import AVFoundation
import Combine
import Darwin
import Foundation
import UIKit

enum MusicPlaybackQueueScope: Equatable, Codable {
    case fullLibrary
    case playlist(UUID)
}

enum MusicPlaylistQueueReconcileReason {
    case membershipMutation
    case authoritativeLibrary
}

struct MusicQueueScopeStore {
    static let key = "MusicPlayback.queueScope.v1"
    static let repairKey = "MusicPlayback.queueScope.repair.v1"
    private static let maximumBytes = 256
    private struct Payload: Codable, Equatable {
        let version: Int
        let kind: String
        let playlistID: UUID?
    }
    let defaults: UserDefaults
    private let writePayload: (Data) -> Bool

    init(defaults: UserDefaults, writePayload: ((Data) -> Bool)? = nil) {
        self.defaults = defaults
        self.writePayload = writePayload ?? { data in
            defaults.set(data, forKey: Self.key)
            return defaults.data(forKey: Self.key) == data
        }
    }

    func loadPlaylistID() -> UUID? {
        guard case let .playlist(id) = pendingRepairScope ?? load(Self.key) else { return nil }
        return id
    }

    var pendingRepairScope: MusicPlaybackQueueScope? { load(Self.repairKey) }

    @discardableResult
    func save(_ scope: MusicPlaybackQueueScope) -> Bool {
        let payload: Payload
        switch scope {
        case .fullLibrary: payload = Payload(version: 1, kind: "fullLibrary", playlistID: nil)
        case let .playlist(id): payload = Payload(version: 1, kind: "playlist", playlistID: id)
        }
        guard let data = try? JSONEncoder().encode(payload), data.count <= Self.maximumBytes else { return false }
        defaults.set(data, forKey: Self.repairKey)
        guard defaults.data(forKey: Self.repairKey) == data else { return false }
        guard writePayload(data), defaults.data(forKey: Self.key) == data,
              (try? JSONDecoder().decode(Payload.self, from: data)) == payload else { return false }
        defaults.removeObject(forKey: Self.repairKey)
        return defaults.data(forKey: Self.repairKey) == nil
    }

    private func load(_ key: String) -> MusicPlaybackQueueScope? {
        guard let data = defaults.data(forKey: key), data.count <= Self.maximumBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data), payload.version == 1 else { return nil }
        switch (payload.kind, payload.playlistID) {
        case ("fullLibrary", nil): return .fullLibrary
        case let ("playlist", id?): return .playlist(id)
        default: return nil
        }
    }
}

enum MusicSleepTimerMode: String, CaseIterable, Equatable {
    case off
    case minutes15
    case minutes30
    case minutes60
    case stopAfterCurrentTrack

    var duration: TimeInterval? {
        switch self {
        case .minutes15: 15 * 60
        case .minutes30: 30 * 60
        case .minutes60: 60 * 60
        case .off, .stopAfterCurrentTrack: nil
        }
    }
}

struct MusicSleepTimerClock {
    let monotonicNow: () -> TimeInterval
    let wallNow: () -> Date

    static let live = MusicSleepTimerClock(
        monotonicNow: { ProcessInfo.processInfo.systemUptime },
        wallNow: Date.init
    )
}

protocol MusicSleepTimerCancellation: AnyObject {
    func cancel()
}

private final class DispatchMusicSleepTimerCancellation: MusicSleepTimerCancellation {
    private var workItem: DispatchWorkItem?

    init(workItem: DispatchWorkItem) {
        self.workItem = workItem
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}

typealias MusicSleepTimerSchedule = @MainActor (
    _ delay: TimeInterval,
    _ action: @escaping @MainActor () -> Void
) -> MusicSleepTimerCancellation

@MainActor
protocol MusicPlaybackStatusObserving: AnyObject {
    func observe(
        _ player: AVPlayer,
        handler: @escaping @MainActor (AVPlayer.TimeControlStatus) -> Void
    )
    func invalidate()
}

@MainActor
private final class LiveMusicPlaybackStatusObserver: MusicPlaybackStatusObserving {
    private var observation: NSKeyValueObservation?

    func observe(
        _ player: AVPlayer,
        handler: @escaping @MainActor (AVPlayer.TimeControlStatus) -> Void
    ) {
        observation = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in handler(status) }
        }
    }

    func invalidate() {
        observation?.invalidate()
        observation = nil
    }
}

@MainActor
private func scheduleLiveMusicSleepTimer(
    after delay: TimeInterval,
    action: @escaping @MainActor () -> Void
) -> MusicSleepTimerCancellation {
    let workItem = DispatchWorkItem {
        MainActor.assumeIsolated { action() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0), execute: workItem)
    return DispatchMusicSleepTimerCancellation(workItem: workItem)
}

enum MusicCompletionMode: String, CaseIterable, Hashable {
    case repeatAll
    case repeatOne
    case stopAtEnd
}

struct MusicCompletionModeStore {
    static let key = "MusicPlayback.completionMode"
    private static let version = 1
    let defaults: UserDefaults

    func load() -> MusicCompletionMode {
        guard let payload = defaults.dictionary(forKey: Self.key),
              payload["version"] as? Int == Self.version,
              let rawValue = payload["mode"] as? String,
              let mode = MusicCompletionMode(rawValue: rawValue) else { return .repeatAll }
        return mode
    }

    func save(_ mode: MusicCompletionMode) {
        defaults.set(["version": Self.version, "mode": mode.rawValue], forKey: Self.key)
    }
}

struct MusicShufflePreferenceStore {
    static let key = "MusicPlayback.shuffle"
    private static let version = 1
    let defaults: UserDefaults

    func load() -> Bool {
        guard let payload = defaults.dictionary(forKey: Self.key),
              payload["version"] as? Int == Self.version,
              let enabled = payload["enabled"] as? Bool else { return false }
        return enabled
    }

    func save(_ enabled: Bool) {
        defaults.set(["version": Self.version, "enabled": enabled], forKey: Self.key)
    }
}

struct MusicShufflePlanner {
    typealias Ordering = ([String]) -> [String]

    private let ordering: Ordering
    private(set) var isEnabled = false
    private var upcoming: [String] = []
    private var history: [String] = []

    init(ordering: @escaping Ordering = { $0.shuffled() }) {
        self.ordering = ordering
    }

    mutating func setEnabled(_ enabled: Bool, currentID: String?, eligibleIDs: [String]) {
        isEnabled = enabled
        upcoming = enabled ? makePlan(currentID: currentID, eligibleIDs: eligibleIDs) : []
        history = []
    }

    mutating func next(currentID: String, eligibleIDs: [String]) -> String? {
        guard isEnabled else { return nil }
        let eligible = Self.unique(eligibleIDs)
        let eligibleSet = Set(eligible)
        upcoming = upcoming.filter { eligibleSet.contains($0) && $0 != currentID }
        if upcoming.isEmpty {
            upcoming = makePlan(currentID: currentID, eligibleIDs: eligible)
        }
        guard !upcoming.isEmpty else { return nil }
        let target = upcoming.removeFirst()
        history.append(currentID)
        return target
    }

    mutating func previous(currentID: String, eligibleIDs: [String]) -> String? {
        guard isEnabled else { return nil }
        let eligible = Set(Self.unique(eligibleIDs))
        history = history.filter { eligible.contains($0) }
        guard let target = history.popLast() else { return nil }
        upcoming.removeAll { $0 == currentID }
        upcoming.insert(currentID, at: 0)
        return target
    }

    mutating func reconcile(currentID: String?, eligibleIDs: [String]) {
        guard isEnabled else { return }
        let eligible = Self.unique(eligibleIDs)
        let eligibleSet = Set(eligible)
        upcoming = upcoming.filter { eligibleSet.contains($0) && $0 != currentID }
        history = history.filter { eligibleSet.contains($0) }
        let represented = Set(upcoming).union(history).union(currentID.map { [$0] } ?? [])
        let additions = eligible.filter { !represented.contains($0) }
        upcoming.append(contentsOf: ordered(additions))
    }

    mutating func recordDirectTransition(from currentID: String?, to targetID: String, eligibleIDs: [String]) {
        guard isEnabled else { return }
        reconcile(currentID: currentID, eligibleIDs: eligibleIDs)
        upcoming.removeAll { $0 == targetID }
        if let currentID, currentID != targetID, Self.unique(eligibleIDs).contains(currentID) {
            history.append(currentID)
        }
    }

    private func makePlan(currentID: String?, eligibleIDs: [String]) -> [String] {
        let candidates = Self.unique(eligibleIDs).filter { $0 != currentID }
        return ordered(candidates)
    }

    private func ordered(_ candidates: [String]) -> [String] {
        let candidateSet = Set(candidates)
        var seen = Set<String>()
        let sanitized = ordering(candidates).filter {
            candidateSet.contains($0) && seen.insert($0).inserted
        }
        return sanitized + candidates.filter { !seen.contains($0) }
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}

enum MusicCompletionDecision: Equatable {
    case advance(to: Int)
    case restartCurrent
    case stop
}

enum MusicInitialQueueLoudnessScheduling {
    case normal
    case deferredUntilForegroundActivation
}

/// Test-visible scheduling telemetry. Production callers use the no-op default.
/// The callback may run on a non-main executor and must therefore be Sendable.
struct MusicLoudnessSchedulingInstrumentation: Sendable {
    let didValidateSource: @Sendable (URL) -> Void
    let willCompleteBookkeeping: @Sendable () -> Void
    let didCompleteBookkeeping: @Sendable () -> Void

    init(
        didValidateSource: @escaping @Sendable (URL) -> Void = { _ in },
        willCompleteBookkeeping: @escaping @Sendable () -> Void = {},
        didCompleteBookkeeping: @escaping @Sendable () -> Void = {}
    ) {
        self.didValidateSource = didValidateSource
        self.willCompleteBookkeeping = willCompleteBookkeeping
        self.didCompleteBookkeeping = didCompleteBookkeeping
    }
}

struct MusicLoudnessLibraryProgress: Equatable {
    let isNormalizing: Bool
    let completedCount: Int
    let totalCount: Int

    static let idle = MusicLoudnessLibraryProgress(
        isNormalizing: false,
        completedCount: 0,
        totalCount: 0
    )
}

struct MusicCompletionPolicy {
    static func decision(
        mode: MusicCompletionMode,
        currentIndex: Int,
        queueCount: Int
    ) -> MusicCompletionDecision {
        guard queueCount > 0,
              currentIndex >= 0,
              currentIndex < queueCount else {
            return .stop
        }
        if mode == .repeatOne { return .restartCurrent }
        if mode == .stopAtEnd { return .stop }
        if queueCount == 1 { return .restartCurrent }
        return .advance(to: (currentIndex + 1) % queueCount)
    }
}

@MainActor
final class MusicPlaybackTimeline: ObservableObject {
    @Published private(set) var currentTime: TimeInterval = 0

    fileprivate func update(currentTime: TimeInterval) {
        self.currentTime = currentTime
    }
}

@MainActor
final class MusicPlaybackTimelineProjection: ObservableObject {
    @Published private(set) var currentTime: TimeInterval

    private let timeline: MusicPlaybackTimeline
    private var observation: AnyCancellable?

    init(timeline: MusicPlaybackTimeline) {
        self.timeline = timeline
        currentTime = timeline.currentTime
    }

    func setActive(_ isActive: Bool) {
        if !isActive {
            observation?.cancel()
            observation = nil
            return
        }
        guard observation == nil else { return }
        publish(timeline.currentTime)
        observation = timeline.$currentTime
            .dropFirst()
            .sink { [weak self] currentTime in
                self?.publish(currentTime)
            }
    }

    private func publish(_ currentTime: TimeInterval) {
        guard self.currentTime != currentTime else { return }
        self.currentTime = currentTime
    }
}

@MainActor
final class MusicPlaybackManager: ObservableObject {
    @Published private(set) var queue: [MusicItem] = []
    @Published private(set) var queueScope: MusicPlaybackQueueScope = .fullLibrary
    @Published private(set) var queueScopePersistenceNeedsRepair = false
    @Published private(set) var currentTrack: MusicItem?
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isPlaying = false
    @Published private(set) var loudnessLibraryProgress = MusicLoudnessLibraryProgress.idle
    var isNormalizingLoudnessLibrary: Bool { loudnessLibraryProgress.isNormalizing }
    var loudnessNormalizationCompletedCount: Int { loudnessLibraryProgress.completedCount }
    var loudnessNormalizationTotalCount: Int { loudnessLibraryProgress.totalCount }
    let timeline = MusicPlaybackTimeline()
    private(set) var currentTime: TimeInterval {
        get { timeline.currentTime }
        set { timeline.update(currentTime: newValue) }
    }
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var completionMode: MusicCompletionMode
    @Published private(set) var isShuffleEnabled: Bool
    let isBluetoothCarLyricsEnabled = true
    @Published private(set) var sleepTimerMode: MusicSleepTimerMode = .off
    @Published private(set) var interruptionNotificationGeneration: UInt64 = 0
    @Published private(set) var routeChangeNotificationGeneration: UInt64 = 0
    @Published private(set) var completionNotificationGeneration: UInt64 = 0
    @Published private(set) var completionTransitionGeneration: UInt64 = 0
    @Published private(set) var trackLoadGeneration: UInt64 = 0
    // Advances after each failure callback finishes, including stale/duplicate callbacks.
    // Completion bookkeeping must not invalidate playback views.
    private let itemFailureCompletionSubject = CurrentValueSubject<UInt64, Never>(0)
    var itemFailureNotificationGeneration: UInt64 { itemFailureCompletionSubject.value }
    var itemFailureCompletionPublisher: AnyPublisher<UInt64, Never> {
        itemFailureCompletionSubject.eraseToAnyPublisher()
    }
    // Advances after the MainActor seek callback finishes, including rejected callbacks.
    // Completion bookkeeping must not invalidate playback views.
    private let seekCompletionSubject = CurrentValueSubject<UInt64, Never>(0)
    var seekCompletionGeneration: UInt64 { seekCompletionSubject.value }
    var seekCompletionPublisher: AnyPublisher<UInt64, Never> {
        seekCompletionSubject.eraseToAnyPublisher()
    }
    // Advances after the MainActor periodic callback finishes, including rejected callbacks.
    // Completion bookkeeping must not invalidate playback views.
    private let periodicCompletionSubject = CurrentValueSubject<UInt64, Never>(0)
    var periodicCompletionGeneration: UInt64 { periodicCompletionSubject.value }
    var periodicCompletionPublisher: AnyPublisher<UInt64, Never> {
        periodicCompletionSubject.eraseToAnyPublisher()
    }
    @Published var playbackErrorMessage: String?

    private enum PersistenceKey {
        static let fileName = "MusicPlayback.lastTrackFileName"
        static let position = "MusicPlayback.lastPositionSeconds"
    }

    private struct SourceFileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    private struct CompletedLoudnessPlayback: Sendable {
        let playbackURL: URL
        let sourceIdentity: SourceFileIdentity
    }

    private struct LoudnessValidationResult: Sendable {
        let sourceURLs: [URL]
        let sourceIdentities: [URL: SourceFileIdentity]
        let completedPlaybacks: [URL: CompletedLoudnessPlayback]
    }

    private struct LoudnessResolutionResult: Sendable {
        let resolution: MusicLoudnessResolution
        let sourceIdentityAfterResolution: SourceFileIdentity?
        let sourceIsReadableRegularFile: Bool
        let derivativeIsReadableRegularFile: Bool
    }

    private struct PendingPlayingConfirmation: Equatable {
        let logicalLocation: String
        let fileName: String
        let sourceURL: URL
        var durableSourceIdentity: MusicFavoriteSourceIdentity?
        let loadedSourceIdentity: SourceFileIdentity?
        let playbackGeneration: UInt64
        let ownershipIntent: PlaybackOwnershipCoordinator.MusicPlaybackIntent

        func matchesStableSource(of other: Self) -> Bool {
            logicalLocation == other.logicalLocation
                && fileName == other.fileName
                && sourceURL == other.sourceURL
                && loadedSourceIdentity == other.loadedSourceIdentity
                && playbackGeneration == other.playbackGeneration
                && ownershipIntent == other.ownershipIntent
        }
    }

    private let player: AVPlayer
    private let defaults: UserDefaults
    private let ownership: PlaybackOwnershipCoordinator
    private let activateAudioSession: @MainActor () throws -> Void
    private let nowPlayingController: MusicNowPlayingControlling
    private let recentlyPlayed: MusicRecentlyPlayedStore
    private let queueScopeStore: MusicQueueScopeStore
    private let playbackStatusObserver: MusicPlaybackStatusObserving
    private let isBluetoothA2DPRoute: () -> Bool
    private let isShuffleTrackReadable: (URL) -> Bool
    private let loudnessCoordinator: MusicLoudnessCacheCoordinator?
    private let loudnessInstrumentation: MusicLoudnessSchedulingInstrumentation
    private let sleepTimerClock: MusicSleepTimerClock
    private let scheduleSleepTimer: MusicSleepTimerSchedule
    private var shufflePlanner: MusicShufflePlanner
    private var timeObserver: Any?
    private var notificationObservers: [NSObjectProtocol] = []
    private var pendingRestoredFileName: String?
    private var pendingRestoredPosition: TimeInterval = 0
    private var didResolveRestoration = false
    private var wasPlayingBeforeInterruption = false
    private var lastPeriodicSave = Date.distantPast
    private var musicPlaybackIntent: PlaybackOwnershipCoordinator.MusicPlaybackIntent?
    private var playbackGeneration: UInt64 = 0
    private var pendingSeekRequestID: UUID?
    private var itemFailureObservation: NSKeyValueObservation?
    private var itemFailedToEndObserver: NSObjectProtocol?
    private var handledItemFailureGeneration: UInt64?
    // An ended item's activation failure is independent of decoding failure.
    // Keep it until a new playback generation; same-item resume needs a fresh
    // callback epoch before it can safely accept timeline callbacks again.
    private var naturalCompletionActivationFailureGeneration: UInt64?
    // A healthy item stopped at EOF still needs a new transport lifecycle on Play.
    private var naturalCompletionExhaustedGeneration: UInt64?
    private var loadedTrackSourceIdentity: SourceFileIdentity?
    private var pendingPlayingConfirmation: PendingPlayingConfirmation?
    private var deferredAudibleConfirmation: PendingPlayingConfirmation?
    private var completedLoudnessPlaybacks: [URL: CompletedLoudnessPlayback] = [:]
    private var failedLoudnessSourceURLs: Set<URL> = []
    private var backgroundLoudnessTasks: [URL: Task<Void, Never>] = [:]
    private var backgroundLoudnessTaskGenerations: [URL: UInt64] = [:]
    private var backgroundLoudnessSourceIdentities: [URL: SourceFileIdentity] = [:]
    private var loudnessWorkGenerations: [URL: UInt64] = [:]
    private var nextLoudnessWorkGeneration: UInt64 = 0
    private var loudnessQueueGeneration: UInt64 = 0
    private var authoritativeLoudnessSourceURLs: Set<URL> = []
    private var loudnessValidationTask: Task<Void, Never>?
    private var validatedLoudnessSourceURLs: Set<URL> = []
    private var validatedLoudnessSourceIdentities: [URL: SourceFileIdentity] = [:]
    private var validatedCompletedLoudnessCount = 0
    private var pendingLoudnessSourceURLs: [URL] = []
    private var pendingLoudnessCursor = 0
    private var pendingLoudnessSourceSet: Set<URL> = []
    private var isLibraryLoudnessNormalizationAllowed = true
    private var isInitialQueueLoudnessSchedulingDeferred: Bool
    private var sleepTimerGeneration: UInt64 = 0
    private var sleepTimerMonotonicDeadline: TimeInterval?
    private var sleepTimerWallDeadline: Date?
    private var sleepTimerCancellation: MusicSleepTimerCancellation?
    private var fullLibraryQueue: [MusicItem] = []
    private var retainedOutOfQueueCurrent = false
    private var pendingRestoredPlaylistID: UUID?
    private var pendingQueueScopePersistence: MusicPlaybackQueueScope?

    init(
        player: AVPlayer = AVPlayer(),
        defaults: UserDefaults = .standard,
        ownership: PlaybackOwnershipCoordinator? = nil,
        loudnessCoordinator: MusicLoudnessCacheCoordinator? = nil,
        initialQueueLoudnessScheduling: MusicInitialQueueLoudnessScheduling = .normal,
        loudnessInstrumentation: MusicLoudnessSchedulingInstrumentation = .init(),
        activateAudioSession: @escaping @MainActor () throws -> Void = AudioSessionManager.activateForPlayback,
        nowPlayingController: MusicNowPlayingControlling? = nil,
        queueScopeStore: MusicQueueScopeStore? = nil,
        recentlyPlayed: MusicRecentlyPlayedStore? = nil,
        playbackStatusObserver: MusicPlaybackStatusObserving? = nil,
        shuffleOrdering: @escaping MusicShufflePlanner.Ordering = { $0.shuffled() },
        isShuffleTrackReadable: ((URL) -> Bool)? = nil,
        sleepTimerClock: MusicSleepTimerClock = .live,
        scheduleSleepTimer: @escaping MusicSleepTimerSchedule = scheduleLiveMusicSleepTimer(after:action:),
        isBluetoothA2DPRoute: @escaping () -> Bool = {
            AVAudioSession.sharedInstance().currentRoute.outputs.contains {
                $0.portType == .bluetoothA2DP
            }
        }
    ) {
        let resolvedNowPlayingController = nowPlayingController ?? MediaPlayerMusicNowPlayingController()
        self.player = player
        self.defaults = defaults
        self.ownership = ownership ?? PlaybackOwnershipCoordinator()
        self.activateAudioSession = activateAudioSession
        self.nowPlayingController = resolvedNowPlayingController
        let resolvedQueueScopeStore = queueScopeStore ?? MusicQueueScopeStore(defaults: defaults)
        self.queueScopeStore = resolvedQueueScopeStore
        self.recentlyPlayed = recentlyPlayed ?? MusicRecentlyPlayedStore(defaults: defaults)
        self.playbackStatusObserver = playbackStatusObserver ?? LiveMusicPlaybackStatusObserver()
        self.isBluetoothA2DPRoute = isBluetoothA2DPRoute
        self.isShuffleTrackReadable = isShuffleTrackReadable ?? Self.isReadableRegularFile(at:)
        self.loudnessCoordinator = loudnessCoordinator
        self.loudnessInstrumentation = loudnessInstrumentation
        self.sleepTimerClock = sleepTimerClock
        self.scheduleSleepTimer = scheduleSleepTimer
        self.shufflePlanner = MusicShufflePlanner(ordering: shuffleOrdering)
        self.isInitialQueueLoudnessSchedulingDeferred = initialQueueLoudnessScheduling
            == .deferredUntilForegroundActivation
        self.completionMode = MusicCompletionModeStore(defaults: defaults).load()
        self.isShuffleEnabled = MusicShufflePreferenceStore(defaults: defaults).load()
        self.shufflePlanner.setEnabled(isShuffleEnabled, currentID: nil, eligibleIDs: [])
        resolvedNowPlayingController.clear()
        resolvedNowPlayingController.registerRemoteCommands { [weak self] command in
            self?.handleRemoteCommand(command) ?? .commandFailed
        }
        // The manager, rather than AVPlayer's default pause action, owns list looping.
        player.actionAtItemEnd = .none
        pendingRestoredFileName = defaults.string(forKey: PersistenceKey.fileName)
        pendingRestoredPosition = defaults.double(forKey: PersistenceKey.position)
        pendingRestoredPlaylistID = resolvedQueueScopeStore.loadPlaylistID()
        pendingQueueScopePersistence = resolvedQueueScopeStore.pendingRepairScope
        queueScopePersistenceNeedsRepair = pendingQueueScopePersistence != nil
        installObservers()
    }

    func setCompletionMode(_ mode: MusicCompletionMode) {
        completionMode = mode
        MusicCompletionModeStore(defaults: defaults).save(mode)
    }

    func setShuffleEnabled(_ enabled: Bool) {
        guard isShuffleEnabled != enabled else { return }
        isShuffleEnabled = enabled
        shufflePlanner.setEnabled(
            enabled,
            currentID: currentTrack?.fileName,
            eligibleIDs: eligibleShuffleIDs
        )
        MusicShufflePreferenceStore(defaults: defaults).save(enabled)
    }

    func activateDeferredLoudnessNormalizationForForeground() {
        guard isInitialQueueLoudnessSchedulingDeferred else { return }
        isInitialQueueLoudnessSchedulingDeferred = false
        beginAuthoritativeLoudnessValidation(
            for: Array(Set(fullLibraryQueue.map { $0.url.standardizedFileURL }))
        )
    }

    deinit {
        itemFailureObservation?.invalidate()
        if let itemFailedToEndObserver {
            NotificationCenter.default.removeObserver(itemFailedToEndObserver)
        }
        sleepTimerCancellation?.cancel()
        loudnessValidationTask?.cancel()
        backgroundLoudnessTasks.values.forEach { $0.cancel() }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func syncLibrary(_ library: [MusicItem], snapshot: MusicFavoritesReconciliationSnapshot) {
        if snapshot.isAuthoritative {
            updateQueue(library)
            return
        }
        // Cheap rows are playable candidates, not deletion or identity evidence.
        // Refresh-start and scan failures carry no candidates and change nothing.
        guard !library.isEmpty else { return }
        var candidatesByID: [String: MusicItem] = [:]
        for candidate in fullLibraryQueue + library where candidatesByID[candidate.id] == nil {
            candidatesByID[candidate.id] = candidate
        }
        // Keep the loaded track's URL, certification and details until authority
        // arrives, including when cheap rows omit it or reuse its logical ID.
        if let currentTrack { candidatesByID[currentTrack.id] = currentTrack }
        let candidates = candidatesByID.values.sorted {
            let order = $0.fileName.localizedStandardCompare($1.fileName)
            return order == .orderedSame ? $0.fileName < $1.fileName : order == .orderedAscending
        }
        fullLibraryQueue = candidates
        guard pendingRestoredPlaylistID == nil, queueScope == .fullLibrary else { return }

        if currentTrack == nil, !didResolveRestoration,
           let pendingName = pendingRestoredFileName,
           candidates.contains(where: { $0.fileName == pendingName }) {
            // Full-library restoration can load immediately and remains paused.
            applyQueue(candidates)
            return
        }
        // Do not run applyQueue's source replacement/deletion checks on provisional
        // input, or consume an unresolved restoration whose row has not arrived.
        queue = candidates
        currentIndex = currentTrack.flatMap { current in
            candidates.firstIndex(where: { $0.id == current.id })
        }
        retainedOutOfQueueCurrent = currentTrack != nil && currentIndex == nil
        shufflePlanner.reconcile(currentID: currentTrack?.fileName, eligibleIDs: eligibleShuffleIDs)
    }

    // Explicit queue input. Scan publications must enter through syncLibrary.
    func updateQueue(_ newQueue: [MusicItem]) {
        fullLibraryQueue = newQueue
        retryQueueScopePersistenceIfNeeded()
        reconcileLoudnessWork(with: newQueue)
        if pendingRestoredPlaylistID != nil {
            return
        }
        guard queueScope == .fullLibrary else {
            return
        }
        applyQueue(newQueue)
    }

    func playFromLibrary(_ track: MusicItem, library: [MusicItem]) {
        fullLibraryQueue = library
        queueScope = .fullLibrary
        persistQueueScope()
        applyQueue(library)
        play(track)
    }

    func playFromPlaylist(_ track: MusicItem, playlistID: UUID, items: [MusicItem]) {
        queueScope = .playlist(playlistID)
        persistQueueScope()
        applyQueue(items)
        play(track)
    }

    func reconcilePlaylistQueue(
        id: UUID,
        items: [MusicItem],
        reason: MusicPlaylistQueueReconcileReason = .membershipMutation
    ) {
        guard queueScope == .playlist(id) else { return }
        let retainedCurrent = currentTrack
        if reason == .authoritativeLibrary, let retainedCurrent,
           !fullLibraryQueue.contains(where: {
               $0.url.standardizedFileURL == retainedCurrent.url.standardizedFileURL
                   && $0.favoriteSourceIdentity == retainedCurrent.favoriteSourceIdentity
           }) {
            detachCurrentItem()
            setNoCurrentTrack(clearPersistence: true)
            applyQueue(items)
            return
        }
        applyQueuePreservingRemovedCurrent(items, retainedCurrent: retainedCurrent)
    }

    func playlistDeleted(id: UUID) {
        guard queueScope == .playlist(id) else { return }
        queueScope = .fullLibrary
        persistQueueScope()
        applyQueue(fullLibraryQueue)
    }

    func resolvePendingQueueScope(playlists: MusicPlaylistStore, library: [MusicItem]) {
        if fullLibraryQueue != library { updateQueue(library) }
        guard let id = pendingRestoredPlaylistID else { return }
        pendingRestoredPlaylistID = nil
        guard let playlist = playlists.playlist(id: id) else {
            queueScope = .fullLibrary
            persistQueueScope()
            applyQueue(library)
            return
        }
        let items = playlists.songs(in: id, library: library)
        queueScope = .playlist(id)
        persistQueueScope()
        if let pendingName = pendingRestoredFileName,
           playlist.members.contains(where: { $0.fileName == pendingName }),
           !items.contains(where: { $0.fileName == pendingName }) {
            // The logical member still exists but its authenticated identity is temporarily
            // unavailable. Keep the restoration pending without inventing an item or URL.
            queue = items
            currentTrack = nil
            currentIndex = nil
            return
        }
        if let pendingName = pendingRestoredFileName,
           !playlist.members.contains(where: { $0.fileName == pendingName }) {
            didResolveRestoration = true
            pendingRestoredFileName = nil
            pendingRestoredPosition = 0
            defaults.removeObject(forKey: PersistenceKey.fileName)
            defaults.removeObject(forKey: PersistenceKey.position)
        }
        applyQueue(items)
    }

    private func persistQueueScope() {
        if queueScopeStore.save(queueScope) {
            pendingQueueScopePersistence = nil
            queueScopePersistenceNeedsRepair = false
        } else {
            pendingQueueScopePersistence = queueScope
            queueScopePersistenceNeedsRepair = true
        }
    }

    private func retryQueueScopePersistenceIfNeeded() {
        guard let pending = pendingQueueScopePersistence else { return }
        if queueScopeStore.save(pending) {
            pendingQueueScopePersistence = nil
            queueScopePersistenceNeedsRepair = false
        }
    }

    func retryQueueScopePersistence() {
        retryQueueScopePersistenceIfNeeded()
    }

    private func applyQueuePreservingRemovedCurrent(_ items: [MusicItem], retainedCurrent: MusicItem?) {
        guard let retainedCurrent,
              !items.contains(where: { $0.fileName == retainedCurrent.fileName }) else {
            applyQueue(items)
            return
        }
        // The AVPlayer item remains loaded; only future traversal targets are replaced.
        queue = items
        currentTrack = retainedCurrent
        currentIndex = nil
        retainedOutOfQueueCurrent = true
        shufflePlanner.reconcile(currentID: nil, eligibleIDs: eligibleShuffleIDs)
    }

    private func applyQueue(_ newQueue: [MusicItem]) {
        let priorFileName = currentTrack?.fileName
        let priorURL = currentTrack?.url.standardizedFileURL
        let priorLoadedTrackSourceIdentity = loadedTrackSourceIdentity
        let hadLoadedItem = player.currentItem != nil
        queue = newQueue
        if isShuffleEnabled {
            shufflePlanner.reconcile(currentID: priorFileName, eligibleIDs: eligibleShuffleIDs)
        }
        defer { scheduleLoudnessNormalizationForCurrentQueue() }

        if let priorFileName,
           let index = newQueue.firstIndex(where: { $0.fileName == priorFileName }) {
            let replacementURL = newQueue[index].url.standardizedFileURL
            if replacementURL != priorURL {
                cancelSleepTimer()
                resetShufflePlan(anchoredAt: newQueue[index].fileName)
                detachCurrentItem()
                isPlaying = false
                wasPlayingBeforeInterruption = false
                musicPlaybackIntent = nil
                currentIndex = index
                currentTrack = newQueue[index]
                currentTime = 0
                duration = validDuration(newQueue[index].duration)
                savePlaybackState()
                syncNowPlaying(isPlaying: false)
                return
            }
            let replacementSourceIdentity = Self.sourceFileIdentity(at: replacementURL)
            if hadLoadedItem,
               (replacementSourceIdentity == nil
                    || priorLoadedTrackSourceIdentity == nil
                    || replacementSourceIdentity != priorLoadedTrackSourceIdentity) {
                cancelSleepTimer()
                resetShufflePlan(anchoredAt: newQueue[index].fileName)
                detachCurrentItem()
                isPlaying = false
                wasPlayingBeforeInterruption = false
                musicPlaybackIntent = nil
                currentIndex = index
                currentTrack = newQueue[index]
                loadTrack(at: index, initialPosition: 0, playbackURL: replacementURL)
                isPlaying = false
                savePlaybackState()
                syncNowPlaying(isPlaying: false)
                return
            }
            currentIndex = index
            retainedOutOfQueueCurrent = false
            currentTrack = newQueue[index]
            duration = validDuration(newQueue[index].duration)
            reconcileAudiblePlaybackConfirmationAfterEnrichment()
            syncNowPlaying()
            return
        }

        if currentTrack != nil {
            resetShufflePlan(anchoredAt: nil)
            detachCurrentItem()
            setNoCurrentTrack(clearPersistence: true)
        }

        guard !didResolveRestoration, !newQueue.isEmpty else { return }
        didResolveRestoration = true
        guard let fileName = pendingRestoredFileName,
              let index = newQueue.firstIndex(where: { $0.fileName == fileName }) else {
            setNoCurrentTrack(clearPersistence: true)
            return
        }

        loadTrack(at: index, initialPosition: pendingRestoredPosition)
        // A restored track is intentionally ready but paused so a cold launch is silent.
        isPlaying = false
        savePlaybackState()
    }

    func play(_ track: MusicItem) {
        guard let index = queue.firstIndex(where: { $0.fileName == track.fileName }) else { return }
        switch MusicListTapDecision.action(
            tappedFileName: track.fileName,
            currentFileName: currentTrack?.fileName,
            isPlaying: isPlaying
        ) {
        case .pauseCurrent:
            pause()
        case .resumeCurrent:
            play()
        case .startTrack, .startDifferentTrack:
            if isShuffleEnabled {
                shufflePlanner.recordDirectTransition(
                    from: currentTrack?.fileName,
                    to: track.fileName,
                    eligibleIDs: eligibleShuffleIDs
                )
            }
            switchTrack(to: index, shouldPlay: true)
        }
    }

    func play() {
        resumePlayback(retryFailedItem: true)
    }

    private func resumePlayback(retryFailedItem: Bool) {
        guard let currentTrack, let item = player.currentItem else { return }
        let hasItemFailure = item.status == .failed
            || handledItemFailureGeneration == playbackGeneration
        let shouldRestartAfterCompletion = !hasItemFailure
            && (naturalCompletionActivationFailureGeneration == playbackGeneration
                || naturalCompletionExhaustedGeneration == playbackGeneration)
        let needsReplacement = hasItemFailure || shouldRestartAfterCompletion
        // Interruption recovery may resume a healthy item, but never retry failure.
        guard retryFailedItem || !needsReplacement else { return }
        do {
            try activateAudioSession()
            if needsReplacement {
                // Only successful explicit recovery retires the exhausted item's
                // callback epoch. Keep decode retries at their saved position.
                installItem(
                    for: currentTrack,
                    initialPosition: shouldRestartAfterCompletion ? 0 : currentTime
                )
                savePlaybackState()
            }
            startPlaybackAfterAudioSessionActivation()
            startBackgroundLoudnessNormalization(for: currentTrack.url)
        } catch {
            player.pause()
            invalidateAudiblePlaybackConfirmation()
            isPlaying = false
            playbackErrorMessage = "无法开始播放，请稍后重试。"
            savePlaybackState()
            if ownership.musicPlaybackIsAllowed(musicPlaybackIntent) {
                syncNowPlaying()
            }
        }
    }

    func pause() {
        if !ownership.musicPlaybackIsAllowed(musicPlaybackIntent) {
            cancelSleepTimer()
        }
        player.pause()
        invalidateAudiblePlaybackConfirmation()
        isPlaying = false
        wasPlayingBeforeInterruption = false
        savePlaybackState()
        syncNowPlaying()
    }

    func prepareForDeletion(_ track: MusicItem) {
        // Called after a successful unlink. That explicit result remains authority
        // even if the following library refresh fails; never retain it as fallback.
        let deletedURL = track.url.standardizedFileURL
        fullLibraryQueue.removeAll { $0.url.standardizedFileURL == deletedURL }
        defer {
            if queue.contains(where: { $0.url.standardizedFileURL == deletedURL }) {
                applyQueuePreservingRemovedCurrent(
                    queue.filter { $0.url.standardizedFileURL != deletedURL },
                    retainedCurrent: currentTrack
                )
            }
        }
        guard currentTrack?.url.standardizedFileURL == track.url.standardizedFileURL else {
            return
        }

        detachCurrentItem()
        wasPlayingBeforeInterruption = false
        musicPlaybackIntent = nil
        pendingRestoredFileName = nil
        pendingRestoredPosition = 0
        setNoCurrentTrack(clearPersistence: true)
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if retainedOutOfQueueCurrent {
            if isShuffleEnabled {
                guard let currentID = currentTrack?.fileName,
                      let targetID = shufflePlanner.next(currentID: currentID, eligibleIDs: eligibleShuffleIDs),
                      let targetIndex = queue.firstIndex(where: { $0.fileName == targetID }) else { return }
                transitionToTrack(at: targetIndex)
            } else { transitionToTrack(at: 0) }
            return
        }
        if isShuffleEnabled {
            guard let currentID = currentTrack?.fileName,
                  let targetID = shufflePlanner.next(currentID: currentID, eligibleIDs: eligibleShuffleIDs),
                  targetID != currentID,
                  let targetIndex = queue.firstIndex(where: { $0.fileName == targetID }) else { return }
            transitionToTrack(at: targetIndex)
            return
        }
        let nextIndex = ((currentIndex ?? -1) + 1) % queue.count
        transitionToTrack(at: nextIndex)
    }

    func previous() {
        guard !queue.isEmpty else { return }
        if retainedOutOfQueueCurrent {
            if isShuffleEnabled {
                guard let currentID = currentTrack?.fileName,
                      let targetID = shufflePlanner.previous(currentID: currentID, eligibleIDs: eligibleShuffleIDs),
                      let targetIndex = queue.firstIndex(where: { $0.fileName == targetID }) else { return }
                transitionToTrack(at: targetIndex)
            } else { transitionToTrack(at: queue.count - 1) }
            return
        }
        if isShuffleEnabled {
            guard let currentID = currentTrack?.fileName,
                  let targetID = shufflePlanner.previous(currentID: currentID, eligibleIDs: eligibleShuffleIDs),
                  let targetIndex = queue.firstIndex(where: { $0.fileName == targetID }) else { return }
            transitionToTrack(at: targetIndex)
            return
        }
        let index = currentIndex ?? 0
        let previousIndex = (index - 1 + queue.count) % queue.count
        transitionToTrack(at: previousIndex)
    }

    func seek(to seconds: TimeInterval) {
        guard let currentTrack, seconds.isFinite else { return }
        let clamped = Self.clampedSeekPosition(seconds, duration: duration)
        if naturalCompletionExhaustedGeneration == playbackGeneration {
            // Retire the exhausted epoch, preserving the confirmed position until
            // the precise seek below completes, including a request for zero.
            installItem(for: currentTrack, initialPosition: nil)
        }
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero,
            completionHandler: seekCompletionCallback(to: clamped)
        )
    }

    func seekCompletionCallback(to seconds: TimeInterval) -> @Sendable (Bool) -> Void {
        let generation = playbackGeneration
        // Each callback represents a new request, even for the same target.
        let requestID = UUID()
        pendingSeekRequestID = requestID
        return { [weak self] finished in
            Task { @MainActor in
                defer {
                    if let self {
                        self.seekCompletionSubject.send(self.seekCompletionGeneration &+ 1)
                    }
                }
                guard let self, self.playbackGeneration == generation,
                      self.pendingSeekRequestID == requestID else { return }
                self.pendingSeekRequestID = nil
                guard finished else { return }
                guard self.naturalCompletionActivationFailureGeneration != generation else { return }
                guard self.naturalCompletionExhaustedGeneration != generation else { return }
                guard self.handledItemFailureGeneration != generation else { return }
                self.currentTime = seconds
                self.savePlaybackState()
                self.syncNowPlaying()
            }
        }
    }

    func setSleepTimerMode(_ mode: MusicSleepTimerMode) {
        if mode == .off {
            cancelSleepTimer()
            return
        }
        guard currentTrack != nil else {
            cancelSleepTimer()
            return
        }
        guard mode != sleepTimerMode else { return }

        sleepTimerGeneration &+= 1
        sleepTimerCancellation?.cancel()
        sleepTimerCancellation = nil
        sleepTimerMode = mode
        guard let duration = mode.duration else {
            sleepTimerMonotonicDeadline = nil
            sleepTimerWallDeadline = nil
            return
        }
        sleepTimerMonotonicDeadline = sleepTimerClock.monotonicNow() + duration
        sleepTimerWallDeadline = sleepTimerClock.wallNow().addingTimeInterval(duration)
        scheduleCurrentSleepTimer(after: duration)
    }

    func cancelSleepTimer() {
        guard sleepTimerMode != .off || sleepTimerCancellation != nil else { return }
        sleepTimerGeneration &+= 1
        sleepTimerCancellation?.cancel()
        sleepTimerCancellation = nil
        sleepTimerMonotonicDeadline = nil
        sleepTimerWallDeadline = nil
        sleepTimerMode = .off
    }

    func sleepTimerRemainingTime() -> TimeInterval? {
        guard sleepTimerMode.duration != nil,
              let monotonicDeadline = sleepTimerMonotonicDeadline,
              let wallDeadline = sleepTimerWallDeadline else { return nil }
        return max(0, min(
            monotonicDeadline - sleepTimerClock.monotonicNow(),
            wallDeadline.timeIntervalSince(sleepTimerClock.wallNow())
        ))
    }

    func reconcileSleepTimerDeadline() {
        guard sleepTimerMode.duration != nil else { return }
        handleSleepTimerDeadline(generation: sleepTimerGeneration)
    }

    private func scheduleCurrentSleepTimer(after delay: TimeInterval) {
        let generation = sleepTimerGeneration
        sleepTimerCancellation = scheduleSleepTimer(delay) { [weak self] in
            self?.handleSleepTimerDeadline(generation: generation)
        }
    }

    private func handleSleepTimerDeadline(generation: UInt64) {
        guard generation == sleepTimerGeneration,
              sleepTimerMode.duration != nil,
              let remaining = sleepTimerRemainingTime() else { return }
        if remaining > 0 {
            sleepTimerCancellation?.cancel()
            scheduleCurrentSleepTimer(after: remaining)
            return
        }

        cancelSleepTimer()
        guard currentTrack != nil else { return }
        guard ownership.musicPlaybackIsAllowed(musicPlaybackIntent) else {
            pause()
            return
        }
        player.pause()
        invalidateAudiblePlaybackConfirmation()
        isPlaying = false
        wasPlayingBeforeInterruption = false
        savePlaybackState()
        syncNowPlaying(isPlaying: false)
    }

    func periodicTimeCallback() -> @Sendable (CMTime) -> Void {
        let generation = playbackGeneration
        return { [weak self] time in
            Task { @MainActor in
                defer {
                    if let self {
                        self.periodicCompletionSubject.send(self.periodicCompletionGeneration &+ 1)
                    }
                }
                guard let self, self.playbackGeneration == generation else { return }
                guard self.pendingSeekRequestID == nil else { return }
                guard self.naturalCompletionActivationFailureGeneration != generation else { return }
                guard self.naturalCompletionExhaustedGeneration != generation else { return }
                let seconds = time.seconds
                guard seconds.isFinite, seconds >= 0 else { return }
                self.currentTime = seconds
                if Date().timeIntervalSince(self.lastPeriodicSave) >= 5 {
                    self.savePlaybackState()
                }
                // A queued pulse from a failed item must not republish music after
                // the failure handler has cleared its intent (possibly under video).
                if self.handledItemFailureGeneration != generation {
                    self.syncNowPlaying()
                }
            }
        }
    }

    static func clampedSeekPosition(_ position: TimeInterval, duration: TimeInterval) -> TimeInterval {
        guard position.isFinite else { return 0 }
        let lowerBoundedPosition = max(position, 0)
        guard duration.isFinite, duration > 0 else { return lowerBoundedPosition }
        return min(lowerBoundedPosition, duration)
    }

    func savePlaybackState() {
        lastPeriodicSave = Date()
        guard let fileName = currentTrack?.fileName else {
            defaults.removeObject(forKey: PersistenceKey.fileName)
            defaults.removeObject(forKey: PersistenceKey.position)
            return
        }
        defaults.set(fileName, forKey: PersistenceKey.fileName)
        defaults.set(max(currentTime, 0), forKey: PersistenceKey.position)
    }

    private func switchTrack(to index: Int, shouldPlay: Bool) {
        guard queue.indices.contains(index) else { return }
        savePlaybackState()
        loadTrack(at: index, initialPosition: 0)
        savePlaybackState()
        if shouldPlay {
            play()
        }
    }

    private func transitionToTrack(at index: Int) {
        guard queue.indices.contains(index) else { return }
        switchTrack(to: index, shouldPlay: true)
    }

    private var eligibleShuffleIDs: [String] {
        queue.filter { isShuffleTrackReadable($0.url.standardizedFileURL) }.map(\.fileName)
    }

    private func resetShufflePlan(anchoredAt currentID: String?) {
        guard isShuffleEnabled else { return }
        shufflePlanner.setEnabled(true, currentID: currentID, eligibleIDs: eligibleShuffleIDs)
    }

    private func handleRemoteCommand(_ command: MusicRemoteCommand) -> MusicRemoteCommandResult {
        switch command {
        case .play:
            guard currentTrack != nil, !isPlaying else { return .commandFailed }
            play()
            return pendingPlayingConfirmation != nil || isPlaying ? .success : .commandFailed
        case .pause:
            guard currentTrack != nil, isPlaying else { return .commandFailed }
            pause()
            return .success
        case .togglePlayPause:
            guard currentTrack != nil else { return .commandFailed }
            if isPlaying {
                pause()
                return .success
            }
            play()
            return pendingPlayingConfirmation != nil || isPlaying ? .success : .commandFailed
        case .nextTrack:
            guard currentTrack != nil, !queue.isEmpty else { return .commandFailed }
            if retainedOutOfQueueCurrent {
                return isShuffleEnabled
                    ? switchShuffleTrackFromRemoteCommand(forward: true)
                    : switchTrackFromRemoteCommand(to: 0)
            }
            if isShuffleEnabled {
                return switchShuffleTrackFromRemoteCommand(forward: true)
            }
            let nextIndex = ((currentIndex ?? -1) + 1) % queue.count
            return switchTrackFromRemoteCommand(to: nextIndex)
        case .previousTrack:
            guard currentTrack != nil, !queue.isEmpty else { return .commandFailed }
            if retainedOutOfQueueCurrent {
                return isShuffleEnabled
                    ? switchShuffleTrackFromRemoteCommand(forward: false)
                    : switchTrackFromRemoteCommand(to: queue.count - 1)
            }
            if isShuffleEnabled {
                return switchShuffleTrackFromRemoteCommand(forward: false)
            }
            let index = currentIndex ?? 0
            let previousIndex = (index - 1 + queue.count) % queue.count
            return switchTrackFromRemoteCommand(to: previousIndex)
        case .skipBackward, .skipForward:
            return .commandFailed
        case let .changePlaybackPosition(position):
            guard currentTrack != nil, position.isFinite else { return .commandFailed }
            seek(to: position)
            return .success
        }
    }

    private func switchTrackFromRemoteCommand(to index: Int) -> MusicRemoteCommandResult {
        do {
            try activateAudioSession()
        } catch {
            playbackErrorMessage = "无法开始播放，请稍后重试。"
            return .commandFailed
        }

        guard queue.indices.contains(index) else { return .commandFailed }
        switchTrack(to: index, shouldPlay: false)
        startPlaybackAfterAudioSessionActivation()
        if let currentTrack {
            startBackgroundLoudnessNormalization(for: currentTrack.url)
        }
        return .success
    }

    private func switchShuffleTrackFromRemoteCommand(forward: Bool) -> MusicRemoteCommandResult {
        do {
            try activateAudioSession()
        } catch {
            playbackErrorMessage = "无法开始播放，请稍后重试。"
            return .commandFailed
        }

        guard let currentID = currentTrack?.fileName else { return .commandFailed }
        let targetID = forward
            ? shufflePlanner.next(currentID: currentID, eligibleIDs: eligibleShuffleIDs)
            : shufflePlanner.previous(currentID: currentID, eligibleIDs: eligibleShuffleIDs)
        guard let targetID,
              targetID != currentID,
              let targetIndex = queue.firstIndex(where: { $0.fileName == targetID }) else {
            return .commandFailed
        }
        switchTrack(to: targetIndex, shouldPlay: false)
        startPlaybackAfterAudioSessionActivation()
        if let currentTrack {
            startBackgroundLoudnessNormalization(for: currentTrack.url)
        }
        return .success
    }

    private func startPlaybackAfterAudioSessionActivation() {
        guard let currentTrack else { return }
        invalidateAudiblePlaybackConfirmation()
        let intent = ownership.musicWillPlay()
        musicPlaybackIntent = intent
        pendingPlayingConfirmation = PendingPlayingConfirmation(
            logicalLocation: currentTrack.url.deletingLastPathComponent().lastPathComponent,
            fileName: currentTrack.fileName,
            sourceURL: currentTrack.url.standardizedFileURL,
            durableSourceIdentity: currentTrack.favoriteSourceIdentity,
            loadedSourceIdentity: loadedTrackSourceIdentity,
            playbackGeneration: playbackGeneration,
            ownershipIntent: intent
        )
        let confirmation = pendingPlayingConfirmation
        playbackStatusObserver.observe(player) { [weak self] status in
            guard let confirmation else { return }
            self?.handlePlaybackStatus(status, confirmation: confirmation)
        }
        player.play()
        isPlaying = true
        playbackErrorMessage = nil
        syncNowPlaying(isPlaying: true, claimOwnership: true)
    }

    private func handlePlaybackStatus(
        _ status: AVPlayer.TimeControlStatus,
        confirmation: PendingPlayingConfirmation
    ) {
        guard status == .playing,
              let pending = pendingPlayingConfirmation,
              pending.matchesStableSource(of: confirmation) else { return }
        guard ownership.musicPlaybackIsAllowed(pending.ownershipIntent) else {
            pause()
            return
        }
        guard confirmationMatchesCurrentSource(pending) else { return }
        pendingPlayingConfirmation = nil
        playbackStatusObserver.invalidate()
        guard let currentTrack else { return }
        if currentTrack.favoriteSourceIdentity?.isValid == true {
            recentlyPlayed.record(currentTrack)
        } else {
            deferredAudibleConfirmation = pending
        }
    }

    private func invalidateAudiblePlaybackConfirmation() {
        pendingPlayingConfirmation = nil
        deferredAudibleConfirmation = nil
        playbackStatusObserver.invalidate()
    }

    private func reconcileAudiblePlaybackConfirmationAfterEnrichment() {
        guard let currentTrack else {
            invalidateAudiblePlaybackConfirmation()
            return
        }

        if var pending = pendingPlayingConfirmation {
            guard confirmationMatchesCurrentSource(pending) else {
                invalidateAudiblePlaybackConfirmation()
                return
            }
            if pending.durableSourceIdentity == nil,
               let identity = currentTrack.favoriteSourceIdentity, identity.isValid {
                pending.durableSourceIdentity = identity
                pendingPlayingConfirmation = pending
            } else if let priorIdentity = pending.durableSourceIdentity,
                      priorIdentity != currentTrack.favoriteSourceIdentity {
                invalidateAudiblePlaybackConfirmation()
                return
            }
        }

        guard let marker = deferredAudibleConfirmation else { return }
        guard confirmationMatchesCurrentSource(marker), marker.durableSourceIdentity == nil else {
            invalidateAudiblePlaybackConfirmation()
            return
        }
        guard currentTrack.favoriteSourceIdentity?.isValid == true else { return }
        deferredAudibleConfirmation = nil
        recentlyPlayed.record(currentTrack)
    }

    private func confirmationMatchesCurrentSource(_ confirmation: PendingPlayingConfirmation) -> Bool {
        guard let currentTrack,
              confirmation.playbackGeneration == playbackGeneration,
              confirmation.logicalLocation == currentTrack.url.deletingLastPathComponent().lastPathComponent,
              confirmation.fileName == currentTrack.fileName,
              confirmation.sourceURL == currentTrack.url.standardizedFileURL,
              confirmation.loadedSourceIdentity == loadedTrackSourceIdentity,
              confirmation.loadedSourceIdentity == Self.sourceFileIdentity(at: confirmation.sourceURL),
              confirmation.ownershipIntent == musicPlaybackIntent,
              ownership.musicPlaybackIsAllowed(confirmation.ownershipIntent) else { return false }
        return confirmation.durableSourceIdentity == nil
            || confirmation.durableSourceIdentity == currentTrack.favoriteSourceIdentity
    }

    private func loadTrack(
        at index: Int,
        initialPosition: TimeInterval,
        playbackURL: URL? = nil
    ) {
        guard queue.indices.contains(index) else { return }
        retainedOutOfQueueCurrent = false
        let track = queue[index]
        currentIndex = index
        currentTrack = track
        installItem(for: track, initialPosition: initialPosition, playbackURL: playbackURL)
    }

    // Item lifecycle only: retrying a retained current track must not alter the queue.
    // A nil position preserves confirmed time and leaves seeking to the caller.
    private func installItem(
        for track: MusicItem,
        initialPosition: TimeInterval?,
        playbackURL: URL? = nil
    ) {
        invalidatePlaybackGeneration()
        let sourceURL = track.url.standardizedFileURL
        loadedTrackSourceIdentity = Self.sourceFileIdentity(at: sourceURL)
        var selectedPlaybackURL = playbackURL
        if selectedPlaybackURL == nil {
            selectedPlaybackURL = validatedCompletedPlaybackURL(for: sourceURL)
        }
        duration = validDuration(track.duration)
        let clampedPosition = initialPosition.map { Self.clampedSeekPosition($0, duration: duration) }
        if let clampedPosition {
            currentTime = clampedPosition
        }
        let item = AVPlayerItem(url: selectedPlaybackURL ?? track.url)
        player.replaceCurrentItem(with: item)
        observeItemFailures(item)
        installPeriodicTimeObserver()
        if let clampedPosition, clampedPosition > 0 {
            player.seek(to: CMTime(seconds: clampedPosition, preferredTimescale: 600))
        }
        syncNowPlaying(isPlaying: false)
        trackLoadGeneration &+= 1
    }

    private func setNoCurrentTrack(clearPersistence: Bool) {
        cancelSleepTimer()
        retainedOutOfQueueCurrent = false
        loadedTrackSourceIdentity = nil
        currentTrack = nil
        currentIndex = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        nowPlayingController.clear()
        if clearPersistence {
            savePlaybackState()
        }
    }

    private func validDuration(_ value: TimeInterval?) -> TimeInterval {
        guard let value, value.isFinite, value > 0 else { return 0 }
        return value
    }

    private func syncNowPlaying(isPlaying: Bool? = nil, claimOwnership: Bool = false) {
        guard let snapshot = NowPlayingSnapshot.make(
            track: currentTrack,
            duration: duration,
            elapsedTime: currentTime,
            isPlaying: isPlaying ?? self.isPlaying,
            bluetoothLyricsEnabled: isBluetoothCarLyricsEnabled,
            isBluetoothA2DPRoute: isBluetoothA2DPRoute()
        ) else { return }
        // Local item installation and timeline callbacks must not claim presentation
        // ownership. An unowned registry still accepts paused restore/EOF state.
        if claimOwnership {
            nowPlayingController.publish(snapshot)
        } else {
            nowPlayingController.publishIfUnownedOrOwned(snapshot)
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, let finishedItem = notification.object as? AVPlayerItem else { return }
                self.completionNotificationGeneration &+= 1
                guard
                      finishedItem === self.player.currentItem,
                      self.naturalCompletionExhaustedGeneration != self.playbackGeneration,
                      self.isPlaying,
                      self.ownership.musicPlaybackIsAllowed(self.musicPlaybackIntent) else { return }
                self.advanceAfterFinishing()
                self.completionTransitionGeneration &+= 1
            }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                self.handleInterruption(notification)
                self.interruptionNotificationGeneration &+= 1
            }
        })
        notificationObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }
                self.handleRouteChange(notification)
                self.routeChangeNotificationGeneration &+= 1
            }
        })
        notificationObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDidEnterBackground() }
        })
        notificationObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWillEnterForeground() }
        })
    }

    private func handleDidEnterBackground() {
        savePlaybackState()
        isLibraryLoudnessNormalizationAllowed = false
        loudnessQueueGeneration &+= 1
        loudnessValidationTask?.cancel()
        loudnessValidationTask = nil
        for (sourceURL, task) in backgroundLoudnessTasks {
            invalidateLoudnessWorkGeneration(for: sourceURL)
            task.cancel()
        }
        publishLoudnessProgress(MusicLoudnessLibraryProgress(
            isNormalizing: false,
            completedCount: loudnessNormalizationCompletedCount,
            totalCount: loudnessNormalizationTotalCount
        ))
    }

    private func handleWillEnterForeground() {
        guard !isLibraryLoudnessNormalizationAllowed else { return }
        isLibraryLoudnessNormalizationAllowed = true
        beginAuthoritativeLoudnessValidation(
            for: Array(Set(fullLibraryQueue.map { $0.url.standardizedFileURL }))
        )
    }

    private func installPeriodicTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main,
            using: periodicTimeCallback()
        )
    }

    private func invalidatePlaybackGeneration() {
        playbackGeneration &+= 1
        pendingSeekRequestID = nil
        itemFailureObservation?.invalidate()
        itemFailureObservation = nil
        if let itemFailedToEndObserver {
            NotificationCenter.default.removeObserver(itemFailedToEndObserver)
            self.itemFailedToEndObserver = nil
        }
        handledItemFailureGeneration = nil
        naturalCompletionActivationFailureGeneration = nil
        naturalCompletionExhaustedGeneration = nil
        invalidateAudiblePlaybackConfirmation()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func detachCurrentItem() {
        invalidatePlaybackGeneration()
        retainedOutOfQueueCurrent = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedTrackSourceIdentity = nil
    }

    private func observeItemFailures(_ item: AVPlayerItem) {
        let generation = playbackGeneration
        // Independent of first-playing confirmation: decoding can fail later too.
        itemFailureObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                self?.handleItemFailure(item, playbackGeneration: generation)
            }
        }
        itemFailedToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak item] _ in
            Task { @MainActor in
                guard let item else { return }
                self?.handleItemFailure(item, playbackGeneration: generation)
            }
        }
    }

    private func handleItemFailure(_ item: AVPlayerItem, playbackGeneration generation: UInt64) {
        defer { itemFailureCompletionSubject.send(itemFailureNotificationGeneration &+ 1) }
        // Validate after the actor hop, before touching playback or ownership state.
        guard item === player.currentItem,
              generation == playbackGeneration,
              handledItemFailureGeneration != generation else { return }
        handledItemFailureGeneration = generation
        pendingSeekRequestID = nil
        let ownsMusic = ownership.musicPlaybackIsAllowed(musicPlaybackIntent)
        player.pause()
        invalidateAudiblePlaybackConfirmation()
        wasPlayingBeforeInterruption = false
        isPlaying = false
        playbackErrorMessage = "音频播放失败，请选择其他歌曲。"
        if ownsMusic { syncNowPlaying(isPlaying: false) }
        musicPlaybackIntent = nil
    }

    private func startBackgroundLoudnessNormalization(for sourceURL: URL) {
        guard isLibraryLoudnessNormalizationAllowed,
              let loudnessCoordinator else { return }
        let standardizedSourceURL = sourceURL.standardizedFileURL
        guard authoritativeLoudnessSourceURLs.contains(standardizedSourceURL),
              let expectedSourceIdentity = validatedLoudnessSourceIdentities[standardizedSourceURL],
              !failedLoudnessSourceURLs.contains(standardizedSourceURL),
              completedLoudnessPlaybacks[standardizedSourceURL] == nil,
              backgroundLoudnessTasks.isEmpty else { return }
        let workGeneration = loudnessWorkGeneration(for: standardizedSourceURL)

        backgroundLoudnessSourceIdentities[standardizedSourceURL] = expectedSourceIdentity
        backgroundLoudnessTaskGenerations[standardizedSourceURL] = workGeneration
        backgroundLoudnessTasks[standardizedSourceURL] = Task.detached(priority: .utility) { [weak self, loudnessCoordinator] in
            let resolution = await loudnessCoordinator.resolve(sourceURL: standardizedSourceURL)
            let identityAfterResolution = Self.sourceFileIdentity(at: standardizedSourceURL)
            let resolvedURL = resolution.playbackURL.standardizedFileURL
            let result = LoudnessResolutionResult(
                resolution: resolution,
                sourceIdentityAfterResolution: identityAfterResolution,
                sourceIsReadableRegularFile: Self.isReadableRegularFile(at: standardizedSourceURL),
                derivativeIsReadableRegularFile: resolvedURL != standardizedSourceURL
                    && Self.isReadableRegularFile(at: resolvedURL)
            )
            await self?.finishBackgroundLoudnessNormalization(
                for: standardizedSourceURL,
                expectedSourceIdentity: expectedSourceIdentity,
                workGeneration: workGeneration,
                result: result,
                wasCancelled: Task.isCancelled
            )
        }
    }

    private func finishBackgroundLoudnessNormalization(
        for sourceURL: URL,
        expectedSourceIdentity: SourceFileIdentity,
        workGeneration: UInt64,
        result: LoudnessResolutionResult,
        wasCancelled: Bool
    ) {
        loudnessInstrumentation.willCompleteBookkeeping()
        defer { loudnessInstrumentation.didCompleteBookkeeping() }

        if backgroundLoudnessTaskGenerations[sourceURL] == workGeneration {
            backgroundLoudnessTasks.removeValue(forKey: sourceURL)
            backgroundLoudnessTaskGenerations.removeValue(forKey: sourceURL)
            backgroundLoudnessSourceIdentities.removeValue(forKey: sourceURL)
        }

        let stillCurrent = authoritativeLoudnessSourceURLs.contains(sourceURL)
            && loudnessWorkGenerations[sourceURL] == workGeneration
            && validatedLoudnessSourceURLs.contains(sourceURL)
        if stillCurrent, !wasCancelled,
           result.sourceIdentityAfterResolution == expectedSourceIdentity {
            let resolvedURL = result.resolution.playbackURL.standardizedFileURL
            switch result.resolution.status {
            case .generated where result.derivativeIsReadableRegularFile,
                 .reused where result.derivativeIsReadableRegularFile:
                let wasAlreadyCompleted = completedLoudnessPlaybacks[sourceURL] != nil
                completedLoudnessPlaybacks[sourceURL] = CompletedLoudnessPlayback(
                    playbackURL: resolvedURL,
                    sourceIdentity: expectedSourceIdentity
                )
                if !wasAlreadyCompleted { validatedCompletedLoudnessCount += 1 }
                failedLoudnessSourceURLs.remove(sourceURL)
            default:
                completedLoudnessPlaybacks.removeValue(forKey: sourceURL)
                failedLoudnessSourceURLs.insert(sourceURL)
            }
        } else if stillCurrent, !wasCancelled,
                  result.sourceIsReadableRegularFile,
                  let replacementIdentity = result.sourceIdentityAfterResolution {
            // The URL is still authoritative but its bytes changed during resolve.
            // Reject the stale derivative and enqueue exactly this replacement.
            invalidateLoudnessWorkGeneration(for: sourceURL)
            completedLoudnessPlaybacks.removeValue(forKey: sourceURL)
            failedLoudnessSourceURLs.remove(sourceURL)
            validatedLoudnessSourceIdentities[sourceURL] = replacementIdentity
            enqueuePendingLoudnessSource(sourceURL)
        }
        scheduleLoudnessNormalizationForCurrentQueue()
    }

    private func scheduleLoudnessNormalizationForCurrentQueue() {
        guard !isInitialQueueLoudnessSchedulingDeferred else {
            publishLoudnessProgress(.idle)
            return
        }
        guard loudnessCoordinator != nil else {
            publishLoudnessProgress(.idle)
            return
        }
        guard loudnessValidationTask == nil else {
            publishLoudnessProgress(MusicLoudnessLibraryProgress(
                isNormalizing: isLibraryLoudnessNormalizationAllowed
                    && validatedCompletedLoudnessCount < authoritativeLoudnessSourceURLs.count,
                completedCount: validatedCompletedLoudnessCount,
                totalCount: validatedLoudnessSourceURLs.count
            ))
            return
        }
        guard isLibraryLoudnessNormalizationAllowed else {
            publishLoudnessProgress(MusicLoudnessLibraryProgress(
                isNormalizing: false,
                completedCount: validatedCompletedLoudnessCount,
                totalCount: validatedLoudnessSourceURLs.count
            ))
            return
        }
        guard backgroundLoudnessTasks.isEmpty else {
            publishLoudnessProgress(MusicLoudnessLibraryProgress(
                isNormalizing: true,
                completedCount: validatedCompletedLoudnessCount,
                totalCount: validatedLoudnessSourceURLs.count
            ))
            return
        }
        while pendingLoudnessCursor < pendingLoudnessSourceURLs.count {
            let sourceURL = pendingLoudnessSourceURLs[pendingLoudnessCursor]
            pendingLoudnessCursor += 1
            pendingLoudnessSourceSet.remove(sourceURL)
            guard authoritativeLoudnessSourceURLs.contains(sourceURL),
                  validatedLoudnessSourceURLs.contains(sourceURL),
                  completedLoudnessPlaybacks[sourceURL] == nil,
                  !failedLoudnessSourceURLs.contains(sourceURL) else { continue }
            startBackgroundLoudnessNormalization(for: sourceURL)
            publishLoudnessProgress(MusicLoudnessLibraryProgress(
                isNormalizing: true,
                completedCount: validatedCompletedLoudnessCount,
                totalCount: validatedLoudnessSourceURLs.count
            ))
            return
        }
        publishLoudnessProgress(MusicLoudnessLibraryProgress(
            isNormalizing: false,
            completedCount: validatedCompletedLoudnessCount,
            totalCount: validatedLoudnessSourceURLs.count
        ))
    }

    private func enqueuePendingLoudnessSource(_ sourceURL: URL) {
        guard !pendingLoudnessSourceSet.contains(sourceURL) else { return }
        pendingLoudnessSourceURLs.append(sourceURL)
        pendingLoudnessSourceSet.insert(sourceURL)
    }

    private func publishLoudnessProgress(_ progress: MusicLoudnessLibraryProgress) {
        guard progress != loudnessLibraryProgress else { return }
        loudnessLibraryProgress = progress
    }

    private func reconcileLoudnessWork(with newQueue: [MusicItem]) {
        let currentSourceURLs = Set(newQueue.map { $0.url.standardizedFileURL })
        authoritativeLoudnessSourceURLs = currentSourceURLs
        validatedLoudnessSourceURLs.formIntersection(currentSourceURLs)
        validatedLoudnessSourceIdentities = validatedLoudnessSourceIdentities.filter {
            currentSourceURLs.contains($0.key)
        }
        completedLoudnessPlaybacks = completedLoudnessPlaybacks.filter {
            currentSourceURLs.contains($0.key)
        }
        validatedCompletedLoudnessCount = completedLoudnessPlaybacks.count
        pendingLoudnessSourceURLs = []
        pendingLoudnessSourceSet = []
        pendingLoudnessCursor = 0
        failedLoudnessSourceURLs.subtract(currentSourceURLs)
        let removedSourceURLs = Set(loudnessWorkGenerations.keys).subtracting(currentSourceURLs)
        for sourceURL in removedSourceURLs {
            loudnessWorkGenerations.removeValue(forKey: sourceURL)
            backgroundLoudnessTasks[sourceURL]?.cancel()
            completedLoudnessPlaybacks.removeValue(forKey: sourceURL)
            failedLoudnessSourceURLs.remove(sourceURL)
        }
        for sourceURL in currentSourceURLs where loudnessWorkGenerations[sourceURL] == nil {
            nextLoudnessWorkGeneration &+= 1
            loudnessWorkGenerations[sourceURL] = nextLoudnessWorkGeneration
        }
        beginAuthoritativeLoudnessValidation(for: Array(currentSourceURLs))
    }

    private func beginAuthoritativeLoudnessValidation(for sourceURLs: [URL]) {
        loudnessQueueGeneration &+= 1
        let queueGeneration = loudnessQueueGeneration
        loudnessValidationTask?.cancel()
        guard loudnessCoordinator != nil, !isInitialQueueLoudnessSchedulingDeferred else {
            validatedLoudnessSourceURLs = []
            validatedLoudnessSourceIdentities = [:]
            validatedCompletedLoudnessCount = 0
            pendingLoudnessSourceURLs = []
            pendingLoudnessCursor = 0
            pendingLoudnessSourceSet = []
            return
        }
        let completedSnapshot = completedLoudnessPlaybacks
        let instrumentation = loudnessInstrumentation
        loudnessValidationTask = Task.detached(priority: .utility) { [weak self] in
            var identities: [URL: SourceFileIdentity] = [:]
            var completed: [URL: CompletedLoudnessPlayback] = [:]
            for sourceURL in sourceURLs {
                guard !Task.isCancelled else { return }
                instrumentation.didValidateSource(sourceURL)
                guard let identity = Self.sourceFileIdentity(at: sourceURL),
                      Self.isReadableRegularFile(at: sourceURL) else { continue }
                identities[sourceURL] = identity
                if let candidate = completedSnapshot[sourceURL],
                   candidate.sourceIdentity == identity,
                   candidate.playbackURL.standardizedFileURL != sourceURL,
                   Self.isReadableRegularFile(at: candidate.playbackURL) {
                    completed[sourceURL] = candidate
                }
            }
            guard !Task.isCancelled else { return }
            let sortedSources = identities.keys.sorted { $0.path < $1.path }
            await self?.applyAuthoritativeLoudnessValidation(
                LoudnessValidationResult(
                    sourceURLs: sortedSources,
                    sourceIdentities: identities,
                    completedPlaybacks: completed
                ),
                queueGeneration: queueGeneration
            )
        }
    }

    private func applyAuthoritativeLoudnessValidation(
        _ result: LoudnessValidationResult,
        queueGeneration: UInt64
    ) {
        guard queueGeneration == loudnessQueueGeneration else { return }
        loudnessValidationTask = nil
        let newSourceSet = Set(result.sourceURLs)
        for (sourceURL, activeIdentity) in backgroundLoudnessSourceIdentities
        where result.sourceIdentities[sourceURL] != activeIdentity {
            invalidateLoudnessWorkGeneration(for: sourceURL)
            backgroundLoudnessTasks[sourceURL]?.cancel()
        }
        var mergedCompletedPlaybacks = result.completedPlaybacks
        for (sourceURL, completed) in completedLoudnessPlaybacks
        where newSourceSet.contains(sourceURL)
            && result.sourceIdentities[sourceURL] == completed.sourceIdentity {
            mergedCompletedPlaybacks[sourceURL] = completed
        }
        validatedLoudnessSourceURLs = newSourceSet
        validatedLoudnessSourceIdentities = result.sourceIdentities
        completedLoudnessPlaybacks = mergedCompletedPlaybacks
        validatedCompletedLoudnessCount = mergedCompletedPlaybacks.count
        failedLoudnessSourceURLs.formIntersection(newSourceSet)
        pendingLoudnessSourceURLs = result.sourceURLs.filter {
            mergedCompletedPlaybacks[$0] == nil
                && backgroundLoudnessTaskGenerations[$0] != loudnessWorkGenerations[$0]
                && !failedLoudnessSourceURLs.contains($0)
        }
        pendingLoudnessCursor = 0
        pendingLoudnessSourceSet = Set(pendingLoudnessSourceURLs)
        scheduleLoudnessNormalizationForCurrentQueue()
    }

    private func loudnessWorkGeneration(for sourceURL: URL) -> UInt64 {
        if let generation = loudnessWorkGenerations[sourceURL] {
            return generation
        }
        nextLoudnessWorkGeneration &+= 1
        loudnessWorkGenerations[sourceURL] = nextLoudnessWorkGeneration
        return nextLoudnessWorkGeneration
    }

    private func invalidateLoudnessWorkGeneration(for sourceURL: URL) {
        guard loudnessWorkGenerations[sourceURL] != nil else { return }
        nextLoudnessWorkGeneration &+= 1
        loudnessWorkGenerations[sourceURL] = nextLoudnessWorkGeneration
    }

    private func validatedCompletedPlaybackURL(for standardizedSourceURL: URL) -> URL? {
        guard let completed = completedLoudnessPlaybacks[standardizedSourceURL],
              Self.sourceFileIdentity(at: standardizedSourceURL) == completed.sourceIdentity,
              completed.playbackURL.standardizedFileURL != standardizedSourceURL,
              Self.isReadableRegularFile(at: completed.playbackURL) else {
            if completedLoudnessPlaybacks.removeValue(forKey: standardizedSourceURL) != nil,
               validatedLoudnessSourceURLs.contains(standardizedSourceURL) {
                validatedCompletedLoudnessCount = max(0, validatedCompletedLoudnessCount - 1)
            }
            return nil
        }
        return completed.playbackURL
    }

    nonisolated private static func sourceFileIdentity(
        at standardizedSourceURL: URL
    ) -> SourceFileIdentity? {
        guard standardizedSourceURL.isFileURL else { return nil }
        var fileStatus = stat()
        guard lstat(standardizedSourceURL.path, &fileStatus) == 0,
              fileStatus.st_mode & S_IFMT == S_IFREG else { return nil }
        return SourceFileIdentity(
            device: fileStatus.st_dev,
            inode: fileStatus.st_ino,
            size: fileStatus.st_size,
            modificationSeconds: Int64(fileStatus.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(fileStatus.st_mtimespec.tv_nsec)
        )
    }

    nonisolated private static func isReadableRegularFile(at url: URL) -> Bool {
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path),
              FileManager.default.isReadableFile(atPath: url.path),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }

    private func advanceAfterFinishing() {
        if retainedOutOfQueueCurrent {
            let shouldStopForSleepTimer = sleepTimerMode == .stopAfterCurrentTrack
            if shouldStopForSleepTimer { cancelSleepTimer() }
            guard !shouldStopForSleepTimer,
                  completionMode != .stopAtEnd,
                  !queue.isEmpty else {
                stopMusicCoherently()
                return
            }
            guard activateForNaturalCompletion() else { return }
            let targetIndex: Int
            if isShuffleEnabled {
                guard let currentID = currentTrack?.fileName,
                      let targetID = shufflePlanner.next(currentID: currentID, eligibleIDs: eligibleShuffleIDs),
                      let index = queue.firstIndex(where: { $0.fileName == targetID }) else {
                    stopMusicCoherently()
                    return
                }
                targetIndex = index
            } else {
                targetIndex = 0
            }
            retainedOutOfQueueCurrent = false
            switchTrack(to: targetIndex, shouldPlay: false)
            startPlaybackAfterAudioSessionActivation()
            if let currentTrack { startBackgroundLoudnessNormalization(for: currentTrack.url) }
            return
        }
        guard let currentIndex else { return }
        if sleepTimerMode == .stopAfterCurrentTrack {
            cancelSleepTimer()
            stopMusicCoherently()
            return
        }
        switch MusicCompletionPolicy.decision(
            mode: completionMode,
            currentIndex: currentIndex,
            queueCount: queue.count
        ) {
        case let .advance(nextIndex):
            guard activateForNaturalCompletion() else { return }
            let targetIndex: Int
            if isShuffleEnabled {
                guard let currentID = currentTrack?.fileName else { return }
                let eligibleIDs = eligibleShuffleIDs
                guard let targetID = shufflePlanner.next(
                        currentID: currentID,
                        eligibleIDs: eligibleIDs
                      ) else {
                    if eligibleIDs.contains(currentID) {
                        currentTime = 0
                        player.seek(to: .zero)
                        savePlaybackState()
                        startPlaybackAfterAudioSessionActivation()
                    } else {
                        stopMusicCoherently()
                    }
                    return
                }
                guard let shuffledIndex = queue.firstIndex(where: { $0.fileName == targetID }) else { return }
                targetIndex = shuffledIndex
            } else {
                targetIndex = nextIndex
            }
            switchTrack(to: targetIndex, shouldPlay: false)
            startPlaybackAfterAudioSessionActivation()
            if let currentTrack { startBackgroundLoudnessNormalization(for: currentTrack.url) }
        case .restartCurrent:
            guard activateForNaturalCompletion() else { return }
            currentTime = 0
            player.seek(to: .zero)
            savePlaybackState()
            startPlaybackAfterAudioSessionActivation()
        case .stop:
            stopMusicCoherently()
        }
    }

    private func stopMusicCoherently() {
        naturalCompletionExhaustedGeneration = playbackGeneration
        player.pause()
        invalidateAudiblePlaybackConfirmation()
        isPlaying = false
        wasPlayingBeforeInterruption = false
        musicPlaybackIntent = nil
        savePlaybackState()
        syncNowPlaying(isPlaying: false)
    }

    private func activateForNaturalCompletion() -> Bool {
        do {
            try activateAudioSession()
            return true
        } catch {
            // Preserve the exhausted source and queue; only stop its playback intent.
            naturalCompletionActivationFailureGeneration = playbackGeneration
            player.pause()
            invalidateAudiblePlaybackConfirmation()
            isPlaying = false
            wasPlayingBeforeInterruption = false
            playbackErrorMessage = "无法开始播放，请稍后重试。"
            savePlaybackState()
            if ownership.musicPlaybackIsAllowed(musicPlaybackIntent) {
                syncNowPlaying(isPlaying: false)
            }
            musicPlaybackIntent = nil
            return false
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }

        switch type {
        case .began:
            wasPlayingBeforeInterruption = isPlaying
            player.pause()
            invalidateAudiblePlaybackConfirmation()
            isPlaying = false
            savePlaybackState()
            if ownership.musicPlaybackIsAllowed(musicPlaybackIntent) {
                syncNowPlaying()
            }
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if wasPlayingBeforeInterruption && options.contains(.shouldResume) {
                resumePlayback(retryFailedItem: false)
            }
            wasPlayingBeforeInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        if ownership.musicPlaybackIsAllowed(musicPlaybackIntent) {
            syncNowPlaying()
        }
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        if rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) == .oldDeviceUnavailable {
            // Route loss cancels automatic resume even when an interruption already paused music.
            wasPlayingBeforeInterruption = false
            if isPlaying {
                pause()
            }
        }
    }
}
