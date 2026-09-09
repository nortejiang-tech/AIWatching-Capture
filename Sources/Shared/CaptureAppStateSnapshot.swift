import Foundation

public struct CaptureAppCaptureStateSnapshot: Sendable {
    public let publisherId: UUID
    public let sequence: Int
    public let timestamp: TimeInterval
    public let sessionId: String?
    public let isCapturing: Bool
    public let statusText: String?

    public init(
        publisherId: UUID,
        sequence: Int,
        timestamp: TimeInterval,
        sessionId: String?,
        isCapturing: Bool,
        statusText: String?
    ) {
        self.publisherId = publisherId
        self.sequence = sequence
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.isCapturing = isCapturing
        self.statusText = statusText
    }

    public init?(applicationContext: [String: Any]) {
        guard let publisherIdString = applicationContext["capturePublisherId"] as? String,
              let publisherId = UUID(uuidString: publisherIdString),
              let sequence = applicationContext["captureStateSequence"] as? Int,
              let timestamp = applicationContext["captureTimestamp"] as? TimeInterval,
              let isCapturing = applicationContext["captureIsCapturing"] as? Bool else {
            return nil
        }

        self.publisherId = publisherId
        self.sequence = sequence
        self.timestamp = timestamp
        self.sessionId = applicationContext["captureSessionId"] as? String
        self.isCapturing = isCapturing
        self.statusText = applicationContext["captureStatusText"] as? String
    }
}

public struct CaptureAppCaptureStateReducer: Sendable {
    public private(set) var publisherId: UUID?
    public private(set) var sequence: Int = 0
    public private(set) var timestamp: TimeInterval = 0
    public private(set) var isCapturing: Bool = false
    public private(set) var statusText: String = "等待 iPhone"
    public private(set) var sessionId: String?
    public private(set) var retiredPublisherIds: Set<UUID> = []

    public init() {}

    @discardableResult
    public mutating func apply(_ snapshot: CaptureAppCaptureStateSnapshot) -> Bool {
        let shouldApply: Bool
        if let publisherId {
            if retiredPublisherIds.contains(snapshot.publisherId) {
                return false
            }
            if publisherId == snapshot.publisherId {
                shouldApply = snapshot.sequence > sequence
            } else {
                shouldApply = snapshot.timestamp > timestamp
                if shouldApply {
                    retiredPublisherIds.insert(publisherId)
                }
            }
        } else {
            shouldApply = true
        }

        guard shouldApply else {
            return false
        }

        self.publisherId = snapshot.publisherId
        sequence = snapshot.sequence
        timestamp = snapshot.timestamp
        isCapturing = snapshot.isCapturing
        statusText = snapshot.statusText ?? (isCapturing ? "正在捕捉" : "等待 iPhone")
        sessionId = snapshot.sessionId
        return true
    }
}
