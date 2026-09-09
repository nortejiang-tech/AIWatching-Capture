import Foundation
import AVFoundation

struct WatchCaptureImporter {
    let captureStore: CaptureStore
    let fileManager: FileManager
    let writeDiagnosticsFile: (Data, URL) throws -> Void
    let recordingsRootProvider: @Sendable () throws -> URL
    let resolveDuration: @Sendable (URL) throws -> TimeInterval
    let enqueueCompletedSession: @Sendable (URL) -> Void

    init(
        captureStore: CaptureStore = CaptureStore(),
        fileManager: FileManager = .default,
        writeDiagnosticsFile: @escaping (Data, URL) throws -> Void = { data, destination in
            try data.write(to: destination, options: [.atomic])
        },
        recordingsRootProvider: (@Sendable () throws -> URL)? = nil,
        resolveDuration: @escaping @Sendable (URL) throws -> TimeInterval = { fileURL in
            let asset = AVURLAsset(url: fileURL)
            let seconds = CMTimeGetSeconds(asset.duration)
            guard seconds.isFinite else {
                throw WatchCaptureImportError.durationParseFailed
            }
            return max(0, seconds)
        },
        enqueueCompletedSession: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.captureStore = captureStore
        self.fileManager = fileManager
        self.writeDiagnosticsFile = writeDiagnosticsFile
        self.recordingsRootProvider = recordingsRootProvider ?? { try CaptureStore().recordingsRoot() }
        self.resolveDuration = resolveDuration
        self.enqueueCompletedSession = enqueueCompletedSession
    }

    func stagingSessionRoot(_ stagingRoot: URL, sessionId: String) -> URL {
        stagingRoot.appendingPathComponent(sessionId, isDirectory: true)
    }

    func metadataFileURL(for stagingSessionDirectory: URL) -> URL {
        stagingSessionDirectory.appendingPathComponent(Self.metadataFileName)
    }

    func chunkAudioFileURL(for stagingSessionDirectory: URL, chunkIndex: Int) -> URL {
        stagingSessionDirectory.appendingPathComponent(Self.chunkAudioFileName(chunkIndex: chunkIndex))
    }

    func chunkMetadataFileURL(for stagingSessionDirectory: URL, chunkIndex: Int) -> URL {
        stagingSessionDirectory.appendingPathComponent(Self.chunkMetadataFileName(chunkIndex: chunkIndex))
    }

    static func chunkAudioFileName(chunkIndex: Int) -> String {
        AIWatchingSchema.chunkAudioFileName(chunkIndex: chunkIndex)
    }

    static func chunkMetadataFileName(chunkIndex: Int) -> String {
        AIWatchingSchema.chunkMetadataFileName(chunkIndex: chunkIndex)
    }

    @discardableResult
    func importAllPendingWatchCaptureSessions(at stagingRoot: URL) -> [WatchCapturePendingImportFailure] {
        guard let sessionDirectories = try? listSessionDirectories(at: stagingRoot) else {
            return []
        }

        var failures: [WatchCapturePendingImportFailure] = []
        for directory in sessionDirectories {
            do {
                _ = try importSession(from: directory)
            } catch WatchCaptureImportError.sessionNotReady {
                // Awaiting more chunk transfers; keep staging and retry on a later pass.
                continue
            } catch {
                failures.append(
                    WatchCapturePendingImportFailure(
                        stagingSessionDirectory: directory,
                        errorDescription: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                    )
                )
            }
        }
        return failures
    }

    func importSession(from stagingSessionDirectory: URL) throws -> URL {
        let plan = try loadSessionPlan(from: stagingSessionDirectory)

        let recordingsRoot = try recordingsRootProvider()
        let startedAt = try parseISODate(plan.startedAt)
        let endedAt = try parseISODate(plan.endedAt)
        guard endedAt >= startedAt else {
            throw WatchCaptureImportError.invalidTimestamp
        }
        if let completedSession = existingCompleteSession(
            at: recordingsRoot,
            sessionId: plan.sessionId
        ) {
            try ensureCompleteSessionDiagnostics(for: plan, at: completedSession)
            try fileManager.removeItem(at: stagingSessionDirectory)
            enqueueCompletedSession(completedSession)
            return completedSession
        }

        let sessionDirectory: URL
        if let existing = existingSessionDirectory(
            at: recordingsRoot,
            sessionId: plan.sessionId
        ) {
            try prepareExistingSessionForRepair(existing, expectedSessionId: plan.sessionId)
            sessionDirectory = existing
        } else {
            sessionDirectory = try makeSessionDirectory(
                recordingsRoot: recordingsRoot,
                startedAt: startedAt,
                sessionId: plan.sessionId
            )
        }

        var manifestChunks: [AudioChunk] = []
        for chunk in plan.chunks {
            let duration = try resolveDuration(chunk.stagedAudioURL)
            guard duration > 0, duration.isFinite else {
                throw WatchCaptureImportError.durationParseFailed
            }

            let outputAudioURL = captureStore.audioURL(sessionDirectory: sessionDirectory, chunkIndex: chunk.index)
            if fileManager.fileExists(atPath: outputAudioURL.path) {
                try fileManager.removeItem(at: outputAudioURL)
            }
            try fileManager.createDirectory(
                at: outputAudioURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.copyItem(at: chunk.stagedAudioURL, to: outputAudioURL)

            manifestChunks.append(
                AudioChunk(
                    file: captureStore.relativeAudioPath(chunkIndex: chunk.index),
                    index: chunk.index,
                    startOffsetSec: chunk.startOffsetSec,
                    durationSec: duration,
                    startedAt: AIWatchingClock.isoString(startedAt.addingTimeInterval(chunk.startOffsetSec))
                )
            )
        }

        let manifest = SessionManifest(
            sessionId: plan.sessionId,
            source: .watch,
            startedAt: plan.startedAt,
            endedAt: plan.endedAt,
            audio: AudioInfo(sampleRate: 16_000, channels: 1, format: "m4a-aac", codec: "aac"),
            chunks: manifestChunks
        )
        try captureStore.writeManifest(manifest, to: sessionDirectory)

        if let diagnostics = plan.diagnostics {
            try writeWatchCaptureDiagnostics(diagnostics, to: sessionDirectory)
        }

        let status = SessionStatus(state: .complete, updatedAt: plan.endedAt)
        try captureStore.writeStatus(status, to: sessionDirectory)

        try fileManager.removeItem(at: stagingSessionDirectory)
        enqueueCompletedSession(sessionDirectory)
        return sessionDirectory
    }

    func loadMetadata(at url: URL) throws -> WatchRecordingProbeMetadata {
        guard fileManager.fileExists(atPath: url.path) else {
            throw WatchCaptureImportError.metadataMissing
        }
        do {
            let data = try Data(contentsOf: url)
            let metadata = try JSONDecoder().decode(WatchRecordingProbeMetadata.self, from: data)
            return metadata
        } catch {
            throw WatchCaptureImportError.metadataReadFailed
        }
    }

    func writeMetadata(_ metadata: WatchRecordingProbeMetadata, to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        try data.write(to: destination, options: [.atomic])
    }

    func writeWatchCaptureDiagnostics(_ diagnostics: WatchCaptureDiagnostics, to sessionDirectory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(diagnostics)
        try writeDiagnosticsFile(
            data,
            sessionDirectory.appendingPathComponent(Self.watchCaptureDiagnosticsFileName)
        )
    }

    private func diagnosticsURL(for sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent(Self.watchCaptureDiagnosticsFileName)
    }

    private func loadDiagnostics(at sessionDirectory: URL) -> WatchCaptureDiagnostics? {
        let url = diagnosticsURL(for: sessionDirectory)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let diagnostics = try? JSONDecoder().decode(WatchCaptureDiagnostics.self, from: data),
              diagnostics.isValid()
        else {
            return nil
        }
        return diagnostics
    }

    private func ensureCompleteSessionDiagnostics(for plan: SessionPlan, at sessionDirectory: URL) throws {
        guard let diagnostics = plan.diagnostics else {
            return
        }

        if let existing = loadDiagnostics(at: sessionDirectory) {
            guard existing == diagnostics else {
                throw WatchCaptureImportError.existingSessionConflict
            }
            return
        }

        let existingPath = diagnosticsURL(for: sessionDirectory)
        guard !fileManager.fileExists(atPath: existingPath.path) else {
            throw WatchCaptureImportError.existingSessionConflict
        }

        do {
            try writeWatchCaptureDiagnostics(diagnostics, to: sessionDirectory)
        } catch {
            throw WatchCaptureImportError.existingSessionConflict
        }
    }

    // MARK: - Session plan (layout detection + readiness)

    private struct StagedChunk {
        let index: Int
        let startOffsetSec: TimeInterval
        let stagedAudioURL: URL
    }

    private struct SessionPlan {
        let sessionId: String
        let startedAt: String
        let endedAt: String
        let chunks: [StagedChunk]
        let diagnostics: WatchCaptureDiagnostics?
    }

    private func loadSessionPlan(from stagingSessionDirectory: URL) throws -> SessionPlan {
        let legacyMetadataURL = metadataFileURL(for: stagingSessionDirectory)
        let chunkSidecars = try listChunkSidecars(at: stagingSessionDirectory)
        let hasLegacy = fileManager.fileExists(atPath: legacyMetadataURL.path)

        if hasLegacy && !chunkSidecars.isEmpty {
            throw WatchCaptureImportError.stagingConflict
        }
        if hasLegacy {
            return try loadLegacySessionPlan(
                from: stagingSessionDirectory,
                metadataURL: legacyMetadataURL
            )
        }
        if chunkSidecars.isEmpty {
            throw WatchCaptureImportError.metadataMissing
        }
        return try loadChunkedSessionPlan(
            from: stagingSessionDirectory,
            sidecarURLs: chunkSidecars
        )
    }

    private func loadLegacySessionPlan(
        from stagingSessionDirectory: URL,
        metadataURL: URL
    ) throws -> SessionPlan {
        let metadata = try loadMetadata(at: metadataURL)
        guard metadata.metadataVersion == WatchRecordingProbeMetadata.singleChunkVersion,
              metadata.isValidUUIDSession(),
              metadata.source == "watch",
              metadata.isStructurallyValidChunk(),
              !metadata.fileName.isEmpty else {
            throw WatchCaptureImportError.invalidTransferMetadata
        }

        let sourceAudioURL = try locateLegacyAudioFile(in: stagingSessionDirectory)
        return SessionPlan(
            sessionId: metadata.sessionId,
            startedAt: metadata.startedAt,
            endedAt: metadata.endedAt,
            chunks: [
                StagedChunk(index: 0, startOffsetSec: 0, stagedAudioURL: sourceAudioURL)
            ],
            diagnostics: metadata.captureDiagnostics
        )
    }

    private func loadChunkedSessionPlan(
        from stagingSessionDirectory: URL,
        sidecarURLs: [URL]
    ) throws -> SessionPlan {
        var byIndex: [Int: (metadata: WatchRecordingProbeMetadata, audioURL: URL)] = [:]
        var finalMetadata: WatchRecordingProbeMetadata?
        for sidecarURL in sidecarURLs {
            let metadata = try loadMetadata(at: sidecarURL)
            guard metadata.metadataVersion == WatchRecordingProbeMetadata.chunkedVersion,
                  metadata.isValidUUIDSession(),
                  metadata.source == "watch",
                  metadata.isStructurallyValidChunk(),
                  !metadata.fileName.isEmpty,
                  sidecarURL.lastPathComponent == Self.chunkMetadataFileName(chunkIndex: metadata.chunkIndex),
                  byIndex[metadata.chunkIndex] == nil else {
                throw WatchCaptureImportError.invalidTransferMetadata
            }
            let audioURL = chunkAudioFileURL(for: stagingSessionDirectory, chunkIndex: metadata.chunkIndex)
            byIndex[metadata.chunkIndex] = (metadata: metadata, audioURL: audioURL)
            if metadata.isFinalChunk {
                if finalMetadata != nil {
                    throw WatchCaptureImportError.invalidTransferMetadata
                }
                finalMetadata = metadata
            }
        }

        guard let first = byIndex[0] else {
            throw WatchCaptureImportError.metadataMissing
        }
        guard byIndex.values.allSatisfy({
            $0.metadata.sessionId == first.metadata.sessionId && $0.metadata.startedAt == first.metadata.startedAt
        }) else {
            throw WatchCaptureImportError.invalidTransferMetadata
        }
        guard first.metadata.sessionId == stagingSessionDirectory.lastPathComponent else {
            throw WatchCaptureImportError.invalidTransferMetadata
        }

        let finals = byIndex.values.filter(\.metadata.isFinalChunk)
        guard let final = finalMetadata, finals.count == 1 else {
            if finalMetadata == nil {
                // The final chunk (the one carrying chunkCount) has not arrived yet.
                throw WatchCaptureImportError.sessionNotReady
            }
            throw WatchCaptureImportError.invalidTransferMetadata
        }
        guard let expectedCount = final.chunkCount else {
            throw WatchCaptureImportError.invalidTransferMetadata
        }
        // The final chunk must be the highest index (chunkCount == index + 1 is
        // enforced per-metadata; an index beyond it means inconsistent transfers).
        guard byIndex.keys.allSatisfy({ $0 < expectedCount }) else {
            throw WatchCaptureImportError.invalidTransferMetadata
        }

        var chunks: [StagedChunk] = []
        var previousOffset = -Double.greatestFiniteMagnitude
        for index in 0..<expectedCount {
            guard let payload = byIndex[index] else {
                throw WatchCaptureImportError.sessionNotReady
            }
            let metadata = payload.metadata
            let audioURL = payload.audioURL
            guard fileManager.fileExists(atPath: audioURL.path),
                  let size = try? fileManager.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber,
                  size.int64Value > 0 else {
                throw WatchCaptureImportError.sessionNotReady
            }
            guard metadata.chunkStartOffsetSec > previousOffset else {
                throw WatchCaptureImportError.invalidTransferMetadata
            }
            previousOffset = metadata.chunkStartOffsetSec
            chunks.append(
                StagedChunk(
                    index: index,
                    startOffsetSec: metadata.chunkStartOffsetSec,
                    stagedAudioURL: audioURL
                )
            )
        }

        return SessionPlan(
            sessionId: first.metadata.sessionId,
            startedAt: first.metadata.startedAt,
            endedAt: final.endedAt,
            chunks: chunks,
            diagnostics: final.captureDiagnostics
        )
    }

    private func listChunkSidecars(at stagingSessionDirectory: URL) throws -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(at: stagingSessionDirectory, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix("chunk_") && $0.pathExtension.lowercased() == "json" }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }

    private func listSessionDirectories(at stagingRoot: URL) throws -> [URL] {
        let urls = try fileManager.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil)
        return urls
            .filter { $0.hasDirectoryPath }
            .filter { isValidSessionId($0.lastPathComponent) }
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    }

    private func isValidSessionId(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    private func existingSessionIsComplete(at sessionDirectory: URL, expectedSessionId: String) -> Bool {
        do {
            let manifestURL = sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName)
            let statusURL = sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName)
            guard fileManager.fileExists(atPath: manifestURL.path), fileManager.fileExists(atPath: statusURL.path) else {
                return false
            }

            let manifestData = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(SessionManifest.self, from: manifestData)
            let statusData = try Data(contentsOf: statusURL)
            let status = try JSONDecoder().decode(SessionStatus.self, from: statusData)
            guard status.state == .complete,
                  AIWatchingSchema.isSupportedCaptureManifest(
                    schemaVersion: manifest.schemaVersion,
                    source: manifest.source
                  ),
                  manifest.sessionId == expectedSessionId,
                  manifest.source == .watch,
                  !manifest.chunks.isEmpty else {
                return false
            }

            for (position, chunk) in manifest.chunks.enumerated() {
                guard chunk.index == position,
                      chunk.file == captureStore.relativeAudioPath(chunkIndex: position),
                      chunk.durationSec.isFinite,
                      chunk.durationSec > 0 else {
                    return false
                }
                let audioURL = captureStore.audioURL(sessionDirectory: sessionDirectory, chunkIndex: position)
                guard fileManager.fileExists(atPath: audioURL.path),
                      let size = try fileManager.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber,
                      size.int64Value > 0 else {
                    return false
                }
                let actualDuration = try resolveDuration(audioURL)
                guard actualDuration.isFinite, actualDuration > 0 else {
                    return false
                }
            }
            return true
        } catch {
            return false
        }
    }

    private func existingSessionDirectory(at recordingsRoot: URL, sessionId: String) -> URL? {
        let suffix = "__capture__\(sessionId)"
        let entries = (try? fileManager.contentsOfDirectory(at: recordingsRoot, includingPropertiesForKeys: nil)) ?? []
        for entry in entries where entry.hasDirectoryPath {
            if entry.lastPathComponent.hasSuffix(suffix) {
                return entry
            }
        }
        return nil
    }

    private func existingCompleteSession(at recordingsRoot: URL, sessionId: String) -> URL? {
        guard let matched = existingSessionDirectory(at: recordingsRoot, sessionId: sessionId) else {
            return nil
        }
        if existingSessionIsComplete(at: matched, expectedSessionId: sessionId) {
            return matched
        }
        return nil
    }

    private func prepareExistingSessionForRepair(_ sessionDirectory: URL, expectedSessionId: String) throws {
        let manifestURL = sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName)
        if fileManager.fileExists(atPath: manifestURL.path) {
            let data = try Data(contentsOf: manifestURL)
            guard let manifest = try? JSONDecoder().decode(SessionManifest.self, from: data),
                  AIWatchingSchema.isSupportedCaptureManifest(
                    schemaVersion: manifest.schemaVersion,
                    source: manifest.source
                  ),
                  manifest.sessionId == expectedSessionId,
                  manifest.source == .watch else {
                throw WatchCaptureImportError.existingSessionConflict
            }
        }

        let statusURL = sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName)
        if fileManager.fileExists(atPath: statusURL.path) {
            try fileManager.removeItem(at: statusURL)
        }
    }

    private func makeSessionDirectory(
        recordingsRoot: URL,
        startedAt: Date,
        sessionId: String
    ) throws -> URL {
        let target = captureStore.sessionDirectory(
            startedAt: startedAt,
            sessionId: sessionId,
            recordingsRoot: recordingsRoot
        )
        if !fileManager.fileExists(atPath: target.path) {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: target.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true),
                withIntermediateDirectories: true
            )
            return target
        }

        try fileManager.createDirectory(
            at: target.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true),
            withIntermediateDirectories: true
        )
        return target
    }

    private func locateLegacyAudioFile(in stagingSessionDirectory: URL) throws -> URL {
        let entries = try fileManager.contentsOfDirectory(at: stagingSessionDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != Self.metadataFileName }

        guard let audioURL = entries.first(where: { $0.lastPathComponent == Self.legacyAudioFileName }) else {
            let fallback = entries.first { $0.pathExtension.lowercased() == "m4a" }
            guard let found = fallback else {
                throw WatchCaptureImportError.audioFileMissing
            }
            return found
        }
        return audioURL
    }

    private func parseISODate(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: value) else {
            throw WatchCaptureImportError.invalidTimestamp
        }
        return date
    }

    private static let metadataFileName = "metadata.json"
    private static let legacyAudioFileName = "audio.m4a"
    static let watchCaptureDiagnosticsFileName = "watch-capture-diagnostics.json"
}

struct WatchCapturePendingImportFailure: Equatable, Sendable {
    let stagingSessionDirectory: URL
    let errorDescription: String
}

enum WatchCaptureImportError: Error, LocalizedError {
    case metadataMissing
    case metadataReadFailed
    case invalidSessionId
    case invalidTimestamp
    case audioFileMissing
    case durationParseFailed
    case invalidTransferMetadata
    case existingSessionConflict
    case stagingConflict
    case sessionNotReady

    var errorDescription: String? {
        switch self {
        case .metadataMissing:
            "missing watch probe metadata"
        case .metadataReadFailed:
            "failed to read watch probe metadata"
        case .invalidSessionId:
            "watch probe metadata has invalid sessionId"
        case .invalidTimestamp:
            "invalid watch probe timestamp"
        case .audioFileMissing:
            "missing watch probe audio file in staging"
        case .durationParseFailed:
            "failed to resolve watch probe duration"
        case .invalidTransferMetadata:
            "invalid watch probe transfer metadata"
        case .existingSessionConflict:
            "existing capture session conflicts with watch import"
        case .stagingConflict:
            "existing watch capture staging conflicts with incoming transfer"
        case .sessionNotReady:
            "watch capture session awaiting remaining chunk transfers"
        }
    }
}
