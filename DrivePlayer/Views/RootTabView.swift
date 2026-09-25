import Foundation
import SwiftUI

@MainActor
struct RootTabView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var ownership: PlaybackOwnershipCoordinator
    @StateObject private var musicLibrary = MusicLibrary()
    @StateObject private var favorites = MusicFavoritesStore()
    @StateObject private var playlists = MusicPlaylistStore()
    @StateObject private var recentlyPlayed: MusicRecentlyPlayedStore
    @StateObject private var playback: MusicPlaybackManager
    @State private var isMusicPlayerPresented = false
    @State private var isVideoDetailPresented = false
    @State private var didResolveInitialPlaylistScope = false
    private let bodyDidEvaluate: () -> Void

    init() {
        let ownership = PlaybackOwnershipCoordinator()
        let recentlyPlayed = MusicRecentlyPlayedStore()
        let loudnessCoordinator: MusicLoudnessCacheCoordinator?
        if let cachesDirectoryURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first,
        let configuration = MusicLoudnessLiveConfiguration.make(
            cachesDirectoryURL: cachesDirectoryURL
        ) {
            loudnessCoordinator = MusicLoudnessCacheCoordinator(
                cacheRootURL: configuration.cacheRootURL,
                cacheBoundaryURL: configuration.cacheBoundaryURL,
                settings: configuration.settings
            )
        } else {
            loudnessCoordinator = nil
        }

        _ownership = StateObject(wrappedValue: ownership)
        _recentlyPlayed = StateObject(wrappedValue: recentlyPlayed)
        _playback = StateObject(
            wrappedValue: MusicPlaybackManager(
                ownership: ownership,
                loudnessCoordinator: loudnessCoordinator,
                initialQueueLoudnessScheduling: .deferredUntilForegroundActivation,
                recentlyPlayed: recentlyPlayed
            )
        )
        bodyDidEvaluate = {}
    }

    init(
        ownership: PlaybackOwnershipCoordinator,
        playback: MusicPlaybackManager,
        bodyDidEvaluate: @escaping () -> Void
    ) {
        _ownership = StateObject(wrappedValue: ownership)
        _recentlyPlayed = StateObject(wrappedValue: MusicRecentlyPlayedStore())
        _playback = StateObject(wrappedValue: playback)
        self.bodyDidEvaluate = bodyDidEvaluate
    }

    var body: some View {
        let _ = bodyDidEvaluate()
        TabView {
            tabContent {
                HomeView(
                    playback: playback,
                    ownership: ownership,
                    isVideoDetailPresented: $isVideoDetailPresented
                )
            }
            .tabItem {
                Label("视频", systemImage: "play.rectangle")
            }

            // Allocate the mini's measured height outside the entire music navigation flow.
            // Home and pushed playlists share the remaining viewport and one root-owned bar.
            VStack(spacing: 0) {
                MusicHomeView(library: musicLibrary, playback: playback, favorites: favorites, recentlyPlayed: recentlyPlayed, playlists: playlists)
                rootMiniPlayer
            }
            .tabItem {
                Label("音乐", systemImage: "music.note.list")
            }
        }
        .sheet(isPresented: $isMusicPlayerPresented) {
            MusicPlayerView(playback: playback, favorites: favorites)
        }
        .alert("播放失败", isPresented: playbackErrorBinding) {
            Button("好", role: .cancel) {
                playback.playbackErrorMessage = nil
            }
        } message: {
            Text(playback.playbackErrorMessage ?? "无法开始播放，请稍后重试。")
        }
        .onReceive(musicLibrary.$latestReconciliationPublication) { publication in
            playback.syncLibrary(publication.songs, snapshot: publication.reconciliationSnapshot)
        }
        .task(id: scenePhase) {
            playback.reconcileSleepTimerDeadline()
            guard scenePhase == .active else { return }
            let favoritesSnapshot = await musicLibrary.refresh()
            favorites.reconcile(with: favoritesSnapshot)
            recentlyPlayed.reconcile(with: favoritesSnapshot)
            if didResolveInitialPlaylistScope {
                MusicPlaylistCoordinator(store: playlists, playback: playback)
                    .synchronize(snapshot: favoritesSnapshot, library: musicLibrary.songs)
            } else if favoritesSnapshot.isAuthoritative {
                playlists.reconcile(with: favoritesSnapshot, library: musicLibrary.songs)
                playback.resolvePendingQueueScope(playlists: playlists, library: musicLibrary.songs)
                didResolveInitialPlaylistScope = true
            }
            await Task.yield()
            guard scenePhase == .active else { return }
            playback.activateDeferredLoudnessNormalizationForForeground()
        }
    }

    private var playbackErrorBinding: Binding<Bool> {
        Binding(
            get: { playback.playbackErrorMessage != nil },
            set: { if !$0 { playback.playbackErrorMessage = nil } }
        )
    }

    @ViewBuilder
    private func tabContent<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                rootMiniPlayer
            }
    }

    @ViewBuilder
    private var rootMiniPlayer: some View {
        if VideoDetailLayoutPolicy.showsRootChrome(
            isVideoDetailPresented: isVideoDetailPresented
        ), playback.currentTrack != nil {
            MiniMusicPlayerView(playback: playback) {
                isMusicPlayerPresented = true
            }
        }
    }

}
