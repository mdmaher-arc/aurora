import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'backoff.dart';
import 'live_messages.dart';
import 'protocol_constants.dart';
import 'server_message.dart';

/// Why a connection ended.
enum LiveConnectionState {
  idle,
  connecting,
  ready,
  reconnecting,
  closed,
  failed,
}

/// Owns the WebSocket to the Gemini Live API.
///
/// Kept separate from the UI so it can be tested without a widget tree.
///  * opens the socket and sends `setup` exactly once per connection
///  * decodes every server frame into [ServerMessage]
///  * tracks the resumption handle across the ~10 minute connection limit
///  * reconnects with backoff when the server drops us
class LiveClient {
  LiveClient({WebSocketChannel Function(Uri uri)? connector})
      : _connector = connector ?? WebSocketChannel.connect;

  final WebSocketChannel Function(Uri uri) _connector;
  final Backoff _backoff = Backoff();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _reconnectTimer;

  /// Decoded server frames, broadcast to listeners.
  final StreamController<ServerMessage> _messages =
      StreamController<ServerMessage>.broadcast();

  /// Connection state changes.
  final StreamController<LiveConnectionState> _states =
      StreamController<LiveConnectionState>.broadcast();

  final Completer<void> _readyCompleter = Completer<void>();

  LiveSessionConfig? _config;
  LiveConnectionState _state = LiveConnectionState.idle;

  String _apiKey = '';
  String _resumeHandle = '';
  bool _closedByUser = false;
  bool _setupAcknowledged = false;

  Stream<ServerMessage> get messages => _messages.stream;
  Stream<LiveConnectionState> get states => _states.stream;
  LiveConnectionState get state => _state;

  /// Latest handle for resuming context. Valid for 2 hours.
  String get resumeHandle => _resumeHandle;

  /// True once the server has accepted the setup frame.
  bool get isReady => _setupAcknowledged;

  /// Builds the endpoint.
  ///
  /// A standard API key goes in `key=`; an ephemeral token goes in
  /// `access_token=`. Tokens only work on v1beta.
  Uri buildUri(String apiKey) {
    final bool isEphemeral = apiKey.startsWith('tokens/');
    return Uri(scheme: 'wss', host: kLiveHost, path: kLivePath).replace(
      queryParameters: <String, String>{
        if (isEphemeral) 'access_token': apiKey else 'key': apiKey,
      },
    );
  }

  /// Opens the socket and sends the setup frame.
  Future<void> connect({
    required String apiKey,
    required LiveSessionConfig config,
  }) async {
    _apiKey = apiKey;
    _config = config;
    final String? handle = config.resumeHandle;
    if (handle != null && handle.isNotEmpty) _resumeHandle = handle;
    _closedByUser = false;
    _setupAcknowledged = false;
    await _openSocket(isReconnect: false);
  }
Future<void> _openSocket({required bool isReconnect}) async {
    _teardownSocket();
    _setState(
      isReconnect ? LiveConnectionState.reconnecting
                  : LiveConnectionState.connecting,
    );

    try {
      final WebSocketChannel channel = _connector(buildUri(_apiKey));
      _channel = channel;
      _subscription = channel.stream.listen(
        _onFrame,
        onError: (Object error) => _onClosed(null, '$error'),
        onDone: () => _onClosed(null, null),
        cancelOnError: false,
      );

      // The setup frame must be first on the connection.
      _sendJson(_config!.buildSetup());
    } on Object catch (error) {
      _onClosed(null, '$error');
    }
  }

  void _onFrame(dynamic frame) {
    final String raw =
        frame is String ? frame : utf8.decode(frame as List<int>);
    final ServerMessage? message = ServerMessage.tryParse(raw);
    if (message == null) return;

    if (message.isSetupComplete && !_setupAcknowledged) {
      _setupAcknowledged = true;
      _backoff.reset();
      _setState(LiveConnectionState.ready);
      if (!_readyCompleter.isCompleted) _readyCompleter.complete();
    }

    // Keep the newest usable handle so a reconnect can resume context.
    if (message.resumable && message.newHandle.isNotEmpty) {
      _resumeHandle = message.newHandle;
    }

    // The server is about to drop this connection. Reconnect immediately
    // rather than waiting for the socket to die, which wastes the remaining
    // seconds and can cut the model off mid-sentence.
    if (message.goAway != null) {
      _scheduleReconnect(immediate: true);
    }

    _messages.add(message);
  }

  void _sendJson(Map<String, dynamic> payload) {
    final WebSocketChannel? channel = _channel;
    if (channel == null) return;
    channel.sink.add(jsonEncode(payload));
  }

  /// Sends one PCM chunk. Safe to call when the socket is not open, so a
  /// capture loop can call it unconditionally.
  void sendAudio(Uint8List pcm) => _sendJson(LiveMessages.audio(pcm));

  /// Flushes the server's cached input audio after a pause in the mic.
  void sendAudioStreamEnd() => _sendJson(LiveMessages.audioStreamEnd());

  /// Manual-mode activity signals. Only legal when server VAD is disabled.
  void sendActivityStart() => _sendJson(LiveMessages.activityStart());

  void sendActivityEnd() => _sendJson(LiveMessages.activityEnd());

  /// Sends a text turn. [turnComplete] false keeps the turn open for the
  /// following realtime input.
  void sendText(String text, {bool turnComplete = true}) {
    if (text.trim().isEmpty) return;
    _sendJson(LiveMessages.clientContent(text, turnComplete: turnComplete));
  }

  /// Returns results for function calls the server requested.
  void sendToolResponses(Map<String, Map<String, dynamic>> responses) {
    if (responses.isEmpty) return;
    _sendJson(LiveMessages.toolResponse(responses));
  }

  void _onClosed(int? code, String? reason) {
    if (_state == LiveConnectionState.closed) return;
    _teardownSocket();
    _setupAcknowledged = false;
    if (_closedByUser) {
      _setState(LiveConnectionState.closed);
      return;
    }
    _scheduleReconnect(immediate: false, lastCode: code, lastReason: reason);
  }

  void _scheduleReconnect({
    required bool immediate,
    int? lastCode,
    String? lastReason,
  }) {
    _reconnectTimer?.cancel();
    if (_closedByUser) return;

    if (!immediate && lastCode != null) {
      // Tell the UI why before we start silently retrying.
      _messages.add(
        ServerMessage.closedNotice(CloseCodes.describe(lastCode, lastReason)),
      );
    }

    final Duration delay = immediate ? Duration.zero : _backoff.next();
    _reconnectTimer = Timer(delay, () {
      unawaited(_openSocket(isReconnect: true));
    });
  }

  /// Closes the socket and stops reconnecting.
  Future<void> disconnect() async {
    _closedByUser = true;
    _reconnectTimer?.cancel();
    _teardownSocket();
    _setState(LiveConnectionState.closed);
  }

  void _teardownSocket() {
    _subscription?.cancel();
    _subscription = null;
    final WebSocketChannel? channel = _channel;
    _channel = null;
    if (channel != null) {
      unawaited(channel.sink.close().catchError((Object _) {}));
    }
  }

  void _setState(LiveConnectionState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  Future<void> dispose() async {
    await disconnect();
    await _messages.close();
    await _states.close();
  }
}