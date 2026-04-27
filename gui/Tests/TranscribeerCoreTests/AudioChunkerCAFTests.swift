import AVFoundation
import Foundation
import Testing
@testable import TranscribeerCore

/// Regression coverage for the dual-capture crash: re-transcribing a session
/// recorded to `audio.mic.caf` used to SIGTRAP inside `AudioChunker.split`
/// because the reader treated the CAF header as WAV and overflowed a UInt16.
/// These tests drive `split` with real AVAudioFile-produced inputs (CAF +
/// M4A) to ensure the chunker stays format-agnostic.
struct AudioChunkerCAFTests {
    // MARK: - Helpers

    /// Write a silent Float32 mono CAF of `durationSeconds` at `sampleRate`.
    /// Matches the format `DualAudioRecorder` produces for `audio.mic.caf`.
    private static func writeSilentCAF(
        durationSeconds: Double,
        sampleRate: Double = 48_000,
        channels: AVAudioChannelCount = 1
    ) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunker-\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(durationSeconds * sampleRate)
        ) else {
            throw ChunkError.invalidWAV
        }
        buffer.frameLength = buffer.frameCapacity
        try file.write(from: buffer)
        return url
    }

    private static func makeTempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-\(UUID().uuidString)")
    }

    // MARK: - split(CAF)

    @Test("Splitting a short CAF produces one WAV chunk without crashing")
    func splitShortCAF() throws {
        let src = try Self.writeSilentCAF(durationSeconds: 2)
        let tempDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let chunks = try AudioChunker.split(
            source: src,
            chunkDuration: 10,
            tempDir: tempDir
        )
        #expect(chunks.count == 1)
        #expect(chunks[0].startOffset == 0.0)

        let header = try Data(contentsOf: chunks[0].url).prefix(4)
        #expect(header == Data([0x52, 0x49, 0x46, 0x46])) // RIFF

        // Chunks are AVAudioFile-readable → verifies they're valid WAVs.
        let decoded = try AVAudioFile(forReading: chunks[0].url)
        #expect(decoded.processingFormat.sampleRate == 48_000)
        #expect(decoded.processingFormat.channelCount == 1)
    }

    @Test("Splitting a longer CAF yields chunks in chronological order")
    func splitMultiChunkCAF() throws {
        let src = try Self.writeSilentCAF(durationSeconds: 25)
        let tempDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let chunks = try AudioChunker.split(
            source: src,
            chunkDuration: 10,
            tempDir: tempDir
        )
        #expect(chunks.count == 3)
        #expect(chunks[0].startOffset == 0.0)
        #expect(abs(chunks[1].startOffset - 10.0) < 0.001)
        #expect(abs(chunks[2].startOffset - 20.0) < 0.001)

        // Every chunk is a valid WAV that AVAudioFile can re-open.
        for chunk in chunks {
            let decoded = try AVAudioFile(forReading: chunk.url)
            #expect(decoded.length > 0)
        }
    }

    @Test("Stereo CAF input is downmixed to mono WAV chunks")
    func splitStereoCAF() throws {
        let src = try Self.writeSilentCAF(durationSeconds: 1, channels: 2)
        let tempDir = Self.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let chunks = try AudioChunker.split(
            source: src,
            chunkDuration: 10,
            tempDir: tempDir
        )
        #expect(chunks.count == 1)
        let decoded = try AVAudioFile(forReading: chunks[0].url)
        #expect(decoded.processingFormat.channelCount == 1)
    }

    @Test("wavDuration accepts any AVAudioFile-readable source")
    func durationOfCAF() throws {
        let src = try Self.writeSilentCAF(durationSeconds: 3)
        defer { try? FileManager.default.removeItem(at: src) }
        let duration = try #require(AudioChunker.wavDuration(url: src))
        #expect(abs(duration - 3.0) < 0.01)
    }
}
