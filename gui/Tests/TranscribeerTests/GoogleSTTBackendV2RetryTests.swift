import Foundation
import Testing
import TranscribeerCore
@testable import TranscribeerApp

/// Tests for the per-chunk retry policy added to `GoogleSTTBackendV2`.
///
/// These exercise `retryDecision(for:attempt:)` (pure logic) and the
/// `recognizeWithRetry` driver via a stubbed `URLProtocol` so we can
/// simulate transient transport / HTTP failures without a network.
@Suite(.serialized)
struct GoogleSTTBackendV2RetryTests {

    // MARK: - Retry policy

    @Test("Transport errors retry with the scheduled backoff",
          arguments: [
              URLError.Code.timedOut,
              .networkConnectionLost,
              .notConnectedToInternet,
              .cannotConnectToHost,
              .dnsLookupFailed,
          ])
    func transportErrorsRetry(code: URLError.Code) {
        let decision = GoogleSTTBackendV2.retryDecision(
            for: URLError(code),
            attempt: 0,
        )
        #expect(decision.retryAfter == 1)
        #expect(decision.kind == "transport")
    }

    @Test("HTTP 5xx retries, HTTP 429 retries, HTTP 4xx does not")
    func httpStatusPolicy() {
        let server = GoogleSTTV2Error.apiError(503, "service unavailable", retryAfter: nil)
        #expect(GoogleSTTBackendV2.retryDecision(for: server, attempt: 0).retryAfter == 1)
        #expect(GoogleSTTBackendV2.retryDecision(for: server, attempt: 0).kind == "server-5xx")

        let throttled = GoogleSTTV2Error.apiError(429, "rate limited", retryAfter: nil)
        #expect(GoogleSTTBackendV2.retryDecision(for: throttled, attempt: 0).retryAfter == 1)
        #expect(GoogleSTTBackendV2.retryDecision(for: throttled, attempt: 0).kind == "rate-limited")

        let bad = GoogleSTTV2Error.apiError(400, "bad request", retryAfter: nil)
        #expect(GoogleSTTBackendV2.retryDecision(for: bad, attempt: 0).retryAfter == nil)
        #expect(GoogleSTTBackendV2.retryDecision(for: bad, attempt: 0).kind == "client-4xx")
    }

    @Test("429 honours an explicit Retry-After value over the default backoff")
    func retryAfterHonoured() {
        let throttled = GoogleSTTV2Error.apiError(429, "slow down", retryAfter: 4.5)
        let decision = GoogleSTTBackendV2.retryDecision(for: throttled, attempt: 0)
        #expect(decision.retryAfter == 4.5)
    }

    @Test("Final attempt returns nil so the loop exits")
    func exhaustedAttemptsStop() {
        // The schedule is 1s/3s/7s, so `attempt = 3` is the cap (4th attempt).
        let err = URLError(.timedOut)
        #expect(GoogleSTTBackendV2.retryDecision(for: err, attempt: 3).retryAfter == nil)
    }

    @Test("URLError values outside the retry list are not retried")
    func nonTransientUrlErrorsAreFatal() {
        // `userCancelledAuthentication` is a permanent client error — must
        // not be looped on, otherwise we'd burn the full schedule on every
        // single failed run.
        let err = URLError(.userCancelledAuthentication)
        #expect(GoogleSTTBackendV2.retryDecision(for: err, attempt: 0).retryAfter == nil)
    }

    // MARK: - Retry-After parsing

    @Test("parseRetryAfter accepts integer and decimal seconds")
    func retryAfterSeconds() {
        #expect(GoogleSTTBackendV2.parseRetryAfter(header: "5") == 5)
        #expect(GoogleSTTBackendV2.parseRetryAfter(header: "2.5") == 2.5)
        #expect(GoogleSTTBackendV2.parseRetryAfter(header: nil) == nil)
        #expect(GoogleSTTBackendV2.parseRetryAfter(header: "") == nil)
    }

    @Test("parseRetryAfter clamps absurd values to a one-minute ceiling")
    func retryAfterClamped() {
        #expect(GoogleSTTBackendV2.parseRetryAfter(header: "9999") == 60)
        #expect(GoogleSTTBackendV2.parseRetryAfter(header: "-5") == 0)
    }

    // MARK: - End-to-end retry via stubbed URLSession

    @Test("Transient networkConnectionLost on first attempt succeeds on retry")
    func networkLostThenSucceeds() async throws {
        let stub = StubURLProtocol.scenario(steps: [
            .failure(URLError(.networkConnectionLost)),
            .success(jsonBody: Self.singleWordResponse),
        ])
        let session = StubURLProtocol.makeSession(scenario: stub)
        let options = makeOptions(session: session)

        let result = try await GoogleSTTBackendV2.recognizeWithRetry(
            audioURL: Self.fakeAudio,
            options: options,
        )
        #expect(result.words.count == 1)
        #expect(result.words.first?.text == "hello")
        #expect(stub.attempts() == 2)
    }

    @Test("Persistent timedOut exhausts the retry budget and rethrows")
    func timedOutExhausted() async {
        let stub = StubURLProtocol.scenario(steps: [
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut)),
            .failure(URLError(.timedOut)),  // safety — ensures we don't run a 5th
        ])
        let session = StubURLProtocol.makeSession(scenario: stub)
        let options = makeOptions(session: session)

        await #expect(throws: URLError.self) {
            _ = try await GoogleSTTBackendV2.recognizeWithRetry(
                audioURL: Self.fakeAudio,
                options: options,
            )
        }
        // 1 initial + 3 retries = 4 attempts total.
        #expect(stub.attempts() == 4)
    }

    @Test("HTTP 503 is classified as transient and retries to success")
    func http503ThenSucceeds() async throws {
        let stub = StubURLProtocol.scenario(steps: [
            .httpError(status: 503, body: #"{"error":{"message":"unavailable"}}"#),
            .success(jsonBody: Self.singleWordResponse),
        ])
        let session = StubURLProtocol.makeSession(scenario: stub)
        let options = makeOptions(session: session)

        let result = try await GoogleSTTBackendV2.recognizeWithRetry(
            audioURL: Self.fakeAudio,
            options: options,
        )
        #expect(result.words.count == 1)
        #expect(stub.attempts() == 2)
    }

    @Test("HTTP 400 is fatal — caller sees the apiError on the first attempt")
    func http400NotRetried() async {
        let stub = StubURLProtocol.scenario(steps: [
            .httpError(status: 400, body: #"{"error":{"message":"bad config"}}"#),
        ])
        let session = StubURLProtocol.makeSession(scenario: stub)
        let options = makeOptions(session: session)

        await #expect(throws: GoogleSTTV2Error.self) {
            _ = try await GoogleSTTBackendV2.recognizeWithRetry(
                audioURL: Self.fakeAudio,
                options: options,
            )
        }
        #expect(stub.attempts() == 1)
    }

    // MARK: - Helpers

    private static let fakeAudio: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("google-stt-v2-retry-fake-\(UUID().uuidString).bin")
        // Tiny payload — content doesn't matter, recognize() just reads
        // and base64-encodes it before the stub intercepts the request.
        try? Data([0x01, 0x02, 0x03, 0x04]).write(to: url)
        return url
    }()

    private static let singleWordResponse: String = """
    {
      "results": [{
        "alternatives": [{
          "transcript": "hello",
          "confidence": 0.95,
          "words": [{"startOffset": "0.0s", "endOffset": "0.5s", "word": "hello"}]
        }],
        "resultEndOffset": "0.5s"
      }]
    }
    """

    private func makeOptions(session: URLSession) -> GoogleSTTBackendV2.RecognizeOptions {
        GoogleSTTBackendV2.RecognizeOptions(
            token: "test-token",
            project: "test-project",
            region: "us",
            model: "chirp_3",
            languageCodes: ["en-US"],
            cacheDir: nil,
            session: session,
        )
    }
}

// MARK: - URLProtocol stub

/// Records each request and replies according to a scripted scenario.
/// Driven through `URLSessionConfiguration.protocolClasses` so we don't
/// touch the network at all.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    enum Step {
        case success(jsonBody: String)
        case failure(URLError)
        case httpError(status: Int, body: String)
    }

    /// Per-process scenario storage. URLProtocol instances are created by
    /// URLSession so we can't inject state directly — we tag the
    /// configuration with a UUID and look up the script here.
    private static let lock = NSLock()
    private static var scenarios: [UUID: Scenario] = [:]

    final class Scenario: @unchecked Sendable {
        let steps: [Step]
        private let counterLock = NSLock()
        private var counter = 0

        init(steps: [Step]) { self.steps = steps }

        func nextStep() -> Step? {
            counterLock.lock()
            defer { counterLock.unlock() }
            guard counter < steps.count else { return nil }
            let step = steps[counter]
            counter += 1
            return step
        }

        func attempts() -> Int {
            counterLock.lock()
            defer { counterLock.unlock() }
            return counter
        }
    }

    static func scenario(steps: [Step]) -> Scenario {
        Scenario(steps: steps)
    }

    /// Build a URLSession that routes through this stub for the lifetime
    /// of `scenario`. Each scenario gets a unique header so concurrent
    /// tests can't cross-talk.
    static func makeSession(scenario: Scenario) -> URLSession {
        let id = UUID()
        lock.lock()
        scenarios[id] = scenario
        lock.unlock()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Stub-Scenario": id.uuidString]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: "X-Stub-Scenario") != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Stub-Scenario").flatMap(UUID.init),
              let scenario = Self.lookup(id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard let step = scenario.nextStep() else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        switch step {
        case .success(let body):
            sendResponse(status: 200, body: body)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .httpError(let status, let body):
            sendResponse(status: status, body: body)
        }
    }

    override func stopLoading() {}

    private func sendResponse(status: Int, body: String) {
        let url = request.url ?? URL(fileURLWithPath: "/")
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"],
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func lookup(_ id: UUID) -> Scenario? {
        lock.lock()
        defer { lock.unlock() }
        return scenarios[id]
    }
}
