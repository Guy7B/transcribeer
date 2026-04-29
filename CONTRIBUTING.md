# Contributing to Transcribeer

Thanks for your interest. This is the contributing guide for the [Guy7B fork](https://github.com/Guy7B/transcribeer). If you want to contribute to the **original** Transcribeer project, head to [moshebe/transcribeer](https://github.com/moshebe/transcribeer) instead — see the "Contributing upstream" section below for the workflow.

## Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon (arm64)
- **Xcode** (not just Command Line Tools) — required for `swift test` (the `Testing` framework ships with Xcode, not CLT) and for the SourceKit framework SwiftLint depends on. If `xcode-select -p` returns `/Library/Developer/CommandLineTools`, install Xcode and run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`.
- [SwiftLint](https://github.com/realm/SwiftLint): `brew install swiftlint`

Optional, for the end-to-end Python harness only:

- [uv](https://github.com/astral-sh/uv) — only used by `tests/e2e/` and `tests/benchmarks/`, not by the app itself

## Dev setup

```bash
git clone https://github.com/Guy7B/transcribeer.git
cd transcribeer

# One-time: create a stable self-signed cert so TCC permission grants
# survive rebuilds. Without this, every `make build-dev` produces a
# differently-signed binary and macOS forgets your Microphone /
# System Audio Recording / Accessibility grants.
make setup-dev-cert

# Build a side-by-side dev variant that won't conflict with a main
# install. Bundle ID: com.transcribeer.menubar.dev — see Dock for it.
make build-dev-variant
open gui/.build/Transcribeer-dev.app
```

If you'd rather replace your main install (and have it auto-start on login):

```bash
make dev          # builds GUI + registers launch agent
make dev-restart  # kick the launch agent after a rebuild
make dev-uninstall  # remove the launch agent (keeps the bundle)
```

## Project layout

```
gui/                 SwiftUI menubar + window app (the main code surface)
  Sources/
    TranscribeerApp/   Views, services, view models
    TranscribeerCore/  Pure-Swift business logic, no GUI deps
  Tests/               Swift Testing suites
capture/             Core Audio capture library (CaptureCore)
  Sources/CaptureCore/   Process tap, mic capture, mixer
obsidian-plugin/     TypeScript + esbuild Obsidian plugin
tests/
  e2e/               Python pytest harness (LLM accuracy, etc.)
  benchmarks/        Python STT comparison tooling
docs/                Architecture notes, design plans
```

State + config (not in repo, on your Mac):

- `~/.transcribeer/config.toml` — user config
- `~/.transcribeer/sessions/` — recordings, transcripts, summaries
- `~/.transcribeer/models/` — WhisperKit + SpeakerKit models (~1.5 GB)

## Running tests

Swift Testing suites (Xcode required — see Requirements):

```bash
cd gui && swift test       # GUI internals + TranscribeerCore
cd capture && swift test   # CaptureCore (mixer, recorder, devices)
```

End-to-end Python harness (optional, for accuracy regressions):

```bash
cd tests/e2e
uv sync
uv run pytest               # needs LLM API keys for the cloud-backend tests
```

STT benchmark comparison (optional):

```bash
cd tests/benchmarks/sttcompare
uv sync
uv run python run.py        # see local README for details
```

## Linting

The Swift code is linted with [SwiftLint](https://github.com/realm/SwiftLint). Config: [`.swiftlint.yml`](.swiftlint.yml).

```bash
make lint          # warn on violations, fail on errors
make lint-fix      # auto-fix correctable violations
make lint-strict   # treat warnings as errors (CI mode)
```

CI runs `swiftlint lint --strict` on every PR and push to `main` ([`.github/workflows/lint.yml`](.github/workflows/lint.yml)).

## Project conventions

The full conventions live in [`AGENTS.md`](AGENTS.md). Highlights:

- Conventional commits: `feat:`, `fix:`, `refactor:`, `chore:`, `docs:`, `test:`
- One concern per PR — keep diffs focused
- No force-unwraps (`!`), no force-casts, no force-trys (SwiftLint enforces this as errors)
- Line length ≤ 120 (error at 160), file ≤ 600 lines, function body ≤ 80
- Swift Testing (`@Test`, `#expect`) — not XCTest
- Pure-logic tests only — no UI automation, no network in unit tests
- API keys live in macOS Keychain via `KeychainHelper` — never in config files or env vars in code paths intended for UI storage

## TCC permission troubleshooting

When you rebuild with a different code-signing identity, macOS may silently deny permissions even though System Settings shows them granted. To wipe TCC entries cleanly:

```bash
make reset-mac-permissions   # asks for sudo; resets both
                             # com.transcribeer.menubar and
                             # com.transcribeer.menubar.dev
```

Then re-grant via System Settings → Privacy & Security on next launch.

## Pull request checklist

Before opening a PR against this fork:

- [ ] `cd gui && swift build` passes
- [ ] `cd gui && swift test` passes (or document why it doesn't apply)
- [ ] `make lint-strict` passes
- [ ] Commit messages follow conventional commits
- [ ] PR targets the correct base (see below)

## Contributing upstream (moshebe/transcribeer)

If you've built something useful and want to send it to the original project, **branch from `upstream/main`, not from this fork's `main`** — that way your personal customizations (Google STT backend, etc.) don't leak into the upstream PR.

```bash
git remote add upstream https://github.com/moshebe/transcribeer.git
git fetch upstream
git checkout -b feat/something-for-upstream upstream/main
# work, commit
git push -u origin feat/something-for-upstream
gh pr create \
  --repo moshebe/transcribeer \
  --base main \
  --head Guy7B:feat/something-for-upstream
```

## Reporting issues

Please include:

- macOS version (`sw_vers`)
- Apple Silicon vs Intel (`uname -m`)
- The exact command or click flow that triggered the issue
- The full output / error message
- Whether you're on the dev variant (`com.transcribeer.menubar.dev`) or the main install (`com.transcribeer.menubar`)
- Relevant lines from `~/.transcribeer/sessions/<latest>/run.log` if a recording session was involved

Logs:

```bash
make logs   # streams unified log entries from the running app
```
