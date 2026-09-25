import AVFoundation
import Darwin
import XCTest
@testable import DrivePlayer

final class VideoLibrarySearchTests: XCTestCase {
    func testVideoLibrarySearchTrimsQueryFiltersFileNamesCaseInsensitivelyAndPreservesOrder() {
        let videos = [
            VideoItem(url: URL(fileURLWithPath: "/tmp/First Clip.MP4"), duration: nil),
            VideoItem(url: URL(fileURLWithPath: "/tmp/旅行记录.mov"), duration: nil),
            VideoItem(url: URL(fileURLWithPath: "/tmp/second clip.mp4"), duration: nil),
        ]

        XCTAssertEqual(VideoLibrarySearch.filter(videos, query: ""), videos)
        XCTAssertEqual(VideoLibrarySearch.filter(videos, query: "  \n\t "), videos)
        XCTAssertEqual(
            VideoLibrarySearch.filter(videos, query: "  CLIP  "),
            [videos[0], videos[2]]
        )
        XCTAssertEqual(VideoLibrarySearch.filter(videos, query: "旅行"), [videos[1]])
    }

    func testHomeViewSearchFiltersDisplayedVideosWithoutChangingPlayerOrder() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
        let homeViewURL = testsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DrivePlayer/Views/HomeView.swift")
        let source = try String(contentsOf: homeViewURL, encoding: .utf8)
        let compactSource = source.filter { !$0.isWhitespace }

        XCTAssertTrue(
            compactSource.contains("@StateprivatevarsearchText"),
            "HomeView must own search text state"
        )
        XCTAssertTrue(
            compactSource.contains("VideoLibrarySearch.filter(library.videos,query:searchText)"),
            "HomeView must derive its displayed videos by filtering the complete library"
        )
        XCTAssertTrue(
            compactSource.contains("List(displayedVideos)"),
            "HomeView's List must render the filtered displayed videos"
        )
        XCTAssertTrue(
            compactSource.contains(".searchable(text:$searchText,prompt:\"搜索视频\")"),
            "HomeView must expose system search with a clear Chinese video-search prompt"
        )
        XCTAssertTrue(
            compactSource.contains("orderedVideos:library.videos"),
            "PlayerView must retain the complete library order for auto-advance"
        )
    }

    func testHomeViewUsesSystemSearchEmptyStateOnlyForNonemptyLibraryWithNonblankQuery() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
        let homeViewURL = testsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DrivePlayer/Views/HomeView.swift")
        let source = try String(contentsOf: homeViewURL, encoding: .utf8)
        let compactSource = source.filter { !$0.isWhitespace }

        let emptyLibraryBranch = "elseiflibrary.videos.isEmpty{ContentUnavailableView{Label(\"还没有视频\""
        let noSearchMatchesBranch = "elseif!searchText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty&&displayedVideos.isEmpty{ContentUnavailableView.search(text:searchText)"

        XCTAssertTrue(
            compactSource.contains(emptyLibraryBranch),
            "HomeView's '还没有视频' state must remain restricted to a genuinely empty library"
        )
        XCTAssertTrue(
            compactSource.contains(noSearchMatchesBranch),
            "A nonblank search with no displayed videos must use the system search empty state"
        )
    }
}

private struct TestFileStat {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let accessTime: timespec
    let modificationTime: timespec
    let statusChangeTime: timespec
}

private struct LegacyV2PlaybackSourceIdentity: Codable {
    let size: Int
    let modificationTime: TimeInterval
}

private struct LegacyV2PlaybackHistoryRecord: Codable {
    let state: String
    let position: TimeInterval
    let duration: TimeInterval
}

private struct LegacyV2StoredPlaybackHistory: Codable {
    let source: LegacyV2PlaybackSourceIdentity
    let record: LegacyV2PlaybackHistoryRecord
}

private func testFileStat(at url: URL) throws -> TestFileStat {
    var value = stat()
    guard fstatat(AT_FDCWD, url.path, &value, 0) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return TestFileStat(
        device: value.st_dev,
        inode: value.st_ino,
        size: value.st_size,
        accessTime: value.st_atimespec,
        modificationTime: value.st_mtimespec,
        statusChangeTime: value.st_ctimespec
    )
}

private func restoreTestFileTimes(at url: URL, from original: TestFileStat) throws {
    let times = [original.accessTime, original.modificationTime]
    let result = times.withUnsafeBufferPointer {
        utimensat(AT_FDCWD, url.path, $0.baseAddress, 0)
    }
    guard result == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private actor ThumbnailGeneratorCounter {
    private(set) var value = 0
    private(set) var active = 0
    private(set) var maxActive = 0

    func increment() {
        value += 1
    }

    func begin() {
        value += 1
        active += 1
        maxActive = max(maxActive, active)
    }

    func end() {
        active -= 1
    }
}

private actor ThumbnailGeneratorGate {
    private var hasStarted = false
    private(set) var invocationCount = 0
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var generationWaiter: CheckedContinuation<Void, Never>?

    func generate() async -> CGImage? {
        invocationCount += 1
        hasStarted = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { generationWaiter = $0 }
        return makeThumbnailTestImage()
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        generationWaiter?.resume()
        generationWaiter = nil
    }
}

private func makeThumbnailTestImage() -> CGImage {
    let data = Data([255, 0, 0, 255]) as CFData
    let provider = CGDataProvider(data: data)!
    return CGImage(
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

final class BundleBrandTests: XCTestCase {
    func testBuiltHostAppDisplayNameIsViviPlayer() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "Vivi播放器")
    }
}

private actor VideoDurationLoaderProbe {
    private let duration: TimeInterval
    private var calls = 0

    init(duration: TimeInterval) {
        self.duration = duration
    }

    func loadDuration(for _: URL) -> TimeInterval? {
        calls += 1
        return duration
    }

    func callCount() -> Int {
        calls
    }
}

private actor ControllableReplacingVideoDurationProbe {
    private var calls = 0
    private var firstContinuation: CheckedContinuation<TimeInterval?, Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func loadDuration(for _: URL) async -> TimeInterval? {
        calls += 1
        if calls == 1 {
            startedContinuation?.resume()
            startedContinuation = nil
            return await withCheckedContinuation { firstContinuation = $0 }
        }
        return 99
    }

    func waitUntilFirstLoadStarts() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func completeFirstLoad() {
        firstContinuation?.resume(returning: 42)
        firstContinuation = nil
    }

    func callCount() -> Int { calls }
}

@MainActor
final class VideoLibraryMetadataSnapshotTests: XCTestCase {
    func testMediaMetadataSnapshotStoreStrongIdentityHasBoundedReadBudget() {
        XCTAssertEqual(MediaMetadataSnapshotStore.maximumFingerprintBytesRead, 3 * 64 * 1024)
    }

    func testMediaMetadataSnapshotStoreStrongIdentityDetectsReplacementOutsideSampledWindows() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MetadataIdentityUnsampledReplacement-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let mediaURL = temporaryRoot.appendingPathComponent("same-size.mp4")
        let restoredMTime = Date(timeIntervalSince1970: 1_700_000_000)
        let original = Data(repeating: 0x41, count: 512 * 1024)
        try original.write(to: mediaURL, options: .atomic)
        try fileManager.setAttributes([.modificationDate: restoredMTime], ofItemAtPath: mediaURL.path)

        let store = MediaMetadataSnapshotStore(
            fileURL: temporaryRoot.appendingPathComponent("MediaMetadataSnapshots.json")
        )
        let optionalOriginalIdentity = await store.sourceIdentity(for: mediaURL)
        let originalIdentity = try XCTUnwrap(optionalOriginalIdentity)

        var replacement = original
        replacement[100_000] = 0x42
        try replacement.write(to: mediaURL, options: .atomic)
        try fileManager.setAttributes([.modificationDate: restoredMTime], ofItemAtPath: mediaURL.path)
        let optionalReplacementIdentity = await store.sourceIdentity(for: mediaURL)
        let replacementIdentity = try XCTUnwrap(optionalReplacementIdentity)

        XCTAssertNotEqual(originalIdentity, replacementIdentity)
    }

    func testMediaMetadataSnapshotStoreRetriesUnchangedVideoSnapshotAfterWriteFailure() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let videoA = temporaryRoot.appendingPathComponent("A.mp4")
        try Data("video A".utf8).write(to: videoA)

        let blockedParent = temporaryRoot.appendingPathComponent("blockedParent")
        try Data("not a directory".utf8).write(to: blockedParent)
        let cacheFile = blockedParent.appendingPathComponent("MediaMetadataSnapshots.json")

        let snapshotStore = MediaMetadataSnapshotStore(fileURL: cacheFile)
        let firstRevision = await snapshotStore.beginRefresh(for: .video)
        await snapshotStore.replaceVideos(with: [videoA: 42], revision: firstRevision)

        try fileManager.removeItem(at: blockedParent)
        try fileManager.createDirectory(at: blockedParent, withIntermediateDirectories: false)

        let secondRevision = await snapshotStore.beginRefresh(for: .video)
        await snapshotStore.replaceVideos(with: [videoA: 42], revision: secondRevision)

        let reloadedStore = MediaMetadataSnapshotStore(fileURL: cacheFile)
        let persistedDuration = await reloadedStore.videoDuration(for: videoA)
        XCTAssertEqual(persistedDuration, 42)
    }

    func testMediaMetadataSnapshotStoreRejectsOlderVideoRefreshCommit() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheFile = temporaryRoot.appendingPathComponent("MediaMetadataSnapshots.json")
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let videoA = temporaryRoot.appendingPathComponent("A.mp4")
        let videoB = temporaryRoot.appendingPathComponent("B.mp4")
        try Data("video A".utf8).write(to: videoA)
        try Data("video B".utf8).write(to: videoB)

        let snapshotStore = MediaMetadataSnapshotStore(fileURL: cacheFile)
        let oldRevision = await snapshotStore.beginRefresh(for: .video)
        let newRevision = await snapshotStore.beginRefresh(for: .video)

        await snapshotStore.replaceVideos(
            with: [videoA: 11, videoB: 22],
            revision: newRevision
        )
        await snapshotStore.replaceVideos(
            with: [videoA: 11],
            revision: oldRevision
        )

        let reloadedStore = MediaMetadataSnapshotStore(fileURL: cacheFile)
        let persistedDuration = await reloadedStore.videoDuration(for: videoB)
        XCTAssertEqual(persistedDuration, 22)
    }

    func testMediaMetadataSnapshotStoreRejectsSnapshotsFromAnotherInstallationGeneration() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let cacheFile = temporaryRoot.appendingPathComponent("MediaMetadataSnapshots.json")
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let videoURL = temporaryRoot.appendingPathComponent("restored.mp4")
        try Data("restored media".utf8).write(to: videoURL)

        let firstStore = MediaMetadataSnapshotStore(
            fileURL: cacheFile,
            installationGeneration: "installation-A"
        )
        let revision = await firstStore.beginRefresh(for: .video)
        await firstStore.replaceVideos(with: [videoURL: 42], revision: revision)

        let restoredStore = MediaMetadataSnapshotStore(
            fileURL: cacheFile,
            installationGeneration: "installation-B"
        )

        let restoredDuration = await restoredStore.videoDuration(for: videoURL)
        XCTAssertNil(restoredDuration)
    }

    func testMediaMetadataSnapshotStoreFailsClosedWhenEntryCountExceedsBudget() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataSnapshotEntryBudget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let firstURL = temporaryRoot.appendingPathComponent("First.mp4")
        let secondURL = temporaryRoot.appendingPathComponent("Second.mp4")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let cacheURL = temporaryRoot.appendingPathComponent("MediaMetadataSnapshots.json")
        let writer = MediaMetadataSnapshotStore(fileURL: cacheURL)
        let revision = await writer.beginRefresh(for: .video)
        await writer.replaceVideos(with: [firstURL: 11, secondURL: 22], revision: revision)

        let boundedReader = MediaMetadataSnapshotStore(
            fileURL: cacheURL,
            maximumEntryCount: 1
        )
        let firstDuration = await boundedReader.videoDuration(for: firstURL)
        let secondDuration = await boundedReader.videoDuration(for: secondURL)

        XCTAssertNil(firstDuration)
        XCTAssertNil(secondDuration)
    }

    func testMediaMetadataSnapshotStoreFailsClosedWhenAggregatePayloadExceedsBudget() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataSnapshotPayloadBudget-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let songURL = temporaryRoot.appendingPathComponent("Song.mp3")
        try Data("song".utf8).write(to: songURL)
        let cacheURL = temporaryRoot.appendingPathComponent("MediaMetadataSnapshots.json")
        let writer = MediaMetadataSnapshotStore(fileURL: cacheURL)
        let optionalIdentity = await writer.sourceIdentity(for: songURL)
        let identity = try XCTUnwrap(optionalIdentity)
        let revision = await writer.beginRefresh(for: .music)
        await writer.replaceMusic(with: [
            songURL: MediaMetadataSnapshotStore.MusicSnapshot(
                fingerprint: identity,
                duration: 42,
                metadata: MusicMetadata(
                    title: String(repeating: "T", count: 64),
                    artist: nil,
                    album: nil,
                    artworkData: nil,
                    lyrics: nil,
                    synchronizedLyricsData: nil
                )
            )
        ], revision: revision)

        let boundedReader = MediaMetadataSnapshotStore(
            fileURL: cacheURL,
            maximumAggregatePayloadBytes: 32
        )
        let snapshot = await boundedReader.musicSnapshot(for: songURL)

        XCTAssertNil(snapshot)
    }

    func testMediaMetadataSnapshotStoreHandlesNearLimitOversizedMalformedAndFutureVersionCaches() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MetadataSnapshotEncodedBoundaries-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        let videoURL = temporaryRoot.appendingPathComponent("Clip.mp4")
        try Data("video".utf8).write(to: videoURL)
        let cacheURL = temporaryRoot.appendingPathComponent("MediaMetadataSnapshots.json")
        let writer = MediaMetadataSnapshotStore(fileURL: cacheURL)
        let revision = await writer.beginRefresh(for: .video)
        await writer.replaceVideos(with: [videoURL: 42], revision: revision)
        let validData = try Data(contentsOf: cacheURL)

        let nearLimitReader = MediaMetadataSnapshotStore(
            fileURL: cacheURL,
            maximumEncodedBytes: validData.count
        )
        let nearLimitDuration = await nearLimitReader.videoDuration(for: videoURL)
        XCTAssertEqual(nearLimitDuration, 42)

        let oversizedReader = MediaMetadataSnapshotStore(
            fileURL: cacheURL,
            maximumEncodedBytes: validData.count - 1
        )
        let oversizedDuration = await oversizedReader.videoDuration(for: videoURL)
        XCTAssertNil(oversizedDuration)

        try Data("{".utf8).write(to: cacheURL, options: .atomic)
        let malformedReader = MediaMetadataSnapshotStore(fileURL: cacheURL)
        let malformedDuration = await malformedReader.videoDuration(for: videoURL)
        XCTAssertNil(malformedDuration)

        var futureObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        futureObject["version"] = 999
        let futureData = try JSONSerialization.data(withJSONObject: futureObject)
        try futureData.write(to: cacheURL, options: .atomic)
        let futureReader = MediaMetadataSnapshotStore(fileURL: cacheURL)
        let futureDuration = await futureReader.videoDuration(for: videoURL)
        XCTAssertNil(futureDuration)
    }

    func testVideoLibraryRefreshReusesPersistedDurationAcrossStoreInstancesForUnchangedFile() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let legacyAudio = temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true)
        let legacyVideo = temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        let cacheFile = temporaryRoot.appendingPathComponent("MediaMetadataSnapshots.json")
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let videoURL = documents.appendingPathComponent("unchanged.mp4")
        try Data("video fixture".utf8).write(to: videoURL)

        let firstProbe = VideoDurationLoaderProbe(duration: 42)
        do {
            let storage = MediaLibraryStorage(
                rootURL: documents,
                legacyAudioURL: legacyAudio,
                legacyVideoURL: legacyVideo,
                fileManager: fileManager
            )
            let snapshotStore = MediaMetadataSnapshotStore(fileURL: cacheFile)
            let library = VideoLibrary(
                storage: storage,
                metadataSnapshotStore: snapshotStore,
                durationLoader: { url in await firstProbe.loadDuration(for: url) }
            )

            await library.refresh()

            let firstCallCount = await firstProbe.callCount()
            XCTAssertEqual(try XCTUnwrap(library.videos.first).duration, 42)
            XCTAssertEqual(firstCallCount, 1)
        }

        let secondProbe = VideoDurationLoaderProbe(duration: 99)
        do {
            let storage = MediaLibraryStorage(
                rootURL: documents,
                legacyAudioURL: legacyAudio,
                legacyVideoURL: legacyVideo,
                fileManager: fileManager
            )
            let snapshotStore = MediaMetadataSnapshotStore(fileURL: cacheFile)
            let library = VideoLibrary(
                storage: storage,
                metadataSnapshotStore: snapshotStore,
                durationLoader: { url in await secondProbe.loadDuration(for: url) }
            )

            await library.refresh()

            let secondCallCount = await secondProbe.callCount()
            XCTAssertEqual(try XCTUnwrap(library.videos.first).duration, 42)
            XCTAssertEqual(secondCallCount, 0)
        }
    }

    func testVideoLibraryRefreshInvalidatesPersistedDurationWhenFileFingerprintChanges() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let legacyAudio = temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true)
        let legacyVideo = temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        let cacheFile = temporaryRoot.appendingPathComponent("MediaMetadataSnapshots.json")
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let videoURL = documents.appendingPathComponent("replaced.mp4")
        try Data("first video fixture".utf8).write(to: videoURL)
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: videoURL.path
        )

        let firstProbe = VideoDurationLoaderProbe(duration: 42)
        do {
            let storage = MediaLibraryStorage(
                rootURL: documents,
                legacyAudioURL: legacyAudio,
                legacyVideoURL: legacyVideo,
                fileManager: fileManager
            )
            let snapshotStore = MediaMetadataSnapshotStore(fileURL: cacheFile)
            let library = VideoLibrary(
                storage: storage,
                metadataSnapshotStore: snapshotStore,
                durationLoader: { url in await firstProbe.loadDuration(for: url) }
            )

            await library.refresh()

            let firstCallCount = await firstProbe.callCount()
            XCTAssertEqual(try XCTUnwrap(library.videos.first).duration, 42)
            XCTAssertEqual(firstCallCount, 1)
        }

        try Data("second video fixture with a different byte length".utf8).write(to: videoURL)
        try fileManager.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_100)],
            ofItemAtPath: videoURL.path
        )

        let secondProbe = VideoDurationLoaderProbe(duration: 99)
        do {
            let storage = MediaLibraryStorage(
                rootURL: documents,
                legacyAudioURL: legacyAudio,
                legacyVideoURL: legacyVideo,
                fileManager: fileManager
            )
            let snapshotStore = MediaMetadataSnapshotStore(fileURL: cacheFile)
            let library = VideoLibrary(
                storage: storage,
                metadataSnapshotStore: snapshotStore,
                durationLoader: { url in await secondProbe.loadDuration(for: url) }
            )

            await library.refresh()

            let secondCallCount = await secondProbe.callCount()
            XCTAssertEqual(try XCTUnwrap(library.videos.first).duration, 99)
            XCTAssertEqual(secondCallCount, 1)
        }
    }

    func testVideoLibraryRefreshInvalidatesPersistedDurationForSameSizeReplacementWithRestoredMTime() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let cacheFile = temporaryRoot.appendingPathComponent("MediaMetadataSnapshots.json")
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let videoURL = documents.appendingPathComponent("same-size.mp4")
        let restoredMTime = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("AAAA".utf8).write(to: videoURL, options: .atomic)
        try fileManager.setAttributes([.modificationDate: restoredMTime], ofItemAtPath: videoURL.path)

        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio"),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos"),
            fileManager: fileManager
        )
        let firstProbe = VideoDurationLoaderProbe(duration: 42)
        let firstLibrary = VideoLibrary(
            storage: storage,
            metadataSnapshotStore: MediaMetadataSnapshotStore(fileURL: cacheFile),
            durationLoader: { url in await firstProbe.loadDuration(for: url) }
        )
        await firstLibrary.refresh()

        try Data("BBBB".utf8).write(to: videoURL, options: .atomic)
        try fileManager.setAttributes([.modificationDate: restoredMTime], ofItemAtPath: videoURL.path)

        let secondProbe = VideoDurationLoaderProbe(duration: 99)
        let secondLibrary = VideoLibrary(
            storage: storage,
            metadataSnapshotStore: MediaMetadataSnapshotStore(fileURL: cacheFile),
            durationLoader: { url in await secondProbe.loadDuration(for: url) }
        )
        await secondLibrary.refresh()

        let secondCallCount = await secondProbe.callCount()
        XCTAssertEqual(secondLibrary.videos.first?.duration, 99)
        XCTAssertEqual(secondCallCount, 1)
    }

    func testVideoLibraryRefreshRetriesWhenSourceIsReplacedDuringDurationLoad() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let videoURL = documents.appendingPathComponent("in-flight.mp4")
        let restoredMTime = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("AAAA".utf8).write(to: videoURL, options: .atomic)
        try fileManager.setAttributes([.modificationDate: restoredMTime], ofItemAtPath: videoURL.path)

        let probe = ControllableReplacingVideoDurationProbe()
        let library = VideoLibrary(
            storage: MediaLibraryStorage(
                rootURL: documents,
                legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio"),
                legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos"),
                fileManager: fileManager
            ),
            metadataSnapshotStore: MediaMetadataSnapshotStore(
                fileURL: temporaryRoot.appendingPathComponent("MediaMetadataSnapshots.json")
            ),
            durationLoader: { url in await probe.loadDuration(for: url) }
        )

        let refresh = Task { await library.refresh() }
        await probe.waitUntilFirstLoadStarts()
        try Data("BBBB".utf8).write(to: videoURL, options: .atomic)
        try fileManager.setAttributes([.modificationDate: restoredMTime], ofItemAtPath: videoURL.path)
        await probe.completeFirstLoad()
        await refresh.value

        let callCount = await probe.callCount()
        XCTAssertEqual(library.videos.first?.duration, 99)
        XCTAssertEqual(callCount, 2)
    }

    @MainActor
    func testVideoLibraryRefreshDiscardsDurationWhenSourceIsDeletedDuringLoad() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoDeletedDuringDurationLoad-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let documentsURL = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        let videoURL = documentsURL.appendingPathComponent("Deleted.mp4")
        try Data("AAAA".utf8).write(to: videoURL)

        let probe = ControllableReplacingVideoDurationProbe()
        let storage = MediaLibraryStorage(
            rootURL: documentsURL,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        )
        let library = VideoLibrary(
            storage: storage,
            metadataSnapshotStore: MediaMetadataSnapshotStore(
                fileURL: temporaryRoot.appendingPathComponent("MediaMetadataSnapshots.json")
            ),
            durationLoader: { url in await probe.loadDuration(for: url) }
        )

        let refresh = Task { await library.refresh() }
        await probe.waitUntilFirstLoadStarts()
        try FileManager.default.removeItem(at: videoURL)
        await probe.completeFirstLoad()
        await refresh.value

        XCTAssertTrue(library.videos.isEmpty)
        XCTAssertFalse(library.isLoading)
    }
}

@MainActor
final class MediaLibraryStorageClassificationTests: XCTestCase {
    func testLyricSidecarScanIsFlatRegularNonSymlinkAndLowercaseExtensionDeterministic() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let legacyAudio = temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true)
        let legacyVideo = temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        for name in ["Song.lrc", "Other.LRC", ".hidden.lrc"] {
            XCTAssertTrue(fileManager.createFile(
                atPath: documents.appendingPathComponent(name).path,
                contents: Data()
            ))
        }
        try fileManager.createDirectory(
            at: documents.appendingPathComponent("Folder.lrc", isDirectory: true),
            withIntermediateDirectories: true
        )
        let album = documents.appendingPathComponent("Album", isDirectory: true)
        try fileManager.createDirectory(at: album, withIntermediateDirectories: true)
        XCTAssertTrue(fileManager.createFile(
            atPath: album.appendingPathComponent("Nested.lrc").path,
            contents: Data()
        ))
        let outside = temporaryRoot.appendingPathComponent("Outside.lrc")
        XCTAssertTrue(fileManager.createFile(atPath: outside.path, contents: Data()))
        try fileManager.createSymbolicLink(
            at: documents.appendingPathComponent("Linked.lrc"),
            withDestinationURL: outside
        )

        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: legacyAudio,
            legacyVideoURL: legacyVideo,
            fileManager: fileManager
        )

        XCTAssertEqual(try storage.scanLyricSidecars().map(\.lastPathComponent).sorted(), ["Song.lrc"])
    }

    func testLyricSidecarReadRejectsSymlinkSubstitutionAfterScan() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let legacyAudio = temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true)
        let legacyVideo = temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let originalBytes = Data("[00:01.00]Original lyric\n".utf8)
        let outsideBytes = Data("[00:02.00]Outside lyric\n".utf8)
        let lyricURL = documents.appendingPathComponent("Song.lrc")
        let outsideURL = temporaryRoot.appendingPathComponent("Outside.lrc")
        try originalBytes.write(to: lyricURL)
        try outsideBytes.write(to: outsideURL)

        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: legacyAudio,
            legacyVideoURL: legacyVideo,
            fileManager: fileManager
        )
        let scannedURL = try XCTUnwrap(storage.scanLyricSidecars().first)

        try fileManager.removeItem(at: scannedURL)
        try fileManager.createSymbolicLink(at: scannedURL, withDestinationURL: outsideURL)

        XCTAssertThrowsError(try storage.readLyricSidecarData(at: scannedURL))
        XCTAssertEqual(try Data(contentsOf: outsideURL), outsideBytes)
    }

    func testLyricSidecarReadRejectsFIFOReplacementAfterScan() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let legacyAudio = temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true)
        let legacyVideo = temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let lyricURL = documents.appendingPathComponent("Song.lrc")
        try Data("[00:01.00]Original lyric\n".utf8).write(to: lyricURL)

        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: legacyAudio,
            legacyVideoURL: legacyVideo,
            fileManager: fileManager
        )
        let scannedURL = try XCTUnwrap(storage.scanLyricSidecars().first)

        try fileManager.removeItem(at: scannedURL)
        let fifoResult = scannedURL.path.withCString { Darwin.mkfifo($0, 0o600) }
        guard fifoResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let writerFinished = expectation(description: "FIFO writer finished")
        DispatchQueue.global().async {
            defer { writerFinished.fulfill() }
            let descriptor = scannedURL.path.withCString { Darwin.open($0, O_WRONLY) }
            guard descriptor >= 0 else { return }
            defer { Darwin.close(descriptor) }
            let bytes = Array("[00:02.00]FIFO lyric\n".utf8)
            bytes.withUnsafeBytes { buffer in
                _ = Darwin.write(descriptor, buffer.baseAddress, buffer.count)
            }
        }

        XCTAssertThrowsError(try storage.readLyricSidecarData(at: scannedURL))
        let cleanupReader = scannedURL.path.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK) }
        defer {
            if cleanupReader >= 0 {
                Darwin.close(cleanupReader)
            }
        }
        wait(for: [writerFinished], timeout: 2)
    }

    func testLyricSidecarReadRejectsHardLinkedFile() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let legacyAudio = temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true)
        let legacyVideo = temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let outsideBytes = Data("[00:02.00]Outside lyric\n".utf8)
        let outsideURL = temporaryRoot.appendingPathComponent("Outside.lrc")
        let linkedURL = documents.appendingPathComponent("Linked.lrc")
        try outsideBytes.write(to: outsideURL)
        let linkResult = outsideURL.path.withCString { sourcePath in
            linkedURL.path.withCString { destinationPath in
                Darwin.link(sourcePath, destinationPath)
            }
        }
        guard linkResult == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: legacyAudio,
            legacyVideoURL: legacyVideo,
            fileManager: fileManager
        )
        let scannedURL = try XCTUnwrap(storage.scanLyricSidecars().first)

        XCTAssertEqual(scannedURL.lastPathComponent, "Linked.lrc")
        XCTAssertThrowsError(try storage.readLyricSidecarData(at: scannedURL))
        XCTAssertEqual(try Data(contentsOf: outsideURL), outsideBytes)
    }

    func testLyricSidecarReadReturnsExactBytesForScannedRegularFile() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let legacyAudio = temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true)
        let legacyVideo = temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let expectedBytes = Data([0xEF, 0xBB, 0xBF])
            + Data("[00:01.25]第一句 🎵\r\n[00:02.50]Second line\n".utf8)
        let lyricURL = documents.appendingPathComponent("Song.lrc")
        try expectedBytes.write(to: lyricURL)

        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: legacyAudio,
            legacyVideoURL: legacyVideo,
            fileManager: fileManager
        )
        let scannedURL = try XCTUnwrap(storage.scanLyricSidecars().first)

        XCTAssertEqual(try storage.readLyricSidecarData(at: scannedURL), expectedBytes)
    }

    func testLyricSidecarReadRejectsSizeChangeAfterInitialFstat() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let lyricURL = root.appendingPathComponent("Song.lrc")
        try Data("[00:01.00]Lyric\n".utf8).write(to: lyricURL)

        let storage = MediaLibraryStorage(
            rootURL: root,
            legacyAudioURL: root.appendingPathComponent("legacy-audio"),
            legacyVideoURL: root.appendingPathComponent("legacy-video"),
            lyricSidecarPreReadHook: {
                let handle = try FileHandle(forWritingTo: lyricURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data([0]))
            }
        )

        XCTAssertThrowsError(try storage.readLyricSidecarData(at: lyricURL))
    }

    func testLyricSidecarReadRejectsFileOver512KiBBeforeReading() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let legacyAudio = temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true)
        let legacyVideo = temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let lyricURL = documents.appendingPathComponent("Big.lrc")
        try Data(count: 512 * 1024 + 1).write(to: lyricURL)

        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: legacyAudio,
            legacyVideoURL: legacyVideo,
            fileManager: fileManager
        )
        let scannedURL = try XCTUnwrap(storage.scanLyricSidecars().first)

        XCTAssertEqual(scannedURL.lastPathComponent, "Big.lrc")
        XCTAssertThrowsError(try storage.readLyricSidecarData(at: scannedURL))
    }

    func testRootScanClassifiesSupportedExtensionsCaseInsensitivelyAndIgnoresOtherEntries() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let legacyAudio = temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true)
        let legacyVideo = temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        for name in ["song.MP3", "lossless.flac", "movie.MkV", "clip.MP4", "notes.txt", ".hidden.m4a"] {
            XCTAssertTrue(fileManager.createFile(
                atPath: documents.appendingPathComponent(name).path,
                contents: Data()
            ))
        }
        let nested = documents.appendingPathComponent("Album", isDirectory: true)
        try fileManager.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertTrue(fileManager.createFile(
            atPath: nested.appendingPathComponent("nested.mp3").path,
            contents: Data()
        ))

        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: legacyAudio,
            legacyVideoURL: legacyVideo,
            fileManager: fileManager
        )

        XCTAssertEqual(try storage.scan(kind: .audio).map(\.lastPathComponent).sorted(), [
            "lossless.flac", "song.MP3"
        ])
        XCTAssertEqual(try storage.scan(kind: .video).map(\.lastPathComponent).sorted(), [
            "clip.MP4", "movie.MkV"
        ])
    }
}

private final class FailingMoveFileManager: FileManager {
    var failingFileName: String?

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.lastPathComponent == failingFileName {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}

@MainActor
final class MediaLibraryStorageMigrationTests: XCTestCase {
    func testMigrationPreservesCollisionsAndRetriesFilesWhoseMoveFailed() throws {
        let fileManager = FailingMoveFileManager()
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let legacyAudio = temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true)
        let legacyVideo = temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        for directory in [documents, legacyAudio, legacyVideo] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        try Data("root".utf8).write(to: documents.appendingPathComponent("shared.mp3"))
        try Data("legacy".utf8).write(to: legacyAudio.appendingPathComponent("shared.mp3"))
        try Data("video".utf8).write(to: legacyVideo.appendingPathComponent("movie.mp4"))
        try Data("retry".utf8).write(to: legacyVideo.appendingPathComponent("retry.mov"))
        fileManager.failingFileName = "retry.mov"

        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: legacyAudio,
            legacyVideoURL: legacyVideo,
            fileManager: fileManager
        )
        storage.migrateLegacyFiles()

        XCTAssertEqual(try Data(contentsOf: documents.appendingPathComponent("shared.mp3")), Data("root".utf8))
        XCTAssertEqual(try Data(contentsOf: documents.appendingPathComponent("shared (2).mp3")), Data("legacy".utf8))
        XCTAssertTrue(fileManager.fileExists(atPath: documents.appendingPathComponent("movie.mp4").path))
        XCTAssertTrue(fileManager.fileExists(atPath: legacyVideo.appendingPathComponent("retry.mov").path))

        fileManager.failingFileName = nil
        storage.migrateLegacyFiles()
        storage.migrateLegacyFiles()

        XCTAssertTrue(fileManager.fileExists(atPath: documents.appendingPathComponent("retry.mov").path))
        XCTAssertFalse(fileManager.fileExists(atPath: legacyVideo.appendingPathComponent("retry.mov").path))
        XCTAssertFalse(fileManager.fileExists(atPath: documents.appendingPathComponent("retry (2).mov").path))
    }
}

@MainActor
final class MediaLibraryStorageImportTests: XCTestCase {
    func testImportCopiesIntoRootWithoutOverwritingDuplicateNames() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let sources = temporaryRoot.appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let source = sources.appendingPathComponent("song.mp3")
        try Data("new".utf8).write(to: source)
        try Data("existing".utf8).write(to: documents.appendingPathComponent("song.mp3"))
        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio"),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos"),
            fileManager: fileManager
        )

        let second = try storage.importFile(from: source)
        let third = try storage.importFile(from: source)

        XCTAssertEqual(second.lastPathComponent, "song (2).mp3")
        XCTAssertEqual(third.lastPathComponent, "song (3).mp3")
        XCTAssertEqual(try Data(contentsOf: documents.appendingPathComponent("song.mp3")), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data("new".utf8))
        XCTAssertFalse(try fileManager.contentsOfDirectory(atPath: documents.path).contains {
            $0.hasPrefix(".importing-")
        })
    }
}

@MainActor
final class MediaLibraryStorageDeletionTests: XCTestCase {
    func testDeleteDoesNotRecursivelyRemoveDirectorySwappedInAfterValidation() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let candidate = documents.appendingPathComponent("race.mp3")
        let sentinel = candidate.appendingPathComponent("sentinel.txt")
        try Data().write(to: candidate)
        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio"),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos"),
            fileManager: fileManager,
            preUnlink: {
                try fileManager.removeItem(at: candidate)
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
                try Data("keep".utf8).write(to: sentinel)
            }
        )

        XCTAssertThrowsError(try storage.deleteFile(at: candidate))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testDeleteOnlyRemovesRegularFileWhoseParentIsExactlyManagedRoot() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let outside = temporaryRoot.appendingPathComponent("Outside", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let insideFile = documents.appendingPathComponent("inside.mp3")
        let outsideFile = outside.appendingPathComponent("outside.mp3")
        let nestedDirectory = documents.appendingPathComponent("Album", isDirectory: true)
        try Data().write(to: insideFile)
        try Data().write(to: outsideFile)
        try fileManager.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio"),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos"),
            fileManager: fileManager
        )

        try storage.deleteFile(at: insideFile)
        XCTAssertFalse(fileManager.fileExists(atPath: insideFile.path))
        XCTAssertThrowsError(try storage.deleteFile(at: outsideFile))
        XCTAssertTrue(fileManager.fileExists(atPath: outsideFile.path))
        XCTAssertThrowsError(try storage.deleteFile(at: nestedDirectory))
        XCTAssertTrue(fileManager.fileExists(atPath: nestedDirectory.path))
    }

    func testDeleteRejectsSymlinkWithoutDeletingItsTarget() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let target = temporaryRoot.appendingPathComponent("target.mp3")
        let link = documents.appendingPathComponent("link.mp3")
        try Data("target".utf8).write(to: target)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio"),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos"),
            fileManager: fileManager
        )

        XCTAssertThrowsError(try storage.deleteFile(at: link))
        XCTAssertEqual(try Data(contentsOf: target), Data("target".utf8))
        XCTAssertTrue(fileManager.fileExists(atPath: link.path))
    }
}

@MainActor
final class MusicDeletionPlaybackIntegrationTests: XCTestCase {
    private final class ControllablePlaybackStatusProbe: MusicPlaybackStatusObserving {
        private var handlers: [(@MainActor (AVPlayer.TimeControlStatus) -> Void)] = []

        func observe(
            _ player: AVPlayer,
            handler: @escaping @MainActor (AVPlayer.TimeControlStatus) -> Void
        ) {
            handlers.append(handler)
        }

        func invalidate() {
            // Keep captured callbacks so tests can deterministically deliver stale events.
        }

        func send(_ status: AVPlayer.TimeControlStatus) {
            handlers.last?(status)
        }

        func send(_ status: AVPlayer.TimeControlStatus, transition index: Int) {
            handlers[index](status)
        }
    }

    private final class NowPlayingControllerProbe: MusicNowPlayingControlling {
        private var handler: (@MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult)?
        func publish(_ snapshot: NowPlayingSnapshot) {}
        func clear() {}
        func registerRemoteCommands(handler: @escaping @MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult) {
            self.handler = handler
        }
        func send(_ command: MusicRemoteCommand) -> MusicRemoteCommandResult {
            handler?(command) ?? .commandFailed
        }
    }

    private final class SleepCancellationProbe: MusicSleepTimerCancellation {
        func cancel() {}
    }

    private func pendingPlayback(
        ownership: PlaybackOwnershipCoordinator? = nil,
        nowPlayingController: MusicNowPlayingControlling? = nil,
        sleepTimerClock: MusicSleepTimerClock = .live,
        scheduleSleepTimer: @escaping MusicSleepTimerSchedule = { _, _ in SleepCancellationProbe() }
    ) throws -> (MusicPlaybackManager, MusicRecentlyPlayedStore, ControllablePlaybackStatusProbe, MusicItem) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PendingPlayback.\(UUID().uuidString)"))
        let recent = MusicRecentlyPlayedStore(defaults: defaults)
        let probe = ControllablePlaybackStatusProbe()
        let song = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/pending.mp3"),
            duration: 60,
            favoriteSourceIdentity: .init(fileSize: 1, contentSHA256Hex: String(repeating: "a", count: 64))
        )
        let playback = MusicPlaybackManager(
            player: AVPlayer(), defaults: defaults, ownership: ownership, activateAudioSession: {},
            nowPlayingController: nowPlayingController, recentlyPlayed: recent,
            playbackStatusObserver: probe, sleepTimerClock: sleepTimerClock,
            scheduleSleepTimer: scheduleSleepTimer
        )
        playback.updateQueue([song])
        playback.play(song)
        XCTAssertTrue(playback.isPlaying, "Successful play intent preserves the public playback contract")
        XCTAssertTrue(recent.isEmpty, "History still waits for audible confirmation")
        return (playback, recent, probe, song)
    }

    private func assertLateConfirmationIsCancelled(
        _ playback: MusicPlaybackManager,
        recent: MusicRecentlyPlayedStore,
        probe: ControllablePlaybackStatusProbe,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        probe.send(.playing)
        XCTAssertFalse(playback.isPlaying, file: file, line: line)
        XCTAssertTrue(recent.isEmpty, file: file, line: line)
    }

    private func deferredRecentPlaybackSetup() throws -> (
        root: URL,
        defaults: UserDefaults,
        playback: MusicPlaybackManager,
        recent: MusicRecentlyPlayedStore,
        probe: ControllablePlaybackStatusProbe,
        nilIdentityItem: MusicItem,
        enrichedItem: MusicItem
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("deferred.mp3")
        try Data("stable-source".utf8).write(to: url)
        let suiteName = "DeferredRecentPlayback.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let recent = MusicRecentlyPlayedStore(defaults: defaults)
        let probe = ControllablePlaybackStatusProbe()
        let nilIdentityItem = MusicItem(url: url, duration: 60)
        let enrichedItem = MusicItem(
            url: url,
            duration: 60,
            favoriteSourceIdentity: .init(
                fileSize: 13,
                contentSHA256Hex: String(repeating: "a", count: 64)
            )
        )
        let playback = MusicPlaybackManager(
            player: AVPlayer(), defaults: defaults, activateAudioSession: {},
            recentlyPlayed: recent, playbackStatusObserver: probe
        )
        return (root, defaults, playback, recent, probe, nilIdentityItem, enrichedItem)
    }

    func testAudibleNilIdentityStartRecordsOnceWhenSameSourceIsEnriched() throws {
        let setup = try deferredRecentPlaybackSetup()
        defer { try? FileManager.default.removeItem(at: setup.root) }
        setup.playback.updateQueue([setup.nilIdentityItem])
        setup.playback.play(setup.nilIdentityItem)
        setup.probe.send(.playing)
        XCTAssertTrue(setup.recent.isEmpty)

        setup.playback.updateQueue([setup.enrichedItem])

        XCTAssertEqual(setup.recent.orderedMatchingSongs(in: [setup.enrichedItem]), [setup.enrichedItem])
        let revision = setup.recent.revision
        setup.playback.updateQueue([setup.enrichedItem])
        setup.probe.send(.playing)
        XCTAssertEqual(setup.recent.revision, revision)
    }

    func testNilIdentityStartEnrichedBeforePlayingRecordsOnConfirmation() throws {
        let setup = try deferredRecentPlaybackSetup()
        defer { try? FileManager.default.removeItem(at: setup.root) }
        setup.playback.updateQueue([setup.nilIdentityItem])
        setup.playback.play(setup.nilIdentityItem)

        setup.playback.updateQueue([setup.enrichedItem])
        XCTAssertTrue(setup.recent.isEmpty)
        setup.probe.send(.playing)

        XCTAssertEqual(setup.recent.orderedMatchingSongs(in: [setup.enrichedItem]), [setup.enrichedItem])
    }

    func testNilIdentityAudibleMarkerRejectsReplacedLogicalOrLoadedSource() throws {
        let setup = try deferredRecentPlaybackSetup()
        defer { try? FileManager.default.removeItem(at: setup.root) }
        setup.playback.updateQueue([setup.nilIdentityItem])
        setup.playback.play(setup.nilIdentityItem)
        setup.probe.send(.playing)

        let replacementURL = setup.root.appendingPathComponent("other", isDirectory: true)
            .appendingPathComponent(setup.nilIdentityItem.fileName)
        try FileManager.default.createDirectory(
            at: replacementURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("replacement".utf8).write(to: replacementURL)
        let replacement = MusicItem(
            url: replacementURL, duration: 60,
            favoriteSourceIdentity: setup.enrichedItem.favoriteSourceIdentity
        )
        setup.playback.updateQueue([replacement])
        XCTAssertTrue(setup.recent.isEmpty)

        let lowLevelSetup = try deferredRecentPlaybackSetup()
        defer { try? FileManager.default.removeItem(at: lowLevelSetup.root) }
        lowLevelSetup.playback.updateQueue([lowLevelSetup.nilIdentityItem])
        lowLevelSetup.playback.play(lowLevelSetup.nilIdentityItem)
        lowLevelSetup.probe.send(.playing)
        try FileManager.default.removeItem(at: lowLevelSetup.nilIdentityItem.url)
        try Data("new-low-level-source".utf8).write(to: lowLevelSetup.nilIdentityItem.url)
        lowLevelSetup.playback.updateQueue([lowLevelSetup.enrichedItem])
        XCTAssertTrue(lowLevelSetup.recent.isEmpty)
    }

    func testCancellationAfterNilIdentityAudibleStartRejectsEnrichmentAndLatePlaying() throws {
        let setup = try deferredRecentPlaybackSetup()
        defer { try? FileManager.default.removeItem(at: setup.root) }
        setup.playback.updateQueue([setup.nilIdentityItem])
        setup.playback.play(setup.nilIdentityItem)
        setup.probe.send(.playing)
        setup.playback.pause()

        setup.playback.updateQueue([setup.enrichedItem])
        setup.probe.send(.playing)

        XCTAssertTrue(setup.recent.isEmpty)
    }

    func testIdentityEnrichmentWithoutPlaybackMarkerNeverRecordsRecent() throws {
        let setup = try deferredRecentPlaybackSetup()
        defer { try? FileManager.default.removeItem(at: setup.root) }
        setup.playback.updateQueue([setup.nilIdentityItem])

        setup.playback.updateQueue([setup.enrichedItem])

        XCTAssertTrue(setup.recent.isEmpty)
        XCTAssertEqual(setup.recent.revision, 0)
    }

    func testRepeatedEnrichmentAndStatusCallbacksDoNotChurnRecentRevision() throws {
        let setup = try deferredRecentPlaybackSetup()
        defer { try? FileManager.default.removeItem(at: setup.root) }
        setup.playback.updateQueue([setup.nilIdentityItem])
        setup.playback.play(setup.nilIdentityItem)
        setup.probe.send(.playing)
        setup.playback.updateQueue([setup.enrichedItem])
        let revision = setup.recent.revision

        setup.playback.updateQueue([setup.enrichedItem])
        setup.playback.updateQueue([setup.enrichedItem])
        setup.probe.send(.playing)
        setup.probe.send(.playing)

        XCTAssertEqual(setup.recent.revision, revision)
    }

    func testMinutesSleepExpiryCancelsPendingAudibleConfirmation() throws {
        var monotonic = 0.0
        var wall = Date(timeIntervalSince1970: 1_000)
        var expiration: (@MainActor () -> Void)?
        let setup = try pendingPlayback(
            sleepTimerClock: .init(monotonicNow: { monotonic }, wallNow: { wall }),
            scheduleSleepTimer: { _, action in expiration = action; return SleepCancellationProbe() }
        )
        setup.0.setSleepTimerMode(.minutes15)
        monotonic = 901; wall = wall.addingTimeInterval(901)
        expiration?()
        assertLateConfirmationIsCancelled(setup.0, recent: setup.1, probe: setup.2)
    }

    func testStopAfterCurrentCoherentStopCancelsPendingAudibleConfirmation() async throws {
        let setup = try pendingPlayback()
        setup.0.setSleepTimerMode(.stopAfterCurrentTrack)
        let player = try XCTUnwrap(Mirror(reflecting: setup.0).descendant("player") as? AVPlayer)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: player.currentItem)
        await Task.yield()
        assertLateConfirmationIsCancelled(setup.0, recent: setup.1, probe: setup.2)
    }

    func testInterruptionBeganCancelsPendingAudibleConfirmation() async throws {
        let setup = try pendingPlayback()
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        await Task.yield()
        assertLateConfirmationIsCancelled(setup.0, recent: setup.1, probe: setup.2)
    }

    func testOldDeviceUnavailableCancelsPendingAudibleConfirmation() async throws {
        let setup = try pendingPlayback()
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        )
        await Task.yield()
        assertLateConfirmationIsCancelled(setup.0, recent: setup.1, probe: setup.2)
    }

    func testLocalToggleCancelsPendingAttemptAndLateConfirmation() throws {
        let setup = try pendingPlayback()
        setup.0.togglePlayback()
        assertLateConfirmationIsCancelled(setup.0, recent: setup.1, probe: setup.2)
    }

    func testRemotePauseSucceedsAndCancelsPendingAttemptAndLateConfirmation() throws {
        let controller = NowPlayingControllerProbe()
        let setup = try pendingPlayback(nowPlayingController: controller)
        XCTAssertEqual(controller.send(.pause), .success)
        assertLateConfirmationIsCancelled(setup.0, recent: setup.1, probe: setup.2)
    }

    func testExplicitRetryAfterCancelledPendingAttemptRecordsExactlyOnce() throws {
        let setup = try pendingPlayback()
        setup.0.pause()
        setup.2.send(.playing, transition: 0)
        XCTAssertTrue(setup.1.isEmpty)

        setup.0.play()
        XCTAssertTrue(setup.0.isPlaying)
        setup.2.send(.playing, transition: 0)
        XCTAssertTrue(setup.1.isEmpty, "Stale observer cannot confirm the retry")
        setup.2.send(.playing, transition: 1)
        XCTAssertEqual(setup.1.orderedMatchingSongs(in: [setup.3]), [setup.3])
        let revision = setup.1.revision
        setup.2.send(.playing, transition: 1)
        XCTAssertEqual(setup.1.revision, revision)
    }

    func testOwnershipLossInvalidatesPendingAudibleConfirmation() throws {
        let ownership = PlaybackOwnershipCoordinator()
        let setup = try pendingPlayback(ownership: ownership)
        _ = ownership.videoPlaybackRequested {}
        setup.2.send(.playing)
        XCTAssertFalse(setup.0.isPlaying)
        XCTAssertTrue(setup.1.isEmpty)
    }

    func testRecentPlaybackWaitsForCurrentConfirmedPlayingTransitionAndRecordsResumeOnce() throws {
        let suiteName = "MusicRecentConfirmedPlaybackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let recent = MusicRecentlyPlayedStore(defaults: defaults)
        let probe = ControllablePlaybackStatusProbe()
        let identityA = MusicFavoriteSourceIdentity(
            fileSize: 1,
            contentSHA256Hex: String(repeating: "a", count: 64)
        )
        let identityB = MusicFavoriteSourceIdentity(
            fileSize: 2,
            contentSHA256Hex: String(repeating: "b", count: 64)
        )
        let a = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/A.mp3"),
            duration: 60,
            favoriteSourceIdentity: identityA
        )
        let b = MusicItem(
            url: URL(fileURLWithPath: "/container/Documents/B.mp3"),
            duration: 60,
            favoriteSourceIdentity: identityB
        )
        let playback = MusicPlaybackManager(
            player: AVPlayer(),
            defaults: defaults,
            activateAudioSession: {},
            recentlyPlayed: recent,
            playbackStatusObserver: probe
        )
        playback.updateQueue([a, b])

        playback.play(a)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertTrue(recent.isEmpty)
        XCTAssertNil(defaults.data(forKey: MusicRecentlyPlayedStore.persistenceKey))

        probe.send(.playing)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(recent.orderedMatchingSongs(in: [a, b]), [a])
        let firstRevision = recent.revision
        probe.send(.playing)
        XCTAssertEqual(recent.revision, firstRevision)

        playback.pause()
        playback.play()
        XCTAssertTrue(playback.isPlaying)
        probe.send(.playing)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(recent.revision, firstRevision)

        playback.pause()
        playback.play()
        playback.updateQueue([b])
        probe.send(.playing)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(recent.orderedMatchingSongs(in: [a, b]), [a])
        XCTAssertEqual(recent.revision, firstRevision)
    }

    func testSuccessfulPlaybackRecordsRecentButActivationFailureDoesNot() throws {
        let suiteName = "MusicRecentPlaybackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let identity = MusicFavoriteSourceIdentity(fileSize: 4, contentSHA256Hex: String(repeating: "a", count: 64))
        let song = MusicItem(url: URL(fileURLWithPath: "/container/Documents/song.mp3"), duration: 60, favoriteSourceIdentity: identity)
        let recent = MusicRecentlyPlayedStore(defaults: defaults)
        let failing = MusicPlaybackManager(
            player: AVPlayer(), defaults: defaults,
            activateAudioSession: { throw NSError(domain: "activation", code: 1) },
            recentlyPlayed: recent
        )
        failing.updateQueue([song])
        failing.play(song)
        XCTAssertTrue(recent.orderedMatchingSongs(in: [song]).isEmpty)

        let probe = ControllablePlaybackStatusProbe()
        let successful = MusicPlaybackManager(
            player: AVPlayer(), defaults: defaults, activateAudioSession: {},
            recentlyPlayed: recent,
            playbackStatusObserver: probe
        )
        successful.updateQueue([song])
        successful.play(song)
        XCTAssertTrue(recent.orderedMatchingSongs(in: [song]).isEmpty)
        probe.send(.playing)
        XCTAssertEqual(recent.orderedMatchingSongs(in: [song]), [song])
        XCTAssertEqual(recent.revision, 1)
    }

    func testManualNextPreviousAndResumeRecordOncePerSuccessfulTransition() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "MusicRecentTransitions.\(UUID().uuidString)"))
        let recent = MusicRecentlyPlayedStore(defaults: defaults)
        func song(_ name: String, _ hash: Character) -> MusicItem {
            MusicItem(url: URL(fileURLWithPath: "/c/Documents/\(name)"), duration: 60, favoriteSourceIdentity: .init(fileSize: 1, contentSHA256Hex: String(repeating: hash, count: 64)))
        }
        let a = song("A.mp3", "a"), b = song("B.mp3", "b")
        let probe = ControllablePlaybackStatusProbe()
        let playback = MusicPlaybackManager(
            player: AVPlayer(), defaults: defaults, activateAudioSession: {},
            recentlyPlayed: recent, playbackStatusObserver: probe
        )
        playback.updateQueue([a, b])
        playback.play(a)
        probe.send(.playing)
        probe.send(.playing)
        XCTAssertEqual(recent.revision, 1)
        playback.next()
        probe.send(.playing)
        XCTAssertEqual(recent.orderedMatchingSongs(in: [a, b]), [b, a])
        playback.previous()
        probe.send(.playing)
        XCTAssertEqual(recent.orderedMatchingSongs(in: [a, b]), [a, b])
        playback.pause(); playback.play(); probe.send(.playing)
        XCTAssertEqual(recent.orderedMatchingSongs(in: [a, b]), [a, b])
    }

    func testSuccessfulCurrentSongDeletionAndSameSourceReimportDoesNotRestoreFavorite() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let importSourceRoot = temporaryRoot.appendingPathComponent("ImportSource", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: importSourceRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let songURL = documents.appendingPathComponent("current.mp3")
        let reimportURL = importSourceRoot.appendingPathComponent("current.mp3")
        let songData = Data("current-song".utf8)
        try songData.write(to: songURL)
        try songData.write(to: reimportURL)
        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio"),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos"),
            fileManager: fileManager
        )
        let library = MusicLibrary(storage: storage, durationLoader: { _ in 60 })
        await library.refresh()
        let song = try XCTUnwrap(library.songs.first)
        let suiteName = "MusicDeletionPlaybackIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let player = AVPlayer()
        let playback = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            activateAudioSession: {}
        )
        let favorites = MusicFavoritesStore(defaults: defaults)
        let recent = MusicRecentlyPlayedStore(defaults: defaults)
        let playlists = MusicPlaylistStore(defaults: defaults)
        let playlist = try XCTUnwrap(playlists.create(name: "Deletion"))
        XCTAssertTrue(playlists.add(song, to: playlist.id))
        favorites.setFavorite(true, for: song)
        recent.record(song)
        playback.updateQueue(library.songs)
        playback.play(song)

        try await MusicDeletionCoordinator.delete(
            song,
            library: library,
            playback: playback,
            favorites: favorites,
            recentlyPlayed: recent,
            playlists: playlists
        )

        XCTAssertFalse(fileManager.fileExists(atPath: songURL.path))
        XCTAssertNil(playback.currentTrack)
        XCTAssertNil(playback.currentIndex)
        XCTAssertTrue(playback.queue.isEmpty)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(favorites.isFavorite(song))
        XCTAssertTrue(recent.orderedMatchingSongs(in: [song]).isEmpty)

        let report = await library.importSongs(from: [reimportURL])
        favorites.reconcile(with: report.favoritesSnapshot)
        playback.updateQueue(library.songs)
        let reimported = try XCTUnwrap(library.songs.first)

        XCTAssertEqual(report.importedSongCount, 1)
        XCTAssertEqual(reimported.fileName, song.fileName)
        XCTAssertEqual(reimported.favoriteSourceIdentity, song.favoriteSourceIdentity)
        XCTAssertFalse(favorites.isFavorite(reimported))
        XCTAssertTrue(recent.orderedMatchingSongs(in: [reimported]).isEmpty)
        XCTAssertTrue(MusicPlaylistStore(defaults: defaults).songs(in: playlist.id, library: [reimported]).isEmpty)
        XCTAssertNil(playback.currentTrack)
        XCTAssertEqual(playback.queue, [reimported])
    }

    func testFailedCurrentSongUnlinkLeavesPlaybackFavoriteAndQueueUnchanged() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        let songURL = documents.appendingPathComponent("current.mp3")
        try Data("current-song".utf8).write(to: songURL)
        let expectedError = NSError(domain: "MusicDeletionTests", code: 7)
        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio"),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos"),
            fileManager: fileManager,
            preUnlink: { throw expectedError }
        )
        let library = MusicLibrary(storage: storage, durationLoader: { _ in 60 })
        await library.refresh()
        let song = try XCTUnwrap(library.songs.first)
        let suiteName = "MusicDeletionPlaybackIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let player = AVPlayer()
        let playback = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            activateAudioSession: {}
        )
        let favorites = MusicFavoritesStore(defaults: defaults)
        let recent = MusicRecentlyPlayedStore(defaults: defaults)
        let playlists = MusicPlaylistStore(defaults: defaults)
        let playlist = try XCTUnwrap(playlists.create(name: "Failed deletion"))
        XCTAssertTrue(playlists.add(song, to: playlist.id))
        favorites.toggleFavorite(for: song)
        recent.record(song)
        playback.updateQueue(library.songs)
        playback.play(song)
        let currentItem = try XCTUnwrap(player.currentItem)
        let originalQueue = playback.queue

        do {
            try await MusicDeletionCoordinator.delete(
                song,
                library: library,
                playback: playback,
                favorites: favorites,
                recentlyPlayed: recent,
                playlists: playlists
            )
            XCTFail("Expected the injected unlink failure")
        } catch let error as MusicPlaylistDeletionPersistenceError {
            guard case let .unlinkFailed(underlying) = error else {
                return XCTFail("Expected wrapped unlink failure, got \(error)")
            }
            XCTAssertEqual((underlying as NSError).domain, expectedError.domain)
        }

        XCTAssertTrue(fileManager.fileExists(atPath: songURL.path))
        XCTAssertTrue(player.currentItem === currentItem)
        XCTAssertEqual(playback.currentTrack, song)
        XCTAssertEqual(playback.currentIndex, 0)
        XCTAssertEqual(playback.queue, originalQueue)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertTrue(favorites.isFavorite(song))
        XCTAssertEqual(recent.orderedMatchingSongs(in: [song]), [song])
        XCTAssertEqual(MusicPlaylistStore(defaults: defaults).songs(in: playlist.id, library: [song]), [song])
    }

    func testOldPeriodicCallbackAfterPrepareForDeletionCannotRestorePlaybackState() async throws {
        let suiteName = "MusicDeletionPlaybackIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let player = AVPlayer()
        let playback = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            activateAudioSession: {}
        )
        let song = MusicItem(url: URL(fileURLWithPath: "/tmp/periodic.mp3"), duration: 60)
        playback.updateQueue([song])
        playback.play(song)
        let staleCallback = playback.periodicTimeCallback()

        playback.prepareForDeletion(song)
        staleCallback(CMTime(seconds: 41, preferredTimescale: 600))
        await Task.yield()

        XCTAssertEqual(playback.currentTime, 0)
        XCTAssertEqual(playback.duration, 0)
        XCTAssertNil(playback.currentTrack)
        XCTAssertNil(playback.currentIndex)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(playback.isPlaying)
    }

    func testOldSeekCompletionAfterPrepareForDeletionCannotRestorePlaybackState() async throws {
        let suiteName = "MusicDeletionPlaybackIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let player = AVPlayer()
        let playback = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            activateAudioSession: {}
        )
        let song = MusicItem(url: URL(fileURLWithPath: "/tmp/seek.mp3"), duration: 60)
        playback.updateQueue([song])
        playback.play(song)
        let staleCompletion = playback.seekCompletionCallback(to: 37)

        playback.prepareForDeletion(song)
        staleCompletion(true)
        await Task.yield()

        XCTAssertEqual(playback.currentTime, 0)
        XCTAssertEqual(playback.duration, 0)
        XCTAssertNil(playback.currentTrack)
        XCTAssertNil(playback.currentIndex)
        XCTAssertNil(player.currentItem)
        XCTAssertFalse(playback.isPlaying)
    }

    func testPreparingCurrentSongForDeletionSynchronouslyDetachesAndClearsPlaybackBeforeFileDeletion() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let documents = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try fileManager.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }
        try Data().write(to: documents.appendingPathComponent("current.mp3"))
        let storage = MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio"),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos"),
            fileManager: fileManager
        )
        let library = MusicLibrary(storage: storage)
        await library.refresh()
        let song = try XCTUnwrap(library.songs.first)
        let suiteName = "MusicDeletionPlaybackIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let player = AVPlayer()
        let playback = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            activateAudioSession: {}
        )
        playback.updateQueue(library.songs)
        playback.play(song)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertNotNil(player.currentItem)
        XCTAssertEqual(defaults.string(forKey: "MusicPlayback.lastTrackFileName"), "current.mp3")

        playback.prepareForDeletion(song)

        XCTAssertTrue(fileManager.fileExists(atPath: song.url.path))
        XCTAssertNil(player.currentItem)
        XCTAssertNil(playback.currentTrack)
        XCTAssertNil(playback.currentIndex)
        XCTAssertEqual(playback.currentTime, 0)
        XCTAssertEqual(playback.duration, 0)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertNil(defaults.string(forKey: "MusicPlayback.lastTrackFileName"))
        XCTAssertNil(defaults.object(forKey: "MusicPlayback.lastPositionSeconds"))

        try await library.deleteSong(song)
        playback.updateQueue(library.songs)

        XCTAssertNil(playback.currentTrack)
        XCTAssertNil(playback.currentIndex)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertNil(defaults.string(forKey: "MusicPlayback.lastTrackFileName"))
        XCTAssertNil(defaults.object(forKey: "MusicPlayback.lastPositionSeconds"))
    }

    func testPreparingDifferentURLWithSameFileNameDoesNotStopOrDetachCurrentTrack() throws {
        let suiteName = "MusicDeletionPlaybackIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let player = AVPlayer()
        let playback = MusicPlaybackManager(
            player: player,
            defaults: defaults,
            activateAudioSession: {}
        )
        let current = MusicItem(
            url: URL(fileURLWithPath: "/tmp/current/shared.mp3"),
            duration: 60
        )
        let different = MusicItem(
            url: URL(fileURLWithPath: "/tmp/different/../different/shared.mp3"),
            duration: 60
        )
        playback.updateQueue([current])
        playback.play(current)
        let currentItem = try XCTUnwrap(player.currentItem)

        playback.prepareForDeletion(different)

        XCTAssertTrue(player.currentItem === currentItem)
        XCTAssertEqual(playback.currentTrack?.url.standardizedFileURL, current.url.standardizedFileURL)
        XCTAssertEqual(playback.currentIndex, 0)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertEqual(defaults.string(forKey: "MusicPlayback.lastTrackFileName"), "shared.mp3")
    }
}

private final class VideoStopSpy {
    var stopCount = 0
}

@MainActor
final class PlaybackOwnershipCoordinatorTests: XCTestCase {
    func testMusicClaimStopsRegisteredVideo() {
        let ownership = PlaybackOwnershipCoordinator()
        let video = VideoStopSpy()
        let registration = ownership.registerVideoStop(for: video) { video in
            video.stopCount += 1
        }

        withExtendedLifetime(registration) {
            ownership.musicWillPlay()
        }

        XCTAssertEqual(video.stopCount, 1)
    }

    func testExplicitVideoClaimStopsMusicAndCreatesCurrentIntent() {
        let ownership = PlaybackOwnershipCoordinator()
        let musicStops = VideoStopSpy()

        let intent = ownership.videoPlaybackRequested {
            musicStops.stopCount += 1
        }

        XCTAssertEqual(musicStops.stopCount, 1)
        XCTAssertTrue(ownership.videoPlaybackIsAllowed(intent))
    }
}

@MainActor
final class VideoPlaybackOwnershipIntegrationTests: XCTestCase {
    func testOwnershipPauseInvalidatesPendingSeek() {
        let ownership = PlaybackOwnershipCoordinator()
        let playbackRequests = VideoPlaybackRequestController()
        var didPause = false
        let registration = ownership.registerVideoStop(
            for: playbackRequests
        ) { playbackRequests in
            playbackRequests.pauseForOwnership {
                didPause = true
            }
        }
        let pendingSeek = playbackRequests.issueSeek()

        withExtendedLifetime(registration) {
            ownership.musicWillPlay()
        }

        XCTAssertTrue(didPause)
        XCTAssertFalse(playbackRequests.isCurrent(pendingSeek))
    }

    func testVideoRegistrationIsWeakAndOlderUnregisterCannotRemoveCurrentVideo() {
        let ownership = PlaybackOwnershipCoordinator()
        let olderVideo = NSObject()
        let olderRegistration = ownership.registerVideoStop(
            for: olderVideo,
            action: { _ in }
        )
        var currentVideo: NSObject? = NSObject()
        weak var weakCurrentVideo = currentVideo
        let callbacks = VideoStopSpy()
        let currentRegistration = ownership.registerVideoStop(
            for: currentVideo!
        ) { _ in
            callbacks.stopCount += 1
        }

        olderRegistration.unregister()
        ownership.musicWillPlay()

        XCTAssertEqual(callbacks.stopCount, 1)

        currentVideo = nil
        ownership.musicWillPlay()

        XCTAssertNil(weakCurrentVideo)
        XCTAssertEqual(callbacks.stopCount, 1)
        withExtendedLifetime(currentRegistration) {}
    }

    func testEngineAutoResumeCannotReclaimAfterNewerMusicAction() {
        let ownership = PlaybackOwnershipCoordinator()
        let musicStops = VideoStopSpy()

        let videoIntent = ownership.videoPlaybackRequested {
            musicStops.stopCount += 1
        }
        ownership.musicWillPlay()

        XCTAssertFalse(ownership.videoPlaybackIsAllowed(videoIntent))
        XCTAssertEqual(musicStops.stopCount, 1)
    }
}

@MainActor
final class MusicPlaybackOwnershipIntegrationTests: XCTestCase {
    private enum ActivationError: Error {
        case failed
    }

    func testAudioSessionActivationFailureDoesNotStopVideo() {
        let ownership = PlaybackOwnershipCoordinator()
        let video = VideoStopSpy()
        let registration = ownership.registerVideoStop(for: video) { video in
            video.stopCount += 1
        }
        let defaults = UserDefaults(
            suiteName: "MusicPlaybackOwnershipIntegrationTests.\(UUID().uuidString)"
        )!
        let playback = MusicPlaybackManager(
            defaults: defaults,
            ownership: ownership,
            activateAudioSession: { throw ActivationError.failed }
        )
        let track = MusicItem(
            url: URL(fileURLWithPath: "/tmp/activation-failure.mp3"),
            duration: 60
        )
        playback.updateQueue([track])

        withExtendedLifetime(registration) {
            playback.play(track)
        }

        XCTAssertEqual(video.stopCount, 0)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertNotNil(playback.playbackErrorMessage)
    }

    func testInterruptionEndDoesNotResumeAfterNewerVideoClaim() async {
        let ownership = PlaybackOwnershipCoordinator()
        let video = VideoStopSpy()
        let registration = ownership.registerVideoStop(for: video) { video in
            video.stopCount += 1
        }
        let defaults = UserDefaults(
            suiteName: "MusicPlaybackOwnershipIntegrationTests.\(UUID().uuidString)"
        )!
        let playback = MusicPlaybackManager(
            defaults: defaults,
            ownership: ownership,
            activateAudioSession: {}
        )
        let track = MusicItem(
            url: URL(fileURLWithPath: "/tmp/interruption.mp3"),
            duration: 60
        )
        playback.updateQueue([track])
        playback.play(track)
        video.stopCount = 0

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.began.rawValue
            ]
        )
        await Task.yield()
        ownership.videoPlaybackRequested {
            playback.pause()
        }
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey:
                    AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey:
                    AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ]
        )
        await Task.yield()

        withExtendedLifetime(registration) {}
        XCTAssertEqual(video.stopCount, 0)
        XCTAssertFalse(playback.isPlaying)
    }

    func testDelayedCurrentItemEndDoesNotReclaimAfterNewerVideoClaim() async throws {
        let ownership = PlaybackOwnershipCoordinator()
        let video = VideoStopSpy()
        let registration = ownership.registerVideoStop(for: video) { video in
            video.stopCount += 1
        }
        let defaults = UserDefaults(
            suiteName: "MusicPlaybackOwnershipIntegrationTests.\(UUID().uuidString)"
        )!
        let playback = MusicPlaybackManager(
            defaults: defaults,
            ownership: ownership,
            activateAudioSession: {}
        )
        let firstTrack = MusicItem(
            url: URL(fileURLWithPath: "/tmp/delayed-end-first.mp3"),
            duration: 60
        )
        let secondTrack = MusicItem(
            url: URL(fileURLWithPath: "/tmp/delayed-end-second.mp3"),
            duration: 60
        )
        playback.updateQueue([firstTrack, secondTrack])
        playback.play(firstTrack)
        video.stopCount = 0
        let player = try XCTUnwrap(
            Mirror(reflecting: playback).descendant("player") as? AVPlayer
        )
        let currentItem = try XCTUnwrap(player.currentItem)

        NotificationCenter.default.post(
            name: .AVPlayerItemDidPlayToEndTime,
            object: currentItem
        )
        let videoIntent = ownership.videoPlaybackRequested {
            playback.pause()
        }
        await Task.yield()

        withExtendedLifetime(registration) {}
        XCTAssertEqual(playback.currentTrack?.fileName, firstTrack.fileName)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(video.stopCount, 0)
        XCTAssertTrue(ownership.videoPlaybackIsAllowed(videoIntent))
    }
}

final class MusicListTapLogicTests: XCTestCase {
    func testFirstTapStartsTrack() {
        XCTAssertEqual(
            MusicListTapDecision.action(
                tappedFileName: "first.mp3",
                currentFileName: nil,
                isPlaying: false
            ),
            .startTrack
        )
    }

    func testTappingPlayingCurrentTrackPausesIt() {
        XCTAssertEqual(
            MusicListTapDecision.action(
                tappedFileName: "first.mp3",
                currentFileName: "first.mp3",
                isPlaying: true
            ),
            .pauseCurrent
        )
    }

    func testTappingPausedCurrentTrackResumesIt() {
        XCTAssertEqual(
            MusicListTapDecision.action(
                tappedFileName: "first.mp3",
                currentFileName: "first.mp3",
                isPlaying: false
            ),
            .resumeCurrent
        )
    }

    func testTappingDifferentTrackStartsIt() {
        XCTAssertEqual(
            MusicListTapDecision.action(
                tappedFileName: "second.mp3",
                currentFileName: "first.mp3",
                isPlaying: true
            ),
            .startDifferentTrack
        )
    }
}

final class PlayerScrubLogicTests: XCTestCase {
    func testVideoListRowBuilderAlwaysRendersWithCheapPlaceholderFallback() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
        let homeViewURL = testsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DrivePlayer/Views/HomeView.swift")
        let source = try String(contentsOf: homeViewURL, encoding: .utf8)
        let listStart = try XCTUnwrap(source.range(of: "List(displayedVideos) { video in"))
        let listEnd = try XCTUnwrap(
            source.range(of: "                    .refreshable {", range: listStart.upperBound..<source.endIndex)
        )
        let rowBuilder = String(source[listStart.lowerBound..<listEnd.lowerBound])

        XCTAssertTrue(
            rowBuilder.contains("let payload = rowPayloads[video.id] ?? .placeholder"),
            "Every library video must build a row using an in-memory payload or the cheap placeholder"
        )
        XCTAssertFalse(
            rowBuilder.contains("if let payload = rowPayloads[video.id]"),
            "A missing prepared payload must never omit its video row"
        )
        for forbiddenPreparation in [
            "playbackProgressStore.history(for:",
            "lstat(",
            "SHA256",
            "VideoThumbnailRequest.make("
        ] {
            XCTAssertFalse(
                rowBuilder.contains(forbiddenPreparation),
                "The row builder must not perform expensive preparation: \(forbiddenPreparation)"
            )
        }
    }

    func testVideoListRowBuilderOnlyLooksUpPreparedPayload() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
        let homeViewURL = testsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DrivePlayer/Views/HomeView.swift")
        let source = try String(contentsOf: homeViewURL, encoding: .utf8)
        let listStart = try XCTUnwrap(source.range(of: "List(displayedVideos) { video in"))
        let listEnd = try XCTUnwrap(
            source.range(of: "                    .refreshable {", range: listStart.upperBound..<source.endIndex)
        )
        let rowBuilder = String(source[listStart.lowerBound..<listEnd.lowerBound])

        XCTAssertTrue(
            rowBuilder.contains("rowPayloads[video.id]"),
            "The gesture-time row builder must only look up explicitly prepared in-memory payloads"
        )
        XCTAssertFalse(
            rowBuilder.contains("playbackProgressStore.history(for:"),
            "Playback history decoding and source migration must happen at preparation boundaries"
        )
        XCTAssertFalse(
            rowBuilder.contains("VideoThumbnailRequest.make("),
            "Filesystem identity checks and thumbnail hashing must happen at preparation boundaries"
        )
    }

    func testVideoAutoAdvancePreferenceDefaultsEnabledWhenUnset() throws {
        let suiteName = "VideoAutoAdvancePreferenceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = VideoAutoAdvancePreferenceStore(defaults: defaults)

        XCTAssertTrue(store.isEnabled())
    }

    func testVideoAutoAdvancePreferenceRoundTripsFalseAndTrueAcrossStoreInstances() throws {
        let suiteName = "VideoAutoAdvancePreferenceStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        VideoAutoAdvancePreferenceStore(defaults: defaults).save(isEnabled: false)
        XCTAssertFalse(VideoAutoAdvancePreferenceStore(defaults: defaults).isEnabled())

        VideoAutoAdvancePreferenceStore(defaults: defaults).save(isEnabled: true)
        XCTAssertTrue(VideoAutoAdvancePreferenceStore(defaults: defaults).isEnabled())
    }

    func testVideoPlaybackClockKeepsBestKnownDurationWhilePeriodicTimeAdvances() {
        let metadataFallback = VideoPlaybackClockUpdate.make(
            currentTime: 5,
            reportedDuration: 0,
            previousDuration: 0,
            metadataDuration: 120
        )
        XCTAssertEqual(metadataFallback.currentTime, 5)
        XCTAssertEqual(metadataFallback.duration, 120)

        let previousFallback = VideoPlaybackClockUpdate.make(
            currentTime: 6,
            reportedDuration: .nan,
            previousDuration: 120,
            metadataDuration: 130
        )
        XCTAssertEqual(previousFallback.currentTime, 6)
        XCTAssertEqual(previousFallback.duration, 120)

        let liveDuration = VideoPlaybackClockUpdate.make(
            currentTime: 7,
            reportedDuration: 125,
            previousDuration: 120,
            metadataDuration: 130
        )
        XCTAssertEqual(liveDuration.currentTime, 7)
        XCTAssertEqual(liveDuration.duration, 125)

        let invalidValues = VideoPlaybackClockUpdate.make(
            currentTime: .nan,
            reportedDuration: .nan,
            previousDuration: -1,
            metadataDuration: 0
        )
        XCTAssertEqual(invalidValues.currentTime, 0)
        XCTAssertEqual(invalidValues.duration, 0)

        let negativeCurrent = VideoPlaybackClockUpdate.make(
            currentTime: -1,
            reportedDuration: 0,
            previousDuration: 0,
            metadataDuration: 120
        )
        XCTAssertEqual(negativeCurrent.currentTime, 0)
        XCTAssertEqual(negativeCurrent.duration, 120)

        let clampedCurrent = VideoPlaybackClockUpdate.make(
            currentTime: 140,
            reportedDuration: 125,
            previousDuration: 120,
            metadataDuration: 130
        )
        XCTAssertEqual(clampedCurrent.currentTime, 125)
        XCTAssertEqual(clampedCurrent.duration, 125)
    }

    func testVideoTimelinePresentationClampsProgressAndFormatsCurrentAndTotalTime() {
        let regular = VideoTimelinePresentation.make(currentTime: 42.9, duration: 125.8)
        XCTAssertEqual(regular.currentTime, 42.9)
        XCTAssertEqual(regular.duration, 125.8)
        XCTAssertEqual(regular.currentTimeLabel, "0:42")
        XCTAssertEqual(regular.durationLabel, "2:05")
        XCTAssertTrue(regular.isSeekEnabled)

        let clamped = VideoTimelinePresentation.make(currentTime: 200, duration: 100)
        XCTAssertEqual(clamped.currentTime, 100)

        for invalidDuration: Double in [0, -1, .nan, .infinity, -.infinity] {
            let invalid = VideoTimelinePresentation.make(
                currentTime: 42.9,
                duration: invalidDuration
            )
            XCTAssertEqual(invalid.currentTime, 42.9)
            XCTAssertEqual(invalid.duration, 0)
            XCTAssertEqual(invalid.currentTimeLabel, "0:42")
            XCTAssertEqual(invalid.durationLabel, "--:--")
            XCTAssertFalse(invalid.isSeekEnabled)
        }
    }

    func testVideoTimelineShowsFiniteCurrentTimeWhileDurationIsStillUnknown() {
        for invalidDuration: Double in [0, -1, .nan, .infinity, -.infinity] {
            let presentation = VideoTimelinePresentation.make(
                currentTime: 42.9,
                duration: invalidDuration
            )
            XCTAssertEqual(presentation.currentTime, 42.9)
            XCTAssertEqual(presentation.currentTimeLabel, "0:42")
            XCTAssertEqual(presentation.duration, 0)
            XCTAssertEqual(presentation.durationLabel, "--:--")
            XCTAssertFalse(presentation.isSeekEnabled)
        }

        for invalidCurrentTime: Double in [.nan, -1, .infinity] {
            let presentation = VideoTimelinePresentation.make(
                currentTime: invalidCurrentTime,
                duration: 0
            )
            XCTAssertEqual(presentation.currentTime, 0)
            XCTAssertEqual(presentation.currentTimeLabel, "0:00")
        }
    }

    func testVideoDetailLayoutHidesRootChromeAndCentersContentVertically() {
        XCTAssertTrue(VideoDetailLayoutPolicy.showsRootChrome(isVideoDetailPresented: false))
        XCTAssertFalse(VideoDetailLayoutPolicy.showsRootChrome(isVideoDetailPresented: true))
        XCTAssertEqual(VideoDetailLayoutPolicy.flexibleSpaceBeforeContent, 1)
        XCTAssertEqual(VideoDetailLayoutPolicy.flexibleSpaceAfterContent, 1)
    }

    func testVideoDetailLayoutPlacesTitleAboveVideoAndTransportBelowVideo() {
        XCTAssertEqual(VideoDetailLayoutPolicy.sectionOrder, [
            .title,
            .video,
            .transport,
            .timeline,
            .playbackRates
        ])
        XCTAssertEqual(VideoDetailLayoutPolicy.displayTitle(for: "Example Clip.mp4"), "Example Clip.mp4")
        XCTAssertEqual(VideoDetailLayoutPolicy.displayTitle(for: " \t\n"), "视频")
        XCTAssertFalse(VideoDetailLayoutPolicy.showsTransportControlsAsVideoOverlay)
    }

    func testVideoPlaybackRatePolicySupportsProductRatesAndFallsBackToNormalSpeed() {
        let supportedRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

        XCTAssertEqual(VideoPlaybackRatePolicy.supportedRates, supportedRates)
        XCTAssertEqual(VideoPlaybackRatePolicy.defaultRate, 1)
        for rate in supportedRates {
            XCTAssertEqual(VideoPlaybackRatePolicy.normalized(rate), rate, accuracy: 1e-9)
        }
        for rate: Double in [0, -1, 0.6, 3, .nan, .infinity, -.infinity] {
            XCTAssertEqual(VideoPlaybackRatePolicy.normalized(rate), 1, accuracy: 1e-9)
        }
    }

    func testVideoPlaybackRatePresentationFormatsEverySupportedRateForTheMenu() {
        XCTAssertEqual(VideoPlaybackRatePresentation.menuRates, VideoPlaybackRatePolicy.supportedRates)
        XCTAssertEqual(VideoPlaybackRatePresentation.label(for: 0.5), "0.5×")
        XCTAssertEqual(VideoPlaybackRatePresentation.label(for: 0.75), "0.75×")
        XCTAssertEqual(VideoPlaybackRatePresentation.label(for: 1), "1×")
        XCTAssertEqual(VideoPlaybackRatePresentation.label(for: 1.25), "1.25×")
        XCTAssertEqual(VideoPlaybackRatePresentation.label(for: 1.5), "1.5×")
        XCTAssertEqual(VideoPlaybackRatePresentation.label(for: 2), "2×")
        XCTAssertEqual(VideoPlaybackRatePresentation.label(for: 0.6), "1×")
    }

    func testVideoPlaybackRatePresentationBuildsFlatMenuOptionsWithOneSelection() {
        let options = VideoPlaybackRatePresentation.menuOptions(selectedRate: 1.5)

        XCTAssertEqual(options, [
            VideoPlaybackRatePresentation.MenuOption(rate: 0.5, label: "0.5×", isSelected: false),
            VideoPlaybackRatePresentation.MenuOption(rate: 0.75, label: "0.75×", isSelected: false),
            VideoPlaybackRatePresentation.MenuOption(rate: 1, label: "1×", isSelected: false),
            VideoPlaybackRatePresentation.MenuOption(rate: 1.25, label: "1.25×", isSelected: false),
            VideoPlaybackRatePresentation.MenuOption(rate: 1.5, label: "1.5×", isSelected: true),
            VideoPlaybackRatePresentation.MenuOption(rate: 2, label: "2×", isSelected: false),
        ])
        XCTAssertEqual(options.map(\.rate), VideoPlaybackRatePolicy.supportedRates)
        XCTAssertEqual(options.map(\.label), options.map { VideoPlaybackRatePresentation.label(for: $0.rate) })
        XCTAssertEqual(options.filter(\.isSelected).map(\.rate), [1.5])
        XCTAssertEqual(Set(options.map(\.rate)).count, options.count)

        let normalizedOptions = VideoPlaybackRatePresentation.menuOptions(selectedRate: 0.6)

        XCTAssertEqual(normalizedOptions.filter(\.isSelected).map(\.rate), [1])
    }

    func testVideoPlaybackRatePresentationProvidesAccessiblePersistentControlMetrics() {
        XCTAssertEqual(VideoPlaybackRatePresentation.minimumTapTarget, 44)
        XCTAssertEqual(VideoPlaybackRatePresentation.controlSpacing, 4)

        let options = VideoPlaybackRatePresentation.menuOptions(selectedRate: 1.25)

        XCTAssertEqual(options.count, 6)
        XCTAssertEqual(options.filter(\.isSelected).map(\.rate), [1.25])
    }

    func testVideoPlaybackRateStorePersistsLastSelectionAcrossInstances() throws {
        let suiteName = "PlayerScrubLogicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = VideoPlaybackRateStore(defaults: defaults)

        XCTAssertEqual(store.selectedRate(), VideoPlaybackRatePolicy.defaultRate, accuracy: 1e-9)
        store.save(rate: 1.5)
        let restoredStore = VideoPlaybackRateStore(defaults: defaults)

        XCTAssertEqual(restoredStore.selectedRate(), 1.5, accuracy: 1e-9)
    }

    func testVideoPlaybackRateApplicationAppliesSelectionAndRestoresItLater() throws {
        let suiteName = "PlayerScrubLogicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = VideoPlaybackRateStore(defaults: defaults)
        var appliedRates: [Float] = []

        let selectedRate = VideoPlaybackRateApplication.select(1.5, store: store) {
            appliedRates.append($0)
        }

        XCTAssertEqual(selectedRate, 1.5, accuracy: 1e-6)
        XCTAssertEqual(appliedRates, [1.5])
        XCTAssertEqual(store.selectedRate(), 1.5, accuracy: 1e-6)

        appliedRates.removeAll()
        let restoredStore = VideoPlaybackRateStore(defaults: defaults)
        let restoredRate = VideoPlaybackRateApplication.restore(store: restoredStore) {
            appliedRates.append($0)
        }

        XCTAssertEqual(restoredRate, 1.5, accuracy: 1e-6)
        XCTAssertEqual(appliedRates, [1.5])
    }

    func testVideoPlaybackProgressSessionAttemptsResumeOnlyOnceAfterDurationIsKnown() {
        var session = VideoPlaybackProgressSession()

        XCTAssertNil(session.resumePosition(storedPosition: 42.5, duration: 0))
        XCTAssertEqual(session.resumePosition(storedPosition: 42.5, duration: 100), 42.5)
        XCTAssertNil(session.resumePosition(storedPosition: 20, duration: 100))
    }

    func testVideoPlaybackResumePlanRestartsCompletedReplayFromStart() {
        var ordinarySession = VideoPlaybackProgressSession()
        XCTAssertEqual(
            ordinarySession.resumePlan(
                history: .viewed(position: 42.5, duration: 100),
                duration: 100
            ),
            VideoPlaybackResumePlan(position: 42.5, shouldResume: true)
        )

        var completedSession = VideoPlaybackProgressSession()
        XCTAssertEqual(
            completedSession.resumePlan(history: .completed(duration: 100), duration: 100),
            VideoPlaybackResumePlan(position: 0, shouldResume: true)
        )
        XCTAssertNil(
            completedSession.resumePlan(history: .completed(duration: 100), duration: 100)
        )
    }

    func testVideoListRowPresentationKeepsNewVideoBlankAndShowsNewBadge() {
        let presentation = VideoListRowPresentation.make(history: .new)

        XCTAssertTrue(presentation.showsNewBadge)
        XCTAssertNil(presentation.thumbnailTime)
        XCTAssertNil(presentation.progressFraction)
    }

    func testVideoListRowPresentationUsesSavedFrameAndProgressForViewedVideo() {
        let presentation = VideoListRowPresentation.make(
            history: .viewed(position: 25, duration: 100)
        )

        XCTAssertFalse(presentation.showsNewBadge)
        XCTAssertEqual(presentation.thumbnailTime, 25)
        XCTAssertEqual(presentation.progressFraction, 0.25)
    }

    func testVideoListRowPresentationUsesNearEndFrameAndFullRingForCompletedVideo() {
        let presentation = VideoListRowPresentation.make(history: .completed(duration: 100))

        XCTAssertFalse(presentation.showsNewBadge)
        XCTAssertEqual(presentation.thumbnailTime ?? -1, 99.9, accuracy: 0.000_001)
        XCTAssertEqual(presentation.progressFraction, 1)
    }

    func testVideoThumbnailRequestIsAbsentForNewVideo() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let request = VideoThumbnailRequest.make(
            video: VideoItem(url: url, duration: nil),
            presentation: .make(history: .new)
        )

        XCTAssertNil(request)
    }

    func testViewedAndCompletedThumbnailRequestsBindSourceAndPresentationTime() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = VideoItem(url: url, duration: nil)

        let viewed = try XCTUnwrap(VideoThumbnailRequest.make(
            video: video,
            presentation: .make(history: .viewed(position: 25, duration: 100))
        ))
        let completed = try XCTUnwrap(VideoThumbnailRequest.make(
            video: video,
            presentation: .make(history: .completed(duration: 100))
        ))

        XCTAssertEqual(viewed.thumbnailTime, 25)
        XCTAssertEqual(completed.thumbnailTime, 99.9, accuracy: 0.000_001)
        XCTAssertEqual(viewed.videoIdentity, completed.videoIdentity)
        XCTAssertNotEqual(viewed.cacheIdentity, completed.cacheIdentity)
    }

    func testThumbnailRequestIdentityChangesWhenSamePathSourceIsReplaced() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("old".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = VideoItem(url: url, duration: nil)
        let presentation = VideoListRowPresentation.make(
            history: .viewed(position: 2, duration: 10)
        )
        let old = try XCTUnwrap(VideoThumbnailRequest.make(video: video, presentation: presentation))

        try Data("replacement source".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 2)],
            ofItemAtPath: url.path
        )
        let replacement = try XCTUnwrap(
            VideoThumbnailRequest.make(video: video, presentation: presentation)
        )

        XCTAssertNotEqual(old.videoIdentity, replacement.videoIdentity)
        XCTAssertNotEqual(old.cacheIdentity, replacement.cacheIdentity)
    }

    func testThumbnailRequestRejectsSameSizeRewriteWithOriginalMTimeRestored() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let originalBytes = Data("original-video-bytes".utf8)
        let replacementBytes = Data("replaced-video-bytes".utf8)
        XCTAssertNotEqual(originalBytes, replacementBytes)
        XCTAssertEqual(originalBytes.count, replacementBytes.count)
        try originalBytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let originalStat = try testFileStat(at: url)
        let presentation = VideoListRowPresentation.make(
            history: .viewed(position: 2, duration: 10)
        )
        let originalRequest = try XCTUnwrap(
            VideoThumbnailRequest.make(
                video: VideoItem(url: url, duration: nil),
                presentation: presentation
            )
        )

        try replacementBytes.write(to: url)
        try restoreTestFileTimes(at: url, from: originalStat)
        let replacementStat = try testFileStat(at: url)
        let writtenBytes = try Data(contentsOf: url)
        XCTAssertNotEqual(writtenBytes, originalBytes)
        XCTAssertEqual(writtenBytes, replacementBytes)
        XCTAssertEqual(writtenBytes.count, originalBytes.count)
        XCTAssertEqual(replacementStat.size, originalStat.size)
        XCTAssertEqual(replacementStat.modificationTime.tv_sec, originalStat.modificationTime.tv_sec)
        XCTAssertEqual(replacementStat.modificationTime.tv_nsec, originalStat.modificationTime.tv_nsec)

        XCTAssertFalse(originalRequest.matchesCurrentSource())
        let replacementRequest = try XCTUnwrap(
            VideoThumbnailRequest.make(
                video: VideoItem(url: url, duration: nil),
                presentation: presentation
            )
        )
        XCTAssertNotEqual(originalRequest.videoIdentity, replacementRequest.videoIdentity)
    }

    func testSameNamedVideosAtDifferentURLsNeverShareThumbnailIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstDirectory = root.appendingPathComponent("one", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = firstDirectory.appendingPathComponent("same.mp4")
        let secondURL = secondDirectory.appendingPathComponent("same.mp4")
        try Data("same bytes".utf8).write(to: firstURL)
        try Data("same bytes".utf8).write(to: secondURL)
        let sharedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: sharedDate], ofItemAtPath: firstURL.path)
        try FileManager.default.setAttributes([.modificationDate: sharedDate], ofItemAtPath: secondURL.path)
        let presentation = VideoListRowPresentation.make(
            history: .viewed(position: 1, duration: 10)
        )

        let first = try XCTUnwrap(
            VideoThumbnailRequest.make(
                video: VideoItem(url: firstURL, duration: nil),
                presentation: presentation
            )
        )
        let second = try XCTUnwrap(
            VideoThumbnailRequest.make(
                video: VideoItem(url: secondURL, duration: nil),
                presentation: presentation
            )
        )

        XCTAssertNotEqual(first.videoIdentity, second.videoIdentity)
        XCTAssertNotEqual(first.cacheIdentity, second.cacheIdentity)
    }

    func testThumbnailCacheIdentityIsOpaqueSHA256() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-name-\(UUID().uuidString).mp4")
        try Data("video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let request = try XCTUnwrap(
            VideoThumbnailRequest.make(
                video: VideoItem(url: url, duration: nil),
                presentation: VideoListRowPresentation.make(
                    history: .viewed(position: 1, duration: 10)
                )
            )
        )

        XCTAssertNotNil(request.cacheIdentity.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        XCTAssertFalse(request.cacheIdentity.contains(url.lastPathComponent))
        XCTAssertFalse(request.cacheIdentity.contains(url.path))
    }

    func testThumbnailRequestCarriesExactSourceURLForGeneration() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let request = try XCTUnwrap(
            VideoThumbnailRequest.make(
                video: VideoItem(url: url, duration: nil),
                presentation: VideoListRowPresentation.make(
                    history: .viewed(position: 1, duration: 10)
                )
            )
        )

        XCTAssertEqual(request.sourceURL, url)
    }

    func testThumbnailServiceCoalescesDuplicateInflightRequests() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let request = try XCTUnwrap(
            VideoThumbnailRequest.make(
                video: VideoItem(url: url, duration: nil),
                presentation: VideoListRowPresentation.make(
                    history: .viewed(position: 1, duration: 10)
                )
            )
        )
        let counter = ThumbnailGeneratorCounter()
        let service = VideoThumbnailService(maxConcurrent: 2) { _ in
            await counter.increment()
            try? await Task.sleep(nanoseconds: 50_000_000)
            return nil
        }

        async let first: CGImage? = service.image(for: request)
        async let second: CGImage? = service.image(for: request)
        _ = await (first, second)

        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testThumbnailServiceBoundsConcurrentGeneration() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = VideoItem(url: url, duration: nil)
        let requests = try (1...5).map { index in
            try XCTUnwrap(
                VideoThumbnailRequest.make(
                    video: video,
                    presentation: VideoListRowPresentation.make(
                        history: .viewed(position: Double(index), duration: 10)
                    )
                )
            )
        }
        let counter = ThumbnailGeneratorCounter()
        let service = VideoThumbnailService(maxConcurrent: 2) { _ in
            await counter.begin()
            try? await Task.sleep(nanoseconds: 50_000_000)
            await counter.end()
            return nil
        }

        let tasks = requests.map { request in
            Task { await service.image(for: request) }
        }
        for task in tasks {
            _ = await task.value
        }

        let maxActive = await counter.maxActive
        XCTAssertLessThanOrEqual(maxActive, 2)
    }

    func testThumbnailEvictionTargetsOnlyMatchingVideoIdentity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let firstDirectory = root.appendingPathComponent("one", isDirectory: true)
        let secondDirectory = root.appendingPathComponent("two", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = firstDirectory.appendingPathComponent("same.mp4")
        let secondURL = secondDirectory.appendingPathComponent("same.mp4")
        try Data("same bytes".utf8).write(to: firstURL)
        try Data("same bytes".utf8).write(to: secondURL)
        let presentation = VideoListRowPresentation.make(
            history: .viewed(position: 1, duration: 10)
        )
        let first = try XCTUnwrap(
            VideoThumbnailRequest.make(
                video: VideoItem(url: firstURL, duration: nil),
                presentation: presentation
            )
        )
        let second = try XCTUnwrap(
            VideoThumbnailRequest.make(
                video: VideoItem(url: secondURL, duration: nil),
                presentation: presentation
            )
        )
        let counter = ThumbnailGeneratorCounter()
        let service = VideoThumbnailService(maxConcurrent: 2) { _ in
            await counter.increment()
            return makeThumbnailTestImage()
        }

        _ = await service.image(for: first)
        _ = await service.image(for: second)
        _ = await service.image(for: first)
        _ = await service.image(for: second)
        let initialGenerationCount = await counter.value
        XCTAssertEqual(initialGenerationCount, 2)

        await service.evict(videoIdentity: first.videoIdentity)
        _ = await service.image(for: first)
        _ = await service.image(for: second)

        let finalGenerationCount = await counter.value
        XCTAssertEqual(finalGenerationCount, 3)
    }

    func testEvictionPreventsInflightGenerationFromRepopulatingCache() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let request = try XCTUnwrap(
            VideoThumbnailRequest.make(
                video: VideoItem(url: url, duration: nil),
                presentation: VideoListRowPresentation.make(
                    history: .viewed(position: 1, duration: 10)
                )
            )
        )
        let counter = ThumbnailGeneratorCounter()
        let service = VideoThumbnailService(maxConcurrent: 1) { _ in
            await counter.increment()
            try? await Task.sleep(nanoseconds: 100_000_000)
            return makeThumbnailTestImage()
        }

        let first = Task { await service.image(for: request) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await service.evict(videoIdentity: request.videoIdentity)
        _ = await first.value
        _ = await service.image(for: request)

        let generationCount = await counter.value
        XCTAssertEqual(generationCount, 2)
    }

    func testThumbnailServiceBoundsMemoryCacheSize() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = VideoItem(url: url, duration: nil)
        let requests = try (1...3).map { index in
            try XCTUnwrap(
                VideoThumbnailRequest.make(
                    video: video,
                    presentation: VideoListRowPresentation.make(
                        history: .viewed(position: Double(index), duration: 10)
                    )
                )
            )
        }
        let counter = ThumbnailGeneratorCounter()
        let service = VideoThumbnailService(maxConcurrent: 1, maxCachedImages: 2) { _ in
            await counter.increment()
            return makeThumbnailTestImage()
        }

        for request in requests {
            _ = await service.image(for: request)
        }
        _ = await service.image(for: requests[0])

        let generationCount = await counter.value
        XCTAssertEqual(generationCount, 4)
    }

    func testLiveThumbnailServiceGeneratesFrameFromBundledVideo() async throws {
        let bundledURL = try XCTUnwrap(
            Bundle.main.url(forResource: "phase0-test", withExtension: "mp4")
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        try FileManager.default.copyItem(at: bundledURL, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let request = try XCTUnwrap(
            VideoThumbnailRequest.make(
                video: VideoItem(url: url, duration: nil),
                presentation: VideoListRowPresentation.make(
                    history: .viewed(position: 1, duration: 2)
                )
            )
        )
        let service = VideoThumbnailService(maxConcurrent: 1)

        let image = await service.image(for: request)

        XCTAssertNotNil(image)
    }

    func testThumbnailServiceRejectsRequestAfterSourceReplacement() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("old".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let request = try XCTUnwrap(
            VideoThumbnailRequest.make(
                video: VideoItem(url: url, duration: nil),
                presentation: VideoListRowPresentation.make(
                    history: .viewed(position: 1, duration: 10)
                )
            )
        )
        try Data("replacement source".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 2)],
            ofItemAtPath: url.path
        )
        let counter = ThumbnailGeneratorCounter()
        let service = VideoThumbnailService(maxConcurrent: 1) { _ in
            await counter.increment()
            return makeThumbnailTestImage()
        }

        let image = await service.image(for: request)

        XCTAssertNil(image)
        let generationCount = await counter.value
        XCTAssertEqual(generationCount, 0)
    }

    func testThumbnailServiceDiscardsFrameWhenSourceChangesDuringGeneration() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let originalBytes = Data("original-video-bytes".utf8)
        let replacementBytes = Data("replaced-video-bytes".utf8)
        XCTAssertNotEqual(originalBytes, replacementBytes)
        XCTAssertEqual(originalBytes.count, replacementBytes.count)
        try originalBytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let originalStat = try testFileStat(at: url)
        let request = try XCTUnwrap(
            VideoThumbnailRequest.make(
                video: VideoItem(url: url, duration: nil),
                presentation: VideoListRowPresentation.make(
                    history: .viewed(position: 1, duration: 10)
                )
            )
        )
        let gate = ThumbnailGeneratorGate()
        let service = VideoThumbnailService(maxConcurrent: 1) { _ in
            await gate.generate()
        }

        let pending = Task { await service.image(for: request) }
        await gate.waitUntilStarted()
        try replacementBytes.write(to: url)
        try restoreTestFileTimes(at: url, from: originalStat)
        let replacementStat = try testFileStat(at: url)
        let writtenBytes = try Data(contentsOf: url)
        XCTAssertNotEqual(writtenBytes, originalBytes)
        XCTAssertEqual(writtenBytes, replacementBytes)
        XCTAssertEqual(writtenBytes.count, originalBytes.count)
        XCTAssertEqual(replacementStat.size, originalStat.size)
        XCTAssertEqual(replacementStat.modificationTime.tv_sec, originalStat.modificationTime.tv_sec)
        XCTAssertEqual(replacementStat.modificationTime.tv_nsec, originalStat.modificationTime.tv_nsec)
        await gate.release()

        let image = await pending.value
        XCTAssertNil(image)
    }

    func testCoalescedThumbnailWaiterRejectsStaleFrameAfterSourceReplacement() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let originalBytes = Data("original-video-bytes".utf8)
        let replacementBytes = Data("replaced-video-bytes".utf8)
        XCTAssertNotEqual(originalBytes, replacementBytes)
        XCTAssertEqual(originalBytes.count, replacementBytes.count)
        try originalBytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let originalStat = try testFileStat(at: url)
        let request = try XCTUnwrap(
            VideoThumbnailRequest.make(
                video: VideoItem(url: url, duration: nil),
                presentation: VideoListRowPresentation.make(
                    history: .viewed(position: 1, duration: 10)
                )
            )
        )
        let gate = ThumbnailGeneratorGate()
        let service = VideoThumbnailService(maxConcurrent: 1) { _ in
            await gate.generate()
        }

        let first = Task { await service.image(for: request) }
        await gate.waitUntilStarted()
        let second = Task { await service.image(for: request) }
        await Task.yield()
        let coalescedGenerationCount = await gate.invocationCount
        XCTAssertEqual(coalescedGenerationCount, 1)

        try replacementBytes.write(to: url)
        try restoreTestFileTimes(at: url, from: originalStat)
        let replacementStat = try testFileStat(at: url)
        let writtenBytes = try Data(contentsOf: url)
        XCTAssertNotEqual(writtenBytes, originalBytes)
        XCTAssertEqual(writtenBytes, replacementBytes)
        XCTAssertEqual(writtenBytes.count, originalBytes.count)
        XCTAssertEqual(replacementStat.size, originalStat.size)
        XCTAssertEqual(replacementStat.modificationTime.tv_sec, originalStat.modificationTime.tv_sec)
        XCTAssertEqual(replacementStat.modificationTime.tv_nsec, originalStat.modificationTime.tv_nsec)
        await gate.release()

        let firstImage = await first.value
        let secondImage = await second.value
        XCTAssertNil(firstImage)
        XCTAssertNil(secondImage)
        let finalGenerationCount = await gate.invocationCount
        XCTAssertEqual(finalGenerationCount, 1)
    }

    func testVideoPlaybackHistoryRecordDistinguishesNewViewedAndCompletedSafely() {
        XCTAssertEqual(VideoPlaybackHistoryRecord.new.state, .new)

        let viewedAtZero = VideoPlaybackHistoryRecord.viewed(position: 0, duration: 100)
        XCTAssertEqual(viewedAtZero.state, .viewed)
        XCTAssertEqual(viewedAtZero.progressFraction, 0)

        let clamped = VideoPlaybackHistoryRecord.viewed(position: 120, duration: 100)
        XCTAssertEqual(clamped.position, 100)
        XCTAssertEqual(clamped.progressFraction, 1)

        let completed = VideoPlaybackHistoryRecord.completed(duration: 100)
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.position, 100)
        XCTAssertEqual(completed.progressFraction, 1)

        for invalid in [Double.nan, .infinity, -.infinity, -1] {
            let record = VideoPlaybackHistoryRecord.viewed(position: invalid, duration: invalid)
            XCTAssertEqual(record.state, .viewed)
            XCTAssertEqual(record.position, 0)
            XCTAssertEqual(record.duration, 0)
            XCTAssertEqual(record.progressFraction, 0)
        }
    }

    func testVideoPlaybackProgressSessionPersistsAtMostOncePerWholeSecond() {
        var session = VideoPlaybackProgressSession()

        XCTAssertNil(session.periodicPositionToPersist(currentTime: 10, duration: 0))
        XCTAssertEqual(session.periodicPositionToPersist(currentTime: 10.1, duration: 100), 10.1)
        XCTAssertNil(session.periodicPositionToPersist(currentTime: 10.9, duration: 100))
        XCTAssertEqual(session.periodicPositionToPersist(currentTime: 11.0, duration: 100), 11.0)
        XCTAssertNil(session.periodicPositionToPersist(currentTime: -1, duration: 100))
        XCTAssertNil(session.periodicPositionToPersist(currentTime: .nan, duration: 100))
        XCTAssertNil(session.periodicPositionToPersist(currentTime: .infinity, duration: 100))
        XCTAssertNil(session.periodicPositionToPersist(currentTime: -.infinity, duration: 100))
        XCTAssertNil(session.periodicPositionToPersist(currentTime: 12, duration: .nan))
        XCTAssertNil(session.periodicPositionToPersist(currentTime: 12, duration: .infinity))
        XCTAssertNil(session.periodicPositionToPersist(currentTime: 12, duration: -.infinity))
        XCTAssertNil(session.periodicPositionToPersist(currentTime: 12, duration: 0))
        XCTAssertNil(session.periodicPositionToPersist(currentTime: 12, duration: -100))
    }

    func testVideoPlaybackProgressStoreUsesStableFileIdentityAcrossAlternateContainerPathsAndRelaunch() throws {
        let suiteName = "PlayerScrubLogicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directoryName = UUID().uuidString
        let canonicalDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: canonicalDirectory) }
        try FileManager.default.createDirectory(at: canonicalDirectory, withIntermediateDirectories: true)
        let canonicalURL = canonicalDirectory.appendingPathComponent("My Movie.mp4")
        let alternateURL = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("My Movie.mp4")
        let unrelatedURL = canonicalDirectory.appendingPathComponent("Other.mp4")
        try Data("same source".utf8).write(to: canonicalURL)
        try Data("unrelated source".utf8).write(to: unrelatedURL)

        let canonicalStat = try testFileStat(at: canonicalURL)
        let alternateStat = try testFileStat(at: alternateURL)
        XCTAssertNotEqual(canonicalURL.path, alternateURL.path)
        XCTAssertEqual(canonicalStat.device, alternateStat.device)
        XCTAssertEqual(canonicalStat.inode, alternateStat.inode)
        XCTAssertEqual(canonicalStat.size, alternateStat.size)
        XCTAssertEqual(canonicalStat.modificationTime.tv_sec, alternateStat.modificationTime.tv_sec)
        XCTAssertEqual(canonicalStat.modificationTime.tv_nsec, alternateStat.modificationTime.tv_nsec)
        XCTAssertEqual(canonicalStat.statusChangeTime.tv_sec, alternateStat.statusChangeTime.tv_sec)
        XCTAssertEqual(canonicalStat.statusChangeTime.tv_nsec, alternateStat.statusChangeTime.tv_nsec)

        VideoPlaybackProgressStore(defaults: defaults).save(
            position: 42.5,
            for: VideoItem(url: canonicalURL, duration: nil)
        )
        let relaunchedStore = VideoPlaybackProgressStore(defaults: defaults)

        XCTAssertEqual(
            relaunchedStore.position(for: VideoItem(url: alternateURL, duration: nil)),
            42.5
        )
        XCTAssertNil(relaunchedStore.position(for: VideoItem(url: unrelatedURL, duration: nil)))
    }

    func testVideoPlaybackProgressStoreRemovesOnlyDeletedVideoPosition() throws {
        let suiteName = "PlayerScrubLogicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = VideoPlaybackProgressStore(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("First.mp4")
        let secondURL = root.appendingPathComponent("Second.mp4")
        try Data("first".utf8).write(to: firstURL)
        try Data("second".utf8).write(to: secondURL)
        let firstVideo = VideoItem(url: firstURL, duration: nil)
        let secondVideo = VideoItem(url: secondURL, duration: nil)

        store.save(position: 12.5, for: firstVideo)
        store.save(position: 47.25, for: secondVideo)
        store.removePosition(for: firstVideo)

        XCTAssertNil(store.position(for: firstVideo))
        XCTAssertEqual(store.position(for: secondVideo), 47.25)
    }

    func testVideoPlaybackHistoryInvalidatesWhenSameNamedSourceIsReplaced() throws {
        let suiteName = "PlayerScrubLogicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Movie.mp4")
        try Data("old".utf8).write(to: url)
        let video = VideoItem(url: url, duration: nil)
        let store = VideoPlaybackProgressStore(defaults: defaults)
        store.save(position: 2, duration: 10, for: video)
        store.markCompleted(duration: 10, for: video)

        try Data("replacement source".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 2)],
            ofItemAtPath: url.path
        )

        XCTAssertEqual(store.history(for: video), .new)
        XCTAssertNil(store.position(for: video))
    }

    func testVideoPlaybackHistoryInvalidatesAfterSameSizeRewriteWithOriginalMTimeRestored() throws {
        let suiteName = "PlayerScrubLogicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        let originalBytes = Data("original-video-bytes".utf8)
        let replacementBytes = Data("replaced-video-bytes".utf8)
        XCTAssertNotEqual(originalBytes, replacementBytes)
        XCTAssertEqual(originalBytes.count, replacementBytes.count)
        try originalBytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let originalStat = try testFileStat(at: url)
        let video = VideoItem(url: url, duration: nil)
        let store = VideoPlaybackProgressStore(defaults: defaults)
        store.markCompleted(duration: 10, for: video)

        try replacementBytes.write(to: url)
        try restoreTestFileTimes(at: url, from: originalStat)
        let replacementStat = try testFileStat(at: url)
        let writtenBytes = try Data(contentsOf: url)
        XCTAssertNotEqual(writtenBytes, originalBytes)
        XCTAssertEqual(writtenBytes, replacementBytes)
        XCTAssertEqual(writtenBytes.count, originalBytes.count)
        XCTAssertEqual(replacementStat.size, originalStat.size)
        XCTAssertEqual(replacementStat.modificationTime.tv_sec, originalStat.modificationTime.tv_sec)
        XCTAssertEqual(replacementStat.modificationTime.tv_nsec, originalStat.modificationTime.tv_nsec)

        XCTAssertEqual(store.history(for: video), .new)
    }

    func testInstallationGenerationIdentifierChangesWhenAppBundleInstallationURLChanges() {
        let firstBundleURL = URL(fileURLWithPath: "/private/var/containers/Bundle/Application/11111111-1111-1111-1111-111111111111/DrivePlayer.app")
        let secondBundleURL = URL(fileURLWithPath: "/private/var/containers/Bundle/Application/22222222-2222-2222-2222-222222222222/DrivePlayer.app")

        let firstIdentifier = VideoPlaybackProgressStore.installationGenerationIdentifier(
            shortVersion: "1.2.3",
            buildVersion: "456",
            bundleURL: firstBundleURL
        )
        let repeatedIdentifier = VideoPlaybackProgressStore.installationGenerationIdentifier(
            shortVersion: "1.2.3",
            buildVersion: "456",
            bundleURL: firstBundleURL
        )
        let secondIdentifier = VideoPlaybackProgressStore.installationGenerationIdentifier(
            shortVersion: "1.2.3",
            buildVersion: "456",
            bundleURL: secondBundleURL
        )

        XCTAssertEqual(firstIdentifier, repeatedIdentifier)
        XCTAssertNotEqual(firstIdentifier, secondIdentifier)
    }

    func testVideoPlaybackHistorySurvivesAppUpdateFileObjectMigrationWhenStableAttributesMatch() throws {
        let suiteName = "PlayerScrubLogicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Movie.mp4")
        let bytes = Data("deterministic-video-bytes".utf8)
        try bytes.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: url.path
        )
        let generationOneStat = try testFileStat(at: url)
        let video = VideoItem(url: url, duration: nil)
        let generationOneStore = VideoPlaybackProgressStore(
            defaults: defaults,
            appBuildIdentifier: "generation-1"
        )
        generationOneStore.save(position: 42.5, duration: 100, for: video)

        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
        try restoreTestFileTimes(at: url, from: generationOneStat)
        let generationTwoStat = try testFileStat(at: url)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertNotEqual(generationTwoStat.inode, generationOneStat.inode)
        XCTAssertTrue(
            generationTwoStat.statusChangeTime.tv_sec != generationOneStat.statusChangeTime.tv_sec
                || generationTwoStat.statusChangeTime.tv_nsec != generationOneStat.statusChangeTime.tv_nsec
        )
        XCTAssertEqual(generationTwoStat.size, generationOneStat.size)
        XCTAssertEqual(generationTwoStat.modificationTime.tv_sec, generationOneStat.modificationTime.tv_sec)
        XCTAssertEqual(generationTwoStat.modificationTime.tv_nsec, generationOneStat.modificationTime.tv_nsec)

        let generationTwoStore = VideoPlaybackProgressStore(
            defaults: defaults,
            appBuildIdentifier: "generation-2"
        )

        XCTAssertEqual(
            generationTwoStore.history(for: VideoItem(url: url, duration: nil)),
            .viewed(position: 42.5, duration: 100)
        )
    }

    func testVideoPlaybackHistoryDoesNotTransferAcrossAppUpdateToDifferentSameSizeContentWithOriginalMTime() throws {
        let suiteName = "PlayerScrubLogicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Movie.mp4")
        let originalBytes = Data("original-video-bytes".utf8)
        let replacementBytes = Data("replaced-video-bytes".utf8)
        XCTAssertNotEqual(originalBytes, replacementBytes)
        XCTAssertEqual(originalBytes.count, replacementBytes.count)
        try originalBytes.write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)],
            ofItemAtPath: url.path
        )
        let generationOneStat = try testFileStat(at: url)
        let generationOneStore = VideoPlaybackProgressStore(
            defaults: defaults,
            appBuildIdentifier: "generation-1"
        )
        generationOneStore.save(
            position: 42.5,
            duration: 100,
            for: VideoItem(url: url, duration: nil)
        )

        try FileManager.default.removeItem(at: url)
        try replacementBytes.write(to: url)
        try restoreTestFileTimes(at: url, from: generationOneStat)
        let generationTwoStat = try testFileStat(at: url)
        XCTAssertEqual(try Data(contentsOf: url), replacementBytes)
        XCTAssertNotEqual(generationTwoStat.inode, generationOneStat.inode)
        XCTAssertTrue(
            generationTwoStat.statusChangeTime.tv_sec != generationOneStat.statusChangeTime.tv_sec
                || generationTwoStat.statusChangeTime.tv_nsec != generationOneStat.statusChangeTime.tv_nsec
        )
        XCTAssertEqual(generationTwoStat.size, generationOneStat.size)
        XCTAssertEqual(generationTwoStat.modificationTime.tv_sec, generationOneStat.modificationTime.tv_sec)
        XCTAssertEqual(generationTwoStat.modificationTime.tv_nsec, generationOneStat.modificationTime.tv_nsec)

        let generationTwoStore = VideoPlaybackProgressStore(
            defaults: defaults,
            appBuildIdentifier: "generation-2"
        )

        XCTAssertEqual(
            generationTwoStore.history(for: VideoItem(url: url, duration: nil)),
            .new
        )
    }

    func testVideoPlaybackProgressStoreMigratesV1PositionAndBindsCurrentSource() throws {
        let suiteName = "PlayerScrubLogicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Legacy.mp4")
        try Data("legacy source".utf8).write(to: url)
        defaults.set(["Legacy.mp4": 42.5], forKey: "VideoPlaybackProgressStore.positions.v1")
        let video = VideoItem(url: url, duration: nil)
        let store = VideoPlaybackProgressStore(defaults: defaults)

        XCTAssertEqual(store.position(for: video), 42.5)
        XCTAssertEqual(store.history(for: video).state, .viewed)

        try Data("new source with another size".utf8).write(to: url)
        XCTAssertEqual(store.history(for: video), .new)
    }

    func testVideoPlaybackProgressStoreMigratesLegacyV2HistoryAndPersistsRebinding() throws {
        let suiteName = "PlayerScrubLogicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("legacy-v2-video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let fileStat = try testFileStat(at: url)
        let legacyModificationTime = TimeInterval(fileStat.modificationTime.tv_sec)
            + TimeInterval(fileStat.modificationTime.tv_nsec) / 1_000_000_000
        let legacyHistory = LegacyV2StoredPlaybackHistory(
            source: LegacyV2PlaybackSourceIdentity(
                size: Int(fileStat.size),
                modificationTime: legacyModificationTime
            ),
            record: LegacyV2PlaybackHistoryRecord(
                state: "viewed",
                position: 42.5,
                duration: 100
            )
        )
        let data = try JSONEncoder().encode([url.lastPathComponent: legacyHistory])
        defaults.set(data, forKey: "VideoPlaybackProgressStore.history.v2")
        let video = VideoItem(url: url, duration: nil)

        let migrated = VideoPlaybackProgressStore(defaults: defaults).history(for: video)
        XCTAssertEqual(migrated, .viewed(position: 42.5, duration: 100))

        let relaunched = VideoPlaybackProgressStore(defaults: defaults).history(for: video)
        XCTAssertEqual(relaunched, .viewed(position: 42.5, duration: 100))
    }

    func testLegacyV2MigrationPreservesAllMatchingSiblingVideoRecords() throws {
        let suiteName = "PlayerScrubLogicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstURL = root.appendingPathComponent("First.mp4")
        let secondURL = root.appendingPathComponent("Second.mov")
        try Data("first legacy video".utf8).write(to: firstURL)
        try Data("second legacy video".utf8).write(to: secondURL)

        let firstStat = try testFileStat(at: firstURL)
        let secondStat = try testFileStat(at: secondURL)
        let firstLegacyModificationTime = TimeInterval(firstStat.modificationTime.tv_sec)
            + TimeInterval(firstStat.modificationTime.tv_nsec) / 1_000_000_000
        let secondLegacyModificationTime = TimeInterval(secondStat.modificationTime.tv_sec)
            + TimeInterval(secondStat.modificationTime.tv_nsec) / 1_000_000_000
        let legacyHistory = [
            firstURL.lastPathComponent: LegacyV2StoredPlaybackHistory(
                source: LegacyV2PlaybackSourceIdentity(
                    size: Int(firstStat.size),
                    modificationTime: firstLegacyModificationTime
                ),
                record: LegacyV2PlaybackHistoryRecord(
                    state: "viewed",
                    position: 12,
                    duration: 100
                )
            ),
            secondURL.lastPathComponent: LegacyV2StoredPlaybackHistory(
                source: LegacyV2PlaybackSourceIdentity(
                    size: Int(secondStat.size),
                    modificationTime: secondLegacyModificationTime
                ),
                record: LegacyV2PlaybackHistoryRecord(
                    state: "viewed",
                    position: 34,
                    duration: 200
                )
            )
        ]
        defaults.set(
            try JSONEncoder().encode(legacyHistory),
            forKey: "VideoPlaybackProgressStore.history.v2"
        )
        let firstVideo = VideoItem(url: firstURL, duration: nil)
        let secondVideo = VideoItem(url: secondURL, duration: nil)

        XCTAssertEqual(
            VideoPlaybackProgressStore(defaults: defaults).history(for: firstVideo),
            .viewed(position: 12, duration: 100)
        )
        let relaunchedStore = VideoPlaybackProgressStore(defaults: defaults)
        XCTAssertEqual(
            relaunchedStore.history(for: secondVideo),
            .viewed(position: 34, duration: 200)
        )
        XCTAssertEqual(
            relaunchedStore.history(for: firstVideo),
            .viewed(position: 12, duration: 100)
        )
    }

    func testVideoPlaybackHistoryPersistsViewedAtZeroPeriodicProgressAndCompletion() throws {
        let suiteName = "PlayerScrubLogicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = VideoItem(url: url, duration: nil)
        let store = VideoPlaybackProgressStore(defaults: defaults)

        XCTAssertEqual(store.history(for: video), .new)
        store.markViewed(for: video)
        XCTAssertEqual(store.history(for: video).state, .viewed)
        XCTAssertEqual(store.history(for: video).position, 0)

        store.save(position: 25, duration: 100, for: video)
        XCTAssertEqual(store.history(for: video).progressFraction, 0.25)

        store.markCompleted(duration: 100, for: video)
        XCTAssertEqual(store.history(for: video).state, .completed)
        XCTAssertEqual(store.history(for: video).progressFraction, 1)

        store.save(position: 100, duration: 100, for: video)
        XCTAssertEqual(store.history(for: video).state, .completed)
    }

    func testMarkViewedResetsCompletedHistoryToStartForReplay() throws {
        let suiteName = "PlayerScrubLogicTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        try Data("video".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = VideoItem(url: url, duration: nil)
        let store = VideoPlaybackProgressStore(defaults: defaults)

        store.markCompleted(duration: 100, for: video)
        XCTAssertEqual(store.history(for: video), .completed(duration: 100))

        store.markViewed(for: video)
        XCTAssertEqual(store.history(for: video), .viewed(position: 0, duration: 100))
    }

    func testVideoPlaybackResumePolicyRestoresOnlyMeaningfulPositionBeforeTheEnd() {
        XCTAssertEqual(
            VideoPlaybackResumePolicy.position(storedPosition: 42.5, duration: 100),
            42.5
        )
        XCTAssertNil(VideoPlaybackResumePolicy.position(storedPosition: 120, duration: 100))
        XCTAssertNil(VideoPlaybackResumePolicy.position(storedPosition: 99, duration: 100))
        XCTAssertNil(VideoPlaybackResumePolicy.position(storedPosition: 0, duration: 100))
        XCTAssertNil(VideoPlaybackResumePolicy.position(storedPosition: -1, duration: 100))
        XCTAssertNil(VideoPlaybackResumePolicy.position(storedPosition: .nan, duration: 100))
        XCTAssertNil(VideoPlaybackResumePolicy.position(storedPosition: .infinity, duration: 100))
        XCTAssertNil(VideoPlaybackResumePolicy.position(storedPosition: -.infinity, duration: 100))
        XCTAssertNil(VideoPlaybackResumePolicy.position(storedPosition: 42.5, duration: .nan))
        XCTAssertNil(VideoPlaybackResumePolicy.position(storedPosition: 42.5, duration: .infinity))
        XCTAssertNil(VideoPlaybackResumePolicy.position(storedPosition: 42.5, duration: -.infinity))
        XCTAssertNil(VideoPlaybackResumePolicy.position(storedPosition: 42.5, duration: 0))
        XCTAssertNil(VideoPlaybackResumePolicy.position(storedPosition: 42.5, duration: -100))
    }

    func testVideoPlaybackSkipPolicyUsesFifteenSecondsForBothDirections() {
        XCTAssertEqual(VideoPlaybackSkipPolicy.interval, 15)
        XCTAssertEqual(
            VideoRemoteCommandDecision.action(
                for: .skipBackward,
                currentTime: 20,
                duration: 100,
                isPlaying: true
            ),
            .seek(5)
        )
        XCTAssertEqual(
            VideoRemoteCommandDecision.action(
                for: .skipForward,
                currentTime: 20,
                duration: 100,
                isPlaying: true
            ),
            .seek(35)
        )
    }

    func testDrivePlayerVideoOptionsReportsPlayerLayerDeinitAfterKSPlayerCleanup() {
        var callbackCount = 0
        let options = DrivePlayerVideoOptions(onPlayerLayerDeinit: {
            callbackCount += 1
        })

        options.playerLayerDeinit()

        XCTAssertEqual(callbackCount, 1)
    }

    func testVideoSeekRequestValidationAcceptsOnlyFiniteTargetsWithinFinitePositiveDuration() {
        XCTAssertTrue(VideoSeekRequestValidation.canIssue(targetTime: 0, duration: 60))
        XCTAssertTrue(VideoSeekRequestValidation.canIssue(targetTime: 60, duration: 60))

        XCTAssertFalse(VideoSeekRequestValidation.canIssue(targetTime: -0.1, duration: 60))
        XCTAssertFalse(VideoSeekRequestValidation.canIssue(targetTime: 60.1, duration: 60))
        XCTAssertFalse(VideoSeekRequestValidation.canIssue(targetTime: .nan, duration: 60))
        XCTAssertFalse(VideoSeekRequestValidation.canIssue(targetTime: .infinity, duration: 60))

        XCTAssertFalse(VideoSeekRequestValidation.canIssue(targetTime: 30, duration: 0))
        XCTAssertFalse(VideoSeekRequestValidation.canIssue(targetTime: 30, duration: -60))
        XCTAssertFalse(VideoSeekRequestValidation.canIssue(targetTime: 30, duration: .nan))
        XCTAssertFalse(VideoSeekRequestValidation.canIssue(targetTime: 30, duration: .infinity))
    }

    func testVideoPausePublicationRequiresCurrentPlaybackOwnership() {
        XCTAssertTrue(
            VideoPausePublicationDecision.shouldPublish(
                isPlaying: true,
                hasCurrentOwnership: true
            )
        )
        XCTAssertFalse(
            VideoPausePublicationDecision.shouldPublish(
                isPlaying: true,
                hasCurrentOwnership: false
            )
        )
        XCTAssertFalse(
            VideoPausePublicationDecision.shouldPublish(
                isPlaying: false,
                hasCurrentOwnership: true
            )
        )
    }

    func testVideoRemotePlaybackActionExecutorPropagatesSeekRejection() {
        var seekTargets: [TimeInterval] = []

        let result = VideoRemotePlaybackActionExecutor.perform(
            .seek(25),
            play: {
                XCTFail("Play should not be called for a seek action")
                return true
            },
            pause: {
                XCTFail("Pause should not be called for a seek action")
                return true
            },
            seek: { target in
                seekTargets.append(target)
                return false
            }
        )

        XCTAssertFalse(result)
        XCTAssertEqual(seekTargets, [25])
    }

    func testSeekPlaybackPlanDefersPlaybackDecisionUntilLatestSuccessfulCompletion() {
        let resumePlan = SeekPlaybackPlan(shouldResume: true)
        let pausePlan = SeekPlaybackPlan(shouldResume: false)

        XCTAssertFalse(resumePlan.engineAutoPlay)
        XCTAssertNil(resumePlan.completionAction(finished: true, isCurrent: false))
        XCTAssertEqual(
            resumePlan.completionAction(finished: true, isCurrent: true),
            .play
        )
        XCTAssertEqual(
            pausePlan.completionAction(finished: true, isCurrent: true),
            .pause
        )
        XCTAssertEqual(
            resumePlan.completionAction(finished: false, isCurrent: true),
            .restorePreviousTime
        )
    }

    func testOnlyLatestSeekRequestCanApplyCompletion() {
        var requests = SeekRequestGeneration()
        let olderRequest = requests.issue()
        let latestRequest = requests.issue()

        XCTAssertFalse(requests.isCurrent(olderRequest))
        XCTAssertTrue(requests.isCurrent(latestRequest))

        requests.invalidate()
        XCTAssertFalse(requests.isCurrent(latestRequest))
    }

    func testGestureEndWithoutStartedScrubShouldNotFinish() {
        XCTAssertFalse(
            PlayerScrubLogic.shouldFinishScrubbing(
                startTime: nil,
                preview: nil
            )
        )

        let preview = PlayerScrubLogic.preview(
            translation: 24,
            currentTime: 40,
            duration: 120
        )
        XCTAssertTrue(
            PlayerScrubLogic.shouldFinishScrubbing(
                startTime: 40,
                preview: preview
            )
        )
    }

    func testTranslationBelowThresholdDoesNotStartScrubbing() {
        XCTAssertNil(
            PlayerScrubLogic.preview(
                translation: 23.9,
                currentTime: 40,
                duration: 120
            )
        )
    }

    func testTranslationAtThresholdStartsScrubbing() throws {
        let preview = try XCTUnwrap(
            PlayerScrubLogic.preview(
                translation: 24,
                currentTime: 40,
                duration: 120
            )
        )

        XCTAssertEqual(preview.relativeSeconds, 6, accuracy: 0.001)
        XCTAssertEqual(preview.targetTime, 46, accuracy: 0.001)
    }

    func testActivatedScrubContinuesUpdatingInsideThreshold() throws {
        let activatedPreview = try XCTUnwrap(
            PlayerScrubLogic.preview(
                translation: 100,
                currentTime: 40,
                duration: 120
            )
        )
        XCTAssertEqual(activatedPreview.targetTime, 65, accuracy: 0.001)

        let preview = try XCTUnwrap(
            PlayerScrubLogic.preview(
                translation: 10,
                currentTime: 40,
                duration: 120,
                isActivated: true
            )
        )

        XCTAssertEqual(preview.relativeSeconds, 2.5, accuracy: 0.001)
        XCTAssertEqual(preview.targetTime, 42.5, accuracy: 0.001)
    }

    func testRightDragConvertsHorizontalDistanceToForwardTime() throws {
        let preview = try XCTUnwrap(
            PlayerScrubLogic.preview(
                translation: 80,
                currentTime: 50,
                duration: 120
            )
        )

        XCTAssertEqual(preview.relativeSeconds, 20, accuracy: 0.001)
        XCTAssertEqual(preview.targetTime, 70, accuracy: 0.001)
    }

    func testLeftDragClampsPreviewAtStart() throws {
        let preview = try XCTUnwrap(
            PlayerScrubLogic.preview(
                translation: -80,
                currentTime: 10,
                duration: 120
            )
        )

        XCTAssertEqual(preview.relativeSeconds, -10, accuracy: 0.001)
        XCTAssertEqual(preview.targetTime, 0, accuracy: 0.001)
    }

    func testRightDragClampsPreviewAtDuration() throws {
        let preview = try XCTUnwrap(
            PlayerScrubLogic.preview(
                translation: 80,
                currentTime: 110,
                duration: 120
            )
        )

        XCTAssertEqual(preview.relativeSeconds, 10, accuracy: 0.001)
        XCTAssertEqual(preview.targetTime, 120, accuracy: 0.001)
    }

    func testInvalidDurationDoesNotStartScrubbing() {
        XCTAssertNil(
            PlayerScrubLogic.preview(
                translation: 80,
                currentTime: 10,
                duration: 0
            )
        )
    }

    func testTimeFormattingSupportsMinutesHoursAndInvalidValues() {
        XCTAssertEqual(PlayerScrubLogic.formattedTime(65), "1:05")
        XCTAssertEqual(PlayerScrubLogic.formattedTime(3_661), "1:01:01")
        XCTAssertEqual(PlayerScrubLogic.formattedTime(-1), "0:00")
        XCTAssertEqual(PlayerScrubLogic.formattedTime(.infinity), "0:00")
    }

    func testTapCountMapsSingleAndDoubleTapToDistinctActions() {
        XCTAssertEqual(PlayerScrubLogic.tapAction(tapCount: 1), .toggleControls)
        XCTAssertEqual(PlayerScrubLogic.tapAction(tapCount: 2), .togglePlayback)
    }

    func testRightHalfPredominantlyVerticalDragAdjustsVolume() {
        XCTAssertEqual(
            PlayerScrubLogic.dragRoute(
                startX: 75,
                translationX: 20,
                translationY: -21,
                viewWidth: 100
            ),
            .adjustVolume
        )
    }

    func testHorizontalDominanceAndAxisTieRemainScrubbing() {
        XCTAssertEqual(
            PlayerScrubLogic.dragRoute(
                startX: 75,
                translationX: 21,
                translationY: -20,
                viewWidth: 100
            ),
            .scrub
        )
        XCTAssertEqual(
            PlayerScrubLogic.dragRoute(
                startX: 75,
                translationX: 20,
                translationY: -20,
                viewWidth: 100
            ),
            .scrub
        )
    }

    func testVerticalDragUsesExactHalfBoundaryAndIgnoresLeftHalf() {
        XCTAssertEqual(
            PlayerScrubLogic.dragRoute(
                startX: 50,
                translationX: 0,
                translationY: 20,
                viewWidth: 100
            ),
            .adjustVolume
        )
        XCTAssertEqual(
            PlayerScrubLogic.dragRoute(
                startX: 49.999,
                translationX: 0,
                translationY: 20,
                viewWidth: 100
            ),
            .ignored
        )
    }

    func testVolumeMappingUsesCapturedStartVolumeAndFullHeightSensitivity() throws {
        XCTAssertEqual(
            try XCTUnwrap(PlayerScrubLogic.volume(
                startVolume: 0.4,
                verticalTranslation: -25,
                viewHeight: 100
            )),
            0.65,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(PlayerScrubLogic.volume(
                startVolume: 0.4,
                verticalTranslation: 25,
                viewHeight: 100
            )),
            0.15,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(PlayerScrubLogic.volume(
                startVolume: 0.4,
                verticalTranslation: -100,
                viewHeight: 100
            )),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(PlayerScrubLogic.volume(
                startVolume: 0.4,
                verticalTranslation: 100,
                viewHeight: 100
            )),
            0,
            accuracy: 0.001
        )
    }

    func testGestureLogicRejectsInvalidOrNonFiniteGeometry() {
        XCTAssertEqual(
            PlayerScrubLogic.dragRoute(
                startX: 50,
                translationX: 0,
                translationY: 20,
                viewWidth: 0
            ),
            .ignored
        )
        XCTAssertEqual(
            PlayerScrubLogic.dragRoute(
                startX: .infinity,
                translationX: 0,
                translationY: 20,
                viewWidth: 100
            ),
            .ignored
        )
        XCTAssertNil(
            PlayerScrubLogic.volume(
                startVolume: .nan,
                verticalTranslation: 20,
                viewHeight: 100
            )
        )
        XCTAssertNil(
            PlayerScrubLogic.volume(
                startVolume: 0.4,
                verticalTranslation: .infinity,
                viewHeight: 100
            )
        )
        XCTAssertNil(
            PlayerScrubLogic.volume(
                startVolume: 0.4,
                verticalTranslation: 20,
                viewHeight: 0
            )
        )
    }

    func testSuccessfulFinishSelectsNextPlayableItemInCapturedLibraryOrder() throws {
        let videos = ["A", "B", "C"].map {
            VideoItem(url: URL(fileURLWithPath: "/tmp/\($0).mp4"), duration: nil)
        }
        var controller = VideoAutoAdvanceController(
            orderedVideos: videos,
            initialVideoID: videos[0].id
        )

        let request = try XCTUnwrap(controller.successfulFinish(
            finishedVideoID: videos[0].id,
            availableVideoIDs: Set(videos.map(\.id)),
            isPlayable: { _ in true }
        ))

        XCTAssertEqual(request.sourceID, videos[0].id)
        XCTAssertEqual(request.targetID, videos[1].id)
    }

    func testSuccessfulFinishOfLastVideoWrapsToFirstPlayableItem() throws {
        let videos = ["A", "B", "C"].map {
            VideoItem(url: URL(fileURLWithPath: "/tmp/\($0).mp4"), duration: nil)
        }
        var controller = VideoAutoAdvanceController(
            orderedVideos: videos,
            initialVideoID: videos[2].id
        )

        let request = try XCTUnwrap(controller.successfulFinish(
            finishedVideoID: videos[2].id,
            availableVideoIDs: Set(videos.map(\.id)),
            isPlayable: { _ in true }
        ))

        XCTAssertEqual(request.sourceID, videos[2].id)
        XCTAssertEqual(request.targetID, videos[0].id)
    }

    func testAutoAdvanceCompletionPolicyDisabledDoesNotConsumeControllerState() throws {
        let videos = ["A", "B"].map {
            VideoItem(url: URL(fileURLWithPath: "/tmp/\($0).mp4"), duration: nil)
        }
        var controller = VideoAutoAdvanceController(
            orderedVideos: videos,
            initialVideoID: videos[0].id
        )
        let availableVideoIDs = Set(videos.map(\.id))

        XCTAssertNil(VideoAutoAdvanceCompletionPolicy.successfulFinish(
            isEnabled: false,
            controller: &controller,
            finishedVideoID: videos[0].id,
            availableVideoIDs: availableVideoIDs,
            isPlayable: { _ in true }
        ))

        let request = try XCTUnwrap(controller.successfulFinish(
            finishedVideoID: videos[0].id,
            availableVideoIDs: availableVideoIDs,
            isPlayable: { _ in true }
        ))
        XCTAssertEqual(request.targetID, videos[1].id)
        XCTAssertEqual(request.generation, 1)
    }

    func testAutoAdvanceCompletionPolicyEnabledDelegatesToExistingController() throws {
        let videos = ["A", "B"].map {
            VideoItem(url: URL(fileURLWithPath: "/tmp/\($0).mp4"), duration: nil)
        }
        var controller = VideoAutoAdvanceController(
            orderedVideos: videos,
            initialVideoID: videos[0].id
        )

        let request = try XCTUnwrap(VideoAutoAdvanceCompletionPolicy.successfulFinish(
            isEnabled: true,
            controller: &controller,
            finishedVideoID: videos[0].id,
            availableVideoIDs: Set(videos.map(\.id)),
            isPlayable: { _ in true }
        ))

        XCTAssertEqual(request.targetID, videos[1].id)
        XCTAssertEqual(request.generation, 1)
    }

    func testAutoAdvanceSuppressesResumeOnlyForCompletedTarget() {
        XCTAssertFalse(VideoAutoAdvanceResumePolicy.shouldSuppressResume(history: .new))
        XCTAssertFalse(VideoAutoAdvanceResumePolicy.shouldSuppressResume(
            history: .viewed(position: 42, duration: 100)
        ))
        XCTAssertTrue(VideoAutoAdvanceResumePolicy.shouldSuppressResume(
            history: .completed(duration: 100)
        ))
    }

    func testPendingTransitionRejectsFinishUntilTargetPlaybackBegins() throws {
        let videos = ["A", "B", "C"].map {
            VideoItem(url: URL(fileURLWithPath: "/tmp/\($0).mp4"), duration: nil)
        }
        var controller = VideoAutoAdvanceController(
            orderedVideos: videos,
            initialVideoID: videos[0].id
        )

        let requestAB = try XCTUnwrap(controller.successfulFinish(
            finishedVideoID: videos[0].id,
            availableVideoIDs: Set(videos.map(\.id)),
            isPlayable: { _ in true }
        ))

        XCTAssertNil(controller.successfulFinish(
            finishedVideoID: videos[1].id,
            availableVideoIDs: Set(videos.map(\.id)),
            isPlayable: { _ in true }
        ))
        XCTAssertTrue(controller.beginPlayback(
            request: requestAB,
            currentVideoID: videos[1].id
        ))

        let requestBC = try XCTUnwrap(controller.successfulFinish(
            finishedVideoID: videos[1].id,
            availableVideoIDs: Set(videos.map(\.id)),
            isPlayable: { _ in true }
        ))
        XCTAssertEqual(requestBC.sourceID, videos[1].id)
        XCTAssertEqual(requestBC.targetID, videos[2].id)
    }

    func testPendingAdvanceRequiresMatchingLoadedURLAndPlaybackOwnership() throws {
        let videos = ["A", "B"].map {
            VideoItem(url: URL(fileURLWithPath: "/tmp/\($0).mp4"), duration: nil)
        }
        var controller = VideoAutoAdvanceController(
            orderedVideos: videos,
            initialVideoID: videos[0].id
        )
        let request = try XCTUnwrap(controller.successfulFinish(
            finishedVideoID: videos[0].id,
            availableVideoIDs: Set(videos.map(\.id)),
            isPlayable: { _ in true }
        ))

        XCTAssertFalse(VideoAutoAdvancePlaybackGate.permits(
            controller: controller,
            request: request,
            currentVideoID: videos[1].id,
            loadedURL: videos[0].url,
            ownershipAllowed: true
        ))
        XCTAssertFalse(VideoAutoAdvancePlaybackGate.permits(
            controller: controller,
            request: request,
            currentVideoID: videos[1].id,
            loadedURL: videos[1].url,
            ownershipAllowed: false
        ))
        XCTAssertTrue(VideoAutoAdvancePlaybackGate.permits(
            controller: controller,
            request: request,
            currentVideoID: videos[1].id,
            loadedURL: videos[1].url,
            ownershipAllowed: true
        ))
    }

    func testInvalidationPreventsPendingAutoAdvancePlayback() throws {
        let videos = ["A", "B"].map {
            VideoItem(url: URL(fileURLWithPath: "/tmp/\($0).mp4"), duration: nil)
        }
        var controller = VideoAutoAdvanceController(
            orderedVideos: videos,
            initialVideoID: videos[0].id
        )

        let request = try XCTUnwrap(controller.successfulFinish(
            finishedVideoID: videos[0].id,
            availableVideoIDs: Set(videos.map(\.id)),
            isPlayable: { _ in true }
        ))
        controller.invalidate()

        XCTAssertFalse(controller.permitsPlayback(
            request: request,
            currentVideoID: videos[1].id
        ))
    }

    func testInvalidatedControllerRejectsLateFinishUntilPlaybackRestarts() throws {
        let videos = ["A", "B"].map {
            VideoItem(url: URL(fileURLWithPath: "/tmp/\($0).mp4"), duration: nil)
        }
        var controller = VideoAutoAdvanceController(
            orderedVideos: videos,
            initialVideoID: videos[0].id
        )

        controller.invalidate()

        XCTAssertNil(controller.successfulFinish(
            finishedVideoID: videos[0].id,
            availableVideoIDs: Set(videos.map(\.id)),
            isPlayable: { _ in true }
        ))
        XCTAssertTrue(controller.notePlaybackStarted(videoID: videos[0].id))

        let request = try XCTUnwrap(controller.successfulFinish(
            finishedVideoID: videos[0].id,
            availableVideoIDs: Set(videos.map(\.id)),
            isPlayable: { _ in true }
        ))
        XCTAssertEqual(request.targetID, videos[1].id)
    }
}
