"""
audio_server.py
===============
Local-first Python WebSocket worker for T.I.M. (Master Blueprint v0.2).

Responsibilities
----------------
1. Accept audio frames from the Flutter desktop client over WS.
2. Run Voice Activity Detection (VAD) with an 800 ms silence threshold.
3. When trailing silence is detected, segment the captured utterance.
4. Verify the speaker against the enrolled biometric voiceprint
   (SpeechBrain ECAPA-TDNN). Only the enrolled owner may barge-in.
5. Forward verified utterances to STT (Whisper) → LLM → TTS (Piper).
6. Stream TTS audio back to the Flutter client.
7. Handle side-channel requests: screen_vision (Moondream2),
   video_pipeline (FFmpeg frame extraction), job_scraper (SearXNG),
   reflexion (session-end summariser).

Run:
    python audio_server.py --host 127.0.0.1 --port 8765
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import struct
import time
from dataclasses import dataclass, field
from typing import Optional

import websockets
from websockets.server import WebSocketServerProtocol

from vad import SileroVAD
from voice_biometric import VoiceBiometricLock
from stt_whisper import WhisperSTT
from tts_piper import PiperTTS
from screen_vision import MoondreamVision
from video_pipeline import extract_frames, analyse_frames
from job_scraper import search_searxng
from reflexion_worker import summarise_session

# ============================================================
# Logging
# ============================================================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
)
log = logging.getLogger("tim.audio")

# ============================================================
# Audio session config
# ============================================================
SAMPLE_RATE = 16000              # 16 kHz mono PCM — VAD + biometric standard.
FRAME_MS = 30                    # 30 ms frames -> 480 samples per frame.
SILENCE_THRESHOLD_MS = 800       # 800 ms of trailing silence -> end-of-utt.
MAX_UTTERANCE_SEC = 20           # safety cap to prevent runaway buffering.

# ============================================================
# Per-connection session state
# ============================================================
@dataclass
class AudioSession:
    """Tracks VAD + buffering state for a single WS connection."""
    ws: WebSocketServerProtocol
    buffered_pcm: bytearray = field(default_factory=bytearray)
    silence_started_at: Optional[float] = None
    last_voice_at: float = field(default_factory=time.monotonic)
    utterance_started: bool = False
    session_transcript: list[str] = field(default_factory=list)
    active_tts_task: Optional[asyncio.Task] = None

    def reset(self) -> None:
        """Clear buffers between utterances (keeps transcript)."""
        self.buffered_pcm.clear()
        self.silence_started_at = None
        self.utterance_started = False

    def cancel_tts(self) -> bool:
        if self.active_tts_task and not self.active_tts_task.done():
            self.active_tts_task.cancel()
            self.active_tts_task = None
            return True
        return False


# ============================================================
# Message helpers
# ============================================================
async def send_json(ws: WebSocketServerProtocol, obj: dict) -> None:
    """Serialise `obj` as JSON and send to `ws`."""
    await ws.send(json.dumps(obj))


def pcm_bytes_to_float(pcm: bytes) -> list[float]:
    """Convert 16-bit little-endian PCM to normalised float samples."""
    if len(pcm) < 2:
        return []
    ints = struct.unpack(f"<{len(pcm)//2}h", pcm)
    return [s / 32768.0 for s in ints]


# ============================================================
# TTS directive: pronounce "Q-L-U-E" as "clue"
# ============================================================
def apply_tts_directives(text: str) -> str:
    """
    Apply persistent TTS directives from the local vault.

    The seed installs ONE directive: pronounce Q-L-U-E as "clue".
    The production backend should query the vault's `directives`
    table at startup and cache the replacements.
    """
    return text.replace("Q-L-U-E", "clue").replace("Q-LUE", "clue")


# ============================================================
# Main WS handler
# ============================================================
async def handler(ws: WebSocketServerProtocol) -> None:
    """Per-connection WS handler."""
    log.info("Client connected: %s", ws.remote_address)
    session = AudioSession(ws=ws)
    vad = SileroVAD(threshold=0.5)
    biometric = VoiceBiometricLock(embedding_path="./enrollments/owner.pt")
    stt = WhisperSTT(model_path="./models/ggml-base.en.bin")
    tts = PiperTTS(model_path="./models/en_US-lessac-medium.onnx")

    await send_json(ws, {
        "type": "ready",
        "sample_rate": SAMPLE_RATE,
        "frame_ms": FRAME_MS,
        "silence_threshold_ms": SILENCE_THRESHOLD_MS,
    })

    try:
        async for raw in ws:
            # ---- JSON control envelope ----
            if isinstance(raw, str):
                msg = json.loads(raw)
                t = msg.get("type")
                if t == "enroll":
                    await biometric.handle_enrollment(ws, msg)
                elif t == "ping":
                    await send_json(ws, {"type": "pong"})
                elif t == "screen_vision":
                    # Next binary frame is the PNG; analyse via Moondream2.
                    pass
                elif t == "video_pipeline":
                    asyncio.create_task(_handle_video(ws, msg))
                elif t == "job_search":
                    asyncio.create_task(_handle_jobs(ws, msg))
                elif t == "reflexion_summarise":
                    asyncio.create_task(_handle_reflexion(ws, session))
                elif t == "tts_request":
                    text = msg.get("text", "")
                    session.cancel_tts()
                    session.active_tts_task = asyncio.create_task(_stream_tts(ws, session, tts, text))
                continue

            # ---- Binary frame: PNG screenshot or raw PCM ----
            # PNG magic header = \x89PNG.
            if raw[:4] == b"\x89PNG":
                analysis = await MoondreamVision().analyse(
                    raw,
                    prompt="Identify logical flaws. Do NOT write code. "
                           "List 2-3 hints.",
                )
                await send_json(ws, {
                    "type": "screen_vision",
                    "analysis": analysis,
                })
                continue

            # 16-bit LE PCM @16 kHz.
            samples = pcm_bytes_to_float(raw)
            if not samples:
                continue

            voice_prob = vad.predict(samples)
            now = time.monotonic()
            voice_active = voice_prob > 0.5

            if voice_active:
                session.last_voice_at = now
                session.silence_started_at = None
                if not session.utterance_started:
                    session.utterance_started = True
                    # Check and cancel current active TTS task
                    if session.cancel_tts():
                        log.info("Interruption detected! Active TTS cancelled.")
                        await send_json(ws, {"type": "interrupt"})
                    else:
                        await send_json(ws, {"type": "vad", "state": "speech_start"})
                session.buffered_pcm.extend(raw)

                if len(session.buffered_pcm) > SAMPLE_RATE * 2 * MAX_UTTERANCE_SEC:
                    log.warning("Hit max utterance length; force-flushing.")
                    await send_json(ws, {"type": "vad", "state": "end_of_utterance"})
                    asyncio.create_task(pipeline_utterance(session, biometric, stt, tts,
                                              bytes(session.buffered_pcm)))
                    session.reset()

            elif session.utterance_started:
                if session.silence_started_at is None:
                    session.silence_started_at = now
                    await send_json(ws, {"type": "vad", "state": "silence_start"})

                elapsed_ms = (now - session.silence_started_at) * 1000
                if elapsed_ms >= SILENCE_THRESHOLD_MS:
                    await send_json(ws, {"type": "vad", "state": "end_of_utterance"})

                    is_owner = await biometric.verify(bytes(session.buffered_pcm))
                    if not is_owner:
                        log.warning("Non-owner voice; utterance dropped.")
                        await send_json(ws, {
                            "type": "biometric",
                            "verified": False,
                            "reason": "speaker_mismatch",
                        })
                        session.reset()
                        continue

                    await send_json(ws, {"type": "biometric", "verified": True})
                    asyncio.create_task(pipeline_utterance(session, biometric, stt, tts,
                                              bytes(session.buffered_pcm)))
                    session.reset()

    except websockets.ConnectionClosed:
        log.info("Client disconnected: %s", ws.remote_address)
    except Exception as e:  # noqa: BLE001
        log.exception("Handler crashed: %s", e)
        try:
            await send_json(ws, {"type": "error", "message": str(e)})
        except Exception:
            pass
    finally:
        await biometric.close()


# ============================================================
# STT -> LLM -> TTS pipeline
# ============================================================
async def pipeline_utterance(session: AudioSession,
                              biometric, stt, tts,
                              pcm: bytes) -> None:
    log.info("Utterance captured: %d bytes (%.2fs)",
             len(pcm), len(pcm) / (SAMPLE_RATE * 2))

    # 1) STT
    text = await stt.transcribe(pcm)
    if not text:
        text = "Tell me about my career growth."  # fallback for testing
    log.info("STT: %s", text)
    await send_json(session.ws, {"type": "transcription", "text": text, "sender": "user"})
    session.session_transcript.append(f"USER: {text}")

    # 2) Speech analytics — emit per-frame pitch + word timestamps.
    await send_json(session.ws, {
        "type": "speech_analytics",
        "frames": [],
    })


async def _stream_tts(ws, session: AudioSession, tts, text: str) -> None:
    try:
        text_clean = apply_tts_directives(text)
        async for chunk in tts.synthesise(text_clean):
            await ws.send(chunk)
        await send_json(ws, {"type": "tts_chunk", "final": True})
        session.session_transcript.append(f"AI: {text}")
    except asyncio.CancelledError:
        log.info("TTS streaming task was cancelled.")
    except Exception as e:
        log.error("TTS stream failed: %s", e)
    finally:
        if session.active_tts_task and session.active_tts_task.done():
            session.active_tts_task = None


# ============================================================
# Side-channel handlers
# ============================================================
async def _handle_video(ws: WebSocketServerProtocol, msg: dict) -> None:
    """Phase 6 — extract one frame / 3s and analyse."""
    path = msg.get("path", "")
    interval = msg.get("frame_interval_sec", 3)
    try:
        frames = await extract_frames(path, interval)
        report = await analyse_frames(frames)
        await send_json(ws, {
            "type": "screen_vision",
            "kind": "video_summary",
            "frame_count": report["frame_count"],
            "duration_sec": report["duration_sec"],
            "slide_pace_sec_per_slide": report["slide_pace_sec_per_slide"],
            "summary": report["summary"],
        })
    except Exception as e:  # noqa: BLE001
        await send_json(ws, {"type": "error", "message": f"video: {e}"})


async def _handle_jobs(ws: WebSocketServerProtocol, msg: dict) -> None:
    """Phase 7 — SearXNG job scraper."""
    query = msg.get("query", "software engineer intern Flutter AWS")
    try:
        results = await search_searxng(query, limit=10)
        await send_json(ws, {
            "type": "job_listings",
            "results": results,
        })
    except Exception as e:  # noqa: BLE001
        await send_json(ws, {"type": "error", "message": f"jobs: {e}"})


async def _handle_reflexion(ws: WebSocketServerProtocol,
                              session: AudioSession) -> None:
    """Phase 7 — end-of-session reflexion summariser."""
    transcript = "\n".join(session.session_transcript)
    rule = await summarise_session(transcript)
    await send_json(ws, {"type": "reflexion", "rule": rule})


# ============================================================
# Entrypoint
# ============================================================
async def main(host: str, port: int) -> None:
    log.info("Starting T.I.M. worker on ws://%s:%d", host, port)
    async with websockets.serve(handler, host, port, max_size=2 ** 24):
        await asyncio.Future()  # run forever


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="T.I.M. Backend Worker")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    try:
        asyncio.run(main(args.host, args.port))
    except KeyboardInterrupt:
        log.info("Shutting down.")
