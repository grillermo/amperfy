//
//  AppQuickAction.swift
//  AmperfyKit
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

import Foundation

/// Home Screen quick actions of the OTA release pipeline (`./deploy`), registered
/// from `available(infoDictionary:)`. Each raw value is the item's
/// `UIApplicationShortcutItem.type`. They work without an account or a synced
/// library, unlike `QuickActionsHandler`'s player actions.
public enum AppQuickAction: String, Equatable, Sendable {
  case installLatest = "amperfy.install-latest"

  /// Info.plist key that ./deploy fills with its pinned OTA manifest URL.
  public static let otaManifestURLInfoKey = "AmperfyOTAManifestURL"

  public init?(shortcutType: String) {
    self.init(rawValue: shortcutType)
  }

  /// Builds made outside ./deploy carry no manifest URL, so they offer no
  /// Install Latest action: there is no release for them to install.
  public static func available(infoDictionary: [String: Any]?) -> [AppQuickAction] {
    otaManifestURL(infoDictionary: infoDictionary) == nil ? [] : [.installLatest]
  }

  public func url(infoDictionary: [String: Any]?) -> URL? {
    switch self {
    case .installLatest:
      // Same link as the install page's button: iOS asks to install straight
      // away. ./deploy republishes the manifest under this pinned name on
      // every release, so it always installs the newest build.
      Self.otaManifestURL(infoDictionary: infoDictionary).flatMap {
        URL(string: "itms-services://?action=download-manifest&url=\($0.absoluteString)")
      }
    }
  }

  private static func otaManifestURL(infoDictionary: [String: Any]?) -> URL? {
    guard let value = infoDictionary?[otaManifestURLInfoKey] as? String,
          !value.isEmpty,
          !value.hasPrefix("$(") else {
      return nil
    }
    return URL(string: value)
  }
}
