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
  });

  final List<ChatMessage> messages;
  final VoiceState voice;
  final bool connected;
  final List<FileChip> pendingChips;

  ChatState copyWith({
    List<ChatMessage>? messages,
    VoiceState? voice,
    bool? connected,
    List<FileChip>? pendingChips,
  }) =>
      ChatState(
        messages: messages ?? this.messages,
        voice: voice ?? this.voice,
        connected: connected ?? this.connected,
        pendingChips: pendingChips ?? this.pendingChips,
      );
}

/// Single shared [WebSocketService] instance.
final webSocketProvider = Provider<WebSocketService>((ref) {
  final ws = WebSocketService();
  ref.onDispose(ws.dispose);
  return ws;
});

class ChatNotifier extends StateNotifier<ChatState> {
  ChatNotifier(this._ws, this._llm, this._vaultCtrl) : super(const ChatState()) {
    _ws.connect();
    _sub = _ws.events.listen(_onEvent);
  }

  final WebSocketService _ws;
  final LlmEngine _llm;
  final VaultController _vaultCtrl;
  late final StreamSubscription<WsEvent> _sub;
  final Logger _log = Logger('ChatNotifier');

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
        // Handled by voice_provider; ignored here.
        break;
      case WsEventType.screenVision:
        final text = e.payload['analysis'] as String? ?? '';
        if (text.isNotEmpty) {
          _addMessage(MessageSender.ai, 'Screen watch:\n$text');
        }
      case WsEventType.jobListings:
        // Forwarded to the job-scraper UI; ignored in the chat stream.
        break;
      case WsEventType.reflexion:
        final rule = e.payload['rule'] as String? ?? '';
        if (rule.isNotEmpty) {
          _addMessage(MessageSender.system, 'Reflexion rule learned: $rule');
        }
      case WsEventType.error:
        _addSystem('Error: ${e.payload['message']}');
        state = state.copyWith(voice: VoiceState.idle);
    }
  }

  void _addMessage(
    MessageSender sender,
    String text, {
    List<FileChip> attachments = const [],
  }) {
    final msg = ChatMessage(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      sender: sender,
      text: text,
      timestamp: DateTime.now(),
      attachments: attachments,
    );
    state = state.copyWith(messages: [...state.messages, msg]);
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
    final attachments = state.pendingChips;
    _addMessage(MessageSender.user, text, attachments: attachments);
    state = state.copyWith(pendingChips: const []);

    if (!_llm.isLoaded) {
      _addSystem('Local model not loaded. Please download/load a model from the top bar.');
      return;
    }

    String ragContext = '';
    final vault = _vaultCtrl.vault;
    if (vault != null) {
      try {
        final queryEmb = await _llm.embed(text);
        final memories = await vault.semanticSearch(queryEmb, k: 3);
        if (memories.isNotEmpty) {
          ragContext = memories.map((m) => '- ${m.content}').join('\n');
        }
      } catch (e) {
        _log.warn('RAG context fetch failed: $e');
      }
    }

    final systemPrompt = '''
You are T.I.M. (This Is Me), a personalized career mentor.
You learn exclusively from the user. Be direct, force them to confront their flaws, and correct their communication.

${ragContext.isNotEmpty ? 'Relevant context from memory:\n$ragContext\n' : ''}
User message: $text
T.I.M.:''';

    final aiMsgId = DateTime.now().microsecondsSinceEpoch.toString();
    var responseText = '';
    
    final initialAiMsg = ChatMessage(
      id: aiMsgId,
      sender: MessageSender.ai,
      text: '',
      timestamp: DateTime.now(),
    );
    state = state.copyWith(messages: [...state.messages, initialAiMsg]);

    try {
      await for (final token in _llm.generate(systemPrompt)) {
        responseText += token;
        state = state.copyWith(
          messages: state.messages.map((m) {
            if (m.id == aiMsgId) {
              return ChatMessage(
                id: aiMsgId,
                sender: MessageSender.ai,
                text: responseText,
                timestamp: m.timestamp,
              );
            }
            return m;
          }).toList(),
        );
      }
      
      if (vault != null) {
        final userEmb = await _llm.embed(text);
        await vault.insertMemory(
          content: 'User said: $text',
          embedding: userEmb,
          metadata: {'sender': 'user'},
        );
        final aiEmb = await _llm.embed(responseText);
        await vault.insertMemory(
          content: 'T.I.M. said: $responseText',
          embedding: aiEmb,
          metadata: {'sender': 'ai'},
        );
      }
    } catch (e) {
      _log.error('LLM generation error', e);
      state = state.copyWith(
        messages: state.messages.map((m) {
          if (m.id == aiMsgId) {
            return ChatMessage(
              id: aiMsgId,
              sender: MessageSender.ai,
              text: '$responseText\n[Generation error: $e]',
              timestamp: m.timestamp,
            );
          }
          return m;
        }).toList(),
      );
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
  return ChatNotifier(ws, llm, vaultCtrl);
});
