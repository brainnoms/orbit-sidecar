# orbit-sidecar

![Orbit sky](https://raw.githubusercontent.com/brainnoms/orbit-visualizer/v0.9.0/docs/media/banner.png)

A local macOS audio sidecar for the [Orbit](https://github.com/brainnoms/orbit-visualizer)
visualizer plugin family for Hermes Desktop. It runs on your machine, binds to
`127.0.0.1:8107`, and serves two things over plain HTTP/SSE:

- **Channel A — meters.** Live per-source loudness/level frames from CoreAudio
  process taps, pushed as SSE (`GET /stream`) to any number of browser renderers.
- **Channel B — voice.** Speech recognition *out* (SSE push) and text-to-speech
  *in* (chunked/streaming POST), so a browser-side agent UI can listen and speak
  without ever touching the system audio stack directly.

It is a component of a single-machine voice loop, not a general-purpose daemon.

## Architecture, in one paragraph

The sidecar attaches **CoreAudio process taps** to running audio sources and emits
an SSE meter pump (`event: levels`, ~13 Hz while subscribed, ~1 Hz heartbeat when
idle; subscriber-gated so an idle server barely wakes). A VAD closes mic
utterances and a persistent Python STT daemon (default: local CPU
`openai-whisper`, stdio JSONL, zero-disk) transcribes them; transcripts are
pushed out as `event: stt` on the Channel-B SSE stream. TTS arrives as a
chunked-transfer `POST /b/tts` with a JSONL body — the sidecar sentence-splits
incrementally and starts speaking as soon as the first clause closes. Multiple
client tabs register themselves over `POST /b/hello` (the *b-hello roster*, keyed
by bootId + epoch so restarts dedupe cleanly), and `GET /sky` returns a
derived-facts snapshot of that roster. "Now Playing" metadata and artwork come
from macOS MediaRemote via a vendored, reverse-engineered adapter
(`/nowplaying`, `/artwork`). The full Channel-B protocol — transport rationale,
event shapes, fallback chain — is specified in **[CHANNEL-B.md](CHANNEL-B.md)**;
`VERSION` is the **contract version** between sidecar and plugins.

## Requirements

- **macOS** (Apple Silicon is the build/run platform). This is not a Linux
  daemon: the meter plane depends on CoreAudio process taps and the Now-Playing
  plane on MediaRemote, both macOS-only.
- **Microphone permission** (TCC) for the binary — and the *launchd-run* binary
  needs its own grant (see supervision gotchas below).
- **Codesigning with entitlements**: `build.sh` ad-hoc signs the binary with
  `tap-entitlements.plist` (`com.apple.security.device.audio-input`), which is
  what lets it hold process taps.
- For the default STT engine: **Python 3 with `openai-whisper`** (any engine
  honoring the stdio JSONL contract works — see "Voice configuration").

## Build

`build.sh` is the only build path:

```sh
./build.sh            # -> ./orbit-sidecar (swiftc -O, ad-hoc codesigned)
```

It compiles `orbit-sidecar.swift` + `channel-b.swift` + `echo-cancel.swift` +
`sky.swift` + the vendored MediaRemote adapter objects, generates
`version.swift` from the `VERSION` file (plus `git describe` as the build id),
and codesigns with the tap entitlements. **`version.swift` is generated —
never hand-edit it; rebuild regenerates it.** No Xcode project, no SPM manifest:
read `build.sh` and you know exactly what the binary is.

## Run and supervise (launchd)

Two LaunchAgents, both in the **`gui/<uid>` domain** (see gotcha below):

1. `com.hermes.orbit-sidecar` — the sidecar itself
   (`RunAtLoad` + `KeepAlive`, `ThrottleInterval 5`).
2. `com.hermes.orbit-watchdog` — `orbit-watchdog.sh` every 15 s
   (`StartInterval 15`), which covers "alive-but-tap-dead / wedged" cases that
   `KeepAlive` can't see: it samples `/stream` and `launchctl kickstart`s the
   service only after two consecutive empty snapshots (a blip is not a hang),
   rate-limited so a silent system can't trigger a kick loop.

Sanitized example plists (drop under `~/Library/LaunchAgents/`, replace `~`
with real paths as appropriate):

```xml
<!-- com.hermes.orbit-sidecar.plist -->
<plist version="1.0"><dict>
  <key>Label</key><string>com.hermes.orbit-sidecar</string>
  <key>ProgramArguments</key><array>
    <string>~/Projects/orbit/orbit-sidecar</string>
  </array>
  <key>WorkingDirectory</key><string>~/Projects/orbit</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>~</string>
    <!-- optionally: ORBIT_STT_PY, ORBIT_HOME, ORBIT_STT, ORBIT_TTS_BASE, ... -->
  </dict>
  <key>StandardOutPath</key><string>~/Projects/orbit/sidecar.out.log</string>
  <key>StandardErrorPath</key><string>~/Projects/orbit/sidecar.err.log</string>
</dict></plist>
```

```xml
<!-- com.hermes.orbit-watchdog.plist -->
<plist version="1.0"><dict>
  <key>Label</key><string>com.hermes.orbit-watchdog</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string>
    <string>~/Projects/orbit/orbit-watchdog.sh</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>15</integer>
  <key>StandardOutPath</key><string>~/Projects/orbit/watchdog.out.log</string>
  <key>StandardErrorPath</key><string>~/Projects/orbit/watchdog.err.log</string>
</dict></plist>
```

After editing a plist, the reliable handoff (a bare `launchctl load` on a
running service can keep the old binary):

```sh
pkill -f orbit-sidecar
launchctl bootout   gui/$(id -u)/com.hermes.orbit-sidecar 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.hermes.orbit-sidecar.plist
```

**The gui-domain gotcha:** a LaunchAgent bootstrapped into `gui/<uid>` runs
inside your Aqua login session and gets live audio; a sidecar detached outside
an Aqua session boots fine, serves HTTP fine, but its CoreAudio taps are dead —
`/stream` answers forever with `"s":[]` (empty sources). Always supervise via
the `gui` domain, and treat persistent `"s":[]` as "tap dead", not "silent".

## Voice configuration (minimum honest setup)

- **STT out of the box:** `orbit-stt.py` — a persistent `openai-whisper` daemon
  running locally on CPU. The sidecar spawns it over stdio JSONL (base64 WAV in,
  transcript out; audio never touches disk, model loads once at boot).
- **Engine swap without recompiling:** set `ORBIT_STT_PY` (Python interpreter
  with the engine installed) and `ORBIT_HOME` (directory holding `orbit-stt.py`)
  in the launchd plist's `EnvironmentVariables`. Any daemon honoring the same
  stdio JSONL contract (mlx-whisper, faster-whisper, …) can sit behind the pipe.
- **TTS in:** the default voice is in-process `AVSpeechSynthesizer` (instant,
  local, zero-dependency; pin a voice with `ORBIT_TTS_VOICE`). Point
  `ORBIT_TTS_BASE` (plus `ORBIT_TTS_KEY`, `ORBIT_TTS_MODEL`) at **any
  OpenAI-compatible `/v1/audio/speech` endpoint** to swap in a provider — all
  env-swappable, no recompile. Endpoints are *not* baked into the Swift; no
  hostname is required (the author's homelab happens to use a host named
  `cerebro` — an example, not a requirement).
- `ORBIT_STT=1` arms the mic at boot; `ORBIT_PORT` (default 8107);
  `ORBIT_BARGEIN=0` disables auto-barge-in.

## HTTP surface (contract sketch, all on `127.0.0.1:8107`)

| Route | What |
|---|---|
| `GET /stream` | Channel A SSE pump, `event: levels` (~13 Hz hot / ~1 Hz idle) |
| `GET /sources` | current tap source list |
| `GET /nowplaying`, `GET /artwork` | macOS Now Playing metadata / cover art (MediaRemote) |
| `GET /b/status` | JSON: `{"version","build","stt":{state,engine,segs},"tts":{state,queued,spoken},"mic","ducked"}` — `version` is the contract version from `VERSION`, `build` is `git describe` (or a build stamp) |
| `GET /b/stream` | Channel B SSE: `b-hello` (roster hello), `stt` (segment-final transcripts, monotonic `id:`), `b-status` (2 s heartbeat) |
| `POST /b/tts` | TTS in, chunked JSONL body (`{"d":"…"}` deltas, `{"final":true}`, `{"barge":true}`); response closes when audio finishes playing |
| `POST /b/tts/speak` | one-shot utterance |
| `POST /b/mode` | arm/mute the mic |
| `POST /b/hello` | roster registration (bootId + epoch) |
| `GET /sky` | derived-facts snapshot of the Channel-B roster |

`CHANNEL-B.md` is the authoritative protocol document — event shapes, ack
semantics, fallback chain, and the transport decision (SSE + chunked POST,
deliberately not WebSocket) live there. `VERSION` is the contract version;
plugins read `version` from `/b/status` to detect sidecar compatibility.

## Limitations, honestly

- **macOS only.** CoreAudio process taps and MediaRemote are the foundation;
  there is no Linux or Windows path and none is planned.
- **MediaRemote is reverse-engineered.** Now Playing rides Apple's private
  framework; the vendored adapter shells out to Apple's platform `perl` to read
  the bus (a non-platform binary can't), which works but can break on macOS
  updates.
- **Logs grow fast.** The watchdog and SSE pump are chatty by design
  (self-reporting hot/cold ticks); rotate if you care.
- **Single-machine by design.** Loopback-bound (`:8107`), no auth beyond the
  loopback trust model, no remote deployments.
- The untracked cruft in a working tree (`.bak`, `.err`, old binaries) is
  build archaeology, not release content; only the sources, `build.sh`,
  `CHANNEL-B.md`, `VERSION`, `orbit-stt.py`, `orbit-watchdog.sh` and
  `tap-entitlements.plist` are the real thing.

## License

MIT — see [LICENSE](LICENSE).
