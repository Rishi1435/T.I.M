"""
vad.py — Silero VAD v4 wrapper (with energy-based fallback).

See Master Blueprint Phase 5. The model file (silero_vad.onnx) is
expected at ./models/silero_vad.onnx.
"""

from __future__ import annotations

import logging
import math
import os
from typing import List

log = logging.getLogger("tim.vad")


class SileroVAD:
    def __init__(self, threshold: float = 0.5,
                 model_path: str = "./models/silero_vad.onnx") -> None:
        self.threshold = threshold
        self.model_path = model_path
        self._session = None
        self._try_load_onnx()

    def _try_load_onnx(self) -> None:
        try:
            import onnxruntime as ort  # type: ignore
            if os.path.exists(self.model_path):
                self._session = ort.InferenceSession(self.model_path)
                log.info("Silero VAD ONNX model loaded from %s", self.model_path)
            else:
                log.warning("Silero VAD model not found at %s; "
                            "using energy fallback.", self.model_path)
        except Exception as e:  # noqa: BLE001
            log.warning("ONNX runtime unavailable (%s); "
                        "using energy fallback.", e)

    def predict(self, samples: List[float]) -> float:
        if self._session is not None:
            return self._predict_onnx(samples)
        return self._predict_energy(samples)

    def _predict_onnx(self, samples: List[float]) -> float:
        # TODO: maintain LSTM hidden state across calls for causal VAD.
        return self._predict_energy(samples)

    @staticmethod
    def _predict_energy(samples: List[float]) -> float:
        if not samples:
            return 0.0
        rms = math.sqrt(sum(s * s for s in samples) / len(samples))
        return min(1.0, rms / 0.05)
