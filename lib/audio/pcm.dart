import 'dart:math' as math;
import 'dart:typed_data';

/// PCM helpers shared by the capture, VAD and playback stages.
class Pcm {
  Pcm._();

  /// Reads float samples (-1.0..1.0) out of little-endian signed 16-bit PCM.
  static Float32List decodeS16Le(Uint8List bytes) {
    final int count = bytes.length ~/ 2;
    final Float32List out = Float32List(count);
    final ByteData view = ByteData.sublistView(bytes);
    for (int i = 0; i < count; i++) {
      out[i] = view.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  /// Encodes float samples to little-endian signed 16-bit PCM, clamping
  /// rather than wrapping on overflow.
  static Uint8List encodeS16Le(Float32List samples) {
    final Uint8List out = Uint8List(samples.length * 2);
    final ByteData view = ByteData.sublistView(out);
    for (int i = 0; i < samples.length; i++) {
      double v = samples[i];
      if (v > 1.0) v = 1.0;
      if (v < -1.0) v = -1.0;
      view.setInt16(i * 2, (v * 32767.0).round(), Endian.little);
    }
    return out;
  }

  /// Root-mean-square amplitude of a frame, in the 0..1 range.
  static double rms(Float32List samples) {
    if (samples.isEmpty) return 0.0;
    double sum = 0.0;
    for (int i = 0; i < samples.length; i++) {
      sum += samples[i] * samples[i];
    }
    return math.sqrt(sum / samples.length);
  }

  /// Largest absolute sample value, in the 0..1 range.
  static double peak(Float32List samples) {
    double max = 0.0;
    for (int i = 0; i < samples.length; i++) {
      final double a = samples[i].abs();
      if (a > max) max = a;
    }
    return max;
  }

  /// Fraction of adjacent sample pairs that change sign, in the 0..1 range.
  ///
  /// Voiced speech sits well above noise here; useful as a cheap guard
  /// against treating steady background hum as speech.
  static double zeroCrossingRate(Float32List samples) {
    if (samples.length < 2) return 0.0;
    int crossings = 0;
    for (int i = 1; i < samples.length; i++) {
      if ((samples[i - 1] < 0) != (samples[i] < 0)) crossings++;
    }
    return crossings / (samples.length - 1);
  }

  /// Converts an amplitude in 0..1 to dBFS, floored at -100 dB.
  static double toDb(double amplitude) {
    if (amplitude <= 1e-10) return -100.0;
    final double db = 20.0 * math.log(amplitude) / math.ln10;
    return db < -100.0 ? -100.0 : db;
  }
}