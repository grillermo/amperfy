# OTA release (this fork)

Run from the repo root, on any Mac whose Xcode is signed in to team Q3WS4MWCW3 and that has a
file_server token (log in once with the file_server MCP's `file_server_login`; it saves
`~/.config/file_server/token`). `./build` runs this and `build-macos.sh` one after the other:

    ./build-ios.sh [patch|minor|major|X.Y.Z] [--yes] [--summary "..."] [--note "..."]...

`build-ios.sh` makes sure Xcode is set up (first-launch tasks, the iOS platform), then runs
`./deploy` with the same arguments. `./deploy`:

1. checks everything before touching the tree: on `master`, clean tree, the
   `amperfy-ota-vX.Y.Z` tag is new, `github` is the fork, file_server answers with our
   token, and codesign can sign (it unlocks the login keychain with
   `~/c/agents-configs/bin/unlock-codesign-keychain.sh` over SSH);
2. bumps the app target's version (`versioning.rb`; AmperfyKit and the tests keep 1.0);
3. archives and exports an ad hoc (`release-testing`) `.ipa` signed by team Q3WS4MWCW3 as
   `me.chiq.amperfy`, with the OTA `manifest.plist`;
4. uploads the `.ipa`, icon, manifest and install page to file_server (files.chiq.me): straight
   to the macmini over the LAN at home, once the server there proves it holds the token, and
   through the tunnel elsewhere (where bodies over ~12 MB can stall, so the ~110 MB `.ipa` needs
   the home network);
5. commits the bump, tags it and pushes `master` to `github` (grillermo/amperfy). Never to
   `origin`, which is upstream.

Install page (stable URL, open in Safari): https://files.chiq.me/files/amperfy-install.html
After the first install, long-press the app icon and pick **Install Latest** to update.

## Flags

| Flag | Effect |
|---|---|
| `patch` (default), `minor`, `major`, `X.Y.Z` | the version bump |
| `--yes` | skip the confirmation prompt |
| `--summary "..."` | headline of the install page's release notes |
| `--note "..."` | a bullet, repeatable; without notes they come from commit subjects |
| `AMPERFY_UNSIGNED=1` | unsigned `Payload/` zip, for when signing is broken |
| `AMPERFY_PUBLISH_DIR=...` | copy into a local dir file_server serves instead of uploading |

## Nothing left behind

The build runs in `tmp/ios-ota/` (DerivedData, Swift packages, archive, the export's temp
logs) and is deleted on exit, success or failure; `build-macos.sh` does the same in
`tmp/macos/`, and `tmp/` goes once both are gone. So is whatever the run added to the shared
caches xcodebuild writes to regardless (provisioning profiles, SwiftPM's manifest cache,
Xcode's plug-in caches; see `SHARED_CACHE_DIRS` in `ipa_builder.rb`), the per-package
`ManifestLoading/<package>.dia` files SwiftPM rewrites on every build, and the empty
`swiftpm/configuration/` dir xcodebuild creates in the project. Both scripts share that
cleanup (`IpaBuilder.clean_shared_caches!`). Rows a build adds to SwiftPM's existing
`manifest.db`, and xcodebuild's own `Cache.db`/`HTTPStorages` databases, stay: they are
shared by every project and cannot be split.

The SwiftFormat build phase is skipped for these builds (`AMPERFY_SKIP_SWIFTFORMAT=YES`): it
would build swiftformat with `swift run`, which fills SwiftPM's caches in `~/Library`. What
remains is what's in files.chiq.me: the versioned `.ipa` plus the pinned
`amperfy-manifest.plist`, `amperfy-icon.png` and `amperfy-install.html` it needs (and, with
`./build`, the Mac app in `~/Applications`).

Opening the project in Xcode's GUI is different: that uses `~/Library/Developer/Xcode/DerivedData`
and SwiftPM's shared `repositories/` cache, which these scripts never touch.

## Setup (both files gitignored, both optional)

- `.env`: `AMPERFY_UPLOAD_BASE` (default https://files.chiq.me), `AMPERFY_PUBLISH_DIR`,
  `AMPERFY_TEAM_ID`, `AMPERFY_DEVLOG_URL`
- `Config/Local.xcconfig`: `DEVELOPMENT_TEAM` and `AMPERFY_BUNDLE_ID`, overriding the
  committed defaults in `Config/Amperfy.xcconfig` (the project's base configuration).

## Fork changes that make this possible

- Personal team and `me.chiq.amperfy*` bundle IDs, from `Config/Amperfy.xcconfig`. The Mac
  Catalyst build (`build-macos.sh`) keeps upstream's bundle ID, so the installed Mac app
  keeps its data.
- CarPlay audio entitlement removed (Apple grants it per team; Q3WS4MWCW3 has none).
- `icon.png` is exported from `AmperfyKit/Assets/AmperfyAppIcon.icon` with Xcode's `ictool`.
- Info.plist's `AmperfyOTAManifestURL` (`$(AMPERFY_OTA_MANIFEST_URL)`, passed by `./deploy`)
  turns on the Install Latest quick action (`AppQuickAction`); other builds don't offer it.

A device must be registered on the developer portal before a build is made.
`ruby scripts/deploy/versioning_test.rb` tests the version bump.
