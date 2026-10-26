# Free ASR (`free-asr`)

零第三方依赖的纯 Swift 实时流式语音识别客户端与协议文档，基于豆包输入法 macOS 版（`DoubaoIme.app` v1.0.2）免登录流式 ASR 协议实现。

- **无需登录账号**：使用设备级免登录鉴权（任意 16 位数字 `device_id` + 固定 `aid=685343` + `appkey=OrnqKvSSrs`）。
- **零外部依赖**：服务端原生支持 `16kHz / 单声道 / 16-bit LE PCM` 直传，无需引入 `libopus` 或 `protobuf` C++ 库，仅依赖系统 `Foundation` 与 `AVFoundation`。
- **边说边出字 + 多遍重打分**：实时返回带标点的流式中间结果（`partialResult`），停止说话后约 250ms 返回 Two-Pass / Three-Pass 修正后的最终结果（`finalResult`）。

---

## 目录结构

- [`PROTOCOL.md`](./PROTOCOL.md)：完整协议逆向规范（握手 Header/Query、Protobuf 字段定义、状态机、JSON 载荷格式、REA Evidence ID 与 Ghidra 反编译函数地址表）。
- [`proto/websocket_asr.proto`](./proto/websocket_asr.proto)：还原的 `mammon_internal.WebSocketRequest` / `WebSocketResponse` Protobuf schema。
- [`Sources/DoubaoASR/DoubaoASRClient.swift`](./Sources/DoubaoASR/DoubaoASRClient.swift)：核心 Swift SDK（`DoubaoASRSession` 流式会话 + `DoubaoMicrophoneStreamer` 麦克风采集重采样）。
- [`Sources/doubao-asr-cli/main.swift`](./Sources/doubao-asr-cli/main.swift)：命令行测试工具。

---

## 快速测试

### 1. 用系统语音合成一句话并测试流式识别

```sh
swift run doubao-asr-cli --say "不需要登录账号，我们直接用Swift连上了豆包输入法的流式语音识别接口。"
```

### 2. 从 Mac 麦克风实时录音识别（按回车停止，`--paste` 自动写入剪贴板）

```sh
swift run doubao-asr-cli --paste
```

### 3. 识别本地音频文件（16kHz 16-bit 单声道 WAV/PCM）

```sh
swift run doubao-asr-cli --file /path/to/audio.wav
```

---

## 在 Swift 项目中集成

在 `Package.swift` 中添加依赖，或直接将 [`Sources/DoubaoASR/DoubaoASRClient.swift`](./Sources/DoubaoASR/DoubaoASRClient.swift) 单文件复制到你的项目中：

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
        print("实时预览:", text)
    case let .finalResult(text, latencyMs, _):
        print("最终结果:", text, "耗时: \(latencyMs ?? 0)ms")
    default:
        break
    }
}
```
