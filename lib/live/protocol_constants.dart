/// Wire-format constants for the Gemini Live API.
///
/// Every value here is verified against Google's published reference
/// (https://ai.google.dev/api/live) for the `v1beta` Live endpoint.
library;

/// The Live endpoint host.
const String kLiveHost = 'generativelanguage.googleapis.com';

/// Ephemeral tokens are only valid on `v1beta`.
const String kLivePath =
    '/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent';

/// Model ids currently served by the Live API.
class LiveModels {
  /// Default choice for low-latency voice agents.
  static const String gemini38Live = 'gemini-3.8-live';

  /// Same, with configurable background reasoning.
  static const String gemini38LiveExtendedThinking =
      'gemini-3.8-live-extended-thinking';

  /// Legacy preview.
  static const String gemini31FlashLivePreview =
      'gemini-3.1-flash-live-preview';

  static const List<String> all = <String>[
    gemini38Live,
    gemini38LiveExtendedThinking,
    gemini31FlashLivePreview,
  ];
}

/// Audio format contract. The server expects exactly these rates.
class AudioFormat {
  /// Raw 16-bit little-endian PCM expected on input.
  static const int inputSampleRate = 16000;

  /// Model audio arrives at this rate.
  static const int outputSampleRate = 24000;

  static const int bytesPerSample = 2;

  /// Google's recommended realtime chunk size is 20-40 ms. We use 20 ms,
  /// the lowest-latency end of that band.
  static const int chunkMillis = 20;

  /// 16000 Hz * 0.020 s * 2 bytes = 640 bytes per chunk.
  static const int inputChunkBytes =
      inputSampleRate * chunkMillis ~/ 1000 * bytesPerSample;

  /// 24000 Hz * 0.020 s * 2 bytes = 960 bytes of playback per chunk.
  static const int outputChunkBytes =
      outputSampleRate * chunkMillis ~/ 1000 * bytesPerSample;

  /// Samples in one input chunk.
  static const int inputChunkSamples = inputChunkBytes ~/ bytesPerSample;

  static const String inputMimeType = 'audio/pcm;rate=16000';
  static const String outputMimeType = 'audio/pcm;rate=24000';
}

/// `RealtimeInputConfig.AutomaticActivityDetection.StartSensitivity`.
enum StartSensitivity {
  unspecified('START_SENSITIVITY_UNSPECIFIED'),

  /// Default. Detects speech onset more eagerly.
  high('START_SENSITIVITY_HIGH'),

  low('START_SENSITIVITY_LOW');

  const StartSensitivity(this.wireName);
  final String wireName;
}

/// `RealtimeInputConfig.AutomaticActivityDetection.EndSensitivity`.
///
/// The server default when unspecified is [high].
enum EndSensitivity {
  unspecified('END_SENSITIVITY_UNSPECIFIED'),

  /// Default. Ends speech more often.
  high('END_SENSITIVITY_HIGH'),

  low('END_SENSITIVITY_LOW');

  const EndSensitivity(this.wireName);
  final String wireName;
}

/// How incoming activity interacts with model output.
enum ActivityHandling {
  unspecified('ACTIVITY_HANDLING_UNSPECIFIED'),

  /// Default. User speech cuts the model off (barge-in).
  startOfActivityInterrupts('START_OF_ACTIVITY_INTERRUPTS'),

  /// The model finishes its response before yielding.
  noInterruption('NO_INTERRUPTION');

  const ActivityHandling(this.wireName);
  final String wireName;
}

/// Which realtime input counts as part of the user's turn.
///
/// Gemini 3.1+ defaults to [turnIncludesAudioActivityAndAllVideo], which keeps
/// idle silence in the context and bills for it. A voice assistant wants
/// [turnIncludesOnlyActivity].
enum TurnCoverage {
  unspecified('TURN_COVERAGE_UNSPECIFIED'),
  turnIncludesOnlyActivity('TURN_INCLUDES_ONLY_ACTIVITY'),
  turnIncludesAllInput('TURN_INCLUDES_ALL_INPUT'),
  turnIncludesAudioActivityAndAllVideo(
    'TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO',
  );

  const TurnCoverage(this.wireName);
  final String wireName;
}

  /// 16000 Hz * 0.020 s * 2 bytes = 640 bytes per chunk.
/// Transcription post-processing mode.
enum TranscriptionMode {
  unspecified('MODE_UNSPECIFIED'),

  /// Default. Compatible with timestamps and diarization.
  verbatim('VERBATIM'),

  /// Removes disfluencies and formats the text. Incompatible with word
  /// timestamps and diarization.
  smart('SMART');

  const TranscriptionMode(this.wireName);
  final String wireName;
}

/// `AudioTranscriptionConfig`.
class AudioTranscriptionConfig {
  const AudioTranscriptionConfig({
    this.languageCodes = const <String>[],
    this.customVocabulary = const <String>[],
    this.wordTimestamp = false,
    this.diarization = false,
    this.mode = TranscriptionMode.verbatim,
  });

  /// Empty means automatic language detection.
  final List<String> languageCodes;
  final List<String> customVocabulary;
  final bool wordTimestamp;
  final bool diarization;
  final TranscriptionMode mode;

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> json = <String, dynamic>{
      'mode': mode.wireName,
    };
    if (languageCodes.isNotEmpty) json['languageCodes'] = languageCodes;
    if (customVocabulary.isNotEmpty) {
      json['customVocabulary'] = customVocabulary;
    }
    if (wordTimestamp) json['wordTimestamp'] = true;
    if (diarization) json['diarization'] = true;
    return json;
  }
}

/// Prebuilt voices available to the native-audio models.
class Voices {
  static const List<String> all = <String>[
    'Puck',
    'Charon',
    'Kore',
    'Fenrir',
    'Aoede',
    'Leda',
    'Orus',
    'Zephyr',
  ];

  static const String defaultVoice = 'Kore';
}

/// WebSocket close codes relevant to this client.
class CloseCodes {
  /// Normal closure.
  static const int normal = 1000;

  /// Unparseable data or a contract violation.
  static const int protocolError = 1002;

  /// Data of an unacceptable type.
  static const int unsupportedData = 1003;

  /// Invalid payload. Google also uses this to reject `activityStart`/
  /// `activityEnd` sent while server-side VAD is still enabled.
  static const int invalidPayload = 1007;

  /// Policy violation, typically an invalid or unauthorized API key.
  static const int policyViolation = 1008;

  /// Message too large. Oversized audio chunks land here.
  static const int messageTooBig = 1009;

  /// Internal server error.
  static const int internalError = 1011;

  /// Human-readable explanation for a close code.
  static String describe(int? code, String? reason) {
    if (code == null) return reason ?? 'Connection closed';
    final String suffix = (reason == null || reason.isEmpty) ? '' : ': $reason';
    switch (code) {
      case normal:
        return 'Closed normally$suffix';
      case policyViolation:
        return 'Rejected by the server. Check your API key and account '
            'permissions$suffix';
      case invalidPayload:
        return 'The server rejected a message as invalid. If you are using '
            'manual VAD, activity signals are only legal while server VAD is '
            'disabled$suffix';
      case messageTooBig:
        return 'A message was too large. Reduce the audio chunk size$suffix';
      case protocolError:
      case unsupportedData:
        return 'Protocol error from the server$suffix';
      case internalError:
        return 'The server hit an internal error$suffix';
      default:
        return 'Connection closed ($code)$suffix';
    }
  }
}