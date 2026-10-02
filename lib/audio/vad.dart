import 'dart:math' as math;
import 'dart:typed_data';

import 'pcm.dart';

/// Result of feeding one frame to [AdaptiveVad].
class VadEvent {
  const VadEvent({
    required this.isSpeech,
    required this.snrDb,
    required this.levelDb,
  });

  /// Whether this frame looks like speech.
  final bool isSpeech;

  /// Estimated signal-to-noise ratio in dB.
  final double snrDb;

  /// Frame level in dBFS.
  final double levelDb;
}

/// Energy-and-ZCR voice activity detection with an adaptive noise floor.
///
/// This drives three separate behaviours in the client: suppressing silent
/// frames before transmission, detecting speech onset locally so playback can
/// be cut instantly on barge-in, and deciding when to send `audioStreamEnd`.
///
/// It is a local heuristic, not a replacement for the server's VAD. The server
/// still decides turn boundaries; this just makes the client react faster.
class AdaptiveVad {
  AdaptiveVad({
    this.snrThresholdDb = 8.0,
    this.noiseFloorAlpha = 0.02,
    this.startHangoverMs = 80,
    this.endHangoverMs = 600,
    this.minSpeechMs = 120,
  });

  /// How far above the noise floor a frame must sit to count as speech.
  final double snrThresholdDb;

  /// Smoothing rate for the noise-floor estimate. Lower reacts more slowly.
  final double noiseFloorAlpha;

  /// Speech must persist this long before onset is committed. Prevents a
  /// single loud transient (door slam, cough) from triggering barge-in.
  final int startHangoverMs;

  /// Speech must be absent this long before it is considered finished.
  final int endHangoverMs;

  /// Minimum utterance length, used to reject clicks and key taps.
  final int minSpeechMs;

  double _noiseRms = 0.003;
  bool _primed = false;
  bool _inSpeech = false;
  int _frameMillis = 20;
  int _speechRunMs = 0;
  int _silenceRunMs = 0;

  /// Running noise-floor estimate in dBFS.
  double get noiseFloorDb => Pcm.toDb(_noiseRms);

  /// True while the detector considers the user to be speaking.
  bool get isSpeech => _inSpeech;

  /// Tells the VAD how long each incoming frame is, so the hangover windows
  /// are accurate regardless of the capture buffer size.
  void configureFrameDuration(int millis) {
    if (millis > 0) _frameMillis = millis;
  }

  /// Feeds one frame of mono audio and reports what it decided.
  VadEvent analyse(Float32List samples) {
    final double level = Pcm.rms(samples);
    final double zcr = Pcm.zeroCrossingRate(samples);

    if (!_primed) {
      // Seed the floor from the first few frames, which are assumed to be
      // room tone. Starting from zero would make everything look like speech.
      _noiseRms = level;
      _primed = true;
    }

    // Track the floor downward quickly and upward slowly, so a sustained
    // noise source becomes the new baseline but a quiet passage does not.
    if (level < _noiseRms) {
      _noiseRms += noiseFloorAlpha * (level - _noiseRms);
    } else {
      _noiseRms += (noiseFloorAlpha * 0.25) * (level - _noiseRms);
    }
    if (_noiseRms < 1e-6) _noiseRms = 1e-6;

    final double snrDb = Pcm.toDb(level) - Pcm.toDb(_noiseRms);
    final double levelDb = Pcm.toDb(level);

    // Require some spectral activity: steady low-frequency hum has low ZCR
    // and should not register as speech.
    final bool energetic = snrDb >= snrThresholdDb;
    final bool voiced = zcr > 0.02 || level > _noiseRms * 6.0;
    final bool candidate = energetic && voiced;

    if (candidate) {
      _speechRunMs += _frameMillis;
      _silenceRunMs = 0;
    } else {
      _silenceRunMs += _frameMillis;
      _speechRunMs = 0;
    }

    final bool wasSpeech = _inSpeech;
    if (!_inSpeech) {
      if (_speechRunMs >= startHangoverMs) _inSpeech = true;
    } else {
      if (_silenceRunMs >= endHangoverMs) {
        _inSpeech = false;
        _speechRunMs = 0;
      }
    }

    return VadEvent(
      // Only report speech after the minimum duration is met, so the UI and
      // the barge-in logic do not flicker on impulsive noise.
      isSpeech: _inSpeech || (wasSpeech && _speechRunMs < minSpeechMs),
      snrDb: snrDb,
      levelDb: levelDb,
    );
  }

  /// Clears detector state, e.g. when the microphone restarts.
  void reset() {
    _primed = false;
    _inSpeech = false;
    _speechRunMs = 0;
    _silenceRunMs = 0;
    _noiseRms = 0.003;
  }
}

/// A small fixed-capacity ring of float samples, used to pre-roll audio so
/// the first syllable of a turn is not clipped.
class RingBuffer {
  RingBuffer(int capacity)
      : _data = Float32List(capacity < 1 ? 1 : capacity),
        _capacity = capacity < 1 ? 1 : capacity;

  final Float32List _data;
  final int _capacity;
  int _write = 0;
  int _length = 0;

  int get length => _length;
  bool get isEmpty => _length == 0;
  int get capacity => _capacity;

  void clear() {
    _write = 0;
    _length = 0;
  }

  void add(Float32List samples) {
    for (int i = 0; i < samples.length; i++) {
      _data[_write] = samples[i];
      _write = (_write + 1) % _capacity;
      if (_length < _capacity) _length++;
    }
  }

  /// Copies the most recent [count] samples into a new list, oldest first.
  Float32List tail(int count) {
    final int n = math.min(count, _length);
    final Float32List out = Float32List(n);
    if (n == 0) return out;
    final int start = (_write - n + _capacity) % _capacity;
    for (int i = 0; i < n; i++) {
      out[i] = _data[(start + i) % _capacity];
    }
    return out;
  }
}