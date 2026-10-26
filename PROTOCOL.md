# 豆包输入法 macOS 版 (v1.0.2) 流式语音识别 (ASR) 完整协议规范

本文档记录对 `/Library/Input Methods/DoubaoIme.app`（v1.0.2）语音输入全链路及字节跳动 SAMI Core SDK（`mac_14.91.26-alpha.1-oinput`）的静态反编译与在线实测验证结果。

---

## 1. 整体架构概览

```
[快捷键触发: CGEventTap (Fn / 修饰键长按或单击)]
        │
        ▼
[音频采集: AVCaptureSession -> AVAudioConverter]
  输入: 麦克风原生采样率/声道
  输出: 16,000 Hz, 单声道 (channel=1), 16-bit Signed LE PCM
  分块: maxBlockSize = 3,200 bytes (每块 100 ms)
        │
        ▼
[传输编码层: SAMI Core SDK (sami_core)]
  支持两种在线音频格式:
  1. "pcm": 裸 16kHz 16-bit LE PCM 直传 (enable_net_transport_compress = 0)
  2. "speech_opus" / "ogg_opus": Opus 编码 (16kHz, CBR 32kbps, 20ms 帧)
        │
        ▼
[长连接层: WebSocket over TLS]
  地址: wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws
  备用: wss://frontier-audio-ime-quic.doubao.com/api/v1/ws
  帧格式: WebSocket Binary Frame 承载 Protobuf (mammon_internal.WebSocketRequest / WebSocketResponse)
        │
        ▼
[流式识别与多遍重打分 (Two-Pass / Three-Pass)]
  - 中间结果 (is_interim=true): 实时返回加标点文本 (results[0]) 与无标点流式文本 (results[1])
  - 最终结果 (is_interim=false, is_vad_finished=true): FinishSession 后约 250~320ms 返回大模型重打分结果
        │
        ▼
[上屏与后处理]
  - 逐字上屏 (ASRTypeWriter): 计算新旧文本公共前缀，仅替换尾部差异 (setMarkedText -> insertText / Cmd-V)
  - 可选 AI 智能整理 (SmartOrganize): POST /api/v2/ai/text_organization (SSE text/event-stream)
  - 可选修改对上传 (ModifyPair): POST /api/v3/context/ime/modify_pair/v2
```

---

## 2. WebSocket 握手与免登录鉴权

豆包输入法语音识别采用**设备级免登录鉴权**（`tokenType = 1`），无需登录豆包账号。

### 2.1 连接 URL 与 Query 参数

基础地址：
```
wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws
```

在 `ServiceWrapper::Init` (`0x100293af4`) 中，SDK 将 `OdinToken` JSON（`{"device_id": "...", "aid": "685343"}`）中的 `device_id`、`aid`、`iid` 合并进 URL Query 参数（连同 `OimeCommon.DeviceInfo.commonParams`）：

| Query 参数名 | 示例值 | 是否必填 | 说明 |
|---|---|---|---|
| `aid` | `685343` | **是** | 豆包输入法 macOS 版固定 App ID (`0x000a751f`) |
| `device_id` | `2451255482369287` | **是** | 16 位数字字符串（实测任意随机 16 位数字均可直接通过，无需预注册） |
| `app_name` | `oime_macos` | 推荐 | 应用标识 (`AppInfo.appName`) |
| `channel` | `release` | 推荐 | 渠道名 |
| `device_platform` | `mac` | 推荐 | 平台标识 |
| `device_type` | `mac` | 推荐 | 设备类型 |
| `device_brand` | `Apple` | 推荐 | 品牌 |
| `os` | `macOS` | 推荐 | 操作系统 |
| `os_version` | `15.6.0` | 推荐 | 系统版本 |
| `version_code` | `1.0.2` | 推荐 | 客户端版本 |
| `version_name` | `1.0.2` | 推荐 | 客户端版本名 |
| `update_version_code` | `1` | 可选 | 构建号 |
| `build_number` | `1.0.2` | 可选 | 构建版本 |
| `app_version` | `1.0.2` | 可选 | 应用版本 |

### 2.2 HTTP 握手请求头 (Headers)

在 `SAMIHandle.swift` (`0x100b2374c` / `0x100b22870`) 与 `ServiceWrapper::Init` (`0x100293af4`) 中构造：

| Header 名称 | 值 | 说明 |
|---|---|---|
| `proto-version` | `v2` | 协议版本 |
| `sdk-version` | `2` | SDK 协议代数 |
| `x-tt-token` | `""`（空字符串） | 未登录时为空字符串 |
| `x-tt-e-k` | `<device_id>+W` | 例如 `2451255482369287+W` |
| `x-custom-keepalive` | `true` | 由 `ServiceWrapper::Init` 固定注入 (`0x100ed58e9`) |

---

## 3. Protobuf 帧结构 (`proto/websocket_asr.proto`)

除心跳帧（WebSocket Text Frame `"ping"` / `"pong"`）外，所有客户端请求与服务端响应均为 **WebSocket Binary Frame**，载荷为 Protobuf 编码。

### 3.1 客户端请求：`mammon_internal.WebSocketRequest`

由 `WebSocketRequest::SerializeWithCachedSizes` (`0x10098114c`) 还原：

| 字段编号 | 字段名 | Protobuf 类型 | Wire Tag | 说明 |
|---|---|---|---|---|
| `1` | `token` | `string` | `0x0a` | `tokenType=1` 时置空 `""`（已在 URL Query 传递 `device_id` 与 `aid`） |
| `2` | `appkey` | `string` | `0x12` | 固定 10 字符常量：`"OrnqKvSSrs"` |
| `3` | `namespace` | `string` | `0x1a` | 固定常量：`"ASR"` |
| `4` | `version` | `string` | `0x22` | 空 `""` |
| `5` | `event` | `string` | `0x2a` | `"StartTask"` / `"StartSession"` / `"TaskRequest"` / `"FinishSession"` / `"FinishTask"` |
| `6` | `payload` | `string` | `0x32` | UTF-8 JSON 字符串（见第 4 节） |
| `7` | `data` | `bytes` | `0x3a` | 仅在 `event == "TaskRequest"` 时携带音频块字节 |
| `8` | `task_id` | `string` | `0x42` | 32 位小写 hex UUID（一次识别会话内所有帧保持一致） |
| `9` | `seq_id` | `uint64` | `0x48` | 仅在 `event == "TaskRequest"` 时携带，从 `1` 开始递增 |
| `10` | `session_id` | `string` | `0x52` | 空 `""` |

### 3.2 服务端响应：`mammon_internal.WebSocketResponse`

由 `WebSocketResponse::MergePartialFromCodedStream` (`0x1009821d0`) 还原：

| 字段编号 | 字段名 | Protobuf 类型 | Wire Tag | 说明 |
|---|---|---|---|---|
| `1` | `task_id` | `string` | `0x0a` | 对应请求的 `task_id` |
| `2` | `message_id` | `string` | `0x12` | 服务端消息 ID |
| `3` | `namespace` | `string` | `0x1a` | `"ASR"` |
| `4` | `event` | `string` | `0x22` | `"TaskStarted"` / `"SessionStarted"` / `""`（识别结果帧为空） / `"SessionFinished"` / `"TaskFinished"` / `"SessionFailed"` / `"TaskFailed"` |
| `5` | `status_code` | `int32` | `0x28` | `20000000` 表示成功 (`OK`) |
| `6` | `status_text` | `string` | `0x32` | `"OK"` 或错误原因描述 |
| `7` | `payload` | `string` | `0x3a` | 识别结果 JSON 字符串（见第 4.4 节） |
| `8` | `data` | `bytes` | `0x42` | 二进制载荷（ASR 中未使用） |
| `9` | `seq_id` | `uint64` | `0x48` | 序号 |
| `10` | `session_id` | `string` | `0x52` | 会话 ID |

---

## 4. 会话状态机与各阶段 JSON Payload

### 4.1 阶段一：启动任务 (`StartTask`)

WebSocket 连接建立后，客户端首先发送 `StartTask`（`BuildStartTaskToPb` @ `0x100292060`）：
- `appkey`: `"OrnqKvSSrs"`
- `namespace`: `"ASR"`
- `event`: `"StartTask"`
- `task_id`: `<32位hex UUID>`
- 其余字段为空。

服务端返回 `WebSocketResponse`：
- `event`: `"TaskStarted"`
- `status_code`: `20000000`
- `status_text`: `"OK"`

### 4.2 阶段二：启动会话 (`StartSession`)

客户端紧接着发送 `StartSession`（`BuildStartSessionToPb` @ `0x1002922f8`），无需等待 `TaskStarted` 返回即可流水线发送：
- `appkey`: `"OrnqKvSSrs"`
- `namespace`: `"ASR"`
- `event`: `"StartSession"`
- `task_id`: `<同一个32位hex UUID>`
- `payload`: JSON 字符串，结构如下（由 `AsrOnWorker::Init` @ `0x10028b5fc` 与 `Extra.encode(to:)` @ `0x100b371a4` 构造）：

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
    "device_id": "2451255482369287",
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

> **关于 `audio_info.format`**：
> - `"pcm"`：直接发送 16kHz、单声道、16-bit Signed LE 裸 PCM 数据，无需任何音频编码库。
> - `"speech_opus"`：使用 `libopus`（16kHz, 单声道, `OPUS_APPLICATION_AUDIO`, CBR 32kbps, 20ms 帧）编码。

服务端返回 `WebSocketResponse`：
- `event`: `"SessionStarted"`
- `status_code`: `20000000`

### 4.3 阶段三：流式发送音频块 (`TaskRequest`)

每采集满 `3200` 字节（100ms 16kHz 16-bit 单声道 PCM），发送一帧 `TaskRequest`（`BuildAudioDataToPb` @ `0x100292ca8`）：
- `appkey`: `"OrnqKvSSrs"`
- `namespace`: `"ASR"`
- `event`: `"TaskRequest"`
- `task_id`: `<同一个32位hex UUID>`
- `seq_id`: `1, 2, 3, ...`（从 1 递增）
- `payload`: `{"timestamp_ms": 1761508500123}`（当前毫秒级 Unix 时间戳）
- `data`: `3200` 字节音频数据

### 4.4 阶段四：实时接收识别结果 (`event == ""`)

音频发送过程中，服务端持续推送 `event == ""`、`status_code == 20000000` 的 `WebSocketResponse`，其 `payload` JSON 有三类：

1. **VAD 触发通知**：
   ```json
   {
     "results": [{"text": "", "is_interim": true}],
     "extra": {"vad_start": true}
   }
   ```
2. **流式中间结果 (`is_interim: true`)**：
   `results[0]` 为实时带标点/ITN 的预览文本，`results[1]` 为不带标点的原始流式文本：
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
3. **最终重打分结果 (`is_interim: false, is_vad_finished: true`)**：
   在客户端发送 `FinishSession` 后返回，包含 Three-Pass 大模型修正后的最终文本与耗时统计：
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

### 4.5 阶段五：结束会话与任务 (`FinishSession` -> `SessionFinished` -> `FinishTask`)

1. 用户停止说话后，客户端将剩余不足 3200 字节的尾帧作为最后一个 `TaskRequest` 发出，随后发送 `FinishSession`（`BuildFinishSessionToPb` @ `0x100292780`）：
   - `appkey`: `"OrnqKvSSrs"`
   - `namespace`: `"ASR"`
   - `event`: `"FinishSession"`
   - `task_id`: `<同一个32位hex UUID>`
2. 服务端返回最终识别结果帧（`is_interim: false, is_vad_finished: true`），随后返回 `event == "SessionFinished"`。
3. 客户端收到 `SessionFinished` 后，发送 `FinishTask`（`BuildFinishTaskToPb` @ `0x100292a14`）并关闭连接。

---

## 5. 逆向证据索引 (REA Evidence & Ghidra 函数表)

| 目标文件 | SHA-256 | REA Evidence ID | 说明 |
|---|---|---|---|
| `/Library/Input Methods/DoubaoIme.app/Contents/MacOS/DoubaoIme` | `4b3836dcb8a3e06b01b4c95390c757b71f623c1f7c4141c059e49284f7f6442d` | `ev_145a49b5f55a04af7b188cffa81e1edf0da537a3bf9f020e110580dae0754e20` | 主程序通用二进制 Mach-O 结构与导入符号 |
| `/Library/Input Methods/DoubaoIme.app` | `4b3836dcb8a3e06b01b4c95390c757b71f623c1f7c4141c059e49284f7f6442d` | `ev_60e311381b34a601a05789a0730c70e1ece8d9d0210d5f968035341f31e02512` | Bundle `@rpath` 动态库依赖图 |
| `DoubaoIme.arm64` (arm64 slice) | `266f49f6bcb62e43c5170620d4b86e2e4c4ef873bcce624ef1a90b9c46244983` | `ev_356efd780d3b339ee6da9b6f354b5d31aebf42fce0e503ceee1c0759c436b2cc` | Ghidra 反编译基准 (`__TEXT` @ `0x100000000`) |
| `OimeCommon.framework/Versions/A/OimeCommon` | `fb6d9f1d0d5e6935455779fb3bc6bf53d95fd0d0f32c37c5bb65ef5bd83ce8e4` | `ev_c46b8e4f13b60e2bbb91b4c0990b7e9fea07d32e01fc27df94feeac9933711ec` | `AppInfo` 与 `DeviceInfo` 实现 |

### 关键函数地址对照表 (`DoubaoIme.arm64`)

| 地址 | 符号 / 所属模块 | 作用 |
|---|---|---|
| `0x100b31b5c` | `SAMIHandle.swift` | 初始化连接池与基础参数（`appKey = "OrnqKvSSrs"`, `businessInfo = "wave"`） |
| `0x100b3913c` | `SAMIHandle.swift` | 创建 `SAMICore_AsrContextCreateParameterV2` 并启动 `SAMICore` 句柄 |
| `0x100b22870` | `Header.encode(to:)` | 编码 `proto-version`、`sdk-version`、`x-tt-token`、`x-tt-e-k` |
| `0x100b22de4` | `OdinToken.encode(to:)` | 编码 `device_id`、`aid` |
| `0x100b371a4` | `Extra.encode(to:)` | 编码 `StartSession` 的 32 个 `extra` 字段 |
| `0x10028b5fc` | `AsrOnWorker::Init` (`asr_on_worker.cpp`) | 解析参数并构建 `StartSession` payload JSON |
| `0x10028d7a8` | `AsrOnWorker::SendAudioData` | 音频分帧与队列入队 |
| `0x10028ea20` | `AsrOnWorker::OnMessage` | 处理服务端 `TaskStarted`、`SessionStarted`、流式结果、`SessionFinished` |
| `0x100291384` | `AsrOnWorker::SendStartProtocol` | 发送 `StartTask` 与 `StartSession` |
| `0x10029154c` | `AsrOnWorker::SendFinishProtocol` | 发送 `FinishTask` |
| `0x100292060` | `BuildStartTaskToPb` (`protocol.cpp`) | 构造 `StartTask` Protobuf 帧 |
| `0x1002922f8` | `BuildStartSessionToPb` (`protocol.cpp`) | 构造 `StartSession` Protobuf 帧 |
| `0x100292780` | `BuildFinishSessionToPb` (`protocol.cpp`) | 构造 `FinishSession` Protobuf 帧 |
| `0x100292a14` | `BuildFinishTaskToPb` (`protocol.cpp`) | 构造 `FinishTask` Protobuf 帧 |
| `0x100292ca8` | `BuildAudioDataToPb` (`protocol.cpp`) | 构造 `TaskRequest` 音频数据 Protobuf 帧 |
| `0x100293af4` | `ServiceWrapper::Init` (`service_wrapper.cpp`) | 解析 Header/Query/Token 并初始化 WebSocket 客户端 |
| `0x10023e22c` | `SAMIWebsocketTTNetClient::init` | 拼接 URL Query 与 Header 并建立 WebSocket 连接 |
| `0x10098114c` | `WebSocketRequest::SerializeWithCachedSizes` | Protobuf 请求序列化 |
| `0x1009821d0` | `WebSocketResponse::MergePartialFromCodedStream` | Protobuf 响应反序列化 |
