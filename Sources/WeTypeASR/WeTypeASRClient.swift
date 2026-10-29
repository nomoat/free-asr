import Foundation
import AVFoundation
import AudioToolbox
import CommonCrypto
import CryptoKit

// MARK: - Public Types

public struct WeTypeASRConfig: Sendable {
    public var host: String
    public var deviceName: String
    public var clientVersion: String
    public var systemVersion: String

    public init(
        host: String = "wetype.weixin.qq.com",
        deviceName: String = "Mac17,8",
        clientVersion: String = "3.0.0(670)",
        systemVersion: String = "27.0.0"
    ) {
        self.host = host
        self.deviceName = deviceName
        self.clientVersion = clientVersion
        self.systemVersion = systemVersion
    }
}

public enum WeTypeASREvent: Sendable {
    case sessionStarted(uin: String, voiceId: String)
    case partialResult(text: String, seq: UInt32)
    case finalResult(text: String, seq: UInt32)
}

public enum WeTypeASRError: LocalizedError {
    case handshakeFailed(String)
    case cryptoFailed(Int32)
    case opusSetupFailed(OSStatus)
    case audioSetupFailed(String)
    case serverError(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .handshakeFailed(let msg): return "WeType handshake failed: \(msg)"
        case .cryptoFailed(let st): return "CommonCrypto CCCrypt failed: \(st)"
        case .opusSetupFailed(let st): return "AudioToolbox Opus encoder failed: \(st)"
        case .audioSetupFailed(let msg): return "Microphone setup failed: \(msg)"
        case .serverError(let code, let msg): return "WeType ASR error (\(code)): \(msg)"
        }
    }
}

// MARK: - 256-bit Unsigned Integer for secp128r1 Field Arithmetic

struct UInt256: Equatable, Comparable {
    // Little-endian 64-bit limbs: w0 + w1*2^64 + w2*2^128 + w3*2^192
    var w: (UInt64, UInt64, UInt64, UInt64)

    static let zero = UInt256(w: (0, 0, 0, 0))
    static let one  = UInt256(w: (1, 0, 0, 0))

    init(w: (UInt64, UInt64, UInt64, UInt64)) {
        self.w = w
    }

    init(hi128: UInt64, lo128: UInt64) {
        self.w = (lo128, hi128, 0, 0)
    }

    init?(hex32: String) {
        guard hex32.count == 32,
              let hi = UInt64(hex32.prefix(16), radix: 16),
              let lo = UInt64(hex32.suffix(16), radix: 16) else { return nil }
        self.w = (lo, hi, 0, 0)
    }

    var hex32: String {
        String(format: "%016llX%016llX", w.1, w.0)
    }

    var isZero: Bool {
        w.0 == 0 && w.1 == 0 && w.2 == 0 && w.3 == 0
    }

    func bit(_ idx: Int) -> Bool {
        let wordIdx = idx >> 6
        let bitIdx = idx & 63
        let limb: UInt64
        switch wordIdx {
        case 0: limb = w.0
        case 1: limb = w.1
        case 2: limb = w.2
        default: limb = w.3
        }
        return ((limb >> bitIdx) & 1) == 1
    }

    static func == (lhs: UInt256, rhs: UInt256) -> Bool {
        lhs.w == rhs.w
    }

    static func < (lhs: UInt256, rhs: UInt256) -> Bool {
        if lhs.w.3 != rhs.w.3 { return lhs.w.3 < rhs.w.3 }
        if lhs.w.2 != rhs.w.2 { return lhs.w.2 < rhs.w.2 }
        if lhs.w.1 != rhs.w.1 { return lhs.w.1 < rhs.w.1 }
        return lhs.w.0 < rhs.w.0
    }

    static func add(_ a: UInt256, _ b: UInt256) -> UInt256 {
        let (r0, c0) = a.w.0.addingReportingOverflow(b.w.0)
        let (t1, c1a) = a.w.1.addingReportingOverflow(b.w.1)
        let (r1, c1b) = t1.addingReportingOverflow(c0 ? 1 : 0)
        let c1 = c1a || c1b
        let (t2, c2a) = a.w.2.addingReportingOverflow(b.w.2)
        let (r2, c2b) = t2.addingReportingOverflow(c1 ? 1 : 0)
        let c2 = c2a || c2b
        let (t3, _) = a.w.3.addingReportingOverflow(b.w.3)
        let (r3, _) = t3.addingReportingOverflow(c2 ? 1 : 0)
        return UInt256(w: (r0, r1, r2, r3))
    }

    static func sub(_ a: UInt256, _ b: UInt256) -> UInt256 {
        let (r0, b0) = a.w.0.subtractingReportingOverflow(b.w.0)
        let (t1, b1a) = a.w.1.subtractingReportingOverflow(b.w.1)
        let (r1, b1b) = t1.subtractingReportingOverflow(b0 ? 1 : 0)
        let bw1 = b1a || b1b
        let (t2, b2a) = a.w.2.subtractingReportingOverflow(b.w.2)
        let (r2, b2b) = t2.subtractingReportingOverflow(bw1 ? 1 : 0)
        let bw2 = b2a || b2b
        let (t3, _) = a.w.3.subtractingReportingOverflow(b.w.3)
        let (r3, _) = t3.subtractingReportingOverflow(bw2 ? 1 : 0)
        return UInt256(w: (r0, r1, r2, r3))
    }

    func shl1() -> UInt256 {
        let r3 = (w.3 << 1) | (w.2 >> 63)
        let r2 = (w.2 << 1) | (w.1 >> 63)
        let r1 = (w.1 << 1) | (w.0 >> 63)
        let r0 = w.0 << 1
        return UInt256(w: (r0, r1, r2, r3))
    }
}

// MARK: - SEC 2 secp128r1 ECDH (Crypto::ECDHKeyGenerator @ 0x1015c5620)

enum Secp128r1 {
    static let p  = UInt256(hi128: 0xFFFFFFFDFFFFFFFF, lo128: 0xFFFFFFFFFFFFFFFF)
    static let pMinus2 = UInt256(hi128: 0xFFFFFFFDFFFFFFFF, lo128: 0xFFFFFFFFFFFFFFFD)
    static let a  = UInt256(hi128: 0xFFFFFFFDFFFFFFFF, lo128: 0xFFFFFFFFFFFFFFFC)
    static let gx = UInt256(hi128: 0x161FF7528B899B2D, lo128: 0x0C28607CA52C5B86)
    static let gy = UInt256(hi128: 0xCF5AC8395BAFEB13, lo128: 0xC02DA292DDED7A83)

    struct Point: Equatable {
        var x: UInt256
        var y: UInt256
    }

    static let generator = Point(x: gx, y: gy)

    static func modAdd(_ x: UInt256, _ y: UInt256) -> UInt256 {
        let s = UInt256.add(x, y)
        return s >= p ? UInt256.sub(s, p) : s
    }

    static func modSub(_ x: UInt256, _ y: UInt256) -> UInt256 {
        if x >= y { return UInt256.sub(x, y) }
        return UInt256.sub(UInt256.add(x, p), y)
    }

    static func modMul(_ x: UInt256, _ y: UInt256) -> UInt256 {
        var res = UInt256.zero
        var base = x
        for i in 0..<128 {
            if y.bit(i) {
                res = modAdd(res, base)
            }
            base = modAdd(base, base)
        }
        return res
    }

    static func modInv(_ x: UInt256) -> UInt256 {
        var res = UInt256.one
        var base = x
        for i in 0..<128 {
            if pMinus2.bit(i) {
                res = modMul(res, base)
            }
            base = modMul(base, base)
        }
        return res
    }

    static func pointAdd(_ p1: Point?, _ p2: Point?) -> Point? {
        guard let p1 else { return p2 }
        guard let p2 else { return p1 }
        if p1.x == p2.x && modAdd(p1.y, p2.y).isZero {
            return nil
        }
        let lam: UInt256
        if p1 == p2 {
            let num = modAdd(modMul(UInt256(hi128: 0, lo128: 3), modMul(p1.x, p1.x)), a)
            let den = modInv(modAdd(p1.y, p1.y))
            lam = modMul(num, den)
        } else {
            let num = modSub(p2.y, p1.y)
            let den = modInv(modSub(p2.x, p1.x))
            lam = modMul(num, den)
        }
        let x3 = modSub(modSub(modMul(lam, lam), p1.x), p2.x)
        let y3 = modSub(modMul(lam, modSub(p1.x, x3)), p1.y)
        return Point(x: x3, y: y3)
    }

    static func scalarMul(_ k: UInt256, point: Point = generator) -> Point? {
        var res: Point? = nil
        var cur: Point? = point
        for i in 0..<128 {
            if k.bit(i) {
                res = pointAdd(res, cur)
            }
            cur = pointAdd(cur, cur)
        }
        return res
    }

    static func generateKeyPair() -> (privateKey: UInt256, publicKeyHex: String) {
        let hi = UInt64.random(in: 1...0xFFFFFFFD00000000)
        let lo = UInt64.random(in: 1...UInt64.max)
        let priv = UInt256(hi128: hi, lo128: lo)
        let pub = scalarMul(priv)!
        return (priv, "04" + pub.x.hex32 + pub.y.hex32)
    }

    static func deriveAESKey(privateKey: UInt256, serverPublicKeyHex: String) -> String? {
        guard serverPublicKeyHex.count == 66, serverPublicKeyHex.hasPrefix("04") else { return nil }
        let body = serverPublicKeyHex.dropFirst(2)
        guard let sx = UInt256(hex32: String(body.prefix(32))),
              let sy = UInt256(hex32: String(body.suffix(32))),
              let shared = scalarMul(privateKey, point: Point(x: sx, y: sy)) else {
            return nil
        }
        return shared.x.hex32
    }
}

// MARK: - Cryptography, Signatures & Snappy

enum WeTypeCrypto {
    static let signKey = "zN7rB3bL4pO8jW1o"
    static let handshakeAESKey = "D4Y5U3Y2M0C0T7N4P1P7O2N6E1I2Y1U6"

    static func md5Upper(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02X", $0) }.joined()
    }

    static func sha256Upper(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02X", $0) }.joined()
    }

    static func randomLowercase(_ count: Int) -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz")
        return String((0..<count).map { _ in chars.randomElement()! })
    }

    static func randomDigits(_ count: Int) -> String {
        let chars = Array("0123456789")
        return String((0..<count).map { _ in chars.randomElement()! })
    }

    static func generateDeviceCode(deviceName: String) -> String {
        let padCount = max(0, 17 - deviceName.count)
        let padded = String(repeating: "0", count: padCount) + deviceName
        let prefix32 = "MAC" + String(padded.prefix(17)) + randomLowercase(12)
        let md5 = md5Upper(Data((prefix32 + signKey).utf8))
        return prefix32 + md5
    }

    static func aes256ECB(operation: CCOperation, keyASCII: String, data: Data) throws -> Data {
        if operation == CCOperation(kCCDecrypt) && data.isEmpty { return Data() }
        let keyBytes = Array(keyASCII.utf8)
        let outCap = data.count + kCCBlockSizeAES128 * 2
        var outBuf = Data(count: outCap)
        var outMoved: size_t = 0
        let status = outBuf.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                CCCrypt(
                    operation,
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding | kCCOptionECBMode),
                    keyBytes,
                    keyBytes.count,
                    nil,
                    inPtr.baseAddress,
                    data.count,
                    outPtr.baseAddress,
                    outCap,
                    &outMoved
                )
            }
        }
        guard status == kCCSuccess else {
            throw WeTypeASRError.cryptoFailed(status)
        }
        outBuf.count = outMoved
        return outBuf
    }

    static func snappyCompress(_ data: Data) -> Data {
        var out = WeTypeProtobuf.encodeVarint(UInt64(data.count))
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let chunkLen = min(65536, bytes.count - i)
            let ln = chunkLen - 1
            if ln < 60 {
                out.append(UInt8(ln << 2))
            } else if ln < 256 {
                out.append(UInt8(60 << 2))
                out.append(UInt8(ln))
            } else {
                out.append(UInt8(61 << 2))
                out.append(UInt8(ln & 0xFF))
                out.append(UInt8((ln >> 8) & 0xFF))
            }
            out.append(contentsOf: bytes[i..<(i + chunkLen)])
            i += chunkLen
        }
        return out
    }

    static func snappyDecompress(_ data: Data) -> Data {
        let buf = [UInt8](data)
        var i = 0
        var shift: UInt64 = 0
        var _uncompLen: UInt64 = 0
        while i < buf.count {
            let b = buf[i]
            i += 1
            _uncompLen |= UInt64(b & 0x7F) << shift
            if (b & 0x80) == 0 { break }
            shift += 7
        }
        var out = [UInt8]()
        while i < buf.count {
            let tag = Int(buf[i])
            i += 1
            let type = tag & 3
            if type == 0 {
                var len = tag >> 2
                if len >= 60 {
                    let nb = len - 59
                    len = 0
                    for k in 0..<nb where i + k < buf.count {
                        len |= Int(buf[i + k]) << (8 * k)
                    }
                    i += nb
                }
                len += 1
                let end = min(buf.count, i + len)
                out.append(contentsOf: buf[i..<end])
                i = end
            } else {
                var len = 0
                var offset = 0
                if type == 1 {
                    len = ((tag >> 2) & 7) + 4
                    offset = ((tag >> 5) << 8) | Int(buf[i])
                    i += 1
                } else if type == 2 {
                    len = (tag >> 2) + 1
                    offset = Int(buf[i]) | (Int(buf[i + 1]) << 8)
                    i += 2
                } else {
                    len = (tag >> 2) + 1
                    offset = Int(buf[i]) | (Int(buf[i + 1]) << 8) | (Int(buf[i + 2]) << 16) | (Int(buf[i + 3]) << 24)
                    i += 4
                }
                guard offset > 0 && offset <= out.count else { break }
                for _ in 0..<len {
                    out.append(out[out.count - offset])
                }
            }
        }
        return Data(out)
    }
}

// MARK: - Protobuf Wire Codec

enum WeTypeProtobuf {
    static func encodeVarint(_ value: UInt64) -> Data {
        var v = value
        var data = Data()
        while v >= 0x80 {
            data.append(UInt8((v & 0x7F) | 0x80))
            v >>= 7
        }
        data.append(UInt8(v))
        return data
    }

    static func encodeUInt(_ field: Int, _ value: UInt64) -> Data {
        var d = encodeVarint(UInt64((field << 3) | 0))
        d.append(encodeVarint(value))
        return d
    }

    static func encodeBytes(_ field: Int, _ value: Data) -> Data {
        var d = encodeVarint(UInt64((field << 3) | 2))
        d.append(encodeVarint(UInt64(value.count)))
        d.append(value)
        return d
    }

    static func encodeString(_ field: Int, _ value: String) -> Data {
        encodeBytes(field, Data(value.utf8))
    }

    enum FieldValue {
        case varint(UInt64)
        case bytes(Data)
    }

    static func parse(_ data: Data) -> [(field: Int, value: FieldValue)] {
        let buf = [UInt8](data)
        var i = 0
        var out = [(Int, FieldValue)]()
        func readVarint() -> UInt64? {
            var val: UInt64 = 0
            var shift: UInt64 = 0
            while i < buf.count {
                let b = UInt64(buf[i])
                i += 1
                val |= (b & 0x7F) << shift
                if (b & 0x80) == 0 { return val }
                shift += 7
            }
            return nil
        }
        while i < buf.count {
            guard let tag = readVarint() else { break }
            let f = Int(tag >> 3)
            let w = Int(tag & 7)
            if w == 0 {
                guard let v = readVarint() else { break }
                out.append((f, .varint(v)))
            } else if w == 2 {
                guard let ln = readVarint(), i + Int(ln) <= buf.count else { break }
                let sub = Data(buf[i..<(i + Int(ln))])
                i += Int(ln)
                out.append((f, .bytes(sub)))
            } else {
                break
            }
        }
        return out
    }
}

// MARK: - AudioToolbox Opus Encoder (TROpusTool #!OPUS_RAW_V1 Framing)

final class WeTypeOpusEncoder {
    private var converter: AudioConverterRef?
    private var isFirstChunk = true
    private var currentInputData = Data()
    private var currentInputConsumed = false

    init() throws {
        var inDesc = AudioStreamBasicDescription(
            mSampleRate: 16000.0,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var outDesc = AudioStreamBasicDescription(
            mSampleRate: 16000.0,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 320,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var conv: AudioConverterRef?
        let status = AudioConverterNew(&inDesc, &outDesc, &conv)
        guard status == noErr, let conv else {
            throw WeTypeASRError.opusSetupFailed(status)
        }
        var bitrate: UInt32 = 64000
        AudioConverterSetProperty(conv, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)
        self.converter = conv
    }

    deinit {
        if let converter {
            AudioConverterDispose(converter)
        }
    }

    func encodeFrames(_ pcm: Data) throws -> Data {
        guard let converter else { return Data() }
        var out = Data()
        if isFirstChunk {
            // 16-byte TROpusTool header: "#!OPUS_RAW_V1" + [0x02 (16kHz), 0x01 (mono), 0x00]
            out.append(contentsOf: "#!OPUS_RAW_V1".utf8)
            out.append(contentsOf: [0x02, 0x01, 0x00])
            isFirstChunk = false
        }
        let frameBytes = 640 // 320 samples (20 ms @ 16 kHz)
        var offset = pcm.startIndex
        var packetBuf = [UInt8](repeating: 0, count: 1500)

        while offset < pcm.endIndex {
            let end = min(offset + frameBytes, pcm.endIndex)
            var frame = Data(pcm[offset..<end])
            if frame.count < frameBytes {
                frame.append(Data(count: frameBytes - frame.count))
            }
            offset = end

            self.currentInputData = frame
            self.currentInputConsumed = false

            var ioOutputDataPackets: UInt32 = 1
            var pktDesc = AudioStreamPacketDescription()
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()

            let st = packetBuf.withUnsafeMutableBytes { outRaw -> OSStatus in
                var abl = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 1,
                        mDataByteSize: 1500,
                        mData: outRaw.baseAddress
                    )
                )
                return AudioConverterFillComplexBuffer(
                    converter,
                    { _, ioNumberDataPackets, ioData, _, inUserData -> OSStatus in
                        let enc = Unmanaged<WeTypeOpusEncoder>.fromOpaque(inUserData!).takeUnretainedValue()
                        if enc.currentInputConsumed {
                            ioNumberDataPackets.pointee = 0
                            return 100
                        }
                        enc.currentInputConsumed = true
                        let count = enc.currentInputData.count
                        enc.currentInputData.withUnsafeBytes { rawPtr in
                            ioData.pointee.mNumberBuffers = 1
                            ioData.pointee.mBuffers.mNumberChannels = 1
                            ioData.pointee.mBuffers.mDataByteSize = UInt32(count)
                            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(mutating: rawPtr.baseAddress)
                        }
                        ioNumberDataPackets.pointee = UInt32(count / 2)
                        return noErr
                    },
                    selfPtr,
                    &ioOutputDataPackets,
                    &abl,
                    &pktDesc
                )
            }
            guard st == noErr, ioOutputDataPackets == 1 else {
                throw WeTypeASRError.opusSetupFailed(st)
            }
            let n = Int(pktDesc.mDataByteSize)
            out.append(UInt8(n & 0xFF))
            out.append(UInt8((n >> 8) & 0xFF))
            out.append(contentsOf: packetBuf[0..<n])
        }
        return out
    }
}

// MARK: - Streaming Session Client

public final class WeTypeASRSession: @unchecked Sendable {
    public static let chunkBytes = 3200 // 100 ms of 16 kHz 16-bit mono PCM (5 x 20ms Opus frames)

    public let config: WeTypeASRConfig
    public let voiceId: String

    private var urlSession: URLSession?
    private var wsTask: URLSessionWebSocketTask?
    private var opusEncoder: WeTypeOpusEncoder?
    private let lock = NSLock()
    private var pcmCarry = Data()
    private var seqId: UInt32 = 0
    private var totalAudioOffset: UInt32 = 0
    private var uin: String = ""
    private var aesKey: String = ""
    private var continuation: AsyncThrowingStream<WeTypeASREvent, Error>.Continuation?
    private var responseWaiters: [UInt32: CheckedContinuation<(status: Int32, headers: [String: String], body: Data), Error>] = [:]
    private var lastPartialText: String = ""
    private var endFlagReceived: Bool = false

    public init(config: WeTypeASRConfig = WeTypeASRConfig()) {
        self.config = config
        self.voiceId = WeTypeCrypto.randomDigits(25)
    }

    public func start() throws -> AsyncThrowingStream<WeTypeASREvent, Error> {
        self.opusEncoder = try WeTypeOpusEncoder()

        var req = URLRequest(url: URL(string: "wss://\(config.host)/")!)
        req.setValue("wxws_pb", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let session = URLSession(configuration: .default)
        let ws = session.webSocketTask(with: req)
        self.urlSession = session
        self.wsTask = ws

        let stream = AsyncThrowingStream<WeTypeASREvent, Error> { cont in
            self.continuation = cont
        }

        ws.resume()
        receiveNext()

        return stream
    }

    public func bootstrapIfNeeded() async throws {
        if let cachedUin = UserDefaults.standard.string(forKey: "WeTypeASR.uin"),
           let cachedKey = UserDefaults.standard.string(forKey: "WeTypeASR.aesKey"),
           !cachedUin.isEmpty, cachedKey.count == 32 {
            self.uin = cachedUin
            self.aesKey = cachedKey
            continuation?.yield(.sessionStarted(uin: cachedUin, voiceId: voiceId))
            return
        }
        try await performHandshake()
        continuation?.yield(.sessionStarted(uin: uin, voiceId: voiceId))
    }

    public func sendPCM(_ data: Data) async throws {
        let pcmChunks: [Data] = lock.withLock {
            pcmCarry.append(data)
            var out = [Data]()
            while pcmCarry.count >= Self.chunkBytes {
                out.append(Data(pcmCarry.prefix(Self.chunkBytes)))
                pcmCarry.removeFirst(Self.chunkBytes)
            }
            return out
        }

        for chunk in pcmChunks {
            try await sendAudioChunk(chunk, isEnd: false)
        }
    }

    public func finishAudio() async throws {
        let remaining: Data = lock.withLock {
            let rem = pcmCarry
            pcmCarry.removeAll()
            return rem
        }

        try await sendAudioChunk(remaining, isEnd: true)

        // Phase-B polling (seq=0, is_end=1, empty audio) until end_flag == 1
        var pollIndex: UInt32 = 1
        while !endFlagReceived && pollIndex <= 25 {
            try await Task.sleep(nanoseconds: 100_000_000)
            try await sendPollingRequest(pollIndex: pollIndex)
            pollIndex += 1
        }
        close()
    }

    public func close() {
        wsTask?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
        continuation?.finish()
    }

    // MARK: - Internal Handshake & Voice Packet Logic

    private func performHandshake() async throws {
        let (priv, clientPubHex) = Secp128r1.generateKeyPair()
        let devCode = WeTypeCrypto.generateDeviceCode(deviceName: config.deviceName)

        var ecdhReq = Data()
        ecdhReq.append(WeTypeProtobuf.encodeString(1, clientPubHex))
        ecdhReq.append(WeTypeProtobuf.encodeString(2, ""))
        ecdhReq.append(WeTypeProtobuf.encodeUInt(3, 1))
        ecdhReq.append(WeTypeProtobuf.encodeString(4, devCode))
        ecdhReq.append(WeTypeProtobuf.encodeString(7, ""))
        ecdhReq.append(WeTypeProtobuf.encodeString(8, config.deviceName))
        ecdhReq.append(WeTypeProtobuf.encodeString(9, ""))

        let encBody = try WeTypeCrypto.aes256ECB(operation: CCOperation(kCCEncrypt), keyASCII: WeTypeCrypto.handshakeAESKey, data: ecdhReq)
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        let traceId = WeTypeCrypto.randomLowercase(16)
        let bodyMd5 = WeTypeCrypto.md5Upper(encBody)
        let taskIdDH: UInt32 = 2147483646
        let signDH = WeTypeCrypto.sha256Upper("5" + config.clientVersion + "2" + ts + bodyMd5 + traceId + String(taskIdDH) + WeTypeCrypto.signKey)

        let dhResp = try await sendTunnelRequest(
            taskId: taskIdDH,
            path: "/oauth_pubkey_v2",
            headers: [
                ("Kb-Uin", "0"),
                ("Kb-DeviceCodeRestrictionV2", "1"),
                ("Kb-OsType", "5"),
                ("Kb-Version", config.clientVersion),
                ("Kb-SystemVersion", config.systemVersion),
                ("Kb-PackageType", "3"),
                ("Use_DebugNet", "0"),
                ("Kb-TimeStamp", ts),
                ("Kb-BodyMd5", bodyMd5),
                ("Kb-TraceId", traceId),
                ("Kb-TaskId", String(taskIdDH)),
                ("Kb-Scene", "2"),
                ("Kb-Sign", signDH),
                ("Content-Length", String(encBody.count)),
                ("Kb-CompressionType", "1"),
                ("Content-Type", "application/octet-stream"),
                ("HOST", config.host),
            ],
            body: encBody
        )
        let decDH = try WeTypeCrypto.aes256ECB(operation: CCOperation(kCCDecrypt), keyASCII: WeTypeCrypto.handshakeAESKey, data: dhResp.body)
        var svrPubHex = ""
        var genUinToken = ""
        for (f, val) in WeTypeProtobuf.parse(decDH) {
            if f == 2, case .bytes(let b) = val { svrPubHex = String(data: b, encoding: .utf8) ?? "" }
            if f == 4, case .bytes(let b) = val { genUinToken = String(data: b, encoding: .utf8) ?? "" }
        }
        guard let derivedKey = Secp128r1.deriveAESKey(privateKey: priv, serverPublicKeyHex: svrPubHex) else {
            throw WeTypeASRError.handshakeFailed("Could not derive secp128r1 shared secret")
        }

        var uinReq = Data()
        uinReq.append(WeTypeProtobuf.encodeString(1, devCode))
        uinReq.append(WeTypeProtobuf.encodeString(2, svrPubHex))
        uinReq.append(WeTypeProtobuf.encodeString(4, UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()))
        uinReq.append(WeTypeProtobuf.encodeString(5, ""))

        let encBody2 = try WeTypeCrypto.aes256ECB(operation: CCOperation(kCCEncrypt), keyASCII: derivedKey, data: uinReq)
        let ts2 = String(Int64(Date().timeIntervalSince1970 * 1000))
        let traceId2 = WeTypeCrypto.randomLowercase(16)
        let bodyMd5_2 = WeTypeCrypto.md5Upper(encBody2)
        let taskIdUin: UInt32 = 2147483645
        let signUin = WeTypeCrypto.sha256Upper("5" + config.clientVersion + "2" + ts2 + bodyMd5_2 + genUinToken + traceId2 + String(taskIdUin) + WeTypeCrypto.signKey)

        let uinResp = try await sendTunnelRequest(
            taskId: taskIdUin,
            path: "/gen_uin_v2",
            headers: [
                ("Kb-GenUinToken", genUinToken),
                ("Kb-DeviceCodeRestrictionV2", "1"),
                ("Kb-OsType", "5"),
                ("Kb-Version", config.clientVersion),
                ("Kb-SystemVersion", config.systemVersion),
                ("Kb-PackageType", "3"),
                ("Use_DebugNet", "0"),
                ("Kb-TimeStamp", ts2),
                ("Kb-BodyMd5", bodyMd5_2),
                ("Kb-TraceId", traceId2),
                ("Kb-TaskId", String(taskIdUin)),
                ("Kb-Scene", "2"),
                ("Kb-Sign", signUin),
                ("Content-Length", String(encBody2.count)),
                ("Kb-CompressionType", "1"),
                ("Content-Type", "application/octet-stream"),
                ("HOST", config.host),
            ],
            body: encBody2
        )
        let decUin = try WeTypeCrypto.aes256ECB(operation: CCOperation(kCCDecrypt), keyASCII: derivedKey, data: uinResp.body)
        var newUin: UInt64 = 0
        for (f, val) in WeTypeProtobuf.parse(decUin) {
            if f == 2, case .varint(let v) = val { newUin = v }
        }
        guard newUin != 0 else {
            throw WeTypeASRError.handshakeFailed("GenUin_V2 returned uin=0")
        }

        self.uin = String(newUin)
        self.aesKey = derivedKey
        UserDefaults.standard.set(self.uin, forKey: "WeTypeASR.uin")
        UserDefaults.standard.set(self.aesKey, forKey: "WeTypeASR.aesKey")
    }

    private func sendAudioChunk(_ pcm: Data, isEnd: Bool) async throws {
        let opusData = pcm.isEmpty ? Data() : (try opusEncoder?.encodeFrames(pcm) ?? Data())
        seqId += 1
        totalAudioOffset += UInt32(opusData.count)
        let currentSeq = seqId

        var inner = Data()
        inner.append(WeTypeProtobuf.encodeString(2, voiceId))
        if !opusData.isEmpty {
            inner.append(WeTypeProtobuf.encodeBytes(4, opusData))
        }
        inner.append(WeTypeProtobuf.encodeUInt(5, 5))
        if isEnd {
            inner.append(WeTypeProtobuf.encodeUInt(6, 1))
        }
        inner.append(WeTypeProtobuf.encodeUInt(7, UInt64(currentSeq)))
        inner.append(WeTypeProtobuf.encodeUInt(11, UInt64(totalAudioOffset)))
        inner.append(WeTypeProtobuf.encodeUInt(24, 1))

        try await sendVoiceInner(taskId: currentSeq, inner: inner, seq: currentSeq)
    }

    private func sendPollingRequest(pollIndex: UInt32) async throws {
        let tid = seqId + pollIndex
        var inner = Data()
        inner.append(WeTypeProtobuf.encodeString(2, voiceId))
        inner.append(WeTypeProtobuf.encodeUInt(5, 5))
        inner.append(WeTypeProtobuf.encodeUInt(6, 1))
        inner.append(WeTypeProtobuf.encodeUInt(11, UInt64(totalAudioOffset)))
        inner.append(WeTypeProtobuf.encodeUInt(24, 1))

        try await sendVoiceInner(taskId: tid, inner: inner, seq: currentSeqOrZero(tid))
    }

    private func currentSeqOrZero(_ tid: UInt32) -> UInt32 { tid }

    private func sendVoiceInner(taskId: UInt32, inner: Data, seq: UInt32) async throws {
        let payload = WeTypeProtobuf.encodeBytes(1, inner)
        let rawBody: Data
        let compType: String
        if payload.count >= 301 {
            rawBody = WeTypeCrypto.snappyCompress(payload)
            compType = "2"
        } else {
            rawBody = payload
            compType = "1"
        }
        let enc = try WeTypeCrypto.aes256ECB(operation: CCOperation(kCCEncrypt), keyASCII: aesKey, data: rawBody)
        let ts = String(Int64(Date().timeIntervalSince1970 * 1000))
        let traceId = WeTypeCrypto.randomLowercase(16)
        let bodyMd5 = WeTypeCrypto.md5Upper(enc)
        let sign = WeTypeCrypto.sha256Upper("5" + config.clientVersion + "2" + "4548" + "0" + ts + bodyMd5 + uin + traceId + String(taskId) + WeTypeCrypto.signKey)

        let resp = try await sendTunnelRequest(
            taskId: taskId,
            path: "/api_v2",
            headers: [
                ("Kb-Uin", uin),
                ("Kb-SharedKeySuffix", String(aesKey.suffix(4))),
                ("Kb-CmdId", "4548"),
                ("Kb-SubCmdId", "0"),
                ("Kb-OsType", "5"),
                ("Kb-Version", config.clientVersion),
                ("Kb-SystemVersion", config.systemVersion),
                ("Kb-PackageType", "3"),
                ("Use_DebugNet", "0"),
                ("Kb-TimeStamp", ts),
                ("Kb-BodyMd5", bodyMd5),
                ("Kb-TraceId", traceId),
                ("Kb-TaskId", String(taskId)),
                ("Kb-Scene", "2"),
                ("Kb-Sign", sign),
                ("Content-Length", String(enc.count)),
                ("Kb-CompressionType", compType),
                ("Content-Type", "application/octet-stream"),
                ("HOST", config.host),
            ],
            body: enc
        )

        if resp.status == 5004 || resp.status == 5011 {
            try await performHandshake()
            return try await sendVoiceInner(taskId: taskId, inner: inner, seq: seq)
        }
        guard resp.status == 200, !resp.body.isEmpty else { return }

        var dec = try WeTypeCrypto.aes256ECB(operation: CCOperation(kCCDecrypt), keyASCII: aesKey, data: resp.body)
        if resp.headers["kb-compressiontype"] == "2" {
            dec = WeTypeCrypto.snappyDecompress(dec)
        }

        let outer = WeTypeProtobuf.parse(dec)
        guard let first = outer.first, case .bytes(let innerData) = first.value else { return }

        var f4 = ""
        var f14 = ""
        var endFlag: UInt64 = 0
        for (f, val) in WeTypeProtobuf.parse(innerData) {
            switch (f, val) {
            case (4, .bytes(let b)): f4 = String(data: b, encoding: .utf8) ?? ""
            case (5, .varint(let v)): endFlag = v
            case (14, .bytes(let b)): f14 = String(data: b, encoding: .utf8) ?? ""
            default: break
            }
        }
        let text = !f14.isEmpty ? f14 : f4
        if endFlag == 1 {
            endFlagReceived = true
            let finalTxt = !text.isEmpty ? text : lastPartialText
            continuation?.yield(.finalResult(text: finalTxt, seq: seq))
        } else if !text.isEmpty && text != lastPartialText {
            lastPartialText = text
            continuation?.yield(.partialResult(text: text, seq: seq))
        }
    }

    private func sendTunnelRequest(
        taskId: UInt32,
        path: String,
        headers: [(String, String)],
        body: Data
    ) async throws -> (status: Int32, headers: [String: String], body: Data) {
        var httpReq = Data()
        httpReq.append(WeTypeProtobuf.encodeString(1, "POST"))
        httpReq.append(WeTypeProtobuf.encodeString(3, path))
        httpReq.append(WeTypeProtobuf.encodeString(4, ""))
        for (k, v) in headers {
            var item = Data()
            item.append(WeTypeProtobuf.encodeString(1, k))
            item.append(WeTypeProtobuf.encodeString(2, v))
            httpReq.append(WeTypeProtobuf.encodeBytes(5, item))
        }
        httpReq.append(WeTypeProtobuf.encodeBytes(6, body))

        var env = Data()
        env.append(WeTypeProtobuf.encodeUInt(1, 0))
        env.append(WeTypeProtobuf.encodeUInt(2, 0))
        env.append(WeTypeProtobuf.encodeUInt(3, UInt64(taskId)))
        env.append(WeTypeProtobuf.encodeBytes(5, httpReq))

        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            responseWaiters[taskId] = cont
            let ws = self.wsTask
            lock.unlock()
            ws?.send(.data(env)) { err in
                if let err {
                    self.lock.lock()
                    let w = self.responseWaiters.removeValue(forKey: taskId)
                    self.lock.unlock()
                    w?.resume(throwing: err)
                }
            }
        }
    }

    private func receiveNext() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                if case .data(let d) = msg {
                    self.handleWsFrame(d)
                }
                self.receiveNext()
            case .failure(let err):
                self.lock.lock()
                let waiters = self.responseWaiters
                self.responseWaiters.removeAll()
                self.lock.unlock()
                for (_, w) in waiters {
                    w.resume(throwing: err)
                }
            }
        }
    }

    private func handleWsFrame(_ data: Data) {
        var seq: UInt32 = 0
        var httpRspData = Data()
        for (f, val) in WeTypeProtobuf.parse(data) {
            if f == 2, case .varint(let v) = val { seq = UInt32(truncatingIfNeeded: v) }
            if f == 4, case .bytes(let b) = val { httpRspData = b }
        }
        guard seq != 0 else { return }

        var status: Int32 = 0
        var hdrs: [String: String] = [:]
        var body = Data()
        for (rf, rval) in WeTypeProtobuf.parse(httpRspData) {
            switch (rf, rval) {
            case (2, .varint(let v)):
                status = Int32(truncatingIfNeeded: v)
            case (4, .bytes(let b)):
                var k = ""
                var v = ""
                for (hf, hval) in WeTypeProtobuf.parse(b) {
                    if hf == 1, case .bytes(let kb) = hval { k = (String(data: kb, encoding: .utf8) ?? "").lowercased() }
                    if hf == 2, case .bytes(let vb) = hval { v = String(data: vb, encoding: .utf8) ?? "" }
                }
                if !k.isEmpty { hdrs[k] = v }
            case (5, .bytes(let b)):
                body = b
            default:
                break
            }
        }

        lock.lock()
        let waiter = responseWaiters.removeValue(forKey: seq)
        lock.unlock()
        waiter?.resume(returning: (status, hdrs, body))
    }
}

// MARK: - Live Microphone Recorder -> 16 kHz Mono Int16 PCM

public final class WeTypeMicrophoneStreamer {
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
            throw WeTypeASRError.audioSetupFailed("No valid microphone input format")
        }
        guard let conv = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw WeTypeASRError.audioSetupFailed("Could not create AVAudioConverter to 16kHz Int16 mono")
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
