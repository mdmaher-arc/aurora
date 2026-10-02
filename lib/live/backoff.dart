import 'dart:math' as math;

/// Exponential backoff with jitter, used for reconnect attempts.
///
/// Jitter matters more than the base delay here: without it, many clients
/// reconnecting after a server-side reset all retry at the same instant.
class Backoff {
  Backoff({
    this.initial = const Duration(milliseconds: 500),
    this.maximum = const Duration(seconds: 30),
    this.multiplier = 1.8,
    this.jitter = 0.3,
  });

  final Duration initial;
  final Duration maximum;
  final double multiplier;

  /// Fraction of the delay that is randomised, 0..1.
  final double jitter;

  final math.Random _random = math.Random();
  int _attempt = 0;

  int get attempts => _attempt;

  /// Returns the delay for the next attempt and advances the counter.
  Duration next() {
    final double base =
        initial.inMilliseconds * math.pow(multiplier, _attempt).toDouble();
    final double capped = math.min(base, maximum.inMilliseconds.toDouble());
    final double spread = capped * jitter;
    final double offset = (_random.nextDouble() * 2 - 1) * spread;
    final int millis = math.max(50, (capped + offset).round());
    _attempt++;
    return Duration(milliseconds: millis);
  }

  /// Call after a successful connection.
  void reset() => _attempt = 0;
}