import Testing
@testable import TranscribeerApp

/// Unit tests for `TranscribeerApp.meetingChangeAction` — the pure decision that
/// maps a meeting state transition to a routing action. Covers the scenarios
/// requested when adding process-exit based meeting-end detection.
struct TranscribeerAppMeetingChangeActionTests {
    typealias Inputs = TranscribeerApp.MeetingChangeInputs

    private func inputs(
        inMeeting: Bool,
        isRecording: Bool = false,
        isBusy: Bool = false,
        autoRecordEnabled: Bool = true,
        hasCountdown: Bool = false,
        autoStarted: Bool = false,
    ) -> Inputs {
        Inputs(
            inMeeting: inMeeting,
            isRecording: isRecording,
            isBusy: isBusy,
            autoRecordEnabled: autoRecordEnabled,
            hasCountdown: hasCountdown,
            autoStarted: autoStarted,
        )
    }

    // MARK: - Meeting end (inMeeting: false)

    @Test("Meeting-end during auto-started recording triggers stopRecording")
    func endDuringAutoStartedRecording() {
        let action = TranscribeerApp.meetingChangeAction(
            inputs(inMeeting: false, isRecording: true, isBusy: true, autoStarted: true),
        )
        #expect(action == .stopRecording)
    }

    @Test("Meeting-end during manually-started recording does NOT stop")
    func endDuringManualRecordingIsNoop() {
        let action = TranscribeerApp.meetingChangeAction(
            inputs(inMeeting: false, isRecording: true, isBusy: true, autoStarted: false),
        )
        #expect(action == .noop)
    }

    @Test("Meeting-end during countdown cancels the countdown")
    func endDuringCountdownCancels() {
        let action = TranscribeerApp.meetingChangeAction(
            inputs(inMeeting: false, hasCountdown: true),
        )
        #expect(action == .cancelCountdown)
    }

    @Test("Meeting-end during countdown AND auto-started recording cancels both")
    func endCancelsCountdownAndStops() {
        // Pathological but possible if a new detection kicked off a countdown while
        // a previous auto-recording was still in progress.
        let action = TranscribeerApp.meetingChangeAction(
            inputs(
                inMeeting: false,
                isRecording: true,
                isBusy: true,
                hasCountdown: true,
                autoStarted: true,
            ),
        )
        #expect(action == .cancelCountdownAndStopRecording)
    }

    @Test("Meeting-end while idle is a noop")
    func endWhileIdleIsNoop() {
        let action = TranscribeerApp.meetingChangeAction(inputs(inMeeting: false))
        #expect(action == .noop)
    }

    // MARK: - Meeting start (inMeeting: true) — existing behaviour sanity checks

    @Test("Meeting-start with auto-record enabled schedules auto-record")
    func startSchedulesAutoRecord() {
        let action = TranscribeerApp.meetingChangeAction(inputs(inMeeting: true))
        #expect(action == .scheduleAutoRecord)
    }

    @Test("Meeting-start with auto-record disabled sends notification")
    func startSendsNotification() {
        let action = TranscribeerApp.meetingChangeAction(
            inputs(inMeeting: true, autoRecordEnabled: false),
        )
        #expect(action == .sendMeetingNotification)
    }

    @Test("Meeting-start while already recording is a noop (no duplicate prompts)")
    func startWhileRecordingIsNoop() {
        let action = TranscribeerApp.meetingChangeAction(
            inputs(
                inMeeting: true,
                isRecording: true,
                isBusy: true,
                autoRecordEnabled: false,
                autoStarted: true,
            ),
        )
        #expect(action == .noop)
    }
}
