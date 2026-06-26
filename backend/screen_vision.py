"""
screen_vision.py — Phase 6 voice-triggered screen watcher (Moondream2).

Triggered ONLY by an explicit voice command ("T.I.M., look at my
screen"). The Flutter app takes a screenshot, downscales it, and
sends the PNG bytes over WS. This module runs it through Moondream2
and returns textual analysis.

T.I.M. does NOT write code for the user. It highlights logical flaws
and guides them to the solution.
"""

from __future__ import annotations

import logging

log = logging.getLogger("tim.screen_vision")


class MoondreamVision:
    def __init__(self, model_path: str = "./models/moondream2.onnx") -> None:
        self.model_path = model_path
        self._model = None
        self._try_load()

    def _try_load(self) -> None:
        try:
            # from transformers import AutoModelForCausalLM  # type: ignore
            # self._model = AutoModelForCausalLM.from_pretrained(
            #     "vikhyatk/moondream2", trust_remote_code=True
            # )
            log.warning("Moondream2 load is stubbed; uncomment in production.")
        except Exception as e:  # noqa: BLE001
            log.warning("Moondream2 unavailable (%s); open mode.", e)

    async def analyse(self, png_bytes: bytes,
                       prompt: str = "Identify logical flaws. Do NOT write code. List 2-3 hints.") -> str:
        log.info("Moondream2 placeholder for %d bytes PNG.", len(png_bytes))
        return ("[screen_vision placeholder] Two hints:\n"
                "1. Re-check your loop bounds.\n"
                "2. Verify the nullability of the response payload.")
