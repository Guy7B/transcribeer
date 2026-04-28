<div align="center">
  <img src="assets/logo-readme.png" width="120" alt="Transcribeer logo"/>
  <h1>Transcribeer 🍺</h1>
  <p><strong>Local-first meeting transcription and summarization for macOS</strong></p>
  <p><sub>A downstream fork of <a href="https://github.com/moshebe/transcribeer">moshebe/transcribeer</a> with additional transcription backends and quality-of-life improvements.</sub></p>
  <p>
    <img src="https://img.shields.io/badge/macOS-15%2B-blue?logo=apple" alt="macOS 15+"/>
    <img src="https://img.shields.io/badge/Apple_Silicon-arm64-green" alt="Apple Silicon"/>
    <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"/>
  </p>
</div>

---

Transcribeer captures both sides of any call, transcribes with speaker labels, and optionally summarizes with an LLM — all running locally on your Mac. No cloud required for transcription unless you opt in.

> **Looking for the original project?** [moshebe/transcribeer](https://github.com/moshebe/transcribeer). All credit for the foundation goes there.

## What this fork adds

This fork integrates [Kostya Ostrovsky's improvements](https://github.com/kostyay/transcribeer) (PRs #3 / #4 / #5 not yet upstreamed) plus a pluggable transcription-backend layer, AEC auto-detect, and several UX fixes. If you want only what's in the upstream release, install [moshebe/transcribeer](https://github.com/moshebe/transcribeer) directly.

| Addition | From | Notes |
|---|---|---|
| **Pluggable transcription backends** — WhisperKit (on-device), Google Cloud STT v1, Google STT v2 / Chirp 3 | this fork | Hebrew-tuned via Chirp 3 |
| **AEC auto-detect** — voice processing engages only when speakers + mic share an acoustic path | this fork | Headphones → off; speakers / AirPods → on |
| **TranscriptStore manifest** — multiple transcripts per session, re-transcribe with a different backend without overwriting | this fork | `transcripts/` subdirectory + `index.json` |
| **Live AX permission polling** — Accessibility banner clears within 2 s of granting in System Settings, no app restart | this fork | |
| **Failure banner** — surfaces the last transcription error with Open log / Retry / Reveal in Finder | this fork | |
| **Recording controls inside the History window** — Record/Stop/Settings/Import alongside the session list | this fork | |
| **Audio file import** — drag any AVFoundation-readable file (Voice Memos, Zoom recordings, .m4a, .wav) in as a new session | this fork | |
| Dual-source audio capture — separate `audio.mic.caf` + `audio.sys.caf` | kostyay PR #5 | Replaces the old ScreenCaptureKit single-stream path |
| Stable code-signing identity — TCC permissions persist across rebuilds | kostyay PR #3 | `make setup-dev-cert` |
| Auto-record Zoom meetings with cancellable countdown | kostyay PR #3 | Configurable delay |
| Sidebar grouped by date with wall-clock time ranges | kostyay PR #4 | "Today / Yesterday / weekday / month" buckets |
| Zoom title + participants enrichment | kostyay PR #5 | Auto-names sessions, captures attendees |

## Features

- **Dual-source audio capture** — records microphone and system audio separately via Core Audio process tap + AVAudioEngine, then mixes to a single 48 kHz / 128 kbps AAC timeline
- **Pluggable transcription** — pick at runtime between WhisperKit (on-device), Google Cloud Speech-to-Text v1, or Google STT v2 (Chirp 3, Hebrew-tuned)
- **On-device transcription** — [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML, Apple Silicon optimized), multilingual
- **Speaker diarization** — who said what, via [SpeakerKit](https://github.com/argmaxinc/WhisperKit) (Pyannote, on-device); inline diarization on Google STT v1 when supported
- **LLM summarization** — Ollama (local), OpenAI, Anthropic, or Gemini (via Google Cloud ADC)
- **Streaming summaries** — live markdown preview as the LLM generates output
- **Custom summary profiles** — swap in a different prompt per session without touching config
- **Smart echo cancellation** — auto-detects whether your output device shares an acoustic path with the mic and engages voice processing only when it'll actually help
- **Native SwiftUI menubar app + window** — start/stop from the menu bar or from the Recording History window; multi-select delete, drag-and-drop import, search
- **Zoom integration** — auto-detect active meetings, optional auto-record with cancellable countdown, meeting topic + participant capture
- **Obsidian plugin** — auto-imports sessions into your vault as notes

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Audio capture | Core Audio process tap + AVAudioEngine (Swift) |
| Mixing | AVAudioEngine + AVAssetWriter (48 kHz AAC, 128 kbps) |
| Transcription (on-device) | [WhisperKit](https://github.com/argmaxinc/WhisperKit) |
| Transcription (cloud, optional) | Google Cloud Speech-to-Text v1 / v2 (Chirp 3) |
| Diarization | [SpeakerKit](https://github.com/argmaxinc/WhisperKit) (Pyannote, on-device) |
| Summarization | [Ollama](https://ollama.ai), [OpenAI](https://openai.com), [Anthropic](https://anthropic.com), [Gemini](https://cloud.google.com/vertex-ai) |
| GUI | Native SwiftUI menubar + window app |
| Credentials | macOS Keychain (per-backend), Google Cloud ADC for Gemini |

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon (arm64)
- ~1.5 GB free disk for WhisperKit + SpeakerKit models (downloaded on first transcription)

## Install

> A Homebrew tap is on the roadmap. Until then, install from source.

```bash
git clone https://github.com/Guy7B/transcribeer.git
cd transcribeer
make setup-dev-cert     # one-time: create a stable self-signed cert so TCC grants stick
make dev                # builds the GUI, registers it as a launch agent, starts on login
```

`make dev` installs Transcribeer.app into `gui/.build/Transcribeer.app` and registers a launch agent at `~/Library/LaunchAgents/com.transcribeer.menubar.plist` so it starts automatically when you log in.

If you'd rather run a one-off without auto-start:

```bash
make build-dev          # build the .app bundle only
open gui/.build/Transcribeer.app
```

To uninstall the launch agent without removing the bundle:

```bash
make dev-uninstall
```

### Side-by-side dev variant

If you're hacking on the code, build the dev variant — it has a distinct bundle ID (`com.transcribeer.menubar.dev`) and Dock icon, and coexists with a main install:

```bash
make build-dev-variant
open gui/.build/Transcribeer-dev.app
```

## First Run

On first launch macOS will prompt for **Microphone** and **System Audio Recording** permissions. Both are required to capture both sides of a call. System Audio Recording can be enabled in **System Settings → Privacy & Security → System Audio Recording**.

If you use the Zoom enricher (auto-naming sessions from the meeting topic + capturing participants), you'll also need to grant **Accessibility** in **System Settings → Privacy & Security → Accessibility**. The app shows a banner until this is granted; you can disable the enricher in Settings → Pipeline if you don't want the prompt.

On first transcription, WhisperKit and SpeakerKit models (~1.5 GB total) are downloaded automatically to `~/.transcribeer/models/`. One-time.

## Using the app

Click the menubar icon to start/stop recording, or use the in-window **Record** button after opening **History…** from the menu. The full pipeline (record → transcribe → summarize) runs automatically based on your `pipeline.mode` config.

```bash
make logs               # stream live logs from the running launch agent
```

Each session is stored as a folder under `~/.transcribeer/sessions/` containing:

- `audio.mic.caf` — microphone recording (mono, original sample rate)
- `audio.sys.caf` — system audio recording (mono, original sample rate)
- `audio.m4a` — mixed output (AAC, 48 kHz, 128 kbps)
- `timing.json` — per-stream start timestamps for timeline alignment
- `meta.json` — session name, language, recording window, participants
- `transcript.txt` — current transcript (mirrors the active entry in `transcripts/`)
- `transcripts/` — full history of transcripts (re-runs with different backends preserved)
- `summary.md` — LLM-generated summary

## Configuration

Config is stored at `~/.transcribeer/config.toml`. The app reads + rewrites it whenever you change settings via the GUI; manual editing is fine too.

```toml
[pipeline]
mode = "record+transcribe+summarize"  # record-only | record+transcribe | record+transcribe+summarize
meeting_auto_record = false           # auto-start when a meeting is detected
meeting_auto_record_delay = 5         # seconds of cancellable countdown before auto-record
zoom_enricher_enabled = true          # read meeting topic + participants from Zoom (needs Accessibility)
max_meeting_participants = 50         # skip participant capture for meetings larger than this

[transcription]
backend = "whisperkit"                # whisperkit | google_stt | google_stt_v2
language = "auto"                     # auto, he, en, etc.
model = "openai_whisper-large-v3_turbo"
diarization = "pyannote"              # pyannote | none
num_speakers = 0                      # 0 = auto-detect

# Google STT v1 (legacy, for backends that support it)
google_stt_location = "global"
google_stt_model = "default"
google_stt_diarize = true

# Google STT v2 / Chirp (recommended for Hebrew + multilingual)
google_stt_v2_project = "your-gcp-project-id"
google_stt_v2_region = "us"
google_stt_v2_model = "chirp_3"

[summarization]
backend = "ollama"                    # ollama | openai | anthropic | gemini
model = "llama3"
ollama_host = "http://localhost:11434"
prompt_on_stop = true

[paths]
sessions_dir = "~/.transcribeer/sessions"

[audio]
input_device_uid = ""                 # empty = system default microphone
output_device_uid = ""                # empty = system default output
aec_mode = "auto"                     # auto | on | off (see below)
self_label = "You"
other_label = "Them"
diarize_mic_multiuser = false
```

### Echo cancellation (`aec_mode`)

| Mode | Behavior |
|---|---|
| `auto` (default) | At recording start, inspect the active output device. Engage Voice Processing IO only when speakers and mic share an acoustic path (built-in speakers, AirPods, HDMI/AirPlay). Wired headphones → leave audio untouched. |
| `on` | Always engage. Cleanest mic track, but the system audio session is in voice/communication mode while recording (lowered volume, voice EQ on output). |
| `off` | Never engage. System audio plays untouched, but if you're on speakers the mic track will pick up bleed and create an echo in the mix. |

Each session's `run.log` records the effective decision (e.g. `audio.aec.mode=auto effective=true reason=auto: speakers / monitor / AirPlay — feedback risk`) so you can always see why a given recording went the way it did.

### API keys

API keys for OpenAI, Anthropic, and Google STT v1 are stored in the **macOS Keychain** — never in the config file. Enter them once via **Settings** in the menubar app; they're saved securely and retrieved automatically.

Gemini summarization uses Google Cloud Application Default Credentials (ADC). Run `gcloud auth application-default login` and set your project via `gcloud config set project <id>` — the app reads the credentials automatically. Settings → Summarization → Gemini shows the live ADC status.

Google STT v2 uses the same ADC flow as Gemini.

## Summary profiles

A profile is a Markdown file with a custom system prompt. Profiles let you get different summary styles without changing global config.

```bash
mkdir -p ~/.transcribeer/prompts
cat > ~/.transcribeer/prompts/standup.md <<'EOF'
Summarize this meeting as a concise standup update:
- What was discussed
- Decisions made
- Action items and owners
EOF
```

Pick the profile from the in-app **Profile** dropdown when stopping a recording, or per-session in the History window's Summary controls (where you can also override the LLM model and add a one-shot focus instruction without touching config).

## Obsidian plugin

The plugin watches `~/.transcribeer/sessions/` and auto-imports new sessions into your vault as notes with YAML frontmatter and a collapsible transcript.

```bash
make obsidian-plugin OBSIDIAN_VAULT="/path/to/your/vault"
```

Then in Obsidian: **Settings → Community Plugins → enable Transcribeer**.

Each imported note includes:
- Date, tags, and source path in frontmatter
- The LLM summary as the note body
- The full transcript in a collapsible callout block

## Building & developing

```bash
make gui-build          # build Swift GUI binary (debug or release per env)
make build-dev          # assemble .app bundle from the current binary
make build-dev-variant  # also create the side-by-side Transcribeer-dev.app
make gui                # build + launch the menubar app
make dev                # full dev install (GUI + launch agent on login)
make dev-uninstall      # remove the launch agent (keeps the bundle)
make dev-restart        # kick the launch agent to pick up a new build
make logs               # stream live logs from the running app
make lint               # run swiftlint
make lint-strict        # run swiftlint with --strict (CI mode)
make obsidian-plugin OBSIDIAN_VAULT=~/path/to/vault
```

If TCC permissions get into a weird state after rebuilds with different signatures:

```bash
make reset-mac-permissions   # resets Microphone, System Audio Recording,
                             # Accessibility, etc. for both the main and
                             # dev bundle IDs (asks for sudo)
```

Tests:

```bash
cd gui && swift test                    # GUI unit tests (Swift Testing)
cd capture && swift test                # CaptureCore tests
cd tests/e2e && uv run pytest           # end-to-end (needs API keys for LLM tests)
```

> **Note**: `swift test` requires Xcode (it provides the `Testing` framework). Command Line Tools alone is not enough.

## Recording consent

> **You are solely responsible for complying with all applicable laws and regulations regarding the recording of conversations in your jurisdiction.** Many jurisdictions require the consent of all parties before a conversation may be recorded. Always obtain necessary consent before recording any meeting or call. The authors of this software accept no liability for misuse.

## Attribution

This fork stands on the shoulders of:

- **[moshebe/transcribeer](https://github.com/moshebe/transcribeer)** — the original Transcribeer project. All core architecture, the SwiftUI menubar app, WhisperKit + SpeakerKit + LLM integration, the Obsidian plugin, and the recording pipeline are theirs.
- **[kostyay/transcribeer](https://github.com/kostyay/transcribeer)** — Kostya Ostrovsky's fork, which authored the dual-source capture rewrite, persistent code-signing tooling, Zoom auto-record + topic/participant enrichment, and recording-window timestamps. PRs #3, #4, and #5 from his fork are merged here. They have not (yet) been upstreamed.

If you're interested in contributing back to the original maintainers, please open PRs against [moshebe/transcribeer](https://github.com/moshebe/transcribeer) directly rather than this fork.

## License

MIT — see [LICENSE](LICENSE). Original copyright © Moshe Bergman et al.; modifications in this fork are also MIT-licensed.
