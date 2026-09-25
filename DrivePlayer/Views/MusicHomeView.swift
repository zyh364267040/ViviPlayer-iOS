import SwiftUI
import UniformTypeIdentifiers

internal enum MusicImportPolicy {
    static let allowedContentTypes: [UTType] = [
        .audio,
        UTType(filenameExtension: "lrc")!
    ]
}

enum MusicPlaylistDeletionPersistenceError: Error {
    case prepareFailed
    case unlinkFailed(underlying: Error)
    case rollbackClearFailed(underlying: Error)
    case finalizeFailed

    var repairRequired: Bool {
        switch self {
        case .rollbackClearFailed, .finalizeFailed: true
        case .prepareFailed, .unlinkFailed: false
        }
    }

    var repairMode: MusicPlaylistDeletionRepairMode? {
        switch self {
        case .rollbackClearFailed: .rollback
        case .finalizeFailed: .finalize
        case .prepareFailed, .unlinkFailed: nil
        }
    }
}

internal struct MusicImportFeedback: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    static func presentation(for report: MusicLibrary.ImportReport) -> MusicImportFeedback {
        if report.failedFileNames.isEmpty {
            return MusicImportFeedback(
                title: "导入完成",
                message: "已导入 \(report.importedSongCount) 首音乐、\(report.importedLyricCount) 个歌词文件。"
            )
        }

        let failedNames = report.failedFileNames.joined(separator: "、")
        if report.importedCount > 0 {
            return MusicImportFeedback(
                title: "部分文件未导入",
                message: "已导入 \(report.importedSongCount) 首音乐、\(report.importedLyricCount) 个歌词文件；以下文件失败：\(failedNames)。"
            )
        }
        return MusicImportFeedback(title: "导入失败", message: "无法导入以下文件：\(failedNames)。")
    }
}

enum MusicPlaylistDeletionFeedback {
    static func presentation(
        for error: MusicPlaylistDeletionPersistenceError,
        repaired: Bool
    ) -> MusicImportFeedback {
        switch error {
        case .rollbackClearFailed:
            return MusicImportFeedback(
                title: "删除未完成",
                message: repaired
                    ? "音乐文件未删除，播放列表成员已保持。"
                    : "音乐文件未删除；请重试修复后再删除。"
            )
        case .finalizeFailed:
            return MusicImportFeedback(
                title: repaired ? "播放列表已修复" : "音乐已删除，需要修复播放列表",
                message: repaired
                    ? "音乐文件已删除，播放列表记录也已完成清理。"
                    : "文件已经删除，但播放列表记录尚未持久化；请再次刷新以重试修复。"
            )
        case .prepareFailed, .unlinkFailed:
            return MusicImportFeedback(title: "删除未完成", message: "音乐文件和播放列表未更改，请重试。")
        }
    }
}

struct MusicQueueScopePersistencePresentation {
    let isRepairRequired: Bool

    var showsStatus: Bool { isRepairRequired }
    var message: String? {
        isRepairRequired ? "播放范围未能保存。当前播放不受影响，请重试保存。" : nil
    }
    var retryLabel: String? { isRepairRequired ? "重试保存" : nil }
}

struct MusicPlaylistReconciliationPresentation {
    let isRepairRequired: Bool

    var showsStatus: Bool { isRepairRequired }
    var message: String? {
        isRepairRequired ? "播放列表未能保存最新音乐状态，请重试修复。" : nil
    }
    var retryLabel: String? { isRepairRequired ? "重试修复" : nil }
}

@MainActor
enum MusicDeletionCoordinator {
    static func delete(
        _ song: MusicItem,
        library: MusicLibrary,
        playback: MusicPlaybackManager,
        favorites: MusicFavoritesStore,
        recentlyPlayed: MusicRecentlyPlayedStore? = nil,
        playlists: MusicPlaylistStore? = nil
    ) async throws {
        let playlistPreparation: MusicPlaylistDeletionPreparation
        if let playlists {
            playlistPreparation = playlists.prepareMediaDeletionPlan(song)
            if playlistPreparation == .failed {
                throw MusicPlaylistDeletionPersistenceError.prepareFailed
            }
        } else {
            playlistPreparation = .noPlaylistWork
        }
        let favoritesSnapshot: MusicFavoritesReconciliationSnapshot
        do {
            favoritesSnapshot = try await library.deleteSong(song) {
                playback.prepareForDeletion(song)
                favorites.removeFavorite(for: song)
                recentlyPlayed?.remove(song)
                if let playlists, playlistPreparation == .journalPrepared {
                    guard playlists.markMediaDeletionUnlinked(song),
                          playlists.finalizeMediaDeletion(song) else {
                        throw MusicPlaylistDeletionPersistenceError.finalizeFailed
                    }
                }
            }
        } catch MusicPlaylistDeletionPersistenceError.finalizeFailed {
            let snapshot = library.latestReconciliationPublication.reconciliationSnapshot
            reconcile(
                snapshot: snapshot,
                songs: library.latestReconciliationPublication.songs,
                playback: playback,
                favorites: favorites,
                recentlyPlayed: recentlyPlayed,
                playlists: playlists
            )
            if playlists?.hasPendingMediaDeletion(for: song) == false {
                return
            }
            throw MusicPlaylistDeletionPersistenceError.finalizeFailed
        } catch {
            if let playlists, playlistPreparation == .journalPrepared {
                guard playlists.markMediaDeletionRollbackRequired(song),
                      playlists.cancelPreparedMediaDeletion(song) else {
                    throw MusicPlaylistDeletionPersistenceError.rollbackClearFailed(underlying: error)
                }
            }
            throw MusicPlaylistDeletionPersistenceError.unlinkFailed(underlying: error)
        }
        reconcile(
            snapshot: favoritesSnapshot,
            songs: library.songs,
            playback: playback,
            favorites: favorites,
            recentlyPlayed: recentlyPlayed,
            playlists: playlists
        )
    }

    private static func reconcile(
        snapshot: MusicFavoritesReconciliationSnapshot,
        songs: [MusicItem],
        playback: MusicPlaybackManager,
        favorites: MusicFavoritesStore,
        recentlyPlayed: MusicRecentlyPlayedStore?,
        playlists: MusicPlaylistStore?
    ) {
        favorites.reconcile(with: snapshot)
        recentlyPlayed?.reconcile(with: snapshot)
        if let playlists {
            MusicPlaylistCoordinator(store: playlists, playback: playback)
                .synchronize(snapshot: snapshot, library: songs)
        } else {
            playback.syncLibrary(songs, snapshot: snapshot)
        }
    }
}

@MainActor
struct MusicHomeView: View {
    @ObservedObject var library: MusicLibrary
    @ObservedObject var playback: MusicPlaybackManager
    @ObservedObject var favorites: MusicFavoritesStore
    @ObservedObject var recentlyPlayed: MusicRecentlyPlayedStore
    @ObservedObject var playlists: MusicPlaylistStore
    @State private var isImporterPresented = false
    @State private var feedback: MusicImportFeedback?
    @State private var pendingDeletion: MusicItem?
    @State private var searchText = ""
    @State private var selectedFilter = MusicLibraryFilterPreferenceStore(defaults: .standard).load()
    @State private var isClearRecentConfirmationPresented = false
    @State private var pendingArrivalTrackID: String?
    private let bodyDidEvaluate: () -> Void

    init(
        library: MusicLibrary,
        playback: MusicPlaybackManager,
        favorites: MusicFavoritesStore,
        recentlyPlayed: MusicRecentlyPlayedStore,
        playlists: MusicPlaylistStore? = nil,
        bodyDidEvaluate: @escaping () -> Void = {}
    ) {
        self.library = library
        self.playback = playback
        self.favorites = favorites
        self.recentlyPlayed = recentlyPlayed
        self.playlists = playlists ?? MusicPlaylistStore()
        self.bodyDidEvaluate = bodyDidEvaluate
    }

    var body: some View {
        let _ = bodyDidEvaluate()
        let displayedSongs = MusicLibraryFilter.filteredSongs(
            library.songs,
            selection: selectedFilter,
            favorites: favorites,
            recentlyPlayed: recentlyPlayed,
            query: searchText
        )
        let loudnessPresentation = MusicLoudnessLibraryProgressPresentation(
            isNormalizing: playback.isNormalizingLoudnessLibrary,
            completedCount: playback.loudnessNormalizationCompletedCount,
            totalCount: playback.loudnessNormalizationTotalCount
        )
        let queueScopePersistencePresentation = MusicQueueScopePersistencePresentation(
            isRepairRequired: playback.queueScopePersistenceNeedsRepair
        )
        let playlistReconciliationPresentation = MusicPlaylistReconciliationPresentation(
            isRepairRequired: playlists.reconciliationNeedsRepair
        )

        let arrivalTrackID = pendingArrivalTrackID.flatMap { id in
            displayedSongs.contains(where: { $0.id == id }) ? id : nil
        }
        ScrollViewReader { proxy in
            NavigationStack {
                List {
                    // Statuses scroll with the library; long messages cannot consume a fixed bottom inset.
                    // Separate message/retry rows keep each action reachable at accessibility text sizes.
                    if playlistReconciliationPresentation.showsStatus,
                       let message = playlistReconciliationPresentation.message,
                       let retryLabel = playlistReconciliationPresentation.retryLabel {
                        Section {
                            Text(message)
                                .font(.subheadline)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("music-playlist-reconciliation-failure")
                            Button {
                                let publication = library.latestReconciliationPublication
                                MusicPlaylistCoordinator(store: playlists, playback: playback)
                                    .synchronize(
                                        snapshot: publication.reconciliationSnapshot,
                                        library: publication.songs
                                    )
                            } label: {
                                Text(retryLabel)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(minHeight: 44, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("music-playlist-reconciliation-retry")
                        }
                    }
                    if queueScopePersistencePresentation.showsStatus,
                       let message = queueScopePersistencePresentation.message,
                       let retryLabel = queueScopePersistencePresentation.retryLabel {
                        Section {
                            Text(message)
                                .font(.subheadline)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("music-queue-scope-persistence-failure")
                            Button {
                                playback.retryQueueScopePersistence()
                            } label: {
                                Text(retryLabel)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(minHeight: 44, alignment: .leading)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("music-queue-scope-persistence-retry")
                        }
                    }
                    if loudnessPresentation.showsStatus,
                       let message = loudnessPresentation.message {
                        Section {
                            HStack(alignment: .top, spacing: 8) {
                                if loudnessPresentation.showsProgressIndicator {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Text(message)
                                    .font(.subheadline)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(message)
                        }
                    }
                    Section {
                        if library.isLoading && library.songs.isEmpty {
                            ProgressView("正在读取音乐…")
                        } else if let message = library.libraryErrorMessage {
                            ContentUnavailableView(
                                "音乐列表不可用",
                                systemImage: "exclamationmark.triangle",
                                description: Text(message)
                            )
                        } else if library.songs.isEmpty {
                            ContentUnavailableView {
                                Label("还没有音乐", systemImage: "music.note")
                            } description: {
                                Text("把音频放入“文件”>“我的 iPhone”> Vivi播放器，或在这里导入；根目录中的媒体会自动分类。")
                            } actions: {
                                Button("导入音乐") {
                                    isImporterPresented = true
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        } else if selectedFilter == .favorites,
                                  searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  displayedSongs.isEmpty {
                            ContentUnavailableView {
                                Image(systemName: "star")
                                Text("还没有收藏音乐")
                            } description: {
                                Text("在音乐列表或正在播放页面点按星标即可收藏。")
                            }
                        } else if selectedFilter == .recentlyPlayed,
                                  searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  displayedSongs.isEmpty {
                            ContentUnavailableView {
                                Image(systemName: "clock.arrow.circlepath")
                                Text("还没有最近播放的音乐")
                            } description: {
                                Text("开始播放音乐后会显示在这里。")
                            }
                        } else if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && displayedSongs.isEmpty {
                            ContentUnavailableView.search(text: searchText)
                        } else {
                            ForEach(displayedSongs) { song in
                                let artworkPresentation = MusicListArtworkPresentation(track: song)
                                let textPresentation = MusicTrackTextPresentation(track: song)

                                HStack(spacing: 8) {
                                    Button {
                                        playback.playFromLibrary(song, library: library.songs)
                                    } label: {
                                        HStack(spacing: 12) {
                                            ZStack(alignment: .bottomTrailing) {
                                                if let artworkImage = artworkPresentation.artworkImage {
                                                    Image(uiImage: artworkImage)
                                                        .resizable()
                                                        .scaledToFill()
                                                        .frame(width: 44, height: 44)
                                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                                        .accessibilityLabel("专辑封面")
                                                } else {
                                                    Image(systemName: "music.note")
                                                        .font(.title3)
                                                        .foregroundStyle(.tint)
                                                        .frame(width: 44, height: 44)
                                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                                        .accessibilityLabel("暂无专辑封面")
                                                }

                                                if isCurrent(song) {
                                                    Image(systemName: "speaker.wave.2.fill")
                                                        .font(.caption2)
                                                        .foregroundStyle(.tint)
                                                        .padding(3)
                                                        .background(.background, in: Circle())
                                                        .accessibilityLabel("当前正在播放")
                                                }
                                            }

                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(textPresentation.title)
                                                    .font(.body.weight(.semibold))
                                                    .lineLimit(2)
                                                    .foregroundStyle(.primary)
                                                if let artist = textPresentation.artist {
                                                    Text(artist)
                                                        .font(.subheadline)
                                                        .lineLimit(1)
                                                        .foregroundStyle(.secondary)
                                                }
                                                Text(song.formattedDuration)
                                                    .font(.subheadline.monospacedDigit())
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                        .padding(.vertical, 4)
                                    }
                                    .buttonStyle(.plain)

                                    let isFavorite = favorites.isFavorite(song)
                                    Button {
                                        favorites.setFavorite(!isFavorite, for: song)
                                    } label: {
                                        Image(systemName: isFavorite ? "star.fill" : "star")
                                            .frame(width: 44, height: 44)
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(song.favoriteSourceIdentity == nil)
                                    .accessibilityIdentifier("music-library-favorite-\(song.id)")
                                    .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
                                    .accessibilityValue(isFavorite ? "已收藏" : "未收藏")
                                }
                                .id(song.id)
                                .swipeActions {
                                    Button("删除", systemImage: "trash", role: .destructive) {
                                        pendingDeletion = song
                                    }
                                }
                            }
                        }
                    }
                }
                .refreshable {
                    await refreshLibrary()
                }
                .navigationTitle("音乐")
                .searchable(text: $searchText, prompt: "搜索音乐")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Picker("音乐筛选", selection: $selectedFilter) {
                            Text("全部").tag(MusicLibraryFilter.all)
                            Text("收藏").tag(MusicLibraryFilter.favorites)
                            Text("最近播放").tag(MusicLibraryFilter.recentlyPlayed)
                        }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("music-library-filter")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("导入", systemImage: "plus") { isImporterPresented = true }
                            NavigationLink {
                                MusicPlaylistListView(store: playlists, library: library, playback: playback)
                            } label: {
                                Label(MusicPlaylistUIModel.open.label, systemImage: "music.note.list")
                            }
                            .accessibilityIdentifier(MusicPlaylistUIModel.open.identifier)
                            Button("清除最近播放记录", systemImage: "trash", role: .destructive) {
                                isClearRecentConfirmationPresented = true
                            }
                            .disabled(recentlyPlayed.isEmpty)
                            .accessibilityIdentifier("music-clear-recent-history")
                        } label: {
                            Label("更多音乐操作", systemImage: "ellipsis.circle")
                        }
                    }
                }
                .onChange(of: selectedFilter) { _, _ in
                    MusicLibraryFilterPreferenceStore(defaults: .standard).save(selectedFilter)
                }
                .fileImporter(
                    isPresented: $isImporterPresented,
                    allowedContentTypes: MusicImportPolicy.allowedContentTypes,
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
                        guard let song = pendingDeletion else { return }
                        pendingDeletion = nil
                        Task { await delete(song) }
                    }
                    Button("取消", role: .cancel) { pendingDeletion = nil }
                } message: {
                    Text("此文件将从 Vivi播放器可见文件夹中永久移除，无法撤销。")
                }
                .confirmationDialog(
                    "清除最近播放记录？",
                    isPresented: $isClearRecentConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button("清除最近播放记录", role: .destructive) { recentlyPlayed.clear() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("这不会停止或改变当前播放。")
                }
            }
            // Observe the navigation container, not a lazily mounted List row.
            // Tab reentry starts a new request; data arriving later can fulfill it once.
            .onAppear { pendingArrivalTrackID = playback.currentTrack?.id }
            .onDisappear { pendingArrivalTrackID = nil }
            .onChange(of: searchText) { _, _ in pendingArrivalTrackID = nil }
            .onChange(of: selectedFilter) { _, _ in pendingArrivalTrackID = nil }
            .onChange(of: playback.currentTrack?.id) { _, _ in pendingArrivalTrackID = nil }
            .task(id: arrivalTrackID) {
                guard let arrivalTrackID else { return }
                // Let SwiftUI install the List's IDs before requesting its offset.
                await Task.yield()
                guard !Task.isCancelled, pendingArrivalTrackID == arrivalTrackID else { return }
                proxy.scrollTo(arrivalTrackID, anchor: .center)
                pendingArrivalTrackID = nil
            }
        }
    }

    private func isCurrent(_ song: MusicItem) -> Bool {
        playback.currentTrack?.fileName == song.fileName
    }

    private func refreshLibrary() async {
        let favoritesSnapshot = await library.refresh()
        favorites.reconcile(with: favoritesSnapshot)
        recentlyPlayed.reconcile(with: favoritesSnapshot)
        MusicPlaylistCoordinator(store: playlists, playback: playback)
            .synchronize(snapshot: favoritesSnapshot, library: library.songs)
    }

    private var deletionConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func delete(_ song: MusicItem) async {
        do {
            try await MusicDeletionCoordinator.delete(
                song,
                library: library,
                playback: playback,
                favorites: favorites,
                recentlyPlayed: recentlyPlayed,
                playlists: playlists
            )
        } catch let deletionError as MusicPlaylistDeletionPersistenceError {
            let repaired = deletionError.repairMode.map {
                playlists.retryDeletedMembershipRepair(song, mode: $0)
            } ?? false
            feedback = MusicPlaylistDeletionFeedback.presentation(for: deletionError, repaired: repaired)
        } catch {
            feedback = MusicImportFeedback(
                title: "无法删除音乐",
                message: "无法删除“\(song.fileName)”，请重试。"
            )
        }
    }

    private func handleImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else {
                feedback = MusicImportFeedback(title: "未导入音乐", message: "没有选择可用的文件。")
                return
            }
            Task {
                let report = await library.importSongs(from: urls)
                favorites.reconcile(with: report.favoritesSnapshot)
                recentlyPlayed.reconcile(with: report.favoritesSnapshot)
                MusicPlaylistCoordinator(store: playlists, playback: playback)
                    .synchronize(snapshot: report.favoritesSnapshot, library: library.songs)
                feedback = MusicImportFeedback.presentation(for: report)
            }
        case .failure:
            feedback = MusicImportFeedback(title: "无法导入音乐", message: "文件选择未完成，请重试。")
        }
    }
}

@MainActor
private struct MusicPlaylistListView: View {
    @ObservedObject var store: MusicPlaylistStore
    @ObservedObject var library: MusicLibrary
    @ObservedObject var playback: MusicPlaybackManager
    @State private var draft = ""
    @State private var creating = false
    @StateObject private var mutationState = MusicPlaylistMutationUIState()

    var body: some View {
        Group {
            if store.playlists.isEmpty {
                ContentUnavailableView(MusicPlaylistUIModel.listEmptyTitle, systemImage: "music.note.list", description: Text("创建播放列表来整理本地音乐。"))
            } else {
                List(store.playlists) { playlist in
                    NavigationLink {
                        MusicPlaylistDetailView(playlistID: playlist.id, store: store, library: library, playback: playback)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(playlist.name)
                            Text("\(playlist.members.count) 首") .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("music-playlist-\(playlist.id.uuidString)")
                }
            }
        }
        .navigationTitle("播放列表")
        .toolbar { Button(MusicPlaylistUIModel.create.label, systemImage: "plus") { draft = ""; creating = true }.accessibilityIdentifier(MusicPlaylistUIModel.create.identifier) }
        .alert("新建播放列表", isPresented: Binding(
            get: { creating }, set: { if !$0 && mutationState.feedback == nil { creating = false } }
        )) {
            TextField(MusicPlaylistUIModel.nameField.label, text: $draft).accessibilityIdentifier(MusicPlaylistUIModel.nameField.identifier)
            Button("创建") {
                if MusicPlaylistUIActions(store: store, playback: playback).create(name: draft) != nil { mutationState.clear() }
                else { mutationState.record(store.lastMutationFailure); creating = true }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("无法保存播放列表", isPresented: Binding(
            get: { mutationState.feedback != nil }, set: { if !$0 { mutationState.clear() } }
        )) { Button("好") {} } message: {
            Text(mutationState.feedback?.message ?? "").accessibilityIdentifier("music-playlist-mutation-failure")
                .accessibilityValue(mutationState.feedback?.accessibilityValue ?? "")
        }
    }
}

@MainActor
private struct MusicPlaylistDetailView: View {
    let playlistID: UUID
    @ObservedObject var store: MusicPlaylistStore
    @ObservedObject var library: MusicLibrary
    @ObservedObject var playback: MusicPlaybackManager
    @Environment(\.dismiss) private var dismiss
    @State private var editingName = ""
    @State private var renameIntent: MusicPlaylistIntent?
    @State private var deleteIntent: MusicPlaylistIntent?
    @State private var adding = false
    @StateObject private var addCoordinator: MusicPlaylistAddCoordinator
    @State private var memberRows: [MusicPlaylistMemberPresentation] = []
    @State private var addRows: [MusicPlaylistAddRow] = []
    @State private var playableSongs: [MusicItem] = []
    @State private var libraryIndex = MusicPlaylistLibraryIndex(library: [])
    @State private var actionIntentConsumer = MusicPlaylistActionIntentConsumer()
    @StateObject private var mutationState = MusicPlaylistMutationUIState()

    init(playlistID: UUID, store: MusicPlaylistStore, library: MusicLibrary, playback: MusicPlaybackManager) {
        self.playlistID = playlistID
        self.store = store
        self.library = library
        self.playback = playback
        _addCoordinator = StateObject(wrappedValue: MusicPlaylistAddCoordinator(
            playlistID: playlistID,
            storeRevision: store.revision,
            libraryGeneration: library.latestReconciliationPublication.generation
        ))
    }

    var body: some View {
        let playlist = store.playlist(id: playlistID)
        Group {
            if playlist?.members.isEmpty != false { ContentUnavailableView(MusicPlaylistUIModel.detailEmptyTitle, systemImage: "music.note", description: Text("使用“添加音乐”选择曲目。")) }
            else { List(memberRows) { row in
                let accessibility = MusicPlaylistUIModel.member(row)
                Button {
                    guard let song = row.playableSong else { return }
                    playback.playFromPlaylist(song, playlistID: playlistID, items: playableSongs)
                } label: {
                    HStack {
                        Text(row.playableSong?.metadata?.title ?? row.member.fileName)
                        Spacer()
                        if row.state != .playable {
                            Text(row.state == .waitingForVerification ? "正在验证" : "暂不可用")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                    .disabled(row.playableSong == nil)
                    .accessibilityIdentifier(accessibility.identifier)
                    .accessibilityLabel(accessibility.label)
                    .accessibilityValue(accessibility.value ?? "")
                    .swipeActions { Button("移除", role: .destructive) {
                        if let intent = row.removeIntent,
                           MusicPlaylistCoordinator(store: store, playback: playback).remove(
                               intent, consumer: &actionIntentConsumer, publication: library.latestReconciliationPublication
                           ) {
                            mutationState.clear()
                            refreshPresentation()
                        } else { mutationState.record(actionIntentConsumer.lastFailure ?? .staleState) }
            }.accessibilityIdentifier(MusicPlaylistUIModel.action(.remove, fileName: row.member.fileName).identifier) }
            } }
        }
        .navigationTitle(playlist?.name ?? "播放列表")
        .toolbar { Menu("播放列表操作", systemImage: "ellipsis.circle") {
            Button("添加音乐", systemImage: "plus") {
                addCoordinator.reset(
                    storeRevision: store.revision,
                    libraryGeneration: library.latestReconciliationPublication.generation
                )
                adding = true
            }.accessibilityIdentifier(MusicPlaylistUIModel.action(.add).identifier)
            Button("重命名", systemImage: "pencil") { editingName = playlist?.name ?? ""; renameIntent = MusicPlaylistUIActions(store: store, playback: playback).captureIntent(for: playlistID) }.accessibilityIdentifier(MusicPlaylistUIModel.action(.rename).identifier)
            Button("删除播放列表", systemImage: "trash", role: .destructive) { deleteIntent = MusicPlaylistUIActions(store: store, playback: playback).captureIntent(for: playlistID) }.accessibilityIdentifier(MusicPlaylistUIModel.action(.delete).identifier)
        } }
        .sheet(isPresented: $adding, onDismiss: { cancelPendingAdds() }) { NavigationStack { List(addRows) { row in
            let song = row.song
            let state = row.state
            let accessibility = MusicPlaylistUIModel.add(row)
            Button {
                switch state {
                case .added: break
                case .available:
                    if let intent = row.actionIntent,
                       addCoordinator.enqueue(intent, store: store, publication: library.latestReconciliationPublication) {
                        refreshPresentation()
                    } else { mutationState.record(addCoordinator.lastFailure ?? .replacedSource) }
                case .waitingForVerification, .requestedWaiting:
                    if addCoordinator.request(song) {
                        mutationState.clear()
                        refreshPresentation(using: libraryIndex)
                    } else {
                        mutationState.record(addCoordinator.isActive ? .unavailableSource : .staleState)
                    }
                }
            } label: { HStack { Text(song.metadata?.title ?? song.fileName); Spacer(); if state == .added { Image(systemName: "checkmark") } else if state == .waitingForVerification || state == .requestedWaiting { Text("等待验证").font(.caption).foregroundStyle(.secondary) } } }
                .accessibilityIdentifier(accessibility.identifier)
                .accessibilityLabel(accessibility.label)
                .accessibilityValue(accessibility.value ?? "")
                .accessibilityAddTraits(accessibility.isSelected ? .isSelected : [])
        } .navigationTitle("添加音乐").toolbar { Button("完成") { adding = false } } } }
        .alert("重命名播放列表", isPresented: Binding(get: { renameIntent != nil }, set: { if !$0 && mutationState.feedback == nil { renameIntent = nil } })) { TextField("名称", text: $editingName); Button("保存") { guard let intent = renameIntent else { return }; if MusicPlaylistUIActions(store: store, playback: playback).rename(intent, name: editingName) { renameIntent = nil; mutationState.clear() } else { mutationState.record(store.lastMutationFailure) } }; Button("取消", role: .cancel) { renameIntent = nil } }
        .confirmationDialog("删除“\(playlist?.name ?? "播放列表")”？", isPresented: Binding(get: { deleteIntent != nil }, set: { if !$0 && mutationState.feedback == nil { deleteIntent = nil } }), titleVisibility: .visible) {
            Button("删除播放列表", role: .destructive) { guard let intent = deleteIntent else { return }; if MusicPlaylistUIActions(store: store, playback: playback).delete(intent, confirmed: true) { deleteIntent = nil; mutationState.clear(); dismiss() } else { mutationState.record(store.lastMutationFailure) } }
            Button("取消", role: .cancel) { deleteIntent = nil }
        } message: { Text(MusicPlaylistUIModel.deletionMessage) }
        .alert("无法完成播放列表操作", isPresented: Binding(
            get: { mutationState.feedback != nil }, set: { if !$0 { mutationState.clear() } }
        )) { Button("好") {} } message: {
            Text(mutationState.feedback?.message ?? "").accessibilityIdentifier("music-playlist-mutation-failure")
                .accessibilityValue(mutationState.feedback?.accessibilityValue ?? "")
        }
        .onChange(of: library.latestReconciliationPublication) { _, publication in
            let index = MusicPlaylistCoordinator(store: store, playback: playback).resolveDetailPublication(
                publication, playlistID: playlistID, addCoordinator: addCoordinator
            )
            libraryIndex = index
            refreshPresentation(using: index)
        }
        .onChange(of: addCoordinator.changeGeneration) { _, _ in
            refreshPresentation(using: libraryIndex)
            MusicPlaylistCoordinator(store: store, playback: playback).reconcileDetailQueue(
                id: playlistID, publication: library.latestReconciliationPublication
            )
        }
        .onChange(of: addCoordinator.outcomeGeneration) { _, _ in
            while let outcome = addCoordinator.consumeOutcome() {
                mutationState.apply(outcome)
            }
        }
        .onChange(of: store.revision) { _, revision in
            if addCoordinator.expectedRevision != revision { cancelPendingAdds() }
            refreshPresentation(using: libraryIndex)
        }
        .onAppear {
            libraryIndex = MusicPlaylistLibraryIndex(library: library.songs)
            refreshPresentation(using: libraryIndex)
        }
        .onDisappear { cancelPendingAdds() }
    }

    private func refreshPresentation(using index: MusicPlaylistLibraryIndex? = nil) {
        guard let playlist = store.playlist(id: playlistID) else {
            memberRows = []; addRows = []; playableSongs = []; return
        }
        let resolvedIndex = index ?? libraryIndex
        memberRows = resolvedIndex.memberRows(
            for: playlist,
            storeRevision: store.revision,
            publicationGeneration: library.latestReconciliationPublication.generation
        )
        playableSongs = memberRows.compactMap(\.playableSong)
        addRows = resolvedIndex.addRows(
            for: playlist,
            requestedBy: addCoordinator.batch,
            storeRevision: store.revision,
            publicationGeneration: library.latestReconciliationPublication.generation
        )
    }

    private func cancelPendingAdds() {
        addCoordinator.cancel()
    }
}
