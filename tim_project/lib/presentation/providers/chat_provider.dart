// ============================================================
// lib/presentation/providers/chat_provider.dart
// Chat state. Listens to [WebSocketService] for VAD / biometric /
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
import '../../data/services/websocket_service.dart';
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

/// Single shared [WebSocketService] instance.
final webSocketProvider = Provider<WebSocketService>((ref) {
  final ws = WebSocketService();
  ref.onDispose(ws.dispose);
  return ws;
});

class ChatNotifier extends StateNotifier<ChatState> {
  ChatNotifier(this._ws, this._llm, this._vaultCtrl, this._ref)
      : super(const ChatState()) {
    _ws.connect();
    _sub = _ws.events.listen(_onEvent);
    // Load persisted chat history from the vault once it's unlocked.
    _loadHistory();
  }

  final WebSocketService _ws;
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

  /// Called by the UI Stop button to abort streaming.
  void stopGeneration() {
    _cancelRequested = true;
    _llm.cancelGeneration();
    _audioPlayer.stop();
  }

  void _runLlmForVoice(String text) async {
    // Re-use logic from sendText to query local LLM
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
        _log.warn('RAG search failed: $e');
      }
    }
    final modelId = _ref.read(modelProvider).selected?.id ?? '';
    final stopSeqs = _getStopSequences(modelId);
    final prompt = _formatPrompt(modelId, state.messages, text, ragContext);

    final aiMsgId = DateTime.now().microsecondsSinceEpoch.toString();
    // Pre-add empty message for streaming response in UI
    _addMessage(MessageSender.ai, '', id: aiMsgId, persist: false);
    state = state.copyWith(isGenerating: true, streamingMessageId: aiMsgId);

    var response = '';
    try {
      await for (final token in _llm.generate(prompt, stop: stopSeqs)) {
        response += token;
        // update UI
        state = state.copyWith(
          messages: state.messages.map((m) => m.id == aiMsgId ? m.copyWith(text: response) : m).toList(),
        );
      }
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
      
      // Now request TTS from the Python worker!
      _ws.sendJson({
        'type': 'tts_request',
        'text': response,
      });
    } catch (e) {
      _addSystem('AI reply generation failed: $e');
    } finally {
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

  List<String> getWorkspaces() {
    final vault = _vaultCtrl.vault;
    if (vault == null) return const [];
    try {
      final list = vault.getWorkspaces();
      final defaults = ['Q-L-U-E Sprint Planning', 'Behavioral Mock Interview', 'AWS API Gateway Config', 'General'];
      for (final def in defaults) {
        if (!list.contains(def)) {
          list.add(def);
        }
      }
      return list;
    } catch (_) {
      return ['Q-L-U-E Sprint Planning', 'Behavioral Mock Interview', 'AWS API Gateway Config', 'General'];
    }
  }

  String _formatPrompt(
    String modelId,
    List<ChatMessage> history,
    String currentText,
    String ragContext,
  ) {
    const systemInstruction =
        'Context: You are T.I.M. (This Is Me), a blunt, hyper-observant career and behavioral mentor running locally on a secure Windows system.\n'
        'Request: Analyze the user\'s input, cross-reference their encrypted timeline, and provide brutal, constructive feedback.\n'
        'Explanation: You do not write code for the user. You do not validate excuses. Your goal is to force the user to confront logical flaws and communication gaps. '
        'If the user\'s memory profile/timeline is empty, guide them to complete the "Genesis Onboarding" so you can learn their story.\n'
        'Action: Respond with direct, concise critiques. If the user makes a mistake, log a high-priority rule for future sessions.\n'
        'Tone: Demanding, analytical, and strictly professional. No pleasantries. No emojis.\n'
        'Extras: Always end by asking a probing question that forces the user to defend their reasoning.';

    final contextPart =
        ragContext.isNotEmpty ? 'Context:\n$ragContext\n' : '';

    final prompt = StringBuffer();

    if (modelId.contains('llama3')) {
      // Llama 3 format
      prompt.write('<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n'
          '$systemInstruction\n$contextPart<|eot_id|>');
      for (final msg in history) {
        final role = msg.sender == MessageSender.user ? 'user' : 'assistant';
        prompt.write('<|start_header_id|>$role<|end_header_id|>\n\n'
            '${msg.text}<|eot_id|>');
      }
      prompt.write('<|start_header_id|>user<|end_header_id|>\n\n'
          '$currentText<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n');
    } else if (modelId.contains('phi3')) {
      // Phi 3 format
      prompt.write('<s><|system|>\n$systemInstruction\n$contextPart<|end|>\n');
      for (final msg in history) {
        final role = msg.sender == MessageSender.user ? 'user' : 'assistant';
        prompt.write('<|$role|>\n${msg.text}<|end|>\n');
      }
      prompt.write('<|user|>\n$currentText<|end|>\n<|assistant|>\n');
    } else {
      // Qwen / ChatML format (default)
      prompt.write('<|im_start|>system\n$systemInstruction\n$contextPart<|im_end|>\n');
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
              _triggerScreenWatch();
            }
            _runLlmForVoice(text);
          } else {
            _addMessage(MessageSender.ai, text);
          }
        }
      case WsEventType.ttsChunk:
        final pcm = e.payload['pcm'] as Uint8List?;
        if (pcm != null && pcm.isNotEmpty) {
          _pcmBuffer.addAll(pcm);
        }
        if (e.payload['final'] == true) {
          state = state.copyWith(voice: VoiceState.idle);
          if (_pcmBuffer.isNotEmpty) {
            _audioPlayer.stop().then((_) {
              final builder = BytesBuilder()
                ..add(_createWavHeader(_pcmBuffer.length ~/ 2, 16000, 1, 16))
                ..add(_pcmBuffer);
              _audioPlayer.play(BytesSource(builder.toBytes()));
              _pcmBuffer.clear();
            });
          }
        }
      case WsEventType.interrupt:
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

  Future<void> _triggerScreenWatch() async {
    _addSystem('T.I.M. is scanning your screen...');
    try {
      final watcher = ScreenWatcher(_ws);
      await watcher.captureAndAnalyse(
        capture: () async {
          const channel = MethodChannel('tim.screen/capture');
          final png = await channel.invokeMethod<Uint8List>('capture');
          if (png == null) {
            throw PlatformException(
              code: 'CAPTURE_FAILED',
              message: 'No image returned',
            );
          }
          return png;
        },
      );
    } catch (e) {
      _addSystem('Screen capture failed: $e');
    }
  }

  /// Local text-send path (when not using voice).
  void sendText(String text) async {
    if (text.trim().isEmpty && state.pendingChips.isEmpty) return;
    // Don't allow sending while already generating.
    if (state.isGenerating) return;

    final attachments = state.pendingChips;
    final userMsgId = DateTime.now().microsecondsSinceEpoch.toString();
    // Decouple SQLite write from sending: user message added to UI state immediately, but written to DB later.
    _addMessage(MessageSender.user, text, attachments: attachments, id: userMsgId, persist: false);
    state = state.copyWith(pendingChips: const []);

    if (!_llm.isLoaded) {
      _addSystem('Local model not loaded. Please download/load a model from the top bar.');
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
      var finalText = responseText;
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
