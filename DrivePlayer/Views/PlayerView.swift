import AVFAudio
import KSPlayer
import Darwin
import MediaPlayer
import SwiftUI

@MainActor
private final class SystemVolumeController: ObservableObject {
    let volumeView: MPVolumeView

    init() {
        volumeView = MPVolumeView(frame: .zero)
        volumeView.showsVolumeSlider = true
        volumeView.isAccessibilityElement = false
        volumeView.accessibilityElementsHidden = true
    }

    var currentVolume: Double {
        Double(volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume)
    }

    @discardableResult
    func setVolume(_ volume: Double) -> Bool {
        guard let volumeSlider else { return false }
        volumeSlider.setValue(Float(volume), animated: false)
        volumeSlider.sendActions(for: .valueChanged)
        return true
    }

    private var volumeSlider: UISlider? {
        volumeView.subviews.compactMap { $0 as? UISlider }.first
    }
}

private struct SystemVolumeView: UIViewRepresentable {
    let controller: SystemVolumeController

    func makeUIView(context: Context) -> MPVolumeView { controller.volumeView }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

internal final class DrivePlayerVideoOptions: KSOptions {
    private let onPlayerLayerDeinit: () -> Void
    private var didReportPlayerLayerDeinit = false

    init(onPlayerLayerDeinit: @escaping () -> Void) {
        self.onPlayerLayerDeinit = onPlayerLayerDeinit
        super.init()
    }

    override func playerLayerDeinit() {
        super.playerLayerDeinit()
        guard !didReportPlayerLayerDeinit else { return }
        didReportPlayerLayerDeinit = true
        onPlayerLayerDeinit()
    }
}

@MainActor
struct PlayerView: View {
    let orderedVideos: [VideoItem]
    @ObservedObject var musicPlayback: MusicPlaybackManager
    @ObservedObject var ownership: PlaybackOwnershipCoordinator
    @Binding var isVideoDetailPresented: Bool
    private let videoAutoAdvanceEnabled: Bool
    @Environment(\.scenePhase) private var scenePhase

    // Keep the coordinator alive across SwiftUI body updates for stable playback state.
    @StateObject private var playerCoordinator = KSVideoPlayer.Coordinator()
    @StateObject private var videoNowPlayingSession = VideoNowPlayingSession(
        controller: MediaPlayerMusicNowPlayingController()
    )
    @StateObject private var systemVolume = SystemVolumeController()
    @State private var controlsVisible = true
    @State private var isPlaying = false
    @State private var currentTime: TimeInterval = 0
    @State private var duration: TimeInterval = 0
    @State private var timelineScrubTime: TimeInterval?
    @State private var scrubStartTime: TimeInterval?
    @State private var scrubPreview: PlayerScrubLogic.Preview?
    @State private var dragRoute: PlayerScrubLogic.DragRoute?
    @State private var volumeStartValue: Double?
    @State private var volumeOverlayValue: Double?
    @State private var autoHideTask: Task<Void, Never>?
    @State private var playbackRequests = VideoPlaybackRequestController()
    @State private var playbackProgressSession = VideoPlaybackProgressSession()
    @State private var videoStopRegistration: PlaybackOwnershipCoordinator.VideoStopRegistration?
    @State private var videoPlaybackIntent: PlaybackOwnershipCoordinator.VideoPlaybackIntent?
    @State private var selectedPlaybackRate = VideoPlaybackRatePolicy.defaultRate
    @State private var currentVideo: VideoItem
    @State private var autoAdvance: VideoAutoAdvanceController
    @State private var pendingAdvance: VideoAutoAdvanceRequest?
    @State private var suppressResumeVideoID: VideoItem.ID?

    private let playbackProgressStore = VideoPlaybackProgressStore()
    private let videoPlaybackRateStore = VideoPlaybackRateStore()

    init(
        initialVideo: VideoItem,
        orderedVideos: [VideoItem],
        musicPlayback: MusicPlaybackManager,
        ownership: PlaybackOwnershipCoordinator,
        videoAutoAdvanceEnabled: Bool,
        isVideoDetailPresented: Binding<Bool>
    ) {
        self.orderedVideos = orderedVideos
        _musicPlayback = ObservedObject(wrappedValue: musicPlayback)
        _ownership = ObservedObject(wrappedValue: ownership)
        self.videoAutoAdvanceEnabled = videoAutoAdvanceEnabled
        _isVideoDetailPresented = isVideoDetailPresented
        _currentVideo = State(initialValue: initialVideo)
        _autoAdvance = State(initialValue: VideoAutoAdvanceController(
            orderedVideos: orderedVideos,
            initialVideoID: initialVideo.id
        ))
        _pendingAdvance = State(initialValue: nil)
    }

    private let playerOptions: KSOptions = {
        let options = DrivePlayerVideoOptions(onPlayerLayerDeinit: {
            Task { @MainActor in
                MusicNowPlayingRegistry.processShared.restoreAfterExternalNowPlayingReset()
            }
        })
        // DrivePlayer owns the process-level command targets, so KSPlayer registration
        // remains disabled to avoid duplicate global handlers.
        options.registerRemoteControll = false
        return options
    }()

    var body: some View {
        VStack {
            if VideoDetailLayoutPolicy.flexibleSpaceBeforeContent > 0 {
                Spacer()
            }

            Text(VideoDetailLayoutPolicy.displayTitle(for: currentVideo.fileName))
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .accessibilityAddTraits(.isHeader)

            ZStack {
                KSVideoPlayer(
                    coordinator: playerCoordinator,
                    url: currentVideo.url,
                    options: playerOptions
                )
                .onPlay { currentTime, totalTime in
                    guard playerCoordinator.playerLayer?.url == currentVideo.url else { return }
                    let clockUpdate = VideoPlaybackClockUpdate.make(
                        currentTime: currentTime,
                        reportedDuration: totalTime,
                        previousDuration: self.duration,
                        metadataDuration: currentVideo.duration
                    )
                    self.currentTime = clockUpdate.currentTime
                    duration = clockUpdate.duration
                    let history: VideoPlaybackHistoryRecord
                    if suppressResumeVideoID == currentVideo.id {
                        history = .new
                        if duration > 0 { suppressResumeVideoID = nil }
                    } else {
                        history = playbackProgressStore.history(for: currentVideo)
                    }
                    if let resumePlan = playbackProgressSession.resumePlan(
                        history: history,
                        duration: duration
                    ) {
                        seek(to: resumePlan.position, shouldResume: resumePlan.shouldResume)
                    } else if let position = playbackProgressSession.periodicPositionToPersist(
                        currentTime: currentTime,
                        duration: duration
                    ) {
                        playbackProgressStore.save(position: position, duration: duration, for: currentVideo)
                    }
                    if ownership.videoPlaybackIsAllowed(videoPlaybackIntent) {
                        videoNowPlayingSession.update(
                            duration: duration,
                            currentTime: currentTime,
                            isPlaying: isPlaying,
                            playbackRate: selectedPlaybackRate
                        )
                    }
                }
                .onFinish { finishedLayer, error in
                    guard error == nil,
                          isVideoDetailPresented,
                          ownership.videoPlaybackIsAllowed(videoPlaybackIntent) else { return }
                    let finished = currentVideo
                    guard finishedLayer.url == finished.url, pendingAdvance == nil else { return }
                    playbackProgressStore.markCompleted(duration: duration, for: finished)
                    currentTime = duration
                    let availableIDs = Set(orderedVideos.lazy.filter(isPlayable).map(\.id))
                    guard let request = VideoAutoAdvanceCompletionPolicy.successfulFinish(
                        isEnabled: videoAutoAdvanceEnabled,
                        controller: &autoAdvance,
                        finishedVideoID: finished.id,
                        availableVideoIDs: availableIDs,
                        isPlayable: isPlayable
                    ), let target = orderedVideos.first(where: { $0.id == request.targetID }) else {
                        finishedLayer.pause()
                        isPlaying = false
                        if ownership.videoPlaybackIsAllowed(videoPlaybackIntent) {
                            videoNowPlayingSession.update(
                                duration: duration,
                                currentTime: currentTime,
                                isPlaying: false,
                                playbackRate: selectedPlaybackRate
                            )
                        }
                        return
                    }
                    prepareTransition(to: target, request: request)
                }
                .onStateChanged { playerLayer, state in
                    let selectedRate = Float(selectedPlaybackRate)
                    if playerCoordinator.playbackRate != selectedRate {
                        playerCoordinator.playbackRate = selectedRate
                    }
                    if state.isPlaying, pendingAdvance != nil {
                        playerLayer.pause()
                        isPlaying = false
                        guard consumePendingAdvanceForExplicitPlaybackIfReady(
                            playerLayer: playerLayer
                        ) else {
                            cancelPendingAutoAdvance()
                            return
                        }
                        playerCoordinator.playbackRate = selectedRate
                        playerLayer.play()
                        return
                    }
                    isPlaying = state.isPlaying
                    if state.isPlaying,
                       !ownership.videoPlaybackIsAllowed(videoPlaybackIntent) {
                        cancelPendingAutoAdvance()
                        playbackRequests.pauseForOwnership {
                            playerCoordinator.playerLayer?.pause()
                        }
                        return
                    }
                    if state.isPlaying,
                       pendingAdvance == nil,
                       ownership.videoPlaybackIsAllowed(videoPlaybackIntent) {
                        autoAdvance.notePlaybackStarted(videoID: currentVideo.id)
                    }
                    if ownership.videoPlaybackIsAllowed(videoPlaybackIntent) {
                        videoNowPlayingSession.update(
                            duration: duration,
                            currentTime: currentTime,
                            isPlaying: state.isPlaying,
                            playbackRate: selectedPlaybackRate
                        )
                    }
                }

                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(interactionGesture(in: geometry.size))
                }

                SystemVolumeView(controller: systemVolume)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                if let scrubPreview {
                    scrubPreviewView(scrubPreview)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if let volumeOverlayValue {
                    volumeOverlay(volumeOverlayValue)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .background(.black)

            controlLayer
                .padding(.vertical, 6)

            timelineLayer
                .padding(.horizontal, 24)

            if VideoDetailLayoutPolicy.flexibleSpaceAfterContent > 0 {
                Spacer()
            }
        }
        .background(Color.black)
        .navigationTitle(currentVideo.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            isVideoDetailPresented = true
            playbackProgressStore.markViewed(for: currentVideo)
            let clockUpdate = VideoPlaybackClockUpdate.make(
                currentTime: currentTime,
                reportedDuration: 0,
                previousDuration: duration,
                metadataDuration: currentVideo.duration
            )
            currentTime = clockUpdate.currentTime
            duration = clockUpdate.duration
            selectedPlaybackRate = VideoPlaybackRateApplication.restore(
                store: videoPlaybackRateStore
            ) { rate in
                playerCoordinator.playbackRate = rate
            }
            if videoStopRegistration == nil {
                videoStopRegistration = ownership.registerVideoStop(
                    for: playerCoordinator
                ) { playerCoordinator in
                    cancelPendingAutoAdvance()
                    playbackRequests.pauseForOwnership {
                        playerCoordinator.playerLayer?.pause()
                    }
                }
                videoPlaybackIntent = ownership.videoPlaybackRequested {
                    musicPlayback.pause()
                }
            }
            videoNowPlayingSession.activate(video: currentVideo)
            videoNowPlayingSession.registerRemoteCommands { action in
                performRemoteAction(action)
            }
            showControlsAndRestartTimer()
        }
        .onDisappear {
            isVideoDetailPresented = false
            autoHideTask?.cancel()
            cancelPendingAutoAdvance()
            ownership.videoPausedByUser(videoPlaybackIntent)
            videoPlaybackIntent = nil
            persistCurrentPosition()
            playbackRequests.pauseForOwnership {
                playerCoordinator.playerLayer?.pause()
            }
            timelineScrubTime = nil
            clearGestureState()
            videoStopRegistration = nil
            videoNowPlayingSession.clear()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active {
                persistCurrentPosition()
            }
        }
        .task(id: currentVideo.id) {
            await beginPendingAutoAdvanceWhenReady()
        }
    }

    private func performRemoteAction(_ action: VideoRemoteCommandAction) -> Bool {
        VideoRemotePlaybackActionExecutor.perform(
            action,
            play: {
                videoPlaybackIntent = ownership.videoPlaybackRequested {
                    musicPlayback.pause()
                }
                guard let playerLayer = playerCoordinator.playerLayer else { return false }
                guard consumePendingAdvanceForExplicitPlaybackIfReady(
                    playerLayer: playerLayer
                ) else { return false }
                playbackRequests.invalidate()
                playerCoordinator.playbackRate = Float(selectedPlaybackRate)
                playerLayer.play()
                return true
            },
            pause: {
                cancelPendingAutoAdvance()
                guard let playerLayer = playerCoordinator.playerLayer else { return false }
                ownership.videoPausedByUser(videoPlaybackIntent)
                videoPlaybackIntent = nil
                persistCurrentPosition()
                playbackRequests.pauseForOwnership {
                    playerLayer.pause()
                }
                return true
            },
            seek: { target in
                seek(to: target)
            }
        )
    }

    private func interactionGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: PlayerScrubLogic.activationThreshold)
            .onChanged { value in
                let route = dragRoute ?? PlayerScrubLogic.dragRoute(
                    startX: Double(value.startLocation.x),
                    translationX: Double(value.translation.width),
                    translationY: Double(value.translation.height),
                    viewWidth: Double(size.width)
                )
                if dragRoute == nil {
                    dragRoute = route
                    if route != .ignored {
                        autoHideTask?.cancel()
                    }
                    if route == .adjustVolume {
                        volumeStartValue = systemVolume.currentVolume
                    }
                }
                switch route {
                case .scrub:
                    updateScrubPreview(horizontalTranslation: value.translation.width)
                case .adjustVolume:
                    updateVolume(verticalTranslation: value.translation.height, viewHeight: size.height)
                case .ignored:
                    break
                }
            }
            .onEnded { _ in
                if PlayerScrubLogic.shouldFinishScrubbing(
                    startTime: scrubStartTime,
                    preview: scrubPreview
                ) {
                    finishScrubbing()
                } else {
                    clearGestureState()
                    restartAutoHideTimer()
                }
            }
            .exclusively(
                before: TapGesture(count: 2)
                    .onEnded { performTap(count: 2) }
                    .exclusively(before: TapGesture(count: 1).onEnded { performTap(count: 1) })
            )
    }

    private var controlLayer: some View {
        HStack(spacing: 44) {
            controlButton(
                systemName: "gobackward.15",
                accessibilityLabel: "快退 15 秒"
            ) {
                skip(seconds: -VideoPlaybackSkipPolicy.interval)
            }

            controlButton(
                systemName: isPlaying ? "pause.fill" : "play.fill",
                accessibilityLabel: isPlaying ? "暂停" : "播放"
            ) {
                togglePlayback()
            }

            controlButton(
                systemName: "goforward.15",
                accessibilityLabel: "快进 15 秒"
            ) {
                skip(seconds: VideoPlaybackSkipPolicy.interval)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(.black.opacity(0.62), in: Capsule())
    }

    private var timelineLayer: some View {
        let presentation = VideoTimelinePresentation.make(
            currentTime: timelineScrubTime ?? currentTime,
            duration: duration
        )
        let sliderValue = Binding(
            get: { presentation.isSeekEnabled ? presentation.currentTime : 0 },
            set: { timelineScrubTime = $0 }
        )

        return VStack(spacing: 4) {
            Slider(
                value: sliderValue,
                in: 0...max(presentation.duration, 1),
                onEditingChanged: { isEditing in
                    if isEditing {
                        autoHideTask?.cancel()
                    } else {
                        let previewTime = timelineScrubTime ?? presentation.currentTime
                        seek(to: previewTime)
                        timelineScrubTime = nil
                        restartAutoHideTimer()
                    }
                }
            )
            .tint(.white)
            .disabled(!presentation.isSeekEnabled)
            .accessibilityLabel("播放进度")
            .accessibilityValue(
                "\(presentation.currentTimeLabel) / \(presentation.durationLabel)"
            )

            HStack {
                Text(presentation.currentTimeLabel)
                Spacer()
                Text(presentation.durationLabel)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.7))

            HStack(spacing: CGFloat(VideoPlaybackRatePresentation.controlSpacing)) {
                ForEach(
                    VideoPlaybackRatePresentation.menuOptions(
                        selectedRate: selectedPlaybackRate
                    ),
                    id: \.rate
                ) { option in
                    Button {
                        selectPlaybackRate(option.rate)
                    } label: {
                        Text(option.label)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: CGFloat(
                                    VideoPlaybackRatePresentation.minimumTapTarget
                                )
                            )
                            .foregroundStyle(option.isSelected ? .black : .white)
                            .background(
                                option.isSelected ? .white : .white.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("播放速度 \(option.label)")
                    .accessibilityAddTraits(option.isSelected ? .isSelected : [])
                }
            }
        }
    }

    private func controlButton(
        systemName: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            showControlsAndRestartTimer()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 28, weight: .semibold))
                .frame(width: 48, height: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(accessibilityLabel)
    }

    private func scrubPreviewView(_ preview: PlayerScrubLogic.Preview) -> some View {
        let relativeSeconds = Int(abs(preview.relativeSeconds).rounded())
        let direction = preview.direction == .backward ? "快退" : "快进"

        return VStack(spacing: 6) {
            Label(
                "\(direction) \(relativeSeconds) 秒",
                systemImage: preview.direction == .backward ? "gobackward" : "goforward"
            )
            .font(.headline)

            Text(
                "\(PlayerScrubLogic.formattedTime(preview.targetTime)) / \(PlayerScrubLogic.formattedTime(duration))"
            )
            .font(.subheadline.monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private func volumeOverlay(_ volume: Double) -> some View {
        VStack(spacing: 8) {
            Image(systemName: volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.title2)
            Text("\(Int((volume * 100).rounded()))%")
                .font(.headline.monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("音量 \(Int((volume * 100).rounded()))%")
    }

    private func performTap(count: Int) {
        switch PlayerScrubLogic.tapAction(tapCount: count) {
        case .toggleControls:
            toggleControls()
        case .togglePlayback:
            togglePlayback()
            showControlsAndRestartTimer()
        case .ignored:
            break
        }
    }

    private func togglePlayback() {
        guard let playerLayer = playerCoordinator.playerLayer else { return }
        playbackRequests.invalidate()
        if playerCoordinator.state.isPlaying {
            cancelPendingAutoAdvance()
            let shouldPublishPause = VideoPausePublicationDecision.shouldPublish(
                isPlaying: playerCoordinator.state.isPlaying,
                hasCurrentOwnership: ownership.videoPlaybackIsAllowed(videoPlaybackIntent)
            )
            ownership.videoPausedByUser(videoPlaybackIntent)
            videoPlaybackIntent = nil
            persistCurrentPosition()
            playerLayer.pause()
            if shouldPublishPause {
                videoNowPlayingSession.update(
                    duration: duration,
                    currentTime: currentTime,
                    isPlaying: false,
                    playbackRate: selectedPlaybackRate
                )
            }
        } else {
            videoPlaybackIntent = ownership.videoPlaybackRequested {
                musicPlayback.pause()
            }
            guard consumePendingAdvanceForExplicitPlaybackIfReady(
                playerLayer: playerLayer
            ) else { return }
            playerCoordinator.playbackRate = Float(selectedPlaybackRate)
            playerLayer.play()
        }
    }

    private func skip(seconds: TimeInterval) {
        let targetTime = min(max(currentTime + seconds, 0), duration)
        seek(to: targetTime)
    }

    @discardableResult
    private func seek(to targetTime: TimeInterval, shouldResume: Bool? = nil) -> Bool {
        guard let playerLayer = playerCoordinator.playerLayer,
              VideoSeekRequestValidation.canIssue(
                  targetTime: targetTime,
                  duration: duration
              ) else {
            return false
        }

        let playbackPlan = SeekPlaybackPlan(
            shouldResume: shouldResume ?? playerCoordinator.state.isPlaying
        )
        let previousTime = currentTime
        let request = playbackRequests.issueSeek()
        currentTime = targetTime
        let seekVideo = currentVideo
        playbackProgressStore.save(position: targetTime, duration: duration, for: seekVideo)
        playerLayer.seek(time: targetTime, autoPlay: playbackPlan.engineAutoPlay) { finished in
            Task { @MainActor [weak playerLayer] in
                guard let playerLayer,
                      let action = playbackPlan.completionAction(
                          finished: finished,
                          isCurrent: playbackRequests.isCurrent(request)
                      ) else {
                    return
                }

                switch action {
                case .restorePreviousTime:
                    currentTime = previousTime
                    playbackProgressStore.save(position: previousTime, duration: duration, for: seekVideo)
                case .play:
                    playerCoordinator.playbackRate = Float(selectedPlaybackRate)
                    playerLayer.play()
                case .pause:
                    playerLayer.pause()
                }
            }
        }
        return true
    }

    private func selectPlaybackRate(_ requestedRate: Double) {
        selectedPlaybackRate = VideoPlaybackRateApplication.select(
            requestedRate,
            store: videoPlaybackRateStore
        ) { rate in
            playerCoordinator.playbackRate = rate
        }
        if ownership.videoPlaybackIsAllowed(videoPlaybackIntent) {
            videoNowPlayingSession.update(
                duration: duration,
                currentTime: currentTime,
                isPlaying: isPlaying,
                playbackRate: selectedPlaybackRate
            )
        }
        restartAutoHideTimer()
    }

    private func persistCurrentPosition() {
        playbackProgressStore.save(position: currentTime, duration: duration, for: currentVideo)
    }

    private func updateScrubPreview(horizontalTranslation: CGFloat) {
        let startTime = scrubStartTime ?? currentTime
        guard let preview = PlayerScrubLogic.preview(
            translation: Double(horizontalTranslation),
            currentTime: startTime,
            duration: duration,
            isActivated: scrubStartTime != nil
        ) else {
            return
        }

        if scrubStartTime == nil {
            scrubStartTime = startTime
            autoHideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.15)) {
                controlsVisible = true
            }
        }
        scrubPreview = preview
    }

    private func updateVolume(verticalTranslation: CGFloat, viewHeight: CGFloat) {
        guard let volumeStartValue,
              let volume = PlayerScrubLogic.volume(
                  startVolume: volumeStartValue,
                  verticalTranslation: Double(verticalTranslation),
                  viewHeight: Double(viewHeight)
              ), systemVolume.setVolume(volume) else {
            return
        }
        withAnimation(.easeInOut(duration: 0.1)) {
            volumeOverlayValue = volume
        }
    }

    private func clearGestureState() {
        dragRoute = nil
        volumeStartValue = nil
        volumeOverlayValue = nil
        scrubStartTime = nil
        scrubPreview = nil
    }

    private func finishScrubbing() {
        if let scrubPreview {
            seek(to: scrubPreview.targetTime)
        }
        clearGestureState()
        showControlsAndRestartTimer()
    }

    private func prepareTransition(
        to target: VideoItem,
        request: VideoAutoAdvanceRequest
    ) {
        guard ownership.videoPlaybackIsAllowed(videoPlaybackIntent) else {
            playerCoordinator.playerLayer?.pause()
            isPlaying = false
            cancelPendingAutoAdvance()
            return
        }
        playerCoordinator.playerLayer?.pause()
        playbackRequests.invalidate()
        playbackProgressSession = VideoPlaybackProgressSession()
        currentTime = 0
        duration = target.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        timelineScrubTime = nil
        clearGestureState()
        isPlaying = false
        autoHideTask?.cancel()
        let targetHistory = playbackProgressStore.history(for: target)
        suppressResumeVideoID = VideoAutoAdvanceResumePolicy.shouldSuppressResume(
            history: targetHistory
        ) ? target.id : nil
        playbackProgressStore.markViewed(for: target)
        videoNowPlayingSession.activate(video: target)
        videoNowPlayingSession.update(
            duration: duration,
            currentTime: 0,
            isPlaying: false,
            playbackRate: selectedPlaybackRate
        )
        pendingAdvance = request
        currentVideo = target
    }

    private func beginPendingAutoAdvanceWhenReady() async {
        guard let request = pendingAdvance,
              request.targetID == currentVideo.id else { return }

        // KSVideoPlayer updates its retained layer asynchronously after the URL changes.
        // A small bounded retry avoids playing either the outgoing or a stale layer.
        for attempt in 0..<50 {
            guard !Task.isCancelled,
                  pendingAdvance == request else { return }
            if let playerLayer = playerCoordinator.playerLayer,
               VideoAutoAdvancePlaybackGate.permits(
                   controller: autoAdvance,
                   request: request,
                   currentVideoID: currentVideo.id,
                   loadedURL: playerLayer.url,
                   ownershipAllowed: ownership.videoPlaybackIsAllowed(videoPlaybackIntent)
               ) {
                guard autoAdvance.beginPlayback(
                    request: request,
                    currentVideoID: currentVideo.id
                ) else {
                    return
                }
                pendingAdvance = nil
                playerCoordinator.playbackRate = Float(selectedPlaybackRate)
                playerLayer.play()
                return
            }
            if attempt == 0 {
                await Task.yield()
            } else {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        guard !Task.isCancelled,
              pendingAdvance == request else { return }
        cancelPendingAutoAdvance()
    }

    private func consumePendingAdvanceForExplicitPlaybackIfReady(
        playerLayer: KSPlayerLayer
    ) -> Bool {
        guard let request = pendingAdvance else {
            return playerLayer.url == currentVideo.url
        }
        guard VideoAutoAdvancePlaybackGate.permits(
            controller: autoAdvance,
            request: request,
            currentVideoID: currentVideo.id,
            loadedURL: playerLayer.url,
            ownershipAllowed: ownership.videoPlaybackIsAllowed(videoPlaybackIntent)
        ), autoAdvance.beginPlayback(
            request: request,
            currentVideoID: currentVideo.id
        ) else {
            return false
        }
        pendingAdvance = nil
        return true
    }

    private func cancelPendingAutoAdvance() {
        pendingAdvance = nil
        autoAdvance.invalidate()
        playbackRequests.invalidate()
    }

    private func isPlayable(_ item: VideoItem) -> Bool {
        guard item.url.isFileURL else { return false }
        var metadata = stat()
        let status: Int32 = item.url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        return status == 0
            && metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_nlink == 1
    }

    private func toggleControls() {
        autoHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            controlsVisible.toggle()
        }
        if controlsVisible {
            restartAutoHideTimer()
        }
    }

    private func showControlsAndRestartTimer() {
        withAnimation(.easeInOut(duration: 0.2)) {
            controlsVisible = true
        }
        restartAutoHideTimer()
    }

    private func restartAutoHideTimer() {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, scrubPreview == nil else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                controlsVisible = false
            }
        }
    }
}
