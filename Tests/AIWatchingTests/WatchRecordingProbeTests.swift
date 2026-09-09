import Foundation
import XCTest
import AVFoundation
@testable import AIWatching

private final class FakeProbeRecorder: WatchRecordingProbeRecording {
    let url: URL
    let prepareResult: Bool
    let recordResult: Bool

    private(set) var isRecording = false
    private(set) var prepareCallCount = 0
    private(set) var recordCallCount = 0
    private(set) var stopCallCount = 0

    init(url: URL, prepareResult: Bool = true, recordResult: Bool = true) {
        self.url = url
        self.prepareResult = prepareResult
        self.recordResult = recordResult
    }

    func prepareToRecord() -> Bool {
        prepareCallCount += 1
        return prepareResult
    }

    func record() -> Bool {
        recordCallCount += 1
        isRecording = recordResult
        return recordResult
    }

    func stop() {
        stopCallCount += 1
        isRecording = false
    }
}

private enum ProbeFactoryFailure: Error {
    case failed
}

private final class FakeProbeRecorderFactory: WatchRecordingProbeRecorderFactory {
    private let nextOutputProvider: (URL) -> Result<WatchRecordingProbeRecording, Error>
    private(set) var createCallCount = 0

    init(nextResult: Result<WatchRecordingProbeRecording, Error>) {
        self.nextOutputProvider = { _ in nextResult }
    }

    init(nextResultProvider: @escaping (URL) -> Result<WatchRecordingProbeRecording, Error>) {
        self.nextOutputProvider = nextResultProvider
    }

    func makeRecorder(url: URL, settings: [String: Any]) throws -> WatchRecordingProbeRecording {
        createCallCount += 1
        return try nextOutputProvider(url).get()
    }
}

private final class FakeTransferClient: WatchRecordingProbeTransferClient, @unchecked Sendable {
    struct Call {
        let fileURL: URL
        let metadata: [String: Any]
    }

    private(set) var calls: [Call] = []
    var nextError: Error?

    func transfer(fileURL: URL, metadata: [String: Any]) throws {
        if let nextError {
            throw nextError
        }
        calls.append(Call(fileURL: fileURL, metadata: metadata))
    }
}

private final class WatchApplicationAckBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAcks: [WatchChunkApplicationAck] = []

    var acks: [WatchChunkApplicationAck] {
        lock.lock()
        defer { lock.unlock() }
        return storedAcks
    }

    func append(_ ack: WatchChunkApplicationAck) {
        lock.lock()
        defer { lock.unlock() }
        storedAcks.append(ack)
    }
}

private final class ProbeDeactivationRecorder {
    private(set) var deactivateCount = 0

    @MainActor
    func deactivate() {
        deactivateCount += 1
    }
}

private extension URL {
    func clearIfExists() {
        let manager = FileManager.default
        if manager.fileExists(atPath: path) {
            try? manager.removeItem(at: self)
        }
    }
}

@MainActor
final class WatchRecordingProbeTests: XCTestCase {
    func testPermissionAwaitPreventsConcurrentDoubleStart() async {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var permissionContinuation: CheckedContinuation<Bool, Never>?
        let factory = FakeProbeRecorderFactory(
            nextResultProvider: { url in
                try? Data([0x01]).write(to: url)
                return .success(FakeProbeRecorder(url: url))
            }
        )

        let transferClient = FakeTransferClient()
        let controller = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: {
                await withCheckedContinuation { continuation in
                    permissionContinuation = continuation
                }
            },
            recorderFactory: factory,
            transferClient: transferClient,
            resolveDurationProvider: { _ in 1.5 },
            setupAudioSession: {},
            deactivateAudioSession: {}
        )

        let first = Task { await controller.start() }
        let second = Task { await controller.start() }

        await Task.yield()
        XCTAssertEqual(controller.state, .starting)
        XCTAssertEqual(factory.createCallCount, 0)

        permissionContinuation?.resume(returning: true)
        await first.value
        await second.value

        XCTAssertEqual(controller.state, .recording)
        XCTAssertEqual(factory.createCallCount, 1)
        XCTAssertEqual(controller.lastError, nil)
        await controller.stop()
        XCTAssertEqual(factory.createCallCount, 1)
    }

    func testStartAStopThenStartBAndOlderPermissionCallbackIgnored() async {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var permissionContinuations: [CheckedContinuation<Bool, Never>] = []
        let factory = FakeProbeRecorderFactory(
            nextResultProvider: { url in
                try? Data([0x01]).write(to: url)
                return .success(FakeProbeRecorder(url: url))
            }
        )
        let transferClient = FakeTransferClient()

        let controller = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: {
                await withCheckedContinuation { continuation in
                    permissionContinuations.append(continuation)
                }
            },
            recorderFactory: factory,
            transferClient: transferClient,
            resolveDurationProvider: { _ in 2.0 },
            setupAudioSession: {},
            deactivateAudioSession: {}
        )

        let startA = Task { await controller.start() }
        await Task.yield()

        await controller.stop()
        XCTAssertEqual(controller.state, .idle)

        let startB = Task { await controller.start() }
        await Task.yield()

        XCTAssertEqual(permissionContinuations.count, 2)

        permissionContinuations[1].resume(returning: true)
        permissionContinuations.removeLast()
        permissionContinuations[0].resume(returning: true)
        permissionContinuations.removeLast()

        await startB.value
        await startA.value

        XCTAssertEqual(factory.createCallCount, 1)
        XCTAssertEqual(controller.state, .recording)

        await controller.stop()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(transferClient.calls.count, 1)
        XCTAssertNotNil(UUID(uuidString: transferClient.calls[0].metadata["sessionId"] as? String ?? ""))
    }

    func testRecordingStartedAtIsCapturedAfterPermissionCompletes() async {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var permissionContinuation: CheckedContinuation<Bool, Never>?
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let expectedStartedAt = Date(timeIntervalSince1970: 1_700_000_120)
        let transferClient = FakeTransferClient()
        let controller = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: {
                await withCheckedContinuation { permissionContinuation = $0 }
            },
            recorderFactory: FakeProbeRecorderFactory(
                nextResultProvider: { url in
                    try? Data([0x01]).write(to: url)
                    return .success(FakeProbeRecorder(url: url))
                }
            ),
            transferClient: transferClient,
            resolveDurationProvider: { _ in 2.0 },
            setupAudioSession: {},
            deactivateAudioSession: {},
            now: { clock }
        )

        let startTask = Task { await controller.start() }
        await Task.yield()
        clock = expectedStartedAt
        permissionContinuation?.resume(returning: true)
        await startTask.value
        await controller.stop()

        XCTAssertEqual(transferClient.calls.count, 1)
        XCTAssertEqual(
            transferClient.calls[0].metadata["startedAt"] as? String,
            AIWatchingClock.isoString(expectedStartedAt)
        )
    }

    func testStopDuringStartingCancelsStartGeneration() async {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var permissionContinuation: CheckedContinuation<Bool, Never>?
        var createdPath: URL?
        let factory = FakeProbeRecorderFactory(
            nextResultProvider: { url in
                createdPath = url
                try? Data([0x01]).write(to: url)
                return .success(FakeProbeRecorder(url: url))
            }
        )

        let controller = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: {
                await withCheckedContinuation { continuation in
                    permissionContinuation = continuation
                }
            },
            recorderFactory: factory,
            transferClient: FakeTransferClient(),
            resolveDurationProvider: { _ in 1.0 },
            setupAudioSession: {},
            deactivateAudioSession: {}
        )

        let startTask = Task { await controller.start() }
        await Task.yield()
        await controller.stop()

        XCTAssertEqual(controller.state, .idle)
        permissionContinuation?.resume(returning: true)
        await startTask.value

        XCTAssertEqual(factory.createCallCount, 0)
        XCTAssertNil(controller.lastError)
        if let createdPath {
            XCTAssertFalse(FileManager.default.fileExists(atPath: createdPath.path))
        }
    }

    func testPrepareFailureCleansCreatedFile() async {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var createdFileURL: URL?
        let factory = FakeProbeRecorderFactory(
            nextResultProvider: { url in
                createdFileURL = url
                try? Data([0x01]).write(to: url)
                return .success(FakeProbeRecorder(url: url, prepareResult: false))
            }
        )

        let controller = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: { true },
            recorderFactory: factory,
            transferClient: FakeTransferClient(),
            resolveDurationProvider: { _ in 1.0 },
            setupAudioSession: {},
            deactivateAudioSession: {}
        )

        await controller.start()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(factory.createCallCount, 1)
        XCTAssertNotNil(createdFileURL)
        if let createdFileURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: createdFileURL.path), "prepare 失败必须清理创建文件")
        }
    }

    func testRecordFailureCleansCreatedFile() async {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var createdFileURL: URL?
        let factory = FakeProbeRecorderFactory(
            nextResultProvider: { url in
                createdFileURL = url
                try? Data([0x01]).write(to: url)
                return .success(FakeProbeRecorder(url: url, recordResult: false))
            }
        )

        let controller = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: { true },
            recorderFactory: factory,
            transferClient: FakeTransferClient(),
            resolveDurationProvider: { _ in 1.0 },
            setupAudioSession: {},
            deactivateAudioSession: {}
        )

        await controller.start()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(factory.createCallCount, 1)
        if let createdFileURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: createdFileURL.path), "record 失败必须清理创建文件")
        }
    }

    func testFactoryFailureCleansCreatedFile() async {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var createdFileURL: URL?
        let factory = FakeProbeRecorderFactory(
            nextResultProvider: { url in
                createdFileURL = url
                try? Data([0x01]).write(to: url)
                return .failure(ProbeFactoryFailure.failed)
            }
        )

        let controller = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: { true },
            recorderFactory: factory,
            transferClient: FakeTransferClient(),
            resolveDurationProvider: { _ in 1.0 },
            setupAudioSession: {},
            deactivateAudioSession: {}
        )

        await controller.start()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(factory.createCallCount, 1)
        XCTAssertNotNil(createdFileURL)
        if let createdFileURL {
            XCTAssertFalse(FileManager.default.fileExists(atPath: createdFileURL.path), "factory 失败必须清理创建文件")
        }
    }

    func testNormalStopTransfersFileAndRetryFailureState() async {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let transferClient = FakeTransferClient()
        let factory = FakeProbeRecorderFactory(
            nextResultProvider: { url in
                try? Data([0x01, 0x02]).write(to: url)
                return .success(FakeProbeRecorder(url: url))
            }
        )

        let controller = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: { true },
            recorderFactory: factory,
            transferClient: transferClient,
            resolveDurationProvider: { _ in 2.5 },
            setupAudioSession: {},
            deactivateAudioSession: {}
        )

        await controller.start()
        await controller.stop()

        XCTAssertEqual(transferClient.calls.count, 1)
        XCTAssertFalse(controller.hasPendingTransfer)
        XCTAssertNil(controller.lastError)
        XCTAssertNotNil(controller.lastDurationSec)
    }

    func testTransferFailureRetainsPendingStateAndCanRetry() async {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let transferClient = FakeTransferClient()
        transferClient.nextError = NSError(domain: "probe", code: 1)

        let factory = FakeProbeRecorderFactory(
            nextResultProvider: { url in
                try? Data([0x01, 0x02]).write(to: url)
                return .success(FakeProbeRecorder(url: url))
            }
        )

        let controller = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: { true },
            recorderFactory: factory,
            transferClient: transferClient,
            resolveDurationProvider: { _ in 2.0 },
            setupAudioSession: {},
            deactivateAudioSession: {}
        )

        await controller.start()
        await controller.stop()

        XCTAssertEqual(controller.hasPendingTransfer, true)
        guard let pendingFileURL = controller.pendingTransferFileURL else {
            return XCTFail("transfer 失败后应有待传输文件")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingFileURL.path))

        transferClient.nextError = nil
        controller.retryPendingTransfer()

        XCTAssertEqual(transferClient.calls.count, 1)
        XCTAssertFalse(controller.hasPendingTransfer)
        XCTAssertNil(controller.lastError)
    }

    func testStartIsBlockedWhenPendingTransferAndKeepsPendingState() async {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var permissionCallCount = 0
        let transferClient = FakeTransferClient()
        transferClient.nextError = NSError(domain: "probe", code: 1)

        let factory = FakeProbeRecorderFactory(
            nextResultProvider: { url in
                try? Data([0x01, 0x02]).write(to: url)
                return .success(FakeProbeRecorder(url: url))
            }
        )

        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        let fixedFormatter = ISO8601DateFormatter()
        let expectedRecordedAt = fixedFormatter.string(from: fixedDate)

        let controller = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: {
                permissionCallCount += 1
                return true
            },
            recorderFactory: factory,
            transferClient: transferClient,
            resolveDurationProvider: { _ in 2.0 },
            setupAudioSession: {},
            deactivateAudioSession: {},
            now: { fixedDate }
        )

        await controller.start()
        await controller.stop()

        XCTAssertEqual(controller.hasPendingTransfer, true)
        XCTAssertEqual(permissionCallCount, 1)
        XCTAssertEqual(factory.createCallCount, 1)
        guard let pendingFileURL = controller.pendingTransferFileURL else {
            return XCTFail("transfer 失败后应有待传输文件")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingFileURL.path))
            let pendingMetadataFileName = pendingFileURL.lastPathComponent

        let previousPermissionCalls = permissionCallCount
        let previousCreateCalls = factory.createCallCount

        await controller.start()
        XCTAssertEqual(controller.statusText, "请先重试待传文件")
        XCTAssertEqual(permissionCallCount, previousPermissionCalls)
        XCTAssertEqual(factory.createCallCount, previousCreateCalls)
        XCTAssertEqual(controller.pendingTransferFileURL, pendingFileURL)
        XCTAssertEqual(controller.hasPendingTransfer, true)

        transferClient.nextError = NSError(domain: "probe", code: 2)
        controller.retryPendingTransfer()

        XCTAssertEqual(transferClient.calls.count, 0)
        XCTAssertEqual(controller.hasPendingTransfer, true)
        XCTAssertEqual(permissionCallCount, previousPermissionCalls)
        XCTAssertEqual(factory.createCallCount, previousCreateCalls)
        XCTAssertEqual(controller.pendingTransferFileURL, pendingFileURL)

        transferClient.nextError = nil
        controller.retryPendingTransfer()

        XCTAssertEqual(controller.hasPendingTransfer, false)
        XCTAssertEqual(transferClient.calls.count, 1)
        if let call = transferClient.calls.first {
            XCTAssertEqual(call.fileURL, pendingFileURL)
            XCTAssertEqual(call.metadata["fileName"] as? String, pendingMetadataFileName)
            XCTAssertEqual(call.metadata["durationSec"] as? TimeInterval, 2.0)
            XCTAssertEqual(call.metadata["startedAt"] as? String, expectedRecordedAt)
            XCTAssertEqual(call.metadata["aiwatchingWatchProbe"] as? Bool, true)
        }

        XCTAssertEqual(controller.statusText, "待传输任务已入队")

        let secondStartPermission = permissionCallCount
        let secondStartCreate = factory.createCallCount
        await controller.start()
        await Task.yield()

        XCTAssertEqual(permissionCallCount, secondStartPermission + 1)
        XCTAssertEqual(factory.createCallCount, secondStartCreate + 1)
        XCTAssertEqual(controller.hasPendingTransfer, false)
    }

    func testStartDoesNotClearPendingTransfer() async {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let transferClient = FakeTransferClient()
        transferClient.nextError = NSError(domain: "probe", code: 1)

        let factory = FakeProbeRecorderFactory(
            nextResultProvider: { url in
                try? Data([0x01, 0x02]).write(to: url)
                return .success(FakeProbeRecorder(url: url))
            }
        )

        let controller = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: { true },
            recorderFactory: factory,
            transferClient: transferClient,
            resolveDurationProvider: { _ in 2.0 },
            setupAudioSession: {},
            deactivateAudioSession: {}
        )

        await controller.start()
        await controller.stop()

        XCTAssertTrue(controller.hasPendingTransfer)

        await controller.start()
        XCTAssertTrue(controller.hasPendingTransfer, "启动录音不应清空未处理 pending transfer")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.statusText, "请先重试待传文件")
        controller.resetState()
        XCTAssertTrue(controller.hasPendingTransfer)
    }

    func testStopDuringStartingSetsIdleAndClearsState() async {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var permissionContinuation: CheckedContinuation<Bool, Never>?
        let controller = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: {
                await withCheckedContinuation { continuation in
                    permissionContinuation = continuation
                }
            },
            recorderFactory: FakeProbeRecorderFactory(nextResult: .success(FakeProbeRecorder(url: tempRoot.appendingPathComponent("x.m4a")))),
            transferClient: FakeTransferClient(),
            resolveDurationProvider: { _ in 1.0 },
            setupAudioSession: {},
            deactivateAudioSession: {}
        )

        let startTask = Task { await controller.start() }
        await Task.yield()
        await controller.stop()

        XCTAssertEqual(controller.state, .idle)
        permissionContinuation?.resume(returning: true)
        await startTask.value
        XCTAssertEqual(controller.state, .idle)
    }

    func testResetStopsRecorderAndDeactivatesAudioSession() async {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let recorder = FakeProbeRecorder(url: tempRoot.appendingPathComponent("probe.m4a"))
        let factory = FakeProbeRecorderFactory(nextResult: .success(recorder))
        let deactivate = ProbeDeactivationRecorder()

        let controller = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: { true },
            recorderFactory: factory,
            transferClient: FakeTransferClient(),
            resolveDurationProvider: { _ in 1.0 },
            setupAudioSession: {},
            deactivateAudioSession: { @MainActor in deactivate.deactivate() }
        )

        await controller.start()
        controller.resetState()

        XCTAssertEqual(recorder.stopCallCount, 1)
        XCTAssertEqual(deactivate.deactivateCount, 1)
        XCTAssertEqual(controller.state, .idle)
    }

    func testNoTransferWhenMissingOrInvalidFileOrShortDuration() async {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let transferClient = FakeTransferClient()

        let missing = tempRoot.appendingPathComponent("missing.m4a")
        let missingFactory = FakeProbeRecorderFactory(nextResult: .success(FakeProbeRecorder(url: missing)))
        let missingController = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: { true },
            recorderFactory: missingFactory,
            transferClient: transferClient,
            resolveDurationProvider: { _ in 2.0 },
            setupAudioSession: {},
            deactivateAudioSession: {}
        )
        await missingController.start()
        await missingController.stop()
        XCTAssertEqual(transferClient.calls.count, 0)

        let empty = tempRoot.appendingPathComponent("empty.m4a")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        let emptyFactory = FakeProbeRecorderFactory(nextResult: .success(FakeProbeRecorder(url: empty)))
        let emptyController = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: { true },
            recorderFactory: emptyFactory,
            transferClient: transferClient,
            resolveDurationProvider: { _ in 2.0 },
            setupAudioSession: {},
            deactivateAudioSession: {}
        )
        await emptyController.start()
        await emptyController.stop()
        XCTAssertEqual(transferClient.calls.count, 0)

        let short = tempRoot.appendingPathComponent("short.m4a")
        try? Data([0x01]).write(to: short)
        let shortFactory = FakeProbeRecorderFactory(nextResult: .success(FakeProbeRecorder(url: short)))
        let shortController = WatchRecordingProbeController(
            documentsProvider: { tempRoot },
            requestPermission: { true },
            recorderFactory: shortFactory,
            transferClient: transferClient,
            resolveDurationProvider: { _ in 0.05 },
            setupAudioSession: {},
            deactivateAudioSession: {}
        )
        await shortController.start()
        await shortController.stop()
        XCTAssertEqual(transferClient.calls.count, 0)
    }

    func testPhoneConnectivityControllerReceiveProbeMovesIntoWatchCaptureInbox() {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        PhoneConnectivityController.shared.debugResetCaptureStateForTests()
        PhoneConnectivityController.shared.installTestDependencies(
            .init(
                watchProbeTransferDocumentsDirectory: tempRoot
            )
        )

        let incoming = tempRoot.appendingPathComponent("incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)

        let sessionId = UUID().uuidString
        let startedAt = AIWatchingClock.isoString(Date(timeIntervalSinceNow: -20))
        let endedAt = AIWatchingClock.isoString()
        let metadata = WatchRecordingProbeMetadata(
            sessionId: sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSec: 2.5,
            fileName: "aivision-watch-probe-\(sessionId).m4a"
        )
        let source1 = incoming.appendingPathComponent("probe-1.m4a")
        let source2 = incoming.appendingPathComponent("probe-2.m4a")
        try? Data([0x01]).write(to: source1)

        let staged1 = PhoneConnectivityController.shared.processWatchProbeTransfer(
            fileURL: source1,
            metadata: metadata.dictionary
        )
        guard let staged1Path = staged1 else {
            return XCTFail("第一段应成功进入 probe staging")
        }
        XCTAssertEqual(staged1Path.lastPathComponent, sessionId)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged1Path.appendingPathComponent("audio.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged1Path.appendingPathComponent("metadata.json").path))

        try? Data([0x02]).write(to: source2)
        let staged2 = PhoneConnectivityController.shared.processWatchProbeTransfer(
            fileURL: source2,
            metadata: metadata.dictionary
        )
        guard let staged2Path = staged2 else {
            return XCTFail("第二段应成功进入 probe staging")
        }
        XCTAssertEqual(staged2Path.lastPathComponent, sessionId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged2Path.appendingPathComponent("audio.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged2Path.appendingPathComponent("metadata.json").path))
        XCTAssertEqual(try? Data(contentsOf: staged2Path.appendingPathComponent("audio.m4a")), Data([0x01]))

        XCTAssertNil(PhoneConnectivityController.shared.debugWatchProbeTransferLastError)
    }

    func testPhoneConnectivityControllerIgnoresNonProbeMetadataAndRecordsImportFailure() {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        PhoneConnectivityController.shared.debugResetCaptureStateForTests()
        PhoneConnectivityController.shared.installTestDependencies(
            .init(
                watchProbeTransferDocumentsDirectory: tempRoot
            )
        )

        let incoming = tempRoot.appendingPathComponent("incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)

        let ignored = incoming.appendingPathComponent("ignored.m4a")
        try? Data([0x01]).write(to: ignored)
        let ignoredResult = PhoneConnectivityController.shared.processWatchProbeTransfer(
            fileURL: ignored,
            metadata: ["other": true]
        )
        XCTAssertNil(ignoredResult)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ignored.path))
        XCTAssertNil(PhoneConnectivityController.shared.debugWatchProbeTransferLastError)

        let invalid = incoming.appendingPathComponent("invalid-metadata.m4a")
        try? Data([0x02]).write(to: invalid)
        _ = PhoneConnectivityController.shared.processWatchProbeTransfer(
            fileURL: invalid,
            metadata: ["aiwatchingWatchProbe": true]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalid.path))
        XCTAssertNotNil(PhoneConnectivityController.shared.debugWatchProbeTransferLastError)

        let missing = incoming.appendingPathComponent("missing.m4a")
        _ = PhoneConnectivityController.shared.processWatchProbeTransfer(
            fileURL: missing,
            metadata: ["aiwatchingWatchProbe": true]
        )
        XCTAssertNotNil(PhoneConnectivityController.shared.debugWatchProbeTransferLastError)

        let quarantinedRoot = tempRoot.appendingPathComponent("watch-capture-quarantine", isDirectory: true)
        let quarantinedEntries = (try? FileManager.default.contentsOfDirectory(
            at: quarantinedRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertEqual(quarantinedEntries.count, 1, "仅真实存在的非法 metadata 音频应进入 quarantine")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: quarantinedEntries[0].appendingPathComponent("audio.m4a").path
            )
        )
    }

    func testChunkStagingSendsCurrentApplicationAckAndRetriesAreIdempotent() throws {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let ackBox = WatchApplicationAckBox()
        PhoneConnectivityController.shared.debugResetCaptureStateForTests()
        PhoneConnectivityController.shared.installTestDependencies(
            .init(
                watchProbeTransferDocumentsDirectory: tempRoot,
                sendWatchChunkApplicationAck: { ackBox.append($0) }
            )
        )

        let incoming = tempRoot.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let sessionId = UUID().uuidString
        let startedAt = AIWatchingClock.isoString(Date(timeIntervalSinceNow: -30))
        let endedAt = AIWatchingClock.isoString()
        let firstAttempt = UUID().uuidString
        let secondAttempt = UUID().uuidString

        func metadata(attemptId: String, startOffset: TimeInterval = 0) -> WatchRecordingProbeMetadata {
            WatchRecordingProbeMetadata(
                metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
                sessionId: sessionId,
                startedAt: startedAt,
                endedAt: endedAt,
                durationSec: 2,
                fileName: "chunk_0000.m4a",
                chunkIndex: 0,
                chunkStartOffsetSec: startOffset,
                transferAttemptId: attemptId
            )
        }

        let firstSource = incoming.appendingPathComponent("first.m4a")
        try Data([0x01]).write(to: firstSource)
        XCTAssertNotNil(
            PhoneConnectivityController.shared.processWatchProbeTransfer(
                fileURL: firstSource,
                metadata: metadata(attemptId: firstAttempt).dictionary
            )
        )
        XCTAssertEqual(ackBox.acks, [
            WatchChunkApplicationAck(
                sessionId: sessionId,
                chunkIndex: 0,
                transferAttemptId: firstAttempt
            )
        ])

        // A retry with a new transport attempt hits the existing business unit
        // idempotently and must still ACK the attempt that just staged.
        let retrySource = incoming.appendingPathComponent("retry.m4a")
        try Data([0x99]).write(to: retrySource)
        XCTAssertNotNil(
            PhoneConnectivityController.shared.processWatchProbeTransfer(
                fileURL: retrySource,
                metadata: metadata(attemptId: secondAttempt).dictionary
            )
        )
        XCTAssertEqual(ackBox.acks.last, WatchChunkApplicationAck(
            sessionId: sessionId,
            chunkIndex: 0,
            transferAttemptId: secondAttempt
        ))
        XCTAssertEqual(ackBox.acks.count, 2)

        let inbox = tempRoot
            .appendingPathComponent("watch-capture-inbox", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        XCTAssertEqual(
            try Data(contentsOf: inbox.appendingPathComponent("chunk_0000.m4a")),
            Data([0x01])
        )
    }

    func testInvalidMetadataConflictMoveAndPersistFailuresNeverSendApplicationAck() throws {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let ackBox = WatchApplicationAckBox()
        PhoneConnectivityController.shared.debugResetCaptureStateForTests()
        PhoneConnectivityController.shared.installTestDependencies(
            .init(
                watchProbeTransferDocumentsDirectory: tempRoot,
                sendWatchChunkApplicationAck: { ackBox.append($0) }
            )
        )

        let incoming = tempRoot.appendingPathComponent("incoming", isDirectory: true)
        try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
        let sessionId = UUID().uuidString
        let startedAt = AIWatchingClock.isoString(Date(timeIntervalSinceNow: -30))
        let endedAt = AIWatchingClock.isoString()
        func metadata(
            attemptId: String,
            startOffset: TimeInterval = 0,
            chunkIndex: Int = 0
        ) -> WatchRecordingProbeMetadata {
            WatchRecordingProbeMetadata(
                metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
                sessionId: sessionId,
                startedAt: startedAt,
                endedAt: endedAt,
                durationSec: 2,
                fileName: "chunk_\(String(format: "%04d", chunkIndex)).m4a",
                chunkIndex: chunkIndex,
                chunkStartOffsetSec: startOffset,
                transferAttemptId: attemptId
            )
        }

        let invalid = incoming.appendingPathComponent("invalid.m4a")
        try Data([0x01]).write(to: invalid)
        XCTAssertNil(
            PhoneConnectivityController.shared.processWatchProbeTransfer(
                fileURL: invalid,
                metadata: [WatchRecordingProbeMetadata.transferFlagKey: true]
            )
        )
        XCTAssertTrue(ackBox.acks.isEmpty)

        let initial = incoming.appendingPathComponent("initial.m4a")
        try Data([0x02]).write(to: initial)
        XCTAssertNotNil(
            PhoneConnectivityController.shared.processWatchProbeTransfer(
                fileURL: initial,
                metadata: metadata(attemptId: UUID().uuidString).dictionary
            )
        )
        XCTAssertEqual(ackBox.acks.count, 1)

        let conflict = incoming.appendingPathComponent("conflict.m4a")
        try Data([0x03]).write(to: conflict)
        XCTAssertNil(
            PhoneConnectivityController.shared.processWatchProbeTransfer(
                fileURL: conflict,
                metadata: metadata(attemptId: UUID().uuidString, startOffset: 1).dictionary
            )
        )
        XCTAssertEqual(ackBox.acks.count, 1)

        let moveFailureMetadata = metadata(
            attemptId: UUID().uuidString,
            startOffset: 10,
            chunkIndex: 1
        )
        let moveFailureSession = tempRoot
            .appendingPathComponent("watch-capture-inbox", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        let moveFailureSidecar = moveFailureSession.appendingPathComponent(
            WatchCaptureImporter.chunkMetadataFileName(chunkIndex: 1)
        )
        try WatchCaptureImporter().writeMetadata(
            moveFailureMetadata.withoutTransferAttemptId(),
            to: moveFailureSidecar
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o555)],
            ofItemAtPath: moveFailureSession.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o755)],
                ofItemAtPath: moveFailureSession.path
            )
        }
        let moveFailureSource = incoming.appendingPathComponent("move-failure.m4a")
        try Data([0x04]).write(to: moveFailureSource)
        XCTAssertNil(
            PhoneConnectivityController.shared.processWatchProbeTransfer(
                fileURL: moveFailureSource,
                metadata: moveFailureMetadata.dictionary
            )
        )
        XCTAssertEqual(ackBox.acks.count, 1)

        let persistFailureRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: persistFailureRoot) }
        let persistAckBox = WatchApplicationAckBox()
        PhoneConnectivityController.shared.debugResetCaptureStateForTests()
        PhoneConnectivityController.shared.installTestDependencies(
            .init(
                watchProbeTransferDocumentsDirectory: persistFailureRoot,
                sendWatchChunkApplicationAck: { persistAckBox.append($0) },
                persistWatchProbeMetadata: { _, _ in
                    struct PersistFailure: Error {}
                    throw PersistFailure()
                }
            )
        )
        let persistIncoming = persistFailureRoot.appendingPathComponent("persist-failure.m4a")
        try Data([0x04]).write(to: persistIncoming)
        let persistMetadata = WatchRecordingProbeMetadata(
            metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
            sessionId: UUID().uuidString,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSec: 2,
            fileName: "chunk_0000.m4a",
            chunkIndex: 0,
            chunkStartOffsetSec: 0,
            transferAttemptId: UUID().uuidString
        )
        XCTAssertNil(
            PhoneConnectivityController.shared.processWatchProbeTransfer(
                fileURL: persistIncoming,
                metadata: persistMetadata.dictionary
            )
        )
        XCTAssertTrue(persistAckBox.acks.isEmpty)
    }
    // MARK: - STAGE-005B chunked (v2) transfer staging

    func testChunkedMetadataDictionaryValidation() {
        let base: [String: Any] = [
            "aiwatchingWatchProbe": true,
            "metadataVersion": 2,
            "sessionId": UUID().uuidString,
            "startedAt": AIWatchingClock.isoString(Date(timeIntervalSinceNow: -30)),
            "endedAt": AIWatchingClock.isoString(),
            "durationSec": 4.2,
            "fileName": "aiwatching-watch-chunk-1.m4a",
            "source": "watch",
        ]

        var valid = base
        valid["chunkIndex"] = 1
        valid["chunkStartOffsetSec"] = 12.5
        valid["chunkCount"] = 2
        let parsed = WatchRecordingProbeMetadata(dictionary: valid)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.chunkIndex, 1)
        XCTAssertEqual(parsed?.chunkStartOffsetSec, 12.5)
        XCTAssertEqual(parsed?.chunkCount, 2)
        XCTAssertEqual(parsed?.isFinalChunk, true)

        // chunkCount must equal chunkIndex + 1 (self-validating final marker).
        var badCount = valid
        badCount["chunkCount"] = 3
        XCTAssertNil(WatchRecordingProbeMetadata(dictionary: badCount))

        // Reject unsupported metadata versions.
        var unsupportedVersion = valid
        unsupportedVersion["metadataVersion"] = 9
        XCTAssertNil(WatchRecordingProbeMetadata(dictionary: unsupportedVersion))

        // v2 requires chunk fields.
        XCTAssertNil(WatchRecordingProbeMetadata(dictionary: base))

        var negativeIndex = valid
        negativeIndex["chunkIndex"] = -1
        negativeIndex.removeValue(forKey: "chunkCount")
        XCTAssertNil(WatchRecordingProbeMetadata(dictionary: negativeIndex))

        // v1 stays valid and normalizes to a single-chunk session.
        var v1 = base
        v1["metadataVersion"] = 1
        let parsedV1 = WatchRecordingProbeMetadata(dictionary: v1)
        XCTAssertNotNil(parsedV1)
        XCTAssertEqual(parsedV1?.chunkIndex, 0)
        XCTAssertEqual(parsedV1?.chunkCount, 1)

        // Diagnostics payload can be carried on v2, but malformed payload must fail decoding.
        var diagnosticsBad = valid
        diagnosticsBad["watchCaptureDiagnosticsJSON"] = "not-json"
        XCTAssertNil(WatchRecordingProbeMetadata(dictionary: diagnosticsBad))

        var diagnosticsEventBad = valid
        diagnosticsEventBad["watchCaptureDiagnosticsJSON"] = String(
            data: try! JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "events": [[
                    "sequence": 1,
                    "kind": "recordingStarted",
                    "occurredAt": AIWatchingClock.isoString(),
                    "sessionOffsetSec": 0,
                    "controllerState": "recording",
                ]],
                "truncated": false,
            ]),
            encoding: .utf8
        )
        XCTAssertNil(WatchRecordingProbeMetadata(dictionary: diagnosticsEventBad))
    }

    func testChunkApplicationAckDictionaryRequiresExactIdentityFields() {
        let sessionId = UUID().uuidString
        let attemptId = UUID().uuidString
        let ack = WatchChunkApplicationAck(
            sessionId: sessionId,
            chunkIndex: 4,
            transferAttemptId: attemptId
        )

        XCTAssertEqual(WatchChunkApplicationAck(dictionary: ack.dictionary), ack)

        var wrongType = ack.dictionary
        wrongType[WatchChunkApplicationAck.typeKey] = "transportSuccess"
        XCTAssertNil(WatchChunkApplicationAck(dictionary: wrongType))

        var wrongFlag = ack.dictionary
        wrongFlag[WatchChunkApplicationAck.flagKey] = false
        XCTAssertNil(WatchChunkApplicationAck(dictionary: wrongFlag))

        var numericFlag = ack.dictionary
        numericFlag[WatchChunkApplicationAck.flagKey] = NSNumber(value: 1)
        XCTAssertNil(WatchChunkApplicationAck(dictionary: numericFlag))

        var missingAttempt = ack.dictionary
        missingAttempt.removeValue(forKey: "transferAttemptId")
        XCTAssertNil(WatchChunkApplicationAck(dictionary: missingAttempt))

        var negativeIndex = ack.dictionary
        negativeIndex["chunkIndex"] = -1
        XCTAssertNil(WatchChunkApplicationAck(dictionary: negativeIndex))

        var wrongIndexType = ack.dictionary
        wrongIndexType["chunkIndex"] = "4"
        XCTAssertNil(WatchChunkApplicationAck(dictionary: wrongIndexType))

        var booleanIndex = ack.dictionary
        booleanIndex["chunkIndex"] = NSNumber(value: true)
        XCTAssertNil(WatchChunkApplicationAck(dictionary: booleanIndex))

        var floatingIndex = ack.dictionary
        floatingIndex["chunkIndex"] = NSNumber(value: 4.0)
        XCTAssertNil(WatchChunkApplicationAck(dictionary: floatingIndex))

        var malformedAttempt = ack.dictionary
        malformedAttempt["transferAttemptId"] = "not-a-uuid"
        XCTAssertNil(WatchChunkApplicationAck(dictionary: malformedAttempt))

        // Real WatchConnectivity delivery bridges property-list scalars to
        // NSNumber. A Boolean CFNumber flag and integral CFNumber index remain
        // valid even though their concrete Swift types changed at the boundary.
        var bridged = ack.dictionary
        bridged[WatchChunkApplicationAck.flagKey] = NSNumber(value: true)
        bridged["chunkIndex"] = NSNumber(value: 4)
        XCTAssertEqual(WatchChunkApplicationAck(dictionary: bridged), ack)
    }

    func testMetadataVersionStrictlyValidatedByJSONDecoder() throws {
        let base: [String: Any] = [
            "aiwatchingWatchProbe": true,
            "metadataVersion": 1,
            "sessionId": UUID().uuidString,
            "startedAt": AIWatchingClock.isoString(Date(timeIntervalSinceNow: -30)),
            "endedAt": AIWatchingClock.isoString(),
            "durationSec": 4.2,
            "fileName": "aiwatching-watch-full.m4a",
            "source": "watch",
        ]

        let decoder = JSONDecoder()
        let validData = try JSONSerialization.data(withJSONObject: base)
        let parsed = try decoder.decode(WatchRecordingProbeMetadata.self, from: validData)
        XCTAssertEqual(parsed.metadataVersion, 1)

        var invalid = base
        invalid["metadataVersion"] = 9
        let invalidData = try JSONSerialization.data(withJSONObject: invalid)

        XCTAssertThrowsError(try decoder.decode(WatchRecordingProbeMetadata.self, from: invalidData)) { error in
            XCTAssertTrue(error is DecodingError)
        }

        let invalidDiagnosticsOffset: [String: Any] = [
            "schemaVersion": 1,
            "events": [[
                "sequence": 0,
                "kind": "recordingStarted",
                "occurredAt": AIWatchingClock.isoString(Date(timeIntervalSinceNow: -30)),
                "sessionOffsetSec": -0.1,
                "controllerState": "recording",
            ]],
            "truncated": false,
        ]
        var invalidOffsetMetadata: [String: Any] = [
            "metadataVersion": 2,
            "sessionId": UUID().uuidString,
            "startedAt": AIWatchingClock.isoString(Date(timeIntervalSinceNow: -30)),
            "endedAt": AIWatchingClock.isoString(),
            "durationSec": 4.2,
            "fileName": "aivision-watch-full.m4a",
            "source": "watch",
            "chunkIndex": 0,
            "chunkStartOffsetSec": 0,
            "chunkCount": 1,
            "watchCaptureDiagnosticsJSON": String(data: try JSONSerialization.data(withJSONObject: invalidDiagnosticsOffset), encoding: .utf8),
            "aiwatchingWatchProbe": true,
        ]
        let invalidOffsetData = try JSONSerialization.data(withJSONObject: invalidOffsetMetadata)
        XCTAssertThrowsError(try decoder.decode(WatchRecordingProbeMetadata.self, from: invalidOffsetData))
    }

    func testMetadataDecoderRejectsInvalidWatchCaptureDiagnosticsJSON() throws {
        let base: [String: Any] = [
            "metadataVersion": 2,
            "sessionId": UUID().uuidString,
            "startedAt": AIWatchingClock.isoString(Date(timeIntervalSinceNow: -30)),
            "endedAt": AIWatchingClock.isoString(),
            "durationSec": 4.2,
            "fileName": "aivision-watch-full.m4a",
            "source": "watch",
            "chunkIndex": 0,
            "chunkStartOffsetSec": 0,
            "chunkCount": 1,
            "watchCaptureDiagnosticsJSON": "not-a-json",
            "aiwatchingWatchProbe": true,
        ]
        let invalidData = try JSONSerialization.data(withJSONObject: base)

        XCTAssertThrowsError(
            try JSONDecoder().decode(WatchRecordingProbeMetadata.self, from: invalidData)
        ) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testMetadataDecoderRejectsNonSequentialDiagnosticsSequence() throws {
        let metadata: [String: Any] = [
            "metadataVersion": 2,
            "sessionId": UUID().uuidString,
            "startedAt": AIWatchingClock.isoString(Date(timeIntervalSinceNow: -30)),
            "endedAt": AIWatchingClock.isoString(),
            "durationSec": 4.2,
            "fileName": "aivision-watch-full.m4a",
            "source": "watch",
            "chunkIndex": 0,
            "chunkStartOffsetSec": 0,
            "chunkCount": 1,
            "watchCaptureDiagnosticsJSON": String(data: try JSONSerialization.data(withJSONObject: [
                "schemaVersion": 1,
                "events": [
                    [
                        "sequence": 0,
                        "kind": "recordingStarted",
                        "occurredAt": AIWatchingClock.isoString(Date(timeIntervalSinceNow: -30)),
                        "sessionOffsetSec": 0,
                        "controllerState": "recording",
                    ],
                    [
                        "sequence": 2,
                        "kind": "interruptionBegan",
                        "occurredAt": AIWatchingClock.isoString(),
                        "sessionOffsetSec": 1,
                        "controllerState": "interrupted",
                    ],
                ],
                "truncated": false,
            ], options: []), encoding: .utf8),
            "aiwatchingWatchProbe": true,
        ]
        let decoder = JSONDecoder()
        let data = try JSONSerialization.data(withJSONObject: metadata)
        XCTAssertThrowsError(try decoder.decode(WatchRecordingProbeMetadata.self, from: data))
    }

    func testWatchCaptureDiagnosticsEnforcesMaxEventCountRules() throws {
        let events256 = (0..<WatchCaptureDiagnostics.maxEventCount).map { index in
            WatchCaptureDiagnosticEvent(
                sequence: index,
                kind: .recordingStarted,
                occurredAt: AIWatchingClock.isoString(Date(timeIntervalSince1970: 1_700_000_000 + Double(index))),
                sessionOffsetSec: Double(index),
                controllerState: "recording",
                shouldResume: nil,
                lastFinalizedChunkIndex: nil,
                detail: nil
            )
        }
        let validDiagnostics = WatchCaptureDiagnostics(
            schemaVersion: 1,
            events: events256,
            truncated: false
        )
        XCTAssertTrue(validDiagnostics.isValid())

        let events257 = events256 + [WatchCaptureDiagnosticEvent(
            sequence: 256,
            kind: .recordingStarted,
            occurredAt: AIWatchingClock.isoString(Date(timeIntervalSince1970: 1_700_000_256)),
            sessionOffsetSec: 256,
            controllerState: "recording",
            shouldResume: nil,
            lastFinalizedChunkIndex: nil,
            detail: nil
        )]
        let invalidDiagnostics = WatchCaptureDiagnostics(
            schemaVersion: 1,
            events: events257,
            truncated: false
        )
        XCTAssertFalse(invalidDiagnostics.isValid())
    }

    func testMetadataVersion9IsRejectedByJSONDecoder() throws {
        let now = AIWatchingClock.isoString(Date(timeIntervalSince1970: 1_700_000_000))
        let diagnostics = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "events": [
                [
                    "sequence": 0,
                    "kind": "recordingStarted",
                    "occurredAt": now,
                    "sessionOffsetSec": 0.0,
                    "controllerState": "recording",
                ]
            ],
            "truncated": false,
        ])
        let metadata: [String: Any] = [
            "metadataVersion": 9,
            "sessionId": UUID().uuidString,
            "startedAt": now,
            "endedAt": now,
            "durationSec": 4.2,
            "fileName": "aivision-watch-full.m4a",
            "source": "watch",
            "chunkIndex": 0,
            "chunkStartOffsetSec": 0,
            "chunkCount": 1,
            "watchCaptureDiagnosticsJSON": String(data: diagnostics, encoding: .utf8),
            "aiwatchingWatchProbe": true,
        ]

        let payload = try JSONSerialization.data(withJSONObject: metadata)
        XCTAssertThrowsError(try JSONDecoder().decode(WatchRecordingProbeMetadata.self, from: payload))

        XCTAssertNil(WatchRecordingProbeMetadata(dictionary: metadata))
    }

    func testMetadataDictionaryRejectsTooManyDiagnosticsEvents() throws {
        let now = AIWatchingClock.isoString(Date(timeIntervalSince1970: 1_700_000_000))
        let events = (0..<256 + 1).map { index in
            [
                "sequence": index,
                "kind": "recordingStarted",
                "occurredAt": AIWatchingClock.isoString(Date(timeIntervalSince1970: 1_700_000_000 + Double(index))),
                "sessionOffsetSec": index,
                "controllerState": "recording",
            ]
        }
        let diagnosticsPayload = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "events": events,
            "truncated": false,
        ])
        let metadata: [String: Any] = [
            "metadataVersion": 2,
            "sessionId": UUID().uuidString,
            "startedAt": now,
            "endedAt": now,
            "durationSec": 4.2,
            "fileName": "aivision-watch-full.m4a",
            "source": "watch",
            "chunkIndex": 0,
            "chunkStartOffsetSec": 0,
            "chunkCount": 1,
            "watchCaptureDiagnosticsJSON": String(data: diagnosticsPayload, encoding: .utf8),
            "aiwatchingWatchProbe": true,
        ]

        XCTAssertNil(WatchRecordingProbeMetadata(dictionary: metadata))

        let payload = try JSONSerialization.data(withJSONObject: metadata)
        XCTAssertThrowsError(try JSONDecoder().decode(WatchRecordingProbeMetadata.self, from: payload))
    }

    func testPhoneConnectivityControllerStagesChunkedTransfersOutOfOrderAndImportsWhenComplete() {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        PhoneConnectivityController.shared.debugResetCaptureStateForTests()
        PhoneConnectivityController.shared.installTestDependencies(
            .init(
                watchProbeTransferDocumentsDirectory: tempRoot,
                sendWatchChunkApplicationAck: { _ in }
            )
        )

        let incoming = tempRoot.appendingPathComponent("incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)

        let sessionId = UUID().uuidString
        let startedAt = AIWatchingClock.isoString(Date(timeIntervalSinceNow: -60))
        let endedAt = AIWatchingClock.isoString()

        func chunkMetadata(
            _ index: Int,
            isFinal: Bool,
            transferAttemptId: String? = nil
        ) -> WatchRecordingProbeMetadata {
            WatchRecordingProbeMetadata(
                metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
                sessionId: sessionId,
                startedAt: startedAt,
                endedAt: endedAt,
                durationSec: 5,
                fileName: "aiwatching-watch-chunk-\(index).m4a",
                chunkIndex: index,
                chunkStartOffsetSec: TimeInterval(index * 10),
                chunkCount: isFinal ? index + 1 : nil,
                transferAttemptId: transferAttemptId
            )
        }

        // Final chunk (index 2) arrives first, then 0, then 1 — out of order.
        for (index, isFinal) in [(2, true), (0, false), (1, false)] {
            let source = incoming.appendingPathComponent("transfer-\(index).m4a")
            try? Data([UInt8(index + 1)]).write(to: source)
            let staged = PhoneConnectivityController.shared.processWatchProbeTransfer(
                fileURL: source,
                metadata: chunkMetadata(
                    index,
                    isFinal: isFinal,
                    transferAttemptId: UUID().uuidString
                ).dictionary
            )
            XCTAssertNotNil(staged, "chunk \(index) 应成功进入 staging")
        }
        XCTAssertNil(PhoneConnectivityController.shared.debugWatchProbeTransferLastError)

        let inbox = tempRoot
            .appendingPathComponent("watch-capture-inbox", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        for index in 0..<3 {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: inbox.appendingPathComponent(WatchCaptureImporter.chunkAudioFileName(chunkIndex: index)).path
            ))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: inbox.appendingPathComponent(WatchCaptureImporter.chunkMetadataFileName(chunkIndex: index)).path
            ))
        }

        // Duplicate retry of an already-staged chunk keeps the first payload.
        let retry = incoming.appendingPathComponent("transfer-0-retry.m4a")
        try? Data([0x99]).write(to: retry)
        let stagedRetry = PhoneConnectivityController.shared.processWatchProbeTransfer(
            fileURL: retry,
            metadata: chunkMetadata(
                0,
                isFinal: false,
                transferAttemptId: UUID().uuidString
            ).dictionary
        )
        XCTAssertNotNil(stagedRetry)
        XCTAssertEqual(
            try? Data(contentsOf: inbox.appendingPathComponent(WatchCaptureImporter.chunkAudioFileName(chunkIndex: 0))),
            Data([0x01])
        )
        let stagedMetadataURL = inbox.appendingPathComponent(
            WatchCaptureImporter.chunkMetadataFileName(chunkIndex: 0)
        )
        let stagedMetadataData = try? Data(contentsOf: stagedMetadataURL)
        let stagedMetadata = stagedMetadataData.flatMap {
            try? JSONDecoder().decode(WatchRecordingProbeMetadata.self, from: $0)
        }
        XCTAssertNil(stagedMetadata?.transferAttemptId)
        let quarantineRoot = tempRoot.appendingPathComponent("watch-capture-quarantine", isDirectory: true)
        let quarantined = (try? FileManager.default.contentsOfDirectory(
            at: quarantineRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        XCTAssertTrue(quarantined.isEmpty)

        // With all chunks staged, an inbox scan assembles the standard session.
        let recordingsRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: recordingsRoot) }
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 5.0 }
        )
        let failures = importer.importAllPendingWatchCaptureSessions(
            at: tempRoot.appendingPathComponent("watch-capture-inbox", isDirectory: true)
        )
        XCTAssertTrue(failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.path))

        let sessions = (try? FileManager.default.contentsOfDirectory(at: recordingsRoot, includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions[0].lastPathComponent.hasSuffix("__capture__\(sessionId)"))
    }

    func testPhoneConnectivityControllerRejectsMixedStagingLayouts() {
        let tempRoot = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        PhoneConnectivityController.shared.debugResetCaptureStateForTests()
        PhoneConnectivityController.shared.installTestDependencies(
            .init(
                watchProbeTransferDocumentsDirectory: tempRoot,
                sendWatchChunkApplicationAck: { _ in }
            )
        )

        let incoming = tempRoot.appendingPathComponent("incoming", isDirectory: true)
        try? FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)

        let sessionId = UUID().uuidString
        let startedAt = AIWatchingClock.isoString(Date(timeIntervalSinceNow: -30))
        let endedAt = AIWatchingClock.isoString()

        // Stage a v2 chunk first.
        let chunkSource = incoming.appendingPathComponent("chunk-transfer.m4a")
        try? Data([0x01]).write(to: chunkSource)
        let chunkMetadata = WatchRecordingProbeMetadata(
            metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
            sessionId: sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSec: 2,
            fileName: "aiwatching-watch-chunk-0.m4a",
            chunkIndex: 0,
            chunkStartOffsetSec: 0
        )
        XCTAssertNotNil(
            PhoneConnectivityController.shared.processWatchProbeTransfer(
                fileURL: chunkSource,
                metadata: chunkMetadata.dictionary
            )
        )

        // A v1 transfer for the same session must be rejected as a layout conflict.
        let legacySource = incoming.appendingPathComponent("legacy-transfer.m4a")
        try? Data([0x02]).write(to: legacySource)
        let legacyMetadata = WatchRecordingProbeMetadata(
            sessionId: sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSec: 2,
            fileName: "aiwatching-watch-probe.m4a"
        )
        let staged = PhoneConnectivityController.shared.processWatchProbeTransfer(
            fileURL: legacySource,
            metadata: legacyMetadata.dictionary
        )
        XCTAssertNil(staged)
        XCTAssertNotNil(PhoneConnectivityController.shared.debugWatchProbeTransferLastError)
        // The conflicting audio is quarantined, not silently dropped.
        let quarantineRoot = tempRoot.appendingPathComponent("watch-capture-quarantine", isDirectory: true)
        let quarantined = (try? FileManager.default.contentsOfDirectory(at: quarantineRoot, includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(quarantined.count, 1)
    }
}

private extension WatchRecordingProbeTests {
    func makeTempRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIWatchingProbe", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
