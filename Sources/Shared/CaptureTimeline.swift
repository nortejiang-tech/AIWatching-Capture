import Foundation

public enum CaptureTimeline {
    public static func sessionRelativeSeconds(from sessionStartedAt: Date, to eventTime: Date) -> TimeInterval {
        eventTime.timeIntervalSince(sessionStartedAt)
    }
}
