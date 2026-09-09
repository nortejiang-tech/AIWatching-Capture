import Combine
import Foundation

struct SessionExportBookmarkResolution: Equatable, Sendable {
    let url: URL
    let isStale: Bool
}

protocol SessionExportBookmarkCoding: Sendable {
    func makeBookmark(for url: URL) throws -> Data
    func resolveBookmark(_ data: Data) throws -> SessionExportBookmarkResolution
}

struct FileSessionExportDestinationStorage: Codable {
    let bookmark: Data
    let displayName: String
}

enum FileSessionExportDestinationStoreError: Error {
    case unresolvedBookmark
}

final class AppleSessionExportBookmarkCoder: @unchecked Sendable, SessionExportBookmarkCoding {
    func makeBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        try url.bookmarkData(options: .withSecurityScope)
        #else
        try url.bookmarkData()
        #endif
    }

    func resolveBookmark(_ data: Data) throws -> SessionExportBookmarkResolution {
        var stale = false
        let resolved = try URL(
            resolvingBookmarkData: data,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return SessionExportBookmarkResolution(url: resolved, isStale: stale)
    }
}

final class FileSessionExportDestinationStore: SessionExportDestinationStoring, @unchecked Sendable {
    private enum Constants {
        static let storagePermissions: FileProtectionType = .completeUntilFirstUserAuthentication
    }

    private let storageURL: URL
    private let bookmarkCoder: SessionExportBookmarkCoding
    private let fileManager: FileManager
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    init(
        storageURL: URL,
        bookmarkCoder: SessionExportBookmarkCoding,
        fileManager: FileManager = .default,
        jsonEncoder: JSONEncoder = JSONEncoder(),
        jsonDecoder: JSONDecoder = JSONDecoder()
    ) {
        self.storageURL = storageURL
        self.bookmarkCoder = bookmarkCoder
        self.fileManager = fileManager
        self.jsonEncoder = jsonEncoder
        self.jsonDecoder = jsonDecoder
    }

    func load() throws -> SessionExportDestinationState {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return .missing
        }

        let data = try Data(contentsOf: storageURL)
        let storage = try jsonDecoder.decode(FileSessionExportDestinationStorage.self, from: data)
        let resolution = try bookmarkCoder.resolveBookmark(storage.bookmark)
        let destination = SessionExportDestination(
            rootURL: resolution.url,
            displayName: storage.displayName
        )

        if resolution.isStale {
            return .stale(displayName: storage.displayName)
        }

        return .available(destination)
    }

    func save(_ destination: SessionExportDestination) throws {
        let directory = storageURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: Constants.storagePermissions]
            )
        }

        let bookmark = try bookmarkCoder.makeBookmark(for: destination.rootURL)
        let payload = FileSessionExportDestinationStorage(
            bookmark: bookmark,
            displayName: destination.displayName
        )
        let data = try jsonEncoder.encode(payload)
        try data.write(to: storageURL, options: [.atomic])
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: storageURL.path) else {
            return
        }

        try fileManager.removeItem(at: storageURL)
    }
}

enum SessionExportDestinationIssue: Equatable, Sendable {
    case destinationMissing
    case destinationStale
}

enum SessionExportFailure: Equatable, Sendable {
    case permissionDenied
    case copyInterrupted
    case identityConflict
}

enum SessionExportOutcome: Equatable, Sendable {
    case exported(sessionId: String)
    case alreadyExported(sessionId: String)
    case deferred(sessionId: String, reason: SessionExportDestinationIssue)
    case failed(sessionId: String, failure: SessionExportFailure)
}

actor SessionExport {
    enum SessionExportError: LocalizedError {
        case sourceManifestMissing
        case sourceManifestUnreadable
        case sourceStatusMissing
        case sourceStatusIncomplete

        var errorDescription: String? {
            switch self {
            case .sourceManifestMissing:
                "source session manifest missing."
            case .sourceManifestUnreadable:
                "source session manifest unreadable."
            case .sourceStatusMissing:
                "source session status missing."
            case .sourceStatusIncomplete:
                "source session status not complete."
            }
        }
    }

    struct SessionExportIdentity: Equatable, Sendable {
        let sessionId: String
        let sourceFingerprint: String
    }

    struct SessionExportRequest: Sendable {
        let sessionDirectory: URL
        let identity: SessionExportIdentity
    }

    enum ExportAttemptResult: Sendable {
        case completed(SessionExportOutcome)
        case retained(SessionExportOutcome)
    }

    private let destinationStore: SessionExportDestinationStoring
    private let copyItem: @Sendable (URL, URL) throws -> Void
    private let fileManager: FileManager
    private let securityScopeAccessor: SessionExportSecurityScopeAccessing
    private var pendingBySessionID: [String: SessionExportRequest] = [:]
    private var pendingOrder: [String] = []

    init(
        destinationStore: SessionExportDestinationStoring,
        copyItem: @escaping @Sendable (URL, URL) throws -> Void = { source, destination in
            try FileManager.default.copyItem(at: source, to: destination)
        },
        securityScopeAccessor: SessionExportSecurityScopeAccessing = AppleSessionExportSecurityScopeAccessor()
    ) {
        self.destinationStore = destinationStore
        self.copyItem = copyItem
        self.securityScopeAccessor = securityScopeAccessor
        fileManager = .default
    }

    func destinationSnapshot() async -> SessionExportDestinationState {
        (try? destinationStore.load()) ?? .missing
    }

    func destinationSnapshotOrThrow() async throws -> SessionExportDestinationState {
        try destinationStore.load()
    }

    func selectDestination(_ destination: SessionExportDestination) async throws {
        let shouldKeepAccess = securityScopeAccessor.startAccessing(destination.rootURL)
        defer {
            if shouldKeepAccess {
                securityScopeAccessor.stopAccessing(destination.rootURL)
            }
        }
        try destinationStore.save(destination)
    }

    func clearDestination() async throws {
        try destinationStore.clear()
    }

    func pendingSessionIDs() async -> [String] {
        pendingOrder
    }

    func enqueue(sessionDirectory: URL) async throws -> Bool {
        let identity = try validateSourceReady(sessionDirectory: sessionDirectory)
        let request = SessionExportRequest(sessionDirectory: sessionDirectory, identity: identity)
        guard pendingBySessionID[identity.sessionId] == nil else { return false }

        pendingBySessionID[identity.sessionId] = request
        pendingOrder.append(identity.sessionId)
        return true
    }

    func flush() async -> [SessionExportOutcome] {
        var outcomes: [SessionExportOutcome] = []
        var retained: [(String, SessionExportRequest)] = []

        for sessionId in pendingOrder {
            guard let request = pendingBySessionID[sessionId] else { continue }
            let result = await handle(request: request)
            switch result {
            case .completed(let outcome):
                outcomes.append(outcome)
                pendingBySessionID[sessionId] = nil
            case .retained(let outcome):
                outcomes.append(outcome)
                retained.append((sessionId, request))
            }
        }

        pendingOrder = retained.map(\.0)
        pendingBySessionID = Dictionary(uniqueKeysWithValues: retained)
        return outcomes
    }

    private func handle(request: SessionExportRequest) async -> ExportAttemptResult {
        let snapshot = await destinationSnapshot()
        guard case .available(let destination) = snapshot else {
            return .retained(
                .deferred(
                    sessionId: request.identity.sessionId,
                    reason: destinationIssue(from: snapshot)
                )
            )
        }

        let shouldKeepAccess = securityScopeAccessor.startAccessing(destination.rootURL)
        defer {
            if shouldKeepAccess {
                securityScopeAccessor.stopAccessing(destination.rootURL)
            }
        }

        do {
            let targetSessionDirectory = destination.rootURL.appendingPathComponent(
                request.sessionDirectory.lastPathComponent,
                isDirectory: true
            )

            if fileManager.fileExists(atPath: targetSessionDirectory.path) {
                do {
                    let existingIdentity = try readSessionIdentity(from: targetSessionDirectory)
                    if existingIdentity == request.identity {
                        if try destinationStatusIsAlreadyPublished(at: targetSessionDirectory) {
                            return .completed(.alreadyExported(sessionId: request.identity.sessionId))
                        }
                        try fileManager.removeItem(at: targetSessionDirectory)
                    } else {
                        return .retained(
                            .failed(sessionId: request.identity.sessionId, failure: .identityConflict)
                        )
                    }
                } catch {
                    if try isDirectoryEmpty(at: targetSessionDirectory) {
                        try fileManager.removeItem(at: targetSessionDirectory)
                    } else {
                        return .retained(
                            .failed(sessionId: request.identity.sessionId, failure: .identityConflict)
                        )
                    }
                }
            }

            try copySession(source: request.sessionDirectory, to: targetSessionDirectory)
            return .completed(.exported(sessionId: request.identity.sessionId))
        } catch {
            return .retained(.failed(sessionId: request.identity.sessionId, failure: mapCopyFailure(from: error)))
        }
    }

    private func destinationIssue(from snapshot: SessionExportDestinationState) -> SessionExportDestinationIssue {
        switch snapshot {
        case .missing:
            .destinationMissing
        case .stale:
            .destinationStale
        case .available:
            .destinationMissing
        }
    }

    private func copySession(source: URL, to destination: URL) throws {
        let manifestSource = source.appendingPathComponent(AIWatchingSchema.manifestFileName)
        let statusSource = source.appendingPathComponent(AIWatchingSchema.statusFileName)

        if !fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        }

        if fileManager.fileExists(atPath: manifestSource.path) {
            try copyItem(manifestSource, destination.appendingPathComponent(AIWatchingSchema.manifestFileName))
        }

        let entries = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        let childPaths = entries
            .filter { $0.lastPathComponent != AIWatchingSchema.statusFileName }
            .filter { $0.lastPathComponent != AIWatchingSchema.manifestFileName }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

        for child in childPaths {
            let destinationChild = destination.appendingPathComponent(child.lastPathComponent, isDirectory: child.hasDirectoryPath)
            try copyItemRecursively(source: child, destination: destinationChild)
        }

        if fileManager.fileExists(atPath: statusSource.path) {
            let statusDestination = destination.appendingPathComponent(AIWatchingSchema.statusFileName)
            try copyItem(statusSource, statusDestination)
        }
    }

    private func copyItemRecursively(source: URL, destination: URL) throws {
        var isDirectory = ObjCBool(false)
        fileManager.fileExists(atPath: source.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            }
            let children = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let destinationChild = destination.appendingPathComponent(child.lastPathComponent, isDirectory: child.hasDirectoryPath)
                try copyItemRecursively(source: child, destination: destinationChild)
            }
            return
        }

        if fileManager.fileExists(atPath: destination.deletingLastPathComponent().path) == false {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        try copyItem(source, destination)
    }

    private func parseSessionIdentity(from sessionDirectory: URL) throws -> SessionExportIdentity {
        let manifestURL = sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(SessionManifest.self, from: manifestData)
        guard AIWatchingSchema.isSupportedCaptureManifest(
            schemaVersion: manifest.schemaVersion,
            source: manifest.source
        ) else {
            throw SessionExportError.sourceManifestUnreadable
        }
        let sourceFingerprint = [manifest.sessionId, manifest.startedAt, manifest.source.rawValue].joined(separator: "|")
        return SessionExportIdentity(sessionId: manifest.sessionId, sourceFingerprint: sourceFingerprint)
    }

    private func validateSourceReady(sessionDirectory: URL) throws -> SessionExportIdentity {
        let manifestURL = sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw SessionExportError.sourceManifestMissing
        }

        do {
            _ = try parseSessionIdentity(from: sessionDirectory)
        } catch {
            throw SessionExportError.sourceManifestUnreadable
        }

        let statusURL = sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName)
        guard fileManager.fileExists(atPath: statusURL.path) else {
            throw SessionExportError.sourceStatusMissing
        }

        do {
            let statusData = try Data(contentsOf: statusURL)
            let status = try JSONDecoder().decode(SessionStatus.self, from: statusData)
            guard status.state == .complete else {
                throw SessionExportError.sourceStatusIncomplete
            }
        } catch let error as SessionExportError {
            throw error
        } catch {
            throw SessionExportError.sourceStatusIncomplete
        }

        return try parseSessionIdentity(from: sessionDirectory)
    }

    private func isDirectoryEmpty(at directory: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else {
            return true
        }
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return children.isEmpty
    }

    private func readSessionIdentity(from sessionDirectory: URL) throws -> SessionExportIdentity {
        let manifestURL = sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName)
        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(SessionManifest.self, from: data)
        guard AIWatchingSchema.isSupportedCaptureManifest(
            schemaVersion: manifest.schemaVersion,
            source: manifest.source
        ) else {
            throw SessionExportError.sourceManifestUnreadable
        }
        let sourceFingerprint = [manifest.sessionId, manifest.startedAt, manifest.source.rawValue].joined(separator: "|")
        return SessionExportIdentity(sessionId: manifest.sessionId, sourceFingerprint: sourceFingerprint)
    }

    private func destinationStatusIsAlreadyPublished(at sessionDirectory: URL) throws -> Bool {
        let statusURL = sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName)
        guard fileManager.fileExists(atPath: statusURL.path) else {
            return false
        }
        let data = try Data(contentsOf: statusURL)
        let status = try JSONDecoder().decode(SessionStatus.self, from: data)
        switch status.state {
        case .complete, .transcribing, .done, .error:
            return true
        case .recording:
            return false
        }
    }

    private func mapCopyFailure(from error: Error) -> SessionExportFailure {
        if let cocoaError = error as? CocoaError, cocoaError.code == .fileWriteNoPermission {
            return .permissionDenied
        }
        if error is CancellationError {
            return .copyInterrupted
        }
        return .copyInterrupted
    }
}

@MainActor
final class SessionExportRuntime: ObservableObject {
    private let exporter: SessionExport
    private let recordingsRootProvider: () throws -> URL
    private let fileManager: FileManager

    @Published private(set) var destinationState: SessionExportDestinationState = .missing
    @Published private(set) var pendingSessionIDs: [String] = []
    @Published private(set) var lastOutcomes: [SessionExportOutcome] = []
    @Published private(set) var lastError: Error?

    nonisolated static func liveLocalRecordingsRoot(fileManager: FileManager = .default) throws -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AIWatchingSchema.appFolderName, isDirectory: true)
        let recordings = base.appendingPathComponent(AIWatchingSchema.recordingsFolderName, isDirectory: true)
        try fileManager.createDirectory(at: recordings, withIntermediateDirectories: true)
        return recordings
    }

    nonisolated static func destinationBookmarkStorageURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AIWatchingSchema.appFolderName, isDirectory: true)
        return base
            .appendingPathComponent("SessionExport", isDirectory: true)
            .appendingPathComponent("destination-bookmark.json", isDirectory: false)
    }

    @MainActor static func live(
        destinationStorageURL: URL? = nil,
        recordingsRootProvider: (() throws -> URL)? = nil,
        bookmarkCoder: SessionExportBookmarkCoding = AppleSessionExportBookmarkCoder(),
        fileManager: FileManager = .default
    ) -> SessionExportRuntime {
        let resolvedRecordingsRootProvider: () throws -> URL = recordingsRootProvider ?? {
            try liveLocalRecordingsRoot(fileManager: fileManager)
        }
        let storageURL = destinationStorageURL ?? destinationBookmarkStorageURL(fileManager: fileManager)
        let destinationStore = FileSessionExportDestinationStore(
            storageURL: storageURL,
            bookmarkCoder: bookmarkCoder,
            fileManager: fileManager
        )
        let exporter = SessionExport(destinationStore: destinationStore)
        return SessionExportRuntime(
            exporter: exporter,
            recordingsRootProvider: resolvedRecordingsRootProvider,
            fileManager: fileManager
        )
    }

    init(
        exporter: SessionExport,
        recordingsRootProvider: @escaping () throws -> URL,
        fileManager: FileManager = .default
    ) {
        self.exporter = exporter
        self.recordingsRootProvider = recordingsRootProvider
        self.fileManager = fileManager
    }

    func refresh() async {
        do {
            destinationState = try await exporter.destinationSnapshotOrThrow()
            lastError = nil
        } catch {
            destinationState = .missing
            lastError = error
        }
        await refreshRuntimeQueues()
    }

    func selectDestination(_ destination: SessionExportDestination) async {
        do {
            try await exporter.selectDestination(destination)
            destinationState = try await exporter.destinationSnapshotOrThrow()
            lastError = nil
        } catch {
            destinationState = .missing
            lastError = error
        }
        await refreshRuntimeQueues()
    }

    func clearDestination() async {
        do {
            try await exporter.clearDestination()
            destinationState = try await exporter.destinationSnapshotOrThrow()
            lastError = nil
        } catch {
            destinationState = .missing
            lastError = error
        }
        await refreshRuntimeQueues()
    }

    func enqueueCompletedSession(_ sessionDirectory: URL) async {
        do {
            _ = try await exporter.enqueue(sessionDirectory: sessionDirectory)
            lastOutcomes = await exporter.flush()
            destinationState = try await exporter.destinationSnapshotOrThrow()
            lastError = nil
        } catch {
            lastOutcomes = []
            lastError = error
            do {
                destinationState = try await exporter.destinationSnapshotOrThrow()
            } catch {
                // Keep current destination state when snapshot cannot be loaded.
            }
        }
        await refreshRuntimeQueues()
    }

    nonisolated func scheduleCompletedSession(_ sessionDirectory: URL) {
        Task { @MainActor [weak self] in
            await self?.enqueueCompletedSession(sessionDirectory)
        }
    }

    func resumeCompleteSessions() async {
        do {
            let recordingsRoot = try recordingsRootProvider()
            let entries = try fileManager.contentsOfDirectory(
                at: recordingsRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )

            for entry in entries {
                var isDirectory = ObjCBool(false)
                fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory)
                guard isDirectory.boolValue else { continue }

                let statusURL = entry.appendingPathComponent(AIWatchingSchema.statusFileName)
                guard fileManager.fileExists(atPath: statusURL.path) else { continue }

                do {
                    let statusData = try Data(contentsOf: statusURL)
                    let status = try JSONDecoder().decode(SessionStatus.self, from: statusData)
                    guard status.state == .complete else { continue }
                    _ = try await exporter.enqueue(sessionDirectory: entry)
                } catch {
                    continue
                }
            }

            lastOutcomes = await exporter.flush()
            destinationState = try await exporter.destinationSnapshotOrThrow()
            lastError = nil
        } catch {
            lastError = error
            lastOutcomes = []
        }

        await refreshRuntimeQueues()
    }

    func retryPending() async {
        do {
            lastOutcomes = await exporter.flush()
            destinationState = try await exporter.destinationSnapshotOrThrow()
            lastError = nil
        } catch {
            destinationState = .missing
            lastError = error
        }
        await refreshRuntimeQueues()
    }

    private func refreshRuntimeQueues() async {
        destinationState = if case .missing = destinationState {
            destinationState
        } else {
            (try? await exporter.destinationSnapshotOrThrow()) ?? destinationState
        }
        pendingSessionIDs = await exporter.pendingSessionIDs()
    }

}
