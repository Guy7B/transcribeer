import Foundation
import Testing
@testable import TranscribeerApp

struct GoogleSTTBackendTests {
    // MARK: - mapLanguage

    @Test(
        "mapLanguage produces the right BCP-47 list for each input",
        arguments: [
            ("auto", ["en-US", "he-IL"]),
            ("en", ["en-US"]),
            ("he", ["he-IL"]),
            ("ar", ["ar-EG"]),
            ("es", ["es-ES"]),
            ("fr", ["fr-FR"]),
            ("de", ["de-DE"]),
            ("ja", ["ja-JP"]),
            ("zh", ["zh-CN"]),
        ],
    )
    func mapLanguageKnown(input: String, expected: [String]) {
        #expect(GoogleSTTBackend.mapLanguage(input) == expected)
    }

    @Test("mapLanguage passes BCP-47 strings through unchanged")
    func mapLanguageBCP47Passthrough() {
        // Power users who type a full BCP-47 tag into `config.language`
        // (e.g. for regional variants Google supports but Transcribeer's
        // enum doesn't surface) should see that tag reach the API.
        #expect(GoogleSTTBackend.mapLanguage("en-GB") == ["en-GB"])
        #expect(GoogleSTTBackend.mapLanguage("pt-BR") == ["pt-BR"])
        #expect(GoogleSTTBackend.mapLanguage("es-MX") == ["es-MX"])
    }

    @Test("mapLanguage is case-insensitive for the short forms")
    func mapLanguageCaseInsensitive() {
        // Users can paste "EN" or "He" from docs; don't punish them.
        #expect(GoogleSTTBackend.mapLanguage("EN") == ["en-US"])
        #expect(GoogleSTTBackend.mapLanguage("He") == ["he-IL"])
        #expect(GoogleSTTBackend.mapLanguage("AUTO") == ["en-US", "he-IL"])
    }

    // MARK: - parseResponse without diarization

    @Test("parseResponse returns one segment per result, using resultEndTime")
    func parseNoDiarize() {
        let response = RecognizeResponse(
            results: [
                RecognizeResponse.Result(
                    alternatives: [RecognizeResponse.Alternative(
                        transcript: "hello world",
                        confidence: 0.9,
                        words: nil,
                    ), ],
                    resultEndTime: "2.5s",
                    languageCode: "en-us",
                ),
                RecognizeResponse.Result(
                    alternatives: [RecognizeResponse.Alternative(
                        transcript: "second chunk",
                        confidence: 0.8,
                        words: nil,
                    ), ],
                    resultEndTime: "5.0s",
                    languageCode: "en-us",
                ),
            ],
        )

        let result = GoogleSTTBackend.parseResponse(response, diarize: false)

        #expect(result.segments.count == 2)
        #expect(result.segments[0].start == 0)
        #expect(result.segments[0].end == 2.5)
        #expect(result.segments[0].text == "hello world")
        #expect(result.segments[1].start == 2.5)
        #expect(result.segments[1].end == 5.0)
        #expect(result.segments[1].text == "second chunk")
        #expect(result.diarSegments.isEmpty)
    }

    @Test("parseResponse skips empty transcripts and tolerates missing alternatives")
    func parseTolerant() {
        let response = RecognizeResponse(
            results: [
                RecognizeResponse.Result(
                    alternatives: [RecognizeResponse.Alternative(
                        transcript: "",
                        confidence: nil,
                        words: nil,
                    ), ],
                    resultEndTime: "1.0s",
                    languageCode: nil,
                ),
                RecognizeResponse.Result(alternatives: nil, resultEndTime: nil, languageCode: nil),
                RecognizeResponse.Result(
                    alternatives: [RecognizeResponse.Alternative(
                        transcript: "actual text",
                        confidence: 0.9,
                        words: nil,
                    ), ],
                    resultEndTime: "3.0s",
                    languageCode: nil,
                ),
            ],
        )

        let result = GoogleSTTBackend.parseResponse(response, diarize: false)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].text == "actual text")
    }

    @Test("parseResponse handles a fully empty response")
    func parseEmpty() {
        let response = RecognizeResponse(results: nil)
        let result = GoogleSTTBackend.parseResponse(response, diarize: false)
        #expect(result.segments.isEmpty)
        #expect(result.diarSegments.isEmpty)
    }

    // MARK: - parseResponse with diarization

    @Test("parseResponse groups consecutive same-speaker words into segments")
    func parseDiarized() {
        // Google v1 emits the final result with every word tagged. Two
        // speakers alternating produces two grouped segments.
        let words: [Word] = [
            Word(startTime: "0.0s", endTime: "0.5s", word: "hello", speakerTag: 1),
            Word(startTime: "0.5s", endTime: "1.0s", word: "there", speakerTag: 1),
            Word(startTime: "1.2s", endTime: "1.8s", word: "hi", speakerTag: 2),
            Word(startTime: "2.0s", endTime: "2.5s", word: "friend", speakerTag: 2),
            Word(startTime: "3.0s", endTime: "3.5s", word: "bye", speakerTag: 1),
        ]
        let response = RecognizeResponse(
            results: [
                // v1 puts earlier-per-word results before the final
                // all-words-with-diarization result; the parser should
                // use the last one.
                RecognizeResponse.Result(
                    alternatives: [RecognizeResponse.Alternative(
                        transcript: "discard this",
                        confidence: 0.8,
                        words: nil,
                    ), ],
                    resultEndTime: "3.5s",
                    languageCode: nil,
                ),
                RecognizeResponse.Result(
                    alternatives: [RecognizeResponse.Alternative(
                        transcript: "ignored",
                        confidence: 0.9,
                        words: words,
                    ), ],
                    resultEndTime: "3.5s",
                    languageCode: nil,
                ),
            ],
        )

        let result = GoogleSTTBackend.parseResponse(response, diarize: true)

        // Three grouped segments: speaker 1, speaker 2, speaker 1.
        #expect(result.segments.count == 3)
        #expect(result.diarSegments.count == 3)

        #expect(result.segments[0].text == "hello there")
        #expect(result.diarSegments[0].speaker == "SPEAKER_1")
        #expect(result.diarSegments[0].start == 0.0)
        #expect(result.diarSegments[0].end == 1.0)

        #expect(result.segments[1].text == "hi friend")
        #expect(result.diarSegments[1].speaker == "SPEAKER_2")
        #expect(result.diarSegments[1].start == 1.2)
        #expect(result.diarSegments[1].end == 2.5)

        #expect(result.segments[2].text == "bye")
        #expect(result.diarSegments[2].speaker == "SPEAKER_1")
    }

    @Test("parseResponse falls back to segments-only when diarize is requested but no words present")
    func parseDiarizedFallback() {
        // Model doesn't support diarization (e.g. some v1 models). Response
        // has no `words`. The parser should not drop the transcript on the
        // floor — it should fall through to the non-diarized path so the
        // pipeline can hand off to Pyannote instead.
        let response = RecognizeResponse(
            results: [RecognizeResponse.Result(
                alternatives: [RecognizeResponse.Alternative(
                    transcript: "transcript without words",
                    confidence: 0.9,
                    words: nil,
                ), ],
                resultEndTime: "4.0s",
                languageCode: nil,
            ), ],
        )

        let result = GoogleSTTBackend.parseResponse(response, diarize: true)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].text == "transcript without words")
        #expect(result.diarSegments.isEmpty)
    }
}
