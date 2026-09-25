import Combine
import CryptoKit
import Darwin
import Foundation

internal enum VideoDetailLayoutPolicy {
    internal enum Section: Equatable {
        case title
        case video
        case transport
        case timeline
        case playbackRates
    }

    static let sectionOrder: [Section] = [
        .title,
        .video,
        .transport,
        .timeline,
        .playbackRates
    ]
    static let showsTransportControlsAsVideoOverlay = false

    static func displayTitle(for name: String) -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? "视频" : trimmedName
    }

    static func showsRootChrome(isVideoDetailPresented: Bool) -> Bool {
        !isVideoDetailPresented
    }

    static let flexibleSpaceBeforeContent = 1
    static let flexibleSpaceAfterContent = 1
}

internal enum VideoPlaybackSkipPolicy {
    static let interval: TimeInterval = 15
}

internal final class VideoAutoAdvancePreferenceStore {
    private static let isEnabledKey = "VideoAutoAdvancePreferenceStore.isEnabled.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isEnabled() -> Bool {
        defaults.object(forKey: Self.isEnabledKey) == nil
            ? true
            : defaults.bool(forKey: Self.isEnabledKey)
    }

    func save(isEnabled: Bool) {
        defaults.set(isEnabled, forKey: Self.isEnabledKey)
    }
}

internal struct VideoAutoAdvanceRequest: Equatable {
    let sourceID: VideoItem.ID
    let targetID: VideoItem.ID
    let generation: UInt64
}

internal struct VideoAutoAdvanceController {
    private let orderedVideos: [VideoItem]
    private var currentVideoID: VideoItem.ID
    private var generation: UInt64 = 0
    private var pendingRequest: VideoAutoAdvanceRequest?
    private var finishEnabled = true

    init(orderedVideos: [VideoItem], initialVideoID: VideoItem.ID) {
        self.orderedVideos = orderedVideos
        self.currentVideoID = initialVideoID
    }

    mutating func successfulFinish(
        finishedVideoID: VideoItem.ID,
        availableVideoIDs: Set<VideoItem.ID>,
        isPlayable: (VideoItem) -> Bool
    ) -> VideoAutoAdvanceRequest? {
        guard finishEnabled,
              pendingRequest == nil,
              finishedVideoID == currentVideoID,
              let currentIndex = orderedVideos.firstIndex(where: { $0.id == finishedVideoID })
        else { return nil }

        let orderedVideos = orderedVideos
        guard let target = (1..<orderedVideos.count).lazy
            .map({ orderedVideos[(currentIndex + $0) % orderedVideos.count] })
            .first(where: {
                availableVideoIDs.contains($0.id) && isPlayable($0)
            }) else { return nil }

        currentVideoID = target.id
        generation &+= 1
        let request = VideoAutoAdvanceRequest(
            sourceID: finishedVideoID,
            targetID: target.id,
            generation: generation
        )
        pendingRequest = request
        finishEnabled = false
        return request
    }

    mutating func invalidate() {
        generation &+= 1
        pendingRequest = nil
        finishEnabled = false
    }

    func permitsPlayback(
        request: VideoAutoAdvanceRequest,
        currentVideoID: VideoItem.ID
    ) -> Bool {
        request == pendingRequest
            && request.generation == generation
            && currentVideoID == request.targetID
    }

    mutating func beginPlayback(
        request: VideoAutoAdvanceRequest,
        currentVideoID: VideoItem.ID
    ) -> Bool {
        guard permitsPlayback(request: request, currentVideoID: currentVideoID) else {
            return false
        }
        pendingRequest = nil
        finishEnabled = true
        return true
    }

    mutating func notePlaybackStarted(videoID: VideoItem.ID) -> Bool {
        guard videoID == currentVideoID, pendingRequest == nil else {
            return false
        }
        finishEnabled = true
        return true
    }
}

internal enum VideoAutoAdvanceCompletionPolicy {
    static func successfulFinish(
        isEnabled: Bool,
        controller: inout VideoAutoAdvanceController,
        finishedVideoID: VideoItem.ID,
        availableVideoIDs: Set<VideoItem.ID>,
        isPlayable: (VideoItem) -> Bool
    ) -> VideoAutoAdvanceRequest? {
        guard isEnabled else { return nil }
        return controller.successfulFinish(
            finishedVideoID: finishedVideoID,
            availableVideoIDs: availableVideoIDs,
            isPlayable: isPlayable
        )
    }
}

internal enum VideoAutoAdvancePlaybackGate {
    static func permits(
        controller: VideoAutoAdvanceController,
        request: VideoAutoAdvanceRequest,
        currentVideoID: VideoItem.ID,
        loadedURL: URL,
        ownershipAllowed: Bool
    ) -> Bool {
        ownershipAllowed
            && loadedURL == request.targetID
            && controller.permitsPlayback(
                request: request,
                currentVideoID: currentVideoID
            )
    }
}

internal struct VideoPlaybackClockUpdate: Equatable {
    let currentTime: TimeInterval
    let duration: TimeInterval

    static func make(
        currentTime: TimeInterval,
        reportedDuration: TimeInterval,
        previousDuration: TimeInterval,
        metadataDuration: TimeInterval?
    ) -> VideoPlaybackClockUpdate {
        let duration = [reportedDuration, previousDuration, metadataDuration]
            .compactMap { $0 }
            .first { $0.isFinite && $0 > 0 } ?? 0
        let sanitizedCurrentTime = currentTime.isFinite && currentTime >= 0
            ? currentTime
            : 0

        return VideoPlaybackClockUpdate(
            currentTime: duration > 0 ? min(sanitizedCurrentTime, duration) : sanitizedCurrentTime,
            duration: duration
        )
    }
}

internal enum VideoPlaybackRatePolicy {
    static let supportedRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    static let defaultRate: Double = 1

    static func normalized(_ value: Double) -> Double {
        supportedRates.first { $0 == value } ?? defaultRate
    }
}

internal enum VideoPlaybackRatePresentation {
    struct MenuOption: Equatable, Sendable {
        let rate: Double
        let label: String
        let isSelected: Bool
    }

    static let menuRates = VideoPlaybackRatePolicy.supportedRates
    static let minimumTapTarget: Double = 44
    static let controlSpacing: Double = 4

    static func menuOptions(selectedRate: Double) -> [MenuOption] {
        let normalizedSelectedRate = VideoPlaybackRatePolicy.normalized(selectedRate)
        return menuRates.map { rate in
            MenuOption(
                rate: rate,
                label: label(for: rate),
                isSelected: rate == normalizedSelectedRate
            )
        }
    }

    static func label(for rate: Double) -> String {
        switch VideoPlaybackRatePolicy.normalized(rate) {
        case 0.5: "0.5×"
        case 0.75: "0.75×"
        case 1: "1×"
        case 1.25: "1.25×"
        case 1.5: "1.5×"
        case 2: "2×"
        default: "1×"
        }
    }
}

internal final class VideoPlaybackRateStore {
    private static let selectedRateKey = "VideoPlaybackRateStore.selectedRate.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func selectedRate() -> Double {
        guard let number = defaults.object(forKey: Self.selectedRateKey) as? NSNumber else {
            return VideoPlaybackRatePolicy.defaultRate
        }
        return VideoPlaybackRatePolicy.normalized(number.doubleValue)
    }

    func save(rate: Double) {
        defaults.set(VideoPlaybackRatePolicy.normalized(rate), forKey: Self.selectedRateKey)
    }
}

internal enum VideoPlaybackRateApplication {
    static func select(
        _ requestedRate: Double,
        store: VideoPlaybackRateStore,
        apply: (Float) -> Void
    ) -> Double {
        let normalizedRate = VideoPlaybackRatePolicy.normalized(requestedRate)
        store.save(rate: normalizedRate)
        apply(Float(normalizedRate))
        return normalizedRate
    }

    static func restore(
        store: VideoPlaybackRateStore,
        apply: (Float) -> Void
    ) -> Double {
        let rate = store.selectedRate()
        apply(Float(rate))
        return rate
    }
}

internal enum VideoPlaybackResumePolicy {
    static let completionResetWindow: TimeInterval = 2

    static func position(
        storedPosition: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard storedPosition.isFinite, duration.isFinite, duration > 0 else { return nil }

        let clampedPosition = min(max(storedPosition, 0), duration)
        guard clampedPosition > 0,
              duration - clampedPosition > completionResetWindow else { return nil }
        return clampedPosition
    }
}

internal struct VideoPlaybackResumePlan: Equatable {
    let position: TimeInterval
    let shouldResume: Bool
}

internal struct VideoPlaybackHistoryRecord: Equatable, Codable {
    enum State: String, Codable {
        case new
        case viewed
        case completed
    }

    let state: State
    let position: TimeInterval
    let duration: TimeInterval

    static let new = VideoPlaybackHistoryRecord(state: .new, position: 0, duration: 0)

    static func viewed(position: TimeInterval, duration: TimeInterval) -> Self {
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        let safePosition = position.isFinite && position >= 0 ? position : 0
        return Self(
            state: .viewed,
            position: safeDuration > 0 ? min(safePosition, safeDuration) : safePosition,
            duration: safeDuration
        )
    }

    static func completed(duration: TimeInterval) -> Self {
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        return Self(state: .completed, position: safeDuration, duration: safeDuration)
    }

    var progressFraction: Double {
        if state == .completed { return 1 }
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

internal enum VideoAutoAdvanceResumePolicy {
    static func shouldSuppressResume(history: VideoPlaybackHistoryRecord) -> Bool {
        history.state == .completed
    }
}

internal struct VideoListRowPresentation: Equatable {
    let showsNewBadge: Bool
    let thumbnailTime: TimeInterval?
    let progressFraction: Double?

    static func make(history: VideoPlaybackHistoryRecord) -> Self {
        switch history.state {
        case .new:
            return Self(showsNewBadge: true, thumbnailTime: nil, progressFraction: nil)
        case .viewed:
            return Self(
                showsNewBadge: false,
                thumbnailTime: history.position,
                progressFraction: history.progressFraction
            )
        case .completed:
            return Self(
                showsNewBadge: false,
                thumbnailTime: max(history.duration - 0.1, 0),
                progressFraction: 1
            )
        }
    }
}

internal struct VideoPlaybackProgressSession {
    private var didAttemptResume = false
    private var lastPersistedWholeSecond: TimeInterval?

    mutating func resumePosition(
        storedPosition: TimeInterval?,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard !didAttemptResume else { return nil }
        guard duration.isFinite, duration > 0 else { return nil }

        didAttemptResume = true
        guard let storedPosition else { return nil }
        return VideoPlaybackResumePolicy.position(
            storedPosition: storedPosition,
            duration: duration
        )
    }

    mutating func resumePlan(
        history: VideoPlaybackHistoryRecord,
        duration: TimeInterval
    ) -> VideoPlaybackResumePlan? {
        guard !didAttemptResume, duration.isFinite, duration > 0 else { return nil }
        didAttemptResume = true
        if history.state == .completed {
            return VideoPlaybackResumePlan(position: 0, shouldResume: true)
        }
        guard let position = VideoPlaybackResumePolicy.position(
            storedPosition: history.position,
            duration: duration
        ) else { return nil }
        return VideoPlaybackResumePlan(position: position, shouldResume: true)
    }

    mutating func periodicPositionToPersist(
        currentTime: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard currentTime.isFinite,
              duration.isFinite,
              currentTime >= 0,
              duration > 0 else { return nil }

        let clampedCurrentTime = min(currentTime, duration)
        let wholeSecond = floor(clampedCurrentTime)
        guard wholeSecond != lastPersistedWholeSecond else { return nil }

        lastPersistedWholeSecond = wholeSecond
        return clampedCurrentTime
    }
}

internal final class VideoPlaybackProgressStore {
    private static let positionsKey = "VideoPlaybackProgressStore.positions.v1"
    private static let historyKey = "VideoPlaybackProgressStore.history.v2"

    private struct SourceIdentity: Equatable, Codable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let statusChangeSeconds: Int64
        let statusChangeNanoseconds: Int64
    }

    private struct StoredHistory: Codable {
        let source: SourceIdentity
        var record: VideoPlaybackHistoryRecord
        let appBuildIdentifier: String?
        let contentFingerprint: String?
    }

    private struct LegacySourceIdentity: Codable {
        let size: Int
        let modificationTime: TimeInterval
    }

    private struct LegacyStoredHistory: Codable {
        let source: LegacySourceIdentity
        let record: VideoPlaybackHistoryRecord
    }

    private let defaults: UserDefaults
    private let appBuildIdentifier: String

    init(
        defaults: UserDefaults = .standard,
        appBuildIdentifier: String = VideoPlaybackProgressStore.productionAppBuildIdentifier
    ) {
        self.defaults = defaults
        self.appBuildIdentifier = appBuildIdentifier
    }

    static var productionAppBuildIdentifier: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return installationGenerationIdentifier(
            shortVersion: shortVersion,
            buildVersion: buildVersion,
            bundleURL: Bundle.main.bundleURL
        )
    }

    internal static func installationGenerationIdentifier(
        shortVersion: String?,
        buildVersion: String?,
        bundleURL: URL
    ) -> String {
        let trimmedShortVersion = shortVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBuildVersion = buildVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let components = [
            trimmedShortVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown-version",
            trimmedBuildVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "unknown-build",
            bundleURL.standardizedFileURL.path
        ]

        var hasher = SHA256()
        for component in components {
            let bytes = Data(component.utf8)
            var byteCount = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &byteCount) { hasher.update(data: Data($0)) }
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func save(position: TimeInterval, for video: VideoItem) {
        save(position: position, duration: 0, for: video)
    }

    func save(position: TimeInterval, duration: TimeInterval, for video: VideoItem) {
        guard let source = sourceIdentity(for: video) else { return }
        var histories = storedHistories()
        let old = histories[video.fileName]
        if let old, old.source == source, old.record.state == .completed {
            if old.contentFingerprint == nil,
               let fingerprint = contentFingerprint(for: video, source: source) {
                histories[video.fileName] = StoredHistory(
                    source: source,
                    record: old.record,
                    appBuildIdentifier: old.appBuildIdentifier,
                    contentFingerprint: fingerprint
                )
                persist(histories)
            }
            return
        }
        histories[video.fileName] = storedHistory(
            source: source, record: .viewed(position: position, duration: duration),
            video: video, reusing: old
        )
        persist(histories)
    }

    func position(for video: VideoItem) -> TimeInterval? {
        let record = history(for: video)
        return record.state == .new ? nil : record.position
    }

    func history(for video: VideoItem) -> VideoPlaybackHistoryRecord {
        guard let source = sourceIdentity(for: video) else { return .new }
        if var histories = decodedStoredHistories() {
            if let stored = histories[video.fileName] {
                if stored.source == source {
                    if stored.contentFingerprint == nil,
                       let fingerprint = contentFingerprint(for: video, source: source) {
                        histories[video.fileName] = StoredHistory(
                            source: source,
                            record: stored.record,
                            appBuildIdentifier: stored.appBuildIdentifier,
                            contentFingerprint: fingerprint
                        )
                        persist(histories)
                    }
                    return stored.record
                }
                guard stored.appBuildIdentifier != appBuildIdentifier,
                      stored.source.size == source.size,
                      stored.source.modificationSeconds == source.modificationSeconds,
                      stored.source.modificationNanoseconds == source.modificationNanoseconds
                else { return .new }
                guard let fingerprint = contentFingerprint(for: video, source: source) else {
                    return .new
                }
                if let storedFingerprint = stored.contentFingerprint {
                    guard storedFingerprint == fingerprint else { return .new }
                } else {
                    guard stored.source.device == source.device,
                          stored.source.inode == source.inode else { return .new }
                }
                histories[video.fileName] = StoredHistory(
                    source: source,
                    record: stored.record,
                    appBuildIdentifier: appBuildIdentifier,
                    contentFingerprint: fingerprint
                )
                persist(histories)
                return stored.record
            }
            guard let number = defaults.dictionary(forKey: Self.positionsKey)?[video.fileName] as? NSNumber,
                  number.doubleValue.isFinite, number.doubleValue >= 0 else { return .new }
            let migrated = VideoPlaybackHistoryRecord.viewed(position: number.doubleValue, duration: 0)
            histories[video.fileName] = storedHistory(
                source: source, record: migrated, video: video
            )
            persist(histories)
            return migrated
        }

        guard let data = defaults.data(forKey: Self.historyKey),
              let legacy = try? JSONDecoder().decode([String: LegacyStoredHistory].self, from: data)
        else { return .new }
        var histories = migratedLegacyHistories(legacy, beside: video)
        if let migrated = histories[video.fileName]?.record {
            persist(histories)
            return migrated
        }
        if legacy[video.fileName] == nil,
           let number = defaults.dictionary(forKey: Self.positionsKey)?[video.fileName] as? NSNumber,
           number.doubleValue.isFinite, number.doubleValue >= 0 {
            let migrated = VideoPlaybackHistoryRecord.viewed(
                position: number.doubleValue,
                duration: 0
            )
            histories[video.fileName] = storedHistory(
                source: source, record: migrated, video: video
            )
            persist(histories)
            return migrated
        }
        persist(histories)
        return .new
    }

    func markViewed(for video: VideoItem) {
        let history = history(for: video)
        switch history.state {
        case .new:
            save(position: 0, duration: 0, for: video)
        case .viewed:
            return
        case .completed:
            guard let source = sourceIdentity(for: video) else { return }
            var histories = storedHistories()
            histories[video.fileName] = storedHistory(
                source: source,
                record: .viewed(position: 0, duration: history.duration),
                video: video,
                reusing: histories[video.fileName]
            )
            persist(histories)
        }
    }

    func markCompleted(duration: TimeInterval, for video: VideoItem) {
        guard let source = sourceIdentity(for: video) else { return }
        var histories = storedHistories()
        histories[video.fileName] = storedHistory(
            source: source,
            record: .completed(duration: duration),
            video: video,
            reusing: histories[video.fileName]
        )
        persist(histories)
    }

    func removePosition(for video: VideoItem) {
        var positions = defaults.dictionary(forKey: Self.positionsKey) ?? [:]
        positions.removeValue(forKey: video.fileName)
        defaults.set(positions, forKey: Self.positionsKey)
        var histories = storedHistories()
        histories.removeValue(forKey: video.fileName)
        persist(histories)
    }

    private func storedHistories() -> [String: StoredHistory] {
        decodedStoredHistories() ?? [:]
    }

    private func decodedStoredHistories() -> [String: StoredHistory]? {
        guard let data = defaults.data(forKey: Self.historyKey) else { return [:] }
        return try? JSONDecoder().decode([String: StoredHistory].self, from: data)
    }

    private func persist(_ histories: [String: StoredHistory]) {
        guard let data = try? JSONEncoder().encode(histories) else { return }
        defaults.set(data, forKey: Self.historyKey)
    }

    private func migratedLegacyHistories(
        _ legacy: [String: LegacyStoredHistory],
        beside video: VideoItem
    ) -> [String: StoredHistory] {
        let parent = video.url.deletingLastPathComponent().standardizedFileURL
        var histories: [String: StoredHistory] = [:]
        for (fileName, stored) in legacy {
            guard !fileName.isEmpty,
                  fileName != ".", fileName != "..",
                  !fileName.contains("/"), !fileName.contains("\\"),
                  stored.source.size >= 0,
                  stored.source.modificationTime.isFinite,
                  stored.source.modificationTime >= 0 else { continue }
            let url = parent.appendingPathComponent(fileName).standardizedFileURL
            guard url.deletingLastPathComponent() == parent,
                  url.lastPathComponent == fileName,
                  let source = sourceIdentity(for: VideoItem(url: url, duration: nil)),
                  Int64(stored.source.size) == source.size,
                  stored.source.modificationTime == TimeInterval(source.modificationSeconds)
                    + TimeInterval(source.modificationNanoseconds) / 1_000_000_000 else { continue }
            let item = VideoItem(url: url, duration: nil)
            histories[fileName] = storedHistory(
                source: source, record: stored.record, video: item
            )
        }
        return histories
    }

    private func storedHistory(
        source: SourceIdentity,
        record: VideoPlaybackHistoryRecord,
        video: VideoItem,
        reusing old: StoredHistory? = nil
    ) -> StoredHistory {
        let fingerprint = old?.source == source
            ? old?.contentFingerprint ?? contentFingerprint(for: video, source: source)
            : contentFingerprint(for: video, source: source)
        return StoredHistory(
            source: source,
            record: record,
            appBuildIdentifier: appBuildIdentifier,
            contentFingerprint: fingerprint
        )
    }

    private func contentFingerprint(for video: VideoItem, source: SourceIdentity) -> String? {
        guard video.url.isFileURL else { return nil }
        let descriptor = video.url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NOFOLLOW) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }

        func currentIdentity() -> SourceIdentity? {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_nlink == 1 else { return nil }
            return SourceIdentity(
                device: UInt64(metadata.st_dev), inode: UInt64(metadata.st_ino),
                size: metadata.st_size,
                modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
                statusChangeSeconds: Int64(metadata.st_ctimespec.tv_sec),
                statusChangeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
            )
        }
        guard currentIdentity() == source else { return nil }

        let chunkSize: Int64 = 64 * 1024
        let length = source.size
        guard length >= 0 else { return nil }
        let offsets = Set([
            Int64(0),
            max((length - min(chunkSize, length)) / 2, 0),
            max(length - min(chunkSize, length), 0)
        ]).sorted()
        var hasher = SHA256()
        func frame(_ value: Int64) {
            var bigEndian = UInt64(bitPattern: value).bigEndian
            withUnsafeBytes(of: &bigEndian) { hasher.update(data: Data($0)) }
        }
        frame(length)
        for offset in offsets {
            let sampleLength = Int(min(chunkSize, length - offset))
            frame(offset)
            frame(Int64(sampleLength))
            var bytes = [UInt8](repeating: 0, count: sampleLength)
            var readCount = 0
            while readCount < sampleLength {
                let result = bytes.withUnsafeMutableBytes { buffer in
                    pread(
                        descriptor,
                        buffer.baseAddress?.advanced(by: readCount),
                        sampleLength - readCount,
                        off_t(offset) + off_t(readCount)
                    )
                }
                guard result > 0 else { return nil }
                readCount += result
            }
            hasher.update(data: Data(bytes))
        }
        guard currentIdentity() == source else { return nil }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func sourceIdentity(for video: VideoItem) -> SourceIdentity? {
        guard video.url.isFileURL else { return nil }

        var metadata = stat()
        let result: Int32 = video.url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        guard result == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else { return nil }

        return SourceIdentity(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            size: metadata.st_size,
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }
}

struct VideoSeekRequestValidation {
    static func canIssue(
        targetTime: TimeInterval,
        duration: TimeInterval
    ) -> Bool {
        targetTime.isFinite
            && duration.isFinite
            && duration > 0
            && targetTime >= 0
            && targetTime <= duration
    }
}

struct VideoPausePublicationDecision {
    static func shouldPublish(
        isPlaying: Bool,
        hasCurrentOwnership: Bool
    ) -> Bool {
        isPlaying && hasCurrentOwnership
    }
}

struct VideoRemotePlaybackActionExecutor {
    static func perform(
        _ action: VideoRemoteCommandAction,
        play: () -> Bool,
        pause: () -> Bool,
        seek: (TimeInterval) -> Bool
    ) -> Bool {
        switch action {
        case .play:
            return play()
        case .pause:
            return pause()
        case .seek(let target):
            return seek(target)
        }
    }
}

@MainActor
final class PlaybackOwnershipCoordinator: ObservableObject {
    struct MusicPlaybackIntent: Equatable {
        fileprivate let generation: UInt64
    }

    struct VideoPlaybackIntent: Equatable {
        fileprivate let generation: UInt64
    }

    private enum ActiveOwner {
        case music
        case video
    }

    @MainActor
    final class VideoStopRegistration {
        fileprivate let id: UUID
        private weak var coordinator: PlaybackOwnershipCoordinator?

        fileprivate init(id: UUID, coordinator: PlaybackOwnershipCoordinator) {
            self.id = id
            self.coordinator = coordinator
        }

        func unregister() {
            coordinator?.unregisterVideoStop(id: id)
            coordinator = nil
        }

        deinit {
            let registrationID = id
            let playbackCoordinator = coordinator
            Task { @MainActor in
                playbackCoordinator?.unregisterVideoStop(id: registrationID)
            }
        }
    }

    private final class RegisteredVideoStop {
        let id: UUID
        weak var owner: AnyObject?
        let action: (AnyObject) -> Void

        init<Owner: AnyObject>(
            id: UUID,
            owner: Owner,
            action: @escaping (Owner) -> Void
        ) {
            self.id = id
            self.owner = owner
            self.action = { object in
                guard let owner = object as? Owner else { return }
                action(owner)
            }
        }

        func invoke() -> Bool {
            guard let owner else { return false }
            action(owner)
            return true
        }
    }

    private var registeredVideoStop: RegisteredVideoStop?
    private var generation: UInt64 = 0
    private var activeOwner: ActiveOwner?

    func registerVideoStop<Owner: AnyObject>(
        for owner: Owner,
        action: @escaping (Owner) -> Void
    ) -> VideoStopRegistration {
        let id = UUID()
        registeredVideoStop = RegisteredVideoStop(
            id: id,
            owner: owner,
            action: action
        )
        return VideoStopRegistration(id: id, coordinator: self)
    }

    fileprivate func unregisterVideoStop(id: UUID) {
        guard registeredVideoStop?.id == id else { return }
        registeredVideoStop = nil
    }

    @discardableResult
    func musicWillPlay() -> MusicPlaybackIntent {
        generation &+= 1
        activeOwner = .music
        guard registeredVideoStop?.invoke() == true else {
            registeredVideoStop = nil
            return MusicPlaybackIntent(generation: generation)
        }
        return MusicPlaybackIntent(generation: generation)
    }

    func musicPlaybackIsAllowed(_ intent: MusicPlaybackIntent?) -> Bool {
        guard let intent else { return false }
        return activeOwner == .music && intent.generation == generation
    }

    @discardableResult
    func videoPlaybackRequested(stopMusic: () -> Void) -> VideoPlaybackIntent {
        generation &+= 1
        activeOwner = .video
        stopMusic()
        return VideoPlaybackIntent(generation: generation)
    }

    func videoPlaybackIsAllowed(_ intent: VideoPlaybackIntent?) -> Bool {
        guard let intent else { return false }
        return activeOwner == .video && intent.generation == generation
    }

    func videoPausedByUser(_ intent: VideoPlaybackIntent?) {
        guard videoPlaybackIsAllowed(intent) else { return }
        generation &+= 1
        activeOwner = nil
    }
}

struct MusicListTapDecision {
    enum Action: Equatable {
        case startTrack
        case startDifferentTrack
        case pauseCurrent
        case resumeCurrent
    }

    static func action(
        tappedFileName: String,
        currentFileName: String?,
        isPlaying: Bool
    ) -> Action {
        if tappedFileName == currentFileName {
            return isPlaying ? .pauseCurrent : .resumeCurrent
        }
        return currentFileName == nil ? .startTrack : .startDifferentTrack
    }
}

struct SeekPlaybackPlan {
    enum CompletionAction: Equatable {
        case restorePreviousTime
        case play
        case pause
    }

    let shouldResume: Bool

    var engineAutoPlay: Bool { false }

    func completionAction(
        finished: Bool,
        isCurrent: Bool
    ) -> CompletionAction? {
        guard isCurrent else { return nil }
        guard finished else { return .restorePreviousTime }
        return shouldResume ? .play : .pause
    }
}

struct SeekRequestGeneration {
    private var generation = 0

    mutating func issue() -> Int {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    func isCurrent(_ request: Int) -> Bool {
        request == generation
    }
}

final class VideoPlaybackRequestController {
    private var seekRequests = SeekRequestGeneration()

    func issueSeek() -> Int {
        seekRequests.issue()
    }

    func invalidate() {
        seekRequests.invalidate()
    }

    func isCurrent(_ request: Int) -> Bool {
        seekRequests.isCurrent(request)
    }

    func pauseForOwnership(_ pause: () -> Void) {
        seekRequests.invalidate()
        pause()
    }
}

internal struct VideoTimelinePresentation: Equatable {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let currentTimeLabel: String
    let durationLabel: String
    let isSeekEnabled: Bool

    static func make(
        currentTime: TimeInterval,
        duration: TimeInterval
    ) -> VideoTimelinePresentation {
        guard duration.isFinite, duration > 0 else {
            let sanitizedCurrentTime = currentTime.isFinite && currentTime >= 0
                ? currentTime
                : 0
            return VideoTimelinePresentation(
                currentTime: sanitizedCurrentTime,
                duration: 0,
                currentTimeLabel: PlayerScrubLogic.formattedTime(sanitizedCurrentTime),
                durationLabel: "--:--",
                isSeekEnabled: false
            )
        }

        let clampedCurrentTime = currentTime.isFinite
            ? min(max(currentTime, 0), duration)
            : 0
        return VideoTimelinePresentation(
            currentTime: clampedCurrentTime,
            duration: duration,
            currentTimeLabel: PlayerScrubLogic.formattedTime(clampedCurrentTime),
            durationLabel: PlayerScrubLogic.formattedTime(duration),
            isSeekEnabled: true
        )
    }
}

struct PlayerScrubLogic {
    enum TapAction: Equatable {
        case toggleControls
        case togglePlayback
        case ignored
    }

    enum DragRoute: Equatable {
        case scrub
        case adjustVolume
        case ignored
    }

    enum Direction: Equatable {
        case backward
        case forward
    }

    struct Preview: Equatable {
        let direction: Direction
        let relativeSeconds: TimeInterval
        let targetTime: TimeInterval
    }

    static let activationThreshold = 24.0
    static let secondsPerPoint = 0.25

    static func tapAction(tapCount: Int) -> TapAction {
        switch tapCount {
        case 1: .toggleControls
        case 2: .togglePlayback
        default: .ignored
        }
    }

    static func dragRoute(
        startX: Double,
        translationX: Double,
        translationY: Double,
        viewWidth: Double
    ) -> DragRoute {
        guard startX.isFinite,
              translationX.isFinite,
              translationY.isFinite,
              viewWidth.isFinite,
              viewWidth > 0,
              (0...viewWidth).contains(startX) else {
            return .ignored
        }

        if abs(translationX) >= abs(translationY) {
            return .scrub
        }
        return startX >= viewWidth / 2 ? .adjustVolume : .ignored
    }

    static func volume(
        startVolume: Double,
        verticalTranslation: Double,
        viewHeight: Double
    ) -> Double? {
        guard startVolume.isFinite,
              verticalTranslation.isFinite,
              viewHeight.isFinite,
              viewHeight > 0 else {
            return nil
        }
        return min(max(startVolume - verticalTranslation / viewHeight, 0), 1)
    }

    static func shouldFinishScrubbing(
        startTime: TimeInterval?,
        preview: Preview?
    ) -> Bool {
        startTime != nil && preview != nil
    }

    static func preview(
        translation: Double,
        currentTime: TimeInterval,
        duration: TimeInterval,
        isActivated: Bool = false
    ) -> Preview? {
        guard translation.isFinite,
              currentTime.isFinite,
              duration.isFinite,
              duration > 0,
              isActivated || abs(translation) >= activationThreshold else {
            return nil
        }

        let startTime = min(max(currentTime, 0), duration)
        let unclampedTarget = startTime + translation * secondsPerPoint
        let targetTime = min(max(unclampedTarget, 0), duration)

        return Preview(
            direction: translation < 0 ? .backward : .forward,
            relativeSeconds: targetTime - startTime,
            targetTime: targetTime
        )
    }

    static func formattedTime(_ time: TimeInterval) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }

        let totalSeconds = Int(time.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = totalSeconds % 3_600 / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
