// ============================================================
// lib/presentation/providers/chat_provider.dart
// Chat state. Listens to [WebSocketService] for VAD / biometric /
// transcription events and forwards a unified chat-message stream
// to the UI.
// ============================================================

import 'dart:async';

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
  });

  final List<ChatMessage> messages;
  final VoiceState voice;
  final bool connected;
  final List<FileChip> pendingChips;
  /// True while the LLM is streaming tokens.
  final bool isGenerating;
  /// The id of the message currently being streamed (if any).
  final String? streamingMessageId;

  ChatState copyWith({
    List<ChatMessage>? messages,
    VoiceState? voice,
    bool? connected,
    List<FileChip>? pendingChips,
    bool? isGenerating,
    Object? streamingMessageId = _sentinel,
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

  /// Update UI on every token for maximum perceived speed.
  static const int _uiUpdateEveryN = 1;
  int _tokensSinceUpdate = 0;

  /// Set to true when the user presses Stop to cancel an in-flight generation.
  bool _cancelRequested = false;

  /// Called by the UI Stop button to abort streaming.
  void stopGeneration() {
    _cancelRequested = true;
    _llm.cancelGeneration();
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
      final rows = vault.loadChatHistory(limit: 100);
      if (rows.isEmpty) return;
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

  String _formatPrompt(String modelId, String text, String ragContext) {
    const systemInstruction =
        'You are T.I.M. (This Is Me), a 100% offline, localized career mentor. '
        'You run completely in-memory on the user\'s machine. Keep answers concise and direct. Push the user to grow. '
        'Answer ONLY what was asked — do not simulate future dialogue. '
        'If the user\'s memory profile is empty, do not say you don\'t have access to information. '
        'Instead, warmly guide them to complete the "Genesis Onboarding" so you can learn their story.';

    final contextPart =
        ragContext.isNotEmpty ? 'Context:\n$ragContext\n' : '';

    if (modelId.contains('llama3')) {
      return '<|begin_of_text|><|start_header_id|>system<|end_header_id|>\n\n'
          '$systemInstruction\n$contextPart<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n'
          '$text<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n';
    } else if (modelId.contains('phi3')) {
      return '<s><|system|>\n$systemInstruction\n$contextPart<|end|>\n'
          '<|user|>\n$text<|end|>\n<|assistant|>\n';
    } else {
      // Qwen / ChatML format (default)
      return '<|im_start|>system\n$systemInstruction\n$contextPart<|im_end|>\n'
          '<|im_start|>user\n$text<|im_end|>\n<|im_start|>assistant\n';
    }
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
        if (text.isNotEmpty) {
          _addMessage(MessageSender.user, text);
          if (ScreenWatcher.isTriggered(text)) {
            _triggerScreenWatch();
          }
        }
        state = state.copyWith(voice: VoiceState.speaking);
      case WsEventType.ttsChunk:
        if (e.payload['final'] == true) {
          state = state.copyWith(voice: VoiceState.idle);
        }
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
    if (sender != MessageSender.system) {
      final vault = _vaultCtrl.vault;
      if (vault != null && text.isNotEmpty) {
        try {
          vault.insertChatMessage(
            id: msgId,
            sender: sender == MessageSender.user ? 'user' : 'ai',
            text: text,
          );
        } catch (e) {
          _log.warn('Chat message persist failed: $e');
        }
      }
    }
  }

  void _addSystem(String text) => _addMessage(MessageSender.system, text);

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
    _addMessage(MessageSender.user, text, attachments: attachments, id: userMsgId);
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
        final memories = await vault.semanticSearch(queryEmb, k: 3);
        if (memories.isNotEmpty) {
          ragContext = memories.map((m) => '- ${m.content}').join('\n');
        }
      } catch (e) {
        _log.warn('RAG context fetch failed: $e');
      }
    }

    final modelState = _ref.read(modelProvider);
    final modelId = modelState.selected?.id ?? 'qwen25-3b';
    final formattedPrompt = _formatPrompt(modelId, text, ragContext);
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

      // ── Persist AI reply & background memory insertion ─────────
      final finalReply = finalText.trim();
      if (finalReply.isNotEmpty && vault != null) {
        // Persist the chat message record synchronously (cheap SQL write).
        try {
          vault.insertChatMessage(
            id: aiMsgId,
            sender: 'ai',
            text: finalReply,
          );
        } catch (e) {
          _log.warn('AI message persist failed: $e');
        }

        // Memory insertion is slow (embedding) — run in background.
        if (!_cancelRequested) {
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
    } finally {
      state = state.copyWith(
        isGenerating: false,
        streamingMessageId: null,
      );
    }
  }

  /// Insert RAG memories in the background using the fast hash embedder
  /// so it doesn't block the UI or the next message send.
  Future<void> _insertMemoriesBackground(
    String userText,
    String aiText,
    dynamic vault,
  ) async {
    try {
      // Use fast hash embedder — no model inference call needed here.
      final userEmb = LlmEngine.hashEmbed(userText);
      await vault.insertMemory(
        content: 'User said: $userText',
        embedding: userEmb,
        metadata: {'sender': 'user'},
      );
      final aiEmb = LlmEngine.hashEmbed(aiText);
      await vault.insertMemory(
        content: 'T.I.M. said: $aiText',
        embedding: aiEmb,
        metadata: {'sender': 'ai'},
      );
    } catch (e) {
      _log.warn('Background memory insertion failed: $e');
    }
  }

  @override
  void dispose() {
    _sub.cancel();
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
