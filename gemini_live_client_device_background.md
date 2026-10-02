
> This document is a **client/device-side** “what’s happening in the background” resource for a **Gemini Live API**-style live voice session (audio-in/audio-out, optionally with video/text).  
> It’s written to match how real apps are built: some steps are **required by the Live API**, others are **common device/OS audio pipeline work** that most high-quality realtime voice apps do for latency, echo control, and stability.

---

## 0) Big picture: what the client device is responsible for

During a live Gemini session your device/app is simultaneously running:

- A **persistent bidirectional connection** (typically WebSocket) that stays open for the session. 
- A **realtime input pipeline** (mic → preprocessing → VAD/turning → chunking → transmit). 
- A **realtime output pipeline** (receive audio chunks → buffer/jitter control → schedule playback → handle barge‑in interruption instantly). 
- Optional **transcription streams** (interim/final input transcription + output transcription) that arrive asynchronously and can be out of order relative to audio/video. 
- Optional **tools/function calling** execution and cancellation handling. 
- **Session lifecycle management**: GoAway, reconnection, resumption handles, context compression tuning. 

---

## 1) Security & auth work on/around the device (often overlooked)

### 1.1 API keys vs ephemeral tokens (client-to-server)
If the device connects **directly** to Gemini Live (instead of your backend proxying audio), Google recommends **ephemeral tokens**: short‑lived tokens meant to reduce risk if extracted from a browser/mobile app. 

High-level flow (what the device + backend do):
1. Device authenticates to *your backend*.
2. Backend requests an ephemeral token from Gemini provisioning.
3. Backend sends the token to the device.
4. Device uses that token “like an API key” for the Live WebSocket connection. 

Important operational detail:
- Ephemeral tokens have default time limits (for starting sessions and for how long the connection can send messages). The docs also note you’ll typically use **session resumption** to reconnect periodically (around every ~10 minutes) without losing context. 

---

## 2) Session establishment (connection + setup)

### 2.1 Open a persistent, stateful connection
The device opens a secure, long‑lived connection (commonly WebSocket) and keeps it open while streaming input and receiving output. This is what makes it “live” rather than request/response. 

### 2.2 Send a setup/config message (modalities, VAD config, tools, etc.)
In Live API terms, the device sends a setup message and then receives `setupComplete` when the server is ready. 

What’s inside setup (typical categories):
- Response modalities (e.g., audio)
- Realtime input config (automatic VAD parameters or manual mode)
- Transcription config (if enabled)
- Tool declarations (if using function calling/search)
- Session resumption config (if you want resumption handles)
- Context window compression config (for long sessions) 

---

## 3) Audio capture & OS/hardware DSP preprocessing (device side)

This section is about “what the phone/PC audio stack usually does” before you even think about Gemini.

### 3.1 Mic capture and audio routing
The device must:
- Acquire mic permission and open the platform’s low-latency capture path.
- Manage audio routing changes (speaker/earpiece/Bluetooth), interruptions (phone calls), and audio focus/ducking (OS-specific).  
(Implementation varies by platform, but the client app always has to deal with it.)

### 3.2 Echo cancellation / noise suppression / gain control (AEC/NS/AGC)
To prevent the model from hearing itself (speaker output re-captured by mic) and to improve intelligibility, many realtime voice apps enable **voice preprocessing** such as:
- **AEC**: cancels far-end audio contribution from the captured mic signal. 
- **NS**: reduces background noise in the captured signal. 
- **AGC**: normalizes mic levels to a more constant loudness. 

Examples of how this is exposed:
- Android exposes AEC/NS/AGC as capture-path preprocessors in `android.media.audiofx` (device support varies; some sources enable effects by default depending on the `AudioSource`). 
- iOS voice processing routes can apply echo cancellation automatically when using Apple’s voice processing APIs; Apple also documents echo-canceled input preferences for supported hardware/routes. 
- WebRTC’s Audio Processing Module (APM) is a widely used stack that includes AEC/NS/AGC for VoIP-style audio; some apps reuse this pipeline even if they’re not doing peer-to-peer calling. 

### 3.3 Beamforming / multi-mic processing (device dependent)
On many modern phones/laptops, additional mic-array processing (directional filtering/beamforming) may be applied by the OS or hardware. This is highly device-specific, but it affects what Gemini receives because it changes the mic signal before transmission.

### 3.4 Hardware offload and efficiency (common in practice)
High-performance realtime audio pipelines frequently lean on:
- SIMD/vectorized math (e.g., ARM NEON) for DSP-like operations,
- DMA-style buffer movement to reduce CPU wakeups,
- dedicated low-power audio/DSP blocks (where available).  
These are common techniques, but the exact mix depends on device chipset and OS audio stack.

---

## 4) Realtime input formatting: sample rates, PCM format, resampling

### 4.1 The Live API audio contract (what the server expects)
**Input audio** is raw PCM:
- raw 16-bit PCM, 16 kHz, little-endian. 

**Output audio** is raw PCM:
- raw 16-bit PCM at **24 kHz**, little-endian. 

### 4.2 Resampling: why the device often must do it
Many mics capture at 44.1 kHz or 48 kHz. The Live API can resample if needed, but Google’s **best practice** is: resample mic input to 16 kHz before sending. 

So device-side work commonly includes:
- capture at hardware rate,
- resample to 16 kHz,
- convert to 16-bit little-endian PCM for upload.

### 4.3 Browser-specific note: AudioWorklet for low-latency processing
On the web, many implementations use **AudioWorklet** to run realtime audio processing off the main thread with low latency (e.g., resampling + PCM packing + VAD features). 

---

## 5) Voice Activity Detection (VAD), turn-taking, and “instant interruption”

This is where “live conversation feel” mostly comes from.

### 5.1 Automatic (server-side) VAD (default)
By default, Gemini Live performs VAD on a continuous audio stream, segmenting speech into turns automatically. 

Automatic VAD is configurable (examples of parameters):
- `prefixPaddingMs` (pre-speech lookback to avoid clipping first syllables)
- `silenceDurationMs` (how long to wait before ending a speech turn)
Docs discuss recommended ranges and quality/latency tradeoffs (e.g., too-low silence can fragment utterances; too-high increases latency). 

### 5.2 Manual activity markers (client-controlled turns)
If automatic activity detection is **disabled**, the device becomes responsible for turn boundaries and must send:
- `activityStart`
- `activityEnd` 

Important: the docs warn that disabling automatic VAD bypasses server buffering behaviors; the client must be careful not to cut off speech, and recommended end-of-speech thresholds are typically **≥ 500 ms** for manual VAD. 

### 5.3 Hybrid approach (very common in good apps)
A practical pattern is “hybrid VAD”:
- Keep **automatic VAD enabled** on the server for robust speech-start detection.
- Use a fast local VAD to detect end-of-speech and then send `audioStreamEnd` to finalize quickly. 

### 5.4 Silence suppression (client-side bandwidth/power optimization)
Even when using server VAD, many clients still run a lightweight local VAD to:
- avoid sending long stretches of silence,
- reduce bandwidth and power,
- improve responsiveness for end-of-speech heuristics.

### 5.5 Barge-in (interrupting the model mid-speech)
Gemini Live has an explicit “barge-in” concept:
- `ActivityHandling` defaults to `START_OF_ACTIVITY_INTERRUPTS`, meaning user activity can cut off model generation. 

When interruption happens, the server sends `serverContent.interrupted: true`, and Google explicitly says this is the signal to **stop playback and empty the client playback queue** if you are playing audio in realtime. 

**What the device does locally for “instant feel” (common implementation):**
- local VAD detects the user starting to talk,
- immediately stops audio output on-device (flush/stop scheduled buffers),
- then relies on the server’s `interrupted: true` signal to confirm and to clear any queued audio chunks robustly. 

---

## 6) Streaming input transport: micro-chunking, buffering rules, multimodal interleaving

### 6.1 Micro-chunking
Google’s Live API best practices recommend sending audio in **20–40 ms chunks** for latency. 

Clients often implement chunk sizes like 20–50 ms in practice, but staying near the recommendation helps responsiveness.

### 6.2 “Don’t buffer a whole second”
Google explicitly advises:
- don’t buffer input audio significantly (e.g., 1 second) before sending,
- send small chunks continuously to minimize latency. 

### 6.3 JSON/base64 packaging (device CPU work)
In many SDK/browser examples, the device:
- takes raw PCM bytes,
- base64-encodes them (CPU work + allocations if not careful),
- sends them in the realtime input message with a MIME type like `audio/pcm;rate=16000`. 

### 6.4 RealtimeInput ordering caveat (important)
Live API treats audio/video/text as concurrent streams; ordering across streams is not guaranteed. The realtime input stream is optimized for responsiveness “at the expense of deterministic ordering.” 

That means the client device/app must be tolerant of:
- transcripts arriving separately,
- model turn parts interleaving,
- video frames and audio not being strictly ordered the way a single queue would be.

### 6.5 Multimodal ingestion (camera/screen frames)
If camera/screen sharing is enabled, the client typically:
- captures frames,
- compresses to JPEG/PNG/WebP (implementation-dependent),
- sends frames as a separate realtime video stream alongside audio. 

---

## 7) `audioStreamEnd`: flushing cached audio when the mic pauses

When using **automatic VAD**, Google documents a key behavior:

- If the audio stream is paused for more than ~1 second (e.g., mic turned off), the client should send `audioStreamEnd: true` to flush cached audio; later it can “reopen” by sending audio again. 

When automatic activity detection is disabled (manual mode), interruption of stream is handled via `activityEnd` rather than `audioStreamEnd`. 

---

## 8) Receiving model output: audio chunks, playback engine, and buffer control

### 8.1 Output audio format and what the device must do
Output is raw PCM at **24 kHz**. The client must:
- decode/interpret raw PCM bytes correctly (sample rate mismatch causes speed/pitch issues),
- queue chunks,
- schedule them for smooth playback. 

### 8.2 Jitter/buffering and “output can arrive faster than playback”
In practice, model audio chunks may arrive unevenly or faster than realtime playback, so clients implement:
- a small jitter buffer,
- progressive queueing,
- backpressure/queue limits,
- “hard clear” semantics on interruption.

Developers have reported the exact failure mode you described: if you don’t clear queued audio, old audio can keep playing even after the user interrupts. Google’s guidance is to clear client buffers on `serverContent.interrupted`. 

### 8.3 Immediate interruption handling (required for natural UX)
On `serverContent.interrupted: true`, the device should:
1. stop current playback immediately,
2. clear queued audio chunks,
3. (if applicable) cancel in-flight tool execution via tool cancellation messages. 

---

## 9) Transcriptions (optional), and why the client needs a “merge layer”

If enabled, the server can emit:
- `interimInputTranscription` (low-latency, frequently updated as user speaks),
- `inputTranscription` (final user transcript),
- `outputTranscription` (assistant transcript aligned to generated output). 

Key device/app responsibilities:
- Render partial vs final text correctly in UI.
- Cope with asynchronous arrival (“no guaranteed ordering” across these streams and other server messages). 

Transcription configuration details the client must respect:
- language hints via BCP‑47 codes,
- custom vocabulary biasing,
- optional word timestamps and diarization,
- `VERBATIM` vs `SMART` mode; `SMART` does disfluency removal and formatting, but timestamps/diarization are incompatible with `SMART`. 

---

## 10) Tool calling (optional): execute tools, return responses, and handle cancellations

### 10.1 Live API does not auto-handle tool responses
Unlike some request/response patterns, Live API requires the client to handle tool calls and send tool responses itself. 

### 10.2 Messages the device/client must handle
The server can send:
- `toolCall` with function calls to execute,
- `toolCallCancellation` to cancel previously issued tool calls (commonly when the client interrupts a server turn). 

So the client must:
- dispatch tool calls,
- return `toolResponse` matching the tool call IDs,
- cancel in-flight tool work when cancellation arrives (and attempt to undo side effects if feasible). 

### 10.3 Synchronous vs asynchronous tool calling (model-dependent)
Docs note function calling behavior can differ by model; for example, some models only support synchronous tool calling in Live contexts (the model may not continue responding until tool results are returned). 

---

## 11) Session lifecycle management: GoAway, resumption handles, compression

### 11.1 GoAway: pre-termination warning
The server can send a `goAway` message before terminating a connection so the client can reconnect gracefully. 

### 11.2 Session resumption: keep conversation context across reconnects
If configured, the server emits `SessionResumptionUpdate` messages containing a handle/token. The client should store the latest handle and pass it on the next connection to resume the session context. 

Resumption tokens are documented as valid for **2 hours** after session termination. 

### 11.3 Context window compression: why the client must enable it for long sessions
Native audio tokens accumulate quickly:
- ~25 tokens/second for audio (and some docs also quantify video separately). 

Without compression, sessions are limited (documented):
- audio-only: ~15 minutes
- audio+video: ~2 minutes  
Exceeding limits can terminate the session; enabling context window compression can extend sessions “to an unlimited amount of time.” 

Client/device responsibility:
- opt in to compression in session config,
- choose thresholds to avoid overly frequent compression (docs note compression can cause temporary latency spikes if done too often). 

---

## 12) Memory and performance optimizations (device-side engineering details)

These are not “required by Gemini,” but they’re what you typically build to make it stable:

### 12.1 Zero-allocation audio pipeline
- pre-allocate fixed buffers (ring/circular buffers),
- avoid runtime allocations per audio chunk to prevent GC pauses (mobile/web runtimes),
- reuse arrays/typed arrays for base64 and PCM conversions.

### 12.2 Zero-copy buffer passing
- pass references/pointers between capture → DSP/VAD → network encoder rather than copying raw byte arrays repeatedly.

### 12.3 Thread priority / realtime scheduling (platform dependent)
Clients often run capture + playback on realtime-priority audio threads where possible (or use OS-provided realtime audio frameworks). Some production debugging reports explicitly mention realtime scheduling choices. 

### 12.4 Web: keep DSP off the UI thread
On web, AudioWorklet exists specifically so audio processing can run on the audio rendering thread rather than blocking the main/UI thread, reducing glitches/latency. 

---

## 13) “Expression” / emotion / prosody: what the device does vs what the cloud does

### 13.1 What the device does NOT need to do
The Live API does not require the client device to run a local emotion classifier.

### 13.2 What the device DOES do (crucial)
The device pipeline must preserve **high acoustic fidelity** (within the constraints of AEC/NS/AGC and mic hardware), because Gemini Live maintains conversational history as **raw audio tokens** “to preserve acoustic nuance and tone.” 

In practice, that means the device should avoid “flattening” or destroying:
- pitch movement, pace, hesitations, laughter/breathiness,
- dynamics that convey emphasis,
- timing cues (pauses) that affect turn-taking quality.

---

## 14) Critical “must-implement” checklist (device/client)

1. Stream input as raw PCM with correct MIME (`audio/pcm;rate=...`), and prefer 16 kHz 16-bit LE.   
2. Send 20–40 ms audio chunks continuously; don’t buffer ~1 second before sending.   
3. Correctly handle output as 24 kHz PCM and schedule playback smoothly.   
4. On `serverContent.interrupted: true`, stop playback and clear queued audio immediately.   
5. If the mic pauses > ~1s under automatic VAD, send `audioStreamEnd: true` to flush cached audio.   
6. If you disable automatic VAD, you must send `activityStart` / `activityEnd` and tune thresholds carefully (≥500 ms recommended end-of-speech for manual VAD).   
7. Implement GoAway + session resumption; store latest resumption handle; tokens valid ~2 hours.   
8. Enable context window compression for long sessions (audio ~25 tokens/sec; 15 min/2 min limits without compression).   
9. If using tools: handle `toolCall`, return tool responses, and cancel work on `toolCallCancellation`.   
10. If connecting directly from device: use ephemeral tokens rather than embedding long-lived keys.   

---

## Sources (primary docs and references)

(Plain URLs are in inline code to keep this file copy/paste friendly.)

- Live API WebSockets reference: `https://ai.google.dev/api/live`   
- Live API capabilities (audio formats, VAD modes, audioStreamEnd, transcription options): `https://ai.google.dev/gemini-api/docs/live-api/capabilities`   
- Live API best practices (20–40ms chunks, interruption buffer clearing, resampling, compression limits): `https://ai.google.dev/gemini-api/docs/live-api/best-practices`   
- Live API session management (GoAway, resumption): `https://ai.google.dev/gemini-api/docs/live-api/session-management`   
- Live API tool use (manual tool handling, sync/async notes): `https://ai.google.dev/gemini-api/docs/live-api/tools`   
- Ephemeral tokens (client-to-server auth pattern): `https://ai.google.dev/gemini-api/docs/live-api/ephemeral-tokens`   
- Android audio preprocessors:
  - AEC: `https://developer.android.com/reference/android/media/audiofx/AcousticEchoCanceler`   
  - NS: `https://developer.android.com/reference/android/media/audiofx/NoiseSuppressor`   
  - AGC: `https://developer.android.com/reference/android/media/audiofx/AutomaticGainControl`   
- Web Audio AudioWorklet (off-main-thread low-latency processing): `https://developer.mozilla.org/en-US/docs/Web/API/AudioWorklet`   
- WebRTC Audio Processing Module overview (AEC/NS/AGC concept): `https://webrtc.googlesource.com/src/+/refs/heads/main/modules/audio_processing/g3doc/audio_processing_module.md`   
- Apple echo-cancelled input note: `https://developer.apple.com/documentation/avfaudio/avaudiosession/setprefersechocancelledinput(_:)`   

---