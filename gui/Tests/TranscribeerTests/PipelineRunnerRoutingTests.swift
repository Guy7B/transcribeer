import Foundation
import Testing
@testable import TranscribeerApp

/// Guard the static routing rules that decide when Pyannote must run even
/// if the user explicitly asked for Google diarization. These matter because:
///   1. Google v1's Hebrew diarization is broken (collapses to 1 speaker)
///   2. Google v2 Chirp 3 doesn't support Hebrew diarization at all
/// The pipeline has to protect users from both without requiring them to
/// know the difference.
struct PipelineRunnerRoutingTests {
    @Test(
        "shouldForcePyannote is true for any Hebrew-ish language value",
        arguments: ["he", "HE", "He", "he-IL", "iw", "iw-IL", "IW-il"],
    )
    func hebrewForcesPyannote(input: String) {
        #expect(PipelineRunner.shouldForcePyannote(language: input))
    }

    @Test(
        "shouldForcePyannote is false for non-Hebrew locales and auto",
        arguments: ["en", "en-US", "ar", "ar-EG", "auto", "", "de", "zh", "ja"],
    )
    func nonHebrewUnaffected(input: String) {
        #expect(!PipelineRunner.shouldForcePyannote(language: input))
    }

    @Test("composePrompt prefers explicit focus over base prompt")
    func composePromptWithFocus() {
        // Sanity check that a pre-existing static helper still composes
        // base + focus correctly — keeps the prompts tab + re-summarize
        // overrides honest.
        let combined = PipelineRunner.composePrompt(base: "BASE", focus: "focus on decisions")
        #expect(combined?.contains("BASE") ?? false)
        #expect(combined?.contains("focus on decisions") ?? false)
    }

    @Test("composePrompt with empty focus returns the base unchanged")
    func composePromptEmptyFocus() {
        #expect(PipelineRunner.composePrompt(base: "BASE", focus: "   ") == "BASE")
        #expect(PipelineRunner.composePrompt(base: "BASE", focus: nil) == "BASE")
    }
}
