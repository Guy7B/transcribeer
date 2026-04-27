import XCTest
@testable import TranscribeerCore

final class AudioChunkerTests: XCTestCase {
    // MARK: - Helpers

    /// Build a minimal PCM WAV with the given number of silent (zero) samples.
    private func makeWAV(sampleRate: UInt32 = 16000, samples: Int) -> Data {
        let pcm = Data(repeating: 0, count: samples * 2) // 16-bit
        var h = Data(count: 44)
        func w32(_ off: Int, _ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { h.replaceSubrange(off..<(off + 4), with: $0) }
        }
        func w16(_ off: Int, _ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { h.replaceSubrange(off..<(off + 2), with: $0) }
        }
        h[0...3]   = Data([0x52, 0x49, 0x46, 0x46]) // RIFF
        w32(4, 36 + UInt32(pcm.count))
        h[8...11]  = Data([0x57, 0x41, 0x56, 0x45]) // WAVE
        h[12...15] = Data([0x66, 0x6d, 0x74, 0x20]) // fmt
        w32(16, 16)
        w16(20, 1)           // PCM
        w16(22, 1)           // mono
        w32(24, sampleRate)
        w32(28, sampleRate * 2) // ByteRate
        w16(32, 2)           // BlockAlign
        w16(34, 16)          // BitsPerSample
        h[36...39] = Data([0x64, 0x61, 0x74, 0x61]) // data
        w32(40, UInt32(pcm.count))
        return h + pcm
    }

    private func writeTemp(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).wav")
        try data.write(to: url)
        return url
    }

    // MARK: - wavDuration

    func testWavDurationMatchesSampleCount() throws {
        let wav = makeWAV(sampleRate: 16000, samples: 16000)
        let url = try writeTemp(wav)
        defer { try? FileManager.default.removeItem(at: url) }
        let duration = try XCTUnwrap(AudioChunker.wavDuration(url: url))
        XCTAssertEqual(duration, 1.0, accuracy: 0.001)
    }

    func testWavDurationFor5Seconds() throws {
        let wav = makeWAV(sampleRate: 16000, samples: 80000)
        let url = try writeTemp(wav)
        defer { try? FileManager.default.removeItem(at: url) }
        let duration = try XCTUnwrap(AudioChunker.wavDuration(url: url))
        XCTAssertEqual(duration, 5.0, accuracy: 0.001)
    }

    func testWavDurationReturnsNilForTruncatedFile() throws {
        let url = try writeTemp(Data(repeating: 0, count: 10))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(AudioChunker.wavDuration(url: url))
    }

    // MARK: - split

    func testSplitShortFileProducesOneChunk() throws {
        let wav = makeWAV(sampleRate: 16000, samples: 32000) // 2 sec
        let src = try writeTemp(wav)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }
        let chunks = try AudioChunker.split(source: src, chunkDuration: 10, tempDir: tempDir)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].startOffset, 0.0)
    }

    func testSplitProducesCorrectChunkCount() throws {
        // 25 seconds → 3 chunks (10, 10, 5)
        let wav = makeWAV(sampleRate: 16000, samples: 25 * 16000)
        let src = try writeTemp(wav)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }
        let chunks = try AudioChunker.split(source: src, chunkDuration: 10, tempDir: tempDir)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].startOffset, 0.0, accuracy: 0.001)
        XCTAssertEqual(chunks[1].startOffset, 10.0, accuracy: 0.001)
        XCTAssertEqual(chunks[2].startOffset, 20.0, accuracy: 0.001)
    }

    func testChunkFilesAreValidWAV() throws {
        let wav = makeWAV(sampleRate: 16000, samples: 32000) // 2 sec
        let src = try writeTemp(wav)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }
        let chunks = try AudioChunker.split(source: src, chunkDuration: 1, tempDir: tempDir)
        XCTAssertEqual(chunks.count, 2)
        for chunk in chunks {
            XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.url.path))
            let d = try Data(contentsOf: chunk.url)
            XCTAssertEqual(d[0...3], Data([0x52, 0x49, 0x46, 0x46])) // RIFF
            let dur = try XCTUnwrap(AudioChunker.wavDuration(url: chunk.url))
            XCTAssertEqual(dur, 1.0, accuracy: 0.01)
        }
    }

    func testSplitPreservesTotalPCMData() throws {
        let sampleCount = 25 * 16000
        let wav = makeWAV(sampleRate: 16000, samples: sampleCount)
        let src = try writeTemp(wav)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }
        let chunks = try AudioChunker.split(source: src, chunkDuration: 10, tempDir: tempDir)
        let totalPCMBytes = try chunks.reduce(0) { acc, chunk in
            let d = try Data(contentsOf: chunk.url)
            return acc + (d.count - 44)
        }
        XCTAssertEqual(totalPCMBytes, sampleCount * 2)
    }

    // MARK: - AVFoundation compatibility (JUNK alignment chunk)

    /// Build a WAV with a JUNK alignment chunk before `fmt `, the layout
    /// `AVAudioFile(forWriting:)` emits. Regression test for the bug where
    /// the old parser assumed `fmt ` at offset 12 and returned empty
    /// chunks for any AVFoundation-produced WAV.
    private func makeWAVWithJUNK(sampleRate: UInt32 = 16000, samples: Int) -> Data {
        let pcm = Data(repeating: 0, count: samples * 2)
        let junkSize = 28 // typical Apple alignment padding
        let junkBody = Data(repeating: 0, count: junkSize)

        var fmtBody = Data(count: 16)
        func w16(_ d: inout Data, _ off: Int, _ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { d.replaceSubrange(off..<(off + 2), with: $0) }
        }
        func w32(_ d: inout Data, _ off: Int, _ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { d.replaceSubrange(off..<(off + 4), with: $0) }
        }
        w16(&fmtBody, 0, 1)                // PCM
        w16(&fmtBody, 2, 1)                // mono
        w32(&fmtBody, 4, sampleRate)
        w32(&fmtBody, 8, sampleRate * 2)   // ByteRate
        w16(&fmtBody, 12, 2)               // BlockAlign
        w16(&fmtBody, 14, 16)              // BitsPerSample

        let contentSize = UInt32(
            4                           // "WAVE"
                + 8 + junkSize          // JUNK chunk header + body
                + 8 + fmtBody.count     // fmt chunk header + body
                + 8 + pcm.count,        // data chunk header + body
        )

        var result = Data()
        result.append(Data([0x52, 0x49, 0x46, 0x46])) // RIFF
        var sz = contentSize.littleEndian
        withUnsafeBytes(of: &sz) { result.append(contentsOf: $0) }
        result.append(Data([0x57, 0x41, 0x56, 0x45])) // WAVE
        result.append(Data([0x4a, 0x55, 0x4e, 0x4b])) // JUNK
        var junkLen = UInt32(junkSize).littleEndian
        withUnsafeBytes(of: &junkLen) { result.append(contentsOf: $0) }
        result.append(junkBody)
        result.append(Data([0x66, 0x6d, 0x74, 0x20])) // "fmt "
        var fmtLen = UInt32(fmtBody.count).littleEndian
        withUnsafeBytes(of: &fmtLen) { result.append(contentsOf: $0) }
        result.append(fmtBody)
        result.append(Data([0x64, 0x61, 0x74, 0x61])) // "data"
        var dataLen = UInt32(pcm.count).littleEndian
        withUnsafeBytes(of: &dataLen) { result.append(contentsOf: $0) }
        result.append(pcm)
        return result
    }

    func testAVFoundationStyleWAVWithJUNKChunk() throws {
        // Regression: old parser hardcoded fmt at offset 12 and PCM at 44.
        // AVAudioFile emits a JUNK chunk first, so that layout didn't
        // match and AudioChunker.split returned [] -> 0-byte transcripts.
        let wav = makeWAVWithJUNK(sampleRate: 16000, samples: 16000 * 2) // 2 sec
        let src = try writeTemp(wav)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chunks-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: tempDir)
        }

        let duration = try XCTUnwrap(AudioChunker.wavDuration(url: src))
        XCTAssertEqual(duration, 2.0, accuracy: 0.001)

        let chunks = try AudioChunker.split(source: src, chunkDuration: 1, tempDir: tempDir)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].startOffset, 0.0, accuracy: 0.001)
        XCTAssertEqual(chunks[1].startOffset, 1.0, accuracy: 0.001)
        for chunk in chunks {
            let chunkDuration = try XCTUnwrap(AudioChunker.wavDuration(url: chunk.url))
            XCTAssertEqual(chunkDuration, 1.0, accuracy: 0.01)
        }
    }
}
