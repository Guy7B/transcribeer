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
    public var captureBin: String = Self.defaultCaptureBin()
    public var pipelineMode: String = "record+transcribe+summarize"
    public var zoomAutoRecord: Bool = false
    public var promptOnStop: Bool = true

    public init() {}

    public var expandedSessionsDir: String {
        (sessionsDir as NSString).expandingTildeInPath
    }

    public var expandedCaptureBin: String {
        (captureBin as NSString).expandingTildeInPath
    }

    public static func defaultCaptureBin() -> String {
        // 1. Bundled inside .app — inherits TCC from parent app (preferred)
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "capture-bin") {
            return bundled.path
        }
        // 2. Homebrew install
        let brewPath = "/opt/homebrew/opt/transcribeer/libexec/bin/capture-bin"
        if FileManager.default.fileExists(atPath: brewPath) {
            return brewPath
        }
        // 3. Manual install
        return "~/.transcribeer/bin/capture-bin"
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
}

private struct PipelineSection: Decodable {
    var mode: String?
    // swiftlint:disable:next discouraged_optional_boolean
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
    var capture_bin: String?
}

// MARK: - Load / Save

public enum ConfigManager {
    public static let configPath: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/config.toml")
    }()

    public static func load() -> AppConfig {
        var cfg = AppConfig()
        guard let data = try? Data(contentsOf: configPath) else { return cfg }
        guard let toml = try? TOMLDecoder().decode(TOMLFile.self, from: data) else { return cfg }
        if let p = toml.pipeline { applyPipeline(p, to: &cfg) }
        if let t = toml.transcription { applyTranscription(t, to: &cfg) }
        if let s = toml.summarization { applySummarization(s, to: &cfg) }
        if let p = toml.paths { applyPaths(p, to: &cfg) }
        return cfg
    }

    private static func applyPipeline(_ section: PipelineSection, to cfg: inout AppConfig) {
        if let v = section.mode { cfg.pipelineMode = v }
        if let v = section.zoom_auto_record { cfg.zoomAutoRecord = v }
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
        if let v = section.capture_bin { cfg.captureBin = v }
    }

    public static func save(_ cfg: AppConfig) {
        let dir = configPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

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
        num_speakers = \(cfg.numSpeakers)
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
