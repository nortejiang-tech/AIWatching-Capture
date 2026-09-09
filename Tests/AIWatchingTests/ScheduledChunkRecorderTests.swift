import AVFoundation
import Foundation
import XCTest
@testable import AIWatching

private final class FakeScheduledCaptureRecorder: NSObject, ScheduledCaptureRecording {
    var delegate: AVAudioRecorderDelegate?
    var isRecording = false
    let url: URL
    var deviceCurrentTime: TimeInterval
    var prepareSucceeds = true
    var scheduleSucceeds = true
    private(set) var scheduledCalls: [(time: TimeInterval, duration: TimeInterval)] = []
    private(set) var stopCount = 0

    init(url: URL, deviceCurrentTime: TimeInterval = 100) {
        self.url = url
        self.deviceCurrentTime = deviceCurrentTime
    }

    func prepareToRecord() -> Bool {
        prepareSucceeds
    }

    func record(atTime time: TimeInterval, forDuration duration: TimeInterval) -> Bool {
        scheduledCalls.append((time, duration))
        return scheduleSucceeds
    }

    func stop() {
        stopCount += 1
        isRecording = false
    }
}

private final class FakeScheduledCaptureRecorderFactory: ScheduledCaptureRecorderFactory {
    private(set) var recorders: [FakeScheduledCaptureRecorder] = []
    var configure: ((Int, FakeScheduledCaptureRecorder) -> Void)?

    func makeRecorder(url: URL, settings: [String: Any]) throws -> ScheduledCaptureRecording {
        let recorder = FakeScheduledCaptureRecorder(url: url)
        configure?(recorders.count, recorder)
        recorders.append(recorder)
        return recorder
    }
}

@MainActor
final class ScheduledChunkRecorderTests: XCTestCase {
    func testConfigurationRejectsOverlapAboveMaximum() {
        XCTAssertThrowsError(
            try ScheduledChunkRecorder.Configuration(
                chunkDuration: 10,
                overlapDuration: 0.501
            ).validate()
        )
    }

    private func makeRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AIWatchingScheduledChunkTests")
            .appendingPathComponent(name)
            .appendingPathComponent(UUID().uuidString)
    }

    func testStartSchedulesOverlappingRecorderPairFromSharedDeviceClock() async throws {
        let root = makeRoot("start-pair")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = FakeScheduledCaptureRecorderFactory()
        var events: [ScheduledChunkRecorder.Event] = []
        var verificationDelays: [TimeInterval] = []
        let coordinator = ScheduledChunkRecorder(
            configuration: .init(chunkDuration: 10, overlapDuration: 0.25, initialLeadTime: 0.1),
            settings: [:],
            recorderFactory: factory,
            urlProvider: { index in root.appendingPathComponent("chunk_\(index).m4a") },
            verificationSleeper: { delay in
                verificationDelays.append(delay)
                factory.recorders[0].isRecording = true
            },
            eventHandler: { events.append($0) }
        )

        let first = try await coordinator.start()

        XCTAssertEqual(factory.recorders.count, 2)
        XCTAssertEqual(first.index, 0)
        XCTAssertEqual(first.scheduledDeviceTime, 100.1, accuracy: 0.000_001)
        XCTAssertEqual(first.startOffsetSec, 0, accuracy: 0.000_001)
        XCTAssertEqual(factory.recorders[0].scheduledCalls[0].time, 100.1, accuracy: 0.000_001)
        XCTAssertEqual(factory.recorders[0].scheduledCalls[0].duration, 10, accuracy: 0.000_001)
        XCTAssertEqual(factory.recorders[1].scheduledCalls[0].time, 109.85, accuracy: 0.000_001)
        XCTAssertFalse(factory.recorders[1].isRecording)
        XCTAssertEqual(verificationDelays.count, 1)
        XCTAssertEqual(verificationDelays[0], 0.15, accuracy: 0.000_001)
        let scheduledChunk = try XCTUnwrap(coordinator.scheduledChunk)
        XCTAssertEqual(scheduledChunk.startOffsetSec, 9.75, accuracy: 0.000_001)
        XCTAssertTrue(coordinator.isCapturing)
        XCTAssertTrue(events.isEmpty)

        try? FileManager.default.removeItem(at: root)
    }

    func testFirstScheduledRecorderMayBecomeActiveAfterInitialVerificationButWithinBoundedGrace() async throws {
        let root = makeRoot("first-recorder-bounded-grace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let factory = FakeScheduledCaptureRecorderFactory()
        var verificationDelays: [TimeInterval] = []
        var events: [ScheduledChunkRecorder.Event] = []
        let coordinator = ScheduledChunkRecorder(
            configuration: .init(chunkDuration: 10, overlapDuration: 0.25, initialLeadTime: 0.1),
            settings: [:],
            recorderFactory: factory,
            urlProvider: { index in root.appendingPathComponent("chunk_\(index).m4a") },
            verificationSleeper: { delay in
                verificationDelays.append(delay)
                if verificationDelays.count == 2 {
                    factory.recorders[0].isRecording = true
                }
            },
            eventHandler: { events.append($0) }
        )

        let chunk = try await coordinator.start()

        XCTAssertEqual(chunk.index, 0)
        XCTAssertTrue(coordinator.isCapturing)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(verificationDelays.count, 2)
        XCTAssertEqual(verificationDelays[0], 0.15, accuracy: 0.000_001)
        XCTAssertEqual(verificationDelays[1], 0.05, accuracy: 0.000_001)
    }

    func testFirstScheduledRecorderThatNeverActivatesFailsAfterBoundedGraceAndCleansSlots() async throws {
        let root = makeRoot("first-recorder-never-activates")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let factory = FakeScheduledCaptureRecorderFactory()
        var verificationDelays: [TimeInterval] = []
        var createdURLs: [URL] = []
        var events: [ScheduledChunkRecorder.Event] = []
        let coordinator = ScheduledChunkRecorder(
            configuration: .init(chunkDuration: 10, overlapDuration: 0.25, initialLeadTime: 0.1),
            settings: [:],
            recorderFactory: factory,
            urlProvider: { index in
                let url = root.appendingPathComponent("chunk_\(index).m4a")
                FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                createdURLs.append(url)
                return url
            },
            verificationSleeper: { delay in
                verificationDelays.append(delay)
            },
            eventHandler: { events.append($0) }
        )

        do {
            _ = try await coordinator.start()
            XCTFail("start should reject a first recorder that never activates")
        } catch let error as ScheduledChunkRecorderError {
            XCTAssertEqual(error, .firstRecorderDidNotStart)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(verificationDelays.count, 21)
        XCTAssertEqual(verificationDelays[0], 0.15, accuracy: 0.000_001)
        for delay in verificationDelays.dropFirst() {
            XCTAssertEqual(delay, 0.05, accuracy: 0.000_001)
        }
        XCTAssertEqual(factory.recorders.count, 2)
        XCTAssertEqual(factory.recorders.map(\.stopCount), [1, 1])
        XCTAssertEqual(createdURLs.count, 2)
        XCTAssertTrue(createdURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertFalse(coordinator.isCapturing)
        XCTAssertNil(coordinator.activeChunk)
        XCTAssertNil(coordinator.scheduledChunk)
        XCTAssertTrue(events.isEmpty)
    }

    func testFinishedActivePromotesScheduledAndSchedulesFollowingBeforeEventReturns() async throws {
        let root = makeRoot("promote")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = FakeScheduledCaptureRecorderFactory()
        var eventSnapshots: [(ScheduledChunkRecorder.Event, Int, Int?)] = []
        var coordinator: ScheduledChunkRecorder!
        coordinator = ScheduledChunkRecorder(
            configuration: .init(chunkDuration: 10, overlapDuration: 0.25, initialLeadTime: 0.1),
            settings: [:],
            recorderFactory: factory,
            urlProvider: { index in root.appendingPathComponent("chunk_\(index).m4a") },
            verificationSleeper: { _ in factory.recorders[0].isRecording = true },
            eventHandler: { event in
                eventSnapshots.append((event, factory.recorders.count, coordinator.scheduledChunk?.index))
            }
        )
        _ = try await coordinator.start()
        factory.recorders[1].isRecording = true
        factory.recorders[1].deviceCurrentTime = 110

        coordinator.debugRecorderDidFinish(factory.recorders[0], successfully: true)

        XCTAssertEqual(factory.recorders.count, 3)
        XCTAssertEqual(coordinator.activeChunk?.index, 1)
        XCTAssertEqual(coordinator.scheduledChunk?.index, 2)
        XCTAssertEqual(factory.recorders[2].scheduledCalls[0].time, 119.6, accuracy: 0.000_001)
        XCTAssertEqual(eventSnapshots.count, 1)
        XCTAssertEqual(eventSnapshots[0].0, .chunkFinished(
            .init(index: 0, url: root.appendingPathComponent("chunk_0.m4a"), scheduledDeviceTime: 100.1, startOffsetSec: 0),
            successfully: true
        ))
        XCTAssertEqual(eventSnapshots[0].1, 3)
        XCTAssertEqual(eventSnapshots[0].2, 2)

        try? FileManager.default.removeItem(at: root)
    }

    func testStopCancelsScheduledFileAndCompletesAfterActiveCallback() async throws {
        let root = makeRoot("stop")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = FakeScheduledCaptureRecorderFactory()
        var events: [ScheduledChunkRecorder.Event] = []
        let coordinator = ScheduledChunkRecorder(
            configuration: .init(chunkDuration: 10),
            settings: [:],
            recorderFactory: factory,
            urlProvider: { index in
                let url = root.appendingPathComponent("chunk_\(index).m4a")
                FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                return url
            },
            verificationSleeper: { _ in factory.recorders[0].isRecording = true },
            eventHandler: { events.append($0) }
        )
        _ = try await coordinator.start()
        let scheduledURL = factory.recorders[1].url
        factory.recorders[1].deviceCurrentTime = 100

        coordinator.stop()

        XCTAssertEqual(factory.recorders[1].stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scheduledURL.path))
        XCTAssertEqual(events, [])

        coordinator.debugRecorderDidFinish(factory.recorders[0], successfully: true)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0], .chunkFinished(
            .init(index: 0, url: factory.recorders[0].url, scheduledDeviceTime: 100.1, startOffsetSec: 0),
            successfully: true
        ))
        XCTAssertEqual(events[1], .stopped)

        coordinator.debugRecorderDidFinish(factory.recorders[1], successfully: true)
        XCTAssertEqual(events.count, 2)

        try? FileManager.default.removeItem(at: root)
    }

    func testStopDoesNotEmitFutureScheduledChunk() async throws {
        let root = makeRoot("stop-future-slot")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = FakeScheduledCaptureRecorderFactory()
        var events: [ScheduledChunkRecorder.Event] = []
        let coordinator = ScheduledChunkRecorder(
            configuration: .init(chunkDuration: 10),
            settings: [:],
            recorderFactory: factory,
            urlProvider: { index in
                let url = root.appendingPathComponent("chunk_\(index).m4a")
                FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                return url
            },
            verificationSleeper: { _ in factory.recorders[0].isRecording = true },
            eventHandler: { events.append($0) }
        )
        _ = try await coordinator.start()

        let first = factory.recorders[0]
        let second = factory.recorders[1]
        second.isRecording = true
        second.deviceCurrentTime = 105
        let scheduledURL = second.url

        coordinator.stop()

        XCTAssertEqual(second.stopCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scheduledURL.path))

        coordinator.debugRecorderDidFinish(first, successfully: true)
        XCTAssertEqual(events, [
            .chunkFinished(
                .init(index: 0, url: first.url, scheduledDeviceTime: 100.1, startOffsetSec: 0),
                successfully: true
            ),
            .stopped
        ])

        coordinator.debugRecorderDidFinish(second, successfully: true)
        XCTAssertEqual(events.count, 2)

        try? FileManager.default.removeItem(at: root)
    }

    func testScheduledRecorderFinishingAfterScheduledTimeIsNotIgnored() async throws {
        let root = makeRoot("scheduled-finish-after-start")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = FakeScheduledCaptureRecorderFactory()
        var events: [ScheduledChunkRecorder.Event] = []
        let coordinator = ScheduledChunkRecorder(
            configuration: .init(chunkDuration: 10),
            settings: [:],
            recorderFactory: factory,
            urlProvider: { index in root.appendingPathComponent("chunk_\(index).m4a") },
            verificationSleeper: { _ in factory.recorders[0].isRecording = true },
            eventHandler: { events.append($0) }
        )
        _ = try await coordinator.start()

        let scheduledRecorder = factory.recorders[1]
        scheduledRecorder.deviceCurrentTime = 110
        scheduledRecorder.isRecording = false
        coordinator.debugRecorderDidFinish(scheduledRecorder, successfully: false)

        XCTAssertEqual(events, [
            .failed("Scheduled recorder finished before promotion for chunk 1."),
            .stopped
        ])
        try? FileManager.default.removeItem(at: root)
    }

    func testStaleEncodeErrorDoesNotFailCurrentCoordinator() async throws {
        let root = makeRoot("stale-encode-error")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = FakeScheduledCaptureRecorderFactory()
        var events: [ScheduledChunkRecorder.Event] = []
        let coordinator = ScheduledChunkRecorder(
            configuration: .init(chunkDuration: 10),
            settings: [:],
            recorderFactory: factory,
            urlProvider: { index in root.appendingPathComponent("chunk_\(index).m4a") },
            verificationSleeper: { _ in factory.recorders[0].isRecording = true },
            eventHandler: { events.append($0) }
        )
        _ = try await coordinator.start()
        let staleRecorder = try factory.makeRecorder(
            url: root.appendingPathComponent("stale.m4a"),
            settings: [:]
        )

        coordinator.debugRecorderEncodeError(staleRecorder, error: nil)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(coordinator.isCapturing)

        coordinator.debugRecorderEncodeError(factory.recorders[0], error: nil)
        XCTAssertEqual(events, [
            .failed("Scheduled recorder encoding failed: unknown."),
            .stopped
        ])
        try? FileManager.default.removeItem(at: root)
    }

    func testResumeConfigurationUsesStartingIndexAndOffset() async throws {
        let root = makeRoot("resume-index-offset")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = FakeScheduledCaptureRecorderFactory()
        let coordinator = ScheduledChunkRecorder(
            configuration: .init(
                chunkDuration: 10,
                startingChunkIndex: 4,
                startingStartOffsetSec: 42
            ),
            settings: [:],
            recorderFactory: factory,
            urlProvider: { index in root.appendingPathComponent("chunk_\(index).m4a") },
            verificationSleeper: { _ in factory.recorders[0].isRecording = true },
            eventHandler: { _ in }
        )

        let first = try await coordinator.start()
        XCTAssertEqual(first.index, 4)
        XCTAssertEqual(first.startOffsetSec, 42)
        XCTAssertEqual(coordinator.scheduledChunk?.index, 5)
        XCTAssertEqual(coordinator.scheduledChunk?.startOffsetSec, 51.75)
        try? FileManager.default.removeItem(at: root)
    }

    func testStopPromotesAndEmitsStartedScheduledChunk() async throws {
        let root = makeRoot("stop-started-slot")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = FakeScheduledCaptureRecorderFactory()
        var events: [ScheduledChunkRecorder.Event] = []
        let coordinator = ScheduledChunkRecorder(
            configuration: .init(chunkDuration: 10),
            settings: [:],
            recorderFactory: factory,
            urlProvider: { index in
                let url = root.appendingPathComponent("chunk_\(index).m4a")
                FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                return url
            },
            verificationSleeper: { _ in factory.recorders[0].isRecording = true },
            eventHandler: { events.append($0) }
        )
        _ = try await coordinator.start()

        let first = factory.recorders[0]
        let second = factory.recorders[1]
        second.isRecording = true
        second.deviceCurrentTime = 200

        coordinator.stop()

        coordinator.debugRecorderDidFinish(second, successfully: true)
        coordinator.debugRecorderDidFinish(first, successfully: true)

        XCTAssertEqual(events, [
            .chunkFinished(
                .init(index: 0, url: first.url, scheduledDeviceTime: 100.1, startOffsetSec: 0),
                successfully: true
            ),
            .chunkFinished(
                .init(index: 1, url: second.url, scheduledDeviceTime: 109.85, startOffsetSec: 9.75),
                successfully: true
            ),
            .stopped
        ])

        try? FileManager.default.removeItem(at: root)
    }

    func testStopBoundarySlotAtScheduledTimeTreatedAsStarted() async throws {
        let root = makeRoot("stop-boundary-slot")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = FakeScheduledCaptureRecorderFactory()
        var events: [ScheduledChunkRecorder.Event] = []
        let coordinator = ScheduledChunkRecorder(
            configuration: .init(chunkDuration: 10),
            settings: [:],
            recorderFactory: factory,
            urlProvider: { index in
                let url = root.appendingPathComponent("chunk_\(index).m4a")
                FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                return url
            },
            verificationSleeper: { _ in factory.recorders[0].isRecording = true },
            eventHandler: { events.append($0) }
        )
        _ = try await coordinator.start()

        let first = factory.recorders[0]
        let second = factory.recorders[1]
        second.isRecording = true
        second.deviceCurrentTime = 109.85

        coordinator.stop()

        coordinator.debugRecorderDidFinish(first, successfully: true)
        coordinator.debugRecorderDidFinish(second, successfully: true)

        XCTAssertEqual(events, [
            .chunkFinished(
                .init(index: 0, url: first.url, scheduledDeviceTime: 100.1, startOffsetSec: 0),
                successfully: true
            ),
            .chunkFinished(
                .init(index: 1, url: second.url, scheduledDeviceTime: 109.85, startOffsetSec: 9.75),
                successfully: true
            ),
            .stopped
        ])

        try? FileManager.default.removeItem(at: root)
    }

    func testHandoffFailsWhenScheduledRecorderIsNotRecording() async throws {
        let root = makeRoot("handoff-failure")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = FakeScheduledCaptureRecorderFactory()
        var events: [ScheduledChunkRecorder.Event] = []
        let coordinator = ScheduledChunkRecorder(
            configuration: .init(chunkDuration: 10),
            settings: [:],
            recorderFactory: factory,
            urlProvider: { index in root.appendingPathComponent("chunk_\(index).m4a") },
            verificationSleeper: { _ in factory.recorders[0].isRecording = true },
            eventHandler: { events.append($0) }
        )
        _ = try await coordinator.start()
        factory.recorders[1].isRecording = false

        coordinator.debugRecorderDidFinish(factory.recorders[0], successfully: true)

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0], .chunkFinished(
            .init(index: 0, url: factory.recorders[0].url, scheduledDeviceTime: 100.1, startOffsetSec: 0),
            successfully: true
        ))
        XCTAssertEqual(events[1], .failed("Scheduled recorder did not start for chunk 1."))
        XCTAssertEqual(events[2], .stopped)
        XCTAssertNil(coordinator.activeChunk)
        XCTAssertNil(coordinator.scheduledChunk)

        try? FileManager.default.removeItem(at: root)
    }

    func testStopDuringHandoffPreservesRunningScheduledChunkAndOrdersCallbacks() async throws {
        let root = makeRoot("stop-during-handoff")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = FakeScheduledCaptureRecorderFactory()
        var events: [ScheduledChunkRecorder.Event] = []
        let coordinator = ScheduledChunkRecorder(
            configuration: .init(chunkDuration: 10),
            settings: [:],
            recorderFactory: factory,
            urlProvider: { index in
                let url = root.appendingPathComponent("chunk_\(index).m4a")
                FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                return url
            },
            verificationSleeper: { _ in factory.recorders[0].isRecording = true },
            eventHandler: { events.append($0) }
        )
        _ = try await coordinator.start()
        let first = factory.recorders[0]
        let second = factory.recorders[1]
        first.isRecording = false
        second.isRecording = true
        second.deviceCurrentTime = 120

        coordinator.stop()

        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertEqual(coordinator.activeChunk?.index, 1)
        XCTAssertNil(coordinator.scheduledChunk)
        XCTAssertEqual(first.stopCount, 1)
        XCTAssertEqual(second.stopCount, 1)
        XCTAssertTrue(events.isEmpty)

        coordinator.debugRecorderDidFinish(second, successfully: true)
        XCTAssertTrue(events.isEmpty, "chunk 1 must wait for delayed chunk 0 callback")

        coordinator.debugRecorderDidFinish(first, successfully: true)
        XCTAssertEqual(events, [
            .chunkFinished(
                .init(index: 0, url: first.url, scheduledDeviceTime: 100.1, startOffsetSec: 0),
                successfully: true
            ),
            .chunkFinished(
                .init(index: 1, url: second.url, scheduledDeviceTime: 109.85, startOffsetSec: 9.75),
                successfully: true
            ),
            .stopped
        ])
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))

        try? FileManager.default.removeItem(at: root)
    }

    func testMissingAnchorEmitsFinishedChunkOnlyOnceBeforeFailure() async throws {
        let root = makeRoot("missing-anchor")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = FakeScheduledCaptureRecorderFactory()
        var events: [ScheduledChunkRecorder.Event] = []
        let coordinator = ScheduledChunkRecorder(
            configuration: .init(chunkDuration: 10),
            settings: [:],
            recorderFactory: factory,
            urlProvider: { index in root.appendingPathComponent("chunk_\(index).m4a") },
            verificationSleeper: { _ in factory.recorders[0].isRecording = true },
            eventHandler: { events.append($0) }
        )
        _ = try await coordinator.start()
        factory.recorders[1].isRecording = true
        factory.recorders[1].deviceCurrentTime = 120
        coordinator.debugClearAnchorTime()

        coordinator.debugRecorderDidFinish(factory.recorders[0], successfully: true)

        XCTAssertEqual(events.filter {
            if case .chunkFinished = $0 { return true }
            return false
        }.count, 1)
        XCTAssertEqual(events, [
            .chunkFinished(
                .init(index: 0, url: factory.recorders[0].url, scheduledDeviceTime: 100.1, startOffsetSec: 0),
                successfully: true
            ),
            .failed("Scheduled recorder anchor time is missing."),
            .stopped
        ])

        try? FileManager.default.removeItem(at: root)
    }

    func testFollowingRecorderSchedulingFailurePreservesFinishedChunkOnce() async throws {
        let root = makeRoot("following-schedule-failure")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let factory = FakeScheduledCaptureRecorderFactory()
        factory.configure = { index, recorder in
            if index == 2 {
                recorder.scheduleSucceeds = false
            }
        }
        var events: [ScheduledChunkRecorder.Event] = []
        let coordinator = ScheduledChunkRecorder(
            configuration: .init(chunkDuration: 10),
            settings: [:],
            recorderFactory: factory,
            urlProvider: { index in root.appendingPathComponent("chunk_\(index).m4a") },
            verificationSleeper: { _ in factory.recorders[0].isRecording = true },
            eventHandler: { events.append($0) }
        )
        _ = try await coordinator.start()
        factory.recorders[1].isRecording = true
        factory.recorders[1].deviceCurrentTime = 120

        coordinator.debugRecorderDidFinish(factory.recorders[0], successfully: true)

        XCTAssertEqual(events, [
            .chunkFinished(
                .init(index: 0, url: factory.recorders[0].url, scheduledDeviceTime: 100.1, startOffsetSec: 0),
                successfully: true
            ),
            .failed("Recorder scheduling failed for chunk 2."),
            .stopped
        ])
        XCTAssertNil(coordinator.activeChunk)
        XCTAssertNil(coordinator.scheduledChunk)

        try? FileManager.default.removeItem(at: root)
    }
}
