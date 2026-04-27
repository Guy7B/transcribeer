import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.transcribeer", category: "audio.chunker")

/// Splits an audio file (WAV, CAF, M4A — anything `AVAudioFile` can read) into
/// fixed-duration 16-bit PCM mono WAV chunks.
///
/// Uses `AVAudioFile` for decoding so the source format doesn't matter; chunks
/// are always emitted as standard RIFF PCM WAV so `WhisperKit` (and any other
/// downstream consumer) can load them without format-specific branches.
public enum AudioChunker {
    public struct Chunk {
        /// URL of the chunk WAV file on disk.
        public let url: URL
        /// Start time of this chunk within the original file, in seconds.
        public let startOffset: Double
    }

    /// Playback duration in seconds for any format `AVAudioFile` can open.
    /// Returns `nil` on I/O failure or unreadable header (including truncated
    /// WAVs that never made it past the 44-byte header).
    public static func wavDuration(url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return nil }
        return Double(file.length) / rate
    }

    /// Split `source` into chunks of `chunkDuration` seconds.
    ///
    /// Returns chunks in chronological order. Files are written to `tempDir`.
    /// Caller is responsible for deleting `tempDir` when done.
    public static func split(
        source: URL,
        chunkDuration: Double = 600,
        tempDir: URL
    ) throws -> [Chunk] {
        let started = Date()
        let file = try AVAudioFile(forReading: source)
        let sourceFormat = file.processingFormat
        let sourceRate = sourceFormat.sampleRate
        guard sourceRate > 0, file.length > 0 else { return [] }

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let framesPerChunk = AVAudioFrameCount(max(1, Int64(chunkDuration * sourceRate)))
        guard let readBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: framesPerChunk
        ) else {
            throw ChunkError.invalidWAV
        }

        // WhisperKit decodes from WAV, so emit at the source's native sample
        // rate but downmixed to mono 16-bit. Resampling is left to WhisperKit
        // to avoid introducing quality loss here.
        let outputRate = UInt32(sourceRate)
        let totalDuration = Double(file.length) / sourceRate
        let estimatedCount = max(1, Int((totalDuration / chunkDuration).rounded(.up)))
        logger.info(
            """
            split src=\(source.lastPathComponent, privacy: .public) \
            duration=\(String(format: "%.1f", totalDuration), privacy: .public)s \
            chunkDuration=\(chunkDuration, privacy: .public)s \
            chunks=~\(estimatedCount, privacy: .public) \
            sampleRate=\(sourceRate, privacy: .public) \
            outDir=\(tempDir.path, privacy: .public)
            """,
        )

        var chunks: [Chunk] = []
        var chunkIndex = 0
        var startFrame: AVAudioFramePosition = 0

        while startFrame < file.length {
            file.framePosition = startFrame
            let remaining = file.length - startFrame
            let toRead = AVAudioFrameCount(min(Int64(framesPerChunk), remaining))

            readBuffer.frameLength = 0
            try file.read(into: readBuffer, frameCount: toRead)
            guard readBuffer.frameLength > 0 else { break }

            let pcm = pcmMonoInt16(from: readBuffer)
            let chunkURL = tempDir.appendingPathComponent("chunk-\(chunkIndex).wav")
            try writeWAV(
                pcm: pcm,
                to: chunkURL,
                sampleRate: outputRate,
                numChannels: 1,
                bitsPerSample: 16
            )

            let startOffset = Double(startFrame) / sourceRate
            let chunkSeconds = Double(readBuffer.frameLength) / sourceRate
            logger.debug(
                """
                chunk idx=\(chunkIndex, privacy: .public) \
                frames=\(readBuffer.frameLength, privacy: .public) \
                duration=\(String(format: "%.1f", chunkSeconds), privacy: .public)s
                """,
            )
            chunks.append(Chunk(
                url: chunkURL,
                startOffset: startOffset
            ))

            startFrame += AVAudioFramePosition(readBuffer.frameLength)
            chunkIndex += 1
        }

        let elapsed = Date().timeIntervalSince(started)
        let elapsedStr = String(format: "%.2f", elapsed)
        logger.info("split done count=\(chunks.count, privacy: .public) in \(elapsedStr, privacy: .public)s")
        return chunks
    }

    // MARK: - Private

    /// Downmix an N-channel float PCM buffer to mono Int16 PCM bytes.
    ///
    /// Works for both interleaved and deinterleaved buffers; falls back to a
    /// zero-filled buffer only if `AVAudioPCMBuffer` didn't expose channel
    /// data (e.g. a zero-length read).
    private static func pcmMonoInt16(from buffer: AVAudioPCMBuffer) -> Data {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return Data() }
        var samples = [Int16](repeating: 0, count: frames)
        let channelCount = Int(buffer.format.channelCount)

        if let channels = buffer.floatChannelData {
            for i in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += channels[ch][i]
                }
                samples[i] = floatToInt16(sum / Float(max(channelCount, 1)))
            }
        } else if let interleaved = buffer.int16ChannelData {
            let src = interleaved[0]
            for i in 0..<frames {
                var sum: Int32 = 0
                for ch in 0..<channelCount {
                    sum += Int32(src[i * channelCount + ch])
                }
                samples[i] = Int16(clamping: sum / Int32(max(channelCount, 1)))
            }
        }

        return samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return Data() }
            return Data(bytes: base, count: frames * MemoryLayout<Int16>.size)
        }
    }

    private static func floatToInt16(_ value: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, value))
        let scaled = clamped * Float(Int16.max)
        return Int16(scaled.rounded())
    }

    private static func writeWAV(
        pcm: Data,
        to url: URL,
        sampleRate: UInt32,
        numChannels: UInt16,
        bitsPerSample: UInt16
    ) throws {
        let dataSize   = UInt32(pcm.count)
        let byteRate   = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign = UInt16(Int(numChannels) * Int(bitsPerSample) / 8)

        var h = Data(count: 44)
        h[0...3]   = Data([0x52, 0x49, 0x46, 0x46])
        h.writeUInt32LE(36 + dataSize, at: 4)
        h[8...11]  = Data([0x57, 0x41, 0x56, 0x45])
        h[12...15] = Data([0x66, 0x6d, 0x74, 0x20])
        h.writeUInt32LE(16, at: 16)
        h.writeUInt16LE(1, at: 20)
        h.writeUInt16LE(numChannels, at: 22)
        h.writeUInt32LE(sampleRate, at: 24)
        h.writeUInt32LE(byteRate, at: 28)
        h.writeUInt16LE(blockAlign, at: 32)
        h.writeUInt16LE(bitsPerSample, at: 34)
        h[36...39] = Data([0x64, 0x61, 0x74, 0x61])
        h.writeUInt32LE(dataSize, at: 40)

        var file = h
        file.append(pcm)
        try file.write(to: url)
    }
}

public enum ChunkError: Error {
    case invalidWAV
}

// MARK: - Data write helpers

private extension Data {
    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { replaceSubrange(offset..<(offset + 2), with: $0) }
    }
}
