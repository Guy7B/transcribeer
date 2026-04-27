#!/usr/bin/env python3
"""Run all configured STT backends on a single audio file, generate a report.

Usage:
    python3 run.py <audio.m4a> [--language he] [--num-speakers 4]
                   [--output-dir tests/benchmarks/sttcompare/output]
                   [--project <gcp-project-id>] [--skip v2-chirp3,...]

Produces, in the output directory:
    A-google-v1-googdiar.txt           # baseline (your reported bug)
    B-google-v1-pyannote.txt           # Google v1 transcript + Pyannote speakers
    C-google-v2-chirp2-pyannote.txt    # Chirp 2 transcript + Pyannote
    D-google-v2-chirp3-pyannote.txt    # Chirp 3 transcript + Pyannote
    E-whisperkit-turbo-pyannote.txt    # WhisperKit large-v3-turbo + Pyannote
    F-whisperkit-large-v3-pyannote.txt # WhisperKit large-v3 (full) + Pyannote
    metadata.json                      # timings, segment counts, speaker counts
    pyannote.json                      # single shared diarization (used by all B/C/D/E/F)
    diarization/run.log                # diar-cli stderr
    <option>.raw.json                  # raw provider output per option
    COMPARISON.md                      # side-by-side report
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent.parent  # tests/benchmarks/sttcompare → repo
sys.path.insert(0, str(HERE))
from lib.align import (  # noqa: E402
    DiarSegment,
    TranscriptSegment,
    assign_speakers,
    format_labeled,
    unique_speakers,
)


# ── option definitions ──────────────────────────────────────────────────────


@dataclass
class Option:
    id: str
    title: str
    description: str
    # Transcription source: "google_v1", "google_v2", "whisperkit"
    transcribe_via: str
    transcribe_args: dict = field(default_factory=dict)
    # Diarization source: "google" (inline with transcription) | "pyannote" | "none"
    diarize_via: str = "pyannote"


ALL_OPTIONS: list[Option] = [
    Option(
        id="A-google-v1-googdiar",
        title="Google v1 default + Google diarization",
        description=(
            "Current broken baseline: v1 `default` model is the only one that "
            "supports Hebrew, and its own diarization collapses multi-speaker "
            "audio."
        ),
        transcribe_via="google_v1",
        transcribe_args={"model": "default", "diarize": "google"},
        diarize_via="google",
    ),
    Option(
        id="B-google-v1-pyannote",
        title="Google v1 default + Pyannote diarization",
        description=(
            "Transcription by Google v1, speakers by Pyannote/SpeakerKit. "
            "Smallest change that fixes the reported bug."
        ),
        transcribe_via="google_v1",
        transcribe_args={"model": "default", "diarize": "none"},
        diarize_via="pyannote",
    ),
    Option(
        id="C-google-v2-chirp2-pyannote",
        title="Google v2 Chirp 2 + Pyannote diarization",
        description=(
            "Chirp 2 — newer multilingual model. Google's docs don't list "
            "Hebrew as officially supported for Chirp 2, but in practice the "
            "Recognize endpoint accepts `iw-IL` and returns Hebrew transcripts. "
            "Occasionally loops on repeated phrases (decoder artifact)."
        ),
        transcribe_via="google_v2",
        transcribe_args={
            "model": "chirp_2",
            "diarize": "none",
            "region": "us-central1",
        },
        diarize_via="pyannote",
    ),
    Option(
        id="D-google-v2-chirp3-pyannote",
        title="Google v2 Chirp 3 + Pyannote diarization",
        description=(
            "Chirp 3 supports Hebrew transcription (Preview). Diarization is "
            "NOT supported for Hebrew so we run Pyannote externally."
        ),
        transcribe_via="google_v2",
        transcribe_args={"model": "chirp_3", "diarize": "none", "region": "us"},
        diarize_via="pyannote",
    ),
    Option(
        id="E-whisperkit-turbo-pyannote",
        title="WhisperKit large-v3-turbo + Pyannote diarization",
        description=(
            "Fully on-device. Fast, excellent Hebrew. Currently the strongest "
            "non-Google option baked into the app."
        ),
        transcribe_via="whisperkit",
        transcribe_args={"model": "openai_whisper-large-v3_turbo"},
        diarize_via="pyannote",
    ),
    Option(
        id="F-whisperkit-large-v3-pyannote",
        title="WhisperKit large-v3 (full) + Pyannote diarization",
        description=(
            "Fully on-device. The non-turbo large-v3 is slower but can be more "
            "accurate for hard Hebrew passages."
        ),
        transcribe_via="whisperkit",
        transcribe_args={"model": "openai_whisper-large-v3"},
        diarize_via="pyannote",
    ),
]


# ── helpers ─────────────────────────────────────────────────────────────────


def _run_stream(cmd: list[str], log_path: Path) -> int:
    """Run a command, stream stderr to log_path, return rc."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w") as log:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=log, check=False)
    return proc.returncode


def _run_capturing(cmd: list[str], log_path: Path) -> tuple[int, bytes]:
    """Run a command, stderr to log_path, return (rc, stdout_bytes)."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w") as log:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=log, check=False)
    return proc.returncode, proc.stdout


def _swift_build(package_dir: Path, out_dir: Path) -> dict[str, Path]:
    """Build transcribe-cli + diarize-cli, return map id → binary path."""
    print(f"  building Swift tools in {package_dir}…", file=sys.stderr)
    rc = subprocess.run(
        ["swift", "build", "-c", "release"],
        cwd=str(package_dir),
        check=False,
    ).returncode
    if rc != 0:
        raise RuntimeError(f"swift build failed (rc={rc})")
    rel = package_dir / ".build" / "release"
    return {
        "transcribe-cli": rel / "transcribe-cli",
        "diarize-cli": rel / "diarize-cli",
    }


def _run_pyannote(
    audio: Path,
    diarize_cli: Path,
    num_speakers: int,
    out_json: Path,
    log: Path,
) -> list[DiarSegment]:
    """Invoke diarize-cli once, save the JSON output, return parsed segments."""
    if out_json.exists():
        print(f"  using cached pyannote → {out_json.name}", file=sys.stderr)
    else:
        cmd = [str(diarize_cli), str(audio)]
        if num_speakers:
            cmd += ["--num-speakers", str(num_speakers)]
        rc, stdout = _run_capturing(cmd, log)
        if rc != 0:
            raise RuntimeError(
                f"diarize-cli failed (rc={rc}); see {log}"
            )
        out_json.write_bytes(stdout)

    data = json.loads(out_json.read_text())
    return [DiarSegment(start=d["start"], end=d["end"], speaker=d["speaker"]) for d in data]


def _run_whisperkit(
    audio: Path,
    transcribe_cli: Path,
    model: str,
    language: str,
    out_json: Path,
    log: Path,
) -> tuple[list[TranscriptSegment], float]:
    if out_json.exists():
        print(f"  using cached whisperkit → {out_json.name}", file=sys.stderr)
    else:
        t0 = time.time()
        cmd = [
            str(transcribe_cli),
            str(audio),
            "--language",
            language,
            "--model",
            model,
            "--format",
            "json",
        ]
        rc, stdout = _run_capturing(cmd, log)
        if rc != 0:
            raise RuntimeError(
                f"transcribe-cli ({model}) failed (rc={rc}); see {log}"
            )
        payload = json.loads(stdout)
        payload["wall_seconds"] = round(time.time() - t0, 2)
        out_json.write_text(json.dumps(payload, ensure_ascii=False, indent=2))

    data = json.loads(out_json.read_text())
    segs = [
        TranscriptSegment(start=s["start"], end=s["end"], text=s["text"])
        for s in data["segments"]
    ]
    return segs, data.get("wall_seconds", 0.0)


def _utterances_from_words(
    words: list[dict], max_gap: float = 0.8, max_utterance: float = 10.0
) -> list[TranscriptSegment]:
    """Group word-level timestamps into utterance-level TranscriptSegments.

    Breaks a new utterance whenever either the silence gap between words
    exceeds `max_gap` OR the utterance has already spanned `max_utterance`
    seconds. Gives the aligner a meaningful granularity: each utterance
    maps to exactly one speaker. Chunks of ~1-5 s work well with Pyannote
    segments and avoid an O(W·D) alignment when W = 5000+ words.
    """
    utterances: list[TranscriptSegment] = []
    if not words:
        return utterances
    cur_start = float(words[0].get("start", 0.0))
    cur_end = float(words[0].get("end", cur_start))
    cur_tokens: list[str] = [words[0].get("word") or ""]
    for w in words[1:]:
        ws = float(w.get("start", 0.0))
        we = float(w.get("end", ws))
        token = w.get("word") or ""
        gap = ws - cur_end
        total = we - cur_start
        if gap > max_gap or total > max_utterance:
            text = " ".join(t for t in cur_tokens if t).strip()
            if text:
                utterances.append(
                    TranscriptSegment(start=cur_start, end=cur_end, text=text)
                )
            cur_start = ws
            cur_tokens = [token]
        else:
            if token:
                cur_tokens.append(token)
        cur_end = we
    text = " ".join(t for t in cur_tokens if t).strip()
    if text:
        utterances.append(TranscriptSegment(start=cur_start, end=cur_end, text=text))
    return utterances


def _run_google(
    which: str,
    audio: Path,
    option: Option,
    language: str,
    num_speakers: int,
    project: str | None,
    out_json: Path,
    log: Path,
) -> tuple[list[TranscriptSegment], list[DiarSegment], float]:
    if out_json.exists():
        print(f"  using cached {which} → {out_json.name}", file=sys.stderr)
    else:
        script = HERE / "providers" / f"{which}.py"
        cmd = [
            sys.executable,
            str(script),
            str(audio),
            "--language",
            language,
            "--model",
            option.transcribe_args["model"],
            "--diarize",
            option.transcribe_args["diarize"],
            "--num-speakers",
            str(num_speakers),
        ]
        if which == "google_v2":
            cmd += ["--region", option.transcribe_args.get("region", "us")]
            if project:
                cmd += ["--project", project]
        rc, stdout = _run_capturing(cmd, log)
        if rc != 0:
            raise RuntimeError(
                f"{which} ({option.id}) failed (rc={rc}); see {log}"
            )
        out_json.write_bytes(stdout)

    data = json.loads(out_json.read_text())

    # Prefer word-level → utterance synthesis when a word stream is available.
    # v1 responses give words only when diarization is requested; otherwise
    # the provider returns a single big transcript per result. v2 (Chirp)
    # always has word-level timestamps when `enableWordTimeOffsets` is set.
    words = data.get("words") or []
    if words and option.diarize_via == "pyannote":
        # Only synthesize when we're going to align against Pyannote anyway.
        # If the provider supplied its own diarization (Google diar), respect
        # that path and use whatever `segments` it produced.
        t_segs = _utterances_from_words(words)
    else:
        t_segs = [
            TranscriptSegment(start=s["start"], end=s["end"], text=s["text"])
            for s in data["segments"]
        ]
    d_segs = [
        DiarSegment(start=d["start"], end=d["end"], speaker=d["speaker"])
        for d in data.get("diar_segments", [])
    ]
    return t_segs, d_segs, data.get("wall_seconds", 0.0)


# ── main ────────────────────────────────────────────────────────────────────


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("audio", help="Path to audio file (any ffmpeg-readable format)")
    ap.add_argument("--language", default="he")
    ap.add_argument(
        "--num-speakers",
        type=int,
        default=0,
        help="Expected speaker count (0 = auto). Helps Pyannote + Google diar.",
    )
    ap.add_argument(
        "--output-dir",
        default=str(HERE / "output"),
    )
    ap.add_argument(
        "--project",
        default=None,
        help="GCP project ID for v2 (else $GOOGLE_CLOUD_PROJECT or gcloud config)",
    )
    ap.add_argument(
        "--skip",
        default="",
        help="Comma-separated option IDs or prefixes to skip (e.g. 'C,F')",
    )
    ap.add_argument(
        "--only",
        default="",
        help="Comma-separated option IDs or prefixes; run ONLY these.",
    )
    ap.add_argument(
        "--force",
        action="store_true",
        help="Re-run every option, ignoring cached raw JSON.",
    )
    args = ap.parse_args()

    audio = Path(args.audio).expanduser().resolve()
    if not audio.exists():
        print(f"audio file not found: {audio}", file=sys.stderr)
        return 2

    output_dir = Path(args.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    logs = output_dir / "logs"
    logs.mkdir(exist_ok=True)

    # Filter options
    skip_set = {s.strip() for s in args.skip.split(",") if s.strip()}
    only_set = {s.strip() for s in args.only.split(",") if s.strip()}
    options = []
    for opt in ALL_OPTIONS:
        short = opt.id.split("-", 1)[0]  # "A", "B", ...
        if only_set and opt.id not in only_set and short not in only_set:
            continue
        if opt.id in skip_set or short in skip_set:
            continue
        options.append(opt)

    # Force mode: wipe prior outputs so cached .raw.json is not reused.
    if args.force:
        print("--force: clearing cached JSON outputs", file=sys.stderr)
        for opt in options:
            raw = output_dir / f"{opt.id}.raw.json"
            if raw.exists():
                raw.unlink()

    needs_whisperkit = any(o.transcribe_via == "whisperkit" for o in options)
    needs_pyannote = any(o.diarize_via == "pyannote" for o in options)

    swift_bin: dict[str, Path] = {}
    if needs_whisperkit or needs_pyannote:
        swift_bin = _swift_build(
            REPO_ROOT / "tests" / "e2e" / "TranscribeCLI",
            output_dir,
        )

    # Shared Pyannote run — reuse across every option that needs Pyannote.
    diar_segments: list[DiarSegment] = []
    if needs_pyannote:
        print("  running Pyannote (shared across options)…", file=sys.stderr)
        diar_json = output_dir / "pyannote.json"
        if args.force and diar_json.exists():
            diar_json.unlink()
        diar_segments = _run_pyannote(
            audio=audio,
            diarize_cli=swift_bin["diarize-cli"],
            num_speakers=args.num_speakers,
            out_json=diar_json,
            log=logs / "pyannote.log",
        )
        print(
            f"    pyannote found {len(diar_segments)} segments across "
            f"{len({d.speaker for d in diar_segments})} unique speakers",
            file=sys.stderr,
        )

    # Per-option run
    metadata: dict[str, dict] = {}
    for opt in options:
        print(f"\n[{opt.id}] {opt.title}", file=sys.stderr)
        raw_json = output_dir / f"{opt.id}.raw.json"
        log = logs / f"{opt.id}.log"
        labeled_txt = output_dir / f"{opt.id}.txt"
        entry: dict = {
            "id": opt.id,
            "title": opt.title,
            "description": opt.description,
            "transcribe_via": opt.transcribe_via,
            "transcribe_args": opt.transcribe_args,
            "diarize_via": opt.diarize_via,
            "status": "skipped",
            "error": None,
        }

        try:
            if opt.transcribe_via == "whisperkit":
                segs, wall = _run_whisperkit(
                    audio=audio,
                    transcribe_cli=swift_bin["transcribe-cli"],
                    model=opt.transcribe_args["model"],
                    language=args.language,
                    out_json=raw_json,
                    log=log,
                )
                diar = diar_segments  # Pyannote shared
            elif opt.transcribe_via == "google_v1":
                segs, google_diar, wall = _run_google(
                    "google_v1",
                    audio=audio,
                    option=opt,
                    language=args.language,
                    num_speakers=args.num_speakers,
                    project=None,
                    out_json=raw_json,
                    log=log,
                )
                diar = google_diar if opt.diarize_via == "google" else diar_segments
            elif opt.transcribe_via == "google_v2":
                segs, google_diar, wall = _run_google(
                    "google_v2",
                    audio=audio,
                    option=opt,
                    language=args.language,
                    num_speakers=args.num_speakers,
                    project=args.project,
                    out_json=raw_json,
                    log=log,
                )
                diar = google_diar if opt.diarize_via == "google" else diar_segments
            else:
                raise RuntimeError(f"unknown transcribe_via: {opt.transcribe_via}")

            labeled = assign_speakers(segs, diar)
            formatted = format_labeled(labeled)
            labeled_txt.write_text(formatted, encoding="utf-8")

            entry.update(
                {
                    "status": "ok",
                    "wall_seconds": wall,
                    "transcription_segments": len(segs),
                    "diar_segments": len(diar),
                    "unique_speakers": unique_speakers(labeled),
                    "speaker_count": len(unique_speakers(labeled)),
                    "transcript_file": labeled_txt.name,
                    "raw_file": raw_json.name if raw_json.exists() else None,
                }
            )
            print(
                f"  ✓ {len(segs)} t-segments, "
                f"{len(entry['unique_speakers'])} speakers, "
                f"wall={wall}s → {labeled_txt.name}",
                file=sys.stderr,
            )
        except Exception as exc:
            entry.update({"status": "failed", "error": str(exc)})
            print(f"  ✗ {exc}", file=sys.stderr)

        metadata[opt.id] = entry

    # metadata.json — merge into any existing file so partial runs (--only,
    # --skip, timeouts) don't wipe previously captured results for other
    # options.
    meta_path = output_dir / "metadata.json"
    existing: dict = {}
    if meta_path.exists():
        try:
            existing = json.loads(meta_path.read_text())
        except Exception:
            existing = {}
    merged_options = dict(existing.get("options") or {})
    merged_options.update(metadata)
    meta_out = {
        "audio": str(audio),
        "language": args.language,
        "num_speakers_hint": args.num_speakers,
        "options": merged_options,
    }
    meta_path.write_text(json.dumps(meta_out, ensure_ascii=False, indent=2))

    # COMPARISON.md — use the merged metadata so the report reflects every
    # option we've ever produced output for, not just the ones from this run.
    report_path = output_dir / "COMPARISON.md"
    _write_report(report_path, audio, args, merged_options, output_dir)
    print(f"\nReport: {report_path}", file=sys.stderr)
    return 0


def _write_report(
    path: Path,
    audio: Path,
    args: argparse.Namespace,
    metadata: dict[str, dict],
    output_dir: Path,
) -> None:
    lines: list[str] = []
    lines.append(f"# STT Backend Comparison — {audio.name}\n")
    lines.append(f"Audio: `{audio}`  ")
    lines.append(f"Language: `{args.language}`  ")
    if args.num_speakers:
        lines.append(f"Hinted speaker count: `{args.num_speakers}`  ")
    lines.append("")

    # Summary table
    lines.append("## Summary\n")
    lines.append(
        "| ID | Option | Status | Speakers | Segments | Wall (s) |"
    )
    lines.append("|----|--------|--------|----------|----------|----------|")
    for opt in ALL_OPTIONS:
        m = metadata.get(opt.id)
        if not m:
            continue
        status = m["status"]
        speakers = m.get("speaker_count", "—")
        segments = m.get("transcription_segments", "—")
        wall = m.get("wall_seconds", "—")
        if status == "failed":
            err = (m.get("error") or "")[:80].replace("|", "\\|")
            status = f"failed: {err}"
        lines.append(
            f"| {opt.id.split('-', 1)[0]} | {opt.title} | {status} | "
            f"{speakers} | {segments} | {wall} |"
        )
    lines.append("")

    # First 2 minutes side-by-side
    lines.append("## First 2 minutes, side-by-side\n")
    lines.append(
        "_Each column shows lines whose end timestamp is within the first "
        "120 seconds._\n"
    )
    for opt in ALL_OPTIONS:
        m = metadata.get(opt.id)
        if not m or m["status"] != "ok":
            continue
        transcript_path = output_dir / m["transcript_file"]
        excerpt = _first_seconds(transcript_path, seconds=120)
        lines.append(f"### {opt.id}\n")
        lines.append(opt.description)
        lines.append("")
        lines.append("```text")
        lines.append(excerpt.strip() or "(empty)")
        lines.append("```")
        lines.append("")

    # Notes
    lines.append("## Observations\n")
    lines.append(
        "_These are programmatic observations based on segment counts and "
        "speaker diversity, not quality judgments. Read the full transcripts "
        "to evaluate accuracy._\n"
    )
    for opt in ALL_OPTIONS:
        m = metadata.get(opt.id)
        if not m or m["status"] != "ok":
            continue
        speakers = m.get("speaker_count", 0)
        segments = m.get("transcription_segments", 0)
        note = ""
        if speakers <= 1 and segments >= 5:
            note = "⚠ collapsed to a single speaker across many segments — bad diarization"
        elif speakers >= 8:
            note = "⚠ detected 8+ speakers — likely over-segmented (quality-dependent)"
        elif speakers >= 2:
            note = "✓ multi-speaker diarization working"
        lines.append(f"- **{opt.id}**: {speakers} speakers, {segments} segments — {note}")
    lines.append("")

    # Files
    lines.append("## Files\n")
    for opt in ALL_OPTIONS:
        m = metadata.get(opt.id)
        if not m:
            continue
        if m["status"] == "ok":
            lines.append(f"- `{m['transcript_file']}` — formatted transcript")
            if m.get("raw_file"):
                lines.append(f"- `{m['raw_file']}` — raw provider JSON")
    lines.append("- `metadata.json` — full run metadata")
    lines.append("- `pyannote.json` — shared Pyannote diarization output")
    lines.append("- `logs/` — stderr from each tool invocation")

    path.write_text("\n".join(lines), encoding="utf-8")


def _first_seconds(
    transcript_path: Path,
    seconds: int,
    max_lines: int = 8,
    max_chars_per_line: int = 600,
) -> str:
    """Return the opening of a transcript for side-by-side display.

    Always includes the first line (even if it spans more than `seconds`,
    as with the collapsed Google-diar case). Otherwise stops once either
    the start timestamp passes `seconds`, or `max_lines` is reached.
    Each long line is truncated to `max_chars_per_line` with an ellipsis.
    """
    if not transcript_path.exists():
        return ""
    out: list[str] = []
    for line_idx, line in enumerate(transcript_path.read_text(encoding="utf-8").splitlines()):
        if not line.startswith("["):
            out.append(line)
            continue
        start_sec: int | None = None
        try:
            head = line.split("->")[0].strip().lstrip("[")
            mm, ss = head.split(":")
            start_sec = int(mm) * 60 + int(ss)
        except Exception:
            start_sec = None
        if line_idx > 0 and start_sec is not None and start_sec > seconds:
            break
        if len(line) > max_chars_per_line:
            line = line[:max_chars_per_line].rstrip() + " …[truncated]"
        out.append(line)
        if len(out) >= max_lines:
            break
    return "\n".join(out)


if __name__ == "__main__":
    sys.exit(main())
