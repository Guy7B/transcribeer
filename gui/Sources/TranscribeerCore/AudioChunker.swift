import Foundation
import os.log

private let logger = Logger(subsystem: "com.transcribeer", category: "audio.chunker")

/// Splits a WAV audio file into fixed-duration chunk files.
///
/// Handles any PCM WAV the standard RIFF spec allows — not just the
/// minimal "classic" layout where `fmt ` is at offset 12 and PCM data
/// starts at offset 44. AVFoundation, for instance, inserts a `JUNK`
/// alignment chunk before `fmt `, and both AVFoundation and `afconvert`
/// emit extended `fmt ` chunks (40 bytes, WAVE_FORMAT_EXTENSIBLE) rather
/// than the 16-byte PCM default. The chunk walker below finds `fmt ` and
/// `data` regardless of their order or the presence of other chunks.
public enum AudioChunker {
    public struct Chunk {
        /// URL of the chunk WAV file on disk.
        public let url: URL
        /// Start time of this chunk within the original file, in seconds.
        public let startOffset: Double
    }

    /// Parsed WAV structure — just the parts we care about for slicing.
    private struct WAVLayout {
        let sampleRate: UInt32
        let numChannels: UInt16
        let bitsPerSample: UInt16
        /// Byte range of PCM data within the full file.
        let dataRange: Range<Int>
    }

    /// Returns the playback duration in seconds of a WAV file, or nil if unreadable.
    public static func wavDuration(url: URL) -> Double? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let layout = try? parseWAV(data)
        else { return nil }
        let bytesPerSec = Double(layout.sampleRate)
            * Double(layout.numChannels)
            * Double(layout.bitsPerSample) / 8
        guard bytesPerSec > 0 else { return nil }
        return Double(layout.dataRange.count) / bytesPerSec
    }

    /// Split `source` WAV into chunks of `chunkDuration` seconds.
    ///
    /// Returns chunks in chronological order. Files are written to `tempDir`.
    /// Caller is responsible for deleting `tempDir` when done.
    public static func split(
        source: URL,
        chunkDuration: Double = 600,
        tempDir: URL
    ) throws -> [Chunk] {
        let started = Date()
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let layout = try parseWAV(data)

        let frameSize = Int(layout.numChannels) * Int(layout.bitsPerSample / 8)
        let pcm = data.subdata(in: layout.dataRange)

        guard frameSize > 0, !pcm.isEmpty else { return [] }

        let samplesPerChunk = Int(Double(layout.sampleRate) * chunkDuration)
        let bytesPerChunk   = samplesPerChunk * frameSize

        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let totalSamples = pcm.count / frameSize
        let totalDuration = Double(totalSamples) / Double(layout.sampleRate)
        let estimatedCount = max(1, Int((totalDuration / chunkDuration).rounded(.up)))
        logger.info(
            """
            split src=\(source.lastPathComponent, privacy: .public) \
            duration=\(String(format: "%.1f", totalDuration), privacy: .public)s \
            chunkDuration=\(chunkDuration, privacy: .public)s \
            chunks=~\(estimatedCount, privacy: .public) \
            sampleRate=\(layout.sampleRate, privacy: .public) \
            outDir=\(tempDir.path, privacy: .public)
            """,
        )

        var chunks: [Chunk] = []
        var byteOffset = 0
        var chunkIndex = 0

        while byteOffset < pcm.count {
            let end      = min(byteOffset + bytesPerChunk, pcm.count)
            let chunkPCM = pcm.subdata(in: byteOffset..<end)
            let chunkURL = tempDir.appendingPathComponent("chunk-\(chunkIndex).wav")

            try writeWAV(
                pcm: chunkPCM,
                to: chunkURL,
                sampleRate: layout.sampleRate,
                numChannels: layout.numChannels,
                bitsPerSample: layout.bitsPerSample
            )

            let startOffset = Double(byteOffset / frameSize) / Double(layout.sampleRate)
            let chunkSeconds = Double(chunkPCM.count / frameSize) / Double(layout.sampleRate)
            let durationStr = String(format: "%.1f", chunkSeconds)
            logger.debug(
                "chunk idx=\(chunkIndex, privacy: .public) bytes=\(chunkPCM.count, privacy: .public) duration=\(durationStr, privacy: .public)s",
            )
            chunks.append(Chunk(url: chunkURL, startOffset: startOffset))

            byteOffset = end
            chunkIndex += 1
        }

        let elapsed = Date().timeIntervalSince(started)
        let elapsedStr = String(format: "%.2f", elapsed)
        logger.info("split done count=\(chunks.count, privacy: .public) in \(elapsedStr, privacy: .public)s")
        return chunks
    }

    // MARK: - WAV parsing

    /// Walk the RIFF chunk list to locate `fmt ` and `data`, whatever
    /// order they appear in and regardless of extra chunks (JUNK, LIST,
    /// bext, etc.). Throws `.invalidWAV` if the magic numbers or chunks
    /// don't line up.
    private static func parseWAV(_ data: Data) throws -> WAVLayout {
        guard data.count >= 12,
              data[0..<4] == Data([0x52, 0x49, 0x46, 0x46]), // "RIFF"
              data[8..<12] == Data([0x57, 0x41, 0x56, 0x45]) // "WAVE"
        else { throw ChunkError.invalidWAV }

        var cursor = 12
        var sampleRate: UInt32 = 0
        var numChannels: UInt16 = 0
        var bitsPerSample: UInt16 = 0
        var dataRange: Range<Int>?

        while cursor + 8 <= data.count {
            let chunkID = data.subdata(in: cursor..<(cursor + 4))
            let chunkSize = Int(data.readUInt32LE(at: cursor + 4))
            let bodyStart = cursor + 8
            let bodyEnd = bodyStart + chunkSize
            guard bodyEnd <= data.count else { break }

            if chunkID == Data([0x66, 0x6d, 0x74, 0x20]) { // "fmt "
                guard chunkSize >= 16 else { throw ChunkError.invalidWAV }
                // PCM fields live at fixed offsets within the fmt body,
                // identical for classic (16-byte) and extensible (40-byte)
                // formats.
                numChannels = data.readUInt16LE(at: bodyStart + 2)
                sampleRate = data.readUInt32LE(at: bodyStart + 4)
                bitsPerSample = data.readUInt16LE(at: bodyStart + 14)
            } else if chunkID == Data([0x64, 0x61, 0x74, 0x61]) { // "data"
                dataRange = bodyStart..<bodyEnd
            }

            // Chunks are 2-byte aligned; an odd chunkSize has a pad byte.
            cursor = bodyEnd + (chunkSize % 2)
        }

        guard let dataRange, sampleRate > 0, numChannels > 0, bitsPerSample > 0 else {
            throw ChunkError.invalidWAV
        }
        return WAVLayout(
            sampleRate: sampleRate,
            numChannels: numChannels,
            bitsPerSample: bitsPerSample,
            dataRange: dataRange,
        )
    }

    // MARK: - Private

    private static func writeWAV(
        pcm: Data,
        to url: URL,
        sampleRate: UInt32,
        numChannels: UInt16,
        bitsPerSample: UInt16
    ) throws {
        let dataSize   = UInt32(pcm.count)
        let byteRate   = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign = numChannels * (bitsPerSample / 8)

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

// MARK: - Data read/write helpers

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return UInt32(0) }
            var v: UInt32 = 0
            memcpy(&v, base.advanced(by: offset), 4)
            return UInt32(littleEndian: v)
        }
    }

    func readUInt16LE(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return UInt16(0) }
            var v: UInt16 = 0
            memcpy(&v, base.advanced(by: offset), 2)
            return UInt16(littleEndian: v)
        }
    }

    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { replaceSubrange(offset..<(offset + 4), with: $0) }
    }

    mutating func writeUInt16LE(_ value: UInt16, at offset: Int) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { replaceSubrange(offset..<(offset + 2), with: $0) }
    }
}
