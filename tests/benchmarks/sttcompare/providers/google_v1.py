#!/usr/bin/env python3
"""Google Cloud Speech-to-Text v1 client for the comparison harness.

Mirrors gui/Sources/TranscribeerApp/Services/GoogleSTTBackend.swift:
  - REST endpoint https://speech.googleapis.com/v1/speech:recognize
  - X-Goog-Api-Key auth header (Keychain or $GOOGLE_STT_API_KEY env)
  - Input normalized to 16 kHz mono 16-bit LINEAR16 PCM WAV
  - Split into ~55 s chunks, POSTed concurrently, results merged in order
  - `--diarize google` : use Google's own speaker tags
  - `--diarize none`   : request words + timestamps only; diarization handled
                         externally (e.g. via diarize-cli + align)

Outputs a JSON blob to stdout:
  {
    "provider": "google_v1",
    "model":    "default",
    "language": "he",
    "diarize":  "none" | "google",
    "words":    [ {start, end, word, speaker_tag?} ],   // only if diarize == "google"
    "segments": [ {start, end, text} ],                 // transcription units
    "diar_segments": [ {start, end, speaker} ],         // only if diarize == "google"
    "wall_seconds": float
  }
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))
from lib.audio import (  # noqa: E402
    TARGET_SAMPLE_RATE,
    split_linear16,
    transcode_to_linear16,
)

V1_ENDPOINT = "https://speech.googleapis.com/v1/speech:recognize"
CHUNK_SECONDS = 55.0
MAX_CONCURRENT = 4
REQUEST_TIMEOUT = 120


def _language_codes(lang: str) -> list[str]:
    """Mirror GoogleSTTBackend.mapLanguage(_:).

    "auto" primes English + Hebrew (the two locales the app UI exposes).
    """
    short = lang.lower()
    mapping = {
        "auto": ["en-US", "he-IL"],
        "en": ["en-US"],
        "he": ["he-IL"],
        "ar": ["ar-EG"],
        "es": ["es-ES"],
        "fr": ["fr-FR"],
        "de": ["de-DE"],
        "ja": ["ja-JP"],
        "zh": ["zh-CN"],
    }
    return mapping.get(short, [lang])


def _resolve_api_key() -> str:
    """Keychain first (matches KeychainHelper), fall back to env var."""
    # Try the macOS Keychain where the app stores it.
    try:
        result = subprocess.run(
            [
                "/usr/bin/security",
                "find-generic-password",
                "-s",
                "transcribeer/google_stt",
                "-a",
                "apikey",
                "-w",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode == 0:
            key = result.stdout.strip()
            if key:
                return key
    except FileNotFoundError:
        pass

    env = os.environ.get("GOOGLE_STT_API_KEY", "").strip()
    if env:
        return env

    print(
        "google_v1: no API key found. Set it in Keychain (transcribeer/google_stt, "
        "account=apikey) or export GOOGLE_STT_API_KEY.",
        file=sys.stderr,
    )
    sys.exit(3)


def _parse_duration(raw: str | None) -> float:
    if not raw:
        return 0.0
    trimmed = raw[:-1] if raw.endswith("s") else raw
    try:
        return float(trimmed)
    except ValueError:
        return 0.0


def _recognize_chunk(
    chunk_path: Path,
    start_offset: float,
    api_key: str,
    language_codes: list[str],
    model: str,
    diarize: bool,
    speaker_count: int | None,
) -> dict:
    """POST a single chunk, return parsed result shifted by start_offset."""
    b64 = base64.b64encode(chunk_path.read_bytes()).decode("ascii")

    config: dict = {
        "encoding": "LINEAR16",
        "sampleRateHertz": TARGET_SAMPLE_RATE,
        "languageCode": language_codes[0],
        "model": model,
        "enableAutomaticPunctuation": True,
        "enableWordTimeOffsets": True,
    }
    if len(language_codes) > 1:
        config["alternativeLanguageCodes"] = language_codes[1:]
    if diarize:
        config["diarizationConfig"] = {
            "enableSpeakerDiarization": True,
            "minSpeakerCount": 1,
            "maxSpeakerCount": speaker_count if speaker_count else 6,
        }

    body = {"config": config, "audio": {"content": b64}}

    req = urllib.request.Request(
        V1_ENDPOINT,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "X-Goog-Api-Key": api_key,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise RuntimeError(
            f"v1 HTTP {exc.code}: {detail[:400]}"
        ) from None

    return _parse_response(data, diarize=diarize, start_offset=start_offset)


def _parse_response(resp: dict, diarize: bool, start_offset: float) -> dict:
    """Mirror GoogleSTTBackend.parseResponse + parseDiarizedWords.

    Returns {'segments': [...], 'diar_segments': [...], 'words': [...]}.
    Timestamps already shifted by start_offset.
    """
    results = resp.get("results") or []

    # Diarized: v1 puts the full word list with speakerTag on the LAST result.
    if diarize and results:
        last = results[-1]
        alts = last.get("alternatives") or []
        if alts and alts[0].get("words"):
            words_raw = alts[0]["words"]
            words: list[dict] = []
            segments: list[dict] = []
            diar_segments: list[dict] = []

            cur_speaker: int | None = None
            cur_start = 0.0
            cur_end = 0.0
            cur_tokens: list[str] = []

            def flush() -> None:
                nonlocal cur_speaker, cur_tokens
                if cur_speaker is None or not cur_tokens:
                    return
                text = " ".join(cur_tokens)
                segments.append({"start": cur_start, "end": cur_end, "text": text})
                diar_segments.append(
                    {
                        "start": cur_start,
                        "end": cur_end,
                        "speaker": f"SPEAKER_{cur_speaker}",
                    }
                )
                cur_tokens = []

            for w in words_raw:
                start = _parse_duration(w.get("startTime")) + start_offset
                end = _parse_duration(w.get("endTime")) + start_offset
                speaker = w.get("speakerTag") or 0
                token = w.get("word") or ""
                words.append(
                    {
                        "start": start,
                        "end": end,
                        "word": token,
                        "speaker_tag": speaker,
                    }
                )
                if speaker != cur_speaker:
                    flush()
                    cur_speaker = speaker
                    cur_start = start
                cur_end = end
                if token:
                    cur_tokens.append(token)
            flush()
            return {
                "segments": segments,
                "diar_segments": diar_segments,
                "words": words,
            }

    # Non-diarized: one segment per result, with word-level timestamps from
    # alternatives[0].words when available.
    segments = []
    words: list[dict] = []
    previous_end = 0.0
    for result in results:
        alts = result.get("alternatives") or []
        if not alts:
            continue
        alt = alts[0]
        transcript = (alt.get("transcript") or "").strip()
        end = _parse_duration(result.get("resultEndTime")) or previous_end
        if transcript:
            segments.append(
                {
                    "start": previous_end + start_offset,
                    "end": end + start_offset,
                    "text": transcript,
                }
            )
        for w in alt.get("words") or []:
            words.append(
                {
                    "start": _parse_duration(w.get("startTime")) + start_offset,
                    "end": _parse_duration(w.get("endTime")) + start_offset,
                    "word": w.get("word") or "",
                }
            )
        previous_end = end

    return {"segments": segments, "diar_segments": [], "words": words}


def run(args: argparse.Namespace) -> None:
    src = Path(args.audio).expanduser().resolve()
    work_dir = Path(args.work_dir).expanduser().resolve()
    work_dir.mkdir(parents=True, exist_ok=True)

    normalized = work_dir / "input-16k.wav"
    transcode_to_linear16(src, normalized)
    chunks = split_linear16(normalized, work_dir / "chunks", CHUNK_SECONDS)

    api_key = _resolve_api_key()
    language_codes = _language_codes(args.language)
    diarize = args.diarize == "google"
    speaker_count = args.num_speakers if args.num_speakers else None

    print(
        f"google_v1: {len(chunks)} chunks, model={args.model}, "
        f"langs={','.join(language_codes)}, diarize={args.diarize}",
        file=sys.stderr,
    )

    t0 = time.time()
    results: list[dict | None] = [None] * len(chunks)

    def work(index: int) -> None:
        chunk_path, offset = chunks[index]
        results[index] = _recognize_chunk(
            chunk_path=chunk_path,
            start_offset=offset,
            api_key=api_key,
            language_codes=language_codes,
            model=args.model,
            diarize=diarize,
            speaker_count=speaker_count,
        )

    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_CONCURRENT) as pool:
        futures = [pool.submit(work, i) for i in range(len(chunks))]
        for i, f in enumerate(concurrent.futures.as_completed(futures)):
            f.result()  # raise on error
            print(f"  chunk {i + 1}/{len(chunks)} done", file=sys.stderr)

    wall = time.time() - t0

    merged_segments: list[dict] = []
    merged_diar: list[dict] = []
    merged_words: list[dict] = []
    for r in results:
        if not r:
            continue
        merged_segments.extend(r["segments"])
        merged_diar.extend(r["diar_segments"])
        merged_words.extend(r["words"])

    out = {
        "provider": "google_v1",
        "model": args.model,
        "language": args.language,
        "diarize": args.diarize,
        "segments": merged_segments,
        "diar_segments": merged_diar,
        "words": merged_words,
        "wall_seconds": round(wall, 2),
    }
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
    print()


def main() -> int:
    ap = argparse.ArgumentParser(description="Google STT v1 benchmark client")
    ap.add_argument("audio", help="Path to audio file")
    ap.add_argument("--language", default="he", help="Language code (default: he)")
    ap.add_argument("--model", default="default", help="v1 model id (default: default)")
    ap.add_argument(
        "--diarize",
        choices=["none", "google"],
        default="none",
        help="Request Google's own diarization, or just words + timestamps.",
    )
    ap.add_argument(
        "--num-speakers",
        type=int,
        default=0,
        help="Expected speaker count (0 = auto/default cap of 6)",
    )
    ap.add_argument(
        "--work-dir",
        default="/tmp/sttcompare-google-v1",
        help="Scratch directory for normalized + chunked audio",
    )
    args = ap.parse_args()
    run(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
