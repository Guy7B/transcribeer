import Foundation
import TOMLDecoder

public struct AppConfig: Equatable, Sendable {
    public var language: String = "auto"
    public var transcriptionBackend: String = "whisperkit"
    public var whisperModel: String = "openai_whisper-large-v3_turbo"
    public var whisperModelRepo: String = ""
    public var diarization: String = "pyannote"
    public var numSpeakers: Int = 0
    public var googleSttLocation: String = "global"
    public var googleSttModel: String = "default"
    public var googleSttDiarize: Bool = true
    public var googleSttV2Project: String = ""
    public var googleSttV2Region: String = "us"
    public var googleSttV2Model: String = "chirp_3"
    public var llmBackend: String = "ollama"
    public var llmModel: String = "llama3"
    public var ollamaHost: String = "http://localhost:11434"
    public var sessionsDir: String = "~/.transcribeer/sessions"
    public var pipelineMode: String = "record+transcribe+summarize"
    public var meetingAutoRecord: Bool = false
    public var promptOnStop: Bool = true
    public var audio = AudioSettings()

    public init() {}

    public struct AudioSettings: Equatable, Sendable {
        public var inputDeviceUID: String = ""
        public var outputDeviceUID: String = ""
        public var aec: AECMode = .auto
        public var selfLabel: String = "You"
        public var otherLabel: String = "Them"
        public var diarizeMicMultiuser: Bool = false

        public init() {}
    }
}

/// Acoustic echo cancellation mode for mic capture. Mirrors the GUI-side
/// `AECMode` enum; kept in `TranscribeerCore` so non-GUI consumers (CLI,
/// tests, external tools) can read/write the same config field.
public enum AECMode: String, CaseIterable, Equatable, Sendable {
    case auto
    case on
    case off
}

// Computed/static helpers live in an extension so the new `AECMode` enum can
// sit between the data definition and the helpers without splitting the
// struct body across two files.
extension AppConfig {
    public var expandedSessionsDir: String {
        (sessionsDir as NSString).expandingTildeInPath
    }

    public static let modelsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/models", isDirectory: true)
    }()
}

// MARK: - TOML file structures for decoding

private struct TOMLFile: Decodable {
    var pipeline: PipelineSection?
    var transcription: TranscriptionSection?
    var summarization: SummarizationSection?
    var paths: PathsSection?
    var audio: AudioSection?
}

private struct PipelineSection: Decodable {
    var mode: String?
    // swiftlint:disable:next discouraged_optional_boolean
    var meeting_auto_record: Bool?
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
    // swiftlint:disable:next discouraged_optional_boolean
    var google_stt_diarize: Bool?
    var google_stt_v2_project: String?
    var google_stt_v2_region: String?
    var google_stt_v2_model: String?
}

private struct SummarizationSection: Decodable {
    var backend: String?
    var model: String?
    var ollama_host: String?
    // swiftlint:disable:next discouraged_optional_boolean
    var prompt_on_stop: Bool?
}

private struct PathsSection: Decodable {
    var sessions_dir: String?
}

private struct AudioSection: Decodable {
    var input_device_uid: String?
    var output_device_uid: String?
    // Legacy boolean form (`aec = true | false`) preserved for backward
    // compatibility with config.toml files written before the auto/on/off
    // tri-state existed. New form below wins when both are present.
    // swiftlint:disable:next discouraged_optional_boolean
    var aec: Bool?
    var aec_mode: String?
    var self_label: String?
    var other_label: String?
    // swiftlint:disable:next discouraged_optional_boolean
    var diarize_mic_multiuser: Bool?
}

// MARK: - Load / Save

public enum ConfigManager {
    public static let configPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/config.toml")
    }()

    public static func load() -> AppConfig {
        var cfg = AppConfig()
        guard
            let data = try? Data(contentsOf: configPath),
            let toml = try? TOMLDecoder().decode(TOMLFile.self, from: data)
        else { return cfg }
        if let p = toml.pipeline { applyPipeline(p, to: &cfg) }
        if let t = toml.transcription { applyTranscription(t, to: &cfg) }
        if let s = toml.summarization { applySummarization(s, to: &cfg) }
        if let p = toml.paths { applyPaths(p, to: &cfg) }
        if let a = toml.audio { applyAudio(a, to: &cfg) }
        return cfg
    }

    private static func applyPipeline(_ section: PipelineSection, to cfg: inout AppConfig) {
        if let v = section.mode { cfg.pipelineMode = v }
        if let v = section.meeting_auto_record { cfg.meetingAutoRecord = v }
    }

    private static func applyTranscription(_ section: TranscriptionSection, to cfg: inout AppConfig) {
        if let v = section.backend { cfg.transcriptionBackend = v }
        if let v = section.language { cfg.language = v }
        if let v = section.model { cfg.whisperModel = v }
        if let v = section.model_repo { cfg.whisperModelRepo = v }
        if let v = section.diarization { cfg.diarization = v }
        if let v = section.num_speakers { cfg.numSpeakers = v }
        if let v = section.google_stt_location { cfg.googleSttLocation = v }
        if let v = section.google_stt_model { cfg.googleSttModel = v }
        if let v = section.google_stt_diarize { cfg.googleSttDiarize = v }
        if let v = section.google_stt_v2_project { cfg.googleSttV2Project = v }
        if let v = section.google_stt_v2_region { cfg.googleSttV2Region = v }
        if let v = section.google_stt_v2_model { cfg.googleSttV2Model = v }
    }

    private static func applySummarization(_ section: SummarizationSection, to cfg: inout AppConfig) {
        if let v = section.backend { cfg.llmBackend = v }
        if let v = section.model { cfg.llmModel = v }
        if let v = section.ollama_host { cfg.ollamaHost = v }
        if let v = section.prompt_on_stop { cfg.promptOnStop = v }
    }

    private static func applyPaths(_ section: PathsSection, to cfg: inout AppConfig) {
        if let v = section.sessions_dir { cfg.sessionsDir = v }
    }

    private static func applyAudio(_ section: AudioSection, to cfg: inout AppConfig) {
        if let v = section.input_device_uid { cfg.audio.inputDeviceUID = v }
        if let v = section.output_device_uid { cfg.audio.outputDeviceUID = v }
        if let v = resolveAECMode(modeString: section.aec_mode, legacyBool: section.aec) {
            cfg.audio.aec = v
        }
        if let v = section.self_label { cfg.audio.selfLabel = v }
        if let v = section.other_label { cfg.audio.otherLabel = v }
        if let v = section.diarize_mic_multiuser { cfg.audio.diarizeMicMultiuser = v }
    }

    /// Pick the AEC mode from whichever form the TOML file used. Mirrors
    /// `Models/Config.swift`'s helper so both AppConfig flavours migrate the
    /// same way. Returns `nil` when neither field was set so the caller
    /// preserves the existing default.
    private static func resolveAECMode(modeString: String?, legacyBool: Bool?) -> AECMode? {
        if let modeString, let parsed = AECMode(rawValue: modeString) {
            return parsed
        }
        if let legacyBool {
            return legacyBool ? .on : .off
        }
        return nil
    }

    public static func save(_ cfg: AppConfig) {
        let dir = configPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let lines = """
        [pipeline]
        mode = \(tomlString(cfg.pipelineMode))
        meeting_auto_record = \(cfg.meetingAutoRecord)

        [transcription]
        backend = \(tomlString(cfg.transcriptionBackend))
        language = \(tomlString(cfg.language))
        model = \(tomlString(cfg.whisperModel))
        model_repo = \(tomlString(cfg.whisperModelRepo))
        diarization = \(tomlString(cfg.diarization))
        num_speakers = \(cfg.numSpeakers)
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
        aec_mode = \(tomlString(cfg.audio.aec.rawValue))
        self_label = \(tomlString(cfg.audio.selfLabel))
        other_label = \(tomlString(cfg.audio.otherLabel))
        diarize_mic_multiuser = \(cfg.audio.diarizeMicMultiuser)
        """
        try? lines.write(to: configPath, atomically: true, encoding: .utf8)
    }

    /// Encode a string as a TOML basic string literal — wraps in quotes and
    /// escapes `\`, `"`, and control characters.  Without this, a path or
    /// label containing a quote or backslash would corrupt the file and
    /// prevent the next load.
    public static func tomlString(_ s: String) -> String {
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
