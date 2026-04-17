import Foundation

/// Supported summarization backends.
public enum LLMBackend: String, CaseIterable, Identifiable, Sendable {
    case ollama
    case openai
    case anthropic
    case gemini

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    public var envVar: String? {
        switch self {
        case .openai: "OPENAI_API_KEY"
        case .anthropic: "ANTHROPIC_API_KEY"
        case .gemini, .ollama: nil
        }
    }

    public enum AuthMode: Equatable, Sendable {
        case apiKey
        case gcloudADC
        case localEndpoint
    }

    public var auth: AuthMode {
        switch self {
        case .openai, .anthropic: .apiKey
        case .gemini: .gcloudADC
        case .ollama: .localEndpoint
        }
    }

    public static func from(_ raw: String) -> Self {
        Self(rawValue: raw) ?? .ollama
    }
}
