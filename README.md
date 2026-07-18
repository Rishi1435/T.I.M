# T.I.M. — This Is Me  (Master Blueprint v0.3 — Path B)

A **100% offline, privacy-first, E2EE** AI mentor compiled as a native
Windows `.exe`. T.I.M. learns exclusively from you, forces you to confront
your flaws, corrects your communication, and secures your data with
end-to-end AES-256-GCM encryption (Argon2id key derivation).

## Architecture — Path B (fully native, v0.3)

```
 ┌─────────────────────────────────────────────────────────────┐
 │  Flutter Desktop (single native Windows .exe)               │
 │                                                             │
 │  UI: Gemini-style shell + Live Call overlay (Riverpod)      │
 │                                                             │
 │  LLM:    llama_cpp_dart (FFI)  → .gguf in AppData           │
 │  Voice:  sherpa-onnx    (FFI)  → one C runtime for          │
 │          Silero VAD · Whisper STT · Piper TTS ·             │
 │          speaker verification (Voice Lock)                  │
 │  Vault:  SQLite + sqlite-vec, AES-256-GCM, Argon2id KDF     │
 │  Video:  bundled ffmpeg.exe (frame extraction)              │
 │  Vision: Moondream2 — ⬜ pending multimodal runtime          │
 └──────────────┬──────────────────────────────────────────────┘
                │ AES-256-GCM ciphertext blobs (only if Cloud Sync ON)
                ▼
        ┌──────────────────┐
        │  Supabase        │  auth + encrypted memory_blobs only.
        │  (RLS per-user)  │  Never sees plaintext.
        └──────────────────┘
```

**There is no Python worker.** v0.2's `backend/` (venv + pip + a
localhost WebSocket that any process could connect to) is deleted.
Everything it did now runs in-process via Dart FFI: smaller install
(~180 MB of ONNX voice models vs multi-GB pip tree), no port 8765,
no "worker offline" failure mode, mic audio never leaves the process.

## Repo layout

```
TIM_Project_Workspace/
├── pubspec.yaml
├── lib/
│   ├── main.dart, app.dart
│   ├── core/                 # theme, config, logger, constants
│   ├── data/
│   │   ├── services/         # supabase, native_worker, audio_engine,
│   │   │                     # biometric_gate, voice_models_catalog,
│   │   │                     # local_vault, crypto, llm_engine,
│   │   │                     # model_downloader, speech_analytics,
│   │   │                     # screen_watcher, video_pipeline, job_scraper,
│   │   │                     # reflexion_engine, tim_backup
│   │   ├── models/           # memory, file_chip, voice_frame, learned_rule
│   │   └── repositories/     # memory_repository (sqlite-vec), directives_repo
│   ├── platform/
│   │   └── channels/         # hardware_scanner (RAM/VRAM/Battery via DXGI)
│   └── presentation/
│       ├── providers/        # auth, vault, chat, voice, onboarding,
│       │                     # hardware, model, sync
│       ├── screens/          # login, home, genesis, live_call
│       └── widgets/          # sidebar, chat_input, message_bubble,
│                             # voice_indicator, memory_block, file_chip,
│                             # waveform, override_modal, drag_drop_zone
└── assets/
```

## Phase-by-phase status

Legend: **Implemented** = works end-to-end · 🔧 = code-complete, needs on-device verification · ⬜ = planned

| Phase | Module                              | Status            |
|-------|-------------------------------------|-------------------|
| 1     | Gemini UI + sidebar                 | Implemented       |
| 1     | Live Call View (waveform overlay)   | Implemented       |
| 1     | Multi-tenant Supabase login         | Implemented       |
| 1     | Drag-and-drop universal input       | Implemented       |
| 2     | llama_cpp_dart FFI engine           | Wired (drop in GGUF) |
| 2     | Hardware profiler (RAM/VRAM/Batt)   | Implemented (Dart + C++) |
| 2     | .gguf auto-downloader               | Implemented       |
| 2     | Safety override modal               | Implemented       |
| 3     | Genesis onboarding screen           | Implemented       |
| 3     | Resume → Memory Blocks extraction   | Wired (LLM-extracted) |
| 3     | Confirm-before-vectorise dashboard  | Implemented       |
| 4     | Local SQLite + sqlite-vec vault     | Implemented       |
| 4     | AES-256-GCM E2EE (Argon2id KDF)     | Implemented (v2 blobs; v1 PBKDF2 fallback) |
| 4     | Encrypted Supabase blob sync        | Implemented       |
| 4     | Export/Import .tim backup           | Implemented       |
| 5     | VAD (350ms adaptive) + Whisper STT  | 🔧 Native (sherpa-onnx), needs device test |
| 5     | Piper TTS streaming                 | 🔧 Native per-sentence streaming, needs device test |
| 5     | Speech analytics (filler/pitch/gap) | Implemented       |
| 5     | Biometric barge-in (two-stage)      | 🔧 Native (3D-Speaker), open mode until enrolled |
| 6     | PDF text extraction                 | Implemented (syncfusion) |
| 6     | Voice-triggered screen watcher      | ⬜ Honest stub — pends multimodal runtime |
| 6     | FFmpeg video frame extraction       | 🔧 Native Process.run (bundle ffmpeg.exe) |
| 7     | Job search (online opt-in module)   | ⬜ Redesign: RSS/JSON feeds, no SearXNG server |
| 7     | Reflexion self-correction loop      | Implemented       |

## Setup (one runtime, no Python)

```bash
cd tim_project
flutter pub get
flutter run -d windows \
  --dart-define=SUPABASE_URL=https://YOUR-PROJECT.supabase.co \
  --dart-define=SUPABASE_ANON_KEY=YOUR-ANON-KEY
```

First launch → Settings → Voice → **Download voice models** (~180 MB,
SHA-256 pinned on first download). Then drop a `.gguf` via the model
downloader as before. Supabase (optional, only for encrypted sync):

```bash
supabase db push   # applies migrations 0001 + 0002
```

## Troubleshooting (Windows)

| Symptom | Fix |
|---|---|
| `No file or variants found for asset: .env` during build | Fixed in v0.3.1 — the `.env` asset entry is removed from pubspec. Pull latest / apply the hotfix patch. Use `--dart-define` for config. |
| `Building with plugins requires symlink support` | Enable **Settings → System → For developers → Developer Mode**, then `flutter clean && flutter run`. |
| `Failed to load dynamic library 'llama.dll'` / model load crash | Run `dart run build.dart` once from `tim_project\` (or `.\windows-setup.ps1`). It downloads llama.dll (b5206, AVX2) into the build output. |
| `Please initialize sherpa-onnx first` | Something called the audio engine before `NativeWorker.connect()` finished. Check the `ready` event before starting a call. |
| Voice models "missing" error at startup | Expected on first run — Settings → Voice → **Download voice models** (~180 MB, SHA-256 pinned). |
| Speech analytics shows zero words/timing | Fixed in v0.3.1 — Whisper needed `enableTokenTimestamps: true` (sherpa-onnx 1.13.x returns empty timestamps without it). |
| `git am` fails with "previous rebase directory .git/rebase-apply still exists" | A prior `git am` half-applied: run `git am --abort`, then re-apply. |

## TTS Directive (built-in)

The seed enforces that the TTS engine **always** pronounces **Q-L-U-E** as
the spoken word **"clue"**. This rule lives in the local `directives` table
as a `tts` directive and is applied by the TTS layer before synthesis.

## Remaining work (tracked)

1. On-device verification pass of the native voice loop (mic →
   sherpa-onnx VAD/STT → LLM → Piper TTS → playback) on the target
   8 GB laptop; tune `SileroVadModelConfig.minSilenceDuration`.
2. Voice Lock enrollment UI (Settings → Voice → Enroll, sends
   `voice_enroll_start` and streams 10 s of mic audio).
3. Multimodal runtime for screen vision (Moondream2 via a llama.cpp
   build with mtmd, exposed through the `VisionEngine` hook in
   `native_worker.dart`).
4. Bundle `ffmpeg.exe` into `<AppData>/bin/` (installer step).
5. Job module redesign: online opt-in, official RSS/JSON feeds
   fetched from Dart — no SearXNG server.
6. Vault re-encryption sweep: legacy v1 (PBKDF2) blobs upgrade to
   v2 (Argon2id) on next save.
