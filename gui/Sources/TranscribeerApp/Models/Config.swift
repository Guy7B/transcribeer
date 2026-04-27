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
    var pipelineMode: String = "record+transcribe+summarize"
    var meetingAutoRecord: Bool = false
    var meetingAutoRecordDelay: Int = 5
    /// Read meeting topic and participant list from the Zoom app via
    /// Accessibility while a recording is in progress. Covers both enrichments
    /// as a single on/off switch — disabling skips the AX walks entirely.
    var zoomEnricherEnabled: Bool = true
    /// Upper bound on how many participants we will observe and persist for a
    /// meeting. Large meetings (classrooms, town halls, webinars) would fill
    /// `meta.json` with churn that isn't useful for per-speaker transcription,
    /// so we skip collection entirely while the observed count exceeds this.
    /// Values `<= 0` disable participant capture.
    var maxMeetingParticipants: Int = 10
    var promptOnStop: Bool = true
    var audio = AudioSettings()

    var expandedSessionsDir: String {
        (sessionsDir as NSString).expandingTildeInPath
    }

    struct AudioSettings: Equatable {
        var inputDeviceUID: String = ""
        var outputDeviceUID: String = ""
        var aec: Bool = true
        var selfLabel: String = "You"
        var otherLabel: String = "Them"
        var diarizeMicMultiuser: Bool = false
    }
}

// MARK: - TOML file structures for decoding
//
// Optional booleans here intentionally distinguish "absent" from "present and
// false" during TOML decoding so we can fall back to the AppConfig default.
// swiftlint:disable discouraged_optional_boolean

struct TOMLFile: Decodable {
    var pipeline: PipelineSection?
    var transcription: TranscriptionSection?
    var summarization: SummarizationSection?
    var paths: PathsSection?
    var audio: AudioSection?
}

struct PipelineSection: Decodable {
    var mode: String?
    var meeting_auto_record: Bool?
    var meeting_auto_record_delay: Int?
    var zoom_enricher_enabled: Bool?
    var max_meeting_participants: Int?
}

struct TranscriptionSection: Decodable {
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

struct SummarizationSection: Decodable {
    var backend: String?
    var model: String?
    var ollama_host: String?
    var prompt_on_stop: Bool?
}

struct PathsSection: Decodable {
    var sessions_dir: String?
}

struct AudioSection: Decodable {
    var input_device_uid: String?
    var output_device_uid: String?
    var aec: Bool?
    var self_label: String?
    var other_label: String?
    var diarize_mic_multiuser: Bool?
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

        if let pipeline = toml.pipeline { applyPipeline(pipeline, to: &cfg) }
        if let transcription = toml.transcription { applyTranscription(transcription, to: &cfg) }
        if let summarization = toml.summarization { applySummarization(summarization, to: &cfg) }
        if let paths = toml.paths { applyPaths(paths, to: &cfg) }
        if let audio = toml.audio { applyAudio(audio, to: &cfg) }
        return cfg
    }

    private static func applyPipeline(_ s: PipelineSection, to cfg: inout AppConfig) {
        cfg.pipelineMode = s.mode ?? cfg.pipelineMode
        cfg.meetingAutoRecord = s.meeting_auto_record ?? cfg.meetingAutoRecord
        if let delay = s.meeting_auto_record_delay, delay >= 0 {
            cfg.meetingAutoRecordDelay = delay
        }
        if let maxParticipants = s.max_meeting_participants {
            cfg.maxMeetingParticipants = maxParticipants
        }
        cfg.zoomEnricherEnabled = s.zoom_enricher_enabled ?? cfg.zoomEnricherEnabled
    }

    private static func applyTranscription(_ s: TranscriptionSection, to cfg: inout AppConfig) {
        cfg.transcriptionBackend = s.backend ?? cfg.transcriptionBackend
        cfg.language = s.language ?? cfg.language
        cfg.whisperModel = s.model.map(AppConfig.canonicalWhisperModel) ?? cfg.whisperModel
        cfg.whisperModelRepo = s.model_repo ?? cfg.whisperModelRepo
        cfg.diarization = s.diarization ?? cfg.diarization
        cfg.numSpeakers = s.num_speakers ?? cfg.numSpeakers
        cfg.googleSttLocation = s.google_stt_location ?? cfg.googleSttLocation
        cfg.googleSttModel = s.google_stt_model ?? cfg.googleSttModel
        cfg.googleSttDiarize = s.google_stt_diarize ?? cfg.googleSttDiarize
        cfg.googleSttV2Project = s.google_stt_v2_project ?? cfg.googleSttV2Project
        cfg.googleSttV2Region = s.google_stt_v2_region ?? cfg.googleSttV2Region
        cfg.googleSttV2Model = s.google_stt_v2_model ?? cfg.googleSttV2Model
    }

    private static func applySummarization(_ s: SummarizationSection, to cfg: inout AppConfig) {
        cfg.llmBackend = s.backend ?? cfg.llmBackend
        cfg.llmModel = s.model ?? cfg.llmModel
        cfg.ollamaHost = s.ollama_host ?? cfg.ollamaHost
        cfg.promptOnStop = s.prompt_on_stop ?? cfg.promptOnStop
    }

    private static func applyPaths(_ s: PathsSection, to cfg: inout AppConfig) {
        cfg.sessionsDir = s.sessions_dir ?? cfg.sessionsDir
    }

    private static func applyAudio(_ s: AudioSection, to cfg: inout AppConfig) {
        cfg.audio.inputDeviceUID = s.input_device_uid ?? cfg.audio.inputDeviceUID
        cfg.audio.outputDeviceUID = s.output_device_uid ?? cfg.audio.outputDeviceUID
        cfg.audio.aec = s.aec ?? cfg.audio.aec
        cfg.audio.selfLabel = s.self_label ?? cfg.audio.selfLabel
        cfg.audio.otherLabel = s.other_label ?? cfg.audio.otherLabel
        cfg.audio.diarizeMicMultiuser = s.diarize_mic_multiuser ?? cfg.audio.diarizeMicMultiuser
    }

    static func save(_ cfg: AppConfig) {
        let dir = configPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let speakers = cfg.numSpeakers
        let lines = """
        [pipeline]
        mode = \(tomlString(cfg.pipelineMode))
        meeting_auto_record = \(cfg.meetingAutoRecord)
        meeting_auto_record_delay = \(cfg.meetingAutoRecordDelay)
        max_meeting_participants = \(cfg.maxMeetingParticipants)
        zoom_enricher_enabled = \(cfg.zoomEnricherEnabled)

        [transcription]
        backend = \(tomlString(cfg.transcriptionBackend))
        language = \(tomlString(cfg.language))
        model = \(tomlString(cfg.whisperModel))
        model_repo = \(tomlString(cfg.whisperModelRepo))
        diarization = \(tomlString(cfg.diarization))
        num_speakers = \(speakers)
        google_stt_location = \(tomlString(cfg.googleSttLocation))
        google_stt_model = \(tomlString(cfg.googleSttModel))
        google_stt_diarize = \(cfg.googleSttDiarize)
        google_stt_v2_project = \(tomlString(cfg.googleSttV2Project))
        google_stt_v2_region = \(tomlString(cfg.googleSttV2Region))
        google_stt_v2_model = \(tomlString(cfg.googleSttV2Model))

        [summarization]
        backend = \(tomlString(cfg.llmBackend))
        model = \(tomlString(cfg.llmModel))
        ollama_host = \(tomlString(cfg.ollamaHost))
        prompt_on_stop = \(cfg.promptOnStop)

        [paths]
        sessions_dir = \(tomlString(cfg.sessionsDir))

        [audio]
        input_device_uid = \(tomlString(cfg.audio.inputDeviceUID))
        output_device_uid = \(tomlString(cfg.audio.outputDeviceUID))
        aec = \(cfg.audio.aec)
        self_label = \(tomlString(cfg.audio.selfLabel))
        other_label = \(tomlString(cfg.audio.otherLabel))
        diarize_mic_multiuser = \(cfg.audio.diarizeMicMultiuser)
        """
        try? lines.write(to: configPath, atomically: true, encoding: .utf8)
    }

    /// Encode a string as a TOML basic string literal — wraps in quotes and
    /// escapes the characters TOML requires (`\`, `"`, and common control
    /// characters).  Without this, a user label containing a quote or a
    /// backslash would corrupt the file and prevent the next load.
    static func tomlString(_ s: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(s.count + 2)
        for ch in s {
            switch ch {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case "\u{08}": escaped += "\\b"
            case "\u{0C}": escaped += "\\f"
            default:
                // TOML basic strings forbid control chars (0x00–0x1F, 0x7F)
                // other than tab; encode via \uXXXX.
                let scalar = ch.unicodeScalars.first.map { $0.value } ?? 0
                if scalar < 0x20 || scalar == 0x7F {
                    escaped += String(format: "\\u%04X", scalar)
                } else {
                    escaped.append(ch)
                }
            }
        }
        return "\"\(escaped)\""
    }
}
