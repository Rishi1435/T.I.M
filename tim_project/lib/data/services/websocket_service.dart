// ============================================================
// lib/data/services/websocket_service.dart
// Persistent WebSocket client that bridges the Flutter UI to the
// local Python worker (backend/audio_server.py). Emits typed events
// that Riverpod providers consume.
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import '../../core/config/app_config.dart';
import '../../core/utils/logger.dart';

/// Discriminator for events emitted by [WebSocketService].
enum WsEventType {
  ready,
  vad,
  biometric,
  transcription,
  ttsChunk,
  speechAnalytics,
  screenVision,
  jobListings,
  reflexion,
  error,
  closed,
}

class WsEvent {
  WsEvent(this.type, this.payload);
  final WsEventType type;
  final Map<String, dynamic> payload;
}

class WebSocketService {
  WebSocketService() : _log = Logger('WebSocketService');

  final Logger _log;
  WebSocketChannel? _channel;
  StreamController<WsEvent>? _controller;
  bool _disposed = false;
  int _reconnectBackoffSec = 1;

  /// Broadcast stream of typed events.
  Stream<WsEvent> get events =>
      (_controller ??= StreamController<WsEvent>.broadcast()).stream;

  /// Connect to the local Python worker.
  Future<void> connect() async {
    if (_channel != null) return;
    _log.info('Connecting to ${AppConfig.wsUrl}');
    final uri = Uri.parse(AppConfig.wsUrl);
    _channel = WebSocketChannel.connect(uri);

    _channel!.stream.listen(
      (data) {
        if (data is String) {
          final obj = jsonDecode(data) as Map<String, dynamic>;
          final type = _parseType(obj['type'] as String?);
          _controller?.add(WsEvent(type, obj));
        } else if (data is List<int>) {
          // Binary PCM frames (TTS playback).
          _controller?.add(
            WsEvent(
              WsEventType.ttsChunk,
              {
                'pcm': Uint8List.fromList(data),
                'final': false,
              },
            ),
          );
        }
      },
      onError: (Object? e, StackTrace s) {
        _log.error('WS error', e, s);
        _controller?.add(WsEvent(WsEventType.error, {'message': '$e'}));
      },
      onDone: () {
        _log.info('WS closed');
        _controller?.add(WsEvent(WsEventType.closed, {}));
        _channel = null;
        if (!_disposed) {
          Future.delayed(Duration(seconds: _reconnectBackoffSec), () {
            _reconnectBackoffSec =
                (_reconnectBackoffSec * 2).clamp(1, 8);
            connect();
          });
        }
      },
    );
    _reconnectBackoffSec = 1;
  }

  /// Send raw PCM (16-bit LE, 16kHz mono) to the audio worker.
  void sendAudio(Uint8List pcm) => _channel?.sink.add(pcm);

  /// Send a JSON control message.
  void sendJson(Map<String, dynamic> obj) =>
      _channel?.sink.add(jsonEncode(obj));

  WsEventType _parseType(String? t) {
    switch (t) {
      case 'ready':
        return WsEventType.ready;
      case 'vad':
        return WsEventType.vad;
      case 'biometric':
        return WsEventType.biometric;
      case 'transcription':
        return WsEventType.transcription;
      case 'tts_chunk':
        return WsEventType.ttsChunk;
      case 'speech_analytics':
        return WsEventType.speechAnalytics;
      case 'screen_vision':
        return WsEventType.screenVision;
      case 'job_listings':
        return WsEventType.jobListings;
      case 'reflexion':
        return WsEventType.reflexion;
      case 'error':
        return WsEventType.error;
      default:
        return WsEventType.error;
    }
  }

  void dispose() {
    _disposed = true;
    _channel?.sink.close();
    _controller?.close();
  }
}
