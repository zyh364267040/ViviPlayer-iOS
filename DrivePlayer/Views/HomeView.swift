import AVFoundation
import CryptoKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

internal struct VideoThumbnailRequest: Equatable, Sendable {
    let sourceURL: URL
    let thumbnailTime: TimeInterval
    let cacheIdentity: String
    let videoIdentity: String

    static func make(
        video: VideoItem,
        presentation: VideoListRowPresentation
    ) -> Self? {
        guard let thumbnailTime = presentation.thumbnailTime,
              let videoIdentity = currentVideoIdentity(for: video.url) else { return nil }
        let quantizedTime = Int64((thumbnailTime * 10).rounded())
        let cacheMaterial = "\(videoIdentity):\(quantizedTime)"
        let cacheIdentity = SHA256.hash(data: Data(cacheMaterial.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return Self(
            sourceURL: video.url,
            thumbnailTime: thumbnailTime,
            cacheIdentity: cacheIdentity,
            videoIdentity: videoIdentity
        )
    }
    func matchesCurrentSource() -> Bool {
        Self.currentVideoIdentity(for: sourceURL) == videoIdentity
    }

    private static func currentVideoIdentity(for url: URL) -> String? {
        guard url.isFileURL else { return nil }
        var metadata = stat()
        let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &metadata)
        }
        guard status == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1 else { return nil }
        return [
            url.standardizedFileURL.path,
            String(UInt64(metadata.st_dev)),
            String(UInt64(metadata.st_ino)),
            String(metadata.st_size),
            String(Int64(metadata.st_mtimespec.tv_sec)),
            String(Int64(metadata.st_mtimespec.tv_nsec)),
            String(Int64(metadata.st_ctimespec.tv_sec)),
            String(Int64(metadata.st_ctimespec.tv_nsec))
        ].joined(separator: ":")
    }
}

internal struct VideoListRowPayload: Equatable {
    let presentation: VideoListRowPresentation
    let thumbnailRequest: VideoThumbnailRequest?

    static let placeholder = Self(
        presentation: VideoListRowPresentation(
            showsNewBadge: false,
            thumbnailTime: nil,
            progressFraction: nil
        ),
        thumbnailRequest: nil
    )

    static func prepare(
        video: VideoItem,
        history: VideoPlaybackHistoryRecord
    ) -> Self {
        let presentation = VideoListRowPresentation.make(history: history)
        return Self(
            presentation: presentation,
            thumbnailRequest: VideoThumbnailRequest.make(
                video: video,
                presentation: presentation
            )
        )
    }
}

internal actor VideoThumbnailService {
    typealias Generator = @Sendable (VideoThumbnailRequest) async -> CGImage?

    private let generator: Generator
    private let maxConcurrent: Int
    private let maxCachedImages: Int
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight: [String: Task<CGImage?, Never>] = [:]
    private var cachedImages: [String: CGImage] = [:]
    private var cacheOrder: [String] = []
    private var cacheKeysByVideo: [String: Set<String>] = [:]
    private var evictionVersions: [String: UInt64] = [:]

    init(maxConcurrent: Int = 2, maxCachedImages: Int = 128) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxCachedImages = max(1, maxCachedImages)
        self.generator = { request in
            await Self.generateFrame(for: request)
        }
    }

    init(
        maxConcurrent: Int,
        maxCachedImages: Int = 128,
        generator: @escaping Generator
    ) {
        self.maxConcurrent = max(1, maxConcurrent)
        self.maxCachedImages = max(1, maxCachedImages)
        self.generator = generator
    }

    func image(for request: VideoThumbnailRequest) async -> CGImage? {
        guard request.matchesCurrentSource() else { return nil }
        if let cached = cachedImages[request.cacheIdentity] {
            return cached
        }
        if let existing = inFlight[request.cacheIdentity] {
            let image = await existing.value
            guard request.matchesCurrentSource() else { return nil }
            return image
        }

        let evictionVersion = evictionVersions[request.videoIdentity, default: 0]
        let task = Task { [generator] in
            await self.acquireSlot()
            let image = await generator(request)
            self.releaseSlot()
            return image
        }
        inFlight[request.cacheIdentity] = task
        let image = await task.value
        inFlight[request.cacheIdentity] = nil
        guard request.matchesCurrentSource() else { return nil }
        if let image,
           evictionVersions[request.videoIdentity, default: 0] == evictionVersion {
            if cachedImages[request.cacheIdentity] == nil {
                cacheOrder.append(request.cacheIdentity)
            }
            cachedImages[request.cacheIdentity] = image
            cacheKeysByVideo[request.videoIdentity, default: []].insert(request.cacheIdentity)
            trimCacheIfNeeded()
        }
        return image
    }

    func evict(videoIdentity: String) {
        evictionVersions[videoIdentity, default: 0] &+= 1
        let keys = cacheKeysByVideo.removeValue(forKey: videoIdentity) ?? []
        cacheOrder.removeAll { keys.contains($0) }
        for key in keys {
            cachedImages[key] = nil
        }
    }

    private func trimCacheIfNeeded() {
        while cachedImages.count > maxCachedImages, !cacheOrder.isEmpty {
            let oldestKey = cacheOrder.removeFirst()
            cachedImages[oldestKey] = nil
            if let owner = cacheKeysByVideo.first(where: { $0.value.contains(oldestKey) })?.key {
                cacheKeysByVideo[owner]?.remove(oldestKey)
                if cacheKeysByVideo[owner]?.isEmpty == true {
                    cacheKeysByVideo[owner] = nil
                }
            }
        }
    }

    private nonisolated static func generateFrame(
        for request: VideoThumbnailRequest
    ) async -> CGImage? {
        guard request.thumbnailTime.isFinite, request.thumbnailTime >= 0 else { return nil }
        let asset = AVURLAsset(url: request.sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
        let time = CMTime(seconds: request.thumbnailTime, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    private func acquireSlot() async {
        if activeCount < maxConcurrent {
            activeCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseSlot() {
        if waiters.isEmpty {
            activeCount -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private struct VideoLibraryRow: View {
    let video: VideoItem
    let presentation: VideoListRowPresentation
    let request: VideoThumbnailRequest?
    let thumbnailService: VideoThumbnailService

    @State private var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)

                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }

                if presentation.showsNewBadge {
                    Text("NEW")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.green, in: Capsule())
                        .padding(6)
                }
            }
            .frame(width: 112, height: 63)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(video.fileName)
                    .lineLimit(2)
                Text(video.formattedDuration)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            if let progress = presentation.progressFraction {
                VideoProgressRing(progress: progress)
            }
        }
        .padding(.vertical, 4)
        .task(id: request?.cacheIdentity) {
            thumbnail = nil
            guard let request else { return }
            thumbnail = await thumbnailService.image(for: request)
        }
    }
}

private struct VideoProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(.secondary.opacity(0.22), lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(.green, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "play.fill")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 28, height: 28)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Int((min(max(progress, 0), 1) * 100).rounded()))%")
    }
}

@MainActor
struct HomeView: View {
    private static let thumbnailService = VideoThumbnailService()

    private struct Feedback: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Environment(\.scenePhase) private var scenePhase
    let playback: MusicPlaybackManager
    @ObservedObject var ownership: PlaybackOwnershipCoordinator
    @Binding var isVideoDetailPresented: Bool
    @StateObject private var library = VideoLibrary()
    @State private var isImporterPresented = false
    @State private var feedback: Feedback?
    @State private var pendingDeletion: VideoItem?
    @State private var rowPayloads: [VideoItem.ID: VideoListRowPayload] = [:]
    @State private var isVideoAutoAdvanceEnabled = VideoAutoAdvancePreferenceStore().isEnabled()
    @State private var searchText = ""
    private let playbackProgressStore = VideoPlaybackProgressStore()
    private let videoAutoAdvancePreferenceStore = VideoAutoAdvancePreferenceStore()
    private let bodyDidEvaluate: () -> Void

    init(
        playback: MusicPlaybackManager,
        ownership: PlaybackOwnershipCoordinator,
        isVideoDetailPresented: Binding<Bool>,
        bodyDidEvaluate: @escaping () -> Void = {}
    ) {
        self.playback = playback
        self.ownership = ownership
        _isVideoDetailPresented = isVideoDetailPresented
        self.bodyDidEvaluate = bodyDidEvaluate
    }

    private var displayedVideos: [VideoItem] {
        VideoLibrarySearch.filter(library.videos, query: searchText)
    }

    var body: some View {
        let _ = bodyDidEvaluate()
        NavigationStack {
            Group {
                if library.isLoading && library.videos.isEmpty {
                    ProgressView("正在读取视频…")
                } else if let message = library.libraryErrorMessage {
                    ContentUnavailableView(
                        "视频列表不可用",
                        systemImage: "exclamationmark.triangle",
                        description: Text(message)
                    )
                } else if library.videos.isEmpty {
                    ContentUnavailableView {
                        Label("还没有视频", systemImage: "film.stack")
                    } description: {
                        Text("把视频放入“文件”>“我的 iPhone”> Vivi播放器，或在这里导入；根目录中的媒体会自动分类。")
                    } actions: {
                        Button("导入视频") {
                            isImporterPresented = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && displayedVideos.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    List(displayedVideos) { video in
                        let payload = rowPayloads[video.id] ?? .placeholder
                        NavigationLink {
                            PlayerView(
                                initialVideo: video,
                                orderedVideos: library.videos,
                                musicPlayback: playback,
                                ownership: ownership,
                                videoAutoAdvanceEnabled: isVideoAutoAdvanceEnabled,
                                isVideoDetailPresented: $isVideoDetailPresented
                            )
                        } label: {
                            VideoLibraryRow(
                                video: video,
                                presentation: payload.presentation,
                                request: payload.thumbnailRequest,
                                thumbnailService: Self.thumbnailService
                            )
                        }
                        .swipeActions {
                            Button("删除", systemImage: "trash") {
                                pendingDeletion = video
                            }
                            .tint(.red)
                        }
                    }
                    .refreshable {
                        await library.refresh()
                        prepareRowPayloads()
                    }
                }
            }
            .navigationTitle("Vivi播放器")
            .searchable(text: $searchText, prompt: "搜索视频")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu("设置", systemImage: "gearshape") {
                        Toggle("视频自动连播", isOn: videoAutoAdvanceBinding)
                            .accessibilityIdentifier("video-auto-advance-toggle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("导入", systemImage: "plus") {
                        isImporterPresented = true
                    }
                }
            }
            .fileImporter(
                isPresented: $isImporterPresented,
                allowedContentTypes: [.movie],
                allowsMultipleSelection: true
            ) { result in
                handleImporterResult(result)
            }
            .alert(item: $feedback) { feedback in
                Alert(
                    title: Text(feedback.title),
                    message: Text(feedback.message),
                    dismissButton: .default(Text("好"))
                )
            }
            .confirmationDialog(
                pendingDeletion.map { "永久删除“\($0.fileName)”？" } ?? "永久删除？",
                isPresented: deletionConfirmationBinding,
                titleVisibility: .visible
            ) {
                Button("永久删除", role: .destructive) {
                    guard let video = pendingDeletion else { return }
                    pendingDeletion = nil
                    Task { await delete(video) }
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("此文件将从 Vivi播放器可见文件夹中永久移除，无法撤销。")
            }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await library.refresh()
            prepareRowPayloads()
        }
        .onChange(of: isVideoDetailPresented) { wasPresented, isPresented in
            if wasPresented && !isPresented {
                prepareRowPayloads()
            }
        }
    }

    private var videoAutoAdvanceBinding: Binding<Bool> {
        Binding(
            get: { isVideoAutoAdvanceEnabled },
            set: { isEnabled in
                isVideoAutoAdvanceEnabled = isEnabled
                videoAutoAdvancePreferenceStore.save(isEnabled: isEnabled)
            }
        )
    }

    private func handleImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else {
                feedback = Feedback(title: "未导入视频", message: "没有选择可用的文件。")
                return
            }

            Task {
                let report = await library.importVideos(from: urls)
                prepareRowPayloads()
                feedback = feedback(for: report)
            }
        case .failure:
            feedback = Feedback(
                title: "无法导入视频",
                message: "文件选择未完成，请重试。"
            )
        }
    }

    private var deletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func delete(_ video: VideoItem) async {
        let videoIdentity = rowPayloads[video.id]?.thumbnailRequest?.videoIdentity
        do {
            try await library.deleteVideo(video)
            playbackProgressStore.removePosition(for: video)
            if let videoIdentity {
                await Self.thumbnailService.evict(videoIdentity: videoIdentity)
            }
            prepareRowPayloads()
        } catch {
            feedback = Feedback(
                title: "无法删除视频",
                message: "无法删除“\(video.fileName)”，请重试。"
            )
        }
    }

    private func prepareRowPayloads() {
        rowPayloads = Dictionary(uniqueKeysWithValues: library.videos.map { video in
            (
                video.id,
                VideoListRowPayload.prepare(
                    video: video,
                    history: playbackProgressStore.history(for: video)
                )
            )
        })
    }

    private func feedback(for report: VideoLibrary.ImportReport) -> Feedback {
        if report.failedFileNames.isEmpty {
            return Feedback(
                title: "导入完成",
                message: "已导入 \(report.importedCount) 个视频。"
            )
        }

        let failedNames = report.failedFileNames.joined(separator: "、")
        if report.importedCount > 0 {
            return Feedback(
                title: "部分视频未导入",
                message: "已导入 \(report.importedCount) 个；以下文件失败：\(failedNames)。"
            )
        }
        return Feedback(
            title: "导入失败",
            message: "无法导入以下文件：\(failedNames)。"
        )
    }
}
