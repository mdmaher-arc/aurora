import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../live/live_messages.dart';
import '../state/session_controller.dart';
import 'widgets/pulse_orb.dart';
import 'onboarding_screen.dart';

/// Chooses between onboarding and the conversation view.
///
/// Onboarding stays up until a session actually connects, so a bad API key
/// leaves the user on the setup form with an error rather than stranded on an
/// empty conversation screen.
class RootRouter extends StatelessWidget {
  const RootRouter({required this.onStart, super.key});

  final Future<void> Function(String apiKey, LiveSessionConfig config) onStart;

  @override
  Widget build(BuildContext context) {
    final bool started = context.select<SessionController, bool>(
      (SessionController s) => s.isConnected,
    );
    if (started) return const ConversationScreen();
    return OnboardingScreen(onStart: onStart);
  }
}

/// Live conversation view.
class ConversationScreen extends StatelessWidget {
  const ConversationScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final SessionController session = context.watch<SessionController>();
    final ThemeData theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Aurora'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Clear transcript',
            onPressed: session.clearTranscript,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (session.errorMessage.isNotEmpty)
            MaterialBanner(
              content: Text(session.errorMessage),
              actions: <Widget>[
                TextButton(
                  onPressed: () => session.reportError(''),
                  child: const Text('Dismiss'),
                ),
              ],
            ),
          Expanded(
            child: ListView(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
              children: <Widget>[
                for (final TranscriptLine line in session.lines)
                  _Bubble(
                    speaker: line.speaker,
                    text: line.text,
                    isUser: line.speaker == TranscriptSpeaker.user,
                  ),
                if (session.interimUserText.isNotEmpty)
                  _Bubble(
                    speaker: TranscriptSpeaker.user,
                    text: session.interimUserText,
                    isUser: true,
                    isInterim: true,
                  ),
                if (session.interimModelText.isNotEmpty)
                  _Bubble(
                    speaker: TranscriptSpeaker.model,
                    text: session.interimModelText,
                    isUser: false,
                    isInterim: true,
                  ),
              ],
            ),
          ),
          PulseOrb(
            status: session.status,
            inputLevel: session.inputLevel,
            outputLevel: session.outputLevel,
          ),
          if (session.bargeInDetected)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Text(
                'Interrupting. Headphones reduce echo pickup on speakerphone.',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
          _Composer(session: session),
        ],
      ),
    );
  }
}

class _Composer extends StatefulWidget {
  const _Composer({required this.session});

  final SessionController session;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  final TextEditingController _input = TextEditingController();

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _send() {
    final String text = _input.text;
    if (text.trim().isEmpty) return;
    widget.session.sendText(text);
    _input.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
      child: Row(
        children: <Widget>[
          IconButton.filledTonal(
            tooltip: widget.session.isMicMuted ? 'Unmute' : 'Mute',
            onPressed: widget.session.toggleMicMute,
            icon: Icon(widget.session.isMicMuted ? Icons.mic_off : Icons.mic),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _input,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: const InputDecoration(
                hintText: 'Type a message',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 12),
          IconButton.filled(
            onPressed: _send,
            icon: const Icon(Icons.arrow_upward),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.speaker,
    required this.text,
    required this.isUser,
    this.isInterim = false,
  });

  final String speaker;
  final String text;
  final bool isUser;
  final bool isInterim;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
        ),
        decoration: BoxDecoration(
          color: isUser
              ? theme.colorScheme.primaryContainer
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(speaker, style: theme.textTheme.labelSmall),
            const SizedBox(height: 2),
            Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: isInterim ? FontStyle.italic : null,
                color: isInterim
                    ? theme.colorScheme.onSurfaceVariant
                    : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}