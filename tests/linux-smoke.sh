#!/usr/bin/env bash
# Opt-in live network test. Provide synthetic 16 kHz mono WAV/PCM only.
set -euo pipefail
cd "$(dirname "$0")/.."
audio="${1:?Usage: tests/linux-smoke.sh /absolute/path/to/synthetic.wav}"
expected="${2:-}"
run() {
  result="$(timeout 40 "$@")"
  test -n "$result" || { echo "Empty transcript" >&2; return 1; }
  if [[ -n "$expected" && "$result" != "$expected" ]]; then echo "Transcript mismatch: $result" >&2; return 1; fi
  printf '%s\n' "$result"
}
python3 python/test_platform.py
node typescript/test_platform.ts
cargo test --manifest-path rust/Cargo.toml
cargo build --manifest-path rust/Cargo.toml
binary="${CARGO_TARGET_DIR:-rust/target}/debug/free-asr"
for provider in wetype doubao; do
  echo "Testing $provider: TypeScript, Python, Rust"
  run node typescript/free_asr.ts --provider "$provider" --file "$audio" --stream
  run python3 python/free_asr.py --provider "$provider" --file "$audio" --stream
  run "$binary" --provider "$provider" --file "$audio" --stream
done
