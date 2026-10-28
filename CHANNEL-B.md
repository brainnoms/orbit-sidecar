# Channel B — Audio Text Stream (STT out / TTS in)

**Task:** t_50833813 · blueprint §6 (`~/.hermes/vaults/Hermes-Plans/orbit-telemetry-audio-context-architecture.md`)
**Owner:** sidecar (`orbit-sidecar`, Swift, :8107). The sidecar owns the STT/TTS
engine relationships; the plugin owns thinking. This file is the transport decision + protocol.

---

## Transport decision: streaming HTTP — SSE out, chunked POST in. NOT WebSocket.

Rationale (pragmatic, per blueprint §6 "whatever services the reflex/big-brain
loop most cheaply/instantly"):

1. **SSE machinery is already production here.** Channel A (`event: levels`,
   :8107 `/stream`) runs the same NWListener + SSE push at 20 Hz, proven. Channel B
   is the *same server* emitting `event: stt` — zero new transport code.
2. **Network.framework has no WebSocket server.** WS means hand-rolling RFC6455:
   handshake, masking, opcodes, fragmentation, ping/pong, close semantics — hundreds
   of lines of fresh attack surface for **zero latency gain** on text-bandwidth
   payloads (a sentence is bytes, not frames).
3. **STT out = SSE push.** Instant server→plugin push the moment a segment closes.
   EventSource on the plugin side **auto-reconnects** (proven pattern, plugin.js
   channel-A arm) and we stamp monotonic event `id:`s so gaps are detectable.
4. **TTS in = chunked-transfer POST.** The plugin pipes its answer tokens
   (`fetch POST /b/tts` with a `ReadableStream` body, JSONL lines) and the sidecar
   consumes **incrementally** — sentence closes, speech starts. Same streaming
   semantics WS would give, in one `fetch`, no handshake, CORS model unchanged.
5. **First-audio latency is the defended number** (two-brain blueprint §5.1):
   SSE delivers STT text with zero polling round-trips; the TTS ingest does
   sentence-split + `flush_ms=400` timeout-flush so an unpunctuated clause still
   starts speaking mid-stream.
6. **One port.** Everything rides :8107 — the plugin's single, sealed, loopback
   trust model stays intact.

**Upgrade trigger (documented, honest):** WebSocket earns its keep only when we need
*binary multiplexed audio* over one connection (e.g. raw PCM mic passthrough to a
remote STT provider with downlink transcripts). Text channel B does not.

---

## Protocol (all on :8107, additive — channel A untouched)

### STT out — `GET /b/stream` (SSE)
```
event: b-hello   data: {"stt":"live|muted|starting|down","engine":"whisper-base","tts":"idle","mic":"armed|muted"}
event: stt       data: {"id":7,"seg":3,"text":"what's the weather","final":true,"engine":"whisper-base","took":0.41,"ts":1792590000}
event: b-status  data: {...}                       ← heartbeat @2s (keeps NAT/keep-alive warm, carries state)
```
- `id:` monotonic per connection — EventSource resends `Last-Event-ID` on reconnect.
- v1 granularity is **segment-final**: the VAD closes an utterance and the resident
  engine transcribes it (sub-second once the daemon is warm). True partials arrive
  when a streaming engine is swapped in — the protocol already fits (`final:false`).

### TTS in — `POST /b/tts` (chunked / streamed body)
Body is **JSONL**, one directive per line, sent as tokens arrive:
```
{"d":"The weather today "}      ← text delta appended to the speak buffer
{"d":"is 72 and clear."}
{"final":true}                  ← stream done; flush remainder
{"barge":true}                  ← stop speaking + drop queue immediately
```
- Raw `Content-Type: text/plain` accepted too: bytes stream straight into the
  buffer; `\n` closes a sentence; connection close flushes.
- Sentence splitter flushes at `. ! ?` (and `\n`); **flush_ms=400** timeout-flush
  starts speech on long unpunctuated clauses (word boundary preferred).
- One voice at a time: sentences queue, play in order. **Duck** engages on first
  sentence, **unduck** when the queue drains (reuses channel-A duck).
- Header `X-Orbit-Voice: <name>` optionally pins the voice for the stream.

### One-shot TTS — `POST /b/tts/speak`
`{"text":"hello bob","voice":"", "barge":true}` — convenience/escalated single utterance.

### Control / state
```
POST /b/mode    {"stt":true|false}   arm/mute mic (engine relationship is sidecar's)
POST /b/inject  {"seg":1,"wav":"<base64 16k-mono WAV>"}  test hook — feeds the engine
                                                            pipeline directly, bypasses mic
GET  /b/status  {"version","build","stt":{"state","engine","segs"},"tts":{"state","queued","spoken"},"mic","ducked"}
      version = contract version from VERSION file (compile-stamped via generated version.swift);
      build = git describe when repo-present, else bYYYYMMDD.HHMM. Plugin (card E) reads
      `version` for sidecar-installed detection -> tooltip "(vX)"; absent -> "version unreported".
```
Barge-in auto-engages on **new mic utterance close while speaking** (blueprint §5.1
"new voice turn cancels in-flight TTS").

---

## Engine relationships (sidecar-owned, swappable — blueprint §1/§6)

| Engine | v1 here (local-only, §9c) | Swap path |
|---|---|---|
| STT | `orbit-stt.py` — persistent **openai-whisper** daemon (`base` default; `medium`/`large-v3-turbo` cached), model resident in RAM, stdio JSONL, **zero disk** (RAM WAV → numpy → `model.transcribe`). | `ORBIT_STT_CMD` → any engine daemon on the same stdio contract (mlx-whisper, faster-whisper); `http` → oMLX/Cerebro `/v1/audio/transcriptions` for hybrid installs. |
| TTS | **AVSpeechSynthesizer** in-process — native, instant, local, zero-dep. Voice via `ORBIT_TTS_VOICE`. | Qwen3-TTS/Kokoro MLX daemon behind the same `/b/tts` contract (models already on disk). |

**Zero-disk discipline (§9):** mic segments live only in RAM, cross to the engine as
base64 over stdio pipes. Nothing raw touches disk. No transcripts retained — STT text
is push-through to the plugin, the sidecar keeps no content log (audit state only:
§9 line, identity/decisions not content).

**§9b fork guard:** nothing here decides erasure rights or shared-device session
binding. The transport is content-free at rest because there is no rest.

---

## Fallback chain (§6 graceful)
- STT daemon dies → sidecar restarts it (backoff), `stt:"down"→"starting"→"live"`, SSE never drops.
- Sidecar absent → plugin falls back to Hermes' native voice loop (unchanged; plugin's
  channel-B arm fails soft — EventSource retry, caption area stays calm).
- Channel A endpoints byte-identical — channel B is additive on the same server.

## Ops
- `ORBIT_PORT` (default 8107), `ORBIT_STT=1` arms mic at boot (macOS TCC prompt once),
  `ORBIT_STT_MODEL` whisper model, `ORBIT_TTS_VOICE` AVSpeech voice, `ORBIT_BARGEIN=0` disables auto-barge.
- Build: `./build.sh` (now compiles `channel-b.swift` + tap core together).

## Transport decision (final, 2026-10-21)
**Streaming HTTP — not WebSocket.** Rationale (easiest to service the agentic loop):
- STT-out: SSE (`GET /b/stream`, `event: stt`/`b-status`) — the sealed renderer already
  speaks EventSource for channel A; auto-reconnect is built into EventSource, zero new
  client machinery.
- TTS-in: chunked `POST /b/tts` — the big brain streams sentence deltas (NDJSON `{"d":...}`
  or plain text lines); the sidecar keeps the response open and acks
  `{"accepted":true,"spoken":N,"done":true}` exactly when the last sentence finishes playing.
  The fetch promise itself is the end-of-turn signal for the agent loop — no separate
  turn-state channel to design, no upgrade handshake, no ping/pong keepalive layer.
- WebSocket would add an upgrade + frame layer on both ends for the same byte semantics;
  every primitive needed is already proven on this server. Decision stands unless bidirectional
  binary audio-in-one-socket becomes a requirement.

## Production promotion log (2026-10-21)
- :8107 live with channel B: STT whisper-base daemon resident, streamed TTS spoken
  (`/b/tts` chunked POST closes clean, `/b/stream` emits b-hello/b-status/stt).
- coreaudiod wedged during promotion (every `AudioDeviceCreateIOProcID` blocked in
  mach_msg system-wide, sampled proof). Hardened in response: tap lifecycle + volume
  property calls + ChannelB engine init all moved OFF the main thread — a wedged audio
  server can no longer take down boot, the HTTP plane, or channel B; taps self-heal
  via `scan()` retries when coreaudiod returns. Watchdog `tap-dead` rule now kicks
  ONCE per empty-streak (was every 30s — kick storms churned now-playing/TTS).
- PENDING (needs human at keyboard, once): mic TCC grant for the launchd-run binary —
  until granted, `mic:"muted"` in production (graceful; plugin mic path falls back to
  native browser transcribe). Fix: click the visualizer mic once, or `POST /b/mic
  {"on":true}` at the keyboard, or bounce coreaudiod with sudo to clear the wedge first.
