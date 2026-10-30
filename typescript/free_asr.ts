#!/usr/bin/env node
/**
 * Zero-dependency TypeScript SDK & CLI for Free ASR (Doubao IME & WeChat WeType IME).
 *
 * Runs directly on Node.js 22.6+ / 24+ (`node typescript/free_asr.ts`), Bun, or `tsx`.
 * Uses only built-in `node:tls`, `node:crypto`, `node:fs`, `node:child_process` (zero npm packages).
 */
import * as tls from "node:tls";
import * as crypto from "node:crypto";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { execFileSync } from "node:child_process";

export type ASRProvider = "wetype" | "doubao";

// ============================================================================
// 1. Minimal Protobuf Wire Codec
// ============================================================================

export function pbVarint(n: bigint | number): Buffer {
  let v = BigInt(n);
  const bytes: number[] = [];
  while (v >= 0x80n) {
    bytes.push(Number((v & 0x7fn) | 0x80n));
    v >>= 7n;
  }
  bytes.push(Number(v));
  return Buffer.from(bytes);
}

export function pbUInt(field: number, val: bigint | number): Buffer {
  const v = BigInt(val);
  if (v === 0n) return Buffer.alloc(0);
  return Buffer.concat([pbVarint((field << 3) | 0), pbVarint(v)]);
}

export function pbUIntAlways(field: number, val: bigint | number): Buffer {
  return Buffer.concat([pbVarint((field << 3) | 0), pbVarint(BigInt(val))]);
}

export function pbBytes(field: number, data: Buffer): Buffer {
  return Buffer.concat([pbVarint((field << 3) | 2), pbVarint(data.length), data]);
}

export function pbStr(field: number, str: string): Buffer {
  return pbBytes(field, Buffer.from(str, "utf8"));
}

export interface PbField {
  field: number;
  wire: number;
  uintVal?: bigint;
  bytesVal?: Buffer;
}

export function pbParse(buf: Buffer): PbField[] {
  let i = 0;
  const out: PbField[] = [];
  const readVarint = (): bigint => {
    let r = 0n;
    let s = 0n;
    while (i < buf.length) {
      const b = BigInt(buf[i++]);
      r |= (b & 0x7fn) << s;
      if ((b & 0x80n) === 0n) break;
      s += 7n;
    }
    return r;
  };
  while (i < buf.length) {
    const tag = readVarint();
    const field = Number(tag >> 3n);
    const wire = Number(tag & 7n);
    if (wire === 0) {
      out.push({ field, wire, uintVal: readVarint() });
    } else if (wire === 2) {
      const len = Number(readVarint());
      if (i + len > buf.length) break;
      out.push({ field, wire, bytesVal: buf.subarray(i, i + len) });
      i += len;
    } else {
      break;
    }
  }
  return out;
}

// ============================================================================
// 2. Minimal RFC 6455 TLS WebSocket Client
// ============================================================================

class TlsWebSocket {
  private sock!: tls.TLSSocket;
  private buf: Buffer = Buffer.alloc(0);
  private waiters: Array<() => void> = [];
  private closed = false;

  static async connect(host: string, pathAndQuery: string, headers: Record<string, string> = {}): Promise<TlsWebSocket> {
    const ws = new TlsWebSocket();
    await new Promise<void>((resolve, reject) => {
      const sock = tls.connect({ host, port: 443, servername: host }, () => {
        const key = crypto.randomBytes(16).toString("base64");
        const lines = [
          `GET ${pathAndQuery} HTTP/1.1`,
          `Host: ${host}`,
          "Upgrade: websocket",
          "Connection: Upgrade",
          `Sec-WebSocket-Key: ${key}`,
          "Sec-WebSocket-Version: 13",
        ];
        for (const [k, v] of Object.entries(headers)) {
          lines.push(`${k}: ${v}`);
        }
        sock.write(lines.join("\r\n") + "\r\n\r\n");
      });
      ws.sock = sock;
      let handshakeDone = false;
      sock.on("data", (chunk: Buffer) => {
        ws.buf = Buffer.concat([ws.buf, chunk]);
        if (!handshakeDone) {
          const idx = ws.buf.indexOf("\r\n\r\n");
          if (idx !== -1) {
            const hdr = ws.buf.subarray(0, idx).toString("latin1");
            ws.buf = ws.buf.subarray(idx + 4);
            if (!hdr.split("\r\n")[0].includes(" 101 ")) {
              reject(new Error(`WebSocket handshake failed: ${hdr.split("\r\n")[0]}`));
              return;
            }
            handshakeDone = true;
            resolve();
          }
        }
        while (ws.waiters.length > 0) {
          ws.waiters.shift()!();
        }
      });
      sock.on("error", reject);
      sock.on("close", () => {
        ws.closed = true;
        while (ws.waiters.length > 0) {
          ws.waiters.shift()!();
        }
      });
    });
    return ws;
  }

  private async ensureBytes(n: number): Promise<void> {
    while (this.buf.length < n) {
      if (this.closed) throw new Error("WebSocket closed");
      await new Promise<void>((r) => this.waiters.push(r));
    }
  }

  sendBinary(payload: Buffer): void {
    this.sendFrame(0x2, payload);
  }

  private sendFrame(opcode: number, payload: Buffer): void {
    const mask = crypto.randomBytes(4);
    const n = payload.length;
    let hdr: Buffer;
    if (n < 126) {
      hdr = Buffer.from([0x80 | opcode, 0x80 | n]);
    } else if (n < 65536) {
      hdr = Buffer.alloc(4);
      hdr[0] = 0x80 | opcode;
      hdr[1] = 0x80 | 126;
      hdr.writeUInt16BE(n, 2);
    } else {
      hdr = Buffer.alloc(10);
      hdr[0] = 0x80 | opcode;
      hdr[1] = 0x80 | 127;
      hdr.writeBigUInt64BE(BigInt(n), 2);
    }
    const masked = Buffer.alloc(n);
    for (let i = 0; i < n; i++) {
      masked[i] = payload[i] ^ mask[i & 3];
    }
    this.sock.write(Buffer.concat([hdr, mask, masked]));
  }

  async recvFrame(): Promise<{ opcode: number; payload: Buffer }> {
    while (true) {
      await this.ensureBytes(2);
      const b0 = this.buf[0];
      const b1 = this.buf[1];
      const opcode = b0 & 0x0f;
      const masked = (b1 & 0x80) !== 0;
      let len = b1 & 0x7f;
      let idx = 2;
      if (len === 126) {
        await this.ensureBytes(idx + 2);
        len = this.buf.readUInt16BE(idx);
        idx += 2;
      } else if (len === 127) {
        await this.ensureBytes(idx + 8);
        len = Number(this.buf.readBigUInt64BE(idx));
        idx += 8;
      }
      let mask: Buffer | null = null;
      if (masked) {
        await this.ensureBytes(idx + 4);
        mask = this.buf.subarray(idx, idx + 4);
        idx += 4;
      }
      await this.ensureBytes(idx + len);
      const payload = Buffer.from(this.buf.subarray(idx, idx + len));
      this.buf = this.buf.subarray(idx + len);
      if (mask) {
        for (let i = 0; i < len; i++) payload[i] ^= mask[i & 3];
      }
      if (opcode === 9) {
        this.sendFrame(0xa, payload);
        continue;
      }
      return { opcode, payload };
    }
  }

  close(): void {
    try {
      this.sock.destroy();
    } catch {}
  }
}

// ============================================================================
// 3. Provider 1: Doubao Input Method Streaming ASR
// ============================================================================

function buildDoubaoReq(event: string, taskId: string, payload = "", data?: Buffer, seqId = 0): Buffer {
  const parts: Buffer[] = [
    pbStr(2, "OrnqKvSSrs"),
    pbStr(3, "ASR"),
    pbStr(5, event),
  ];
  if (payload) parts.push(pbStr(6, payload));
  if (data && data.length > 0) parts.push(pbBytes(7, data));
  parts.push(pbStr(8, taskId));
  if (seqId > 0) parts.push(pbUInt(9, seqId));
  return Buffer.concat(parts);
}

export async function transcribeDoubao(pcm: Buffer, onPartial?: (text: string) => void): Promise<string> {
  let deviceId = "7";
  for (let i = 0; i < 15; i++) deviceId += Math.floor(Math.random() * 10).toString();
  const taskId = crypto.randomUUID().replace(/-/g, "");
  const query = new URLSearchParams({
    aid: "685343",
    device_id: deviceId,
    app_name: "oime_macos",
    channel: "release",
    device_platform: "mac",
    device_type: "mac",
    device_brand: "Apple",
    os: "macOS",
    os_version: "15.6.0",
    version_code: "1.0.2",
    version_name: "1.0.2",
    update_version_code: "1",
    build_number: "1.0.2",
    app_version: "1.0.2",
  }).toString();

  const ws = await TlsWebSocket.connect("frontier-audio-ime-ws.doubao.com", `/ocean/api/v1/ws?${query}`, {
    "proto-version": "v2",
    "sdk-version": "2",
    "x-tt-token": "",
    "x-tt-e-k": `${deviceId}+W`,
    "x-custom-keepalive": "true",
  });

  try {
    ws.sendBinary(buildDoubaoReq("StartTask", taskId));
    const startPayload = JSON.stringify({
      audio_info: { channel: 1, format: "pcm", sample_rate: 16000 },
      enable_punctuation: true,
      enable_speech_rejection: false,
      extra: {
        app_name: "oime_macos",
        app_version: "1.0.2",
        cell_compress_rate: 8,
        device_brand: "Apple",
        device_id: deviceId,
        device_model: "Mac",
        disable_user_words: false,
        enable_asr_format: true,
        enable_asr_threepass: true,
        enable_asr_twopass: true,
        enable_print_chinese: true,
        enable_text_filter: true,
        finish_wait_offline_time: 1000,
        format_space_at_newline: false,
        input_mode: "wave",
        join_user_experience_improve_program: false,
        max_wait_switch_offline_time: 4000,
        offline_wait_online_interval_time: 200,
        offline_wait_online_time: 1000,
        os: "macOS",
        os_version: "15.6.0",
        remove_space_between_han_eng: false,
        remove_space_between_han_num: true,
        retry_server_code: [],
        strong_ddc: true,
        use_twopass_retry: true,
      },
    });
    ws.sendBinary(buildDoubaoReq("StartSession", taskId, startPayload));

    const chunkBytes = 3200;
    let seq = 0;
    for (let off = 0; off < pcm.length; off += chunkBytes) {
      seq++;
      const chunk = pcm.subarray(off, Math.min(off + chunkBytes, pcm.length));
      ws.sendBinary(buildDoubaoReq("TaskRequest", taskId, `{"timestamp_ms":${Date.now()}}`, chunk, seq));
    }
    ws.sendBinary(buildDoubaoReq("FinishSession", taskId));

    let finalText = "";
    let lastPartial = "";
    while (true) {
      const { opcode, payload } = await ws.recvFrame();
      if (opcode !== 2) continue;
      let event = "";
      let jsonStr = "";
      for (const f of pbParse(payload)) {
        if (f.field === 4 && f.bytesVal) event = f.bytesVal.toString("utf8");
        if (f.field === 7 && f.bytesVal) jsonStr = f.bytesVal.toString("utf8");
      }
      if (event === "SessionFinished" || event === "TaskFinished") break;
      if (event === "SessionFailed" || event === "TaskFailed") {
        throw new Error(`Doubao ASR failed: ${event}`);
      }
      if (jsonStr) {
        const obj = JSON.parse(jsonStr);
        const first = obj?.results?.[0];
        if (first) {
          const txt: string = first.text || "";
          if (!first.is_interim || first.is_vad_finished) {
            finalText = txt;
          } else if (txt && txt !== lastPartial) {
            lastPartial = txt;
            onPartial?.(txt);
          }
        }
      }
    }
    ws.sendBinary(buildDoubaoReq("FinishTask", taskId));
    return finalText || lastPartial;
  } finally {
    ws.close();
  }
}

// ============================================================================
// 4. Provider 2: WeChat Input Method / WeType Streaming ASR
// ============================================================================

const WETYPE_HOST = "wetype.weixin.qq.com";
const WETYPE_SIGN_KEY = "zN7rB3bL4pO8jW1o";
const WETYPE_HS_KEY = "D4Y5U3Y2M0C0T7N4P1P7O2N6E1I2Y1U6";
const WETYPE_VERSION = "3.0.0(670)";

const SECP128R1_P = 0xfffffffdffffffffffffffffffffffffn;
const SECP128R1_A = 0xfffffffdfffffffffffffffffffffffcn;
const SECP128R1_GX = 0x161ff7528b899b2d0c28607ca52c5b86n;
const SECP128R1_GY = 0xcf5ac8395bafeb13c02da292dded7a83n;

function mod(a: bigint, m = SECP128R1_P): bigint {
  const r = a % m;
  return r >= 0n ? r : r + m;
}

function modPow(base: bigint, exp: bigint, m = SECP128R1_P): bigint {
  let res = 1n;
  let b = mod(base, m);
  let e = exp;
  while (e > 0n) {
    if (e & 1n) res = mod(res * b, m);
    b = mod(b * b, m);
    e >>= 1n;
  }
  return res;
}

function ecAdd(p1: [bigint, bigint] | null, p2: [bigint, bigint] | null): [bigint, bigint] | null {
  if (!p1) return p2;
  if (!p2) return p1;
  const [x1, y1] = p1;
  const [x2, y2] = p2;
  if (x1 === x2 && mod(y1 + y2) === 0n) return null;
  const lam =
    x1 === x2 && y1 === y2
      ? mod((3n * x1 * x1 + SECP128R1_A) * modPow(2n * y1, SECP128R1_P - 2n))
      : mod((y2 - y1) * modPow(x2 - x1, SECP128R1_P - 2n));
  const x3 = mod(lam * lam - x1 - x2);
  const y3 = mod(lam * (x1 - x3) - y1);
  return [x3, y3];
}

function ecMul(k: bigint, pt: [bigint, bigint] = [SECP128R1_GX, SECP128R1_GY]): [bigint, bigint] {
  let res: [bigint, bigint] | null = null;
  let cur: [bigint, bigint] | null = pt;
  let n = k;
  while (n > 0n) {
    if (n & 1n) res = ecAdd(res, cur);
    cur = ecAdd(cur, cur);
    n >>= 1n;
  }
  return res!;
}

function aes256EcbEncrypt(keyAscii: string, data: Buffer): Buffer {
  const cipher = crypto.createCipheriv("aes-256-ecb", Buffer.from(keyAscii, "ascii"), null);
  return Buffer.concat([cipher.update(data), cipher.final()]);
}

function aes256EcbDecrypt(keyAscii: string, data: Buffer): Buffer {
  if (data.length === 0) return Buffer.alloc(0);
  const decipher = crypto.createDecipheriv("aes-256-ecb", Buffer.from(keyAscii, "ascii"), null);
  return Buffer.concat([decipher.update(data), decipher.final()]);
}

function md5Upper(data: Buffer | string): string {
  return crypto.createHash("md5").update(data).digest("hex").toUpperCase();
}

function sha256Upper(str: string): string {
  return crypto.createHash("sha256").update(str, "utf8").digest("hex").toUpperCase();
}

function randLower(len: number): string {
  const chars = "abcdefghijklmnopqrstuvwxyz";
  let out = "";
  for (let i = 0; i < len; i++) out += chars[Math.floor(Math.random() * chars.length)];
  return out;
}

function randDigits(len: number): string {
  let out = "";
  for (let i = 0; i < len; i++) out += Math.floor(Math.random() * 10).toString();
  return out;
}

function snappyCompress(data: Buffer): Buffer {
  const parts: Buffer[] = [pbVarint(data.length)];
  for (let i = 0; i < data.length; i += 65536) {
    const chunk = data.subarray(i, Math.min(i + 65536, data.length));
    const ln = chunk.length - 1;
    if (ln < 60) {
      parts.push(Buffer.from([ln << 2]));
    } else if (ln < 256) {
      parts.push(Buffer.from([60 << 2, ln]));
    } else {
      parts.push(Buffer.from([61 << 2, ln & 0xff, (ln >> 8) & 0xff]));
    }
    parts.push(chunk);
  }
  return Buffer.concat(parts);
}

function snappyDecompress(data: Buffer): Buffer {
  let i = 0;
  let shift = 0;
  while (i < data.length) {
    const b = data[i++];
    if ((b & 0x80) === 0) break;
    shift += 7;
  }
  const out: number[] = [];
  while (i < data.length) {
    const tag = data[i++];
    const type = tag & 3;
    if (type === 0) {
      let len = tag >> 2;
      if (len >= 60) {
        const nb = len - 59;
        len = 0;
        for (let k = 0; k < nb; k++) len |= data[i++] << (8 * k);
      }
      len += 1;
      for (let k = 0; k < len; k++) out.push(data[i++]);
    } else {
      let len = 0;
      let offset = 0;
      if (type === 1) {
        len = ((tag >> 2) & 7) + 4;
        offset = ((tag >> 5) << 8) | data[i++];
      } else if (type === 2) {
        len = (tag >> 2) + 1;
        offset = data[i] | (data[i + 1] << 8);
        i += 2;
      } else {
        len = (tag >> 2) + 1;
        offset = (data[i] | (data[i + 1] << 8) | (data[i + 2] << 16) | (data[i + 3] << 24)) >>> 0;
        i += 4;
      }
      for (let k = 0; k < len; k++) out.push(out[out.length - offset]);
    }
  }
  return Buffer.from(out);
}

export function encodeWeTypeOpusChunks(pcm: Buffer, framesPerChunk = 5): Buffer[] {
  if (!Number.isInteger(framesPerChunk) || framesPerChunk < 1) throw new Error("framesPerChunk must be positive");
  if (!pcm.length) return [];
  if (process.platform !== "darwin") {
    const ogg = execFileSync("ffmpeg", ["-hide_banner", "-loglevel", "error", "-f", "s16le", "-ar", "16000", "-ac", "1", "-i", "pipe:0",
      "-c:a", "libopus", "-b:a", "64k", "-vbr", "off", "-application", "voip", "-frame_duration", "20", "-f", "opus", "pipe:1"],
      { input: pcm, maxBuffer: Math.max(1024 * 1024, pcm.length), timeout: 60000 });
    const packets: Buffer[] = [];
    let at = 0, pieces: Buffer[] = [];
    while (at < ogg.length) {
      if (at + 27 > ogg.length || ogg.toString("ascii", at, at + 4) !== "OggS") throw new Error("Invalid Ogg page");
      const count = ogg[at + 26], table = at + 27;
      let offset = table + count;
      if (offset > ogg.length) throw new Error("Truncated Ogg page");
      for (let i = 0; i < count; i++) {
        const n = ogg[table + i];
        if (offset + n > ogg.length) throw new Error("Truncated Opus packet");
        pieces.push(ogg.subarray(offset, offset + n)); offset += n;
        if (n < 255) {
          const packet = Buffer.concat(pieces); pieces = [];
          if (!["OpusHead", "OpusTags"].includes(packet.toString("ascii", 0, 8))) packets.push(packet);
        }
      }
      at = offset;
    }
    if (pieces.length) throw new Error("Truncated Opus packet");
    const chunks: Buffer[] = [];
    for (let i = 0; i < packets.length; i += framesPerChunk) {
      const parts = i ? [] : [Buffer.from("#!OPUS_RAW_V1\x02\x01\x00", "binary")];
      for (const packet of packets.slice(i, i + framesPerChunk)) {
        const length = Buffer.alloc(2); length.writeUInt16LE(packet.length); parts.push(length, packet);
      }
      chunks.push(Buffer.concat(parts));
    }
    return chunks;
  }
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "wetype-ts-opus-"));
  try {
    const inWav = path.join(tmpDir, "in.wav");
    const outCaf = path.join(tmpDir, "out.caf");
    const wavHdr = Buffer.alloc(44);
    wavHdr.write("RIFF", 0);
    wavHdr.writeUInt32LE(36 + pcm.length, 4);
    wavHdr.write("WAVEfmt ", 8);
    wavHdr.writeUInt32LE(16, 16);
    wavHdr.writeUInt16LE(1, 20);
    wavHdr.writeUInt16LE(1, 22);
    wavHdr.writeUInt32LE(16000, 24);
    wavHdr.writeUInt32LE(32000, 28);
    wavHdr.writeUInt16LE(2, 32);
    wavHdr.writeUInt16LE(16, 34);
    wavHdr.write("data", 36);
    wavHdr.writeUInt32LE(pcm.length, 40);
    fs.writeFileSync(inWav, Buffer.concat([wavHdr, pcm]));
    execFileSync("/usr/bin/afconvert", ["-f", "caff", "-d", "opus@16000", "-b", "64000", inWav, outCaf]);
    const caf = fs.readFileSync(outCaf);
    let pos = 8;
    let pakt = Buffer.alloc(0);
    let dataChunk = Buffer.alloc(0);
    while (pos + 12 <= caf.length) {
      const ctype = caf.subarray(pos, pos + 4).toString("ascii");
      const clen = Number(caf.readBigInt64BE(pos + 4));
      pos += 12;
      if (ctype === "pakt") pakt = caf.subarray(pos, pos + clen);
      if (ctype === "data") dataChunk = caf.subarray(pos + 4, pos + clen);
      pos += clen;
    }
    const numPkts = Number(pakt.readBigInt64BE(0));
    let idx = 24;
    const pktSizes: number[] = [];
    for (let p = 0; p < numPkts; p++) {
      let v = 0;
      while (true) {
        const b = pakt[idx++];
        v = (v << 7) | (b & 0x7f);
        if ((b & 0x80) === 0) break;
      }
      pktSizes.push(v);
    }
    const chunks: Buffer[] = [];
    let cur: Buffer[] = [Buffer.from("#!OPUS_RAW_V1\x02\x01\x00", "binary")];
    let fCount = 0;
    let doff = 0;
    for (const sz of pktSizes) {
      const pkt = dataChunk.subarray(doff, doff + sz);
      doff += sz;
      const lenBuf = Buffer.alloc(2);
      lenBuf.writeUInt16LE(pkt.length, 0);
      cur.push(lenBuf, pkt);
      fCount++;
      if (fCount === framesPerChunk) {
        chunks.push(Buffer.concat(cur));
        cur = [];
        fCount = 0;
      }
    }
    if (cur.length > 0) chunks.push(Buffer.concat(cur));
    return chunks;
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

function sendWeTypeWsReq(ws: TlsWebSocket, taskId: number, reqPath: string, headers: Array<[string, string]>, body: Buffer): void {
  const parts: Buffer[] = [pbStr(1, "POST"), pbStr(3, reqPath), pbStr(4, "")];
  for (const [k, v] of headers) {
    parts.push(pbBytes(5, Buffer.concat([pbStr(1, k), pbStr(2, v)])));
  }
  parts.push(pbBytes(6, body));
  const env = Buffer.concat([
    pbUIntAlways(1, 0),
    pbUIntAlways(2, 0),
    pbUIntAlways(3, taskId),
    pbBytes(5, Buffer.concat(parts)),
  ]);
  ws.sendBinary(env);
}

async function recvWeTypeWsRsp(ws: TlsWebSocket, expectedTid?: number): Promise<{ seq: number; status: number; headers: Record<string, string>; body: Buffer }> {
  while (true) {
    const { opcode, payload } = await ws.recvFrame();
    if (opcode !== 2) continue;
    let seq = 0;
    let httpRspBuf: Buffer = Buffer.alloc(0);
    for (const f of pbParse(payload)) {
      if (f.field === 2 && f.uintVal !== undefined) seq = Number(f.uintVal);
      if (f.field === 4 && f.bytesVal) httpRspBuf = f.bytesVal;
    }
    if (seq === 0) continue;
    let status = 0;
    const headers: Record<string, string> = {};
    let body: Buffer = Buffer.alloc(0);
    for (const rf of pbParse(httpRspBuf)) {
      if (rf.field === 2 && rf.uintVal !== undefined) status = Number(rf.uintVal);
      if (rf.field === 4 && rf.bytesVal) {
        let k = "";
        let v = "";
        for (const hf of pbParse(rf.bytesVal)) {
          if (hf.field === 1 && hf.bytesVal) k = hf.bytesVal.toString("utf8").toLowerCase();
          if (hf.field === 2 && hf.bytesVal) v = hf.bytesVal.toString("utf8");
        }
        if (k) headers[k] = v;
      }
      if (rf.field === 5 && rf.bytesVal) body = rf.bytesVal;
    }
    if (expectedTid === undefined || seq === expectedTid) {
      return { seq, status, headers, body };
    }
  }
}

export async function transcribeWeType(pcm: Buffer, onPartial?: (text: string) => void): Promise<string> {
  const chunks = encodeWeTypeOpusChunks(pcm);
  if (chunks.length === 0) return "";
  const ws = await TlsWebSocket.connect(WETYPE_HOST, "/", { "Sec-WebSocket-Protocol": "wxws_pb" });

  try {
    // 1. secp128r1 ECDH Handshake (/oauth_pubkey_v2)
    const priv = BigInt("0x" + crypto.randomBytes(15).toString("hex")) + 2n;
    const [pubX, pubY] = ecMul(priv);
    const clientPubHex = "04" + pubX.toString(16).toUpperCase().padStart(32, "0") + pubY.toString(16).toUpperCase().padStart(32, "0");
    const devName = "Mac17,8";
    const prefix32 = "MAC" + devName.padStart(17, "0") + randLower(12);
    const devCode = prefix32 + md5Upper(prefix32 + WETYPE_SIGN_KEY);

    const ecdhReq = Buffer.concat([
      pbStr(1, clientPubHex),
      pbStr(2, ""),
      pbUInt(3, 1),
      pbStr(4, devCode),
      pbStr(7, ""),
      pbStr(8, devName),
      pbStr(9, ""),
    ]);
    const encBody = aes256EcbEncrypt(WETYPE_HS_KEY, ecdhReq);
    const ts1 = Date.now().toString();
    const tr1 = randLower(16);
    const md5_1 = md5Upper(encBody);
    const tid1 = 2147483646;
    const sign1 = sha256Upper("5" + WETYPE_VERSION + "2" + ts1 + md5_1 + tr1 + tid1.toString() + WETYPE_SIGN_KEY);

    sendWeTypeWsReq(ws, tid1, "/oauth_pubkey_v2", [
      ["Kb-Uin", "0"],
      ["Kb-DeviceCodeRestrictionV2", "1"],
      ["Kb-OsType", "5"],
      ["Kb-Version", WETYPE_VERSION],
      ["Kb-SystemVersion", "27.0.0"],
      ["Kb-PackageType", "3"],
      ["Use_DebugNet", "0"],
      ["Kb-TimeStamp", ts1],
      ["Kb-BodyMd5", md5_1],
      ["Kb-TraceId", tr1],
      ["Kb-TaskId", tid1.toString()],
      ["Kb-Scene", "2"],
      ["Kb-Sign", sign1],
      ["Content-Length", encBody.length.toString()],
      ["Kb-CompressionType", "1"],
      ["Content-Type", "application/octet-stream"],
      ["HOST", WETYPE_HOST],
    ], encBody);

    const dhRsp = await recvWeTypeWsRsp(ws, tid1);
    const dhDec = aes256EcbDecrypt(WETYPE_HS_KEY, dhRsp.body);
    let svrPubHex = "";
    let genUinToken = "";
    for (const f of pbParse(dhDec)) {
      if (f.field === 2 && f.bytesVal) svrPubHex = f.bytesVal.toString("ascii");
      if (f.field === 4 && f.bytesVal) genUinToken = f.bytesVal.toString("ascii");
    }
    const svrX = BigInt("0x" + svrPubHex.slice(2, 34));
    const svrY = BigInt("0x" + svrPubHex.slice(34, 66));
    const [sharedX] = ecMul(priv, [svrX, svrY]);
    const aesKey = sharedX.toString(16).toUpperCase().padStart(32, "0");

    // 2. Anonymous UIN Allocation (/gen_uin_v2)
    const uinReq = Buffer.concat([
      pbStr(1, devCode),
      pbStr(2, svrPubHex),
      pbStr(4, crypto.randomUUID().replace(/-/g, "")),
      pbStr(5, ""),
    ]);
    const encBody2 = aes256EcbEncrypt(aesKey, uinReq);
    const ts2 = Date.now().toString();
    const tr2 = randLower(16);
    const md5_2 = md5Upper(encBody2);
    const tid2 = 2147483645;
    const sign2 = sha256Upper("5" + WETYPE_VERSION + "2" + ts2 + md5_2 + genUinToken + tr2 + tid2.toString() + WETYPE_SIGN_KEY);

    sendWeTypeWsReq(ws, tid2, "/gen_uin_v2", [
      ["Kb-GenUinToken", genUinToken],
      ["Kb-DeviceCodeRestrictionV2", "1"],
      ["Kb-OsType", "5"],
      ["Kb-Version", WETYPE_VERSION],
      ["Kb-SystemVersion", "27.0.0"],
      ["Kb-PackageType", "3"],
      ["Use_DebugNet", "0"],
      ["Kb-TimeStamp", ts2],
      ["Kb-BodyMd5", md5_2],
      ["Kb-TraceId", tr2],
      ["Kb-TaskId", tid2.toString()],
      ["Kb-Scene", "2"],
      ["Kb-Sign", sign2],
      ["Content-Length", encBody2.length.toString()],
      ["Kb-CompressionType", "1"],
      ["Content-Type", "application/octet-stream"],
      ["HOST", WETYPE_HOST],
    ], encBody2);

    const uinRsp = await recvWeTypeWsRsp(ws, tid2);
    const uinDec = aes256EcbDecrypt(aesKey, uinRsp.body);
    let uin = "0";
    for (const f of pbParse(uinDec)) {
      if (f.field === 2 && f.uintVal !== undefined) uin = f.uintVal.toString();
    }

    // 3. Stream Voice Packets (/api_v2, Kb-CmdId = 4548)
    const voiceId = randDigits(25);
    let totalOffset = 0;

    const sendVoice = (tid: number, inner: Buffer) => {
      const payload = pbBytes(1, inner);
      const compType = payload.length >= 301 ? "2" : "1";
      const rawBody = compType === "2" ? snappyCompress(payload) : payload;
      const enc = aes256EcbEncrypt(aesKey, rawBody);
      const ts = Date.now().toString();
      const tr = randLower(16);
      const md5 = md5Upper(enc);
      const sign = sha256Upper("5" + WETYPE_VERSION + "2" + "4548" + "0" + ts + md5 + uin + tr + tid.toString() + WETYPE_SIGN_KEY);
      sendWeTypeWsReq(ws, tid, "/api_v2", [
        ["Kb-Uin", uin],
        ["Kb-SharedKeySuffix", aesKey.slice(-4)],
        ["Kb-CmdId", "4548"],
        ["Kb-SubCmdId", "0"],
        ["Kb-OsType", "5"],
        ["Kb-Version", WETYPE_VERSION],
        ["Kb-SystemVersion", "27.0.0"],
        ["Kb-PackageType", "3"],
        ["Use_DebugNet", "0"],
        ["Kb-TimeStamp", ts],
        ["Kb-BodyMd5", md5],
        ["Kb-TraceId", tr],
        ["Kb-TaskId", tid.toString()],
        ["Kb-Scene", "2"],
        ["Kb-Sign", sign],
        ["Content-Length", enc.length.toString()],
        ["Kb-CompressionType", compType],
        ["Content-Type", "application/octet-stream"],
        ["HOST", WETYPE_HOST],
      ], enc);
    };

    for (let i = 0; i < chunks.length; i++) {
      const audio = chunks[i];
      totalOffset += audio.length;
      const seq = i + 1;
      const isEnd = seq === chunks.length;
      const inner = Buffer.concat([
        pbStr(2, voiceId),
        pbBytes(4, audio),
        pbUInt(5, 5),
        isEnd ? pbUInt(6, 1) : Buffer.alloc(0),
        pbUInt(7, seq),
        pbUInt(11, totalOffset),
        pbUInt(24, 1),
      ]);
      sendVoice(seq, inner);
    }

    let lastText = "";
    let endFlag = 0;
    const decodeRsp = (hdrs: Record<string, string>, rbody: Buffer) => {
      if (rbody.length === 0) return;
      let dec = aes256EcbDecrypt(aesKey, rbody);
      if (hdrs["kb-compressiontype"] === "2") dec = snappyDecompress(dec);
      const outer = pbParse(dec);
      if (outer.length === 0 || !outer[0].bytesVal) return;
      let f4 = "";
      let f14 = "";
      for (const f of pbParse(outer[0].bytesVal)) {
        if (f.field === 4 && f.bytesVal) f4 = f.bytesVal.toString("utf8");
        if (f.field === 5 && f.uintVal !== undefined) endFlag = Number(f.uintVal);
        if (f.field === 14 && f.bytesVal) f14 = f.bytesVal.toString("utf8");
      }
      const txt = f14 || f4;
      if (txt && txt !== lastText) {
        lastText = txt;
        onPartial?.(txt);
      }
    };

    for (let i = 0; i < chunks.length; i++) {
      const rsp = await recvWeTypeWsRsp(ws);
      decodeRsp(rsp.headers, rsp.body);
    }

    let pollTid = chunks.length + 1;
    while (endFlag !== 1 && pollTid <= chunks.length + 25) {
      await new Promise((r) => setTimeout(r, 100));
      const pollInner = Buffer.concat([
        pbStr(2, voiceId),
        pbUInt(5, 5),
        pbUInt(6, 1),
        pbUInt(11, totalOffset),
        pbUInt(24, 1),
      ]);
      sendVoice(pollTid, pollInner);
      const rsp = await recvWeTypeWsRsp(ws, pollTid);
      pollTid++;
      decodeRsp(rsp.headers, rsp.body);
    }
    return lastText;
  } finally {
    ws.close();
  }
}

// ============================================================================
// 5. Unified Entrypoint & CLI
// ============================================================================

export async function transcribe(pcm: Buffer, provider: ASRProvider = "wetype", onPartial?: (text: string) => void): Promise<string> {
  return provider === "doubao" ? transcribeDoubao(pcm, onPartial) : transcribeWeType(pcm, onPartial);
}

function loadPcm16kMono(filePath: string): Buffer {
  const raw = fs.readFileSync(filePath);
  const idx = raw.indexOf("data");
  if (raw.subarray(0, 4).toString("ascii") === "RIFF" && idx !== -1 && idx + 8 <= raw.length) {
    return raw.subarray(idx + 8);
  }
  return raw;
}

function synthesizeTtsPcm(text: string): Buffer {
  if (process.platform !== "darwin") throw new Error("--say requires macOS; on Linux use --file with a 16 kHz mono WAV/PCM file");
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "free-asr-ts-"));
  try {
    const wavPath = path.join(tmpDir, "speech.wav");
    execFileSync("/usr/bin/say", ["-v", "Tingting", "-o", wavPath, "--data-format=LEI16@16000", text]);
    return loadPcm16kMono(wavPath);
  } finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
  }
}

async function cliMain() {
  const args = process.argv.slice(2);
  let provider: ASRProvider = "wetype";
  let sayText = "";
  let filePath = "";
  let stream = false;

  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--provider" || a === "-p") {
      provider = (args[++i] as ASRProvider) || "wetype";
    } else if (a === "--say" || a === "-s") {
      sayText = args[++i] || "";
    } else if (a === "--file" || a === "--wav" || a === "-f") {
      filePath = args[++i] || "";
    } else if (a === "--stream") {
      stream = true;
    } else if (!a.startsWith("-") && !sayText && !filePath) {
      sayText = a;
    }
  }

  if (!sayText && !filePath) {
    console.error("Usage: node typescript/free_asr.ts [--provider wetype|doubao] [--say <text> | --file <audio.wav>] [--stream]");
    process.exit(1);
  }

  const pcm = filePath ? loadPcm16kMono(filePath) : synthesizeTtsPcm(sayText);
  const result = await transcribe(pcm, provider, (partial) => {
    if (stream) process.stderr.write(`\r\x1b[K⋯ ${partial}`);
  });
  if (stream && result) process.stderr.write(`\r\x1b[K✓ ${result}\n`);
  console.log(result);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  cliMain().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
