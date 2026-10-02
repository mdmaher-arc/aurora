import 'dart:math' as math;
import 'dart:typed_data';

/// Streaming polyphase FIR resampler for mono audio.
///
/// Linear interpolation aliases badly when downsampling (48 kHz to 16 kHz is
/// the common case here), and the resulting high-frequency junk measurably
/// degrades what the model hears. This uses a windowed-sinc low-pass with a
/// polyphase decomposition instead, and keeps filter state across calls so it
/// can be fed arbitrary chunk sizes.
class Resampler {
  Resampler({
    required this.inputRate,
    required this.outputRate,
    int taps = 63,
    this.phases = 256,
  })  : assert(inputRate > 0 && outputRate > 0),
        // An odd tap count keeps the window centred on the same sample the
        // kernel peaks at, so the filter adds no phase shift.
        assert(taps > 0 && taps.isOdd),
        taps = taps,
        _step = inputRate / outputRate,
        _cutoff = math.min(1.0, outputRate / inputRate) {
    _buildFilter();
  }

  final int inputRate;
  final int outputRate;

  /// Filter length in input samples. Must be odd; see [Resampler.new].
  final int taps;

  /// Number of polyphase branches; controls interpolation resolution.
  final int phases;

  final double _step;

  /// Normalised cutoff, clamped to 1.0 when upsampling.
  final double _cutoff;

  /// `phases * taps` coefficients.
  late final Float64List _coeffs;

  /// The last `taps - 1` input samples, oldest first.
  late Float32List _hist;

  /// How many entries of [_hist] are currently valid.
  int _histFill = 0;

  /// Fractional read position within the retained history, carried between
  /// calls so block boundaries do not introduce a phase discontinuity.
  double _frac = 0.0;

  /// Scratch space holding padding, history plus the incoming block.
  Float32List _scratch = Float32List(0);

  /// Leading zeros in [_scratch], one filter window long.
  int get _pad => taps;

  bool _disposed = false;

  /// True when the input rate already matches the output rate.
  bool get isPassthrough => inputRate == outputRate;

  void _buildFilter() {
    final int half = taps ~/ 2;
    _coeffs = Float64List(phases * taps);
    // Retain a full filter window, not just half. After producing output the
    // next read position can still be up to `taps` samples behind the end of
    // the block, so a half-window history would make the following call read
    // before the start of its buffer.
    _hist = Float32List(taps);

    for (int p = 0; p < phases; p++) {
      final double frac = p / phases;
      // The kernel peak sits at half + frac, so an interpolated sample lines
      // up with base + frac and the resampler adds no phase error.
      final double centre = half + frac;
      double sum = 0.0;
      for (int k = 0; k < taps; k++) {
        final double x = k - centre;
        // Windowed sinc: an ideal low-pass times a Blackman window, scaled by
        // the decimation ratio.
        final double sinc = x == 0.0
            ? _cutoff
            : math.sin(math.pi * _cutoff * x) / (math.pi * x);
        final double w = 0.42 -
            0.5 * math.cos(2.0 * math.pi * k / (taps - 1)) +
            0.08 * math.cos(4.0 * math.pi * k / (taps - 1));
        final double c = sinc * w * _step;
        _coeffs[p * taps + k] = c;
        sum += c;
      }
      // Normalise each branch to unity DC gain. A branch convolves the input
      // on its own, so a constant signal must survive every branch unchanged;
      // scaling the taps preserves the low-pass shape.
      if (sum.abs() > 1e-12) {
        for (int k = 0; k < taps; k++) {
          _coeffs[p * taps + k] /= sum;
        }
      }
    }
  }

  /// Feeds [samples] and returns whatever is ready at [outputRate].
  ///
  /// [samples] may be any length, including longer than the filter window.
  Float32List process(Float32List samples) {
    if (_disposed) {
      throw StateError('Resampler has been disposed');
    }
    if (isPassthrough) return samples;
    if (samples.isEmpty) return Float32List(0);

    final int half = taps ~/ 2;
    final int n = samples.length;

    // Scratch layout: [_pad zeros][retained history][new block].
    // The padding is half a window plus a margin, so the first output can
    // centre its window on sample 0 without running off the front.
    final int need = _pad + _histFill + n;
    if (_scratch.length < need) {
      _scratch = Float32List(need + 4096);
      _scratch.fillRange(0, _pad, 0.0);
    }
    if (_histFill > 0) {
      _scratch.setRange(_pad, _pad + _histFill, _hist);
    }
    _scratch.setRange(_pad + _histFill, need, samples);

    // The data region runs from _pad to need, i.e. `_avail` samples. The last
    // output may place its kernel centre at most `half` before the end.
    final int avail = need - _pad;
    final double span = avail - half - _frac;
    if (span < 0.0) {
      _retain(need, _pad + (_frac.floor() - half));
      return Float32List(0);
    }
    final int produced = (span / _step).floor() + 1;

    final Float32List out = Float32List(produced);
    for (int i = 0; i < produced; i++) {
      // Position within the data region, then split into whole and fractional
      // parts. The window is centred on this position.
      final double t = _frac + i * _step;
      final int whole = t.floor();
      final double frac = t - whole;
      final int phase = (frac * phases).floor().clamp(0, phases - 1);
      final int coeffBase = phase * taps;
      final int offset = _pad + whole - half;

      double acc = 0.0;
      for (int k = 0; k < taps; k++) {
        acc += _coeffs[coeffBase + k] * _scratch[offset + k];
      }
      out[i] = acc;
    }

    // Carry the position forward. Retain from where the next window will
    // start, then express the carry relative to that new origin: it is
    // `half` plus the leftover fraction.
    final double nextT = _frac + produced * _step;
    _retain(need, _pad + nextT.floor() - half);
    _frac = nextT - nextT.floor() + half;
    return out;
  }

  /// Keeps the samples from [from] to the end of the scratch buffer as history
  /// for the next call.
  ///
  /// Copies element by element rather than via `sublist`, so this never
  /// allocates and cannot go out of range.
  void _retain(int need, int from) {
    final int start = math.max(_pad, from);
    final int keep = math.min(_hist.length, need - start);
    if (keep <= 0) {
      _histFill = 0;
      return;
    }
    for (int i = 0; i < keep; i++) {
      _hist[i] = _scratch[start + i];
    }
    _histFill = keep;
  }

  /// Discards filter state, so audio from a previous stream cannot bleed
  /// into the next one.
  void reset() {
    _hist.fillRange(0, _hist.length, 0.0);
    _histFill = 0;
    _frac = 0.0;
  }

  void dispose() {
    _disposed = true;
  }
}