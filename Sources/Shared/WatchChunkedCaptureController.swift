import AVFoundation
import Foundation
import WatchConnectivity

/// Coordinator surface the watch controller drives. `ScheduledChunkRecorder`
/// is the production implementation; tests inject fakes.
@MainActor
protocol WatchChunkedRecordingCoordinating: AnyObject {
    var isCapturing: Bool { get }

    @discardableResult
    func start() async throws -> ScheduledChunkRecorder.Chunk
    func stop()
}

@MainActor
extension ScheduledChunkRecorder: WatchChunkedRecordingCoordinating {}

/// Outbox sidecar: v2 chunk metadata plus transfer bookkeeping. Files stay on
/// disk after enqueue because `WCSession.transferFile` needs them until the
/// system finishes the transfer; GC is a later stage.
struct WatchChunkOutboxRecord: Codable, Equatable, Sendable {
    var metadata: WatchRecordingProbeMetadata
    var transferState: TransferState
    var isFinal: Bool
    var activeAttemptId: String?

    enum CodingKeys: String, CodingKey {
        case metadata
        case transferState
        case isFinal
        case enqueued
        case activeAttemptId
    }

    init(
        metadata: WatchRecordingProbeMetadata,
        transferState: TransferState = .pending,
        isFinal: Bool,
        activeAttemptId: String? = nil
    ) {
        self.metadata = metadata
        self.transferState = transferState
        self.isFinal = isFinal
        self.activeAttemptId = activeAttemptId
    }

    /// Transitional initializer used by existing tests and historical sidecars.
    init(metadata: WatchRecordingProbeMetadata, enqueued: Bool, isFinal: Bool) {
        self.metadata = metadata
        self.transferState = enqueued ? .enqueued : .pending
        self.isFinal = isFinal
        self.activeAttemptId = nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decode(WatchRecordingProbeMetadata.self, forKey: .metadata)
        isFinal = try container.decode(Bool.self, forKey: .isFinal)

        if let rawState = try? container.decode(TransferState.self, forKey: .transferState) {
            transferState = rawState
            activeAttemptId = try? container.decodeIfPresent(String.self, forKey: .activeAttemptId)
            return
        }

        // backward compatibility for existing sidecars created by earlier versions
        if let legacyEnqueued = try? container.decode(Bool.self, forKey: .enqueued) {
            transferState = legacyEnqueued ? .enqueued : .pending
            activeAttemptId = try? container.decodeIfPresent(String.self, forKey: .activeAttemptId)
            return
        }

        transferState = .pending
        activeAttemptId = try? container.decodeIfPresent(String.self, forKey: .activeAttemptId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(transferState, forKey: .transferState)
        try container.encode(isFinal, forKey: .isFinal)
        if let activeAttemptId {
            try container.encode(activeAttemptId, forKey: .activeAttemptId)
        }
    }
}

enum TransferState: String, Codable, Equatable, Sendable {
    case pending
    case enqueued
    case acknowledged
}

struct WatchChunkTransferIdentity: Hashable, Sendable {
    let sessionId: String
    let chunkIndex: Int
    let transferAttemptId: String?
}

enum WatchChunkedCaptureState: String, Equatable {
    case idle
    case starting
    case recording
    case interrupted
    case stopping
}

@MainActor
struct WatchCaptureEntryRouter {
    enum Entry {
        case primaryButton
        case deepLink(URL)
    }

    @discardableResult
    func handle(_ entry: Entry, controller: WatchChunkedCaptureController) async -> Bool {
        switch entry {
        case .primaryButton:
            await controller.start()
            return true
        case let .deepLink(url):
            guard url.absoluteString == "aiwatching://start" else {
                return false
            }
            await controller.start()
            return true
        }
    }
}

enum WatchChunkedCaptureError: Error, LocalizedError, Equatable {
    case permissionDenied
    case audioSessionSetupFailed
    case coordinatorDidNotStart

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "分片捕捉缺少麦克风授权"
        case .audioSessionSetupFailed:
            "分片捕捉音频会话配置失败"
        case .coordinatorDidNotStart:
            "分片录音协调器未启动"
        }
    }
}

protocol WatchChunkedTransferCompletionObserver: AnyObject {
    func watchChunkedCaptureController(didFinishTransfer metadata: WatchRecordingProbeMetadata, wasSuccessful: Bool)
    func watchChunkedCaptureController(didReceiveApplicationAck ack: WatchChunkApplicationAck)
}

/// Buffers both WatchConnectivity event types until the Watch controller is
/// registered. A single ordered queue prevents an early application ACK from
/// being lost during Watch app construction and preserves callback order.
@MainActor
final class WatchChunkedTransferObserverBuffer {
    private enum Event {
        case transferCompletion(metadata: WatchRecordingProbeMetadata, wasSuccessful: Bool)
        case applicationAck(WatchChunkApplicationAck)
    }

    private weak var observer: WatchChunkedTransferCompletionObserver?
    private var bufferedEvents: [Event] = []

    func register(_ observer: WatchChunkedTransferCompletionObserver?) {
        self.observer = observer
        guard let observer, !bufferedEvents.isEmpty else {
            return
        }

        let pending = bufferedEvents
        bufferedEvents.removeAll()
        for event in pending {
            deliver(event, to: observer)
        }
    }

    func receiveTransferCompletion(metadata: WatchRecordingProbeMetadata, wasSuccessful: Bool) {
        receive(.transferCompletion(metadata: metadata, wasSuccessful: wasSuccessful))
    }

    func receiveApplicationAck(_ ack: WatchChunkApplicationAck) {
        receive(.applicationAck(ack))
    }

    private func receive(_ event: Event) {
        guard let observer else {
            bufferedEvents.append(event)
            return
        }
        deliver(event, to: observer)
    }

    private func deliver(_ event: Event, to observer: WatchChunkedTransferCompletionObserver) {
        switch event {
        case let .transferCompletion(metadata, wasSuccessful):
            observer.watchChunkedCaptureController(
                didFinishTransfer: metadata,
                wasSuccessful: wasSuccessful
            )
        case let .applicationAck(ack):
            observer.watchChunkedCaptureController(didReceiveApplicationAck: ack)
        }
    }
}

@MainActor
final class WatchChunkedCaptureController: NSObject, ObservableObject {
    @Published private(set) var state: WatchChunkedCaptureState = .idle
    @Published private(set) var statusText = "分片捕捉待机"
    @Published private(set) var lastError: String?
    @Published private(set) var currentSessionId: String?
    @Published private(set) var transferredChunkCount = 0
    @Published private(set) var pendingTransferCount = 0

    var isRecording: Bool {
        state == .recording
    }

    typealias CoordinatorProvider = @MainActor (
        _ outboxSessionDirectory: URL,
        _ configuration: ScheduledChunkRecorder.Configuration,
        _ eventHandler: @escaping @MainActor (ScheduledChunkRecorder.Event) -> Void
    ) throws -> WatchChunkedRecordingCoordinating

    private let fileManager: FileManager
    private let documentsProvider: () -> URL
    private let requestPermission: @MainActor () async -> Bool
    private let transferClient: WatchRecordingProbeTransferClient
    private let resolveDuration: (URL) -> TimeInterval
    private let setupAudioSession: @MainActor () throws -> Void
    private let deactivateAudioSession: @MainActor () -> Void
    private let now: () -> Date
    private let configurationProvider: () -> ScheduledChunkRecorder.Configuration
    private let coordinatorProvider: CoordinatorProvider
    private let persistDiagnosticsFile: (Data, URL) throws -> Void
    private let outstandingTransferKeysProvider: () -> Set<WatchChunkTransferIdentity>

    private let minimumTransferDurationSec = 0.2

    private var coordinator: WatchChunkedRecordingCoordinating?
    private var sessionToken: UUID?
    private var sessionId: String?
    private var sessionStartedAt: Date?
    private var outboxSessionDirectory: URL?
    /// hold-one policy: the newest finalized chunk stays here until its
    /// successor finalizes (then it is definitively non-final) or the session
    /// stops (then it is the final chunk and carries `chunkCount`).
    private var heldChunkIndex: Int?
    private var lastFinalizedChunkIndex: Int?
    private var sessionDegraded = false
    private var stopRequestedDuringStart = false
    /// Set when interruption-ended(shouldResume) arrives while chunks are
    /// still finalizing; the stopped event then performs the resume.
    private var pendingResume = false
    private var sessionDiagnostics: WatchCaptureDiagnostics?
    private static func makeTransferIdentity(
        sessionId: String,
        chunkIndex: Int,
        transferAttemptId: String? = nil
    ) -> WatchChunkTransferIdentity {
        WatchChunkTransferIdentity(
            sessionId: sessionId,
            chunkIndex: chunkIndex,
            transferAttemptId: transferAttemptId
        )
    }

    private static func currentOutstandingTransferKeys() -> Set<WatchChunkTransferIdentity> {
        guard WCSession.isSupported() else { return [] }
        return Set(WCSession.default.outstandingFileTransfers.compactMap { transfer in
            guard let metadata = transfer.file.metadata as? [String: Any],
                  let parsed = WatchRecordingProbeMetadata(dictionary: metadata) else {
                return nil
            }
            return makeTransferIdentity(
                sessionId: parsed.sessionId,
                chunkIndex: parsed.chunkIndex,
                transferAttemptId: parsed.transferAttemptId
            )
        })
    }

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
        transferClient: WatchRecordingProbeTransferClient = DefaultWatchRecordingProbeTransferClient(),
        resolveDuration: @escaping (URL) -> TimeInterval = { fileURL in
            let asset = AVURLAsset(url: fileURL)
            return max(0, CMTimeGetSeconds(asset.duration))
        },
        setupAudioSession: @escaping @MainActor () throws -> Void = {
            try WatchRecordingAudioSessionPolicy.activate()
        },
        deactivateAudioSession: @escaping @MainActor () -> Void = {
            WatchRecordingAudioSessionPolicy.deactivate()
        },
        now: @escaping () -> Date = Date.init,
        configurationProvider: @escaping () -> ScheduledChunkRecorder.Configuration = {
            .init(chunkDuration: AIWatchingSchema.watchChunkDuration, overlapDuration: 0.25, initialLeadTime: 0.1)
        },
        coordinatorProvider: CoordinatorProvider? = nil,
        outstandingTransferKeysProvider: (() -> Set<WatchChunkTransferIdentity>)? = nil,
        persistDiagnosticsFile: @escaping (Data, URL) throws -> Void = { data, destination in
            try data.write(to: destination, options: [.atomic])
        }
    ) {
        self.fileManager = fileManager
        self.documentsProvider = documentsProvider
        self.requestPermission = requestPermission
        self.transferClient = transferClient
        self.resolveDuration = resolveDuration
        self.setupAudioSession = setupAudioSession
        self.deactivateAudioSession = deactivateAudioSession
        self.now = now
        self.configurationProvider = configurationProvider
        self.persistDiagnosticsFile = persistDiagnosticsFile
        self.outstandingTransferKeysProvider = outstandingTransferKeysProvider ?? {
            Self.currentOutstandingTransferKeys()
        }
        self.coordinatorProvider = coordinatorProvider ?? { directory, configuration, eventHandler in
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            ]
            return ScheduledChunkRecorder(
                configuration: configuration,
                settings: settings,
                urlProvider: { chunkIndex in
                    directory.appendingPathComponent(
                        AIWatchingSchema.chunkAudioFileName(chunkIndex: chunkIndex)
                    )
                },
                eventHandler: eventHandler
            )
        }
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruptionNotification(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    func handleTransferCompletion(metadata: WatchRecordingProbeMetadata, wasSuccessful: Bool) {
        let sessionDirectory = outboxRoot.appendingPathComponent(metadata.sessionId, isDirectory: true)
        processTransferCompletion(for: metadata, in: sessionDirectory, success: wasSuccessful)
    }

    /// Accepts only the iPhone's durable application ACK. A successful
    /// WCSession file-transfer callback is intentionally insufficient: it only
    /// proves that iOS accepted the file into its private Inbox.
    func handleApplicationAck(_ ack: WatchChunkApplicationAck) {
        let sessionDirectory = outboxRoot.appendingPathComponent(ack.sessionId, isDirectory: true)
        processApplicationAck(ack, in: sessionDirectory)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleInterruptionNotification(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }
        switch type {
        case .began:
            handleInterruptionBegan()
        case .ended:
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let shouldResume = options.contains(.shouldResume)
            Task { @MainActor [weak self] in
                await self?.handleInterruptionEnded(shouldResume: shouldResume)
            }
        @unknown default:
            break
        }
    }

    var outboxRoot: URL {
        documentsProvider().appendingPathComponent("watch-chunked-outbox", isDirectory: true)
    }

    // MARK: - Session lifecycle

    func start() async {
        guard state == .idle else { return }

        let token = UUID()
        let newSessionId = UUID().uuidString
        sessionToken = token
        state = .starting
        stopRequestedDuringStart = false
        statusText = "分片捕捉启动中"
        lastError = nil

        do {
            let granted = await requestPermission()
            guard sessionToken == token else { return }
            guard granted else {
                throw WatchChunkedCaptureError.permissionDenied
            }

            do {
                try setupAudioSession()
            } catch {
                throw WatchChunkedCaptureError.audioSessionSetupFailed
            }
            guard sessionToken == token else { return }

            let sessionDirectory = outboxRoot.appendingPathComponent(newSessionId, isDirectory: true)
            try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

            let newCoordinator = try coordinatorProvider(
                sessionDirectory,
                configurationProvider()
            ) { [weak self] event in
                self?.handleCoordinatorEvent(event, token: token)
            }
            coordinator = newCoordinator
            _ = try await newCoordinator.start()
            guard sessionToken == token else { return }
            guard newCoordinator.isCapturing else {
                throw WatchChunkedCaptureError.coordinatorDidNotStart
            }

            sessionId = newSessionId
            sessionStartedAt = now()
            outboxSessionDirectory = sessionDirectory
            heldChunkIndex = nil
            lastFinalizedChunkIndex = nil
            sessionDiagnostics = WatchCaptureDiagnostics(
                schemaVersion: 1,
                events: [],
                truncated: false
            )
            sessionDegraded = false
            transferredChunkCount = 0
            currentSessionId = newSessionId
            state = .recording
            statusText = "分片捕捉中"
            appendDiagnosticEvent(.recordingStarted)

            if stopRequestedDuringStart {
                stopRequestedDuringStart = false
                stop()
            }
        } catch {
            guard sessionToken == token else { return }
            coordinator?.stop()
            coordinator = nil
            deactivateAudioSession()
            sessionToken = nil
            sessionDiagnostics = nil
            state = .idle
            let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            statusText = "分片捕捉开始失败：\(detail)"
            lastError = detail
        }
    }

    func stop() {
        switch state {
        case .idle:
            statusText = "分片捕捉未在录音"
        case .starting:
            stopRequestedDuringStart = true
        case .stopping:
            break
        case .recording, .interrupted:
            appendDiagnosticEvent(.stopRequested)
            state = .stopping
            statusText = "分片捕捉停止中"
            pendingResume = false // an explicit stop wins over a deferred resume
            if let coordinator {
                coordinator.stop()
            } else {
                // Interrupted with no live coordinator: chunks are already
                // finalized, go straight to session completion.
                completeSession()
            }
        }
    }

    // MARK: - Coordinator events

    private func handleCoordinatorEvent(_ event: ScheduledChunkRecorder.Event, token: UUID) {
        guard sessionToken == token else { return }
        switch event {
        case let .chunkFinished(chunk, successfully):
            handleChunkFinished(chunk, successfully: successfully)
        case let .failed(detail):
            sessionDegraded = true
            lastError = "分片录音失败：\(detail)"
        case .stopped:
            coordinator = nil
            if state == .interrupted && !sessionDegraded {
                if pendingResume {
                    // Interruption already ended while chunks were finalizing;
                    // perform the deferred resume now.
                    pendingResume = false
                    Task { @MainActor [weak self] in
                        await self?.resumeAfterInterruption()
                    }
                } else {
                    // Chunks are finalized and held; await interruption end.
                    statusText = "音频中断，分片已收尾，等待恢复"
                }
                return
            }
            completeSession()
        }
    }

    private func handleChunkFinished(_ chunk: ScheduledChunkRecorder.Chunk, successfully: Bool) {
        guard let sessionId, let sessionStartedAt else { return }

        guard successfully, fileManager.fileExists(atPath: chunk.url.path) else {
            discardChunkFile(chunk.url)
            degradeSessionIfRecording(detail: "分片未成功结束")
            return
        }

        let duration = resolveDuration(chunk.url)
        guard duration.isFinite, duration > minimumTransferDurationSec else {
            discardChunkFile(chunk.url)
            if state == .stopping || state == .interrupted {
                // A too-short tail chunk is dropped; the held predecessor
                // becomes the final chunk at completion.
                return
            }
            degradeSessionIfRecording(detail: "分片持续时间过短")
            return
        }

        let metadata = WatchRecordingProbeMetadata(
            metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
            sessionId: sessionId,
            startedAt: AIWatchingClock.isoString(sessionStartedAt),
            endedAt: AIWatchingClock.isoString(sessionStartedAt.addingTimeInterval(chunk.startOffsetSec + duration)),
            durationSec: duration,
            fileName: chunk.url.lastPathComponent,
            chunkIndex: chunk.index,
            chunkStartOffsetSec: chunk.startOffsetSec
        )
        do {
            try writeOutboxRecord(
                WatchChunkOutboxRecord(metadata: metadata, enqueued: false, isFinal: false),
                chunkIndex: chunk.index
            )
        } catch {
            lastError = "分片元数据写入失败：\(error.localizedDescription)"
            degradeSessionIfRecording(detail: "分片元数据写入失败")
            return
        }

        // hold-one: the predecessor is definitively non-final now.
        if let heldChunkIndex {
            transferOutboxChunk(at: heldChunkIndex, markFinal: false)
        }
        heldChunkIndex = chunk.index
        lastFinalizedChunkIndex = chunk.index
    }

    private func degradeSessionIfRecording(detail: String) {
        sessionDegraded = true
        lastError = lastError ?? "分片捕捉部分成功：\(detail)"
        if state == .recording {
            state = .stopping
            coordinator?.stop()
        }
    }

    private func completeSession() {
        if let heldChunkIndex {
            appendDiagnosticEvent(.sessionCompleted)
            transferOutboxChunk(at: heldChunkIndex, markFinal: true)
        }
        let hadChunks = heldChunkIndex != nil || lastFinalizedChunkIndex != nil

        deactivateAudioSession()
        refreshPendingTransferCount()

        if hadChunks {
            statusText = sessionDegraded
                ? "分片捕捉已结束（部分成功），传输交由系统完成"
                : "分片捕捉已结束，传输交由系统完成"
        } else {
            statusText = "分片捕捉已结束，未产生可传输分片"
        }

        coordinator = nil
        sessionToken = nil
        sessionId = nil
        sessionStartedAt = nil
        outboxSessionDirectory = nil
        heldChunkIndex = nil
        lastFinalizedChunkIndex = nil
        sessionDiagnostics = nil
        sessionDegraded = false
        pendingResume = false
        currentSessionId = nil
        state = .idle
    }

    // MARK: - Interruption flow (ADR-007 decision 8)

    func handleInterruptionBegan() {
        guard state == .recording else { return }
        appendDiagnosticEvent(.interruptionBegan)
        state = .interrupted
        statusText = "音频中断，正在收尾当前分片"
        coordinator?.stop()
    }

    func handleInterruptionEnded(shouldResume: Bool) async {
        guard state == .interrupted else { return }
        appendDiagnosticEvent(.interruptionEnded, shouldResume: shouldResume)
        guard shouldResume else {
            state = .stopping
            statusText = "音频中断结束，系统未允许恢复"
            if coordinator != nil {
                coordinator?.stop()
            } else {
                completeSession()
            }
            return
        }
        guard coordinator == nil else {
            // Chunks still finalizing; the stopped event performs the resume.
            pendingResume = true
            appendDiagnosticEvent(.resumeDeferred)
            return
        }
        await resumeAfterInterruption()
    }

    private func resumeAfterInterruption() async {
        appendDiagnosticEvent(.resumeAttemptStarted)
        guard let token = sessionToken,
              let sessionStartedAt,
              let outboxSessionDirectory else {
            appendDiagnosticEvent(.resumeFailed, detail: "中断恢复缺少会话上下文")
            completeSession()
            return
        }

        do {
            try setupAudioSession()
            let base = configurationProvider()
            let resumeConfiguration = ScheduledChunkRecorder.Configuration(
                chunkDuration: base.chunkDuration,
                overlapDuration: base.overlapDuration,
                initialLeadTime: base.initialLeadTime,
                startingChunkIndex: (lastFinalizedChunkIndex ?? -1) + 1,
                startingStartOffsetSec: now().timeIntervalSince(sessionStartedAt)
            )
            let newCoordinator = try coordinatorProvider(
                outboxSessionDirectory,
                resumeConfiguration
            ) { [weak self] event in
                self?.handleCoordinatorEvent(event, token: token)
            }
            coordinator = newCoordinator
            _ = try await newCoordinator.start()
            guard sessionToken == token, state == .interrupted else { return }
            guard newCoordinator.isCapturing else {
                throw WatchChunkedCaptureError.coordinatorDidNotStart
            }
            state = .recording
            appendDiagnosticEvent(.resumeSucceeded)
            statusText = "音频中断已恢复，分片继续捕捉"
        } catch {
            appendDiagnosticEvent(.resumeFailed, detail: (error as? LocalizedError)?.errorDescription)
            lastError = "中断恢复失败：\((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
            sessionDegraded = true
            coordinator?.stop()
            coordinator = nil
            completeSession()
        }
    }

    // MARK: - Outbox transfer + recovery

    /// Re-attempts every outbox record whose enqueue previously failed,
    /// across all sessions, but skips the currently held chunk in the live session.
    func retryPendingTransfers() {
        for sessionDirectory in listOutboxSessionDirectories() {
            let records = listOutboxRecords(in: sessionDirectory)
            for (chunkIndex, record) in records where shouldRetry(record, at: chunkIndex, among: records, in: sessionDirectory) {
                sendOutboxRecord(record, chunkIndex: chunkIndex, in: sessionDirectory)
            }
        }
        refreshPendingTransferCount()
    }

    /// App relaunch implies any previous session has ended. Sessions left in
    /// the outbox without a final marker get their highest chunk
    /// promoted to final (chunkCount = index + 1) and resent once so the
    /// destination can assemble a complete session.
    func recoverAbandonedSessions() {
        reconcileOutboxTransferStatesWithOutstandingTransfers()
        for sessionDirectory in listOutboxSessionDirectories() {
            cleanupAcknowledgedRecords(in: sessionDirectory)
        }

        for sessionDirectory in listOutboxSessionDirectories()
        where sessionDirectory.lastPathComponent != sessionId {
            var records = listOutboxRecords(in: sessionDirectory)
            guard !records.isEmpty else {
                try? fileManager.removeItem(at: sessionDirectory)
                continue
            }

            let hasFinal = records.values.contains { $0.isFinal }
            if !hasFinal, let maxIndex = records.keys.max(), var record = records[maxIndex] {
                let diagnostics = appendRecoveredDiagnosticEvent(
                    to: loadSessionDiagnostics(in: sessionDirectory),
                    chunkIndex: maxIndex,
                    metadata: record.metadata,
                    eventDate: now()
                )

                record.isFinal = true
                record.metadata = WatchRecordingProbeMetadata(
                    metadataVersion: record.metadata.metadataVersion,
                    sessionId: record.metadata.sessionId,
                    startedAt: record.metadata.startedAt,
                    endedAt: record.metadata.endedAt,
                    durationSec: record.metadata.durationSec,
                    fileName: record.metadata.fileName,
                    source: record.metadata.source,
                    chunkIndex: record.metadata.chunkIndex,
                    chunkStartOffsetSec: record.metadata.chunkStartOffsetSec,
                    chunkCount: maxIndex + 1,
                    captureDiagnostics: diagnostics
                )
                // The promoted final must be (re)sent even if the non-final
                // version was already enqueued: without a final marker the
                // phone-side session never assembles. A duplicate differing
                // only by chunkCount is quarantined there — acceptable for an
                // abandoned session versus never completing. Mark unsent.
                record.transferState = .pending
                record.activeAttemptId = nil
                records[maxIndex] = record
                if let diagnostics {
                    persistDiagnosticsFileWrite(diagnostics, to: diagnosticsFileURL(in: sessionDirectory))
                }
                try? writeOutboxRecord(record, chunkIndex: maxIndex, in: sessionDirectory)
            }
        }

        retryPendingTransfers()
        refreshPendingTransferCount()
    }

    private func processTransferCompletion(
        for transferMetadata: WatchRecordingProbeMetadata,
        in sessionDirectory: URL,
        success: Bool
    ) {
        guard var record = readOutboxRecord(chunkIndex: transferMetadata.chunkIndex, in: sessionDirectory) else {
            return
        }

        guard transferMetadata.sessionId == record.metadata.sessionId,
              transferMetadata.chunkIndex == record.metadata.chunkIndex,
              record.transferState == .enqueued,
              transferMetadata.transferAttemptId == record.activeAttemptId else {
            return
        }

        if !isOutboxRecordCurrentAttempt(record: record, for: transferMetadata) {
            return
        }

        if !success {
            handleTransferFailed(record: &record, in: sessionDirectory, failureMessage: "未知错误")
            try? writeOutboxRecord(record, chunkIndex: transferMetadata.chunkIndex, in: sessionDirectory)
        }

        refreshPendingTransferCount()
    }

    private func isOutboxRecordCurrentAttempt(
        record: WatchChunkOutboxRecord,
        for transferMetadata: WatchRecordingProbeMetadata
    ) -> Bool {
        let active = record.activeAttemptId
        let callbackAttempt = transferMetadata.transferAttemptId

        // Compatibility for historical records produced before attempt IDs.
        if active == nil && callbackAttempt == nil {
            return true
        }
        return active == callbackAttempt && active != nil
    }

    private func processApplicationAck(
        _ ack: WatchChunkApplicationAck,
        in sessionDirectory: URL
    ) {
        guard var record = readOutboxRecord(chunkIndex: ack.chunkIndex, in: sessionDirectory) else {
            return
        }

        guard record.metadata.sessionId == ack.sessionId,
              record.metadata.chunkIndex == ack.chunkIndex,
              record.transferState == .enqueued,
              let activeAttemptId = record.activeAttemptId,
              !activeAttemptId.isEmpty,
              activeAttemptId == ack.transferAttemptId else {
            return
        }

        record.transferState = .acknowledged
        record.activeAttemptId = nil
        do {
            try writeOutboxRecord(record, chunkIndex: ack.chunkIndex, in: sessionDirectory)
            removeAcknowledgedOutboxArtifacts(for: ack.chunkIndex, in: sessionDirectory)
        } catch {
            lastError = "分片 \(ack.chunkIndex) 确认状态写入失败：\(error.localizedDescription)"
        }
        refreshPendingTransferCount()
    }

    private func handleTransferFailed(record: inout WatchChunkOutboxRecord, in sessionDirectory: URL, failureMessage: String) {
        lastError = "分片 \(record.metadata.chunkIndex) 传输失败：\(failureMessage)"
        record.transferState = .pending
        record.activeAttemptId = nil
    }

    private func transferOutboxChunk(at chunkIndex: Int, markFinal: Bool) {
        guard let outboxSessionDirectory else { return }
        transferOutboxChunk(at: chunkIndex, markFinal: markFinal, in: outboxSessionDirectory)
    }

    private func transferOutboxChunk(
        at chunkIndex: Int,
        markFinal: Bool,
        in sessionDirectory: URL,
        sessionDiagnosticsOverride: WatchCaptureDiagnostics? = nil
    ) {
        guard var record = readOutboxRecord(chunkIndex: chunkIndex, in: sessionDirectory) else {
            lastError = "分片 \(chunkIndex) 元数据缺失，无法传输"
            return
        }

        if markFinal {
            let diagnostics = sessionDiagnosticsOverride
                ?? sessionDiagnostics
                ?? loadSessionDiagnostics(in: sessionDirectory)
            record.isFinal = true
            record.metadata = WatchRecordingProbeMetadata(
                metadataVersion: record.metadata.metadataVersion,
                sessionId: record.metadata.sessionId,
                startedAt: record.metadata.startedAt,
                endedAt: record.metadata.endedAt,
                durationSec: record.metadata.durationSec,
                fileName: record.metadata.fileName,
                source: record.metadata.source,
                chunkIndex: record.metadata.chunkIndex,
                chunkStartOffsetSec: record.metadata.chunkStartOffsetSec,
                chunkCount: chunkIndex + 1,
                captureDiagnostics: diagnostics
            )
        } else if record.metadata.captureDiagnostics != nil {
            record.metadata = WatchRecordingProbeMetadata(
                metadataVersion: record.metadata.metadataVersion,
                sessionId: record.metadata.sessionId,
                startedAt: record.metadata.startedAt,
                endedAt: record.metadata.endedAt,
                durationSec: record.metadata.durationSec,
                fileName: record.metadata.fileName,
                source: record.metadata.source,
                chunkIndex: record.metadata.chunkIndex,
                chunkStartOffsetSec: record.metadata.chunkStartOffsetSec,
                chunkCount: nil,
                captureDiagnostics: nil
            )
        }

        try? writeOutboxRecord(record, chunkIndex: chunkIndex, in: sessionDirectory)
        sendOutboxRecord(record, chunkIndex: chunkIndex, in: sessionDirectory)
        heldChunkIndex = heldChunkIndex == chunkIndex ? nil : heldChunkIndex
    }

    private func removeAcknowledgedOutboxArtifacts(for chunkIndex: Int, in sessionDirectory: URL) {
        let audioURL = sessionDirectory.appendingPathComponent(
            AIWatchingSchema.chunkAudioFileName(chunkIndex: chunkIndex)
        )
        if fileManager.fileExists(atPath: audioURL.path) {
            try? fileManager.removeItem(at: audioURL)
        }

        let recordURL = outboxRecordURL(chunkIndex: chunkIndex, in: sessionDirectory)
        if fileManager.fileExists(atPath: recordURL.path) {
            try? fileManager.removeItem(at: recordURL)
        }

        cleanupAcknowledgedRecords(in: sessionDirectory)
    }

    private func cleanupAcknowledgedRecords(in sessionDirectory: URL) {
        let records = listOutboxRecords(in: sessionDirectory)
        guard !records.isEmpty else {
            let diagnosticsURL = diagnosticsFileURL(in: sessionDirectory)
            if fileManager.fileExists(atPath: diagnosticsURL.path) {
                try? fileManager.removeItem(at: diagnosticsURL)
            }
            let files = (try? fileManager.contentsOfDirectory(at: sessionDirectory, includingPropertiesForKeys: nil)) ?? []
            if files.isEmpty {
                try? fileManager.removeItem(at: sessionDirectory)
            }
            return
        }

        var hasRemainingPending = false
        var hasRemainingRecords = false

        for (_, record) in records {
            if record.transferState == .acknowledged {
                let audioURL = sessionDirectory.appendingPathComponent(
                    AIWatchingSchema.chunkAudioFileName(chunkIndex: record.metadata.chunkIndex)
                )
                if fileManager.fileExists(atPath: audioURL.path) {
                    try? fileManager.removeItem(at: audioURL)
                }
                let recordURL = outboxRecordURL(chunkIndex: record.metadata.chunkIndex, in: sessionDirectory)
                if fileManager.fileExists(atPath: recordURL.path) {
                    try? fileManager.removeItem(at: recordURL)
                }
            } else {
                hasRemainingRecords = true
            }

            if record.transferState != .acknowledged {
                hasRemainingPending = true
            }
        }

        // If all records were acknowledged (or removed), clean up diagnostics and
        // directory as long as we are not holding any non-acknowledged items.
        guard !hasRemainingRecords else { return }
        let diagnosticsURL = diagnosticsFileURL(in: sessionDirectory)
        if fileManager.fileExists(atPath: diagnosticsURL.path) {
            try? fileManager.removeItem(at: diagnosticsURL)
        }

        guard !hasRemainingPending else { return }
        let files = (try? fileManager.contentsOfDirectory(at: sessionDirectory, includingPropertiesForKeys: nil)) ?? []
        if files.isEmpty {
            try? fileManager.removeItem(at: sessionDirectory)
        }
    }

    private func sendOutboxRecord(_ record: WatchChunkOutboxRecord, chunkIndex: Int, in sessionDirectory: URL) {
        let audioURL = sessionDirectory.appendingPathComponent(
            AIWatchingSchema.chunkAudioFileName(chunkIndex: chunkIndex)
        )
        guard fileManager.fileExists(atPath: audioURL.path) else {
            lastError = "分片 \(chunkIndex) 音频缺失，无法传输"
            return
        }

        let attemptId = UUID().uuidString
        var transferRecord = record
        transferRecord.activeAttemptId = attemptId
        transferRecord.metadata = WatchRecordingProbeMetadata(
            metadataVersion: transferRecord.metadata.metadataVersion,
            sessionId: transferRecord.metadata.sessionId,
            startedAt: transferRecord.metadata.startedAt,
            endedAt: transferRecord.metadata.endedAt,
            durationSec: transferRecord.metadata.durationSec,
            fileName: transferRecord.metadata.fileName,
            source: transferRecord.metadata.source,
            chunkIndex: transferRecord.metadata.chunkIndex,
            chunkStartOffsetSec: transferRecord.metadata.chunkStartOffsetSec,
            chunkCount: transferRecord.metadata.chunkCount,
            captureDiagnostics: transferRecord.metadata.captureDiagnostics,
            transferAttemptId: attemptId
        )

        try? writeOutboxRecord(transferRecord, chunkIndex: chunkIndex, in: sessionDirectory)
        do {
            try transferClient.transfer(fileURL: audioURL, metadata: transferRecord.metadata.dictionary)
            var sent = transferRecord
            sent.transferState = .enqueued
            sent.activeAttemptId = attemptId
            try? writeOutboxRecord(sent, chunkIndex: chunkIndex, in: sessionDirectory)
            transferredChunkCount += 1
        } catch {
            lastError = "分片 \(chunkIndex) 传输入队失败：\((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
            if var pending = readOutboxRecord(chunkIndex: chunkIndex, in: sessionDirectory) {
                pending.activeAttemptId = nil
                pending.transferState = .pending
                try? writeOutboxRecord(pending, chunkIndex: chunkIndex, in: sessionDirectory)
            }
        }
    }

    private func appendDiagnosticEvent(
        _ kind: WatchCaptureDiagnosticEventKind,
        shouldResume: Bool? = nil,
        detail: String? = nil
    ) {
        let eventDate = now()
        appendDiagnosticEvent(
            kind,
            at: eventDate,
            shouldResume: shouldResume,
            detail: detail
        )
    }

    private func appendDiagnosticEvent(
        _ kind: WatchCaptureDiagnosticEventKind,
        at eventDate: Date,
        shouldResume: Bool? = nil,
        detail: String? = nil
    ) {
        guard state != .idle, state != .starting else {
            return
        }
        guard let sessionStartedAt, var diagnostics = sessionDiagnostics else {
            return
        }
        if diagnostics.events.count >= WatchCaptureDiagnostics.maxEventCount {
            if !diagnostics.truncated {
                diagnostics.truncated = true
                sessionDiagnostics = diagnostics
                persistSessionDiagnostics()
            }
            return
        }

        let event = WatchCaptureDiagnosticEvent(
            sequence: diagnostics.events.count,
            kind: kind,
            occurredAt: AIWatchingClock.isoString(eventDate),
            sessionOffsetSec: max(0, eventDate.timeIntervalSince(sessionStartedAt)),
            controllerState: state.rawValue,
            shouldResume: shouldResume,
            lastFinalizedChunkIndex: lastFinalizedChunkIndex,
            detail: detail
        )
        diagnostics.events.append(event)
        sessionDiagnostics = diagnostics
        persistSessionDiagnostics()
    }

    private func appendRecoveredDiagnosticEvent(
        to diagnostics: WatchCaptureDiagnostics?,
        chunkIndex: Int,
        metadata: WatchRecordingProbeMetadata,
        eventDate: Date
    ) -> WatchCaptureDiagnostics? {
        var accumulated = diagnostics ?? WatchCaptureDiagnostics(
            schemaVersion: 1,
            events: [],
            truncated: false
        )

        guard accumulated.events.count < WatchCaptureDiagnostics.maxEventCount else {
            accumulated.truncated = true
            return accumulated
        }

        let sessionStartedAt = parseISODate(metadata.startedAt) ?? eventDate
        let event = WatchCaptureDiagnosticEvent(
            sequence: accumulated.events.count,
            kind: .abandonedSessionRecovered,
            occurredAt: AIWatchingClock.isoString(eventDate),
            sessionOffsetSec: max(0, eventDate.timeIntervalSince(sessionStartedAt)),
            controllerState: "abandonedRecovery",
            shouldResume: nil,
            lastFinalizedChunkIndex: chunkIndex,
            detail: nil
        )
        accumulated.events.append(event)
        return accumulated
    }

    private func persistDiagnosticsFileWrite(_ data: WatchCaptureDiagnostics, to destination: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(data)
            try persistDiagnosticsFile(encoded, destination)
        } catch {
            lastError = "诊断信息持久化失败：\((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
        }
    }

    private func parseISODate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: value)
    }

    private func persistSessionDiagnostics() {
        guard let outboxSessionDirectory, let diagnostics = sessionDiagnostics else {
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(diagnostics)
            try persistDiagnosticsFile(data, diagnosticsFileURL(in: outboxSessionDirectory))
        } catch {
            lastError = "诊断信息持久化失败：\((error as? LocalizedError)?.errorDescription ?? String(describing: error))"
        }
    }

    // MARK: - Outbox IO

    private func outboxRecordURL(chunkIndex: Int, in sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent(
            AIWatchingSchema.chunkMetadataFileName(chunkIndex: chunkIndex)
        )
    }

    private func diagnosticsFileURL(in sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent(WatchCaptureDiagnostics.watchCaptureDiagnosticsFileName)
    }

    private func writeOutboxRecord(_ record: WatchChunkOutboxRecord, chunkIndex: Int) throws {
        guard let outboxSessionDirectory else { return }
        try writeOutboxRecord(record, chunkIndex: chunkIndex, in: outboxSessionDirectory)
    }

    private func writeOutboxRecord(
        _ record: WatchChunkOutboxRecord,
        chunkIndex: Int,
        in sessionDirectory: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: outboxRecordURL(chunkIndex: chunkIndex, in: sessionDirectory), options: [.atomic])
    }

    private func readOutboxRecord(chunkIndex: Int, in sessionDirectory: URL) -> WatchChunkOutboxRecord? {
        let url = outboxRecordURL(chunkIndex: chunkIndex, in: sessionDirectory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WatchChunkOutboxRecord.self, from: data)
    }

    private func listOutboxSessionDirectories() -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(at: outboxRoot, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.hasDirectoryPath && UUID(uuidString: $0.lastPathComponent) != nil }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }

    private func reconcileOutboxTransferStatesWithOutstandingTransfers() {
        let outstanding = outstandingTransferKeysProvider()
        for sessionDirectory in listOutboxSessionDirectories() {
            var sessionChanged = false
            var records = listOutboxRecords(in: sessionDirectory)

            for (chunkIndex, var record) in records {
                let identity = Self.makeTransferIdentity(
                    sessionId: record.metadata.sessionId,
                    chunkIndex: chunkIndex,
                    transferAttemptId: record.activeAttemptId
                )
                let keyMatchesActive = outstanding.contains(identity)

                if keyMatchesActive {
                    if record.transferState == .pending {
                        record.transferState = .enqueued
                        records[chunkIndex] = record
                        sessionChanged = true
                    }
                    continue
                }

                if record.transferState == .enqueued {
                    record.transferState = .pending
                    records[chunkIndex] = record
                    sessionChanged = true
                }
            }

            guard sessionChanged else { continue }
            for (chunkIndex, record) in records {
                try? writeOutboxRecord(record, chunkIndex: chunkIndex, in: sessionDirectory)
            }
        }
    }

    private func listOutboxRecords(in sessionDirectory: URL) -> [Int: WatchChunkOutboxRecord] {
        let entries = (try? fileManager.contentsOfDirectory(at: sessionDirectory, includingPropertiesForKeys: nil)) ?? []
        var records: [Int: WatchChunkOutboxRecord] = [:]
        for entry in entries where entry.pathExtension.lowercased() == "json" {
            guard entry.lastPathComponent.hasPrefix("chunk_") else {
                continue
            }
            guard let data = try? Data(contentsOf: entry),
                  let record = try? JSONDecoder().decode(WatchChunkOutboxRecord.self, from: data) else {
                continue
            }
            records[record.metadata.chunkIndex] = record
        }
        return records
    }

    private func refreshPendingTransferCount() {
        var pending = 0
        for sessionDirectory in listOutboxSessionDirectories() {
            let records = listOutboxRecords(in: sessionDirectory)
            for (chunkIndex, record) in records where shouldRetry(record, at: chunkIndex, among: records, in: sessionDirectory) {
                pending += 1
            }
        }
        pendingTransferCount = pending
    }

    private func isCurrentSessionDirectory(_ sessionDirectory: URL) -> Bool {
        sessionDirectory.lastPathComponent == sessionId
    }

    private func shouldRetry(
        _ record: WatchChunkOutboxRecord,
        at chunkIndex: Int,
        among records: [Int: WatchChunkOutboxRecord],
        in sessionDirectory: URL
    ) -> Bool {
        guard record.transferState == .pending else {
            return false
        }
        if isCurrentSessionDirectory(sessionDirectory), heldChunkIndex == chunkIndex {
            return false
        }
        if record.metadata.chunkCount != nil {
            return true
        }
        // Non-final chunks are safe to resend only once their successor exists.
        return records.keys.contains(chunkIndex + 1)
    }

    private func discardChunkFile(_ url: URL) {
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func loadSessionDiagnostics(in sessionDirectory: URL) -> WatchCaptureDiagnostics? {
        let url = diagnosticsFileURL(in: sessionDirectory)
        guard let data = try? Data(contentsOf: url),
              let diagnostics = try? JSONDecoder().decode(WatchCaptureDiagnostics.self, from: data) else {
            return nil
        }
        return diagnostics.isValid() ? diagnostics : nil
    }
}

extension WatchChunkedCaptureController: WatchChunkedTransferCompletionObserver {
    nonisolated func watchChunkedCaptureController(didFinishTransfer metadata: WatchRecordingProbeMetadata, wasSuccessful: Bool) {
        Task { @MainActor [weak self] in
            self?.handleTransferCompletion(metadata: metadata, wasSuccessful: wasSuccessful)
        }
    }

    nonisolated func watchChunkedCaptureController(didReceiveApplicationAck ack: WatchChunkApplicationAck) {
        Task { @MainActor [weak self] in
            self?.handleApplicationAck(ack)
        }
    }
}
