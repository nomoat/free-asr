# Doubao IME (macOS v1.0.2) Streaming Speech-to-Text (ASR) Protocol Specification

This document specifies the complete wire protocol, authentication model, Protobuf framing, and JSON schemas for the unauthenticated real-time streaming Speech-to-Text (ASR) service used by **Doubao Input Method for macOS** (`/Library/Input Methods/DoubaoIme.app`, v1.0.2, embedding ByteDance SAMI Core SDK `mac_14.91.26-alpha.1-oinput`).

---

## 1. Architecture Overview

```
[Global Shortcut Trigger: CGEventTap (Fn / Modifier Hold or Tap)]
        │
        ▼
[Audio Capture: AVCaptureSession / AVAudioEngine -> AVAudioConverter]
  Input : Hardware microphone native format (e.g. 48,000 Hz Float32)
  Output: 16,000 Hz, 1 channel (mono), 16-bit Signed Little-Endian PCM
  Chunk : maxBlockSize = 3,200 bytes (100 ms per chunk)
        │
        ▼
[Codec Layer: SAMI Core SDK (sami_core)]
  Two supported online wire formats in StartSession:
  1. "pcm"        : Raw 16kHz 16-bit mono LE PCM (when enable_net_transport_compress == 0)
  2. "speech_opus": Opus encoded frames (16kHz, mono, CBR 32 kbps, 20 ms frames)
        │
        ▼
[Transport Layer: WebSocket over TLS]
  Primary Endpoint : wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws
  QUIC Alternative : wss://frontier-audio-ime-quic.doubao.com/api/v1/ws
  Framing          : WebSocket Binary Frames carrying Protobuf (mammon_internal.WebSocketRequest / WebSocketResponse)
        │
        ▼
[Streaming Recognition & Multi-Pass Rescoring]
  - Interim Results (is_interim=true) : Real-time punctuated/ITN text (results[0]) + raw unpunctuated text (results[1])
  - Final Result    (is_interim=false): Server-side Two-Pass / Three-Pass LLM rescored transcript (~250-320 ms after FinishSession)
        │
        ▼
[Commit & Optional Post-Processing]
  - Typewriter diffing (ASRTypeWriter.updateResult): Computes common prefix, replaces only changed suffix
  - Optional AI Smart Organize: POST /api/v2/ai/text_organization (SSE text/event-stream)
  - Optional ModifyPair Upload: POST /api/v3/context/ime/modify_pair/v2
```

---

## 2. Authentication & Validation Mechanism (Why No Login or Registration Is Needed)

### 2.1 How the Official Client Obtains `device_id`
On first launch, `DoubaoIme.app` initializes ByteDance's telemetry SDK (`libapplogrs.dylib`), which asynchronously registers the machine and caches a 64-bit integer `device_id` and `install_id` in `~/Library/Application Support/DoubaoIme/AppLog/keyboard/applog.cache2` (exposed in Swift via `OimeCommon.AppInfo.deviceID` @ `0x91c4`).

### 2.2 How the ASR Server Actually Validates Requests (`tokenType = 1` / `TOKEN_TO_C`)
In `SAMIHandle.swift` (`0x100b3913c`), the client configures `SAMICore_AsrContextCreateParameterV2` with:
- `setTokenType(1)` (`TOKEN_TO_C`, i.e., consumer device-level authentication rather than user-account authentication)
- `setToken("{\"device_id\":\"<deviceID>\",\"aid\":\"685343\"}")` (`OdinToken` struct @ `0x101184bac`)
- `setAppKey("OrnqKvSSrs")`

In `ServiceWrapper::Init` (`0x100293af4`), when `tokenType == 1`:
1. The SDK parses the `token` JSON object.
2. Any keys matching `"device_id"`, `"iid"`, or `"aid"` are extracted and appended to the **WebSocket URL query string**.
3. The `token` field inside the Protobuf `WebSocketRequest` message (field 1) is cleared to `""` (`AsrOnWorker::Init` @ `0x10028b5fc`: `if (tokenType != 0) token = "";`).

**Crucial Finding (Verified Against Production):**
The ASR WebSocket gateway (`frontier-audio-ime-ws.doubao.com`) **does not check whether `device_id` is registered in ByteDance's `applog` database**.
- **Reason**: An input method must work the instant a user installs it and presses the voice hotkey, even if the background telemetry registration has not completed or was blocked.
- **Verification**: Passing **any randomly generated 16-digit numeric string** (e.g., `7391846205183947`) as `device_id` succeeds immediately with `status_code = 20000000 (OK)`.
- **What the server actually checks**:
  1. **URL Query**: `aid=685343` and a non-empty `device_id`.
  2. **HTTP Headers**: `proto-version: v2`, `sdk-version: 2`, `x-tt-e-k: <device_id>+W`, and `x-custom-keepalive: true`.
  3. **Protobuf Request Fields**: `appkey = "OrnqKvSSrs"` and `namespace = "ASR"`.
  4. No cookies, no HMAC signatures, and no user tokens (`x-tt-token` is empty) are required.

---

## 3. WebSocket Handshake Specification

### 3.1 Endpoint & Query Parameters

```
wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws
  ?aid=685343
  &device_id=7391846205183947
  &app_name=oime_macos
  &channel=release
  &device_platform=mac
  &device_type=mac
  &device_brand=Apple
  &os=macOS
  &os_version=15.6.0
  &version_code=1.0.2
  &version_name=1.0.2
  &update_version_code=1
  &build_number=1.0.2
  &app_version=1.0.2
```

| Query Parameter | Example Value | Required | Source in Binary |
|---|---|---|---|
| `aid` | `685343` | **Yes** | `OimeCommon.AppInfo.appID` (`0x6f54`) / `OdinToken.appID` |
| `device_id` | Any 16-digit number | **Yes** | `OdinToken.deviceID` (`0x100b22de4`) |
| `app_name` | `oime_macos` | Recommended | `OimeCommon.AppInfo.appName` (`0x3b54`) |
| `channel` | `release` | Recommended | `OimeCommon.DeviceInfo.commonParams` (`0x19a50`) |
| `device_platform` | `mac` | Recommended | `OimeCommon.DeviceInfo.commonParams` (`0x19a50`) |
| `device_type` | `mac` | Recommended | `OimeCommon.DeviceInfo.commonParams` (`0x19a50`) |
| `device_brand` | `Apple` | Recommended | `OimeCommon.DeviceInfo.commonParams` (`0x19a50`) |
| `os` | `macOS` | Recommended | `OimeCommon.DeviceInfo.commonParams` (`0x19a50`) |
| `os_version` | `15.6.0` | Recommended | `OimeCommon.DeviceInfo.commonParams` (`0x19a50`) |
| `version_code` | `1.0.2` | Recommended | `OimeCommon.DeviceInfo.commonParams` (`0x19a50`) |
| `version_name` | `1.0.2` | Recommended | `OimeCommon.DeviceInfo.commonParams` (`0x19a50`) |
| `update_version_code` | `1` | Optional | `OimeCommon.DeviceInfo.commonParams` (`0x19a50`) |
| `build_number` | `1.0.2` | Optional | `OimeCommon.DeviceInfo.commonParams` (`0x19a50`) |
| `app_version` | `1.0.2` | Optional | `OimeCommon.DeviceInfo.commonParams` (`0x19a50`) |

### 3.2 HTTP Handshake Headers

Constructed in `SAMIHandle.swift` (`FUN_100b2374c` / `Header.encode(to:)` @ `0x100b22870`) and `ServiceWrapper::Init` (`0x100293af4`):

```http
proto-version: v2
sdk-version: 2
x-tt-token: 
x-tt-e-k: 7391846205183947+W
x-custom-keepalive: true
```

---

## 4. Protobuf Wire Schema (`proto/websocket_asr.proto`)

All WebSocket messages (except `"ping"` / `"pong"` text heartbeats) are **WebSocket Binary Frames** containing a single serialized Protobuf message.

```protobuf
syntax = "proto3";
package mammon_internal;

// Decompiled from WebSocketRequest::SerializeWithCachedSizes @ 0x10098114c
message WebSocketRequest {
  string token = 1;       // Tag 0x0a: "" when tokenType == 1
  string appkey = 2;      // Tag 0x12: "OrnqKvSSrs"
  string namespace = 3;   // Tag 0x1a: "ASR"
  string version = 4;     // Tag 0x22: ""
  string event = 5;       // Tag 0x2a: "StartTask" | "StartSession" | "TaskRequest" | "FinishSession" | "FinishTask"
  string payload = 6;     // Tag 0x32: UTF-8 JSON string
  bytes  data = 7;        // Tag 0x3a: Raw audio bytes (only when event == "TaskRequest")
  string task_id = 8;     // Tag 0x42: 32-char lowercase hex UUID (constant across one session)
  uint64 seq_id = 9;      // Tag 0x48: 1-based incrementing audio chunk index (only when event == "TaskRequest")
  string session_id = 10; // Tag 0x52: ""
}

// Decompiled from WebSocketResponse::MergePartialFromCodedStream @ 0x1009821d0
message WebSocketResponse {
  string task_id = 1;     // Tag 0x0a
  string message_id = 2;  // Tag 0x12
  string namespace = 3;   // Tag 0x1a: "ASR"
  string event = 4;       // Tag 0x22: "TaskStarted" | "SessionStarted" | "" (ASR result) | "SessionFinished" | "TaskFinished" | "SessionFailed" | "TaskFailed"
  int32  status_code = 5; // Tag 0x28: 20000000 == OK
  string status_text = 6; // Tag 0x32: "OK" or error description
  string payload = 7;     // Tag 0x3a: UTF-8 JSON string with recognition results
  bytes  data = 8;        // Tag 0x42
  uint64 seq_id = 9;      // Tag 0x48
  string session_id = 10; // Tag 0x52
}
```

---

## 5. Session State Machine & JSON Payloads

```
Client                                                 Server
  |--- [1] WebSocketRequest(event="StartTask") --------->|
  |--- [2] WebSocketRequest(event="StartSession") ------>|
  |<-- [3] WebSocketResponse(event="TaskStarted") -------|
  |<-- [4] WebSocketResponse(event="SessionStarted") ----|
  |                                                      |
  |--- [5] WebSocketRequest(event="TaskRequest", seq=1)->|  (100ms / 3200B PCM)
  |--- [5] WebSocketRequest(event="TaskRequest", seq=2)->|
  |<-- [6] WebSocketResponse(event="", is_interim=true) -|  (Live streaming preview)
  |    ...                                               |
  |--- [7] WebSocketRequest(event="FinishSession") ----->|  (User stops speaking)
  |<-- [8] WebSocketResponse(event="", is_interim=false)-|  (Three-pass rescored final text)
  |<-- [9] WebSocketResponse(event="SessionFinished") ---|
  |--- [10] WebSocketRequest(event="FinishTask") ------->|
```

### 5.1 Step 1: `StartTask` (`BuildStartTaskToPb` @ `0x100292060`)
Sent immediately when the WebSocket opens:
- `appkey`: `"OrnqKvSSrs"`
- `namespace`: `"ASR"`
- `event`: `"StartTask"`
- `task_id`: `<32-char lowercase hex UUID>`

### 5.2 Step 2: `StartSession` (`BuildStartSessionToPb` @ `0x1002922f8`)
Can be pipelined immediately after `StartTask` without waiting for `TaskStarted` (`SendStartProtocol` @ `0x100291384`):
- `appkey`: `"OrnqKvSSrs"`
- `namespace`: `"ASR"`
- `event`: `"StartSession"`
- `task_id`: `<same 32-char hex UUID>`
- `payload`: JSON string:

```json
{
  "audio_info": {
    "channel": 1,
    "format": "pcm",
    "sample_rate": 16000
  },
  "enable_punctuation": true,
  "enable_speech_rejection": false,
  "extra": {
    "app_name": "oime_macos",
    "app_version": "1.0.2",
    "cell_compress_rate": 8,
    "device_brand": "Apple",
    "device_id": "7391846205183947",
    "device_model": "Mac",
    "disable_user_words": false,
    "enable_asr_format": true,
    "enable_asr_threepass": true,
    "enable_asr_twopass": true,
    "enable_print_chinese": true,
    "enable_text_filter": true,
    "finish_wait_offline_time": 1000,
    "format_space_at_newline": false,
    "input_mode": "wave",
    "join_user_experience_improve_program": false,
    "max_wait_switch_offline_time": 4000,
    "offline_wait_online_interval_time": 200,
    "offline_wait_online_time": 1000,
    "os": "macOS",
    "os_version": "15.6.0",
    "remove_space_between_han_eng": false,
    "remove_space_between_han_num": true,
    "retry_server_code": [],
    "strong_ddc": true,
    "use_twopass_retry": true
  }
}
```

### 5.3 Step 3: `TaskRequest` Audio Chunks (`BuildAudioDataToPb` @ `0x100292ca8`)
For each 100 ms (`3,200` bytes) of 16 kHz, 16-bit mono signed LE PCM:
- `appkey`: `"OrnqKvSSrs"`
- `namespace`: `"ASR"`
- `event`: `"TaskRequest"`
- `task_id`: `<same 32-char hex UUID>`
- `seq_id`: `1, 2, 3, ...`
- `payload`: `{"timestamp_ms": 1761508500123}`
- `data`: Raw 3,200-byte PCM chunk

### 5.4 Step 4: Receiving Recognition Results (`WebSocketResponse` with `event == ""`)

1. **VAD Start Notification**:
   ```json
   {
     "results": [{"text": "", "is_interim": true}],
     "extra": {"vad_start": true}
   }
   ```
2. **Streaming Partial Result (`is_interim: true`)**:
   - `results[0].text`: Punctuated and ITN-formatted text for live UI display.
   - `results[1].text`: Raw unpunctuated streaming text.
   ```json
   {
     "results": [
       {
         "text": "你好，今天天气怎么样？我正在用 Swift",
         "start_time": 0,
         "end_time": 4.099999,
         "is_interim": true
       },
       {
         "text": "你好今天天气怎么样我正在用 swift",
         "start_time": 0,
         "end_time": 4.099999,
         "is_interim": true,
         "stream_asr_finish": false,
         "extra": {"seq_id": 41}
       }
     ],
     "extra": {"seq_id": 41}
   }
   ```
3. **Final Rescored Result (`is_interim: false, is_vad_finished: true`)**:
   Returned ~250–320 ms after `FinishSession`:
   ```json
   {
     "results": [
       {
         "text": "你好，今天天气怎么样？我正在用 Swift 测试豆包语音输入法的实时语音识别接口。",
         "start_time": 0,
         "end_time": 8.028875,
         "is_interim": false,
         "is_vad_finished": true
       },
       {
         "text": "你好，今天天气怎么样？我正在用 Swift 测试豆包语音输入法的实时语音识别接口。",
         "start_time": 0,
         "end_time": 8.028875,
         "is_interim": false,
         "extra": {"nonstream_result": true}
       }
     ],
     "extra": {
       "seq_id": 82,
       "lastpkt_latency": 318,
       "lastpkt_threepass_latency": 294,
       "lastpkt_vad_latency": 6,
       "lastpkt_postprocss_latency": 0
     }
   }
   ```

### 5.5 Step 5: `FinishSession` & `FinishTask`
1. Flush any remaining PCM bytes (`< 3200` bytes) in a final `TaskRequest`, then send `FinishSession` (`event = "FinishSession"`).
2. Wait for the final `WebSocketResponse` (`is_interim: false`) and `WebSocketResponse(event = "SessionFinished")`.
3. Send `FinishTask` (`event = "FinishTask"`) and close the WebSocket.

---

## 6. Reverse-Engineering Evidence Ledger (REA & Ghidra)

| Artifact | SHA-256 | REA Evidence ID | Role |
|---|---|---|---|
| `/Library/Input Methods/DoubaoIme.app/Contents/MacOS/DoubaoIme` | `4b3836dcb8a3e06b01b4c95390c757b71f623c1f7c4141c059e49284f7f6442d` | `ev_145a49b5f55a04af7b188cffa81e1edf0da537a3bf9f020e110580dae0754e20` | Universal Mach-O layout, imports, exports |
| `/Library/Input Methods/DoubaoIme.app` | `4b3836dcb8a3e06b01b4c95390c757b71f623c1f7c4141c059e49284f7f6442d` | `ev_60e311381b34a601a05789a0730c70e1ece8d9d0210d5f968035341f31e02512` | Bundle `@rpath` dylib dependency graph |
| `DoubaoIme.arm64` (thinned arm64) | `266f49f6bcb62e43c5170620d4b86e2e4c4ef873bcce624ef1a90b9c46244983` | `ev_356efd780d3b339ee6da9b6f354b5d31aebf42fce0e503ceee1c0759c436b2cc` | Ghidra decompilation image (`__TEXT` @ `0x100000000`) |
| `OimeCommon.framework/Versions/A/OimeCommon` | `fb6d9f1d0d5e6935455779fb3bc6bf53d95fd0d0f32c37c5bb65ef5bd83ce8e4` | `ev_c46b8e4f13b60e2bbb91b4c0990b7e9fea07d32e01fc27df94feeac9933711ec` | `AppInfo` (`aid=685343`) & `DeviceInfo.commonParams` |

### Key Decompiled Procedures (`DoubaoIme.arm64`)

| Address | Symbol / Source File | Description |
|---|---|---|
| `0x100b31b5c` | `SAMIHandle.swift` | Initializes connection pool parameters (`appKey = "OrnqKvSSrs"`, `businessInfo = "wave"`) |
| `0x100b3913c` | `SAMIHandle.swift` | Populates `SAMICore_AsrContextCreateParameterV2` and creates `SAMICore` handle |
| `0x100b22870` | `Header.encode(to:)` | Encodes `proto-version`, `sdk-version`, `x-tt-token`, `x-tt-e-k` |
| `0x100b22de4` | `OdinToken.encode(to:)` | Encodes `device_id` and `aid` |
| `0x100b371a4` | `Extra.encode(to:)` | Encodes the 32 fields of `StartSession.extra` |
| `0x10028b5fc` | `AsrOnWorker::Init` (`asr_on_worker.cpp`) | Builds `StartSession` payload JSON; selects `"pcm"` vs `"speech_opus"` |
| `0x10028d7a8` | `AsrOnWorker::SendAudioData` | Buffers/encodes audio and enqueues chunks into `SendQueue` |
| `0x10028ea20` | `AsrOnWorker::OnMessage` | Handles `TaskStarted`, `SessionStarted`, streaming JSON results, `SessionFinished` |
| `0x100291384` | `AsrOnWorker::SendStartProtocol` | Sends `StartTask` followed by `StartSession` |
| `0x10029154c` | `AsrOnWorker::SendFinishProtocol` | Sends `FinishTask` |
| `0x100292060` | `BuildStartTaskToPb` (`protocol.cpp`) | Serializes `StartTask` `WebSocketRequest` |
| `0x1002922f8` | `BuildStartSessionToPb` (`protocol.cpp`) | Serializes `StartSession` `WebSocketRequest` |
| `0x100292780` | `BuildFinishSessionToPb` (`protocol.cpp`) | Serializes `FinishSession` `WebSocketRequest` |
| `0x100292a14` | `BuildFinishTaskToPb` (`protocol.cpp`) | Serializes `FinishTask` `WebSocketRequest` |
| `0x100292ca8` | `BuildAudioDataToPb` (`protocol.cpp`) | Serializes `TaskRequest` audio chunk `WebSocketRequest` |
| `0x100293af4` | `ServiceWrapper::Init` (`service_wrapper.cpp`) | Splits `OdinToken` (`device_id`, `aid`, `iid`) into URL query and headers; injects `x-custom-keepalive: true` |
| `0x10023e22c` | `SAMIWebsocketTTNetClient::init` | Builds final WebSocket URL with query parameters and headers |
| `0x10098114c` | `WebSocketRequest::SerializeWithCachedSizes` | Protobuf serializer for `mammon_internal.WebSocketRequest` |
| `0x1009821d0` | `WebSocketResponse::MergePartialFromCodedStream` | Protobuf parser for `mammon_internal.WebSocketResponse` |
