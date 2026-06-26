# T.I.M. Backend Worker (Master Blueprint v0.2)

Local-first Python WebSocket worker for T.I.M.'s voice + vision +
scraper pipelines.

## Quick start

```bash
cd backend
python -m venv .venv
.venv/Scripts/activate          # Windows
pip install -r requirements.txt
python audio_server.py --host 127.0.0.1 --port 8765
```

## Protocol

The server speaks a JSON + binary protocol over WebSocket.

### Server -> Client (JSON)

| `type`              | Payload                                              |
|---------------------|------------------------------------------------------|
| `ready`             | `{sample_rate, frame_ms, silence_threshold_ms}`     |
| `vad`               | `{state: speech_start\|silence_start\|end_of_utt}`  |
| `biometric`         | `{verified: bool, reason?: str}`                    |
| `transcription`     | `{text: str, sender?: "ai"\|"user"}`                |
| `tts_chunk`         | `{final: bool}`                                     |
| `speech_analytics`  | `{frames: [...]}`                                   |
| `screen_vision`     | `{analysis: str}` or `{kind: "video_summary", ...}` |
| `job_listings`      | `{results: [...]}`                                  |
| `reflexion`         | `{rule: str}`                                       |
| `error`             | `{message: str}`                                    |

### Client -> Server

- Binary frames: 16-bit LE PCM @ 16 kHz mono, OR a PNG screenshot
  (detected via the `\x89PNG` magic header).
- JSON control envelopes:
  - `{"type":"ping"}`
  - `{"type":"enroll","action":"start"}`
  - `{"type":"video_pipeline","path":"C:/...","frame_interval_sec":3}`
  - `{"type":"job_search","query":"flutter intern"}`
  - `{"type":"reflexion_summarise"}`

## Tuning knobs

| Constant                  | Default | Location          |
|---------------------------|---------|-------------------|
| `SILENCE_THRESHOLD_MS`    | 800     | `audio_server.py` |
| `MAX_UTTERANCE_SEC`       | 20      | `audio_server.py` |
| `VERIFICATION_THRESHOLD`  | 0.50    | `voice_biometric.py` |

## Status

| Module              | Status      |
|---------------------|-------------|
| WS server + VAD     | Implemented |
| Silero VAD ONNX     | Stubbed (energy fallback) |
| SpeechBrain biometric | Stubbed (open mode)     |
| Whisper STT         | Stubbed     |
| Piper TTS           | Stubbed     |
| Moondream2 vision   | Stubbed     |
| FFmpeg video frames | Implemented (subprocess) |
| SearXNG scraper     | Implemented |
| Reflexion summariser | Stubbed    |
