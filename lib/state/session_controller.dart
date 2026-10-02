import 'dart:async';
import 'package:flutter/foundation.dart';

import '../audio/pcm.dart';
import '../audio/playback_queue.dart';
import '../audio/resampler.dart';
import '../audio/vad.dart';
import '../live/live_client.dart';
import '../live/live_messages.dart';
import '../live/protocol_constants.dart';
import '../live/server_message.dart';

/// One line of conversation.
@immutable
class TranscriptLine {
  const TranscriptLine({
    required this.speaker,
    required this.text,
    required this.isFinal,
  });

  /// Either [TranscriptSpeaker.user] or [TranscriptSpeaker.model].
  final String speaker;
  final String text;

  /// Interim lines are still being revised.
  final bool isFinal;
}

abstract final class TranscriptSpeaker {
  static const String user = 'You';
  static const String model = 'Gemini';
}

/// Coarse connection state, suitable for driving the UI.
enum SessionStatus {
  idle,
  connecting,
  listening,

  /// The model is producing audio.
  speaking,

  reconnecting,
  error,
}

/// A sink for decoded model audio.
///
/// Abstracting playback keeps [SessionController] free of plugin imports, so
/// it stays testable and the audio backend stays swappable.
abstract interface class AudioSink {
  /// Prepares the sink for a new turn. Called after a flush.
  Future<void> prepare();

  /// Queues one chunk of 24 kHz mono PCM16.
  void write(Uint8List chunk);

  /// Discards everything queued and stops immediately. Used for barge-in.
  Future<void> flush();
}

/// A sink that discards audio. Useful in tests and on unsupported platforms.
class NullAudioSink implements AudioSink {
  const NullAudioSink();

  @override
  Future<void> prepare() async {}

  @override
  void write(Uint8List chunk) {}

  @override
  Future<void> flush() async {}
}

/// Orchestrates the full pipeline: microphone -> VAD -> resample -> socket,
/// and socket -> jitter buffer -> speaker, plus transcript bookkeeping.
///
/// This is the only class the widget layer needs to talk to.
class SessionController extends ChangeNotifier {
  SessionController({LiveClient? client, AudioSink? sink})
      : _client = client ?? LiveClient(),
        _sink = sink ?? const NullAudioSink();

  final LiveClient _client;
  final AudioSink _sink;

  /// Key or ephemeral token. Never logged or shown in full.
  LiveSessionConfig _config = defaultSessionConfig;

  final AdaptiveVad _vad = AdaptiveVad();
  final PlaybackQueue _queue = PlaybackQueue();

  /// Holds recently captured audio so the first syllable survives the
  /// speech-onset delay in the VAD.
  final RingBuffer _preRoll = RingBuffer(AudioFormat.inputSampleRate);

  Resampler? _resampler;
  StreamSubscription<ServerMessage>? _messageSub;
  StreamSubscription<LiveConnectionState>? _stateSub;

  final List<TranscriptLine> _lines = <TranscriptLine>[];
  SessionStatus _status = SessionStatus.idle;
  String _interimUser = '';
  String _interimModel = '';
  String _errorMessage = '';
  double _inputLevel = 0.0;
  double _outputLevel = 0.0;
  bool _micMuted = false;

  /// Set while the user is talking over the model, so the UI can flag the
  /// echo-cancellation risk on speakerphone.
  bool _bargeInDetected = false;

  /// True once the jitter buffer has filled and playback has begun for the
  /// current turn. Reset on interruption so the next turn re-primes.
  bool _primed = false;

  /// Sensible defaults: both transcriptions on so captions work.
  static const LiveSessionConfig defaultSessionConfig = LiveSessionConfig(
    inputTranscription: AudioTranscriptionConfig(),
    outputTranscription: AudioTranscriptionConfig(),
  );

  List<TranscriptLine> get lines => List<TranscriptLine>.unmodifiable(_lines);
  SessionStatus get status => _status;
  String get interimUserText => _interimUser;
  String get interimModelText => _interimModel;
  String get errorMessage => _errorMessage;
  bool get isMicMuted => _micMuted;
  bool get bargeInDetected => _bargeInDetected;

  /// Smoothed input level in 0..1, for the visualiser.
  double get inputLevel => _inputLevel;

  /// Smoothed output level in 0..1, for the visualiser.
  double get outputLevel => _outputLevel;

  /// Queued model audio in milliseconds, shown in diagnostics.
  double get queuedMillis => _queue.queuedMillis;

  bool get isConnected =>
      _status == SessionStatus.listening || _status == SessionStatus.speaking;

  /// Opens the session. [inputSampleRate] is whatever the platform gave us;
  /// audio is resampled to the 16 kHz the server expects.
  Future<void> start({
    required String apiKey,
    LiveSessionConfig? config,
    int inputSampleRate = 48000,
  }) async {
    if (apiKey.trim().isEmpty) {
      _setError('Add your Gemini API key to continue.');
      return;
    }

    _config = config ?? defaultSessionConfig;
    _resampler = Resampler(
      inputRate: inputSampleRate,
      outputRate: AudioFormat.inputSampleRate,
    );
    _vad.reset();
    _queue.reset();
    _primed = false;
    _lines.clear();
    _errorMessage = '';
    _setStatus(SessionStatus.connecting);

    _messageSub ??= _client.messages.listen(_onServerMessage);
    _stateSub ??= _client.states.listen(_onStateChanged);

    await _client.connect(apiKey: apiKey, config: _config);
  }

  Future<void> stop() async {
    await _client.disconnect();
    _resampler?.dispose();
    _resampler = null;
    _queue.reset();
    _primed = false;
    await _sink.flush();
    _setStatus(SessionStatus.idle);
  }

  /// Feeds one block of captured float samples from the microphone.
  ///
  /// Called from the capture stream, so it must stay cheap and must not throw:
  /// a pipeline hiccup should not tear down a live conversation.
  void onAudioCaptured(Float32List samples, int sampleRate) {
    if (_status == SessionStatus.error) return;

    final VadEvent event = _vad.analyse(samples);
    _inputLevel =
        _inputLevel * 0.7 + (event.levelDb.clamp(-60.0, 0.0) / 60.0) * 0.3;

    // A muted mic still runs the VAD, so barge-in and the level meter stay
    // live and unmuting feels instant.
    if (_micMuted) return;

    // Local barge-in: cut playback as soon as the user starts talking rather
    // than waiting for the server's `interrupted` flag to come back.
    if (event.isSpeech && _queue.queuedMillis > 0) {
      if (!_bargeInDetected) {
        _bargeInDetected = true;
        _queue.flush();
        _primed = false;
        unawaited(_sink.flush());
        _clearModelTranscript();
        if (_status == SessionStatus.speaking) {
          _setStatus(SessionStatus.listening);
        }
      }
    } else if (!event.isSpeech) {
      _bargeInDetected = false;
    }

    final Resampler? resampler = _resampler;
    if (resampler == null) return;

    // Resample first, then chunk to a fixed 20 ms so the wire format is
    // exactly what the server documents.
    final Float32List resampled =
        resampler.isPassthrough ? samples : resampler.process(samples);
    if (resampled.isEmpty) return;

    _preRoll.add(resampled);
    _emitChunks(resampled);
  }

  /// Splits [samples] into 20 ms PCM16 chunks and sends them.
  ///
  /// A trailing partial chunk is held back until more audio arrives, rather
  /// than sending a short frame for the server to resample.
  void _emitChunks(Float32List samples) {
    const int chunkSamples = AudioFormat.inputChunkSamples;
    int offset = 0;
    while (offset + chunkSamples <= samples.length) {
      final Float32List slice =
          Float32List.sublistView(samples, offset, offset + chunkSamples);
      _client.sendAudio(Pcm.encodeS16Le(slice));
      offset += chunkSamples;
    }
  }

  /// Called after a pause in the mic so the server flushes cached audio.
  void notifyMicPaused() => _client.sendAudioStreamEnd();

  void toggleMicMute() {
    _micMuted = !_micMuted;
    if (_micMuted) _client.sendAudioStreamEnd();
    notifyListeners();
  }

  /// Sends a typed message as a complete turn.
  void sendText(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _lines.add(
      TranscriptLine(
        speaker: TranscriptSpeaker.user,
        text: trimmed,
        isFinal: true,
      ),
    );
    _client.sendText(trimmed);
    notifyListeners();
  }

  void _onStateChanged(LiveConnectionState state) {
    switch (state) {
      case LiveConnectionState.ready:
        _errorMessage = '';
        _setStatus(SessionStatus.listening);
      case LiveConnectionState.connecting:
        _setStatus(SessionStatus.connecting);
      case LiveConnectionState.reconnecting:
        _setStatus(SessionStatus.reconnecting);
      case LiveConnectionState.closed:
      case LiveConnectionState.idle:
        if (_status != SessionStatus.error) _setStatus(SessionStatus.idle);
      case LiveConnectionState.failed:
        _setStatus(SessionStatus.error);
    }
  }

  void _onServerMessage(ServerMessage message) {
    if (message.isNotice) {
      _setError(message.notice!);
      return;
    }

    if (message.interrupted) {
      // The server confirmed the barge-in. Drop anything still queued.
      _queue.flush();
      _primed = false;
      unawaited(_sink.flush());
      _clearModelTranscript();
      if (_status == SessionStatus.speaking) {
        _setStatus(SessionStatus.listening);
      }
      return;
    }

    for (final Uint8List chunk in message.audioChunks) {
      _queue.add(chunk);
      final double peakDb = Pcm.toDb(Pcm.peak(Pcm.decodeS16Le(chunk)));
      _outputLevel =
          _outputLevel * 0.6 + (peakDb.clamp(-60.0, 0.0) / 60.0) * 0.4;
    }
    if (message.audioChunks.isNotEmpty) {
      _drainQueue();
      if (_status != SessionStatus.speaking) {
        _setStatus(SessionStatus.speaking);
      }
    }

    final String interimUser = message.interimInputTranscription;
    if (interimUser.isNotEmpty) {
      _interimUser = interimUser;
      notifyListeners();
    }

    final String interimModel = message.outputTranscription;
    if (interimModel.isNotEmpty) {
      _interimModel = interimModel;
      notifyListeners();
    }

    final String finalUser = message.inputTranscription;
    if (finalUser.trim().isNotEmpty) {
      _lines.add(
        TranscriptLine(
          speaker: TranscriptSpeaker.user,
          text: finalUser.trim(),
          isFinal: true,
        ),
      );
      _interimUser = '';
      notifyListeners();
    }

    if (message.turnComplete || message.generationComplete) {
      _commitModelTranscript();
      if (_status == SessionStatus.speaking) {
        _setStatus(SessionStatus.listening);
      }
    }

    if (message.toolCalls.isNotEmpty) {
      // No tools are registered, so answer explicitly rather than leaving
      // the model waiting on a tool response that will never arrive.
      final Map<String, Map<String, dynamic>> responses =
          <String, Map<String, dynamic>>{
        for (final ToolCall call in message.toolCalls)
          call.id: <String, dynamic>{
            'error': 'No tools are configured in this app.',
          },
      };
      _client.sendToolResponses(responses);
    }
  }

  /// Moves queued model audio into the speaker.
  ///
  /// Chunks are pushed through as they arrive, but the first one is held
  /// until the jitter buffer has primed, otherwise playback starts on a
  /// partial buffer and immediately underruns.
  void _drainQueue() {
    if (_queue.queuedMillis < _queue.targetDurationMillis && !_primed) {
      return;
    }
    if (!_primed) {
      _primed = true;
      unawaited(_sink.prepare());
    }
    Uint8List? chunk;
    while ((chunk = _queue.take()) != null) {
      _sink.write(chunk!);
    }
  }

  /// Moves the streaming model transcript into the permanent list.
  void _commitModelTranscript() {
    final String text = _interimModel.trim();
    if (text.isEmpty) return;
    _lines.add(
      TranscriptLine(
        speaker: TranscriptSpeaker.model,
        text: text,
        isFinal: true,
      ),
    );
    _interimModel = '';
    notifyListeners();
  }

  /// Discards a partial model reply, used when the user interrupts.
  void _clearModelTranscript() {
    if (_interimModel.isEmpty) return;
    _interimModel = '';
    notifyListeners();
  }

  /// Surfaces a problem to the user, e.g. a denied microphone permission.
  void reportError(String message) => _setError(message);

  void clearTranscript() {
    _lines.clear();
    _interimUser = '';
    _interimModel = '';
    notifyListeners();
  }

  void _setError(String message) {
    _errorMessage = message;
    _setStatus(SessionStatus.error);
  }

  void _setStatus(SessionStatus next) {
    if (_status == next) return;
    _status = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _stateSub?.cancel();
    _client.dispose();
    _resampler?.dispose();
    super.dispose();
  }
}
