import AVFoundation

public enum AudioFileError: Error {
    case cannotOpen(String)
}

/// Writes audio samples to a compressed M4A/AAC file via AVAudioFile.
///
/// Thread-safe: `append(_:)` and `close()` can be called from any thread.
public final class AudioFileWriter {
    public static let shared = AudioFileWriter()
    public init() {}

    private let lock = NSLock()
    private var audioFile: AVAudioFile?

    public func open(
        url: URL,
        sampleRate: Double = 16000,
        channels: Int = 1
    ) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        do {
            audioFile = try AVAudioFile(forWriting: url, settings: settings)
        } catch {
            throw AudioFileError.cannotOpen(url.path)
        }
    }

    public func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let file = audioFile, buffer.frameLength > 0 else { return }
            try? file.write(from: buffer)
        }
    }

    public func close() {
        lock.withLock {
            audioFile = nil
        }
    }
}
