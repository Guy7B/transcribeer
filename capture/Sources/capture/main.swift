import Foundation
import CoreGraphics
import CaptureCore

// ── 1. Parse args ────────────────────────────────────────────────────────────
let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("Usage: capture <output.m4a> [duration_seconds]\n", stderr)
    exit(1)
}
let outputPath = args[1]
var autoDuration: Double? = nil
if args.count >= 3 {
    guard let d = Int(args[2]), d > 0 else {
        fputs("Invalid duration: '\(args[2])'. Must be a positive integer (seconds).\n", stderr)
        exit(1)
    }
    autoDuration = Double(d)
}

// ── 2. Permission check ──────────────────────────────────────────────────────
guard CGPreflightScreenCaptureAccess() else {
    // Trigger the system dialog so the user knows where to go
    CGRequestScreenCaptureAccess()
    fputs("Grant \"Screen & System Audio Recording\" to your terminal in System Settings → Privacy & Security, then re-run.\n", stderr)
    exit(1)
}

// ── 3. Open audio writer ─────────────────────────────────────────────────────
let writer = AudioFileWriter.shared
do {
    try writer.open(url: URL(fileURLWithPath: outputPath))
} catch {
    fputs("Cannot write to \(outputPath): \(error)\n", stderr)
    exit(1)
}

// ── 4. Shutdown helper (called from SIGINT and auto-stop) ───────────────────
var stopped = false
let startTime = Date()
func shutdown() {
    AudioCapture.shared.stop()
    AudioFileWriter.shared.close()
    let elapsed = Int(Date().timeIntervalSince(startTime))
    let m = elapsed / 60, s = elapsed % 60
    let size = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
    fputs("\nDone. [\(String(format: "%02d:%02d", m, s))] \(String(format: "%.1f", Double(size) / 1_048_576)) MB → \(outputPath)\n", stderr)
}

// ── 5. SIGINT handler ────────────────────────────────────────────────────────
signal(SIGINT, SIG_IGN)
let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSrc.setEventHandler {
    guard !stopped else { return }
    stopped = true
    shutdown()
    exit(0)
}
sigintSrc.resume()

// ── 6. Auto-stop ─────────────────────────────────────────────────────────────
if let duration = autoDuration {
    DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
        guard !stopped else { return }
        stopped = true
        shutdown()
        exit(0)
    }
}

// ── 7. Start capture ─────────────────────────────────────────────────────────
AudioCapture.shared.onStreamStopped = {
    guard !stopped else { return }
    stopped = true
    shutdown()
    exit(0)
}

fputs("Recording → \(outputPath)  (Ctrl+C to stop)\n", stderr)
Task {
    do {
        try await AudioCapture.shared.start(writer: writer)
    } catch {
        fputs("Failed to start audio capture: \(error)\n", stderr)
        exit(1)
    }
}

// ── 8. Ticker (updates every second on stderr) ───────────────────────────────
let ticker = DispatchSource.makeTimerSource(queue: .main)
ticker.schedule(deadline: .now() + 1, repeating: 1.0)
ticker.setEventHandler {
    let elapsed = Int(Date().timeIntervalSince(startTime))
    let m = elapsed / 60, s = elapsed % 60
    let size = (try? FileManager.default.attributesOfItem(atPath: outputPath)[.size] as? Int) ?? 0
    fputs("\r[\(String(format: "%02d:%02d", m, s))] \(String(format: "%.1f", Double(size) / 1_048_576)) MB  ", stderr)
}
ticker.resume()

// ── 9. Run loop ───────────────────────────────────────────────────────────────
RunLoop.main.run()
