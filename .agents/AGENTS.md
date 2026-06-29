# T.I.M. Project Development Guidelines

These rules and architectural patterns are saved in workspace memory for future development.

## 1. Local LLM & GPU Offloading Constraints
- **Lightweight Models (CPU Fallback)**: For lightweight models (e.g., `qwen25-3b`, `phi3-mini` with `minVramGb: 0`), set `gpuLayers = 0` during loading. Attempting to offload 99 layers on systems without dedicated CUDA hardware causes silent inference failures where the FFI stream yields zero tokens.
- **Offload Condition**: Only offload to GPU (`gpuLayers = 99`) if the model specifies `minVramGb > 0` and the hardware profiler matches or exceeds this threshold.

## 2. Text Input Controller Rebuilds
- **Dynamic Action Icons**: If a stateful widget's layout toggles icons or buttons conditionally based on a `TextEditingController`'s content (e.g., switching between a microphone icon and a send icon in the chat pill), you MUST add a listener in `initState` (and remove it in `dispose`):
  ```dart
  _inputCtrl.addListener(() => setState(() {}));
  ```
  Without this listener, Flutter will not trigger a rebuild when text is typed.

## 3. Dynamic Workspaces & Localized Memory
- **Workspace-Specific Chat History**: Persist chat messages under an active `workspace` key inside the SQLite database, and load history filtered by this workspace.
- **Localized RAG Memory**: Vector search queries (`semanticSearch` via sqlite-vec) must filter on the active workspace using SQL JSON extraction (`json_extract(metadata_json, '$.workspace') = ?`). Fallback to global database memories only if the workspace-specific search returns no hits.
- **Background Memory Indexing**: Memories extracted in the background must include the active workspace in their metadata.

## 4. UI Scroll Synchronization
- **Auto-Scrolling**: Use a Riverpod selector listener inside page builders to listen to changes in message history length and auto-scroll to the bottom. This ensures that new user messages and error bubbles trigger instant viewport updates:
  ```dart
  ref.listen<int>(chatProvider.select((s) => s.messages.length), (prev, next) {
    _scrollToBottom();
  });
  ```
