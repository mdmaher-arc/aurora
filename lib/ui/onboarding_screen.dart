import 'package:flutter/material.dart';

import '../live/live_messages.dart';
import '../live/protocol_constants.dart';

/// First-run screen: API key, model, voice and persona.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({required this.onStart, super.key});

  /// Called with the key and the assembled session configuration.
  final Future<void> Function(String apiKey, LiveSessionConfig config) onStart;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _personaController =
      TextEditingController(text: LiveSessionConfig.defaultSystemInstruction);
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  String _model = LiveModels.gemini38Live;
  String _voice = Voices.defaultVoice;
  bool _obscure = true;
  bool _busy = false;

  @override
  void dispose() {
    _keyController.dispose();
    _personaController.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _busy = true);
    try {
      await widget.onStart(
        _keyController.text.trim(),
        LiveSessionConfig(
          model: _model,
          voiceName: _voice,
          systemInstruction: _personaController.text.trim(),
          inputTranscription: const AudioTranscriptionConfig(),
          outputTranscription: const AudioTranscriptionConfig(),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: <Widget>[
                  Text('Aurora', style: theme.textTheme.headlineMedium),
                  const SizedBox(height: 8),
                  Text(
                    'A low-latency voice assistant on the Gemini Live API.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _keyController,
                    obscureText: _obscure,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLines: 1,
                    decoration: InputDecoration(
                      labelText: 'Gemini API key',
                      helperText: 'Held in memory for this session only.',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscure ? Icons.visibility : Icons.visibility_off,
                        ),
                        onPressed: () => setState(() => _obscure = !_obscure),
                      ),
                    ),
                    validator: (String? value) =>
                        (value == null || value.trim().isEmpty)
                            ? 'Enter your API key'
                            : null,
                  ),
                  const SizedBox(height: 20),
                  DropdownButtonFormField<String>(
                    initialValue: _model,
                    decoration: const InputDecoration(
                      labelText: 'Model',
                      border: OutlineInputBorder(),
                    ),
                    items: <DropdownMenuItem<String>>[
                      for (final String model in LiveModels.all)
                        DropdownMenuItem<String>(
                          value: model,
                          child: Text(model),
                        ),
                    ],
                    onChanged: (String? v) =>
                        setState(() => _model = v ?? _model),
                  ),
                  const SizedBox(height: 20),
                  DropdownButtonFormField<String>(
                    initialValue: _voice,
                    decoration: const InputDecoration(
                      labelText: 'Voice',
                      border: OutlineInputBorder(),
                    ),
                    items: <DropdownMenuItem<String>>[
                      for (final String voice in Voices.all)
                        DropdownMenuItem<String>(
                          value: voice,
                          child: Text(voice),
                        ),
                    ],
                    onChanged: (String? v) =>
                        setState(() => _voice = v ?? _voice),
                  ),
                  const SizedBox(height: 20),
                  TextFormField(
                    controller: _personaController,
                    maxLines: 8,
                    minLines: 5,
                    decoration: const InputDecoration(
                      labelText: 'System instructions',
                      helperText:
                          'Persona first, then conversational rules, then '
                          'guardrails.',
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                    ),
                  ),
                  const SizedBox(height: 28),
                  FilledButton.icon(
                    onPressed: _busy ? null : _start,
                    icon: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.mic),
                    label: Text(_busy ? 'Connecting...' : 'Start talking'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}