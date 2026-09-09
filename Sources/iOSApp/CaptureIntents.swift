import AppIntents
import Foundation

struct StartCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Start AIWatching Capture"
    static let description = IntentDescription("Open AIWatching and start an iPhone-backed capture session.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        CaptureCommand.storePending(.start)
        return .result()
    }
}

struct StopCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop AIWatching Capture"
    static let description = IntentDescription("Open AIWatching and stop the active capture session.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        CaptureCommand.storePending(.stop)
        return .result()
    }
}

struct MarkCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark AIWatching Moment"
    static let description = IntentDescription("Open AIWatching and add a timestamp bookmark to the active capture session.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        CaptureCommand.storePending(.bookmark)
        return .result()
    }
}

struct AIWatchingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartCaptureIntent(),
            phrases: ["Start capture with \(.applicationName)", "Start \(.applicationName)"],
            shortTitle: "Start Capture",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopCaptureIntent(),
            phrases: ["Stop capture with \(.applicationName)", "Stop \(.applicationName)"],
            shortTitle: "Stop Capture",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: MarkCaptureIntent(),
            phrases: ["Mark this moment with \(.applicationName)", "Mark \(.applicationName)"],
            shortTitle: "Mark Moment",
            systemImageName: "bookmark"
        )
    }
}
