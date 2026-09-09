import Foundation
import XCTest
@testable import AIWatching

@MainActor
final class WatchChunkedCaptureControllerTests: XCTestCase {

    // MARK: - Fakes

    final class FakeTransferClient: WatchRecordingProbeTransferClient, @unchecked Sendable {
        struct Call {
            let fileURL: URL
            let metadata: [String: Any]
        }

        private let lock = NSLock()
        private var _calls: [Call] = []
        var failNextTransfers = 0

        var calls: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return _calls
        }

        func transfer(fileURL: URL, metadata: [String: Any]) throws {
            lock.lock()
            defer { lock.unlock() }
            if failNextTransfers > 0 {
                failNextTransfers -= 1
                throw WatchRecordingProbeError.transferUnavailable
            }
            _calls.append(Call(fileURL: fileURL, metadata: metadata))
        }
    }

    final class FakeChunkedObserver: WatchChunkedTransferCompletionObserver, @unchecked Sendable {
        private let lock = NSLock()
        private var receivedAcks: [WatchChunkApplicationAck] = []
        private var receivedEvents: [String] = []

        var acks: [WatchChunkApplicationAck] {
            lock.lock()
            defer { lock.unlock() }
            return receivedAcks
        }

        var events: [String] {
            lock.lock()
            defer { lock.unlock() }
            return receivedEvents
        }

        nonisolated func watchChunkedCaptureController(
            didFinishTransfer metadata: WatchRecordingProbeMetadata,
            wasSuccessful: Bool
        ) {
            lock.lock()
            defer { lock.unlock() }
            receivedEvents.append("transfer:\(metadata.chunkIndex):\(wasSuccessful)")
        }

        nonisolated func watchChunkedCaptureController(didReceiveApplicationAck ack: WatchChunkApplicationAck) {
            lock.lock()
            defer { lock.unlock() }
            receivedAcks.append(ack)
            receivedEvents.append("ack:\(ack.chunkIndex)")
        }
    }

    @MainActor
    final class FakeCoordinator: WatchChunkedRecordingCoordinating {
        let directory: URL
        let configuration: ScheduledChunkRecorder.Configuration
        let eventHandler: @MainActor (ScheduledChunkRecorder.Event) -> Void
        var startShouldThrow = false
        private(set) var stopCallCount = 0
        var capturingAfterStart = true
        private var capturing = false

        init(
            directory: URL,
            configuration: ScheduledChunkRecorder.Configuration,
            eventHandler: @escaping @MainActor (ScheduledChunkRecorder.Event) -> Void
        ) {
            self.directory = directory
            self.configuration = configuration
            self.eventHandler = eventHandler
        }

        var isCapturing: Bool { capturing }

        @discardableResult
        func start() async throws -> ScheduledChunkRecorder.Chunk {
            if startShouldThrow {
                throw ScheduledChunkRecorderError.firstRecorderDidNotStart
            }
            capturing = capturingAfterStart
            return chunk(at: configuration.startingChunkIndex)
        }

        func stop() {
            stopCallCount += 1
            capturing = false
        }

        func chunk(at index: Int) -> ScheduledChunkRecorder.Chunk {
            ScheduledChunkRecorder.Chunk(
                index: index,
                url: directory.appendingPathComponent(AIWatchingSchema.chunkAudioFileName(chunkIndex: index)),
                scheduledDeviceTime: 0,
                startOffsetSec: configuration.startingStartOffsetSec +
                    TimeInterval(index - configuration.startingChunkIndex) * configuration.stride
            )
        }

        /// Simulates the recorder finalizing a chunk: writes the audio file
        /// then emits the event, mirroring real delegate ordering.
        func finishChunk(_ index: Int, payload: UInt8 = 0x0A, successfully: Bool = true, writeFile: Bool = true) {
            let chunk = chunk(at: index)
            if writeFile {
                try? Data([payload]).write(to: chunk.url)
            }
            eventHandler(.chunkFinished(chunk, successfully: successfully))
        }

        func emitStopped() {
            capturing = false
            eventHandler(.stopped)
        }
    }

    struct Harness {
        let controller: WatchChunkedCaptureController
        let transferClient: FakeTransferClient
        let root: URL
        let coordinators: () -> [FakeCoordinator]

        var coordinator: FakeCoordinator? { coordinators().last }
    }

    func makeHarness(
        documentsRoot: URL? = nil,
        duration: @escaping (URL) -> TimeInterval = { _ in 60.0 },
        permission: Bool = true,
        now: @escaping () -> Date = Date.init,
        outstandingTransferKeys: @escaping () -> Set<WatchChunkTransferIdentity> = { Set() },
        setupAudioSession: @escaping @Sendable () throws -> Void = {},
        persistDiagnosticsFile: ((Data, URL) throws -> Void)? = nil
    ) -> Harness {
        let root = documentsRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("AIWatchingChunked", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let transferClient = FakeTransferClient()
        let box = CoordinatorBox()
        let controller = WatchChunkedCaptureController(
            documentsProvider: { root },
            requestPermission: { permission },
            transferClient: transferClient,
            resolveDuration: duration,
            setupAudioSession: setupAudioSession,
            deactivateAudioSession: {},
            now: now,
            configurationProvider: {
                .init(chunkDuration: 60, overlapDuration: 0.25, initialLeadTime: 0.1)
            },
            coordinatorProvider: { directory, configuration, eventHandler in
                let coordinator = FakeCoordinator(
                    directory: directory,
                    configuration: configuration,
                    eventHandler: eventHandler
                )
                box.append(coordinator)
                return coordinator
            },
            outstandingTransferKeysProvider: outstandingTransferKeys,
            persistDiagnosticsFile: persistDiagnosticsFile ?? { data, destination in
                try data.write(to: destination, options: [.atomic])
            }
        )
        return Harness(
            controller: controller,
            transferClient: transferClient,
            root: root,
            coordinators: { box.coordinators }
        )
    }

    @MainActor
    final class CoordinatorBox {
        private(set) var coordinators: [FakeCoordinator] = []
        func append(_ coordinator: FakeCoordinator) {
            coordinators.append(coordinator)
        }
    }

    // MARK: - hold-one transfer policy

    func testStartStopRecordsDiagnosticTimelineOrder() async throws {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let harness = makeHarness(
            now: {
                defer { clock = clock.addingTimeInterval(1) }
                return clock
            }
        )
        await harness.controller.start()
        let sessionId = try XCTUnwrap(harness.controller.currentSessionId)
        await Task.yield()

        XCTAssertEqual(harness.controller.state, .recording)
        let coordinator = try XCTUnwrap(harness.coordinator)

        harness.controller.stop()
        coordinator.finishChunk(0, payload: 0x11)
        coordinator.emitStopped()

        XCTAssertEqual(harness.controller.state, .idle)

        let diagnostics = try loadDiagnostics(from: diagnosticsURL(in: harness.root, sessionId: sessionId))
        XCTAssertEqual(diagnostics.events.map(\ .kind), [
            .recordingStarted,
            .stopRequested,
            .sessionCompleted
        ])
        XCTAssertEqual(diagnostics.events.count, 3)
        XCTAssertEqual(diagnostics.events[0].sequence, 0)
        XCTAssertEqual(diagnostics.events[1].sequence, 1)
        XCTAssertEqual(diagnostics.events[2].sequence, 2)
        XCTAssertLessThanOrEqual(diagnostics.events[0].sessionOffsetSec, diagnostics.events[1].sessionOffsetSec)
        XCTAssertLessThanOrEqual(diagnostics.events[1].sessionOffsetSec, diagnostics.events[2].sessionOffsetSec)
        XCTAssertLessThanOrEqual(diagnostics.events[0].occurredAt, diagnostics.events[1].occurredAt)
        XCTAssertLessThanOrEqual(diagnostics.events[1].occurredAt, diagnostics.events[2].occurredAt)
    }

    func testHoldOnePolicyTransfersPredecessorAndMarksLastChunkFinal() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        XCTAssertEqual(harness.controller.state, .recording)
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        // hold-one: chunk 0 is held, nothing transferred yet.
        XCTAssertEqual(harness.transferClient.calls.count, 0)

        coordinator.finishChunk(1)
        // chunk 0 is now definitively non-final.
        XCTAssertEqual(harness.transferClient.calls.count, 1)
        let first = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        XCTAssertEqual(first?.chunkIndex, 0)
        XCTAssertNil(first?.chunkCount)
        XCTAssertEqual(first?.metadataVersion, WatchRecordingProbeMetadata.chunkedVersion)

        harness.controller.stop()
        coordinator.finishChunk(2)
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 3)
        let second = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[1].metadata)
        XCTAssertEqual(second?.chunkIndex, 1)
        XCTAssertNil(second?.chunkCount)
        let final = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[2].metadata)
        XCTAssertEqual(final?.chunkIndex, 2)
        XCTAssertEqual(final?.chunkCount, 3)
        XCTAssertEqual(harness.controller.state, .idle)

        // Offsets follow the recorder stride and stay strictly increasing.
        let offsets = [first, second, final].compactMap { $0?.chunkStartOffsetSec }
        XCTAssertEqual(offsets.count, 3)
        XCTAssertTrue(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 })
    }

    func testSingleChunkSessionSendsFinalWithCountOne() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        harness.controller.stop()
        coordinator.finishChunk(0)
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 1)
        let metadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        XCTAssertEqual(metadata?.chunkIndex, 0)
        XCTAssertEqual(metadata?.chunkCount, 1)
        XCTAssertEqual(metadata?.isFinalChunk, true)
    }

    func testTooShortTailChunkIsDroppedAndPredecessorBecomesFinal() async throws {
        let harness = makeHarness(duration: { url in
            url.lastPathComponent == AIWatchingSchema.chunkAudioFileName(chunkIndex: 1) ? 0.05 : 60.0
        })
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        harness.controller.stop()
        coordinator.finishChunk(1) // tail below minimum transfer duration
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 1)
        let metadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        XCTAssertEqual(metadata?.chunkIndex, 0)
        XCTAssertEqual(metadata?.chunkCount, 1)
        // The dropped tail's audio is removed from the outbox.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: coordinator.directory
                    .appendingPathComponent(AIWatchingSchema.chunkAudioFileName(chunkIndex: 1)).path
            )
        )
    }

    // MARK: - failure handling

    func testMidSessionFailedChunkEndsSessionWithLastGoodChunkFinal() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        coordinator.finishChunk(1, successfully: false, writeFile: false)
        XCTAssertEqual(harness.controller.state, .stopping)
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 1)
        let metadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        XCTAssertEqual(metadata?.chunkIndex, 0)
        XCTAssertEqual(metadata?.chunkCount, 1)
        XCTAssertEqual(harness.controller.state, .idle)
        XCTAssertNotNil(harness.controller.lastError)
    }

    func testTransferEnqueueFailureIsRetriedFromOutbox() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        harness.transferClient.failNextTransfers = 1
        harness.controller.stop()
        coordinator.finishChunk(0)
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 0)
        XCTAssertEqual(harness.controller.pendingTransferCount, 1)

        harness.controller.retryPendingTransfers()
        XCTAssertEqual(harness.transferClient.calls.count, 1)
        XCTAssertEqual(harness.controller.pendingTransferCount, 0)
        let metadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        XCTAssertEqual(metadata?.chunkCount, 1)
        XCTAssertEqual(metadata?.isFinalChunk, true)
    }

    func testRetryPendingTransfersSkipsCurrentHeldChunkButResendsOldSession() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        XCTAssertEqual(harness.transferClient.calls.count, 0)
        XCTAssertEqual(harness.controller.pendingTransferCount, 0)

        let oldSessionId = UUID().uuidString
        let oldSessionDirectory = harness.controller.outboxRoot.appendingPathComponent(oldSessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: oldSessionDirectory, withIntermediateDirectories: true)

        let oldAudioURL = oldSessionDirectory.appendingPathComponent(
            AIWatchingSchema.chunkAudioFileName(chunkIndex: 0)
        )
        try Data([0xAA]).write(to: oldAudioURL)
        let oldMetadata = WatchChunkOutboxRecord(
            metadata: WatchRecordingProbeMetadata(
                metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
                sessionId: oldSessionId,
                startedAt: AIWatchingClock.isoString(Date(timeIntervalSinceNow: -5)),
                endedAt: AIWatchingClock.isoString(),
                durationSec: 60.0,
                fileName: "chunk_0000.m4a",
                chunkIndex: 0,
                chunkStartOffsetSec: 0,
                chunkCount: 1
            ),
            enqueued: false,
            isFinal: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let oldSidecar = oldSessionDirectory.appendingPathComponent(
            AIWatchingSchema.chunkMetadataFileName(chunkIndex: 0)
        )
        try encoder.encode(oldMetadata).write(to: oldSidecar, options: .atomic)

        harness.controller.retryPendingTransfers()
        XCTAssertEqual(harness.transferClient.calls.count, 1, "应优先补发旧会话分片，当前 held 分片不应补发")
        XCTAssertEqual(harness.controller.pendingTransferCount, 0)

        let first = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        XCTAssertEqual(first?.sessionId, oldSessionId)
        XCTAssertEqual(first?.chunkIndex, 0)
        XCTAssertEqual(first?.chunkCount, 1)
        XCTAssertEqual(first?.isFinalChunk, true)

        harness.controller.stop()
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 2)
        let currentFinal = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[1].metadata)
        XCTAssertEqual(currentFinal?.chunkIndex, 0)
        XCTAssertEqual(currentFinal?.chunkCount, 1, "当前 hold 分片应只在停止时改为 final 发送")
        XCTAssertEqual(currentFinal?.metadataVersion, WatchRecordingProbeMetadata.chunkedVersion)
    }

    func testPermissionDeniedFailsStartExplicitly() async {
        let harness = makeHarness(permission: false)
        await harness.controller.start()
        XCTAssertEqual(harness.controller.state, .idle)
        XCTAssertNotNil(harness.controller.lastError)
        XCTAssertTrue(harness.coordinators().isEmpty)
    }

    // MARK: - interruption flow (ADR-007 decision 8)

    func testInterruptionHoldsChunksAndResumeContinuesIndices() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let first = try XCTUnwrap(harness.coordinator)

        first.finishChunk(0)
        first.finishChunk(1)
        XCTAssertEqual(harness.transferClient.calls.count, 1) // chunk 0 sent non-final

        harness.controller.handleInterruptionBegan()
        XCTAssertEqual(harness.controller.state, .interrupted)
        XCTAssertEqual(first.stopCallCount, 1)
        first.emitStopped()
        // Held chunk 1 must NOT be flushed as final during interruption.
        XCTAssertEqual(harness.transferClient.calls.count, 1)

        await harness.controller.handleInterruptionEnded(shouldResume: true)
        XCTAssertEqual(harness.controller.state, .recording)
        let resumed = try XCTUnwrap(harness.coordinator)
        XCTAssertFalse(resumed === first)
        // Indices continue after the last finalized chunk; offsets restart
        // from the session-relative wall-clock, still increasing.
        XCTAssertEqual(resumed.configuration.startingChunkIndex, 2)

        resumed.finishChunk(2)
        // chunk 1 is now definitively non-final.
        XCTAssertEqual(harness.transferClient.calls.count, 2)

        let sessionId = try XCTUnwrap(harness.controller.currentSessionId)
        let diagnostics = try loadDiagnostics(from: diagnosticsURL(in: harness.root, sessionId: sessionId))
        let kinds = diagnostics.events.map(\ .kind)
        XCTAssertEqual(kinds, [
            .recordingStarted,
            .interruptionBegan,
            .interruptionEnded,
            .resumeAttemptStarted,
            .resumeSucceeded,
        ])

        harness.controller.stop()
        coordinatorStopAndFinish(resumed, finishing: 3)

        XCTAssertEqual(harness.transferClient.calls.count, 4)
        let final = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[3].metadata)
        XCTAssertEqual(final?.chunkIndex, 3)
        XCTAssertEqual(final?.chunkCount, 4)

        let finalMetadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[3].metadata)
        XCTAssertNotNil(finalMetadata?.captureDiagnostics)
        let nonFinalMetadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        XCTAssertNil(nonFinalMetadata?.captureDiagnostics)
    }

    func testInterruptionEndedWithoutResumeCompletesSessionWithFinalMarker() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)
        let sessionId = try XCTUnwrap(harness.controller.currentSessionId)

        coordinator.finishChunk(0)
        harness.controller.handleInterruptionBegan()
        coordinator.emitStopped()

        await harness.controller.handleInterruptionEnded(shouldResume: false)
        XCTAssertEqual(harness.controller.state, .idle)
        XCTAssertEqual(harness.transferClient.calls.count, 1)
        let metadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        XCTAssertEqual(metadata?.chunkCount, 1)

        let diagnostics = try loadDiagnostics(from: diagnosticsURL(in: harness.root, sessionId: sessionId))
        let kinds = diagnostics.events.map(\ .kind)
        XCTAssertEqual(kinds, [
            .recordingStarted,
            .interruptionBegan,
            .interruptionEnded,
            .sessionCompleted
        ])
    }

    func testInterruptionEndedDuringFinalizationProducesOnlyOneInterruptionEndedEvent() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        harness.controller.handleInterruptionBegan()
        await harness.controller.handleInterruptionEnded(shouldResume: true)
        XCTAssertEqual(harness.controller.state, .interrupted)
        coordinator.emitStopped()
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(harness.controller.state, .recording)

        let diagnostics = try loadDiagnostics(
            from: diagnosticsURL(in: harness.root, sessionId: try XCTUnwrap(harness.controller.currentSessionId))
        )
        XCTAssertEqual(diagnostics.events.map(\ .kind).filter { $0 == .interruptionEnded }.count, 1)
        XCTAssertEqual(
            diagnostics.events.map(\ .kind),
            [
                .recordingStarted,
                .interruptionBegan,
                .interruptionEnded,
                .resumeDeferred,
                .resumeAttemptStarted,
                .resumeSucceeded,
            ]
        )
    }

    func testResumeFailureKeepsSessionCompletionWithResumeFailed() async throws {
        enum SetupError: Error {
            case failed
        }

        final class SetupCounter: @unchecked Sendable {
            private var count = 0
            private let lock = NSLock()

            func nextAttempt() throws {
                lock.lock()
                defer { lock.unlock() }
                count += 1
                if count > 1 {
                    throw SetupError.failed
                }
            }
        }

        let setupCounter = SetupCounter()
        let harness = makeHarness(
            now: {
                Date()
            },
            setupAudioSession: {
                try setupCounter.nextAttempt()
            },
            persistDiagnosticsFile: nil
        )
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)
        let sessionId = try XCTUnwrap(harness.controller.currentSessionId)

        coordinator.finishChunk(0)
        harness.controller.handleInterruptionBegan()
        await harness.controller.handleInterruptionEnded(shouldResume: true)
        coordinator.emitStopped()
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(harness.controller.state, .idle)
        XCTAssertEqual(harness.controller.transferredChunkCount, 1)

        let diagnostics = try loadDiagnostics(
            from: diagnosticsURL(in: harness.root, sessionId: sessionId)
        )
        XCTAssertTrue(diagnostics.events.map(\ .kind).contains(.resumeFailed))
    }

    func testResumeSignalArrivingDuringFinalizationIsDeferredNotLost() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let first = try XCTUnwrap(harness.coordinator)

        first.finishChunk(0)
        harness.controller.handleInterruptionBegan()
        // Interruption ends BEFORE the coordinator finished finalizing.
        await harness.controller.handleInterruptionEnded(shouldResume: true)
        XCTAssertEqual(harness.controller.state, .interrupted)

        first.emitStopped()
        // The deferred resume runs on the next main-actor hop.
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(harness.controller.state, .recording)
        XCTAssertEqual(harness.coordinators().count, 2)
    }

    // MARK: - abandoned session recovery

    func testRecoverAbandonedSessionPromotesHighestChunkToFinalAndResends() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        coordinator.finishChunk(1)
        XCTAssertEqual(harness.transferClient.calls.count, 1)
        let preRecoveryCallCount = harness.transferClient.calls.count
        // Simulate app death mid-session: chunk 1 held, never sent as final.
        // A new controller instance over the same documents root relaunches.
        let relaunched = WatchChunkedCaptureController(
            documentsProvider: { harness.root },
            requestPermission: { true },
            transferClient: harness.transferClient,
            resolveDuration: { _ in 60.0 },
            setupAudioSession: {},
            deactivateAudioSession: {},
            coordinatorProvider: { _, _, _ in
                XCTFail("recovery must not start a recorder")
                throw ScheduledChunkRecorderError.alreadyStarted
            }
        )
        relaunched.recoverAbandonedSessions()

        XCTAssertEqual(harness.transferClient.calls.count, 3)
        let recoveredCalls = harness.transferClient.calls.dropFirst(preRecoveryCallCount)
        XCTAssertEqual(recoveredCalls.count, 2)
        let recovered = harness.transferClient.calls
            .compactMap { WatchRecordingProbeMetadata(dictionary: $0.metadata) }
            .first { $0.chunkIndex == 1 && $0.chunkCount == 2 }
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.chunkIndex, 1)
        XCTAssertEqual(recovered?.chunkCount, 2)
        XCTAssertEqual(relaunched.pendingTransferCount, 0)
        let retried = recoveredCalls.compactMap { WatchRecordingProbeMetadata(dictionary: $0.metadata) }
            .first { $0.chunkIndex == 0 && $0.chunkCount == nil }
        XCTAssertNotNil(retried)
        XCTAssertEqual(retried?.chunkIndex, 0)
        XCTAssertNil(retried?.chunkCount)
    }

    func testRecoverAbandonedSessionRetainsLatestDiagnostics() async throws {
        let sessionStartedAt = AIWatchingClock.isoString(Date(timeIntervalSince1970: 1_700_000_200))
        let diagnostics = WatchCaptureDiagnostics(
            schemaVersion: 1,
            events: [
                WatchCaptureDiagnosticEvent(
                    sequence: 0,
                    kind: .recordingStarted,
                    occurredAt: sessionStartedAt,
                    sessionOffsetSec: 0,
                    controllerState: "recording",
                    shouldResume: nil,
                    lastFinalizedChunkIndex: nil,
                    detail: nil
                )
            ],
            truncated: false
        )

        let harness = makeHarness(
            now: {
                Date(timeIntervalSince1970: 1_700_000_200)
            },
            persistDiagnosticsFile: { data, destination in
                try data.write(to: destination, options: [.atomic])
            }
        )
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        coordinator.finishChunk(1)
        let sessionId = try XCTUnwrap(harness.controller.currentSessionId)

        let storedDiagnostics = try loadDiagnostics(from: diagnosticsURL(in: harness.root, sessionId: sessionId))
        XCTAssertEqual(storedDiagnostics.truncated, false)
        XCTAssertEqual(storedDiagnostics.events.first?.occurredAt, sessionStartedAt)
        XCTAssertEqual(storedDiagnostics, diagnostics)

        let relaunched = WatchChunkedCaptureController(
            documentsProvider: { harness.root },
            requestPermission: { true },
            transferClient: harness.transferClient,
            resolveDuration: { _ in 60.0 },
            setupAudioSession: {},
            deactivateAudioSession: {},
            coordinatorProvider: { _, _, _ in
                XCTFail("recovery must not start a recorder")
                throw ScheduledChunkRecorderError.alreadyStarted
            },
            persistDiagnosticsFile: { data, destination in
                try data.write(to: destination, options: [.atomic])
            }
        )
        relaunched.recoverAbandonedSessions()

        XCTAssertEqual(harness.transferClient.calls.count, 3)
        let recovered = harness.transferClient.calls
            .compactMap { WatchRecordingProbeMetadata(dictionary: $0.metadata) }
            .first { $0.chunkIndex == 1 && $0.chunkCount == 2 }
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.chunkIndex, 1)
        XCTAssertEqual(recovered?.chunkCount, 2)
        XCTAssertNotNil(recovered?.captureDiagnostics)
        let recoveredEvents = try XCTUnwrap(recovered?.captureDiagnostics?.events)
        XCTAssertEqual(recoveredEvents.count, storedDiagnostics.events.count + 1)
        XCTAssertEqual(Array(recoveredEvents.dropLast()), storedDiagnostics.events)
        XCTAssertEqual(relaunched.pendingTransferCount, 0)
        XCTAssertEqual(harness.transferClient.calls.count, 3)
        let first = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        XCTAssertNil(first?.chunkCount)
        XCTAssertNil(first?.captureDiagnostics)
        XCTAssertEqual(recovered?.chunkIndex, 1)
        XCTAssertEqual(recovered?.chunkCount, 2)
        XCTAssertEqual(recoveredEvents.last?.kind, .abandonedSessionRecovered)
        XCTAssertGreaterThanOrEqual(recoveredEvents.last?.sessionOffsetSec ?? -1, 0)
        XCTAssertTrue(
            zip(recoveredEvents, recoveredEvents.dropFirst())
                .allSatisfy { $0.sequence + 1 == $1.sequence }
        )
    }

    func testRecoverAbandonedSessionRecoveryEventPersistsOnDiagnosticsWriteBackFailure() async throws {
        enum WriteFailure: Error {
            case failed
        }

        var persistedWrites = 0
        let throwingPersist: (Data, URL) throws -> Void = { data, destination in
            persistedWrites += 1
            if persistedWrites > 1 {
                throw WriteFailure.failed
            }
            try data.write(to: destination, options: [.atomic])
        }

        let harness = makeHarness(
            now: {
                Date(timeIntervalSince1970: 1_700_000_300)
            },
            persistDiagnosticsFile: throwingPersist
        )
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        coordinator.finishChunk(1)
        XCTAssertEqual(harness.transferClient.calls.count, 1)

        let relaunched = WatchChunkedCaptureController(
            documentsProvider: { harness.root },
            requestPermission: { true },
            transferClient: harness.transferClient,
            resolveDuration: { _ in 60.0 },
            setupAudioSession: {},
            deactivateAudioSession: {},
            coordinatorProvider: { _, _, _ in
                XCTFail("recovery must not start a recorder")
                throw ScheduledChunkRecorderError.alreadyStarted
            },
            persistDiagnosticsFile: throwingPersist
        )
        relaunched.recoverAbandonedSessions()

        XCTAssertEqual(harness.transferClient.calls.count, 3)
        let recovered = harness.transferClient.calls
            .compactMap { WatchRecordingProbeMetadata(dictionary: $0.metadata) }
            .first { $0.chunkIndex == 1 && $0.chunkCount == 2 }
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.chunkIndex, 1)
        XCTAssertEqual(recovered?.chunkCount, 2)
        XCTAssertNotNil(relaunched.lastError)
        let recoveredEvents = try XCTUnwrap(recovered?.captureDiagnostics?.events)
        XCTAssertEqual(recoveredEvents.last?.kind, .abandonedSessionRecovered)
        XCTAssertGreaterThanOrEqual(recoveredEvents.last?.sessionOffsetSec ?? -1, 0)
        XCTAssertTrue(
            zip(recoveredEvents, recoveredEvents.dropFirst())
                .allSatisfy { $0.sequence + 1 == $1.sequence }
        )
    }

    func testDiagnosticsFileIsTruncatedAtMaxEventCount() async throws {
        var clock = Date(timeIntervalSinceReferenceDate: 0)
        let harness = makeHarness(
            now: {
                let tick = clock
                clock = tick.addingTimeInterval(0.25)
                return tick
            }
        )
        await harness.controller.start()
        let sessionId = try XCTUnwrap(harness.controller.currentSessionId)
        for _ in 0..<51 {
            let coordinator = try XCTUnwrap(harness.coordinator)
            harness.controller.handleInterruptionBegan()
            await harness.controller.handleInterruptionEnded(shouldResume: true)
            coordinator.emitStopped()
            await Task.yield()
            await Task.yield()
        }
        let coordinator = try XCTUnwrap(harness.coordinator)
        harness.controller.stop()
        coordinator.emitStopped()

        let diagnostics = try loadDiagnostics(
            from: diagnosticsURL(in: harness.root, sessionId: sessionId)
        )
        XCTAssertEqual(diagnostics.events.count, 256)
        XCTAssertTrue(diagnostics.truncated)
        XCTAssertEqual(diagnostics.events.last?.sequence, 255)
    }

    func testDiagnosticsPersistenceFailureDoesNotAbortRecording() async throws {
        struct WriteFailure: Error {}
        let harness = makeHarness(
            persistDiagnosticsFile: { _, _ in
                throw WriteFailure()
            }
        )
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        harness.controller.stop()
        coordinator.emitStopped()

        XCTAssertEqual(harness.controller.state, .idle)
        XCTAssertEqual(harness.transferClient.calls.count, 1)
        XCTAssertNotNil(harness.controller.lastError)
    }

    func testFinalMetadataUsesMemoryDiagnosticsWhenDiagnosticsPersistenceFails() async throws {
        struct WriteFailure: Error {}
        let harness = makeHarness(
            persistDiagnosticsFile: { _, _ in
                throw WriteFailure()
            }
        )
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0, payload: 0x11)
        coordinator.finishChunk(1, payload: 0x22)
        harness.controller.stop()
        coordinator.emitStopped()

        XCTAssertEqual(harness.controller.state, .idle)
        XCTAssertEqual(harness.transferClient.calls.count, 2)
        XCTAssertNotNil(harness.controller.lastError)

        let nonFinal = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        XCTAssertNil(nonFinal?.captureDiagnostics)

        let final = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[1].metadata)
        XCTAssertNotNil(final?.captureDiagnostics)
        let events = final?.captureDiagnostics?.events ?? []
        XCTAssertEqual(events.last?.kind, .sessionCompleted)
        XCTAssertTrue(events.map(\.kind).contains(.recordingStarted))
        XCTAssertTrue(events.map(\.kind).contains(.stopRequested))
        XCTAssertTrue(events.map(\.kind).contains(.sessionCompleted))
        XCTAssertTrue(zip(events, events.dropFirst()).allSatisfy { $0.sequence + 1 == $1.sequence })
    }

    func testFinalMetadataUsesMemoryDiagnosticsWhenFinalWriteFailsOnDisk() async throws {
        struct WriteFailure: Error {}

        var writeCount = 0
        let harness = makeHarness(
            persistDiagnosticsFile: { data, destination in
                writeCount += 1
                if writeCount == 3 {
                    throw WriteFailure()
                }
                try data.write(to: destination, options: [.atomic])
            }
        )
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0, payload: 0x11)
        harness.controller.stop()
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 1)
        let final = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        XCTAssertEqual(final?.chunkIndex, 0)
        XCTAssertNotNil(final?.captureDiagnostics)
        XCTAssertNotNil(harness.controller.lastError)

        let events = final?.captureDiagnostics?.events ?? []
        let kinds = events.map(\.kind)
        XCTAssertEqual(kinds, [.recordingStarted, .stopRequested, .sessionCompleted])
    }

    // MARK: - end-to-end (software): watch controller -> phone staging -> importer

    func testChunkedCaptureFlowsThroughPhoneStagingIntoStandardSession() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)
        let sessionId = try XCTUnwrap(harness.controller.currentSessionId)

        coordinator.finishChunk(0, payload: 0x01)
        coordinator.finishChunk(1, payload: 0x02)
        harness.controller.stop()
        coordinator.finishChunk(2, payload: 0x03)
        coordinator.emitStopped()
        XCTAssertEqual(harness.transferClient.calls.count, 3)

        // Phone side: feed every watch transfer through the real staging path.
        let phoneRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIWatchingChunkedPhone", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: phoneRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: phoneRoot) }

        PhoneConnectivityController.shared.debugResetCaptureStateForTests()
        PhoneConnectivityController.shared.installTestDependencies(
            .init(
                watchProbeTransferDocumentsDirectory: phoneRoot,
                sendWatchChunkApplicationAck: { _ in }
            )
        )

        for call in harness.transferClient.calls {
            // transferFile hands the phone a temporary copy; simulate that so
            // staging's move does not consume the watch-side outbox file.
            let incoming = phoneRoot.appendingPathComponent("incoming-\(UUID().uuidString).m4a")
            try FileManager.default.copyItem(at: call.fileURL, to: incoming)
            let staged = PhoneConnectivityController.shared.processWatchProbeTransfer(
                fileURL: incoming,
                metadata: call.metadata
            )
            XCTAssertNotNil(staged)
        }
        XCTAssertNil(PhoneConnectivityController.shared.debugWatchProbeTransferLastError)

        let recordingsRoot = phoneRoot.appendingPathComponent("recordings", isDirectory: true)
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 60.0 }
        )
        let failures = importer.importAllPendingWatchCaptureSessions(
            at: phoneRoot.appendingPathComponent("watch-capture-inbox", isDirectory: true)
        )
        XCTAssertTrue(failures.isEmpty)

        let sessions = (try? FileManager.default.contentsOfDirectory(at: recordingsRoot, includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions[0].lastPathComponent.hasSuffix("__capture__\(sessionId)"))

        let manifestData = try Data(contentsOf: sessions[0].appendingPathComponent(AIWatchingSchema.manifestFileName))
        let manifest = try JSONDecoder().decode(SessionManifest.self, from: manifestData)
        XCTAssertEqual(manifest.source, .watch)
        XCTAssertEqual(manifest.chunks.map(\.index), [0, 1, 2])
        XCTAssertTrue(
            zip(manifest.chunks, manifest.chunks.dropFirst())
                .allSatisfy { $0.startOffsetSec < $1.startOffsetSec }
        )
        for (position, payload) in [Data([0x01]), Data([0x02]), Data([0x03])].enumerated() {
            let audio = sessions[0]
                .appendingPathComponent(AIWatchingSchema.audioFolderName)
                .appendingPathComponent(AIWatchingSchema.chunkAudioFileName(chunkIndex: position))
            XCTAssertEqual(try Data(contentsOf: audio), payload)
        }

        let statusData = try Data(contentsOf: sessions[0].appendingPathComponent(AIWatchingSchema.statusFileName))
        let status = try JSONDecoder().decode(SessionStatus.self, from: statusData)
        XCTAssertEqual(status.state, .complete)
    }

    // MARK: - transfer completion confirmation + outbox GC

    func testTransportSuccessDoesNotAcknowledgeOrDeleteUntilApplicationAck() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        harness.controller.stop()
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 1)
        let metadata = harness.transferClient.calls[0].metadata
        let transferMetadata = WatchRecordingProbeMetadata(dictionary: metadata)
        let sessionId = try XCTUnwrap(transferMetadata?.sessionId)
        let sessionDir = outboxSessionDirectory(in: harness.root, sessionId: sessionId)
        let audio = sessionDir.appendingPathComponent(AIWatchingSchema.chunkAudioFileName(chunkIndex: 0))

        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))

        harness.controller.handleTransferCompletion(metadata: transferMetadata!, wasSuccessful: false)
        let pendingRecord = try outboxRecord(from: sessionDir, chunkIndex: 0)
        XCTAssertEqual(pendingRecord.transferState, .pending)
        XCTAssertEqual(harness.controller.pendingTransferCount, 1)

        // A late transport-success callback for the failed attempt cannot
        // acknowledge a record that is already pending.
        harness.controller.handleTransferCompletion(metadata: transferMetadata!, wasSuccessful: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))

        harness.controller.retryPendingTransfers()
        XCTAssertEqual(harness.transferClient.calls.count, 2)
        let retriedAttemptMetadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[1].metadata)
        XCTAssertNotNil(retriedAttemptMetadata?.transferAttemptId)

        // didFinish(success) means only that the file reached the system Inbox.
        harness.controller.handleTransferCompletion(metadata: retriedAttemptMetadata!, wasSuccessful: true)
        let transportSucceededRecord = try outboxRecord(from: sessionDir, chunkIndex: 0)
        XCTAssertEqual(transportSucceededRecord.transferState, .enqueued)
        XCTAssertEqual(transportSucceededRecord.activeAttemptId, retriedAttemptMetadata?.transferAttemptId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent(
            AIWatchingSchema.chunkMetadataFileName(chunkIndex: 0)
        ).path))

        harness.controller.handleApplicationAck(
            WatchChunkApplicationAck(
                sessionId: retriedAttemptMetadata!.sessionId,
                chunkIndex: retriedAttemptMetadata!.chunkIndex,
                transferAttemptId: retriedAttemptMetadata!.transferAttemptId!
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir.appendingPathComponent(
            AIWatchingSchema.chunkMetadataFileName(chunkIndex: 0)
        ).path))

        // Duplicate transport callback and application ACK remain idempotent.
        harness.controller.handleTransferCompletion(metadata: transferMetadata!, wasSuccessful: true)
        harness.controller.handleApplicationAck(
            WatchChunkApplicationAck(
                sessionId: retriedAttemptMetadata!.sessionId,
                chunkIndex: retriedAttemptMetadata!.chunkIndex,
                transferAttemptId: retriedAttemptMetadata!.transferAttemptId!
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio.path))
    }

    func testApplicationAckRequiresCurrentEnqueuedUnitAndAttempt() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        harness.controller.stop()
        coordinator.finishChunk(0)
        coordinator.emitStopped()

        let metadata = try XCTUnwrap(
            WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        )
        let sessionDirectory = outboxSessionDirectory(in: harness.root, sessionId: metadata.sessionId)
        let audioURL = sessionDirectory.appendingPathComponent(
            AIWatchingSchema.chunkAudioFileName(chunkIndex: metadata.chunkIndex)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        let staleAttempt = WatchChunkApplicationAck(
            sessionId: metadata.sessionId,
            chunkIndex: metadata.chunkIndex,
            transferAttemptId: UUID().uuidString
        )
        let wrongSession = WatchChunkApplicationAck(
            sessionId: UUID().uuidString,
            chunkIndex: metadata.chunkIndex,
            transferAttemptId: metadata.transferAttemptId!
        )
        let wrongIndex = WatchChunkApplicationAck(
            sessionId: metadata.sessionId,
            chunkIndex: metadata.chunkIndex + 1,
            transferAttemptId: metadata.transferAttemptId!
        )

        for ack in [staleAttempt, wrongSession, wrongIndex] {
            harness.controller.handleApplicationAck(ack)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(
            try outboxRecord(from: sessionDirectory, chunkIndex: metadata.chunkIndex).transferState,
            .enqueued
        )

        harness.controller.handleApplicationAck(
            WatchChunkApplicationAck(
                sessionId: metadata.sessionId,
                chunkIndex: metadata.chunkIndex,
                transferAttemptId: metadata.transferAttemptId!
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testApplicationAckHasNoEffectForPendingOrAcknowledgedRecord() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)
        harness.transferClient.failNextTransfers = 1
        harness.controller.stop()
        coordinator.finishChunk(0)
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 0)

        let sessionDirectories = try FileManager.default.contentsOfDirectory(
            at: harness.controller.outboxRoot,
            includingPropertiesForKeys: nil
        )
        let sessionDirectory = try XCTUnwrap(sessionDirectories.first)
        let sessionId = sessionDirectory.lastPathComponent
        let pending = try outboxRecord(from: sessionDirectory, chunkIndex: 0)
        XCTAssertEqual(pending.transferState, .pending)
        let ack = WatchChunkApplicationAck(
            sessionId: sessionId,
            chunkIndex: 0,
            transferAttemptId: UUID().uuidString
        )
        harness.controller.handleApplicationAck(ack)
        XCTAssertEqual(try outboxRecord(from: sessionDirectory, chunkIndex: 0).transferState, .pending)

        harness.controller.retryPendingTransfers()
        let currentMetadata = try XCTUnwrap(
            WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        )
        harness.controller.handleApplicationAck(
            WatchChunkApplicationAck(
                sessionId: currentMetadata.sessionId,
                chunkIndex: currentMetadata.chunkIndex,
                transferAttemptId: currentMetadata.transferAttemptId!
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent(
            AIWatchingSchema.chunkAudioFileName(chunkIndex: 0)
        ).path))
        // Replaying the same ACK after GC must not recreate or mutate anything.
        harness.controller.handleApplicationAck(
            WatchChunkApplicationAck(
                sessionId: currentMetadata.sessionId,
                chunkIndex: currentMetadata.chunkIndex,
                transferAttemptId: currentMetadata.transferAttemptId!
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
    }

    func testWatchConnectorBuffersEarlyApplicationAckUntilObserverRegistration() {
        let buffer = WatchChunkedTransferObserverBuffer()
        let ack = WatchChunkApplicationAck(
            sessionId: UUID().uuidString,
            chunkIndex: 7,
            transferAttemptId: UUID().uuidString
        )

        buffer.receiveApplicationAck(ack)

        let observer = FakeChunkedObserver()
        buffer.register(observer)
        XCTAssertEqual(observer.acks, [ack])
    }

    func testWatchConnectorObserverBufferPreservesEarlyTransferAndAckOrder() {
        let buffer = WatchChunkedTransferObserverBuffer()
        let ack = WatchChunkApplicationAck(
            sessionId: UUID().uuidString,
            chunkIndex: 8,
            transferAttemptId: UUID().uuidString
        )
        let metadata = WatchRecordingProbeMetadata(
            metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
            sessionId: ack.sessionId,
            startedAt: AIWatchingClock.isoString(Date(timeIntervalSince1970: 1_700_000_000)),
            endedAt: AIWatchingClock.isoString(Date(timeIntervalSince1970: 1_700_000_060)),
            durationSec: 60,
            fileName: "chunk_0008.m4a",
            chunkIndex: ack.chunkIndex,
            chunkStartOffsetSec: 480,
            transferAttemptId: ack.transferAttemptId
        )
        buffer.receiveTransferCompletion(metadata: metadata, wasSuccessful: true)
        buffer.receiveApplicationAck(ack)

        let observer = FakeChunkedObserver()
        buffer.register(observer)
        XCTAssertEqual(observer.acks, [ack])
        XCTAssertEqual(observer.events, ["transfer:8:true", "ack:8"])
    }

    func testTransportSuccessWithoutApplicationAckIsResentAfterRestartReconcile() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)
        harness.controller.stop()
        coordinator.finishChunk(0)
        coordinator.emitStopped()

        let metadata = try XCTUnwrap(
            WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        )
        let sessionDirectory = outboxSessionDirectory(in: harness.root, sessionId: metadata.sessionId)
        XCTAssertEqual(try outboxRecord(from: sessionDirectory, chunkIndex: 0).transferState, .enqueued)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent(
            AIWatchingSchema.chunkAudioFileName(chunkIndex: 0)
        ).path))

        // didFinish(success) does not supply the missing application ACK.
        harness.controller.handleTransferCompletion(metadata: metadata, wasSuccessful: true)
        XCTAssertEqual(try outboxRecord(from: sessionDirectory, chunkIndex: 0).transferState, .enqueued)

        let relaunched = makeHarness(
            documentsRoot: harness.root,
            outstandingTransferKeys: { [] }
        )
        relaunched.controller.recoverAbandonedSessions()
        XCTAssertEqual(relaunched.transferClient.calls.count, 1)
        XCTAssertEqual(
            WatchRecordingProbeMetadata(dictionary: relaunched.transferClient.calls[0].metadata)?.sessionId,
            metadata.sessionId
        )
    }

    func testTransferCompletionStaleMetadataIgnored() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        harness.controller.stop()
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 1)
        let transferMetadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)

        harness.controller.handleTransferCompletion(
            metadata: WatchRecordingProbeMetadata(
                metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
                sessionId: UUID().uuidString,
                startedAt: AIWatchingClock.isoString(Date(timeIntervalSince1970: 1_700_000_200)),
                endedAt: AIWatchingClock.isoString(Date(timeIntervalSince1970: 1_700_000_260)),
                durationSec: 10,
                fileName: "chunk_0000.m4a",
                chunkIndex: 0
            ),
            wasSuccessful: true
        )

        let validMetadata = try XCTUnwrap(transferMetadata)
        XCTAssertNotNil(validMetadata)
        let audio = outboxSessionDirectory(in: harness.root, sessionId: validMetadata.sessionId)
            .appendingPathComponent(AIWatchingSchema.chunkAudioFileName(chunkIndex: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertEqual(harness.controller.pendingTransferCount, 0)
    }

    func testTransferCompletionPendingStateSuccessIgnored() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)
        let sessionId = try XCTUnwrap(harness.controller.currentSessionId)

        harness.transferClient.failNextTransfers = 1
        coordinator.finishChunk(0)
        harness.controller.stop()
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 0)
        let sessionDirectory = outboxSessionDirectory(in: harness.root, sessionId: sessionId)
        let pendingRecord = try outboxRecord(from: sessionDirectory, chunkIndex: 0)
        XCTAssertEqual(pendingRecord.transferState, .pending)

        let metadata = pendingRecord.metadata
        harness.controller.handleTransferCompletion(metadata: metadata, wasSuccessful: true)

        XCTAssertEqual(harness.controller.pendingTransferCount, 1)
        let audioURL = sessionDirectory
            .appendingPathComponent(AIWatchingSchema.chunkAudioFileName(chunkIndex: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(harness.controller.pendingTransferCount, 1)
    }

    func testTransferAttemptIdFailureThenRetrySuccessUsesLatestAttemptOnly() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        harness.controller.stop()
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 1)
        let firstAttemptMetadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        XCTAssertNotNil(firstAttemptMetadata?.transferAttemptId)
        let sessionDirectory = outboxSessionDirectory(
            in: harness.root,
            sessionId: firstAttemptMetadata!.sessionId
        )
        let firstSidecar = try outboxRecord(from: sessionDirectory, chunkIndex: 0)
        XCTAssertEqual(firstSidecar.transferState, .enqueued)

        harness.controller.handleTransferCompletion(metadata: firstAttemptMetadata!, wasSuccessful: false)
        XCTAssertEqual(harness.controller.pendingTransferCount, 1)

        harness.controller.retryPendingTransfers()
        XCTAssertEqual(harness.transferClient.calls.count, 2)
        let secondAttemptMetadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[1].metadata)
        XCTAssertNotNil(secondAttemptMetadata?.transferAttemptId)
        XCTAssertNotEqual(firstAttemptMetadata?.transferAttemptId, secondAttemptMetadata?.transferAttemptId)

        harness.controller.handleTransferCompletion(metadata: firstAttemptMetadata!, wasSuccessful: true)
        let audioURL = sessionDirectory
            .appendingPathComponent(AIWatchingSchema.chunkAudioFileName(chunkIndex: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(harness.controller.pendingTransferCount, 0)

        harness.controller.handleTransferCompletion(metadata: secondAttemptMetadata!, wasSuccessful: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        harness.controller.handleApplicationAck(
            WatchChunkApplicationAck(
                sessionId: secondAttemptMetadata!.sessionId,
                chunkIndex: secondAttemptMetadata!.chunkIndex,
                transferAttemptId: secondAttemptMetadata!.transferAttemptId!
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
    }

    func testTransferAttemptIdFailureAfterRetryDoesNotRevertCurrentAttempt() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        harness.controller.stop()
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 1)
        let firstAttemptMetadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)

        harness.controller.handleTransferCompletion(metadata: firstAttemptMetadata!, wasSuccessful: false)
        XCTAssertEqual(harness.controller.pendingTransferCount, 1)

        harness.controller.retryPendingTransfers()
        XCTAssertEqual(harness.transferClient.calls.count, 2)
        let secondAttemptMetadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[1].metadata)

        let delayedFailure = firstAttemptMetadata!
        harness.controller.handleTransferCompletion(metadata: delayedFailure, wasSuccessful: false)
        let statusRecord = try outboxRecord(
            from: outboxSessionDirectory(in: harness.root, sessionId: firstAttemptMetadata!.sessionId),
            chunkIndex: 0
        )
        XCTAssertEqual(statusRecord.transferState, .enqueued)
        XCTAssertEqual(statusRecord.activeAttemptId, secondAttemptMetadata?.transferAttemptId)
        XCTAssertEqual(harness.controller.pendingTransferCount, 0)
    }

    func testRecoverAbandonedSessionsReconcilesStaleEnqueuedAndAutoResends() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIWatchingChunked", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let harness = makeHarness(
            documentsRoot: root,
            outstandingTransferKeys: { [] }
        )
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)
        coordinator.finishChunk(0)
        harness.controller.stop()
        coordinator.emitStopped()

        let firstMetadata = harness.transferClient.calls[0].metadata
        let sessionId = try XCTUnwrap(WatchRecordingProbeMetadata(dictionary: firstMetadata)?.sessionId)
        let sessionDir = outboxSessionDirectory(in: root, sessionId: sessionId)
        let stale = try outboxRecord(from: sessionDir, chunkIndex: 0)
        XCTAssertEqual(stale.transferState, .enqueued)
        XCTAssertEqual(stale.transferState == .enqueued, true)

        let relaunched = makeHarness(
            documentsRoot: root,
            outstandingTransferKeys: { [] }
        )
        relaunched.controller.recoverAbandonedSessions()

        XCTAssertEqual(relaunched.transferClient.calls.count, 1)
        XCTAssertEqual(relaunched.controller.pendingTransferCount, 0)
        let reconciled = try outboxRecord(from: sessionDir, chunkIndex: 0)
        XCTAssertEqual(reconciled.transferState, .enqueued)
    }

    func testOutstandingAttemptIsolatedFromPendingStateForRestart() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)
        coordinator.finishChunk(0)
        harness.controller.stop()
        coordinator.emitStopped()
        XCTAssertEqual(harness.transferClient.calls.count, 1)

        let initialTransferMetadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        let sessionId = try XCTUnwrap(initialTransferMetadata?.sessionId)
        let sessionDirectory = outboxSessionDirectory(in: harness.root, sessionId: sessionId)
        let firstRecord = try outboxRecord(from: sessionDirectory, chunkIndex: 0)
        let sessionMetadata = firstRecord.metadata

        let outstanding = [WatchChunkTransferIdentity(
            sessionId: sessionId,
            chunkIndex: 0,
            transferAttemptId: firstRecord.activeAttemptId ?? sessionMetadata.transferAttemptId
        )]

        let relaunchedTransferClient = FakeTransferClient()
        let controller = WatchChunkedCaptureController(
            documentsProvider: { harness.root },
            requestPermission: { true },
            transferClient: relaunchedTransferClient,
            resolveDuration: { _ in 60.0 },
            setupAudioSession: {},
            deactivateAudioSession: {},
            coordinatorProvider: { _, _, _ in
                XCTFail("recovery must not restart recorder")
                throw ScheduledChunkRecorderError.alreadyStarted
            },
            outstandingTransferKeysProvider: { Set(outstanding) }
        )

        controller.recoverAbandonedSessions()
        XCTAssertEqual(relaunchedTransferClient.calls.count, 0)
        XCTAssertEqual(controller.pendingTransferCount, 0)
    }

    func testRecoverRestartAcknowledgedChunkPerformsCleanupSafely() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        harness.controller.stop()
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 1)
        let metadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        let sessionId = try XCTUnwrap(metadata?.sessionId)
        let sessionDirectory = outboxSessionDirectory(in: harness.root, sessionId: sessionId)

        var sidecar = try outboxRecord(from: sessionDirectory, chunkIndex: 0)
        sidecar.transferState = .acknowledged
        sidecar.activeAttemptId = nil
        sidecar.metadata = WatchRecordingProbeMetadata(
            metadataVersion: sidecar.metadata.metadataVersion,
            sessionId: sidecar.metadata.sessionId,
            startedAt: sidecar.metadata.startedAt,
            endedAt: sidecar.metadata.endedAt,
            durationSec: sidecar.metadata.durationSec,
            fileName: sidecar.metadata.fileName,
            source: sidecar.metadata.source,
            chunkIndex: sidecar.metadata.chunkIndex,
            chunkStartOffsetSec: sidecar.metadata.chunkStartOffsetSec,
            chunkCount: sidecar.metadata.chunkCount,
            captureDiagnostics: sidecar.metadata.captureDiagnostics,
            transferAttemptId: sidecar.metadata.transferAttemptId
        )
        try writeOutboxRecord(sidecar, in: harness.root, sessionId: sessionId, chunkIndex: 0)

        let relaunched = makeHarness(documentsRoot: harness.root)
        relaunched.controller.recoverAbandonedSessions()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
        XCTAssertEqual(relaunched.controller.pendingTransferCount, 0)
    }

    func testRecoverRestartAcknowledgedWithMissingAudioIsSafe() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        harness.controller.stop()
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 1)
        let metadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        let sessionId = try XCTUnwrap(metadata?.sessionId)
        let sessionDirectory = outboxSessionDirectory(in: harness.root, sessionId: sessionId)

        var sidecar = try outboxRecord(from: sessionDirectory, chunkIndex: 0)
        sidecar.transferState = .acknowledged
        sidecar.activeAttemptId = nil
        try writeOutboxRecord(sidecar, in: harness.root, sessionId: sessionId, chunkIndex: 0)
        let audioURL = sessionDirectory
            .appendingPathComponent(AIWatchingSchema.chunkAudioFileName(chunkIndex: 0))
        if FileManager.default.fileExists(atPath: audioURL.path) {
            try FileManager.default.removeItem(at: audioURL)
        }

        let relaunched = makeHarness(documentsRoot: harness.root)
        relaunched.controller.recoverAbandonedSessions()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(relaunched.controller.pendingTransferCount, 0)
    }

    func testTransferCompletionPartialSuccessAndPartialFailure() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        coordinator.finishChunk(1)
        harness.controller.stop()
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 2)
        let first = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[0].metadata)
        let second = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[1].metadata)
        let sessionId = try XCTUnwrap(second?.sessionId)
        let sessionDir = outboxSessionDirectory(in: harness.root, sessionId: sessionId)
        let firstAudio = sessionDir.appendingPathComponent(AIWatchingSchema.chunkAudioFileName(chunkIndex: 0))
        let secondAudio = sessionDir.appendingPathComponent(AIWatchingSchema.chunkAudioFileName(chunkIndex: 1))

        XCTAssertTrue(FileManager.default.fileExists(atPath: firstAudio.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondAudio.path))

        let firstMetadata = try XCTUnwrap(first)
        let secondMetadata = try XCTUnwrap(second)
        harness.controller.handleTransferCompletion(metadata: firstMetadata, wasSuccessful: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstAudio.path))
        let firstSidecar = sessionDir.appendingPathComponent(
            AIWatchingSchema.chunkMetadataFileName(chunkIndex: 0)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstSidecar.path))
        XCTAssertEqual(harness.controller.pendingTransferCount, 0)

        harness.controller.handleApplicationAck(
            WatchChunkApplicationAck(
                sessionId: firstMetadata.sessionId,
                chunkIndex: firstMetadata.chunkIndex,
                transferAttemptId: firstMetadata.transferAttemptId!
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstAudio.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstSidecar.path))

        harness.controller.handleTransferCompletion(metadata: secondMetadata, wasSuccessful: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondAudio.path))
        XCTAssertEqual(harness.controller.pendingTransferCount, 1)
        let pendingSecond = try outboxRecord(from: sessionDir, chunkIndex: 1)
        XCTAssertEqual(pendingSecond.transferState, .pending)
    }

    func testTransferCompletionOutOfOrderAndCrossSessionSameChunkIndex() async throws {
        let harness = makeHarness()
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)

        coordinator.finishChunk(0)
        coordinator.finishChunk(1)
        harness.controller.stop()
        coordinator.finishChunk(2)
        coordinator.emitStopped()

        XCTAssertEqual(harness.transferClient.calls.count, 3)
        let metadata0 = harness.transferClient.calls[0].metadata
        let metadata1 = harness.transferClient.calls[1].metadata
        let metadata2 = harness.transferClient.calls[2].metadata
        let sessionId = try XCTUnwrap(WatchRecordingProbeMetadata(dictionary: metadata0)?.sessionId)
        let sessionDir = outboxSessionDirectory(in: harness.root, sessionId: sessionId)

        let firstMetadata = WatchRecordingProbeMetadata(dictionary: metadata0)
        let secondOutOfOrderMetadata = WatchRecordingProbeMetadata(dictionary: metadata1)
        let finalMetadata = WatchRecordingProbeMetadata(dictionary: metadata2)
        harness.controller.handleTransferCompletion(
            metadata: try XCTUnwrap(finalMetadata),
            wasSuccessful: true
        )
        harness.controller.handleTransferCompletion(
            metadata: try XCTUnwrap(firstMetadata),
            wasSuccessful: true
        )
        harness.controller.handleTransferCompletion(
            metadata: try XCTUnwrap(secondOutOfOrderMetadata),
            wasSuccessful: true
        )
        for metadata in [firstMetadata, secondOutOfOrderMetadata, finalMetadata].compactMap({ $0 }) {
            harness.controller.handleApplicationAck(
                WatchChunkApplicationAck(
                    sessionId: metadata.sessionId,
                    chunkIndex: metadata.chunkIndex,
                    transferAttemptId: metadata.transferAttemptId!
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDir.path))

        await harness.controller.start()
        let secondCoordinator = try XCTUnwrap(harness.coordinator)
        secondCoordinator.finishChunk(0)
        harness.controller.stop()
        secondCoordinator.emitStopped()
        XCTAssertEqual(harness.transferClient.calls.count, 4)

        let secondMetadata = WatchRecordingProbeMetadata(dictionary: harness.transferClient.calls[3].metadata)
        let secondMetadataSessionId = try XCTUnwrap(secondMetadata?.sessionId)
        XCTAssertNotEqual(sessionId, secondMetadataSessionId)
        harness.controller.handleTransferCompletion(
            metadata: try XCTUnwrap(secondMetadata),
            wasSuccessful: true
        )
        harness.controller.handleApplicationAck(
            WatchChunkApplicationAck(
                sessionId: secondMetadataSessionId,
                chunkIndex: secondMetadata!.chunkIndex,
                transferAttemptId: secondMetadata!.transferAttemptId!
            )
        )
        let secondSessionDir = outboxSessionDirectory(in: harness.root, sessionId: secondMetadataSessionId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondSessionDir.path))
    }

    func testRecoverAbandonedSessionsReconcilesStaleEnqueuedStateUsingOutstandingTransfers() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIWatchingChunked", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let harness = makeHarness(
            documentsRoot: root,
            outstandingTransferKeys: { [] }
        )
        await harness.controller.start()
        let coordinator = try XCTUnwrap(harness.coordinator)
        coordinator.finishChunk(0)
        harness.controller.stop()
        coordinator.emitStopped()

        let firstMetadata = harness.transferClient.calls[0].metadata
        let sessionId = try XCTUnwrap(WatchRecordingProbeMetadata(dictionary: firstMetadata)?.sessionId)
        let sessionDir = outboxSessionDirectory(in: root, sessionId: sessionId)
        let record = try outboxRecord(from: sessionDir, chunkIndex: 0)
        XCTAssertEqual(record.transferState, .enqueued)

        let relaunched = makeHarness(
            documentsRoot: root,
            outstandingTransferKeys: { [] }
        )
        relaunched.controller.recoverAbandonedSessions()
        let reconciled = try outboxRecord(from: sessionDir, chunkIndex: 0)
        XCTAssertEqual(relaunched.transferClient.calls.count, 1)
        XCTAssertEqual(reconciled.transferState, .enqueued)
        XCTAssertEqual(relaunched.controller.pendingTransferCount, 0)

        try? FileManager.default.removeItem(at: root)
    }

    func testPrimaryButtonAndCanonicalDeepLinkShareOneLocalCaptureSession() async throws {
        let harness = makeHarness()
        let router = WatchCaptureEntryRouter()

        let primaryHandled = await router.handle(.primaryButton, controller: harness.controller)
        let firstSessionId = try XCTUnwrap(harness.controller.currentSessionId)

        XCTAssertTrue(primaryHandled)
        XCTAssertEqual(harness.controller.state, .recording)

        let deepLinkHandled = await router.handle(
            .deepLink(try XCTUnwrap(URL(string: "aiwatching://start"))),
            controller: harness.controller
        )

        XCTAssertTrue(deepLinkHandled)
        XCTAssertEqual(harness.controller.state, .recording)
        XCTAssertEqual(harness.controller.currentSessionId, firstSessionId)
        XCTAssertEqual(harness.coordinators().count, 1)
    }

    func testNonCanonicalDeepLinksDoNotStartLocalCapture() async throws {
        let harness = makeHarness()
        let router = WatchCaptureEntryRouter()
        let nonCanonicalURLs = [
            "not-aiwatching://start",
            "aiwatching://stop",
            "aiwatching://start/extra",
            "aiwatching://start?query=value",
            "aiwatching://start#fragment",
            "aiwatching://user:password@start",
            "aiwatching://start:1234",
            "aiwatching://st%61rt",
            "aiwatching://start:",
        ]

        for rawURL in nonCanonicalURLs {
            let url = try XCTUnwrap(URL(string: rawURL), "Expected constructible URL: \(rawURL)")
            let handled = await router.handle(.deepLink(url), controller: harness.controller)
            XCTAssertFalse(handled, "Unexpectedly handled URL: \(rawURL)")
        }

        XCTAssertEqual(harness.controller.state, .idle)
        XCTAssertNil(harness.controller.currentSessionId)
        XCTAssertEqual(harness.coordinators().count, 0)
    }

    // MARK: - helpers

    private func outboxSessionDirectory(in root: URL, sessionId: String) -> URL {
        root
            .appendingPathComponent("watch-chunked-outbox", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
    }

    private func writeOutboxRecord(_ record: WatchChunkOutboxRecord, in root: URL, sessionId: String, chunkIndex: Int) throws {
        let sessionDirectory = outboxSessionDirectory(in: root, sessionId: sessionId)
        let url = sessionDirectory
            .appendingPathComponent(AIWatchingSchema.chunkMetadataFileName(chunkIndex: chunkIndex))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: url, options: [.atomic])
    }

    private func outboxRecord(from sessionDirectory: URL, chunkIndex: Int) throws -> WatchChunkOutboxRecord {
        let url = sessionDirectory.appendingPathComponent(AIWatchingSchema.chunkMetadataFileName(chunkIndex: chunkIndex))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WatchChunkOutboxRecord.self, from: data)
    }

    private func coordinatorStopAndFinish(_ coordinator: FakeCoordinator, finishing index: Int) {
        coordinator.finishChunk(index)
        coordinator.emitStopped()
    }

    private func diagnosticsURL(in root: URL, sessionId: String) -> URL {
        root
            .appendingPathComponent("watch-chunked-outbox", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent(WatchCaptureDiagnostics.watchCaptureDiagnosticsFileName)
    }

    private func loadDiagnostics(from url: URL) throws -> WatchCaptureDiagnostics {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(WatchCaptureDiagnostics.self, from: data)
    }

}
