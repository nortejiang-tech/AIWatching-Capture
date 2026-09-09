import Foundation
import CoreFoundation

enum WatchCaptureDiagnosticEventKind: String, Codable, Equatable, Sendable {
    case recordingStarted
    case interruptionBegan
    case interruptionEnded
    case resumeDeferred
    case resumeAttemptStarted
    case resumeSucceeded
    case resumeFailed
    case stopRequested
    case sessionCompleted
    case abandonedSessionRecovered
}

struct WatchCaptureDiagnosticEvent: Codable, Equatable, Sendable {
    let sequence: Int
    let kind: WatchCaptureDiagnosticEventKind
    let occurredAt: String
    let sessionOffsetSec: TimeInterval
    let controllerState: String
    let shouldResume: Bool?
    let lastFinalizedChunkIndex: Int?
    let detail: String?

    func isValid() -> Bool {
        occurredAt.isValidISO8601Timestamp && sequence >= 0 && sessionOffsetSec.isFinite && sessionOffsetSec >= 0
    }
}

struct WatchCaptureDiagnostics: Codable, Equatable, Sendable {
    static let watchCaptureDiagnosticsFileName = "watch-capture-diagnostics.json"
    static let supportedSchemaVersion = 1
    static let maxEventCount = 256

    let schemaVersion: Int
    var events: [WatchCaptureDiagnosticEvent]
    var truncated: Bool

    func isValid() -> Bool {
        guard schemaVersion == Self.supportedSchemaVersion else {
            return false
        }
        guard events.count <= WatchCaptureDiagnostics.maxEventCount else {
            return false
        }
        for (index, event) in events.enumerated() {
            guard event.isValid() else {
                return false
            }
            if index == 0 {
                if event.sequence != 0 { return false }
            } else if events[index - 1].sequence + 1 != event.sequence {
                return false
            }
        }
        return true
    }
}

private extension String {
    var isValidISO8601Timestamp: Bool {
        ISO8601DateFormatter().date(from: self) != nil
    }
}

struct WatchRecordingProbeMetadata: Codable, Equatable, Sendable {
    static let transferFlagKey = "aiwatchingWatchProbe"
    static let singleChunkVersion = 1
    static let chunkedVersion = 2

    let metadataVersion: Int
    let sessionId: String
    let startedAt: String
    let endedAt: String
    let durationSec: TimeInterval
    let fileName: String
    let source: String
    /// v2 only: zero-based chunk position inside the session. v1 decodes as 0.
    let chunkIndex: Int
    /// v2 only: session-relative start offset of this chunk. v1 decodes as 0.
    let chunkStartOffsetSec: TimeInterval
    /// v2 only: total chunk count, carried by the final chunk alone and
    /// self-validating (`chunkCount == chunkIndex + 1`). v1 decodes as 1.
    let chunkCount: Int?
    /// Optional diagnostics for watch interruption/retry observability.
    /// Non-final v2 chunks should not persist this in transfer metadata.
    let captureDiagnostics: WatchCaptureDiagnostics?
    /// Transfer attempt identifier for WCSession delivery callback matching.
    let transferAttemptId: String?

    init(
        metadataVersion: Int = WatchRecordingProbeMetadata.singleChunkVersion,
        sessionId: String,
        startedAt: String,
        endedAt: String,
        durationSec: TimeInterval,
        fileName: String,
        source: String = "watch",
        chunkIndex: Int = 0,
        chunkStartOffsetSec: TimeInterval = 0,
        chunkCount: Int? = nil,
        captureDiagnostics: WatchCaptureDiagnostics? = nil,
        transferAttemptId: String? = nil
    ) {
        self.metadataVersion = metadataVersion
        self.sessionId = sessionId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSec = durationSec
        self.fileName = fileName
        self.source = source
        if metadataVersion == Self.singleChunkVersion {
            self.chunkIndex = 0
            self.chunkStartOffsetSec = 0
            self.chunkCount = 1
            self.captureDiagnostics = nil
            self.transferAttemptId = nil
        } else {
            self.chunkIndex = chunkIndex
            self.chunkStartOffsetSec = chunkStartOffsetSec
            self.chunkCount = chunkCount
            self.captureDiagnostics = captureDiagnostics
            self.transferAttemptId = transferAttemptId
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .metadataVersion)
        guard version == Self.singleChunkVersion || version == Self.chunkedVersion else {
            let context = DecodingError.Context(
                codingPath: container.codingPath + [CodingKeys.metadataVersion],
                debugDescription: "unsupported metadataVersion: \(version)",
                underlyingError: nil
            )
            throw DecodingError.dataCorrupted(context)
        }
        let rawDiagnostics = try container.decodeIfPresent(String.self, forKey: .watchCaptureDiagnosticsJSON)
        let captureDiagnostics: WatchCaptureDiagnostics?
        if let rawDiagnostics {
            guard let decodedDiagnostics = Self.decodeDiagnostics(rawDiagnostics) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: container.codingPath + [CodingKeys.watchCaptureDiagnosticsJSON],
                        debugDescription: "invalid watchCaptureDiagnosticsJSON",
                        underlyingError: nil
                    )
                )
            }
            captureDiagnostics = decodedDiagnostics
        } else {
            captureDiagnostics = nil
        }

        self.init(
            metadataVersion: version,
            sessionId: try container.decode(String.self, forKey: .sessionId),
            startedAt: try container.decode(String.self, forKey: .startedAt),
            endedAt: try container.decode(String.self, forKey: .endedAt),
            durationSec: try container.decode(TimeInterval.self, forKey: .durationSec),
            fileName: try container.decode(String.self, forKey: .fileName),
            source: try container.decode(String.self, forKey: .source),
            chunkIndex: try container.decodeIfPresent(Int.self, forKey: .chunkIndex) ?? 0,
            chunkStartOffsetSec: try container.decodeIfPresent(TimeInterval.self, forKey: .chunkStartOffsetSec) ?? 0,
            chunkCount: try container.decodeIfPresent(Int.self, forKey: .chunkCount),
            captureDiagnostics: captureDiagnostics,
            transferAttemptId: try container.decodeIfPresent(String.self, forKey: .transferAttemptId)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadataVersion, forKey: .metadataVersion)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(durationSec, forKey: .durationSec)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(source, forKey: .source)

        if metadataVersion >= Self.chunkedVersion {
            try container.encode(chunkIndex, forKey: .chunkIndex)
            try container.encode(chunkStartOffsetSec, forKey: .chunkStartOffsetSec)
            try container.encodeIfPresent(chunkCount, forKey: .chunkCount)
            try container.encodeIfPresent(transferAttemptId, forKey: .transferAttemptId)
            if let captureDiagnostics {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                let data = try encoder.encode(captureDiagnostics)
                let encoded = String(data: data, encoding: .utf8)
                try container.encode(encoded, forKey: .watchCaptureDiagnosticsJSON)
            }
        }
    }

    var isFinalChunk: Bool {
        chunkCount != nil
    }

    var dictionary: [String: Any] {
        var dict: [String: Any] = [
            Self.transferFlagKey: true,
            "metadataVersion": metadataVersion,
            "sessionId": sessionId,
            "startedAt": startedAt,
            "endedAt": endedAt,
            "durationSec": durationSec,
            "fileName": fileName,
            "source": source,
        ]
        if metadataVersion >= Self.chunkedVersion {
            dict["chunkIndex"] = chunkIndex
            dict["chunkStartOffsetSec"] = chunkStartOffsetSec
            if let chunkCount {
                dict["chunkCount"] = chunkCount
            }
            if let transferAttemptId {
                dict["transferAttemptId"] = transferAttemptId
            }
            if let captureDiagnostics {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                if let data = try? encoder.encode(captureDiagnostics) {
                    dict["watchCaptureDiagnosticsJSON"] = String(data: data, encoding: .utf8)
                }
            }
        }
        return dict
    }

    init?(dictionary: [String: Any]?) {
        guard let dict = dictionary,
              (dict[Self.transferFlagKey] as? Bool) == true,
              let metadataVersion = dict["metadataVersion"] as? Int,
              metadataVersion == Self.singleChunkVersion || metadataVersion == Self.chunkedVersion,
              let sessionId = dict["sessionId"] as? String,
              let startedAt = dict["startedAt"] as? String,
              let endedAt = dict["endedAt"] as? String,
              let fileName = dict["fileName"] as? String,
              let source = dict["source"] as? String,
              source == "watch",
              !sessionId.isEmpty,
              !startedAt.isEmpty,
              !endedAt.isEmpty,
              !fileName.isEmpty,
              !source.isEmpty,
              UUID(uuidString: sessionId) != nil else {
            return nil
        }

        guard let duration = Self.finiteDouble(dict["durationSec"]) else {
            return nil
        }

        let captureDiagnostics: WatchCaptureDiagnostics?
        if let rawDiagnostics = dict["watchCaptureDiagnosticsJSON"] {
            guard let diagnosticsString = rawDiagnostics as? String else {
                return nil
            }
            guard let diagnostics = Self.decodeDiagnostics(diagnosticsString) else {
                return nil
            }
            captureDiagnostics = diagnostics
        } else {
            captureDiagnostics = nil
        }

        var chunkIndex = 0
        var chunkStartOffsetSec: TimeInterval = 0
        var chunkCount: Int?
        var transferAttemptId: String?
        if metadataVersion == Self.chunkedVersion {
            guard let index = dict["chunkIndex"] as? Int,
                  index >= 0,
                  let offset = Self.finiteDouble(dict["chunkStartOffsetSec"]),
                  offset >= 0 else {
                return nil
            }
            chunkIndex = index
            chunkStartOffsetSec = offset
            if dict["chunkCount"] != nil {
                guard let count = dict["chunkCount"] as? Int, count == index + 1 else {
                    return nil
                }
                chunkCount = count
            }
            if let attemptId = dict["transferAttemptId"] as? String {
                guard !attemptId.isEmpty else {
                    return nil
                }
                transferAttemptId = attemptId
            }
        }

        let formatter = ISO8601DateFormatter()
        guard duration.isFinite,
              duration > 0,
              let startedDate = formatter.date(from: startedAt),
              let endedDate = formatter.date(from: endedAt),
              endedDate >= startedDate else {
            return nil
        }

        self.init(
            metadataVersion: metadataVersion,
            sessionId: sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSec: duration,
            fileName: fileName,
            source: source,
            chunkIndex: chunkIndex,
            chunkStartOffsetSec: chunkStartOffsetSec,
            chunkCount: chunkCount,
            captureDiagnostics: captureDiagnostics,
            transferAttemptId: transferAttemptId
        )
    }

    /// Returns the session/chunk metadata that is safe to persist and compare
    /// on the receiving device. The attempt identifier belongs to the
    /// WatchConnectivity transport envelope, not to the captured audio unit.
    func withoutTransferAttemptId() -> Self {
        guard transferAttemptId != nil else { return self }
        return Self(
            metadataVersion: metadataVersion,
            sessionId: sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSec: durationSec,
            fileName: fileName,
            source: source,
            chunkIndex: chunkIndex,
            chunkStartOffsetSec: chunkStartOffsetSec,
            chunkCount: chunkCount,
            captureDiagnostics: captureDiagnostics,
            transferAttemptId: nil
        )
    }

    func isValidUUIDSession() -> Bool {
        UUID(uuidString: sessionId) != nil
    }

    /// Structural self-check shared by staging and import. v1 always passes
    /// (constructor normalizes it to index 0 / offset 0 / count 1).
    func isStructurallyValidChunk() -> Bool {
        guard chunkIndex >= 0,
              chunkStartOffsetSec.isFinite,
              chunkStartOffsetSec >= 0,
              durationSec.isFinite,
              durationSec > 0 else {
            return false
        }
        if let chunkCount {
            return chunkCount == chunkIndex + 1
        }
        return true
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        let double: Double
        if let doubleValue = value as? Double {
            double = doubleValue
        } else if let numberValue = value as? NSNumber {
            double = numberValue.doubleValue
        } else {
            return nil
        }
        return double.isFinite ? double : nil
    }

    private enum CodingKeys: String, CodingKey {
        case metadataVersion
        case sessionId
        case startedAt
        case endedAt
        case durationSec
        case fileName
        case source
        case chunkIndex
        case chunkStartOffsetSec
        case chunkCount
        case transferAttemptId
        case watchCaptureDiagnosticsJSON
    }

    private static func decodeDiagnostics(_ rawDiagnostics: String) -> WatchCaptureDiagnostics? {
        let data = Data(rawDiagnostics.utf8)
        guard let parsed = try? JSONDecoder().decode(WatchCaptureDiagnostics.self, from: data),
              parsed.isValid() else {
            return nil
        }
        return parsed
    }
}

/// Application-level confirmation sent by the iPhone after a chunk has been
/// durably staged. The transport attempt is deliberately part of the ACK so a
/// delayed retry cannot acknowledge a newer Watch outbox attempt.
struct WatchChunkApplicationAck: Equatable, Sendable {
    static let typeKey = "type"
    static let type = "watchChunkApplicationAck"
    static let flagKey = "aiwatchingWatchChunkApplicationAck"

    let sessionId: String
    let chunkIndex: Int
    let transferAttemptId: String

    init(sessionId: String, chunkIndex: Int, transferAttemptId: String) {
        self.sessionId = sessionId
        self.chunkIndex = chunkIndex
        self.transferAttemptId = transferAttemptId
    }

    var dictionary: [String: Any] {
        [
            Self.flagKey: true,
            Self.typeKey: Self.type,
            "sessionId": sessionId,
            "chunkIndex": chunkIndex,
            "transferAttemptId": transferAttemptId,
        ]
    }

    init?(dictionary: [String: Any]?) {
        guard let dictionary,
              dictionary[Self.typeKey] as? String == Self.type,
              let flag = Self.exactBool(dictionary[Self.flagKey]),
              flag,
              let sessionId = dictionary["sessionId"] as? String,
              UUID(uuidString: sessionId) != nil,
              let chunkIndex = Self.exactInt(dictionary["chunkIndex"]),
              chunkIndex >= 0,
              let transferAttemptId = dictionary["transferAttemptId"] as? String,
              UUID(uuidString: transferAttemptId) != nil else {
            return nil
        }

        self.init(
            sessionId: sessionId,
            chunkIndex: chunkIndex,
            transferAttemptId: transferAttemptId
        )
    }

    /// WatchConnectivity property-list values cross the Objective-C boundary
    /// as NSNumber. Swift's ordinary casts are too permissive here:
    /// NSNumber(1) casts to Bool and NSNumber(true) casts to Int. Preserve the
    /// wire contract by distinguishing CFBoolean, integer CFNumber and float.
    private static func exactBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else {
            return nil
        }
        return number.boolValue
    }

    private static func exactInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(number) else {
            return nil
        }
        return value as? Int
    }
}
