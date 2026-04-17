import CaptureCore
import Foundation

/// Thin façade over `AudioCapture` + `AudioFileWriter` for the GUI pipeline.
enum CaptureService {
    enum Result {
        case recorded
        case noAudio
        case permissionDenied
        case error(String)
    }

    /// Record system audio to `url` until `stop()` is called (or `duration` seconds elapse).
    static func record(to url: URL, duration: Double?) async -> Result {
        let writer = AudioFileWriter.shared
        do {
            try writer.open(url: url)
        } catch {
            return .error("Cannot open output file: \(error.localizedDescription)")
        }

        do {
            try await AudioCapture.shared.start(writer: writer)
        } catch {
            writer.close()
            let msg = error.localizedDescription
            if msg.contains("Screen & System Audio Recording") || msg.contains("TCC") {
                return .permissionDenied
            }
            return .error(msg)
        }

        if let duration {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            AudioCapture.shared.stop()
        } else {
            // Wait until stop() is called externally (stream delegate fires onStreamStopped).
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                AudioCapture.shared.onStreamStopped = {
                    continuation.resume()
                }
            }
        }

        writer.close()

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        return size > 0 ? .recorded : .noAudio
    }

    /// Signal the active recording to stop.
    static func stop() {
        AudioCapture.shared.stop()
    }
}
