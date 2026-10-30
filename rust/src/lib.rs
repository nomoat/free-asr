//! Zero-dependency Rust SDK for Free ASR (Doubao IME & WeChat WeType IME).
//!
//! Uses macOS Security/CommonCrypto or Linux OpenSSL and FFmpeg,
//! requiring zero third-party crates from crates.io.

#[cfg(target_os = "macos")]
use std::ffi::{c_char, c_int, c_void};
#[cfg(target_os = "macos")]
use std::fs;
use std::net::{TcpStream, ToSocketAddrs};
#[cfg(target_os = "macos")]
use std::os::unix::io::AsRawFd;
#[cfg(target_os = "macos")]
use std::path::PathBuf;
#[cfg(target_os = "macos")]
use std::process::Command;
#[cfg(target_os = "macos")]
use std::ptr;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use linux::{random_bytes, md5_upper, sha256_upper, aes256_ecb_encrypt, aes256_ecb_decrypt};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Provider {
    WeType,
    Doubao,
}

// ============================================================================
// 1. macOS System FFI: CommonCrypto (MD5, SHA256, AES-256-ECB) & Security TLS
// ============================================================================

#[cfg(target_os = "macos")]
#[link(name = "System")]
extern "C" {
    fn CC_MD5(data: *const c_void, len: u32, md: *mut u8) -> *mut u8;
    fn CC_SHA256(data: *const c_void, len: u32, md: *mut u8) -> *mut u8;
    fn CCCrypt(
        op: u32,
        alg: u32,
        options: u32,
        key: *const c_void,
        key_length: usize,
        iv: *const c_void,
        data_in: *const c_void,
        data_in_length: usize,
        data_out: *mut c_void,
        data_out_available: usize,
        data_out_moved: *mut usize,
    ) -> i32;
    fn arc4random_buf(buf: *mut c_void, nbytes: usize);
}

#[cfg(target_os = "macos")]
#[repr(C)]
struct SSLContext(c_void);

#[cfg(target_os = "macos")]
type SSLConnectionRef = *const c_void;
#[cfg(target_os = "macos")]
type SSLReadFunc = extern "C" fn(SSLConnectionRef, *mut c_void, *mut usize) -> i32;
#[cfg(target_os = "macos")]
type SSLWriteFunc = extern "C" fn(SSLConnectionRef, *const c_void, *mut usize) -> i32;

#[cfg(target_os = "macos")]
#[link(name = "Security", kind = "framework")]
extern "C" {
    fn SSLCreateContext(alloc: *const c_void, protocol_side: c_int, connection_type: c_int) -> *mut SSLContext;
    fn SSLSetIOFuncs(ctx: *mut SSLContext, read_func: SSLReadFunc, write_func: SSLWriteFunc) -> i32;
    fn SSLSetConnection(ctx: *mut SSLContext, connection: SSLConnectionRef) -> i32;
    fn SSLSetPeerDomainName(ctx: *mut SSLContext, peer_name: *const c_char, peer_name_len: usize) -> i32;
    fn SSLHandshake(ctx: *mut SSLContext) -> i32;
    fn SSLWrite(ctx: *mut SSLContext, data: *const c_void, data_length: usize, processed: *mut usize) -> i32;
    fn SSLRead(ctx: *mut SSLContext, data: *mut c_void, data_length: usize, processed: *mut usize) -> i32;
    fn SSLClose(ctx: *mut SSLContext) -> i32;
}

#[cfg(target_os = "macos")]
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(cf: *const c_void);
}

#[cfg(target_os = "macos")]
extern "C" {
    fn read(fd: c_int, buf: *mut c_void, count: usize) -> isize;
    fn write(fd: c_int, buf: *const c_void, count: usize) -> isize;
}

#[cfg(target_os = "macos")]
extern "C" fn ssl_read_cb(connection: SSLConnectionRef, data: *mut c_void, data_len: *mut usize) -> i32 {
    let fd = connection as usize as c_int;
    let requested = unsafe { *data_len };
    let mut total = 0usize;
    while total < requested {
        let n = unsafe { read(fd, (data as *mut u8).add(total) as *mut c_void, requested - total) };
        if n > 0 {
            total += n as usize;
        } else if n == 0 {
            unsafe { *data_len = total };
            return -9805; // errSSLClosedGraceful
        } else {
            unsafe { *data_len = total };
            return -9806; // errSSLClosedAbort
        }
    }
    unsafe { *data_len = total };
    0
}

#[cfg(target_os = "macos")]
extern "C" fn ssl_write_cb(connection: SSLConnectionRef, data: *const c_void, data_len: *mut usize) -> i32 {
    let fd = connection as usize as c_int;
    let requested = unsafe { *data_len };
    let mut total = 0usize;
    while total < requested {
        let n = unsafe { write(fd, (data as *const u8).add(total) as *const c_void, requested - total) };
        if n > 0 {
            total += n as usize;
        } else {
            unsafe { *data_len = total };
            return -9806;
        }
    }
    unsafe { *data_len = total };
    0
}

#[cfg(target_os = "macos")]
pub fn random_bytes(len: usize) -> Vec<u8> {
    let mut buf = vec![0u8; len];
    unsafe { arc4random_buf(buf.as_mut_ptr() as *mut c_void, len) };
    buf
}

#[cfg(target_os = "macos")]
pub fn md5_upper(data: &[u8]) -> String {
    let mut digest = [0u8; 16];
    unsafe { CC_MD5(data.as_ptr() as *const c_void, data.len() as u32, digest.as_mut_ptr()) };
    digest.iter().map(|b| format!("{:02X}", b)).collect()
}

#[cfg(target_os = "macos")]
pub fn sha256_upper(data: &[u8]) -> String {
    let mut digest = [0u8; 32];
    unsafe { CC_SHA256(data.as_ptr() as *const c_void, data.len() as u32, digest.as_mut_ptr()) };
    digest.iter().map(|b| format!("{:02X}", b)).collect()
}

#[cfg(target_os = "macos")]
pub fn aes256_ecb_encrypt(key_ascii: &str, data: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = vec![0u8; data.len() + 32];
    let mut moved = 0usize;
    let st = unsafe {
        CCCrypt(
            0, // kCCEncrypt
            0, // kCCAlgorithmAES
            3, // kCCOptionPKCS7Padding | kCCOptionECBMode
            key_ascii.as_ptr() as *const c_void,
            key_ascii.len(),
            ptr::null(),
            data.as_ptr() as *const c_void,
            data.len(),
            out.as_mut_ptr() as *mut c_void,
            out.len(),
            &mut moved,
        )
    };
    if st != 0 {
        return Err(format!("CCCrypt encrypt failed: {}", st));
    }
    out.truncate(moved);
    Ok(out)
}

#[cfg(target_os = "macos")]
pub fn aes256_ecb_decrypt(key_ascii: &str, data: &[u8]) -> Result<Vec<u8>, String> {
    if data.is_empty() {
        return Ok(Vec::new());
    }
    let mut out = vec![0u8; data.len() + 32];
    let mut moved = 0usize;
    let st = unsafe {
        CCCrypt(
            1, // kCCDecrypt
            0, // kCCAlgorithmAES
            3, // kCCOptionPKCS7Padding | kCCOptionECBMode
            key_ascii.as_ptr() as *const c_void,
            key_ascii.len(),
            ptr::null(),
            data.as_ptr() as *const c_void,
            data.len(),
            out.as_mut_ptr() as *mut c_void,
            out.len(),
            &mut moved,
        )
    };
    if st != 0 {
        return Err(format!("CCCrypt decrypt failed: {}", st));
    }
    out.truncate(moved);
    Ok(out)
}

// ============================================================================
// 2. TLS WebSocket Client (RFC 6455 over Security.framework)
// ============================================================================

struct TlsWebSocket {
    _tcp: TcpStream,
    #[cfg(target_os = "macos")]
    ctx: *mut SSLContext,
    #[cfg(target_os = "linux")]
    tls: linux::TlsStream,
    buf: Vec<u8>,
}

impl TlsWebSocket {
    fn connect(host: &str, path_and_query: &str, headers: &[(&str, &str)]) -> Result<Self, String> {
        let addr = (host, 443)
            .to_socket_addrs()
            .map_err(|e| e.to_string())?
            .next()
            .ok_or_else(|| "DNS resolution failed".to_string())?;
        let tcp = TcpStream::connect_timeout(&addr, Duration::from_secs(10)).map_err(|e| e.to_string())?;
        tcp.set_read_timeout(Some(Duration::from_secs(15))).ok();
        tcp.set_write_timeout(Some(Duration::from_secs(15))).ok();

        #[cfg(target_os = "macos")]
        let ctx = {
            let ctx = unsafe { SSLCreateContext(ptr::null(), 1 /* kSSLClientSide */, 0 /* kSSLStreamType */) };
            if ctx.is_null() {
                return Err("SSLCreateContext failed".to_string());
            }
            unsafe {
                SSLSetIOFuncs(ctx, ssl_read_cb, ssl_write_cb);
                SSLSetConnection(ctx, tcp.as_raw_fd() as usize as SSLConnectionRef);
                SSLSetPeerDomainName(ctx, host.as_ptr() as *const c_char, host.len());
                let st = SSLHandshake(ctx);
                if st != 0 {
                    CFRelease(ctx as *const c_void);
                    return Err(format!("SSLHandshake failed: {}", st));
                }
            }

            ctx
        };
        #[cfg(target_os = "linux")]
        let tls = linux::TlsStream::connect(&tcp, host)?;

        let mut ws = Self {
            _tcp: tcp,
            #[cfg(target_os = "macos")]
            ctx,
            #[cfg(target_os = "linux")]
            tls,
            buf: Vec::new(),
        };

        let key = base64_encode(&random_bytes(16));
        let mut req = format!(
            "GET {} HTTP/1.1\r\nHost: {}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {}\r\nSec-WebSocket-Version: 13\r\n",
            path_and_query, host, key
        );
        for (k, v) in headers {
            req.push_str(&format!("{}: {}\r\n", k, v));
        }
        req.push_str("\r\n");
        ws.tls_write_all(req.as_bytes())?;

        loop {
            if let Some(pos) = ws.buf.windows(4).position(|w| w == b"\r\n\r\n") {
                let hdr = String::from_utf8_lossy(&ws.buf[..pos]).to_string();
                ws.buf.drain(..pos + 4);
                if !hdr.lines().next().unwrap_or("").contains(" 101 ") {
                    return Err(format!("WebSocket handshake failed: {}", hdr.lines().next().unwrap_or("")));
                }
                break;
            }
            let mut tmp = [0u8; 4096];
            let n = ws.tls_read(&mut tmp)?;
            if n == 0 {
                return Err("EOF during WebSocket handshake".to_string());
            }
            ws.buf.extend_from_slice(&tmp[..n]);
        }

        Ok(ws)
    }

    #[cfg(target_os = "macos")]
    fn tls_write_all(&mut self, data: &[u8]) -> Result<(), String> {
        let mut off = 0;
        while off < data.len() {
            let mut processed = 0usize;
            let st = unsafe {
                SSLWrite(
                    self.ctx,
                    data[off..].as_ptr() as *const c_void,
                    data.len() - off,
                    &mut processed,
                )
            };
            if st != 0 {
                return Err(format!("SSLWrite failed: {}", st));
            }
            off += processed;
        }
        Ok(())
    }

    #[cfg(target_os = "macos")]
    fn tls_read(&mut self, out: &mut [u8]) -> Result<usize, String> {
        let mut processed = 0usize;
        let st = unsafe { SSLRead(self.ctx, out.as_mut_ptr() as *mut c_void, out.len(), &mut processed) };
        if st == 0 || processed > 0 {
            Ok(processed)
        } else {
            Err(format!("SSLRead failed: {}", st))
        }
    }

    #[cfg(target_os = "linux")]
    fn tls_write_all(&mut self, data: &[u8]) -> Result<(), String> { self.tls.write_all(data) }
    #[cfg(target_os = "linux")]
    fn tls_read(&mut self, out: &mut [u8]) -> Result<usize, String> { self.tls.read(out) }

    fn ensure_bytes(&mut self, n: usize) -> Result<(), String> {
        while self.buf.len() < n {
            let mut tmp = [0u8; 8192];
            let k = self.tls_read(&mut tmp)?;
            if k == 0 {
                return Err("WebSocket EOF".to_string());
            }
            self.buf.extend_from_slice(&tmp[..k]);
        }
        Ok(())
    }

    fn send_binary(&mut self, payload: &[u8]) -> Result<(), String> {
        self.send_frame(0x2, payload)
    }

    fn send_frame(&mut self, opcode: u8, payload: &[u8]) -> Result<(), String> {
        let mask = random_bytes(4);
        let n = payload.len();
        let mut frame = Vec::with_capacity(14 + n);
        frame.push(0x80 | opcode);
        if n < 126 {
            frame.push(0x80 | (n as u8));
        } else if n < 65536 {
            frame.push(0x80 | 126);
            frame.extend_from_slice(&(n as u16).to_be_bytes());
        } else {
            frame.push(0x80 | 127);
            frame.extend_from_slice(&(n as u64).to_be_bytes());
        }
        frame.extend_from_slice(&mask);
        for (i, &b) in payload.iter().enumerate() {
            frame.push(b ^ mask[i & 3]);
        }
        self.tls_write_all(&frame)
    }

    fn recv_frame(&mut self) -> Result<(u8, Vec<u8>), String> {
        loop {
            self.ensure_bytes(2)?;
            let b0 = self.buf[0];
            let b1 = self.buf[1];
            let op = b0 & 0x0F;
            let masked = (b1 & 0x80) != 0;
            let mut len = (b1 & 0x7F) as usize;
            let mut idx = 2usize;
            if len == 126 {
                self.ensure_bytes(idx + 2)?;
                len = u16::from_be_bytes([self.buf[idx], self.buf[idx + 1]]) as usize;
                idx += 2;
            } else if len == 127 {
                self.ensure_bytes(idx + 8)?;
                let mut arr = [0u8; 8];
                arr.copy_from_slice(&self.buf[idx..idx + 8]);
                len = u64::from_be_bytes(arr) as usize;
                idx += 8;
            }
            let mut mask = [0u8; 4];
            if masked {
                self.ensure_bytes(idx + 4)?;
                mask.copy_from_slice(&self.buf[idx..idx + 4]);
                idx += 4;
            }
            self.ensure_bytes(idx + len)?;
            let mut payload = self.buf[idx..idx + len].to_vec();
            self.buf.drain(..idx + len);
            if masked {
                for (i, b) in payload.iter_mut().enumerate() {
                    *b ^= mask[i & 3];
                }
            }
            if op == 9 {
                self.send_frame(0xA, &payload)?;
                continue;
            }
            return Ok((op, payload));
        }
    }
}

#[cfg(target_os = "macos")]
impl Drop for TlsWebSocket {
    fn drop(&mut self) {
        unsafe {
            SSLClose(self.ctx);
            CFRelease(self.ctx as *const c_void);
        }
    }
}

fn base64_encode(input: &[u8]) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[((n >> 18) & 0x3F) as usize] as char);
        out.push(TABLE[((n >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 {
            out.push(TABLE[((n >> 6) & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(TABLE[(n & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

// ============================================================================
// 3. Minimal Protobuf Wire Codec
// ============================================================================

pub fn pb_varint(mut n: u64) -> Vec<u8> {
    let mut out = Vec::new();
    while n >= 0x80 {
        out.push(((n & 0x7F) as u8) | 0x80);
        n >>= 7;
    }
    out.push(n as u8);
    out
}

pub fn pb_uint(field: u32, val: u64) -> Vec<u8> {
    if val == 0 {
        return Vec::new();
    }
    pb_uint_always(field, val)
}

pub fn pb_uint_always(field: u32, val: u64) -> Vec<u8> {
    let mut out = pb_varint(((field as u64) << 3) | 0);
    out.extend_from_slice(&pb_varint(val));
    out
}

pub fn pb_bytes(field: u32, data: &[u8]) -> Vec<u8> {
    let mut out = pb_varint(((field as u64) << 3) | 2);
    out.extend_from_slice(&pb_varint(data.len() as u64));
    out.extend_from_slice(data);
    out
}

pub fn pb_str(field: u32, s: &str) -> Vec<u8> {
    pb_bytes(field, s.as_bytes())
}

pub enum PbVal {
    Varint(u64),
    Bytes(Vec<u8>),
}

pub fn pb_parse(buf: &[u8]) -> Vec<(u32, PbVal)> {
    let mut i = 0usize;
    let mut out = Vec::new();
    let read_varint = |idx: &mut usize| -> Option<u64> {
        let mut r = 0u64;
        let mut s = 0u32;
        while *idx < buf.len() {
            let b = buf[*idx];
            *idx += 1;
            r |= ((b & 0x7F) as u64) << s;
            if (b & 0x80) == 0 {
                return Some(r);
            }
            s += 7;
        }
        None
    };
    while i < buf.len() {
        let Some(tag) = read_varint(&mut i) else { break };
        let field = (tag >> 3) as u32;
        let wire = (tag & 7) as u32;
        if wire == 0 {
            let Some(v) = read_varint(&mut i) else { break };
            out.push((field, PbVal::Varint(v)));
        } else if wire == 2 {
            let Some(len) = read_varint(&mut i) else { break };
            let len = len as usize;
            if i + len > buf.len() {
                break;
            }
            out.push((field, PbVal::Bytes(buf[i..i + len].to_vec())));
            i += len;
        } else {
            break;
        }
    }
    out
}

// ============================================================================
// 4. SEC 2 secp128r1 ECDH in Native Rust u128
// ============================================================================

const SECP128R1_P: u128 = 0xFFFFFFFD_FFFFFFFF_FFFFFFFF_FFFFFFFF;
const SECP128R1_A: u128 = 0xFFFFFFFD_FFFFFFFF_FFFFFFFF_FFFFFFFC;
const SECP128R1_GX: u128 = 0x161FF752_8B899B2D_0C28607C_A52C5B86;
const SECP128R1_GY: u128 = 0xCF5AC839_5BAFEB13_C02DA292_DDED7A83;
const TWO128_MOD_P: u128 = 0x00000002_00000000_00000000_00000001; // 2^128 - p

fn mod_add(x: u128, y: u128) -> u128 {
    let (s, c1) = x.overflowing_add(y);
    if c1 {
        let (s2, c2) = s.overflowing_add(TWO128_MOD_P);
        if c2 {
            s2.wrapping_add(TWO128_MOD_P)
        } else if s2 >= SECP128R1_P {
            s2 - SECP128R1_P
        } else {
            s2
        }
    } else if s >= SECP128R1_P {
        s - SECP128R1_P
    } else {
        s
    }
}

fn mod_sub(x: u128, y: u128) -> u128 {
    if x >= y {
        x - y
    } else {
        SECP128R1_P - (y - x)
    }
}

fn mod_mul(x: u128, mut y: u128) -> u128 {
    let mut res = 0u128;
    let mut base = x % SECP128R1_P;
    while y > 0 {
        if (y & 1) == 1 {
            res = mod_add(res, base);
        }
        base = mod_add(base, base);
        y >>= 1;
    }
    res
}

fn mod_inv(x: u128) -> u128 {
    let mut res = 1u128;
    let mut base = x % SECP128R1_P;
    let mut exp = SECP128R1_P - 2;
    while exp > 0 {
        if (exp & 1) == 1 {
            res = mod_mul(res, base);
        }
        base = mod_mul(base, base);
        exp >>= 1;
    }
    res
}

fn ec_add(p1: Option<(u128, u128)>, p2: Option<(u128, u128)>) -> Option<(u128, u128)> {
    match (p1, p2) {
        (None, q) => q,
        (p, None) => p,
        (Some((x1, y1)), Some((x2, y2))) => {
            if x1 == x2 && mod_add(y1, y2) == 0 {
                return None;
            }
            let lam = if x1 == x2 && y1 == y2 {
                let num = mod_add(mod_mul(3, mod_mul(x1, x1)), SECP128R1_A);
                let den = mod_inv(mod_add(y1, y1));
                mod_mul(num, den)
            } else {
                let num = mod_sub(y2, y1);
                let den = mod_inv(mod_sub(x2, x1));
                mod_mul(num, den)
            };
            let x3 = mod_sub(mod_sub(mod_mul(lam, lam), x1), x2);
            let y3 = mod_sub(mod_mul(lam, mod_sub(x1, x3)), y1);
            Some((x3, y3))
        }
    }
}

fn ec_mul(mut k: u128, pt: (u128, u128)) -> (u128, u128) {
    let mut res = None;
    let mut cur = Some(pt);
    while k > 0 {
        if (k & 1) == 1 {
            res = ec_add(res, cur);
        }
        cur = ec_add(cur, cur);
        k >>= 1;
    }
    res.unwrap()
}

// ============================================================================
// 5. Snappy & TROpusTool #!OPUS_RAW_V1 Helpers
// ============================================================================

fn snappy_compress(data: &[u8]) -> Vec<u8> {
    let mut out = pb_varint(data.len() as u64);
    for chunk in data.chunks(65536) {
        let ln = chunk.len() - 1;
        if ln < 60 {
            out.push((ln as u8) << 2);
        } else if ln < 256 {
            out.push(60 << 2);
            out.push(ln as u8);
        } else {
            out.push(61 << 2);
            out.push((ln & 0xFF) as u8);
            out.push(((ln >> 8) & 0xFF) as u8);
        }
        out.extend_from_slice(chunk);
    }
    out
}

fn snappy_decompress(data: &[u8]) -> Vec<u8> {
    let mut i = 0usize;
    while i < data.len() {
        let b = data[i];
        i += 1;
        if (b & 0x80) == 0 {
            break;
        }
    }
    let mut out = Vec::new();
    while i < data.len() {
        let tag = data[i] as usize;
        i += 1;
        let t = tag & 3;
        if t == 0 {
            let mut len = tag >> 2;
            if len >= 60 {
                let nb = len - 59;
                len = 0;
                for k in 0..nb {
                    len |= (data[i + k] as usize) << (8 * k);
                }
                i += nb;
            }
            len += 1;
            out.extend_from_slice(&data[i..i + len]);
            i += len;
        } else {
            let (len, off) = if t == 1 {
                let l = ((tag >> 2) & 7) + 4;
                let o = ((tag >> 5) << 8) | (data[i] as usize);
                i += 1;
                (l, o)
            } else if t == 2 {
                let l = (tag >> 2) + 1;
                let o = (data[i] as usize) | ((data[i + 1] as usize) << 8);
                i += 2;
                (l, o)
            } else {
                let l = (tag >> 2) + 1;
                let o = (data[i] as usize)
                    | ((data[i + 1] as usize) << 8)
                    | ((data[i + 2] as usize) << 16)
                    | ((data[i + 3] as usize) << 24);
                i += 4;
                (l, o)
            };
            for _ in 0..len {
                let b = out[out.len() - off];
                out.push(b);
            }
        }
    }
    out
}

#[cfg(target_os = "macos")]
fn encode_wetype_opus_chunks(pcm: &[u8], frames_per_chunk: usize) -> Result<Vec<Vec<u8>>, String> {
    let pid = std::process::id();
    let in_wav = PathBuf::from(format!("/tmp/wetype_rs_in_{}.wav", pid));
    let out_caf = PathBuf::from(format!("/tmp/wetype_rs_out_{}.caf", pid));

    let mut wav = Vec::with_capacity(44 + pcm.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&((36 + pcm.len()) as u32).to_le_bytes());
    wav.extend_from_slice(b"WAVEfmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&16000u32.to_le_bytes());
    wav.extend_from_slice(&32000u32.to_le_bytes());
    wav.extend_from_slice(&2u16.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&(pcm.len() as u32).to_le_bytes());
    wav.extend_from_slice(pcm);
    fs::write(&in_wav, &wav).map_err(|e| e.to_string())?;

    let status = Command::new("/usr/bin/afconvert")
        .args(["-f", "caff", "-d", "opus@16000", "-b", "64000"])
        .arg(&in_wav)
        .arg(&out_caf)
        .status()
        .map_err(|e| e.to_string())?;
    let _ = fs::remove_file(&in_wav);
    if !status.success() {
        return Err("afconvert opus failed".to_string());
    }
    let caf = fs::read(&out_caf).map_err(|e| e.to_string())?;
    let _ = fs::remove_file(&out_caf);

    let mut pos = 8usize;
    let mut pakt = &[][..];
    let mut data_chunk = &[][..];
    while pos + 12 <= caf.len() {
        let ctype = &caf[pos..pos + 4];
        let mut len_bytes = [0u8; 8];
        len_bytes.copy_from_slice(&caf[pos + 4..pos + 12]);
        let clen = i64::from_be_bytes(len_bytes) as usize;
        pos += 12;
        if ctype == b"pakt" {
            pakt = &caf[pos..pos + clen];
        } else if ctype == b"data" {
            data_chunk = &caf[pos + 4..pos + clen];
        }
        pos += clen;
    }

    let mut np_bytes = [0u8; 8];
    np_bytes.copy_from_slice(&pakt[0..8]);
    let num_pkts = i64::from_be_bytes(np_bytes) as usize;
    let mut idx = 24usize;
    let mut pkt_sizes = Vec::with_capacity(num_pkts);
    for _ in 0..num_pkts {
        let mut v = 0usize;
        loop {
            let b = pakt[idx];
            idx += 1;
            v = (v << 7) | ((b & 0x7F) as usize);
            if (b & 0x80) == 0 {
                break;
            }
        }
        pkt_sizes.push(v);
    }

    let mut chunks = Vec::new();
    let mut cur = b"#!OPUS_RAW_V1\x02\x01\x00".to_vec();
    let mut f_count = 0usize;
    let mut doff = 0usize;
    for sz in pkt_sizes {
        let pkt = &data_chunk[doff..doff + sz];
        doff += sz;
        cur.extend_from_slice(&(pkt.len() as u16).to_le_bytes());
        cur.extend_from_slice(pkt);
        f_count += 1;
        if f_count == frames_per_chunk {
            chunks.push(cur);
            cur = Vec::new();
            f_count = 0;
        }
    }
    if !cur.is_empty() {
        chunks.push(cur);
    }
    Ok(chunks)
}

#[cfg(target_os = "linux")]
fn encode_wetype_opus_chunks(pcm: &[u8], frames_per_chunk: usize) -> Result<Vec<Vec<u8>>, String> {
    linux::encode_opus(pcm, frames_per_chunk)
}

fn rand_lower(len: usize) -> String {
    random_bytes(len)
        .into_iter()
        .map(|b| (b'a' + (b % 26)) as char)
        .collect()
}

fn rand_digits(len: usize) -> String {
    random_bytes(len)
        .into_iter()
        .map(|b| (b'0' + (b % 10)) as char)
        .collect()
}

fn rand_hex(len: usize) -> String {
    const HEX: &[u8] = b"0123456789abcdef";
    random_bytes(len)
        .into_iter()
        .map(|b| HEX[(b & 0x0F) as usize] as char)
        .collect()
}

fn now_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
}

// ============================================================================
// 6. Provider 1: WeType (WeChat IME) Streaming ASR
// ============================================================================

const WETYPE_HOST: &str = "wetype.weixin.qq.com";
const WETYPE_SIGN_KEY: &str = "zN7rB3bL4pO8jW1o";
const WETYPE_HS_KEY: &str = "D4Y5U3Y2M0C0T7N4P1P7O2N6E1I2Y1U6";
const WETYPE_VERSION: &str = "3.0.0(670)";

fn wetype_send_req(ws: &mut TlsWebSocket, tid: u32, path: &str, headers: &[(&str, String)], body: &[u8]) -> Result<(), String> {
    let mut http_req = Vec::new();
    http_req.extend_from_slice(&pb_str(1, "POST"));
    http_req.extend_from_slice(&pb_str(3, path));
    http_req.extend_from_slice(&pb_str(4, ""));
    for (k, v) in headers {
        let mut item = pb_str(1, k);
        item.extend_from_slice(&pb_str(2, v));
        http_req.extend_from_slice(&pb_bytes(5, &item));
    }
    http_req.extend_from_slice(&pb_bytes(6, body));

    let mut env = pb_uint_always(1, 0);
    env.extend_from_slice(&pb_uint_always(2, 0));
    env.extend_from_slice(&pb_uint_always(3, tid as u64));
    env.extend_from_slice(&pb_bytes(5, &http_req));
    ws.send_binary(&env)
}

fn wetype_recv_rsp(ws: &mut TlsWebSocket, expected_tid: Option<u32>) -> Result<(u32, i32, String, Vec<u8>), String> {
    loop {
        let (op, pay) = ws.recv_frame()?;
        if op != 2 {
            continue;
        }
        let mut seq = 0u32;
        let mut http_rsp = Vec::new();
        for (f, val) in pb_parse(&pay) {
            match (f, val) {
                (2, PbVal::Varint(v)) => seq = v as u32,
                (4, PbVal::Bytes(b)) => http_rsp = b,
                _ => {}
            }
        }
        if seq == 0 {
            continue;
        }
        let mut status = 0i32;
        let mut comp_type = "1".to_string();
        let mut body = Vec::new();
        for (rf, rval) in pb_parse(&http_rsp) {
            match (rf, rval) {
                (2, PbVal::Varint(v)) => status = v as i32,
                (4, PbVal::Bytes(b)) => {
                    let mut k = String::new();
                    let mut v = String::new();
                    for (hf, hval) in pb_parse(&b) {
                        if hf == 1 {
                            if let PbVal::Bytes(kb) = hval {
                                k = String::from_utf8_lossy(&kb).to_lowercase();
                            }
                        } else if hf == 2 {
                            if let PbVal::Bytes(vb) = hval {
                                v = String::from_utf8_lossy(&vb).to_string();
                            }
                        }
                    }
                    if k == "kb-compressiontype" {
                        comp_type = v;
                    }
                }
                (5, PbVal::Bytes(b)) => body = b,
                _ => {}
            }
        }
        if expected_tid.is_none() || expected_tid == Some(seq) {
            return Ok((seq, status, comp_type, body));
        }
    }
}

pub fn transcribe_wetype(pcm: &[u8], mut on_partial: Option<&mut dyn FnMut(&str)>) -> Result<String, String> {
    let chunks = encode_wetype_opus_chunks(pcm, 5)?;
    if chunks.is_empty() {
        return Ok(String::new());
    }
    let mut ws = TlsWebSocket::connect(WETYPE_HOST, "/", &[("Sec-WebSocket-Protocol", "wxws_pb")])?;

    // 1. /oauth_pubkey_v2 (secp128r1 ECDH)
    let mut priv_bytes = [0u8; 16];
    priv_bytes[1..].copy_from_slice(&random_bytes(15));
    let priv_key = u128::from_be_bytes(priv_bytes).max(2);
    let (pub_x, pub_y) = ec_mul(priv_key, (SECP128R1_GX, SECP128R1_GY));
    let client_pub_hex = format!("04{:032X}{:032X}", pub_x, pub_y);
    let dev_name = "Mac17,8";
    let prefix32 = format!("MAC{:0>17}{}", dev_name, rand_lower(12));
    let dev_code = format!("{}{}", prefix32, md5_upper(format!("{}{}", prefix32, WETYPE_SIGN_KEY).as_bytes()));

    let mut ecdh_req = Vec::new();
    ecdh_req.extend_from_slice(&pb_str(1, &client_pub_hex));
    ecdh_req.extend_from_slice(&pb_str(2, ""));
    ecdh_req.extend_from_slice(&pb_uint(3, 1));
    ecdh_req.extend_from_slice(&pb_str(4, &dev_code));
    ecdh_req.extend_from_slice(&pb_str(7, ""));
    ecdh_req.extend_from_slice(&pb_str(8, dev_name));
    ecdh_req.extend_from_slice(&pb_str(9, ""));

    let enc1 = aes256_ecb_encrypt(WETYPE_HS_KEY, &ecdh_req)?;
    let ts1 = now_ms().to_string();
    let tr1 = rand_lower(16);
    let md5_1 = md5_upper(&enc1);
    let tid1 = 2147483646u32;
    let sign1 = sha256_upper(
        format!("5{}2{}{}{}{}{}", WETYPE_VERSION, ts1, md5_1, tr1, tid1, WETYPE_SIGN_KEY).as_bytes(),
    );

    wetype_send_req(
        &mut ws,
        tid1,
        "/oauth_pubkey_v2",
        &[
            ("Kb-Uin", "0".into()),
            ("Kb-DeviceCodeRestrictionV2", "1".into()),
            ("Kb-OsType", "5".into()),
            ("Kb-Version", WETYPE_VERSION.into()),
            ("Kb-SystemVersion", "27.0.0".into()),
            ("Kb-PackageType", "3".into()),
            ("Use_DebugNet", "0".into()),
            ("Kb-TimeStamp", ts1),
            ("Kb-BodyMd5", md5_1),
            ("Kb-TraceId", tr1),
            ("Kb-TaskId", tid1.to_string()),
            ("Kb-Scene", "2".into()),
            ("Kb-Sign", sign1),
            ("Content-Length", enc1.len().to_string()),
            ("Kb-CompressionType", "1".into()),
            ("Content-Type", "application/octet-stream".into()),
            ("HOST", WETYPE_HOST.into()),
        ],
        &enc1,
    )?;

    let (_, _, _, rbody1) = wetype_recv_rsp(&mut ws, Some(tid1))?;
    let dec1 = aes256_ecb_decrypt(WETYPE_HS_KEY, &rbody1)?;
    let mut svr_pub_hex = String::new();
    let mut gen_uin_token = String::new();
    for (f, val) in pb_parse(&dec1) {
        if f == 2 {
            if let PbVal::Bytes(b) = val {
                svr_pub_hex = String::from_utf8_lossy(&b).to_string();
            }
        } else if f == 4 {
            if let PbVal::Bytes(b) = val {
                gen_uin_token = String::from_utf8_lossy(&b).to_string();
            }
        }
    }
    let svr_x = u128::from_str_radix(&svr_pub_hex[2..34], 16).map_err(|e| e.to_string())?;
    let svr_y = u128::from_str_radix(&svr_pub_hex[34..66], 16).map_err(|e| e.to_string())?;
    let (shared_x, _) = ec_mul(priv_key, (svr_x, svr_y));
    let aes_key = format!("{:032X}", shared_x);

    // 2. /gen_uin_v2
    let mut uin_req = Vec::new();
    uin_req.extend_from_slice(&pb_str(1, &dev_code));
    uin_req.extend_from_slice(&pb_str(2, &svr_pub_hex));
    uin_req.extend_from_slice(&pb_str(4, &rand_hex(32)));
    uin_req.extend_from_slice(&pb_str(5, ""));

    let enc2 = aes256_ecb_encrypt(&aes_key, &uin_req)?;
    let ts2 = now_ms().to_string();
    let tr2 = rand_lower(16);
    let md5_2 = md5_upper(&enc2);
    let tid2 = 2147483645u32;
    let sign2 = sha256_upper(
        format!(
            "5{}2{}{}{}{}{}{}",
            WETYPE_VERSION, ts2, md5_2, gen_uin_token, tr2, tid2, WETYPE_SIGN_KEY
        )
        .as_bytes(),
    );

    wetype_send_req(
        &mut ws,
        tid2,
        "/gen_uin_v2",
        &[
            ("Kb-GenUinToken", gen_uin_token),
            ("Kb-DeviceCodeRestrictionV2", "1".into()),
            ("Kb-OsType", "5".into()),
            ("Kb-Version", WETYPE_VERSION.into()),
            ("Kb-SystemVersion", "27.0.0".into()),
            ("Kb-PackageType", "3".into()),
            ("Use_DebugNet", "0".into()),
            ("Kb-TimeStamp", ts2),
            ("Kb-BodyMd5", md5_2),
            ("Kb-TraceId", tr2),
            ("Kb-TaskId", tid2.to_string()),
            ("Kb-Scene", "2".into()),
            ("Kb-Sign", sign2),
            ("Content-Length", enc2.len().to_string()),
            ("Kb-CompressionType", "1".into()),
            ("Content-Type", "application/octet-stream".into()),
            ("HOST", WETYPE_HOST.into()),
        ],
        &enc2,
    )?;

    let (_, _, _, rbody2) = wetype_recv_rsp(&mut ws, Some(tid2))?;
    let dec2 = aes256_ecb_decrypt(&aes_key, &rbody2)?;
    let mut uin = String::new();
    for (f, val) in pb_parse(&dec2) {
        if f == 2 {
            if let PbVal::Varint(v) = val {
                uin = v.to_string();
            }
        }
    }

    // 3. Stream voice chunks (/api_v2)
    let voice_id = rand_digits(25);
    let mut total_offset = 0u64;

    let send_voice = |ws: &mut TlsWebSocket, tid: u32, inner: &[u8]| -> Result<(), String> {
        let payload = pb_bytes(1, inner);
        let (raw_body, comp_type) = if payload.len() >= 301 {
            (snappy_compress(&payload), "2")
        } else {
            (payload, "1")
        };
        let enc = aes256_ecb_encrypt(&aes_key, &raw_body)?;
        let ts = now_ms().to_string();
        let tr = rand_lower(16);
        let md5 = md5_upper(&enc);
        let sign = sha256_upper(
            format!(
                "5{}245480{}{}{}{}{}{}",
                WETYPE_VERSION, ts, md5, uin, tr, tid, WETYPE_SIGN_KEY
            )
            .as_bytes(),
        );
        wetype_send_req(
            ws,
            tid,
            "/api_v2",
            &[
                ("Kb-Uin", uin.clone()),
                ("Kb-SharedKeySuffix", aes_key[28..].to_string()),
                ("Kb-CmdId", "4548".into()),
                ("Kb-SubCmdId", "0".into()),
                ("Kb-OsType", "5".into()),
                ("Kb-Version", WETYPE_VERSION.into()),
                ("Kb-SystemVersion", "27.0.0".into()),
                ("Kb-PackageType", "3".into()),
                ("Use_DebugNet", "0".into()),
                ("Kb-TimeStamp", ts),
                ("Kb-BodyMd5", md5),
                ("Kb-TraceId", tr),
                ("Kb-TaskId", tid.to_string()),
                ("Kb-Scene", "2".into()),
                ("Kb-Sign", sign),
                ("Content-Length", enc.len().to_string()),
                ("Kb-CompressionType", comp_type.into()),
                ("Content-Type", "application/octet-stream".into()),
                ("HOST", WETYPE_HOST.into()),
            ],
            &enc,
        )
    };

    for (i, audio) in chunks.iter().enumerate() {
        total_offset += audio.len() as u64;
        let seq = (i + 1) as u32;
        let is_end = seq == chunks.len() as u32;
        let mut inner = Vec::new();
        inner.extend_from_slice(&pb_str(2, &voice_id));
        inner.extend_from_slice(&pb_bytes(4, audio));
        inner.extend_from_slice(&pb_uint(5, 5));
        if is_end {
            inner.extend_from_slice(&pb_uint(6, 1));
        }
        inner.extend_from_slice(&pb_uint(7, seq as u64));
        inner.extend_from_slice(&pb_uint(11, total_offset));
        inner.extend_from_slice(&pb_uint(24, 1));
        send_voice(&mut ws, seq, &inner)?;
    }

    let mut last_text = String::new();
    let mut end_flag = 0u64;

    let mut decode_rsp = |comp_type: &str, rbody: &[u8]| -> Result<u64, String> {
        if rbody.is_empty() {
            return Ok(0);
        }
        let mut dec = aes256_ecb_decrypt(&aes_key, rbody)?;
        if comp_type == "2" {
            dec = snappy_decompress(&dec);
        }
        let outer = pb_parse(&dec);
        let mut ef = 0u64;
        if let Some((_, PbVal::Bytes(inner_bytes))) = outer.into_iter().next() {
            let mut f4 = String::new();
            let mut f14 = String::new();
            for (f, val) in pb_parse(&inner_bytes) {
                match (f, val) {
                    (4, PbVal::Bytes(b)) => f4 = String::from_utf8_lossy(&b).to_string(),
                    (5, PbVal::Varint(v)) => ef = v,
                    (14, PbVal::Bytes(b)) => f14 = String::from_utf8_lossy(&b).to_string(),
                    _ => {}
                }
            }
            let txt = if !f14.is_empty() { f14 } else { f4 };
            if !txt.is_empty() && txt != last_text {
                last_text = txt;
                if let Some(cb) = on_partial.as_deref_mut() {
                    cb(&last_text);
                }
            }
        }
        Ok(ef)
    };

    for _ in 0..chunks.len() {
        let (_, _, comp_type, rbody) = wetype_recv_rsp(&mut ws, None)?;
        if decode_rsp(&comp_type, &rbody)? == 1 {
            end_flag = 1;
        }
    }

    let mut poll_tid = (chunks.len() + 1) as u32;
    while end_flag != 1 && poll_tid <= (chunks.len() + 25) as u32 {
        std::thread::sleep(Duration::from_millis(100));
        let mut poll_inner = Vec::new();
        poll_inner.extend_from_slice(&pb_str(2, &voice_id));
        poll_inner.extend_from_slice(&pb_uint(5, 5));
        poll_inner.extend_from_slice(&pb_uint(6, 1));
        poll_inner.extend_from_slice(&pb_uint(11, total_offset));
        poll_inner.extend_from_slice(&pb_uint(24, 1));
        send_voice(&mut ws, poll_tid, &poll_inner)?;
        let (_, _, comp_type, rbody) = wetype_recv_rsp(&mut ws, Some(poll_tid))?;
        poll_tid += 1;
        if decode_rsp(&comp_type, &rbody)? == 1 {
            end_flag = 1;
        }
    }

    Ok(last_text)
}

// ============================================================================
// 7. Provider 2: Doubao Input Method Streaming ASR
// ============================================================================

fn build_doubao_req(event: &str, task_id: &str, payload: &str, data: &[u8], seq_id: u64) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&pb_str(2, "OrnqKvSSrs"));
    out.extend_from_slice(&pb_str(3, "ASR"));
    out.extend_from_slice(&pb_str(5, event));
    if !payload.is_empty() {
        out.extend_from_slice(&pb_str(6, payload));
    }
    if !data.is_empty() {
        out.extend_from_slice(&pb_bytes(7, data));
    }
    out.extend_from_slice(&pb_str(8, task_id));
    if seq_id > 0 {
        out.extend_from_slice(&pb_uint(9, seq_id));
    }
    out
}

pub fn transcribe_doubao(pcm: &[u8], mut on_partial: Option<&mut dyn FnMut(&str)>) -> Result<String, String> {
    let device_id = format!("7{}", rand_digits(15));
    let task_id = rand_hex(32);
    let path = format!(
        "/ocean/api/v1/ws?aid=685343&device_id={}&app_name=oime_macos&channel=release&device_platform=mac&device_type=mac&device_brand=Apple&os=macOS&os_version=15.6.0&version_code=1.0.2&version_name=1.0.2&update_version_code=1&build_number=1.0.2&app_version=1.0.2",
        device_id
    );
    let ek = format!("{}+W", device_id);
    let mut ws = TlsWebSocket::connect(
        "frontier-audio-ime-ws.doubao.com",
        &path,
        &[
            ("proto-version", "v2"),
            ("sdk-version", "2"),
            ("x-tt-token", ""),
            ("x-tt-e-k", &ek),
            ("x-custom-keepalive", "true"),
        ],
    )?;

    ws.send_binary(&build_doubao_req("StartTask", &task_id, "", &[], 0))?;
    let start_payload = format!(
        r#"{{"audio_info":{{"channel":1,"format":"pcm","sample_rate":16000}},"enable_punctuation":true,"enable_speech_rejection":false,"extra":{{"app_name":"oime_macos","app_version":"1.0.2","cell_compress_rate":8,"device_brand":"Apple","device_id":"{}","device_model":"Mac","disable_user_words":false,"enable_asr_format":true,"enable_asr_threepass":true,"enable_asr_twopass":true,"enable_print_chinese":true,"enable_text_filter":true,"finish_wait_offline_time":1000,"format_space_at_newline":false,"input_mode":"wave","join_user_experience_improve_program":false,"max_wait_switch_offline_time":4000,"offline_wait_online_interval_time":200,"offline_wait_online_time":1000,"os":"macOS","os_version":"15.6.0","remove_space_between_han_eng":false,"remove_space_between_han_num":true,"retry_server_code":[],"strong_ddc":true,"use_twopass_retry":true}}}}"#,
        device_id
    );
    ws.send_binary(&build_doubao_req("StartSession", &task_id, &start_payload, &[], 0))?;

    for (i, chunk) in pcm.chunks(3200).enumerate() {
        let seq = (i + 1) as u64;
        let payload = format!(r#"{{"timestamp_ms":{}}}"#, now_ms());
        ws.send_binary(&build_doubao_req("TaskRequest", &task_id, &payload, chunk, seq))?;
    }
    ws.send_binary(&build_doubao_req("FinishSession", &task_id, "", &[], 0))?;

    let mut final_text = String::new();
    let mut last_partial = String::new();
    loop {
        let (op, pay) = ws.recv_frame()?;
        if op != 2 {
            continue;
        }
        let mut event = String::new();
        let mut json_str = String::new();
        for (f, val) in pb_parse(&pay) {
            if f == 4 {
                if let PbVal::Bytes(b) = val {
                    event = String::from_utf8_lossy(&b).to_string();
                }
            } else if f == 7 {
                if let PbVal::Bytes(b) = val {
                    json_str = String::from_utf8_lossy(&b).to_string();
                }
            }
        }
        if event == "SessionFinished" || event == "TaskFinished" {
            break;
        }
        if event == "SessionFailed" || event == "TaskFailed" {
            return Err(format!("Doubao ASR error: {}", event));
        }
        if let Some(txt) = extract_first_json_text(&json_str) {
            if json_str.contains(r#""is_interim":false"#) || json_str.contains(r#""is_vad_finished":true"#) {
                final_text = txt;
            } else if !txt.is_empty() && txt != last_partial {
                last_partial = txt;
                if let Some(cb) = on_partial.as_deref_mut() {
                    cb(&last_partial);
                }
            }
        }
    }
    let _ = ws.send_binary(&build_doubao_req("FinishTask", &task_id, "", &[], 0));
    Ok(if !final_text.is_empty() { final_text } else { last_partial })
}

fn extract_first_json_text(json: &str) -> Option<String> {
    let marker = r#""text":""#;
    let start = json.find(marker)? + marker.len();
    let rest = &json[start..];
    let mut out = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        if c == '"' {
            return Some(out);
        } else if c == '\\' {
            if let Some(esc) = chars.next() {
                out.push(esc);
            }
        } else {
            out.push(c);
        }
    }
    None
}

pub fn transcribe(pcm: &[u8], provider: Provider, on_partial: Option<&mut dyn FnMut(&str)>) -> Result<String, String> {
    match provider {
        Provider::WeType => transcribe_wetype(pcm, on_partial),
        Provider::Doubao => transcribe_doubao(pcm, on_partial),
    }
}
