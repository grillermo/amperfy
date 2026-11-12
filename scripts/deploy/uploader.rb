# frozen_string_literal: true

# uploader.rb
#
# Publishes release artifacts to the file_server service behind
# AMPERFY_UPLOAD_BASE (files.chiq.me), from whichever Mac runs ../../deploy.
#
# It POSTs each file to the service's /upload with ?name=<pinned name> and the
# bearer token the file_server MCP saved on this Mac (~/.config/file_server/token;
# log in with the MCP's file_server_login once per machine). A pinned upload
# overwrites whatever was there, which is what gives the install page and the
# OTA manifest URLs that never move, so one Home Screen bookmark keeps
# installing the newest release forever.
#
# Where the bytes go. Request bodies past roughly 12 MB stall in the Cloudflare
# tunnel in front of files.chiq.me and the edge answers 524 before the origin
# sees them. So at home the upload goes straight to the service's LAN address,
# and only away from home through the tunnel. The LAN address is used only once
# the server there proves it holds our token (the same challenge the file_server
# MCP uses): on another network that address is someone else's device, and it
# must never see the token.
#
# AMPERFY_PUBLISH_DIR=<dir> instead copies into a local directory that the
# service serves (the old macmini-only route): each file is copied beside its
# target and renamed over it, so a device never downloads a half-written one.

require "digest"
require "fileutils"
require "json"
require "open3"
require "openssl"
require "securerandom"
require "uri"

require_relative "ipa_builder"

module Uploader
  DEFAULT_BASE_URL = "https://files.chiq.me"
  # The macmini's file_server port (~/c/file_server/bin/rackup).
  DEFAULT_LAN_URL  = "http://192.168.1.1:33333"
  DEFAULT_TOKEN_FILE = File.expand_path("~/.config/file_server/token")
  SERVICE_ID = "chiq-file-server"
  # Past this a body risks the tunnel stall described above; past the hard
  # limit the edge refuses it outright, so don't even try.
  TUNNEL_SOFT_LIMIT = 12 * 1024 * 1024
  TUNNEL_HARD_LIMIT = 25 * 1024 * 1024

  module_function

  def base_url
    base = IpaBuilder.env("UPLOAD_BASE").to_s
    base = DEFAULT_BASE_URL if base.empty?
    base.sub(%r{/+\z}, "")
  end

  def lan_url
    url = IpaBuilder.env("UPLOAD_LAN").to_s
    url = DEFAULT_LAN_URL if url.empty?
    url.sub(%r{/+\z}, "")
  end

  # Set only to publish by copying into a directory instead of over HTTP.
  def publish_dir
    dir = IpaBuilder.env("PUBLISH_DIR").to_s
    dir.empty? ? nil : File.expand_path(dir)
  end

  def token
    @token ||= begin
      value = IpaBuilder.env("UPLOAD_TOKEN").to_s.strip
      if value.empty?
        file = IpaBuilder.env("UPLOAD_TOKEN_FILE") || DEFAULT_TOKEN_FILE
        value = File.exist?(file) ? File.read(file).strip : ""
      end
      value.empty? ? nil : value
    end
  end

  # Called by ../../deploy in preflight, so a missing token or an unreachable
  # server fails before a build rather than after one. Returns a description of
  # where the files will go.
  def check!
    if publish_dir
      return "#{publish_dir} (local copy)" if File.directory?(publish_dir)

      IpaBuilder.die("#{IpaBuilder::ENV_PREFIX}_PUBLISH_DIR=#{publish_dir} is not a directory")
    end

    unless token
      IpaBuilder.die(
        "no file_server token on this Mac. Log in once with the file_server MCP " \
        "(file_server_login), which saves it to #{DEFAULT_TOKEN_FILE}, or set " \
        "#{IpaBuilder::ENV_PREFIX}_UPLOAD_TOKEN."
      )
    end

    target = endpoint
    unless service_up?(target)
      IpaBuilder.die("file_server is not answering at #{target}/health; is it running on the macmini?")
    end
    target == base_url ? "#{base_url} (through the tunnel)" : "#{target} (LAN, for #{base_url})"
  end

  # The LAN address when the server there proves it holds our token, the
  # public URL otherwise. Decided once per run.
  def endpoint
    @endpoint ||= lan_server? ? lan_url : base_url
  end

  # Publishes `path` under exactly `name`, returning its public URL.
  def upload(path, name:)
    IpaBuilder.die("file to publish not found: #{path}") unless File.file?(path)
    IpaBuilder.die("unsafe publish name: #{name.inspect}") unless name == File.basename(name) && name =~ /\A[\w.\-]+\z/

    publish_dir ? copy_into_dir(path, name) : post_file(path, name)
    url = "#{base_url}/files/#{name}"
    verify_public!(url, File.size(path))
    url
  end

  def copy_into_dir(path, name)
    target = File.join(publish_dir, name)
    staged = "#{target}.publishing-#{Process.pid}"
    begin
      FileUtils.cp(path, staged)
      File.rename(staged, target)
    ensure
      FileUtils.rm_f(staged)
    end
  end

  def post_file(path, name)
    size = File.size(path)
    if endpoint == base_url
      mb = (size / 1_048_576.0).round(1)
      if size > TUNNEL_HARD_LIMIT
        IpaBuilder.die("#{name} is #{mb} MB, over the tunnel's 25 MB cap; publish from the home network")
      elsif size > TUNNEL_SOFT_LIMIT
        warn "    warning: #{name} is #{mb} MB through the tunnel; bodies over ~12 MB can stall (524)"
      end
    end

    url = "#{endpoint}/upload?#{URI.encode_www_form(name: name)}"
    code, body = curl(url, "-X", "POST", "-F", "file=@#{path};filename=#{name}", "--max-time", "600",
                      headers: "Authorization: Bearer #{token}")
    case code
    when "200" then nil
    when "401" then IpaBuilder.die("file_server rejected the token (401); log in again with the file_server MCP")
    else IpaBuilder.die("upload of #{name} to #{endpoint} failed (#{code}): #{body.to_s[0, 300]}")
    end
  end

  # Fetches the published file's headers through the public URL (the one the
  # phone uses), so a publish that landed somewhere unserved fails here.
  def verify_public!(url, size)
    code, head = curl(url, "--head", "-H", "Cache-Control: no-cache", "--max-time", "30")
    length = head[/^content-length:\s*(\d+)/i, 1].to_i
    return if code == "200" && (length.zero? || length == size)

    IpaBuilder.die("#{url} answers #{code} with #{length} bytes after publishing (expected #{size})")
  end

  def service_up?(url)
    code, body = curl("#{url}/health", "--max-time", "10")
    code == "200" && JSON.parse(body)["service"] == SERVICE_ID
  rescue JSON::ParserError
    false
  end

  # HMAC-SHA256(key: SHA-256 hex of the token, "<nonce>\n<Host>"), which only
  # the real server can compute (see ~/c/file_server/app.rb#health).
  def lan_server?
    return false if lan_url.empty? || token.nil?

    digest = Digest::SHA256.hexdigest(token)
    nonce = SecureRandom.hex(16)
    uri = URI("#{lan_url}/health")
    uri.query = URI.encode_www_form(nonce: nonce, token_id: digest[0, 16])
    code, body = curl(uri.to_s, "--connect-timeout", "1", "--max-time", "3", die: false)
    return false unless code == "200"

    host = uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"
    expected = OpenSSL::HMAC.hexdigest("SHA256", digest, "#{nonce}\n#{host}")
    secure_equal?(JSON.parse(body)["proof"].to_s, expected)
  rescue JSON::ParserError
    false
  end

  # OpenSSL.secure_compare needs Ruby 2.7; the macmini's system Ruby is 2.6.
  def secure_equal?(a, b)
    return false unless a.bytesize == b.bytesize

    a.bytes.zip(b.bytes).inject(0) { |acc, (x, y)| acc | (x ^ y) }.zero?
  end

  # HTTP goes through curl, not Net::HTTP: macOS's Local Network privacy
  # blocks a Ruby that isn't Apple's (rbenv, Homebrew) from LAN addresses with
  # "No route to host", while curl is allowed. `headers:` go in through stdin
  # (-H @-), so the token never shows up in `ps`. Returns [status, body].
  def curl(url, *args, headers: nil, die: true)
    cmd = ["curl", "-sS", "-o", "-", "-w", "\n%{http_code}", "--connect-timeout", "10", *args]
    cmd += ["-H", "@-"] if headers
    cmd << url
    out, err, status = Open3.capture3(*cmd, stdin_data: headers.to_s)
    unless status.success?
      return [nil, err] unless die

      IpaBuilder.die("could not reach #{url.sub(/\?.*/, "")}: #{err.strip}")
    end
    body, _, code = out.rpartition("\n")
    [code, body]
  end
end
