import Foundation

/// Represents a single recording session directory.
struct Session: Identifiable, Equatable {
    let id: String  // directory path
    let path: URL
    let name: String
    let isUntitled: Bool
    let date: Date
    let formattedDate: String
    let duration: String
    let snippet: String

    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id
    }
}

/// Detailed data for a selected session.
struct SessionDetail {
    let name: String
    let notes: String
    let date: String
    let duration: String
    let transcript: String
    let summary: String
    let canTranscribe: Bool
    let canSummarize: Bool
    let audioURL: URL?
}

// MARK: - Session Manager

enum SessionManager {
    /// List session dirs sorted most-recent first.
    static func listSessions(sessionsDir: String) -> [Session] {
        let dir = URL(fileURLWithPath: (sessionsDir as NSString).expandingTildeInPath)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles
        ) else { return [] }

        return contents
            .filter { url in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                return isDir.boolValue
            }
            .sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return aDate > bDate
            }
            .map { sessionRow($0) }
    }

    /// Create a new session directory.
    static func newSession(sessionsDir: String) -> URL {
        let dir = URL(fileURLWithPath: (sessionsDir as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let name = formatter.string(from: Date())
        var path = dir.appendingPathComponent(name)
        var suffix = 0
        while FileManager.default.fileExists(atPath: path.path) {
            suffix += 1
            path = dir.appendingPathComponent("\(name)-\(suffix)")
        }
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    static func sessionRow(_ dir: URL) -> Session {
        let meta = readMeta(dir)
        let rawName = meta["name"] as? String ?? ""
        let displayName = rawName.isEmpty ? dir.lastPathComponent : rawName

        let creationDate: Date
        if let vals = try? dir.resourceValues(forKeys: [.creationDateKey]),
           let d = vals.creationDate {
            creationDate = d
        } else {
            creationDate = .distantPast
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy HH:mm"

        return Session(
            id: dir.path,
            path: dir,
            name: displayName,
            isUntitled: rawName.isEmpty,
            date: creationDate,
            formattedDate: fmt.string(from: creationDate),
            duration: audioDuration(dir),
            snippet: snippet(dir)
        )
    }

    static func sessionDetail(_ dir: URL) -> SessionDetail {
        let meta = readMeta(dir)
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d, yyyy HH:mm"
        let creationDate: Date
        if let vals = try? dir.resourceValues(forKeys: [.creationDateKey]),
           let d = vals.creationDate {
            creationDate = d
        } else {
            creationDate = .distantPast
        }

        let txPath = dir.appendingPathComponent("transcript.txt")
        let smPath = dir.appendingPathComponent("summary.md")
        let audioPath = dir.appendingPathComponent("audio.wav")

        let hasAudio = FileManager.default.fileExists(atPath: audioPath.path)

        return SessionDetail(
            name: meta["name"] as? String ?? "",
            notes: meta["notes"] as? String ?? "",
            date: fmt.string(from: creationDate),
            duration: audioDuration(dir),
            transcript: (try? String(contentsOf: txPath, encoding: .utf8)) ?? "",
            summary: (try? String(contentsOf: smPath, encoding: .utf8)) ?? "",
            canTranscribe: hasAudio,
            canSummarize: FileManager.default.fileExists(atPath: txPath.path),
            audioURL: hasAudio ? audioPath : nil
        )
    }

    // MARK: - Meta

    static func readMeta(_ dir: URL) -> [String: Any] {
        let path = dir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    static func writeMeta(_ dir: URL, _ data: [String: Any]) {
        let path = dir.appendingPathComponent("meta.json")
        guard let jsonData = try? JSONSerialization.data(
            withJSONObject: data, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? jsonData.write(to: path, options: .atomic)
    }

    static func setName(_ dir: URL, _ name: String) {
        var data = readMeta(dir)
        data["name"] = name
        writeMeta(dir, data)
    }

    static func setNotes(_ dir: URL, _ notes: String) {
        var data = readMeta(dir)
        data["notes"] = notes
        writeMeta(dir, data)
    }

    static func displayName(_ dir: URL) -> String {
        let name = readMeta(dir)["name"] as? String ?? ""
        return name.isEmpty ? dir.lastPathComponent : name
    }

    // MARK: - Helpers

    private static func audioDuration(_ dir: URL) -> String {
        let path = dir.appendingPathComponent("audio.wav")
        guard FileManager.default.fileExists(atPath: path.path) else { return "—" }

        // Read WAV header to get duration
        guard let handle = try? FileHandle(forReadingFrom: path) else { return "—" }
        defer { try? handle.close() }

        let header = handle.readData(ofLength: 44)
        guard header.count == 44 else { return "—" }

        // Bytes 24-27: sample rate (little-endian)
        let sampleRate = header.withUnsafeBytes { buf -> UInt32 in
            buf.load(fromByteOffset: 24, as: UInt32.self)
        }
        // Bytes 34-35: bits per sample
        let bitsPerSample = header.withUnsafeBytes { buf -> UInt16 in
            buf.load(fromByteOffset: 34, as: UInt16.self)
        }
        // Bytes 22-23: channels
        let channels = header.withUnsafeBytes { buf -> UInt16 in
            buf.load(fromByteOffset: 22, as: UInt16.self)
        }

        guard sampleRate > 0, bitsPerSample > 0, channels > 0 else { return "—" }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? UInt64) ?? 0
        let dataSize = fileSize - 44
        let bytesPerSample = UInt64(bitsPerSample) / 8
        let totalSamples = dataSize / (bytesPerSample * UInt64(channels))
        let seconds = Int(totalSamples / UInt64(sampleRate))
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private static func snippet(_ dir: URL) -> String {
        for fname in ["summary.md", "transcript.txt"] {
            let path = dir.appendingPathComponent(fname)
            guard let text = try? String(contentsOf: path, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    return String(trimmed.prefix(120))
                }
            }
        }
        return ""
    }
}
