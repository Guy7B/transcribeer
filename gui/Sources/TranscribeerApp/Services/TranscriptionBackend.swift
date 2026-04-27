import Foundation

/// Identifier for a transcription backend, persisted in `AppConfig`.
///
/// New backends should be added here and surfaced in the Settings picker.
/// The raw value is what lands in `config.toml`, so changes require a
/// migration story — never rename existing cases.
enum TranscriptionBackendKind: String, CaseIterable, Identifiable, Sendable {
    case whisperkit
    /// Google STT v2 (Chirp 2 / Chirp 3). Recommended cloud backend: Hebrew
    /// transcription is dramatically better than v1, authentication uses
    /// Application Default Credentials via `gcloud`.
    case googleSttV2 = "google_stt_v2"
    /// Google STT v1 REST API with API key auth. Kept for legacy configs and
    /// non-GCP users who only have an API key available.
    case googleStt = "google_stt"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .whisperkit: "WhisperKit (on-device)"
        case .googleSttV2: "Google Speech-to-Text (Chirp)"
        case .googleStt: "Google Speech-to-Text v1 (legacy)"
        }
    }

    /// Best-effort parse that falls back to `.whisperkit` so a bad config
    /// value doesn't block the pipeline.
    static func from(_ raw: String) -> Self {
        Self(rawValue: raw) ?? .whisperkit
    }
}

/// Full result of a transcription pass, returned at the end of `transcribe(...)`.
///
/// Cloud backends that perform speaker diarization inline (e.g. Google STT
/// with `diarizationConfig`) populate `diarSegments` and set
/// `TranscriptionBackend.producesDiarization` to true, which tells the
/// pipeline to skip the external Pyannote pass.
struct TranscriptionOutput: Sendable {
    let segments: [TranscriptSegment]
    let diarSegments: [DiarSegment]
    let detectedLanguage: String?
}

/// Abstraction over a transcription provider.
///
/// Implementations must be safe to call concurrently with the same instance
/// (the `Sendable` conformance). In practice `PipelineRunner` creates a fresh
/// backend per pipeline run, so concurrency across runs isn't a concern.
///
/// Segments are delivered in two ways: streamed via the `onSegment` callback
/// (so the live preview can render incrementally) and returned as a canonical
/// full list at completion. Implementations that can't stream (Google batch
/// recognize for a single chunk) may emit each segment once via `onSegment`
/// right before `transcribe(...)` returns.
protocol TranscriptionBackend: Sendable {
    /// Human-readable label for error messages and logs.
    var displayName: String { get }

    /// When true, `TranscriptionOutput.diarSegments` will be populated and
    /// the pipeline skips the external `DiarizationService` pass.
    var producesDiarization: Bool { get }

    /// Transcribe `audioURL` to timestamped segments.
    ///
    /// - Parameters:
    ///   - audioURL: Path to a PCM-encoded audio file (WAV). M4A/MP3 are also
    ///     accepted where the backend supports them.
    ///   - language: ISO 639-1 code (`"en"`, `"he"`) or `"auto"` for detection.
    ///     Backends that require a specific language list (Google STT) must
    ///     map `"auto"` to a sensible default themselves.
    ///   - numSpeakers: Expected speaker count for diarization-capable
    ///     backends. Pass 0 or nil for auto-detect. WhisperKit ignores this.
    ///   - onSegment: Called on a background queue as segments become
    ///     available. Recipients must hop to the main actor before mutating
    ///     UI state.
    ///   - onProgress: Fractional progress in [0, 1]. Backends without a
    ///     meaningful progress signal may report only 0 at start and 1 at
    ///     completion.
    func transcribe(
        audioURL: URL,
        language: String,
        numSpeakers: Int?,
        onSegment: @Sendable (TranscriptSegment) -> Void,
        onProgress: @Sendable (Double) -> Void,
    ) async throws -> TranscriptionOutput
}
