use free_asr::{transcribe, Provider};
use std::env;
use std::fs;
use std::io::{self, Write};
use std::path::Path;
use std::process::Command;

fn load_pcm_16k_mono(path: &Path) -> Result<Vec<u8>, String> {
    let raw = fs::read(path).map_err(|e| e.to_string())?;
    if raw.len() >= 44 && &raw[0..4] == b"RIFF" {
        if let Some(pos) = raw.windows(4).position(|w| w == b"data") {
            if pos + 8 <= raw.len() {
                return Ok(raw[pos + 8..].to_vec());
            }
        }
    }
    Ok(raw)
}

fn synthesize_tts_pcm(text: &str) -> Result<Vec<u8>, String> {
    let tmp = format!("/tmp/free_asr_rs_say_{}.wav", std::process::id());
    let status = Command::new("/usr/bin/say")
        .args(["-v", "Tingting", "-o", &tmp, "--data-format=LEI16@16000", text])
        .status()
        .map_err(|e| e.to_string())?;
    if !status.success() {
        return Err("macOS `say` failed".to_string());
    }
    let pcm = load_pcm_16k_mono(Path::new(&tmp))?;
    let _ = fs::remove_file(&tmp);
    Ok(pcm)
}

fn main() {
    let args: Vec<String> = env::args().skip(1).collect();
    let mut provider = Provider::WeType;
    let mut say_text = String::new();
    let mut file_path = String::new();
    let mut stream = false;

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--provider" | "-p" => {
                i += 1;
                if i < args.len() && args[i] == "doubao" {
                    provider = Provider::Doubao;
                } else {
                    provider = Provider::WeType;
                }
            }
            "--say" | "-s" => {
                i += 1;
                if i < args.len() {
                    say_text = args[i].clone();
                }
            }
            "--file" | "--wav" | "-f" => {
                i += 1;
                if i < args.len() {
                    file_path = args[i].clone();
                }
            }
            "--stream" => {
                stream = true;
            }
            other if !other.starts_with('-') && say_text.is_empty() && file_path.is_empty() => {
                say_text = other.to_string();
            }
            _ => {}
        }
        i += 1;
    }

    if say_text.is_empty() && file_path.is_empty() {
        eprintln!("Usage: cargo run -- [--provider wetype|doubao] [--say <text> | --file <audio.wav>] [--stream]");
        std::process::exit(1);
    }

    let pcm = if !file_path.is_empty() {
        load_pcm_16k_mono(Path::new(&file_path)).expect("Failed to load audio")
    } else {
        synthesize_tts_pcm(&say_text).expect("Failed to synthesize TTS")
    };

    let mut cb = |partial: &str| {
        if stream {
            eprint!("\r\x1b[K⋯ {}", partial);
            let _ = io::stderr().flush();
        }
    };

    match transcribe(&pcm, provider, Some(&mut cb)) {
        Ok(text) => {
            if stream && !text.is_empty() {
                eprintln!("\r\x1b[K✓ {}", text);
            }
            println!("{}", text);
        }
        Err(err) => {
            eprintln!("Error: {}", err);
            std::process::exit(1);
        }
    }
}
