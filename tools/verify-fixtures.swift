// SPDX-License-Identifier: GPL-3.0-only
// Compile alongside DrivePlayer/Models/MusicMetadata.swift; see tools/README.md.
import Foundation
import AVFoundation
import ImageIO

@main struct VerifyFixtures {
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = root.appendingPathComponent("DrivePlayerTests/Resources/metadata-fixture.m4a")
        let raw = try await AVFoundationMusicMetadataRawLoader.load(from: url)
        let parsed = MusicMetadataParser.parse(raw, fallbackFileName: url.lastPathComponent)
        precondition(parsed.title == "Fixture Title")
        precondition(parsed.artist == "Fixture Artist")
        precondition(parsed.album == "Fixture Album")
        precondition(parsed.lyrics == "Line one\nLine two")
        precondition(parsed.artworkData?.count == 68)
        precondition(parsed.synchronizedLyricsData == nil)
        let png = CGImageSourceCreateWithData(parsed.artworkData! as CFData, nil)!
        precondition(CGImageSourceCreateImageAtIndex(png, 0, nil) != nil)
        print("PASS production AVFoundation loader/parser: six assertions; PNG decodes")
        let audio = AVURLAsset(url: url)
        let audioDuration = try await audio.load(.duration).seconds
        precondition(audioDuration == 1)
        let video = AVURLAsset(url: root.appendingPathComponent("DrivePlayer/Resources/phase0-test.mp4"))
        let duration = try await video.load(.duration).seconds
        precondition(duration == 3)
        let tracks = try await video.loadTracks(withMediaType: .video)
        precondition(tracks.count == 1)
        print("PASS AVFoundation container inspection: audio 1s; video 3s, one video track")
        if CommandLine.arguments.contains("--decode") {
            let image = try await AVAssetImageGenerator(asset: video)
                .image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
            precondition(image.width == 160 && image.height == 96)
            let reader = try AVAssetReader(asset: audio)
            let track = try await audio.loadTracks(withMediaType: .audio).first!
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(output)
            guard reader.startReading() else { throw reader.error! }
            var samples = 0
            while let sample = output.copyNextSampleBuffer() { samples += CMSampleBufferGetNumSamples(sample) }
            if let error = reader.error { throw error }
            precondition(reader.status == .completed && samples == 44100)
            print("PASS decoded video at 1s and 44100 audio samples")
        }
    }
}
