import 'dart:convert';
import 'dart:typed_data';

/// A single pending function call.
class ToolCall {
  const ToolCall({required this.id, required this.name, required this.args});

  final String id;
  final String name;
  final Map<String, dynamic> args;
}

/// `GoAway`: the connection is about to be torn down.
class GoAway {
  const GoAway({required this.timeLeft});

  /// Remaining time before the drop. A protobuf Duration.
  final Duration timeLeft;
}

/// `SessionResumptionUpdate`.
class SessionResumptionUpdate {
  const SessionResumptionUpdate({
    required this.resumable,
    required this.newHandle,
  });

  final bool resumable;
  final String newHandle;
}

/// Token accounting for the session.
class UsageMetadata {
  const UsageMetadata({
    this.totalTokens = 0,
    this.promptTokens = 0,
    this.responseTokens = 0,
    this.cachedTokens = 0,
  });

  final int totalTokens;
  final int promptTokens;
  final int responseTokens;
  final int cachedTokens;
}

/// One decoded server message.
///
/// The Live API sends `usageMetadata` alongside, and otherwise exactly one of
/// the payload fields. A single event can also carry several content parts at
/// once, so [audioChunks] is a list rather than a single buffer.
class ServerMessage {
  const ServerMessage({
    this.isSetupComplete = false,
    this.modelText = '',
    this.audioChunks = const <Uint8List>[],
    this.outputTranscription = '',
    this.inputTranscription = '',
    this.interimInputTranscription = '',
    this.interrupted = false,
    this.turnComplete = false,
    this.generationComplete = false,
    this.interactionStatus,
    this.toolCalls = const <ToolCall>[],
    this.cancelledToolCallIds = const <String>[],
    this.goAway,
    this.resumable = false,
    this.newHandle = '',
    this.usage,
    this.notice,
  });

  /// True once the server accepts our setup frame.
  final bool isSetupComplete;

  /// Text parts from `serverContent.modelTurn`.
  final String modelText;

  /// Model audio, 24 kHz mono PCM16.
  final List<Uint8List> audioChunks;

  final String outputTranscription;
  final String inputTranscription;
  final String interimInputTranscription;

  /// The model was cut off. Requires an immediate playback flush.
  final bool interrupted;

  final bool turnComplete;
  final bool generationComplete;

  /// `IN_PROGRESS` or `IDLE`. With extended thinking, `turnComplete` does
  /// not mean the session is idle, so this is the reliable signal.
  final String? interactionStatus;

  final List<ToolCall> toolCalls;

  /// Ids cancelled by `toolCallCancellation`, normally on barge-in.
  final List<String> cancelledToolCallIds;

  final GoAway? goAway;

  /// A new resumption handle is available.
  final bool resumable;
  final String newHandle;

  final UsageMetadata? usage;

  /// Set only on synthetic messages built by [closedNotice].
  final String? notice;

  /// True while the model is producing output.
  bool get isSpeaking =>
      audioChunks.isNotEmpty || outputTranscription.isNotEmpty;

  /// A synthetic message carrying a human-readable connection problem.
  ///
  /// Connection errors are not part of the wire protocol, so they ride the
  /// same stream as a notice. [isNotice] separates them from real traffic.
  factory ServerMessage.closedNotice(String reason) =>
      ServerMessage(notice: reason);

  bool get isNotice => notice != null;

  /// Decodes a raw socket frame.
  ///
  /// Returns `null` for frames we cannot make sense of rather than throwing,
  /// so one bad message cannot tear down a live conversation.
  static ServerMessage? tryParse(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    return parse(decoded);
  }

  static ServerMessage parse(Map<String, dynamic> json) {
    return ServerMessage(
      isSetupComplete: json['setupComplete'] != null,
      modelText: _parseModelText(json['serverContent']),
      audioChunks: _parseAudio(json['serverContent']),
      outputTranscription: _transcriptionText(
        _field(json['serverContent'], 'outputTranscription'),
      ),
      inputTranscription: _transcriptionText(
        _field(json['serverContent'], 'inputTranscription'),
      ),
      interimInputTranscription: _transcriptionText(
        _field(json['serverContent'], 'interimInputTranscription'),
      ),
      interrupted: _field(json['serverContent'], 'interrupted') == true,
      turnComplete: _field(json['serverContent'], 'turnComplete') == true,
      generationComplete:
          _field(json['serverContent'], 'generationComplete') == true,
      interactionStatus:
          _field(json['serverContent'], 'interactionStatus') as String?,
      toolCalls: _parseToolCalls(json['toolCall']),
      cancelledToolCallIds: _parseCancelledIds(json['toolCallCancellation']),
      goAway: _parseGoAway(json['goAway']),
      resumable: _field(json['sessionResumptionUpdate'], 'resumable') == true,
      newHandle:
          _field(json['sessionResumptionUpdate'], 'newHandle') as String? ?? '',
      usage: _parseUsage(json['usageMetadata']),
    );
  }
}

/// Reads a key from a `Map<String, dynamic>?`, tolerating null.
Object? _field(Object? container, String key) {
  if (container is Map<String, dynamic>) return container[key];
  return null;
}

/// Concatenates every text part in `serverContent.modelTurn`.
String _parseModelText(Object? serverContent) {
  final Object? modelTurn = _field(serverContent, 'modelTurn');
  final Object? parts = modelTurn is Map<String, dynamic>
      ? modelTurn['parts']
      : null;
  if (parts is! List) return '';

  final StringBuffer buffer = StringBuffer();
  for (final Object? part in parts) {
    if (part is! Map<String, dynamic>) continue;
    final Object? text = part['text'];
    if (text is String) buffer.write(text);
  }
  return buffer.toString();
}

/// Collects every audio blob in `serverContent.modelTurn`.
List<Uint8List> _parseAudio(Object? serverContent) {
  final Object? modelTurn = _field(serverContent, 'modelTurn');
  final Object? parts = modelTurn is Map<String, dynamic>
      ? modelTurn['parts']
      : null;
  if (parts is! List) return const <Uint8List>[];

  final List<Uint8List> audio = <Uint8List>[];
  for (final Object? part in parts) {
    if (part is! Map<String, dynamic>) continue;
    final Object? inline = part['inlineData'];
    if (inline is! Map<String, dynamic>) continue;
    final Object? mime = inline['mimeType'];
    // Only keep audio blobs; image parts can appear in the same list.
    if (mime is! String || !mime.startsWith('audio/')) continue;
    final Uint8List? bytes = _decodeBlob(inline['data']);
    if (bytes != null) audio.add(bytes);
  }
  return audio;
}

/// Decodes a base64 `data` field.
Uint8List? _decodeBlob(Object? data) {
  if (data is! String || data.isEmpty) return null;
  try {
    return base64Decode(data);
  } on FormatException {
    return null;
  }
}

/// Pulls the text out of a transcription object or a plain string.
String _transcriptionText(Object? raw) {
  if (raw is String) return raw;
  if (raw is Map<String, dynamic>) {
    final Object? text = raw['text'];
    if (text is String) return text;
  }
  return '';
}

/// Parses `toolCall.functionCalls`.
List<ToolCall> _parseToolCalls(Object? toolCall) {
  final Object? calls = _field(toolCall, 'functionCalls');
  if (calls is! List) return const <ToolCall>[];

  final List<ToolCall> parsed = <ToolCall>[];
  for (final Object? call in calls) {
    if (call is! Map<String, dynamic>) continue;
    final Object? args = call['args'];
    parsed.add(
      ToolCall(
        id: call['id'] as String? ?? '',
        name: call['name'] as String? ?? '',
        args: args is Map<String, dynamic> ? args : <String, dynamic>{},
      ),
    );
  }
  return parsed;
}

/// Parses `toolCallCancellation.ids`.
List<String> _parseCancelledIds(Object? cancellation) {
  final Object? ids = _field(cancellation, 'ids');
  if (ids is! List) return const <String>[];
  return ids.whereType<String>().toList(growable: false);
}

/// Parses `goAway.timeLeft`, a protobuf Duration.
GoAway? _parseGoAway(Object? goAway) {
  if (goAway is! Map<String, dynamic>) return null;
  final Object? duration = goAway['timeLeft'];
  final Object? seconds =
      duration is Map<String, dynamic> ? duration['seconds'] : null;
  final Object? nanos =
      duration is Map<String, dynamic> ? duration['nanos'] : null;
  return GoAway(
    timeLeft: Duration(
      seconds: seconds is int ? seconds : 0,
      microseconds: nanos is int ? nanos ~/ 1000 : 0,
    ),
  );
}

/// Parses `usageMetadata`.
UsageMetadata? _parseUsage(Object? usage) {
  if (usage is! Map<String, dynamic>) return null;
  return UsageMetadata(
    totalTokens: _asInt(usage['totalTokenCount']),
    promptTokens: _asInt(usage['promptTokenCount']),
    responseTokens: _asInt(usage['responseTokenCount']),
    cachedTokens: _asInt(usage['cachedContentTokenCount']),
  );
}

int _asInt(Object? value) => value is int ? value : 0;
