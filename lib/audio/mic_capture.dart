import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../audio/pcm.dart';

/// Wraps microphone capture and decodes the platform stream to float samples.
///
/// `record` exposes `echoCancel`, `noiseSuppress` and `autoGain`, which map
/// onto each platform's own voice-communication DSP (Android's
/// AcousticEchoCanceler/NoiseSuppressor/AutomaticGainControl, Apple's voice
/// processing I/O). That is what keeps the model from hearing itself on
/// speakerphone.
class MicCapture {
  MicCapture({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  StreamSubscription<Uint8List>? _subscription;
  int _sampleRate = 48000;

  /// Rate the platform is actually delivering.
  int get sampleRate => _sampleRate;

  Future<bool> hasPermission() => _recorder.hasPermission();

  /// Starts capture. [onFrame] receives mono float samples at the
  /// platform's native rate; the caller resamples.
  Future<bool> start({
    required void Function(Float32List samples, int sampleRate) onFrame,
    int requestedRate = 48000,
    bool echoCancel = true,
    bool noiseSuppress = true,
    bool autoGain = true,
  }) async {
    if (!await _recorder.hasPermission()) return false;

    _sampleRate = requestedRate;
    final RecordConfig config = RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: requestedRate,
      numChannels: 1,
      // Best-effort platform DSP. Not every platform honours every flag, but
      // setting them costs nothing where unsupported.
      echoCancel: echoCancel,
      noiseSuppress: noiseSuppress,
      autoGain: autoGain,
      streamBufferSize: 1024,
    );

    final Stream<Uint8List> stream = await _recorder.startStream(config);
    _subscription = stream.listen(
      (Uint8List bytes) {
        if (bytes.isEmpty) return;
        onFrame(Pcm.decodeS16Le(bytes), _sampleRate);
      },
      onError: (Object _) {
        // A capture error should not crash the session; the next chunk or the
        // connection state will surface the problem.
      },
      cancelOnError: false,
    );
    return true;
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _recorder.stop();
    } on Object {
      // Already stopped, or never started.
    }
  }

  Future<void> dispose() => _recorder.dispose();
}