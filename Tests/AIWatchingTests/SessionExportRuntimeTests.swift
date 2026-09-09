import Combine
import Foundation
import XCTest
@testable import AIWatching

private final class FakeSessionExportBookmarkCoder: @unchecked Sendable, SessionExportBookmarkCoding {
    private let lock = NSLock()
    private var resolutions: [Data: SessionExportBookmarkResolution] = [:]
    private var stale = false

    func makeBookmark(for url: URL) throws -> Data {
        let data = Data(url.standardizedFileURL.path.utf8)
        lock.lock()
        resolutions[data] = SessionExportBookmarkResolution(url: url, isStale: false)
        lock.unlock()
        return data
    }

    func resolveBookmark(_ data: Data) throws -> SessionExportBookmarkResolution {
        lock.lock()
        defer { lock.unlock() }
        guard let resolution = resolutions[data] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return SessionExportBookmarkResolution(url: resolution.url, isStale: stale)
    }

    func setStale(_ stale: Bool) {
        lock.lock()
        self.stale = stale
        lock.unlock()
    }
}

private final class RuntimeDestinationStore: @unchecked Sendable, SessionExportDestinationStoring {
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
        state = .available(destination)
        lock.unlock()
    }

    func clear() throws {
        lock.lock()
        state = .missing
        lock.unlock()
    }
}

private final class RuntimeCopyProbe: @unchecked Sendable {
    enum Mode {
        case copy
        case permissionDenied
    }

    private let lock = NSLock()
    private var mode: Mode

    init(mode: Mode) {
        self.mode = mode
    }

    func setMode(_ mode: Mode) {
        lock.lock()
        self.mode = mode
        lock.unlock()
    }

    func copy(from source: URL, to destination: URL) throws {
        lock.lock()
        let currentMode = mode
        lock.unlock()
        if case .permissionDenied = currentMode {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

private final class RuntimeSecurityScopeProbe: @unchecked Sendable, SessionExportSecurityScopeAccessing {
    private let lock = NSLock()
    private let startResult: Bool
    private let eventLog: RuntimeEventRecorder?
    private var recordedEvents: [String] = []

    init(startResult: Bool, eventLog: RuntimeEventRecorder? = nil) {
        self.startResult = startResult
        self.eventLog = eventLog
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recordedEvents
    }

    func startAccessing(_ url: URL) -> Bool {
        record("start")
        return startResult
    }

    func stopAccessing(_ url: URL) {
        record("stop")
    }

    func copy(from source: URL, to destination: URL) throws {
        record("copy")
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func record(_ event: String) {
        eventLog?.record(event)
        lock.lock()
        recordedEvents.append(event)
        lock.unlock()
    }
}

private final class RuntimeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var recordedEvents: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }
}

private final class RuntimeDestinationStoreProbe: @unchecked Sendable, SessionExportDestinationStoring {
    private let lock = NSLock()
    private let destinationStore: SessionExportDestinationStoring
    private let eventRecorder: RuntimeEventRecorder?

    init(
        destinationStore: SessionExportDestinationStoring,
        eventRecorder: RuntimeEventRecorder? = nil
    ) {
        self.destinationStore = destinationStore
        self.eventRecorder = eventRecorder
    }

    func load() throws -> SessionExportDestinationState {
        try destinationStore.load()
    }

    func save(_ destination: SessionExportDestination) throws {
        eventRecorder?.record("save")
        try destinationStore.save(destination)
    }

    func clear() throws {
        try destinationStore.clear()
    }
}

@MainActor
final class SessionExportRuntimeTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let sessionDirectory: URL
        let sessionId: String
    }

    func testFileDestinationStoreMissingRoundTripStaleAndClear() throws {
        let root = try makeTemporaryDirectory("bookmark-store")
        defer { try? FileManager.default.removeItem(at: root) }
        let storageURL = root.appendingPathComponent("destination-bookmark.json")
        let coder = FakeSessionExportBookmarkCoder()
        let store = FileSessionExportDestinationStore(storageURL: storageURL, bookmarkCoder: coder)
        let selectedURL = root.appendingPathComponent("Selected Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedURL, withIntermediateDirectories: true)
        let destination = SessionExportDestination(rootURL: selectedURL, displayName: "我的转写目录")

        XCTAssertEqual(try store.load(), .missing)

        try store.save(destination)
        XCTAssertTrue(FileManager.default.fileExists(atPath: storageURL.path))
        XCTAssertEqual(try store.load(), .available(destination))

        coder.setStale(true)
        XCTAssertEqual(try store.load(), .stale(displayName: destination.displayName))

        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: storageURL.path))
        XCTAssertEqual(try store.load(), .missing)
    }

    func testProductionAdaptersSatisfyDefaultWiringProtocols() {
        let bookmarkCoder: any SessionExportBookmarkCoding = AppleSessionExportBookmarkCoder()
        _ = bookmarkCoder

        let runtime = SessionExportRuntime(
            exporter: SessionExport(destinationStore: RuntimeDestinationStore(.missing)),
            recordingsRootProvider: { FileManager.default.temporaryDirectory }
        )
        let observable: any ObservableObject = runtime
        _ = observable
    }

    func testRuntimeSelectionClearAndRefreshExposeViewState() async throws {
        let root = try makeTemporaryDirectory("runtime-state")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeDestinationStore(.missing)
        let runtime = SessionExportRuntime(
            exporter: SessionExport(destinationStore: store),
            recordingsRootProvider: { root }
        )
        let destination = SessionExportDestination(rootURL: root, displayName: "Local Test Folder")

        await runtime.refresh()
        XCTAssertEqual(runtime.destinationState, .missing)
        XCTAssertTrue(runtime.pendingSessionIDs.isEmpty)
        XCTAssertTrue(runtime.lastOutcomes.isEmpty)
        XCTAssertNil(runtime.lastError)

        await runtime.selectDestination(destination)
        XCTAssertEqual(runtime.destinationState, .available(destination))

        await runtime.clearDestination()
        XCTAssertEqual(runtime.destinationState, .missing)
    }

    func testLiveFactoryPersistsSelectedDestinationAcrossRuntimeRecreation() async throws {
        let root = try makeTemporaryDirectory("runtime-live-factory")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let destinationStorageURL = root.appendingPathComponent("destination-bookmark.json")
        let destination = SessionExportDestination(rootURL: destinationRoot, displayName: "Spool Export")
        let coder = FakeSessionExportBookmarkCoder()

        let runtime1 = SessionExportRuntime.live(
            destinationStorageURL: destinationStorageURL,
            recordingsRootProvider: { recordingsRoot },
            bookmarkCoder: coder,
            fileManager: FileManager.default
        )
        await runtime1.selectDestination(destination)

        let runtime2 = SessionExportRuntime.live(
            destinationStorageURL: destinationStorageURL,
            recordingsRootProvider: { recordingsRoot },
            bookmarkCoder: coder,
            fileManager: FileManager.default
        )
        await runtime2.refresh()

        XCTAssertEqual(runtime2.destinationState, SessionExportDestinationState.available(destination))
        XCTAssertNil(runtime2.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationStorageURL.path))
    }

    func testEnqueueCompletedSessionDefersImmediatelyWhenDestinationMissing() async throws {
        let root = try makeTemporaryDirectory("runtime-enqueue-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
        let complete = try makeSession(in: recordingsRoot, state: .complete, label: "missing")
        let runtime = SessionExportRuntime(
            exporter: SessionExport(destinationStore: RuntimeDestinationStore(.missing)),
            recordingsRootProvider: { recordingsRoot }
        )

        await runtime.enqueueCompletedSession(complete.sessionDirectory)

        XCTAssertEqual(runtime.pendingSessionIDs, [complete.sessionId])
        XCTAssertEqual(
            runtime.lastOutcomes,
            [.deferred(sessionId: complete.sessionId, reason: .destinationMissing)]
        )
        XCTAssertNil(runtime.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: complete.sessionDirectory.path))
    }

    func testEnqueueCompletedSessionExportsImmediatelyWhenDestinationAvailable() async throws {
        let root = try makeTemporaryDirectory("runtime-enqueue-available")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let complete = try makeSession(in: recordingsRoot, state: .complete, label: "available")
        let destination = SessionExportDestination(rootURL: destinationRoot, displayName: "Available")
        let runtime = SessionExportRuntime(
            exporter: SessionExport(destinationStore: RuntimeDestinationStore(.available(destination))),
            recordingsRootProvider: { recordingsRoot }
        )

        await runtime.enqueueCompletedSession(complete.sessionDirectory)

        let destinationStatus = destinationRoot
            .appendingPathComponent(complete.sessionDirectory.lastPathComponent, isDirectory: true)
            .appendingPathComponent(AIWatchingSchema.statusFileName)

        XCTAssertEqual(runtime.pendingSessionIDs, [])
        XCTAssertEqual(runtime.lastOutcomes, [.exported(sessionId: complete.sessionId)])
        XCTAssertTrue(isCompleteStatus(at: destinationStatus))
        XCTAssertTrue(FileManager.default.fileExists(atPath: complete.sessionDirectory.path))
    }

    func testEnqueueValidationFailurePreservesAvailableDestination() async throws {
        let root = try makeTemporaryDirectory("runtime-enqueue-invalid-source")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let incomplete = try makeSession(in: recordingsRoot, state: .recording, label: "invalid-source")
        let destination = SessionExportDestination(rootURL: destinationRoot, displayName: "Still Available")
        let runtime = SessionExportRuntime(
            exporter: SessionExport(destinationStore: RuntimeDestinationStore(.available(destination))),
            recordingsRootProvider: { recordingsRoot }
        )

        await runtime.enqueueCompletedSession(incomplete.sessionDirectory)

        XCTAssertEqual(runtime.destinationState, .available(destination))
        XCTAssertNotNil(runtime.lastError)
        XCTAssertTrue(runtime.pendingSessionIDs.isEmpty)
        XCTAssertTrue(runtime.lastOutcomes.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: incomplete.sessionDirectory.path))
    }

    func testResumeScansOnlyCompleteSessionsAndDoesNotDuplicatePendingJobs() async throws {
        let root = try makeTemporaryDirectory("runtime-scan")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
        let complete = try makeSession(in: recordingsRoot, state: .complete, label: "complete")
        _ = try makeSession(in: recordingsRoot, state: .recording, label: "recording")
        let broken = recordingsRoot.appendingPathComponent("broken-session", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: broken.appendingPathComponent(AIWatchingSchema.statusFileName))
        try Data("ordinary file".utf8).write(to: recordingsRoot.appendingPathComponent("notes.txt"))
        let runtime = SessionExportRuntime(
            exporter: SessionExport(destinationStore: RuntimeDestinationStore(.missing)),
            recordingsRootProvider: { recordingsRoot }
        )

        await runtime.resumeCompleteSessions()
        let firstPending = runtime.pendingSessionIDs
        let firstOutcomes = runtime.lastOutcomes
        await runtime.resumeCompleteSessions()

        XCTAssertEqual(firstPending, [complete.sessionId])
        XCTAssertEqual(runtime.pendingSessionIDs, [complete.sessionId])
        XCTAssertEqual(firstOutcomes, [.deferred(sessionId: complete.sessionId, reason: .destinationMissing)])
        XCTAssertEqual(runtime.lastOutcomes, [.deferred(sessionId: complete.sessionId, reason: .destinationMissing)])
        XCTAssertNil(runtime.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: complete.sessionDirectory.path))
    }

    func testPermissionFailureSurfacesAndManualRetryExportsWithoutDeletingSource() async throws {
        let root = try makeTemporaryDirectory("runtime-retry")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let complete = try makeSession(in: recordingsRoot, state: .complete, label: "retry")
        let destination = SessionExportDestination(rootURL: destinationRoot, displayName: "Destination")
        let probe = RuntimeCopyProbe(mode: .permissionDenied)
        let exporter = SessionExport(
            destinationStore: RuntimeDestinationStore(.available(destination)),
            copyItem: { source, target in try probe.copy(from: source, to: target) }
        )
        let runtime = SessionExportRuntime(
            exporter: exporter,
            recordingsRootProvider: { recordingsRoot }
        )

        await runtime.resumeCompleteSessions()

        XCTAssertEqual(runtime.pendingSessionIDs, [complete.sessionId])
        XCTAssertEqual(runtime.lastOutcomes, [.failed(sessionId: complete.sessionId, failure: .permissionDenied)])
        XCTAssertNil(runtime.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: complete.sessionDirectory.path))

        probe.setMode(.copy)
        await runtime.retryPending()
        let targetStatus = destinationRoot
            .appendingPathComponent(complete.sessionDirectory.lastPathComponent, isDirectory: true)
            .appendingPathComponent(AIWatchingSchema.statusFileName)

        XCTAssertTrue(runtime.pendingSessionIDs.isEmpty)
        XCTAssertEqual(runtime.lastOutcomes, [.exported(sessionId: complete.sessionId)])
        XCTAssertTrue(isCompleteStatus(at: targetStatus))
        XCTAssertTrue(FileManager.default.fileExists(atPath: complete.sessionDirectory.path))
    }

    func testExporterWrapsDestinationIOInSecurityScope() async throws {
        let root = try makeTemporaryDirectory("security-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let complete = try makeSession(in: recordingsRoot, state: .complete, label: "scoped")
        let destination = SessionExportDestination(rootURL: destinationRoot, displayName: "Scoped")
        let probe = RuntimeSecurityScopeProbe(startResult: true)
        let exporter = SessionExport(
            destinationStore: RuntimeDestinationStore(.available(destination)),
            copyItem: { source, target in try probe.copy(from: source, to: target) },
            securityScopeAccessor: probe
        )

        _ = try await exporter.enqueue(sessionDirectory: complete.sessionDirectory)
        let outcomes = await exporter.flush()

        XCTAssertEqual(outcomes, [.exported(sessionId: complete.sessionId)])
        XCTAssertEqual(probe.events.first, "start")
        XCTAssertEqual(probe.events.last, "stop")
        XCTAssertEqual(probe.events.filter { $0 == "start" }.count, 1)
        XCTAssertEqual(probe.events.filter { $0 == "stop" }.count, 1)
        XCTAssertTrue(probe.events.contains("copy"))
    }

    func testUnscopedLocalDestinationStillCopiesWhenStartReturnsFalse() async throws {
        let root = try makeTemporaryDirectory("unscoped-local")
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: recordingsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let complete = try makeSession(in: recordingsRoot, state: .complete, label: "local")
        let destination = SessionExportDestination(rootURL: destinationRoot, displayName: "Local")
        let probe = RuntimeSecurityScopeProbe(startResult: false)
        let exporter = SessionExport(
            destinationStore: RuntimeDestinationStore(.available(destination)),
            copyItem: { source, target in try probe.copy(from: source, to: target) },
            securityScopeAccessor: probe
        )

        _ = try await exporter.enqueue(sessionDirectory: complete.sessionDirectory)
        let outcomes = await exporter.flush()

        XCTAssertEqual(outcomes, [.exported(sessionId: complete.sessionId)])
        XCTAssertEqual(probe.events.first, "start")
        XCTAssertFalse(probe.events.contains("stop"))
        XCTAssertTrue(probe.events.contains("copy"))
    }

    func testFocused_selectionDestinationSaveOccursWithinSecurityScope() async throws {
        let root = try makeTemporaryDirectory("selection-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationRoot = root.appendingPathComponent("destination", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let destination = SessionExportDestination(rootURL: destinationRoot, displayName: "Scoped Save")
        let eventRecorder = RuntimeEventRecorder()
        let probe = RuntimeSecurityScopeProbe(startResult: true, eventLog: eventRecorder)
        let store = RuntimeDestinationStoreProbe(
            destinationStore: RuntimeDestinationStore(.missing),
            eventRecorder: eventRecorder
        )
        let exporter = SessionExport(
            destinationStore: store,
            securityScopeAccessor: probe
        )

        try await exporter.selectDestination(destination)

        XCTAssertEqual(eventRecorder.recordedEvents, ["start", "save", "stop"])
    }

    func testRecordingRootFailureIsPublishedForSwiftUI() async {
        let store = RuntimeDestinationStore(.missing)
        let runtime = SessionExportRuntime(
            exporter: SessionExport(destinationStore: store),
            recordingsRootProvider: {
                throw CocoaError(.fileReadNoSuchFile)
            }
        )

        await runtime.resumeCompleteSessions()

        XCTAssertNotNil(runtime.lastError)
        XCTAssertTrue(runtime.pendingSessionIDs.isEmpty)
    }

    private func makeSession(
        in recordingsRoot: URL,
        state: SessionState,
        label: String
    ) throws -> Fixture {
        let sessionId = UUID().uuidString
        let sessionDirectory = recordingsRoot.appendingPathComponent("\(label)-\(sessionId)", isDirectory: true)
        let audioDirectory = sessionDirectory.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try Data([0x01]).write(
            to: audioDirectory.appendingPathComponent(AIWatchingSchema.chunkAudioFileName(chunkIndex: 0))
        )
        let startedAt = AIWatchingClock.isoString(Date(timeIntervalSince1970: 1_700_000_000))
        let manifest = SessionManifest(
            sessionId: sessionId,
            source: .iphone,
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
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(
            to: sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName),
            options: [.atomic]
        )
        try encoder.encode(SessionStatus(state: state)).write(
            to: sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName),
            options: [.atomic]
        )
        return Fixture(root: recordingsRoot, sessionDirectory: sessionDirectory, sessionId: sessionId)
    }

    private func makeTemporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIWatching-STAGE-008A-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isCompleteStatus(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let status = try? JSONDecoder().decode(SessionStatus.self, from: data)
        else {
            return false
        }
        return status.state == .complete
    }
}
