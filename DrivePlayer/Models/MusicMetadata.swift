import Foundation
import AVFoundation

struct RawMusicMetadataItem: Equatable, Sendable {
    let identifier: String
    let stringValue: String?
    let dataValue: Data?
}

enum AVFoundationMusicMetadataRawLoader {
    static func loadSupportedItems(
        _ items: [AVMetadataItem],
        limits: MusicMetadataResourceLimits = .default,
        stringValueLoader: @Sendable (AVMetadataItem) async throws -> String?,
        dataValueLoader: @Sendable (AVMetadataItem) async throws -> Data?
    ) async -> [RawMusicMetadataItem] {
        var rawItems: [RawMusicMetadataItem] = []
        var supportedItemCount = 0

        for item in items {
            guard let identifier = item.identifier?.rawValue else {
                continue
            }

            switch identifier {
            case "id3/TIT2", "id3/TPE1", "id3/TALB", "id3/USLT",
                 "itsk/%A9nam", "itsk/%A9ART", "itsk/%A9alb", "itsk/%A9lyr":
                guard supportedItemCount < limits.maximumSupportedItemCount else {
                    continue
                }
                supportedItemCount += 1
                do {
                    let stringValue = try await stringValueLoader(item)
                    if let stringValue, stringValue.utf8.count > limits.maximumTextBytes {
                        continue
                    }
                    rawItems.append(
                        RawMusicMetadataItem(
                            identifier: identifier,
                            stringValue: stringValue,
                            dataValue: nil
                        )
                    )
                } catch {
                    continue
                }
            case "id3/APIC", "id3/SYLT", "itsk/covr":
                guard supportedItemCount < limits.maximumSupportedItemCount else {
                    continue
                }
                supportedItemCount += 1
                do {
                    let dataValue = try await dataValueLoader(item)
                    let maximumBytes = identifier == "id3/SYLT"
                        ? limits.maximumSynchronizedLyricsBytes
                        : limits.maximumArtworkBytes
                    if let dataValue, dataValue.count > maximumBytes {
                        continue
                    }
                    rawItems.append(
                        RawMusicMetadataItem(
                            identifier: identifier,
                            stringValue: nil,
                            dataValue: dataValue
                        )
                    )
                } catch {
                    continue
                }
            default:
                continue
            }
        }

        return rawItems
    }

    static func load(from url: URL) async throws -> [RawMusicMetadataItem] {
        let asset = AVURLAsset(url: url.standardizedFileURL)
        let formats = try await asset.load(.availableMetadataFormats)
        var rawItems: [RawMusicMetadataItem] = []

        for format in formats {
            let metadataItems = try await asset.loadMetadata(for: format)
            let loadedItems = await loadSupportedItems(
                metadataItems,
                stringValueLoader: { item in
                    try await item.load(.stringValue)
                },
                dataValueLoader: { item in
                    try await item.load(.dataValue)
                }
            )
            rawItems.append(contentsOf: loadedItems)
        }

        return rawItems
    }
}

struct MusicMetadata: Equatable, Sendable {
    let title: String
    let artist: String?
    let album: String?
    let artworkData: Data?
    let lyrics: String?
    let synchronizedLyricsData: Data?
    let synchronizedLyrics: SynchronizedLyrics?

    init(
        title: String,
        artist: String?,
        album: String?,
        artworkData: Data?,
        lyrics: String?,
        synchronizedLyricsData: Data?
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkData = artworkData
        self.lyrics = lyrics
        self.synchronizedLyricsData = synchronizedLyricsData
        synchronizedLyrics = synchronizedLyricsData.flatMap {
            try? ID3SynchronizedLyricsDecoder.decode($0)
        }
    }

    func replacingSynchronizedLyrics(with synchronizedLyrics: SynchronizedLyrics) -> MusicMetadata {
        MusicMetadata(
            title: title,
            artist: artist,
            album: album,
            artworkData: artworkData,
            lyrics: lyrics,
            synchronizedLyricsData: synchronizedLyricsData,
            synchronizedLyrics: synchronizedLyrics
        )
    }

    private init(
        title: String,
        artist: String?,
        album: String?,
        artworkData: Data?,
        lyrics: String?,
        synchronizedLyricsData: Data?,
        synchronizedLyrics: SynchronizedLyrics
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkData = artworkData
        self.lyrics = lyrics
        self.synchronizedLyricsData = synchronizedLyricsData
        self.synchronizedLyrics = synchronizedLyrics
    }
}

struct SynchronizedLyrics: Equatable, Sendable {
    let language: String
    let cues: [SynchronizedLyricsCue]

    func cueIndex(at playbackTime: TimeInterval) -> Int? {
        guard playbackTime.isFinite, playbackTime >= 0, !cues.isEmpty else {
            return nil
        }

        var lowerBound = 0
        var upperBound = cues.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            let cueTime = TimeInterval(cues[middle].timestampMilliseconds) / 1_000
            if cueTime <= playbackTime {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return lowerBound == 0 ? nil : lowerBound - 1
    }
}

struct SynchronizedLyricsCue: Equatable, Sendable {
    let timestampMilliseconds: UInt32
    let text: String
}

enum LRCSynchronizedLyricsDecoder {
    static func decode(_ data: Data) -> SynchronizedLyrics? {
        guard data.count <= 512 * 1024 else {
            return nil
        }

        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            bytes.removeFirst(3)
        }
        guard String(bytes: bytes, encoding: .utf8) != nil else {
            return nil
        }

        var cues: [(cue: SynchronizedLyricsCue, occurrence: Int)] = []
        var nextOccurrence = 0
        var globalOffsetMilliseconds: Int64?
        let offsetPrefix = Array("[offset:".utf8)
        for line in bytes.split(whereSeparator: { $0 == 0x0A || $0 == 0x0D }) {
            if line.starts(with: offsetPrefix) {
                guard let offset = offsetMilliseconds(in: line) else {
                    return nil
                }
                guard globalOffsetMilliseconds == nil else {
                    return nil
                }
                globalOffsetMilliseconds = offset
                continue
            }

            var timestamps: [UInt32] = []
            var textStart = line.startIndex
            while textStart < line.endIndex,
                  line[textStart] == 0x5B,
                  let closingBracket = line[textStart...].firstIndex(of: 0x5D),
                  let timestamp = timestamp(in: line[textStart..<closingBracket]) {
                timestamps.append(timestamp)
                textStart = line.index(after: closingBracket)
            }

            if !timestamps.isEmpty,
               textStart < line.endIndex,
               line[textStart] == 0x5B {
                let nextIndex = line.index(after: textStart)
                if nextIndex < line.endIndex,
                   line[nextIndex] >= 0x30, line[nextIndex] <= 0x39 {
                    return nil
                }
                if let closingBracket = line[textStart...].firstIndex(of: 0x5D),
                   line[nextIndex..<closingBracket].contains(0x3A) {
                    return nil
                }
            }

            if line.count >= 2,
               line[line.startIndex] == 0x5B,
               let firstTagByte = line.dropFirst().first,
               firstTagByte >= 0x30, firstTagByte <= 0x39,
               timestamps.isEmpty {
                return nil
            }

            let textBytes = line[textStart...]
            guard !timestamps.isEmpty, !textBytes.isEmpty,
                  let text = String(bytes: textBytes, encoding: .utf8) else {
                continue
            }
            for timestamp in timestamps {
                cues.append((
                    cue: SynchronizedLyricsCue(timestampMilliseconds: timestamp, text: text),
                    occurrence: nextOccurrence
                ))
                nextOccurrence += 1
            }
        }

        if let offset = globalOffsetMilliseconds {
            var adjustedCues: [(cue: SynchronizedLyricsCue, occurrence: Int)] = []
            adjustedCues.reserveCapacity(cues.count)
            for entry in cues {
                let timestamp = UInt64(entry.cue.timestampMilliseconds)
                let effectiveTimestamp: UInt64
                if offset < 0 {
                    let magnitude = offset.magnitude
                    effectiveTimestamp = magnitude >= timestamp ? 0 : timestamp - magnitude
                } else {
                    let (adjusted, overflow) = timestamp.addingReportingOverflow(UInt64(offset))
                    guard !overflow, adjusted <= UInt32.max else {
                        return nil
                    }
                    effectiveTimestamp = adjusted
                }
                adjustedCues.append((
                    cue: SynchronizedLyricsCue(
                        timestampMilliseconds: UInt32(effectiveTimestamp),
                        text: entry.cue.text
                    ),
                    occurrence: entry.occurrence
                ))
            }
            cues = adjustedCues
        }

        cues.sort {
            if $0.cue.timestampMilliseconds != $1.cue.timestampMilliseconds {
                return $0.cue.timestampMilliseconds < $1.cue.timestampMilliseconds
            }
            return $0.occurrence < $1.occurrence
        }
        return cues.isEmpty ? nil : SynchronizedLyrics(language: "und", cues: cues.map(\.cue))
    }

    private static func offsetMilliseconds(in line: ArraySlice<UInt8>) -> Int64? {
        let prefix = Array("[offset:".utf8)
        guard line.starts(with: prefix), line.last == 0x5D else { return nil }

        let valueStart = line.index(line.startIndex, offsetBy: prefix.count)
        let valueBytes = line[valueStart..<line.index(before: line.endIndex)]
        guard !valueBytes.isEmpty else { return nil }

        let isNegative = valueBytes.first == 0x2D
        let digits = (isNegative || valueBytes.first == 0x2B) ? valueBytes.dropFirst() : valueBytes
        guard !digits.isEmpty else { return nil }

        var value: Int64 = 0
        for byte in digits {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            let (timesTen, multiplyOverflow) = value.multipliedReportingOverflow(by: 10)
            let digit = Int64(byte - 0x30)
            let (nextValue, addOverflow) = isNegative
                ? timesTen.subtractingReportingOverflow(digit)
                : timesTen.addingReportingOverflow(digit)
            guard !multiplyOverflow, !addOverflow else { return nil }
            value = nextValue
        }
        return value
    }

    private static func timestamp(in prefix: ArraySlice<UInt8>) -> UInt32? {
        guard prefix.first == 0x5B,
              let colon = prefix.firstIndex(of: 0x3A) else {
            return nil
        }

        let minutesBytes = prefix[prefix.index(after: prefix.startIndex)..<colon]
        let secondsAndFraction = prefix[prefix.index(after: colon)...]
        guard !minutesBytes.isEmpty else { return nil }

        var minutes: UInt32 = 0
        for byte in minutesBytes {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            let (timesTen, multiplyOverflow) = minutes.multipliedReportingOverflow(by: 10)
            let (value, addOverflow) = timesTen.addingReportingOverflow(UInt32(byte - 0x30))
            guard !multiplyOverflow, !addOverflow else { return nil }
            minutes = value
        }

        guard secondsAndFraction.count >= 2 else { return nil }
        let secondTens = secondsAndFraction[secondsAndFraction.startIndex]
        let secondOnes = secondsAndFraction[secondsAndFraction.index(after: secondsAndFraction.startIndex)]
        guard secondTens >= 0x30, secondTens <= 0x35,
              secondOnes >= 0x30, secondOnes <= 0x39 else {
            return nil
        }
        let seconds = UInt32(secondTens - 0x30) * 10 + UInt32(secondOnes - 0x30)

        let remainder = secondsAndFraction.dropFirst(2)
        let fraction: UInt32
        if remainder.isEmpty {
            fraction = 0
        } else {
            guard remainder.first == 0x2E, (2...4).contains(remainder.count) else { return nil }
            var value: UInt32 = 0
            for byte in remainder.dropFirst() {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                value = value * 10 + UInt32(byte - 0x30)
            }
            fraction = value * [100, 10, 1][remainder.count - 2]
        }

        let (minuteMilliseconds, minuteOverflow) = minutes.multipliedReportingOverflow(by: 60_000)
        let (wholeMilliseconds, secondsOverflow) = minuteMilliseconds.addingReportingOverflow(seconds * 1_000)
        let (timestamp, fractionOverflow) = wholeMilliseconds.addingReportingOverflow(fraction)
        guard !minuteOverflow, !secondsOverflow, !fractionOverflow else { return nil }
        return timestamp
    }
}

enum ID3SynchronizedLyricsDecoderError: Error {
    case invalidPayload
}

enum ID3SynchronizedLyricsDecoder {
    private static let maximumCueCount = 4_096
    private static let maximumDecodedTextBytes = 1 * 1024 * 1024

    static func decode(_ data: Data) throws -> SynchronizedLyrics {
        let bytes = [UInt8](data)
        var cursor = 0

        guard bytes.count >= 7,
              bytes[cursor] == 0 || bytes[cursor] == 1 else {
            throw ID3SynchronizedLyricsDecoderError.invalidPayload
        }
        let textEncoding = bytes[cursor]
        cursor += 1

        let languageEnd = cursor + 3
        guard languageEnd <= bytes.count,
              let language = String(
                  bytes: bytes[cursor..<languageEnd],
                  encoding: .ascii
              ) else {
            throw ID3SynchronizedLyricsDecoderError.invalidPayload
        }
        cursor = languageEnd

        guard cursor + 2 <= bytes.count,
              bytes[cursor] == 2,
              bytes[cursor + 1] == 1 else {
            throw ID3SynchronizedLyricsDecoderError.invalidPayload
        }
        cursor += 2

        (_, cursor) = try decodeTerminatedString(
            bytes,
            startingAt: cursor,
            encoding: textEncoding
        )

        var cues: [SynchronizedLyricsCue] = []
        var decodedTextBytes = 0
        var previousTimestamp: UInt32?

        while cursor < bytes.count {
            guard cues.count < maximumCueCount else {
                throw ID3SynchronizedLyricsDecoderError.invalidPayload
            }

            let text: String
            (text, cursor) = try decodeTerminatedString(
                bytes,
                startingAt: cursor,
                encoding: textEncoding
            )
            let textByteCount = text.utf8.count
            guard textByteCount <= maximumDecodedTextBytes - decodedTextBytes else {
                throw ID3SynchronizedLyricsDecoderError.invalidPayload
            }
            decodedTextBytes += textByteCount

            guard bytes.count - cursor >= 4 else {
                throw ID3SynchronizedLyricsDecoderError.invalidPayload
            }
            let timestamp = (UInt32(bytes[cursor]) << 24)
                | (UInt32(bytes[cursor + 1]) << 16)
                | (UInt32(bytes[cursor + 2]) << 8)
                | UInt32(bytes[cursor + 3])
            cursor += 4

            guard previousTimestamp.map({ timestamp >= $0 }) ?? true else {
                throw ID3SynchronizedLyricsDecoderError.invalidPayload
            }
            cues.append(
                SynchronizedLyricsCue(
                    timestampMilliseconds: timestamp,
                    text: text
                )
            )
            previousTimestamp = timestamp
        }

        // Keep empty cues in order, but do not let blank-only SYLT replace plain lyrics.
        guard cues.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ID3SynchronizedLyricsDecoderError.invalidPayload
        }
        return SynchronizedLyrics(language: language, cues: cues)
    }

    private static func decodeTerminatedString(
        _ bytes: [UInt8],
        startingAt start: Int,
        encoding: UInt8
    ) throws -> (String, Int) {
        if encoding == 0 {
            guard let end = bytes[start...].firstIndex(of: 0),
                  let string = String(
                      bytes: bytes[start..<end],
                      encoding: .isoLatin1
                  ) else {
                throw ID3SynchronizedLyricsDecoderError.invalidPayload
            }
            return (string, end + 1)
        }

        guard encoding == 1,
              bytes.count - start >= 2 else {
            throw ID3SynchronizedLyricsDecoderError.invalidPayload
        }

        let stringEncoding: String.Encoding
        if bytes[start] == 0xFF, bytes[start + 1] == 0xFE {
            stringEncoding = .utf16LittleEndian
        } else if bytes[start] == 0xFE, bytes[start + 1] == 0xFF {
            stringEncoding = .utf16BigEndian
        } else {
            throw ID3SynchronizedLyricsDecoderError.invalidPayload
        }

        let contentStart = start + 2
        var end = contentStart
        while end + 1 < bytes.count {
            if bytes[end] == 0, bytes[end + 1] == 0 {
                guard let string = String(
                    bytes: bytes[contentStart..<end],
                    encoding: stringEncoding
                ) else {
                    throw ID3SynchronizedLyricsDecoderError.invalidPayload
                }
                return (string, end + 2)
            }
            end += 2
        }

        throw ID3SynchronizedLyricsDecoderError.invalidPayload
    }
}

struct MusicMetadataFileFingerprint: Equatable, Sendable {
    let fileSize: Int64
    let modificationDate: Date
    let contentSHA256Hex: String
    let fileSystemIdentifier: UInt64
    let fileObjectIdentifier: UInt64
    let statusChangeSeconds: Int64
    let statusChangeNanoseconds: Int64

    init(
        fileSize: Int64,
        modificationDate: Date,
        contentSHA256Hex: String = "",
        fileSystemIdentifier: UInt64 = 0,
        fileObjectIdentifier: UInt64 = 0,
        statusChangeSeconds: Int64 = 0,
        statusChangeNanoseconds: Int64 = 0
    ) {
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.contentSHA256Hex = contentSHA256Hex
        self.fileSystemIdentifier = fileSystemIdentifier
        self.fileObjectIdentifier = fileObjectIdentifier
        self.statusChangeSeconds = statusChangeSeconds
        self.statusChangeNanoseconds = statusChangeNanoseconds
    }
}

actor MusicMetadataLoader {
    private final class RequestToken {}

    private struct CacheEntry {
        let fingerprint: MusicMetadataFileFingerprint
        let metadata: MusicMetadata
    }

    private let maximumCachedEntryCount: Int
    private let rawLoader: @Sendable (URL) async throws -> [RawMusicMetadataItem]
    private var cache: [URL: CacheEntry] = [:]
    private var cacheRecency: [URL] = []
    private var requestTokens: [URL: RequestToken] = [:]

    init(
        maximumCachedEntryCount: Int = 64,
        rawItemLoader: @escaping @Sendable (URL) async throws -> [RawMusicMetadataItem] = {
            try await AVFoundationMusicMetadataRawLoader.load(from: $0)
        }
    ) {
        self.maximumCachedEntryCount = max(0, maximumCachedEntryCount)
        self.rawLoader = rawItemLoader
    }

    func load(from url: URL) async -> MusicMetadata {
        let standardizedURL = url.standardizedFileURL
        let fallback = MusicMetadataParser.parse(
            [],
            fallbackFileName: standardizedURL.lastPathComponent
        )

        do {
            let resourceValues = try standardizedURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey]
            )
            guard let fileSize = resourceValues.fileSize,
                  let fileSize = Int64(exactly: fileSize),
                  let modificationDate = resourceValues.contentModificationDate else {
                return fallback
            }

            let fingerprint = MusicMetadataFileFingerprint(
                fileSize: fileSize,
                modificationDate: modificationDate
            )
            return try await load(url: standardizedURL, fingerprint: fingerprint)
        } catch {
            return fallback
        }
    }

    func load(
        url: URL,
        fingerprint: MusicMetadataFileFingerprint
    ) async throws -> MusicMetadata {
        let standardizedURL = url.standardizedFileURL

        if let cached = cache[standardizedURL], cached.fingerprint == fingerprint {
            markMostRecent(standardizedURL)
            return cached.metadata
        }

        let requestToken = RequestToken()
        requestTokens[standardizedURL] = requestToken

        do {
            let items = try await rawLoader(standardizedURL)
            let metadata = MusicMetadataParser.parse(
                items,
                fallbackFileName: standardizedURL.lastPathComponent
            )
            if requestTokens[standardizedURL] === requestToken {
                requestTokens.removeValue(forKey: standardizedURL)
                insertCacheEntry(
                    CacheEntry(fingerprint: fingerprint, metadata: metadata),
                    for: standardizedURL
                )
            }
            return metadata
        } catch {
            if requestTokens[standardizedURL] === requestToken {
                requestTokens.removeValue(forKey: standardizedURL)
            }
            throw error
        }
    }

    private func markMostRecent(_ url: URL) {
        cacheRecency.removeAll { $0 == url }
        cacheRecency.append(url)
    }

    private func insertCacheEntry(_ entry: CacheEntry, for url: URL) {
        guard maximumCachedEntryCount > 0 else {
            cache.removeValue(forKey: url)
            cacheRecency.removeAll { $0 == url }
            return
        }

        cache[url] = entry
        markMostRecent(url)
        while cache.count > maximumCachedEntryCount {
            let leastRecentURL = cacheRecency.removeFirst()
            cache.removeValue(forKey: leastRecentURL)
        }
    }
}

struct MusicMetadataResourceLimits: Equatable, Sendable {
    let maximumArtworkBytes: Int
    let maximumSynchronizedLyricsBytes: Int
    let maximumTextBytes: Int
    let maximumSupportedItemCount: Int

    init(
        maximumArtworkBytes: Int,
        maximumSynchronizedLyricsBytes: Int,
        maximumSupportedItemCount: Int = 256,
        maximumTextBytes: Int = 1 * 1024 * 1024
    ) {
        self.maximumArtworkBytes = max(0, maximumArtworkBytes)
        self.maximumSynchronizedLyricsBytes = max(0, maximumSynchronizedLyricsBytes)
        self.maximumSupportedItemCount = max(0, maximumSupportedItemCount)
        self.maximumTextBytes = max(0, maximumTextBytes)
    }

    static let `default` = MusicMetadataResourceLimits(
        maximumArtworkBytes: 20 * 1024 * 1024,
        maximumSynchronizedLyricsBytes: 5 * 1024 * 1024
    )
}

enum MusicMetadataParser {
    static func parse(
        _ items: [RawMusicMetadataItem],
        fallbackFileName: String,
        limits: MusicMetadataResourceLimits = .default
    ) -> MusicMetadata {
        var title: String?
        var artist: String?
        var album: String?
        var artworkData: Data?
        var lyrics: String?
        var synchronizedLyricsData: Data?

        for item in items {
            let value: String? = item.stringValue.flatMap { value -> String? in
                guard value.utf8.count <= limits.maximumTextBytes else {
                    return nil
                }
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            switch item.identifier {
            case "id3/TIT2", "itsk/%A9nam":
                if title == nil, value?.isEmpty == false {
                    title = value
                }
            case "id3/TPE1", "itsk/%A9ART":
                if artist == nil, value?.isEmpty == false {
                    artist = value
                }
            case "id3/TALB", "itsk/%A9alb":
                if album == nil, value?.isEmpty == false {
                    album = value
                }
            case "id3/APIC", "itsk/covr":
                if artworkData == nil,
                   let data = item.dataValue,
                   !data.isEmpty,
                   data.count <= limits.maximumArtworkBytes {
                    artworkData = data
                }
            case "id3/USLT", "itsk/%A9lyr":
                if lyrics == nil, value?.isEmpty == false {
                    lyrics = value
                }
            case "id3/SYLT":
                if synchronizedLyricsData == nil,
                   let data = item.dataValue,
                   !data.isEmpty,
                   data.count <= limits.maximumSynchronizedLyricsBytes {
                    synchronizedLyricsData = data
                }
            default:
                break
            }
        }

        return MusicMetadata(
            title: title ?? fallbackTitle(from: fallbackFileName),
            artist: artist,
            album: album,
            artworkData: artworkData,
            lyrics: lyrics,
            synchronizedLyricsData: synchronizedLyricsData
        )
    }

    private static func fallbackTitle(from fileName: String) -> String {
        let trimmedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let finalDot = trimmedFileName.lastIndex(of: "."),
              trimmedFileName.lastIndex(of: "/").map({ $0 < finalDot }) ?? true else {
            return trimmedFileName
        }

        let stem = trimmedFileName[..<finalDot].trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? trimmedFileName : stem
    }
}
