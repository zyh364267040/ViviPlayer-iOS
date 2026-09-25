import Darwin
import Foundation

@MainActor
final class MediaLibraryStorage {
    enum StorageError: Error {
        case unsafeDeletionTarget
        case unsafeLyricSidecarTarget
    }
    enum MediaKind {
        case audio
        case video
    }
    enum MusicImportClassification {
        case song
        case lyric
    }

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "alac",
        "ogg", "opus", "wma", "ape", "amr"
    ]
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "flv", "wmv", "webm",
        "ts", "m2ts", "3gp", "rmvb"
    ]

    let rootURL: URL
    let legacyAudioURL: URL
    let legacyVideoURL: URL
    private let fileManager: FileManager
    private let preUnlink: (() throws -> Void)?
    private let lyricSidecarPreReadHook: (() throws -> Void)?

    init(
        rootURL: URL,
        legacyAudioURL: URL,
        legacyVideoURL: URL,
        fileManager: FileManager = .default,
        preUnlink: (() throws -> Void)? = nil,
        lyricSidecarPreReadHook: (() throws -> Void)? = nil
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.legacyAudioURL = legacyAudioURL.standardizedFileURL
        self.legacyVideoURL = legacyVideoURL.standardizedFileURL
        self.fileManager = fileManager
        self.preUnlink = preUnlink
        self.lyricSidecarPreReadHook = lyricSidecarPreReadHook
    }

    static func live(fileManager: FileManager = .default) -> MediaLibraryStorage {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return MediaLibraryStorage(
            rootURL: documents,
            legacyAudioURL: applicationSupport.appendingPathComponent("ImportedAudio", isDirectory: true),
            legacyVideoURL: applicationSupport.appendingPathComponent("ImportedVideos", isDirectory: true),
            fileManager: fileManager
        )
    }

    func musicImportClassification(for url: URL) -> MusicImportClassification? {
        let fileExtension = url.pathExtension
        if Self.audioExtensions.contains(fileExtension.lowercased()) {
            return .song
        }
        if fileExtension == "lrc" {
            return .lyric
        }
        return nil
    }

    func scan(kind: MediaKind) throws -> [URL] {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        let supported = kind == .audio ? Self.audioExtensions : Self.videoExtensions
        return urls.filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true
                && values?.isSymbolicLink != true
                && supported.contains(url.pathExtension.lowercased())
        }
    }

    func scanLyricSidecars() throws -> [URL] {
        try Self.scanLyricSidecars(at: rootURL, fileManager: fileManager)
    }

    func readLyricSidecarData(at url: URL) throws -> Data {
        try Self.readLyricSidecarData(
            at: url,
            rootURL: rootURL,
            preReadHook: lyricSidecarPreReadHook
        )
    }

    nonisolated static func scanLyricSidecars(
        at rootURL: URL,
        fileManager: FileManager
    ) throws -> [URL] {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let urls = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return urls.filter { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true
                && values?.isSymbolicLink != true
                && url.pathExtension == "lrc"
        }
    }

    nonisolated static func readLyricSidecarData(
        at url: URL,
        rootURL: URL,
        preReadHook: (() throws -> Void)?
    ) throws -> Data {
        guard url.isFileURL else { throw StorageError.unsafeLyricSidecarTarget }
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent() == rootURL else {
            throw StorageError.unsafeLyricSidecarTarget
        }
        let name = candidate.lastPathComponent
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/"),
              !name.utf8.contains(0),
              candidate.pathExtension == "lrc" else {
            throw StorageError.unsafeLyricSidecarTarget
        }

        let rootFD = rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard rootFD >= 0 else { throw Self.posixError() }
        defer { Darwin.close(rootFD) }

        let childFD = name.withCString {
            Darwin.openat(rootFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard childFD >= 0 else { throw Self.posixError() }
        defer { Darwin.close(childFD) }

        var status = stat()
        guard Darwin.fstat(childFD, &status) == 0 else { throw Self.posixError() }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 0,
              status.st_size <= 512 * 1024 else {
            throw StorageError.unsafeLyricSidecarTarget
        }
        let initialSize = status.st_size

        try preReadHook?()
        let data = try FileHandle(
            fileDescriptor: childFD,
            closeOnDealloc: false
        ).readToEnd() ?? Data()

        var finalStatus = stat()
        guard Darwin.fstat(childFD, &finalStatus) == 0 else { throw Self.posixError() }
        guard (finalStatus.st_mode & S_IFMT) == S_IFREG,
              finalStatus.st_nlink == 1,
              finalStatus.st_size == initialSize,
              finalStatus.st_size >= 0,
              finalStatus.st_size <= 512 * 1024,
              data.count == Int(initialSize) else {
            throw StorageError.unsafeLyricSidecarTarget
        }
        return data
    }

    func migrateLegacyFiles() {
        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            return
        }
        for directory in [legacyAudioURL, legacyVideoURL] {
            migrateFiles(from: directory)
        }
    }

    func importFile(from sourceURL: URL) throws -> URL {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let stagingURL = rootURL.appendingPathComponent(".importing-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: stagingURL) }
        try fileManager.copyItem(at: sourceURL, to: stagingURL)
        let destination = uniqueDestination(forFileName: sourceURL.lastPathComponent)
        try fileManager.moveItem(at: stagingURL, to: destination)
        return destination
    }

    func deleteFile(at url: URL) throws {
        guard url.isFileURL else { throw StorageError.unsafeDeletionTarget }
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent() == rootURL else {
            throw StorageError.unsafeDeletionTarget
        }
        let name = candidate.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw StorageError.unsafeDeletionTarget
        }

        let rootFD = rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard rootFD >= 0 else { throw Self.posixError() }
        defer { Darwin.close(rootFD) }

        var status = stat()
        let statResult = name.withCString {
            fstatat(rootFD, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0 else { throw Self.posixError() }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw StorageError.unsafeDeletionTarget
        }

        try preUnlink?()
        let unlinkResult = name.withCString { unlinkat(rootFD, $0, 0) }
        guard unlinkResult == 0 else { throw Self.posixError() }
    }

    nonisolated private static func posixError() -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private func migrateFiles(from directory: URL) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for sourceURL in urls {
            let values = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            do {
                try fileManager.moveItem(
                    at: sourceURL,
                    to: uniqueDestination(forFileName: sourceURL.lastPathComponent)
                )
            } catch {
                // Leave this source in place so the next refresh can retry it.
            }
        }

        if let leftovers = try? fileManager.contentsOfDirectory(atPath: directory.path),
           leftovers.isEmpty {
            try? fileManager.removeItem(at: directory)
        }
    }

    private func uniqueDestination(forFileName fileName: String) -> URL {
        let safeName = fileName.isEmpty ? "ImportedMedia" : fileName
        let nameURL = URL(fileURLWithPath: safeName)
        let fileExtension = nameURL.pathExtension
        let baseName = nameURL.deletingPathExtension().lastPathComponent
        var candidate = rootURL.appendingPathComponent(safeName)
        var sequence = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = rootURL.appendingPathComponent("\(baseName) (\(sequence))")
            if !fileExtension.isEmpty {
                candidate.appendPathExtension(fileExtension)
            }
            sequence += 1
        }
        return candidate
    }
}

actor BoundedLyricSidecarLoader {
    private let rootURL: URL

    init(rootURL: URL) {
        self.rootURL = rootURL
    }

    func load(for songURL: URL) -> Data? {
        guard !Task.isCancelled else { return nil }
        let sidecarURL = rootURL
            .appendingPathComponent(songURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("lrc")
        return try? MediaLibraryStorage.readLyricSidecarData(
            at: sidecarURL,
            rootURL: rootURL,
            preReadHook: nil
        )
    }
}
