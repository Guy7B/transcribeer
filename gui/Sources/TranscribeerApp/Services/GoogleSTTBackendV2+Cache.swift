import CryptoKit
import Foundation
import os.log

// MARK: - Resume cache

/// Per-chunk persistence so a partial run can be resumed without redoing
/// completed work. Layered as a separate file to keep the main backend
/// under the 600-line file budget; the API stays purely static so the
/// retry path in `recognize(...)` can call into it without a backend
/// instance.
extension GoogleSTTBackendV2 {

    private static let cacheLogger = Logger(
        subsystem: "com.transcribeer",
        category: "transcription.google_v2.cache",
    )

    /// Compute the directory under which per-chunk results are cached.
    /// The audio hash is derived from the source file (size + mtime + first
    /// 1MB SHA-256) so changing the recording invalidates the cache without
    /// needing to read every byte of a multi-hundred-megabyte file.
    static func resumeCacheDirectory(
        audioURL: URL,
        model: String,
        languageCodes: [String],
    ) -> URL? {
        let session = audioURL.deletingLastPathComponent()
        let langKey = languageCodes.joined(separator: "_")
        let hash = audioHash(of: audioURL)
        guard !hash.isEmpty else { return nil }
        let safeModel = model.replacingOccurrences(of: "/", with: "_")
        let safeLang = langKey.replacingOccurrences(of: "/", with: "_")
        let folder = "google_stt_v2__\(safeModel)__\(safeLang)__\(hash)"
        return session.appendingPathComponent(".stt-cache").appendingPathComponent(folder)
    }

    /// SHA-256 of size + mtime + first 1MB of the file, hex, first 16 chars.
    /// Returns "" when the file is unreadable so callers can fall back to
    /// no-cache behaviour without crashing.
    static func audioHash(of url: URL) -> String {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path) else { return "" }
        let size = (attrs[.size] as? UInt64) ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0

        var hasher = SHA256()
        var sizeLE = size.littleEndian
        withUnsafeBytes(of: &sizeLE) { hasher.update(bufferPointer: $0) }
        var mtimeBits = mtime.bitPattern.littleEndian
        withUnsafeBytes(of: &mtimeBits) { hasher.update(bufferPointer: $0) }

        if let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let head = (try? handle.read(upToCount: 1_048_576)) ?? Data()
            hasher.update(data: head)
        }
        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// Load any chunks already on disk for this run. Validates the
    /// manifest first so a model/lang change correctly invalidates the
    /// cache. Corrupt individual chunk JSON files are skipped (not fatal —
    /// we simply re-transcribe them).
    static func loadResumeCache(
        at dir: URL?,
        expectedChunkCount: Int,
    ) -> [Int: ChunkResultV2] {
        guard let dir else { return [:] }
        guard FileManager.default.fileExists(atPath: dir.path) else { return [:] }

        let manifestURL = dir.appendingPathComponent("manifest.json")
        if let data = try? Data(contentsOf: manifestURL),
           let manifest = try? JSONDecoder().decode(ResumeManifest.self, from: data),
           manifest.totalChunks != expectedChunkCount {
            cacheLogger.warning(
                """
                stt-cache manifest mismatch (totalChunks=\
                \(manifest.totalChunks, privacy: .public) \
                expected=\(expectedChunkCount, privacy: .public)); ignoring
                """,
            )
            return [:]
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return [:]
        }
        var loaded: [Int: ChunkResultV2] = [:]
        for entry in entries where entry.hasPrefix("chunk_") && entry.hasSuffix(".json") {
            let url = dir.appendingPathComponent(entry)
            do {
                let data = try Data(contentsOf: url)
                let payload = try JSONDecoder().decode(CachedChunkPayload.self, from: data)
                let words = payload.words.map { WordHit(start: $0.start, end: $0.end, text: $0.text) }
                loaded[payload.index] = ChunkResultV2(words: words)
            } catch {
                cacheLogger.warning(
                    """
                    stt-cache: skipping corrupt \(entry, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """,
                )
            }
        }
        return loaded
    }

    /// Persist a single chunk's result. Best-effort — any I/O failure is
    /// logged and swallowed so a flaky disk doesn't take down a working
    /// transcription pipeline.
    static func saveChunkCache(
        at dir: URL,
        index: Int,
        startOffset: Double,
        result: ChunkResultV2,
    ) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let payload = CachedChunkPayload(
                index: index,
                startOffset: startOffset,
                endOffset: result.words.last.map { $0.end + startOffset } ?? startOffset,
                words: result.words.map {
                    CachedChunkPayload.CachedWord(start: $0.start, end: $0.end, text: $0.text)
                },
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            let name = String(format: "chunk_%04d.json", index)
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        } catch {
            cacheLogger.warning(
                """
                stt-cache: write failed for chunk \(index, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """,
            )
        }
    }

    static func writeManifest(
        at dir: URL?,
        audioHash: String,
        model: String,
        languageCodes: [String],
        totalChunks: Int,
    ) {
        guard let dir else { return }
        let manifest = ResumeManifest(
            totalChunks: totalChunks,
            audioHash: audioHash,
            model: model,
            languageCodes: languageCodes,
            createdAt: ISO8601DateFormatter().string(from: Date()),
        )
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(manifest)
            try data.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        } catch {
            cacheLogger.warning(
                "stt-cache: manifest write failed: \(error.localizedDescription, privacy: .public)",
            )
        }
    }
}

// MARK: - Cache payload types

/// Single chunk's persisted payload. Kept fileprivate so the on-disk
/// schema is owned exclusively by this file — no other module depends on
/// the field names, which lets us evolve the format without rippling
/// through the codebase.
private struct CachedChunkPayload: Codable {
    let index: Int
    let startOffset: Double
    let endOffset: Double
    let words: [CachedWord]

    struct CachedWord: Codable {
        let start: Double
        let end: Double
        let text: String
    }
}

/// Cache directory header. `totalChunks` is the validation key — when it
/// disagrees with what `AudioChunker.split` produces for the current
/// run, we treat the whole cache as stale.
private struct ResumeManifest: Codable {
    let totalChunks: Int
    let audioHash: String
    let model: String
    let languageCodes: [String]
    let createdAt: String
}
