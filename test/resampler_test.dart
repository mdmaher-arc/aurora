import 'dart:math' as math;
import 'dart:typed_data';

import 'package:aurora/audio/resampler.dart';
import 'package:flutter_test/flutter_test.dart';

/// Generates [count] samples of a sine at [freq] Hz sampled at [rate].
Float32List sine(double freq, int rate, int count, {double amp = 0.5}) {
  return Float32List.fromList(
    List<double>.generate(
      count,
      (int i) => amp * math.sin(2 * math.pi * freq * i / rate),
    ),
  );
}

void main() {
  group('Resampler', () {
    test('passes audio through untouched when rates match', () {
      final Resampler r = Resampler(inputRate: 16000, outputRate: 16000);
      final Float32List input = sine(300, 16000, 160);
      expect(r.isPassthrough, isTrue);
      expect(r.process(input), same(input));
    });

    test('halves the sample count when downsampling 2:1', () {
      final Resampler r = Resampler(inputRate: 32000, outputRate: 16000);
      final Float32List out = r.process(sine(300, 32000, 3200));
      // Roughly half, allowing for filter warm-up.
      expect(out.length, closeTo(1600, 60));
    });

    test('preserves a low-frequency sine through 48k to 16k', () {
      const int inRate = 48000;
      const int outRate = 16000;
      final Resampler r = Resampler(inputRate: inRate, outputRate: outRate);

      // 300 Hz sits well below the 8 kHz output Nyquist.
      final Float32List out = r.process(sine(300, inRate, inRate));
      expect(out.length, greaterThan(inRate ~/ outRate - 40));

      // Skip the filter warm-up, then compare against a direct reference.
      // The offset matters: out[i] is the input at time i / outRate, so the
      // reference must be indexed at the same position.
      const int skip = 200;
      final Float32List reference = sine(300, outRate, out.length);
      double total = 0.0;
      for (int i = skip; i < out.length; i++) {
        total += (out[i] - reference[i]).abs();
      }
      expect(total / (out.length - skip), lessThan(0.02));
    });

    test('attenuates a tone above the output Nyquist', () {
      const int inRate = 48000;
      const int outRate = 16000;
      final Resampler r = Resampler(inputRate: inRate, outputRate: outRate);

      // 12 kHz would alias into the audible band without a proper filter.
      final Float32List out = r.process(sine(12000, inRate, inRate));

      double peak = 0.0;
      for (int i = 300; i < out.length; i++) {
        final double a = out[i].abs();
        if (a > peak) peak = a;
      }
      // Input peak is 0.5; a working anti-alias filter drops this far lower.
      expect(peak, lessThan(0.1));
    });
  });

  group('Resampler, streaming behaviour', () {
    test('maintains constant gain across input chunk sizes', () {
      double measureRms(int chunkSize) {
        final Resampler r = Resampler(inputRate: 48000, outputRate: 16000);
        double sumSq = 0.0;
        int count = 0;
        int phase = 0;
        final Float32List block = Float32List(chunkSize);
        for (int i = 0; i < 40; i++) {
          for (int j = 0; j < chunkSize; j++) {
            block[j] = 0.5 * math.sin(2 * math.pi * 300.0 * (phase + j) / 48000);
          }
          phase += chunkSize;
          for (final double s in r.process(block)) {
            sumSq += s * s;
            count++;
          }
        }
        return math.sqrt(sumSq / count);
      }

      // Every chunking of the same signal should give the same level.
      for (final int size in <int>[320, 1024, 4096]) {
        expect(measureRms(size), closeTo(0.3535, 0.02));
      }
    });

    test('produces contiguous output with no gaps between blocks', () {
      final Resampler r = Resampler(inputRate: 48000, outputRate: 16000);
      final Float32List block = Float32List(480);
      final List<double> all = <double>[];
      for (int i = 0; i < 20; i++) {
        for (int j = 0; j < block.length; j++) {
          final int n = i * block.length + j;
          block[j] = 0.4 * math.sin(2 * math.pi * 440.0 * n / 48000);
        }
        all.addAll(r.process(block));
      }
      // A discontinuity would appear as a large jump between neighbours.
      double maxJump = 0.0;
      for (int i = 1; i < all.length; i++) {
        final double d = (all[i] - all[i - 1]).abs();
        if (d > maxJump) maxJump = d;
      }
      expect(maxJump, lessThan(0.15));
    });

    test('reset clears filter state', () {
      final Resampler r = Resampler(inputRate: 48000, outputRate: 16000);
      r.process(Float32List.fromList(List<double>.filled(480, 1.0)));
      r.reset();
      final Float32List afterReset = r.process(Float32List(480));
      double peak = 0.0;
      for (final double s in afterReset) {
        final double a = s.abs();
        if (a > peak) peak = a;
      }
      // Starting from silence, not carrying the previous block's energy.
      expect(peak, lessThan(0.05));
    });

    test('handles 44.1 kHz to 16 kHz, a non-integer ratio', () {
      final Resampler r = Resampler(inputRate: 44100, outputRate: 16000);
      // One second of audio. A 64-tap filter cannot emit the first ~23
      // output samples, so allow for that latency.
      final Float32List out = r.process(sine(300, 44100, 44100));
      expect(out.length, closeTo(16000, 40));
      for (final double s in out) {
        expect(s.isFinite, isTrue, reason: 'no NaN or infinity');
      }
    });

    test('rejects use after dispose', () {
      final Resampler r = Resampler(inputRate: 48000, outputRate: 16000)
        ..dispose();
      expect(() => r.process(Float32List(10)), throwsStateError);
    });
  });
}