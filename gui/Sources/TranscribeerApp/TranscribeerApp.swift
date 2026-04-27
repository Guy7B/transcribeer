import TranscribeerCore
import os.log
import SwiftUI
import UserNotifications

private let logger = Logger(subsystem: "com.transcribeer", category: "app")

/// Live state for a pending meeting auto-record countdown.
///
/// Reference type so the owning view can identity-check the active countdown
/// inside the async timer task (user may cancel + new meeting detection may
/// start a fresh one before the old task observes cancellation).
@Observable
@MainActor
final class AutoRecordCountdown {
    var secondsRemaining: Int
    @ObservationIgnored var task: Task<Void, Never>?

    init(secondsRemaining: Int) {
        self.secondsRemaining = secondsRemaining
    }
}

@main
struct TranscribeerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var runner = PipelineRunner()
    @State private var meetingDetector = MeetingDetector()
    @State private var config = ConfigManager.load()
    @State private var autoRecordCountdown: AutoRecordCountdown?

    var body: some Scene {
        MenuBarExtra {
            menuContent
                .onChange(of: runner.state) { _, new in
                    DockTileBadger.setRecording(new.isRecording)
                }
        } label: {
            MenuBarIcon(runner: runner)
                .task { onFirstAppear() }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(config: $config)
        }

        Window("Recording History", id: "history") {
            HistoryView(config: $config, runner: runner)
        }
        .defaultSize(width: 900, height: 600)
    }

    // MARK: - Menu

    @ViewBuilder
    private var menuContent: some View {
        if config.zoomEnricherEnabled, !AccessibilityGuard.isTrusted {
            Text("⚠ Accessibility not granted — Zoom title & participants disabled")
            Button("Grant Accessibility…") {
                AccessibilityGuard.prompt()
                AccessibilityGuard.openSystemSettings()
            }
            Divider()
        }

        if let countdown = autoRecordCountdown {
            Text("⏱ Auto-recording in \(countdown.secondsRemaining)s")
            Button("⏹ Cancel auto-record") {
                cancelAutoRecordCountdown()
            }
            Divider()
        }

        switch runner.state {
        case .idle:
            if meetingDetector.inMeeting && autoRecordCountdown == nil {
                let appLabel = meetingDetector.detectedApp?.name ?? "Meeting"
                Button("⏺ Record \(appLabel)") {
                    startRecording(autoStarted: false)
                }
                Divider()
            }
            Button("Start Recording") {
                startRecording(autoStarted: false)
            }

        case .recording(let startTime):
            TimelineView(.periodic(from: startTime, by: 1)) { context in
                let elapsed = Int(context.date.timeIntervalSince(startTime))
                Text("⏺ Recording  \(String(format: "%02d:%02d", elapsed / 60, elapsed % 60))")
            }
            if let title = runner.liveMeetingTitle {
                Text("🎥 \(title)")
            }
            let names = runner.participantsWatcher.snapshot?
                .participants
                .map(\.displayName)
                .filter { !$0.isEmpty } ?? []
            if !names.isEmpty {
                Text("👥 \(names.joined(separator: ", "))")
            }
            Button("⏹ Stop Recording") {
                runner.stopRecording()
            }

        case .transcribing:
            if let pct = runner.transcriptionProgress {
                Text("📝 Transcribing… \(Int(pct * 100))%")
            } else {
                Text("📝 Transcribing…")
            }
            Button("⏹ Stop") {
                runner.cancelProcessing()
            }

        case .summarizing:
            Text("🤔 Summarizing…")
            Button("⏹ Stop") {
                runner.cancelProcessing()
            }

        case .done(let path):
            Text("✓ Done")
            Button("📁 Open Session") {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            Divider()
            Button("Start Recording") {
                startRecording(autoStarted: false)
            }

        case let .error(message, _, _):
            Text(verbatim: "⚠ \(message)")
            Divider()
            Button("Start Recording") {
                startRecording(autoStarted: false)
            }
        }

        Divider()

        Button("History…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "history")
        }
        SettingsLink {
            Text("Settings…")
        }

        Divider()

        Button("Quit") { NSApp.terminate(nil) }
    }

    @Environment(\.openWindow) private var openWindow

    // MARK: - Lifecycle

    private func onFirstAppear() {
        meetingDetector.start()
        showFirstRunOnboardingIfNeeded()

        // Wire notification "Start Recording" action → startRecording
        appDelegate.onRecord = { [runner] in
            Task { @MainActor in
                guard !runner.state.isBusy else { return }
                NotificationManager.cancelMeetingNotification()
                runner.startRecording(config: ConfigManager.load())
            }
        }
        appDelegate.onCancelAutoRecord = {
            Task { @MainActor in
                cancelAutoRecordCountdown()
            }
        }

        startMeetingChangeObservation()

        // Check if a meeting is already in progress at launch.
        if meetingDetector.inMeeting {
            handleMeetingChange(inMeeting: true)
        }
    }

    /// Observe `meetingDetector.inMeeting` independently of menu visibility.
    ///
    /// The `.onChange` on `menuContent` only fires while the menu is open
    /// (MenuBarExtra `.menu` style re-renders content on demand), so auto-record
    /// won't trigger for users who keep the menu closed. This re-arms after
    /// every observed change for the lifetime of the app.
    private func startMeetingChangeObservation() {
        var last = meetingDetector.inMeeting
        func arm() {
            withObservationTracking {
                _ = meetingDetector.inMeeting
            } onChange: {
                Task { @MainActor in
                    let current = meetingDetector.inMeeting
                    if current != last {
                        last = current
                        handleMeetingChange(inMeeting: current)
                    }
                    arm()
                }
            }
        }
        arm()
    }

    private func showFirstRunOnboardingIfNeeded() {
        let key = "com.transcribeer.onboardingShown"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.messageText = "Welcome to Transcribeer"
        alert.informativeText = (
            "Transcribeer needs two permissions to capture both sides of a call:\n\n"
                + "• Microphone — to record your voice.\n"
                + "• System Audio Recording — to record the other participants.\n\n"
                + "System Audio Recording can be enabled in System Settings → "
                + "Privacy & Security → System Audio Recording.\n\n"
                + "You can change devices, labels, and echo cancellation in Settings → Audio."
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Get Started")
        alert.runModal()
    }

    // MARK: - Meeting integration

    /// Pure decision for what a meeting state change implies. Extracted so the
    /// routing can be unit-tested without standing up the full app scene.
    enum MeetingChangeAction: Equatable {
        case noop
        case sendMeetingNotification
        case scheduleAutoRecord
        case cancelCountdown
        case stopRecording
        case cancelCountdownAndStopRecording
    }

    /// Inputs to `meetingChangeAction`. Grouped into a struct so callers stay
    /// under the positional-parameter limit and the decision reads like data.
    struct MeetingChangeInputs: Equatable {
        let inMeeting: Bool
        let isRecording: Bool
        let isBusy: Bool
        let autoRecordEnabled: Bool
        let hasCountdown: Bool
        let autoStarted: Bool
    }

    static func meetingChangeAction(_ inputs: MeetingChangeInputs) -> MeetingChangeAction {
        if inputs.inMeeting {
            if inputs.autoRecordEnabled, !inputs.isBusy, !inputs.hasCountdown {
                return .scheduleAutoRecord
            }
            if !inputs.isRecording, !inputs.hasCountdown {
                return .sendMeetingNotification
            }
            return .noop
        }
        switch (inputs.hasCountdown, inputs.isRecording && inputs.autoStarted) {
        case (true, true): return .cancelCountdownAndStopRecording
        case (true, false): return .cancelCountdown
        case (false, true): return .stopRecording
        case (false, false): return .noop
        }
    }

    private func handleMeetingChange(inMeeting: Bool) {
        if !inMeeting {
            NotificationManager.cancelMeetingNotification()
        }

        let inputs = MeetingChangeInputs(
            inMeeting: inMeeting,
            isRecording: runner.state.isRecording,
            isBusy: runner.state.isBusy,
            autoRecordEnabled: config.meetingAutoRecord,
            hasCountdown: autoRecordCountdown != nil,
            autoStarted: runner.meetingAutoStarted,
        )
        let action = Self.meetingChangeAction(inputs)
        logger.info(
            "meeting change: inMeeting=\(inMeeting, privacy: .public) isRec=\(inputs.isRecording, privacy: .public) isBusy=\(inputs.isBusy, privacy: .public) auto=\(inputs.autoRecordEnabled, privacy: .public) countdown=\(inputs.hasCountdown, privacy: .public) autoStarted=\(inputs.autoStarted, privacy: .public) → \(String(describing: action), privacy: .public)",
        )

        switch action {
        case .noop:
            break
        case .sendMeetingNotification:
            NotificationManager.sendMeetingNotification(appName: meetingDetector.detectedApp?.name)
        case .scheduleAutoRecord:
            scheduleAutoRecord()
        case .cancelCountdown:
            cancelAutoRecordCountdown()
        case .stopRecording:
            autoStopForMeetingEnd()
        case .cancelCountdownAndStopRecording:
            cancelAutoRecordCountdown()
            autoStopForMeetingEnd()
        }
    }

    private func autoStopForMeetingEnd() {
        let appName = runner.meetingAutoStartContext?.appName ?? "unknown"
        runner.appendRunLog("stop=auto reason=meeting-ended app=\(appName)")
        runner.stopRecording()
    }

    private func startRecording(autoStarted: Bool) {
        NotificationManager.cancelMeetingNotification()
        if !autoStarted {
            cancelAutoRecordCountdown()
        }
        runner.meetingAutoStartContext = autoStarted
            ? PipelineRunner.MeetingAutoStartContext(
                appName: meetingDetector.detectedApp?.name ?? "unknown",
                title: meetingTitle(),
                delaySeconds: max(0, config.meetingAutoRecordDelay),
            )
            : nil
        runner.startRecording(config: config)

        if autoStarted {
            notifyMeetingAutoRecord()
            prefillMeetingTitle()
        }
    }

    /// Resolve the best-known meeting title. Today only Zoom is supported via
    /// its AX topic; other apps return `nil` until dedicated enrichers land.
    /// Returns `nil` immediately when the user has disabled the Zoom enricher
    /// in Settings so no AX walk is performed.
    private func meetingTitle() -> String? {
        guard config.zoomEnricherEnabled,
              meetingDetector.detectedApp?.bundleID == "us.zoom.xos"
        else { return nil }
        return ZoomTitleReader.meetingTitle()
    }

    /// Send a notification announcing auto-record has started.
    /// Briefly waits (up to ~2s) for an enriched meeting title to populate before posting.
    private func notifyMeetingAutoRecord() {
        Task { @MainActor in
            for _ in 0..<10 {
                if meetingTitle() != nil { break }
                try? await Task.sleep(for: .milliseconds(200))
            }
            NotificationManager.notifyMeetingAutoRecordStarted(
                appName: meetingDetector.detectedApp?.name,
                title: meetingTitle(),
            )
        }
    }

    // MARK: - Auto-record countdown

    private func scheduleAutoRecord() {
        let delay = max(0, config.meetingAutoRecordDelay)
        logger.info("scheduleAutoRecord delay=\(delay, privacy: .public)s app=\(self.meetingDetector.detectedApp?.name ?? "-", privacy: .public)")
        if delay == 0 {
            startRecording(autoStarted: true)
            return
        }

        let countdown = AutoRecordCountdown(secondsRemaining: delay)
        autoRecordCountdown = countdown

        let appName = meetingDetector.detectedApp?.name
        let title = meetingTitle()
        NotificationManager.showMeetingCountdown(secondsRemaining: delay, appName: appName, title: title)

        countdown.task = Task { @MainActor in
            var remaining = delay
            while remaining > 0 {
                autoRecordCountdown?.secondsRemaining = remaining
                NotificationManager.showMeetingCountdown(
                    secondsRemaining: remaining,
                    appName: meetingDetector.detectedApp?.name ?? appName,
                    title: meetingTitle() ?? title,
                )
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return // cancelled
                }
                remaining -= 1
            }
            // Timer complete — only fire if still the active countdown.
            guard autoRecordCountdown === countdown else { return }
            autoRecordCountdown = nil
            NotificationManager.cancelMeetingCountdown()
            guard meetingDetector.inMeeting, !runner.state.isBusy else { return }
            startRecording(autoStarted: true)
        }
    }

    private func cancelAutoRecordCountdown() {
        autoRecordCountdown?.task?.cancel()
        autoRecordCountdown = nil
        NotificationManager.cancelMeetingCountdown()
    }

    /// After a short delay, read the meeting title and set it as the session name.
    private func prefillMeetingTitle() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard let session = runner.currentSession else { return }
            // Don't overwrite if already named.
            let meta = SessionManager.readMeta(session)
            if let name = meta["name"] as? String, !name.isEmpty { return }

            if let title = meetingTitle() {
                SessionManager.setName(session, title)
            }
        }
    }
}
