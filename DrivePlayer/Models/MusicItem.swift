import Combine
import Foundation

struct MusicFavoriteSourceIdentity: Codable, Equatable, Hashable, Sendable {
    let fileSize: Int64
    let contentSHA256Hex: String

    var isValid: Bool {
        fileSize >= 0
            && contentSHA256Hex.utf8.count == 64
            && contentSHA256Hex.utf8.allSatisfy {
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
            }
    }
}

struct MusicFavoritesReconciliationSnapshot: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let logicalLocation: String
        let fileName: String
        let sourceIdentity: MusicFavoriteSourceIdentity?
    }

    let isAuthoritative: Bool
    let entries: [Entry]

    static let unavailable = MusicFavoritesReconciliationSnapshot(
        isAuthoritative: false,
        entries: []
    )

    init(isAuthoritative: Bool, entries: [Entry]) {
        self.isAuthoritative = isAuthoritative
        self.entries = entries
    }

    init(songs: [MusicItem]) {
        isAuthoritative = true
        entries = songs.map {
            Entry(
                logicalLocation: $0.url.deletingLastPathComponent().lastPathComponent,
                fileName: $0.fileName,
                sourceIdentity: $0.favoriteSourceIdentity
            )
        }
    }
}

struct MusicItem: Identifiable, Equatable, Sendable {
    let url: URL
    let duration: TimeInterval?
    let metadata: MusicMetadata?
    let favoriteSourceIdentity: MusicFavoriteSourceIdentity?

    init(
        url: URL,
        duration: TimeInterval?,
        metadata: MusicMetadata? = nil,
        favoriteSourceIdentity: MusicFavoriteSourceIdentity? = nil
    ) {
        self.url = url
        self.duration = duration
        self.metadata = metadata
        self.favoriteSourceIdentity = favoriteSourceIdentity
    }

    var id: String { fileName }
    var fileName: String { url.lastPathComponent }

    var formattedDuration: String {
        guard let duration, duration.isFinite, duration >= 0 else { return "--:--" }
        return Self.formatDuration(duration)
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        return formatWholeSeconds(Int(seconds.rounded()))
    }

    static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        return formatWholeSeconds(Int(seconds.rounded(.down)))
    }

    private static func formatWholeSeconds(_ totalSeconds: Int) -> String {
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

@MainActor
final class MusicFavoritesStore: ObservableObject {
    private static let key = "MusicFavoritesStore.state.v1"
    private static let version = 1
    private static let maximumPayloadBytes = 64 * 1024
    private static let maximumFavoriteCount = 1_024

    private struct FavoriteRecord: Codable, Equatable {
        let logicalLocation: String
        let fileName: String
        let sourceIdentity: MusicFavoriteSourceIdentity
    }

    private struct Payload: Codable {
        let version: Int
        let favorites: [FavoriteRecord]
    }

    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    private var recordsByLogicalID: [String: FavoriteRecord]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recordsByLogicalID = Self.load(defaults: defaults)
    }

    func isFavorite(_ song: MusicItem) -> Bool {
        guard let sourceIdentity = song.favoriteSourceIdentity else { return false }
        return recordsByLogicalID[logicalID(for: song)]?.sourceIdentity == sourceIdentity
    }

    func toggleFavorite(for song: MusicItem) {
        setFavorite(!isFavorite(song), for: song)
    }

    func setFavorite(_ desiredState: Bool, for song: MusicItem) {
        guard !song.fileName.isEmpty else { return }
        var candidate = recordsByLogicalID
        let logicalID = logicalID(for: song)
        if desiredState {
            guard !isFavorite(song),
                  let sourceIdentity = song.favoriteSourceIdentity,
                  sourceIdentity.isValid else { return }
            candidate[logicalID] = FavoriteRecord(
                logicalLocation: logicalLocation(for: song),
                fileName: song.fileName,
                sourceIdentity: sourceIdentity
            )
        } else {
            guard isFavorite(song) else { return }
            guard candidate.removeValue(forKey: logicalID) != nil else { return }
        }
        commit(candidate)
    }

    func removeFavorite(for song: MusicItem) {
        var candidate = recordsByLogicalID
        guard candidate.removeValue(forKey: logicalID(for: song)) != nil else { return }
        commit(candidate)
    }

    func reconcile(with snapshot: MusicFavoritesReconciliationSnapshot) {
        guard snapshot.isAuthoritative else { return }
        var entriesByLogicalID: [String: MusicFavoritesReconciliationSnapshot.Entry] = [:]
        for entry in snapshot.entries {
            let logicalID = Self.logicalID(
                location: entry.logicalLocation,
                fileName: entry.fileName
            )
            guard entriesByLogicalID[logicalID] == nil else { return }
            entriesByLogicalID[logicalID] = entry
        }
        let reconciled = recordsByLogicalID.filter { logicalID, record in
            guard let entry = entriesByLogicalID[logicalID] else { return false }
            guard let sourceIdentity = entry.sourceIdentity else { return true }
            return sourceIdentity == record.sourceIdentity
        }
        guard reconciled != recordsByLogicalID else { return }
        commit(reconciled)
    }

    private static func load(defaults: UserDefaults) -> [String: FavoriteRecord] {
        guard let data = defaults.data(forKey: key),
              data.count <= maximumPayloadBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == version,
              payload.favorites.count <= maximumFavoriteCount else { return [:] }
        var records: [String: FavoriteRecord] = [:]
        for record in payload.favorites {
            guard !record.logicalLocation.isEmpty,
                  record.logicalLocation == URL(fileURLWithPath: record.logicalLocation).lastPathComponent,
                  !record.fileName.isEmpty,
                  record.fileName == URL(fileURLWithPath: record.fileName).lastPathComponent,
                  record.sourceIdentity.isValid else { return [:] }
            let id = logicalID(location: record.logicalLocation, fileName: record.fileName)
            guard records[id] == nil else { return [:] }
            records[id] = record
        }
        return records
    }

    @discardableResult
    private func commit(_ candidate: [String: FavoriteRecord]) -> Bool {
        guard candidate.count <= Self.maximumFavoriteCount else { return false }
        let payload = Payload(
            version: Self.version,
            favorites: candidate.values.sorted {
                ($0.logicalLocation, $0.fileName) < ($1.logicalLocation, $1.fileName)
            }
        )
        guard let data = try? JSONEncoder().encode(payload),
              data.count <= Self.maximumPayloadBytes else { return false }
        defaults.set(data, forKey: Self.key)
        guard defaults.data(forKey: Self.key) == data else { return false }
        recordsByLogicalID = candidate
        revision &+= 1
        return true
    }

    private func logicalID(for song: MusicItem) -> String {
        Self.logicalID(location: logicalLocation(for: song), fileName: song.fileName)
    }

    private func logicalLocation(for song: MusicItem) -> String {
        song.url.deletingLastPathComponent().lastPathComponent
    }

    private static func logicalID(location: String, fileName: String) -> String {
        "\(location)\u{0}\(fileName)"
    }
}

@MainActor
final class MusicRecentlyPlayedStore: ObservableObject {
    static let persistenceKey = "MusicRecentlyPlayedStore.state.v1"
    private static let version = 1
    private static let maximumPayloadBytes = 64 * 1_024
    private static let maximumRecordCount = 100

    private struct Record: Codable, Equatable {
        let logicalLocation: String
        let fileName: String
        let sourceIdentity: MusicFavoriteSourceIdentity

        var logicalID: String { Self.makeLogicalID(logicalLocation, fileName) }

        static func makeLogicalID(_ location: String, _ fileName: String) -> String {
            "\(location)\u{0}\(fileName)"
        }
    }

    private struct Payload: Codable {
        let version: Int
        let records: [Record]
    }

    @Published private(set) var revision = 0
    private let defaults: UserDefaults
    private var records: [Record]

    var isEmpty: Bool { records.isEmpty }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        records = Self.load(defaults)
    }

    func record(_ song: MusicItem) {
        guard let record = Self.record(for: song) else { return }
        if records.first == record { return }
        var candidate = records.filter { $0.logicalID != record.logicalID }
        candidate.insert(record, at: 0)
        if candidate.count > Self.maximumRecordCount {
            candidate.removeLast(candidate.count - Self.maximumRecordCount)
        }
        commit(candidate)
    }

    func orderedMatchingSongs(in songs: [MusicItem]) -> [MusicItem] {
        var songsByID: [String: MusicItem] = [:]
        for song in songs {
            guard let record = Self.record(for: song), songsByID[record.logicalID] == nil else { continue }
            songsByID[record.logicalID] = song
        }
        return records.compactMap { record in
            guard let song = songsByID[record.logicalID],
                  song.favoriteSourceIdentity == record.sourceIdentity else { return nil }
            return song
        }
    }

    func clear() {
        guard !records.isEmpty else { return }
        defaults.removeObject(forKey: Self.persistenceKey)
        guard defaults.data(forKey: Self.persistenceKey) == nil else { return }
        records = []
        revision &+= 1
    }

    func remove(_ song: MusicItem) {
        let logicalID = Self.logicalID(for: song)
        let candidate = records.filter { $0.logicalID != logicalID }
        guard candidate != records else { return }
        commit(candidate)
    }

    func reconcile(with snapshot: MusicFavoritesReconciliationSnapshot) {
        guard snapshot.isAuthoritative else { return }
        var entries: [String: MusicFavoritesReconciliationSnapshot.Entry] = [:]
        for entry in snapshot.entries {
            let id = Record.makeLogicalID(entry.logicalLocation, entry.fileName)
            guard entries[id] == nil else { return }
            entries[id] = entry
        }
        let candidate = records.filter { record in
            guard let entry = entries[record.logicalID] else { return false }
            return entry.sourceIdentity.map { $0 == record.sourceIdentity } ?? true
        }
        guard candidate != records else { return }
        commit(candidate)
    }

    private static func load(_ defaults: UserDefaults) -> [Record] {
        guard let data = defaults.data(forKey: persistenceKey),
              data.count <= maximumPayloadBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == version,
              payload.records.count <= maximumRecordCount else { return [] }
        var seen = Set<String>()
        for record in payload.records {
            guard validComponent(record.logicalLocation),
                  validComponent(record.fileName),
                  record.sourceIdentity.isValid,
                  seen.insert(record.logicalID).inserted else { return [] }
        }
        return payload.records
    }

    @discardableResult
    private func commit(_ candidate: [Record]) -> Bool {
        guard candidate.count <= Self.maximumRecordCount,
              let data = try? JSONEncoder().encode(Payload(version: Self.version, records: candidate)),
              data.count <= Self.maximumPayloadBytes else { return false }
        defaults.set(data, forKey: Self.persistenceKey)
        guard defaults.data(forKey: Self.persistenceKey) == data else { return false }
        records = candidate
        revision &+= 1
        return true
    }

    private static func record(for song: MusicItem) -> Record? {
        let location = song.url.deletingLastPathComponent().lastPathComponent
        guard validComponent(location), validComponent(song.fileName),
              let identity = song.favoriteSourceIdentity, identity.isValid else { return nil }
        return Record(logicalLocation: location, fileName: song.fileName, sourceIdentity: identity)
    }

    private static func logicalID(for song: MusicItem) -> String {
        Record.makeLogicalID(song.url.deletingLastPathComponent().lastPathComponent, song.fileName)
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value == URL(fileURLWithPath: value).lastPathComponent
    }
}

struct MusicTrackTextPresentation {
    let title: String
    let artist: String?

    init(track: MusicItem) {
        let metadataTitle = track.metadata?.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataArtist = track.metadata?.artist?.trimmingCharacters(in: .whitespacesAndNewlines)

        title = metadataTitle.flatMap { $0.isEmpty ? nil : $0 } ?? track.fileName
        artist = metadataArtist.flatMap { $0.isEmpty ? nil : $0 }
    }
}

enum MusicLibrarySearch {
    static func filteredSongs(_ songs: [MusicItem], query: String) -> [MusicItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return songs }

        return songs.filter { song in
            let textPresentation = MusicTrackTextPresentation(track: song)
            return song.fileName.localizedCaseInsensitiveContains(query)
                || textPresentation.title.localizedCaseInsensitiveContains(query)
                || (textPresentation.artist?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
}

enum MusicLibraryFilter: String, CaseIterable, Codable {
    case all
    case favorites
    case recentlyPlayed

    @MainActor
    static func filteredSongs(
        _ songs: [MusicItem],
        selection: MusicLibraryFilter,
        favorites: MusicFavoritesStore,
        recentlyPlayed: MusicRecentlyPlayedStore? = nil,
        query: String
    ) -> [MusicItem] {
        let searchResults = MusicLibrarySearch.filteredSongs(songs, query: query)
        switch selection {
        case .all: return searchResults
        case .favorites: return searchResults.filter(favorites.isFavorite)
        case .recentlyPlayed:
            return recentlyPlayed?.orderedMatchingSongs(in: searchResults) ?? []
        }
    }
}

struct MusicLibraryFilterPreferenceStore {
    static let key = "MusicLibraryFilterPreferenceStore.selection"
    private static let version = 1
    let defaults: UserDefaults

    func load() -> MusicLibraryFilter {
        guard let payload = defaults.dictionary(forKey: Self.key),
              payload["version"] as? Int == Self.version,
              let rawValue = payload["selection"] as? String,
              let selection = MusicLibraryFilter(rawValue: rawValue) else { return .all }
        return selection
    }

    func save(_ selection: MusicLibraryFilter) {
        defaults.set(
            ["version": Self.version, "selection": selection.rawValue],
            forKey: Self.key
        )
    }
}
