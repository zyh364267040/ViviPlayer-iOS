import AVFoundation
import CryptoKit
import Darwin
import Foundation

private func isStrictLowercaseSHA256Hex(_ value: String) -> Bool {
    let scalars = value.unicodeScalars
    return scalars.count == 64 && scalars.allSatisfy {
        (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
    }
}

internal struct MusicLoudnessNormalizationSettings: Equatable, Sendable {
    let targetIntegratedLevelDBFS: Double
    let truePeakCeilingDBTP: Double
    let maximumBoostDB: Double
    let algorithmVersion: Int

    init?(
        targetIntegratedLevelDBFS: Double,
        truePeakCeilingDBTP: Double,
        maximumBoostDB: Double,
        algorithmVersion: Int
    ) {
        guard targetIntegratedLevelDBFS.isFinite,
              truePeakCeilingDBTP.isFinite,
              maximumBoostDB.isFinite,
              (-24 ... -10).contains(targetIntegratedLevelDBFS),
              (-6 ... 0).contains(truePeakCeilingDBTP),
              (0 ... 18).contains(maximumBoostDB),
              algorithmVersion > 0 else {
            return nil
        }

        self.targetIntegratedLevelDBFS = targetIntegratedLevelDBFS
        self.truePeakCeilingDBTP = truePeakCeilingDBTP
        self.maximumBoostDB = maximumBoostDB
        self.algorithmVersion = algorithmVersion
    }
}

internal struct MusicLoudnessLiveConfiguration: Equatable, Sendable {
    let cacheRootURL: URL
    let cacheBoundaryURL: URL
    let settings: MusicLoudnessNormalizationSettings

    static func make(cachesDirectoryURL: URL) -> MusicLoudnessLiveConfiguration? {
        guard cachesDirectoryURL.isFileURL,
              !cachesDirectoryURL.path.isEmpty,
              cachesDirectoryURL.path.hasPrefix("/"),
              let settings = MusicLoudnessNormalizationSettings(
                  targetIntegratedLevelDBFS: -16,
                  truePeakCeilingDBTP: -1.5,
                  maximumBoostDB: 12,
                  algorithmVersion: 1
              ) else {
            return nil
        }

        let cacheBoundaryURL = cachesDirectoryURL.standardizedFileURL
        let cacheRootURL = cacheBoundaryURL
            .appendingPathComponent("DrivePlayer", isDirectory: true)
            .appendingPathComponent("LoudnessBalance", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)

        return MusicLoudnessLiveConfiguration(
            cacheRootURL: cacheRootURL,
            cacheBoundaryURL: cacheBoundaryURL,
            settings: settings
        )
    }
}

internal struct MusicLoudnessCacheManifest: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case processing
        case complete
        case failed
    }

    let cacheKey: String
    let sourceSHA256Hex: String
    let derivativeFileName: String
    let derivativeSHA256Hex: String?
    let state: State
    let measuredIntegratedLevelDBFS: Double?
    let measuredTruePeakDBTP: Double?
    let outputIntegratedLevelDBFS: Double?
    let outputTruePeakDBTP: Double?

    init(
        cacheKey: String,
        sourceSHA256Hex: String,
        derivativeFileName: String,
        derivativeSHA256Hex: String? = nil,
        state: State,
        measuredIntegratedLevelDBFS: Double?,
        measuredTruePeakDBTP: Double?,
        outputIntegratedLevelDBFS: Double?,
        outputTruePeakDBTP: Double?
    ) {
        self.cacheKey = cacheKey
        self.sourceSHA256Hex = sourceSHA256Hex
        self.derivativeFileName = derivativeFileName
        self.derivativeSHA256Hex = derivativeSHA256Hex
        self.state = state
        self.measuredIntegratedLevelDBFS = measuredIntegratedLevelDBFS
        self.measuredTruePeakDBTP = measuredTruePeakDBTP
        self.outputIntegratedLevelDBFS = outputIntegratedLevelDBFS
        self.outputTruePeakDBTP = outputTruePeakDBTP
    }

    func isUsable(expectedCacheKey: String, derivativeExists: Bool) -> Bool {
        guard state == .complete,
              derivativeExists,
              cacheKey == expectedCacheKey,
              isStrictLowercaseSHA256Hex(cacheKey),
              isStrictLowercaseSHA256Hex(sourceSHA256Hex),
              !derivativeFileName.isEmpty,
              derivativeFileName != ".",
              derivativeFileName != "..",
              !derivativeFileName.contains("/"),
              !derivativeFileName.contains("\\"),
              !derivativeFileName.contains("\0"),
              let measuredIntegratedLevelDBFS,
              measuredIntegratedLevelDBFS.isFinite,
              let measuredTruePeakDBTP,
              measuredTruePeakDBTP.isFinite,
              let outputIntegratedLevelDBFS,
              outputIntegratedLevelDBFS.isFinite,
              let outputTruePeakDBTP,
              outputTruePeakDBTP.isFinite else {
            return false
        }

        return true
    }
}

internal enum MusicLoudnessCacheKey {
    static func make(
        sourceSHA256Hex: String,
        settings: MusicLoudnessNormalizationSettings
    ) -> String? {
        guard isStrictLowercaseSHA256Hex(sourceSHA256Hex) else {
            return nil
        }

        var payload = Data(sourceSHA256Hex.utf8)
        append(settings.targetIntegratedLevelDBFS.bitPattern, to: &payload)
        append(settings.truePeakCeilingDBTP.bitPattern, to: &payload)
        append(settings.maximumBoostDB.bitPattern, to: &payload)
        append(UInt64(bitPattern: Int64(settings.algorithmVersion)), to: &payload)

        let hexDigits = Array("0123456789abcdef".utf8)
        return SHA256.hash(data: payload).reduce(into: "") { result, byte in
            result.unicodeScalars.append(UnicodeScalar(hexDigits[Int(byte >> 4)]))
            result.unicodeScalars.append(UnicodeScalar(hexDigits[Int(byte & 0x0f)]))
        }
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}

internal struct MusicLoudnessResolution: Equatable, Sendable {
    internal enum Status: Equatable, Sendable {
        case generated
        case reused
        case fallbackOriginal
    }

    let playbackURL: URL
    let status: Status
}

internal struct MusicLoudnessLibraryProgressPresentation: Equatable, Sendable {
    let showsStatus: Bool
    let showsProgressIndicator: Bool
    let message: String?

    init(isNormalizing: Bool, completedCount: Int, totalCount: Int) {
        let total = max(0, totalCount)
        guard total > 0, isNormalizing || completedCount < total else {
            showsStatus = false
            showsProgressIndicator = false
            message = nil
            return
        }

        let completed = min(max(0, completedCount), total)
        showsStatus = true
        showsProgressIndicator = isNormalizing
        message = isNormalizing
            ? "正在统一音量 \(completed)/\(total)"
            : "音量统一完成 \(completed)/\(total)"
    }
}

internal actor MusicLoudnessCacheCoordinator {
    internal typealias Processor = (
        URL,
        URL,
        MusicLoudnessNormalizationSettings
    ) throws -> MusicLoudnessProcessingResult

    private static let derivativeFileName = "normalized.m4a"
    private static let manifestFileName = "manifest.json"
    private static let hashChunkSize = 1_048_576

    private let cacheRootURL: URL
    private let cacheBoundaryURL: URL?
    private let settings: MusicLoudnessNormalizationSettings
    private let processor: Processor

    init(
        cacheRootURL: URL,
        cacheBoundaryURL: URL? = nil,
        settings: MusicLoudnessNormalizationSettings,
        processor: @escaping Processor = { sourceURL, destinationURL, settings in
            try MusicLoudnessOfflineProcessor.process(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                settings: settings
            )
        }
    ) {
        self.cacheRootURL = cacheRootURL.standardizedFileURL
        self.cacheBoundaryURL = cacheBoundaryURL?.standardizedFileURL
        self.settings = settings
        self.processor = processor
    }

    func resolve(sourceURL: URL) -> MusicLoudnessResolution {
        let source = sourceURL.standardizedFileURL
        let root = cacheRootURL.standardizedFileURL
        var generationURL: URL?
        var stagingURL: URL?
        var snapshotURL: URL?

        defer {
            if let snapshotURL,
               snapshotURL != source,
               snapshotURL.deletingLastPathComponent() == root,
               snapshotURL.lastPathComponent.hasPrefix(".source-") {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
        }

        func fallback() -> MusicLoudnessResolution {
            if let stagingURL {
                try? FileManager.default.removeItem(at: stagingURL)
            }
            if let generationURL,
               generationURL != source,
               !source.path.hasPrefix(generationURL.path + "/") {
                try? FileManager.default.removeItem(at: generationURL)
            }
            return MusicLoudnessResolution(playbackURL: source, status: .fallbackOriginal)
        }

        do {
            try Task.checkCancellation()
            try Self.validateOrCreateCacheRoot(
                at: root,
                trustedBoundaryURL: cacheBoundaryURL
            )
            try Task.checkCancellation()

            let safeExtension = Self.safeSourcePathExtension(source.pathExtension)
            let snapshotName = ".source-\(UUID().uuidString)"
                + (safeExtension.map { ".\($0)" } ?? "")
            let snapshot = root
                .appendingPathComponent(snapshotName, isDirectory: false)
                .standardizedFileURL
            guard snapshot.deletingLastPathComponent() == root,
                  snapshot != source else {
                return fallback()
            }
            snapshotURL = snapshot
            try FileManager.default.copyItem(at: source, to: snapshot)
            try Task.checkCancellation()
            guard Self.isValidSnapshot(at: snapshot, expectedRoot: root) else {
                return fallback()
            }

            let sourceSHA256Hex = try Self.hashRegularFile(at: snapshot)
            try Task.checkCancellation()
            guard let cacheKey = MusicLoudnessCacheKey.make(
                sourceSHA256Hex: sourceSHA256Hex,
                settings: settings
            ),
            isStrictLowercaseSHA256Hex(cacheKey) else {
                return fallback()
            }

            let generation = root.appendingPathComponent(cacheKey, isDirectory: true).standardizedFileURL
            generationURL = generation
            guard generation.deletingLastPathComponent() == root,
                  generation.lastPathComponent == cacheKey,
                  generation != source,
                  !source.path.hasPrefix(generation.path + "/") else {
                return fallback()
            }

            let derivative = generation
                .appendingPathComponent(Self.derivativeFileName, isDirectory: false)
                .standardizedFileURL
            let manifestURL = generation
                .appendingPathComponent(Self.manifestFileName, isDirectory: false)
                .standardizedFileURL
            guard derivative.deletingLastPathComponent() == generation,
                  manifestURL.deletingLastPathComponent() == generation else {
                return fallback()
            }

            if Self.isValidManifest(
                at: manifestURL,
                expectedGenerationParent: generation
            ),
               let manifestData = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder().decode(
                   MusicLoudnessCacheManifest.self,
                   from: manifestData
               ),
               manifest.sourceSHA256Hex == sourceSHA256Hex,
               MusicLoudnessCacheKey.make(
                   sourceSHA256Hex: manifest.sourceSHA256Hex,
                   settings: settings
               ) == cacheKey,
               manifest.derivativeFileName == Self.derivativeFileName,
               let derivativeSHA256Hex = manifest.derivativeSHA256Hex,
               isStrictLowercaseSHA256Hex(derivativeSHA256Hex),
               manifest.isUsable(
                   expectedCacheKey: cacheKey,
                   derivativeExists: Self.isValidDerivative(
                       at: derivative,
                       expectedGenerationParent: generation,
                       expectedSHA256Hex: derivativeSHA256Hex
                   )
               ) {
                try Task.checkCancellation()
                return MusicLoudnessResolution(playbackURL: derivative, status: .reused)
            }

            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: generation)
            try FileManager.default.createDirectory(
                at: generation,
                withIntermediateDirectories: false
            )

            let staging = generation
                .appendingPathComponent(".staging-\(UUID().uuidString).m4a", isDirectory: false)
                .standardizedFileURL
            stagingURL = staging
            guard staging.deletingLastPathComponent() == generation else {
                return fallback()
            }

            try Task.checkCancellation()
            let result = try processor(snapshot, staging, settings)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: staging, to: derivative)
            stagingURL = nil

            try Task.checkCancellation()
            guard Self.isSafeDecodableDerivative(
                at: derivative,
                expectedGenerationParent: generation
            ) else {
                return fallback()
            }
            let derivativeSHA256Hex = try Self.hashRegularFile(at: derivative)
            try Task.checkCancellation()
            guard isStrictLowercaseSHA256Hex(derivativeSHA256Hex) else {
                return fallback()
            }

            let manifest = MusicLoudnessCacheManifest(
                cacheKey: cacheKey,
                sourceSHA256Hex: sourceSHA256Hex,
                derivativeFileName: Self.derivativeFileName,
                derivativeSHA256Hex: derivativeSHA256Hex,
                state: .complete,
                measuredIntegratedLevelDBFS: result.measuredIntegratedLevelDBFS,
                measuredTruePeakDBTP: result.measuredTruePeakDBTP,
                outputIntegratedLevelDBFS: result.outputIntegratedLevelDBFS,
                outputTruePeakDBTP: result.outputTruePeakDBTP
            )
            let manifestData = try JSONEncoder().encode(manifest)
            try Task.checkCancellation()
            try manifestData.write(to: manifestURL, options: .atomic)

            try Task.checkCancellation()
            guard Self.isValidManifest(
                at: manifestURL,
                expectedGenerationParent: generation
            ) else {
                return fallback()
            }
            let verifiedData = try Data(contentsOf: manifestURL)
            try Task.checkCancellation()
            let verifiedManifest = try JSONDecoder().decode(
                MusicLoudnessCacheManifest.self,
                from: verifiedData
            )
            guard verifiedManifest.sourceSHA256Hex == sourceSHA256Hex,
                  MusicLoudnessCacheKey.make(
                      sourceSHA256Hex: verifiedManifest.sourceSHA256Hex,
                      settings: settings
                  ) == cacheKey,
                  verifiedManifest.derivativeFileName == Self.derivativeFileName,
                  let verifiedDerivativeSHA256Hex = verifiedManifest.derivativeSHA256Hex,
                  isStrictLowercaseSHA256Hex(verifiedDerivativeSHA256Hex),
                  verifiedManifest.isUsable(
                      expectedCacheKey: cacheKey,
                      derivativeExists: Self.isValidDerivative(
                          at: derivative,
                          expectedGenerationParent: generation,
                          expectedSHA256Hex: verifiedDerivativeSHA256Hex
                      )
                  ) else {
                return fallback()
            }

            return MusicLoudnessResolution(playbackURL: derivative, status: .generated)
        } catch {
            return fallback()
        }
    }

    private static func validateOrCreateCacheRoot(
        at rootURL: URL,
        trustedBoundaryURL: URL? = nil
    ) throws {
        let root = rootURL.standardizedFileURL
        guard root.isFileURL,
              !root.path.isEmpty,
              root.path.hasPrefix("/") else {
            throw CocoaError(.fileNoSuchFile)
        }

        func lstatStatus(at url: URL) throws -> stat? {
            var fileStatus = stat()
            var errorNumber: Int32 = 0
            let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else {
                    errorNumber = EINVAL
                    return -1
                }
                let result = lstat(path, &fileStatus)
                if result != 0 {
                    errorNumber = errno
                }
                return result
            }
            if result == 0 {
                return fileStatus
            }
            if errorNumber == ENOENT {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: errorNumber) ?? .EIO)
        }

        func validateDirectory(at url: URL, requireReadableAndWritable: Bool) throws {
            guard let fileStatus = try lstatStatus(at: url),
                  (fileStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw CocoaError(.fileReadNoPermission)
            }
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isReadableKey, .isWritableKey]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink == false,
                  !requireReadableAndWritable
                    || (values.isReadable == true && values.isWritable == true) else {
                throw CocoaError(.fileReadNoPermission)
            }
        }

        let boundary: URL
        if let trustedBoundaryURL {
            guard trustedBoundaryURL.isFileURL,
                  !trustedBoundaryURL.path.isEmpty,
                  trustedBoundaryURL.path.hasPrefix("/") else {
                throw CocoaError(.fileNoSuchFile)
            }
            boundary = trustedBoundaryURL.standardizedFileURL
            guard try lstatStatus(at: boundary) != nil else {
                throw CocoaError(.fileNoSuchFile)
            }
        } else {
            var nearestExistingBoundary = root
            while try lstatStatus(at: nearestExistingBoundary) == nil {
                guard nearestExistingBoundary.path != "/" else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let parent = nearestExistingBoundary.deletingLastPathComponent().standardizedFileURL
                guard parent != nearestExistingBoundary else {
                    throw CocoaError(.fileNoSuchFile)
                }
                nearestExistingBoundary = parent
            }
            boundary = nearestExistingBoundary
        }
        try validateDirectory(at: boundary, requireReadableAndWritable: true)

        let rootComponents = root.pathComponents
        let boundaryComponents = boundary.pathComponents
        guard rootComponents.count >= boundaryComponents.count,
              Array(rootComponents.prefix(boundaryComponents.count)) == boundaryComponents else {
            throw CocoaError(.fileNoSuchFile)
        }

        var current = boundary
        for component in rootComponents.dropFirst(boundaryComponents.count) {
            guard !component.isEmpty,
                  component != ".",
                  component != ".." else {
                throw CocoaError(.fileNoSuchFile)
            }
            current = current.appendingPathComponent(component, isDirectory: true)
                .standardizedFileURL
            if try lstatStatus(at: current) == nil {
                try FileManager.default.createDirectory(
                    at: current,
                    withIntermediateDirectories: false
                )
            }
            try validateDirectory(
                at: current,
                requireReadableAndWritable: current == root
            )
        }

        if boundary == root {
            try validateDirectory(at: root, requireReadableAndWritable: true)
        }
    }

    private static func safeSourcePathExtension(_ pathExtension: String) -> String? {
        let value = pathExtension
        guard (1 ... 10).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ scalar in
                  (48 ... 57).contains(scalar.value) || (97 ... 122).contains(scalar.value)
              }) else {
            return nil
        }
        return value
    }

    private static func isValidSnapshot(at snapshotURL: URL, expectedRoot rootURL: URL) -> Bool {
        let snapshot = snapshotURL.standardizedFileURL
        let root = rootURL.standardizedFileURL
        guard snapshot.isFileURL,
              root.isFileURL,
              snapshot.deletingLastPathComponent() == root else {
            return false
        }

        var fileStatus = stat()
        let isRegularFile = snapshot.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return false
            }
            return lstat(path, &fileStatus) == 0
                && (fileStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
                && fileStatus.st_nlink == 1
        }
        guard isRegularFile,
              FileManager.default.isReadableFile(atPath: snapshot.path) else {
            return false
        }

        do {
            let values = try snapshot.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isReadableKey]
            )
            return values.isRegularFile == true
                && values.isSymbolicLink == false
                && values.isReadable == true
        } catch {
            return false
        }
    }

    private static func isValidDerivative(
        at derivativeURL: URL,
        expectedGenerationParent: URL,
        expectedSHA256Hex: String
    ) -> Bool {
        guard isStrictLowercaseSHA256Hex(expectedSHA256Hex),
              isSafeDecodableDerivative(
                  at: derivativeURL,
                  expectedGenerationParent: expectedGenerationParent
              ),
              let actualSHA256Hex = try? hashRegularFile(at: derivativeURL) else {
            return false
        }
        return actualSHA256Hex == expectedSHA256Hex
    }

    private static func isValidManifest(
        at manifestURL: URL,
        expectedGenerationParent: URL
    ) -> Bool {
        let manifest = manifestURL.standardizedFileURL
        let expectedParent = expectedGenerationParent.standardizedFileURL
        guard manifestURL.isFileURL,
              expectedGenerationParent.isFileURL,
              manifestURL == manifest,
              expectedGenerationParent == expectedParent,
              manifest.deletingLastPathComponent() == expectedParent else {
            return false
        }

        var fileStatus = stat()
        let isRegularFile = manifest.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return false
            }
            return lstat(path, &fileStatus) == 0
                && (fileStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
                && fileStatus.st_nlink == 1
        }
        guard isRegularFile,
              FileManager.default.isReadableFile(atPath: manifest.path) else {
            return false
        }

        do {
            let values = try manifest.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isReadableKey]
            )
            return values.isRegularFile == true
                && values.isSymbolicLink == false
                && values.isReadable == true
        } catch {
            return false
        }
    }

    private static func isSafeDecodableDerivative(
        at derivativeURL: URL,
        expectedGenerationParent: URL
    ) -> Bool {
        let derivative = derivativeURL.standardizedFileURL
        let expectedParent = expectedGenerationParent.standardizedFileURL
        guard derivative.isFileURL,
              expectedParent.isFileURL,
              derivative.deletingLastPathComponent() == expectedParent else {
            return false
        }

        var fileStatus = stat()
        let isRegularFile = derivative.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                return false
            }
            return lstat(path, &fileStatus) == 0
                && (fileStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
                && fileStatus.st_nlink == 1
        }
        guard isRegularFile,
              FileManager.default.isReadableFile(atPath: derivative.path) else {
            return false
        }

        do {
            let values = try derivative.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isReadableKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink == false,
                  values.isReadable == true else {
                return false
            }

            let audioFile = try AVAudioFile(
                forReading: derivative,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            let format = audioFile.processingFormat
            return format.sampleRate.isFinite
                && (8_000 ... 192_000).contains(format.sampleRate)
                && (1 ... 2).contains(format.channelCount)
                && audioFile.length > 0
                && audioFile.length <= (AVAudioFramePosition(1) << 50)
        } catch {
            return false
        }
    }

    private static func hashRegularFile(at sourceURL: URL) throws -> String {
        try Task.checkCancellation()
        let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard values.isRegularFile == true,
              values.isReadable == true,
              FileManager.default.isReadableFile(atPath: sourceURL.path) else {
            throw CocoaError(.fileReadNoPermission)
        }

        let handle = try FileHandle(forReadingFrom: sourceURL)
        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: hashChunkSize), !data.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: data)
            }
            try Task.checkCancellation()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        let hexDigits = Array("0123456789abcdef".utf8)
        let hash = hasher.finalize().reduce(into: "") { result, byte in
            result.unicodeScalars.append(UnicodeScalar(hexDigits[Int(byte >> 4)]))
            result.unicodeScalars.append(UnicodeScalar(hexDigits[Int(byte & 0x0f)]))
        }
        guard isStrictLowercaseSHA256Hex(hash) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return hash
    }
}

internal struct MusicLoudnessProcessingResult: Equatable, Sendable {
    let measuredIntegratedLevelDBFS: Double
    let measuredTruePeakDBTP: Double
    let outputIntegratedLevelDBFS: Double
    let outputTruePeakDBTP: Double
    let appliedGainDB: Double
}

internal enum MusicLoudnessGainPolicy {
    static func appliedGainDB(
        measuredIntegratedLevelDBFS: Double,
        measuredPeakDBTP: Double,
        settings: MusicLoudnessNormalizationSettings
    ) -> Double? {
        guard measuredIntegratedLevelDBFS.isFinite,
              measuredPeakDBTP.isFinite,
              (-200 ... 20).contains(measuredIntegratedLevelDBFS),
              (-200 ... 0).contains(measuredPeakDBTP) else {
            return nil
        }

        let requestedGain = settings.targetIntegratedLevelDBFS - measuredIntegratedLevelDBFS
        let peakHeadroom = settings.truePeakCeilingDBTP - measuredPeakDBTP
        let appliedGain = min(requestedGain, settings.maximumBoostDB, peakHeadroom)
        return appliedGain.isFinite ? appliedGain : nil
    }
}

internal enum MusicLoudnessOfflineProcessor {
    internal enum ProcessingError: Error, LocalizedError {
        case sourceAndDestinationAreTheSame
        case destinationAlreadyExists
        case destinationMustBeM4A
        case unsupportedAudioFormat(sampleRate: Double, channelCount: AVAudioChannelCount)
        case emptyAudio
        case invalidAudioSample
        case silentAudio
        case unreasonableFrameCount(AVAudioFramePosition)
        case unreasonableBufferLayout
        case invalidGain
        case incompleteRead(expected: AVAudioFramePosition, actual: AVAudioFramePosition)

        var errorDescription: String? {
            switch self {
            case .sourceAndDestinationAreTheSame:
                return "The source and destination URLs refer to the same standardized path."
            case .destinationAlreadyExists:
                return "The destination file already exists."
            case .destinationMustBeM4A:
                return "The destination must have an .m4a extension."
            case let .unsupportedAudioFormat(sampleRate, channelCount):
                return "Unsupported audio format: \(sampleRate) Hz, \(channelCount) channels."
            case .emptyAudio:
                return "The audio file contains no frames."
            case .invalidAudioSample:
                return "The audio file contains a non-finite sample or unrepresentable energy."
            case .silentAudio:
                return "The audio file is silent."
            case let .unreasonableFrameCount(frameCount):
                return "The audio frame count is unreasonable: \(frameCount)."
            case .unreasonableBufferLayout:
                return "The audio buffer has an invalid or unsupported layout."
            case .invalidGain:
                return "The requested gain or peak ceiling is not finite and representable."
            case let .incompleteRead(expected, actual):
                return "Audio read ended early: expected \(expected) frames, read \(actual)."
            }
        }
    }

    private struct Measurement {
        let integratedLevelDBFS: Double
        let peakDBFS: Double
    }

    private static let framesPerBuffer: AVAudioFrameCount = 8_192
    private static let maximumReasonableFrameCount = AVAudioFramePosition(1) << 50

    static func process(
        sourceURL: URL,
        destinationURL: URL,
        settings: MusicLoudnessNormalizationSettings
    ) throws -> MusicLoudnessProcessingResult {
        try Task.checkCancellation()
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard source != destination else {
            throw ProcessingError.sourceAndDestinationAreTheSame
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw ProcessingError.destinationAlreadyExists
        }
        guard destination.pathExtension.lowercased() == "m4a" else {
            throw ProcessingError.destinationMustBeM4A
        }

        let input = try AVAudioFile(
            forReading: source,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try Task.checkCancellation()
        try validate(input)
        try Task.checkCancellation()
        let measured = try measure(input)
        try Task.checkCancellation()

        guard let appliedGainDB = MusicLoudnessGainPolicy.appliedGainDB(
            measuredIntegratedLevelDBFS: measured.integratedLevelDBFS,
            measuredPeakDBTP: measured.peakDBFS,
            settings: settings
        ) else {
            throw ProcessingError.invalidGain
        }
        let linearGain = pow(10, appliedGainDB / 20)
        let ceilingAmplitude = pow(10, settings.truePeakCeilingDBTP / 20)
        guard linearGain.isFinite,
              linearGain >= 0,
              ceilingAmplitude.isFinite,
              ceilingAmplitude > 0 else {
            throw ProcessingError.invalidGain
        }

        var shouldRemoveDestination = true
        defer {
            if shouldRemoveDestination {
                try? FileManager.default.removeItem(at: destination)
            }
        }

        input.framePosition = 0
        let channelCount = input.processingFormat.channelCount
        let bitRate = min(320_000, channelCount == 1 ? 128_000 : 256_000)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: input.processingFormat.sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitRate
        ]
        var output: AVAudioFile? = try AVAudioFile(
            forWriting: destination,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = try makeBuffer(format: input.processingFormat)
        var framesWritten: AVAudioFramePosition = 0
        while framesWritten < input.length {
            try Task.checkCancellation()
            let remaining = input.length - framesWritten
            let boundedRemaining = min(remaining, AVAudioFramePosition(framesPerBuffer))
            guard let requestedFrameCount = AVAudioFrameCount(exactly: boundedRemaining) else {
                throw ProcessingError.unreasonableFrameCount(remaining)
            }
            try input.read(into: buffer, frameCount: min(framesPerBuffer, requestedFrameCount))
            let frameCount = buffer.frameLength
            guard frameCount > 0 else {
                throw ProcessingError.incompleteRead(expected: input.length, actual: framesWritten)
            }
            guard let channels = buffer.floatChannelData else {
                throw ProcessingError.unreasonableBufferLayout
            }
            for channel in 0 ..< Int(channelCount) {
                let samples = channels[channel]
                for frame in 0 ..< Int(frameCount) {
                    if frame.isMultiple(of: 1_024) {
                        try Task.checkCancellation()
                    }
                    let sample = Double(samples[frame])
                    guard sample.isFinite else { throw ProcessingError.invalidAudioSample }
                    samples[frame] = Float(max(-ceilingAmplitude, min(ceilingAmplitude, sample * linearGain)))
                }
            }
            guard let output else { throw ProcessingError.unreasonableBufferLayout }
            try output.write(from: buffer)
            framesWritten += AVAudioFramePosition(frameCount)
        }
        guard framesWritten == input.length else {
            throw ProcessingError.incompleteRead(expected: input.length, actual: framesWritten)
        }
        output = nil

        try Task.checkCancellation()
        let encoded = try AVAudioFile(
            forReading: destination,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try Task.checkCancellation()
        try validate(encoded)
        try Task.checkCancellation()
        let outputMeasurement = try measure(encoded)
        try Task.checkCancellation()
        shouldRemoveDestination = false

        return MusicLoudnessProcessingResult(
            measuredIntegratedLevelDBFS: measured.integratedLevelDBFS,
            measuredTruePeakDBTP: measured.peakDBFS,
            outputIntegratedLevelDBFS: outputMeasurement.integratedLevelDBFS,
            outputTruePeakDBTP: outputMeasurement.peakDBFS,
            appliedGainDB: appliedGainDB
        )
    }

    private static func validate(_ file: AVAudioFile) throws {
        let format = file.processingFormat
        let channelCount = format.channelCount
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              format.sampleRate.isFinite,
              (8_000 ... 192_000).contains(format.sampleRate),
              (1 ... 2).contains(channelCount) else {
            throw ProcessingError.unsupportedAudioFormat(
                sampleRate: format.sampleRate,
                channelCount: channelCount
            )
        }
        guard file.length > 0 else { throw ProcessingError.emptyAudio }
        guard file.length <= maximumReasonableFrameCount else {
            throw ProcessingError.unreasonableFrameCount(file.length)
        }
    }

    private static func makeBuffer(format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard framesPerBuffer > 0,
              framesPerBuffer <= 65_536,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBuffer),
              buffer.frameCapacity == framesPerBuffer else {
            throw ProcessingError.unreasonableBufferLayout
        }
        return buffer
    }

    private static func measure(_ file: AVAudioFile) throws -> Measurement {
        try Task.checkCancellation()
        file.framePosition = 0
        let buffer = try makeBuffer(format: file.processingFormat)
        let channelCount = Int(file.processingFormat.channelCount)
        var sumOfSquares = 0.0
        var peak = 0.0
        var sampleCount = 0.0
        var framesRead: AVAudioFramePosition = 0

        while framesRead < file.length {
            try Task.checkCancellation()
            let remaining = file.length - framesRead
            let boundedRemaining = min(remaining, AVAudioFramePosition(framesPerBuffer))
            guard let requestedFrameCount = AVAudioFrameCount(exactly: boundedRemaining) else {
                throw ProcessingError.unreasonableFrameCount(remaining)
            }
            try file.read(into: buffer, frameCount: min(framesPerBuffer, requestedFrameCount))
            let frameCount = buffer.frameLength
            guard frameCount > 0 else {
                throw ProcessingError.incompleteRead(expected: file.length, actual: framesRead)
            }
            guard let channels = buffer.floatChannelData else {
                throw ProcessingError.unreasonableBufferLayout
            }
            for channel in 0 ..< channelCount {
                let samples = channels[channel]
                for frame in 0 ..< Int(frameCount) {
                    if frame.isMultiple(of: 1_024) {
                        try Task.checkCancellation()
                    }
                    let sample = Double(samples[frame])
                    guard sample.isFinite else { throw ProcessingError.invalidAudioSample }
                    sumOfSquares += sample * sample
                    peak = max(peak, abs(sample))
                }
            }
            sampleCount += Double(frameCount) * Double(channelCount)
            framesRead += AVAudioFramePosition(frameCount)
            guard sumOfSquares.isFinite, sampleCount.isFinite else {
                throw ProcessingError.invalidAudioSample
            }
        }

        guard framesRead == file.length else {
            throw ProcessingError.incompleteRead(expected: file.length, actual: framesRead)
        }
        guard sampleCount > 0 else { throw ProcessingError.emptyAudio }
        guard sumOfSquares > 0, peak > 0 else { throw ProcessingError.silentAudio }
        let integratedLevel = 10 * log10(sumOfSquares / sampleCount)
        let peakLevel = 20 * log10(peak)
        guard integratedLevel.isFinite, peakLevel.isFinite else {
            throw ProcessingError.invalidAudioSample
        }
        return Measurement(integratedLevelDBFS: integratedLevel, peakDBFS: peakLevel)
    }
}
