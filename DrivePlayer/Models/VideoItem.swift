import Foundation

struct VideoItem: Identifiable, Hashable {
    let url: URL
    let duration: TimeInterval?

    var id: URL { url }
    var fileName: String { url.lastPathComponent }

    var formattedDuration: String {
        guard let duration, duration.isFinite, duration >= 0 else {
            return "--:--"
        }

        let totalSeconds = Int(duration.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum VideoLibrarySearch {
    static func filter(_ videos: [VideoItem], query: String) -> [VideoItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return videos }

        return videos.filter { $0.fileName.localizedCaseInsensitiveContains(trimmedQuery) }
    }
}
