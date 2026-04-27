# Changelog

All notable changes are documented here.

## feat/openoats-capture-rewrite

Replaced the single-stream ScreenCaptureKit audio capture with a split-source architecture that records microphone and system audio as separate tracks. This eliminates the need for Screen Recording permission — macOS now prompts only for Microphone and the new System Audio Recording entitlement. Each session stores `audio.mic.caf`, `audio.sys.caf`, and `timing.json` alongside the mixed `audio.m4a`, enabling per-source transcription with accurate timeline alignment.

The mixed output is now 48 kHz AAC at 128 kbps (up from 16 kHz), significantly improving transcription quality for high-pitched voices and fast speech. Speaker labels are configurable in Settings under the new **Audio** tab: set custom "Self" and "Other" labels, choose specific input/output devices, toggle echo cancellation, and optionally enable diarization on the microphone track when multiple people share it. By default diarization is off and the transcript uses your chosen labels directly, removing the previous always-on SpeakerKit overhead for simple two-party calls.

New `make reset-mac-permissions` resets Microphone and System Audio Recording TCC entries (ScreenCapture has been removed). The README and first-run flow have been updated to guide users through the new permission model.





## feat/recording-timestamps-ui

Added recording window timestamps to sessions, allowing users to see exact start/end times (e.g., "Jun 15 · 10:30 – 11:15") in the sidebar for calendar correlation (#4). Introduced `SessionDateFormatter` and `SessionGrouper` services that intelligently format session timestamps and organize sessions into date-based groups (Today, Yesterday, weekday names, months), with fallback support for legacy sessions lacking timestamp data. Enhanced `PipelineRunner` to persist ISO-8601 formatted start/end times to session metadata and added an `isCancelling` state indicator for improved UI responsiveness during long-running cancellation operations. Comprehensive test coverage added via new `SessionDateFormatterTests`, `SessionGrouperTests`, and `SessionManagerRecordingTimesTests` to ensure correct date formatting across timezones and edge cases.

## feat/code-signing-and-zoom-delays

Added comprehensive code signing support with configurable identities and automatic self-signed certificate management, enabling persistent macOS TCC (Transparency, Consent, and Control) permissions across rebuilds (#3). Introduced `zoomAutoRecordDelay` configuration to allow users to customize the countdown before automatic Zoom meeting recording begins, with a new countdown notification UI and cancel action in the NotificationManager. Enhanced the build system with multiple new make targets (`setup-dev-cert`, `check-identity`, `sign`, `reset-mac-permissions`) to simplify developer workflows, entitlements management, and TCC permission troubleshooting on macOS. The capture binary and app bundle now use hardened runtime signing with proper entitlements for audio input and screen recording access, resolving permission persistence issues that previously required manual Keychain intervention.

## chore/add-swiftlint-configuration

Added comprehensive SwiftUI code quality enforcement, expanded LLM backend support, and significantly enhanced the GUI application with streaming summaries and live progress tracking (#2). Introduced a new SwiftUI design principles agent skill to guide polished UI development, integrated Gemini and Vertex AI as summarization backends alongside existing providers, and rebuilt core services (PipelineRunner, TranscriptionService, SummarizationService) to support real-time streaming output and improved state management. The GUI now features live session summaries with markdown rendering, enhanced settings UI for prompt management, detailed transcription progress visualization, and improved diarization service integration, while a new linting workflow enforces SwiftUI conventions across the codebase via SwiftLint configuration.

## docs/add-swiftui-expert-skill

Added comprehensive agent skills for Swift development expertise with two new specialized skill frameworks (#1). The **SwiftUI Expert Skill** provides extensive guidance across 17 reference documents covering layouts, animations, state management, accessibility, performance optimization, and platform-specific patterns for macOS and iOS. The **Swift Testing Pro** skill delivers detailed best practices for writing modern Swift Testing code, including async test patterns, migration guidance from XCTest, and core testing conventions aligned with Swift 6.2+. Both skills include OpenAI agent configuration and visual assets, enabling AI assistants to provide expert-level code reviews and testing recommendations within the agent ecosystem.
