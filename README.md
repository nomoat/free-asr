# Free ASR (`free-asr`)

A zero-dependency, pure-Swift real-time streaming Speech-to-Text (ASR) client and complete protocol specification, reverse-engineered from **Doubao Input Method for macOS** (`DoubaoIme.app` v1.0.2 / ByteDance SAMI Core SDK `mac_14.91.26-alpha.1-oinput`).

---

## Key Findings: How Authentication & Streaming Work

1. **No Account Login Required (`tokenType = 1` / `TOKEN_TO_C`)**:
   Doubao IME works out-of-the-box without signing into a Doubao account.
2. **No Device Registration Required (`device_id` is not checked against a whitelist)**:
   While the official app asynchronously registers a `device_id` via `libapplogrs.dylib` (cached in `~/Library/Application Support/DoubaoIme/AppLog/keyboard/applog.cache2`), the ASR WebSocket gateway (`wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws`) **does not verify whether `device_id` exists in a backend database**.
   - Why? Input methods must respond immediately on first keystroke right after installation, even before background device registration finishes.
   - Any randomly generated 16-digit numeric string (e.g., `7391846205183947`) is accepted immediately with `status_code = 20000000 (OK)`. The server only uses `device_id` for rate-limiting buckets and log tracing (`log_id`).
3. **What the Server Actually Validates**:
   The gateway only checks three hardcoded constants:
   - **URL Query**: `aid=685343` (Doubao IME macOS App ID) and a non-empty `device_id=<16-digit number>`.
   - **WebSocket HTTP Headers**: `proto-version: v2`, `sdk-version: 2`, `x-tt-e-k: <device_id>+W`, `x-custom-keepalive: true`, and `x-tt-token: ""` (empty string).
   - **Protobuf Frame Fields**: `appkey = "OrnqKvSSrs"` (field 2) and `namespace = "ASR"` (field 3) in every `WebSocketRequest` frame.
4. **Native Uncompressed PCM Support (No `libopus` or `protobuf` C++ libraries needed)**:
   Although the official app defaults to `"format": "speech_opus"`, decompilation of `AsrOnWorker::Init` (`0x10028b5fc`) revealed that setting `"format": "pcm"` in the `StartSession` JSON payload makes the server accept **raw 16,000 Hz, 1-channel (mono), 16-bit signed little-endian PCM** (`3,200` bytes per 100 ms chunk).
5. **Streaming Partial + Three-Pass Rescored Final Results**:
   - While audio chunks are streaming, the server pushes real-time partial results (`is_interim: true`), including both punctuated/ITN text (`results[0].text`) and raw unpunctuated text (`results[1].text`).
   - Once `FinishSession` is sent, the server runs a server-side Two-Pass / Three-Pass LLM rescorer and returns the final corrected transcript (`is_interim: false, is_vad_finished: true`) in ~250–320 ms.

---

## Repository Structure

- [`PROTOCOL.md`](./PROTOCOL.md): Complete English protocol specification (authentication mechanics, WebSocket handshake Query & Headers, Protobuf wire schema, session state machine, JSON payloads, REA Evidence IDs, and Ghidra decompiled function table).
- [`proto/websocket_asr.proto`](./proto/websocket_asr.proto): Recovered Protobuf schema for `mammon_internal.WebSocketRequest` and `mammon_internal.WebSocketResponse`.
- [`Sources/DoubaoASR/DoubaoASRClient.swift`](./Sources/DoubaoASR/DoubaoASRClient.swift): Self-contained, single-file Swift SDK (`DoubaoASRSession` + `DoubaoMicrophoneStreamer` + inline Protobuf wire codec). Can be copied directly into any macOS or iOS app.
- [`Sources/doubao-asr-cli/main.swift`](./Sources/doubao-asr-cli/main.swift): Command-line tool for testing live microphone capture, local WAV/PCM files, or macOS TTS (`say`) synthesis.

---

## Quick Start & Testing

### 1. Automated Self-Test (macOS TTS -> Doubao ASR)

Synthesizes a Chinese sentence using macOS `/usr/bin/say` (`LEI16@16000`) and streams it to the live server:

```sh
swift run doubao-asr-cli --say "不需要登录账号，我们直接用Swift连上了豆包输入法的流式语音识别接口。"
```

### 2. Live Microphone Streaming (Press Enter to stop)

Records from the default Mac microphone, resamples to 16 kHz mono Int16 PCM on-the-fly, prints live interim transcripts, and optionally copies the final transcript to the clipboard (`--paste`):

```sh
swift run doubao-asr-cli --paste
```

### 3. Transcribe a Local Audio File (16 kHz, 16-bit mono WAV or raw PCM)

```sh
swift run doubao-asr-cli --file /path/to/audio.wav
```

---

## Using in Your Own Swift Project

Add this repository as a Swift Package dependency or copy [`Sources/DoubaoASR/DoubaoASRClient.swift`](./Sources/DoubaoASR/DoubaoASRClient.swift) directly into your target:

```swift
import DoubaoASR

let session = DoubaoASRSession()
let events = try session.start()

let mic = DoubaoMicrophoneStreamer()
try mic.start { pcmData in
    session.sendPCM(pcmData)
}

for try await event in events {
    switch event {
    case let .partialResult(text, _, _):
        print("Partial:", text)
    case let .finalResult(text, latencyMs, _):
        print("Final:", text, "(\(latencyMs ?? 0) ms)")
    default:
        break
    }
}
```
