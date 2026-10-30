#!/usr/bin/env node
// Opt-in live API test. Sends only the supplied PCM fixture, at real-time speed.
// Node.js 22.18+; no npm packages. Credentials come only from the environment.
import { readFileSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';

const usage = `Usage: node tests/gemini-stream-smoke.mjs --file speech.pcm [options]
  --mode auto|manual  Automatic VAD or explicit push-to-talk boundaries (default: auto)
  --repeat N          Replay N turns on the SAME WebSocket (default: 1)
  --model NAME        Default: gemini-3.5-transcribe-live
  --drain-ms N        Observe responses after each turn (default: 3000)

Input: raw 16 kHz, mono, signed 16-bit little-endian PCM (not a WAV container).
Set GEMINI_API_KEY or GOOGLE_API_KEY outside the repository.
Output: JSON lines, including partial/final text and timing summaries.
Exit status is nonzero if a turn has no interim text BEFORE all audio is sent,
has no final transcript, or the connection fails. This is an opt-in API call.`;

function options(args) {
  const out = { file: '', mode: 'auto', repeat: 1,
    model: 'gemini-3.5-transcribe-live', drainMs: 3000 };
  for (let i = 0; i < args.length; i++) {
    const flag = args[i];
    const name = { '--file': 'file', '--mode': 'mode', '--repeat': 'repeat',
      '--model': 'model', '--drain-ms': 'drainMs' }[flag];
    if (!name || !args[i + 1] || args[i + 1].startsWith('--')) {
      throw new Error(`Invalid or missing argument: ${flag}\n${usage}`);
    }
    const value = args[++i];
    out[name] = name === 'repeat' || name === 'drainMs' ? Number(value) : value;
  }
  if (!out.file || !['auto', 'manual'].includes(out.mode)
      || !Number.isInteger(out.repeat) || out.repeat < 1
      || !Number.isInteger(out.drainMs) || out.drainMs < 1) {
    throw new Error(usage);
  }
  return out;
}

const key = process.env.GEMINI_API_KEY || process.env.GOOGLE_API_KEY;
const redact = (value) => key ? String(value).replaceAll(key, '[REDACTED]') : String(value);

async function main() {
  if (process.argv.includes('--help') || process.argv.includes('-h')) {
    console.log(usage);
    return;
  }
  const opts = options(process.argv.slice(2));
  if (!key) throw new Error('Set GEMINI_API_KEY or GOOGLE_API_KEY outside the repository.');
  const pcm = readFileSync(opts.file);
  if (!pcm.length || pcm.length % 2 || pcm.subarray(0, 4).toString() === 'RIFF') {
    throw new Error('Expected nonempty raw PCM16, not a WAV container. Convert with FFmpeg first.');
  }

  const start = performance.now();
  let setupComplete = false, failure, active, closing = false;
  const log = (kind, fields = {}) => console.log(redact(JSON.stringify({
    kind, tMs: Math.round(performance.now() - start), ...fields,
  })));
  const ws = new WebSocket(
    'wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key='
    + encodeURIComponent(key));
  ws.binaryType = 'arraybuffer';
  const send = (message) => {
    if (failure) throw failure;
    if (ws.readyState !== WebSocket.OPEN) throw new Error('WebSocket is not open');
    ws.send(JSON.stringify(message));
  };

  ws.addEventListener('open', () => {
    log('connected');
    const setup = {
      model: `models/${opts.model}`,
      generationConfig: { responseModalities: ['TEXT'] },
      inputAudioTranscription: {},
    };
    if (opts.mode === 'manual') {
      setup.realtimeInputConfig = { automaticActivityDetection: { disabled: true } };
    }
    ws.send(JSON.stringify({ setup }));
  });
  ws.addEventListener('message', (event) => {
    try {
      const msg = JSON.parse(typeof event.data === 'string'
        ? event.data : Buffer.from(event.data).toString('utf8'));
      if (msg.error) throw new Error(redact(JSON.stringify(msg.error)));
      if (msg.setupComplete) {
        setupComplete = true;
        log('setup_complete', { model: opts.model, mode: opts.mode });
      }
      if (msg.goAway) throw new Error('Server requested reconnect (goAway)');
      if (!active) return;
      const content = msg.serverContent;
      for (const field of ['interimInputTranscription', 'inputTranscription']) {
        const transcript = content?.[field];
        if (!transcript?.text) continue;
        const now = performance.now();
        const beforeAllAudioSent = active.sentBytes < pcm.length;
        if (field === 'interimInputTranscription') {
          active.firstInterimAt ??= now;
          active.interimCount++;
          if (beforeAllAudioSent) active.interimBeforeAllAudioSent++;
        } else {
          active.finalCount++;
          active.lastFinalAt = now;
        }
        log(field, { turn: active.turn, sentAudioMs: Math.round(active.sentBytes / 32),
          beforeAllAudioSent, text: transcript.text });
      }
    } catch (error) {
      failure = error;
    }
  });
  // Do not print the error event: it may contain the credential-bearing URL.
  ws.addEventListener('error', () => { failure = new Error('WebSocket connection failed'); });
  ws.addEventListener('close', (event) => {
    if (!closing) failure = new Error(`WebSocket closed: ${event.code} ${redact(event.reason)}`);
  });

  try {
    const setupDeadline = performance.now() + 10000;
    while (!setupComplete) {
      if (failure) throw failure;
      if (performance.now() > setupDeadline) throw new Error('Timed out waiting for setupComplete');
      await sleep(20);
    }
    for (let turn = 1; turn <= opts.repeat; turn++) {
      active = { turn, sentBytes: 0, start: performance.now(), interimCount: 0,
        interimBeforeAllAudioSent: 0, finalCount: 0 };
      if (opts.mode === 'manual') send({ realtimeInput: { activityStart: {} } });
      log('audio_start', { turn, durationMs: pcm.length / 32 });
      // Sending and receiving are concurrent. Replacing this loop with microphone
      // callbacks keeps the same wire protocol; do not wait for a whole recording.
      for (let offset = 0; offset < pcm.length; offset += 3200) {
        const chunk = pcm.subarray(offset, offset + 3200);
        send({ realtimeInput: { audio: {
          data: chunk.toString('base64'), mimeType: 'audio/pcm;rate=16000',
        } } });
        active.sentBytes += chunk.length;
        // Absolute deadlines avoid accumulating timer drift. Never burst-upload
        // the complete file: that would not demonstrate live input latency.
        await sleep(Math.max(0, active.start + active.sentBytes / 32 - performance.now()));
      }
      active.end = performance.now();
      log('audio_end', { turn });
      send({ realtimeInput: opts.mode === 'manual' ? { activityEnd: {} } : { audioStreamEnd: true } });
      // This fixed observation window is for a smoke test, NOT a production
      // finalization handshake. The transcribe model need not emit turnComplete.
      await sleep(opts.drainMs);
      if (failure) throw failure;
      const summary = {
        turn, model: opts.model, mode: opts.mode, audioDurationMs: pcm.length / 32,
        firstInterimMs: active.firstInterimAt == null ? null : Math.round(active.firstInterimAt - active.start),
        interimCount: active.interimCount,
        interimBeforeAllAudioSent: active.interimBeforeAllAudioSent,
        finalCount: active.finalCount,
        lastFinalAfterAudioEndMs: active.lastFinalAt == null ? null : Math.round(active.lastFinalAt - active.end),
        passed: active.interimBeforeAllAudioSent > 0 && active.finalCount > 0,
      };
      log('summary', summary);
      active = undefined;
      if (!summary.passed) throw new Error('Streaming check failed; inspect events and fixture duration.');
    }
  } finally {
    closing = true;
    ws.close();
  }
}

main().catch((error) => {
  console.error(redact(error.message));
  process.exitCode = 1;
});
