import KSPlayer
import SwiftUI

@main
@MainActor
struct DrivePlayerApp: App {
    init() {
        KSOptions.canBackgroundPlay = true
        AudioSessionManager.configureCategoryForPlayback()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
    }
}
