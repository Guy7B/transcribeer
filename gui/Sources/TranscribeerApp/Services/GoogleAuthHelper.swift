import Foundation
import os.log

/// Obtains OAuth 2.0 bearer tokens for Google Cloud v2 APIs.
///
/// The app can't embed a service-account key or prompt for OAuth from a
/// menubar context, so we delegate to the user's installed `gcloud` CLI:
///
///   1. User runs `gcloud auth application-default login` once.
///   2. `print-access-token` returns a fresh access token for the active
///      ADC principal. Tokens live ~1 hour; we cache with a safety margin.
///
/// This mirrors what the `tests/benchmarks/sttcompare/providers/google_v2.py`
/// script does, keeping the two paths consistent.
enum GoogleAuthHelper {
    /// Errors surfaced to the UI layer verbatim (they conform to
    /// `LocalizedError`), so phrasing matters.
    enum AuthError: LocalizedError {
        case gcloudNotInstalled
        case notAuthenticated(detail: String)
        case tokenEmpty

        var errorDescription: String? {
            switch self {
            case .gcloudNotInstalled:
                return "Google Cloud CLI (`gcloud`) not found. Install it with " +
                    "`brew install google-cloud-sdk`, then run " +
                    "`gcloud auth application-default login`."
            case .notAuthenticated(let detail):
                return "Google Cloud authentication failed. Run " +
                    "`gcloud auth application-default login`, then retry.\n\n" +
                    detail
            case .tokenEmpty:
                return "`gcloud auth application-default print-access-token` " +
                    "returned an empty token. Re-authenticate with " +
                    "`gcloud auth application-default login`."
            }
        }
    }

    private static let logger = Logger(subsystem: "com.transcribeer", category: "auth.google")

    /// Safe guesses for where Homebrew (Apple Silicon + Intel) drops `gcloud`,
    /// plus the macOS SDK's own install path. Searched in this order before
    /// falling back to `$PATH`. GUI apps launched from Finder get a stripped
    /// `$PATH` that often lacks `/opt/homebrew/bin`, so explicit paths matter.
    private static let candidatePaths = [
        "/opt/homebrew/bin/gcloud",
        "/opt/homebrew/share/google-cloud-sdk/bin/gcloud",
        "/usr/local/bin/gcloud",
        "/usr/local/share/google-cloud-sdk/bin/gcloud",
        "\(NSHomeDirectory())/google-cloud-sdk/bin/gcloud",
    ]

    // Serialize cache access across concurrent pipeline runs. Tokens are
    // expensive (~0.5-1s subprocess call) so sharing one per process cuts
    // most of the latency from a 35-chunk Chirp 3 run.
    private static let cacheLock = NSLock()
    private static var cachedToken: CachedToken?

    private struct CachedToken {
        let token: String
        let expiresAt: Date
    }

    /// Return a valid access token. Cached until ~5 minutes before expiry;
    /// past that, re-invokes `gcloud` to refresh.
    static func accessToken() throws -> String {
        cacheLock.lock()
        if let cached = cachedToken, cached.expiresAt.timeIntervalSinceNow > 300 {
            let ageSeconds = Int(Date().timeIntervalSince(
                cached.expiresAt.addingTimeInterval(-50 * 60)
            ))
            defer { cacheLock.unlock() }
            logger.debug("token cache hit, age=\(ageSeconds, privacy: .public)s")
            return cached.token
        }
        cacheLock.unlock()

        let token = try fetchToken()

        cacheLock.lock()
        cachedToken = CachedToken(
            token: token,
            // Google ADC tokens are 1h; mint a fresh one every 50 minutes
            // so in-flight requests never race the expiry.
            expiresAt: Date().addingTimeInterval(50 * 60)
        )
        cacheLock.unlock()
        logger.info("token minted, valid for ~3600s (cache expires in 50m)")
        return token
    }

    /// Find an executable `gcloud`. Absolute paths win over $PATH so GUI
    /// launches (which inherit a minimal environment) still work.
    static func resolveGcloud() -> String? {
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            logger.debug("resolved gcloud at \(path, privacy: .public)")
            return path
        }
        // Final fallback: let the shell resolve via `command -v`. Slow but
        // handles non-standard install locations.
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-lc", "command -v gcloud"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            logger.error("gcloud shell-resolve failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: output, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !path.isEmpty {
            logger.debug("resolved gcloud via shell at \(path, privacy: .public)")
        }
        return path.isEmpty ? nil : path
    }

    private static func fetchToken() throws -> String {
        guard let gcloudPath = resolveGcloud() else {
            logger.error("gcloud binary not found in any candidate path")
            throw AuthError.gcloudNotInstalled
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gcloudPath)
        proc.arguments = ["auth", "application-default", "print-access-token"]
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        do {
            try proc.run()
        } catch {
            logger.error(
                "gcloud exec failed: \(error.localizedDescription, privacy: .public)",
            )
            throw AuthError.notAuthenticated(detail: error.localizedDescription)
        }
        proc.waitUntilExit()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()

        guard proc.terminationStatus == 0 else {
            let errText = String(data: errData, encoding: .utf8) ?? ""
            let truncated = String(errText.prefix(500))
            let rc = proc.terminationStatus
            logger.error(
                """
                gcloud print-access-token failed rc=\(rc, privacy: .public) \
                stderr=\(truncated, privacy: .public)
                """,
            )
            throw AuthError.notAuthenticated(detail: errText)
        }

        let token = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            logger.error("gcloud returned empty token")
            throw AuthError.tokenEmpty
        }
        return token
    }

    /// Drop the in-memory cache. Call after the user re-authenticates or
    /// changes projects so the next request mints a fresh token.
    static func invalidateCache() {
        cacheLock.lock()
        cachedToken = nil
        cacheLock.unlock()
        logger.info("token cache invalidated")
    }

    /// Lightweight probe used by the Settings UI. Does not raise — returns a
    /// Result so the view can render a green/red status badge without an
    /// alert sheet.
    static func probe() -> Result<String, AuthError> {
        do {
            let token = try fetchToken()
            // Store it so the next real request skips the subprocess call.
            cacheLock.lock()
            cachedToken = CachedToken(
                token: token,
                expiresAt: Date().addingTimeInterval(50 * 60)
            )
            cacheLock.unlock()
            // Return a short prefix so the UI can show "…ok" without leaking
            // the full bearer token into the view hierarchy.
            return .success(String(token.prefix(8)) + "…")
        } catch let error as AuthError {
            return .failure(error)
        } catch {
            return .failure(.notAuthenticated(detail: error.localizedDescription))
        }
    }
}
