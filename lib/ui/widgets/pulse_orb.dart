import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../state/session_controller.dart';

/// Animated orb that reacts to live audio levels.
///
/// The radius follows whichever side is currently active: the user's input
/// while listening, the model's output while speaking. This gives immediate
/// visual feedback that the mic is live, which matters more than decoration
/// when you cannot hear yourself.
class PulseOrb extends StatefulWidget {
  const PulseOrb({
    required this.status,
    required this.inputLevel,
    required this.outputLevel,
    super.key,
  });

  final SessionStatus status;
  final double inputLevel;
  final double outputLevel;

  @override
  State<PulseOrb> createState() => _PulseOrbState();
}

class _PulseOrbState extends State<PulseOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 90),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color _color(ColorScheme scheme) {
    switch (widget.status) {
      case SessionStatus.speaking:
        return scheme.tertiary;
      case SessionStatus.listening:
        return scheme.primary;
      case SessionStatus.error:
        return scheme.error;
      case SessionStatus.connecting:
      case SessionStatus.reconnecting:
        return scheme.secondary;
      case SessionStatus.idle:
        return scheme.outline;
    }
  }

  String get _label {
    switch (widget.status) {
      case SessionStatus.speaking:
        return 'Gemini is speaking';
      case SessionStatus.listening:
        return 'Listening';
      case SessionStatus.error:
        return 'Connection problem';
      case SessionStatus.connecting:
        return 'Connecting';
      case SessionStatus.reconnecting:
        return 'Reconnecting';
      case SessionStatus.idle:
        return 'Idle';
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color color = _color(scheme);
    // While speaking, ignore the mic level: the speaker is what is active.
    final double level = widget.status == SessionStatus.speaking
        ? widget.outputLevel
        : widget.inputLevel;
    final double t = Curves.easeOut.transform(
      (level * 6).clamp(0.0, 1.0).toDouble(),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: <Widget>[
          AnimatedBuilder(
            animation: _controller,
            builder: (BuildContext context, Widget? child) {
              // A slow idle breath, so the orb never looks frozen.
              final double breath =
                  1.0 + 0.04 * math.sin(_controller.value * 2 * math.pi);
              final double scale = (0.62 + 0.38 * t) * breath;
              return Container(
                width: 96 * scale,
                height: 96 * scale,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: 0.18 + 0.22 * t),
                  border: Border.all(
                    color: color.withValues(alpha: 0.55),
                    width: 1.5,
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          Text(
            _label,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    );
  }
}