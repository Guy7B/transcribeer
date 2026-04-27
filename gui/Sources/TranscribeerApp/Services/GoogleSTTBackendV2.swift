import AVFoundation
import CryptoKit
import Foundation
import os.log
import TranscribeerCore

/// Google Cloud Speech-to-Text v2 backend.
///
/// Differences from `GoogleSTTBackend` (v1):
///   - Endpoint is regional: `{region}-speech.googleapis.com/v2/...`
///   - Authenticates with ADC-issued OAuth bearer tokens (via `gcloud`),
///     not an API key
///   - Supports Chirp 2 / Chirp 3 models (better Hebrew transcription)
///   - Always returns word-level timestamps which we synthesize into
///     utterance segments for downstream diarization alignment
///   - Does NOT request inline diarization (Chirp 3 doesn't support Hebrew
///     diarization, and for the languages it does support, diarization is
///     only available via BatchRecognize + GCS — violates our no-cloud-
///     storage rule)
///
/// **Resilience layers** (added 2026-04-26 after long-recording timeouts):
///
///   1. Per-chunk retry inside `recognize(...)`: transient transport / HTTP
///      5xx / 429 errors are retried with exponential backoff (up to 4
///      attempts). Permanent 4xx errors are surfaced to the caller without
///      retry — those mean misconfiguration, not flakiness.
///
///   2. Per-chunk result persistence under
///      `<session>/.stt-cache/google_stt_v2__<model>__<lang>__<hash>/`.
///      A failed run leaves all completed chunks on disk; the next attempt
///      loads them and only re-transcribes what's missing. A 42-minute
///      recording that died on chunk 38 of 46 doesn't restart from zero.
///
/// The calling pipeline always runs Pyannote afterwards when diarization is
/// enabled (see `PipelineRunner.makeTranscriptionBackend`).
struct GoogleSTTBackendV2: TranscriptionBackend {
    let displayName = "Google Speech-to-Text v2"
    let producesDiarization = false

    private let project: String
    private let region: String
    private let model: String
    private let session: URLSession

    static let keychainBackend = "google_stt_v2"

    private static let chunkDurationSeconds: Double = 55
    private static let targetSampleRate: Double = 16_000
    private static let requestTimeout: TimeInterval = 180

    /// Backoff schedule used by `recognize(...)`'s retry helper. Index `i`
    /// is the delay BEFORE attempt `i+1` (i.e. attempt 0 has no delay,
    /// attempt 1 waits backoff[0] seconds, etc.). Length+1 == attempt cap.
    static let retryBackoffSeconds: [TimeInterval] = [1, 3, 7]

    private static let logger = Logger(subsystem: "com.transcribeer", category: "transcription.google_v2")

    init(project: String, region: String, model: String, session: URLSession = .shared) {
        self.project = project
        self.region = region
        self.model = model
        self.session = session
    }

    /// Best-effort validation of configuration before any network call.
    /// Surfaces a human-readable error so the pipeline doesn't burn time
    /// normalizing + chunking audio just to fail on the first POST.
    static func preflight(project: String, region: String) throws {
        if project.trimmingCharacters(in: .whitespaces).isEmpty {
            throw GoogleSTTV2Error.missingProject
        }
        if region.trimmingCharacters(in: .whitespaces).isEmpty {
            throw GoogleSTTV2Error.missingRegion
        }
        _ = try GoogleAuthHelper.accessToken()
    }

    func transcribe(
        audioURL: URL,
        language: String,
        numSpeakers: Int?,
        onSegment: @Sendable (TranscriptSegment) -> Void,
        onProgress: @Sendable (Double) -> Void,
    ) async throws -> TranscriptionOutput {
        try Self.preflight(project: project, region: region)
        let token = try GoogleAuthHelper.accessToken()

        let languageCodes = Self.mapLanguage(language)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("google-stt-v2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let normalizedWAV = tempDir.appendingPathComponent("input.wav")
        try writeLinear16WAV(source: audioURL, dest: normalizedWAV)

        let chunks = try AudioChunker.split(
            source: normalizedWAV,
            chunkDuration: Self.chunkDurationSeconds,
            tempDir: tempDir,
        )
        guard !chunks.isEmpty else {
            return TranscriptionOutput(segments: [], diarSegments: [], detectedLanguage: nil)
        }

        // Resume cache lives next to the source audio (not the normalized
        // WAV), keyed on the original audio's hash so re-runs against the
        // same recording can reuse work.
        let cacheDir = Self.resumeCacheDirectory(
            audioURL: audioURL,
            model: model,
            languageCodes: languageCodes,
        )
        let cached = Self.loadResumeCache(at: cacheDir, expectedChunkCount: chunks.count)
        let langJoined = languageCodes.joined(separator: ",")
        Self.logger.log(
            """
            google_stt_v2: \(chunks.count) chunks, model=\(self.model, privacy: .public), \
            region=\(self.region, privacy: .public), project=\(self.project, privacy: .public), \
            lang=\(langJoined, privacy: .public), cached=\(cached.count, privacy: .public)
            """,
        )

        // Initial progress reflects already-cached chunks so a fully-cached
        // re-run shows 1.0 immediately and the user doesn't think we're
        // about to re-transcribe everything.
        Self.reportProgress(completed: cached.count, total: chunks.count, onProgress: onProgress)

        let options = RecognizeOptions(
            token: token,
            project: project,
            region: region,
            model: model,
            languageCodes: languageCodes,
            cacheDir: cacheDir,
            session: session,
        )
        _ = numSpeakers  // Reserved: Chirp does not accept our speaker hint.

        let chunkResults = try await Self.runConcurrent(
            chunks: chunks,
            options: options,
            cached: cached,
            maxConcurrency: min(4, chunks.count),
            onProgress: onProgress,
        )

        // Write/update the manifest now that we know the run produced a
        // full result set. Best-effort — a failed write must not abort
        // the transcription path.
        Self.writeManifest(
            at: cacheDir,
            audioHash: Self.audioHash(of: audioURL),
            model: model,
            languageCodes: languageCodes,
            totalChunks: chunks.count,
        )

        var words: [WordHit] = []
        for (chunk, result) in zip(chunks, chunkResults) {
            for hit in result.words {
                words.append(WordHit(
                    start: hit.start + chunk.startOffset,
                    end: hit.end + chunk.startOffset,
                    text: hit.text,
                ))
            }
        }

        // Synthesize utterance-level segments from word timestamps so the
        // downstream aligner has meaningful granularity. Mirrors the
        // Python harness behaviour in tests/benchmarks/sttcompare/run.py.
        let segments = Self.utterances(from: words)
        for segment in segments { onSegment(segment) }

        onProgress(1)
        return TranscriptionOutput(
            segments: segments,
            diarSegments: [],
            detectedLanguage: languageCodes.first,
        )
    }

    // MARK: - Helpers

    /// v2 expects BCP-47 tags in `languageCodes`. Unlike v1 there is no
    /// separate `alternativeLanguageCodes` field; the array holds every
    /// candidate. Chirp 3's `"auto"` sentinel is supported too.
    static func mapLanguage(_ code: String) -> [String] {
        switch code.lowercased() {
        case "auto": return ["auto"]
        case "en": return ["en-US"]
        case "he": return ["iw-IL"]  // Google still expects the legacy "iw"
        case "ar": return ["ar-EG"]
        case "es": return ["es-ES"]
        case "fr": return ["fr-FR"]
        case "de": return ["de-DE"]
        case "ja": return ["ja-JP"]
        case "zh": return ["cmn-Hans-CN"]
        default: return code.contains("-") ? [code] : [code]
        }
    }

    /// Group word-level timestamps into utterance segments using silence
    /// gaps. Intentionally identical to the Python harness
    /// (`tests/benchmarks/sttcompare/run.py _utterances_from_words`) so the
    /// in-app output matches what you previewed there.
    static func utterances(
        from words: [WordHit],
        maxGap: Double = 0.8,
        maxUtterance: Double = 10.0,
    ) -> [TranscriptSegment] {
        guard let first = words.first else { return [] }
        var out: [TranscriptSegment] = []
        var curStart = first.start
        var curEnd = first.end
        var curTokens: [String] = [first.text]

        for word in words.dropFirst() {
            let gap = word.start - curEnd
            let total = word.end - curStart
            if gap > maxGap || total > maxUtterance {
                let text = curTokens.filter { !$0.isEmpty }.joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !text.isEmpty {
                    out.append(TranscriptSegment(start: curStart, end: curEnd, text: text))
                }
                curStart = word.start
                curTokens = [word.text]
            } else if !word.text.isEmpty {
                curTokens.append(word.text)
            }
            curEnd = word.end
        }
        let tailText = curTokens.filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if !tailText.isEmpty {
            out.append(TranscriptSegment(start: curStart, end: curEnd, text: tailText))
        }
        return out
    }

    // MARK: - Audio normalization

    /// Re-encode any AVFoundation-readable audio as 16 kHz mono 16-bit LINEAR16
    /// PCM WAV. Shared logic with `GoogleSTTBackend.writeLinear16WAV`; kept
    /// inline here to avoid an awkward shared-helper file just for two
    /// Google backends.
    private func writeLinear16WAV(source: URL, dest: URL) throws {
        let inputFile = try AVAudioFile(forReading: source)
        let inputFormat = inputFile.processingFormat

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true,
        ) else {
            throw GoogleSTTV2Error.audioConversionFailed("cannot create output format")
        }

        let writeSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.targetSampleRate,
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
            throw GoogleSTTV2Error.audioConversionFailed("no converter for \(inputFormat) -> \(outputFormat)")
        }

        let readBatch: AVAudioFrameCount = 16_384
        guard let readBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: readBatch) else {
            throw GoogleSTTV2Error.audioConversionFailed("cannot allocate read buffer")
        }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(readBatch) * ratio + 1024)
        guard let writeBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCapacity) else {
            throw GoogleSTTV2Error.audioConversionFailed("cannot allocate write buffer")
        }

        var endOfStream = false
        while !endOfStream {
            do {
                try inputFile.read(into: readBuffer)
            } catch {
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
                throw GoogleSTTV2Error.audioConversionFailed(error.localizedDescription)
            }
            if status == .endOfStream { endOfStream = true }
            if writeBuffer.frameLength > 0 {
                try outputFile.write(from: writeBuffer)
            }
            readBuffer.frameLength = 0
            writeBuffer.frameLength = 0
        }
    }

    // MARK: - HTTP

    struct RecognizeOptions: Sendable {
        let token: String
        let project: String
        let region: String
        let model: String
        let languageCodes: [String]
        /// Where to persist `chunk_NNNN.json` as each chunk completes. When
        /// `nil`, no caching is performed (used by the unit tests that
        /// don't want a filesystem dependency).
        let cacheDir: URL?
        let session: URLSession
    }

    private static func runConcurrent(
        chunks: [AudioChunker.Chunk],
        options: RecognizeOptions,
        cached: [Int: ChunkResultV2],
        maxConcurrency: Int,
        onProgress: @Sendable (Double) -> Void,
    ) async throws -> [ChunkResultV2] {
        var results: [Int: ChunkResultV2] = cached
        results.reserveCapacity(chunks.count)

        // Indices that need transcribing — preserve order so progress
        // updates roughly match the source timeline.
        let pending = (0..<chunks.count).filter { results[$0] == nil }
        if pending.isEmpty {
            // Everything came from cache — caller still expects to see the
            // final 1.0 progress event from `transcribe(...)`.
            return (0..<chunks.count).compactMap { results[$0] }
        }

        try await withThrowingTaskGroup(of: (Int, ChunkResultV2).self) { group in
            var cursor = 0
            var completed = cached.count

            func enqueueNext() {
                guard cursor < pending.count else { return }
                let idx = pending[cursor]
                cursor += 1
                let chunk = chunks[idx]
                group.addTask {
                    let result = try await recognize(
                        audioURL: chunk.url,
                        chunkIndex: idx,
                        startOffset: chunk.startOffset,
                        options: options,
                    )
                    return (idx, result)
                }
            }

            for _ in 0..<min(maxConcurrency, pending.count) { enqueueNext() }

            for try await (idx, result) in group {
                results[idx] = result
                completed += 1
                reportProgress(completed: completed, total: chunks.count, onProgress: onProgress)
                enqueueNext()
            }
        }

        return (0..<chunks.count).compactMap { results[$0] }
    }

    private static func reportProgress(
        completed: Int,
        total: Int,
        onProgress: @Sendable (Double) -> Void,
    ) {
        guard total > 0 else { return onProgress(0) }
        onProgress(min(1.0, Double(completed) / Double(total)))
    }

    /// Recognize one audio chunk. Wraps the raw HTTP path in a retry helper
    /// so transient errors (timeouts, dropped TCP, 5xx, 429) don't kill the
    /// whole multi-chunk transcription. Successful results are persisted
    /// to the resume cache before returning.
    static func recognize(
        audioURL: URL,
        chunkIndex: Int,
        startOffset: Double,
        options: RecognizeOptions,
    ) async throws -> ChunkResultV2 {
        let result = try await recognizeWithRetry(audioURL: audioURL, options: options)
        if let cacheDir = options.cacheDir {
            saveChunkCache(
                at: cacheDir,
                index: chunkIndex,
                startOffset: startOffset,
                result: result,
            )
        }
        return result
    }

    /// Drive `performRecognize` with up to 4 attempts. Backoff schedule is
    /// 1s / 3s / 7s. Returns on the first success; throws the last error
    /// after the final attempt is exhausted.
    static func recognizeWithRetry(
        audioURL: URL,
        options: RecognizeOptions,
    ) async throws -> ChunkResultV2 {
        var attempt = 0
        let maxAttempts = retryBackoffSeconds.count + 1
        var lastError: Error = GoogleSTTV2Error.transportFailure("no attempt was made")

        while attempt < maxAttempts {
            do {
                return try await performRecognize(audioURL: audioURL, options: options)
            } catch {
                lastError = error
                let decision = retryDecision(for: error, attempt: attempt)
                logger.log(
                    """
                    google_stt_v2 chunk attempt=\(attempt + 1, privacy: .public) \
                    decision=\(decision.kind, privacy: .public) \
                    error=\(error.localizedDescription, privacy: .public)
                    """,
                )
                guard let delay = decision.retryAfter else {
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }
        throw lastError
    }

    /// Strategy decision for a single failed attempt: either give up
    /// (`retryAfter == nil`) or sleep for `retryAfter` seconds and try
    /// again. The `kind` string is purely for logging.
    struct RetryDecision: Sendable {
        let retryAfter: TimeInterval?
        let kind: String
    }

    /// Classify an error from `performRecognize` and choose the next move.
    /// Pulled out as a static helper so the retry loop stays readable and
    /// the unit tests can exercise the policy without a live URLSession.
    static func retryDecision(for error: Error, attempt: Int) -> RetryDecision {
        // Last attempt — never retry, regardless of error class.
        if attempt >= retryBackoffSeconds.count {
            return RetryDecision(retryAfter: nil, kind: "exhausted")
        }
        let nextBackoff = retryBackoffSeconds[attempt]

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .dnsLookupFailed:
                return RetryDecision(retryAfter: nextBackoff, kind: "transport")
            default:
                return RetryDecision(retryAfter: nil, kind: "url-fatal")
            }
        }
        if case let GoogleSTTV2Error.apiError(status, _, retryAfter) = error {
            if status == 429 {
                return RetryDecision(
                    retryAfter: retryAfter ?? nextBackoff,
                    kind: "rate-limited",
                )
            }
            if (500..<600).contains(status) {
                return RetryDecision(retryAfter: nextBackoff, kind: "server-5xx")
            }
            return RetryDecision(retryAfter: nil, kind: "client-4xx")
        }
        // Decoding / programming / non-classifiable errors: don't retry.
        return RetryDecision(retryAfter: nil, kind: "fatal")
    }

    /// One HTTP round-trip to the v2 Recognize endpoint. Throws either a
    /// `URLError` (transport) or `GoogleSTTV2Error.apiError` (HTTP status
    /// outside 2xx). Both are classified by `retryDecision(for:attempt:)`.
    private static func performRecognize(
        audioURL: URL,
        options: RecognizeOptions,
    ) async throws -> ChunkResultV2 {
        let endpointString = "https://\(options.region)-speech.googleapis.com/v2/projects/" +
            "\(options.project)/locations/\(options.region)/recognizers/_:recognize"
        guard let endpoint = URL(string: endpointString) else {
            throw GoogleSTTV2Error.invalidEndpoint(endpointString)
        }
        let audioData = try Data(contentsOf: audioURL)
        let base64Audio = audioData.base64EncodedString()

        let body = RecognizeRequestV2(
            config: RecognitionConfigV2(
                explicitDecodingConfig: ExplicitDecodingConfig(
                    encoding: "LINEAR16",
                    sampleRateHertz: Int(targetSampleRate),
                    audioChannelCount: 1,
                ),
                languageCodes: options.languageCodes,
                model: options.model,
                features: RecognitionFeatures(enableWordTimeOffsets: true),
            ),
            content: base64Audio,
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(options.token)", forHTTPHeaderField: "Authorization")
        request.setValue(options.project, forHTTPHeaderField: "x-goog-user-project")
        request.timeoutInterval = requestTimeout
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await options.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleSTTV2Error.transportFailure("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = parseErrorMessage(data) ?? "HTTP \(http.statusCode)"
            // 401 usually means the cached token just crossed the 1h boundary
            // between when we minted it and when this chunk fired. Invalidate
            // so the next transcription run picks up a fresh token; surfacing
            // the error to the user anyway keeps the UI honest about the
            // failure.
            if http.statusCode == 401 {
                GoogleAuthHelper.invalidateCache()
            }
            let retryAfter = parseRetryAfter(header: http.value(forHTTPHeaderField: "Retry-After"))
            throw GoogleSTTV2Error.apiError(http.statusCode, detail, retryAfter: retryAfter)
        }

        let decoded = try JSONDecoder().decode(RecognizeResponseV2.self, from: data)
        return parseResponse(decoded)
    }

    /// Parse a `Retry-After` header in either delta-seconds or HTTP-date
    /// form, clamping to a sane upper bound so a hostile/proxy-injected
    /// value can't make us sleep for hours.
    static func parseRetryAfter(header: String?) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return nil
        }
        if let secs = Double(raw) {
            return min(max(secs, 0), 60)
        }
        // HTTP-date — rare on Google APIs but cheap to handle.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: raw) {
            let delta = date.timeIntervalSinceNow
            return min(max(delta, 0), 60)
        }
        return nil
    }

    private static func parseErrorMessage(_ data: Data) -> String? {
        struct ErrorEnvelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner?
        }
        return (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error?.message
    }

    /// Extract word-level timestamps from a v2 Recognize response. Segment
    /// assembly happens later in `utterances(from:)` so we get one uniform
    /// granularity across chunks.
    static func parseResponse(_ response: RecognizeResponseV2) -> ChunkResultV2 {
        var words: [WordHit] = []
        for result in response.results ?? [] {
            guard let alt = result.alternatives?.first else { continue }
            for word in alt.words ?? [] {
                let start = parseOffset(word.startOffset)
                let end = parseOffset(word.endOffset)
                let text = word.word ?? ""
                guard !text.isEmpty else { continue }
                words.append(WordHit(start: start, end: end, text: text))
            }
            // When a chunk came back with a transcript but no per-word
            // timestamps (rare — Chirp 3 always returns words when we ask
            // for them, but older models may not), synthesize a single
            // word-sized hit covering the whole result so the utterance
            // step still produces output.
            if (alt.words ?? []).isEmpty, let transcript = alt.transcript?.trimmingCharacters(in: .whitespaces),
               !transcript.isEmpty {
                let endOffset = parseOffset(result.resultEndOffset)
                words.append(WordHit(start: 0, end: endOffset, text: transcript))
            }
        }
        return ChunkResultV2(words: words)
    }

    private static func parseOffset(_ raw: String?) -> Double {
        guard let raw else { return 0 }
        let trimmed = raw.hasSuffix("s") ? String(raw.dropLast()) : raw
        return Double(trimmed) ?? 0
    }

    // Resume-cache APIs (resumeCacheDirectory, audioHash, loadResumeCache,
    // saveChunkCache, writeManifest) live in `GoogleSTTBackendV2+Cache.swift`.
    // Public types (WordHit, ChunkResultV2, RecognizeResponseV2, WordV2,
    // GoogleSTTV2Error) live in `GoogleSTTBackendV2Types.swift`.
}

// MARK: - v2 request DTOs (kept fileprivate to the recognize() path)

private struct RecognizeRequestV2: Encodable {
    let config: RecognitionConfigV2
    let content: String
}

private struct RecognitionConfigV2: Encodable {
    let explicitDecodingConfig: ExplicitDecodingConfig
    let languageCodes: [String]
    let model: String
    let features: RecognitionFeatures
}

private struct ExplicitDecodingConfig: Encodable {
    let encoding: String
    let sampleRateHertz: Int
    let audioChannelCount: Int
}

private struct RecognitionFeatures: Encodable {
    let enableWordTimeOffsets: Bool
}
