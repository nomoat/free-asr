#!/usr/bin/env python3
"""Zero-dependency Python SDK & CLI for Free ASR (Doubao IME & WeChat WeType IME).

Supports both reverse-engineered streaming ASR backends out-of-the-box with zero pip packages:
  1. `doubao` — Doubao Input Method (wss://frontier-audio-ime-ws.doubao.com/ocean/api/v1/ws, raw 16kHz PCM)
  2. `wetype` — WeChat Input Method (wss://wetype.weixin.qq.com, secp128r1 ECDH + AES-256-ECB + #!OPUS_RAW_V1)

Usage:
    python3 python/free_asr.py --provider wetype --say "今天天气很好，我们去公园散步。"
    python3 python/free_asr.py --provider doubao --say "今天天气很好，我们去公园散步。"
    python3 python/free_asr.py --provider wetype --file speech.wav --stream
"""
from __future__ import annotations

import argparse
import base64
import ctypes
import ctypes.util
import hashlib
import json
import os
import random
import shutil
import socket
import ssl
import string
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid
import wave
from typing import Callable

# ============================================================================
# Shared Minimal Protobuf Wire Codec & RFC 6455 TLS WebSocket Client
# ============================================================================

def pb_varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def pb_uint(field: int, val: int) -> bytes:
    if val == 0:
        return b""
    return pb_varint((field << 3) | 0) + pb_varint(val)


def pb_uint_always(field: int, val: int) -> bytes:
    return pb_varint((field << 3) | 0) + pb_varint(val)


def pb_bytes(field: int, data: bytes) -> bytes:
    return pb_varint((field << 3) | 2) + pb_varint(len(data)) + data


def pb_str(field: int, s: str) -> bytes:
    return pb_bytes(field, s.encode("utf-8"))


def pb_parse(buf: bytes) -> list[tuple[int, int, int | bytes]]:
    i = 0
    n = len(buf)
    out: list[tuple[int, int, int | bytes]] = []
    while i < n:
        tag = 0
        shift = 0
        while True:
            x = buf[i]
            i += 1
            tag |= (x & 0x7F) << shift
            shift += 7
            if not (x & 0x80):
                break
        f, w = tag >> 3, tag & 7
        if w == 0:
            v = 0
            shift = 0
            while True:
                x = buf[i]
                i += 1
                v |= (x & 0x7F) << shift
                shift += 7
                if not (x & 0x80):
                    break
            out.append((f, w, v))
        elif w == 2:
            ln = 0
            shift = 0
            while True:
                x = buf[i]
                i += 1
                ln |= (x & 0x7F) << shift
                shift += 7
                if not (x & 0x80):
                    break
            out.append((f, w, buf[i:i + ln]))
            i += ln
        else:
            break
    return out


class TlsWebSocket:
    def __init__(self, host: str, path_and_query: str = "/", headers: dict[str, str] | None = None):
        ctx = ssl.create_default_context()
        raw_sock = socket.create_connection((host, 443), timeout=10)
        self.sock = ctx.wrap_socket(raw_sock, server_hostname=host)
        ws_key = base64.b64encode(os.urandom(16)).decode("ascii")
        lines = [
            f"GET {path_and_query} HTTP/1.1",
            f"Host: {host}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {ws_key}",
            "Sec-WebSocket-Version: 13",
        ]
        if headers:
            for k, v in headers.items():
                lines.append(f"{k}: {v}")
        req = "\r\n".join(lines) + "\r\n\r\n"
        self.sock.sendall(req.encode("utf-8"))
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("WebSocket handshake closed unexpectedly")
            buf += chunk
        hdr, rem = buf.split(b"\r\n\r\n", 1)
        status_line = hdr.splitlines()[0].decode("latin1")
        if " 101 " not in status_line:
            raise ConnectionError(f"WebSocket handshake failed: {status_line}")
        self.buf = bytearray(rem)

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass

    def send_binary(self, payload: bytes):
        self._send_frame(0x2, payload)

    def _send_frame(self, opcode: int, payload: bytes):
        mask = os.urandom(4)
        n = len(payload)
        hdr = bytearray([0x80 | opcode])
        if n < 126:
            hdr.append(0x80 | n)
        elif n < 65536:
            hdr.append(0x80 | 126)
            hdr.extend(struct.pack(">H", n))
        else:
            hdr.append(0x80 | 127)
            hdr.extend(struct.pack(">Q", n))
        hdr.extend(mask)
        masked = bytes(payload[i] ^ mask[i & 3] for i in range(n))
        self.sock.sendall(bytes(hdr) + masked)

    def recv_frame(self) -> tuple[int, bytes]:
        while True:
            while len(self.buf) < 2:
                chunk = self.sock.recv(8192)
                if not chunk:
                    raise EOFError("WebSocket closed")
                self.buf.extend(chunk)
            b0, b1 = self.buf[0], self.buf[1]
            op = b0 & 0x0F
            masked = (b1 & 0x80) != 0
            ln = b1 & 0x7F
            idx = 2
            if ln == 126:
                while len(self.buf) < idx + 2:
                    self.buf.extend(self.sock.recv(8192))
                ln = struct.unpack(">H", self.buf[idx:idx + 2])[0]
                idx += 2
            elif ln == 127:
                while len(self.buf) < idx + 8:
                    self.buf.extend(self.sock.recv(8192))
                ln = struct.unpack(">Q", self.buf[idx:idx + 8])[0]
                idx += 8
            if masked:
                while len(self.buf) < idx + 4:
                    self.buf.extend(self.sock.recv(8192))
                mask = bytes(self.buf[idx:idx + 4])
                idx += 4
            while len(self.buf) < idx + ln:
                self.buf.extend(self.sock.recv(8192))
            pay = bytes(self.buf[idx:idx + ln])
            del self.buf[:idx + ln]
            if masked:
                pay = bytes(pay[i] ^ mask[i & 3] for i in range(ln))
            if op == 9:  # Ping -> Pong
                self._send_frame(0xA, pay)
                continue
            return op, pay


# ============================================================================
# Provider 1: Doubao Input Method Streaming ASR (DoubaoIme.app v1.0.2)
# ============================================================================

DOUBAO_HOST = "frontier-audio-ime-ws.doubao.com"
DOUBAO_APP_KEY = "OrnqKvSSrs"
DOUBAO_AID = "685343"


def _doubao_req(event: str, task_id: str, payload: str = "", data: bytes = b"", seq_id: int = 0) -> bytes:
    out = bytearray()
    out += pb_str(2, DOUBAO_APP_KEY)
    out += pb_str(3, "ASR")
    out += pb_str(5, event)
    if payload:
        out += pb_str(6, payload)
    if data:
        out += pb_bytes(7, data)
    out += pb_str(8, task_id)
    if seq_id:
        out += pb_uint(9, seq_id)
    return bytes(out)


def transcribe_doubao(pcm_bytes: bytes, on_partial: Callable[[str], None] | None = None) -> str:
    device_id = "7" + "".join(random.choices(string.digits, k=15))
    task_id = uuid.uuid4().hex
    query = urllib.parse.urlencode({
        "aid": DOUBAO_AID,
        "device_id": device_id,
        "app_name": "oime_macos",
        "channel": "release",
        "device_platform": "mac",
        "device_type": "mac",
        "device_brand": "Apple",
        "os": "macOS",
        "os_version": "15.6.0",
        "version_code": "1.0.2",
        "version_name": "1.0.2",
        "update_version_code": "1",
        "build_number": "1.0.2",
        "app_version": "1.0.2",
    })
    ws = TlsWebSocket(
        DOUBAO_HOST,
        f"/ocean/api/v1/ws?{query}",
        headers={
            "proto-version": "v2",
            "sdk-version": "2",
            "x-tt-token": "",
            "x-tt-e-k": f"{device_id}+W",
            "x-custom-keepalive": "true",
        },
    )
    try:
        ws.send_binary(_doubao_req("StartTask", task_id))
        session_cfg = {
            "audio_info": {"channel": 1, "format": "pcm", "sample_rate": 16000},
            "enable_punctuation": True,
            "enable_speech_rejection": False,
            "extra": {
                "app_name": "oime_macos",
                "app_version": "1.0.2",
                "cell_compress_rate": 8,
                "device_brand": "Apple",
                "device_id": device_id,
                "device_model": "Mac",
                "disable_user_words": False,
                "enable_asr_format": True,
                "enable_asr_threepass": True,
                "enable_asr_twopass": True,
                "enable_print_chinese": True,
                "enable_text_filter": True,
                "finish_wait_offline_time": 1000,
                "format_space_at_newline": False,
                "input_mode": "wave",
                "join_user_experience_improve_program": False,
                "max_wait_switch_offline_time": 4000,
                "offline_wait_online_interval_time": 200,
                "offline_wait_online_time": 1000,
                "os": "macOS",
                "os_version": "15.6.0",
                "remove_space_between_han_eng": False,
                "remove_space_between_han_num": True,
                "retry_server_code": [],
                "strong_ddc": True,
                "use_twopass_retry": True,
            },
        }
        ws.send_binary(_doubao_req("StartSession", task_id, payload=json.dumps(session_cfg)))

        chunk_bytes = 3200  # 100 ms of 16 kHz mono Int16 PCM
        seq = 0
        for off in range(0, len(pcm_bytes), chunk_bytes):
            seq += 1
            chunk = pcm_bytes[off:off + chunk_bytes]
            ts_ms = int(time.time() * 1000)
            ws.send_binary(_doubao_req("TaskRequest", task_id, payload=f'{{"timestamp_ms":{ts_ms}}}', data=chunk, seq_id=seq))

        ws.send_binary(_doubao_req("FinishSession", task_id))

        final_text = ""
        last_partial = ""
        while True:
            op, pay = ws.recv_frame()
            if op != 2:
                continue
            fields = {f: v for f, w, v in pb_parse(pay)}
            ev = fields.get(4, b"").decode("utf-8", "ignore") if isinstance(fields.get(4), bytes) else ""
            if ev in ("SessionFinished", "TaskFinished"):
                break
            if ev in ("SessionFailed", "TaskFailed"):
                msg = fields.get(6, b"").decode("utf-8", "ignore") if isinstance(fields.get(6), bytes) else ""
                raise RuntimeError(f"Doubao ASR {ev}: {msg}")
            payload_bytes = fields.get(7, b"")
            if isinstance(payload_bytes, bytes) and payload_bytes:
                obj = json.loads(payload_bytes.decode("utf-8", "ignore"))
                results = obj.get("results") or []
                if results:
                    first = results[0]
                    txt = first.get("text") or ""
                    is_interim = first.get("is_interim", True)
                    is_vad_fin = first.get("is_vad_finished", False)
                    if not is_interim or is_vad_fin:
                        final_text = txt
                    elif txt and txt != last_partial:
                        last_partial = txt
                        if on_partial:
                            on_partial(txt)

        ws.send_binary(_doubao_req("FinishTask", task_id))
        return final_text or last_partial
    finally:
        ws.close()


# ============================================================================
# Provider 2: WeChat Input Method / WeType Streaming ASR (WeType.app v3.0.0)
# ============================================================================

WETYPE_HOST = "wetype.weixin.qq.com"
WETYPE_SIGN_KEY = "zN7rB3bL4pO8jW1o"
WETYPE_HS_AES_KEY = "D4Y5U3Y2M0C0T7N4P1P7O2N6E1I2Y1U6"
WETYPE_OS_TYPE = "5"
WETYPE_VERSION = "3.0.0(670)"
WETYPE_SYS_VER = "27.0.0"
WETYPE_PKG_TYPE = "3"
WETYPE_SCENE = "2"
WETYPE_CMD_ASR = "4548"
WETYPE_TID_DH = 2147483646
WETYPE_TID_UIN = 2147483645

SECP128R1_P = 0xFFFFFFFDFFFFFFFFFFFFFFFFFFFFFFFF
SECP128R1_A = 0xFFFFFFFDFFFFFFFFFFFFFFFFFFFFFFFC
SECP128R1_GX = 0x161FF7528B899B2D0C28607CA52C5B86
SECP128R1_GY = 0xCF5AC8395BAFEB13C02DA292DDED7A83
SECP128R1_N = 0xFFFFFFFE0000000075A30D1B9038A115


def _ec_inv(x: int) -> int:
    return pow(x, SECP128R1_P - 2, SECP128R1_P)


def _ec_add(pt1, pt2):
    if pt1 is None:
        return pt2
    if pt2 is None:
        return pt1
    x1, y1 = pt1
    x2, y2 = pt2
    if x1 == x2 and (y1 + y2) % SECP128R1_P == 0:
        return None
    if pt1 == pt2:
        lam = (3 * x1 * x1 + SECP128R1_A) * _ec_inv(2 * y1) % SECP128R1_P
    else:
        lam = (y2 - y1) * _ec_inv(x2 - x1) % SECP128R1_P
    x3 = (lam * lam - x1 - x2) % SECP128R1_P
    y3 = (lam * (x1 - x3) - y1) % SECP128R1_P
    return (x3, y3)


def _ec_mul(k: int, pt=(SECP128R1_GX, SECP128R1_GY)):
    res = None
    cur = pt
    while k:
        if k & 1:
            res = _ec_add(res, cur)
        cur = _ec_add(cur, cur)
        k >>= 1
    return res


_cc = None
if sys.platform == "darwin":
    _cc = ctypes.CDLL("/usr/lib/system/libcommonCrypto.dylib")
    _cc.CCCrypt.argtypes = [
        ctypes.c_uint32, ctypes.c_uint32, ctypes.c_uint32,
        ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p,
        ctypes.c_void_p, ctypes.c_size_t,
        ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_size_t),
    ]
    _cc.CCCrypt.restype = ctypes.c_int32


def _openssl_aes(key_ascii: str, data: bytes, encrypt: bool) -> bytes:
    """Use system libcrypto; no Python packages or per-request subprocesses."""
    name = ctypes.util.find_library("crypto")
    if not name:
        raise RuntimeError("WeType on Linux requires OpenSSL libcrypto (install libssl3)")
    lib = ctypes.CDLL(name)
    ptr = ctypes.c_void_p
    lib.EVP_CIPHER_CTX_new.restype = ptr
    lib.EVP_CIPHER_CTX_free.argtypes = [ptr]
    lib.EVP_aes_256_ecb.restype = ptr
    lib.EVP_CipherInit_ex.argtypes = [ptr, ptr, ptr, ptr, ptr, ctypes.c_int]
    lib.EVP_CipherUpdate.argtypes = [ptr, ptr, ctypes.POINTER(ctypes.c_int), ptr, ctypes.c_int]
    lib.EVP_CipherFinal_ex.argtypes = [ptr, ptr, ctypes.POINTER(ctypes.c_int)]
    if len(key_ascii) != 32:
        raise ValueError("AES-256 key must be 32 ASCII bytes")
    ctx = lib.EVP_CIPHER_CTX_new()
    if not ctx:
        raise RuntimeError("OpenSSL context allocation failed")
    try:
        out = ctypes.create_string_buffer(len(data) + 32)
        count, final = ctypes.c_int(), ctypes.c_int()
        if lib.EVP_CipherInit_ex(ctx, lib.EVP_aes_256_ecb(), None, key_ascii.encode("ascii"), None, int(encrypt)) != 1:
            raise RuntimeError("OpenSSL AES initialization failed")
        if lib.EVP_CipherUpdate(ctx, out, ctypes.byref(count), data, len(data)) != 1:
            raise RuntimeError("OpenSSL AES update failed")
        if lib.EVP_CipherFinal_ex(ctx, ctypes.byref(out, count.value), ctypes.byref(final)) != 1:
            raise RuntimeError("OpenSSL AES finalization failed (invalid padding)")
        return out.raw[:count.value + final.value]
    finally:
        lib.EVP_CIPHER_CTX_free(ctx)


def _aes256_ecb_enc(key_ascii: str, data: bytes) -> bytes:
    if _cc is None:
        return _openssl_aes(key_ascii, data, True)
    key_b = key_ascii.encode("ascii")
    out_cap = len(data) + 32
    out_buf = ctypes.create_string_buffer(out_cap)
    out_len = ctypes.c_size_t(0)
    st = _cc.CCCrypt(0, 0, 3, key_b, len(key_b), None, data, len(data), out_buf, out_cap, ctypes.byref(out_len))
    if st != 0:
        raise RuntimeError(f"CCCrypt encrypt failed: {st}")
    return out_buf.raw[:out_len.value]


def _aes256_ecb_dec(key_ascii: str, data: bytes) -> bytes:
    if not data:
        return b""
    if len(data) % 16:
        raise RuntimeError("AES ciphertext must contain complete 16-byte blocks")
    if _cc is None:
        return _openssl_aes(key_ascii, data, False)
    key_b = key_ascii.encode("ascii")
    out_cap = len(data) + 32
    out_buf = ctypes.create_string_buffer(out_cap)
    out_len = ctypes.c_size_t(0)
    st = _cc.CCCrypt(1, 0, 3, key_b, len(key_b), None, data, len(data), out_buf, out_cap, ctypes.byref(out_len))
    if st != 0:
        raise RuntimeError(f"CCCrypt decrypt failed: {st}")
    return out_buf.raw[:out_len.value]


def _snappy_compress(data: bytes) -> bytes:
    out = bytearray(pb_varint(len(data)))
    i = 0
    n = len(data)
    while i < n:
        chunk = data[i:i + 65536]
        ln = len(chunk) - 1
        if ln < 60:
            out.append(ln << 2)
        elif ln < 256:
            out.append(60 << 2)
            out.append(ln)
        else:
            out.append(61 << 2)
            out.extend(struct.pack("<H", ln))
        out.extend(chunk)
        i += len(chunk)
    return bytes(out)


def _snappy_decompress(data: bytes) -> bytes:
    i = 0
    ln = 0
    shift = 0
    while True:
        x = data[i]
        i += 1
        ln |= (x & 0x7F) << shift
        shift += 7
        if not (x & 0x80):
            break
    out = bytearray()
    n = len(data)
    while i < n:
        tag = data[i]
        i += 1
        t = tag & 3
        if t == 0:
            l = tag >> 2
            if l >= 60:
                nb = l - 59
                l = int.from_bytes(data[i:i + nb], "little")
                i += nb
            l += 1
            out.extend(data[i:i + l])
            i += l
        else:
            if t == 1:
                l = ((tag >> 2) & 7) + 4
                off = ((tag >> 5) << 8) | data[i]
                i += 1
            elif t == 2:
                l = (tag >> 2) + 1
                off = int.from_bytes(data[i:i + 2], "little")
                i += 2
            else:
                l = (tag >> 2) + 1
                off = int.from_bytes(data[i:i + 4], "little")
                i += 4
            for _ in range(l):
                out.append(out[-off])
    return bytes(out)


def _ffmpeg_opus_chunks(pcm: bytes, frames_per_chunk: int) -> list[bytes]:
    ogg = subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "s16le", "-ar", "16000", "-ac", "1", "-i", "pipe:0",
        "-c:a", "libopus", "-b:a", "64k", "-vbr", "off", "-application", "voip", "-frame_duration", "20", "-f", "opus", "pipe:1",
    ], input=pcm, capture_output=True, check=True, timeout=60).stdout
    at, packets, packet = 0, [], bytearray()
    while at < len(ogg):
        if at + 27 > len(ogg) or ogg[at:at + 4] != b"OggS":
            raise ValueError("Invalid Ogg page")
        count = ogg[at + 26]
        table, offset = at + 27, at + 27 + count
        if offset > len(ogg):
            raise ValueError("Truncated Ogg page")
        for size in ogg[table:offset]:
            if offset + size > len(ogg):
                raise ValueError("Truncated Opus packet")
            packet.extend(ogg[offset:offset + size])
            offset += size
            if size < 255:
                if packet[:8] not in (b"OpusHead", b"OpusTags"):
                    packets.append(bytes(packet))
                packet.clear()
        at = offset
    if packet:
        raise ValueError("Truncated Opus packet")
    chunks = []
    for i in range(0, len(packets), frames_per_chunk):
        header = b"#!OPUS_RAW_V1\x02\x01\x00" if i == 0 else b""
        chunks.append(header + b"".join(struct.pack("<H", len(p)) + p for p in packets[i:i + frames_per_chunk]))
    return chunks


def encode_wetype_opus_chunks(pcm_bytes: bytes, frames_per_chunk: int = 5) -> list[bytes]:
    """Encodes 16 kHz mono s16le PCM to WeType #!OPUS_RAW_V1 chunks using macOS `/usr/bin/afconvert`."""
    if frames_per_chunk < 1:
        raise ValueError("frames_per_chunk must be positive")
    if not pcm_bytes:
        return []
    if sys.platform != "darwin":
        return _ffmpeg_opus_chunks(pcm_bytes, frames_per_chunk)
    tmp_dir = tempfile.mkdtemp(prefix="wetype-opus-")
    try:
        in_wav = os.path.join(tmp_dir, "in.wav")
        out_caf = os.path.join(tmp_dir, "out.caf")
        with wave.open(in_wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(16000)
            w.writeframes(pcm_bytes)
        subprocess.run(
            ["/usr/bin/afconvert", "-f", "caff", "-d", "opus@16000", "-b", "64000", in_wav, out_caf],
            check=True,
            capture_output=True,
        )
        caf = open(out_caf, "rb").read()
        pos = 8
        caf_chunks = {}
        while pos + 12 <= len(caf):
            ctype = caf[pos:pos + 4]
            clen = struct.unpack(">q", caf[pos + 4:pos + 12])[0]
            pos += 12
            caf_chunks[ctype] = caf[pos:pos + clen]
            pos += clen
        pakt = caf_chunks[b"pakt"]
        num_pkts = struct.unpack(">q", pakt[:8])[0]
        idx = 24
        pkt_sizes = []
        for _ in range(num_pkts):
            v = 0
            while True:
                b = pakt[idx]
                idx += 1
                v = (v << 7) | (b & 0x7F)
                if not (b & 0x80):
                    break
            pkt_sizes.append(v)
        raw_data = caf_chunks[b"data"][4:]
        chunks: list[bytes] = []
        cur = bytearray(b"#!OPUS_RAW_V1\x02\x01\x00")
        f_count = 0
        doff = 0
        for sz in pkt_sizes:
            pkt = raw_data[doff:doff + sz]
            doff += sz
            cur += struct.pack("<H", len(pkt)) + pkt
            f_count += 1
            if f_count == frames_per_chunk:
                chunks.append(bytes(cur))
                cur = bytearray()
                f_count = 0
        if cur:
            chunks.append(bytes(cur))
        return chunks
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


WETYPE_CACHE_PATH = os.path.expanduser("~/.cache/free-asr/wetype_session.json")


def _wetype_send_req(ws: TlsWebSocket, task_id: int, path: str, headers: list[tuple[str, str]], body: bytes):
    http_req = pb_str(1, "POST") + pb_str(3, path) + pb_str(4, "")
    for k, v in headers:
        http_req += pb_bytes(5, pb_str(1, k) + pb_str(2, str(v)))
    http_req += pb_bytes(6, body)
    pb_req = pb_uint_always(1, 0) + pb_uint_always(2, 0) + pb_uint_always(3, task_id) + pb_bytes(5, http_req)
    ws.send_binary(pb_req)


def _wetype_recv_rsp(ws: TlsWebSocket, expected_tid: int | None = None):
    while True:
        op, pay = ws.recv_frame()
        if op != 2:
            continue
        top = dict((f, v) for f, w, v in pb_parse(pay))
        seq = top.get(2, 0)
        if seq == 0:
            continue
        status = 0
        hdrs = {}
        body = b""
        for rf, rw, rv in pb_parse(top.get(4, b"")):
            if rf == 2 and isinstance(rv, int):
                status = rv
            elif rf == 4 and isinstance(rv, bytes):
                kv = dict((kf, kv.decode("utf-8", "ignore")) for kf, kw, kv in pb_parse(rv) if isinstance(kv, bytes))
                hdrs[kv.get(1, "").lower()] = kv.get(2, "")
            elif rf == 5 and isinstance(rv, bytes):
                body = rv
        if expected_tid is None or seq == expected_tid:
            return seq, status, hdrs, body


def _wetype_handshake(ws: TlsWebSocket) -> dict:
    priv = random.randrange(2, SECP128R1_N - 1)
    pub_x, pub_y = _ec_mul(priv)
    client_pub_hex = f"04{pub_x:032X}{pub_y:032X}"
    dev_name = "Mac17,8"
    prefix32 = "MAC" + dev_name.rjust(17, "0") + "".join(random.choices(string.ascii_lowercase, k=12))
    dev_code = prefix32 + hashlib.md5((prefix32 + WETYPE_SIGN_KEY).encode("ascii")).hexdigest().upper()

    ecdh_req = (
        pb_str(1, client_pub_hex) +
        pb_str(2, "") +
        pb_uint(3, 1) +
        pb_str(4, dev_code) +
        pb_str(7, "") +
        pb_str(8, dev_name) +
        pb_str(9, "")
    )
    enc_body = _aes256_ecb_enc(WETYPE_HS_AES_KEY, ecdh_req)
    ts = str(int(time.time() * 1000))
    trace_id = "".join(random.choices(string.ascii_lowercase, k=16))
    body_md5 = hashlib.md5(enc_body).hexdigest().upper()
    tid1 = str(WETYPE_TID_DH)
    kb_sign = hashlib.sha256(
        (WETYPE_OS_TYPE + WETYPE_VERSION + WETYPE_SCENE + ts + body_md5 + trace_id + tid1 + WETYPE_SIGN_KEY).encode("ascii")
    ).hexdigest().upper()

    _wetype_send_req(ws, WETYPE_TID_DH, "/oauth_pubkey_v2", [
        ("Kb-Uin", "0"),
        ("Kb-DeviceCodeRestrictionV2", "1"),
        ("Kb-OsType", WETYPE_OS_TYPE),
        ("Kb-Version", WETYPE_VERSION),
        ("Kb-SystemVersion", WETYPE_SYS_VER),
        ("Kb-PackageType", WETYPE_PKG_TYPE),
        ("Use_DebugNet", "0"),
        ("Kb-TimeStamp", ts),
        ("Kb-BodyMd5", body_md5),
        ("Kb-TraceId", trace_id),
        ("Kb-TaskId", tid1),
        ("Kb-Scene", WETYPE_SCENE),
        ("Kb-Sign", kb_sign),
        ("Content-Length", str(len(enc_body))),
        ("Kb-CompressionType", "1"),
        ("Content-Type", "application/octet-stream"),
        ("HOST", WETYPE_HOST),
    ], enc_body)

    _, status, _, rbody = _wetype_recv_rsp(ws, WETYPE_TID_DH)
    if status != 200:
        raise RuntimeError(f"/oauth_pubkey_v2 HTTP {status}")
    rsp_map = {f: v for f, w, v in pb_parse(_aes256_ecb_dec(WETYPE_HS_AES_KEY, rbody))}
    svr_pub_hex = rsp_map[2].decode("ascii")
    gen_uin_token = rsp_map[4].decode("ascii")
    shared_x, _ = _ec_mul(priv, (int(svr_pub_hex[2:34], 16), int(svr_pub_hex[34:66], 16)))
    aes_key = f"{shared_x:032X}"

    gen_uin_req = (
        pb_str(1, dev_code) +
        pb_str(2, svr_pub_hex) +
        pb_str(4, uuid.uuid4().hex) +
        pb_str(5, "")
    )
    enc_body2 = _aes256_ecb_enc(aes_key, gen_uin_req)
    ts2 = str(int(time.time() * 1000))
    trace_id2 = "".join(random.choices(string.ascii_lowercase, k=16))
    body_md5_2 = hashlib.md5(enc_body2).hexdigest().upper()
    tid2 = str(WETYPE_TID_UIN)
    kb_sign2 = hashlib.sha256(
        (WETYPE_OS_TYPE + WETYPE_VERSION + WETYPE_SCENE + ts2 + body_md5_2 + gen_uin_token + trace_id2 + tid2 + WETYPE_SIGN_KEY).encode("ascii")
    ).hexdigest().upper()

    _wetype_send_req(ws, WETYPE_TID_UIN, "/gen_uin_v2", [
        ("Kb-GenUinToken", gen_uin_token),
        ("Kb-DeviceCodeRestrictionV2", "1"),
        ("Kb-OsType", WETYPE_OS_TYPE),
        ("Kb-Version", WETYPE_VERSION),
        ("Kb-SystemVersion", WETYPE_SYS_VER),
        ("Kb-PackageType", WETYPE_PKG_TYPE),
        ("Use_DebugNet", "0"),
        ("Kb-TimeStamp", ts2),
        ("Kb-BodyMd5", body_md5_2),
        ("Kb-TraceId", trace_id2),
        ("Kb-TaskId", tid2),
        ("Kb-Scene", WETYPE_SCENE),
        ("Kb-Sign", kb_sign2),
        ("Content-Length", str(len(enc_body2))),
        ("Kb-CompressionType", "1"),
        ("Content-Type", "application/octet-stream"),
        ("HOST", WETYPE_HOST),
    ], enc_body2)

    _, status2, _, rbody2 = _wetype_recv_rsp(ws, WETYPE_TID_UIN)
    if status2 != 200:
        raise RuntimeError(f"/gen_uin_v2 HTTP {status2}")
    rsp2_map = {f: v for f, w, v in pb_parse(_aes256_ecb_dec(aes_key, rbody2))}
    uin = str(rsp2_map[2])
    sess = {"uin": uin, "aes_key": aes_key}
    try:
        os.makedirs(os.path.dirname(WETYPE_CACHE_PATH), exist_ok=True)
        with open(WETYPE_CACHE_PATH, "w", encoding="utf-8") as f:
            json.dump(sess, f)
    except Exception:
        pass
    return sess


def transcribe_wetype(pcm_bytes: bytes, on_partial: Callable[[str], None] | None = None) -> str:
    chunks = encode_wetype_opus_chunks(pcm_bytes)
    if not chunks:
        return ""
    ws = TlsWebSocket(WETYPE_HOST, "/", headers={"Sec-WebSocket-Protocol": "wxws_pb"})
    try:
        sess = None
        try:
            with open(WETYPE_CACHE_PATH, "r", encoding="utf-8") as f:
                sess = json.load(f)
        except Exception:
            pass
        if not sess or not sess.get("uin") or len(sess.get("aes_key", "")) != 32:
            sess = _wetype_handshake(ws)

        for attempt in range(2):
            uin = sess["uin"]
            aes_key = sess["aes_key"]
            voice_id = "".join(random.choices(string.digits, k=25))
            total_offset = 0

            def send_voice(tid: int, inner_bytes: bytes):
                payload = pb_bytes(1, inner_bytes)
                if len(payload) >= 301:
                    raw_body = _snappy_compress(payload)
                    comp_type = "2"
                else:
                    raw_body = payload
                    comp_type = "1"
                enc = _aes256_ecb_enc(aes_key, raw_body)
                ts_i = str(int(time.time() * 1000))
                tr_i = "".join(random.choices(string.ascii_lowercase, k=16))
                md5_i = hashlib.md5(enc).hexdigest().upper()
                sgn_i = hashlib.sha256((
                    WETYPE_OS_TYPE + WETYPE_VERSION + WETYPE_SCENE + WETYPE_CMD_ASR + "0" +
                    ts_i + md5_i + uin + tr_i + str(tid) + WETYPE_SIGN_KEY
                ).encode("ascii")).hexdigest().upper()
                _wetype_send_req(ws, tid, "/api_v2", [
                    ("Kb-Uin", uin),
                    ("Kb-SharedKeySuffix", aes_key[-4:]),
                    ("Kb-CmdId", WETYPE_CMD_ASR),
                    ("Kb-SubCmdId", "0"),
                    ("Kb-OsType", WETYPE_OS_TYPE),
                    ("Kb-Version", WETYPE_VERSION),
                    ("Kb-SystemVersion", WETYPE_SYS_VER),
                    ("Kb-PackageType", WETYPE_PKG_TYPE),
                    ("Use_DebugNet", "0"),
                    ("Kb-TimeStamp", ts_i),
                    ("Kb-BodyMd5", md5_i),
                    ("Kb-TraceId", tr_i),
                    ("Kb-TaskId", str(tid)),
                    ("Kb-Scene", WETYPE_SCENE),
                    ("Kb-Sign", sgn_i),
                    ("Content-Length", str(len(enc))),
                    ("Kb-CompressionType", comp_type),
                    ("Content-Type", "application/octet-stream"),
                    ("HOST", WETYPE_HOST),
                ], enc)

            for idx, audio in enumerate(chunks, 1):
                total_offset += len(audio)
                is_end = 1 if idx == len(chunks) else 0
                msg = (
                    pb_str(2, voice_id) +
                    pb_bytes(4, audio) +
                    pb_uint(5, 5) +
                    (pb_uint(6, 1) if is_end else b"") +
                    pb_uint(7, idx) +
                    pb_uint(11, total_offset) +
                    pb_uint(24, 1)
                )
                send_voice(idx, msg)

            last_text = ""
            end_flag = 0
            expired = False

            for _ in range(len(chunks)):
                _, status, hdrs, rbody = _wetype_recv_rsp(ws)
                if status in (5004, 5011):
                    expired = True
                    break
                if status != 200 or not rbody:
                    continue
                dec = _aes256_ecb_dec(aes_key, rbody)
                if hdrs.get("kb-compressiontype") == "2":
                    dec = _snappy_decompress(dec)
                outer = pb_parse(dec)
                rsp = {f: v for f, w, v in pb_parse(outer[0][2])} if outer and isinstance(outer[0][2], bytes) else {}
                raw_txt = rsp.get(14) or rsp.get(4) or b""
                txt = raw_txt.decode("utf-8", "ignore") if isinstance(raw_txt, bytes) else ""
                if txt and txt != last_text:
                    last_text = txt
                    if on_partial:
                        on_partial(txt)
                if rsp.get(5) == 1:
                    end_flag = 1

            if expired and attempt == 0:
                sess = _wetype_handshake(ws)
                continue

            poll_tid = len(chunks) + 1
            while not end_flag and poll_tid <= len(chunks) + 30:
                time.sleep(0.1)
                poll_msg = (
                    pb_str(2, voice_id) +
                    pb_uint(5, 5) +
                    pb_uint(6, 1) +
                    pb_uint(11, total_offset) +
                    pb_uint(24, 1)
                )
                send_voice(poll_tid, poll_msg)
                _, status, hdrs, rbody = _wetype_recv_rsp(ws, poll_tid)
                poll_tid += 1
                if status != 200 or not rbody:
                    continue
                dec = _aes256_ecb_dec(aes_key, rbody)
                if hdrs.get("kb-compressiontype") == "2":
                    dec = _snappy_decompress(dec)
                outer = pb_parse(dec)
                rsp = {f: v for f, w, v in pb_parse(outer[0][2])} if outer and isinstance(outer[0][2], bytes) else {}
                raw_txt = rsp.get(14) or rsp.get(4) or b""
                txt = raw_txt.decode("utf-8", "ignore") if isinstance(raw_txt, bytes) else ""
                if txt:
                    last_text = txt
                if rsp.get(5) == 1:
                    break

            return last_text
        return ""
    finally:
        ws.close()


# ============================================================================
# Unified API & CLI Entrypoint
# ============================================================================

def transcribe(pcm_bytes: bytes, provider: str = "wetype", on_partial: Callable[[str], None] | None = None) -> str:
    if provider == "doubao":
        return transcribe_doubao(pcm_bytes, on_partial=on_partial)
    elif provider == "wetype":
        return transcribe_wetype(pcm_bytes, on_partial=on_partial)
    raise ValueError(f"Unknown provider: {provider}")


def load_pcm_16k_mono(path: str) -> bytes:
    if path.lower().endswith(".pcm"):
        with open(path, "rb") as f:
            return f.read()
    try:
        with wave.open(path, "rb") as w:
            if w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2:
                return w.readframes(w.getnframes())
    except wave.Error:
        pass
    if sys.platform != "darwin":
        return subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path, "-f", "s16le", "-ac", "1", "-ar", "16000", "pipe:1"], capture_output=True, check=True, timeout=60).stdout
    tmp_dir = tempfile.mkdtemp(prefix="free-asr-")
    try:
        out_wav = os.path.join(tmp_dir, "converted.wav")
        subprocess.run(
            ["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", path, out_wav],
            check=True,
            capture_output=True,
        )
        with wave.open(out_wav, "rb") as w:
            return w.readframes(w.getnframes())
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def synthesize_tts_pcm(text: str) -> bytes:
    if sys.platform != "darwin":
        raise RuntimeError("--say requires macOS; on Linux use --file with a WAV/PCM file")
    tmp_dir = tempfile.mkdtemp(prefix="free-asr-")
    try:
        wav_path = os.path.join(tmp_dir, "speech.wav")
        subprocess.run(
            ["/usr/bin/say", "-v", "Tingting", "-o", wav_path, "--data-format=LEI16@16000", text],
            check=True,
        )
        with wave.open(wav_path, "rb") as w:
            return w.readframes(w.getnframes())
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


def main() -> int:
    ap = argparse.ArgumentParser(description="Free ASR Python CLI (Doubao IME & WeChat WeType IME)")
    ap.add_argument("text", nargs="?", help="Text to synthesize with macOS `say` and transcribe")
    ap.add_argument("--provider", "-p", choices=["wetype", "doubao"], default="wetype", help="ASR provider (default: wetype)")
    ap.add_argument("--say", "-s", help="Text to synthesize with macOS `say` and transcribe")
    ap.add_argument("--file", "--wav", "-f", dest="file", help="Path to audio file")
    ap.add_argument("--stream", action="store_true", help="Print live partial results to stderr")
    args = ap.parse_args()

    if args.file:
        pcm = load_pcm_16k_mono(args.file)
    elif args.say or args.text:
        pcm = synthesize_tts_pcm(args.say or args.text)
    else:
        ap.error("Provide text (or --say) or --file/--wav")

    def handle_partial(txt: str):
        if args.stream:
            sys.stderr.write(f"\r\033[K⋯ {txt}")
            sys.stderr.flush()

    text = transcribe(pcm, provider=args.provider, on_partial=handle_partial)
    if args.stream and text:
        sys.stderr.write(f"\r\033[K✓ {text}\n")
        sys.stderr.flush()
    if text:
        print(text)
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
