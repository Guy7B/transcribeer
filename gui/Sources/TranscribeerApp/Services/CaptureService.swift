import AVFoundation
import CaptureCore
import Foundation
import os

private let logger = Logger(subsystem: "com.transcribeer", category: "CaptureService")

/// Thin façade over `DualAudioRecorder` + `AudioMixer` for the GUI pipeline.
enum CaptureService {
    enum Result {
        case recorded
        case noAudio
        case permissionDenied(String)
        case error(String)
    }

    private static let lock = NSLock()
    private static var stopContinuation: CheckedContinuation<Void, Never>?
    /// Set by `stop()` so an early click doesn't get lost between
    /// `recorder.start()` returning and the wait-for-stop task actually
    /// installing the continuation. Reset at the start of every `record()`.
    private static var stopRequested = false

    // MARK: - Private helpers

    private static func resolveMicDevice(uid: String) -> AudioDeviceID? {
        resolveDevice(uid: uid, kind: "Microphone", lookup: MicCapture.inputDeviceID(forUID:))
    }

    private static func resolveOutputDevice(uid: String) -> AudioDeviceID? {
        resolveDevice(uid: uid, kind: "Output device", lookup: SystemAudioCapture.outputDeviceID(forUID:))
    }

    private static func resolveDevice(
        uid: String,
        kind: String,
        lookup: (String) -> AudioDeviceID?
    ) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        if let id = lookup(uid) { return id }
        let message = "\(kind) '\(uid)' not found. Falling back to system default."
        logger.warning("\(message, privacy: .public)")
        NotificationManager.notifyError(message)
        return nil
    }

    private static let micDeniedMessage =
        "Microphone access denied. Enable Microphone in System Settings > Privacy & Security."

    private static func preflightMic() async -> Result? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? nil : .permissionDenied(micDeniedMessage)
        case .denied, .restricted:
            return .permissionDenied(micDeniedMessage)
        case .authorized:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Record to `sessionDir` (creates `audio.mic.caf`, `audio.sys.caf`,
    /// `timing.json`, and mixed `audio.m4a`).
    static func record(
        to sessionDir: URL,
        duration: Double?,
        audio: AppConfig.AudioSettings
    ) async -> Result {
        if let result = await preflightMic() { return result }

        lock.withLock {
            stopRequested = false
            stopContinuation = nil
        }

        let recorder = DualAudioRecorder(sessionDir: sessionDir)
        recorder.inputDeviceID = resolveMicDevice(uid: audio.inputDeviceUID)
        recorder.outputDeviceID = resolveOutputDevice(uid: audio.outputDeviceUID)
        let aec = resolveEchoCancellation(audio: audio, outputDeviceID: recorder.outputDeviceID)
        recorder.echoCancellation = aec.enabled
        logger.info("aec mode=\(audio.aec.rawValue, privacy: .public) reason=\(aec.reason, privacy: .public) → enabled=\(aec.enabled, privacy: .public)")

        do {
            try await recorder.start()
        } catch let error as SystemAudioCapture.CaptureError {
            return .permissionDenied(error.localizedDescription)
        } catch {
            return .error(error.localizedDescription)
        }

        let stopTask = Task {
            if let duration {
                // Poll the stop flag so a user click can end a fixed-duration
                // recording early. 100 ms granularity keeps the overhead low
                // and the latency imperceptible.
                let pollNanos: UInt64 = 100_000_000
                let totalNanos = UInt64(duration * 1_000_000_000)
                var elapsed: UInt64 = 0
                while elapsed < totalNanos {
                    if lock.withLock({ stopRequested }) { return }
                    try? await Task.sleep(nanoseconds: pollNanos)
                    elapsed += pollNanos
                }
            } else {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    // Resume immediately if stop() was already called before
                    // we got here; otherwise install the continuation.
                    let alreadyStopped = lock.withLock { () -> Bool in
                        if stopRequested { return true }
                        stopContinuation = cont
                        return false
                    }
                    if alreadyStopped { cont.resume() }
                }
            }
        }

        await stopTask.value
        let timing = await recorder.stop()

        do {
            try timing.write(to: sessionDir.appendingPathComponent("timing.json"))
        } catch {
            return .error("Failed to write timing: \(error.localizedDescription)")
        }

        let mixedURL = sessionDir.appendingPathComponent("audio.m4a")
        let mixer = AudioMixer()
        do {
            try mixer.mix(
                micURL: sessionDir.appendingPathComponent("audio.mic.caf"),
                sysURL: sessionDir.appendingPathComponent("audio.sys.caf"),
                timing: timing,
                outputURL: mixedURL
            )
        } catch {
            return .error("Mix failed: \(error.localizedDescription)")
        }

        let size = (
            try? FileManager.default.attributesOfItem(atPath: mixedURL.path)[.size]
                as? UInt64
        ) ?? 0
        return size > 0 ? .recorded : .noAudio
    }

    /// Human-readable snapshot of the devices the pipeline will use, for the
    /// session run log. Always includes the current system defaults so a later
    /// reader can tell whether "system default" in config meant what they expect.
    static func describeDevices(audio: AppConfig.AudioSettings) -> [String] {
        let inputs = AudioDevices.availableInputDevices()
        let outputs = AudioDevices.availableOutputDevices()
        let resolvedOutputID = resolveOutputDevice(uid: audio.outputDeviceUID)
            ?? AudioDevices.defaultOutputDeviceID()
        let aec = resolveEchoCancellation(audio: audio, outputDeviceID: resolvedOutputID)
        return [
            "audio.input=\(selected(uid: audio.inputDeviceUID, in: inputs))"
                + " default=\(name(of: AudioDevices.defaultInputDeviceID(), in: inputs))",
            "audio.output=\(selected(uid: audio.outputDeviceUID, in: outputs))"
                + " default=\(name(of: AudioDevices.defaultOutputDeviceID(), in: outputs))",
            "audio.aec.mode=\(audio.aec.rawValue) effective=\(aec.enabled) reason=\(aec.reason)",
        ]
    }

    private typealias DeviceInfo = (id: AudioDeviceID, name: String, uid: String)

    private static func selected(uid: String, in devices: [DeviceInfo]) -> String {
        guard !uid.isEmpty else { return "<system default>" }
        if let match = devices.first(where: { $0.uid == uid }) {
            return "\(match.name) [uid=\(uid)]"
        }
        return "<not found, falling back to system default> [uid=\(uid)]"
    }

    private static func name(of deviceID: AudioDeviceID?, in devices: [DeviceInfo]) -> String {
        guard let deviceID else { return "unknown" }
        return devices.first(where: { $0.id == deviceID })?.name ?? "unknown"
    }

    // MARK: - AEC resolution

    /// Decision returned by `resolveEchoCancellation`: the boolean to feed
    /// `DualAudioRecorder.echoCancellation`, plus a short human-readable
    /// reason suitable for the run log.
    struct AECDecision: Equatable {
        let enabled: Bool
        let reason: String
    }

    /// Translate the user's `AECMode` setting into an effective on/off
    /// boolean, factoring in the current output device when the user has
    /// asked for `.auto`.
    ///
    /// The reason string lands in `run.log` so a future user reading back a
    /// session can see exactly why AEC went the way it did ("auto: built-in
    /// speakers detected", "auto: headphones jack — skipped", "manual: on",
    /// etc.). Pure with respect to its inputs — easy to test by feeding a
    /// stub device ID.
    static func resolveEchoCancellation(
        audio: AppConfig.AudioSettings,
        outputDeviceID: AudioDeviceID?
    ) -> AECDecision {
        switch audio.aec {
        case .on:
            return AECDecision(enabled: true, reason: "manual: on")
        case .off:
            return AECDecision(enabled: false, reason: "manual: off")
        case .auto:
            guard let outputDeviceID else {
                // No detectable output device — be safe and engage AEC so
                // the mic track stays clean if the user is on speakers.
                return AECDecision(enabled: true, reason: "auto: no output detected — defaulting on")
            }
            let cls = OutputDeviceClassifier.classify(deviceID: outputDeviceID)
            let enabled = OutputDeviceClassifier.aecRecommended(for: cls)
            return AECDecision(enabled: enabled, reason: "auto: \(reasonLabel(for: cls))")
        }
    }

    private static func reasonLabel(for cls: OutputDeviceClass) -> String {
        switch cls {
        case .headphonesIsolated: return "wired headphones — no acoustic feedback"
        case .speakerLikely: return "speakers / monitor / AirPlay — feedback risk"
        case .earbudsCoupled: return "Bluetooth earbuds — coupling risk"
        case .unknown: return "unknown transport — defaulting on"
        }
    }

    /// Signal the active recording to stop.
    static func stop() {
        logger.info("recording stop requested")
        lock.withLock {
            stopRequested = true
            stopContinuation?.resume()
            stopContinuation = nil
        }
    }
}
