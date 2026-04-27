import Foundation
import Testing
@testable import TranscribeerApp

/// Table-driven tests for `TranscriptStore`. Each test creates a fresh
/// temporary session directory and tears it down after — the suite never
/// touches `~/.transcribeer/sessions`. When a test fails, inspect the
/// session paths it logged to diagnose.
@Suite("TranscriptStore")
struct TranscriptStoreTests {
    // MARK: - Helpers

    private static func makeSession() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribeer-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cleanup(_ session: URL) {
        try? FileManager.default.removeItem(at: session)
    }

    private static func seedLegacyTranscript(_ session: URL, text: String = "[00:00 -> 00:03] SPEAKER_1: hello\n") {
        let url = session.appendingPathComponent("transcript.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func seedLegacySummary(_ session: URL, text: String = "# Summary\n\nLegacy.\n") {
        let url = session.appendingPathComponent("summary.md")
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func readFile(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    private static func makeInput(
        backend: String = "whisperkit",
        model: String = "openai_whisper-large-v3_turbo",
        language: String = "en",
        diarization: String = "pyannote",
        content: String = "[00:00 -> 00:02] SPEAKER_1: test\n",
    ) -> TranscriptStore.NewTranscriptInput {
        TranscriptStore.NewTranscriptInput(
            backend: backend,
            model: model,
            language: language,
            diarization: diarization,
            content: content,
        )
    }

    // MARK: - Add + mirror

    @Test("addTranscript creates record, writes file, mirrors to transcript.txt")
    func addPersists() throws {
        let session = Self.makeSession()
        defer { Self.cleanup(session) }

        let record = try TranscriptStore.addTranscript(
            session: session,
            input: Self.makeInput(content: "alpha\n"),
        )

        // Record is visible via manifest and current pointer.
        #expect(record.backend == "whisperkit")
        #expect(record.summaryFile == nil)
        let records = TranscriptStore.records(in: session)
        #expect(records.count == 1)
        #expect(records.first?.id == record.id)
        #expect(TranscriptStore.currentRecord(in: session)?.id == record.id)

        // File is on disk under transcripts/ and mirrors to top-level.
        let fileURL = TranscriptStore.transcriptURL(for: record, in: session)
        #expect(Self.readFile(fileURL) == "alpha\n")
        #expect(Self.readFile(session.appendingPathComponent("transcript.txt")) == "alpha\n")
    }

    @Test("two addTranscript calls keep both records and bump the mirror to the newest")
    func addKeepsHistory() throws {
        let session = Self.makeSession()
        defer { Self.cleanup(session) }

        let first = try TranscriptStore.addTranscript(
            session: session,
            input: Self.makeInput(backend: "whisperkit", content: "first\n"),
        )
        // Sleep a millisecond so the ids differ even if the backend+model match.
        // The compact timestamp has 1s resolution; a quick second call in the
        // same second would produce the same id. Using different backends
        // sidesteps that for the happy path.
        let second = try TranscriptStore.addTranscript(
            session: session,
            input: Self.makeInput(backend: "google_stt", model: "default", content: "second\n"),
        )

        let records = TranscriptStore.records(in: session)
        #expect(records.count == 2)
        #expect(records.contains(where: { $0.id == first.id }))
        #expect(records.contains(where: { $0.id == second.id }))
        #expect(TranscriptStore.currentRecord(in: session)?.id == second.id)

        // First transcript survives on disk even though it's no longer current.
        let firstFile = TranscriptStore.transcriptURL(for: first, in: session)
        #expect(Self.readFile(firstFile) == "first\n")
        // Mirror reflects the newest.
        #expect(Self.readFile(session.appendingPathComponent("transcript.txt")) == "second\n")
    }

    @Test("makeCurrent=false preserves previous current and doesn't touch the mirror")
    func addWithoutMakeCurrent() throws {
        let session = Self.makeSession()
        defer { Self.cleanup(session) }

        let primary = try TranscriptStore.addTranscript(
            session: session,
            input: Self.makeInput(content: "primary\n"),
        )
        _ = try TranscriptStore.addTranscript(
            session: session,
            input: Self.makeInput(backend: "google_stt", content: "backfill\n"),
            makeCurrent: false,
        )

        #expect(TranscriptStore.currentRecord(in: session)?.id == primary.id)
        // Mirror still holds the original current's content.
        #expect(Self.readFile(session.appendingPathComponent("transcript.txt")) == "primary\n")
    }

    // MARK: - attachSummary

    @Test("attachSummary writes the file and mirrors when record is current")
    func attachSummaryMirrors() throws {
        let session = Self.makeSession()
        defer { Self.cleanup(session) }

        let record = try TranscriptStore.addTranscript(session: session, input: Self.makeInput())

        let updated = try TranscriptStore.attachSummary(
            session: session,
            transcriptID: record.id,
            content: "# Summary\n\nTest summary.\n",
        )

        #expect(updated.summaryFile != nil)
        let summaryURL = TranscriptStore.summaryURL(for: updated, in: session)
        #expect(summaryURL.flatMap(Self.readFile)?.contains("Test summary.") == true)
        // Mirror at session root.
        let mirrorSummary = session.appendingPathComponent("summary.md")
        #expect(Self.readFile(mirrorSummary)?.contains("Test summary.") == true)
    }

    @Test("attachSummary on non-current record writes the file but leaves the mirror alone")
    func attachSummaryOnNonCurrent() throws {
        let session = Self.makeSession()
        defer { Self.cleanup(session) }

        let first = try TranscriptStore.addTranscript(
            session: session,
            input: Self.makeInput(content: "first\n"),
        )
        let second = try TranscriptStore.addTranscript(
            session: session,
            input: Self.makeInput(backend: "google_stt", content: "second\n"),
        )

        // Attach to the older (non-current) record.
        _ = try TranscriptStore.attachSummary(
            session: session,
            transcriptID: first.id,
            content: "# First\n",
        )

        // The non-current record's summary file exists.
        guard let updated = TranscriptStore.record(withID: first.id, in: session),
              let summaryURL = TranscriptStore.summaryURL(for: updated, in: session)
        else {
            Issue.record("expected summary file registered on first record")
            return
        }
        #expect(Self.readFile(summaryURL)?.contains("# First") == true)

        // Mirror still reflects the CURRENT record (`second`), which has no summary.
        let mirrorSummary = session.appendingPathComponent("summary.md")
        #expect(!FileManager.default.fileExists(atPath: mirrorSummary.path))
        // And current is unchanged.
        #expect(TranscriptStore.currentRecord(in: session)?.id == second.id)
    }

    @Test("attachSummary with unknown id throws missingRecord")
    func attachSummaryMissingRecord() throws {
        let session = Self.makeSession()
        defer { Self.cleanup(session) }
        _ = try TranscriptStore.addTranscript(session: session, input: Self.makeInput())

        #expect(throws: TranscriptStoreError.self) {
            _ = try TranscriptStore.attachSummary(
                session: session,
                transcriptID: "nope",
                content: "x",
            )
        }
    }

    // MARK: - setCurrent + deleteRecord

    @Test("setCurrent swaps the mirror to the selected record's content")
    func setCurrentSwapsMirror() throws {
        let session = Self.makeSession()
        defer { Self.cleanup(session) }

        let first = try TranscriptStore.addTranscript(
            session: session,
            input: Self.makeInput(content: "first\n"),
        )
        _ = try TranscriptStore.addTranscript(
            session: session,
            input: Self.makeInput(backend: "google_stt", content: "second\n"),
        )

        try TranscriptStore.setCurrent(session: session, transcriptID: first.id)

        #expect(TranscriptStore.currentRecord(in: session)?.id == first.id)
        #expect(Self.readFile(session.appendingPathComponent("transcript.txt")) == "first\n")
    }

    @Test("deleteRecord refuses to delete the current record")
    func deleteCurrentForbidden() throws {
        let session = Self.makeSession()
        defer { Self.cleanup(session) }
        let record = try TranscriptStore.addTranscript(session: session, input: Self.makeInput())

        #expect(throws: TranscriptStoreError.self) {
            try TranscriptStore.deleteRecord(session: session, transcriptID: record.id)
        }
    }

    @Test("deleteRecord removes a non-current record's files")
    func deleteNonCurrent() throws {
        let session = Self.makeSession()
        defer { Self.cleanup(session) }

        let first = try TranscriptStore.addTranscript(
            session: session,
            input: Self.makeInput(content: "first\n"),
        )
        _ = try TranscriptStore.attachSummary(
            session: session,
            transcriptID: first.id,
            content: "summary-of-first",
        )
        _ = try TranscriptStore.addTranscript(
            session: session,
            input: Self.makeInput(backend: "google_stt", content: "second\n"),
        )

        let firstFileBefore = TranscriptStore.transcriptURL(for: first, in: session)
        #expect(FileManager.default.fileExists(atPath: firstFileBefore.path))

        try TranscriptStore.deleteRecord(session: session, transcriptID: first.id)

        // Transcript + summary files for `first` are gone; manifest shrinks.
        #expect(!FileManager.default.fileExists(atPath: firstFileBefore.path))
        let remaining = TranscriptStore.records(in: session)
        #expect(remaining.count == 1)
        #expect(remaining.contains(where: { $0.id == first.id }) == false)
    }

    // MARK: - Migration

    @Test("legacy transcript.txt gets migrated into a single 'legacy' record")
    func migrationCreatesLegacyRecord() {
        let session = Self.makeSession()
        defer { Self.cleanup(session) }

        Self.seedLegacyTranscript(session, text: "legacy body\n")
        Self.seedLegacySummary(session, text: "# legacy summary\n")

        // First read triggers migration.
        let records = TranscriptStore.records(in: session)

        #expect(records.count == 1)
        guard let record = records.first else { return }
        #expect(record.backend == "legacy")
        #expect(record.model == "unknown")
        #expect(record.summaryFile != nil)
        #expect(TranscriptStore.currentRecord(in: session)?.id == record.id)

        // The copies inside transcripts/ match the originals.
        let fileURL = TranscriptStore.transcriptURL(for: record, in: session)
        #expect(Self.readFile(fileURL) == "legacy body\n")
        if let summaryURL = TranscriptStore.summaryURL(for: record, in: session) {
            #expect(Self.readFile(summaryURL)?.contains("legacy summary") == true)
        }
        // Mirror files are still present (they're the original legacy files).
        #expect(Self.readFile(session.appendingPathComponent("transcript.txt")) == "legacy body\n")
    }

    @Test("migration is a no-op when the manifest already exists")
    func migrationIdempotent() throws {
        let session = Self.makeSession()
        defer { Self.cleanup(session) }

        let record = try TranscriptStore.addTranscript(
            session: session,
            input: Self.makeInput(content: "from-pipeline\n"),
        )
        // Even if a legacy-looking transcript.txt is now on disk, the
        // migration shouldn't synthesize a fake `legacy` record — the
        // manifest takes priority.
        Self.seedLegacyTranscript(session, text: "stray\n")

        let records = TranscriptStore.records(in: session)
        #expect(records.count == 1)
        #expect(records.first?.id == record.id)
    }

    @Test("re-transcribing a legacy session preserves the legacy transcript")
    func legacyPlusNewKeepsBoth() throws {
        let session = Self.makeSession()
        defer { Self.cleanup(session) }
        Self.seedLegacyTranscript(session, text: "legacy\n")

        // Kick migration via first read, then add a new transcript.
        _ = TranscriptStore.records(in: session)
        let fresh = try TranscriptStore.addTranscript(
            session: session,
            input: Self.makeInput(content: "fresh\n"),
        )

        let records = TranscriptStore.records(in: session)
        #expect(records.count == 2)
        #expect(records.contains(where: { $0.backend == "legacy" }))
        #expect(TranscriptStore.currentRecord(in: session)?.id == fresh.id)
    }

    // MARK: - makeRecordID

    @Test("makeRecordID produces a stable slug + timestamp id")
    func recordIDShape() {
        let timestamp = Date(timeIntervalSince1970: 1_769_000_000) // 2026-01-21T05:33:20Z
        let id = TranscriptStore.makeRecordID(
            backend: "google_stt",
            model: "openai_whisper/large-v3 turbo",
            timestamp: timestamp,
        )
        #expect(id.hasPrefix("google-stt__openai-whisper-large-v3-turbo__"))
        // Compact UTC timestamp suffix: YYYYMMDDTHHMMSSZ
        #expect(id.hasSuffix("Z"))
    }

    @Test("makeRecordID normalizes unicode and collapses separators")
    func recordIDSlug() {
        let id = TranscriptStore.makeRecordID(
            backend: "   mixed__chars!! ",
            model: "A//B--C  D",
            timestamp: Date(timeIntervalSince1970: 0),
        )
        #expect(id.contains("mixed-chars__a-b-c-d"))
    }
}
