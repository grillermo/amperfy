# frozen_string_literal: true

# The app's version lives in Amperfy.xcodeproj/project.pbxproj, in the Debug and
# Release buildSettings of the app target (the AmperfyKit and test targets carry
# their own 1.0 / 1 and are left alone). The app target's blocks are the ones
# whose PRODUCT_BUNDLE_IDENTIFIER is the app's bundle ID.
module Versioning
  BLOCK     = /buildSettings = \{.*?\n\t\t\t\};/m
  MARKETING = /^(\s*"?MARKETING_VERSION(?:\[sdk=[^\]]+\])?"?\s*=\s*)([\d.]+);/
  BUILD     = /^(\s*CURRENT_PROJECT_VERSION\s*=\s*)(\d+);/

  module_function

  def app_blocks(text, bundle_id)
    marker = "PRODUCT_BUNDLE_IDENTIFIER = #{bundle_id};"
    text.scan(BLOCK).select { |b| b.include?(marker) }
  end

  def read(text, bundle_id:)
    block = app_blocks(text, bundle_id).first or
      raise ArgumentError, "no buildSettings with PRODUCT_BUNDLE_IDENTIFIER = #{bundle_id} in project.pbxproj"
    marketing = block[MARKETING, 2] or raise ArgumentError, "no MARKETING_VERSION for #{bundle_id}"
    build     = block[BUILD, 2]     or raise ArgumentError, "no CURRENT_PROJECT_VERSION for #{bundle_id}"
    { marketing: marketing, build: build.to_i }
  end

  def bump(current, arg)
    return arg if arg =~ /\A\d+\.\d+(\.\d+)?\z/

    major, minor, patch = current.split(".").map(&:to_i)
    patch ||= 0
    case arg
    when "major" then "#{major + 1}.0.0"
    when "minor" then "#{major}.#{minor + 1}.0"
    when "patch", nil then "#{major}.#{minor}.#{patch + 1}"
    else raise ArgumentError, "bad argument '#{arg}' (use patch|minor|major or an X.Y[.Z] version)"
    end
  end

  def write(text, bundle_id:, version:, build:)
    marker = "PRODUCT_BUNDLE_IDENTIFIER = #{bundle_id};"
    text.gsub(BLOCK) do |block|
      next block unless block.include?(marker)

      block.gsub(MARKETING) { "#{$1}#{version};" }.gsub(BUILD) { "#{$1}#{build};" }
    end
  end
end
