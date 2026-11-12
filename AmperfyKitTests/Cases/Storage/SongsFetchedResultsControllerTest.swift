//
//  SongsFetchedResultsControllerTest.swift
//  AmperfyKitTests
//
//  Created by Jerome Mohm on 12.10.26.
//  Copyright (c) 2026 Jerome Mohm. All rights reserved.
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
import CoreData
import XCTest

@MainActor
class SongsFetchedResultsControllerTest: XCTestCase {
  var cdHelper: CoreDataHelper!
  var library: LibraryStorage!
  var account: Account!
  var coreDataCompanion: CoreDataCompanion!

  override func setUp() async throws {
    cdHelper = CoreDataHelper()
    library = cdHelper.createSeededStorage()
    account = library.getAccount(info: TestAccountInfo.create1())
    coreDataCompanion = CoreDataCompanion(context: cdHelper.persistentContainer.viewContext)
  }

  func testSongsControllerUsesNoPersistentCache() {
    let sortTypes: [SongElementSortType] = [
      .name,
      .rating,
      .addedDate,
      .duration,
      .starredDate,
      .lastPlayed,
    ]
    for sortType in sortTypes {
      let songsController = SongsFetchedResultsController(
        coreDataCompanion: coreDataCompanion,
        account: account,
        sortType: sortType,
        isGroupedInAlphabeticSections: sortType.hasSectionTitles
      )
      XCTAssertNil(songsController.fetchResultsController.cacheName)
    }
  }

  func testLastPlayedSortShowsMostRecentlyPlayedFirst() {
    let now = Date()
    let older = library.createSong(account: account)
    older.id = "lastPlayedOlder"
    older.title = "A older"
    older.lastTimePlayed = now.addingTimeInterval(-3600)
    let newest = library.createSong(account: account)
    newest.id = "lastPlayedNewest"
    newest.title = "B newest"
    newest.lastTimePlayed = now
    let neverPlayed = library.createSong(account: account)
    neverPlayed.id = "lastPlayedNever"
    neverPlayed.title = "C never"
    // cached songs pass the controller's "exclude server deleted, uncached" filter
    for song in [older, newest, neverPlayed] {
      song.managedObject.relFilePath = "\(song.id).mp3"
    }
    library.saveContext()

    let songsController = SongsFetchedResultsController(
      coreDataCompanion: coreDataCompanion,
      account: account,
      sortType: .lastPlayed,
      isGroupedInAlphabeticSections: SongElementSortType.lastPlayed.hasSectionTitles
    )
    songsController.fetch()
    let ids = (songsController.fetchedObjects ?? [])
      .compactMap { $0.id }
      .filter { $0.hasPrefix("lastPlayed") }
    XCTAssertEqual(ids, ["lastPlayedNewest", "lastPlayedOlder", "lastPlayedNever"])
  }

  func testTrackingControllerKeepsPersistentCache() {
    let albumsController = AlbumFetchedResultsController(
      coreDataCompanion: coreDataCompanion,
      account: account,
      sortType: .name,
      isGroupedInAlphabeticSections: true
    )
    XCTAssertNotNil(albumsController.fetchResultsController.cacheName)
  }
}
