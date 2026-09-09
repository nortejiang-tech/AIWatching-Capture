import Foundation
import XCTest
@testable import AIWatching

@MainActor
final class WatchCaptureImporterTests: XCTestCase {
    func testImporterCreatesStandardWatchSessionWithFixedChunkPath() throws {
        let root = uniqueTempDirectory()
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 123.4 }
        )
        let metadata = WatchRecordingProbeMetadata(
            sessionId: UUID().uuidString,
            startedAt: AIWatchingClock.isoString(Date(timeIntervalSinceNow: -20)),
            endedAt: AIWatchingClock.isoString(),
            durationSec: 99.9,
            fileName: "aivision-watch-probe.m4a"
        )

        let stagingSession = importer.stagingSessionRoot(root, sessionId: metadata.sessionId)
        try FileManager.default.createDirectory(at: stagingSession, withIntermediateDirectories: true)
        let audioURL = stagingSession.appendingPathComponent("audio.m4a")
        try Data([0x00]).write(to: audioURL)
        try importer.writeMetadata(metadata, to: importer.metadataFileURL(for: stagingSession))

        let sessionDirectory = try importer.importSession(from: stagingSession)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let manifest = try decodeManifest(at: sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName))
        let status = try decodeStatus(at: sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName))
        let audioOutput = sessionDirectory.appendingPathComponent(AIWatchingSchema.audioFolderName)
            .appendingPathComponent("chunk_0000.m4a")

        XCTAssertEqual(manifest.source, .watch)
        XCTAssertEqual(manifest.sessionId, metadata.sessionId)
        XCTAssertEqual(manifest.startedAt, metadata.startedAt)
        XCTAssertEqual(manifest.endedAt, metadata.endedAt)
        XCTAssertEqual(manifest.chunks.count, 1)
        XCTAssertEqual(manifest.chunks[0].index, 0)
        XCTAssertEqual(manifest.chunks[0].file, "audio/chunk_0000.m4a")
        XCTAssertEqual(manifest.chunks[0].startOffsetSec, 0)
        XCTAssertEqual(manifest.chunks[0].durationSec, 123.4)
        XCTAssertEqual(manifest.audio.sampleRate, 16_000)
        XCTAssertEqual(manifest.audio.channels, 1)
        XCTAssertEqual(manifest.audio.format, "m4a-aac")
        XCTAssertEqual(manifest.audio.codec, "aac")
        XCTAssertEqual(status.state, .complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioOutput.path))
    }

    func testImportUsesActualAudioDurationNotMetadataValue() throws {
        let root = uniqueTempDirectory()
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { root.appendingPathComponent("recordings", isDirectory: true) },
            resolveDuration: { _ in 2.5 }
        )
        let metadata = WatchRecordingProbeMetadata(
            sessionId: UUID().uuidString,
            startedAt: AIWatchingClock.isoString(),
            endedAt: AIWatchingClock.isoString(),
            durationSec: 9.9,
            fileName: "aivision-watch-probe.m4a"
        )

        let stagingSession = importer.stagingSessionRoot(root, sessionId: metadata.sessionId)
        try FileManager.default.createDirectory(at: stagingSession, withIntermediateDirectories: true)
        let audioURL = stagingSession.appendingPathComponent("audio.m4a")
        try Data([0x11]).write(to: audioURL)
        try importer.writeMetadata(metadata, to: importer.metadataFileURL(for: stagingSession))

        let sessionDirectory = try importer.importSession(from: stagingSession)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let manifest = try decodeManifest(at: sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName))
        XCTAssertEqual(manifest.chunks[0].durationSec, 2.5)
        XCTAssertNotEqual(manifest.chunks[0].durationSec, metadata.durationSec)
    }

    func testImporterRejectsMissingMetadataOrInvalidSessionId() throws {
        let importer = WatchCaptureImporter()

        let missingMetadataRoot = uniqueTempDirectory()
        let missingMetadataSession = importer.stagingSessionRoot(
            missingMetadataRoot,
            sessionId: UUID().uuidString
        )
        try FileManager.default.createDirectory(at: missingMetadataSession, withIntermediateDirectories: true)
        try Data([0x00]).write(to: missingMetadataSession.appendingPathComponent("audio.m4a"))

        XCTAssertThrowsError(try importer.importSession(from: missingMetadataSession)) { error in
            XCTAssertEqual(error as? WatchCaptureImportError, .metadataMissing)
        }

        let invalidMetadataSessionRoot = uniqueTempDirectory()
        let metadata = WatchRecordingProbeMetadata(
            sessionId: "not-a-uuid",
            startedAt: AIWatchingClock.isoString(),
            endedAt: AIWatchingClock.isoString(),
            durationSec: 1,
            fileName: "audio.m4a"
        )
        let invalidMetadataSession = importer.stagingSessionRoot(
            invalidMetadataSessionRoot,
            sessionId: metadata.sessionId
        )
        try FileManager.default.createDirectory(at: invalidMetadataSession, withIntermediateDirectories: true)
        try Data([0x00]).write(to: invalidMetadataSession.appendingPathComponent("audio.m4a"))
        try importer.writeMetadata(metadata, to: importer.metadataFileURL(for: invalidMetadataSession))

        XCTAssertThrowsError(try importer.importSession(from: invalidMetadataSession)) { error in
            XCTAssertEqual(error as? WatchCaptureImportError, .invalidTransferMetadata)
        }
    }

    func testImporterKeepsStagingWhenImportFailsAndAllowsRetryLater() throws {
        let root = uniqueTempDirectory()
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let failingImporter = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in throw WatchCaptureImportError.durationParseFailed }
        )
        let sessionId = UUID().uuidString
        let staging = failingImporter.stagingSessionRoot(root, sessionId: sessionId)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data([0x00]).write(to: staging.appendingPathComponent("audio.m4a"))
        let metadata = WatchRecordingProbeMetadata(
            sessionId: sessionId,
            startedAt: AIWatchingClock.isoString(),
            endedAt: AIWatchingClock.isoString(),
            durationSec: 1,
            fileName: "audio.m4a"
        )
        try failingImporter.writeMetadata(metadata, to: failingImporter.metadataFileURL(for: staging))

        XCTAssertThrowsError(try failingImporter.importSession(from: staging))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent("audio.m4a").path))

        let retryImporter = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 4.2 }
        )
        let sessionDirectory = try retryImporter.importSession(from: staging)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(sessionDirectory.lastPathComponent.hasSuffix("__capture__\(sessionId)"), true)
    }

    func testImporterDeduplicatesRepeatSessionId() throws {
        let root = uniqueTempDirectory()
        let sessionId = UUID().uuidString
        let metadata = WatchRecordingProbeMetadata(
            sessionId: sessionId,
            startedAt: AIWatchingClock.isoString(Date(timeIntervalSinceNow: -20)),
            endedAt: AIWatchingClock.isoString(),
            durationSec: 4.2,
            fileName: "audio.m4a"
        )

        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 4.2 }
        )

        let firstStaging = importer.stagingSessionRoot(root, sessionId: sessionId)
        try FileManager.default.createDirectory(at: firstStaging, withIntermediateDirectories: true)
        try Data([0x00]).write(to: firstStaging.appendingPathComponent("audio.m4a"))
        try importer.writeMetadata(metadata, to: importer.metadataFileURL(for: firstStaging))
        let firstSession = try importer.importSession(from: firstStaging)

        let secondStaging = importer.stagingSessionRoot(root, sessionId: sessionId)
        try FileManager.default.createDirectory(at: secondStaging, withIntermediateDirectories: true)
        try Data([0x01]).write(to: secondStaging.appendingPathComponent("audio.m4a"))
        let duplicatedMetadata = WatchRecordingProbeMetadata(
            sessionId: sessionId,
            startedAt: AIWatchingClock.isoString(Date(timeIntervalSinceNow: -10)),
            endedAt: AIWatchingClock.isoString(),
            durationSec: 4.2,
            fileName: "audio.m4a"
        )
        try importer.writeMetadata(duplicatedMetadata, to: importer.metadataFileURL(for: secondStaging))

        let secondSession = try importer.importSession(from: secondStaging)

        XCTAssertEqual(firstSession, secondSession)
        let audioDir = firstSession.appendingPathComponent(AIWatchingSchema.audioFolderName)
        XCTAssertEqual((try FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil).count), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondStaging.path))
        defer { try? FileManager.default.removeItem(at: firstSession) }
    }

    func testImportAllPendingWatchCaptureSessionsSkipsFailuresButRetriesOnNextRun() throws {
        let root = uniqueTempDirectory()
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 2.0 }
        )

        let validSessionId = UUID().uuidString
        let validStaging = importer.stagingSessionRoot(root, sessionId: validSessionId)
        try FileManager.default.createDirectory(at: validStaging, withIntermediateDirectories: true)
        try Data([0x00]).write(to: validStaging.appendingPathComponent("audio.m4a"))
        let validMetadata = WatchRecordingProbeMetadata(
            sessionId: validSessionId,
            startedAt: AIWatchingClock.isoString(),
            endedAt: AIWatchingClock.isoString(),
            durationSec: 2,
            fileName: "audio.m4a"
        )
        try importer.writeMetadata(validMetadata, to: importer.metadataFileURL(for: validStaging))

        let failedSessionId = UUID().uuidString
        let failedStaging = importer.stagingSessionRoot(root, sessionId: failedSessionId)
        try FileManager.default.createDirectory(at: failedStaging, withIntermediateDirectories: true)
        let failedMetadata = WatchRecordingProbeMetadata(
            sessionId: failedSessionId,
            startedAt: AIWatchingClock.isoString(),
            endedAt: AIWatchingClock.isoString(),
            durationSec: 2,
            fileName: "audio.m4a"
        )
        try importer.writeMetadata(failedMetadata, to: importer.metadataFileURL(for: failedStaging))

        let firstFailures = importer.importAllPendingWatchCaptureSessions(at: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: validStaging.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedStaging.path))
        XCTAssertEqual(firstFailures.count, 1)

        try Data([0x01]).write(to: failedStaging.appendingPathComponent("audio.m4a"))
        let retryImporter = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 3.3 }
        )
        let retryFailures = retryImporter.importAllPendingWatchCaptureSessions(at: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: failedStaging.path))
        XCTAssertTrue(retryFailures.isEmpty)
        defer { failedSessionId.removePath(root) }
    }

    func testStatusWrittenAfterManifestForStandardSession() throws {
        let root = uniqueTempDirectory()
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 1.8 }
        )
        let metadata = WatchRecordingProbeMetadata(
            sessionId: UUID().uuidString,
            startedAt: AIWatchingClock.isoString(Date(timeIntervalSinceNow: -5)),
            endedAt: AIWatchingClock.isoString(),
            durationSec: 1.8,
            fileName: "audio.m4a"
        )
        let staging = importer.stagingSessionRoot(root, sessionId: metadata.sessionId)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data([0x00]).write(to: staging.appendingPathComponent("audio.m4a"))
        try importer.writeMetadata(metadata, to: importer.metadataFileURL(for: staging))

        let sessionDirectory = try importer.importSession(from: staging)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let manifestURL = sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName)
        let statusURL = sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName)
        XCTAssertTrue(manifestURL.fileExists)
        XCTAssertTrue(statusURL.fileExists)
        let status = try decodeStatus(at: statusURL)
        XCTAssertEqual(status.state, .complete)
        let manifest = try decodeManifest(at: manifestURL)
        XCTAssertNotNil(manifest.endedAt)
    }

    func testInvalidCompleteSessionDoesNotDiscardStagingAudio() throws {
        let root = uniqueTempDirectory()
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let sessionId = UUID().uuidString
        let metadata = WatchRecordingProbeMetadata(
            sessionId: sessionId,
            startedAt: AIWatchingClock.isoString(Date(timeIntervalSinceNow: -5)),
            endedAt: AIWatchingClock.isoString(),
            durationSec: 2,
            fileName: "audio.m4a"
        )
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 2 }
        )
        let staging = importer.stagingSessionRoot(root, sessionId: sessionId)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data([0x42]).write(to: staging.appendingPathComponent("audio.m4a"))
        try importer.writeMetadata(metadata, to: importer.metadataFileURL(for: staging))

        let existing = CaptureStore().sessionDirectory(
            startedAt: ISO8601DateFormatter().date(from: metadata.startedAt)!,
            sessionId: sessionId,
            recordingsRoot: recordingsRoot
        )
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let manifest = SessionManifest(
            sessionId: sessionId,
            source: .watch,
            startedAt: metadata.startedAt,
            endedAt: metadata.endedAt,
            chunks: [AudioChunk(file: "audio/chunk_0000.m4a", index: 0, startOffsetSec: 0, durationSec: 2)]
        )
        try CaptureStore().writeManifest(manifest, to: existing)
        try CaptureStore().writeStatus(SessionStatus(state: .complete), to: existing)

        let imported = try importer.importSession(from: staging)
        XCTAssertEqual(imported, existing)
        XCTAssertEqual(
            try Data(contentsOf: existing.appendingPathComponent("audio/chunk_0000.m4a")),
            Data([0x42])
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testImportRejectsV2WatchExistingSessionAndPreservesBothTrees() throws {
        let root = uniqueTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let captureStore = CaptureStore()
        let sessionId = UUID().uuidString
        let startedAtDate = Date(timeIntervalSince1970: 1_700_000_000)
        let startedAt = AIWatchingClock.isoString(startedAtDate)
        let endedAt = AIWatchingClock.isoString(startedAtDate.addingTimeInterval(2))
        let importer = WatchCaptureImporter(
            captureStore: captureStore,
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 2 }
        )

        let existing = captureStore.sessionDirectory(
            startedAt: startedAtDate,
            sessionId: sessionId,
            recordingsRoot: recordingsRoot
        )
        let existingAudio = captureStore.audioURL(sessionDirectory: existing, chunkIndex: 0)
        try FileManager.default.createDirectory(
            at: existingAudio.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0xA1, 0xA2]).write(to: existingAudio)
        try captureStore.writeManifest(
            SessionManifest(
                schemaVersion: AIWatchingSchema.externalManifestVersion,
                sessionId: sessionId,
                source: .watch,
                startedAt: startedAt,
                endedAt: endedAt,
                chunks: [
                    AudioChunk(
                        file: "audio/chunk_0000.m4a",
                        index: 0,
                        startOffsetSec: 0,
                        durationSec: 2,
                        startedAt: startedAt
                    )
                ]
            ),
            to: existing
        )
        try captureStore.writeStatus(SessionStatus(state: .complete), to: existing)

        let stagingRoot = root.appendingPathComponent("staging", isDirectory: true)
        let staging = importer.stagingSessionRoot(stagingRoot, sessionId: sessionId)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let stagingAudio = staging.appendingPathComponent("audio.m4a")
        try Data([0xB1, 0xB2]).write(to: stagingAudio)
        let metadata = WatchRecordingProbeMetadata(
            sessionId: sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSec: 2,
            fileName: "audio.m4a"
        )
        let stagingMetadata = importer.metadataFileURL(for: staging)
        try importer.writeMetadata(metadata, to: stagingMetadata)

        let existingManifest = try Data(
            contentsOf: existing.appendingPathComponent(AIWatchingSchema.manifestFileName)
        )
        let existingStatus = try Data(
            contentsOf: existing.appendingPathComponent(AIWatchingSchema.statusFileName)
        )
        let existingAudioBytes = try Data(contentsOf: existingAudio)
        let stagingMetadataBytes = try Data(contentsOf: stagingMetadata)
        let stagingAudioBytes = try Data(contentsOf: stagingAudio)

        XCTAssertThrowsError(try importer.importSession(from: staging)) { error in
            XCTAssertEqual(error as? WatchCaptureImportError, .existingSessionConflict)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        if FileManager.default.fileExists(atPath: staging.path) {
            XCTAssertEqual(try Data(contentsOf: stagingMetadata), stagingMetadataBytes)
            XCTAssertEqual(try Data(contentsOf: stagingAudio), stagingAudioBytes)
        }
        XCTAssertEqual(
            try Data(contentsOf: existing.appendingPathComponent(AIWatchingSchema.manifestFileName)),
            existingManifest
        )
        XCTAssertEqual(
            try Data(contentsOf: existing.appendingPathComponent(AIWatchingSchema.statusFileName)),
            existingStatus
        )
        XCTAssertEqual(try Data(contentsOf: existingAudio), existingAudioBytes)
    }
    // MARK: - STAGE-005B multi-chunk reassembly

    func testChunkedImportAssemblesAllChunksWithOffsetsAndDurations() throws {
        let root = uniqueTempDirectory()
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let durations: [String: TimeInterval] = [
            "chunk_0000.m4a": 300.1,
            "chunk_0001.m4a": 299.8,
            "chunk_0002.m4a": 42.5,
        ]
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { url in durations[url.lastPathComponent] ?? 1.0 }
        )
        let sessionId = UUID().uuidString
        let sessionStart = Date(timeIntervalSinceNow: -900)
        let startedAt = AIWatchingClock.isoString(sessionStart)
        let finalEndedAt = AIWatchingClock.isoString(sessionStart.addingTimeInterval(642.4))

        let staging = importer.stagingSessionRoot(root, sessionId: sessionId)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let offsets: [TimeInterval] = [0, 299.75, 599.9]
        for index in 0..<3 {
            try Data([UInt8(index + 1)]).write(to: importer.chunkAudioFileURL(for: staging, chunkIndex: index))
            let metadata = WatchRecordingProbeMetadata(
                metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
                sessionId: sessionId,
                startedAt: startedAt,
                endedAt: index == 2 ? finalEndedAt : AIWatchingClock.isoString(sessionStart.addingTimeInterval(offsets[index] + 200)),
                durationSec: 10,
                fileName: "aiwatching-watch-chunk-\(index).m4a",
                chunkIndex: index,
                chunkStartOffsetSec: offsets[index],
                chunkCount: index == 2 ? 3 : nil
            )
            try importer.writeMetadata(metadata, to: importer.chunkMetadataFileURL(for: staging, chunkIndex: index))
        }

        let sessionDirectory = try importer.importSession(from: staging)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let manifest = try decodeManifest(at: sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName))
        let status = try decodeStatus(at: sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName))

        XCTAssertEqual(manifest.source, .watch)
        XCTAssertEqual(manifest.sessionId, sessionId)
        XCTAssertEqual(manifest.startedAt, startedAt)
        XCTAssertEqual(manifest.endedAt, finalEndedAt)
        XCTAssertEqual(manifest.chunks.count, 3)
        for index in 0..<3 {
            XCTAssertEqual(manifest.chunks[index].index, index)
            XCTAssertEqual(manifest.chunks[index].file, "audio/chunk_\(String(format: "%04d", index)).m4a")
            XCTAssertEqual(manifest.chunks[index].startOffsetSec, offsets[index])
            XCTAssertEqual(
                manifest.chunks[index].durationSec,
                durations[WatchCaptureImporter.chunkAudioFileName(chunkIndex: index)]
            )
            let audioOutput = sessionDirectory
                .appendingPathComponent(AIWatchingSchema.audioFolderName)
                .appendingPathComponent(WatchCaptureImporter.chunkAudioFileName(chunkIndex: index))
            XCTAssertEqual(try Data(contentsOf: audioOutput), Data([UInt8(index + 1)]))
        }
        XCTAssertEqual(status.state, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testChunkedImportWritesWatchCaptureDiagnosticsFromFinalMetadata() throws {
        let root = uniqueTempDirectory()
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 5.0 }
        )

        let diagnostics = WatchCaptureDiagnostics(
            schemaVersion: 1,
            events: [
                WatchCaptureDiagnosticEvent(
                    sequence: 0,
                    kind: .recordingStarted,
                    occurredAt: AIWatchingClock.isoString(Date(timeIntervalSinceNow: -120)),
                    sessionOffsetSec: 0,
                    controllerState: "recording",
                    shouldResume: nil,
                    lastFinalizedChunkIndex: nil,
                    detail: nil
                )
            ],
            truncated: false
        )

        let sessionId = UUID().uuidString
        let startedAt = AIWatchingClock.isoString(Date(timeIntervalSinceNow: -120))
        let finalEndedAt = AIWatchingClock.isoString()
        let staging = importer.stagingSessionRoot(root, sessionId: sessionId)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        for index in 0..<2 {
            try Data([UInt8(index + 1)]).write(to: importer.chunkAudioFileURL(for: staging, chunkIndex: index))
            let metadata = WatchRecordingProbeMetadata(
                metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
                sessionId: sessionId,
                startedAt: startedAt,
                endedAt: index == 1 ? finalEndedAt : AIWatchingClock.isoString(),
                durationSec: 5,
                fileName: "aiwatching-watch-chunk-\(index).m4a",
                chunkIndex: index,
                chunkStartOffsetSec: TimeInterval(index * 60),
                chunkCount: index == 1 ? 2 : nil,
                captureDiagnostics: index == 1 ? diagnostics : nil
            )
            try importer.writeMetadata(metadata, to: importer.chunkMetadataFileURL(for: staging, chunkIndex: index))
        }

        let sessionDirectory = try importer.importSession(from: staging)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let diagnosticsURL = sessionDirectory.appendingPathComponent(WatchCaptureImporter.watchCaptureDiagnosticsFileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnosticsURL.path))

        let loaded = try JSONDecoder().decode(
            WatchCaptureDiagnostics.self,
            from: Data(contentsOf: diagnosticsURL)
        )
        XCTAssertEqual(loaded, diagnostics)
    }

    func testChunkedImportSkipsWatchCaptureDiagnosticsWithoutMetadataDiagnostics() throws {
        let root = uniqueTempDirectory()
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 5.0 }
        )

        let sessionId = UUID().uuidString
        let startedAt = AIWatchingClock.isoString(Date(timeIntervalSinceNow: -120))
        let staging = importer.stagingSessionRoot(root, sessionId: sessionId)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let metadata = WatchRecordingProbeMetadata(
            metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
            sessionId: sessionId,
            startedAt: startedAt,
            endedAt: AIWatchingClock.isoString(),
            durationSec: 5,
            fileName: "aiwatching-watch-chunk-0.m4a",
            chunkIndex: 0,
            chunkStartOffsetSec: 0,
            chunkCount: 1
        )

        try Data([0x11]).write(to: importer.chunkAudioFileURL(for: staging, chunkIndex: 0))
        try importer.writeMetadata(metadata, to: importer.chunkMetadataFileURL(for: staging, chunkIndex: 0))

        let sessionDirectory = try importer.importSession(from: staging)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: sessionDirectory.appendingPathComponent(WatchCaptureImporter.watchCaptureDiagnosticsFileName).path
        ))
    }

    func testChunkedImportFailsWhenDiagnosticsWriteFailsThenRetriesOnNextRun() throws {
        enum WriteFailure: Error {
            case failed
        }

        let root = uniqueTempDirectory()
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let captureStore = CaptureStore()
        let sessionStartedAt = Date(timeIntervalSince1970: 1_700_000_200)

        let diagnostics = WatchCaptureDiagnostics(
            schemaVersion: 1,
            events: [
                WatchCaptureDiagnosticEvent(
                    sequence: 0,
                    kind: .recordingStarted,
                    occurredAt: AIWatchingClock.isoString(Date(timeIntervalSinceNow: -10)),
                    sessionOffsetSec: 0,
                    controllerState: "recording",
                    shouldResume: nil,
                    lastFinalizedChunkIndex: nil,
                    detail: nil
                ),
            ],
            truncated: false
        )

        let sessionId = UUID().uuidString
        let startedAt = AIWatchingClock.isoString(sessionStartedAt)
        let endedAt = AIWatchingClock.isoString()
        let staging = root.appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data([0x11]).write(to: staging.appendingPathComponent(WatchCaptureImporter.chunkAudioFileName(chunkIndex: 0)))
        let metadata = WatchRecordingProbeMetadata(
            metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
            sessionId: sessionId,
            startedAt: startedAt,
            endedAt: endedAt,
            durationSec: 5,
            fileName: "aiwatching-watch-chunk-0.m4a",
            chunkIndex: 0,
            chunkStartOffsetSec: 0,
            chunkCount: 1,
            captureDiagnostics: diagnostics
        )
        let failingImporter = WatchCaptureImporter(
            writeDiagnosticsFile: { _, _ in throw WriteFailure.failed },
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 5.0 }
        )
        try failingImporter.writeMetadata(metadata, to: failingImporter.chunkMetadataFileURL(for: staging, chunkIndex: 0))
        let plannedSessionDirectory = captureStore.sessionDirectory(
            startedAt: sessionStartedAt,
            sessionId: sessionId,
            recordingsRoot: recordingsRoot
        )

        XCTAssertThrowsError(try failingImporter.importSession(from: staging))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))

        let statusURL = plannedSessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName)
        if FileManager.default.fileExists(atPath: statusURL.path) {
            XCTAssertNotEqual((try decodeStatus(at: statusURL)).state, .complete)
        }

        let retryImporter = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 5.0 }
        )
        let sessionDirectory = try retryImporter.importSession(from: staging)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let status = try decodeStatus(at: sessionDirectory.appendingPathComponent(AIWatchingSchema.statusFileName))
        let diagnosticsURL = sessionDirectory.appendingPathComponent(WatchCaptureImporter.watchCaptureDiagnosticsFileName)
        XCTAssertEqual(status.state, .complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: diagnosticsURL.path))
        let loaded = try JSONDecoder().decode(
            WatchCaptureDiagnostics.self,
            from: Data(contentsOf: diagnosticsURL)
        )
        XCTAssertEqual(loaded, diagnostics)
    }

    func testExistingCompleteSessionRepairsMissingDiagnosticsAndDetectsConflicts() throws {
        let root = uniqueTempDirectory()
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let sessionStore = CaptureStore()
        let sessionId = UUID().uuidString
        let startedAt = Date(timeIntervalSinceNow: -180)

        let completeSession = sessionStore.sessionDirectory(
            startedAt: startedAt,
            sessionId: sessionId,
            recordingsRoot: recordingsRoot
        )
        try FileManager.default.createDirectory(at: completeSession, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: completeSession.appendingPathComponent(AIWatchingSchema.audioFolderName, isDirectory: true),
            withIntermediateDirectories: true
        )
        let manifestAudio = completeSession.appendingPathComponent(AIWatchingSchema.audioFolderName)
            .appendingPathComponent("chunk_0000.m4a")
        try Data([0xAA]).write(to: manifestAudio)
        let manifest = SessionManifest(
            sessionId: sessionId,
            source: .watch,
            startedAt: AIWatchingClock.isoString(startedAt),
            endedAt: AIWatchingClock.isoString(),
            chunks: [
                AudioChunk(
                    file: "audio/chunk_0000.m4a",
                    index: 0,
                    startOffsetSec: 0,
                    durationSec: 5
                )
            ]
        )
        try sessionStore.writeManifest(manifest, to: completeSession)
        try sessionStore.writeStatus(
            SessionStatus(state: .complete),
            to: completeSession
        )

        let diagnosticsA = WatchCaptureDiagnostics(
            schemaVersion: 1,
            events: [
                WatchCaptureDiagnosticEvent(
                    sequence: 0,
                    kind: .recordingStarted,
                    occurredAt: AIWatchingClock.isoString(startedAt),
                    sessionOffsetSec: 0,
                    controllerState: "recording",
                    shouldResume: nil,
                    lastFinalizedChunkIndex: nil,
                    detail: nil
                )
            ],
            truncated: false
        )

        let diagnosticsB = WatchCaptureDiagnostics(
            schemaVersion: 1,
            events: [
                WatchCaptureDiagnosticEvent(
                    sequence: 0,
                    kind: .interruptionBegan,
                    occurredAt: AIWatchingClock.isoString(startedAt.addingTimeInterval(1)),
                    sessionOffsetSec: 1,
                    controllerState: "interrupted",
                    shouldResume: nil,
                    lastFinalizedChunkIndex: 0,
                    detail: nil
                )
            ],
            truncated: false
        )

        func stagedRoot(with diagnostics: WatchCaptureDiagnostics) -> URL {
            let staging = root.appendingPathComponent("staging", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

            try? Data([0x33]).write(to: staging.appendingPathComponent(WatchCaptureImporter.chunkAudioFileName(chunkIndex: 0)))
            let metadata = WatchRecordingProbeMetadata(
                metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
                sessionId: sessionId,
                startedAt: AIWatchingClock.isoString(startedAt),
                endedAt: AIWatchingClock.isoString(),
                durationSec: 5,
                fileName: "aiwatching-watch-chunk-0.m4a",
                chunkIndex: 0,
                chunkStartOffsetSec: 0,
                chunkCount: 1,
                captureDiagnostics: diagnostics
            )
            let importer = WatchCaptureImporter(
                recordingsRootProvider: { recordingsRoot },
                resolveDuration: { _ in 5.0 }
            )
            try? importer.writeMetadata(metadata, to: importer.chunkMetadataFileURL(for: staging, chunkIndex: 0))
            return staging
        }

        let importer = WatchCaptureImporter(recordingsRootProvider: { recordingsRoot }, resolveDuration: { _ in 5.0 })

        let firstStaging = stagedRoot(with: diagnosticsA)
        let repaired = try importer.importSession(from: firstStaging)
        defer { try? FileManager.default.removeItem(at: repaired) }
        XCTAssertEqual(repaired, completeSession)
        let repairedDiagnosticsURL = completeSession.appendingPathComponent(WatchCaptureImporter.watchCaptureDiagnosticsFileName)
        let repairedDiagnostics = try JSONDecoder().decode(
            WatchCaptureDiagnostics.self,
            from: Data(contentsOf: repairedDiagnosticsURL)
        )
        XCTAssertEqual(repairedDiagnostics, diagnosticsA)

        let secondStaging = stagedRoot(with: diagnosticsA)
        let unchanged = try importer.importSession(from: secondStaging)
        XCTAssertEqual(unchanged, completeSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondStaging.path))

        let conflicted = stagedRoot(with: diagnosticsB)
        XCTAssertThrowsError(try importer.importSession(from: conflicted))
        XCTAssertTrue(FileManager.default.fileExists(atPath: conflicted.path))
        XCTAssertNotNil(try? JSONDecoder().decode(
            SessionManifest.self,
            from: Data(contentsOf: repaired.appendingPathComponent(AIWatchingSchema.manifestFileName))
        ))
        XCTAssertEqual(repaired, completeSession)
    }

    func testChunkedImportWaitsForMissingChunkAndCompletesAfterArrival() throws {
        let root = uniqueTempDirectory()
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 5.0 }
        )
        let sessionId = UUID().uuidString
        let startedAt = AIWatchingClock.isoString(Date(timeIntervalSinceNow: -120))
        let endedAt = AIWatchingClock.isoString()
        let staging = importer.stagingSessionRoot(root, sessionId: sessionId)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        func stageChunk(_ index: Int, isFinal: Bool, offset: TimeInterval) throws {
            try Data([UInt8(index + 10)]).write(to: importer.chunkAudioFileURL(for: staging, chunkIndex: index))
            let metadata = WatchRecordingProbeMetadata(
                metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
                sessionId: sessionId,
                startedAt: startedAt,
                endedAt: endedAt,
                durationSec: 5,
                fileName: "aiwatching-watch-chunk-\(index).m4a",
                chunkIndex: index,
                chunkStartOffsetSec: offset,
                chunkCount: isFinal ? index + 1 : nil
            )
            try importer.writeMetadata(metadata, to: importer.chunkMetadataFileURL(for: staging, chunkIndex: index))
        }

        // Out-of-order arrival: final chunk (index 2) first, then chunk 0. Chunk 1 missing.
        try stageChunk(2, isFinal: true, offset: 20)
        try stageChunk(0, isFinal: false, offset: 0)

        XCTAssertThrowsError(try importer.importSession(from: staging)) { error in
            XCTAssertEqual(error as? WatchCaptureImportError, .sessionNotReady)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))

        // A pending-scan pass must not treat the waiting session as a failure.
        let failures = importer.importAllPendingWatchCaptureSessions(at: root)
        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))

        // The missing middle chunk arrives; the session becomes importable.
        try stageChunk(1, isFinal: false, offset: 10)
        let sessionDirectory = try importer.importSession(from: staging)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        let manifest = try decodeManifest(at: sessionDirectory.appendingPathComponent(AIWatchingSchema.manifestFileName))
        XCTAssertEqual(manifest.chunks.map(\.index), [0, 1, 2])
        XCTAssertEqual(manifest.chunks.map(\.startOffsetSec), [0, 10, 20])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testChunkedImportWaitsWhenFinalChunkHasNotArrived() throws {
        let root = uniqueTempDirectory()
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { root.appendingPathComponent("recordings", isDirectory: true) },
            resolveDuration: { _ in 5.0 }
        )
        let sessionId = UUID().uuidString
        let startedAt = AIWatchingClock.isoString(Date(timeIntervalSinceNow: -60))
        let staging = importer.stagingSessionRoot(root, sessionId: sessionId)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        for index in 0..<2 {
            try Data([0x01]).write(to: importer.chunkAudioFileURL(for: staging, chunkIndex: index))
            let metadata = WatchRecordingProbeMetadata(
                metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
                sessionId: sessionId,
                startedAt: startedAt,
                endedAt: AIWatchingClock.isoString(),
                durationSec: 5,
                fileName: "aiwatching-watch-chunk-\(index).m4a",
                chunkIndex: index,
                chunkStartOffsetSec: TimeInterval(index * 10)
            )
            try importer.writeMetadata(metadata, to: importer.chunkMetadataFileURL(for: staging, chunkIndex: index))
        }

        XCTAssertThrowsError(try importer.importSession(from: staging)) { error in
            XCTAssertEqual(error as? WatchCaptureImportError, .sessionNotReady)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }

    func testChunkedImportRejectsNonMonotonicOffsets() throws {
        let root = uniqueTempDirectory()
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { root.appendingPathComponent("recordings", isDirectory: true) },
            resolveDuration: { _ in 5.0 }
        )
        let sessionId = UUID().uuidString
        let startedAt = AIWatchingClock.isoString(Date(timeIntervalSinceNow: -60))
        let staging = importer.stagingSessionRoot(root, sessionId: sessionId)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let offsets: [TimeInterval] = [10, 5]
        for index in 0..<2 {
            try Data([0x01]).write(to: importer.chunkAudioFileURL(for: staging, chunkIndex: index))
            let metadata = WatchRecordingProbeMetadata(
                metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
                sessionId: sessionId,
                startedAt: startedAt,
                endedAt: AIWatchingClock.isoString(),
                durationSec: 5,
                fileName: "aiwatching-watch-chunk-\(index).m4a",
                chunkIndex: index,
                chunkStartOffsetSec: offsets[index],
                chunkCount: index == 1 ? 2 : nil
            )
            try importer.writeMetadata(metadata, to: importer.chunkMetadataFileURL(for: staging, chunkIndex: index))
        }

        XCTAssertThrowsError(try importer.importSession(from: staging)) { error in
            XCTAssertEqual(error as? WatchCaptureImportError, .invalidTransferMetadata)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
    }

    func testChunkedImportDeduplicatesAfterCompleteSession() throws {
        let root = uniqueTempDirectory()
        let recordingsRoot = root.appendingPathComponent("recordings", isDirectory: true)
        let importer = WatchCaptureImporter(
            recordingsRootProvider: { recordingsRoot },
            resolveDuration: { _ in 3.0 }
        )
        let sessionId = UUID().uuidString
        let startedAt = AIWatchingClock.isoString(Date(timeIntervalSinceNow: -60))
        let endedAt = AIWatchingClock.isoString()

        func stage(_ payload: UInt8) throws -> URL {
            let staging = importer.stagingSessionRoot(root, sessionId: sessionId)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for index in 0..<2 {
                try Data([payload]).write(to: importer.chunkAudioFileURL(for: staging, chunkIndex: index))
                let metadata = WatchRecordingProbeMetadata(
                    metadataVersion: WatchRecordingProbeMetadata.chunkedVersion,
                    sessionId: sessionId,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    durationSec: 3,
                    fileName: "aiwatching-watch-chunk-\(index).m4a",
                    chunkIndex: index,
                    chunkStartOffsetSec: TimeInterval(index * 10),
                    chunkCount: index == 1 ? 2 : nil
                )
                try importer.writeMetadata(metadata, to: importer.chunkMetadataFileURL(for: staging, chunkIndex: index))
            }
            return staging
        }

        let firstSession = try importer.importSession(from: try stage(0xAA))
        defer { try? FileManager.default.removeItem(at: firstSession) }

        // Full session replay after completion resolves to the existing session
        // without touching its audio.
        let replayStaging = try stage(0xBB)
        let secondSession = try importer.importSession(from: replayStaging)
        XCTAssertEqual(firstSession, secondSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: replayStaging.path))
        let chunk0 = firstSession
            .appendingPathComponent(AIWatchingSchema.audioFolderName)
            .appendingPathComponent(WatchCaptureImporter.chunkAudioFileName(chunkIndex: 0))
        XCTAssertEqual(try Data(contentsOf: chunk0), Data([0xAA]))
    }
}

private extension WatchCaptureImporterTests {
    func uniqueTempDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIWatchingWatchImport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func decodeManifest(at url: URL) throws -> SessionManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionManifest.self, from: data)
    }

    func decodeStatus(at url: URL) throws -> SessionStatus {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SessionStatus.self, from: data)
    }
}

private extension URL {
    func removeIfExists() {
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(at: self)
        }
    }

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

private extension String {
    func removePath(_ root: URL) {
        let path = root.appendingPathComponent(self, isDirectory: true)
        try? FileManager.default.removeItem(at: path)
    }
}
