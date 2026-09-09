import AVFoundation
import Foundation
import UIKit

protocol CaptureRecording: AnyObject {
    var delegate: AVAudioRecorderDelegate? { get set }
    var isRecording: Bool { get }
    var url: URL { get }
    func prepareToRecord() -> Bool
    func record(forDuration: TimeInterval) -> Bool
    func stop()
}

extension AVAudioRecorder: CaptureRecording {}

@MainActor
protocol ScheduledChunkRecorderLike: AnyObject {
    var activeChunk: ScheduledChunkRecorder.Chunk? { get }
    var scheduledChunk: ScheduledChunkRecorder.Chunk? { get }
    var isCapturing: Bool { get }

    @discardableResult
    func start() async throws -> ScheduledChunkRecorder.Chunk
    func stop()
}

@MainActor
extension ScheduledChunkRecorder: ScheduledChunkRecorderLike {}

protocol CaptureRecorderFactory {
    func makeRecorder(url: URL, settings: [String: Any]) throws -> CaptureRecording
}

struct DefaultCaptureRecorderFactory: CaptureRecorderFactory {
    func makeRecorder(url: URL, settings: [String: Any]) throws -> CaptureRecording {
        try AVAudioRecorder(url: url, settings: settings)
    }
}

@MainActor
private final class ScheduledChunkFinalizationQueue {
    typealias Operation = @MainActor () async -> Void

    private var waiting: [Int: Operation] = [:]
    private var nextIndex = 0
    private var tail: Task<Void, Never> = Task {}

    func enqueue(index: Int, operation: @escaping Operation) {
        guard index >= nextIndex, waiting[index] == nil else { return }
        waiting[index] = operation
        scheduleContiguousOperations()
    }

    func drain() async {
        await tail.value
    }

    func reset() {
        waiting.removeAll()
        nextIndex = 0
        tail.cancel()
        tail = Task {}
    }

    private func scheduleContiguousOperations() {
        while let operation = waiting.removeValue(forKey: nextIndex) {
            let previous = tail
            tail = Task { @MainActor in
                await previous.value
                guard !Task.isCancelled else { return }
                await operation()
            }
            nextIndex += 1
        }
    }
}

@MainActor
final class CaptureController: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsedText = "00:00:00"
    @Published private(set) var recentSessions: [String] = []
    @Published var message: String?
    @Published private(set) var lastWriteError: String?

    private let store = CaptureStore()
    private var recorder: CaptureRecording?
    private var scheduledChunkRecorder: ScheduledChunkRecorderLike?
    private var scheduledChunkFinalizationQueue = ScheduledChunkFinalizationQueue()
    private var scheduledChunkFailureDetail: String?
    private var scheduledChunkShouldDiscardSession = false
    private var scheduledChunkCompletionTask: Task<Void, Never>?
    private var scheduledChunkModeEnabled: () -> Bool = {
        true
    }
    private var scheduledChunkConfigurationProvider: () -> ScheduledChunkRecorder.Configuration = {
#if AIWATCHING_SCHEDULED_CHUNK_PROTOTYPE
        .init(chunkDuration: 10, overlapDuration: 0.25, initialLeadTime: 0.1)
#else
        .init(chunkDuration: AIWatchingSchema.chunkDuration, overlapDuration: 0.25, initialLeadTime: 0.1)
#endif
    }
    private var scheduledChunkRecorderProvider: (
        URL,
        ScheduledChunkRecorder.Configuration,
        @escaping @MainActor (ScheduledChunkRecorder.Event, UUID) -> Void,
        UUID
    ) throws -> ScheduledChunkRecorderLike = { sessionDirectory, configuration, handler, sessionToken in
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        return ScheduledChunkRecorder(
            configuration: configuration,
            settings: settings,
            recorderFactory: DefaultScheduledCaptureRecorderFactory(),
            urlProvider: { chunkIndex in
            CaptureStore().audioURL(sessionDirectory: sessionDirectory, chunkIndex: chunkIndex)
            },
            eventHandler: { event in
                handler(event, sessionToken)
            }
        )
    }
    private var activeSessionToken: UUID?
    private var manifest: SessionManifest?
    private var sessionDirectory: URL?
    private var sessionRecordingsRoot: URL?
    private var recentSessionsRecordingsRoot: URL?
    private var sessionStartedAt: Date?
    private var currentChunkStartedAt: Date?
    private var currentChunkIndex = 0
    private var currentChunkURL: URL?
    private var recorderGate = CaptureRecorderIdentityGate()
    private var interruptionFlow = CaptureInterruptionFlow()
    private var lifecycle: CaptureLifecycle = .idle
    private var timer: Timer?
    private var interruptionGeneration = 0
    private var pendingCompletionDetail: String?
    private var interruptionActionScheduler: (@MainActor (@escaping () async -> Void) -> Void)?
    private var publishCaptureStateProvider: (Bool, String, String?) -> Void = { _, _, _ in }
    private var enqueueCompletedSessionProvider: (URL) -> Void = { _ in }
    private var recordingsRootProvider: () throws -> URL = {
        try CaptureStore().recordingsRoot()
    }
    private var requestPermissionProvider: () async -> Bool = { false }
    private var configureAudioSessionProvider: () throws -> Void = {}
    private var deactivateAudioSessionProvider: () throws -> Void = {}
    private static let defaultResolveFinalizedChunkDurationProvider: (URL) async throws -> TimeInterval = { chunkURL in
        try await CaptureController.resolveFinalizedChunkDurationFromRecorderFile(at: chunkURL)
    }
    private var makeSessionDirectoryProvider: (Date, String, URL) throws -> URL = { _, _, _ in
        throw CaptureError.noSessionDirectory
    }
    private var makeRecorderProvider: (URL, [String: Any]) throws -> CaptureRecording = { _, _ in
        throw CaptureError.noSessionDirectory
    }
    private var resolveFinalizedChunkDurationProvider: (URL) async throws -> TimeInterval = CaptureController.defaultResolveFinalizedChunkDurationProvider
    private var persistActiveSessionProvider: (SessionManifest, URL) throws -> Void = { manifest, sessionDirectory in
        let manifestStore = CaptureStore()
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try manifestStore.writeManifest(manifest, to: sessionDirectory)
        try manifestStore.writeStatus(SessionStatus(state: .recording), to: sessionDirectory)
    }

    private enum CaptureLifecycle: Equatable {
        case idle
        case starting
        case recording
        case interrupted
        case stopping
    }

    override init() {
        super.init()
        requestPermissionProvider = {
            await Self.requestMicrophonePermission()
        }
        configureAudioSessionProvider = {
            try Self.configureAudioSession()
        }
        deactivateAudioSessionProvider = {
            try Self.deactivateAudioSession()
        }
        makeSessionDirectoryProvider = { startedAt, sessionId, recordingsRoot in
            return try CaptureStore().makeSessionDirectory(
                startedAt: startedAt,
                sessionId: sessionId,
                recordingsRoot: recordingsRoot
            )
        }
        makeRecorderProvider = { url, settings in
            try DefaultCaptureRecorderFactory().makeRecorder(url: url, settings: settings)
        }
        interruptionActionScheduler = { action in
            Task {
                await action()
            }
        }
        publishCaptureStateProvider = { isCapturing, statusText, sessionId in
            PhoneConnectivityController.shared.publishCaptureState(
                isCapturing: isCapturing,
                statusText: statusText,
                sessionId: sessionId
            )
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var isActiveSession: Bool {
        manifest != nil && sessionDirectory != nil
    }

    func loadRecentSessions() async {
        let previousRoot = recentSessionsRecordingsRoot
        let previousSessions = recentSessions
        do {
            let recordingsRoot = try recordingsRootProvider()
            let names = try store.recentSessionNames(at: recordingsRoot)
            recentSessionsRecordingsRoot = recordingsRoot
            recentSessions = names
        } catch {
            recentSessionsRecordingsRoot = previousRoot
            recentSessions = previousSessions
            message = "无法读取会话目录：\(error.localizedDescription)"
        }
    }

    private func refreshRecentSessionsFromBoundRoot() async {
        guard let recordingsRoot = recentSessionsRecordingsRoot else {
            return
        }
        let previousSessions = recentSessions
        do {
            recentSessions = try store.recentSessionNames(at: recordingsRoot)
        } catch {
            recentSessions = previousSessions
            message = "无法刷新会话列表：\(error.localizedDescription)"
        }
    }

    func performPendingCommandIfNeeded() async {
        guard let command = CaptureCommand.takePending() else { return }
        switch command {
        case .start:
            await startCapture()
        case .stop:
            await stopCapture()
        case .bookmark:
            await addBookmark(note: nil, source: "iphone")
        }
    }

    /// Starts a capture session. Returns a structured result so callers (e.g. the
    /// Watch reply) only report success after recording has *actually* started.
    @discardableResult
    func startCapture() async -> CaptureStartResult {
        guard lifecycle == .idle, !isRecording else { return CaptureStartResult(ok: isRecording, message: "已在捕捉。") }
        let sessionToken = UUID()
        var provisionalSessionDirectory: URL?
        var cleanupSessionDirectory: URL?
        var provisionalRecordingsRoot: URL?
        var didActivateAudioSession = false
        do {
            activeSessionToken = sessionToken
            lifecycle = .starting
            pendingCompletionDetail = nil
            let granted = await requestPermissionProvider()
            guard isCurrentSessionToken(sessionToken) else {
                await handleStartFailure(
                    sessionToken: sessionToken,
                    provisionalSessionDirectory: provisionalSessionDirectory,
                    cleanupSessionDirectory: cleanupSessionDirectory,
                    provisionalRecordingsRoot: provisionalRecordingsRoot,
                    didActivateAudioSession: didActivateAudioSession
                )
                return CaptureStartResult(ok: false, message: "会话已切换，开始取消。")
            }
            guard granted else {
                let text = "没有麦克风权限，无法开始捕捉。"
                message = text
                activeSessionToken = nil
                lifecycle = .idle
                return CaptureStartResult(ok: false, message: text)
            }

            try configureAudioSessionProvider()
            didActivateAudioSession = true

            guard isCurrentSessionToken(sessionToken) else {
                let text = "会话已切换，开始失败。"
                message = text
                await handleStartFailure(
                    sessionToken: sessionToken,
                    provisionalSessionDirectory: provisionalSessionDirectory,
                    cleanupSessionDirectory: cleanupSessionDirectory,
                    provisionalRecordingsRoot: provisionalRecordingsRoot,
                    didActivateAudioSession: didActivateAudioSession
                )
                return CaptureStartResult(ok: false, message: text)
            }

            let recordingsRoot = try recordingsRootProvider()
            let id = UUID().uuidString
            let started = Date()
            provisionalRecordingsRoot = recordingsRoot
            provisionalSessionDirectory = store.sessionDirectory(startedAt: started, sessionId: id, recordingsRoot: recordingsRoot)
            cleanupSessionDirectory = provisionalSessionDirectory
            guard isCurrentSessionToken(sessionToken) else {
                await handleStartFailure(
                    sessionToken: sessionToken,
                    provisionalSessionDirectory: provisionalSessionDirectory,
                    cleanupSessionDirectory: cleanupSessionDirectory,
                    provisionalRecordingsRoot: provisionalRecordingsRoot,
                    didActivateAudioSession: didActivateAudioSession
                )
                return CaptureStartResult(ok: false, message: "会话已切换，开始失败。")
            }
            let directory = try makeSessionDirectoryProvider(started, id, recordingsRoot)
            cleanupSessionDirectory = directory
            let scheduledChunkConfiguration = scheduledChunkConfigurationProvider()

            let newManifest = SessionManifest(
                sessionId: id,
                title: "capture",
                source: .iphone,
                device: deviceIdentifier(),
                startedAt: AIWatchingClock.isoString(started)
            )

            manifest = newManifest
            sessionDirectory = directory
            sessionRecordingsRoot = recordingsRoot
            sessionStartedAt = started
            currentChunkIndex = 0
            if scheduledChunkModeEnabled() {
                scheduledChunkFailureDetail = nil
                scheduledChunkShouldDiscardSession = false
                scheduledChunkCompletionTask?.cancel()
                scheduledChunkCompletionTask = nil
                scheduledChunkFinalizationQueue = ScheduledChunkFinalizationQueue()
                scheduledChunkRecorder = nil
                let coordinator = try scheduledChunkRecorderProvider(
                    directory,
                    scheduledChunkConfiguration,
                    { [weak self] event, token in
                        self?.handleScheduledEvent(event, sessionToken: token)
                    },
                    sessionToken
                )
                scheduledChunkRecorder = coordinator
                _ = try await coordinator.start()
            } else {
                try startNextChunk(sessionToken: sessionToken)
            }
            try persistActiveSession()
            guard isCurrentSessionToken(sessionToken) else {
                let text = "会话已切换，开始失败。"
                message = text
                await handleStartFailure(
                    sessionToken: sessionToken,
                    provisionalSessionDirectory: provisionalSessionDirectory,
                    cleanupSessionDirectory: cleanupSessionDirectory,
                    provisionalRecordingsRoot: provisionalRecordingsRoot,
                    didActivateAudioSession: didActivateAudioSession
                )
                return CaptureStartResult(ok: false, message: text)
            }
            lifecycle = .recording
            interruptionFlow.markRecording()
            if scheduledChunkModeEnabled() {
                guard let scheduledChunkRecorder, scheduledChunkRecorder.isCapturing else {
                    await handleStartFailure(
                        sessionToken: sessionToken,
                        provisionalSessionDirectory: provisionalSessionDirectory,
                        cleanupSessionDirectory: cleanupSessionDirectory,
                        provisionalRecordingsRoot: provisionalRecordingsRoot,
                        didActivateAudioSession: didActivateAudioSession
                    )
                    return CaptureStartResult(ok: false, message: "开始失败：Scheduled chunk recorder did not start.")
                }
            }

            // Only now is recording truly live.
            isRecording = true
            let text = "捕捉已开始。"
            guard isCurrentSessionToken(sessionToken) else {
                let text = "会话已切换，开始取消。"
                message = text
                await handleStartFailure(
                    sessionToken: sessionToken,
                    provisionalSessionDirectory: provisionalSessionDirectory,
                    cleanupSessionDirectory: cleanupSessionDirectory,
                    provisionalRecordingsRoot: provisionalRecordingsRoot,
                    didActivateAudioSession: didActivateAudioSession
                )
                return CaptureStartResult(ok: false, message: text)
            }
            message = text
            startElapsedTimer()
            publishCaptureState(
                isCapturing: true,
                statusText: text,
                sessionId: manifest?.sessionId,
                sessionToken: sessionToken
            )
            return CaptureStartResult(ok: true, message: text)
        } catch {
            let text = "开始失败：\(error.localizedDescription)"
            message = text
            await handleStartFailure(
                sessionToken: sessionToken,
                provisionalSessionDirectory: provisionalSessionDirectory,
                cleanupSessionDirectory: cleanupSessionDirectory,
                provisionalRecordingsRoot: provisionalRecordingsRoot,
                didActivateAudioSession: didActivateAudioSession
            )
            return CaptureStartResult(ok: false, message: text)
        }
    }

    func stopCapture() async {
        let sessionToken = activeSessionToken
        guard isRecording || recorder != nil || scheduledChunkRecorder != nil || sessionToken != nil || lifecycle == .interrupted else { return }

        switch lifecycle {
        case .starting:
            lifecycle = .stopping
            await tearDownSession(markComplete: false, token: sessionToken, publishReadyState: false)
        case .recording:
            lifecycle = .stopping
            if scheduledChunkModeEnabled() {
                scheduledChunkRecorder?.stop()
            } else {
                guard recorder != nil else { return }
                recorder?.stop()   // delegate -> finishCurrentChunk -> tearDownSession(markComplete: true)
            }
        case .interrupted:
            if scheduledChunkModeEnabled() {
                lifecycle = .stopping
                if scheduledChunkRecorder == nil {
                    await tearDownSession(markComplete: true, token: sessionToken)
                } else {
                    scheduledChunkRecorder?.stop()
                }
            } else if recorder == nil {
                await tearDownSession(markComplete: true, token: sessionToken)
            } else {
                lifecycle = .stopping
                recorder?.stop()
            }
        case .idle, .stopping:
            return
        }
    }

    func addBookmark(note: String?, source: String) async {
        guard var manifest, let sessionStartedAt, let sessionDirectory else {
            message = "当前没有正在捕捉的会话。"
            return
        }
        let now = Date()
        let atSec = CaptureTimeline.sessionRelativeSeconds(from: sessionStartedAt, to: now)
        manifest.bookmarks.append(
            CaptureBookmark(atSec: atSec, atTime: AIWatchingClock.isoString(now), note: note, source: source)
        )
        self.manifest = manifest
        do {
            try store.writeManifest(manifest, to: sessionDirectory)
            message = "已打标 \(formatDuration(atSec))。"
        } catch {
            message = "打标失败：\(error.localizedDescription)"
        }
    }

    func deleteSession(_ name: String) async {
        guard name != sessionDirectory?.lastPathComponent else {
            message = "正在录制的会话不可删除。"
            return
        }
        do {
            guard let recordingsRoot = recentSessionsRecordingsRoot else {
                message = "删除失败：未绑定历史会话目录。"
                return
            }
            let target = recordingsRoot.appendingPathComponent(name, isDirectory: true)
            try store.deleteSession(at: target, within: recordingsRoot)
            lastWriteError = nil
            message = "已删除会话 \(name)。"
            await refreshRecentSessionsFromBoundRoot()
        } catch {
            message = "删除失败：\(error.localizedDescription)"
            lastWriteError = error.localizedDescription
        }
    }

    // MARK: - Diagnostics

    var storageMode: String {
        store.isUsingICloud() ? "iCloud" : "本地 Documents（未登录 iCloud）"
    }

    var iCloudRootPath: String {
        store.rootPath()
    }

    var currentSessionFolder: String? {
        sessionDirectory?.lastPathComponent
    }

    private static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private static func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        try session.setActive(true)
    }

    private static func deactivateAudioSession() throws {
        try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    private static func resolveFinalizedChunkDurationFromRecorderFile(at chunkURL: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: chunkURL)
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds
        guard seconds.isFinite, seconds >= 0 else {
            throw CaptureError.invalidChunkDuration
        }
        return seconds
    }

    private func resolvedChunkDuration(at chunkURL: URL) async throws -> TimeInterval {
        let duration = try await resolveFinalizedChunkDurationProvider(chunkURL)
        guard duration.isFinite, duration >= 0 else {
            throw CaptureError.invalidChunkDuration
        }
        return duration
    }

    private func handleScheduledEvent(_ event: ScheduledChunkRecorder.Event, sessionToken: UUID) {
        guard isCurrentSessionToken(sessionToken) else { return }
        switch event {
        case let .chunkFinished(chunk, successfully: successfully):
            scheduledChunkFinalizationQueue.enqueue(index: chunk.index) { [weak self] in
                await self?.handleScheduledChunkFinished(
                    chunk: chunk,
                    success: successfully,
                    sessionToken: sessionToken
                )
            }
        case let .failed(detail):
            scheduledChunkFailureDetail = "partial capture: \(detail)"
        case .stopped:
            scheduleScheduledChunkCompletion(sessionToken: sessionToken)
        }
    }

    private func scheduleScheduledChunkCompletion(sessionToken: UUID) {
        guard scheduledChunkCompletionTask == nil else { return }
        let queue = scheduledChunkFinalizationQueue
        scheduledChunkCompletionTask = Task { @MainActor [weak self] in
            await queue.drain()
            guard let self, self.isCurrentSessionToken(sessionToken) else { return }
            if self.lifecycle == .interrupted {
                self.scheduledChunkRecorder = nil
                self.scheduledChunkCompletionTask = nil
                let action = self.interruptionFlow.handle(.currentChunkFinished)
                await self.handleInterruptionFlowAction(
                    action,
                    sessionToken: sessionToken,
                    interruptionGeneration: self.interruptionGeneration
                )
                return
            }
            let hasCompletedChunks = !(self.manifest?.chunks.isEmpty ?? true)
            let markComplete = hasCompletedChunks
            if !hasCompletedChunks {
                self.message = "没有生成有效音频，未创建会话。"
            }
            await self.tearDownSession(
                markComplete: markComplete,
                detail: self.scheduledChunkFailureDetail ?? self.pendingCompletionDetail,
                token: sessionToken
            )
        }
    }

    private func handleScheduledChunkFinished(
        chunk: ScheduledChunkRecorder.Chunk,
        success: Bool,
        sessionToken: UUID
    ) async {
        guard isCurrentSessionToken(sessionToken),
              lifecycle != .idle,
              var manifest,
              let sessionDirectory,
              let sessionStartedAt else {
            return
        }

        let capturedChunkURL = chunk.url
        let chunkIndex = chunk.index

        if manifest.chunks.contains(where: { $0.index == chunkIndex }) {
            return
        }

        guard success, FileManager.default.fileExists(atPath: capturedChunkURL.path) else {
            cleanupCurrentChunkFile(capturedChunkURL)
            scheduledChunkShouldDiscardSession = manifest.chunks.isEmpty
            scheduledChunkFailureDetail = scheduledChunkFailureDetail ?? "partial capture: 当前分片未成功结束"
            scheduledChunkRecorder?.stop()
            return
        }

        do {
            let duration = try await resolvedChunkDuration(at: capturedChunkURL)
            let shouldPreserveChunk = duration > 0.2 || (lifecycle == .stopping && duration > 0)
            guard shouldPreserveChunk else {
                cleanupCurrentChunkFile(capturedChunkURL)
                scheduledChunkShouldDiscardSession = manifest.chunks.isEmpty
                if lifecycle != .stopping {
                    scheduledChunkFailureDetail = scheduledChunkFailureDetail ?? "partial capture: 当前分片持续时间过短"
                    scheduledChunkRecorder?.stop()
                }
                return
            }
            let chunkStartedAt = sessionStartedAt.addingTimeInterval(chunk.startOffsetSec)
            let newChunk = AudioChunk(
                file: store.relativeAudioPath(chunkIndex: chunkIndex),
                index: chunkIndex,
                startOffsetSec: chunk.startOffsetSec,
                durationSec: duration,
                startedAt: AIWatchingClock.isoString(chunkStartedAt)
            )

            if manifest.chunks.last?.index == chunkIndex - 1 {
                manifest.chunks.append(newChunk)
            } else if manifest.chunks.isEmpty && chunkIndex == 0 {
                manifest.chunks.append(newChunk)
            } else {
                scheduledChunkFailureDetail = scheduledChunkFailureDetail ?? "partial capture: 分片索引不连续"
                scheduledChunkRecorder?.stop()
                return
            }

            self.manifest = manifest
            do {
                try store.writeManifest(manifest, to: sessionDirectory)
                try store.writeStatus(SessionStatus(state: .recording), to: sessionDirectory)
            } catch {
                message = "写入分片失败：\(error.localizedDescription)"
                lastWriteError = error.localizedDescription
                scheduledChunkFailureDetail = "partial capture: 写入分片失败 \(error.localizedDescription)"
                scheduledChunkRecorder?.stop()
            }
        } catch {
            message = "解析分片时长失败：\(error.localizedDescription)"
            cleanupCurrentChunkFile(capturedChunkURL)
            scheduledChunkFailureDetail = scheduledChunkFailureDetail ?? "partial capture: 当前分片时长无效"
            scheduledChunkShouldDiscardSession = manifest.chunks.isEmpty
            scheduledChunkRecorder?.stop()
        }
    }

    private func startNextChunk(sessionToken: UUID?) throws {
        guard isCurrentSessionToken(sessionToken) else {
            throw CaptureError.staleSession
        }
        guard let sessionDirectory else { throw CaptureError.noSessionDirectory }
        let provisionalChunkURL = store.audioURL(sessionDirectory: sessionDirectory, chunkIndex: currentChunkIndex)
        currentChunkURL = provisionalChunkURL
        var shouldCleanupChunk = true

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
        ]
        defer {
            if shouldCleanupChunk {
                cleanupCurrentChunkFile(provisionalChunkURL)
                currentChunkURL = nil
            }
        }

        let recorder = try makeRecorderProvider(provisionalChunkURL, settings)
        recorder.delegate = self
        if let avRecorder = recorder as? AVAudioRecorder {
            avRecorder.isMeteringEnabled = false
        }

        guard recorder.prepareToRecord() else {
            throw CaptureError.recorderPreparationFailed
        }
        let chunkStartedAt = Date()
        guard recorder.record(forDuration: AIWatchingSchema.chunkDuration) else {
            throw CaptureError.recorderDidNotStart
        }
        guard recorder.isRecording else {
            throw CaptureError.recorderDidNotStart
        }

        self.recorder = recorder
        recorderGate.arm(recorder)
        currentChunkURL = provisionalChunkURL
        currentChunkStartedAt = chunkStartedAt
        interruptionFlow.markRecording()
        shouldCleanupChunk = false
    }

    private func finishCurrentChunk(success: Bool, recorder finishedRecorder: CaptureRecording, sessionToken: UUID) async {
        guard isCurrentSessionToken(sessionToken),
              lifecycle != .idle,
              self.recorder === finishedRecorder,
              let currentChunkStartedAt,
              var manifest,
              let sessionDirectory,
              let sessionStartedAt else {
            return
        }

        let capturedChunkURL = currentChunkURL ?? finishedRecorder.url
        let chunkIndex = currentChunkIndex
        let hasCompletedChunks = !manifest.chunks.isEmpty
        self.recorder = nil
        self.currentChunkURL = nil
        self.currentChunkStartedAt = nil
        _ = recorderGate.clearIfCurrent(finishedRecorder)

        if success, FileManager.default.fileExists(atPath: capturedChunkURL.path) {
            do {
                let duration = try await resolvedChunkDuration(at: capturedChunkURL)
                let shouldPreserveChunk = duration > 0.2
                if shouldPreserveChunk {
                    let startOffset = CaptureTimeline.sessionRelativeSeconds(from: sessionStartedAt, to: currentChunkStartedAt)
                    let chunk = AudioChunk(
                        file: store.relativeAudioPath(chunkIndex: chunkIndex),
                        index: chunkIndex,
                        startOffsetSec: startOffset,
                        durationSec: duration,
                        startedAt: AIWatchingClock.isoString(currentChunkStartedAt)
                    )
                    manifest.chunks.append(chunk)
                    self.manifest = manifest
                    currentChunkIndex = chunkIndex + 1
                    do {
                        try store.writeManifest(manifest, to: sessionDirectory)
                        try store.writeStatus(SessionStatus(state: .recording), to: sessionDirectory)
                    } catch {
                        message = "写入分片失败：\(error.localizedDescription)"
                        lastWriteError = error.localizedDescription
                        await tearDownSession(markComplete: true, detail: "partial capture: 写入分片失败 \(error.localizedDescription)", token: sessionToken)
                        return
                    }

                    if lifecycle == .stopping {
                        await tearDownSession(
                            markComplete: true,
                            detail: scheduledChunkFailureDetail ?? pendingCompletionDetail,
                            token: sessionToken
                        )
                        return
                    }

                    if lifecycle == .interrupted {
                        let action = interruptionFlow.handle(.currentChunkFinished)
                        await handleInterruptionFlowAction(action, sessionToken: sessionToken, interruptionGeneration: interruptionGeneration)
                        return
                    }

                    do {
                        try startNextChunk(sessionToken: sessionToken)
                    } catch {
                        message = "续录失败：\(error.localizedDescription)"
                        await tearDownSession(markComplete: true, detail: "partial capture: 续录失败 \(error.localizedDescription)", token: sessionToken)
                    }
                    return
                }

                cleanupCurrentChunkFile(capturedChunkURL)
                if lifecycle != .stopping {
                    scheduledChunkFailureDetail = scheduledChunkFailureDetail ?? "partial capture: 当前分片持续时间过短"
                    scheduledChunkRecorder?.stop()
                    return
                }
                if hasCompletedChunks {
                    await tearDownSession(
                        markComplete: true,
                        detail: scheduledChunkFailureDetail ?? pendingCompletionDetail,
                        token: sessionToken
                    )
                } else {
                    await tearDownSession(markComplete: false, token: sessionToken)
                }
                return
            } catch {
                message = "解析分片时长失败：\(error.localizedDescription)"
            }
        }

        cleanupCurrentChunkFile(capturedChunkURL)
        if lifecycle == .interrupted {
            let action = interruptionFlow.handle(.currentChunkFinished)
            await handleInterruptionFlowAction(action, sessionToken: sessionToken, interruptionGeneration: interruptionGeneration)
            return
        }

        let completionDetail = scheduledChunkFailureDetail ?? pendingCompletionDetail ?? "partial capture: 当前分片未成功结束"
        if hasCompletedChunks {
            await tearDownSession(markComplete: true, detail: completionDetail, token: sessionToken)
        } else {
            await tearDownSession(markComplete: false, token: sessionToken)
        }
    }

    private func handleInterruptionFlowAction(
        _ action: CaptureInterruptionFlow.Action,
        sessionToken: UUID?,
        interruptionGeneration: Int,
        recorderIdentity: ObjectIdentifier? = nil
    ) async {
        guard isCurrentSessionToken(sessionToken) else { return }
        guard interruptionGeneration == self.interruptionGeneration else { return }
        switch action {
        case .none:
            return
        case .stopCurrentRecorder:
            guard lifecycle == .recording || lifecycle == .interrupted else { return }
            if scheduledChunkModeEnabled() {
                scheduledChunkRecorder?.stop()
                return
            }
            if let recorderIdentity, let recorder {
                guard ObjectIdentifier(recorder as AnyObject) == recorderIdentity else { return }
            }
            recorder?.stop()
        case .startNextRecorder:
            guard lifecycle == .interrupted else { return }
            do {
                try configureAudioSessionProvider()
                if scheduledChunkModeEnabled() {
                    guard let sessionToken,
                          let sessionDirectory,
                          let sessionStartedAt else {
                        throw CaptureError.noSessionDirectory
                    }
                    let baseConfiguration = scheduledChunkConfigurationProvider()
                    let nextChunkIndex = (manifest?.chunks.last?.index ?? -1) + 1
                    let resumeOffset = CaptureTimeline.sessionRelativeSeconds(
                        from: sessionStartedAt,
                        to: Date()
                    )
                    let resumeConfiguration = ScheduledChunkRecorder.Configuration(
                        chunkDuration: baseConfiguration.chunkDuration,
                        overlapDuration: baseConfiguration.overlapDuration,
                        initialLeadTime: baseConfiguration.initialLeadTime,
                        startingChunkIndex: nextChunkIndex,
                        startingStartOffsetSec: resumeOffset
                    )
                    scheduledChunkFailureDetail = nil
                    scheduledChunkShouldDiscardSession = false
                    scheduledChunkFinalizationQueue = ScheduledChunkFinalizationQueue()
                    scheduledChunkCompletionTask = nil
                    let coordinator = try scheduledChunkRecorderProvider(
                        sessionDirectory,
                        resumeConfiguration,
                        { [weak self] event, token in
                            self?.handleScheduledEvent(event, sessionToken: token)
                        },
                        sessionToken
                    )
                    scheduledChunkRecorder = coordinator
                    _ = try await coordinator.start()
                    guard coordinator.isCapturing else {
                        throw CaptureError.recorderDidNotStart
                    }
                } else {
                    try startNextChunk(sessionToken: sessionToken)
                }
                lifecycle = .recording
                pendingCompletionDetail = nil
                message = "音频中断已恢复，新分片继续捕捉。"
            } catch {
                message = "中断恢复失败：\(error.localizedDescription)"
                await tearDownSession(markComplete: true, detail: "partial capture: 中断恢复失败 \(error.localizedDescription)", token: sessionToken)
            }
        case .completeSession:
            guard lifecycle == .interrupted else { return }
            await tearDownSession(
                markComplete: true,
                detail: pendingCompletionDetail ?? "partial capture: interruption ended without shouldResume",
                token: sessionToken
            )
        }
    }

    private func publishCaptureState(
        isCapturing: Bool,
        statusText: String? = nil,
        sessionId: String? = nil,
        sessionToken: UUID? = nil
    ) {
        guard isCurrentSessionToken(sessionToken) else {
            return
        }
        let text = statusText ?? (isCapturing ? "正在捕捉" : "等待 iPhone")
        publishCaptureStateProvider(isCapturing, text, sessionId)
    }

    private func persistActiveSession() throws {
        guard let manifest, let sessionDirectory else { throw CaptureError.noSessionDirectory }
        try persistActiveSessionProvider(manifest, sessionDirectory)
    }

    private func cleanupCurrentChunkFile(_ chunkURL: URL?) {
        guard let chunkURL else { return }
        do {
            if !FileManager.default.fileExists(atPath: chunkURL.path) {
                return
            }
            try FileManager.default.removeItem(at: chunkURL)
        } catch {
            lastWriteError = error.localizedDescription
            message = "清理分片失败：\(error.localizedDescription)"
        }
    }

    private func isCurrentSessionToken(_ sessionToken: UUID?) -> Bool {
        guard let sessionToken, let activeSessionToken = self.activeSessionToken else { return false }
        return activeSessionToken == sessionToken
    }

    private func ownsActiveAudioSession(for sessionToken: UUID, didActivateAudioSession: Bool) -> Bool {
        guard didActivateAudioSession else { return false }
        return activeSessionToken == nil || activeSessionToken == sessionToken
    }

    private func handleStartFailure(
        sessionToken: UUID,
        provisionalSessionDirectory: URL?,
        cleanupSessionDirectory: URL?,
        provisionalRecordingsRoot: URL?,
        didActivateAudioSession: Bool
    ) async {
        if isCurrentSessionToken(sessionToken) {
            await rollbackCurrentSessionStartFailure(
                sessionToken: sessionToken,
                provisionalSessionDirectory: provisionalSessionDirectory,
                cleanupSessionDirectory: cleanupSessionDirectory,
                provisionalRecordingsRoot: provisionalRecordingsRoot,
                didActivateAudioSession: didActivateAudioSession
            )
            return
        }
        await rollbackFailedStart(
            sessionToken: sessionToken,
            provisionalSessionDirectory: provisionalSessionDirectory,
            cleanupSessionDirectory: cleanupSessionDirectory,
            provisionalRecordingsRoot: provisionalRecordingsRoot,
            didActivateAudioSession: didActivateAudioSession
        )
    }

    private func rollbackCurrentSessionStartFailure(
        sessionToken: UUID,
        provisionalSessionDirectory: URL?,
        cleanupSessionDirectory: URL?,
        provisionalRecordingsRoot: URL?,
        didActivateAudioSession: Bool
    ) async {
        if let currentRecorder = recorder {
            currentRecorder.delegate = nil
            currentRecorder.stop()
            recorder = nil
        }
        if let scheduledRecorder = scheduledChunkRecorder {
            scheduledRecorder.stop()
            scheduledChunkRecorder = nil
        }
        scheduledChunkCompletionTask?.cancel()
        scheduledChunkCompletionTask = nil
        scheduledChunkFinalizationQueue.reset()
        scheduledChunkFailureDetail = nil
        scheduledChunkShouldDiscardSession = false
        recorderGate.clear()
        timer?.invalidate()
        timer = nil
        isRecording = false
        if ownsActiveAudioSession(for: sessionToken, didActivateAudioSession: didActivateAudioSession) {
            do {
                try deactivateAudioSessionProvider()
            } catch {
                lastWriteError = error.localizedDescription
                message = "释放音频会话失败：\(error.localizedDescription)"
            }
        }
        await cleanupFailedSessionDirectory(sessionDirectory: cleanupSessionDirectory ?? provisionalSessionDirectory, recordingsRoot: provisionalRecordingsRoot)
        manifest = nil
        sessionDirectory = nil
        sessionRecordingsRoot = nil
        sessionStartedAt = nil
        currentChunkStartedAt = nil
        currentChunkURL = nil
        currentChunkIndex = 0
        activeSessionToken = nil
        lifecycle = .idle
    }

    private func rollbackFailedStart(
        sessionToken: UUID,
        provisionalSessionDirectory: URL?,
        cleanupSessionDirectory: URL?,
        provisionalRecordingsRoot: URL?,
        didActivateAudioSession: Bool
    ) async {
        if let scheduledRecorder = scheduledChunkRecorder {
            scheduledRecorder.stop()
            scheduledChunkRecorder = nil
        }
        scheduledChunkCompletionTask?.cancel()
        scheduledChunkCompletionTask = nil
        scheduledChunkFinalizationQueue.reset()
        if ownsActiveAudioSession(for: sessionToken, didActivateAudioSession: didActivateAudioSession) {
            do {
                try deactivateAudioSessionProvider()
            } catch {
                lastWriteError = error.localizedDescription
                message = "释放音频会话失败：\(error.localizedDescription)"
            }
        }
        await cleanupFailedSessionDirectory(sessionDirectory: cleanupSessionDirectory ?? provisionalSessionDirectory, recordingsRoot: provisionalRecordingsRoot)
    }

    private func cleanupFailedSessionDirectory(sessionDirectory: URL?, recordingsRoot: URL?) async {
        guard let sessionDirectory else { return }
        guard let recordingsRoot else {
            lastWriteError = "会话根目录缺失"
            message = "会话清理失败：会话根目录缺失。"
            return
        }
        guard FileManager.default.fileExists(atPath: sessionDirectory.path) else { return }
        do {
            try store.deleteSession(at: sessionDirectory, within: recordingsRoot)
        } catch {
            lastWriteError = error.localizedDescription
            message = "清理会话失败：\(error.localizedDescription)"
        }
    }

    private func tearDownSession(markComplete: Bool, detail: String? = nil, token: UUID?, publishReadyState: Bool = true) async {
        guard isCurrentSessionToken(token) else { return }
        timer?.invalidate()
        timer = nil
        let sessionDirectory = self.sessionDirectory
        let sessionRoot = self.sessionRecordingsRoot
        let publishSessionToken = token
        let captureSessionId = manifest?.sessionId
        let currentChunkURL = self.currentChunkURL
        let currentRecorder = self.recorder
        let scheduledChunkRecorder = self.scheduledChunkRecorder
        let completionDetail = detail ?? pendingCompletionDetail
        self.recorderGate.clear()
        self.currentChunkURL = nil
        lifecycle = .idle

        if let currentRecorder {
            currentRecorder.delegate = nil
            currentRecorder.stop()
        }
        self.recorder = nil

        if let scheduledChunkRecorder {
            scheduledChunkRecorder.stop()
        }
        self.scheduledChunkRecorder = nil
        scheduledChunkFailureDetail = nil
        scheduledChunkShouldDiscardSession = false
        scheduledChunkCompletionTask = nil
        scheduledChunkFinalizationQueue.reset()

        do {
            try deactivateAudioSessionProvider()
        } catch {
            message = "释放音频会话失败：\(error.localizedDescription)"
            lastWriteError = error.localizedDescription
        }

        if !markComplete {
            cleanupCurrentChunkFile(currentChunkURL)
            if let sessionDirectory {
                if let sessionRoot {
                    if FileManager.default.fileExists(atPath: sessionDirectory.path) {
                        do {
                            try store.deleteSession(at: sessionDirectory, within: sessionRoot)
                        } catch {
                            lastWriteError = error.localizedDescription
                            message = "清理会话失败：\(error.localizedDescription)"
                        }
                    }
                } else {
                    lastWriteError = "会话根目录缺失"
                    message = "会话根目录缺失，无法清理会话。"
                }
                if message == nil {
                    message = "捕捉已取消。"
                }
            }
        }

        if markComplete, var manifest, let sessionDirectory {
            manifest.endedAt = AIWatchingClock.isoString()
            self.manifest = manifest
            do {
                try store.writeManifest(manifest, to: sessionDirectory)
                try store.writeStatus(SessionStatus(state: .complete, detail: completionDetail), to: sessionDirectory)
                enqueueCompletedSessionProvider(sessionDirectory)
                message = completionDetail == nil ? "捕捉已完成，等待 Mac companion 转写。" : "捕捉已结束（部分成功），等待 Mac companion 转写。"
            } catch {
                message = "完成会话失败：\(error.localizedDescription)"
                lastWriteError = error.localizedDescription
            }
        } else if markComplete {
            lastWriteError = "会话目录缺失"
            message = "完成会话失败：会话目录缺失"
        }

        isRecording = false
        elapsedText = "00:00:00"

        if publishReadyState {
            publishCaptureState(isCapturing: false, sessionId: captureSessionId, sessionToken: publishSessionToken)
        }
        activeSessionToken = nil

        self.manifest = nil
        self.sessionDirectory = nil
        sessionStartedAt = nil
        currentChunkStartedAt = nil
        self.currentChunkURL = nil
        sessionRecordingsRoot = nil
        pendingCompletionDetail = nil
        lifecycle = .idle
        await refreshRecentSessionsFromBoundRoot()
    }

    private func startElapsedTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.sessionStartedAt else { return }
                self.elapsedText = self.formatDuration(Date().timeIntervalSince(start))
            }
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        let h = value / 3600
        let m = (value % 3600) / 60
        let s = value % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            guard isActiveSession, lifecycle == .recording else { return }
            let sessionToken = activeSessionToken
            interruptionGeneration += 1
            let currentGeneration = interruptionGeneration
            if scheduledChunkModeEnabled() {
                lifecycle = .interrupted
                pendingCompletionDetail = nil
                message = "音频中断，已暂停当前分片。"
                let action = interruptionFlow.handle(.interruptionBegan)
                if action == .stopCurrentRecorder {
                    interruptionActionScheduler? { [sessionToken, currentGeneration] in
                        await self.handleInterruptionFlowAction(
                            action,
                            sessionToken: sessionToken,
                            interruptionGeneration: currentGeneration
                        )
                    }
                }
                return
            }

            let recorderIdentity = recorder.map { ObjectIdentifier($0 as AnyObject) }
            lifecycle = .interrupted
            pendingCompletionDetail = nil
            message = "音频中断，已暂停当前分片。"
            let action = interruptionFlow.handle(.interruptionBegan)
            if action == .stopCurrentRecorder {
                interruptionActionScheduler? { [sessionToken, currentGeneration, recorderIdentity] in
                    await self.handleInterruptionFlowAction(
                        action,
                        sessionToken: sessionToken,
                        interruptionGeneration: currentGeneration,
                        recorderIdentity: recorderIdentity
                    )
                }
            }
        case .ended:
            guard lifecycle == .interrupted, isActiveSession else { return }
            let sessionToken = activeSessionToken
            let currentGeneration = interruptionGeneration
            let userInfo = notification.userInfo ?? [:]
            let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if !options.contains(.shouldResume) {
                message = "音频中断结束，系统未允许自动恢复。"
                pendingCompletionDetail = "partial capture: interruption ended without shouldResume"
            } else {
                pendingCompletionDetail = nil
            }
            let action = interruptionFlow.handle(.interruptionEnded(shouldResume: options.contains(.shouldResume)))
            interruptionActionScheduler? { [sessionToken, currentGeneration] in
                await self.handleInterruptionFlowAction(
                    action,
                    sessionToken: sessionToken,
                    interruptionGeneration: currentGeneration
                )
            }
        @unknown default:
            break
        }
    }

    private func resolveRecorderFinish(_ recorder: CaptureRecording, successfully flag: Bool, sessionToken: UUID) async {
        guard !scheduledChunkModeEnabled() else { return }
        guard isCurrentSessionToken(sessionToken) else { return }
        guard recorderGate.accepts(recorder) else { return }
        await finishCurrentChunk(success: flag, recorder: recorder, sessionToken: sessionToken)
    }

    private func deviceIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }
}

extension CaptureController: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            guard let token = self.activeSessionToken else { return }
            await resolveRecorderFinish(recorder, successfully: flag, sessionToken: token)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            guard !self.scheduledChunkModeEnabled() else { return }
            guard let sessionToken = self.activeSessionToken else { return }
            guard recorderGate.accepts(recorder), self.isCurrentSessionToken(sessionToken) else { return }
            let failureChunkURL = recorder.url
            message = "录音编码失败：\(error?.localizedDescription ?? "unknown")"
            cleanupCurrentChunkFile(failureChunkURL)
            if self.currentChunkURL == failureChunkURL {
                self.currentChunkURL = nil
            }
            if manifest?.chunks.isEmpty == true {
                await tearDownSession(markComplete: false, token: sessionToken)
            } else {
                await tearDownSession(markComplete: true, detail: "partial capture: 编码失败 \(error?.localizedDescription ?? "unknown")", token: sessionToken)
            }
        }
    }

    func configureSessionExport(
        recordingsRootProvider: @escaping () throws -> URL,
        enqueueCompletedSession: @escaping @Sendable (URL) -> Void
    ) {
        self.recordingsRootProvider = recordingsRootProvider
        self.enqueueCompletedSessionProvider = enqueueCompletedSession
    }
}

    #if DEBUG
    extension CaptureController {
    struct TestDependencies {
        var requestPermission: (() async -> Bool)?
        var configureSession: (() throws -> Void)?
        var deactivateSession: (() throws -> Void)?
        var recordingsRoot: (() throws -> URL)?
        var createSessionDirectory: ((Date, String, URL) throws -> URL)?
        var createRecorder: ((URL, [String: Any]) throws -> CaptureRecording)?
        var resolveFinalizedChunkDuration: ((URL) async throws -> TimeInterval)?
        var scheduledChunkConfiguration: (() -> ScheduledChunkRecorder.Configuration)?
        var persistActiveSession: ((SessionManifest, URL) throws -> Void)?
        var scheduleInterruptionAction: (@MainActor (@escaping () async -> Void) -> Void)?
        var useScheduledChunkPrototype: Bool?
        var scheduledChunkRecorder: ((
            URL,
            ScheduledChunkRecorder.Configuration,
            @escaping @MainActor (ScheduledChunkRecorder.Event, UUID) -> Void,
            UUID
        ) throws -> ScheduledChunkRecorderLike)?
        var publishCaptureState: ((Bool, String, String?) -> Void)?
        var enqueueCompletedSession: ((URL) -> Void)?
    }

    func installTestDependencies(_ dependencies: TestDependencies) {
        if let requestPermission = dependencies.requestPermission {
            requestPermissionProvider = requestPermission
        }
        if let configureSession = dependencies.configureSession {
            configureAudioSessionProvider = configureSession
        }
        if let deactivateSession = dependencies.deactivateSession {
            deactivateAudioSessionProvider = deactivateSession
        }
        if let recordingsRoot = dependencies.recordingsRoot {
            recordingsRootProvider = recordingsRoot
        }
        if let createSessionDirectory = dependencies.createSessionDirectory {
            makeSessionDirectoryProvider = createSessionDirectory
        }
        if let createRecorder = dependencies.createRecorder {
            makeRecorderProvider = createRecorder
        }
        if let resolveFinalizedChunkDuration = dependencies.resolveFinalizedChunkDuration {
            resolveFinalizedChunkDurationProvider = resolveFinalizedChunkDuration
        }
        if let persistActiveSession = dependencies.persistActiveSession {
            persistActiveSessionProvider = persistActiveSession
        }
        if let scheduleInterruptionAction = dependencies.scheduleInterruptionAction {
            interruptionActionScheduler = scheduleInterruptionAction
        }
        if let scheduledChunkConfiguration = dependencies.scheduledChunkConfiguration {
            scheduledChunkConfigurationProvider = scheduledChunkConfiguration
        }
        if let scheduledChunkRecorder = dependencies.scheduledChunkRecorder {
            scheduledChunkRecorderProvider = scheduledChunkRecorder
        }
        if let useScheduledChunkPrototype = dependencies.useScheduledChunkPrototype {
            scheduledChunkModeEnabled = { useScheduledChunkPrototype }
        } else if dependencies.scheduledChunkRecorder != nil || dependencies.scheduledChunkConfiguration != nil {
            scheduledChunkModeEnabled = { true }
        } else {
            scheduledChunkModeEnabled = { false }
        }
        if let publishCaptureState = dependencies.publishCaptureState {
            publishCaptureStateProvider = publishCaptureState
        }
        if let enqueueCompletedSession = dependencies.enqueueCompletedSession {
            enqueueCompletedSessionProvider = enqueueCompletedSession
        }
    }

    var debugLifecycle: String { String(describing: lifecycle) }
    var debugSessionToken: UUID? { activeSessionToken }
    var debugSessionDirectory: URL? { sessionDirectory }
    var debugSessionRoot: URL? { sessionRecordingsRoot }
    var debugRecentSessionsRoot: URL? { recentSessionsRecordingsRoot }
    var debugRecentSessions: [String] { recentSessions }
    var debugCurrentChunkURL: URL? { currentChunkURL }
    var debugRecorder: CaptureRecording? { recorder }
    var debugScheduledRecorder: ScheduledChunkRecorderLike? { scheduledChunkRecorder }
    var debugScheduledChunkModeEnabled: Bool { scheduledChunkModeEnabled() }
    var debugInterruptionGeneration: Int { interruptionGeneration }
    var debugRecorderObjectID: ObjectIdentifier? { recorder.map { ObjectIdentifier($0 as AnyObject) } }
    func debugSetPendingCompletionDetail(_ detail: String?) { pendingCompletionDetail = detail }

    func debugHandleInterruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool = false) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if type == .ended {
            info[AVAudioSessionInterruptionOptionKey] = shouldResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : 0
        }
        let notification = Notification(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), userInfo: info)
        handleInterruption(notification)
    }

    func debugResolveRecorderFinish(_ recorder: CaptureRecording, success: Bool, token: UUID) async {
        await resolveRecorderFinish(recorder, successfully: success, sessionToken: token)
    }

    func debugHandleInterruptionFlowAction(
        _ action: CaptureInterruptionFlow.Action,
        token: UUID?,
        interruptionGeneration: Int? = nil,
        recorder: CaptureRecording? = nil
    ) async {
        let expectedGeneration = interruptionGeneration ?? self.interruptionGeneration
        let expectedRecorder = recorder.map { ObjectIdentifier($0 as AnyObject) }
        await handleInterruptionFlowAction(
            action,
            sessionToken: token,
            interruptionGeneration: expectedGeneration,
            recorderIdentity: expectedRecorder
        )
    }

    func debugHandleScheduledChunkEvent(_ event: ScheduledChunkRecorder.Event, token: UUID) async {
        handleScheduledEvent(event, sessionToken: token)
        if case .stopped = event {
            await scheduledChunkCompletionTask?.value
        } else {
            await Task.yield()
        }
    }

    func debugTearDown(markComplete: Bool, detail: String? = nil, token: UUID?) async {
        await tearDownSession(markComplete: markComplete, detail: detail, token: token)
    }
}
#endif

struct CaptureStartResult: Sendable {
    let ok: Bool
    let message: String
}

enum CaptureError: LocalizedError {
    case noSessionDirectory
    case recorderPreparationFailed
    case recorderDidNotStart
    case staleSession
    case invalidChunkDuration

    var errorDescription: String? {
        switch self {
        case .noSessionDirectory:
            "Missing session directory."
        case .recorderPreparationFailed:
            "Recorder preparation failed."
        case .recorderDidNotStart:
            "Recorder did not start."
        case .staleSession:
            "Session stale."
        case .invalidChunkDuration:
            "Invalid chunk duration."
        }
    }
}
