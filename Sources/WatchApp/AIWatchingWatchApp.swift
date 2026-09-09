import SwiftUI

@main
struct AIWatchingWatchApp: App {
    @StateObject private var connector: WatchConnector
    @StateObject private var chunkedController: WatchChunkedCaptureController

    init() {
        let chunkedController = WatchChunkedCaptureController()
        _chunkedController = StateObject(wrappedValue: chunkedController)
        _connector = StateObject(wrappedValue: WatchConnector(completionObserver: chunkedController))
    }

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(chunkedController)
                .task {
                    // App relaunch implies previous sessions ended: promote
                    // their final markers and re-enqueue unsent chunks.
                    chunkedController.recoverAbandonedSessions()
                }
        }
    }
}
