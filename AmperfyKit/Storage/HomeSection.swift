//
//  HomeSection.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 26.11.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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

public enum HomeSection: Int, Sendable, CaseIterable, Codable {
  // add new section always at the end to keep the Int consitent
  case lastTimePlayedPlaylists
  case recentlyPlayedAlbums
  case newestAlbums
  case randomAlbums
  case newestPodcastEpisodes
  case podcasts
  case radios
  case randomArtists
  case randomGenres
  case randomSongs
  case recentlyAddedSongs

  // sections no longer offered on the Home screen; the cases stay to keep the Int raw values consistent
  static let removedSections: Set<HomeSection> = [.randomAlbums]

  // sections added after users already stored their Home settings, with the section each one
  // follows: they are shown there until the user arranges the sections in the editor
  static let introducedSections: [(section: HomeSection, after: HomeSection)] = [
    (.recentlyAddedSongs, .newestAlbums),
  ]

  static let defaultValue: [HomeSection] = [
    .recentlyPlayedAlbums,
    .lastTimePlayedPlaylists,
    .newestAlbums,
    .recentlyAddedSongs,
  ]

  public var title: String {
    switch self {
    case .recentlyPlayedAlbums: return "Recently Played Albums"
    case .newestAlbums: return "Newest Albums"
    case .randomAlbums: return "Random Albums"
    case .lastTimePlayedPlaylists: return "Recently Played Playlists"
    case .newestPodcastEpisodes: return "Newest Podcast Episodes"
    case .podcasts: return "Podcasts"
    case .radios: return "Radios"
    case .randomArtists: return "Random Artists"
    case .randomGenres: return "Random Genres"
    case .randomSongs: return "Random Songs"
    case .recentlyAddedSongs: return "Recently Added Songs"
    }
  }

  public static func create(fromTitle: String) -> HomeSection? {
    allCases.first(where: { $0.title == fromTitle })
  }

  public var isRandomSection: Bool {
    switch self {
    case .recentlyPlayedAlbums: return false
    case .newestAlbums: return false
    case .randomAlbums: return true
    case .lastTimePlayedPlaylists: return false
    case .newestPodcastEpisodes: return false
    case .podcasts: return false
    case .radios: return false
    case .randomArtists: return true
    case .randomGenres: return true
    case .randomSongs: return true
    case .recentlyAddedSongs: return false
    }
  }

  /// Inserts the introduced sections missing from `knownSections` (the sections the stored settings
  /// already knew about) after the section each one follows, or at the end if that one is absent.
  static func insertingIntroducedSections(
    into sections: [HomeSection],
    knownSections: [HomeSection]
  )
    -> [HomeSection] {
    var result = sections
    for (section, anchor) in introducedSections
      where !knownSections.contains(section) && !result.contains(section) {
      if let anchorIndex = result.firstIndex(of: anchor) {
        result.insert(section, at: anchorIndex + 1)
      } else {
        result.append(section)
      }
    }
    return result
  }
}
