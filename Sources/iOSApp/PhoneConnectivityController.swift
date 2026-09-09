import Foundation
import AVFoundation
import WatchConnectivity

@MainActor
final class PhoneConnectivityController: NSObject, WCSessionDelegate {
    static let shared = PhoneConnectivityController()

    private weak var capture: CaptureController?
    private var captureStatePublisherId = UUID()
    private var captureStateSequence = 0
    private var latestCaptureContext: [String: Any]?
    private var lastPublishError: Error?

    private struct WatchProbeTransferDependencies: Sendable {
        let documentsDirectory: URL
        let recordingsRootProvider: @Sendable () throws -> URL
        let enqueueCompletedSession: @Sendable (URL) -> Void
        let sendWatchChunkApplicationAck: @Sendable (WatchChunkApplicationAck) -> Void
        let persistWatchProbeMetadata: @Sendable (WatchRecordingProbeMetadata, URL) throws -> Void
    }

    private final class WatchProbeTransferDependencyStore: @unchecked Sendable {
        private let lock = NSLock()
        private var dependencies: WatchProbeTransferDependencies

        init(_ dependencies: WatchProbeTransferDependencies) {
            self.dependencies = dependencies
        }

        func set(_ dependencies: WatchProbeTransferDependencies) {
            lock.lock()
            defer { lock.unlock() }
            self.dependencies = dependencies
        }

        func snapshot() -> WatchProbeTransferDependencies {
            lock.lock()
            defer { lock.unlock() }
            return dependencies
        }
    }

    private nonisolated let watchProbeTransferDependencyStore = WatchProbeTransferDependencyStore(
        WatchProbeTransferDependencies(
            documentsDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
            recordingsRootProvider: { try CaptureStore().recordingsRoot() },
            enqueueCompletedSession: { _ in },
            sendWatchChunkApplicationAck: { ack in
                WCSession.default.transferUserInfo(ack.dictionary)
            },
            persistWatchProbeMetadata: { metadata, destination in
                try WatchCaptureImporter().writeMetadata(metadata, to: destination)
            }
        )
    )
    private nonisolated let watchProbeTransferOperationLock = NSLock()

    private var watchProbeTransferLastError: Error?

    private var isSessionSupported: () -> Bool = { WCSession.isSupported() }
    private var currentActivationState: () -> WCSessionActivationState = { WCSession.default.activationState }
    private var currentReachability: () -> Bool = { WCSession.default.isReachable }
    private var currentPairedState: () -> Bool = { WCSession.default.isPaired }
    private var activateSession: () -> Void = { WCSession.default.activate() }
    private var updateApplicationContextProvider: ([String: Any]) throws -> Void = { context in
        try WCSession.default.updateApplicationContext(context)
    }

    private override init() {
        super.init()
        guard isSessionSupported() else { return }
        WCSession.default.delegate = self
        activateSession()
    }

    @MainActor
    func attach(_ capture: CaptureController) {
        self.capture = capture
        importPendingWatchProbeTransfers()
    }

    var isWatchReachable: Bool {
        isSessionSupported()
            && currentActivationState() == .activated
            && currentReachability()
    }

    var isWatchPaired: Bool {
        isSessionSupported() && currentPairedState()
    }

    func publishCaptureState(isCapturing: Bool, statusText: String, sessionId: String?) {
        guard isSessionSupported() else {
            return
        }
        captureStateSequence += 1
        latestCaptureContext = [
            "capturePublisherId": captureStatePublisherId.uuidString,
            "captureStateSequence": captureStateSequence,
            "captureTimestamp": Date().timeIntervalSince1970,
            "captureIsCapturing": isCapturing,
            "captureStatusText": statusText,
        ]
        if let sessionId {
            latestCaptureContext?["captureSessionId"] = sessionId
        }
        flushLatestCaptureState()
    }

    @MainActor
    private func flushLatestCaptureStateIfActivated() {
        guard isSessionSupported(),
              currentActivationState() == .activated else {
            return
        }
        flushLatestCaptureState()
    }

    private func flushLatestCaptureState() {
        guard isSessionSupported(),
              currentActivationState() == .activated,
              let context = latestCaptureContext else {
            return
        }
        do {
            try updateApplicationContextProvider(context)
            lastPublishError = nil
        } catch {
            lastPublishError = error
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else {
            return
        }
        Task { [weak self] in
            await self?.flushLatestCaptureStateIfActivated()
            await self?.importPendingWatchProbeTransfers()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {
    }

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.activateSession()
        }
    }

    #if DEBUG
    func debugRestartCaptureStatePublisher() {
        captureStatePublisherId = UUID()
        captureStateSequence = 0
    }
    #endif

    #if DEBUG
    var debugCaptureStatePublisherId: UUID { captureStatePublisherId }
    var debugLatestCaptureContext: [String: Any]? { latestCaptureContext }
    var debugLastPublishError: Error? { lastPublishError }
    var debugWatchProbeTransferLastError: Error? { watchProbeTransferLastError }
    func debugResetCaptureStateForTests() {
        isSessionSupported = { WCSession.isSupported() }
        currentActivationState = { WCSession.default.activationState }
        currentReachability = { WCSession.default.isReachable }
        currentPairedState = { WCSession.default.isPaired }
        activateSession = { WCSession.default.activate() }
        updateApplicationContextProvider = { context in
            try WCSession.default.updateApplicationContext(context)
        }
        let defaultProbeDependencies = WatchProbeTransferDependencies(
            documentsDirectory: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
            recordingsRootProvider: { try CaptureStore().recordingsRoot() },
            enqueueCompletedSession: { _ in },
            sendWatchChunkApplicationAck: { ack in
                WCSession.default.transferUserInfo(ack.dictionary)
            },
            persistWatchProbeMetadata: { metadata, destination in
                try WatchCaptureImporter().writeMetadata(metadata, to: destination)
            }
        )
        watchProbeTransferDependencyStore.set(defaultProbeDependencies)
        watchProbeTransferLastError = nil
        captureStatePublisherId = UUID()
        captureStateSequence = 0
        latestCaptureContext = nil
        lastPublishError = nil
    }

    struct TestDependencies {
        var isSupported: (() -> Bool)?
        var activationState: (() -> WCSessionActivationState)?
        var isReachable: (() -> Bool)?
        var isPaired: (() -> Bool)?
        var activateSession: (() -> Void)?
        var updateApplicationContext: (([String: Any]) throws -> Void)?
        var watchProbeTransferDocumentsDirectory: URL?
        var sendWatchChunkApplicationAck: (@Sendable (WatchChunkApplicationAck) -> Void)?
        var persistWatchProbeMetadata: (@Sendable (WatchRecordingProbeMetadata, URL) throws -> Void)?
    }

    func installTestDependencies(_ dependencies: TestDependencies) {
        if let dependency = dependencies.isSupported {
            isSessionSupported = dependency
        }
        if let dependency = dependencies.activationState {
            currentActivationState = dependency
        }
        if let dependency = dependencies.isReachable {
            currentReachability = dependency
        }
        if let dependency = dependencies.isPaired {
            currentPairedState = dependency
        }
        if let dependency = dependencies.activateSession {
            activateSession = dependency
        }
        if let dependency = dependencies.updateApplicationContext {
            updateApplicationContextProvider = dependency
        }
        let currentDependencies = watchProbeTransferDependencyStore.snapshot()
        watchProbeTransferDependencyStore.set(
            WatchProbeTransferDependencies(
                documentsDirectory: dependencies.watchProbeTransferDocumentsDirectory
                    ?? currentDependencies.documentsDirectory,
                recordingsRootProvider: currentDependencies.recordingsRootProvider,
                enqueueCompletedSession: currentDependencies.enqueueCompletedSession,
                sendWatchChunkApplicationAck: dependencies.sendWatchChunkApplicationAck
                    ?? currentDependencies.sendWatchChunkApplicationAck,
                persistWatchProbeMetadata: dependencies.persistWatchProbeMetadata
                    ?? currentDependencies.persistWatchProbeMetadata
            )
        )
        watchProbeTransferLastError = nil
    }
    #endif

    func configureSessionExport(
        recordingsRootProvider: @escaping @Sendable () throws -> URL,
        enqueueCompletedSession: @escaping @Sendable (URL) -> Void
    ) {
        let currentDependencies = watchProbeTransferDependencyStore.snapshot()
        watchProbeTransferDependencyStore.set(
            WatchProbeTransferDependencies(
                documentsDirectory: currentDependencies.documentsDirectory,
                recordingsRootProvider: recordingsRootProvider,
                enqueueCompletedSession: enqueueCompletedSession,
                sendWatchChunkApplicationAck: currentDependencies.sendWatchChunkApplicationAck,
                persistWatchProbeMetadata: currentDependencies.persistWatchProbeMetadata
            )
        )
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let command = message["command"] as? String else {
            replyHandler(["ok": false, "message": "missing command"])
            return
        }

        switch command {
        case "start":
            // Reply only after the phone has actually started recording, so the
            // watch never shows "正在捕捉" for a start that failed (permission,
            // iCloud write, or controller-not-attached).
            let box = ReplyHandlerBox(reply: replyHandler)
            Task { @MainActor in
                let result = await self.capture?.startCapture()
                box.reply([
                    "ok": result?.ok ?? false,
                    "message": result?.message ?? "capture 未就绪，未开始",
                ])
            }
        case "stop":
            replyHandler(["ok": true, "message": "stopping"])
            Task { @MainActor in await self.capture?.stopCapture() }
        case "bookmark":
            replyHandler(["ok": true, "message": "bookmarked"])
            Task { @MainActor in await self.capture?.addBookmark(note: nil, source: "watch") }
        default:
            replyHandler(["ok": false, "message": "unknown command"])
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let importer = createWatchCaptureImporter()
        do {
            let dependencies = watchProbeTransferDependencyStore.snapshot()
            let stagedSession = try withWatchProbeTransferLock {
                try receiveWatchProbe(
                    importer: importer,
                    fileURL: file.fileURL,
                    metadata: file.metadata,
                    dependencies: dependencies
                )
            }
            guard let stagedSession else {
                return
            }
            sendWatchChunkApplicationAckIfEligible(
                for: file.metadata,
                dependencies: dependencies
            )
            Task { @MainActor [weak self] in
                self?.importStagedWatchCapture(stagedSession)
            }
        } catch {
            DispatchQueue.main.async { [weak self] in
                self?.watchProbeTransferLastError = error
            }
        }
    }

    func processWatchProbeTransfer(fileURL: URL, metadata: [String: Any]?) -> URL? {
        do {
            let importer = createWatchCaptureImporter()
            let dependencies = watchProbeTransferDependenciesSnapshot()
            let stagedSession = try withWatchProbeTransferLock {
                try receiveWatchProbe(
                    importer: importer,
                    fileURL: fileURL,
                    metadata: metadata,
                    dependencies: dependencies
                )
            }
            if stagedSession != nil {
                sendWatchChunkApplicationAckIfEligible(
                    for: metadata,
                    dependencies: dependencies
                )
            }
            return stagedSession
        } catch {
            watchProbeTransferLastError = error
            return nil
        }
    }

    private func importPendingWatchProbeTransfers() {
        let dependencies = watchProbeTransferDependencyStore.snapshot()
        let root = watchCaptureInboxRoot(dependencies.documentsDirectory)
        let failures = withWatchProbeTransferLock {
            createWatchCaptureImporter().importAllPendingWatchCaptureSessions(at: root)
        }
        watchProbeTransferLastError = failures.first.map {
            NSError(
                domain: "com.aiwatching.watch-capture-import",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: $0.errorDescription]
            )
        }
    }

    private func importStagedWatchCapture(_ stagedSession: URL) {
        do {
            try withWatchProbeTransferLock {
                _ = try createWatchCaptureImporter().importSession(from: stagedSession)
            }
            watchProbeTransferLastError = nil
        } catch WatchCaptureImportError.sessionNotReady {
            // Multi-chunk session still awaiting transfers; staging is kept and
            // a later pass (or the final chunk's arrival) completes the import.
        } catch {
            watchProbeTransferLastError = error
        }
    }

    private nonisolated func watchCaptureInboxRoot(_ documentsDirectory: URL) -> URL {
        documentsDirectory.appendingPathComponent("watch-capture-inbox", isDirectory: true)
    }

    private nonisolated func receiveWatchProbe(
        importer: WatchCaptureImporter,
        fileURL: URL,
        metadata: [String: Any]?,
        dependencies: WatchProbeTransferDependencies
    ) throws -> URL? {
        let fileManager = FileManager.default
        guard metadata?[WatchRecordingProbeMetadata.transferFlagKey] as? Bool == true else {
            return nil
        }

        guard let receivedProbeMetadata = WatchRecordingProbeMetadata(dictionary: metadata) else {
            try quarantineWatchProbe(
                fileURL: fileURL,
                rawMetadata: metadata,
                parsedMetadata: nil,
                importer: importer,
                documentsDirectory: dependencies.documentsDirectory
            )
            throw WatchCaptureImportError.invalidTransferMetadata
        }
        // A retry has a new transferAttemptId even when it carries the same
        // audio unit. Keep that identifier available to the sender callback,
        // but exclude it from receiver-side persistence and idempotency.
        let probeMetadata = receivedProbeMetadata.withoutTransferAttemptId()

        guard probeMetadata.isValidUUIDSession() else {
            throw WatchCaptureImportError.invalidSessionId
        }

        let inboxRoot = watchCaptureInboxRoot(dependencies.documentsDirectory)
        try fileManager.createDirectory(at: inboxRoot, withIntermediateDirectories: true)

        let sessionDirectory = importer.stagingSessionRoot(inboxRoot, sessionId: probeMetadata.sessionId)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        // v1 keeps the legacy single-file layout; v2 stages one file per chunk.
        // The two layouts must never mix inside one session directory.
        let isChunked = probeMetadata.metadataVersion == WatchRecordingProbeMetadata.chunkedVersion
        guard stagingLayoutIsCompatible(sessionDirectory, expectChunked: isChunked) else {
            try quarantineWatchProbe(
                fileURL: fileURL,
                rawMetadata: metadata,
                parsedMetadata: probeMetadata,
                importer: importer,
                documentsDirectory: dependencies.documentsDirectory
            )
            throw WatchCaptureImportError.stagingConflict
        }

        let stagedAudio: URL
        let metadataDestination: URL
        if isChunked {
            stagedAudio = importer.chunkAudioFileURL(for: sessionDirectory, chunkIndex: probeMetadata.chunkIndex)
            metadataDestination = importer.chunkMetadataFileURL(for: sessionDirectory, chunkIndex: probeMetadata.chunkIndex)
        } else {
            stagedAudio = sessionDirectory.appendingPathComponent("audio.m4a")
            metadataDestination = importer.metadataFileURL(for: sessionDirectory)
        }

        if fileManager.fileExists(atPath: metadataDestination.path) {
            guard let existingMetadata = try? importer.loadMetadata(at: metadataDestination),
                  existingMetadata == probeMetadata else {
                try quarantineWatchProbe(
                    fileURL: fileURL,
                    rawMetadata: metadata,
                    parsedMetadata: probeMetadata,
                    importer: importer,
                    documentsDirectory: dependencies.documentsDirectory
                )
                throw WatchCaptureImportError.stagingConflict
            }
        }

        if fileManager.fileExists(atPath: stagedAudio.path) {
            let attributes = try fileManager.attributesOfItem(atPath: stagedAudio.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
                try quarantineWatchProbe(
                    fileURL: fileURL,
                    rawMetadata: metadata,
                    parsedMetadata: probeMetadata,
                    importer: importer,
                    documentsDirectory: dependencies.documentsDirectory
                )
                throw WatchCaptureImportError.stagingConflict
            }
            if !fileManager.fileExists(atPath: metadataDestination.path) {
                try dependencies.persistWatchProbeMetadata(probeMetadata, metadataDestination)
            }
            return sessionDirectory
        }

        if !fileManager.fileExists(atPath: metadataDestination.path) {
            try dependencies.persistWatchProbeMetadata(probeMetadata, metadataDestination)
        }
        do {
            try fileManager.moveItem(at: fileURL, to: stagedAudio)
        } catch {
            try? quarantineWatchProbe(
                fileURL: fileURL,
                rawMetadata: metadata,
                parsedMetadata: probeMetadata,
                importer: importer,
                documentsDirectory: dependencies.documentsDirectory
            )
            throw error
        }
        return sessionDirectory
    }

    private nonisolated func stagingLayoutIsCompatible(_ sessionDirectory: URL, expectChunked: Bool) -> Bool {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(at: sessionDirectory, includingPropertiesForKeys: nil)) ?? []
        let hasLegacyMetadata = entries.contains { $0.lastPathComponent == "metadata.json" }
        let hasChunkSidecars = entries.contains {
            $0.lastPathComponent.hasPrefix("chunk_") && $0.pathExtension.lowercased() == "json"
        }
        if expectChunked {
            return !hasLegacyMetadata
        }
        return !hasChunkSidecars
    }

    private nonisolated func quarantineWatchProbe(
        fileURL: URL,
        rawMetadata: [String: Any]?,
        parsedMetadata: WatchRecordingProbeMetadata?,
        importer: WatchCaptureImporter,
        documentsDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        let quarantine = documentsDirectory
            .appendingPathComponent("watch-capture-quarantine", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: quarantine, withIntermediateDirectories: true)
        do {
            try fileManager.moveItem(at: fileURL, to: quarantine.appendingPathComponent("audio.m4a"))
        } catch {
            try? fileManager.removeItem(at: quarantine)
            throw error
        }

        if let parsedMetadata {
            try? importer.writeMetadata(parsedMetadata, to: importer.metadataFileURL(for: quarantine))
        } else if let rawMetadata,
                  PropertyListSerialization.propertyList(rawMetadata, isValidFor: .binary) {
            let data = try? PropertyListSerialization.data(
                fromPropertyList: rawMetadata,
                format: .binary,
                options: 0
            )
            try? data?.write(to: quarantine.appendingPathComponent("raw-metadata.plist"), options: [.atomic])
        }
    }

    private nonisolated func withWatchProbeTransferLock<T>(_ operation: () throws -> T) rethrows -> T {
        watchProbeTransferOperationLock.lock()
        defer { watchProbeTransferOperationLock.unlock() }
        return try operation()
    }

    private nonisolated func createWatchCaptureImporter() -> WatchCaptureImporter {
        let dependencies = watchProbeTransferDependencyStore.snapshot()
        return WatchCaptureImporter(
            recordingsRootProvider: dependencies.recordingsRootProvider,
            enqueueCompletedSession: dependencies.enqueueCompletedSession
        )
    }

    private func watchProbeTransferDependenciesSnapshot() -> WatchProbeTransferDependencies {
        watchProbeTransferDependencyStore.snapshot()
    }

    private nonisolated func sendWatchChunkApplicationAckIfEligible(
        for rawMetadata: [String: Any]?,
        dependencies: WatchProbeTransferDependencies
    ) {
        guard let metadata = WatchRecordingProbeMetadata(dictionary: rawMetadata),
              metadata.metadataVersion == WatchRecordingProbeMetadata.chunkedVersion,
              let transferAttemptId = metadata.transferAttemptId else {
            return
        }
        dependencies.sendWatchChunkApplicationAck(
            WatchChunkApplicationAck(
                sessionId: metadata.sessionId,
                chunkIndex: metadata.chunkIndex,
                transferAttemptId: transferAttemptId
            )
        )
    }

    #if DEBUG
    func debugMakeConfiguredWatchCaptureImporter(
        resolveDuration: @escaping @Sendable (URL) throws -> TimeInterval = { fileURL in
            let asset = AVURLAsset(url: fileURL)
            let seconds = CMTimeGetSeconds(asset.duration)
            guard seconds.isFinite else {
                throw WatchCaptureImportError.durationParseFailed
            }
            return max(0, seconds)
        }
    ) -> WatchCaptureImporter {
        let dependencies = watchProbeTransferDependencyStore.snapshot()
        return WatchCaptureImporter(
            recordingsRootProvider: dependencies.recordingsRootProvider,
            resolveDuration: resolveDuration,
            enqueueCompletedSession: dependencies.enqueueCompletedSession
        )
    }
    #endif
}

/// Carries WCSession's `replyHandler` (safe to call from any thread, but not
/// Sendable-typed) into a structured-concurrency Task without relaxing safety
/// elsewhere. Used so the `start` reply can await the real recording result.
private struct ReplyHandlerBox: @unchecked Sendable {
    let reply: ([String: Any]) -> Void
}
