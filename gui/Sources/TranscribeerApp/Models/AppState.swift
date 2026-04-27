import TranscribeerCore
import Foundation

/// Single source of truth for the app's pipeline state.
enum AppState: Equatable {
    case idle
    case recording(startTime: Date)
    case transcribing
    case summarizing
    case done(sessionPath: String)
    case error(message: String, sessionPath: String?, kind: ErrorKind)

    /// Categorises which pipeline stage produced the failure so the UI can
    /// pick an icon/wording and route the retry button to the right action.
    /// Kept narrow on purpose — this is what the UI cares about, not a full
    /// taxonomy of every underlying error type.
    enum ErrorKind: Equatable {
        case transcription
        case recording
        case summarization
        case other
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isBusy: Bool {
        switch self {
        case .recording, .transcribing, .summarizing: return true
        default: return false
        }
    }

    var menuBarIcon: String {
        switch self {
        case .idle: return "mic"
        case .recording: return "record.circle.fill"
        case .transcribing, .summarizing: return "ellipsis.circle"
        case .done: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    var statusText: String {
        switch self {
        case .idle: return ""
        case .recording(let start): return Self.recordingText(from: start)
        case .transcribing: return "📝 Transcribing…"
        case .summarizing: return "🤔 Summarizing…"
        case .done: return "✓ Done"
        case .error(let msg, _, _): return "⚠ \(msg)"
        }
    }

    /// Convenience for callers that just want the message (legacy callsites,
    /// menubar dropdown, etc.) without unpacking the full payload.
    var errorMessage: String? {
        if case .error(let msg, _, _) = self { return msg }
        return nil
    }

    /// Session path attached to the failure, if any. Used by the UI to wire
    /// "Open log" / "Reveal in Finder" / "Retry" actions.
    var errorSessionPath: String? {
        if case .error(_, let path, _) = self { return path }
        return nil
    }

    var errorKind: ErrorKind? {
        if case .error(_, _, let kind) = self { return kind }
        return nil
    }

    private static func recordingText(from start: Date) -> String {
        let elapsed = Int(Date().timeIntervalSince(start))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return String(format: "⏺ Recording  %02d:%02d", minutes, seconds)
    }
}
