import Foundation
import Testing
import TranscribeerCore
@testable import TranscribeerApp

struct GoogleSTTBackendV2Tests {
    // MARK: - mapLanguage

    @Test(
        "mapLanguage produces the BCP-47 list the v2 API expects",
        arguments: [
            ("auto", ["auto"]),
            ("en", ["en-US"]),
            ("he", ["iw-IL"]),   // v2 still expects legacy "iw" tag
            ("ar", ["ar-EG"]),
            ("es", ["es-ES"]),
            ("fr", ["fr-FR"]),
            ("de", ["de-DE"]),
            ("ja", ["ja-JP"]),
            ("zh", ["cmn-Hans-CN"]),
        ],
    )
    func mapLanguageKnown(input: String, expected: [String]) {
        #expect(GoogleSTTBackendV2.mapLanguage(input) == expected)
    }

    @Test("mapLanguage passes BCP-47 tags through unchanged")
    func mapLanguageBCP47Passthrough() {
        // v2's `languageCodes` takes raw BCP-47 so regional variants users
        // type into config.toml reach the API verbatim.
        #expect(GoogleSTTBackendV2.mapLanguage("en-GB") == ["en-GB"])
        #expect(GoogleSTTBackendV2.mapLanguage("pt-BR") == ["pt-BR"])
    }

    @Test("mapLanguage is case-insensitive for the short forms")
    func mapLanguageCaseInsensitive() {
        #expect(GoogleSTTBackendV2.mapLanguage("EN") == ["en-US"])
        #expect(GoogleSTTBackendV2.mapLanguage("He") == ["iw-IL"])
    }

    // MARK: - utterances(from:)

    @Test("utterances collapse a word stream into gap-bounded segments")
    func utterancesGroupByGap() {
        // Three consecutive words with tiny gaps → one utterance. Then a
        // ~2 s gap opens a new utterance.
        let words = [
            WordHit(start: 0.0, end: 0.3, text: "שלום"),
            WordHit(start: 0.4, end: 0.8, text: "עולם"),
            WordHit(start: 0.85, end: 1.1, text: "חדש"),
            WordHit(start: 3.0, end: 3.5, text: "אבל"),
            WordHit(start: 3.6, end: 4.2, text: "חכה"),
        ]

        let result = GoogleSTTBackendV2.utterances(from: words, maxGap: 0.8)
        #expect(result.count == 2)
        #expect(result[0].start == 0.0)
        #expect(result[0].end == 1.1)
        #expect(result[0].text == "שלום עולם חדש")
        #expect(result[1].start == 3.0)
        #expect(result[1].end == 4.2)
        #expect(result[1].text == "אבל חכה")
    }

    @Test("utterances break when the running total exceeds maxUtterance")
    func utterancesBreakOnMaxDuration() {
        // No gaps, but cumulative duration exceeds the cap → must split.
        let words = (0..<12).map { idx in
            WordHit(
                start: Double(idx),
                end: Double(idx) + 0.9,
                text: "w\(idx)",
            )
        }

        let result = GoogleSTTBackendV2.utterances(
            from: words,
            maxGap: 2.0,
            maxUtterance: 4.0,
        )
        // First utterance spans roughly 4 s (w0..w3), then next ~4 s, etc.
        #expect(result.count >= 3)
        for seg in result {
            #expect(seg.end - seg.start <= 4.5)
        }
    }

    @Test("utterances handle empty input without crashing")
    func utterancesEmpty() {
        #expect(GoogleSTTBackendV2.utterances(from: []).isEmpty)
    }

    @Test("utterances drop empty word tokens without producing blank segments")
    func utterancesSkipBlanks() {
        let words = [
            WordHit(start: 0.0, end: 0.5, text: "hello"),
            WordHit(start: 0.5, end: 0.6, text: ""),
            WordHit(start: 0.6, end: 1.0, text: "world"),
        ]
        let result = GoogleSTTBackendV2.utterances(from: words)
        #expect(result.count == 1)
        #expect(result[0].text == "hello world")
    }

    // MARK: - parseResponse

    @Test("parseResponse harvests word-level timestamps across all results")
    func parseWordsAcrossResults() {
        let response = RecognizeResponseV2(
            results: [
                RecognizeResponseV2.Result(
                    alternatives: [RecognizeResponseV2.Alternative(
                        transcript: "hello world",
                        confidence: 0.9,
                        words: [
                            WordV2(startOffset: "0.0s", endOffset: "0.4s", word: "hello", speakerLabel: nil),
                            WordV2(startOffset: "0.4s", endOffset: "1.0s", word: "world", speakerLabel: nil),
                        ],
                    )],
                    resultEndOffset: "1.0s",
                    languageCode: "en-US",
                ),
                RecognizeResponseV2.Result(
                    alternatives: [RecognizeResponseV2.Alternative(
                        transcript: "and again",
                        confidence: 0.88,
                        words: [
                            WordV2(startOffset: "1.1s", endOffset: "1.4s", word: "and", speakerLabel: nil),
                            WordV2(startOffset: "1.4s", endOffset: "1.9s", word: "again", speakerLabel: nil),
                        ],
                    )],
                    resultEndOffset: "1.9s",
                    languageCode: "en-US",
                ),
            ],
        )

        let chunk = GoogleSTTBackendV2.parseResponse(response)
        #expect(chunk.words.count == 4)
        #expect(chunk.words[0].text == "hello")
        #expect(chunk.words[0].start == 0.0)
        #expect(chunk.words[3].text == "again")
        #expect(chunk.words[3].end == 1.9)
    }

    @Test("parseResponse falls back to a single transcript word when the model omits per-word timings")
    func parseFallbackWhenNoWords() {
        // Older v2 models (and some edge cases) may return a transcript
        // without word timings. The aligner still needs something for each
        // chunk; synthesize a single word-sized hit so the upstream
        // utterance step produces output.
        let response = RecognizeResponseV2(
            results: [RecognizeResponseV2.Result(
                alternatives: [RecognizeResponseV2.Alternative(
                    transcript: "full chunk transcript",
                    confidence: 0.9,
                    words: nil,
                )],
                resultEndOffset: "2.0s",
                languageCode: nil,
            )],
        )

        let chunk = GoogleSTTBackendV2.parseResponse(response)
        #expect(chunk.words.count == 1)
        #expect(chunk.words[0].text == "full chunk transcript")
        #expect(chunk.words[0].start == 0.0)
        #expect(chunk.words[0].end == 2.0)
    }

    @Test("parseResponse handles an empty results array")
    func parseEmpty() {
        let chunk = GoogleSTTBackendV2.parseResponse(RecognizeResponseV2(results: nil))
        #expect(chunk.words.isEmpty)
    }

    // MARK: - preflight

    @Test("preflight rejects missing project and region")
    func preflightValidation() {
        #expect(throws: GoogleSTTV2Error.self) {
            try GoogleSTTBackendV2.preflight(project: "", region: "us")
        }
        #expect(throws: GoogleSTTV2Error.self) {
            try GoogleSTTBackendV2.preflight(project: "   ", region: "us")
        }
        #expect(throws: GoogleSTTV2Error.self) {
            try GoogleSTTBackendV2.preflight(project: "proj", region: "")
        }
    }
}
