import AVFoundation
import Combine
import CryptoKit
import Darwin
import Foundation

actor MediaMetadataSnapshotStore {
    private static let fingerprintWindowBytes = 64 * 1024
    static let maximumFingerprintBytesRead = 3 * fingerprintWindowBytes

    enum Category: Equatable, Sendable {
        case music
        case video
    }

    struct Revision: Equatable, Sendable {
        fileprivate let category: Category
        fileprivate let value: UInt64
    }

    struct FileFingerprint: Codable, Equatable, Sendable {
        let fileSize: Int64
        let modificationDate: Date
        let contentSHA256Hex: String
        let fileSystemIdentifier: UInt64
        let fileObjectIdentifier: UInt64
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64

        init(
            fileSize: Int64,
            modificationDate: Date,
            contentSHA256Hex: String = "",
            fileSystemIdentifier: UInt64 = 0,
            fileObjectIdentifier: UInt64 = 0,
            statusChangeSeconds: Int64 = 0,
            statusChangeNanoseconds: Int64 = 0
        ) {
            self.fileSize = fileSize
            self.modificationDate = modificationDate
            self.contentSHA256Hex = contentSHA256Hex
            self.fileSystemIdentifier = fileSystemIdentifier
            self.fileObjectIdentifier = fileObjectIdentifier
            self.statusChangeSeconds = statusChangeSeconds
            self.statusChangeNanoseconds = statusChangeNanoseconds
        }
    }

    struct VideoSnapshot: Codable, Equatable, Sendable {
        let fingerprint: FileFingerprint
        let duration: TimeInterval
    }

    struct MusicSnapshot: Equatable, Sendable {
        let fingerprint: FileFingerprint
        let duration: TimeInterval?
        let metadata: MusicMetadata?
    }

    private struct MusicMetadataPayload: Codable, Equatable {
        let title: String
        let artist: String?
        let album: String?
        let artworkData: Data?
        let lyrics: String?
        let synchronizedLyricsData: Data?

        init(_ metadata: MusicMetadata) {
            title = metadata.title
            artist = metadata.artist
            album = metadata.album
            artworkData = metadata.artworkData
            lyrics = metadata.lyrics
            synchronizedLyricsData = metadata.synchronizedLyricsData
        }

        var metadata: MusicMetadata {
            MusicMetadata(
                title: title,
                artist: artist,
                album: album,
                artworkData: artworkData,
                lyrics: lyrics,
                synchronizedLyricsData: synchronizedLyricsData
            )
        }

        var isWithinResourceLimits: Bool {
            let limits = MusicMetadataResourceLimits.default
            return artworkData?.count ?? 0 <= limits.maximumArtworkBytes
                && synchronizedLyricsData?.count ?? 0 <= limits.maximumSynchronizedLyricsBytes
                && [title, artist, album, lyrics].allSatisfy {
                    $0?.utf8.count ?? 0 <= limits.maximumTextBytes
                }
        }

        var resourceByteCount: Int? {
            let values = [
                title.utf8.count,
                artist?.utf8.count ?? 0,
                album?.utf8.count ?? 0,
                artworkData?.count ?? 0,
                lyrics?.utf8.count ?? 0,
                synchronizedLyricsData?.count ?? 0,
            ]
            var total = 0
            for value in values {
                let result = total.addingReportingOverflow(value)
                guard !result.overflow else { return nil }
                total = result.partialValue
            }
            return total
        }
    }

    private struct PersistedMusicSnapshot: Codable, Equatable {
        let fingerprint: FileFingerprint
        let duration: TimeInterval?
        let metadata: MusicMetadataPayload?

        var isValid: Bool {
            guard fingerprint.fileSize >= 0,
                  metadata?.isWithinResourceLimits != false else {
                return false
            }
            guard let duration else { return true }
            return duration.isFinite && duration >= 0
        }
    }

    private struct PersistedSnapshots: Codable, Equatable {
        let version: Int
        let installationGeneration: String
        var videos: [String: VideoSnapshot]
        var music: [String: PersistedMusicSnapshot]

        private enum CodingKeys: String, CodingKey {
            case version, installationGeneration, videos, music
        }

        init(
            version: Int,
            installationGeneration: String,
            videos: [String: VideoSnapshot],
            music: [String: PersistedMusicSnapshot]
        ) {
            self.version = version
            self.installationGeneration = installationGeneration
            self.videos = videos
            self.music = music
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            installationGeneration = try container.decode(String.self, forKey: .installationGeneration)
            videos = try container.decodeIfPresent([String: VideoSnapshot].self, forKey: .videos) ?? [:]
            music = try container.decodeIfPresent([String: PersistedMusicSnapshot].self, forKey: .music) ?? [:]
        }
    }

    private static let currentVersion = 3

    static let shared = MediaMetadataSnapshotStore.live()

    static func live(fileManager: FileManager = .default) -> MediaMetadataSnapshotStore {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return MediaMetadataSnapshotStore(
            fileURL: applicationSupport.appendingPathComponent(
                "MediaMetadataSnapshots.json",
                isDirectory: false
            ),
            fileManager: fileManager,
            installationGeneration: installationGeneration(
                at: caches.appendingPathComponent("MediaMetadataInstallationGeneration", isDirectory: false),
                fileManager: fileManager
            )
        )
    }

    private static func installationGeneration(at url: URL, fileManager: FileManager) -> String {
        if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
           values.isRegularFile == true,
           values.fileSize == 36,
           let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
           data.count == 36,
           let value = String(data: data, encoding: .utf8),
           UUID(uuidString: value) != nil {
            return value
        }
        let value = UUID().uuidString
        try? fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? Data(value.utf8).write(to: url, options: .atomic)
        return value
    }

    private let fileURL: URL
    private let fileManager: FileManager
    private let maximumEncodedBytes: Int
    private let maximumEntryCount: Int
    private let maximumAggregatePayloadBytes: Int
    private let installationGeneration: String
    private let musicSnapshotPreReturnHook: (@Sendable () async -> Void)?
    private var snapshots: PersistedSnapshots?
    private var lastPersistedSnapshots: PersistedSnapshots?
    private var latestMusicRevision: UInt64 = 0
    private var latestVideoRevision: UInt64 = 0

    init(
        fileURL: URL,
        fileManager: FileManager = .default,
        maximumEncodedBytes: Int = 8 * 1024 * 1024,
        maximumEntryCount: Int = 1_024,
        maximumAggregatePayloadBytes: Int = 4 * 1024 * 1024,
        installationGeneration: String = "test-installation",
        musicSnapshotPreReturnHook: (@Sendable () async -> Void)? = nil
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        self.maximumEncodedBytes = max(0, maximumEncodedBytes)
        self.maximumEntryCount = max(0, maximumEntryCount)
        self.maximumAggregatePayloadBytes = max(0, maximumAggregatePayloadBytes)
        self.installationGeneration = installationGeneration
        self.musicSnapshotPreReturnHook = musicSnapshotPreReturnHook
    }

    func videoDuration(for url: URL) -> TimeInterval? {
        guard let currentFingerprint = fingerprint(for: url) else { return nil }
        return videoDuration(for: url, matching: currentFingerprint)
    }

    func sourceIdentity(for url: URL) -> FileFingerprint? {
        fingerprint(for: url)
    }

    func videoDuration(for url: URL, matching fingerprint: FileFingerprint) -> TimeInterval? {
        loadIfNeeded()
        guard let snapshot = snapshots?.videos[url.lastPathComponent],
              fingerprint == snapshot.fingerprint,
              snapshot.duration.isFinite,
              snapshot.duration >= 0 else {
            return nil
        }
        return snapshot.duration
    }

    func musicSnapshot(for url: URL) async -> MusicSnapshot? {
        guard let currentFingerprint = fingerprint(for: url) else { return nil }
        return await musicSnapshot(for: url, matching: currentFingerprint)
    }

    func musicSnapshot(for url: URL, matching fingerprint: FileFingerprint) async -> MusicSnapshot? {
        loadIfNeeded()
        guard let snapshot = snapshots?.music[url.lastPathComponent],
              fingerprint == snapshot.fingerprint else {
            return nil
        }
        await musicSnapshotPreReturnHook?()
        return MusicSnapshot(
            fingerprint: snapshot.fingerprint,
            duration: snapshot.duration,
            metadata: snapshot.metadata?.metadata
        )
    }

    func beginRefresh(for category: Category) -> Revision {
        switch category {
        case .music:
            latestMusicRevision += 1
            return Revision(category: category, value: latestMusicRevision)
        case .video:
            latestVideoRevision += 1
            return Revision(category: category, value: latestVideoRevision)
        }
    }

    func replaceMusic(with replacements: [URL: MusicSnapshot], revision: Revision) {
        guard revision.category == .music,
              revision.value == latestMusicRevision else { return }
        loadIfNeeded()

        var music: [String: PersistedMusicSnapshot] = [:]
        for (url, snapshot) in replacements {
            guard let currentFingerprint = fingerprint(for: url),
                  currentFingerprint == snapshot.fingerprint else { continue }
            let validDuration = snapshot.duration.flatMap {
                $0.isFinite && $0 >= 0 ? $0 : nil
            }
            let payload = snapshot.metadata.map(MusicMetadataPayload.init)
            guard payload?.isWithinResourceLimits != false else { continue }
            music[url.lastPathComponent] = PersistedMusicSnapshot(
                fingerprint: currentFingerprint,
                duration: validDuration,
                metadata: payload
            )
        }

        guard var replacement = snapshots else { return }
        replacement.music = music
        guard isWithinAggregatePayloadBudget(replacement) else { return }
        snapshots = replacement
        guard replacement != lastPersistedSnapshots else { return }
        if persist(replacement) {
            lastPersistedSnapshots = replacement
        }
    }

    func replaceVideos(with durations: [URL: TimeInterval], revision: Revision) {
        let snapshots = durations.reduce(into: [URL: VideoSnapshot]()) { result, entry in
            guard entry.value.isFinite, entry.value >= 0,
                  let fingerprint = fingerprint(for: entry.key) else { return }
            result[entry.key] = VideoSnapshot(fingerprint: fingerprint, duration: entry.value)
        }
        replaceVideos(with: snapshots, revision: revision)
    }

    func replaceVideos(with replacements: [URL: VideoSnapshot], revision: Revision) {
        guard revision.category == .video,
              revision.value == latestVideoRevision else { return }
        loadIfNeeded()

        var videos: [String: VideoSnapshot] = [:]
        for (url, snapshot) in replacements where snapshot.duration.isFinite && snapshot.duration >= 0 {
            guard let currentFingerprint = fingerprint(for: url),
                  currentFingerprint == snapshot.fingerprint else { continue }
            videos[url.lastPathComponent] = snapshot
        }

        guard var replacement = snapshots else { return }
        replacement.videos = videos
        snapshots = replacement
        guard replacement != lastPersistedSnapshots else { return }
        if persist(replacement) {
            lastPersistedSnapshots = replacement
        }
    }

    private func loadIfNeeded() {
        guard snapshots == nil else { return }
        snapshots = PersistedSnapshots(
            version: Self.currentVersion,
            installationGeneration: installationGeneration,
            videos: [:],
            music: [:]
        )

        guard let values = try? fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ),
        values.isRegularFile == true,
        values.isSymbolicLink != true,
        let fileSize = values.fileSize,
        fileSize >= 0,
        fileSize <= maximumEncodedBytes,
        let data = try? Data(contentsOf: fileURL),
        data.count <= maximumEncodedBytes,
        let decoded = try? JSONDecoder().decode(PersistedSnapshots.self, from: data),
        decoded.version == Self.currentVersion,
        decoded.installationGeneration == installationGeneration,
        decoded.videos.count <= maximumEntryCount,
        decoded.music.count <= maximumEntryCount - decoded.videos.count else {
            return
        }
        guard isWithinAggregatePayloadBudget(decoded) else { return }

        let sanitizedSnapshots = PersistedSnapshots(
            version: decoded.version,
            installationGeneration: decoded.installationGeneration,
            videos: decoded.videos.filter {
                $0.value.fingerprint.fileSize >= 0
                    && $0.value.duration.isFinite
                    && $0.value.duration >= 0
            },
            music: decoded.music.filter { name, snapshot in
                !name.isEmpty
                    && !name.contains("/")
                    && snapshot.isValid
            }
        )
        snapshots = sanitizedSnapshots
        lastPersistedSnapshots = sanitizedSnapshots
    }

    private func fingerprint(for url: URL) -> FileFingerprint? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)

        var initialStatus = stat()
        guard Darwin.fstat(descriptor, &initialStatus) == 0,
              (initialStatus.st_mode & S_IFMT) == S_IFREG,
              initialStatus.st_nlink == 1,
              initialStatus.st_size >= 0 else {
            return nil
        }

        let fileSize = UInt64(initialStatus.st_size)
        let windowSize = UInt64(Self.fingerprintWindowBytes)
        let finalWindowOffset = fileSize > windowSize ? fileSize - windowSize : 0
        let middleWindowOffset = fileSize > windowSize ? (fileSize - windowSize) / 2 : 0
        let offsets = Set([UInt64(0), middleWindowOffset, finalWindowOffset]).sorted()

        var hasher = SHA256()
        do {
            for offset in offsets {
                try handle.seek(toOffset: offset)
                let expectedByteCount = Int(min(windowSize, fileSize - offset))
                let data = try handle.read(upToCount: expectedByteCount) ?? Data()
                guard data.count == expectedByteCount else { return nil }
                var encodedOffset = offset.bigEndian
                withUnsafeBytes(of: &encodedOffset) {
                    hasher.update(data: Data($0))
                }
                hasher.update(data: data)
            }
        } catch {
            return nil
        }

        var finalStatus = stat()
        var pathStatus = stat()
        guard Darwin.fstat(descriptor, &finalStatus) == 0,
              Darwin.lstat(url.path, &pathStatus) == 0,
              initialStatus.st_dev == finalStatus.st_dev,
              initialStatus.st_ino == finalStatus.st_ino,
              initialStatus.st_size == finalStatus.st_size,
              initialStatus.st_mtimespec.tv_sec == finalStatus.st_mtimespec.tv_sec,
              initialStatus.st_mtimespec.tv_nsec == finalStatus.st_mtimespec.tv_nsec,
              finalStatus.st_dev == pathStatus.st_dev,
              finalStatus.st_ino == pathStatus.st_ino,
              finalStatus.st_size == pathStatus.st_size,
              finalStatus.st_mtimespec.tv_sec == pathStatus.st_mtimespec.tv_sec,
              finalStatus.st_mtimespec.tv_nsec == pathStatus.st_mtimespec.tv_nsec else {
            return nil
        }

        let modificationDate = Date(
            timeIntervalSince1970: TimeInterval(finalStatus.st_mtimespec.tv_sec)
                + TimeInterval(finalStatus.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return FileFingerprint(
            fileSize: Int64(finalStatus.st_size),
            modificationDate: modificationDate,
            contentSHA256Hex: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            fileSystemIdentifier: UInt64(finalStatus.st_dev),
            fileObjectIdentifier: UInt64(finalStatus.st_ino),
            statusChangeSeconds: Int64(finalStatus.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(finalStatus.st_ctimespec.tv_nsec)
        )
    }

    private func persist(_ value: PersistedSnapshots) -> Bool {
        guard value.videos.count <= maximumEntryCount,
              value.music.count <= maximumEntryCount - value.videos.count,
              isWithinAggregatePayloadBudget(value),
              let data = try? JSONEncoder().encode(value),
              data.count <= maximumEncodedBytes else {
            return false
        }
        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            // Metadata caching is best-effort; media remains available on write failure.
            return false
        }
    }

    private func isWithinAggregatePayloadBudget(_ value: PersistedSnapshots) -> Bool {
        var total = 0
        for snapshot in value.music.values {
            guard let metadata = snapshot.metadata else { continue }
            guard let byteCount = metadata.resourceByteCount else { return false }
            let result = total.addingReportingOverflow(byteCount)
            guard !result.overflow else { return false }
            total = result.partialValue
            guard total <= maximumAggregatePayloadBytes else { return false }
        }
        return true
    }
}

@MainActor
final class VideoLibrary: ObservableObject {
    struct ImportReport {
        let importedCount: Int
        let failedFileNames: [String]
    }

    @Published private(set) var videos: [VideoItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var libraryErrorMessage: String?

    private let storage: MediaLibraryStorage
    private let metadataSnapshotStore: MediaMetadataSnapshotStore
    private let durationLoader: @Sendable (URL) async -> TimeInterval?
    private var refreshGeneration = 0

    init(
        storage: MediaLibraryStorage? = nil,
        metadataSnapshotStore: MediaMetadataSnapshotStore = .shared,
        durationLoader: @escaping @Sendable (URL) async -> TimeInterval? = { @Sendable url in
            await VideoLibrary.defaultDurationLoader(for: url)
        }
    ) {
        self.storage = storage ?? .live()
        self.metadataSnapshotStore = metadataSnapshotStore
        self.durationLoader = durationLoader
    }

    func refresh() async {
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        libraryErrorMessage = nil
        defer {
            if generation == refreshGeneration {
                isLoading = false
            }
        }
        let revision = await metadataSnapshotStore.beginRefresh(for: .video)

        do {
            storage.migrateLegacyFiles()
            let urls = try storage.scan(kind: .video)

            var scannedVideos: [VideoItem] = []
            var loadedSnapshots: [URL: MediaMetadataSnapshotStore.VideoSnapshot] = [:]
            for url in urls {
                guard generation == refreshGeneration, !Task.isCancelled else { return }
                var resolved: (duration: TimeInterval?, identity: MediaMetadataSnapshotStore.FileFingerprint)?
                for _ in 0..<2 {
                    guard let identity = await metadataSnapshotStore.sourceIdentity(for: url) else { break }
                    let duration: TimeInterval?
                    if let cachedDuration = await metadataSnapshotStore.videoDuration(
                        for: url,
                        matching: identity
                    ) {
                        duration = cachedDuration
                    } else {
                        duration = await durationLoader(url)
                    }
                    guard generation == refreshGeneration, !Task.isCancelled else { return }
                    guard await metadataSnapshotStore.sourceIdentity(for: url) == identity else {
                        continue
                    }
                    resolved = (duration, identity)
                    break
                }
                guard let resolved else { continue }
                scannedVideos.append(
                    VideoItem(url: url, duration: resolved.duration)
                )
                if let duration = resolved.duration, duration.isFinite, duration >= 0 {
                    loadedSnapshots[url] = MediaMetadataSnapshotStore.VideoSnapshot(
                        fingerprint: resolved.identity,
                        duration: duration
                    )
                }
            }

            if generation == refreshGeneration, !Task.isCancelled {
                await metadataSnapshotStore.replaceVideos(
                    with: loadedSnapshots,
                    revision: revision
                )
                guard generation == refreshGeneration, !Task.isCancelled else { return }
                videos = scannedVideos.sorted {
                    $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
                }
            }
        } catch {
            if generation == refreshGeneration {
                videos = []
                libraryErrorMessage = "无法读取已导入的视频，请稍后重试。"
            }
        }
    }

    func importVideos(from sourceURLs: [URL]) async -> ImportReport {
        var importedCount = 0
        var failedFileNames: [String] = []

        for sourceURL in sourceURLs {
            do {
                try storage.importFile(from: sourceURL)
                importedCount += 1
            } catch {
                let displayName = sourceURL.lastPathComponent.isEmpty
                    ? "未命名文件"
                    : sourceURL.lastPathComponent
                failedFileNames.append(displayName)
            }
        }

        // Only publish the rescan result after every selected file has reached a final state.
        await refresh()
        return ImportReport(
            importedCount: importedCount,
            failedFileNames: failedFileNames
        )
    }

    func deleteVideo(_ video: VideoItem) async throws {
        try storage.deleteFile(at: video.url)
        await refresh()
    }

    static func defaultDurationLoader(for url: URL) async -> TimeInterval? {
        do {
            let duration = try await AVURLAsset(url: url).load(.duration)
            let seconds = duration.seconds
            return seconds.isFinite && seconds >= 0 ? seconds : nil
        } catch {
            return nil
        }
    }
}
