# OTA release

    ./deploy [patch|minor|major|X.Y.Z] [--yes] [--summary ...] [--note ...]

Builds an ad-hoc `.ipa` signed by team Q3WS4MWCW3 as `me.chiq.amperfy`, publishes it with
its manifest, icon and install page into `../../file_server/files` (served at
`files.chiq.me`), then commits the version bump, tags `amperfy-ota-vX.Y.Z` and pushes to the
`github` remote (grillermo/amperfy).

Install page (stable URL, open in Safari): https://files.chiq.me/files/amperfy-install.html

After the first install, long-press the app icon and pick **Install Latest** to update.

Fork changes that make this possible:

- `DEVELOPMENT_TEAM` and bundle IDs switched to the personal team / `me.chiq.amperfy*`.
- CarPlay audio entitlement removed (Apple grants it per team; Q3WS4MWCW3 has none).
- `icon.png` is exported from `AmperfyKit/Assets/AmperfyAppIcon.icon` with Xcode's `ictool`.

A device must be registered on the developer portal before a build is made.
`ruby scripts/deploy/versioning_test.rb` tests the pbxproj version bump.
