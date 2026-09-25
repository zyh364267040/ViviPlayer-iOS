import Combine
import Foundation
import MediaPlayer

enum MusicRemoteCommandExecutorDecision: Equatable {
    case runDirectly
    case synchronizeToMainExecutor
    case failClosed
}

struct MusicRemoteCommandExecutorBridge {
    static func decision(
        isMainThread: Bool,
        isMainExecutor: Bool
    ) -> MusicRemoteCommandExecutorDecision {
        if isMainExecutor {
            return .runDirectly
        }
        if !isMainThread {
            return .synchronizeToMainExecutor
        }
        return .failClosed
    }
}

private final class MusicMainExecutorDetector: @unchecked Sendable {
    private let key = DispatchSpecificKey<UInt8>()
    private let value: UInt8 = 1

    init() {
        DispatchQueue.main.setSpecific(key: key, value: value)
    }

    var isCurrentExecutor: Bool {
        DispatchQueue.getSpecific(key: key) == value
    }
}

private final class MusicNowPlayingOwnerLifetime: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var isActive = true

    func invalidate() {
        lock.lock()
        isActive = false
        lock.unlock()
    }

    func performIfActive<Result>(
        fallback: Result,
        _ operation: () -> Result
    ) -> Result {
        lock.lock()
        guard isActive else {
            lock.unlock()
            return fallback
        }
        defer { lock.unlock() }
        return operation()
    }
}

enum MusicRemoteCommand: Equatable, Sendable {
    case play
    case pause
    case togglePlayPause
    case nextTrack
    case previousTrack
    case skipBackward
    case skipForward
    case changePlaybackPosition(TimeInterval)
}

enum VideoRemoteCommandAction: Equatable, Sendable {
    case play
    case pause
    case seek(TimeInterval)
}

struct VideoRemoteCommandDecision {
    static func action(
        for command: MusicRemoteCommand,
        currentTime: TimeInterval,
        duration: TimeInterval,
        isPlaying: Bool
    ) -> VideoRemoteCommandAction? {
        switch command {
        case .play:
            return isPlaying ? nil : .play
        case .pause:
            return isPlaying ? .pause : nil
        case .togglePlayPause:
            return isPlaying ? .pause : .play
        case .nextTrack, .previousTrack:
            return nil
        case .changePlaybackPosition(let targetTime):
            guard VideoSeekRequestValidation.canIssue(
                targetTime: targetTime,
                duration: duration
            ) else { return nil }
            return .seek(targetTime)
        case .skipBackward, .skipForward:
            guard currentTime.isFinite, duration.isFinite, duration > 0 else { return nil }
            let sanitizedCurrentTime = min(max(currentTime, 0), duration)
            return command == .skipBackward
                ? .seek(max(sanitizedCurrentTime - VideoPlaybackSkipPolicy.interval, 0))
                : .seek(min(sanitizedCurrentTime + VideoPlaybackSkipPolicy.interval, duration))
        }
    }
}

enum MusicRemoteCommandResult: Equatable, Sendable {
    case success
    case commandFailed
}

enum NowPlayingCommandProfile: Equatable, Sendable {
    case music
    case video
}

struct NowPlayingSnapshot: Equatable, Sendable {
    let title: String
    let artist: String?
    let album: String?
    let duration: TimeInterval
    let elapsedTime: TimeInterval
    let playbackRate: Double
    let artworkData: Data?

    init(
        title: String,
        duration: TimeInterval,
        elapsedTime: TimeInterval,
        playbackRate: Double,
        artworkData: Data? = nil,
        artist: String? = nil,
        album: String? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.elapsedTime = elapsedTime
        self.playbackRate = playbackRate
        self.artworkData = artworkData
    }

    static func sanitizedLyricTitle(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var result = ""
        for character in trimmed {
            let candidate = result + String(character)
            guard candidate.utf8.count <= 240 else { break }
            result = candidate
        }
        return result.isEmpty ? nil : result
    }

    static func lyricDisplaySegments(_ text: String) -> [String] {
        guard let sanitized = sanitizedLyricTitle(text) else { return [] }
        guard sanitized.count > 12 else { return [sanitized] }

        var segments: [String] = []
        var segment = ""
        var segmentLength = 0
        for character in sanitized {
            segment.append(character)
            segmentLength += 1
            if segmentLength == 12 {
                segments.append(segment)
                segment = ""
                segmentLength = 0
            }
        }
        if !segment.isEmpty {
            segments.append(segment)
        }
        return segments
    }

    static func lyricDisplaySegment(
        _ text: String,
        cueStartTime: TimeInterval,
        elapsedTime: TimeInterval
    ) -> String? {
        let segments = lyricDisplaySegments(text)
        guard !segments.isEmpty else { return nil }

        let safeCueRelativeTime = cueStartTime.isFinite && elapsedTime.isFinite
            ? max(elapsedTime - cueStartTime, 0)
            : 0
        let step = floor(safeCueRelativeTime / 1.5)
        let index = step.isFinite
            ? Int(step.truncatingRemainder(dividingBy: Double(segments.count)))
            : 0
        return segments[index]
    }

    static func make(
        track: MusicItem?,
        duration: TimeInterval,
        elapsedTime: TimeInterval,
        isPlaying: Bool,
        bluetoothLyricsEnabled: Bool = false,
        isBluetoothA2DPRoute: Bool = false
    ) -> NowPlayingSnapshot? {
        guard let track else { return nil }

        let fileTitle = track.url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataTitle = track.metadata?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalTitle = metadataTitle?.isEmpty == false ? metadataTitle! : fileTitle
        let lyricTitle: String?
        if bluetoothLyricsEnabled,
           isBluetoothA2DPRoute,
           let lyrics = track.metadata?.synchronizedLyrics,
           let cueIndex = lyrics.cueIndex(at: elapsedTime) {
            let cue = lyrics.cues[cueIndex]
            lyricTitle = lyricDisplaySegment(
                cue.text,
                cueStartTime: TimeInterval(cue.timestampMilliseconds) / 1_000,
                elapsedTime: elapsedTime
            )
        } else {
            lyricTitle = nil
        }
        let trimmedTitle = lyricTitle ?? originalTitle
        let artist = track.metadata?.artist?.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = track.metadata?.album?.trimmingCharacters(in: .whitespacesAndNewlines)
        let publishedArtist = if lyricTitle != nil {
            artist?.isEmpty == false ? "\(originalTitle) · \(artist!)" : originalTitle
        } else {
            artist?.isEmpty == false ? artist : nil
        }
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        let safeElapsedTime = elapsedTime.isFinite
            ? min(max(elapsedTime, 0), safeDuration)
            : 0

        return NowPlayingSnapshot(
            title: trimmedTitle.isEmpty ? "Unknown Track" : trimmedTitle,
            duration: safeDuration,
            elapsedTime: safeElapsedTime,
            playbackRate: isPlaying ? 1 : 0,
            artworkData: track.metadata?.artworkData,
            artist: publishedArtist,
            album: album?.isEmpty == false ? album : nil
        )
    }

    static func make(
        video: VideoItem?,
        duration: TimeInterval,
        elapsedTime: TimeInterval,
        isPlaying: Bool,
        playbackRate: Double = VideoPlaybackRatePolicy.defaultRate
    ) -> NowPlayingSnapshot? {
        guard let video else { return nil }

        let trimmedTitle = video.url.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0
        let safeElapsedTime = elapsedTime.isFinite
            ? min(max(elapsedTime, 0), safeDuration)
            : 0
        let normalizedPlaybackRate = VideoPlaybackRatePolicy.normalized(playbackRate)

        return NowPlayingSnapshot(
            title: trimmedTitle.isEmpty ? "Unknown Video" : trimmedTitle,
            duration: safeDuration,
            elapsedTime: safeElapsedTime,
            playbackRate: isPlaying ? normalizedPlaybackRate : 0,
            artworkData: nil
        )
    }
}

@MainActor
protocol MusicNowPlayingControlling: AnyObject {
    func publish(_ snapshot: NowPlayingSnapshot)
    func publishIfUnownedOrOwned(_ snapshot: NowPlayingSnapshot)
    func clear()
    func registerRemoteCommands(
        handler: @escaping @MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult
    )
}

extension MusicNowPlayingControlling {
    // Controllers without a shared registry have no competing presentation owner.
    func publishIfUnownedOrOwned(_ snapshot: NowPlayingSnapshot) {
        publish(snapshot)
    }
}

@MainActor
protocol VideoNowPlayingControlling: AnyObject {
    func publish(_ snapshot: NowPlayingSnapshot)
    func clear()
    func registerVideoRemoteCommands(
        handler: @escaping @MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult
    )
}

@MainActor
final class VideoNowPlayingSession: ObservableObject {
    private let controller: any VideoNowPlayingControlling
    private var activeVideo: VideoItem?
    private var latestDuration: TimeInterval = 0
    private var latestCurrentTime: TimeInterval = 0
    private var latestIsPlaying = false
    private var latestPlaybackRate = VideoPlaybackRatePolicy.defaultRate
    private var actionPerformer: (@MainActor (VideoRemoteCommandAction) -> Bool)?

    init(controller: any VideoNowPlayingControlling) {
        self.controller = controller
    }

    func activate(video: VideoItem) {
        activeVideo = video
        latestDuration = video.duration ?? 0
        latestCurrentTime = 0
        latestIsPlaying = false
        latestPlaybackRate = VideoPlaybackRatePolicy.defaultRate
        if let snapshot = NowPlayingSnapshot.make(
            video: video,
            duration: latestDuration,
            elapsedTime: 0,
            isPlaying: false,
            playbackRate: latestPlaybackRate
        ) {
            controller.publish(snapshot)
        }
    }

    func update(
        duration: TimeInterval,
        currentTime: TimeInterval,
        isPlaying: Bool,
        playbackRate: Double = VideoPlaybackRatePolicy.defaultRate
    ) {
        let normalizedPlaybackRate = VideoPlaybackRatePolicy.normalized(playbackRate)
        latestDuration = duration
        latestCurrentTime = currentTime
        latestIsPlaying = isPlaying
        latestPlaybackRate = normalizedPlaybackRate
        guard let activeVideo,
              let snapshot = NowPlayingSnapshot.make(
                  video: activeVideo,
                  duration: duration,
                  elapsedTime: currentTime,
                  isPlaying: isPlaying,
                  playbackRate: normalizedPlaybackRate
              ) else { return }
        controller.publish(snapshot)
    }

    func registerRemoteCommands(
        perform: @escaping @MainActor (VideoRemoteCommandAction) -> Bool
    ) {
        actionPerformer = perform
        controller.registerVideoRemoteCommands { [weak self] command in
            guard let self,
                  self.activeVideo != nil,
                  let action = VideoRemoteCommandDecision.action(
                      for: command,
                      currentTime: self.latestCurrentTime,
                      duration: self.latestDuration,
                      isPlaying: self.latestIsPlaying
                  ),
                  self.actionPerformer?(action) == true else {
                return .commandFailed
            }
            if action == .pause {
                self.update(
                    duration: self.latestDuration,
                    currentTime: self.latestCurrentTime,
                    isPlaying: false,
                    playbackRate: self.latestPlaybackRate
                )
            }
            return .success
        }
    }

    func clear() {
        activeVideo = nil
        actionPerformer = nil
        controller.clear()
    }
}

@MainActor
final class MusicNowPlayingRegistry {
    typealias Handler = @MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult
    typealias TargetRegistrar = @MainActor (@escaping Handler) -> [() -> Void]
    typealias CommandProfileSetter = @MainActor (NowPlayingCommandProfile?) -> Void

    static let processShared = MusicNowPlayingRegistry(
        commandProfileSetter: MediaPlayerMusicNowPlayingController.applyCommandProfile
    )

    private struct OwnershipRecord {
        // Keeping the center alive makes ObjectIdentifier reuse impossible while tracked.
        let center: MPNowPlayingInfoCenter
        var activeOwnerID: UUID
    }

    private struct PublicationRecord {
        var generation: UInt64
        let nowPlayingInfo: [String: Any]
        let playbackState: MPNowPlayingPlaybackState
    }

    private struct HandlerRecord {
        let lifetime: MusicNowPlayingOwnerLifetime
        let handler: Handler
        let profile: NowPlayingCommandProfile
    }

    private struct ArtworkCacheEntry {
        let data: Data
        let artwork: MPMediaItemArtwork?
    }

    private var handlers: [UUID: HandlerRecord] = [:]
    private var ownershipByCenter: [ObjectIdentifier: OwnershipRecord] = [:]
    private var centerByOwner: [UUID: ObjectIdentifier] = [:]
    private var publicationsByOwner: [UUID: PublicationRecord] = [:]
    private var artworkCacheEntry: ArtworkCacheEntry?
    private var activeCommandOwnerID: UUID?
    private var latestGeneration: UInt64 = 0
    private var didRegisterGlobalTargets = false
    // Process-global command targets deliberately live for the registry's lifetime.
    private var globalTargetRemovals: [() -> Void] = []
    private var globalTargetRegistrar: TargetRegistrar?
    private let commandProfileSetter: CommandProfileSetter

    init(commandProfileSetter: @escaping CommandProfileSetter = { _ in }) {
        self.commandProfileSetter = commandProfileSetter
    }

    fileprivate func registerHandler(
        ownerID: UUID,
        lifetime: MusicNowPlayingOwnerLifetime,
        profile: NowPlayingCommandProfile,
        registerTargets: @escaping TargetRegistrar,
        handler: @escaping Handler
    ) {
        handlers[ownerID] = HandlerRecord(lifetime: lifetime, handler: handler, profile: profile)
        guard !didRegisterGlobalTargets else { return }
        didRegisterGlobalTargets = true
        globalTargetRegistrar = registerTargets
        installGlobalTargets(using: registerTargets)
    }

    func restoreAfterExternalNowPlayingReset() {
        guard let globalTargetRegistrar else { return }

        globalTargetRemovals.forEach { $0() }
        globalTargetRemovals.removeAll()
        installGlobalTargets(using: globalTargetRegistrar)

        commandProfileSetter(activeCommandOwnerID.flatMap { handlers[$0]?.profile })

        guard let activeCommandOwnerID,
              let publication = publicationsByOwner[activeCommandOwnerID],
              let centerID = centerByOwner[activeCommandOwnerID],
              let ownership = ownershipByCenter[centerID],
              ownership.activeOwnerID == activeCommandOwnerID else { return }
        ownership.center.nowPlayingInfo = publication.nowPlayingInfo
        ownership.center.playbackState = publication.playbackState
    }

    func publishIfUnownedOrOwned(_ snapshot: NowPlayingSnapshot, ownerID: UUID, center: MPNowPlayingInfoCenter) {
        guard activeCommandOwnerID == nil || activeCommandOwnerID == ownerID else { return }
        let centerOwnerID = ownershipByCenter[ObjectIdentifier(center)]?.activeOwnerID
        guard centerOwnerID == nil || centerOwnerID == ownerID else { return }
        publish(snapshot, ownerID: ownerID, center: center)
    }

    func publish(_ snapshot: NowPlayingSnapshot, ownerID: UUID, center: MPNowPlayingInfoCenter) {
        let centerID = ObjectIdentifier(center)
        guard centerByOwner[ownerID].map({ $0 == centerID }) ?? true else { return }
        if let previousOwnerID = ownershipByCenter[centerID]?.activeOwnerID,
           previousOwnerID != ownerID {
            publicationsByOwner.removeValue(forKey: previousOwnerID)
            if centerByOwner[previousOwnerID] == centerID {
                centerByOwner.removeValue(forKey: previousOwnerID)
            }
        }
        let generation = nextGeneration()
        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.playbackRate
        ]
        if let artist = snapshot.artist, !artist.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        }
        if let album = snapshot.album, !album.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = album
        }
        if let artwork = artwork(from: snapshot.artworkData) {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        let playbackState: MPNowPlayingPlaybackState = snapshot.playbackRate > 0 ? .playing : .paused
        ownershipByCenter[centerID] = OwnershipRecord(
            center: center,
            activeOwnerID: ownerID
        )
        centerByOwner[ownerID] = centerID
        publicationsByOwner[ownerID] = PublicationRecord(
            generation: generation,
            nowPlayingInfo: nowPlayingInfo,
            playbackState: playbackState
        )
        activeCommandOwnerID = ownerID
        commandProfileSetter(handlers[ownerID]?.profile)
        center.nowPlayingInfo = nowPlayingInfo
        center.playbackState = playbackState
    }

    func clear(ownerID: UUID, center: MPNowPlayingInfoCenter) {
        let centerID = ObjectIdentifier(center)
        guard ownershipByCenter[centerID]?.activeOwnerID == ownerID else { return }
        let publication = publicationsByOwner[ownerID]
        ownershipByCenter.removeValue(forKey: centerID)
        publicationsByOwner.removeValue(forKey: ownerID)
        centerByOwner.removeValue(forKey: ownerID)
        if publicationsByOwner.isEmpty {
            artworkCacheEntry = nil
        }
        if activeCommandOwnerID == ownerID {
            activeCommandOwnerID = newestPublishedOwnerWithHandler()
            commandProfileSetter(activeCommandOwnerID.flatMap { handlers[$0]?.profile })
        }
        if publication.map({ centerMatchesPublication(center, publication: $0) }) == true {
            clear(center)
        }
    }

    func release(ownerID: UUID, center: MPNowPlayingInfoCenter) {
        let centerID = ObjectIdentifier(center)
        guard centerByOwner[ownerID].map({ $0 == centerID }) ?? true else { return }
        let publication = publicationsByOwner[ownerID]
        handlers.removeValue(forKey: ownerID)
        if centerByOwner[ownerID] == centerID {
            publicationsByOwner.removeValue(forKey: ownerID)
            centerByOwner.removeValue(forKey: ownerID)
        }
        if ownershipByCenter[centerID]?.activeOwnerID == ownerID {
            ownershipByCenter.removeValue(forKey: centerID)
            publicationsByOwner.removeValue(forKey: ownerID)
            if publication.map({ centerMatchesPublication(center, publication: $0) }) == true {
                clear(center)
            }
        }
        if publicationsByOwner.isEmpty {
            artworkCacheEntry = nil
        }
        if activeCommandOwnerID == ownerID {
            activeCommandOwnerID = newestPublishedOwnerWithHandler()
            commandProfileSetter(activeCommandOwnerID.flatMap { handlers[$0]?.profile })
        }
    }

    func clearStaleStateDuringInitialization(center: MPNowPlayingInfoCenter) {
        let centerID = ObjectIdentifier(center)
        guard ownershipByCenter[centerID] == nil else { return }
        clear(center)
    }

    private func dispatch(_ command: MusicRemoteCommand) -> MusicRemoteCommandResult {
        guard let activeCommandOwnerID, let record = handlers[activeCommandOwnerID] else {
            return .commandFailed
        }
        return record.lifetime.performIfActive(fallback: .commandFailed) {
            record.handler(command)
        }
    }

    private func installGlobalTargets(using registrar: TargetRegistrar) {
        globalTargetRemovals = registrar { [weak self] command in
            self?.dispatch(command) ?? .commandFailed
        }
    }

    private func newestPublishedOwnerWithHandler() -> UUID? {
        publicationsByOwner
            .filter { handlers[$0.key] != nil }
            .max { $0.value.generation < $1.value.generation }?
            .key
    }

    private func artwork(from data: Data?) -> MPMediaItemArtwork? {
        guard let data else {
            artworkCacheEntry = nil
            return nil
        }
        if artworkCacheEntry?.data == data {
            return artworkCacheEntry?.artwork
        }
        let artwork = SafeArtworkDecoder.image(from: data).map { image in
            MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        artworkCacheEntry = ArtworkCacheEntry(data: data, artwork: artwork)
        return artwork
    }

    private func nextGeneration() -> UInt64 {
        if latestGeneration == .max {
            let orderedOwners = publicationsByOwner.keys.sorted {
                publicationsByOwner[$0]!.generation < publicationsByOwner[$1]!.generation
            }
            for (offset, ownerID) in orderedOwners.enumerated() {
                publicationsByOwner[ownerID]?.generation = UInt64(offset + 1)
            }
            latestGeneration = UInt64(orderedOwners.count)
        }
        latestGeneration += 1
        return latestGeneration
    }

    private func centerMatchesPublication(
        _ center: MPNowPlayingInfoCenter,
        publication: PublicationRecord
    ) -> Bool {
        guard let nowPlayingInfo = center.nowPlayingInfo else { return false }
        return NSDictionary(dictionary: nowPlayingInfo).isEqual(to: publication.nowPlayingInfo)
            && center.playbackState == publication.playbackState
    }

    private func clear(_ center: MPNowPlayingInfoCenter) {
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }
}

@MainActor
final class MusicNowPlayingCoordinator {
    typealias Handler = MusicNowPlayingRegistry.Handler
    typealias TargetRegistrar = MusicNowPlayingRegistry.TargetRegistrar

    static let shared = MusicNowPlayingCoordinator(
        center: .default(),
        registerTargets: MediaPlayerMusicNowPlayingController.registerTargets,
        registry: .processShared,
        clearsStaleStateDuringInitialization: true
    )

    private let center: MPNowPlayingInfoCenter
    private let registerTargets: TargetRegistrar
    private let registry: MusicNowPlayingRegistry

    init(testingCenter center: MPNowPlayingInfoCenter, registerTargets: @escaping TargetRegistrar) {
        self.center = center
        self.registerTargets = registerTargets
        registry = MusicNowPlayingRegistry()
    }

    fileprivate init(
        center: MPNowPlayingInfoCenter,
        registerTargets: @escaping TargetRegistrar,
        registry: MusicNowPlayingRegistry,
        clearsStaleStateDuringInitialization: Bool = false
    ) {
        self.center = center
        self.registerTargets = registerTargets
        self.registry = registry
        if clearsStaleStateDuringInitialization {
            registry.clearStaleStateDuringInitialization(center: center)
        }
    }

    fileprivate func registerHandler(
        ownerID: UUID,
        lifetime: MusicNowPlayingOwnerLifetime,
        profile: NowPlayingCommandProfile,
        handler: @escaping Handler
    ) {
        registry.registerHandler(
            ownerID: ownerID,
            lifetime: lifetime,
            profile: profile,
            registerTargets: registerTargets,
            handler: handler
        )
    }

    func publish(_ snapshot: NowPlayingSnapshot, ownerID: UUID) {
        registry.publish(snapshot, ownerID: ownerID, center: center)
    }

    func publishIfUnownedOrOwned(_ snapshot: NowPlayingSnapshot, ownerID: UUID) {
        registry.publishIfUnownedOrOwned(snapshot, ownerID: ownerID, center: center)
    }

    func clear(ownerID: UUID) {
        registry.clear(ownerID: ownerID, center: center)
    }

    func release(ownerID: UUID) {
        registry.release(ownerID: ownerID, center: center)
    }
}

private final class MusicNowPlayingCleanupToken: @unchecked Sendable {
    private let coordinator: MusicNowPlayingCoordinator
    private let ownerID: UUID
    let lifetime = MusicNowPlayingOwnerLifetime()

    init(coordinator: MusicNowPlayingCoordinator, ownerID: UUID) {
        self.coordinator = coordinator
        self.ownerID = ownerID
    }

    deinit {
        lifetime.invalidate()
        let coordinator = coordinator
        let ownerID = ownerID
        Task { @MainActor in
            coordinator.release(ownerID: ownerID)
        }
    }
}

@MainActor
final class MediaPlayerMusicNowPlayingController: MusicNowPlayingControlling, VideoNowPlayingControlling {
    static let videoSkipInterval = VideoPlaybackSkipPolicy.interval

    static func applyCommandProfile(_ profile: NowPlayingCommandProfile?) {
        let commands = MPRemoteCommandCenter.shared()
        let hasProfile = profile != nil
        let isMusic = profile == .music
        let isVideo = profile == .video

        commands.playCommand.isEnabled = hasProfile
        commands.pauseCommand.isEnabled = hasProfile
        commands.togglePlayPauseCommand.isEnabled = hasProfile
        commands.nextTrackCommand.isEnabled = isMusic
        commands.previousTrackCommand.isEnabled = isMusic
        commands.changePlaybackPositionCommand.isEnabled = isMusic || isVideo
        commands.skipBackwardCommand.isEnabled = isVideo
        commands.skipForwardCommand.isEnabled = isVideo
    }

    private let ownerID = UUID()
    private let coordinator: MusicNowPlayingCoordinator
    private let cleanupToken: MusicNowPlayingCleanupToken
    private var didRegisterRemoteCommands = false

    init(
        coordinator: MusicNowPlayingCoordinator = .shared
    ) {
        self.coordinator = coordinator
        cleanupToken = MusicNowPlayingCleanupToken(coordinator: coordinator, ownerID: ownerID)
    }

    convenience init(
        center: MPNowPlayingInfoCenter,
        registerTargets: @escaping MusicNowPlayingCoordinator.TargetRegistrar
    ) {
        self.init(coordinator: MusicNowPlayingCoordinator(
            center: center,
            registerTargets: registerTargets,
            registry: .processShared
        ))
    }

    convenience init(
        testingCenter center: MPNowPlayingInfoCenter,
        registerTargets: @escaping MusicNowPlayingCoordinator.TargetRegistrar,
        sharedRegistryForTesting registry: MusicNowPlayingRegistry
    ) {
        self.init(coordinator: MusicNowPlayingCoordinator(
            center: center,
            registerTargets: registerTargets,
            registry: registry
        ))
    }

    func publish(_ snapshot: NowPlayingSnapshot) {
        coordinator.publish(snapshot, ownerID: ownerID)
    }

    func publishIfUnownedOrOwned(_ snapshot: NowPlayingSnapshot) {
        coordinator.publishIfUnownedOrOwned(snapshot, ownerID: ownerID)
    }

    func clear() {
        coordinator.clear(ownerID: ownerID)
    }

    func registerRemoteCommands(
        handler: @escaping @MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult
    ) {
        registerRemoteCommands(profile: .music, handler: handler)
    }

    func registerVideoRemoteCommands(
        handler: @escaping @MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult
    ) {
        registerRemoteCommands(profile: .video, handler: handler)
    }

    private func registerRemoteCommands(
        profile: NowPlayingCommandProfile,
        handler: @escaping @MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult
    ) {
        guard !didRegisterRemoteCommands else { return }
        didRegisterRemoteCommands = true
        coordinator.registerHandler(
            ownerID: ownerID,
            lifetime: cleanupToken.lifetime,
            profile: profile,
            handler: handler
        )
    }

    static func registerTargets(
        handler: @escaping @MainActor (MusicRemoteCommand) -> MusicRemoteCommandResult
    ) -> [() -> Void] {
        let commands = MPRemoteCommandCenter.shared()
        commands.skipBackwardCommand.preferredIntervals = [NSNumber(value: videoSkipInterval)]
        commands.skipForwardCommand.preferredIntervals = [NSNumber(value: videoSkipInterval)]

        let playTarget = commands.playCommand.addTarget {
            _ in Self.runOnMainActor(fallback: .commandFailed) {
                Self.status(for: handler(.play))
            }
        }
        let pauseTarget = commands.pauseCommand.addTarget {
            _ in Self.runOnMainActor(fallback: .commandFailed) {
                Self.status(for: handler(.pause))
            }
        }
        let toggleTarget = commands.togglePlayPauseCommand.addTarget {
            _ in Self.runOnMainActor(fallback: .commandFailed) {
                Self.status(for: handler(.togglePlayPause))
            }
        }
        let nextTarget = commands.nextTrackCommand.addTarget {
            _ in Self.runOnMainActor(fallback: .commandFailed) {
                Self.status(for: handler(.nextTrack))
            }
        }
        let previousTarget = commands.previousTrackCommand.addTarget {
            _ in Self.runOnMainActor(fallback: .commandFailed) {
                Self.status(for: handler(.previousTrack))
            }
        }
        let positionTarget = commands.changePlaybackPositionCommand.addTarget {
            event in
                guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                    return .commandFailed
                }
                return Self.runOnMainActor(fallback: .commandFailed) {
                    Self.status(for: handler(.changePlaybackPosition(event.positionTime)))
                }
        }
        let skipBackwardTarget = commands.skipBackwardCommand.addTarget {
            _ in Self.runOnMainActor(fallback: .commandFailed) {
                Self.status(for: handler(.skipBackward))
            }
        }
        let skipForwardTarget = commands.skipForwardCommand.addTarget {
            _ in Self.runOnMainActor(fallback: .commandFailed) {
                Self.status(for: handler(.skipForward))
            }
        }

        return [
            { commands.playCommand.removeTarget(playTarget) },
            { commands.pauseCommand.removeTarget(pauseTarget) },
            { commands.togglePlayPauseCommand.removeTarget(toggleTarget) },
            { commands.nextTrackCommand.removeTarget(nextTarget) },
            { commands.previousTrackCommand.removeTarget(previousTarget) },
            { commands.changePlaybackPositionCommand.removeTarget(positionTarget) },
            { commands.skipBackwardCommand.removeTarget(skipBackwardTarget) },
            { commands.skipForwardCommand.removeTarget(skipForwardTarget) }
        ]
    }

    private static func status(for result: MusicRemoteCommandResult) -> MPRemoteCommandHandlerStatus {
        result == .success ? .success : .commandFailed
    }

    private nonisolated static func runOnMainActor<Result>(
        fallback: Result,
        _ operation: @escaping @MainActor () -> Result
    ) -> Result {
        let operation = MainActorOperation(operation)
        let isMainExecutor = mainExecutorDetector.isCurrentExecutor
        switch MusicRemoteCommandExecutorBridge.decision(
            isMainThread: Thread.isMainThread,
            isMainExecutor: isMainExecutor
        ) {
        case .runDirectly:
            return MainActor.assumeIsolated { operation.body() }
        case .synchronizeToMainExecutor:
            return DispatchQueue.main.sync {
                MainActor.assumeIsolated { operation.body() }
            }
        case .failClosed:
            return fallback
        }
    }

    private nonisolated static let mainExecutorDetector = MusicMainExecutorDetector()
}

private final class MainActorOperation<Result>: @unchecked Sendable {
    let body: @MainActor () -> Result

    init(_ body: @escaping @MainActor () -> Result) {
        self.body = body
    }
}
