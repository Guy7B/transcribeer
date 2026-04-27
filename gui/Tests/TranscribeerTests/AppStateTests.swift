import Foundation
import Testing
@testable import TranscribeerApp

struct AppStateTests {
    // MARK: - isRecording

    @Test("isRecording is true only for .recording state",
          arguments: [
              (AppState.idle, false),
              (.recording(startTime: .now), true),
              (.transcribing, false),
              (.summarizing, false),
              (.done(sessionPath: "/tmp"), false),
              (.error(message: "fail", sessionPath: nil, kind: .other), false),
          ])
    func isRecording(state: AppState, expected: Bool) {
        #expect(state.isRecording == expected)
    }

    // MARK: - isBusy

    @Test("isBusy is true for recording, transcribing, and summarizing",
          arguments: [
              (AppState.idle, false),
              (.recording(startTime: .now), true),
              (.transcribing, true),
              (.summarizing, true),
              (.done(sessionPath: "/tmp"), false),
              (.error(message: "fail", sessionPath: nil, kind: .other), false),
          ])
    func isBusy(state: AppState, expected: Bool) {
        #expect(state.isBusy == expected)
    }

    // MARK: - statusText

    @Test("Idle state has empty status text")
    func idleStatusText() {
        #expect(AppState.idle.statusText.isEmpty)
    }

    @Test("Transcribing shows pencil emoji")
    func transcribingStatusText() {
        #expect(AppState.transcribing.statusText == "📝 Transcribing…")
    }

    @Test("Summarizing shows thinking emoji")
    func summarizingStatusText() {
        #expect(AppState.summarizing.statusText == "🤔 Summarizing…")
    }

    @Test("Done shows checkmark")
    func doneStatusText() {
        #expect(AppState.done(sessionPath: "/tmp").statusText == "✓ Done")
    }

    @Test("Error includes the message")
    func errorStatusText() {
        let msg = "Something went wrong"
        let state = AppState.error(message: msg, sessionPath: nil, kind: .transcription)
        #expect(state.statusText == "⚠ \(msg)")
    }

    @Test("Recording status includes elapsed time format")
    func recordingStatusFormat() {
        let past = Date().addingTimeInterval(-125) // 2m 5s ago
        let text = AppState.recording(startTime: past).statusText
        #expect(text.hasPrefix("⏺ Recording"))
        #expect(text.contains("02:0"))
    }

    // MARK: - Error payload accessors

    @Test("errorMessage returns the message only for .error states")
    func errorMessageAccessor() {
        let err: AppState = .error(message: "boom", sessionPath: "/tmp/s", kind: .transcription)
        #expect(err.errorMessage == "boom")
        #expect(AppState.idle.errorMessage == nil)
    }

    @Test("errorSessionPath round-trips the attached session URL")
    func errorSessionPathAccessor() {
        let err: AppState = .error(message: "boom", sessionPath: "/tmp/s", kind: .transcription)
        #expect(err.errorSessionPath == "/tmp/s")
        let bare: AppState = .error(message: "boom", sessionPath: nil, kind: .other)
        #expect(bare.errorSessionPath == nil)
    }

    @Test("errorKind reports the categorised stage that failed",
          arguments: [
              (AppState.ErrorKind.transcription, AppState.ErrorKind.transcription),
              (.recording, .recording),
              (.summarization, .summarization),
              (.other, .other),
          ])
    func errorKindAccessor(input: AppState.ErrorKind, expected: AppState.ErrorKind) {
        let state: AppState = .error(message: "x", sessionPath: nil, kind: input)
        #expect(state.errorKind == expected)
    }
}
