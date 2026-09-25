import ImageIO
import SwiftUI
import UIKit

enum SafeArtworkDecoder {
    private static let maximumPixelDimension: Int64 = 8192
    private static let maximumPixelCount: Int64 = 16_777_216

    static func image(from data: Data) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as NSDictionary?,
              let width = validatedDimension(properties[kCGImagePropertyPixelWidth]),
              let height = validatedDimension(properties[kCGImagePropertyPixelHeight]),
              width <= maximumPixelCount / height else {
            return nil
        }

        return UIImage(data: data)
    }

    private static func validatedDimension(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        let dimension = number.int64Value
        guard number.doubleValue == Double(dimension),
              dimension > 0,
              dimension <= maximumPixelDimension else { return nil }
        return dimension
    }
}

enum MusicLyricsKind: Equatable {
    case plain
    case timestamped
}

enum MusicLyricsClassifier {
    static func classify(_ lyrics: String) -> MusicLyricsKind {
        let bytes = Array(lyrics.utf8)
        var lineStart = 0

        while lineStart < bytes.count {
            if hasTimestamp(at: lineStart, in: bytes) {
                return .timestamped
            }

            while lineStart < bytes.count, bytes[lineStart] != 0x0A, bytes[lineStart] != 0x0D {
                lineStart += 1
            }
            while lineStart < bytes.count, bytes[lineStart] == 0x0A || bytes[lineStart] == 0x0D {
                lineStart += 1
            }
        }

        return .plain
    }

    private static func hasTimestamp(at start: Int, in bytes: [UInt8]) -> Bool {
        guard start < bytes.count, bytes[start] == 0x5B else { return false }
        var index = start + 1
        let minuteStart = index

        while index < bytes.count, bytes[index].isASCIIDigit {
            index += 1
        }
        guard index - minuteStart >= 2,
              index < bytes.count, bytes[index] == 0x3A else { return false }
        index += 1

        guard index + 1 < bytes.count,
              bytes[index].isASCIIDigit,
              bytes[index + 1].isASCIIDigit,
              (bytes[index] - 0x30) * 10 + bytes[index + 1] - 0x30 < 60 else { return false }
        index += 2

        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            let fractionStart = index
            while index < bytes.count, bytes[index].isASCIIDigit, index - fractionStart < 3 {
                index += 1
            }
            guard (1...3).contains(index - fractionStart) else { return false }
        }

        return index < bytes.count && bytes[index] == 0x5D
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { (0x30...0x39).contains(self) }
}

struct MusicSleepTimerPresentation {
    static func optionLabel(for mode: MusicSleepTimerMode) -> String {
        switch mode {
        case .off: "关闭"
        case .minutes15: "15 分钟"
        case .minutes30: "30 分钟"
        case .minutes60: "60 分钟"
        case .stopAfterCurrentTrack: "本曲结束后停止"
        }
    }

    static func statusText(mode: MusicSleepTimerMode, remaining: TimeInterval?) -> String {
        switch mode {
        case .off:
            return "睡眠定时：关闭"
        case .stopAfterCurrentTrack:
            return "睡眠定时：本曲结束后停止"
        case .minutes15, .minutes30, .minutes60:
            let seconds = max(0, Int(ceil(remaining ?? 0)))
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            let remainder = seconds % 60
            let countdown = hours > 0
                ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
                : String(format: "%02d:%02d", minutes, remainder)
            return "睡眠定时：\(optionLabel(for: mode))（\(countdown)）"
        }
    }
}

struct MusicListArtworkPresentation {
    let artworkImage: UIImage?
    var showsPlaceholderArtwork: Bool { artworkImage == nil }

    init(track: MusicItem) {
        artworkImage = track.metadata?.artworkData.flatMap(SafeArtworkDecoder.image(from:))
    }
}

struct MusicDetailPresentation {
    let title: String
    let artist: String?
    let album: String?
    let artworkImage: UIImage?
    let lyricsText: String?
    let synchronizedLyrics: SynchronizedLyrics?
    let lyricsKind: MusicLyricsKind?
    let lyricsHeading: String?
    let supportsBluetoothCarLyrics: Bool
    var showsPlaceholderArtwork: Bool { artworkImage == nil }

    func activeSynchronizedCueIndex(at playbackTime: TimeInterval) -> Int? {
        synchronizedLyrics?.cueIndex(at: playbackTime)
    }

    init(track: MusicItem) {
        title = MusicTrackTextPresentation(track: track).title
        artist = track.metadata?.artist
        album = track.metadata?.album
        artworkImage = track.metadata?.artworkData.flatMap(SafeArtworkDecoder.image(from:))
        synchronizedLyrics = track.metadata?.synchronizedLyrics
        supportsBluetoothCarLyrics = synchronizedLyrics != nil
        if let lyrics = track.metadata?.lyrics {
            lyricsText = lyrics
        } else {
            lyricsText = nil
        }
        if synchronizedLyrics != nil {
            lyricsKind = .timestamped
            lyricsHeading = "同步歌词"
        } else if let lyrics = track.metadata?.lyrics {
            let kind = MusicLyricsClassifier.classify(lyrics)
            lyricsKind = kind
            lyricsHeading = kind == .plain ? "歌词" : "时间歌词（全文）"
        } else {
            lyricsKind = nil
            lyricsHeading = nil
        }
    }
}

struct MusicQueueRowPresentation {
    let title: String
    let artist: String?
    let isCurrent: Bool
    let accessibilityIdentifier: String
    var accessibilityValue: String { isCurrent ? "当前播放" : "非当前播放" }

    init(track: MusicItem, index: Int, isCurrent: Bool) {
        let textPresentation = MusicTrackTextPresentation(track: track)
        title = textPresentation.title
        artist = textPresentation.artist
        self.isCurrent = isCurrent
        accessibilityIdentifier = "music-queue-row-\(index)"
    }
}

@MainActor
private struct MusicQueueSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var playback: MusicPlaybackManager

    var body: some View {
        NavigationStack {
            Group {
                if playback.queue.isEmpty {
                    ContentUnavailableView {
                        Image(systemName: "music.note.list")
                        Text("播放队列为空")
                    }
                } else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(Array(playback.queue.enumerated()), id: \.offset) { index, track in
                                let presentation = MusicQueueRowPresentation(
                                    track: track,
                                    index: index,
                                    isCurrent: playback.currentIndex == index
                                )

                                Button {
                                    playback.play(track)
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .foregroundStyle(.tint)
                                            .opacity(presentation.isCurrent ? 1 : 0)
                                            .accessibilityHidden(true)

                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(presentation.title)
                                                .foregroundStyle(presentation.isCurrent ? Color.accentColor : Color.primary)
                                            if let artist = presentation.artist {
                                                Text(artist)
                                                    .font(.subheadline)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier(presentation.accessibilityIdentifier)
                                .accessibilityValue(presentation.accessibilityValue)
                                .accessibilityAddTraits(presentation.isCurrent ? .isSelected : [])
                                .id(index)
                            }
                        }
                        .listStyle(.plain)
                        .onAppear {
                            guard let index = playback.currentIndex,
                                  playback.queue.indices.contains(index),
                                  playback.queue[index].fileName == playback.currentTrack?.fileName else { return }
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            }
            .navigationTitle("播放队列")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

// Constructed only by the real More sheet onDismiss. Delivery is synchronous by
// default; tests may retain this one-shot event until their host is dismantled.
@MainActor
final class MusicPlayerMoreDismissalDelivery {
    let id = UUID()
    private var continuation: (@MainActor () -> Void)?
    private let processed: @MainActor (UUID) -> Void

    fileprivate init(continuation: @escaping @MainActor () -> Void, processed: @escaping @MainActor (UUID) -> Void) {
        self.continuation = continuation
        self.processed = processed
    }

    func deliver() {
        guard let continuation else { return }
        self.continuation = nil
        continuation()
        processed(id)
    }
}

@MainActor
struct MusicPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var playback: MusicPlaybackManager
    @StateObject private var timeline: MusicPlaybackTimelineProjection
    @ObservedObject var favorites: MusicFavoritesStore
    @State private var sliderValue: TimeInterval = 0
    @State private var isSeeking = false
    @State private var showsQueue = false
    @State private var showsLyrics = false
    @State private var showsMore = false
    @State private var isViewVisible = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let bodyDidEvaluate: () -> Void
    private let moreDismissalDeliveryGate: @MainActor (MusicPlayerMoreDismissalDelivery) -> Void
    private let moreDismissalProcessed: @MainActor (UUID) -> Void

    init(
        playback: MusicPlaybackManager,
        favorites: MusicFavoritesStore,
        timelineProjection: MusicPlaybackTimelineProjection? = nil,
        bodyDidEvaluate: @escaping () -> Void = {},
        moreDismissalDeliveryGate: @escaping @MainActor (MusicPlayerMoreDismissalDelivery) -> Void = { $0.deliver() },
        moreDismissalProcessed: @escaping @MainActor (UUID) -> Void = { _ in }
    ) {
        self.playback = playback
        _timeline = StateObject(
            wrappedValue: timelineProjection
                ?? MusicPlaybackTimelineProjection(timeline: playback.timeline)
        )
        self.favorites = favorites
        self.bodyDidEvaluate = bodyDidEvaluate
        self.moreDismissalDeliveryGate = moreDismissalDeliveryGate
        self.moreDismissalProcessed = moreDismissalProcessed
    }

    var body: some View {
        let _ = bodyDidEvaluate()
        NavigationStack {
            let presentation = playback.currentTrack.map { MusicDetailPresentation(track: $0) }
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    if showsLyrics && dynamicTypeSize.isAccessibilitySize {
                        // Share the whole content viewport with lyrics. Identity remains
                        // fully scrollable on the cover page, without reserving a tiny band here.
                        lyricsContent(presentation)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                    } else if showsLyrics {
                        VStack(spacing: 12) {
                            ScrollView(.vertical) {
                                trackIdentity(presentation)
                            }
                            .frame(maxHeight: min(geometry.size.height * 0.25,
                                                  110))
                            contentToggle
                            lyricsContent(presentation)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                    } else {
                        ScrollView(.vertical) {
                            VStack(spacing: 16) {
                                Spacer(minLength: 0)
                                artwork(
                                    presentation,
                                    size: max(64, min(
                                        dynamicTypeSize.isAccessibilitySize ? 140 : 300,
                                        geometry.size.width - 48,
                                        geometry.size.height * 0.55
                                    ))
                                )
                                trackIdentity(presentation)
                                contentToggle
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 8)
                            .frame(minHeight: geometry.size.height)
                        }
                    }
                }
                .clipped()

                VStack(spacing: dynamicTypeSize.isAccessibilitySize ? 8 : 16) {
                    VStack(spacing: 8) {
                        Slider(
                            value: progressSliderBinding,
                            in: 0...max(playback.duration, 1),
                            onEditingChanged: { editing in
                                if editing {
                                    sliderValue = timeline.currentTime
                                }
                                isSeeking = editing
                                if !editing {
                                    playback.seek(to: sliderValue)
                                }
                            }
                        )
                        .disabled(playback.currentTrack == nil || playback.duration <= 0)

                        HStack {
                            Text(MusicItem.formatTime(isSeeking ? sliderValue : timeline.currentTime))
                            Spacer()
                            Text(playback.duration > 0
                                 ? MusicItem.formatDuration(playback.duration)
                                 : "--:--")
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24)

                    HStack(spacing: 44) {
                        Button {
                            playback.previous()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 30))
                                .frame(width: 52, height: 52)
                        }
                        .accessibilityLabel("上一首")

                        Button {
                            playback.togglePlayback()
                        } label: {
                            Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 68))
                        }
                        .accessibilityLabel(playback.isPlaying ? "暂停" : "播放")

                        Button {
                            playback.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 30))
                                .frame(width: 52, height: 52)
                        }
                        .accessibilityLabel("下一首")
                    }
                    .disabled(playback.currentTrack == nil)

                    secondaryControls
                        .padding(.horizontal, 16)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 8 : 12)
                .background(Color(uiColor: .systemBackground))
            }
            .navigationTitle("正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsMore = true } label: {
                        Image(systemName: "ellipsis")
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("更多")
                    .accessibilityIdentifier("music-player-more-entry")
                }
            }
            .sheet(isPresented: $showsQueue) {
                MusicQueueSheet(playback: playback)
            }
            .sheet(isPresented: $showsMore, onDismiss: {
                moreDismissalDeliveryGate(MusicPlayerMoreDismissalDelivery(continuation: {
                    guard isViewVisible else { return }
                    updateTimelineActivity()
                }, processed: moreDismissalProcessed))
            }) {
                moreSheet
            }
            .onAppear {
                isViewVisible = true
                updateTimelineActivity()
                sliderValue = timeline.currentTime
            }
            .onDisappear {
                isViewVisible = false
                timeline.setActive(false)
            }
            .onChange(of: playback.currentTrack?.id) { _, _ in
                sliderValue = timeline.currentTime
            }
            .onChange(of: showsQueue) { _, _ in
                updateTimelineActivity()
            }
            .onChange(of: showsMore) { _, _ in
                updateTimelineActivity()
            }
        }
    }

    private func updateTimelineActivity() {
        timeline.setActive(isViewVisible && !showsQueue && !showsMore)
    }

    private var contentToggle: some View {
        Button { showsLyrics.toggle() } label: {
            Label(showsLyrics ? "显示封面" : "显示歌词",
                  systemImage: showsLyrics ? "photo" : "text.alignleft")
                .font(.subheadline.weight(.medium))
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityIdentifier("music-player-content-toggle")
    }

    private func artwork(_ presentation: MusicDetailPresentation?, size: CGFloat) -> some View {
        Group {
            if let image = presentation?.artworkImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("专辑封面")
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: min(76, size * 0.4), weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityLabel(presentation == nil ? "未选择歌曲" : "暂无专辑封面")
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 24))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    private func trackIdentity(_ presentation: MusicDetailPresentation?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(presentation?.title ?? "未选择歌曲")
                    .font(.title2.weight(.semibold))
                if let artist = presentation?.artist {
                    Text(artist).foregroundStyle(.secondary)
                }
                if let album = presentation?.album {
                    Text(album).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let currentTrack = playback.currentTrack {
                let isFavorite = favorites.isFavorite(currentTrack)
                Button {
                    favorites.setFavorite(!isFavorite, for: currentTrack)
                } label: {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(currentTrack.favoriteSourceIdentity == nil)
                .accessibilityIdentifier("music-player-favorite-toggle")
                .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
                .accessibilityValue(isFavorite ? "已收藏" : "未收藏")
            }
        }
    }

    @ViewBuilder
    private func lyricsContent(_ presentation: MusicDetailPresentation?) -> some View {
        if let lyrics = presentation?.synchronizedLyrics {
            VStack(alignment: .leading, spacing: 8) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Text(presentation?.lyricsHeading ?? "同步歌词").font(.headline)
                }
                SynchronizedLyricsView(
                    lyrics: lyrics,
                    activeIndex: presentation?.activeSynchronizedCueIndex(at: timeline.currentTime)
                ) {
                    if dynamicTypeSize.isAccessibilitySize {
                        contentToggle
                        Text(presentation?.lyricsHeading ?? "同步歌词")
                            .font(.headline)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .id(playback.currentTrack?.id)
            }
        } else {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    if dynamicTypeSize.isAccessibilitySize {
                        contentToggle
                    }
                    Text(presentation?.lyricsHeading ?? "暂无歌词").font(.headline)
                    if let text = presentation?.lyricsText {
                        Text(text)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("music-detail-lyrics-text")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var secondaryControls: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    completionModeMenu
                    HStack(spacing: 8) {
                        shuffleControl
                        Spacer(minLength: 8)
                        queueControl
                    }
                }
            } else {
                HStack(spacing: 8) {
                    shuffleControl
                    completionModeMenu
                    queueControl
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var shuffleControl: some View {
        let isShuffleSelected = playback.isShuffleEnabled
        return Button {
            playback.setShuffleEnabled(!isShuffleSelected)
        } label: {
            Image(systemName: "shuffle")
                .frame(minWidth: 44, minHeight: 44)
                .background(isShuffleSelected ? Color.accentColor.opacity(0.16) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 12))
        }
        .disabled(playback.currentTrack == nil)
        .accessibilityIdentifier("music-shuffle-toggle")
        .accessibilityLabel("随机播放")
        .accessibilityValue(isShuffleSelected ? "已选择" : "未选择")
        .accessibilityAddTraits(isShuffleSelected ? .isSelected : [])
    }

    private var completionModeMenu: some View {
        Menu {
            ForEach(MusicCompletionMode.allCases, id: \.self) { mode in
                Button {
                    playback.setCompletionMode(mode)
                } label: {
                    if playback.completionMode == mode {
                        Label(completionModeLabelText(mode), systemImage: "checkmark")
                    } else {
                        Text(completionModeLabelText(mode))
                    }
                }
                .accessibilityIdentifier("music-completion-mode-\(mode.rawValue)")
            }
        } label: {
            HStack(spacing: 4) {
                Text(completionModeLabelText(playback.completionMode))
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down").font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(playback.currentTrack == nil)
        .accessibilityIdentifier("music-completion-mode-menu")
        .accessibilityLabel("播放完成方式")
        .accessibilityValue(completionModeLabelText(playback.completionMode))
    }

    private var queueControl: some View {
        Button { showsQueue = true } label: {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(HStackLayout(spacing: 8))
                : AnyLayout(VStackLayout(spacing: 2))
            layout {
                Image(systemName: "list.bullet")
                Text("队列").font(.caption)
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("播放队列")
        .accessibilityIdentifier("music-queue-entry")
    }

    private var moreSheet: some View {
        NavigationStack {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 24) {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let statusText = MusicSleepTimerPresentation.statusText(
                            mode: playback.sleepTimerMode,
                            remaining: playback.sleepTimerRemainingTime()
                        )
                        Menu {
                            ForEach(MusicSleepTimerMode.allCases, id: \.self) { mode in
                                Button {
                                    playback.setSleepTimerMode(mode)
                                } label: {
                                    if playback.sleepTimerMode == mode {
                                        Label(
                                            MusicSleepTimerPresentation.optionLabel(for: mode),
                                            systemImage: "checkmark"
                                        )
                                    } else {
                                        Text(MusicSleepTimerPresentation.optionLabel(for: mode))
                                    }
                                }
                            }
                        } label: {
                            Label(statusText, systemImage: "timer")
                                .font(.body.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(playback.currentTrack == nil)
                        .accessibilityIdentifier("music-sleep-timer-menu")
                        .accessibilityLabel("睡眠定时")
                        .accessibilityValue(statusText)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("播放时会暂时使用蓝牙歌曲标题字段显示当前歌词，实际效果可能因车型而异。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if playback.currentTrack?.metadata?.synchronizedLyrics == nil {
                            Text("当前歌曲无可用同步歌词")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("更多")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showsMore = false }
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }

    private var progressSliderBinding: Binding<TimeInterval> {
        Binding(
            get: { isSeeking ? sliderValue : timeline.currentTime },
            set: { sliderValue = $0 }
        )
    }

    private func completionModeLabelText(_ mode: MusicCompletionMode) -> String {
        switch mode {
        case .repeatAll: "列表循环"
        case .repeatOne: "单曲循环"
        case .stopAtEnd: "播完停止"
        }
    }
}

private struct SynchronizedLyricsView<Header: View>: View {
    let lyrics: SynchronizedLyrics
    let activeIndex: Int?
    @ViewBuilder var header: Header

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    header
                    ForEach(lyrics.cues.indices, id: \.self) { index in
                        Text(lyrics.cues[index].text)
                            .fontWeight(index == activeIndex ? .semibold : .regular)
                            .foregroundStyle(index == activeIndex ? Color.accentColor : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .id(index)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .accessibilityIdentifier("music-detail-lyrics-text")
            .onAppear {
                guard let activeIndex else { return }
                proxy.scrollTo(activeIndex, anchor: .center)
            }
            .onChange(of: activeIndex) { _, newIndex in
                guard let newIndex else { return }
                withAnimation {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }
}
