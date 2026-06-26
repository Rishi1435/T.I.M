"""
stt_whisper.py — Whisper STT wrapper (Phase 5).

Production: wrap faster-whisper or whisper-cpp-python. The placeholder
returns an empty string so the WS pipeline can be exercised end-to-end.
"""

from __future__ import annotations

import logging

log = logging.getLogger("tim.stt")


class WhisperSTT:
    def __init__(self, model_path: str = "./models/ggml-base.en.bin") -> None:
        self.model_path = model_path
        self._model = None
        self._try_load()

    def _try_load(self) -> None:
        try:
            # from faster_whisper import WhisperModel  # type: ignore
            # self._model = WhisperModel(self.model_path, device="cpu")
            log.warning("Whisper load is stubbed; uncomment in production.")
        except Exception as e:  # noqa: BLE001
            log.warning("Whisper unavailable (%s); open mode.", e)

    async def transcribe(self, pcm: bytes) -> str:
        log.info("STT placeholder for %d bytes PCM.", len(pcm))
        return ""

    async def transcribe_with_timestamps(self, pcm: bytes) -> list[dict]:
        """Returns word-level timestamps for the Speech Analytics module."""
        return []
