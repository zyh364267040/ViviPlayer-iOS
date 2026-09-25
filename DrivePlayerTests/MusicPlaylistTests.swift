import AVFoundation
import Combine
import XCTest
@testable import DrivePlayer

@MainActor
final class MusicPlaylistTests: XCTestCase {
    // Investigative characterization at f7fbbea: no elapsed-time pass/fail thresholds.
    // Only the readability scan is CPU-isolated; AVPlayer, stat and defaults remain real.
    func testLargeLibraryPlaybackInvestigationStubReadability() throws {
        for count in [100, 1_000, 5_000] {
            try investigatePlayback(count: count, stubReadability: true)
        }
    }

    func testLargeLibraryPlaybackInvestigationRealIO() throws {
        // Same 100-item workload as the stub case, using the private production predicate.
        try investigatePlayback(count: 100, stubReadability: false)
    }

    func testLargeLibraryFirstCheapRefreshInvestigationRealIO() async throws {
        let root = try makePerformanceDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        let (items, bytes) = try makePerformanceMedia(count: 100, directory: documents)
        let gate = CheapPublicationEnrichmentGate()
        defer { gate.release() }
        let blocked = expectation(description: "First sidecar enrichment is gated")
        let library = MusicLibrary(
            storage: MediaLibraryStorage(
                rootURL: documents,
                legacyAudioURL: root.appendingPathComponent("UnusedLegacyAudio"),
                legacyVideoURL: root.appendingPathComponent("UnusedLegacyVideo")
            ),
            metadataSnapshotStore: MediaMetadataSnapshotStore(
                fileURL: root.appendingPathComponent("metadata.json")
            ),
            durationLoader: { _ in 0.1 },
            maximumConcurrentEnrichmentCount: 1,
            lyricSidecarLoader: { _ in
                await gate.wait(entered: blocked)
                return nil
            }
        )
        let published = expectation(description: "First cheap rows published")
        var elapsed: Double?
        var cheapRows: [MusicItem] = []
        var start: UInt64 = 0
        let observation = library.$latestReconciliationPublication
            .filter { !$0.songs.isEmpty && !$0.reconciliationSnapshot.isAuthoritative }
            .prefix(1)
            .sink { publication in
                elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                cheapRows = publication.songs
                published.fulfill()
            }
        defer { observation.cancel() }
        start = DispatchTime.now().uptimeNanoseconds
        let refresh = Task { await library.refresh() }
        defer { refresh.cancel(); gate.release() }
        // This is a deadlock guard, not a performance acceptance threshold.
        await fulfillment(of: [published, blocked], timeout: 30)
        XCTAssertTrue(library.isLoading)
        XCTAssertTrue(gate.isWaiting)
        XCTAssertEqual(cheapRows.map(\.fileName), items.map(\.fileName))
        XCTAssertTrue(cheapRows.allSatisfy { $0.duration == nil && $0.favoriteSourceIdentity == nil })
        if let elapsed {
            print("[LargeLibrary CHECK] io=real-scan operation=first-cheap-publication n=100 repetitions=1 total_ms=\(elapsed) readability_calls=not-applicable enrichment=gated")
        } else {
            XCTFail("No cheap publication timing captured")
        }
        // Cancel and drain before removing fixtures; do not measure full enrichment here.
        refresh.cancel()
        gate.release()
        _ = await refresh.value
        XCTAssertFalse(library.isLoading)
        for item in items { XCTAssertEqual(try Data(contentsOf: item.url), bytes) }
    }

    func testShuffleDisabledLibraryAndDirectPlaySkipReadabilityAndPreserveSelectionAndOrder() throws {
        let root = try makePerformanceDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let (items, bytes) = try makePerformanceMedia(count: 3, directory: root)
        // Deliberately non-filename order so accidental queue sorting is observable.
        let ordered = [items[2], items[0], items[1]]
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        var readabilityCalls = 0
        let player = AVPlayer()
        player.isMuted = true
        let manager = MusicPlaybackManager(
            player: player, defaults: defaults, activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            shuffleOrdering: { $0 },
            isShuffleTrackReadable: { _ in
                readabilityCalls += 1
                return true
            }
        )
        defer { manager.pause(); player.replaceCurrentItem(with: nil) }
        XCTAssertFalse(manager.isShuffleEnabled)

        func assertSelection(_ selected: MusicItem, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(manager.currentTrack?.url, selected.url, file: file, line: line)
            let currentItem = try XCTUnwrap(player.currentItem, file: file, line: line)
            let asset = try XCTUnwrap(currentItem.asset as? AVURLAsset, file: file, line: line)
            XCTAssertEqual(asset.url, selected.url, file: file, line: line)
            XCTAssertEqual(manager.queue, ordered, file: file, line: line)
            XCTAssertEqual(manager.queueScope, .fullLibrary, file: file, line: line)
            XCTAssertFalse(manager.isShuffleEnabled, file: file, line: line)
        }

        // Count only each explicit selection, including applyQueue for library taps.
        readabilityCalls = 0
        manager.playFromLibrary(ordered[2], library: ordered)
        XCTAssertEqual(readabilityCalls, 0, "Cold library selection must skip shuffle readability")
        try assertSelection(ordered[2])

        readabilityCalls = 0
        manager.playFromLibrary(ordered[1], library: ordered)
        XCTAssertEqual(readabilityCalls, 0, "Warm library selection must skip shuffle readability")
        try assertSelection(ordered[1])

        readabilityCalls = 0
        manager.play(ordered[0])
        XCTAssertEqual(readabilityCalls, 0, "Direct selection must skip shuffle readability")
        try assertSelection(ordered[0])

        // Check sequential playback order without constraining other operations' scans.
        manager.next()
        try assertSelection(ordered[1])
        manager.next()
        try assertSelection(ordered[2])
        for item in items { XCTAssertEqual(try Data(contentsOf: item.url), bytes) }
    }

    private func investigatePlayback(count: Int, stubReadability: Bool) throws {
        let root = try makePerformanceDirectory()
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: root)) }
        let (items, bytes) = try makePerformanceMedia(count: count, directory: root)
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        var readabilityCalls = 0
        let probe: ((URL) -> Bool)? = stubReadability ? { _ in
            readabilityCalls += 1
            return true
        } : nil
        let player = AVPlayer()
        player.isMuted = true
        let manager = MusicPlaybackManager(
            player: player, defaults: defaults, activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            shuffleOrdering: { $0 }, isShuffleTrackReadable: probe
        )
        defer { manager.pause(); player.replaceCurrentItem(with: nil) }
        let io = stubReadability ? "stub-readable-true" : "real-production-readability"
        func timed(_ operation: String, repetitions: Int, expectedCalls: Int, body: () -> Void) {
            readabilityCalls = 0
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let calls = stubReadability ? String(readabilityCalls) : "unobservable-private-predicate"
            print("[LargeLibrary CHECK] io=\(io) operation=\(operation) n=\(count) repetitions=\(repetitions) total_ms=\(ms) mean_ms=\(ms / Double(repetitions)) readability_calls=\(calls)")
            if stubReadability { XCTAssertEqual(readabilityCalls, expectedCalls, operation) }
        }
        // A cold row action includes queue installation as well as direct selection.
        timed("cold-playFromLibrary-last", repetitions: 1, expectedCalls: 0) {
            manager.playFromLibrary(items[count - 1], library: items)
        }
        XCTAssertEqual(manager.currentTrack?.url, items[count - 1].url)
        XCTAssertEqual(manager.trackLoadGeneration, 1)
        timed("warm-playFromLibrary-middle", repetitions: 1, expectedCalls: 0) {
            manager.playFromLibrary(items[count / 2], library: items)
        }
        XCTAssertEqual(manager.currentTrack?.url, items[count / 2].url)
        XCTAssertEqual(manager.trackLoadGeneration, 2)
        timed("direct-play-last", repetitions: 1, expectedCalls: 0) {
            manager.play(items[count - 1])
        }
        XCTAssertEqual(manager.currentTrack?.url, items[count - 1].url)
        let repetitions = 20
        var visited: [String] = []
        visited.reserveCapacity(repetitions)
        var generation = manager.trackLoadGeneration
        timed("sequential-next", repetitions: repetitions, expectedCalls: 0) {
            for _ in 0..<repetitions {
                manager.next()
                visited.append(manager.currentTrack?.fileName ?? "<missing>")
            }
        }
        XCTAssertEqual(visited, Array(items.prefix(repetitions)).map(\.fileName))
        XCTAssertEqual(manager.trackLoadGeneration, generation + UInt64(repetitions))
        timed("enable-shuffle", repetitions: 1, expectedCalls: count) {
            manager.setShuffleEnabled(true)
        }
        XCTAssertTrue(manager.isShuffleEnabled)
        visited.removeAll(keepingCapacity: true)
        generation = manager.trackLoadGeneration
        timed("shuffle-next", repetitions: repetitions, expectedCalls: repetitions * count) {
            for _ in 0..<repetitions {
                manager.next()
                visited.append(manager.currentTrack?.fileName ?? "<missing>")
            }
        }
        // Identity ordering visits 0...18, then skips the prior current item 19 for 20.
        let expected = Array(items.prefix(repetitions - 1)) + [items[repetitions]]
        XCTAssertEqual(visited, expected.map(\.fileName))
        XCTAssertEqual(Set(visited).count, repetitions)
        XCTAssertEqual(manager.trackLoadGeneration, generation + UInt64(repetitions))
        XCTAssertEqual(manager.queue, items)
        XCTAssertEqual(manager.queueScope, .fullLibrary)
        XCTAssertEqual((player.currentItem?.asset as? AVURLAsset)?.url, items[repetitions].url)
        manager.pause()
        player.replaceCurrentItem(with: nil)
        // Byte verification and all fixture creation are outside measured intervals.
        for item in items { XCTAssertEqual(try Data(contentsOf: item.url), bytes) }
    }

    private func makePerformanceDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrivePlayerPerformance-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makePerformanceMedia(count: Int, directory: URL) throws -> ([MusicItem], Data) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstURL = directory.appendingPathComponent("track-00000.wav")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800))
        buffer.frameLength = 800
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<800 { samples[frame] = 0 }
        // Close the writer before reading its finalized WAV bytes.
        do {
            let file = try AVAudioFile(forWriting: firstURL, settings: format.settings)
            try file.write(from: buffer)
        }
        let bytes = try Data(contentsOf: firstURL)
        let items = try (0..<count).map { index in
            let url = directory.appendingPathComponent(String(format: "track-%05d.wav", index))
            if index != 0 { try bytes.write(to: url) }
            return MusicItem(url: url, duration: 0.1)
        }
        return (items, bytes)
    }

    private actor FingerprintGate {
        private var continuations: [String: CheckedContinuation<Bool, Never>] = [:]

        func wait(_ name: String) async -> Bool {
            await withCheckedContinuation { continuations[name] = $0 }
        }

        func release(_ name: String, valid: Bool = true) {
            continuations.removeValue(forKey: name)?.resume(returning: valid)
        }
    }

    func testRollbackRepairModeClearsOnlyExactJournalAndPreservesMembership() throws {
        let suite = "MusicPlaylistRollbackMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        var rejectClear = false
        let store = MusicPlaylistStore(defaults: defaults) { data in
            if rejectClear,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["pendingDeletion"] is NSNull || object["pendingDeletion"] == nil { return false }
            defaults.set(data, forKey: MusicPlaylistStore.persistenceKey)
            return defaults.data(forKey: MusicPlaylistStore.persistenceKey) == data
        }
        let playlist = try XCTUnwrap(store.create(name: "Rollback"))
        let song = item("rollback-mode.mp3", byte: "r")
        XCTAssertTrue(store.add(song, to: playlist.id)); XCTAssertTrue(store.prepareMediaDeletion(song))
        XCTAssertTrue(store.markMediaDeletionRollbackRequired(song))
        rejectClear = true
        XCTAssertFalse(store.retryDeletedMembershipRepair(song, mode: .rollback))
        XCTAssertEqual(store.pendingDeletionRepairMode, .rollback)
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), [song.fileName])
        XCTAssertTrue(FileManager.default.fileExists(atPath: song.url.path))
        rejectClear = false
        XCTAssertTrue(store.retryDeletedMembershipRepair(song, mode: .rollback))
        XCTAssertNil(store.pendingDeletionRepairMode)
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), [song.fileName])
        XCTAssertFalse(store.retryDeletedMembershipRepair(song, mode: .finalize))
    }

    func testCoordinatorRollbackClearFailureRetriesWithoutDeletionSuccessCopy() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("PlaylistRollback-\(UUID().uuidString)", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = documents.appendingPathComponent("rollback.mp3"); try Data("rollback".utf8).write(to: source)
        struct InjectedUnlinkFailure: Error {}
        var failUnlink = true
        let storage = MediaLibraryStorage(
            rootURL: documents, legacyAudioURL: root.appendingPathComponent("OldAudio"),
            legacyVideoURL: root.appendingPathComponent("OldVideo"), preUnlink: { if failUnlink { throw InjectedUnlinkFailure() } }
        )
        let library = MusicLibrary(storage: storage, durationLoader: { _ in 30 })
        _ = await library.refresh(); let song = try XCTUnwrap(library.songs.first)
        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        var rejectJournalClear = false
        let playlists = MusicPlaylistStore(defaults: defaults) { data in
            if rejectJournalClear,
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               root["pendingDeletion"] == nil { return false }
            defaults.set(data, forKey: MusicPlaylistStore.persistenceKey); return true
        }
        let playlist = try XCTUnwrap(playlists.create(name: "Rollback coordinator")); XCTAssertTrue(playlists.add(song, to: playlist.id))
        rejectJournalClear = true
        do {
            try await MusicDeletionCoordinator.delete(
                song, library: library,
                playback: MusicPlaybackManager(defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController()),
                favorites: MusicFavoritesStore(defaults: defaults), playlists: playlists
            )
            XCTFail("Rollback-clear failure must surface")
        } catch let error as MusicPlaylistDeletionPersistenceError {
            guard case .rollbackClearFailed = error else { return XCTFail("Wrong route: \(error)") }
            XCTAssertEqual(error.repairMode, .rollback)
            XCTAssertEqual(MusicPlaylistDeletionFeedback.presentation(for: error, repaired: true).title, "删除未完成")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(playlists.playlist(id: playlist.id)?.members.map(\.fileName), [song.fileName])
        XCTAssertEqual(playlists.pendingDeletionRepairMode, .rollback)
        rejectJournalClear = false
        XCTAssertTrue(playlists.retryDeletedMembershipRepair(song, mode: .rollback))
        XCTAssertNil(playlists.pendingDeletionRepairMode)
        XCTAssertEqual(playlists.playlist(id: playlist.id)?.members.map(\.fileName), [song.fileName])
        failUnlink = false
        try await MusicDeletionCoordinator.delete(
            song, library: library,
            playback: MusicPlaybackManager(defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController()),
            favorites: MusicFavoritesStore(defaults: defaults), playlists: playlists
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(playlists.playlist(id: playlist.id)?.members.isEmpty == true)
    }

    func testCoordinatorDeletesNonmemberWithoutCreatingPlaylistRepairWork() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("PlaylistNonmemberDelete-\(UUID().uuidString)", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("target".utf8).write(to: documents.appendingPathComponent("target.mp3"))
        try Data("member".utf8).write(to: documents.appendingPathComponent("member.mp3"))
        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: root.appendingPathComponent("OldAudio"),
            legacyVideoURL: root.appendingPathComponent("OldVideo")
        )
        let library = MusicLibrary(storage: storage, durationLoader: { _ in 30 })
        _ = await library.refresh()
        let target = try XCTUnwrap(library.songs.first { $0.fileName == "target.mp3" })
        let member = try XCTUnwrap(library.songs.first { $0.fileName == "member.mp3" })
        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        let playlists = MusicPlaylistStore(defaults: defaults)
        let playlist = try XCTUnwrap(playlists.create(name: "Unrelated"))
        XCTAssertTrue(playlists.add(member, to: playlist.id))
        let bytes = playlists.persistedPayloadData
        let revision = playlists.revision

        try await MusicDeletionCoordinator.delete(
            target,
            library: library,
            playback: MusicPlaybackManager(
                defaults: defaults,
                activateAudioSession: {},
                nowPlayingController: RecordingNowPlayingController()
            ),
            favorites: MusicFavoritesStore(defaults: defaults),
            playlists: playlists
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.url.path))
        XCTAssertEqual(library.songs.map(\.fileName), [member.fileName])
        XCTAssertEqual(playlists.persistedPayloadData, bytes)
        XCTAssertEqual(playlists.revision, revision)
        XCTAssertFalse(playlists.hasPendingMediaDeletion)
        XCTAssertFalse(playlists.reconciliationNeedsRepair)
        XCTAssertEqual(playlists.playlist(id: playlist.id)?.members.map(\.fileName), [member.fileName])
    }

    func testCoordinatorTreatsPostUnlinkReconciliationAsSuccessfulRepair() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("PlaylistPostUnlinkRepair-\(UUID().uuidString)", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("member".utf8).write(to: documents.appendingPathComponent("member.mp3"))
        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: root.appendingPathComponent("OldAudio"),
            legacyVideoURL: root.appendingPathComponent("OldVideo")
        )
        let library = MusicLibrary(storage: storage, durationLoader: { _ in 30 })
        _ = await library.refresh()
        let song = try XCTUnwrap(library.songs.first)
        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        var rejectedFinalizePhaseOnce = false
        let playlists = MusicPlaylistStore(defaults: defaults) { data in
            if !rejectedFinalizePhaseOnce,
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let journal = root["pendingDeletion"] as? [String: Any],
               journal["phase"] as? String == "finalizeRequired" {
                rejectedFinalizePhaseOnce = true
                return false
            }
            defaults.set(data, forKey: MusicPlaylistStore.persistenceKey)
            return defaults.data(forKey: MusicPlaylistStore.persistenceKey) == data
        }
        let playlist = try XCTUnwrap(playlists.create(name: "Repair during refresh"))
        XCTAssertTrue(playlists.add(song, to: playlist.id))
        var feedback: MusicImportFeedback?

        do {
            try await MusicDeletionCoordinator.delete(
                song,
                library: library,
                playback: MusicPlaybackManager(
                    defaults: defaults,
                    activateAudioSession: {},
                    nowPlayingController: RecordingNowPlayingController()
                ),
                favorites: MusicFavoritesStore(defaults: defaults),
                playlists: playlists
            )
        } catch let deletionError as MusicPlaylistDeletionPersistenceError {
            let repaired = deletionError.repairMode.map {
                playlists.retryDeletedMembershipRepair(song, mode: $0)
            } ?? false
            feedback = MusicPlaylistDeletionFeedback.presentation(for: deletionError, repaired: repaired)
        }

        XCTAssertTrue(rejectedFinalizePhaseOnce)
        XCTAssertFalse(FileManager.default.fileExists(atPath: song.url.path))
        XCTAssertTrue(playlists.playlist(id: playlist.id)?.members.isEmpty == true)
        XCTAssertFalse(playlists.hasPendingMediaDeletion)
        XCTAssertFalse(playlists.reconciliationNeedsRepair)
        XCTAssertNil(feedback)
        let reconstructed = MusicPlaylistStore(defaults: defaults)
        XCTAssertTrue(reconstructed.playlist(id: playlist.id)?.members.isEmpty == true)
        XCTAssertFalse(reconstructed.hasPendingMediaDeletion)
        XCTAssertFalse(reconstructed.reconciliationNeedsRepair)
    }

    func testDeletionJournalPhaseFailureKeepsRepairVisibleUntilExactRetryConverges() throws {
        let suite = "MusicPlaylistJournalPhaseRepair.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var rejectFinalizePhase = false
        let store = MusicPlaylistStore(defaults: defaults) { data in
            if rejectFinalizePhase,
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let journal = root["pendingDeletion"] as? [String: Any],
               journal["phase"] as? String == "finalizeRequired" {
                return false
            }
            defaults.set(data, forKey: MusicPlaylistStore.persistenceKey)
            return defaults.data(forKey: MusicPlaylistStore.persistenceKey) == data
        }
        let playlist = try XCTUnwrap(store.create(name: "Phase repair"))
        let song = item("phase-repair.mp3", byte: "p")
        XCTAssertTrue(store.add(song, to: playlist.id))

        XCTAssertTrue(store.prepareMediaDeletion(song))
        XCTAssertFalse(store.reconciliationNeedsRepair)
        rejectFinalizePhase = true
        try FileManager.default.removeItem(at: song.url)
        XCTAssertFalse(store.markMediaDeletionUnlinked(song))
        XCTAssertFalse(store.markMediaDeletionUnlinked(song))
        XCTAssertTrue(store.hasPendingMediaDeletion)
        XCTAssertTrue(store.reconciliationNeedsRepair)
        XCTAssertTrue(MusicPlaylistReconciliationPresentation(
            isRepairRequired: store.reconciliationNeedsRepair
        ).showsStatus)

        rejectFinalizePhase = false
        XCTAssertTrue(store.retryDeletedMembershipRepair(song, mode: .finalize))
        XCTAssertFalse(store.hasPendingMediaDeletion)
        XCTAssertFalse(store.reconciliationNeedsRepair)
        XCTAssertTrue(store.playlist(id: playlist.id)?.members.isEmpty == true)

        let control = item("phase-control.mp3", byte: "c")
        XCTAssertTrue(store.add(control, to: playlist.id))
        XCTAssertTrue(store.prepareMediaDeletion(control))
        XCTAssertFalse(store.reconciliationNeedsRepair)
        try FileManager.default.removeItem(at: control.url)
        XCTAssertTrue(store.markMediaDeletionUnlinked(control))
        XCTAssertTrue(store.finalizeMediaDeletion(control))
        XCTAssertFalse(store.hasPendingMediaDeletion)
        XCTAssertFalse(store.reconciliationNeedsRepair)
    }

    func testDeletionJournalPhaseIsStrictlyDecodedAndLegacyRevisionFieldRejected() throws {
        let suite = "MusicPlaylistJournalPhase.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let seed = MusicPlaylistStore(defaults: defaults)
        let playlist = try XCTUnwrap(seed.create(name: "Phase")); let song = item("phase.mp3", byte: "p")
        XCTAssertTrue(seed.add(song, to: playlist.id)); XCTAssertTrue(seed.prepareMediaDeletion(song))
        let valid = try XCTUnwrap(seed.persistedPayloadData)
        for mutation in 0..<2 {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
            var journal = try XCTUnwrap(root["pendingDeletion"] as? [String: Any])
            if mutation == 0 { journal["phase"] = "unknown-future-phase" }
            else { journal["storeRevision"] = 7 }
            root["pendingDeletion"] = journal
            defaults.set(try JSONSerialization.data(withJSONObject: root), forKey: MusicPlaylistStore.persistenceKey)
            XCTAssertTrue(MusicPlaylistStore(defaults: defaults).playlists.isEmpty)
        }
    }

    func testAddCoordinatorPublishesTypedTerminalOutcomesExactlyOnce() async throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let playlist = try XCTUnwrap(store.create(name: "Outcomes")), song = item("outcome.mp3", byte: "o")
        let publication = MusicLibraryPublication(generation: 1, reconciliationSnapshot: .init(songs: [song]), songs: [song])
        let intent = try XCTUnwrap(MusicPlaylistLibraryIndex(library: [song]).addRows(
            for: playlist, storeRevision: store.revision, publicationGeneration: 1
        ).first?.actionIntent)
        let gate = FingerprintGate(), started = expectation(description: "validation")
        let coordinator = MusicPlaylistAddCoordinator(
            playlistID: playlist.id, storeRevision: store.revision, libraryGeneration: 1,
            validator: { item in started.fulfill(); return await gate.wait(item.fileName) }
        )
        XCTAssertTrue(coordinator.enqueue(intent, store: store, publication: publication))
        await fulfillment(of: [started], timeout: 1); await gate.release(song.fileName, valid: false)
        let failed = await coordinator.nextOutcome()
        XCTAssertEqual(failed, .failure(songID: song.id, reason: .replacedSource, generation: 0))
        XCTAssertNil(coordinator.consumeOutcome())
        XCTAssertEqual(coordinator.pendingWorkCount, 0)
        XCTAssertFalse(coordinator.hasPendingRequests)

        coordinator.reset(storeRevision: store.revision, libraryGeneration: 1)
        XCTAssertTrue(coordinator.enqueue(intent, store: store, publication: publication))
        coordinator.cancel()
        XCTAssertNil(coordinator.consumeOutcome())
        XCTAssertEqual(coordinator.pendingWorkCount, 0)
        XCTAssertFalse(coordinator.hasPendingRequests)
    }

    func testAddCoordinatorReportsStalePersistenceAndSuccessOutcomes() async throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let playlist = try XCTUnwrap(store.create(name: "Outcome states")), song = item("outcome-states.mp3", byte: "s")
        let publication = MusicLibraryPublication(generation: 1, reconciliationSnapshot: .init(songs: [song]), songs: [song])
        let intent = try XCTUnwrap(MusicPlaylistLibraryIndex(library: [song]).addRows(
            for: playlist, storeRevision: store.revision, publicationGeneration: 1
        ).first?.actionIntent)
        let gate = FingerprintGate(), started = expectation(description: "stale validation")
        let stale = MusicPlaylistAddCoordinator(
            playlistID: playlist.id, storeRevision: store.revision, libraryGeneration: 1,
            validator: { item in started.fulfill(); return await gate.wait(item.fileName) }
        )
        XCTAssertTrue(stale.enqueue(intent, store: store, publication: publication))
        await fulfillment(of: [started], timeout: 1)
        XCTAssertNotNil(store.create(name: "External mutation"))
        await gate.release(song.fileName)
        let staleOutcome = await stale.nextOutcome()
        XCTAssertEqual(staleOutcome, .failure(songID: song.id, reason: .staleState, generation: 0))
        XCTAssertEqual(stale.pendingWorkCount, 0)

        let suite = "MusicPlaylistOutcomePersistence.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        var rejectWrites = false
        let failingStore = MusicPlaylistStore(defaults: defaults) { data in
            guard !rejectWrites else { return false }
            defaults.set(data, forKey: MusicPlaylistStore.persistenceKey); return true
        }
        let failingPlaylist = try XCTUnwrap(failingStore.create(name: "Persistence"))
        let failingSong = item("outcome-persistence.mp3", byte: "p")
        let failingPublication = MusicLibraryPublication(generation: 2, reconciliationSnapshot: .init(songs: [failingSong]), songs: [failingSong])
        let failingIntent = try XCTUnwrap(MusicPlaylistLibraryIndex(library: [failingSong]).addRows(
            for: failingPlaylist, storeRevision: failingStore.revision, publicationGeneration: 2
        ).first?.actionIntent)
        let persistence = MusicPlaylistAddCoordinator(
            playlistID: failingPlaylist.id, storeRevision: failingStore.revision, libraryGeneration: 2,
            validator: { _ in true }
        )
        rejectWrites = true
        XCTAssertTrue(persistence.enqueue(failingIntent, store: failingStore, publication: failingPublication))
        let persistenceOutcome = await persistence.nextOutcome()
        XCTAssertEqual(persistenceOutcome, .failure(songID: failingSong.id, reason: .persistenceFailure, generation: 0))
        XCTAssertTrue(failingStore.playlist(id: failingPlaylist.id)?.members.isEmpty == true)
        rejectWrites = false
        persistence.reset(storeRevision: failingStore.revision, libraryGeneration: 2)
        XCTAssertTrue(persistence.enqueue(failingIntent, store: failingStore, publication: failingPublication))
        let successOutcome = await persistence.nextOutcome()
        XCTAssertEqual(successOutcome, .success(songID: failingSong.id, generation: 1))
        XCTAssertEqual(failingStore.playlist(id: failingPlaylist.id)?.members.map(\.fileName), [failingSong.fileName])
        XCTAssertEqual(persistence.pendingWorkCount, 0)
    }

    func testAddOutcomeFeedbackSurvivesCoalescedSuccessAndFailureBatches() {
        let state = MusicPlaylistMutationUIState()

        state.apply(.failure(songID: "a", reason: .replacedSource, generation: 1))
        state.apply(.success(songID: "b", generation: 1))
        XCTAssertEqual(state.feedback?.failure, .replacedSource)

        state.clear()
        state.apply(.success(songID: "a", generation: 2))
        state.apply(.failure(songID: "b", reason: .persistenceFailure, generation: 2))
        XCTAssertEqual(state.feedback?.failure, .persistenceFailure)

        state.clear()
        state.apply(.success(songID: "a", generation: 3))
        state.apply(.success(songID: "b", generation: 3))
        XCTAssertNil(state.feedback)
    }

    func testWaitingAddPublishesTerminalFailureWhenAuthoritativeSourceIsDeleted() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let playlist = try XCTUnwrap(store.create(name: "Waiting outcome"))
        let authenticated = item("waiting-outcome.mp3", byte: "w")
        let cheap = MusicItem(url: authenticated.url, duration: 30, favoriteSourceIdentity: nil)
        let coordinator = MusicPlaylistAddCoordinator(
            playlistID: playlist.id,
            storeRevision: store.revision,
            libraryGeneration: 1
        )

        XCTAssertTrue(coordinator.request(cheap))
        coordinator.resolve(
            using: MusicPlaylistLibraryIndex(library: []),
            store: store,
            publication: MusicLibraryPublication(
                generation: 2,
                reconciliationSnapshot: MusicFavoritesReconciliationSnapshot(songs: []),
                songs: []
            )
        )

        XCTAssertEqual(
            coordinator.consumeOutcome(),
            .failure(songID: cheap.id, reason: .unavailableSource, generation: 0)
        )
        XCTAssertNil(coordinator.consumeOutcome())
        XCTAssertFalse(coordinator.hasPendingRequests)
    }

    func testOwnedAddCoordinatorCommitsOutOfOrderFingerprintResultsInTapOrderAndCancelsLateWork() async throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let playlist = try XCTUnwrap(store.create(name: "Async owner"))
        let a = item("async-a.mp3", byte: "a"), b = item("async-b.mp3", byte: "b")
        let publication = MusicLibraryPublication(generation: 1, reconciliationSnapshot: .init(songs: [a, b]), songs: [a, b])
        let rows = MusicPlaylistLibraryIndex(library: [a, b]).addRows(
            for: playlist, storeRevision: store.revision, publicationGeneration: 1
        )
        let aIntent = try XCTUnwrap(rows.first(where: { $0.song == a })?.actionIntent)
        let bIntent = try XCTUnwrap(rows.first(where: { $0.song == b })?.actionIntent)
        let gate = FingerprintGate(), aStarted = expectation(description: "A validation started"), bStarted = expectation(description: "B validation started")
        let coordinator = MusicPlaylistAddCoordinator(
            playlistID: playlist.id, storeRevision: store.revision, libraryGeneration: 1,
            validator: { song in
                if song == a { aStarted.fulfill() } else { bStarted.fulfill() }
                return await gate.wait(song.fileName)
            }
        )
        XCTAssertTrue(coordinator.enqueue(aIntent, store: store, publication: publication))
        XCTAssertFalse(coordinator.enqueue(aIntent, store: store, publication: publication))
        XCTAssertTrue(coordinator.enqueue(bIntent, store: store, publication: publication))
        await fulfillment(of: [aStarted, bStarted], timeout: 1)
        await gate.release(b.fileName)
        XCTAssertTrue(store.playlist(id: playlist.id)?.members.isEmpty == true)
        let committed = expectation(description: "ordered commits")
        var cancellables = Set<AnyCancellable>()
        store.$revision.dropFirst().collect(2).sink { _ in committed.fulfill() }.store(in: &cancellables)
        await gate.release(a.fileName)
        await fulfillment(of: [committed], timeout: 1)
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), [a.fileName, b.fileName])

        let second = try XCTUnwrap(store.create(name: "Cancelled async"))
        let c = item("async-c.mp3", byte: "c")
        let cPublication = MusicLibraryPublication(generation: 2, reconciliationSnapshot: .init(songs: [c]), songs: [c])
        let cIntent = try XCTUnwrap(MusicPlaylistLibraryIndex(library: [c]).addRows(
            for: second, storeRevision: store.revision, publicationGeneration: 2
        ).first?.actionIntent)
        let cancelGate = FingerprintGate(), cStarted = expectation(description: "C validation started")
        let cancelled = MusicPlaylistAddCoordinator(
            playlistID: second.id, storeRevision: store.revision, libraryGeneration: 2,
            validator: { song in cStarted.fulfill(); return await cancelGate.wait(song.fileName) }
        )
        XCTAssertTrue(cancelled.enqueue(cIntent, store: store, publication: cPublication))
        await fulfillment(of: [cStarted], timeout: 1)
        cancelled.cancel(); await cancelGate.release(c.fileName)
        XCTAssertTrue(store.playlist(id: second.id)?.members.isEmpty == true)
    }

    func testRetainedCurrentShuffleUsesPlanAndHistoryForLocalAndRemoteTraversal() throws {
        for remote in [false, true] {
            let (defaults, cleanup) = try makeDefaults(); defer { cleanup() }
            let controls = RecordingNowPlayingController()
            let manager = MusicPlaybackManager(
                player: AVPlayer(), defaults: defaults, activateAudioSession: {}, nowPlayingController: controls,
                shuffleOrdering: { Array($0.reversed()) }, isShuffleTrackReadable: { _ in true }
            )
            let b = item("shuffle-b-\(remote).mp3", byte: "b")
            let a = item("shuffle-a-\(remote).mp3", byte: "a")
            let c = item("shuffle-c-\(remote).mp3", byte: "c")
            let id = UUID()
            manager.updateQueue([a, b, c]); manager.playFromPlaylist(b, playlistID: id, items: [b, a, c])
            manager.setShuffleEnabled(true); manager.reconcilePlaylistQueue(id: id, items: [a, c])
            let retainedGeneration = manager.trackLoadGeneration
            if remote { XCTAssertEqual(controls.send(.previousTrack), .commandFailed) } else { manager.previous() }
            XCTAssertEqual(manager.trackLoadGeneration, retainedGeneration)
            XCTAssertEqual(manager.currentTrack?.fileName, b.fileName)

            if remote { XCTAssertEqual(controls.send(.nextTrack), .success) } else { manager.next() }
            XCTAssertEqual(manager.currentTrack?.fileName, c.fileName)
            XCTAssertEqual(manager.trackLoadGeneration, retainedGeneration + 1)
            if remote { XCTAssertEqual(controls.send(.nextTrack), .success) } else { manager.next() }
            XCTAssertEqual(manager.currentTrack?.fileName, a.fileName)
            XCTAssertEqual(manager.trackLoadGeneration, retainedGeneration + 2)
            if remote { XCTAssertEqual(controls.send(.previousTrack), .success) } else { manager.previous() }
            XCTAssertEqual(manager.currentTrack?.fileName, c.fileName)
            XCTAssertEqual(manager.trackLoadGeneration, retainedGeneration + 3)
            XCTAssertFalse(manager.queue.contains(where: { $0.fileName == b.fileName }))
        }
    }

    func testRetainedCurrentNonshufflePreviousLoadsLastRemainingForLocalAndRemote() throws {
        for remote in [false, true] {
            let (defaults, cleanup) = try makeDefaults(); defer { cleanup() }
            let controls = RecordingNowPlayingController()
            let manager = MusicPlaybackManager(player: AVPlayer(), defaults: defaults, activateAudioSession: {}, nowPlayingController: controls)
            let b = item("previous-b-\(remote).mp3", byte: "b"), a = item("previous-a-\(remote).mp3", byte: "a"), c = item("previous-c-\(remote).mp3", byte: "c")
            let id = UUID(); manager.updateQueue([a, b, c]); manager.playFromPlaylist(b, playlistID: id, items: [b, a, c])
            manager.reconcilePlaylistQueue(id: id, items: [a, c])
            let generation = manager.trackLoadGeneration
            if remote { XCTAssertEqual(controls.send(.previousTrack), .success) } else { manager.previous() }
            XCTAssertEqual(manager.currentTrack?.fileName, c.fileName)
            XCTAssertEqual(manager.trackLoadGeneration, generation + 1)
            XCTAssertFalse(manager.queue.contains(where: { $0.fileName == b.fileName }))
        }
    }

    func testNonauthoritativeCoordinatorSnapshotPreservesLoadedPlaylistQueueUntilAuthorityReturns() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let (defaults, cleanupDefaults) = try makeDefaults(); defer { cleanupDefaults() }
        let player = AVPlayer()
        let manager = MusicPlaybackManager(player: player, defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController())
        let b = item("nonauth-b.mp3", byte: "b"), a = item("nonauth-a.mp3", byte: "a")
        let playlist = try XCTUnwrap(store.create(name: "Nonauthoritative")); XCTAssertTrue(store.add(b, to: playlist.id)); XCTAssertTrue(store.add(a, to: playlist.id))
        manager.updateQueue([b, a]); manager.playFromPlaylist(b, playlistID: playlist.id, items: [b, a])
        let loaded = player.currentItem; let generation = manager.trackLoadGeneration
        let cheap = [MusicItem(url: b.url, duration: 30, favoriteSourceIdentity: nil), MusicItem(url: a.url, duration: 30, favoriteSourceIdentity: nil)]
        MusicPlaylistCoordinator(store: store, playback: manager).synchronize(snapshot: .unavailable, library: cheap)
        XCTAssertEqual(manager.queue.map(\.fileName), [b.fileName, a.fileName])
        XCTAssertTrue(player.currentItem === loaded)
        XCTAssertEqual(manager.trackLoadGeneration, generation)
        MusicPlaylistCoordinator(store: store, playback: manager).synchronize(snapshot: .init(songs: [b, a]), library: [b, a])
        XCTAssertEqual(manager.queue.map(\.fileName), [b.fileName, a.fileName])
        XCTAssertTrue(player.currentItem === loaded)
    }

    func testDetailRefreshWithoutPendingAddsPreservesActivePlaylistQueue() async throws {
        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        let store = MusicPlaylistStore(defaults: defaults)
        let documents = fixtureDirectory.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        for name in ["A.wav", "B.wav"] {
            try writeDetailRefreshAudio(to: documents.appendingPathComponent(name))
        }
        let library = MusicLibrary(storage: MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: fixtureDirectory.appendingPathComponent("OldAudio"),
            legacyVideoURL: fixtureDirectory.appendingPathComponent("OldVideo")
        ), metadataSnapshotStore: MediaMetadataSnapshotStore(
            fileURL: fixtureDirectory.appendingPathComponent("detail-refresh-metadata.json")
        ), durationLoader: { _ in 30 })
        let initialSnapshot = await library.refresh()
        XCTAssertTrue(initialSnapshot.isAuthoritative)
        let a = try XCTUnwrap(library.songs.first { $0.fileName == "A.wav" })
        let b = try XCTUnwrap(library.songs.first { $0.fileName == "B.wav" })
        XCTAssertNotNil(a.favoriteSourceIdentity); XCTAssertNotNil(b.favoriteSourceIdentity)
        let playlist = try XCTUnwrap(store.create(name: "Detail refresh"))
        XCTAssertTrue(store.add(a, to: playlist.id)); XCTAssertTrue(store.add(b, to: playlist.id))
        let player = AVPlayer()
        let playback = MusicPlaybackManager(
            player: player, defaults: defaults, activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController()
        )
        defer { playback.pause() }
        playback.updateQueue([a, b])
        playback.playFromPlaylist(a, playlistID: playlist.id, items: [a, b])
        // Hold the real transport still while exercising the manager's position callback.
        player.pause()
        playback.seekCompletionCallback(to: 7)(true)
        await Task.yield()
        let loaded = try XCTUnwrap(player.currentItem)
        let loadGeneration = playback.trackLoadGeneration
        XCTAssertEqual(playback.currentTime, 7)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(playback.queue.map(\.fileName), ["A.wav", "B.wav"])
        let addCoordinator = MusicPlaylistAddCoordinator(
            playlistID: playlist.id, storeRevision: store.revision,
            libraryGeneration: library.latestReconciliationPublication.generation
        )
        defer { addCoordinator.cancel() }
        XCTAssertFalse(addCoordinator.hasPendingRequests)
        XCTAssertEqual(addCoordinator.pendingWorkCount, 0)
        let revision = store.revision
        let coordinator = MusicPlaylistCoordinator(store: store, playback: playback)
        var currentPublication = library.latestReconciliationPublication
        var callbackCount = 0
        var nonauthoritativeStages: [Int] = []

        // Both subscriptions call the same production coordination entry points as
        // the detail view. @Published delivers before the library property updates,
        // so retain the incoming publication for the nested add notification.
        let changeObservation = addCoordinator.$changeGeneration.dropFirst().sink { _ in
            callbackCount += 1
            coordinator.reconcileDetailQueue(id: playlist.id, publication: currentPublication)
        }
        let publicationObservation = library.$latestReconciliationPublication.dropFirst().sink { publication in
            currentPublication = publication
            let positionBeforeCallback = playback.currentTime
            let playingBeforeCallback = playback.isPlaying
            coordinator.resolveDetailPublication(publication, playlistID: playlist.id, addCoordinator: addCoordinator)
            guard !publication.reconciliationSnapshot.isAuthoritative else { return }
            nonauthoritativeStages.append(publication.songs.count)
            XCTAssertTrue(publication.songs.allSatisfy { $0.favoriteSourceIdentity == nil })
            XCTAssertFalse(addCoordinator.hasPendingRequests)
            XCTAssertEqual(addCoordinator.pendingWorkCount, 0)
            XCTAssertEqual(store.revision, revision)
            XCTAssertEqual(playback.queueScope, .playlist(playlist.id))
            XCTAssertEqual(playback.queue.map(\.fileName), ["A.wav", "B.wav"],
                           "Non-authoritative detail refresh must preserve certified traversal")
            XCTAssertEqual(playback.currentTrack?.fileName, "A.wav")
            XCTAssertTrue(player.currentItem === loaded)
            XCTAssertEqual(playback.trackLoadGeneration, loadGeneration)
            XCTAssertEqual(playback.currentTime, positionBeforeCallback)
            XCTAssertEqual(playback.isPlaying, playingBeforeCallback)
            if !publication.songs.isEmpty {
                // Check BEFORE authority returns, which would otherwise hide the gap.
                playback.next()
                XCTAssertEqual(playback.currentTrack?.fileName, "B.wav",
                               "Next must still reach B during cheap/unverified refresh")
                XCTAssertEqual(playback.trackLoadGeneration, loadGeneration + 1)
            }
        }
        defer { publicationObservation.cancel(); changeObservation.cancel() }
        _ = await library.refresh()
        XCTAssertEqual(nonauthoritativeStages, [0, 2], "Exercise both real refresh publications")
        XCTAssertGreaterThanOrEqual(callbackCount, 2, "Exercise the production changeGeneration publisher")
    }

    func testDetailRefreshAllowsExplicitRemovalAndVerifiedAdd() async throws {
        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        let store = MusicPlaylistStore(defaults: defaults)
        let documents = fixtureDirectory.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        for name in ["A.wav", "B.wav"] {
            try writeDetailRefreshAudio(to: documents.appendingPathComponent(name))
        }
        let library = MusicLibrary(storage: MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: fixtureDirectory.appendingPathComponent("OldAudio"),
            legacyVideoURL: fixtureDirectory.appendingPathComponent("OldVideo")
        ), metadataSnapshotStore: MediaMetadataSnapshotStore(
            fileURL: fixtureDirectory.appendingPathComponent("detail-mutation-metadata.json")
        ), durationLoader: { _ in 30 })
        let snapshot = await library.refresh()
        XCTAssertTrue(snapshot.isAuthoritative)
        let a = try XCTUnwrap(library.songs.first { $0.fileName == "A.wav" })
        let b = try XCTUnwrap(library.songs.first { $0.fileName == "B.wav" })
        let originalA = try Data(contentsOf: a.url), originalB = try Data(contentsOf: b.url)
        let playlist = try XCTUnwrap(store.create(name: "Refresh mutations"))
        XCTAssertTrue(store.add(a, to: playlist.id)); XCTAssertTrue(store.add(b, to: playlist.id))
        let player = AVPlayer()
        let playback = MusicPlaybackManager(
            player: player, defaults: defaults, activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController()
        )
        defer { playback.pause() }
        playback.updateQueue([a, b])
        playback.playFromPlaylist(a, playlistID: playlist.id, items: [a, b])
        player.pause()
        playback.seekCompletionCallback(to: 7)(true)
        await Task.yield()
        let loaded = try XCTUnwrap(player.currentItem)
        let loadGeneration = playback.trackLoadGeneration
        let coordinator = MusicPlaylistCoordinator(store: store, playback: playback)
        let addCoordinator = MusicPlaylistAddCoordinator(
            playlistID: playlist.id, storeRevision: store.revision,
            libraryGeneration: library.latestReconciliationPublication.generation
        )
        defer { addCoordinator.cancel() }
        var consumer = MusicPlaylistActionIntentConsumer()
        var currentPublication = library.latestReconciliationPublication
        var stages: [Int] = []
        let changeObservation = addCoordinator.$changeGeneration.dropFirst().sink { _ in
            coordinator.reconcileDetailQueue(id: playlist.id, publication: currentPublication)
        }
        let publicationObservation = library.$latestReconciliationPublication.dropFirst().sink { publication in
            currentPublication = publication
            let index = coordinator.resolveDetailPublication(
                publication, playlistID: playlist.id, addCoordinator: addCoordinator
            )
            guard !publication.reconciliationSnapshot.isAuthoritative else { return }
            stages.append(publication.songs.count)
            // Remove the next member during [], then the playing member during
            // cheap rows. Both are fresh user intents from the actual detail index.
            let name = publication.songs.isEmpty ? "B.wav" : "A.wav"
            guard let currentPlaylist = store.playlist(id: playlist.id),
                  let intent = index.memberRows(
                    for: currentPlaylist, storeRevision: store.revision,
                    publicationGeneration: publication.generation
                  ).first(where: { $0.member.fileName == name })?.removeIntent else {
                XCTFail("Refresh rows must retain explicit remove actions"); return
            }
            let priorRevision = store.revision
            let position = playback.currentTime, playing = playback.isPlaying
            XCTAssertTrue(coordinator.remove(intent, consumer: &consumer, publication: publication))
            XCTAssertEqual(store.revision, priorRevision + 1)
            let expected = publication.songs.isEmpty ? ["A.wav"] : []
            XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), expected)
            XCTAssertEqual(playback.queue.map(\.fileName), expected)
            XCTAssertEqual(playback.queueScope, .playlist(playlist.id))
            XCTAssertEqual(playback.currentTrack?.fileName, "A.wav")
            XCTAssertTrue(player.currentItem === loaded)
            XCTAssertEqual(playback.trackLoadGeneration, loadGeneration)
            XCTAssertEqual(playback.currentTime, position)
            XCTAssertEqual(playback.isPlaying, playing)
            XCTAssertFalse(coordinator.remove(intent, consumer: &consumer, publication: publication))
            XCTAssertEqual(consumer.lastFailure, .staleState)
            XCTAssertEqual(store.revision, priorRevision + 1)
            XCTAssertEqual(playback.queue.map(\.fileName), expected)
        }
        defer { publicationObservation.cancel(); changeObservation.cancel() }
        _ = await library.refresh()
        XCTAssertEqual(stages, [0, 2])
        XCTAssertTrue(library.latestReconciliationPublication.reconciliationSnapshot.isAuthoritative)
        XCTAssertTrue(playback.queue.isEmpty)

        // The real Add button resets the batch, then async fingerprint validation
        // commits against an authoritative publication. Its notification must
        // immediately put the newly added member back into future traversal.
        addCoordinator.reset(storeRevision: store.revision, libraryGeneration: currentPublication.generation)
        let currentPlaylist = try XCTUnwrap(store.playlist(id: playlist.id))
        let row = try XCTUnwrap(MusicPlaylistLibraryIndex(library: currentPublication.songs).addRows(
            for: currentPlaylist, storeRevision: store.revision,
            publicationGeneration: currentPublication.generation
        ).first { $0.song.fileName == "B.wav" })
        let intent = try XCTUnwrap(row.actionIntent)
        XCTAssertTrue(addCoordinator.enqueue(intent, store: store, publication: currentPublication))
        let outcome = await addCoordinator.nextOutcome()
        XCTAssertEqual(outcome, .success(songID: intent.song.id, generation: addCoordinator.operationGeneration))
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), ["B.wav"])
        XCTAssertEqual(playback.queue.map(\.fileName), ["B.wav"])
        XCTAssertTrue(player.currentItem === loaded)
        XCTAssertEqual(playback.trackLoadGeneration, loadGeneration)
        playback.next()
        XCTAssertEqual(playback.currentTrack?.fileName, "B.wav")
        XCTAssertEqual(playback.trackLoadGeneration, loadGeneration + 1)
        XCTAssertEqual(try Data(contentsOf: a.url), originalA)
        XCTAssertEqual(try Data(contentsOf: b.url), originalB)
    }

    func testDeletingActivePlaylistAfterScanFailurePreservesLoadedPlaybackUntilScanRecovers() async throws {
        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        let store = MusicPlaylistStore(defaults: defaults)
        let documents = fixtureDirectory.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let sourceURLs = ["A.wav", "B.wav"].map { documents.appendingPathComponent($0) }
        for url in sourceURLs { try writeDetailRefreshAudio(to: url) }
        let originalBytes = try sourceURLs.map { try Data(contentsOf: $0) }
        let fileManager = PlaylistScanFailureFileManager()
        let library = MusicLibrary(storage: MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: fixtureDirectory.appendingPathComponent("OldAudio"),
            legacyVideoURL: fixtureDirectory.appendingPathComponent("OldVideo"),
            fileManager: fileManager
        ), metadataSnapshotStore: MediaMetadataSnapshotStore(
            fileURL: fixtureDirectory.appendingPathComponent("scan-failure-delete-metadata.json")
        ), durationLoader: { _ in 30 })
        let initialSnapshot = await library.refresh()
        XCTAssertTrue(initialSnapshot.isAuthoritative)
        let a = try XCTUnwrap(library.songs.first { $0.fileName == "A.wav" })
        let b = try XCTUnwrap(library.songs.first { $0.fileName == "B.wav" })
        XCTAssertNotNil(a.favoriteSourceIdentity); XCTAssertNotNil(b.favoriteSourceIdentity)
        let playlist = try XCTUnwrap(store.create(name: "Scan failure"))
        XCTAssertTrue(store.add(a, to: playlist.id)); XCTAssertTrue(store.add(b, to: playlist.id))
        let player = AVPlayer()
        let playback = MusicPlaybackManager(
            player: player, defaults: defaults, activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController()
        )
        defer { playback.pause() }
        let coordinator = MusicPlaylistCoordinator(store: store, playback: playback)
        coordinator.synchronize(snapshot: initialSnapshot, library: library.songs)
        playback.playFromPlaylist(a, playlistID: playlist.id, items: [a, b])
        player.pause() // Hold transport still; retain the manager's real play request.
        let loaded = try XCTUnwrap(player.currentItem)
        let loadGeneration = playback.trackLoadGeneration
        XCTAssertTrue(playback.isPlaying)

        // Fail only directory enumeration, through the existing storage injection.
        // The real refresh catch publishes unavailable + []; no source is removed.
        fileManager.failingDirectory = documents
        let failedSnapshot = await library.refresh()
        XCTAssertEqual(fileManager.scanFailureCount, 1)
        XCTAssertFalse(failedSnapshot.isAuthoritative)
        XCTAssertFalse(library.latestReconciliationPublication.reconciliationSnapshot.isAuthoritative)
        XCTAssertTrue(library.latestReconciliationPublication.songs.isEmpty)
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertNotNil(library.libraryErrorMessage, "Exercise a thrown scan, not a successful empty scan")
        XCTAssertTrue(player.currentItem === loaded)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(try sourceURLs.map { try Data(contentsOf: $0) }, originalBytes)

        // Set a nonzero manager position after the asynchronous scan, then exercise
        // coordination and confirmed deletion synchronously, without timer drift.
        let positionReady = expectation(description: "Loaded playback position set before failed-scan coordination")
        let positionObservation = playback.timeline.$currentTime.filter { $0 == 7 }.prefix(1).sink { _ in
            positionReady.fulfill()
        }
        defer { positionObservation.cancel() }
        playback.seekCompletionCallback(to: 7)(true)
        await fulfillment(of: [positionReady], timeout: 1)
        XCTAssertEqual(playback.currentTime, 7)
        let revision = store.revision
        XCTAssertEqual(coordinator.synchronize(snapshot: failedSnapshot, library: library.songs), .noChange)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), ["A.wav", "B.wav"])
        XCTAssertEqual(playback.queueScope, .playlist(playlist.id))
        XCTAssertEqual(playback.queue.map(\.fileName), ["A.wav", "B.wav"])
        XCTAssertEqual(playback.currentTrack?.fileName, "A.wav")
        XCTAssertTrue(player.currentItem === loaded)
        XCTAssertEqual(playback.trackLoadGeneration, loadGeneration)
        XCTAssertEqual(playback.currentTime, 7)
        XCTAssertTrue(playback.isPlaying)

        let actions = MusicPlaylistUIActions(store: store, playback: playback)
        let deletion = try XCTUnwrap(actions.captureIntent(for: playlist.id))
        XCTAssertTrue(actions.delete(deletion, confirmed: true))
        XCTAssertNil(store.playlist(id: playlist.id))
        XCTAssertNil(MusicPlaylistStore(defaults: defaults).playlist(id: playlist.id))
        XCTAssertEqual(playback.queueScope, .fullLibrary)
        XCTAssertEqual(playback.currentTrack?.fileName, "A.wav", "Deleting metadata must retain the existing source")
        XCTAssertEqual(playback.currentTrack?.url, a.url)
        XCTAssertTrue(player.currentItem === loaded, "Scan failure is not authority to detach the loaded item")
        XCTAssertEqual(playback.trackLoadGeneration, loadGeneration)
        XCTAssertEqual(playback.currentTime, 7)
        XCTAssertTrue(playback.isPlaying, "Confirmed playlist deletion must preserve the active play request")
        XCTAssertEqual(try sourceURLs.map { try Data(contentsOf: $0) }, originalBytes)

        // A later real, successful authoritative scan restores full-library traversal.
        fileManager.failingDirectory = nil
        let recoveredSnapshot = await library.refresh()
        XCTAssertTrue(recoveredSnapshot.isAuthoritative)
        XCTAssertNil(library.libraryErrorMessage)
        XCTAssertEqual(fileManager.scanFailureCount, 1)
        XCTAssertEqual(library.songs.map(\.fileName), ["A.wav", "B.wav"])
        let positionBeforeRecovery = playback.currentTime
        coordinator.synchronize(snapshot: recoveredSnapshot, library: library.songs)
        XCTAssertNil(store.playlist(id: playlist.id))
        XCTAssertEqual(playback.queueScope, .fullLibrary)
        XCTAssertEqual(playback.queue.map(\.fileName), ["A.wav", "B.wav"])
        XCTAssertEqual(playback.currentTrack?.fileName, "A.wav")
        XCTAssertTrue(player.currentItem === loaded)
        XCTAssertEqual(playback.trackLoadGeneration, loadGeneration)
        XCTAssertEqual(playback.currentTime, positionBeforeRecovery)
        XCTAssertTrue(playback.isPlaying)
        playback.next()
        XCTAssertEqual(playback.currentTrack?.fileName, "B.wav")
        XCTAssertEqual(playback.trackLoadGeneration, loadGeneration + 1)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(try sourceURLs.map { try Data(contentsOf: $0) }, originalBytes)
    }

    func testFullLibraryNextLoadsNewCheapSongBeforeRefreshEnrichmentCompletes() async throws {
        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        let documents = fixtureDirectory.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let aURL = documents.appendingPathComponent("A.wav")
        let bURL = documents.appendingPathComponent("B.wav")
        try writeDetailRefreshAudio(to: aURL)
        let gate = CheapPublicationEnrichmentGate()
        defer { gate.release() }
        let enrichmentBlocked = expectation(description: "B duration loader is suspended")
        let library = MusicLibrary(storage: MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: fixtureDirectory.appendingPathComponent("OldAudio"),
            legacyVideoURL: fixtureDirectory.appendingPathComponent("OldVideo")
        ), metadataSnapshotStore: MediaMetadataSnapshotStore(
            fileURL: fixtureDirectory.appendingPathComponent("cheap-publication-metadata.json")
        ), durationLoader: { url in
            if url.lastPathComponent == "B.wav" {
                await gate.wait(entered: enrichmentBlocked)
            }
            return 30
        })
        let player = AVPlayer()
        let playback = MusicPlaybackManager(
            player: player, defaults: defaults, activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController()
        )
        defer { playback.pause() }
        // Use RootTabView's actual publication payload and shared sync entry point.
        let observation = library.$latestReconciliationPublication.sink { publication in
            playback.syncLibrary(publication.songs, snapshot: publication.reconciliationSnapshot)
        }
        defer { observation.cancel() }
        let initialSnapshot = await library.refresh()
        XCTAssertTrue(initialSnapshot.isAuthoritative)
        XCTAssertEqual(library.songs.map(\.fileName), ["A.wav"])
        XCTAssertEqual(playback.queue.map(\.fileName), ["A.wav"])
        let a = try XCTUnwrap(library.songs.first)
        playback.playFromLibrary(a, library: library.songs)
        player.pause() // Hold transport while retaining the manager's play intent.
        let initialItem = try XCTUnwrap(player.currentItem)
        let initialLoadGeneration = playback.trackLoadGeneration
        XCTAssertEqual(playback.queueScope, .fullLibrary)
        XCTAssertEqual(playback.queue.map(\.fileName), ["A.wav"])
        XCTAssertEqual(playback.currentTrack?.url, aURL)
        XCTAssertTrue(playback.isPlaying)

        // Introduce B only after verifying the active one-song full-library queue.
        try writeDetailRefreshAudio(to: bURL)
        let cheapRowsEmitted = expectation(description: "Real cheap A/B publication emitted")
        let cheapObservation = library.$latestReconciliationPublication
            .filter {
                !$0.reconciliationSnapshot.isAuthoritative
                    && $0.songs.map(\.fileName) == ["A.wav", "B.wav"]
            }
            .prefix(1)
            .sink { _ in cheapRowsEmitted.fulfill() }
        defer { cheapObservation.cancel() }
        let refresh = Task { await library.refresh() }
        defer { gate.release(); refresh.cancel() }
        await fulfillment(of: [cheapRowsEmitted, enrichmentBlocked], timeout: 3)

        // Every behavioral assertion runs while B enrichment remains suspended.
        // No throwing unwrap or early return follows task creation; failed XCTest
        // assertions still reach release + drain, with defer as a release fallback.
        XCTAssertTrue(gate.isWaiting)
        XCTAssertFalse(gate.isReleased)
        XCTAssertTrue(library.isLoading)
        XCTAssertNil(library.libraryErrorMessage)
        XCTAssertFalse(library.latestReconciliationPublication.reconciliationSnapshot.isAuthoritative)
        XCTAssertEqual(library.latestReconciliationPublication.songs.map(\.fileName), ["A.wav", "B.wav"])
        XCTAssertEqual(library.songs.map(\.fileName), ["A.wav", "B.wav"])
        XCTAssertTrue(library.songs.allSatisfy { $0.duration == nil && $0.favoriteSourceIdentity == nil })
        XCTAssertEqual(playback.queueScope, .fullLibrary)
        XCTAssertEqual(playback.currentTrack?.url, aURL)
        XCTAssertTrue(player.currentItem === initialItem)
        XCTAssertEqual(playback.trackLoadGeneration, initialLoadGeneration)
        XCTAssertTrue(playback.isPlaying)

        // No second row tap or direct queue update: next must use visible candidates.
        playback.next()
        XCTAssertEqual(playback.currentTrack?.url, bURL,
                       "Next must reach cheap B before metadata/duration enrichment finishes")
        XCTAssertEqual((player.currentItem?.asset as? AVURLAsset)?.url, bURL,
                       "The player must actually load B, not merely change the displayed track")
        XCTAssertEqual(playback.trackLoadGeneration, initialLoadGeneration + 1)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertTrue(gate.isWaiting)
        XCTAssertFalse(gate.isReleased)
        XCTAssertTrue(library.isLoading)

        gate.release()
        _ = await refresh.value
    }

    func testColdFullLibraryRestorationAndCheapRowTapLoadBeforeEnrichmentCompletes() async throws {
        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        let documents = fixtureDirectory.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let aURL = documents.appendingPathComponent("A.wav")
        let bURL = documents.appendingPathComponent("B.wav")
        try writeDetailRefreshAudio(to: aURL)
        try writeDetailRefreshAudio(to: bURL)
        let originalA = try Data(contentsOf: aURL)
        let originalB = try Data(contentsOf: bURL)
        defaults.set("B.wav", forKey: "MusicPlayback.lastTrackFileName")
        defaults.set(7.0, forKey: "MusicPlayback.lastPositionSeconds")
        let gate = CheapPublicationEnrichmentGate()
        defer { gate.release() }
        let enrichmentBlocked = expectation(description: "Cold B enrichment is suspended")
        let library = MusicLibrary(storage: MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: fixtureDirectory.appendingPathComponent("OldAudio"),
            legacyVideoURL: fixtureDirectory.appendingPathComponent("OldVideo")
        ), metadataSnapshotStore: MediaMetadataSnapshotStore(
            fileURL: fixtureDirectory.appendingPathComponent("cold-cheap-metadata.json")
        ), durationLoader: { url in
            if url.lastPathComponent == "B.wav" { await gate.wait(entered: enrichmentBlocked) }
            return 30
        })
        let player = AVPlayer()
        let playback = MusicPlaybackManager(
            player: player, defaults: defaults, activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController()
        )
        defer { playback.pause() }
        let observation = library.$latestReconciliationPublication.sink { publication in
            playback.syncLibrary(publication.songs, snapshot: publication.reconciliationSnapshot)
        }
        defer { observation.cancel() }
        let refresh = Task { await library.refresh() }
        defer { gate.release(); refresh.cancel() }
        await fulfillment(of: [enrichmentBlocked], timeout: 3)

        // Keep the real loader gated through restoration, row tap and next.
        XCTAssertTrue(gate.isWaiting)
        XCTAssertFalse(gate.isReleased)
        XCTAssertTrue(library.isLoading)
        XCTAssertFalse(library.latestReconciliationPublication.reconciliationSnapshot.isAuthoritative)
        XCTAssertEqual(library.songs.map(\.fileName), ["A.wav", "B.wav"])
        XCTAssertTrue(library.songs.allSatisfy { $0.duration == nil && $0.favoriteSourceIdentity == nil })
        XCTAssertEqual(playback.queueScope, .fullLibrary)
        XCTAssertEqual(playback.queue.map(\.fileName), ["A.wav", "B.wav"])
        XCTAssertEqual(playback.currentTrack?.url, bURL)
        XCTAssertEqual((player.currentItem?.asset as? AVURLAsset)?.url, bURL)
        XCTAssertEqual(playback.currentTime, 7, accuracy: 0.1)
        XCTAssertFalse(playback.isPlaying, "Cold restoration must remain silent")
        XCTAssertEqual(playback.trackLoadGeneration, 1)

        // Match MusicHomeView's actual cheap-row action; no enriched replacement.
        if let cheapA = library.songs.first(where: { $0.url == aURL }) {
            playback.playFromLibrary(cheapA, library: library.songs)
        } else {
            XCTFail("Expected the real cheap A row")
        }
        player.pause()
        XCTAssertEqual(playback.currentTrack?.url, aURL)
        XCTAssertEqual((player.currentItem?.asset as? AVURLAsset)?.url, aURL)
        XCTAssertEqual(playback.trackLoadGeneration, 2)
        XCTAssertTrue(playback.isPlaying)
        playback.next()
        player.pause()
        XCTAssertEqual(playback.currentTrack?.url, bURL)
        XCTAssertEqual((player.currentItem?.asset as? AVURLAsset)?.url, bURL)
        XCTAssertEqual(playback.trackLoadGeneration, 3)
        XCTAssertTrue(playback.isPlaying)
        let loadedB = player.currentItem
        XCTAssertNotNil(loadedB)
        XCTAssertTrue(gate.isWaiting)
        XCTAssertFalse(gate.isReleased)
        XCTAssertTrue(library.isLoading)

        gate.release()
        let snapshot = await refresh.value
        XCTAssertTrue(snapshot.isAuthoritative)
        XCTAssertTrue(player.currentItem === loadedB, "Enrichment must retain the item already loaded from cheap rows")
        XCTAssertEqual(playback.trackLoadGeneration, 3)
        XCTAssertEqual(try Data(contentsOf: aURL), originalA)
        XCTAssertEqual(try Data(contentsOf: bURL), originalB)
    }

    func testCheapCandidatesMergeInLibraryOrderWithoutReplacingLoadedIdentityOrProvingRemoval() throws {
        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        let urls = ["2.wav", "3.wav", "10.wav"].map { fixtureDirectory.appendingPathComponent($0) }
        for url in urls { try writeDetailRefreshAudio(to: url) }
        let songs = urls.map { url in
            MusicItem(url: url, duration: 30,
                      favoriteSourceIdentity: MusicPlaylistAuthenticatedSourceValidator.fingerprint(at: url))
        }
        let a = songs[0], b = songs[1], c = songs[2]
        XCTAssertNotNil(a.favoriteSourceIdentity)
        let originalA = try Data(contentsOf: a.url)
        let player = AVPlayer()
        let playback = MusicPlaybackManager(
            player: player, defaults: defaults, activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController()
        )
        defer { playback.pause() }
        playback.syncLibrary([a, c], snapshot: MusicFavoritesReconciliationSnapshot(songs: [a, c]))
        playback.playFromLibrary(a, library: [a, c])
        player.pause()
        let loaded = try XCTUnwrap(player.currentItem)
        let generation = playback.trackLoadGeneration
        let conflictingA = MusicItem(url: fixtureDirectory.appendingPathComponent("Other/2.wav"), duration: nil)
        let cheapB = MusicItem(url: b.url, duration: nil)
        let duplicateB = MusicItem(url: fixtureDirectory.appendingPathComponent("Other/3.wav"), duration: nil)
        playback.syncLibrary([cheapB, conflictingA, duplicateB, cheapB], snapshot: .unavailable)
        XCTAssertEqual(playback.queue.map(\.fileName), ["2.wav", "3.wav", "10.wav"])
        XCTAssertEqual(playback.queue.map(\.url), [a.url, b.url, c.url])
        XCTAssertEqual(playback.currentTrack, a)
        XCTAssertEqual(playback.currentIndex, 0)
        XCTAssertTrue(player.currentItem === loaded)
        XCTAssertEqual(playback.trackLoadGeneration, generation)
        XCTAssertEqual(playback.duration, 30)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(try Data(contentsOf: a.url), originalA)

        // A partial publication must not probe away an already loaded source.
        // Only this test-owned WAV is unlinked; the later authority proves removal.
        try FileManager.default.removeItem(at: a.url)
        playback.syncLibrary([cheapB], snapshot: .unavailable)
        playback.syncLibrary([], snapshot: .unavailable)
        XCTAssertEqual(playback.queue.map(\.url), [a.url, b.url, c.url])
        XCTAssertEqual(playback.currentTrack, a)
        XCTAssertTrue(player.currentItem === loaded)
        XCTAssertEqual(playback.trackLoadGeneration, generation)
        XCTAssertTrue(playback.isPlaying)
        playback.syncLibrary([b, c], snapshot: MusicFavoritesReconciliationSnapshot(songs: [b, c]))
        XCTAssertEqual(playback.queue.map(\.url), [b.url, c.url])
        XCTAssertNil(playback.currentTrack)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(playback.isPlaying)
    }

    func testCheapCandidatesCannotResolveSavedPlaylistOrCertifyMembership() throws {
        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        let store = MusicPlaylistStore(defaults: defaults)
        let a = item("saved-a.mp3", byte: "a"), b = item("saved-b.mp3", byte: "b")
        let playlist = try XCTUnwrap(store.create(name: "Saved scope"))
        XCTAssertTrue(store.add(b, to: playlist.id))
        XCTAssertTrue(MusicQueueScopeStore(defaults: defaults).save(.playlist(playlist.id)))
        defaults.set(b.fileName, forKey: "MusicPlayback.lastTrackFileName")
        defaults.set(7.0, forKey: "MusicPlayback.lastPositionSeconds")
        let playback = MusicPlaybackManager(
            defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController()
        )
        defer { playback.pause() }
        let coordinator = MusicPlaylistCoordinator(store: store, playback: playback)
        let cheap = [a, b].map { MusicItem(url: $0.url, duration: nil) }
        let revision = store.revision
        coordinator.synchronize(snapshot: .unavailable, library: cheap)
        XCTAssertTrue(playback.queue.isEmpty)
        XCTAssertNil(playback.currentTrack)
        XCTAssertEqual(store.revision, revision)
        XCTAssertTrue(store.songs(in: playlist.id, library: cheap).isEmpty)
        XCTAssertEqual(defaults.string(forKey: "MusicPlayback.lastTrackFileName"), b.fileName)
        XCTAssertEqual(MusicQueueScopeStore(defaults: defaults).loadPlaylistID(), playlist.id)

        let snapshot = MusicFavoritesReconciliationSnapshot(songs: [a, b])
        coordinator.synchronize(snapshot: snapshot, library: [a, b])
        playback.resolvePendingQueueScope(playlists: store, library: [a, b])
        XCTAssertEqual(playback.queueScope, .playlist(playlist.id))
        XCTAssertEqual(playback.queue, [b])
        XCTAssertEqual(playback.currentTrack, b)
        XCTAssertEqual(playback.currentTime, 7)
        coordinator.synchronize(snapshot: .unavailable, library: cheap)
        XCTAssertEqual(playback.queue, [b])
        XCTAssertEqual(playback.currentTrack, b)
        XCTAssertEqual(store.revision, revision)
    }

    func testPartialCheapCandidatesDoNotConsumeMissingFullLibraryRestoration() throws {
        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        let urls = ["A.wav", "B.wav"].map { fixtureDirectory.appendingPathComponent($0) }
        for url in urls { try writeDetailRefreshAudio(to: url) }
        let cheap = urls.map { MusicItem(url: $0, duration: nil) }
        defaults.set("B.wav", forKey: "MusicPlayback.lastTrackFileName")
        defaults.set(7.0, forKey: "MusicPlayback.lastPositionSeconds")
        let player = AVPlayer()
        let playback = MusicPlaybackManager(
            player: player, defaults: defaults, activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController()
        )
        defer { playback.pause() }
        playback.syncLibrary([cheap[0]], snapshot: .unavailable)
        playback.syncLibrary([], snapshot: .unavailable)
        XCTAssertEqual(playback.queue, [cheap[0]])
        XCTAssertNil(playback.currentTrack)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(defaults.string(forKey: "MusicPlayback.lastTrackFileName"), "B.wav")
        XCTAssertEqual(defaults.double(forKey: "MusicPlayback.lastPositionSeconds"), 7)
        playback.syncLibrary([cheap[1]], snapshot: .unavailable)
        XCTAssertEqual(playback.queue, cheap)
        XCTAssertEqual(playback.currentTrack, cheap[1])
        XCTAssertEqual((player.currentItem?.asset as? AVURLAsset)?.url, urls[1])
        XCTAssertEqual(playback.trackLoadGeneration, 1)
        XCTAssertEqual(playback.currentTime, 7)
        XCTAssertFalse(playback.isPlaying)
    }

    func testLibraryPublicationPreservesFallbackOnScanErrorButAuthoritativeEmptyDetaches() async throws {
        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        let documents = fixtureDirectory.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let source = documents.appendingPathComponent("A.wav")
        try writeDetailRefreshAudio(to: source)
        let originalBytes = try Data(contentsOf: source)
        let fileManager = PlaylistScanFailureFileManager()
        let library = MusicLibrary(storage: MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: fixtureDirectory.appendingPathComponent("OldAudio"),
            legacyVideoURL: fixtureDirectory.appendingPathComponent("OldVideo"),
            fileManager: fileManager
        ), metadataSnapshotStore: MediaMetadataSnapshotStore(
            fileURL: fixtureDirectory.appendingPathComponent("publication-authority-metadata.json")
        ), durationLoader: { _ in 30 })
        let store = MusicPlaylistStore(defaults: defaults)
        let player = AVPlayer()
        let playback = MusicPlaybackManager(
            player: player, defaults: defaults, activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController()
        )
        defer { playback.pause() }
        // Match RootTabView's subscription: use the atomic publication payload,
        // including refresh-start/cheap/error publications, not a post-refresh bypass.
        let observation = library.$latestReconciliationPublication.sink { publication in
            playback.syncLibrary(publication.songs, snapshot: publication.reconciliationSnapshot)
        }
        defer { observation.cancel() }
        let initialSnapshot = await library.refresh()
        XCTAssertTrue(initialSnapshot.isAuthoritative)
        let a = try XCTUnwrap(library.songs.first)
        let playlist = try XCTUnwrap(store.create(name: "Publication authority"))
        XCTAssertTrue(store.add(a, to: playlist.id))
        playback.playFromPlaylist(a, playlistID: playlist.id, items: [a])
        player.pause()
        let loaded = try XCTUnwrap(player.currentItem)
        let generation = playback.trackLoadGeneration

        fileManager.failingDirectory = documents
        let failedSnapshot = await library.refresh()
        XCTAssertFalse(failedSnapshot.isAuthoritative)
        XCTAssertEqual(fileManager.scanFailureCount, 1)
        XCTAssertNotNil(library.libraryErrorMessage)
        XCTAssertTrue(player.currentItem === loaded)
        let actions = MusicPlaylistUIActions(store: store, playback: playback)
        XCTAssertTrue(actions.delete(try XCTUnwrap(actions.captureIntent(for: playlist.id)), confirmed: true))
        XCTAssertEqual(playback.queueScope, .fullLibrary)
        XCTAssertEqual(playback.queue.map(\.fileName), [a.fileName])
        XCTAssertTrue(player.currentItem === loaded)
        XCTAssertEqual(playback.trackLoadGeneration, generation)
        XCTAssertTrue(playback.isPlaying)

        // Failure in full-library scope must also retain the loaded source.
        let secondFailure = await library.refresh()
        XCTAssertFalse(secondFailure.isAuthoritative)
        XCTAssertEqual(fileManager.scanFailureCount, 2)
        XCTAssertEqual(playback.currentTrack?.url, source)
        XCTAssertTrue(player.currentItem === loaded)
        XCTAssertEqual(playback.trackLoadGeneration, generation)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)

        // Only this test-owned source is removed. A successful empty scan is
        // authoritative deletion evidence and must clear the old fallback/item.
        try FileManager.default.removeItem(at: source)
        fileManager.failingDirectory = nil
        let emptySnapshot = await library.refresh()
        XCTAssertTrue(emptySnapshot.isAuthoritative)
        XCTAssertTrue(emptySnapshot.entries.isEmpty)
        XCTAssertNil(library.libraryErrorMessage)
        XCTAssertTrue(library.latestReconciliationPublication.songs.isEmpty)
        XCTAssertTrue(playback.queue.isEmpty)
        XCTAssertNil(playback.currentTrack)
        XCTAssertNil(player.currentItem)
        XCTAssertEqual(playback.currentTime, 0)
        XCTAssertFalse(playback.isPlaying)
    }

    func testExplicitMediaDeletionPrunesFallbackEvenWhenFollowingScanFails() async throws {
        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        let documents = fixtureDirectory.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let sourceURLs = ["A.wav", "B.wav"].map { documents.appendingPathComponent($0) }
        for url in sourceURLs { try writeDetailRefreshAudio(to: url) }
        let originalA = try Data(contentsOf: sourceURLs[0])
        let fileManager = PlaylistScanFailureFileManager()
        let library = MusicLibrary(storage: MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: fixtureDirectory.appendingPathComponent("OldAudio"),
            legacyVideoURL: fixtureDirectory.appendingPathComponent("OldVideo"),
            fileManager: fileManager
        ), metadataSnapshotStore: MediaMetadataSnapshotStore(
            fileURL: fixtureDirectory.appendingPathComponent("explicit-delete-scan-error-metadata.json")
        ), durationLoader: { _ in 30 })
        let snapshot = await library.refresh()
        XCTAssertTrue(snapshot.isAuthoritative)
        let a = try XCTUnwrap(library.songs.first { $0.fileName == "A.wav" })
        let b = try XCTUnwrap(library.songs.first { $0.fileName == "B.wav" })
        let store = MusicPlaylistStore(defaults: defaults)
        let favorites = MusicFavoritesStore(defaults: defaults)
        let playlist = try XCTUnwrap(store.create(name: "Explicit deletion"))
        XCTAssertTrue(store.add(a, to: playlist.id)); XCTAssertTrue(store.add(b, to: playlist.id))
        let player = AVPlayer()
        let playback = MusicPlaybackManager(
            player: player, defaults: defaults, activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController()
        )
        defer { playback.pause() }
        MusicPlaylistCoordinator(store: store, playback: playback).synchronize(snapshot: snapshot, library: library.songs)
        playback.playFromPlaylist(a, playlistID: playlist.id, items: [a, b])
        player.pause()
        let loaded = try XCTUnwrap(player.currentItem)
        let generation = playback.trackLoadGeneration
        fileManager.failingDirectory = documents

        try await MusicDeletionCoordinator.delete(b, library: library, playback: playback, favorites: favorites, playlists: store)
        XCTAssertEqual(fileManager.scanFailureCount, 1)
        XCTAssertFalse(library.latestReconciliationPublication.reconciliationSnapshot.isAuthoritative)
        XCTAssertNotNil(library.libraryErrorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.url.path))
        XCTAssertEqual(try Data(contentsOf: a.url), originalA)
        XCTAssertEqual(playback.queue.map(\.fileName), [a.fileName])
        XCTAssertEqual(playback.currentTrack?.url, a.url)
        XCTAssertTrue(player.currentItem === loaded)
        XCTAssertEqual(playback.trackLoadGeneration, generation)
        XCTAssertTrue(playback.isPlaying)

        let actions = MusicPlaylistUIActions(store: store, playback: playback)
        XCTAssertTrue(actions.delete(try XCTUnwrap(actions.captureIntent(for: playlist.id)), confirmed: true))
        XCTAssertEqual(playback.queueScope, .fullLibrary)
        XCTAssertEqual(playback.queue.map(\.fileName), [a.fileName], "Confirmed unlink must prune the cached fallback")
        XCTAssertTrue(player.currentItem === loaded)
        XCTAssertTrue(playback.isPlaying)

        try await MusicDeletionCoordinator.delete(a, library: library, playback: playback, favorites: favorites, playlists: store)
        XCTAssertEqual(fileManager.scanFailureCount, 2)
        XCTAssertFalse(library.latestReconciliationPublication.reconciliationSnapshot.isAuthoritative)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.url.path))
        XCTAssertTrue(playback.queue.isEmpty)
        XCTAssertNil(playback.currentTrack)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(playback.isPlaying)
        playback.next()
        XCTAssertNil(playback.currentTrack, "A failed rescan must not resurrect an explicitly unlinked source")
        XCTAssertNil(player.currentItem)
    }

    private func writeDetailRefreshAudio(to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = Float(0.01 * sin(2 * .pi * 440 * Double(frame) / 8_000))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func testLogicalMemberReplacementCannotAppendBeforeAuthoritativeReconcile() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let playlist = try XCTUnwrap(store.create(name: "Logical"))
        let old = item("logical.mp3", byte: "a")
        XCTAssertTrue(store.add(old, to: playlist.id))
        let bytes = store.persistedPayloadData
        let revision = store.revision
        let replacement = MusicItem(url: old.url, duration: 30, favoriteSourceIdentity: .init(fileSize: 2, contentSHA256Hex: String(repeating: "b", count: 64)))
        XCTAssertFalse(store.add(replacement, to: playlist.id))
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.count, 1)
        XCTAssertEqual(store.persistedPayloadData, bytes)
    }

    func testCollisionSuffixRespectsGraphemeAndUTF8Budgets() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let nearBytes = String(repeating: "😀", count: 100)
        XCTAssertNotNil(store.create(name: nearBytes))
        let second = try XCTUnwrap(store.create(name: nearBytes))
        XCTAssertLessThanOrEqual(second.name.count, MusicPlaylistStore.maximumNameCharacters)
        XCTAssertLessThanOrEqual(second.name.utf8.count, MusicPlaylistStore.maximumNameUTF8Bytes)
        XCTAssertTrue(second.name.hasSuffix(" (2)"))
        for index in 3...12 { XCTAssertNotNil(store.create(name: nearBytes), "suffix \(index)") }
        let multiScalar = String(repeating: "👨‍👩‍👧‍👦", count: 15)
        XCTAssertNotNil(store.create(name: multiScalar))
        let multiScalarCollision = try XCTUnwrap(store.create(name: multiScalar))
        XCTAssertLessThanOrEqual(multiScalarCollision.name.utf8.count, MusicPlaylistStore.maximumNameUTF8Bytes)
        XCTAssertTrue(multiScalarCollision.name.hasSuffix(" (2)"))
        XCTAssertEqual(Set(store.playlists.map(\.name)).count, store.playlists.count)
    }

    func testExactCombiningUTF8CollisionUsesDeterministicNonWhitespaceStemThroughDigitGrowth() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let base = "a" + String(repeating: "\u{0301}", count: 199)
        XCTAssertEqual(base.count, 1); XCTAssertEqual(base.utf8.count, 399)
        XCTAssertNotNil(store.create(name: base))
        for suffix in 2...100 {
            let playlist = try XCTUnwrap(store.create(name: base))
            XCTAssertEqual(playlist.name, "P (\(suffix))")
            XCTAssertEqual(playlist.name, playlist.name.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertLessThanOrEqual(playlist.name.utf8.count, MusicPlaylistStore.maximumNameUTF8Bytes)
        }
        XCTAssertEqual(Set(store.playlists.map(\.name)).count, 100)
    }
    func testPendingBatchResolvesPastUnknownHeadAndRestoresTapOrderLater() throws {
        for hasExistingMember in [false, true] {
            let (store, cleanup) = try makeStore(); defer { cleanup() }
            let playlist = try XCTUnwrap(store.create(name: "Independent \(hasExistingMember)"))
            let x = item("independent-x-\(hasExistingMember).mp3", byte: "f")
            if hasExistingMember { XCTAssertTrue(store.add(x, to: playlist.id)) }
            let a = item("independent-a-\(hasExistingMember).mp3", byte: "a")
            let b = item("independent-b-\(hasExistingMember).mp3", byte: "b")
            let cheapA = MusicItem(url: a.url, duration: 30, favoriteSourceIdentity: nil)
            let cheapB = MusicItem(url: b.url, duration: 30, favoriteSourceIdentity: nil)
            var batch = MusicPlaylistPendingAddBatch(playlistID: playlist.id, storeRevision: store.revision)
            XCTAssertTrue(batch.request(cheapA)); XCTAssertTrue(batch.request(cheapB))

            let unknownA = MusicFavoritesReconciliationSnapshot.Entry(
                logicalLocation: a.url.deletingLastPathComponent().lastPathComponent,
                fileName: a.fileName,
                sourceIdentity: nil
            )
            let firstSnapshot = MusicFavoritesReconciliationSnapshot(
                isAuthoritative: true,
                entries: [unknownA] + MusicFavoritesReconciliationSnapshot(songs: [b]).entries
            )
            batch.resolve(using: MusicPlaylistLibraryIndex(library: [cheapA, b]), store: store,
                          publication: MusicLibraryPublication(generation: 1, reconciliationSnapshot: firstSnapshot))
            XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), hasExistingMember ? [x.fileName, b.fileName] : [b.fileName])
            XCTAssertEqual(batch.state(for: cheapA), .requestedWaiting)

            let revisionAfterB = store.revision
            batch.resolve(using: MusicPlaylistLibraryIndex(library: [cheapA, b]), store: store,
                          publication: MusicLibraryPublication(generation: 2, reconciliationSnapshot: firstSnapshot))
            XCTAssertEqual(store.revision, revisionAfterB)
            batch.resolve(using: MusicPlaylistLibraryIndex(library: [a, b]), store: store,
                          publication: MusicLibraryPublication(generation: 3, reconciliationSnapshot: .init(songs: [a, b])))
            XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), hasExistingMember ? [x.fileName, a.fileName, b.fileName] : [a.fileName, b.fileName])
            XCTAssertTrue(batch.isEmpty)
        }
    }

    func testRenderedMutationIntentsAreExactOnceAndSheetOwnedRevisionsPreservePendingWork() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let playlist = try XCTUnwrap(store.create(name: "Rendered"))
        let a = item("render-a.mp3", byte: "a"), b = item("render-b.mp3", byte: "b")
        let cheapA = MusicItem(url: a.url, duration: 30, favoriteSourceIdentity: nil)
        let publication = MusicLibraryPublication(
            generation: 1, reconciliationSnapshot: .init(songs: [b]), songs: [b]
        )
        var batch = MusicPlaylistPendingAddBatch(playlistID: playlist.id, storeRevision: store.revision, libraryGeneration: 1)
        XCTAssertTrue(batch.request(cheapA))
        let bIntent = try XCTUnwrap(
            MusicPlaylistLibraryIndex(library: [b]).addRows(
                for: playlist, requestedBy: batch, storeRevision: store.revision, publicationGeneration: 1
            ).first?.actionIntent
        )
        XCTAssertTrue(batch.commitAuthenticated(bIntent, store: store, publication: publication))
        XCTAssertFalse(batch.commitAuthenticated(bIntent, store: store, publication: publication))
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), [b.fileName])
        batch.resolve(using: MusicPlaylistLibraryIndex(library: [a, b]), store: store,
                      publication: .init(generation: 2, reconciliationSnapshot: .init(songs: [a, b]), songs: [a, b]))
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), [a.fileName, b.fileName])

        let rendered = try XCTUnwrap(store.playlist(id: playlist.id))
        let removeRow = try XCTUnwrap(MusicPlaylistLibraryIndex(library: [a, b]).memberRows(
            for: rendered, storeRevision: store.revision, publicationGeneration: 2
        ).first)
        let removeIntent = try XCTUnwrap(removeRow.removeIntent)
        _ = store.create(name: "External")
        var consumer = MusicPlaylistActionIntentConsumer()
        XCTAssertFalse(consumer.remove(removeIntent, store: store,
                                       publication: .init(generation: 2, reconciliationSnapshot: .init(songs: [a, b]), songs: [a, b])))
        let freshPlaylist = try XCTUnwrap(store.playlist(id: playlist.id))
        let freshIntent = try XCTUnwrap(MusicPlaylistLibraryIndex(library: [a, b]).memberRows(
            for: freshPlaylist, storeRevision: store.revision, publicationGeneration: 3
        ).first?.removeIntent)
        let freshPublication = MusicLibraryPublication(generation: 3, reconciliationSnapshot: .init(songs: [a, b]), songs: [a, b])
        XCTAssertTrue(consumer.remove(freshIntent, store: store, publication: freshPublication))
        XCTAssertFalse(consumer.remove(freshIntent, store: store, publication: freshPublication))

        let c = item("render-c.mp3", byte: "c")
        let current = try XCTUnwrap(store.playlist(id: playlist.id))
        let captured = try XCTUnwrap(MusicPlaylistLibraryIndex(library: [c]).addRows(
            for: current, storeRevision: store.revision, publicationGeneration: 4
        ).first?.actionIntent)
        try Data("replacement".utf8).write(to: c.url, options: .atomic)
        var replacementBatch = MusicPlaylistPendingAddBatch(playlistID: playlist.id, storeRevision: store.revision, libraryGeneration: 4)
        XCTAssertFalse(replacementBatch.commitAuthenticated(
            captured, store: store,
            publication: .init(generation: 4, reconciliationSnapshot: .init(songs: [c]), songs: [c])
        ))

        let reverse = try XCTUnwrap(store.create(name: "Reverse ownership"))
        let reversePublication = MusicLibraryPublication(generation: 5, reconciliationSnapshot: .init(songs: [b]), songs: [b])
        var reverseBatch = MusicPlaylistPendingAddBatch(playlistID: reverse.id, storeRevision: store.revision, libraryGeneration: 5)
        let reverseB = try XCTUnwrap(MusicPlaylistLibraryIndex(library: [b]).addRows(
            for: reverse, storeRevision: store.revision, publicationGeneration: 5
        ).first?.actionIntent)
        XCTAssertTrue(reverseBatch.commitAuthenticated(reverseB, store: store, publication: reversePublication))
        XCTAssertTrue(reverseBatch.request(cheapA))
        reverseBatch.resolve(using: MusicPlaylistLibraryIndex(library: [a, b]), store: store,
                             publication: .init(generation: 6, reconciliationSnapshot: .init(songs: [a, b]), songs: [a, b]))
        XCTAssertEqual(store.playlist(id: reverse.id)?.members.map(\.fileName), [b.fileName, a.fileName])
    }

    func testAuthenticatedActionsRejectEqualSizeRestoredMtimeAndPrecommitReplacement() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let playlist = try XCTUnwrap(store.create(name: "TOCTOU"))
        let song = item("toctou.mp3", byte: "a")
        let publication = MusicLibraryPublication(generation: 1, reconciliationSnapshot: .init(songs: [song]), songs: [song])
        let intent = try XCTUnwrap(MusicPlaylistLibraryIndex(library: [song]).addRows(
            for: playlist, storeRevision: store.revision, publicationGeneration: 1
        ).first?.actionIntent)
        let modificationDate = try XCTUnwrap(try song.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try Data("b".utf8).write(to: song.url)
        try FileManager.default.setAttributes([.modificationDate: modificationDate], ofItemAtPath: song.url.path)
        var stale = MusicPlaylistPendingAddBatch(playlistID: playlist.id, storeRevision: store.revision, libraryGeneration: 1)
        XCTAssertFalse(stale.commitAuthenticated(intent, store: store, publication: publication))
        XCTAssertTrue(store.playlist(id: playlist.id)?.members.isEmpty == true)

        let pendingSong = item("toctou-pending.mp3", byte: "b")
        let cheapPending = MusicItem(url: pendingSong.url, duration: 30, favoriteSourceIdentity: nil)
        var pending = MusicPlaylistPendingAddBatch(playlistID: playlist.id, storeRevision: store.revision)
        XCTAssertTrue(pending.request(cheapPending))
        let pendingDate = try XCTUnwrap(try pendingSong.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        try Data("c".utf8).write(to: pendingSong.url)
        try FileManager.default.setAttributes([.modificationDate: pendingDate], ofItemAtPath: pendingSong.url.path)
        pending.resolve(using: MusicPlaylistLibraryIndex(library: [pendingSong]), store: store, isAuthoritative: true)
        XCTAssertFalse(store.playlist(id: playlist.id)?.members.contains(where: { $0.fileName == pendingSong.fileName }) == true)

        let freshSong = item("toctou-fresh.mp3", byte: "c")
        let freshPublication = MusicLibraryPublication(generation: 2, reconciliationSnapshot: .init(songs: [freshSong]), songs: [freshSong])
        let freshIntent = try XCTUnwrap(MusicPlaylistLibraryIndex(library: [freshSong]).addRows(
            for: playlist, storeRevision: store.revision, publicationGeneration: 2
        ).first?.actionIntent)
        let persisted = store.persistedPayloadData; let revision = store.revision
        var raced = MusicPlaylistPendingAddBatch(
            playlistID: playlist.id, storeRevision: revision, libraryGeneration: 2,
            preCommitSourceValidationHook: { try? Data("d".utf8).write(to: freshSong.url) }
        )
        XCTAssertFalse(raced.commitAuthenticated(freshIntent, store: store, publication: freshPublication))
        XCTAssertEqual(store.persistedPayloadData, persisted); XCTAssertEqual(store.revision, revision)

        let unchanged = item("toctou-unchanged.mp3", byte: "e")
        let unchangedPublication = MusicLibraryPublication(generation: 3, reconciliationSnapshot: .init(songs: [unchanged]), songs: [unchanged])
        let unchangedIntent = try XCTUnwrap(MusicPlaylistLibraryIndex(library: [unchanged]).addRows(
            for: playlist, storeRevision: store.revision, publicationGeneration: 3
        ).first?.actionIntent)
        var control = MusicPlaylistPendingAddBatch(playlistID: playlist.id, storeRevision: store.revision, libraryGeneration: 3)
        XCTAssertTrue(control.commitAuthenticated(unchangedIntent, store: store, publication: unchangedPublication))
        XCTAssertFalse(control.commitAuthenticated(unchangedIntent, store: store, publication: unchangedPublication))

        let hardlink = fixtureDirectory.appendingPathComponent("hardlink.mp3")
        try FileManager.default.linkItem(at: unchanged.url, to: hardlink)
        let hardlinkSong = MusicItem(url: hardlink, duration: 30, favoriteSourceIdentity: unchanged.favoriteSourceIdentity)
        XCTAssertNil(MusicPlaylistLibraryIndex(library: [hardlinkSong]).addRows(
            for: playlist, storeRevision: store.revision, publicationGeneration: 4
        ).first?.actionIntent)
        let symlink = fixtureDirectory.appendingPathComponent("symlink.mp3")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: unchanged.url)
        let symlinkSong = MusicItem(url: symlink, duration: 30, favoriteSourceIdentity: unchanged.favoriteSourceIdentity)
        XCTAssertNil(MusicPlaylistLibraryIndex(library: [symlinkSong]).addRows(
            for: playlist, storeRevision: store.revision, publicationGeneration: 4
        ).first?.actionIntent)
    }

    func testEveryDurableRowCarriesSourceIndependentExactOnceRemovalIntent() throws {
        for mode in 0..<4 {
            let (store, cleanup) = try makeStore(); defer { cleanup() }
            let playlist = try XCTUnwrap(store.create(name: "Remove \(mode)"))
            let song = item("remove-\(mode).mp3", byte: "a")
            XCTAssertTrue(store.add(song, to: playlist.id))
            let library: [MusicItem]
            switch mode {
            case 0: library = [song]
            case 1: library = [MusicItem(url: song.url, duration: 30, favoriteSourceIdentity: nil)]
            case 2: library = []
            default:
                library = [MusicItem(url: song.url, duration: 30, favoriteSourceIdentity: .init(fileSize: 2, contentSHA256Hex: String(repeating: "b", count: 64)))]
            }
            let durable = try XCTUnwrap(store.playlist(id: playlist.id))
            let row = try XCTUnwrap(MusicPlaylistLibraryIndex(library: library).memberRows(
                for: durable, storeRevision: store.revision, publicationGeneration: 7
            ).first)
            let intent = try XCTUnwrap(row.removeIntent)
            var consumer = MusicPlaylistActionIntentConsumer()
            let publication = MusicLibraryPublication(generation: 7, reconciliationSnapshot: .unavailable, songs: library)
            XCTAssertTrue(consumer.remove(intent, store: store, publication: publication))
            XCTAssertFalse(consumer.remove(intent, store: store, publication: publication))
            XCTAssertTrue(store.playlist(id: playlist.id)?.members.isEmpty == true)
        }

        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let playlist = try XCTUnwrap(store.create(name: "Stale remove"))
        let song = item("stale-remove.mp3", byte: "b"); XCTAssertTrue(store.add(song, to: playlist.id))
        let row = try XCTUnwrap(MusicPlaylistLibraryIndex(library: []).memberRows(
            for: try XCTUnwrap(store.playlist(id: playlist.id)), storeRevision: store.revision, publicationGeneration: 1
        ).first)
        _ = store.create(name: "External")
        var consumer = MusicPlaylistActionIntentConsumer()
        XCTAssertFalse(consumer.remove(try XCTUnwrap(row.removeIntent), store: store,
                                       publication: .init(generation: 1, reconciliationSnapshot: .unavailable, songs: [])))
    }

    func testMutationUIStateReportsTypedFailuresAndSuccessfulRetryClearsFeedback() throws {
        let suite = "MusicPlaylistMutationUI.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        var rejectWrites = false
        let limits = MusicPlaylistStore.Limits(playlistCount: 1, membersPerPlaylist: 1, totalMemberAndTombstoneCount: 2, payloadBytes: 64 * 1_024)
        let store = MusicPlaylistStore(defaults: defaults, limits: limits) { data in
            guard !rejectWrites else { return false }
            defaults.set(data, forKey: MusicPlaylistStore.persistenceKey); return true
        }
        let state = MusicPlaylistMutationUIState()
        XCTAssertNil(store.create(name: " \n")); state.record(store.lastMutationFailure)
        XCTAssertEqual(state.feedback?.failure, .invalidName)
        XCTAssertEqual(state.feedback?.accessibilityIdentifier, "music-playlist-mutation-failure")
        let playlist = try XCTUnwrap(store.create(name: "One")); state.clear(); XCTAssertNil(state.feedback)
        XCTAssertNil(store.create(name: "Two")); state.record(store.lastMutationFailure)
        XCTAssertEqual(state.feedback?.failure, .playlistLimit)
        let a = item("failure-a.mp3", byte: "a"), b = item("failure-b.mp3", byte: "b")
        XCTAssertTrue(store.add(a, to: playlist.id)); XCTAssertFalse(store.add(b, to: playlist.id)); state.record(store.lastMutationFailure)
        XCTAssertEqual(state.feedback?.failure, .memberLimit)
        let stale = try XCTUnwrap(store.intent(for: playlist.id)); XCTAssertTrue(store.rename(id: playlist.id, name: "Renamed"))
        XCTAssertFalse(store.rename(stale, name: "Stale")); state.record(store.lastMutationFailure)
        XCTAssertEqual(state.feedback?.failure, .staleState)
        XCTAssertFalse(store.delete(stale)); XCTAssertEqual(store.lastMutationFailure, .staleState)
        let member = try XCTUnwrap(store.playlist(id: playlist.id)?.members.first)
        XCTAssertFalse(store.remove(member, from: playlist.id, expectedRevision: stale.storeRevision))
        XCTAssertEqual(store.lastMutationFailure, .staleState)
        XCTAssertFalse(store.insert(b, into: playlist.id, at: 0, expectedRevision: stale.storeRevision))
        XCTAssertEqual(store.lastMutationFailure, .staleState)
        rejectWrites = true
        XCTAssertFalse(store.rename(id: playlist.id, name: "Retry")); state.record(store.lastMutationFailure)
        XCTAssertEqual(state.feedback?.failure, .persistenceFailure)
        XCTAssertFalse(state.feedback?.message.contains("/private/") == true)
        rejectWrites = false
        XCTAssertTrue(store.rename(id: playlist.id, name: "Retry")); state.clear()
        XCTAssertNil(state.feedback)
    }

    func testPendingAddsHonorPublicationAuthorityAndRejectStaleGenerations() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let playlist = try XCTUnwrap(store.create(name: "Authority"))
        let a = item("authority-a.mp3", byte: "a"), b = item("authority-b.mp3", byte: "b")
        let cheapA = MusicItem(url: a.url, duration: 30, favoriteSourceIdentity: nil)
        var batch = MusicPlaylistPendingAddBatch(playlistID: playlist.id, storeRevision: store.revision)
        XCTAssertTrue(batch.request(cheapA))
        batch.resolve(using: MusicPlaylistLibraryIndex(library: []), store: store,
                      publication: MusicLibraryPublication(generation: 1, reconciliationSnapshot: .unavailable))
        XCTAssertTrue(store.playlist(id: playlist.id)?.members.isEmpty == true)
        batch.resolve(using: MusicPlaylistLibraryIndex(library: [a]), store: store,
                      publication: MusicLibraryPublication(generation: 1, reconciliationSnapshot: .init(songs: [a])))
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), [a.fileName])

        let cheapMissing = MusicItem(url: item("authority-missing.mp3", byte: "c").url, duration: 30, favoriteSourceIdentity: nil)
        let cheapB = MusicItem(url: b.url, duration: 30, favoriteSourceIdentity: nil)
        var ordered = MusicPlaylistPendingAddBatch(playlistID: playlist.id, storeRevision: store.revision)
        XCTAssertTrue(ordered.request(cheapMissing)); XCTAssertTrue(ordered.request(cheapB))
        ordered.resolve(using: MusicPlaylistLibraryIndex(library: [b]), store: store,
                        publication: MusicLibraryPublication(generation: 2, reconciliationSnapshot: .init(songs: [b])))
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), [a.fileName, b.fileName])

        let staleSong = item("authority-stale.mp3", byte: "d")
        var stale = MusicPlaylistPendingAddBatch(playlistID: playlist.id, storeRevision: store.revision, libraryGeneration: 9)
        XCTAssertTrue(stale.request(MusicItem(url: staleSong.url, duration: 30, favoriteSourceIdentity: nil)))
        stale.resolve(using: MusicPlaylistLibraryIndex(library: [staleSong]), store: store,
                      publication: MusicLibraryPublication(generation: 8, reconciliationSnapshot: .init(songs: [staleSong])))
        XCTAssertFalse(store.playlist(id: playlist.id)?.members.contains(where: { $0.fileName == staleSong.fileName }) == true)

        let equal = item("authority-equal.mp3", byte: "e")
        var equalBatch = MusicPlaylistPendingAddBatch(playlistID: playlist.id, storeRevision: store.revision, libraryGeneration: 10)
        XCTAssertTrue(equalBatch.request(MusicItem(url: equal.url, duration: 30, favoriteSourceIdentity: nil)))
        equalBatch.resolve(using: MusicPlaylistLibraryIndex(library: [equal]), store: store,
                           publication: .init(generation: 10, reconciliationSnapshot: .unavailable, songs: [equal]))
        XCTAssertFalse(store.playlist(id: playlist.id)?.members.contains(where: { $0.fileName == equal.fileName }) == true)
        equalBatch.resolve(using: MusicPlaylistLibraryIndex(library: [equal]), store: store,
                           publication: .init(generation: 10, reconciliationSnapshot: .init(songs: [equal]), songs: [equal]))
        XCTAssertTrue(store.playlist(id: playlist.id)?.members.contains(where: { $0.fileName == equal.fileName }) == true)
    }

    func testPendingAddBatchPreservesTapOrderIdempotencyAndIndependentFailure() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let playlist = try XCTUnwrap(store.create(name: "Batch"))
        let a = item("batch-a.mp3", byte: "a"), b = item("batch-b.mp3", byte: "b")
        let cheapA = MusicItem(url: a.url, duration: 30, favoriteSourceIdentity: nil)
        let cheapB = MusicItem(url: b.url, duration: 30, favoriteSourceIdentity: nil)
        var batch = MusicPlaylistPendingAddBatch(playlistID: playlist.id, storeRevision: store.revision)
        XCTAssertTrue(batch.request(cheapA))
        XCTAssertTrue(batch.request(cheapB))
        XCTAssertFalse(batch.request(cheapA))
        XCTAssertEqual(batch.state(for: cheapA), .requestedWaiting)
        XCTAssertEqual(
            MusicPlaylistLibraryIndex(library: [cheapA, cheapB])
                .addRows(for: playlist, requestedBy: batch).map(\.state),
            [.requestedWaiting, .requestedWaiting]
        )

        batch.resolve(using: MusicPlaylistLibraryIndex(library: [cheapA, b]), store: store, isAuthoritative: false)
        XCTAssertTrue(store.playlist(id: playlist.id)?.members.isEmpty == true)
        batch.resolve(using: MusicPlaylistLibraryIndex(library: [a, b]), store: store, isAuthoritative: true)
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), [a.fileName, b.fileName])
        XCTAssertTrue(batch.isEmpty)

        let c = item("batch-c.mp3", byte: "c"), d = item("batch-d.mp3", byte: "d")
        var independent = MusicPlaylistPendingAddBatch(playlistID: playlist.id, storeRevision: store.revision)
        XCTAssertTrue(independent.request(MusicItem(url: c.url, duration: 30, favoriteSourceIdentity: nil)))
        XCTAssertTrue(independent.request(MusicItem(url: d.url, duration: 30, favoriteSourceIdentity: nil)))
        try Data("replacement".utf8).write(to: c.url, options: .atomic)
        independent.resolve(using: MusicPlaylistLibraryIndex(library: [d]), store: store, isAuthoritative: true)
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), [a.fileName, b.fileName, d.fileName])
    }

    func testPendingAddBatchRejectsExternalRevisionAndCancellation() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let playlist = try XCTUnwrap(store.create(name: "Stale batch"))
        let song = item("late.mp3", byte: "e")
        let cheap = MusicItem(url: song.url, duration: 30, favoriteSourceIdentity: nil)
        var stale = MusicPlaylistPendingAddBatch(playlistID: playlist.id, storeRevision: store.revision)
        XCTAssertTrue(stale.request(cheap)); _ = store.create(name: "External mutation")
        stale.resolve(using: MusicPlaylistLibraryIndex(library: [song]), store: store, isAuthoritative: true)
        XCTAssertFalse(store.playlist(id: playlist.id)?.members.contains(where: { $0.fileName == song.fileName }) == true)
        var cancelled = MusicPlaylistPendingAddBatch(playlistID: playlist.id, storeRevision: store.revision)
        XCTAssertTrue(cancelled.request(cheap)); cancelled.cancel()
        cancelled.resolve(using: MusicPlaylistLibraryIndex(library: [song]), store: store, isAuthoritative: true)
        XCTAssertTrue(cancelled.isEmpty)
        XCTAssertFalse(store.playlist(id: playlist.id)?.members.contains(where: { $0.fileName == song.fileName }) == true)
    }

    func testPlaylistLibraryIndexUsesLinearBoundedWorkAndPreservesTriStateOrder() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let playlist = try XCTUnwrap(store.create(name: "Indexed"))
        var library: [MusicItem] = []
        for index in 0..<1_000 {
            let song = item("indexed-\(index).mp3", byte: String(format: "%x", index % 16))
            library.append(song); XCTAssertTrue(store.add(song, to: playlist.id))
        }
        let known = library[0]
        library[0] = MusicItem(url: known.url, duration: 30, favoriteSourceIdentity: nil)
        library.remove(at: 1)
        var operations = 0
        let index = MusicPlaylistLibraryIndex(library: library) { operations += 1 }
        let rows = index.memberRows(for: try XCTUnwrap(store.playlist(id: playlist.id)))
        XCTAssertEqual(rows.count, 1_000)
        XCTAssertEqual(rows[0].state, .waitingForVerification)
        XCTAssertEqual(rows[1].state, .unavailable)
        XCTAssertEqual(rows.dropFirst(2).compactMap(\.playableSong).map(\.fileName), library.dropFirst().map(\.fileName))
        XCTAssertLessThanOrEqual(operations, library.count + rows.count + 4)
    }
    func testDurableMemberPresentationSurvivesCheapScanThenBecomesPlayableExactly() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let authenticated = item("presentation-a.mp3", byte: "a")
        let playlist = try XCTUnwrap(store.create(name: "Presentation")); XCTAssertTrue(store.add(authenticated, to: playlist.id))
        let cheap = MusicItem(url: authenticated.url, duration: 30, favoriteSourceIdentity: nil)

        let pendingRows = MusicPlaylistPresentation.rows(playlist: try XCTUnwrap(store.playlist(id: playlist.id)), library: [cheap])
        XCTAssertEqual(pendingRows.count, 1)
        XCTAssertEqual(pendingRows[0].state, .waitingForVerification)
        XCTAssertNil(pendingRows[0].playableSong)

        let playableRows = MusicPlaylistPresentation.rows(playlist: try XCTUnwrap(store.playlist(id: playlist.id)), library: [authenticated])
        XCTAssertEqual(playableRows.map(\.member), pendingRows.map(\.member))
        XCTAssertEqual(playableRows[0].state, .playable)
        XCTAssertEqual(playableRows[0].playableSong, authenticated)
    }

    func testPendingAddCommitsExactEnrichmentOnceAndRejectsReplacementDeletionAndRevisionChange() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let playlist = try XCTUnwrap(store.create(name: "Pending add"))
        let valid = item("pending-b.mp3", byte: "b")
        let available = item("pending-c.mp3", byte: "c")
        XCTAssertEqual(store.addRowState(for: available, playlistID: playlist.id).accessibilityValue, "未添加")
        let cheap = MusicItem(url: valid.url, duration: 30, favoriteSourceIdentity: nil)
        let intent = try XCTUnwrap(MusicPlaylistPendingAddIntent(song: cheap, playlistID: playlist.id, storeRevision: store.revision))
        XCTAssertEqual(intent.accessibilityValue, "等待验证")
        XCTAssertTrue(store.resolvePendingAdd(intent, library: [valid]))
        XCTAssertFalse(store.resolvePendingAdd(intent, library: [valid]))
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.count, 1)

        let replacementCheap = MusicItem(url: valid.url, duration: 30, favoriteSourceIdentity: nil)
        let replacementIntent = try XCTUnwrap(MusicPlaylistPendingAddIntent(song: replacementCheap, playlistID: playlist.id, storeRevision: store.revision))
        try Data("replacement bytes".utf8).write(to: valid.url, options: .atomic)
        let replacement = MusicItem(url: valid.url, duration: 30, favoriteSourceIdentity: MusicFavoriteSourceIdentity(fileSize: 2, contentSHA256Hex: String(repeating: "c", count: 64)))
        XCTAssertFalse(store.resolvePendingAdd(replacementIntent, library: [replacement]))
        XCTAssertFalse(store.resolvePendingAdd(replacementIntent, library: []))
        let stale = try XCTUnwrap(MusicPlaylistPendingAddIntent(song: cheap, playlistID: playlist.id, storeRevision: store.revision))
        _ = store.create(name: "Revision bump")
        XCTAssertFalse(store.resolvePendingAdd(stale, library: [valid]))
        XCTAssertEqual(store.addRowState(for: valid, playlistID: playlist.id).accessibilityValue, "已添加")
    }

    func testQueueScopePersistenceFailureKeepsPlaybackImmediateAndRetriesBothDirections() throws {
        let (defaults, cleanup) = try makeDefaults(); defer { cleanup() }
        let (playlists, cleanupPlaylists) = try makeStore(); defer { cleanupPlaylists() }
        var rejectWrites = false
        let scopeStore = MusicQueueScopeStore(defaults: defaults) { data in
            guard !rejectWrites else { return false }
            defaults.set(data, forKey: MusicQueueScopeStore.key)
            return defaults.data(forKey: MusicQueueScopeStore.key) == data
        }
        XCTAssertTrue(scopeStore.save(.fullLibrary))
        let a = item("scope-a.mp3", byte: "a"), b = item("scope-b.mp3", byte: "b")
        let playlist = try XCTUnwrap(playlists.create(name: "Durable scope"))
        XCTAssertTrue(playlists.add(a, to: playlist.id)); XCTAssertTrue(playlists.add(b, to: playlist.id))
        let manager = MusicPlaybackManager(defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController(), queueScopeStore: scopeStore)
        manager.updateQueue([a, b])

        rejectWrites = true
        manager.playFromPlaylist(a, playlistID: playlist.id, items: [a, b])
        XCTAssertEqual(manager.queueScope, .playlist(playlist.id))
        XCTAssertTrue(manager.queueScopePersistenceNeedsRepair)
        manager.next(); XCTAssertEqual(manager.currentTrack, b)
        let restoredPlaylist = MusicPlaybackManager(defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController(), queueScopeStore: scopeStore)
        restoredPlaylist.resolvePendingQueueScope(playlists: playlists, library: [a, b])
        XCTAssertEqual(restoredPlaylist.queueScope, .playlist(playlist.id))
        XCTAssertEqual(restoredPlaylist.queue.map(\.fileName), [a.fileName, b.fileName])

        rejectWrites = false
        manager.updateQueue([a, b])
        XCTAssertFalse(manager.queueScopePersistenceNeedsRepair)
        XCTAssertEqual(MusicQueueScopeStore(defaults: defaults).loadPlaylistID(), playlist.id)

        rejectWrites = true
        manager.playFromLibrary(a, library: [a, b])
        XCTAssertEqual(manager.queueScope, .fullLibrary)
        XCTAssertTrue(manager.queueScopePersistenceNeedsRepair)
        let restoredLibrary = MusicPlaybackManager(defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController(), queueScopeStore: scopeStore)
        restoredLibrary.updateQueue([a, b])
        XCTAssertEqual(restoredLibrary.queueScope, .fullLibrary)
        XCTAssertEqual(restoredLibrary.queue.map(\.fileName), [a.fileName, b.fileName])
        rejectWrites = false
        manager.updateQueue([a, b])
        XCTAssertFalse(manager.queueScopePersistenceNeedsRepair)
        XCTAssertNil(MusicQueueScopeStore(defaults: defaults).loadPlaylistID())
    }

    func testQueueScopePersistenceFailureIsVisibleUntilUserRetrySucceeds() {
        let suite = "MusicQueueScopeVisibleFailure.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var rejectWrites = true
        let scopeStore = MusicQueueScopeStore(defaults: defaults) { data in
            guard !rejectWrites else { return false }
            defaults.set(data, forKey: MusicQueueScopeStore.key)
            return true
        }
        let manager = MusicPlaybackManager(
            defaults: defaults,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            queueScopeStore: scopeStore
        )
        let song = item("visible-scope-failure.mp3", byte: "v")

        manager.playFromPlaylist(song, playlistID: UUID(), items: [song])

        let failedPresentation = MusicQueueScopePersistencePresentation(
            isRepairRequired: manager.queueScopePersistenceNeedsRepair
        )
        XCTAssertTrue(failedPresentation.showsStatus)
        XCTAssertEqual(failedPresentation.message, "播放范围未能保存。当前播放不受影响，请重试保存。")
        XCTAssertEqual(failedPresentation.retryLabel, "重试保存")

        rejectWrites = false
        manager.retryQueueScopePersistence()

        XCTAssertFalse(manager.queueScopePersistenceNeedsRepair)
        XCTAssertFalse(MusicQueueScopePersistencePresentation(
            isRepairRequired: manager.queueScopePersistenceNeedsRepair
        ).showsStatus)
    }

    func testAuthoritativePlaylistRepairIsVisibleUntilCoordinatorRetrySucceeds() throws {
        let suite = "MusicPlaylistVisibleRepair.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var rejectWrites = false
        let store = MusicPlaylistStore(defaults: defaults) { data in
            guard !rejectWrites else { return false }
            defaults.set(data, forKey: MusicPlaylistStore.persistenceKey)
            return true
        }
        let playlist = try XCTUnwrap(store.create(name: "Repair visibility"))
        let removed = item("visible-repair-removed.mp3", byte: "r")
        let surviving = item("visible-repair-surviving.mp3", byte: "s")
        XCTAssertTrue(store.add(removed, to: playlist.id))
        XCTAssertTrue(store.add(surviving, to: playlist.id))
        let manager = MusicPlaybackManager(
            defaults: defaults,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController()
        )
        manager.updateQueue([removed, surviving])
        manager.playFromPlaylist(removed, playlistID: playlist.id, items: [removed, surviving])
        let coordinator = MusicPlaylistCoordinator(store: store, playback: manager)
        let publication = MusicFavoritesReconciliationSnapshot(songs: [surviving])

        rejectWrites = true
        XCTAssertEqual(coordinator.synchronize(snapshot: publication, library: [surviving]), .repairRequired)

        let failedPresentation = MusicPlaylistReconciliationPresentation(
            isRepairRequired: store.reconciliationNeedsRepair
        )
        XCTAssertTrue(failedPresentation.showsStatus)
        XCTAssertEqual(failedPresentation.message, "播放列表未能保存最新音乐状态，请重试修复。")
        XCTAssertEqual(failedPresentation.retryLabel, "重试修复")
        XCTAssertEqual(manager.queue.map(\.fileName), [surviving.fileName])

        rejectWrites = false
        XCTAssertEqual(coordinator.synchronize(snapshot: publication, library: [surviving]), .persisted)

        XCTAssertFalse(store.reconciliationNeedsRepair)
        XCTAssertFalse(MusicPlaylistReconciliationPresentation(
            isRepairRequired: store.reconciliationNeedsRepair
        ).showsStatus)
        let restored = MusicPlaylistStore(defaults: defaults)
        XCTAssertEqual(restored.playlist(id: playlist.id)?.members.map(\.fileName), [surviving.fileName])
    }

    func testPlaylistUIReducersDriveAccessibleLifecycleActionsWithoutReorderingOrDeletingMedia() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let (defaults, cleanupDefaults) = try makeDefaults(); defer { cleanupDefaults() }
        let playback = MusicPlaybackManager(defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController())
        let actions = MusicPlaylistUIActions(store: store, playback: playback)
        XCTAssertEqual(MusicPlaylistUIModel.listEmptyTitle, "还没有播放列表")
        XCTAssertFalse(MusicPlaylistUIModel.allowsReordering)
        XCTAssertEqual(MusicPlaylistUIModel.open.identifier, "music-playlists-open")
        XCTAssertEqual(MusicPlaylistUIModel.create.identifier, "music-playlist-create")
        XCTAssertEqual(MusicPlaylistUIModel.nameField.identifier, "music-playlist-name-field")

        let playlist = try XCTUnwrap(actions.create(name: "  UI Mix\n"))
        XCTAssertEqual(playlist.name, "UI Mix")
        XCTAssertEqual(MusicPlaylistUIModel.detailEmptyTitle, "播放列表为空")
        let song = item("ui-member.mp3", byte: "a")
        XCTAssertTrue(store.add(song, to: playlist.id))
        let durable = try XCTUnwrap(store.playlist(id: playlist.id))
        let waitingSong = MusicItem(url: song.url, duration: 30, favoriteSourceIdentity: nil)
        let waiting = try XCTUnwrap(MusicPlaylistLibraryIndex(library: [waitingSong]).memberRows(for: durable).first)
        XCTAssertEqual(MusicPlaylistUIModel.member(waiting).value, "正在验证")
        let unavailable = try XCTUnwrap(MusicPlaylistLibraryIndex(library: []).memberRows(for: durable).first)
        XCTAssertEqual(MusicPlaylistUIModel.member(unavailable).value, "暂不可用")
        let playable = try XCTUnwrap(MusicPlaylistLibraryIndex(library: [song]).memberRows(for: durable).first)
        XCTAssertEqual(MusicPlaylistUIModel.member(playable).value, "可播放")

        let addedRow = try XCTUnwrap(MusicPlaylistLibraryIndex(library: [song]).addRows(for: durable).first)
        XCTAssertTrue(MusicPlaylistUIModel.add(addedRow).isSelected)
        XCTAssertEqual(MusicPlaylistUIModel.add(addedRow).value, "已添加")
        let available = item("ui-available.mp3", byte: "b")
        let availableRow = try XCTUnwrap(MusicPlaylistLibraryIndex(library: [available]).addRows(for: durable).first)
        XCTAssertEqual(MusicPlaylistUIModel.add(availableRow).value, "未添加")
        XCTAssertFalse(MusicPlaylistUIModel.add(availableRow).isSelected)
        let cheapAvailable = MusicItem(url: available.url, duration: 30, favoriteSourceIdentity: nil)
        var pending = MusicPlaylistPendingAddBatch(playlistID: playlist.id, storeRevision: store.revision)
        XCTAssertTrue(pending.request(cheapAvailable))
        let requestedRow = try XCTUnwrap(
            MusicPlaylistLibraryIndex(library: [cheapAvailable]).addRows(for: durable, requestedBy: pending).first
        )
        XCTAssertEqual(MusicPlaylistUIModel.add(requestedRow).value, "等待验证")
        XCTAssertTrue(MusicPlaylistUIModel.action(.delete).isDestructive)
        XCTAssertEqual(MusicPlaylistUIModel.action(.delete).identifier, "music-playlist-delete")
        XCTAssertTrue(MusicPlaylistUIModel.action(.remove, fileName: song.fileName).isDestructive)
        XCTAssertEqual(MusicPlaylistUIModel.deletionMessage, "音乐文件不会被删除。")

        let staleRename = try XCTUnwrap(actions.captureIntent(for: playlist.id))
        _ = actions.create(name: "External")
        XCTAssertFalse(actions.rename(staleRename, name: "Stale"))
        XCTAssertTrue(actions.rename(try XCTUnwrap(actions.captureIntent(for: playlist.id)), name: "Fresh"))
        let member = try XCTUnwrap(store.playlist(id: playlist.id)?.members.first)
        XCTAssertTrue(actions.remove(member, from: playlist.id, expectedRevision: store.revision))
        XCTAssertTrue(FileManager.default.fileExists(atPath: song.url.path))
        let deleteIntent = try XCTUnwrap(actions.captureIntent(for: playlist.id))
        XCTAssertFalse(actions.delete(deleteIntent, confirmed: false))
        XCTAssertNotNil(store.playlist(id: playlist.id))
        XCTAssertTrue(actions.delete(deleteIntent, confirmed: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: song.url.path))
    }
    private lazy var fixtureDirectory: URL = {
        let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("DrivePlayerPlaylistTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }()

    func testRetainedCurrentManualAndRemoteTransitionsConvergeThroughSingleLoadPath() async throws {
        for usesRemote in [false, true] {
            let (defaults, cleanup) = try makeDefaults(); defer { cleanup() }
            let player = AVPlayer(); let controls = RecordingNowPlayingController()
            let manager = MusicPlaybackManager(player: player, defaults: defaults, activateAudioSession: {}, nowPlayingController: controls, isShuffleTrackReadable: { _ in true })
            let b = item("b.mp3", byte: "b"), a = item("a.mp3", byte: "a"), c = item("c.mp3", byte: "c"), id = UUID()
            manager.updateQueue([a, b, c]); manager.playFromPlaylist(b, playlistID: id, items: [b, a, c])
            manager.reconcilePlaylistQueue(id: id, items: [a, c])
            if usesRemote { XCTAssertEqual(controls.send(.nextTrack), .success) } else { manager.next() }
            XCTAssertEqual(manager.currentTrack?.fileName, "a.mp3")
            XCTAssertEqual(manager.currentIndex, 0)
            let aItem = try XCTUnwrap(player.currentItem)
            await postCompletion(aItem, manager: manager)
            XCTAssertEqual(manager.currentTrack?.fileName, "c.mp3")
            XCTAssertEqual(manager.currentIndex, 1)
        }
    }

    func testRetainedCurrentPreviousAndShuffleNaturalCompletionUseRemainingScopeOnly() async throws {
        let (defaults, cleanup) = try makeDefaults(); defer { cleanup() }
        let player = AVPlayer(); let manager = MusicPlaybackManager(player: player, defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController(), shuffleOrdering: { Array($0.reversed()) }, isShuffleTrackReadable: { _ in true })
        let b = item("b.mp3", byte: "b"), a = item("a.mp3", byte: "a"), c = item("c.mp3", byte: "c"), id = UUID()
        manager.updateQueue([a, b, c]); manager.playFromPlaylist(b, playlistID: id, items: [b, a, c]); manager.reconcilePlaylistQueue(id: id, items: [a, c])
        manager.previous()
        XCTAssertEqual(manager.currentTrack?.fileName, "c.mp3")

        manager.playFromPlaylist(b, playlistID: id, items: [b, a, c]); manager.setShuffleEnabled(true); let completed = try XCTUnwrap(player.currentItem)
        manager.reconcilePlaylistQueue(id: id, items: [a, c])
        await postCompletion(completed, manager: manager)
        XCTAssertEqual(manager.currentTrack?.fileName, "c.mp3")
        XCTAssertFalse(manager.queue.contains(where: { $0.fileName == "b.mp3" }))
    }

    func testNaturalCompletionAfterRemovingLoadedPlaylistCurrentAdvancesOnceToFirstRemaining() async throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let player = AVPlayer()
        let nowPlaying = RecordingNowPlayingController()
        let manager = MusicPlaybackManager(
            player: player, defaults: defaults, activateAudioSession: {},
            nowPlayingController: nowPlaying, isShuffleTrackReadable: { _ in true }
        )
        let playlistID = UUID()
        let b = item("b.mp3", byte: "b")
        let a = item("a.mp3", byte: "a")
        manager.updateQueue([a, b])
        manager.playFromPlaylist(b, playlistID: playlistID, items: [b, a])
        let completedItem = try XCTUnwrap(player.currentItem)

        manager.reconcilePlaylistQueue(id: playlistID, items: [a])
        XCTAssertTrue(player.currentItem === completedItem)
        XCTAssertEqual(manager.currentTrack?.fileName, "b.mp3")

        await postCompletion(completedItem, manager: manager)
        XCTAssertEqual(manager.currentTrack?.fileName, "a.mp3")
        XCTAssertEqual(manager.currentIndex, 0)
        XCTAssertTrue(manager.isPlaying)
        XCTAssertEqual(nowPlaying.snapshots.last?.title, "a")

        await postCompletion(completedItem, manager: manager, accepted: false)
        XCTAssertEqual(manager.currentTrack?.fileName, "a.mp3")
    }

    func testRemovedLoadedCurrentCompletionStopsCoherentlyWhenEmptyOrSleepStopRequested() async throws {
        for sleepStops in [false, true] {
            let (defaults, cleanup) = try makeDefaults(); defer { cleanup() }
            let player = AVPlayer(); let nowPlaying = RecordingNowPlayingController()
            let manager = MusicPlaybackManager(player: player, defaults: defaults, activateAudioSession: {}, nowPlayingController: nowPlaying)
            let b = item("b.mp3", byte: "b"), a = item("a.mp3", byte: "a"); let id = UUID()
            manager.updateQueue([a, b]); manager.playFromPlaylist(b, playlistID: id, items: [b, a])
            let completed = try XCTUnwrap(player.currentItem)
            manager.reconcilePlaylistQueue(id: id, items: sleepStops ? [a] : [])
            if sleepStops { manager.setSleepTimerMode(.stopAfterCurrentTrack) }
            await postCompletion(completed, manager: manager)
            XCTAssertFalse(manager.isPlaying)
            XCTAssertEqual(manager.currentTrack?.fileName, "b.mp3")
            XCTAssertNil(manager.currentIndex)
            XCTAssertEqual(nowPlaying.snapshots.last?.playbackRate, 0)
            XCTAssertEqual(manager.sleepTimerMode, .off)
        }
    }

    func testCoordinatorKeepsActivePlaylistExactlySynchronizedWithoutReloadingCurrent() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let (defaults, cleanupDefaults) = try makeDefaults(); defer { cleanupDefaults() }
        let player = AVPlayer()
        let manager = MusicPlaybackManager(player: player, defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController(), isShuffleTrackReadable: { _ in true })
        let coordinator = MusicPlaylistCoordinator(store: store, playback: manager)
        let a = item("a.mp3", byte: "a"), b = item("b.mp3", byte: "b"), c = item("c.mp3", byte: "c")
        let playlist = try XCTUnwrap(store.create(name: "Mix"))
        XCTAssertTrue(store.add(b, to: playlist.id)); XCTAssertTrue(store.add(a, to: playlist.id))
        manager.updateQueue([a, b, c]); manager.playFromPlaylist(b, playlistID: playlist.id, items: [b, a])
        let loaded = try XCTUnwrap(player.currentItem)
        XCTAssertTrue(coordinator.add(c, to: playlist.id, library: [a, b, c]))
        XCTAssertEqual(manager.queue.map(\.fileName), ["b.mp3", "a.mp3", "c.mp3"])
        XCTAssertTrue(player.currentItem === loaded)

        let enrichedB = MusicItem(url: b.url, duration: 99, metadata: MusicMetadata(title: "B+", artist: nil, album: nil, artworkData: nil, lyrics: nil, synchronizedLyricsData: nil), favoriteSourceIdentity: b.favoriteSourceIdentity)
        coordinator.synchronize(snapshot: MusicFavoritesReconciliationSnapshot(songs: [a, enrichedB, c]), library: [a, enrichedB, c])
        XCTAssertEqual(manager.queue.map(\.fileName), ["b.mp3", "a.mp3", "c.mp3"])
        XCTAssertEqual(manager.queue.first?.metadata?.title, "B+")
        XCTAssertTrue(player.currentItem === loaded)
    }

    func testAuthoritativeRemovalDetachesInvalidRetainedCurrentAndRepairRetriesDurably() throws {
        let suite = "MusicPlaylistReconcileRepair.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        var rejectWrites = false
        let store = MusicPlaylistStore(defaults: defaults) { data in
            guard !rejectWrites else { return false }
            defaults.set(data, forKey: MusicPlaylistStore.persistenceKey)
            return defaults.data(forKey: MusicPlaylistStore.persistenceKey) == data
        }
        let playlist = try XCTUnwrap(store.create(name: "Repair"))
        let a = item("repair-a.mp3", byte: "a"), b = item("repair-b.mp3", byte: "b")
        XCTAssertTrue(store.add(b, to: playlist.id)); XCTAssertTrue(store.add(a, to: playlist.id))
        let durableBefore = try XCTUnwrap(defaults.data(forKey: MusicPlaylistStore.persistenceKey))
        let (playbackDefaults, cleanupPlayback) = try makeDefaults(); defer { cleanupPlayback() }
        let player = AVPlayer(); let nowPlaying = RecordingNowPlayingController()
        let manager = MusicPlaybackManager(player: player, defaults: playbackDefaults, activateAudioSession: {}, nowPlayingController: nowPlaying)
        manager.updateQueue([a, b]); manager.playFromPlaylist(b, playlistID: playlist.id, items: [b, a])

        rejectWrites = true
        MusicPlaylistCoordinator(store: store, playback: manager).synchronize(
            snapshot: MusicFavoritesReconciliationSnapshot(songs: [a]), library: [a]
        )
        XCTAssertTrue(store.reconciliationNeedsRepair)
        XCTAssertEqual(defaults.data(forKey: MusicPlaylistStore.persistenceKey), durableBefore)
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), [b.fileName, a.fileName])
        XCTAssertEqual(manager.queue.map(\.fileName), [a.fileName])
        XCTAssertNil(manager.currentTrack)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertNil(player.currentItem)
        XCTAssertTrue(MusicPlaylistStore(defaults: defaults).playlist(id: playlist.id)?.members.contains(where: { $0.fileName == b.fileName }) == true)

        rejectWrites = false
        MusicPlaylistCoordinator(store: store, playback: manager).synchronize(
            snapshot: MusicFavoritesReconciliationSnapshot(songs: [a]), library: [a]
        )
        XCTAssertFalse(store.reconciliationNeedsRepair)
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), [a.fileName])
        XCTAssertFalse(MusicPlaylistStore(defaults: defaults).playlist(id: playlist.id)?.members.contains(where: { $0.fileName == b.fileName }) == true)

        manager.updateQueue([a, b]); manager.playFromPlaylist(b, playlistID: playlist.id, items: [b, a])
        let replacement = MusicItem(
            url: b.url, duration: 30,
            favoriteSourceIdentity: .init(fileSize: 2, contentSHA256Hex: String(repeating: "c", count: 64))
        )
        manager.updateQueue([a, replacement])
        manager.reconcilePlaylistQueue(id: playlist.id, items: [a], reason: .authoritativeLibrary)
        XCTAssertNil(manager.currentTrack)
        XCTAssertNil(player.currentItem)

        XCTAssertTrue(store.add(b, to: playlist.id))
        let replacementSnapshot = MusicFavoritesReconciliationSnapshot(songs: [a, replacement])
        rejectWrites = true
        XCTAssertEqual(store.reconcile(with: replacementSnapshot), .repairRequired)
        XCTAssertTrue(store.reconciliationNeedsRepair)
        XCTAssertTrue(store.playlist(id: playlist.id)?.members.contains(where: { $0.fileName == b.fileName }) == true)
        rejectWrites = false
        XCTAssertEqual(store.reconcile(with: replacementSnapshot), .persisted)
        XCTAssertFalse(store.reconciliationNeedsRepair)
        XCTAssertFalse(store.playlist(id: playlist.id)?.members.contains(where: { $0.fileName == b.fileName }) == true)
    }

    func testCapturedRenameAndDeleteIntentsRejectReplacementRevisionAndFreshIntentSucceedsOnce() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let original = try XCTUnwrap(store.create(name: "Original"))
        let staleRename = try XCTUnwrap(store.intent(for: original.id))
        _ = store.create(name: "Other")
        XCTAssertFalse(store.rename(staleRename, name: "Stale"))
        let freshRename = try XCTUnwrap(store.intent(for: original.id))
        XCTAssertTrue(store.rename(freshRename, name: "Fresh"))
        XCTAssertFalse(store.rename(freshRename, name: "Twice"))
        let staleDelete = try XCTUnwrap(store.intent(for: original.id))
        _ = store.create(name: "Revision")
        XCTAssertFalse(store.delete(staleDelete))
        XCTAssertTrue(store.delete(try XCTUnwrap(store.intent(for: original.id))))
    }

    func testQueueScopeRestoresOnlyAfterPlaylistAndLibraryResolution() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        let a = item("a.mp3", byte: "a"), b = item("b.mp3", byte: "b")
        let playlist = try XCTUnwrap(store.create(name: "Mix")); _ = store.add(b, to: playlist.id); _ = store.add(a, to: playlist.id)
        var first: MusicPlaybackManager? = MusicPlaybackManager(defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController())
        first?.updateQueue([a, b]); first?.playFromPlaylist(b, playlistID: playlist.id, items: [b, a])
        defaults.set(7.0, forKey: "MusicPlayback.lastPositionSeconds")
        first = nil
        let restored = MusicPlaybackManager(defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController())
        XCTAssertEqual(restored.queueScope, .fullLibrary)
        restored.resolvePendingQueueScope(playlists: store, library: [a, b])
        XCTAssertEqual(restored.queueScope, .playlist(playlist.id))
        XCTAssertEqual(restored.queue.map(\.fileName), ["b.mp3", "a.mp3"])
        XCTAssertEqual(restored.currentTrack?.fileName, "b.mp3")
        XCTAssertEqual(restored.currentTime, 7)
    }

    func testDeletedMalformedFutureAndOversizedQueueScopeFallBackToFullLibrary() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let a = item("a.mp3", byte: "a")
        for data in [
            Data(#"{"version":2,"kind":"playlist","playlistID":"00000000-0000-0000-0000-000000000001"}"#.utf8),
            Data("malformed".utf8),
            Data(repeating: 0x61, count: 257),
        ] {
            let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
            defaults.set(data, forKey: MusicQueueScopeStore.key)
            let manager = MusicPlaybackManager(defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController())
            manager.resolvePendingQueueScope(playlists: store, library: [a])
            XCTAssertEqual(manager.queueScope, .fullLibrary)
            XCTAssertEqual(manager.queue, [a])
        }

        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        XCTAssertTrue(MusicQueueScopeStore(defaults: defaults).save(.playlist(UUID())))
        let manager = MusicPlaybackManager(defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController())
        manager.resolvePendingQueueScope(playlists: store, library: [a])
        XCTAssertEqual(manager.queueScope, .fullLibrary)
        XCTAssertEqual(manager.queue, [a])
    }

    func testExistingColdPlaylistKeepsScopeForPrunedUnknownAndEmptyMembership() throws {
        for mode in 0..<3 {
            let (store, cleanup) = try makeStore(); defer { cleanup() }
            let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
            let a = item("a-\(mode).mp3", byte: "a"), b = item("b-\(mode).mp3", byte: "b")
            let playlist = try XCTUnwrap(store.create(name: "Mix \(mode)"))
            if mode != 2 { _ = store.add(b, to: playlist.id); _ = store.add(a, to: playlist.id) }
            XCTAssertTrue(MusicQueueScopeStore(defaults: defaults).save(.playlist(playlist.id)))
            defaults.set(b.fileName, forKey: "MusicPlayback.lastTrackFileName")
            defaults.set(9.0, forKey: "MusicPlayback.lastPositionSeconds")
            if mode == 0 {
                store.reconcile(with: MusicFavoritesReconciliationSnapshot(songs: [a]))
            }
            let manager = MusicPlaybackManager(defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController())
            if mode == 1 {
                let unknownB = MusicItem(url: b.url, duration: 1, favoriteSourceIdentity: nil)
                manager.resolvePendingQueueScope(playlists: store, library: [unknownB, a])
                XCTAssertEqual(manager.queueScope, .playlist(playlist.id))
                XCTAssertNil(manager.currentTrack)
                MusicPlaylistCoordinator(store: store, playback: manager).synchronize(snapshot: MusicFavoritesReconciliationSnapshot(songs: [b, a]), library: [b, a])
                XCTAssertEqual(manager.currentTrack?.fileName, b.fileName)
                XCTAssertEqual(manager.currentTime, 9)
            } else {
                manager.resolvePendingQueueScope(playlists: store, library: [a])
                XCTAssertEqual(manager.queueScope, .playlist(playlist.id))
                XCTAssertNil(manager.currentTrack)
            }
        }
    }

    func testMalformedFutureAndDuplicatePersistenceFailsClosed() throws {
        let suite = "MusicPlaylistCorruption.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        for payload in [
            #"{"version":2,"playlists":[]}"#,
            #"{"version":1,"playlists":[{"id":"00000000-0000-0000-0000-000000000001","name":"Mix","members":[]},{"id":"00000000-0000-0000-0000-000000000001","name":"Other","members":[]}]}"#,
            #"{"version":1,"playlists":[{"id":"00000000-0000-0000-0000-000000000001","name":"Mix","members":[]},{"id":"00000000-0000-0000-0000-000000000002","name":"mix","members":[]}]}"#,
            #"{"version":1,"playlists":[{"id":"00000000-0000-0000-0000-000000000001","name":"Mix","members":[{"logicalLocation":"Music","fileName":"a.mp3","sourceIdentity":{"fileSize":1,"contentSHA256Hex":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},{"logicalLocation":"Music","fileName":"a.mp3","sourceIdentity":{"fileSize":2,"contentSHA256Hex":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}}]}]}"#,
        ] {
            defaults.set(Data(payload.utf8), forKey: MusicPlaylistStore.persistenceKey)
            XCTAssertTrue(MusicPlaylistStore(defaults: defaults).playlists.isEmpty)
        }
    }

    func testStoreExactStructuralBoundsAcceptAndBoundPlusOneIsAtomic() throws {
        XCTAssertEqual(MusicPlaylistStore.Limits.production.playlistCount, 100)
        XCTAssertEqual(MusicPlaylistStore.Limits.production.membersPerPlaylist, 1_000)
        XCTAssertEqual(MusicPlaylistStore.Limits.production.totalMemberAndTombstoneCount, 10_000)
        XCTAssertEqual(MusicPlaylistStore.Limits.production.payloadBytes, 512 * 1_024)

        let suite = "MusicPlaylistBounds.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let limits = MusicPlaylistStore.Limits(playlistCount: 2, membersPerPlaylist: 2, totalMemberAndTombstoneCount: 4, payloadBytes: 64 * 1_024)
        let store = MusicPlaylistStore(defaults: defaults, limits: limits)
        XCTAssertNotNil(store.create(name: "One")); XCTAssertNotNil(store.create(name: "Two"))
        assertRejectedMutationIsAtomic(store: store, defaults: defaults) { XCTAssertNil(store.create(name: "Three")) }

        let memberSuite = "MusicPlaylistMemberBounds.\(UUID().uuidString)"
        let memberDefaults = try XCTUnwrap(UserDefaults(suiteName: memberSuite)); defer { memberDefaults.removePersistentDomain(forName: memberSuite) }
        let memberStore = MusicPlaylistStore(defaults: memberDefaults, limits: limits)
        let playlist = try XCTUnwrap(memberStore.create(name: "Members"))
        XCTAssertTrue(memberStore.add(item("bound-a.mp3", byte: "a"), to: playlist.id))
        XCTAssertTrue(memberStore.add(item("bound-b.mp3", byte: "b"), to: playlist.id))
        assertRejectedMutationIsAtomic(store: memberStore, defaults: memberDefaults) {
            XCTAssertFalse(memberStore.add(item("bound-c.mp3", byte: "c"), to: playlist.id))
        }
    }

    func testStoreTotalBoundIncludesTombstonesAndRejectsOverflowAtomically() throws {
        let suite = "MusicPlaylistTotalBounds.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let limits = MusicPlaylistStore.Limits(playlistCount: 2, membersPerPlaylist: 3, totalMemberAndTombstoneCount: 2, payloadBytes: 64 * 1_024)
        let store = MusicPlaylistStore(defaults: defaults, limits: limits)
        let playlist = try XCTUnwrap(store.create(name: "Total"))
        for index in 0..<5 {
            let deleted = item("total-churn-\(index).mp3", byte: String(format: "%x", index))
            XCTAssertTrue(store.add(deleted, to: playlist.id)); XCTAssertTrue(store.removeFromAllPlaylists(deleted))
        }
        XCTAssertTrue(store.add(item("total-b.mp3", byte: "b"), to: playlist.id))
        XCTAssertTrue(store.add(item("total-c.mp3", byte: "c"), to: playlist.id))
        let reconstructed = MusicPlaylistStore(defaults: defaults, limits: limits)
        XCTAssertEqual(reconstructed.playlist(id: playlist.id)?.members.count, 2)
        assertRejectedMutationIsAtomic(store: reconstructed, defaults: defaults) {
            XCTAssertFalse(reconstructed.add(item("total-d.mp3", byte: "d"), to: playlist.id))
        }
    }

    func testStorePayloadExactBoundaryLoadsAndLargerCandidateOrPersistedPayloadFailsClosed() throws {
        let suite = "MusicPlaylistPayloadBounds.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let seed = MusicPlaylistStore(defaults: defaults)
        let playlist = try XCTUnwrap(seed.create(name: "A"))
        let exactBytes = try XCTUnwrap(defaults.data(forKey: MusicPlaylistStore.persistenceKey))
        let structural = MusicPlaylistStore.Limits(playlistCount: 2, membersPerPlaylist: 2, totalMemberAndTombstoneCount: 2, payloadBytes: exactBytes.count)
        var writeCount = 0
        let exact = MusicPlaylistStore(defaults: defaults, limits: structural) { data in
            writeCount += 1
            defaults.set(data, forKey: MusicPlaylistStore.persistenceKey)
            return defaults.data(forKey: MusicPlaylistStore.persistenceKey) == data
        }
        XCTAssertEqual(exact.playlists.count, 1)
        assertRejectedMutationIsAtomic(store: exact, defaults: defaults) {
            XCTAssertFalse(exact.rename(id: playlist.id, name: String(repeating: "Z", count: 100)))
        }
        XCTAssertEqual(writeCount, 0)
        let oversized = MusicPlaylistStore(defaults: defaults, limits: .init(
            playlistCount: 2, membersPerPlaylist: 2, totalMemberAndTombstoneCount: 2, payloadBytes: exactBytes.count - 1
        ))
        XCTAssertTrue(oversized.playlists.isEmpty)
        XCTAssertEqual(defaults.data(forKey: MusicPlaylistStore.persistenceKey), exactBytes)
    }

    func testStoreWriteAndReadbackFailuresRestorePersistentAndPublishedState() throws {
        for corruptsReadback in [false, true] {
            let suite = "MusicPlaylistAtomicFailure.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
            let seed = MusicPlaylistStore(defaults: defaults)
            let playlist = try XCTUnwrap(seed.create(name: "Before"))
            let baseline = try XCTUnwrap(defaults.data(forKey: MusicPlaylistStore.persistenceKey))
            let store = MusicPlaylistStore(defaults: defaults) { data in
                if corruptsReadback { defaults.set(Data("corrupt".utf8), forKey: MusicPlaylistStore.persistenceKey); return true }
                return false
            }
            assertRejectedMutationIsAtomic(store: store, defaults: defaults) {
                XCTAssertFalse(store.rename(id: playlist.id, name: "After"))
            }
            XCTAssertEqual(store.lastMutationFailure, corruptsReadback ? .readbackFailure : .persistenceFailure)
            XCTAssertEqual(defaults.data(forKey: MusicPlaylistStore.persistenceKey), baseline)
        }
    }

    func testNameGraphemeAndUTF8BoundsAndPlaylistDeletionNeverTouchesMedia() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        XCTAssertNotNil(store.create(name: String(repeating: "é", count: 100)))
        XCTAssertNil(store.create(name: String(repeating: "a", count: 101)))
        XCTAssertNil(store.create(name: String(repeating: "🧑🏽‍🚀", count: 81)))
        let song = item("keep.mp3", byte: "d")
        let playlist = try XCTUnwrap(store.create(name: "Disposable"))
        XCTAssertTrue(store.add(song, to: playlist.id))
        XCTAssertTrue(store.delete(try XCTUnwrap(store.intent(for: playlist.id))))
        XCTAssertTrue(FileManager.default.fileExists(atPath: song.url.path))
    }

    func testInvalidAndDuplicateMemberPayloadsFailClosed() throws {
        let suite = "MusicPlaylistMemberCorruption.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let member = #"{"logicalLocation":"Documents","fileName":"a.mp3","sourceIdentity":{"fileSize":1,"contentSHA256Hex":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}"#
        for payload in [
            "{\"version\":1,\"playlists\":[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Mix\",\"members\":[\(member),\(member)]}]}",
            #"{"version":1,"playlists":[{"id":"00000000-0000-0000-0000-000000000001","name":"Mix","members":[{"logicalLocation":"../escape","fileName":"a.mp3","sourceIdentity":{"fileSize":-1,"contentSHA256Hex":"bad"}}]}]}"#,
        ] {
            defaults.set(Data(payload.utf8), forKey: MusicPlaylistStore.persistenceKey)
            XCTAssertTrue(MusicPlaylistStore(defaults: defaults).playlists.isEmpty)
        }
    }

    func testPostUnlinkPersistenceFailureSurfacesRepairAndRetryPreventsIdenticalResurrection() async throws {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("PlaylistDelete-\(UUID().uuidString)", isDirectory: true)
        let documents = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = documents.appendingPathComponent("song.mp3")
        let bytes = Data("same authenticated bytes".utf8); try bytes.write(to: source)
        let storage = MediaLibraryStorage(rootURL: documents, legacyAudioURL: root.appendingPathComponent("OldAudio"), legacyVideoURL: root.appendingPathComponent("OldVideo"), fileManager: .default)
        let library = MusicLibrary(storage: storage, durationLoader: { _ in 1 })
        let snapshot = await library.refresh(); let song = try XCTUnwrap(library.songs.first)
        let (defaults, cleanDefaults) = try makeDefaults(); defer { cleanDefaults() }
        var rejectWrites = false
        let playlists = MusicPlaylistStore(defaults: defaults) { data in
            guard !rejectWrites else { return false }
            defaults.set(data, forKey: MusicPlaylistStore.persistenceKey)
            return defaults.data(forKey: MusicPlaylistStore.persistenceKey) == data
        }
        let playlist = try XCTUnwrap(playlists.create(name: "Delete repair")); XCTAssertTrue(playlists.add(song, to: playlist.id))
        let playback = MusicPlaybackManager(defaults: defaults, activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController())
        playback.updateQueue(library.songs)
        XCTAssertTrue(playlists.prepareMediaDeletion(song))
        rejectWrites = true
        do {
            try await MusicDeletionCoordinator.delete(song, library: library, playback: playback, favorites: MusicFavoritesStore(defaults: defaults), playlists: playlists)
            XCTFail("Post-unlink playlist persistence failure must surface")
        } catch MusicPlaylistDeletionPersistenceError.finalizeFailed {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(playlists.retryDeletedMembershipRepair(song, mode: .finalize))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertTrue(library.latestReconciliationPublication.reconciliationSnapshot.isAuthoritative)
        XCTAssertTrue(library.latestReconciliationPublication.songs.isEmpty)
        let durablePlaylist = try XCTUnwrap(playlists.playlist(id: playlist.id))
        XCTAssertEqual(MusicPlaylistLibraryIndex(library: library.songs).memberRows(for: durablePlaylist).first?.state, .unavailable)
        XCTAssertTrue(playback.queue.isEmpty)
        let repairState = MusicPlaylistMutationUIState(); repairState.record(.repairRequired)
        XCTAssertEqual(repairState.feedback?.failure, .repairRequired)
        XCTAssertEqual(repairState.feedback?.accessibilityIdentifier, "music-playlist-mutation-failure")
        XCTAssertEqual(MusicPlaylistStore(defaults: defaults).playlist(id: playlist.id)?.members.count, 1)
        XCTAssertTrue(MusicPlaylistStore(defaults: defaults).hasPendingMediaDeletion)
        rejectWrites = false
        XCTAssertTrue(playlists.retryDeletedMembershipRepair(song, mode: .finalize)); repairState.clear(); XCTAssertNil(repairState.feedback)
        try bytes.write(to: source)
        _ = await library.refresh()
        let reimported = try XCTUnwrap(library.songs.first)
        let reconstructed = MusicPlaylistStore(defaults: defaults)
        reconstructed.reconcile(with: snapshot)
        XCTAssertTrue(reconstructed.songs(in: playlist.id, library: [reimported]).isEmpty)
    }

    func testDeletionJournalRecoversCrashBeforeAndAfterUnlinkWithoutReimportResurrection() throws {
        let suite = "MusicPlaylistDeletionJournal.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = MusicPlaylistStore(defaults: defaults)
        let playlist = try XCTUnwrap(store.create(name: "Journal"))
        let song = item("journal.mp3", byte: "a"); XCTAssertTrue(store.add(song, to: playlist.id))

        XCTAssertTrue(store.prepareMediaDeletion(song))
        let beforeUnlink = MusicPlaylistStore(defaults: defaults)
        XCTAssertTrue(beforeUnlink.hasPendingMediaDeletion)
        let shiftedDate = Date(timeIntervalSinceNow: -30)
        try FileManager.default.setAttributes([.modificationDate: shiftedDate], ofItemAtPath: song.url.path)
        _ = beforeUnlink.reconcile(with: .init(songs: [song]), library: [song])
        XCTAssertFalse(beforeUnlink.hasPendingMediaDeletion)
        XCTAssertEqual(beforeUnlink.playlist(id: playlist.id)?.members.count, 1)

        XCTAssertTrue(beforeUnlink.prepareMediaDeletion(song))
        try FileManager.default.removeItem(at: song.url)
        let afterUnlink = MusicPlaylistStore(defaults: defaults)
        XCTAssertTrue(afterUnlink.hasPendingMediaDeletion)
        _ = afterUnlink.reconcile(with: .init(songs: []), library: [])
        XCTAssertFalse(afterUnlink.hasPendingMediaDeletion)
        XCTAssertTrue(afterUnlink.playlist(id: playlist.id)?.members.isEmpty == true)

        try Data("a".utf8).write(to: song.url, options: .atomic)
        let reimported = MusicItem(url: song.url, duration: 30, favoriteSourceIdentity: song.favoriteSourceIdentity)
        _ = afterUnlink.reconcile(with: .init(songs: [reimported]), library: [reimported])
        XCTAssertTrue(afterUnlink.playlist(id: playlist.id)?.members.isEmpty == true)
        XCTAssertTrue(afterUnlink.cancelPreparedMediaDeletion(reimported))

        let second = try XCTUnwrap(afterUnlink.create(name: "Reimport race"))
        let raced = item("journal-raced.mp3", byte: "b"); XCTAssertTrue(afterUnlink.add(raced, to: second.id))
        XCTAssertTrue(afterUnlink.prepareMediaDeletion(raced)); try FileManager.default.removeItem(at: raced.url)
        let crashed = MusicPlaylistStore(defaults: defaults)
        try Data("b".utf8).write(to: raced.url, options: .atomic)
        let identicalReimport = MusicItem(url: raced.url, duration: 30, favoriteSourceIdentity: raced.favoriteSourceIdentity)
        _ = crashed.reconcile(with: .init(songs: [identicalReimport]), library: [identicalReimport])
        XCTAssertFalse(crashed.hasPendingMediaDeletion)
        XCTAssertTrue(crashed.playlist(id: second.id)?.members.isEmpty == true)
    }

    func testDeletionJournalCancellationIsDurableAndPreservesMembershipAfterUnlinkFailure() throws {
        let suite = "MusicPlaylistDeletionJournalCancel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MusicPlaylistStore(defaults: defaults)
        let playlist = try XCTUnwrap(store.create(name: "Failed unlink"))
        let song = item("journal-unlink-failed.mp3", byte: "u")
        XCTAssertTrue(store.add(song, to: playlist.id))

        XCTAssertTrue(store.prepareMediaDeletion(song))
        XCTAssertTrue(store.hasPendingMediaDeletion)
        XCTAssertTrue(store.cancelPreparedMediaDeletion(song))

        let restarted = MusicPlaylistStore(defaults: defaults)
        XCTAssertFalse(restarted.hasPendingMediaDeletion)
        XCTAssertEqual(restarted.playlist(id: playlist.id)?.members.map(\.fileName), [song.fileName])
        XCTAssertTrue(FileManager.default.fileExists(atPath: song.url.path))
    }

    func testDeletionJournalFinalizationReadbackFailureSurvivesRestartAndRetries() throws {
        let suite = "MusicPlaylistDeletionJournalReadback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var corruptReadback = false
        let store = MusicPlaylistStore(defaults: defaults) { data in
            defaults.set(corruptReadback ? Data("corrupt".utf8) : data, forKey: MusicPlaylistStore.persistenceKey)
            return true
        }
        let playlist = try XCTUnwrap(store.create(name: "Readback repair"))
        let song = item("journal-readback.mp3", byte: "r")
        XCTAssertTrue(store.add(song, to: playlist.id))
        XCTAssertTrue(store.prepareMediaDeletion(song))
        XCTAssertTrue(store.markMediaDeletionUnlinked(song))
        let journalBytes = store.persistedPayloadData
        let revision = store.revision
        try FileManager.default.removeItem(at: song.url)

        corruptReadback = true
        XCTAssertFalse(store.finalizeMediaDeletion(song))
        XCTAssertEqual(store.lastMutationFailure, .readbackFailure)
        XCTAssertEqual(store.persistedPayloadData, journalBytes)
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), [song.fileName])

        let restarted = MusicPlaylistStore(defaults: defaults)
        XCTAssertTrue(restarted.hasPendingMediaDeletion)
        XCTAssertEqual(restarted.playlist(id: playlist.id)?.members.map(\.fileName), [song.fileName])
        corruptReadback = false
        XCTAssertTrue(store.retryDeletedMembershipRepair(song))
        XCTAssertFalse(store.hasPendingMediaDeletion)
        XCTAssertTrue(store.playlist(id: playlist.id)?.members.isEmpty == true)
    }

    func testPendingDeletionJournalBlocksDifferentItemUntilExactRecovery() throws {
        let (store, cleanup) = try makeStore(); defer { cleanup() }
        let playlist = try XCTUnwrap(store.create(name: "Journal ownership"))
        let a = item("journal-owner-a.mp3", byte: "a")
        let b = item("journal-owner-b.mp3", byte: "b")
        XCTAssertTrue(store.add(a, to: playlist.id)); XCTAssertTrue(store.add(b, to: playlist.id))
        XCTAssertTrue(store.prepareMediaDeletion(a))
        let bytes = store.persistedPayloadData, revision = store.revision

        XCTAssertFalse(store.prepareMediaDeletion(b))
        XCTAssertFalse(store.retryDeletedMembershipRepair(b))
        XCTAssertEqual(store.persistedPayloadData, bytes); XCTAssertEqual(store.revision, revision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.url.path))
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), [a.fileName, b.fileName])

        XCTAssertEqual(store.reconcile(with: .init(songs: [a, b]), library: [a, b]), .noChange)
        XCTAssertFalse(store.hasPendingMediaDeletion)
        XCTAssertTrue(store.prepareMediaDeletion(b))
    }

    func testUnknownAuthoritativeJournalEntryRemainsRepairableUntilExactSourceReturns() throws {
        let suite = "MusicPlaylistJournalUnknown.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let store = MusicPlaylistStore(defaults: defaults)
        let playlist = try XCTUnwrap(store.create(name: "Unknown journal"))
        let song = item("journal-unknown.mp3", byte: "a")
        XCTAssertTrue(store.add(song, to: playlist.id)); XCTAssertTrue(store.prepareMediaDeletion(song))
        let bytes = store.persistedPayloadData, revision = store.revision
        let unknown = MusicFavoritesReconciliationSnapshot.Entry(
            logicalLocation: song.url.deletingLastPathComponent().lastPathComponent,
            fileName: song.fileName,
            sourceIdentity: nil
        )
        XCTAssertEqual(store.reconcile(with: .init(isAuthoritative: true, entries: [unknown]), library: [MusicItem(url: song.url, duration: 30)]), .repairRequired)
        XCTAssertTrue(store.hasPendingMediaDeletion); XCTAssertTrue(store.reconciliationNeedsRepair)
        XCTAssertEqual(store.persistedPayloadData, bytes); XCTAssertEqual(store.revision, revision)

        XCTAssertEqual(store.reconcile(with: .init(songs: [song]), library: [song]), .noChange)
        XCTAssertFalse(store.hasPendingMediaDeletion); XCTAssertFalse(store.reconciliationNeedsRepair)
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.map(\.fileName), [song.fileName])
    }

    func testMalformedDeletionJournalPayloadFailsClosed() throws {
        let suite = "MusicPlaylistJournalCorruption.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let seed = MusicPlaylistStore(defaults: defaults)
        let playlist = try XCTUnwrap(seed.create(name: "Journal corruption"))
        let song = item("journal-corrupt.mp3", byte: "j")
        XCTAssertTrue(seed.add(song, to: playlist.id)); XCTAssertTrue(seed.prepareMediaDeletion(song))
        let validData = try XCTUnwrap(seed.persistedPayloadData)

        for mutation in 0..<3 {
            var root = try XCTUnwrap(JSONSerialization.jsonObject(with: validData) as? [String: Any])
            var journal = try XCTUnwrap(root["pendingDeletion"] as? [String: Any])
            switch mutation {
            case 0:
                journal["affectedPlaylistIDs"] = [playlist.id.uuidString, playlist.id.uuidString]
            case 1:
                journal["affectedPlaylistIDs"] = [UUID().uuidString]
            default:
                var session = try XCTUnwrap(journal["sessionSourceIdentity"] as? [String: Any])
                session["changeNanoseconds"] = -1
                journal["sessionSourceIdentity"] = session
            }
            root["pendingDeletion"] = journal
            defaults.set(try JSONSerialization.data(withJSONObject: root), forKey: MusicPlaylistStore.persistenceKey)
            XCTAssertTrue(MusicPlaylistStore(defaults: defaults).playlists.isEmpty)
        }
    }

    func testRetainedRepeatModesAdvanceIntoRemainingScopeBeforeApplyingPolicy() async throws {
        // Completion notifications exercise repeat policy on real playable media.
        // Placeholder bytes can asynchronously fail the retained repeatOne item
        // after the completion transition has already been observed.
        func playableItem(_ name: String) throws -> MusicItem {
            let url = fixtureDirectory.appendingPathComponent(name)
            try writeDetailRefreshAudio(to: url)
            return MusicItem(
                url: url, duration: 30,
                favoriteSourceIdentity: MusicPlaylistAuthenticatedSourceValidator.fingerprint(at: url)
            )
        }

        for mode in [MusicCompletionMode.repeatAll, .repeatOne] {
            let (defaults, cleanup) = try makeDefaults(); defer { cleanup() }
            let player = AVPlayer(), nowPlaying = RecordingNowPlayingController()
            let manager = MusicPlaybackManager(player: player, defaults: defaults, activateAudioSession: {}, nowPlayingController: nowPlaying)
            let b = try playableItem("matrix-b-\(mode.rawValue).wav")
            let a = try playableItem("matrix-a-\(mode.rawValue).wav")
            let c = try playableItem("matrix-c-\(mode.rawValue).wav")
            let id = UUID(); manager.updateQueue([b, a, c]); manager.setCompletionMode(mode)
            manager.playFromPlaylist(b, playlistID: id, items: [b, a, c])
            let removed = try XCTUnwrap(player.currentItem); manager.reconcilePlaylistQueue(id: id, items: [a, c])
            let generation = manager.trackLoadGeneration
            await postCompletion(removed, manager: manager)
            XCTAssertEqual(manager.currentTrack?.fileName, a.fileName)
            XCTAssertEqual(manager.trackLoadGeneration, generation + 1)
            XCTAssertEqual(nowPlaying.snapshots.last?.title, "matrix-a-\(mode.rawValue)")
            let aItem = try XCTUnwrap(player.currentItem)
            await postCompletion(aItem, manager: manager)
            switch mode {
            case .repeatOne:
                XCTAssertEqual(manager.currentTrack?.fileName, a.fileName)
                XCTAssertEqual(manager.trackLoadGeneration, generation + 1)
                XCTAssertTrue(manager.isPlaying)
            case .repeatAll:
                XCTAssertEqual(manager.currentTrack?.fileName, c.fileName)
                XCTAssertEqual(manager.trackLoadGeneration, generation + 2)
            case .stopAtEnd:
                XCTFail("stopAtEnd is covered by its immediate-stop regression")
            }
        }
    }

    func testRetainedCurrentStopAtEndStopsWithoutLoadingRemainingPlaylistItem() async throws {
        let (defaults, cleanup) = try makeDefaults(); defer { cleanup() }
        let player = AVPlayer(), nowPlaying = RecordingNowPlayingController()
        let manager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            activateAudioSession: {},
            nowPlayingController: nowPlaying
        )
        let b = item("retained-stop-b.mp3", byte: "b")
        let a = item("retained-stop-a.mp3", byte: "a")
        let id = UUID()
        manager.updateQueue([b, a])
        manager.setCompletionMode(.stopAtEnd)
        manager.playFromPlaylist(b, playlistID: id, items: [b, a])
        let completed = try XCTUnwrap(player.currentItem)
        manager.reconcilePlaylistQueue(id: id, items: [a])
        let generation = manager.trackLoadGeneration

        await postCompletion(completed, manager: manager)

        XCTAssertEqual(manager.queue.map(\.fileName), [a.fileName])
        XCTAssertEqual(manager.currentTrack?.fileName, b.fileName)
        XCTAssertTrue(player.currentItem === completed)
        XCTAssertEqual(manager.trackLoadGeneration, generation)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(nowPlaying.snapshots.last?.playbackRate, 0)
    }

    func testRetainedShuffleCompletionStopsWhenPlannerHasNoReadableTarget() async throws {
        let (defaults, cleanup) = try makeDefaults(); defer { cleanup() }
        let player = AVPlayer(), nowPlaying = RecordingNowPlayingController()
        let manager = MusicPlaybackManager(
            player: player, defaults: defaults, activateAudioSession: {}, nowPlayingController: nowPlaying,
            shuffleOrdering: { Array($0.reversed()) }, isShuffleTrackReadable: { _ in false }
        )
        let b = item("shuffle-stop-b.mp3", byte: "b"), a = item("shuffle-stop-a.mp3", byte: "a"), c = item("shuffle-stop-c.mp3", byte: "c")
        let id = UUID(); manager.updateQueue([b, a, c]); manager.playFromPlaylist(b, playlistID: id, items: [b, a, c])
        manager.setShuffleEnabled(true)
        let completed = try XCTUnwrap(player.currentItem), generation = manager.trackLoadGeneration
        manager.reconcilePlaylistQueue(id: id, items: [a, c])
        await postCompletion(completed, manager: manager)
        XCTAssertEqual(manager.trackLoadGeneration, generation)
        XCTAssertEqual(manager.currentTrack?.fileName, b.fileName)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(nowPlaying.snapshots.last?.playbackRate, 0)
        XCTAssertFalse(manager.queue.contains(where: { $0.fileName == b.fileName }))
    }

    func testCreateTrimsNameRejectsEmptyAndUsesDeterministicSuffix() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let first = try XCTUnwrap(store.create(name: "  Road Trip\n"))
        let second = try XCTUnwrap(store.create(name: "road trip"))
        XCTAssertEqual(first.name, "Road Trip")
        XCTAssertEqual(second.name, "road trip (2)")
        XCTAssertNil(store.create(name: " \n "))
        XCTAssertEqual(store.revision, 2)
    }

    func testMembershipIsOrderedIdempotentDurableAndContainerNeutral() throws {
        let suite = "MusicPlaylistPersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MusicPlaylistStore(defaults: defaults)
        let playlist = try XCTUnwrap(store.create(name: "Mix"))
        let a = item("a.mp3", byte: "a")
        let b = item("b.mp3", byte: "b")
        XCTAssertTrue(store.add(b, to: playlist.id))
        XCTAssertTrue(store.add(a, to: playlist.id))
        XCTAssertTrue(store.add(b, to: playlist.id))
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.count, 2)

        let relocated = [
            MusicItem(url: URL(fileURLWithPath: "/new/container/\(fixtureDirectory.lastPathComponent)/b.mp3"), duration: 2, favoriteSourceIdentity: b.favoriteSourceIdentity),
            MusicItem(url: URL(fileURLWithPath: "/new/container/\(fixtureDirectory.lastPathComponent)/a.mp3"), duration: 2, favoriteSourceIdentity: a.favoriteSourceIdentity),
        ]
        let reloaded = MusicPlaylistStore(defaults: defaults)
        XCTAssertEqual(reloaded.songs(in: playlist.id, library: relocated).map(\.fileName), ["b.mp3", "a.mp3"])
    }

    func testStaleIntentsCannotRenameOrRemoveReplacementState() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let playlist = try XCTUnwrap(store.create(name: "Original"))
        let song = item("a.mp3", byte: "a")
        XCTAssertTrue(store.add(song, to: playlist.id))
        let staleRevision = store.revision
        XCTAssertTrue(store.rename(id: playlist.id, name: "New"))
        XCTAssertFalse(store.rename(id: playlist.id, name: "Stale", expectedRevision: staleRevision))
        XCTAssertFalse(store.remove(song, from: playlist.id, expectedRevision: staleRevision))
        XCTAssertEqual(store.playlist(id: playlist.id)?.name, "New")
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.count, 1)
    }

    func testAuthoritativeReplacementPrunesButUnavailableSnapshotDoesNot() throws {
        let suite = "MusicPlaylistTriState.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MusicPlaylistStore(defaults: defaults)
        let playlist = try XCTUnwrap(store.create(name: "Mix"))
        let song = item("a.mp3", byte: "a")
        XCTAssertTrue(store.add(song, to: playlist.id))
        store.reconcile(with: .unavailable)
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.count, 1)
        let revision = store.revision
        let bytes = defaults.data(forKey: MusicPlaylistStore.persistenceKey)
        let unknown = MusicFavoritesReconciliationSnapshot.Entry(
            logicalLocation: fixtureDirectory.lastPathComponent, fileName: "a.mp3", sourceIdentity: nil
        )
        store.reconcile(with: MusicFavoritesReconciliationSnapshot(isAuthoritative: true, entries: [unknown]))
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.count, 1)
        XCTAssertEqual(defaults.data(forKey: MusicPlaylistStore.persistenceKey), bytes)
        store.reconcile(with: MusicFavoritesReconciliationSnapshot(isAuthoritative: true, entries: [unknown, unknown]))
        XCTAssertEqual(store.revision, revision)
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.count, 1)
        XCTAssertEqual(defaults.data(forKey: MusicPlaylistStore.persistenceKey), bytes)
        let replacement = MusicFavoritesReconciliationSnapshot.Entry(
            logicalLocation: fixtureDirectory.lastPathComponent, fileName: "a.mp3",
            sourceIdentity: MusicFavoriteSourceIdentity(fileSize: 1, contentSHA256Hex: String(repeating: "b", count: 64))
        )
        store.reconcile(with: MusicFavoritesReconciliationSnapshot(isAuthoritative: true, entries: [replacement]))
        XCTAssertEqual(store.playlist(id: playlist.id)?.members.count, 0)
    }

    private func item(_ name: String, byte: String) -> MusicItem {
        let url = fixtureDirectory.appendingPathComponent(name)
        try? Data(byte.utf8).write(to: url, options: .atomic)
        return MusicItem(
            url: url, duration: 30,
            favoriteSourceIdentity: MusicPlaylistAuthenticatedSourceValidator.fingerprint(at: url)
        )
    }

    private func assertRejectedMutationIsAtomic(
        store: MusicPlaylistStore,
        defaults: UserDefaults,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ mutation: () -> Void
    ) {
        let playlists = store.playlists
        let revision = store.revision
        let bytes = defaults.data(forKey: MusicPlaylistStore.persistenceKey)
        mutation()
        XCTAssertEqual(store.playlists, playlists, file: file, line: line)
        XCTAssertEqual(store.revision, revision, file: file, line: line)
        XCTAssertEqual(defaults.data(forKey: MusicPlaylistStore.persistenceKey), bytes, file: file, line: line)
    }

    private func postCompletion(
        _ item: AVPlayerItem,
        manager: MusicPlaybackManager,
        accepted: Bool = true
    ) async {
        let notificationBefore = manager.completionNotificationGeneration
        let transitionBefore = manager.completionTransitionGeneration
        let converged = expectation(description: accepted ? "completion transition converged" : "stale completion rejected")
        var cancellable: AnyCancellable?
        let publisher = accepted
            ? manager.$completionTransitionGeneration.eraseToAnyPublisher()
            : manager.$completionNotificationGeneration.eraseToAnyPublisher()
        let threshold = accepted ? transitionBefore : notificationBefore
        cancellable = publisher
            .filter { $0 > threshold }
            .prefix(1)
            .sink { _ in converged.fulfill() }
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        await fulfillment(of: [converged], timeout: 1)
        withExtendedLifetime(cancellable) {}
        XCTAssertEqual(manager.completionNotificationGeneration, notificationBefore + 1)
        XCTAssertEqual(manager.completionTransitionGeneration, transitionBefore + (accepted ? 1 : 0))
    }

    private func makeStore() throws -> (MusicPlaylistStore, () -> Void) {
        let suite = "MusicPlaylistTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (MusicPlaylistStore(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    private func makeDefaults() throws -> (UserDefaults, () -> Void) {
        let suite = "MusicPlaylistManagerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }
}

@MainActor
private final class CheapPublicationEnrichmentGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var isReleased = false
    var isWaiting: Bool { !continuations.isEmpty }

    func wait(entered: XCTestExpectation) async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            entered.fulfill()
        }
    }

    func release() {
        isReleased = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

private final class PlaylistScanFailureFileManager: FileManager, @unchecked Sendable {
    // Used only by this MainActor test and MediaLibraryStorage's MainActor scan.
    var failingDirectory: URL?
    private(set) var scanFailureCount = 0

    override func contentsOfDirectory(
        at url: URL,
        includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []
    ) throws -> [URL] {
        if url.standardizedFileURL == failingDirectory?.standardizedFileURL {
            scanFailureCount += 1
            throw CocoaError(.fileReadNoPermission)
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }
}
