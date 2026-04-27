import Foundation

/// A single transcription run captured for a session.
///
/// Multiple records can coexist per session — each re-transcribe creates a
/// new one rather than overwriting. The record pairs a transcript with its
/// summary so summaries stay bound to the transcript they were generated
/// from (a Whisper transcript's summary doesn't follow you to Google's).
///
/// The record is serialized into `transcripts/index.json` and also crosses
/// the main-actor boundary when the pipeline hands a new one to the UI, so
/// keep the conformances broad (`Codable`, `Sendable`, `Hashable`).
struct TranscriptRecord: Codable, Hashable, Identifiable, Sendable {
    /// Stable identifier, also used as the on-disk filename stem.
    /// Format: `<backend>__<model-slug>__<YYYYMMDDTHHMMSSZ>`.
    let id: String
    /// `TranscriptionBackendKind` raw value, or `"legacy"` for migrated
    /// transcripts whose provenance is unknown.
    let backend: String
    /// Resolved model identifier at the time of transcription.
    let model: String
    /// Language code used for this run (`"auto"`, `"en"`, `"he"`, etc.).
    let language: String
    /// Diarization source: `"pyannote"`, `"google"`, `"none"`, or `"unknown"`.
    let diarization: String
    /// Wall-clock time the run finished.
    let createdAt: Date
    /// Filename of the transcript within the session's `transcripts/` dir.
    let transcriptFile: String
    /// Optional paired summary filename. `nil` until a summary has been
    /// generated for this specific transcript.
    var summaryFile: String?
}

/// On-disk manifest for a session's transcripts directory.
///
/// `schemaVersion` lets us evolve the format — older builds reading a
/// newer manifest can refuse gracefully instead of silently losing data.
struct TranscriptManifest: Codable, Sendable {
    /// Bumped on any backward-incompatible change to the manifest shape.
    static let currentSchemaVersion = 1

    var schemaVersion: Int = Self.currentSchemaVersion
    var records: [TranscriptRecord]
    /// `id` of the record that `transcript.txt` / `summary.md` currently
    /// mirror. `nil` only for brand-new sessions with zero records.
    var currentID: String?
}
