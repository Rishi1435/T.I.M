"""
video_pipeline.py — Phase 6 FFmpeg frame extraction (1 frame / 3s).

Requires ffmpeg.exe + ffprobe.exe in the backend/ directory (or PATH).
"""

from __future__ import annotations

import asyncio
import logging
import os
from typing import List

log = logging.getLogger("tim.video")

FFMPEG = os.environ.get("TIM_FFMPEG", "./ffmpeg.exe")
FFPROBE = os.environ.get("TIM_FFPROBE", "./ffprobe.exe")


async def extract_frames(mp4_path: str, interval_sec: int = 3) -> List[str]:
    """Extract one frame every `interval_sec` seconds from `mp4_path`."""
    out_dir = "./_frames"
    os.makedirs(out_dir, exist_ok=True)
    cmd = [
        FFMPEG, "-i", mp4_path,
        "-vf", f"fps=1/{interval_sec}",
        "-y", os.path.join(out_dir, "frame_%04d.png"),
    ]
    log.info("FFmpeg extract: %s", " ".join(cmd))
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    await proc.communicate()
    files = sorted(
        os.path.join(out_dir, f)
        for f in os.listdir(out_dir)
        if f.startswith("frame_")
    )
    return files


async def analyse_frames(frame_paths: List[str]) -> dict:
    """Aggregate analysis: slide pace, structure, body language."""
    duration_sec = len(frame_paths) * 3
    slide_pace = duration_sec / max(1, len(frame_paths))
    return {
        "frame_count": len(frame_paths),
        "duration_sec": duration_sec,
        "slide_pace_sec_per_slide": slide_pace,
        "summary": ("[video_pipeline placeholder] Pacing OK; consider "
                    "spending more time on the intro slide."),
    }
