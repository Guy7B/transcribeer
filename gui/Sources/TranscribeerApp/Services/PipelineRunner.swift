import Foundation
import os.log
import TranscribeerCore

private let logger = Logger(subsystem: "com.transcribeer", category: "pipeline")

/// Runs the transcribeer pipeline using native Swift services.
@Observable
@MainActor
final class PipelineRunner {
    var state: AppState = .idle
    var currentSession: URL?
    var promptProfile: String?

    /// True when the current recording was auto-started by Zoom detection.
    var zoomAutoStarted = false

    /// Which session is actively being transcribed right now, if any.
    /// Set for both new recordings and re-transcribe-from-history flows so
    /// the detail view can decide whether to render the live preview.
    var transcribingSession: URL?

    /// Which session is actively being summarized right now, if any. Drives
    /// the live markdown preview while the LLM streams deltas.
    var summarizingSession: URL?

    /// Running accumulator of streamed summary text for `summarizingSession`.
    /// Cleared when the stream finishes or a new summary starts.
    var liveSummary: String = ""

    /// Transcription progress (0..1), driven by WhisperKit.
    var transcriptionProgress: Double? { transcriptionService.progress }

    let transcriptionService = TranscriptionService()

    private var pipelineTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var summarizeTask: Task<CLIResult, Never>?

    func startRecording(config: AppConfig) {
        guard !state.isBusy else { return }

        let session = SessionManager.newSession(sessionsDir: config.expandedSessionsDir)
        currentSession = session
        promptProfile = nil
        state = .recording(startTime: Date())

        pipelineTask = Task {
            await runPipeline(session: session, config: config)
        }
    }

    func stopRecording() {
        guard state.isRecording else { return }
        CaptureService.stop()
    }

    /// Cancel an in-flight transcription or summarization. Does nothing while
    /// recording (use `stopRecording` for that).
    func cancelProcessing() {
        switch state {
        case .transcribing, .summarizing:
            transcriptionService.cancel()
            processingTask?.cancel()
            pipelineTask?.cancel()
            summarizeTask?.cancel()
            summarizeTask = nil
        default:
            break
        }
    }

    private func runPipeline(session: URL, config: AppConfig) async {
        let audioPath = session.appendingPathComponent("audio.m4a")
        let transcriptPath = session.appendingPathComponent("transcript.txt")
        let summaryPath = session.appendingPathComponent("summary.md")
        let logger = SessionLog(logPath: session.appendingPathComponent("run.log"))

        logger.log("session=\(session.path)")
        logger.log("pipeline=\(config.pipelineMode) lang=\(config.language) diarize=\(config.diarization)")
        logger.log(
            "backend=\(config.transcriptionBackend) model=\(modelForBackend(config: config)) " +
            "llm_backend=\(config.llmBackend) llm_model=\(config.llmModel)",
        )

        // 1. Record — in-process via CaptureCore (uses app's TCC permission)
        logger.log("capture started")
        let recordResult = await CaptureService.record(to: audioPath, duration: nil)

        switch recordResult {
        case .permissionDenied(let detail):
            logger.log("capture failed: \(detail)")
            state = .error(message: detail, sessionPath: session.path, kind: .recording)
            NotificationManager.notifyError(detail)
            return
        case .error(let err):
            logger.log("capture failed: \(err)")
            state = .error(message: err, sessionPath: session.path, kind: .recording)
            NotificationManager.notifyError(err)
            return
        case .noAudio:
            logger.log("no audio captured")
            state = .idle
            return
        case .recorded:
            let size = (try? FileManager.default.attributesOfItem(
                atPath: audioPath.path
            )[.size] as? UInt64) ?? 0
            let sizeMB = Double(size) / (1024.0 * 1024.0)
            logger.log("recorded \(size) bytes (\(String(format: "%.2f", sizeMB)) MB)")
        }

        if config.pipelineMode == "record-only" {
            finishSession(session)
            return
        }

        // 2. Transcribe (WhisperKit + SpeakerKit)
        guard await performTranscription(
            config: config,
            audioPath: audioPath,
            transcriptPath: transcriptPath,
            logger: logger
        ) else { return }

        if config.pipelineMode == "record+transcribe" {
            finishSession(session)
            return
        }

        // 3. Summarize (LLM) — failure here is non-fatal
        await performSummarization(
            config: config,
            transcriptPath: transcriptPath,
            summaryPath: summaryPath,
            logger: logger
        )

        finishSession(session)
    }

    private func performTranscription(
        config: AppConfig,
        audioPath: URL,
        transcriptPath: URL,
        logger: SessionLog
    ) async -> Bool {
        state = .transcribing
        let session = transcriptPath.deletingLastPathComponent()
        transcribingSession = session
        defer { transcribingSession = nil }
        logger.log("transcription started")
        let started = Date()

        do {
            let result = try await transcribeAndFormat(
                audioPath: audioPath,
                language: config.language,
                config: config,
                logger: logger,
            )
            try storeTranscript(
                result: result,
                session: session,
                config: config,
                language: config.language,
            )
            SessionManager.setLanguage(session, config.language)
            let elapsed = Date().timeIntervalSince(started)
            logger.log("transcription done in \(String(format: "%.1f", elapsed))s")
            return true
        } catch is CancellationError {
            logger.log("transcription cancelled")
            state = .idle
            return false
        } catch {
            let message = "Transcription failed: \(error.localizedDescription)"
            logger.log(message)
            state = .error(message: message, sessionPath: session.path, kind: .transcription)
            NotificationManager.notifyError(message)
            return false
        }
    }

    /// Hand a freshly-produced transcript to the persistence store. The
    /// store owns filename allocation, manifest updates, and the
    /// `transcript.txt` mirror that legacy code paths (and the
    /// summarization stage) still read from. Pulled out of the happy-path
    /// `performTranscription` so the function stays short and the error
    /// paths aren't obscured by filesystem details.
    private func storeTranscript(
        result: String,
        session: URL,
        config: AppConfig,
        language: String,
    ) throws {
        let kind = TranscriptionBackendKind.from(config.transcriptionBackend)
        let diarization: String
        switch kind {
        case .googleStt where config.googleSttDiarize && !Self.shouldForcePyannote(language: language):
            diarization = "google"
        default:
            diarization = config.diarization
        }
        let effectiveModel: String
        switch kind {
        case .googleStt: effectiveModel = config.googleSttModel
        case .googleSttV2: effectiveModel = config.googleSttV2Model
        case .whisperkit: effectiveModel = AppConfig.canonicalWhisperModel(config.whisperModel)
        }

        let input = TranscriptStore.NewTranscriptInput(
            backend: config.transcriptionBackend,
            model: effectiveModel,
            language: language,
            diarization: diarization,
            content: result,
        )
        _ = try TranscriptStore.addTranscript(session: session, input: input, makeCurrent: true)
    }

    /// Whether the pipeline should override whatever inline diarization the
    /// selected backend advertises and run Pyannote externally instead.
    ///
    /// Hebrew: Google's v1 diarization collapses a multi-speaker recording
    /// into a single speaker (reproduced on 2026-04-23 with 4-speaker audio
    /// and documented in tests/benchmarks/sttcompare/output/). Chirp 3's
    /// diarization doesn't support Hebrew at all. Pyannote (language-
    /// agnostic acoustic diarization via SpeakerKit) is the correct answer
    /// in both cases.
    static func shouldForcePyannote(language: String) -> Bool {
        let normalized = language.lowercased()
        return normalized == "he" || normalized.hasPrefix("he-") ||
            normalized == "iw" || normalized.hasPrefix("iw-")
    }

    private func performSummarization(
        config: AppConfig,
        transcriptPath: URL,
        summaryPath: URL,
        logger: SessionLog
    ) async {
        state = .summarizing
        logger.log(
            "summarization started backend=\(config.llmBackend) " +
            "model=\(config.llmModel) profile=\(promptProfile ?? "default")",
        )
        let started = Date()
        var firstFragmentAt: Date?
        do {
            let transcript = try String(contentsOf: transcriptPath, encoding: .utf8)
            let customPrompt = SummarizationService.loadPromptProfile(promptProfile)
            _ = try await streamSummary(
                session: transcriptPath.deletingLastPathComponent(),
                transcript: transcript,
                summaryPath: summaryPath,
                config: config,
                prompt: customPrompt,
                onFirstFragment: {
                    if firstFragmentAt == nil {
                        firstFragmentAt = Date()
                        let ttft = Date().timeIntervalSince(started)
                        logger.log("summary first token in \(String(format: "%.2f", ttft))s")
                    }
                },
            )
            let elapsed = Date().timeIntervalSince(started)
            logger.log("summarization done in \(String(format: "%.1f", elapsed))s")
        } catch {
            logger.log("summarization failed: \(error.localizedDescription)")
            // Non-fatal — transcript is what matters.
        }
    }

    /// Stream summary deltas from the LLM, mirroring them into `liveSummary`
    /// for the detail view to render in real time. On completion, attaches
    /// the summary to the session's current transcript record (so the
    /// summary follows that specific transcript, not the session as a
    /// whole) and lets the store rewrite `summary.md` as its mirror.
    ///
    /// Falls back to writing `summaryPath` directly when the session has
    /// no current record — shouldn't happen once migration has run, but
    /// keeps the pipeline resilient if a malformed manifest is ever
    /// encountered.
    private func streamSummary(
        session: URL,
        transcript: String,
        summaryPath: URL,
        config: AppConfig,
        prompt: String?,
        onFirstFragment: (() -> Void)? = nil
    ) async throws -> String {
        summarizingSession = session
        liveSummary = ""
        // Clear on any exit path — success, throw, or cancellation.
        defer {
            summarizingSession = nil
            liveSummary = ""
        }

        let stream = try await SummarizationService.streamSummarize(
            transcript: transcript,
            backend: config.llmBackend,
            model: config.llmModel,
            ollamaHost: config.ollamaHost,
            prompt: prompt
        )

        var accumulated = ""
        var sawFirst = false
        for try await fragment in stream {
            try Task.checkCancellation()
            if !sawFirst {
                sawFirst = true
                onFirstFragment?()
            }
            accumulated += fragment
            liveSummary = accumulated
        }

        if let current = TranscriptStore.currentRecord(in: session) {
            _ = try TranscriptStore.attachSummary(
                session: session,
                transcriptID: current.id,
                content: accumulated,
            )
        } else {
            try accumulated.write(to: summaryPath, atomically: true, encoding: .utf8)
        }
        return accumulated
    }

    private func finishSession(_ session: URL) {
        state = .done(sessionPath: session.path)
        NotificationManager.notifyDone(sessionName: SessionManager.displayName(session))
    }

    // MARK: - Transcription + Diarization + Formatting

    /// Run the chosen transcription backend plus (optionally) external
    /// diarization, merge the two, and return the formatted transcript.
    ///
    /// Backends that bring their own diarization (`producesDiarization ==
    /// true`, e.g. Google STT) return pre-labeled `DiarSegment`s in their
    /// `TranscriptionOutput`; the external `DiarizationService` pass is
    /// skipped for those. Backends that don't (WhisperKit) run Pyannote in
    /// parallel with the transcription request.
    private func transcribeAndFormat(
        audioPath: URL,
        language: String,
        config: AppConfig,
        logger: SessionLog,
    ) async throws -> String {
        // Guard: fail fast on silent recordings before any model load or
        // network call. Cheap local check; catches muted / no-playback
        // captures before they burn minutes (or API quota).
        try AudioValidation.ensureAudibleSignal(at: audioPath)

        let backend = makeTranscriptionBackend(config: config, language: language)
        let numSpeakers = config.numSpeakers > 0 ? config.numSpeakers : nil
        let runExternalDiarization = !backend.producesDiarization && config.diarization != "none"

        let progressTracker = TranscriptionProgressTracker(logger: logger)

        // Transcription and external diarization are independent: both
        // consume the same audio file and produce disjoint segment streams.
        // Run them in parallel so the pipeline's wall time is dominated by
        // the slower of the two instead of their sum.
        async let transcriptionTask: TranscriptionOutput = backend.transcribe(
            audioURL: audioPath,
            language: language,
            numSpeakers: numSpeakers,
            onSegment: { _ in progressTracker.recordSegment() },
            onProgress: { progressTracker.recordProgress($0) },
        )

        async let externalDiarTask: [DiarSegment] = {
            guard runExternalDiarization else { return [] }
            return try await DiarizationService.diarize(
                audioURL: audioPath,
                numSpeakers: numSpeakers,
            )
        }()

        let output = try await transcriptionTask
        let externalDiar = try await externalDiarTask

        try Task.checkCancellation()

        let diarSegments = backend.producesDiarization ? output.diarSegments : externalDiar

        let labeled = TranscriptFormatter.assignSpeakers(
            whisperSegments: output.segments,
            diarSegments: diarSegments,
        )
        return TranscriptFormatter.format(labeled)
    }

    /// Construct the `TranscriptionBackend` the pipeline should use for this
    /// run, based on the current config. Called once per pipeline invocation
    /// so config changes take effect without app restart.
    ///
    /// For WhisperKit, the backend wraps the long-lived
    /// `transcriptionService` so repeated runs reuse the loaded model. Cloud
    /// backends are stateless and cheap to construct.
    ///
    /// Hebrew carve-out: even when the user has `google_stt_diarize = true`
    /// in config, we force `diarize: false` on the v1 backend so the
    /// pipeline falls through to Pyannote. Google's v1 diarization is
    /// unusable on Hebrew and users shouldn't need to toggle a second
    /// setting to opt out.
    private func makeTranscriptionBackend(
        config: AppConfig,
        language: String
    ) -> TranscriptionBackend {
        let kind = TranscriptionBackendKind.from(config.transcriptionBackend)
        switch kind {
        case .whisperkit:
            return WhisperKitBackend(
                service: transcriptionService,
                modelName: config.whisperModel,
                modelRepo: config.whisperModelRepo,
            )
        case .googleStt:
            let diarize = config.googleSttDiarize && !Self.shouldForcePyannote(language: language)
            return GoogleSTTBackend(
                location: config.googleSttLocation,
                model: config.googleSttModel,
                diarize: diarize,
            )
        case .googleSttV2:
            return GoogleSTTBackendV2(
                project: config.googleSttV2Project,
                region: config.googleSttV2Region,
                model: config.googleSttV2Model,
            )
        }
    }

    // MARK: - History re-runs

    /// Result of a pipeline operation.
    struct CLIResult {
        let ok: Bool
        let error: String
    }

    /// Re-transcribe a session from its audio.
    ///
    /// `languageOverride` wins over `config.language` when non-nil. Used by the
    /// session detail view to run Hebrew on one recording while the global
    /// default stays on English (or auto).
    func transcribeSession(
        _ session: URL,
        config: AppConfig,
        languageOverride: String? = nil
    ) async -> CLIResult {
        guard let audioPath = SessionManager.audioURL(in: session) else {
            return CLIResult(ok: false, error: "Audio file not found")
        }
        let language = languageOverride ?? config.language

        logger.info("re-transcribe: \(audioPath.path) lang=\(language)")

        let previousState = state
        state = .transcribing
        transcribingSession = session
        defer {
            transcribingSession = nil
            if case .transcribing = state { state = previousState }
        }

        let runLog = SessionLog(logPath: session.appendingPathComponent("run.log"))
        runLog.log(
            "re-transcribe started backend=\(config.transcriptionBackend) " +
            "model=\(modelForBackend(config: config)) lang=\(language)",
        )
        let started = Date()
        do {
            let result = try await transcribeAndFormat(
                audioPath: audioPath,
                language: language,
                config: config,
                logger: runLog,
            )
            try storeTranscript(
                result: result,
                session: session,
                config: config,
                language: language,
            )
            SessionManager.setLanguage(session, language)
            let elapsed = Date().timeIntervalSince(started)
            runLog.log("re-transcribe done in \(String(format: "%.1f", elapsed))s")
            return CLIResult(ok: true, error: "")
        } catch is CancellationError {
            logger.info("re-transcribe cancelled")
            runLog.log("re-transcribe cancelled")
            return CLIResult(ok: false, error: "Cancelled")
        } catch {
            logger.error("re-transcribe failed: \(error.localizedDescription)")
            runLog.log("re-transcribe failed: \(error.localizedDescription)")
            return CLIResult(ok: false, error: error.localizedDescription)
        }
    }

    /// Retry transcription for a session that previously failed (e.g. a
    /// long Hebrew recording that lost its connection partway through).
    /// Thin wrapper over `transcribeSession` that:
    ///   - resets `.error` state to `.idle` so the UI doesn't keep showing
    ///     the previous failure while the retry runs
    ///   - lets the underlying backend reuse its `.stt-cache` directory so
    ///     work already completed on the previous run isn't redone
    ///
    /// Called from the History row's "Retry" button and the session detail
    /// banner.
    func retryTranscription(_ session: URL, config: AppConfig) async -> CLIResult {
        if case .error = state { state = .idle }
        return await transcribeSession(session, config: config)
    }

    /// Optional one-shot overrides for a single re-summarize call.
    ///
    /// `backend`/`model` let the detail view pick a different LLM without
    /// touching the global config. `focus` is a free-form user note appended
    /// to the system prompt — typically "focus on X" — so people can steer
    /// a summary towards a topic without creating a new prompt profile.
    struct SummarizeOverrides {
        var backend: String?
        var model: String?
        var focus: String?
    }

    /// Re-summarize a session from its transcript.
    func summarizeSession(
        _ session: URL,
        config: AppConfig,
        profile: String?,
        overrides: SummarizeOverrides = .init()
    ) async -> CLIResult {
        let txPath = session.appendingPathComponent("transcript.txt")
        let smPath = session.appendingPathComponent("summary.md")

        guard FileManager.default.fileExists(atPath: txPath.path) else {
            return CLIResult(ok: false, error: "Transcript file not found")
        }

        let effectiveConfig = applyOverrides(overrides, to: config)
        logger.info(
            "re-summarize: \(txPath.path) backend=\(effectiveConfig.llmBackend) model=\(effectiveConfig.llmModel)"
        )

        let previousState = state
        state = .summarizing

        // Run inside a stored Task so `cancelProcessing` can tear it down
        // mid-stream — the caller's Task isn't reachable from the runner.
        let work: Task<CLIResult, Never> = Task { [weak self] in
            guard let self else { return CLIResult(ok: false, error: "Cancelled") }
            do {
                let transcript = try String(contentsOf: txPath, encoding: .utf8)
                let basePrompt = SummarizationService.loadPromptProfile(profile)
                let prompt = Self.composePrompt(base: basePrompt, focus: overrides.focus)
                _ = try await self.streamSummary(
                    session: session,
                    transcript: transcript,
                    summaryPath: smPath,
                    config: effectiveConfig,
                    prompt: prompt
                )
                return CLIResult(ok: true, error: "")
            } catch is CancellationError {
                return CLIResult(ok: false, error: "Cancelled")
            } catch {
                return CLIResult(ok: false, error: error.localizedDescription)
            }
        }
        summarizeTask = work
        let result = await work.value
        summarizeTask = nil
        if case .summarizing = state { state = previousState }

        if !result.ok, result.error == "Cancelled" {
            logger.info("re-summarize cancelled")
        } else if !result.ok {
            logger.error("re-summarize failed: \(result.error)")
        }
        return result
    }

    /// Produce a config with backend/model swapped when the caller supplied
    /// overrides. Keeps the original config untouched so the user's saved
    /// preferences aren't mutated by a one-off regenerate.
    private func applyOverrides(_ overrides: SummarizeOverrides, to config: AppConfig) -> AppConfig {
        var copy = config
        if let backend = overrides.backend, !backend.isEmpty {
            copy.llmBackend = backend
        }
        if let model = overrides.model, !model.isEmpty {
            copy.llmModel = model
        }
        return copy
    }

    /// Combine the profile prompt (or the built-in default) with an optional
    /// free-form focus instruction. Returns `nil` when there's nothing to
    /// override — the service will fall back to `defaultPrompt`.
    static func composePrompt(base: String?, focus: String?) -> String? {
        let trimmedFocus = focus?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedFocus, !trimmedFocus.isEmpty {
            let root = base ?? SummarizationService.defaultPrompt
            return root + "\n\nAdditional instructions from the user:\n" + trimmedFocus
        }
        return base
    }

    // MARK: - Logging helpers

    /// Resolve the model name for the active transcription backend so the
    /// session log captures the same value the user would see in Settings.
    fileprivate func modelForBackend(config: AppConfig) -> String {
        switch TranscriptionBackendKind.from(config.transcriptionBackend) {
        case .whisperkit:
            return AppConfig.canonicalWhisperModel(config.whisperModel)
        case .googleStt:
            return config.googleSttModel
        case .googleSttV2:
            return config.googleSttV2Model
        }
    }
}

// MARK: - TranscriptionProgressTracker

/// Throttles transcription progress + segment logging so a backend that
/// emits hundreds of `onProgress` callbacks per second doesn't drown the
/// session log. Crosses actor boundaries (the backend invokes the
/// callbacks from arbitrary executors), hence the lock-protected state
/// and `@unchecked Sendable` conformance.
private final class TranscriptionProgressTracker: @unchecked Sendable {
    private let logger: SessionLog
    private let lock = NSLock()
    private var lastLoggedDecile: Int = -1
    private var lastLogAt: Date = .distantPast
    private var segmentCount: Int = 0

    /// Don't emit more than one progress line per this many seconds even
    /// if multiple decile boundaries are crossed in quick succession.
    private let minInterval: TimeInterval = 5

    init(logger: SessionLog) {
        self.logger = logger
    }

    func recordProgress(_ value: Double) {
        let clamped = max(0, min(1, value))
        let decile = Int(clamped * 10)
        let now = Date()
        lock.lock()
        let shouldLog = decile > lastLoggedDecile && now.timeIntervalSince(lastLogAt) >= minInterval
        if shouldLog {
            lastLoggedDecile = decile
            lastLogAt = now
        }
        lock.unlock()
        if shouldLog {
            logger.log("transcription \(decile * 10)%")
        }
    }

    func recordSegment() {
        lock.lock()
        segmentCount += 1
        let count = segmentCount
        lock.unlock()
        if count % 50 == 0 {
            logger.log("transcription segments=\(count)")
        }
    }
}
