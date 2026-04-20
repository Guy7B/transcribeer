import sys
from pathlib import Path
from unittest.mock import MagicMock
import pytest


def test_none_backend_returns_empty_list(tmp_path):
    wav = tmp_path / "audio.wav"
    wav.write_bytes(b"")
    from transcribeer.diarize import run
    result = run(wav, backend="none")
    assert result == []


def test_unknown_backend_raises(tmp_path):
    wav = tmp_path / "audio.wav"
    wav.write_bytes(b"")
    from transcribeer.diarize import run
    with pytest.raises(ValueError, match="Unknown diarization backend"):
        run(wav, backend="invalid_backend")


def test_pyannote_backend_returns_tuples(tmp_path):
    """pyannote backend returns list of (float, float, str) tuples."""
    wav = tmp_path / "audio.wav"
    wav.write_bytes(b"")

    mock_turn = MagicMock()
    mock_turn.start = 0.0
    mock_turn.end = 2.5

    mock_diarization = MagicMock()
    mock_diarization.itertracks.return_value = [(mock_turn, None, "SPEAKER_00")]

    mock_result = MagicMock()
    mock_result.speaker_diarization = mock_diarization

    mock_pipeline = MagicMock(return_value=mock_result)

    mock_waveform = MagicMock()
    mock_sample_rate = 16000

    from unittest.mock import patch
    with patch("transcribeer.diarize._load_pyannote_pipeline", return_value=mock_pipeline), \
         patch("torchaudio.load", return_value=(mock_waveform, mock_sample_rate)):
        from transcribeer.diarize import run
        result = run(wav, backend="pyannote")

    assert len(result) == 1
    start, end, speaker = result[0]
    assert start == 0.0
    assert end == 2.5
    assert isinstance(speaker, str)


def test_resemblyzer_backend_returns_tuples(tmp_path, monkeypatch):
    """resemblyzer backend returns list of (float, float, str) tuples."""
    import numpy as np

    wav = tmp_path / "audio.wav"
    wav.write_bytes(b"")

    mock_preprocessed = np.zeros(48000, dtype=np.float32)  # 3s at 16kHz — fits 1.5s windows
    mock_encoder = MagicMock()
    mock_encoder.embed_utterance.return_value = np.random.rand(256)
    mock_labels = np.array([0, 0, 1, 1])

    mock_resemblyzer = MagicMock()
    mock_resemblyzer.VoiceEncoder.return_value = mock_encoder

    mock_cluster = MagicMock()
    mock_cluster.fit_predict.return_value = mock_labels
    mock_sklearn_cluster = MagicMock()
    mock_sklearn_cluster.AgglomerativeClustering.return_value = mock_cluster

    monkeypatch.setitem(sys.modules, "resemblyzer", mock_resemblyzer)
    monkeypatch.setitem(sys.modules, "sklearn", MagicMock())
    monkeypatch.setitem(sys.modules, "sklearn.cluster", mock_sklearn_cluster)

    # The new timeline-preserving preprocess calls librosa + normalize_volume.
    from unittest.mock import patch
    with patch(
        "transcribeer.diarize._preprocess_wav_preserve_timeline",
        return_value=mock_preprocessed,
    ):
        from transcribeer.diarize import run
        result = run(wav, backend="resemblyzer", num_speakers=2)

    assert len(result) > 0
    for start, end, speaker in result:
        assert isinstance(start, float)
        assert isinstance(end, float)
        assert isinstance(speaker, str)
        assert speaker.startswith("SPEAKER_")


def test_resemblyzer_preprocess_preserves_timeline(tmp_path, monkeypatch):
    """`_preprocess_wav_preserve_timeline` returns a waveform the same length
    as the original audio — no VAD-based silence trimming.

    This is the fix for the ``???`` tail-label bug on long recordings: the
    previous code used ``resemblyzer.preprocess_wav`` which invokes
    ``trim_long_silences`` and produces a shorter waveform.
    """
    import numpy as np

    expected_sr = 16000
    duration_sec = 5
    expected_len = expected_sr * duration_sec
    # Mix real speech-like signal with a long silence block — trim_long_silences
    # would drop the silence, making the output shorter than the input. The new
    # helper must NOT do that.
    speech = np.random.RandomState(0).randn(expected_len // 2).astype(np.float32) * 0.1
    silence = np.zeros(expected_len // 2, dtype=np.float32)
    fake_wav = np.concatenate([speech, silence])

    # librosa.load is the only thing we need to mock; normalize_volume is pure
    # NumPy and runs real.
    from unittest.mock import patch
    with patch("librosa.load", return_value=(fake_wav, expected_sr)):
        from transcribeer.diarize import _preprocess_wav_preserve_timeline
        out = _preprocess_wav_preserve_timeline(tmp_path / "audio.wav")

    assert len(out) == len(fake_wav), (
        f"Timeline drift: input was {len(fake_wav)} samples but preprocess "
        f"returned {len(out)}. The fix must NOT trim silences."
    )
