import AppKit
import Foundation
import os.log

/// Read-only helpers for inspecting a session's `run.log` from the UI.
///
/// Kept separate from `SessionLog` (which owns writes) so the UI surface
/// doesn't drag a writable file handle into views that just want to peek
/// at the last error or open the log in Console.app.
enum RunLogReader {

    private static let logger = Logger(subsystem: "com.transcribeer", category: "run_log_reader")

    /// Last line in `run.log` that begins with "Transcription failed:",
    /// stripped of its timestamp prefix and the "Transcription failed: "
    /// header. Returns `nil` when the file is missing, unreadable, or
    /// doesn't contain a failure entry.
    ///
    /// Used by the session detail banner to surface a recent failure
    /// without re-running the pipeline.
    static func lastError(in session: URL) -> String? {
        let logPath = session.appendingPathComponent("run.log")
        guard let contents = try? String(contentsOf: logPath, encoding: .utf8) else {
            return nil
        }
        // Walk the file backwards line-by-line — recordings produce a few
        // hundred lines of progress logging, so this is cheap.
        let lines = contents.split(whereSeparator: \.isNewline)
        for raw in lines.reversed() {
            let line = String(raw)
            guard let payload = stripTimestamp(line) else { continue }
            if payload.hasPrefix("Transcription failed: ") {
                return String(payload.dropFirst("Transcription failed: ".count))
            }
            // Older-style capture failures or generic pipeline aborts.
            if payload.hasPrefix("capture failed: ") {
                return String(payload.dropFirst("capture failed: ".count))
            }
        }
        return nil
    }

    /// Open the session's `run.log` in the user's default text editor.
    /// No-ops silently if the file is missing — the UI guards on
    /// `lastError` returning non-nil before exposing the button.
    static func openRunLog(in session: URL) {
        let logPath = session.appendingPathComponent("run.log")
        guard FileManager.default.fileExists(atPath: logPath.path) else {
            logger.info("openRunLog: missing log at \(logPath.path, privacy: .public)")
            return
        }
        NSWorkspace.shared.open(logPath)
    }

    /// Reveal the session directory in Finder with the audio file (or the
    /// run log if there's no audio yet) selected.
    static func revealInFinder(_ session: URL) {
        let logPath = session.appendingPathComponent("run.log")
        let audioPath = session.appendingPathComponent("audio.m4a")
        let target: URL
        if FileManager.default.fileExists(atPath: audioPath.path) {
            target = audioPath
        } else if FileManager.default.fileExists(atPath: logPath.path) {
            target = logPath
        } else {
            target = session
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    // MARK: - Helpers

    /// Strip the leading `[HH:MM:SS] ` timestamp written by `SessionLog`.
    /// Returns `nil` for lines that don't match the expected shape — those
    /// aren't messages we logged, so they aren't candidates for "last
    /// error".
    private static func stripTimestamp(_ line: String) -> String? {
        // Format: "[12:34:56] message" — bracket at 0, close-bracket at 9,
        // space at 10, body from 11. We tolerate slightly different widths
        // (e.g. localised AM/PM suffix) by scanning to the close-bracket.
        guard line.first == "[" else { return nil }
        guard let closeIdx = line.firstIndex(of: "]") else { return nil }
        let after = line.index(after: closeIdx)
        guard after < line.endIndex else { return nil }
        let body = line[after...].drop(while: { $0 == " " })
        return String(body)
    }
}
