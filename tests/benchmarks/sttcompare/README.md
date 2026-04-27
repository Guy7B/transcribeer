# STT Backend Comparison Harness

A local, scriptable comparison of every realistic transcription + diarization
configuration we can plausibly ship in Transcribeer, run on a single audio file
so you can eyeball the quality differences.

## What it runs

| ID | Transcription | Diarization | Notes |
|----|---------------|-------------|-------|
| A | Google STT v1 `default` | Google (v1 diar) | Current baseline — the broken one |
| B | Google STT v1 `default` | Pyannote/SpeakerKit | Smallest fix for the reported Hebrew bug |
| C | Google STT v2 Chirp 2 | Pyannote | Chirp 2 does NOT support Hebrew; expected to fail for `he`, works for other langs |
| D | Google STT v2 Chirp 3 | Pyannote | Hebrew Preview on Chirp 3; best v2 option for Hebrew |
| E | WhisperKit `large-v3-turbo` | Pyannote | Fully on-device. Already the app's fallback path |
| F | WhisperKit `large-v3` (full) | Pyannote | On-device, slower but often more accurate than turbo |

Everything writes into `output/` and generates `COMPARISON.md`.

## Requirements

- macOS 15+ Apple Silicon (same as the app)
- `ffmpeg` (`brew install ffmpeg`) — used for audio normalization
- Swift toolchain (ships with Xcode)
- Python 3.10+ (standard library only)
- **For A/B:** Google STT v1 **API key** in macOS Keychain under
  `transcribeer/google_stt` (account `apikey`) — same entry the GUI uses. Or
  export `GOOGLE_STT_API_KEY`.
- **For C/D:** GCP project + `gcloud auth application-default login` so
  `gcloud auth application-default print-access-token` works. Pass the project
  via `--project`, `$GOOGLE_CLOUD_PROJECT`, or `gcloud config set project`.
- **For E/F:** WhisperKit models auto-download on first run into
  `~/.transcribeer/models/` (`large-v3-turbo` is ~1.5 GB, `large-v3` is ~3 GB).

## Run

```sh
cd tests/benchmarks/sttcompare

# Run EVERYTHING on your test recording (defaults: he, auto-speakers)
python3 run.py ~/.transcribeer/sessions/2026-04-23-1406-1/audio.m4a \
    --num-speakers 4

# Run only specific options (by short id or full id):
python3 run.py <audio> --only A,B,E --language he

# Skip slow or provider-dependent options:
python3 run.py <audio> --skip C,F --language he

# Override GCP project for v2 runs:
python3 run.py <audio> --only D --project my-gcp-project --language he

# Force re-run (ignore cached .raw.json):
python3 run.py <audio> --force
```

## Output

```
output/
├── A-google-v1-googdiar.txt            # each transcript as the app's [MM:SS -> MM:SS] Speaker N: text format
├── B-google-v1-pyannote.txt
├── C-google-v2-chirp2-pyannote.txt
├── D-google-v2-chirp3-pyannote.txt
├── E-whisperkit-turbo-pyannote.txt
├── F-whisperkit-large-v3-pyannote.txt
├── <option>.raw.json                    # raw provider response per option
├── pyannote.json                        # shared Pyannote output (re-used across all Pyannote-diar options)
├── metadata.json                        # timings, segment counts, detected speaker counts
├── logs/                                # stderr from every subprocess
└── COMPARISON.md                        # summary table + first 2 min side-by-side
```

## How it mirrors the production pipeline

- Audio normalization (`lib/audio.py`): identical to
  `gui/Sources/TranscribeerApp/Services/GoogleSTTBackend.swift writeLinear16WAV`
  (16 kHz mono 16-bit LINEAR16) + `gui/Sources/TranscribeerCore/AudioChunker.swift`
  (55 s chunk split). ffmpeg does the decoding rather than AVFoundation, but
  the on-wire bytes are identical.
- Word/diarization alignment (`lib/align.py`): a line-for-line port of
  `gui/Sources/TranscribeerCore/TranscriptFormatter.swift assignSpeakers + format`.
- Pyannote diarization: the `diarize-cli` Swift target uses the same
  `SpeakerKit` initialization as
  `gui/Sources/TranscribeerCore/DiarizationService.swift`.
- WhisperKit transcription: the existing `transcribe-cli` is reused; JSON mode
  was added so segment-level timestamps are available for the aligner.

## Caching

Each run caches raw provider output to `output/<id>.raw.json` and Pyannote
output to `output/pyannote.json`. Re-running without `--force` skips any
backend whose raw JSON already exists, so iterating on formatting/report
layout is cheap.

## Why not integrate this into the GUI?

This is an evaluation tool, not a product feature. Once you pick a
winning configuration we'll wire it into the GUI's settings as a normal
`TranscriptionBackendKind`. This harness is disposable; keep it if you
want to re-benchmark later.
