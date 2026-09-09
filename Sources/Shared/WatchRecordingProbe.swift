import AVFoundation
import Foundation
import WatchConnectivity

enum WatchRecordingProbeState: String, Equatable {
    case idle
    case starting
    case recording
    case stopping
}

protocol WatchRecordingProbeRecording: AnyObject {
    var isRecording: Bool { get }
    var url: URL { get }

    func prepareToRecord() -> Bool
    func record() -> Bool
    func stop()
}

extension AVAudioRecorder: WatchRecordingProbeRecording {}

protocol WatchRecordingProbeRecorderFactory {
    func makeRecorder(url: URL, settings: [String: Any]) throws -> WatchRecordingProbeRecording
}

struct DefaultWatchRecordingProbeRecorderFactory: WatchRecordingProbeRecorderFactory {
    func makeRecorder(url: URL, settings: [String: Any]) throws -> WatchRecordingProbeRecording {
        try AVAudioRecorder(url: url, settings: settings)
    }
}

protocol WatchRecordingProbeTransferClient: Sendable {
    func transfer(fileURL: URL, metadata: [String: Any]) throws
}

struct DefaultWatchRecordingProbeTransferClient: WatchRecordingProbeTransferClient {
    func transfer(fileURL: URL, metadata: [String: Any]) throws {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            throw WatchRecordingProbeError.transferUnavailable
        }
        WCSession.default.transferFile(fileURL, metadata: metadata)
    }
}

enum WatchRecordingProbeError: Error, LocalizedError {
    case permissionDenied
    case prepareFailed
    case recordFailed
    case startCancelled
    case audioSessionSetupFailed
    case missingSessionContext
    case fileResolutionFailed
    case fileNotFoundOrEmpty
    case transferUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "探针录音缺少麦克风授权"
        case .prepareFailed:
            "探针录音初始化失败"
        case .recordFailed:
            "探针录音启动失败"
        case .startCancelled:
            "探针启动已取消"
        case .audioSessionSetupFailed:
            "探针录音音频会话配置失败"
        case .missingSessionContext:
            "探针录音上下文丢失"
        case .fileResolutionFailed:
            "探针录音文件解析失败"
        case .fileNotFoundOrEmpty:
            "探针录音文件无效"
        case .transferUnavailable:
            "与 iPhone 的文件传输会话不可用"
        }
    }
}

@MainActor
final class WatchRecordingProbeController: ObservableObject {
    @Published private(set) var state: WatchRecordingProbeState = .idle
    @Published private(set) var statusText = "探针待机"
    @Published private(set) var lastError: String?
    @Published private(set) var lastFileName: String?
    @Published private(set) var lastDurationSec: TimeInterval?
    @Published private(set) var hasPendingTransfer = false
    @Published private(set) var pendingTransferFileURL: URL?

    var isRecording: Bool {
        state == .recording
    }

    private let audioFilenamePrefix = "aivision-watch-probe"
    private let minimumTransferDurationSec = 0.2

    private let configuration: [String: Any]
    private let outputDirectory: URL
    private let requestPermission: @MainActor () async -> Bool
    private let recorderFactory: WatchRecordingProbeRecorderFactory
    private let transferClient: WatchRecordingProbeTransferClient
    private let resolveDurationProvider: (URL) -> TimeInterval
    private let setupAudioSession: @MainActor () throws -> Void
    private let deactivateAudioSession: @MainActor () -> Void
    private let now: () -> Date
    private let documentsProvider: () -> URL
    private let fileManager: FileManager

    private var recorder: WatchRecordingProbeRecording?
    private var currentFileURL: URL?
    private var activeStartGeneration: UUID?
    private var activeSessionId: String?
    private var activeSessionStartedAt: Date?
    private var pendingTransferMetadata: [String: Any]?

    init(
        fileManager: FileManager = .default,
        documentsProvider: @escaping () -> URL = {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        },
        requestPermission: @escaping @MainActor () async -> Bool = {
            await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        },
        recorderFactory: WatchRecordingProbeRecorderFactory = DefaultWatchRecordingProbeRecorderFactory(),
        transferClient: WatchRecordingProbeTransferClient = DefaultWatchRecordingProbeTransferClient(),
        resolveDurationProvider: @escaping (URL) -> TimeInterval = { fileURL in
            let asset = AVURLAsset(url: fileURL)
            return max(0, CMTimeGetSeconds(asset.duration))
        },
        setupAudioSession: @escaping @MainActor () throws -> Void = {
            try WatchRecordingAudioSessionPolicy.activate()
        },
        deactivateAudioSession: @escaping @MainActor () -> Void = {
            WatchRecordingAudioSessionPolicy.deactivate()
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.requestPermission = requestPermission
        self.recorderFactory = recorderFactory
        self.transferClient = transferClient
        self.resolveDurationProvider = resolveDurationProvider
        self.setupAudioSession = setupAudioSession
        self.deactivateAudioSession = deactivateAudioSession
        self.now = now
        self.documentsProvider = documentsProvider
        self.fileManager = fileManager

        configuration = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        let documents = documentsProvider()
        outputDirectory = documents.appendingPathComponent("WatchRecordingProbe", isDirectory: true)
    }

    func start() async {
        guard state == .idle else {
            return
        }

        guard !hasPendingTransfer else {
            statusText = "请先重试待传文件"
            return
        }

        let generation = UUID()
        let sessionId = UUID().uuidString
        activeStartGeneration = generation
        activeSessionId = nil
        activeSessionStartedAt = nil
        state = .starting
        statusText = "探针启动中"
        lastError = nil

        var createdFileURL: URL?

        do {
            let hasPermission = await requestPermission()
            try ensureCurrentGeneration(generation)
            guard hasPermission else {
                throw WatchRecordingProbeError.permissionDenied
            }

            let fileURL = try allocateFileURL()
            createdFileURL = fileURL

            do {
                try setupAudioSession()
            } catch {
                throw WatchRecordingProbeError.audioSessionSetupFailed
            }
            try ensureCurrentGeneration(generation)

            let newRecorder = try recorderFactory.makeRecorder(url: fileURL, settings: configuration)
            try ensureCurrentGeneration(generation)

            guard newRecorder.prepareToRecord() else {
                newRecorder.stop()
                throw WatchRecordingProbeError.prepareFailed
            }
            try ensureCurrentGeneration(generation)

            guard newRecorder.record() else {
                newRecorder.stop()
                throw WatchRecordingProbeError.recordFailed
            }
            let recordingStartedAt = now()
            do {
                try ensureCurrentGeneration(generation)
            } catch {
                newRecorder.stop()
                throw error
            }

            recorder = newRecorder
            currentFileURL = fileURL
            activeSessionId = sessionId
            activeSessionStartedAt = recordingStartedAt
            lastFileName = fileURL.lastPathComponent
            state = .recording
            statusText = "探针录音中"
        } catch {
            if isCurrentGeneration(generation) {
                finishStartFailure(fileURL: createdFileURL, error: error)
            } else {
                if let createdFileURL {
                    discardFile(createdFileURL)
                }
            }
        }
    }

    func stop() async {
        let sessionId = activeSessionId
        let sessionStartedAt = activeSessionStartedAt
        stopGeneration()

        switch state {
        case .idle:
            statusText = "探针未在录音"
            return
        case .starting, .stopping:
            state = .stopping
            statusText = "探针启动已取消"
            if let currentFileURL {
                discardFile(currentFileURL)
            }
            recorder?.stop()
            recorder = nil
            self.currentFileURL = nil
            deactivateAudioSession()
            state = .idle
            return
        case .recording:
            state = .stopping
        }

        let current = recorder
        let fileURL = currentFileURL
        recorder = nil
        currentFileURL = nil
        current?.stop()

        do {
            guard let fileURL else {
                throw WatchRecordingProbeError.fileNotFoundOrEmpty
            }
            guard let sessionId, let sessionStartedAt else {
                throw WatchRecordingProbeError.missingSessionContext
            }

            let duration = try validatedDuration(for: fileURL)
            lastDurationSec = duration
            lastFileName = fileURL.lastPathComponent

            if duration > minimumTransferDurationSec {
                let metadata = transferMetadata(
        for: fileURL,
                    duration: duration,
                    sessionId: sessionId,
                    sessionStartedAt: sessionStartedAt
                )
                do {
                    try transferClient.transfer(fileURL: fileURL, metadata: metadata)
                    pendingTransferFileURL = nil
                    pendingTransferMetadata = nil
                    hasPendingTransfer = false
                    let durationText = String(format: "%.3f", duration)
                    statusText = "探针已停止（" + durationText + "s），传输已入队"
                } catch {
                    statusText = "探针停止，但传输入队失败：\((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
                    hasPendingTransfer = true
                    pendingTransferFileURL = fileURL
                    pendingTransferMetadata = metadata
                    lastError = statusText
                }
            } else {
                let durationText = String(format: "%.3f", duration)
                statusText = "探针已停止（" + durationText + "s），未达到传输最小时长"
                pendingTransferFileURL = nil
                pendingTransferMetadata = nil
                hasPendingTransfer = false
                discardFile(fileURL)
            }

            deactivateAudioSession()
            state = .idle
        } catch {
            finalizeStopWithFailure(fileURL: fileURL, error: error)
        }
    }

    func resetState() {
        stopGeneration()
        recorder?.stop()
        if let currentFileURL {
            discardFile(currentFileURL)
        }
        recorder = nil
        currentFileURL = nil
        state = .idle
        statusText = "探针待机"
        lastError = nil
        lastFileName = nil
        lastDurationSec = nil
        deactivateAudioSession()
    }

    func retryPendingTransfer() {
        guard hasPendingTransfer, let pendingFileURL = pendingTransferFileURL, let pendingTransferMetadata else {
            return
        }

        do {
            let duration = try validatedDuration(for: pendingFileURL)
            guard duration > minimumTransferDurationSec else {
                statusText = "待传输文件时长不足"
                return
            }

            try transferClient.transfer(fileURL: pendingFileURL, metadata: pendingTransferMetadata)
            statusText = "待传输任务已入队"
            hasPendingTransfer = false
            self.pendingTransferFileURL = nil
            self.pendingTransferMetadata = nil
            self.lastError = nil
        } catch {
            statusText = "传输重试失败：\((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
            hasPendingTransfer = true
            lastError = statusText
        }
    }

    private func isCurrentGeneration(_ generation: UUID) -> Bool {
        activeStartGeneration == generation && state == .starting
    }

    private func ensureCurrentGeneration(_ generation: UUID) throws {
        guard isCurrentGeneration(generation) else {
            throw WatchRecordingProbeError.startCancelled
        }
    }

    private func stopGeneration() {
        activeStartGeneration = nil
        activeSessionId = nil
        activeSessionStartedAt = nil
    }

    private func finalizeStopWithFailure(fileURL: URL?, error: Error) {
        recorder = nil
        currentFileURL = nil
        deactivateAudioSession()

        if let fileURL, fileManager.fileExists(atPath: fileURL.path) {
            lastFileName = fileURL.lastPathComponent
        }

        state = .idle
        if let watchError = error as? WatchRecordingProbeError {
            statusText = watchError.localizedDescription
            lastError = watchError.localizedDescription
            return
        }

        statusText = "探针失败"
        lastError = "探针失败"
    }

    private func finishStartFailure(fileURL: URL?, error: Error) {
        recorder?.stop()
        recorder = nil
        currentFileURL = nil

        if let fileURL {
            discardFile(fileURL)
        }

        deactivateAudioSession()
        stopGeneration()
        state = .idle

        if let watchError = error as? WatchRecordingProbeError {
            statusText = watchError.localizedDescription
            if watchError != .startCancelled {
                lastError = watchError.localizedDescription
            }
            return
        }

        statusText = "探针失败"
        lastError = "探针失败"
    }

    private func validatedDuration(for fileURL: URL) throws -> TimeInterval {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw WatchRecordingProbeError.fileNotFoundOrEmpty
        }

        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
            throw WatchRecordingProbeError.fileNotFoundOrEmpty
        }

        let duration = resolveDurationProvider(fileURL)
        guard duration.isFinite else {
            throw WatchRecordingProbeError.fileResolutionFailed
        }

        return max(0, duration)
    }

    private func discardFile(_ fileURL: URL) {
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    private func allocateFileURL() throws -> URL {
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        return outputDirectory.appendingPathComponent("\(audioFilenamePrefix)-\(id).m4a")
    }

    private func transferMetadata(
        for fileURL: URL,
        duration: TimeInterval,
        sessionId: String,
        sessionStartedAt: Date
    ) -> [String: Any] {
        return WatchRecordingProbeMetadata(
            sessionId: sessionId,
            startedAt: AIWatchingClock.isoString(sessionStartedAt),
            endedAt: AIWatchingClock.isoString(now()),
            durationSec: duration,
            fileName: fileURL.lastPathComponent
        ).dictionary
    }
}
