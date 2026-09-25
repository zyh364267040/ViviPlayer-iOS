import Foundation
import AVFoundation
import XCTest
@testable import DrivePlayer

final class LRCSynchronizedLyricsDecoderTests: XCTestCase {
    func testExpandsMultipleTimestampsAndStablyOrdersDuplicateTimestamps() {
        let lrc = "[00:03][00:01]共享\n[00:01]第二个同刻\n[00:02]中间"
        let data = Data(lrc.utf8)

        let lyrics = LRCSynchronizedLyricsDecoder.decode(data)

        XCTAssertEqual(
            lyrics?.cues,
            [
                SynchronizedLyricsCue(timestampMilliseconds: 1_000, text: "共享"),
                SynchronizedLyricsCue(timestampMilliseconds: 1_000, text: "第二个同刻"),
                SynchronizedLyricsCue(timestampMilliseconds: 2_000, text: "中间"),
                SynchronizedLyricsCue(timestampMilliseconds: 3_000, text: "共享"),
            ]
        )
    }

    func testParsesUTF8BOMLineEndingsUnicodeAndSupportedTimestampPrecisions() {
        let lrc = "[00:01]第一句\n[00:02.1]第二句 🎵\r\n[00:03.12]第三句\r[01:04.123]第四句"
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(lrc.utf8)

        let lyrics = LRCSynchronizedLyricsDecoder.decode(data)

        XCTAssertEqual(
            lyrics?.cues,
            [
                SynchronizedLyricsCue(timestampMilliseconds: 1_000, text: "第一句"),
                SynchronizedLyricsCue(timestampMilliseconds: 2_100, text: "第二句 🎵"),
                SynchronizedLyricsCue(timestampMilliseconds: 3_120, text: "第三句"),
                SynchronizedLyricsCue(timestampMilliseconds: 64_123, text: "第四句"),
            ]
        )
    }

    func testAppliesNegativeGlobalOffsetAndClampsEffectiveTimeAtZero() {
        let lrc = "[offset:-1500]\n[00:01]提前\n[00:02]稍后"
        let data = Data(lrc.utf8)

        let lyrics = LRCSynchronizedLyricsDecoder.decode(data)

        XCTAssertEqual(
            lyrics?.cues,
            [
                SynchronizedLyricsCue(timestampMilliseconds: 0, text: "提前"),
                SynchronizedLyricsCue(timestampMilliseconds: 500, text: "稍后"),
            ]
        )
    }

    func testRejectsWholeFileWhenATimestampLineIsMalformed() {
        let lrc = "[00:01]有效\n[00:99]损坏"
        let data = Data(lrc.utf8)

        XCTAssertNil(LRCSynchronizedLyricsDecoder.decode(data))
    }

    func testRejectsWholeLRCWhenALaterTimestampTagIsMalformed() {
        let data = Data("[00:01.000][00:99.000]text\n".utf8)

        XCTAssertNil(LRCSynchronizedLyricsDecoder.decode(data))
    }

    func testRejectsWholeLRCWhenLaterBracketedTimestampTagIsMalformed() {
        let data = Data("[00:01]valid\n[00:02][xx:yy]malformed".utf8)

        XCTAssertNil(LRCSynchronizedLyricsDecoder.decode(data))
    }

    func testRejectsWholeLRCWhenPositiveOffsetOverflowsAnyCue() {
        let lrc = "[offset:+1]\n[00:01.000]keep\n[71582:47.295]overflow\n"
        let data = Data(lrc.utf8)

        XCTAssertNil(LRCSynchronizedLyricsDecoder.decode(data))
    }

    func testRejectsWholeLRCWhenOffsetMetadataIsMalformed() {
        let lrc = "[offset:not-a-number]\n[00:01.000]valid\n"
        let data = Data(lrc.utf8)

        XCTAssertNil(LRCSynchronizedLyricsDecoder.decode(data))
    }

    func testRejectsWholeLRCWhenOffsetMetadataIsRepeated() {
        let data = Data("[offset:+100]\n[offset:-100]\n[00:01.000]valid\n".utf8)

        XCTAssertNil(LRCSynchronizedLyricsDecoder.decode(data))
    }

    func testRejectsInputExceedingMaximumByteBudget() {
        let maximumByteBudget = 512 * 1024
        var data = Data("[00:01]有效\n".utf8)
        data.append(Data(repeating: 0x78, count: maximumByteBudget + 1 - data.count))

        XCTAssertNil(LRCSynchronizedLyricsDecoder.decode(data))
    }
}

final class MusicMetadataTests: XCTestCase {
    func testParserMapsTrimmedID3ValuesAndFallsBackForBlankOrMissingMetadata() {
        let title = RawMusicMetadataItem(
            identifier: "id3/TIT2",
            stringValue: "  Night Drive  ",
            dataValue: nil
        )
        let duplicateTitle = RawMusicMetadataItem(
            identifier: "id3/TIT2",
            stringValue: "  Night Drive  ",
            dataValue: nil
        )
        requireSendable(title)
        XCTAssertEqual(title, duplicateTitle)

        let parsed = MusicMetadataParser.parse(
            [
                title,
                RawMusicMetadataItem(identifier: "id3/TPE1", stringValue: "  The Comets\n", dataValue: nil),
                RawMusicMetadataItem(identifier: "id3/TALB", stringValue: "\tMidnight Roads  ", dataValue: nil),
                RawMusicMetadataItem(identifier: "other/binary", stringValue: nil, dataValue: Data([0x01]))
            ],
            fallbackFileName: "recording.mp3"
        )
        XCTAssertEqual(parsed.title, "Night Drive")
        XCTAssertEqual(parsed.artist, "The Comets")
        XCTAssertEqual(parsed.album, "Midnight Roads")

        let blank = MusicMetadataParser.parse(
            [
                RawMusicMetadataItem(identifier: "id3/TIT2", stringValue: " \n\t ", dataValue: nil),
                RawMusicMetadataItem(identifier: "id3/TPE1", stringValue: "   ", dataValue: nil),
                RawMusicMetadataItem(identifier: "id3/TALB", stringValue: "\n", dataValue: nil)
            ],
            fallbackFileName: "Live.Set.flac"
        )
        XCTAssertEqual(blank.title, "Live.Set")
        XCTAssertNil(blank.artist)
        XCTAssertNil(blank.album)

        let missing = MusicMetadataParser.parse([], fallbackFileName: "Untitled.m4a")
        XCTAssertEqual(missing.title, "Untitled")
        XCTAssertNil(missing.artist)
        XCTAssertNil(missing.album)
    }

    func testParserMapsFirstValidID3ArtworkLyricsAndSynchronizedLyricsValues() {
        let artwork = Data([0x01, 0x02, 0x03])
        let synchronizedLyrics = Data([0x10, 0x20, 0x30])
        let items = [
            RawMusicMetadataItem(identifier: "id3/TIT2", stringValue: "   ", dataValue: nil),
            RawMusicMetadataItem(identifier: "id3/APIC", stringValue: nil, dataValue: Data()),
            RawMusicMetadataItem(identifier: "id3/APIC", stringValue: nil, dataValue: artwork),
            RawMusicMetadataItem(identifier: "id3/APIC", stringValue: nil, dataValue: Data([0xFF])),
            RawMusicMetadataItem(identifier: "id3/USLT", stringValue: " \n\t ", dataValue: nil),
            RawMusicMetadataItem(identifier: "id3/USLT", stringValue: "  First line\nSecond line  ", dataValue: nil),
            RawMusicMetadataItem(identifier: "id3/USLT", stringValue: "Later lyrics", dataValue: nil),
            RawMusicMetadataItem(identifier: "id3/SYLT", stringValue: nil, dataValue: Data()),
            RawMusicMetadataItem(identifier: "id3/SYLT", stringValue: nil, dataValue: synchronizedLyrics),
            RawMusicMetadataItem(identifier: "id3/SYLT", stringValue: nil, dataValue: Data([0xEE]))
        ]

        let parsed = MusicMetadataParser.parse(items, fallbackFileName: "Fallback Track.mp3")
        let duplicate = MusicMetadataParser.parse(items, fallbackFileName: "Fallback Track.mp3")

        requireSendable(parsed)
        XCTAssertEqual(parsed, duplicate)
        XCTAssertEqual(parsed.title, "Fallback Track")
        XCTAssertEqual(parsed.artworkData, artwork)
        XCTAssertEqual(parsed.lyrics, "First line\nSecond line")
        XCTAssertEqual(parsed.synchronizedLyricsData, synchronizedLyrics)

        let invalidOnly = MusicMetadataParser.parse(
            [
                RawMusicMetadataItem(identifier: "id3/APIC", stringValue: nil, dataValue: Data()),
                RawMusicMetadataItem(identifier: "id3/USLT", stringValue: " \n\t ", dataValue: nil),
                RawMusicMetadataItem(identifier: "id3/SYLT", stringValue: nil, dataValue: Data())
            ],
            fallbackFileName: "Invalid Values.flac"
        )

        XCTAssertEqual(invalidOnly.title, "Invalid Values")
        XCTAssertNil(invalidOnly.artworkData)
        XCTAssertNil(invalidOnly.lyrics)
        XCTAssertNil(invalidOnly.synchronizedLyricsData)
    }

    func testParserRejectsOversizedBinaryMetadataAndRetainsFirstValidValuesWithinResourceLimits() {
        let limits = MusicMetadataResourceLimits(
            maximumArtworkBytes: 4,
            maximumSynchronizedLyricsBytes: 3
        )
        let equivalentLimits = MusicMetadataResourceLimits(
            maximumArtworkBytes: 4,
            maximumSynchronizedLyricsBytes: 3
        )
        let oversizedArtwork = Data(repeating: 0xAA, count: 5)
        let oversizedSynchronizedLyrics = Data(repeating: 0xBB, count: 4)
        let artworkAtLimit = Data(repeating: 0xCC, count: 4)
        let synchronizedLyricsAtLimit = Data(repeating: 0xDD, count: 3)

        requireSendable(limits)
        XCTAssertEqual(limits, equivalentLimits)

        let parsed = MusicMetadataParser.parse(
            [
                RawMusicMetadataItem(identifier: "id3/APIC", stringValue: nil, dataValue: oversizedArtwork),
                RawMusicMetadataItem(identifier: "id3/SYLT", stringValue: nil, dataValue: oversizedSynchronizedLyrics),
                RawMusicMetadataItem(identifier: "id3/APIC", stringValue: nil, dataValue: artworkAtLimit),
                RawMusicMetadataItem(identifier: "id3/SYLT", stringValue: nil, dataValue: synchronizedLyricsAtLimit),
                RawMusicMetadataItem(identifier: "id3/TIT2", stringValue: "Resource-Bounded Track", dataValue: nil)
            ],
            fallbackFileName: "Fallback.mp3",
            limits: limits
        )

        XCTAssertEqual(parsed.title, "Resource-Bounded Track")
        XCTAssertEqual(parsed.artworkData, artworkAtLimit)
        XCTAssertEqual(parsed.synchronizedLyricsData, synchronizedLyricsAtLimit)
        XCTAssertNotEqual(parsed.artworkData, oversizedArtwork)
        XCTAssertNotEqual(parsed.synchronizedLyricsData, oversizedSynchronizedLyrics)
    }

    func testParserIgnoresOversizedTextAndSelectsLaterTextAtResourceLimit() {
        let limits = MusicMetadataResourceLimits(
            maximumArtworkBytes: 4,
            maximumSynchronizedLyricsBytes: 3,
            maximumSupportedItemCount: 4,
            maximumTextBytes: 4
        )

        let parsed = MusicMetadataParser.parse(
            [
                RawMusicMetadataItem(identifier: "id3/TIT2", stringValue: "ABCDE", dataValue: nil),
                RawMusicMetadataItem(identifier: "id3/TIT2", stringValue: "WXYZ", dataValue: nil)
            ],
            fallbackFileName: "Fallback.mp3",
            limits: limits
        )

        XCTAssertEqual(parsed.title, "WXYZ")
    }

    func testParserMapsFirstValidCurrentSDKITunesM4ARawIdentifierValues() {
        let artwork = Data([0x01, 0x02, 0x03])
        let items = [
            RawMusicMetadataItem(identifier: "itsk/%A9nam", stringValue: " \n\t ", dataValue: nil),
            RawMusicMetadataItem(identifier: "itsk/%A9nam", stringValue: "  Night Drive  ", dataValue: nil),
            RawMusicMetadataItem(identifier: "itsk/%A9nam", stringValue: "Later Title", dataValue: nil),
            RawMusicMetadataItem(identifier: "itsk/%A9ART", stringValue: "   ", dataValue: nil),
            RawMusicMetadataItem(identifier: "itsk/%A9ART", stringValue: "  The Comets\n", dataValue: nil),
            RawMusicMetadataItem(identifier: "itsk/%A9ART", stringValue: "Later Artist", dataValue: nil),
            RawMusicMetadataItem(identifier: "itsk/%A9alb", stringValue: "\n", dataValue: nil),
            RawMusicMetadataItem(identifier: "itsk/%A9alb", stringValue: "\tMidnight Roads  ", dataValue: nil),
            RawMusicMetadataItem(identifier: "itsk/%A9alb", stringValue: "Later Album", dataValue: nil),
            RawMusicMetadataItem(identifier: "itsk/covr", stringValue: nil, dataValue: Data()),
            RawMusicMetadataItem(identifier: "itsk/covr", stringValue: nil, dataValue: artwork),
            RawMusicMetadataItem(identifier: "itsk/covr", stringValue: nil, dataValue: Data([0xFF])),
            RawMusicMetadataItem(identifier: "itsk/%A9lyr", stringValue: " \n\t ", dataValue: nil),
            RawMusicMetadataItem(identifier: "itsk/%A9lyr", stringValue: "  First line\nSecond line  ", dataValue: nil),
            RawMusicMetadataItem(identifier: "itsk/%A9lyr", stringValue: "Later lyrics", dataValue: nil)
        ]

        let parsed = MusicMetadataParser.parse(items, fallbackFileName: "Fallback Track.m4a")
        let duplicate = MusicMetadataParser.parse(items, fallbackFileName: "Fallback Track.m4a")

        requireSendable(parsed)
        XCTAssertEqual(parsed, duplicate)
        XCTAssertEqual(parsed.title, "Night Drive")
        XCTAssertEqual(parsed.artist, "The Comets")
        XCTAssertEqual(parsed.album, "Midnight Roads")
        XCTAssertEqual(parsed.artworkData, artwork)
        XCTAssertEqual(parsed.lyrics, "First line\nSecond line")
        XCTAssertNil(parsed.synchronizedLyricsData)
    }

    private func m4aFixtureData() throws -> Data {
        let url = try XCTUnwrap(Bundle(for: MusicMetadataTests.self)
            .url(forResource: "metadata-fixture", withExtension: "m4a"))
        return try Data(contentsOf: url)
    }


    func testAVFoundationRawLoaderLoadsRealM4AMetadataForParser() async throws {
        let fixtureData = try m4aFixtureData()
        let fixtureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicMetadataFixture-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try fixtureData.write(to: fixtureURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fixtureURL) }

        let rawItems = try await AVFoundationMusicMetadataRawLoader.load(from: fixtureURL)
        requireSendable(rawItems)

        let parsed = MusicMetadataParser.parse(
            rawItems,
            fallbackFileName: fixtureURL.lastPathComponent
        )
        requireSendable(parsed)
        XCTAssertEqual(parsed.title, "Fixture Title")
        XCTAssertEqual(parsed.artist, "Fixture Artist")
        XCTAssertEqual(parsed.album, "Fixture Album")
        XCTAssertEqual(parsed.lyrics, "Line one\nLine two")
        XCTAssertEqual(parsed.artworkData?.count, 68)
        XCTAssertNil(parsed.synchronizedLyricsData)
    }

    func testAVFoundationRawLoaderSkipsMalformedSupportedItemAndLoadsLaterSupportedItem() async {
        let malformedTitle = AVMutableMetadataItem()
        malformedTitle.identifier = AVMetadataIdentifier(rawValue: "id3/TIT2")
        let validArtist = AVMutableMetadataItem()
        validArtist.identifier = AVMetadataIdentifier(rawValue: "id3/TPE1")

        let stringValueLoader: @Sendable (AVMetadataItem) async throws -> String? = { item in
            if item.identifier?.rawValue == "id3/TIT2" {
                throw MusicMetadataRawItemLoaderTestError.malformedSupportedItem
            }
            return "Recovered Artist"
        }
        let dataValueLoader: @Sendable (AVMetadataItem) async throws -> Data? = { _ in nil }

        let rawItems = await AVFoundationMusicMetadataRawLoader.loadSupportedItems(
            [malformedTitle, validArtist],
            stringValueLoader: stringValueLoader,
            dataValueLoader: dataValueLoader
        )

        XCTAssertEqual(
            rawItems,
            [RawMusicMetadataItem(identifier: "id3/TPE1", stringValue: "Recovered Artist", dataValue: nil)]
        )
    }

    func testAVFoundationRawLoaderDiscardsOversizedBinaryAndLoadsLaterValidItem() async {
        let firstItem = AVMutableMetadataItem()
        firstItem.identifier = AVMetadataIdentifier(rawValue: "id3/APIC")
        firstItem.extendedLanguageTag = "oversized"
        let secondItem = AVMutableMetadataItem()
        secondItem.identifier = AVMetadataIdentifier(rawValue: "id3/APIC")
        secondItem.extendedLanguageTag = "valid"
        let limits = MusicMetadataResourceLimits(
            maximumArtworkBytes: 4,
            maximumSynchronizedLyricsBytes: 3
        )
        let oversizedArtwork = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let validArtwork = Data([0x06, 0x07, 0x08, 0x09])

        let stringValueLoader: @Sendable (AVMetadataItem) async throws -> String? = { _ in nil }
        let dataValueLoader: @Sendable (AVMetadataItem) async throws -> Data? = { item in
            item.extendedLanguageTag == "oversized" ? oversizedArtwork : validArtwork
        }

        let rawItems = await AVFoundationMusicMetadataRawLoader.loadSupportedItems(
            [firstItem, secondItem],
            limits: limits,
            stringValueLoader: stringValueLoader,
            dataValueLoader: dataValueLoader
        )

        XCTAssertEqual(
            rawItems,
            [RawMusicMetadataItem(identifier: "id3/APIC", stringValue: nil, dataValue: validArtwork)]
        )
    }

    func testAVFoundationRawLoaderDiscardsOversizedTextBeforeRetentionAndLoadsLaterValidItem() async {
        let firstItem = AVMutableMetadataItem()
        firstItem.identifier = AVMetadataIdentifier(rawValue: "id3/TIT2")
        firstItem.extendedLanguageTag = "oversized"
        let secondItem = AVMutableMetadataItem()
        secondItem.identifier = AVMetadataIdentifier(rawValue: "id3/TIT2")
        secondItem.extendedLanguageTag = "valid"
        let limits = MusicMetadataResourceLimits(
            maximumArtworkBytes: 4,
            maximumSynchronizedLyricsBytes: 3,
            maximumSupportedItemCount: 2,
            maximumTextBytes: 4
        )

        let stringValueLoader: @Sendable (AVMetadataItem) async throws -> String? = { item in
            item.extendedLanguageTag == "oversized" ? "ABCDE" : "WXYZ"
        }
        let dataValueLoader: @Sendable (AVMetadataItem) async throws -> Data? = { _ in nil }

        let rawItems = await AVFoundationMusicMetadataRawLoader.loadSupportedItems(
            [firstItem, secondItem],
            limits: limits,
            stringValueLoader: stringValueLoader,
            dataValueLoader: dataValueLoader
        )

        XCTAssertEqual(
            rawItems,
            [RawMusicMetadataItem(identifier: "id3/TIT2", stringValue: "WXYZ", dataValue: nil)]
        )
    }

    func testAVFoundationRawLoaderStopsBeforeLoadingValuesBeyondSupportedItemCountLimit() async {
        let title = AVMutableMetadataItem()
        title.identifier = AVMetadataIdentifier(rawValue: "id3/TIT2")
        let artist = AVMutableMetadataItem()
        artist.identifier = AVMetadataIdentifier(rawValue: "id3/TPE1")
        let album = AVMutableMetadataItem()
        album.identifier = AVMetadataIdentifier(rawValue: "id3/TALB")
        let limits = MusicMetadataResourceLimits(
            maximumArtworkBytes: 4,
            maximumSynchronizedLyricsBytes: 3,
            maximumSupportedItemCount: 2
        )
        let probe = SupportedMusicMetadataStringLoaderProbe()

        let rawItems = await AVFoundationMusicMetadataRawLoader.loadSupportedItems(
            [title, artist, album],
            limits: limits,
            stringValueLoader: { item in await probe.loadString(for: item) },
            dataValueLoader: { _ in nil }
        )

        XCTAssertEqual(
            rawItems,
            [
                RawMusicMetadataItem(identifier: "id3/TIT2", stringValue: "Count-Bounded Title", dataValue: nil),
                RawMusicMetadataItem(identifier: "id3/TPE1", stringValue: "Count-Bounded Artist", dataValue: nil)
            ]
        )
        XCTAssertFalse(rawItems.contains { $0.identifier == "id3/TALB" })
        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 2)
    }

    @MainActor
    func testDefaultMusicLibraryRefreshAttachesRealEmbeddedM4AMetadataToScannedMusicItem() async throws {
        let fixtureData = try m4aFixtureData()

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibraryMetadata-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let documentsURL = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        let fixtureURL = documentsURL.appendingPathComponent("Library Fixture.m4a")
        try fixtureData.write(to: fixtureURL, options: .atomic)

        let storage = MediaLibraryStorage(
            rootURL: documentsURL,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        )
        let library = MusicLibrary(storage: storage)

        await library.refresh()

        XCTAssertNil(library.libraryErrorMessage)
        XCTAssertEqual(library.songs.count, 1)
        let song = try XCTUnwrap(library.songs.first)
        XCTAssertEqual(song.fileName, "Library Fixture.m4a")
        let metadata = try XCTUnwrap(song.metadata)
        XCTAssertEqual(metadata.title, "Fixture Title")
        XCTAssertEqual(metadata.artist, "Fixture Artist")
        XCTAssertEqual(metadata.album, "Fixture Album")
        XCTAssertEqual(metadata.lyrics, "Line one\nLine two")
        XCTAssertEqual(metadata.artworkData?.count, 68)
        XCTAssertNil(metadata.synchronizedLyricsData)
    }

    @MainActor
    func testMusicLibraryRefreshReusesPersistedMetadataAndDurationAcrossStoreInstancesForUnchangedFile() async throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("MusicLibraryMetadataSnapshot-\(UUID().uuidString)", isDirectory: true)
        let documentsURL = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        let legacyAudioURL = temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true)
        let legacyVideoURL = temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        let cacheFile = temporaryRoot.appendingPathComponent("MediaMetadataSnapshots.json")
        try fileManager.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let musicURL = documentsURL.appendingPathComponent("Unchanged Track.mp3")
        try Data("music fixture".utf8).write(to: musicURL, options: .atomic)

        let firstArtwork = Data([0x01, 0x02, 0x03])
        let firstMetadataProbe = PersistedMusicMetadataLoaderProbe(items: [
            RawMusicMetadataItem(
                identifier: "id3/TIT2",
                stringValue: "Persisted Title",
                dataValue: nil
            ),
            RawMusicMetadataItem(
                identifier: "id3/TPE1",
                stringValue: "Persisted Artist",
                dataValue: nil
            ),
            RawMusicMetadataItem(
                identifier: "id3/APIC",
                stringValue: nil,
                dataValue: firstArtwork
            ),
        ])
        let firstDurationProbe = MusicDurationLoaderProbe(duration: 42)
        do {
            let storage = MediaLibraryStorage(
                rootURL: documentsURL,
                legacyAudioURL: legacyAudioURL,
                legacyVideoURL: legacyVideoURL,
                fileManager: fileManager
            )
            let snapshotStore = MediaMetadataSnapshotStore(fileURL: cacheFile)
            let metadataLoader = MusicMetadataLoader(rawItemLoader: { url in
                await firstMetadataProbe.loadRawItems(for: url)
            })
            let library = MusicLibrary(
                storage: storage,
                metadataLoader: metadataLoader,
                metadataSnapshotStore: snapshotStore,
                durationLoader: { url in await firstDurationProbe.loadDuration(for: url) }
            )

            await library.refresh()

            let song = try XCTUnwrap(library.songs.first)
            let metadata = try XCTUnwrap(song.metadata)
            XCTAssertEqual(metadata.title, "Persisted Title")
            XCTAssertEqual(metadata.artist, "Persisted Artist")
            XCTAssertEqual(metadata.artworkData, firstArtwork)
            XCTAssertEqual(song.duration, 42)
            let metadataCallCount = await firstMetadataProbe.callCount()
            let durationCallCount = await firstDurationProbe.callCount()
            XCTAssertEqual(metadataCallCount, 1)
            XCTAssertEqual(durationCallCount, 1)
        }

        let secondMetadataProbe = PersistedMusicMetadataLoaderProbe(items: [
            RawMusicMetadataItem(
                identifier: "id3/TIT2",
                stringValue: "Unexpected Reloaded Title",
                dataValue: nil
            ),
            RawMusicMetadataItem(
                identifier: "id3/TPE1",
                stringValue: "Unexpected Reloaded Artist",
                dataValue: nil
            ),
            RawMusicMetadataItem(
                identifier: "id3/APIC",
                stringValue: nil,
                dataValue: Data([0x99])
            ),
        ])
        let secondDurationProbe = MusicDurationLoaderProbe(duration: 99)
        do {
            let storage = MediaLibraryStorage(
                rootURL: documentsURL,
                legacyAudioURL: legacyAudioURL,
                legacyVideoURL: legacyVideoURL,
                fileManager: fileManager
            )
            let snapshotStore = MediaMetadataSnapshotStore(fileURL: cacheFile)
            let metadataLoader = MusicMetadataLoader(rawItemLoader: { url in
                await secondMetadataProbe.loadRawItems(for: url)
            })
            let library = MusicLibrary(
                storage: storage,
                metadataLoader: metadataLoader,
                metadataSnapshotStore: snapshotStore,
                durationLoader: { url in await secondDurationProbe.loadDuration(for: url) }
            )

            await library.refresh()

            let song = try XCTUnwrap(library.songs.first)
            let metadata = try XCTUnwrap(song.metadata)
            XCTAssertEqual(metadata.title, "Persisted Title")
            XCTAssertEqual(metadata.artist, "Persisted Artist")
            XCTAssertEqual(metadata.artworkData, firstArtwork)
            XCTAssertEqual(song.duration, 42)
            let metadataCallCount = await secondMetadataProbe.callCount()
            let durationCallCount = await secondDurationProbe.callCount()
            XCTAssertEqual(metadataCallCount, 0)
            XCTAssertEqual(durationCallCount, 0)
        }
    }

    @MainActor
    func testMusicLibraryRefreshPrefersValidSameBasenameLRCOverEmbeddedSynchronizedLyrics() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibrarySidecarLyrics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let documentsURL = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        try Data().write(to: documentsURL.appendingPathComponent("Song.mp3"))
        try Data("[00:02]外部歌词".utf8).write(
            to: documentsURL.appendingPathComponent("Song.lrc"),
            options: .atomic
        )

        let embeddedSynchronizedLyrics = Data([
            0x00,
            0x7A, 0x68, 0x6F,
            0x02,
            0x01,
            0x00,
            0xE5, 0x86, 0x85, 0xE5, 0xB5, 0x8C, 0xE6, 0xAD, 0x8C, 0xE8, 0xAF, 0x8D, 0x00,
            0x00, 0x00, 0x07, 0xD0,
        ])
        let metadataLoader = MusicMetadataLoader(rawItemLoader: { _ in
            [
                RawMusicMetadataItem(
                    identifier: "id3/TIT2",
                    stringValue: "Embedded Title",
                    dataValue: nil
                ),
                RawMusicMetadataItem(
                    identifier: "id3/SYLT",
                    stringValue: nil,
                    dataValue: embeddedSynchronizedLyrics
                ),
            ]
        })
        let storage = MediaLibraryStorage(
            rootURL: documentsURL,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        )
        let library = MusicLibrary(storage: storage, metadataLoader: metadataLoader)

        await library.refresh()

        let song = try XCTUnwrap(library.songs.first)
        let metadata = try XCTUnwrap(song.metadata)
        XCTAssertEqual(metadata.title, "Embedded Title")
        XCTAssertEqual(
            metadata.synchronizedLyrics?.cues,
            [SynchronizedLyricsCue(timestampMilliseconds: 2_000, text: "外部歌词")]
        )
    }

    @MainActor
    func testMusicLibraryRefreshPublishesURLBackedSongsWhileMetadataEnrichmentIsPending() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibraryEarlyPublication-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let documentsURL = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        try Data("music fixture".utf8).write(
            to: documentsURL.appendingPathComponent("Immediate.mp3")
        )

        let probe = ControllableMusicMetadataLoaderProbe()
        let storage = MediaLibraryStorage(
            rootURL: documentsURL,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        )
        let library = MusicLibrary(
            storage: storage,
            metadataLoader: MusicMetadataLoader(rawItemLoader: { url in
                await probe.loadRawItems(for: url)
            }),
            durationLoader: { _ in 42 }
        )

        let refresh = Task { await library.refresh() }
        await probe.waitUntilStarted()

        XCTAssertEqual(library.songs.map(\.fileName), ["Immediate.mp3"])
        XCTAssertNil(library.songs.first?.metadata)
        XCTAssertNil(library.songs.first?.duration)
        XCTAssertTrue(library.isLoading)

        await probe.complete(title: "Enriched Title")
        _ = await refresh.value

        XCTAssertEqual(library.songs.first?.metadata?.title, "Enriched Title")
        XCTAssertEqual(library.songs.first?.duration, 42)
        XCTAssertFalse(library.isLoading)
    }

    @MainActor
    func testMusicLibraryRefreshPublishesURLBackedSongsWhileLyricSidecarsArePending() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibrarySidecarEarlyPublication-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let documentsURL = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        for name in ["First.mp3", "Immediate.mp3", "Third.mp3"] {
            try Data("music fixture".utf8).write(to: documentsURL.appendingPathComponent(name))
        }

        let sidecarProbe = ControllableLyricSidecarLoaderProbe()
        let library = MusicLibrary(
            storage: MediaLibraryStorage(
                rootURL: documentsURL,
                legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true),
                legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
            ),
            metadataLoader: MusicMetadataLoader(rawItemLoader: { _ in [] }),
            durationLoader: { _ in 42 },
            maximumConcurrentEnrichmentCount: 2,
            lyricSidecarLoader: { url in await sidecarProbe.load(for: url) }
        )

        let refresh = Task { await library.refresh() }
        await sidecarProbe.waitUntilSaturated()

        XCTAssertEqual(library.songs.map(\.fileName), ["First.mp3", "Immediate.mp3", "Third.mp3"])
        XCTAssertTrue(library.songs.allSatisfy { $0.metadata == nil })
        XCTAssertTrue(library.songs.allSatisfy { $0.duration == nil })
        XCTAssertTrue(library.isLoading)
        let maximumActive = await sidecarProbe.maximumActiveCount()
        XCTAssertEqual(maximumActive, 2)

        await sidecarProbe.release(with: Data("[00:01.00]Sidecar lyric".utf8))
        _ = await refresh.value

        XCTAssertTrue(library.songs.allSatisfy {
            $0.metadata?.synchronizedLyrics?.cues == [
                SynchronizedLyricsCue(timestampMilliseconds: 1_000, text: "Sidecar lyric")
            ]
        })
        XCTAssertTrue(library.songs.allSatisfy { $0.duration == 42 })
        XCTAssertFalse(library.isLoading)
    }

    @MainActor
    func testMusicLibraryRefreshDiscoversSidecarAddedAfterEarlierRefresh() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibraryAddedSidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let documentsURL = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        try Data("music fixture".utf8).write(to: documentsURL.appendingPathComponent("Song.mp3"))

        let library = MusicLibrary(
            storage: MediaLibraryStorage(
                rootURL: documentsURL,
                legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true),
                legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
            ),
            metadataLoader: MusicMetadataLoader(rawItemLoader: { _ in [] }),
            metadataSnapshotStore: MediaMetadataSnapshotStore(
                fileURL: temporaryRoot.appendingPathComponent("MediaMetadataSnapshots.json")
            ),
            durationLoader: { _ in 42 }
        )

        await library.refresh()
        XCTAssertNil(library.songs.first?.metadata?.synchronizedLyrics)

        try Data("[00:01.00]New sidecar lyric".utf8).write(
            to: documentsURL.appendingPathComponent("Song.lrc")
        )
        await library.refresh()

        XCTAssertEqual(
            library.songs.first?.metadata?.synchronizedLyrics?.cues,
            [SynchronizedLyricsCue(timestampMilliseconds: 1_000, text: "New sidecar lyric")]
        )
    }

    @MainActor
    func testMusicLibraryRefreshDiscardsMetadataWhenSourceIsDeletedDuringEnrichment() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibraryDeletedDuringEnrichment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let documentsURL = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        let songURL = documentsURL.appendingPathComponent("Deleted.mp3")
        try Data("music fixture".utf8).write(to: songURL)

        let probe = ControllableMusicMetadataLoaderProbe()
        let storage = MediaLibraryStorage(
            rootURL: documentsURL,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        )
        let library = MusicLibrary(
            storage: storage,
            metadataLoader: MusicMetadataLoader(rawItemLoader: { url in
                await probe.loadRawItems(for: url)
            }),
            durationLoader: { _ in 42 }
        )

        let refresh = Task { await library.refresh() }
        await probe.waitUntilStarted()
        try FileManager.default.removeItem(at: songURL)
        await probe.complete(title: "Deleted Source Title")
        _ = await refresh.value

        XCTAssertTrue(library.songs.isEmpty)
    }

    @MainActor
    func testMusicLibraryRefreshRetriesMetadataWhenSourceIsReplacedDuringEnrichment() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibraryReplacedDuringEnrichment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let documentsURL = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        let songURL = documentsURL.appendingPathComponent("Replaced.mp3")
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("AAAA".utf8).write(to: songURL)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: songURL.path)

        let probe = ControllableReplacingMusicMetadataLoaderProbe()
        let storage = MediaLibraryStorage(
            rootURL: documentsURL,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        )
        let library = MusicLibrary(
            storage: storage,
            metadataLoader: MusicMetadataLoader(rawItemLoader: { url in
                await probe.loadRawItems(for: url)
            }),
            durationLoader: { _ in 42 }
        )

        let refresh = Task { await library.refresh() }
        await probe.waitUntilStarted()
        try Data("BBBB".utf8).write(to: songURL, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: songURL.path)
        await probe.completeFirstLoad()
        _ = await refresh.value

        let callCount = await probe.callCount()
        XCTAssertEqual(library.songs.first?.metadata?.title, "Replacement Title")
        XCTAssertEqual(callCount, 2)
    }

    @MainActor
    func testMusicLibraryRefreshRejectsCachedSnapshotWhenSourceIsReplacedDuringCacheHit() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibraryCacheHitReplacement-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let documentsURL = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        let songURL = documentsURL.appendingPathComponent("Cached.mp3")
        let restoredMTime = Date(timeIntervalSince1970: 1_700_000_000)
        try Data("AAAA".utf8).write(to: songURL, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: restoredMTime], ofItemAtPath: songURL.path)

        let cacheURL = temporaryRoot.appendingPathComponent("MediaMetadataSnapshots.json")
        let writer = MediaMetadataSnapshotStore(fileURL: cacheURL)
        let optionalIdentity = await writer.sourceIdentity(for: songURL)
        let identity = try XCTUnwrap(optionalIdentity)
        let revision = await writer.beginRefresh(for: .music)
        await writer.replaceMusic(with: [
            songURL: MediaMetadataSnapshotStore.MusicSnapshot(
                fingerprint: identity,
                duration: 42,
                metadata: MusicMetadata(
                    title: "Cached Title",
                    artist: nil,
                    album: nil,
                    artworkData: nil,
                    lyrics: nil,
                    synchronizedLyricsData: nil
                )
            )
        ], revision: revision)

        let cacheHitGate = ControllableCacheHitGate()
        let metadataProbe = PersistedMusicMetadataLoaderProbe(items: [
            RawMusicMetadataItem(identifier: "id3/TIT2", stringValue: "Replacement Title", dataValue: nil)
        ])
        let durationProbe = MusicDurationLoaderProbe(duration: 99)
        let reader = MediaMetadataSnapshotStore(
            fileURL: cacheURL,
            musicSnapshotPreReturnHook: { await cacheHitGate.wait() }
        )
        let library = MusicLibrary(
            storage: MediaLibraryStorage(
                rootURL: documentsURL,
                legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true),
                legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
            ),
            metadataLoader: MusicMetadataLoader(rawItemLoader: { url in
                await metadataProbe.loadRawItems(for: url)
            }),
            metadataSnapshotStore: reader,
            durationLoader: { url in await durationProbe.loadDuration(for: url) }
        )

        let refresh = Task { await library.refresh() }
        await cacheHitGate.waitUntilBlocked()
        try Data("BBBB".utf8).write(to: songURL, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: restoredMTime], ofItemAtPath: songURL.path)
        await cacheHitGate.release()
        _ = await refresh.value

        XCTAssertEqual(library.songs.first?.metadata?.title, "Replacement Title")
        XCTAssertEqual(library.songs.first?.duration, 99)
        let metadataCallCount = await metadataProbe.callCount()
        let durationCallCount = await durationProbe.callCount()
        XCTAssertEqual(metadataCallCount, 1)
        XCTAssertEqual(durationCallCount, 1)
    }

    @MainActor
    func testMusicLibraryRefreshDiscardsCachedSnapshotWhenSourceIsDeletedDuringCacheHit() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibraryCacheHitDeletion-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let documentsURL = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        let songURL = documentsURL.appendingPathComponent("Cached.mp3")
        try Data("cached media".utf8).write(to: songURL)

        let cacheURL = temporaryRoot.appendingPathComponent("MediaMetadataSnapshots.json")
        let writer = MediaMetadataSnapshotStore(fileURL: cacheURL)
        let optionalIdentity = await writer.sourceIdentity(for: songURL)
        let identity = try XCTUnwrap(optionalIdentity)
        let revision = await writer.beginRefresh(for: .music)
        await writer.replaceMusic(with: [
            songURL: MediaMetadataSnapshotStore.MusicSnapshot(
                fingerprint: identity,
                duration: 42,
                metadata: MusicMetadata(
                    title: "Cached Title",
                    artist: nil,
                    album: nil,
                    artworkData: nil,
                    lyrics: nil,
                    synchronizedLyricsData: nil
                )
            )
        ], revision: revision)

        let cacheHitGate = ControllableCacheHitGate()
        let reader = MediaMetadataSnapshotStore(
            fileURL: cacheURL,
            musicSnapshotPreReturnHook: { await cacheHitGate.wait() }
        )
        let library = MusicLibrary(
            storage: MediaLibraryStorage(
                rootURL: documentsURL,
                legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true),
                legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
            ),
            metadataSnapshotStore: reader,
            durationLoader: { _ in 99 }
        )

        let refresh = Task { await library.refresh() }
        await cacheHitGate.waitUntilBlocked()
        try FileManager.default.removeItem(at: songURL)
        await cacheHitGate.release()
        _ = await refresh.value

        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertFalse(library.isLoading)
    }

    @MainActor
    func testRootTabViewUpdatesPlaybackQueueForEveryPublishedMusicList() throws {
        let testsURL = URL(fileURLWithPath: #filePath)
        let rootTabViewURL = testsURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("DrivePlayer/Views/RootTabView.swift")
        let source = try String(contentsOf: rootTabViewURL, encoding: .utf8)
        let compactSource = source.filter { !$0.isWhitespace }

        XCTAssertTrue(
            compactSource.contains(".onReceive(musicLibrary.$latestReconciliationPublication){publicationinplayback.syncLibrary(publication.songs,snapshot:publication.reconciliationSnapshot)}"),
            "RootTabView must bind each publication's rows and authority to the shared API exercised by the gated cheap-playback regressions"
        )
    }

    @MainActor
    func testMusicLibraryRefreshUsesConfiguredBoundedMetadataEnrichmentConcurrency() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibraryBoundedEnrichment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let documentsURL = temporaryRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        let fileNames = [
            "09 Zulu.mp3",
            "01 Alpha.mp3",
            "07 Golf.mp3",
            "03 Charlie.mp3",
            "08 Hotel.mp3",
            "02 Bravo.mp3",
            "06 Foxtrot.mp3",
            "04 Delta.mp3",
            "05 Echo.mp3",
        ]
        for fileName in fileNames {
            try Data().write(to: documentsURL.appendingPathComponent(fileName))
        }

        let probe = BoundedMetadataEnrichmentProbe()
        let metadataLoader = MusicMetadataLoader(rawItemLoader: { url in
            try await probe.loadRawItems(for: url)
        })
        let storage = MediaLibraryStorage(
            rootURL: documentsURL,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        )
        let library = MusicLibrary(
            storage: storage,
            metadataLoader: metadataLoader,
            maximumConcurrentEnrichmentCount: 3
        )

        await library.refresh()

        let maximumActive = await probe.maximumActive
        XCTAssertEqual(maximumActive, 3)
        XCTAssertEqual(library.songs.count, 9)
        XCTAssertEqual(
            library.songs.map { $0.fileName },
            fileNames.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        )
    }

    @MainActor
    func testMusicLibraryImportReportsLowercaseLRCSidecarSeparatelyFromSongs() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibraryImportSidecar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let sourceDirectory = temporaryRoot.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("Song.lrc")
        try Data("[00:01.00]External lyrics".utf8).write(to: source, options: .atomic)

        let storageRoot = temporaryRoot.appendingPathComponent("MediaLibrary", isDirectory: true)
        let storage = MediaLibraryStorage(
            rootURL: storageRoot,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        )
        let library = MusicLibrary(storage: storage)

        let report = await library.importSongs(from: [source])

        XCTAssertEqual(report.importedSongCount, 0)
        XCTAssertEqual(report.importedLyricCount, 1)
        XCTAssertTrue(report.failedFileNames.isEmpty)
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertEqual(try storage.scanLyricSidecars().map(\.lastPathComponent), ["Song.lrc"])
    }

    @MainActor
    func testMusicLibraryImportRejectsUnsupportedExtensionWithoutCopying() async throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicLibraryImportUnsupported-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }

        let sourceDirectory = temporaryRoot.appendingPathComponent("Source", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let source = sourceDirectory.appendingPathComponent("notes.txt")
        try Data("Not a supported media file".utf8).write(to: source, options: .atomic)

        let storageRoot = temporaryRoot.appendingPathComponent("MediaLibrary", isDirectory: true)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        let storage = MediaLibraryStorage(
            rootURL: storageRoot,
            legacyAudioURL: temporaryRoot.appendingPathComponent("ImportedAudio", isDirectory: true),
            legacyVideoURL: temporaryRoot.appendingPathComponent("ImportedVideos", isDirectory: true)
        )
        let library = MusicLibrary(storage: storage)

        let report = await library.importSongs(from: [source])

        XCTAssertEqual(report.importedSongCount, 0)
        XCTAssertEqual(report.importedLyricCount, 0)
        XCTAssertEqual(report.failedFileNames, ["notes.txt"])
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageRoot.appendingPathComponent("notes.txt").path))
    }

    func testLoaderCachesParsedMetadataForStandardizedURLAndFingerprintAndReloadsWhenFingerprintChanges() async throws {
        let probe = MusicMetadataRawItemLoaderProbe()
        let rawItemLoader: @Sendable (URL) async throws -> [RawMusicMetadataItem] = { url in
            await probe.loadRawItems(for: url)
        }
        let loader = MusicMetadataLoader(rawItemLoader: rawItemLoader)
        let unstandardizedURL = URL(fileURLWithPath: "/tmp/Music/../Cached Track.mp3")
        let standardizedURL = unstandardizedURL.standardizedFileURL
        let initialFingerprint = MusicMetadataFileFingerprint(
            fileSize: 1_024,
            modificationDate: Date(timeIntervalSince1970: 1_000)
        )
        let equalFingerprint = MusicMetadataFileFingerprint(
            fileSize: 1_024,
            modificationDate: Date(timeIntervalSince1970: 1_000)
        )
        let changedFingerprint = MusicMetadataFileFingerprint(
            fileSize: 2_048,
            modificationDate: Date(timeIntervalSince1970: 2_000)
        )

        requireSendable(initialFingerprint)
        requireSendable(loader)
        XCTAssertEqual(initialFingerprint, equalFingerprint)
        XCTAssertEqual(unstandardizedURL.standardizedFileURL, standardizedURL)

        let first = try await loader.load(url: unstandardizedURL, fingerprint: initialFingerprint)
        let cached = try await loader.load(url: standardizedURL, fingerprint: equalFingerprint)

        requireSendable(first)
        XCTAssertEqual(first, cached)
        XCTAssertEqual(first.title, "First Load")

        let reloaded = try await loader.load(url: unstandardizedURL, fingerprint: changedFingerprint)

        requireSendable(reloaded)
        XCTAssertEqual(reloaded.title, "Second Load")
        XCTAssertNotEqual(reloaded, first)
        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testLoaderEvictsLeastRecentlyUsedMetadataWhenCacheCapacityIsReached() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicMetadataLoader-LRU-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let urlA = temporaryDirectory.appendingPathComponent("A.mp3")
        let urlB = temporaryDirectory.appendingPathComponent("B.mp3")
        let urlC = temporaryDirectory.appendingPathComponent("C.mp3")
        try Data([0x41]).write(to: urlA)
        try Data([0x42, 0x42]).write(to: urlB)
        try Data([0x43, 0x43, 0x43]).write(to: urlC)

        let probe = URLCountingMusicMetadataRawItemLoaderProbe()
        let loader = MusicMetadataLoader(maximumCachedEntryCount: 2, rawItemLoader: { url in
            await probe.loadRawItems(for: url)
        })

        let firstA = await loader.load(from: urlA)
        let firstB = await loader.load(from: urlB)
        let firstC = await loader.load(from: urlC)
        let cachedB = await loader.load(from: urlB)
        let reloadedA = await loader.load(from: urlA)

        XCTAssertEqual(firstA.title, "A")
        XCTAssertEqual(firstB.title, "B")
        XCTAssertEqual(firstC.title, "C")
        XCTAssertEqual(cachedB.title, "B")
        XCTAssertEqual(reloadedA.title, "A")
        let callCountA = await probe.callCount(for: urlA)
        let callCountB = await probe.callCount(for: urlB)
        let callCountC = await probe.callCount(for: urlC)
        XCTAssertEqual(callCountA, 2)
        XCTAssertEqual(callCountB, 1)
        XCTAssertEqual(callCountC, 1)
    }

    func testLoaderDoesNotLetOlderFingerprintCompletionOverwriteNewerFingerprintCacheEntry() async throws {
        let probe = ReentrantMusicMetadataRawItemLoaderProbe()
        let loader = MusicMetadataLoader(rawItemLoader: { url in
            await probe.loadRawItems(for: url)
        })
        let url = URL(fileURLWithPath: "/tmp/Reentrant Metadata.mp3").standardizedFileURL
        let oldFingerprint = MusicMetadataFileFingerprint(
            fileSize: 1_024,
            modificationDate: Date(timeIntervalSince1970: 1_000)
        )
        let newFingerprint = MusicMetadataFileFingerprint(
            fileSize: 2_048,
            modificationDate: Date(timeIntervalSince1970: 2_000)
        )

        async let oldMetadata = loader.load(url: url, fingerprint: oldFingerprint)
        await probe.waitUntilCallCount(1)

        async let newMetadata = loader.load(url: url, fingerprint: newFingerprint)
        await probe.waitUntilCallCount(2)
        await probe.completeCall(2, title: "New Metadata")
        let completedNewMetadata = try await newMetadata

        await probe.completeCall(1, title: "Old Metadata")
        let completedOldMetadata = try await oldMetadata

        XCTAssertEqual(completedNewMetadata.title, "New Metadata")
        XCTAssertEqual(completedOldMetadata.title, "Old Metadata")

        let cachedNewMetadata = try await loader.load(url: url, fingerprint: newFingerprint)

        XCTAssertEqual(cachedNewMetadata.title, "New Metadata")
        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 2)
    }

    func testLoaderConvenienceLoadFallsBackRetriesAfterFailureAndCachesSuccessfulEmptyMetadata() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicMetadataLoader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let detourDirectory = temporaryDirectory.appendingPathComponent("Detour", isDirectory: true)
        try FileManager.default.createDirectory(at: detourDirectory, withIntermediateDirectories: false)
        let standardizedURL = temporaryDirectory.appendingPathComponent("No Metadata.mp3")
        try Data([0x01, 0x02, 0x03]).write(to: standardizedURL)
        let unstandardizedURL = detourDirectory
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("No Metadata.mp3")

        let probe = FailingThenEmptyMusicMetadataRawItemLoaderProbe()
        let loader = MusicMetadataLoader(rawItemLoader: { url in
            try await probe.loadRawItems(for: url)
        })
        requireSendable(loader)

        let first = await loader.load(from: unstandardizedURL)
        requireSendable(first)
        XCTAssertEqual(first.title, "No Metadata")
        XCTAssertNil(first.artist)
        XCTAssertNil(first.album)
        XCTAssertNil(first.artworkData)
        XCTAssertNil(first.lyrics)
        XCTAssertNil(first.synchronizedLyricsData)

        let second = await loader.load(from: standardizedURL)
        requireSendable(second)
        XCTAssertEqual(second, first)

        let third = await loader.load(from: standardizedURL)
        requireSendable(third)
        XCTAssertEqual(third, first)
        let callCount = await probe.callCount()
        XCTAssertEqual(callCount, 2)
    }

    private func requireSendable<T: Sendable>(_ value: T) {}
}

private enum MusicMetadataRawItemLoaderTestError: Error {
    case firstLoadFailed
    case malformedSupportedItem
}

private actor ControllableMusicMetadataLoaderProbe {
    private var continuation: CheckedContinuation<[RawMusicMetadataItem], Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var started = false

    func loadRawItems(for _: URL) async -> [RawMusicMetadataItem] {
        started = true
        startedContinuation?.resume()
        startedContinuation = nil
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func complete(title: String) {
        continuation?.resume(returning: [
            RawMusicMetadataItem(identifier: "id3/TIT2", stringValue: title, dataValue: nil)
        ])
        continuation = nil
    }
}

private actor ControllableLyricSidecarLoaderProbe {
    private var active = 0
    private var maximumActive = 0
    private var releaseValue: Data?
    private var isReleased = false
    private var continuations: [CheckedContinuation<Data?, Never>] = []
    private var saturatedContinuation: CheckedContinuation<Void, Never>?

    func load(for _: URL) async -> Data? {
        guard !isReleased else { return releaseValue }
        active += 1
        maximumActive = max(maximumActive, active)
        if active == 2 {
            saturatedContinuation?.resume()
            saturatedContinuation = nil
        }
        let value = await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        active -= 1
        return value
    }

    func waitUntilSaturated() async {
        guard maximumActive < 2 else { return }
        await withCheckedContinuation { continuation in
            saturatedContinuation = continuation
        }
    }

    func maximumActiveCount() -> Int {
        maximumActive
    }

    func release(with value: Data) {
        releaseValue = value
        isReleased = true
        let pending = continuations
        continuations = []
        for continuation in pending {
            continuation.resume(returning: value)
        }
    }
}

private actor ControllableCacheHitGate {
    private var blocked = false
    private var shouldBlock = true
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard shouldBlock else { return }
        shouldBlock = false
        blocked = true
        blockedContinuation?.resume()
        blockedContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { continuation in
            blockedContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor ControllableReplacingMusicMetadataLoaderProbe {
    private var calls = 0
    private var continuation: CheckedContinuation<[RawMusicMetadataItem], Never>?
    private var startedContinuation: CheckedContinuation<Void, Never>?

    func loadRawItems(for _: URL) async -> [RawMusicMetadataItem] {
        calls += 1
        if calls > 1 {
            return [RawMusicMetadataItem(
                identifier: "id3/TIT2",
                stringValue: "Replacement Title",
                dataValue: nil
            )]
        }
        startedContinuation?.resume()
        startedContinuation = nil
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard calls == 0 else { return }
        await withCheckedContinuation { continuation in
            startedContinuation = continuation
        }
    }

    func completeFirstLoad() {
        continuation?.resume(returning: [RawMusicMetadataItem(
            identifier: "id3/TIT2",
            stringValue: "Stale Title",
            dataValue: nil
        )])
        continuation = nil
    }

    func callCount() -> Int {
        calls
    }
}

private actor BoundedMetadataEnrichmentProbe {
    private var active = 0
    private(set) var maximumActive = 0

    func loadRawItems(for url: URL) async throws -> [RawMusicMetadataItem] {
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }

        try await Task.sleep(for: .milliseconds(100))
        return [
            RawMusicMetadataItem(
                identifier: "id3/TIT2",
                stringValue: "Metadata for \(url.lastPathComponent)",
                dataValue: nil
            )
        ]
    }
}

private actor FailingThenEmptyMusicMetadataRawItemLoaderProbe {
    private var calls = 0

    func loadRawItems(for _: URL) throws -> [RawMusicMetadataItem] {
        calls += 1
        if calls == 1 {
            throw MusicMetadataRawItemLoaderTestError.firstLoadFailed
        }
        return []
    }

    func callCount() -> Int {
        calls
    }
}

private actor MusicMetadataRawItemLoaderProbe {
    private var calls = 0

    func loadRawItems(for _: URL) -> [RawMusicMetadataItem] {
        calls += 1
        let title = calls == 1 ? "First Load" : "Second Load"
        return [RawMusicMetadataItem(identifier: "id3/TIT2", stringValue: title, dataValue: nil)]
    }

    func callCount() -> Int {
        calls
    }
}

private actor PersistedMusicMetadataLoaderProbe {
    private let items: [RawMusicMetadataItem]
    private var calls = 0

    init(items: [RawMusicMetadataItem]) {
        self.items = items
    }

    func loadRawItems(for _: URL) -> [RawMusicMetadataItem] {
        calls += 1
        return items
    }

    func callCount() -> Int {
        calls
    }
}

private actor MusicDurationLoaderProbe {
    private let duration: TimeInterval
    private var calls = 0

    init(duration: TimeInterval) {
        self.duration = duration
    }

    func loadDuration(for _: URL) -> TimeInterval? {
        calls += 1
        return duration
    }

    func callCount() -> Int {
        calls
    }
}

private actor URLCountingMusicMetadataRawItemLoaderProbe {
    private var callsByURL: [URL: Int] = [:]

    func loadRawItems(for url: URL) -> [RawMusicMetadataItem] {
        let standardizedURL = url.standardizedFileURL
        callsByURL[standardizedURL, default: 0] += 1
        return [
            RawMusicMetadataItem(
                identifier: "id3/TIT2",
                stringValue: standardizedURL.deletingPathExtension().lastPathComponent,
                dataValue: nil
            )
        ]
    }

    func callCount(for url: URL) -> Int {
        callsByURL[url.standardizedFileURL, default: 0]
    }
}

private actor SupportedMusicMetadataStringLoaderProbe {
    private var calls = 0

    func loadString(for item: AVMetadataItem) async -> String? {
        calls += 1
        switch item.identifier?.rawValue {
        case "id3/TIT2":
            return "Count-Bounded Title"
        case "id3/TPE1":
            return "Count-Bounded Artist"
        case "id3/TALB":
            return "Count-Bounded Album"
        default:
            return nil
        }
    }

    func callCount() -> Int {
        calls
    }
}

private actor ReentrantMusicMetadataRawItemLoaderProbe {
    private var calls = 0
    private var continuations: [Int: CheckedContinuation<[RawMusicMetadataItem], Never>] = [:]
    private var callCountWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func loadRawItems(for _: URL) async -> [RawMusicMetadataItem] {
        calls += 1
        let call = calls
        resumeSatisfiedCallCountWaiters()

        guard call <= 2 else {
            return titleItems("Unexpected Reload")
        }

        return await withCheckedContinuation { continuation in
            continuations[call] = continuation
        }
    }

    func waitUntilCallCount(_ count: Int) async {
        guard calls < count else { return }

        await withCheckedContinuation { continuation in
            callCountWaiters.append((count, continuation))
        }
    }

    func completeCall(_ call: Int, title: String) {
        continuations.removeValue(forKey: call)?.resume(returning: titleItems(title))
    }

    func callCount() -> Int {
        calls
    }

    private func resumeSatisfiedCallCountWaiters() {
        var remainingWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for waiter in callCountWaiters {
            if calls >= waiter.count {
                waiter.continuation.resume()
            } else {
                remainingWaiters.append(waiter)
            }
        }
        callCountWaiters = remainingWaiters
    }

    private func titleItems(_ title: String) -> [RawMusicMetadataItem] {
        [RawMusicMetadataItem(identifier: "id3/TIT2", stringValue: title, dataValue: nil)]
    }
}
