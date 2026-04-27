import Foundation
import Testing
@testable import TranscribeerApp

struct TranscriptionBackendKindTests {
    @Test("Raw values match config.toml strings")
    func rawValues() {
        #expect(TranscriptionBackendKind.whisperkit.rawValue == "whisperkit")
        #expect(TranscriptionBackendKind.googleSttV2.rawValue == "google_stt_v2")
        #expect(TranscriptionBackendKind.googleStt.rawValue == "google_stt")
    }

    @Test("from(_:) falls back to whisperkit for unknown or empty values")
    func fromUnknownFallsBackToWhisperKit() {
        // Guards against a future typo in config.toml silently disabling
        // local transcription. An unknown backend value should degrade to
        // the privacy-preserving on-device default.
        #expect(TranscriptionBackendKind.from("whisperkit") == .whisperkit)
        #expect(TranscriptionBackendKind.from("google_stt_v2") == .googleSttV2)
        #expect(TranscriptionBackendKind.from("google_stt") == .googleStt)
        #expect(TranscriptionBackendKind.from("not-a-backend") == .whisperkit)
        #expect(TranscriptionBackendKind.from("") == .whisperkit)
    }

    @Test("allCases covers every backend (prevents picker regressions)")
    func allCasesCoverage() {
        let cases = Set(TranscriptionBackendKind.allCases.map(\.rawValue))
        #expect(cases == ["whisperkit", "google_stt_v2", "google_stt"])
    }

    @Test("displayName is non-empty for every case")
    func displayNamePresent() {
        for kind in TranscriptionBackendKind.allCases {
            #expect(!kind.displayName.isEmpty)
        }
    }
}
