#!/usr/bin/env python3
"""Google Cloud Speech-to-Text v2 client for the comparison harness.

Uses the synchronous Recognize endpoint with inline audio:
  POST https://{region}-speech.googleapis.com/v2/projects/{project}/locations/{region}/recognizers/_:recognize

Authentication: Application Default Credentials via `gcloud auth
application-default print-access-token`. No service-account key file required;
the user just needs `gcloud auth application-default login` to have been run.

Models supported:
  - chirp_2 : stronger than v1 'default' for supported langs. NO Hebrew.
              NO diarization.
  - chirp_3 : latest multilingual. Hebrew (iw-IL) transcription in Preview.
              Diarization NOT supported for Hebrew (only 13 specific langs).
  - latest_long / latest_short : v2 built-in models.

Important constraints we work around:
  * Sync Recognize accepts inline audio ≤1 min. We chunk to 55 s like v1.
  * Chirp 3 with word timestamps caps at 20 min total when using BatchRecognize
    — irrelevant for sync since we slice to 55 s anyway.
  * v2 does not accept the v1 `alternativeLanguageCodes` as a separate field;
    it takes a `language_codes` array and picks the best match.

Output JSON matches google_v1.py's schema.
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

CHUNK_SECONDS = 55.0
MAX_CONCURRENT = 4
REQUEST_TIMEOUT = 180


def _language_codes(lang: str, model: str) -> list[str]:
    """Map 'he' etc. to BCP-47 + handle Chirp model limitations.

    Chirp 2 doesn't support Hebrew. If the user asks for he with chirp_2
    we fall back to he-IL anyway — the API will error, and the harness logs
    that error rather than silently substituting a different language.
    """
    short = lang.lower()
    mapping = {
        "auto": ["auto"],  # v2 accepts a sentinel "auto" value
        "en": ["en-US"],
        "he": ["iw-IL"],  # yes, v2 still expects "iw" (Chirp 3 Preview)
        "ar": ["ar-EG"],
        "es": ["es-ES"],
        "fr": ["fr-FR"],
        "de": ["de-DE"],
        "ja": ["ja-JP"],
        "zh": ["cmn-Hans-CN"],
    }
    _ = model  # reserved for future model-specific overrides
    return mapping.get(short, [lang])


def _resolve_token() -> str:
    """Print an access token via gcloud, mirroring ADC."""
    result = subprocess.run(
        ["gcloud", "auth", "application-default", "print-access-token"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        print(
            "google_v2: failed to obtain access token via gcloud.\n"
            "Run: gcloud auth application-default login",
            file=sys.stderr,
        )
        print(result.stderr, file=sys.stderr)
        sys.exit(3)
    token = result.stdout.strip()
    if not token:
        print("google_v2: gcloud returned empty token", file=sys.stderr)
        sys.exit(3)
    return token


def _resolve_project(cli_project: str | None) -> str:
    if cli_project:
        return cli_project
    env = os.environ.get("GOOGLE_CLOUD_PROJECT", "").strip()
    if env:
        return env
    # gcloud config
    result = subprocess.run(
        ["gcloud", "config", "get-value", "project"],
        capture_output=True,
        text=True,
        check=False,
    )
    proj = result.stdout.strip()
    if proj and proj != "(unset)":
        return proj
    print(
        "google_v2: project ID required. Pass --project, set "
        "GOOGLE_CLOUD_PROJECT, or run 'gcloud config set project <id>'.",
        file=sys.stderr,
    )
    sys.exit(3)


def _parse_offset(raw: str | None) -> float:
    """v2 uses 'startOffset' / 'endOffset' in the form '3.500s'."""
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
    token: str,
    project: str,
    region: str,
    model: str,
    language_codes: list[str],
    diarize: bool,
    speaker_count: int | None,
) -> dict:
    endpoint = (
        f"https://{region}-speech.googleapis.com/v2/projects/{project}"
        f"/locations/{region}/recognizers/_:recognize"
    )
    b64 = base64.b64encode(chunk_path.read_bytes()).decode("ascii")

    features: dict = {"enableWordTimeOffsets": True}
    if diarize:
        features["diarizationConfig"] = {
            "minSpeakerCount": 1,
            "maxSpeakerCount": speaker_count if speaker_count else 6,
        }

    body: dict = {
        "config": {
            "explicitDecodingConfig": {
                "encoding": "LINEAR16",
                "sampleRateHertz": TARGET_SAMPLE_RATE,
                "audioChannelCount": 1,
            },
            "languageCodes": language_codes,
            "model": model,
            "features": features,
        },
        "content": b64,
    }

    req = urllib.request.Request(
        endpoint,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": f"Bearer {token}",
            "x-goog-user-project": project,
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=REQUEST_TIMEOUT) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode(errors="replace")
        raise RuntimeError(
            f"v2 HTTP {exc.code}: {detail[:400]}"
        ) from None

    return _parse_response(data, diarize=diarize, start_offset=start_offset)


def _parse_response(resp: dict, diarize: bool, start_offset: float) -> dict:
    """Parse v2 Recognize response.

    Shape (abbreviated):
    {
      "results": [
        {
          "alternatives": [
            {
              "transcript": "...",
              "words": [ {"startOffset": "0.5s", "endOffset": "0.9s",
                          "word": "foo", "speakerLabel": "2"} ]
            }
          ],
          "resultEndOffset": "3.5s",
          "languageCode": "iw-IL"
        },
        ...
      ]
    }

    v2 uses `speakerLabel` (string) rather than v1's `speakerTag` (int).
    """
    results = resp.get("results") or []
    segments: list[dict] = []
    diar_segments: list[dict] = []
    words: list[dict] = []

    # When diarization is on, v2 (like v1) places the cumulative words list on
    # the final result. Prefer that path if available.
    if diarize and results:
        last = results[-1]
        alts = last.get("alternatives") or []
        if alts and alts[0].get("words"):
            words_raw = alts[0]["words"]
            cur_speaker: str | None = None
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
                start = _parse_offset(w.get("startOffset")) + start_offset
                end = _parse_offset(w.get("endOffset")) + start_offset
                speaker = w.get("speakerLabel") or "0"
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

    # Non-diarized path: derive segment start/end from the words in each
    # alternative, because Chirp-family responses often omit `resultEndOffset`
    # (or set it to 0). Fall back to `resultEndOffset` only when words are
    # absent.
    previous_end = 0.0
    for result in results:
        alts = result.get("alternatives") or []
        if not alts:
            continue
        alt = alts[0]
        transcript = (alt.get("transcript") or "").strip()
        word_list = alt.get("words") or []

        seg_start: float
        seg_end: float
        if word_list:
            seg_start = _parse_offset(word_list[0].get("startOffset"))
            seg_end = _parse_offset(word_list[-1].get("endOffset")) or seg_start
        else:
            seg_start = previous_end
            seg_end = _parse_offset(result.get("resultEndOffset")) or previous_end

        if transcript:
            segments.append(
                {
                    "start": seg_start + start_offset,
                    "end": seg_end + start_offset,
                    "text": transcript,
                }
            )
        for w in word_list:
            words.append(
                {
                    "start": _parse_offset(w.get("startOffset")) + start_offset,
                    "end": _parse_offset(w.get("endOffset")) + start_offset,
                    "word": w.get("word") or "",
                }
            )
        previous_end = seg_end

    return {"segments": segments, "diar_segments": [], "words": words}


def run(args: argparse.Namespace) -> None:
    src = Path(args.audio).expanduser().resolve()
    work_dir = Path(args.work_dir).expanduser().resolve()
    work_dir.mkdir(parents=True, exist_ok=True)

    normalized = work_dir / "input-16k.wav"
    transcode_to_linear16(src, normalized)
    chunks = split_linear16(normalized, work_dir / "chunks", CHUNK_SECONDS)

    token = _resolve_token()
    project = _resolve_project(args.project)
    language_codes = _language_codes(args.language, args.model)
    diarize = args.diarize == "google"
    speaker_count = args.num_speakers if args.num_speakers else None

    print(
        f"google_v2: {len(chunks)} chunks, model={args.model}, region={args.region}, "
        f"project={project}, langs={','.join(language_codes)}, diarize={args.diarize}",
        file=sys.stderr,
    )

    t0 = time.time()
    results: list[dict | None] = [None] * len(chunks)
    errors: list[tuple[int, str]] = []

    def work(index: int) -> None:
        chunk_path, offset = chunks[index]
        try:
            results[index] = _recognize_chunk(
                chunk_path=chunk_path,
                start_offset=offset,
                token=token,
                project=project,
                region=args.region,
                model=args.model,
                language_codes=language_codes,
                diarize=diarize,
                speaker_count=speaker_count,
            )
        except Exception as exc:
            errors.append((index, str(exc)))

    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_CONCURRENT) as pool:
        futures = [pool.submit(work, i) for i in range(len(chunks))]
        for i, f in enumerate(concurrent.futures.as_completed(futures)):
            f.result()
            print(f"  chunk {i + 1}/{len(chunks)} done", file=sys.stderr)

    wall = time.time() - t0

    if errors:
        for idx, msg in errors[:3]:
            print(f"google_v2: chunk {idx} failed — {msg}", file=sys.stderr)

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
        "provider": "google_v2",
        "model": args.model,
        "language": args.language,
        "region": args.region,
        "project": project,
        "diarize": args.diarize,
        "segments": merged_segments,
        "diar_segments": merged_diar,
        "words": merged_words,
        "wall_seconds": round(wall, 2),
        "failed_chunks": len(errors),
    }
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
    print()


def main() -> int:
    ap = argparse.ArgumentParser(description="Google STT v2 (Chirp 2/3) benchmark client")
    ap.add_argument("audio", help="Path to audio file")
    ap.add_argument("--language", default="he")
    ap.add_argument(
        "--model",
        default="chirp_3",
        help="v2 model: chirp_3, chirp_2, latest_long, latest_short, etc.",
    )
    ap.add_argument(
        "--region",
        default="us",
        help="Regional endpoint: us, eu, us-central1, europe-west4, asia-southeast1",
    )
    ap.add_argument(
        "--project",
        default=None,
        help="GCP project ID (else $GOOGLE_CLOUD_PROJECT or gcloud config)",
    )
    ap.add_argument(
        "--diarize",
        choices=["none", "google"],
        default="none",
    )
    ap.add_argument("--num-speakers", type=int, default=0)
    ap.add_argument(
        "--work-dir",
        default="/tmp/sttcompare-google-v2",
    )
    args = ap.parse_args()
    run(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
