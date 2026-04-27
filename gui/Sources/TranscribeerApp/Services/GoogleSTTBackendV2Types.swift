import Foundation

// MARK: - Public-ish types

/// One word with start/end timestamps in seconds, used as the smallest
/// unit of granularity for both v2 transcription output and resume-cache
/// persistence.
struct WordHit: Sendable {
    let start: Double
    let end: Double
    let text: String
}

/// Per-chunk transcription result used by `runConcurrent` and the resume
/// cache. Wraps just the word list — chunk start offsets are added by
/// the caller when assembling the final word stream.
struct ChunkResultV2: Sendable {
    let words: [WordHit]
}

// MARK: - v2 response DTOs

/// Top-level v2 `Recognize` response envelope. Only the fields we
/// actually consume are modelled; Google adds new ones over time and
/// `Decodable` happily ignores them.
struct RecognizeResponseV2: Decodable {
    let results: [Result]?

    struct Result: Decodable {
        let alternatives: [Alternative]?
        let resultEndOffset: String?
        let languageCode: String?
    }

    struct Alternative: Decodable {
        let transcript: String?
        let confidence: Double?
        let words: [WordV2]?
    }
}

/// One word from a v2 alternative. Offsets are duration strings
/// ("1.234s") which `parseOffset` converts to `Double` seconds.
struct WordV2: Decodable {
    let startOffset: String?
    let endOffset: String?
    let word: String?
    /// v2 uses `speakerLabel` (String) vs v1's `speakerTag` (Int). Unused
    /// today because we rely on Pyannote for diarization, but kept in the
    /// model so a future Chirp-diarization path can read it.
    let speakerLabel: String?
}

// MARK: - Errors

/// Domain errors produced by `GoogleSTTBackendV2`. `errorDescription`
/// returns user-facing copy that surfaces verbatim in alerts and
/// `run.log`, so the wording is intentionally direct and actionable.
enum GoogleSTTV2Error: LocalizedError {
    case missingProject
    case missingRegion
    case invalidEndpoint(String)
    case audioConversionFailed(String)
    case transportFailure(String)
    /// `retryAfter` is set when the server suggested an explicit delay
    /// (Retry-After header on a 429); `nil` lets the retry loop fall back
    /// to its default backoff.
    case apiError(Int, String, retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .missingProject:
            return "Google STT v2 needs a GCP project ID. Set it in Settings → Transcription."
        case .missingRegion:
            return "Google STT v2 needs a region (e.g. `us`, `eu`, `us-central1`)."
        case let .invalidEndpoint(raw):
            return "Google STT v2 endpoint URL is malformed: \(raw)"
        case let .audioConversionFailed(detail):
            return "Audio conversion for Google STT v2 failed: \(detail)."
        case let .transportFailure(detail):
            return "Google STT v2 request failed: \(detail)."
        case let .apiError(status, message, _):
            return "Google STT v2 returned HTTP \(status): \(message)"
        }
    }
}
