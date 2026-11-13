//
//  ArtistDetailVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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

import AmperfyKit
import CoreData
import UIKit

// MARK: - ArtistDetailVC

class ArtistDetailVC: MultiSourceTableViewController {
  override var sceneTitle: String? { artist.name }

  private let artist: Artist
  var albumToScrollTo: Album?
  private var albumsFetchedResultsController: ArtistAlbumsItemsFetchedResultsController!
  private var songsFetchedResultsController: ArtistSongsItemsFetchedResultsController!
  private var optionsButton: UIBarButtonItem!
  private var detailOperationsView: GenericDetailTableHeader?

  /// The albums show as a grid of cover cards, held in a single row of the table
  private var albumsGridVC: ArtistAlbumsGridVC!
  private var isAlbumsGridReloadNeeded = false
  private var lastLayoutWidth: CGFloat = 0

  init(account: Account, artist: Artist) {
    self.artist = artist
    super.init(style: .plain, account: account)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    appDelegate.userStatistics.visited(.artistDetail)

    optionsButton = UIBarButtonItem.createOptionsBarButton()

    albumsFetchedResultsController = ArtistAlbumsItemsFetchedResultsController(
      for: artist,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false
    )
    albumsFetchedResultsController.delegate = self
    songsFetchedResultsController = createSongsFetchedResultsController(
      sortType: appDelegate.storage.settings.user.artistSongsSortSetting
    )
    albumsGridVC = ArtistAlbumsGridVC(
      account: account,
      albumsFetchedResultsController: albumsFetchedResultsController
    )
    addChild(albumsGridVC)
    albumsGridVC.didMove(toParent: self)
    tableView.register(
      ArtistAlbumsGridTableCell.self,
      forCellReuseIdentifier: ArtistAlbumsGridTableCell.reuseID
    )
    resultUpdateHandler?.changesDidEnd = { [weak self] in
      self?.reloadAlbumsGridIfNeeded()
    }
    tableView.register(nibName: PlayableTableCell.typeName)
    tableView.reloadOnTextSizeChange()
    tableView.sectionHeaderHeight = 0.0
    tableView.estimatedSectionHeaderHeight = 0.0
    tableView.sectionFooterHeight = 0.0
    tableView.estimatedSectionFooterHeight = 0.0

    configureSearchController(placeholder: "Albums and Songs", scopeButtonTitles: ["All", "Cached"])
    let playShuffleInfoConfig = PlayShuffleInfoConfiguration(
      infoCB: {
        "\(self.artist.albumCount) Album\(self.artist.albumCount == 1 ? "" : "s") \(CommonString.oneMiddleDot) \(self.artist.songCount) Song\(self.artist.songCount == 1 ? "" : "s")"
      },
      playContextCb: { () in
        let songs = self.songsFetchedResultsController
          .getContextSongs(onlyCachedSongs: self.appDelegate.storage.settings.user.isOfflineMode) ??
          []
        let sortedSongs = songs.filterSongs().sortByAlbum()
        return PlayContext(containable: self.artist, playables: sortedSongs)
      },
      player: appDelegate.player,
      isInfoAlwaysHidden: true
    )
    let detailHeaderConfig = DetailHeaderConfiguration(
      entityContainer: artist,
      rootView: self,
      tableView: tableView,
      playShuffleInfoConfig: playShuffleInfoConfig
    )
    detailOperationsView = GenericDetailTableHeader
      .createTableHeader(configuration: detailHeaderConfig)

    optionsButton = UIBarButtonItem.createOptionsBarButton()
    optionsButton.menu = UIMenu.lazyMenu {
      EntityPreviewActionBuilder(container: self.artist, on: self).createMenuActions()
    }
    navigationItem.rightBarButtonItem = optionsButton

    containableAtIndexPathCallback = { indexPath in
      switch indexPath.section + 1 {
      case LibraryElement.Song.rawValue:
        return self.songsFetchedResultsController.getWrappedEntity(at: IndexPath(
          row: indexPath.row,
          section: 0
        ))
      default:
        return nil
      }
    }
    playContextAtIndexPathCallback = { indexPath in
      switch indexPath.section + 1 {
      case LibraryElement.Song.rawValue:
        let songIndexPath = IndexPath(row: indexPath.row, section: 0)
        return self.convertIndexPathToPlayContext(songIndexPath: songIndexPath)
      default:
        return nil
      }
    }
    swipeCallback = { indexPath, completionHandler in
      switch indexPath.section + 1 {
      case LibraryElement.Song.rawValue:
        let songIndexPath = IndexPath(row: indexPath.row, section: 0)
        let song = self.songsFetchedResultsController.getWrappedEntity(at: songIndexPath)
        let playContext = self.convertIndexPathToPlayContext(songIndexPath: songIndexPath)
        completionHandler(SwipeActionContext(containable: song, playContext: playContext))
      default:
        completionHandler(nil)
      }
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = false
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    albumsFetchedResultsController?.delegate = self
    songsFetchedResultsController?.delegate = self
    Task { @MainActor in
      do {
        try await artist.fetch(
          storage: self.appDelegate.storage,
          librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.appDelegate.getMeta(self.account.info)
            .playableDownloadManager
        )
      } catch {
        self.appDelegate.eventLogger.report(topic: "Artist Sync", error: error)
      }
      self.detailOperationsView?.refresh()
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    albumsFetchedResultsController?.delegate = nil
    songsFetchedResultsController?.delegate = nil
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    defer { albumToScrollTo = nil }
    if let albumToScrollTo, let cardFrame = albumsGridVC.frame(of: albumToScrollTo) {
      let gridRowFrame = tableView.rectForRow(at: IndexPath(
        row: 0,
        section: LibraryElement.Album.rawValue - 1
      ))
      tableView.scrollRectToVisible(
        cardFrame.offsetBy(dx: gridRowFrame.minX, dy: gridRowFrame.minY),
        animated: true
      )
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    // the number of grid columns follows the window width, so the grid row height does too
    let width = tableView.bounds.width
    guard width != lastLayoutWidth else { return }
    lastLayoutWidth = width
    UIView.performWithoutAnimation {
      tableView.beginUpdates()
      tableView.endUpdates()
    }
  }

  private var albumsGridHeight: CGFloat {
    ArtistAlbumsGridVC.height(
      forWidth: tableView.bounds.width,
      count: albumsGridVC.albumCount,
      traits: traitCollection
    )
  }

  private func reloadAlbumsGridIfNeeded() {
    guard isAlbumsGridReloadNeeded else { return }
    isAlbumsGridReloadNeeded = false
    albumsGridVC.reload()
    tableView.reloadSections(
      IndexSet(integer: LibraryElement.Album.rawValue - 1),
      with: .none
    )
  }

  private func createSongsFetchedResultsController(sortType: SongElementSortType)
    -> ArtistSongsItemsFetchedResultsController {
    let controller = ArtistSongsItemsFetchedResultsController(
      for: artist,
      displayFilter: appDelegate.storage.settings.user.artistsFilterSetting,
      sortType: sortType,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false
    )
    controller.delegate = self
    return controller
  }

  private func change(songsSortType sortType: SongElementSortType) {
    guard sortType != songsFetchedResultsController.sortType else { return }
    appDelegate.storage.settings.user.artistSongsSortSetting = sortType
    songsFetchedResultsController.delegate = nil
    songsFetchedResultsController = createSongsFetchedResultsController(sortType: sortType)
    // applies the active search to the new controller and reloads the table
    updateSearchResults(for: searchController)
  }

  private func createSongsSortMenu() -> UIMenu {
    var sortTypes: [(String, SongElementSortType)] = [
      ("Name", .name),
      ("Rating", .rating),
      ("Duration", .duration),
      ("Recently Played", .lastPlayed),
      ("Play Count", .playCount),
    ]
    if account.apiType.asServerApiType != .ampache {
      sortTypes.append(("Date Added", .addedDate))
    }
    let current = songsFetchedResultsController.sortType
    let actions = sortTypes.map { title, sortType in
      UIAction(title: title, image: sortType == current ? .check : nil) { [weak self] _ in
        self?.change(songsSortType: sortType)
      }
    }
    return UIMenu(title: "Sort", image: .sort, options: [.displayInline], children: actions)
  }

  private static let songsSortButtonTag = 4_242

  /// The ⋯ button at the trailing end of the "Songs" section header, with the sort options.
  /// Header views are reused across sections, so other sections hide it.
  private func configureSongsSortButton(in header: UITableViewHeaderFooterView, isShown: Bool) {
    var button = header.contentView.viewWithTag(Self.songsSortButtonTag) as? UIButton
    if button == nil, isShown {
      let newButton = UIButton(type: .system)
      newButton.tag = Self.songsSortButtonTag
      newButton.setImage(.ellipsis, for: .normal)
      newButton.showsMenuAsPrimaryAction = true
      newButton.accessibilityLabel = "Sort Songs"
      newButton.translatesAutoresizingMaskIntoConstraints = false
      header.contentView.addSubview(newButton)
      NSLayoutConstraint.activate([
        newButton.trailingAnchor
          .constraint(equalTo: header.contentView.layoutMarginsGuide.trailingAnchor),
        newButton.centerYAnchor.constraint(equalTo: header.contentView.centerYAnchor),
        newButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
        newButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      ])
      button = newButton
    }
    button?.isHidden = !isShown
    if isShown {
      button?.menu = createSongsSortMenu()
    }
  }

  override func tableView(
    _ tableView: UITableView,
    willDisplayHeaderView view: UIView,
    forSection section: Int
  ) {
    super.tableView(tableView, willDisplayHeaderView: view, forSection: section)
    guard let header = view as? UITableViewHeaderFooterView else { return }
    configureSongsSortButton(
      in: header,
      isShown: section + 1 == LibraryElement.Song.rawValue
    )
  }

  func convertIndexPathToPlayContext(songIndexPath: IndexPath) -> PlayContext? {
    guard let songs = songsFetchedResultsController
      .getContextSongs(onlyCachedSongs: appDelegate.storage.settings.user.isOfflineMode)
    else { return nil }
    let selectedSong = songsFetchedResultsController.getWrappedEntity(at: songIndexPath)
    guard let playContextIndex = songs.firstIndex(of: selectedSong) else { return nil }
    return PlayContext(containable: artist, index: playContextIndex, playables: songs)
  }

  func convertCellViewToPlayContext(cell: UITableViewCell) -> PlayContext? {
    guard let indexPath = tableView.indexPath(for: cell),
          indexPath.section + 1 == LibraryElement.Song.rawValue
    else { return nil }
    return convertIndexPathToPlayContext(songIndexPath: IndexPath(row: indexPath.row, section: 0))
  }

  // MARK: - Table view data source

  override func numberOfSections(in tableView: UITableView) -> Int {
    // 2 section + 1 top section. The top section is needed due to display bugs
    3
  }

  override func tableView(
    _ tableView: UITableView,
    titleForHeaderInSection section: Int
  )
    -> String? {
    switch section + 1 {
    case LibraryElement.Album.rawValue:
      return "Albums"
    case LibraryElement.Song.rawValue:
      return "Songs"
    default:
      return ""
    }
  }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    switch section + 1 {
    case LibraryElement.Album.rawValue:
      // the grid row stays even without albums (0 high then), so fetch updates never change
      // this section's row count
      return 1
    case LibraryElement.Song.rawValue:
      return songsFetchedResultsController.sections?[0].numberOfObjects ?? 0
    default:
      return 0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    switch indexPath.section + 1 {
    case LibraryElement.Album.rawValue:
      let gridCell = tableView.dequeueReusableCell(
        withIdentifier: ArtistAlbumsGridTableCell.reuseID,
        for: indexPath
      ) as! ArtistAlbumsGridTableCell
      gridCell.embed(albumsGridVC.view)
      albumsGridVC.reload()
      return gridCell
    case LibraryElement.Song.rawValue:
      let cell: PlayableTableCell = dequeueCell(for: tableView, at: indexPath)
      let song = songsFetchedResultsController.getWrappedEntity(at: IndexPath(
        row: indexPath.row,
        section: 0
      ))
      cell.display(playable: song, playContextCb: convertCellViewToPlayContext, rootView: self)
      return cell
    default:
      return UITableViewCell()
    }
  }

  override func tableView(
    _ tableView: UITableView,
    heightForHeaderInSection section: Int
  )
    -> CGFloat {
    switch section + 1 {
    case LibraryElement.Album.rawValue:
      return albumsFetchedResultsController.sections?[0]
        .numberOfObjects ?? 0 > 0 ? CommonScreenOperations.tableSectionHeightLarge : 0
    case LibraryElement.Song.rawValue:
      return songsFetchedResultsController.sections?[0]
        .numberOfObjects ?? 0 > 0 ? CommonScreenOperations.tableSectionHeightLarge : 0
    default:
      return 0.0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    heightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch indexPath.section + 1 {
    case LibraryElement.Album.rawValue:
      return albumsGridHeight
    case LibraryElement.Song.rawValue:
      return PlayableTableCell.rowHeight
    default:
      return 0.0
    }
  }

  override func tableView(
    _ tableView: UITableView,
    estimatedHeightForRowAt indexPath: IndexPath
  )
    -> CGFloat {
    switch indexPath.section + 1 {
    case LibraryElement.Album.rawValue:
      return albumsGridHeight
    case LibraryElement.Song.rawValue:
      return PlayableTableCell.rowHeight
    default:
      return 0.0
    }
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    // albums open from their grid card, songs play from their cell
  }

  override func updateSearchResults(for searchController: UISearchController) {
    guard let searchText = searchController.searchBar.text else { return }
    if !searchText.isEmpty, !searchController.searchBar.isCachedScopeSelected {
      albumsFetchedResultsController.search(searchText: searchText, onlyCached: false)
      songsFetchedResultsController.search(searchText: searchText, onlyCachedSongs: false)
    } else if searchController.searchBar.isCachedScopeSelected {
      albumsFetchedResultsController.search(searchText: searchText, onlyCached: true)
      songsFetchedResultsController.search(searchText: searchText, onlyCachedSongs: true)
    } else {
      albumsFetchedResultsController.showAllResults()
      songsFetchedResultsController.showAllResults()
    }
    tableView.reloadData()
  }

  override func controller(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>,
    didChange anObject: Any,
    at indexPath: IndexPath?,
    for type: NSFetchedResultsChangeType,
    newIndexPath: IndexPath?
  ) {
    var section = 0
    switch controller {
    case albumsFetchedResultsController.fetchResultsController:
      // the grid reloads as a whole once the changes end (reloadAlbumsGridIfNeeded)
      isAlbumsGridReloadNeeded = true
      return
    case songsFetchedResultsController.fetchResultsController:
      section = LibraryElement.Song.rawValue - 1
    default:
      return
    }

    resultUpdateHandler?.applyChangesOfMultiRowType(
      controller,
      didChange: anObject,
      determinedSection: section,
      at: indexPath,
      for: type,
      newIndexPath: newIndexPath
    )
  }

  override func controller(
    _ controller: NSFetchedResultsController<NSFetchRequestResult>,
    didChange sectionInfo: NSFetchedResultsSectionInfo,
    atSectionIndex sectionIndex: Int,
    for type: NSFetchedResultsChangeType
  ) {}
}

// MARK: - ArtistAlbumsGridVC

/// The artist's albums as square cover cards with the title below, the same cards Home uses.
/// It does not scroll: it is as tall as all its rows and lives in one row of the artist table.
final class ArtistAlbumsGridVC: UICollectionViewController {
  static let itemWidth: CGFloat = 160.0
  private static let interItemSpacing: CGFloat = 12.0
  private static let lineSpacing: CGFloat = 16.0
  private static let insets = UIEdgeInsets(top: 8, left: 16, bottom: 16, right: 16)

  private let account: Account
  private let albumsFetchedResultsController: ArtistAlbumsItemsFetchedResultsController

  init(
    account: Account,
    albumsFetchedResultsController: ArtistAlbumsItemsFetchedResultsController
  ) {
    self.account = account
    self.albumsFetchedResultsController = albumsFetchedResultsController
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .vertical
    layout.minimumInteritemSpacing = Self.interItemSpacing
    layout.minimumLineSpacing = Self.lineSpacing
    layout.sectionInset = Self.insets
    super.init(collectionViewLayout: layout)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var albumCount: Int {
    albumsFetchedResultsController.sections?.first?.numberOfObjects ?? 0
  }

  private static func itemHeight(for traits: UITraitCollection) -> CGFloat {
    itemWidth + AlbumCollectionCell.labelAreaHeight(for: traits, defaultHeight: 50.0)
  }

  private static func columns(forWidth width: CGFloat) -> Int {
    let available = width - insets.left - insets.right + interItemSpacing
    return max(1, Int(available / (itemWidth + interItemSpacing)))
  }

  /// Height the grid needs to show `count` albums at the given width
  static func height(forWidth width: CGFloat, count: Int, traits: UITraitCollection) -> CGFloat {
    guard count > 0 else { return 0 }
    let columns = columns(forWidth: width)
    let rows = (count + columns - 1) / columns
    return insets.top + insets.bottom + CGFloat(rows) * itemHeight(for: traits) +
      CGFloat(rows - 1) * lineSpacing
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    collectionView.backgroundColor = .clear
    collectionView.isScrollEnabled = false
    collectionView.register(
      UINib(nibName: AlbumCollectionCell.typeName, bundle: .main),
      forCellWithReuseIdentifier: AlbumCollectionCell.typeName
    )
    updateItemSize()
    registerForTraitChanges(
      [UITraitPreferredContentSizeCategory.self],
      handler: { (self: Self, _: UITraitCollection) in
        self.updateItemSize()
      }
    )
  }

  private func updateItemSize() {
    guard let layout = collectionView.collectionViewLayout as? UICollectionViewFlowLayout
    else { return }
    layout.itemSize = CGSize(width: Self.itemWidth, height: Self.itemHeight(for: traitCollection))
    layout.invalidateLayout()
  }

  func reload() {
    collectionView.reloadData()
  }

  /// Frame of the album's card in the grid's coordinates
  func frame(of album: Album) -> CGRect? {
    guard let indexPath = albumsFetchedResultsController.fetchResultsController
      .indexPath(forObject: album.managedObject)
    else { return nil }
    collectionView.layoutIfNeeded()
    return collectionView.layoutAttributesForItem(at: indexPath)?.frame
  }

  private func album(at indexPath: IndexPath) -> Album {
    albumsFetchedResultsController.getWrappedEntity(at: IndexPath(row: indexPath.item, section: 0))
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    numberOfItemsInSection section: Int
  )
    -> Int {
    albumCount
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    cellForItemAt indexPath: IndexPath
  )
    -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: AlbumCollectionCell.typeName,
      for: indexPath
    ) as! AlbumCollectionCell
    cell.display(
      container: album(at: indexPath),
      rootView: self,
      itemWidth: Self.itemWidth,
      initialIndexPath: indexPath
    )
    // the artist is the page itself, so only the album title goes below the cover
    cell.subtitleLabel.isHidden = true
    return cell
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    didSelectItemAt indexPath: IndexPath
  ) {
    collectionView.deselectItem(at: indexPath, animated: false)
    navigationController?.pushViewController(
      AppStoryboard.Main.segueToAlbumDetail(account: account, album: album(at: indexPath)),
      animated: true
    )
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    contextMenuConfigurationForItemAt indexPath: IndexPath,
    point: CGPoint
  )
    -> UIContextMenuConfiguration? {
    let album = album(at: indexPath)
    let rootView: UIViewController = parent ?? self
    let identifier = NSString(string: TableViewPreviewInfo(
      playableContainerIdentifier: album.containerIdentifier,
      indexPath: indexPath
    ).asJSONString())
    return UIContextMenuConfiguration(identifier: identifier, previewProvider: {
      let vc = EntityPreviewVC()
      vc.display(container: album, on: rootView)
      Task { @MainActor in
        do {
          try await album.fetch(
            storage: self.appDelegate.storage,
            librarySyncer: self.appDelegate.getMeta(self.account.info).librarySyncer,
            playableDownloadManager: self.appDelegate.getMeta(self.account.info)
              .playableDownloadManager
          )
        } catch {
          self.appDelegate.eventLogger.report(topic: "Preview Sync", error: error)
        }
        vc.refresh()
      }
      return vc
    }) { _ in
      EntityPreviewActionBuilder(
        container: album,
        on: rootView,
        playContextCb: { PlayContext(containable: album) }
      ).createMenu()
    }
  }

  override func collectionView(
    _ collectionView: UICollectionView,
    willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionCommitAnimating
  ) {
    let rootView: UIViewController = parent ?? self
    animator.addCompletion {
      if let identifier = configuration.identifier as? String,
         let tvPreviewInfo = TableViewPreviewInfo.create(fromIdentifier: identifier),
         let containerIdentifier = tvPreviewInfo.playableContainerIdentifier,
         let container = self.appDelegate.storage.main.library
         .getContainer(identifier: containerIdentifier) {
        EntityPreviewActionBuilder(container: container, on: rootView)
          .performPreviewTransition()
      }
    }
  }
}

// MARK: - ArtistAlbumsGridTableCell

/// Table row that holds the albums grid view
final class ArtistAlbumsGridTableCell: UITableViewCell {
  static let reuseID = "ArtistAlbumsGridTableCell"

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    selectionStyle = .none
    backgroundColor = .clear
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func embed(_ view: UIView) {
    guard view.superview !== contentView else { return }
    view.removeFromSuperview()
    view.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      view.topAnchor.constraint(equalTo: contentView.topAnchor),
      view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
    ])
  }
}
