# Gemini Live Transcription: verified streaming input

Verified on 2026-10-30 with `gemini-3.5-transcribe-live`, using the Gemini
Developer API and an API key supplied outside the repository.

**Result: yes, Gemini can receive ongoing audio and return text while the speaker
is still speaking.** It is a viable third ASR backend alongside WeType and
Doubao. The verification sends a synthetic Chinese speech fixture at real-time
speed, over a bidirectional WebSocket. It does not upload the complete recording
and then stream the answer.

The working reference is [`tests/gemini-stream-smoke.mjs`](./tests/gemini-stream-smoke.mjs).
It is an opt-in network test, with no npm dependencies. It is not yet integrated
into the four SDK provider selectors, automatic failover, or system-wide typing.

## Reproduce

Requirements: Node.js 22.18+, a Gemini API key with access to the model, and raw
16 kHz mono signed 16-bit little-endian PCM. FFmpeg can convert an existing audio
file. The fixture below uses macOS `say`; Linux can use any speech fixture.

Keep the key in an environment variable or a private file **outside the checkout**,
for example `$HOME/.config/free-asr/gemini.env`, containing a `GEMINI_API_KEY`
assignment. The script also accepts `GOOGLE_API_KEY`. No key is included here.
Do not pass a key as a script argument. Model access and billing belong to the
API account; the login-free properties of the other two providers do not apply.

```sh
# macOS: create the exact speech fixture used in the verification.
say -v Tingting -r 170 -o /tmp/free-asr-gemini.aiff \
  '我们现在测试实时语音输入。我还没有说完，屏幕上就应该出现文字。微信输入法和豆包输入法如果不能使用，就切换到谷歌的语音服务。请保留原来的中文，不要回答我的问题。'

# Any FFmpeg-supported recording can replace the input file here.
ffmpeg -v error -y -i /tmp/free-asr-gemini.aiff \
  -ac 1 -ar 16000 -f s16le /tmp/free-asr-gemini.pcm

# Two turns on ONE connection, using automatic voice activity detection (VAD).
node --env-file="$HOME/.config/free-asr/gemini.env" \
  tests/gemini-stream-smoke.mjs --file /tmp/free-asr-gemini.pcm --repeat 2

# Explicit start/stop, as used by a push-to-talk button.
node --env-file="$HOME/.config/free-asr/gemini.env" \
  tests/gemini-stream-smoke.mjs --file /tmp/free-asr-gemini.pcm --mode manual
```

Omit Node's `--env-file` option if the key is already in the environment. The
script emits JSON lines with intermediate text, final text, and timing summaries.
It exits nonzero if it gets no intermediate text before all PCM bytes are sent,
no final text within the observation window, or a connection error. Use a speech
fixture long enough to distinguish streaming from end-only transcription.

## Measurements

The fixture contains 557,404 PCM bytes, or 17.419 seconds of audio. Each full
chunk is 3,200 bytes (100 ms). Sending and receiving run concurrently.

The committed reference script passed these live checks:

| Mode | Turn | First interim after audio start | Interim events before all audio sent | Final after audio end |
|---|---|---|---|---|
| Automatic VAD | 1 | 747 ms | 35 | 407 ms |
| Automatic VAD, same connection | 2 | 866 ms | 35 | 435 ms |
| Manual push-to-talk | 1 | 652 ms | 35 | 380 ms |

Each turn received 36 interim events in total and one final transcript. The two
automatic-VAD turns used the same WebSocket, without reconnecting. The first
exploratory probe also passed (694 ms to first interim, 499 ms to final after
audio end).

These are observed times for synthetic speech on one machine and network,
not a latency guarantee or an accuracy benchmark. First-interim time includes
the initial speech needed to recognize a word; it is not per-word processing
latency. Interim text can revise words, spacing, and punctuation.

## Wire protocol

Use the dedicated transcription model, `gemini-3.5-transcribe-live`. The ordinary
`generateContent` / `streamGenerateContent` endpoints are not this input-streaming
path. The separate conversational Live models have different response semantics.

Connect to the WebSocket endpoint documented by Google:

```text
wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent
```

The reference script supplies the runtime API key during the connection and
never logs the URL or raw socket error objects. It redacts the key from emitted
text and errors as a second safeguard.

1. Send `setup` with `model: "models/gemini-3.5-transcribe-live"`,
   `generationConfig.responseModalities: ["TEXT"]`, and
   `inputAudioTranscription: {}`. Wait for `setupComplete`.
2. Repeatedly send `realtimeInput.audio` with base64 PCM in `data` and
   `mimeType: "audio/pcm;rate=16000"`. Receive events concurrently.
3. Read `serverContent.interimInputTranscription.text` for the live preview.
   These are revised hypotheses: **replace the current preview**, rather than
   concatenating each update.
4. Read `serverContent.inputTranscription.text` for committed speech segments.
   Keep committed text separate from the current preview.
5. For automatic VAD, end the input with `realtimeInput.audioStreamEnd: true`.
   For push-to-talk, set
   `realtimeInputConfig.automaticActivityDetection.disabled: true` in setup,
   then use `realtimeInput.activityStart: {}` and
   `realtimeInput.activityEnd: {}` around the audio.

The test receives transcription events without a conversational `turnComplete`
event. Do not make receiving that event a requirement for displaying text. The
test uses a configurable three-second observation window after each turn; that
fixed delay is a test mechanism, not a production finalization protocol.

## Integrating a third provider

```text
Microphone -> 16 kHz mono PCM -> selected ASR provider -> preview / committed text
                                  | WeType
                                  | Doubao
                                  | Gemini Live Transcription
```

Use one capture and text-display path, with provider-specific wire adapters.
Feed each microphone chunk directly to the selected adapter. For Gemini, replace
the fixture pacing loop with microphone callbacks; keep the receiver active while
recording. Existing Swift sessions already expose incremental PCM input. The
existing Python, TypeScript, and Rust `transcribe(pcm, ...)` convenience APIs take
a complete buffer, so their `--stream` output alone is not a live-capture API.

Automatic fallback still needs explicit handling of failure, buffered uncommitted
audio, and text already committed to the application. Otherwise a switch can
lose words or type them twice. System-wide shortcuts and insertion into the
focused application are a separate layer from ASR. Long sessions, reconnection,
microphone permissions, and application-wide typing were not validated here.

## Official references

- [Live transcription guide](https://ai.google.dev/gemini-api/docs/live-api/live-transcribe):
  dedicated model, interim/final events, and automatic/manual VAD.
- [Live API WebSocket reference](https://ai.google.dev/api/live):
  endpoint, setup handshake, and message fields.
- [Live API capabilities](https://ai.google.dev/gemini-api/docs/live-api/capabilities):
  PCM input format and sending audio chunks.
