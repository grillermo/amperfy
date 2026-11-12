# frozen_string_literal: true

# The app's version lives in Amperfy.xcodeproj/project.pbxproj, in the Debug and
# Release buildSettings of the app target. AmperfyKit and the tests carry their
# own 1.0 / 1 and are left alone, which is why ./deploy cannot bump every
# MARKETING_VERSION in the file. The app target's blocks are the ones that use
# the app's Info.plist (the bundle ID is a $(AMPERFY_BUNDLE_ID) variable now).
module Versioning
  APP_MARKER = "INFOPLIST_FILE = Amperfy/Info.plist;"
  BLOCK      = /buildSettings = \{.*?\n\t\t\t\};/m
  MARKETING  = /^(\s*"?MARKETING_VERSION(?:\[sdk=[^\]]+\])?"?\s*=\s*)([\d.]+);/
  BUILD      = /^(\s*CURRENT_PROJECT_VERSION\s*=\s*)(\d+);/

  module_function

  def app_blocks(text, marker: APP_MARKER)
    text.scan(BLOCK).select { |b| b.include?(marker) }
  end

  def read(text, marker: APP_MARKER)
    block = app_blocks(text, marker: marker).first or
      raise ArgumentError, "no buildSettings with #{marker} in project.pbxproj"
    marketing = block[MARKETING, 2] or raise ArgumentError, "no MARKETING_VERSION in the app target"
    build     = block[BUILD, 2]     or raise ArgumentError, "no CURRENT_PROJECT_VERSION in the app target"
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

  def write(text, version:, build:, marker: APP_MARKER)
    text.gsub(BLOCK) do |block|
      next block unless block.include?(marker)

      block.gsub(MARKETING) { "#{$1}#{version};" }.gsub(BUILD) { "#{$1}#{build};" }
    end
  end
end
