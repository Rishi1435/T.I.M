"""
tts_piper.py — Piper TTS streaming wrapper (Phase 5).

Production: wrap piper-tts. The placeholder yields no PCM so the WS
pipeline can be exercised end-to-end without a TTS model.

Critical: `apply_tts_directives` in audio_server.py replaces "Q-L-U-E"
with "clue" before synthesis — so the spoken output always says "clue".
"""

from __future__ import annotations

import logging
from typing import AsyncIterator

log = logging.getLogger("tim.tts")


class PiperTTS:
    def __init__(self, model_path: str = "./models/en_US-lessac-medium.onnx") -> None:
        self.model_path = model_path
        self._model = None
        self._try_load()

    def _try_load(self) -> None:
        try:
            # import piper  # type: ignore
            # self._model = piper.PiperVoice.load(self.model_path)
            log.warning("Piper load is stubbed; uncomment in production.")
        except Exception as e:  # noqa: BLE001
            log.warning("Piper unavailable (%s); open mode.", e)

    async def synthesise(self, text: str) -> AsyncIterator[bytes]:
        """Yields 16-bit LE PCM @16 kHz mono."""
        log.info("TTS placeholder for: %s", text)
        if False:  # pragma: no cover
            yield b""
