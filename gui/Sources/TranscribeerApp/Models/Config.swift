import Foundation
import TOMLDecoder

/// Mirrors ~/.transcribeer/config.toml.
struct AppConfig: Equatable {
    var language: String = "auto"
    var transcriptionBackend: String = "whisperkit"
    var whisperModel: String = "openai_whisper-large-v3_turbo"
    var whisperModelRepo: String = ""
    var diarization: String = "pyannote"
    var numSpeakers: Int = 0
    /// Google Speech-to-Text v2 `recognizer` location. `"global"` works for
    /// non-EU-residency users; EU users should set `"eu"`. Only consulted
    /// when `transcriptionBackend == "google_stt"` and we later move to v2.
    var googleSttLocation: String = "global"
    /// Google STT v1 model. `"default"` is the safest choice: it's the only
    /// v1 model Google currently enables for Hebrew (probed 2026-04-23).
    /// `"latest_long"` gives better English accuracy but rejects `he-IL`
    /// server-side with `"model is not supported for language : iw-IL"`.
    var googleSttModel: String = "default"
    /// When true and the v1 Google backend is active, request inline
    /// diarization and skip the external Pyannote pass. Ignored for v2:
    /// Chirp 3 doesn't support Hebrew diarization so we always run Pyannote
    /// externally. Regardless of this flag, the pipeline auto-disables
    /// Google diarization for Hebrew because its v1 diarization is broken
    /// there (see `PipelineRunner.makeTranscriptionBackend`).
    var googleSttDiarize: Bool = true
    /// GCP project ID for Google STT v2 (Chirp). Required when
    /// `transcriptionBackend == "google_stt_v2"`. Stored in config (not
    /// Keychain) because it's not secret — the bearer token is the secret
    /// and that comes from `gcloud`.
    var googleSttV2Project: String = ""
    /// Regional endpoint for v2. Chirp 3 lives in `"us"` and `"eu"` multi-
    /// regions; Chirp 2 uses single regions like `"us-central1"`. Default
    /// matches Chirp 3.
    var googleSttV2Region: String = "us"
    /// v2 model. `chirp_3` handles Hebrew best; `chirp_2` and `latest_long`
    /// exist for other languages. Users can type any valid model ID into
    /// config.toml.
    var googleSttV2Model: String = "chirp_3"
    var llmBackend: String = "ollama"
    var llmModel: String = "llama3"
    var ollamaHost: String = "http://localhost:11434"
    var sessionsDir: String = "~/.transcribeer/sessions"
    var captureBin: String = Self.defaultCaptureBin()
    var pipelineMode: String = "record+transcribe+summarize"
    var zoomAutoRecord: Bool = false
    var promptOnStop: Bool = true

    var expandedSessionsDir: String {
        (sessionsDir as NSString).expandingTildeInPath
    }

    var expandedCaptureBin: String {
        (captureBin as NSString).expandingTildeInPath
    }

    static func defaultCaptureBin() -> String {
        let brewPath = "/opt/homebrew/opt/transcribeer/libexec/bin/capture-bin"
        if FileManager.default.fileExists(atPath: brewPath) {
            return brewPath
        }
        return "~/.transcribeer/bin/capture-bin"
    }
}

// MARK: - TOML file structures for decoding
//
// Optional booleans here intentionally distinguish "absent" from "present and
// false" during TOML decoding so we can fall back to the AppConfig default.
// swiftlint:disable discouraged_optional_boolean

private struct TOMLFile: Decodable {
    var pipeline: PipelineSection?
    var transcription: TranscriptionSection?
    var summarization: SummarizationSection?
    var paths: PathsSection?
}

private struct PipelineSection: Decodable {
    var mode: String?
    var zoom_auto_record: Bool?
}

private struct TranscriptionSection: Decodable {
    var backend: String?
    var language: String?
    var model: String?
    var model_repo: String?
    var diarization: String?
    var num_speakers: Int?
    var google_stt_location: String?
    var google_stt_model: String?
    var google_stt_diarize: Bool?
    var google_stt_v2_project: String?
    var google_stt_v2_region: String?
    var google_stt_v2_model: String?
}

private struct SummarizationSection: Decodable {
    var backend: String?
    var model: String?
    var ollama_host: String?
    var prompt_on_stop: Bool?
}

private struct PathsSection: Decodable {
    var sessions_dir: String?
    var capture_bin: String?
}

// swiftlint:enable discouraged_optional_boolean

// MARK: - Load / Save

extension AppConfig {
    /// Migrate legacy short model names (e.g. `"large-v3-turbo"`) to the
    /// canonical WhisperKit identifiers that match the HuggingFace repo folders.
    /// WhisperKit resolves models via glob on the folder name, so the hyphenated
    /// legacy names match nothing and throw `modelsUnavailable`.
    static func canonicalWhisperModel(_ name: String) -> String {
        switch name {
        case "tiny": "openai_whisper-tiny"
        case "base": "openai_whisper-base"
        case "small": "openai_whisper-small"
        case "medium": "openai_whisper-medium"
        case "large-v2": "openai_whisper-large-v2"
        case "large-v3": "openai_whisper-large-v3"
        case "large-v3-turbo", "large-v3_turbo": "openai_whisper-large-v3_turbo"
        default: name
        }
    }
}

enum ConfigManager {
    static let configPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/config.toml")
    }()

    static func load() -> AppConfig {
        var cfg = AppConfig()
        guard
            let data = try? Data(contentsOf: configPath),
            let toml = try? TOMLDecoder().decode(TOMLFile.self, from: data)
        else { return cfg }

        if let pipeline = toml.pipeline {
            cfg.pipelineMode = pipeline.mode ?? cfg.pipelineMode
            cfg.zoomAutoRecord = pipeline.zoom_auto_record ?? cfg.zoomAutoRecord
        }
        if let transcription = toml.transcription {
            cfg.transcriptionBackend = transcription.backend ?? cfg.transcriptionBackend
            cfg.language = transcription.language ?? cfg.language
            cfg.whisperModel = transcription.model.map(AppConfig.canonicalWhisperModel) ?? cfg.whisperModel
            cfg.whisperModelRepo = transcription.model_repo ?? cfg.whisperModelRepo
            cfg.diarization = transcription.diarization ?? cfg.diarization
            cfg.numSpeakers = transcription.num_speakers ?? cfg.numSpeakers
            cfg.googleSttLocation = transcription.google_stt_location ?? cfg.googleSttLocation
            cfg.googleSttModel = transcription.google_stt_model ?? cfg.googleSttModel
            cfg.googleSttDiarize = transcription.google_stt_diarize ?? cfg.googleSttDiarize
            cfg.googleSttV2Project = transcription.google_stt_v2_project ?? cfg.googleSttV2Project
            cfg.googleSttV2Region = transcription.google_stt_v2_region ?? cfg.googleSttV2Region
            cfg.googleSttV2Model = transcription.google_stt_v2_model ?? cfg.googleSttV2Model
        }
        if let summarization = toml.summarization {
            cfg.llmBackend = summarization.backend ?? cfg.llmBackend
            cfg.llmModel = summarization.model ?? cfg.llmModel
            cfg.ollamaHost = summarization.ollama_host ?? cfg.ollamaHost
            cfg.promptOnStop = summarization.prompt_on_stop ?? cfg.promptOnStop
        }
        if let paths = toml.paths {
            cfg.sessionsDir = paths.sessions_dir ?? cfg.sessionsDir
            cfg.captureBin = paths.capture_bin ?? cfg.captureBin
        }
        return cfg
    }

    static func save(_ cfg: AppConfig) {
        let dir = configPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let speakers = cfg.numSpeakers
        let lines = """
        [pipeline]
        mode = "\(cfg.pipelineMode)"
        zoom_auto_record = \(cfg.zoomAutoRecord)

        [transcription]
        backend = "\(cfg.transcriptionBackend)"
        language = "\(cfg.language)"
        model = "\(cfg.whisperModel)"
        model_repo = "\(cfg.whisperModelRepo)"
        diarization = "\(cfg.diarization)"
        num_speakers = \(speakers)
        google_stt_location = "\(cfg.googleSttLocation)"
        google_stt_model = "\(cfg.googleSttModel)"
        google_stt_diarize = \(cfg.googleSttDiarize)
        google_stt_v2_project = "\(cfg.googleSttV2Project)"
        google_stt_v2_region = "\(cfg.googleSttV2Region)"
        google_stt_v2_model = "\(cfg.googleSttV2Model)"

        [summarization]
        backend = "\(cfg.llmBackend)"
        model = "\(cfg.llmModel)"
        ollama_host = "\(cfg.ollamaHost)"
        prompt_on_stop = \(cfg.promptOnStop)

        [paths]
        sessions_dir = "\(cfg.sessionsDir)"
        capture_bin = "\(cfg.captureBin)"
        """
        try? lines.write(to: configPath, atomically: true, encoding: .utf8)
    }
}
