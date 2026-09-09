import Foundation

struct CaptureStore {
    let fileManager: FileManager = .default

    func aiWatchingRoot() throws -> URL {
        // The app stores recordings locally (Application Support via
        // SessionExportRuntime) and copies them out through a security-scoped
        // bookmark, so no iCloud container entitlement is needed.
        let base = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = base.appendingPathComponent(AIWatchingSchema.appFolderName, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func recordingsRoot() throws -> URL {
        let root = try aiWatchingRoot().appendingPathComponent(AIWatchingSchema.recordingsFolderName, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func makeSessionDirectory(startedAt: Date, sessionId: String) throws -> URL {
        try makeSessionDirectory(startedAt: startedAt, sessionId: sessionId, recordingsRoot: try recordingsRoot())
    }

    func sessionDirectory(startedAt: Date, sessionId: String, recordingsRoot: URL) -> URL {
        let name = "\(AIWatchingClock.sessionFolderPrefix(startedAt))__capture__\(sessionId)"
        return recordingsRoot.appendingPathComponent(name, isDirectory: true)
    }

    func makeSessionDirectory(startedAt: Date, sessionId: String, recordingsRoot: URL) throws -> URL {
        let dir = sessionDirectory(startedAt: startedAt, sessionId: sessionId, recordingsRoot: recordingsRoot)
        try fileManager.createDirectory(at: dir.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true), withIntermediateDirectories: true)
        return dir
    }

    func audioURL(sessionDirectory: URL, chunkIndex: Int) -> URL {
        sessionDirectory
            .appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true)
            .appendingPathComponent(String(format: "chunk_%04d.m4a", chunkIndex))
    }

    func relativeAudioPath(chunkIndex: Int) -> String {
        "\(AIWatchingSchema.audioFolderName)/\(String(format: "chunk_%04d.m4a", chunkIndex))"
    }

    func writeManifest(_ manifest: SessionManifest, to sessionDirectory: URL) throws {
        try writeJSON(manifest, to: sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName))
    }

    func writeStatus(_ status: SessionStatus, to sessionDirectory: URL) throws {
        try writeJSON(status, to: sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName))
    }

    func recentSessionNames(limit: Int = 20) throws -> [String] {
        try recentSessionNames(at: recordingsRoot(), limit: limit)
    }

    func recentSessionNames(at recordingsRoot: URL, limit: Int = 20) throws -> [String] {
        let root = recordingsRoot
        let urls = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.hasDirectoryPath }
            .sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs > rhs
            }
            .prefix(limit)
            .map(\.lastPathComponent)
    }

    func deleteSession(named name: String) throws {
        let dir = try recordingsRoot().appendingPathComponent(name, isDirectory: true)
        try deleteSession(at: dir)
    }

    func deleteSession(at sessionDirectory: URL) throws {
        let root = try recordingsRoot().standardizedFileURL
        try deleteSession(at: sessionDirectory, within: root)
    }

    func deleteSession(at sessionDirectory: URL, within recordingsRoot: URL) throws {
        let root = recordingsRoot.standardizedFileURL
        let target = sessionDirectory.standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard target.path != root.path, target.path.hasPrefix(rootPath) else {
            throw CaptureStoreError.outsideRecordingsRoot
        }
        guard fileManager.fileExists(atPath: target.path) else {
            throw CaptureStoreError.sessionNotFound
        }
        try fileManager.removeItem(at: target)
    }

    /// Whether a session directory lives inside the recordings root.
    func isUsingICloud() -> Bool {
        // No iCloud container: recordings go out via a security-scoped
        // bookmark to a user-chosen folder. Kept for the diagnostics screen.
        false
    }

    /// Best-effort AIWatching root path, for the diagnostics screen.
    func rootPath() -> String {
        (try? aiWatchingRoot().path) ?? "unavailable"
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }
}

enum CaptureStoreError: LocalizedError {
    case outsideRecordingsRoot
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .outsideRecordingsRoot:
            "Refusing to delete outside AIWatching recordings root."
        case .sessionNotFound:
            "Session directory not found."
        }
    }
}
