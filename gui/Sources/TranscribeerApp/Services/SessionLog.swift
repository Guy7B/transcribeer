import Foundation
import os.log

/// Per-session log sink. Appends timestamped lines to `run.log` while
/// mirroring every entry to the unified Apple log under
/// `com.transcribeer / pipeline.session` so live diagnostics from a running
/// app are visible via `log stream` without having to tail a file inside
/// `~/.transcribeer/sessions/<id>/`.
///
/// `SessionLog` is reference-typed because the same instance is threaded
/// through every pipeline stage (capture → transcription → summarization)
/// and can be passed across actor hops; an `NSLock` guards file-handle
/// reuse so concurrent stages don't interleave bytes mid-line.
final class SessionLog: @unchecked Sendable {

    // MARK: - Stored

    let logPath: URL
    private let lock = NSLock()
    private let osLogger = Logger(subsystem: "com.transcribeer", category: "pipeline.session")

    // MARK: - Init

    init(logPath: URL) {
        self.logPath = logPath
    }

    // MARK: - API

    /// Append a single line to `run.log` and mirror it to os.log.
    ///
    /// Mirroring uses `.public` privacy because session logs already contain
    /// only paths/durations/sizes/model names — never API keys, transcript
    /// content, or prompts (see AGENTS.md). Keeping them public makes the
    /// stream usable from `log stream --predicate ...` without sudo.
    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(
            from: Date(),
            dateStyle: .none,
            timeStyle: .medium,
        )
        let line = "[\(timestamp)] \(message)\n"
        let data = Data(line.utf8)

        lock.lock()
        defer { lock.unlock() }

        if let handle = try? FileHandle(forWritingTo: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logPath)
        }

        osLogger.info("\(message, privacy: .public)")
    }
}
