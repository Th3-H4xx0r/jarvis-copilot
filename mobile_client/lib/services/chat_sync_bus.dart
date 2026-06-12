import 'dart:async';

/// App-wide signal that a chat session changed (a turn was added) somewhere
/// OTHER than the chat screen — e.g. a voice conversation persisted a turn.
///
/// The chat screen owns its own [ChatController] (created per page, kept alive
/// in the NavShell IndexedStack) and has no other way to learn that the voice
/// controller just wrote to a session. It subscribes here and refreshes the
/// sessions list (and the open thread, if it's the one that changed) so the new
/// turn shows up live instead of only after a manual reload.
class ChatSyncBus {
  ChatSyncBus._();
  static final ChatSyncBus instance = ChatSyncBus._();

  final StreamController<String?> _ctrl = StreamController<String?>.broadcast();

  /// Fires with the affected session id (or null when unknown — list-only
  /// refresh). Listeners must tolerate bursts and unknown ids.
  Stream<String?> get onChanged => _ctrl.stream;

  /// Announce that [sessionId] gained a turn (or any session changed when null).
  void sessionChanged([String? sessionId]) {
    if (!_ctrl.isClosed) _ctrl.add(sessionId);
  }
}
