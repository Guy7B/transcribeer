import Foundation

/// Manages prompt profiles from ~/.transcribeer/prompts/.
enum PromptProfileManager {
    private static var promptsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribeer/prompts")
    }

    /// Return available profile names. "default" is always first.
    static func listProfiles() -> [String] {
        var profiles = ["default"]
        let dir = promptsDir
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return profiles }

        let extras = contents
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .filter { $0 != "default" }
            .sorted()
        profiles.append(contentsOf: extras)
        return profiles
    }
}
