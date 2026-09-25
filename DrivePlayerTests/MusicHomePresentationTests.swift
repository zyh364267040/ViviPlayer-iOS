import AVFoundation
import SwiftUI
import UIKit
import XCTest
@testable import DrivePlayer

/// List reachability/action regression tests; rendered text requires parent vision review.
/// Run on a simulator whose screen contains the 390 x 568 inset host.
@MainActor
final class MusicHomePresentationTests: XCTestCase {
    // Source contract only: this does not host RootTabView or prove safe-area geometry.
    func testRootMiniSourceContractReservesMusicNavigationSpaceAndRetainsVideoMini() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let rootSource = try String(contentsOf: root.appendingPathComponent("DrivePlayer/Views/RootTabView.swift"), encoding: .utf8)
        let homeSource = try String(contentsOf: root.appendingPathComponent("DrivePlayer/Views/MusicHomeView.swift"), encoding: .utf8)
        let videoStart = try XCTUnwrap(rootSource.range(of: "            tabContent {"))
        let musicStart = try XCTUnwrap(rootSource.range(of: "            VStack(spacing: 0) {"))
        let sheetStart = try XCTUnwrap(rootSource.range(of: "        .sheet(isPresented: $isMusicPlayerPresented)"))
        XCTAssertLessThan(videoStart.lowerBound, musicStart.lowerBound)
        XCTAssertLessThan(musicStart.lowerBound, sheetStart.lowerBound)
        let videoTab = String(rootSource[videoStart.lowerBound..<musicStart.lowerBound])
        let musicTab = String(rootSource[musicStart.lowerBound..<sheetStart.lowerBound])
        XCTAssertTrue(videoTab.contains("HomeView("))
        XCTAssertTrue(videoTab.contains("isVideoDetailPresented: $isVideoDetailPresented"))
        XCTAssertTrue(musicTab.contains("""
                    VStack(spacing: 0) {
                        MusicHomeView(library: musicLibrary, playback: playback, favorites: favorites, recentlyPlayed: recentlyPlayed, playlists: playlists)
                        rootMiniPlayer
                    }
        """), "The measured mini is a sibling of the entire music NavigationStack, including pushed destinations")
        XCTAssertEqual(musicTab.components(separatedBy: "rootMiniPlayer").count - 1, 1)
        XCTAssertFalse(musicTab.contains(".frame(height:"))
        XCTAssertFalse(musicTab.contains("Spacer("))
        XCTAssertFalse(musicTab.contains("tabContent {"))
        XCTAssertFalse(musicTab.contains(".safeAreaInset"), "Music navigation must receive space from layout, without an outer inset")
        XCTAssertEqual(rootSource.components(separatedBy: "tabContent {").count - 1, 1)
        XCTAssertTrue(rootSource.contains("""
            private func tabContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
                content()
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        rootMiniPlayer
                    }
            }
        """))
        XCTAssertEqual(rootSource.components(separatedBy: "MiniMusicPlayerView(playback: playback)").count - 1, 1)
        XCTAssertTrue(rootSource.contains("""
            private var rootMiniPlayer: some View {
                if VideoDetailLayoutPolicy.showsRootChrome(
                    isVideoDetailPresented: isVideoDetailPresented
                ), playback.currentTrack != nil {
                    MiniMusicPlayerView(playback: playback) {
                        isMusicPlayerPresented = true
                    }
                }
            }
        """))
        XCTAssertTrue(rootSource.contains("MusicPlayerView(playback: playback, favorites: favorites)"))
        // Scope ownership checks to the changed root composition/accessory declarations.
        // Playlist destinations legitimately retain their own StateObjects.
        let accessoryStart = try XCTUnwrap(rootSource.range(of: "    private var rootMiniPlayer: some View {"))
        let accessory = String(rootSource[accessoryStart.lowerBound...])
        for declaration in [musicTab, accessory] {
            XCTAssertFalse(declaration.contains("@StateObject"))
            XCTAssertFalse(declaration.contains("MusicPlaybackManager("))
            XCTAssertFalse(declaration.contains("MusicPlaylistStore("))
        }
        let homeStart = try XCTUnwrap(homeSource.range(of: "struct MusicHomeView: View {"))
        let destinationStart = try XCTUnwrap(homeSource.range(of: "private struct MusicPlaylistListView: View {"))
        let homeDeclaration = String(homeSource[homeStart.lowerBound..<destinationStart.lowerBound])
        XCTAssertTrue(homeDeclaration.contains("ScrollViewReader { proxy in\n            NavigationStack {\n                List {"))
        XCTAssertFalse(homeDeclaration.contains("bottomAccessory"), "Standalone home must retain its pre-candidate layout")
        XCTAssertFalse(homeDeclaration.contains(".safeAreaInset"))
        XCTAssertFalse(homeDeclaration.contains("@StateObject"))
        XCTAssertTrue(homeDeclaration.contains("MusicPlaylistListView(store: playlists, library: library, playback: playback)"))
        XCTAssertTrue(homeSource.contains("MusicPlaylistDetailView(playlistID: playlist.id, store: store, library: library, playback: playback)"))
        XCTAssertFalse(homeSource.contains("MiniMusicPlayerView("), "Only root owns the shared mini placement and sheet action")
    }

    func testHostedHomeAt320Standard() async throws {
        try await checkHome(width: 320, size: .large)
    }

    func testHostedHomeAt390Standard() async throws {
        try await checkHome(width: 390, size: .large)
    }

    func testHostedHomeAt320Accessibility5() async throws {
        try await checkHome(width: 320, size: .accessibility5)
    }

    func testHostedHomeAt390Accessibility5() async throws {
        try await checkHome(width: 390, size: .accessibility5)
    }

    func testHostedHomeThreeStatusBarsAt320Accessibility5() async throws {
        try await checkHome(width: 320, size: .accessibility5, statuses: true)
    }

    func testHostedHomeThreeStatusBarsAt390Accessibility5() async throws {
        try await checkHome(width: 390, size: .accessibility5, statuses: true)
    }

    func testHostedHomeRetryFailuresAndIndependentRecovery() async throws {
        try await checkHome(width: 390, size: .large, statuses: true, retries: true)
    }

    func testHostedHomeEmptyFavoritesRetainsRetryActions() async throws {
        try await checkHome(width: 390, size: .large, statuses: true, retries: true, emptyFavorites: true)
    }

    private func checkHome(width: CGFloat, size: DynamicTypeSize, statuses: Bool = false,
                           retries: Bool = false, emptyFavorites: Bool = false) async throws {
        if !retries {
            try await calibrateList(width: width, size: size)
            try await calibrateFavorite(width: width, size: size)
            if statuses { try await calibrateStatusSections(width: width, size: size) }
        }
        let suite = "MusicHomePresentation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        // Home's existing filter uses standard defaults. Restore the exact payload.
        let filterKey = MusicLibraryFilterPreferenceStore.key
        let oldFilter = UserDefaults.standard.object(forKey: filterKey)
        MusicLibraryFilterPreferenceStore(defaults: .standard).save(emptyFavorites ? .favorites : .all)
        defer {
            if let oldFilter { UserDefaults.standard.set(oldFilter, forKey: filterKey) }
            else { UserDefaults.standard.removeObject(forKey: filterKey) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let audio = root.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let frameCount: AVAudioFrameCount = retries ? 24_000 : 800
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(frameCount) { samples[index] = 0 }
        for index in 0..<24 {
            let url = audio.appendingPathComponent(String(format: "%02d-home.wav", index))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let library = MusicLibrary(storage: MediaLibraryStorage(
            rootURL: audio, legacyAudioURL: root.appendingPathComponent("LegacyAudio"),
            legacyVideoURL: root.appendingPathComponent("LegacyVideo")
        ), metadataLoader: MusicMetadataLoader(rawItemLoader: { url in
            let index = Int(url.lastPathComponent.prefix(2))!
            if index == 1 { return [] } // Loader supplies a nonempty title without the extension.
            if index == 2 {
                return [RawMusicMetadataItem(identifier: "id3/TIT2", stringValue: " \n\t ", dataValue: nil),
                        RawMusicMetadataItem(identifier: "id3/TPE1", stringValue: " \t ", dataValue: nil)]
            }
            return [RawMusicMetadataItem(identifier: "id3/TIT2", stringValue: Self.title(index), dataValue: nil),
                    RawMusicMetadataItem(identifier: "id3/TPE1", stringValue: "林间回声 Artist Ensemble", dataValue: nil)]
        }), metadataSnapshotStore: MediaMetadataSnapshotStore(fileURL: root.appendingPathComponent("metadata.json")),
           durationLoader: { _ in 224 }, lyricSidecarLoader: { _ in nil })
        let publication = await library.refresh()
        guard publication.isAuthoritative, library.libraryErrorMessage == nil, library.songs.count == 24 else {
            throw MiniPlayerAccessibilityHost.failure("Home fixture refresh failed")
        }
        let favorites = MusicFavoritesStore(defaults: defaults)
        let recent = MusicRecentlyPlayedStore(defaults: defaults)
        var rejectPlaylistWrites = false
        var rejectScopeWrites = false
        var playlistWrites = 0
        var scopeWrites = 0
        let playlists = MusicPlaylistStore(defaults: defaults, writePayload: { data in
            playlistWrites += 1
            guard !rejectPlaylistWrites else { return false }
            defaults.set(data, forKey: MusicPlaylistStore.persistenceKey)
            return true
        })
        let scope = MusicQueueScopeStore(defaults: defaults, writePayload: { data in
            scopeWrites += 1
            guard !rejectScopeWrites else { return false }
            defaults.set(data, forKey: MusicQueueScopeStore.key)
            return true
        })
        let gate = HomeNormalizationGate()
        defer { gate.release() }
        let settings = try XCTUnwrap(MusicLoudnessNormalizationSettings(
            targetIntegratedLevelDBFS: -16, truePeakCeilingDBTP: -1.5, maximumBoostDB: 12, algorithmVersion: 1))
        // Preserve directory URL identity for the coordinator's snapshot-parent guard.
        let coordinator = MusicLoudnessCacheCoordinator(cacheRootURL: root.appendingPathComponent("Cache", isDirectory: true),
            settings: settings, processor: { _, _, _ in
                try gate.wait()
                throw CancellationError()
            })
        let player = AVPlayer()
        player.isMuted = true
        let playback = MusicPlaybackManager(player: player, defaults: defaults,
            ownership: PlaybackOwnershipCoordinator(), loudnessCoordinator: statuses && !retries ? coordinator : nil,
            activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController(), queueScopeStore: scope)
        defer { playback.updateQueue([]); player.replaceCurrentItem(with: nil) }
        playback.updateQueue(library.songs)
        do {
            if statuses {
                let first = try XCTUnwrap(library.songs.first)
                let playlist = try XCTUnwrap(playlists.create(name: "Home status fixture"))
                XCTAssertTrue(playlists.add(first, to: playlist.id))
                if retries {
                    // Match persisted membership to the active queue so legitimate
                    // authoritative reconciliation is not mistaken for a UI side effect.
                    for song in library.songs.dropFirst() { XCTAssertTrue(playlists.add(song, to: playlist.id)) }
                }
                XCTAssertTrue(playlists.prepareMediaDeletion(first))
                rejectPlaylistWrites = true
                rejectScopeWrites = true
                _ = playlists.reconcile(with: publication, library: library.songs)
                playback.playFromPlaylist(first, playlistID: playlist.id, items: library.songs)
                playback.pause()
                for _ in 0..<(retries ? 0 : 100) {
                    if playback.isNormalizingLoudnessLibrary && gate.hasEntered { break }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                guard playlists.reconciliationNeedsRepair, playback.queueScopePersistenceNeedsRepair,
                      retries || (playback.isNormalizingLoudnessLibrary && gate.hasEntered) else {
                    throw MiniPlayerAccessibilityHost.failure("Three real status conditions did not become active")
                }
            }
            if retries {
                if !emptyFavorites { favorites.setFavorite(true, for: try XCTUnwrap(library.songs.last)) }
                let host = try MiniPlayerAccessibilityHost(content:
                    MusicHomeView(library: library, playback: playback, favorites: favorites,
                                  recentlyPlayed: recent, playlists: playlists)
                        .environment(\.dynamicTypeSize, size).environment(\.colorScheme, .light),
                    viewportWidth: width, viewportHeight: 568)
                defer { host.close() }
                let prefix = emptyFavorites ? "home-empty-favorites-retry" : "home-retry"
                _ = try await snapshot(host, name: prefix + "-initial")
                // Use a nonzero paused position so an accidental restart cannot pass.
                playback.seek(to: 1)
                for _ in 0..<100 {
                    if abs(playback.currentTime - 1) < 0.01,
                       abs(player.currentTime().seconds - 1) < 0.01 { break }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                guard abs(playback.currentTime - 1) < 0.01,
                      abs(player.currentTime().seconds - 1) < 0.01 else {
                    throw MiniPlayerAccessibilityHost.failure("Retry fixture did not settle at a nonzero paused time")
                }
                // Record a real AVPlayerItem, not just the model's track identity.
                let item = try XCTUnwrap(player.currentItem)
                let queue = playback.queue.map(\.id)
                let track = try XCTUnwrap(playback.currentTrack).id
                let index = playback.currentIndex
                let time = playback.currentTime
                let playerTime = player.currentTime().seconds
                XCTAssertTrue(playerTime.isFinite)
                let playing = playback.isPlaying
                XCTAssertFalse(playing)
                let favoriteIDs = Set(library.songs.filter { favorites.isFavorite($0) }.map(\.id))
                XCTAssertEqual(favoriteIDs.count, emptyFavorites ? 0 : 1)
                let queueScope = playback.queueScope
                let playlistRetry = "music-playlist-reconciliation-retry"
                let scopeRetry = "music-queue-scope-persistence-retry"

                func checkState(_ stage: String, playlistFailed: Bool, scopeFailed: Bool) async throws {
                    XCTAssertEqual(playlists.reconciliationNeedsRepair, playlistFailed)
                    XCTAssertEqual(playback.queueScopePersistenceNeedsRepair, scopeFailed)
                    let scroll = try XCTUnwrap(host.outerScrollView)
                    scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
                    var tree = try await snapshot(host, name: prefix + "-" + stage)
                    var seen = Set<String>()
                    var emptySeen = false
                    var bottom = ListBottomState()
                    var finished = false
                    // Reuse the existing lawful List traversal, with a small finite fixture bound.
                    for step in 0..<60 {
                        let geometry = try homeGeometry(host, scroll: scroll, tree: tree)
                        for element in tree {
                            let relevant = element.identifier?.hasPrefix("music-") == true
                                || element.label.contains("还没有收藏音乐")
                            guard relevant, geometry.contains(try host.validatedFrame(element)) else { continue }
                            if let id = element.identifier { seen.insert(id) }
                            if element.label.contains("还没有收藏音乐") { emptySeen = true }
                        }
                        if bottom.observe(scroll) { finished = true; break }
                        try advanceList(host, scroll: scroll, geometry: geometry)
                        tree = try await snapshot(host, name: prefix + "-" + stage + "-\(step)", capture: false)
                    }
                    XCTAssertTrue(finished, "Retry traversal did not reach stable legal bottom")
                    for (id, expected) in [
                        ("music-playlist-reconciliation-failure", playlistFailed), (playlistRetry, playlistFailed),
                        ("music-queue-scope-persistence-failure", scopeFailed), (scopeRetry, scopeFailed)
                    ] { XCTAssertEqual(seen.contains(id), expected, "\(stage): \(id)") }
                    if emptyFavorites {
                        XCTAssertTrue(emptySeen, "Real empty-favorites branch missing")
                        XCTAssertFalse(seen.contains { $0.hasPrefix("music-library-favorite-") })
                    }
                    XCTAssertEqual(playlists.reconciliationNeedsRepair, playlistFailed)
                    XCTAssertEqual(playback.queueScopePersistenceNeedsRepair, scopeFailed)
                    XCTAssertEqual(playback.queue.map(\.id), queue)
                    XCTAssertEqual(playback.queueScope, queueScope)
                    XCTAssertEqual(playback.currentTrack?.id, track)
                    XCTAssertEqual(playback.currentIndex, index)
                    XCTAssertTrue(player.currentItem === item)
                    XCTAssertEqual(playback.currentTime, time, accuracy: 0.01)
                    XCTAssertEqual(player.currentTime().seconds, playerTime, accuracy: 0.01)
                    XCTAssertEqual(playback.isPlaying, playing)
                    XCTAssertEqual(player.rate, 0)
                    XCTAssertEqual(Set(library.songs.filter { favorites.isFavorite($0) }.map(\.id)), favoriteIDs)
                }

                // Recovery uses the same real AX buttons. synchronize -> syncLibrary may
                // also save scope; keep its independent failure switch closed here.
                func activateRetry(_ id: String) async throws {
                    let scroll = try XCTUnwrap(host.outerScrollView)
                    scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
                    var tree = try await snapshot(host, name: prefix + "-recover-" + id, capture: false)
                    for step in 0..<12 {
                        let geometry = try homeGeometry(host, scroll: scroll, tree: tree)
                        if let button = tree.first(where: { $0.identifier == id }),
                           geometry.contains(try host.validatedFrame(button)) {
                            XCTAssertTrue(button.traits.contains(.button))
                            XCTAssertFalse(button.traits.contains(.notEnabled))
                            XCTAssertTrue(button.object.accessibilityActivate())
                            _ = try await snapshot(host, name: prefix + "-activated-" + id)
                            return
                        }
                        try advanceList(host, scroll: scroll, geometry: geometry)
                        tree = try await snapshot(host, name: prefix + "-recover-\(step)", capture: false)
                    }
                    XCTFail("Recovery retry never reachable: \(id)")
                }
                let initialPlaylistWrites = playlistWrites
                try await activateRetry(playlistRetry)
                XCTAssertGreaterThan(playlistWrites, initialPlaylistWrites)
                try await checkState("playlist-still-fails", playlistFailed: true, scopeFailed: true)
                let initialScopeWrites = scopeWrites
                try await activateRetry(scopeRetry)
                XCTAssertGreaterThan(scopeWrites, initialScopeWrites)
                try await checkState("scope-still-fails", playlistFailed: true, scopeFailed: true)
                rejectPlaylistWrites = false
                let beforeRepair = playlistWrites
                try await activateRetry(playlistRetry)
                XCTAssertGreaterThan(playlistWrites, beforeRepair)
                try await checkState("only-scope-remains", playlistFailed: false, scopeFailed: true)
                rejectScopeWrites = false
                let beforeSave = scopeWrites
                try await activateRetry(scopeRetry)
                XCTAssertGreaterThan(scopeWrites, beforeSave)
                try await checkState("both-recovered", playlistFailed: false, scopeFailed: false)
            }
            for scheme: ColorScheme in (retries ? [] : [ColorScheme.light, ColorScheme.dark]) {
                let name = "home-\(Int(width))-\(size)-\(scheme)-\(statuses ? "three-status" : "baseline")"
                let host = try MiniPlayerAccessibilityHost(content:
                    MusicHomeView(library: library, playback: playback, favorites: favorites,
                                  recentlyPlayed: recent, playlists: playlists)
                        .environment(\.dynamicTypeSize, size).environment(\.colorScheme, scheme),
                    viewportWidth: width, viewportHeight: 568)
                let initialFailures = testRun?.failureCount ?? 0
                var finished = false
                defer {
                    if !finished || (testRun?.failureCount ?? 0) > initialFailures {
                        if let image = try? host.renderedAttachment(name: name + "-failure") { add(image) }
                    }
                    host.close()
                }
                _ = try await snapshot(host, name: name + "-arrival")
                let scroll = try XCTUnwrap(host.outerScrollView, "INFRASTRUCTURE_FAILURE: home List scroll missing")
                // Arrival locates the current song below the status sections. Start
                // the full-library reachability pass at the legal top after it settles.
                scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
                var tree = try await snapshot(host, name: name + "-top")
                XCTAssertEqual(host.viewportScreenFrame.width, width, accuracy: 0.5)
                XCTAssertEqual(host.viewportScreenFrame.height, 568, accuracy: 0.5)
                var reachedStatuses = Set<String>()
                var seen = Set<String>()
                var reachable = Set<String>()
                var activated = Set<String>()
                var capturedMiddle = false
                var bottomReached = false
                var bottomState = ListBottomState()
                // Discover virtualized rows with overlapping viewport samples. Status targets
                // additionally need frame-guided positioning: a tall Text can fit in
                // the viewport yet have a complete-visibility window smaller than a step.
                for step in 0..<240 {
                    var geometry = try homeGeometry(host, scroll: scroll, tree: tree)
                    if statuses {
                        XCTAssertTrue(playlists.reconciliationNeedsRepair)
                        XCTAssertTrue(playback.queueScopePersistenceNeedsRepair)
                        XCTAssertTrue(playback.isNormalizingLoudnessLibrary)
                        XCTAssertEqual(playback.loudnessNormalizationCompletedCount, 0)
                        XCTAssertEqual(playback.loudnessNormalizationTotalCount, 24)
                        let message = try XCTUnwrap(MusicLoudnessLibraryProgressPresentation(
                            isNormalizing: playback.isNormalizingLoudnessLibrary,
                            completedCount: playback.loudnessNormalizationCompletedCount,
                            totalCount: playback.loudnessNormalizationTotalCount).message)
                        XCTAssertEqual(message, "正在统一音量 0/24")
                        try await recordStatusReachability(host, tree: &tree, scroll: scroll,
                            progressMessage: message, reached: &reachedStatuses, name: name + "-status-step-\(step)")
                        geometry = try homeGeometry(host, scroll: scroll, tree: tree)
                    }
                    let visible = geometry.viewport
                    guard visible.height > 0 else {
                        throw MiniPlayerAccessibilityHost.failure("No visible home List region")
                    }
                    // Favorite labels repeat across rows, so an absent identifier
                    // cannot safely use the calibration's unique-label fallback.
                    if tree.contains(where: {
                        $0.identifier == nil && $0.traits.contains(.button)
                            && ["收藏", "取消收藏"].contains($0.label)
                    }) {
                        throw MiniPlayerAccessibilityHost.failure(
                            "Home favorite identifier missing; repeated labels cannot identify a song")
                    }
                    for song in library.songs {
                        guard let favorite = tree.first(where: { $0.identifier == "music-library-favorite-\(song.id)" }) else { continue }
                        let firstVisit = seen.insert(song.id).inserted
                        let frame = try host.validatedFrame(favorite)
                        diagnostic("ID=\(song.id) favorite AX=\(frame) fullyUnoccluded=\(geometry.contains(frame)); physical 44pt hit=PENDING",
                                   name: name + "-step-\(step)-favorite-\(song.id)")
                        // Virtualized AX may expose a clipped favorite without its row.
                        // Keep the ID above, but require same-cell identity only once visible.
                        // The final reachable-set assertion still requires every expected row.
                        guard geometry.contains(frame) else { continue }
                        let row = try rowInSameCell(as: favorite, tree: tree, scroll: scroll, host: host)
                        let index = Int(song.fileName.prefix(2))!
                        let expectedTitle = (index == 1 || index == 2)
                            ? URL(fileURLWithPath: song.fileName).deletingPathExtension().lastPathComponent
                            : Self.title(index)
                        if !reachable.contains(song.id) {
                            XCTAssertEqual(song.metadata?.title, expectedTitle, "Loader title contract changed")
                            XCTAssertTrue(row.label.contains(expectedTitle), "Loader title missing for \(song.id)")
                            XCTAssertTrue(row.label.contains("3:44"), "Duration lost for \(song.id)")
                            if index != 1 && index != 2 {
                                XCTAssertTrue(row.label.contains("林间回声 Artist Ensemble"), "Artist lost for \(song.id)")
                            }
                        }
                        let rowFrame = try host.validatedFrame(row)
                        // AX may expose only the glyph; it is not the physical hit target.
                        if firstVisit { diagnostic("favorite AX=\(frame); physical 44pt hit=PENDING", name: name + "-favorite-\(index)") }
                        XCTAssertFalse(frame.intersects(rowFrame), "Row AX overlaps favorite AX")
                        XCTAssertFalse(favorite.traits.contains(.notEnabled))
                        if geometry.contains(frame) && geometry.contains(rowFrame) { reachable.insert(song.id) }
                        if (index == 0 || index == 23) && geometry.contains(frame) && activated.insert(song.id).inserted {
                            let wasFavorite = favorites.isFavorite(song)
                            XCTAssertTrue(favorite.object.accessibilityActivate())
                            tree = try await snapshot(host, name: name + "-favorite-\(index)-activated", capture: false)
                            XCTAssertEqual(favorites.isFavorite(song), !wasFavorite, "Real favorite action failed")
                            let updated = try XCTUnwrap(tree.first { $0.identifier == favorite.identifier })
                            XCTAssertEqual(updated.label, wasFavorite ? "收藏" : "取消收藏")
                        }
                    }
                    if bottomState.observe(scroll) {
                        bottomReached = true
                        break
                    }
                    if !capturedMiddle && seen.count >= 12 {
                        try attach(host, tree: tree, name: name + "-middle")
                        capturedMiddle = true
                    }
                    try advanceList(host, scroll: scroll, geometry: geometry)
                    tree = try await snapshot(host, name: name + "-step-\(step)", capture: false)
                }
                guard bottomReached else {
                    throw MiniPlayerAccessibilityHost.failure(
                        "Home List traversal exhausted 240 steps without stable offset/contentSize at legal bottom; seen=\(seen.count)/24")
                }
                try attach(host, tree: tree, name: name + "-bottom")
                XCTAssertTrue(bottomReached, "Did not reach legal List bottom")
                XCTAssertEqual(seen, Set(library.songs.map(\.id)), "Some row identities were never visited")
                XCTAssertEqual(reachable, Set(library.songs.map(\.id)), "PRESENTATION_RED: rows/favorites never fully reachable outside List clipping/navigation/search occlusion")
                let bottomGeometry = try homeGeometry(host, scroll: scroll, tree: tree)
                let last = try XCTUnwrap(library.songs.last)
                let lastFavorite = try XCTUnwrap(tree.first { $0.identifier == "music-library-favorite-\(last.id)" })
                XCTAssertTrue(bottomGeometry.contains(try host.validatedFrame(lastFavorite)), "PRESENTATION_RED: last favorite is occluded at stable bottom")
                if statuses {
                    XCTAssertEqual(reachedStatuses, Self.statusIdentities,
                                   "Status Text/retry/progress never individually fully reachable in bounded List traversal")
                    diagnostic("AX reachability and complete labels do not prove drawn glyphs are untruncated. Parent vision must review top, status reachability, middle, bottom and failure images.",
                               name: name + "-rendered-readability-PENDING")
                }
                let actionIDs = Set([library.songs.first, library.songs.last].compactMap { $0?.id })
                XCTAssertEqual(activated, actionIDs, "PRESENTATION_RED: first/last favorite AX action was not reachable")
                finished = true
            }
        } catch {
            playback.updateQueue([])
            gate.release()
            _ = await coordinator.resolve(sourceURL: root.appendingPathComponent("missing.wav"))
            throw error
        }
        playback.updateQueue([])
        gate.release()
        // Drain the actor after releasing the processor, before deleting fixture files.
        _ = await coordinator.resolve(sourceURL: root.appendingPathComponent("missing.wav"))
    }

    private struct HomeGeometry {
        let viewport: CGRect
        let statusAX: [String: CGRect]
        let search: [CGRect]
        var unobstructedBands: [CGRect] {
            var bands = [viewport]
            for occluder in search {
                bands = bands.flatMap { band -> [CGRect] in
                    let overlap = band.intersection(occluder)
                    guard !overlap.isNull, !overlap.isEmpty else { return [band] }
                    return [CGRect(x: band.minX, y: band.minY, width: band.width, height: max(0, overlap.minY - band.minY)),
                            CGRect(x: band.minX, y: overlap.maxY, width: band.width, height: max(0, band.maxY - overlap.maxY))]
                }
            }
            return bands.filter { !$0.isEmpty && !$0.isNull }
        }
        var largestBandHeight: CGFloat {
            unobstructedBands.map(\.height).max() ?? 0
        }
        func contains(_ frame: CGRect) -> Bool {
            viewport.contains(frame) && !search.contains { $0.intersects(frame) }
        }
    }

    private func rowInSameCell(as favorite: MiniPlayerAccessibilityHost.Element,
                               tree: [MiniPlayerAccessibilityHost.Element], scroll: UIScrollView,
                               host: MiniPlayerAccessibilityHost) throws -> MiniPlayerAccessibilityHost.Element {
        let window = try XCTUnwrap(scroll.window)
        var cells: [UIView] = []
        func visit(_ view: UIView) {
            if view is UICollectionViewCell || view is UITableViewCell { cells.append(view); return }
            view.subviews.forEach(visit)
        }
        visit(scroll)
        let favoriteFrame = try host.validatedFrame(favorite)
        let candidates = cells.filter {
            $0.convert($0.bounds, to: window.screen.coordinateSpace)
                .contains(CGPoint(x: favoriteFrame.midX, y: favoriteFrame.midY))
        }
        guard candidates.count == 1, let cell = candidates.first else {
            throw MiniPlayerAccessibilityHost.failure("Favorite ID has no unique realized cell: \(favorite.frameDiagnostic)")
        }
        let cellFrame = cell.convert(cell.bounds, to: window.screen.coordinateSpace)
        let rows = tree.filter {
            $0.object !== favorite.object && $0.traits.contains(.button) && $0.identifier == nil
                && cellFrame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY))
                && abs($0.frame.midY - favoriteFrame.midY) < 1
        }
        guard rows.count == 1, let row = rows.first else {
            throw MiniPlayerAccessibilityHost.failure("Favorite cell does not contain a unique row button: \(favorite.frameDiagnostic)")
        }
        return row
    }

    // AX container bounds are semantic observations, never rendered occluders.
    // Status Section rows scroll as content; their AX bounds never subtract from the viewport.
    private func homeGeometry(_ host: MiniPlayerAccessibilityHost, scroll: UIScrollView,
                              tree: [MiniPlayerAccessibilityHost.Element]) throws -> HomeGeometry {
        let window = try XCTUnwrap(scroll.window)
        var visited = Set<ObjectIdentifier>()
        var statusAX: [String: CGRect] = [:]
        var search: [CGRect] = []
        let statusIDs: Set<String> = ["music-playlist-reconciliation-failure", "music-queue-scope-persistence-failure"]
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted, visited.count < 4096 else { return }
            if let view = object as? UIView {
                guard !view.isHidden, view.alpha > 0.01 else { return }
                if view is UISearchBar {
                    var frame = view.convert(view.bounds, to: window.screen.coordinateSpace)
                    var ancestor = view.superview
                    while let parent = ancestor {
                        if parent.clipsToBounds {
                            frame = frame.intersection(parent.convert(parent.bounds, to: window.screen.coordinateSpace))
                        }
                        ancestor = parent.superview
                    }
                    frame = frame.intersection(host.viewportScreenFrame)
                    if !frame.isNull && !frame.isEmpty { search.append(frame) }
                }
            }
            if let id = MiniPlayerAccessibilityHost.readIdentifier(object), statusIDs.contains(id) {
                let frame = object.accessibilityFrame
                if !frame.isNull, !frame.isEmpty, frame.minY.isFinite {
                    statusAX[id] = frame
                }
            }
            if let children = object.accessibilityElements {
                for case let child as NSObject in children { visit(child) }
            } else {
                let count = object.accessibilityElementCount()
                if count != NSNotFound, count > 0, count < 2048 {
                    for index in 0..<count {
                        if let child = object.accessibilityElement(at: index) as? NSObject { visit(child) }
                    }
                }
            }
            if let view = object as? UIView { view.subviews.forEach { visit($0) } }
        }
        if let root = window.rootViewController?.view { visit(root) }
        // Combined loudness AX bounds also do not measure the rendered HStack.
        for element in tree where element.label.hasPrefix("正在统一音量") {
            statusAX["loudness-progress"] = try host.validatedFrame(element)
        }
        // Search's leaf is also useful if UIKit exposes the field outside its bar.
        for element in tree where element.object is UISearchTextField {
            let frame = try host.validatedFrame(element).intersection(host.viewportScreenFrame)
            if !frame.isNull && !frame.isEmpty { search.append(frame) }
        }
        return HomeGeometry(viewport: host.visibleScrollFrame(scroll), statusAX: statusAX, search: search)
    }

    private static let statusIdentities: Set<String> = [
        "music-playlist-reconciliation-failure", "music-playlist-reconciliation-retry",
        "music-queue-scope-persistence-failure", "music-queue-scope-persistence-retry", "loudness-progress"
    ]

    // Observe each real Text/action independently. A reason and its retry may be
    // fully visible on different steps. Combined progress AX is semantic evidence,
    // not a measurement of the rendered spinner or glyphs.
    private func recordStatusReachability(_ host: MiniPlayerAccessibilityHost,
        tree: inout [MiniPlayerAccessibilityHost.Element], scroll: UIScrollView,
        progressMessage: String, reached: inout Set<String>, name: String) async throws {
        let expected = [
            ("music-playlist-reconciliation-failure", "播放列表未能保存最新音乐状态，请重试修复。", false),
            ("music-playlist-reconciliation-retry", "重试修复", true),
            ("music-queue-scope-persistence-failure", "播放范围未能保存。当前播放不受影响，请重试保存。", false),
            ("music-queue-scope-persistence-retry", "重试保存", true),
            ("loudness-progress", progressMessage, false)
        ]
        let traversalOffset = scroll.contentOffset
        for (identity, label, isRetry) in expected {
            // Three corrections allow navigation collapse / List remeasurement.
            // This is a per-identity geometry bound, not additional blind traversal.
            for attempt in 0...3 {
                let matches = tree.filter {
                    identity == "loudness-progress" ? $0.label.hasPrefix("正在统一音量") : $0.identifier == identity
                }
                guard !matches.isEmpty else { break } // List virtualization is expected.
                XCTAssertEqual(matches.count, 1, "Ambiguous status identity: \(identity)")
                let element = try XCTUnwrap(matches.first)
                XCTAssertEqual(element.label, label, "Complete status/retry copy changed: \(identity)")
                if isRetry {
                    XCTAssertTrue(element.traits.contains(.button), identity)
                    XCTAssertFalse(element.traits.contains(.notEnabled), "Retry independently disabled: \(identity)")
                }
                let frame = try host.validatedFrame(element)
                let geometry = try homeGeometry(host, scroll: scroll, tree: tree)
                diagnostic("identity=\(identity) AX=\(frame) viewport=\(geometry.viewport) bands=\(geometry.unobstructedBands) fullyReachable=\(geometry.contains(frame)); rendered truncation requires vision",
                           name: name + "-\(identity)-attempt-\(attempt)")
                if geometry.contains(frame) {
                    if reached.insert(identity).inserted {
                        try attach(host, tree: tree, name: name + "-reachable-" + identity)
                    }
                    break
                }
                if reached.contains(identity) { break }
                guard let band = geometry.unobstructedBands.filter({
                    $0.minX <= frame.minX && $0.maxX >= frame.maxX && $0.height >= frame.height
                }).max(by: { $0.height < $1.height }) else {
                    try attach(host, tree: tree, name: name + "-oversize-" + identity)
                    // Never count a mere intersection as reading coverage. If a future
                    // fixture is taller than every band, it needs explicit overlapping
                    // reading segments and glyph screenshot review before it can pass.
                    throw MiniPlayerAccessibilityHost.failure(
                        "Status target cannot fit measured unoccluded bands; segmented reading is unverified: \(identity), frame=\(frame), bands=\(geometry.unobstructedBands)")
                }
                guard attempt < 3 else {
                    try attach(host, tree: tree, name: name + "-positioning-failure-" + identity)
                    throw MiniPlayerAccessibilityHost.failure("Frame-guided status positioning did not settle: \(identity)")
                }
                let minimum = -scroll.adjustedContentInset.top
                let maximum = max(minimum,
                    scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                let delta = frame.midY - band.midY
                let next = max(minimum, min(maximum, scroll.contentOffset.y + delta))
                guard next.isFinite, abs(next - scroll.contentOffset.y) > 0.5 else {
                    try attach(host, tree: tree, name: name + "-positioning-limit-" + identity)
                    throw MiniPlayerAccessibilityHost.failure("Status positioning reached legal offset limit: \(identity)")
                }
                diagnostic("identity=\(identity) frame=\(frame) band=\(band) delta=\(delta) offset=\(scroll.contentOffset.y) -> \(next)",
                           name: name + "-position-\(identity)-\(attempt)")
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: false)
                tree = try await snapshot(host, name: name + "-positioned-\(identity)-\(attempt)", capture: false)
            }
        }
        // Positioning is a reading detour. Resume the discovery pass at its
        // original offset so status checks cannot skip song/favorite samples.
        if scroll.contentOffset != traversalOffset {
            let minimum = -scroll.adjustedContentInset.top
            let maximum = max(minimum,
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: traversalOffset.x,
                y: max(minimum, min(maximum, traversalOffset.y))), animated: false)
            tree = try await snapshot(host, name: name + "-resume-traversal", capture: false)
        }
    }

    private func calibrateStatusSections(width: CGFloat, size: DynamicTypeSize) async throws {
        let host = try MiniPlayerAccessibilityHost(content: NavigationStack {
            List {
                calibrationRepairSection(message: "播放列表未能保存最新音乐状态，请重试修复。", retry: "重试修复",
                    messageID: "music-playlist-reconciliation-failure", retryID: "music-playlist-reconciliation-retry")
                calibrationRepairSection(message: "播放范围未能保存。当前播放不受影响，请重试保存。", retry: "重试保存",
                    messageID: "music-queue-scope-persistence-failure", retryID: "music-queue-scope-persistence-retry")
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在统一音量 0/24").font(.subheadline)
                            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine).accessibilityLabel("正在统一音量 0/24")
                }
                Section {
                    ForEach(0..<24, id: \.self) { index in
                        Text("Home Section Probe \(index)")
                            .accessibilityIdentifier("home-section-probe-\(index)")
                    }
                }
            }
            .navigationTitle("音乐").searchable(text: .constant(""), prompt: "搜索音乐")
        }.environment(\.dynamicTypeSize, size), viewportWidth: width, viewportHeight: 568)
        let name = "home-status-section-calibration-\(Int(width))-\(size)"
        let initialFailures = testRun?.failureCount ?? 0
        var finished = false
        defer {
            if !finished || (testRun?.failureCount ?? 0) > initialFailures {
                if let image = try? host.renderedAttachment(name: name + "-failure") { add(image) }
            }
            host.close()
        }
        var tree = try await snapshot(host, name: name + "-top")
        let scroll = try XCTUnwrap(host.outerScrollView)
        var reached = Set<String>()
        var bottomState = ListBottomState()
        for step in 0..<240 {
            try await recordStatusReachability(host, tree: &tree, scroll: scroll,
                progressMessage: "正在统一音量 0/24", reached: &reached, name: name + "-step-\(step)")
            let geometry = try homeGeometry(host, scroll: scroll, tree: tree)
            if bottomState.observe(scroll) {
                let last = try XCTUnwrap(tree.first { $0.identifier == "home-section-probe-23" })
                XCTAssertTrue(geometry.contains(try host.validatedFrame(last)))
                XCTAssertEqual(reached, Self.statusIdentities, "Section calibration missed individually reachable status content")
                guard reached == Self.statusIdentities else {
                    throw MiniPlayerAccessibilityHost.failure("Status calibration incomplete; production reachability cannot be classified")
                }
                try attach(host, tree: tree, name: name + "-bottom")
                finished = true
                return
            }
            try advanceList(host, scroll: scroll, geometry: geometry)
            tree = try await snapshot(host, name: name + "-step-\(step)", capture: false)
        }
        throw MiniPlayerAccessibilityHost.failure("Section calibration exhausted 240 steps without stable legal bottom")
    }

    private func calibrationRepairSection(message: String, retry: String,
                                           messageID: String, retryID: String) -> some View {
        Section {
            Text(message).font(.subheadline).lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(messageID)
            Button {} label: {
                Text(retry).lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.bordered).accessibilityIdentifier(retryID)
        }
    }

    private func calibrateFavorite(width: CGFloat, size: DynamicTypeSize) async throws {
        let measurement = HomeFrameMeasurement()
        var activations = 0
        let host = try MiniPlayerAccessibilityHost(content: NavigationStack {
            List {
                HStack {
                    Button("Home row calibration") {}.buttonStyle(.plain)
                    Spacer()
                    Button { activations += 1 } label: {
                        Image(systemName: "star")
                            .frame(width: 44, height: 44)
                            .background(GeometryReader { proxy in
                                Color.clear.onAppear { measurement.size = proxy.size }
                                    .onChange(of: proxy.size) { _, value in measurement.size = value }
                            })
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("收藏")
                    .accessibilityIdentifier("home-favorite-calibration")
                }
            }.navigationTitle("音乐")
                .searchable(text: .constant(""), prompt: "搜索音乐")
        }.environment(\.dynamicTypeSize, size), viewportWidth: width, viewportHeight: 568)
        defer { host.close() }
        let name = "home-favorite-calibration-\(Int(width))-\(size)"
        let tree = try await snapshot(host, name: name)
        let favorite = try XCTUnwrap(tree.first { $0.identifier == "home-favorite-calibration" })
        let layout = try XCTUnwrap(measurement.size, "INFRASTRUCTURE_FAILURE: layout probe missing")
        XCTAssertEqual(layout.width, 44, accuracy: 0.5)
        XCTAssertEqual(layout.height, 44, accuracy: 0.5)
        diagnostic("Image.frame layout=\(layout); AX=\(try host.validatedFrame(favorite)); plain button; physical hit=PENDING. AX and layout are independent observations.", name: name + "-layout-vs-AX")
        XCTAssertTrue(favorite.object.accessibilityActivate())
        _ = try await snapshot(host, name: name + "-activated", capture: false)
        XCTAssertEqual(activations, 1, "Calibration validates AX action only")
    }

    nonisolated private static func title(_ index: Int) -> String {
        "曲目\(index) 晚风来信 A Long Journey Home 写给城市晚风里慢慢走回家的你"
    }

    private func diagnostic(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(_ host: MiniPlayerAccessibilityHost,
                        tree: [MiniPlayerAccessibilityHost.Element], name: String) throws {
        let metrics = host.outerScrollView.map {
            "scroll=\(type(of: $0)) offset=\($0.contentOffset) contentSize=\($0.contentSize) bounds=\($0.bounds) adjustedInset=\($0.adjustedContentInset) visible=\(host.visibleScrollFrame($0))"
        } ?? "scroll=nil"
        add(try host.renderedAttachment(name: name))
        let geometry = try host.outerScrollView.map { try homeGeometry(host, scroll: $0, tree: tree) }
        diagnostic(metrics + "\nsemantic status AX (not occlusion)=\(geometry?.statusAX ?? [:]) search=\(geometry?.search ?? [])\n" + tree.map(\.frameDiagnostic).joined(separator: "\n"), name: name + "-AX")
    }

    // Keep every text poll; images only at top, representative middle, bottom or failure.
    private func snapshot(_ host: MiniPlayerAccessibilityHost, name: String, capture: Bool = true) async throws
        -> [MiniPlayerAccessibilityHost.Element] {
        var poll = 0
        do {
            let tree = try await host.layoutSnapshot { elements in
                let metrics = host.outerScrollView.map {
                    "offset=\($0.contentOffset) contentSize=\($0.contentSize) bounds=\($0.bounds) adjustedInset=\($0.adjustedContentInset) visible=\(host.visibleScrollFrame($0))"
                } ?? "scroll=nil"
                self.diagnostic(metrics + "\n" + elements.map(\.frameDiagnostic).joined(separator: "\n"),
                                name: name + "-poll-\(poll)-AX")
                poll += 1
            }
            if let scroll = host.outerScrollView {
                let geometry = try homeGeometry(host, scroll: scroll, tree: tree)
                diagnostic("semantic status AX (not occlusion)=\(geometry.statusAX) search=\(geometry.search) viewport=\(geometry.viewport) band excluding measured navigation/search only=\(geometry.largestBandHeight)",
                           name: name + "-occlusion")
            }
            if capture { try attach(host, tree: tree, name: name) }
            return tree
        } catch {
            diagnostic(String(describing: error), name: name + "-failure")
            if let rendered = try? host.renderedAttachment(name: name + "-failure") { add(rendered) }
            throw error
        }
    }

    private struct ListBottomState {
        private var previousOffset: CGPoint?
        private var previousSize: CGSize?
        private var consecutive = 0

        mutating func observe(_ scroll: UIScrollView) -> Bool {
            let maximum = max(-scroll.adjustedContentInset.top,
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
            let atBottom = abs(scroll.contentOffset.y - maximum) < 0.5
            consecutive = atBottom && previousOffset == scroll.contentOffset
                && previousSize == scroll.contentSize ? consecutive + 1 : 0
            previousOffset = scroll.contentOffset
            previousSize = scroll.contentSize
            // Matching an estimated maximum once does not establish the bottom.
            return consecutive >= 2
        }
    }

    private func advanceList(_ host: MiniPlayerAccessibilityHost, scroll: UIScrollView, geometry: HomeGeometry? = nil) throws {
        let visible = host.visibleScrollFrame(scroll)
        guard visible.height.isFinite, visible.height > 0,
              scroll.contentSize.height.isFinite, scroll.contentOffset.y.isFinite else {
            throw MiniPlayerAccessibilityHost.failure("Invalid List scroll geometry")
        }
        let minimum = -scroll.adjustedContentInset.top
        let maximum = max(minimum,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        // Use actual unobstructed vertical bands when any exist. A completely
        // covered List still advances to a stable bottom and then fails reachability.
        let stepHeight = geometry.map { $0.largestBandHeight > 0 ? $0.largestBandHeight : visible.height } ?? visible.height
        // Rows have at least the production 44pt Image layout. A narrower
        // exposed band cannot contain a whole row; avoid tiny-step spinning there.
        // Recompute after every settled render; never jump to an estimated end.
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
            y: max(minimum, min(maximum, scroll.contentOffset.y + max(44, stepHeight * 0.4)))), animated: false)
    }

    private func calibrateList(width: CGFloat, size: DynamicTypeSize) async throws {
        var activations = 0
        let host = try MiniPlayerAccessibilityHost(content: NavigationStack {
            List(0..<30, id: \.self) { index in
                Button("Home List Probe \(index)") { activations += 1 }
                    .buttonStyle(.plain).frame(height: 48)
                    .accessibilityIdentifier("home-probe-\(index)")
            }.navigationTitle("音乐")
        }.environment(\.dynamicTypeSize, size), viewportWidth: width, viewportHeight: 568)
        defer { host.close() }
        let name = "home-list-calibration-\(Int(width))-\(size)"
        let getterProbe = UIButton()
        getterProbe.accessibilityIdentifier = "home-getter-probe"
        let getterResult = MiniPlayerAccessibilityHost.readIdentifier(getterProbe)
        diagnostic("UIButton getter=\(String(reflecting: getterResult)); NSObject getter=\(String(reflecting: MiniPlayerAccessibilityHost.readIdentifier(NSObject())))",
                   name: name + "-identifier-getter")
        var tree = try await snapshot(host, name: name + "-top")
        guard getterResult == "home-getter-probe",
              MiniPlayerAccessibilityHost.readIdentifier(NSObject()) == nil,
              let scroll = host.outerScrollView else {
            throw MiniPlayerAccessibilityHost.failure("List calibration getter/scroll unavailable")
        }
        var bottomState = ListBottomState()
        for step in 0..<240 {
            let byID = tree.filter { $0.identifier == "home-probe-29" }
            let byLabel = tree.filter { $0.label == "Home List Probe 29" && $0.traits.contains(.button) }
            guard byID.count <= 1, byLabel.count <= 1 else {
                throw MiniPlayerAccessibilityHost.failure("Ambiguous List bottom probe identity")
            }
            let bottom = byID.first ?? byLabel.first.flatMap { $0.identifier == nil ? $0 : nil }
            if let bottom {
                guard bottom.label == "Home List Probe 29", bottom.traits.contains(.button) else {
                    throw MiniPlayerAccessibilityHost.failure("List probe getter/label mismatch")
                }
                diagnostic("matched via=\(bottom.identifier == nil ? "unique-exact-label" : "identifier") \(bottom.frameDiagnostic)",
                           name: name + "-step-\(step)-match")
            } else if let mismatch = byLabel.first, mismatch.identifier != nil {
                throw MiniPlayerAccessibilityHost.failure("List probe identifier mismatch: \(mismatch.diagnostic)")
            }
            let visible = try bottom.map { host.visibleScrollFrame(scroll).contains(try host.validatedFrame($0)) } ?? false
            if bottomState.observe(scroll) {
                try attach(host, tree: tree, name: name + "-bottom")
                guard visible, let bottom else {
                    throw MiniPlayerAccessibilityHost.failure("Stable calibration bottom probe is not visible")
                }
                guard scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
                        > -scroll.adjustedContentInset.top,
                      bottom.object.accessibilityActivate() else {
                    throw MiniPlayerAccessibilityHost.failure("Native List overflow/bottom AX activation calibration failed")
                }
                _ = try await snapshot(host, name: name + "-activated", capture: false)
                guard activations == 1 else {
                    throw MiniPlayerAccessibilityHost.failure("Native List AX action did not fire exactly once")
                }
                return
            }
            try advanceList(host, scroll: scroll)
            tree = try await snapshot(host, name: name + "-step-\(step)", capture: false)
        }
        throw MiniPlayerAccessibilityHost.failure(
            "List calibration exhausted 240 steps without stable actual bottom")
    }
}

/// Test-only synchronous processor gate. Timeout throws; it can never create a passing status fixture.
private final class HomeNormalizationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var entered = false
    var hasEntered: Bool {
        condition.lock(); defer { condition.unlock() }
        return entered
    }
    func wait() throws {
        condition.lock(); defer { condition.unlock() }
        entered = true
        let deadline = Date().addingTimeInterval(180)
        while !released {
            guard condition.wait(until: deadline) else { throw CancellationError() }
        }
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        released = true
        condition.broadcast()
    }
}

@MainActor
private final class HomeFrameMeasurement {
    var size: CGSize?
}

// Real processor -> manager -> MusicHomeView.
// A disabled normalization pipeline cannot satisfy the progress/completion guards.
extension MusicHomePresentationTests {
    func testSuccessfulNormalizationPresentationIsHiddenWhileProcessingRemainsVisible() {
        let completed = MusicLoudnessLibraryProgressPresentation(
            isNormalizing: false, completedCount: 1, totalCount: 1)
        XCTAssertFalse(completed.showsStatus, "COMPLETION_RED: successful status must be hidden")
        XCTAssertFalse(completed.showsProgressIndicator)
        XCTAssertNil(completed.message, "COMPLETION_RED: successful status must have no presented message")
        let processing = MusicLoudnessLibraryProgressPresentation(
            isNormalizing: true, completedCount: 1, totalCount: 2)
        XCTAssertTrue(processing.showsStatus)
        XCTAssertTrue(processing.showsProgressIndicator)
        XCTAssertEqual(processing.message, "正在统一音量 1/2")
    }

    func testHostedMusicDirectoryHidesSuccessfulNormalizationButRetainsProcessing() async throws {
        let suite = "HomeCompletionRemoval.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let filterKey = MusicLibraryFilterPreferenceStore.key
        let previousFilter = UserDefaults.standard.object(forKey: filterKey)
        MusicLibraryFilterPreferenceStore(defaults: .standard).save(.all)
        defer {
            if let previousFilter { UserDefaults.standard.set(previousFilter, forKey: filterKey) }
            else { UserDefaults.standard.removeObject(forKey: filterKey) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let audio = root.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let source = audio.appendingPathComponent("completion-contract.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132_300))
        buffer.frameLength = 132_300
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(buffer.frameLength) {
            samples[index] = Float(0.05 * sin(2 * Double.pi * 440 * Double(index) / 44_100))
        }
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        let originalBytes = try Data(contentsOf: source)
        let library = MusicLibrary(storage: MediaLibraryStorage(
            rootURL: audio, legacyAudioURL: root.appendingPathComponent("LegacyAudio"),
            legacyVideoURL: root.appendingPathComponent("LegacyVideo")),
            metadataLoader: MusicMetadataLoader(rawItemLoader: { _ in [] }),
            metadataSnapshotStore: MediaMetadataSnapshotStore(fileURL: root.appendingPathComponent("metadata.json")),
            durationLoader: { _ in 3 }, lyricSidecarLoader: { _ in nil })
        let publication = await library.refresh()
        guard publication.isAuthoritative, library.songs.count == 1 else {
            throw MiniPlayerAccessibilityHost.failure("Completion fixture library failed")
        }
        let gate = HomeNormalizationGate()
        defer { gate.release() }
        let settings = try XCTUnwrap(MusicLoudnessNormalizationSettings(
            targetIntegratedLevelDBFS: -16, truePeakCeilingDBTP: -1.5, maximumBoostDB: 12, algorithmVersion: 1))
        // Preserve directory URL identity for the coordinator's snapshot-parent guard.
        let coordinator = MusicLoudnessCacheCoordinator(cacheRootURL: root.appendingPathComponent("Cache", isDirectory: true),
            settings: settings, processor: { source, destination, settings in
                try gate.wait()
                return try MusicLoudnessOfflineProcessor.process(
                    sourceURL: source, destinationURL: destination, settings: settings)
            })
        let player = AVPlayer()
        player.isMuted = true
        let playback = MusicPlaybackManager(player: player, defaults: defaults,
            ownership: PlaybackOwnershipCoordinator(), loudnessCoordinator: coordinator,
            activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController())
        defer { playback.updateQueue([]); player.replaceCurrentItem(with: nil) }
        playback.updateQueue(library.songs)
        let entered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated { gate.hasEntered && playback.isNormalizingLoudnessLibrary }
        }, object: nil)
        guard await XCTWaiter.fulfillment(of: [entered], timeout: 10) == .completed else {
            throw MiniPlayerAccessibilityHost.failure("Real normalization never started")
        }
        let host = try MiniPlayerAccessibilityHost(content: MusicHomeView(
            library: library, playback: playback, favorites: MusicFavoritesStore(defaults: defaults),
            recentlyPlayed: MusicRecentlyPlayedStore(defaults: defaults),
            playlists: MusicPlaylistStore(defaults: defaults)), viewportWidth: 390, viewportHeight: 568)
        defer { host.close() }
        let processing = try await host.layoutSnapshot()
        guard processing.contains(where: { $0.label.contains("正在统一音量 0/1") }) else {
            throw MiniPlayerAccessibilityHost.failure("Real processing presentation is unreadable or missing")
        }
        XCTAssertFalse(processing.contains { $0.label.contains("驾驶模式") ||
            ($0.identifier?.hasPrefix("driving-mode-") ?? false) })
        gate.release()
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                !playback.isNormalizingLoudnessLibrary &&
                playback.loudnessNormalizationCompletedCount == 1 &&
                playback.loudnessNormalizationTotalCount == 1
            }
        }, object: nil)
        guard await XCTWaiter.fulfillment(of: [completed], timeout: 20) == .completed else {
            throw MiniPlayerAccessibilityHost.failure("Real successful normalization never completed 1/1")
        }
        let finished = try await host.layoutSnapshot()
        // Positive content check prevents an empty/unmounted host passing absence.
        XCTAssertTrue(finished.contains { $0.label.contains("completion-contract") })
        XCTAssertFalse(finished.contains { $0.label.contains("音量统一完成") },
            "COMPLETION_RED: successful normalization must not leave a completion banner in the music directory")
        XCTAssertFalse(finished.contains { $0.label.contains("正在统一音量") })
        XCTAssertEqual(playback.queue.count, 1)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        add(try host.renderedAttachment(name: "normalization-complete-directory"))
    }
}

// Render the production library inside a real TabView: selection drives SwiftUI
// appearance, without directly invoking a scroll helper or a lifecycle callback.
extension MusicHomePresentationTests {
    func testMusicTabArrivalLocatesDistantCurrentRowAndReentryRespectsBrowsing() async throws {
        try await checkMusicTabArrival(emptyFavorites: false)
    }

    func testMusicTabArrivalDoesNotChangeFilterToRevealCurrentRow() async throws {
        try await checkMusicTabArrival(emptyFavorites: true)
    }

    private func checkMusicTabArrival(emptyFavorites: Bool) async throws {
        let suite = "MusicTabArrival.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let filterKey = MusicLibraryFilterPreferenceStore.key
        let previousFilter = UserDefaults.standard.object(forKey: filterKey)
        MusicLibraryFilterPreferenceStore(defaults: .standard).save(emptyFavorites ? .favorites : .all)
        defer {
            if let previousFilter { UserDefaults.standard.set(previousFilter, forKey: filterKey) }
            else { UserDefaults.standard.removeObject(forKey: filterKey) }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let audio = root.appendingPathComponent("Audio")
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 80_000))
        buffer.frameLength = 80_000
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(buffer.frameLength) { samples[index] = 0 }
        for index in 0..<60 {
            let file = try AVAudioFile(forWriting: audio.appendingPathComponent(
                String(format: "%02d-arrival.wav", index)), settings: format.settings)
            try file.write(from: buffer)
        }
        let library = MusicLibrary(storage: MediaLibraryStorage(
            rootURL: audio, legacyAudioURL: root.appendingPathComponent("LegacyAudio"),
            legacyVideoURL: root.appendingPathComponent("LegacyVideo")),
            metadataLoader: MusicMetadataLoader(rawItemLoader: { _ in [] }),
            metadataSnapshotStore: MediaMetadataSnapshotStore(fileURL: root.appendingPathComponent("metadata.json")),
            durationLoader: { _ in 10 }, lyricSidecarLoader: { _ in nil })
        let publication = await library.refresh()
        guard publication.isAuthoritative, library.songs.count == 60 else {
            throw MiniPlayerAccessibilityHost.failure("Arrival library fixture failed")
        }
        let player = AVPlayer()
        player.isMuted = true
        let playback = MusicPlaybackManager(player: player, defaults: defaults,
            ownership: PlaybackOwnershipCoordinator(), activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController())
        defer { playback.updateQueue([]); player.replaceCurrentItem(with: nil) }
        playback.updateQueue(library.songs)
        let target = library.songs[50]
        playback.play(target)
        playback.pause()
        XCTAssertEqual(playback.currentTrack?.id, target.id)
        let selection = MusicArrivalTabSelection()
        let host = try MiniPlayerAccessibilityHost(content: MusicArrivalTabHost(
            selection: selection,
            home: MusicHomeView(library: library, playback: playback,
                favorites: MusicFavoritesStore(defaults: defaults),
                recentlyPlayed: MusicRecentlyPlayedStore(defaults: defaults),
                playlists: MusicPlaylistStore(defaults: defaults))),
            viewportWidth: 390, viewportHeight: 568)
        defer { host.close() }
        _ = try await host.layoutSnapshot()
        let originalItem = player.currentItem
        let originalTime = player.currentTime().seconds
        let originalQueue = playback.queue
        selection.tab = 1
        let tree = try await host.layoutSnapshot()
        let scroll = try XCTUnwrap(host.outerScrollView)
        func isVisible(_ song: MusicItem, in elements: [MiniPlayerAccessibilityHost.Element]) throws -> Bool {
            guard let row = elements.first(where: { $0.identifier == "music-library-favorite-\(song.id)" }) else {
                return false
            }
            return host.visibleScrollFrame(scroll).contains(try host.validatedFrame(row))
        }
        add(try host.renderedAttachment(name: "music-tab-first-arrival"))
        XCTAssertTrue(player.currentItem === originalItem)
        XCTAssertEqual(player.currentTime().seconds, originalTime, accuracy: 0.1)
        XCTAssertEqual(playback.queue, originalQueue)
        XCTAssertFalse(playback.isPlaying)
        if emptyFavorites {
            XCTAssertFalse(try isVisible(target, in: tree))
            XCTAssertEqual(MusicLibraryFilterPreferenceStore(defaults: .standard).load(), .favorites)
            XCTAssertFalse(tree.contains { $0.identifier?.hasPrefix("music-library-favorite-") == true })
            return
        }
        XCTAssertTrue(try isVisible(target, in: tree), "ARRIVAL_RED: first music tab selection must reveal the distant current row")
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: false)
        let browsed = try await host.layoutSnapshot()
        XCTAssertTrue(try isVisible(library.songs[0], in: browsed))
        XCTAssertFalse(try isVisible(target, in: browsed))
        let offset = scroll.contentOffset.y
        let next = library.songs[55]
        playback.play(next)
        playback.pause()
        _ = try await host.layoutSnapshot()
        XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 1, "Track changes must not interrupt browsing")
        selection.tab = 0
        _ = try await host.layoutSnapshot()
        let reentryItem = player.currentItem
        let reentryTime = player.currentTime().seconds
        selection.tab = 1
        let reentered = try await host.layoutSnapshot()
        XCTAssertTrue(try isVisible(next, in: reentered), "Reentry must locate the newly current row")
        XCTAssertTrue(player.currentItem === reentryItem)
        XCTAssertEqual(player.currentTime().seconds, reentryTime, accuracy: 0.1)
        XCTAssertEqual(playback.queue, originalQueue)
        XCTAssertFalse(playback.isPlaying)
    }
}

@MainActor
private final class MusicArrivalTabSelection: ObservableObject {
    @Published var tab = 0
}

@MainActor
private struct MusicArrivalTabHost: View {
    @ObservedObject var selection: MusicArrivalTabSelection
    let home: MusicHomeView

    var body: some View {
        TabView(selection: $selection.tab) {
            Text("Video tab fixture").tabItem { Label("视频", systemImage: "play.rectangle") }.tag(0)
            home.tabItem { Label("音乐", systemImage: "music.note.list") }.tag(1)
        }
    }
}
