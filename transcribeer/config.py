from __future__ import annotations

import tomllib
from dataclasses import dataclass
from pathlib import Path


def _config_path() -> Path:
    return Path.home() / ".transcribeer" / "config.toml"

_DEFAULTS = {
    "transcription": {
        "language": "auto",
        "diarization": "resemblyzer",
        "num_speakers": 0,
    },
    "summarization": {
        "backend": "ollama",
        "model": "llama3",
        "ollama_host": "http://localhost:11434",
        "prompt_on_stop": True,
    },
    "paths": {
        "sessions_dir": "~/.transcribeer/sessions",
        "capture_bin": "~/.transcribeer/bin/capture-bin",
    },
    "pipeline": {
        "mode": "record+transcribe+summarize",
    },
}

PIPELINE_MODES = [
    "record-only",
    "record+transcribe",
    "record+transcribe+summarize",
]


@dataclass
class Config:
    language: str
    diarization: str
    num_speakers: int | None
    llm_backend: str
    llm_model: str
    ollama_host: str
    sessions_dir: Path
    capture_bin: Path
    pipeline_mode: str = "record+transcribe+summarize"
    prompt_on_stop: bool = True


def load() -> Config:
    """Load ~/.transcribeer/config.toml. Missing keys use defaults. Never raises."""
    data: dict = {}
    cfg_path = _config_path()
    if cfg_path.exists():
        with open(cfg_path, "rb") as f:
            data = tomllib.load(f)

    def get(section: str, key: str):
        return data.get(section, {}).get(key, _DEFAULTS[section][key])

    raw_speakers = get("transcription", "num_speakers")
    num_speakers = None if raw_speakers == 0 else int(raw_speakers)

    return Config(
        language=get("transcription", "language"),
        diarization=get("transcription", "diarization"),
        num_speakers=num_speakers,
        llm_backend=get("summarization", "backend"),
        llm_model=get("summarization", "model"),
        ollama_host=get("summarization", "ollama_host"),
        sessions_dir=Path(get("paths", "sessions_dir")).expanduser(),
        capture_bin=Path(get("paths", "capture_bin")).expanduser(),
        pipeline_mode=get("pipeline", "mode"),
        prompt_on_stop=bool(get("summarization", "prompt_on_stop")),
    )


def save(cfg: Config) -> None:
    """Write cfg back to ~/.transcribeer/config.toml (creates dirs as needed)."""
    cfg_path = _config_path()
    cfg_path.parent.mkdir(parents=True, exist_ok=True)

    raw_speakers = 0 if cfg.num_speakers is None else cfg.num_speakers

    lines: list[str] = []

    lines += [
        "[pipeline]",
        f'mode = "{cfg.pipeline_mode}"',
        "",
        "[transcription]",
        f'language = "{cfg.language}"',
        f'diarization = "{cfg.diarization}"',
        f"num_speakers = {raw_speakers}",
        "",
        "[summarization]",
        f'backend = "{cfg.llm_backend}"',
        f'model = "{cfg.llm_model}"',
        f'ollama_host = "{cfg.ollama_host}"',
        f"prompt_on_stop = {'true' if cfg.prompt_on_stop else 'false'}",
        "",
        "[paths]",
        f'sessions_dir = "{cfg.sessions_dir}"',
        f'capture_bin = "{cfg.capture_bin}"',
        "",
    ]

    cfg_path.write_text("\n".join(lines), encoding="utf-8")
