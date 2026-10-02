# Aurora — a Gemini Live voice assistant in Flutter

A low-latency, full-duplex voice assistant built on the **Gemini Live API**
(`gemini-3.8-live`). You supply a Gemini API key; the app opens a WebSocket to
the Live endpoint and holds a live audio conversation.

---

## What is implemented

| Area | File | Notes |
|---|---|---|
| Wire protocol | `lib/live/live_messages.dart` | `setup`, `realtimeInput`, `clientContent`, `toolResponse` builders |
| Wire constants | `lib/live/protocol_constants.dart` | Models, audio formats, VAD/sensitivity enums, close codes |
| Server decoding | `lib/live/server_message.dart` | `setupComplete`, `serverContent`, `toolCall`, `goAway`, resumption, usage |
| Socket + lifecycle | `lib/live/live_client.dart` | GoAway, session resumption, jittered reconnect |
| Backoff | `lib/live/backoff.dart` | Exponential with jitter |
| Resampling | `lib/audio/resampler.dart` | Streaming polyphase FIR, 48k/44.1k → 16k |
| Voice activity | `lib/audio/vad.dart` | Adaptive noise floor + ZCR + hangover, plus a ring buffer |
| Jitter buffer | `lib/audio/playback_queue.dart` | Adaptive target depth, hard flush for barge-in |
| PCM helpers | `lib/audio/pcm.dart` | s16le encode/decode, RMS, peak, ZCR |
| Microphone | `lib/audio/mic_capture.dart` | `record` with `echoCancel` / `noiseSuppress` / `autoGain` |
| Playback | `lib/main.dart` (`SoloudSink`) | `flutter_soloud` buffer stream, 24 kHz mono s16le |
| Orchestration | `lib/state/session_controller.dart` | Pipeline, transcripts, local barge-in |
| UI | `lib/ui/` | Onboarding, conversation, reactive orb |

### Audio contract

* Input: raw PCM16 LE, **16 kHz mono**, sent as **20 ms / 640-byte** chunks.
  This sits at the low-latency end of Google's recommended 20–40 ms band, and
  nothing is ever batched before sending.
* Output: raw PCM16 LE, **24 kHz mono**.
* Capture runs at 48 kHz and is resampled in-process.

### Latency and interruption handling

* **Local barge-in.** The VAD detects speech onset and flushes playback
  immediately, rather than waiting for the server's `interrupted: true`. The
  server flag is then treated as confirmation and queue hygiene.
* **Adaptive jitter buffer.** Starts at 240 ms, shrinks on underrun, grows
  when the model consistently outruns playback.
* **Context window compression** (`triggerTokens` 25 000,
  `slidingWindow.targetTokens` 8 000) removes the 15-minute session cap.
* **Session resumption.** The latest resumption handle is retained and
  ---

## Verified behaviour

`flutter test` — **25 tests, all passing.** These are behavioural tests, not
smoke tests; each caught a real defect during development:

* Resampler passband accuracy and out-of-band rejection at 48k → 16k.
* Constant output gain across input chunk sizes of 320 / 1024 / 4096 samples.
* Output continuity with no gaps across successive blocks.
* Non-integer 44.1 kHz → 16 kHz conversion.
* Exact wire-format assertions for the `setup` frame and every client message.

Filter response measured with an independent probe (63-tap Blackman-windowed
sinc, 256 polyphase branches):

| Frequency | Gain |
|---|---|
| 100 Hz – 3.8 kHz | ±0.3 dB (flat passband) |
| 8.6 kHz | −12 dB |
| 13.0 kHz | −31 dB |
| 19.5 kHz | −36 dB |

DC gain is 1.000 per polyphase branch, and a 300 Hz tone reconstructs with
correlation 1.0000 against the ideal reference.

---

## Protocol details worth knowing

These were checked against Google's reference rather than assumed, and a few
differ from commonly circulated examples:

* Sensitivity enums are `START_SENSITIVITY_HIGH` / `END_SENSITIVITY_HIGH`,
  **not** `START_OF_SPEECH_SENSITIVITY_*`.
* Context compression nests as
  `{"triggerTokens": N, "slidingWindow": {"targetTokens": M}}`.
* `activityStart` / `activityEnd` are **only legal while server VAD is
  disabled**. With automatic detection on, the server rejects them.
  `LiveSessionConfig.enableServerVad` gates this; the default is server VAD on
  and manual signals unused.
* `audioStreamEnd` is the opposite: only valid while server VAD is **on**.
* `thinkingConfig` / `thinkingLevel` are rejected by `gemini-3.8-live` and are
  deliberately never sent.
* `proactiveAudio` is permanently enabled on 3.8 and errors if set false, so it
  is never sent.
* `turnCoverage` is set to `TURN_INCLUDES_ONLY_ACTIVITY`; the 3.1+ default
  keeps idle silence in the context and bills for it.

---

## Security

The API key is held in memory for the running session only. It is not written
to disk and is never logged or displayed in full.

**This is not suitable for shipping to end users as-is.** A key compiled into
an app is extractable. For production, use an ephemeral-token broker: your
backend calls `POST https://generativelanguage.googleapis.com/v1beta/auth_tokens`
and hands the short-lived token to the client, which passes it as
`access_token=` on the WebSocket. `LiveClient.buildUri` already detects a
`tokens/...` key and uses the right query parameter.

---

## Running it

```powershell
flutter pub get
flutter run -d windows     # or android / ios / chrome
```

Paste your Gemini API key on the first screen, pick a voice and persona, and
press **Start talking**.

---

## Known limitations

* **Echo cancellation depends on the platform.** `record` maps
  `echoCancel` / `noiseSuppress` / `autoGain` onto each OS's own
  voice-communication DSP (Android AEC/NS/AGC, Apple voice-processing I/O), but
  support varies and Windows/Linux have no equivalent. On a laptop speakerphone
  the model may partially hear itself; headphones are the reliable fix. The
  `MicCapture` class is the seam where a native DSP implementation would go.
* **Output transcription costs extra.** It is billed as text output in addition
  to audio tokens. It is on by default for captions; disabling it is a
  one-line config change.
* **Proactive audio cannot be disabled** on `gemini-3.8-live`, so the model may
  speak unprompted. Muting the microphone is the available control.
* **No tools are registered.** If the server requests a function call, the
  client replies with an explicit "no tools configured" error rather than
  leaving the turn hanging. `LiveSessionConfig.tools` is wired but unpopulated.