import AVFoundation
import Foundation

protocol ScheduledCaptureRecording: AnyObject {
    var delegate: AVAudioRecorderDelegate? { get set }
    var isRecording: Bool { get }
    var url: URL { get }
    var deviceCurrentTime: TimeInterval { get }

    func prepareToRecord() -> Bool
    func record(atTime time: TimeInterval, forDuration duration: TimeInterval) -> Bool
    func stop()
}

extension AVAudioRecorder: ScheduledCaptureRecording {}

protocol ScheduledCaptureRecorderFactory {
    func makeRecorder(url: URL, settings: [String: Any]) throws -> ScheduledCaptureRecording
}

struct DefaultScheduledCaptureRecorderFactory: ScheduledCaptureRecorderFactory {
    func makeRecorder(url: URL, settings: [String: Any]) throws -> ScheduledCaptureRecording {
        try AVAudioRecorder(url: url, settings: settings)
    }
}

@MainActor
final class ScheduledChunkRecorder: NSObject {
    struct Configuration: Sendable, Equatable {
        static let maximumOverlapDuration: TimeInterval = 0.5

        let chunkDuration: TimeInterval
        let overlapDuration: TimeInterval
        let initialLeadTime: TimeInterval
        let startingChunkIndex: Int
        let startingStartOffsetSec: TimeInterval

        init(
            chunkDuration: TimeInterval,
            overlapDuration: TimeInterval = 0.25,
            initialLeadTime: TimeInterval = 0.1,
            startingChunkIndex: Int = 0,
            startingStartOffsetSec: TimeInterval = 0
        ) {
            self.chunkDuration = chunkDuration
            self.overlapDuration = overlapDuration
            self.initialLeadTime = initialLeadTime
            self.startingChunkIndex = startingChunkIndex
            self.startingStartOffsetSec = startingStartOffsetSec
        }

        var stride: TimeInterval {
            chunkDuration - overlapDuration
        }

        func validate() throws {
            guard chunkDuration > 0,
                  overlapDuration >= 0,
                  overlapDuration <= Self.maximumOverlapDuration,
                  overlapDuration < chunkDuration,
                  initialLeadTime >= 0,
                  startingChunkIndex >= 0,
                  startingStartOffsetSec >= 0 else {
                throw ScheduledChunkRecorderError.invalidConfiguration
            }
        }
    }

    struct Chunk: Sendable, Equatable {
        let index: Int
        let url: URL
        let scheduledDeviceTime: TimeInterval
        let startOffsetSec: TimeInterval
    }

    enum Event: Sendable, Equatable {
        case chunkFinished(Chunk, successfully: Bool)
        case stopped
        case failed(String)
    }

    typealias EventHandler = @MainActor (Event) -> Void
    typealias URLProvider = @MainActor (Int) throws -> URL
    typealias VerificationSleeper = @MainActor (TimeInterval) async throws -> Void

    private struct Slot {
        let recorder: ScheduledCaptureRecording
        let chunk: Chunk
    }

    private let configuration: Configuration
    private let settings: [String: Any]
    private let recorderFactory: ScheduledCaptureRecorderFactory
    private let urlProvider: URLProvider
    private let verificationSleeper: VerificationSleeper
    private let eventHandler: EventHandler

    private var anchorDeviceTime: TimeInterval?
    private var activeSlot: Slot?
    private var scheduledSlot: Slot?
    private var finalizingSlots: [ObjectIdentifier: Slot] = [:]
    private var pendingFinishedChunks: [Int: (chunk: Chunk, successfully: Bool)] = [:]
    private var nextFinishedChunkIndex = 0
    private var isStopping = false
    private var hasStopped = false

    private static let firstRecorderActivationGracePoll: TimeInterval = 0.05
    private static let firstRecorderActivationGracePollCount = 20

    init(
        configuration: Configuration,
        settings: [String: Any],
        recorderFactory: ScheduledCaptureRecorderFactory = DefaultScheduledCaptureRecorderFactory(),
        urlProvider: @escaping URLProvider,
        verificationSleeper: @escaping VerificationSleeper = { delay in
            guard delay > 0 else { return }
            try await Task.sleep(for: .seconds(delay))
        },
        eventHandler: @escaping EventHandler
    ) {
        self.configuration = configuration
        self.settings = settings
        self.recorderFactory = recorderFactory
        self.urlProvider = urlProvider
        self.verificationSleeper = verificationSleeper
        self.eventHandler = eventHandler
        super.init()
    }

    var isCapturing: Bool {
        (activeSlot?.recorder.isRecording == true ||
            isScheduledSlotActivelyRecording(scheduledSlot))
            && !isStopping
            && !hasStopped
    }

    var activeChunk: Chunk? {
        activeSlot?.chunk
    }

    var scheduledChunk: Chunk? {
        scheduledSlot?.chunk
    }

    @discardableResult
    func start() async throws -> Chunk {
        try configuration.validate()
        guard activeSlot == nil, scheduledSlot == nil, !isStopping, !hasStopped else {
            throw ScheduledChunkRecorderError.alreadyStarted
        }

        do {
            finalizingSlots.removeAll()
            pendingFinishedChunks.removeAll()
            nextFinishedChunkIndex = configuration.startingChunkIndex
            let firstIndex = configuration.startingChunkIndex
            let firstRecorder = try makePreparedRecorder(index: firstIndex)
            let anchor = firstRecorder.deviceCurrentTime + configuration.initialLeadTime
            anchorDeviceTime = anchor

            let firstSlot = try schedule(firstRecorder, index: firstIndex, at: anchor)
            activeSlot = firstSlot

            let secondIndex = firstIndex + 1
            let secondRecorder = try makePreparedRecorder(index: secondIndex)
            scheduledSlot = try schedule(
                secondRecorder,
                index: secondIndex,
                at: scheduledDeviceTime(for: secondIndex, anchor: anchor)
            )

            try await verificationSleeper(configuration.initialLeadTime + 0.05)
            if !firstSlot.recorder.isRecording {
                for _ in 0..<Self.firstRecorderActivationGracePollCount {
                    try await verificationSleeper(Self.firstRecorderActivationGracePoll)
                    if firstSlot.recorder.isRecording {
                        return firstSlot.chunk
                    }
                }
                throw ScheduledChunkRecorderError.firstRecorderDidNotStart
            }
            return firstSlot.chunk
        } catch {
            cancelAllRecorders(removeFiles: true)
            anchorDeviceTime = nil
            throw error
        }
    }

    func stop() {
        guard !isStopping, !hasStopped else { return }
        isStopping = true

        if let scheduledSlot, hasScheduledTimeArrived(scheduledSlot) {
            if let activeSlot {
                finalizingSlots[ObjectIdentifier(activeSlot.recorder)] = activeSlot
            }
            self.activeSlot = scheduledSlot
            self.scheduledSlot = nil
            finalizingSlots.values.forEach { $0.recorder.stop() }
            scheduledSlot.recorder.stop()
            return
        }

        cancelScheduledRecorder(removeFile: true)

        guard let activeSlot else {
            emitStoppedIfQuiescent()
            return
        }
        activeSlot.recorder.stop()
    }

    private func makePreparedRecorder(index: Int) throws -> ScheduledCaptureRecording {
        let url = try urlProvider(index)
        let recorder = try recorderFactory.makeRecorder(url: url, settings: settings)
        recorder.delegate = self
        guard recorder.prepareToRecord() else {
            recorder.delegate = nil
            recorder.stop()
            removeFileIfPresent(url)
            throw ScheduledChunkRecorderError.recorderPreparationFailed(index: index)
        }
        return recorder
    }

    private func schedule(
        _ recorder: ScheduledCaptureRecording,
        index: Int,
        at deviceTime: TimeInterval
    ) throws -> Slot {
        guard recorder.record(atTime: deviceTime, forDuration: configuration.chunkDuration) else {
            recorder.delegate = nil
            recorder.stop()
            removeFileIfPresent(recorder.url)
            throw ScheduledChunkRecorderError.recorderSchedulingFailed(index: index)
        }
        return Slot(
            recorder: recorder,
            chunk: Chunk(
                index: index,
                url: recorder.url,
                scheduledDeviceTime: deviceTime,
                startOffsetSec: configuration.startingStartOffsetSec +
                    TimeInterval(index - configuration.startingChunkIndex) * configuration.stride
            )
        )
    }

    private func scheduledDeviceTime(for index: Int, anchor: TimeInterval) -> TimeInterval {
        anchor + TimeInterval(index - configuration.startingChunkIndex) * configuration.stride
    }

    private func handleRecorderFinished(identity: ObjectIdentifier, successfully: Bool) {
        if let finalizingSlot = finalizingSlots.removeValue(forKey: identity) {
            queueFinishedChunk(finalizingSlot.chunk, successfully: successfully)
            emitStoppedIfQuiescent()
            return
        }

        guard let activeSlot,
              ObjectIdentifier(activeSlot.recorder) == identity else {
            if let scheduledSlot,
               ObjectIdentifier(scheduledSlot.recorder) == identity {
                guard hasScheduledTimeArrived(scheduledSlot) else {
                    return
                }
                fail(ScheduledChunkRecorderError.scheduledRecorderFinishedEarly(index: scheduledSlot.chunk.index))
            }
            return
        }

        let finishedChunk = activeSlot.chunk
        self.activeSlot = nil

        if isStopping {
            queueFinishedChunk(finishedChunk, successfully: successfully)
            emitStoppedIfQuiescent()
            return
        }

        guard successfully else {
            queueFinishedChunk(finishedChunk, successfully: false)
            fail(ScheduledChunkRecorderError.activeRecorderFailed(index: finishedChunk.index))
            return
        }

        guard let nextSlot = scheduledSlot,
              isScheduledSlotActivelyRecording(nextSlot) else {
            queueFinishedChunk(finishedChunk, successfully: true)
            fail(ScheduledChunkRecorderError.scheduledRecorderDidNotStart(index: finishedChunk.index + 1))
            return
        }

        do {
            guard let anchorDeviceTime else {
                throw ScheduledChunkRecorderError.missingAnchorTime
            }
            let followingIndex = nextSlot.chunk.index + 1
            let followingRecorder = try makePreparedRecorder(index: followingIndex)
            let followingSlot = try schedule(
                followingRecorder,
                index: followingIndex,
                at: scheduledDeviceTime(for: followingIndex, anchor: anchorDeviceTime)
            )
            self.activeSlot = nextSlot
            self.scheduledSlot = followingSlot
            queueFinishedChunk(finishedChunk, successfully: true)
        } catch {
            self.activeSlot = nextSlot
            self.scheduledSlot = nil
            queueFinishedChunk(finishedChunk, successfully: true)
            fail(error)
        }
    }

    private func queueFinishedChunk(_ chunk: Chunk, successfully: Bool) {
        guard chunk.index >= nextFinishedChunkIndex,
              pendingFinishedChunks[chunk.index] == nil else {
            return
        }
        pendingFinishedChunks[chunk.index] = (chunk, successfully)

        while let next = pendingFinishedChunks.removeValue(forKey: nextFinishedChunkIndex) {
            eventHandler(.chunkFinished(next.chunk, successfully: next.successfully))
            nextFinishedChunkIndex += 1
        }
    }

    private func fail(_ error: Error) {
        guard !hasStopped else { return }
        isStopping = true
        cancelAllRecorders(removeFiles: true)
        eventHandler(.failed(error.localizedDescription))
        emitStoppedOnce()
    }

    private func handleRecorderEncodeError(identity: ObjectIdentifier, detail: String) {
        let ownsActive = activeSlot.map { ObjectIdentifier($0.recorder) == identity } ?? false
        let ownsScheduled = scheduledSlot.map { ObjectIdentifier($0.recorder) == identity } ?? false
        guard ownsActive || ownsScheduled || finalizingSlots[identity] != nil else {
            return
        }
        fail(ScheduledChunkRecorderError.encodingFailed(detail))
    }

    private func cancelScheduledRecorder(removeFile: Bool) {
        guard let scheduledSlot else { return }
        scheduledSlot.recorder.delegate = nil
        scheduledSlot.recorder.stop()
        if removeFile {
            removeFileIfPresent(scheduledSlot.chunk.url)
        }
        self.scheduledSlot = nil
    }

    private func cancelAllRecorders(removeFiles: Bool) {
        if let activeSlot {
            activeSlot.recorder.delegate = nil
            activeSlot.recorder.stop()
            if removeFiles {
                removeFileIfPresent(activeSlot.chunk.url)
            }
        }
        self.activeSlot = nil
        cancelScheduledRecorder(removeFile: removeFiles)
        for slot in finalizingSlots.values {
            slot.recorder.delegate = nil
            slot.recorder.stop()
            if removeFiles {
                removeFileIfPresent(slot.chunk.url)
            }
        }
        finalizingSlots.removeAll()
    }

    private func emitStoppedIfQuiescent() {
        guard activeSlot == nil,
              scheduledSlot == nil,
              finalizingSlots.isEmpty,
              pendingFinishedChunks.isEmpty else {
            return
        }
        emitStoppedOnce()
    }

    private func emitStoppedOnce() {
        guard !hasStopped else { return }
        hasStopped = true
        isStopping = false
        eventHandler(.stopped)
    }

    private func hasScheduledTimeArrived(_ slot: Slot?) -> Bool {
        guard let slot else { return false }
        return slot.recorder.deviceCurrentTime >= slot.chunk.scheduledDeviceTime
    }

    private func isScheduledSlotActivelyRecording(_ slot: Slot?) -> Bool {
        guard let slot else { return false }
        return hasScheduledTimeArrived(slot) && slot.recorder.isRecording
    }

    private func removeFileIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

#if DEBUG
    func debugRecorderDidFinish(_ recorder: ScheduledCaptureRecording, successfully: Bool) {
        handleRecorderFinished(identity: ObjectIdentifier(recorder), successfully: successfully)
    }

    func debugRecorderEncodeError(_ recorder: ScheduledCaptureRecording, error: Error?) {
        handleRecorderEncodeError(
            identity: ObjectIdentifier(recorder),
            detail: error?.localizedDescription ?? "unknown"
        )
    }

    func debugClearAnchorTime() {
        anchorDeviceTime = nil
    }
#endif
}

extension ScheduledChunkRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            self?.handleRecorderFinished(identity: identity, successfully: flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let identity = ObjectIdentifier(recorder)
        let detail = error?.localizedDescription ?? "unknown"
        Task { @MainActor [weak self] in
            self?.handleRecorderEncodeError(identity: identity, detail: detail)
        }
    }
}

enum ScheduledChunkRecorderError: LocalizedError, Equatable {
    case invalidConfiguration
    case alreadyStarted
    case recorderPreparationFailed(index: Int)
    case recorderSchedulingFailed(index: Int)
    case firstRecorderDidNotStart
    case scheduledRecorderDidNotStart(index: Int)
    case scheduledRecorderFinishedEarly(index: Int)
    case activeRecorderFailed(index: Int)
    case missingAnchorTime
    case encodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "Invalid scheduled chunk recorder configuration."
        case .alreadyStarted:
            "Scheduled chunk recorder already started."
        case .recorderPreparationFailed(let index):
            "Recorder preparation failed for chunk \(index)."
        case .recorderSchedulingFailed(let index):
            "Recorder scheduling failed for chunk \(index)."
        case .firstRecorderDidNotStart:
            "First scheduled recorder did not start."
        case .scheduledRecorderDidNotStart(let index):
            "Scheduled recorder did not start for chunk \(index)."
        case .scheduledRecorderFinishedEarly(let index):
            "Scheduled recorder finished before promotion for chunk \(index)."
        case .activeRecorderFailed(let index):
            "Active recorder failed for chunk \(index)."
        case .missingAnchorTime:
            "Scheduled recorder anchor time is missing."
        case .encodingFailed(let detail):
            "Scheduled recorder encoding failed: \(detail)."
        }
    }
}
