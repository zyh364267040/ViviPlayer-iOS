import Combine
import CryptoKit
import Darwin
import Foundation

enum MusicPlaylistMemberPresentationState: Equatable {
    case playable
    case waitingForVerification
    case unavailable
}

struct MusicPlaylistMemberPresentation: Identifiable, Equatable {
    var id: MusicPlaylistMember { member }
    let member: MusicPlaylistMember
    let state: MusicPlaylistMemberPresentationState
    let playableSong: MusicItem?
    var removeIntent: MusicPlaylistRemoveActionIntent? = nil
}

struct MusicPlaylistRemoveActionIntent: Equatable {
    let id = UUID()
    let playlistID: UUID
    let storeRevision: Int
    let publicationGeneration: Int
    let member: MusicPlaylistMember
    let sourceURL: URL?
    fileprivate let sessionSourceIdentity: MusicPlaylistSessionSourceIdentity?
}

@MainActor
struct MusicPlaylistActionIntentConsumer {
    private var consumed = Set<UUID>()
    private(set) var lastFailure: MusicPlaylistMutationFailure?

    mutating func remove(
        _ intent: MusicPlaylistRemoveActionIntent,
        store: MusicPlaylistStore,
        publication: MusicLibraryPublication
    ) -> Bool {
        lastFailure = nil
        guard !consumed.contains(intent.id) else { lastFailure = .staleState; return false }
        guard store.revision == intent.storeRevision,
              publication.generation == intent.publicationGeneration else { lastFailure = .staleState; return false }
        guard intent.sourceURL == nil || MusicPlaylistSessionSourceIdentity.read(intent.sourceURL!) == intent.sessionSourceIdentity else { lastFailure = .replacedSource; return false }
        guard store.remove(intent.member, from: intent.playlistID, expectedRevision: intent.storeRevision) else { lastFailure = store.lastMutationFailure; return false }
        consumed.insert(intent.id)
        return true
    }
}

enum MusicPlaylistPresentation {
    static func rows(playlist: MusicPlaylist, library: [MusicItem]) -> [MusicPlaylistMemberPresentation] {
        MusicPlaylistLibraryIndex(library: library).memberRows(for: playlist)
    }
}

fileprivate struct MusicPlaylistSessionSourceIdentity: Codable, Equatable, Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
    let linkCount: UInt64

    static func read(_ url: URL) -> Self? {
        var status = stat()
        guard lstat(url.standardizedFileURL.path, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else { return nil }
        return Self(device: status.st_dev, inode: status.st_ino, size: status.st_size,
                    modificationSeconds: Int64(status.st_mtimespec.tv_sec),
                    modificationNanoseconds: Int64(status.st_mtimespec.tv_nsec),
                    changeSeconds: Int64(status.st_ctimespec.tv_sec),
                    changeNanoseconds: Int64(status.st_ctimespec.tv_nsec),
                    linkCount: UInt64(status.st_nlink))
    }
}

enum MusicPlaylistAuthenticatedSourceValidator {
    private static let windowBytes = 64 * 1_024

    static func fingerprint(at url: URL) -> MusicFavoriteSourceIdentity? {
        validate(at: url, expected: nil)?.identity
    }

    static func matches(_ expected: MusicFavoriteSourceIdentity, at url: URL) -> Bool {
        validate(at: url, expected: expected) != nil
    }

    private static func validate(
        at url: URL,
        expected: MusicFavoriteSourceIdentity?
    ) -> (identity: MusicFavoriteSourceIdentity, session: MusicPlaylistSessionSourceIdentity)? {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0 else { return nil }
        let size = UInt64(before.st_size), window = UInt64(windowBytes)
        let offsets = Set([UInt64(0), size > window ? (size - window) / 2 : 0, size > window ? size - window : 0]).sorted()
        var hasher = SHA256()
        for offset in offsets {
            guard lseek(descriptor, off_t(offset), SEEK_SET) >= 0 else { return nil }
            let count = Int(min(window, size - offset)); var data = Data(count: count)
            let readCount = data.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, count) }
            guard readCount == count else { return nil }
            var encodedOffset = offset.bigEndian
            withUnsafeBytes(of: &encodedOffset) { hasher.update(data: Data($0)) }
            hasher.update(data: data)
        }
        var after = stat(), path = stat()
        guard fstat(descriptor, &after) == 0, lstat(url.path, &path) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_dev == path.st_dev, after.st_ino == path.st_ino,
              after.st_size == path.st_size,
              after.st_mtimespec.tv_sec == path.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == path.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == path.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == path.st_ctimespec.tv_nsec,
              after.st_nlink == 1, path.st_nlink == 1 else { return nil }
        let identity = MusicFavoriteSourceIdentity(
            fileSize: Int64(after.st_size),
            contentSHA256Hex: hasher.finalize().map { String(format: "%02x", $0) }.joined()
        )
        guard expected == nil || expected == identity,
              let session = MusicPlaylistSessionSourceIdentity.read(url),
              session.device == after.st_dev, session.inode == after.st_ino,
              session.size == after.st_size,
              session.modificationSeconds == Int64(after.st_mtimespec.tv_sec),
              session.modificationNanoseconds == Int64(after.st_mtimespec.tv_nsec),
              session.changeSeconds == Int64(after.st_ctimespec.tv_sec),
              session.changeNanoseconds == Int64(after.st_ctimespec.tv_nsec) else { return nil }
        return (identity, session)
    }
}

struct MusicPlaylistPendingAddIntent {
    let playlistID: UUID
    let storeRevision: Int
    let logicalLocation: String
    let fileName: String
    let sourceURL: URL
    fileprivate let sessionSourceIdentity: MusicPlaylistSessionSourceIdentity

    init?(song: MusicItem, playlistID: UUID, storeRevision: Int) {
        guard song.favoriteSourceIdentity == nil,
              let identity = MusicPlaylistSessionSourceIdentity.read(song.url) else { return nil }
        self.playlistID = playlistID
        self.storeRevision = storeRevision
        logicalLocation = song.url.deletingLastPathComponent().lastPathComponent
        fileName = song.fileName
        sourceURL = song.url.standardizedFileURL
        sessionSourceIdentity = identity
    }

    var accessibilityValue: String { "等待验证" }

    fileprivate var logicalID: String { "\(logicalLocation)\u{0}\(fileName)" }

    fileprivate var stableKey: MusicPlaylistPendingAddKey {
        MusicPlaylistPendingAddKey(
            logicalLocation: logicalLocation,
            fileName: fileName,
            sourceURL: sourceURL,
            sessionSourceIdentity: sessionSourceIdentity
        )
    }

    fileprivate var sessionSourceIsCurrent: Bool {
        MusicPlaylistSessionSourceIdentity.read(sourceURL) == sessionSourceIdentity
    }
}

fileprivate struct MusicPlaylistPendingAddKey: Hashable, Sendable {
    let logicalLocation: String
    let fileName: String
    let sourceURL: URL
    let sessionSourceIdentity: MusicPlaylistSessionSourceIdentity
}

fileprivate struct MusicPlaylistPendingRowKey: Hashable {
    let logicalID: String
    let sourceURL: URL
}

enum MusicPlaylistPendingAddResolution {
    case success(songID: String)
    case failure(songID: String, reason: MusicPlaylistMutationFailure)
}

enum MusicPlaylistAddRowState: Equatable {
    case added
    case available
    case waitingForVerification
    case requestedWaiting

    var accessibilityValue: String {
        switch self {
        case .added: "已添加"
        case .available: "未添加"
        case .waitingForVerification: "等待验证"
        case .requestedWaiting: "等待验证"
        }
    }
}

struct MusicPlaylistAddRow: Identifiable, Equatable {
    var id: String { song.id }
    let song: MusicItem
    let state: MusicPlaylistAddRowState
    var actionIntent: MusicPlaylistAuthenticatedAddIntent? = nil
}

struct MusicPlaylistAuthenticatedAddIntent: Equatable {
    let id = UUID()
    let playlistID: UUID
    let storeRevision: Int
    let publicationGeneration: Int
    let song: MusicItem
    fileprivate let sessionSourceIdentity: MusicPlaylistSessionSourceIdentity

    init?(song: MusicItem, playlistID: UUID, storeRevision: Int, publicationGeneration: Int) {
        guard song.favoriteSourceIdentity?.isValid == true,
              let session = MusicPlaylistSessionSourceIdentity.read(song.url) else { return nil }
        self.playlistID = playlistID
        self.storeRevision = storeRevision
        self.publicationGeneration = publicationGeneration
        self.song = song
        sessionSourceIdentity = session
    }
}

struct MusicPlaylistAccessibilityDescriptor: Equatable {
    let identifier: String
    let label: String
    let value: String?
    let isSelected: Bool
    let isDestructive: Bool
}

enum MusicPlaylistUIModel {
    static let listEmptyTitle = "还没有播放列表"
    static let detailEmptyTitle = "播放列表为空"
    static let deletionMessage = "音乐文件不会被删除。"
    static let allowsReordering = false

    static let open = MusicPlaylistAccessibilityDescriptor(
        identifier: "music-playlists-open", label: "播放列表", value: nil,
        isSelected: false, isDestructive: false
    )
    static let create = MusicPlaylistAccessibilityDescriptor(
        identifier: "music-playlist-create", label: "新建", value: nil,
        isSelected: false, isDestructive: false
    )
    static let nameField = MusicPlaylistAccessibilityDescriptor(
        identifier: "music-playlist-name-field", label: "名称", value: nil,
        isSelected: false, isDestructive: false
    )

    static func add(_ row: MusicPlaylistAddRow) -> MusicPlaylistAccessibilityDescriptor {
        MusicPlaylistAccessibilityDescriptor(
            identifier: "music-playlist-add-\(row.song.id)",
            label: row.song.metadata?.title ?? row.song.fileName,
            value: row.state.accessibilityValue,
            isSelected: row.state == .added,
            isDestructive: false
        )
    }

    static func member(_ row: MusicPlaylistMemberPresentation) -> MusicPlaylistAccessibilityDescriptor {
        let value = switch row.state {
        case .playable: "可播放"
        case .waitingForVerification: "正在验证"
        case .unavailable: "暂不可用"
        }
        return MusicPlaylistAccessibilityDescriptor(
            identifier: "music-playlist-play-\(row.member.fileName)",
            label: row.playableSong?.metadata?.title ?? row.member.fileName,
            value: value,
            isSelected: false,
            isDestructive: false
        )
    }

    static func action(_ kind: ActionKind, fileName: String? = nil) -> MusicPlaylistAccessibilityDescriptor {
        switch kind {
        case .add: .init(identifier: "music-playlist-add", label: "添加音乐", value: nil, isSelected: false, isDestructive: false)
        case .rename: .init(identifier: "music-playlist-rename", label: "重命名", value: nil, isSelected: false, isDestructive: false)
        case .delete: .init(identifier: "music-playlist-delete", label: "删除播放列表", value: nil, isSelected: false, isDestructive: true)
        case .remove: .init(identifier: "music-playlist-remove-\(fileName ?? "")", label: "移除", value: nil, isSelected: false, isDestructive: true)
        }
    }

    enum ActionKind { case add, rename, delete, remove }
}

@MainActor
struct MusicPlaylistUIActions {
    let store: MusicPlaylistStore
    let playback: MusicPlaybackManager

    func create(name: String) -> MusicPlaylist? { store.create(name: name) }
    func captureIntent(for id: UUID) -> MusicPlaylistIntent? { store.intent(for: id) }
    func rename(_ intent: MusicPlaylistIntent, name: String) -> Bool { store.rename(intent, name: name) }

    func delete(_ intent: MusicPlaylistIntent, confirmed: Bool) -> Bool {
        guard confirmed, store.delete(intent) else { return false }
        playback.playlistDeleted(id: intent.playlistID)
        return true
    }

    func remove(_ member: MusicPlaylistMember, from id: UUID, expectedRevision: Int) -> Bool {
        store.remove(member, from: id, expectedRevision: expectedRevision)
    }
}

struct MusicPlaylistLibraryIndex {
    private struct SessionKey: Hashable {
        let logicalID: String
        let sourceURL: URL
    }

    private let library: [MusicItem]
    private let logicalIDsWithUnknownIdentity: Set<String>
    private let byMember: [MusicPlaylistMember: MusicItem]
    private let bySessionKey: [SessionKey: MusicItem]
    private let operation: () -> Void

    var authenticatedSongs: [MusicItem] {
        library.filter { $0.favoriteSourceIdentity?.isValid == true }
    }

    init(library: [MusicItem], operation: @escaping () -> Void = {}) {
        self.library = library
        self.operation = operation
        var unknown = Set<String>()
        var authenticated: [MusicPlaylistMember: MusicItem] = [:]
        var sessionItems: [SessionKey: MusicItem] = [:]
        for song in library {
            operation()
            let id = Self.logicalID(song)
            let sessionKey = SessionKey(logicalID: id, sourceURL: song.url.standardizedFileURL)
            if song.favoriteSourceIdentity == nil { unknown.insert(id) }
            else if song.favoriteSourceIdentity?.isValid == true, sessionItems[sessionKey] == nil {
                sessionItems[sessionKey] = song
            }
            if let member = MusicPlaylistMember(song: song), authenticated[member] == nil {
                authenticated[member] = song
            }
        }
        logicalIDsWithUnknownIdentity = unknown
        byMember = authenticated
        bySessionKey = sessionItems
    }

    func memberRows(
        for playlist: MusicPlaylist,
        storeRevision: Int? = nil,
        publicationGeneration: Int? = nil
    ) -> [MusicPlaylistMemberPresentation] {
        playlist.members.map { member in
            operation()
            if let song = byMember[member] {
                let intent: MusicPlaylistRemoveActionIntent? = storeRevision.flatMap { revision in
                    publicationGeneration.flatMap { generation in
                        MusicPlaylistSessionSourceIdentity.read(song.url).map {
                            MusicPlaylistRemoveActionIntent(
                                playlistID: playlist.id, storeRevision: revision,
                                publicationGeneration: generation, member: member,
                                sourceURL: song.url.standardizedFileURL, sessionSourceIdentity: $0
                            )
                        }
                    }
                }
                return MusicPlaylistMemberPresentation(member: member, state: .playable, playableSong: song, removeIntent: intent)
            }
            let state: MusicPlaylistMemberPresentationState = logicalIDsWithUnknownIdentity.contains(member.logicalID)
                ? .waitingForVerification : .unavailable
            let intent = storeRevision.flatMap { revision in publicationGeneration.map {
                MusicPlaylistRemoveActionIntent(
                    playlistID: playlist.id, storeRevision: revision, publicationGeneration: $0,
                    member: member, sourceURL: nil, sessionSourceIdentity: nil
                )
            } }
            return MusicPlaylistMemberPresentation(member: member, state: state, playableSong: nil, removeIntent: intent)
        }
    }

    func playableSongs(for playlist: MusicPlaylist) -> [MusicItem] {
        memberRows(for: playlist).compactMap(\.playableSong)
    }

    @MainActor
    func addRows(
        for playlist: MusicPlaylist,
        requestedBy batch: MusicPlaylistPendingAddBatch? = nil,
        storeRevision: Int? = nil,
        publicationGeneration: Int? = nil
    ) -> [MusicPlaylistAddRow] {
        let logicalMembers = Set(playlist.members.map(\.logicalID))
        return library.map { song in
            operation()
            let state: MusicPlaylistAddRowState
            if logicalMembers.contains(Self.logicalID(song)) { state = .added }
            else if batch?.isRequested(song) == true { state = .requestedWaiting }
            else if song.favoriteSourceIdentity?.isValid == true { state = .available }
            else { state = .waitingForVerification }
            let intent = storeRevision.flatMap { revision in
                publicationGeneration.flatMap {
                    MusicPlaylistAuthenticatedAddIntent(song: song, playlistID: playlist.id, storeRevision: revision, publicationGeneration: $0)
                }
            }
            return MusicPlaylistAddRow(song: song, state: state, actionIntent: state == .available ? intent : nil)
        }
    }

    fileprivate func authenticatedSong(for intent: MusicPlaylistPendingAddIntent) -> MusicItem? {
        operation()
        return bySessionKey[SessionKey(logicalID: intent.logicalID, sourceURL: intent.sourceURL)]
    }

    private static func logicalID(_ song: MusicItem) -> String {
        "\(song.url.deletingLastPathComponent().lastPathComponent)\u{0}\(song.fileName)"
    }
}

@MainActor
struct MusicPlaylistPendingAddBatch {
    private struct Request {
        let intent: MusicPlaylistPendingAddIntent
        let ordinal: Int
    }

    let playlistID: UUID
    private let generationBaseRevision: Int
    private(set) var expectedRevision: Int
    private(set) var latestLibraryGeneration: Int
    private var latestGenerationWasAuthoritative = false
    private var intents: [Request] = []
    private var nextOrdinal = 0
    private var baseInsertionBoundary: Int?
    private var keys = Set<MusicPlaylistPendingAddKey>()
    private var requestedRows = Set<MusicPlaylistPendingRowKey>()
    private var consumedActionIDs = Set<UUID>()
    private var reservedAuthenticatedSources = Set<URL>()
    private(set) var isCancelled = false
    private(set) var lastFailure: MusicPlaylistMutationFailure?
    private let preCommitSourceValidationHook: (() -> Void)?

    init(
        playlistID: UUID,
        storeRevision: Int,
        libraryGeneration: Int = 0,
        preCommitSourceValidationHook: (() -> Void)? = nil
    ) {
        self.playlistID = playlistID
        generationBaseRevision = storeRevision
        expectedRevision = storeRevision
        latestLibraryGeneration = libraryGeneration
        self.preCommitSourceValidationHook = preCommitSourceValidationHook
    }

    var isEmpty: Bool { intents.isEmpty }

    mutating func request(_ song: MusicItem) -> Bool {
        guard !isCancelled,
              let intent = MusicPlaylistPendingAddIntent(song: song, playlistID: playlistID, storeRevision: expectedRevision),
              keys.insert(intent.stableKey).inserted else { return false }
        intents.append(Request(intent: intent, ordinal: nextOrdinal))
        nextOrdinal += 1
        requestedRows.insert(Self.rowKey(intent))
        return true
    }

    mutating func commitAuthenticated(
        _ action: MusicPlaylistAuthenticatedAddIntent,
        store: MusicPlaylistStore,
        publication: MusicLibraryPublication,
        sourceFingerprintValidated: Bool = false,
        reservedOrdinal: Int? = nil
    ) -> Bool {
        lastFailure = nil
        guard !isCancelled, action.playlistID == playlistID else { lastFailure = .staleState; return false }
        guard
              (action.storeRevision == generationBaseRevision || action.storeRevision == expectedRevision),
              store.revision == expectedRevision else { lastFailure = .staleState; return false }
        guard
              action.publicationGeneration == publication.generation,
              publication.generation >= latestLibraryGeneration,
              publication.reconciliationSnapshot.isAuthoritative,
              publication.reconciliationSnapshot.entries.contains(where: {
                  $0.logicalLocation == action.song.url.deletingLastPathComponent().lastPathComponent
                      && $0.fileName == action.song.fileName
                      && $0.sourceIdentity == action.song.favoriteSourceIdentity
              }) else { lastFailure = .replacedSource; return false }
        guard !consumedActionIDs.contains(action.id) else { lastFailure = .staleState; return false }
        if !sourceFingerprintValidated { preCommitSourceValidationHook?() }
        guard MusicPlaylistSessionSourceIdentity.read(action.song.url) == action.sessionSourceIdentity,
              (sourceFingerprintValidated || MusicPlaylistAuthenticatedSourceValidator.matches(action.song.favoriteSourceIdentity!, at: action.song.url)) else { lastFailure = .replacedSource; return false }
        if baseInsertionBoundary == nil { baseInsertionBoundary = store.playlist(id: playlistID)?.members.count }
        let ordinal = reservedOrdinal ?? nextOrdinal
        guard store.insert(action.song, into: playlistID, at: (baseInsertionBoundary ?? 0) + ordinal, expectedRevision: expectedRevision) else { lastFailure = store.lastMutationFailure; return false }
        if reservedOrdinal == nil { nextOrdinal += 1 }
        expectedRevision = store.revision
        latestLibraryGeneration = max(latestLibraryGeneration, publication.generation)
        latestGenerationWasAuthoritative = true
        consumedActionIDs.insert(action.id)
        return true
    }

    mutating func reserveAuthenticated(_ action: MusicPlaylistAuthenticatedAddIntent) -> Int? {
        let source = action.song.url.standardizedFileURL
        guard !isCancelled, reservedAuthenticatedSources.insert(source).inserted else { return nil }
        let ordinal = nextOrdinal
        nextOrdinal += 1
        return ordinal
    }

    mutating func commitAuthenticatedOffMain(
        _ action: MusicPlaylistAuthenticatedAddIntent,
        store: MusicPlaylistStore,
        publication: MusicLibraryPublication
    ) async -> Bool {
        preCommitSourceValidationHook?()
        let valid = await Task.detached(priority: .userInitiated) {
            MusicPlaylistAuthenticatedSourceValidator.matches(action.song.favoriteSourceIdentity!, at: action.song.url)
        }.value
        guard valid else { lastFailure = .replacedSource; return false }
        guard MusicPlaylistSessionSourceIdentity.read(action.song.url) == action.sessionSourceIdentity else {
            lastFailure = .replacedSource
            return false
        }
        return commitAuthenticated(action, store: store, publication: publication, sourceFingerprintValidated: true)
    }

    func state(for song: MusicItem) -> MusicPlaylistAddRowState? {
        isRequested(song) ? .requestedWaiting : nil
    }

    fileprivate func isRequested(_ song: MusicItem) -> Bool {
        requestedRows.contains(Self.rowKey(song))
    }

    mutating func cancel() {
        isCancelled = true
        intents.removeAll()
        keys.removeAll()
        requestedRows.removeAll()
    }

    @discardableResult
    mutating func resolve(using index: MusicPlaylistLibraryIndex, store: MusicPlaylistStore, isAuthoritative: Bool) -> [MusicPlaylistPendingAddResolution] {
        resolve(
            using: index,
            store: store,
            publication: MusicLibraryPublication(
                generation: latestLibraryGeneration + 1,
                reconciliationSnapshot: isAuthoritative
                    ? MusicFavoritesReconciliationSnapshot(songs: index.authenticatedSongs)
                    : .unavailable
            )
        )
    }

    @discardableResult
    mutating func resolve(
        using index: MusicPlaylistLibraryIndex,
        store: MusicPlaylistStore,
        publication: MusicLibraryPublication
    ) -> [MusicPlaylistPendingAddResolution] {
        resolve(using: index, store: store, publication: publication, prevalidatedKeys: nil)
    }

    @discardableResult
    fileprivate mutating func resolve(
        using index: MusicPlaylistLibraryIndex,
        store: MusicPlaylistStore,
        publication: MusicLibraryPublication,
        prevalidatedKeys: Set<MusicPlaylistPendingAddKey>?
    ) -> [MusicPlaylistPendingAddResolution] {
        guard publication.generation > latestLibraryGeneration
                || (publication.generation == latestLibraryGeneration
                    && publication.reconciliationSnapshot.isAuthoritative
                    && !latestGenerationWasAuthoritative) else { return [] }
        latestLibraryGeneration = publication.generation
        latestGenerationWasAuthoritative = publication.reconciliationSnapshot.isAuthoritative
        guard !isCancelled, store.revision == expectedRevision, store.playlist(id: playlistID) != nil else {
            let results = intents.map {
                MusicPlaylistPendingAddResolution.failure(songID: $0.intent.fileName, reason: .staleState)
            }
            cancel()
            return results
        }
        if baseInsertionBoundary == nil {
            baseInsertionBoundary = store.playlist(id: playlistID)?.members.count
        }
        var authoritativeLogicalIDs = Set<String>()
        var authoritativeIdentities: [String: MusicFavoriteSourceIdentity] = [:]
        if publication.reconciliationSnapshot.isAuthoritative {
            for entry in publication.reconciliationSnapshot.entries {
                let logicalID = "\(entry.logicalLocation)\u{0}\(entry.fileName)"
                guard authoritativeLogicalIDs.insert(logicalID).inserted else { return [] }
                if let identity = entry.sourceIdentity { authoritativeIdentities[logicalID] = identity }
            }
        }
        var results: [MusicPlaylistPendingAddResolution] = []
        var requestIndex = 0
        while requestIndex < intents.count {
            let request = intents[requestIndex]
            let intent = request.intent
            guard intent.sessionSourceIsCurrent else {
                discard(at: requestIndex)
                results.append(.failure(songID: intent.fileName, reason: .replacedSource))
                continue
            }
            if publication.reconciliationSnapshot.isAuthoritative,
               let song = index.authenticatedSong(for: intent),
               authoritativeIdentities[intent.logicalID] == song.favoriteSourceIdentity {
                preCommitSourceValidationHook?()
                guard intent.sessionSourceIsCurrent,
                      (prevalidatedKeys?.contains(intent.stableKey)
                        ?? MusicPlaylistAuthenticatedSourceValidator.matches(song.favoriteSourceIdentity!, at: song.url)) else {
                    discard(at: requestIndex)
                    results.append(.failure(songID: intent.fileName, reason: .replacedSource))
                    continue
                }
                let inserted = store.insert(
                    song,
                    into: playlistID,
                    at: (baseInsertionBoundary ?? 0) + request.ordinal,
                    expectedRevision: expectedRevision
                )
                if inserted { expectedRevision = store.revision }
                discard(at: requestIndex)
                results.append(inserted
                    ? .success(songID: intent.fileName)
                    : .failure(songID: intent.fileName, reason: store.lastMutationFailure ?? .persistenceFailure))
                continue
            }
            if publication.reconciliationSnapshot.isAuthoritative,
               authoritativeIdentities[intent.logicalID] != nil {
                discard(at: requestIndex)
                results.append(.failure(songID: intent.fileName, reason: .replacedSource))
                continue
            }
            if publication.reconciliationSnapshot.isAuthoritative
                && !authoritativeLogicalIDs.contains(intent.logicalID) {
                discard(at: requestIndex)
                results.append(.failure(songID: intent.fileName, reason: .unavailableSource))
                continue
            }
            requestIndex += 1
        }
        return results
    }

    fileprivate func validationCandidates(
        using index: MusicPlaylistLibraryIndex,
        publication: MusicLibraryPublication
    ) -> [(MusicPlaylistPendingAddKey, MusicFavoriteSourceIdentity, URL)] {
        guard publication.reconciliationSnapshot.isAuthoritative else { return [] }
        var identities: [String: MusicFavoriteSourceIdentity] = [:]
        var logicalIDs = Set<String>()
        for entry in publication.reconciliationSnapshot.entries {
            let logicalID = "\(entry.logicalLocation)\u{0}\(entry.fileName)"
            guard logicalIDs.insert(logicalID).inserted else { return [] }
            if let identity = entry.sourceIdentity { identities[logicalID] = identity }
        }
        return intents.compactMap { request in
            guard let song = index.authenticatedSong(for: request.intent),
                  identities[request.intent.logicalID] == song.favoriteSourceIdentity else { return nil }
            return (request.intent.stableKey, song.favoriteSourceIdentity!, song.url)
        }
    }

    private mutating func discard(at index: Int) {
        guard intents.indices.contains(index) else { return }
        let intent = intents.remove(at: index).intent
        keys.remove(intent.stableKey)
        requestedRows.remove(Self.rowKey(intent))
    }

    private static func rowKey(_ song: MusicItem) -> MusicPlaylistPendingRowKey {
        MusicPlaylistPendingRowKey(
            logicalID: "\(song.url.deletingLastPathComponent().lastPathComponent)\u{0}\(song.fileName)",
            sourceURL: song.url.standardizedFileURL
        )
    }

    private static func rowKey(_ intent: MusicPlaylistPendingAddIntent) -> MusicPlaylistPendingRowKey {
        MusicPlaylistPendingRowKey(logicalID: intent.logicalID, sourceURL: intent.sourceURL)
    }
}

@MainActor
enum MusicPlaylistAddWorkOutcome: Equatable {
    case success(songID: String, generation: Int)
    case failure(songID: String, reason: MusicPlaylistMutationFailure, generation: Int)
}

@MainActor
final class MusicPlaylistAddCoordinator: ObservableObject {
    typealias FingerprintValidator = @Sendable (MusicItem) async -> Bool

    private struct Work {
        let id: UUID
        let action: MusicPlaylistAuthenticatedAddIntent
        let publication: MusicLibraryPublication
        let ordinal: Int
        var validationResult: Bool?
    }

    private(set) var batch: MusicPlaylistPendingAddBatch
    private(set) var operationGeneration = 0
    private(set) var isActive = true
    private var latestPublicationGeneration: Int
    private var work: [Work] = []
    private var validationTasks: [UUID: Task<Void, Never>] = [:]
    private let validator: FingerprintValidator
    private let playlistID: UUID
    @Published private(set) var changeGeneration = 0
    @Published private(set) var outcomeGeneration = 0
    private var outcomes: [MusicPlaylistAddWorkOutcome] = []
    private var outcomeWaiter: CheckedContinuation<MusicPlaylistAddWorkOutcome, Never>?

    init(
        playlistID: UUID,
        storeRevision: Int,
        libraryGeneration: Int,
        validator: @escaping FingerprintValidator = { song in
            await Task.detached(priority: .userInitiated) {
                guard let identity = song.favoriteSourceIdentity else { return false }
                return MusicPlaylistAuthenticatedSourceValidator.matches(identity, at: song.url)
            }.value
        }
    ) {
        self.playlistID = playlistID
        latestPublicationGeneration = libraryGeneration
        batch = MusicPlaylistPendingAddBatch(
            playlistID: playlistID,
            storeRevision: storeRevision,
            libraryGeneration: libraryGeneration
        )
        self.validator = validator
    }

    var expectedRevision: Int { batch.expectedRevision }
    var lastFailure: MusicPlaylistMutationFailure? { batch.lastFailure }
    var pendingWorkCount: Int { work.count }
    var hasPendingRequests: Bool { !work.isEmpty || !batch.isEmpty }

    func consumeOutcome() -> MusicPlaylistAddWorkOutcome? {
        guard !outcomes.isEmpty else { return nil }
        return outcomes.removeFirst()
    }

    func nextOutcome() async -> MusicPlaylistAddWorkOutcome {
        if let outcome = consumeOutcome() { return outcome }
        return await withCheckedContinuation { outcomeWaiter = $0 }
    }

    @discardableResult
    func request(_ song: MusicItem) -> Bool {
        let accepted = isActive && batch.request(song)
        if accepted { changeGeneration &+= 1 }
        return accepted
    }

    @discardableResult
    func enqueue(
        _ action: MusicPlaylistAuthenticatedAddIntent,
        store: MusicPlaylistStore,
        publication: MusicLibraryPublication
    ) -> Bool {
        guard isActive, publication.generation == latestPublicationGeneration,
              let ordinal = batch.reserveAuthenticated(action) else { return false }
        let id = UUID()
        work.append(Work(id: id, action: action, publication: publication, ordinal: ordinal, validationResult: nil))
        let generation = operationGeneration
        validationTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            let valid = await self.validator(action.song)
            guard !Task.isCancelled, self.isActive, self.operationGeneration == generation else { return }
            self.validationTasks[id] = nil
            guard let index = self.work.firstIndex(where: { $0.id == id }) else { return }
            self.work[index].validationResult = valid
            self.commitReadyWork(store: store, generation: generation)
        }
        changeGeneration &+= 1
        return true
    }

    func resolve(using index: MusicPlaylistLibraryIndex, store: MusicPlaylistStore, publication: MusicLibraryPublication) {
        guard isActive else { return }
        guard publication.generation >= latestPublicationGeneration else { return }
        latestPublicationGeneration = publication.generation
        let candidates = batch.validationCandidates(using: index, publication: publication)
        guard !candidates.isEmpty else {
            publish(batch.resolve(using: index, store: store, publication: publication, prevalidatedKeys: []))
            changeGeneration &+= 1
            return
        }
        let id = UUID(), generation = operationGeneration
        validationTasks[id] = Task { @MainActor [weak self] in
            let validKeys: Set<MusicPlaylistPendingAddKey> = await Task.detached(priority: .userInitiated) {
                Set<MusicPlaylistPendingAddKey>(candidates.compactMap { key, identity, url in
                    guard MusicPlaylistAuthenticatedSourceValidator.matches(identity, at: url) else { return nil }
                    return key
                })
            }.value
            guard let self else { return }
            self.validationTasks[id] = nil
            guard !Task.isCancelled, self.isActive,
                  self.operationGeneration == generation,
                  self.latestPublicationGeneration == publication.generation else { return }
            let resolutions = self.batch.resolve(
                using: index, store: store, publication: publication,
                prevalidatedKeys: validKeys
            )
            self.publish(resolutions)
            self.changeGeneration &+= 1
        }
    }

    func cancel() {
        operationGeneration &+= 1
        isActive = false
        validationTasks.values.forEach { $0.cancel() }
        validationTasks.removeAll()
        work.removeAll()
        batch.cancel()
        changeGeneration &+= 1
    }

    func reset(storeRevision: Int, libraryGeneration: Int) {
        cancel()
        batch = MusicPlaylistPendingAddBatch(
            playlistID: playlistID,
            storeRevision: storeRevision,
            libraryGeneration: libraryGeneration
        )
        latestPublicationGeneration = libraryGeneration
        isActive = true
        changeGeneration &+= 1
    }

    private func commitReadyWork(store: MusicPlaylistStore, generation: Int) {
        while isActive, operationGeneration == generation,
              let result = work.first?.validationResult {
            let next = work.removeFirst()
            if result, next.publication.generation == latestPublicationGeneration {
                let committed = batch.commitAuthenticated(
                    next.action,
                    store: store,
                    publication: next.publication,
                    sourceFingerprintValidated: true,
                    reservedOrdinal: next.ordinal
                )
                publish(committed
                    ? .success(songID: next.action.song.id, generation: generation)
                    : .failure(songID: next.action.song.id, reason: batch.lastFailure ?? .persistenceFailure, generation: generation))
            } else if !result {
                publish(.failure(songID: next.action.song.id, reason: .replacedSource, generation: generation))
            } else {
                publish(.failure(songID: next.action.song.id, reason: .staleState, generation: generation))
            }
            changeGeneration &+= 1
        }
    }

    private func publish(_ outcome: MusicPlaylistAddWorkOutcome) {
        outcomeGeneration &+= 1
        if let waiter = outcomeWaiter {
            outcomeWaiter = nil
            waiter.resume(returning: outcome)
        } else {
            outcomes.append(outcome)
        }
    }

    private func publish(_ resolutions: [MusicPlaylistPendingAddResolution]) {
        for resolution in resolutions {
            switch resolution {
            case let .success(songID):
                publish(.success(songID: songID, generation: operationGeneration))
            case let .failure(songID, reason):
                publish(.failure(songID: songID, reason: reason, generation: operationGeneration))
            }
        }
    }
}

struct MusicPlaylistMember: Codable, Equatable, Hashable {
    let logicalLocation: String
    let fileName: String
    let sourceIdentity: MusicFavoriteSourceIdentity

    init?(song: MusicItem) {
        let location = song.url.deletingLastPathComponent().lastPathComponent
        guard !location.isEmpty, !song.fileName.isEmpty,
              let identity = song.favoriteSourceIdentity, identity.isValid else { return nil }
        logicalLocation = location
        fileName = song.fileName
        sourceIdentity = identity
    }

    var logicalID: String { "\(logicalLocation)\u{0}\(fileName)" }
}

struct MusicPlaylist: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    fileprivate(set) var members: [MusicPlaylistMember]
}

struct MusicPlaylistIntent: Equatable {
    let playlistID: UUID
    let storeRevision: Int
}

struct MusicPlaylistMemberIntent: Equatable {
    let playlistID: UUID
    let storeRevision: Int
    let member: MusicPlaylistMember
}

enum MusicPlaylistReconciliationOutcome: Equatable {
    case noChange
    case persisted
    case repairRequired
}

enum MusicPlaylistDeletionRepairMode: String, Codable, Equatable {
    case rollback
    case finalize
}

enum MusicPlaylistDeletionPreparation: Equatable {
    case noPlaylistWork
    case journalPrepared
    case failed
}

enum MusicPlaylistMutationFailure: Equatable {
    case invalidName, playlistLimit, memberLimit, totalLimit, payloadLimit
    case staleState, unavailableSource, replacedSource, logicalConflict
    case persistenceFailure, readbackFailure, repairRequired, notFound

    var message: String {
        switch self {
        case .invalidName: "请输入有效的播放列表名称。"
        case .playlistLimit: "播放列表数量已达上限。"
        case .memberLimit, .totalLimit: "播放列表曲目已达上限。"
        case .payloadLimit: "播放列表数据过大，请移除部分内容后重试。"
        case .staleState: "播放列表已更改，请刷新后重试。"
        case .unavailableSource, .replacedSource: "音乐来源已变更，请刷新后重试。"
        case .logicalConflict: "同一位置的音乐已在播放列表中。"
        case .persistenceFailure, .readbackFailure, .repairRequired: "无法保存更改，请重试。"
        case .notFound: "播放列表或曲目已不存在，请刷新。"
        }
    }
}

struct MusicPlaylistMutationFeedback: Identifiable, Equatable {
    let id = UUID()
    let failure: MusicPlaylistMutationFailure
    var message: String { failure.message }
    let accessibilityIdentifier = "music-playlist-mutation-failure"
    var accessibilityValue: String { message }
}

@MainActor
final class MusicPlaylistMutationUIState: ObservableObject {
    @Published private(set) var feedback: MusicPlaylistMutationFeedback?

    func record(_ failure: MusicPlaylistMutationFailure?) {
        feedback = failure.map(MusicPlaylistMutationFeedback.init(failure:))
    }

    func apply(_ outcome: MusicPlaylistAddWorkOutcome) {
        if case let .failure(_, reason, _) = outcome {
            record(reason)
        }
    }

    func clear() { feedback = nil }
}

@MainActor
final class MusicPlaylistStore: ObservableObject {
    nonisolated static let persistenceKey = "MusicPlaylistStore.state.v1"
    nonisolated static let maximumPlaylistCount = 100
    nonisolated static let maximumMembersPerPlaylist = 1_000
    nonisolated static let maximumTotalMemberCount = 10_000
    nonisolated static let maximumPayloadBytes = 512 * 1_024
    nonisolated static let maximumNameCharacters = 100
    nonisolated static let maximumNameUTF8Bytes = 400
    nonisolated private static let version = 1

    struct Limits: Equatable {
        let playlistCount: Int
        let membersPerPlaylist: Int
        let totalMemberAndTombstoneCount: Int
        let payloadBytes: Int

        nonisolated static let production = Limits(
            playlistCount: MusicPlaylistStore.maximumPlaylistCount,
            membersPerPlaylist: MusicPlaylistStore.maximumMembersPerPlaylist,
            totalMemberAndTombstoneCount: MusicPlaylistStore.maximumTotalMemberCount,
            payloadBytes: MusicPlaylistStore.maximumPayloadBytes
        )
    }

    private struct Payload: Codable {
        let version: Int
        let playlists: [MusicPlaylist]
        let deletionTombstones: [MusicPlaylistMember]?
        let pendingDeletion: DeletionJournal?
    }

    private struct DeletionJournal: Codable, Equatable {
        enum Phase: String, Codable, Equatable { case prepared, rollbackRequired, finalizeRequired }
        let member: MusicPlaylistMember
        let affectedPlaylistIDs: [UUID]
        let phase: Phase
        let sessionSourceIdentity: MusicPlaylistSessionSourceIdentity

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case member, affectedPlaylistIDs, phase, sessionSourceIdentity
        }
        private struct AnyCodingKey: CodingKey {
            let stringValue: String
            let intValue: Int? = nil
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(
            member: MusicPlaylistMember,
            affectedPlaylistIDs: [UUID],
            phase: Phase,
            sessionSourceIdentity: MusicPlaylistSessionSourceIdentity
        ) {
            self.member = member
            self.affectedPlaylistIDs = affectedPlaylistIDs
            self.phase = phase
            self.sessionSourceIdentity = sessionSourceIdentity
        }

        init(from decoder: Decoder) throws {
            let raw = try decoder.container(keyedBy: AnyCodingKey.self)
            guard Set(raw.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid deletion journal schema"))
            }
            let values = try decoder.container(keyedBy: CodingKeys.self)
            member = try values.decode(MusicPlaylistMember.self, forKey: .member)
            affectedPlaylistIDs = try values.decode([UUID].self, forKey: .affectedPlaylistIDs)
            phase = try values.decode(Phase.self, forKey: .phase)
            sessionSourceIdentity = try values.decode(MusicPlaylistSessionSourceIdentity.self, forKey: .sessionSourceIdentity)
        }
    }
    private enum JournalMutation { case unchanged, set(DeletionJournal?) }

    @Published private(set) var playlists: [MusicPlaylist]
    @Published private(set) var revision = 0
    @Published private(set) var reconciliationNeedsRepair = false
    @Published private(set) var lastMutationFailure: MusicPlaylistMutationFailure?
    private let defaults: UserDefaults
    private let writePayload: (Data) -> Bool
    private let limits: Limits
    private var deletionTombstones: Set<MusicPlaylistMember>
    private var pendingDeletion: DeletionJournal?
    var persistedPayloadData: Data? { defaults.data(forKey: Self.persistenceKey) }
    var hasPendingMediaDeletion: Bool { pendingDeletion != nil }
    func hasPendingMediaDeletion(for song: MusicItem) -> Bool {
        MusicPlaylistMember(song: song) == pendingDeletion?.member
    }
    var pendingDeletionRepairMode: MusicPlaylistDeletionRepairMode? {
        switch pendingDeletion?.phase {
        case .rollbackRequired: .rollback
        case .finalizeRequired: .finalize
        case .prepared, nil: nil
        }
    }

    init(
        defaults: UserDefaults = .standard,
        limits: Limits = .production,
        writePayload: ((Data) -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.limits = limits
        self.writePayload = writePayload ?? { data in
            defaults.set(data, forKey: Self.persistenceKey)
            return defaults.data(forKey: Self.persistenceKey) == data
        }
        let loaded = Self.load(defaults, limits: limits)
        playlists = loaded.playlists
        deletionTombstones = loaded.tombstones
        pendingDeletion = loaded.pendingDeletion
        reconciliationNeedsRepair = loaded.pendingDeletion != nil
    }

    @discardableResult
    func create(name: String) -> MusicPlaylist? {
        lastMutationFailure = nil
        guard playlists.count < limits.playlistCount else { lastMutationFailure = .playlistLimit; return nil }
        guard let base = Self.validatedName(name) else { lastMutationFailure = .invalidName; return nil }
        let resolved = collisionFreeName(base, excluding: nil)
        let playlist = MusicPlaylist(id: UUID(), name: resolved, members: [])
        var candidate = playlists
        candidate.append(playlist)
        return commit(candidate) ? playlist : nil
    }

    @discardableResult
    func rename(id: UUID, name: String, expectedRevision: Int? = nil) -> Bool {
        lastMutationFailure = nil
        guard expectedRevision == nil || expectedRevision == revision else { lastMutationFailure = .staleState; return false }
        guard let requested = Self.validatedName(name) else { lastMutationFailure = .invalidName; return false }
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { lastMutationFailure = .notFound; return false }
        let resolved = collisionFreeName(requested, excluding: id)
        guard playlists[index].name != resolved else { return true }
        var candidate = playlists
        candidate[index].name = resolved
        return commit(candidate)
    }

    @discardableResult
    func delete(id: UUID, expectedRevision: Int? = nil) -> Bool {
        lastMutationFailure = nil
        guard expectedRevision == nil || expectedRevision == revision else { lastMutationFailure = .staleState; return false }
        guard playlists.contains(where: { $0.id == id }) else { lastMutationFailure = .notFound; return false }
        return commit(playlists.filter { $0.id != id })
    }

    @discardableResult
    func add(_ song: MusicItem, to id: UUID) -> Bool {
        insert(song, into: id, at: Int.max)
    }

    @discardableResult
    func insert(_ song: MusicItem, into id: UUID, at requestedIndex: Int, expectedRevision: Int? = nil) -> Bool {
        lastMutationFailure = nil
        guard expectedRevision == nil || expectedRevision == revision else { lastMutationFailure = .staleState; return false }
        guard requestedIndex >= 0, let member = MusicPlaylistMember(song: song) else { lastMutationFailure = .unavailableSource; return false }
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { lastMutationFailure = .notFound; return false }
        if playlists[index].members.contains(member) { return true }
        guard !playlists[index].members.contains(where: { $0.logicalID == member.logicalID }) else { lastMutationFailure = .logicalConflict; return false }
        guard playlists[index].members.count < limits.membersPerPlaylist else { lastMutationFailure = .memberLimit; return false }
        var candidate = playlists
        candidate[index].members.insert(member, at: min(requestedIndex, candidate[index].members.count))
        var candidateTombstones = deletionTombstones
        candidateTombstones.remove(member)
        return commit(candidate, tombstones: candidateTombstones)
    }

    @discardableResult
    func remove(_ song: MusicItem, from id: UUID, expectedRevision: Int? = nil) -> Bool {
        guard let member = MusicPlaylistMember(song: song) else { return false }
        return remove(member, from: id, expectedRevision: expectedRevision)
    }

    @discardableResult
    func remove(_ member: MusicPlaylistMember, from id: UUID, expectedRevision: Int? = nil) -> Bool {
        lastMutationFailure = nil
        guard expectedRevision == nil || expectedRevision == revision else { lastMutationFailure = .staleState; return false }
        guard let index = playlists.firstIndex(where: { $0.id == id }),
              playlists[index].members.contains(member) else { lastMutationFailure = .notFound; return false }
        var candidate = playlists
        candidate[index].members.removeAll { $0 == member }
        return commit(candidate)
    }

    func playlist(id: UUID) -> MusicPlaylist? { playlists.first { $0.id == id } }

    func intent(for id: UUID) -> MusicPlaylistIntent? {
        playlist(id: id).map { _ in MusicPlaylistIntent(playlistID: id, storeRevision: revision) }
    }

    func rename(_ intent: MusicPlaylistIntent, name: String) -> Bool {
        rename(id: intent.playlistID, name: name, expectedRevision: intent.storeRevision)
    }

    func delete(_ intent: MusicPlaylistIntent) -> Bool {
        delete(id: intent.playlistID, expectedRevision: intent.storeRevision)
    }

    @discardableResult
    func removeFromAllPlaylists(_ song: MusicItem) -> Bool {
        guard let member = MusicPlaylistMember(song: song) else { return false }
        var candidate = playlists
        for index in candidate.indices { candidate[index].members.removeAll { $0 == member } }
        var candidateTombstones = deletionTombstones
        candidateTombstones.remove(member)
        guard candidate != playlists || candidateTombstones != deletionTombstones else { return true }
        return commit(candidate, tombstones: candidateTombstones)
    }

    func retryDeletedMembershipRepair(_ song: MusicItem) -> Bool {
        guard let mode = pendingDeletionRepairMode else {
            lastMutationFailure = .repairRequired
            return false
        }
        return retryDeletedMembershipRepair(song, mode: mode)
    }

    func retryDeletedMembershipRepair(_ song: MusicItem, mode: MusicPlaylistDeletionRepairMode) -> Bool {
        guard let member = MusicPlaylistMember(song: song), pendingDeletion?.member == member else {
            lastMutationFailure = .notFound
            return false
        }
        let phaseMatches = pendingDeletionRepairMode == mode
            || (mode == .rollback && pendingDeletion?.phase == .prepared
                && MusicPlaylistSessionSourceIdentity.read(song.url) == pendingDeletion?.sessionSourceIdentity)
            || (mode == .finalize && pendingDeletion?.phase == .prepared
                && MusicPlaylistSessionSourceIdentity.read(song.url) == nil)
        guard phaseMatches else { lastMutationFailure = .repairRequired; return false }
        switch mode {
        case .rollback: return cancelPreparedMediaDeletion(song)
        case .finalize:
            if pendingDeletion?.phase == .prepared,
               !markMediaDeletionUnlinked(song) { return false }
            return finalizeMediaDeletion(song)
        }
    }

    func prepareMediaDeletion(_ song: MusicItem) -> Bool {
        prepareMediaDeletionPlan(song) != .failed
    }

    func prepareMediaDeletionPlan(_ song: MusicItem) -> MusicPlaylistDeletionPreparation {
        guard let member = MusicPlaylistMember(song: song) else { lastMutationFailure = .unavailableSource; return .failed }
        let affected = playlists.filter { $0.members.contains(member) }.map(\.id)
        guard !affected.isEmpty else { return .noPlaylistWork }
        guard let session = MusicPlaylistSessionSourceIdentity.read(song.url) else { lastMutationFailure = .unavailableSource; return .failed }
        if pendingDeletion?.member == member,
           pendingDeletion?.affectedPlaylistIDs == affected,
           pendingDeletion?.sessionSourceIdentity == session { return .journalPrepared }
        let journal = DeletionJournal(member: member, affectedPlaylistIDs: affected, phase: .prepared, sessionSourceIdentity: session)
        guard pendingDeletion == nil || pendingDeletion == journal else { lastMutationFailure = .repairRequired; return .failed }
        let result = commit(playlists, journal: .set(journal))
        reconciliationNeedsRepair = !result
        return result ? .journalPrepared : .failed
    }

    func cancelPreparedMediaDeletion(_ song: MusicItem) -> Bool {
        guard let member = MusicPlaylistMember(song: song), pendingDeletion?.member == member else { return pendingDeletion == nil }
        let result = commit(playlists, journal: .set(nil))
        if result { reconciliationNeedsRepair = false }
        return result
    }

    func markMediaDeletionRollbackRequired(_ song: MusicItem) -> Bool {
        updatePendingDeletionPhase(song, to: .rollbackRequired)
    }

    func markMediaDeletionUnlinked(_ song: MusicItem) -> Bool {
        updatePendingDeletionPhase(song, to: .finalizeRequired)
    }

    private func updatePendingDeletionPhase(_ song: MusicItem, to phase: DeletionJournal.Phase) -> Bool {
        guard let member = MusicPlaylistMember(song: song), let journal = pendingDeletion,
              journal.member == member else { lastMutationFailure = .notFound; return false }
        if journal.phase == phase { return true }
        let updated = DeletionJournal(
            member: journal.member,
            affectedPlaylistIDs: journal.affectedPlaylistIDs,
            phase: phase,
            sessionSourceIdentity: journal.sessionSourceIdentity
        )
        let result = commit(playlists, journal: .set(updated))
        reconciliationNeedsRepair = !result
        return result
    }

    func finalizeMediaDeletion(_ song: MusicItem) -> Bool {
        guard let member = MusicPlaylistMember(song: song), let journal = pendingDeletion,
              journal.member == member else { lastMutationFailure = .notFound; return false }
        guard journal.phase == .finalizeRequired else { lastMutationFailure = .repairRequired; return false }
        var candidate = playlists
        for index in candidate.indices where journal.affectedPlaylistIDs.contains(candidate[index].id) {
            candidate[index].members.removeAll { $0 == member }
        }
        let result = commit(candidate, journal: .set(nil))
        reconciliationNeedsRepair = !result
        return result
    }

    func resolvePendingAdd(_ intent: MusicPlaylistPendingAddIntent, library: [MusicItem]) -> Bool {
        guard pendingAddIsCurrent(intent, library: library),
              let song = library.first(where: {
                  $0.url.standardizedFileURL == intent.sourceURL
                      && $0.url.deletingLastPathComponent().lastPathComponent == intent.logicalLocation
                      && $0.fileName == intent.fileName
                      && $0.favoriteSourceIdentity?.isValid == true
              }) else { return false }
        return add(song, to: intent.playlistID)
    }

    func pendingAddIsCurrent(_ intent: MusicPlaylistPendingAddIntent, library: [MusicItem]) -> Bool {
        revision == intent.storeRevision && playlist(id: intent.playlistID) != nil
            && MusicPlaylistSessionSourceIdentity.read(intent.sourceURL) == intent.sessionSourceIdentity
            && library.contains { $0.url.standardizedFileURL == intent.sourceURL }
    }

    func addRowState(for song: MusicItem, playlistID: UUID) -> MusicPlaylistAddRowState {
        let location = song.url.deletingLastPathComponent().lastPathComponent
        if playlist(id: playlistID)?.members.contains(where: {
            $0.logicalLocation == location && $0.fileName == song.fileName
        }) == true {
            return .added
        }
        return song.favoriteSourceIdentity?.isValid == true ? .available : .waitingForVerification
    }

    func songs(in id: UUID, library: [MusicItem]) -> [MusicItem] {
        guard let playlist = playlist(id: id) else { return [] }
        return MusicPlaylistLibraryIndex(library: library).playableSongs(for: playlist)
    }

    func songs(in id: UUID, index: MusicPlaylistLibraryIndex) -> [MusicItem] {
        guard let playlist = playlist(id: id) else { return [] }
        return index.playableSongs(for: playlist)
    }

    @discardableResult
    func reconcile(
        with snapshot: MusicFavoritesReconciliationSnapshot,
        library: [MusicItem]? = nil
    ) -> MusicPlaylistReconciliationOutcome {
        guard snapshot.isAuthoritative else { return .noChange }
        if let journal = pendingDeletion {
            let matching = snapshot.entries.first {
                "\($0.logicalLocation)\u{0}\($0.fileName)" == journal.member.logicalID
            }
            let survivingOriginalSource = library?.first(where: {
                MusicPlaylistMember(song: $0) == journal.member
            }).flatMap { MusicPlaylistSessionSourceIdentity.read($0.url) }.map {
                $0.device == journal.sessionSourceIdentity.device
                    && $0.inode == journal.sessionSourceIdentity.inode
                    && $0.size == journal.sessionSourceIdentity.size
                    && $0.linkCount == 1
            } == true
            if journal.phase == .rollbackRequired, survivingOriginalSource {
                guard commit(playlists, journal: .set(nil)) else { reconciliationNeedsRepair = true; return .repairRequired }
                reconciliationNeedsRepair = false
            } else if journal.phase == .rollbackRequired {
                reconciliationNeedsRepair = true
                return .repairRequired
            } else if journal.phase == .prepared,
                      matching?.sourceIdentity == journal.member.sourceIdentity, survivingOriginalSource {
                guard commit(playlists, journal: .set(nil)) else { reconciliationNeedsRepair = true; return .repairRequired }
                reconciliationNeedsRepair = false
            } else if matching?.sourceIdentity == journal.member.sourceIdentity, library == nil {
                reconciliationNeedsRepair = true
                return .repairRequired
            } else if matching?.sourceIdentity == nil, matching != nil {
                reconciliationNeedsRepair = true
                return .repairRequired
            } else if matching == nil || matching?.sourceIdentity != nil {
                var candidate = playlists
                for index in candidate.indices where journal.affectedPlaylistIDs.contains(candidate[index].id) {
                    candidate[index].members.removeAll { $0 == journal.member }
                }
                guard commit(candidate, journal: .set(nil)) else { reconciliationNeedsRepair = true; return .repairRequired }
                reconciliationNeedsRepair = false
            }
        }
        var logicalIDs = Set<String>()
        var identities: [String: MusicFavoriteSourceIdentity] = [:]
        for entry in snapshot.entries {
            let id = "\(entry.logicalLocation)\u{0}\(entry.fileName)"
            guard logicalIDs.insert(id).inserted else { return .noChange }
            if let identity = entry.sourceIdentity { identities[id] = identity }
        }
        var candidate = playlists
        for index in candidate.indices {
            candidate[index].members.removeAll { member in
                guard logicalIDs.contains(member.logicalID) else { return true }
                guard let identity = identities[member.logicalID] else { return false }
                return identity != member.sourceIdentity
            }
        }
        guard candidate != playlists else {
            reconciliationNeedsRepair = false
            return .noChange
        }
        guard commit(candidate) else {
            reconciliationNeedsRepair = true
            return .repairRequired
        }
        reconciliationNeedsRepair = false
        return .persisted
    }

    private func collisionFreeName(_ base: String, excluding id: UUID?) -> String {
        let occupied = Set(playlists.filter { $0.id != id }.map { Self.normalized($0.name) })
        if !occupied.contains(Self.normalized(base)) { return base }
        var suffix = 2
        while true {
            let marker = " (\(suffix))"
            let characterBudget = max(0, Self.maximumNameCharacters - marker.count)
            let byteBudget = max(0, Self.maximumNameUTF8Bytes - marker.utf8.count)
            var stem = ""
            for character in base {
                guard stem.count < characterBudget,
                      stem.utf8.count + String(character).utf8.count <= byteBudget else { break }
                stem.append(character)
            }
            if stem.isEmpty { stem = "P" }
            let candidate = stem + marker
            if Self.validatedName(candidate) == candidate,
               !occupied.contains(Self.normalized(candidate)) { return candidate }
            suffix += 1
        }
    }

    private static func validatedName(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maximumNameCharacters,
              value.utf8.count <= maximumNameUTF8Bytes else { return nil }
        return value
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func load(_ defaults: UserDefaults, limits: Limits) -> (playlists: [MusicPlaylist], tombstones: Set<MusicPlaylistMember>, pendingDeletion: DeletionJournal?) {
        guard let data = defaults.data(forKey: persistenceKey), data.count <= limits.payloadBytes,
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.version == version, validate(payload.playlists, limits: limits) else { return ([], [], nil) }
        let tombstones = payload.deletionTombstones ?? []
        let memberCount = payload.playlists.reduce(0) { $0 + $1.members.count }
        guard memberCount + tombstones.count <= limits.totalMemberAndTombstoneCount,
              tombstones.allSatisfy(validMember), Set(tombstones).count == tombstones.count else { return ([], [], nil) }
        if let journal = payload.pendingDeletion {
            guard validJournal(journal, playlists: payload.playlists, limits: limits) else { return ([], [], nil) }
        }
        // Legacy tombstones are not historical deletion records. A durable membership
        // removal is sufficient to prevent reimport resurrection, so clear them in memory.
        return (payload.playlists, [], payload.pendingDeletion)
    }

    private static func validate(_ playlists: [MusicPlaylist], limits: Limits) -> Bool {
        guard playlists.count <= limits.playlistCount else { return false }
        var ids = Set<UUID>(), names = Set<String>()
        for playlist in playlists {
            guard ids.insert(playlist.id).inserted,
                  let name = validatedName(playlist.name), name == playlist.name,
                  names.insert(normalized(name)).inserted,
                  playlist.members.count <= limits.membersPerPlaylist else { return false }
            var members = Set<MusicPlaylistMember>()
            var logicalIDs = Set<String>()
            for member in playlist.members {
                guard validMember(member), members.insert(member).inserted,
                      logicalIDs.insert(member.logicalID).inserted else { return false }
            }
        }
        return true
    }

    private static func validMember(_ member: MusicPlaylistMember) -> Bool {
        !member.logicalLocation.isEmpty
            && member.logicalLocation == URL(fileURLWithPath: member.logicalLocation).lastPathComponent
            && !member.fileName.isEmpty
            && member.fileName == URL(fileURLWithPath: member.fileName).lastPathComponent
            && member.sourceIdentity.isValid
    }

    private static func validJournal(
        _ journal: DeletionJournal,
        playlists: [MusicPlaylist],
        limits: Limits
    ) -> Bool {
        guard validMember(journal.member), !journal.affectedPlaylistIDs.isEmpty,
              journal.affectedPlaylistIDs.count <= limits.playlistCount,
              Set(journal.affectedPlaylistIDs).count == journal.affectedPlaylistIDs.count,
              journal.sessionSourceIdentity.device >= 0,
              journal.sessionSourceIdentity.inode > 0,
              journal.sessionSourceIdentity.size >= 0,
              journal.sessionSourceIdentity.modificationSeconds >= 0,
              (0..<1_000_000_000).contains(journal.sessionSourceIdentity.modificationNanoseconds),
              journal.sessionSourceIdentity.changeSeconds >= 0,
              (0..<1_000_000_000).contains(journal.sessionSourceIdentity.changeNanoseconds),
              journal.sessionSourceIdentity.linkCount == 1,
              journal.sessionSourceIdentity.size == off_t(journal.member.sourceIdentity.fileSize) else { return false }
        let byID = Dictionary(uniqueKeysWithValues: playlists.map { ($0.id, $0) })
        return journal.affectedPlaylistIDs.allSatisfy {
            byID[$0]?.members.contains(journal.member) == true
        }
    }

    private func commit(
        _ candidate: [MusicPlaylist],
        tombstones: Set<MusicPlaylistMember>? = nil,
        journal: JournalMutation = .unchanged
    ) -> Bool {
        let candidateTombstones = tombstones ?? deletionTombstones
        let candidateJournal: DeletionJournal?
        switch journal {
        case .unchanged: candidateJournal = pendingDeletion
        case let .set(value): candidateJournal = value
        }
        let memberCount = candidate.reduce(0) { $0 + $1.members.count }
        guard Self.validate(candidate, limits: limits) else { lastMutationFailure = .memberLimit; return false }
        guard candidateJournal.map({ Self.validJournal($0, playlists: candidate, limits: limits) }) ?? true else {
            lastMutationFailure = .repairRequired
            return false
        }
        guard memberCount + candidateTombstones.count <= limits.totalMemberAndTombstoneCount else { lastMutationFailure = .totalLimit; return false }
        guard let data = try? JSONEncoder().encode(Payload(version: Self.version, playlists: candidate, deletionTombstones: candidateTombstones.sorted { $0.logicalID < $1.logicalID }, pendingDeletion: candidateJournal)) else { lastMutationFailure = .persistenceFailure; return false }
        guard data.count <= limits.payloadBytes else { lastMutationFailure = .payloadLimit; return false }
        let previousData = defaults.data(forKey: Self.persistenceKey)
        guard writePayload(data) else {
            restorePersistedData(previousData)
            lastMutationFailure = .persistenceFailure
            return false
        }
        guard defaults.data(forKey: Self.persistenceKey) == data,
              let readback = try? JSONDecoder().decode(Payload.self, from: data),
              readback.version == Self.version, readback.playlists == candidate,
              Set(readback.deletionTombstones ?? []) == candidateTombstones,
              readback.pendingDeletion == candidateJournal else {
            restorePersistedData(previousData)
            lastMutationFailure = .readbackFailure
            return false
        }
        playlists = candidate
        deletionTombstones = candidateTombstones
        pendingDeletion = candidateJournal
        revision &+= 1
        lastMutationFailure = nil
        return true
    }

    private func restorePersistedData(_ data: Data?) {
        if let data { defaults.set(data, forKey: Self.persistenceKey) }
        else { defaults.removeObject(forKey: Self.persistenceKey) }
    }
}

@MainActor
struct MusicPlaylistCoordinator {
    let store: MusicPlaylistStore
    let playback: MusicPlaybackManager

    @discardableResult
    func resolveDetailPublication(
        _ publication: MusicLibraryPublication,
        playlistID: UUID,
        addCoordinator: MusicPlaylistAddCoordinator
    ) -> MusicPlaylistLibraryIndex {
        let index = MusicPlaylistLibraryIndex(library: publication.songs)
        addCoordinator.resolve(using: index, store: store, publication: publication)
        reconcileDetailQueue(id: playlistID, publication: publication, index: index)
        return index
    }

    func reconcileDetailQueue(
        id: UUID,
        publication: MusicLibraryPublication,
        index: MusicPlaylistLibraryIndex? = nil
    ) {
        // Presentation/work notifications are not evidence that certified members
        // disappeared. Both detail publication and async add callbacks enter here.
        guard publication.reconciliationSnapshot.isAuthoritative else { return }
        let resolvedIndex = index ?? MusicPlaylistLibraryIndex(library: publication.songs)
        playback.reconcilePlaylistQueue(id: id, items: store.songs(in: id, index: resolvedIndex))
    }

    @discardableResult
    func remove(
        _ intent: MusicPlaylistRemoveActionIntent,
        consumer: inout MusicPlaylistActionIntentConsumer,
        publication: MusicLibraryPublication
    ) -> Bool {
        guard consumer.remove(intent, store: store, publication: publication) else { return false }
        // A committed user removal remains authoritative about membership during
        // refresh. Retain only certified queue sources that are still members;
        // cheap/empty scan rows cannot remove the other traversal targets.
        let songs = publication.reconciliationSnapshot.isAuthoritative ? publication.songs : playback.queue
        let index = MusicPlaylistLibraryIndex(library: songs)
        playback.reconcilePlaylistQueue(id: intent.playlistID, items: store.songs(in: intent.playlistID, index: index))
        return true
    }

    @discardableResult
    func synchronize(
        snapshot: MusicFavoritesReconciliationSnapshot,
        library: [MusicItem]
    ) -> MusicPlaylistReconciliationOutcome {
        let index = MusicPlaylistLibraryIndex(library: library)
        let outcome = store.reconcile(with: snapshot, library: library)
        playback.syncLibrary(library, snapshot: snapshot)
        if case let .playlist(id) = playback.queueScope {
            guard store.playlist(id: id) != nil else {
                playback.playlistDeleted(id: id)
                return outcome
            }
            guard snapshot.isAuthoritative else { return outcome }
            playback.reconcilePlaylistQueue(id: id, items: store.songs(in: id, index: index), reason: .authoritativeLibrary)
        }
        return outcome
    }

    @discardableResult
    func add(_ song: MusicItem, to id: UUID, library: [MusicItem]) -> Bool {
        guard store.add(song, to: id) else { return false }
        let index = MusicPlaylistLibraryIndex(library: library)
        playback.reconcilePlaylistQueue(id: id, items: store.songs(in: id, index: index))
        return true
    }

    @discardableResult
    func remove(_ song: MusicItem, from id: UUID, expectedRevision: Int, library: [MusicItem]) -> Bool {
        guard store.remove(song, from: id, expectedRevision: expectedRevision) else { return false }
        let index = MusicPlaylistLibraryIndex(library: library)
        playback.reconcilePlaylistQueue(id: id, items: store.songs(in: id, index: index))
        return true
    }
}
