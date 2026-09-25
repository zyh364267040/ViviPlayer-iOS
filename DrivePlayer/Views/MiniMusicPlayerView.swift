import SwiftUI

@MainActor
struct MiniMusicPlayerView: View {
    @ObservedObject var playback: MusicPlaybackManager
    let openPlayer: () -> Void

    var body: some View {
        let textPresentation = playback.currentTrack.map { MusicTrackTextPresentation(track: $0) }

        HStack(spacing: 12) {
            Button(action: openPlayer) {
                HStack(spacing: 12) {
                    Image(systemName: "music.note")
                        .foregroundStyle(.tint)
                        .frame(width: 28)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(textPresentation?.title ?? "")
                            .lineLimit(1)
                            .foregroundStyle(.primary)

                        if let artist = textPresentation?.artist {
                            Text(artist)
                                .font(.caption)
                                .lineLimit(1)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                playback.togglePlayback()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(playback.isPlaying ? "暂停" : "播放")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}
