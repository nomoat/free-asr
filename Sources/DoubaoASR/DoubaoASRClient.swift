import Foundation
import AVFoundation

// MARK: - Public Types

public struct DoubaoASRConfig: Sendable {
    public var endpoint: String
    public var appKey: String
    public var appId: String
    public var deviceId: String
    public var enablePunctuation: Bool
    public var enableTwoPass: Bool
    public var enableThreePass: Bool
    public var enableTextFilter: Bool
    public var removeSpaceBetweenHanNum: Bool
    public var removeSpaceBetweenHanEng: Bool

    public init(
        endpoint: String = "wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws",
        appKey: String = "OrnqKvSSrs",
        appId: String = "685343",
        deviceId: String? = nil,
        enablePunctuation: Bool = true,
        enableTwoPass: Bool = true,
        enableThreePass: Bool = true,
        enableTextFilter: Bool = true,
        removeSpaceBetweenHanNum: Bool = true,
        removeSpaceBetweenHanEng: Bool = false
    ) {
        self.endpoint = endpoint
        self.appKey = appKey
        self.appId = appId
        self.deviceId = deviceId ?? Self.defaultDeviceId()
        self.enablePunctuation = enablePunctuation
        self.enableTwoPass = enableTwoPass
        self.enableThreePass = enableThreePass
        self.enableTextFilter = enableTextFilter
        self.removeSpaceBetweenHanNum = removeSpaceBetweenHanNum
        self.removeSpaceBetweenHanEng = removeSpaceBetweenHanEng
    }

    public static func defaultDeviceId() -> String {
        if let saved = UserDefaults.standard.string(forKey: "DoubaoASR.deviceId"), !saved.isEmpty {
            return saved
        }
        var digits = "7"
        for _ in 0..<15 {
            digits.append(String(Int.random(in: 0...9)))
        }
        UserDefaults.standard.set(digits, forKey: "DoubaoASR.deviceId")
        return digits
    }
}

public enum DoubaoASREvent: Sendable {
    case taskStarted(taskId: String)
    case sessionStarted(taskId: String)
    case vadStarted
    case partialResult(text: String, rawText: String?, seqId: UInt64)
    case finalResult(text: String, latencyMs: Int?, seqId: UInt64)
    case sessionFinished(taskId: String)
    case taskFinished(taskId: String)
}

public enum DoubaoASRError: LocalizedError {
    case invalidURL
    case serverError(event: String, code: Int64, message: String)
    case audioSetupFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid WebSocket URL"
        case let .serverError(event, code, message):
            return "Doubao ASR server error (\(event), code \(code)): \(message)"
        case let .audioSetupFailed(reason):
            return "Audio setup failed: \(reason)"
        }
    }
}

// MARK: - Protobuf Wire Codec (mammon_internal.WebSocketRequest / WebSocketResponse)

enum DoubaoProtobuf {
    static func encodeVarint(_ value: UInt64) -> Data {
        var v = value
        var data = Data()
        while v >= 0x80 {
            data.append(UInt8((v & 0x7f) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v))
        return data
    }

    static func encodeString(field: Int, value: String) -> Data {
        guard !value.isEmpty, let bytes = value.data(using: .utf8) else { return Data() }
        return encodeBytes(field: field, value: bytes)
    }

    static func encodeBytes(field: Int, value: Data) -> Data {
        guard !value.isEmpty else { return Data() }
        var data = Data()
        let tag = UInt64((field << 3) | 2)
        data.append(encodeVarint(tag))
        data.append(encodeVarint(UInt64(value.count)))
        data.append(value)
        return data
    }

    static func encodeUInt64(field: Int, value: UInt64) -> Data {
        guard value != 0 else { return Data() }
        var data = Data()
        let tag = UInt64((field << 3) | 0)
        data.append(encodeVarint(tag))
        data.append(encodeVarint(value))
        return data
    }

    /// Serializes `mammon_internal.WebSocketRequest`
    /// Field 1: token (string)
    /// Field 2: appkey (string)
    /// Field 3: namespace (string)
    /// Field 4: version (string)
    /// Field 5: event (string)
    /// Field 6: payload (string)
    /// Field 7: data (bytes)
    /// Field 8: task_id (string)
    /// Field 9: seq_id (uint64)
    /// Field 10: session_id (string)
    static func buildRequest(
        token: String = "",
        appkey: String,
        namespace: String = "ASR",
        version: String = "",
        event: String,
        payload: String = "",
        data: Data = Data(),
        taskId: String,
        seqId: UInt64 = 0,
        sessionId: String = ""
    ) -> Data {
        var out = Data()
        out.append(encodeString(field: 1, value: token))
        out.append(encodeString(field: 2, value: appkey))
        out.append(encodeString(field: 3, value: namespace))
        out.append(encodeString(field: 4, value: version))
        out.append(encodeString(field: 5, value: event))
        out.append(encodeString(field: 6, value: payload))
        out.append(encodeBytes(field: 7, value: data))
        out.append(encodeString(field: 8, value: taskId))
        out.append(encodeUInt64(field: 9, value: seqId))
        out.append(encodeString(field: 10, value: sessionId))
        return out
    }

    struct Response {
        var taskId = ""
        var messageId = ""
        var namespace = ""
        var event = ""
        var statusCode: Int64 = 0
        var statusText = ""
        var payload = ""
        var data = Data()
        var seqId: UInt64 = 0
        var sessionId = ""
    }

    /// Deserializes `mammon_internal.WebSocketResponse`
    /// Field 1: task_id (string)
    /// Field 2: message_id (string)
    /// Field 3: namespace (string)
    /// Field 4: event (string)
    /// Field 5: status_code (int32/varint)
    /// Field 6: status_text (string)
    /// Field 7: payload (string)
    /// Field 8: data (bytes)
    /// Field 9: seq_id (uint64)
    /// Field 10: session_id (string)
    static func decodeResponse(_ bytes: Data) -> Response {
        var res = Response()
        let buf = [UInt8](bytes)
        var i = 0
        func readVarint() -> UInt64 {
            var val: UInt64 = 0
            var shift: UInt64 = 0
            while i < buf.count {
                let b = UInt64(buf[i])
                i += 1
                val |= (b & 0x7f) << shift
                if (b & 0x80) == 0 { break }
                shift += 7
            }
            return val
        }
        while i < buf.count {
            let tag = readVarint()
            let field = Int(tag >> 3)
            let wire = Int(tag & 7)
            if wire == 0 {
                let v = readVarint()
                if field == 5 {
                    res.statusCode = Int64(Int32(truncatingIfNeeded: v))
                } else if field == 9 {
                    res.seqId = v
                }
            } else if wire == 2 {
                let len = Int(readVarint())
                guard i + len <= buf.count else { break }
                let sub = Data(buf[i..<(i + len)])
                i += len
                let str = String(data: sub, encoding: .utf8) ?? ""
                switch field {
                case 1: res.taskId = str
                case 2: res.messageId = str
                case 3: res.namespace = str
                case 4: res.event = str
                case 6: res.statusText = str
                case 7: res.payload = str
                case 8: res.data = sub
                case 10: res.sessionId = str
                default: break
                }
            } else {
                break
            }
        }
        return res
    }
}

// MARK: - Streaming Session Client

public final class DoubaoASRSession: @unchecked Sendable {
    public let config: DoubaoASRConfig
    public let taskId: String

    private var urlSession: URLSession?
    private var wsTask: URLSessionWebSocketTask?
    private var seqId: UInt64 = 0
    private var pcmCarry = Data()
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<DoubaoASREvent, Error>.Continuation?

    public static let chunkBytes = 3200 // 100ms of 16kHz 16-bit mono PCM

    public init(config: DoubaoASRConfig = DoubaoASRConfig()) {
        self.config = config
        self.taskId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public func start() throws -> AsyncThrowingStream<DoubaoASREvent, Error> {
        guard var comps = URLComponents(string: config.endpoint) else {
            throw DoubaoASRError.invalidURL
        }
        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let osVerStr = "\(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"

        comps.queryItems = [
            URLQueryItem(name: "aid", value: config.appId),
            URLQueryItem(name: "device_id", value: config.deviceId),
            URLQueryItem(name: "app_name", value: "oime_macos"),
            URLQueryItem(name: "channel", value: "release"),
            URLQueryItem(name: "device_platform", value: "mac"),
            URLQueryItem(name: "device_type", value: "mac"),
            URLQueryItem(name: "device_brand", value: "Apple"),
            URLQueryItem(name: "os", value: "macOS"),
            URLQueryItem(name: "os_version", value: osVerStr),
            URLQueryItem(name: "version_code", value: "1.0.2"),
            URLQueryItem(name: "version_name", value: "1.0.2"),
            URLQueryItem(name: "update_version_code", value: "1"),
            URLQueryItem(name: "build_number", value: "1.0.2"),
            URLQueryItem(name: "app_version", value: "1.0.2")
        ]
        guard let url = comps.url else {
            throw DoubaoASRError.invalidURL
        }

        var req = URLRequest(url: url)
        req.setValue("v2", forHTTPHeaderField: "proto-version")
        req.setValue("2", forHTTPHeaderField: "sdk-version")
        req.setValue("", forHTTPHeaderField: "x-tt-token")
        req.setValue("\(config.deviceId)+W", forHTTPHeaderField: "x-tt-e-k")
        req.setValue("true", forHTTPHeaderField: "x-custom-keepalive")

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: req)
        self.urlSession = session
        self.wsTask = ws

        let stream = AsyncThrowingStream<DoubaoASREvent, Error> { cont in
            self.continuation = cont
        }

        ws.resume()
        receiveNext()

        // 1. Send StartTask
        let startTaskData = DoubaoProtobuf.buildRequest(
            appkey: config.appKey,
            event: "StartTask",
            taskId: taskId
        )
        ws.send(.data(startTaskData)) { _ in }

        // 2. Send StartSession
        let startSessionPayload = buildStartSessionPayload(osVersion: osVerStr)
        let startSessionData = DoubaoProtobuf.buildRequest(
            appkey: config.appKey,
            event: "StartSession",
            payload: startSessionPayload,
            taskId: taskId
        )
        ws.send(.data(startSessionData)) { _ in }

        return stream
    }

    /// Feed 16kHz 16-bit signed little-endian mono PCM bytes.
    public func sendPCM(_ data: Data) {
        lock.lock()
        pcmCarry.append(data)
        var chunks: [(Data, UInt64)] = []
        while pcmCarry.count >= Self.chunkBytes {
            let chunk = Data(pcmCarry.prefix(Self.chunkBytes))
            pcmCarry.removeFirst(Self.chunkBytes)
            seqId += 1
            chunks.append((chunk, seqId))
        }
        let ws = self.wsTask
        lock.unlock()

        for (chunk, seq) in chunks {
            sendAudioChunk(chunk, seq: seq, via: ws)
        }
    }

    /// Flush remaining buffered PCM and send FinishSession.
    public func finishAudio() {
        lock.lock()
        var lastChunk: (Data, UInt64)?
        if !pcmCarry.isEmpty {
            seqId += 1
            lastChunk = (pcmCarry, seqId)
            pcmCarry.removeAll()
        }
        let ws = self.wsTask
        lock.unlock()

        if let (chunk, seq) = lastChunk {
            sendAudioChunk(chunk, seq: seq, via: ws)
        }

        let finishSessionData = DoubaoProtobuf.buildRequest(
            appkey: config.appKey,
            event: "FinishSession",
            taskId: taskId
        )
        ws?.send(.data(finishSessionData)) { _ in }
    }

    public func close() {
        let finishTaskData = DoubaoProtobuf.buildRequest(
            appkey: config.appKey,
            event: "FinishTask",
            taskId: taskId
        )
        wsTask?.send(.data(finishTaskData)) { [weak self] _ in
            self?.wsTask?.cancel(with: .normalClosure, reason: nil)
            self?.urlSession?.invalidateAndCancel()
        }
        continuation?.finish()
    }

    private func sendAudioChunk(_ chunk: Data, seq: UInt64, via ws: URLSessionWebSocketTask?) {
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        let req = DoubaoProtobuf.buildRequest(
            appkey: config.appKey,
            event: "TaskRequest",
            payload: "{\"timestamp_ms\":\(ts)}",
            data: chunk,
            taskId: taskId,
            seqId: seq
        )
        ws?.send(.data(req)) { _ in }
    }

    private func receiveNext() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .data(let d):
                    let shouldContinue = self.handleBinaryMessage(d)
                    if shouldContinue {
                        self.receiveNext()
                    }
                case .string:
                    self.receiveNext()
                @unknown default:
                    self.receiveNext()
                }
            case .failure(let err):
                self.continuation?.finish(throwing: err)
            }
        }
    }

    private func handleBinaryMessage(_ data: Data) -> Bool {
        let res = DoubaoProtobuf.decodeResponse(data)
        switch res.event {
        case "TaskStarted":
            continuation?.yield(.taskStarted(taskId: res.taskId))
            return true
        case "SessionStarted":
            continuation?.yield(.sessionStarted(taskId: res.taskId))
            return true
        case "SessionFinished":
            continuation?.yield(.sessionFinished(taskId: res.taskId))
            close()
            return false
        case "TaskFinished":
            continuation?.yield(.taskFinished(taskId: res.taskId))
            continuation?.finish()
            return false
        case "SessionFailed", "TaskFailed":
            continuation?.finish(
                throwing: DoubaoASRError.serverError(
                    event: res.event,
                    code: res.statusCode,
                    message: res.statusText
                )
            )
            return false
        default:
            break
        }

        guard !res.payload.isEmpty,
              let jsonData = res.payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return true
        }

        let extra = obj["extra"] as? [String: Any]
        let seq = (extra?["seq_id"] as? UInt64) ?? UInt64((extra?["seq_id"] as? Int) ?? 0)

        if let results = obj["results"] as? [[String: Any]], let first = results.first {
            let text = (first["text"] as? String) ?? ""
            let isInterim = (first["is_interim"] as? Bool) ?? true
            let isVadFinished = (first["is_vad_finished"] as? Bool) ?? false

            if text.isEmpty && (extra?["vad_start"] as? Bool) == true && isInterim {
                continuation?.yield(.vadStarted)
                return true
            }

            if !isInterim || isVadFinished {
                let latency = extra?["lastpkt_latency"] as? Int
                continuation?.yield(.finalResult(text: text, latencyMs: latency, seqId: seq))
            } else if !text.isEmpty {
                let rawText = results.count > 1 ? (results[1]["text"] as? String) : nil
                continuation?.yield(.partialResult(text: text, rawText: rawText, seqId: seq))
            }
        }
        return true
    }

    private func buildStartSessionPayload(osVersion: String) -> String {
        let dict: [String: Any] = [
            "audio_info": [
                "channel": 1,
                "format": "pcm",
                "sample_rate": 16000
            ],
            "enable_punctuation": config.enablePunctuation,
            "enable_speech_rejection": false,
            "extra": [
                "app_name": "oime_macos",
                "app_version": "1.0.2",
                "cell_compress_rate": 8,
                "device_brand": "Apple",
                "device_id": config.deviceId,
                "device_model": "Mac",
                "disable_user_words": false,
                "enable_asr_format": true,
                "enable_asr_threepass": config.enableThreePass,
                "enable_asr_twopass": config.enableTwoPass,
                "enable_print_chinese": true,
                "enable_text_filter": config.enableTextFilter,
                "finish_wait_offline_time": 1000,
                "format_space_at_newline": false,
                "input_mode": "wave",
                "join_user_experience_improve_program": false,
                "max_wait_switch_offline_time": 4000,
                "offline_wait_online_interval_time": 200,
                "offline_wait_online_time": 1000,
                "os": "macOS",
                "os_version": osVersion,
                "remove_space_between_han_eng": config.removeSpaceBetweenHanEng,
                "remove_space_between_han_num": config.removeSpaceBetweenHanNum,
                "retry_server_code": [Int](),
                "strong_ddc": true,
                "use_twopass_retry": true
            ]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Live Microphone Recorder -> 16kHz Mono Int16 PCM

public final class DoubaoMicrophoneStreamer {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    public init() {}

    public func start(onPCM: @escaping @Sendable (Data) -> Void) throws {
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            throw DoubaoASRError.audioSetupFailed("No valid microphone input format")
        }
        guard let conv = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw DoubaoASRError.audioSetupFailed("Could not create AVAudioConverter to 16kHz Int16 mono")
        }
        self.converter = conv

        inputNode.installTap(onBus: 0, bufferSize: 1600, format: hwFormat) { [targetFormat] buffer, _ in
            let ratio = targetFormat.sampleRate / hwFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
                return
            }
            var error: NSError?
            var consumed = false
            conv.convert(to: outBuffer, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if error == nil, outBuffer.frameLength > 0, let ptr = outBuffer.int16ChannelData?[0] {
                let byteCount = Int(outBuffer.frameLength) * MemoryLayout<Int16>.size
                let data = Data(bytes: ptr, count: byteCount)
                onPCM(data)
            }
        }

        engine.prepare()
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
