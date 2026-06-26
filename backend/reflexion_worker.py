"""
reflexion_worker.py — Phase 7 session-end summariser.

Receives the full session transcript and produces ONE concrete
"learned rule" that T.I.M. should drill in future sessions.

Production: call the in-process LLM (via llama.cpp Python bindings)
to generate the summary. Placeholder returns a canned rule so the
WS pipeline can be exercised.
"""

from __future__ import annotations

import logging

log = logging.getLogger("tim.reflexion")


async def summarise_session(transcript: str) -> str:
    if not transcript.strip():
        return "<empty session — nothing to reflect on>"
    log.info("Reflexion summarising %d chars.", len(transcript))
    return ("[reflexion placeholder] User rambled on system design — "
            "drill the STAR method for behavioural answers next session.")
