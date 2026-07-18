// ============================================================
// lib/data/services/worker_events.dart
// Shared event contract between the voice/vision worker and the UI.
//
// Path B migration note: these types used to live inside
// websocket_service.dart. They are transport-agnostic, so they now
// live here and are consumed by the fully-native NativeWorker.
// The names are kept identical (WsEvent / WsEventType) so existing
// providers/widgets compile unchanged.
// ============================================================

/// Discriminator for events emitted by the worker pipeline.
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
  interrupt,
}

class WsEvent {
  WsEvent(this.type, this.payload);
  final WsEventType type;
  final Map<String, dynamic> payload;
}
