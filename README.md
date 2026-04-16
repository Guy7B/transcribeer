<div align="center">
  <img src="assets/logo-readme.png" width="120" alt="Transcribeer logo"/>
  <h1>Transcribeer 🍺</h1>
  <p><strong>Local-first meeting transcription and summarization for macOS</strong></p>
  <p>
    <img src="https://img.shields.io/badge/macOS-15%2B-blue?logo=apple" alt="macOS 15+"/>
    <img src="https://img.shields.io/badge/Apple_Silicon-arm64-green" alt="Apple Silicon"/>
    <img src="https://img.shields.io/badge/license-MIT-green" alt="MIT License"/>
  </p>
</div>

---

Transcribeer captures both sides of any call, transcribes with speaker labels, and optionally summarizes with an LLM — all running locally on your Mac. No cloud required. Zero Python dependencies.

## Features

- **System audio capture** — records both microphone and speaker audio via Apple ScreenCaptureKit
- **On-device transcription** — [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML, Apple Silicon optimized)
- **Speaker diarization** — who said what, via [SpeakerKit](https://github.com/argmaxinc/WhisperKit) (Pyannote backend)
- **LLM summarization** — Ollama (local), OpenAI, or Anthropic
- **Custom summary profiles** — swap in a different prompt per session without touching config
- **Native macOS menubar app** — start/stop recording from the menu bar, session browser, settings UI

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Audio capture | [Apple ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) (Swift) |
| Transcription | [WhisperKit](https://github.com/argmaxinc/WhisperKit) (CoreML, on-device) |
| Diarization | [SpeakerKit](https://github.com/argmaxinc/WhisperKit) (Pyannote, on-device) |
| Summarization | [Ollama](https://ollama.ai) (local), [OpenAI](https://openai.com), [Anthropic](https://anthropic.com) |
| GUI | Native SwiftUI menubar app |
| Credentials | macOS Keychain (API keys stored securely per-service) |

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon (arm64)

## Install

**Homebrew (recommended):**

```bash
brew tap moshebe/pkg
brew install transcribeer
```

**From source:**

```bash
git clone https://github.com/moshebe/transcribeer.git
cd transcribeer
make dev
```

## Running Permanently (auto-start on login)

```bash
brew services start transcribeer
```

This registers the menubar app as a launchd service so it launches automatically when you log in. To stop auto-start:

```bash
brew services stop transcribeer
```

## First Run

```bash
make gui                  # build + launch the native menubar app
```

The first transcription will automatically download the WhisperKit model (~1.5 GB) and SpeakerKit models. This is a one-time download stored in `~/.transcribeer/models/`.

## Configuration

Config is stored at `~/.transcribeer/config.toml`:

```toml
[pipeline]
mode = "record+transcribe+summarize"   # record-only, record+transcribe, record+transcribe+summarize
zoom_auto_record = false

[transcription]
language = "auto"           # auto, he, en, etc.
diarization = "pyannote"    # pyannote, none
num_speakers = 0            # 0 = auto-detect

[summarization]
backend = "ollama"          # ollama, openai, anthropic
model = "llama3"
ollama_host = "http://localhost:11434"
prompt_on_stop = true
```

### API Keys

API keys for OpenAI and Anthropic are stored in the **macOS Keychain** — never in the config file. Enter them once via **Settings** in the menubar app; they are saved securely and retrieved automatically on each run.

## Summary Profiles

A profile is a Markdown file containing a custom system prompt. Profiles let you get different summary styles (e.g. bullet-point action items vs. a narrative recap) without changing the global config.

**Create a profile:**

```bash
mkdir -p ~/.transcribeer/prompts
cat > ~/.transcribeer/prompts/standup.md <<'EOF'
Summarize this meeting as a concise standup update:
- What was discussed
- Decisions made
- Action items and owners
EOF
```

**Use a profile:**

- **Menubar**: click **Profile** in the menu during or after a recording and type the profile name

The built-in default prompt is used when no profile is selected. Profiles live in `~/.transcribeer/prompts/*.md`; the filename (without `.md`) is the profile name.

## Building from Source

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Recording Consent

> **You are solely responsible for complying with all applicable laws and regulations regarding the recording of conversations in your jurisdiction.** Many jurisdictions require the consent of all parties before a conversation may be recorded. Always obtain necessary consent before recording any meeting or call. The authors of this software accept no liability for misuse.

## License

MIT — see [LICENSE](LICENSE).
