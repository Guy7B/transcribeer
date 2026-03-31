from pathlib import Path
from unittest.mock import patch, MagicMock
import shutil
import tempfile
import pytest


def test_assign_speakers_overlap():
    """Whisper segment overlapping a diarization segment gets that speaker."""
    from transcribee.transcribe import assign_speakers
    whisper = [(0.0, 2.0, "hello world")]
    diarization = [(0.0, 3.0, "SPEAKER_00")]
    result = assign_speakers(whisper, diarization)
    assert result == [(0.0, 2.0, "SPEAKER_00", "hello world")]


def test_assign_speakers_no_diarization():
    """Empty diarization → all segments labeled UNKNOWN."""
    from transcribee.transcribe import assign_speakers
    whisper = [(0.0, 2.0, "hello")]
    result = assign_speakers(whisper, [])
    assert result[0][2] == "UNKNOWN"


def test_assign_speakers_midpoint_fallback():
    """Uses midpoint when no overlap found."""
    from transcribee.transcribe import assign_speakers
    whisper = [(0.0, 1.0, "hi")]
    diarization = [(0.4, 0.8, "SPEAKER_01")]
    result = assign_speakers(whisper, diarization)
    assert result[0][2] == "SPEAKER_01"


def test_format_output_merges_consecutive_same_speaker():
    """Consecutive segments from same speaker are merged."""
    from transcribee.transcribe import format_output
    labeled = [
        (0.0, 1.0, "SPEAKER_00", "hello"),
        (1.0, 2.0, "SPEAKER_00", "world"),
        (2.0, 3.0, "SPEAKER_01", "hi"),
    ]
    output = format_output(labeled)
    lines = output.strip().split("\n")
    assert len(lines) == 2
    assert "Speaker 1" in lines[0]
    assert "hello world" in lines[0]
    assert "Speaker 2" in lines[1]


def test_format_output_empty():
    from transcribee.transcribe import format_output
    assert format_output([]) == ""


def test_format_timestamp():
    from transcribee.transcribe import format_timestamp
    assert format_timestamp(65.0) == "01:05"
    assert format_timestamp(0.0) == "00:00"


def test_language_auto_maps_to_none():
    """'auto' language → None passed to faster-whisper model.transcribe."""
    tmp = Path(tempfile.mkdtemp())
    wav = tmp / "audio.wav"
    # 44-byte WAV header + 2 bytes of data so the empty-audio check passes
    wav.write_bytes(b"RIFF\x2e\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x80\x3e\x00\x00\x00\x7d\x00\x00\x02\x00\x10\x00data\x02\x00\x00\x00\x00\x00")

    mock_seg = MagicMock()
    mock_seg.start = 0.0
    mock_seg.end = 1.0
    mock_seg.text = "shalom"

    mock_info = MagicMock()
    mock_info.duration = 1.0

    mock_model = MagicMock()
    mock_model.transcribe.return_value = ([mock_seg], mock_info)

    with patch("transcribee.transcribe._load_whisper_model", return_value=mock_model), \
         patch("transcribee.diarize.run", return_value=[]), \
         patch("transcribee.transcribe.ensure_wav", return_value=wav):

        from transcribee.transcribe import run
        run(wav, language="auto", diarize_backend="none", num_speakers=None, out_path=tmp / "out.txt")

    call_kwargs = mock_model.transcribe.call_args
    # language=None should have been passed (not "auto")
    passed_lang = call_kwargs.kwargs.get("language") if call_kwargs.kwargs else call_kwargs[1].get("language")
    assert passed_lang is None

    shutil.rmtree(tmp)
