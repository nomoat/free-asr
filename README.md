# Free ASR (`free-asr`)

Login-free real-time streaming Speech-to-Text (ASR) SDKs and CLIs in **Swift**, **Rust**, **Python**, and **TypeScript**, reverse-engineered from **Doubao Input Method** (`DoubaoIme.app` v1.0.2) and **WeChat Input Method / WeType** (`WeType.app` v3.0.0) on macOS. TypeScript, Python and Rust also run on Linux using system FFmpeg/OpenSSL; no npm, pip or crates.io packages are required.

---

## Supported Providers Comparison

| Feature | Doubao IME (`doubao`) | WeChat IME / WeType (`wetype`) |
|---|---|---|
| **Gateway Endpoint** | `wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws` | `wss://wetype.weixin.qq.com/` (`Sec-WebSocket-Protocol: wxws_pb`) |
| **Account Login Needed?** | **No** (`tokenType = 1` / `TOKEN_TO_C`) | **No** (anonymous 64-bit `Kb-Uin` issued via `/gen_uin_v2`) |
| **Bootstrap / Auth** | Random 16-digit `device_id`, `aid=685343`, `appkey="OrnqKvSSrs"` | `secp128r1` ECDH (`/oauth_pubkey_v2`) + `Kb-Sign` SHA-256 (`zN7rB3bL4pO8jW1o`) |
| **Payload Encryption** | TLS only (plaintext Protobuf + JSON) | Snappy (`>= 301 B`) + AES-256-ECB (session key = 32-char hex of ECDH `S.x`) |
| **Wire Audio Format** | Raw 16,000 Hz, 1-ch, 16-bit LE PCM (`"format": "pcm"`) | `#!OPUS_RAW_V1\x02\x01\x00` + `[uint16_le(len) + 20ms_opus_64kbps]*` |
| **Final Rescoring** | Server-side Two-Pass / Three-Pass LLM rescoring (`is_interim: false`) | Server-side Phase-B polish polling (`seq=0, is_end=1` -> `result_text_v2`) |

---

## Repository Structure

- [`PROTOCOL.md`](./PROTOCOL.md): Complete protocol specification for both **Part I: Doubao IME** and **Part II: WeChat Input Method (WeType)** (authentication, `secp128r1` ECDH, `Kb-Sign` SHA-256 formulas, `#!OPUS_RAW_V1` framing, Protobuf schemas, and decompiled binary function tables).
- **Protobuf Schemas**:
  - [`proto/websocket_asr.proto`](./proto/websocket_asr.proto): Doubao IME (`mammon_internal.WebSocketRequest` / `WebSocketResponse`).
  - [`proto/wetype_asr.proto`](./proto/wetype_asr.proto): WeType (`websocket.*`, `wetap.net.*`, `wetype.voice.*`).
- **Swift SDK & CLI** (`Package.swift`, zero external dependencies):
  - [`Sources/DoubaoASR/DoubaoASRClient.swift`](./Sources/DoubaoASR/DoubaoASRClient.swift) & [`Sources/doubao-asr-cli/main.swift`](./Sources/doubao-asr-cli/main.swift)
  - [`Sources/WeTypeASR/WeTypeASRClient.swift`](./Sources/WeTypeASR/WeTypeASRClient.swift) & [`Sources/wetype-asr-cli/main.swift`](./Sources/wetype-asr-cli/main.swift)
- **Rust SDK & CLI** (`rust/Cargo.toml`, zero crates.io dependencies):
  - [`rust/src/lib.rs`](./rust/src/lib.rs) & [`rust/src/main.rs`](./rust/src/main.rs)
- **Python SDK & CLI** (zero `pip` dependencies):
  - [`python/free_asr.py`](./python/free_asr.py)
- **TypeScript SDK & CLI** (`typescript/package.json`, zero `npm` dependencies):
  - [`typescript/free_asr.ts`](./typescript/free_asr.ts)

---

## Linux support

| SDK / CLI | macOS | Linux | System requirements on Linux |
|---|---|---|---|
| TypeScript | Yes | Yes | Node.js 22.18+; FFmpeg with `libopus` for WeType |
| Python | Yes | Yes | Python 3.9+; system OpenSSL `libcrypto`; FFmpeg with `libopus` |
| Rust | Yes | Yes | Rust 1.65+; OpenSSL development libraries at build time; CA certificates; FFmpeg with `libopus` |
| Swift | Yes | No | Uses Apple AVFoundation, AudioToolbox and CommonCrypto |

For Debian 12 / Ubuntu, install the relevant system dependencies:

```sh
sudo apt-get update
sudo apt-get install ffmpeg libssl-dev ca-certificates python3
# Install a supported Node.js / Rust toolchain separately.

node typescript/free_asr.ts --provider wetype --file speech.wav --stream
python3 python/free_asr.py --provider wetype --file speech.wav --stream
cargo run --manifest-path rust/Cargo.toml -- --provider wetype --file speech.wav --stream
```

Use a **16 kHz, mono, signed 16-bit WAV or raw `.pcm`** file. Replace `wetype`
with `doubao` to test the other service. `--say` is a macOS-only convenience;
Linux uses `--file`. Linux Opus encoding uses FFmpeg rather than `afconvert`.
Python uses OpenSSL's EVP AES API; Rust uses OpenSSL for AES/hash/TLS and
verifies the server certificate chain and hostname against the system CA store.
Node uses its built-in TLS/crypto. No account credentials are needed.

`--stream` prints partial recognition results for the supplied file; it does
not capture a Linux microphone. Applications can feed PCM to the SDK APIs.

Offline checks (FFmpeg required):

```sh
python3 python/test_platform.py
node typescript/test_platform.ts
cargo test --manifest-path rust/Cargo.toml
```

Verified on 2026-10-30: Debian 12 x86_64, Node 22, Python 3.11, Rust 1.95,
OpenSSL 3 and FFmpeg 5.1. All three clients transcribed the same Chinese test
sentence through **both** WeType and Doubao. Rust was compiled inside that
Linux environment; binaries built on newer glibc hosts are not portable to
older distributions. macOS Swift WeType and TypeScript/Python/Rust build or
codec checks were also exercised. See `tests/linux-smoke.sh` for the opt-in
live test; it sends only the fixture file you supply to the selected services.

---

## Quick Start Across All 4 Languages

### 1. Swift (`doubao-asr-cli` & `wetype-asr-cli`)

```sh
# Automated TTS -> ASR test (WeType & Doubao)
swift run wetype-asr-cli --say "不需要登录账号，我们直接用纯Swift连上了微信输入法的流式语音识别服务。"
swift run doubao-asr-cli --say "不需要登录账号，我们直接用纯Swift连上了豆包输入法的流式语音识别接口。"

# Live microphone streaming (press Enter to stop; --paste copies to clipboard)
swift run wetype-asr-cli --paste
swift run doubao-asr-cli --paste

# Transcribe a local WAV/PCM file
swift run wetype-asr-cli --file /path/to/audio.wav
swift run doubao-asr-cli --file /path/to/audio.wav
```

### 2. Rust (`rust/`, zero crates.io dependencies)

```sh
cd rust
cargo run -- --provider wetype --say "Rust客户端测试微信输入法语音识别。" --stream
cargo run -- --provider doubao --say "Rust客户端测试豆包输入法语音识别。" --stream
cargo run -- --provider wetype --file /path/to/audio.wav
```

### 3. Python (`python/free_asr.py`, zero `pip` dependencies)

```sh
python3 python/free_asr.py --provider wetype --say "Python客户端测试微信输入法语音识别。" --stream
python3 python/free_asr.py --provider doubao --say "Python客户端测试豆包输入法语音识别。" --stream
python3 python/free_asr.py --provider wetype --file /path/to/audio.wav
```

### 4. TypeScript (`typescript/free_asr.ts`, zero `npm` dependencies, Node.js 22.18+ / Bun)

```sh
node typescript/free_asr.ts --provider wetype --say "TypeScript客户端测试微信输入法语音识别。" --stream
node typescript/free_asr.ts --provider doubao --say "TypeScript客户端测试豆包输入法语音识别。" --stream
node typescript/free_asr.ts --provider wetype --file /path/to/audio.wav
```

---

## SDK Usage Examples

### Swift (`DoubaoASR` / `WeTypeASR`)

```swift
import WeTypeASR

let session = WeTypeASRSession()
let events = try session.start()
try await session.bootstrapIfNeeded()

let mic = WeTypeMicrophoneStreamer()
try mic.start { pcmData in
    Task { try? await session.sendPCM(pcmData) }
}

for try await event in events {
    switch event {
    case let .partialResult(text, _):
        print("Partial:", text)
    case let .finalResult(text, _):
        print("Final:", text)
    default:
        break
    }
}
```

### Rust (`free_asr`)

```rust
use free_asr::{transcribe, Provider};

let text = transcribe(&pcm_16k_s16le_bytes, Provider::WeType, None)?;
println!("Transcript: {}", text);
```

### Python (`free_asr`)

```python
from python.free_asr import transcribe

text = transcribe(pcm_16k_s16le_bytes, provider="wetype")
print("Transcript:", text)
```

### TypeScript (`free_asr.ts`)

```ts
import { transcribe } from "./typescript/free_asr.ts";

const text = await transcribe(pcm16kS16leBuffer, "wetype");
console.log("Transcript:", text);
```
