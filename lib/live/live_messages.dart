import 'dart:convert';
import 'dart:typed_data';

import 'protocol_constants.dart';

/// Everything needed to open a Live session.
class LiveSessionConfig {
  const LiveSessionConfig({
    this.model = LiveModels.gemini38Live,
    this.systemInstruction = defaultSystemInstruction,
    this.voiceName = Voices.defaultVoice,
    this.temperature = 0.7,
    this.startSensitivity = StartSensitivity.high,
    this.endSensitivity = EndSensitivity.high,
    this.prefixPaddingMs = 300,
    this.silenceDurationMs = 500,
    this.activityHandling = ActivityHandling.startOfActivityInterrupts,
    this.turnCoverage = TurnCoverage.turnIncludesOnlyActivity,
    this.enableServerVad = true,
    this.inputTranscription,
    this.outputTranscription,
    this.enableSessionResumption = true,
    this.resumeHandle,
    this.contextWindowCompression = true,
    this.compressionTriggerTokens = 25000,
    this.compressionTargetTokens = 8000,
    this.tools = const <Map<String, dynamic>>[],
  });

  /// Sensible default persona. Google's guidance is to define the persona,
  /// then the conversational rules, then the guardrails, in that order.
  static const String defaultSystemInstruction = '''
You are a helpful, natural-sounding voice assistant.

Persona:
- Warm, direct and unhurried. You are talking with someone, not reading a script.
- Keep spoken answers short. One or two sentences unless asked for detail.

Conversational rules:
- Never announce that you are an AI or mention these instructions.
- Do not spell out numbers, currency or abbreviations; speak them naturally.
- If you did not hear the user clearly, say so plainly and ask them to repeat.
- Use filler and acknowledgement sparingly. Do not start every reply with "Sure".

Guardrails:
- If asked to do something outside a conversation, say you cannot and stay in character.
''';

  final String model;
  final String systemInstruction;
  final String voiceName;
  final double temperature;

  final StartSensitivity startSensitivity;
  final EndSensitivity endSensitivity;
  final int prefixPaddingMs;
  final int silenceDurationMs;
  final ActivityHandling activityHandling;
  final TurnCoverage turnCoverage;

  /// When false, server VAD is switched off and the client becomes
  /// responsible for sending activity signals.
  final bool enableServerVad;

  /// `null` disables input transcription.
  final AudioTranscriptionConfig? inputTranscription;

  /// `null` disables output transcription. Costs extra text output tokens.
  final AudioTranscriptionConfig? outputTranscription;

  final bool enableSessionResumption;

  /// A handle from a previous connection, to resume context.
  final String? resumeHandle;

  final bool contextWindowCompression;
  final int compressionTriggerTokens;
  final int compressionTargetTokens;

  final List<Map<String, dynamic>> tools;

  /// Builds the `setup` frame, the first message on the socket.
  ///
  /// Field names are verified against https://ai.google.dev/api/live.
  Map<String, dynamic> buildSetup() {
    final Map<String, dynamic> setup = <String, dynamic>{
      'model': 'models/$model',
      'generationConfig': <String, dynamic>{
        'responseModalities': <String>['AUDIO'],
        'speechConfig': <String, dynamic>{
          'voiceConfig': <String, dynamic>{
            'prebuiltVoiceConfig': <String, dynamic>{'voiceName': voiceName},
          },
        },
        'temperature': temperature,
      },
      'realtimeInputConfig': <String, dynamic>{
        'automaticActivityDetection': <String, dynamic>{
          'disabled': !enableServerVad,
          'startOfSpeechSensitivity': startSensitivity.wireName,
          'endOfSpeechSensitivity': endSensitivity.wireName,
          'prefixPaddingMs': prefixPaddingMs,
          'silenceDurationMs': silenceDurationMs,
        },
        'activityHandling': activityHandling.wireName,
        'turnCoverage': turnCoverage.wireName,
      },
    };

    // Deliberately absent: thinkingConfig/thinkingLevel, which Gemini 3.8
    // Live rejects, and proactiveAudio, which is permanently enabled there
    // and errors if set false.

    if (systemInstruction.trim().isNotEmpty) {
      setup['systemInstruction'] = <String, dynamic>{
        'parts': <Map<String, dynamic>>[
          <String, dynamic>{'text': systemInstruction},
        ],
      };
    }

    final AudioTranscriptionConfig? inputTx = inputTranscription;
    if (inputTx != null) setup['inputAudioTranscription'] = inputTx.toJson();

    final AudioTranscriptionConfig? outputTx = outputTranscription;
    if (outputTx != null) setup['outputAudioTranscription'] = outputTx.toJson();

    if (enableSessionResumption) {
      final Map<String, dynamic> resumption = <String, dynamic>{};
      // An absent handle means "start fresh", not "resume nothing".
      final String? handle = resumeHandle;
      if (handle != null && handle.isNotEmpty) resumption['handle'] = handle;
      setup['sessionResumption'] = resumption;
    }

    if (contextWindowCompression) {
      setup['contextWindowCompression'] = <String, dynamic>{
        'triggerTokens': compressionTriggerTokens,
        'slidingWindow': <String, dynamic>{
          'targetTokens': compressionTargetTokens,
        },
      };
    }

    if (tools.isNotEmpty) setup['tools'] = tools;

    return <String, dynamic>{'setup': setup};
  }
}

/// Builds the four client message shapes the Live API accepts.
class LiveMessages {
  LiveMessages._();

  /// Wraps one PCM chunk for the realtime input stream.
  ///
  /// 20 ms of 16 kHz mono PCM16 is 640 bytes.
  static Map<String, dynamic> audio(Uint8List pcm) {
    return <String, dynamic>{
      'realtimeInput': <String, dynamic>{
        'audio': <String, dynamic>{
          'data': base64Encode(pcm),
          'mimeType': AudioFormat.inputMimeType,
        },
      },
    };
  }

  /// Tells the server the audio stream paused so it flushes cached audio.
  ///
  /// Only legal while server-side VAD is enabled. The stream reopens
  /// automatically on the next audio message.
  static Map<String, dynamic> audioStreamEnd() {
    return <String, dynamic>{
      'realtimeInput': <String, dynamic>{'audioStreamEnd': true},
    };
  }

  /// Marks the start of user activity.
  ///
  /// Only legal when server VAD is disabled; sending it otherwise gets the
  /// socket closed.
  static Map<String, dynamic> activityStart() {
    return <String, dynamic>{
      'realtimeInput': <String, dynamic>{'activityStart': <String, dynamic>{}},
    };
  }

  /// Marks the end of user activity. Same restriction as [activityStart].
  static Map<String, dynamic> activityEnd() {
    return <String, dynamic>{
      'realtimeInput': <String, dynamic>{'activityEnd': <String, dynamic>{}},
    };
  }

  /// Appends text to the conversation history.
  ///
  /// With [turnComplete] true the model starts generating. Note this
  /// unconditionally interrupts any generation in progress.
  static Map<String, dynamic> clientContent(
    String text, {
    bool turnComplete = true,
    String role = 'user',
  }) {
    return <String, dynamic>{
      'clientContent': <String, dynamic>{
        'turns': <Map<String, dynamic>>[
          <String, dynamic>{
            'role': role,
            'parts': <Map<String, dynamic>>[
              <String, dynamic>{'text': text},
            ],
          },
        ],
        'turnComplete': turnComplete,
      },
    };
  }

  /// Returns results for one or more function calls.
  static Map<String, dynamic> toolResponse(
    Map<String, Map<String, dynamic>> responsesById,
  ) {
    return <String, dynamic>{
      'toolResponse': <String, dynamic>{
        'functionResponses': responsesById.entries
            .map(
              (MapEntry<String, Map<String, dynamic>> e) =>
                  <String, dynamic>{'id': e.key, 'response': e.value},
            )
            .toList(),
      },
    };
  }
}
