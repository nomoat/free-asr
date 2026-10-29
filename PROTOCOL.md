# Free ASR: Doubao IME & WeChat Input Method (WeType) Streaming ASR Protocol Specification

This document specifies the complete wire protocols, authentication/bootstrap models, cryptographic key derivations, Protobuf schemas, and state machines for two login-free real-time streaming Speech-to-Text (ASR) services reverse-engineered on macOS:

- **Part I**: **Doubao Input Method for macOS** (`/Library/Input Methods/DoubaoIme.app` v1.0.2, ByteDance SAMI Core SDK `mac_14.91.26-alpha.1-oinput`)
- **Part II**: **WeChat Input Method (WeType) for macOS** (`/Library/Input Methods/WeType.app` v3.0.0 (670), Tencent `wetap::net` + `wcwss.framework` + `TROpusTool`)

---

# Part I: Doubao IME (macOS v1.0.2) Streaming ASR Protocol

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

---

# Part II: WeChat Input Method / WeType (macOS v3.0.0) Streaming ASR Protocol

Reverse-engineered from `/Library/Input Methods/WeType.app/Contents/MacOS/WeType` v3.0.0 (build 670, arm64).

---

## 7. Architecture Overview (WeType)

```
[Audio Input: 16,000 Hz, 1 channel (mono), 16-bit Signed Little-Endian PCM]
        │
        ▼
[Opus Framing Layer: TROpusTool @ 0x102c3268c]
  - Opus Encoder : 16,000 Hz, 1 channel, 64,000 bps, 20 ms frames (320 samples / 640 B PCM)
  - 1st Packet   : Prefixed with 16-byte header "#!OPUS_RAW_V1\x02\x01\x00"
  - Frame Prefix : uint16_le(frame_byte_length) + raw_opus_frame
  - Chunk Size   : 5 frames per packet (100 ms)
        │
        ▼
[Voice Protobuf Layer: wetype.voice (Kb-CmdId = 4548, Kb-SubCmdId = 0)]
  - Request      : ImeVoiceTranslateReq { 1: bytes(ImeVoiceAssistantReq) }
  - Response     : ImeVoiceTranslateResp { 1: bytes(ImeVoiceAssistantRsp) }
        │
        ▼
[Compression & Encryption Layer: CronetNetworkApi::StartTaskSync @ 0x1015d8c74]
  - Compression  : Snappy when plaintext >= 301 bytes (Kb-CompressionType = "2"), else uncompressed ("1")
  - Cipher       : AES-256-ECB with PKCS#7 padding (no IV)
  - Session Key  : 32-byte ASCII uppercase hex of the 16-byte secp128r1 ECDH shared secret X coordinate
        │
        ▼
[Transport Layer: WebSocket Tunnel (wss://wetype.weixin.qq.com, Sec-WebSocket-Protocol: wxws_pb) or HTTPS]
  - Step 1       : POST /oauth_pubkey_v2 (TaskId = 2147483646) -> secp128r1 ECDH key exchange + gen_uin_token
  - Step 2       : POST /gen_uin_v2      (TaskId = 2147483645) -> Anonymous 64-bit UIN allocation (no login)
  - Step 3       : POST /api_v2          (Kb-CmdId = 4548)     -> Streaming recognition + Phase-B polish polling
```

---

## 8. Transport Envelope (`proto/wetype_asr.proto`)

WeType supports two equivalent transports to `wetype.weixin.qq.com` (debug host: `wetype995.weixin.qq.com`):

1. **Multiplexed WebSocket Tunnel (Default in `wcwss_api.cpp`)**:
   - Endpoint: `wss://wetype.weixin.qq.com/`
   - Required Handshake Header: `Sec-WebSocket-Protocol: wxws_pb` (`wetap::net::WcwssAPI::ConnectHost` @ `0x1015f7850`)
   - Binary frames carry `websocket.WebSocketPbRequest` and `websocket.WebSocketPbResponse`:

   ```protobuf
   message HttpHeader {
     string key   = 1;
     string value = 2;
   }

   message HttpRequest {
     string              method = 1; // "POST"
     string              path   = 3; // "/oauth_pubkey_v2" | "/gen_uin_v2" | "/api_v2" | "/timestamp"
     string              query  = 4; // ""
     repeated HttpHeader header = 5;
     bytes               body   = 6;
   }

   message WebSocketPbRequest {
     uint32      field_1  = 1; // 0
     uint32      field_2  = 2; // 0
     uint32      seq      = 3; // Matches Kb-TaskId
     HttpRequest http_req = 5;
   }

   message HttpResponse {
     string              version     = 1;
     int32               status_code = 2; // 200 = OK; 5004 / 5011 = session key expired
     string              status_text = 3;
     repeated HttpHeader header      = 4; // Includes kb-compressiontype ("1" or "2")
     bytes               body        = 5;
   }

   message WebSocketPbResponse {
     uint32       type      = 1;
     uint32       seq       = 2; // Matches request seq (0 = server push notification)
     bytes        push_data = 3;
     HttpResponse http_rsp  = 4;
   }
   ```

2. **Direct HTTPS POST**:
   - Standard `POST https://wetype.weixin.qq.com/<path>` with the same `Kb-*` HTTP headers and encrypted body.

---

## 9. Platform Constants, Device Code, and `Kb-Sign` Signatures

### 9.1 Platform `sign_key` Table (`0x1015ce944` & `0x1015cfa04`)

| `Kb-OsType` (`platform`) | Prefix | 16-Byte `sign_key` |
|---|---|---|
| `1` (Android) | `AND` | `aI0wC6qT1nB3nN5r` |
| `2` (iOS) | `IOS` | `wC4bY5nV2kE0xK0r` |
| `3` (Windows) | `WIN` | `mW9oS8mT5eC1xU2i` |
| `4` (HarmonyOS) | `HAR` | `tF8lN8eP0aO2rB9i` |
| `5` (macOS) | `MAC` | `zN7rB3bL4pO8jW1o` |

### 9.2 Device Code Generation (`wetap::net::Util::GenerateDeviceCode` @ `0x1015ce7e8`)
1. Left-pad the device model (e.g., `"Mac17,8"`) with `'0'` to 17 characters (`"0000000000Mac17,8"`).
2. Generate 12 random lowercase letters `rand12`.
3. Form the 32-character prefix `prefix32 = "MAC" + padded_model_17 + rand12`.
4. Append the 32-character uppercase MD5 digest of `prefix32 + "zN7rB3bL4pO8jW1o"`:
   ```
   device_code = prefix32 + MD5_UPPER(prefix32 + "zN7rB3bL4pO8jW1o")
   ```

### 9.3 `Kb-Sign` SHA-256 Formulas (`wetap::net::WcwssAPI::GETWsHttpData` @ `0x1015f498c`)

Every request carries a 64-character uppercase hex SHA-256 signature (`Kb-Sign`):

1. **ECDH Public Key Exchange (`/oauth_pubkey_v2`, `Kb-TaskId = 2147483646`)** (`GetDHAPISignature` @ `0x1015ce178`):
   ```
   Kb-Sign = SHA256_UPPER(
     Kb-OsType + Kb-Version + Kb-Scene + Kb-TimeStamp +
     Kb-BodyMd5 + Kb-TraceId + Kb-TaskId + "zN7rB3bL4pO8jW1o"
   )
   ```
2. **Anonymous UIN Allocation (`/gen_uin_v2`, `Kb-TaskId = 2147483645`)** (`GetUinAPISignature` @ `0x1015ce37c`):
   ```
   Kb-Sign = SHA256_UPPER(
     Kb-OsType + Kb-Version + Kb-Scene + Kb-TimeStamp +
     Kb-BodyMd5 + Kb-GenUinToken + Kb-TraceId + Kb-TaskId + "zN7rB3bL4pO8jW1o"
   )
   ```
3. **Standard Task Requests (`/api_v2` and `/timestamp`)** (`GetAPISignature` @ `0x1015cdf08`):
   ```
   Kb-Sign = SHA256_UPPER(
     Kb-OsType + Kb-Version + Kb-Scene + Kb-CmdId + Kb-SubCmdId +
     Kb-TimeStamp + Kb-BodyMd5 + Kb-Uin + Kb-TraceId + Kb-TaskId + "zN7rB3bL4pO8jW1o"
   )
   ```

---

## 10. `secp128r1` ECDH Handshake & AES-256-ECB Key Derivation

### 10.1 Curve Parameters (`CryptoPP::ASN1::secp128r1` @ `0x1015c5a6c`)
WeType uses **SEC 2 `secp128r1`** (OID `1.3.132.0.28`, 128-bit prime field):
```
p  = 0xFFFFFFFDFFFFFFFFFFFFFFFFFFFFFFFF
a  = 0xFFFFFFFDFFFFFFFFFFFFFFFFFFFFFFFC
b  = 0xE87579C11079F43DD824993C2CEE5ED3
Gx = 0x161FF7528B899B2D0C28607CA52C5B86
Gy = 0xCF5AC8395BAFEB13C02DA292DDED7A83
n  = 0xFFFFFFFE0000000075A30D1B9038A115
```
- **Public Key Format**: Uncompressed SEC 1 point `0x04 || X (16 bytes) || Y (16 bytes)` (33 bytes total), formatted as a **66-character uppercase hex string** (`"04..."`).
- **Session AES Key Derivation** (`Crypto::ECDHKeyGenerator::GenerateSharedKey` @ `0x1015c5cec`):
  Given client private scalar `d` and server point `Q_svr`, compute `S = d * Q_svr`. Format the 16-byte X coordinate `S.x` as a **32-character uppercase hex string** (32 ASCII bytes). Those 32 ASCII bytes are used directly as the **AES-256-ECB** key, and its last 4 characters are sent in `Kb-SharedKeySuffix`.

### 10.2 Two-Step Bootstrap
1. **`POST /oauth_pubkey_v2` (`Kb-TaskId = 2147483646`)**:
   - `ECDHPubKeyReq_V2` is encrypted with the static 32-byte ASCII key `"D4Y5U3Y2M0C0T7N4P1P7O2N6E1I2Y1U6"` (AES-256-ECB, PKCS#7 padding, `Kb-CompressionType = "1"`).
   - Response `ECDHPubKeyRsp_V2` is decrypted with `"D4Y5U3Y2M0C0T7N4P1P7O2N6E1I2Y1U6"`, yielding `svr_pub_key` (field 2, 66 hex chars) and `gen_uin_token` (field 4, UUID string).
2. **`POST /gen_uin_v2` (`Kb-TaskId = 2147483645`)**:
   - Header includes `Kb-GenUinToken: <gen_uin_token>`.
   - `GenUinReq_V2` is encrypted with the ECDH-derived session `aes_key`.
   - Response `GenUinRsp_V2` is decrypted with `aes_key`, yielding the anonymous 64-bit `uin` in field 2.

---

## 11. `#!OPUS_RAW_V1` Audio Framing & Phase-B Polling

### 11.1 `TROpusTool` Framing (`0x102c32738` & `0x102c32ad4`)
Audio is encoded as 16,000 Hz, 1-channel, 64 kbps Opus in 20 ms frames (320 samples / 640 bytes PCM per frame):
- **First packet (`seq = 1`)**: Starts with the 16-byte header `"#!OPUS_RAW_V1\x02\x01\x00"` (`0x02` = 16 kHz, `0x01` = 1 channel, `0x00` = reserved).
- **Every 20 ms Opus frame**: Prefixed by a 2-byte little-endian unsigned length `uint16_le(frame_len)` followed by `frame_len` bytes of raw Opus packet data.

### 11.2 Streaming & Phase-B Polish Polling (`VoiceEngine::sendEndPollingRequest` @ `0x100049300`)
1. Send audio chunks with `seq = 1..N`, `encode = 5`, `lane = 1`, and cumulative byte `offset`. Set `is_end = 1` on the final audio chunk (`seq = N`).
2. While `end_flag` (field 5 of `ImeVoiceAssistantRsp`) is `0`, poll every `100 ms` with `voice_id`, `encode = 5`, `is_end = 1`, `seq = 0` (omitted), `offset = total_audio_bytes`, `lane = 1`, and empty `audio`.
3. When `end_flag == 1`, `result_text_v2` (field 14) and `result_text` (field 4) contain the final punctuated transcript.

### Key Decompiled Procedures (`WeType.arm64`)

| Address | Symbol | Description |
|---|---|---|
| `0x100048910` | `wetype::VoiceEngine::setupOpus()` | Initializes 16kHz/Mono/64kbps Opus encoder |
| `0x100048e4c` | `wetype::VoiceEngine::sendBuffer(bool)` | Sends Opus chunks and `sendEndPollingRequest` (`seq=0, is_end=1`) |
| `0x10004ad90` | `wetype::VoiceEngine::buildVoiceTransRequest(...)` | Serializes `ImeVoiceTranslateReq` / `ImeVoiceAssistantReq` |
| `0x10004bbc8` | `wetype::VoiceEngine::handleNetworkResponse(...)` | Processes streaming ASR responses and Phase-B state machine |
| `0x10004c9b4` | `wetype::VoiceEngine::parseVoiceTransResponse(...)` | Parses `ImeVoiceTranslateResp` / `ImeVoiceAssistantRsp` |
| `0x1015c5620` | `Crypto::ECDHKeyGenerator::ECDHKeyGenerator()` | Generates `secp128r1` keypair |
| `0x1015c5a6c` | `CryptoPP::ASN1::secp128r1()` | Returns OID `1.3.132.0.28` (`secp128r1`) |
| `0x1015c5cec` | `Crypto::ECDHKeyGenerator::GenerateSharedKey(...)` | Computes `secp128r1` shared secret and formats 32-char uppercase hex key |
| `0x1015c67d0` | `Crypto::AES::Encrypt(...)` / `Decrypt(...)` | AES-256-ECB + PKCS#7 encryption/decryption |
| `0x1015cdf08` | `wetap::net::Util::GetAPISignature(...)` | Computes `Kb-Sign` for `/api_v2` and `/timestamp` |
| `0x1015ce178` | `wetap::net::Util::GetDHAPISignature(...)` | Computes `Kb-Sign` for `/oauth_pubkey_v2` |
| `0x1015ce37c` | `wetap::net::Util::GetUinAPISignature(...)` | Computes `Kb-Sign` for `/gen_uin_v2` |
| `0x1015ce7e8` | `wetap::net::Util::GenerateDeviceCode(...)` | Generates 64-char `device_code` with platform `sign_key` |
| `0x1015d8c74` | `wetap::net::CronetNetworkApi::StartTaskSync(...)` | Applies Snappy compression (`>= 301 B`) and AES-256-ECB encryption |
| `0x1015f498c` | `wetap::net::WcwssAPI::GETWsHttpData(...)` | Builds `WebSocketPbRequest` and `Kb-*` headers |
| `0x102c32ad4` | `TROpusTool::Encode(...)` | Prepends `#!OPUS_RAW_V1\x02\x01\x00` and 2-byte LE frame lengths |

