import AVFoundation
import Combine
import Darwin
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import DrivePlayer

private final class LockedTestState<State>: @unchecked Sendable {
    private let lock = NSLock()
    private var state: State

    init(_ state: State) {
        self.state = state
    }

    func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
        try lock.withLock {
            try body(&state)
        }
    }
}

@MainActor
private final class RemoteLoudnessNowPlayingControllerSpy: MusicNowPlayingControlling {
    private var handler: (@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)?

    func publish(_ snapshot: NowPlayingSnapshot) {}
    func clear() {}

    func registerRemoteCommands(
        handler: @escaping @MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult
    ) {
        self.handler = handler
    }

    func send(_ command: MusicRemoteCommand) -> MusicRemoteCommandResult {
        handler?(command) ?? .commandFailed
    }
}

final class MusicDetailPresentationTests: XCTestCase {
    func testBlankPlayerTitleMatchesTrackTextFilenameFallback() {
        // Pure production projection only; no claim about hosted title wiring
        // or complete A player visual acceptance. No media file is read.
        for blankTitle in ["", " \t\n ", "\u{3000}\n"] {
            let track = MusicItem(
                url: URL(fileURLWithPath: "/tmp/A-title-fallback-731.mp3"), duration: nil,
                metadata: MusicMetadata(title: blankTitle, artist: nil, album: nil,
                                        artworkData: nil, lyrics: nil, synchronizedLyricsData: nil))
            let shared = MusicTrackTextPresentation(track: track)
            XCTAssertEqual(shared.title, "A-title-fallback-731.mp3", "Shared fallback fixture must retain extension")
            XCTAssertEqual(MusicDetailPresentation(track: track).title, shared.title,
                           "PRESENTATION_RED: blank player title must use shared filename fallback; input \(String(reflecting: blankTitle))")
        }
    }

    func testPlaylistRowsDeclareDetailDestinationWithoutUUIDLookupSourceContract() throws {
        // Source contract only: this does not activate a SwiftUI link or prove a push.
        // The real route pushes MusicPlaylistListView via a view-destination link,
        // then looks up a UUID destination registered only on that pushed view.
        // Parent GUI logs reported both duplicate UUID registration and no visible
        // matching UUID destination. Preserve view-destination navigation for rows.
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("DrivePlayer/Views/MusicHomeView.swift"),
            encoding: .utf8
        )
        let listStart = try XCTUnwrap(source.range(of: "private struct MusicPlaylistListView: View"))
        let detailStart = try XCTUnwrap(source.range(
            of: "private struct MusicPlaylistDetailView: View",
            range: listStart.upperBound..<source.endIndex
        ))
        let listSource = String(source[listStart.lowerBound..<detailStart.lowerBound])

        XCTAssertNotNil(
            listSource.range(
                of: #"NavigationLink\s*\{\s*MusicPlaylistDetailView\s*\(\s*playlistID:\s*playlist\.id,\s*store:\s*store,\s*library:\s*library,\s*playback:\s*playback\s*\)\s*\}\s*label:\s*\{"#,
                options: .regularExpression
            ),
            "Each playlist row must directly present its own MusicPlaylistDetailView; the observed UUID lookup cannot activate the link."
        )
        XCTAssertNil(
            listSource.range(
                of: #"\.navigationDestination\s*\(\s*for:\s*(?:Foundation\.)?UUID\.self"#,
                options: .regularExpression
            ),
            "Remove the pushed list's UUID destination registration implicated by the duplicate / no matching destination runtime diagnostics."
        )
    }

    @MainActor
    func testMusicFavoritePersistsByLogicalNameAndSourceIdentityAcrossContainerRelocation() throws {
        let suiteName = "MusicFavoritesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sourceIdentity = MusicFavoriteSourceIdentity(
            fileSize: 12,
            contentSHA256Hex: String(repeating: "a", count: 64)
        )
        let original = MusicItem(
            url: URL(fileURLWithPath: "/old-container/Documents/Song.mp3"),
            duration: 10,
            favoriteSourceIdentity: sourceIdentity
        )
        let relocated = MusicItem(
            url: URL(fileURLWithPath: "/new-container/Documents/Song.mp3"),
            duration: 10,
            favoriteSourceIdentity: sourceIdentity
        )

        let firstStore = MusicFavoritesStore(defaults: defaults)
        firstStore.toggleFavorite(for: original)
        let relaunchedStore = MusicFavoritesStore(defaults: defaults)

        XCTAssertTrue(relaunchedStore.isFavorite(relocated))
        XCTAssertFalse(String(describing: defaults.dictionaryRepresentation()).contains("old-container"))
    }

    @MainActor
    func testMusicFavoriteDoesNotTransferToSameNameAndSourceAtDifferentLogicalLocation() throws {
        let suiteName = "MusicFavoritesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sourceIdentity = MusicFavoriteSourceIdentity(
            fileSize: 12,
            contentSHA256Hex: String(repeating: "a", count: 64)
        )
        let original = MusicItem(
            url: URL(fileURLWithPath: "/library-A/Song.mp3"),
            duration: 10,
            favoriteSourceIdentity: sourceIdentity
        )
        let replacement = MusicItem(
            url: URL(fileURLWithPath: "/library-B/Song.mp3"),
            duration: 10,
            favoriteSourceIdentity: sourceIdentity
        )

        let store = MusicFavoritesStore(defaults: defaults)
        store.toggleFavorite(for: original)

        XCTAssertFalse(store.isFavorite(replacement))
    }

    @MainActor
    func testMusicFavoriteIntentIsIdempotentForRepeatedCallbacks() throws {
        let suiteName = "MusicFavoritesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let song = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/Song.mp3"),
            duration: 10,
            favoriteSourceIdentity: MusicFavoriteSourceIdentity(
                fileSize: 12,
                contentSHA256Hex: String(repeating: "a", count: 64)
            )
        )
        let store = MusicFavoritesStore(defaults: defaults)

        store.setFavorite(true, for: song)
        let favoriteRevision = store.revision
        let favoriteData = defaults.data(forKey: "MusicFavoritesStore.state.v1")
        store.setFavorite(true, for: song)

        XCTAssertTrue(store.isFavorite(song))
        XCTAssertEqual(store.revision, favoriteRevision)
        XCTAssertEqual(defaults.data(forKey: "MusicFavoritesStore.state.v1"), favoriteData)

        store.setFavorite(false, for: song)
        let unfavoriteRevision = store.revision
        let unfavoriteData = defaults.data(forKey: "MusicFavoritesStore.state.v1")
        store.setFavorite(false, for: song)

        XCTAssertFalse(store.isFavorite(song))
        XCTAssertEqual(store.revision, unfavoriteRevision)
        XCTAssertEqual(defaults.data(forKey: "MusicFavoritesStore.state.v1"), unfavoriteData)
    }

    @MainActor
    func testStaleUnfavoriteIntentCannotRemoveReplacementSourceFavorite() throws {
        let suiteName = "MusicFavoritesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let original = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/Song.mp3"),
            duration: 10,
            favoriteSourceIdentity: MusicFavoriteSourceIdentity(
                fileSize: 12,
                contentSHA256Hex: String(repeating: "a", count: 64)
            )
        )
        let replacement = MusicItem(
            url: original.url,
            duration: 10,
            favoriteSourceIdentity: MusicFavoriteSourceIdentity(
                fileSize: 13,
                contentSHA256Hex: String(repeating: "b", count: 64)
            )
        )
        let store = MusicFavoritesStore(defaults: defaults)
        store.setFavorite(true, for: original)
        store.setFavorite(true, for: replacement)
        let replacementRevision = store.revision
        let replacementData = defaults.data(forKey: "MusicFavoritesStore.state.v1")

        store.setFavorite(false, for: original)

        XCTAssertTrue(store.isFavorite(replacement))
        XCTAssertEqual(store.revision, replacementRevision)
        XCTAssertEqual(defaults.data(forKey: "MusicFavoritesStore.state.v1"), replacementData)
    }

    @MainActor
    func testMusicFavoritesFutureVersionFailsClosed() throws {
        let suiteName = "MusicFavoritesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hash = String(repeating: "a", count: 64)
        let payload = """
        {"version":999,"favorites":[{"logicalLocation":"Documents","fileName":"Song.mp3","sourceIdentity":{"fileSize":12,"contentSHA256Hex":"\(hash)"}}]}
        """.data(using: .utf8)
        defaults.set(payload, forKey: "MusicFavoritesStore.state.v1")
        let song = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/Song.mp3"),
            duration: 10,
            favoriteSourceIdentity: MusicFavoriteSourceIdentity(fileSize: 12, contentSHA256Hex: hash)
        )

        let store = MusicFavoritesStore(defaults: defaults)

        XCTAssertFalse(store.isFavorite(song))
    }

    @MainActor
    func testMusicFavoritesOversizedPayloadFailsClosedBeforeDecode() throws {
        let suiteName = "MusicFavoritesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let oversizedHash = String(repeating: "a", count: 70 * 1024)
        let payload = """
        {"version":1,"favorites":[{"logicalLocation":"Documents","fileName":"Song.mp3","sourceIdentity":{"fileSize":12,"contentSHA256Hex":"\(oversizedHash)"}}]}
        """.data(using: .utf8)
        defaults.set(payload, forKey: "MusicFavoritesStore.state.v1")
        let song = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/Song.mp3"),
            duration: 10,
            favoriteSourceIdentity: MusicFavoriteSourceIdentity(
                fileSize: 12,
                contentSHA256Hex: oversizedHash
            )
        )

        let store = MusicFavoritesStore(defaults: defaults)

        XCTAssertFalse(store.isFavorite(song))
    }

    @MainActor
    func testMusicFavoritesRejectsCandidateThatWouldExceedPayloadWithoutChangingDurableState() throws {
        let suiteName = "MusicFavoritesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MusicFavoritesStore(defaults: defaults)
        var accepted: [MusicItem] = []
        var rejected: MusicItem?
        var durableDataBeforeRejection: Data?
        var revisionBeforeRejection = 0

        for index in 0..<1_024 {
            let song = MusicItem(
                url: URL(fileURLWithPath: "/container/Documents/\(String(repeating: "x", count: 180))-\(index).mp3"),
                duration: 10,
                favoriteSourceIdentity: MusicFavoriteSourceIdentity(
                    fileSize: Int64(index + 1),
                    contentSHA256Hex: String(format: "%064x", index + 1)
                )
            )
            let previousRevision = store.revision
            let previousData = defaults.data(forKey: "MusicFavoritesStore.state.v1")
            store.toggleFavorite(for: song)
            if store.revision == previousRevision {
                rejected = song
                durableDataBeforeRejection = previousData
                revisionBeforeRejection = previousRevision
                break
            }
            accepted.append(song)
        }

        let rejectedSong = try XCTUnwrap(rejected)
        let persistedData = try XCTUnwrap(defaults.data(forKey: "MusicFavoritesStore.state.v1"))
        XCTAssertFalse(accepted.isEmpty)
        XCTAssertEqual(store.revision, revisionBeforeRejection)
        XCTAssertEqual(persistedData, durableDataBeforeRejection)
        XCTAssertLessThanOrEqual(persistedData.count, 64 * 1_024)
        XCTAssertFalse(store.isFavorite(rejectedSong))

        let relaunched = MusicFavoritesStore(defaults: defaults)
        XCTAssertTrue(relaunched.isFavorite(try XCTUnwrap(accepted.first)))
        XCTAssertTrue(relaunched.isFavorite(try XCTUnwrap(accepted.last)))
        XCTAssertFalse(relaunched.isFavorite(rejectedSong))
    }

    @MainActor
    func testMusicFavoritesMalformedSourceIdentityFailsClosed() throws {
        let suiteName = "MusicFavoritesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let malformedHash = "not-a-sha256"
        let payload = """
        {"version":1,"favorites":[{"logicalLocation":"Documents","fileName":"Song.mp3","sourceIdentity":{"fileSize":-1,"contentSHA256Hex":"\(malformedHash)"}}]}
        """.data(using: .utf8)
        defaults.set(payload, forKey: "MusicFavoritesStore.state.v1")
        let song = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/Song.mp3"),
            duration: 10,
            favoriteSourceIdentity: MusicFavoriteSourceIdentity(
                fileSize: -1,
                contentSHA256Hex: malformedHash
            )
        )

        let store = MusicFavoritesStore(defaults: defaults)

        XCTAssertFalse(store.isFavorite(song))
    }

    func testMusicLibraryWiresAuthenticatedSourceFingerprintIntoFavoriteIdentity() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("DrivePlayer/Services/MusicLibrary.swift"),
            encoding: .utf8
        )

        for fragment in [
            "favoriteSourceIdentity: MusicFavoriteSourceIdentity(",
            "fileSize: fingerprint.fileSize",
            "contentSHA256Hex: fingerprint.contentSHA256Hex",
        ] {
            XCTAssertTrue(source.contains(fragment), "MusicLibrary.swift is missing: \(fragment)")
        }
    }

    @MainActor
    func testMusicFavoritesReconciliationPermanentlyDropsReplacedSource() throws {
        let suiteName = "MusicFavoritesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let original = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/Song.mp3"),
            duration: 10,
            favoriteSourceIdentity: MusicFavoriteSourceIdentity(
                fileSize: 12,
                contentSHA256Hex: String(repeating: "a", count: 64)
            )
        )
        let replacement = MusicItem(
            url: original.url,
            duration: 10,
            favoriteSourceIdentity: MusicFavoriteSourceIdentity(
                fileSize: 12,
                contentSHA256Hex: String(repeating: "b", count: 64)
            )
        )
        let store = MusicFavoritesStore(defaults: defaults)
        store.toggleFavorite(for: original)

        store.reconcile(with: MusicFavoritesReconciliationSnapshot(songs: [replacement]))
        let relaunched = MusicFavoritesStore(defaults: defaults)

        XCTAssertFalse(relaunched.isFavorite(original))
        XCTAssertFalse(relaunched.isFavorite(replacement))
    }

    @MainActor
    func testMusicFavoritesScanFailureDoesNotPrunePersistedFavorite() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not-a-directory".utf8).write(to: temporaryRoot)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let storage = MediaLibraryStorage(
            rootURL: temporaryRoot,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio"),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos"),
            fileManager: fileManager
        )
        let library = MusicLibrary(storage: storage)
        let suiteName = "MusicFavoritesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let song = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/Song.mp3"),
            duration: 10,
            favoriteSourceIdentity: MusicFavoriteSourceIdentity(
                fileSize: 12,
                contentSHA256Hex: String(repeating: "a", count: 64)
            )
        )
        let store = MusicFavoritesStore(defaults: defaults)
        store.toggleFavorite(for: song)

        let snapshot = await library.refresh()
        store.reconcile(with: snapshot)

        XCTAssertTrue(MusicFavoritesStore(defaults: defaults).isFavorite(song))
    }

    @MainActor
    func testMusicFavoritesUnavailableScannedIdentityDoesNotPrunePersistedFavorite() throws {
        let suiteName = "MusicFavoritesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let song = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/Song.mp3"),
            duration: 10,
            favoriteSourceIdentity: MusicFavoriteSourceIdentity(
                fileSize: 12,
                contentSHA256Hex: String(repeating: "a", count: 64)
            )
        )
        let store = MusicFavoritesStore(defaults: defaults)
        store.toggleFavorite(for: song)
        let snapshot = MusicFavoritesReconciliationSnapshot(
            isAuthoritative: true,
            entries: [
                .init(logicalLocation: "Documents", fileName: "Song.mp3", sourceIdentity: nil)
            ]
        )

        store.reconcile(with: snapshot)

        XCTAssertTrue(MusicFavoritesStore(defaults: defaults).isFavorite(song))
    }

    @MainActor
    func testMusicFavoritesFilterIntersectsSearchWithoutChangingOriginalOrder() throws {
        let suiteName = "MusicFavoritesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identity = MusicFavoriteSourceIdentity(
            fileSize: 12,
            contentSHA256Hex: String(repeating: "a", count: 64)
        )
        let favoriteMatch = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/Needle One.mp3"),
            duration: 10,
            favoriteSourceIdentity: identity
        )
        let nonFavoriteMatch = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/Needle Two.mp3"),
            duration: 10,
            favoriteSourceIdentity: MusicFavoriteSourceIdentity(
                fileSize: 13,
                contentSHA256Hex: String(repeating: "b", count: 64)
            )
        )
        let favoriteNonMatch = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/Other.mp3"),
            duration: 10,
            favoriteSourceIdentity: MusicFavoriteSourceIdentity(
                fileSize: 14,
                contentSHA256Hex: String(repeating: "c", count: 64)
            )
        )
        let store = MusicFavoritesStore(defaults: defaults)
        store.toggleFavorite(for: favoriteMatch)
        store.toggleFavorite(for: favoriteNonMatch)

        let filtered = MusicLibraryFilter.filteredSongs(
            [favoriteNonMatch, nonFavoriteMatch, favoriteMatch],
            selection: .favorites,
            favorites: store,
            query: " needle "
        )

        XCTAssertEqual(filtered, [favoriteMatch])
    }

    func testMusicLibraryFilterPreferenceDefaultsAllAndPersistsFavorites() throws {
        let suiteName = "MusicLibraryFilterPreferenceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(MusicLibraryFilterPreferenceStore(defaults: defaults).load(), .all)

        MusicLibraryFilterPreferenceStore(defaults: defaults).save(.favorites)

        XCTAssertEqual(MusicLibraryFilterPreferenceStore(defaults: defaults).load(), .favorites)
    }

    func testMusicFavoritesUIWiresAccessibleControlsFilterEmptyStateAndFullQueueSemantics() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rootSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("DrivePlayer/Views/RootTabView.swift"),
            encoding: .utf8
        )
        let homeSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("DrivePlayer/Views/MusicHomeView.swift"),
            encoding: .utf8
        )
        let playerSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("DrivePlayer/Views/MusicPlayerView.swift"),
            encoding: .utf8
        )

        for fragment in [
            "@StateObject private var favorites = MusicFavoritesStore()",
            "MusicHomeView(library: musicLibrary, playback: playback, favorites: favorites, recentlyPlayed: recentlyPlayed, playlists: playlists)",
            "MusicPlayerView(playback: playback, favorites: favorites)",
            "favorites.reconcile(with: favoritesSnapshot)",
        ] {
            XCTAssertTrue(rootSource.contains(fragment), "RootTabView.swift is missing: \(fragment)")
        }
        for fragment in [
            "@ObservedObject var favorites: MusicFavoritesStore",
            "MusicLibraryFilter.filteredSongs(",
            "selection: selectedFilter",
            "Picker(\"音乐筛选\", selection: $selectedFilter)",
            ".accessibilityIdentifier(\"music-library-filter\")",
            "MusicLibraryFilterPreferenceStore(defaults: .standard).save(selectedFilter)",
            "favorites.setFavorite(!isFavorite, for: song)",
            ".accessibilityIdentifier(\"music-library-favorite-\\(song.id)\")",
            "Text(\"还没有收藏音乐\")",
            "MusicPlaylistCoordinator(store: playlists, playback: playback)",
            ".synchronize(snapshot: favoritesSnapshot, library: library.songs)",
            "favorites.reconcile(with: favoritesSnapshot)",
        ] {
            XCTAssertTrue(homeSource.contains(fragment), "MusicHomeView.swift is missing: \(fragment)")
        }
        for fragment in [
            "@ObservedObject var favorites: MusicFavoritesStore",
            "favorites.setFavorite(!isFavorite, for: currentTrack)",
            ".accessibilityIdentifier(\"music-player-favorite-toggle\")",
            ".accessibilityLabel(isFavorite ? \"取消收藏\" : \"收藏\")",
        ] {
            XCTAssertTrue(playerSource.contains(fragment), "MusicPlayerView.swift is missing: \(fragment)")
        }
        XCTAssertFalse(homeSource.contains("playback.updateQueue(displayedSongs)"))
    }

    @MainActor
    func testMusicRecentlyPlayedPersistsUniqueMostRecentFirstAcrossContainerRelocation() throws {
        let suiteName = "MusicRecentlyPlayedStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identityA = MusicFavoriteSourceIdentity(
            fileSize: 12,
            contentSHA256Hex: String(repeating: "a", count: 64)
        )
        let identityB = MusicFavoriteSourceIdentity(
            fileSize: 13,
            contentSHA256Hex: String(repeating: "b", count: 64)
        )
        let first = MusicItem(
            url: URL(fileURLWithPath: "/old-container/Documents/First.mp3"),
            duration: 10,
            favoriteSourceIdentity: identityA
        )
        let second = MusicItem(
            url: URL(fileURLWithPath: "/old-container/Documents/Second.mp3"),
            duration: 10,
            favoriteSourceIdentity: identityB
        )
        let store = MusicRecentlyPlayedStore(defaults: defaults)

        store.record(first)
        store.record(second)
        store.record(first)

        let relocated = [
            MusicItem(url: URL(fileURLWithPath: "/new-container/Documents/Second.mp3"), duration: 10, favoriteSourceIdentity: identityB),
            MusicItem(url: URL(fileURLWithPath: "/new-container/Documents/First.mp3"), duration: 10, favoriteSourceIdentity: identityA),
        ]
        let relaunched = MusicRecentlyPlayedStore(defaults: defaults)
        XCTAssertEqual(relaunched.orderedMatchingSongs(in: relocated).map(\.fileName), ["First.mp3", "Second.mp3"])
        XCTAssertEqual(relaunched.revision, 0)
        let payloadText = String(data: try XCTUnwrap(defaults.data(forKey: "MusicRecentlyPlayedStore.state.v1")), encoding: .utf8)
        XCTAssertFalse(try XCTUnwrap(payloadText).contains("old-container"))
    }

    func testRecentlyPlayedUIWiresFilterFullQueueEmptyStateAndAccessibleClearConfirmation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let rootSource = try String(contentsOf: root.appendingPathComponent("DrivePlayer/Views/RootTabView.swift"), encoding: .utf8)
        let homeSource = try String(contentsOf: root.appendingPathComponent("DrivePlayer/Views/MusicHomeView.swift"), encoding: .utf8)
        for fragment in ["@StateObject private var recentlyPlayed", "recentlyPlayed: recentlyPlayed", "recentlyPlayed.reconcile"] {
            XCTAssertTrue(rootSource.contains(fragment), "Root missing \(fragment)")
        }
        for fragment in ["Text(\"最近播放\")", "Text(\"还没有最近播放的音乐\")", "music-clear-recent-history", "清除最近播放记录", "role: .destructive", "MusicPlaylistCoordinator(store: playlists, playback: playback)", ".synchronize(snapshot: favoritesSnapshot, library: library.songs)"] {
            XCTAssertTrue(homeSource.contains(fragment), "Home missing \(fragment)")
        }
        XCTAssertFalse(homeSource.contains("playback.updateQueue(displayedSongs)"))
        XCTAssertTrue(homeSource.contains(".disabled(recentlyPlayed.isEmpty)"))
    }

    @MainActor
    func testRecentlyPlayedDurableAvailabilitySurvivesNilEnrichmentAndClearIsPlaybackIndependent() throws {
        let suiteName = "MusicRecentlyPlayedDurableAvailability.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identity = MusicFavoriteSourceIdentity(
            fileSize: 4,
            contentSHA256Hex: String(repeating: "a", count: 64)
        )
        let enriched = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/Song.mp3"),
            duration: 60,
            favoriteSourceIdentity: identity
        )
        let temporarilyUnenriched = MusicItem(
            url: enriched.url,
            duration: 60,
            favoriteSourceIdentity: nil
        )
        let store = MusicRecentlyPlayedStore(defaults: defaults)
        store.record(enriched)
        store.reconcile(with: .init(
            isAuthoritative: true,
            entries: [.init(
                logicalLocation: "Documents",
                fileName: "Song.mp3",
                sourceIdentity: nil
            )]
        ))

        XCTAssertTrue(store.orderedMatchingSongs(in: [temporarilyUnenriched]).isEmpty)
        XCTAssertFalse(store.isEmpty)
        let revisionBeforeClear = store.revision
        store.clear()
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.revision, revisionBeforeClear + 1)
        XCTAssertNil(defaults.data(forKey: MusicRecentlyPlayedStore.persistenceKey))
        let revisionAfterClear = store.revision
        store.clear()
        XCTAssertEqual(store.revision, revisionAfterClear)
    }

    @MainActor
    func testMusicRecentlyPlayedRejectsFutureMalformedOversizedAndDuplicatePayloads() throws {
        let suiteName = "MusicRecentlyPlayedInvalidTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = MusicRecentlyPlayedStore.persistenceKey
        let validRecord = "{\"logicalLocation\":\"Documents\",\"fileName\":\"Song.mp3\",\"sourceIdentity\":{\"fileSize\":4,\"contentSHA256Hex\":\"\(String(repeating: "a", count: 64))\"}}"
        let song = MusicItem(url: URL(fileURLWithPath: "/new/Documents/Song.mp3"), duration: 1, favoriteSourceIdentity: .init(fileSize: 4, contentSHA256Hex: String(repeating: "a", count: 64)))
        for data in [
            Data("{\"version\":2,\"records\":[\(validRecord)]}".utf8),
            Data("not-json".utf8),
            Data(repeating: 0x61, count: 64 * 1_024 + 1),
            Data("{\"version\":1,\"records\":[\(validRecord),\(validRecord)]}".utf8),
        ] {
            defaults.set(data, forKey: key)
            XCTAssertTrue(MusicRecentlyPlayedStore(defaults: defaults).orderedMatchingSongs(in: [song]).isEmpty)
        }
    }

    @MainActor
    func testMusicRecentlyPlayedRejectsOversizedCandidateAtomically() throws {
        let suiteName = "MusicRecentlyPlayedOversizedCandidate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identity = MusicFavoriteSourceIdentity(
            fileSize: 4,
            contentSHA256Hex: String(repeating: "a", count: 64)
        )
        let accepted = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/Accepted.mp3"),
            duration: 1,
            favoriteSourceIdentity: identity
        )
        let store = MusicRecentlyPlayedStore(defaults: defaults)
        store.record(accepted)
        let persistedBefore = try XCTUnwrap(defaults.data(forKey: MusicRecentlyPlayedStore.persistenceKey))
        let orderBefore = store.orderedMatchingSongs(in: [accepted]).map(\.fileName)
        let revisionBefore = store.revision

        let oversizedName = String(repeating: "x", count: 70_000) + ".mp3"
        let oversized = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/\(oversizedName)"),
            duration: 1,
            favoriteSourceIdentity: .init(
                fileSize: 5,
                contentSHA256Hex: String(repeating: "b", count: 64)
            )
        )
        XCTAssertEqual(oversized.fileName, oversizedName, "The candidate must remain one valid logical component")

        store.record(oversized)

        XCTAssertEqual(defaults.data(forKey: MusicRecentlyPlayedStore.persistenceKey), persistedBefore)
        XCTAssertEqual(store.orderedMatchingSongs(in: [accepted, oversized]).map(\.fileName), orderBefore)
        XCTAssertEqual(store.revision, revisionBefore)
        XCTAssertFalse(store.orderedMatchingSongs(in: [oversized]).contains(oversized))
    }

    @MainActor
    func testMusicRecentlyPlayedAuthenticatesLogicalLocationAndAuthoritativeMovePrunesDurably() throws {
        let suiteName = "MusicRecentlyPlayedLogicalLocation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identity = MusicFavoriteSourceIdentity(
            fileSize: 4,
            contentSHA256Hex: String(repeating: "a", count: 64)
        )
        let atA = MusicItem(
            url: URL(fileURLWithPath: "/container/LocationA/Song.mp3"),
            duration: 1,
            favoriteSourceIdentity: identity
        )
        let atB = MusicItem(
            url: URL(fileURLWithPath: "/container/LocationB/Song.mp3"),
            duration: 1,
            favoriteSourceIdentity: identity
        )
        let store = MusicRecentlyPlayedStore(defaults: defaults)
        store.record(atA)

        XCTAssertEqual(store.orderedMatchingSongs(in: [atA]), [atA])
        XCTAssertTrue(store.orderedMatchingSongs(in: [atB]).isEmpty)

        store.reconcile(with: .init(songs: [atB]))

        XCTAssertTrue(store.isEmpty)
        XCTAssertTrue(store.orderedMatchingSongs(in: [atA, atB]).isEmpty)
        let persistedEmptyState = try XCTUnwrap(defaults.data(forKey: MusicRecentlyPlayedStore.persistenceKey))
        let relaunched = MusicRecentlyPlayedStore(defaults: defaults)
        XCTAssertTrue(relaunched.isEmpty)
        XCTAssertTrue(relaunched.orderedMatchingSongs(in: [atA, atB]).isEmpty)
        XCTAssertEqual(defaults.data(forKey: MusicRecentlyPlayedStore.persistenceKey), persistedEmptyState)
    }

    @MainActor
    func testMusicRecentlyPlayedBoundsToOneHundredAndClearIsIdempotent() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MusicRecentlyPlayedBounds.\(UUID().uuidString)"))
        let store = MusicRecentlyPlayedStore(defaults: defaults)
        let songs = (0..<101).map { index in
            MusicItem(
                url: URL(fileURLWithPath: "/container/Documents/\(index).mp3"), duration: 1,
                favoriteSourceIdentity: .init(fileSize: Int64(index), contentSHA256Hex: String(format: "%064x", index))
            )
        }
        songs.forEach(store.record)
        XCTAssertEqual(store.orderedMatchingSongs(in: songs).count, 100)
        XCTAssertFalse(store.orderedMatchingSongs(in: songs).contains(songs[0]))
        store.clear()
        let revision = store.revision
        store.clear()
        XCTAssertEqual(store.revision, revision)
    }

    @MainActor
    func testMusicRecentlyPlayedAuthoritativeReconcilePrunesDeletionAndChangedIdentityButUnavailableAndNilIdentityPreserve() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MusicRecentlyPlayedReconcile.\(UUID().uuidString)"))
        let identity = MusicFavoriteSourceIdentity(fileSize: 4, contentSHA256Hex: String(repeating: "a", count: 64))
        let song = MusicItem(url: URL(fileURLWithPath: "/container/Documents/Song.mp3"), duration: 1, favoriteSourceIdentity: identity)
        let store = MusicRecentlyPlayedStore(defaults: defaults)
        store.record(song)
        store.reconcile(with: .unavailable)
        store.reconcile(with: .init(isAuthoritative: true, entries: [.init(logicalLocation: "Documents", fileName: "Song.mp3", sourceIdentity: nil)]))
        XCTAssertEqual(store.orderedMatchingSongs(in: [song]), [song])
        store.reconcile(with: .init(isAuthoritative: true, entries: [.init(logicalLocation: "Documents", fileName: "Song.mp3", sourceIdentity: .init(fileSize: 5, contentSHA256Hex: String(repeating: "b", count: 64)))]))
        XCTAssertTrue(store.orderedMatchingSongs(in: [song]).isEmpty)
    }

    @MainActor
    func testMusicRecentlyPlayedFilterIntersectsSearchInRecencyOrderAndFavoritesRemainIndependent() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MusicRecentlyPlayedFilter.\(UUID().uuidString)"))
        let recent = MusicRecentlyPlayedStore(defaults: defaults)
        let favorites = MusicFavoritesStore(defaults: defaults)
        let a = MusicItem(url: URL(fileURLWithPath: "/c/Documents/Needle A.mp3"), duration: 1, favoriteSourceIdentity: .init(fileSize: 1, contentSHA256Hex: String(repeating: "a", count: 64)))
        let b = MusicItem(url: URL(fileURLWithPath: "/c/Documents/Needle B.mp3"), duration: 1, favoriteSourceIdentity: .init(fileSize: 2, contentSHA256Hex: String(repeating: "b", count: 64)))
        recent.record(a); recent.record(b); favorites.setFavorite(true, for: a)
        XCTAssertEqual(MusicLibraryFilter.filteredSongs([a, b], selection: .recentlyPlayed, favorites: favorites, recentlyPlayed: recent, query: "needle"), [b, a])
        recent.clear()
        XCTAssertTrue(favorites.isFavorite(a))
    }

    func testMusicLibrarySearchMatchesFilenameTitleAndArtistInOriginalOrder() {
        let filenameMatch = MusicItem(
            url: URL(fileURLWithPath: "/tmp/Needle Recording.mp3"),
            duration: 10
        )
        let titleMatch = MusicItem(
            url: URL(fileURLWithPath: "/tmp/title-match.mp3"),
            duration: 20,
            metadata: MusicMetadata(
                title: "  nEeDlE in the Title\n",
                artist: nil,
                album: nil,
                artworkData: nil,
                lyrics: nil,
                synchronizedLyricsData: nil
            )
        )
        let albumOnlyMatch = MusicItem(
            url: URL(fileURLWithPath: "/tmp/album-only.mp3"),
            duration: 30,
            metadata: MusicMetadata(
                title: "Unrelated title",
                artist: "Unrelated artist",
                album: "Needle Album",
                artworkData: nil,
                lyrics: nil,
                synchronizedLyricsData: nil
            )
        )
        let artistMatch = MusicItem(
            url: URL(fileURLWithPath: "/tmp/artist-match.mp3"),
            duration: 40,
            metadata: MusicMetadata(
                title: "Another title",
                artist: "\tNEEDLE Artist  ",
                album: nil,
                artworkData: nil,
                lyrics: nil,
                synchronizedLyricsData: nil
            )
        )
        let lyricsOnlyMatch = MusicItem(
            url: URL(fileURLWithPath: "/tmp/lyrics-only.mp3"),
            duration: 50,
            metadata: MusicMetadata(
                title: "No result",
                artist: nil,
                album: nil,
                artworkData: nil,
                lyrics: "Needle appears only in lyrics",
                synchronizedLyricsData: nil
            )
        )
        let absolutePathOnlyMatch = MusicItem(
            url: URL(fileURLWithPath: "/tmp/Needle Folder/path-only.mp3"),
            duration: 60
        )
        let songs = [
            filenameMatch,
            titleMatch,
            albumOnlyMatch,
            artistMatch,
            lyricsOnlyMatch,
            absolutePathOnlyMatch,
        ]

        let filtered = MusicLibrarySearch.filteredSongs(songs, query: "  \nnEeDlE\t ")

        XCTAssertEqual(filtered, [filenameMatch, titleMatch, artistMatch])
    }

    func testMusicLibrarySearchReturnsAllSongsForBlankQueryInOriginalOrder() {
        let thirdSong = MusicItem(
            url: URL(fileURLWithPath: "/tmp/third.mp3"),
            duration: 30
        )
        let firstSong = MusicItem(
            url: URL(fileURLWithPath: "/tmp/first.mp3"),
            duration: 10
        )
        let secondSong = MusicItem(
            url: URL(fileURLWithPath: "/tmp/second.mp3"),
            duration: 20
        )
        let songs = [thirdSong, firstSong, secondSong]

        let emptyQueryResult = MusicLibrarySearch.filteredSongs(songs, query: "")
        let whitespaceQueryResult = MusicLibrarySearch.filteredSongs(songs, query: " \t\n ")

        XCTAssertEqual(emptyQueryResult, songs)
        XCTAssertEqual(whitespaceQueryResult, songs)
    }

    func testMusicTrackTextPresentationUsesTrimmedMetadataOrTrackFallbacks() {
        let metadataTrack = MusicItem(
            url: URL(fileURLWithPath: "/tmp/metadata-fallback.mp3"),
            duration: 10,
            metadata: MusicMetadata(
                title: "  Display Title  ",
                artist: "  Display Artist  ",
                album: nil,
                artworkData: nil,
                lyrics: nil,
                synchronizedLyricsData: nil
            )
        )
        let fallbackTrack = MusicItem(
            url: URL(fileURLWithPath: "/tmp/fallback.mp3"),
            duration: 10,
            metadata: MusicMetadata(
                title: " \n\t ",
                artist: "   ",
                album: nil,
                artworkData: nil,
                lyrics: nil,
                synchronizedLyricsData: nil
            )
        )

        let metadataPresentation = MusicTrackTextPresentation(track: metadataTrack)
        let fallbackPresentation = MusicTrackTextPresentation(track: fallbackTrack)

        XCTAssertEqual(metadataPresentation.title, "Display Title")
        XCTAssertEqual(metadataPresentation.artist, "Display Artist")
        XCTAssertEqual(fallbackPresentation.title, "fallback.mp3")
        XCTAssertNil(fallbackPresentation.artist)
    }

    func testMusicQueueRowPresentationUsesTrimmedMetadataAndSafeFallbacks() {
        let metadataTrack = MusicItem(
            url: URL(fileURLWithPath: "/tmp/fallback.mp3"),
            duration: 10,
            metadata: MusicMetadata(
                title: "  Display Title  ",
                artist: "  Display Artist  ",
                album: nil,
                artworkData: nil,
                lyrics: nil,
                synchronizedLyricsData: nil
            )
        )
        let fallbackTrack = MusicItem(
            url: URL(fileURLWithPath: "/tmp/fallback.mp3"),
            duration: 10,
            metadata: MusicMetadata(
                title: " \n\t ",
                artist: "   ",
                album: nil,
                artworkData: nil,
                lyrics: nil,
                synchronizedLyricsData: nil
            )
        )

        let metadataPresentation = MusicQueueRowPresentation(
            track: metadataTrack,
            index: 0,
            isCurrent: false
        )
        let fallbackPresentation = MusicQueueRowPresentation(
            track: fallbackTrack,
            index: 1,
            isCurrent: false
        )

        XCTAssertEqual(metadataPresentation.title, "Display Title")
        XCTAssertEqual(metadataPresentation.artist, "Display Artist")
        XCTAssertEqual(fallbackPresentation.title, "fallback.mp3")
        XCTAssertNil(fallbackPresentation.artist)
    }

    func testMusicQueueRowPresentationExposesIndexIdentityAndCurrentState() {
        let track = MusicItem(
            url: URL(fileURLWithPath: "/tmp/unsafe / 名称.mp3"),
            duration: 10
        )

        let current = MusicQueueRowPresentation(track: track, index: 7, isCurrent: true)
        let nonCurrent = MusicQueueRowPresentation(track: track, index: 8, isCurrent: false)

        XCTAssertEqual(current.accessibilityIdentifier, "music-queue-row-7")
        XCTAssertEqual(current.accessibilityValue, "当前播放")
        XCTAssertTrue(current.isCurrent)
        XCTAssertEqual(nonCurrent.accessibilityIdentifier, "music-queue-row-8")
        XCTAssertEqual(nonCurrent.accessibilityValue, "非当前播放")
        XCTAssertFalse(nonCurrent.isCurrent)
    }

    func testMusicPlayerWiresReadOnlyQueueSheetToExistingPlaybackSemantics() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("DrivePlayer/Views/MusicPlayerView.swift"),
            encoding: .utf8
        )

        let secondary = try XCTUnwrap(source.range(of: "private var secondaryControls: some View"))
        let end = try XCTUnwrap(source.range(of: "private var moreSheet: some View", range: secondary.upperBound..<source.endIndex))
        let controls = String(source[secondary.lowerBound..<end.lowerBound])
        XCTAssertTrue(controls.contains("Button { showsQueue = true } label:"))
        XCTAssertTrue(controls.contains(".accessibilityLabel(\"播放队列\")"))
        XCTAssertTrue(controls.contains(".accessibilityIdentifier(\"music-queue-entry\")"))
        // Real entry/row/empty/Done behavior is covered by the hosted queue tests.
        for fragment in [
            ".accessibilityIdentifier(\"music-queue-entry\")",
            ".sheet(isPresented: $showsQueue)",
            "MusicQueueSheet(playback: playback)",
            ".navigationTitle(\"播放队列\")",
            "ForEach(Array(playback.queue.enumerated()), id: \\.offset)",
            "isCurrent: playback.currentIndex == index",
            "Image(systemName: \"speaker.wave.2.fill\")",
            ".accessibilityIdentifier(presentation.accessibilityIdentifier)",
            ".accessibilityValue(presentation.accessibilityValue)",
            "playback.play(track)",
            "Text(\"播放队列为空\")",
        ] {
            XCTAssertTrue(source.contains(fragment), "MusicPlayerView.swift is missing: \(fragment)")
        }
    }

    func testMusicQueueButtonLabelUsesFullWidthLeadingRectangularHitTarget() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("DrivePlayer/Views/MusicPlayerView.swift"),
            encoding: .utf8
        )
        let queueButtonLabel = try XCTUnwrap(
            source.range(
                of: #"Button \{\s*playback\.play\(track\)\s*\} label: \{(?<label>[\s\S]*?)\n\s*\}\n\s*\.buttonStyle\(\.plain\)"#,
                options: .regularExpression
            ).map { String(source[$0]) }
        )

        XCTAssertTrue(
            queueButtonLabel.contains(".frame(maxWidth: .infinity, alignment: .leading)"),
            "Queue button label must fill the available row width with leading alignment"
        )
        XCTAssertTrue(
            queueButtonLabel.contains(".contentShape(Rectangle())"),
            "Queue button label must use an explicit rectangular hit target"
        )
    }

    func testMusicPlayerExposesAccessibleDirectThreeOptionCompletionSelector() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("DrivePlayer/Views/MusicPlayerView.swift"), encoding: .utf8)
        // Wiring only. Three real menu actions and unique AX selection are
        // enforced by MusicMenuUITests.testCompletionRepeatAllRealSelection,
        // testCompletionRepeatOneRealSelection and testCompletionStopAtEndRealSelection.
        for fragment in [
            "ForEach(MusicCompletionMode.allCases, id: \\.self)",
            "case .repeatAll: \"列表循环\"", "case .repeatOne: \"单曲循环\"", "case .stopAtEnd: \"播完停止\"",
            "playback.setCompletionMode(mode)",
            ".accessibilityIdentifier(\"music-completion-mode-\\(mode.rawValue)\")",
            ".accessibilityIdentifier(\"music-completion-mode-menu\")",
            ".accessibilityLabel(\"播放完成方式\")",
            ".accessibilityValue(completionModeLabelText(playback.completionMode))",
        ] {
            XCTAssertTrue(source.contains(fragment), "MusicPlayerView.swift is missing: \(fragment)")
        }
    }

    func testMusicPlayerExposesClearlyLabeledAccessibleShuffleToggleWithSelectedState() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: repositoryRoot.appendingPathComponent("DrivePlayer/Views/MusicPlayerView.swift"), encoding: .utf8)
        for fragment in [
            "Image(systemName: \"shuffle\")",
            "playback.setShuffleEnabled(!isShuffleSelected)",
            ".accessibilityIdentifier(\"music-shuffle-toggle\")",
            ".accessibilityLabel(\"随机播放\")",
            ".accessibilityValue(isShuffleSelected ? \"已选择\" : \"未选择\")",
            ".accessibilityAddTraits(isShuffleSelected ? .isSelected : [])",
        ] {
            XCTAssertTrue(source.contains(fragment), "MusicPlayerView.swift is missing: \(fragment)")
        }
    }

    func testMusicImportPolicyAllowsAudioAndLowercaseLRCOnly() {
        XCTAssertTrue(MusicImportPolicy.allowedContentTypes.contains(.audio))
        XCTAssertTrue(
            MusicImportPolicy.allowedContentTypes.contains(UTType(filenameExtension: "lrc")!)
        )
        XCTAssertFalse(MusicImportPolicy.allowedContentTypes.contains(.plainText))
    }

    func testMusicHomeFileImporterUsesMusicImportPolicy() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let musicHomeViewURL = repositoryRoot.appendingPathComponent("DrivePlayer/Views/MusicHomeView.swift")
        let source = try String(contentsOf: musicHomeViewURL, encoding: .utf8)

        XCTAssertTrue(source.contains("allowedContentTypes: MusicImportPolicy.allowedContentTypes"))
        XCTAssertFalse(source.contains("allowedContentTypes: [.audio]"))
    }

    func testMusicHomeSearchFiltersDisplayedRowsWithoutChangingPlaybackQueue() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("DrivePlayer/Views/MusicHomeView.swift"),
            encoding: .utf8
        )

        for fragment in [
            "@State private var searchText = \"\"",
            "let displayedSongs = MusicLibraryFilter.filteredSongs(",
            "selection: selectedFilter",
            "favorites: favorites",
            "query: searchText",
            "ForEach(displayedSongs)",
            ".searchable(text: $searchText, prompt: \"搜索音乐\")",
            "playback.playFromLibrary(song, library: library.songs)",
        ] {
            XCTAssertTrue(source.contains(fragment), "MusicHomeView.swift is missing: \(fragment)")
        }
        XCTAssertEqual(
            source.components(separatedBy: ".synchronize(snapshot:").count - 1,
            3,
            "Refresh, deletion, and import must each use exactly one playlist/library coordinator path"
        )
        XCTAssertFalse(
            source.contains("playback.updateQueue(displayedSongs)"),
            "Search results must never replace the full playback queue"
        )
    }

    func testMusicHomeUsesSearchEmptyStateOnlyAfterOriginalLibraryEmptyState() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("DrivePlayer/Views/MusicHomeView.swift"),
            encoding: .utf8
        )
        let libraryEmptyRange = source.range(of: "else if library.songs.isEmpty {")
        let searchEmptyRange = source.range(
            of: "else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && displayedSongs.isEmpty {"
        )

        XCTAssertNotNil(libraryEmptyRange, "MusicHomeView.swift must preserve the original empty-library state")
        XCTAssertNotNil(searchEmptyRange, "MusicHomeView.swift must show an empty state for nonblank searches with no results")
        XCTAssertTrue(
            source.contains("ContentUnavailableView.search(text: searchText)"),
            "The search empty state must use the query-aware system presentation"
        )

        if let libraryEmptyRange, let searchEmptyRange {
            let libraryEmptyOffset = source.distance(from: source.startIndex, to: libraryEmptyRange.lowerBound)
            let searchEmptyOffset = source.distance(from: source.startIndex, to: searchEmptyRange.lowerBound)
            XCTAssertLessThan(
                libraryEmptyOffset,
                searchEmptyOffset,
                "The original empty-library import guidance must take precedence over search results"
            )
        }
    }

    func testMusicLibraryRowsShowTrackMetadataWhilePreservingPlaybackArtworkDurationAndDeletion() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repositoryRoot.appendingPathComponent("DrivePlayer/Views/MusicHomeView.swift"),
            encoding: .utf8
        )
        let libraryRows = try XCTUnwrap(
            source.range(
                of: #"ForEach\(displayedSongs\) \{ song in(?<rows>[\s\S]*?)\n\s*\}\n\s*\.refreshable"#,
                options: .regularExpression
            ).map { String(source[$0]) }
        )

        for fragment in [
            "let textPresentation = MusicTrackTextPresentation(track: song)",
            "Text(textPresentation.title)",
            "if let artist = textPresentation.artist",
            "Text(artist)",
            "Text(song.formattedDuration)",
            "MusicListArtworkPresentation(track: song)",
            "if isCurrent(song)",
            "playback.playFromLibrary(song, library: library.songs)",
            ".swipeActions",
            "pendingDeletion = song",
        ] {
            XCTAssertTrue(libraryRows.contains(fragment), "Music library row is missing: \(fragment)")
        }
        XCTAssertFalse(
            libraryRows.contains("Text(song.fileName)"),
            "Music library rows must not expose the file name directly as their primary title"
        )
    }

    func testMusicImportFeedbackReportsSongsAndLyricsSeparately() {
        let report = MusicLibrary.ImportReport(
            importedSongCount: 1,
            importedLyricCount: 2,
            failedFileNames: []
        )

        let presentation = MusicImportFeedback.presentation(for: report)

        XCTAssertEqual(presentation.title, "导入完成")
        XCTAssertEqual(presentation.message, "已导入 1 首音乐、2 个歌词文件。")
    }

    func testMusicImportFeedbackReportsPartialSongsAndLyricsSeparately() {
        let report = MusicLibrary.ImportReport(
            importedSongCount: 1,
            importedLyricCount: 2,
            failedFileNames: ["bad.txt"]
        )

        let presentation = MusicImportFeedback.presentation(for: report)

        XCTAssertEqual(presentation.title, "部分文件未导入")
        XCTAssertEqual(presentation.message, "已导入 1 首音乐、2 个歌词文件；以下文件失败：bad.txt。")
    }

    func testPersistedVideoAutoAdvanceChoiceControlsPlayerFinishPolicy() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let homeViewURL = repositoryRoot.appendingPathComponent("DrivePlayer/Views/HomeView.swift")
        let playerViewURL = repositoryRoot.appendingPathComponent("DrivePlayer/Views/PlayerView.swift")
        let homeViewSource = try String(contentsOf: homeViewURL, encoding: .utf8)
        let playerViewSource = try String(contentsOf: playerViewURL, encoding: .utf8)

        let homeViewFragments = [
            "videoAutoAdvanceEnabled: isVideoAutoAdvanceEnabled",
        ]
        let playerViewFragments = [
            "private let videoAutoAdvanceEnabled: Bool",
            "videoAutoAdvanceEnabled: Bool,",
            "self.videoAutoAdvanceEnabled = videoAutoAdvanceEnabled",
            "guard let request = VideoAutoAdvanceCompletionPolicy.successfulFinish(",
            "isEnabled: videoAutoAdvanceEnabled,",
            "controller: &autoAdvance,",
        ]

        for fragment in homeViewFragments {
            XCTAssertTrue(homeViewSource.contains(fragment), "HomeView.swift is missing: \(fragment)")
        }
        for fragment in playerViewFragments {
            XCTAssertTrue(playerViewSource.contains(fragment), "PlayerView.swift is missing: \(fragment)")
        }
    }

    func testHomeViewExposesPersistentVideoAutoAdvanceToggle() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let homeViewURL = repositoryRoot.appendingPathComponent("DrivePlayer/Views/HomeView.swift")
        let source = try String(contentsOf: homeViewURL, encoding: .utf8)
        let contractFragments = [
            "@State private var isVideoAutoAdvanceEnabled = VideoAutoAdvancePreferenceStore().isEnabled()",
            "private let videoAutoAdvancePreferenceStore = VideoAutoAdvancePreferenceStore()",
            "Menu(\"设置\", systemImage: \"gearshape\")",
            "Toggle(\"视频自动连播\", isOn: videoAutoAdvanceBinding)",
            ".accessibilityIdentifier(\"video-auto-advance-toggle\")",
            "private var videoAutoAdvanceBinding: Binding<Bool>",
            "videoAutoAdvancePreferenceStore.save(isEnabled: isEnabled)",
        ]

        for fragment in contractFragments {
            XCTAssertTrue(source.contains(fragment), "HomeView.swift is missing: \(fragment)")
        }
    }

    func testVideoSwipeDeleteTriggerDefersDestructionToConfirmation() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let homeViewURL = repositoryRoot.appendingPathComponent("DrivePlayer/Views/HomeView.swift")
        let source = try String(contentsOf: homeViewURL, encoding: .utf8)

        let swipeBlock = try XCTUnwrap(
            source.range(
                of: #"\.swipeActions\s*\{(?<swipe>[\s\S]*?)\n\s*\}\n\s*\}\n\s*\.refreshable"#,
                options: .regularExpression
            ).map { String(source[$0]) }
        )
        XCTAssertTrue(
            swipeBlock.contains(#"Button("删除", systemImage: "trash")"#),
            "The video swipe trigger must be a regular Button"
        )
        XCTAssertFalse(
            swipeBlock.contains("role: .destructive"),
            "The video swipe trigger must not opt into destructive row-collapse semantics"
        )
        XCTAssertTrue(
            swipeBlock.contains("pendingDeletion = video"),
            "The video swipe trigger must continue to defer deletion"
        )
        XCTAssertTrue(
            swipeBlock.contains(".tint(.red)"),
            "The regular video swipe trigger must remain visually red"
        )

        let confirmationBlock = try XCTUnwrap(
            source.range(
                of: #"\.confirmationDialog\([\s\S]*?\n\s*\} message:"#,
                options: .regularExpression
            ).map { String(source[$0]) }
        )
        XCTAssertTrue(confirmationBlock.contains(#"Button("永久删除", role: .destructive)"#))
        XCTAssertTrue(confirmationBlock.contains("guard let video = pendingDeletion else { return }"))
        XCTAssertTrue(confirmationBlock.contains("pendingDeletion = nil"))
        XCTAssertTrue(confirmationBlock.contains("Task { await delete(video) }"))
    }

    func testLoudnessLibraryProgressPresentationShowsProgressAndHidesSuccessfulCompletion() {
        let normalizingPresentation = MusicLoudnessLibraryProgressPresentation(
            isNormalizing: true,
            completedCount: 3,
            totalCount: 10
        )
        let completedPresentation = MusicLoudnessLibraryProgressPresentation(
            isNormalizing: false,
            completedCount: 10,
            totalCount: 10
        )
        let idlePresentation = MusicLoudnessLibraryProgressPresentation(
            isNormalizing: false,
            completedCount: 0,
            totalCount: 0
        )
        let negativeCompletedPresentation = MusicLoudnessLibraryProgressPresentation(
            isNormalizing: true,
            completedCount: -1,
            totalCount: 10
        )
        let excessiveCompletedPresentation = MusicLoudnessLibraryProgressPresentation(
            isNormalizing: true,
            completedCount: 11,
            totalCount: 10
        )
        let negativeTotalPresentation = MusicLoudnessLibraryProgressPresentation(
            isNormalizing: true,
            completedCount: 3,
            totalCount: -1
        )

        XCTAssertTrue(normalizingPresentation.showsStatus)
        XCTAssertTrue(normalizingPresentation.showsProgressIndicator)
        XCTAssertEqual(normalizingPresentation.message, "正在统一音量 3/10")

        XCTAssertFalse(completedPresentation.showsStatus)
        XCTAssertFalse(completedPresentation.showsProgressIndicator)
        XCTAssertNil(completedPresentation.message)

        XCTAssertFalse(idlePresentation.showsStatus)
        XCTAssertFalse(idlePresentation.showsProgressIndicator)
        XCTAssertNil(idlePresentation.message)

        XCTAssertTrue(negativeCompletedPresentation.showsStatus)
        XCTAssertTrue(negativeCompletedPresentation.showsProgressIndicator)
        XCTAssertEqual(negativeCompletedPresentation.message, "正在统一音量 0/10")

        XCTAssertTrue(excessiveCompletedPresentation.showsStatus)
        XCTAssertTrue(excessiveCompletedPresentation.showsProgressIndicator)
        XCTAssertEqual(excessiveCompletedPresentation.message, "正在统一音量 10/10")

        XCTAssertFalse(negativeTotalPresentation.showsStatus)
        XCTAssertFalse(negativeTotalPresentation.showsProgressIndicator)
        XCTAssertNil(negativeTotalPresentation.message)
    }

    func testLiveLoudnessConfigurationUsesVersionedCachesDirectoryAndConservativeDefaults() throws {
        let cachesDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Caches", isDirectory: true)

        let configuration = try XCTUnwrap(
            MusicLoudnessLiveConfiguration.make(cachesDirectoryURL: cachesDirectoryURL)
        )

        XCTAssertEqual(
            configuration.cacheRootURL.standardizedFileURL,
            cachesDirectoryURL
                .appendingPathComponent("DrivePlayer/LoudnessBalance/v1", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertEqual(
            configuration.cacheBoundaryURL.standardizedFileURL,
            cachesDirectoryURL.standardizedFileURL
        )
        XCTAssertEqual(configuration.settings.targetIntegratedLevelDBFS, -16)
        XCTAssertEqual(configuration.settings.truePeakCeilingDBTP, -1.5)
        XCTAssertEqual(configuration.settings.maximumBoostDB, 12)
        XCTAssertEqual(configuration.settings.algorithmVersion, 1)
        XCTAssertNil(
            MusicLoudnessLiveConfiguration.make(
                cachesDirectoryURL: try XCTUnwrap(URL(string: "relative-caches"))
            )
        )
        XCTAssertNil(
            MusicLoudnessLiveConfiguration.make(
                cachesDirectoryURL: try XCTUnwrap(URL(string: "https://example.com/caches"))
            )
        )
    }

    func testPresentationExposesCompletePlainLyrics() {
        let lyrics = "First line\nSecond line\nThird line"
        let metadata = MusicMetadata(
            title: "Title",
            artist: nil,
            album: nil,
            artworkData: nil,
            lyrics: lyrics,
            synchronizedLyricsData: nil
        )
        let track = MusicItem(
            url: URL(fileURLWithPath: "/tmp/fixture.mp3"),
            duration: nil,
            metadata: metadata
        )

        let presentation = MusicDetailPresentation(track: track)

        XCTAssertEqual(presentation.lyricsText, "First line\nSecond line\nThird line")
        XCTAssertEqual(presentation.lyricsKind, .plain)
        XCTAssertEqual(presentation.lyricsHeading, "歌词")
    }

    func testPresentationClassifiesTimestampedLRCLyricsAndPreservesCompleteText() {
        let lyrics = "[00:01.25]First line\n[01:02.345]Second line"
        let metadata = MusicMetadata(
            title: "Title",
            artist: nil,
            album: nil,
            artworkData: nil,
            lyrics: lyrics,
            synchronizedLyricsData: nil
        )
        let track = MusicItem(
            url: URL(fileURLWithPath: "/tmp/fixture.mp3"),
            duration: nil,
            metadata: metadata
        )

        let presentation = MusicDetailPresentation(track: track)

        XCTAssertEqual(presentation.lyricsText, lyrics)
        XCTAssertEqual(presentation.lyricsKind, .timestamped)
        XCTAssertEqual(presentation.lyricsHeading, "时间歌词（全文）")
    }

    func testPresentationPrefersSynchronizedLyricsAndPreservesPlainLyricsAsFallback() {
        let synchronizedLyricsData = Data([
            0x00,
            0x7A, 0x68, 0x6F,
            0x02,
            0x01,
            0x00,
            0x46, 0x69, 0x72, 0x73, 0x74, 0x20, 0x6C, 0x69, 0x6E, 0x65, 0x00,
            0x00, 0x00, 0x04, 0xE2,
            0x53, 0x65, 0x63, 0x6F, 0x6E, 0x64, 0x20, 0x6C, 0x69, 0x6E, 0x65, 0x00,
            0x00, 0x00, 0xF3, 0x89,
        ])
        let metadata = MusicMetadata(
            title: "Title",
            artist: nil,
            album: nil,
            artworkData: nil,
            lyrics: "Plain fallback",
            synchronizedLyricsData: synchronizedLyricsData
        )
        let track = MusicItem(
            url: URL(fileURLWithPath: "/tmp/fixture.mp3"),
            duration: nil,
            metadata: metadata
        )

        let presentation = MusicDetailPresentation(track: track)

        XCTAssertEqual(
            presentation.synchronizedLyrics,
            SynchronizedLyrics(
                language: "zho",
                cues: [
                    SynchronizedLyricsCue(timestampMilliseconds: 1_250, text: "First line"),
                    SynchronizedLyricsCue(timestampMilliseconds: 62_345, text: "Second line"),
                ]
            )
        )
        XCTAssertEqual(presentation.lyricsHeading, "同步歌词")
        XCTAssertEqual(presentation.lyricsText, "Plain fallback")
    }

    func testPresentationSelectsActiveSynchronizedCueIndexForPlaybackTime() {
        let synchronizedLyricsData = Data([
            0x00,
            0x7A, 0x68, 0x6F,
            0x02,
            0x01,
            0x00,
            0x46, 0x69, 0x72, 0x73, 0x74, 0x00,
            0x00, 0x00, 0x04, 0xE2,
            0x53, 0x65, 0x63, 0x6F, 0x6E, 0x64, 0x00,
            0x00, 0x00, 0xF3, 0x89,
        ])
        let metadata = MusicMetadata(
            title: "Title",
            artist: nil,
            album: nil,
            artworkData: nil,
            lyrics: nil,
            synchronizedLyricsData: synchronizedLyricsData
        )
        let track = MusicItem(
            url: URL(fileURLWithPath: "/tmp/fixture.mp3"),
            duration: nil,
            metadata: metadata
        )

        let presentation = MusicDetailPresentation(track: track)

        XCTAssertNil(presentation.activeSynchronizedCueIndex(at: 1.249))
        XCTAssertEqual(presentation.activeSynchronizedCueIndex(at: 30.0), 0)
        XCTAssertEqual(presentation.activeSynchronizedCueIndex(at: 62.345), 1)
        XCTAssertEqual(presentation.activeSynchronizedCueIndex(at: 120.0), 1)
    }

    func testPresentationUsesEmbeddedMetadataAndDecodesEmbeddedArtwork() throws {
        let pngData = try XCTUnwrap(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        )
        let metadata = MusicMetadata(
            title: "Embedded Title",
            artist: "Embedded Artist",
            album: "Embedded Album",
            artworkData: pngData,
            lyrics: nil,
            synchronizedLyricsData: nil
        )
        let track = MusicItem(
            url: URL(fileURLWithPath: "/tmp/fixture.mp3"),
            duration: nil,
            metadata: metadata
        )

        let presentation = MusicDetailPresentation(track: track)

        XCTAssertEqual(presentation.title, "Embedded Title")
        XCTAssertEqual(presentation.artist, "Embedded Artist")
        XCTAssertEqual(presentation.album, "Embedded Album")
        XCTAssertNotNil(presentation.artworkImage)
    }

    func testPresentationFallsBackToFileNameAndRequestsPlaceholderWithoutEmbeddedMetadata() {
        let track = MusicItem(
            url: URL(fileURLWithPath: "/tmp/Fallback Song.mp3"),
            duration: nil,
            metadata: nil
        )

        let presentation = MusicDetailPresentation(track: track)

        XCTAssertEqual(presentation.title, "Fallback Song.mp3")
        XCTAssertNil(presentation.artist)
        XCTAssertNil(presentation.album)
        XCTAssertNil(presentation.artworkImage)
        XCTAssertTrue(presentation.showsPlaceholderArtwork)
    }

    func testPresentationRejectsValidArtworkExceedingMaximumPixelDimension() throws {
        let pngData = try XCTUnwrap(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAIAEAAAABAQAAAACx8nbzAAAAEUlEQVR42mNgGAWjYBSMXAAABAIAAWlqySsAAAAASUVORK5CYII=")
        )
        let metadata = MusicMetadata(
            title: "Normal Title",
            artist: nil,
            album: nil,
            artworkData: pngData,
            lyrics: nil,
            synchronizedLyricsData: nil
        )
        let track = MusicItem(
            url: URL(fileURLWithPath: "/tmp/fixture.mp3"),
            duration: nil,
            metadata: metadata
        )

        let presentation = MusicDetailPresentation(track: track)

        XCTAssertNil(presentation.artworkImage)
        XCTAssertTrue(presentation.showsPlaceholderArtwork)
    }

    func testPresentationRejectsValidArtworkExceedingMaximumPixelCount() throws {
        let pngData = try XCTUnwrap(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAEAAAABABAQAAAAARhMofAAAIC0lEQVR42u3BMQEAAADCoPVPbQo/oAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA4GgT4QAB+/qKxgAAAABJRU5ErkJggg==")
        )
        let metadata = MusicMetadata(
            title: "Normal Title",
            artist: nil,
            album: nil,
            artworkData: pngData,
            lyrics: nil,
            synchronizedLyricsData: nil
        )
        let track = MusicItem(
            url: URL(fileURLWithPath: "/tmp/fixture.mp3"),
            duration: nil,
            metadata: metadata
        )

        let presentation = MusicDetailPresentation(track: track)

        XCTAssertNil(presentation.artworkImage)
        XCTAssertTrue(presentation.showsPlaceholderArtwork)
    }

    func testPresentationRejectsMultiFrameArtwork() throws {
        let artworkData = try XCTUnwrap(
            Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP8AACH5BAAKAAAALAAAAAABAAEAAAICRAEAIfkEAAoAAAAsAAAAAAEAAQAAAgJMAQA7")
        )
        let metadata = MusicMetadata(
            title: "Normal Title",
            artist: nil,
            album: nil,
            artworkData: artworkData,
            lyrics: nil,
            synchronizedLyricsData: nil
        )
        let track = MusicItem(
            url: URL(fileURLWithPath: "/tmp/fixture.mp3"),
            duration: nil,
            metadata: metadata
        )

        let presentation = MusicDetailPresentation(track: track)

        XCTAssertNil(presentation.artworkImage)
        XCTAssertTrue(presentation.showsPlaceholderArtwork)
    }

    func testSynchronizedLyricsDecoderDecodesOrderedMillisecondCues() throws {
        let payload = Data([
            0x00,
            0x7A, 0x68, 0x6F,
            0x02,
            0x01,
            0x00,
            0x46, 0x69, 0x72, 0x73, 0x74, 0x20, 0x6C, 0x69, 0x6E, 0x65, 0x00,
            0x00, 0x00, 0x04, 0xE2,
            0x53, 0x65, 0x63, 0x6F, 0x6E, 0x64, 0x20, 0x6C, 0x69, 0x6E, 0x65, 0x00,
            0x00, 0x00, 0xF3, 0x89,
        ])

        let lyrics: SynchronizedLyrics = try ID3SynchronizedLyricsDecoder.decode(payload)

        XCTAssertEqual(lyrics.language, "zho")
        XCTAssertEqual(lyrics.cues.count, 2)
        XCTAssertEqual(lyrics.cues[0].text, "First line")
        XCTAssertEqual(lyrics.cues[0].timestampMilliseconds, 1_250)
        XCTAssertEqual(lyrics.cues[1].text, "Second line")
        XCTAssertEqual(lyrics.cues[1].timestampMilliseconds, 62_345)
    }

    func testSynchronizedLyricsSelectsLatestCueAtPlaybackTime() {
        let lyrics = SynchronizedLyrics(
            language: "zho",
            cues: [
                SynchronizedLyricsCue(timestampMilliseconds: 1_250, text: "First line"),
                SynchronizedLyricsCue(timestampMilliseconds: 62_345, text: "Second line"),
            ]
        )

        XCTAssertNil(lyrics.cueIndex(at: -0.001))
        XCTAssertNil(lyrics.cueIndex(at: .nan))
        XCTAssertNil(lyrics.cueIndex(at: 1.249))
        XCTAssertEqual(lyrics.cueIndex(at: 1.250), 0)
        XCTAssertEqual(lyrics.cueIndex(at: 30.0), 0)
        XCTAssertEqual(lyrics.cueIndex(at: 62.345), 1)
        XCTAssertEqual(lyrics.cueIndex(at: 120.0), 1)
    }

    func testSynchronizedLyricsDecoderDecodesUTF16LEChineseCuesWithBOMs() throws {
        let payload = Data([
            0x01,
            0x7A, 0x68, 0x6F,
            0x02,
            0x01,
            0xFF, 0xFE, 0x00, 0x00,
            0xFF, 0xFE, 0x2C, 0x7B, 0x00, 0x4E, 0xE5, 0x53, 0x00, 0x00,
            0x00, 0x00, 0x04, 0xE2,
            0xFF, 0xFE, 0x2C, 0x7B, 0x8C, 0x4E, 0xE5, 0x53, 0x00, 0x00,
            0x00, 0x00, 0xF3, 0x89,
        ])

        let lyrics: SynchronizedLyrics = try ID3SynchronizedLyricsDecoder.decode(payload)

        XCTAssertEqual(lyrics.language, "zho")
        XCTAssertEqual(lyrics.cues.map(\.text), ["第一句", "第二句"])
        XCTAssertEqual(lyrics.cues.map(\.timestampMilliseconds), [1_250, 62_345])
    }

    private func syntheticUTF16LESYLTWithTrailingEmptyCue() -> Data {
        // Synthetic ID3v2.3 SYLT payload based on the existing UTF-16LE fixture.
        // Each string has its own BOM; no user media or copyrighted lyrics are read.
        Data([
            0x01, 0x7A, 0x68, 0x6F, 0x02, 0x01,
            0xFF, 0xFE, 0x00, 0x00,
            0xFF, 0xFE, 0x2C, 0x7B, 0x00, 0x4E, 0xE5, 0x53, 0x00, 0x00,
            0x00, 0x00, 0x58, 0xDE, // 22,750 ms
            0xFF, 0xFE, 0x2C, 0x7B, 0x8C, 0x4E, 0xE5, 0x53, 0x00, 0x00,
            0x00, 0x00, 0xF3, 0x89, // 62,345 ms
            0xFF, 0xFE, 0x00, 0x00,
            0x00, 0x04, 0xD1, 0x48, // Empty cue at 315,720 ms, with complete timestamp.
        ])
    }

    func testSynchronizedLyricsDecoderPreservesUTF16LETrailingEmptyCueAndBackwardSeek() throws {
        let lyrics = try ID3SynchronizedLyricsDecoder.decode(syntheticUTF16LESYLTWithTrailingEmptyCue())

        XCTAssertEqual(lyrics.language, "zho")
        XCTAssertEqual(lyrics.cues.map(\.text), ["第一句", "第二句", ""])
        XCTAssertEqual(lyrics.cues.map(\.timestampMilliseconds), [22_750, 62_345, 315_720])
        XCTAssertNil(lyrics.cueIndex(at: 22.749))
        XCTAssertEqual(lyrics.cueIndex(at: 22.750), 0)
        XCTAssertEqual(lyrics.cueIndex(at: 315.719), 1)
        XCTAssertEqual(lyrics.cueIndex(at: 315.720), 2)
        XCTAssertEqual(lyrics.cueIndex(at: 320), 2)
        // Query earlier times after reaching the empty cue to model a backward seek.
        XCTAssertEqual(lyrics.cueIndex(at: 62.345), 1)
        XCTAssertEqual(lyrics.cueIndex(at: 22.750), 0)
        XCTAssertNil(lyrics.cueIndex(at: 22.749))
    }

    func testPresentationPrefersSYLTWithTrailingEmptyCueOverUSLTThroughMetadataParser() {
        let payload = syntheticUTF16LESYLTWithTrailingEmptyCue()
        let metadata = MusicMetadataParser.parse([
            RawMusicMetadataItem(identifier: "id3/USLT", stringValue: "Synthetic plain fallback", dataValue: nil),
            RawMusicMetadataItem(identifier: "id3/SYLT", stringValue: nil, dataValue: payload),
        ], fallbackFileName: "synthetic-empty-cue.mp3")
        let track = MusicItem(
            url: URL(fileURLWithPath: "/tmp/synthetic-empty-cue.mp3"),
            duration: nil,
            metadata: metadata
        )

        let presentation = MusicDetailPresentation(track: track)

        XCTAssertEqual(metadata.synchronizedLyricsData, payload)
        XCTAssertEqual(presentation.lyricsText, "Synthetic plain fallback")
        XCTAssertEqual(presentation.synchronizedLyrics, SynchronizedLyrics(language: "zho", cues: [
            SynchronizedLyricsCue(timestampMilliseconds: 22_750, text: "第一句"),
            SynchronizedLyricsCue(timestampMilliseconds: 62_345, text: "第二句"),
            SynchronizedLyricsCue(timestampMilliseconds: 315_720, text: ""),
        ]))
        XCTAssertEqual(presentation.lyricsKind, .timestamped)
        XCTAssertEqual(presentation.lyricsHeading, "同步歌词")
        XCTAssertEqual(presentation.activeSynchronizedCueIndex(at: 315.719), 1)
        XCTAssertEqual(presentation.activeSynchronizedCueIndex(at: 315.720), 2)
        XCTAssertEqual(presentation.activeSynchronizedCueIndex(at: 320), 2)
        XCTAssertEqual(presentation.activeSynchronizedCueIndex(at: 22.750), 0)
        XCTAssertNil(presentation.activeSynchronizedCueIndex(at: 22.749))
    }

    private func syntheticUTF16LESYLT(cues: [(UInt32, String)]) -> Data {
        var payload = Data(syntheticUTF16LESYLTWithTrailingEmptyCue().prefix(10))
        for (timestamp, text) in cues {
            payload.append(contentsOf: [0xFF, 0xFE])
            for unit in text.utf16 {
                payload.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)])
            }
            payload.append(contentsOf: [
                0x00, 0x00,
                UInt8((timestamp >> 24) & 0xFF), UInt8((timestamp >> 16) & 0xFF),
                UInt8((timestamp >> 8) & 0xFF), UInt8(timestamp & 0xFF),
            ])
        }
        return payload
    }

    func testBlankOnlySYLTFallsBackToUSLTThroughMetadataParser() {
        // All-empty rejection was already supported; this protects that boundary.
        for texts in [["", ""], [" \t\r\n", "\u{3000}"], ["", " \t"]] {
            let payload = syntheticUTF16LESYLT(cues: [(0, texts[0]), (1_000, texts[1])])
            XCTAssertThrowsError(try ID3SynchronizedLyricsDecoder.decode(payload))
            let metadata = MusicMetadataParser.parse([
                RawMusicMetadataItem(identifier: "id3/USLT", stringValue: "Synthetic plain fallback", dataValue: nil),
                RawMusicMetadataItem(identifier: "id3/SYLT", stringValue: nil, dataValue: payload),
            ], fallbackFileName: "synthetic-empty-cue.mp3")
            let presentation = MusicDetailPresentation(track: MusicItem(
                url: URL(fileURLWithPath: "/tmp/synthetic-empty-cue.mp3"),
                duration: nil,
                metadata: metadata
            ))

            XCTAssertNil(metadata.synchronizedLyrics)
            XCTAssertNil(presentation.synchronizedLyrics)
            XCTAssertEqual(presentation.lyricsText, "Synthetic plain fallback")
            XCTAssertEqual(presentation.lyricsKind, .plain)
        }
    }

    func testSynchronizedLyricsDecoderPreservesZeroEmptyCueAndEqualTimestampLastWins() throws {
        let lyrics = try ID3SynchronizedLyricsDecoder.decode(syntheticUTF16LESYLT(cues: [
            (0, ""), (1_000, " \tFirst\n"), (1_000, ""),
            (2_000, ""), (2_000, "Second"), (3_000, " \t\n"),
        ]))

        XCTAssertEqual(lyrics.cues.map(\.text), ["", " \tFirst\n", "", "", "Second", " \t\n"])
        XCTAssertEqual(lyrics.cues.map(\.timestampMilliseconds), [0, 1_000, 1_000, 2_000, 2_000, 3_000])
        XCTAssertEqual(lyrics.cueIndex(at: 0), 0)
        XCTAssertEqual(lyrics.cueIndex(at: 0.999), 0)
        XCTAssertEqual(lyrics.cueIndex(at: 1), 2)
        XCTAssertEqual(lyrics.cueIndex(at: 2), 4)
        XCTAssertEqual(lyrics.cueIndex(at: 3), 5)
    }

    func testSynchronizedLyricsDecoderCountsEmptyCuesTowardMaximum() throws {
        var cues: [(UInt32, String)] = [(0, "Visible")]
        cues.append(contentsOf: (1..<4_096).map { (UInt32($0), "") })
        let lyrics = try ID3SynchronizedLyricsDecoder.decode(syntheticUTF16LESYLT(cues: cues))
        XCTAssertEqual(lyrics.cues.count, 4_096)
        XCTAssertEqual(lyrics.cues.last, SynchronizedLyricsCue(timestampMilliseconds: 4_095, text: ""))

        cues.append((4_096, ""))
        XCTAssertThrowsError(try ID3SynchronizedLyricsDecoder.decode(syntheticUTF16LESYLT(cues: cues)))
    }

    func testSynchronizedLyricsDecoderRejectsMalformedTrailingEmptyCue() {
        let payload = syntheticUTF16LESYLTWithTrailingEmptyCue()
        // Leave a partial timestamp, terminator, or BOM after valid visible cues.
        for removedBytes in 1...7 {
            XCTAssertThrowsError(try ID3SynchronizedLyricsDecoder.decode(Data(payload.dropLast(removedBytes))),
                                 "Truncated by \(removedBytes) bytes")
        }
        var missingBOM = Data(payload.dropLast(8))
        missingBOM.append(contentsOf: payload.suffix(6))
        XCTAssertThrowsError(try ID3SynchronizedLyricsDecoder.decode(missingBOM))

        var trailingGarbage = payload
        trailingGarbage.append(0xFF)
        XCTAssertThrowsError(try ID3SynchronizedLyricsDecoder.decode(trailingGarbage))
    }

    func testSynchronizedLyricsDecoderValidatesMonotonicityAcrossEmptyCues() {
        let cases: [[(UInt32, String)]] = [
            [(1_000, "Visible"), (999, "")],
            [(0, "Visible"), (1_000, ""), (999, "After")],
        ]
        for cues in cases {
            XCTAssertThrowsError(try ID3SynchronizedLyricsDecoder.decode(syntheticUTF16LESYLT(cues: cues)))
        }
    }

    func testSynchronizedLyricsDecoderRejectsMoreThanMaximumCueCount() {
        let cueCount = 4_097
        var payload = Data([0x00, 0x7A, 0x68, 0x6F, 0x02, 0x01, 0x00])
        payload.reserveCapacity(payload.count + cueCount * 6)

        for timestamp in UInt32(0)..<UInt32(cueCount) {
            payload.append(contentsOf: [
                0x78, 0x00,
                UInt8((timestamp >> 24) & 0xFF),
                UInt8((timestamp >> 16) & 0xFF),
                UInt8((timestamp >> 8) & 0xFF),
                UInt8(timestamp & 0xFF),
            ])
        }

        XCTAssertThrowsError(try ID3SynchronizedLyricsDecoder.decode(payload))
    }

    func testSynchronizedLyricsDecoderRejectsCueTextExceedingMaximumDecodedUTF8Size() {
        let cueTextByteCount = (1 * 1024 * 1024) + 1
        var payload = Data([0x00, 0x7A, 0x68, 0x6F, 0x02, 0x01, 0x00])
        payload.reserveCapacity(payload.count + cueTextByteCount + 5)
        payload.append(contentsOf: repeatElement(UInt8(0x78), count: cueTextByteCount))
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x04, 0xE2])

        XCTAssertThrowsError(try ID3SynchronizedLyricsDecoder.decode(payload))
    }

    func testMusicListArtworkPresentationUsesSafeEmbeddedArtworkAndFallsBackForMissingOrInvalidData() throws {
        let pngData = try XCTUnwrap(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        )
        let validArtworkTrack = MusicItem(
            url: URL(fileURLWithPath: "/tmp/valid-artwork.mp3"),
            duration: nil,
            metadata: MusicMetadata(
                title: "Valid Artwork",
                artist: nil,
                album: nil,
                artworkData: pngData,
                lyrics: nil,
                synchronizedLyricsData: nil
            )
        )
        let missingArtworkTrack = MusicItem(
            url: URL(fileURLWithPath: "/tmp/missing-artwork.mp3"),
            duration: nil,
            metadata: nil
        )
        let malformedArtworkTrack = MusicItem(
            url: URL(fileURLWithPath: "/tmp/malformed-artwork.mp3"),
            duration: nil,
            metadata: MusicMetadata(
                title: "Malformed Artwork",
                artist: nil,
                album: nil,
                artworkData: Data([0x00, 0x01, 0x02]),
                lyrics: nil,
                synchronizedLyricsData: nil
            )
        )

        let validPresentation = MusicListArtworkPresentation(track: validArtworkTrack)
        let missingPresentation = MusicListArtworkPresentation(track: missingArtworkTrack)
        let malformedPresentation = MusicListArtworkPresentation(track: malformedArtworkTrack)

        XCTAssertNotNil(validPresentation.artworkImage)
        XCTAssertFalse(validPresentation.showsPlaceholderArtwork)
        XCTAssertNil(missingPresentation.artworkImage)
        XCTAssertTrue(missingPresentation.showsPlaceholderArtwork)
        XCTAssertNil(malformedPresentation.artworkImage)
        XCTAssertTrue(malformedPresentation.showsPlaceholderArtwork)
    }

    func testMusicLoudnessNormalizationSettingsAcceptSafeFiniteValuesAndRejectUnsafeValues() throws {
        func makeSettings(
            targetIntegratedLevelDBFS: Double = -16,
            truePeakCeilingDBTP: Double = -1.5,
            maximumBoostDB: Double = 12,
            algorithmVersion: Int = 1
        ) -> MusicLoudnessNormalizationSettings? {
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: targetIntegratedLevelDBFS,
                truePeakCeilingDBTP: truePeakCeilingDBTP,
                maximumBoostDB: maximumBoostDB,
                algorithmVersion: algorithmVersion
            )
        }

        let settings = try XCTUnwrap(makeSettings())

        XCTAssertEqual(settings.targetIntegratedLevelDBFS, -16)
        XCTAssertEqual(settings.truePeakCeilingDBTP, -1.5)
        XCTAssertEqual(settings.maximumBoostDB, 12)
        XCTAssertEqual(settings.algorithmVersion, 1)

        for unsafeValue in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertNil(makeSettings(targetIntegratedLevelDBFS: unsafeValue))
            XCTAssertNil(makeSettings(truePeakCeilingDBTP: unsafeValue))
            XCTAssertNil(makeSettings(maximumBoostDB: unsafeValue))
        }

        XCTAssertNil(makeSettings(targetIntegratedLevelDBFS: -24.1))
        XCTAssertNil(makeSettings(targetIntegratedLevelDBFS: -9.9))
        XCTAssertNil(makeSettings(truePeakCeilingDBTP: -6.1))
        XCTAssertNil(makeSettings(truePeakCeilingDBTP: 0.1))
        XCTAssertNil(makeSettings(maximumBoostDB: -0.1))
        XCTAssertNil(makeSettings(maximumBoostDB: 18.1))
        XCTAssertNil(makeSettings(algorithmVersion: 0))
    }

    func testLoudnessGainPolicyUsesTargetBoostCapAndPeakHeadroomWithoutFlattening() throws {
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )

        func appliedGainDB(level: Double, peak: Double) -> Double? {
            MusicLoudnessGainPolicy.appliedGainDB(
                measuredIntegratedLevelDBFS: level,
                measuredPeakDBTP: peak,
                settings: settings
            )
        }

        XCTAssertEqual(try XCTUnwrap(appliedGainDB(level: -33, peak: -30)), 12, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(appliedGainDB(level: -6, peak: -3)), -10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(appliedGainDB(level: -30, peak: -0.5)), -1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(appliedGainDB(level: -16, peak: -4)), 0, accuracy: 1e-9)

        for unsafeValue in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertNil(appliedGainDB(level: unsafeValue, peak: -4))
            XCTAssertNil(appliedGainDB(level: -16, peak: unsafeValue))
        }

        XCTAssertNil(appliedGainDB(level: -16, peak: 0.1))
        XCTAssertNil(appliedGainDB(level: -201, peak: -4))
        XCTAssertNil(appliedGainDB(level: 21, peak: -4))
    }

    func testMusicLoudnessCacheKeyUsesSourceContentHashAndAllNormalizationParameters() throws {
        let baseSettings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let changedTargetSettings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -15,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let changedPeakSettings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -2,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let changedBoostSettings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 10,
                algorithmVersion: 1
            )
        )
        let changedVersionSettings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 2
            )
        )
        let sourceA = String(repeating: "a", count: 64)
        let sourceB = String(repeating: "b", count: 64)

        let baseKey = try XCTUnwrap(
            MusicLoudnessCacheKey.make(sourceSHA256Hex: sourceA, settings: baseSettings)
        )

        XCTAssertFalse(baseKey.isEmpty)
        XCTAssertEqual(
            MusicLoudnessCacheKey.make(sourceSHA256Hex: sourceA, settings: baseSettings),
            baseKey
        )
        XCTAssertNotEqual(
            MusicLoudnessCacheKey.make(sourceSHA256Hex: sourceB, settings: baseSettings),
            baseKey
        )
        XCTAssertNotEqual(
            MusicLoudnessCacheKey.make(sourceSHA256Hex: sourceA, settings: changedTargetSettings),
            baseKey
        )
        XCTAssertNotEqual(
            MusicLoudnessCacheKey.make(sourceSHA256Hex: sourceA, settings: changedPeakSettings),
            baseKey
        )
        XCTAssertNotEqual(
            MusicLoudnessCacheKey.make(sourceSHA256Hex: sourceA, settings: changedBoostSettings),
            baseKey
        )
        XCTAssertNotEqual(
            MusicLoudnessCacheKey.make(sourceSHA256Hex: sourceA, settings: changedVersionSettings),
            baseKey
        )
        XCTAssertNil(
            MusicLoudnessCacheKey.make(
                sourceSHA256Hex: String(repeating: "a", count: 63),
                settings: baseSettings
            )
        )
        XCTAssertNil(
            MusicLoudnessCacheKey.make(
                sourceSHA256Hex: String(repeating: "A", count: 64),
                settings: baseSettings
            )
        )
        XCTAssertNil(
            MusicLoudnessCacheKey.make(
                sourceSHA256Hex: String(repeating: "g", count: 64),
                settings: baseSettings
            )
        )
    }

    func testMusicLoudnessCacheManifestIsUsableOnlyWhenCompleteMatchingFiniteAndPresent() {
        let cacheKey = String(repeating: "c", count: 64)
        let sourceSHA256Hex = String(repeating: "a", count: 64)

        func makeManifest(
            derivativeFileName: String = "normalized.m4a",
            state: MusicLoudnessCacheManifest.State = .complete,
            measuredIntegratedLevelDBFS: Double? = -20,
            measuredTruePeakDBTP: Double? = -2,
            outputIntegratedLevelDBFS: Double? = -16,
            outputTruePeakDBTP: Double? = -1.5
        ) -> MusicLoudnessCacheManifest {
            MusicLoudnessCacheManifest(
                cacheKey: cacheKey,
                sourceSHA256Hex: sourceSHA256Hex,
                derivativeFileName: derivativeFileName,
                state: state,
                measuredIntegratedLevelDBFS: measuredIntegratedLevelDBFS,
                measuredTruePeakDBTP: measuredTruePeakDBTP,
                outputIntegratedLevelDBFS: outputIntegratedLevelDBFS,
                outputTruePeakDBTP: outputTruePeakDBTP
            )
        }

        XCTAssertTrue(makeManifest().isUsable(expectedCacheKey: cacheKey, derivativeExists: true))
        XCTAssertFalse(
            makeManifest().isUsable(
                expectedCacheKey: String(repeating: "d", count: 64),
                derivativeExists: true
            )
        )
        XCTAssertFalse(makeManifest().isUsable(expectedCacheKey: cacheKey, derivativeExists: false))
        XCTAssertFalse(
            makeManifest(state: .processing)
                .isUsable(expectedCacheKey: cacheKey, derivativeExists: true)
        )
        XCTAssertFalse(
            makeManifest(state: .failed)
                .isUsable(expectedCacheKey: cacheKey, derivativeExists: true)
        )

        let incompleteManifests = [
            makeManifest(measuredIntegratedLevelDBFS: nil),
            makeManifest(measuredTruePeakDBTP: nil),
            makeManifest(outputIntegratedLevelDBFS: nil),
            makeManifest(outputTruePeakDBTP: nil),
        ]
        for manifest in incompleteManifests {
            XCTAssertFalse(manifest.isUsable(expectedCacheKey: cacheKey, derivativeExists: true))
        }

        let nonFiniteManifests = [
            makeManifest(measuredIntegratedLevelDBFS: Double.nan),
            makeManifest(measuredTruePeakDBTP: Double.infinity),
            makeManifest(outputIntegratedLevelDBFS: -Double.infinity),
        ]
        for manifest in nonFiniteManifests {
            XCTAssertFalse(manifest.isUsable(expectedCacheKey: cacheKey, derivativeExists: true))
        }

        for unsafeDerivativeFileName in ["../normalized.m4a", "/tmp/normalized.m4a", ""] {
            XCTAssertFalse(
                makeManifest(derivativeFileName: unsafeDerivativeFileName)
                    .isUsable(expectedCacheKey: cacheKey, derivativeExists: true)
            )
        }
    }

    func testLoudnessCacheCoordinatorGeneratesOnceThenReusesCompleteCache() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        let cacheRootURL = temporaryDirectory.appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings
        )

        let firstResolution: MusicLoudnessResolution = await coordinator.resolve(sourceURL: sourceURL)

        guard case .generated = firstResolution.status else {
            XCTFail("Expected the first resolution to generate a cached derivative")
            return
        }
        let firstPlaybackURL = firstResolution.playbackURL.standardizedFileURL
        XCTAssertNotEqual(firstPlaybackURL, sourceURL.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPlaybackURL.path))
        XCTAssertEqual(firstPlaybackURL.pathExtension.lowercased(), "m4a")
        XCTAssertGreaterThan(try measureAudioFile(at: firstPlaybackURL).frameCount, 0)
        assertNoTemporaryFiles(in: cacheRootURL)

        let secondResolution: MusicLoudnessResolution = await coordinator.resolve(sourceURL: sourceURL)

        guard case .reused = secondResolution.status else {
            XCTFail("Expected the second resolution to reuse the complete cached derivative")
            return
        }
        let secondPlaybackURL = secondResolution.playbackURL.standardizedFileURL
        XCTAssertEqual(secondPlaybackURL, firstPlaybackURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondPlaybackURL.path))
        XCTAssertGreaterThan(try measureAudioFile(at: secondPlaybackURL).frameCount, 0)
        assertNoTemporaryFiles(in: cacheRootURL)
    }

    func testLoudnessCacheRejectsSymlinkManifestBeforeReading() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        let cacheRootURL = temporaryDirectory.appendingPathComponent(
            "loudness-cache",
            isDirectory: true
        )
        let externalManifestURL = temporaryDirectory.appendingPathComponent(
            "external-manifest.json",
            isDirectory: false
        )
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        var processorInvocationCount = 0
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, processingSettings in
                processorInvocationCount += 1
                return try MusicLoudnessOfflineProcessor.process(
                    sourceURL: processingSourceURL,
                    destinationURL: destinationURL,
                    settings: processingSettings
                )
            }
        )

        let firstResolution: MusicLoudnessResolution = await coordinator.resolve(
            sourceURL: sourceURL
        )

        guard case .generated = firstResolution.status else {
            XCTFail("Expected the controlled fixture to generate its initial derivative")
            return
        }
        XCTAssertEqual(processorInvocationCount, 1)
        let derivativeURL = firstResolution.playbackURL.standardizedFileURL
        let generationDirectoryURL = derivativeURL.deletingLastPathComponent()
        let manifestURL = generationDirectoryURL.appendingPathComponent(
            "manifest.json",
            isDirectory: false
        )
        let validManifestBytes = try Data(contentsOf: manifestURL)
        XCTAssertFalse(validManifestBytes.isEmpty)
        XCTAssertTrue(derivativeURL.path.hasPrefix(cacheRootURL.standardizedFileURL.path + "/"))
        XCTAssertEqual(manifestURL.deletingLastPathComponent(), generationDirectoryURL)

        try validManifestBytes.write(to: externalManifestURL, options: .atomic)
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createSymbolicLink(
            at: manifestURL,
            withDestinationURL: externalManifestURL
        )

        var symlinkStatus = stat()
        XCTAssertEqual(lstat(manifestURL.path, &symlinkStatus), 0)
        XCTAssertEqual(symlinkStatus.st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: manifestURL.path),
            externalManifestURL.path
        )
        XCTAssertEqual(try Data(contentsOf: externalManifestURL), validManifestBytes)

        let secondResolution: MusicLoudnessResolution = await coordinator.resolve(
            sourceURL: sourceURL
        )

        if case .reused = secondResolution.status {
            XCTFail("Must never reuse a cache whose manifest path is a symlink")
        }
        guard case .generated = secondResolution.status else {
            XCTFail("Expected the symlinked manifest to force regeneration")
            return
        }
        XCTAssertEqual(processorInvocationCount, 2)
        let regeneratedDerivativeURL = secondResolution.playbackURL.standardizedFileURL
        XCTAssertEqual(regeneratedDerivativeURL, derivativeURL)
        XCTAssertEqual(regeneratedDerivativeURL.deletingLastPathComponent(), generationDirectoryURL)

        var regeneratedManifestStatus = stat()
        XCTAssertEqual(lstat(manifestURL.path, &regeneratedManifestStatus), 0)
        XCTAssertEqual(
            regeneratedManifestStatus.st_mode & mode_t(S_IFMT),
            mode_t(S_IFREG)
        )
        XCTAssertEqual(regeneratedManifestStatus.st_nlink, 1)
        XCTAssertEqual(manifestURL.deletingLastPathComponent(), generationDirectoryURL)

        var regeneratedDerivativeStatus = stat()
        XCTAssertEqual(lstat(regeneratedDerivativeURL.path, &regeneratedDerivativeStatus), 0)
        XCTAssertEqual(
            regeneratedDerivativeStatus.st_mode & mode_t(S_IFMT),
            mode_t(S_IFREG)
        )
        XCTAssertGreaterThan(try AVAudioFile(forReading: regeneratedDerivativeURL).length, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: externalManifestURL), validManifestBytes)
    }

    func testLoudnessCacheRejectsSymlinkedAncestorBeforeCreatingCacheRoot() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        let outsideURL = temporaryDirectory.appendingPathComponent("outside", isDirectory: true)
        let linkedParentURL = temporaryDirectory
            .appendingPathComponent("linked-parent", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        try FileManager.default.createDirectory(
            at: outsideURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: linkedParentURL,
            withDestinationURL: outsideURL
        )

        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let cacheRootURL = linkedParentURL
            .appendingPathComponent("LoudnessBalance", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings
        )

        let resolution: MusicLoudnessResolution = await coordinator.resolve(sourceURL: sourceURL)

        guard case .fallbackOriginal = resolution.status else {
            XCTFail("Expected a symlinked cache-root ancestor to fall back to the original source")
            return
        }
        XCTAssertEqual(
            resolution.playbackURL.standardizedFileURL,
            sourceURL.standardizedFileURL
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outsideURL.appendingPathComponent("LoudnessBalance").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outsideURL
                    .appendingPathComponent("LoudnessBalance")
                    .appendingPathComponent("v1")
                    .path
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: outsideURL,
                includingPropertiesForKeys: nil
            ),
            []
        )
        let outsideEnumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: outsideURL,
                includingPropertiesForKeys: nil
            )
        )
        XCTAssertTrue(outsideEnumerator.allObjects.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testLoudnessCacheTrustedBoundaryRejectsHigherSymlinkWhenLowerDirectoryAlreadyExists() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        let outsideURL = temporaryDirectory.appendingPathComponent("outside", isDirectory: true)
        let outsideLoudnessBalanceURL = outsideURL
            .appendingPathComponent("LoudnessBalance", isDirectory: true)
        let linkedParentURL = temporaryDirectory
            .appendingPathComponent("linked-parent", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        try FileManager.default.createDirectory(
            at: outsideLoudnessBalanceURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedParentURL,
            withDestinationURL: outsideURL
        )

        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let cacheRootURL = linkedParentURL
            .appendingPathComponent("LoudnessBalance", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            cacheBoundaryURL: temporaryDirectory,
            settings: settings
        )

        let resolution: MusicLoudnessResolution = await coordinator.resolve(sourceURL: sourceURL)

        guard case .fallbackOriginal = resolution.status else {
            XCTFail("Expected a cache root escaping its trusted boundary to fall back to the original source")
            return
        }
        XCTAssertEqual(
            resolution.playbackURL.standardizedFileURL,
            sourceURL.standardizedFileURL
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outsideLoudnessBalanceURL
                    .appendingPathComponent("v1", isDirectory: true)
                    .path
            )
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                at: outsideLoudnessBalanceURL,
                includingPropertiesForKeys: nil
            ),
            []
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testLoudnessCacheHashesAndProcessesPrivateSourceSnapshotWhenOriginalPathChanges() async throws {
        let isStrictHash: (String) -> Bool = { value in
            let scalars = value.unicodeScalars
            return scalars.count == 64 && scalars.allSatisfy { scalar in
                (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
            }
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("source-a-quiet.wav")
        let replacementURL = temporaryDirectory.appendingPathComponent("source-b-loud.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache-\(UUID().uuidString)", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        try writeSineWave(to: replacementURL, amplitude: pow(10, -3.0 / 20.0))
        let sourceAData = try Data(contentsOf: sourceURL)
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        var processorInvocationCount = 0
        let standardizedSourceURL = sourceURL.standardizedFileURL
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, processingSettings in
                processorInvocationCount += 1
                XCTAssertNotEqual(
                    processingSourceURL.standardizedFileURL,
                    standardizedSourceURL
                )
                XCTAssertEqual(try Data(contentsOf: processingSourceURL), sourceAData)

                try FileManager.default.removeItem(at: sourceURL)
                try FileManager.default.moveItem(at: replacementURL, to: sourceURL)

                return try MusicLoudnessOfflineProcessor.process(
                    sourceURL: processingSourceURL,
                    destinationURL: destinationURL,
                    settings: processingSettings
                )
            }
        )

        let resolution: MusicLoudnessResolution = await coordinator.resolve(sourceURL: sourceURL)

        guard case .generated = resolution.status else {
            XCTFail("Expected snapshot-backed processing to generate a cached derivative")
            return
        }
        let playbackURL = resolution.playbackURL.standardizedFileURL
        let standardizedCacheRootURL = cacheRootURL.standardizedFileURL
        XCTAssertEqual(processorInvocationCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: playbackURL.path))
        XCTAssertTrue(playbackURL.path.hasPrefix(standardizedCacheRootURL.path + "/"))
        XCTAssertEqual(playbackURL.pathExtension.lowercased(), "m4a")
        XCTAssertNotEqual(try Data(contentsOf: sourceURL), sourceAData)

        let manifestURL = playbackURL.deletingLastPathComponent()
            .appendingPathComponent("manifest.json", isDirectory: false)
        let manifest = try JSONDecoder().decode(
            MusicLoudnessCacheManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertEqual(manifest.state, .complete)
        XCTAssertTrue(isStrictHash(manifest.sourceSHA256Hex))
        XCTAssertTrue(isStrictHash(manifest.cacheKey))
        XCTAssertEqual(
            MusicLoudnessCacheKey.make(
                sourceSHA256Hex: manifest.sourceSHA256Hex,
                settings: settings
            ),
            manifest.cacheKey
        )
        XCTAssertEqual(playbackURL.deletingLastPathComponent().lastPathComponent, manifest.cacheKey)
    }

    func testLoudnessCacheRejectsDirectoryAndSymlinkDerivativeArtifacts() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )

        for artifactKind in ["directory", "symlink"] {
            let cacheRootURL = temporaryDirectory
                .appendingPathComponent("\(artifactKind)-cache", isDirectory: true)
            let coordinator = MusicLoudnessCacheCoordinator(
                cacheRootURL: cacheRootURL,
                settings: settings
            )
            let firstResolution: MusicLoudnessResolution = await coordinator.resolve(
                sourceURL: sourceURL
            )

            guard case .generated = firstResolution.status else {
                XCTFail("Expected initial \(artifactKind) case resolution to generate a derivative")
                continue
            }
            let hostileDerivativeURL = firstResolution.playbackURL.standardizedFileURL
            XCTAssertTrue(
                hostileDerivativeURL.path.hasPrefix(cacheRootURL.standardizedFileURL.path + "/")
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: hostileDerivativeURL.path))

            if artifactKind == "symlink" {
                let outsideFileURL = temporaryDirectory
                    .appendingPathComponent("outside-\(artifactKind).m4a")
                try FileManager.default.copyItem(at: hostileDerivativeURL, to: outsideFileURL)
                try FileManager.default.removeItem(at: hostileDerivativeURL)
                try FileManager.default.createSymbolicLink(
                    at: hostileDerivativeURL,
                    withDestinationURL: outsideFileURL
                )
            } else {
                try FileManager.default.removeItem(at: hostileDerivativeURL)
                try FileManager.default.createDirectory(
                    at: hostileDerivativeURL,
                    withIntermediateDirectories: false
                )
            }

            let secondResolution: MusicLoudnessResolution = await coordinator.resolve(
                sourceURL: sourceURL
            )

            if case .reused = secondResolution.status {
                XCTFail("Must not reuse a \(artifactKind) at the cached derivative path")
            }
            let playbackURL = secondResolution.playbackURL.standardizedFileURL
            if playbackURL != sourceURL.standardizedFileURL {
                var fileStatus = stat()
                XCTAssertEqual(lstat(playbackURL.path, &fileStatus), 0)
                XCTAssertEqual(fileStatus.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))

                let resourceValues = try playbackURL.resourceValues(
                    forKeys: [.isReadableKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
                XCTAssertEqual(resourceValues.isReadable, true)
                XCTAssertEqual(resourceValues.isRegularFile, true)
                XCTAssertEqual(resourceValues.isSymbolicLink, false)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        }
    }

    func testLoudnessCacheRejectsCorruptedRegularDerivativeWithIntactManifest() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        let cacheRootURL = temporaryDirectory.appendingPathComponent(
            "loudness-cache",
            isDirectory: true
        )
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        var processorInvocationCount = 0
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, processingSettings in
                processorInvocationCount += 1
                return try MusicLoudnessOfflineProcessor.process(
                    sourceURL: processingSourceURL,
                    destinationURL: destinationURL,
                    settings: processingSettings
                )
            }
        )

        let firstResolution: MusicLoudnessResolution = await coordinator.resolve(
            sourceURL: sourceURL
        )

        guard case .generated = firstResolution.status else {
            XCTFail("Expected the first resolution to generate a cached derivative")
            return
        }
        XCTAssertEqual(processorInvocationCount, 1)
        let derivativeURL = firstResolution.playbackURL.standardizedFileURL
        XCTAssertEqual(derivativeURL.lastPathComponent, "normalized.m4a")
        let firstAudioFile = try AVAudioFile(forReading: derivativeURL)
        XCTAssertGreaterThan(firstAudioFile.length, 0)

        let manifestURL = derivativeURL.deletingLastPathComponent()
            .appendingPathComponent("manifest.json", isDirectory: false)
        let originalManifestBytes = try Data(contentsOf: manifestURL)
        XCTAssertFalse(originalManifestBytes.isEmpty)

        try FileManager.default.removeItem(at: derivativeURL)
        let garbageBytes = Data("corrupted regular derivative".utf8)
        try garbageBytes.write(to: derivativeURL, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: derivativeURL), garbageBytes)

        var corruptedFileStatus = stat()
        XCTAssertEqual(lstat(derivativeURL.path, &corruptedFileStatus), 0)
        XCTAssertEqual(corruptedFileStatus.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
        let corruptedResourceValues = try derivativeURL.resourceValues(
            forKeys: [.isReadableKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        XCTAssertEqual(corruptedResourceValues.isReadable, true)
        XCTAssertEqual(corruptedResourceValues.isRegularFile, true)
        XCTAssertEqual(corruptedResourceValues.isSymbolicLink, false)
        XCTAssertEqual(try Data(contentsOf: manifestURL), originalManifestBytes)

        let secondResolution: MusicLoudnessResolution = await coordinator.resolve(
            sourceURL: sourceURL
        )

        if case .reused = secondResolution.status {
            XCTFail("Must not reuse a corrupted regular cached derivative")
        }
        XCTAssertEqual(processorInvocationCount, 2)
        guard case .generated = secondResolution.status else {
            if case .fallbackOriginal = secondResolution.status {
                XCTAssertEqual(
                    secondResolution.playbackURL.standardizedFileURL,
                    sourceURL.standardizedFileURL
                )
                XCTAssertNotEqual(
                    secondResolution.playbackURL.standardizedFileURL,
                    derivativeURL
                )
            } else {
                XCTFail("Expected regeneration or fallback to the original source")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
            return
        }

        let regeneratedDerivativeURL = secondResolution.playbackURL.standardizedFileURL
        XCTAssertEqual(regeneratedDerivativeURL, derivativeURL)
        var regeneratedFileStatus = stat()
        XCTAssertEqual(lstat(regeneratedDerivativeURL.path, &regeneratedFileStatus), 0)
        XCTAssertEqual(regeneratedFileStatus.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
        let regeneratedResourceValues = try regeneratedDerivativeURL.resourceValues(
            forKeys: [.isReadableKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        XCTAssertEqual(regeneratedResourceValues.isReadable, true)
        XCTAssertEqual(regeneratedResourceValues.isRegularFile, true)
        XCTAssertEqual(regeneratedResourceValues.isSymbolicLink, false)
        let regeneratedAudioFile = try AVAudioFile(forReading: regeneratedDerivativeURL)
        XCTAssertGreaterThan(regeneratedAudioFile.length, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    func testLoudnessCacheRejectsManifestSourceHashNotBoundToCurrentSnapshot() async throws {
        let isStrictHash: (String) -> Bool = { value in
            let scalars = value.unicodeScalars
            return scalars.count == 64 && scalars.allSatisfy { scalar in
                (48...57).contains(scalar.value) || (97...102).contains(scalar.value)
            }
        }
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        let cacheRootURL = temporaryDirectory.appendingPathComponent(
            "loudness-cache",
            isDirectory: true
        )
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        var processorInvocationCount = 0
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, processingSettings in
                processorInvocationCount += 1
                return try MusicLoudnessOfflineProcessor.process(
                    sourceURL: processingSourceURL,
                    destinationURL: destinationURL,
                    settings: processingSettings
                )
            }
        )

        let firstResolution: MusicLoudnessResolution = await coordinator.resolve(
            sourceURL: sourceURL
        )

        guard case .generated = firstResolution.status else {
            XCTFail("Expected the controlled fixture to generate its initial derivative")
            return
        }
        XCTAssertEqual(processorInvocationCount, 1)
        let derivativeURL = firstResolution.playbackURL.standardizedFileURL
        let manifestURL = derivativeURL.deletingLastPathComponent()
            .appendingPathComponent("manifest.json", isDirectory: false)
        let originalDerivativeBytes = try Data(contentsOf: derivativeURL)
        let originalManifest = try JSONDecoder().decode(
            MusicLoudnessCacheManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertTrue(isStrictHash(originalManifest.sourceSHA256Hex))
        XCTAssertTrue(isStrictHash(originalManifest.cacheKey))
        XCTAssertEqual(
            MusicLoudnessCacheKey.make(
                sourceSHA256Hex: originalManifest.sourceSHA256Hex,
                settings: settings
            ),
            originalManifest.cacheKey
        )

        let tamperedSourceHash = originalManifest.sourceSHA256Hex == String(repeating: "0", count: 64)
            ? String(repeating: "1", count: 64)
            : String(repeating: "0", count: 64)
        let manifestBytes = try Data(contentsOf: manifestURL)
        var manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any]
        )
        manifestObject["sourceSHA256Hex"] = tamperedSourceHash
        let tamperedManifestBytes = try JSONSerialization.data(withJSONObject: manifestObject)
        try tamperedManifestBytes.write(to: manifestURL, options: .atomic)

        var tamperedManifestStatus = stat()
        XCTAssertEqual(lstat(manifestURL.path, &tamperedManifestStatus), 0)
        XCTAssertEqual(tamperedManifestStatus.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
        XCTAssertEqual(try Data(contentsOf: derivativeURL), originalDerivativeBytes)
        XCTAssertGreaterThan(try AVAudioFile(forReading: derivativeURL).length, 0)

        let secondResolution: MusicLoudnessResolution = await coordinator.resolve(
            sourceURL: sourceURL
        )

        if case .reused = secondResolution.status {
            XCTFail("Must not reuse a cache whose source hash is unrelated to the current snapshot")
        }
        guard case .generated = secondResolution.status else {
            XCTFail("Expected the unrelated manifest source hash to force regeneration")
            return
        }
        XCTAssertEqual(processorInvocationCount, 2)
        let regeneratedDerivativeURL = secondResolution.playbackURL.standardizedFileURL
        XCTAssertEqual(regeneratedDerivativeURL, derivativeURL)
        XCTAssertGreaterThan(try AVAudioFile(forReading: regeneratedDerivativeURL).length, 0)

        let regeneratedManifest = try JSONDecoder().decode(
            MusicLoudnessCacheManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertNotEqual(regeneratedManifest.sourceSHA256Hex, tamperedSourceHash)
        XCTAssertEqual(regeneratedManifest.sourceSHA256Hex, originalManifest.sourceSHA256Hex)
        XCTAssertEqual(regeneratedManifest.cacheKey, originalManifest.cacheKey)
        XCTAssertEqual(
            MusicLoudnessCacheKey.make(
                sourceSHA256Hex: regeneratedManifest.sourceSHA256Hex,
                settings: settings
            ),
            regeneratedManifest.cacheKey
        )
        XCTAssertEqual(
            regeneratedDerivativeURL.deletingLastPathComponent().lastPathComponent,
            regeneratedManifest.cacheKey
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @MainActor
    func testAppBackgroundingCancelsLoudnessWorkPreservesPlaybackAndForegroundingResumesQueue() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let processorStateLock = NSLock()
        var processorInvocationCount = 0
        var cancellationWasObserved = false
        var releaseProcessors = false
        defer {
            processorStateLock.withLock {
                releaseProcessors = true
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceAURL = temporaryDirectory.appendingPathComponent("background-A.wav")
        let sourceBURL = temporaryDirectory.appendingPathComponent("background-B.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceAURL, amplitude: pow(10, -30.0 / 20.0), duration: 10)
        try writeSineWave(to: sourceBURL, amplitude: pow(10, -24.0 / 20.0), duration: 10)
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { _, _, _ in
                processorStateLock.withLock {
                    processorInvocationCount += 1
                }

                while true {
                    if Task.isCancelled {
                        processorStateLock.withLock {
                            cancellationWasObserved = true
                        }
                        throw CancellationError()
                    }
                    if processorStateLock.withLock({ releaseProcessors }) {
                        throw CancellationError()
                    }
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {}
        )
        let songA = MusicItem(url: sourceAURL, duration: 10)
        let songB = MusicItem(url: sourceBURL, duration: 10)
        let queue = [songA, songB]

        playbackManager.updateQueue(queue)
        playbackManager.play(songA)

        let processorStartDeadline = Date().addingTimeInterval(2)
        while processorStateLock.withLock({ processorInvocationCount == 0 }),
              Date() < processorStartDeadline {
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(
            processorStateLock.withLock { processorInvocationCount },
            1,
            "Timed out waiting for the first loudness processor invocation"
        )
        let playingAssetURL = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
            .url.standardizedFileURL
        XCTAssertTrue(playbackManager.isPlaying)
        XCTAssertEqual(playbackManager.currentTrack, songA)

        NotificationCenter.default.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        let cancellationDeadline = Date().addingTimeInterval(1)
        while !processorStateLock.withLock({ cancellationWasObserved }),
              Date() < cancellationDeadline {
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(
            processorStateLock.withLock { cancellationWasObserved },
            "Backgrounding must promptly make Task cancellation observable to the processor"
        )
        XCTAssertEqual(
            processorStateLock.withLock { processorInvocationCount },
            1,
            "A queued processor must not start after background cancellation"
        )
        XCTAssertTrue(playbackManager.isPlaying)
        XCTAssertEqual(playbackManager.currentTrack, songA)
        XCTAssertEqual(
            (player.currentItem?.asset as? AVURLAsset)?.url.standardizedFileURL,
            playingAssetURL
        )

        playbackManager.updateQueue(queue)
        let backgroundStabilityDeadline = Date().addingTimeInterval(0.1)
        while Date() < backgroundStabilityDeadline {
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(
            processorStateLock.withLock { processorInvocationCount },
            1,
            "Queue normalization must not be rescheduled while the app is backgrounded"
        )

        NotificationCenter.default.post(
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )

        let foregroundResumeDeadline = Date().addingTimeInterval(2)
        while processorStateLock.withLock({ processorInvocationCount < 2 }),
              Date() < foregroundResumeDeadline {
            await Task.yield()
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertGreaterThanOrEqual(
            processorStateLock.withLock { processorInvocationCount },
            2,
            "Foregrounding must resume queue loudness normalization"
        )
        XCTAssertTrue(playbackManager.isPlaying)
        XCTAssertEqual(playbackManager.currentTrack, songA)
        XCTAssertEqual(
            (player.currentItem?.asset as? AVURLAsset)?.url.standardizedFileURL,
            playingAssetURL
        )
    }

    @MainActor
    func testForegroundValidationRestartsCancelledSameIdentityWorkAfterBlockedTaskReturns() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let firstProcessorGate = DispatchSemaphore(value: 0)
        let state = LockedTestState((
            processorInvocationCount: 0,
            activeProcessorCount: 0,
            maximumActiveProcessorCount: 0,
            validationCount: 0,
            firstProcessorWasReleased: false,
            staleResultWasPublished: false
        ))
        defer {
            let needsRelease = state.withLock {
                let needsRelease = !$0.firstProcessorWasReleased
                $0.firstProcessorWasReleased = true
                return needsRelease
            }
            if needsRelease { firstProcessorGate.signal() }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURL = temporaryDirectory.appendingPathComponent("foreground-race.wav").standardizedFileURL
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0), duration: 0.01)
        let settings = try XCTUnwrap(MusicLoudnessNormalizationSettings(
            targetIntegratedLevelDBFS: -16,
            truePeakCeilingDBTP: -1.5,
            maximumBoostDB: 12,
            algorithmVersion: 1
        ))
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: temporaryDirectory.appendingPathComponent("cache", isDirectory: true),
            settings: settings,
            processor: { processingSourceURL, destinationURL, _ in
                let invocation = state.withLock {
                    $0.processorInvocationCount += 1
                    $0.activeProcessorCount += 1
                    $0.maximumActiveProcessorCount = max(
                        $0.maximumActiveProcessorCount,
                        $0.activeProcessorCount
                    )
                    return $0.processorInvocationCount
                }
                defer { state.withLock { $0.activeProcessorCount -= 1 } }
                if invocation == 1 {
                    // Deliberately ignore cancellation until the authoritative
                    // foreground validation has applied.
                    firstProcessorGate.wait()
                }
                try FileManager.default.copyItem(at: processingSourceURL, to: destinationURL)
                return MusicLoudnessProcessingResult(
                    measuredIntegratedLevelDBFS: -30,
                    measuredTruePeakDBTP: -30,
                    outputIntegratedLevelDBFS: -16,
                    outputTruePeakDBTP: -16,
                    appliedGainDB: 12
                )
            }
        )
        let playbackManager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: defaults,
            loudnessCoordinator: coordinator,
            loudnessInstrumentation: MusicLoudnessSchedulingInstrumentation(
                didValidateSource: { _ in state.withLock { $0.validationCount += 1 } }
            ),
            activateAudioSession: {}
        )
        let progressObservation = playbackManager.$loudnessLibraryProgress
            .dropFirst()
            .sink { progress in
                let processorInvocations = state.withLock { $0.processorInvocationCount }
                if progress.completedCount > 0, processorInvocations < 2 {
                    state.withLock { $0.staleResultWasPublished = true }
                }
            }

        playbackManager.updateQueue([MusicItem(url: sourceURL, duration: 0.01)])
        for _ in 0..<20_000 where state.withLock({ $0.processorInvocationCount < 1 }) {
            await Task.yield()
        }
        XCTAssertEqual(state.withLock { $0.processorInvocationCount }, 1)
        XCTAssertEqual(state.withLock { $0.validationCount }, 1)

        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        for _ in 0..<1_000 { await Task.yield() }
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)

        // A true 0/1 foreground progress snapshot is only published after the
        // replacement authoritative validation has applied on MainActor.
        for _ in 0..<20_000
        where state.withLock({ $0.validationCount < 2 })
            || !playbackManager.isNormalizingLoudnessLibrary
            || playbackManager.loudnessNormalizationTotalCount != 1 {
            await Task.yield()
        }
        XCTAssertEqual(state.withLock { $0.validationCount }, 2)
        XCTAssertEqual(state.withLock { $0.processorInvocationCount }, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 0)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)
        XCTAssertTrue(playbackManager.isNormalizingLoudnessLibrary)

        state.withLock { $0.firstProcessorWasReleased = true }
        firstProcessorGate.signal()
        for _ in 0..<40_000
        where state.withLock({ $0.processorInvocationCount < 2 })
            || playbackManager.loudnessNormalizationCompletedCount != 1
            || playbackManager.loudnessNormalizationTotalCount != 1
            || playbackManager.isNormalizingLoudnessLibrary {
            await Task.yield()
        }
        withExtendedLifetime(progressObservation) {}

        XCTAssertEqual(state.withLock { $0.processorInvocationCount }, 2)
        XCTAssertEqual(state.withLock { $0.maximumActiveProcessorCount }, 1)
        XCTAssertEqual(state.withLock { $0.validationCount }, 2)
        XCTAssertFalse(state.withLock { $0.staleResultWasPublished })
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)
    }

    @MainActor
    func testColdLaunchDefersRepeatedQueueLoudnessSchedulingUntilForegroundActivation() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let processorStateLock = NSLock()
        var processorInvocationCount = 0
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURL = temporaryDirectory.appendingPathComponent("cold-launch.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        let originalData = try Data(contentsOf: sourceURL)
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, _ in
                processorStateLock.withLock {
                    processorInvocationCount += 1
                }
                try FileManager.default.copyItem(
                    at: processingSourceURL,
                    to: destinationURL
                )
                return MusicLoudnessProcessingResult(
                    measuredIntegratedLevelDBFS: -30,
                    measuredTruePeakDBTP: -30,
                    outputIntegratedLevelDBFS: -16,
                    outputTruePeakDBTP: -16,
                    appliedGainDB: 12
                )
            }
        )
        let playbackManager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: defaults,
            loudnessCoordinator: coordinator,
            initialQueueLoudnessScheduling: .deferredUntilForegroundActivation,
            activateAudioSession: {}
        )
        let item = MusicItem(url: sourceURL, duration: 1)

        playbackManager.updateQueue([])
        playbackManager.updateQueue([item])
        playbackManager.updateQueue([item])
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(playbackManager.queue, [item])
        XCTAssertEqual(processorStateLock.withLock { processorInvocationCount }, 0)
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 0)

        playbackManager.activateDeferredLoudnessNormalizationForForeground()
        playbackManager.activateDeferredLoudnessNormalizationForForeground()
        playbackManager.updateQueue([item])

        let completionDeadline = Date().addingTimeInterval(10)
        while processorStateLock.withLock({ processorInvocationCount == 0 }),
              Date() < completionDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(processorStateLock.withLock { processorInvocationCount }, 1)
        XCTAssertEqual(playbackManager.queue, [item])
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
    }

    @MainActor
    func testRemovingAndReaddingSourceInvalidatesStaleLoudnessWork() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let processorGate = DispatchSemaphore(value: 0)
        let processorStateLock = NSLock()
        var processorInvocationCount = 0
        var firstProcessorReleased = false
        var firstProcessorObservedCancellation = false
        defer {
            let needsRelease = processorStateLock.withLock {
                let needsRelease = !firstProcessorReleased
                firstProcessorReleased = true
                return needsRelease
            }
            if needsRelease {
                processorGate.signal()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURL = temporaryDirectory.appendingPathComponent("generation.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        let originalData = try Data(contentsOf: sourceURL)
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, _ in
                let invocation = processorStateLock.withLock {
                    processorInvocationCount += 1
                    return processorInvocationCount
                }
                if invocation == 1 {
                    processorGate.wait()
                    processorStateLock.withLock {
                        firstProcessorObservedCancellation = Task.isCancelled
                    }
                }
                try FileManager.default.copyItem(
                    at: processingSourceURL,
                    to: destinationURL
                )
                return MusicLoudnessProcessingResult(
                    measuredIntegratedLevelDBFS: -30,
                    measuredTruePeakDBTP: -30,
                    outputIntegratedLevelDBFS: -16,
                    outputTruePeakDBTP: -16,
                    appliedGainDB: 12
                )
            }
        )
        let playbackManager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {}
        )
        let item = MusicItem(url: sourceURL, duration: 1)

        playbackManager.updateQueue([item])
        let processorStartDeadline = Date().addingTimeInterval(10)
        while processorStateLock.withLock({ processorInvocationCount == 0 }),
              Date() < processorStartDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(processorStateLock.withLock { processorInvocationCount }, 1)

        playbackManager.updateQueue([])
        playbackManager.updateQueue([item])
        processorStateLock.withLock {
            firstProcessorReleased = true
        }
        processorGate.signal()

        let completionDeadline = Date().addingTimeInterval(10)
        while playbackManager.loudnessNormalizationCompletedCount == 0,
              Date() < completionDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(
            processorStateLock.withLock { firstProcessorObservedCancellation },
            "Removing a source must cancel and invalidate its in-flight generation"
        )
        XCTAssertEqual(playbackManager.queue, [item])
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 1)
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
    }

    @MainActor
    func testLoudnessCompletionPublishesOneCoherentProgressInvalidation() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let processorGate = DispatchSemaphore(value: 0)
        let secondProcessorGate = DispatchSemaphore(value: 0)
        let processorLock = NSLock()
        var invocationCount = 0
        var didReleaseFirst = false
        defer {
            let needsRelease = processorLock.withLock {
                let needsRelease = !didReleaseFirst
                didReleaseFirst = true
                return needsRelease
            }
            if needsRelease { processorGate.signal() }
            secondProcessorGate.signal()
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURLs = try (0..<2).map { index in
            let url = temporaryDirectory.appendingPathComponent("source-\(index).wav")
            try writeSineWave(
                to: url,
                amplitude: pow(10, (index == 0 ? -30.0 : -24.0) / 20.0)
            )
            return url
        }
        let settings = try XCTUnwrap(MusicLoudnessNormalizationSettings(
            targetIntegratedLevelDBFS: -16,
            truePeakCeilingDBTP: -1.5,
            maximumBoostDB: 12,
            algorithmVersion: 1
        ))
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: temporaryDirectory.appendingPathComponent("cache", isDirectory: true),
            settings: settings,
            processor: { sourceURL, destinationURL, _ in
                let invocation = processorLock.withLock {
                    invocationCount += 1
                    return invocationCount
                }
                if invocation == 1 {
                    processorGate.wait()
                } else {
                    secondProcessorGate.wait()
                    throw CancellationError()
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                return MusicLoudnessProcessingResult(
                    measuredIntegratedLevelDBFS: -30,
                    measuredTruePeakDBTP: -30,
                    outputIntegratedLevelDBFS: -16,
                    outputTruePeakDBTP: -16,
                    appliedGainDB: 12
                )
            }
        )
        let playbackManager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {}
        )
        playbackManager.updateQueue(sourceURLs.map { MusicItem(url: $0, duration: 1) })

        let startDeadline = Date().addingTimeInterval(10)
        while processorLock.withLock({ invocationCount == 0 }), Date() < startDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(processorLock.withLock { invocationCount }, 1)

        var progressInvalidations = 0
        let observation = playbackManager.objectWillChange.sink {
            progressInvalidations += 1
        }
        processorLock.withLock { didReleaseFirst = true }
        processorGate.signal()

        let completionDeadline = Date().addingTimeInterval(10)
        while playbackManager.loudnessNormalizationCompletedCount == 0,
              Date() < completionDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        observation.cancel()

        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 1)
        XCTAssertLessThanOrEqual(
            progressInvalidations,
            1,
            "One completion must publish one coherent progress snapshot"
        )
    }

    @MainActor
    func testLoudnessCompletionInstrumentationBracketsBookkeepingAfterProcessorReturns() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        let sourceURL = temporaryDirectory.appendingPathComponent("instrumented.wav")
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0), duration: 0.01)
        let events = LockedTestState([String]())
        let settings = try XCTUnwrap(MusicLoudnessNormalizationSettings(
            targetIntegratedLevelDBFS: -16,
            truePeakCeilingDBTP: -1.5,
            maximumBoostDB: 12,
            algorithmVersion: 1
        ))
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: temporaryDirectory.appendingPathComponent("cache", isDirectory: true),
            settings: settings,
            processor: { processingSourceURL, destinationURL, _ in
                events.withLock { $0.append("processor-start") }
                try FileManager.default.copyItem(at: processingSourceURL, to: destinationURL)
                events.withLock { $0.append("processor-end") }
                return MusicLoudnessProcessingResult(
                    measuredIntegratedLevelDBFS: -30,
                    measuredTruePeakDBTP: -30,
                    outputIntegratedLevelDBFS: -16,
                    outputTruePeakDBTP: -16,
                    appliedGainDB: 12
                )
            }
        )
        let playbackManager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: defaults,
            loudnessCoordinator: coordinator,
            loudnessInstrumentation: MusicLoudnessSchedulingInstrumentation(
                willCompleteBookkeeping: { events.withLock { $0.append("bookkeeping-start") } },
                didCompleteBookkeeping: { events.withLock { $0.append("bookkeeping-end") } }
            ),
            activateAudioSession: {}
        )

        playbackManager.updateQueue([MusicItem(url: sourceURL, duration: 0.01)])
        for _ in 0..<20_000
        where playbackManager.loudnessNormalizationCompletedCount != 1
            || playbackManager.isNormalizingLoudnessLibrary {
            await Task.yield()
        }

        XCTAssertEqual(
            events.withLock { $0 },
            ["processor-start", "processor-end", "bookkeeping-start", "bookkeeping-end"]
        )
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)
    }

    @MainActor
    func testLoudnessCompletionBookkeepingLatencyIsBoundedAcrossSmallAnd227ItemQueues() async throws {
        typealias CandidateResult = (
            samples: [UInt64],
            completionCalls: Int,
            validationCalls: Int,
            completionPublications: Int
        )
        let candidate: @MainActor (Int, Int) async throws -> CandidateResult = { queueCount, round in
            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            let defaultsSuiteName = "MusicDetailPresentationTests.H4.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }
            let sourceURLs = try (0..<queueCount).map { index in
                let sourceURL = temporaryDirectory.appendingPathComponent("r\(round)-\(index).wav")
                try self.writeSineWave(
                    to: sourceURL,
                    amplitude: pow(10, (-30.0 + Double(index % 7)) / 20.0),
                    duration: 0.001
                )
                return sourceURL.standardizedFileURL
            }
            let settings = try XCTUnwrap(MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            ))
            let telemetry = LockedTestState((
                start: UInt64?.none,
                samples: [UInt64](),
                completionCalls: 0,
                validationCalls: 0,
                isInsideCompletion: false,
                completionPublications: 0
            ))
            let coordinator = MusicLoudnessCacheCoordinator(
                cacheRootURL: temporaryDirectory.appendingPathComponent("cache", isDirectory: true),
                settings: settings,
                processor: { processingSourceURL, destinationURL, _ in
                    try FileManager.default.copyItem(at: processingSourceURL, to: destinationURL)
                    return MusicLoudnessProcessingResult(
                        measuredIntegratedLevelDBFS: -30,
                        measuredTruePeakDBTP: -30,
                        outputIntegratedLevelDBFS: -16,
                        outputTruePeakDBTP: -16,
                        appliedGainDB: 12
                    )
                }
            )
            let playbackManager = MusicPlaybackManager(
                player: AVPlayer(),
                defaults: defaults,
                loudnessCoordinator: coordinator,
                loudnessInstrumentation: MusicLoudnessSchedulingInstrumentation(
                    didValidateSource: { _ in telemetry.withLock { $0.validationCalls += 1 } },
                    willCompleteBookkeeping: {
                        telemetry.withLock {
                            $0.completionCalls += 1
                            $0.isInsideCompletion = true
                            $0.start = DispatchTime.now().uptimeNanoseconds
                        }
                    },
                    didCompleteBookkeeping: {
                        let end = DispatchTime.now().uptimeNanoseconds
                        telemetry.withLock {
                            if let start = $0.start { $0.samples.append(end - start) }
                            $0.start = nil
                            $0.isInsideCompletion = false
                        }
                    }
                ),
                activateAudioSession: {}
            )
            let observation = playbackManager.objectWillChange.sink {
                telemetry.withLock {
                    if $0.isInsideCompletion { $0.completionPublications += 1 }
                }
            }

            playbackManager.updateQueue(sourceURLs.map { MusicItem(url: $0, duration: 0.001) })
            let deadline = Date().addingTimeInterval(30)
            while (playbackManager.isNormalizingLoudnessLibrary
                    || playbackManager.loudnessNormalizationCompletedCount != queueCount),
                  Date() < deadline {
                await Task.yield()
            }
            observation.cancel()
            let result = telemetry.withLock {
                CandidateResult(
                    samples: $0.samples,
                    completionCalls: $0.completionCalls,
                    validationCalls: $0.validationCalls,
                    completionPublications: $0.completionPublications
                )
            }
            XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, queueCount)
            XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, queueCount)
            XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)
            return result
        }
        let percentile: ([UInt64], Double) -> UInt64 = { samples, fraction in
            let sorted = samples.sorted()
            guard !sorted.isEmpty else { return 0 }
            let rank = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1))
            return sorted[rank]
        }
        let summary: ([UInt64]) -> String = { samples in
            let microseconds = { (value: UInt64) in String(format: "%.3f", Double(value) / 1_000) }
            return "n=\(samples.count) p50=\(microseconds(percentile(samples, 0.50)))us "
                + "p95=\(microseconds(percentile(samples, 0.95)))us "
                + "p99=\(microseconds(percentile(samples, 0.99)))us "
                + "max=\(microseconds(samples.max() ?? 0))us"
        }
        let baselineRescan: ([URL], Int) -> [UInt64] = { sourceURLs, rounds in
            var samples: [UInt64] = []
            samples.reserveCapacity(sourceURLs.count * rounds)
            for _ in 0..<rounds {
                var completed: Set<URL> = []
                for completedURL in sourceURLs {
                    completed.insert(completedURL)
                    let start = DispatchTime.now().uptimeNanoseconds
                    let allSources = Set(sourceURLs)
                    let pending = allSources
                        .subtracting(completed)
                        .sorted { $0.path < $1.path }
                    _ = pending.first
                    samples.append(DispatchTime.now().uptimeNanoseconds - start)
                }
            }
            return samples
        }

        let rounds = 3
        var smallCandidate = CandidateResult([], 0, 0, 0)
        var largeCandidate = CandidateResult([], 0, 0, 0)
        for round in 0..<rounds {
            let small = try await candidate(8, round)
            smallCandidate.samples.append(contentsOf: small.samples)
            smallCandidate.completionCalls += small.completionCalls
            smallCandidate.validationCalls += small.validationCalls
            smallCandidate.completionPublications += small.completionPublications
            let large = try await candidate(227, round)
            largeCandidate.samples.append(contentsOf: large.samples)
            largeCandidate.completionCalls += large.completionCalls
            largeCandidate.validationCalls += large.validationCalls
            largeCandidate.completionPublications += large.completionPublications
        }
        let smallURLs = (0..<8).map { URL(fileURLWithPath: "/synthetic/small/\($0).wav") }
        let largeURLs = (0..<227).map { URL(fileURLWithPath: "/synthetic/large/\($0).wav") }
        let smallBaseline = baselineRescan(smallURLs, rounds)
        let largeBaseline = baselineRescan(largeURLs, rounds)

        XCTAssertEqual(smallCandidate.samples.count, 8 * rounds)
        XCTAssertEqual(smallCandidate.completionCalls, 8 * rounds)
        XCTAssertEqual(smallCandidate.validationCalls, 8 * rounds)
        XCTAssertEqual(smallCandidate.completionPublications, 8 * rounds)
        XCTAssertEqual(largeCandidate.samples.count, 227 * rounds)
        XCTAssertEqual(largeCandidate.completionCalls, 227 * rounds)
        XCTAssertEqual(largeCandidate.validationCalls, 227 * rounds)
        XCTAssertEqual(largeCandidate.completionPublications, 227 * rounds)
        XCTAssertEqual(smallBaseline.count, 8 * rounds)
        XCTAssertEqual(largeBaseline.count, 227 * rounds)
        XCTAssertLessThan(
            percentile(largeCandidate.samples, 0.95),
            percentile(largeBaseline, 0.95),
            "Candidate completion bookkeeping must remain cheaper than the old full-rescan shape"
        )

        print("H4_LATENCY candidate-small \(summary(smallCandidate.samples)) calls=\(smallCandidate.completionCalls) publications=\(smallCandidate.completionPublications) validations=\(smallCandidate.validationCalls)")
        print("H4_LATENCY candidate-227 \(summary(largeCandidate.samples)) calls=\(largeCandidate.completionCalls) publications=\(largeCandidate.completionPublications) validations=\(largeCandidate.validationCalls)")
        print("H4_LATENCY baseline-rescan-small \(summary(smallBaseline)) calls=\(smallBaseline.count) publications-model=\(smallBaseline.count * 3)")
        print("H4_LATENCY baseline-rescan-227 \(summary(largeBaseline)) calls=\(largeBaseline.count) publications-model=\(largeBaseline.count * 3)")
    }

    @MainActor
    func testLoudnessCompletionDoesNotRevalidate227ItemQueue() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let firstProcessorGate = DispatchSemaphore(value: 0)
        let secondProcessorGate = DispatchSemaphore(value: 0)
        let state = LockedTestState((
            processorInvocationCount: 0,
            validationCount: 0,
            didReleaseFirst: false
        ))
        defer {
            let needsRelease = state.withLock {
                let needsRelease = !$0.didReleaseFirst
                $0.didReleaseFirst = true
                return needsRelease
            }
            if needsRelease { firstProcessorGate.signal() }
            secondProcessorGate.signal()
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURLs = try (0..<227).map { index in
            let sourceURL = temporaryDirectory.appendingPathComponent("source-\(index).wav")
            try writeSineWave(
                to: sourceURL,
                amplitude: pow(10, (-30.0 + Double(index % 7)) / 20.0),
                duration: 0.01
            )
            return sourceURL
        }
        let settings = try XCTUnwrap(MusicLoudnessNormalizationSettings(
            targetIntegratedLevelDBFS: -16,
            truePeakCeilingDBTP: -1.5,
            maximumBoostDB: 12,
            algorithmVersion: 1
        ))
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: temporaryDirectory.appendingPathComponent("cache", isDirectory: true),
            settings: settings,
            processor: { sourceURL, destinationURL, _ in
                let invocation = state.withLock {
                    $0.processorInvocationCount += 1
                    return $0.processorInvocationCount
                }
                if invocation == 1 {
                    firstProcessorGate.wait()
                } else {
                    secondProcessorGate.wait()
                    throw CancellationError()
                }
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                return MusicLoudnessProcessingResult(
                    measuredIntegratedLevelDBFS: -30,
                    measuredTruePeakDBTP: -30,
                    outputIntegratedLevelDBFS: -16,
                    outputTruePeakDBTP: -16,
                    appliedGainDB: 12
                )
            }
        )
        let playbackManager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: defaults,
            loudnessCoordinator: coordinator,
            loudnessInstrumentation: MusicLoudnessSchedulingInstrumentation(
                didValidateSource: { _ in
                    state.withLock { $0.validationCount += 1 }
                }
            ),
            activateAudioSession: {}
        )

        playbackManager.updateQueue(sourceURLs.map { MusicItem(url: $0, duration: 0.01) })
        let startDeadline = Date().addingTimeInterval(10)
        while state.withLock({ $0.processorInvocationCount == 0 }), Date() < startDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(state.withLock { $0.validationCount }, 227)
        XCTAssertEqual(state.withLock { $0.processorInvocationCount }, 1)

        state.withLock { $0.didReleaseFirst = true }
        firstProcessorGate.signal()
        let completionDeadline = Date().addingTimeInterval(10)
        while playbackManager.loudnessNormalizationCompletedCount == 0,
              Date() < completionDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 1)
        XCTAssertEqual(
            state.withLock { $0.validationCount },
            227,
            "A completion must advance from validated state without rescanning the queue"
        )
    }

    @MainActor
    func testReplacementValidationNeverPublishesPriorCompletedProgressAsIdle() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let validationGate = DispatchSemaphore(value: 0)
        let processorGate = DispatchSemaphore(value: 0)
        let state = LockedTestState((
            replacementValidationIsBlocked: false,
            replacementProcessorStarted: false,
            validationWasReleased: false,
            processorWasReleased: false,
            progressDuringReplacement: [MusicLoudnessLibraryProgress]()
        ))
        defer {
            let releases = state.withLock {
                let releases = (!$0.validationWasReleased, !$0.processorWasReleased)
                $0.validationWasReleased = true
                $0.processorWasReleased = true
                return releases
            }
            if releases.0 { validationGate.signal() }
            if releases.1 { processorGate.signal() }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let oldSourceURL = temporaryDirectory.appendingPathComponent("old.wav").standardizedFileURL
        let replacementSourceURL = temporaryDirectory
            .appendingPathComponent("replacement.wav")
            .standardizedFileURL
        try writeSineWave(to: oldSourceURL, amplitude: pow(10, -30.0 / 20.0), duration: 0.01)
        try writeSineWave(to: replacementSourceURL, amplitude: pow(10, -12.0 / 20.0), duration: 0.01)
        let replacementSourceData = try Data(contentsOf: replacementSourceURL)
        let settings = try XCTUnwrap(MusicLoudnessNormalizationSettings(
            targetIntegratedLevelDBFS: -16,
            truePeakCeilingDBTP: -1.5,
            maximumBoostDB: 12,
            algorithmVersion: 1
        ))
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: temporaryDirectory.appendingPathComponent("cache", isDirectory: true),
            settings: settings,
            processor: { processingSourceURL, destinationURL, _ in
                if try Data(contentsOf: processingSourceURL) == replacementSourceData {
                    state.withLock { $0.replacementProcessorStarted = true }
                    processorGate.wait()
                }
                try FileManager.default.copyItem(at: processingSourceURL, to: destinationURL)
                return MusicLoudnessProcessingResult(
                    measuredIntegratedLevelDBFS: -30,
                    measuredTruePeakDBTP: -30,
                    outputIntegratedLevelDBFS: -16,
                    outputTruePeakDBTP: -16,
                    appliedGainDB: 12
                )
            }
        )
        let playbackManager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: defaults,
            loudnessCoordinator: coordinator,
            loudnessInstrumentation: MusicLoudnessSchedulingInstrumentation(
                didValidateSource: { sourceURL in
                    guard sourceURL.standardizedFileURL == replacementSourceURL else { return }
                    state.withLock { $0.replacementValidationIsBlocked = true }
                    validationGate.wait()
                }
            ),
            activateAudioSession: {}
        )

        playbackManager.updateQueue([MusicItem(url: oldSourceURL, duration: 0.01)])
        for _ in 0..<20_000
        where playbackManager.loudnessNormalizationCompletedCount != 1
            || playbackManager.loudnessNormalizationTotalCount != 1
            || playbackManager.isNormalizingLoudnessLibrary {
            await Task.yield()
        }
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)

        let progressObservation = playbackManager.$loudnessLibraryProgress
            .dropFirst()
            .sink { progress in
                state.withLock { $0.progressDuringReplacement.append(progress) }
            }
        playbackManager.updateQueue([MusicItem(url: replacementSourceURL, duration: 0.01)])
        for _ in 0..<10_000 where !state.withLock({ $0.replacementValidationIsBlocked }) {
            await Task.yield()
        }
        XCTAssertTrue(state.withLock { $0.replacementValidationIsBlocked })
        XCTAssertFalse(
            state.withLock { $0.progressDuringReplacement }.contains {
                !$0.isNormalizing && $0.completedCount == 1 && $0.totalCount == 1
            },
            "Foreground validation must count as active work or coherently hide/reset the prior completed totals"
        )

        state.withLock { $0.validationWasReleased = true }
        validationGate.signal()
        for _ in 0..<10_000 where !state.withLock({ $0.replacementProcessorStarted }) {
            await Task.yield()
        }
        XCTAssertTrue(state.withLock { $0.replacementProcessorStarted })

        state.withLock {
            $0.progressDuringReplacement.removeAll()
            $0.processorWasReleased = true
        }
        processorGate.signal()
        for _ in 0..<20_000
        where playbackManager.loudnessNormalizationCompletedCount != 1
            || playbackManager.loudnessNormalizationTotalCount != 1
            || playbackManager.isNormalizingLoudnessLibrary
            || !state.withLock({ progress in
                progress.progressDuringReplacement.last.map {
                    !$0.isNormalizing && $0.completedCount == 1 && $0.totalCount == 1
                } ?? false
            }) {
            await Task.yield()
        }
        withExtendedLifetime(progressObservation) {}

        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)
        let finalProgress = try XCTUnwrap(state.withLock { $0.progressDuringReplacement.last })
        XCTAssertEqual(finalProgress.completedCount, 1)
        XCTAssertEqual(finalProgress.totalCount, 1)
        XCTAssertFalse(finalProgress.isNormalizing)
    }

    @MainActor
    func testCompletedLoudnessWorkConvergesToIdleWhenCapturedValidationAppliesLate() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let processorGate = DispatchSemaphore(value: 0)
        let validationGate = DispatchSemaphore(value: 0)
        let state = LockedTestState((
            processorInvocationCount: 0,
            validationInvocationCount: 0,
            secondValidationIsBlocked: false,
            processorWasReleased: false,
            validationWasReleased: false
        ))
        defer {
            let releases = state.withLock {
                let releases = (!$0.processorWasReleased, !$0.validationWasReleased)
                $0.processorWasReleased = true
                $0.validationWasReleased = true
                return releases
            }
            if releases.0 { processorGate.signal() }
            if releases.1 { validationGate.signal() }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURL = temporaryDirectory.appendingPathComponent("source.wav")
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0), duration: 0.01)
        let settings = try XCTUnwrap(MusicLoudnessNormalizationSettings(
            targetIntegratedLevelDBFS: -16,
            truePeakCeilingDBTP: -1.5,
            maximumBoostDB: 12,
            algorithmVersion: 1
        ))
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: temporaryDirectory.appendingPathComponent("cache", isDirectory: true),
            settings: settings,
            processor: { sourceURL, destinationURL, _ in
                state.withLock { $0.processorInvocationCount += 1 }
                processorGate.wait()
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                return MusicLoudnessProcessingResult(
                    measuredIntegratedLevelDBFS: -30,
                    measuredTruePeakDBTP: -30,
                    outputIntegratedLevelDBFS: -16,
                    outputTruePeakDBTP: -16,
                    appliedGainDB: 12
                )
            }
        )
        let playbackManager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: defaults,
            loudnessCoordinator: coordinator,
            loudnessInstrumentation: MusicLoudnessSchedulingInstrumentation(
                didValidateSource: { _ in
                    let invocation = state.withLock {
                        $0.validationInvocationCount += 1
                        if $0.validationInvocationCount == 2 { $0.secondValidationIsBlocked = true }
                        return $0.validationInvocationCount
                    }
                    if invocation == 2 { validationGate.wait() }
                }
            ),
            activateAudioSession: {}
        )
        let item = MusicItem(url: sourceURL, duration: 0.01)

        playbackManager.updateQueue([item])
        for _ in 0..<10_000 where state.withLock({ $0.processorInvocationCount == 0 }) {
            await Task.yield()
        }
        XCTAssertEqual(state.withLock { $0.processorInvocationCount }, 1)

        // This validation has already captured the empty completed-playback snapshot.
        playbackManager.updateQueue([item])
        for _ in 0..<10_000 where !state.withLock({ $0.secondValidationIsBlocked }) {
            await Task.yield()
        }
        XCTAssertTrue(state.withLock { $0.secondValidationIsBlocked })

        state.withLock { $0.processorWasReleased = true }
        processorGate.signal()
        for _ in 0..<10_000
        where playbackManager.loudnessNormalizationCompletedCount != 1
            || playbackManager.isNormalizingLoudnessLibrary {
            await Task.yield()
        }
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)

        var progressAfterValidationRelease: [MusicLoudnessLibraryProgress] = []
        let progressObservation = playbackManager.$loudnessLibraryProgress
            .dropFirst()
            .sink { progressAfterValidationRelease.append($0) }
        state.withLock { $0.validationWasReleased = true }
        validationGate.signal()
        for _ in 0..<10_000 { await Task.yield() }
        withExtendedLifetime(progressObservation) {}

        XCTAssertEqual(state.withLock { $0.processorInvocationCount }, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)
        XCTAssertFalse(
            progressAfterValidationRelease.contains {
                $0.isNormalizing || $0.completedCount != 1 || $0.totalCount != 1
            },
            "A late validation must not overwrite the completed snapshot or leave pending work before returning to idle"
        )
    }

    @MainActor
    func testRemovingPendingLoudnessItemWhileReplacementValidationIsBlockedDoesNotResurrectItsWork() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let processorGate = DispatchSemaphore(value: 0)
        let validationGate = DispatchSemaphore(value: 0)
        let state = LockedTestState((
            aProcessorInvocationCount: 0,
            bProcessorInvocationCount: 0,
            aValidationInvocationCount: 0,
            replacementValidationIsBlocked: false,
            aProcessorCompleted: false,
            processorWasReleased: false,
            validationWasReleased: false,
            progressAfterReplacement: [MusicLoudnessLibraryProgress]()
        ))
        defer {
            let releases = state.withLock {
                let releases = (!$0.processorWasReleased, !$0.validationWasReleased)
                $0.processorWasReleased = true
                $0.validationWasReleased = true
                return releases
            }
            if releases.0 { processorGate.signal() }
            if releases.1 { validationGate.signal() }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceAURL = temporaryDirectory.appendingPathComponent("A.wav").standardizedFileURL
        let sourceBURL = temporaryDirectory.appendingPathComponent("B.wav").standardizedFileURL
        try writeSineWave(to: sourceAURL, amplitude: pow(10, -30.0 / 20.0), duration: 0.01)
        try writeSineWave(to: sourceBURL, amplitude: pow(10, -24.0 / 20.0), duration: 0.01)
        let sourceABytes = try Data(contentsOf: sourceAURL)
        let sourceBBytes = try Data(contentsOf: sourceBURL)
        let settings = try XCTUnwrap(MusicLoudnessNormalizationSettings(
            targetIntegratedLevelDBFS: -16,
            truePeakCeilingDBTP: -1.5,
            maximumBoostDB: 12,
            algorithmVersion: 1
        ))
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: temporaryDirectory.appendingPathComponent("cache", isDirectory: true),
            settings: settings,
            processor: { processingSourceURL, destinationURL, _ in
                let sourceBytes = try Data(contentsOf: processingSourceURL)
                if sourceBytes == sourceABytes {
                    state.withLock { $0.aProcessorInvocationCount += 1 }
                    processorGate.wait()
                    try sourceBytes.write(to: destinationURL)
                    state.withLock { $0.aProcessorCompleted = true }
                } else if sourceBytes == sourceBBytes {
                    state.withLock { $0.bProcessorInvocationCount += 1 }
                    try sourceBytes.write(to: destinationURL)
                } else {
                    XCTFail("Unexpected loudness processor source bytes")
                }
                return MusicLoudnessProcessingResult(
                    measuredIntegratedLevelDBFS: -30,
                    measuredTruePeakDBTP: -30,
                    outputIntegratedLevelDBFS: -16,
                    outputTruePeakDBTP: -16,
                    appliedGainDB: 12
                )
            }
        )
        let playbackManager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: defaults,
            loudnessCoordinator: coordinator,
            loudnessInstrumentation: MusicLoudnessSchedulingInstrumentation(
                didValidateSource: { sourceURL in
                    guard sourceURL.standardizedFileURL == sourceAURL else { return }
                    let invocation = state.withLock {
                        $0.aValidationInvocationCount += 1
                        if $0.aValidationInvocationCount == 2 {
                            $0.replacementValidationIsBlocked = true
                        }
                        return $0.aValidationInvocationCount
                    }
                    if invocation == 2 { validationGate.wait() }
                }
            ),
            activateAudioSession: {}
        )
        let itemA = MusicItem(url: sourceAURL, duration: 0.01)
        let itemB = MusicItem(url: sourceBURL, duration: 0.01)

        playbackManager.updateQueue([itemA, itemB])
        for _ in 0..<10_000 where state.withLock({ $0.aProcessorInvocationCount == 0 }) {
            await Task.yield()
        }
        XCTAssertEqual(state.withLock { $0.aProcessorInvocationCount }, 1)
        XCTAssertEqual(state.withLock { $0.bProcessorInvocationCount }, 0)
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 0)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 2)
        XCTAssertTrue(playbackManager.isNormalizingLoudnessLibrary)

        playbackManager.updateQueue([itemA])
        for _ in 0..<10_000 where !state.withLock({ $0.replacementValidationIsBlocked }) {
            await Task.yield()
        }
        XCTAssertTrue(state.withLock { $0.replacementValidationIsBlocked })
        let progressObservation = playbackManager.$loudnessLibraryProgress
            .dropFirst()
            .sink { progress in
                state.withLock { $0.progressAfterReplacement.append(progress) }
            }

        state.withLock { $0.processorWasReleased = true }
        processorGate.signal()
        for _ in 0..<10_000
        where !state.withLock({ $0.aProcessorCompleted })
            || (playbackManager.loudnessNormalizationCompletedCount == 0
                && state.withLock({ $0.bProcessorInvocationCount == 0 })) {
            await Task.yield()
        }

        XCTAssertEqual(
            state.withLock { $0.bProcessorInvocationCount },
            0,
            "Deleted B must not regain a work generation or leave the stale pending queue"
        )
        XCTAssertFalse(
            state.withLock { $0.progressAfterReplacement }.contains {
                $0.completedCount > 1 || $0.totalCount > 1
            },
            "No post-replacement progress or normalizing state may include deleted B"
        )

        state.withLock { $0.validationWasReleased = true }
        validationGate.signal()
        for _ in 0..<10_000
        where playbackManager.loudnessNormalizationCompletedCount != 1
            || playbackManager.loudnessNormalizationTotalCount != 1
            || playbackManager.isNormalizingLoudnessLibrary {
            await Task.yield()
        }
        withExtendedLifetime(progressObservation) {}

        XCTAssertEqual(state.withLock { $0.aProcessorInvocationCount }, 1)
        XCTAssertEqual(state.withLock { $0.bProcessorInvocationCount }, 0)
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)
        XCTAssertFalse(
            state.withLock { $0.progressAfterReplacement }.contains {
                $0.completedCount > 1 || $0.totalCount > 1
            }
        )
    }

    @MainActor
    func testActiveSameURLReplacementRejectsStaleDerivativeAndProcessesReplacementExactlyOnce() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let firstProcessorGate = DispatchSemaphore(value: 0)
        let firstProcessorStarted = expectation(description: "first processor started")
        let replacementWasValidated = expectation(description: "replacement was validated")
        let replacementProcessorStarted = expectation(description: "replacement processor started")
        let state = LockedTestState((
            processorInvocationCount: 0,
            validationCount: 0,
            processedSourceBytes: [Data](),
            firstProcessorWasReleased: false
        ))
        defer {
            let needsRelease = state.withLock {
                let needsRelease = !$0.firstProcessorWasReleased
                $0.firstProcessorWasReleased = true
                return needsRelease
            }
            if needsRelease { firstProcessorGate.signal() }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURL = temporaryDirectory.appendingPathComponent("same-url.wav")
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0), duration: 0.01)
        let originalBytes = try Data(contentsOf: sourceURL)
        let settings = try XCTUnwrap(MusicLoudnessNormalizationSettings(
            targetIntegratedLevelDBFS: -16,
            truePeakCeilingDBTP: -1.5,
            maximumBoostDB: 12,
            algorithmVersion: 1
        ))
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: temporaryDirectory.appendingPathComponent("cache", isDirectory: true),
            settings: settings,
            processor: { processingSourceURL, destinationURL, _ in
                let sourceBytes = try Data(contentsOf: processingSourceURL)
                let invocation = state.withLock {
                    $0.processorInvocationCount += 1
                    $0.processedSourceBytes.append(sourceBytes)
                    return $0.processorInvocationCount
                }
                if invocation == 1 {
                    firstProcessorStarted.fulfill()
                    firstProcessorGate.wait()
                } else if invocation == 2 {
                    replacementProcessorStarted.fulfill()
                }
                try sourceBytes.write(to: destinationURL)
                return MusicLoudnessProcessingResult(
                    measuredIntegratedLevelDBFS: -30,
                    measuredTruePeakDBTP: -30,
                    outputIntegratedLevelDBFS: -16,
                    outputTruePeakDBTP: -16,
                    appliedGainDB: 12
                )
            }
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            loudnessInstrumentation: MusicLoudnessSchedulingInstrumentation(
                didValidateSource: { _ in
                    let validationCount = state.withLock {
                        $0.validationCount += 1
                        return $0.validationCount
                    }
                    if validationCount == 2 { replacementWasValidated.fulfill() }
                }
            ),
            activateAudioSession: {}
        )
        let item = MusicItem(url: sourceURL, duration: 0.01)

        playbackManager.updateQueue([item])
        await fulfillment(of: [firstProcessorStarted], timeout: 5)
        XCTAssertEqual(state.withLock { $0.processorInvocationCount }, 1)
        XCTAssertEqual(state.withLock { $0.validationCount }, 1)

        try FileManager.default.removeItem(at: sourceURL)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -6.0 / 20.0), duration: 0.02)
        let replacementBytes = try Data(contentsOf: sourceURL)
        XCTAssertNotEqual(replacementBytes, originalBytes)
        playbackManager.updateQueue([MusicItem(url: sourceURL, duration: 0.02)])

        await fulfillment(of: [replacementWasValidated], timeout: 5)
        XCTAssertEqual(state.withLock { $0.validationCount }, 2)
        state.withLock { $0.firstProcessorWasReleased = true }
        firstProcessorGate.signal()

        await fulfillment(of: [replacementProcessorStarted], timeout: 5)
        let normalizationCompleted = expectation(description: "replacement normalization completed")
        let progressObservation = playbackManager.$loudnessLibraryProgress
            .filter { progress in
                !progress.isNormalizing
                    && progress.completedCount == 1
                    && progress.totalCount == 1
            }
            .first()
            .sink { _ in normalizationCompleted.fulfill() }
        await fulfillment(of: [normalizationCompleted], timeout: 5)
        withExtendedLifetime(progressObservation) {}
        XCTAssertEqual(state.withLock { $0.processorInvocationCount }, 2)
        XCTAssertEqual(state.withLock { $0.validationCount }, 2,
                       "Only the two authoritative queue refreshes may scan the source")
        XCTAssertEqual(state.withLock { $0.processedSourceBytes }, [originalBytes, replacementBytes])
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)

        let replacement = MusicItem(url: sourceURL, duration: 0.02)
        playbackManager.play(replacement)
        let derivativeURL = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset).url.standardizedFileURL
        XCTAssertNotEqual(derivativeURL, sourceURL.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: derivativeURL), replacementBytes,
                       "The published derivative must belong to the replacement source identity")
        playbackManager.pause()
    }

    @MainActor
    func testCancelledStaleValidationStopsAfterFirstSourceAndOnlyReplacementGenerationPublishes() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let staleValidationGate = DispatchSemaphore(value: 0)
        let replacementProcessorGate = DispatchSemaphore(value: 0)
        let state = LockedTestState((
            events: [String](),
            validatedAURLs: [URL](),
            replacementProcessorCount: 0,
            staleValidationWasReleased: false,
            replacementProcessorWasReleased: false
        ))
        defer {
            let releases = state.withLock {
                let releases = (!$0.staleValidationWasReleased, !$0.replacementProcessorWasReleased)
                $0.staleValidationWasReleased = true
                $0.replacementProcessorWasReleased = true
                return releases
            }
            if releases.0 { staleValidationGate.signal() }
            if releases.1 { replacementProcessorGate.signal() }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let generationAURLs = try (0..<3).map { index in
            let url = temporaryDirectory.appendingPathComponent("generation-a-\(index).wav")
            try writeSineWave(to: url, amplitude: pow(10, (-30.0 + Double(index)) / 20.0), duration: 0.01)
            return url.standardizedFileURL
        }
        let generationASet = Set(generationAURLs)
        let generationBURL = temporaryDirectory.appendingPathComponent("generation-b.wav").standardizedFileURL
        try writeSineWave(to: generationBURL, amplitude: pow(10, -12.0 / 20.0), duration: 0.01)
        let replacementBytes = try Data(contentsOf: generationBURL)
        let settings = try XCTUnwrap(MusicLoudnessNormalizationSettings(
            targetIntegratedLevelDBFS: -16,
            truePeakCeilingDBTP: -1.5,
            maximumBoostDB: 12,
            algorithmVersion: 1
        ))
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: temporaryDirectory.appendingPathComponent("cache", isDirectory: true),
            settings: settings,
            processor: { processingSourceURL, destinationURL, _ in
                let bytes = try Data(contentsOf: processingSourceURL)
                state.withLock {
                    $0.replacementProcessorCount += 1
                    $0.events.append("B processor")
                }
                replacementProcessorGate.wait()
                try bytes.write(to: destinationURL)
                return MusicLoudnessProcessingResult(
                    measuredIntegratedLevelDBFS: -12,
                    measuredTruePeakDBTP: -12,
                    outputIntegratedLevelDBFS: -16,
                    outputTruePeakDBTP: -16,
                    appliedGainDB: -4
                )
            }
        )
        let playbackManager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: defaults,
            loudnessCoordinator: coordinator,
            loudnessInstrumentation: MusicLoudnessSchedulingInstrumentation(
                didValidateSource: { sourceURL in
                    let standardizedURL = sourceURL.standardizedFileURL
                    if generationASet.contains(standardizedURL) {
                        let isFirst = state.withLock {
                            $0.validatedAURLs.append(standardizedURL)
                            $0.events.append("A validate")
                            return $0.validatedAURLs.count == 1
                        }
                        if isFirst { staleValidationGate.wait() }
                    } else if standardizedURL == generationBURL {
                        state.withLock { $0.events.append("B validate") }
                    }
                }
            ),
            activateAudioSession: {}
        )
        var publishedProgress: [MusicLoudnessLibraryProgress] = []
        let progressObservation = playbackManager.$loudnessLibraryProgress
            .dropFirst()
            .sink { publishedProgress.append($0) }

        playbackManager.updateQueue(generationAURLs.map { MusicItem(url: $0, duration: 0.01) })
        for _ in 0..<10_000 where state.withLock({ $0.validatedAURLs.isEmpty }) {
            await Task.yield()
        }
        XCTAssertEqual(state.withLock { $0.validatedAURLs.count }, 1)

        playbackManager.updateQueue([MusicItem(url: generationBURL, duration: 0.01)])
        for _ in 0..<10_000 where state.withLock({ $0.replacementProcessorCount < 1 }) {
            await Task.yield()
        }
        XCTAssertEqual(state.withLock { $0.replacementProcessorCount }, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)
        XCTAssertTrue(playbackManager.isNormalizingLoudnessLibrary)

        state.withLock { $0.staleValidationWasReleased = true }
        staleValidationGate.signal()
        for _ in 0..<10_000 { await Task.yield() }
        XCTAssertEqual(state.withLock { $0.validatedAURLs.count }, 1,
                       "A cancelled validation must stop before touching another stale source")
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)
        XCTAssertTrue(playbackManager.isNormalizingLoudnessLibrary)

        state.withLock { $0.replacementProcessorWasReleased = true }
        replacementProcessorGate.signal()
        for _ in 0..<20_000
        where playbackManager.isNormalizingLoudnessLibrary
            || playbackManager.loudnessNormalizationCompletedCount != 1 {
            await Task.yield()
        }
        withExtendedLifetime(progressObservation) {}

        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)
        XCTAssertFalse(publishedProgress.contains { $0.totalCount == generationAURLs.count },
                       "Generation A must never publish stale progress or state")
        XCTAssertFalse(publishedProgress.contains { $0.completedCount > 1 || $0.totalCount > 1 })
        XCTAssertEqual(state.withLock { $0.events.filter { $0 == "B validate" }.count }, 1)
        XCTAssertEqual(state.withLock { $0.events.filter { $0 == "B processor" }.count }, 1)
        XCTAssertEqual(state.withLock { $0.events }, ["A validate", "B validate", "B processor"],
                       "Only generation B may advance from validation into normalization")
        XCTAssertEqual(try Data(contentsOf: generationBURL), replacementBytes)
    }

    @MainActor
    func testQueueRefreshNormalizesEntireLibrarySeriallyWithoutBlockingOrPlaying() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let firstProcessorEntry = DispatchSemaphore(value: 0)
        let firstProcessorGate = DispatchSemaphore(value: 0)
        let processorStateLock = NSLock()
        var processorInvocationCount = 0
        var activeProcessorCount = 0
        var maximumActiveProcessorCount = 0
        var firstProcessorReleased = false
        let activationCountLock = NSLock()
        var activationCount = 0
        defer {
            let needsRelease = processorStateLock.withLock {
                let needsRelease = !firstProcessorReleased
                firstProcessorReleased = true
                return needsRelease
            }
            if needsRelease {
                firstProcessorGate.signal()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceAURL = temporaryDirectory.appendingPathComponent("library-A.wav")
        let sourceBURL = temporaryDirectory.appendingPathComponent("library-B.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceAURL, amplitude: pow(10, -30.0 / 20.0))
        try writeSineWave(to: sourceBURL, amplitude: pow(10, -24.0 / 20.0))
        let originalAData = try Data(contentsOf: sourceAURL)
        let originalBData = try Data(contentsOf: sourceBURL)
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, _ in
                let invocation = processorStateLock.withLock {
                    processorInvocationCount += 1
                    activeProcessorCount += 1
                    maximumActiveProcessorCount = max(
                        maximumActiveProcessorCount,
                        activeProcessorCount
                    )
                    return processorInvocationCount
                }
                defer {
                    processorStateLock.withLock {
                        activeProcessorCount -= 1
                    }
                }
                if invocation == 1 {
                    firstProcessorEntry.signal()
                    firstProcessorGate.wait()
                }
                try FileManager.default.copyItem(
                    at: processingSourceURL,
                    to: destinationURL
                )
                return MusicLoudnessProcessingResult(
                    measuredIntegratedLevelDBFS: -30,
                    measuredTruePeakDBTP: -30,
                    outputIntegratedLevelDBFS: -16,
                    outputTruePeakDBTP: -16,
                    appliedGainDB: 12
                )
            }
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {
                activationCountLock.withLock {
                    activationCount += 1
                }
            }
        )
        let itemA = MusicItem(url: sourceAURL, duration: 1)
        let itemB = MusicItem(url: sourceBURL, duration: 1)
        var updateQueueReturned = false

        playbackManager.updateQueue([itemA, itemB])
        updateQueueReturned = true

        let firstEntryDeadline = Date().addingTimeInterval(10)
        while processorStateLock.withLock({ processorInvocationCount == 0 }),
              Date() < firstEntryDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(
            firstProcessorEntry.wait(timeout: .now()),
            .success,
            "Timed out waiting for the first library normalization processor entry"
        )
        XCTAssertTrue(updateQueueReturned, "Queue refresh must return while normalization is blocked")
        XCTAssertEqual(processorStateLock.withLock { processorInvocationCount }, 1)
        XCTAssertEqual(processorStateLock.withLock { activeProcessorCount }, 1)
        XCTAssertTrue(playbackManager.isNormalizingLoudnessLibrary)
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 0)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 2)
        XCTAssertFalse(playbackManager.isPlaying)
        XCTAssertNil(playbackManager.currentTrack)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 0)

        processorStateLock.withLock {
            firstProcessorReleased = true
        }
        firstProcessorGate.signal()

        let completionDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < completionDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(
            playbackManager.isNormalizingLoudnessLibrary,
            "Timed out waiting for whole-library loudness normalization"
        )
        XCTAssertEqual(processorStateLock.withLock { processorInvocationCount }, 2)
        XCTAssertEqual(processorStateLock.withLock { maximumActiveProcessorCount }, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 2)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 2)
        XCTAssertFalse(playbackManager.isPlaying)
        XCTAssertNil(playbackManager.currentTrack)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceAURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceBURL.path))
        XCTAssertEqual(try Data(contentsOf: sourceAURL), originalAData)
        XCTAssertEqual(try Data(contentsOf: sourceBURL), originalBData)
    }

    @MainActor
    func testPlaylistQueueNeverNarrowsWholeLibraryLoudnessBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "PlaylistLoudness.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var invocations: [String] = []
        var released = false
        defer {
            let signal = lock.withLock { let needed = !released; released = true; return needed }
            if signal { gate.signal() }
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let urls = ["A.wav", "B.wav", "C.wav"].map { directory.appendingPathComponent($0) }
        for (index, url) in urls.enumerated() {
            try writeSineWave(to: url, amplitude: pow(10, Double(-30 + index) / 20.0))
        }
        let labelsByBytes = Dictionary(uniqueKeysWithValues: try urls.map { url in
            (try Data(contentsOf: url), url.lastPathComponent)
        })
        let settings = try XCTUnwrap(MusicLoudnessNormalizationSettings(targetIntegratedLevelDBFS: -16, truePeakCeilingDBTP: -1.5, maximumBoostDB: 12, algorithmVersion: 1))
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: directory.appendingPathComponent("cache", isDirectory: true),
            settings: settings,
            processor: { source, destination, _ in
                let sourceBytes = try Data(contentsOf: source)
                let label = try XCTUnwrap(labelsByBytes[sourceBytes])
                let first = lock.withLock { invocations.append(label); return invocations.count == 1 }
                if first { gate.wait() }
                try FileManager.default.copyItem(at: source, to: destination)
                return MusicLoudnessProcessingResult(measuredIntegratedLevelDBFS: -30, measuredTruePeakDBTP: -30, outputIntegratedLevelDBFS: -18, outputTruePeakDBTP: -18, appliedGainDB: 12)
            }
        )
        let manager = MusicPlaybackManager(defaults: defaults, loudnessCoordinator: coordinator, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController())
        let items = urls.map { MusicItem(url: $0, duration: 30) }
        manager.updateQueue(items)
        for _ in 0..<20_000 where lock.withLock({ invocations.isEmpty }) { await Task.yield() }
        XCTAssertEqual(lock.withLock { invocations.count }, 1)
        XCTAssertEqual(manager.loudnessNormalizationTotalCount, 3)

        let playlistID = UUID()
        manager.playFromPlaylist(items[0], playlistID: playlistID, items: [items[0]])
        manager.reconcilePlaylistQueue(id: playlistID, items: [items[0]])
        XCTAssertEqual(manager.queue, [items[0]])
        XCTAssertEqual(manager.loudnessNormalizationTotalCount, 3)
        lock.withLock { released = true }; gate.signal()
        for _ in 0..<40_000 where manager.isNormalizingLoudnessLibrary { await Task.yield() }
        XCTAssertEqual(lock.withLock { invocations.sorted() }, ["A.wav", "B.wav", "C.wav"])
        XCTAssertEqual(manager.loudnessNormalizationCompletedCount, 3)
        XCTAssertEqual(manager.loudnessNormalizationTotalCount, 3)
    }

    @MainActor
    func testNextStartsOriginalImmediatelyWhileLibraryNormalizationContinues() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let firstProcessorGate = DispatchSemaphore(value: 0)
        let processorStateLock = NSLock()
        var processorInvocationCount = 0
        var firstProcessorReleased = false
        let activationCountLock = NSLock()
        var activationCount = 0
        defer {
            let needsRelease = processorStateLock.withLock {
                let needsRelease = !firstProcessorReleased
                firstProcessorReleased = true
                return needsRelease
            }
            if needsRelease {
                firstProcessorGate.signal()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceAURL = temporaryDirectory.appendingPathComponent("next-A.wav")
        let sourceBURL = temporaryDirectory.appendingPathComponent("next-B.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceAURL, amplitude: pow(10, -30.0 / 20.0))
        try writeSineWave(to: sourceBURL, amplitude: pow(10, -24.0 / 20.0))
        let originalAData = try Data(contentsOf: sourceAURL)
        let originalBData = try Data(contentsOf: sourceBURL)
        _ = try AVAudioFile(forReading: sourceAURL)
        _ = try AVAudioFile(forReading: sourceBURL)
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, _ in
                let invocation = processorStateLock.withLock {
                    processorInvocationCount += 1
                    return processorInvocationCount
                }
                if invocation == 1 {
                    firstProcessorGate.wait()
                }
                try FileManager.default.copyItem(
                    at: processingSourceURL,
                    to: destinationURL
                )
                return MusicLoudnessProcessingResult(
                    measuredIntegratedLevelDBFS: -30,
                    measuredTruePeakDBTP: -30,
                    outputIntegratedLevelDBFS: -16,
                    outputTruePeakDBTP: -16,
                    appliedGainDB: 12
                )
            }
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {
                activationCountLock.withLock {
                    activationCount += 1
                }
            }
        )
        let itemA = MusicItem(url: sourceAURL, duration: 1)
        let itemB = MusicItem(url: sourceBURL, duration: 1)

        playbackManager.updateQueue([itemA, itemB])

        let processorStartDeadline = Date().addingTimeInterval(10)
        while processorStateLock.withLock({ processorInvocationCount == 0 }),
              Date() < processorStartDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(
            processorStateLock.withLock { processorInvocationCount },
            1,
            "Timed out waiting for background library normalization to block"
        )
        XCTAssertTrue(playbackManager.isNormalizingLoudnessLibrary)

        playbackManager.play(itemA)

        XCTAssertEqual(playbackManager.currentTrack, itemA)
        XCTAssertEqual(playbackManager.currentIndex, 0)
        XCTAssertTrue(playbackManager.isPlaying)
        let itemAAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(itemAAsset.url.standardizedFileURL, sourceAURL.standardizedFileURL)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 1)

        playbackManager.next()
        await Task.yield()

        XCTAssertEqual(playbackManager.currentTrack, itemB)
        XCTAssertEqual(playbackManager.currentIndex, 1)
        XCTAssertTrue(playbackManager.isPlaying)
        let itemBAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(itemBAsset.url.standardizedFileURL, sourceBURL.standardizedFileURL)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 2)
        XCTAssertTrue(playbackManager.isNormalizingLoudnessLibrary)
        XCTAssertEqual(processorStateLock.withLock { processorInvocationCount }, 1)

        processorStateLock.withLock {
            firstProcessorReleased = true
        }
        firstProcessorGate.signal()

        let normalizationDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < normalizationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(
            playbackManager.isNormalizingLoudnessLibrary,
            "Timed out waiting for background library normalization to finish"
        )
        XCTAssertEqual(playbackManager.currentTrack, itemB)
        XCTAssertEqual(playbackManager.currentIndex, 1)
        XCTAssertTrue(playbackManager.isPlaying)
        let finalAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(
            finalAsset.url.standardizedFileURL,
            sourceBURL.standardizedFileURL,
            "Finishing background normalization must not replace the current item mid-song"
        )
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 2)
        XCTAssertEqual(try Data(contentsOf: sourceAURL), originalAData)
        XCTAssertEqual(try Data(contentsOf: sourceBURL), originalBData)
    }

    @MainActor
    func testRemoteNextStartsOriginalImmediatelyWhileLibraryNormalizationContinues() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let firstProcessorGate = DispatchSemaphore(value: 0)
        let processorStateLock = NSLock()
        var processorInvocationCount = 0
        var firstProcessorReleased = false
        let activationCountLock = NSLock()
        var activationCount = 0
        defer {
            let needsRelease = processorStateLock.withLock {
                let needsRelease = !firstProcessorReleased
                firstProcessorReleased = true
                return needsRelease
            }
            if needsRelease {
                firstProcessorGate.signal()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceAURL = temporaryDirectory.appendingPathComponent("remote-next-A.wav")
        let sourceBURL = temporaryDirectory.appendingPathComponent("remote-next-B.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceAURL, amplitude: pow(10, -30.0 / 20.0))
        try writeSineWave(to: sourceBURL, amplitude: pow(10, -24.0 / 20.0))
        let originalAData = try Data(contentsOf: sourceAURL)
        let originalBData = try Data(contentsOf: sourceBURL)
        _ = try AVAudioFile(forReading: sourceAURL)
        _ = try AVAudioFile(forReading: sourceBURL)
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, _ in
                let invocation = processorStateLock.withLock {
                    processorInvocationCount += 1
                    return processorInvocationCount
                }
                if invocation == 1 {
                    firstProcessorGate.wait()
                }
                try FileManager.default.copyItem(
                    at: processingSourceURL,
                    to: destinationURL
                )
                return MusicLoudnessProcessingResult(
                    measuredIntegratedLevelDBFS: -30,
                    measuredTruePeakDBTP: -30,
                    outputIntegratedLevelDBFS: -16,
                    outputTruePeakDBTP: -16,
                    appliedGainDB: 12
                )
            }
        )
        let player = AVPlayer()
        let controller = RemoteLoudnessNowPlayingControllerSpy()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {
                activationCountLock.withLock {
                    activationCount += 1
                }
            },
            nowPlayingController: controller
        )
        let itemA = MusicItem(url: sourceAURL, duration: 1)
        let itemB = MusicItem(url: sourceBURL, duration: 1)

        playbackManager.updateQueue([itemA, itemB])

        let processorStartDeadline = Date().addingTimeInterval(10)
        while processorStateLock.withLock({ processorInvocationCount == 0 }),
              Date() < processorStartDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(
            processorStateLock.withLock { processorInvocationCount },
            1,
            "Timed out waiting for background library normalization to block"
        )
        XCTAssertTrue(playbackManager.isNormalizingLoudnessLibrary)

        playbackManager.play(itemA)

        XCTAssertEqual(playbackManager.currentTrack, itemA)
        XCTAssertEqual(playbackManager.currentIndex, 0)
        XCTAssertTrue(playbackManager.isPlaying)
        let itemAAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(itemAAsset.url.standardizedFileURL, sourceAURL.standardizedFileURL)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 1)

        let commandResult = controller.send(.nextTrack)
        await Task.yield()

        XCTAssertEqual(commandResult, .success)
        XCTAssertEqual(playbackManager.currentTrack, itemB)
        XCTAssertEqual(playbackManager.currentIndex, 1)
        XCTAssertTrue(playbackManager.isPlaying)
        let itemBAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(itemBAsset.url.standardizedFileURL, sourceBURL.standardizedFileURL)
        XCTAssertTrue(playbackManager.isNormalizingLoudnessLibrary)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 2)
        XCTAssertEqual(processorStateLock.withLock { processorInvocationCount }, 1)

        processorStateLock.withLock {
            firstProcessorReleased = true
        }
        firstProcessorGate.signal()

        let normalizationDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < normalizationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(
            playbackManager.isNormalizingLoudnessLibrary,
            "Timed out waiting for background library normalization to finish"
        )
        XCTAssertEqual(processorStateLock.withLock { processorInvocationCount }, 2)
        XCTAssertEqual(playbackManager.currentTrack, itemB)
        XCTAssertEqual(playbackManager.currentIndex, 1)
        XCTAssertTrue(playbackManager.isPlaying)
        let finalAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(
            finalAsset.url.standardizedFileURL,
            sourceBURL.standardizedFileURL,
            "Finishing background normalization must not replace the current item mid-song"
        )
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 2)
        XCTAssertEqual(try Data(contentsOf: sourceAURL), originalAData)
        XCTAssertEqual(try Data(contentsOf: sourceBURL), originalBData)
    }

    @MainActor
    func testMusicTapStartsOriginalImmediatelyWhileLoudnessNormalizesInBackground() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        let processorGate = DispatchSemaphore(value: 0)
        let processorStateLock = NSLock()
        var processorStarted = false
        var processorFinished = false
        var processorReleased = false
        let activationCountLock = NSLock()
        var activationCount = 0
        defer {
            let needsRelease = processorStateLock.withLock {
                let needsRelease = !processorReleased
                processorReleased = true
                return needsRelease
            }
            if needsRelease {
                processorGate.signal()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, processingSettings in
                processorStateLock.withLock {
                    processorStarted = true
                }
                processorGate.wait()
                defer {
                    processorStateLock.withLock {
                        processorFinished = true
                    }
                }
                return try MusicLoudnessOfflineProcessor.process(
                    sourceURL: processingSourceURL,
                    destinationURL: destinationURL,
                    settings: processingSettings
                )
            }
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {
                activationCountLock.withLock {
                    activationCount += 1
                }
            }
        )
        let song = MusicItem(url: sourceURL, duration: 1)
        playbackManager.updateQueue([song])

        playbackManager.play(song)

        let processorStartDeadline = Date().addingTimeInterval(10)
        while !processorStateLock.withLock({ processorStarted }),
              Date() < processorStartDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(
            processorStateLock.withLock { processorStarted },
            "Timed out waiting for the loudness processor to enter its blocked gate"
        )
        await Task.yield()
        XCTAssertFalse(processorStateLock.withLock { processorReleased })

        XCTAssertTrue(playbackManager.isPlaying)
        XCTAssertEqual(playbackManager.currentTrack, song)
        XCTAssertEqual(
            playbackManager.currentTrack?.url.standardizedFileURL,
            sourceURL.standardizedFileURL
        )
        XCTAssertEqual(playbackManager.currentIndex, 0)
        XCTAssertNotNil(player.currentItem)
        let playbackAsset = player.currentItem?.asset as? AVURLAsset
        XCTAssertEqual(
            playbackAsset?.url.standardizedFileURL,
            sourceURL.standardizedFileURL
        )
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 1)

        processorStateLock.withLock {
            processorReleased = true
        }
        processorGate.signal()

        let processorFinishDeadline = Date().addingTimeInterval(10)
        while !processorStateLock.withLock({ processorFinished }),
              Date() < processorFinishDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(
            processorStateLock.withLock { processorFinished },
            "Timed out waiting for background loudness normalization to finish"
        )
        XCTAssertTrue(playbackManager.isPlaying)
        XCTAssertEqual(playbackManager.currentTrack, song)
        XCTAssertEqual(playbackManager.currentIndex, 0)
        let finalPlaybackAsset = player.currentItem?.asset as? AVURLAsset
        XCTAssertEqual(
            finalPlaybackAsset?.url.standardizedFileURL,
            sourceURL.standardizedFileURL,
            "Finishing background normalization must not replace the item mid-song"
        )
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 1)
    }

    @MainActor
    func testCompletedBackgroundLoudnessResultIsUsedOnNextFreshLoad() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {}
        )
        let song = MusicItem(url: sourceURL, duration: 1)
        playbackManager.updateQueue([song])

        let normalizationDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < normalizationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)
        XCTAssertFalse(playbackManager.isPlaying)
        XCTAssertNil(player.currentItem)

        playbackManager.play(song)

        XCTAssertTrue(playbackManager.isPlaying)
        XCTAssertEqual(playbackManager.currentTrack, song)
        XCTAssertEqual(playbackManager.currentTrack?.url, sourceURL)
        let playbackAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        let playbackURL = playbackAsset.url.standardizedFileURL
        let standardizedSourceURL = sourceURL.standardizedFileURL
        let standardizedCacheRootURL = cacheRootURL.standardizedFileURL
        XCTAssertTrue(FileManager.default.fileExists(atPath: playbackURL.path))
        XCTAssertNotEqual(playbackURL, standardizedSourceURL)
        XCTAssertTrue(
            playbackURL.path.hasPrefix(standardizedCacheRootURL.path + "/"),
            "Balanced derivative must be stored under the loudness cache root"
        )
        XCTAssertEqual(playbackURL.pathExtension.lowercased(), "m4a")
        XCTAssertGreaterThan(try measureAudioFile(at: playbackURL).frameCount, 0)

    }

    @MainActor
    func testRestoredTrackPlaysOriginalImmediatelyWhileBackgroundNormalizationContinues() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        let processorGate = DispatchSemaphore(value: 0)
        let processorStateLock = NSLock()
        var processorStarted = false
        var processorReleased = false
        let activationCountLock = NSLock()
        var activationCount = 0
        defer {
            let needsRelease = processorStateLock.withLock {
                let needsRelease = !processorReleased
                processorReleased = true
                return needsRelease
            }
            if needsRelease {
                processorGate.signal()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURL = temporaryDirectory.appendingPathComponent("restored.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        defaults.set("restored.wav", forKey: "MusicPlayback.lastTrackFileName")
        defaults.set(0.25, forKey: "MusicPlayback.lastPositionSeconds")

        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        var processorInvocationCount = 0
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, processingSettings in
                processorInvocationCount += 1
                processorStateLock.withLock {
                    processorStarted = true
                }
                processorGate.wait()
                return try MusicLoudnessOfflineProcessor.process(
                    sourceURL: processingSourceURL,
                    destinationURL: destinationURL,
                    settings: processingSettings
                )
            }
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {
                activationCountLock.withLock {
                    activationCount += 1
                }
            }
        )
        let track = MusicItem(url: sourceURL, duration: 1)

        playbackManager.updateQueue([track])

        let processorStartDeadline = Date().addingTimeInterval(10)
        while !processorStateLock.withLock({ processorStarted }),
              Date() < processorStartDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(processorStateLock.withLock { processorStarted })

        XCTAssertEqual(playbackManager.currentTrack, track)
        XCTAssertEqual(playbackManager.currentIndex, 0)
        XCTAssertFalse(playbackManager.isPlaying)
        XCTAssertNotEqual(player.timeControlStatus, .playing)
        let restoredAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(
            restoredAsset.url.standardizedFileURL,
            sourceURL.standardizedFileURL
        )

        playbackManager.play()
        XCTAssertTrue(playbackManager.isPlaying)
        let playbackAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        let playbackURL = playbackAsset.url.standardizedFileURL
        XCTAssertEqual(playbackURL, sourceURL.standardizedFileURL)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 1)

        processorStateLock.withLock {
            processorReleased = true
        }
        processorGate.signal()

        let normalizationDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < normalizationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)
        XCTAssertEqual(processorInvocationCount, 1)
        let finalAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(finalAsset.url.standardizedFileURL, sourceURL.standardizedFileURL)
        XCTAssertEqual(playbackManager.currentTrack, track)
        XCTAssertEqual(
            playbackManager.currentTrack?.url.standardizedFileURL,
            sourceURL.standardizedFileURL
        )
        XCTAssertTrue(playbackManager.isPlaying)
    }

    @MainActor
    func testPauseDuringBackgroundNormalizationCannotRestartOrReplacePlayback() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        let processorGate = DispatchSemaphore(value: 0)
        let processorStateLock = NSLock()
        var processorStarted = false
        var processorReleased = false
        defer {
            let needsRelease = processorStateLock.withLock {
                let needsRelease = !processorReleased
                processorReleased = true
                return needsRelease
            }
            if needsRelease {
                processorGate.signal()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, processingSettings in
                processorStateLock.withLock {
                    processorStarted = true
                }
                processorGate.wait()

                return try MusicLoudnessOfflineProcessor.process(
                    sourceURL: processingSourceURL,
                    destinationURL: destinationURL,
                    settings: processingSettings
                )
            }
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {}
        )
        let song = MusicItem(url: sourceURL, duration: 1)
        playbackManager.updateQueue([song])

        playbackManager.play(song)

        let processorStartDeadline = Date().addingTimeInterval(10)
        while Date() < processorStartDeadline {
            let hasStarted = processorStateLock.withLock {
                processorStarted
            }
            if hasStarted {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let didStartProcessor = processorStateLock.withLock {
            processorStarted
        }
        XCTAssertTrue(didStartProcessor, "Timed out waiting for the loudness processor to start")
        XCTAssertEqual(playbackManager.currentTrack, song)

        playbackManager.pause()

        XCTAssertFalse(playbackManager.isPlaying)
        XCTAssertNotEqual(player.timeControlStatus, .playing)

        processorStateLock.withLock {
            processorReleased = true
        }
        processorGate.signal()

        let normalizationDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < normalizationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(playbackManager.isPlaying)
        XCTAssertNotEqual(player.timeControlStatus, .playing)
        let pausedAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(pausedAsset.url.standardizedFileURL, sourceURL.standardizedFileURL)
        XCTAssertEqual(playbackManager.currentTrack, song)
        XCTAssertEqual(playbackManager.currentTrack?.url.standardizedFileURL, sourceURL.standardizedFileURL)
    }

    @MainActor
    func testPauseThenPlayDuringBackgroundNormalizationResumesWithoutDuplicateProcessing() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        let firstProcessorGate = DispatchSemaphore(value: 0)
        let processorStateLock = NSLock()
        var processorInvocationCount = 0
        var firstProcessorStarted = false
        var firstProcessorFinished = false
        var firstProcessorReleased = false
        let activationCountLock = NSLock()
        var activationCount = 0
        defer {
            let needsRelease = processorStateLock.withLock {
                let needsRelease = !firstProcessorReleased
                firstProcessorReleased = true
                return needsRelease
            }
            if needsRelease {
                firstProcessorGate.signal()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, processingSettings in
                let invocation = processorStateLock.withLock {
                    processorInvocationCount += 1
                    if processorInvocationCount == 1 {
                        firstProcessorStarted = true
                    }
                    return processorInvocationCount
                }

                if invocation == 1 {
                    firstProcessorGate.wait()
                    processorStateLock.withLock {
                        firstProcessorFinished = true
                    }
                    return try MusicLoudnessOfflineProcessor.process(
                        sourceURL: processingSourceURL,
                        destinationURL: destinationURL,
                        settings: processingSettings
                    )
                }

                return try MusicLoudnessOfflineProcessor.process(
                    sourceURL: processingSourceURL,
                    destinationURL: destinationURL,
                    settings: processingSettings
                )
            }
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {
                activationCountLock.withLock {
                    activationCount += 1
                }
            }
        )
        let metadata = MusicMetadata(
            title: "Source Title",
            artist: "Source Artist",
            album: "Source Album",
            artworkData: nil,
            lyrics: "Source Lyrics",
            synchronizedLyricsData: nil
        )
        let song = MusicItem(url: sourceURL, duration: 1, metadata: metadata)
        playbackManager.updateQueue([song])

        playbackManager.play(song)

        let firstStartDeadline = Date().addingTimeInterval(10)
        while Date() < firstStartDeadline {
            let hasStarted = processorStateLock.withLock {
                firstProcessorStarted
            }
            if hasStarted {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(
            processorStateLock.withLock { firstProcessorStarted },
            "Timed out waiting for the first loudness processor invocation"
        )

        playbackManager.pause()
        let pausedAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(pausedAsset.url.standardizedFileURL, sourceURL.standardizedFileURL)
        XCTAssertFalse(playbackManager.isPlaying)
        XCTAssertNotEqual(player.timeControlStatus, .playing)

        processorStateLock.withLock {
            firstProcessorReleased = true
        }
        firstProcessorGate.signal()

        let completionDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < completionDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(processorStateLock.withLock { firstProcessorFinished })
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)

        playbackManager.play()

        let playbackDeadline = Date().addingTimeInterval(10)
        while (player.currentItem == nil
                || !playbackManager.isPlaying),
              Date() < playbackDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(playbackManager.isPlaying)
        XCTAssertEqual(processorStateLock.withLock { processorInvocationCount }, 1)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 2)
        XCTAssertEqual(playbackManager.currentTrack, song)
        XCTAssertEqual(playbackManager.currentTrack?.metadata, metadata)
        XCTAssertEqual(
            playbackManager.currentTrack?.url.standardizedFileURL,
            sourceURL.standardizedFileURL
        )

        let playbackAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        let playbackURL = playbackAsset.url.standardizedFileURL
        XCTAssertEqual(playbackURL, sourceURL.standardizedFileURL)
    }

    @MainActor
    func testQueueReorderDuringBackgroundNormalizationKeepsActiveOriginalCoherent() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        let processorGate = DispatchSemaphore(value: 0)
        let processorStateLock = NSLock()
        var processorStarted = false
        var processorInvocationCount = 0
        var processorReleased = false
        let activationCountLock = NSLock()
        var activationCount = 0
        defer {
            let needsRelease = processorStateLock.withLock {
                let needsRelease = !processorReleased
                processorReleased = true
                return needsRelease
            }
            if needsRelease {
                processorGate.signal()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceAURL = temporaryDirectory.appendingPathComponent("Queue Reorder A.wav")
        let sourceBURL = temporaryDirectory.appendingPathComponent("Queue Reorder B.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceAURL, amplitude: pow(10, -24.0 / 20.0))
        try writeSineWave(to: sourceBURL, amplitude: pow(10, -30.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, processingSettings in
                processorStateLock.withLock {
                    processorInvocationCount += 1
                    processorStarted = true
                }
                processorGate.wait()

                return try MusicLoudnessOfflineProcessor.process(
                    sourceURL: processingSourceURL,
                    destinationURL: destinationURL,
                    settings: processingSettings
                )
            }
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {
                activationCountLock.withLock {
                    activationCount += 1
                }
            }
        )
        let itemA = MusicItem(
            url: sourceAURL,
            duration: 1,
            metadata: MusicMetadata(
                title: "Queue Reorder Track A",
                artist: "DrivePlayer Test Artist A",
                album: "DrivePlayer Test Album A",
                artworkData: nil,
                lyrics: nil,
                synchronizedLyricsData: nil
            )
        )
        let itemB = MusicItem(
            url: sourceBURL,
            duration: 1,
            metadata: MusicMetadata(
                title: "Queue Reorder Track B",
                artist: "DrivePlayer Test Artist B",
                album: "DrivePlayer Test Album B",
                artworkData: nil,
                lyrics: nil,
                synchronizedLyricsData: nil
            )
        )
        playbackManager.updateQueue([itemA, itemB])

        playbackManager.play(itemB)
        XCTAssertEqual(
            playbackManager.currentTrack?.url.standardizedFileURL,
            sourceBURL.standardizedFileURL
        )
        XCTAssertEqual(playbackManager.currentIndex, 1)
        XCTAssertTrue(playbackManager.isPlaying)
        let initialAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(initialAsset.url.standardizedFileURL, sourceBURL.standardizedFileURL)

        let processorStartDeadline = Date().addingTimeInterval(10)
        while Date() < processorStartDeadline {
            let hasStarted = processorStateLock.withLock {
                processorStarted
            }
            if hasStarted {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(
            processorStateLock.withLock { processorStarted },
            "Timed out waiting for the loudness processor to start"
        )

        playbackManager.updateQueue([itemB, itemA])

        XCTAssertEqual(
            playbackManager.currentTrack?.url.standardizedFileURL,
            sourceBURL.standardizedFileURL
        )
        XCTAssertEqual(playbackManager.currentIndex, 0)
        let reorderedAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(reorderedAsset.url.standardizedFileURL, sourceBURL.standardizedFileURL)

        processorStateLock.withLock {
            processorReleased = true
        }
        processorGate.signal()

        let playbackDeadline = Date().addingTimeInterval(10)
        while (player.currentItem == nil
                || !playbackManager.isPlaying),
              Date() < playbackDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(playbackManager.isPlaying)
        XCTAssertEqual(
            playbackManager.currentTrack?.url.standardizedFileURL,
            sourceBURL.standardizedFileURL
        )
        XCTAssertEqual(playbackManager.currentIndex, 0)
        let playbackAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        let playbackURL = playbackAsset.url.standardizedFileURL
        XCTAssertEqual(playbackURL, sourceBURL.standardizedFileURL)
        XCTAssertEqual(
            processorStateLock.withLock { processorInvocationCount },
            1
        )
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 1)
    }

    @MainActor
    func testSameFileNameReplacementIgnoresOldBackgroundCompletionAndNormalizesReplacement() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sourceDirectory = temporaryDirectory.appendingPathComponent("source", isDirectory: true)
        let replacementDirectory = temporaryDirectory.appendingPathComponent(
            "replacement",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: replacementDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        let processorGate = DispatchSemaphore(value: 0)
        let processorStateLock = NSLock()
        var processorStarted = false
        var processorCompleted = false
        var processorInvocationCount = 0
        var processorReleased = false
        let activationCountLock = NSLock()
        var activationCount = 0
        defer {
            let needsRelease = processorStateLock.withLock {
                let needsRelease = !processorReleased
                processorReleased = true
                return needsRelease
            }
            if needsRelease {
                processorGate.signal()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURL = sourceDirectory.appendingPathComponent("same.wav")
        let replacementURL = replacementDirectory.appendingPathComponent("same.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        try writeSineWave(to: replacementURL, amplitude: pow(10, -12.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, processingSettings in
                let invocation = processorStateLock.withLock {
                    processorInvocationCount += 1
                    processorStarted = true
                    return processorInvocationCount
                }
                if invocation == 1 {
                    processorGate.wait()
                }

                let result = try MusicLoudnessOfflineProcessor.process(
                    sourceURL: processingSourceURL,
                    destinationURL: destinationURL,
                    settings: processingSettings
                )
                processorStateLock.withLock {
                    processorCompleted = true
                }
                return result
            }
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {
                activationCountLock.withLock {
                    activationCount += 1
                }
            }
        )
        let original = MusicItem(url: sourceURL, duration: 1)
        let replacement = MusicItem(url: replacementURL, duration: 1)
        playbackManager.updateQueue([original])

        playbackManager.play(original)

        let processorStartDeadline = Date().addingTimeInterval(10)
        while Date() < processorStartDeadline {
            let hasStarted = processorStateLock.withLock {
                processorStarted
            }
            if hasStarted {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let didStartProcessor = processorStateLock.withLock {
            processorStarted
        }
        XCTAssertTrue(didStartProcessor, "Timed out waiting for the loudness processor to start")
        let originalAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(originalAsset.url.standardizedFileURL, sourceURL.standardizedFileURL)
        XCTAssertTrue(playbackManager.isPlaying)

        playbackManager.updateQueue([replacement])
        XCTAssertEqual(
            playbackManager.currentTrack?.url.standardizedFileURL,
            replacementURL.standardizedFileURL
        )
        XCTAssertEqual(playbackManager.currentIndex, 0)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(playbackManager.isPlaying)

        processorStateLock.withLock {
            processorReleased = true
        }
        processorGate.signal()

        let normalizationDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < normalizationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(processorStateLock.withLock { processorCompleted })
        XCTAssertEqual(processorStateLock.withLock { processorInvocationCount }, 2)
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)
        await Task.yield()
        XCTAssertEqual(
            playbackManager.currentTrack?.url.standardizedFileURL,
            replacementURL.standardizedFileURL
        )
        XCTAssertEqual(playbackManager.currentIndex, 0)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(playbackManager.isPlaying)
        let finalActivationCount = activationCountLock.withLock {
            activationCount
        }
        XCTAssertEqual(finalActivationCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementURL.path))
    }

    @MainActor
    func testUpdateQueueWithSameFileNameDifferentURLStopsLoadedOriginalAndFailsClosedPaused() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let originalDirectory = temporaryDirectory.appendingPathComponent(
            "original",
            isDirectory: true
        )
        let replacementDirectory = temporaryDirectory.appendingPathComponent(
            "replacement",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: originalDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: replacementDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let originalURL = originalDirectory.appendingPathComponent("same.wav")
        let replacementURL = replacementDirectory.appendingPathComponent("same.wav")
        try writeSineWave(to: originalURL, amplitude: 0.1)
        try writeSineWave(to: replacementURL, amplitude: 0.2)

        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: nil,
            activateAudioSession: {}
        )
        let original = MusicItem(url: originalURL, duration: 1)
        let replacementDuration: TimeInterval = 0.75
        let replacement = MusicItem(url: replacementURL, duration: replacementDuration)

        playbackManager.updateQueue([original])
        playbackManager.play(original)

        let loadedOriginalAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(
            loadedOriginalAsset.url.standardizedFileURL,
            originalURL.standardizedFileURL
        )
        XCTAssertTrue(playbackManager.isPlaying)

        playbackManager.updateQueue([replacement])

        XCTAssertEqual(
            playbackManager.currentTrack?.url.standardizedFileURL,
            replacementURL.standardizedFileURL
        )
        XCTAssertEqual(playbackManager.currentIndex, 0)
        XCTAssertFalse(playbackManager.isPlaying)
        XCTAssertEqual(player.rate, 0)
        XCTAssertNotEqual(player.timeControlStatus, .playing)
        XCTAssertNil(player.currentItem, "The loaded original item must be explicitly cleared")
        XCTAssertEqual(playbackManager.currentTime, 0)
        XCTAssertEqual(playbackManager.duration, replacementDuration)
        XCTAssertEqual(defaults.string(forKey: "MusicPlayback.lastTrackFileName"), "same.wav")
        XCTAssertEqual(defaults.double(forKey: "MusicPlayback.lastPositionSeconds"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementURL.path))
    }

    @MainActor
    func testAudioInterruptionDuringBackgroundNormalizationResumesOnlyAfterShouldResume() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        let processorGate = DispatchSemaphore(value: 0)
        let processorStateLock = NSLock()
        var processorStarted = false
        var processorReleased = false
        let activationCountLock = NSLock()
        var activationCount = 0
        defer {
            let needsRelease = processorStateLock.withLock {
                let needsRelease = !processorReleased
                processorReleased = true
                return needsRelease
            }
            if needsRelease {
                processorGate.signal()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, processingSettings in
                processorStateLock.withLock {
                    processorStarted = true
                }
                processorGate.wait()

                return try MusicLoudnessOfflineProcessor.process(
                    sourceURL: processingSourceURL,
                    destinationURL: destinationURL,
                    settings: processingSettings
                )
            }
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {
                activationCountLock.withLock {
                    activationCount += 1
                }
            }
        )
        let song = MusicItem(url: sourceURL, duration: 1)
        playbackManager.updateQueue([song])

        playbackManager.play(song)

        let processorStartDeadline = Date().addingTimeInterval(10)
        while Date() < processorStartDeadline {
            let hasStarted = processorStateLock.withLock {
                processorStarted
            }
            if hasStarted {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let didStartProcessor = processorStateLock.withLock {
            processorStarted
        }
        XCTAssertTrue(didStartProcessor, "Timed out waiting for the loudness processor to start")
        let playingAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(playingAsset.url.standardizedFileURL, sourceURL.standardizedFileURL)
        XCTAssertTrue(playbackManager.isPlaying)

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue
            ]
        )
        await Task.yield()

        processorStateLock.withLock {
            processorReleased = true
        }
        processorGate.signal()

        let normalizationDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < normalizationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(playbackManager.isPlaying)
        XCTAssertNotEqual(player.timeControlStatus, .playing)
        let interruptedAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(interruptedAsset.url.standardizedFileURL, sourceURL.standardizedFileURL)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 1)

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey:
                    AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ]
        )
        await Task.yield()

        XCTAssertTrue(playbackManager.isPlaying)
        let resumedAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(resumedAsset.url.standardizedFileURL, sourceURL.standardizedFileURL)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 2)
        XCTAssertEqual(playbackManager.currentTrack, song)
        XCTAssertEqual(playbackManager.currentTrack?.url.standardizedFileURL, sourceURL.standardizedFileURL)
    }

    @MainActor
    func testOldDeviceUnavailableDuringBackgroundNormalizationCannotResumeOrReplacePlayback() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        let processorGate = DispatchSemaphore(value: 0)
        let processorStateLock = NSLock()
        var processorStarted = false
        var processorReleased = false
        let activationCountLock = NSLock()
        var activationCount = 0
        defer {
            let needsRelease = processorStateLock.withLock {
                let needsRelease = !processorReleased
                processorReleased = true
                return needsRelease
            }
            if needsRelease {
                processorGate.signal()
            }
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, processingSettings in
                processorStateLock.withLock {
                    processorStarted = true
                }
                processorGate.wait()

                return try MusicLoudnessOfflineProcessor.process(
                    sourceURL: processingSourceURL,
                    destinationURL: destinationURL,
                    settings: processingSettings
                )
            }
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {
                activationCountLock.withLock {
                    activationCount += 1
                }
            }
        )
        let song = MusicItem(url: sourceURL, duration: 1)
        playbackManager.updateQueue([song])

        playbackManager.play(song)

        let processorStartDeadline = Date().addingTimeInterval(10)
        while Date() < processorStartDeadline {
            let hasStarted = processorStateLock.withLock {
                processorStarted
            }
            if hasStarted {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let didStartProcessor = processorStateLock.withLock {
            processorStarted
        }
        XCTAssertTrue(didStartProcessor, "Timed out waiting for the loudness processor to start")
        let playingAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(playingAsset.url.standardizedFileURL, sourceURL.standardizedFileURL)
        XCTAssertTrue(playbackManager.isPlaying)

        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            ]
        )
        await Task.yield()

        processorStateLock.withLock {
            processorReleased = true
        }
        processorGate.signal()

        let normalizationDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < normalizationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(playbackManager.isPlaying)
        XCTAssertNotEqual(player.timeControlStatus, .playing)
        let routedAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(routedAsset.url.standardizedFileURL, sourceURL.standardizedFileURL)
        let finalActivationCount = activationCountLock.withLock {
            activationCount
        }
        XCTAssertEqual(finalActivationCount, 1)
        XCTAssertEqual(playbackManager.currentTrack, song)
        XCTAssertEqual(playbackManager.currentTrack?.url.standardizedFileURL, sourceURL.standardizedFileURL)
    }

    @MainActor
    func testNextImmediatelyLoadsOriginalWithoutMidSongNormalizationSwap() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let firstSourceURL = temporaryDirectory.appendingPathComponent("first.wav")
        let secondSourceURL = temporaryDirectory.appendingPathComponent("second.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: firstSourceURL, amplitude: pow(10, -30.0 / 20.0))
        try writeSineWave(to: secondSourceURL, amplitude: pow(10, -24.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {}
        )
        let first = MusicItem(url: firstSourceURL, duration: 1)
        let second = MusicItem(url: secondSourceURL, duration: 1)
        playbackManager.updateQueue([first, second])

        playbackManager.play(first)

        playbackManager.next()

        XCTAssertEqual(playbackManager.currentTrack, second)
        XCTAssertTrue(playbackManager.isPlaying)
        let immediateAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(immediateAsset.url.standardizedFileURL, secondSourceURL.standardizedFileURL)

        let normalizationDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < normalizationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(playbackManager.currentTrack, second)
        XCTAssertTrue(playbackManager.isPlaying)
        let playbackAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        let playbackURL = playbackAsset.url.standardizedFileURL
        let standardizedSecondSourceURL = secondSourceURL.standardizedFileURL
        XCTAssertEqual(playbackURL, standardizedSecondSourceURL)
    }

    @MainActor
    func testPreviousImmediatelyUsesCompletedNormalizedCacheWithoutMidSongSwap() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let firstSourceURL = temporaryDirectory.appendingPathComponent("first.wav")
        let secondSourceURL = temporaryDirectory.appendingPathComponent("second.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: firstSourceURL, amplitude: pow(10, -30.0 / 20.0))
        try writeSineWave(to: secondSourceURL, amplitude: pow(10, -24.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {}
        )
        let first = MusicItem(url: firstSourceURL, duration: 1)
        let second = MusicItem(url: secondSourceURL, duration: 1)
        playbackManager.updateQueue([first, second])

        playbackManager.play(second)
        playbackManager.pause()

        let secondNormalizationDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < secondNormalizationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(playbackManager.currentTrack, second)

        playbackManager.previous()

        XCTAssertEqual(playbackManager.currentTrack, first)
        XCTAssertTrue(playbackManager.isPlaying)
        let immediateAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        let immediateURL = immediateAsset.url.standardizedFileURL
        let standardizedFirstSourceURL = firstSourceURL.standardizedFileURL
        let standardizedCacheRootURL = cacheRootURL.standardizedFileURL
        XCTAssertNotEqual(immediateURL, standardizedFirstSourceURL)
        XCTAssertTrue(immediateURL.path.hasPrefix(standardizedCacheRootURL.path + "/"))
        XCTAssertEqual(immediateURL.pathExtension.lowercased(), "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: immediateURL.path))

        let firstNormalizationDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < firstNormalizationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(playbackManager.currentTrack, first)
        XCTAssertTrue(playbackManager.isPlaying)
        let playbackAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        let playbackURL = playbackAsset.url.standardizedFileURL
        XCTAssertNotEqual(playbackURL, standardizedFirstSourceURL)
        XCTAssertTrue(playbackURL.path.hasPrefix(standardizedCacheRootURL.path + "/"))
        XCTAssertEqual(playbackURL.pathExtension.lowercased(), "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: playbackURL.path))
        XCTAssertEqual(playbackURL, immediateURL)
    }

    @MainActor
    func testRemoteNextAndPreviousImmediatelyLoadOriginalsWithoutDuplicateActivation() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let firstSourceURL = temporaryDirectory.appendingPathComponent("first.wav")
        let secondSourceURL = temporaryDirectory.appendingPathComponent("second.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: firstSourceURL, amplitude: pow(10, -30.0 / 20.0))
        try writeSineWave(to: secondSourceURL, amplitude: pow(10, -24.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings
        )
        let player = AVPlayer()
        let controller = RemoteLoudnessNowPlayingControllerSpy()
        let activationCountLock = NSLock()
        var activationCount = 0
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {
                activationCountLock.withLock {
                    activationCount += 1
                }
            },
            nowPlayingController: controller
        )
        let first = MusicItem(url: firstSourceURL, duration: 1)
        let second = MusicItem(url: secondSourceURL, duration: 1)
        playbackManager.updateQueue([first, second])
        playbackManager.play(first)

        let firstPlaybackDeadline = Date().addingTimeInterval(10)
        while player.currentItem == nil,
              Date() < firstPlaybackDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(player.currentItem)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 1)

        XCTAssertEqual(controller.send(.nextTrack), .success)
        XCTAssertEqual(playbackManager.currentTrack, second)
        XCTAssertTrue(playbackManager.isPlaying)
        let immediateSecondAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(immediateSecondAsset.url.standardizedFileURL, secondSourceURL.standardizedFileURL)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 2)
        let secondPlaybackAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        let secondPlaybackURL = secondPlaybackAsset.url.standardizedFileURL
        XCTAssertEqual(secondPlaybackURL, secondSourceURL.standardizedFileURL)

        XCTAssertEqual(controller.send(.previousTrack), .success)
        XCTAssertEqual(playbackManager.currentTrack, first)
        XCTAssertTrue(playbackManager.isPlaying)
        let immediateFirstAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(immediateFirstAsset.url.standardizedFileURL, firstSourceURL.standardizedFileURL)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 3)

        let previousNormalizationDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < previousNormalizationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let firstPlaybackAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        let firstPlaybackURL = firstPlaybackAsset.url.standardizedFileURL
        XCTAssertEqual(firstPlaybackURL, firstSourceURL.standardizedFileURL)
        XCTAssertTrue(playbackManager.isPlaying)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 3)
    }

    @MainActor
    func testAutomaticAdvanceImmediatelyLoadsOriginalWithoutMidSongNormalizationSwap() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let firstSourceURL = temporaryDirectory.appendingPathComponent("first.wav")
        let secondSourceURL = temporaryDirectory.appendingPathComponent("second.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: firstSourceURL, amplitude: pow(10, -30.0 / 20.0))
        try writeSineWave(to: secondSourceURL, amplitude: pow(10, -24.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {}
        )
        let first = MusicItem(url: firstSourceURL, duration: 1)
        let second = MusicItem(url: secondSourceURL, duration: 1)
        playbackManager.updateQueue([first, second])

        playbackManager.play(first)
        XCTAssertEqual(playbackManager.currentTrack, first)
        XCTAssertTrue(playbackManager.isPlaying)
        let firstPlayerItem = try XCTUnwrap(player.currentItem)

        NotificationCenter.default.post(
            name: .AVPlayerItemDidPlayToEndTime,
            object: firstPlayerItem
        )

        let automaticAdvanceDeadline = Date().addingTimeInterval(2)
        while playbackManager.currentTrack != second,
              Date() < automaticAdvanceDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(
            playbackManager.currentTrack,
            second,
            "Timed out waiting for automatic advance to select the second track"
        )
        XCTAssertEqual(playbackManager.currentTrack, second)
        XCTAssertTrue(playbackManager.isPlaying)
        let playbackAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        let playbackURL = playbackAsset.url.standardizedFileURL
        let standardizedSecondSourceURL = secondSourceURL.standardizedFileURL
        XCTAssertEqual(playbackURL, standardizedSecondSourceURL)
    }

    @MainActor
    func testFailedBackgroundNormalizationIsNotCompletedAndRetriesOnNextQueueRefresh() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        let sourceBytes = try Data(contentsOf: sourceURL)
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let processorStateLock = NSLock()
        var processorInvocationCount = 0
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, processingSettings in
                let invocation = processorStateLock.withLock {
                    processorInvocationCount += 1
                    return processorInvocationCount
                }
                if invocation == 1 {
                    throw LoudnessProcessorTestError.deliberateFirstFailure
                }
                return try MusicLoudnessOfflineProcessor.process(
                    sourceURL: processingSourceURL,
                    destinationURL: destinationURL,
                    settings: processingSettings
                )
            }
        )
        let activationCountLock = NSLock()
        var activationCount = 0
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {
                activationCountLock.withLock {
                    activationCount += 1
                }
            }
        )
        let song = MusicItem(url: sourceURL, duration: 1)

        playbackManager.updateQueue([song])

        let firstInvocationDeadline = Date().addingTimeInterval(10)
        while processorStateLock.withLock({ processorInvocationCount < 1 }),
              Date() < firstInvocationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let firstCompletionDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < firstCompletionDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(processorStateLock.withLock { processorInvocationCount }, 1)
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 0)
        XCTAssertNil(playbackManager.currentTrack)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(playbackManager.isPlaying)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 0)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)

        playbackManager.updateQueue([song])

        let secondInvocationDeadline = Date().addingTimeInterval(10)
        while processorStateLock.withLock({ processorInvocationCount < 2 }),
              Date() < secondInvocationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let secondCompletionDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < secondCompletionDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(processorStateLock.withLock { processorInvocationCount }, 2)
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)
        XCTAssertFalse(playbackManager.isNormalizingLoudnessLibrary)
        XCTAssertNil(playbackManager.currentTrack)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(playbackManager.isPlaying)
        XCTAssertEqual(activationCountLock.withLock { activationCount }, 0)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)

        playbackManager.play(song)

        XCTAssertTrue(playbackManager.isPlaying)
        XCTAssertEqual(playbackManager.currentTrack, song)
        let playbackAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        let playbackURL = playbackAsset.url.standardizedFileURL
        let standardizedSourceURL = sourceURL.standardizedFileURL
        let standardizedCacheRootURL = cacheRootURL.standardizedFileURL
        XCTAssertNotEqual(playbackURL, standardizedSourceURL)
        XCTAssertTrue(playbackURL.path.hasPrefix(standardizedCacheRootURL.path + "/"))
        XCTAssertEqual(playbackURL.pathExtension.lowercased(), "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: playbackURL.path))
        XCTAssertGreaterThan(try measureAudioFile(at: playbackURL).frameCount, 0)
        XCTAssertEqual(processorStateLock.withLock { processorInvocationCount }, 2)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes)
        playbackManager.pause()
    }

    @MainActor
    func testSameURLSourceReplacementRejectsCompletedDerivativeAndRenormalizesInBackground() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let defaultsSuiteName = "MusicDetailPresentationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        let sourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        let cacheRootURL = temporaryDirectory
            .appendingPathComponent("loudness-cache", isDirectory: true)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -30.0 / 20.0))
        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let processorStateLock = NSLock()
        var processorInvocationCount = 0
        let coordinator = MusicLoudnessCacheCoordinator(
            cacheRootURL: cacheRootURL,
            settings: settings,
            processor: { processingSourceURL, destinationURL, processingSettings in
                processorStateLock.withLock {
                    processorInvocationCount += 1
                }
                return try MusicLoudnessOfflineProcessor.process(
                    sourceURL: processingSourceURL,
                    destinationURL: destinationURL,
                    settings: processingSettings
                )
            }
        )
        let player = AVPlayer()
        let playbackManager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            loudnessCoordinator: coordinator,
            activateAudioSession: {}
        )
        let song = MusicItem(url: sourceURL, duration: 1)

        playbackManager.updateQueue([song])

        let firstCompletionDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < firstCompletionDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(
            playbackManager.isNormalizingLoudnessLibrary,
            "Timed out waiting for the initial whole-library normalization"
        )
        XCTAssertEqual(processorStateLock.withLock { processorInvocationCount }, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)

        playbackManager.play(song)

        XCTAssertTrue(playbackManager.isPlaying)
        let firstPlaybackAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        let oldDerivativeURL = firstPlaybackAsset.url.standardizedFileURL
        let standardizedSourceURL = sourceURL.standardizedFileURL
        let standardizedCacheRootURL = cacheRootURL.standardizedFileURL
        XCTAssertNotEqual(oldDerivativeURL, standardizedSourceURL)
        XCTAssertTrue(oldDerivativeURL.path.hasPrefix(standardizedCacheRootURL.path + "/"))
        XCTAssertEqual(oldDerivativeURL.pathExtension.lowercased(), "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDerivativeURL.path))
        XCTAssertGreaterThan(try measureAudioFile(at: oldDerivativeURL).frameCount, 0)
        playbackManager.pause()

        try FileManager.default.removeItem(at: sourceURL)
        try writeSineWave(to: sourceURL, amplitude: pow(10, -6.0 / 20.0))
        let replacementBytes = try Data(contentsOf: sourceURL)
        let replacement = MusicItem(url: sourceURL, duration: 1)
        playbackManager.updateQueue([replacement])

        playbackManager.play(replacement)

        XCTAssertTrue(playbackManager.isPlaying, "Replacement playback must start immediately")
        XCTAssertEqual(playbackManager.currentTrack, replacement)
        let immediateReplacementAsset = try XCTUnwrap(
            player.currentItem?.asset as? AVURLAsset
        )
        XCTAssertEqual(
            immediateReplacementAsset.url.standardizedFileURL,
            standardizedSourceURL,
            "An in-place source replacement must not reuse the completed derivative for old bytes"
        )

        let secondStartDeadline = Date().addingTimeInterval(10)
        while processorStateLock.withLock({ processorInvocationCount < 2 }),
              Date() < secondStartDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(
            processorStateLock.withLock { processorInvocationCount },
            2,
            "The replacement bytes must start a second background normalization"
        )

        let secondCompletionDeadline = Date().addingTimeInterval(10)
        while playbackManager.isNormalizingLoudnessLibrary,
              Date() < secondCompletionDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(
            playbackManager.isNormalizingLoudnessLibrary,
            "Timed out waiting for replacement normalization"
        )
        XCTAssertEqual(processorStateLock.withLock { processorInvocationCount }, 2)
        XCTAssertEqual(playbackManager.loudnessNormalizationCompletedCount, 1)
        XCTAssertEqual(playbackManager.loudnessNormalizationTotalCount, 1)
        let uninterruptedAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(
            uninterruptedAsset.url.standardizedFileURL,
            standardizedSourceURL,
            "Completing normalization must not replace the current item mid-song"
        )

        playbackManager.pause()
        playbackManager.next()

        XCTAssertTrue(playbackManager.isPlaying)
        XCTAssertEqual(playbackManager.currentTrack, replacement)
        let freshPlaybackAsset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        let newDerivativeURL = freshPlaybackAsset.url.standardizedFileURL
        XCTAssertNotEqual(newDerivativeURL, standardizedSourceURL)
        XCTAssertNotEqual(newDerivativeURL, oldDerivativeURL)
        XCTAssertTrue(newDerivativeURL.path.hasPrefix(standardizedCacheRootURL.path + "/"))
        XCTAssertEqual(newDerivativeURL.pathExtension.lowercased(), "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newDerivativeURL.path))
        XCTAssertGreaterThan(try measureAudioFile(at: newDerivativeURL).frameCount, 0)
        XCTAssertEqual(try Data(contentsOf: sourceURL), replacementBytes)
        playbackManager.pause()
    }

    func testOfflineLoudnessProcessorMovesQuietAndLoudFilesTowardTargetWithPeakProtection() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let quietSourceURL = temporaryDirectory.appendingPathComponent("quiet.wav")
        let loudSourceURL = temporaryDirectory.appendingPathComponent("loud.wav")
        let quietDestinationURL = temporaryDirectory.appendingPathComponent("quiet.m4a")
        let loudDestinationURL = temporaryDirectory.appendingPathComponent("loud.m4a")
        try writeSineWave(to: quietSourceURL, amplitude: pow(10, -30.0 / 20.0))
        try writeSineWave(to: loudSourceURL, amplitude: pow(10, -3.0 / 20.0))

        let settings = try XCTUnwrap(
            MusicLoudnessNormalizationSettings(
                targetIntegratedLevelDBFS: -16,
                truePeakCeilingDBTP: -1.5,
                maximumBoostDB: 12,
                algorithmVersion: 1
            )
        )
        let quietResult: MusicLoudnessProcessingResult = try MusicLoudnessOfflineProcessor.process(
            sourceURL: quietSourceURL,
            destinationURL: quietDestinationURL,
            settings: settings
        )
        let loudResult: MusicLoudnessProcessingResult = try MusicLoudnessOfflineProcessor.process(
            sourceURL: loudSourceURL,
            destinationURL: loudDestinationURL,
            settings: settings
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: quietDestinationURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: loudDestinationURL.path))

        let quietSourceMeasurement = try measureAudioFile(at: quietSourceURL)
        let loudSourceMeasurement = try measureAudioFile(at: loudSourceURL)
        let quietOutputMeasurement = try measureAudioFile(at: quietDestinationURL)
        let loudOutputMeasurement = try measureAudioFile(at: loudDestinationURL)

        XCTAssertGreaterThan(quietOutputMeasurement.frameCount, 0)
        XCTAssertGreaterThan(loudOutputMeasurement.frameCount, 0)
        XCTAssertGreaterThanOrEqual(
            quietOutputMeasurement.meanSquareDBFS - quietSourceMeasurement.meanSquareDBFS,
            8
        )
        XCTAssertGreaterThanOrEqual(
            loudSourceMeasurement.meanSquareDBFS - loudOutputMeasurement.meanSquareDBFS,
            6
        )

        let sourceLevelGap = abs(
            quietSourceMeasurement.meanSquareDBFS - loudSourceMeasurement.meanSquareDBFS
        )
        let outputLevelGap = abs(
            quietOutputMeasurement.meanSquareDBFS - loudOutputMeasurement.meanSquareDBFS
        )
        XCTAssertLessThanOrEqual(outputLevelGap, 6.5)
        XCTAssertLessThan(outputLevelGap, sourceLevelGap)
        XCTAssertLessThanOrEqual(
            quietOutputMeasurement.samplePeakDBFS,
            settings.truePeakCeilingDBTP + 0.25
        )
        XCTAssertLessThanOrEqual(
            loudOutputMeasurement.samplePeakDBFS,
            settings.truePeakCeilingDBTP + 0.25
        )

        for result in [quietResult, loudResult] {
            XCTAssertTrue(result.measuredIntegratedLevelDBFS.isFinite)
            XCTAssertTrue(result.measuredTruePeakDBTP.isFinite)
            XCTAssertTrue(result.outputIntegratedLevelDBFS.isFinite)
            XCTAssertTrue(result.outputTruePeakDBTP.isFinite)
            XCTAssertTrue(result.appliedGainDB.isFinite)
        }
        XCTAssertGreaterThan(quietResult.appliedGainDB, 0)
        XCTAssertLessThan(loudResult.appliedGainDB, 0)
    }

    private func writeSineWave(to url: URL, amplitude: Double, duration: TimeInterval = 1) throws {
        let sampleRate = 44_100.0
        let safeDuration = duration.isFinite && duration > 0 ? duration : 1
        let frameCount = AVAudioFrameCount(sampleRate * safeDuration)
        let format = try XCTUnwrap(
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false
            )
        )
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        )
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0 ..< Int(frameCount) {
            samples[frame] = Float(amplitude * sin(2 * .pi * 440 * Double(frame) / sampleRate))
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func measureAudioFile(
        at url: URL
    ) throws -> (meanSquareDBFS: Double, samplePeakDBFS: Double, frameCount: AVAudioFramePosition) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0 else {
            XCTFail("Audio file is empty: \(url.lastPathComponent)")
            throw AudioMeasurementError.emptyAudio
        }
        guard file.length <= AVAudioFramePosition(UInt32.max) else {
            XCTFail("Audio file is too large to measure: \(url.lastPathComponent)")
            throw AudioMeasurementError.invalidAudio
        }

        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        )
        try file.read(into: buffer)
        guard buffer.frameLength > 0,
              let channelData = buffer.floatChannelData else {
            XCTFail("Audio file has no readable Float32 samples: \(url.lastPathComponent)")
            throw AudioMeasurementError.emptyAudio
        }

        var sumOfSquares = 0.0
        var samplePeak = 0.0
        let channelCount = Int(buffer.format.channelCount)
        let sampleCount = Int(buffer.frameLength) * channelCount
        for channel in 0 ..< channelCount {
            for frame in 0 ..< Int(buffer.frameLength) {
                let sample = Double(channelData[channel][frame])
                guard sample.isFinite else {
                    XCTFail("Audio file contains nonfinite samples: \(url.lastPathComponent)")
                    throw AudioMeasurementError.invalidAudio
                }
                sumOfSquares += sample * sample
                samplePeak = max(samplePeak, abs(sample))
            }
        }

        let meanSquare = sumOfSquares / Double(sampleCount)
        guard meanSquare.isFinite, meanSquare > 0, samplePeak.isFinite, samplePeak > 0 else {
            XCTFail("Audio file has invalid or silent sample data: \(url.lastPathComponent)")
            throw AudioMeasurementError.invalidAudio
        }
        let meanSquareDBFS = 10 * log10(meanSquare)
        let samplePeakDBFS = 20 * log10(samplePeak)
        guard meanSquareDBFS.isFinite, samplePeakDBFS.isFinite else {
            XCTFail("Audio file produced nonfinite measurements: \(url.lastPathComponent)")
            throw AudioMeasurementError.invalidAudio
        }

        return (meanSquareDBFS, samplePeakDBFS, AVAudioFramePosition(buffer.frameLength))
    }

    private func assertNoTemporaryFiles(
        in directoryURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        let temporaryURLs = enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.contains(".tmp") }
        XCTAssertTrue(
            temporaryURLs.isEmpty,
            "Cache contains temporary artifacts: \(temporaryURLs.map(\.path))",
            file: file,
            line: line
        )
    }

    private enum AudioMeasurementError: Error {
        case emptyAudio
        case invalidAudio
    }

    private enum LoudnessProcessorTestError: Error {
        case deliberateFirstFailure
    }

}
