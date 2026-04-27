import Foundation
import os.log

/// Session-local storage for multiple transcript runs.
///
/// ## Layout
///
/// ```
/// <session>/
///   transcripts/
///     index.json
///     whisperkit__openai-whisper-large-v3-turbo__20260423T142210Z.txt
///     whisperkit__openai-whisper-large-v3-turbo__20260423T142210Z__summary.md
///     google_stt__default__20260423T150000Z.txt
///     google_stt__default__20260423T150000Z__summary.md
///   transcript.txt   ← mirror of the current record's transcript
///   summary.md       ← mirror of the current record's summary (if any)
/// ```
///
/// The top-level `transcript.txt` and `summary.md` are rewritten from
/// whichever record is marked `current`. Legacy tooling that reads those
/// files keeps working without knowing the manifest exists.
///
/// ## Migration
///
/// The first time a store is consulted for a session that has
/// `transcript.txt` but no `transcripts/index.json`, a synthetic `legacy`
/// record is created from the existing files. This is one-way: once a
/// session has a manifest, legacy fields are never synthesized again.
///
/// ## Concurrency
///
/// All methods are synchronous and file-scoped. Expected call patterns
/// serialize access per session (one pipeline run at a time per session);
/// we don't take a global lock. If two processes race on the same session
/// the JSON-atomic write means the last writer wins for the manifest, but
/// transcript files themselves are write-once under unique filenames so
/// they never collide.
enum TranscriptStore {
    private static let logger = Logger(
        subsystem: "com.transcribeer",
        category: "transcript-store",
    )
    private static let transcriptsDirName = "transcripts"
    private static let manifestFileName = "index.json"
    private static let legacyRecordID = "legacy"

    // MARK: - Read

    /// Return all records, applying one-time migration for legacy sessions.
    ///
    /// Throwing flavor: returns an empty manifest on any I/O failure.
    /// Callers that need to distinguish "no records" from "read error"
    /// should hit `loadManifest(_:)` directly.
    static func records(in session: URL) -> [TranscriptRecord] {
        manifest(for: session)?.records ?? []
    }

    /// The record `transcript.txt` and `summary.md` currently mirror.
    static func currentRecord(in session: URL) -> TranscriptRecord? {
        guard let mf = manifest(for: session), let id = mf.currentID else { return nil }
        return mf.records.first { $0.id == id }
    }

    /// Look up a specific record by id.
    static func record(withID id: String, in session: URL) -> TranscriptRecord? {
        manifest(for: session)?.records.first { $0.id == id }
    }

    /// Load the manifest, migrating legacy state if needed. Returns nil on
    /// persistent failure (will be logged) or when the session is truly
    /// empty (no transcript.txt, no manifest).
    static func manifest(for session: URL) -> TranscriptManifest? {
        migrateLegacyIfNeeded(session: session)
        return loadManifest(at: manifestURL(session))
    }

    /// Return an in-memory manifest guaranteed to reflect any legacy state,
    /// falling back to an empty manifest for brand-new sessions. Used by
    /// write paths so they never miss a pre-existing legacy transcript.
    private static func currentManifest(for session: URL) -> TranscriptManifest {
        migrateLegacyIfNeeded(session: session)
        return loadManifest(at: manifestURL(session))
            ?? TranscriptManifest(records: [], currentID: nil)
    }

    // MARK: - Write

    /// Bundle of metadata for a new transcript run. Passed to
    /// `addTranscript(session:input:makeCurrent:)` so the store's signature
    /// doesn't grow with every new field we end up tracking.
    struct NewTranscriptInput: Sendable {
        let backend: String
        let model: String
        let language: String
        let diarization: String
        let content: String
    }

    /// Register a new transcript produced by the pipeline.
    ///
    /// - Parameters:
    ///   - session: Session directory URL.
    ///   - input: Run metadata + formatted transcript content (the output
    ///     of `TranscriptFormatter.format`).
    ///   - makeCurrent: When true, this record becomes the new `current`
    ///     and the top-level mirror files are rewritten. The UI/CLI will
    ///     almost always want `true`; passing `false` is only useful for
    ///     background backfills that shouldn't replace the user's active
    ///     view.
    /// - Returns: The persisted record, including its allocated id.
    @discardableResult
    static func addTranscript(
        session: URL,
        input: NewTranscriptInput,
        makeCurrent: Bool = true,
    ) throws -> TranscriptRecord {
        try ensureTranscriptsDir(session)

        let createdAt = Date()
        let id = makeRecordID(backend: input.backend, model: input.model, timestamp: createdAt)
        let transcriptFile = "\(id).txt"

        let record = TranscriptRecord(
            id: id,
            backend: input.backend,
            model: input.model,
            language: input.language,
            diarization: input.diarization,
            createdAt: createdAt,
            transcriptFile: transcriptFile,
            summaryFile: nil,
        )

        let transcriptURL = transcriptsDir(session).appendingPathComponent(transcriptFile)
        try input.content.write(to: transcriptURL, atomically: true, encoding: .utf8)

        var mf = currentManifest(for: session)
        mf.records.append(record)
        if makeCurrent { mf.currentID = id }
        try saveManifest(mf, at: manifestURL(session))

        if makeCurrent {
            mirrorCurrent(session: session, manifest: mf)
        }
        return record
    }

    /// Attach a summary to an existing transcript record and (optionally)
    /// refresh the top-level `summary.md` mirror if that record is current.
    ///
    /// Throws if `transcriptID` isn't in the manifest. The summary file is
    /// written atomically before the manifest is updated, so a partial
    /// write leaves a stray file but doesn't corrupt the manifest.
    @discardableResult
    static func attachSummary(
        session: URL,
        transcriptID: String,
        content: String,
    ) throws -> TranscriptRecord {
        var mf = currentManifest(for: session)
        guard let idx = mf.records.firstIndex(where: { $0.id == transcriptID }) else {
            throw TranscriptStoreError.missingRecord(transcriptID)
        }

        try ensureTranscriptsDir(session)
        let summaryFile = "\(transcriptID)__summary.md"
        let summaryURL = transcriptsDir(session).appendingPathComponent(summaryFile)
        try content.write(to: summaryURL, atomically: true, encoding: .utf8)

        mf.records[idx].summaryFile = summaryFile
        try saveManifest(mf, at: manifestURL(session))

        if mf.currentID == transcriptID {
            mirrorCurrent(session: session, manifest: mf)
        }
        return mf.records[idx]
    }

    /// Swap the `current` pointer and rewrite the top-level mirror files.
    /// Used by the UI's "make current" action in the transcript picker.
    static func setCurrent(session: URL, transcriptID: String) throws {
        var mf = currentManifest(for: session)
        guard mf.records.contains(where: { $0.id == transcriptID }) else {
            throw TranscriptStoreError.missingRecord(transcriptID)
        }
        mf.currentID = transcriptID
        try saveManifest(mf, at: manifestURL(session))
        mirrorCurrent(session: session, manifest: mf)
    }

    /// Remove a record and its associated files. Refuses to delete the
    /// record that's currently mirrored — caller must `setCurrent` first.
    static func deleteRecord(session: URL, transcriptID: String) throws {
        var mf = currentManifest(for: session)
        guard mf.currentID != transcriptID else {
            throw TranscriptStoreError.deleteCurrent
        }
        guard let idx = mf.records.firstIndex(where: { $0.id == transcriptID }) else {
            throw TranscriptStoreError.missingRecord(transcriptID)
        }
        let record = mf.records[idx]

        let dir = transcriptsDir(session)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(record.transcriptFile))
        if let summary = record.summaryFile {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(summary))
        }

        mf.records.remove(at: idx)
        try saveManifest(mf, at: manifestURL(session))
    }

    // MARK: - Content lookup

    /// Absolute URL of a record's transcript file on disk.
    static func transcriptURL(for record: TranscriptRecord, in session: URL) -> URL {
        transcriptsDir(session).appendingPathComponent(record.transcriptFile)
    }

    /// Absolute URL of a record's summary file, if one exists.
    static func summaryURL(for record: TranscriptRecord, in session: URL) -> URL? {
        record.summaryFile.map { transcriptsDir(session).appendingPathComponent($0) }
    }

    // MARK: - Migration

    /// Convert a legacy single-file session into a manifest-backed one.
    ///
    /// No-op in all these cases:
    /// - manifest already exists (normal read path)
    /// - neither `transcript.txt` nor manifest exists (untouched session)
    ///
    /// When legacy state is detected, copies `transcript.txt` into
    /// `transcripts/legacy.txt` (and `summary.md` similarly if present),
    /// then writes a manifest with a single record pointing at those
    /// copies. The originals stay in place as the mirror files, so every
    /// consumer of `transcript.txt` / `summary.md` keeps working
    /// unchanged.
    static func migrateLegacyIfNeeded(session: URL) {
        let manifestFile = manifestURL(session)
        guard !FileManager.default.fileExists(atPath: manifestFile.path) else { return }

        let legacyTranscript = session.appendingPathComponent("transcript.txt")
        guard FileManager.default.fileExists(atPath: legacyTranscript.path) else { return }

        do {
            try ensureTranscriptsDir(session)
            let transcriptsDir = transcriptsDir(session)
            let legacyTranscriptCopy = transcriptsDir.appendingPathComponent("\(legacyRecordID).txt")
            try FileManager.default.copyItem(at: legacyTranscript, to: legacyTranscriptCopy)

            var summaryFile: String?
            let legacySummary = session.appendingPathComponent("summary.md")
            if FileManager.default.fileExists(atPath: legacySummary.path) {
                let legacySummaryCopy = transcriptsDir.appendingPathComponent("\(legacyRecordID)__summary.md")
                try FileManager.default.copyItem(at: legacySummary, to: legacySummaryCopy)
                summaryFile = "\(legacyRecordID)__summary.md"
            }

            let createdAt = legacyMtime(of: legacyTranscript) ?? Date()
            let language = (SessionManager.readMeta(session)["language"] as? String) ?? "unknown"
            let record = TranscriptRecord(
                id: legacyRecordID,
                backend: "legacy",
                model: "unknown",
                language: language,
                diarization: "unknown",
                createdAt: createdAt,
                transcriptFile: "\(legacyRecordID).txt",
                summaryFile: summaryFile,
            )
            let mf = TranscriptManifest(records: [record], currentID: legacyRecordID)
            try saveManifest(mf, at: manifestFile)

            logger.log("migrated legacy transcript for session \(session.lastPathComponent, privacy: .public)")
        } catch {
            let sessionName = session.lastPathComponent
            let description = error.localizedDescription
            logger.error(
                """
                legacy migration failed for \(sessionName, privacy: .public): \
                \(description, privacy: .public)
                """,
            )
        }
    }

    // MARK: - Mirror

    /// Rewrite `transcript.txt` and `summary.md` at the session root to
    /// match whichever record is marked `current` in the manifest.
    ///
    /// Idempotent — a no-op when `current` points at a record whose files
    /// are already reflected in the mirrors. Best-effort on individual
    /// file operations: a missing summary file (record has `summaryFile`
    /// set but the file is gone) doesn't block the transcript mirror.
    private static func mirrorCurrent(session: URL, manifest: TranscriptManifest) {
        guard let id = manifest.currentID,
              let record = manifest.records.first(where: { $0.id == id })
        else { return }

        let transcriptsDir = transcriptsDir(session)
        let mirrorTranscript = session.appendingPathComponent("transcript.txt")
        let mirrorSummary = session.appendingPathComponent("summary.md")

        let source = transcriptsDir.appendingPathComponent(record.transcriptFile)
        if let content = try? String(contentsOf: source, encoding: .utf8) {
            try? content.write(to: mirrorTranscript, atomically: true, encoding: .utf8)
        }

        if let summaryFile = record.summaryFile {
            let summarySource = transcriptsDir.appendingPathComponent(summaryFile)
            if let content = try? String(contentsOf: summarySource, encoding: .utf8) {
                try? content.write(to: mirrorSummary, atomically: true, encoding: .utf8)
            }
        } else if FileManager.default.fileExists(atPath: mirrorSummary.path) {
            // Current record has no summary; clear the stale mirror so the
            // summary pane doesn't show a previous record's summary.
            try? FileManager.default.removeItem(at: mirrorSummary)
        }
    }

    // MARK: - Internals

    private static func transcriptsDir(_ session: URL) -> URL {
        session.appendingPathComponent(transcriptsDirName, isDirectory: true)
    }

    private static func manifestURL(_ session: URL) -> URL {
        transcriptsDir(session).appendingPathComponent(manifestFileName)
    }

    private static func ensureTranscriptsDir(_ session: URL) throws {
        try FileManager.default.createDirectory(
            at: transcriptsDir(session),
            withIntermediateDirectories: true,
        )
    }

    private static func loadManifest(at url: URL) -> TranscriptManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(TranscriptManifest.self, from: data)
        } catch {
            logger.error("manifest decode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func saveManifest(_ manifest: TranscriptManifest, at url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private static func legacyMtime(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Build a filesystem-safe, readable identifier from the run metadata.
    ///
    /// Example: `("google_stt", "default", 2026-04-23T15:00:00Z)` →
    /// `"google_stt__default__20260423T150000Z"`.
    static func makeRecordID(backend: String, model: String, timestamp: Date) -> String {
        let slugBackend = slugify(backend)
        let slugModel = slugify(model)
        let stamp = Self.compactTimestampFormatter.string(from: timestamp)
        return "\(slugBackend)__\(slugModel)__\(stamp)"
    }

    /// Lowercased, alphanumeric + hyphen. Collapses runs of separators so
    /// `"openai_whisper/large-v3 turbo"` → `"openai-whisper-large-v3-turbo"`.
    private static func slugify(_ input: String) -> String {
        var out = ""
        var previousHyphen = false
        for scalar in input.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.append(Character(scalar).lowercased())
                previousHyphen = false
            } else if !previousHyphen, !out.isEmpty {
                out.append("-")
                previousHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "unknown" : out
    }

    private static let compactTimestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "UTC")
        fmt.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return fmt
    }()
}

// MARK: - Errors

enum TranscriptStoreError: LocalizedError {
    case missingRecord(String)
    case deleteCurrent

    var errorDescription: String? {
        switch self {
        case let .missingRecord(id):
            "Transcript record '\(id)' not found in manifest."
        case .deleteCurrent:
            "Cannot delete the current transcript. Pick a different one as current first."
        }
    }
}
