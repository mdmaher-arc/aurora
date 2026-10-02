import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../live/protocol_constants.dart';

/// Accumulates model audio and tracks how much is queued.
///
/// Model audio can arrive faster than real time, so without buffering the
/// output stutters; with too much buffering it lags. This holds a target
/// duration and reports when the queue drifts away from it, letting the
/// caller trim aggressively for barge-in and grow generously otherwise.
class PlaybackQueue {
  PlaybackQueue({
    this.targetMillis = 240,
    this.minTargetMillis = 120,
    this.maxTargetMillis = 480,
  })  : assert(minTargetMillis <= targetMillis),
        assert(targetMillis <= maxTargetMillis);

  /// Startup and steady-state target queue depth.
  final int targetMillis;

  /// Floor used after an underrun.
  final int minTargetMillis;

  /// Ceiling used while the stream is consistently ahead of playback.
  final int maxTargetMillis;

  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _queuedBytes = 0;
  int _target = 240;
  int _underrunCount = 0;

  int get targetDurationMillis => _target;

  /// Bytes waiting to play.
  int get queuedBytes => _queuedBytes;

  /// Queued audio in milliseconds at 24 kHz PCM16.
  double get queuedMillis =>
      _queuedBytes * 1000.0 / (AudioFormat.outputSampleRate * 2);

  bool get isEmpty => _chunks.isEmpty;

  /// True when enough audio is buffered that playback can start smoothly.
  bool get hasPrimed => queuedMillis >= _target;

  /// Appends a decoded model audio chunk.
  void add(Uint8List chunk) {
    if (chunk.isEmpty) return;
    _chunks.add(chunk);
    _queuedBytes += chunk.length;

    // Sustained fullness means the model is outrunning playback; let the
    // buffer grow toward the ceiling rather than discarding audio.
    if (queuedMillis > _target * 1.6 && _target < maxTargetMillis) {
      _target = math.min(maxTargetMillis, _target + 20);
    }
  }

  /// Removes and returns the next chunk, or null when empty.
  ///
  /// Call this as the player drains audio.
  Uint8List? take() {
    if (_chunks.isEmpty) return null;
    final Uint8List chunk = _chunks.removeFirst();
    _queuedBytes -= chunk.length;
    return chunk;
  }

  /// Signals that the player ran dry mid-stream.
  ///
  /// Shrinks the target so we recover quickly, rather than staying in a state
  /// that is guaranteed to underrun again.
  void noteUnderrun() {
    _underrunCount++;
    _target = math.max(minTargetMillis, _target - 40);
  }

  int get underruns => _underrunCount;

  /// Drops everything queued. This is the barge-in primitive.
  void flush() {
    _chunks.clear();
    _queuedBytes = 0;
    _target = targetMillis;
  }

  /// Restores state after an interruption, ready for the next turn.
  void reset() {
    flush();
    _underrunCount = 0;
  }
}