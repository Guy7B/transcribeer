import Foundation

/// Keychain access via the `security` CLI — matches the Python implementation.
enum KeychainHelper {
    private static func service(_ backend: String) -> String {
        "transcribeer/\(backend)"
    }

    static func getAPIKey(backend: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = [
            "find-generic-password",
            "-s", service(backend),
            "-a", "apikey",
            "-w",
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }

        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let key = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return key?.isEmpty == true ? nil : key
    }

    static func setAPIKey(backend: String, key: String) {
        // Delete existing first
        let del = Process()
        del.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        del.arguments = [
            "delete-generic-password",
            "-s", service(backend),
            "-a", "apikey",
        ]
        del.standardOutput = FileHandle.nullDevice
        del.standardError = FileHandle.nullDevice
        try? del.run()
        del.waitUntilExit()

        // Add new
        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        add.arguments = [
            "add-generic-password",
            "-s", service(backend),
            "-a", "apikey",
            "-w", key,
        ]
        add.standardOutput = FileHandle.nullDevice
        add.standardError = FileHandle.nullDevice
        try? add.run()
        add.waitUntilExit()
    }
}
