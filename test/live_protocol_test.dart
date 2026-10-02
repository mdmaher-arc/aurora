import 'dart:convert';
import 'dart:typed_data';

import 'package:aurora/live/live_messages.dart';
import 'package:aurora/live/protocol_constants.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> setupFor(LiveSessionConfig config) =>
    config.buildSetup()['setup'] as Map<String, dynamic>;

Map<String, dynamic> realtime(Map<String, dynamic> msg) =>
    msg['realtimeInput'] as Map<String, dynamic>;

void main() {
  group('setup frame', () {
    test('targets the 3.8 live model and requests audio output', () {
      final Map<String, dynamic> setup = setupFor(const LiveSessionConfig());
      expect(setup['model'], 'models/gemini-3.8-live');

      final Map<String, dynamic> gen =
          setup['generationConfig'] as Map<String, dynamic>;
      expect(gen['responseModalities'], <String>['AUDIO']);
    });

    test('uses the verified sensitivity enum names', () {
      final Map<String, dynamic> setup = setupFor(const LiveSessionConfig());
      final Map<String, dynamic> ric =
          setup['realtimeInputConfig'] as Map<String, dynamic>;
      final Map<String, dynamic> aad =
          ric['automaticActivityDetection'] as Map<String, dynamic>;

      // These exact strings were wrong in an earlier draft of this project.
      expect(aad['startOfSpeechSensitivity'], 'START_SENSITIVITY_HIGH');
      expect(aad['endOfSpeechSensitivity'], 'END_SENSITIVITY_HIGH');
      expect(ric['activityHandling'], 'START_OF_ACTIVITY_INTERRUPTS');
      expect(ric['turnCoverage'], 'TURN_INCLUDES_ONLY_ACTIVITY');
    });

    test('omits thinkingConfig, which 3.8 live rejects', () {
      final Map<String, dynamic> setup = setupFor(const LiveSessionConfig());
      expect(setup.containsKey('thinkingConfig'), isFalse);
      final Map<String, dynamic> gen =
          setup['generationConfig'] as Map<String, dynamic>;
      expect(gen.containsKey('thinkingConfig'), isFalse);
    });

    test('omits proactiveAudio, permanently enabled on 3.8', () {
      final Map<String, dynamic> setup = setupFor(const LiveSessionConfig());
      expect(setup.containsKey('proactiveAudio'), isFalse);
    });

    test('nests compression as slidingWindow.targetTokens', () {
      final Map<String, dynamic> setup = setupFor(const LiveSessionConfig());
      final Map<String, dynamic> cwc =
          setup['contextWindowCompression'] as Map<String, dynamic>;
      expect(cwc['triggerTokens'], 25000);

      // The inner key is targetTokens, not "slidingWindowSize".
      final Map<String, dynamic> window =
          cwc['slidingWindow'] as Map<String, dynamic>;
      expect(window['targetTokens'], 8000);
    });

    test('sends sessionResumption, omitting an absent handle', () {
      final Map<String, dynamic> fresh = setupFor(const LiveSessionConfig());
      final Map<String, dynamic> resumption =
          fresh['sessionResumption'] as Map<String, dynamic>;
      expect(resumption.containsKey('handle'), isFalse);

      final Map<String, dynamic> resumed = setupFor(
        const LiveSessionConfig(resumeHandle: 'abc123'),
      );
      expect(
        (resumed['sessionResumption'] as Map<String, dynamic>)['handle'],
        'abc123',
      );
    });

    test('disables server VAD when asked, enabling activity signals', () {
      final Map<String, dynamic> setup = setupFor(
        const LiveSessionConfig(enableServerVad: false),
      );
      final Map<String, dynamic> ric =
          setup['realtimeInputConfig'] as Map<String, dynamic>;
      final Map<String, dynamic> aad =
          ric['automaticActivityDetection'] as Map<String, dynamic>;
      expect(aad['disabled'], isTrue);
    });

    test('applies the selected voice', () {
      final Map<String, dynamic> setup = setupFor(
        const LiveSessionConfig(voiceName: 'Charon'),
      );
      final Map<String, dynamic> gen =
          setup['generationConfig'] as Map<String, dynamic>;
      final Map<String, dynamic> speech =
          gen['speechConfig'] as Map<String, dynamic>;
      final Map<String, dynamic> voice =
          (speech['voiceConfig'] as Map<String, dynamic>)[
              'prebuiltVoiceConfig'] as Map<String, dynamic>;
      expect(voice['voiceName'], 'Charon');
    });

    test('includes transcriptions only when configured', () {
      final Map<String, dynamic> bare = setupFor(const LiveSessionConfig());
      expect(bare.containsKey('inputAudioTranscription'), isFalse);
      expect(bare.containsKey('outputAudioTranscription'), isFalse);

      final Map<String, dynamic> full = setupFor(
        const LiveSessionConfig(
          inputTranscription: AudioTranscriptionConfig(),
          outputTranscription: AudioTranscriptionConfig(),
        ),
      );
      expect(full.containsKey('inputAudioTranscription'), isTrue);
      expect(full.containsKey('outputAudioTranscription'), isTrue);
    });

    test('is JSON-encodable, as the socket requires', () {
      final String encoded =
          jsonEncode(const LiveSessionConfig().buildSetup());
      expect(encoded, contains('"setup"'));
      expect(() => jsonDecode(encoded), returnsNormally);
    });
  });

  group('realtime input messages', () {
    test('wraps audio with the 16 kHz mime type', () {
      final Uint8List pcm = Uint8List(AudioFormat.inputChunkBytes);
      final Map<String, dynamic> audio =
          realtime(LiveMessages.audio(pcm))['audio']
              as Map<String, dynamic>;

      expect(audio['mimeType'], 'audio/pcm;rate=16000');
      expect(audio['data'], base64Encode(pcm));
      // 20 ms at 16 kHz mono PCM16.
      expect(AudioFormat.inputChunkBytes, 640);
    });

    test('sends audioStreamEnd as a boolean flag', () {
      expect(realtime(LiveMessages.audioStreamEnd())['audioStreamEnd'], isTrue);
    });

    test('sends activity signals as empty objects', () {
      expect(
        realtime(LiveMessages.activityStart())['activityStart'],
        isA<Map<String, dynamic>>(),
      );
      expect(
        realtime(LiveMessages.activityEnd())['activityEnd'],
        isA<Map<String, dynamic>>(),
      );
    });
  });

  group('client content and tools', () {
    test('builds a text turn marked complete', () {
      final Map<String, dynamic> cc =
          LiveMessages.clientContent('hello there')['clientContent']
              as Map<String, dynamic>;
      expect(cc['turnComplete'], isTrue);

      final Map<String, dynamic> turn =
          (cc['turns'] as List<dynamic>).first as Map<String, dynamic>;
      expect(turn['role'], 'user');
      final Map<String, dynamic> part =
          (turn['parts'] as List<dynamic>).first as Map<String, dynamic>;
      expect(part['text'], 'hello there');
    });

    test('can leave a turn open', () {
      final Map<String, dynamic> cc =
          LiveMessages.clientContent('keep listening', turnComplete: false)[
              'clientContent'] as Map<String, dynamic>;
      expect(cc['turnComplete'], isFalse);
    });

    test('pairs tool response ids with their payloads', () {
      final Map<String, dynamic> msg = LiveMessages.toolResponse(
        <String, Map<String, dynamic>>{
          'call_1': <String, dynamic>{'tempC': 22},
        },
      );
      final List<dynamic> responses =
          (msg['toolResponse'] as Map<String, dynamic>)['functionResponses']
              as List<dynamic>;
      final Map<String, dynamic> first =
          responses.first as Map<String, dynamic>;
      expect(first['id'], 'call_1');
      expect((first['response'] as Map<String, dynamic>)['tempC'], 22);
    });
  });
}