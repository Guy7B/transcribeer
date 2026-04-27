"""Audio preprocessing helpers for the STT comparison harness.

Mirrors the logic in gui/Sources/TranscribeerApp/Services/GoogleSTTBackend.swift
and gui/Sources/TranscribeerCore/AudioChunker.swift so every provider sees the
same normalized inputs the production pipeline uses:

  1. Decode the source file (m4a / mp3 / wav / anything ffmpeg reads).
  2. Resample to 16 kHz mono 16-bit LINEAR16 PCM WAV.
  3. Split into fixed-duration chunks with fresh RIFF/WAVE headers.
"""

from __future__ import annotations

import math
import subprocess
import sys
import wave
from pathlib import Path
from typing import Iterable


TARGET_SAMPLE_RATE = 16_000  # match GoogleSTTBackend.targetSampleRate
TARGET_CHANNELS = 1
TARGET_SAMPLE_WIDTH = 2  # bytes, int16


def which(cmd: str) -> str:
    """Return absolute path of `cmd`, exit(2) if missing."""
    path = subprocess.run(
        ["which", cmd], capture_output=True, text=True, check=False
    ).stdout.strip()
    if not path:
        print(f"missing required tool: {cmd}", file=sys.stderr)
        sys.exit(2)
    return path


def transcode_to_linear16(src: Path, dst: Path) -> None:
    """Re-encode any ffmpeg-readable audio file as 16 kHz mono 16-bit PCM WAV."""
    subprocess.run(
        [
            which("ffmpeg"),
            "-y",
            "-loglevel",
            "error",
            "-i",
            str(src),
            "-ac",
            str(TARGET_CHANNELS),
            "-ar",
            str(TARGET_SAMPLE_RATE),
            "-sample_fmt",
            "s16",
            "-f",
            "wav",
            str(dst),
        ],
        check=True,
    )


def duration_seconds(wav_path: Path) -> float:
    with wave.open(str(wav_path), "rb") as w:
        return w.getnframes() / float(w.getframerate())


def split_linear16(
    src: Path, out_dir: Path, chunk_seconds: float = 55.0
) -> list[tuple[Path, float]]:
    """Split a 16 kHz mono int16 WAV into chunk files.

    Returns [(chunk_path, start_offset_seconds), ...] in order.
    Mirrors AudioChunker.split in TranscribeerCore.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    chunks: list[tuple[Path, float]] = []

    with wave.open(str(src), "rb") as rd:
        assert rd.getframerate() == TARGET_SAMPLE_RATE
        assert rd.getnchannels() == TARGET_CHANNELS
        assert rd.getsampwidth() == TARGET_SAMPLE_WIDTH
        total_frames = rd.getnframes()
        frames_per_chunk = int(chunk_seconds * TARGET_SAMPLE_RATE)
        num_chunks = max(1, math.ceil(total_frames / frames_per_chunk))

        for i in range(num_chunks):
            start_frame = i * frames_per_chunk
            rd.setpos(start_frame)
            remaining = total_frames - start_frame
            take = min(frames_per_chunk, remaining)
            data = rd.readframes(take)

            out_path = out_dir / f"chunk-{i:03d}.wav"
            with wave.open(str(out_path), "wb") as wr:
                wr.setnchannels(TARGET_CHANNELS)
                wr.setsampwidth(TARGET_SAMPLE_WIDTH)
                wr.setframerate(TARGET_SAMPLE_RATE)
                wr.writeframes(data)

            chunks.append((out_path, start_frame / TARGET_SAMPLE_RATE))

    return chunks


def read_wav_bytes(path: Path) -> bytes:
    return path.read_bytes()
