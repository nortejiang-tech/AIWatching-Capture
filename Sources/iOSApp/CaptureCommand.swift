import Foundation

enum CaptureCommand: String {
    case start
    case stop
    case bookmark

    private static let pendingKey = "AIWatching.pendingCommand"

    static func storePending(_ command: CaptureCommand) {
        UserDefaults.standard.set(command.rawValue, forKey: pendingKey)
    }

    static func takePending() -> CaptureCommand? {
        guard let raw = UserDefaults.standard.string(forKey: pendingKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: pendingKey)
        return CaptureCommand(rawValue: raw)
    }
}
