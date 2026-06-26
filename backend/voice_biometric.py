"""
voice_biometric.py — SpeechBrain ECAPA-TDNN speaker-verification barge-in.

Phase 5 — Biometric Voice Lock.

During setup, the user reads a 10-second sentence to create an offline
vocal footprint. During Live Call, any non-owner sound (door slam,
dog bark, another speaker) is scored and ignored; when the owner
speaks, the system matches the footprint and halts the AI's playback
(natural barge-in).

NOTE: This is a placeholder. Implement `_load_speechbrain()` once the
SpeechBrain dependency is provisioned.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Optional

log = logging.getLogger("tim.biometric")

VERIFICATION_THRESHOLD = 0.50
ENROLMENT_SENTENCE = (
    "My voice is my passport. Verify me. T.I.M. listens for this "
    "vocal footprint and ignores anyone else who speaks."
)


class VoiceBiometricLock:
    def __init__(self, embedding_path: str = "./enrollments/owner.pt") -> None:
        self.embedding_path = embedding_path
        self._owner_embedding: Optional[list[float]] = None
        self._sb_model = None
        self._try_load()

    def _try_load(self) -> None:
        if os.path.exists(self.embedding_path):
            try:
                import torch  # type: ignore
                self._owner_embedding = torch.load(self.embedding_path).tolist()
                log.info("Owner voiceprint loaded from %s", self.embedding_path)
            except Exception as e:  # noqa: BLE001
                log.warning("Could not load owner voiceprint (%s).", e)

        try:
            # from speechbrain.inference.speaker import EncoderClassifier  # noqa
            # self._sb_model = EncoderClassifier.from_hparams(
            #     source="speechbrain/spkrec-ecapa-voxceleb",
            #     savedir="./models/sb_ecapa",
            # )
            log.warning("SpeechBrain load is stubbed; uncomment in production.")
        except Exception as e:  # noqa: BLE001
            log.warning("SpeechBrain unavailable (%s); open mode.", e)

    async def verify(self, pcm: bytes) -> bool:
        if self._sb_model is None or self._owner_embedding is None:
            log.info("Biometric in open-mode; accepting.")
            return True
        emb = await self._embed(pcm)
        sim = self._cosine(emb, self._owner_embedding)
        log.info("Speaker cosine similarity: %.3f (threshold %.2f)",
                 sim, VERIFICATION_THRESHOLD)
        return sim >= VERIFICATION_THRESHOLD

    async def _embed(self, pcm: bytes) -> list[float]:
        return self._owner_embedding or [0.0] * 192

    @staticmethod
    def _cosine(a: list[float], b: list[float]) -> float:
        if not a or not b or len(a) != len(b):
            return 0.0
        dot = sum(x * y for x, y in zip(a, b))
        na = sum(x * x for x in a) ** 0.5
        nb = sum(y * y for y in b) ** 0.5
        if na == 0 or nb == 0:
            return 0.0
        return dot / (na * nb)

    async def handle_enrollment(self, ws, msg: dict) -> None:
        """
        Phase 5 enrolment flow:
          1. Flutter sends {"type":"enroll","action":"start"}.
          2. Server replies with the enrolment sentence to display.
          3. User reads it aloud (~10s); PCM is captured.
          4. Server embeds + averages 3-5 captures, saves to disk.
        """
        log.info("Enrolment requested.")
        await ws.send(json.dumps({
            "type": "enroll",
            "status": "ready",
            "sentence": ENROLMENT_SENTENCE,
            "duration_sec": 10,
        }))

    async def close(self) -> None:
        pass
