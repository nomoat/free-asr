//! System OpenSSL ABI (1.1.1/3.x) and FFmpeg; no crates.io dependencies.
use std::ffi::{c_char, c_int, c_long, c_void, CString};
use std::io::{Read, Write};
use std::net::TcpStream;
use std::os::unix::io::AsRawFd;
use std::process::{Command, Stdio};
use std::ptr;

#[link(name = "crypto")]
extern "C" {
    fn MD5(data: *const u8, len: usize, out: *mut u8) -> *mut u8;
    fn SHA256(data: *const u8, len: usize, out: *mut u8) -> *mut u8;
    fn EVP_CIPHER_CTX_new() -> *mut c_void;
    fn EVP_CIPHER_CTX_free(ctx: *mut c_void);
    fn EVP_aes_256_ecb() -> *const c_void;
    fn EVP_CipherInit_ex(ctx: *mut c_void, cipher: *const c_void, engine: *mut c_void, key: *const u8, iv: *const u8, encrypt: c_int) -> c_int;
    fn EVP_CipherUpdate(ctx: *mut c_void, out: *mut u8, out_len: *mut c_int, data: *const u8, len: c_int) -> c_int;
    fn EVP_CipherFinal_ex(ctx: *mut c_void, out: *mut u8, out_len: *mut c_int) -> c_int;
}
#[link(name = "ssl")]
extern "C" {
    fn TLS_client_method() -> *const c_void;
    fn SSL_CTX_new(method: *const c_void) -> *mut c_void;
    fn SSL_CTX_free(ctx: *mut c_void);
    fn SSL_CTX_set_default_verify_paths(ctx: *mut c_void) -> c_int;
    fn SSL_CTX_set_verify(ctx: *mut c_void, mode: c_int, callback: Option<unsafe extern "C" fn(c_int, *mut c_void) -> c_int>);
    fn SSL_new(ctx: *mut c_void) -> *mut c_void;
    fn SSL_free(ssl: *mut c_void);
    fn SSL_set_fd(ssl: *mut c_void, fd: c_int) -> c_int;
    fn SSL_set1_host(ssl: *mut c_void, hostname: *const c_char) -> c_int;
    fn SSL_ctrl(ssl: *mut c_void, cmd: c_int, larg: c_long, parg: *mut c_void) -> c_long;
    fn SSL_connect(ssl: *mut c_void) -> c_int;
    fn SSL_get_error(ssl: *const c_void, result: c_int) -> c_int;
    fn SSL_read(ssl: *mut c_void, data: *mut c_void, len: c_int) -> c_int;
    fn SSL_write(ssl: *mut c_void, data: *const c_void, len: c_int) -> c_int;
}

pub fn random_bytes(len: usize) -> Vec<u8> {
    let mut bytes = vec![0; len];
    std::fs::File::open("/dev/urandom").and_then(|mut file| file.read_exact(&mut bytes)).expect("OS random source unavailable");
    bytes
}
pub fn md5_upper(data: &[u8]) -> String {
    let mut out = [0; 16];
    unsafe { MD5(data.as_ptr(), data.len(), out.as_mut_ptr()); }
    out.iter().map(|b| format!("{b:02X}")).collect()
}
pub fn sha256_upper(data: &[u8]) -> String {
    let mut out = [0; 32];
    unsafe { SHA256(data.as_ptr(), data.len(), out.as_mut_ptr()); }
    out.iter().map(|b| format!("{b:02X}")).collect()
}
fn aes(key: &str, data: &[u8], encrypt: bool) -> Result<Vec<u8>, String> {
    if key.len() != 32 || data.len() > c_int::MAX as usize { return Err("Invalid AES key/input length".into()); }
    unsafe {
        let ctx = EVP_CIPHER_CTX_new();
        if ctx.is_null() { return Err("OpenSSL AES context allocation failed".into()); }
        let mut out = vec![0; data.len() + 32];
        let (mut len, mut final_len) = (0, 0);
        let ok = EVP_CipherInit_ex(ctx, EVP_aes_256_ecb(), ptr::null_mut(), key.as_ptr(), ptr::null(), encrypt as c_int) == 1
            && EVP_CipherUpdate(ctx, out.as_mut_ptr(), &mut len, data.as_ptr(), data.len() as c_int) == 1
            && EVP_CipherFinal_ex(ctx, out.as_mut_ptr().add(len as usize), &mut final_len) == 1;
        EVP_CIPHER_CTX_free(ctx);
        if !ok { return Err("OpenSSL AES failed (invalid key or padding)".into()); }
        out.truncate((len + final_len) as usize);
        Ok(out)
    }
}
pub fn aes256_ecb_encrypt(key: &str, data: &[u8]) -> Result<Vec<u8>, String> { aes(key, data, true) }
pub fn aes256_ecb_decrypt(key: &str, data: &[u8]) -> Result<Vec<u8>, String> {
    if data.is_empty() { return Ok(Vec::new()); }
    aes(key, data, false)
}

pub struct TlsStream { ctx: *mut c_void, ssl: *mut c_void }
impl TlsStream {
    pub fn connect(tcp: &TcpStream, host: &str) -> Result<Self, String> {
        let hostname = CString::new(host).map_err(|e| e.to_string())?;
        unsafe {
            let ctx = SSL_CTX_new(TLS_client_method());
            if ctx.is_null() { return Err("OpenSSL TLS context allocation failed".into()); }
            let mut stream = Self { ctx, ssl: ptr::null_mut() };
            SSL_CTX_set_verify(ctx, 1, None); // SSL_VERIFY_PEER, default verification callback.
            if SSL_CTX_set_default_verify_paths(ctx) != 1 { return Err("Cannot load system CA certificates".into()); }
            stream.ssl = SSL_new(ctx);
            if stream.ssl.is_null() { return Err("OpenSSL TLS allocation failed".into()); }
            if SSL_set_fd(stream.ssl, tcp.as_raw_fd()) != 1
                || SSL_set1_host(stream.ssl, hostname.as_ptr()) != 1
                || SSL_ctrl(stream.ssl, 55, 0, hostname.as_ptr() as *mut c_void) != 1 {
                return Err("OpenSSL hostname/SNI setup failed".into());
            }
            let status = SSL_connect(stream.ssl);
            if status != 1 { return Err(format!("TLS handshake/certificate validation failed ({})", SSL_get_error(stream.ssl, status))); }
            Ok(stream)
        }
    }
    pub fn read(&mut self, data: &mut [u8]) -> Result<usize, String> {
        let n = unsafe { SSL_read(self.ssl, data.as_mut_ptr() as *mut c_void, data.len().min(c_int::MAX as usize) as c_int) };
        if n > 0 { return Ok(n as usize); }
        let error = unsafe { SSL_get_error(self.ssl, n) };
        if error == 6 { return Ok(0); }
        Err(format!("TLS read failed ({error})"))
    }
    pub fn write_all(&mut self, mut data: &[u8]) -> Result<(), String> {
        while !data.is_empty() {
            let n = unsafe { SSL_write(self.ssl, data.as_ptr() as *const c_void, data.len().min(c_int::MAX as usize) as c_int) };
            if n <= 0 { return Err(format!("TLS write failed ({})", unsafe { SSL_get_error(self.ssl, n) })); }
            data = &data[n as usize..];
        }
        Ok(())
    }
}
impl Drop for TlsStream {
    fn drop(&mut self) { unsafe { if !self.ssl.is_null() { SSL_free(self.ssl); } SSL_CTX_free(self.ctx); } }
}

pub fn encode_opus(pcm: &[u8], frames_per_chunk: usize) -> Result<Vec<Vec<u8>>, String> {
    if frames_per_chunk == 0 { return Err("frames_per_chunk must be positive".into()); }
    if pcm.is_empty() { return Ok(Vec::new()); }
    let mut child = Command::new("ffmpeg").args(["-hide_banner", "-loglevel", "error", "-f", "s16le", "-ar", "16000", "-ac", "1", "-i", "pipe:0",
        "-c:a", "libopus", "-b:a", "64k", "-vbr", "off", "-application", "voip", "-frame_duration", "20", "-f", "opus", "pipe:1"])
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|e| format!("FFmpeg with libopus is required: {e}"))?;
    let mut stdin = child.stdin.take().unwrap();
    let input = pcm.to_vec();
    let writer = std::thread::spawn(move || stdin.write_all(&input));
    let output = child.wait_with_output().map_err(|e| e.to_string())?;
    writer.join().map_err(|_| "FFmpeg input writer panicked")?.map_err(|e| e.to_string())?;
    if !output.status.success() { return Err(format!("FFmpeg encoding failed: {}", String::from_utf8_lossy(&output.stderr))); }
    opus_chunks(&output.stdout, frames_per_chunk)
}
fn opus_chunks(ogg: &[u8], frames_per_chunk: usize) -> Result<Vec<Vec<u8>>, String> {
    let (mut at, mut packet, mut packets) = (0, Vec::new(), Vec::new());
    while at < ogg.len() {
        if at + 27 > ogg.len() || &ogg[at..at + 4] != b"OggS" { return Err("Invalid Ogg page".into()); }
        let count = ogg[at + 26] as usize;
        let table = at + 27;
        let mut offset = table + count;
        if offset > ogg.len() { return Err("Truncated Ogg page".into()); }
        for &size in &ogg[table..offset] {
            let size = size as usize;
            if offset + size > ogg.len() { return Err("Truncated Opus packet".into()); }
            packet.extend_from_slice(&ogg[offset..offset + size]); offset += size;
            if size < 255 {
                if !packet.starts_with(b"OpusHead") && !packet.starts_with(b"OpusTags") { packets.push(packet.clone()); }
                packet.clear();
            }
        }
        at = offset;
    }
    if !packet.is_empty() { return Err("Truncated Opus packet".into()); }
    let mut chunks = Vec::new();
    for (i, group) in packets.chunks(frames_per_chunk).enumerate() {
        let mut chunk = if i == 0 { b"#!OPUS_RAW_V1\x02\x01\x00".to_vec() } else { Vec::new() };
        for packet in group { chunk.extend_from_slice(&(packet.len() as u16).to_le_bytes()); chunk.extend_from_slice(packet); }
        chunks.push(chunk);
    }
    Ok(chunks)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn crypto_and_opus() {
        assert_eq!(md5_upper(b"abc"), "900150983CD24FB0D6963F7D28E17F72");
        assert_eq!(sha256_upper(b"abc"), "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD");
        let key = "0123456789ABCDEF0123456789ABCDEF";
        let ciphertext = aes256_ecb_encrypt(key, b"hello world").unwrap();
        assert_eq!(aes256_ecb_decrypt(key, &ciphertext).unwrap(), b"hello world");
        assert!(aes256_ecb_decrypt(key, &[0; 16]).is_err());
        let chunks = encode_opus(&vec![0; 32000], 5).unwrap();
        assert!(chunks[0].starts_with(b"#!OPUS_RAW_V1\x02\x01\x00"));
        assert!(chunks.len() >= 10);
        assert!(opus_chunks(b"OggS", 5).is_err());
    }
}
