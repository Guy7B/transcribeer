# Changelog

This is the changelog for the [Guy7B fork](https://github.com/Guy7B/transcribeer) of Transcribeer. The original project's history is at [moshebe/transcribeer](https://github.com/moshebe/transcribeer/blob/main/CHANGELOG.md).

The format is loosely based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are not yet tagged on this fork; entries below describe work landed on `main`.

## Unreleased

### Added (this fork)

- **AEC auto-detect** — new `aec_mode = "auto" | "on" | "off"` config replaces the old binary `aec` toggle. In auto mode, `OutputDeviceClassifier` reads `kAudioDevicePropertyTransportType` + `kAudioDevicePropertyDataSource` at recording start and engages Voice Processing IO only when speakers and mic share an acoustic path (built-in speakers, AirPods, HDMI/AirPlay → on; wired headphones → off). The decision lands in `run.log` so you can see why each session went the way it did. Legacy `aec = true|false` config values migrate automatically (true → `on`, false → `off`).
- **Pluggable transcription backends** — new `TranscriptionBackend` protocol with `WhisperKitBackend` (existing on-device), `GoogleSTTBackend` (v1 Google Cloud Speech-to-Text, with chunking + caching + Hebrew carve-out for diarization), and `GoogleSTTBackendV2` (Chirp 3 — Hebrew-tuned streaming model). Selected via `[transcription] backend = "..."` in config or per-session in the GUI.
- **TranscriptStore manifest** — sessions can now hold multiple transcripts (`transcripts/index.json` + per-run files). Re-transcribing with a different backend or language preserves earlier runs instead of overwriting them.
- **Failure banner** in `SessionDetailView` — surfaces the last transcription error from `run.log` with Open log / Retry / Reveal in Finder actions.
- **Live AX permission polling** — the Accessibility banner in `HistoryView` clears within ~2 s of granting in System Settings, no app restart needed. macOS doesn't push TCC change notifications, so the banner reads from a polled `@State` updated by a `.task` loop.
- **Audio file import** — drag any AVFoundation-readable file (Voice Memos, Zoom recordings, .m4a, .wav) into the History window to create a new session from it.
- **In-window recording controls** — Record / Stop / Cancel / Settings / Import buttons in the History window's control bar, parallel to the menubar dropdown.
- **Sidebar grouping by date with time ranges** — sessions appear under "Today / Yesterday / Wednesday / April / 2024" buckets with `13:38–14:17` time ranges instead of just timestamps. (Initially merged from kostyay PR #4; rendering integrated with the in-window control bar.)

### Fixed

- **UI layout overflow** post-merge: kostyay's PR #5 introduced an unbounded markdown ScrollView in `SessionDetailView` that ballooned `NavigationSplitView` past the window height (~1958 px on an 875 px window), pushing the controlBar, session header, audio player, and tab bar above `y=0`. Hoisted window chrome out of `NavigationSplitView` and pinned the inner VStack + tabContent to `.frame(maxHeight: .infinity)` so a tall summary scrolls inside its ScrollView instead of expanding parents.
- **TCC permission tooling**: `make reset-mac-permissions` now resets both `com.transcribeer.menubar` and `com.transcribeer.menubar.dev` (previously only the main bundle ID).

### Merged from kostyay/transcribeer

The following landed via [`Merge kostyay/main`](https://github.com/Guy7B/transcribeer/commit/3c0d328) — three substantive PRs from Kostya Ostrovsky's fork that are not yet upstreamed:

- **PR #5 — Fold capture CLI into app + dual-source pipeline.** Replaces the old `capture-bin` (ScreenCaptureKit single-stream) with in-process `CaptureCore` using Core Audio process tap + AVAudioEngine. Sessions now store separate `audio.mic.caf`, `audio.sys.caf`, and `timing.json` alongside the mixed `audio.m4a`. Mixed output upgraded to 48 kHz / 128 kbps AAC (from 16 kHz). New `DualSourceTranscriber` runs each lane independently and merges by timestamp. New Meeting services (`MeetingDetector`, `ZoomTitleReader`, `ZoomParticipantsReader/Watcher`, `SessionParticipantsRecorder`, `AccessibilityGuard`). New Audio Settings tab (custom Self / Other labels, device pickers, echo cancellation toggle, optional mic-track diarization). Diarization off by default for two-party calls.
- **PR #4 — Recording window timestamps + sidebar UI refinements.** ISO-8601 `startedAt` / `endedAt` persisted in `meta.json`. New `SessionDateFormatter` ("Jun 15 · 10:30 – 11:15") and `SessionGrouper` ("Today / Yesterday / weekday / month") services. New `isCancelling` UI state during long-running cancellation.
- **PR #3 — Code-signing identity management + Zoom auto-record delay.** `make setup-dev-cert` creates a stable self-signed cert in the login keychain so TCC permissions persist across rebuilds. New Make targets (`check-identity`, `sign`, `reset-mac-permissions`). Configurable `zoomAutoRecordDelay` (default 5 s) with cancellable countdown notification. Hardened runtime + microphone usage description.

### Pre-merge work (this fork)

- **Pluggable transcription backends — WIP checkpoint.** Single large commit ([`625ae29`](https://github.com/Guy7B/transcribeer/commit/625ae29)) introducing the backend abstraction and Google STT v1 / v2 implementations before merging kostyay's work on top. Includes `GoogleAuthHelper` for ADC / service-account flows, `TranscriptStore` + `RunLogReader` + `SessionLog` persistence layer, `TranscriptRecord` model, `TranscriptionSettingsView` UI, `AudioChunker` enhancements, plus comprehensive Swift Testing coverage for routing, kinds, cache, resume, and retries. Benchmarks scaffold + `diarize-cli` for offline evaluation.
- **Claude catalog refresh** for summarization to include 4.5 / 4.6 / 4.7 model identifiers ([`6374e54`](https://github.com/Guy7B/transcribeer/commit/6374e54)).
- **Debounced API key save** in `SettingsView` so rapid edits don't hammer the Keychain ([`894c8e5`](https://github.com/Guy7B/transcribeer/commit/894c8e5)).

## Inherited from upstream

For features that were already in [moshebe/transcribeer](https://github.com/moshebe/transcribeer) when this fork branched off (the SwiftUI menubar app, WhisperKit + SpeakerKit integration, LLM summarization across Ollama / OpenAI / Anthropic / Gemini, the Obsidian plugin, the SwiftLint setup, etc.), see the upstream changelog.
