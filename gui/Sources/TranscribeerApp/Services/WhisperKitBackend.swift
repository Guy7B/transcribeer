import Foundation
import os.log

/// `TranscriptionBackend` adapter that delegates to the existing
/// `TranscriptionService` (the app's WhisperKit integration).
///
/// `TranscriptionService` remains the canonical owner of live state (the
/// `liveSegments` / `progress` / `modelState` observables wired into the
/// session detail view). This adapter just forwards segments into the
/// protocol's `onSegment` callback in parallel so non-WhisperKit observers
/// (if any) see the same stream.
///
/// The adapter intentionally captures an existing `TranscriptionService`
/// instance rather than constructing its own: the service holds an expensive
/// loaded `WhisperKit` object we want to reuse across pipeline runs.
struct WhisperKitBackend: TranscriptionBackend {
    var displayName: String { "WhisperKit (on-device)" }
    var producesDiarization: Bool { false }

    /// Shared service reference. Reads/writes on `MainActor`.
    let service: TranscriptionService
    /// Resolved WhisperKit model identifier (after canonicalization).
    let modelName: String
    /// Optional HuggingFace `owner/repo` override for custom models.
    let modelRepo: String

    private static let logger = Logger(subsystem: "com.transcribeer", category: "transcription.whisperkit")

    func transcribe(
        audioURL: URL,
        language: String,
        numSpeakers: Int?,
        onSegment: @Sendable (TranscriptSegment) -> Void,
        onProgress: @Sendable (Double) -> Void,
    ) async throws -> TranscriptionOutput {
        // Pre-load the model so the actual transcribe call doesn't pay the
        // download/compile cost mid-stream. `TranscriptionService.loadModel`
        // short-circuits when the requested variant is already loaded.
        try await service.loadModel(
            name: modelName,
            repo: modelRepo.isEmpty ? nil : modelRepo,
        )

        // `TranscriptionService.transcribe` already handles the segment
        // streaming via its own `liveSegments` observable — views bind to
        // that directly. We ignore onSegment here intentionally; the
        // contract allows backends to deliver segments only at the end.
        //
        // If future work moves live-segment rendering behind the protocol,
        // this backend will need to instrument
        // `kit.segmentDiscoveryCallback` and fan out to both consumers.
        _ = onSegment
        _ = onProgress
        _ = numSpeakers

        Self.logger.log("transcribe via WhisperKit: model=\(modelName, privacy: .public)")

        let segments = try await service.transcribe(
            audioURL: audioURL,
            language: language,
        )
        return TranscriptionOutput(
            segments: segments,
            diarSegments: [],
            detectedLanguage: nil,
        )
    }
}
