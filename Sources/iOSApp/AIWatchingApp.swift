import SwiftUI

@main
struct AIWatchingApp: App {
    @StateObject private var capture: CaptureController
    @StateObject private var sessionExport: SessionExportRuntime
    private let recordingsRootProvider: @Sendable () throws -> URL
    private let enqueueCompletedSession: @Sendable (URL) -> Void
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let recordingsRootProvider: @Sendable () throws -> URL = {
            try SessionExportRuntime.liveLocalRecordingsRoot(fileManager: .default)
        }
        let exportRuntime = SessionExportRuntime.live(
            recordingsRootProvider: recordingsRootProvider,
            fileManager: .default
        )
        let enqueueCompletedSession: @Sendable (URL) -> Void = { sessionDirectory in
            exportRuntime.scheduleCompletedSession(sessionDirectory)
        }
        let captureController = CaptureController()
        captureController.configureSessionExport(
            recordingsRootProvider: recordingsRootProvider,
            enqueueCompletedSession: enqueueCompletedSession
        )

        self._capture = StateObject(wrappedValue: captureController)
        self._sessionExport = StateObject(wrappedValue: exportRuntime)
        self.recordingsRootProvider = recordingsRootProvider
        self.enqueueCompletedSession = enqueueCompletedSession
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionExport)
                .environmentObject(capture)
                .task {
                    PhoneConnectivityController.shared.configureSessionExport(
                        recordingsRootProvider: recordingsRootProvider,
                        enqueueCompletedSession: enqueueCompletedSession
                    )
                    PhoneConnectivityController.shared.attach(capture)
                    await capture.loadRecentSessions()
                    await capture.performPendingCommandIfNeeded()
                    await sessionExport.refresh()
                    await sessionExport.resumeCompleteSessions()
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task {
                        await capture.performPendingCommandIfNeeded()
                        await sessionExport.refresh()
                    }
                }
        }
    }
}
