import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:provider/provider.dart';

import 'audio/mic_capture.dart';
import 'live/live_messages.dart';
import 'live/protocol_constants.dart';
import 'state/session_controller.dart';
import 'ui/conversation_screen.dart';

void main() {
  runApp(const AuroraApp());
}

/// Playback backed by SoLoud, which covers Android, iOS, macOS, Windows,
/// Linux and web.
///
/// `setBufferStream` declares the 24 kHz mono s16le format once and returns an
/// `AudioSource`; chunks are then pushed into that source as they arrive.
/// SoLoud resamples to the hardware rate.
class SoloudSink implements AudioSink {
  /// Seconds of audio SoLoud wants buffered before it un-pauses. The package
  /// default is 2 s, which would add two seconds to every first word.
  static const double _bufferingTimeNeeds = 0.24;

  AudioSource? _source;
  bool _initialised = false;
  bool _playing = false;

  @override
  Future<void> prepare() async {
    if (!_initialised) {
      await SoLoud.instance.init();
      _initialised = true;
    }
    _source ??= SoLoud.instance.setBufferStream(
      bufferingType: BufferingType.preserved,
      bufferingTimeNeeds: _bufferingTimeNeeds,
      sampleRate: AudioFormat.outputSampleRate,
      channels: Channels.mono,
      format: BufferType.s16le,
      maxBufferSizeBytes: 1024 * 1024 * 10,
    );
    if (!_playing) {
      SoLoud.instance.play(_source!);
      _playing = true;
    }
  }

  @override
  void write(Uint8List chunk) {
    final AudioSource? source = _source;
    if (source == null || !_playing || chunk.isEmpty) return;
    SoLoud.instance.addAudioDataStream(source, chunk);
  }

  @override
  Future<void> flush() async {
    final AudioSource? source = _source;
    if (source == null) return;

    // Stop first, then reset the buffer. Resetting alone can leave the last
    // queued frame audible, which is exactly what barge-in must not do.
    SoLoud.instance.stopAudioSource(source);
    SoLoud.instance.resetBufferStream(source);
    _playing = false;
  }

  Future<void> disposeSink() async {
    if (_initialised) {
      SoLoud.instance.deinit();
      _initialised = false;
    }
    _source = null;
    _playing = false;
  }
}

class AuroraApp extends StatefulWidget {
  const AuroraApp({super.key});

  @override
  State<AuroraApp> createState() => _AuroraAppState();
}

class _AuroraAppState extends State<AuroraApp> {
  final SoloudSink _sink = SoloudSink();
  late final SessionController _controller = SessionController(sink: _sink);
  MicCapture? _mic;

  /// Capture rate we ask the platform for.
  static const int _captureRate = 48000;

  /// Brings up playback, capture and the live socket, in that order.
  Future<void> _start(String apiKey, LiveSessionConfig config) async {
    
    _mic ??= MicCapture();

    final bool micReady = await _mic!.start(
      onFrame: (Float32List samples, int rate) {
        _controller.onAudioCaptured(samples, rate);
      },
      requestedRate: _captureRate,
    );
    if (!micReady) {
      _controller.reportError(
        'Microphone permission was denied. Enable it in system settings.',
      );
      return;
    }

    await _controller.start(
      apiKey: apiKey,
      config: config,
      inputSampleRate: _captureRate,
    );
  }

  @override
  void dispose() {
    _mic?.dispose();
    _controller.dispose();
    _sink.disposeSink();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<SessionController>.value(
      value: _controller,
      child: MaterialApp(
        title: 'Aurora',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        ),
        darkTheme: ThemeData.dark(useMaterial3: true),
        home: RootRouter(onStart: _start),
      ),
    );
  }
}