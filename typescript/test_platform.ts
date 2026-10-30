// Offline encoder check on the current platform; Linux requires FFmpeg/libopus.
import assert from "node:assert/strict";
import { encodeWeTypeOpusChunks } from "./free_asr.ts";
const chunks = encodeWeTypeOpusChunks(Buffer.alloc(32000));
assert.ok(chunks.length >= 10);
assert.equal(chunks[0].subarray(0, 16).toString("binary"), "#!OPUS_RAW_V1\x02\x01\x00");
let frames = 0;
for (let i = 0; i < chunks.length; i++) {
  const chunk = chunks[i];
  let at = i ? 0 : 16;
  while (at < chunk.length) {
    const length = chunk.readUInt16LE(at);
    assert.ok(length > 0 && length <= 1275);
    at += length + 2;
    frames++;
  }
  assert.equal(at, chunk.length);
}
assert.ok(frames >= 50);
assert.deepEqual(encodeWeTypeOpusChunks(Buffer.alloc(0)), []);
assert.throws(() => encodeWeTypeOpusChunks(Buffer.alloc(640), 0));
console.log(`Opus framing passed on ${process.platform}`);
