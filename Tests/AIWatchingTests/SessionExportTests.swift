import AVFoundation
import Foundation
import XCTest
@testable import AIWatching

private final class InMemorySessionExportDestinationStore: @unchecked Sendable, SessionExportDestinationStoring {
    private let lock = NSLock()
    private var state: SessionExportDestinationState

    init(_ state: SessionExportDestinationState) {
        self.state = state
    }

    func load() throws -> SessionExportDestinationState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func save(_ destination: SessionExportDestination) throws {
        lock.lock()
        defer { lock.unlock() }
        state = .available(destination)
    }

    func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        state = .missing
    }
}

private final class SessionExportCopyProbe: @unchecked Sendable {
    enum Mode: Sendable {
        case copy
        case permissionDenied
        case interruptBeforeStatus
    }

    struct Event: Equatable, Sendable {
        let source: URL
        let destination: URL
    }

    private let lock = NSLock()
    private var mode: Mode
    private var recordedEvents: [Event] = []

    init(mode: Mode = .copy) {
        self.mode = mode
    }

    func setMode(_ mode: Mode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

    func copyItem(from source: URL, to destination: URL) throws {
        lock.lock()
        let currentMode = mode
        lock.unlock()

        switch currentMode {
        case .permissionDenied:
            throw CocoaError(.fileWriteNoPermission)
        case .interruptBeforeStatus where source.lastPathComponent == AIWatchingSchema.statusFileName:
            throw CancellationError()
        case .copy, .interruptBeforeStatus:
            break
        }

        try FileManager.default.copyItem(at: source, to: destination)
        lock.lock()
        recordedEvents.append(Event(source: source, destination: destination))
        lock.unlock()
    }

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }
}

private final class SessionExportCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedURLs: [URL] = []

    func record(_ url: URL) {
        lock.lock()
        recordedURLs.append(url)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return recordedURLs
    }
}

private final class SessionExportTestRecorder: NSObject, CaptureRecording {
    weak var delegate: AVAudioRecorderDelegate?
    private(set) var isRecording = false
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func prepareToRecord() -> Bool { true }

    func record(forDuration duration: TimeInterval) -> Bool {
        isRecording = true
        return true
    }

    func stop() {
        isRecording = false
    }
}

@MainActor
final class SessionExportTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let sessionDirectory: URL
        let sessionId: String

        var folderName: String { sessionDirectory.lastPathComponent }
    }

    func testDestinationSelectionAndClearAreStoreBacked() async throws {
        let root = try makeTemporaryDirectory("destination-selection")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = InMemorySessionExportDestinationStore(.missing)
        let exporter = makeExporter(store: store)
        let destination = SessionExportDestination(rootURL: root, displayName: "Synthetic Folder")

        let missing = await exporter.destinationSnapshot()
        XCTAssertEqual(missing, .missing)

        try await exporter.selectDestination(destination)
        let available = await exporter.destinationSnapshot()
        XCTAssertEqual(available, .available(destination))

        try await exporter.clearDestination()
        let cleared = await exporter.destinationSnapshot()
        XCTAssertEqual(cleared, .missing)
    }

    func testMissingDestinationDefersWithoutPublishingOrDeletingSource() async throws {
        let fixture = try makeCompleteSession("destination-missing")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probe = SessionExportCopyProbe()
        let exporter = makeExporter(
            store: InMemorySessionExportDestinationStore(.missing),
            probe: probe
        )

        let accepted = try await exporter.enqueue(sessionDirectory: fixture.sessionDirectory)
        let outcomes = await exporter.flush()
        let pending = await exporter.pendingSessionIDs()

        XCTAssertTrue(accepted)
        XCTAssertEqual(outcomes, [.deferred(sessionId: fixture.sessionId, reason: .destinationMissing)])
        XCTAssertEqual(pending, [fixture.sessionId])
        XCTAssertTrue(probe.events.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
    }

    func testStaleDestinationDefersAndRequiresSelection() async throws {
        let fixture = try makeCompleteSession("destination-stale")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let exporter = makeExporter(
            store: InMemorySessionExportDestinationStore(.stale(displayName: "Old iCloud Folder"))
        )

        let accepted = try await exporter.enqueue(sessionDirectory: fixture.sessionDirectory)
        let snapshot = await exporter.destinationSnapshot()
        let outcomes = await exporter.flush()
        let pending = await exporter.pendingSessionIDs()

        XCTAssertTrue(accepted)
        XCTAssertEqual(snapshot, .stale(displayName: "Old iCloud Folder"))
        XCTAssertEqual(outcomes, [.deferred(sessionId: fixture.sessionId, reason: .destinationStale)])
        XCTAssertEqual(pending, [fixture.sessionId])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
    }

    func testPermissionDeniedKeepsJobPendingAndSourceIntact() async throws {
        let fixture = try makeCompleteSession("permission-denied")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destinationRoot = fixture.root.appendingPathComponent("destination", isDirectory: true)
        let probe = SessionExportCopyProbe(mode: .permissionDenied)
        let exporter = makeExporter(
            destinationRoot: destinationRoot,
            probe: probe
        )

        let accepted = try await exporter.enqueue(sessionDirectory: fixture.sessionDirectory)
        let outcomes = await exporter.flush()
        let pending = await exporter.pendingSessionIDs()
        let targetStatus = destinationRoot
            .appendingPathComponent(fixture.folderName, isDirectory: true)
            .appendingPathComponent(AIWatchingSchema.statusFileName)

        XCTAssertTrue(accepted)
        XCTAssertEqual(outcomes, [.failed(sessionId: fixture.sessionId, failure: .permissionDenied)])
        XCTAssertEqual(pending, [fixture.sessionId])
        XCTAssertFalse(isCompleteStatus(at: targetStatus))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))

        probe.setMode(.copy)
        let retryOutcomes = await exporter.flush()
        let retryPending = await exporter.pendingSessionIDs()

        XCTAssertEqual(retryOutcomes, [.exported(sessionId: fixture.sessionId)])
        XCTAssertTrue(retryPending.isEmpty)
        XCTAssertTrue(isCompleteStatus(at: targetStatus))
    }

    func testSuccessfulExportCopiesCompleteStatusLastAndRetainsSource() async throws {
        let fixture = try makeCompleteSession("status-last")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destinationRoot = fixture.root.appendingPathComponent("destination", isDirectory: true)
        let probe = SessionExportCopyProbe()
        let exporter = makeExporter(destinationRoot: destinationRoot, probe: probe)

        let accepted = try await exporter.enqueue(sessionDirectory: fixture.sessionDirectory)
        let outcomes = await exporter.flush()
        let pending = await exporter.pendingSessionIDs()
        let targetDirectory = destinationRoot.appendingPathComponent(fixture.folderName, isDirectory: true)
        let targetStatus = targetDirectory.appendingPathComponent(AIWatchingSchema.statusFileName)

        XCTAssertTrue(accepted)
        XCTAssertEqual(outcomes, [.exported(sessionId: fixture.sessionId)])
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(probe.events.last?.source.lastPathComponent, AIWatchingSchema.statusFileName)
        XCTAssertEqual(probe.events.last?.destination, targetStatus)
        XCTAssertTrue(isCompleteStatus(at: targetStatus))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
    }

    func testInterruptedCopyNeverPublishesCompleteAndRemainsRetryable() async throws {
        let fixture = try makeCompleteSession("copy-interrupted")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destinationRoot = fixture.root.appendingPathComponent("destination", isDirectory: true)
        let probe = SessionExportCopyProbe(mode: .interruptBeforeStatus)
        let exporter = makeExporter(destinationRoot: destinationRoot, probe: probe)

        let accepted = try await exporter.enqueue(sessionDirectory: fixture.sessionDirectory)
        let outcomes = await exporter.flush()
        let pending = await exporter.pendingSessionIDs()
        let targetStatus = destinationRoot
            .appendingPathComponent(fixture.folderName, isDirectory: true)
            .appendingPathComponent(AIWatchingSchema.statusFileName)

        XCTAssertTrue(accepted)
        XCTAssertEqual(outcomes, [.failed(sessionId: fixture.sessionId, failure: .copyInterrupted)])
        XCTAssertEqual(pending, [fixture.sessionId])
        XCTAssertFalse(isCompleteStatus(at: targetStatus))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))

        probe.setMode(.copy)
        let retryOutcomes = await exporter.flush()
        let retryPending = await exporter.pendingSessionIDs()

        XCTAssertEqual(retryOutcomes, [.exported(sessionId: fixture.sessionId)])
        XCTAssertTrue(retryPending.isEmpty)
        XCTAssertTrue(isCompleteStatus(at: targetStatus))
    }

    func testDuplicateEnqueueAndRestartRetryAreIdempotent() async throws {
        let fixture = try makeCompleteSession("idempotent")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destinationRoot = fixture.root.appendingPathComponent("destination", isDirectory: true)
        let firstExporter = makeExporter(destinationRoot: destinationRoot)

        let firstAccepted = try await firstExporter.enqueue(sessionDirectory: fixture.sessionDirectory)
        let duplicateAccepted = try await firstExporter.enqueue(sessionDirectory: fixture.sessionDirectory)
        let firstPending = await firstExporter.pendingSessionIDs()
        let firstOutcomes = await firstExporter.flush()
        XCTAssertTrue(firstAccepted)
        XCTAssertFalse(duplicateAccepted)
        XCTAssertEqual(firstPending, [fixture.sessionId])
        XCTAssertEqual(firstOutcomes, [.exported(sessionId: fixture.sessionId)])

        let restartedExporter = makeExporter(destinationRoot: destinationRoot)
        let restartedAccepted = try await restartedExporter.enqueue(sessionDirectory: fixture.sessionDirectory)
        let restartedOutcomes = await restartedExporter.flush()
        XCTAssertTrue(restartedAccepted)
        XCTAssertEqual(restartedOutcomes, [.alreadyExported(sessionId: fixture.sessionId)])

        let targetDirectories = try FileManager.default.contentsOfDirectory(
            at: destinationRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        XCTAssertEqual(targetDirectories.map(\.lastPathComponent), [fixture.folderName])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
    }

    func testRestartExportPreservesMatchingDestinationAlreadyAdvancedByMac() async throws {
        let fixture = try makeCompleteSession("preserve-mac-writeback")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destinationRoot = fixture.root.appendingPathComponent("destination", isDirectory: true)
        let initialExporter = makeExporter(destinationRoot: destinationRoot)

        let initialAccepted = try await initialExporter.enqueue(sessionDirectory: fixture.sessionDirectory)
        let initialOutcomes = await initialExporter.flush()
        XCTAssertTrue(initialAccepted)
        XCTAssertEqual(initialOutcomes, [.exported(sessionId: fixture.sessionId)])

        let targetDirectory = destinationRoot.appendingPathComponent(fixture.folderName, isDirectory: true)
        for state in ["transcribing", "done", "error"] {
            let statusURL = targetDirectory.appendingPathComponent(AIWatchingSchema.statusFileName)
            let transcriptURL = targetDirectory.appendingPathComponent("transcript.json")
            let minutesURL = targetDirectory.appendingPathComponent("minutes.json")
            let workflowURL = targetDirectory
                .appendingPathComponent("workflow", isDirectory: true)
                .appendingPathComponent("processing.json")
            let statusData = try JSONEncoder().encode(
                SessionStatus(
                    state: try XCTUnwrap(SessionState(rawValue: state)),
                    updatedAt: "2026-07-18T12:00:00Z"
                )
            )
            let transcriptData = Data("transcript-\(state)".utf8)
            let minutesData = Data("minutes-\(state)".utf8)
            let workflowData = Data("workflow-\(state)".utf8)
            let nestedWorkflowURL = targetDirectory
                .appendingPathComponent("workflow", isDirectory: true)
                .appendingPathComponent("attempts", isDirectory: true)
                .appendingPathComponent("receipt.bin")
            let nestedWorkflowData = Data("nested-workflow-\(state)".utf8)

            try statusData.write(to: statusURL, options: [.atomic])
            try transcriptData.write(to: transcriptURL, options: [.atomic])
            try minutesData.write(to: minutesURL, options: [.atomic])
            try FileManager.default.createDirectory(
                at: workflowURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try workflowData.write(to: workflowURL, options: [.atomic])
            try FileManager.default.createDirectory(
                at: nestedWorkflowURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try nestedWorkflowData.write(to: nestedWorkflowURL, options: [.atomic])
            let targetSnapshot = try recursiveTreeSnapshot(at: targetDirectory)

            let restartedExporter = makeExporter(destinationRoot: destinationRoot)
            let restartedAccepted = try await restartedExporter.enqueue(sessionDirectory: fixture.sessionDirectory)
            let restartedOutcomes = await restartedExporter.flush()
            XCTAssertTrue(restartedAccepted)

            XCTAssertEqual(
                restartedOutcomes,
                [.alreadyExported(sessionId: fixture.sessionId)],
                "matching Mac (state) target must not be republished"
            )
            XCTAssertEqual(try recursiveTreeSnapshot(at: targetDirectory), targetSnapshot)
        }
    }

    func testRestartExportFailsClosedWhenMatchingTargetStatusCannotBeRead() async throws {
        let fixture = try makeCompleteSession("unreadable-target-status")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destinationRoot = fixture.root.appendingPathComponent("destination", isDirectory: true)
        let initialExporter = makeExporter(destinationRoot: destinationRoot)

        let initialAccepted = try await initialExporter.enqueue(sessionDirectory: fixture.sessionDirectory)
        let initialOutcomes = await initialExporter.flush()
        XCTAssertTrue(initialAccepted)
        XCTAssertEqual(initialOutcomes, [.exported(sessionId: fixture.sessionId)])

        let targetDirectory = destinationRoot.appendingPathComponent(fixture.folderName, isDirectory: true)
        let statusURL = targetDirectory.appendingPathComponent(AIWatchingSchema.statusFileName)
        let markerURL = targetDirectory.appendingPathComponent("mac-marker.txt")
        try FileManager.default.removeItem(at: statusURL)
        try FileManager.default.createDirectory(at: statusURL, withIntermediateDirectories: false)
        try Data("do-not-delete".utf8).write(to: markerURL, options: [.atomic])
        let targetSnapshot = try recursiveTreeSnapshot(at: targetDirectory)

        let restartedExporter = makeExporter(destinationRoot: destinationRoot)
        let restartedAccepted = try await restartedExporter.enqueue(sessionDirectory: fixture.sessionDirectory)
        let restartedOutcomes = await restartedExporter.flush()
        let pending = await restartedExporter.pendingSessionIDs()

        XCTAssertTrue(restartedAccepted)
        XCTAssertEqual(restartedOutcomes, [.failed(sessionId: fixture.sessionId, failure: .identityConflict)])
        XCTAssertEqual(pending, [fixture.sessionId])
        XCTAssertEqual(try recursiveTreeSnapshot(at: targetDirectory), targetSnapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testRestartExportReplacesMatchingRecordingTargetSafely() async throws {
        let fixture = try makeCompleteSession("recording-target-retry")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destinationRoot = fixture.root.appendingPathComponent("destination", isDirectory: true)
        let initialExporter = makeExporter(destinationRoot: destinationRoot)

        let initialAccepted = try await initialExporter.enqueue(sessionDirectory: fixture.sessionDirectory)
        let initialOutcomes = await initialExporter.flush()
        XCTAssertTrue(initialAccepted)
        XCTAssertEqual(initialOutcomes, [.exported(sessionId: fixture.sessionId)])

        let targetDirectory = destinationRoot.appendingPathComponent(fixture.folderName, isDirectory: true)
        let statusURL = targetDirectory.appendingPathComponent(AIWatchingSchema.statusFileName)
        let markerURL = targetDirectory.appendingPathComponent("incomplete-marker.txt")
        try JSONEncoder().encode(SessionStatus(state: .recording)).write(to: statusURL, options: [.atomic])
        try Data("replace-me".utf8).write(to: markerURL, options: [.atomic])

        let restartedExporter = makeExporter(destinationRoot: destinationRoot)
        let restartedAccepted = try await restartedExporter.enqueue(sessionDirectory: fixture.sessionDirectory)
        let restartedOutcomes = await restartedExporter.flush()
        let pending = await restartedExporter.pendingSessionIDs()

        XCTAssertTrue(restartedAccepted)
        XCTAssertEqual(restartedOutcomes, [.exported(sessionId: fixture.sessionId)])
        XCTAssertTrue(pending.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertTrue(isCompleteStatus(at: statusURL))
    }

    func testIdentityConflictDoesNotOverwriteExistingTarget() async throws {
        let fixture = try makeCompleteSession("identity-conflict")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destinationRoot = fixture.root.appendingPathComponent("destination", isDirectory: true)
        let conflict = try makeCompleteSession(
            "identity-conflict-target",
            root: destinationRoot,
            folderName: fixture.folderName,
            sessionId: UUID().uuidString,
            source: .watch
        )
        let marker = conflict.sessionDirectory.appendingPathComponent("do-not-overwrite.txt")
        try Data("existing".utf8).write(to: marker)
        let existingManifest = try decodeManifest(at: conflict.sessionDirectory)
        let exporter = makeExporter(destinationRoot: destinationRoot)

        let accepted = try await exporter.enqueue(sessionDirectory: fixture.sessionDirectory)
        let outcomes = await exporter.flush()
        let pending = await exporter.pendingSessionIDs()

        XCTAssertTrue(accepted)
        XCTAssertEqual(outcomes, [.failed(sessionId: fixture.sessionId, failure: .identityConflict)])
        XCTAssertEqual(pending, [fixture.sessionId])
        XCTAssertEqual(try Data(contentsOf: marker), Data("existing".utf8))
        XCTAssertEqual(try decodeManifest(at: conflict.sessionDirectory), existingManifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
    }

    func testEnqueueRejectsUnsupportedCaptureManifestVersionSourcePairs() async throws {
        let unsupportedPairs: [(label: String, schemaVersion: Int, source: CaptureSource)] = [
            ("v1-external", AIWatchingSchema.version, .external),
            ("v2-iphone", AIWatchingSchema.externalManifestVersion, .iphone),
            ("v2-watch", AIWatchingSchema.externalManifestVersion, .watch),
            ("v2-external", AIWatchingSchema.externalManifestVersion, .external)
        ]

        for pair in unsupportedPairs {
            let fixture = try makeCompleteSession(
                "unsupported-\(pair.label)",
                schemaVersion: pair.schemaVersion,
                source: pair.source
            )
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let destinationRoot = fixture.root.appendingPathComponent("destination", isDirectory: true)
            let exporter = makeExporter(destinationRoot: destinationRoot)

            do {
                _ = try await exporter.enqueue(sessionDirectory: fixture.sessionDirectory)
                XCTFail("Expected sourceManifestUnreadable for \(pair.label)")
            } catch let error as SessionExport.SessionExportError {
                switch error {
                case .sourceManifestUnreadable:
                    break
                default:
                    XCTFail("Unexpected SessionExportError for \(pair.label): \(error)")
                }
            } catch {
                XCTFail("Unexpected error for \(pair.label): \(error)")
            }

            let pending = await exporter.pendingSessionIDs()
            let target = destinationRoot.appendingPathComponent(fixture.folderName, isDirectory: true)
            XCTAssertTrue(pending.isEmpty, pair.label)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sessionDirectory.path), pair.label)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), pair.label)
        }
    }

    func testDestinationIdentityReaderRejectsV2IPhoneManifest() async throws {
        let fixture = try makeCompleteSession("destination-v2-identity-source")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destinationRoot = fixture.root.appendingPathComponent("destination", isDirectory: true)
        let target = try makeCompleteSession(
            "destination-v2-identity-target",
            root: destinationRoot,
            folderName: fixture.folderName,
            sessionId: fixture.sessionId,
            schemaVersion: AIWatchingSchema.externalManifestVersion,
            source: .iphone
        )
        let targetSnapshot = try recursiveTreeSnapshot(at: target.sessionDirectory)
        let exporter = makeExporter(destinationRoot: destinationRoot)

        let accepted = try await exporter.enqueue(sessionDirectory: fixture.sessionDirectory)
        let outcomes = await exporter.flush()
        let pending = await exporter.pendingSessionIDs()

        XCTAssertTrue(accepted)
        XCTAssertEqual(outcomes, [.failed(sessionId: fixture.sessionId, failure: .identityConflict)])
        XCTAssertEqual(pending, [fixture.sessionId])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sessionDirectory.path))
        XCTAssertEqual(try recursiveTreeSnapshot(at: target.sessionDirectory), targetSnapshot)
    }

    func testIPhoneCaptureCompletionEnqueuesExactlyOnce() async throws {
        let root = try makeTemporaryDirectory("iphone-enqueue")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = SessionExportCompletionProbe()
        let controller = CaptureController()
        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                recordingsRoot: { root },
                createRecorder: { url, _ in SessionExportTestRecorder(url: url) },
                useScheduledChunkPrototype: false,
                enqueueCompletedSession: { probe.record($0) }
            )
        )

        let start = await controller.startCapture()
        XCTAssertTrue(start.ok)
        let token = try XCTUnwrap(controller.debugSessionToken)
        let sessionDirectory = try XCTUnwrap(controller.debugSessionDirectory)

        await controller.debugTearDown(markComplete: true, token: token)
        await controller.debugTearDown(markComplete: true, token: token)

        XCTAssertEqual(probe.urls, [sessionDirectory])
        XCTAssertTrue(isCompleteStatus(at: sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName)))
    }

    func testWatchImportCompletionEnqueuesExactlyOnce() throws {
        let root = try makeTemporaryDirectory("watch-enqueue")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let probe = SessionExportCompletionProbe()
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 1.25 },
            enqueueCompletedSession: { probe.record($0) }
        )
        let metadata = WatchRecordingProbeMetadata(
            sessionId: UUID().uuidString,
            startedAt: AIWatchingClock.isoString(Date(timeIntervalSince1970: 1_700_000_000)),
            endedAt: AIWatchingClock.isoString(Date(timeIntervalSince1970: 1_700_000_010)),
            durationSec: 1.25,
            fileName: "audio.m4a"
        )
        let stagingSession = importer.stagingSessionRoot(stagingRoot, sessionId: metadata.sessionId)
        try FileManager.default.createDirectory(at: stagingSession, withIntermediateDirectories: true)
        try Data([0x01, 0x02]).write(to: stagingSession.appendingPathComponent(metadata.fileName))
        try importer.writeMetadata(metadata, to: importer.metadataFileURL(for: stagingSession))

        let importedSession = try importer.importSession(from: stagingSession)

        XCTAssertEqual(probe.urls, [importedSession])
        XCTAssertTrue(isCompleteStatus(at: importedSession.appendingPathComponent(AIWatchingSchema.statusFileName)))
    }

    func testCaptureProductionExportBindingUsesConfiguredSpoolAndCompletionHandler() async throws {
        let root = try makeTemporaryDirectory("iphone-production-spool")
        defer { try? FileManager.default.removeItem(at: root) }
        let configuredRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let probe = SessionExportCompletionProbe()
        let controller = CaptureController()
        controller.configureSessionExport(
            recordingsRootProvider: { configuredRoot },
            enqueueCompletedSession: { probe.record($0) }
        )
        controller.installTestDependencies(
            .init(
                requestPermission: { true },
                configureSession: {},
                deactivateSession: {},
                createRecorder: { url, _ in SessionExportTestRecorder(url: url) },
                useScheduledChunkPrototype: false
            )
        )

        let started = await controller.startCapture()
        XCTAssertTrue(started.ok)
        let token = try XCTUnwrap(controller.debugSessionToken)
        let sessionDirectory = try XCTUnwrap(controller.debugSessionDirectory)

        await controller.debugTearDown(markComplete: true, token: token)
        XCTAssertEqual(sessionDirectory.deletingLastPathComponent(), configuredRoot)
        XCTAssertTrue(isCompleteStatus(at: sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName)))
        XCTAssertEqual(probe.urls, [sessionDirectory])
    }

    func testPhoneConnectivityExportBindingConfiguresWatchImporterSpoolAndCompletionHandler() throws {
        PhoneConnectivityController.shared.debugResetCaptureStateForTests()
        defer { PhoneConnectivityController.shared.debugResetCaptureStateForTests() }

        let root = try makeTemporaryDirectory("phoneconnectivity-production-spool")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let probe = SessionExportCompletionProbe()

        PhoneConnectivityController.shared.configureSessionExport(
            recordingsRootProvider: { recordingsRoot },
            enqueueCompletedSession: { probe.record($0) }
        )
        let importer = PhoneConnectivityController.shared.debugMakeConfiguredWatchCaptureImporter(
            resolveDuration: { _ in 2.0 }
        )
        let stagingSession = try makeLegacyWatchStagingSession(
            using: importer,
            in: stagingRoot
        )
        let importedSession = try importer.importSession(from: stagingSession)

        XCTAssertEqual(probe.urls, [importedSession])
        XCTAssertEqual(importedSession.deletingLastPathComponent(), recordingsRoot)
        XCTAssertTrue(isCompleteStatus(at: importedSession.appendingPathComponent(AIWatchingSchema.statusFileName)))
    }

    private func makeExporter(
        destinationRoot: URL? = nil,
        store: InMemorySessionExportDestinationStore? = nil,
        probe: SessionExportCopyProbe = SessionExportCopyProbe()
    ) -> SessionExport {
        let destinationStore: InMemorySessionExportDestinationStore
        if let store {
            destinationStore = store
        } else {
            let root = destinationRoot ?? FileManager.default.temporaryDirectory
            destinationStore = InMemorySessionExportDestinationStore(
                .available(SessionExportDestination(rootURL: root, displayName: root.lastPathComponent))
            )
        }
        return SessionExport(
            destinationStore: destinationStore,
            copyItem: { source, destination in
                try probe.copyItem(from: source, to: destination)
            }
        )
    }

    private func makeCompleteSession(
        _ label: String,
        root: URL? = nil,
        folderName: String? = nil,
        sessionId: String = UUID().uuidString,
        schemaVersion: Int = AIWatchingSchema.version,
        source: CaptureSource = .iphone
    ) throws -> Fixture {
        let fixtureRoot = try root ?? makeTemporaryDirectory(label)
        let sessionDirectory = fixtureRoot.appendingPathComponent(
            folderName ?? "2026-07-18__\(label)__\(sessionId)",
            isDirectory: true
        )
        let audioDirectory = sessionDirectory.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try Data([0x00, 0x01, 0x02]).write(
            to: audioDirectory.appendingPathComponent(AIWatchingSchema.chunkAudioFileName(chunkIndex: 0))
        )
        let startedAt = AIWatchingClock.isoString(Date(timeIntervalSince1970: 1_700_000_000))
        let manifest = SessionManifest(
            schemaVersion: schemaVersion,
            sessionId: sessionId,
            source: source,
            startedAt: startedAt,
            endedAt: AIWatchingClock.isoString(Date(timeIntervalSince1970: 1_700_000_010)),
            chunks: [
                AudioChunk(
                    file: "\(AIWatchingSchema.audioFolderName)/\(AIWatchingSchema.chunkAudioFileName(chunkIndex: 0))",
                    index: 0,
                    startOffsetSec: 0,
                    durationSec: 10,
                    startedAt: startedAt
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName),
            options: [.atomic]
        )
        try encoder.encode(SessionStatus(state: .complete)).write(
            to: sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName),
            options: [.atomic]
        )
        return Fixture(root: fixtureRoot, sessionDirectory: sessionDirectory, sessionId: sessionId)
    }

    private func makeLegacyWatchStagingSession(
        using importer: WatchCaptureImporter,
        in stagingRoot: URL,
        sessionId: String = UUID().uuidString
    ) throws -> URL {
        let metadata = WatchRecordingProbeMetadata(
            sessionId: sessionId,
            startedAt: AIWatchingClock.isoString(Date(timeIntervalSinceNow: -20)),
            endedAt: AIWatchingClock.isoString(),
            durationSec: 2.0,
            fileName: "audio.m4a"
        )
        let stagingSession = importer.stagingSessionRoot(stagingRoot, sessionId: sessionId)
        try FileManager.default.createDirectory(at: stagingSession, withIntermediateDirectories: true)
        let audioFile = stagingSession.appendingPathComponent(metadata.fileName)
        try Data([0x00, 0x01]).write(to: audioFile)
        try importer.writeMetadata(metadata, to: importer.metadataFileURL(for: stagingSession))
        return stagingSession
    }

    private func makeTemporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIWatching-STAGE-008A-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func decodeManifest(at sessionDirectory: URL) throws -> SessionManifest {
        try JSONDecoder().decode(
            SessionManifest.self,
            from: Data(contentsOf: sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName))
        )
    }

    private func isCompleteStatus(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let status = try? JSONDecoder().decode(SessionStatus.self, from: data)
        else {
            return false
        }
        return status.state == .complete
    }

    private func recursiveTreeSnapshot(at root: URL) throws -> [String: Data] {
        let fileManager = FileManager.default
        let relativePaths = try fileManager.subpathsOfDirectory(atPath: root.path).sorted()
        var snapshot: [String: Data] = [:]

        for relativePath in relativePaths {
            let url = root.appendingPathComponent(relativePath)
            var isDirectory = ObjCBool(false)
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                XCTFail("Snapshot path disappeared: \(relativePath)")
                continue
            }
            if isDirectory.boolValue {
                snapshot["directory:\(relativePath)"] = Data()
            } else {
                snapshot["file:\(relativePath)"] = try Data(contentsOf: url)
            }
        }

        return snapshot
    }
}
