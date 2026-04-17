import Foundation
import CaptureCore
import CoreGraphics

/// Wraps CaptureCore's AudioCapture for use inside the GUI app.
/// Runs in-process so TCC permission is checked against TranscribeerApp, not capture-bin.
enum CaptureService {

    enum CaptureResult {
        case recorded
        case noAudio
        case permissionDenied
        case error(String)
    }

    /// Record audio to `audioPath` until `stop()` is called or `duration` elapses.
    /// Returns a task that completes when recording finishes.
    static func record(to audioPath: URL, duration: Double?) async -> CaptureResult {
        let writer = WAVWriter.shared
        do {
            try writer.open(path: audioPath.path)
        } catch {
            return .error("Cannot open output file: \(error.localizedDescription)")
        }

        do {
            try await AudioCapture.shared.start(writer: writer)
        } catch {
            writer.close()
            let ns = error as NSError
            let detail = "SCKit error \(ns.domain)/\(ns.code): \(ns.localizedDescription)"
            if ns.code == -3801 || ns.localizedDescription.lowercased().contains("not authorized") {
                return .permissionDenied
            }
            return .error(detail)
        }

        if let duration {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            AudioCapture.shared.stop()
            writer.close()
        }
        // If no duration, caller stops via stopRecording()

        let size = (try? FileManager.default.attributesOfItem(
            atPath: audioPath.path
        )[.size] as? UInt64) ?? 0
        return size > 0 ? .recorded : .noAudio
    }

    static func stop() {
        AudioCapture.shared.stop()
        WAVWriter.shared.close()
    }

    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }
}
