# Amperfy iOS OTA Pipeline (full spec) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring this Amperfy fork's over-the-air release setup (`./deploy` + `scripts/deploy/`) up to the full spec in `~/c/agents-configs/docs/ios-ota-rollout/pipeline-prompt.md`, porting the missing pieces from the reference implementation in `~/c/vvterm`.

**Architecture:** `./deploy` stays a Ruby script at the repo root. Its pure logic moves into small, unit-tested modules under `scripts/deploy/`: `release_support.rb` (dotenv, release notes, escaping, push check), `install_page.rb` (HTML), plus the existing `ipa_builder.rb`, `uploader.rb` and `versioning.rb`. The bundle ID and team move out of `project.pbxproj` into a committed `Config/Amperfy.xcconfig`, overridden by a gitignored `Config/Local.xcconfig`. In the app, a new pure type `OTAInstallLatest` (AmperfyKit) maps Info.plist to the `itms-services://` URL. The existing `QuickActionsHandler` registers "Install Latest" dynamically through it, and `SceneDelegate` handles it ahead of its account guard. A new `DevLog.swift` (AmperfyKit) and `scripts/devlog/server.py` provide the `--devlog` diagnostics build.

**Tech Stack:** Ruby 3.2 (stdlib + minitest), Xcode 26 / `xcodebuild`, Swift 6 (strict concurrency, XCTest), Python 3 stdlib.

---

## Context for the executor (read first)

You are in `~/c/third-parties/amperfy` on the macmini (this machine). The app is a third-party fork. Keep upstream merges easy: prefer new files, keep edits to upstream files small, and don't reformat code you don't change.

**Remotes:** `origin` = upstream `https://github.com/BLeeEZ/amperfy`. **Never push there.** `github` = the user's fork `git@github.com:grillermo/amperfy.git`. `./deploy` pushes to `github` only. Default branch: `master`. The local `master` tracks `origin/master`, so a bare `git push` would push to upstream. Never run a bare `git push`. Don't push during this plan at all; only the final `./deploy` (Task 16, after the user approves) pushes.

**Already done on this fork (commits 9095d71f..f96a0c9d):**
- `DEVELOPMENT_TEAM = Q3WS4MWCW3` (project level, `project.pbxproj` around lines 2979 and 3047) and bundle IDs `me.chiq.amperfy`, `me.chiq.amperfy.AmperfyKit`, `me.chiq.amperfy.AmperfyKitTests` are hard-coded in `project.pbxproj`. The CarPlay entitlement was removed.
- `./deploy` (207 lines) already has: version argument, notes filter, branch check (`master`), clean-tree check, tag check, publish-dir check, `at_exit` restore of the pbxproj, ExportOptions with `thinning` `<none>`, manifest dict, atomic publish, install page with `h()` escaping, temp-dir delete on success, SwiftFormat-leftover check, and push to `github`.
- `scripts/deploy/versioning.rb` bumps only the **app target's** `MARKETING_VERSION` (including `"MARKETING_VERSION[sdk=macosx*]"`) and `CURRENT_PROJECT_VERSION`. It finds the app target by `PRODUCT_BUNDLE_IDENTIFIER = me.chiq.amperfy;`. AmperfyKit and the tests keep `1.0` / `1`. Keep that behaviour, but the marker must change (Task 1), because Task 2 turns the bundle ID into a variable.
- A **static** "Install Latest" `UIApplicationShortcutItems` entry in `Amperfy/Info.plist`, and a **hard-coded** manifest URL in `AmperfyKit/Common/QuickActionsHandler.swift` (`static let installLatestURL`). Tasks 9–10 replace both.
- Release `amperfy-ota-v2.1.2` is published. The app is now at 2.1.2, build 2. `github/master` == local HEAD.

**Real gaps against the spec (what this plan fixes):**
1. No codesign probe or `security unlock-keychain` preflight.
2. Push: no "push failed but the remote has our HEAD = success" fallback.
3. No `.env` loader; `AMPERFY_UPLOAD_BASE` silently defaults to `https://files.chiq.me`.
4. No `Config/Amperfy.xcconfig` / gitignored `Config/Local.xcconfig`; the bundle ID and team are hard-coded in the pbxproj and in `ipa_builder.rb`.
5. Signing hints are partial: no Xcode → Accounts hint, and nothing when the *archive* fails.
6. No `AMPERFY_UNSIGNED=1` fallback.
7. The temp dir is deleted only on success.
8. The install page has no "Add to Home Screen" hint.
9. No `AmperfyOTAManifestURL` Info.plist key. The quick action is static and has a hard-coded URL, no `exit(0)`, and no unit test. It is also blocked by `SceneDelegate`'s `isNormalInteraction` guard (no account yet, or the library is updating).
10. No ntfy project memory.
11. No `--devlog`, `DevLog.swift`, `scripts/devlog/server.py` or `/log/` gitignore.
12. Docs: `scripts/deploy/README.md` lacks `.env`, `Local.xcconfig` and flags; the root README has no pointer.

**Deliberate deviation from the spec: do NOT add `NSAllowsLocalNetworking`.** `Amperfy/Info.plist` already has `NSAppTransportSecurity` → `NSAllowsArbitraryLoads = true`, because users connect to plain-HTTP Ampache/Subsonic servers. Apple documents that on iOS 10+, when `NSAllowsLocalNetworking` is present, `NSAllowsArbitraryLoads` is **ignored**. Adding it would break every non-local `http://` server. Arbitrary loads already allow the LAN DevLog server. Task 11 adds an XML comment saying so instead.

**Build facts:**
- `objectVersion = 54`: no file-system-synchronized groups. Every new Swift file must be registered in `project.pbxproj` (PBXBuildFile, PBXFileReference, group child, Sources phase). This plan uses fixed IDs with the prefix `0CA0FF1C` (verified unused) and inserts them with a Ruby snippet that asserts each anchor matches exactly once.
- Swift 6 with `SWIFT_STRICT_CONCURRENCY = complete`. The default actor isolation is **not** MainActor, so don't write `nonisolated` on types.
- Every build runs the `SwiftFormat` build phase (`BuildTools/applyFormat.sh`). The first time, it compiles swiftformat with `swift run` (slow), then **rewrites files in place** across the repo using `.swiftformat` (2-space indent). After every xcodebuild, run `git status`. If it reformatted the files you wrote, include that formatting in your commit. If it touched files you did not write, stop and tell the user.
- Simulator: `iPhone 16e` (iOS 26.3) exists. Unit tests live in the `AmperfyKitTests` target (XCTest, `@testable import AmperfyKit`), run through the `Amperfy` scheme.
- Signing identity present: `Apple Development: GUILLERMO SILICEO TRUEBA (5G377QAPK3)`.
- The publish dir is `~/c/file_server/files` (= `../../file_server/files` from the repo).
- Ruby: `ruby` 3.2.4 via rbenv. Python: `python3`.

---

## File structure

| File | Status | Responsibility |
|---|---|---|
| `deploy` | rewrite | CLI flow: flags, preflight, prompt, bump, build, publish, commit/tag/push |
| `scripts/deploy/release_support.rb` | create | Pure helpers: dotenv, notes, HTML escape, devlog URL, push check |
| `scripts/deploy/release_support_test.rb` | create | minitest for the above |
| `scripts/deploy/install_page.rb` | create | Renders the install page HTML |
| `scripts/deploy/install_page_test.rb` | create | minitest |
| `scripts/deploy/ipa_builder.rb` | rewrite | xcconfig values, codesign probe, archive/export, unsigned fallback, signing hints |
| `scripts/deploy/ipa_builder_test.rb` | create | minitest for the pure parts |
| `scripts/deploy/uploader.rb` | modify | `AMPERFY_UPLOAD_BASE` required (from `.env`) |
| `scripts/deploy/versioning.rb` (+`_test`) | modify | Find the app target by `INFOPLIST_FILE` instead of the bundle ID |
| `scripts/deploy/README.md` | rewrite | Full usage docs |
| `Config/Amperfy.xcconfig` | create | Committed defaults + `#include? "Local.xcconfig"` |
| `Config/Local.xcconfig` | create, **gitignored** | `me.chiq.amperfy` / `Q3WS4MWCW3` |
| `.env` | create, **gitignored** | `AMPERFY_UPLOAD_BASE=https://files.chiq.me` |
| `.gitignore` | modify | `.env`, `Config/Local.xcconfig`, `/log/` |
| `Amperfy.xcodeproj/project.pbxproj` | modify | xcconfig wiring, bundle-ID variables, 4 new Swift files |
| `Amperfy/Info.plist` | modify | Drop the static shortcut; add the `AmperfyOTAManifestURL` and `AmperfyDevLogURL` keys |
| `AmperfyKit/Common/OTAInstallLatest.swift` | create | Pure Info.plist → itms-services URL mapping |
| `AmperfyKitTests/Cases/Common/OTAInstallLatestTest.swift` | create | XCTest |
| `AmperfyKit/Common/QuickActionsHandler.swift` | modify | Dynamic Install Latest item, open + `exit(0)` |
| `Amperfy/SceneDelegate.swift` | modify | 3 small hooks (cold launch, warm action, register at launch) |
| `AmperfyKit/Common/DevLog.swift` | create | DevLog event/upload sink |
| `AmperfyKitTests/Cases/Common/DevLogTest.swift` | create | XCTest |
| `Amperfy/AppDelegate.swift` | modify | One `DevLog.event("app.launch")` line |
| `scripts/devlog/server.py` | create | Stdlib log server on :19486 |
| `scripts/devlog/server_test.py` | create | unittest |
| `README.md` | modify | Short "Fork: OTA install" section at the end, pointing to `scripts/deploy/README.md` |
| `~/.claude/projects/-Users-grillermo-c-third-parties-amperfy/memory/*` | create (outside the repo) | ntfy-after-deploy memory |

Commit after each task with a message that ends with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Don't push.

---

### Task 1: Versioning finds the app target by its Info.plist, not its bundle ID

**Files:**
- Modify: `scripts/deploy/versioning.rb`
- Modify: `scripts/deploy/versioning_test.rb`

- [ ] **Step 1: Rewrite the test** so the fixture uses the variable bundle ID and the API has no `bundle_id:`.

Replace the whole of `scripts/deploy/versioning_test.rb` with:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "versioning"

class VersioningTest < Minitest::Test
  PBX = <<~PBX
    \t\tA /* Debug */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tCURRENT_PROJECT_VERSION = 7;
    \t\t\t\tINFOPLIST_FILE = Amperfy/Info.plist;
    \t\t\t\tMARKETING_VERSION = 2.1.1;
    \t\t\t\t"MARKETING_VERSION[sdk=macosx*]" = 2.1.1;
    \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "$(AMPERFY_BUNDLE_ID)";
    \t\t\t};
    \t\t\tname = Debug;
    \t\t};
    \t\tB /* Debug */ = {
    \t\t\tisa = XCBuildConfiguration;
    \t\t\tbuildSettings = {
    \t\t\t\tCURRENT_PROJECT_VERSION = 1;
    \t\t\t\tGENERATE_INFOPLIST_FILE = YES;
    \t\t\t\tMARKETING_VERSION = 1.0;
    \t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "$(AMPERFY_BUNDLE_ID).AmperfyKit";
    \t\t\t};
    \t\t\tname = Debug;
    \t\t};
  PBX

  def test_read
    assert_equal({ marketing: "2.1.1", build: 7 }, Versioning.read(PBX))
  end

  def test_bump_keywords
    assert_equal "2.1.2", Versioning.bump("2.1.1", "patch")
    assert_equal "2.1.2", Versioning.bump("2.1.1", nil)
    assert_equal "2.2.0", Versioning.bump("2.1.1", "minor")
    assert_equal "3.0.0", Versioning.bump("2.1.1", "major")
    assert_equal "3.1", Versioning.bump("2.1.1", "3.1")
    assert_raises(ArgumentError) { Versioning.bump("2.1.1", "banana") }
  end

  def test_write_touches_only_the_app_target
    out = Versioning.write(PBX, version: "2.1.2", build: 8)
    assert_equal({ marketing: "2.1.2", build: 8 }, Versioning.read(out))
    assert_includes out, %("MARKETING_VERSION[sdk=macosx*]" = 2.1.2;)
    assert_includes out, "MARKETING_VERSION = 1.0;"
    assert_includes out, "CURRENT_PROJECT_VERSION = 1;"
  end

  def test_read_raises_without_the_app_target
    assert_raises(ArgumentError) { Versioning.read(PBX.gsub("INFOPLIST_FILE = Amperfy/Info.plist;", "")) }
  end

  def test_real_project_has_an_app_target
    real = File.read(File.expand_path("../../Amperfy.xcodeproj/project.pbxproj", __dir__))
    assert_match(/\A\d+\.\d+(\.\d+)?\z/, Versioning.read(real)[:marketing])
  end
end
```

- [ ] **Step 2: Run it and check that it fails**

Run: `ruby scripts/deploy/versioning_test.rb`
Expected: errors with `ArgumentError: missing keyword: :bundle_id`.

- [ ] **Step 3: Implement.** Replace the whole of `scripts/deploy/versioning.rb` with:

```ruby
# frozen_string_literal: true

# The app's version lives in Amperfy.xcodeproj/project.pbxproj, in the Debug and
# Release buildSettings of the app target. AmperfyKit and the test targets carry
# their own 1.0 / 1 and are left alone. The app target's blocks are the only ones
# with INFOPLIST_FILE = Amperfy/Info.plist (the others generate theirs). The
# bundle ID can't be the marker: it is "$(AMPERFY_BUNDLE_ID)" for every target.
module Versioning
  APP_MARKER = "INFOPLIST_FILE = Amperfy/Info.plist;"
  BLOCK      = /buildSettings = \{.*?\n\t\t\t\};/m
  MARKETING  = /^(\s*"?MARKETING_VERSION(?:\[sdk=[^\]]+\])?"?\s*=\s*)([\d.]+);/
  BUILD      = /^(\s*CURRENT_PROJECT_VERSION\s*=\s*)(\d+);/

  module_function

  def app_blocks(text)
    text.scan(BLOCK).select { |b| b.include?(APP_MARKER) }
  end

  def read(text)
    block = app_blocks(text).first or
      raise ArgumentError, "no buildSettings with #{APP_MARKER} in project.pbxproj"
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

  def write(text, version:, build:)
    text.gsub(BLOCK) do |block|
      next block unless block.include?(APP_MARKER)

      block.gsub(MARKETING) { "#{$1}#{version};" }.gsub(BUILD) { "#{$1}#{build};" }
    end
  end
end
```

(`deploy` still calls the old `bundle_id:` signature; Task 7 rewrites it. Until then, don't run `./deploy`.)

- [ ] **Step 4: Run the test and check that it passes**

Run: `ruby scripts/deploy/versioning_test.rb`
Expected: `5 runs, ... 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add scripts/deploy/versioning.rb scripts/deploy/versioning_test.rb
git commit -m "refactor(deploy): find the app target by INFOPLIST_FILE

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Bundle ID and team move into Config/Amperfy.xcconfig, overridden by a gitignored Local.xcconfig

**Files:**
- Create: `Config/Amperfy.xcconfig`
- Create (gitignored, not committed): `Config/Local.xcconfig`, `.env`
- Modify: `.gitignore`
- Modify: `Amperfy.xcodeproj/project.pbxproj`

Why at project level: Xcode's precedence is target settings > target xcconfig > project settings > project xcconfig. No target sets `DEVELOPMENT_TEAM`, so after the project-level `DEVELOPMENT_TEAM` lines are removed, the project xcconfig supplies it to every target. `AMPERFY_BUNDLE_ID` is a new variable that every target inherits. The committed defaults are upstream's bundle ID and an empty team, so a fresh clone builds for the simulator exactly like upstream.

- [ ] **Step 1: Record the current resolved settings (baseline)**

Run:
```bash
xcodebuild -project Amperfy.xcodeproj -target Amperfy -configuration Release -showBuildSettings 2>/dev/null | grep -E " (PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM) ="
```
Expected: `DEVELOPMENT_TEAM = Q3WS4MWCW3`, `PRODUCT_BUNDLE_IDENTIFIER = me.chiq.amperfy`.

- [ ] **Step 2: Create `Config/Amperfy.xcconfig`**

```
// Settings that identify whoever builds and signs this fork. The defaults are
// upstream's bundle ID and no team, so a fresh clone still builds (simulator).
// Put your own values in Config/Local.xcconfig, which is gitignored and
// overrides these. See scripts/deploy/README.md.
AMPERFY_BUNDLE_ID = de.familie-zimba.amperfy-music
DEVELOPMENT_TEAM =

// ./deploy passes the OTA manifest URL on the xcodebuild command line, because
// an xcconfig file reads the // in a URL as a comment. Builds made any other
// way leave it empty, so they offer no Install Latest quick action.
AMPERFY_OTA_MANIFEST_URL =

// ./deploy --devlog passes the DevLog server URL the same way. When it is empty,
// the app records nothing (AmperfyKit/Common/DevLog.swift).
AMPERFY_DEVLOG_URL =

#include? "Local.xcconfig"
```

- [ ] **Step 3: Create the gitignored local files and ignore them**

`Config/Local.xcconfig`:
```
// Personal signing values; gitignored. Overrides Config/Amperfy.xcconfig.
AMPERFY_BUNDLE_ID = me.chiq.amperfy
DEVELOPMENT_TEAM = Q3WS4MWCW3
```

`.env`:
```
# Gitignored. Read by ./deploy; an exported shell variable wins.
AMPERFY_UPLOAD_BASE=https://files.chiq.me
```

Append to `.gitignore`:
```

# OTA deploy (fork): personal settings
.env
Config/Local.xcconfig

# DevLog server output (scripts/devlog/server.py)
/log/
```

Verify: `git check-ignore -v .env Config/Local.xcconfig log/x` prints all three.

- [ ] **Step 4: Wire the pbxproj** (run from the repo root)

```bash
ruby - <<'RUBY'
path = "Amperfy.xcodeproj/project.pbxproj"
pbx = File.read(path)

def once!(pbx, needle)
  n = pbx.scan(needle).length
  abort "expected exactly 1 match, got #{n}: #{needle.inspect}" unless n == 1
end

def insert_after!(pbx, anchor, text)
  once!(pbx, anchor)
  pbx.sub!(anchor) { anchor + text }
end

ref = "0CA0FF1C0000000000000001"

# File reference (at the project root, like the other top-level groups)
insert_after!(pbx, "/* Begin PBXFileReference section */\n",
  "\t\t#{ref} /* Amperfy.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; name = Amperfy.xcconfig; path = Config/Amperfy.xcconfig; sourceTree = \"<group>\"; };\n")

# Main group child
insert_after!(pbx, "50C9D614284FA847007F18D0 /* AmperfyKitTests */,\n",
  "\t\t\t\t#{ref} /* Amperfy.xcconfig */,\n")

# Project-level Debug and Release use it as their base configuration
%w[5083860A21C5965E00C4BB32\ /*\ Debug\ */ 5083860B21C5965E00C4BB32\ /*\ Release\ */].each do |cfg|
  insert_after!(pbx, "#{cfg} = {\n\t\t\tisa = XCBuildConfiguration;\n",
    "\t\t\tbaseConfigurationReference = #{ref} /* Amperfy.xcconfig */;\n")
end

# Team comes from the xcconfig now
n = pbx.scan("\t\t\t\tDEVELOPMENT_TEAM = Q3WS4MWCW3;\n").length
abort "expected 2 DEVELOPMENT_TEAM lines, got #{n}" unless n == 2
pbx.gsub!("\t\t\t\tDEVELOPMENT_TEAM = Q3WS4MWCW3;\n", "")

# Bundle IDs become variables
{
  "PRODUCT_BUNDLE_IDENTIFIER = me.chiq.amperfy;" => 'PRODUCT_BUNDLE_IDENTIFIER = "$(AMPERFY_BUNDLE_ID)";',
  "PRODUCT_BUNDLE_IDENTIFIER = me.chiq.amperfy.AmperfyKit;" => 'PRODUCT_BUNDLE_IDENTIFIER = "$(AMPERFY_BUNDLE_ID).AmperfyKit";',
  "PRODUCT_BUNDLE_IDENTIFIER = me.chiq.amperfy.AmperfyKitTests;" => 'PRODUCT_BUNDLE_IDENTIFIER = "$(AMPERFY_BUNDLE_ID).AmperfyKitTests";',
}.each do |from, to|
  n = pbx.scan(from).length
  abort "expected 2 of #{from}, got #{n}" unless n == 2
  pbx.gsub!(from, to)
end

File.write(path, pbx)
puts "ok"
RUBY
```
Expected: `ok`. The `0CA0FF1C` IDs must not exist yet (`grep -c 0CA0FF1C` printed 0 before this task).

- [ ] **Step 5: Verify the precedence works both ways**

```bash
xcodebuild -project Amperfy.xcodeproj -target Amperfy -configuration Release -showBuildSettings 2>/dev/null | grep -E " (PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM|AMPERFY_OTA_MANIFEST_URL) ="
```
Expected: `DEVELOPMENT_TEAM = Q3WS4MWCW3`, `PRODUCT_BUNDLE_IDENTIFIER = me.chiq.amperfy`, `AMPERFY_OTA_MANIFEST_URL =` (empty).

```bash
mv Config/Local.xcconfig /tmp/amperfy-Local.xcconfig
xcodebuild -project Amperfy.xcodeproj -target AmperfyKit -configuration Release -showBuildSettings 2>/dev/null | grep -E " (PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM) ="
mv /tmp/amperfy-Local.xcconfig Config/Local.xcconfig
```
Expected without Local: `PRODUCT_BUNDLE_IDENTIFIER = de.familie-zimba.amperfy-music.AmperfyKit`, `DEVELOPMENT_TEAM =` (empty). Then `ruby scripts/deploy/versioning_test.rb` still passes (it reads the real project).

- [ ] **Step 6: Commit** (Local.xcconfig and .env must not appear in `git status`)

```bash
git add Config/Amperfy.xcconfig .gitignore Amperfy.xcodeproj/project.pbxproj
git commit -m "chore(signing): move bundle ID and team into Config/*.xcconfig

Config/Amperfy.xcconfig carries upstream-like defaults; the gitignored
Config/Local.xcconfig sets me.chiq.amperfy and team Q3WS4MWCW3.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: ReleaseSupport, the pure helpers for deploy

**Files:**
- Create: `scripts/deploy/release_support.rb`
- Test: `scripts/deploy/release_support_test.rb`

- [ ] **Step 1: Write the failing test** `scripts/deploy/release_support_test.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "release_support"

class ReleaseSupportTest < Minitest::Test
  R = ReleaseSupport

  def test_dotenv_loads_values_and_never_overrides_an_exported_variable
    file = Tempfile.new("env")
    file.write(<<~ENV)
      # comment
      AMPERFY_UPLOAD_BASE="https://files.example.com/"
      export AMPERFY_PUBLISH_DIR=/srv/files
      ALREADY=from-file

      NOEQUALS
    ENV
    file.close
    env = { "ALREADY" => "from-shell" }
    R.load_dotenv(file.path, env)
    assert_equal "https://files.example.com/", env["AMPERFY_UPLOAD_BASE"]
    assert_equal "/srv/files", env["AMPERFY_PUBLISH_DIR"]
    assert_equal "from-shell", env["ALREADY"]
    refute env.key?("NOEQUALS")
  end

  def test_dotenv_missing_file_is_fine
    env = {}
    R.load_dotenv("/nonexistent/.env", env)
    assert_empty env
  end

  def test_notes_from_subjects_drop_noise_dupes_and_cap_at_eight
    subjects = [
      "Release Amperfy OTA amperfy-ota-v2.1.2", "Merge branch 'x'", "Bump deps",
      "wip", "WIP: half done", "Fix crash", "Fix crash",
    ] + (1..10).map { |i| "Feature #{i}" }
    notes = R.notes_from_subjects(subjects)
    assert_equal "Fix crash", notes.first
    assert_equal 8, notes.length
    refute(notes.any? { |n| n =~ /Release|Merge|Bump|wip/i })
  end

  def test_clean_notes_strips_bullets_and_splits_lines
    assert_equal %w[one two three], R.clean_notes(["- one\n* two", "• three", "  "])
  end

  def test_release_notes_headlines
    assert_equal "Release 2.2.0.", R.release_notes(version: "2.2.0", summary: nil, notes: [], subjects: [])
    assert_equal "What's new in 2.2.0:\n\n• Fix crash",
                 R.release_notes(version: "2.2.0", summary: nil, notes: [], subjects: ["Fix crash"])
    assert_equal "Faster\n\n• a",
                 R.release_notes(version: "2.2.0", summary: "Faster", notes: ["a"], subjects: ["ignored"])
  end

  def test_html_escape
    assert_equal "&lt;b&gt; &amp; &quot;q&quot; &#39;s&#39;", R.html_escape(%(<b> & "q" 's'))
    assert_equal "7", R.html_escape(7)
  end

  def test_devlog_url
    assert_equal "http://macmini.local:19486/api/devlog", R.devlog_url({}, "macmini")
    assert_equal "http://macmini.local:19500/api/devlog", R.devlog_url({ "AMPERFY_DEVLOG_PORT" => "19500" }, "macmini")
    assert_equal "http://x:1/y", R.devlog_url({ "AMPERFY_DEVLOG_URL" => "http://x:1/y" }, "macmini")
  end

  def test_push_succeeded
    assert R.push_succeeded?(push_ok: true, local_head: "a", remote_head: "")
    assert R.push_succeeded?(push_ok: false, local_head: "abc", remote_head: "abc")
    refute R.push_succeeded?(push_ok: false, local_head: "abc", remote_head: "def")
    refute R.push_succeeded?(push_ok: false, local_head: "", remote_head: "")
  end
end
```

- [ ] **Step 2: Run it and check that it fails**

Run: `ruby scripts/deploy/release_support_test.rb`
Expected: `cannot load such file -- .../release_support`.

- [ ] **Step 3: Implement** `scripts/deploy/release_support.rb`:

```ruby
# frozen_string_literal: true

# Pure helpers for ../../deploy, kept out of the script so
# release_support_test.rb can cover them.
module ReleaseSupport
  # Commit subjects that tell someone installing the build nothing: release
  # commits, merges, dependency bumps, work in progress.
  NOTE_NOISE = /\A(Release |Merge |Bump |wip\b)/i
  MAX_NOTES  = 8

  module_function

  # Minimal dotenv: KEY=VALUE lines, # comments, optional quotes and `export `.
  # A variable already exported in the shell wins, so
  # `AMPERFY_PUBLISH_DIR=/x ./deploy` overrides .env for one run.
  def load_dotenv(path, env = ENV)
    return unless File.exist?(path)

    File.readlines(path, chomp: true).each do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      key, value = line.split("=", 2)
      next unless key && value

      key = key.strip.delete_prefix("export ").strip
      env[key] ||= value.strip.gsub(/\A["']|["']\z/, "")
    end
  end

  # --note values: split multi-line values, drop bullet markers and blanks.
  def clean_notes(raw)
    raw.flat_map { |n| n.split("\n") }
       .map { |n| n.strip.sub(/\A[-*•]\s*/, "") }
       .reject(&:empty?)
  end

  def notes_from_subjects(subjects)
    subjects.map(&:strip).reject { |s| s.empty? || s.match?(NOTE_NOISE) }.uniq.first(MAX_NOTES)
  end

  def release_notes(version:, summary:, notes:, subjects:)
    bullets  = notes.empty? ? notes_from_subjects(subjects) : notes
    headline = summary || (bullets.empty? ? "Release #{version}." : "What's new in #{version}:")
    lines = [headline]
    lines << "" unless bullets.empty?
    lines.concat(bullets.map { |b| "• #{b}" })
    lines.join("\n")
  end

  def html_escape(str)
    str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;").gsub("'", "&#39;")
  end

  # Each app on the macmini has its own DevLog port so the servers can run side
  # by side (vvterm uses 19480). server.py reads the same AMPERFY_DEVLOG_PORT.
  DEVLOG_PORT = 19486

  # Where a --devlog build sends its records: scripts/devlog/server.py on this
  # Mac, reached by its Bonjour name so it works on any LAN address.
  def devlog_url(env, local_host_name)
    override = env["AMPERFY_DEVLOG_URL"].to_s
    return override unless override.empty?

    port = env["AMPERFY_DEVLOG_PORT"].to_s
    port = DEVLOG_PORT.to_s if port.empty?
    "http://#{local_host_name}.local:#{port}/api/devlog"
  end

  # `git push` can fail after the remote already took the commit (a hook or a
  # flaky connection on the way back). If the remote branch is at our HEAD, the
  # release is out.
  def push_succeeded?(push_ok:, local_head:, remote_head:)
    push_ok || (!local_head.to_s.empty? && local_head == remote_head)
  end
end
```

- [ ] **Step 4: Run the test and check that it passes**

Run: `ruby scripts/deploy/release_support_test.rb`
Expected: `8 runs, ... 0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
git add scripts/deploy/release_support.rb scripts/deploy/release_support_test.rb
git commit -m "feat(deploy): add tested release helpers (dotenv, notes, push check)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: InstallPage renders the install page with everything escaped

**Files:**
- Create: `scripts/deploy/install_page.rb`
- Test: `scripts/deploy/install_page_test.rb`

- [ ] **Step 1: Write the failing test** `scripts/deploy/install_page_test.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "install_page"

class InstallPageTest < Minitest::Test
  def render(notes: "What's new in 2.1.3:\n\n• Fix <script>alert(1)</script>")
    InstallPage.render(
      app_name: "Amperfy", version: "2.1.3", build: 3,
      icon_url: "https://files.example.com/files/amperfy-icon.png",
      itms_url: "itms-services://?action=download-manifest&url=https://files.example.com/files/amperfy-manifest.plist",
      notes: notes, bundle_id: "me.chiq.amperfy"
    )
  end

  def test_escapes_inserted_values
    html = render
    refute_includes html, "<script>alert"
    assert_includes html, "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert_includes html, 'href="itms-services://?action=download-manifest&amp;url=https://files.example.com/files/amperfy-manifest.plist"'
  end

  def test_has_the_required_sections
    html = render
    assert_includes html, "Version 2.1.3 (build 3)"
    assert_includes html, "Safari"
    assert_includes html, "Add to Home Screen"
    assert_includes html, "registered"
    assert_includes html, "Install Latest"
    assert_includes html, 'name="viewport"'
  end
end
```

- [ ] **Step 2: Run it and check that it fails**

Run: `ruby scripts/deploy/install_page_test.rb`
Expected: `cannot load such file`.

- [ ] **Step 3: Implement** `scripts/deploy/install_page.rb` (styles copied from the existing page in `deploy`):

```ruby
# frozen_string_literal: true

require_relative "release_support"

# The one self-contained page a phone opens to install a release. Published
# under a fixed name, so a Home Screen bookmark of it always offers the newest
# build. Every inserted value goes through html_escape.
module InstallPage
  module_function

  def render(app_name:, version:, build:, icon_url:, itms_url:, notes:, bundle_id:)
    h = ->(s) { ReleaseSupport.html_escape(s) }
    <<~HTML
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
      <title>Install #{h[app_name]}</title>
      <style>
        :root { color-scheme: dark; }
        body { margin: 0; padding: 2.5rem 1.25rem 4rem; background: #111; color: #f2f2f2;
          font: 16px/1.55 -apple-system, system-ui, sans-serif; display: flex; flex-direction: column; align-items: center; }
        main { width: 100%; max-width: 26rem; }
        img.icon { width: 88px; height: 88px; border-radius: 20px; display: block; margin: 0 auto 1.25rem; }
        h1 { font-size: 1.6rem; margin: 0 0 .25rem; text-align: center; }
        .version { text-align: center; color: #9a9a9a; margin: 0 0 2rem; font-size: .95rem; }
        a.install { display: block; background: #1E88E5; color: #fff; text-decoration: none; font-weight: 600;
          font-size: 1.05rem; text-align: center; padding: 1rem; border-radius: 14px; margin-bottom: 1.5rem; }
        a.install:active { background: #1667b0; }
        section { border-top: 1px solid #2a2a2a; padding-top: 1.25rem; margin-top: 1.25rem; }
        h2 { font-size: .8rem; text-transform: uppercase; letter-spacing: .08em; color: #8a8a8a; margin: 0 0 .6rem; }
        pre.notes { white-space: pre-wrap; margin: 0; font: inherit; color: #d8d8d8; }
        p { color: #b0b0b0; font-size: .9rem; }
        code { background: #1c1c1c; padding: .15em .4em; border-radius: 5px; font-size: .85em; word-break: break-all; }
      </style>
      </head>
      <body>
      <main>
        <img class="icon" src="#{h[icon_url]}" alt="">
        <h1>#{h[app_name]}</h1>
        <p class="version">Version #{h[version]} (build #{h[build]})</p>
        <a class="install" href="#{h[itms_url]}">Install #{h[app_name]}</a>
        <p>Open this page in <strong>Safari</strong>; other browsers cannot start an install.
        Then confirm the prompt and watch the Home Screen.</p>
        <section><h2>What&rsquo;s new</h2><pre class="notes">#{h[notes]}</pre></section>
        <section><h2>Updating later</h2>
        <p>Add this page to your Home Screen (Share &rarr; Add to Home Screen): its button always
        installs the newest release. Or touch and hold the app icon and pick <em>Install Latest</em>.</p></section>
        <section><h2>Requirements</h2>
        <p>The device must be registered on the developer account <em>before</em> the build is made; a
        device added afterwards needs a fresh <code>./deploy</code>. This fork is signed as
        <code>#{h[bundle_id]}</code>, so it installs beside the App Store #{h[app_name]}, without CarPlay.</p></section>
      </main>
      </body>
      </html>
    HTML
  end
end
```

- [ ] **Step 4: Run the test and check that it passes**

Run: `ruby scripts/deploy/install_page_test.rb`
Expected: `2 runs, ... 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add scripts/deploy/install_page.rb scripts/deploy/install_page_test.rb
git commit -m "feat(deploy): render the install page in a tested module

Adds the Add to Home Screen hint and escapes every inserted value.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: IpaBuilder reads xcconfig values, probes codesign, has an unsigned fallback and signing hints

**Files:**
- Rewrite: `scripts/deploy/ipa_builder.rb`
- Test: `scripts/deploy/ipa_builder_test.rb`

- [ ] **Step 1: Write the failing test** `scripts/deploy/ipa_builder_test.rb`:

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "ipa_builder"

class IpaBuilderTest < Minitest::Test
  B = IpaBuilder

  def test_export_options
    Dir.mktmpdir do |dir|
      path = B.export_options_plist(File.join(dir, "o.plist"), team: "TEAM123",
        manifest: { app_url: "https://f.example/a.ipa?x=1&y=2", icon_url: "https://f.example/i.png" })
      xml = File.read(path)
      assert_includes xml, "<key>method</key><string>release-testing</string>"
      assert_includes xml, "<key>teamID</key><string>TEAM123</string>"
      assert_includes xml, "<key>signingStyle</key><string>automatic</string>"
      assert_includes xml, "<key>thinning</key><string>&lt;none&gt;</string>"
      assert_includes xml, "https://f.example/a.ipa?x=1&amp;y=2"
      assert system("plutil -lint -s #{path}"), "ExportOptions.plist must be valid"
    end
  end

  def test_xcconfig_value_local_wins_and_empty_falls_through
    Dir.mktmpdir do |dir|
      local = File.join(dir, "Local.xcconfig")
      base  = File.join(dir, "Amperfy.xcconfig")
      File.write(local, "AMPERFY_BUNDLE_ID = me.example.app\nDEVELOPMENT_TEAM =\n")
      File.write(base, "AMPERFY_BUNDLE_ID = upstream.id\nDEVELOPMENT_TEAM = BASETEAM\n")
      paths = [local, base]
      assert_equal "me.example.app", B.xcconfig_value("AMPERFY_BUNDLE_ID", paths: paths)
      assert_equal "BASETEAM", B.xcconfig_value("DEVELOPMENT_TEAM", paths: paths)
      assert_nil B.xcconfig_value("NOPE", paths: paths)
      assert_equal "upstream.id", B.xcconfig_value("AMPERFY_BUNDLE_ID", paths: [File.join(dir, "missing"), base])
    end
  end

  def test_xcodebuild_settings
    signed = B.xcodebuild_settings(team: "T1", ota_manifest_url: "https://f.example/m.plist", devlog_url: nil, unsigned: false)
    assert_equal ["DEVELOPMENT_TEAM=T1", "AMPERFY_OTA_MANIFEST_URL=https://f.example/m.plist"], signed

    unsigned = B.xcodebuild_settings(team: nil, ota_manifest_url: nil, devlog_url: "http://m.local:19486/api/devlog", unsigned: true)
    assert_equal ["CODE_SIGNING_ALLOWED=NO", "AMPERFY_DEVLOG_URL=http://m.local:19486/api/devlog"], unsigned
  end

  def test_real_config_resolves_bundle_id
    refute_nil B.bundle_id
  end
end
```

- [ ] **Step 2: Run it and check that it fails**

Run: `ruby scripts/deploy/ipa_builder_test.rb`
Expected: errors (`unknown keyword: :team`, `undefined method 'xcconfig_value'`).

- [ ] **Step 3: Implement.** Replace the whole of `scripts/deploy/ipa_builder.rb` with:

```ruby
# frozen_string_literal: true

# Builds an ad-hoc-signed Amperfy .ipa from Amperfy.xcodeproj, together with the
# OTA manifest.plist that an `itms-services://` link points at. Used by ../../deploy.
#
# The bundle ID and team come from Config/Local.xcconfig (gitignored), which
# overrides the committed defaults in Config/Amperfy.xcconfig. Ad hoc builds
# install from Safari with no cable, but only on devices registered on the
# portal before the build, and only once the App ID exists there (automatic
# signing creates certificates and profiles, not App IDs). CarPlay audio is an
# Apple-granted entitlement this team lacks, so this fork drops it from
# Amperfy/Amperfy.entitlements.
#
# AMPERFY_UNSIGNED=1 archives without signing and zips the .app into Payload/
# with ditto, so a broken signing setup never blocks getting a binary. That
# .ipa cannot be installed from Safari.

require "fileutils"
require "shellwords"
require "tmpdir"

module IpaBuilder
  APP_NAME  = "Amperfy"
  SCHEME    = "Amperfy"
  REPO_ROOT = File.expand_path(File.join(__dir__, "..", ".."))
  PROJECT   = "Amperfy.xcodeproj"
  PBXPROJ   = File.join(REPO_ROOT, PROJECT, "project.pbxproj")
  XCCONFIGS = [
    File.join(REPO_ROOT, "Config", "Local.xcconfig"),
    File.join(REPO_ROOT, "Config", "Amperfy.xcconfig"),
  ].freeze

  module_function

  def bold(str) = "\e[1m#{str}\e[0m"
  def green(str) = "\e[32m#{str}\e[0m"
  def red(str) = "\e[31m#{str}\e[0m"
  def step(msg) = puts "\n#{bold("==> #{msg}")}"

  def die(msg)
    warn red("error: #{msg}")
    exit 1
  end

  def run(cmd, chdir:, hint: nil)
    puts "    $ #{cmd}"
    system(cmd, chdir: chdir) or die("command failed: #{cmd}#{hint ? "\n#{hint}" : ""}")
  end

  def unsigned? = ENV["AMPERFY_UNSIGNED"] == "1"

  # A build setting as Xcode resolves it: the first file (Local.xcconfig) with a
  # non-empty value wins over the committed defaults.
  def xcconfig_value(key, paths: XCCONFIGS)
    paths.each do |path|
      next unless File.exist?(path)

      value = File.read(path)[/^[ \t]*#{Regexp.escape(key)}[ \t]*=[ \t]*(\S*)/, 1]
      return value if value && !value.empty?
    end
    nil
  end

  def bundle_id
    xcconfig_value("AMPERFY_BUNDLE_ID") or die("no AMPERFY_BUNDLE_ID in Config/Local.xcconfig or Config/Amperfy.xcconfig")
  end

  # AMPERFY_TEAM_ID overrides Config/Local.xcconfig for a one-off.
  def team_id
    id = ENV["AMPERFY_TEAM_ID"] || xcconfig_value("DEVELOPMENT_TEAM")
    die("no DEVELOPMENT_TEAM in Config/Local.xcconfig and no AMPERFY_TEAM_ID set (see scripts/deploy/README.md)") unless id
    id
  end

  # xcodebuild needs a full Xcode, not the Command Line Tools.
  def resolve_developer_dir
    env = ENV["DEVELOPER_DIR"]
    return env if env && Dir.exist?(env)

    xcode = Dir.glob("/Applications/Xcode*.app").max
    die("no Xcode.app found; install Xcode or set DEVELOPER_DIR") unless xcode
    File.join(xcode, "Contents", "Developer")
  end

  # Over SSH, or after the Mac slept, the login keychain is locked, and the
  # archive would die at its first CodeSign step (errSecInternalComponent) after
  # minutes of compiling. Probe by signing a throwaway copy of /usr/bin/true; if
  # that fails, unlock the keychain (prompts for the login password) and retry.
  def ensure_codesign_can_sign!
    return if unsigned?

    probe = File.join(Dir.tmpdir, "#{APP_NAME}-codesign-probe-#{Process.pid}")
    FileUtils.cp("/usr/bin/true", probe)
    sign = "codesign -f -s 'Apple Development' #{Shellwords.escape(probe)} >/dev/null 2>&1"
    return if system(sign)

    puts red("    codesign cannot use your signing key -- the login keychain is probably locked.")
    keychain = File.expand_path("~/Library/Keychains/login.keychain-db")
    system("security unlock-keychain #{Shellwords.escape(keychain)}") or die("could not unlock the login keychain")
    system(sign) or die("codesign still fails after unlocking; try: codesign -f -s 'Apple Development' /some/file")
  ensure
    FileUtils.rm_f(probe) if probe
  end

  def signing_hint
    "If this is a signing failure, check that:\n" \
    "  - the Apple ID for team #{team_id} is added in Xcode -> Settings -> Accounts;\n" \
    "  - the device is registered on developer.apple.com (ad hoc only installs on devices registered before the build);\n" \
    "  - the App ID #{bundle_id} exists on the portal (automatic signing creates certificates and profiles, not App IDs).\n" \
    "  AMPERFY_UNSIGNED=1 ./deploy still produces an unsigned binary."
  end

  def xml_escape(str) = str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

  # `release-testing` is Xcode 15.3+'s name for ad hoc. thinning <none> keeps one
  # universal .ipa that a single URL can serve. The `manifest` dict makes
  # xcodebuild write manifest.plist, so it can never drift from the binary;
  # appURL must be the .ipa's final public URL, known before the build.
  def export_options_plist(path, manifest:, team: team_id)
    File.write(path, <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>method</key><string>release-testing</string>
        <key>teamID</key><string>#{xml_escape(team)}</string>
        <key>signingStyle</key><string>automatic</string>
        <key>stripSwiftSymbols</key><true/>
        <key>thinning</key><string>&lt;none&gt;</string>
        <key>destination</key><string>export</string>
        <key>manifest</key>
        <dict>
          <key>appURL</key><string>#{xml_escape(manifest[:app_url])}</string>
          <key>displayImageURL</key><string>#{xml_escape(manifest[:icon_url])}</string>
          <key>fullSizeImageURL</key><string>#{xml_escape(manifest[:icon_url])}</string>
        </dict>
      </dict>
      </plist>
    PLIST
    path
  end

  # Command-line build settings. The URLs go here and not in an xcconfig,
  # because an xcconfig reads the // in a URL as a comment.
  def xcodebuild_settings(team:, ota_manifest_url:, devlog_url:, unsigned:)
    settings = [unsigned ? "CODE_SIGNING_ALLOWED=NO" : "DEVELOPMENT_TEAM=#{Shellwords.escape(team)}"]
    settings << "AMPERFY_OTA_MANIFEST_URL=#{Shellwords.escape(ota_manifest_url)}" if ota_manifest_url
    settings << "AMPERFY_DEVLOG_URL=#{Shellwords.escape(devlog_url)}" if devlog_url
    settings
  end

  # Returns the .ipa path. The caller owns (and removes) File.dirname(ipa), where
  # a signed export also writes manifest.plist.
  def build(manifest:, ota_manifest_url: nil, devlog_url: nil)
    ENV["DEVELOPER_DIR"] = resolve_developer_dir
    puts "    DEVELOPER_DIR=#{ENV['DEVELOPER_DIR']}"

    work    = Dir.mktmpdir("#{APP_NAME}-ipa-")
    archive = File.join(work, "#{APP_NAME}.xcarchive")
    settings = xcodebuild_settings(team: unsigned? ? nil : team_id, ota_manifest_url: ota_manifest_url,
                                   devlog_url: devlog_url, unsigned: unsigned?)
    hint = unsigned? ? nil : signing_hint

    step "Archiving (xcodebuild)#{unsigned? ? ' [UNSIGNED]' : ''}"
    run(
      "xcodebuild -project #{PROJECT} -scheme #{SCHEME} -configuration Release " \
      "-destination 'generic/platform=iOS' -archivePath #{Shellwords.escape(archive)} " \
      "#{settings.join(' ')} -allowProvisioningUpdates archive",
      chdir: REPO_ROOT, hint: hint
    )
    die("archive not produced: #{archive}") unless Dir.exist?(archive)

    return package_unsigned(archive, work) if unsigned?

    step "Exporting signed .ipa (ad hoc)"
    options = export_options_plist(File.join(work, "ExportOptions.plist"), manifest: manifest)
    run(
      "xcodebuild -exportArchive -archivePath #{Shellwords.escape(archive)} " \
      "-exportPath #{Shellwords.escape(work)} -exportOptionsPlist #{Shellwords.escape(options)} " \
      "-allowProvisioningUpdates",
      chdir: REPO_ROOT, hint: hint
    )

    ipa = File.join(work, "#{APP_NAME}.ipa")
    die("export produced no .ipa in #{work} (see the xcodebuild output above).\n#{hint}") unless File.exist?(ipa)
    ipa
  end

  # ditto --keepParent keeps Payload/ at the zip root and preserves the
  # symlinks inside embedded frameworks, which plain zip can mangle.
  def package_unsigned(archive, work)
    app = File.join(archive, "Products", "Applications", "#{APP_NAME}.app")
    die("no #{APP_NAME}.app inside archive: #{app}") unless Dir.exist?(app)

    step "Packaging .ipa (unsigned)"
    payload = File.join(work, "Payload")
    FileUtils.mkdir_p(payload)
    FileUtils.cp_r(app, payload)
    ipa = File.join(work, "#{APP_NAME}.ipa")
    run("ditto -c -k --sequesterRsrc --keepParent #{Shellwords.escape(payload)} #{Shellwords.escape(ipa)}", chdir: work)
    ipa
  end
end
```

- [ ] **Step 4: Run the test and check that it passes**

Run: `ruby scripts/deploy/ipa_builder_test.rb`
Expected: `4 runs, ... 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add scripts/deploy/ipa_builder.rb scripts/deploy/ipa_builder_test.rb
git commit -m "feat(deploy): codesign probe, unsigned fallback, xcconfig signing values

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Uploader requires AMPERFY_UPLOAD_BASE (from .env)

**Files:**
- Modify: `scripts/deploy/uploader.rb`

- [ ] **Step 1: Replace `DEFAULT_BASE` and `base_url`.** In `scripts/deploy/uploader.rb`, delete the line `DEFAULT_BASE = "https://files.chiq.me"`. Replace the line
`def base_url = ENV.fetch("AMPERFY_UPLOAD_BASE", DEFAULT_BASE).sub(%r{/+\z}, "")` with:

```ruby
  # Public URL of the file_server that serves publish_dir, from .env
  # (AMPERFY_UPLOAD_BASE=https://files.chiq.me). No default: a wrong guess would
  # bake broken URLs into the manifest and the app.
  def base_url
    base = ENV["AMPERFY_UPLOAD_BASE"].to_s
    IpaBuilder.die("set AMPERFY_UPLOAD_BASE (in .env) to the public URL of your file server") if base.empty?
    base.sub(%r{/+\z}, "")
  end
```

Also change the top comment's "file_to_s3 service" to "file_server service" (in both places in this file) and add this sentence to the comment: `Publishing by copying, not over HTTP: request bodies past ~12 MB stall in the Cloudflare tunnel and come back as 524s.`

- [ ] **Step 2: Verify**

```bash
ruby -r./scripts/deploy/uploader -e 'puts Uploader.base_url' ; echo "exit=$?"
AMPERFY_UPLOAD_BASE=https://x.example/ ruby -r./scripts/deploy/uploader -e 'puts Uploader.base_url'
```
Expected: first prints `error: set AMPERFY_UPLOAD_BASE ...` and `exit=1` (this snippet doesn't load .env); the second prints `https://x.example`.

- [ ] **Step 3: Commit**

```bash
git add scripts/deploy/uploader.rb
git commit -m "feat(deploy): take the public base URL from AMPERFY_UPLOAD_BASE

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Rewrite ./deploy on top of the modules

**Files:**
- Rewrite: `deploy` (keep it executable: `chmod +x deploy`)

- [ ] **Step 1: Replace the whole of `deploy` with:**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# deploy
#
# One-shot release of this Amperfy fork over Safari OTA install: no App Store,
# TestFlight or cable.
#
#   1. bump MARKETING_VERSION / CURRENT_PROJECT_VERSION of the app target
#   2. build an ad-hoc-signed .ipa + OTA manifest      (scripts/deploy/ipa_builder.rb)
#   3. publish .ipa, icon, manifest and install page into file_server's files/ dir
#   4. commit the bump, tag amperfy-ota-vX.Y.Z, push branch + tags to `github`
#
# Usage:
#   ./deploy                      # bump patch (2.1.2 -> 2.1.3)
#   ./deploy patch|minor|major
#   ./deploy 2.2.0                # explicit version
#   ./deploy --yes                # skip the confirmation prompt
#   ./deploy --summary "Faster search" --note "Debounced typing" --note "..."
#                                 # release notes; default: commit subjects since the last tag
#   ./deploy --devlog             # instrumented build; DevLog -> scripts/devlog/server.py on :19486
#                                 # (AMPERFY_DEVLOG_PORT overrides the port, AMPERFY_DEVLOG_URL the whole URL)
#   AMPERFY_UNSIGNED=1 ./deploy   # unsigned build only: saves build/Amperfy-X.Y.Z-unsigned.ipa,
#                                 # publishes, commits and pushes nothing
#
# Setup (both gitignored; see scripts/deploy/README.md):
#   .env                   AMPERFY_UPLOAD_BASE=https://files.chiq.me (required)
#                          AMPERFY_PUBLISH_DIR=... (optional, default ../../file_server/files)
#   Config/Local.xcconfig  AMPERFY_BUNDLE_ID and DEVELOPMENT_TEAM, overriding Config/Amperfy.xcconfig
#
# The install page, manifest and icon have fixed names, so one Home Screen
# bookmark (or the app's Install Latest quick action) installs the newest
# release forever. Only the .ipa is versioned.

require_relative "scripts/deploy/ipa_builder"
require_relative "scripts/deploy/uploader"
require_relative "scripts/deploy/versioning"
require_relative "scripts/deploy/release_support"
require_relative "scripts/deploy/install_page"
require "fileutils"
require "shellwords"

B = IpaBuilder
R = ReleaseSupport
REPO_ROOT   = B::REPO_ROOT
PBXPROJ_REL = "Amperfy.xcodeproj/project.pbxproj"
# `github` is grillermo/amperfy. `origin` is upstream BLeeEZ/amperfy: never push there.
REMOTE      = "github"
BRANCH      = "master" # upstream's default branch

# .env first: the URLs below and the publish dir read it.
R.load_dotenv(File.join(REPO_ROOT, ".env"))

PINNED_MANIFEST = "amperfy-manifest.plist"
PINNED_INSTALL  = "amperfy-install.html"
PINNED_ICON     = "amperfy-icon.png"
ICON_SOURCE     = File.join(REPO_ROOT, "scripts/deploy/icon.png") # 1024 px, from AmperfyKit/Assets/AmperfyAppIcon.icon

MANIFEST_URL = "#{Uploader.base_url}/files/#{PINNED_MANIFEST}"
INSTALL_URL  = "#{Uploader.base_url}/files/#{PINNED_INSTALL}"
ICON_URL     = "#{Uploader.base_url}/files/#{PINNED_ICON}"
ITMS_URL     = "itms-services://?action=download-manifest&url=#{MANIFEST_URL}"

# --- flags -----------------------------------------------------------------------

ASSUME_YES = !ARGV.delete("--yes").nil?
DEVLOG     = !ARGV.delete("--devlog").nil?

# Repeatable "--flag value" / "--flag=value" options, pulled out of ARGV so the
# version argument stays positional wherever it sits.
def take_option(argv, *names)
  values = []
  i = 0
  while i < argv.length
    arg = argv[i]
    if names.include?(arg)
      value = argv[i + 1]
      B.die("#{arg} needs a value") if value.nil? || value.start_with?("--")
      values << value
      argv.slice!(i, 2)
    elsif (eq = arg.match(/\A(--[a-z-]+)=(.*)\z/m)) && names.include?(eq[1])
      values << eq[2]
      argv.slice!(i, 1)
    else
      i += 1
    end
  end
  values
end

SUMMARY = take_option(ARGV, "--summary", "-s").last
NOTES   = R.clean_notes(take_option(ARGV, "--note", "--notes", "-n"))

unknown = ARGV.find { |a| a.start_with?("-") }
B.die("unknown option #{unknown} (see the header of ./deploy)") if unknown
B.die("too many arguments: #{ARGV.join(' ')}") if ARGV.length > 1

def git(args) = `git -C #{REPO_ROOT.shellescape} #{args}`

# --- preflight: nothing here touches the working tree ------------------------------

Uploader.check_publish_dir!

branch = git("rev-parse --abbrev-ref HEAD").strip
B.die("on branch '#{branch}', not '#{BRANCH}'; releases are cut from #{BRANCH}") unless branch == BRANCH

dirty = git("status --porcelain")
B.die("working tree is dirty -- commit or stash before releasing:\n#{dirty}") unless dirty.strip.empty?

pbxproj = B::PBXPROJ
begin
  current = Versioning.read(File.read(pbxproj))
  version = Versioning.bump(current[:marketing], ARGV[0])
rescue ArgumentError => e
  B.die(e.message)
end
build    = current[:build] + 1
tag      = "amperfy-ota-v#{version}"
asset    = "#{B::APP_NAME}-#{version}.ipa"
# Versioned name: predictable before the build (the manifest needs it) and unique
# per release. The tag check below is what stops a version shipping twice.
download = "#{Uploader.base_url}/files/#{asset}"

B.die("tag #{tag} already exists -- bump to a new version") if git("tag -l #{tag.shellescape}").strip == tag

# Unlock the keychain now, not after minutes of compiling.
B.ensure_codesign_can_sign!

last_tag    = git("describe --tags --abbrev=0 --match 'amperfy-ota-v*' 2>/dev/null").strip
range       = last_tag.empty? ? "-n 20 HEAD" : "#{last_tag}..HEAD"
subjects    = git("log --no-merges --pretty=%s #{range}").lines
DESCRIPTION = R.release_notes(version: version, summary: SUMMARY, notes: NOTES, subjects: subjects)

devlog_url = DEVLOG ? R.devlog_url(ENV, `scutil --get LocalHostName`.strip) : nil

puts B.bold("\n==> Releasing #{B::APP_NAME} (OTA) #{current[:marketing]} -> #{version} (build #{build})")
puts DESCRIPTION.lines.map { |l| "      #{l}" }.join
puts "\n    Install page: #{INSTALL_URL}"
puts "    DevLog: #{devlog_url}  (start scripts/devlog/server.py first)" if devlog_url
puts B.red("    UNSIGNED: builds only; nothing is published, committed or pushed") if B.unsigned?

unless ASSUME_YES
  print "\n    Continue? [y/N] "
  B.die("aborted") unless $stdin.gets.to_s.strip.downcase.start_with?("y")
end

# --- write the bump; restore it on any exit before the commit ----------------------
#
# A leftover bump would fail the *next* run's clean-tree check with an error
# pointing nowhere near this run. B.die calls exit, so at_exit covers a failed
# build, a failed publish, an exception and Ctrl-C alike.

original  = File.read(pbxproj)
committed = false
at_exit { File.write(pbxproj, original) unless committed }

File.write(pbxproj, Versioning.write(original, version: version, build: build))

# --- build -----------------------------------------------------------------------

ipa  = B.build(manifest: { app_url: download, icon_url: ICON_URL }, ota_manifest_url: MANIFEST_URL, devlog_url: devlog_url)
work = File.dirname(ipa)
at_exit { FileUtils.rm_rf(work) } # the build's temp dir goes on every exit path
puts B.green("    #{asset} — #{(File.size(ipa) / 1_048_576.0).round(1)} MB")

# The Amperfy scheme runs SwiftFormat as a build phase. Anything it rewrote
# besides the bump would ride along unreleased, so stop before publishing.
reformatted = git("status --porcelain").lines.map(&:strip).reject { |l| l.end_with?(PBXPROJ_REL) }
B.die("the build left changes behind (SwiftFormat?) -- commit them and re-run:\n#{reformatted.join("\n")}") unless reformatted.empty?

if B.unsigned?
  out = File.join(REPO_ROOT, "build", "#{B::APP_NAME}-#{version}-unsigned.ipa") # build/ is gitignored
  FileUtils.mkdir_p(File.dirname(out))
  FileUtils.cp(ipa, out)
  puts B.green("\n✓ Unsigned .ipa: #{out}")
  puts "    Not installable from Safari. Nothing published or committed; the version bump was rolled back."
  exit 0
end

built_manifest = File.join(work, "manifest.plist")
B.die("export produced no manifest.plist -- cannot publish the OTA route") unless File.exist?(built_manifest)

# --- publish: each file references the one before it ----------------------------------
# The manifest points at the .ipa and the page at the manifest, so a manifest
# published ahead of its binary would point at a 404.

B.step "Publishing the .ipa"
puts "    #{Uploader.upload(ipa, name: asset)}"
B.step "Publishing the icon"
puts "    #{Uploader.upload(ICON_SOURCE, name: PINNED_ICON)}"
B.step "Publishing the OTA manifest"
puts "    #{Uploader.upload(built_manifest, name: PINNED_MANIFEST)}"

B.step "Publishing the install page"
page = File.join(work, PINNED_INSTALL)
File.write(page, InstallPage.render(app_name: B::APP_NAME, version: version, build: build, icon_url: ICON_URL,
                                    itms_url: ITMS_URL, notes: DESCRIPTION, bundle_id: B.bundle_id))
puts "    #{Uploader.upload(page, name: PINNED_INSTALL)}"

# --- commit, tag, push ------------------------------------------------------------

B.step "Committing + pushing"
B.run("git add #{PBXPROJ_REL.shellescape}", chdir: REPO_ROOT)
B.run("git commit -m #{"Release Amperfy OTA #{tag}\n\nCo-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>".shellescape}", chdir: REPO_ROOT)
committed = true # the bump lives in a commit now; at_exit must not undo it
B.run("git tag #{tag.shellescape}", chdir: REPO_ROOT)

push = "git push #{REMOTE} #{BRANCH} --tags"
puts "    $ #{push}"
push_ok = system(push, chdir: REPO_ROOT)
unless push_ok
  local  = git("rev-parse HEAD").strip
  remote = git("ls-remote #{REMOTE} refs/heads/#{BRANCH}").split.first.to_s
  B.die("push failed (remote at #{remote.empty? ? 'nothing' : remote[0, 7]}, we are at #{local[0, 7]})") unless
    R.push_succeeded?(push_ok: false, local_head: local, remote_head: remote)
  puts B.green("    remote already at #{local[0, 7]}; continuing")
end

puts B.green("\n✓ Published #{B::APP_NAME} OTA #{version}")
puts B.bold("\n    Install from Safari on the device:\n    #{INSTALL_URL}")
puts "    itms link: #{ITMS_URL}"
```

- [ ] **Step 2: Syntax check and run all the Ruby tests**

```bash
ruby -c deploy && for t in scripts/deploy/*_test.rb; do ruby "$t" || exit 1; done
```
Expected: `Syntax OK`, then every suite reports `0 failures, 0 errors`.

- [ ] **Step 3: Commit**

```bash
git add deploy
git commit -m "feat(deploy): full OTA pipeline (.env, codesign probe, unsigned, devlog, push check)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Verify the preflight failures (nothing is built or published)

Every command below must stop **before** "Archiving". Afterwards `git status --porcelain` must print nothing and `git tag -l 'amperfy-ota-v2.1.3'` must print nothing.

- [ ] **Step 1: Bad arguments**

```bash
./deploy banana --yes; echo "exit=$?"
./deploy --bogus; echo "exit=$?"
./deploy 1.0 2.0; echo "exit=$?"
./deploy --note; echo "exit=$?"
```
Expected: `bad argument 'banana'`, `unknown option --bogus`, `too many arguments`, `--note needs a value`. Each exits 1.

- [ ] **Step 2: Missing upload base and missing publish dir**

```bash
AMPERFY_UPLOAD_BASE= ./deploy --yes; echo "exit=$?"
AMPERFY_PUBLISH_DIR=/nonexistent ./deploy --yes; echo "exit=$?"
```
Expected: `set AMPERFY_UPLOAD_BASE (in .env)` and `files/ directory was not found at /nonexistent`.

- [ ] **Step 3: Dirty tree, wrong branch, existing tag**

```bash
touch preflight-scratch; ./deploy --yes; echo "exit=$?"; rm preflight-scratch
git switch -c ota-preflight-test && ./deploy --yes; echo "exit=$?"; git switch master && git branch -D ota-preflight-test
./deploy 2.1.2 --yes; echo "exit=$?"
```
Expected: `working tree is dirty`, `on branch 'ota-preflight-test', not 'master'`, `tag amperfy-ota-v2.1.2 already exists`.

- [ ] **Step 4: The prompt preview, then abort (exercises the codesign probe)**

```bash
echo n | ./deploy --summary "Preview" --note "one" --note "two"; echo "exit=$?"
```
Expected: `Releasing Amperfy (OTA) 2.1.2 -> 2.1.3 (build 3)`, the notes `Preview / • one / • two`, the install page URL `https://files.chiq.me/files/amperfy-install.html`, then `error: aborted`, exit 1. If the codesign probe asks for the keychain password (it runs `security unlock-keychain`), this session can't type it. Stop and ask the user to run this in a terminal on the macmini, then retry:

```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

Also check the default notes: `echo n | ./deploy` lists commit subjects since `amperfy-ota-v2.1.2` with no `Release …`/`Merge`/`Bump`/`wip` lines, at most 8.

- [ ] **Step 5: Confirm nothing changed**

Run: `git status --porcelain; git tag -l 'amperfy-ota-v2.1.3'`
Expected: no output. (Nothing to commit in this task.)

---

### Task 9: OTAInstallLatest, the pure URL mapping (Swift, TDD)

**Files:**
- Create: `AmperfyKit/Common/OTAInstallLatest.swift`
- Create: `AmperfyKitTests/Cases/Common/OTAInstallLatestTest.swift`
- Modify: `Amperfy.xcodeproj/project.pbxproj` (register both)

- [ ] **Step 1: Write the failing test** `AmperfyKitTests/Cases/Common/OTAInstallLatestTest.swift`:

```swift
//
//  OTAInstallLatestTest.swift
//  AmperfyKitTests
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

@testable import AmperfyKit
import XCTest

class OTAInstallLatestTest: XCTestCase {
  let manifest = "https://files.example.com/files/amperfy-manifest.plist"

  func testNoActionWithoutAManifestURL() {
    let key = OTAInstallLatest.manifestURLInfoKey
    let cases: [[String: Any]?] = [
      nil,
      [:],
      [key: ""],
      [key: "   "],
      [key: "$(AMPERFY_OTA_MANIFEST_URL)"],
      [key: "http://files.example.com/files/amperfy-manifest.plist"],
      [key: 42],
    ]
    for info in cases {
      XCTAssertNil(OTAInstallLatest.installURL(infoDictionary: info), "\(String(describing: info))")
      XCTAssertFalse(OTAInstallLatest.isAvailable(infoDictionary: info))
    }
  }

  func testInstallURLPointsAtThePinnedManifest() {
    let info: [String: Any] = [OTAInstallLatest.manifestURLInfoKey: manifest]
    XCTAssertEqual(
      OTAInstallLatest.installURL(infoDictionary: info),
      URL(string: "itms-services://?action=download-manifest&url=\(manifest)")
    )
    XCTAssertTrue(OTAInstallLatest.isAvailable(infoDictionary: info))
  }

  @MainActor
  func testShortcutTypeMatchesTheQuickActionsHandler() {
    XCTAssertEqual(
      QuickActionsHandler.QuickActionType.installLatestAction.rawValue,
      OTAInstallLatest.shortcutType
    )
  }
}
```

- [ ] **Step 2: Create the source file** with a stub, so only the test fails and not the project: `AmperfyKit/Common/OTAInstallLatest.swift`:

```swift
//
//  OTAInstallLatest.swift
//  AmperfyKit
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

import Foundation

public enum OTAInstallLatest {
  public static let manifestURLInfoKey = "AmperfyOTAManifestURL"
  public static let shortcutType = "InstallLatestAction"

  public static func installURL(infoDictionary: [String: Any]?) -> URL? {
    nil
  }

  public static func isAvailable(infoDictionary: [String: Any]?) -> Bool {
    false
  }
}
```

- [ ] **Step 3: Register both files in the pbxproj**

```bash
ruby - <<'RUBY'
path = "Amperfy.xcodeproj/project.pbxproj"
pbx = File.read(path)
def insert_after!(pbx, anchor, text)
  n = pbx.scan(anchor).length
  abort "expected exactly 1 match, got #{n}: #{anchor.inspect}" unless n == 1
  pbx.sub!(anchor) { anchor + text }
end
# AmperfyKit: OTAInstallLatest.swift (fileRef ...02, buildFile ...03), next to QuickActionsHandler.swift
insert_after!(pbx, "505CA1F52B848B8300AA81CD /* QuickActionsHandler.swift in Sources */ = {isa = PBXBuildFile; fileRef = 505CA1F42B848B8300AA81CD /* QuickActionsHandler.swift */; };\n",
  "\t\t0CA0FF1C0000000000000003 /* OTAInstallLatest.swift in Sources */ = {isa = PBXBuildFile; fileRef = 0CA0FF1C0000000000000002 /* OTAInstallLatest.swift */; };\n")
insert_after!(pbx, "505CA1F42B848B8300AA81CD /* QuickActionsHandler.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = QuickActionsHandler.swift; sourceTree = \"<group>\"; };\n",
  "\t\t0CA0FF1C0000000000000002 /* OTAInstallLatest.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OTAInstallLatest.swift; sourceTree = \"<group>\"; };\n")
insert_after!(pbx, "505CA1F42B848B8300AA81CD /* QuickActionsHandler.swift */,\n",
  "\t\t\t\t0CA0FF1C0000000000000002 /* OTAInstallLatest.swift */,\n")
insert_after!(pbx, "505CA1F52B848B8300AA81CD /* QuickActionsHandler.swift in Sources */,\n",
  "\t\t\t\t0CA0FF1C0000000000000003 /* OTAInstallLatest.swift in Sources */,\n")
# AmperfyKitTests: OTAInstallLatestTest.swift (fileRef ...06, buildFile ...07), next to ShareSongActionTest.swift
insert_after!(pbx, "B5A5CE010000000000000001 /* ShareSongActionTest.swift in Sources */ = {isa = PBXBuildFile; fileRef = B5A5CE010000000000000002 /* ShareSongActionTest.swift */; };\n",
  "\t\t0CA0FF1C0000000000000007 /* OTAInstallLatestTest.swift in Sources */ = {isa = PBXBuildFile; fileRef = 0CA0FF1C0000000000000006 /* OTAInstallLatestTest.swift */; };\n")
insert_after!(pbx, "B5A5CE010000000000000002 /* ShareSongActionTest.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ShareSongActionTest.swift; sourceTree = \"<group>\"; };\n",
  "\t\t0CA0FF1C0000000000000006 /* OTAInstallLatestTest.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OTAInstallLatestTest.swift; sourceTree = \"<group>\"; };\n")
insert_after!(pbx, "B5A5CE010000000000000002 /* ShareSongActionTest.swift */,\n",
  "\t\t\t\t0CA0FF1C0000000000000006 /* OTAInstallLatestTest.swift */,\n")
insert_after!(pbx, "B5A5CE010000000000000001 /* ShareSongActionTest.swift in Sources */,\n",
  "\t\t\t\t0CA0FF1C0000000000000007 /* OTAInstallLatestTest.swift in Sources */,\n")
File.write(path, pbx)
puts "ok"
RUBY
xcodebuild -list -project Amperfy.xcodeproj >/dev/null && echo "project parses"
```
Expected: `ok`, `project parses`.

- [ ] **Step 4: Run the test and check that it fails**

```bash
xcodebuild test -project Amperfy.xcodeproj -scheme Amperfy \
  -destination 'platform=iOS Simulator,name=iPhone 16e' \
  -only-testing:AmperfyKitTests/OTAInstallLatestTest 2>&1 | tail -30
```
Expected: `testInstallURLPointsAtThePinnedManifest` fails; the other two pass. (The first build compiles swiftformat and can take many minutes. If `-only-testing` complains about the missing `AmperfyTests` / `AmperfyUITests` targets that the scheme lists, run `xcodebuild -project Amperfy.xcodeproj -list` to check which targets exist, and use the identifier it accepts.)

- [ ] **Step 5: Implement.** Replace the body of `OTAInstallLatest.swift` (keep the header) with:

```swift
import Foundation

/// The "Install Latest" Home Screen quick action of OTA builds.
///
/// `./deploy` passes its pinned manifest URL as the `AMPERFY_OTA_MANIFEST_URL`
/// build setting, which lands in Info.plist under `manifestURLInfoKey`. Every
/// release republishes the manifest under that same name, so the link always
/// installs the newest build. Builds made any other way leave the key empty and
/// offer no action.
public enum OTAInstallLatest {
  public static let manifestURLInfoKey = "AmperfyOTAManifestURL"
  /// `UIApplicationShortcutItem.type`; matches `QuickActionsHandler.QuickActionType.installLatestAction`.
  public static let shortcutType = "InstallLatestAction"

  /// The same link as the install page's button. iOS only installs from an
  /// https manifest, so anything else counts as "no action".
  public static func installURL(infoDictionary: [String: Any]?) -> URL? {
    guard let raw = infoDictionary?[manifestURLInfoKey] as? String else { return nil }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let manifest = URL(string: value),
          manifest.scheme?.lowercased() == "https",
          manifest.host?.isEmpty == false
    else { return nil }
    return URL(string: "itms-services://?action=download-manifest&url=\(manifest.absoluteString)")
  }

  public static func isAvailable(infoDictionary: [String: Any]?) -> Bool {
    installURL(infoDictionary: infoDictionary) != nil
  }
}
```

- [ ] **Step 6: Run the test and check that it passes**

Same command as Step 4. Expected: `** TEST SUCCEEDED **`, 3 tests passed. Then run `git status` and include any SwiftFormat rewrites of these two files.

- [ ] **Step 7: Commit**

```bash
git add AmperfyKit/Common/OTAInstallLatest.swift AmperfyKitTests/Cases/Common/OTAInstallLatestTest.swift Amperfy.xcodeproj/project.pbxproj
git commit -m "feat: add OTAInstallLatest Info.plist to itms-services mapping

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Dynamic Install Latest quick action (replaces the static one)

**Files:**
- Modify: `Amperfy/Info.plist`
- Modify: `AmperfyKit/Common/QuickActionsHandler.swift`
- Modify: `Amperfy/SceneDelegate.swift`

- [ ] **Step 1: Info.plist.** In `Amperfy/Info.plist`, delete the whole `UIApplicationShortcutItems` key and its `<array>…</array>` (the 11 lines that commit d42720c6 added, just before `<key>UIApplicationSceneManifest</key>`). In their place, add:

```xml
	<!-- Set by ./deploy (command-line build setting). Empty: no Install Latest quick action (OTAInstallLatest). -->
	<key>AmperfyOTAManifestURL</key>
	<string>$(AMPERFY_OTA_MANIFEST_URL)</string>
```
Run `plutil -lint Amperfy/Info.plist`. Expected: `OK`.

- [ ] **Step 2: QuickActionsHandler.** In `AmperfyKit/Common/QuickActionsHandler.swift`:

(a) Replace the enum case comment and delete the hard-coded URL:

```swift
    /// Static item from Info.plist. `./deploy` republishes the OTA manifest under
    /// this pinned name on every release, so it always installs the newest build.
    case installLatestAction = "InstallLatestAction"
  }

  static let installLatestURL =
    URL(
      string: "itms-services://?action=download-manifest&url=https://files.chiq.me/files/amperfy-manifest.plist"
    )!
```
becomes
```swift
    /// Registered only in builds made by `./deploy`; see OTAInstallLatest.
    case installLatestAction = "InstallLatestAction"
  }
```

(b) In `configureQuickActions()`, inside the `guard storage.settings.app.isLibrarySynced else {` block, change `application.shortcutItems = quickActions` to `application.shortcutItems = quickActions + installLatestQuickActions()`. Change the **last** line of the function, `application.shortcutItems = quickActions`, the same way.

(c) In `handleShortCutItem`, change
```swift
      case .installLatestAction:
        application.open(Self.installLatestURL)
```
to
```swift
      case .installLatestAction:
        installLatest()
```

(d) Add these methods right after `handleSavedShortCutItemIfSaved()`:

```swift
  /// Install Latest must work before an account exists and while the library
  /// updates, so SceneDelegate calls these two ahead of its isNormalInteraction guard.
  public func handleInstallLatest(shortcutItem: UIApplicationShortcutItem) -> Bool {
    guard shortcutItem.type == QuickActionType.installLatestAction.rawValue else { return false }
    installLatest()
    return true
  }

  public func handleSavedInstallLatestIfSaved() {
    guard let item = savedShortCutItem, handleInstallLatest(shortcutItem: item) else { return }
    savedShortCutItem = nil
  }

  private func installLatestQuickActions() -> [UIApplicationShortcutItem] {
    guard OTAInstallLatest.isAvailable(infoDictionary: Bundle.main.infoDictionary) else { return [] }
    return [UIApplicationShortcutItem(
      type: QuickActionType.installLatestAction.rawValue,
      localizedTitle: "Install Latest",
      localizedSubtitle: nil,
      icon: UIApplicationShortcutIcon(systemImageName: "arrow.down.app"),
      userInfo: nil
    )]
  }

  private func installLatest() {
    guard let url = OTAInstallLatest.installURL(infoDictionary: Bundle.main.infoDictionary)
    else { return }
    application.open(url, options: [:]) { opened in
      guard opened else { return }
      // iOS replaces the app bundle under the running process, which crashes
      // it, and only starts the install once the app is left. Exiting after the
      // install prompt is up lets the install begin on its own.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        exit(0)
      }
    }
  }
```

- [ ] **Step 3: SceneDelegate.** In `Amperfy/SceneDelegate.swift`:

(a) In `windowScene(_:performActionFor:completionHandler:)`, insert before `guard appDelegate.isNormalInteraction else {`:
```swift
    if appDelegate.quickActionsManager.handleInstallLatest(shortcutItem: shortcutItem) {
      return completionHandler(true)
    }
```
(b) In `sceneDidBecomeActive(_:)`, insert before `guard appDelegate.isNormalInteraction else {`:
```swift
    // Cold launch from Install Latest: opening a URL works only once active.
    appDelegate.quickActionsManager.handleSavedInstallLatestIfSaved()
```
(c) In `scene(_:willConnectTo:options:)`, after the last line `AmperfyAppShortcuts.updateAppShortcutParameters()`, add:
```swift
    // Register Home Screen quick actions (incl. Install Latest) at launch, not
    // only on resign-active, so a fresh OTA install offers Install Latest at once.
    appDelegate.quickActionsManager.configureQuickActions()
```

(The App Intents in `Amperfy/Intents/AmperfyAppShortcuts.swift` are Siri/Shortcuts actions, a separate mechanism from Home Screen quick actions. Leave them alone.)

- [ ] **Step 4: Build and run the unit tests**

```bash
xcodebuild test -project Amperfy.xcodeproj -scheme Amperfy \
  -destination 'platform=iOS Simulator,name=iPhone 16e' \
  -only-testing:AmperfyKitTests 2>&1 | tail -30
```
Expected: `** TEST SUCCEEDED **`. If a test that existed before this plan fails, check whether it also fails on `git stash`-free HEAD~N (for example with `git worktree add /tmp/amperfy-base f96a0c9d`). Report pre-existing failures instead of fixing upstream tests. Run `git status`, and include SwiftFormat rewrites of the files you touched.

- [ ] **Step 5: Commit**

```bash
git add Amperfy/Info.plist AmperfyKit/Common/QuickActionsHandler.swift Amperfy/SceneDelegate.swift
git commit -m "feat: register Install Latest only in ./deploy builds and exit for the install

Replaces the static Info.plist shortcut and its hard-coded URL with a dynamic
item driven by AmperfyOTAManifestURL. Handled ahead of the account guard at
cold launch and from windowScene(_:performActionFor:).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: DevLog.swift (TDD) and the Info.plist key

**Files:**
- Create: `AmperfyKit/Common/DevLog.swift`
- Create: `AmperfyKitTests/Cases/Common/DevLogTest.swift`
- Modify: `Amperfy.xcodeproj/project.pbxproj`, `Amperfy/Info.plist`, `Amperfy/AppDelegate.swift`

- [ ] **Step 1: Write the failing test** `AmperfyKitTests/Cases/Common/DevLogTest.swift`:

```swift
//
//  DevLogTest.swift
//  AmperfyKitTests
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

@testable import AmperfyKit
import XCTest

class DevLogTest: XCTestCase {
  func testStaysOffWithoutAnHTTPURL() {
    let key = DevLog.urlInfoKey
    XCTAssertNil(DevLogSink(infoDictionary: nil))
    XCTAssertNil(DevLogSink(infoDictionary: [key: ""]))
    // An unexpanded build setting must not count as a URL.
    XCTAssertNil(DevLogSink(infoDictionary: [key: "$(AMPERFY_DEVLOG_URL)"]))
    XCTAssertNil(DevLogSink(infoDictionary: [key: "ftp://macmini.local/api/devlog"]))
  }

  func testTurnsOnWithAnHTTPURL() {
    XCTAssertNotNil(DevLogSink(infoDictionary: [DevLog.urlInfoKey: "http://macmini.local:19486/api/devlog"]))
  }

  func testDisabledEventDoesNotBuildItsFields() {
    // The test host's Info.plist has an empty AmperfyDevLogURL.
    XCTAssertFalse(DevLog.isEnabled)
    var built = false
    DevLog.event("test") { () -> [String: String] in
      built = true
      return [:]
    }()
    XCTAssertFalse(built)
  }
}
```

Note: if the immediately-invoked closure in `testDisabledEventDoesNotBuildItsFields` reads awkwardly or doesn't compile, write it as:
```swift
    func fields() -> [String: String] { built = true; return [:] }
    DevLog.event("test", fields())
```
That is the point of `@autoclosure`: `fields()` must not run.

- [ ] **Step 2: Create a stub** `AmperfyKit/Common/DevLog.swift` (same GPL header as in Task 9, with `DevLog.swift`):

```swift
import Foundation

public enum DevLog {
  public static let urlInfoKey = "AmperfyDevLogURL"
  public static var isEnabled: Bool { true }
  public static func event(_ kind: String, _ fields: @autoclosure () -> [String: String] = [:]) {
    _ = fields()
  }
}

final class DevLogSink: @unchecked Sendable {
  init?(infoDictionary: [String: Any]?) { nil }
}
```

- [ ] **Step 3: Register both files in the pbxproj**

```bash
ruby - <<'RUBY'
path = "Amperfy.xcodeproj/project.pbxproj"
pbx = File.read(path)
def insert_after!(pbx, anchor, text)
  n = pbx.scan(anchor).length
  abort "expected exactly 1 match, got #{n}: #{anchor.inspect}" unless n == 1
  pbx.sub!(anchor) { anchor + text }
end
# AmperfyKit: DevLog.swift (fileRef ...04, buildFile ...05)
insert_after!(pbx, "505CA1F52B848B8300AA81CD /* QuickActionsHandler.swift in Sources */ = {isa = PBXBuildFile; fileRef = 505CA1F42B848B8300AA81CD /* QuickActionsHandler.swift */; };\n",
  "\t\t0CA0FF1C0000000000000005 /* DevLog.swift in Sources */ = {isa = PBXBuildFile; fileRef = 0CA0FF1C0000000000000004 /* DevLog.swift */; };\n")
insert_after!(pbx, "505CA1F42B848B8300AA81CD /* QuickActionsHandler.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = QuickActionsHandler.swift; sourceTree = \"<group>\"; };\n",
  "\t\t0CA0FF1C0000000000000004 /* DevLog.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DevLog.swift; sourceTree = \"<group>\"; };\n")
insert_after!(pbx, "505CA1F42B848B8300AA81CD /* QuickActionsHandler.swift */,\n",
  "\t\t\t\t0CA0FF1C0000000000000004 /* DevLog.swift */,\n")
insert_after!(pbx, "505CA1F52B848B8300AA81CD /* QuickActionsHandler.swift in Sources */,\n",
  "\t\t\t\t0CA0FF1C0000000000000005 /* DevLog.swift in Sources */,\n")
# AmperfyKitTests: DevLogTest.swift (fileRef ...08, buildFile ...09)
insert_after!(pbx, "B5A5CE010000000000000001 /* ShareSongActionTest.swift in Sources */ = {isa = PBXBuildFile; fileRef = B5A5CE010000000000000002 /* ShareSongActionTest.swift */; };\n",
  "\t\t0CA0FF1C0000000000000009 /* DevLogTest.swift in Sources */ = {isa = PBXBuildFile; fileRef = 0CA0FF1C0000000000000008 /* DevLogTest.swift */; };\n")
insert_after!(pbx, "B5A5CE010000000000000002 /* ShareSongActionTest.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ShareSongActionTest.swift; sourceTree = \"<group>\"; };\n",
  "\t\t0CA0FF1C0000000000000008 /* DevLogTest.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DevLogTest.swift; sourceTree = \"<group>\"; };\n")
insert_after!(pbx, "B5A5CE010000000000000002 /* ShareSongActionTest.swift */,\n",
  "\t\t\t\t0CA0FF1C0000000000000008 /* DevLogTest.swift */,\n")
insert_after!(pbx, "B5A5CE010000000000000001 /* ShareSongActionTest.swift in Sources */,\n",
  "\t\t\t\t0CA0FF1C0000000000000009 /* DevLogTest.swift in Sources */,\n")
File.write(path, pbx)
puts "ok"
RUBY
```

- [ ] **Step 4: Add the Info.plist key** right after the `AmperfyOTAManifestURL` string from Task 10. Also add a comment above the existing `<key>NSAppTransportSecurity</key>`:

```xml
	<!-- Set by ./deploy --devlog. Empty: DevLog records nothing. -->
	<key>AmperfyDevLogURL</key>
	<string>$(AMPERFY_DEVLOG_URL)</string>
```
```xml
	<!-- Fork note: NSAllowsLocalNetworking is deliberately NOT added for the DevLog server.
	     When it is present, iOS ignores NSAllowsArbitraryLoads, which plain-HTTP media servers need;
	     arbitrary loads already allow the LAN. -->
```
Run `plutil -lint Amperfy/Info.plist`. Expected: `OK`.

- [ ] **Step 5: Run the tests and check that they fail**

```bash
xcodebuild test -project Amperfy.xcodeproj -scheme Amperfy \
  -destination 'platform=iOS Simulator,name=iPhone 16e' \
  -only-testing:AmperfyKitTests/DevLogTest 2>&1 | tail -30
```
Expected: `testTurnsOnWithAnHTTPURL` and `testDisabledEventDoesNotBuildItsFields` fail.

- [ ] **Step 6: Implement.** Replace the body of `AmperfyKit/Common/DevLog.swift` (keep the header):

```swift
import Foundation

/// Ships diagnostic events to the developer's log server
/// (`scripts/devlog/server.py`), so a device build can be debugged without Xcode.
/// Only `./deploy --devlog` bakes the server URL into Info.plist. Every other
/// build has none, and `event` then does nothing, not even build its fields.
///
/// Emitting only appends to a bounded buffer under a lock. A utility queue sends
/// once a second, and failed batches are dropped, so the code being observed
/// never waits on the network.
public enum DevLog {
  public static let urlInfoKey = "AmperfyDevLogURL"

  private static let sink = DevLogSink(infoDictionary: Bundle.main.infoDictionary)

  public static var isEnabled: Bool { sink != nil }

  public static func event(_ kind: String, _ fields: @autoclosure () -> [String: String] = [:]) {
    sink?.append(kind: kind, fields: fields())
  }

  /// Sends a file (a screenshot) that the server stores under `log/screens/<name>`.
  /// Uploads skip the record buffer, and are dropped when too many are in flight.
  public static func upload(_ name: String, _ data: Data) {
    sink?.upload(name: name, data: data)
  }
}

final class DevLogSink: @unchecked Sendable {
  private static let maxBufferedRecords = 2000
  private static let flushInterval: DispatchTimeInterval = .seconds(1)
  private static let maxUploadsInFlight = 6

  private let endpoint: URL
  private let session = UUID().uuidString
  private let build: String
  private let lock = NSLock()
  private var buffer: [[String: Any]] = []
  private let queue = DispatchQueue(label: "amperfy.devlog", qos: .utility)
  private var timer: DispatchSourceTimer?
  private var uploadsInFlight = 0

  init?(infoDictionary: [String: Any]?) {
    guard let value = infoDictionary?[DevLog.urlInfoKey] as? String,
          let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host?.isEmpty == false
    else { return nil }
    endpoint = url
    let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    let number = infoDictionary?["CFBundleVersion"] as? String ?? "?"
    build = "\(version) (\(number))"
    startTimer()
  }

  func append(kind: String, fields: [String: String]) {
    let record: [String: Any] = [
      "t": Self.timestamp(),
      "kind": kind,
      "meta": fields,
      "session": session,
      "build": build,
    ]
    lock.lock()
    if buffer.count < Self.maxBufferedRecords {
      buffer.append(record)
    }
    lock.unlock()
  }

  func upload(name: String, data: Data) {
    guard var components = URLComponents(
      url: endpoint.appendingPathComponent("screen"),
      resolvingAgainstBaseURL: false
    ) else { return }
    components.queryItems = [URLQueryItem(name: "name", value: name)]
    guard let url = components.url else { return }
    lock.lock()
    guard uploadsInFlight < Self.maxUploadsInFlight else {
      lock.unlock()
      return
    }
    uploadsInFlight += 1
    lock.unlock()
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    URLSession.shared.uploadTask(with: request, from: data) { [weak self] _, _, _ in
      guard let self else { return }
      self.lock.lock()
      self.uploadsInFlight -= 1
      self.lock.unlock()
    }.resume()
  }

  private func startTimer() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
    timer.setEventHandler { [weak self] in self?.flush() }
    self.timer = timer
    timer.resume()
  }

  private func flush() {
    lock.lock()
    let records = buffer
    buffer.removeAll(keepingCapacity: true)
    lock.unlock()
    guard !records.isEmpty,
          let body = try? JSONSerialization.data(withJSONObject: ["records": records])
    else { return }
    var request = URLRequest(url: endpoint, timeoutInterval: 5)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = body
    URLSession.shared.dataTask(with: request).resume()
  }

  private static func timestamp() -> String {
    // A formatter per call keeps this Sendable-clean; events are rare enough.
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
  }
}
```

If Swift 6 complains about `private static let sink` (a non-Sendable global), `DevLogSink` is already `@unchecked Sendable`. If it still complains, mark the property `nonisolated(unsafe) private static let sink`.

- [ ] **Step 7: Instrument launch.** In `Amperfy/AppDelegate.swift`, in `application(_:didFinishLaunchingWithOptions:)`, add right after the `if let options = launchOptions { … } else { … }` block:

```swift
    DevLog.event("app.launch")
```

- [ ] **Step 8: Run the tests and check that they pass**

Same command as Step 5, then the whole `-only-testing:AmperfyKitTests`. Expected: `** TEST SUCCEEDED **`. Run `git status` and include SwiftFormat rewrites of your files.

- [ ] **Step 9: Commit**

```bash
git add AmperfyKit/Common/DevLog.swift AmperfyKitTests/Cases/Common/DevLogTest.swift Amperfy.xcodeproj/project.pbxproj Amperfy/Info.plist Amperfy/AppDelegate.swift
git commit -m "feat: add DevLog for ./deploy --devlog diagnostics builds

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: scripts/devlog/server.py (TDD)

**Files:**
- Create: `scripts/devlog/server.py` (executable)
- Test: `scripts/devlog/server_test.py`

- [ ] **Step 1: Write the failing test** `scripts/devlog/server_test.py`:

```python
"""Tests for server.py. Run: python3 -I scripts/devlog/server_test.py"""

import http.client
import importlib.util
import json
import os
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path

TMP = tempfile.mkdtemp()
os.environ["AMPERFY_DEVLOG_FILE"] = str(Path(TMP) / "log" / "devlog.jsonl")
spec = importlib.util.spec_from_file_location("devlog_server", Path(__file__).with_name("server.py"))
server = importlib.util.module_from_spec(spec)
spec.loader.exec_module(server)


class ServerTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        server.prepare()
        cls.httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
        cls.port = cls.httpd.server_address[1]
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()

    def request(self, method, path, body=b"", headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        conn.request(method, path, body=body, headers=headers or {})
        resp = conn.getresponse()
        data = resp.read()
        conn.close()
        return resp.status, data

    def test_default_port_is_amperfys_own(self):
        # vvterm uses 19480; each app has its own port so servers run side by side.
        if "AMPERFY_DEVLOG_PORT" not in os.environ:
            self.assertEqual(server.PORT, 19486)

    def test_health(self):
        self.assertEqual(self.request("GET", "/api/devlog/health"), (200, b"ok\n"))
        self.assertEqual(self.request("GET", "/health"), (200, b"ok\n"))

    def test_records_are_appended(self):
        body = json.dumps({"records": [{"kind": "app.launch", "meta": {}}]}).encode()
        status, _ = self.request("POST", "/api/devlog", body, {"Content-Type": "application/json"})
        self.assertEqual(status, 204)
        lines = server.LOG_PATH.read_text().splitlines()
        self.assertIn("app.launch", lines[-1])

    def test_bad_payload_and_size(self):
        self.assertEqual(self.request("POST", "/api/devlog", b"nope")[0], 400)
        self.assertEqual(self.request("POST", "/api/devlog", b"")[0], 413)

    def test_screen_upload(self):
        self.assertEqual(self.request("POST", "/api/devlog/screen?name=shot.png", b"PNG")[0], 204)
        self.assertEqual((server.SCREENS_DIR / "shot.png").read_bytes(), b"PNG")
        self.assertEqual(self.request("POST", "/api/devlog/screen?name=../evil", b"x")[0], 400)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run it and check that it fails**

Run: `python3 -I scripts/devlog/server_test.py`
Expected: `FileNotFoundError` for server.py.

- [ ] **Step 3: Implement** `scripts/devlog/server.py`, then `chmod +x scripts/devlog/server.py`:

```python
#!/usr/bin/env python3
"""Receives the DevLog records that a `./deploy --devlog` build of Amperfy sends.

A phone can't write to this Mac's disk, so the instrumented app POSTs batches
of JSON records to /api/devlog. This server appends them one per line to
log/devlog.jsonl and echoes each to stdout, so a run can be watched live.
Files (DevLog.upload) go to /api/devlog/screen?name=... and are stored in
log/screens/. The logs are emptied at start, so they hold only the current run.

    scripts/devlog/server.py                       # 0.0.0.0:19486 -> log/devlog.jsonl
    AMPERFY_DEVLOG_PORT=19500 scripts/devlog/server.py   # then: AMPERFY_DEVLOG_PORT=19500 ./deploy --devlog
    curl http://$(scutil --get LocalHostName).local:19486/api/devlog/health

Stdlib only. It listens on the LAN without auth, so it caps request and file
sizes instead of trusting the client.
"""

import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from urllib.parse import parse_qs, urlparse

PORT = int(os.getenv("AMPERFY_DEVLOG_PORT", "19486"))
LOG_PATH = Path(os.getenv("AMPERFY_DEVLOG_FILE", Path(__file__).resolve().parents[2] / "log" / "devlog.jsonl"))
SCREENS_DIR = LOG_PATH.parent / "screens"
MAX_REQUEST_BYTES = 1024 * 1024
MAX_RECORDS_PER_REQUEST = 2000
MAX_LOG_BYTES = 32 * 1024 * 1024  # at the cap the file rolls to devlog.jsonl.1
MAX_SCREEN_BYTES = 8 * 1024 * 1024
MAX_SCREENS_BYTES = 512 * 1024 * 1024
SCREEN_NAME = re.compile(r"^[A-Za-z0-9._+-]{1,128}$")
HEALTH_PATHS = {"/health", "/api/devlog/health"}

write_lock = Lock()


def append(records):
    lines = []
    for record in records:
        try:
            lines.append(json.dumps(record, ensure_ascii=True, separators=(",", ":")))
        except (TypeError, ValueError):
            continue
    if not lines:
        return 0
    with write_lock:
        if LOG_PATH.exists() and LOG_PATH.stat().st_size >= MAX_LOG_BYTES:
            os.replace(LOG_PATH, LOG_PATH.with_suffix(LOG_PATH.suffix + ".1"))
        with LOG_PATH.open("a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    for line in lines:
        print(line, flush=True)
    return len(lines)


def save_screen(name, data):
    if not SCREEN_NAME.match(name) or name.startswith("."):
        return False
    with write_lock:
        used = sum(p.stat().st_size for p in SCREENS_DIR.iterdir() if p.is_file())
        if used + len(data) > MAX_SCREENS_BYTES:
            return False
        (SCREENS_DIR / name).write_bytes(data)
    return True


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if urlparse(self.path).path in HEALTH_PATHS:
            self._reply(200, b"ok\n")
        else:
            self._reply(404, b"not found\n")

    def do_POST(self):
        url = urlparse(self.path)
        if url.path == "/api/devlog/screen":
            return self._screen(parse_qs(url.query).get("name", [""])[0])
        if url.path != "/api/devlog":
            return self._reply(404, b"not found\n")
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_REQUEST_BYTES:
            return self._reply(413, b"bad size\n")
        try:
            records = json.loads(self.rfile.read(length))["records"]
            if not isinstance(records, list) or len(records) > MAX_RECORDS_PER_REQUEST:
                raise ValueError("records")
        except (ValueError, KeyError, TypeError):
            return self._reply(400, b"bad payload\n")
        append([r for r in records if isinstance(r, dict)])
        self._reply(204, b"")

    def _screen(self, name):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_SCREEN_BYTES:
            return self._reply(413, b"bad size\n")
        data = self.rfile.read(length)
        if not save_screen(name, data):
            return self._reply(400, b"bad name or screens full\n")
        print(json.dumps({"kind": "screen.file", "name": name, "bytes": length}), flush=True)
        self._reply(204, b"")

    def _reply(self, status, body):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, *args):
        pass  # records already go to stdout; access lines would bury them


def prepare():
    """Empty the logs: they only ever hold the current run."""
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    LOG_PATH.write_text("")
    LOG_PATH.with_suffix(LOG_PATH.suffix + ".1").unlink(missing_ok=True)
    SCREENS_DIR.mkdir(parents=True, exist_ok=True)
    for old in SCREENS_DIR.iterdir():
        if old.is_file():
            old.unlink()


def main():
    prepare()
    httpd = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"devlog: listening on :{PORT}, writing {LOG_PATH}", file=sys.stderr, flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Run the test and check that it passes, then smoke-test it for real**

```bash
python3 -I scripts/devlog/server_test.py
```
Expected: `Ran 5 tests ... OK`. Port 19486 is amperfy's own (vvterm's server uses 19480, so both can run). If `lsof -iTCP:19486 -sTCP:LISTEN` shows something else on it, stop and tell the user:

```bash
scripts/devlog/server.py & SERVER=$!; sleep 1
curl -s "http://$(scutil --get LocalHostName).local:19486/api/devlog/health"
kill $SERVER
```
Expected: `ok`. `git status` must not show `log/` (it is gitignored).

- [ ] **Step 5: Commit**

```bash
git add scripts/devlog/server.py scripts/devlog/server_test.py
git commit -m "feat(devlog): add stdlib DevLog server for --devlog builds

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Verify an unsigned build end to end (nothing is published)

- [ ] **Step 1: Unsigned build through the real script**

```bash
AMPERFY_UNSIGNED=1 ./deploy --yes 2>&1 | tail -25
```
Expected: `UNSIGNED: builds only…`, `Archiving (xcodebuild) [UNSIGNED]`, `Packaging .ipa (unsigned)`, `✓ Unsigned .ipa: …/build/Amperfy-2.1.3-unsigned.ipa`, exit 0. No codesign probe runs. If it dies with `the build left changes behind (SwiftFormat?)`, look at the diff. If it only touches files from this plan, commit it as `style: apply SwiftFormat` and re-run. Otherwise stop and ask the user.

- [ ] **Step 2: Check the binary and the rollback**

```bash
unzip -p build/Amperfy-2.1.3-unsigned.ipa Payload/Amperfy.app/Info.plist | plutil -p - | grep -E "AmperfyOTAManifestURL|AmperfyDevLogURL|CFBundleShortVersionString|CFBundleVersion|CFBundleIdentifier"
git status --porcelain; ls "${TMPDIR:-/tmp}" | grep -c '^Amperfy-ipa-' || true
```
Expected: `AmperfyOTAManifestURL => "https://files.chiq.me/files/amperfy-manifest.plist"`, `AmperfyDevLogURL => ""`, version `2.1.3`, build `3`, `CFBundleIdentifier => "me.chiq.amperfy"`. `git status` is empty (the bump was restored). The grep count is `0`, because the temp dir was deleted. Also check: `ls ~/c/file_server/files | grep -c 'Amperfy-2.1.3'` prints `0`.

- [ ] **Step 3: Unsigned --devlog build**

```bash
AMPERFY_UNSIGNED=1 ./deploy --yes --devlog 2>&1 | tail -5
unzip -p build/Amperfy-2.1.3-unsigned.ipa Payload/Amperfy.app/Info.plist | plutil -p - | grep AmperfyDevLogURL
```
Expected: `AmperfyDevLogURL => "http://<LocalHostName>.local:19486/api/devlog"`.

- [ ] **Step 4: Clean up.** `rm build/Amperfy-2.1.3-unsigned.ipa`. There is nothing to commit, apart from a possible SwiftFormat commit from Step 1.

---

### Task 14: Documentation

**Files:**
- Rewrite: `scripts/deploy/README.md`
- Modify: `README.md` (append a short section; leave the rest of upstream's README untouched)

- [ ] **Step 1: Replace `scripts/deploy/README.md` with:**

````markdown
# OTA release (this fork)

One command builds Amperfy, publishes it and makes it installable from Safari on a
registered iPhone. No App Store, TestFlight or cable.

```
./deploy [patch|minor|major|X.Y.Z] [--yes] [--summary "..."] [--note "..."]... [--devlog]
```

| Flag | Effect |
|---|---|
| (none) / `patch` / `minor` / `major` / `X.Y.Z` | version bump of the app target (`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION`) |
| `--yes` | skip the confirmation prompt |
| `--summary`, `--note` (repeatable) | release notes; default: commit subjects since the last `amperfy-ota-v*` tag, minus merges/Release/Bump/wip, max 8 |
| `--devlog` | bake `AmperfyDevLogURL` = `http://<LocalHostName>.local:19486/api/devlog` (port override: `AMPERFY_DEVLOG_PORT`, which `server.py` also reads; full URL override: `AMPERFY_DEVLOG_URL`) |
| `AMPERFY_UNSIGNED=1` | unsigned archive only: saves `build/Amperfy-X.Y.Z-unsigned.ipa`, publishes/commits nothing |
| `AMPERFY_TEAM_ID` | one-off team override |

## Setup

Both files are gitignored.

`.env` (repo root):

```
AMPERFY_UPLOAD_BASE=https://files.chiq.me
# AMPERFY_PUBLISH_DIR=/path/to/file_server/files   (default ../../file_server/files)
```

`Config/Local.xcconfig` overrides the committed defaults in `Config/Amperfy.xcconfig`
(upstream's bundle ID, no team):

```
AMPERFY_BUNDLE_ID = me.chiq.amperfy
DEVELOPMENT_TEAM = Q3WS4MWCW3
```

The App ID must exist on developer.apple.com (automatic signing creates certificates and
profiles, not App IDs), and each device must be registered **before** the build.

## What it does

1. Preflight: publish dir exists, branch is `master`, tree clean, tag `amperfy-ota-vX.Y.Z`
   is new, codesign works (signs a copy of `/usr/bin/true`; unlocks the login keychain if
   locked, as happens over SSH).
2. Bumps the version (rolled back by an `at_exit` hook if anything fails before the commit).
3. `xcodebuild archive` + `-exportArchive` (`release-testing`, `thinning` `<none>`, manifest
   dict). The OTA manifest URL is passed as the `AMPERFY_OTA_MANIFEST_URL` build setting.
4. Copies into file_server's `files/` (staged + renamed): `Amperfy-X.Y.Z.ipa`,
   `amperfy-icon.png`, `amperfy-manifest.plist`, `amperfy-install.html`.
5. Commits `Release Amperfy OTA <tag>`, tags, pushes branch + tags to the `github` remote
   (never `origin`, which is upstream).

Install page (stable URL, open in Safari): https://files.chiq.me/files/amperfy-install.html.
After the first install, touch and hold the app icon and pick **Install Latest**. It
only appears in builds made by `./deploy`.

## DevLog

```
scripts/devlog/server.py            # :19486, writes log/devlog.jsonl and log/screens/
curl http://$(scutil --get LocalHostName).local:19486/api/devlog/health
./deploy --devlog
```

In app code: `DevLog.event("kind", ["key": "value"])`, `DevLog.upload("name.png", data)`.
Both are no-ops in builds without `--devlog`.

## Fork changes that make this possible

- Bundle IDs are `$(AMPERFY_BUNDLE_ID)[.AmperfyKit|.AmperfyKitTests]`; the team comes from the xcconfig.
- CarPlay audio entitlement removed (Apple grants it per team; Q3WS4MWCW3 has none).
- `icon.png` is exported from `AmperfyKit/Assets/AmperfyAppIcon.icon` with Xcode's `ictool`.
- `NSAllowsLocalNetworking` is deliberately not set: it would disable `NSAllowsArbitraryLoads`.

## Tests

```
for t in scripts/deploy/*_test.rb; do ruby "$t"; done
python3 -I scripts/devlog/server_test.py
xcodebuild test -project Amperfy.xcodeproj -scheme Amperfy -destination 'platform=iOS Simulator,name=iPhone 16e' -only-testing:AmperfyKitTests
```
````

- [ ] **Step 2: Append to `README.md`:**

```markdown

## Fork: OTA install

This fork can be released to registered devices over the air with `./deploy`.
See [scripts/deploy/README.md](scripts/deploy/README.md) for setup (`.env`,
`Config/Local.xcconfig`) and flags.
```

- [ ] **Step 3: Commit**

```bash
git add scripts/deploy/README.md README.md
git commit -m "docs(deploy): document setup, flags and DevLog

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: ntfy-after-deploy project memory (outside the repo)

**Files:**
- Create: `~/.claude/projects/-Users-grillermo-c-third-parties-amperfy/memory/deploy-ntfy-install-link.md`
- Create or append: `~/.claude/projects/-Users-grillermo-c-third-parties-amperfy/memory/MEMORY.md`

- [ ] **Step 1: Write the memory**

```markdown
---
name: deploy-ntfy-install-link
description: "After every ./deploy of Amperfy, send an ntfy notification whose tap starts the OTA install"
metadata:
  type: feedback
---

After every `./deploy` of this Amperfy fork, send an ntfy notification (ntfy skill) with the version in the message.

**Why:** the user wants every OTA release on their phone with one tap (iOS OTA rollout spec, section 5).

**How to apply:** tap target `-u 'itms-services://?action=download-manifest&url=https://files.chiq.me/files/amperfy-manifest.plist'`;
add the install page as a button, because `-l` only takes http(s): `-l https://files.chiq.me/files/amperfy-install.html -L "Install page"`.
Example: `sh ~/.claude/skills/ntfy/scripts/ntfy-send.sh -t "Amperfy" -T rocket -u '<itms link>' -l https://files.chiq.me/files/amperfy-install.html -L "Install page" "Amperfy 2.1.3 is out. Tap to install."`
If the deploy fails, send the failure with `-p high` instead.
```

- [ ] **Step 2: Index it.** Create `MEMORY.md` in the same directory (or append to it) with the line:
`- [Deploy → ntfy install link](deploy-ntfy-install-link.md): after every ./deploy, ntfy the itms-services install link`

- [ ] **Step 3: Dry-run the notification**

```bash
sh ~/.claude/skills/ntfy/scripts/ntfy-send.sh --dry-run -t "Amperfy" -T rocket \
  -u 'itms-services://?action=download-manifest&url=https://files.chiq.me/files/amperfy-manifest.plist' \
  -l https://files.chiq.me/files/amperfy-install.html -L "Install page" "Amperfy dry run"
```
Expected: it prints the request, which isn't sent. (Nothing to commit in the repo.)

---

### Task 16: Final checks, then ASK the user before the one real ./deploy

- [ ] **Step 1: Run every test and check the tree**

```bash
for t in scripts/deploy/*_test.rb; do ruby "$t" || exit 1; done
python3 -I scripts/devlog/server_test.py
xcodebuild test -project Amperfy.xcodeproj -scheme Amperfy -destination 'platform=iOS Simulator,name=iPhone 16e' -only-testing:AmperfyKitTests 2>&1 | tail -5
git status --porcelain; git log --oneline f96a0c9d..HEAD
```
Expected: everything passes, the tree is clean, and the log shows the commits from this plan.

- [ ] **Step 2: STOP and ask the user.** Do not run `./deploy` without explicit approval in chat. Send them:
  - a summary of what changed (task titles above) and the verification results;
  - that `./deploy` will build 2.1.3 (build 3), publish to `https://files.chiq.me/files/amperfy-install.html`, commit `Release Amperfy OTA amperfy-ota-v2.1.3`, tag it, and push `master` + tags to `github` (grillermo/amperfy). That also pushes all the commits from this plan;
  - that the codesign probe may need them to unlock the keychain in a terminal first:

```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

- [ ] **Step 3: Only after approval, run**

```bash
./deploy --yes
```
Report the install URL and what each step printed (archive, export, each published URL, commit, tag, push). Then send the ntfy notification described in the project memory (Task 15) with the real version. On failure, send the failure with `-p high`, and report the error output plus the `scripts/deploy/ipa_builder.rb` signing hint.

- [ ] **Step 4: Update the rollout tracker** (per `~/.claude/projects/-Users-grillermo/memory/ios-ota-rollout.md`): update amperfy's row in the Status table of `~/c/agents-configs/docs/ios-ota-rollout/index.html`, commit it in that repo, and re-publish it to `https://files.chiq.me/files/ios-ota-rollout.html` (file_server `upload_file`, name `ios-ota-rollout.html`).

---

## Open questions / risks for the user

1. **`NSAllowsLocalNetworking` is skipped on purpose** (see the Context section). Adding it would make iOS ignore `NSAllowsArbitraryLoads` and break plain-HTTP media servers. The LAN DevLog server works without it.
2. **DevLog port is 19486, amperfy's own** (vvterm uses 19480), so both servers can run side by side. `AMPERFY_DEVLOG_PORT` overrides it in both `server.py` and `./deploy --devlog`; use the same value for both.
3. **Committed xcconfig defaults are upstream's bundle ID (`de.familie-zimba.amperfy-music`) with an empty team.** A fresh clone builds for the simulator. Device builds need `Config/Local.xcconfig`.
4. **Bundle ID lines in `project.pbxproj` become `$(AMPERFY_BUNDLE_ID)…`.** Upstream merges touching those lines will conflict, as they already do with `me.chiq.amperfy`.
5. **The SwiftFormat build phase** formats the whole repo on every build. If upstream code drifts from the formatter, `./deploy` stops with "the build left changes behind".
6. **Install Latest bypasses `isNormalInteraction`** so that it works before an account exists. All other quick actions keep upstream behaviour.
````
