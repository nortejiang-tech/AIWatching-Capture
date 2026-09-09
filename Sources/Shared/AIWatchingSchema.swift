import Foundation

public enum AIWatchingSchema {
    public static let version = 1
    public static let externalManifestVersion = 2
    public static let profiledExternalManifestVersion = 3
    public static let appFolderName = "AIWatching"
    public static let recordingsFolderName = "recordings"
    public static let manifestFileName = "manifest.json"
    public static let statusFileName = "status.json"
    public static let audioFolderName = "audio"
    public static let chunkDuration: TimeInterval = 300
    /// Watch guaranteed-capture path uses shorter chunks: transfers start
    /// flowing earlier and a suspended app loses at most one chunk (ADR-007).
    public static let watchChunkDuration: TimeInterval = 60

    public static func chunkAudioFileName(chunkIndex: Int) -> String {
        String(format: "chunk_%04d.m4a", chunkIndex)
    }

    public static func chunkMetadataFileName(chunkIndex: Int) -> String {
        String(format: "chunk_%04d.json", chunkIndex)
    }

    public static func isSupportedCaptureManifest(
        schemaVersion: Int,
        source: CaptureSource
    ) -> Bool {
        schemaVersion == version && (source == .iphone || source == .watch)
    }
}

public enum CaptureSource: String, Codable, Sendable {
    case iphone
    case watch
    case external
}

public enum SessionState: String, Codable, Sendable {
    case recording
    case complete
    case transcribing
    case done
    case error
}

public struct AudioInfo: Codable, Equatable, Sendable {
    public var sampleRate: Int
    public var channels: Int
    public var format: String
    public var codec: String?

    public init(sampleRate: Int = 16_000, channels: Int = 1, format: String = "m4a-aac", codec: String? = "aac") {
        self.sampleRate = sampleRate
        self.channels = channels
        self.format = format
        self.codec = codec
    }
}

public struct AudioChunk: Codable, Identifiable, Equatable, Sendable {
    public var id: Int { index }
    public var file: String
    public var index: Int
    public var startOffsetSec: Double
    public var durationSec: Double
    public var startedAt: String?

    public init(file: String, index: Int, startOffsetSec: Double, durationSec: Double, startedAt: String? = nil) {
        self.file = file
        self.index = index
        self.startOffsetSec = startOffsetSec
        self.durationSec = durationSec
        self.startedAt = startedAt
    }
}

public struct CaptureBookmark: Codable, Identifiable, Equatable, Sendable {
    public var id: String?
    public var atSec: Double
    public var atTime: String?
    public var note: String?
    public var source: String?

    public init(id: String? = UUID().uuidString, atSec: Double, atTime: String? = nil, note: String? = nil, source: String? = nil) {
        self.id = id
        self.atSec = atSec
        self.atTime = atTime
        self.note = note
        self.source = source
    }
}

public struct SessionManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var sessionId: String
    public var title: String?
    public var source: CaptureSource
    public var device: String?
    public var startedAt: String
    public var endedAt: String?
    public var timezone: String?
    public var language: String
    public var customVocabulary: [String]
    public var audio: AudioInfo
    public var chunks: [AudioChunk]
    public var bookmarks: [CaptureBookmark]

    public init(
        schemaVersion: Int = AIWatchingSchema.version,
        sessionId: String,
        title: String? = nil,
        source: CaptureSource = .iphone,
        device: String? = nil,
        startedAt: String,
        endedAt: String? = nil,
        timezone: String? = TimeZone.current.identifier,
        language: String = "auto",
        customVocabulary: [String] = ["AIWatching"],
        audio: AudioInfo = AudioInfo(),
        chunks: [AudioChunk] = [],
        bookmarks: [CaptureBookmark] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.title = title
        self.source = source
        self.device = device
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timezone = timezone
        self.language = language
        self.customVocabulary = customVocabulary
        self.audio = audio
        self.chunks = chunks
        self.bookmarks = bookmarks
    }
}

public struct SessionStatus: Codable, Equatable, Sendable {
    public var state: SessionState
    public var updatedAt: String
    public var engine: String?
    public var detail: String?

    public init(state: SessionState, updatedAt: String = AIWatchingClock.isoString(), engine: String? = nil, detail: String? = nil) {
        self.state = state
        self.updatedAt = updatedAt
        self.engine = engine
        self.detail = detail
    }
}

public enum AIWatchingClock {
    public static func isoString(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    public static func sessionFolderPrefix(_ date: Date = Date()) -> String {
        isoString(date).replacingOccurrences(of: ":", with: "-")
    }

}
