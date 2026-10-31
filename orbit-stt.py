#!/usr/bin/env python3
"""orbit-stt — persistent whisper STT daemon. stdio JSONL. Zero disk.

Owned by orbit-sidecar (channel B). Contract:
  <- {"seg": <int>, "wav": "<base64 mono 16k PCM16 WAV>"}   segment to transcribe
  -> {"ready": true, "engine": "whisper-<model>"}             model resident, live
  -> {"seg": <int>, "text": "...", "final": true, "took": s}  transcript
  -> {"seg": <int>, "err": "..."}                            per-segment failure

Audio never touches disk: base64 -> RAM bytes -> wave module -> numpy float32 ->
model.transcribe. Model loads ONCE at boot; segments transcribe warm.
Engine swap: run any daemon honoring this contract (mlx-whisper, faster-whisper);
the sidecar doesn't care what's behind the pipes.
"""
import os, sys, json, base64, io, time, wave, array

def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

def fail(msg):
    emit({"err": str(msg)})

def wav_to_f32(b: bytes):
    """Mono/stereo PCM16 (or PCM8) WAV bytes -> float32 mono @ its rate, in RAM."""
    w = wave.open(io.BytesIO(b), "rb")
    n, ch, sw, rate = w.getnframes(), w.getnchannels(), w.getsampwidth(), w.getframerate()
    raw = w.readframes(n)
    w.close()
    if sw == 2:
        a = array.array("h", raw)
        data = [v / 32768.0 for v in a]
    elif sw == 1:
        a = array.array("B", raw)
        data = [(v - 128) / 128.0 for v in a]
    else:
        raise ValueError("unsupported sample width %d" % sw)
    if ch > 1:
        data = [sum(data[i:i + ch]) / ch for i in range(0, len(data) - ch + 1, ch)]
    import numpy as np
    return np.array(data, dtype=np.float32), rate

def main():
    model_name = os.environ.get("ORBIT_STT_MODEL", "base")
    device = os.environ.get("ORBIT_STT_DEVICE", "")       # "" = auto (mps on Apple Silicon)
    fp16 = os.environ.get("ORBIT_STT_FP16", "auto")
    lang = os.environ.get("ORBIT_STT_LANG", "en")
    root = os.environ.get("ORBIT_STT_DIR", os.path.expanduser("~/.cache/whisper"))

    import whisper  # noqa: E402 — engine lives behind the pipe
    t0 = time.time()
    model = whisper.load_model(model_name, device=device or None, download_root=root)
    try:
        import torch
        dev = str(next(model.parameters()).device)
    except Exception:
        dev = device or "?"
    emit({"ready": True, "engine": "whisper-" + model_name, "device": dev,
          "load_s": round(time.time() - t0, 2)})

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except Exception as e:
            fail({"bad_json": str(e), "head": line[:64]})
            continue
        if m.get("ping"):
            emit({"pong": True, "busy": False})
            continue
        seg = m.get("seg")
        try:
            audio, rate = wav_to_f32(base64.b64decode(m["wav"]))
            if rate != 16000:  # whisper expects 16k; crude linear resample fallback
                step = rate / 16000.0
                idx = [int(i * step) for i in range(int(len(audio) / step))]
                import numpy as np
                audio = audio[np.array(idx)]
            t1 = time.time()
            kw = {"language": lang, "fp16": fp16 == "true"} if fp16 != "auto" else {"language": lang}
            # ⟦HOUSEHOLD ROSTER⟧ (2026-10-30): a human saying "Hey Donna" transcribes as
            # "Hey Dala" without a decoder bias — wake nomatch kills the loop at the gate.
            # initial_prompt seeds the names this house answers to + command vocabulary.
            pr = os.environ.get("ORBIT_STT_PROMPT", "Hey Donna, hey Orbit, hey Jarvis, hey Neuromancer. What time is it? Turn the lamp to fifty percent. Lock the front door. What's the weather?")
            if pr: kw["initial_prompt"] = pr
            res = model.transcribe(audio, **kw)
            emit({"seg": seg, "text": (res.get("text") or "").strip(),
                  "final": True, "took": round(time.time() - t1, 3)})
        except Exception as e:
            emit({"seg": seg, "err": "%s: %s" % (type(e).__name__, e)})

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        fail("fatal: %s: %s" % (type(e).__name__, e))
        sys.exit(1)
