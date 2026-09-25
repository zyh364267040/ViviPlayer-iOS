import AVFoundation
import OSLog

@MainActor
enum AudioSessionManager {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "DrivePlayer",
        category: "AudioSession"
    )

    static func configureCategoryForPlayback() {
        let session = AVAudioSession.sharedInstance()

        do {
            // The playback category is the system prerequisite for audio to continue
            // after locking the screen or switching to another app. Merely setting the
            // category does not claim the audio session during a silent cold launch.
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
        } catch {
            let errorCode = (error as NSError).code
            logger.error("Audio session configuration failed with code \(errorCode, privacy: .public)")
        }
    }

    static func activateForPlayback() throws {
        // Activation belongs at the moment the user actually asks for playback.
        // KSPlayer independently activates its session while preparing video playback.
        try AVAudioSession.sharedInstance().setActive(true)
    }
}
