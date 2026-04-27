import AVFoundation
import Foundation
import os.log
import TranscribeerCore

/// Google Speech-to-Text v1 backend.
///
/// Uses the v1 API (`speech.googleapis.com/v1/speech:recognize`) with API-key
/// auth so the user only needs an API key — no project ID, no gcloud ADC.
/// v2 would unlock Chirp 2, but requires a project-qualified URL path and
/// has a mandatory GCS upload path for audio longer than about a minute.
///
/// ## Audio handling (no-cloud-storage design)
///
/// By policy, audio bytes never land in GCS or any other cloud storage. To
/// stay within v1's 1-minute-per-request limit the backend:
///
/// 1. Decodes the input file (M4A/WAV/etc.) through `AVAudioFile`
/// 2. Resamples to 16 kHz mono 16-bit PCM WAV (Google's recommended input)
/// 3. Splits the PCM into ~55 second chunks via `AudioChunker.split`
/// 4. POSTs each chunk inline (base64) to `/v1/speech:recognize`
/// 5. Offsets timestamps by the chunk start time and merges
///
/// All temp files live in `FileManager.temporaryDirectory` and are deleted
/// via `defer` before the function returns.
///
/// ## Diarization
///
/// When `diarize == true`, the config requests `enableSpeakerDiarization`
/// with min=1/max=6 speakers. v1 returns speaker tags on each word in the
/// final result; we group adjacent words with the same tag into
/// `DiarSegment`s. `producesDiarization` is set at init to match the user's
/// toggle so the pipeline knows whether to skip the external Pyannote pass.
struct GoogleSTTBackend: TranscriptionBackend {
    var displayName: String { "Google Speech-to-Text" }
    let producesDiarization: Bool

    let model: String
    let diarize: Bool

    /// Backend identifier passed to `KeychainHelper` — isolated from the
    /// LLM backend namespace so the STT key and the Gemini key (if any) are
    /// distinct keychain entries.
    static let keychainBackend = "google_stt"

    private static let chunkDurationSeconds: Double = 55
    private static let targetSampleRate: Double = 16_000
    private static let apiEndpoint = URL(string: "https://speech.googleapis.com/v1/speech:recognize")
    private static let requestTimeout: TimeInterval = 120

    private static let logger = Logger(subsystem: "com.transcribeer", category: "transcription.google")

    init(location _: String = "global", model: String, diarize: Bool) {
        // `location` is accepted for forward compatibility with a v2 backend;
        // v1 doesn't use it. Kept in the signature so the caller (config) can
        // feed all Google STT fields without branching.
        self.model = model
        self.diarize = diarize
        self.producesDiarization = diarize
    }

    func transcribe(
        audioURL: URL,
        language: String,
        numSpeakers: Int?,
        onSegment: @Sendable (TranscriptSegment) -> Void,
        onProgress: @Sendable (Double) -> Void,
    ) async throws -> TranscriptionOutput {
        let apiKey = try Self.resolveAPIKey()
        let languageCodes = Self.mapLanguage(language)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("google-stt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Normalize to 16 kHz mono 16-bit PCM so chunking + Google-friendly
        // encoding are both handled in one pass, regardless of input format.
        let normalizedWAV = tempDir.appendingPathComponent("input.wav")
        try Self.writeLinear16WAV(source: audioURL, dest: normalizedWAV)

        let chunks = try AudioChunker.split(
            source: normalizedWAV,
            chunkDuration: Self.chunkDurationSeconds,
            tempDir: tempDir,
        )
        guard !chunks.isEmpty else {
            return TranscriptionOutput(segments: [], diarSegments: [], detectedLanguage: nil)
        }

        let langJoined = languageCodes.joined(separator: ",")
        Self.logger.log(
            """
            google_stt: \(chunks.count) chunks, model=\(self.model, privacy: .public), \
            lang=\(langJoined, privacy: .public), diarize=\(self.diarize)
            """,
        )

        onProgress(0)

        // Preserve chunk order by keying on index. Network latency dominates,
        // so parallel dispatch cuts wall time proportional to concurrency;
        // cap at 4 to stay well under Google's default per-minute quota.
        let options = RecognizeOptions(
            apiKey: apiKey,
            languageCodes: languageCodes,
            model: model,
            diarize: diarize,
            speakerCount: numSpeakers.flatMap { $0 > 0 ? $0 : nil },
        )
        let chunkResults = try await Self.runConcurrentRecognize(
            chunks: chunks,
            options: options,
            maxConcurrency: min(4, chunks.count),
            onProgress: onProgress,
        )

        var segments: [TranscriptSegment] = []
        var diarSegments: [DiarSegment] = []
        for (chunk, result) in zip(chunks, chunkResults) {
            for segment in result.segments {
                let shifted = TranscriptSegment(
                    start: segment.start + chunk.startOffset,
                    end: segment.end + chunk.startOffset,
                    text: segment.text,
                )
                segments.append(shifted)
                onSegment(shifted)
            }
            for diar in result.diarSegments {
                diarSegments.append(DiarSegment(
                    start: diar.start + chunk.startOffset,
                    end: diar.end + chunk.startOffset,
                    speaker: diar.speaker,
                ))
            }
        }

        onProgress(1)
        return TranscriptionOutput(
            segments: segments,
            diarSegments: diarSegments,
            detectedLanguage: languageCodes.first,
        )
    }

    // MARK: - Helpers

    private static func resolveAPIKey() throws -> String {
        if let key = KeychainHelper.getAPIKey(backend: keychainBackend), !key.isEmpty {
            return key
        }
        if let env = ProcessInfo.processInfo.environment["GOOGLE_STT_API_KEY"], !env.isEmpty {
            return env
        }
        throw GoogleSTTError.missingAPIKey
    }

    /// Map Transcribeer's ISO 639-1 codes (plus `"auto"`) to Google's BCP-47
    /// `languageCode` + optional `alternativeLanguageCodes`.
    ///
    /// v1 takes a single primary `languageCode` and up to 3 alternates. When
    /// the user picks `"auto"` we prime it with English + Hebrew (the two
    /// locales the app's UI currently surfaces). Power users can override by
    /// typing a BCP-47 string into the language field directly.
    static func mapLanguage(_ code: String) -> [String] {
        switch code.lowercased() {
        case "auto":
            return ["en-US", "he-IL"]
        case "en":
            return ["en-US"]
        case "he":
            return ["he-IL"]
        case "ar":
            return ["ar-EG"]
        case "es":
            return ["es-ES"]
        case "fr":
            return ["fr-FR"]
        case "de":
            return ["de-DE"]
        case "ja":
            return ["ja-JP"]
        case "zh":
            return ["zh-CN"]
        default:
            // Accept raw BCP-47 (`"en-GB"`, `"pt-BR"`) as-is.
            return code.contains("-") ? [code] : [code]
        }
    }

    // MARK: - Audio normalization

    /// Re-encode any AVFoundation-readable audio file as a 16 kHz mono
    /// 16-bit LINEAR16 PCM WAV, ready for Google STT and `AudioChunker`.
    ///
    /// This is a one-pass decode + resample + downmix. For inputs already at
    /// 16 kHz mono (the app's default capture format), the main cost is
    /// re-encoding float32 samples to int16 — fast enough that we don't
    /// bother short-circuiting.
    private static func writeLinear16WAV(source: URL, dest: URL) throws {
        let inputFile = try AVAudioFile(forReading: source)
        let inputFormat = inputFile.processingFormat

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: true,
        ) else {
            throw GoogleSTTError.audioConversionFailed("cannot create output format")
        }

        // AVAudioFile for writing LINEAR16 WAV. The settings dictionary
        // forces 16-bit signed little-endian PCM which matches what
        // AudioChunker expects (it writes the same header format itself).
        let writeSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let outputFile = try AVAudioFile(
            forWriting: dest,
            settings: writeSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true,
        )

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw GoogleSTTError.audioConversionFailed("no converter for \(inputFormat) -> \(outputFormat)")
        }

        let readBatch: AVAudioFrameCount = 16_384
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: readBatch) else {
            throw GoogleSTTError.audioConversionFailed("cannot allocate read buffer")
        }
        // Output capacity must accommodate the sample-rate ratio (e.g. 48 k → 16 k
        // will shrink, 8 k → 16 k will grow). Round up generously.
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(readBatch) * ratio + 1024)
        guard let writeBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
            throw GoogleSTTError.audioConversionFailed("cannot allocate write buffer")
        }

        var endOfStream = false
        while !endOfStream {
            do {
                try inputFile.read(into: readBuffer)
            } catch {
                // EOF is expected and not an error; AVAudioFile.read surfaces
                // it with frameLength == 0 on the final call.
                if readBuffer.frameLength == 0 { break }
                throw error
            }
            if readBuffer.frameLength == 0 { break }

            var error: NSError?
            var consumed = false
            let status = converter.convert(to: writeBuffer, error: &error) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return readBuffer
            }

            if let error {
                throw GoogleSTTError.audioConversionFailed(error.localizedDescription)
            }
            if status == .endOfStream {
                endOfStream = true
            }
            if writeBuffer.frameLength > 0 {
                try outputFile.write(from: writeBuffer)
            }
            // Reset for the next iteration — AVAudioFile.read fills to
            // frameLength, and AVAudioConverter writes to frameLength; we
            // need to clear so the next convert/write doesn't double-count.
            readBuffer.frameLength = 0
            writeBuffer.frameLength = 0
        }
    }

    // MARK: - HTTP

    /// Request-shaping parameters bundled so the concurrent driver and the
    /// per-chunk helper don't each need an 8-parameter signature.
    private struct RecognizeOptions: Sendable {
        let apiKey: String
        let languageCodes: [String]
        let model: String
        let diarize: Bool
        let speakerCount: Int?
    }

    private static func runConcurrentRecognize(
        chunks: [AudioChunker.Chunk],
        options: RecognizeOptions,
        maxConcurrency: Int,
        onProgress: @Sendable (Double) -> Void,
    ) async throws -> [ChunkResult] {
        var results: [Int: ChunkResult] = [:]
        results.reserveCapacity(chunks.count)

        try await withThrowingTaskGroup(of: (Int, ChunkResult).self) { group in
            var enqueued = 0
            var completed = 0

            // Seed up to maxConcurrency tasks, then dispatch a replacement
            // for each one as it completes. Keeps in-flight requests bounded
            // without the extra ceremony of an explicit semaphore.
            func enqueueNext() {
                guard enqueued < chunks.count else { return }
                let idx = enqueued
                enqueued += 1
                let chunk = chunks[idx]
                group.addTask {
                    let result = try await recognize(audioURL: chunk.url, options: options)
                    return (idx, result)
                }
            }

            for _ in 0..<min(maxConcurrency, chunks.count) {
                enqueueNext()
            }

            for try await (idx, result) in group {
                results[idx] = result
                completed += 1
                onProgress(Double(completed) / Double(chunks.count))
                enqueueNext()
            }
        }

        return (0..<chunks.count).compactMap { results[$0] }
    }

    private static func recognize(
        audioURL: URL,
        options: RecognizeOptions,
    ) async throws -> ChunkResult {
        guard let endpoint = apiEndpoint else {
            throw GoogleSTTError.invalidEndpoint
        }
        let audioData = try Data(contentsOf: audioURL)
        let base64Audio = audioData.base64EncodedString()

        let alternatives = options.languageCodes.count > 1
            ? Array(options.languageCodes.dropFirst())
            : nil
        let diarConfig: DiarizationConfig? = options.diarize
            ? DiarizationConfig(
                enableSpeakerDiarization: true,
                minSpeakerCount: 1,
                maxSpeakerCount: options.speakerCount ?? 6,
            )
            : nil

        let body = RecognizeRequest(
            config: RecognitionConfig(
                encoding: "LINEAR16",
                sampleRateHertz: Int(targetSampleRate),
                languageCode: options.languageCodes.first ?? "en-US",
                alternativeLanguageCodes: alternatives,
                model: options.model,
                enableAutomaticPunctuation: true,
                enableWordTimeOffsets: true,
                diarizationConfig: diarConfig,
            ),
            audio: RecognizeRequest.Audio(content: base64Audio),
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(options.apiKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.timeoutInterval = requestTimeout
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw GoogleSTTError.transportFailure("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = Self.parseErrorMessage(data) ?? "HTTP \(http.statusCode)"
            throw GoogleSTTError.apiError(http.statusCode, detail)
        }

        let decoded = try JSONDecoder().decode(RecognizeResponse.self, from: data)
        return parseResponse(decoded, diarize: options.diarize)
    }

    private static func parseErrorMessage(_ data: Data) -> String? {
        struct ErrorEnvelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        return (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error?.message
    }

    /// Turn the v1 `results` array into a merged `ChunkResult`.
    ///
    /// Without diarization: one `TranscriptSegment` per `result` using
    /// `resultEndTime` as the end and the previous result's end as the start
    /// (zero for the first).
    ///
    /// With diarization: v1 emits a final result whose `alternatives[0].words`
    /// carries `speakerTag` for every word in the recognition. We prefer that
    /// final words array (higher fidelity timing + speaker info) and synthesize
    /// segments by grouping consecutive words with the same `speakerTag`.
    static func parseResponse(_ response: RecognizeResponse, diarize: Bool) -> ChunkResult {
        let results = response.results ?? []

        if diarize, let finalWords = results.last?.alternatives?.first?.words, !finalWords.isEmpty {
            return parseDiarizedWords(finalWords)
        }

        var segments: [TranscriptSegment] = []
        var previousEnd: Double = 0
        for result in results {
            guard let alt = result.alternatives?.first, let transcript = alt.transcript else { continue }
            let cleaned = transcript.trimmingCharacters(in: .whitespaces)
            guard !cleaned.isEmpty else { continue }
            let end = parseDuration(result.resultEndTime) ?? previousEnd
            segments.append(TranscriptSegment(start: previousEnd, end: end, text: cleaned))
            previousEnd = end
        }
        return ChunkResult(segments: segments, diarSegments: [])
    }

    private static func parseDiarizedWords(_ words: [Word]) -> ChunkResult {
        var segments: [TranscriptSegment] = []
        var diarSegments: [DiarSegment] = []

        var currentSpeaker: Int?
        var currentStart: Double = 0
        var currentEnd: Double = 0
        var currentText: [String] = []

        func flush() {
            guard let speaker = currentSpeaker, !currentText.isEmpty else { return }
            let text = currentText.joined(separator: " ")
            segments.append(TranscriptSegment(start: currentStart, end: currentEnd, text: text))
            diarSegments.append(DiarSegment(
                start: currentStart,
                end: currentEnd,
                speaker: "SPEAKER_\(speaker)",
            ))
        }

        for word in words {
            let start = parseDuration(word.startTime) ?? 0
            let end = parseDuration(word.endTime) ?? start
            let speaker = word.speakerTag ?? 0
            let token = word.word ?? ""

            if speaker != currentSpeaker {
                flush()
                currentSpeaker = speaker
                currentStart = start
                currentText = []
            }
            currentEnd = end
            if !token.isEmpty { currentText.append(token) }
        }
        flush()
        return ChunkResult(segments: segments, diarSegments: diarSegments)
    }

    /// Parse Google's duration format (e.g. `"3.500s"`) to seconds.
    private static func parseDuration(_ string: String?) -> Double? {
        guard let raw = string else { return nil }
        let trimmed = raw.hasSuffix("s") ? String(raw.dropLast()) : raw
        return Double(trimmed)
    }
}

// MARK: - Internal types

/// Per-chunk parse result. Internal to the backend; merged into the public
/// `TranscriptionOutput` after offset adjustment.
struct ChunkResult: Sendable {
    let segments: [TranscriptSegment]
    let diarSegments: [DiarSegment]
}

// MARK: - v1 request/response DTOs

private struct RecognizeRequest: Encodable {
    let config: RecognitionConfig
    let audio: Audio

    struct Audio: Encodable {
        let content: String
    }
}

private struct RecognitionConfig: Encodable {
    let encoding: String
    let sampleRateHertz: Int
    let languageCode: String
    let alternativeLanguageCodes: [String]?
    let model: String
    let enableAutomaticPunctuation: Bool
    let enableWordTimeOffsets: Bool
    let diarizationConfig: DiarizationConfig?
}

private struct DiarizationConfig: Encodable {
    let enableSpeakerDiarization: Bool
    let minSpeakerCount: Int
    let maxSpeakerCount: Int
}

/// v1 recognize response. Shape matches
/// https://cloud.google.com/speech-to-text/docs/reference/rest/v1/speech/recognize
struct RecognizeResponse: Decodable {
    let results: [Result]?

    struct Result: Decodable {
        let alternatives: [Alternative]?
        let resultEndTime: String?
        let languageCode: String?
    }

    struct Alternative: Decodable {
        let transcript: String?
        let confidence: Double?
        let words: [Word]?
    }
}

struct Word: Decodable {
    let startTime: String?
    let endTime: String?
    let word: String?
    let speakerTag: Int?
}

// MARK: - Errors

enum GoogleSTTError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case audioConversionFailed(String)
    case transportFailure(String)
    case apiError(Int, String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Google Speech-to-Text API key found in Keychain (or GOOGLE_STT_API_KEY env)."
        case .invalidEndpoint:
            return "Google STT endpoint URL is malformed."
        case let .audioConversionFailed(detail):
            return "Audio conversion for Google STT failed: \(detail)."
        case let .transportFailure(detail):
            return "Google STT request failed: \(detail)."
        case let .apiError(status, message):
            return "Google STT returned HTTP \(status): \(message)"
        }
    }
}
