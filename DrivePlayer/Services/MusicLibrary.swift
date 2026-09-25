import AVFoundation
import Combine
import Foundation

struct MusicLibraryPublication: Equatable, Sendable {
    let generation: Int
    let reconciliationSnapshot: MusicFavoritesReconciliationSnapshot
    let songs: [MusicItem]

    init(
        generation: Int,
        reconciliationSnapshot: MusicFavoritesReconciliationSnapshot,
        songs: [MusicItem] = []
    ) {
        self.generation = generation
        self.reconciliationSnapshot = reconciliationSnapshot
        self.songs = songs
    }

    static let initial = MusicLibraryPublication(generation: 0, reconciliationSnapshot: .unavailable, songs: [])
}

@MainActor
final class MusicLibrary: ObservableObject {
    struct ImportReport {
        let importedSongCount: Int
        let importedLyricCount: Int
        var importedCount: Int { importedSongCount + importedLyricCount }
        let failedFileNames: [String]
        let favoritesSnapshot: MusicFavoritesReconciliationSnapshot

        init(
            importedSongCount: Int,
            importedLyricCount: Int,
            failedFileNames: [String],
            favoritesSnapshot: MusicFavoritesReconciliationSnapshot = .unavailable
        ) {
            self.importedSongCount = importedSongCount
            self.importedLyricCount = importedLyricCount
            self.failedFileNames = failedFileNames
            self.favoritesSnapshot = favoritesSnapshot
        }
    }

    @Published private(set) var songs: [MusicItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var libraryErrorMessage: String?
    @Published private(set) var latestReconciliationPublication = MusicLibraryPublication.initial

    private let storage: MediaLibraryStorage
    private let metadataLoader: MusicMetadataLoader
    private let metadataSnapshotStore: MediaMetadataSnapshotStore
    private let durationLoader: @Sendable (URL) async -> TimeInterval?
    private let maximumConcurrentEnrichmentCount: Int
    private let lyricSidecarLoader: @Sendable (URL) async -> Data?
    private var refreshGeneration = 0

    init(
        storage: MediaLibraryStorage? = nil,
        metadataLoader: MusicMetadataLoader = MusicMetadataLoader(),
        metadataSnapshotStore: MediaMetadataSnapshotStore = .shared,
        durationLoader: @escaping @Sendable (URL) async -> TimeInterval? = { @Sendable url in
            await MusicLibrary.defaultDurationLoader(for: url)
        },
        maximumConcurrentEnrichmentCount: Int = 8,
        lyricSidecarLoader: (@Sendable (URL) async -> Data?)? = nil
    ) {
        let resolvedStorage = storage ?? .live()
        self.storage = resolvedStorage
        self.metadataLoader = metadataLoader
        self.metadataSnapshotStore = metadataSnapshotStore
        self.durationLoader = durationLoader
        self.maximumConcurrentEnrichmentCount = max(1, maximumConcurrentEnrichmentCount)
        let rootURL = resolvedStorage.rootURL
        let defaultSidecarLoader = BoundedLyricSidecarLoader(rootURL: rootURL)
        self.lyricSidecarLoader = lyricSidecarLoader ?? { url in
            await defaultSidecarLoader.load(for: url)
        }
    }

    @discardableResult
    func refresh() async -> MusicFavoritesReconciliationSnapshot {
        refreshGeneration += 1
        let generation = refreshGeneration
        latestReconciliationPublication = MusicLibraryPublication(
            generation: generation,
            reconciliationSnapshot: .unavailable,
            songs: []
        )
        isLoading = true
        libraryErrorMessage = nil
        defer {
            if generation == refreshGeneration {
                isLoading = false
            }
        }
        let revision = await metadataSnapshotStore.beginRefresh(for: .music)

        do {
            storage.migrateLegacyFiles()
            let urls = try storage.scan(kind: .audio)
            guard generation == refreshGeneration, !Task.isCancelled else { return .unavailable }
            let cheapSongs = urls.map {
                MusicItem(url: $0, duration: nil)
            }.sorted {
                $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending
            }
            latestReconciliationPublication = MusicLibraryPublication(
                generation: generation, reconciliationSnapshot: .unavailable, songs: cheapSongs
            )
            songs = cheapSongs

            let indexedSongs = await withTaskGroup(
                of: (Int, MusicItem, MediaMetadataSnapshotStore.MusicSnapshot)?.self,
                returning: [(Int, MusicItem, MediaMetadataSnapshotStore.MusicSnapshot)].self
            ) { group in
                var results: [(Int, MusicItem, MediaMetadataSnapshotStore.MusicSnapshot)] = []
                let initialTaskCount = min(maximumConcurrentEnrichmentCount, urls.count)
                var nextIndex = initialTaskCount

                for index in 0..<initialTaskCount {
                    let url = urls[index]
                    group.addTask { [metadataLoader, metadataSnapshotStore, durationLoader, lyricSidecarLoader] in
                        let sidecarData = await lyricSidecarLoader(url)
                        guard !Task.isCancelled else { return nil }
                        guard let result = await Self.enrich(
                            url: url,
                            sidecarData: sidecarData,
                            metadataLoader: metadataLoader,
                            metadataSnapshotStore: metadataSnapshotStore,
                            durationLoader: durationLoader
                        ) else { return nil }
                        return (index, result.song, result.snapshot)
                    }
                }

                while let result = await group.next() {
                    if let result {
                        results.append(result)
                    }
                    guard !Task.isCancelled, nextIndex < urls.count else { continue }
                    let index = nextIndex
                    let url = urls[index]
                    nextIndex += 1
                    group.addTask { [metadataLoader, metadataSnapshotStore, durationLoader, lyricSidecarLoader] in
                        let sidecarData = await lyricSidecarLoader(url)
                        guard !Task.isCancelled else { return nil }
                        guard let result = await Self.enrich(
                            url: url,
                            sidecarData: sidecarData,
                            metadataLoader: metadataLoader,
                            metadataSnapshotStore: metadataSnapshotStore,
                            durationLoader: durationLoader
                        ) else { return nil }
                        return (index, result.song, result.snapshot)
                    }
                }
                return results
            }
            guard !Task.isCancelled else { return .unavailable }
            let scannedSongs = indexedSongs
                .sorted { $0.0 < $1.0 }
                .map(\.1)

            let identitiesByURL = Dictionary(
                uniqueKeysWithValues: indexedSongs.compactMap { result in
                    result.1.favoriteSourceIdentity.map { (result.1.url.standardizedFileURL, $0) }
                }
            )
            let authoritativeSnapshot = MusicFavoritesReconciliationSnapshot(
                isAuthoritative: true,
                entries: urls.map { url in
                    MusicFavoritesReconciliationSnapshot.Entry(
                        logicalLocation: url.deletingLastPathComponent().lastPathComponent,
                        fileName: url.lastPathComponent,
                        sourceIdentity: identitiesByURL[url.standardizedFileURL]
                    )
                }
            )
            if generation == refreshGeneration, !Task.isCancelled {
                let cache = Dictionary(
                    uniqueKeysWithValues: indexedSongs.map { ($0.1.url, $0.2) }
                )
                await metadataSnapshotStore.replaceMusic(with: cache, revision: revision)
                guard generation == refreshGeneration, !Task.isCancelled else { return .unavailable }
                latestReconciliationPublication = MusicLibraryPublication(
                    generation: generation,
                    reconciliationSnapshot: authoritativeSnapshot,
                    songs: scannedSongs.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
                )
                songs = latestReconciliationPublication.songs
            }
            guard generation == refreshGeneration, !Task.isCancelled else { return .unavailable }
            return authoritativeSnapshot
        } catch {
            if generation == refreshGeneration {
                latestReconciliationPublication = MusicLibraryPublication(
                    generation: generation,
                    reconciliationSnapshot: .unavailable,
                    songs: []
                )
                songs = []
                libraryErrorMessage = "无法读取已导入的音乐，请稍后重试。"
            }
            return .unavailable
        }
    }

    func importSongs(from sourceURLs: [URL]) async -> ImportReport {
        var importedSongCount = 0
        var importedLyricCount = 0
        var failedFileNames: [String] = []

        for sourceURL in sourceURLs {
            guard let classification = storage.musicImportClassification(for: sourceURL) else {
                failedFileNames.append(displayName(for: sourceURL))
                continue
            }

            do {
                _ = try storage.importFile(from: sourceURL)
                switch classification {
                case .song:
                    importedSongCount += 1
                case .lyric:
                    importedLyricCount += 1
                }
            } catch {
                failedFileNames.append(displayName(for: sourceURL))
            }
        }

        let favoritesSnapshot = await refresh()
        return ImportReport(
            importedSongCount: importedSongCount,
            importedLyricCount: importedLyricCount,
            failedFileNames: failedFileNames,
            favoritesSnapshot: favoritesSnapshot
        )
    }

    @discardableResult
    func deleteSong(
        _ song: MusicItem,
        didDelete: @MainActor () throws -> Void = {}
    ) async throws -> MusicFavoritesReconciliationSnapshot {
        try storage.deleteFile(at: song.url)
        do {
            try didDelete()
        } catch {
            _ = await refresh()
            throw error
        }
        return await refresh()
    }

    private func displayName(for url: URL) -> String {
        url.lastPathComponent.isEmpty ? "未命名文件" : url.lastPathComponent
    }

    nonisolated private static func enrich(
        url: URL,
        sidecarData: Data?,
        metadataLoader: MusicMetadataLoader,
        metadataSnapshotStore: MediaMetadataSnapshotStore,
        durationLoader: @Sendable (URL) async -> TimeInterval?
    ) async -> (song: MusicItem, snapshot: MediaMetadataSnapshotStore.MusicSnapshot)? {
        for _ in 0..<2 {
            guard let fingerprint = await metadataSnapshotStore.sourceIdentity(for: url) else {
                return nil
            }
            let cached = await metadataSnapshotStore.musicSnapshot(for: url, matching: fingerprint)
            let baseMetadata: MusicMetadata
            let persistedMetadata: MusicMetadata?
            if let cachedMetadata = cached?.metadata {
                baseMetadata = cachedMetadata
                persistedMetadata = cachedMetadata
            } else {
                do {
                    let loaded = try await metadataLoader.load(
                        url: url,
                        fingerprint: MusicMetadataFileFingerprint(
                            fileSize: fingerprint.fileSize,
                            modificationDate: fingerprint.modificationDate,
                            contentSHA256Hex: fingerprint.contentSHA256Hex,
                            fileSystemIdentifier: fingerprint.fileSystemIdentifier,
                            fileObjectIdentifier: fingerprint.fileObjectIdentifier,
                            statusChangeSeconds: fingerprint.statusChangeSeconds,
                            statusChangeNanoseconds: fingerprint.statusChangeNanoseconds
                        )
                    )
                    baseMetadata = loaded
                    persistedMetadata = loaded
                } catch {
                    baseMetadata = MusicMetadataParser.parse([], fallbackFileName: url.lastPathComponent)
                    persistedMetadata = nil
                }
                guard let currentFingerprint = await metadataSnapshotStore.sourceIdentity(for: url) else {
                    return nil
                }
                guard currentFingerprint == fingerprint else { continue }
            }
            var metadata = baseMetadata
            if let sidecarData,
               let synchronizedLyrics = LRCSynchronizedLyricsDecoder.decode(sidecarData) {
                metadata = metadata.replacingSynchronizedLyrics(with: synchronizedLyrics)
            }
            let duration: TimeInterval?
            if let cachedDuration = cached?.duration {
                duration = cachedDuration
            } else {
                duration = await durationLoader(url)
                guard let currentFingerprint = await metadataSnapshotStore.sourceIdentity(for: url) else {
                    return nil
                }
                guard currentFingerprint == fingerprint else { continue }
            }
            guard let currentFingerprint = await metadataSnapshotStore.sourceIdentity(for: url) else {
                return nil
            }
            guard currentFingerprint == fingerprint else { continue }
            let validDuration = duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let song = MusicItem(
                url: url,
                duration: validDuration,
                metadata: metadata,
                favoriteSourceIdentity: MusicFavoriteSourceIdentity(
                    fileSize: fingerprint.fileSize,
                    contentSHA256Hex: fingerprint.contentSHA256Hex
                )
            )
            return (
                song,
                MediaMetadataSnapshotStore.MusicSnapshot(
                    fingerprint: fingerprint,
                    duration: validDuration,
                    metadata: persistedMetadata
                )
            )
        }
        return nil
    }

    nonisolated static func defaultDurationLoader(for url: URL) async -> TimeInterval? {
        do {
            let duration = try await AVURLAsset(url: url).load(.duration)
            let seconds = duration.seconds
            return seconds.isFinite && seconds >= 0 ? seconds : nil
        } catch {
            return nil
        }
    }
}
