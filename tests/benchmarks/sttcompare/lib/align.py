"""Merge transcription segments with speaker diarization into labeled output.

Replicates gui/Sources/TranscribeerCore/TranscriptFormatter.swift exactly so the
comparison report looks identical to what the production app produces.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class TranscriptSegment:
    start: float
    end: float
    text: str


@dataclass
class DiarSegment:
    start: float
    end: float
    speaker: str


@dataclass
class LabeledSegment:
    start: float
    end: float
    speaker: str
    text: str


def assign_speakers(
    transcription: list[TranscriptSegment],
    diarization: list[DiarSegment],
) -> list[LabeledSegment]:
    """For each transcription segment, pick the diar speaker with max temporal
    overlap; fall back to midpoint containment; else 'UNKNOWN'.

    Mirrors TranscriptFormatter.assignSpeakers.
    """
    labeled: list[LabeledSegment] = []
    for ws in transcription:
        ws_mid = (ws.start + ws.end) / 2.0
        best_speaker = "UNKNOWN"
        best_overlap = 0.0

        for ds in diarization:
            overlap = max(0.0, min(ws.end, ds.end) - max(ws.start, ds.start))
            if overlap > best_overlap:
                best_overlap = overlap
                best_speaker = ds.speaker
            if best_overlap == 0 and ds.start <= ws_mid <= ds.end:
                best_speaker = ds.speaker

        labeled.append(
            LabeledSegment(start=ws.start, end=ws.end, speaker=best_speaker, text=ws.text)
        )
    return labeled


def _mmss(seconds: float) -> str:
    t = int(seconds)
    return f"{t // 60:02d}:{t % 60:02d}"


def format_labeled(segments: list[LabeledSegment]) -> str:
    """Rename speakers sequentially, merge consecutive same-speaker lines,
    emit [MM:SS -> MM:SS] Speaker N: text lines.

    Mirrors TranscriptFormatter.format.
    """
    if not segments:
        return ""

    speaker_map: dict[str, str] = {}
    counter = 1
    for seg in segments:
        if seg.speaker == "UNKNOWN":
            continue
        if seg.speaker not in speaker_map:
            speaker_map[seg.speaker] = f"Speaker {counter}"
            counter += 1
    speaker_map["UNKNOWN"] = "???"

    merged: list[LabeledSegment] = []
    for seg in segments:
        friendly = speaker_map.get(seg.speaker, seg.speaker)
        if merged and merged[-1].speaker == friendly:
            prev = merged.pop()
            merged.append(
                LabeledSegment(
                    start=prev.start,
                    end=seg.end,
                    speaker=friendly,
                    text=(prev.text + " " + seg.text).strip(),
                )
            )
        else:
            merged.append(
                LabeledSegment(
                    start=seg.start,
                    end=seg.end,
                    speaker=friendly,
                    text=seg.text,
                )
            )

    return "\n".join(
        f"[{_mmss(s.start)} -> {_mmss(s.end)}] {s.speaker}: {s.text}" for s in merged
    )


def unique_speakers(segments: list[LabeledSegment]) -> list[str]:
    """Return unique speaker labels in first-appearance order (after renaming)."""
    seen: list[str] = []
    for s in segments:
        if s.speaker not in seen:
            seen.append(s.speaker)
    return seen
