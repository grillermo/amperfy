//
//  AppQuickActionTest.swift
//  AmperfyKitTests
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

@testable import AmperfyKit
import Foundation
import Testing

struct AppQuickActionTest {
  private let deployedInfo: [String: Any] = [
    AppQuickAction.otaManifestURLInfoKey: "https://files.example.com/files/amperfy-manifest.plist",
  ]

  @Test
  func installLatestStartsTheOTAInstallFromThePinnedManifest() {
    // ./deploy builds in the manifest it republishes under the same name on
    // every release, so the link always installs the newest OTA build.
    #expect(
      AppQuickAction.installLatest.url(infoDictionary: deployedInfo)
        ==
        URL(
          string: "itms-services://?action=download-manifest&url=https://files.example.com/files/amperfy-manifest.plist"
        )
    )
  }

  @Test
  func deployedBuildOffersInstallLatest() {
    #expect(AppQuickAction.available(infoDictionary: deployedInfo) == [.installLatest])
  }

  @Test
  func buildWithoutAManifestOffersNoQuickActions() {
    let localBuild: [String: Any] = [AppQuickAction.otaManifestURLInfoKey: ""]
    // An unexpanded build setting must not count as a URL either.
    let unexpanded: [String: Any] =
      [AppQuickAction.otaManifestURLInfoKey: "$(AMPERFY_OTA_MANIFEST_URL)"]

    #expect(AppQuickAction.available(infoDictionary: localBuild).isEmpty)
    #expect(AppQuickAction.available(infoDictionary: unexpanded).isEmpty)
    #expect(AppQuickAction.available(infoDictionary: nil).isEmpty)
    #expect(AppQuickAction.installLatest.url(infoDictionary: localBuild) == nil)
  }

  @Test
  func unknownShortcutTypeIsIgnored() {
    #expect(AppQuickAction(shortcutType: "com.example.unknown") == nil)
    // The static Info.plist item of the 2.1.2 release is gone too.
    #expect(AppQuickAction(shortcutType: "InstallLatestAction") == nil)
  }
}
