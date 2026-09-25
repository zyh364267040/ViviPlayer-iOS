import AVFoundation
import Combine
import MediaPlayer
import SwiftUI
import UIKit
import XCTest
@testable import DrivePlayer

@MainActor
final class MusicNowPlayingSnapshotTests: XCTestCase {
    func testShufflePreferenceDefaultsOffAndRoundTripsVersionedValueFailSafe() throws {
        let suite = "MusicShufflePreferenceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MusicShufflePreferenceStore(defaults: defaults)

        XCTAssertFalse(store.load())
        store.save(true)
        XCTAssertTrue(MusicShufflePreferenceStore(defaults: defaults).load())

        for value: Any in ["corrupt", ["version": 2, "enabled": true], ["version": 1, "enabled": "yes"]] {
            defaults.set(value, forKey: MusicShufflePreferenceStore.key)
            XCTAssertFalse(store.load())
        }
    }

    func testShufflePlannerKeepsCurrentStableAndExhaustsUniquePlanBeforeNewCycle() {
        var planner = MusicShufflePlanner(ordering: { Array($0.reversed()) })

        planner.setEnabled(true, currentID: "A", eligibleIDs: ["A", "B", "C"])

        XCTAssertEqual(planner.next(currentID: "A", eligibleIDs: ["A", "B", "C"]), "C")
        XCTAssertEqual(planner.next(currentID: "C", eligibleIDs: ["A", "B", "C"]), "B")
        XCTAssertEqual(planner.next(currentID: "B", eligibleIDs: ["A", "B", "C"]), "C")
    }

    func testShufflePlannerPreviousFollowsActualHistoryAndNextRetracesPrevious() {
        var planner = MusicShufflePlanner(ordering: { Array($0.reversed()) })
        let eligible = ["A", "B", "C"]
        planner.setEnabled(true, currentID: "A", eligibleIDs: eligible)
        XCTAssertEqual(planner.next(currentID: "A", eligibleIDs: eligible), "C")
        XCTAssertEqual(planner.next(currentID: "C", eligibleIDs: eligible), "B")

        XCTAssertEqual(planner.previous(currentID: "B", eligibleIDs: eligible), "C")
        XCTAssertEqual(planner.previous(currentID: "C", eligibleIDs: eligible), "A")
        XCTAssertEqual(planner.next(currentID: "A", eligibleIDs: eligible), "C")
    }

    func testShufflePlannerPreviousPreservesRepeatedHistoryAcrossCycleBoundary() {
        var planner = MusicShufflePlanner(ordering: { Array($0.reversed()) })
        let eligible = ["A", "B", "C"]
        planner.setEnabled(true, currentID: "A", eligibleIDs: eligible)
        XCTAssertEqual(planner.next(currentID: "A", eligibleIDs: eligible), "C")
        XCTAssertEqual(planner.next(currentID: "C", eligibleIDs: eligible), "B")
        XCTAssertEqual(planner.next(currentID: "B", eligibleIDs: eligible), "C")

        XCTAssertEqual(planner.previous(currentID: "C", eligibleIDs: eligible), "B")
        XCTAssertEqual(planner.previous(currentID: "B", eligibleIDs: eligible), "C")
        XCTAssertEqual(planner.previous(currentID: "C", eligibleIDs: eligible), "A")
    }

    func testShufflePlannerReconcilePrunesDeletedItemsAndAddsNewUniqueItems() {
        var planner = MusicShufflePlanner(ordering: { $0 })
        planner.setEnabled(true, currentID: "A", eligibleIDs: ["A", "B", "C"])
        XCTAssertEqual(planner.next(currentID: "A", eligibleIDs: ["A", "B", "C"]), "B")

        planner.reconcile(currentID: "B", eligibleIDs: ["B", "D", "D"])

        XCTAssertNil(planner.previous(currentID: "B", eligibleIDs: ["B", "D"]), "Deleted history must be pruned")
        XCTAssertEqual(planner.next(currentID: "B", eligibleIDs: ["B", "D"]), "D")
        XCTAssertEqual(planner.next(currentID: "D", eligibleIDs: ["B", "D"]), "B")
    }

    func testShufflePlannerSanitizesMalformedOrderingAndCoversEveryEligibleTarget() {
        var planner = MusicShufflePlanner(ordering: { _ in ["C", "C", "foreign"] })
        planner.setEnabled(true, currentID: "A", eligibleIDs: ["A", "B", "C"])

        XCTAssertEqual(planner.next(currentID: "A", eligibleIDs: ["A", "B", "C"]), "C")
        XCTAssertEqual(planner.next(currentID: "C", eligibleIDs: ["A", "B", "C"]), "B")
    }

    // Source contract only, NOT a runtime complexity proof. The production planner
    // accepts concrete [String] values; its ordering seam cannot count comparisons.
    // Deliberately scoped to next's unique eligibility array, not other methods.
    func testShufflePlannerNextSourceContractRejectsUniqueEligibilityArrayContains() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("DrivePlayer/Services/MusicPlaybackManager.swift"),
            encoding: .utf8
        )
        let plannerStart = try XCTUnwrap(source.range(of: "struct MusicShufflePlanner {"))
        let nextStart = try XCTUnwrap(source.range(
            of: "mutating func next(", range: plannerStart.upperBound..<source.endIndex
        ))
        let nextEnd = try XCTUnwrap(source.range(
            of: "mutating func previous(", range: nextStart.upperBound..<source.endIndex
        ))
        let nextSource = String(source[nextStart.lowerBound..<nextEnd.lowerBound])
        // Capture the array binding so merely renaming `eligible` cannot pass.
        // A Set(Self.unique(...)) binding is intentionally not an array match.
        let arrayBinding = try NSRegularExpression(
            pattern: #"\b(?:let|var)\s+(\w+)\s*(?::\s*\[String\])?\s*=\s*Self\s*\.\s*unique\s*\(\s*eligibleIDs\s*\)"#
        )
        for match in arrayBinding.matches(in: nextSource, range: NSRange(nextSource.startIndex..., in: nextSource)) {
            let nameRange = try XCTUnwrap(Range(match.range(at: 1), in: nextSource))
            let name = String(nextSource[nameRange])
            let membership = #"\b"# + NSRegularExpression.escapedPattern(for: name) + #"\s*\.\s*contains\s*\("#
            XCTAssertNil(
                nextSource.range(of: membership, options: .regularExpression),
                "Source contract: next must not scan its unique eligibility Array with contains for each upcoming ID; use Set membership while preserving ordered candidates. This is not a runtime complexity proof."
            )
        }
    }

    func testShufflePlannerNextLargeOrderedCycleDeduplicatesAndRefillsInInputOrder() throws {
        // Non-lexical order exposes sorting or Set iteration replacing array order.
        let ids = (0..<512).map { "track-\(($0 * 137) % 512)" }
        let eligible = ids + Array(ids.reversed())
        var orderingInputs: [[String]] = []
        var planner = MusicShufflePlanner(ordering: {
            orderingInputs.append($0)
            return $0
        })
        var current = ids[0]
        planner.setEnabled(true, currentID: current, eligibleIDs: eligible)
        var visited: [String] = []
        for expected in ids.dropFirst() {
            let target = try XCTUnwrap(planner.next(currentID: current, eligibleIDs: eligible))
            XCTAssertEqual(target, expected)
            XCTAssertNotEqual(target, current)
            visited.append(target)
            current = target
        }
        XCTAssertEqual(visited, Array(ids.dropFirst()))
        XCTAssertEqual(Set(visited).count, ids.count - 1)
        XCTAssertEqual(orderingInputs, [Array(ids.dropFirst())], "Refill only after exhausting the unique plan")
        XCTAssertEqual(planner.next(currentID: current, eligibleIDs: eligible), ids[0])
        XCTAssertEqual(orderingInputs, [Array(ids.dropFirst()), Array(ids.dropLast())])
    }

    func testShufflePlannerNextPrunesLargePlanWithoutReorderingSurvivors() {
        let ids = (0..<5_000).map { "track-\($0)" }
        var planner = MusicShufflePlanner(ordering: { $0 })
        planner.setEnabled(true, currentID: ids[0], eligibleIDs: ids)
        // Change eligibility directly, without reconcile. Existing plan order wins
        // over the new eligibility order until refill; current must be excluded.
        let eligible = [ids[4_999], ids[2_500], ids[17], ids[17]]
        XCTAssertEqual(planner.next(currentID: ids[2_500], eligibleIDs: eligible), ids[17])
        XCTAssertEqual(planner.next(currentID: ids[17], eligibleIDs: eligible), ids[4_999])
        XCTAssertEqual(planner.next(currentID: ids[4_999], eligibleIDs: eligible), ids[2_500])
    }

    func testShufflePlannerNextPreservesHistoryAndRetracesAfterEligibilityPruning() {
        var planner = MusicShufflePlanner(ordering: { $0 })
        let eligible = ["A", "B", "C", "D", "E", "B"]
        planner.setEnabled(true, currentID: "A", eligibleIDs: eligible)
        XCTAssertEqual(planner.next(currentID: "A", eligibleIDs: eligible), "B")
        XCTAssertEqual(planner.next(currentID: "B", eligibleIDs: eligible), "C")
        let remaining = ["E", "D", "C", "A", "D"]
        XCTAssertEqual(planner.next(currentID: "C", eligibleIDs: remaining), "D")
        XCTAssertEqual(planner.previous(currentID: "D", eligibleIDs: remaining), "C")
        XCTAssertEqual(planner.previous(currentID: "C", eligibleIDs: remaining), "A", "Removed B must leave history")
        XCTAssertNil(planner.previous(currentID: "A", eligibleIDs: remaining))
        XCTAssertEqual(planner.next(currentID: "A", eligibleIDs: remaining), "C")
        XCTAssertEqual(planner.next(currentID: "C", eligibleIDs: remaining), "D")
        XCTAssertEqual(planner.next(currentID: "D", eligibleIDs: remaining), "E")
    }

    func testShufflePlannerNextNoTargetDoesNotAppendHistoryAndCanResume() {
        for unavailable in [[String](), ["B"], ["B", "B"]] {
            var planner = MusicShufflePlanner(ordering: { $0 })
            XCTAssertNil(planner.next(currentID: "A", eligibleIDs: ["A", "B"]))
            planner.setEnabled(true, currentID: "A", eligibleIDs: ["A", "B", "C"])
            XCTAssertEqual(planner.next(currentID: "A", eligibleIDs: ["A", "B", "C"]), "B")
            XCTAssertNil(planner.next(currentID: "B", eligibleIDs: unavailable))
            XCTAssertNil(planner.next(currentID: "B", eligibleIDs: unavailable))
            XCTAssertEqual(planner.previous(currentID: "B", eligibleIDs: ["A", "B"]), "A", "Failed next must not record B")
            XCTAssertNil(planner.previous(currentID: "A", eligibleIDs: ["A", "B"]))
            XCTAssertEqual(planner.next(currentID: "A", eligibleIDs: ["A", "B"]), "B")
            planner.setEnabled(false, currentID: "B", eligibleIDs: ["A", "B"])
            XCTAssertNil(planner.next(currentID: "B", eligibleIDs: ["A", "B"]))
            XCTAssertNil(planner.previous(currentID: "B", eligibleIDs: ["A", "B"]))
        }
    }

    func testRepeatAllNaturalCompletionAdvancesToNextQueueItem() {
        XCTAssertEqual(
            MusicCompletionPolicy.decision(mode: .repeatAll, currentIndex: 0, queueCount: 2),
            .advance(to: 1)
        )
    }

    func testRepeatAllFinalItemWrapsToQueueStart() {
        XCTAssertEqual(
            MusicCompletionPolicy.decision(mode: .repeatAll, currentIndex: 2, queueCount: 3),
            .advance(to: 0)
        )
    }

    func testRepeatAllOneItemRestartsCurrentItem() {
        XCTAssertEqual(
            MusicCompletionPolicy.decision(mode: .repeatAll, currentIndex: 0, queueCount: 1),
            .restartCurrent
        )
    }

    func testRepeatOneRestartsAnyValidCurrentItem() {
        XCTAssertEqual(MusicCompletionPolicy.decision(mode: .repeatOne, currentIndex: 0, queueCount: 1), .restartCurrent)
        XCTAssertEqual(MusicCompletionPolicy.decision(mode: .repeatOne, currentIndex: 1, queueCount: 3), .restartCurrent)
    }

    func testStopAtEndStopsAtEveryValidQueuePosition() {
        XCTAssertEqual(MusicCompletionPolicy.decision(mode: .stopAtEnd, currentIndex: 0, queueCount: 3), .stop)
        XCTAssertEqual(MusicCompletionPolicy.decision(mode: .stopAtEnd, currentIndex: 1, queueCount: 3), .stop)
        XCTAssertEqual(MusicCompletionPolicy.decision(mode: .stopAtEnd, currentIndex: 2, queueCount: 3), .stop)
    }

    func testStopAtEndStopsWhenSuccessorExists() {
        XCTAssertEqual(MusicCompletionPolicy.decision(mode: .stopAtEnd, currentIndex: 0, queueCount: 2), .stop)
    }

    func testCompletionPolicyInvalidQueueStateFailsClosed() {
        for (index, count) in [(0, 0), (-1, 2), (2, 2)] {
            XCTAssertEqual(MusicCompletionPolicy.decision(mode: .repeatAll, currentIndex: index, queueCount: count), .stop)
            XCTAssertEqual(MusicCompletionPolicy.decision(mode: .repeatOne, currentIndex: index, queueCount: count), .stop)
            XCTAssertEqual(MusicCompletionPolicy.decision(mode: .stopAtEnd, currentIndex: index, queueCount: count), .stop)
        }
    }

    func testCompletionModeStoreRoundTripsAllModesAcrossInstances() throws {
        let suite = "MusicCompletionModeStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        for mode in [MusicCompletionMode.repeatAll, .repeatOne, .stopAtEnd] {
            MusicCompletionModeStore(defaults: defaults).save(mode)
            XCTAssertEqual(MusicCompletionModeStore(defaults: defaults).load(), mode)
        }
    }

    func testCompletionModeStoreDefaultsMissingCorruptUnknownAndFutureValuesToRepeatAll() throws {
        let suite = "MusicCompletionModeStoreFallbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MusicCompletionModeStore(defaults: defaults)
        XCTAssertEqual(store.load(), .repeatAll)
        for value: Any in ["corrupt", ["version": 1, "mode": "shuffle"], ["version": 2, "mode": "repeatOne"]] {
            defaults.set(value, forKey: MusicCompletionModeStore.key)
            XCTAssertEqual(store.load(), .repeatAll)
        }
    }

    func testBluetoothCarLyricsControlIsAvailableOnlyForDecodedSynchronizedLyrics() {
        let payload = Data([0x00, 0x65, 0x6E, 0x67, 0x02, 0x01, 0x00,
                            0x43, 0x75, 0x65, 0x00, 0, 0, 0, 0])
        let synchronized = MusicMetadata(title: "Song", artist: nil, album: nil,
            artworkData: nil, lyrics: nil, synchronizedLyricsData: payload)
        let plain = MusicMetadata(title: "Song", artist: nil, album: nil,
            artworkData: nil, lyrics: "plain", synchronizedLyricsData: nil)

        XCTAssertTrue(MusicDetailPresentation(track: MusicItem(
            url: URL(fileURLWithPath: "/tmp/a.mp3"), duration: 1, metadata: synchronized
        )).supportsBluetoothCarLyrics)
        XCTAssertFalse(MusicDetailPresentation(track: MusicItem(
            url: URL(fileURLWithPath: "/tmp/b.mp3"), duration: 1, metadata: plain
        )).supportsBluetoothCarLyrics)
    }

    func testDisabledBluetoothLyricsKeepsTrackIdentityMetadata() throws {
        let metadata = MusicMetadata(
            title: "Real Title",
            artist: "Real Artist",
            album: "Real Album",
            artworkData: nil,
            lyrics: nil,
            synchronizedLyricsData: nil
        )
        let track = MusicItem(url: URL(fileURLWithPath: "/tmp/file.mp3"), duration: 60, metadata: metadata)

        let snapshot = try XCTUnwrap(NowPlayingSnapshot.make(
            track: track,
            duration: 60,
            elapsedTime: 10,
            isPlaying: true,
            bluetoothLyricsEnabled: false,
            isBluetoothA2DPRoute: true
        ))

        XCTAssertEqual(snapshot.title, "Real Title")
        XCTAssertEqual(snapshot.artist, "Real Artist")
        XCTAssertEqual(snapshot.album, "Real Album")
    }

    func testEnabledA2DPUsesCueAtPlaybackTime() throws {
        let payload = Data([0x00, 0x65, 0x6E, 0x67, 0x02, 0x01, 0x00,
                            0x46, 0x69, 0x72, 0x73, 0x74, 0x00, 0, 0, 0, 0,
                            0x53, 0x65, 0x63, 0x6F, 0x6E, 0x64, 0x00, 0, 0, 0x03, 0xE8])
        let metadata = MusicMetadata(title: "Song", artist: "Artist", album: "Album",
                                     artworkData: nil, lyrics: nil, synchronizedLyricsData: payload)
        let track = MusicItem(url: URL(fileURLWithPath: "/tmp/song.mp3"), duration: 60, metadata: metadata)

        let snapshot = try XCTUnwrap(NowPlayingSnapshot.make(
            track: track, duration: 60, elapsedTime: 1, isPlaying: true,
            bluetoothLyricsEnabled: true, isBluetoothA2DPRoute: true
        ))

        XCTAssertEqual(snapshot.title, "Second")
    }

    func testActiveLyricTitleUsesOriginalTitleAndArtistAsContextAndKeepsAlbum() throws {
        let payload = Data([0x00, 0x65, 0x6E, 0x67, 0x02, 0x01, 0x00,
                            0x43, 0x75, 0x65, 0x00, 0, 0, 0, 0])
        let metadata = MusicMetadata(title: "Original", artist: "Artist", album: "Album",
                                     artworkData: nil, lyrics: nil, synchronizedLyricsData: payload)
        let track = MusicItem(url: URL(fileURLWithPath: "/tmp/file.mp3"), duration: 60, metadata: metadata)

        let snapshot = try XCTUnwrap(NowPlayingSnapshot.make(
            track: track, duration: 60, elapsedTime: 0, isPlaying: true,
            bluetoothLyricsEnabled: true, isBluetoothA2DPRoute: true
        ))

        XCTAssertEqual(snapshot.artist, "Original · Artist")
        XCTAssertEqual(snapshot.album, "Album")
    }

    func testLyricCueSanitizationTrimsRejectsEmptyAndBoundsUnicodeByUTF8Bytes() {
        XCTAssertEqual(NowPlayingSnapshot.sanitizedLyricTitle("  hello \n"), "hello")
        XCTAssertNil(NowPlayingSnapshot.sanitizedLyricTitle(" \n\t "))

        let bounded = NowPlayingSnapshot.sanitizedLyricTitle(String(repeating: "👩🏽‍🚗", count: 30))
        XCTAssertNotNil(bounded)
        XCTAssertLessThanOrEqual(bounded!.utf8.count, 240)
        XCTAssertTrue(String(repeating: "👩🏽‍🚗", count: 30).hasPrefix(bounded!))
    }

    func testLyricDisplaySegmentsPreserveShortAndEmptyBehaviorAndReconstructLongUnicode() {
        XCTAssertEqual(NowPlayingSnapshot.lyricDisplaySegments("  short line \n"), ["short line"])
        XCTAssertEqual(NowPlayingSnapshot.lyricDisplaySegments(" \n\t "), [])

        let text = "一路向前👩🏽‍🚗不要回头e\u{301}，星光仍在前方闪耀"
        let segments = NowPlayingSnapshot.lyricDisplaySegments(text)

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { $0.count <= 12 })
        XCTAssertEqual(segments.joined(), text)
        XCTAssertFalse(segments.contains { $0.contains("...") || $0.contains("…") })
    }

    func testLyricDisplaySegmentsRetainExistingUTF8SafetyBoundBeforeChunking() throws {
        let oversized = String(repeating: "你", count: 200)
        let segments = NowPlayingSnapshot.lyricDisplaySegments(oversized)
        let reconstructed = segments.joined()

        XCTAssertEqual(reconstructed, try XCTUnwrap(NowPlayingSnapshot.sanitizedLyricTitle(oversized)))
        XCTAssertLessThanOrEqual(reconstructed.utf8.count, 240)
        XCTAssertTrue(segments.allSatisfy { $0.count <= 12 })
    }

    func testLyricDisplaySegmentPreservesWhitespaceOnlyChunkAfterWholeCueSanitization() {
        let text = "abcdefghijkl            tail"

        XCTAssertEqual(
            NowPlayingSnapshot.lyricDisplaySegments(text),
            ["abcdefghijkl", "            ", "tail"]
        )
        XCTAssertEqual(
            NowPlayingSnapshot.lyricDisplaySegment(text, cueStartTime: 0, elapsedTime: 1.5),
            "            "
        )
    }

    func testLongLyricRotatesEveryOnePointFiveSecondsWrapsAndIgnoresPlayingState() throws {
        var payload = Data([0x00, 0x65, 0x6E, 0x67, 0x02, 0x01, 0x00])
        payload.append(contentsOf: "abcdefghijklmnopqrstuvwx123456".utf8)
        payload.append(contentsOf: [0, 0, 0, 0, 0])
        let metadata = MusicMetadata(title: "Song", artist: nil, album: nil,
            artworkData: nil, lyrics: nil, synchronizedLyricsData: payload)
        let track = MusicItem(url: URL(fileURLWithPath: "/tmp/song.mp3"), duration: 60, metadata: metadata)

        func title(at elapsedTime: TimeInterval, playing: Bool = true) throws -> String {
            try XCTUnwrap(NowPlayingSnapshot.make(track: track, duration: 60,
                elapsedTime: elapsedTime, isPlaying: playing,
                bluetoothLyricsEnabled: true, isBluetoothA2DPRoute: true)).title
        }

        XCTAssertEqual(try title(at: 0), "abcdefghijkl")
        XCTAssertEqual(try title(at: 1.499), "abcdefghijkl")
        XCTAssertEqual(try title(at: 1.5), "mnopqrstuvwx")
        XCTAssertEqual(try title(at: 3), "123456")
        XCTAssertEqual(try title(at: 4.5), "abcdefghijkl")
        XCTAssertEqual(try title(at: 1.5, playing: false), try title(at: 1.5, playing: true))
    }

    func testLyricRotationUsesCueRelativeTimeResetsAtNextCueAndSeeksDeterministically() throws {
        var payload = Data([0x00, 0x65, 0x6E, 0x67, 0x02, 0x01, 0x00])
        payload.append(contentsOf: "abcdefghijklmnopqrstuvwx".utf8)
        payload.append(contentsOf: [0, 0, 0, 0x07, 0xD0])
        payload.append(contentsOf: "next cue has enough text".utf8)
        payload.append(contentsOf: [0, 0, 0, 0x1F, 0x40])
        let metadata = MusicMetadata(title: "Song", artist: nil, album: nil,
            artworkData: nil, lyrics: nil, synchronizedLyricsData: payload)
        let track = MusicItem(url: URL(fileURLWithPath: "/tmp/song.mp3"), duration: 60, metadata: metadata)

        func title(at elapsedTime: TimeInterval) throws -> String {
            try XCTUnwrap(NowPlayingSnapshot.make(track: track, duration: 60,
                elapsedTime: elapsedTime, isPlaying: true,
                bluetoothLyricsEnabled: true, isBluetoothA2DPRoute: true)).title
        }

        XCTAssertEqual(try title(at: 2), "abcdefghijkl")
        XCTAssertEqual(try title(at: 3.5), "mnopqrstuvwx")
        XCTAssertEqual(try title(at: 8), "next cue has")
        XCTAssertEqual(try title(at: 2), "abcdefghijkl")
    }

    func testLyricPolicyFallsBackWhenDisabledNotA2DPBeforeFirstCueOrCueIsEmpty() throws {
        func track(cue: String, timestamp: UInt32) -> MusicItem {
            var payload = Data([0x00, 0x65, 0x6E, 0x67, 0x02, 0x01, 0x00])
            payload.append(contentsOf: cue.utf8); payload.append(0)
            payload.append(contentsOf: [UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xff),
                                        UInt8((timestamp >> 8) & 0xff), UInt8(timestamp & 0xff)])
            let metadata = MusicMetadata(title: "Original", artist: "Artist", album: "Album",
                artworkData: nil, lyrics: nil, synchronizedLyricsData: payload)
            return MusicItem(url: URL(fileURLWithPath: "/tmp/song.mp3"), duration: 60, metadata: metadata)
        }
        func title(_ item: MusicItem, time: TimeInterval, enabled: Bool, route: Bool) throws -> String {
            try XCTUnwrap(NowPlayingSnapshot.make(track: item, duration: 60, elapsedTime: time,
                isPlaying: true, bluetoothLyricsEnabled: enabled, isBluetoothA2DPRoute: route)).title
        }

        XCTAssertEqual(try title(track(cue: "Cue", timestamp: 0), time: 1, enabled: false, route: true), "Original")
        XCTAssertEqual(try title(track(cue: "Cue", timestamp: 0), time: 1, enabled: true, route: false), "Original")
        XCTAssertEqual(try title(track(cue: "Cue", timestamp: 2_000), time: 1, enabled: true, route: true), "Original")
        XCTAssertEqual(try title(track(cue: "  \n", timestamp: 0), time: 1, enabled: true, route: true), "Original")
    }

    func testSnapshotIsNilWithoutTrackAndSanitizesTitleTimeAndRate() {
        XCTAssertNil(NowPlayingSnapshot.make(track: nil, duration: 20, elapsedTime: 3, isPlaying: true))
        let track = MusicItem(url: URL(fileURLWithPath: "/tmp/Road Song.mp3"), duration: nil)
        XCTAssertEqual(NowPlayingSnapshot.make(track: track, duration: .infinity, elapsedTime: .nan, isPlaying: false), NowPlayingSnapshot(title: "Road Song", duration: 0, elapsedTime: 0, playbackRate: 0))
        XCTAssertEqual(NowPlayingSnapshot.make(track: track, duration: 90, elapsedTime: 120, isPlaying: true), NowPlayingSnapshot(title: "Road Song", duration: 90, elapsedTime: 90, playbackRate: 1))
    }

    func testVideoSnapshotIsNilWithoutVideoAndSanitizesTitleTimeAndRate() throws {
        XCTAssertNil(NowPlayingSnapshot.make(video: nil, duration: 20, elapsedTime: 3, isPlaying: true))
        let video = VideoItem(url: URL(fileURLWithPath: "/tmp/Road Movie.mp4"), duration: nil)

        let paused = try XCTUnwrap(NowPlayingSnapshot.make(video: video, duration: .infinity, elapsedTime: .nan, isPlaying: false))
        XCTAssertEqual(paused.title, "Road Movie")
        XCTAssertEqual(paused.duration, 0)
        XCTAssertEqual(paused.elapsedTime, 0)
        XCTAssertEqual(paused.playbackRate, 0)
        XCTAssertNil(paused.artworkData)

        let playing = try XCTUnwrap(NowPlayingSnapshot.make(video: video, duration: 90, elapsedTime: 120, isPlaying: true))
        XCTAssertEqual(playing.duration, 90)
        XCTAssertEqual(playing.elapsedTime, 90)
        XCTAssertEqual(playing.playbackRate, 1)
    }

    func testVideoSnapshotPublishesSelectedPlaybackRateOnlyWhilePlaying() throws {
        let video = VideoItem(url: URL(fileURLWithPath: "/tmp/Playback Rate Movie.mp4"), duration: nil)

        let playing = try XCTUnwrap(
            NowPlayingSnapshot.make(
                video: video,
                duration: 90,
                elapsedTime: 30,
                isPlaying: true,
                playbackRate: 1.5
            )
        )
        XCTAssertEqual(playing.playbackRate, 1.5, accuracy: 1e-9)

        let paused = try XCTUnwrap(
            NowPlayingSnapshot.make(
                video: video,
                duration: 90,
                elapsedTime: 30,
                isPlaying: false,
                playbackRate: 1.5
            )
        )
        XCTAssertEqual(paused.playbackRate, 0, accuracy: 1e-9)

        for unsafeRate: Double in [0, -1, 0.6, 3, .nan, .infinity, -.infinity] {
            let snapshot = try XCTUnwrap(
                NowPlayingSnapshot.make(
                    video: video,
                    duration: 90,
                    elapsedTime: 30,
                    isPlaying: true,
                    playbackRate: unsafeRate
                )
            )
            XCTAssertEqual(snapshot.playbackRate, 1, accuracy: 1e-9)
        }
    }

    func testVideoRemoteSkipCommandsUseFifteenSecondsAndClampToDuration() {
        XCTAssertEqual(
            VideoRemoteCommandDecision.action(
                for: MusicRemoteCommand.skipBackward,
                currentTime: 10,
                duration: 100,
                isPlaying: true
            ),
            .seek(0)
        )
        XCTAssertEqual(
            VideoRemoteCommandDecision.action(
                for: MusicRemoteCommand.skipForward,
                currentTime: 10,
                duration: 100,
                isPlaying: true
            ),
            .seek(25)
        )
        XCTAssertEqual(
            VideoRemoteCommandDecision.action(
                for: MusicRemoteCommand.skipForward,
                currentTime: 95,
                duration: 100,
                isPlaying: true
            ),
            .seek(100)
        )
        XCTAssertNil(
            VideoRemoteCommandDecision.action(
                for: MusicRemoteCommand.skipBackward,
                currentTime: 10,
                duration: 0,
                isPlaying: true
            )
        )
        XCTAssertNil(
            VideoRemoteCommandDecision.action(
                for: MusicRemoteCommand.skipForward,
                currentTime: 10,
                duration: .infinity,
                isPlaying: true
            )
        )
    }

    func testVideoRemotePlayPauseAndToggleRespectCurrentState() {
        XCTAssertEqual(
            VideoRemoteCommandDecision.action(for: .play, currentTime: 10, duration: 100, isPlaying: false),
            .play
        )
        XCTAssertNil(
            VideoRemoteCommandDecision.action(for: .play, currentTime: 10, duration: 100, isPlaying: true)
        )
        XCTAssertEqual(
            VideoRemoteCommandDecision.action(for: .pause, currentTime: 10, duration: 100, isPlaying: true),
            .pause
        )
        XCTAssertNil(
            VideoRemoteCommandDecision.action(for: .pause, currentTime: 10, duration: 100, isPlaying: false)
        )
        XCTAssertEqual(
            VideoRemoteCommandDecision.action(for: .togglePlayPause, currentTime: 10, duration: 100, isPlaying: false),
            .play
        )
        XCTAssertEqual(
            VideoRemoteCommandDecision.action(for: .togglePlayPause, currentTime: 10, duration: 100, isPlaying: true),
            .pause
        )

        XCTAssertNil(
            VideoRemoteCommandDecision.action(for: .nextTrack, currentTime: 10, duration: 100, isPlaying: true)
        )
        XCTAssertNil(
            VideoRemoteCommandDecision.action(for: .previousTrack, currentTime: 10, duration: 100, isPlaying: true)
        )
    }

    func testVideoRemoteDecisionMapsValidChangePlaybackPositionToSeek() {
        XCTAssertEqual(
            VideoRemoteCommandDecision.action(
                for: .changePlaybackPosition(42.5),
                currentTime: 10,
                duration: 100,
                isPlaying: true
            ),
            .seek(42.5)
        )
    }

    func testVideoRemoteTransportDoesNotRequireKnownDurationButSkipDoes() {
        XCTAssertEqual(
            VideoRemoteCommandDecision.action(for: .play, currentTime: 0, duration: 0, isPlaying: false),
            .play
        )
        XCTAssertEqual(
            VideoRemoteCommandDecision.action(for: .pause, currentTime: 0, duration: 0, isPlaying: true),
            .pause
        )
        XCTAssertEqual(
            VideoRemoteCommandDecision.action(for: .togglePlayPause, currentTime: 0, duration: 0, isPlaying: false),
            .play
        )
        XCTAssertNil(
            VideoRemoteCommandDecision.action(for: .skipForward, currentTime: 0, duration: 0, isPlaying: false)
        )
        XCTAssertNil(
            VideoRemoteCommandDecision.action(for: .skipBackward, currentTime: 0, duration: 0, isPlaying: false)
        )
        XCTAssertEqual(
            VideoRemoteCommandDecision.action(
                for: .play,
                currentTime: .nan,
                duration: .infinity,
                isPlaying: false
            ),
            .play
        )
    }

    func testRemoteCommandExecutorBridgeDecisionDistinguishesMainExecutorFromMainThread() {
        XCTAssertEqual(
            MusicRemoteCommandExecutorBridge.decision(isMainThread: true, isMainExecutor: true),
            MusicRemoteCommandExecutorDecision.runDirectly
        )
        XCTAssertEqual(
            MusicRemoteCommandExecutorBridge.decision(isMainThread: false, isMainExecutor: false),
            MusicRemoteCommandExecutorDecision.synchronizeToMainExecutor
        )
        XCTAssertEqual(
            MusicRemoteCommandExecutorBridge.decision(isMainThread: true, isMainExecutor: false),
            MusicRemoteCommandExecutorDecision.failClosed
        )
    }
}

@MainActor
final class RecordingNowPlayingController: MusicNowPlayingControlling {
    private(set) var snapshots: [NowPlayingSnapshot] = []
    private(set) var clearCount = 0
    private(set) var registrationCount = 0
    private var handler: (@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)?

    func publish(_ snapshot: NowPlayingSnapshot) { snapshots.append(snapshot) }
    func clear() { clearCount += 1 }
    func registerRemoteCommands(handler: @escaping @MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult) {
        registrationCount += 1
        self.handler = handler
    }
    func send(_ command: MusicRemoteCommand) -> MusicRemoteCommandResult { handler?(command) ?? .commandFailed }
}

@MainActor
final class RecordingVideoNowPlayingController: VideoNowPlayingControlling {
    private(set) var snapshots: [NowPlayingSnapshot] = []
    private(set) var clearCount = 0
    private(set) var registrationCount = 0
    private var handler: (@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)?

    func publish(_ snapshot: NowPlayingSnapshot) { snapshots.append(snapshot) }
    func clear() { clearCount += 1 }
    func registerVideoRemoteCommands(
        handler: @escaping @MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult
    ) {
        registrationCount += 1
        self.handler = handler
    }
    func send(_ command: MusicRemoteCommand) -> MusicRemoteCommandResult { handler?(command) ?? .commandFailed }
}

@MainActor
private final class ManualMusicSleepTimerScheduler {
    final class Token: MusicSleepTimerCancellation {
        private(set) var isCancelled = false
        func cancel() { isCancelled = true }
    }

    private(set) var scheduled: [(delay: TimeInterval, token: Token, action: @MainActor () -> Void)] = []

    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> MusicSleepTimerCancellation {
        let token = Token()
        scheduled.append((delay, token, action))
        return token
    }

    func fire(at index: Int) {
        let entry = scheduled[index]
        guard !entry.token.isCancelled else { return }
        entry.action()
    }

    func fireIgnoringCancellation(at index: Int) {
        scheduled[index].action()
    }
}

@MainActor
final class MusicSleepTimerTests: XCTestCase {
    func testFifteenMinuteTimerUsesInjectedDeadlineAndStopsWithoutChangingTrackOrPosition() async throws {
        let suite = "MusicSleepTimerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var monotonicNow: TimeInterval = 100
        var wallNow = Date(timeIntervalSince1970: 1_000)
        let scheduler = ManualMusicSleepTimerScheduler()
        let player = AVPlayer()
        let nowPlaying = RecordingNowPlayingController()
        let manager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            activateAudioSession: {},
            nowPlayingController: nowPlaying,
            sleepTimerClock: MusicSleepTimerClock(
                monotonicNow: { monotonicNow },
                wallNow: { wallNow }
            ),
            scheduleSleepTimer: scheduler.schedule(after:action:)
        )
        let tracks = [
            MusicItem(url: URL(fileURLWithPath: "/tmp/A.mp3"), duration: 1_800),
            MusicItem(url: URL(fileURLWithPath: "/tmp/B.mp3"), duration: 1_800),
        ]
        manager.updateQueue(tracks)
        manager.play(tracks[0])
        manager.seekCompletionCallback(to: 123)(true)
        await Task.yield()

        manager.setSleepTimerMode(.minutes15)

        XCTAssertEqual(manager.sleepTimerMode, .minutes15)
        XCTAssertEqual(try XCTUnwrap(scheduler.scheduled.last?.delay), 900, accuracy: 0.001)
        monotonicNow += 900
        wallNow.addTimeInterval(900)
        scheduler.fire(at: 0)

        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertEqual(manager.currentIndex, 0)
        XCTAssertEqual(manager.currentTime, 123)
        XCTAssertEqual(manager.queue, tracks)
        XCTAssertEqual(manager.sleepTimerMode, .off)
        XCTAssertEqual(defaults.string(forKey: "MusicPlayback.lastTrackFileName"), "A.mp3")
        XCTAssertEqual(defaults.double(forKey: "MusicPlayback.lastPositionSeconds"), 123)
        XCTAssertEqual(nowPlaying.snapshots.last?.playbackRate, 0)
    }

    func testStopAfterCurrentTrackOverridesCompletionPreferenceAndShuffleWithoutChangingPreference() async throws {
        let suite = "MusicSleepTimerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AVPlayer()
        let nowPlaying = RecordingNowPlayingController()
        let tracks = ["A", "B", "C"].map {
            MusicItem(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), duration: 30)
        }
        let manager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            activateAudioSession: {},
            nowPlayingController: nowPlaying,
            shuffleOrdering: { Array($0.reversed()) },
            isShuffleTrackReadable: { _ in true }
        )
        manager.updateQueue(tracks)
        manager.setCompletionMode(.repeatOne)
        manager.play(tracks[0])
        manager.setShuffleEnabled(true)
        manager.setSleepTimerMode(.stopAfterCurrentTrack)

        NotificationCenter.default.post(
            name: .AVPlayerItemDidPlayToEndTime,
            object: try XCTUnwrap(player.currentItem)
        )
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertEqual(manager.currentIndex, 0)
        XCTAssertEqual(manager.sleepTimerMode, .off)
        XCTAssertEqual(manager.completionMode, .repeatOne)
        XCTAssertTrue(manager.isShuffleEnabled)
        XCTAssertEqual(nowPlaying.snapshots.last?.playbackRate, 0)
    }

    func testVideoOwnershipInvalidatesTimedCallbackBeforeLaterUnrelatedMusicSession() throws {
        let suite = "MusicSleepTimerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var monotonicNow: TimeInterval = 100
        var wallNow = Date(timeIntervalSince1970: 1_000)
        let scheduler = ManualMusicSleepTimerScheduler()
        let ownership = PlaybackOwnershipCoordinator()
        let manager = MusicPlaybackManager(
            defaults: defaults,
            ownership: ownership,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            sleepTimerClock: MusicSleepTimerClock(
                monotonicNow: { monotonicNow },
                wallNow: { wallNow }
            ),
            scheduleSleepTimer: scheduler.schedule(after:action:)
        )
        let tracks = ["A", "B"].map {
            MusicItem(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), duration: 1_800)
        }
        manager.updateQueue(tracks)
        manager.play(tracks[0])
        manager.setSleepTimerMode(.minutes15)

        let videoIntent = ownership.videoPlaybackRequested { manager.pause() }
        XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent))
        manager.play(tracks[1])
        XCTAssertTrue(manager.isPlaying)

        monotonicNow += 900
        wallNow.addTimeInterval(900)
        scheduler.fireIgnoringCancellation(at: 0)

        XCTAssertTrue(manager.isPlaying)
        XCTAssertEqual(manager.currentTrack, tracks[1])
        XCTAssertEqual(manager.sleepTimerMode, .off)
    }

    func testCurrentTrackDisappearanceCancelsTimerAndLateCallbackCannotAffectLaterTrack() throws {
        let suite = "MusicSleepTimerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var monotonicNow: TimeInterval = 0
        var wallNow = Date(timeIntervalSince1970: 0)
        let scheduler = ManualMusicSleepTimerScheduler()
        let manager = MusicPlaybackManager(
            defaults: defaults,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            sleepTimerClock: MusicSleepTimerClock(
                monotonicNow: { monotonicNow },
                wallNow: { wallNow }
            ),
            scheduleSleepTimer: scheduler.schedule(after:action:)
        )
        let first = MusicItem(url: URL(fileURLWithPath: "/tmp/A.mp3"), duration: 1_800)
        let later = MusicItem(url: URL(fileURLWithPath: "/tmp/B.mp3"), duration: 1_800)
        manager.updateQueue([first])
        manager.play(first)
        manager.setSleepTimerMode(.minutes15)

        manager.updateQueue([])
        XCTAssertEqual(manager.sleepTimerMode, .off)
        manager.updateQueue([later])
        manager.play(later)
        monotonicNow += 900
        wallNow.addTimeInterval(900)
        scheduler.fireIgnoringCancellation(at: 0)

        XCTAssertTrue(manager.isPlaying)
        XCTAssertEqual(manager.currentTrack, later)
    }

    func testSleepTimerPresentationAndFullPlayerSceneWiringAreAccessible() throws {
        XCTAssertEqual(MusicSleepTimerPresentation.optionLabel(for: .off), "关闭")
        XCTAssertEqual(MusicSleepTimerPresentation.optionLabel(for: .minutes15), "15 分钟")
        XCTAssertEqual(MusicSleepTimerPresentation.optionLabel(for: .minutes30), "30 分钟")
        XCTAssertEqual(MusicSleepTimerPresentation.optionLabel(for: .minutes60), "60 分钟")
        XCTAssertEqual(MusicSleepTimerPresentation.optionLabel(for: .stopAfterCurrentTrack), "本曲结束后停止")
        XCTAssertEqual(
            MusicSleepTimerPresentation.statusText(mode: .minutes15, remaining: 899),
            "睡眠定时：15 分钟（14:59）"
        )
        XCTAssertEqual(
            MusicSleepTimerPresentation.statusText(mode: .stopAfterCurrentTrack, remaining: nil),
            "睡眠定时：本曲结束后停止"
        )

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let playerSource = try String(
            contentsOf: root.appendingPathComponent("DrivePlayer/Views/MusicPlayerView.swift"),
            encoding: .utf8
        )
        let rootSource = try String(
            contentsOf: root.appendingPathComponent("DrivePlayer/Views/RootTabView.swift"),
            encoding: .utf8
        )
        for fragment in [
            "Menu {",
            "playback.setSleepTimerMode(mode)",
            "TimelineView(.periodic",
            ".accessibilityIdentifier(\"music-sleep-timer-menu\")",
            ".accessibilityValue(statusText)",
            ".disabled(playback.currentTrack == nil)",
        ] {
            XCTAssertTrue(playerSource.contains(fragment), "MusicPlayerView.swift is missing: \(fragment)")
        }
        XCTAssertTrue(rootSource.contains("playback.reconcileSleepTimerDeadline()"))
    }

    func testTimedModesUseExactDurationsAndRepeatedSetCancelRearmAreIdempotent() throws {
        let suite = "MusicSleepTimerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now: TimeInterval = 10
        var date = Date(timeIntervalSince1970: 10)
        let scheduler = ManualMusicSleepTimerScheduler()
        let manager = MusicPlaybackManager(
            defaults: defaults,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            sleepTimerClock: MusicSleepTimerClock(monotonicNow: { now }, wallNow: { date }),
            scheduleSleepTimer: scheduler.schedule(after:action:)
        )
        let track = MusicItem(url: URL(fileURLWithPath: "/tmp/A.mp3"), duration: 5_000)
        manager.updateQueue([track]); manager.play(track)

        manager.setSleepTimerMode(.minutes15)
        manager.setSleepTimerMode(.minutes15)
        XCTAssertEqual(scheduler.scheduled.map(\.delay), [900])
        manager.setSleepTimerMode(.minutes30)
        XCTAssertTrue(scheduler.scheduled[0].token.isCancelled)
        XCTAssertEqual(scheduler.scheduled.map(\.delay), [900, 1_800])
        now += 900; date.addTimeInterval(900)
        scheduler.fireIgnoringCancellation(at: 0)
        XCTAssertTrue(manager.isPlaying)
        XCTAssertEqual(manager.sleepTimerMode, .minutes30)

        manager.cancelSleepTimer(); manager.cancelSleepTimer()
        XCTAssertEqual(manager.sleepTimerMode, .off)
        XCTAssertTrue(scheduler.scheduled[1].token.isCancelled)

        manager.setSleepTimerMode(.minutes60)
        XCTAssertEqual(scheduler.scheduled.last?.delay, 3_600)
    }

    func testWallClockReconciliationStopsAtRealDeadlineWithoutCumulativeDrift() throws {
        let suite = "MusicSleepTimerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var monotonicNow: TimeInterval = 100
        var wallNow = Date(timeIntervalSince1970: 1_000)
        let scheduler = ManualMusicSleepTimerScheduler()
        let manager = MusicPlaybackManager(
            defaults: defaults,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            sleepTimerClock: MusicSleepTimerClock(
                monotonicNow: { monotonicNow },
                wallNow: { wallNow }
            ),
            scheduleSleepTimer: scheduler.schedule(after:action:)
        )
        let track = MusicItem(url: URL(fileURLWithPath: "/tmp/A.mp3"), duration: 2_000)
        manager.updateQueue([track]); manager.play(track); manager.setSleepTimerMode(.minutes15)

        monotonicNow += 300
        wallNow.addTimeInterval(300)
        scheduler.fireIgnoringCancellation(at: 0)
        XCTAssertEqual(try XCTUnwrap(manager.sleepTimerRemainingTime()), 600, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(scheduler.scheduled.last?.delay), 600, accuracy: 0.001)

        wallNow.addTimeInterval(600)
        manager.reconcileSleepTimerDeadline()
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(manager.currentTrack, track)
        XCTAssertEqual(manager.sleepTimerMode, .off)
    }

    func testTimedCountdownSurvivesManualPauseResumeAndAppRemoteTrackChanges() throws {
        let suite = "MusicSleepTimerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = ManualMusicSleepTimerScheduler()
        let remote = RecordingNowPlayingController()
        let manager = MusicPlaybackManager(
            defaults: defaults,
            activateAudioSession: {},
            nowPlayingController: remote,
            sleepTimerClock: MusicSleepTimerClock(monotonicNow: { 0 }, wallNow: { .distantPast }),
            scheduleSleepTimer: scheduler.schedule(after:action:)
        )
        let tracks = ["A", "B", "C"].map {
            MusicItem(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), duration: 2_000)
        }
        manager.updateQueue(tracks); manager.play(tracks[0]); manager.setSleepTimerMode(.minutes30)

        manager.pause(); XCTAssertEqual(manager.sleepTimerMode, .minutes30)
        manager.play(); XCTAssertEqual(manager.sleepTimerMode, .minutes30)
        manager.next(); XCTAssertEqual(manager.currentTrack, tracks[1])
        XCTAssertEqual(manager.sleepTimerMode, .minutes30)
        XCTAssertEqual(remote.send(.previousTrack), .success)
        XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertEqual(manager.sleepTimerMode, .minutes30)
        XCTAssertEqual(remote.send(.nextTrack), .success)
        XCTAssertEqual(manager.currentTrack, tracks[1])
        XCTAssertEqual(manager.sleepTimerMode, .minutes30)
        XCTAssertEqual(scheduler.scheduled.count, 1)
    }

    func testStopAfterCurrentRemainsArmedAcrossManualTrackChangesThenStopsNextNaturalEnd() async throws {
        let suite = "MusicSleepTimerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = AVPlayer()
        let remote = RecordingNowPlayingController()
        let manager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            activateAudioSession: {},
            nowPlayingController: remote
        )
        let tracks = ["A", "B", "C"].map {
            MusicItem(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), duration: 30)
        }
        manager.updateQueue(tracks); manager.play(tracks[0]); manager.setSleepTimerMode(.stopAfterCurrentTrack)
        manager.next(); XCTAssertEqual(manager.currentTrack, tracks[1])
        XCTAssertEqual(remote.send(.nextTrack), .success)
        XCTAssertEqual(manager.currentTrack, tracks[2])
        XCTAssertEqual(manager.sleepTimerMode, .stopAfterCurrentTrack)

        NotificationCenter.default.post(
            name: .AVPlayerItemDidPlayToEndTime,
            object: try XCTUnwrap(player.currentItem)
        )
        await Task.yield(); await Task.yield()

        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(manager.currentTrack, tracks[2])
        XCTAssertEqual(manager.sleepTimerMode, .off)
    }

    func testSleepTimerIsSessionOnlyAndColdReconstructionStartsOff() throws {
        let suite = "MusicSleepTimerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let track = MusicItem(url: URL(fileURLWithPath: "/tmp/A.mp3"), duration: 2_000)
        let first = MusicPlaybackManager(
            defaults: defaults,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController()
        )
        first.updateQueue([track]); first.play(track); first.setSleepTimerMode(.minutes60)
        XCTAssertEqual(first.sleepTimerMode, .minutes60)

        let reconstructed = MusicPlaybackManager(
            defaults: defaults,
            nowPlayingController: RecordingNowPlayingController()
        )
        reconstructed.updateQueue([track])
        XCTAssertEqual(reconstructed.sleepTimerMode, .off)
        XCTAssertNil(reconstructed.sleepTimerRemainingTime())
        XCTAssertFalse(reconstructed.isPlaying)
    }

    func testSourceReplacementCancelsTimerWhileExactSourceReorderPreservesIt() throws {
        let suite = "MusicSleepTimerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = ManualMusicSleepTimerScheduler()
        let manager = MusicPlaybackManager(
            defaults: defaults,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            sleepTimerClock: MusicSleepTimerClock(monotonicNow: { 0 }, wallNow: { .distantPast }),
            scheduleSleepTimer: scheduler.schedule(after:action:)
        )
        let libraryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SleepTimerReorder-\(UUID().uuidString)", isDirectory: true)
        let replacementRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SleepTimerDifferentURL-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: libraryRoot)
            try? FileManager.default.removeItem(at: replacementRoot)
        }
        let firstURL = libraryRoot.appendingPathComponent("A.mp3")
        let otherURL = libraryRoot.appendingPathComponent("B.mp3")
        let replacementURL = replacementRoot.appendingPathComponent("A.mp3")
        try Data("A".utf8).write(to: firstURL)
        try Data("B".utf8).write(to: otherURL)
        try Data("replacement A".utf8).write(to: replacementURL)
        let first = MusicItem(url: firstURL, duration: 1_800)
        let other = MusicItem(url: otherURL, duration: 1_800)
        manager.updateQueue([first, other]); manager.play(first); manager.setSleepTimerMode(.minutes15)

        manager.updateQueue([other, first])
        XCTAssertEqual(manager.currentTrack, first)
        XCTAssertEqual(manager.currentIndex, 1)
        XCTAssertEqual(manager.sleepTimerMode, .minutes15)

        let differentURL = MusicItem(url: replacementURL, duration: 1_800)
        manager.updateQueue([other, differentURL])
        XCTAssertEqual(manager.currentTrack, differentURL)
        XCTAssertEqual(manager.sleepTimerMode, .off)
        XCTAssertTrue(scheduler.scheduled[0].token.isCancelled)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SleepTimerSourceReplacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sameURL = root.appendingPathComponent("Same.mp3")
        try Data("original".utf8).write(to: sameURL)
        let original = MusicItem(url: sameURL, duration: 1_800)
        manager.updateQueue([original]); manager.play(original); manager.setSleepTimerMode(.minutes30)
        try Data("replacement-with-new-inode".utf8).write(to: sameURL, options: .atomic)
        manager.updateQueue([MusicItem(url: sameURL, duration: 1_800)])

        XCTAssertEqual(manager.sleepTimerMode, .off)
        XCTAssertTrue(scheduler.scheduled[1].token.isCancelled)
    }

    func testStopAfterCurrentPrecedesEveryCompletionPreferenceWithShuffleOnAndOff() async throws {
        for completionMode in MusicCompletionMode.allCases {
            for shuffleEnabled in [false, true] {
                let suite = "MusicSleepTimerTests.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let player = AVPlayer()
                let nowPlaying = RecordingNowPlayingController()
                let tracks = ["A", "B", "C"].map {
                    MusicItem(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), duration: 30)
                }
                let manager = MusicPlaybackManager(
                    player: player,
                    defaults: defaults,
                    activateAudioSession: {},
                    nowPlayingController: nowPlaying,
                    shuffleOrdering: { Array($0.reversed()) },
                    isShuffleTrackReadable: { _ in true }
                )
                manager.updateQueue(tracks)
                manager.setCompletionMode(completionMode)
                manager.play(tracks[0])
                manager.setShuffleEnabled(shuffleEnabled)
                manager.setSleepTimerMode(.stopAfterCurrentTrack)
                let snapshotCount = nowPlaying.snapshots.count

                NotificationCenter.default.post(
                    name: .AVPlayerItemDidPlayToEndTime,
                    object: try XCTUnwrap(player.currentItem)
                )
                await Task.yield(); await Task.yield()

                XCTAssertFalse(manager.isPlaying, "mode=\(completionMode), shuffle=\(shuffleEnabled)")
                XCTAssertEqual(manager.currentTrack, tracks[0])
                XCTAssertEqual(manager.currentIndex, 0)
                XCTAssertEqual(manager.queue, tracks)
                XCTAssertEqual(manager.completionMode, completionMode)
                XCTAssertEqual(manager.isShuffleEnabled, shuffleEnabled)
                XCTAssertEqual(manager.sleepTimerMode, .off)
                XCTAssertEqual(nowPlaying.snapshots.count, snapshotCount + 1)
                XCTAssertEqual(nowPlaying.snapshots.last?.playbackRate, 0)
            }
        }
    }

    func testDeadlineCallbackSceneReconciliationAndLateCallbackApplyTerminalEffectsExactlyOnce() async throws {
        let suite = "MusicSleepTimerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var monotonicNow: TimeInterval = 10
        var wallNow = Date(timeIntervalSince1970: 10)
        let scheduler = ManualMusicSleepTimerScheduler()
        let player = AVPlayer()
        let nowPlaying = RecordingNowPlayingController()
        let tracks = ["A", "B"].map {
            MusicItem(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), duration: 2_000)
        }
        let manager = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            activateAudioSession: {},
            nowPlayingController: nowPlaying,
            sleepTimerClock: MusicSleepTimerClock(
                monotonicNow: { monotonicNow },
                wallNow: { wallNow }
            ),
            scheduleSleepTimer: scheduler.schedule(after:action:)
        )
        manager.updateQueue(tracks)
        manager.setCompletionMode(.stopAtEnd)
        manager.play(tracks[0])
        manager.seekCompletionCallback(to: 321)(true)
        await Task.yield()
        manager.setSleepTimerMode(.minutes15)
        let snapshotCount = nowPlaying.snapshots.count

        monotonicNow += 900
        wallNow.addTimeInterval(900)
        scheduler.fireIgnoringCancellation(at: 0)
        manager.reconcileSleepTimerDeadline()
        scheduler.fireIgnoringCancellation(at: 0)

        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertEqual(manager.currentIndex, 0)
        XCTAssertEqual(manager.currentTime, 321)
        XCTAssertEqual(manager.queue, tracks)
        XCTAssertEqual(manager.completionMode, .stopAtEnd)
        XCTAssertEqual(manager.sleepTimerMode, .off)
        XCTAssertEqual(defaults.string(forKey: "MusicPlayback.lastTrackFileName"), "A.mp3")
        XCTAssertEqual(defaults.double(forKey: "MusicPlayback.lastPositionSeconds"), 321)
        XCTAssertEqual(nowPlaying.snapshots.count, snapshotCount + 1)
        XCTAssertEqual(nowPlaying.snapshots.last?.playbackRate, 0)
    }
}

@MainActor
final class MusicNowPlayingIntegrationTests: XCTestCase {
    private func defaults(_ name: String = #function) throws -> (UserDefaults, String) {
        let suite = "MusicNowPlayingIntegrationTests.\(name).\(UUID().uuidString)"
        return (try XCTUnwrap(UserDefaults(suiteName: suite)), suite)
    }

    func testManagerPersistsShuffleAndRoutesManualTransportThroughPlanAndHistory() throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let tracks = ["A", "B", "C"].map {
            MusicItem(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), duration: 30)
        }
        let manager = MusicPlaybackManager(
            defaults: store,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            shuffleOrdering: { Array($0.reversed()) },
            isShuffleTrackReadable: { _ in true }
        )
        manager.updateQueue(tracks)
        manager.play(tracks[0])

        manager.setShuffleEnabled(true)
        XCTAssertTrue(manager.isShuffleEnabled)
        XCTAssertEqual(manager.currentTrack, tracks[0])
        manager.next(); XCTAssertEqual(manager.currentTrack, tracks[2])
        manager.next(); XCTAssertEqual(manager.currentTrack, tracks[1])
        manager.previous(); XCTAssertEqual(manager.currentTrack, tracks[2])

        manager.setShuffleEnabled(false)
        XCTAssertEqual(manager.currentTrack, tracks[2])
        manager.next(); XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertFalse(manager.isShuffleEnabled)

        manager.setShuffleEnabled(true)
        let restored = MusicPlaybackManager(defaults: store, nowPlayingController: RecordingNowPlayingController())
        XCTAssertTrue(restored.isShuffleEnabled)
    }

    func testRemoteNextAndPreviousUseShufflePlanAndActualHistory() throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let controller = RecordingNowPlayingController()
        let tracks = ["A", "B", "C"].map {
            MusicItem(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), duration: 30)
        }
        let manager = MusicPlaybackManager(
            defaults: store,
            activateAudioSession: {},
            nowPlayingController: controller,
            shuffleOrdering: { Array($0.reversed()) },
            isShuffleTrackReadable: { _ in true }
        )
        manager.updateQueue(tracks); manager.play(tracks[0]); manager.setShuffleEnabled(true)

        XCTAssertEqual(controller.send(.nextTrack), .success)
        XCTAssertEqual(manager.currentTrack, tracks[2])
        XCTAssertEqual(controller.send(.previousTrack), .success)
        XCTAssertEqual(manager.currentTrack, tracks[0])
    }

    func testNaturalCompletionModesTakePrecedenceThenRepeatAllAdvancesShufflePlan() async throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let player = AVPlayer()
        let tracks = ["A", "B", "C"].map {
            MusicItem(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), duration: 30)
        }
        let manager = MusicPlaybackManager(
            player: player,
            defaults: store,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            shuffleOrdering: { Array($0.reversed()) },
            isShuffleTrackReadable: { _ in true }
        )
        manager.updateQueue(tracks); manager.play(tracks[0]); manager.setShuffleEnabled(true)

        manager.setCompletionMode(.repeatOne)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: try XCTUnwrap(player.currentItem))
        await Task.yield(); await Task.yield()
        XCTAssertEqual(manager.currentTrack, tracks[0])

        manager.setCompletionMode(.repeatAll)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: try XCTUnwrap(player.currentItem))
        await Task.yield(); await Task.yield()
        XCTAssertEqual(manager.currentTrack, tracks[2])

        manager.setCompletionMode(.stopAtEnd)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: try XCTUnwrap(player.currentItem))
        await Task.yield(); await Task.yield()
        XCTAssertEqual(manager.currentTrack, tracks[2])
        XCTAssertFalse(manager.isPlaying)
    }

    func testShuffleRepeatAllRestartsCurrentWhenItIsTheOnlyReadableTrack() async throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let player = AVPlayer()
        let controller = RecordingNowPlayingController()
        let tracks = ["A", "B"].map {
            MusicItem(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), duration: 30)
        }
        let manager = MusicPlaybackManager(
            player: player,
            defaults: store,
            activateAudioSession: {},
            nowPlayingController: controller,
            shuffleOrdering: { $0 },
            isShuffleTrackReadable: { $0.lastPathComponent == "A.mp3" }
        )
        manager.updateQueue(tracks); manager.play(tracks[0]); manager.setShuffleEnabled(true)
        let currentItem = try XCTUnwrap(player.currentItem)
        let snapshotCountBeforeCompletion = controller.snapshots.count

        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: currentItem)
        await Task.yield(); await Task.yield()

        XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertTrue(player.currentItem === currentItem)
        XCTAssertTrue(manager.isPlaying)
        XCTAssertEqual(manager.currentTime, 0)
        XCTAssertGreaterThan(controller.snapshots.count, snapshotCountBeforeCompletion)
    }

    func testShuffleRepeatAllStopsCoherentlyWhenCurrentAndTargetsAreUnreadable() async throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let player = AVPlayer()
        let tracks = ["A", "B"].map {
            MusicItem(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), duration: 30)
        }
        let manager = MusicPlaybackManager(
            player: player,
            defaults: store,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            shuffleOrdering: { $0 },
            isShuffleTrackReadable: { _ in false }
        )
        manager.updateQueue(tracks); manager.play(tracks[0]); manager.setShuffleEnabled(true)
        let currentItem = try XCTUnwrap(player.currentItem)

        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: currentItem)
        await Task.yield(); await Task.yield()

        XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertTrue(player.currentItem === currentItem)
        XCTAssertFalse(manager.isPlaying)
    }

    func testShuffleNextFailsClosedWhenNoDifferentReadableTargetExists() throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let player = AVPlayer()
        let tracks = ["A", "B"].map {
            MusicItem(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), duration: 30)
        }
        var readableNames: Set<String> = ["A.mp3"]
        let manager = MusicPlaybackManager(
            player: player,
            defaults: store,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            shuffleOrdering: { $0 },
            isShuffleTrackReadable: { readableNames.contains($0.lastPathComponent) }
        )
        manager.updateQueue(tracks); manager.play(tracks[0]); manager.setShuffleEnabled(true)
        let onlyCurrentItem = try XCTUnwrap(player.currentItem)

        manager.next()
        XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertTrue(player.currentItem === onlyCurrentItem)

        readableNames = []
        manager.setShuffleEnabled(false); manager.setShuffleEnabled(true)
        let allUnreadableItem = try XCTUnwrap(player.currentItem)
        manager.next()
        XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertTrue(player.currentItem === allUnreadableItem)
    }

    func testDirectSelectionRecordsActualShuffleHistoryAgainstFullQueue() throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let tracks = ["A", "B", "C"].map {
            MusicItem(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), duration: 30)
        }
        let manager = MusicPlaybackManager(
            defaults: store,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            shuffleOrdering: { $0 },
            isShuffleTrackReadable: { _ in true }
        )
        manager.updateQueue(tracks); manager.play(tracks[0]); manager.setShuffleEnabled(true)

        manager.play(tracks[1])
        XCTAssertEqual(manager.currentTrack, tracks[1])
        manager.previous()
        XCTAssertEqual(manager.currentTrack, tracks[0])
        manager.next()
        XCTAssertEqual(manager.currentTrack, tracks[1])
        XCTAssertEqual(manager.queue, tracks, "Selection from filtered UI must not replace the full queue")
    }

    func testRepeatedShuffleToggleValuesAreIdempotentAndPreserveCycleHistory() throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let tracks = ["A", "B", "C"].map {
            MusicItem(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), duration: 30)
        }
        var orderingCallCount = 0
        let manager = MusicPlaybackManager(
            defaults: store,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            shuffleOrdering: { orderingCallCount += 1; return $0 },
            isShuffleTrackReadable: { _ in true }
        )
        manager.updateQueue(tracks); manager.play(tracks[0])

        manager.setShuffleEnabled(true)
        manager.next()
        XCTAssertEqual(manager.currentTrack, tracks[1])
        manager.setShuffleEnabled(true)
        XCTAssertEqual(orderingCallCount, 1)
        manager.previous()
        XCTAssertEqual(manager.currentTrack, tracks[0])

        manager.setShuffleEnabled(false)
        manager.setShuffleEnabled(false)
        XCTAssertEqual(orderingCallCount, 1)
        XCTAssertEqual(manager.currentTrack, tracks[0])
    }

    func testCurrentDisappearanceClearsStaleShuffleHistoryBeforeLaterSelection() throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let player = AVPlayer()
        let tracks = ["A", "B", "C"].map {
            MusicItem(url: URL(fileURLWithPath: "/tmp/\($0).mp3"), duration: 30)
        }
        let manager = MusicPlaybackManager(
            player: player,
            defaults: store,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            shuffleOrdering: { $0 },
            isShuffleTrackReadable: { _ in true }
        )
        manager.updateQueue(tracks); manager.play(tracks[0]); manager.setShuffleEnabled(true)
        manager.next(); XCTAssertEqual(manager.currentTrack, tracks[1])

        manager.updateQueue([tracks[0], tracks[2]])
        XCTAssertNil(manager.currentTrack)
        manager.play(tracks[2])
        let selectedItem = try XCTUnwrap(player.currentItem)

        manager.previous()
        XCTAssertEqual(manager.currentTrack, tracks[2])
        XCTAssertTrue(player.currentItem === selectedItem)
        manager.next()
        XCTAssertEqual(manager.currentTrack, tracks[0], "A fresh plan may use remaining items, not stale history")
    }

    func testSameURLCurrentSourceReplacementResetsShuffleHistoryAndPlan() throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShuffleSameURLReplacement-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tracks = try ["A", "B", "C"].map { name -> MusicItem in
            let url = root.appendingPathComponent("\(name).mp3")
            try Data("original-\(name)".utf8).write(to: url)
            return MusicItem(url: url, duration: 30)
        }
        let player = AVPlayer()
        let manager = MusicPlaybackManager(
            player: player,
            defaults: store,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            shuffleOrdering: { $0 },
            isShuffleTrackReadable: { _ in true }
        )
        manager.updateQueue(tracks); manager.play(tracks[0]); manager.setShuffleEnabled(true)
        manager.next(); XCTAssertEqual(manager.currentTrack, tracks[1])

        try Data("replacement-B-with-new-inode".utf8).write(to: tracks[1].url, options: .atomic)
        let refreshed = tracks.enumerated().map { index, track in
            MusicItem(url: track.url, duration: TimeInterval(40 + index))
        }
        manager.updateQueue(refreshed)
        let replacementItem = try XCTUnwrap(player.currentItem)

        manager.previous()
        XCTAssertEqual(manager.currentTrack?.fileName, "B.mp3")
        XCTAssertTrue(player.currentItem === replacementItem)
        manager.next()
        XCTAssertEqual(manager.currentTrack?.fileName, "A.mp3", "Replacement starts a fresh deterministic cycle")
    }

    func testSameNameDifferentURLCurrentReplacementResetsShuffleHistoryAndPlan() throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let tracks = ["A", "B", "C"].map {
            MusicItem(url: URL(fileURLWithPath: "/tmp/original/\($0).mp3"), duration: 30)
        }
        let manager = MusicPlaybackManager(
            defaults: store,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController(),
            shuffleOrdering: { $0 },
            isShuffleTrackReadable: { _ in true }
        )
        manager.updateQueue(tracks); manager.play(tracks[0]); manager.setShuffleEnabled(true)
        manager.next(); XCTAssertEqual(manager.currentTrack, tracks[1])

        let replacement = MusicItem(
            url: URL(fileURLWithPath: "/tmp/replacement/B.mp3"),
            duration: 40
        )
        manager.updateQueue([tracks[0], replacement, tracks[2]])

        manager.previous()
        XCTAssertEqual(manager.currentTrack, replacement)
        manager.next()
        XCTAssertEqual(manager.currentTrack, tracks[0], "Replacement starts a fresh deterministic cycle")
    }

    func testManagerLoadsPublishesAndPersistsCompletionMode() throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        MusicCompletionModeStore(defaults: store).save(.repeatOne)
        let manager = MusicPlaybackManager(defaults: store, nowPlayingController: RecordingNowPlayingController())
        XCTAssertEqual(manager.completionMode, .repeatOne)

        manager.setCompletionMode(.stopAtEnd)
        XCTAssertEqual(manager.completionMode, .stopAtEnd)
        let restored = MusicPlaybackManager(defaults: store, nowPlayingController: RecordingNowPlayingController())
        XCTAssertEqual(restored.completionMode, .stopAtEnd)
    }

    func testStopAtEndNaturalCompletionKeepsCurrentIdentityAndPublishesPaused() async throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let controller = RecordingNowPlayingController(); let player = AVPlayer()
        let manager = MusicPlaybackManager(player: player, defaults: store, activateAudioSession: {}, nowPlayingController: controller)
        let track = MusicItem(url: URL(fileURLWithPath: "/tmp/Only.mp3"), duration: 30)
        manager.updateQueue([track]); manager.setCompletionMode(.stopAtEnd); manager.play(track)

        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: try XCTUnwrap(player.currentItem))
        await Task.yield(); await Task.yield()

        XCTAssertEqual(manager.currentTrack, track)
        XCTAssertEqual(manager.currentIndex, 0)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(controller.snapshots.last?.title, "Only")
        XCTAssertEqual(controller.snapshots.last?.playbackRate, 0)
    }

    func testRepeatOneNaturalCompletionRestartsOneItemFromZeroAndKeepsPlaying() async throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let controller = RecordingNowPlayingController(); let player = AVPlayer()
        let manager = MusicPlaybackManager(player: player, defaults: store, activateAudioSession: {}, nowPlayingController: controller)
        let track = MusicItem(url: URL(fileURLWithPath: "/tmp/Repeat.mp3"), duration: 30)
        manager.updateQueue([track]); manager.setCompletionMode(.repeatOne); manager.play(track)
        manager.seekCompletionCallback(to: 18)(true); await Task.yield(); await Task.yield()

        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: try XCTUnwrap(player.currentItem))
        await Task.yield(); await Task.yield()

        XCTAssertEqual(manager.currentTrack, track)
        XCTAssertEqual(manager.currentTime, 0)
        XCTAssertTrue(manager.isPlaying)
        XCTAssertEqual(controller.snapshots.last?.playbackRate, 1)
    }

    func testNaturalCompletionActivationFailurePausesWithErrorAndPreservesSourceAndPersistentState() async throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        // Artificial EOF isolates the branch and exact position contract; real EOF is tested below.
        let controller = RecordingNowPlayingController(); let player = ManuallyDrivenPeriodicPlayer()
        player.isMuted = true
        var failActivation = false
        var activationCount = 0
        let manager = MusicPlaybackManager(player: player, defaults: store, activateAudioSession: {
            activationCount += 1
            if failActivation { throw TestFailure.activation }
        }, nowPlayingController: controller)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaturalCompletionContract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let readers = NSHashTable<AnyObject>.weakObjects()
        readers.add(player); readers.add(manager)
        addTeardownBlock { @MainActor in
            guard autoreleasepool(invoking: { readers.allObjects.isEmpty }) else {
                print("AVFoundation cleanup pending; preserving completion fixtures at \(root.path)")
                return
            }
            try FileManager.default.removeItem(at: root)
        }
        let urls = [root.appendingPathComponent("A.wav"), root.appendingPathComponent("B.wav")]
        try writeRecoveryWAV(to: urls[0], duration: 30)
        try writeRecoveryWAV(to: urls[1], duration: 40)
        let originalBytes = try urls.map { try Data(contentsOf: $0) }
        let tracks = [MusicItem(url: urls[0], duration: 30), MusicItem(url: urls[1], duration: 40)]
        let playlistID = UUID()
        manager.playFromPlaylist(tracks[0], playlistID: playlistID, items: tracks)
        // Freeze physical transport while keeping the manager's pre-completion playing intent.
        player.pause()
        let item = try XCTUnwrap(player.currentItem)
        readers.add(item); readers.add(item.asset)
        defer {
            manager.pause()
            player.replaceCurrentItem(with: nil)
            item.cancelPendingSeeks(); item.asset.cancelLoading()
        }
        let ready = expectation(description: "Contract WAV is ready before artificial EOF")
        let readyObservation = item.publisher(for: \.status, options: [.initial, .new])
            .filter { $0 == .readyToPlay }.prefix(1).sink { _ in ready.fulfill() }
        defer { readyObservation.cancel() }
        guard await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed else {
            XCTFail("Contract WAV readiness timed out")
            return
        }
        let seekGeneration = manager.seekCompletionGeneration
        let positioned = expectation(description: "Real seek and manager position update complete")
        let seekObservation = manager.seekCompletionPublisher
            .filter { $0 > seekGeneration }.prefix(1).sink { _ in positioned.fulfill() }
        defer { seekObservation.cancel() }
        manager.seek(to: 12)
        guard await XCTWaiter.fulfillment(of: [positioned], timeout: 5) == .completed else {
            XCTFail("Contract seek timed out")
            return
        }
        XCTAssertEqual(manager.currentTime, 12)
        XCTAssertEqual(item.currentTime().seconds, 12, accuracy: 0.05)
        XCTAssertTrue(manager.isPlaying)
        XCTAssertNil(manager.playbackErrorMessage)
        let snapshot = try XCTUnwrap(controller.snapshots.last)
        let snapshotCount = controller.snapshots.count
        let loadGeneration = manager.trackLoadGeneration
        let failureGeneration = manager.itemFailureNotificationGeneration
        let persistedName = store.string(forKey: "MusicPlayback.lastTrackFileName")
        let persistedTime = store.double(forKey: "MusicPlayback.lastPositionSeconds")
        failActivation = true

        let transitionGeneration = manager.completionTransitionGeneration
        let handled = expectation(description: "Artificial EOF production handler completes")
        let completionObservation = manager.$completionTransitionGeneration
            .filter { $0 > transitionGeneration }.prefix(1).sink { _ in handled.fulfill() }
        defer { completionObservation.cancel() }
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        guard await XCTWaiter.fulfillment(of: [handled], timeout: 2) == .completed else {
            XCTFail("Artificial EOF handler timed out")
            return
        }

        XCTAssertEqual(manager.currentTrack, tracks[0]); XCTAssertEqual(manager.currentIndex, 0)
        XCTAssertEqual(manager.currentTime, 12); XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(player.rate, 0)
        XCTAssertFalse(manager.playbackErrorMessage?.isEmpty ?? true)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual((item.asset as? AVURLAsset)?.url, urls[0])
        XCTAssertEqual(item.status, .readyToPlay)
        XCTAssertNil(item.error)
        XCTAssertEqual(manager.trackLoadGeneration, loadGeneration)
        XCTAssertEqual(manager.itemFailureNotificationGeneration, failureGeneration)
        XCTAssertEqual(manager.queue, tracks)
        XCTAssertEqual(manager.queueScope, .playlist(playlistID))
        XCTAssertEqual(MusicQueueScopeStore(defaults: store).loadPlaylistID(), playlistID)
        XCTAssertEqual(activationCount, 2)
        XCTAssertEqual(manager.completionTransitionGeneration, transitionGeneration + 1)
        XCTAssertEqual(store.string(forKey: "MusicPlayback.lastTrackFileName"), persistedName)
        XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"), persistedTime)
        XCTAssertEqual(controller.snapshots.count, snapshotCount + 1)
        XCTAssertEqual(controller.snapshots.last, NowPlayingSnapshot(
            title: snapshot.title, duration: snapshot.duration, elapsedTime: snapshot.elapsedTime,
            playbackRate: 0, artworkData: snapshot.artworkData, artist: snapshot.artist, album: snapshot.album
        ))
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, originalBytes)
    }

    func testInjectedEOFActivationFailureThenVideoClaimRejectsCapturedSameGenerationSeek() async throws {
        try await assertInjectedEOFActivationFailureThenVideoClaimRejectsCapturedCallback(isSeek: true)
    }

    func testInjectedEOFActivationFailureThenVideoClaimRejectsCapturedSameGenerationPeriodic() async throws {
        try await assertInjectedEOFActivationFailureThenVideoClaimRejectsCapturedCallback(isSeek: false)
    }

    private func assertInjectedEOFActivationFailureThenVideoClaimRejectsCapturedCallback(isSeek: Bool) async throws {
        // Injected EOF on valid WAV isolates delayed callbacks; real transport EOF
        // is independently covered by the real-EOF tests below.
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InjectedEOFDelayedCallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let readers = NSHashTable<AnyObject>.weakObjects()
        addTeardownBlock { @MainActor in
            guard autoreleasepool(invoking: { readers.allObjects.isEmpty }) else {
                print("AVFoundation cleanup pending; preserving injected EOF fixtures at \(root.path)")
                return
            }
            try FileManager.default.removeItem(at: root)
        }
        let urls = [root.appendingPathComponent("A.wav"), root.appendingPathComponent("B.wav")]
        for url in urls { try writeRecoveryWAV(to: url, duration: 90) }
        let originalBytes = try urls.map { try Data(contentsOf: $0) }
        let tracks = urls.map { MusicItem(url: $0, duration: 90) }
        let session = MPNowPlayingSession(players: [AVPlayer()])
        let center = session.nowPlayingInfoCenter
        defer { center.nowPlayingInfo = nil; center.playbackState = .stopped }
        var profiles: [NowPlayingCommandProfile?] = []
        var dispatcher: (@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)?
        let registry = MusicNowPlayingRegistry(commandProfileSetter: { profiles.append($0) })
        let musicController = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { handler in dispatcher = handler; return [] },
            sharedRegistryForTesting: registry
        )
        let videoController = MediaPlayerMusicNowPlayingController(
            testingCenter: center, registerTargets: { _ in [] }, sharedRegistryForTesting: registry
        )
        let ownership = PlaybackOwnershipCoordinator()
        let player = ManuallyDrivenPeriodicPlayer()
        player.isMuted = true
        var failActivation = false
        var activationCount = 0
        let manager = MusicPlaybackManager(
            player: player, defaults: store, ownership: ownership,
            activateAudioSession: {
                activationCount += 1
                if failActivation { throw TestFailure.activation }
            }, nowPlayingController: musicController
        )
        readers.add(player); readers.add(manager)
        let playlistID = UUID()
        manager.playFromPlaylist(tracks[0], playlistID: playlistID, items: tracks)
        player.pause() // Freeze transport while preserving pre-EOF manager intent.
        let item = try XCTUnwrap(player.currentItem)
        readers.add(item); readers.add(item.asset)
        defer {
            player.pause()
            item.cancelPendingSeeks(); item.asset.cancelLoading()
            player.replaceCurrentItem(with: nil)
        }
        let ready = expectation(description: "Valid WAV ready before injected EOF")
        let readyObservation = item.publisher(for: \.status, options: [.initial, .new])
            .filter { $0 == .readyToPlay }.prefix(1).sink { _ in ready.fulfill() }
        defer { readyObservation.cancel() }
        guard await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed else {
            XCTFail("Injected EOF prerequisite: valid WAV readiness timed out")
            return
        }
        let initialSeekGeneration = manager.seekCompletionGeneration
        let positioned = expectation(description: "Initial real seek completes before callback capture")
        let positionObservation = manager.seekCompletionPublisher
            .filter { $0 > initialSeekGeneration }.prefix(1).sink { _ in positioned.fulfill() }
        defer { positionObservation.cancel() }
        manager.seek(to: 12)
        guard await XCTWaiter.fulfillment(of: [positioned], timeout: 5) == .completed else {
            XCTFail("Injected EOF prerequisite: initial seek timed out")
            return
        }
        XCTAssertEqual(manager.currentTime, 12)
        XCTAssertEqual(item.currentTime().seconds, 12, accuracy: 0.05)
        XCTAssertTrue(manager.isPlaying)
        XCTAssertNil(manager.playbackErrorMessage)
        let oldSeek = manager.seekCompletionCallback(to: 61)
        let oldPeriodic = try XCTUnwrap(player.periodicCallback)
        let loadGeneration = manager.trackLoadGeneration
        let failureGeneration = manager.itemFailureNotificationGeneration
        let transitionGeneration = manager.completionTransitionGeneration
        let handled = expectation(description: "Injected EOF activation-failure handler returns")
        let completionObservation = manager.$completionTransitionGeneration
            .filter { $0 > transitionGeneration }.prefix(1).sink { _ in handled.fulfill() }
        defer { completionObservation.cancel() }
        failActivation = true
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        guard await XCTWaiter.fulfillment(of: [handled], timeout: 2) == .completed else {
            XCTFail("Injected EOF prerequisite: completion handler timed out")
            return
        }
        XCTAssertEqual(manager.completionTransitionGeneration, transitionGeneration + 1)
        XCTAssertEqual(activationCount, 2)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertFalse(manager.playbackErrorMessage?.isEmpty ?? true)
        XCTAssertEqual(manager.currentTime, 12)
        XCTAssertEqual(manager.trackLoadGeneration, loadGeneration)
        XCTAssertEqual(manager.itemFailureNotificationGeneration, failureGeneration,
                       "Injected natural completion must not use the decode-failure path")

        let video = VideoStopSpyForNowPlaying()
        let registration = ownership.registerVideoStop(for: video) { $0.stopCount += 1 }
        defer { withExtendedLifetime(registration) {} }
        let videoIntent = ownership.videoPlaybackRequested { manager.pause() }
        var videoCommandCount = 0
        videoController.registerVideoRemoteCommands { _ in
            videoCommandCount += 1
            return .success
        }
        videoController.publish(
            NowPlayingSnapshot(title: "Active Video", duration: 60, elapsedTime: 9, playbackRate: 1)
        )
        let dispatch = try XCTUnwrap(dispatcher)
        XCTAssertEqual(dispatch(.pause), .success)
        XCTAssertEqual(videoCommandCount, 1)
        XCTAssertEqual(profiles.last, .video)
        XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent))
        let videoSnapshot = try XCTUnwrap(center.nowPlayingInfo) as NSDictionary
        let videoState = center.playbackState
        let profilesBeforeCallback = profiles
        let stopsBeforeCallback = video.stopCount
        let persisted = try XCTUnwrap(store.persistentDomain(forName: suite)) as NSDictionary
        let retainedPosition = manager.currentTime
        let retainedDuration = manager.duration
        let retainedError = manager.playbackErrorMessage
        let retainedItemTime = item.currentTime()
        let scopeNeedsRepair = manager.queueScopePersistenceNeedsRepair

        if isSeek {
            let generation = manager.seekCompletionGeneration
            let processed = expectation(description: "Captured same-generation seek returns after video claim")
            let observation = manager.seekCompletionPublisher
                .filter { $0 > generation }.prefix(1).sink { _ in processed.fulfill() }
            oldSeek(true)
            let result = await XCTWaiter.fulfillment(of: [processed], timeout: 2)
            observation.cancel()
            guard result == .completed else {
                XCTFail("Captured seek did not complete within 2 s")
                return
            }
            XCTAssertEqual(manager.seekCompletionGeneration, generation + 1)
        } else {
            // Exercise the real five-second persistence branch as well as publication.
            // No live periodic observer can deliver a pulse or reset its save clock.
            let saveWindow = expectation(description: "Periodic persistence throttle expires")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) { saveWindow.fulfill() }
            guard await XCTWaiter.fulfillment(of: [saveWindow], timeout: 7) == .completed else {
                XCTFail("Periodic persistence window did not open")
                return
            }
            let generation = manager.periodicCompletionGeneration
            let processed = expectation(description: "Captured same-generation periodic returns after video claim")
            let observation = manager.periodicCompletionPublisher
                .filter { $0 > generation }.prefix(1).sink { _ in processed.fulfill() }
            oldPeriodic(CMTime(seconds: 67, preferredTimescale: 600))
            let result = await XCTWaiter.fulfillment(of: [processed], timeout: 2)
            observation.cancel()
            guard result == .completed else {
                XCTFail("Captured periodic callback did not complete within 2 s")
                return
            }
            XCTAssertEqual(manager.periodicCompletionGeneration, generation + 1)
        }

        XCTAssertEqual(manager.currentTime, retainedPosition, "Delayed callback must preserve exhausted music position")
        XCTAssertEqual(manager.duration, retainedDuration)
        XCTAssertEqual(manager.playbackErrorMessage, retainedError)
        XCTAssertEqual(try XCTUnwrap(store.persistentDomain(forName: suite)) as NSDictionary, persisted)
        XCTAssertEqual(try XCTUnwrap(center.nowPlayingInfo) as NSDictionary, videoSnapshot,
                       "Parent RED: delayed same-generation callback must not publish music over video")
        XCTAssertEqual(center.playbackState, videoState)
        XCTAssertEqual(profiles, profilesBeforeCallback)
        XCTAssertEqual(profiles.last, .video)
        XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent))
        XCTAssertEqual(video.stopCount, stopsBeforeCallback)
        XCTAssertEqual(dispatch(.pause), .success)
        XCTAssertEqual(videoCommandCount, 2, "Actual shared registry dispatcher must still route to video")
        XCTAssertEqual(video.stopCount, stopsBeforeCallback)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(player.rate, 0)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(item.status, .readyToPlay)
        XCTAssertNil(item.error)
        XCTAssertEqual(CMTimeCompare(item.currentTime(), retainedItemTime), 0)
        XCTAssertEqual(manager.trackLoadGeneration, loadGeneration)
        XCTAssertEqual(manager.itemFailureNotificationGeneration, failureGeneration)
        XCTAssertEqual(manager.completionTransitionGeneration, transitionGeneration + 1)
        XCTAssertEqual(activationCount, 2)
        XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertEqual(manager.currentIndex, 0)
        XCTAssertEqual(manager.queue, tracks)
        XCTAssertEqual(manager.queueScope, .playlist(playlistID))
        XCTAssertEqual(manager.queueScopePersistenceNeedsRepair, scopeNeedsRepair)
        XCTAssertEqual(MusicQueueScopeStore(defaults: store).loadPlaylistID(), playlistID)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, originalBytes)

        // A later explicit selection accepts its new callbacks while the captured
        // ended-item callbacks remain stale, even after the failure state resets.
        failActivation = false
        manager.play(tracks[1])
        player.pause()
        let replacement = try XCTUnwrap(player.currentItem)
        readers.add(replacement); readers.add(replacement.asset)
        defer { replacement.cancelPendingSeeks(); replacement.asset.cancelLoading() }
        XCTAssertFalse(replacement === item)
        XCTAssertEqual(manager.trackLoadGeneration, loadGeneration + 1)
        XCTAssertNil(manager.playbackErrorMessage)
        let callbackGeneration = isSeek ? manager.seekCompletionGeneration : manager.periodicCompletionGeneration
        let callbackPublisher = isSeek ? manager.seekCompletionPublisher : manager.periodicCompletionPublisher
        let replacementProcessed = expectation(description: "Replacement callback returns")
        let replacementObservation = callbackPublisher
            .filter { $0 >= callbackGeneration + 1 }.prefix(1).sink { _ in replacementProcessed.fulfill() }
        defer { replacementObservation.cancel() }
        let freshProcessed = expectation(description: "Replacement and stale callbacks return")
        let callbackObservation = callbackPublisher
            .filter { $0 >= callbackGeneration + 2 }.prefix(1).sink { _ in freshProcessed.fulfill() }
        defer { callbackObservation.cancel() }
        if isSeek {
            manager.seekCompletionCallback(to: 23)(true)
        } else {
            try XCTUnwrap(player.periodicCallback)(CMTime(seconds: 23, preferredTimescale: 600))
        }
        guard await XCTWaiter.fulfillment(of: [replacementProcessed], timeout: 2) == .completed else {
            XCTFail("Replacement callback did not complete")
            return
        }
        XCTAssertEqual(manager.currentTime, 23)
        if isSeek {
            oldSeek(true)
        } else {
            oldPeriodic(CMTime(seconds: 67, preferredTimescale: 600))
        }
        guard await XCTWaiter.fulfillment(of: [freshProcessed], timeout: 2) == .completed else {
            XCTFail("Replacement callback and matching stale callback did not complete")
            return
        }
        XCTAssertEqual(manager.currentTime, 23)
        XCTAssertEqual(manager.currentTrack, tracks[1])
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 23)
        if isSeek {
            XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"), 23)
        }
    }

    func testRealEOFActivationFailureThenVideoClaimExplicitSeekPreservesRegistryOwnership() async throws {
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EOFSeekOwnership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let readers = NSHashTable<AnyObject>.weakObjects()
        addTeardownBlock { @MainActor in
            guard autoreleasepool(invoking: { readers.allObjects.isEmpty }) else {
                print("AVFoundation cleanup pending; preserving fixtures at \(root.path)")
                return
            }
            try FileManager.default.removeItem(at: root)
        }

        let url = root.appendingPathComponent("short.wav")
        try writeRecoveryWAV(to: url, duration: 2)
        let originalBytes = try Data(contentsOf: url)
        let track = MusicItem(url: url, duration: 2)

        // Only periodic delivery is isolated. Transport, seek and EOF stay real.
        let player = ManuallyDrivenPeriodicPlayer()
        player.isMuted = true
        let session = MPNowPlayingSession(players: [AVPlayer()])
        let center = session.nowPlayingInfoCenter
        defer {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            withExtendedLifetime(session) {}
        }

        var profiles: [NowPlayingCommandProfile?] = []
        var dispatcher: (@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)?
        let registry = MusicNowPlayingRegistry(commandProfileSetter: { profiles.append($0) })
        let musicController = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { handler in
                dispatcher = handler
                return []
            },
            sharedRegistryForTesting: registry
        )
        let videoController = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { _ in [] },
            sharedRegistryForTesting: registry
        )
        let ownership = PlaybackOwnershipCoordinator()
        var activations = 0
        let manager = MusicPlaybackManager(
            player: player,
            defaults: store,
            ownership: ownership,
            activateAudioSession: {
                activations += 1
                if activations >= 2 { throw TestFailure.activation }
            },
            nowPlayingController: musicController
        )
        readers.add(player)
        readers.add(manager)
        var items: [AVPlayerItem] = []
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
            items.forEach {
                $0.cancelPendingSeeks()
                $0.asset.cancelLoading()
            }
        }

        manager.setCompletionMode(.repeatOne)
        manager.playFromPlaylist(track, playlistID: UUID(), items: [track])
        let exhaustedItem = try XCTUnwrap(player.currentItem)
        items.append(exhaustedItem)
        readers.add(exhaustedItem)
        readers.add(exhaustedItem.asset)

        let transition = manager.completionTransitionGeneration
        let failure = manager.itemFailureNotificationGeneration
        let started = expectation(description: "Real WAV starts playing")
        let ended = expectation(description: "AVFoundation emits natural EOF")
        let handled = expectation(description: "Natural EOF activation-failure handler returns")
        let startObservation = player.publisher(
            for: \.timeControlStatus, options: [.initial, .new]
        )
            .filter { $0 == .playing }.prefix(1)
            .sink { _ in started.fulfill() }
        let endObservation = NotificationCenter.default.publisher(
            for: .AVPlayerItemDidPlayToEndTime, object: exhaustedItem
        )
            .prefix(1).sink { _ in ended.fulfill() }
        let handlerObservation = manager.$completionTransitionGeneration
            .filter { $0 > transition }.prefix(1)
            .sink { _ in handled.fulfill() }
        defer {
            startObservation.cancel()
            endObservation.cancel()
            handlerObservation.cancel()
        }

        guard await XCTWaiter.fulfillment(
            of: [started, ended, handled], timeout: 10
        ) == .completed else {
            XCTFail("Prerequisite failed: real EOF/handler not established; not ownership RED")
            return
        }
        guard activations == 2,
              manager.completionTransitionGeneration == transition + 1,
              manager.itemFailureNotificationGeneration == failure,
              exhaustedItem.status == .readyToPlay,
              exhaustedItem.error == nil,
              player.error == nil,
              player.currentItem === exhaustedItem,
              abs(exhaustedItem.currentTime().seconds - 2) < 0.15,
              !manager.isPlaying,
              player.rate == 0,
              !(manager.playbackErrorMessage?.isEmpty ?? true) else {
            XCTFail("Prerequisite failed: expected natural EOF activation failure was not established")
            return
        }

        let video = VideoStopSpyForNowPlaying()
        let registration = ownership.registerVideoStop(for: video) { $0.stopCount += 1 }
        defer {
            withExtendedLifetime(registration) {}
            withExtendedLifetime(videoController) {}
        }
        let videoIntent = ownership.videoPlaybackRequested { manager.pause() }
        var videoCommands: [MusicRemoteCommand] = []
        videoController.registerVideoRemoteCommands { command in
            guard command == .skipForward else { return .commandFailed }
            videoCommands.append(command)
            return .success
        }
        videoController.publish(
            NowPlayingSnapshot(
                title: "Active Video", duration: 60, elapsedTime: 9, playbackRate: 1
            )
        )

        let dispatch = try XCTUnwrap(dispatcher)
        guard ownership.videoPlaybackIsAllowed(videoIntent),
              profiles.last == .video,
              center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Active Video",
              center.playbackState == .playing,
              dispatch(.skipForward) == .success,
              videoCommands == [.skipForward] else {
            XCTFail("Prerequisite failed: video did not acquire the actual shared registry")
            return
        }
        videoCommands.removeAll()
        let videoInfo = try XCTUnwrap(center.nowPlayingInfo) as NSDictionary
        let videoState = center.playbackState
        let videoProfiles = profiles
        let videoStops = video.stopCount

        // Subscribe before the real public seek. Never invoke a captured callback.
        let seekGeneration = manager.seekCompletionGeneration
        let seekCompletionObserved = CurrentValueSubject<Bool, Never>(false)
        let seekObservation = manager.seekCompletionPublisher
            .filter { $0 > seekGeneration }.prefix(1)
            .sink { _ in seekCompletionObserved.send(true) }
        defer { seekObservation.cancel() }

        manager.seek(to: 0.25)

        if player.currentItem === exhaustedItem {
            // Baseline path: AVPlayer completion -> manager MainActor handler -> defer.
            // Replay only the real completion signal if it arrived before this wait.
            // The replacement path never creates an XCTest expectation.
            let seekProcessed = expectation(description: "Real seek completion actor handler returns")
            let completionObservation = seekCompletionObserved
                .filter { $0 }.prefix(1)
                .sink { _ in seekProcessed.fulfill() }
            defer { completionObservation.cancel() }
            guard await XCTWaiter.fulfillment(
                of: [seekProcessed], timeout: 5
            ) == .completed else {
                XCTFail("Real seek completion barrier timed out; not ownership RED")
                return
            }
        } else if let replacement = player.currentItem {
            // Candidate installs and publishes synchronously before seek returns.
            // Its installItem seek has no manager completion; do not invent a barrier.
            items.append(replacement)
            readers.add(replacement)
            readers.add(replacement.asset)
        } else {
            XCTFail("Seek unexpectedly detached the current item")
            return
        }

        XCTAssertEqual(center.nowPlayingInfo.map { $0 as NSDictionary }, videoInfo)
        XCTAssertEqual(center.playbackState, videoState)
        XCTAssertEqual(profiles, videoProfiles)
        XCTAssertEqual(profiles.last, .video)
        XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent))
        XCTAssertEqual(video.stopCount, videoStops)
        XCTAssertEqual(activations, 2)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(player.rate, 0)

        // Goes through registry.dispatch, not directly to the video closure.
        // Music rejects skipForward without starting playback or publishing.
        XCTAssertEqual(dispatch(.skipForward), .success)
        XCTAssertEqual(videoCommands, [.skipForward])

        // Behavioral owner probe: a non-owner music clear must leave video intact.
        musicController.clear()
        XCTAssertEqual(center.nowPlayingInfo.map { $0 as NSDictionary }, videoInfo)
        XCTAssertEqual(center.playbackState, videoState)
        XCTAssertEqual(profiles, videoProfiles)
        XCTAssertEqual(dispatch(.skipForward), .success)
        XCTAssertEqual(videoCommands, [.skipForward, .skipForward])
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    }

    func testHealthyEOFStopAtEndThenVideoClaimPublicSeekPreservesRegistryAndTransport() async throws {
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HealthyEOFSeekOwnership-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let readers = NSHashTable<AnyObject>.weakObjects()
        addTeardownBlock { @MainActor in
            guard autoreleasepool(invoking: { readers.allObjects.isEmpty }) else {
                print("AVFoundation cleanup pending; preserving fixtures at \(root.path)")
                return
            }
            try FileManager.default.removeItem(at: root)
        }

        let url = root.appendingPathComponent("short.wav")
        try writeRecoveryWAV(to: url, duration: 2)
        let originalBytes = try Data(contentsOf: url)
        let track = MusicItem(url: url, duration: 2)

        // Only periodic delivery is isolated. Transport, seek and EOF stay real.
        let player = ManuallyDrivenPeriodicPlayer()
        player.isMuted = true
        let session = MPNowPlayingSession(players: [AVPlayer()])
        let center = session.nowPlayingInfoCenter
        defer {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            withExtendedLifetime(session) {}
        }

        var profiles: [NowPlayingCommandProfile?] = []
        var dispatcher: (@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)?
        let registry = MusicNowPlayingRegistry(commandProfileSetter: { profiles.append($0) })
        let musicController = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { handler in
                dispatcher = handler
                return []
            },
            sharedRegistryForTesting: registry
        )
        let videoController = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { _ in [] },
            sharedRegistryForTesting: registry
        )
        let ownership = PlaybackOwnershipCoordinator()
        var activations = 0
        let manager = MusicPlaybackManager(
            player: player,
            defaults: store,
            ownership: ownership,
            activateAudioSession: {
                activations += 1
            },
            nowPlayingController: musicController
        )
        readers.add(player)
        readers.add(manager)
        var items: [AVPlayerItem] = []
        defer {
            player.pause()
            player.replaceCurrentItem(with: nil)
            items.forEach {
                $0.cancelPendingSeeks()
                $0.asset.cancelLoading()
            }
        }

        manager.setCompletionMode(.stopAtEnd)
        manager.playFromPlaylist(track, playlistID: UUID(), items: [track])
        let exhaustedItem = try XCTUnwrap(player.currentItem)
        items.append(exhaustedItem)
        readers.add(exhaustedItem)
        readers.add(exhaustedItem.asset)

        let transition = manager.completionTransitionGeneration
        let failure = manager.itemFailureNotificationGeneration
        let started = expectation(description: "Real WAV starts playing")
        let ended = expectation(description: "AVFoundation emits natural EOF")
        let handled = expectation(description: "Healthy EOF stop-at-end handler returns")
        let startObservation = player.publisher(
            for: \.timeControlStatus, options: [.initial, .new]
        )
            .filter { $0 == .playing }.prefix(1)
            .sink { _ in started.fulfill() }
        let endObservation = NotificationCenter.default.publisher(
            for: .AVPlayerItemDidPlayToEndTime, object: exhaustedItem
        )
            .prefix(1).sink { _ in ended.fulfill() }
        let handlerObservation = manager.$completionTransitionGeneration
            .filter { $0 > transition }.prefix(1)
            .sink { _ in handled.fulfill() }
        defer {
            startObservation.cancel()
            endObservation.cancel()
            handlerObservation.cancel()
        }

        guard await XCTWaiter.fulfillment(
            of: [started, ended, handled], timeout: 10
        ) == .completed else {
            XCTFail("Prerequisite failed: real EOF/handler not established; not ownership RED")
            return
        }
        guard activations == 1,
              manager.completionMode == .stopAtEnd,
              manager.currentTrack == track,
              manager.completionTransitionGeneration == transition + 1,
              manager.itemFailureNotificationGeneration == failure,
              exhaustedItem.status == .readyToPlay,
              exhaustedItem.error == nil,
              player.error == nil,
              player.currentItem === exhaustedItem,
              abs(exhaustedItem.duration.seconds - 2) < 0.1,
              abs(exhaustedItem.currentTime().seconds - 2) < 0.1,
              !manager.isPlaying,
              player.rate == 0,
              manager.playbackErrorMessage == nil else {
            XCTFail("Prerequisite failed: healthy exhausted stopAtEnd state was not established; not ownership RED")
            return
        }

        let video = VideoStopSpyForNowPlaying()
        let registration = ownership.registerVideoStop(for: video) { $0.stopCount += 1 }
        defer {
            withExtendedLifetime(registration) {}
            withExtendedLifetime(videoController) {}
        }
        let videoIntent = ownership.videoPlaybackRequested { manager.pause() }
        var videoCommands: [MusicRemoteCommand] = []
        videoController.registerVideoRemoteCommands { command in
            guard command == .skipForward else { return .commandFailed }
            videoCommands.append(command)
            return .success
        }
        videoController.publish(
            NowPlayingSnapshot(
                title: "Active Video", duration: 60, elapsedTime: 9, playbackRate: 1
            )
        )

        let dispatch = try XCTUnwrap(dispatcher)
        guard ownership.videoPlaybackIsAllowed(videoIntent),
              profiles.last == .video,
              center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Active Video",
              center.playbackState == .playing,
              dispatch(.skipForward) == .success,
              videoCommands == [.skipForward] else {
            XCTFail("Prerequisite failed: video did not acquire the actual shared registry")
            return
        }
        videoCommands.removeAll()
        let videoInfo = try XCTUnwrap(center.nowPlayingInfo) as NSDictionary
        let videoState = center.playbackState
        let videoProfiles = profiles
        let videoStops = video.stopCount

        let activationsBeforeSeek = activations
        func assertVideoPreserved(_ phase: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(center.nowPlayingInfo.map { $0 as NSDictionary }, videoInfo, phase, file: file, line: line)
            XCTAssertEqual(center.playbackState, videoState, phase, file: file, line: line)
            XCTAssertEqual(profiles, videoProfiles, phase, file: file, line: line)
            XCTAssertEqual(profiles.last, .video, phase, file: file, line: line)
            XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent), phase, file: file, line: line)
            XCTAssertEqual(video.stopCount, videoStops, phase, file: file, line: line)
            XCTAssertEqual(activations, activationsBeforeSeek, phase, file: file, line: line)
            XCTAssertFalse(manager.isPlaying, phase, file: file, line: line)
            XCTAssertEqual(player.rate, 0, phase, file: file, line: line)
            // Probe the registered dispatcher, never call the video closure directly.
            videoCommands.removeAll()
            XCTAssertEqual(dispatch(.skipForward), .success, phase, file: file, line: line)
            XCTAssertEqual(videoCommands, [.skipForward], phase, file: file, line: line)
        }

        // Subscribe before the first public seek, including the EOF replacement path.
        let seekGeneration = manager.seekCompletionGeneration
        let seekCompletionObserved = CurrentValueSubject<Bool, Never>(false)
        let seekObservation = manager.seekCompletionPublisher
            .filter { $0 > seekGeneration }.prefix(1)
            .sink { _ in seekCompletionObserved.send(true) }
        defer { seekObservation.cancel() }

        manager.seek(to: 0.25)
        // Primary RED: no suspension may hide installItem's synchronous publication.
        assertVideoPreserved("Immediately after public healthy EOF seek")

        let seekItem = try XCTUnwrap(player.currentItem)
        if seekItem !== exhaustedItem {
            items.append(seekItem)
            readers.add(seekItem)
            readers.add(seekItem.asset)
        }
        let firstProcessed = expectation(description: "First public EOF seek's real completion handler returns")
        let firstObservation = seekCompletionObserved.filter { $0 }.prefix(1)
            .sink { _ in firstProcessed.fulfill() }
        defer { firstObservation.cancel() }
        guard await XCTWaiter.fulfillment(of: [firstProcessed], timeout: 5) == .completed else {
            XCTFail("Real seek completion barrier timed out; not ownership RED")
            return
        }
        XCTAssertEqual(manager.seekCompletionGeneration, seekGeneration + 1)
        XCTAssertEqual(manager.currentTime, 0.25, accuracy: 0.001)
        XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"), 0.25, accuracy: 0.001)
        XCTAssertEqual(seekItem.currentTime().seconds, 0.25, accuracy: 1.0 / 600.0)
        assertVideoPreserved("After public seek completion handler")
        // Drain the first request before subscribing for the ordinary seek so a
        // cancelled first callback cannot masquerade as the second completion.

        let ordinaryItem = try XCTUnwrap(player.currentItem)
        let ordinaryLoad = manager.trackLoadGeneration
        let ordinaryGeneration = manager.seekCompletionGeneration
        let ordinaryDone = expectation(description: "Second public seek processed")
        let ordinaryObservation = manager.seekCompletionPublisher
            .filter { $0 > ordinaryGeneration }.prefix(1)
            .sink { _ in ordinaryDone.fulfill() }
        defer { ordinaryObservation.cancel() }

        manager.seek(to: 0.5)
        assertVideoPreserved("Immediately after second public seek")
        guard await XCTWaiter.fulfillment(of: [ordinaryDone], timeout: 5) == .completed else {
            XCTFail("Second public seek completion timed out")
            return
        }

        XCTAssertEqual(manager.seekCompletionGeneration, ordinaryGeneration + 1)
        XCTAssertTrue(player.currentItem === ordinaryItem)
        XCTAssertEqual(manager.trackLoadGeneration, ordinaryLoad)
        XCTAssertEqual(manager.currentTime, 0.5, accuracy: 0.001)
        XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"),
                       0.5, accuracy: 0.001)
        assertVideoPreserved("After second public seek completion")

        let saveWindow = expectation(description: "Open periodic persistence window after second public seek")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) { saveWindow.fulfill() }
        guard await XCTWaiter.fulfillment(of: [saveWindow], timeout: 7) == .completed else {
            XCTFail("Periodic persistence window did not open")
            return
        }

        // Deliver only the currently installed production callback. The existing
        // manual clock excludes unrelated pulses from satisfying its completion barrier.
        let periodic = try XCTUnwrap(player.periodicCallback)
        let periodicGeneration = manager.periodicCompletionGeneration
        let processed = expectation(description: "Post-seek current periodic handler returns")
        let observation = manager.periodicCompletionPublisher
            .filter { $0 > periodicGeneration }.prefix(1)
            .sink { _ in processed.fulfill() }
        defer { observation.cancel() }
        periodic(CMTime(seconds: 0.75, preferredTimescale: 600))
        guard await XCTWaiter.fulfillment(of: [processed], timeout: 2) == .completed else {
            XCTFail("Current periodic handler completion barrier timed out")
            return
        }
        XCTAssertEqual(manager.periodicCompletionGeneration, periodicGeneration + 1)
        XCTAssertEqual(manager.currentTime, 0.75, accuracy: 0.001)
        XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"),
                       0.75, accuracy: 0.001)
        assertVideoPreserved("After current periodic handler completion")

        // Behavioral owner probe: clearing non-owner music must leave VIDEO intact.
        musicController.clear()
        assertVideoPreserved("After non-owner music clear")
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    }

    func testRealEOFNextActivationFailurePausesPreservesSourceAndAllowsExplicitRecovery() async throws {
        try await assertRealEOFActivationFailure(mode: .repeatAll)
    }

    func testRealEOFRepeatActivationFailurePausesPreservesSourceAndAllowsExplicitRecovery() async throws {
        try await assertRealEOFActivationFailure(mode: .repeatOne)
    }

    func testRealEOFNextActivationFailureRemotePlayRestartsPreservedTrackFromZero() async throws {
        try await assertRealEOFSameTrackRecovery(mode: .repeatAll, remote: true)
    }

    func testRealEOFRepeatActivationFailureDirectPlayRestartsPreservedTrackFromZero() async throws {
        try await assertRealEOFSameTrackRecovery(mode: .repeatOne, remote: false)
    }

    func testRealEOFRetainedNilIndexRepeatActivationFailureRemotePlayRestartsPreservedTrackFromZero() async throws {
        try await assertRealEOFSameTrackRecovery(mode: .repeatOne, remote: true, retained: true)
    }

    func testRealEOFActivationFailureSameTrackRecoveryAcceptsFreshTimelineRejectsCapturedOldSeekAndPeriodic() async throws {
        try await assertRealEOFSameTrackRecovery(mode: .repeatAll, remote: true, verifyStaleDelivery: true)
    }

    func testRealEOFStopAtEndThenRepeatAllExplicitPlayRestartsSameTrack() async throws {
        try await assertRealEOFStopAtEndReplay()
    }

    // Neighboring contracts added with the fix; not independently RED yet.
    func testRealEOFRetainedStopAtEndExplicitPlayRestartsSameTrack() async throws {
        try await assertRealEOFStopAtEndReplay(retained: true)
    }

    func testRealEOFStopAtEndExplicitSeekThenPlayPreservesRequestedPosition() async throws {
        try await assertRealEOFStopAtEndReplay(seekAfterEOF: true)
    }

    func testRealEOFStopAtEndPausedExactSeekCommitsOnlyAfterRealCompletion() async throws {
        try await assertRealEOFPausedExactSeek(to: 0.25)
    }

    func testRealEOFStopAtEndPausedExactSeekZeroCommitsOnlyAfterRealCompletion() async throws {
        try await assertRealEOFPausedExactSeek(to: 0)
    }

    private func assertRealEOFPausedExactSeek(to requested: TimeInterval) async throws {
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealEOFExactSeek-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let readers = NSHashTable<AnyObject>.weakObjects()
        addTeardownBlock { @MainActor in
            guard autoreleasepool(invoking: { readers.allObjects.isEmpty }) else {
                print("AVFoundation cleanup pending; preserving exact seek fixtures at \(root.path)")
                return
            }
            try FileManager.default.removeItem(at: root)
        }
        let urls = [root.appendingPathComponent("short.wav"), root.appendingPathComponent("next.wav")]
        try writeRecoveryWAV(to: urls[0], duration: 2)
        try writeRecoveryWAV(to: urls[1], duration: 30)
        let originalBytes = try urls.map { try Data(contentsOf: $0) }
        let tracks = [MusicItem(url: urls[0], duration: 2), MusicItem(url: urls[1], duration: 30)]
        // Isolate queued periodic publication, not AVFoundation transport, item or seek.
        let player = ManuallyDrivenPeriodicPlayer()
        player.isMuted = true
        var activations = 0
        let manager = MusicPlaybackManager(
            player: player, defaults: store, activateAudioSession: { activations += 1 },
            nowPlayingController: RecordingNowPlayingController()
        )
        readers.add(player); readers.add(manager)
        var items: [AVPlayerItem] = []
        defer {
            manager.pause()
            player.replaceCurrentItem(with: nil)
            items.forEach { $0.cancelPendingSeeks(); $0.asset.cancelLoading() }
        }
        manager.setCompletionMode(.stopAtEnd)
        let transition = manager.completionTransitionGeneration
        let failure = manager.itemFailureNotificationGeneration
        manager.playFromPlaylist(tracks[0], playlistID: UUID(), items: tracks)
        let expectedQueue = manager.queue
        let expectedIndex = manager.currentIndex
        let expectedScope = manager.queueScope
        let exhaustedItem = try XCTUnwrap(player.currentItem)
        items.append(exhaustedItem); readers.add(exhaustedItem); readers.add(exhaustedItem.asset)
        let ready = expectation(description: "Short WAV item becomes ready")
        let ended = expectation(description: "Real WAV reaches natural EOF without a seek or posted notification")
        let handled = expectation(description: "Production stopAtEnd completion handler returns")
        let readyObservation = exhaustedItem.publisher(for: \.status, options: [.initial, .new])
            .filter { $0 == .readyToPlay }.prefix(1).sink { _ in ready.fulfill() }
        let endObservation = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: exhaustedItem)
            .prefix(1).sink { _ in ended.fulfill() }
        let handlerObservation = manager.$completionTransitionGeneration
            .filter { $0 > transition }.prefix(1).sink { _ in handled.fulfill() }
        defer { readyObservation.cancel(); endObservation.cancel(); handlerObservation.cancel() }
        guard await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed else {
            XCTFail("Prerequisite failed: WAV not ready before natural EOF")
            return
        }
        // Seed a nonzero confirmed timeline through the installed periodic callback;
        // no synthetic seek completion or physical seek precedes natural EOF.
        try await awaitPeriodicHandler(on: manager) {
            try XCTUnwrap(player.periodicCallback)(CMTime(seconds: 0.75, preferredTimescale: 600))
        }
        manager.savePlaybackState()
        guard await XCTWaiter.fulfillment(of: [ended, handled], timeout: 10) == .completed else {
            XCTFail("Prerequisite failed: real natural EOF/stopAtEnd handler not established; not exact-seek RED")
            return
        }
        guard manager.currentTrack == tracks[0], player.currentItem === exhaustedItem,
              manager.completionMode == .stopAtEnd,
              manager.completionTransitionGeneration == transition + 1,
              manager.itemFailureNotificationGeneration == failure,
              exhaustedItem.status == .readyToPlay, exhaustedItem.error == nil, player.error == nil,
              abs(exhaustedItem.duration.seconds - 2) < 0.1,
              abs(exhaustedItem.currentTime().seconds - 2) < 0.1,
              !manager.isPlaying, player.rate == 0, player.timeControlStatus == .paused,
              manager.playbackErrorMessage == nil, activations == 1 else {
            XCTFail("Prerequisite failed: healthy ready exhausted item and paused stopAtEnd state required; not exact-seek RED")
            return
        }

        // Both requested targets are exactly representable at both the WAV's 8 kHz and seek's 600 Hz.
        // Allow one tick of the coarser clock, not a broad playback-progress window.
        let precision = max(1.0 / 8_000.0, 1.0 / 600.0)
        // Physical EOF is independently established from the real item.
        let confirmedPosition = manager.currentTime
        let persistedPosition = try XCTUnwrap(store.object(forKey: "MusicPlayback.lastPositionSeconds") as? NSNumber).doubleValue
        guard confirmedPosition.isFinite, persistedPosition.isFinite,
              abs(confirmedPosition - requested) > precision,
              abs(persistedPosition - requested) > precision else {
            XCTFail("Prerequisite failed: distinguishable confirmed/persisted positions required to detect optimistic seek commit")
            return
        }
        let loadBeforeSeek = manager.trackLoadGeneration
        let seekGeneration = manager.seekCompletionGeneration
        let completed = expectation(description: "Public post-EOF seek's real completion handler returns")
        let seekObservation = manager.seekCompletionPublisher
            .filter { $0 > seekGeneration }.prefix(1).sink { _ in completed.fulfill() }
        let playbackObserved = CurrentValueSubject<Bool, Never>(false)
        let playbackObservation = player.publisher(for: \.timeControlStatus, options: [.initial, .new])
            .filter { $0 == .playing }.sink { _ in playbackObserved.send(true) }
        defer { seekObservation.cancel(); playbackObservation.cancel() }

        manager.seek(to: requested)
        // No suspension: requesting a position must not commit it optimistically.
        XCTAssertEqual(manager.currentTime, confirmedPosition)
        XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"), persistedPosition)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(activations, 1)
        let itemAfterRequest = player.currentItem
        let loadAfterRequest = manager.trackLoadGeneration
        if let itemAfterRequest, itemAfterRequest !== exhaustedItem {
            items.append(itemAfterRequest); readers.add(itemAfterRequest); readers.add(itemAfterRequest.asset)
        }
        // Always wait, including when EOF recovery replaced the item.
        guard await XCTWaiter.fulfillment(of: [completed], timeout: 5) == .completed else {
            XCTFail("Exact-seek contract RED after established healthy natural EOF: public seek did not deliver its real completion handler, even if the item was replaced")
            return
        }
        let positionedItem = try XCTUnwrap(player.currentItem)
        let positionedReady = expectation(description: "Post-EOF seek item is ready for physical position assertions")
        let positionedObservation = positionedItem.publisher(for: \.status, options: [.initial, .new])
            .filter { $0 == .readyToPlay }.prefix(1).sink { _ in positionedReady.fulfill() }
        defer { positionedObservation.cancel() }
        guard await XCTWaiter.fulfillment(of: [positionedReady], timeout: 5) == .completed else {
            XCTFail("Exact-seek contract failed: current item not ready after real completion")
            return
        }
        // The diagnostic publisher also counts false/stale callbacks. Only the
        // actual item time plus committed state below establish this seek's success.
        let actual = positionedItem.currentTime().seconds
        XCTAssertTrue(actual.isFinite)
        XCTAssertEqual(actual, requested, accuracy: precision)
        XCTAssertEqual(manager.currentTime, actual, accuracy: precision)
        XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"), actual, accuracy: precision)
        XCTAssertEqual(manager.seekCompletionGeneration, seekGeneration + 1)
        XCTAssertTrue(player.currentItem === itemAfterRequest, "Completion must not replace the requested item again")
        XCTAssertEqual(manager.trackLoadGeneration, loadAfterRequest)
        XCTAssertEqual(loadAfterRequest, loadBeforeSeek + (itemAfterRequest === exhaustedItem ? 0 : 1))
        XCTAssertFalse(playbackObserved.value, "Paused seek must not spuriously start transport")
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(player.timeControlStatus, .paused)
        XCTAssertEqual(activations, 1)
        XCTAssertEqual((positionedItem.asset as? AVURLAsset)?.url, urls[0])
        XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertEqual(manager.queue, expectedQueue)
        XCTAssertEqual(manager.currentIndex, expectedIndex)
        XCTAssertEqual(manager.queueScope, expectedScope)
        XCTAssertEqual(manager.completionMode, .stopAtEnd)
        XCTAssertEqual(manager.completionTransitionGeneration, transition + 1)
        XCTAssertEqual(manager.itemFailureNotificationGeneration, failure)
        XCTAssertNil(positionedItem.error)
        XCTAssertNil(player.error)
        XCTAssertNil(manager.playbackErrorMessage)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, originalBytes)
    }

    func testSameItemLatestSeekRequestWinsWhenOlderCompletionArrivesLast() async throws {
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SameItemSeekOrdering-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let readers = NSHashTable<AnyObject>.weakObjects()
        addTeardownBlock { @MainActor in
            guard autoreleasepool(invoking: { readers.allObjects.isEmpty }) else {
                print("AVFoundation cleanup pending; preserving seek ordering fixtures at \(root.path)")
                return
            }
            try FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("readable.wav")
        try writeRecoveryWAV(to: url, duration: 30)
        let originalBytes = try Data(contentsOf: url)
        let track = MusicItem(url: url, duration: 30)
        let player = ManuallyDrivenPeriodicPlayer()
        player.isMuted = true
        let controller = RecordingNowPlayingController()
        let manager = MusicPlaybackManager(
            player: player, defaults: store, activateAudioSession: {},
            nowPlayingController: controller
        )
        readers.add(player); readers.add(manager)
        manager.playFromPlaylist(track, playlistID: UUID(), items: [track])
        let item = try XCTUnwrap(player.currentItem)
        readers.add(item); readers.add(item.asset)
        defer {
            manager.pause()
            player.replaceCurrentItem(with: nil)
            item.cancelPendingSeeks()
            item.asset.cancelLoading()
        }
        let ready = expectation(description: "Readable WAV becomes ready for same-item seek ordering")
        let readyObservation = item.publisher(for: \.status, options: [.initial, .new])
            .filter { $0 == .readyToPlay }.prefix(1).sink { _ in ready.fulfill() }
        defer { readyObservation.cancel() }
        guard await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed else {
            XCTFail("Prerequisite failed: readable current WAV required; not seek ordering RED")
            return
        }
        manager.pause()
        let load = manager.trackLoadGeneration
        let failure = manager.itemFailureNotificationGeneration
        XCTAssertTrue(player.currentItem === item)
        XCTAssertNil(item.error)
        XCTAssertNil(player.error)
        XCTAssertEqual((item.asset as? AVURLAsset)?.url, url)

        // Only these injected callbacks can satisfy each seek handler barrier.
        // Manual periodic isolation prevents unrelated timeline/defaults updates.
        func deliver(_ callback: @Sendable (Bool) -> Void, finished: Bool, phase: String) async throws {
            let generation = manager.seekCompletionGeneration
            let handled = expectation(description: phase)
            let observation = manager.seekCompletionPublisher
                .filter { $0 > generation }.prefix(1).sink { _ in handled.fulfill() }
            defer { observation.cancel() }
            callback(finished)
            guard await XCTWaiter.fulfillment(of: [handled], timeout: 2) == .completed else {
                XCTFail("Exact injected seek handler did not return: \(phase)")
                throw AudioSessionNotificationError.processingTimedOut
            }
            XCTAssertEqual(manager.seekCompletionGeneration, generation + 1)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertEqual(manager.trackLoadGeneration, load)
            XCTAssertEqual(manager.itemFailureNotificationGeneration, failure)
        }

        // The production factory creates two requests in the same item/epoch.
        // Injected true exercises acceptance ordering, not physical AVPlayer seek.
        let requestA = manager.seekCompletionCallback(to: 0.25)
        let requestB = manager.seekCompletionCallback(to: 0.5)
        try await deliver(requestB, finished: true, phase: "Latest B success handler returns")
        XCTAssertEqual(manager.currentTime, 0.5)
        XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"), 0.5)
        XCTAssertEqual(controller.snapshots.last?.elapsedTime, 0.5)
        let snapshotsAfterB = controller.snapshots

        try await deliver(requestA, finished: true, phase: "Older A success handler returns after B")
        XCTAssertEqual(manager.currentTime, 0.5, "Old same-item success must not overwrite B")
        XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"), 0.5)
        XCTAssertEqual(controller.snapshots, snapshotsAfterB)

        try await deliver(requestA, finished: false, phase: "Older A cancellation handler returns after B")
        XCTAssertEqual(manager.currentTime, 0.5, "Old cancellation must leave B committed")
        XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"), 0.5)
        XCTAssertEqual(controller.snapshots, snapshotsAfterB)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(player.rate, 0)
        XCTAssertNil(manager.playbackErrorMessage)
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    }

    // These tests control handler acceptance only: injected true is NOT evidence
    // that AVFoundation physically sought. Real EOF exact-seek tests stay separate.
    func testLatestSeekFalsePreservesNonzeroConfirmationAndCannotRevive() async throws {
        try await withReadySeekAcceptanceFixture { manager, player, store, controller, activations in
            try await self.awaitSeekHandler(on: manager) { manager.seekCompletionCallback(to: 7)(true) }
            let snapshots = controller.snapshots
            let activationCount = activations()
            let cancelled = manager.seekCompletionCallback(to: 12)
            try await self.awaitSeekHandler(on: manager) { cancelled(false) }
            self.assertSeekConfirmation(manager, store, controller, position: 7)
            XCTAssertEqual(controller.snapshots, snapshots)
            XCTAssertNil(manager.playbackErrorMessage)
            XCTAssertFalse(manager.isPlaying)
            XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(activations(), activationCount)

            try await self.awaitSeekHandler(on: manager) { cancelled(true) }
            self.assertSeekConfirmation(manager, store, controller, position: 7)
            XCTAssertEqual(controller.snapshots, snapshots, "Consumed false cannot be revived by duplicate true")
            XCTAssertNil(manager.playbackErrorMessage)
            XCTAssertFalse(manager.isPlaying)
            XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(activations(), activationCount)

            // Same target, new factory-issued identity. The consumed closure cannot
            // consume this new request even though both targets equal twelve.
            let replacement = manager.seekCompletionCallback(to: 12)
            try await self.awaitSeekHandler(on: manager) { cancelled(true) }
            XCTAssertEqual(controller.snapshots, snapshots)
            self.assertSeekConfirmation(manager, store, controller, position: 7)
            try await self.awaitSeekHandler(on: manager) { replacement(true) }
            self.assertSeekConfirmation(manager, store, controller, position: 12)
            XCTAssertEqual(controller.snapshots.count, snapshots.count + 1)
            XCTAssertFalse(manager.isPlaying)
            XCTAssertEqual(player.rate, 0)
            XCTAssertNil(manager.playbackErrorMessage)
            XCTAssertEqual(activations(), activationCount)
        }
    }

    func testQueuedSeekSuccessIsSupersededBeforeActorHopAndStaleFalseLeavesLatestPending() async throws {
        try await withReadySeekAcceptanceFixture { manager, _, store, controller, _ in
            try await self.awaitSeekHandler(on: manager) { manager.seekCompletionCallback(to: 7)(true) }
            let snapshots = controller.snapshots
            let requestA = manager.seekCompletionCallback(to: 12)
            var requestB: (@Sendable (Bool) -> Void)?
            try await self.awaitSeekHandler(on: manager) {
                requestA(true) // Enqueue A's MainActor task while this actor is held.
                requestB = manager.seekCompletionCallback(to: 15) // No await before B exists.
            }
            self.assertSeekConfirmation(manager, store, controller, position: 7)
            XCTAssertEqual(controller.snapshots, snapshots, "Queued A must check identity after its actor hop")
            try await self.awaitSeekHandler(on: manager) { requestA(false) }
            self.assertSeekConfirmation(manager, store, controller, position: 7)
            XCTAssertEqual(controller.snapshots, snapshots)
            let latest = try XCTUnwrap(requestB)
            try await self.awaitSeekHandler(on: manager) { latest(true) }
            self.assertSeekConfirmation(manager, store, controller, position: 15)
            XCTAssertEqual(controller.snapshots.count, snapshots.count + 1, "Stale A(false) must not consume B")
            let committed = controller.snapshots
            try await self.awaitSeekHandler(on: manager) { latest(true) }
            self.assertSeekConfirmation(manager, store, controller, position: 15)
            XCTAssertEqual(controller.snapshots, committed, "Duplicate success must not republish")
        }
    }

    func testPendingSeekTruePreservesExplicitPlay() async throws {
        try await assertPendingSeekPreservesExplicitPlay(finished: true)
    }

    func testPendingSeekFalsePreservesExplicitPlay() async throws {
        try await assertPendingSeekPreservesExplicitPlay(finished: false)
    }

    private func assertPendingSeekPreservesExplicitPlay(finished: Bool) async throws {
        try await withReadySeekAcceptanceFixture { manager, player, store, controller, activations in
            try await self.awaitSeekHandler(on: manager) { manager.seekCompletionCallback(to: 7)(true) }
            let pending = manager.seekCompletionCallback(to: 12)
            let beforePlay = activations()
            manager.play()
            XCTAssertEqual(activations(), beforePlay + 1)
            self.assertSeekConfirmation(manager, store, controller, position: 7)
            try await self.awaitFutureBoundary(on: player)
            let physicalBefore = player.currentTime().seconds
            let item = player.currentItem
            let load = manager.trackLoadGeneration
            let snapshots = controller.snapshots
            try await self.awaitSeekHandler(on: manager) { pending(finished) }
            if !finished { XCTAssertEqual(controller.snapshots, snapshots) }
            XCTAssertTrue(manager.isPlaying)
            XCTAssertEqual(player.rate, 1)
            XCTAssertEqual(player.timeControlStatus, .playing)
            XCTAssertGreaterThanOrEqual(player.currentTime().seconds, physicalBefore - 1.0 / 600)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertEqual(manager.trackLoadGeneration, load)
            XCTAssertEqual(activations(), beforePlay + 1)
            XCTAssertNil(manager.playbackErrorMessage)
            self.assertSeekConfirmation(manager, store, controller, position: finished ? 12 : 7)
            // Real transport advances, independently of the simulated target label.
            try await self.awaitFutureBoundary(on: player)
        }
    }

    func testPendingSeekTrueAfterExplicitPauseNeverResumesAndNormalPlayAdvances() async throws {
        try await withReadySeekAcceptanceFixture { manager, player, store, controller, activations in
            manager.play()
            try await self.awaitFutureBoundary(on: player)
            XCTAssertEqual(player.timeControlStatus, .playing)
            let pending = manager.seekCompletionCallback(to: 12)
            let activationCount = activations()
            manager.pause() // The production pause first stops an advancing player.
            let pausedPosition = player.currentTime().seconds
            try await self.awaitSeekHandler(on: manager) { pending(true) }
            try await Task.sleep(nanoseconds: 150_000_000)
            XCTAssertFalse(manager.isPlaying)
            XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(player.timeControlStatus, .paused)
            XCTAssertEqual(player.currentTime().seconds, pausedPosition, accuracy: 1.0 / 600)
            XCTAssertEqual(activations(), activationCount)
            XCTAssertNil(manager.playbackErrorMessage)
            self.assertSeekConfirmation(manager, store, controller, position: 12)
            // Subscribe to a future physical boundary BEFORE production resume.
            try await self.awaitFutureBoundary(on: player) { manager.play() }
            XCTAssertTrue(manager.isPlaying)
            XCTAssertEqual(player.timeControlStatus, .playing)
            XCTAssertGreaterThan(player.currentTime().seconds, pausedPosition)
            XCTAssertEqual(activations(), activationCount + 1)
        }
    }

    // Expected behavioral RED until production gates periodic publication while a
    // seek is pending. Keep separate from callback acceptance and physical seeks.
    func testPendingSeekPeriodicRetainsConfirmedPositionUntilCompletion() async throws {
        try await withReadySeekAcceptanceFixture { manager, player, store, controller, _ in
            try await self.awaitSeekHandler(on: manager) { manager.seekCompletionCallback(to: 7)(true) }
            let snapshots = controller.snapshots
            let pending = manager.seekCompletionCallback(to: 12)
            let periodic = try XCTUnwrap(player.periodicCallback) // Actual registered closure.
            try await self.awaitPeriodicHandler(on: manager) {
                periodic(CMTime(seconds: 9, preferredTimescale: 600))
            }
            self.assertSeekConfirmation(manager, store, controller, position: 7)
            XCTAssertEqual(controller.snapshots, snapshots, "Pending periodic must retain confirmed state, without preview")
            try await self.awaitSeekHandler(on: manager) { pending(true) }
            self.assertSeekConfirmation(manager, store, controller, position: 12)
            // Respect the real five-second persistence throttle; no production clock seam.
            try await Task.sleep(nanoseconds: 5_100_000_000)
            let afterSeek = controller.snapshots.count
            try await self.awaitPeriodicHandler(on: manager) {
                periodic(CMTime(seconds: 14, preferredTimescale: 600))
            }
            self.assertSeekConfirmation(manager, store, controller, position: 14)
            XCTAssertEqual(controller.snapshots.count, afterSeek + 1, "Fresh periodic must resume publication and persistence")
        }
    }

    private func assertSeekConfirmation(
        _ manager: MusicPlaybackManager, _ store: UserDefaults,
        _ controller: RecordingNowPlayingController, position: TimeInterval,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(manager.currentTime, position, file: file, line: line)
        XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"), position, file: file, line: line)
        XCTAssertEqual(controller.snapshots.last?.elapsedTime, position, file: file, line: line)
    }

    private func awaitSeekHandler(on manager: MusicPlaybackManager, action: () throws -> Void) async throws {
        let generation = manager.seekCompletionGeneration
        let handled = expectation(description: "Controlled seek handler returned")
        let observation = manager.seekCompletionPublisher.filter { $0 > generation }.prefix(1)
            .sink { _ in handled.fulfill() }
        defer { observation.cancel() }
        try action() // Subscription precedes callback release, including queued-A case.
        guard await XCTWaiter.fulfillment(of: [handled], timeout: 2) == .completed else {
            XCTFail("Controlled seek handler timed out")
            throw AudioSessionNotificationError.processingTimedOut
        }
        XCTAssertEqual(manager.seekCompletionGeneration, generation + 1)
    }

    private func awaitPeriodicHandler(on manager: MusicPlaybackManager, action: () throws -> Void) async throws {
        let generation = manager.periodicCompletionGeneration
        let handled = expectation(description: "Captured periodic handler returned")
        let observation = manager.periodicCompletionPublisher.filter { $0 > generation }.prefix(1)
            .sink { _ in handled.fulfill() }
        defer { observation.cancel() }
        try action()
        guard await XCTWaiter.fulfillment(of: [handled], timeout: 2) == .completed else {
            XCTFail("Captured periodic handler timed out")
            throw AudioSessionNotificationError.processingTimedOut
        }
        XCTAssertEqual(manager.periodicCompletionGeneration, generation + 1)
    }

    private func awaitFutureBoundary(on player: AVPlayer, action: () -> Void = {}) async throws {
        let target = player.currentTime().seconds + 0.25
        let advanced = expectation(description: "Real AVPlayer crosses a future boundary")
        let token = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: target, preferredTimescale: 600))], queue: .main
        ) { advanced.fulfill() }
        defer { player.removeTimeObserver(token) }
        action()
        guard await XCTWaiter.fulfillment(of: [advanced], timeout: 3) == .completed else {
            XCTFail("Real AVPlayer did not advance across the future boundary")
            throw AudioSessionNotificationError.processingTimedOut
        }
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, target - 1.0 / 600)
    }

    private func withReadySeekAcceptanceFixture(
        _ body: (MusicPlaybackManager, ManuallyDrivenPeriodicPlayer, UserDefaults,
                 RecordingNowPlayingController, () -> Int) async throws -> Void
    ) async throws {
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SeekAcceptance-\(UUID().uuidString).wav")
        try writeRecoveryWAV(to: url, duration: 30)
        let readers = NSHashTable<AnyObject>.weakObjects()
        addTeardownBlock { @MainActor in
            guard autoreleasepool(invoking: { readers.allObjects.isEmpty }) else {
                print("AVFoundation cleanup pending; preserving seek fixture at \(url.path)")
                return
            }
            try FileManager.default.removeItem(at: url)
        }
        let player = ManuallyDrivenPeriodicPlayer()
        player.isMuted = true
        let controller = RecordingNowPlayingController()
        var activations = 0
        let manager = MusicPlaybackManager(player: player, defaults: store,
            activateAudioSession: { activations += 1 }, nowPlayingController: controller)
        readers.add(player); readers.add(manager)
        let track = MusicItem(url: url, duration: 30)
        manager.playFromPlaylist(track, playlistID: UUID(), items: [track])
        let item = try XCTUnwrap(player.currentItem)
        readers.add(item); readers.add(item.asset)
        defer {
            manager.pause()
            player.replaceCurrentItem(with: nil)
            item.cancelPendingSeeks(); item.asset.cancelLoading()
        }
        let ready = expectation(description: "Acceptance fixture WAV ready")
        let observation = item.publisher(for: \.status, options: [.initial, .new])
            .filter { $0 == .readyToPlay }.prefix(1).sink { _ in ready.fulfill() }
        defer { observation.cancel() }
        guard await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed else {
            XCTFail("Prerequisite failed: valid WAV not ready; not a seek contract RED")
            throw AudioSessionNotificationError.processingTimedOut
        }
        manager.pause()
        XCTAssertEqual(activations, 1)
        let load = manager.trackLoadGeneration
        let failure = manager.itemFailureNotificationGeneration
        try await body(manager, player, store, controller, { activations })
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(manager.trackLoadGeneration, load)
        XCTAssertEqual(manager.itemFailureNotificationGeneration, failure)
        XCTAssertEqual(manager.currentTrack, track)
        XCTAssertNil(item.error)
        XCTAssertNil(player.error)
    }

    private func assertRealEOFStopAtEndReplay(
        retained: Bool = false,
        seekAfterEOF: Bool = false
    ) async throws {
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealEOFStopAtEndReplay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let readers = NSHashTable<AnyObject>.weakObjects()
        addTeardownBlock { @MainActor in
            guard autoreleasepool(invoking: { readers.allObjects.isEmpty }) else {
                print("AVFoundation cleanup pending; preserving EOF replay fixtures at \(root.path)")
                return
            }
            try FileManager.default.removeItem(at: root)
        }
        let urls = [root.appendingPathComponent("short.wav"), root.appendingPathComponent("next.wav")]
        try writeRecoveryWAV(to: urls[0], duration: 2)
        try writeRecoveryWAV(to: urls[1], duration: 30)
        let originalBytes = try urls.map { try Data(contentsOf: $0) }
        let tracks = [MusicItem(url: urls[0], duration: 2), MusicItem(url: urls[1], duration: 30)]
        let player = AVPlayer()
        player.isMuted = true
        let manager = MusicPlaybackManager(
            player: player, defaults: store, activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController()
        )
        readers.add(player); readers.add(manager)
        var items: [AVPlayerItem] = []
        defer {
            manager.pause()
            player.replaceCurrentItem(with: nil)
            items.forEach { $0.cancelPendingSeeks(); $0.asset.cancelLoading() }
        }
        manager.setCompletionMode(.stopAtEnd)
        if retained {
            let playlistID = UUID()
            manager.playFromPlaylist(tracks[0], playlistID: playlistID, items: tracks)
            manager.reconcilePlaylistQueue(id: playlistID, items: [tracks[1]])
        } else {
            manager.playFromLibrary(tracks[0], library: tracks)
        }
        let expectedQueue = manager.queue
        let expectedIndex = manager.currentIndex
        let expectedScope = manager.queueScope
        let exhaustedItem = try XCTUnwrap(player.currentItem)
        items.append(exhaustedItem); readers.add(exhaustedItem); readers.add(exhaustedItem.asset)
        let transition = manager.completionTransitionGeneration
        let ready = expectation(description: "Short WAV is ready")
        let playing = expectation(description: "Short WAV actually plays before EOF")
        let ended = expectation(description: "Real AVFoundation EOF without seek or posted notification")
        let handled = expectation(description: "Production stop-at-end handler completes")
        let readyObservation = exhaustedItem.publisher(for: \.status, options: [.initial, .new])
            .filter { $0 == .readyToPlay }.prefix(1).sink { _ in ready.fulfill() }
        let playingObservation = player.publisher(for: \.timeControlStatus, options: [.initial, .new])
            .filter { $0 == .playing }.prefix(1).sink { _ in playing.fulfill() }
        let endObservation = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: exhaustedItem)
            .prefix(1).sink { _ in ended.fulfill() }
        let handlerObservation = manager.$completionTransitionGeneration
            .filter { $0 > transition }.prefix(1).sink { _ in handled.fulfill() }
        defer {
            readyObservation.cancel(); playingObservation.cancel()
            endObservation.cancel(); handlerObservation.cancel()
        }
        guard await XCTWaiter.fulfillment(of: [ready, playing, ended, handled], timeout: 10) == .completed else {
            XCTFail("Prerequisite failed: real EOF and stop handler not established; not a replay RED. itemStatus=\(exhaustedItem.status.rawValue)")
            return
        }
        guard manager.currentTrack == tracks[0], player.currentItem === exhaustedItem,
              !manager.isPlaying, player.rate == 0, manager.playbackErrorMessage == nil,
              exhaustedItem.status == .readyToPlay, exhaustedItem.error == nil,
              abs(exhaustedItem.duration.seconds - 2) < 0.1,
              abs(exhaustedItem.currentTime().seconds - 2) < 0.1 else {
            XCTFail("Prerequisite failed: natural stop must retain the healthy exhausted song and pause; not a replay RED")
            return
        }
        manager.setCompletionMode(.repeatAll)
        XCTAssertFalse(manager.isPlaying, "Changing completion mode alone must remain paused")
        XCTAssertEqual(player.rate, 0)
        XCTAssertTrue(player.currentItem === exhaustedItem)
        XCTAssertEqual(exhaustedItem.currentTime().seconds, 2, accuracy: 0.1)
        XCTAssertEqual(manager.queue, expectedQueue, "A successor must remain available")
        var seekItem: AVPlayerItem?
        var loadAfterSeek: UInt64?
        if seekAfterEOF {
            let seekGeneration = manager.seekCompletionGeneration
            let completed = expectation(description: "Post-EOF seek completes before explicit Play")
            let seekObservation = manager.seekCompletionPublisher
                .filter { $0 > seekGeneration }.prefix(1)
                .sink { _ in completed.fulfill() }
            defer { seekObservation.cancel() }
            manager.seek(to: 0.25)
            let positionedItem = try XCTUnwrap(player.currentItem)
            seekItem = positionedItem
            items.append(positionedItem); readers.add(positionedItem); readers.add(positionedItem.asset)
            loadAfterSeek = manager.trackLoadGeneration
            // Completion is required even when EOF recovery replaces the item.
            guard await XCTWaiter.fulfillment(of: [completed], timeout: 5) == .completed else {
                XCTFail("Post-EOF seek did not complete before explicit Play")
                return
            }
            XCTAssertEqual(manager.seekCompletionGeneration, seekGeneration + 1)
            XCTAssertTrue(player.currentItem === positionedItem)
            XCTAssertEqual(manager.trackLoadGeneration, loadAfterSeek)
            XCTAssertFalse(manager.isPlaying)
            XCTAssertEqual(manager.currentTime, 0.25)
            XCTAssertEqual(positionedItem.currentTime().seconds, 0.25, accuracy: 1.0 / 600.0)
        }

        // Observe real transport after explicit Play. Label clamping or setting
        // isPlaying cannot satisfy early boundaries on this exhausted WAV.
        let nearZero = expectation(description: "Replayed song crosses its first early boundary")
        let advanced = expectation(description: "Replayed song advances through 0.65 seconds")
        let nearZeroToken = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: seekAfterEOF ? 0.4 : 0.1, preferredTimescale: 600))], queue: .main
        ) { nearZero.fulfill() }
        let advancedToken = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: 0.65, preferredTimescale: 600))], queue: .main
        ) {
            // Freeze only after actual progress to keep a second EOF out of assertions.
            player.pause()
            advanced.fulfill()
        }
        defer { player.removeTimeObserver(nearZeroToken); player.removeTimeObserver(advancedToken) }
        let timelineAdvanced = expectation(description: "Real periodic publication advances inside replayed song")
        let timelineObservation = manager.timeline.$currentTime.dropFirst()
            .filter { $0 > 0.1 && $0 < 1.5 }.prefix(1).sink { _ in timelineAdvanced.fulfill() }
        defer { timelineObservation.cancel() }
        manager.play()
        let replayItem = try XCTUnwrap(player.currentItem)
        if let seekItem, let loadAfterSeek {
            XCTAssertTrue(replayItem === seekItem, "Play must preserve the explicit post-EOF seek")
            XCTAssertEqual(manager.trackLoadGeneration, loadAfterSeek)
            XCTAssertEqual(manager.currentTime, 0.25, "Cleared EOF state must not reset the requested position")
        }
        items.append(replayItem); readers.add(replayItem); readers.add(replayItem.asset)
        guard await XCTWaiter.fulfillment(of: [nearZero, advanced, timelineAdvanced], timeout: 5) == .completed else {
            XCTFail("Replay contract failed after established real EOF: explicit Play must restart the same song and cross 0.1/0.65 s with real periodic progress. playerTime=\(player.currentTime().seconds), timeline=\(manager.currentTime), duration=\(manager.duration), rate=\(player.rate), status=\(player.timeControlStatus.rawValue), itemError=\(String(describing: player.currentItem?.error))")
            return
        }
        XCTAssertTrue(player.currentItem === replayItem, "No automatic advance to successor during replay")
        XCTAssertEqual((replayItem.asset as? AVURLAsset)?.url, urls[0])
        XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertEqual(manager.currentIndex, expectedIndex)
        XCTAssertEqual(manager.queue, expectedQueue)
        XCTAssertEqual(manager.queueScope, expectedScope)
        XCTAssertEqual(manager.completionMode, .repeatAll)
        XCTAssertEqual(manager.completionTransitionGeneration, transition + 1)
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 0.65)
        XCTAssertLessThan(player.currentTime().seconds, 2)
        XCTAssertNil(replayItem.error)
        XCTAssertNil(manager.playbackErrorMessage)
        manager.pause()
        let pausedTime = player.currentTime().seconds
        let pausedItem = player.currentItem
        let pausedLoad = manager.trackLoadGeneration
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(player.rate, 0)
        manager.play()
        XCTAssertTrue(player.currentItem === pausedItem, "Ordinary mid-song pause/play must reuse the item")
        XCTAssertEqual(manager.trackLoadGeneration, pausedLoad)
        XCTAssertEqual(player.currentTime().seconds, pausedTime, accuracy: 0.1)
        manager.pause()
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, originalBytes)
    }

    private func assertRealEOFSameTrackRecovery(
        mode: MusicCompletionMode,
        remote: Bool,
        retained: Bool = false,
        verifyStaleDelivery: Bool = false
    ) async throws {
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RealEOFSameTrackRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let readers = NSHashTable<AnyObject>.weakObjects()
        addTeardownBlock { @MainActor in
            guard autoreleasepool(invoking: { readers.allObjects.isEmpty }) else {
                print("AVFoundation cleanup pending; preserving same-track EOF fixtures at \(root.path)")
                return
            }
            try FileManager.default.removeItem(at: root)
        }
        let urls = [root.appendingPathComponent("short.wav"), root.appendingPathComponent("other.wav")]
        try writeRecoveryWAV(to: urls[0], duration: 2)
        try writeRecoveryWAV(to: urls[1], duration: 30)
        let originalBytes = try urls.map { try Data(contentsOf: $0) }
        let tracks = [MusicItem(url: urls[0], duration: 2), MusicItem(url: urls[1], duration: 30)]
        // Only the stale-delivery case suppresses automatic periodic pulses. Its
        // item readiness, transport, boundary observers and EOF remain real.
        let player: AVPlayer = verifyStaleDelivery ? ManuallyDrivenPeriodicPlayer() : AVPlayer()
        player.isMuted = true
        let session = MPNowPlayingSession(players: [player])
        let center = session.nowPlayingInfoCenter
        defer { center.nowPlayingInfo = nil; center.playbackState = .stopped }
        var dispatcher: (@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)?
        let registry = MusicNowPlayingRegistry(commandProfileSetter: { _ in })
        let controller = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { handler in dispatcher = handler; return [] },
            sharedRegistryForTesting: registry
        )
        var activations = 0
        let manager = MusicPlaybackManager(
            player: player, defaults: store,
            activateAudioSession: {
                activations += 1
                if activations == 2 { throw TestFailure.activation }
            }, nowPlayingController: controller
        )
        readers.add(player); readers.add(manager)
        var items: [AVPlayerItem] = []
        defer {
            manager.pause()
            player.replaceCurrentItem(with: nil)
            items.forEach { $0.cancelPendingSeeks(); $0.asset.cancelLoading() }
        }
        let playlistID = UUID()
        manager.setCompletionMode(mode)
        manager.playFromPlaylist(tracks[0], playlistID: playlistID, items: tracks)
        let oldItem = try XCTUnwrap(player.currentItem)
        items.append(oldItem); readers.add(oldItem); readers.add(oldItem.asset)
        let oldSeek = manager.seekCompletionCallback(to: 1.75)
        let oldPeriodic = (player as? ManuallyDrivenPeriodicPlayer)?.periodicCallback
        if retained {
            manager.reconcilePlaylistQueue(id: playlistID, items: [tracks[1]])
            XCTAssertNil(manager.currentIndex)
            XCTAssertEqual(manager.currentTrack, tracks[0])
        }
        let expectedQueue = manager.queue
        let expectedIndex = manager.currentIndex
        let expectedRepair = manager.queueScopePersistenceNeedsRepair
        let transition = manager.completionTransitionGeneration
        let failure = manager.itemFailureNotificationGeneration
        let ready = expectation(description: "Short source WAV becomes ready")
        let playing = expectation(description: "Short source WAV actually plays")
        let ended = expectation(description: "Short source emits real EOF without a seek or posted notification")
        let handled = expectation(description: "Real EOF activation-failure handler returns")
        let readyObservation = oldItem.publisher(for: \.status, options: [.initial, .new])
            .filter { $0 == .readyToPlay }.prefix(1).sink { _ in ready.fulfill() }
        let playingObservation = player.publisher(for: \.timeControlStatus, options: [.initial, .new])
            .filter { $0 == .playing }.prefix(1).sink { _ in playing.fulfill() }
        let endObservation = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: oldItem)
            .prefix(1).sink { _ in ended.fulfill() }
        let handlerObservation = manager.$completionTransitionGeneration
            .filter { $0 > transition }.prefix(1).sink { _ in handled.fulfill() }
        defer {
            readyObservation.cancel(); playingObservation.cancel()
            endObservation.cancel(); handlerObservation.cancel()
        }
        guard await XCTWaiter.fulfillment(of: [ready, playing, ended, handled], timeout: 10) == .completed else {
            XCTFail("Prerequisite failed: real EOF and its handler were not established; this is not the same-track recovery RED. status=\(oldItem.status.rawValue), activations=\(activations)")
            return
        }
        XCTAssertEqual(oldItem.currentTime().seconds, 2, accuracy: 0.1)
        XCTAssertNil(oldItem.error)
        XCTAssertEqual(manager.itemFailureNotificationGeneration, failure)
        XCTAssertEqual(manager.completionTransitionGeneration, transition + 1)
        XCTAssertEqual(activations, 2)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(player.rate, 0)
        XCTAssertFalse(manager.playbackErrorMessage?.isEmpty ?? true)
        XCTAssertTrue(player.currentItem === oldItem, "Failed automatic activation must preserve the exhausted source")
        XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertEqual(manager.queue, expectedQueue)
        XCTAssertEqual(manager.currentIndex, expectedIndex)

        // Register before the explicit command: a .playing flag on an exhausted
        // item is insufficient. Both early boundaries must be crossed after EOF.
        let nearZero = expectation(description: "Recovered source crosses 0.1 seconds from the beginning")
        let advanced = expectation(description: "Recovered source really advances through 0.65 seconds")
        let nearZeroToken = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: 0.1, preferredTimescale: 600))], queue: .main
        ) { nearZero.fulfill() }
        let advancedToken = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: 0.65, preferredTimescale: 600))], queue: .main
        ) {
            // Freeze real transport only AFTER progress, preventing a second EOF
            // while checking callbacks. Preserve manager intent for publication.
            player.pause()
            advanced.fulfill()
        }
        defer { player.removeTimeObserver(nearZeroToken); player.removeTimeObserver(advancedToken) }
        var publishedZero = false
        let zeroObservation = manager.timeline.$currentTime.dropFirst()
            .filter { $0 == 0 }.prefix(1).sink { _ in publishedZero = true }
        let recoveryPlaying = expectation(description: "Explicit same-track recovery actually enters playing")
        let recoveryPlayingObservation = player.publisher(for: \.timeControlStatus, options: [.initial, .new])
            .filter { $0 == .playing }.prefix(1).sink { _ in recoveryPlaying.fulfill() }
        defer { zeroObservation.cancel(); recoveryPlayingObservation.cancel() }
        if remote {
            XCTAssertEqual(try XCTUnwrap(dispatcher)(.play), .success)
        } else {
            manager.play()
        }
        let recoveredItem = try XCTUnwrap(player.currentItem)
        items.append(recoveredItem); readers.add(recoveredItem); readers.add(recoveredItem.asset)
        // Reusing the item or safely reinstalling it are both valid contracts.
        XCTAssertEqual((recoveredItem.asset as? AVURLAsset)?.url, urls[0])
        let recoveryReady = expectation(description: "Recovered current item is ready")
        let recoveryReadyObservation = recoveredItem.publisher(for: \.status, options: [.initial, .new])
            .filter { $0 == .readyToPlay }.prefix(1).sink { _ in recoveryReady.fulfill() }
        defer { recoveryReadyObservation.cancel() }
        guard await XCTWaiter.fulfillment(
            of: [recoveryReady, recoveryPlaying, nearZero, advanced], timeout: 5
        ) == .completed else {
            XCTFail("Same-track recovery RED: explicit play after handled real EOF must restart the preserved song at zero and cross 0.1/0.65 s. time=\(recoveredItem.currentTime().seconds), status=\(recoveredItem.status.rawValue), activations=\(activations). Stale delivery was NOT exercised because initial recovery is unavailable.")
            return
        }
        XCTAssertTrue(publishedZero, "Explicit EOF recovery must publish a zero-start timeline")
        XCTAssertTrue(player.currentItem === recoveredItem)
        XCTAssertGreaterThanOrEqual(recoveredItem.currentTime().seconds, 0.65)
        XCTAssertLessThan(recoveredItem.currentTime().seconds, 2)
        XCTAssertNil(recoveredItem.error)
        XCTAssertNil(manager.playbackErrorMessage)
        XCTAssertTrue(manager.isPlaying)
        XCTAssertEqual(activations, 3, "Exactly one explicit activation recovers the same song")
        XCTAssertEqual(manager.completionTransitionGeneration, transition + 1)
        XCTAssertEqual(manager.itemFailureNotificationGeneration, failure)
        XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertEqual(manager.currentIndex, expectedIndex)
        XCTAssertEqual(manager.queue, expectedQueue)
        XCTAssertEqual(manager.queueScope, .playlist(playlistID))
        XCTAssertEqual(manager.queueScopePersistenceNeedsRepair, expectedRepair)
        XCTAssertEqual(manager.completionMode, mode)
        XCTAssertEqual(MusicQueueScopeStore(defaults: store).loadPlaylistID(), playlistID)
        XCTAssertEqual(store.string(forKey: "MusicPlayback.lastTrackFileName"), tracks[0].fileName)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, originalBytes)
        guard publishedZero, manager.playbackErrorMessage == nil else {
            XCTFail("Initial recovery contract failed; stale callback delivery was NOT exercised")
            return
        }

        if !verifyStaleDelivery {
            let timelineAdvanced = expectation(description: "Fresh real periodic observer restores advancing timeline")
            let observation = manager.timeline.$currentTime
                .filter { $0 > 0.1 && $0 < 1.5 }.prefix(1).sink { _ in timelineAdvanced.fulfill() }
            defer { observation.cancel() }
            let timelineResult = await XCTWaiter.fulfillment(of: [timelineAdvanced], timeout: 2)
            XCTAssertEqual(timelineResult, .completed,
                           "Real transport recovery must also restore accepted timeline callbacks")
            return
        }

        // This separate test uses only manually delivered periodic callbacks, so
        // completion barriers below cannot be satisfied by an unrelated live pulse.
        let manualPlayer = try XCTUnwrap(player as? ManuallyDrivenPeriodicPlayer)
        let freshPeriodic = try XCTUnwrap(manualPlayer.periodicCallback)
        func deliverPeriodic(_ callback: @Sendable (CMTime) -> Void, seconds: Double) async throws {
            let generation = manager.periodicCompletionGeneration
            let processed = expectation(description: "Exact periodic callback finishes its actor hop")
            let observation = manager.periodicCompletionPublisher
                .filter { $0 > generation }.prefix(1).sink { _ in processed.fulfill() }
            defer { observation.cancel() }
            callback(CMTime(seconds: seconds, preferredTimescale: 600))
            guard await XCTWaiter.fulfillment(of: [processed], timeout: 2) == .completed else {
                XCTFail("Periodic delivery barrier timed out")
                throw AudioSessionNotificationError.processingTimedOut
            }
            XCTAssertEqual(manager.periodicCompletionGeneration, generation + 1)
        }
        try await deliverPeriodic(freshPeriodic, seconds: 0.8)
        XCTAssertEqual(manager.currentTime, 0.8, "Recovery must accept a fresh callback epoch")
        guard manager.currentTime == 0.8 else {
            XCTFail("Fresh recovery periodic callback remains blocked; stale delivery was NOT exercised")
            return
        }
        // A real seek proves the freshly installed seek completion also works.
        let seekGeneration = manager.seekCompletionGeneration
        let sought = expectation(description: "Fresh recovery real seek completes")
        let seekObservation = manager.seekCompletionPublisher
            .filter { $0 > seekGeneration }.prefix(1).sink { _ in sought.fulfill() }
        manager.seek(to: 1)
        let seekResult = await XCTWaiter.fulfillment(of: [sought], timeout: 2)
        seekObservation.cancel()
        guard seekResult == .completed else {
            XCTFail("Fresh recovery seek completion timed out; stale delivery was NOT exercised")
            return
        }
        XCTAssertEqual(manager.currentTime, 1)
        XCTAssertEqual(recoveredItem.currentTime().seconds, 1, accuracy: 0.05)
        guard manager.currentTime == 1 else {
            XCTFail("Fresh recovery seek remains blocked; stale delivery was NOT exercised")
            return
        }
        let position = manager.currentTime
        let duration = manager.duration
        let persisted = try XCTUnwrap(store.persistentDomain(forName: suite)) as NSDictionary
        let snapshot = try XCTUnwrap(center.nowPlayingInfo) as NSDictionary
        let playbackState = center.playbackState
        func assertPreservedAfterStaleDelivery() throws {
            XCTAssertEqual(manager.currentTime, position)
            XCTAssertEqual(manager.duration, duration)
            XCTAssertEqual(try XCTUnwrap(store.persistentDomain(forName: suite)) as NSDictionary, persisted)
            XCTAssertEqual(try XCTUnwrap(center.nowPlayingInfo) as NSDictionary, snapshot)
            XCTAssertEqual(center.playbackState, playbackState)
            XCTAssertNil(manager.playbackErrorMessage)
            XCTAssertTrue(manager.isPlaying)
            XCTAssertTrue(player.currentItem === recoveredItem)
            XCTAssertEqual(manager.currentTrack, tracks[0])
            XCTAssertEqual(manager.currentIndex, expectedIndex)
            XCTAssertEqual(manager.queue, expectedQueue)
            XCTAssertEqual(manager.queueScope, .playlist(playlistID))
        }
        let oldSeekGeneration = manager.seekCompletionGeneration
        let oldSeekProcessed = expectation(description: "Captured pre-EOF seek finishes after same-track recovery")
        let oldSeekObservation = manager.seekCompletionPublisher
            .filter { $0 > oldSeekGeneration }.prefix(1).sink { _ in oldSeekProcessed.fulfill() }
        oldSeek(true)
        let oldSeekResult = await XCTWaiter.fulfillment(of: [oldSeekProcessed], timeout: 2)
        oldSeekObservation.cancel()
        guard oldSeekResult == .completed else {
            XCTFail("Captured pre-EOF seek barrier timed out")
            return
        }
        XCTAssertEqual(manager.seekCompletionGeneration, oldSeekGeneration + 1)
        try assertPreservedAfterStaleDelivery()
        let saveWindow = expectation(description: "Open periodic persistence window after fresh seek")
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) { saveWindow.fulfill() }
        guard await XCTWaiter.fulfillment(of: [saveWindow], timeout: 7) == .completed else {
            XCTFail("Periodic persistence window did not open")
            return
        }
        try await deliverPeriodic(try XCTUnwrap(oldPeriodic), seconds: 1.9)
        try assertPreservedAfterStaleDelivery()
        try await deliverPeriodic(freshPeriodic, seconds: 1.1)
        XCTAssertEqual(manager.currentTime, 1.1, "Rejecting old callbacks must not disable the fresh epoch")
        XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"), 1.1)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 1.1)
        XCTAssertEqual(activations, 3)
        XCTAssertEqual(manager.completionTransitionGeneration, transition + 1)
    }

    private func assertRealEOFActivationFailure(mode: MusicCompletionMode) async throws {
        // Real transport evidence complements the artificial-notification contract above.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NaturalCompletionActivation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let readers = NSHashTable<AnyObject>.weakObjects()
        addTeardownBlock { @MainActor in
            // Never unlink a fixture while AVFoundation or background analysis may read it.
            guard autoreleasepool(invoking: { readers.allObjects.isEmpty }) else {
                print("AVFoundation cleanup pending; preserving EOF fixtures at \(root.path)")
                return
            }
            try FileManager.default.removeItem(at: root)
        }
        let firstURL = root.appendingPathComponent("short.wav")
        let secondURL = root.appendingPathComponent("recovery.wav")
        try writeRecoveryWAV(to: firstURL, duration: 2)
        try writeRecoveryWAV(to: secondURL, duration: 30)
        let originalBytes = try [firstURL, secondURL].map { try Data(contentsOf: $0) }
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let player = AVPlayer()
        player.isMuted = true
        let controller = RecordingNowPlayingController()
        var activationCount = 0
        var injectedFailureCount = 0
        let manager = MusicPlaybackManager(
            player: player, defaults: store,
            activateAudioSession: {
                activationCount += 1
                if activationCount == 2 {
                    injectedFailureCount += 1
                    throw TestFailure.activation
                }
            }, nowPlayingController: controller
        )
        readers.add(player)
        readers.add(manager)
        var items: [AVPlayerItem] = []
        defer {
            manager.pause()
            player.replaceCurrentItem(with: nil)
            items.forEach { $0.cancelPendingSeeks(); $0.asset.cancelLoading() }
        }
        let tracks = [MusicItem(url: firstURL, duration: 2), MusicItem(url: secondURL, duration: 30)]
        let playlistID = UUID()
        manager.setCompletionMode(mode)
        manager.playFromPlaylist(tracks[0], playlistID: playlistID, items: tracks)
        let item = try XCTUnwrap(player.currentItem)
        items.append(item)
        readers.add(item)
        readers.add(item.asset)
        let loadGeneration = manager.trackLoadGeneration
        let transitionGeneration = manager.completionTransitionGeneration
        let failureGeneration = manager.itemFailureNotificationGeneration
        let started = expectation(description: "Short WAV actually starts")
        let ended = expectation(description: "AVFoundation emits actual EOF for short WAV")
        let handled = expectation(description: "Production completion handler finishes its actor hop")
        let startObservation = player.publisher(for: \.timeControlStatus, options: [.initial, .new])
            .filter { $0 == .playing }.prefix(1).sink { _ in started.fulfill() }
        // No posted notifications, seeks, manual callbacks, or synthetic player in this test.
        let endObservation = NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime, object: item)
            .prefix(1).sink { _ in ended.fulfill() }
        let handlerObservation = manager.$completionTransitionGeneration
            .filter { $0 > transitionGeneration }.prefix(1).sink { _ in handled.fulfill() }
        defer { startObservation.cancel(); endObservation.cancel(); handlerObservation.cancel() }
        XCTAssertEqual(activationCount, 1)
        let result = await XCTWaiter.fulfillment(of: [started, ended, handled], timeout: 10)
        guard result == .completed else {
            XCTFail("Real EOF/handler prerequisite timed out; not a contract RED. item status=\(item.status.rawValue), error=\(String(describing: item.error)), activations=\(activationCount)")
            return
        }
        XCTAssertEqual(item.status, .readyToPlay, "Activation injection must not be a decode failure")
        XCTAssertNil(item.error)
        XCTAssertNil(player.error)
        XCTAssertEqual(manager.itemFailureNotificationGeneration, failureGeneration)
        XCTAssertEqual(item.duration.seconds, 2, accuracy: 0.05)
        XCTAssertEqual(item.currentTime().seconds, 2, accuracy: 0.1, "Must reach real EOF without a seek")
        XCTAssertEqual(activationCount, 2, "Initial activation succeeds; exactly one automatic attempt fails")
        XCTAssertEqual(injectedFailureCount, 1)
        XCTAssertEqual(manager.completionTransitionGeneration, transitionGeneration + 1)

        // Expected RED at 56cd502: activation catch returns without these state updates.
        // Nonthrowing assertions deliberately let explicit recovery run even while RED.
        XCTAssertFalse(manager.isPlaying, "An exhausted item cannot retain playing intent after activation failure")
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(controller.snapshots.last?.playbackRate, 0)
        XCTAssertFalse(manager.playbackErrorMessage?.isEmpty ?? true, "Surface the injected activation failure")
        XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertEqual(manager.currentIndex, 0)
        XCTAssertEqual(manager.queue, tracks)
        XCTAssertEqual(manager.queueScope, .playlist(playlistID))
        XCTAssertEqual(manager.completionMode, mode)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual((item.asset as? AVURLAsset)?.url, firstURL)
        XCTAssertEqual(manager.trackLoadGeneration, loadGeneration)
        XCTAssertEqual(store.string(forKey: "MusicPlayback.lastTrackFileName"), tracks[0].fileName)
        XCTAssertEqual(MusicQueueScopeStore(defaults: store).loadPlaylistID(), playlistID)
        XCTAssertEqual(MusicCompletionModeStore(defaults: store).load(), mode)
        // Wall-clock progress is legitimate; do not freeze the pre-EOF persisted position.
        let persistedPosition = store.double(forKey: "MusicPlayback.lastPositionSeconds")
        XCTAssertTrue(persistedPosition.isFinite && (0...2.1).contains(persistedPosition))

        // Explicit selection on the same manager/player must recover, with no pause/reset.
        manager.play(tracks[1])
        let recoveredItem = try XCTUnwrap(player.currentItem)
        items.append(recoveredItem)
        readers.add(recoveredItem)
        readers.add(recoveredItem.asset)
        XCTAssertFalse(recoveredItem === item, "Explicit selection must install the replacement item")
        // Player-level .playing can outlive the exhausted item. First wait for
        // this replacement's readiness, then require real forward transport.
        let recoveryReady = expectation(description: "Replacement WAV becomes ready after explicit selection")
        let recoveryReadyObservation = recoveredItem.publisher(for: \.status, options: [.initial, .new])
            .filter { $0 == .readyToPlay }.prefix(1).sink { _ in recoveryReady.fulfill() }
        defer { recoveryReadyObservation.cancel() }
        guard await XCTWaiter.fulfillment(of: [recoveryReady], timeout: 5) == .completed else {
            XCTFail("Replacement readiness timed out; not a contract RED. status=\(recoveredItem.status.rawValue), error=\(String(describing: recoveredItem.error))")
            return
        }
        let recoveryStart = recoveredItem.currentTime().seconds
        guard player.currentItem === recoveredItem, recoveryStart.isFinite else {
            XCTFail("Replacement must remain current with a finite timeline before transport verification")
            return
        }
        let recoveryBoundary = CMTime(seconds: recoveryStart + 0.25, preferredTimescale: 600)
        let recoveryAdvanced = expectation(description: "Ready replacement advances across a future boundary")
        let recoveryBoundaryToken = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: recoveryBoundary)], queue: .main
        ) { recoveryAdvanced.fulfill() }
        defer { player.removeTimeObserver(recoveryBoundaryToken) }
        let recovered = expectation(description: "Explicit selection actually plays after activation recovers")
        let recoveryObservation = player.publisher(for: \.timeControlStatus, options: [.initial, .new])
            .filter { $0 == .playing }.prefix(1).sink { _ in recovered.fulfill() }
        defer { recoveryObservation.cancel() }
        guard await XCTWaiter.fulfillment(of: [recovered, recoveryAdvanced], timeout: 5) == .completed else {
            XCTFail("Replacement transport timed out; not a contract RED. status=\(recoveredItem.status.rawValue), time=\(recoveredItem.currentTime().seconds), boundary=\(recoveryBoundary.seconds), transport=\(player.timeControlStatus.rawValue), error=\(String(describing: recoveredItem.error))")
            return
        }
        XCTAssertTrue(player.currentItem === recoveredItem)
        XCTAssertEqual(player.timeControlStatus, .playing)
        XCTAssertGreaterThanOrEqual(recoveredItem.currentTime().seconds, recoveryBoundary.seconds)
        XCTAssertEqual(activationCount, 3)
        XCTAssertEqual(injectedFailureCount, 1)
        XCTAssertEqual(recoveredItem.status, .readyToPlay)
        XCTAssertNil(recoveredItem.error)
        XCTAssertEqual((recoveredItem.asset as? AVURLAsset)?.url, secondURL)
        XCTAssertTrue(manager.isPlaying)
        XCTAssertGreaterThan(player.rate, 0)
        XCTAssertEqual(controller.snapshots.last?.playbackRate, 1)
        XCTAssertNil(manager.playbackErrorMessage)
        XCTAssertEqual(manager.currentTrack, tracks[1])
        XCTAssertEqual(manager.currentIndex, 1)
        XCTAssertEqual(manager.queue, tracks)
        XCTAssertEqual(manager.queueScope, .playlist(playlistID))
        XCTAssertEqual(store.string(forKey: "MusicPlayback.lastTrackFileName"), tracks[1].fileName)
        XCTAssertEqual(try [firstURL, secondURL].map { try Data(contentsOf: $0) }, originalBytes)
    }

    func testManualAndRemoteSkipsWrapRegardlessOfCompletionMode() throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let controller = RecordingNowPlayingController()
        let manager = MusicPlaybackManager(defaults: store, activateAudioSession: {}, nowPlayingController: controller)
        let tracks = [MusicItem(url: URL(fileURLWithPath: "/tmp/A.mp3"), duration: 30), MusicItem(url: URL(fileURLWithPath: "/tmp/B.mp3"), duration: 40)]
        manager.updateQueue(tracks); manager.setCompletionMode(.stopAtEnd); manager.play(tracks[1])
        manager.next(); XCTAssertEqual(manager.currentTrack, tracks[0])
        manager.previous(); XCTAssertEqual(manager.currentTrack, tracks[1])
        XCTAssertEqual(controller.send(.nextTrack), .success); XCTAssertEqual(manager.currentTrack, tracks[0])
        XCTAssertEqual(controller.send(.previousTrack), .success); XCTAssertEqual(manager.currentTrack, tracks[1])
    }

    func testBluetoothLyricsAlwaysEnabledIncludingPersistedFalse() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "MusicPlayback.bluetoothCarLyricsEnabled")
        let controller = RecordingNowPlayingController()
        let manager = MusicPlaybackManager(defaults: defaults, nowPlayingController: controller,
                                           isBluetoothA2DPRoute: { true })
        let payload = Data([0x00, 0x65, 0x6E, 0x67, 0x02, 0x01, 0x00,
                            0x43, 0x75, 0x65, 0x00, 0, 0, 0, 0])
        let metadata = MusicMetadata(title: "Original", artist: "Artist", album: "Album",
                                     artworkData: nil, lyrics: nil, synchronizedLyricsData: payload)
        let track = MusicItem(url: URL(fileURLWithPath: "/tmp/song.mp3"), duration: 60, metadata: metadata)
        manager.updateQueue([track])
        manager.play(track)
        XCTAssertTrue(manager.isBluetoothCarLyricsEnabled)
        XCTAssertEqual(controller.snapshots.last?.title, "Cue")
        XCTAssertEqual(controller.snapshots.last?.artist, "Original · Artist")
        XCTAssertEqual(controller.snapshots.last?.album, "Album")
        let restored = MusicPlaybackManager(defaults: defaults, nowPlayingController: RecordingNowPlayingController())
        XCTAssertTrue(restored.isBluetoothCarLyricsEnabled)
        XCTAssertEqual(defaults.object(forKey: "MusicPlayback.bluetoothCarLyricsEnabled") as? Bool, false)
    }

    func testManagerRoutePredicateGatesLyricTitle() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = RecordingNowPlayingController()
        let manager = MusicPlaybackManager(
            defaults: defaults,
            nowPlayingController: controller,
            isBluetoothA2DPRoute: { false }
        )
        let payload = Data([0x00, 0x65, 0x6E, 0x67, 0x02, 0x01, 0x00,
                            0x43, 0x75, 0x65, 0x00, 0, 0, 0, 0])
        let metadata = MusicMetadata(title: "Original", artist: nil, album: nil,
                                     artworkData: nil, lyrics: nil, synchronizedLyricsData: payload)
        let track = MusicItem(url: URL(fileURLWithPath: "/tmp/song.mp3"), duration: 60, metadata: metadata)
        manager.updateQueue([track])
        manager.play(track)

        XCTAssertEqual(controller.snapshots.last?.title, "Original")
    }

    func testRouteChangeRepublishesAndRestoresOriginalTitle() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        var isA2DP = true
        let controller = RecordingNowPlayingController()
        let manager = MusicPlaybackManager(defaults: defaults, nowPlayingController: controller,
                                           isBluetoothA2DPRoute: { isA2DP })
        let payload = Data([0x00, 0x65, 0x6E, 0x67, 0x02, 0x01, 0x00,
                            0x43, 0x75, 0x65, 0x00, 0, 0, 0, 0])
        let metadata = MusicMetadata(title: "Original", artist: nil, album: nil,
                                     artworkData: nil, lyrics: nil, synchronizedLyricsData: payload)
        let track = MusicItem(url: URL(fileURLWithPath: "/tmp/song.mp3"), duration: 60, metadata: metadata)
        manager.updateQueue([track]); manager.play(track)
        XCTAssertEqual(controller.snapshots.last?.title, "Cue")
        let count = controller.snapshots.count

        isA2DP = false
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(), userInfo: [AVAudioSessionRouteChangeReasonKey:
                AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue])
        await Task.yield()

        XCTAssertGreaterThan(controller.snapshots.count, count)
        XCTAssertEqual(controller.snapshots.last?.title, "Original")
    }

    func testRouteChangeDoesNotReclaimNowPlayingFromActiveVideo() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = MPNowPlayingSession(players: [AVPlayer()])
        let center = session.nowPlayingInfoCenter
        defer { center.nowPlayingInfo = nil; center.playbackState = .stopped }
        var profiles: [NowPlayingCommandProfile?] = []
        var dispatcher: (@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)?
        let registry = MusicNowPlayingRegistry(commandProfileSetter: { profiles.append($0) })
        let musicController = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { handler in dispatcher = handler; return [] },
            sharedRegistryForTesting: registry
        )
        let videoController = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { _ in [] },
            sharedRegistryForTesting: registry
        )
        let ownership = PlaybackOwnershipCoordinator()
        let manager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: defaults,
            ownership: ownership,
            activateAudioSession: {},
            nowPlayingController: musicController
        )
        let song = MusicItem(url: URL(fileURLWithPath: "/tmp/Loaded Song.mp3"), duration: 30)
        manager.updateQueue([song])
        manager.play(song)
        let videoIntent = ownership.videoPlaybackRequested { manager.pause() }
        var videoCommandCount = 0
        videoController.registerVideoRemoteCommands { _ in
            videoCommandCount += 1
            return .success
        }
        videoController.publish(
            NowPlayingSnapshot(title: "Active Video", duration: 60, elapsedTime: 12, playbackRate: 1)
        )

        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey:
                AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue]
        )
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Active Video")
        XCTAssertEqual(profiles.last, .video)
        XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent))
        XCTAssertEqual(dispatcher?(.pause), .success)
        XCTAssertEqual(videoCommandCount, 1)
    }

    func testOldDeviceUnavailableRouteChangeStillPausesActiveMusic() async throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = RecordingNowPlayingController()
        let manager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: defaults,
            activateAudioSession: {},
            nowPlayingController: controller
        )
        let song = MusicItem(url: URL(fileURLWithPath: "/tmp/Active Song.mp3"), duration: 30)
        manager.updateQueue([song])
        manager.play(song)

        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey:
                AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        )
        await Task.yield()
        await Task.yield()

        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(controller.snapshots.last?.playbackRate, 0)
    }

    func testEnabledBluetoothLyricsWithoutSynchronizedCueKeepsOriginalMetadata() throws {
        let (defaults, suite) = try defaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = RecordingNowPlayingController()
        let manager = MusicPlaybackManager(defaults: defaults, nowPlayingController: controller,
                                           isBluetoothA2DPRoute: { true })
        let metadata = MusicMetadata(title: "Original", artist: "Artist", album: "Album",
                                     artworkData: nil, lyrics: nil, synchronizedLyricsData: nil)
        let track = MusicItem(url: URL(fileURLWithPath: "/tmp/song.mp3"), duration: 60, metadata: metadata)
        manager.updateQueue([track]); manager.play(track)
        XCTAssertTrue(manager.isBluetoothCarLyricsEnabled)
        XCTAssertEqual(controller.snapshots.last?.title, "Original")
        XCTAssertEqual(controller.snapshots.last?.artist, "Artist")
        XCTAssertEqual(controller.snapshots.last?.album, "Album")
    }

    @MainActor
    func testVideoNowPlayingSessionPublishesCurrentVideoStateAndClears() {
        let controller = RecordingVideoNowPlayingController()
        let session = VideoNowPlayingSession(controller: controller)
        let video = VideoItem(
            url: URL(fileURLWithPath: "/tmp/Session Movie.mp4"),
            duration: 60
        )

        session.activate(video: video)

        XCTAssertEqual(controller.snapshots.first?.title, "Session Movie")
        XCTAssertEqual(controller.snapshots.first?.duration, 60)
        XCTAssertEqual(controller.snapshots.first?.elapsedTime, 0)
        XCTAssertEqual(controller.snapshots.first?.playbackRate, 0)

        session.update(duration: 60, currentTime: 12, isPlaying: true)

        XCTAssertEqual(controller.snapshots.last?.title, "Session Movie")
        XCTAssertEqual(controller.snapshots.last?.duration, 60)
        XCTAssertEqual(controller.snapshots.last?.elapsedTime, 12)
        XCTAssertEqual(controller.snapshots.last?.playbackRate, 1)
        XCTAssertEqual(controller.clearCount, 0)

        session.clear()

        XCTAssertEqual(controller.clearCount, 1)
    }

    @MainActor
    func testVideoNowPlayingSessionCarriesSelectedRateThroughUpdates() throws {
        let controller = RecordingVideoNowPlayingController()
        let session = VideoNowPlayingSession(controller: controller)
        let video = VideoItem(
            url: URL(fileURLWithPath: "/tmp/Selected Rate Movie.mp4"),
            duration: 60
        )

        session.activate(video: video)
        session.update(duration: 60, currentTime: 12, isPlaying: true, playbackRate: 1.5)

        XCTAssertEqual(try XCTUnwrap(controller.snapshots.last).playbackRate, 1.5, accuracy: 1e-9)

        session.update(duration: 60, currentTime: 12, isPlaying: false, playbackRate: 1.5)

        XCTAssertEqual(try XCTUnwrap(controller.snapshots.last).playbackRate, 0, accuracy: 1e-9)
    }

    @MainActor
    func testVideoNowPlayingSessionRoutesRemoteCommandUsingLatestState() {
        let controller = RecordingVideoNowPlayingController()
        let session = VideoNowPlayingSession(controller: controller)
        let video = VideoItem(
            url: URL(fileURLWithPath: "/tmp/Remote Movie.mp4"),
            duration: 60
        )
        var actions: [VideoRemoteCommandAction] = []

        session.activate(video: video)
        session.update(duration: 60, currentTime: 10, isPlaying: true)
        session.registerRemoteCommands { action in
            actions.append(action)
            return true
        }

        XCTAssertEqual(controller.registrationCount, 1)
        XCTAssertEqual(controller.send(.skipForward), .success)
        XCTAssertEqual(actions, [.seek(25)])
    }

    @MainActor
    func testVideoNowPlayingSessionPublishesPausedSnapshotAfterAcceptedRemotePause() {
        let controller = RecordingVideoNowPlayingController()
        let session = VideoNowPlayingSession(controller: controller)
        let video = VideoItem(
            url: URL(fileURLWithPath: "/tmp/Pause Movie.mp4"),
            duration: 60
        )

        session.activate(video: video)
        session.update(duration: 60, currentTime: 10, isPlaying: true)
        session.registerRemoteCommands { _ in true }

        XCTAssertEqual(controller.send(.pause), .success)
        XCTAssertEqual(controller.snapshots.last?.title, "Pause Movie")
        XCTAssertEqual(controller.snapshots.last?.duration, 60)
        XCTAssertEqual(controller.snapshots.last?.elapsedTime, 10)
        XCTAssertEqual(controller.snapshots.last?.playbackRate, 0)
    }

    @MainActor
    func testProductionTargetRegistrarAddsVideoSkipTargetsWithFifteenSecondIntervals() {
        let commandCenter = MPRemoteCommandCenter.shared()
        let originalBackwardIntervals = commandCenter.skipBackwardCommand.preferredIntervals
        let originalForwardIntervals = commandCenter.skipForwardCommand.preferredIntervals
        var targetRemovals: [() -> Void] = []
        defer {
            targetRemovals.forEach { $0() }
            commandCenter.skipBackwardCommand.preferredIntervals = originalBackwardIntervals
            commandCenter.skipForwardCommand.preferredIntervals = originalForwardIntervals
        }

        targetRemovals = MediaPlayerMusicNowPlayingController.registerTargets { _ in .success }

        XCTAssertEqual(MediaPlayerMusicNowPlayingController.videoSkipInterval, 15)
        XCTAssertEqual(commandCenter.skipBackwardCommand.preferredIntervals, [NSNumber(value: 15)])
        XCTAssertEqual(commandCenter.skipForwardCommand.preferredIntervals, [NSNumber(value: 15)])
        XCTAssertEqual(targetRemovals.count, 8)
    }

    @MainActor
    func testProductionCommandProfileEnablesOnlyCommandsForActiveMediaKind() {
        let commandCenter = MPRemoteCommandCenter.shared()
        let commands: [MPRemoteCommand] = [
            commandCenter.playCommand,
            commandCenter.pauseCommand,
            commandCenter.togglePlayPauseCommand,
            commandCenter.nextTrackCommand,
            commandCenter.previousTrackCommand,
            commandCenter.changePlaybackPositionCommand,
            commandCenter.skipBackwardCommand,
            commandCenter.skipForwardCommand,
        ]
        let originalEnabledValues = commands.map(\.isEnabled)
        defer {
            for (command, isEnabled) in zip(commands, originalEnabledValues) {
                command.isEnabled = isEnabled
            }
        }

        MediaPlayerMusicNowPlayingController.applyCommandProfile(.music)
        XCTAssertTrue(commandCenter.playCommand.isEnabled)
        XCTAssertTrue(commandCenter.pauseCommand.isEnabled)
        XCTAssertTrue(commandCenter.togglePlayPauseCommand.isEnabled)
        XCTAssertTrue(commandCenter.nextTrackCommand.isEnabled)
        XCTAssertTrue(commandCenter.previousTrackCommand.isEnabled)
        XCTAssertTrue(commandCenter.changePlaybackPositionCommand.isEnabled)
        XCTAssertFalse(commandCenter.skipBackwardCommand.isEnabled)
        XCTAssertFalse(commandCenter.skipForwardCommand.isEnabled)

        MediaPlayerMusicNowPlayingController.applyCommandProfile(.video)
        XCTAssertTrue(commandCenter.playCommand.isEnabled)
        XCTAssertTrue(commandCenter.pauseCommand.isEnabled)
        XCTAssertTrue(commandCenter.togglePlayPauseCommand.isEnabled)
        XCTAssertFalse(commandCenter.nextTrackCommand.isEnabled)
        XCTAssertFalse(commandCenter.previousTrackCommand.isEnabled)
        XCTAssertTrue(commandCenter.changePlaybackPositionCommand.isEnabled)
        XCTAssertTrue(commandCenter.skipBackwardCommand.isEnabled)
        XCTAssertTrue(commandCenter.skipForwardCommand.isEnabled)

        MediaPlayerMusicNowPlayingController.applyCommandProfile(nil)
        XCTAssertFalse(commandCenter.playCommand.isEnabled)
        XCTAssertFalse(commandCenter.pauseCommand.isEnabled)
        XCTAssertFalse(commandCenter.togglePlayPauseCommand.isEnabled)
        XCTAssertFalse(commandCenter.nextTrackCommand.isEnabled)
        XCTAssertFalse(commandCenter.previousTrackCommand.isEnabled)
        XCTAssertFalse(commandCenter.changePlaybackPositionCommand.isEnabled)
        XCTAssertFalse(commandCenter.skipBackwardCommand.isEnabled)
        XCTAssertFalse(commandCenter.skipForwardCommand.isEnabled)
    }

    func testConcreteControllerPublishesValidEmbeddedArtwork() throws {
        let session = MPNowPlayingSession(players: [AVPlayer()])
        let center = session.nowPlayingInfoCenter
        defer {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }

        let artworkData = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let metadata = MusicMetadata(
            title: "Embedded Artwork",
            artist: nil,
            album: nil,
            artworkData: artworkData,
            lyrics: nil,
            synchronizedLyricsData: nil
        )
        let item = MusicItem(
            url: URL(fileURLWithPath: "/tmp/Embedded Artwork.mp3"),
            duration: 30,
            metadata: metadata
        )
        let snapshot = try XCTUnwrap(
            NowPlayingSnapshot.make(track: item, duration: 30, elapsedTime: 5, isPlaying: true)
        )
        let controller = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { _ in [] },
            sharedRegistryForTesting: MusicNowPlayingRegistry()
        )

        controller.publish(snapshot)

        let artwork = center.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        XCTAssertNotNil(artwork)
        XCTAssertNotNil(artwork?.image(at: CGSize(width: 64, height: 64)))
    }

    func testConcreteControllerPublishesNonEmptyArtistAndAlbum() {
        let session = MPNowPlayingSession(players: [AVPlayer()])
        let center = session.nowPlayingInfoCenter
        defer { center.nowPlayingInfo = nil; center.playbackState = .stopped }
        let controller = MediaPlayerMusicNowPlayingController(
            testingCenter: center, registerTargets: { _ in [] },
            sharedRegistryForTesting: MusicNowPlayingRegistry()
        )

        controller.publish(NowPlayingSnapshot(title: "Title", duration: 30, elapsedTime: 1,
            playbackRate: 1, artist: "Artist", album: "Album"))

        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyArtist] as? String, "Artist")
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyAlbumTitle] as? String, "Album")
    }

    @MainActor
    func testConcreteControllerReusesArtworkAcrossProgressPublications() throws {
        let session = MPNowPlayingSession(players: [AVPlayer()])
        let center = session.nowPlayingInfoCenter
        defer {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }

        let artworkData = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="))
        let metadata = MusicMetadata(
            title: "Progress Artwork",
            artist: nil,
            album: nil,
            artworkData: artworkData,
            lyrics: nil,
            synchronizedLyricsData: nil
        )
        let item = MusicItem(
            url: URL(fileURLWithPath: "/tmp/Progress Artwork.mp3"),
            duration: 30,
            metadata: metadata
        )
        let firstSnapshot = try XCTUnwrap(
            NowPlayingSnapshot.make(track: item, duration: 30, elapsedTime: 5, isPlaying: true)
        )
        let secondSnapshot = try XCTUnwrap(
            NowPlayingSnapshot.make(track: item, duration: 30, elapsedTime: 6, isPlaying: true)
        )
        let controller = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { _ in [] },
            sharedRegistryForTesting: MusicNowPlayingRegistry()
        )

        controller.publish(firstSnapshot)
        let firstArtwork = try XCTUnwrap(
            center.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        )

        controller.publish(secondSnapshot)
        let secondArtwork = try XCTUnwrap(
            center.nowPlayingInfo?[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        )

        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 6)
        XCTAssertTrue(firstArtwork === secondArtwork)
    }

    func testConcreteControllerRegistersTargetsOnceAndGlobalTargetsOutliveController() async {
        var registrationCount = 0
        var unregisterCount = 0
        let coordinator = MusicNowPlayingCoordinator(
            testingCenter: .default(),
            registerTargets: { (_: @MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult) in
                registrationCount += 1
                return [{ unregisterCount += 1 }]
            }
        )
        var controller: MediaPlayerMusicNowPlayingController? = MediaPlayerMusicNowPlayingController(coordinator: coordinator)

        controller?.registerRemoteCommands { _ in .success }
        controller?.registerRemoteCommands { _ in .success }
        XCTAssertEqual(registrationCount, 1)

        controller = nil
        await Task.yield()

        XCTAssertEqual(unregisterCount, 0)
    }

    func testConcreteControllerClearsOnlyMetadataItStillOwnsOnDeallocation() async {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        defer {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }

        let coordinator = MusicNowPlayingCoordinator(testingCenter: center, registerTargets: { _ in [] })
        var older: MediaPlayerMusicNowPlayingController? = MediaPlayerMusicNowPlayingController(coordinator: coordinator)
        older?.publish(NowPlayingSnapshot(title: "Older", duration: 30, elapsedTime: 5, playbackRate: 1))

        var newer: MediaPlayerMusicNowPlayingController? = MediaPlayerMusicNowPlayingController(coordinator: coordinator)
        newer?.publish(NowPlayingSnapshot(title: "Newer", duration: 40, elapsedTime: 7, playbackRate: 1))

        older = nil
        await Task.yield()
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Newer")
        XCTAssertEqual(center.playbackState, .playing)

        newer = nil
        await Task.yield()
        XCTAssertNil(center.nowPlayingInfo)
        XCTAssertEqual(center.playbackState, .stopped)
    }

    func testNonOwnerExplicitClearCannotEraseNewerMetadata() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        defer {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }

        let coordinator = MusicNowPlayingCoordinator(testingCenter: center, registerTargets: { _ in [] })
        let older = MediaPlayerMusicNowPlayingController(coordinator: coordinator)
        let newer = MediaPlayerMusicNowPlayingController(coordinator: coordinator)
        older.publish(NowPlayingSnapshot(title: "Older", duration: 30, elapsedTime: 5, playbackRate: 1))
        newer.publish(NowPlayingSnapshot(title: "Newer", duration: 40, elapsedTime: 7, playbackRate: 1))

        older.clear()

        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Newer")
        XCTAssertEqual(center.playbackState, .playing)
    }

    func testNeverOwningControllerCannotClearExternallyInjectedMetadata() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        defer {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }

        let coordinator = MusicNowPlayingCoordinator(testingCenter: center, registerTargets: { _ in [] })
        center.nowPlayingInfo = [MPMediaItemPropertyTitle: "External"]
        center.playbackState = .playing
        let controller = MediaPlayerMusicNowPlayingController(coordinator: coordinator)

        controller.clear()

        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "External")
        XCTAssertEqual(center.playbackState, .playing)
    }

    func testExplicitClearPreservesExternallyReplacedPublishedMetadata() {
        let session = MPNowPlayingSession(players: [AVPlayer()])
        let center = session.nowPlayingInfoCenter
        let registry = MusicNowPlayingRegistry()
        let controller = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { _ in [] },
            sharedRegistryForTesting: registry
        )
        controller.publish(NowPlayingSnapshot(title: "Owned", duration: 30, elapsedTime: 5, playbackRate: 1))
        center.nowPlayingInfo = [MPMediaItemPropertyTitle: "External"]
        center.playbackState = .playing

        controller.clear()

        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "External")
        XCTAssertEqual(center.playbackState, .playing)
    }

    func testControllerDeallocationPreservesExternallyReplacedPublishedMetadata() async {
        let session = MPNowPlayingSession(players: [AVPlayer()])
        let center = session.nowPlayingInfoCenter
        let registry = MusicNowPlayingRegistry()
        var controller: MediaPlayerMusicNowPlayingController? = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { _ in [] },
            sharedRegistryForTesting: registry
        )
        controller?.publish(NowPlayingSnapshot(title: "Owned", duration: 30, elapsedTime: 5, playbackRate: 1))
        center.nowPlayingInfo = [MPMediaItemPropertyTitle: "External"]
        center.playbackState = .playing

        controller = nil
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "External")
        XCTAssertEqual(center.playbackState, .playing)
    }

    func testIndependentlyInitializedControllersSharingProcessRegistryInstallOneTargetSetAndRouteToCurrentPublisher() {
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        defer {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }

        var dispatchers: [(@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)] = []
        var olderCommands = 0
        var newerCommands = 0
        let registerTargets: MusicNowPlayingCoordinator.TargetRegistrar = { dispatcher in
            dispatchers.append(dispatcher)
            return []
        }
        let registry = MusicNowPlayingRegistry()
        let older = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: registerTargets,
            sharedRegistryForTesting: registry
        )
        let newer = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: registerTargets,
            sharedRegistryForTesting: registry
        )
        older.registerRemoteCommands { _ in olderCommands += 1; return .success }
        newer.registerRemoteCommands { _ in newerCommands += 1; return .success }
        older.publish(NowPlayingSnapshot(title: "Older", duration: 30, elapsedTime: 5, playbackRate: 1))
        newer.publish(NowPlayingSnapshot(title: "Newer", duration: 40, elapsedTime: 7, playbackRate: 1))

        let result = dispatchers.first?(.pause)

        XCTAssertEqual(dispatchers.count, 1)
        XCTAssertEqual(result, .success)
        XCTAssertEqual(olderCommands, 0)
        XCTAssertEqual(newerCommands, 1)
    }

    @MainActor
    func testExternalNowPlayingResetReinstallsTargetsAndRestoresActiveVideoPublication() {
        let session = MPNowPlayingSession(players: [AVPlayer()])
        let center = session.nowPlayingInfoCenter
        defer {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }

        var profiles: [NowPlayingCommandProfile?] = []
        var dispatchers: [(@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)] = []
        var removalCount = 0
        var commandCount = 0
        let registry = MusicNowPlayingRegistry(commandProfileSetter: { profiles.append($0) })
        let controller = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { dispatcher in
                dispatchers.append(dispatcher)
                return [{ removalCount += 1 }]
            },
            sharedRegistryForTesting: registry
        )
        controller.registerVideoRemoteCommands { _ in
            commandCount += 1
            return .success
        }
        controller.publish(
            NowPlayingSnapshot(
                title: "Recovery Movie",
                duration: 60,
                elapsedTime: 12,
                playbackRate: 1
            )
        )

        XCTAssertEqual(dispatchers.count, 1)
        XCTAssertEqual(profiles.last, .video)

        center.nowPlayingInfo = nil
        center.playbackState = .stopped
        registry.restoreAfterExternalNowPlayingReset()

        XCTAssertEqual(dispatchers.count, 2)
        XCTAssertEqual(removalCount, 1)
        XCTAssertEqual(profiles.last, .video)
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Recovery Movie")
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyPlaybackDuration] as? Double, 60)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 12)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        XCTAssertEqual(center.playbackState, .playing)
        XCTAssertEqual(dispatchers.last?(.pause), .success)
        XCTAssertEqual(commandCount, 1)
    }

    @MainActor
    func testCommandProfileFollowsActualNowPlayingOwnerAndIgnoresNonOwnerClear() throws {
        let session = MPNowPlayingSession(players: [AVPlayer()])
        let center = session.nowPlayingInfoCenter
        defer {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
        }

        var profiles: [NowPlayingCommandProfile?] = []
        let registry = MusicNowPlayingRegistry(commandProfileSetter: { profiles.append($0) })
        let music = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { _ in [] },
            sharedRegistryForTesting: registry
        )
        let video = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { _ in [] },
            sharedRegistryForTesting: registry
        )
        music.registerRemoteCommands { _ in .success }
        video.registerVideoRemoteCommands { _ in .success }

        let musicSnapshot = try XCTUnwrap(
            NowPlayingSnapshot.make(
                track: MusicItem(url: URL(fileURLWithPath: "/tmp/Command Profile Song.mp3"), duration: 30),
                duration: 30,
                elapsedTime: 5,
                isPlaying: true
            )
        )
        let videoSnapshot = try XCTUnwrap(
            NowPlayingSnapshot.make(
                video: VideoItem(url: URL(fileURLWithPath: "/tmp/Command Profile Movie.mp4"), duration: 40),
                duration: 40,
                elapsedTime: 7,
                isPlaying: true
            )
        )

        music.publish(musicSnapshot)
        XCTAssertEqual(profiles.last, .music)
        video.publish(videoSnapshot)
        XCTAssertEqual(profiles.last, .video)
        music.publish(musicSnapshot)
        XCTAssertEqual(profiles.last, .music)

        let profilesBeforeNonOwnerClear = profiles
        video.clear()
        XCTAssertEqual(profiles, profilesBeforeNonOwnerClear)

        music.clear()
        let expectedProfiles: [NowPlayingCommandProfile?] = [.music, .video, .music, nil]
        XCTAssertEqual(profiles, expectedProfiles)
    }

    func testReleasingNewestOwnerFallsBackToOlderPublishedOwnerAcrossDistinctCenters() async {
        let olderSession = MPNowPlayingSession(players: [AVPlayer()])
        let newerSession = MPNowPlayingSession(players: [AVPlayer()])
        let olderCenter = olderSession.nowPlayingInfoCenter
        let newerCenter = newerSession.nowPlayingInfoCenter
        var dispatchers: [(@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)] = []
        var olderCommands = 0
        var newerCommands = 0
        let registerTargets: MusicNowPlayingCoordinator.TargetRegistrar = { dispatcher in
            dispatchers.append(dispatcher)
            return []
        }
        let registry = MusicNowPlayingRegistry()
        let older = MediaPlayerMusicNowPlayingController(
            testingCenter: olderCenter,
            registerTargets: registerTargets,
            sharedRegistryForTesting: registry
        )
        var newer: MediaPlayerMusicNowPlayingController? = MediaPlayerMusicNowPlayingController(
            testingCenter: newerCenter,
            registerTargets: registerTargets,
            sharedRegistryForTesting: registry
        )
        older.registerRemoteCommands { _ in olderCommands += 1; return .success }
        older.publish(NowPlayingSnapshot(title: "Older", duration: 30, elapsedTime: 5, playbackRate: 1))
        newer?.registerRemoteCommands { _ in newerCommands += 1; return .success }
        newer?.publish(NowPlayingSnapshot(title: "Newer", duration: 40, elapsedTime: 7, playbackRate: 1))

        XCTAssertEqual(dispatchers.count, 1)
        XCTAssertEqual(dispatchers.first?(.pause), .success)
        XCTAssertEqual(olderCommands, 0)
        XCTAssertEqual(newerCommands, 1)

        newer = nil
        await Task.yield()
        await Task.yield()

        XCTAssertNil(newerCenter.nowPlayingInfo)
        XCTAssertEqual(newerCenter.playbackState, .stopped)
        XCTAssertEqual(olderCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Older")
        XCTAssertEqual(olderCenter.playbackState, .playing)
        XCTAssertEqual(dispatchers.first?(.pause), .success)
        XCTAssertEqual(olderCommands, 1)
        XCTAssertEqual(newerCommands, 1)
    }

    func testOneOwnerCannotPublishAcrossDistinctCenters() {
        let registry = MusicNowPlayingRegistry()
        let firstSession = MPNowPlayingSession(players: [AVPlayer()])
        let secondSession = MPNowPlayingSession(players: [AVPlayer()])
        let firstCenter = firstSession.nowPlayingInfoCenter
        let secondCenter = secondSession.nowPlayingInfoCenter
        let ownerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        firstCenter.nowPlayingInfo = nil
        firstCenter.playbackState = .stopped
        secondCenter.nowPlayingInfo = nil
        secondCenter.playbackState = .stopped
        defer {
            firstCenter.nowPlayingInfo = nil
            firstCenter.playbackState = .stopped
            secondCenter.nowPlayingInfo = nil
            secondCenter.playbackState = .stopped
        }

        registry.publish(
            NowPlayingSnapshot(title: "First", duration: 30, elapsedTime: 5, playbackRate: 1),
            ownerID: ownerID,
            center: firstCenter
        )
        registry.publish(
            NowPlayingSnapshot(title: "Second", duration: 40, elapsedTime: 7, playbackRate: 1),
            ownerID: ownerID,
            center: secondCenter
        )

        XCTAssertEqual(firstCenter.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "First")
        XCTAssertEqual(firstCenter.playbackState, .playing)
        XCTAssertNil(secondCenter.nowPlayingInfo)
        XCTAssertEqual(secondCenter.playbackState, .stopped)
    }

    func testTwoControllersInstallOneGlobalTargetSetAndRouteOnlyToCurrentOwner() {
        var dispatchers: [(@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)] = []
        var olderCommands = 0
        var newerCommands = 0
        let registerTargets: @MainActor (
            @escaping @MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult
        ) -> [() -> Void] = { dispatcher in
            dispatchers.append(dispatcher)
            return []
        }
        let coordinator = MusicNowPlayingCoordinator(testingCenter: .default(), registerTargets: registerTargets)
        let older = MediaPlayerMusicNowPlayingController(coordinator: coordinator)
        let newer = MediaPlayerMusicNowPlayingController(coordinator: coordinator)
        older.registerRemoteCommands { _ in olderCommands += 1; return .success }
        newer.registerRemoteCommands { _ in newerCommands += 1; return .success }
        older.publish(NowPlayingSnapshot(title: "Older", duration: 30, elapsedTime: 5, playbackRate: 1))
        newer.publish(NowPlayingSnapshot(title: "Newer", duration: 40, elapsedTime: 7, playbackRate: 1))

        let results = dispatchers.map { $0(.pause) }

        XCTAssertEqual(dispatchers.count, 1)
        XCTAssertEqual(results, [.success])
        XCTAssertEqual(olderCommands, 0)
        XCTAssertEqual(newerCommands, 1)
    }

    func testDeallocatedControllerHandlerCannotBeInvokedByStaleGlobalDispatcher() async {
        var dispatcher: (@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)?
        var invocationCount = 0
        let coordinator = MusicNowPlayingCoordinator(
            testingCenter: .default(),
            registerTargets: { registeredDispatcher in
                dispatcher = registeredDispatcher
                return []
            }
        )
        var controller: MediaPlayerMusicNowPlayingController? = MediaPlayerMusicNowPlayingController(coordinator: coordinator)
        controller?.registerRemoteCommands { _ in invocationCount += 1; return .success }
        controller?.publish(NowPlayingSnapshot(title: "Owner", duration: 30, elapsedTime: 5, playbackRate: 1))

        controller = nil
        await Task.yield()
        let result = dispatcher?(.pause)

        XCTAssertEqual(result, .commandFailed)
        XCTAssertEqual(invocationCount, 0)
    }

    func testDeallocatedControllerHandlerCannotBeInvokedImmediatelyByStaleGlobalDispatcher() {
        var dispatcher: (@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)?
        var invocationCount = 0
        let registry = MusicNowPlayingRegistry()
        var controller: MediaPlayerMusicNowPlayingController? = MediaPlayerMusicNowPlayingController(
            testingCenter: .default(),
            registerTargets: { registeredDispatcher in
                dispatcher = registeredDispatcher
                return []
            },
            sharedRegistryForTesting: registry
        )
        controller?.registerRemoteCommands { _ in
            invocationCount += 1
            return .success
        }
        controller?.publish(NowPlayingSnapshot(title: "Owner", duration: 30, elapsedTime: 5, playbackRate: 1))

        controller = nil
        let result = dispatcher?(.pause)

        XCTAssertEqual(result, .commandFailed)
        XCTAssertEqual(invocationCount, 0)
    }

    func testRegistersOnceAndPublishesLoadPlayPauseFailureAndRestore() throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let controller = RecordingNowPlayingController()
        var failActivation = false
        let manager = MusicPlaybackManager(player: AVPlayer(), defaults: store, activateAudioSession: { if failActivation { throw TestFailure.activation } }, nowPlayingController: controller)
        let song = MusicItem(url: URL(fileURLWithPath: "/tmp/First Song.mp3"), duration: 80)
        manager.updateQueue([song]); manager.play(song); manager.pause()
        failActivation = true; manager.play()
        XCTAssertEqual(controller.registrationCount, 1)
        XCTAssertEqual(controller.snapshots.map(\.playbackRate), [0, 1, 0, 0])

        let (restoredStore, restoredSuite) = try defaults("restore"); defer { restoredStore.removePersistentDomain(forName: restoredSuite) }
        restoredStore.set("Restored.m4a", forKey: "MusicPlayback.lastTrackFileName")
        restoredStore.set(200.0, forKey: "MusicPlayback.lastPositionSeconds")
        let restoredController = RecordingNowPlayingController()
        let restored = MusicPlaybackManager(player: AVPlayer(), defaults: restoredStore, activateAudioSession: {}, nowPlayingController: restoredController)
        restored.updateQueue([MusicItem(url: URL(fileURLWithPath: "/tmp/Restored.m4a"), duration: 50)])
        XCTAssertEqual(restoredController.snapshots.last, NowPlayingSnapshot(title: "Restored", duration: 50, elapsedTime: 50, playbackRate: 0))
    }

    func testSeekPeriodicRefreshAndStaleCallbacksPublishOnlyCurrentGeneration() async throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let controller = RecordingNowPlayingController()
        let player = ManuallyDrivenPeriodicPlayer()
        player.isMuted = true
        let manager = MusicPlaybackManager(player: player, defaults: store, activateAudioSession: {}, nowPlayingController: controller)
        // These generations must remain healthy: missing media exercises failure
        // suppression instead of successful seek/periodic metadata publication.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeekPeriodic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            if let currentTrack = manager.currentTrack { manager.prepareForDeletion(currentTrack) }
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not remove seek/periodic fixtures: \(error)") }
        }
        let firstURL = root.appendingPathComponent("First.wav")
        let secondURL = root.appendingPathComponent("Second.wav")
        try writeRecoveryWAV(to: firstURL, duration: 100)
        try writeRecoveryWAV(to: secondURL, duration: 40)
        let first = MusicItem(url: firstURL, duration: 100)
        let second = MusicItem(url: secondURL, duration: 40)
        manager.updateQueue([first, second]); manager.play(first)
        let staleSeek = manager.seekCompletionCallback(to: 88)
        let stalePeriodic = try XCTUnwrap(player.periodicCallback)
        manager.next()
        XCTAssertTrue(manager.isPlaying)
        let currentPeriodic = try XCTUnwrap(player.periodicCallback)
        let countAfterSwitch = controller.snapshots.count
        staleSeek(true); stalePeriodic(CMTime(seconds: 77, preferredTimescale: 600))
        await Task.yield(); await Task.yield()
        XCTAssertEqual(controller.snapshots.count, countAfterSwitch)
        XCTAssertEqual(controller.snapshots.last?.title, "Second")
        manager.updateQueue([second, first])
        XCTAssertEqual(controller.snapshots.last?.title, "Second")
        manager.seekCompletionCallback(to: 40)(true); await Task.yield()
        XCTAssertEqual(controller.snapshots.last?.elapsedTime, 40)
        let countBeforeFailedSeek = controller.snapshots.count
        manager.seekCompletionCallback(to: 12)(false); await Task.yield()
        XCTAssertEqual(controller.snapshots.count, countBeforeFailedSeek)
        currentPeriodic(CMTime(seconds: 13, preferredTimescale: 600)); await Task.yield()
        XCTAssertEqual(controller.snapshots.last?.elapsedTime, 13)
        XCTAssertTrue(manager.isPlaying)
        XCTAssertNil(manager.playbackErrorMessage)
    }

    func testRepeatedPeriodicPulsesPublishOnlyNarrowTimeline() async throws {
        let (store, suite) = try defaults("timeline-pulses")
        defer { store.removePersistentDomain(forName: suite) }
        let manager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: store,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController()
        )
        let song = MusicItem(url: URL(fileURLWithPath: "/tmp/Timeline.mp3"), duration: 90)
        manager.updateQueue([song])
        manager.play(song)

        var broadInvalidations = 0
        var timelineUpdates: [TimeInterval] = []
        let broadObservation = manager.objectWillChange.sink { broadInvalidations += 1 }
        let timelineObservation = manager.timeline.$currentTime
            .dropFirst()
            .sink { timelineUpdates.append($0) }

        let callback = manager.periodicTimeCallback()
        for seconds in [0.5, 1.0, 1.5] {
            callback(CMTime(seconds: seconds, preferredTimescale: 600))
            await Task.yield()
        }

        broadObservation.cancel()
        timelineObservation.cancel()
        XCTAssertEqual(broadInvalidations, 0)
        XCTAssertEqual(timelineUpdates, [0.5, 1.0, 1.5])
        XCTAssertEqual(manager.currentTime, 1.5)
    }

    func testTimelineProjectionPublishesPlayingAndPausedPulsesOnlyWhileActive() async throws {
        let (store, suite) = try defaults("timeline-projection")
        defer { store.removePersistentDomain(forName: suite) }
        let manager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: store,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController()
        )
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Projection-\(UUID().uuidString).wav")
        defer {
            if let currentTrack = manager.currentTrack { manager.prepareForDeletion(currentTrack) }
            do { try FileManager.default.removeItem(at: fixtureURL) }
            catch { XCTFail("Could not remove timeline-projection fixture: \(error)") }
        }
        try writeRecoveryWAV(to: fixtureURL, duration: 90)
        let song = MusicItem(url: fixtureURL, duration: 90)
        manager.updateQueue([song])
        manager.play(song)
        let projection = MusicPlaybackTimelineProjection(timeline: manager.timeline)
        var updates: [TimeInterval] = []
        let observation = projection.$currentTime.dropFirst().sink { updates.append($0) }

        projection.setActive(true)
        for seconds in [1.0, 2.0] {
            manager.periodicTimeCallback()(CMTime(seconds: seconds, preferredTimescale: 600))
            await Task.yield()
        }
        XCTAssertEqual(updates, [1.0, 2.0])

        manager.pause()
        updates.removeAll()
        for seconds in [2.5, 3.0] {
            manager.periodicTimeCallback()(CMTime(seconds: seconds, preferredTimescale: 600))
            await Task.yield()
        }
        XCTAssertEqual(updates, [2.5, 3.0])

        projection.setActive(false)
        updates.removeAll()
        manager.periodicTimeCallback()(CMTime(seconds: 4, preferredTimescale: 600))
        await Task.yield()
        XCTAssertTrue(updates.isEmpty)

        projection.setActive(true)
        XCTAssertEqual(updates, [4], "Reactivation must catch up exactly once")
        updates.removeAll()
        let seekGeneration = manager.seekCompletionGeneration
        let seekProcessed = expectation(description: "Paused timeline-projection seek callback completed after actor hop")
        let seekObservation = manager.seekCompletionPublisher
            .filter { $0 > seekGeneration }.prefix(1).sink { _ in seekProcessed.fulfill() }
        defer { seekObservation.cancel() }
        manager.seekCompletionCallback(to: 5)(true)
        let seekResult = await XCTWaiter.fulfillment(of: [seekProcessed], timeout: 2)
        guard seekResult == .completed else {
            XCTFail("Paused timeline-projection seek callback did not complete within 2 s")
            throw AudioSessionNotificationError.processingTimedOut
        }
        XCTAssertEqual(updates, [5], "A paused seek must refresh the active consumer exactly once")
        observation.cancel()
    }

    func testRealPlaybackViewTopologyInvalidatesOnlyActiveTimelineConsumer() async throws {
        let (store, suite) = try defaults("timeline-view-topology")
        defer { store.removePersistentDomain(forName: suite) }
        let ownership = PlaybackOwnershipCoordinator()
        // Only injected observer pulses drive the measured timeline. The player
        // still loads/plays real media and reports item failures normally.
        let player = ManuallyDrivenPeriodicPlayer()
        player.isMuted = true
        let manager = MusicPlaybackManager(
            player: player,
            defaults: store,
            ownership: ownership,
            activateAudioSession: {},
            nowPlayingController: RecordingNowPlayingController()
        )
        // Normal playback requires decodable media now that item failures are observed.
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Topology-\(UUID().uuidString).wav")
        try writeRecoveryWAV(to: fixtureURL, duration: 90)
        let song = MusicItem(url: fixtureURL, duration: 90)
        defer {
            manager.prepareForDeletion(song)
            do { try FileManager.default.removeItem(at: fixtureURL) }
            catch { XCTFail("Could not remove normal-playback fixture: \(error)") }
        }
        manager.updateQueue([song])
        manager.play(song)
        XCTAssertTrue(manager.isPlaying)
        let periodic = try XCTUnwrap(player.periodicCallback)

        var rootInvalidations = 0
        var videoListInvalidations = 0
        var musicListInvalidations = 0
        var fullPlayerInvalidations = 0
        let fullPlayerTimeline = MusicPlaybackTimelineProjection(timeline: manager.timeline)
        let viewUpdateBarrier = ViewUpdateBarrier()
        func observedEvaluationCounts() -> [Int] {
            [
                rootInvalidations,
                videoListInvalidations,
                musicListInvalidations,
                fullPlayerInvalidations,
            ]
        }
        let rootHost = UIHostingController(rootView: RootTabView(
            ownership: ownership,
            playback: manager,
            bodyDidEvaluate: { rootInvalidations += 1 }
        ))
        let videoHost = UIHostingController(rootView: HomeView(
            playback: manager,
            ownership: ownership,
            isVideoDetailPresented: .constant(false),
            bodyDidEvaluate: { videoListInvalidations += 1 }
        ))
        let musicHost = UIHostingController(rootView: MusicHomeView(
            library: MusicLibrary(),
            playback: manager,
            favorites: MusicFavoritesStore(defaults: store),
            recentlyPlayed: MusicRecentlyPlayedStore(defaults: store),
            bodyDidEvaluate: { musicListInvalidations += 1 }
        ))
        let fullPlayerHost = UIHostingController(rootView: MusicPlayerView(
            playback: manager,
            favorites: MusicFavoritesStore(defaults: store),
            timelineProjection: fullPlayerTimeline,
            bodyDidEvaluate: { fullPlayerInvalidations += 1 }
        ))
        let barrierHost = UIHostingController(rootView: ViewUpdateBarrierProbe(barrier: viewUpdateBarrier))
        let container = UIViewController()
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = container
        for host: UIViewController in [rootHost, videoHost, musicHost, fullPlayerHost, barrierHost] {
            container.addChild(host)
            host.view.frame = container.view.bounds
            container.view.addSubview(host.view)
            host.didMove(toParent: container)
        }
        window.makeKeyAndVisible()
        container.view.layoutIfNeeded()
        await settleViewUpdates(using: viewUpdateBarrier, observedEvaluationCounts: observedEvaluationCounts, phase: "initial mount")
        rootInvalidations = 0
        videoListInvalidations = 0
        musicListInvalidations = 0
        fullPlayerInvalidations = 0

        for seconds in [2.0, 2.5, 3.0] {
            periodic(CMTime(seconds: seconds, preferredTimescale: 600))
            await settleViewUpdates(using: viewUpdateBarrier, observedEvaluationCounts: observedEvaluationCounts, phase: "active pulse")
        }

        XCTAssertEqual(rootInvalidations, 0)
        XCTAssertEqual(videoListInvalidations, 0)
        XCTAssertEqual(musicListInvalidations, 0)
        XCTAssertEqual(fullPlayerInvalidations, 3)

        XCTAssertTrue(manager.isPlaying)
        XCTAssertNil(manager.playbackErrorMessage)
        manager.pause()
        XCTAssertFalse(manager.isPlaying)
        await settleViewUpdates(using: viewUpdateBarrier, observedEvaluationCounts: observedEvaluationCounts, phase: "pause")
        rootInvalidations = 0
        videoListInvalidations = 0
        musicListInvalidations = 0
        fullPlayerInvalidations = 0
        for seconds in [3.25, 3.5] {
            periodic(CMTime(seconds: seconds, preferredTimescale: 600))
            await settleViewUpdates(using: viewUpdateBarrier, observedEvaluationCounts: observedEvaluationCounts, phase: "paused pulse")
        }
        manager.seekCompletionCallback(to: 4)(true)
        await settleViewUpdates(using: viewUpdateBarrier, observedEvaluationCounts: observedEvaluationCounts, phase: "seek")
        XCTAssertEqual(rootInvalidations, 0)
        XCTAssertEqual(videoListInvalidations, 0)
        XCTAssertEqual(musicListInvalidations, 0)
        XCTAssertEqual(
            fullPlayerInvalidations,
            3,
            "Two paused periodic pulses and one paused seek must each refresh live progress exactly once"
        )

        XCTAssertFalse(manager.isPlaying)
        fullPlayerTimeline.setActive(false)
        manager.play()
        XCTAssertTrue(manager.isPlaying)
        await settleViewUpdates(using: viewUpdateBarrier, observedEvaluationCounts: observedEvaluationCounts, phase: "resume")
        rootInvalidations = 0
        videoListInvalidations = 0
        musicListInvalidations = 0
        fullPlayerInvalidations = 0

        for seconds in [5.0, 5.5, 6.0] {
            periodic(CMTime(seconds: seconds, preferredTimescale: 600))
            await settleViewUpdates(using: viewUpdateBarrier, observedEvaluationCounts: observedEvaluationCounts, phase: "inactive pulse")
        }

        XCTAssertEqual(rootInvalidations, 0)
        XCTAssertEqual(videoListInvalidations, 0)
        XCTAssertEqual(musicListInvalidations, 0)
        XCTAssertEqual(fullPlayerInvalidations, 0, "The inactive full player must not receive timeline pulses")
        XCTAssertTrue(manager.isPlaying)
        XCTAssertNil(manager.playbackErrorMessage)
        window.isHidden = true
        withExtendedLifetime(rootHost) {}
        withExtendedLifetime(videoHost) {}
        withExtendedLifetime(musicHost) {}
        withExtendedLifetime(fullPlayerHost) {}
        withExtendedLifetime(barrierHost) {}
    }

    private func settleViewUpdates(
        using barrier: ViewUpdateBarrier,
        observedEvaluationCounts: () -> [Int],
        phase: String
    ) async {
        await crossViewUpdateBarrier(barrier)
        let settledCounts = observedEvaluationCounts()
        await crossViewUpdateBarrier(barrier)
        XCTAssertEqual(
            observedEvaluationCounts(),
            settledCounts,
            "[\(phase)] No observed playback view may evaluate after a later SwiftUI barrier has completed"
        )
    }

    private func crossViewUpdateBarrier(_ barrier: ViewUpdateBarrier) async {
        let evaluation = expectation(description: "SwiftUI evaluates the view-update barrier")
        barrier.advance(expectation: evaluation)
        await fulfillment(of: [evaluation], timeout: 1)
    }

    func testCorruptWAVFailureStopsPlaybackPublishesZeroRateAndAllowsExplicitValidTrackChange() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CorruptWAVRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        // Weak tracking is only a conservative fixture-deletion gate, not a leak test.
        let fixtureReaders = NSHashTable<AnyObject>.weakObjects()
        addTeardownBlock { @MainActor in
            // Run after the async test scope has released its locals. Suspending gives
            // AVFoundation's asynchronous teardown time to drain without blocking main.
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(2))
            while autoreleasepool(invoking: { fixtureReaders.allObjects.isEmpty }) == false {
                guard clock.now < deadline else {
                    // A retained framework object is not evidence of a product leak.
                    // Do not unlink fixtures while a possible reader is still alive.
                    print("AVFoundation cleanup still pending; preserving this test's fixtures at \(root.path)")
                    return
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not remove this test's fixtures: \(error)") }
        }
        let corruptURL = root.appendingPathComponent("invalid.wav")
        let validURL = root.appendingPathComponent("valid.wav")
        // Nonempty, deliberately invalid container bytes; never replace existing media.
        let corruptBytes = Data("Deliberately invalid WAV: no RIFF header or audio frames.".utf8)
        try corruptBytes.write(to: corruptURL, options: .withoutOverwriting)
        try writeRecoveryWAV(to: validURL)
        let validBytes = try Data(contentsOf: validURL)
        let validFrameCount = try autoreleasepool {
            let reader = try AVAudioFile(forReading: validURL)
            fixtureReaders.add(reader)
            return reader.length
        }
        guard validFrameCount > 0 else {
            XCTFail("Valid fixture setup failed: synthetic WAV has no audio frames")
            return
        }

        @MainActor
        func exercisePlayback() async throws {
            let (store, suite) = try defaults()
            defer { store.removePersistentDomain(forName: suite) }
            let controller = RecordingNowPlayingController()
            let player = AVPlayer()
            fixtureReaders.add(player)
            player.isMuted = true
            var activationCount = 0
            let manager = MusicPlaybackManager(
                player: player, defaults: store,
                activateAudioSession: { activationCount += 1 },
                nowPlayingController: controller
            )
            fixtureReaders.add(manager)
            var observations: [NSKeyValueObservation] = []
            var fixtureItems: [AVPlayerItem] = []
            defer {
                observations.forEach { $0.invalidate() }
                manager.pause()
                player.pause()
                player.replaceCurrentItem(with: nil)
                fixtureItems.forEach {
                    $0.cancelPendingSeeks()
                    $0.asset.cancelLoading()
                }
            }
            let corrupt = MusicItem(url: corruptURL, duration: 30)
            let valid = MusicItem(url: validURL, duration: 30)
            guard FileManager.default.isReadableFile(atPath: corruptURL.path),
                  try corruptURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  try Data(contentsOf: corruptURL) == corruptBytes else {
                XCTFail("Corrupt fixture setup failed: expected a readable regular file with exact invalid bytes")
                return
            }
            manager.updateQueue([corrupt, valid])
            manager.play(corrupt)
            let failedItem = try XCTUnwrap(player.currentItem, "Setup: manager must install a real item")
            fixtureItems.append(failedItem)
            fixtureReaders.add(failedItem)
            fixtureReaders.add(failedItem.asset)
            XCTAssertEqual((failedItem.asset as? AVURLAsset)?.url, corruptURL)
            XCTAssertEqual(activationCount, 1, "Activation succeeds; no session-throw injection")

            let failed = expectation(description: "Real corrupt AVPlayerItem reaches .failed")
            let failureObservation = failedItem.observe(\.status, options: [.initial, .new]) { item, _ in
                if item.status == .failed { failed.fulfill() }
            }
            observations.append(failureObservation)
            let failureResult = await XCTWaiter.fulfillment(of: [failed], timeout: 5)
            guard failureResult == .completed, failedItem.status == .failed else {
                XCTFail("Real .failed was not observed within 5 s; decode failure is unproven (status \(failedItem.status.rawValue), error \(String(describing: failedItem.error)))")
                return
            }
            XCTAssertNotNil(failedItem.error, "Real item failure must carry an AVFoundation error")
            XCTAssertEqual(try Data(contentsOf: corruptURL), corruptBytes, "Failure must not be a missing or changed fixture")

            let handled = expectation(description: "Real item failure handler completed")
            let handledSubscription = manager.itemFailureCompletionPublisher
                .filter { $0 > 0 }.prefix(1).sink { _ in handled.fulfill() }
            let handledResult = await XCTWaiter.fulfillment(of: [handled], timeout: 2)
            handledSubscription.cancel()
            XCTAssertEqual(handledResult, .completed)

            // Subscribe after proven failure; @Published's initial value also handles
            // recovery that already completed. Never infer completion from a yield/sleep.
            let stopped = expectation(description: "Manager converges to nonplaying after item failure")
            let stoppedSubscription = manager.$isPlaying.filter { !$0 }.prefix(1)
                .sink { _ in stopped.fulfill() }
            let stopResult = await XCTWaiter.fulfillment(of: [stopped], timeout: 2)
            stoppedSubscription.cancel()
            XCTAssertEqual(stopResult, .completed, "Manager must handle real item failure within 2 s")
            XCTAssertFalse(manager.isPlaying)
            XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(controller.snapshots.last?.playbackRate, 0)

            XCTAssertTrue(player.currentItem === failedItem)
            XCTAssertEqual(manager.currentTrack, corrupt)
            XCTAssertEqual(manager.currentIndex, 0)
            XCTAssertEqual(manager.queue, [corrupt, valid])
            XCTAssertFalse(try XCTUnwrap(manager.playbackErrorMessage).isEmpty)
            let snapshotCount = controller.snapshots.count
            var duplicateInvalidations = 0
            let duplicateObservation = manager.objectWillChange.sink { duplicateInvalidations += 1 }
            try await awaitItemFailureCallback(on: manager) {
                NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: failedItem)
            }
            duplicateObservation.cancel()
            XCTAssertEqual(duplicateInvalidations, 0, "Rejected failure completion must not invalidate playback views")
            XCTAssertEqual(controller.snapshots.count, snapshotCount, "Duplicate failure must not republish")
            XCTAssertEqual(activationCount, 1, "Failure must not retry or advance")

            // Continue after recovery assertions even when red, to test an explicit
            // change on the same manager/player without pausing or resetting either.
            // Queue the old callback, then replace synchronously before its actor hop.
            try await awaitItemFailureCallback(on: manager) {
                NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: failedItem)
                manager.play(valid)
            }
            let validItem = try XCTUnwrap(player.currentItem)
            fixtureItems.append(validItem)
            fixtureReaders.add(validItem)
            fixtureReaders.add(validItem.asset)
            XCTAssertFalse(validItem === failedItem)
            XCTAssertEqual((validItem.asset as? AVURLAsset)?.url, validURL)
            let playing = expectation(description: "Same real player plays the valid replacement")
            let playingObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
                if player.timeControlStatus == .playing { playing.fulfill() }
            }
            observations.append(playingObservation)
            let playingResult = await XCTWaiter.fulfillment(of: [playing], timeout: 5)
            XCTAssertEqual(playingResult, .completed, "Valid WAV must actually play within 5 s; intent alone is insufficient")
            XCTAssertEqual(validItem.status, .readyToPlay, "Valid fixture/player setup: \(String(describing: validItem.error))")
            XCTAssertEqual(player.timeControlStatus, .playing)
            XCTAssertTrue(manager.isPlaying)
            XCTAssertEqual(manager.currentTrack, valid)
            XCTAssertEqual(controller.snapshots.last?.playbackRate, 1)
            XCTAssertNil(manager.playbackErrorMessage)
            XCTAssertEqual(activationCount, 2)

            // Exercise a later failed-to-end event on the new load, after actual
            // playback and an interruption that would otherwise request resume.
            try await postProcessedAudioSessionNotification(
                to: manager,
                name: AVAudioSession.interruptionNotification,
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
            )
            try await awaitItemFailureCallback(on: manager) {
                NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: validItem)
            }
            XCTAssertNotNil(manager.playbackErrorMessage, "Failure dedup must reset for the new load")
            try await postProcessedAudioSessionNotification(
                to: manager,
                name: AVAudioSession.interruptionNotification,
                userInfo: [
                    AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                    AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
                ]
            )
            XCTAssertEqual(activationCount, 2, "Item failure must cancel interruption resume")
            XCTAssertFalse(manager.isPlaying)
            XCTAssertEqual(player.rate, 0)
            XCTAssertTrue(player.currentItem === validItem)
            XCTAssertEqual(manager.currentTrack, valid)
            XCTAssertEqual(manager.queue, [corrupt, valid])
        }

        try await exercisePlayback()
        XCTAssertEqual(try Data(contentsOf: corruptURL), corruptBytes)
        XCTAssertEqual(try Data(contentsOf: validURL), validBytes)
    }

    func testExplicitSameTrackTapRetriesRealFailedCorruptItemOncePerAction() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CorruptWAVSameTrackRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let fixtureReaders = NSHashTable<AnyObject>.weakObjects()
        addTeardownBlock { @MainActor in
            // Never unlink beneath a possible framework reader. No timed drain is
            // needed for this regression; preserve this unique fixture if still held.
            guard autoreleasepool(invoking: { fixtureReaders.allObjects.isEmpty }) else {
                print("AVFoundation cleanup pending; preserving retry fixtures at \(root.path)")
                return
            }
            try FileManager.default.removeItem(at: root)
        }
        let corruptURL = root.appendingPathComponent("invalid.wav")
        let otherURL = root.appendingPathComponent("other.wav")
        let corruptBytes = Data("Deliberately invalid WAV: no RIFF header or audio frames.".utf8)
        try corruptBytes.write(to: corruptURL, options: .withoutOverwriting)
        try writeRecoveryWAV(to: otherURL)
        let otherBytes = try Data(contentsOf: otherURL)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: corruptURL.path))
        XCTAssertEqual(try corruptURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, true)

        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let controller = RecordingNowPlayingController()
        let player = AVPlayer()
        player.isMuted = true
        var activationCount = 0
        let manager = MusicPlaybackManager(
            player: player, defaults: store,
            activateAudioSession: { activationCount += 1 },
            nowPlayingController: controller
        )
        fixtureReaders.add(player)
        fixtureReaders.add(manager)
        var fixtureItems: [AVPlayerItem] = []
        defer {
            manager.pause()
            player.pause()
            player.replaceCurrentItem(with: nil)
            fixtureItems.forEach {
                $0.cancelPendingSeeks()
                $0.asset.cancelLoading()
            }
        }
        let corrupt = MusicItem(url: corruptURL, duration: 30)
        let other = MusicItem(url: otherURL, duration: 30)
        manager.updateQueue([corrupt, other])

        @MainActor
        func awaitRealFailure(of item: AVPlayerItem, after generation: UInt64) async throws {
            // KVO proves actual AVFoundation failure; the replaying completion
            // publisher separately proves the manager's actor-hopped handler returned.
            let failed = expectation(description: "Corrupt retry item reaches real .failed")
            let statusSubscription = item.publisher(for: \.status, options: [.initial, .new])
                .filter { $0 == .failed }.prefix(1).sink { _ in failed.fulfill() }
            defer { statusSubscription.cancel() }
            let failureResult = await XCTWaiter.fulfillment(of: [failed], timeout: 5)
            guard failureResult == .completed, item.status == .failed else {
                XCTFail("Real corrupt-item failure unproven: status \(item.status.rawValue), error \(String(describing: item.error))")
                throw AudioSessionNotificationError.processingTimedOut
            }
            XCTAssertNotNil(item.error)
            let handled = expectation(description: "Real corrupt retry failure handler completed")
            let completionSubscription = manager.itemFailureCompletionPublisher
                .filter { $0 > generation }.prefix(1).sink { _ in handled.fulfill() }
            defer { completionSubscription.cancel() }
            let handledResult = await XCTWaiter.fulfillment(of: [handled], timeout: 2)
            guard handledResult == .completed else {
                XCTFail("Real corrupt retry failure handler did not complete")
                throw AudioSessionNotificationError.processingTimedOut
            }
            XCTAssertTrue(player.currentItem === item)
            XCTAssertFalse(manager.isPlaying)
            XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(controller.snapshots.last?.playbackRate, 0)
            XCTAssertFalse(try XCTUnwrap(manager.playbackErrorMessage).isEmpty)
        }

        let initialFailureGeneration = manager.itemFailureNotificationGeneration
        manager.play(corrupt)
        let originalItem = try XCTUnwrap(player.currentItem)
        fixtureItems.append(originalItem)
        fixtureReaders.add(originalItem)
        fixtureReaders.add(originalItem.asset)
        let initialLoadGeneration = manager.trackLoadGeneration
        try await awaitRealFailure(of: originalItem, after: initialFailureGeneration)
        XCTAssertEqual(manager.trackLoadGeneration, initialLoadGeneration, "Initial failure must not auto-retry or advance")
        XCTAssertEqual(activationCount, 1)

        // Seed a nonzero saved resume position only after real failure. This is
        // persistence state, not a claim that corrupt media ever decoded or sought.
        let savedPosition: TimeInterval = 7
        @MainActor
        func seedSavedPosition() async throws {
            let seeded = expectation(description: "Synthetic periodic pulse seeds saved resume position")
            let subscription = manager.timeline.$currentTime
                .dropFirst().filter { $0 == savedPosition }.prefix(1)
                .sink { _ in seeded.fulfill() }
            defer { subscription.cancel() }
            // Exercise the existing clock callback seam without asking AVPlayer to seek.
            manager.periodicTimeCallback()(CMTime(seconds: savedPosition, preferredTimescale: 600))
            let result = await XCTWaiter.fulfillment(of: [seeded], timeout: 2)
            guard result == .completed else {
                XCTFail("Synthetic resume-position pulse did not complete")
                throw AudioSessionNotificationError.processingTimedOut
            }
            // The MainActor callback finishes the published assignment before we resume.
            manager.savePlaybackState()
        }
        try await seedSavedPosition()
        let completionGeneration = manager.completionTransitionGeneration
        var previousItem = originalItem
        for action in 1...2 {
            // Failed media has no meaningful decoded clock. Reestablish the same
            // saved resume state for each independent user action.
            try await seedSavedPosition()
            let failureGeneration = manager.itemFailureNotificationGeneration
            manager.play(corrupt) // The sole explicit retry entry under test: same-track tap.
            let retryItem = try XCTUnwrap(player.currentItem)
            fixtureItems.append(retryItem)
            fixtureReaders.add(retryItem)
            fixtureReaders.add(retryItem.asset)
            XCTAssertFalse(retryItem === previousItem, "Tap \(action) must replace the failed instance")
            XCTAssertEqual(manager.trackLoadGeneration, initialLoadGeneration + UInt64(action), "Exactly one fresh load per tap")
            XCTAssertEqual(activationCount, 1 + action)
            XCTAssertEqual((retryItem.asset as? AVURLAsset)?.url, corruptURL)
            XCTAssertEqual(manager.currentTime, savedPosition, "Same-track retry must not reset the resume position")
            XCTAssertEqual(store.string(forKey: "MusicPlayback.lastTrackFileName"), corrupt.fileName)
            XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"), savedPosition)
            XCTAssertEqual(manager.currentTrack, corrupt)
            XCTAssertEqual(manager.currentIndex, 0)
            XCTAssertEqual(manager.queue, [corrupt, other])
            XCTAssertEqual(try Data(contentsOf: corruptURL), corruptBytes)
            XCTAssertEqual(try Data(contentsOf: otherURL), otherBytes)
            // At HEAD this guard follows the RED identity/generation assertions.
            // Do not mistake the old item's replayed .failed for a fresh retry.
            guard retryItem !== previousItem,
                  manager.trackLoadGeneration == initialLoadGeneration + UInt64(action) else { return }

            try await awaitRealFailure(of: retryItem, after: failureGeneration)
            // A duplicate notification is only a post-failure completion barrier,
            // never the evidence that this item actually failed. Bound the no-loop
            // assertion to these completed handlers, not an arbitrary quiet interval.
            try await awaitItemFailureCallback(on: manager) {
                NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: retryItem)
            }
            XCTAssertTrue(player.currentItem === retryItem)
            XCTAssertEqual(manager.trackLoadGeneration, initialLoadGeneration + UInt64(action), "Failure and duplicate handling must not auto-retry")
            XCTAssertEqual(activationCount, 1 + action, "Only the explicit tap may reactivate playback")
            XCTAssertFalse(manager.isPlaying)
            XCTAssertEqual(manager.currentTrack, corrupt)
            XCTAssertEqual(manager.currentIndex, 0)
            XCTAssertEqual(manager.queue, [corrupt, other], "Do not advance to the other track on failure")
            XCTAssertEqual(manager.completionTransitionGeneration, completionGeneration)
            XCTAssertEqual(store.string(forKey: "MusicPlayback.lastTrackFileName"), corrupt.fileName)
            XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"), savedPosition)
            XCTAssertEqual(try Data(contentsOf: corruptURL), corruptBytes)
            XCTAssertEqual(try Data(contentsOf: otherURL), otherBytes)
            previousItem = retryItem
        }
    }

    func testExplicitFailedMusicRetryActivationFailurePreservesActiveVideoAndPlaybackState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FailedMusicRetryActivation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let fixtureReaders = NSHashTable<AnyObject>.weakObjects()
        addTeardownBlock { @MainActor in
            guard autoreleasepool(invoking: { fixtureReaders.allObjects.isEmpty }) else {
                print("AVFoundation cleanup pending; preserving activation retry fixtures at \(root.path)")
                return
            }
            try FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("valid.wav")
        let otherURL = root.appendingPathComponent("other.wav")
        try writeRecoveryWAV(to: url, duration: 90)
        try writeRecoveryWAV(to: otherURL, duration: 90)
        let fixtureBytes = try Data(contentsOf: url)
        let otherBytes = try Data(contentsOf: otherURL)
        let frames = try autoreleasepool {
            let reader = try AVAudioFile(forReading: url)
            fixtureReaders.add(reader)
            return reader.length
        }
        XCTAssertGreaterThan(frames, 0)
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let session = MPNowPlayingSession(players: [AVPlayer()])
        let center = session.nowPlayingInfoCenter
        defer { center.nowPlayingInfo = nil; center.playbackState = .stopped }
        var profiles: [NowPlayingCommandProfile?] = []
        var dispatcher: (@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)?
        let registry = MusicNowPlayingRegistry(commandProfileSetter: { profiles.append($0) })
        let musicController = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { handler in dispatcher = handler; return [] },
            sharedRegistryForTesting: registry
        )
        let videoController = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { _ in [] },
            sharedRegistryForTesting: registry
        )
        let ownership = PlaybackOwnershipCoordinator()
        let player = ManuallyDrivenPeriodicPlayer()
        player.isMuted = true
        var failActivation = false
        var activationCount = 0
        let manager = MusicPlaybackManager(
            player: player, defaults: store, ownership: ownership,
            activateAudioSession: {
                activationCount += 1
                if failActivation { throw TestFailure.activation }
            },
            nowPlayingController: musicController
        )
        fixtureReaders.add(player)
        fixtureReaders.add(manager)
        defer {
            player.pause()
            player.currentItem?.cancelPendingSeeks()
            player.currentItem?.asset.cancelLoading()
            player.replaceCurrentItem(with: nil)
        }
        let song = MusicItem(url: url, duration: 90)
        let other = MusicItem(url: otherURL, duration: 90)
        let playlistID = UUID()
        manager.playFromPlaylist(song, playlistID: playlistID, items: [song, other])
        let item = try XCTUnwrap(player.currentItem)
        fixtureReaders.add(item)
        fixtureReaders.add(item.asset)
        let ready = expectation(description: "Valid synthetic WAV becomes ready before failure injection")
        let readyObservation = item.publisher(for: \.status, options: [.initial, .new])
            .filter { $0 == .readyToPlay }.prefix(1).sink { _ in ready.fulfill() }
        let readyResult = await XCTWaiter.fulfillment(of: [ready], timeout: 5)
        readyObservation.cancel()
        guard readyResult == .completed else {
            XCTFail("Valid WAV did not become ready: \(String(describing: item.error))")
            throw AudioSessionNotificationError.processingTimedOut
        }
        XCTAssertNil(item.error)
        XCTAssertTrue(manager.isPlaying)
        XCTAssertEqual(activationCount, 1)

        // INJECTION: valid media receives a synthetic failed-to-end notification.
        // The existing completion publisher proves the real manager handler returned;
        // this is not evidence of an AVFoundation decode failure or natural completion.
        try await awaitItemFailureCallback(on: manager) {
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item)
        }
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(player.rate, 0)
        XCTAssertNotNil(manager.playbackErrorMessage)
        XCTAssertTrue(player.currentItem === item)

        let seeded = expectation(description: "Manual clock seeds nonzero failed-music resume position")
        let seedObservation = manager.timeline.$currentTime
            .filter { $0 == 7 }.prefix(1).sink { _ in seeded.fulfill() }
        try XCTUnwrap(player.periodicCallback)(CMTime(seconds: 7, preferredTimescale: 600))
        let seedResult = await XCTWaiter.fulfillment(of: [seeded], timeout: 2)
        seedObservation.cancel()
        guard seedResult == .completed else {
            XCTFail("Manual position callback did not complete")
            throw AudioSessionNotificationError.processingTimedOut
        }
        manager.savePlaybackState()
        let video = VideoStopSpyForNowPlaying()
        let registration = ownership.registerVideoStop(for: video) { $0.stopCount += 1 }
        defer { withExtendedLifetime(registration) {} }
        let videoIntent = ownership.videoPlaybackRequested { manager.pause() }
        var videoCommandCount = 0
        videoController.registerVideoRemoteCommands { _ in
            videoCommandCount += 1
            return .success
        }
        videoController.publish(
            NowPlayingSnapshot(title: "Active Video", duration: 60, elapsedTime: 12, playbackRate: 1)
        )
        let dispatch = try XCTUnwrap(dispatcher)
        XCTAssertEqual(dispatch(.pause), .success)
        XCTAssertEqual(videoCommandCount, 1)
        XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent))
        XCTAssertEqual(profiles.last, .video)
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Active Video")
        XCTAssertEqual(manager.queueScope, .playlist(playlistID))
        XCTAssertEqual(manager.currentTime, 7)

        let loadGeneration = manager.trackLoadGeneration
        let failureGeneration = manager.itemFailureNotificationGeneration
        let completionGeneration = manager.completionTransitionGeneration
        let queue = manager.queue
        let scope = manager.queueScope
        let scopeNeedsRepair = manager.queueScopePersistenceNeedsRepair
        let track = manager.currentTrack
        let index = manager.currentIndex
        let position = manager.currentTime
        let duration = manager.duration
        let itemTime = item.currentTime()
        let persisted = try XCTUnwrap(store.persistentDomain(forName: suite)) as NSDictionary
        let videoSnapshot = try XCTUnwrap(center.nowPlayingInfo) as NSDictionary
        let videoState = center.playbackState
        let profilesBeforeRetry = profiles
        let stopsBeforeRetry = video.stopCount

        failActivation = true // Only the explicit same-track retry may throw.
        manager.play(song)

        XCTAssertEqual(activationCount, 2, "Exactly one activation attempt for the explicit retry")
        XCTAssertTrue(player.currentItem === item, "Failed activation must not replace the failed load")
        XCTAssertEqual(manager.trackLoadGeneration, loadGeneration)
        XCTAssertEqual(manager.itemFailureNotificationGeneration, failureGeneration)
        XCTAssertEqual(manager.completionTransitionGeneration, completionGeneration)
        XCTAssertEqual(manager.queue, queue)
        XCTAssertEqual(manager.queueScope, scope)
        XCTAssertEqual(manager.queueScopePersistenceNeedsRepair, scopeNeedsRepair)
        XCTAssertEqual(manager.currentTrack, track)
        XCTAssertEqual(manager.currentIndex, index)
        XCTAssertEqual(manager.currentTime, position)
        XCTAssertEqual(manager.duration, duration)
        XCTAssertEqual(CMTimeCompare(item.currentTime(), itemTime), 0)
        XCTAssertEqual(try XCTUnwrap(store.persistentDomain(forName: suite)) as NSDictionary, persisted)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(player.rate, 0)
        XCTAssertEqual(manager.playbackErrorMessage, "无法开始播放，请稍后重试。")
        XCTAssertEqual(try XCTUnwrap(center.nowPlayingInfo) as NSDictionary, videoSnapshot,
                       "Parent RED: activation catch must not publish music over active video")
        XCTAssertEqual(center.playbackState, videoState)
        XCTAssertEqual(profiles, profilesBeforeRetry)
        XCTAssertEqual(profiles.last, .video)
        XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent))
        XCTAssertEqual(video.stopCount, stopsBeforeRetry)
        XCTAssertEqual(dispatch(.pause), .success)
        XCTAssertEqual(videoCommandCount, 2, "Actual registry dispatcher must still route to video")
        XCTAssertEqual(video.stopCount, stopsBeforeRetry)
        XCTAssertEqual(try Data(contentsOf: url), fixtureBytes)
        XCTAssertEqual(try Data(contentsOf: otherURL), otherBytes)
    }

    func testRegistryRemotePlayRetriesInjectedFailedHealthyWAVAndActuallyPlaysAtRetainedPosition() async throws {
        try await assertRegistryRetryOfInjectedFailedHealthyWAV(command: .play, retainedQueueIsEmpty: nil)
    }

    func testRegistryRemoteToggleRetriesInjectedFailedHealthyWAVAndActuallyPlaysAtRetainedPosition() async throws {
        try await assertRegistryRetryOfInjectedFailedHealthyWAV(command: .togglePlayPause, retainedQueueIsEmpty: nil)
    }

    func testRegistryRemotePlayRetriesRetainedCurrentWithoutReinsertingIntoPlaylist() async throws {
        try await assertRegistryRetryOfInjectedFailedHealthyWAV(command: .play, retainedQueueIsEmpty: false)
    }

    func testRegistryRemoteToggleRetriesRetainedCurrentWithoutReinsertingIntoEmptyPlaylist() async throws {
        try await assertRegistryRetryOfInjectedFailedHealthyWAV(command: .togglePlayPause, retainedQueueIsEmpty: true)
    }

    private func assertRegistryRetryOfInjectedFailedHealthyWAV(
        command: MusicRemoteCommand,
        retainedQueueIsEmpty: Bool?
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RegistryInjectedFailureRetry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let fixtureReaders = NSHashTable<AnyObject>.weakObjects()
        addTeardownBlock { @MainActor in
            guard autoreleasepool(invoking: { fixtureReaders.allObjects.isEmpty }) else {
                print("AVFoundation cleanup pending; preserving registry retry fixtures at \(root.path)")
                return
            }
            try FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("healthy.wav")
        try writeRecoveryWAV(to: url, duration: 90)
        let originalBytes = try Data(contentsOf: url)
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let player = ManuallyDrivenPeriodicPlayer()
        player.isMuted = true
        let session = MPNowPlayingSession(players: [player])
        let center = session.nowPlayingInfoCenter
        defer { center.nowPlayingInfo = nil; center.playbackState = .stopped }
        var dispatcher: (@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)?
        var profiles: [NowPlayingCommandProfile?] = []
        let registry = MusicNowPlayingRegistry(commandProfileSetter: { profiles.append($0) })
        let controller = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { handler in dispatcher = handler; return [] },
            sharedRegistryForTesting: registry
        )
        var activationCount = 0
        let manager = MusicPlaybackManager(
            player: player, defaults: store,
            activateAudioSession: { activationCount += 1 },
            nowPlayingController: controller
        )
        fixtureReaders.add(player)
        fixtureReaders.add(manager)
        var items: [AVPlayerItem] = []
        defer {
            manager.pause()
            player.replaceCurrentItem(with: nil)
            items.forEach { $0.cancelPendingSeeks(); $0.asset.cancelLoading() }
        }
        func awaitActualPlaying() async throws {
            let playing = expectation(description: "Healthy WAV reaches actual AVPlayer playing")
            let observation = player.publisher(for: \.timeControlStatus, options: [.initial, .new])
                .filter { $0 == .playing }.prefix(1).sink { _ in playing.fulfill() }
            defer { observation.cancel() }
            guard await XCTWaiter.fulfillment(of: [playing], timeout: 5) == .completed else {
                XCTFail("Healthy WAV did not reach actual playing within 5 s")
                throw AudioSessionNotificationError.processingTimedOut
            }
            XCTAssertEqual(player.currentItem?.status, .readyToPlay)
            XCTAssertNil(player.currentItem?.error)
            XCTAssertEqual(player.timeControlStatus, .playing)
        }
        let song = MusicItem(url: url, duration: 90)
        let other = MusicItem(url: root.appendingPathComponent("unplayed.wav"), duration: 90)
        let playlistID = UUID()
        manager.playFromPlaylist(song, playlistID: playlistID, items: [song, other])
        let oldItem = try XCTUnwrap(player.currentItem)
        items.append(oldItem)
        fixtureReaders.add(oldItem)
        fixtureReaders.add(oldItem.asset)
        try await awaitActualPlaying()
        let dispatch = try XCTUnwrap(dispatcher)
        XCTAssertEqual(profiles.last, .music)
        let oldSeek = manager.seekCompletionCallback(to: 61)
        let oldPeriodic = try XCTUnwrap(player.periodicCallback)
        if let retainedQueueIsEmpty {
            manager.reconcilePlaylistQueue(id: playlistID, items: retainedQueueIsEmpty ? [] : [other])
            XCTAssertNil(manager.currentIndex)
            XCTAssertEqual(manager.currentTrack, song)
        }
        let expectedQueue = manager.queue
        let expectedIndex = manager.currentIndex
        let loadGeneration = manager.trackLoadGeneration
        try await postProcessedAudioSessionNotification(
            to: manager, name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        // Injection into proven healthy media, not evidence of real corrupt decoding.
        try await awaitItemFailureCallback(on: manager) {
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem)
        }
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(player.rate, 0)
        XCTAssertNotNil(manager.playbackErrorMessage)
        try await postProcessedAudioSessionNotification(
            to: manager, name: AVAudioSession.interruptionNotification,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ]
        )
        XCTAssertEqual(activationCount, 1, "Interruption must not retry an injected failed item")
        XCTAssertEqual(manager.trackLoadGeneration, loadGeneration)
        XCTAssertTrue(player.currentItem === oldItem)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(player.rate, 0)

        let seeded = expectation(description: "Existing manual periodic seam seeds retained position")
        let seedObservation = manager.timeline.$currentTime.filter { $0 == 7 }.prefix(1)
            .sink { _ in seeded.fulfill() }
        try XCTUnwrap(player.periodicCallback)(CMTime(seconds: 7, preferredTimescale: 600))
        let seedResult = await XCTWaiter.fulfillment(of: [seeded], timeout: 2)
        seedObservation.cancel()
        guard seedResult == .completed else {
            XCTFail("Retained position was not seeded")
            throw AudioSessionNotificationError.processingTimedOut
        }
        manager.savePlaybackState()
        // Enqueue the OLD observer while installed, replace before its actor hop,
        // then await that very failure handler's completion publisher.
        try await awaitItemFailureCallback(on: manager) {
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem)
            XCTAssertEqual(dispatch(command), .success)
            XCTAssertEqual(manager.currentTime, 7)
        }
        let replacement = try XCTUnwrap(player.currentItem)
        items.append(replacement)
        fixtureReaders.add(replacement)
        fixtureReaders.add(replacement.asset)
        XCTAssertFalse(replacement === oldItem)
        XCTAssertEqual((replacement.asset as? AVURLAsset)?.url, url)
        XCTAssertEqual(manager.trackLoadGeneration, loadGeneration + 1)
        XCTAssertEqual(activationCount, 2)
        XCTAssertNil(manager.playbackErrorMessage, "Completed old failure must not poison retry")
        try await awaitActualPlaying()

        let seekGeneration = manager.seekCompletionGeneration
        let seekProcessed = expectation(description: "Old seek callback returns after retry")
        let seekObservation = manager.seekCompletionPublisher.filter { $0 > seekGeneration }.prefix(1)
            .sink { _ in seekProcessed.fulfill() }
        oldSeek(true)
        let seekResult = await XCTWaiter.fulfillment(of: [seekProcessed], timeout: 2)
        seekObservation.cancel()
        guard seekResult == .completed else {
            XCTFail("Old seek callback did not complete")
            throw AudioSessionNotificationError.processingTimedOut
        }
        XCTAssertEqual(manager.currentTime, 7, "Completed old seek cannot overwrite retry position")
        XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"), 7)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 7)
        // Only periodic delivery is manual: no live pulse can satisfy this
        // completion or change the baseline while the old callback crosses actors.
        // This proves manager isolation, not AVFoundation's periodic scheduling.
        let timeBeforePeriodic = manager.currentTime
        let durationBeforePeriodic = manager.duration
        let persistenceBeforePeriodic = try XCTUnwrap(store.persistentDomain(forName: suite)) as NSDictionary
        let errorBeforePeriodic = manager.playbackErrorMessage
        let nowPlayingBeforePeriodic = try XCTUnwrap(center.nowPlayingInfo) as NSDictionary
        let playbackStateBeforePeriodic = center.playbackState
        let profilesBeforePeriodic = profiles
        let periodicGeneration = manager.periodicCompletionGeneration
        let periodicProcessed = expectation(description: "Old periodic callback returns after retry")
        let periodicObservation = manager.periodicCompletionPublisher
            .filter { $0 > periodicGeneration }.prefix(1)
            .sink { _ in periodicProcessed.fulfill() }
        oldPeriodic(CMTime(seconds: 67, preferredTimescale: 600))
        let periodicResult = await XCTWaiter.fulfillment(of: [periodicProcessed], timeout: 2)
        periodicObservation.cancel()
        guard periodicResult == .completed else {
            XCTFail("Old periodic callback did not complete within 2 s")
            throw AudioSessionNotificationError.processingTimedOut
        }
        XCTAssertEqual(manager.periodicCompletionGeneration, periodicGeneration + 1)
        XCTAssertEqual(manager.currentTime, timeBeforePeriodic, "Completed old pulse cannot overwrite the new timeline")
        XCTAssertEqual(manager.duration, durationBeforePeriodic)
        XCTAssertEqual(try XCTUnwrap(store.persistentDomain(forName: suite)) as NSDictionary, persistenceBeforePeriodic)
        XCTAssertEqual(manager.playbackErrorMessage, errorBeforePeriodic)
        XCTAssertEqual(try XCTUnwrap(center.nowPlayingInfo) as NSDictionary, nowPlayingBeforePeriodic)
        XCTAssertEqual(center.playbackState, playbackStateBeforePeriodic)
        XCTAssertEqual(profiles, profilesBeforePeriodic)
        XCTAssertTrue(player.currentItem === replacement)
        XCTAssertEqual(replacement.status, .readyToPlay)
        XCTAssertNil(replacement.error)
        XCTAssertEqual(manager.trackLoadGeneration, loadGeneration + 1)
        XCTAssertTrue(manager.isPlaying)
        XCTAssertEqual(player.timeControlStatus, .playing)
        // The player itself must advance beyond the retained position. Its real
        // boundary observer remains available on the manually driven periodic player.
        let advanced = expectation(description: "Replacement actually advances from retained position")
        let boundary = max(7.25, player.currentTime().seconds + 0.25)
        let token = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: boundary, preferredTimescale: 600))], queue: .main
        ) { advanced.fulfill() }
        let advancedResult = await XCTWaiter.fulfillment(of: [advanced], timeout: 3)
        player.removeTimeObserver(token)
        XCTAssertEqual(advancedResult, .completed)
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 7.25)
        XCTAssertTrue(player.currentItem === replacement)
        XCTAssertTrue(manager.isPlaying)
        XCTAssertEqual(player.timeControlStatus, .playing)
        XCTAssertNil(manager.playbackErrorMessage)
        XCTAssertEqual(center.nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        XCTAssertEqual(profiles.last, .music)
        XCTAssertEqual(manager.currentTrack, song)
        XCTAssertEqual(manager.currentIndex, expectedIndex)
        XCTAssertEqual(manager.queue, expectedQueue)
        XCTAssertEqual(manager.queueScope, .playlist(playlistID))
        if retainedQueueIsEmpty != nil {
            XCTAssertNil(manager.currentIndex)
            XCTAssertFalse(manager.queue.contains(song), "Retry must not reinsert retained current")
        }
        XCTAssertEqual(manager.trackLoadGeneration, loadGeneration + 1)
        XCTAssertEqual(activationCount, 2, "Exactly one explicit retry activation")
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
    }

    private func awaitItemFailureCallback(
        on manager: MusicPlaybackManager,
        action: () -> Void
    ) async throws {
        let generation = manager.itemFailureNotificationGeneration
        let processed = expectation(description: "Item failure callback completed after actor hop")
        let subscription = manager.itemFailureCompletionPublisher
            .filter { $0 > generation }.prefix(1).sink { _ in processed.fulfill() }
        defer { subscription.cancel() }
        action()
        let result = await XCTWaiter.fulfillment(of: [processed], timeout: 2)
        guard result == .completed else {
            XCTFail("Item failure callback did not complete")
            throw AudioSessionNotificationError.processingTimedOut
        }
    }

    private func writeRecoveryWAV(to url: URL, duration: Int = 30) throws {
        // Match the intended track duration and keep EOF outside the wait bounds.
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 8_000, channels: 1, interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(8_000 * duration)))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) {
            samples[frame] = Float(0.01 * sin(2 * .pi * 440 * Double(frame) / 8_000))
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let reader = try AVAudioFile(forReading: url)
        XCTAssertEqual(reader.length, AVAudioFramePosition(8_000 * duration), "Synthetic WAV must contain all intended audio frames")
    }

    func testAudioSessionInterruptionBeganPausesAndPublishesZeroPlaybackRate() async throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let controller = RecordingNowPlayingController()
        let player = AVPlayer()
        let manager = MusicPlaybackManager(player: player, defaults: store, activateAudioSession: {}, nowPlayingController: controller)
        let song = MusicItem(url: URL(fileURLWithPath: "/tmp/Interrupted.mp3"), duration: 30)
        manager.updateQueue([song]); manager.play(song)
        XCTAssertEqual(controller.snapshots.last?.playbackRate, 1)

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        await Task.yield(); await Task.yield()

        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(controller.snapshots.last?.playbackRate, 0)
    }

    private enum AudioSessionNotificationError: Error {
        case processingTimedOut
    }

    private func postProcessedAudioSessionNotification(
        to manager: MusicPlaybackManager,
        name: Notification.Name,
        userInfo: [AnyHashable: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let generation: KeyPath<MusicPlaybackManager, UInt64>
        let publisher: Published<UInt64>.Publisher
        switch name {
        case AVAudioSession.interruptionNotification:
            generation = \.interruptionNotificationGeneration
            publisher = manager.$interruptionNotificationGeneration
        case AVAudioSession.routeChangeNotification:
            generation = \.routeChangeNotificationGeneration
            publisher = manager.$routeChangeNotificationGeneration
        default:
            preconditionFailure("Unsupported audio session notification")
        }
        let expectedGeneration = manager[keyPath: generation] &+ 1
        let processed = expectation(description: "Manager processed \(name.rawValue)")
        let subscription = publisher
            .filter { $0 == expectedGeneration }
            .prefix(1)
            .sink { _ in processed.fulfill() }
        defer { subscription.cancel() }

        NotificationCenter.default.post(
            name: name,
            object: AVAudioSession.sharedInstance(),
            userInfo: userInfo
        )
        let result = await XCTWaiter.fulfillment(of: [processed], timeout: 1)
        guard result == .completed, manager[keyPath: generation] == expectedGeneration else {
            XCTFail("Manager did not finish processing \(name.rawValue) within the timeout", file: file, line: line)
            throw AudioSessionNotificationError.processingTimedOut
        }
    }

    func testInterruptionEndedShouldResumeRestoresPlaybackExactlyOnce() async throws {
        try await assertInterruptionResumesExactlyOnce(withNewDeviceAvailable: false)
    }

    func testNewDeviceAvailableDuringInterruptionPreservesResumeExactlyOnce() async throws {
        try await assertInterruptionResumesExactlyOnce(withNewDeviceAvailable: true)
    }

    private func assertInterruptionResumesExactlyOnce(withNewDeviceAvailable: Bool) async throws {
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let controller = RecordingNowPlayingController()
        var activationCount = 0
        let manager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: store,
            activateAudioSession: { activationCount += 1 },
            nowPlayingController: controller
        )
        // Normal playback requires decodable media now that item failures are observed.
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Interruption Resume-\(UUID().uuidString).wav")
        try writeRecoveryWAV(to: fixtureURL, duration: 30)
        let song = MusicItem(url: fixtureURL, duration: 30)
        defer {
            manager.prepareForDeletion(song)
            do { try FileManager.default.removeItem(at: fixtureURL) }
            catch { XCTFail("Could not remove normal-playback fixture: \(error)") }
        }
        manager.updateQueue([song])
        manager.play(song)
        XCTAssertTrue(manager.isPlaying)
        XCTAssertEqual(controller.snapshots.last?.playbackRate, 1)
        XCTAssertEqual(activationCount, 1)

        try await postProcessedAudioSessionNotification(
            to: manager,
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(controller.snapshots.last?.playbackRate, 0)
        XCTAssertEqual(activationCount, 1)

        if withNewDeviceAvailable {
            try await postProcessedAudioSessionNotification(
                to: manager,
                name: AVAudioSession.routeChangeNotification,
                userInfo: [AVAudioSessionRouteChangeReasonKey:
                    AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue]
            )
            XCTAssertFalse(manager.isPlaying)
            XCTAssertEqual(controller.snapshots.last?.playbackRate, 0)
            XCTAssertEqual(activationCount, 1)
        }

        // A duplicate ended notification must not activate the audio session again.
        for _ in 0..<2 {
            try await postProcessedAudioSessionNotification(
                to: manager,
                name: AVAudioSession.interruptionNotification,
                userInfo: [
                    AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                    AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
                ]
            )
            XCTAssertTrue(manager.isPlaying)
            XCTAssertEqual(manager.currentTrack, song)
            XCTAssertEqual(controller.snapshots.last?.playbackRate, 1)
            XCTAssertEqual(activationCount, 2, "Automatic resume must activate audio exactly once")
        }
    }

    func testInterruptionResumeAfterOldDeviceUnavailableRemainsPausedWithoutAudioReactivation() async throws {
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let controller = RecordingNowPlayingController()
        var activationCount = 0
        let manager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: store,
            activateAudioSession: { activationCount += 1 },
            nowPlayingController: controller
        )
        let song = MusicItem(url: URL(fileURLWithPath: "/tmp/Interrupted Route Loss.mp3"), duration: 30)
        manager.updateQueue([song])
        manager.play(song)
        XCTAssertTrue(manager.isPlaying)
        XCTAssertEqual(controller.snapshots.last?.playbackRate, 1)
        XCTAssertEqual(activationCount, 1)

        try await postProcessedAudioSessionNotification(
            to: manager,
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(controller.snapshots.last?.playbackRate, 0)

        try await postProcessedAudioSessionNotification(
            to: manager,
            name: AVAudioSession.routeChangeNotification,
            userInfo: [AVAudioSessionRouteChangeReasonKey:
                AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        )
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(activationCount, 1)

        try await postProcessedAudioSessionNotification(
            to: manager,
            name: AVAudioSession.interruptionNotification,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ]
        )

        XCTAssertFalse(manager.isPlaying, "Route loss during interruption must cancel automatic resume")
        XCTAssertEqual(controller.snapshots.last?.playbackRate, 0)
        XCTAssertEqual(activationCount, 1, "Interruption end must not reactivate audio after route loss")
    }

    func testInterruptionBeganDoesNotReclaimNowPlayingOrRemoteCommandsFromActiveVideo() async throws {
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let session = MPNowPlayingSession(players: [AVPlayer()])
        let center = session.nowPlayingInfoCenter
        defer { center.nowPlayingInfo = nil; center.playbackState = .stopped }
        var profiles: [NowPlayingCommandProfile?] = []
        var dispatcher: (@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)?
        let registry = MusicNowPlayingRegistry(commandProfileSetter: { profiles.append($0) })
        let musicController = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { handler in dispatcher = handler; return [] },
            sharedRegistryForTesting: registry
        )
        let videoController = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { _ in [] },
            sharedRegistryForTesting: registry
        )
        let ownership = PlaybackOwnershipCoordinator()
        let manager = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: store,
            ownership: ownership,
            activateAudioSession: {},
            nowPlayingController: musicController
        )
        let song = MusicItem(url: URL(fileURLWithPath: "/tmp/Loaded Before Video.mp3"), duration: 30)
        manager.updateQueue([song])
        manager.play(song)
        XCTAssertTrue(manager.isPlaying)
        let videoIntent = ownership.videoPlaybackRequested { manager.pause() }
        var videoCommandCount = 0
        videoController.registerVideoRemoteCommands { _ in
            videoCommandCount += 1
            return .success
        }
        videoController.publish(
            NowPlayingSnapshot(title: "Active Video", duration: 60, elapsedTime: 12, playbackRate: 1)
        )
        XCTAssertEqual(manager.currentTrack, song)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Active Video")
        XCTAssertEqual(profiles.last, .video)
        XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent))
        let dispatch = try XCTUnwrap(dispatcher)
        XCTAssertEqual(dispatch(.pause), .success)
        XCTAssertEqual(videoCommandCount, 1)

        try await postProcessedAudioSessionNotification(
            to: manager,
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )

        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Active Video")
        XCTAssertEqual(profiles.last, .video)
        XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent))
        XCTAssertEqual(dispatch(.pause), .success)
        XCTAssertEqual(videoCommandCount, 2, "The registry must still dispatch remote commands to video")
    }

    func testItemFailureDoesNotReclaimNowPlayingOrRemoteCommandsFromActiveVideo() async throws {
        let (store, suite) = try defaults()
        defer { store.removePersistentDomain(forName: suite) }
        let session = MPNowPlayingSession(players: [AVPlayer()])
        let center = session.nowPlayingInfoCenter
        defer { center.nowPlayingInfo = nil; center.playbackState = .stopped }
        var profiles: [NowPlayingCommandProfile?] = []
        var dispatcher: (@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)?
        let registry = MusicNowPlayingRegistry(commandProfileSetter: { profiles.append($0) })
        let musicController = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { handler in dispatcher = handler; return [] },
            sharedRegistryForTesting: registry
        )
        let videoController = MediaPlayerMusicNowPlayingController(
            testingCenter: center,
            registerTargets: { _ in [] },
            sharedRegistryForTesting: registry
        )
        let ownership = PlaybackOwnershipCoordinator()
        let player = AVPlayer()
        let manager = MusicPlaybackManager(
            player: player,
            defaults: store,
            ownership: ownership,
            activateAudioSession: {},
            nowPlayingController: musicController
        )
        let song = MusicItem(url: URL(fileURLWithPath: "/tmp/Loaded Before Video.mp3"), duration: 30)
        manager.updateQueue([song])
        manager.play(song)
        XCTAssertTrue(manager.isPlaying)
        let pendingSeekCallback = manager.seekCompletionCallback(to: 23)
        let videoIntent = ownership.videoPlaybackRequested { manager.pause() }
        var videoCommandCount = 0
        videoController.registerVideoRemoteCommands { _ in
            videoCommandCount += 1
            return .success
        }
        videoController.publish(
            NowPlayingSnapshot(title: "Active Video", duration: 60, elapsedTime: 12, playbackRate: 1)
        )
        XCTAssertEqual(manager.currentTrack, song)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Active Video")
        XCTAssertEqual(profiles.last, .video)
        XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent))
        let dispatch = try XCTUnwrap(dispatcher)
        XCTAssertEqual(dispatch(.pause), .success)
        XCTAssertEqual(videoCommandCount, 1)

        let item = try XCTUnwrap(player.currentItem)
        let pendingPeriodicCallback = manager.periodicTimeCallback()
        try await awaitItemFailureCallback(on: manager) {
            NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: item)
        }
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(player.rate, 0)
        XCTAssertNotNil(manager.playbackErrorMessage)

        let periodicProcessed = expectation(description: "Pending failed-item pulse updates timeline")
        let periodicObservation = manager.timeline.$currentTime
            .filter { $0 == 17 }.prefix(1).sink { _ in periodicProcessed.fulfill() }
        pendingPeriodicCallback(CMTime(seconds: 17, preferredTimescale: 600))
        let periodicResult = await XCTWaiter.fulfillment(of: [periodicProcessed], timeout: 2)
        periodicObservation.cancel()
        XCTAssertEqual(periodicResult, .completed)
        // The MainActor callback finishes publication before this actor resumes.

        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String, "Active Video")
        XCTAssertEqual(profiles.last, .video)
        XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent))
        XCTAssertEqual(dispatch(.pause), .success)
        XCTAssertEqual(videoCommandCount, 2, "The registry must still dispatch remote commands to video")

        let videoSnapshot = try XCTUnwrap(center.nowPlayingInfo) as NSDictionary
        let videoPlaybackState = center.playbackState
        let profilesBeforeSeek = profiles
        let failureMessage = try XCTUnwrap(manager.playbackErrorMessage)
        let positionBeforeSeek = manager.currentTime
        let persistedPositionBeforeSeek = store.object(forKey: "MusicPlayback.lastPositionSeconds") as? NSNumber
        let persistedTrackBeforeSeek = store.string(forKey: "MusicPlayback.lastTrackFileName")
        let seekGeneration = manager.seekCompletionGeneration
        let seekProcessed = expectation(description: "Pending failed-item seek callback completed after actor hop")
        let seekObservation = manager.seekCompletionPublisher
            .filter { $0 > seekGeneration }.prefix(1).sink { _ in seekProcessed.fulfill() }
        defer { seekObservation.cancel() }
        pendingSeekCallback(true)
        let seekResult = await XCTWaiter.fulfillment(of: [seekProcessed], timeout: 2)
        guard seekResult == .completed else {
            XCTFail("Pending failed-item seek callback did not complete within 2 s")
            throw AudioSessionNotificationError.processingTimedOut
        }

        XCTAssertEqual(try XCTUnwrap(center.nowPlayingInfo) as NSDictionary, videoSnapshot)
        XCTAssertEqual(center.playbackState, videoPlaybackState)
        XCTAssertEqual(profiles, profilesBeforeSeek)
        XCTAssertEqual(profiles.last, .video)
        XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent))
        XCTAssertEqual(dispatch(.pause), .success)
        XCTAssertEqual(videoCommandCount, 3, "The real registry dispatcher must still route to video after the failed-item seek")
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(player.rate, 0)
        XCTAssertFalse(manager.isPlaying)
        XCTAssertEqual(manager.currentTrack, song)
        XCTAssertEqual(manager.queue, [song])
        XCTAssertEqual(manager.playbackErrorMessage, failureMessage)
        XCTAssertEqual(manager.currentTime, positionBeforeSeek)
        XCTAssertEqual(store.object(forKey: "MusicPlayback.lastPositionSeconds") as? NSNumber, persistedPositionBeforeSeek)
        XCTAssertEqual(store.string(forKey: "MusicPlayback.lastTrackFileName"), persistedTrackBeforeSeek)
    }

    func testNextPreviousEndAdvanceAndSynchronousClear() async throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let controller = RecordingNowPlayingController(); let player = AVPlayer()
        let manager = MusicPlaybackManager(player: player, defaults: store, activateAudioSession: {}, nowPlayingController: controller)
        let first = MusicItem(url: URL(fileURLWithPath: "/tmp/First.mp3"), duration: 10)
        let second = MusicItem(url: URL(fileURLWithPath: "/tmp/Second.mp3"), duration: 20)
        manager.updateQueue([first, second]); manager.play(first)
        manager.next(); XCTAssertEqual(controller.snapshots.last?.title, "Second")
        manager.previous(); XCTAssertEqual(controller.snapshots.last?.title, "First")
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: try XCTUnwrap(player.currentItem)); await Task.yield()
        XCTAssertEqual(controller.snapshots.last?.title, "Second")
        let beforeDelete = controller.clearCount
        manager.prepareForDeletion(second)
        XCTAssertEqual(controller.clearCount, beforeDelete + 1); XCTAssertNil(manager.currentTrack)
        manager.updateQueue([first]); manager.play(first)
        let beforeDisappear = controller.clearCount
        manager.updateQueue([])
        XCTAssertEqual(controller.clearCount, beforeDisappear + 1); XCTAssertNil(manager.currentTrack)
    }

    func testRemoteCommandsRejectImpossibleOperationsAndPreserveActivationBeforeOwnership() throws {
        let (store, suite) = try defaults(); defer { store.removePersistentDomain(forName: suite) }
        let controller = RecordingNowPlayingController(); var failActivation = false; var activationCount = 0
        let ownership = PlaybackOwnershipCoordinator(); let video = VideoStopSpyForNowPlaying()
        let registration = ownership.registerVideoStop(for: video) { $0.stopCount += 1 }
        let manager = MusicPlaybackManager(player: AVPlayer(), defaults: store, ownership: ownership, activateAudioSession: { activationCount += 1; if failActivation { throw TestFailure.activation } }, nowPlayingController: controller)
        XCTAssertEqual(controller.send(.play), .commandFailed)
        XCTAssertEqual(controller.send(.pause), .commandFailed)
        XCTAssertEqual(controller.send(.changePlaybackPosition(1)), .commandFailed)
        let first = MusicItem(url: URL(fileURLWithPath: "/tmp/First.mp3"), duration: 30)
        let second = MusicItem(url: URL(fileURLWithPath: "/tmp/Second.mp3"), duration: 40)
        manager.updateQueue([first, second]); manager.play(first); manager.pause()
        XCTAssertEqual(controller.send(.pause), .commandFailed)
        XCTAssertEqual(controller.send(.changePlaybackPosition(.nan)), .commandFailed)
        XCTAssertEqual(controller.send(.changePlaybackPosition(.infinity)), .commandFailed)
        XCTAssertEqual(MusicPlaybackManager.clampedSeekPosition(300, duration: 30), 30)
        XCTAssertEqual(MusicPlaybackManager.clampedSeekPosition(-4, duration: 30), 0)
        XCTAssertEqual(controller.send(.changePlaybackPosition(300)), .success)
        XCTAssertEqual(controller.send(.play), .success)
        XCTAssertEqual(controller.send(.togglePlayPause), .success)
        XCTAssertEqual(controller.send(.togglePlayPause), .success)
        XCTAssertEqual(controller.send(.nextTrack), .success); XCTAssertEqual(manager.currentTrack?.fileName, "Second.mp3")
        XCTAssertEqual(controller.send(.previousTrack), .success); XCTAssertEqual(manager.currentTrack?.fileName, "First.mp3")
        manager.pause(); failActivation = true
        let stopsBeforeFailure = video.stopCount
        XCTAssertEqual(controller.send(.play), .commandFailed)
        XCTAssertEqual(video.stopCount, stopsBeforeFailure); XCTAssertFalse(manager.isPlaying); XCTAssertGreaterThan(activationCount, 0)
        withExtendedLifetime(registration) {}
    }

    func testRemoteNextAndPreviousTrackCommandsFailWhenAudioSessionActivationThrowsAndRemainPaused() throws {
        for (command, startingTrackIndex) in [(MusicRemoteCommand.nextTrack, 0), (.previousTrack, 2)] {
            let (store, suite) = try defaults("\(command)")
            defer { store.removePersistentDomain(forName: suite) }
            let controller = RecordingNowPlayingController()
            var failActivation = false
            let manager = MusicPlaybackManager(
                player: AVPlayer(),
                defaults: store,
                activateAudioSession: { if failActivation { throw TestFailure.activation } },
                nowPlayingController: controller
            )
            let tracks = [
                MusicItem(url: URL(fileURLWithPath: "/tmp/First.mp3"), duration: 30),
                MusicItem(url: URL(fileURLWithPath: "/tmp/Second.mp3"), duration: 40),
                MusicItem(url: URL(fileURLWithPath: "/tmp/Third.mp3"), duration: 50),
            ]
            manager.updateQueue(tracks)
            manager.play(tracks[startingTrackIndex])
            manager.pause()
            let trackBeforeCommand = manager.currentTrack
            failActivation = true

            XCTAssertEqual(controller.send(command), .commandFailed)
            XCTAssertFalse(manager.isPlaying)
            XCTAssertEqual(manager.currentTrack, trackBeforeCommand)
        }
    }

    func testRemoteTrackActivationFailureWhilePlayingPreservesAllPlaybackState() async throws {
        for (command, startingTrackIndex) in [(MusicRemoteCommand.nextTrack, 0), (.previousTrack, 2)] {
            let (store, suite) = try defaults("playing-\(command)")
            defer { store.removePersistentDomain(forName: suite) }
            let controller = RecordingNowPlayingController()
            var failActivation = false
            let manager = MusicPlaybackManager(
                player: AVPlayer(),
                defaults: store,
                activateAudioSession: { if failActivation { throw TestFailure.activation } },
                nowPlayingController: controller
            )
            let tracks = [
                MusicItem(url: URL(fileURLWithPath: "/tmp/First.mp3"), duration: 30),
                MusicItem(url: URL(fileURLWithPath: "/tmp/Second.mp3"), duration: 40),
                MusicItem(url: URL(fileURLWithPath: "/tmp/Third.mp3"), duration: 50),
            ]
            manager.updateQueue(tracks)
            manager.play(tracks[startingTrackIndex])
            manager.seekCompletionCallback(to: 12)(true)
            await Task.yield()
            await Task.yield()

            let trackBeforeCommand = manager.currentTrack
            let timeBeforeCommand = manager.currentTime
            let persistedTrackBeforeCommand = store.string(forKey: "MusicPlayback.lastTrackFileName")
            let persistedPositionBeforeCommand = store.double(forKey: "MusicPlayback.lastPositionSeconds")
            let snapshotBeforeCommand = controller.snapshots.last
            let snapshotCountBeforeCommand = controller.snapshots.count
            failActivation = true

            XCTAssertEqual(controller.send(command), .commandFailed)
            XCTAssertTrue(manager.isPlaying)
            XCTAssertEqual(manager.currentTrack, trackBeforeCommand)
            XCTAssertEqual(manager.currentTime, timeBeforeCommand)
            XCTAssertEqual(store.string(forKey: "MusicPlayback.lastTrackFileName"), persistedTrackBeforeCommand)
            XCTAssertEqual(store.double(forKey: "MusicPlayback.lastPositionSeconds"), persistedPositionBeforeCommand)
            XCTAssertEqual(controller.snapshots.count, snapshotCountBeforeCommand)
            XCTAssertEqual(controller.snapshots.last, snapshotBeforeCommand)
        }
    }
}

// Test-local control of AVPlayer's existing periodic-observer injection seam.
// Real item/status/transport behavior is inherited; only clock delivery is manual.
// Returning the registered block also lets a test retain a removed generation's
// callback and verify the manager rejects an already queued stale pulse.
private final class ManuallyDrivenPeriodicPlayer: AVPlayer {
    private final class PeriodicObserver {
        let callback: @Sendable (CMTime) -> Void

        init(callback: @escaping @Sendable (CMTime) -> Void) {
            self.callback = callback
        }
    }

    private var periodicObserver: PeriodicObserver?
    var periodicCallback: (@Sendable (CMTime) -> Void)? { periodicObserver?.callback }

    override func addPeriodicTimeObserver(
        forInterval interval: CMTime,
        queue: DispatchQueue?,
        using block: @escaping @Sendable (CMTime) -> Void
    ) -> Any {
        precondition(periodicObserver == nil, "Remove the prior generation's observer before installing another")
        let observer = PeriodicObserver(callback: block)
        periodicObserver = observer
        return observer
    }

    override func removeTimeObserver(_ observer: Any) {
        guard let observer = observer as? PeriodicObserver else {
            super.removeTimeObserver(observer)
            return
        }
        precondition(periodicObserver === observer, "Remove only the installed periodic observer")
        periodicObserver = nil
    }
}

@MainActor
private final class ViewUpdateBarrier: ObservableObject {
    @Published private(set) var generation = 0
    private var expectedGeneration: Int?
    private var expectation: XCTestExpectation?

    func advance(expectation: XCTestExpectation) {
        precondition(self.expectation == nil, "Only one barrier generation may be pending")
        expectedGeneration = generation + 1
        self.expectation = expectation
        generation += 1
    }

    func didEvaluate(generation: Int) {
        guard generation == expectedGeneration else { return }
        expectedGeneration = nil
        let expectation = expectation
        self.expectation = nil
        expectation?.fulfill()
    }
}

@MainActor
private struct ViewUpdateBarrierProbe: View {
    @ObservedObject var barrier: ViewUpdateBarrier

    var body: some View {
        let generation = barrier.generation
        let _ = barrier.didEvaluate(generation: generation)
        Color.clear
    }
}

private enum TestFailure: Error { case activation }
private final class VideoStopSpyForNowPlaying { var stopCount = 0 }

// Test-only hosting seam. Keep this in an existing test source so the explicit
// PBXSourcesBuildPhase needs no changes. A failed calibration/tree read is never RED.
@MainActor
final class MiniMusicPlayerPresentationTests: XCTestCase {
    // Limited A layout slice: this does not accept the full player, auxiliary
    // controls, appearance, compact height, or Dynamic Type visual gates.
    func testHostedIndependentPlayButtonHas44PointFrameAt320And390Widths() async throws {
        for width in [CGFloat(320), CGFloat(390)] {
            try await calibrateFrameReader(width: width)
            try await withBoundaryFixture { _, _, manager, _ in
                let host = try MiniPlayerAccessibilityHost(
                    content: MiniMusicPlayerView(playback: manager) {}, viewportWidth: width)
                defer { host.close() }
                let elements = try await host.settledElements(buttonCount: 2, includingFrames: true)
                attach(elements, name: "Mini actual frames at \(width)pt")
                let open = try openElement(elements)
                guard let play = elements.first(where: { $0.traits.contains(.button) && $0.label == "播放" }),
                      play.object !== open.object else {
                    throw MiniPlayerAccessibilityHost.failure("Cannot identify independent paused transport")
                }
                // Invalid coordinates must stop before any product RED assertion.
                let playFrame = try host.validatedFrame(play)
                let openFrame = try host.validatedFrame(open)
                XCTAssertTrue(host.viewportScreenFrame.contains(playFrame),
                              "LAYOUT_RED: play frame outside \(width)pt viewport: \(playFrame)")
                XCTAssertTrue(host.viewportScreenFrame.contains(openFrame),
                              "LAYOUT_RED: open frame outside \(width)pt viewport: \(openFrame)")
                XCTAssertFalse(playFrame.intersects(openFrame), "LAYOUT_RED: independent button frames overlap")
                XCTAssertGreaterThanOrEqual(playFrame.width, 44,
                                            "LAYOUT_RED: mini play width at \(width)pt; actual \(playFrame)")
                XCTAssertGreaterThanOrEqual(playFrame.height, 44,
                                            "LAYOUT_RED: mini play height at \(width)pt; actual \(playFrame)")
            }
        }
    }

    private func calibrateFrameReader(width: CGFloat) async throws {
        // A known 64x48 button centered in a real, inset hosting viewport proves
        // both point dimensions and screen-coordinate conversion at each width.
        let host = try MiniPlayerAccessibilityHost(content:
            Button {} label: {
                Image(systemName: "play.fill").frame(width: 64, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Frame Calibration 406")
            .frame(maxWidth: .infinity, maxHeight: .infinity), viewportWidth: width)
        defer { host.close() }
        let elements = try await host.settledElements(buttonCount: 1, includingFrames: true)
        attach(elements, name: "Frame calibration at \(width)pt")
        guard let button = elements.first(where: { $0.traits.contains(.button) && $0.label == "Frame Calibration 406" }) else {
            throw MiniPlayerAccessibilityHost.failure("Known frame calibration button missing")
        }
        let actual = try host.validatedFrame(button)
        let viewport = host.viewportScreenFrame
        let expected = CGRect(x: viewport.midX - 32, y: viewport.midY - 24, width: 64, height: 48)
        guard abs(viewport.width - width) < 0.5,
              abs(actual.minX - expected.minX) < 0.5,
              abs(actual.minY - expected.minY) < 0.5,
              abs(actual.width - expected.width) < 0.5,
              abs(actual.height - expected.height) < 0.5 else {
            throw MiniPlayerAccessibilityHost.failure(
                "Frame calibration mismatch: viewport \(viewport), expected \(expected), actual \(actual)")
        }
    }

    func testHostingAccessibilityReaderCalibrationReadsCombinedTextAndActivatesButton() async throws {
        try await calibrateReader()
    }

    func testHostedMetadataTitleAndArtistAppearInOpenPlayerAccessibleName() async throws {
        try await calibrateReader()
        let title = "Metadata Title 731"
        let artist = "Metadata Artist 952"
        let metadata = MusicMetadata(title: title, artist: artist, album: nil,
                                     artworkData: nil, lyrics: nil, synchronizedLyricsData: nil)
        let label = try await hostedOpenPlayerName(metadata: metadata)
        // Only these assertions are presentation RED candidates. Neither expected
        // string is supplied to the real view through a wrapper/accessibility label.
        XCTAssertTrue(label.contains(title), "PRESENTATION_RED: open-player name lacks metadata title; actual: \(label)")
        XCTAssertTrue(label.contains(artist), "PRESENTATION_RED: open-player name lacks metadata artist; actual: \(label)")
        XCTAssertFalse(label.contains(Self.fixtureFileName),
                       "PRESENTATION_RED: file name must be replaced when metadata title exists; actual: \(label)")
    }

    func testHostedMissingMetadataFallsBackToFileName() async throws {
        try await calibrateReader()
        let label = try await hostedOpenPlayerName(metadata: nil)
        XCTAssertTrue(label.contains(Self.fixtureFileName),
                      "PRESENTATION_RED: open-player name lacks fallback file name; actual: \(label)")
    }

    func testHostedWhitespaceMetadataTrimsTitleAndArtist() async throws {
        try await calibrateReader()
        let clean = MusicMetadata(title: "Trim Title 613", artist: "Trim Artist 724", album: nil,
                                  artworkData: nil, lyrics: nil, synchronizedLyricsData: nil)
        let padded = MusicMetadata(title: " \t\nTrim Title 613\n\t ", artist: " \n\tTrim Artist 724\t\n ", album: nil,
                                   artworkData: nil, lyrics: nil, synchronizedLyricsData: nil)
        // Compare actual hosted names, preserving UIKit's own combined-label separator.
        let expected = try await hostedOpenPlayerName(metadata: clean)
        let actual = try await hostedOpenPlayerName(metadata: padded)
        XCTAssertTrue(actual.contains("Trim Title 613"), "PRESENTATION_RED: missing trimmed title")
        XCTAssertTrue(actual.contains("Trim Artist 724"), "PRESENTATION_RED: missing trimmed artist")
        XCTAssertEqual(actual, expected, "PRESENTATION_RED: surrounding metadata whitespace leaked into AX")
        XCTAssertFalse(actual.contains(Self.fixtureFileName))
    }

    func testHostedBlankTitleKeepsFileExtensionAndBlankArtistIsHidden() async throws {
        try await calibrateReader()
        let absent = try await hostedOpenPlayerName(metadata: nil)
        let blank = MusicMetadata(title: " \n\t ", artist: "\t \n", album: nil,
                                  artworkData: nil, lyrics: nil, synchronizedLyricsData: nil)
        let actual = try await hostedOpenPlayerName(metadata: blank)
        XCTAssertTrue(actual.contains(Self.fixtureFileName), "PRESENTATION_RED: fallback must retain .wav")
        XCTAssertEqual(actual, absent, "PRESENTATION_RED: blank metadata must expose only the filename fallback")
        let titleOnly = MusicMetadata(title: "Only Title 835", artist: nil, album: nil,
                                      artworkData: nil, lyrics: nil, synchronizedLyricsData: nil)
        let blankArtist = MusicMetadata(title: "Only Title 835", artist: " \t\n ", album: nil,
                                        artworkData: nil, lyrics: nil, synchronizedLyricsData: nil)
        let titleOnlyName = try await hostedOpenPlayerName(metadata: titleOnly)
        let blankArtistName = try await hostedOpenPlayerName(metadata: blankArtist)
        XCTAssertEqual(blankArtistName, titleOnlyName, "PRESENTATION_RED: blank artist must not add an AX text child")
    }

    func testHostedLibraryEnrichmentUpdatesSameHostPreservingPlaybackAndOwnership() async throws {
        try await calibrateReader()
        // Exercise both user intents. Freeze the injected player's physical clock
        // for the playing-intent case without changing manager.isPlaying.
        for playingIntent in [false, true] {
            try await withBoundaryFixture { directory, player, manager, ownership in
                if playingIntent { manager.play(); player.pause() }
                let video = VideoStopSpyForNowPlaying()
                let registration = ownership.registerVideoStop(for: video) { $0.stopCount += 1 }
                defer { registration.unregister() }
                let videoIntent = playingIntent ? nil : ownership.videoPlaybackRequested { manager.pause() }
                let host = try MiniPlayerAccessibilityHost(content: MiniMusicPlayerView(playback: manager) {})
                defer { host.close() }
                let before = try await host.settledElements(buttonCount: 2)
                let beforeOpen = try openElement(before)
                XCTAssertTrue(beforeOpen.label.contains(Self.fixtureFileName))
                XCTAssertNil(manager.currentTrack?.metadata)
                let queue = manager.queue.map(\.id)
                let index = manager.currentIndex
                let scope = manager.queueScope
                let position = manager.currentTime
                let item = try XCTUnwrap(player.currentItem)
                let itemPosition = item.currentTime().seconds
                let loadGeneration = manager.trackLoadGeneration
                XCTAssertEqual(manager.isPlaying, playingIntent)

                let library = MusicLibrary(storage: MediaLibraryStorage(
                    rootURL: directory,
                    legacyAudioURL: directory.appendingPathComponent("OldAudio"),
                    legacyVideoURL: directory.appendingPathComponent("OldVideo")
                ), metadataLoader: MusicMetadataLoader(rawItemLoader: { _ in
                    [RawMusicMetadataItem(identifier: "id3/TIT2", stringValue: "Enriched Title 946", dataValue: nil),
                     RawMusicMetadataItem(identifier: "id3/TPE1", stringValue: "Enriched Artist 157", dataValue: nil)]
                }), metadataSnapshotStore: MediaMetadataSnapshotStore(
                    fileURL: directory.appendingPathComponent("metadata.json")
                ), durationLoader: { _ in 30 })
                // Same atomic publication -> syncLibrary entry used by RootTabView.
                let observation = library.$latestReconciliationPublication.sink { publication in
                    manager.syncLibrary(publication.songs, snapshot: publication.reconciliationSnapshot)
                }
                defer { observation.cancel() }
                let snapshot = await library.refresh()
                guard snapshot.isAuthoritative, library.libraryErrorMessage == nil,
                      library.songs.first?.metadata?.title == "Enriched Title 946" else {
                    throw MiniPlayerAccessibilityHost.failure("Real library enrichment fixture did not publish metadata")
                }
                XCTAssertEqual(manager.currentTrack?.metadata?.title, "Enriched Title 946")
                // Poll the existing host for a changed, stable AX tree; never replace
                // rootView or inject a view invalidation to manufacture a refresh.
                let after = try await host.changedElements(buttonCount: 2, from: before)
                attach(after, name: "Same-host enrichment; playing intent \(playingIntent)")
                let afterOpen = try openElement(after)
                XCTAssertTrue(afterOpen.label.contains("Enriched Title 946"), "PRESENTATION_RED: title did not refresh")
                XCTAssertTrue(afterOpen.label.contains("Enriched Artist 157"), "PRESENTATION_RED: artist did not refresh")
                XCTAssertFalse(afterOpen.label.contains(Self.fixtureFileName))
                XCTAssertEqual(manager.queue.map(\.id), queue)
                XCTAssertEqual(manager.currentIndex, index)
                XCTAssertEqual(manager.queueScope, scope)
                XCTAssertEqual(manager.currentTime, position)
                XCTAssertEqual(item.currentTime().seconds, itemPosition, accuracy: 0.05)
                XCTAssertEqual(manager.isPlaying, playingIntent)
                XCTAssertTrue(player.currentItem === item)
                XCTAssertEqual(manager.trackLoadGeneration, loadGeneration)
                XCTAssertEqual(video.stopCount, 0, "Enrichment must not request music ownership again")
                if let videoIntent { XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent)) }
                XCTAssertNil(manager.playbackErrorMessage)
            }
        }
    }

    func testHostedOpenPreservesPauseAndIndependentPlayActivatesTransportOnly() async throws {
        try await calibrateReader()
        try await withBoundaryFixture { _, player, manager, ownership in
            var opens = 0
            let video = VideoStopSpyForNowPlaying()
            let registration = ownership.registerVideoStop(for: video) { $0.stopCount += 1 }
            defer { registration.unregister() }
            let videoIntent = ownership.videoPlaybackRequested { manager.pause() }
            let host = try MiniPlayerAccessibilityHost(content: MiniMusicPlayerView(playback: manager) { opens += 1 })
            defer { host.close() }
            let before = try await host.settledElements(buttonCount: 2)
            let open = try openElement(before)
            let item = try XCTUnwrap(player.currentItem)
            let queue = manager.queue.map(\.id)
            let position = manager.currentTime
            XCTAssertFalse(manager.isPlaying)
            XCTAssertTrue(open.object.accessibilityActivate(), "ACTION_RED: real open button rejected activation")
            XCTAssertEqual(opens, 1)
            XCTAssertFalse(manager.isPlaying, "ACTION_RED: opening player changed paused intent")
            XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(manager.currentTime, position)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent))
            XCTAssertEqual(video.stopCount, 0)
            let opened = try await host.settledElements(buttonCount: 2)
            XCTAssertFalse(manager.isPlaying, "ACTION_RED: open asynchronously changed paused intent")
            guard let play = opened.first(where: { $0.traits.contains(.button) && $0.label == "播放" }) else {
                XCTFail("ACTION_RED: independent play button missing after open")
                return
            }
            XCTAssertFalse(play.object === open.object)
            XCTAssertTrue(play.object.accessibilityActivate(), "ACTION_RED: real play button rejected activation")
            XCTAssertTrue(manager.isPlaying, "ACTION_RED: play did not reach manager transport action")
            XCTAssertEqual(opens, 1, "ACTION_RED: play also invoked open")
            XCTAssertEqual(video.stopCount, 1, "Actual play must acquire ownership")
            XCTAssertFalse(ownership.videoPlaybackIsAllowed(videoIntent))
            let playing = try await host.changedElements(buttonCount: 2, from: opened)
            attach(playing, name: "Independent play action AX")
            XCTAssertEqual(playing.filter { $0.traits.contains(.button) && $0.label == "暂停" }.count, 1)
            XCTAssertEqual(opens, 1)
            XCTAssertTrue(manager.isPlaying)
            XCTAssertEqual(manager.queue.map(\.id), queue)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertNil(manager.playbackErrorMessage)
        }
    }

    private func openElement(_ elements: [MiniPlayerAccessibilityHost.Element]) throws -> MiniPlayerAccessibilityHost.Element {
        let buttons = elements.filter { $0.traits.contains(.button) }
        guard buttons.count == 2,
              buttons.filter({ $0.label == "播放" || $0.label == "暂停" }).count == 1,
              let open = buttons.first(where: { $0.label != "播放" && $0.label != "暂停" }),
              !open.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MiniPlayerAccessibilityHost.failure("Cannot identify real open and transport AX buttons")
        }
        return open
    }

    private func withBoundaryFixture(
        sleepTimerClock: MusicSleepTimerClock = .live,
        scheduleSleepTimer: MusicSleepTimerSchedule? = nil,
        _ body: @MainActor (URL, AVPlayer, MusicPlaybackManager, PlaybackOwnershipCoordinator) async throws -> Void
    ) async throws {
        let suite = "MiniPlayerBoundary.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw MiniPlayerAccessibilityHost.failure("Cannot create isolated boundary defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("INFRASTRUCTURE_FAILURE: boundary fixture cleanup: \(error)") }
        }
        let url = directory.appendingPathComponent(Self.fixtureFileName)
        try writeSyntheticAudio(to: url)
        let secondURL = directory.appendingPathComponent("second-track-529.wav")
        try writeSyntheticAudio(to: secondURL)
        let player = ManuallyDrivenPeriodicPlayer()
        player.isMuted = true
        let ownership = PlaybackOwnershipCoordinator()
        let manager: MusicPlaybackManager
        if let scheduleSleepTimer {
            manager = MusicPlaybackManager(player: player, defaults: defaults, ownership: ownership,
                activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController(),
                sleepTimerClock: sleepTimerClock, scheduleSleepTimer: scheduleSleepTimer)
        } else {
            manager = MusicPlaybackManager(player: player, defaults: defaults, ownership: ownership,
                activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController(),
                sleepTimerClock: sleepTimerClock)
        }
        let track = MusicItem(url: url, duration: 30)
        defer { manager.prepareForDeletion(track); player.replaceCurrentItem(with: nil) }
        manager.updateQueue([track, MusicItem(url: secondURL, duration: 30)])
        manager.play(track)
        manager.pause()
        guard let item = player.currentItem, manager.playbackErrorMessage == nil else {
            throw MiniPlayerAccessibilityHost.failure("Boundary WAV did not load")
        }
        let ready = expectation(description: "Boundary WAV ready")
        let readyObservation = item.publisher(for: \.status, options: [.initial, .new])
            .filter { $0 == .readyToPlay }.prefix(1).sink { _ in ready.fulfill() }
        defer { readyObservation.cancel() }
        guard await XCTWaiter.fulfillment(of: [ready], timeout: 5) == .completed else {
            throw MiniPlayerAccessibilityHost.failure("Boundary WAV readiness timed out: \(item.status.rawValue)")
        }
        let generation = manager.seekCompletionGeneration
        let positioned = expectation(description: "Boundary real seek completed")
        let seekObservation = manager.seekCompletionPublisher.filter { $0 > generation }.prefix(1)
            .sink { _ in positioned.fulfill() }
        defer { seekObservation.cancel() }
        manager.seek(to: 7)
        guard await XCTWaiter.fulfillment(of: [positioned], timeout: 5) == .completed,
              abs(item.currentTime().seconds - 7) < 0.05, manager.currentTime == 7 else {
            throw MiniPlayerAccessibilityHost.failure("Boundary real seek did not settle at seven seconds")
        }
        try await body(directory, player, manager, ownership)
    }

    private static let fixtureFileName = "raw-file-418.wav"

    private func calibrateReader() async throws {
        var activations = 0
        // Same unlabelled SwiftUI Button/HStack/Image/Text topology as the mini
        // player, with two Text children to prove title AND artist can be read.
        let host = try MiniPlayerAccessibilityHost(content: Button {
            activations += 1
        } label: {
            HStack {
                Image(systemName: "music.note")
                VStack(alignment: .leading) {
                    Text("Calibration Title 163")
                    Text("Calibration Artist 284")
                }
            }
        }.buttonStyle(.plain))
        defer { host.close() }
        let elements = try await host.settledElements(buttonCount: 1)
        attach(elements, name: "Hosting accessibility calibration")
        let buttons = elements.filter { $0.traits.contains(.button) }
        guard let button = buttons.first,
              button.label.contains("Calibration Title 163"),
              button.label.contains("Calibration Artist 284") else {
            throw MiniPlayerAccessibilityHost.failure("Calibration could not read both known Text children in the button name")
        }
        let activated = button.object.accessibilityActivate()
        guard activated, activations == 1 else {
            throw MiniPlayerAccessibilityHost.failure("Calibration button activation did not reach its SwiftUI action exactly once")
        }
    }

    private func hostedOpenPlayerName(metadata: MusicMetadata?) async throws -> String {
        let suite = "MiniMusicPlayerPresentationTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            throw MiniPlayerAccessibilityHost.failure("Cannot create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { XCTFail("INFRASTRUCTURE_FAILURE: fixture cleanup: \(error)") }
        }
        let url = directory.appendingPathComponent(Self.fixtureFileName)
        try writeSyntheticAudio(to: url)
        let player = AVPlayer()
        player.isMuted = true
        let manager = MusicPlaybackManager(
            player: player, defaults: defaults, ownership: PlaybackOwnershipCoordinator(),
            activateAudioSession: {}, nowPlayingController: RecordingNowPlayingController()
        )
        let track = MusicItem(url: url, duration: 30, metadata: metadata)
        defer { manager.prepareForDeletion(track) }
        manager.updateQueue([track])
        manager.play(track)
        manager.pause()
        guard manager.currentTrack == track, manager.playbackErrorMessage == nil else {
            throw MiniPlayerAccessibilityHost.failure("Synthetic track did not load: \(manager.playbackErrorMessage ?? "no current track")")
        }
        var opens = 0
        let host = try MiniPlayerAccessibilityHost(content: MiniMusicPlayerView(playback: manager) { opens += 1 })
        defer { host.close() }
        let elements = try await host.settledElements(buttonCount: 2)
        attach(elements, name: metadata == nil ? "Mini player fallback tree" : "Mini player metadata tree")
        let buttons = elements.filter { $0.traits.contains(.button) }
        // Locate independently of the title/artist under test. The other button
        // is the real paused transport control; prove the candidate opens player.
        guard buttons.filter({ $0.label == "播放" }).count == 1,
              let open = buttons.first(where: { $0.label != "播放" }),
              !open.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MiniPlayerAccessibilityHost.failure("Cannot identify readable open-player and paused transport buttons")
        }
        let activated = open.object.accessibilityActivate()
        guard activated, opens == 1, manager.currentTrack == track,
              manager.playbackErrorMessage == nil else {
            throw MiniPlayerAccessibilityHost.failure("Open-player action or playback fixture validation failed")
        }
        return open.label
    }

    private func attach(_ elements: [MiniPlayerAccessibilityHost.Element], name: String) {
        let attachment = XCTAttachment(string: elements.map { $0.frameDiagnostic }.joined(separator: "\n"))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func writeSyntheticAudio(to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8_000,
                                         channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000),
              let samples = buffer.floatChannelData?[0] else {
            throw MiniPlayerAccessibilityHost.failure("Cannot allocate synthetic WAV")
        }
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) { samples[frame] = 0 }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        guard try AVAudioFile(forReading: url).length == 240_000 else {
            throw MiniPlayerAccessibilityHost.failure("Synthetic WAV frame count mismatch")
        }
    }
}

@MainActor
final class MiniPlayerAccessibilityHost {
    struct Element {
        let object: NSObject
        let label: String
        let identifier: String?
        let traits: UIAccessibilityTraits
        let value: String?
        let frame: CGRect
        var diagnostic: String { "\(type(of: object)) traits=\(traits.rawValue) label=\(String(reflecting: label)) identifier=\(String(reflecting: identifier))" }
        var frameDiagnostic: String { "\(diagnostic) frame=\(frame)" }
    }

    private let window: UIWindow
    private let controller: UIViewController
    private weak var previousKeyWindow: UIWindow?

    init<Content: View>(content: Content, viewportWidth: CGFloat? = nil, viewportHeight: CGFloat = 300) throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            throw Self.failure("No foreground UIWindowScene for hosting")
        }
        previousKeyWindow = scene.windows.first(where: { $0.isKeyWindow })
        controller = UIHostingController(rootView: content)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        if let viewportWidth {
            // Size the actual hosting UIView, not merely the SwiftUI content.
            // An inset child avoids the device's safe area influencing calibration.
            let container = UIViewController()
            window.rootViewController = container
            container.loadViewIfNeeded()
            container.view.frame = window.bounds
            container.addChild(controller)
            container.view.addSubview(controller.view)
            controller.view.frame = CGRect(x: (window.bounds.width - viewportWidth) / 2,
                                           y: 100, width: viewportWidth, height: viewportHeight)
            controller.didMove(toParent: container)
        } else {
            window.rootViewController = controller
        }
        window.makeKeyAndVisible()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        if let viewportWidth {
            guard abs(controller.view.bounds.width - viewportWidth) < 0.5,
                  window.screen.coordinateSpace.bounds.contains(viewportScreenFrame) else {
                close()
                throw Self.failure("Requested \(viewportWidth)pt hosting viewport does not fit this test screen")
            }
        }
    }

    var viewportScreenFrame: CGRect {
        controller.view.convert(controller.view.bounds, to: window.screen.coordinateSpace)
    }

    // Full-player layout facilities are test-only and retain the mini defaults.
    var outerScrollView: UIScrollView? {
        @MainActor
        func firstScroll(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            for child in view.subviews {
                if let scroll = firstScroll(in: child) { return scroll }
            }
            return nil
        }
        return firstScroll(in: controller.view)
    }

    // UIKit geometry and AX frames share screen coordinates. Navigation bars
    // overlay the scroll as siblings, so ancestor clipping alone is insufficient.
    var visibleNavigationBarFrames: [CGRect] {
        var frames: [CGRect] = []
        @MainActor
        func visit(_ view: UIView, clippedTo clip: CGRect, alpha: CGFloat) {
            let alpha = alpha * view.alpha
            guard !view.isHidden, alpha > 0.01 else { return }
            let frame = view.convert(view.bounds, to: window.screen.coordinateSpace)
            let visible = clip.intersection(frame)
            if view is UINavigationBar, !visible.isNull, !visible.isEmpty {
                frames.append(visible)
            }
            let childClip = view.clipsToBounds ? visible : clip
            for child in view.subviews { visit(child, clippedTo: childClip, alpha: alpha) }
        }
        visit(controller.view, clippedTo: viewportScreenFrame, alpha: 1)
        return frames
    }

    func visibleScrollFrame(_ scroll: UIScrollView) -> CGRect {
        var visible = viewportScreenFrame
        var ancestor: UIView? = scroll
        while let view = ancestor {
            if view === scroll || view.clipsToBounds {
                visible = visible.intersection(view.convert(view.bounds, to: window.screen.coordinateSpace))
            }
            ancestor = view.superview
        }
        // A top NavigationBar occludes everything through its visible bottom.
        // Do not subtract adjustedContentInset: it describes scroll positioning,
        // not another screen-space occluder. No assumed navigation-bar height.
        for bar in visibleNavigationBarFrames where visible.intersects(bar) {
            let top = max(visible.minY, bar.maxY)
            visible = CGRect(x: visible.minX, y: top, width: visible.width,
                             height: max(0, visible.maxY - top))
        }
        return visible
    }

    func presentedElements() throws -> [Element]? {
        @MainActor
        func presented(in controller: UIViewController) -> UIViewController? {
            if let modal = controller.presentedViewController, !modal.isBeingDismissed { return modal }
            return controller.children.compactMap { presented(in: $0) }.first
        }
        guard let modal = presented(in: controller) else { return nil }
        modal.view.layoutIfNeeded()
        return try readElements(in: modal.view)
    }

    func layoutSnapshot(observe: (([Element]) -> Void)? = nil) async throws -> [Element] {
        var previous: [String] = []
        var stable = 0
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 50_000_000)
            controller.view.layoutIfNeeded()
            let elements = try readElements()
            // Export actual reads before settlement can time out. List contentSize may
            // still be estimated even when the visible AX topology is unchanged.
            observe?(elements)
            let scrollSignature = outerScrollView.map {
                "offset=\($0.contentOffset) size=\($0.contentSize) bounds=\($0.bounds) inset=\($0.adjustedContentInset)"
            } ?? "scroll=nil"
            let signature = elements.map { $0.frameDiagnostic } + [scrollSignature]
            stable = !elements.isEmpty && signature == previous ? stable + 1 : 0
            if stable >= 3 { return elements }
            previous = signature
        }
        throw Self.failure("Full-player AX frame tree did not settle")
    }

    func renderedAttachment(name: String) throws -> XCTAttachment {
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            rendered = controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        guard rendered else { throw Self.failure("Mounted hierarchy rendering failed") }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        return attachment
    }

    func validatedFrame(_ element: Element) throws -> CGRect {
        let frame = element.frame
        guard !frame.isNull, !frame.isInfinite,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width > 0, frame.height > 0 else {
            throw Self.failure("Invalid AX frame; not layout RED: \(element.frameDiagnostic)")
        }
        return frame
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()
    }

    // Poll for a stable readable topology, never for the expected product text.
    // Timeout/empty/partial trees throw an infrastructure error before assertions.
    func settledElements(buttonCount: Int, includingFrames: Bool = false) async throws -> [Element] {
        var previous: [String] = []
        var stableReads = 0
        var last: [Element] = []
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 50_000_000)
            controller.view.layoutIfNeeded()
            last = try readElements()
            let signature = last.map { includingFrames ? $0.frameDiagnostic : $0.diagnostic }
            if last.filter({ $0.traits.contains(.button) }).count == buttonCount,
               !last.isEmpty, signature == previous {
                stableReads += 1
                if stableReads >= 3 { return last }
            } else {
                stableReads = 0
            }
            previous = signature
        }
        throw Self.failure("Empty, incomplete, or unstable accessibility tree (expected \(buttonCount) buttons). Last read:\n"
                           + last.map { $0.diagnostic }.joined(separator: "\n"))
    }

    // A topology-only settle can return the old tree before SwiftUI processes
    // objectWillChange. Require an actual AX change, then stable reads. Timeouts
    // are explicitly unclassified infrastructure/synchronization failures, not RED.
    func changedElements(buttonCount: Int, from baseline: [Element]) async throws -> [Element] {
        let original = baseline.map { $0.diagnostic }
        var previous = original
        var stableReads = 0
        var last: [Element] = []
        for _ in 0..<100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            controller.view.layoutIfNeeded()
            last = try readElements()
            let signature = last.map { $0.diagnostic }
            if last.filter({ $0.traits.contains(.button) }).count == buttonCount,
               signature != original, signature == previous {
                stableReads += 1
                if stableReads >= 3 { return last }
            } else { stableReads = 0 }
            previous = signature
        }
        throw Self.failure("Timed out awaiting changed stable AX on the same host; stale product output versus AX scheduling requires diagnosis. Baseline:\n"
                           + original.joined(separator: "\n") + "\nLast read:\n"
                           + last.map { $0.diagnostic }.joined(separator: "\n"))
    }

    // SwiftUI AX leaves can implement the getter without declaring UIKit's
    // identification protocol. Read the actual property, never infer it from label.
    static func readIdentifier(_ object: NSObject) -> String? {
        let getter = NSSelectorFromString("accessibilityIdentifier")
        guard object.responds(to: getter) else { return nil }
        return object.perform(getter)?.takeUnretainedValue() as? String
    }

    private func readElements(in root: UIView? = nil) throws -> [Element] {
        var visited = Set<ObjectIdentifier>()
        var result: [Element] = []
        @MainActor
        func visit(_ object: NSObject, depth: Int) throws {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            guard depth < 64, visited.count <= 2_048 else {
                throw Self.failure("Accessibility traversal exceeded bounds")
            }
            if let view = object as? UIView, view.isHidden || view.alpha <= 0.01 { return }
            guard !object.accessibilityElementsHidden else { return }
            if object.isAccessibilityElement {
                result.append(Element(object: object, label: object.accessibilityLabel ?? "",
                                      identifier: Self.readIdentifier(object),
                                      traits: object.accessibilityTraits, value: object.accessibilityValue, frame: object.accessibilityFrame))
                return // Respect combined accessibility leaves; do not invent a name from descendants.
            }
            if let children = object.accessibilityElements, !children.isEmpty {
                for child in children {
                    guard let child = child as? NSObject else {
                        throw Self.failure("Non-NSObject accessibility child")
                    }
                    try visit(child, depth: depth + 1)
                }
                return
            }
            let count = object.accessibilityElementCount()
            if count != NSNotFound, count > 0 {
                guard count <= 2_048 else { throw Self.failure("Invalid accessibility container count: \(count)") }
                for index in 0..<count {
                    guard let child = object.accessibilityElement(at: index) as? NSObject else {
                        throw Self.failure("Missing accessibility container child at \(index)")
                    }
                    try visit(child, depth: depth + 1)
                }
                return
            }
            if let view = object as? UIView {
                for child in view.subviews { try visit(child, depth: depth + 1) }
            }
        }
        try visit(root ?? controller.view, depth: 0)
        return result
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "MiniPlayerHosting.INFRASTRUCTURE_FAILURE", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "INFRASTRUCTURE_FAILURE (not presentation RED): \(message)"])
    }
}

// First content-first slice: real hosted actions, intentionally UNRUN until the
// parent captures RED. New identifiers are string contracts, not production APIs.
extension MiniMusicPlayerPresentationTests {
    func testHostedPlayerContentToggleSwitchesArtworkToSynchronizedLyricsAndBack() async throws {
        try await calibrateReader()
        try await withContentFirstPlayerHost { host, manager in
            var tree = try await host.layoutSnapshot()
            attach(tree, name: "content-first-before-toggle")
            guard activateContentFirstEntry("music-player-content-toggle", label: "显示歌词", in: tree) else { return }
            tree = try await host.layoutSnapshot()
            XCTAssertTrue(tree.contains { $0.identifier == "music-detail-lyrics-text" || $0.label == "Cue" },
                          "CONTENT_RED: activating lyrics must expose the real synchronized lyrics")
            XCTAssertFalse(tree.contains { $0.label == "暂无专辑封面" },
                           "CONTENT_RED: lyrics must replace artwork in the main content area")
            XCTAssertTrue(tree.contains { $0.label == "播放" && $0.traits.contains(.button) },
                          "CONTENT_RED: transport must remain available in lyrics mode")
            guard activateContentFirstEntry("music-player-content-toggle", label: "显示封面", in: tree) else { return }
            tree = try await host.layoutSnapshot()
            XCTAssertTrue(tree.contains { $0.label == "暂无专辑封面" },
                          "CONTENT_RED: switching back must restore artwork")
            XCTAssertFalse(tree.contains { $0.identifier == "music-detail-lyrics-text" || $0.label == "Cue" },
                           "CONTENT_RED: artwork mode must replace the lyrics body")
            XCTAssertFalse(manager.isPlaying, "Content switching must not resume playback")
            attach(tree, name: "content-first-returned-to-artwork")
        }
    }

    func testHostedPlayerMoreEntryRevealsSleepAndBluetoothExplanation() async throws {
        try await calibrateReader()
        try await withContentFirstPlayerHost { host, manager in
            let tree = try await host.layoutSnapshot()
            attach(tree, name: "content-first-before-more")
            let completion = manager.completionMode
            let sleep = manager.sleepTimerMode
            guard activateContentFirstEntry("music-player-more-entry", label: "更多", in: tree) else { return }
            let expectedLabels = ["睡眠定时",
                                  "播放时会暂时使用蓝牙歌曲标题字段显示当前歌词，实际效果可能因车型而异。"]
            var destination: [MiniPlayerAccessibilityHost.Element] = []
            for _ in 0..<20 {
                let root = try await host.layoutSnapshot()
                destination = try host.presentedElements() ?? root
                if expectedLabels.allSatisfy({ label in destination.contains { $0.label == label } }) { break }
            }
            for label in expectedLabels {
                XCTAssertTrue(destination.contains { $0.label == label },
                              "MORE_RED: activating more must expose \(label)")
            }
            XCTAssertFalse(destination.contains { $0.label == "蓝牙车载歌词（实验）" })
            XCTAssertEqual(manager.completionMode, completion, "Opening more must not change completion")
            XCTAssertEqual(manager.sleepTimerMode, sleep, "Opening more must not change sleep mode")
            XCTAssertFalse(manager.isPlaying, "Opening more must not resume playback")
            attach(destination, name: "content-first-more-destination")
        }
    }

    private func activateContentFirstEntry(
        _ identifier: String, label: String, in tree: [MiniPlayerAccessibilityHost.Element],
        file: StaticString = #filePath, line: UInt = #line
    ) -> Bool {
        let matches = tree.filter {
            $0.identifier == identifier ||
                ($0.identifier == nil && $0.label == label && $0.traits.contains(.button))
        }
        XCTAssertEqual(matches.count, 1, "ENTRY_RED: expected one reachable \(identifier) (\(label))", file: file, line: line)
        guard matches.count == 1, let entry = matches.first else { return false }
        let activated = entry.object.accessibilityActivate()
        XCTAssertTrue(activated, "ACTION_RED: \(identifier) rejected AX activation", file: file, line: line)
        return activated
    }

    private func withContentFirstPlayerHost(
        _ body: @MainActor (MiniPlayerAccessibilityHost, MusicPlaybackManager) async throws -> Void
    ) async throws {
        try await withBoundaryFixture { directory, _, manager, _ in
            let suite = "ContentFirstPlayer.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            // Existing synthetic WAV and SYLT encoding; no user media or new service.
            let payload = Data([0x00, 0x65, 0x6E, 0x67, 0x02, 0x01, 0x00,
                                0x43, 0x75, 0x65, 0x00, 0, 0, 0, 0])
            let metadata = MusicMetadata(title: "Content switch fixture", artist: "Fixture artist", album: nil,
                artworkData: nil, lyrics: nil, synchronizedLyricsData: payload)
            _ = try XCTUnwrap(metadata.synchronizedLyrics, "Fixture must contain decoded SYLT")
            let track = MusicItem(url: directory.appendingPathComponent(Self.fixtureFileName),
                                  duration: 30, metadata: metadata)
            manager.updateQueue([track])
            manager.play(track)
            manager.pause()
            let host = try MiniPlayerAccessibilityHost(content:
                MusicPlayerView(playback: manager, favorites: MusicFavoritesStore(defaults: defaults)))
            defer { host.close() }
            try await body(host, manager)
        }
    }
}

// A major-layout contract. These assertions are UNRUN until the parent executes
// them: passing assertions are regression protection, never retroactive RED.
// Group styling, whitespace rhythm and title/artist emphasis require image review.
extension MiniMusicPlayerPresentationTests {
    func testHostedPlayerLayoutAt320Standard() async throws {
        try await checkPlayerLayout(size: .large, name: "320-standard")
    }

    func testHostedPlayerLayoutAt320Accessibility5() async throws {
        try await checkPlayerLayout(size: .accessibility5, name: "320-accessibility5")
    }

    private func calibratePlayerScroll(size: DynamicTypeSize) async throws {
        try await calibrateFrameReader(width: 320)
        let probe = UIButton()
        probe.accessibilityLabel = "Identifier calibration label"
        probe.accessibilityIdentifier = "identifier-calibration-probe"
        guard MiniPlayerAccessibilityHost.readIdentifier(probe) == "identifier-calibration-probe",
              MiniPlayerAccessibilityHost.readIdentifier(NSObject()) == nil else {
            throw MiniPlayerAccessibilityHost.failure("AX identifier getter calibration failed")
        }
        let host = try MiniPlayerAccessibilityHost(content:
            ScrollView {
                VStack(spacing: 0) {
                    Button {} label: {
                        Image(systemName: "play.fill").frame(width: 64, height: 48)
                    }.buttonStyle(.plain).accessibilityLabel("Scroll calibration top")
                        .accessibilityIdentifier("scroll-calibration-top")
                    Color.clear.frame(height: 1000)
                    Button {} label: {
                        Image(systemName: "play.fill").frame(width: 64, height: 48)
                    }.buttonStyle(.plain).accessibilityLabel("Scroll calibration bottom")
                        .accessibilityIdentifier("scroll-calibration-bottom")
                }
            }.environment(\.dynamicTypeSize, size), viewportWidth: 320, viewportHeight: 568)
        defer { host.close() }
        let before = try await host.layoutSnapshot()
        let scroll = try XCTUnwrap(host.outerScrollView, "INFRASTRUCTURE_FAILURE: calibration scroll missing")
        let top = try XCTUnwrap(before.first { $0.label == "Scroll calibration top" })
        let topFrame = try host.validatedFrame(top)
        guard host.visibleScrollFrame(scroll).contains(topFrame), scroll.contentSize.height > scroll.bounds.height else {
            throw MiniPlayerAccessibilityHost.failure("Calibration top/scroll viewport invalid")
        }
        if let bottom = before.first(where: { $0.label == "Scroll calibration bottom" }),
           host.visibleScrollFrame(scroll).intersects(bottom.frame) {
            throw MiniPlayerAccessibilityHost.failure("Calibration offscreen bottom unexpectedly visible")
        }
        let offset = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
        scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        let after = try await host.layoutSnapshot()
        let bottom = try XCTUnwrap(after.first { $0.label == "Scroll calibration bottom" })
        // A missing SwiftUI getter permits exact-label matching; a returned but
        // incorrect identifier is a reader failure, not a product layout failure.
        for (element, expected) in [(top, "scroll-calibration-top"), (bottom, "scroll-calibration-bottom")] {
            guard element.identifier == nil || element.identifier == expected else {
                throw MiniPlayerAccessibilityHost.failure("SwiftUI identifier calibration failed: \(element.diagnostic)")
            }
        }
        attach([top, bottom], name: "calibrated-scroll-identities-320")
        guard scroll.contentOffset.y > 0,
              host.visibleScrollFrame(scroll).contains(try host.validatedFrame(bottom)) else {
            throw MiniPlayerAccessibilityHost.failure("Calibration bottom did not become fully visible")
        }
        if let movedTop = after.first(where: { $0.label == "Scroll calibration top" }) {
            guard !host.visibleScrollFrame(scroll).intersects(movedTop.frame),
                  abs((topFrame.minY - movedTop.frame.minY) - scroll.contentOffset.y) < 1 else {
                throw MiniPlayerAccessibilityHost.failure("Offscreen AX was mistaken for visible content")
            }
        }
        add(try host.renderedAttachment(name: "calibrated-scroll-320"))
    }

    func testHostedNavigationToolbarOcclusionAndScrollCalibrationAt320() async throws {
        for size: DynamicTypeSize in [.large, .accessibility5] {
            _ = try await calibrateNavigationToolbar(size: size)
        }
    }

    // Same OS, host dimensions, Dynamic Type, title and native toolbar placements
    // as the player. Native AX bounds are a reference, not a 44pt touch region.
    private func calibrateNavigationToolbar(size: DynamicTypeSize) async throws -> [String: CGRect] {
        var moreActivations = 0
        var doneActivations = 0
        let host = try MiniPlayerAccessibilityHost(content:
            NavigationStack {
                ScrollView {
                    VStack(spacing: 0) {
                        Color.clear.frame(height: 500)
                        Button {} label: {
                            Text("Middle probe").frame(width: 200, height: 48)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("navigation-scroll-middle-probe")
                        Color.clear.frame(height: 1000)
                    }
                }
                .navigationTitle("正在播放")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("完成") { doneActivations += 1 }
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { moreActivations += 1 } label: {
                            Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel("更多")
                    }
                }
            }.environment(\.dynamicTypeSize, size), viewportWidth: 320, viewportHeight: 568)
        defer { host.close() }
        _ = try await host.layoutSnapshot()
        let scroll = try XCTUnwrap(host.outerScrollView, "INFRASTRUCTURE_FAILURE: navigation scroll missing")
        scroll.setContentOffset(CGPoint(x: 0, y: 500), animated: false)
        var tree = try await host.layoutSnapshot()
        @MainActor
        func probe(_ tree: [MiniPlayerAccessibilityHost.Element]) throws -> CGRect {
            let element = try XCTUnwrap(tree.first { $0.identifier == "navigation-scroll-middle-probe" || $0.label == "Middle probe" },
                                       "INFRASTRUCTURE_FAILURE: middle probe missing")
            return try host.validatedFrame(element)
        }
        let bar = try XCTUnwrap(host.visibleNavigationBarFrames.first,
                               "INFRASTRUCTURE_FAILURE: real NavigationStack bar missing")
        let initial = try probe(tree)
        // Put half the probe behind the measured bar, with no assumed inset.
        let behindOffset = scroll.contentOffset.y + initial.minY - (bar.maxY - initial.height / 2)
        scroll.setContentOffset(CGPoint(x: 0, y: behindOffset), animated: false)
        tree = try await host.layoutSnapshot()
        let behind = try probe(tree)
        let scrollWindow = try XCTUnwrap(scroll.window)
        let rawScroll = scroll.convert(scroll.bounds, to: scrollWindow.screen.coordinateSpace)
        guard abs(scroll.contentOffset.y - behindOffset) < 1,
              rawScroll.contains(behind), bar.intersects(behind),
              !host.visibleScrollFrame(scroll).contains(behind) else {
            throw MiniPlayerAccessibilityHost.failure("Navigation calibration must reject a probe inside raw scroll bounds but behind the visible bar")
        }
        attach(tree, name: "navigation-calibration-behind-bar-\(size)")
        add(try host.renderedAttachment(name: "navigation-calibration-behind-bar-\(size)"))
        let visible = host.visibleScrollFrame(scroll)
        let middleOffset = scroll.contentOffset.y + behind.midY - visible.midY
        scroll.setContentOffset(CGPoint(x: 0, y: middleOffset), animated: false)
        tree = try await host.layoutSnapshot()
        let middle = try probe(tree)
        guard abs(scroll.contentOffset.y - middleOffset) < 1,
              host.visibleScrollFrame(scroll).contains(middle),
              !host.visibleNavigationBarFrames.contains(where: { $0.intersects(middle) }),
              abs((behind.minY - middle.minY) - (middleOffset - behindOffset)) < 1 else {
            throw MiniPlayerAccessibilityHost.failure("Navigation calibration middle probe not reachable in unified screen coordinates")
        }
        var frames: [String: CGRect] = [:]
        for (identifier, label) in [("music-player-more-entry", "更多"), ("native-reference-done", "完成")] {
            let element = try XCTUnwrap(tree.first { $0.label == label && $0.traits.contains(.button) })
            let frame = try host.validatedFrame(element)
            guard host.viewportScreenFrame.contains(frame),
                  host.visibleNavigationBarFrames.contains(where: { $0.contains(frame) }),
                  !frame.intersects(middle), element.object.accessibilityActivate() else {
                throw MiniPlayerAccessibilityHost.failure("Native toolbar reference visibility/activation failed: \(label)")
            }
            frames[identifier] = frame
        }
        guard moreActivations == 1, doneActivations == 1 else {
            throw MiniPlayerAccessibilityHost.failure("Native reference actions or nonoverlap calibration failed")
        }
        attach(tree, name: "navigation-calibration-middle-native-reference-\(size)")
        add(try host.renderedAttachment(name: "navigation-calibration-middle-\(size)"))
        return frames
    }

    func testHostedPlayerNativeToolbarAccessibilityActivateOpensDestinationsAt320() async throws {
        // Real AX actions, native presentation state and handler completion;
        // no physical touch is injected.
        for size: DynamicTypeSize in [.large, .accessibility5] {
            let reference = try await calibrateNavigationToolbar(size: size)
            try await withBoundaryFixture { _, _, manager, _ in
                let suite = "NativeToolbarAction.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let projection = MusicPlaybackTimelineProjection(timeline: manager.timeline)
                var processedIDs: [UUID] = []
                var pendingDismissal: XCTestExpectation?
                let host = try MiniPlayerAccessibilityHost(content:
                    MusicPlayerView(playback: manager, favorites: MusicFavoritesStore(defaults: defaults),
                        timelineProjection: projection, moreDismissalProcessed: { id in
                            processedIDs.append(id)
                            pendingDismissal?.fulfill()
                        })
                        .environment(\.dynamicTypeSize, size), viewportWidth: 320, viewportHeight: 568)
                defer { host.close() }
                var publications: [TimeInterval] = []
                let observation = projection.$currentTime.dropFirst().sink { publications.append($0) }
                defer { observation.cancel() }

                // Fixed queue + native toolbar More; keep the selector for the parent runner.
                let identifier = "music-queue-entry"
                let entry = try await self.lifecycleButton(in: host, modal: false, label: "播放队列")
                XCTAssertTrue(entry.identifier == identifier || entry.identifier == nil)
                let frame = try host.validatedFrame(entry)
                XCTAssertTrue(host.viewportScreenFrame.contains(frame), "LAYOUT_CONTRACT: fixed queue entry clipped")
                XCTAssertGreaterThanOrEqual(frame.width, 44)
                XCTAssertGreaterThanOrEqual(frame.height, 44)
                _ = try self.assertFixedControls(host, tree: host.lifecycleElements(modal: false))
                XCTAssertNil(try host.presentedElements(), "Fixture already has a presented destination")
                XCTAssertTrue(entry.object.accessibilityActivate(), "ACTION_RED: \(identifier) rejected AX activation")
                let destination = try await host.completedNativePresentation(destinationLabel: "播放队列")
                XCTAssertTrue(destination.contains { $0.label == "播放队列" },
                              "ACTION_RED: \(identifier) did not present 播放队列")
                self.attach(destination, name: "native-toolbar-AX-destination-\(identifier)-\(size)")
                let queueDone = try await self.lifecycleButton(in: host, modal: true, label: "完成")
                XCTAssertTrue(queueDone.object.accessibilityActivate(), "Queue Done rejected AX activation")
                _ = try await host.completedNativePresentation(destinationLabel: nil)

                let more = try await self.lifecycleButton(in: host, modal: false,
                    identifier: "music-player-more-entry", label: "更多")
                let moreFrame = try host.validatedFrame(more)
                XCTAssertTrue(host.visibleNavigationBarFrames.contains { $0.contains(moreFrame) })
                let expected = try XCTUnwrap(reference["music-player-more-entry"])
                XCTAssertEqual(moreFrame.width, expected.width, accuracy: 1)
                XCTAssertEqual(moreFrame.height, expected.height, accuracy: 1)
                XCTAssertTrue(more.object.accessibilityActivate(), "More must remain usable after queue dismissal")
                _ = try await host.completedNativePresentation(destinationLabel: "睡眠定时")
                let done = try await self.lifecycleButton(in: host, modal: true, label: "完成")
                let processed = self.expectation(description: "Normal More handler returned")
                pendingDismissal = processed
                XCTAssertTrue(done.object.accessibilityActivate())
                try await self.lifecycleBarrier([processed], "normal More handler completion")
                pendingDismissal = nil
                _ = try await host.completedNativePresentation(destinationLabel: nil)
                XCTAssertEqual(processedIDs.count, 1)
                XCTAssertEqual(Set(processedIDs).count, 1)
                let resumedCount = publications.count
                try await self.lifecycleSeek(manager, to: 17)
                XCTAssertEqual(projection.currentTime, 17)
                XCTAssertEqual(publications.count, resumedCount + 1,
                               "More dismissal must preserve detail lyrics subscription")
            }
        }
        let pending = XCTAttachment(string: "PENDING: native toolbar physical 44pt hit acceptance. AX reference geometry and accessibilityActivate do not prove physical touch coverage.")
        pending.name = "PENDING-native-toolbar-physical-44pt"
        pending.lifetime = .keepAlways
        add(pending)
    }

    private func checkPlayerLayout(size: DynamicTypeSize, name: String) async throws {
        try await calibratePlayerScroll(size: size)
        let nativeToolbarFrames = try await calibrateNavigationToolbar(size: size)
        try await withBoundaryFixture { directory, _, manager, _ in
            let suite = "PlayerLayout.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let title = "晚风来信 A Long Journey Home 长标题排版校准"
            let artist = "林间回声 Artist Ensemble"
            let payload = Data([0x00, 0x65, 0x6E, 0x67, 0x02, 0x01, 0x00,
                                0x43, 0x75, 0x65, 0x00, 0, 0, 0, 0])
            let metadata = MusicMetadata(title: title, artist: artist, album: "夜行专辑",
                artworkData: nil, lyrics: nil, synchronizedLyricsData: payload)
            let track = MusicItem(url: directory.appendingPathComponent(Self.fixtureFileName),
                                  duration: 30, metadata: metadata)
            guard metadata.synchronizedLyrics != nil else {
                throw MiniPlayerAccessibilityHost.failure("Synchronized lyric fixture failed to decode")
            }
            manager.updateQueue([track])
            manager.play(track)
            manager.pause()
            guard manager.currentTrack?.metadata?.title == title, manager.playbackErrorMessage == nil else {
                throw MiniPlayerAccessibilityHost.failure("Full-player metadata fixture did not load")
            }
            let host = try MiniPlayerAccessibilityHost(content:
                MusicPlayerView(playback: manager, favorites: MusicFavoritesStore(defaults: defaults))
                    .environment(\.dynamicTypeSize, size), viewportWidth: 320, viewportHeight: 568)
            defer { host.close() }
            var elements = try await host.layoutSnapshot()
            let scroll = try XCTUnwrap(host.outerScrollView, "INFRASTRUCTURE_FAILURE: actual player scroll missing")
            let viewport = host.viewportScreenFrame
            guard abs(viewport.width - 320) < 0.5, abs(viewport.height - 568) < 0.5,
                  !host.visibleScrollFrame(scroll).isEmpty else {
                throw MiniPlayerAccessibilityHost.failure("Actual player visible viewport invalid")
            }
            let transportLabels = ["上一首", "播放", "下一首"]
            @MainActor
            func transport(_ tree: [MiniPlayerAccessibilityHost.Element]) throws -> [CGRect] {
                try transportLabels.map { label in
                    let matches = tree.filter { $0.label == label && $0.traits.contains(.button) }
                    guard matches.count == 1 else {
                        throw MiniPlayerAccessibilityHost.failure("Cannot identify actual transport: \(label)")
                    }
                    return try host.validatedFrame(matches[0])
                }
            }
            add(try host.renderedAttachment(name: "player-\(name)-initial-mounted"))
            attach(elements, name: "player-\(name)-initial-AX")
            let initialTransport = try transport(elements)
            let identifiers = ["music-player-favorite-toggle", "music-player-content-toggle"]
            let labels = [title, artist, "夜行专辑"]
            let targets = identifiers + labels
            let exactLabels = ["music-player-favorite-toggle": "收藏", "music-player-content-toggle": "显示歌词"]
            let initialFixed = try self.assertFixedControls(host, tree: elements)
            for (key, label) in [("music-player-more-entry", "更多"), ("native-reference-done", "完成")] {
                let entry = try self.routeElement(elements, id: key == "native-reference-done" ? nil : key, label: label)
                let frame = try host.validatedFrame(entry)
                let reference = try XCTUnwrap(nativeToolbarFrames[key])
                XCTAssertTrue(host.visibleNavigationBarFrames.contains { $0.contains(frame) })
                XCTAssertEqual(frame.width, reference.width, accuracy: 1)
                XCTAssertEqual(frame.height, reference.height, accuracy: 1)
            }
            var observed = Set<String>()
            var reached = Set<String>()
            var textSlices: [String: [ClosedRange<CGFloat>]] = [:]
            var textHeights: [String: CGFloat] = [:]
            var diagnostics: [String] = ["PENDING: favorite AX 22x21 vs physical hit region is unresolved; original AX >=44 assertions retained. Native toolbar and favorite physical touch coverage are not established by AX activation."]
            var step = 0
            while true {
                let visibleScroll = host.visibleScrollFrame(scroll)
                let currentTransport = try transport(elements)
                _ = try self.assertFixedControls(host, tree: elements, baseline: initialFixed)
                diagnostics.append("step=\(step) viewport=\(viewport) scrollVisible=\(visibleScroll) offset=\(scroll.contentOffset)")
                diagnostics += elements.map { $0.frameDiagnostic }
                add(try host.renderedAttachment(name: "player-\(name)-scroll-\(step)"))
                for (index, frame) in currentTransport.enumerated() {
                    XCTAssertTrue(viewport.contains(frame), "LAYOUT_CONTRACT: transport clipped: \(frame)")
                    XCTAssertGreaterThanOrEqual(frame.width, 44)
                    XCTAssertGreaterThanOrEqual(frame.height, 44)
                    XCTAssertEqual(frame.minY, initialTransport[index].minY, accuracy: 1,
                                   "REGRESSION: bottom transport moved while scrolling")
                    XCTAssertEqual(frame.minX, initialTransport[index].minX, accuracy: 1)
                    XCTAssertEqual(frame.width, initialTransport[index].width, accuracy: 1)
                    XCTAssertEqual(frame.height, initialTransport[index].height, accuracy: 1)
                    if index > 0 {
                        XCTAssertLessThanOrEqual(currentTransport[index - 1].maxX, frame.minX,
                                                 "REGRESSION: previous/play/next order or overlap")
                    }
                }
                var visibleControls: [(String, CGRect)] = []
                for target in targets {
                    let matches = elements.filter {
                        if identifiers.contains(target) {
                            return $0.identifier == target ||
                                ($0.identifier == nil && $0.label == exactLabels[target] && $0.traits.contains(.button))
                        }
                        return $0.label == target
                    }
                    guard matches.count <= 1 else {
                        throw MiniPlayerAccessibilityHost.failure("Ambiguous player AX identity: \(target)")
                    }
                    guard let element = matches.first else { continue } // Offscreen SwiftUI AX children may be omitted.
                    observed.insert(target)
                    diagnostics.append("matched target=\(target) via=\(element.identifier == target ? "identifier" : "exact-label")")
                    var frame = try host.validatedFrame(element)
                    if labels.contains(target), frame.height > visibleScroll.height + 0.5 {
                        // Use only the existing, screenshot-backed traversal samples.
                        // Node-relative slices must cover the entire height with no gaps;
                        // a full AX label identifies text but cannot prove rendered glyphs.
                        if let height = textHeights[target] {
                            XCTAssertEqual(frame.height, height, accuracy: 0.5)
                        }
                        textHeights[target] = frame.height
                        let visible = frame.intersection(visibleScroll)
                        if !visible.isNull, !visible.isEmpty {
                            XCTAssertGreaterThanOrEqual(frame.minX, visibleScroll.minX - 0.5)
                            XCTAssertLessThanOrEqual(frame.maxX, visibleScroll.maxX + 0.5)
                            textSlices[target, default: []].append(
                                (visible.minY - frame.minY)...(visible.maxY - frame.minY))
                            diagnostics.append("text slice target=\(target) step=\(step) local=\(visible.minY - frame.minY)...\(visible.maxY - frame.minY)")
                        }
                        continue
                    }
                    if !visibleScroll.insetBy(dx: -0.5, dy: -0.5).contains(frame) {
                        // Center the actual frame, bounded to three attempts. Restore
                        // discovery offset so a long AX label never substitutes for visibility.
                        let saved = scroll.contentOffset
                        for _ in 0..<3 {
                            let band = host.visibleScrollFrame(scroll)
                            let minimum = -scroll.adjustedContentInset.top
                            let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                            let y = min(maximum, max(minimum, scroll.contentOffset.y + frame.midY - band.midY))
                            scroll.setContentOffset(CGPoint(x: saved.x, y: y), animated: false)
                            let directed = try await host.layoutSnapshot()
                            _ = try self.assertFixedControls(host, tree: directed, baseline: initialFixed)
                            diagnostics.append("directed target=\(target) offset=\(scroll.contentOffset) band=\(host.visibleScrollFrame(scroll))")
                            diagnostics += directed.map { $0.frameDiagnostic }
                            if let fresh = directed.first(where: { $0.identifier == target || ($0.identifier == nil && $0.label == exactLabels[target]) || $0.label == target }) {
                                frame = try host.validatedFrame(fresh)
                                if host.visibleScrollFrame(scroll).insetBy(dx: -0.5, dy: -0.5).contains(frame) {
                                    reached.insert(target)
                                    if identifiers.contains(target) {
                                        XCTAssertGreaterThanOrEqual(frame.width, 44, "LAYOUT_CONTRACT: \(target) \(frame)")
                                        XCTAssertGreaterThanOrEqual(frame.height, 44, "LAYOUT_CONTRACT: \(target) \(frame)")
                                    }
                                    break
                                }
                            }
                        }
                        scroll.setContentOffset(saved, animated: false)
                        elements = try await host.layoutSnapshot()
                        continue
                    }
                    reached.insert(target)
                    if identifiers.contains(target) {
                        visibleControls.append((target, frame))
                        // AX glyph vs physical favorite hit target remains unresolved.
                        // Keep the 44pt target; allow only screen-coordinate floating-point noise.
                        XCTAssertGreaterThanOrEqual(frame.width + 1e-9, 44, "LAYOUT_CONTRACT: \(target); raw frame=\(frame); numerical tolerance=1e-9pt")
                        XCTAssertGreaterThanOrEqual(frame.height + 1e-9, 44, "LAYOUT_CONTRACT: \(target); raw frame=\(frame); numerical tolerance=1e-9pt")
                    }
                }
                for i in visibleControls.indices {
                    for j in visibleControls.indices where j > i {
                        XCTAssertFalse(visibleControls[i].1.insetBy(dx: 0.5, dy: 0.5).intersects(visibleControls[j].1),
                                       "LAYOUT_CONTRACT: overlapping \(visibleControls[i].0) / \(visibleControls[j].0)")
                    }
                    for frame in currentTransport {
                        XCTAssertFalse(visibleControls[i].1.insetBy(dx: 0.5, dy: 0.5).intersects(frame),
                                       "LAYOUT_CONTRACT: auxiliary entry overlaps fixed transport")
                    }
                }
                let maximum = max(-scroll.adjustedContentInset.top,
                    scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                if scroll.contentOffset.y >= maximum - 0.5 { break }
                guard step < 40 else { throw MiniPlayerAccessibilityHost.failure("Scroll traversal exceeded 40 steps") }
                let next = min(maximum, scroll.contentOffset.y + max(24, visibleScroll.height / 3))
                scroll.setContentOffset(CGPoint(x: 0, y: next), animated: false)
                elements = try await host.layoutSnapshot()
                guard abs(scroll.contentOffset.y - next) < 1 else {
                    throw MiniPlayerAccessibilityHost.failure("Actual outer scroll did not reach requested offset")
                }
                step += 1
            }
            for (target, height) in textHeights {
                var covered: CGFloat = 0
                for slice in (textSlices[target] ?? []).sorted(by: { $0.lowerBound < $1.lowerBound }) {
                    XCTAssertLessThanOrEqual(slice.lowerBound, covered + 0.5,
                                             "LAYOUT_CONTRACT: unsampled text gap: \(target)")
                    covered = max(covered, slice.upperBound)
                }
                XCTAssertGreaterThanOrEqual(covered, height - 0.5,
                                            "LAYOUT_CONTRACT: text tail never visible: \(target)")
                // Geometry coverage is asserted above; rendered glyphs require an
                // independent screenshot review, recorded without forcing a test failure.
                diagnostics.append("VISUAL_REVIEW_REQUIRED: rendered segment coverage for \(target); inspect this run's player-\(name)-scroll-* screenshots. Geometry coverage does not establish rendered text correctness or physical tap acceptance.")
            }
            let attachment = XCTAttachment(string: diagnostics.joined(separator: "\n"))
            attachment.name = "player-\(name)-actual-AX-frames"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(observed, Set(targets), "LAYOUT_CONTRACT: missing body targets after bounded traversal")
            let wholeFrameTargets = Set(targets).subtracting(textHeights.keys)
            XCTAssertEqual(reached.intersection(wholeFrameTargets), wholeFrameTargets,
                           "LAYOUT_CONTRACT: fitting targets never fully visible: \(wholeFrameTargets.subtracting(reached))")
            try await self.checkLayoutRoutes(host, manager: manager, baseline: initialFixed, size: size, name: name)

        }
    }
}

// Lifecycle calibration slice: UNRUN. Missing native events / barrier timeouts
// are infrastructure failures, never lifecycle RED.
@MainActor
private final class PlayerLifecycleMount: ObservableObject {
    @Published var includesDetail = true
}

@MainActor
private struct PlayerLifecycleUIKitProbe: UIViewRepresentable {
    let mounted: () -> Void
    let dismantled: () -> Void

    final class ProbeView: UIView {
        var mounted: (() -> Void)?
        var dismantled: (() -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil {
                let callback = mounted
                mounted = nil
                callback?()
            }
        }
    }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isAccessibilityElement = false
        view.mounted = mounted
        view.dismantled = dismantled
        return view
    }

    func updateUIView(_ uiView: ProbeView, context: Context) {}

    static func dismantleUIView(_ uiView: ProbeView, coordinator: ()) {
        let callback = uiView.dismantled
        uiView.dismantled = nil
        callback?()
    }
}

@MainActor
private struct PlayerLifecycleConditionalHost: View {
    @ObservedObject var mount: PlayerLifecycleMount
    let detail: MusicPlayerView
    let mounted: () -> Void
    let dismantled: () -> Void
    let replacementMounted: () -> Void

    var body: some View {
        if mount.includesDetail {
            detail.background(PlayerLifecycleUIKitProbe(mounted: mounted, dismantled: dismantled))
        } else {
            Text("Detail removed")
                .background(PlayerLifecycleUIKitProbe(mounted: replacementMounted, dismantled: {}))
        }
    }
}

private extension MiniPlayerAccessibilityHost {
    // Bounded observation of the real UIKit hierarchy, including dismissing
    // controllers (presentedElements deliberately hides those). AX presence alone
    // cannot establish that a presentation animation has completed.
    func completedNativePresentation(destinationLabel: String?) async throws -> [Element] {
        var elements: [Element] = []
        var readFailure: Error?
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                var visited = Set<ObjectIdentifier>()
                func hierarchy(_ node: UIViewController) -> [UIViewController] {
                    guard visited.insert(ObjectIdentifier(node)).inserted else { return [] }
                    return [node] + node.children.flatMap { hierarchy($0) }
                        + (node.presentedViewController.map { hierarchy($0) } ?? [])
                }
                guard let root = self.window.rootViewController else { return false }
                let nodes = hierarchy(root)
                guard nodes.allSatisfy({ !$0.isBeingPresented && !$0.isBeingDismissed && $0.transitionCoordinator == nil }) else {
                    return false
                }
                let modals = nodes.filter { $0.presentingViewController != nil && $0.parent == nil }
                do {
                    if let destinationLabel {
                        guard modals.count == 1, let modal = modals.first,
                              modal.viewIfLoaded?.window === self.window else { return false }
                        modal.view.layoutIfNeeded()
                        elements = try self.readElements(in: modal.view)
                        return elements.contains { $0.label == destinationLabel }
                    }
                    guard modals.isEmpty, self.controller.viewIfLoaded?.window === self.window else { return false }
                    elements = try self.lifecycleElements(modal: false)
                    return !elements.isEmpty
                } catch {
                    readFailure = error
                    return true
                }
            }
        }, object: nil)
        guard await XCTWaiter.fulfillment(of: [settled], timeout: 5) == .completed else {
            throw Self.failure("Native presentation did not complete: \(destinationLabel ?? "uncovered detail")")
        }
        if let readFailure { throw readFailure }
        return elements
    }

    // Immediate real AX read; lifecycle tests use bounded expectations for entry
    // availability, and native event barriers for dismissal/removal completion.
    func lifecycleElements(modal: Bool) throws -> [Element] {
        controller.view.layoutIfNeeded()
        return try modal ? (presentedElements() ?? []) : readElements()
    }
}

extension MiniMusicPlayerPresentationTests {
    func testHostedPlayerMoreDismissAfterDetailRemovalDoesNotReactivateTimeline() async throws {
        try await checkHostedMoreDismissalLifecycle(removingDetail: true)
    }

    func testHostedPlayerNormalMoreDismissRestoresTimelineSubscription() async throws {
        try await checkHostedMoreDismissalLifecycle(removingDetail: false)
    }

    private func lifecycleBarrier(_ events: [XCTestExpectation], _ description: String) async throws {
        guard await XCTWaiter.fulfillment(of: events, timeout: 5) == .completed else {
            throw MiniPlayerAccessibilityHost.failure("Lifecycle calibration barrier: \(description)")
        }
    }

    private func lifecycleSeek(_ manager: MusicPlaybackManager, to time: TimeInterval) async throws {
        let generation = manager.seekCompletionGeneration
        let completed = expectation(description: "Real lifecycle seek \(time) processed")
        let observation = manager.seekCompletionPublisher.filter { $0 > generation }.prefix(1)
            .sink { _ in completed.fulfill() }
        defer { observation.cancel() }
        manager.seek(to: time)
        try await lifecycleBarrier([completed], "real seek completion")
        guard manager.seekCompletionGeneration == generation + 1,
              manager.timeline.currentTime == time else {
            throw MiniPlayerAccessibilityHost.failure("Real lifecycle seek did not update manager timeline")
        }
    }

    private func lifecycleButton(
        in host: MiniPlayerAccessibilityHost, modal: Bool, identifier: String? = nil, label: String
    ) async throws -> MiniPlayerAccessibilityHost.Element {
        var found: MiniPlayerAccessibilityHost.Element?
        var readFailure: Error?
        let available = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                do {
                    let buttons = try host.lifecycleElements(modal: modal).filter { element in
                        element.traits.contains(.button) &&
                        (identifier.map { element.identifier == $0 } ?? (element.label == label))
                    }
                    if buttons.count == 1 { found = buttons[0]; return true }
                    return false
                } catch {
                    readFailure = error
                    return true
                }
            }
        }, object: nil)
        try await lifecycleBarrier([available], "unique real \(modal ? "modal" : "detail") button \(label)")
        if let readFailure { throw readFailure }
        guard let found else { throw MiniPlayerAccessibilityHost.failure("Missing lifecycle AX button") }
        return found
    }

    private func checkHostedMoreDismissalLifecycle(removingDetail: Bool) async throws {
        try await withBoundaryFixture { _, _, manager, _ in
            let suite = "PlayerLifecycle.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let projection = MusicPlaybackTimelineProjection(timeline: manager.timeline)
            let mount = PlayerLifecycleMount()
            let mounted = self.expectation(description: "Detail UIKit probe mounted")
            // Only the removal path waits for these events. The normal path
            // observes branch counts without registering unwaited expectations.
            let dismantled = removingDetail ? self.expectation(description: "Detail UIKit probe dismantled") : nil
            let replacementMounted = removingDetail ? self.expectation(description: "Replacement branch mounted") : nil
            let arrived = removingDetail ? self.expectation(description: "Real SwiftUI More onDismiss arrived") : nil
            let processed = self.expectation(description: "Entire More onDismiss handler returned")
            var delivery: MusicPlayerMoreDismissalDelivery?
            var receivedIDs: [UUID] = []
            var processedIDs: [UUID] = []
            var dismantleCount = 0
            var replacementCount = 0
            let finished: @MainActor (UUID) -> Void = { id in
                processedIDs.append(id)
                processed.fulfill()
            }
            let favorites = MusicFavoritesStore(defaults: defaults)
            let detail: MusicPlayerView
            if removingDetail {
                detail = MusicPlayerView(playback: manager, favorites: favorites, timelineProjection: projection,
                    moreDismissalDeliveryGate: { event in
                        receivedIDs.append(event.id)
                        delivery = event
                        arrived?.fulfill()
                    }, moreDismissalProcessed: finished)
            } else {
                // Exercise the actual default synchronous gate in the control.
                detail = MusicPlayerView(playback: manager, favorites: favorites, timelineProjection: projection,
                                         moreDismissalProcessed: finished)
            }
            let host = try MiniPlayerAccessibilityHost(content: PlayerLifecycleConditionalHost(
                mount: mount, detail: detail, mounted: { mounted.fulfill() },
                dismantled: { dismantleCount += 1; dismantled?.fulfill() },
                replacementMounted: { replacementCount += 1; replacementMounted?.fulfill() }))
            defer { host.close() }
            try await self.lifecycleBarrier([mounted], "initial detail mount")
            // Read actual publications, with no active setter or private reflection.
            var publications: [TimeInterval] = []
            let observation = projection.$currentTime.dropFirst().sink { publications.append($0) }
            defer { observation.cancel() }
            let more = try await self.lifecycleButton(in: host, modal: false,
                identifier: "music-player-more-entry", label: "更多")
            try await self.lifecycleSeek(manager, to: 9)
            guard projection.currentTime == 9, publications.contains(9) else {
                throw MiniPlayerAccessibilityHost.failure("Mounted projection never subscribed")
            }
            guard more.object.accessibilityActivate() else {
                throw MiniPlayerAccessibilityHost.failure("Real More action rejected AX activation")
            }
            let done = try await self.lifecycleButton(in: host, modal: true, label: "完成")
            let frozenTime = projection.currentTime
            let frozenCount = publications.count
            try await self.lifecycleSeek(manager, to: 11)
            guard projection.currentTime == frozenTime, publications.count == frozenCount,
                  dismantleCount == 0, mount.includesDetail else {
                throw MiniPlayerAccessibilityHost.failure("More coverage did not freeze a still-mounted detail")
            }
            guard done.object.accessibilityActivate() else {
                throw MiniPlayerAccessibilityHost.failure("Real More Done action rejected AX activation")
            }
            if removingDetail {
                let arrived = try XCTUnwrap(arrived)
                let dismantled = try XCTUnwrap(dismantled)
                let replacementMounted = try XCTUnwrap(replacementMounted)
                try await self.lifecycleBarrier([arrived], "native More onDismiss arrival")
                guard let event = delivery, receivedIDs == [event.id], processedIDs.isEmpty else {
                    throw MiniPlayerAccessibilityHost.failure("Gate did not retain exactly one unprocessed real event")
                }
                mount.includesDetail = false
                try await self.lifecycleBarrier([dismantled, replacementMounted], "conditional removal and UIKit dismantle")
                guard !mount.includesDetail, dismantleCount == 1, replacementCount == 1 else {
                    throw MiniPlayerAccessibilityHost.failure("Detail branch removal was not confirmed")
                }
                // Confirm onDisappear cancellation with a real seek before delivery.
                let removedCount = publications.count
                let removedTime = projection.currentTime
                try await self.lifecycleSeek(manager, to: 13)
                guard publications.count == removedCount, projection.currentTime == removedTime else {
                    throw MiniPlayerAccessibilityHost.failure("Removed projection was not inactive before delayed delivery")
                }
                event.deliver()
                try await self.lifecycleBarrier([processed], "full delayed handler completion")
                guard processedIDs == [event.id] else {
                    throw MiniPlayerAccessibilityHost.failure("Processed event ID mismatch")
                }
                // One-shot delivery cannot repeat the handler or its completion.
                event.deliver()
                guard processedIDs == [event.id] else {
                    throw MiniPlayerAccessibilityHost.failure("Dismiss event was consumed more than once")
                }
                try await self.lifecycleSeek(manager, to: 17)
                XCTAssertEqual(publications.count, removedCount,
                    "LIFECYCLE_RED: real delayed More dismissal published after permanent detail removal")
                XCTAssertEqual(projection.currentTime, removedTime,
                    "LIFECYCLE_RED: removed detail timeline must remain frozen after delayed dismissal and real seek")
            } else {
                try await self.lifecycleBarrier([processed], "default synchronous dismissal processing")
                guard processedIDs.count == 1, mount.includesDetail,
                      dismantleCount == 0, replacementCount == 0 else {
                    throw MiniPlayerAccessibilityHost.failure("Normal dismiss did not retain the detail branch")
                }
                let restoredCount = publications.count
                try await self.lifecycleSeek(manager, to: 17)
                XCTAssertEqual(projection.currentTime, 17, "Normal More dismiss must restore timeline subscription")
                XCTAssertEqual(publications.count, restoredCount + 1,
                               "Normal More dismiss must deliver the subsequent real seek")
            }
        }
    }
}

// Removal contract slice: tests only, UNRUN. Parent must distinguish behavioral
// REMOVAL_RED from host/AX/presentation infrastructure failures.
extension MiniMusicPlayerPresentationTests {
    func testHostedPlayerMoreHasNoDrivingModeAndRetainsIndependentControls() async throws {
        try await calibrateReader()
        try await withContentFirstPlayerHost { host, manager in
            let originalTrack = manager.currentTrack?.id
            let originalQueue = manager.queue.map(\.id)
            let originalSleep = manager.sleepTimerMode
            let root = try await host.layoutSnapshot()
            self.assertNoDrivingEntry(root)
            let more = try await self.lifecycleButton(in: host, modal: false,
                identifier: "music-player-more-entry", label: "更多")
            guard more.object.accessibilityActivate() else {
                throw MiniPlayerAccessibilityHost.failure("Real More activation failed")
            }
            // Wait for retained content, never for the feature being removed.
            let sheet = try await host.completedNativePresentation(destinationLabel: "更多")
            self.attach(sheet, name: "removal-real-more")
            self.assertNoDrivingEntry(sheet)
            XCTAssertTrue(sheet.contains { $0.identifier == "music-sleep-timer-menu" })
            XCTAssertFalse(sheet.contains { $0.label == "蓝牙车载歌词（实验）" })
            XCTAssertTrue(sheet.contains {
                $0.label == "播放时会暂时使用蓝牙歌曲标题字段显示当前歌词，实际效果可能因车型而异。"
            })
            let done = try await self.lifecycleButton(in: host, modal: true, label: "完成")
            guard done.object.accessibilityActivate() else {
                throw MiniPlayerAccessibilityHost.failure("Real More Done activation failed")
            }
            let returned = try await host.completedNativePresentation(destinationLabel: nil)
            self.assertNoDrivingEntry(returned)
            XCTAssertTrue(returned.contains { $0.identifier == "music-player-more-entry" })
            XCTAssertEqual(manager.currentTrack?.id, originalTrack)
            XCTAssertEqual(manager.queue.map(\.id), originalQueue)
            XCTAssertEqual(manager.sleepTimerMode, originalSleep)
            XCTAssertFalse(manager.isPlaying)
        }
    }

    func testHostedPlayerQueueHasNoDrivingMode() async throws {
        try await calibrateReader()
        try await withContentFirstPlayerHost { host, _ in
            let queue = try await self.lifecycleButton(in: host, modal: false,
                identifier: "music-queue-entry", label: "播放队列")
            guard queue.object.accessibilityActivate() else {
                throw MiniPlayerAccessibilityHost.failure("Real queue activation failed")
            }
            let sheet = try await host.completedNativePresentation(destinationLabel: "播放队列")
            XCTAssertTrue(sheet.contains { $0.identifier == "music-queue-row-0" })
            self.assertNoDrivingEntry(sheet)
        }
    }

    func testHostedVideoListAndDetailHaveNoDrivingMode() async throws {
        try await calibrateReader()
        try await withBoundaryFixture { directory, _, manager, ownership in
            // Inactive scene prevents the production video's default library from
            // refreshing app Documents. Its actual navigation/toolbar still mounts.
            let list = try MiniPlayerAccessibilityHost(content: HomeView(
                playback: manager, ownership: ownership, isVideoDetailPresented: .constant(false))
                .environment(\.scenePhase, .inactive))
            do {
                defer { list.close() }
                let tree = try await list.layoutSnapshot()
                XCTAssertTrue(tree.contains { $0.label == "Vivi播放器" })
                self.assertNoDrivingEntry(tree)
            }
            // Decodable synthetic media through the real video detail UI. This
            // tests entry presentation, not video decoding or playback acceptance.
            let video = VideoItem(url: directory.appendingPathComponent(Self.fixtureFileName), duration: 30)
            let detail = try MiniPlayerAccessibilityHost(content: PlayerView(
                initialVideo: video, orderedVideos: [video], musicPlayback: manager,
                ownership: ownership, videoAutoAdvanceEnabled: false,
                isVideoDetailPresented: .constant(true)))
            defer { detail.close() }
            let tree = try await detail.layoutSnapshot()
            XCTAssertTrue(tree.contains { $0.label == "快退 15 秒" && $0.traits.contains(.button) })
            XCTAssertTrue(tree.contains { $0.label == "快进 15 秒" && $0.traits.contains(.button) })
            self.assertNoDrivingEntry(tree)
        }
    }

    private func assertNoDrivingEntry(_ tree: [MiniPlayerAccessibilityHost.Element],
                                      file: StaticString = #filePath, line: UInt = #line) {
        let entries = tree.filter {
            $0.label.contains("驾驶模式") || ($0.identifier?.hasPrefix("driving-mode-") ?? false)
        }
        XCTAssertTrue(entries.isEmpty,
            "REMOVAL_RED: real presentation still exposes driving mode: \(entries.map(\.diagnostic))",
            file: file, line: line)
    }
}

// Post-removal tests-only adaptation. All new actions use real AX leaves.
// No UIAction handler access, private UIKit class matching, or manager setter fallback.
private extension MiniPlayerAccessibilityHost {
    func routeRoot(modal: Bool) throws -> UIView {
        if !modal { return controller.view }
        func find(_ node: UIViewController) -> UIViewController? {
            if let presented = node.presentedViewController, !presented.isBeingDismissed { return presented }
            return node.children.compactMap { find($0) }.first
        }
        guard let presented = find(controller), presented.view.window === window else {
            throw Self.failure("Requested sheet has no real mounted presentation")
        }
        return presented.view
    }

    func routeScrolls(modal: Bool) throws -> [UIScrollView] {
        func visit(_ view: UIView) -> [UIScrollView] {
            guard !view.isHidden, view.alpha > 0.01 else { return [] }
            return (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { visit($0) }
        }
        return visit(try routeRoot(modal: modal))
    }

    func routeViewport(modal: Bool) throws -> CGRect {
        let root = try routeRoot(modal: modal)
        return root.convert(root.bounds, to: window.screen.coordinateSpace)
    }

    func routeBand(_ scroll: UIScrollView, modal: Bool) throws -> CGRect {
        if !modal { return visibleScrollFrame(scroll) }
        let root = try routeRoot(modal: true)
        var band = try routeViewport(modal: true)
        var ancestor: UIView? = scroll
        while let view = ancestor {
            if view === scroll || view.clipsToBounds {
                band = band.intersection(view.convert(view.bounds, to: window.screen.coordinateSpace))
            }
            ancestor = view.superview
        }
        func bars(_ view: UIView) -> [UIView] {
            guard !view.isHidden, view.alpha > 0.01 else { return [] }
            return view is UINavigationBar ? [view] : view.subviews.flatMap { bars($0) }
        }
        for bar in bars(root) {
            let frame = bar.convert(bar.bounds, to: window.screen.coordinateSpace)
            if band.intersects(frame) {
                let top = max(band.minY, frame.maxY)
                band = CGRect(x: band.minX, y: top, width: band.width, height: max(0, band.maxY - top))
            }
        }
        return band
    }

    func routeSnapshot(modal: Bool) async throws -> [Element] {
        var previous: [String] = []
        var stable = 0
        var last: [Element] = []
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            let root = try routeRoot(modal: modal)
            root.layoutIfNeeded()
            last = try readElements(in: root)
            let signature = last.map { "\($0.frameDiagnostic) value=\(String(reflecting: $0.value))" }
                + (try routeScrolls(modal: modal)).map { "\($0.contentOffset) \($0.contentSize) \($0.bounds)" }
            stable = !last.isEmpty && signature == previous ? stable + 1 : 0
            if stable >= 3 { return last }
            previous = signature
        }
        throw Self.failure("Route AX/value did not settle: \(last.map { $0.frameDiagnostic })")
    }
}

extension MiniMusicPlayerPresentationTests {
    private func routeElement(_ tree: [MiniPlayerAccessibilityHost.Element], id: String? = nil,
                              label: String) throws -> MiniPlayerAccessibilityHost.Element {
        let matches = tree.filter { element in
            if let id { return element.identifier == id || (element.identifier == nil && element.label == label) }
            return element.label == label
        }
        return try XCTUnwrap(matches.count == 1 ? matches.first : nil,
                             "ROUTE_RED: expected exactly one \(id ?? label), found \(matches.count)")
    }

    @discardableResult
    private func assertFixedControls(_ host: MiniPlayerAccessibilityHost,
                                     tree: [MiniPlayerAccessibilityHost.Element],
                                     baseline: [CGRect]? = nil) throws -> [CGRect] {
        let entries: [(String?, String)] = [(nil, "上一首"), (nil, "播放"), (nil, "下一首"),
            ("music-shuffle-toggle", "随机播放"), ("music-completion-mode-menu", "播放完成方式"),
            ("music-queue-entry", "播放队列")]
        let frames = try entries.map { try host.validatedFrame(routeElement(tree, id: $0.0, label: $0.1)) }
        for (index, frame) in frames.enumerated() {
            XCTAssertTrue(host.viewportScreenFrame.contains(frame), "LAYOUT_CONTRACT: fixed control clipped: \(entries[index].1) \(frame)")
            XCTAssertFalse(host.visibleNavigationBarFrames.contains { $0.intersects(frame) })
            XCTAssertGreaterThanOrEqual(frame.width, 44, "LAYOUT_CONTRACT: \(entries[index].1)")
            XCTAssertGreaterThanOrEqual(frame.height, 44, "LAYOUT_CONTRACT: \(entries[index].1)")
            if let baseline {
                XCTAssertEqual(frame.minX, baseline[index].minX, accuracy: 1)
                XCTAssertEqual(frame.minY, baseline[index].minY, accuracy: 1)
                XCTAssertEqual(frame.width, baseline[index].width, accuracy: 1)
                XCTAssertEqual(frame.height, baseline[index].height, accuracy: 1)
            }
            for other in frames.indices where other > index {
                XCTAssertFalse(frame.insetBy(dx: 0.5, dy: 0.5).intersects(frames[other]),
                               "LAYOUT_CONTRACT: fixed controls overlap: \(entries[index].1)/\(entries[other].1)")
            }
        }
        XCTAssertLessThanOrEqual(frames[0].maxX, frames[1].minX)
        XCTAssertLessThanOrEqual(frames[1].maxX, frames[2].minX)
        return frames
    }

    // Bounded discovery plus frame-directed reach on the requested real surface.
    // Exact full labels identify nodes; only full frame containment proves reach.
    private func reachRoute(_ host: MiniPlayerAccessibilityHost, modal: Bool = false,
                            id: String? = nil, label: String,
                            fixedBaseline: [CGRect]? = nil) async throws -> MiniPlayerAccessibilityHost.Element {
        var tree = try await host.routeSnapshot(modal: modal)
        let scrolls = try host.routeScrolls(modal: modal)
        for scroll in scrolls {
            let minimum = -scroll.adjustedContentInset.top
            scroll.setContentOffset(CGPoint(x: 0, y: minimum), animated: false)
            for step in 0..<40 {
                tree = try await host.routeSnapshot(modal: modal)
                if let fixedBaseline { try assertFixedControls(host, tree: tree, baseline: fixedBaseline) }
                let matches = tree.filter { $0.identifier == id && id != nil || ($0.identifier == nil || id == nil) && $0.label == label }
                XCTAssertLessThanOrEqual(matches.count, 1, "ROUTE_RED: ambiguous \(label)")
                let discoveryOffset = scroll.contentOffset
                if var element = matches.first {
                    for _ in 0..<3 {
                        let frame = try host.validatedFrame(element)
                        let band = try host.routeBand(scroll, modal: modal)
                        if band.insetBy(dx: -0.5, dy: -0.5).contains(frame) { return element }
                        let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                        let y = min(maximum, max(minimum, scroll.contentOffset.y + frame.midY - band.midY))
                        scroll.setContentOffset(CGPoint(x: 0, y: y), animated: false)
                        tree = try await host.routeSnapshot(modal: modal)
                        if let fixedBaseline { try assertFixedControls(host, tree: tree, baseline: fixedBaseline) }
                        guard let fresh = tree.first(where: { ($0.identifier == id && id != nil) || (($0.identifier == nil || id == nil) && $0.label == label) }) else { break }
                        element = fresh
                    }
                }
                scroll.setContentOffset(discoveryOffset, animated: false)
                let maximum = max(minimum, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                if scroll.contentOffset.y >= maximum - 0.5 { break }
                let band = try host.routeBand(scroll, modal: modal)
                scroll.setContentOffset(CGPoint(x: 0, y: min(maximum, scroll.contentOffset.y + max(24, band.height / 3))), animated: false)
                if step == 39 { XCTFail("LAYOUT_CONTRACT: bounded route traversal exhausted: \(label)") }
            }
        }
        attach(tree, name: "unreachable-\(label)-modal-\(modal)")
        XCTFail("LAYOUT_CONTRACT: \(label) never fully reachable on correct surface (not proved by full AX label)")
        throw NSError(domain: "PlayerLayout.PRODUCT_RED", code: 1)
    }

    private func checkLayoutRoutes(_ host: MiniPlayerAccessibilityHost, manager: MusicPlaybackManager,
                                   baseline: [CGRect], size: DynamicTypeSize, name: String) async throws {
        let completion = manager.completionMode
        let sleep = manager.sleepTimerMode
        let toggle = try await reachRoute(host, id: "music-player-content-toggle", label: "显示歌词", fixedBaseline: baseline)
        XCTAssertTrue(toggle.object.accessibilityActivate())
        // Reacquire the actual layout branch after the content replacement.
        let lyricsTree = try await host.routeSnapshot(modal: false)
        let lyricScrolls = try host.routeScrolls(modal: false)
        if size.isAccessibilitySize {
            XCTAssertEqual(lyricScrolls.count, 1, "LAYOUT_CONTRACT: AX lyrics use one full-content scroll; identity remains on cover")
        } else {
            XCTAssertGreaterThanOrEqual(lyricScrolls.count, 2, "LAYOUT_CONTRACT: identity and synchronized lyrics have separate scroll regions")
        }
        add(try host.renderedAttachment(name: "player-\(name)-lyrics-initial"))
        attach(lyricsTree, name: "player-\(name)-lyrics-initial-AX")
        // Standard heading/return are siblings between the scroll regions;
        // AX places them inside its single lyrics scroll. Measure the content band.
        let contentBand = try lyricScrolls.map { try host.routeBand($0, modal: false) }
            .reduce(CGRect.null) { $0.union($1) }
        let initialGeometry = XCTAttachment(string: "lyrics initial contentBand=\(contentBand)")
        initialGeometry.name = "player-\(name)-lyrics-initial-band"
        initialGeometry.lifetime = .keepAlways
        add(initialGeometry)
        let heading = try routeElement(lyricsTree, label: "同步歌词")
        XCTAssertTrue(contentBand.contains(try host.validatedFrame(heading)), "LAYOUT_CONTRACT: synchronized lyrics heading clipped")
        // Capture the same mounted host and measured bands at each actual route state.
        @MainActor
        func captureLyrics(_ state: String) async throws {
            let tree = try await host.routeSnapshot(modal: false)
            add(try host.renderedAttachment(name: "player-\(name)-\(state)"))
            attach(tree, name: "player-\(name)-\(state)-AX")
            let bands = try host.routeScrolls(modal: false).map {
                "band=\(try host.routeBand($0, modal: false)) offset=\($0.contentOffset)"
            }
            let geometry = XCTAttachment(string: bands.joined(separator: "\n"))
            geometry.name = "player-\(name)-\(state)-bands"
            geometry.lifetime = .keepAlways
            add(geometry)
        }
        _ = try await reachRoute(host, label: "Cue", fixedBaseline: baseline)
        try await captureLyrics("lyrics-Cue")
        if size.isAccessibilitySize {
            _ = try await reachRoute(host, id: "music-player-content-toggle", label: "显示封面", fixedBaseline: baseline)
        }
        try await captureLyrics("lyrics-before-return")
        let returnTree = try await host.routeSnapshot(modal: false)
        let back = try routeElement(returnTree, id: "music-player-content-toggle", label: "显示封面")
        let returnBand = try host.routeScrolls(modal: false)
            .map { try host.routeBand($0, modal: false) }.reduce(CGRect.null) { $0.union($1) }
        let backFrame = try host.validatedFrame(back)
        guard returnBand.insetBy(dx: -0.5, dy: -0.5).contains(backFrame) else {
            XCTFail("LAYOUT_CONTRACT: return entry must be fully visible before activation")
            throw NSError(domain: "PlayerLayout.PRODUCT_RED", code: 1)
        }
        XCTAssertTrue(back.object.accessibilityActivate())
        try await captureLyrics("cover-after-return")
        let returned = try await host.routeSnapshot(modal: false)
        _ = try routeElement(returned, id: "music-player-content-toggle", label: "显示歌词")
        XCTAssertFalse(returned.contains { $0.label == "同步歌词" || $0.label == "Cue" },
                       "LAYOUT_CONTRACT: lyrics must be replaced by cover after return")
        _ = try assertFixedControls(host, tree: returned, baseline: baseline)
        XCTAssertFalse(manager.isPlaying)
        let more = try await lifecycleButton(in: host, modal: false, identifier: "music-player-more-entry", label: "更多")
        XCTAssertTrue(more.object.accessibilityActivate())
        _ = try await host.completedNativePresentation(destinationLabel: "更多")
        let sheetViewport = try host.routeViewport(modal: true)
        let geometry = XCTAttachment(string: "320 child detail; actual presented sheet viewport=\(sheetViewport)")
        geometry.name = "More-real-viewport"; geometry.lifetime = .keepAlways; add(geometry)
        for (id, label) in [("music-sleep-timer-menu", "睡眠定时"),
                            (nil, "播放时会暂时使用蓝牙歌曲标题字段显示当前歌词，实际效果可能因车型而异。")] as [(String?, String)] {
            let target = try await reachRoute(host, modal: true, id: id, label: label)
            if label != "播放时会暂时使用蓝牙歌曲标题字段显示当前歌词，实际效果可能因车型而异。" {
                let frame = try host.validatedFrame(target)
                let diagnostic = "target=\(label), identifier=\(id ?? "nil"), type=\(type(of: target.object)), traits=\(target.traits), frame=\(frame), viewport=\(sheetViewport)"
                XCTAssertGreaterThanOrEqual(frame.width, 44, diagnostic)
                XCTAssertGreaterThanOrEqual(frame.height, 44, diagnostic)
            }
        }
        let moreSnapshot = try await host.routeSnapshot(modal: true)
        XCTAssertFalse(moreSnapshot.contains { $0.label == "蓝牙车载歌词（实验）" })
        let done = try await lifecycleButton(in: host, modal: true, label: "完成")
        XCTAssertTrue(done.object.accessibilityActivate())
        _ = try await host.completedNativePresentation(destinationLabel: nil)
        _ = try assertFixedControls(host, tree: await host.routeSnapshot(modal: false), baseline: baseline)
        XCTAssertEqual(manager.completionMode, completion)
        XCTAssertEqual(manager.sleepTimerMode, sleep)
        XCTAssertFalse(manager.isPlaying)
    }

    private func withPostRemovalHost(size: DynamicTypeSize,
        _ body: @MainActor (MiniPlayerAccessibilityHost, MusicPlaybackManager, AVPlayer) async throws -> Void
    ) async throws {
        try await withBoundaryFixture { _, player, manager, _ in
            let suite = "PostRemovalMenu.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let host = try MiniPlayerAccessibilityHost(content:
                MusicPlayerView(playback: manager, favorites: MusicFavoritesStore(defaults: defaults))
                    .environment(\.dynamicTypeSize, size), viewportWidth: 320, viewportHeight: 568)
            defer { host.close() }
            try await body(host, manager, player)
        }
    }

    // Model setters preserve internal invariants; these are NOT UI click substitutes.
    // Real menu action wiring, entry values and selected state belong to DrivePlayerUITests.
    func testCompletionModeModelSettersPreservePlaybackAndIndependentSettings() async throws {
        try await withBoundaryFixture { _, player, manager, _ in
            manager.setShuffleEnabled(true)
            manager.setSleepTimerMode(.stopAfterCurrentTrack)
            let queue = manager.queue
            let track = manager.currentTrack
            let index = manager.currentIndex
            let item = try XCTUnwrap(player.currentItem)
            let position = manager.timeline.currentTime
            let playerPosition = player.currentTime().seconds
            let sleep = manager.sleepTimerMode
            XCTAssertFalse(manager.isPlaying)
            for mode in [MusicCompletionMode.repeatOne, .stopAtEnd, .repeatAll] {
                manager.setCompletionMode(mode)
                XCTAssertEqual(manager.completionMode, mode)
                XCTAssertTrue(manager.isShuffleEnabled)
                XCTAssertEqual(manager.sleepTimerMode, sleep)
                XCTAssertEqual(manager.queue, queue)
                XCTAssertEqual(manager.currentTrack, track)
                XCTAssertEqual(manager.currentIndex, index)
                XCTAssertTrue(player.currentItem === item)
                XCTAssertFalse(manager.isPlaying)
                XCTAssertEqual(manager.timeline.currentTime, position, accuracy: 0.01)
                XCTAssertEqual(player.currentTime().seconds, playerPosition, accuracy: 0.1)
                XCTAssertEqual(player.currentTime().seconds, position, accuracy: 0.1)
            }
        }
    }

    func testHostedPlayerShuffleToggleKeepsCompletionAndSleepIndependent() async throws {
        try await calibrateReader()
        for size: DynamicTypeSize in [.large, .accessibility5] {
            try await withPostRemovalHost(size: size) { host, manager, player in
                let completion = manager.completionMode
                let sleep = manager.sleepTimerMode
                let queue = manager.queue
                let track = manager.currentTrack
                let item = player.currentItem
                let position = manager.timeline.currentTime
                for selected in [false, true, false] {
                    if selected != manager.isShuffleEnabled {
                        let before = try self.routeElement(await host.routeSnapshot(modal: false), id: "music-shuffle-toggle", label: "随机播放")
                        XCTAssertTrue(host.viewportScreenFrame.contains(try host.validatedFrame(before)))
                        XCTAssertTrue(before.object.accessibilityActivate())
                    }
                    let entry = try self.routeElement(await host.routeSnapshot(modal: false), id: "music-shuffle-toggle", label: "随机播放")
                    XCTAssertEqual(manager.isShuffleEnabled, selected)
                    XCTAssertEqual(entry.value, selected ? "已选择" : "未选择")
                    XCTAssertEqual(entry.traits.contains(.selected), selected)
                    XCTAssertEqual(manager.completionMode, completion)
                    XCTAssertEqual(manager.sleepTimerMode, sleep)
                    XCTAssertEqual(manager.queue, queue)
                    XCTAssertEqual(manager.currentTrack, track)
                    XCTAssertTrue(player.currentItem === item)
                    XCTAssertFalse(manager.isPlaying)
                    XCTAssertEqual(manager.timeline.currentTime, position, accuracy: 0.01)
                    XCTAssertEqual(player.currentTime().seconds, position, accuracy: 0.1)
                }
            }
        }
    }

    func testHostedPlayerQueueRowsSelectTrackAndPreserveQueueAt320() async throws {
        try await calibrateReader()
        for size: DynamicTypeSize in [.large, .accessibility5] {
            try await withPostRemovalHost(size: size) { host, manager, player in
                let queue = manager.queue
                XCTAssertEqual(queue.count, 2)
                var rowPositions: [CGRect] = []
                let entry = try self.routeElement(await host.routeSnapshot(modal: false), id: "music-queue-entry", label: "播放队列")
                XCTAssertTrue(entry.object.accessibilityActivate())
                _ = try await host.completedNativePresentation(destinationLabel: "播放队列")
                for index in 0..<2 {
                    let row = try await self.reachRoute(host, modal: true, id: "music-queue-row-\(index)", label: MusicTrackTextPresentation(track: queue[index]).title)
                    XCTAssertEqual(row.value, index == 0 ? "当前播放" : "非当前播放")
                    XCTAssertEqual(row.traits.contains(.selected), index == 0)
                    let frame = try host.validatedFrame(row)
                    XCTAssertGreaterThanOrEqual(frame.width, 44)
                    XCTAssertGreaterThanOrEqual(frame.height, 44)
                    let list = try XCTUnwrap(host.routeScrolls(modal: true).first)
                    rowPositions.append(frame.offsetBy(dx: 0, dy: list.contentOffset.y))
                }
                XCTAssertLessThanOrEqual(rowPositions[0].maxY, rowPositions[1].minY + 1e-9,
                                         "QUEUE_RED: queue identity/order and distinct rows; numerical tolerance=1e-9pt; frames=\(rowPositions)")
                let second = try await self.reachRoute(host, modal: true, id: "music-queue-row-1", label: MusicTrackTextPresentation(track: queue[1]).title)
                XCTAssertTrue(second.object.accessibilityActivate())
                _ = try await host.routeSnapshot(modal: true)
                XCTAssertEqual(manager.currentTrack, queue[1])
                XCTAssertEqual(manager.currentIndex, 1)
                XCTAssertEqual((player.currentItem?.asset as? AVURLAsset)?.url, queue[1].url)
                XCTAssertTrue(manager.isPlaying, "Queue selection must retain existing play intent")
                XCTAssertEqual(manager.queue, queue)
                for index in 0..<2 {
                    let row = try await self.reachRoute(host, modal: true, id: "music-queue-row-\(index)", label: MusicTrackTextPresentation(track: queue[index]).title)
                    XCTAssertEqual(row.value, index == 1 ? "当前播放" : "非当前播放")
                    XCTAssertEqual(row.traits.contains(.selected), index == 1)
                }
                let done = try await self.lifecycleButton(in: host, modal: true, label: "完成")
                XCTAssertTrue(done.object.accessibilityActivate())
                _ = try await host.completedNativePresentation(destinationLabel: nil)
                manager.pause() // Fixture cleanup after the real play action.
                _ = try self.assertFixedControls(host, tree: await host.routeSnapshot(modal: false))
            }
        }
    }

    func testHostedPlayerQueueOpensCenteredOnCurrentTrackFarBelowViewport() async throws {
        try await calibrateReader()
        try await withPostRemovalHost(size: .large) { host, manager, player in
            let current = try XCTUnwrap(manager.currentTrack)
            let directory = current.url.deletingLastPathComponent()
            let currentIndex = 36
            var queue = (0..<48).map { index in
                MusicItem(url: directory.appendingPathComponent("queue-position-\(index).wav"), duration: 30)
            }
            queue[currentIndex] = current
            manager.updateQueue(queue) // Arrange a long queue while preserving the loaded, paused item.
            let item = try XCTUnwrap(player.currentItem)
            let position = manager.timeline.currentTime
            XCTAssertEqual(manager.currentIndex, currentIndex)
            XCTAssertFalse(manager.isPlaying)

            let entry = try self.routeElement(await host.routeSnapshot(modal: false),
                                              id: "music-queue-entry", label: "播放队列")
            XCTAssertTrue(entry.object.accessibilityActivate())
            _ = try await host.completedNativePresentation(destinationLabel: "播放队列")
            let sheet = try await host.routeSnapshot(modal: true)
            let rows = sheet.filter { $0.identifier == "music-queue-row-\(currentIndex)" }
            XCTAssertEqual(rows.count, 1,
                           "QUEUE_SCROLL_RED: opening a long queue must reveal its current row without a user scroll")
            guard let row = rows.first else { return }
            let scroll = try XCTUnwrap(host.routeScrolls(modal: true).first)
            let band = try host.routeBand(scroll, modal: true)
            let frame = try host.validatedFrame(row)
            XCTAssertTrue(band.contains(frame), "QUEUE_SCROLL_RED: current row must be fully visible on opening")
            XCTAssertLessThanOrEqual(abs(frame.midY - band.midY), frame.height,
                                     "QUEUE_SCROLL_RED: current row should open near the list center")
            XCTAssertEqual(row.value, "当前播放")
            XCTAssertTrue(row.traits.contains(.selected))
            XCTAssertEqual(manager.queue, queue)
            XCTAssertEqual(manager.currentIndex, currentIndex)
            XCTAssertEqual(manager.currentTrack, current)
            XCTAssertTrue(player.currentItem === item)
            XCTAssertFalse(manager.isPlaying)
            XCTAssertEqual(manager.timeline.currentTime, position, accuracy: 0.01)
        }
    }

    func testHostedPlayerEmptyQueueSheetIsReachableAndDismisses() async throws {
        try await calibrateReader()
        try await withPostRemovalHost(size: .large) { host, manager, _ in
            manager.updateQueue([]) // Establish an empty fixture, not the action under test.
            let entry = try self.routeElement(await host.routeSnapshot(modal: false), id: "music-queue-entry", label: "播放队列")
            XCTAssertTrue(entry.object.accessibilityActivate())
            let sheet = try await host.completedNativePresentation(destinationLabel: "播放队列")
            let empty = try self.routeElement(sheet, label: "播放队列为空")
            XCTAssertTrue(try host.routeViewport(modal: true).contains(host.validatedFrame(empty)))
            XCTAssertFalse(sheet.contains { $0.identifier?.hasPrefix("music-queue-row-") == true })
            let done = try await self.lifecycleButton(in: host, modal: true, label: "完成")
            XCTAssertTrue(done.object.accessibilityActivate())
            _ = try await host.completedNativePresentation(destinationLabel: nil)
        }
    }
}

extension MiniMusicPlayerPresentationTests {
    // No host or Menu: deterministic model/presentation coverage, not UI selection.
    func testSleepTimerModelSettersPreservePlaybackAndIndependentSettings() async throws {
        let scheduler = ManualMusicSleepTimerScheduler()
        let clock = MusicSleepTimerClock(monotonicNow: { 100 }, wallNow: { Date(timeIntervalSince1970: 1_000) })
        try await withBoundaryFixture(sleepTimerClock: clock, scheduleSleepTimer: scheduler.schedule(after:action:)) { _, player, manager, _ in
            manager.setCompletionMode(.repeatOne)
            manager.setShuffleEnabled(true)
            let completion = manager.completionMode
            let shuffle = manager.isShuffleEnabled
            let track = manager.currentTrack
            let queue = manager.queue
            let index = manager.currentIndex
            let item = try XCTUnwrap(player.currentItem)
            let position = manager.timeline.currentTime
            let playerPosition = player.currentTime().seconds
            let cases: [(MusicSleepTimerMode, TimeInterval?, String)] = [
                (.minutes15, 900, "睡眠定时：15 分钟（15:00）"),
                (.minutes30, 1_800, "睡眠定时：30 分钟（30:00）"),
                (.minutes60, 3_600, "睡眠定时：60 分钟（1:00:00）"),
                (.stopAfterCurrentTrack, nil, "睡眠定时：本曲结束后停止"),
                (.off, nil, "睡眠定时：关闭")
            ]
            XCTAssertFalse(manager.isPlaying)
            for (mode, expectedRemaining, expectedStatus) in cases {
                manager.setSleepTimerMode(mode)
                XCTAssertEqual(manager.sleepTimerMode, mode)
                let remaining = manager.sleepTimerRemainingTime()
                if let expectedRemaining {
                    XCTAssertEqual(try XCTUnwrap(remaining), expectedRemaining, accuracy: 0.001)
                } else {
                    XCTAssertNil(remaining)
                }
                XCTAssertEqual(MusicSleepTimerPresentation.statusText(mode: manager.sleepTimerMode, remaining: remaining), expectedStatus)
                XCTAssertEqual(manager.completionMode, completion)
                XCTAssertEqual(manager.isShuffleEnabled, shuffle)
                XCTAssertEqual(manager.currentTrack, track)
                XCTAssertEqual(manager.queue, queue)
                XCTAssertEqual(manager.currentIndex, index)
                XCTAssertTrue(player.currentItem === item)
                XCTAssertFalse(manager.isPlaying)
                XCTAssertEqual(manager.timeline.currentTime, position, accuracy: 0.01)
                XCTAssertEqual(player.currentTime().seconds, playerPosition, accuracy: 0.1)
                XCTAssertEqual(player.currentTime().seconds, position, accuracy: 0.1)
            }
        }
    }

    func testHostedPlayerMoreOmitsBluetoothSwitchWithSynchronizedLyrics() async throws {
        try await calibrateReader()
        try await withContentFirstPlayerHost { host, manager in
            let completion = manager.completionMode
            let shuffle = manager.isShuffleEnabled
            let track = manager.currentTrack
            let queue = manager.queue
            let position = manager.timeline.currentTime
            XCTAssertNotNil(track?.metadata?.synchronizedLyrics)
            XCTAssertTrue(manager.isBluetoothCarLyricsEnabled)
            let more = try await self.lifecycleButton(in: host, modal: false,
                identifier: "music-player-more-entry", label: "更多")
            XCTAssertTrue(more.object.accessibilityActivate())
            let sheet = try await host.completedNativePresentation(destinationLabel: "更多")
            XCTAssertFalse(sheet.contains { $0.label == "蓝牙车载歌词（实验）" })
            XCTAssertTrue(sheet.contains { $0.identifier == "music-sleep-timer-menu" })
            XCTAssertEqual(manager.sleepTimerMode, .off)
            XCTAssertEqual(manager.completionMode, completion)
            XCTAssertEqual(manager.isShuffleEnabled, shuffle)
            XCTAssertEqual(manager.currentTrack, track)
            XCTAssertEqual(manager.queue, queue)
            XCTAssertFalse(manager.isPlaying)
            XCTAssertEqual(manager.timeline.currentTime, position, accuracy: 0.01)
            let done = try await self.lifecycleButton(in: host, modal: true, label: "完成")
            XCTAssertTrue(done.object.accessibilityActivate())
            _ = try await host.completedNativePresentation(destinationLabel: nil)
            let returned = try await self.lifecycleButton(in: host, modal: false,
                identifier: "music-player-more-entry", label: "更多")
            XCTAssertTrue(host.viewportScreenFrame.contains(try host.validatedFrame(returned)))
        }
    }

    func testHostedPlayerMoreOmitsBluetoothSwitchWithoutSynchronizedLyrics() async throws {
        try await calibrateReader()
        try await withPostRemovalHost(size: .accessibility5) { host, manager, _ in
            let more = try await self.lifecycleButton(in: host, modal: false,
                identifier: "music-player-more-entry", label: "更多")
            XCTAssertTrue(more.object.accessibilityActivate())
            let sheet = try await host.completedNativePresentation(destinationLabel: "更多")
            XCTAssertFalse(sheet.contains { $0.label == "蓝牙车载歌词（实验）" })
            XCTAssertTrue(sheet.contains { $0.label == "当前歌曲无可用同步歌词" })
            XCTAssertTrue(manager.isBluetoothCarLyricsEnabled)
            XCTAssertFalse(manager.isPlaying)
            let done = try await self.lifecycleButton(in: host, modal: true, label: "完成")
            XCTAssertTrue(done.object.accessibilityActivate())
            _ = try await host.completedNativePresentation(destinationLabel: nil)
        }
    }
}
