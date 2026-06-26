"""
job_scraper.py — Phase 7 SearXNG client.

Talks to a locally-running SearXNG instance (http://localhost:8080).
Returns raw listing dicts; the Flutter side does cosine matching
against the local encrypted vault.
"""

from __future__ import annotations

import logging
from typing import List

import httpx

log = logging.getLogger("tim.jobs")

SEARXNG_URL = "http://localhost:8080"


async def search_searxng(query: str, limit: int = 10) -> List[dict]:
    """Hit SearXNG's JSON API and return up to [limit] results."""
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.get(
            f"{SEARXNG_URL}/search",
            params={
                "q": query,
                "format": "json",
                "categories": "jobs",
                "pageno": 1,
            },
            headers={"Accept": "application/json"},
        )
    if resp.status_code != 200:
        log.warning("SearXNG returned %d", resp.status_code)
        return []
    body = resp.json()
    return body.get("results", [])[:limit]
