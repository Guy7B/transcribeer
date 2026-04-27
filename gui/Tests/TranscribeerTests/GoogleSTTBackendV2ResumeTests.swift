import Foundation
import Testing
import TranscribeerCore
@testable import TranscribeerApp

/// Tests for the per-chunk resume cache that lets a long Google STT v2
/// transcription survive a transient failure without restarting from
/// chunk zero.
struct GoogleSTTBackendV2ResumeTests {

    // MARK: - Audio hashing

    @Test("audioHash is stable for the same source file across calls")
    func audioHashStable() throws {
        let url = try writeTempAudio(bytes: [0x10, 0x20, 0x30, 0x40, 0x50, 0x60])
        defer { try? FileManager.default.removeItem(at: url) }

        let first = GoogleSTTBackendV2.audioHash(of: url)
        let second = GoogleSTTBackendV2.audioHash(of: url)

        #expect(first == second)
        #expect(first.count == 16)
    }

    @Test("audioHash differs when the file contents change")
    func audioHashContentSensitive() throws {
        let url = try writeTempAudio(bytes: [0x10, 0x20, 0x30, 0x40])
        defer { try? FileManager.default.removeItem(at: url) }

        let original = GoogleSTTBackendV2.audioHash(of: url)
        try Data([0xAA, 0xBB, 0xCC, 0xDD, 0xEE]).write(to: url)
        let updated = GoogleSTTBackendV2.audioHash(of: url)

        #expect(original != updated)
    }

    @Test("audioHash returns empty string for missing files (signals no-cache)")
    func audioHashMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/nope-\(UUID().uuidString).bin")
        #expect(GoogleSTTBackendV2.audioHash(of: url).isEmpty)
    }

    // MARK: - Cache directory layout

    @Test("resumeCacheDirectory bakes model + lang + hash into the folder name")
    func cacheDirectoryShape() throws {
        let url = try writeTempAudio(bytes: [0x01, 0x02, 0x03])
        defer { try? FileManager.default.removeItem(at: url) }

        let cacheDir = try #require(GoogleSTTBackendV2.resumeCacheDirectory(
            audioURL: url,
            model: "chirp_3",
            languageCodes: ["iw-IL"],
        ))
        #expect(cacheDir.lastPathComponent.hasPrefix("google_stt_v2__chirp_3__iw-IL__"))
        #expect(cacheDir.deletingLastPathComponent().lastPathComponent == ".stt-cache")
        // Sibling of the audio file's directory.
        #expect(cacheDir.deletingLastPathComponent().deletingLastPathComponent() ==
                url.deletingLastPathComponent())
    }

    @Test("Multi-language code list joins on underscore for filesystem safety")
    func cacheDirectoryMultiLang() throws {
        let url = try writeTempAudio(bytes: [0x01])
        defer { try? FileManager.default.removeItem(at: url) }

        let cacheDir = try #require(GoogleSTTBackendV2.resumeCacheDirectory(
            audioURL: url,
            model: "chirp_3",
            languageCodes: ["en-US", "iw-IL"],
        ))
        #expect(cacheDir.lastPathComponent.contains("__en-US_iw-IL__"))
    }

    @Test("Slash characters in model name are sanitised so we don't cross dirs")
    func cacheDirectorySanitisedModel() throws {
        let url = try writeTempAudio(bytes: [0x01])
        defer { try? FileManager.default.removeItem(at: url) }

        let cacheDir = try #require(GoogleSTTBackendV2.resumeCacheDirectory(
            audioURL: url,
            model: "vendor/model",
            languageCodes: ["en-US"],
        ))
        let folder = cacheDir.lastPathComponent
        #expect(folder.contains("vendor_model"))
        #expect(!folder.contains("vendor/model"))
    }

    // MARK: - Save + load round-trip

    @Test("Saving a chunk and reloading it produces an equivalent ChunkResultV2")
    func saveLoadRoundTrip() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = ChunkResultV2(words: [
            WordHit(start: 0.0, end: 0.5, text: "hello"),
            WordHit(start: 0.5, end: 1.0, text: "world"),
        ])
        GoogleSTTBackendV2.saveChunkCache(at: dir, index: 3, startOffset: 12.0, result: result)

        let loaded = GoogleSTTBackendV2.loadResumeCache(at: dir, expectedChunkCount: 5)
        let entry = try #require(loaded[3])
        #expect(entry.words.count == 2)
        #expect(entry.words[0].text == "hello")
        #expect(entry.words[1].end == 1.0)
    }

    @Test("Manifest mismatch invalidates the cache so the run starts fresh")
    func manifestMismatchIgnoresCache() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Seed a chunk and a manifest that disagrees on totalChunks.
        GoogleSTTBackendV2.saveChunkCache(
            at: dir,
            index: 0,
            startOffset: 0,
            result: ChunkResultV2(words: [WordHit(start: 0, end: 1, text: "x")]),
        )
        let manifest: [String: Any] = [
            "totalChunks": 99,
            "audioHash": "deadbeef",
            "model": "chirp_3",
            "languageCodes": ["en-US"],
            "createdAt": "2026-01-01T00:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest)
        try data.write(to: dir.appendingPathComponent("manifest.json"))

        let loaded = GoogleSTTBackendV2.loadResumeCache(at: dir, expectedChunkCount: 5)
        #expect(loaded.isEmpty)
    }

    @Test("Corrupt JSON files are skipped, valid neighbours still load")
    func corruptChunkSkipped() throws {
        let dir = try makeScratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        GoogleSTTBackendV2.saveChunkCache(
            at: dir,
            index: 0,
            startOffset: 0,
            result: ChunkResultV2(words: [WordHit(start: 0, end: 1, text: "ok")]),
        )
        // Drop a malformed payload at index 1.
        try Data("{ not json".utf8)
            .write(to: dir.appendingPathComponent("chunk_0001.json"))

        let loaded = GoogleSTTBackendV2.loadResumeCache(at: dir, expectedChunkCount: 2)
        #expect(loaded.count == 1)
        #expect(loaded[0]?.words.first?.text == "ok")
        #expect(loaded[1] == nil)
    }

    @Test("Missing cache directory returns an empty map without throwing")
    func missingDirReturnsEmpty() {
        let dir = URL(fileURLWithPath: "/tmp/never-created-\(UUID().uuidString)")
        let loaded = GoogleSTTBackendV2.loadResumeCache(at: dir, expectedChunkCount: 5)
        #expect(loaded.isEmpty)
    }

    // MARK: - Helpers

    private func writeTempAudio(bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stt-resume-\(UUID().uuidString).bin")
        try Data(bytes).write(to: url)
        return url
    }

    private func makeScratchDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stt-resume-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
