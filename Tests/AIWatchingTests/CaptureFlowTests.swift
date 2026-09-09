import Foundation
import AVFoundation
import XCTest
import WatchConnectivity
@testable import AIWatching

private final class FakeCaptureRecorder: NSObject, CaptureRecording {
    private var _delegate: AVAudioRecorderDelegate?
    private(set) var events: [String] = []
    var onStop: (() -> Void)?
    var onEvent: ((String) -> Void)?

    var delegate: AVAudioRecorderDelegate? {
        get { _delegate }
        set {
            if newValue == nil {
                events.append("delegate=nil")
                onEvent?("delegate=nil")
            } else {
                events.append("delegate=set")
                onEvent?("delegate=set")
            }
            _delegate = newValue
        }
    }

    var isRecording: Bool
    let url: URL
    private let prepareSucceeds: Bool
    private let recordSucceeds: Bool

    init(url: URL, prepareSucceeds: Bool = true, recordSucceeds: Bool = true) {
        self.url = url
        self.prepareSucceeds = prepareSucceeds
        self.recordSucceeds = recordSucceeds
        self.isRecording = false
        super.init()
    }

    func prepareToRecord() -> Bool {
        events.append("prepare")
        onEvent?("prepare")
        return prepareSucceeds
    }

    func record(forDuration: TimeInterval) -> Bool {
        events.append("record")
        onEvent?("record")
        isRecording = recordSucceeds
        return recordSucceeds
    }

    func stop() {
        events.append("stop")
        onEvent?("stop")
        isRecording = false
        onStop?()
    }
}

@MainActor
private final class FakeScheduledChunkCoordinator: NSObject, ScheduledChunkRecorderLike {
    private let startResult: Result<ScheduledChunkRecorder.Chunk, Error>
    private(set) var startInvocations = 0
    private(set) var stopInvocations = 0
    private let startCapturing: Bool

    var activeChunk: ScheduledChunkRecorder.Chunk?
    var scheduledChunk: ScheduledChunkRecorder.Chunk?
    var isCapturing: Bool

    init(
        startResult: Result<ScheduledChunkRecorder.Chunk, Error>,
        activeChunk: ScheduledChunkRecorder.Chunk? = nil,
        scheduledChunk: ScheduledChunkRecorder.Chunk? = nil,
        isCapturing: Bool = false
    ) {
        self.startResult = startResult
        self.activeChunk = activeChunk
        self.scheduledChunk = scheduledChunk
        self.startCapturing = isCapturing
        self.isCapturing = isCapturing
    }

    @discardableResult
    func start() async throws -> ScheduledChunkRecorder.Chunk {
        startInvocations += 1
        switch startResult {
        case .failure(let error):
            isCapturing = false
            throw error
        case .success(let chunk):
            isCapturing = startCapturing
            if activeChunk == nil {
                activeChunk = chunk
            }
            return chunk
        }
    }

    func stop() {
        stopInvocations += 1
        isCapturing = false
    }
}

private actor ResolvingChunkDurationGate {
    enum ResolutionError: Error {
        case missingDuration
    }

    private let durations: [Int: TimeInterval]
    private var released = Set<Int>()
    private var waiting: [Int: [CheckedContinuation<TimeInterval, Error>]] = [:]

    init(_ durations: [Int: TimeInterval]) {
        self.durations = durations
    }

    func resolve(index: Int) async throws -> TimeInterval {
        guard let duration = durations[index] else {
            throw ResolutionError.missingDuration
        }
        if released.contains(index) {
            return duration
        }
        return try await withCheckedThrowingContinuation { continuation in
            var bucket = waiting[index] ?? []
            bucket.append(continuation)
            waiting[index] = bucket
        }
    }

    func release(_ index: Int) {
        released.insert(index)
        let continuations = waiting[index] ?? []
        waiting[index] = nil
        guard let duration = durations[index] else { return }
        continuations.forEach { $0.resume(returning: duration) }
    }
}

private extension CaptureController {
    func makeTemporaryRoot(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AIWatchingTests")
            .appendingPathComponent(name)
    }
}

actor PermissionRequestGate {
    private var continuations: [CheckedContinuation<Bool, Never>] = []
    private let expectations: [XCTestExpectation]

    init(expectations: [XCTestExpectation]) {
        self.expectations = expectations
    }

    func request() async -> Bool {
        await withCheckedContinuation { continuation in
            let index = continuations.count
            continuations.append(continuation)
            if index < expectations.count {
                expectations[index].fulfill()
            }
        }
    }

    func resume(_ index: Int, value: Bool) -> Bool {
        guard continuations.indices.contains(index) else {
            return false
        }
        let continuation = continuations.remove(at: index)
        continuation.resume(returning: value)
        return true
    }
}

actor AsyncSignal {
    private var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        if let continuation = waiters.popLast() {
            continuation.resume()
        } else {
            count += 1
        }
    }

    func wait() async {
        if count > 0 {
            count -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

actor Counter {
    private var value = 0

    func increment() {
        value += 1
    }

    func read() -> Int {
        value
    }
}

@MainActor
final class CaptureFlowTests: XCTestCase {
    func awaitSessionArtifacts(_ directory: URL, timeout: TimeInterval = 1.0) async throws -> (SessionStatus, SessionManifest) {
        let statusURL = directory.appendingPathComponent(AIWatchingSchema.statusFileName)
        let manifestURL = directory.appendingPathComponent(AIWatchingSchema.manifestFileName)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            do {
                let statusData = try Data(contentsOf: statusURL)
                let manifestData = try Data(contentsOf: manifestURL)
                let status = try JSONDecoder().decode(SessionStatus.self, from: statusData)
                let manifest = try JSONDecoder().decode(SessionManifest.self, from: manifestData)
                return (status, manifest)
            } catch {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        throw NSError(
            domain: "CaptureFlowTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for session artifacts at \(directory.path)"]
        )
    }

    private func isoDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: text)
    }

    func testInterruptionBeganThenFinishThenEndedResumesOnce() {
        var flow = CaptureInterruptionFlow()
        flow.markRecording()

        XCTAssertEqual(flow.handle(.interruptionBegan), .stopCurrentRecorder)
        XCTAssertEqual(flow.handle(.currentChunkFinished), .none)
        XCTAssertEqual(flow.handle(.interruptionEnded(shouldResume: true)), .startNextRecorder)
        XCTAssertEqual(flow.handle(.interruptionEnded(shouldResume: true)), .none)
    }

    func testInterruptionBeganThenEndedThenFinishResumesOnce() {
        var flow = CaptureInterruptionFlow()
        flow.markRecording()

        XCTAssertEqual(flow.handle(.interruptionBegan), .stopCurrentRecorder)
        XCTAssertEqual(flow.handle(.interruptionEnded(shouldResume: true)), .none)
        XCTAssertEqual(flow.handle(.currentChunkFinished), .startNextRecorder)
        XCTAssertEqual(flow.handle(.currentChunkFinished), .none)
    }

    func testInterruptionWithoutResumeCompletes() {
        var flow = CaptureInterruptionFlow()
        flow.markRecording()

        XCTAssertEqual(flow.handle(.interruptionBegan), .stopCurrentRecorder)
        XCTAssertEqual(flow.handle(.currentChunkFinished), .none)
        XCTAssertEqual(flow.handle(.interruptionEnded(shouldResume: false)), .completeSession)
        XCTAssertEqual(flow.handle(.interruptionEnded(shouldResume: false)), .none)
    }

    func testStaleRecorderCallbackDoesNotChangeCurrentRecorderGate() {
        final class FakeRecorder {}

        var gate = CaptureRecorderIdentityGate()
        let current = FakeRecorder()
        let stale = FakeRecorder()

        gate.arm(current)
        XCTAssertTrue(gate.accepts(current))
        XCTAssertFalse(gate.accepts(stale))
        XCTAssertFalse(gate.clearIfCurrent(stale))
        XCTAssertTrue(gate.accepts(current))
        XCTAssertTrue(gate.clearIfCurrent(current))
        XCTAssertFalse(gate.accepts(current))
    }

    func testStartPermissionWaitThenStopAThenStartBThenResumeALeavesBStateIntact() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("permission-wait")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let requestAExpectation = expectation(description: "permission request A")
        let requestBExpectation = expectation(description: "permission request B")
        let permissionGate = PermissionRequestGate(expectations: [requestAExpectation, requestBExpectation])

        var startedSessions: [URL] = []

        controller.installTestDependencies(
            .init(
                requestPermission: {
                    return await permissionGate.request()
                },
                configureSession: {
                    return
                },
                deactivateSession: {
                    return
                },
                recordingsRoot: {
                    return tempRoot
                },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    startedSessions.append(session)
                    return session
                },
                createRecorder: { url, _ in
                    FakeCaptureRecorder(url: url)
                }
            )
        )

        let startTaskA = Task {
            await controller.startCapture()
        }
        await fulfillment(of: [requestAExpectation], timeout: 1.0)

        await controller.stopCapture()

        let startTaskB = Task {
            await controller.startCapture()
        }
        await fulfillment(of: [requestBExpectation], timeout: 1.0)

        let resumedB = await permissionGate.resume(1, value: true)
        if !resumedB {
            XCTFail("permission continuation 不足：B")
            return
        }
        let resumedA = await permissionGate.resume(0, value: false)
        if !resumedA {
            XCTFail("permission continuation 不足：A")
            return
        }

        let resultA = await startTaskA.value
        let resultB = await startTaskB.value

        XCTAssertFalse(resultA.ok)
        XCTAssertEqual(resultA.message, "会话已切换，开始取消。")
        XCTAssertTrue(resultB.ok)

        let stableToken = controller.debugSessionToken
        let stableRecorder = controller.debugRecorder
        let stableDirectory = controller.debugSessionDirectory
        let stableLifecycle = controller.debugLifecycle

        XCTAssertNotNil(stableToken)
        XCTAssertNotNil(stableDirectory)
        XCTAssertEqual(stableLifecycle, "recording")

        guard
            let stableToken,
            let stableRecorder,
            let stableRecorderObjectID = controller.debugRecorderObjectID,
            let stableDirectory
        else {
            XCTFail("stable B session info missing")
            return
        }
        XCTAssertEqual(stableDirectory.deletingLastPathComponent().path, tempRoot.path)
        XCTAssertEqual(stableToken, controller.debugSessionToken)
        XCTAssertEqual(stableRecorderObjectID, controller.debugRecorderObjectID)
        XCTAssertEqual(stableDirectory, controller.debugSessionDirectory)
        XCTAssertEqual(controller.debugLifecycle, "recording")
        XCTAssertEqual(stableToken, controller.debugSessionToken)
        XCTAssertEqual(ObjectIdentifier(stableRecorder), controller.debugRecorderObjectID)
        XCTAssertEqual(stableDirectory, controller.debugSessionDirectory)
        XCTAssertEqual(stableLifecycle, controller.debugLifecycle)
        XCTAssertEqual(startedSessions.count, 1)

        try? FileManager.default.removeItem(at: root)
    }

    func testQueuedInterruptionStopActionDoesNotStopReplacedRecorder() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("stale-interruption-stop-action")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var createdRecorders: [FakeCaptureRecorder] = []
        var chunkDurations: [URL: TimeInterval] = [:]
        let firstRecorderCreated = AsyncSignal()
        let secondRecorderReady = AsyncSignal()
        let staleActionStopCounter = Counter()
        var queuedInterruptionActions: [() async -> Void] = []

        controller.installTestDependencies(
            .init(
                requestPermission: {
                    return true
                },
                configureSession: {
                    return
                },
                deactivateSession: {
                    return
                },
                recordingsRoot: {
                    return tempRoot
                },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    return session
                },
                createRecorder: { url, _ in
                    chunkDurations[url] = 0.3
                    let recorder = FakeCaptureRecorder(url: url)
                    createdRecorders.append(recorder)
                    if createdRecorders.count == 1 {
                        Task { await firstRecorderCreated.signal() }
                    }
                    if createdRecorders.count == 2 {
                        Task { await secondRecorderReady.signal() }
                    }
                    return recorder
                },
                resolveFinalizedChunkDuration: { url in
                    guard let duration = chunkDurations[url] else {
                        throw NSError(domain: "CaptureFlowTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing chunk duration for \(url.path)"])
                    }
                    return duration
                },
                scheduleInterruptionAction: { action in
                    queuedInterruptionActions.append(action)
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertEqual(result.ok, true, "startCapture failed: \(result.message)")
        guard let firstRecorder = createdRecorders.first else {
            XCTFail("firstRecorder missing")
            return
        }
        firstRecorder.onStop = {
            Task { await staleActionStopCounter.increment() }
        }

        controller.debugHandleInterruption(.began)
        controller.debugHandleInterruption(.ended, shouldResume: true)
        await firstRecorderCreated.wait()
        guard let token = controller.debugSessionToken else {
            XCTFail("sessionToken missing")
            return
        }
        await controller.debugResolveRecorderFinish(firstRecorder, success: true, token: token)
        await secondRecorderReady.wait()
        XCTAssertFalse(queuedInterruptionActions.isEmpty)
        if let delayedAction = queuedInterruptionActions.first {
            await delayedAction()
            queuedInterruptionActions.removeFirst()
        }

        guard let secondRecorder = createdRecorders.last,
              let secondRecorderID = controller.debugRecorderObjectID else {
            XCTFail("secondRecorder missing")
            return
        }
        XCTAssertEqual(ObjectIdentifier(secondRecorder), secondRecorderID)
        XCTAssertEqual(secondRecorder.events, ["delegate=set", "prepare", "record"])
        XCTAssertFalse(secondRecorder.events.contains("stop"))
        XCTAssertEqual(createdRecorders.last?.isRecording, true)
        try? await Task.sleep(for: .milliseconds(200))
        let staleActionStopCount = await staleActionStopCounter.read()
        XCTAssertEqual(staleActionStopCount, 0)

        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testOldRecorderCallbackHasNoEffectOnCurrentChunkState() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("old-callback")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let firstRecorder = FakeCaptureRecorder(url: tempRoot.appendingPathComponent("first.m4a"))
        let staleRecorder = FakeCaptureRecorder(url: tempRoot.appendingPathComponent("stale.m4a"))

        controller.installTestDependencies(
            .init(
                requestPermission: {
                    return true
                },
                configureSession: {
                    return
                },
                deactivateSession: {
                    return
                },
                recordingsRoot: {
                    return tempRoot
                },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    return session
                },
                createRecorder: { _, _ in
                    firstRecorder
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let currentToken = controller.debugSessionToken else {
            XCTFail("sessionToken missing")
            return
        }

        await controller.debugResolveRecorderFinish(staleRecorder, success: true, token: currentToken)

        guard let debugRecorderObjectID = controller.debugRecorderObjectID else {
            XCTFail("debugRecorderObjectID missing")
            return
        }
        XCTAssertEqual(ObjectIdentifier(firstRecorder), debugRecorderObjectID)
        XCTAssertTrue(firstRecorder.isRecording)
        XCTAssertEqual(firstRecorder.events, ["delegate=set", "prepare", "record"])

        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testFailedChunkPreparationCleansCapturedChunkFile() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("failed-chunk")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let sessionID = UUID().uuidString
        var createdFileURL: URL?

        controller.installTestDependencies(
            .init(
                requestPermission: {
                    return true
                },
                configureSession: {
                    return
                },
                deactivateSession: {
                    return
                },
                recordingsRoot: {
                    return tempRoot
                },
                createSessionDirectory: { _, _, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionID)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    return session
                },
                createRecorder: { url, _ in
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                    createdFileURL = url
                    return FakeCaptureRecorder(url: url, prepareSucceeds: false)
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertFalse(result.ok)

        XCTAssertNil(controller.debugSessionDirectory)
        XCTAssertNil(controller.debugSessionRoot)
        if let createdFileURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: createdFileURL.path))
        }

        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testPersistActiveSessionFailureRollsBackStartedSessionAndDeletesProvisionalDirectory() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("persist-active-session-failure")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var createdSessionURL: URL?
        var createdRecorder: FakeCaptureRecorder?
        var events: [String] = []
        var recorderEventsAtDeactivation: [String] = []
        var deactivateCount = 0

        controller.installTestDependencies(
            .init(
                requestPermission: {
                    return true
                },
                configureSession: {
                    events.append("configure")
                },
                deactivateSession: {
                    deactivateCount += 1
                    recorderEventsAtDeactivation = createdRecorder?.events ?? []
                    events.append("deactivate")
                },
                recordingsRoot: {
                    return tempRoot
                },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    createdSessionURL = session
                    events.append("make-session")
                    return session
                },
                createRecorder: { url, _ in
                    events.append("create-recorder")
                    let recorder = FakeCaptureRecorder(url: url)
                    recorder.onEvent = { event in
                        events.append(event)
                    }
                    createdRecorder = recorder
                    return recorder
                },
                persistActiveSession: { _, _ in
                    events.append("persist")
                    throw CaptureError.noSessionDirectory
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "开始失败：Missing session directory.")
        XCTAssertEqual(events.filter { $0 == "deactivate" }.count, 1)
        guard let recorder = createdRecorder else {
            XCTFail("recorder missing")
            return
        }
        XCTAssertEqual(
            recorder.events,
            ["delegate=set", "prepare", "record", "delegate=nil", "stop"]
        )
        let expectedOrder = [
            "configure",
            "make-session",
            "create-recorder",
            "delegate=set",
            "prepare",
            "record",
            "persist",
            "delegate=nil",
            "stop",
            "deactivate"
        ]
        XCTAssertEqual(events, expectedOrder)

        XCTAssertEqual(recorderEventsAtDeactivation, recorder.events)
        XCTAssertNil(controller.debugSessionToken)
        XCTAssertNil(controller.debugSessionDirectory)
        XCTAssertNil(controller.debugSessionRoot)
        XCTAssertNil(controller.debugCurrentChunkURL)
        XCTAssertEqual(controller.debugLifecycle, "idle")
        XCTAssertNil(controller.debugRecorder)
        XCTAssertEqual(deactivateCount, 1)

        guard let createdSessionURL else {
            XCTFail("created session url missing")
            return
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: createdSessionURL.path))
        XCTAssertTrue(events.contains("persist"))
        XCTAssertNil(controller.lastWriteError)

        try? FileManager.default.removeItem(at: root)
    }

    func testShortInterruptionChunkStillSubmitsCurrentChunkFinishedAndCanResume() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("short-interruption")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var createdRecorders: [FakeCaptureRecorder] = []
        var chunkDurations: [URL: TimeInterval] = [:]
        var recorderIndex = 0

        controller.installTestDependencies(
            .init(
                requestPermission: {
                    return true
                },
                configureSession: {
                    return
                },
                deactivateSession: {
                    return
                },
                recordingsRoot: {
                    return tempRoot
                },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    return session
                },
                createRecorder: { url, _ in
                    let duration = recorderIndex == 0 ? 0.1 : 0.3
                    chunkDurations[url] = duration
                    let recorder = FakeCaptureRecorder(url: url)
                    createdRecorders.append(recorder)
                    recorderIndex += 1
                    return recorder
                },
                resolveFinalizedChunkDuration: { url in
                    guard let duration = chunkDurations[url] else {
                        throw NSError(domain: "CaptureFlowTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing chunk duration for \(url.path)"])
                    }
                    return duration
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken else {
            XCTFail("sessionToken missing")
            return
        }

        let firstRecorderStopped = expectation(description: "first recorder stopped")
        createdRecorders.first?.onStop = {
            firstRecorderStopped.fulfill()
        }

        controller.debugHandleInterruption(.began)
        controller.debugHandleInterruption(.ended, shouldResume: true)
        await fulfillment(of: [firstRecorderStopped], timeout: 1.0)

        guard let firstRecorder = createdRecorders.first else {
            XCTFail("firstRecorder missing")
            return
        }
        await controller.debugResolveRecorderFinish(firstRecorder, success: true, token: token)

        XCTAssertEqual(recorderIndex, 2)
        XCTAssertEqual(controller.debugLifecycle, "recording")
        guard let lastRecorder = createdRecorders.last,
              let debugRecorderObjectID = controller.debugRecorderObjectID else {
            XCTFail("debugRecorderObjectID or last recorder missing")
            return
        }
        XCTAssertEqual(ObjectIdentifier(lastRecorder), debugRecorderObjectID)
        XCTAssertFalse(createdRecorders.first?.isRecording ?? true)

        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testFactoryFailureAfterSuccessfulChunkCleansFailedChunkAndCompletesPartialSession() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("factory-failure-partial")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var recorderIndex = 0
        var chunkDurations: [URL: TimeInterval] = [:]
        var firstChunkFile: URL?
        var secondChunkFile: URL?
        var sessionDirectory: URL?

        controller.installTestDependencies(
            .init(
                requestPermission: {
                    return true
                },
                configureSession: {
                    return
                },
                deactivateSession: {
                    return
                },
                recordingsRoot: {
                    return tempRoot
                },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    sessionDirectory = session
                    return session
                },
                createRecorder: { url, _ in
                    if recorderIndex == 0 {
                        firstChunkFile = url
                        chunkDurations[url] = 0.3
                        FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                        recorderIndex += 1
                        return FakeCaptureRecorder(url: url)
                    }

                    secondChunkFile = url
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                    throw CaptureError.recorderPreparationFailed
                },
                resolveFinalizedChunkDuration: { url in
                    guard let duration = chunkDurations[url] else {
                        throw NSError(domain: "CaptureFlowTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing chunk duration for \(url.path)"])
                    }
                    return duration
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken,
              let first = controller.debugRecorder else {
            XCTFail("recording missing")
            return
        }

        await controller.debugResolveRecorderFinish(first, success: true, token: token)

        guard let sessionDirectory else {
            XCTFail("session directory missing")
            return
        }
        let statusURL = sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName)
        let manifestURL = sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName)
        let statusData = try Data(contentsOf: statusURL)
        let manifestData = try Data(contentsOf: manifestURL)
        let status = try JSONDecoder().decode(SessionStatus.self, from: statusData)
        let manifest = try JSONDecoder().decode(SessionManifest.self, from: manifestData)

        XCTAssertEqual(status.state, .complete)
        XCTAssertTrue((status.detail ?? "").contains("partial capture: 续录失败"))
        XCTAssertEqual(manifest.chunks.count, 1)
        XCTAssertNotNil(firstChunkFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstChunkFile!.path))
        XCTAssertNotNil(secondChunkFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondChunkFile!.path))

        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testShortChunkWhenInterruptionNoResumeCompletesSession() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("short-chunk-no-resume")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var createdSessionURL: URL?
        var chunkDurations: [URL: TimeInterval] = [:]

        controller.installTestDependencies(
            .init(
                requestPermission: {
                    return true
                },
                configureSession: {
                    return
                },
                deactivateSession: {
                    return
                },
                recordingsRoot: {
                    return tempRoot
                },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    createdSessionURL = session
                    return session
                },
                createRecorder: { url, _ in
                    chunkDurations[url] = 0.1
                    return FakeCaptureRecorder(url: url)
                },
                resolveFinalizedChunkDuration: { url in
                    guard let duration = chunkDurations[url] else {
                        throw NSError(domain: "CaptureFlowTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing chunk duration for \(url.path)"])
                    }
                    return duration
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken else {
            XCTFail("sessionToken missing")
            return
        }

        controller.debugHandleInterruption(.began)
        controller.debugHandleInterruption(.ended, shouldResume: false)

        guard let sessionDirectory = createdSessionURL,
              let first = controller.debugRecorder else {
            XCTFail("session or recorder missing")
            return
        }
        await controller.debugResolveRecorderFinish(first, success: true, token: token)

        let statusURL = sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName)
        let manifestURL = sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName)
        let statusData = try Data(contentsOf: statusURL)
        let status = try JSONDecoder().decode(SessionStatus.self, from: statusData)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(SessionManifest.self, from: manifestData)

        XCTAssertEqual(status.state, .complete)
        XCTAssertNotNil(status.detail)
        XCTAssertTrue(status.detail?.contains("interruption ended without shouldResume") == true)
        XCTAssertEqual(manifest.chunks.count, 0)
        let expectedSessionId = sessionDirectory.lastPathComponent
            .hasPrefix("session-") ? String(sessionDirectory.lastPathComponent.dropFirst("session-".count)) : sessionDirectory.lastPathComponent
        XCTAssertEqual(manifest.sessionId, expectedSessionId)
        XCTAssertFalse(controller.isRecording)

        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testInterruptionBeganThenFinishThenStopWhileInterruptedKeepsCompletedSession() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("interruption-began-finish-stop-completes")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        var queuedInterruptionActions: [() async -> Void] = []
        var chunkDurations: [URL: TimeInterval] = [:]

        var createdSessionURL: URL?
        var createdRecorders: [FakeCaptureRecorder] = []

        controller.installTestDependencies(
            .init(
                requestPermission: {
                    return true
                },
                configureSession: {
                    return
                },
                deactivateSession: {
                    return
                },
                recordingsRoot: {
                    return tempRoot
                },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    createdSessionURL = session
                    return session
                },
                createRecorder: { url, _ in
                    FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                    chunkDurations[url] = 0.3
                    let recorder = FakeCaptureRecorder(url: url)
                    createdRecorders.append(recorder)
                    return recorder
                },
                resolveFinalizedChunkDuration: { url in
                    guard let duration = chunkDurations[url] else {
                        throw NSError(domain: "CaptureFlowTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing chunk duration for \(url.path)"])
                    }
                    return duration
                },
                scheduleInterruptionAction: { action in
                    queuedInterruptionActions.append(action)
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken else {
            XCTFail("sessionToken missing")
            return
        }
        guard let firstRecorder = createdRecorders.first else {
            XCTFail("first recorder missing")
            return
        }

        controller.debugHandleInterruption(.began)
        XCTAssertEqual(queuedInterruptionActions.count, 1)
        await controller.debugResolveRecorderFinish(firstRecorder, success: true, token: token)
        await controller.stopCapture()

        guard let sessionDirectory = createdSessionURL else {
            XCTFail("session directory missing")
            return
        }

        let (status, manifest) = try await awaitSessionArtifacts(sessionDirectory)

        XCTAssertEqual(status.state, .complete)
        XCTAssertEqual(manifest.chunks.count, 1)
        XCTAssertEqual(controller.debugLifecycle, "idle")
        XCTAssertNil(controller.debugSessionDirectory)

        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testNoResumeDetailSurvivesManualStopBeforeQueuedCompletionAction() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("no-resume-detail-stop-race")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var queuedInterruptionActions: [() async -> Void] = []
        var createdSessionURL: URL?
        var createdRecorder: FakeCaptureRecorder?
        var chunkDurations: [URL: TimeInterval] = [:]

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    createdSessionURL = session
                    return session
                },
                createRecorder: { url, _ in
                    FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                    chunkDurations[url] = 0.3
                    let recorder = FakeCaptureRecorder(url: url)
                    createdRecorder = recorder
                    return recorder
                },
                resolveFinalizedChunkDuration: { url in
                    guard let duration = chunkDurations[url] else {
                        throw NSError(domain: "CaptureFlowTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing chunk duration for \(url.path)"])
                    }
                    return duration
                },
                scheduleInterruptionAction: { action in
                    queuedInterruptionActions.append(action)
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken,
              let recorder = createdRecorder,
              let sessionDirectory = createdSessionURL else {
            XCTFail("active session missing")
            return
        }

        controller.debugHandleInterruption(.began)
        XCTAssertEqual(queuedInterruptionActions.count, 1)
        let stopRecorderAction = queuedInterruptionActions.removeFirst()
        await stopRecorderAction()
        await controller.debugResolveRecorderFinish(recorder, success: true, token: token)

        controller.debugHandleInterruption(.ended, shouldResume: false)
        XCTAssertEqual(queuedInterruptionActions.count, 1)
        await controller.stopCapture()

        let (status, manifest) = try await awaitSessionArtifacts(sessionDirectory)
        XCTAssertEqual(status.state, .complete)
        XCTAssertTrue(status.detail?.contains("interruption ended without shouldResume") == true)
        XCTAssertEqual(manifest.chunks.count, 1)
        XCTAssertEqual(controller.debugLifecycle, "idle")

        let delayedCompletionAction = queuedInterruptionActions.removeFirst()
        await delayedCompletionAction()
        let statusAfterDelayedAction = try JSONDecoder().decode(
            SessionStatus.self,
            from: Data(contentsOf: sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName))
        )
        XCTAssertEqual(statusAfterDelayedAction.detail, status.detail)

        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testManualStopAfterCompletionUsesResolvedDurationNotCurrentTime() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("manual-stop-uses-finalized-duration")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var createdSessionURL: URL?
        var createdRecorder: FakeCaptureRecorder?
        var chunkDurations: [URL: TimeInterval] = [:]

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    createdSessionURL = session
                    return session
                },
                createRecorder: { url, _ in
                    FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                    chunkDurations[url] = 0.7
                    let recorder = FakeCaptureRecorder(url: url)
                    createdRecorder = recorder
                    return recorder
                },
                resolveFinalizedChunkDuration: { url in
                    guard let duration = chunkDurations[url] else {
                        throw NSError(domain: "CaptureFlowTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing chunk duration for \(url.path)"])
                    }
                    return duration
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken,
              let recorder = createdRecorder,
              let sessionDirectory = createdSessionURL else {
            XCTFail("start capture failed")
            return
        }

        await controller.stopCapture()
        await controller.debugResolveRecorderFinish(recorder, success: true, token: token)

        let (status, manifest) = try await awaitSessionArtifacts(sessionDirectory)
        XCTAssertEqual(status.state, .complete)
        XCTAssertEqual(manifest.chunks.count, 1)
        XCTAssertEqual(manifest.chunks.first?.durationSec, 0.7)
        XCTAssertEqual(controller.debugLifecycle, "idle")
        XCTAssertNil(controller.debugSessionDirectory)

        guard let chunkFile = manifest.chunks.first?.file else {
            XCTFail("chunk file missing")
            return
        }
        let chunkURL = sessionDirectory.appendingPathComponent(chunkFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunkURL.path))

        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testManualStopDropsChunkWhenFinalizedDurationIsInvalid() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("manual-stop-invalid-finalized-duration")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var createdSessionURL: URL?
        var createdRecorder: FakeCaptureRecorder?

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    createdSessionURL = session
                    return session
                },
                createRecorder: { url, _ in
                    FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                    let recorder = FakeCaptureRecorder(url: url)
                    createdRecorder = recorder
                    return recorder
                },
                resolveFinalizedChunkDuration: { _ in
                    throw NSError(domain: "CaptureFlowTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "duration resolver failed"])
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken,
              let recorder = createdRecorder else {
            XCTFail("start capture failed")
            return
        }

        await controller.stopCapture()
        await controller.debugResolveRecorderFinish(recorder, success: true, token: token)

        XCTAssertNil(controller.debugSessionDirectory)
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(controller.debugLifecycle, "idle")

        if let createdSessionURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: createdSessionURL.path))
        }

        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testManualStopKeepsShortTailWhenDurationPositive() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("manual-stop-short-tail")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var createdSessionURL: URL?
        var createdRecorder: FakeCaptureRecorder?
        var chunkDurations: [URL: TimeInterval] = [:]

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    createdSessionURL = session
                    return session
                },
                createRecorder: { url, _ in
                    FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                    chunkDurations[url] = 0.21
                    let recorder = FakeCaptureRecorder(url: url)
                    createdRecorder = recorder
                    return recorder
                },
                resolveFinalizedChunkDuration: { url in
                    guard let duration = chunkDurations[url] else {
                        throw NSError(domain: "CaptureFlowTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing chunk duration for \(url.path)"])
                    }
                    return duration
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken,
              let recorder = createdRecorder,
              let sessionDirectory = createdSessionURL else {
            XCTFail("start capture failed")
            return
        }

        await controller.stopCapture()
        await controller.debugResolveRecorderFinish(recorder, success: true, token: token)

        let (status, manifest) = try await awaitSessionArtifacts(sessionDirectory)
        XCTAssertEqual(status.state, .complete)
        XCTAssertNil(status.detail)
        XCTAssertEqual(manifest.chunks.count, 1)
        XCTAssertEqual(manifest.chunks.first?.durationSec, 0.21)

        try? FileManager.default.removeItem(at: root)
    }

    func testManualStopZeroDurationChunkIsNotPersisted() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("manual-stop-zero-duration")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var createdSessionURL: URL?
        var createdRecorder: FakeCaptureRecorder?

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    createdSessionURL = session
                    return session
                },
                createRecorder: { url, _ in
                    FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                    let recorder = FakeCaptureRecorder(url: url)
                    createdRecorder = recorder
                    return recorder
                },
                resolveFinalizedChunkDuration: { _ in return 0 }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken,
              let recorder = createdRecorder,
              let sessionDirectory = createdSessionURL else {
            XCTFail("start capture failed")
            return
        }

        await controller.stopCapture()
        await controller.debugResolveRecorderFinish(recorder, success: true, token: token)

        XCTAssertNil(controller.debugSessionDirectory)
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(controller.debugLifecycle, "idle")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))

        try? FileManager.default.removeItem(at: root)
    }

    func testManualStopShortTailPreservesExistingCompletionDetail() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("manual-stop-short-tail-existing-detail")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var createdSessionURL: URL?
        var createdRecorder: FakeCaptureRecorder?

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    createdSessionURL = session
                    return session
                },
                createRecorder: { url, _ in
                    FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                    let recorder = FakeCaptureRecorder(url: url)
                    createdRecorder = recorder
                    return recorder
                },
                resolveFinalizedChunkDuration: { _ in 0.21 }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        controller.debugSetPendingCompletionDetail("partial capture: 真实错误")

        guard let token = controller.debugSessionToken,
              let recorder = createdRecorder,
              let sessionDirectory = createdSessionURL else {
            XCTFail("start capture failed")
            return
        }

        await controller.stopCapture()
        await controller.debugResolveRecorderFinish(recorder, success: true, token: token)

        let (status, manifest) = try await awaitSessionArtifacts(sessionDirectory)
        XCTAssertEqual(status.state, .complete)
        XCTAssertEqual(status.detail, "partial capture: 真实错误")
        XCTAssertEqual(manifest.chunks.count, 1)

        try? FileManager.default.removeItem(at: root)
    }

    func testMakeSessionDirectoryProviderFailureCleansPartialAudioDirectory() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("session-directory-provider-failure")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var createdSessionURL: URL?
        let store = CaptureStore()
        controller.installTestDependencies(
            .init(
                requestPermission: {
                    return true
                },
                configureSession: {
                    return
                },
                deactivateSession: {
                    return
                },
                recordingsRoot: {
                    return tempRoot
                },
                createSessionDirectory: { startedAt, sessionId, recordingsRoot in
                    let session = store.sessionDirectory(startedAt: startedAt, sessionId: sessionId, recordingsRoot: recordingsRoot)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    createdSessionURL = session
                    throw CaptureError.noSessionDirectory
                },
                createRecorder: { url, _ in
                    FakeCaptureRecorder(url: url)
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertFalse(result.ok)
        XCTAssertNil(controller.debugSessionDirectory)
        XCTAssertNil(controller.debugSessionRoot)

        guard let createdSessionURL else {
            XCTFail("session目录未创建")
            return
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: createdSessionURL.path))

        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testStartCaptureDoesNotMutateLoadedRecentSessionsRoot() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("startcapture-stable-recent-root")
        try? FileManager.default.removeItem(at: root)
        let goodRoot = root.appendingPathComponent("good")
        let altRoot = root.appendingPathComponent("alt")
        try? FileManager.default.createDirectory(at: goodRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: altRoot, withIntermediateDirectories: true)

        let stableSession = goodRoot.appendingPathComponent("session-stable", isDirectory: true)
        try? FileManager.default.createDirectory(at: stableSession.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true), withIntermediateDirectories: true)
        var chunkDurations: [URL: TimeInterval] = [:]

        controller.installTestDependencies(
            .init(
                recordingsRoot: {
                    return goodRoot
                }
            )
        )
        await controller.loadRecentSessions()
        let stableRoot = controller.debugRecentSessionsRoot
        let stableSessions = controller.debugRecentSessions

        var createdSessionURL: URL?
        var createdRecorder: FakeCaptureRecorder?
        let stopExpectation = expectation(description: "recorder stopped")

        controller.installTestDependencies(
            .init(
                requestPermission: {
                    return true
                },
                configureSession: {
                    return
                },
                deactivateSession: {
                    return
                },
                recordingsRoot: {
                    return altRoot
                },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    createdSessionURL = session
                    return session
                },
                createRecorder: { url, _ in
                    FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                    chunkDurations[url] = 0.3
                    let recorder = FakeCaptureRecorder(url: url)
                    recorder.onStop = {
                        stopExpectation.fulfill()
                    }
                    createdRecorder = recorder
                    return recorder
                },
                resolveFinalizedChunkDuration: { url in
                    guard let duration = chunkDurations[url] else {
                        throw NSError(domain: "CaptureFlowTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing chunk duration for \(url.path)"])
                    }
                    return duration
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken,
              let recorder = createdRecorder else {
            XCTFail("start capture failed")
            return
        }
        await controller.stopCapture()
        await fulfillment(of: [stopExpectation], timeout: 1.0)
        await controller.debugResolveRecorderFinish(recorder, success: true, token: token)

        XCTAssertEqual(controller.debugRecentSessionsRoot, stableRoot)
        XCTAssertEqual(controller.debugRecentSessions, stableSessions)
        XCTAssertEqual(controller.debugLifecycle, "idle")
        XCTAssertNil(controller.debugSessionDirectory)

        if let createdSessionURL {
            try? FileManager.default.removeItem(at: createdSessionURL)
        }

        try? FileManager.default.removeItem(at: root)
    }

    func testDeleteHistorySessionUsesBoundRootAfterProviderFailure() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("history-delete-idle")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let altRoot = root.appendingPathComponent("alternate")
        try? FileManager.default.createDirectory(at: altRoot, withIntermediateDirectories: true)

        var chunkDurations: [URL: TimeInterval] = [:]

        let firstRecorderCreated = expectation(description: "first recorder created")
        let secondRecorderCreated = expectation(description: "second recorder created")
        let recorderStopped = expectation(description: "session recorder stopped")
        var createdSessionURL: URL?
        var createdRecorders: [FakeCaptureRecorder] = []
        controller.installTestDependencies(
            .init(
                requestPermission: {
                    return true
                },
                configureSession: {
                    return
                },
                deactivateSession: {
                    return
                },
                recordingsRoot: {
                    return tempRoot
                },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    createdSessionURL = session
                    return session
                },
                createRecorder: { url, _ in
                    let recorder = FakeCaptureRecorder(url: url)
                    createdRecorders.append(recorder)
                    FileManager.default.createFile(atPath: url.path, contents: Data([0x01]))
                    chunkDurations[url] = 0.3
                    if createdRecorders.count == 1 {
                        firstRecorderCreated.fulfill()
                    } else if createdRecorders.count == 2 {
                        secondRecorderCreated.fulfill()
                    }
                    return recorder
                },
                resolveFinalizedChunkDuration: { url in
                    guard let duration = chunkDurations[url] else {
                        throw NSError(domain: "CaptureFlowTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "missing chunk duration for \(url.path)"])
                    }
                    return duration
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken else {
            XCTFail("sessionToken missing")
            return
        }
        await fulfillment(of: [firstRecorderCreated], timeout: 1.0)
        guard let first = createdRecorders.first else {
            XCTFail("first recorder missing")
            return
        }
        await controller.debugResolveRecorderFinish(first, success: true, token: token)
        await fulfillment(of: [secondRecorderCreated], timeout: 1.0)

        guard let recorder = createdRecorders.last else {
            XCTFail("active recorder missing")
            return
        }
        recorder.onStop = {
            recorderStopped.fulfill()
        }

        await controller.stopCapture()
        await fulfillment(of: [recorderStopped], timeout: 1.0)
        await controller.debugResolveRecorderFinish(recorder, success: true, token: token)
        XCTAssertEqual(controller.debugLifecycle, "idle")
        let completedSessionURL = createdSessionURL
        if let completedSessionURL {
            do {
                let (status, _) = try await awaitSessionArtifacts(completedSessionURL)
                XCTAssertEqual(status.state, .complete)
            } catch {
                XCTFail("读取 session artifacts 失败：\(error)")
                return
            }
        }

        let reloadedController = CaptureController()
        reloadedController.installTestDependencies(.init(recordingsRoot: { tempRoot }))

        await reloadedController.loadRecentSessions()
        guard let sessionName = createdSessionURL?.lastPathComponent else {
            XCTFail("session missing")
            return
        }
        XCTAssertEqual(reloadedController.debugRecentSessions.first, sessionName)
        XCTAssertEqual(reloadedController.debugRecentSessionsRoot, tempRoot)

        reloadedController.installTestDependencies(
            .init(recordingsRoot: {
                throw NSError(domain: "CaptureFlowTests", code: 1)
            })
        )
        await reloadedController.deleteSession(sessionName)

        XCTAssertFalse(FileManager.default.fileExists(atPath: createdSessionURL!.path))
        XCTAssertEqual(reloadedController.debugRecentSessionsRoot, tempRoot)
        XCTAssertFalse(reloadedController.debugRecentSessions.contains(sessionName))

        reloadedController.installTestDependencies(
            .init(recordingsRoot: { altRoot })
        )

        let crossRootDuplicate = altRoot.appendingPathComponent(sessionName, isDirectory: true)
        try? FileManager.default.createDirectory(at: crossRootDuplicate.appendingPathComponent("keep"), withIntermediateDirectories: true)

        await reloadedController.deleteSession(sessionName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: createdSessionURL!.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: crossRootDuplicate.path))

        await reloadedController.deleteSession(sessionName + "-missing")
        XCTAssertEqual(reloadedController.message, "删除失败：Session directory not found.")

        try? FileManager.default.removeItem(at: root)
    }

    func testLoadRecentSessionsPreservesExistingRootAndListOnFailure() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("history-load-failure-retains-state")
        try? FileManager.default.removeItem(at: root)
        let goodRoot = root.appendingPathComponent("good")
        let badRoot = root.appendingPathComponent("bad")
        try? FileManager.default.createDirectory(at: goodRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: badRoot, withIntermediateDirectories: true)

        controller.installTestDependencies(
            .init(recordingsRoot: { goodRoot })
        )
        await controller.loadRecentSessions()
        let stableRoot = controller.debugRecentSessionsRoot
        let stableSessions = controller.debugRecentSessions

        controller.installTestDependencies(
            .init(recordingsRoot: {
                throw NSError(domain: "CaptureFlowTests", code: 2)
            })
        )
        await controller.loadRecentSessions()

        XCTAssertEqual(controller.debugRecentSessionsRoot, stableRoot)
        XCTAssertEqual(controller.debugRecentSessions, stableSessions)

        XCTAssertEqual(stableRoot, goodRoot)
        XCTAssertTrue(controller.message?.contains("无法读取会话目录") == true)

        try? FileManager.default.removeItem(at: root)
    }

    func testScheduledStartReturnsOkOnlyAfterRecorderCapturing() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("scheduled-start-gating")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let chunk = ScheduledChunkRecorder.Chunk(
            index: 0,
            url: tempRoot.appendingPathComponent("chunk_0.m4a"),
            scheduledDeviceTime: 0,
            startOffsetSec: 0
        )

        let nonCapturingCoordinator = FakeScheduledChunkCoordinator(
            startResult: .success(chunk),
            isCapturing: false
        )
        let capturingCoordinator = FakeScheduledChunkCoordinator(
            startResult: .success(chunk),
            isCapturing: true
        )

        var captureCallCount = 0
        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                useScheduledChunkPrototype: true,
                scheduledChunkRecorder: { _, _, _, _ in
                    captureCallCount += 1
                    if captureCallCount == 1 {
                        return nonCapturingCoordinator
                    }
                    return capturingCoordinator
                }
            )
        )

        let firstStart = await controller.startCapture()
        XCTAssertFalse(firstStart.ok)
        XCTAssertNil(controller.debugSessionDirectory)
        XCTAssertEqual(firstStart.message, "开始失败：Scheduled chunk recorder did not start.")

        let secondStart = await controller.startCapture()
        XCTAssertTrue(secondStart.ok)
        XCTAssertNotNil(controller.debugSessionDirectory)
        XCTAssertEqual(capturingCoordinator.startInvocations, 1)

        await controller.stopCapture()
        guard let tokenAfterStart = controller.debugSessionToken else {
            XCTFail("session token missing")
            return
        }
        await controller.debugHandleScheduledChunkEvent(
            .stopped,
            token: tokenAfterStart
        )

        XCTAssertNil(controller.debugSessionDirectory)

        try? FileManager.default.removeItem(at: root)
    }

    func testDefaultCaptureUsesScheduledRecorderWithoutPrototypeFlag() {
        let controller = CaptureController()
        XCTAssertTrue(controller.debugScheduledChunkModeEnabled)
    }

    func testDefaultScheduledChunkConfigurationMatchesBuildTarget() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("scheduled-default-configuration")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let chunk = ScheduledChunkRecorder.Chunk(
            index: 0,
            url: tempRoot.appendingPathComponent("chunk_0.m4a"),
            scheduledDeviceTime: 0,
            startOffsetSec: 0
        )

        var observedChunkDuration: TimeInterval?
        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                scheduledChunkRecorder: { _, configuration, _, _ in
                    observedChunkDuration = configuration.chunkDuration
                    return FakeScheduledChunkCoordinator(
                        startResult: .success(chunk),
                        isCapturing: true
                    )
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        let expectedChunkDuration: TimeInterval = {
            #if AIWATCHING_SCHEDULED_CHUNK_PROTOTYPE
            return 10
            #else
            return AIWatchingSchema.chunkDuration
            #endif
        }()
        XCTAssertEqual(
            observedChunkDuration,
            expectedChunkDuration
        )

        await controller.stopCapture()
        guard let tokenAfterStart = controller.debugSessionToken else {
            XCTFail("session token missing")
            return
        }
        await controller.debugHandleScheduledChunkEvent(.stopped, token: tokenAfterStart)
        XCTAssertNil(controller.debugSessionDirectory)

        try? FileManager.default.removeItem(at: root)
    }

    func testScheduledInterruptionResumesAfterCoordinatorStops() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("scheduled-interruption-resume")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let firstChunk = ScheduledChunkRecorder.Chunk(
            index: 0,
            url: tempRoot.appendingPathComponent("chunk_0.m4a"),
            scheduledDeviceTime: 0,
            startOffsetSec: 0
        )
        let resumedChunk = ScheduledChunkRecorder.Chunk(
            index: 0,
            url: tempRoot.appendingPathComponent("resumed.m4a"),
            scheduledDeviceTime: 1,
            startOffsetSec: 1
        )
        let firstCoordinator = FakeScheduledChunkCoordinator(
            startResult: .success(firstChunk),
            isCapturing: true
        )
        let resumedCoordinator = FakeScheduledChunkCoordinator(
            startResult: .success(resumedChunk),
            isCapturing: true
        )
        var providerCalls = 0
        var scheduledAction: (() async -> Void)?
        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                scheduleInterruptionAction: { action in scheduledAction = action },
                useScheduledChunkPrototype: true,
                scheduledChunkRecorder: { _, _, _, _ in
                    providerCalls += 1
                    return providerCalls == 1 ? firstCoordinator : resumedCoordinator
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken else {
            XCTFail("session token missing")
            return
        }

        controller.debugHandleInterruption(.began)
        XCTAssertEqual(controller.debugLifecycle, "interrupted")
        await scheduledAction?()
        XCTAssertEqual(firstCoordinator.stopInvocations, 1)
        controller.debugHandleInterruption(.ended, shouldResume: true)
        await scheduledAction?()
        await controller.debugHandleScheduledChunkEvent(.stopped, token: token)

        XCTAssertEqual(controller.debugLifecycle, "recording")
        XCTAssertEqual(resumedCoordinator.startInvocations, 1)
        await controller.stopCapture()
        await controller.debugHandleScheduledChunkEvent(.stopped, token: token)
        XCTAssertNil(controller.debugSessionDirectory)
        try? FileManager.default.removeItem(at: root)
    }

    func testScheduledPrototypeStartFailureDeletesProvisionedSessionDirectory() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("scheduled-start-failure-cleanup")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var createdSessionURL: URL?

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
                    try FileManager.default.createDirectory(
                        at: session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true),
                        withIntermediateDirectories: true
                    )
                    createdSessionURL = session
                    return session
                },
                persistActiveSession: { _, _ in
                    throw CaptureError.noSessionDirectory
                },
                useScheduledChunkPrototype: true,
                scheduledChunkRecorder: { _, _, _, _ in
                    throw ScheduledChunkRecorderError.recorderSchedulingFailed(index: 0)
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertFalse(result.ok)
        XCTAssertNil(controller.debugSessionDirectory)
        guard let createdSessionURL else {
            XCTFail("session dir missing")
            return
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: createdSessionURL.path))

        try? FileManager.default.removeItem(at: root)
    }

    func testScheduledPrototypeChunkFinishedUsesStartOffset() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("scheduled-start-offset")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let chunk = ScheduledChunkRecorder.Chunk(
            index: 0,
            url: tempRoot.appendingPathComponent("chunk_0.m4a"),
            scheduledDeviceTime: 100,
            startOffsetSec: 2.0
        )
        let chunkIndexByURL = [chunk.url: chunk.index]
        FileManager.default.createFile(atPath: chunk.url.path, contents: Data([0x01]))

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                resolveFinalizedChunkDuration: { url in
                    guard chunkIndexByURL.keys.contains(url) else {
                        throw NSError(domain: "CaptureFlowTests", code: 3)
                    }
                    return 0.35
                },
                useScheduledChunkPrototype: true,
                scheduledChunkRecorder: { _, _, _, _ in
                    FakeScheduledChunkCoordinator(
                        startResult: .success(chunk),
                        isCapturing: true
                    )
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken,
              let sessionDirectory = controller.debugSessionDirectory else {
            XCTFail("start capture failed")
            return
        }

        await controller.debugHandleScheduledChunkEvent(.chunkFinished(chunk, successfully: true), token: token)
        await controller.debugHandleScheduledChunkEvent(.stopped, token: token)

        let (_, manifest) = try await awaitSessionArtifacts(sessionDirectory)
        XCTAssertEqual(manifest.chunks.count, 1)
        let actualChunk = try XCTUnwrap(manifest.chunks.first)
        XCTAssertEqual(actualChunk.startOffsetSec, 2.0, accuracy: 0.000_001)
        let sessionStarted = try XCTUnwrap(isoDate(manifest.startedAt))
        let chunkStarted = try XCTUnwrap(isoDate(try XCTUnwrap(actualChunk.startedAt)))
        XCTAssertEqual(chunkStarted.timeIntervalSince(sessionStarted), 2.0, accuracy: 0.05)

        try? FileManager.default.removeItem(at: root)
    }

    func testScheduledPrototypeChunkFinalizationQueuePreservesIndexOrderWhenDurationsBlock() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("scheduled-queue-order")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let firstChunk = ScheduledChunkRecorder.Chunk(
            index: 0,
            url: tempRoot.appendingPathComponent("chunk_0.m4a"),
            scheduledDeviceTime: 0,
            startOffsetSec: 0
        )
        let secondChunk = ScheduledChunkRecorder.Chunk(
            index: 1,
            url: tempRoot.appendingPathComponent("chunk_1.m4a"),
            scheduledDeviceTime: 9.75,
            startOffsetSec: 9.75
        )
        FileManager.default.createFile(atPath: firstChunk.url.path, contents: Data([0x01]))
        FileManager.default.createFile(atPath: secondChunk.url.path, contents: Data([0x01]))

        let gate = ResolvingChunkDurationGate([0: 0.3, 1: 0.35])
        let chunkURLIndex = [firstChunk.url: 0, secondChunk.url: 1]

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                resolveFinalizedChunkDuration: { url in
                    guard let index = chunkURLIndex[url] else {
                        throw NSError(domain: "CaptureFlowTests", code: 3)
                    }
                    return try await gate.resolve(index: index)
                },
                useScheduledChunkPrototype: true,
                scheduledChunkRecorder: { _, _, _, _ in
                    FakeScheduledChunkCoordinator(
                        startResult: .success(firstChunk),
                        isCapturing: true
                    )
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken,
              let sessionDirectory = controller.debugSessionDirectory else {
            XCTFail("start capture failed")
            return
        }

        let secondFinish = Task {
            await controller.debugHandleScheduledChunkEvent(
                .chunkFinished(secondChunk, successfully: true),
                token: token
            )
        }
        let firstFinish = Task {
            await controller.debugHandleScheduledChunkEvent(
                .chunkFinished(firstChunk, successfully: true),
                token: token
            )
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        await gate.release(0)
        await secondFinish.value
        await firstFinish.value
        await gate.release(1)

        await controller.debugHandleScheduledChunkEvent(.stopped, token: token)

        let (_, manifest) = try await awaitSessionArtifacts(sessionDirectory)
        XCTAssertEqual(manifest.chunks.map(\.index), [0, 1])

        try? FileManager.default.removeItem(at: root)
    }

    func testScheduledPrototypeStopWaitsForFinalizationBeforeCompleting() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("scheduled-stop-waits-finalization")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let chunk = ScheduledChunkRecorder.Chunk(
            index: 0,
            url: tempRoot.appendingPathComponent("chunk_0.m4a"),
            scheduledDeviceTime: 0,
            startOffsetSec: 0
        )
        FileManager.default.createFile(atPath: chunk.url.path, contents: Data([0x01]))

        let gate = ResolvingChunkDurationGate([0: 0.3])

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                resolveFinalizedChunkDuration: { _ in
                    return try await gate.resolve(index: 0)
                },
                useScheduledChunkPrototype: true,
                scheduledChunkRecorder: { _, _, _, _ in
                    FakeScheduledChunkCoordinator(
                        startResult: .success(chunk),
                        isCapturing: true
                    )
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken,
              let sessionDirectory = controller.debugSessionDirectory else {
            XCTFail("start capture failed")
            return
        }

        let finishTask = Task {
            await controller.debugHandleScheduledChunkEvent(.chunkFinished(chunk, successfully: true), token: token)
        }

        await controller.stopCapture()
        XCTAssertEqual(controller.debugLifecycle, "stopping")
        XCTAssertNotNil(controller.debugSessionDirectory)

        await gate.release(0)
        await finishTask.value
        await controller.debugHandleScheduledChunkEvent(.stopped, token: token)

        let (status, _) = try await awaitSessionArtifacts(sessionDirectory)
        XCTAssertEqual(status.state, .complete)

        try? FileManager.default.removeItem(at: root)
    }

    func testScheduledPrototypeStaleSessionEventDoesNotPolluteNewSession() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("scheduled-stale-event")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let staleChunk = ScheduledChunkRecorder.Chunk(
            index: 0,
            url: tempRoot.appendingPathComponent("chunk_stale.m4a"),
            scheduledDeviceTime: 0,
            startOffsetSec: 0
        )
        let newChunk = ScheduledChunkRecorder.Chunk(
            index: 0,
            url: tempRoot.appendingPathComponent("chunk_new.m4a"),
            scheduledDeviceTime: 0,
            startOffsetSec: 0
        )

        FileManager.default.createFile(atPath: staleChunk.url.path, contents: Data([0x01]))
        FileManager.default.createFile(atPath: newChunk.url.path, contents: Data([0x01]))

        let firstCoordinator = FakeScheduledChunkCoordinator(
            startResult: .success(staleChunk),
            isCapturing: true
        )
        let secondCoordinator = FakeScheduledChunkCoordinator(
            startResult: .success(newChunk),
            isCapturing: true
        )

        var scheduledCallCount = 0

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                resolveFinalizedChunkDuration: { url in
                    if url == staleChunk.url {
                        return 0.3
                    }
                    return 0.3
                },
                useScheduledChunkPrototype: true,
                scheduledChunkRecorder: { _, _, _, _ in
                    scheduledCallCount += 1
                    if scheduledCallCount == 1 {
                        return firstCoordinator
                    }
                    return secondCoordinator
                }
            )
        )

        let firstStart = await controller.startCapture()
        XCTAssertTrue(firstStart.ok)
        guard let firstToken = controller.debugSessionToken else {
            XCTFail("first start missing token")
            return
        }

        await controller.debugHandleScheduledChunkEvent(.stopped, token: firstToken)

        let secondStart = await controller.startCapture()
        XCTAssertTrue(secondStart.ok)
        guard let secondToken = controller.debugSessionToken,
              let secondSession = controller.debugSessionDirectory else {
            XCTFail("second start missing session")
            return
        }

        await controller.debugHandleScheduledChunkEvent(
            .chunkFinished(staleChunk, successfully: true),
            token: firstToken
        )

        await controller.debugHandleScheduledChunkEvent(
            .chunkFinished(newChunk, successfully: true),
            token: secondToken
        )
        await controller.debugHandleScheduledChunkEvent(.stopped, token: secondToken)

        let (_, manifest) = try await awaitSessionArtifacts(secondSession)
        XCTAssertEqual(manifest.chunks.count, 1)
        XCTAssertEqual(manifest.chunks.first?.file, CaptureStore().relativeAudioPath(chunkIndex: 0))
        XCTAssertEqual(secondCoordinator.startInvocations, 1)
        XCTAssertEqual(secondCoordinator.activeChunk?.index, 0)

        try? FileManager.default.removeItem(at: root)
    }

    func testScheduledPrototypeShortTailPreservedWhenStopping() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("scheduled-short-tail-stop")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let finalChunk = ScheduledChunkRecorder.Chunk(
            index: 0,
            url: tempRoot.appendingPathComponent("chunk_0.m4a"),
            scheduledDeviceTime: 0,
            startOffsetSec: 0
        )
        FileManager.default.createFile(atPath: finalChunk.url.path, contents: Data([0x01]))

        var captureSnapshots: [(Bool, String, String?)] = []
        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                resolveFinalizedChunkDuration: { _ in
                    return 0.1
                },
                useScheduledChunkPrototype: true,
                scheduledChunkRecorder: { _, _, _, _ in
                    FakeScheduledChunkCoordinator(
                        startResult: .success(finalChunk),
                        isCapturing: true
                    )
                },
                publishCaptureState: { isCapturing, statusText, sessionId in
                    captureSnapshots.append((isCapturing, statusText, sessionId))
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(captureSnapshots.filter { $0.0 }.count, 1)

        guard let token = controller.debugSessionToken,
              let sessionDirectory = controller.debugSessionDirectory else {
            XCTFail("start capture failed")
            return
        }

        await controller.stopCapture()
        await controller.debugHandleScheduledChunkEvent(.chunkFinished(finalChunk, successfully: true), token: token)
        await controller.debugHandleScheduledChunkEvent(.stopped, token: token)

        let (status, manifest) = try await awaitSessionArtifacts(sessionDirectory)
        XCTAssertEqual(status.state, .complete)
        XCTAssertNil(status.detail)
        XCTAssertEqual(manifest.chunks.count, 1)
        let shortTailDuration = try XCTUnwrap(manifest.chunks.first?.durationSec)
        XCTAssertEqual(shortTailDuration, 0.1, accuracy: 0.001)
        XCTAssertEqual(manifest.chunks.first?.index, 0)
        XCTAssertEqual(captureSnapshots.filter { !$0.0 }.count, 1)

        try? FileManager.default.removeItem(at: root)
    }

    func testScheduledPrototypeShortTailFailureKeepsCompletedChunkAndMarksPartial() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("scheduled-short-tail-failure")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let fullChunk = ScheduledChunkRecorder.Chunk(
            index: 0,
            url: tempRoot.appendingPathComponent("chunk_0.m4a"),
            scheduledDeviceTime: 0,
            startOffsetSec: 0
        )
        let shortChunk = ScheduledChunkRecorder.Chunk(
            index: 1,
            url: tempRoot.appendingPathComponent("chunk_1.m4a"),
            scheduledDeviceTime: 9.75,
            startOffsetSec: 9.75
        )
        FileManager.default.createFile(atPath: fullChunk.url.path, contents: Data([0x01]))
        FileManager.default.createFile(atPath: shortChunk.url.path, contents: Data([0x01]))

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                resolveFinalizedChunkDuration: { url in
                    if url == fullChunk.url {
                        return 0.4
                    }
                    return 0.1
                },
                useScheduledChunkPrototype: true,
                scheduledChunkRecorder: { _, _, _, _ in
                    FakeScheduledChunkCoordinator(
                        startResult: .success(fullChunk),
                        isCapturing: true
                    )
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken,
              let sessionDirectory = controller.debugSessionDirectory else {
            XCTFail("start capture failed")
            return
        }

        await controller.debugHandleScheduledChunkEvent(.chunkFinished(fullChunk, successfully: true), token: token)
        await controller.debugHandleScheduledChunkEvent(.chunkFinished(shortChunk, successfully: true), token: token)
        await controller.debugHandleScheduledChunkEvent(.stopped, token: token)

        let (status, manifest) = try await awaitSessionArtifacts(sessionDirectory)
        XCTAssertEqual(status.state, .complete)
        XCTAssertEqual(status.detail, "partial capture: 当前分片持续时间过短")
        XCTAssertEqual(manifest.chunks.count, 1)
        let fullChunkDuration = try XCTUnwrap(manifest.chunks.first?.durationSec)
        XCTAssertEqual(fullChunkDuration, 0.4, accuracy: 0.001)

        try? FileManager.default.removeItem(at: root)
    }

    func testPhoneLocalStartPublishesCapturingState() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("publish-state-local-start")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        var recorder: FakeCaptureRecorder?
        var states: [(Bool, String, String?)] = []

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                createRecorder: { url, _ in
                    let created = FakeCaptureRecorder(url: url)
                    recorder = created
                    return created
                },
                resolveFinalizedChunkDuration: { _ in
                    return 0.3
                },
                useScheduledChunkPrototype: false,
                publishCaptureState: { isCapturing, statusText, sessionId in
                    states.append((isCapturing, statusText, sessionId))
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        XCTAssertEqual(states.filter { $0.0 }.count, 1)

        await controller.stopCapture()
        if let recorder {
            if let token = controller.debugSessionToken {
                await controller.debugResolveRecorderFinish(recorder, success: true, token: token)
            }
        }

        XCTAssertEqual(states.filter { !$0.0 }.count, 1)
        let last = states.last
        XCTAssertEqual(last?.0, false)
        XCTAssertNotNil(last?.2)

        try? FileManager.default.removeItem(at: root)
    }

    func testPhoneLocalStartFailureDoesNotPublishCapturing() async {
        let controller = CaptureController()
        var states: [(Bool, String, String?)] = []

        controller.installTestDependencies(
            .init(
                requestPermission: { false },
                publishCaptureState: { isCapturing, statusText, sessionId in
                    states.append((isCapturing, statusText, sessionId))
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertFalse(result.ok)
        XCTAssertTrue(states.isEmpty)
    }

    func testPhoneConnectivityPublishesLatestContextOnlyAfterActivation() async {
        let controller = PhoneConnectivityController.shared

        actor PublishedStateCollector {
            private var snapshots: [CaptureAppCaptureStateSnapshot] = []

            func append(_ snapshot: CaptureAppCaptureStateSnapshot) {
                snapshots.append(snapshot)
            }

            func count() -> Int {
                snapshots.count
            }

            func all() -> [CaptureAppCaptureStateSnapshot] {
                snapshots
            }
            func latest() -> CaptureAppCaptureStateSnapshot? {
                snapshots.last
            }
        }

        var activationState: WCSessionActivationState = .notActivated
        let published = PublishedStateCollector()

        controller.debugResetCaptureStateForTests()
        controller.installTestDependencies(
            .init(
                isSupported: { true },
                activationState: { activationState },
                isReachable: { false },
                isPaired: { true },
                activateSession: {},
                updateApplicationContext: { context in
                    Task {
                        guard let snapshot = CaptureAppCaptureStateSnapshot(applicationContext: context) else { return }
                        await published.append(snapshot)
                    }
                }
            )
        )

        controller.publishCaptureState(isCapturing: true, statusText: "已开始", sessionId: "one")
        controller.publishCaptureState(isCapturing: false, statusText: "未开始", sessionId: "two")

        let initialPublishedCount = await published.count()
        XCTAssertEqual(initialPublishedCount, 0)
        activationState = .activated
        controller.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)

        let publicationDeadline = Date().addingTimeInterval(1.0)
        var publishedCount = await published.count()
        while publishedCount == 0 && Date() < publicationDeadline {
            try? await Task.sleep(for: .milliseconds(10))
            publishedCount = await published.count()
        }

        let snapshotCount = await published.count()
        XCTAssertEqual(snapshotCount, 1)

        guard let lastSnapshot = await published.latest(),
              let lastSessionId = lastSnapshot.sessionId else {
            XCTFail("missing snapshot after activation")
            return
        }
        XCTAssertEqual(lastSessionId, "two")
        XCTAssertEqual(lastSnapshot.sequence, 2)
        XCTAssertEqual(lastSnapshot.statusText, "未开始")
    }

    func testPhoneConnectivityNewPublisherSnapshotAcceptedAndOldPublisherDropped() {
        var reducer = CaptureAppCaptureStateReducer()
        let publisherA = UUID()
        let publisherB = UUID()

        let firstFromA = CaptureAppCaptureStateSnapshot(
            publisherId: publisherA,
            sequence: 1,
            timestamp: 100,
            sessionId: "session-a",
            isCapturing: true,
            statusText: "旧会话"
        )
        let newFromB = CaptureAppCaptureStateSnapshot(
            publisherId: publisherB,
            sequence: 1,
            timestamp: 200,
            sessionId: "session-b",
            isCapturing: true,
            statusText: "新会话"
        )
        let delayedFromA = CaptureAppCaptureStateSnapshot(
            publisherId: publisherA,
            sequence: 5,
            timestamp: 300,
            sessionId: "session-a-late",
            isCapturing: true,
            statusText: "延后更新"
        )

        XCTAssertTrue(reducer.apply(firstFromA))
        XCTAssertTrue(reducer.apply(newFromB))
        XCTAssertFalse(reducer.apply(delayedFromA))
        XCTAssertEqual(reducer.sessionId, "session-b")
        XCTAssertEqual(reducer.isCapturing, true)
        XCTAssertEqual(reducer.retiredPublisherIds, Set([publisherA]))
    }

    func testWatchConnectorReducerRejectsOldSequenceAndAcceptsNewPublisher() {
        var reducer = CaptureAppCaptureStateReducer()

        let publisherA = UUID()
        let publisherB = UUID()

        let snapshotA0 = CaptureAppCaptureStateSnapshot(
            publisherId: publisherA,
            sequence: 1,
            timestamp: 100,
            sessionId: "a",
            isCapturing: true,
            statusText: "正在捕捉"
        )
        let snapshotA1 = CaptureAppCaptureStateSnapshot(
            publisherId: publisherA,
            sequence: 2,
            timestamp: 110,
            sessionId: "a",
            isCapturing: false,
            statusText: "等待 iPhone"
        )
        let snapshotA2 = CaptureAppCaptureStateSnapshot(
            publisherId: publisherA,
            sequence: 1,
            timestamp: 120,
            sessionId: "a-old",
            isCapturing: true,
            statusText: "重放"
        )
        let snapshotB = CaptureAppCaptureStateSnapshot(
            publisherId: publisherB,
            sequence: 1,
            timestamp: 130,
            sessionId: "b",
            isCapturing: true,
            statusText: "正在捕捉"
        )

        let acceptedA0 = reducer.apply(snapshotA0)
        let acceptedA1 = reducer.apply(snapshotA1)
        let rejectedOld = reducer.apply(snapshotA2)
        let acceptedB = reducer.apply(snapshotB)

        XCTAssertTrue(acceptedA0)
        XCTAssertTrue(acceptedA1)
        XCTAssertFalse(rejectedOld)
        XCTAssertTrue(acceptedB)
        XCTAssertEqual(reducer.sessionId, "b")
        XCTAssertEqual(reducer.isCapturing, true)
        XCTAssertEqual(reducer.statusText, "正在捕捉")
    }

    func testWatchConnectorReducerRejectsDelayedOldPublisherSnapshot() {
        var reducer = CaptureAppCaptureStateReducer()

        let publisherA = UUID()
        let publisherB = UUID()

        let baseline = CaptureAppCaptureStateSnapshot(
            publisherId: publisherA,
            sequence: 1,
            timestamp: 200,
            sessionId: "first",
            isCapturing: true,
            statusText: "正在捕捉"
        )
        let replacement = CaptureAppCaptureStateSnapshot(
            publisherId: publisherB,
            sequence: 1,
            timestamp: 300,
            sessionId: "second",
            isCapturing: false,
            statusText: "等待 iPhone"
        )
        let delayedOld = CaptureAppCaptureStateSnapshot(
            publisherId: publisherA,
            sequence: 2,
            timestamp: 250,
            sessionId: "stale",
            isCapturing: true,
            statusText: "仍在捕捉"
        )

        XCTAssertTrue(reducer.apply(baseline))
        XCTAssertTrue(reducer.apply(replacement))
        XCTAssertFalse(reducer.apply(delayedOld))
        XCTAssertEqual(reducer.sessionId, "second")
        XCTAssertEqual(reducer.isCapturing, false)
    }

    func testPhoneConnectivityActivationFailureCapturesError() async {
        let controller = PhoneConnectivityController.shared
        struct LocalError: Error, LocalizedError {
            var errorDescription: String? { "update failed" }
        }

        var activationState: WCSessionActivationState = .notActivated
        actor ErrorCollector {
            private var count = 0
            func increment() {
                count += 1
            }
            func read() -> Int {
                count
            }
        }

        let failureCount = ErrorCollector()
        controller.debugResetCaptureStateForTests()
        controller.installTestDependencies(
            .init(
                isSupported: { true },
                activationState: { activationState },
                isReachable: { false },
                isPaired: { true },
                activateSession: {},
                updateApplicationContext: { _ in
                    Task {
                        await failureCount.increment()
                    }
                    throw LocalError()
                }
            )
        )

        controller.publishCaptureState(isCapturing: true, statusText: "on", sessionId: nil)
        activationState = .activated
        controller.session(WCSession.default, activationDidCompleteWith: .activated, error: nil)

        let deadline = Date().addingTimeInterval(1.0)
        var failureReads = await failureCount.read()
        while failureReads == 0 && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
            failureReads = await failureCount.read()
        }

        XCTAssertNotNil(controller.debugLastPublishError?.localizedDescription)
        XCTAssertEqual(controller.debugLastPublishError?.localizedDescription, "update failed")
        let updates = await failureCount.read()
        XCTAssertEqual(updates, 1)
    }

    func testCaptureControllerStaleStartDoesNotPublishCapturingState() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("stale-start-state-not-publish")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var states: [(Bool, String, String?)] = []
        let requestA = expectation(description: "start A permission")
        let requestB = expectation(description: "start B permission")
        let permissionGate = PermissionRequestGate(expectations: [requestA, requestB])

        controller.installTestDependencies(
            .init(
                requestPermission: {
                    return await permissionGate.request()
                },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                createSessionDirectory: { _, sessionId, recordingsRoot in
                    let session = recordingsRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    return session
                },
                createRecorder: { url, _ in
                    let recorder = FakeCaptureRecorder(url: url)
                    return recorder
                },
                resolveFinalizedChunkDuration: { _ in
                    return 0.3
                },
                publishCaptureState: { isCapturing, statusText, sessionId in
                    states.append((isCapturing, statusText, sessionId))
                }
            )
        )

        let startA = Task {
            await controller.startCapture()
        }
        await fulfillment(of: [requestA], timeout: 1.0)

        await controller.stopCapture()

        let startB = Task {
            await controller.startCapture()
        }
        await fulfillment(of: [requestB], timeout: 1.0)

        let resumedB = await permissionGate.resume(1, value: true)
        XCTAssertTrue(resumedB)
        let resumedA = await permissionGate.resume(0, value: false)
        XCTAssertTrue(resumedA)

        let resultA = await startA.value
        let resultB = await startB.value
        XCTAssertFalse(resultA.ok)
        XCTAssertTrue(resultB.ok)

        XCTAssertEqual(states.filter { $0.0 }.count, 1)
        XCTAssertEqual(states.filter { !$0.0 }.count, 0)

        guard let token = controller.debugSessionToken,
              let recorder = controller.debugRecorder else {
            XCTFail("session missing")
            return
        }
        await controller.stopCapture()
        await controller.debugResolveRecorderFinish(recorder, success: true, token: token)
        XCTAssertEqual(states.filter { !$0.0 }.count, 1)

        try? FileManager.default.removeItem(at: root)
    }

    func testScheduledStopWithoutAnyChunkDoesNotPublishCompleteSession() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("scheduled-stop-without-chunk")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let firstChunk = ScheduledChunkRecorder.Chunk(
            index: 0,
            url: tempRoot.appendingPathComponent("chunk_0.m4a"),
            scheduledDeviceTime: 0,
            startOffsetSec: 0
        )
        let coordinator = FakeScheduledChunkCoordinator(
            startResult: .success(firstChunk),
            activeChunk: firstChunk,
            isCapturing: true
        )
        var exportedSessions: [URL] = []

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                useScheduledChunkPrototype: true,
                scheduledChunkRecorder: { _, _, _, _ in coordinator },
                enqueueCompletedSession: { exportedSessions.append($0) }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken,
              let sessionDirectory = controller.debugSessionDirectory else {
            return XCTFail("start capture failed")
        }

        await controller.stopCapture()
        await controller.debugHandleScheduledChunkEvent(.stopped, token: token)

        XCTAssertTrue(exportedSessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
        XCTAssertEqual(controller.message, "没有生成有效音频，未创建会话。")

        try? FileManager.default.removeItem(at: root)
    }

    func testScheduledPrototypeZeroDurationFinalChunkIsDiscarded() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("scheduled-zero-duration-final")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let firstChunk = ScheduledChunkRecorder.Chunk(
            index: 0,
            url: tempRoot.appendingPathComponent("chunk_0.m4a"),
            scheduledDeviceTime: 0,
            startOffsetSec: 0
        )
        let zeroChunk = ScheduledChunkRecorder.Chunk(
            index: 1,
            url: tempRoot.appendingPathComponent("chunk_1.m4a"),
            scheduledDeviceTime: 9.75,
            startOffsetSec: 9.75
        )
        FileManager.default.createFile(atPath: firstChunk.url.path, contents: Data([0x01]))
        FileManager.default.createFile(atPath: zeroChunk.url.path, contents: Data([0x01]))

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                resolveFinalizedChunkDuration: { url in
                    if url == firstChunk.url {
                        return 0.5
                    }
                    return 0
                },
                useScheduledChunkPrototype: true,
                scheduledChunkRecorder: { _, _, _, _ in
                    FakeScheduledChunkCoordinator(
                        startResult: .success(firstChunk),
                        activeChunk: firstChunk,
                        scheduledChunk: zeroChunk,
                        isCapturing: true
                    )
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken,
              let sessionDirectory = controller.debugSessionDirectory else {
            XCTFail("start capture failed")
            return
        }

        await controller.debugHandleScheduledChunkEvent(.chunkFinished(firstChunk, successfully: true), token: token)
        await controller.debugHandleScheduledChunkEvent(.chunkFinished(zeroChunk, successfully: true), token: token)
        await controller.debugHandleScheduledChunkEvent(.stopped, token: token)

        let (status, manifest) = try await awaitSessionArtifacts(sessionDirectory)
        XCTAssertEqual(status.state, .complete)
        XCTAssertEqual(manifest.chunks.count, 1)
        XCTAssertFalse(manifest.chunks.contains(where: { $0.index == 1 }))

        try? FileManager.default.removeItem(at: root)
    }

    func testScheduledPrototypeZeroDurationDuringRecordingIsNotAddedToManifest() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("scheduled-zero-duration-mid")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let fullChunk = ScheduledChunkRecorder.Chunk(
            index: 0,
            url: tempRoot.appendingPathComponent("chunk_0.m4a"),
            scheduledDeviceTime: 0,
            startOffsetSec: 0
        )
        let zeroChunk = ScheduledChunkRecorder.Chunk(
            index: 1,
            url: tempRoot.appendingPathComponent("chunk_1.m4a"),
            scheduledDeviceTime: 9.75,
            startOffsetSec: 9.75
        )
        FileManager.default.createFile(atPath: fullChunk.url.path, contents: Data([0x01]))
        FileManager.default.createFile(atPath: zeroChunk.url.path, contents: Data([0x01]))

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                resolveFinalizedChunkDuration: { url in
                    if url == fullChunk.url {
                        return 0.4
                    }
                    return 0
                },
                useScheduledChunkPrototype: true,
                scheduledChunkRecorder: { _, _, _, _ in
                    FakeScheduledChunkCoordinator(
                        startResult: .success(fullChunk),
                        activeChunk: fullChunk,
                        scheduledChunk: zeroChunk,
                        isCapturing: true
                    )
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken,
              let sessionDirectory = controller.debugSessionDirectory else {
            XCTFail("start capture failed")
            return
        }

        await controller.debugHandleScheduledChunkEvent(.chunkFinished(fullChunk, successfully: true), token: token)
        await controller.debugHandleScheduledChunkEvent(.chunkFinished(zeroChunk, successfully: true), token: token)
        await controller.debugHandleScheduledChunkEvent(.stopped, token: token)

        let (status, manifest) = try await awaitSessionArtifacts(sessionDirectory)
        XCTAssertEqual(status.state, .complete)
        XCTAssertEqual(manifest.chunks.count, 1)
        XCTAssertEqual(manifest.chunks.map(\.index), [0])
        XCTAssertNotNil(status.detail)

        try? FileManager.default.removeItem(at: root)
    }

    func testScheduledPrototypeFailureDetailSurvivesSuccessfulShortTail() async throws {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("scheduled-failure-detail-tail")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let firstChunk = ScheduledChunkRecorder.Chunk(
            index: 0,
            url: tempRoot.appendingPathComponent("chunk_0.m4a"),
            scheduledDeviceTime: 0,
            startOffsetSec: 0
        )
        let shortChunk = ScheduledChunkRecorder.Chunk(
            index: 1,
            url: tempRoot.appendingPathComponent("chunk_1.m4a"),
            scheduledDeviceTime: 9.75,
            startOffsetSec: 9.75
        )
        FileManager.default.createFile(atPath: firstChunk.url.path, contents: Data([0x01]))
        FileManager.default.createFile(atPath: shortChunk.url.path, contents: Data([0x01]))

        let coordinator = FakeScheduledChunkCoordinator(
            startResult: .success(firstChunk),
            activeChunk: firstChunk,
            scheduledChunk: shortChunk,
            isCapturing: true
        )

        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { tempRoot },
                resolveFinalizedChunkDuration: { url in
                    if url == firstChunk.url {
                        return 0.5
                    }
                    return 0.1
                },
                useScheduledChunkPrototype: true,
                scheduledChunkRecorder: { _, _, _, _ in coordinator }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken,
              let sessionDirectory = controller.debugSessionDirectory else {
            XCTFail("start capture failed")
            return
        }

        await controller.debugHandleScheduledChunkEvent(.failed("encoding failed"), token: token)
        await controller.debugHandleScheduledChunkEvent(.chunkFinished(firstChunk, successfully: true), token: token)
        await controller.stopCapture()
        await controller.debugHandleScheduledChunkEvent(.chunkFinished(shortChunk, successfully: true), token: token)
        await controller.debugHandleScheduledChunkEvent(.stopped, token: token)

        let (status, manifest) = try await awaitSessionArtifacts(sessionDirectory)
        XCTAssertEqual(status.state, .complete)
        XCTAssertNotNil(status.detail)
        XCTAssertEqual(status.detail, "partial capture: encoding failed")
        XCTAssertEqual(manifest.chunks.count, 2)
        XCTAssertEqual(manifest.chunks.map(\.index), [0, 1])

        try? FileManager.default.removeItem(at: root)
    }

    func testDefaultProviderClosuresDoNotKeepCaptureControllerAlive() {
        weak var weakController: CaptureController?

        autoreleasepool {
            let controller = CaptureController()
            weakController = controller
            _ = controller.debugInterruptionGeneration
        }

        XCTAssertNil(weakController)
    }

    func testTearDownUsesCapturedRootAndReportsDeleteFailure() async {
        let controller = CaptureController()
        let root = controller.makeTemporaryRoot("stable-root")
        try? FileManager.default.removeItem(at: root)
        let tempRoot = root.appendingPathComponent(UUID().uuidString)
        let outsideRoot = root.appendingPathComponent("outside")
        try? FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        var teardownEvents: [String] = []
        var createdRecorder: FakeCaptureRecorder?
        var recorderDuringDeinit: [String] = []

        controller.installTestDependencies(
            .init(
                requestPermission: {
                    return true
                },
                configureSession: {
                    return
                },
                deactivateSession: {
                    if createdRecorder?.isRecording == true {
                        teardownEvents.append("deactivate-before-stop")
                    } else {
                        teardownEvents.append("deactivate")
                    }
                    recorderDuringDeinit = createdRecorder?.events ?? []
                },
                recordingsRoot: {
                    return tempRoot
                },
                createSessionDirectory: { _, sessionId, _ in
                    let session = outsideRoot.appendingPathComponent("session-\(sessionId)", isDirectory: true)
                    let audio = session.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
                    try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
                    return session
                },
                createRecorder: { url, _ in
                    let recorder = FakeCaptureRecorder(url: url)
                    createdRecorder = recorder
                    return recorder
                }
            )
        )

        let result = await controller.startCapture()
        XCTAssertTrue(result.ok)
        guard let token = controller.debugSessionToken else {
            XCTFail("sessionToken missing")
            return
        }

        await controller.debugTearDown(markComplete: false, token: token)

        XCTAssertEqual(createdRecorder?.events, ["delegate=set", "prepare", "record", "delegate=nil", "stop"])
        XCTAssertEqual(recorderDuringDeinit, createdRecorder?.events)
        XCTAssertEqual(teardownEvents, ["deactivate"])
        XCTAssertEqual(controller.debugLifecycle, "idle")
        XCTAssertNotNil(controller.message)
        XCTAssertTrue(controller.message?.contains("清理会话失败") == true)

        try? FileManager.default.removeItem(at: root)
    }
}
