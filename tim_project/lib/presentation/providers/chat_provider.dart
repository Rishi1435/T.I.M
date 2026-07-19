// ============================================================
// lib/presentation/providers/chat_provider.dart
// Chat state. Listens to [NativeWorker] for VAD / biometric /
// transcription events and forwards a unified chat-message stream
// to the UI.
// ============================================================

import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/logger.dart';
import '../../data/models/file_chip.dart';
import '../../data/services/llm_engine.dart';
import '../../data/services/screen_watcher.dart';
import '../../data/services/native_worker.dart';
import '../../data/services/windows_ocr.dart';
import 'model_provider.dart';
import 'vault_provider.dart';

enum MessageSender { user, ai, system }

@immutable
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.sender,
    required this.text,
    this.timestamp,
    this.attachments = const [],
  });
  final String id;
  final MessageSender sender;
  final String text;
  final DateTime? timestamp;
  final List<FileChip> attachments;

  ChatMessage copyWith({
    String? id,
    MessageSender? sender,
    String? text,
    DateTime? timestamp,
    List<FileChip>? attachments,
  }) =>
      ChatMessage(
        id: id ?? this.id,
        sender: sender ?? this.sender,
        text: text ?? this.text,
        timestamp: timestamp ?? this.timestamp,
        attachments: attachments ?? this.attachments,
      );
}

enum VoiceState { idle, listening, verifying, speaking }

@immutable
class ChatState {
  const ChatState({
    this.messages = const [],
    this.voice = VoiceState.idle,
    this.connected = false,
    this.pendingChips = const [],
    this.isGenerating = false,
    this.streamingMessageId,
    this.activeWorkspace = 'General',
  });

  final List<ChatMessage> messages;
  final VoiceState voice;
  final bool connected;
  final List<FileChip> pendingChips;
  /// True while the LLM is streaming tokens.
  final bool isGenerating;
  /// The id of the message currently being streamed (if any).
  final String? streamingMessageId;
  final String activeWorkspace;

  ChatState copyWith({
    List<ChatMessage>? messages,
    VoiceState? voice,
    bool? connected,
    List<FileChip>? pendingChips,
    bool? isGenerating,
    Object? streamingMessageId = _sentinel,
    String? activeWorkspace,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        voice: voice ?? this.voice,
        connected: connected ?? this.connected,
        pendingChips: pendingChips ?? this.pendingChips,
        isGenerating: isGenerating ?? this.isGenerating,
        streamingMessageId: identical(streamingMessageId, _sentinel)
            ? this.streamingMessageId
            : streamingMessageId as String?,
        activeWorkspace: activeWorkspace ?? this.activeWorkspace,
      );
}

// Sentinel so copyWith can explicitly null out streamingMessageId.
const Object _sentinel = Object();

/// Single shared [NativeWorker] instance (Path B: the voice
/// pipeline runs in-process — no Python, no localhost socket).
final timWorkerProvider = Provider<NativeWorker>((ref) {
  final worker = NativeWorker();
  ref.onDispose(worker.dispose);
  return worker;
});

/// Back-compat alias for older call sites.
final webSocketProvider = timWorkerProvider;

class ChatNotifier extends StateNotifier<ChatState> {
  ChatNotifier(this._ws, this._llm, this._vaultCtrl, this._ref)
      : super(const ChatState()) {
    _ws.connect();
    _sub = _ws.events.listen(_onEvent);
    _audioPlayer.onPlayerComplete.listen((_) {
      _ttsPlaying = false;
      if (_ttsQueue.isNotEmpty) {
        _drainTtsQueue();
      } else {
        _notifyPlayback(false);
        state = state.copyWith(voice: VoiceState.idle);
      }
    });
    // v0.3.4: launch into a FRESH session instead of resurfacing the
    // previous conversation ("when a user opens the application it was
    // showing me the previous chat — it needs to open a new session").
    // The session only materialises in the DB when a message is sent,
    // and gets auto-titled from that first message. Older sessions
    // stay one click away in the sidebar.
    state = state.copyWith(activeWorkspace: 'New Chat');
  }

  final NativeWorker _ws;
  final LlmEngine _llm;
  final VaultController _vaultCtrl;
  final Ref _ref;
  late final StreamSubscription<WsEvent> _sub;
  final Logger _log = Logger('ChatNotifier');
  final _audioPlayer = AudioPlayer();
  final List<int> _pcmBuffer = [];

  /// Update UI on every token for maximum perceived speed.
  static const int _uiUpdateEveryN = 1;
  int _tokensSinceUpdate = 0;

  /// Set to true when the user presses Stop to cancel an in-flight generation.
  bool _cancelRequested = false;

  /// Synchronous in-flight guard. `state.isGenerating` is only set after
  /// async RAG work, leaving a race window where a double-Enter sent the
  /// same message twice (the duplicated "hi" bubbles). This flag is set
  /// before the first await and closes that window.
  bool _sendBusy = false;

  /// Strip chat-template control tokens that a model may echo
  /// (e.g. a leaked `<|eot_id|` fragment) before persisting/rendering.
  static String _stripSpecialTokens(String text) => text
      .replaceAll(RegExp(r'<\|[A-Za-z0-9_]+\|>'), '')
      .replaceAll(RegExp(r'<\|[A-Za-z0-9_]*\|?>?\s*$'), '')
      .trimRight();

  /// Called by the UI Stop button to abort streaming.
  /// v0.3.9 — Copilot-style screen sharing: while ON, every message
  /// (typed or spoken) automatically carries a fresh snapshot of the
  /// screen text, no trigger phrase needed.
  bool screenShareActive = false;

  void toggleScreenShare() {
    screenShareActive = !screenShareActive;
    _addSystem(screenShareActive
        ? 'Screen sharing ON — every question now includes what\'s on '
            'your screen (captured at the moment you ask, read locally, '
            'never uploaded).'
        : 'Screen sharing OFF.');
  }

  Future<String> _screenContextIfSharing() async {
    if (!screenShareActive) return '';
    try {
      const channel = MethodChannel('tim.screen/capture');
      final png = await channel
          .invokeMethod<Uint8List>('capture')
          .timeout(const Duration(seconds: 8));
      if (png == null) return '';
      final txt = await WindowsOcr.extractText(png);
      if (txt == null || txt.trim().length < 10) return '';
      final clipped =
          txt.length > 2500 ? txt.substring(txt.length - 2500) : txt;
      return '\n[Current screen content (OCR)]:\n$clipped\n';
    } catch (_) {
      return '';
    }
  }

  final List<Uint8List> _ttsQueue = [];
  bool _ttsPlaying = false;

  bool _playbackNotified = false;
  Timer? _playbackOffTimer;

  void _notifyPlayback(bool active) {
    if (active) {
      // Cancel any pending 'off' — a new sentence arrived in the gap.
      _playbackOffTimer?.cancel();
      _playbackOffTimer = null;
    } else {
      // v0.4.0 — debounce OFF by 900 ms: between sentences the queue
      // is momentarily empty and the gate must NOT open in that gap.
      _playbackOffTimer?.cancel();
      _playbackOffTimer = Timer(const Duration(milliseconds: 900), () {
        _playbackNotified = false;
        _ws.sendJson({'type': 'playback_state', 'active': false});
      });
      return;
    }
    if (_playbackNotified == active) return;
    _playbackNotified = active;
    // v0.3.9 — the worker cannot know when SPEAKER OUTPUT is live
    // (synthesis finishes long before playback does). The client owns
    // the player, so the client tells the worker — this is the gate
    // that stops T.I.M. transcribing its own voice as the user.
    _ws.sendJson({'type': 'playback_state', 'active': active});
  }

  void _drainTtsQueue() {
    if (_ttsPlaying || _ttsQueue.isEmpty) return;
    _ttsPlaying = true;
    _notifyPlayback(true);
    final next = _ttsQueue.removeAt(0);
    _audioPlayer.play(BytesSource(next));
  }

  void _silenceTts() {
    _ws.sendJson({'type': 'tts_stop'});
    _ttsQueue.clear();
    _ttsPlaying = false;
    _notifyPlayback(false);
    _audioPlayer.stop();
    state = state.copyWith(voice: VoiceState.idle);
  }

  /// v0.3.8 — Stop now means stop: cancels generation, tells the
  /// worker to abandon queued TTS, silences playback, and releases
  /// the UI immediately (even if the C++ side takes a moment to
  /// unwind — during prompt processing llama.cpp cannot be
  /// interrupted mid-batch, so the UI must not wait for it).
  void stopGeneration() {
    _cancelRequested = true;
    _llm.cancelGeneration();
    _silenceTts();
    state = state.copyWith(isGenerating: false, streamingMessageId: null);
  }

  void _runLlmForVoice(String text) async {
    if (_sendBusy) return;
    _sendBusy = true;
    _cancelRequested = false;
    // v0.3.8 — voice mode is latency-critical: skip the RAG lookup
    // and cap history at the last 8 messages so prompt processing
    // (the un-interruptible part on CPU) stays short. Deep-memory
    // questions belong in chat, where waiting is acceptable.
    final vault = _vaultCtrl.vault;
    const ragContext = '';
    final recent = state.messages.length > 4
        ? state.messages.sublist(state.messages.length - 4)
        : state.messages;
    final screenCtx = await _screenContextIfSharing();
    final modelId = _ref.read(modelProvider).selected?.id ?? '';
    final stopSeqs = _getStopSequences(modelId);
    final prompt = _formatPrompt(
        modelId, recent, text, ragContext + screenCtx,
        voiceMode: true);

    final aiMsgId = DateTime.now().microsecondsSinceEpoch.toString();
    // Pre-add empty message for streaming response in UI
    _addMessage(MessageSender.ai, '', id: aiMsgId, persist: false);
    state = state.copyWith(isGenerating: true, streamingMessageId: aiMsgId);

    var response = '';
    var spokenUpTo = 0; // chars already handed to TTS
    final sentenceEnd = RegExp("[.!?][\\\"'\\)\\]]?\\s");
    try {
      await for (final token in _llm.generate(prompt, stop: stopSeqs)) {
        if (_cancelRequested) break;
        response += token;
        // v0.3.8 — speak WHILE generating: as soon as a sentence
        // completes, ship it to TTS. First audio lands after the
        // first sentence, not after the whole reply.
        final unspoken = response.substring(spokenUpTo);
        final m = sentenceEnd.firstMatch(unspoken);
        if (m != null) {
          final sentence =
              _stripSpecialTokens(unspoken.substring(0, m.end)).trim();
          if (sentence.isNotEmpty) {
            _ws.sendJson({'type': 'tts_request', 'text': sentence});
          }
          spokenUpTo += m.end;
        }
        // update UI
        state = state.copyWith(
          messages: state.messages.map((m) => m.id == aiMsgId ? m.copyWith(text: response) : m).toList(),
        );
      }
      response = _stripSpecialTokens(response);
      state = state.copyWith(
        messages: state.messages
            .map((m) => m.id == aiMsgId ? m.copyWith(text: response) : m)
            .toList(),
      );
      // Done streaming. Persist response and user message to DB safely.
      if (vault != null) {
        try {
          final userMsgId = DateTime.now().microsecondsSinceEpoch.toString();
          vault.insertChatMessage(
            id: userMsgId,
            sender: 'user',
            text: text,
            workspace: state.activeWorkspace,
          );
          vault.insertChatMessage(
            id: aiMsgId,
            sender: 'ai',
            text: response,
            workspace: state.activeWorkspace,
          );
          
          // Trigger background memory insertion / reflexion indexing
          _insertMemoriesBackground(text, response, vault);
        } catch (e) {
          _log.warn('Failed to save voice chat to DB: $e');
        }
      }
      
      // v0.3.8 — speak only the remainder, and only if the user did
      // not cancel. (Previously this fired unconditionally with the
      // partial reply, which is why T.I.M. started talking AFTER you
      // pressed Stop or left the call.)
      if (!_cancelRequested) {
        final tail = response.substring(
            spokenUpTo.clamp(0, response.length));
        if (tail.trim().isNotEmpty) {
          _ws.sendJson({'type': 'tts_request', 'text': tail.trim()});
        }
      } else {
        _silenceTts();
      }
    } catch (e) {
      _addSystem('AI reply generation failed: $e');
    } finally {
      _sendBusy = false;
      state = state.copyWith(isGenerating: false, streamingMessageId: null);
    }
  }

  Uint8List _createWavHeader(int numSamples, int sampleRate, int numChannels, int bitsPerSample) {
    final header = ByteData(44);
    final numBytes = numSamples * numChannels * (bitsPerSample ~/ 8);
    
    // "RIFF"
    header.setUint32(0, 0x52494646, Endian.big);
    // File size - 8
    header.setUint32(4, 36 + numBytes, Endian.little);
    // "WAVE"
    header.setUint32(8, 0x57415645, Endian.big);
    // "fmt "
    header.setUint32(12, 0x666d7420, Endian.big);
    // Subchunk1 Size (16 for PCM)
    header.setUint32(16, 16, Endian.little);
    // AudioFormat (1 for PCM)
    header.setUint16(20, 1, Endian.little);
    // NumChannels
    header.setUint16(22, numChannels, Endian.little);
    // SampleRate
    header.setUint32(24, sampleRate, Endian.little);
    // ByteRate
    header.setUint32(28, sampleRate * numChannels * (bitsPerSample ~/ 8), Endian.little);
    // BlockAlign
    header.setUint16(32, numChannels * (bitsPerSample ~/ 8), Endian.little);
    // BitsPerSample
    header.setUint16(34, bitsPerSample, Endian.little);
    // "data"
    header.setUint32(36, 0x64617461, Endian.big);
    // Subchunk2 Size
    header.setUint32(40, numBytes, Endian.little);
    
    return header.buffer.asUint8List();
  }

  /// Load the last 100 messages from the vault and hydrate state.
  void _loadHistory() {
    final vault = _vaultCtrl.vault;
    if (vault == null) {
      // Vault may not be unlocked yet; retry via a short delay.
      Future.delayed(const Duration(milliseconds: 800), _loadHistory);
      return;
    }
    try {
      final rows = vault.loadChatHistory(workspace: state.activeWorkspace, limit: 100);
      if (rows.isEmpty) {
        state = state.copyWith(messages: const []);
        return;
      }
      final msgs = rows.map((r) {
        final sender = switch (r['sender']) {
          'user' => MessageSender.user,
          'ai' => MessageSender.ai,
          _ => MessageSender.system,
        };
        return ChatMessage(
          id: r['id']!,
          sender: sender,
          text: r['text']!,
          timestamp: null,
        );
      }).toList();
      state = state.copyWith(messages: msgs);
    } catch (e) {
      _log.warn('Failed to load chat history: $e');
    }
  }

  void changeWorkspace(String workspaceName) {
    state = state.copyWith(
      activeWorkspace: workspaceName,
      messages: const [],
    );
    _loadHistory();
  }

  /// First ~5 words of the message, cleaned, max 34 chars.
  static String _titleFromText(String text) {
    final words = text
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .split(' ')
        .where((w) => w.isNotEmpty)
        .take(5)
        .join(' ');
    final t = words.length > 34 ? '${words.substring(0, 31)}…' : words;
    if (t.isEmpty) return '';
    return t[0].toUpperCase() + t.substring(1);
  }

  List<String> getWorkspaces() {
    final vault = _vaultCtrl.vault;
    if (vault == null) return const [];
    try {
      // v0.3.4: no more hardcoded demo sessions ("Q-L-U-E Sprint
      // Planning", "AWS API Gateway Config", …). New users see only
      // their real sessions. The active (possibly still-unsaved)
      // session is included so the sidebar can highlight it.
      final list = vault
          .getWorkspaces()
          .where((w) => !w.startsWith('__'))
          .toList();
      if (!list.contains('General')) list.add('General');
      if (!list.contains(state.activeWorkspace)) {
        list.insert(0, state.activeWorkspace);
      }
      return list;
    } catch (_) {
      return [state.activeWorkspace, if (state.activeWorkspace != 'General') 'General'];
    }
  }

  String _formatPrompt(
    String modelId,
    List<ChatMessage> history,
    String currentText,
    String ragContext, {
    bool voiceMode = false,
  }) {
    // v0.4.0 — the 30-second wait for a spoken "hi" was CPU prompt
    // processing of the full system prompt + history. Voice mode uses
    // a ~10x smaller prompt; depth stays in chat where waiting is OK.
    const voiceInstruction =
        'You are T.I.M., a friendly, direct career mentor on a live '
        'voice call. Reply in 1-3 short conversational sentences. '
        'No lists, no formatting.';
    const systemInstruction =
        'You are T.I.M. (This Is Me), a direct, hyper-observant career and communication mentor running fully offline on the user\'s own PC.\n'
        'Core behavior:\n'
        '- Be concise, specific, and honest. Push back on weak reasoning, but never scold the user for how they opened the conversation.\n'
        '- If the user greets you (e.g. "hi"), greet them back in ONE short sentence and ask what they want to work on today. Do not lecture them about providing context.\n'
        '- You coach; you do not do the work for them. Guide them to fix their own code, answers, and communication.\n'
        '- If their memory profile is empty, mention Genesis Onboarding at most once, briefly, then work with whatever they give you.\n'
        '- Use the retrieved memory context when relevant; never invent facts about the user.\n'
        '- When you spot a real weakness, name it plainly and give one concrete improvement step.\n'
        '- End substantive answers (not greetings) with ONE focused follow-up question.\n'
        'Tone: professional, warm-but-firm, no emojis, no filler.';

    final instruction = voiceMode ? voiceInstruction : systemInstruction;
    final contextPart =
        ragContext.isNotEmpty ? 'Context:\n$ragContext\n' : '';

    final prompt = StringBuffer();

    if (modelId.contains('llama3')) {
      // Llama 3 format
      prompt.write('<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n'
          '$instruction\n$contextPart<|eot_id|>');
      for (final msg in history) {
        final role = msg.sender == MessageSender.user ? 'user' : 'assistant';
        prompt.write('<|start_header_id|>$role<|end_header_id|>\n\n'
            '${msg.text}<|eot_id|>');
      }
      prompt.write('<|start_header_id|>user<|end_header_id|>\n\n'
          '$currentText<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n');
    } else if (modelId.contains('phi3')) {
      // Phi 3 format
      prompt.write('<s><|system|>\n$instruction\n$contextPart<|end|>\n');
      for (final msg in history) {
        final role = msg.sender == MessageSender.user ? 'user' : 'assistant';
        prompt.write('<|$role|>\n${msg.text}<|end|>\n');
      }
      prompt.write('<|user|>\n$currentText<|end|>\n<|assistant|>\n');
    } else {
      // Qwen / ChatML format (default)
      prompt.write('<|im_start|>system\n$instruction\n$contextPart<|im_end|>\n');
      for (final msg in history) {
        final role = msg.sender == MessageSender.user ? 'user' : 'assistant';
        prompt.write('<|im_start|>$role\n${msg.text}<|im_end|>\n');
      }
      prompt.write('<|im_start|>user\n$currentText<|im_end|>\n<|im_start|>assistant\n');
    }

    return prompt.toString();
  }

  List<String> _getStopSequences(String modelId) {
    final common = ['user message:', 'user:', 't.i.m.:'];
    if (modelId.contains('llama3')) {
      return [...common, '<|eot_id|>', '<|start_header_id|>'];
    } else if (modelId.contains('phi3')) {
      return [...common, '<|end|>', '<|user|>', '<|assistant|>'];
    } else {
      // ChatML / Qwen
      return [...common, '<|im_end|>', '<|im_start|>'];
    }
  }

  void _onEvent(WsEvent e) {
    switch (e.type) {
      case WsEventType.ready:
        state = state.copyWith(connected: true);
      case WsEventType.closed:
        state = state.copyWith(connected: false, voice: VoiceState.idle);
      case WsEventType.vad:
        final s = e.payload['state'] as String?;
        if (s == 'speech_start') {
          state = state.copyWith(voice: VoiceState.listening);
          _audioPlayer.stop();
          _pcmBuffer.clear();
        } else if (s == 'end_of_utterance') {
          state = state.copyWith(voice: VoiceState.verifying);
        }
      case WsEventType.biometric:
        final ok = e.payload['verified'] as bool? ?? false;
        if (!ok) {
          state = state.copyWith(voice: VoiceState.idle);
          _addSystem('Non-owner voice — barge-in blocked.');
        }
      case WsEventType.transcription:
        final text = e.payload['text'] as String? ?? '';
        final sender = e.payload['sender'] as String? ?? 'user';
        if (text.isNotEmpty) {
          if (sender == 'user') {
            final userMsgId = DateTime.now().microsecondsSinceEpoch.toString();
            _addMessage(MessageSender.user, text, id: userMsgId, persist: false);
            if (ScreenWatcher.isTriggered(text)) {
              _triggerScreenWatch(text);
            } else {
              _runLlmForVoice(text);
            }
          } else {
            _addMessage(MessageSender.ai, text);
          }
        }
      case WsEventType.ttsChunk:
        // v0.3.8 — each chunk is one synthesized sentence. Play it as
        // soon as it arrives instead of buffering the entire reply
        // (which caused 15-25 s of dead silence before ANY audio).
        final pcm = e.payload['pcm'] as Uint8List?;
        if (pcm != null && pcm.isNotEmpty) {
          final wav = BytesBuilder()
            ..add(_createWavHeader(pcm.length ~/ 2, 16000, 1, 16))
            ..add(pcm);
          _ttsQueue.add(wav.toBytes());
          state = state.copyWith(voice: VoiceState.speaking);
          _drainTtsQueue();
        }
        if (e.payload['final'] == true && _ttsQueue.isEmpty && !_ttsPlaying) {
          state = state.copyWith(voice: VoiceState.idle);
        }
      case WsEventType.interrupt:
        _ttsQueue.clear();
        _ttsPlaying = false;
        _audioPlayer.stop();
        _pcmBuffer.clear();
        state = state.copyWith(voice: VoiceState.listening);
        _addSystem('AI interrupted by user voice.');
      case WsEventType.speechAnalytics:
        break;
      case WsEventType.screenVision:
        final text = e.payload['analysis'] as String? ?? '';
        if (text.isNotEmpty) {
          _addMessage(MessageSender.ai, 'Screen watch:\n$text');
        }
      case WsEventType.jobListings:
        break;
      case WsEventType.reflexion:
        final rule = e.payload['rule'] as String? ?? '';
        if (rule.isNotEmpty) {
          _addMessage(MessageSender.system, 'Reflexion rule learned: $rule');
        }
      case WsEventType.modelDownload:
        final id = e.payload['id'] as String? ?? 'model';
        final pct = e.payload['pct'] as int? ?? 0;
        final done = e.payload['done'] as bool? ?? false;
        const dlMsgId = 'voice-model-download';
        final txt = done
            ? 'Voice engine ready — all models installed.'
            : 'Downloading voice engine: $id — $pct%';
        final exists = state.messages.any((m) => m.id == dlMsgId);
        if (exists) {
          state = state.copyWith(
            messages: state.messages
                .map((m) => m.id == dlMsgId ? m.copyWith(text: txt) : m)
                .toList(),
          );
        } else {
          _addMessage(MessageSender.system, txt,
              id: dlMsgId, persist: false);
        }
      case WsEventType.error:
        state = state.copyWith(voice: VoiceState.idle);
    }
  }

  void _addMessage(
    MessageSender sender,
    String text, {
    List<FileChip> attachments = const [],
    String? id,
    bool persist = true,
  }) {
    final msgId = id ?? DateTime.now().microsecondsSinceEpoch.toString();
    final msg = ChatMessage(
      id: msgId,
      sender: sender,
      text: text,
      timestamp: DateTime.now(),
      attachments: attachments,
    );
    state = state.copyWith(messages: [...state.messages, msg]);

    // Persist to vault (fire-and-forget — non-blocking).
    if (persist && sender != MessageSender.system) {
      final vault = _vaultCtrl.vault;
      if (vault != null && text.isNotEmpty) {
        try {
          vault.insertChatMessage(
            id: msgId,
            sender: sender == MessageSender.user ? 'user' : 'ai',
            text: text,
            workspace: state.activeWorkspace,
          );
        } catch (e) {
          _log.warn('Chat message persist failed: $e');
        }
      }
    }
  }

  void _addSystem(String text) => _addMessage(MessageSender.system, text);

  void clearHistory() {
    state = state.copyWith(messages: const []);
  }

  void addSystem(String text) => _addSystem(text);

  /// Add a pending file chip to the input dock (drag-and-drop).
  void addFileChip(FileChip chip) {
    state = state.copyWith(
      pendingChips: [...state.pendingChips, chip],
    );
  }

  void removeFileChip(String id) {
    state = state.copyWith(
      pendingChips: state.pendingChips.where((c) => c.id != id).toList(),
    );
  }

  /// v0.3.4 — "look at my screen" now actually looks at the screen.
  /// Flow: native full-desktop capture (flutter_window.cpp, includes
  /// whatever window/tab the user is working in) → built-in Windows
  /// OCR extracts the readable text → the local LLM analyzes that
  /// text against the user's question. No stub replies.
  Future<void> _triggerScreenWatch([String userQuestion = '']) async {
    _addSystem('T.I.M. is reading your screen…');
    try {
      const channel = MethodChannel('tim.screen/capture');
      final png = await channel.invokeMethod<Uint8List>('capture');
      if (png == null) {
        throw PlatformException(
            code: 'CAPTURE_FAILED', message: 'No image returned');
      }
      final screenText = await WindowsOcr.extractText(png);
      if (screenText == null || screenText.trim().length < 10) {
        _addSystem('I captured the screen but could not read any text '
            'from it (Windows OCR unavailable or the screen is mostly '
            'visual). A pixel-level vision model is on the roadmap.');
        return;
      }
      // Keep the prompt within budget: screens can OCR to thousands
      // of words; keep the most recent ~4000 chars (bottom of screen
      // usually holds the active content).
      final clipped = screenText.length > 4000
          ? screenText.substring(screenText.length - 4000)
          : screenText;
      final question = userQuestion.trim().isEmpty
          ? 'Describe what I am working on and point out anything '
              'that looks wrong or could be improved.'
          : userQuestion;
      final analysisRequest =
          'I captured the text visible on my screen with OCR. Here it is:\n'
          '--- SCREEN TEXT START ---\n$clipped\n--- SCREEN TEXT END ---\n\n'
          'My question about this screen: $question\n'
          'Note: OCR may contain small recognition errors; ignore obvious '
          'artifacts. Analyze the content, do not repeat it back.';
      _runLlmForVoice(analysisRequest);
    } catch (e) {
      _addSystem('Screen capture failed: $e');
    }
  }

  /// Local text-send path (when not using voice).
  void sendText(String text) async {
    if (text.trim().isEmpty && state.pendingChips.isEmpty) return;
    // Don't allow sending while already generating (sync guard closes
    // the double-Enter race; state flag covers everything else).
    if (_sendBusy || state.isGenerating) return;

    // Screen-share trigger ("look at my screen", "can you see my
    // screen", …) — previously this text went straight to a blind LLM
    // which replied confused. Now it routes to capture + OCR + analysis.
    if (ScreenWatcher.isTriggered(text)) {
      final userMsgId = DateTime.now().microsecondsSinceEpoch.toString();
      _addMessage(MessageSender.user, text, id: userMsgId, persist: false);
      _triggerScreenWatch(text);
      return;
    }
    _sendBusy = true;

    final attachments = state.pendingChips;
    final userMsgId = DateTime.now().microsecondsSinceEpoch.toString();
    // Decouple SQLite write from sending: user message added to UI state immediately, but written to DB later.
    _addMessage(MessageSender.user, text, attachments: attachments, id: userMsgId, persist: false);
    state = state.copyWith(pendingChips: const []);

    if (!_llm.isLoaded) {
      _addSystem('Local model not loaded. Please download/load a model from the top bar.');
      _sendBusy = false;
      return;
    }

    // ── RAG: use fast hash embedder (non-blocking, no model call) ──
    String ragContext = '';
    final vault = _vaultCtrl.vault;
    if (vault != null) {
      try {
        final queryEmb = LlmEngine.hashEmbed(text);
        final memories = await vault.semanticSearch(queryEmb, workspace: state.activeWorkspace, k: 3);
        if (memories.isNotEmpty) {
          ragContext = memories.map((m) => '- ${m.content}').join('\n');
        }
      } catch (e) {
        _log.warn('RAG context fetch failed: $e');
      }
    }
    // v0.3.9 — Copilot-style sharing: fold in the current screen text.
    ragContext += await _screenContextIfSharing();

    // Extract last 8 messages for context window prompt history
    final history = state.messages
        .where((m) =>
            m.id != userMsgId &&
            m.sender != MessageSender.system &&
            m.text.isNotEmpty,)
        .toList();
    final recentHistory = history.length > 8
        ? history.sublist(history.length - 8)
        : history;

    final modelState = _ref.read(modelProvider);
    final modelId = modelState.selected?.id ?? 'qwen25-3b';
    final formattedPrompt = _formatPrompt(
      modelId,
      recentHistory,
      text,
      ragContext,
    );
    final stopSeqs = _getStopSequences(modelId);

    final aiMsgId = DateTime.now().microsecondsSinceEpoch.toString();
    var responseText = '';
    _cancelRequested = false;
    _tokensSinceUpdate = 0;

    final initialAiMsg = ChatMessage(
      id: aiMsgId,
      sender: MessageSender.ai,
      text: '',
      timestamp: DateTime.now(),
    );
    state = state.copyWith(
      messages: [...state.messages, initialAiMsg],
      isGenerating: true,
      streamingMessageId: aiMsgId,
    );

    try {
      await for (final token in _llm.generate(
        formattedPrompt,
        stop: stopSeqs,
        // Higher token budget for richer answers; stop seqs handle early exit.
        maxTokens: 800,
        temperature: 0.65,
      )) {
        if (_cancelRequested) break;
        responseText += token;
        _tokensSinceUpdate++;

        // Clean stop sequences from the accumulated text.
        var cleanText = responseText;
        for (final seq in stopSeqs) {
          final idx = cleanText.toLowerCase().indexOf(seq.toLowerCase());
          if (idx != -1) cleanText = cleanText.substring(0, idx);
        }

        // ── Update UI on every token for smooth streaming ────────
        if (_tokensSinceUpdate >= _uiUpdateEveryN) {
          _tokensSinceUpdate = 0;
          state = state.copyWith(
            messages: state.messages.map((m) {
              if (m.id == aiMsgId) {
                return ChatMessage(
                  id: aiMsgId,
                  sender: MessageSender.ai,
                  text: cleanText,
                  timestamp: m.timestamp,
                );
              }
              return m;
            }).toList(),
          );
        }
      }

      // Final UI flush (in case last batch < _uiUpdateEveryN tokens).
      var finalText = _stripSpecialTokens(responseText);
      for (final seq in stopSeqs) {
        final idx = finalText.toLowerCase().indexOf(seq.toLowerCase());
        if (idx != -1) finalText = finalText.substring(0, idx);
      }
      state = state.copyWith(
        messages: state.messages.map((m) {
          if (m.id == aiMsgId) {
            return ChatMessage(
              id: aiMsgId,
              sender: MessageSender.ai,
              text: finalText.trim(),
              timestamp: m.timestamp,
            );
          }
          return m;
        }).toList(),
      );

      // ── Decoupled DB write: Persist user & AI messages safely after stream concludes ──
      final finalReply = finalText.trim();
      if (vault != null) {
        try {
          if (text.isNotEmpty) {
            vault.insertChatMessage(
              id: userMsgId,
              sender: 'user',
              text: text,
              workspace: state.activeWorkspace,
            );
          }
          if (finalReply.isNotEmpty) {
            vault.insertChatMessage(
              id: aiMsgId,
              sender: 'ai',
              text: finalReply,
              workspace: state.activeWorkspace,
            );
          }
        } catch (dbErr) {
          _log.error('CRITICAL: Failed to save to local memory (chat message persist failed): $dbErr');
        }

        // Memory insertion is slow (embedding) — run in background.
        if (!_cancelRequested && finalReply.isNotEmpty) {
          unawaited(_insertMemoriesBackground(text, finalReply, vault));
        }

        // v0.3.4 auto-title: an unnamed session takes its title from
        // the first message ("based on the question it needs to
        // summarize and add a title to the session").
        if (state.activeWorkspace == 'New Chat' ||
            state.activeWorkspace.startsWith('New Chat ')) {
          final title = _titleFromText(text);
          if (title.isNotEmpty && title != state.activeWorkspace) {
            try {
              vault.renameWorkspace(state.activeWorkspace, title);
              state = state.copyWith(activeWorkspace: title);
            } catch (e) {
              _log.warn('Session auto-title failed: $e');
            }
          }
        }
      }
    } catch (e) {
      _log.error('LLM generation error', e);
      final errText = responseText.isEmpty ? '[Generation failed: $e]' : responseText.trim();
      state = state.copyWith(
        messages: state.messages.map((m) {
          if (m.id == aiMsgId) {
            return ChatMessage(
              id: aiMsgId,
              sender: MessageSender.ai,
              text: errText,
              timestamp: m.timestamp,
            );
          }
          return m;
        }).toList(),
      );

      // Decoupled DB write on error
      if (vault != null) {
        try {
          if (text.isNotEmpty) {
            vault.insertChatMessage(
              id: userMsgId,
              sender: 'user',
              text: text,
              workspace: state.activeWorkspace,
            );
          }
          vault.insertChatMessage(
            id: aiMsgId,
            sender: 'ai',
            text: errText,
            workspace: state.activeWorkspace,
          );
        } catch (dbErr) {
          _log.error('CRITICAL: Failed to save to local memory on generation error: $dbErr');
        }
      }
    } finally {
      _sendBusy = false;
      state = state.copyWith(
        isGenerating: false,
        streamingMessageId: null,
      );
    }
  }

  List<String> _chunkText(String text, {int maxChunkSize = 500}) {
    if (text.length <= maxChunkSize) return [text];
    final chunks = <String>[];
    final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));
    var currentChunk = StringBuffer();
    for (final sentence in sentences) {
      if (currentChunk.length + sentence.length > maxChunkSize) {
        if (currentChunk.isNotEmpty) {
          chunks.add(currentChunk.toString().trim());
          currentChunk = StringBuffer();
        }
        if (sentence.length > maxChunkSize) {
          var start = 0;
          while (start < sentence.length) {
            final end = (start + maxChunkSize).clamp(0, sentence.length);
            chunks.add(sentence.substring(start, end).trim());
            start = end;
          }
        } else {
          currentChunk.write('$sentence ');
        }
      } else {
        currentChunk.write('$sentence ');
      }
    }
    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk.toString().trim());
    }
    return chunks;
  }

  /// Insert RAG memories in the background using the fast hash embedder
  /// so it doesn't block the UI or the next message send.
  Future<void> _insertMemoriesBackground(
    String userText,
    String aiText,
    dynamic vault,
  ) async {
    try {
      final currentWorkspace = state.activeWorkspace;
      // Chunk user text
      final userChunks = _chunkText(userText);
      for (final chunk in userChunks) {
        final userEmb = LlmEngine.hashEmbed(chunk);
        await vault.insertMemory(
          content: 'User said: $chunk',
          embedding: userEmb,
          metadata: {'sender': 'user', 'workspace': currentWorkspace},
        );
      }

      // Chunk AI text
      final aiChunks = _chunkText(aiText);
      for (final chunk in aiChunks) {
        final aiEmb = LlmEngine.hashEmbed(chunk);
        await vault.insertMemory(
          content: 'T.I.M. said: $chunk',
          embedding: aiEmb,
          metadata: {'sender': 'ai', 'workspace': currentWorkspace},
        );
      }
    } catch (e) {
      _log.warn('Background memory insertion failed: $e');
    }
  }

  @override
  void dispose() {
    _sub.cancel();
    _audioPlayer.dispose();
    super.dispose();
  }
}

final chatProvider =
    StateNotifierProvider<ChatNotifier, ChatState>((ref) {
  final ws = ref.watch(webSocketProvider);
  final llm = ref.watch(llmEngineProvider);
  final vaultCtrl = ref.watch(vaultProvider.notifier);
  return ChatNotifier(ws, llm, vaultCtrl, ref);
});
