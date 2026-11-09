# LOOP-RECON — speech-loop ecosystem research (feeds Interface C)

Card `t_1d4c7f8a` · hiro · 2026-11-09. Source ground truth: `~/.hermes/hermes-agent` @ `bc4c142a93` (2026-11-07), plus this machine's live configs and the G-card program receipts (`t_75de594a` Card A verb table, `t_a0e43065` G control-sync). Research card: no production changes, no engine restart; spikes disclosed in §2.

**One-line verdict:** the shim is buildable today with zero Hermes platform changes — cerebro already runs the exact OpenAI-compatible wire (§2 spikes), and the sidecar's only gap is two missing POST routes on :8107 (§2 probe).

## 1. What speech plugins do today (and how they hook the loop)

**Mechanism = a provider registry, not monkey-patch, not separate surfaces.** Plugins call `PluginContext.register_tts_provider()` / `register_transcription_provider()` (`hermes_cli/plugins_context.py:866,870`) against two ABCs:

- **TTS** — `agent/tts_provider.py`: `TTSProvider.synthesize(text, output_path, voice/model/speed/format)` is required; the streaming voice path is opt-in via `streams_pcm` + `stream_sample_rate` + `stream()` yielding raw int16 LE mono PCM (`:29-44`; thread-safety required, speaker prefetches up to 3 sentences).
- **STT** — `agent/transcription_provider.py`: `TranscriptionProvider.transcribe(file_path, model/language/prompt)` returns a `{success, transcript, provider, error}` envelope and must not raise; live streaming is opt-in via `streaming_capable` / `open_stream_session()` with `push_audio` (16 kHz mono s16le) / `finalize` / `partial_transcript` (`:26-66`).

**Resolution precedence (who services `tts.provider: <name>`):** built-in names never reach the plugin registry; a same-named `tts.providers.<name>: {type: command}` wins over a plugin ("config is more local than a plugin install"); unknown names fall through to the Edge default — `tools/tts_tool_plugins.py:36-45` (`_plugin_route_key`), `:84-103` (`_dispatch_to_plugin_provider`). Built-in TTS set: `edge, elevenlabs, openai, minimax, xai, mistral, gemini, neutts, kittentts, piper, deepinfra` (`tools/tts_command_provider.py:301-303`). STT mirrors it: built-ins `local, local_command, groq, openai, mistral, xai, elevenlabs, deepinfra` (`tools/transcription_common.py:68-70`), plugin dispatch otherwise (`tools/transcription_tools.py:525,549`).

**Catalog/hub (voice category, `plugin-catalog/*.yaml`, 21 entries):**
- *Provider plugs* (register a TTS/STT provider name): `speechify` (`tts.provider: speechify`), `wyoming-voice-bridge` (stt/tts provider `wyoming` — the closest precedent to "point Hermes at a box you run"), `ttsbuddy`, `transcription-dashscope` (Qwen STT), `kokoro-tts`, `fish-audio`, `deepgram-voice`, `omnivoice`, `openrouter-voice`, `breeze-tts`, `alice-voice`, `carbonvoice-platform`, `hermes-live-voice`, `hermes-whatsapp-voice`, `idealphase-elevenlabs-audio-tags`.
- *Management/tool surfaces*: `hermes-speech` (AllModels router, 80+ voices behind one key, guided setup + `allmodels_speech_setup/manage` tools — proof that "speech provider onboarding" is plugin-able).
- *Hook-only*: `stt-vocab` (`pre_transcription` hook rewrites the Whisper prompt with vocabulary), `voice-ledger` (observer, logs every recording).

**This install:** no speech plugin in the gateway (`plugins/` = chronicle, homeassistant, performance-inspector, tavily; profile hiro = homeassistant). The speech loop runs on **built-ins pointed at omlx/cerebro** (hiro profile `tts.openai.base_url: http://192.168.1.3:8000/v1`, model `Kokoro-82M-8bit`, voice `af_bella`) plus a gateway `tts.providers.jarvis: type: command` entry (`donna-tts` script) — the command-provider escape hatch in `tools/tts_command_provider.py` (template placeholders `{text_path}/{output_path}/…`). On the desktop side, the orbit-visualizer plugin carries the live voice lane (`~/.hermes/desktop-plugins/orbit-visualizer/plugin.js`: 15 `G-CONTROLSYNC`/`CARD-F`/`jarvisPTT` markers — the G/F/E program landed there).

**Server relay surface (desktop's audio ladder endpoints):** `hermes_cli/web_routers/audio.py` — `GET /api/audio/voice-config` `:152`, `POST /api/audio/speak` `:298`, `WS /api/audio/transcribe-stream` `:521`, `WS /api/audio/speak-stream` `:604`.

## 2. Can Hermes be pointed at an OpenAI-compatible endpoint today? YES — config-only, both directions

| Knob | Where it's read | What it does |
|---|---|---|
| `tts.provider: openai` + `tts.openai.{base_url,api_key,model,voice,speed}` | `tools/tts_tool_openai.py:59,115-117` | config base_url beats the auth-chain fallback; the Nous-managed model whitelist is skipped once base_url is redirected (`:122-123`) |
| `tts.openai.pcm_sample_rate` (+ server `X-Audio-Sample-Rate` / `Content-Type rate=` headers) | `tools/tts_streaming.py:277-316` | streaming TTS via `client.audio.speech` `response_format=pcm`; endpoint can announce its PCM rate and Hermes honors it before first chunk |
| `stt.provider: openai` + `stt.openai.{base_url,api_key,model}` | `tools/transcription_cloud.py:400-411` | credential ladder: config key → **keyless local base_url** (placeholder bearer `not-needed` so the SDK constructs) → env key → managed |
| `stt.openai.streaming_model` | `tools/transcription_streaming.py:10-16,462` | live dictation wire; session dials `{base_url→ws}://host/v1/realtime?intent=transcription` (`:263-268`) — derived from the SAME base_url |
| Desktop client-direct wires | `tools/voice_client_config.py:20-29` | `openai-multipart` = `POST {base_url}/audio/transcriptions` (Bearer), `openai-speech` = `POST {base_url}/audio/speech` → audio bytes; executed renderer-side at `apps/desktop/src/lib/voice-client-direct.ts:318,415` |

Desktop read-aloud's client-direct rung means the **renderer itself** POSTs straight to whatever `stt/tts.*.openai.base_url` names — the gateway resolves the wire + key via `GET /api/audio/voice-config` and the key lives in renderer memory only (`voice_client_config.py:1-9`). Command- and plugin-providers resolve to `{mode: relay}` there (`:108`) — only the built-in wire list (openai/xai/elevenlabs/…) gets direct.

**Spikes (live this card, cerebro = `192.168.1.3:8000`, disclosed):**
1. `POST /v1/audio/speech` `{Kokoro-82M-8bit, af_bella}` → **200**, 118,844 B WAV, 24 kHz mono PCM, 0.64 s. (This is hiro's live TTS path — pointing at an OpenAI-compat endpoint isn't hypothetical here, it's how the profile speaks today.)
2. `POST /v1/audio/transcriptions` `model=whisper-large-v3-turbo-asr-fp16` → **200**, transcript of the spoken test sentence exact: `" The data vectors do not lie."` (no `stt:` section in either config → default auto-detect picks local faster-whisper; the openai-compat rung is one config stanza away).
3. Sidecar `:8107` today: `POST /v1/audio/speech` → **404**, `POST /v1/audio/transcriptions` → **404**. `/b/status` live: `stt {state:live, engine:whisper-base}`, `tts {provider:{configured:false,…}}` — the sidecar already runs whisper for its own lane and has an upstream-provider slot.

**Feasibility answer: no platform change needed to point Hermes at the sidecar.** The shim is sidecar-side work: serve those two POST shapes (plus the optional realtime WS) under `:8107/v1`, and set `tts.provider: openai; tts.openai.base_url: http://127.0.0.1:8107/v1` (same for `stt.openai`).

## 3. Who owns the hard loop problems today

| Piece | Owner today | Evidence |
|---|---|---|
| **Wake** | Hermes gateway daemon (`tools/wake_word.py`; engines pyopen-wakeword / sherpa-onnx KWS / Porcupine, `tools/wake_word_engines.py:1`). Capture `local` vs `client` (`wake_word.py:75-78,149-159` — `remote`/`external` collapse to client). Per-transport **ownership lease**; `wake.pause/resume` are owner-scoped, `wake.feed` route-through PCM = the native usurp primitive (Card A verdict table, re-verified at this HEAD). | sidecar never needs to own wake — it leases it |
| **Barge-in** | Gateway `tui_gateway/methods_voice.py`: one streaming-TTS pipeline per process; `_tts_stream_stop(user_barge=True)` cuts it and `mark_speech_interrupted()` latches the interrupt for the next turn (`:165,194-207`); gated by `voice.barge_in` (`:235-237`). The renderer has its own playback stop (voice-playback session `stop` → fallback settle). | barge = the loop **canceling** the HTTP/WS synth request — the shim must honor client disconnect |
| **Streaming in (STT)** | Opt-in `stt.streaming: true`; built-in wires openai-realtime `{base}/realtime`, xai `{base}/stt`, elevenlabs realtime (`transcription_streaming.py:10-16,263-388`); plugins opt in via `streaming_capable`; **every surface falls back to the file path** when no session opens (`:18-19`) | no streaming = degraded latency, not broken dictation |
| **Streaming out (TTS)** | `tools/tts_streaming.py` + `tools/tts_tool_speaker.py` (prefetch ≤3, FIFO). Renderer ladder: client-direct sentence synth → `/api/audio/speak-stream` WS relay → `/api/audio/speak` file (`voice-playback.ts:84-86,122-196`; `web_routers/audio.py:298,604`) | the shim rides the same ladder for free |
| **Turn detection** | Gateway full-duplex VAD: `_full_duplex_listener` → `full_duplex_listen` (voice_mode) with `_fd_barge_params` multiplier/grace (`methods_voice.py:250-279,285`); trip → transcribe → `voice.transcript`. Stop-phrase ends the chat (typed or spoken). Desktop PTT turn = dictation session finalize. | turn = VAD trip or PTT release, both loop-side |
| **Usurp / device ownership** | G-card program: sidecar device-claim = non-destructive process taps under a 30 s **lease** (`GET /claim` refresh; orbit `t_a0e43065`), desktop toggles stay policy, mic policy flows through native `wake.*` verbs. | shim must not double-own the devices — keep every mic/speaker tap behind the existing `/claim` lease |

**Ownership rule for the shim:** the sidecar is a *passive endpoint* on the OpenAI wire — it owns models and audio, never wake, never barge, never turn detection. The loop driver cuts it by hanging up; the loop driver arms it by POSTing.

## 4. Recommendation + platform asks (fills Interface C)

**RECOMMENDATION: SHIM NOW.** Not "shim with platform asks" — every ask below is additive polish; none blocks. cerebro running Kokoro-TTS + Whisper-large on the exact wire is the existence proof, and the hiro profile already demonstrates the pointing. Sidecar effort is bounded: two POST routes (+ one WS later); it can run models itself (its whisper-base is live; Qwen3-TTS is on cerebro) or pass through upstream (`/b/status.tts.provider` slot is already the config for that).

**Interface C ask list:**
1. **(sidecar, REQUIRED)** `POST /v1/audio/speech` — JSON `{model, input, voice, response_format}` → audio bytes. Support `response_format: pcm` and announce the rate via `X-Audio-Sample-Rate` header (else Hermes pins `tts.openai.pcm_sample_rate`). Must honor client disconnect mid-body — that IS the barge-in.
2. **(sidecar, REQUIRED)** `POST /v1/audio/transcriptions` — multipart `{file, model[, language]}` → `{"text": …}`. Accept any/absent Bearer: Hermes sends placeholder `not-needed` for local URLs (`transcription_cloud.py:400-411`).
3. **(sidecar, OPTIONAL — streaming)** `ws://:8107/v1/realtime?intent=transcription` speaking the OpenAI Realtime transcription dialect (deltas before commit). Until it exists, `stt.streaming` falls back to file transcription: dictation still works, live captions don't.
4. **(platform, inherited)** Drivable read-aloud verb + readable atom (Card A ask #1). The renderer read-aloud still isn't in the RPC surface (localStorage + storage-event sync works per Card G); the shim doesn't change that — ask stands.
5. **(platform, watch-out)** Command/plugin providers are relay-only in client-direct (`voice_client_config.py:108`). If orbit ever wants renderer-direct speech AND a wyoming-style plugin provider simultaneously, the wire allowlist must grow — for now, `provider: openai` + base_url is the lane that gets the one-hop renderer path.
6. **(sidecar, hygiene)** Keep transcripts whisper-clean: the silence-hallucination contract (`is_whisper_hallucination`) is applied on relay and forwarded to client-direct (`voice_client_config.py` `hallucination_filter`) — passthrough providers should mimic whisper-style whitespace or accept the filter eating replies.

**Stale voice-lane items (retest, non-blocking):** push-to-talk provider error, missing `omlx-cli` path, globally-missing `ws` module — all sidecar-lane, none touched this card. The two 404s in §2 are the sidecar's current gap list, not Hermes'.

**Sibling cards:** revived duplicates `t_c575972e` (LOOP-RECON) and `t_bdc2d30e` (CONTRACT-FROZEN) run on the board; the family spec v1 that reserves Interface C is CONTRACT-FROZEN's deliverable — this doc is the speech-loop fill for it.
