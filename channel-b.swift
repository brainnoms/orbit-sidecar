// channel-b.swift — Channel B: STT text OUT (SSE), TTS text IN (chunked POST),
// and the RETURN half of the contract (card C): in-waveform + out-waveform +
// turn timing over the SAME /b/stream SSE (b-in / b-out / b-timing events —
// see CHANNEL-B.md §card C). Waveforms are 64-bin signed-peak frames, base64,
// 128-centered — byte-identical to the plugin's getByteTimeDomainData layout.
// Blueprint §6. Transport decision: streaming HTTP (see CHANNEL-B.md). Additive to
// orbit-sidecar.swift — channel A (:8107 /stream levels) is untouched.
//
// Owns the engine relationships (blueprint §1): mic tap -> VAD -> resident STT
// daemon (stdio JSONL, zero disk) -> SSE 'event: stt'. TTS: streamed text in ->
// sentence splitter (+flush_ms=400 §5.1) -> provider TTS (LEVEL 1, card B:
// oMLX-compatible POST {base}/v1/audio/speech, voice from the plugin's selection) ->
// AVSpeechSynthesizer ONLY as LEVEL-2 fallback when the selection is missing or the
// provider call fails (blueprint §1) -> duck/unduck/barge (reuses channel-A duck).
// No content ever rests on disk (§9) — provider audio lives in RAM (dump is an opt-in
// evidence hook via /b/mode {"dump":dir}, off by default).
import AVFoundation
import Foundation
import Network

final class ChannelB: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    static let shared = ChannelB()

    // ---- tunables (env-overridable; nothing hardcoded per box — §9c) ----
    var bargeOn = ProcessInfo.processInfo.environment["ORBIT_BARGEIN"] != "0"
    let flushMs: TimeInterval = 0.400          // §5.1 timeout-flush
    let vadThresh = 0.010                       // RMS speech floor
    let vadHangover: CFTimeInterval = 0.600    // silence before segment close
    let preRollFrames = Int(0.200 * 16000)    // keep speech onset
    let maxSeg: CFTimeInterval = 10.0          // force-close cap
    var micArmedAtBoot = ProcessInfo.processInfo.environment["ORBIT_STT"] == "1"
    let sttCmd: [String] = {                   // engine daemon behind the pipe
        // auto-resolve the NEWEST whisper cellar python — a brew upgrade changes the
        // version dir and a hardcoded path silently kills STT (2026-10-22 e1 canary:
        // '20250625_6' rotted to '20250625_8'; stt daemon spawn failed, engine 'down')
        let py = ProcessInfo.processInfo.environment["ORBIT_STT_PY"] ?? {
            let cellar = "/opt/homebrew/Cellar/openai-whisper"
            let vs = ((try? FileManager.default.contentsOfDirectory(atPath: cellar)) ?? [])
                .sorted(by: >)
            for v in vs {
                let p = cellar + "/" + v + "/libexec/bin/python"
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
            return "/opt/homebrew/bin/python3"   // last resort; daemon import will fail loudly
        }()
        let dir = ProcessInfo.processInfo.environment["ORBIT_HOME"]
            ?? NSString(string: "~/Projects/orbit").expandingTildeInPath
        return [py, dir + "/orbit-stt.py"]
    }()

    // ---- state (all guarded by bblock) ----
    let bblock = NSLock()
    var sseConns: [NWConnection] = []
    // evtId declared below, seeded from bootMark (cross-boot monotonic)
    var segId = 0
    var sttState = "starting"                  // starting|live|muted|down
    var engineName = "?"
    var segsDone = 0
    var micOn = false
    var engineMuted = false
    var ttsState = "idle"                      // idle|speaking
    var queued: [String] = []                  // speak queue (sentences)
    var spoken = 0
    var pending = ""                           // TTS token buffer (line-framed JSONL or raw)
    var ttsBuf = Data()                        // raw byte staging for line framing (CRLF-proof)
    var streamOpen = false
    var ttsChunk: ChunkDecoder?                // set when request is Transfer-Encoding: chunked
    var lastByte: CFTimeInterval = 0
    var ttsConn: NWConnection?                 // the open /b/tts request conn — the TURN's lifecycle
    var ttsEOF = false                         // client finished sending its turn
    var ttsAcked = false                       // final ack written (idempotence guard)
    var uttDeadline: CFTimeInterval = 0       // stuck-synthesizer fuse for the current utterance
    var voiceOverride = ""
    // card B — provider-TTS (LEVEL 1). Config arrives PER-REQUEST (plugin is the
    // config authority, §1); env supplies boot defaults; empty selection ⇒ LEVEL 2.
    var pBase = ""          // provider base URL, e.g. http://cerebro:8000
    var pKey = ""           // bearer key — RAM only: never logged, never in statusJSON
    var pModel = ""         // TTS model id from the plugin's selection
    let envBase = ProcessInfo.processInfo.environment["ORBIT_TTS_BASE"] ?? ""
    let envKey = ProcessInfo.processInfo.environment["ORBIT_TTS_KEY"] ?? ""
    let envModel = ProcessInfo.processInfo.environment["ORBIT_TTS_MODEL"] ?? ""
    let synthTimeout = Double(ProcessInfo.processInfo.environment["ORBIT_TTS_SYNTH_TIMEOUT"] ?? "") ?? 45
    var uttGen = 0          // utterance generation: barged mid-synth audio dies silently
    var providerErrs = 0    // provider failures since boot (each one fell to LEVEL 2)
    var synthInFlight = 0   // provider synthesize calls running RIGHT NOW — the ack
                            // guard must not close a turn whose audio is being cooked
    var lastMode = ""       // provider | avspeech — engine of the most recent utterance
    var player: AVAudioPlayerNode?   // ⟦ECHO LAW⟧ LEVEL-1 playback rides the SAME engine as the mic:
                                     // Apple VPIO cancels what we ourselves play. The old split
                                     // (AVAudioPlayer out ∥ AVAudioEngine in) cancelled NOTHING —
                                     // the agent hears itself, media bleeds into STT, wake ghosts follow.
    var legacy: AVAudioPlayer?       // fallback when the engine can't run — no cancellation, logged honestly
    var vpio = false                 // Voice Processing IO engaged (AEC + NS + AGC on the mic path)
    var vpioTried = false
    var cfgObs = false
    var nodeAttached = false
    // The player node speaks exactly ONE format (48k stereo). Provider audio is
    // RESAMPLED into it in code: a 24k buffer scheduled into a 48k node doesn't
    // error — it just plays at chipmunk speed (caught live 2026-10-30).
    // Node format tracks the PROVIDER rate (Kokoro 24k): the engine's own sample-rate
    // converter does the interpolating — my hand-rolled linear resample (24k→48k) bought
    // speed at the price of robot voice (Bob, 2026-10-30). Reconnect the node when — and
    // only when — a different provider rate shows up; the mixer SRCs properly.
    var uttStart: Double = 0
    var afProc: Process? = nil          // ⟦AFPLAY MOUTH⟧: both in-process players refused to open output ALL NIGHT while say/afplay/AVSpeech worked — sounding is DELEGATED to a child process whose on-time exit is the completion receipt.
    var nodeEnds: Double = 0          // wall-clock finish line for the current node utterance
    var nodeEnded: Bool { nodeEnds > 0 && CACurrentMediaTime() > nodeEnds }
    var renderAlive: Double = 0   // last node completion — the render is consuming samples
    var nodeRate: Double = 0
    func nodeFormat(_ r: Double) -> AVAudioFormat { AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: r, channels: 2, interleaved: false)! }         // engine.attach is one-shot per node — twice = NSAssert death
    var dumpDir = ProcessInfo.processInfo.environment["ORBIT_TTS_DUMP"] ?? ""   // evidence hook: dump provider bytes here ("off" unless env or /b/mode)
    var daemon: Process?
    // ⟦BOOT MARK⟧ (2026-10-30): b-stream replays events on (re)connect, so the plugin
    // dedupes stt by monotonic id — but ids RESET to 1 when this process restarts, and a
    // long-lived window saw every event from nine restarts tonight as 'older than seen'
    // and silently ate them all: 'not a single stat'. b-hello now carries boot; a new
    // boot resets the window's dedup ledger. State corrected live, at hello.
    static let bootMark = Int(Date().timeIntervalSince1970 * 1000)
    // ⟦CROSS-BOOT IDS⟧ (2026-10-30, 'still the same'): event ids restarted at 1 every
    // boot, so a long-lived window deduped a REAL wake phrase to death (id=2935 beat the
    // fresh ids). Event ids now inherit the birthmark: bootMark + counter is monotonic
    // ACROSS reboots — the ledger never needs to know a reboot happened, and replay
    // dedup inside one boot stands untouched. No disk, no lease, no zombie.
    var evtId = ChannelB.bootMark
    var dIn: FileHandle?
    // ⟦PIPE LAW⟧ (2026-10-30): concurrent ~20 KB base64 JSON writes from global(qos:)
    // interleave mid-byte (pipe atomicity = 512 B) — whisper answered 'Incorrect
    // padding'. One serial queue owns every whisper stdin write.
    let whisperQ = DispatchQueue(label: "orbit.whisper.stdin", qos: .userInitiated)
    var pumpTick = 0

    // ---- card C: return-channel state (waveform + timing telemetry) ----
    // in-side: fed on the mic tap thread (vad()), drained by the frame ticker.
    let inLock = NSLock()
    var inRing = [Int16]()          // last ~100ms of mic at tap rate (RAM only, §9)
    var inRmsSm = 0.0               // exponential-smoothed mic rms (level atom)
    // out-side: the LEVEL-1 provider PCM already in RAM (card B). AVSpeech has
    // no PCM — its b-out frames carry an honest empty waveform, speaking=true.
    var outPcm = [Int16]()          // current sentence's samples (swapped per playAudio)
    var outRate: Double = 24000     // provider WAV rate (24k Qwen3-TTS; 22.05k tell)
    var outT0: CFTimeInterval = 0   // host time of play() — the waveform playhead
    var outSpeaking = false         // b-out speaking:true flip state
    // turn timing: one /b/tts request = one turn (oneShot has turnStart=0 → silent)
    var turnN = 0
    var turnStart: CFTimeInterval = 0   // host time of beginTTS; 0 = no open turn
    var turnSpokenBase = 0              // `spoken` counter at turn start
    var firstAudioDone = false          // first_audio emitted for this turn?
    var firstLatencyMs = -1.0           // turn start → first audible sample
    var lastSynthMs: Double = 0         // provider HTTP call time, most recent sentence
    var turnMode = ""                   // engine of the turn's first audio
    var frameTimer: DispatchSourceTimer?
    static let wfBins = 64

    let speech = AVSpeechSynthesizer()
    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()   // playback source inside the VPIO graph
    var micRate: Double = 16000                // actual tap rate after decimation
    var preBuf = [Int16]()                     // pre-roll ring (RAM only)
    var segBuf = [Int16]()
    var segOpen = false
    var segStart: CFTimeInterval = 0
    var lastVoice: CFTimeInterval = 0

    // ---------------- lifecycle ----------------
    func start() {
        speech.delegate = self
        if let v = ProcessInfo.processInfo.environment["ORBIT_TTS_VOICE"], !v.isEmpty {
            voiceOverride = v
        }
        startDaemon()
        if micArmedAtBoot { armMic() }
        startFrames()
        log("channel-B up (stt=\(sttState) mic=\(micOn ? "armed" : "muted"))")
    }

    // ---------------- STT engine daemon (stdio JSONL, restart-safe) ----------------
    func startDaemon() {
        bblock.lock(); let already = (daemon != nil); bblock.unlock()
        if already { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sttCmd[0])
        p.arguments = Array(sttCmd.dropFirst())
        let out = Pipe(), inP = Pipe()
        p.standardOutput = out; p.standardInput = inP
        p.standardError = FileHandle.standardError
        do {
            try p.run()
            bblock.lock(); daemon = p; dIn = inP.fileHandleForWriting; sttState = "starting"; bblock.unlock()
            out.fileHandleForReading.readabilityHandler = { [weak self] h in
                let d = h.availableData
                if d.isEmpty { return }
                guard let s = String(data: d, encoding: .utf8) else { return }
                for ln in s.split(separator: "\n") { self?.onDaemonLine(String(ln)) }
            }
            p.terminationHandler = { [weak self] _ in
                guard let self = self else { return }
                log("stt daemon exited — respawn @2s")
                self.setState { self.daemon = nil; self.dIn = nil; self.sttState = "down" }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { self.startDaemon() }
            }
        } catch {
            log("stt daemon spawn failed: \(error.localizedDescription)")
            setState { sttState = "down" }
        }
    }
    func onDaemonLine(_ s: String) {
        guard !s.isEmpty, let j = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return }
        if j["ready"] as? Bool == true {
            let eng = (j["engine"] as? String) ?? "whisper"
            setState { self.sttState = self.engineMuted ? "muted" : "live"; self.engineName = eng }
            log("stt engine live: \(eng)")
            return
        }
        if let seg = j["seg"] as? Int {
            if let err = j["err"] as? String {
                log("stt seg \(seg) err: \(err)")
                publish("stt", "{\"id\":\(nextId()),\"seg\":\(seg),\"text\":\"\",\"final\":true,\"err\":\(jsonStr(err))}")
                return
            }
            let text = (j["text"] as? String) ?? ""
            let took = (j["took"] as? Double) ?? 0
            let eng = getEngineName()
            setState { self.segsDone += 1 }
            log("stt seg \(seg) result in \(String(format: "%.2f", took))s: \(jsonStr(String(text.prefix(80))))")  // success leaves a receipt
            publish("stt", "{\"id\":\(nextId()),\"seg\":\(seg),\"text\":\(jsonStr(text)),\"final\":true,\"engine\":\(jsonStr(eng)),\"took\":\(took),\"ts\":\(Int(Date().timeIntervalSince1970*1000))}")
            // barge-in: a fresh utterance heard while speaking kills the mouth (§5.1)
            if bargeOn { bblock.lock(); let talking = ttsState == "speaking"; bblock.unlock()
                if talking { barge() } }
        }
    }

    // ---------------- mic tap + VAD (RAM only — §9 zero-disk) ----------------
    func armMic() {
        // ⟦ATOMIC CLAIM⟧ (crash 22:30:44: 'nullptr == Tap()' NSException): the guard used
        // to CHECK micOn and release the lock, setting it true only after the setup
        // gauntlet. Two plugin windows knocked on the same envelope tick, BOTH walked in,
        // BOTH installTapped bus 0 — CoreAudio kills the process for a double tap. The
        // ticket is now TAKEN UNDER THE LOCK; the loser returns, the winner arms.
        bblock.lock(); if micOn { bblock.unlock(); return }; micOn = true; bblock.unlock()
        if !cfgObs { cfgObs = true
            // ⟦CONFIG-CHANGE REFLEX⟧ a device swap resets the input node — tap gone, engine
            // stopped, but our books said armed. Release the claim so the plugin's steady
            // knock re-arms the real ear within seconds: live-state correction, not a corpse.
            NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                object: engine, queue: .main) { [weak self] _ in
                guard let self = self else { return }
                self.bblock.lock(); let was = self.micOn; self.micOn = false; self.bblock.unlock()
                if was { self.setState { self.sttState = "reconfig" }; log("audio device changed — ear released, awaiting knock") }
            }
        }
        let input = engine.inputNode
        // ⟦THE MIC SHALL NOT HEAR THE SPEAKER⟧ no vendor AEC, no opinions: echo-cancel.swift
        // subtracts the WHOLE output from the mic with our own NLMS — the exact samples the
        // taps already carry plus the agent's own bytes, reference before the DAC.
        let fmt = input.inputFormat(forBus: 0)
        let step = max(1, Int(fmt.sampleRate / 16000.0))
        micRate = (fmt.sampleRate / Double(step)).rounded()
        let chN = max(1, Int(fmt.channelCount))
        input.removeTap(onBus: 0)   // belt: one tap per bus, remove first, plant once
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            guard let self = self, let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            var s = [Int16](repeating: 0, count: n / step + 1); var k = 0
            var sumsq = 0.0; var cnt = 0.0
            for i in stride(from: 0, to: n, by: step) {
                var v = 0.0
                for c in 0..<chN { v += Double(ch[c][i]) }
                v /= Double(chN)
                sumsq += v * v; cnt += 1
                s[k] = Int16(max(-1.0, min(1.0, v)) * 32767.0); k += 1
            }
            // ⟦THE MIC SHALL NOT HEAR THE SPEAKER⟧ subtract the entire speaker output —
            // and judge silence on the CANCELLED signal, so the agent never hears itself talk.
            canc.process(&s, k, at: CACurrentMediaTime())
            var cs = 0.0; for j in 0..<k { let v = Double(s[j]); cs += v * v }
            // UNITS LAW: vadThresh is FLOAT (-40 dBFS = 0.010) — the tap's samples are
            // INT16 (the echo surgery moved this path). Compare apples: /32767. Without
            // it every fan is 'voiced', every segment rides the 10.4 s ceiling (2026-10-30).
            self.vad(s, k, k > 0 ? (cs / Double(k)).squareRoot() / 32767.0 : 0)
        }
        if !engine.isRunning { engine.prepare() }
        do { if !engine.isRunning { try engine.start() } } catch {
            log("mic start failed (TCC?): \(error.localizedDescription)")
            setState { micOn = false; sttState = "down" }
            return
        }
        setState { micOn = true; sttState = engineMuted ? "muted" : "live" }
        log("mic armed @\(Int(fmt.sampleRate))Hz -> \(Int(micRate))Hz VAD")
    }
    func disarmMic() {
        bblock.lock(); let was = micOn; micOn = false; bblock.unlock()
        if was {
            engine.inputNode.removeTap(onBus: 0)
            // ⟦ECHO LAW⟧ the engine is now a playback participant too — muting the ear
            // must never mute the mouth. Stop the IO only when nothing is sounding.
            if !playerNode.isPlaying && !(legacy?.isPlaying ?? false) && !speech.isSpeaking { engine.stop() }
        }
        log("mic disarmed")
    }
    func vad(_ s: [Int16], _ n: Int, _ rms: Double) {
        let now = CACurrentMediaTime()
        let voiced = rms > vadThresh
        // card C: feed the return-channel in-ring on the tap thread — 100ms window,
        // RAM only (§9); tiny lock keeps the frame ticker off the audio thread.
        inLock.lock()
        inRing.append(contentsOf: s[0..<n])
        let cap = Int(micRate * 0.1)
        if inRing.count > cap { inRing.removeFirst(inRing.count - cap) }
        inRmsSm = inRmsSm * 0.7 + rms * 0.3
        inLock.unlock()
        if voiced && !segOpen {
            segOpen = true; segStart = now; lastVoice = now
            segBuf = preBuf                       // pre-roll: catch the first phoneme
        }
        if voiced { lastVoice = now }
        segBuf.append(contentsOf: s[0..<n])
        preBuf.append(contentsOf: s[0..<n])
        if preBuf.count > preRollFrames { preBuf.removeFirst(preBuf.count - preRollFrames) }
        if segOpen && (now - lastVoice > vadHangover || now - segStart > maxSeg) {
            closeSegment()
        }
    }
    func closeSegment() {
        guard segOpen else { return }
        segOpen = false
        let samples = segBuf; segBuf = []
        let dur = Double(samples.count) / micRate
        guard dur > 0.35 else { return }        // ignore blips
        segId += 1
        let seg = segId
        feedEngine(seg, pcm16: samples)
        log("vad seg #\(seg) \(String(format: "%.2f", dur))s -> stt")
    }
    // base64 WAV over the stdio pipe — never disk. Pipe writes off the audio thread.
    func feedEngine(_ seg: Int, pcm16: [Int16]) {
        bblock.lock(); let h = dIn; bblock.unlock()
        guard let h = h else { return }
        var wav = Data(wavHeader(Int32(pcm16.count * 2), Int32(micRate)))
        pcm16.withUnsafeBytes { wav.append(contentsOf: $0) }
        let line = "{\"seg\":\(seg),\"wav\":\"\(wav.base64EncodedString())\"}\n"
        whisperQ.async { h.write(Data(line.utf8)) }
    }
    func wavHeader(_ dataLen: Int32, _ rate: Int32) -> [UInt8] {
        func u32(_ v: Int32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
        func u16(_ v: Int16) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
        var h: [UInt8] = []
        h += Array("RIFF".utf8); h += u32(36 + dataLen); h += Array("WAVE".utf8)
        h += Array("fmt ".utf8); h += u32(16); h += u16(1); h += u16(1)
        h += u32(rate); h += u32(rate * 2); h += u16(2); h += u16(16)
        h += Array("data".utf8); h += u32(dataLen)
        return h
    }

    // ---------------- HTTP surface (hooked from orbit-sidecar handle()) ----------------
    // returns true if consumed
    func handle(_ conn: NWConnection, _ method: String, _ path: String, _ req: String) -> Bool {
        if path == "/b/stream" || path.hasPrefix("/b/stream?") {
            // ⟦EPOCH-TRUTH⟧ the b-stream shares the visualizer identity: once an epoch>0
            // claim exists, bootless legacy streams and superseded boots are 410'd fatally,
            // so leaked pre-guard /b/stream sockets get torn down BY THE BROWSER instead of
            // squatting Chromium's six-per-host pool (the "no now-playing after reload" law).
            var role = ""; var boot = ""; var epoch: Double = 0
            if let qi = path.firstIndex(of: "?") {
                for kv in path[path.index(after: qi)...].split(separator: "&") {
                    let p = kv.split(separator: "=", maxSplits: 1)
                    if p.count == 2 {
                        let v = String(p[1]).removingPercentEncoding ?? String(p[1])
                        if p[0] == "role" { role = v }; if p[0] == "boot" { boot = v }
                        if p[0] == "epoch" { epoch = Double(v) ?? 0 }
                    }
                }
            }
            if curClaim().1 > 0 {
                if role != "doctor" {
                    let cc = curClaim()
                    if boot.isEmpty { goneResp(conn); return true }
                    if epoch <= cc.1 && boot != cc.0 { goneResp(conn); return true }
                }
            }
            send(conn, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: keep-alive\r\n\r\n")
            bblock.lock(); sseConns.append(conn); bblock.unlock()
            streamRegLock.lock(); streamReg.append((conn, boot, epoch, role)); streamRegLock.unlock()
            publish("b-hello", statusJSON())
            return true
        }
        if path == "/b/status" { httpResp(conn, "200 OK", "application/json", statusJSON()); return true }
        if method == "POST" && path == "/b/tts" { beginTTS(conn, req); return true }
        if method == "POST" && path == "/b/tts/speak" { oneShot(conn, req); return true }
        if method == "POST" && path == "/b/mode" { mode(conn, req); return true }
        if method == "POST" && path == "/b/inject" { inject(conn, req); return true }
        return false
    }

    // ---- provider-TTS config transport (card B contract) ----
    // Per-request headers (plugin = config authority, §1). Every turn RESETS to env
    // defaults first, so a config change is live on the next request and a plugin
    // that stops sending headers drops the sidecar back to LEVEL 2 — stale creds
    // never outlive the turn that sent them. Key is never logged nor surfaced.
    func headValue(_ head: String, _ name: String) -> String {
        guard let r = head.range(of: name + ":", options: .caseInsensitive) else { return "" }
        // CR is an ICU grapheme quirk on String.firstIndex(of:) — scan UTF-8 bytes instead
        let tail = head[r.upperBound...].utf8
        let end = tail.firstIndex(of: 0x0D) ?? tail.firstIndex(of: 0x0A) ?? tail.endIndex
        return String(decoding: tail[tail.startIndex..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
    func applyProviderHeaders(_ head: String) {
        setState { pBase = envBase; pKey = envKey; pModel = envModel }
        let hv = headValue(head, "X-Orbit-Voice")
        if !hv.isEmpty { setState { voiceOverride = hv } }
        let tb = headValue(head, "X-Orbit-TTS-Base")
        let tk = headValue(head, "X-Orbit-TTS-Key")
        let tm = headValue(head, "X-Orbit-TTS-Model")
        setState { if !tb.isEmpty { pBase = tb }; if !tk.isEmpty { pKey = tk }; if !tm.isEmpty { pModel = tm } }
    }

    // ---- TTS in: streamed JSONL body, consumed incrementally ----
    func beginTTS(_ conn: NWConnection, _ head: String) {
        applyProviderHeaders(head)
        bblock.lock(); streamOpen = true; lastByte = CACurrentMediaTime()
        ttsConn = conn; ttsEOF = false; ttsAcked = false
        ttsChunk = head.range(of: "Transfer-Encoding:", options: .caseInsensitive) != nil ? ChunkDecoder() : nil
        // card C: a /b/tts request OPENS a turn — b-timing phases (start/first_audio/end).
        turnN += 1; turnStart = CACurrentMediaTime()
        turnSpokenBase = spoken; firstAudioDone = false; firstLatencyMs = -1
        turnMode = ""; lastSynthMs = 0
        let tN = turnN
        bblock.unlock()
        timing("start", tN, [])
        // Headers only — the response BODY completes when the TURN completes.
        // No Content-Length: client reads until we close after the last sentence
        // plays (fetch-based renderers block on that; the ack IS the end-of-turn).
        send(conn, "HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nConnection: keep-alive\r\n\r\n")
        if let sep = head.range(of: "\r\n\r\n") {   // body bytes already in first recv
            feedTTSBytes(Data(String(head[sep.upperBound...]).utf8))
        }
        pullTTS(conn)
    }
    func pullTTS(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, err in
            guard let self = self else { return }
            if let d = data, !d.isEmpty { self.feedTTSBytes(d) }
            // FIN semantics in Network.framework: after a client half-close the flag may
            // surface on the NEXT receive (nil data), not the one that carried the last
            // bytes. Treat empty-delivery as EOF too — never re-arm into a dead socket.
            if isComplete || err != nil || data == nil || data!.isEmpty {
                self.bblock.lock(); self.streamOpen = false; self.ttsChunk = nil; self.ttsEOF = true
                if let tail = String(data: self.ttsBuf, encoding: .utf8) { self.pending += tail }
                self.ttsBuf = Data()
                let rest = self.pending; self.pending = ""; let qEmpty = self.queued.isEmpty; let talking = self.speech.isSpeaking || (self.player?.isPlaying ?? false); self.bblock.unlock()
                if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { self.enqueue(rest) }
                // empty turn (or everything already spoken): ack now, else ack in speakNext/pump
                if qEmpty && !talking { self.ackTTS() }
                return
            }
            self.pullTTS(conn)
        }
    }
    func feedTTSBytes(_ d0: Data) {
        var d = d0
        bblock.lock(); let dec = ttsChunk; bblock.unlock()
        if let dec = dec { d = dec.feed(d0) }
        guard !d.isEmpty else { return }
        bblock.lock()
        lastByte = CACurrentMediaTime()
        ttsBuf.append(d)                       // byte-level line framing: CRLF-proof
        var lines: [String] = []
        while let nl = ttsBuf.firstIndex(of: 0x0A) {
            if let s = String(data: ttsBuf[ttsBuf.startIndex..<nl], encoding: .utf8) { lines.append(s) }
            ttsBuf.removeSubrange(ttsBuf.startIndex...nl)
        }
        bblock.unlock()
        for ln in lines { ingestLine(ln) }
    }
    func ingestLine(_ ln: String) {
        let t = ln.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if t.hasPrefix("{") {
            guard let j = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any] else { enqueue(t); return }
            if j["barge"] as? Bool == true { barge(); return }
            if let d = j["d"] as? String { accumulate(d) }
            if j["final"] as? Bool == true {
                flushPending(true)
                // PROTOCOL end-of-turn — authoritative. TCP isComplete does NOT fire
                // on keep-alive (curl) and may not fire at the chunk terminator either;
                // the client says "final" when the turn's text is done. Ack + close.
                bblock.lock(); ttsEOF = true; streamOpen = false; let qEmpty = queued.isEmpty; let talking = speech.isSpeaking || playerNode.isPlaying || (legacy?.isPlaying ?? false) || (afProc?.isRunning ?? false); bblock.unlock()
                if qEmpty && !talking { ackTTS() }   // else the delegate/pump acks when the queue drains
                return
            }
        } else {
            accumulate(ln)   // raw text mode: lines close sentences
        }
    }
    func accumulate(_ s: String) {
        bblock.lock(); pending += s; lastByte = CACurrentMediaTime(); bblock.unlock()
        flushSentences()
    }
    func flushSentences() {
        while true {
            bblock.lock()
            let cs = Array(pending)
            var idx = -1
            for i in 0..<cs.count where cs[i] == "." || cs[i] == "!" || cs[i] == "?" || cs[i] == "\n" { idx = i }
            if idx < 0 { bblock.unlock(); return }
            let sent = String(cs[0...idx]); pending.removeFirst(idx + 1)
            bblock.unlock()
            enqueue(sent)
        }
    }
    func flushPending(_ force: Bool) {
        bblock.lock(); let rest = pending; pending = ""; bblock.unlock()
        if force, !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { enqueue(rest) }
    }
    func enqueue(_ s: String) {
        let c = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard c.count >= 2 else { if !c.isEmpty { log("enqueue DROP <2ch: \"\(c)\"") }; return }
        bblock.lock(); queued.append(c); bblock.unlock()
        speakNext()
    }
    func speakNext() {
        bblock.lock()
        if ttsState == "speaking" {
            // a queue waiting behind a 'speaking' that never ends = the wedge we keep
            // finding blind (2026-10-30). Name it: queued depth + how long it's held.
            if !queued.isEmpty {
                let held = CACurrentMediaTime() - uttStart
                if held > 3 { log("speakNext DENY: state=speaking held \(String(format: "%.1f", held))s queued=\(queued.count)") }
            }
            bblock.unlock(); return
        }
        guard !queued.isEmpty else {
            ttsState = "idle"; let eof = ttsEOF; bblock.unlock(); unduckOrResume()
            outFlip(false, "")   // card C: end-of-speech flip (agent.speaking → false)
            if eof { ackTTS() }   // last sentence just played → end the turn, close the request
            return
        }
        let s = queued.removeFirst()
        ttsState = "speaking"
        uttGen += 1; let gen = uttGen
        uttStart = CACurrentMediaTime()
        let v = voiceOverride
        let base = pBase, key = pKey, model = pModel
        // stuck-fuse: AVSpeech at rate 0.5 runs ~0.19s/char; provider mode gets the
        // synth budget ON TOP of the playback estimate
        uttDeadline = CACurrentMediaTime() + Double(s.count) * 0.19 + (base.isEmpty ? 0 : synthTimeout) + 5.0
        bblock.unlock()
        duckOrPause()   // ⟦VOICE OWNS THE MIX⟧ policy layer: spoken content PAUSES, music ducks, silence stays silent
        bblock.lock(); spoken += 1; bblock.unlock()
        if !base.isEmpty, !model.isEmpty {
            // LEVEL 1 (§1): synthesize with the CONFIGURED provider voice, play the
            // returned audio. Blocking HTTP on a worker; playback advances the queue
            // through AVAudioPlayerDelegate — same drain semantics as the AVSpeech path.
            bblock.lock(); synthInFlight += 1; bblock.unlock()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                let done = { self.bblock.lock(); self.synthInFlight -= 1; self.bblock.unlock() }
                if let d = self.providerSynth(base, key, model, v, s) {
                    self.bblock.lock(); let alive = (self.ttsState == "speaking" && self.uttGen == gen); self.bblock.unlock()
                    if !alive { done(); return }   // barged mid-synth: bytes die, the new turn owns the mouth
                    // AVAudioPlayer delegate callbacks need the CREATING thread's run
                    // loop — GCD workers have none. Create + play on main (RunLoop.main
                    // runs in orbit-sidecar.swift; didFinishPlaying drives the drain).
                    let sem = DispatchSemaphore(value: 0)
                    var ok = false
                    DispatchQueue.main.async {
                        ok = self.playAudio(d); sem.signal()
                    }
                    if sem.wait(timeout: .now() + 10) == .timedOut || !ok {
                        // main wedged or decode failed — fall through to LEVEL 2
                    } else { done(); return }
                }
                // LEVEL 2 (§1): provider missing/broken → OS default, flagged in status + ack
                self.bblock.lock()
                if self.ttsState != "speaking" || self.uttGen != gen { self.bblock.unlock(); done(); return }
                self.providerErrs += 1; self.lastMode = "avspeech"
                self.bblock.unlock()
                done()
                log("provider TTS unavailable — LEVEL-2 AVSpeech fallback (voice=\(v))")
                self.fallbackSpeak(s, v)
            }
        } else {
            // no provider/voice selection at all → LEVEL-2 OS default (§1: AVSpeech is last resort)
            setState { lastMode = "avspeech" }
            log("no provider TTS configured — LEVEL-2 AVSpeech (voice=\(v.isEmpty ? "system" : v))")
            fallbackSpeak(s, v)
        }
    }
    func fallbackSpeak(_ s: String, _ v: String) {
        let u = AVSpeechUtterance(string: s)
        u.rate = 0.5
        if !v.isEmpty, let voice = AVSpeechSynthesisVoice(identifier: v) { u.voice = voice }
        bblock.lock(); uttDeadline = CACurrentMediaTime() + Double(s.count) * 0.19 + 4.0; bblock.unlock()
        // AVSpeech delegate callbacks need the main runloop — pullTTS runs on NWConnection queue
        DispatchQueue.main.async { [weak self] in guard let self = self else { return }
            self.speech.speak(u)
            // card C: LEVEL-2 has no accessible PCM — the flip is honest:
            // speaking=true, empty waveform. The lamp keys off 'speaking'.
            self.outFlip(true, "avspeech")
            self.firstAudio("avspeech")
        }
    }
    // LEVEL-1 synth: OpenAI-compatible POST {base}/v1/audio/speech → WAV in RAM.
    func providerSynth(_ base0: String, _ key: String, _ model: String, _ voice: String, _ text: String) -> Data? {
        var u = base0
        while u.hasSuffix("/") { u.removeLast() }
        // base may arrive as host:port or host:port/v1 (renderer voiceCfg carries /v1) —
        // never stack a second /v1; that 404 silently made every provider turn an OS turn
        let path = u.hasSuffix("/v1") ? "/audio/speech" : "/v1/audio/speech"
        guard let url = URL(string: u + path) else { log("provider: bad base URL"); return nil }
        var req = URLRequest(url: url, timeoutInterval: synthTimeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { req.setValue("Bearer " + key, forHTTPHeaderField: "Authorization") }
        // voice optional by contract: Qwen3-TTS-Base has no roster (random-voice IS its
        // selection) — sending "" 400s; omitting it lets Base be Base
        var body: [String: Any] = ["model": model, "input": text, "response_format": "wav"]
        if !voice.isEmpty { body["voice"] = voice }
        req.httpBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        var data: Data?; var code = 0; var ct = ""; var e: Error?
        let synthT0 = CACurrentMediaTime()   // card C: synth_ms telemetry
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, er in
            data = d; e = er
            if let h = r as? HTTPURLResponse { code = h.statusCode; ct = h.value(forHTTPHeaderField: "Content-Type") ?? "" }
            sem.signal()
        }.resume()
        if sem.wait(timeout: .now() + synthTimeout + 2) == .timedOut { log("provider synth timeout (\(u))"); return nil }
        let synthMs = (CACurrentMediaTime() - synthT0) * 1000
        guard e == nil, code == 200, let d = data, d.count > 44 else {
            log("provider synth failed http=\(code) bytes=\(data?.count ?? 0) err=\(e?.localizedDescription ?? "-")")
            return nil
        }
        let riff = Array(d.prefix(4)) == Array("RIFF".utf8)
        if !riff && !ct.lowercased().contains("audio") { log("provider returned non-audio (ct=\(ct.prefix(40)))"); return nil }
        setState { lastMode = "provider"; lastSynthMs = synthMs }
        log("provider synth ok: model=\(model) voice=\(voice) bytes=\(d.count)")
        bblock.lock(); let dd = dumpDir; bblock.unlock()
        if !dd.isEmpty {   // opt-in evidence hook (off by default — §9 zero-disk law)
            let p = dd + "/tts-prov-\(Int(Date().timeIntervalSince1970 * 1000)).wav"
            try? FileManager.default.createDirectory(atPath: dd, withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: p))
            log("dumped provider audio → \(p)")
        }
        return d
    }
    // ⟦LOUDNESS LAW⟧ Provider streams arrive light (measured Kokoro 2026-10-30: peak −6.6 dBFS,
    // RMS −22.1) — every dB of that is room-filling headroom left on the table. Normalize the
    // in-RAM PCM to ~−1 dBFS peak, cap +11 dB, never cut, never clip: pure gain on bytes that
    // are already in RAM (zero audio-graph change, §9 zero-disk intact). AVSpeech LEVEL-2 owns
    // its own engine levels — untouched. With the app-level duck the master never moves, so
    // this gain IS the voice; in master mode it reclaims exactly what the floor takes.
    static func normalizeWav16(_ d: Data) -> Data {
        // ⟦REPAIR, DON'T JUST READ⟧ (2026-10-31, the last bone in the night): we KNEW
        // oMLX writes the sample rate into wFormatTag (0x5DC0 = 24000, a field lie),
        // and we forgave the lie for OUR parser — then handed the still-broken header
        // to AVAudioPlayer, whose decoder checks the tag, throws, and — behind a try? —
        // dies without a sound. Leniency that never fixes the bytes is just failure
        // scheduled later. The output of this function must be a VALID WAV, always.
        guard d.count > 64, Array(d.prefix(4)) == Array("RIFF".utf8), Array(d[8..<12]) == Array("WAVE".utf8) else { return d }
        var off = 12, dataOff = -1, dataLen = 0, bits = 0, isPCM = false, fmtOff = -1
        while off + 8 <= d.count {
            let sz = Int(UInt32(d[off+4]) | UInt32(d[off+5]) << 8 | UInt32(d[off+6]) << 16 | UInt32(d[off+7]) << 24)
            if Array(d[off..<off+4]) == Array("fmt ".utf8), off + 26 <= d.count {
                let tag = Int(d[off+12]) | Int(d[off+13]) << 8
                bits = Int(d[off+22]) | Int(d[off+23]) << 8
                if tag != 1 { fmtOff = off }                     // the tag lies; remember where
                if tag == 0xFFFE { isPCM = d[off+24] == 1 }        // extensible: SubFormat GUID LSB
                else { isPCM = tag != 3 && tag != 0x0055 }          // float/MP3 aren't; oMLX writes 0x5DC0 (the SAMPLE RATE!) in the tag — proven 16-bit LE, AudioToolbox plays it
            } else if Array(d[off..<off+4]) == Array("data".utf8) {
                dataOff = off + 8; dataLen = min(sz, d.count - dataOff)
            }
            if sz <= 0 || off + 8 + sz > d.count + 1 { break }
            off += 8 + sz + (sz & 1)
        }
        guard isPCM, bits == 16, dataOff >= 0, dataLen >= 2 else { return d }
        var out = d
        if fmtOff >= 0 {
            out[fmtOff+12] = 1; out[fmtOff+13] = 0                // wFormatTag := 1 — PCM, the truth
            if fmtOff + 24 <= out.count && out[fmtOff+24] != 1 { out[fmtOff+24] = 1 }  // SubFormat GUID LSB too, if extensible
            log("normalizeWav16: repaired bogus wFormatTag → PCM(1)")
        }
        var peak = 1; var i = dataOff
        while i + 1 < dataOff + dataLen {
            let s = Int16(bitPattern: UInt16(d[i]) | (UInt16(d[i+1]) << 8))
            if abs(Int(s)) > peak { peak = abs(Int(s)) }
            i += 2
        }
        let gain = min(3.5, 29500.0 / Double(max(peak, 900)))
        guard gain > 1.05 else { return out }
        i = dataOff
        while i + 1 < dataOff + dataLen {
            let s = Int16(bitPattern: UInt16(d[i]) | (UInt16(d[i+1]) << 8))
            var v = Int((Double(s) * gain).rounded())
            if v > 32767 { v = 32767 }; if v < -32768 { v = -32768 }
            let u = UInt16(bitPattern: Int16(truncatingIfNeeded: v))
            out[i] = UInt8(truncatingIfNeeded: u); out[i+1] = UInt8(truncatingIfNeeded: u >> 8)
            i += 2
        }
        log("normalizeWav16: peak \(peak) gain ×\(String(format: "%.2f", gain))")
        return out
    }
    // drain after one provider sentence: advance the queue (same discipline as the
    // AVAudioPlayer delegate — generation-checked so a barge stays silent)
    func nodeDone(_ gen: Int) {
        bblock.lock(); renderAlive = CACurrentMediaTime(); bblock.unlock()
        bblock.lock(); let alive = (ttsState == "speaking" && uttGen == gen); bblock.unlock()
        guard alive else { return }
        log("tts done (provider) — echo-cancel: \(canc.reportAndReset())")
        setState { if playerNode.isPlaying || player != nil { player = nil } }
        DispatchQueue.main.async { self.speakNext() }
    }
    // ⟦RENDER RECEIPT⟧: play() claims, nodeDone proves — completion stamps the
    // render clock, and the watchdog names a dead render out loud instead of glowing.
    func playAudio(_ raw: Data) -> Bool {
        let d = Self.normalizeWav16(raw)
        log("playAudio: \(d.count) bytes, main-thread=\(Thread.isMainThread) echo=\(canc.active ? "nlms" : "idle")")
        let (pcm, rate) = Self.pcm16(fromWAV: d)
        // SCHEDULE STEREO, THE ENGINE'S LANGUAGE: the output path renders stereo, and
        // scheduleBuffer THROWS the channel-mismatch NSException (caught live 2026-10-30:
        // every provider sentence killed the process mid-syllable). Mono source fans to
        // both channels; the canceller still references the mono source — that's physics.
        // ⟦THE DAC IS THE MOUTH⟧ (2026-10-31, end of the long night): every engine-node
        // attempt tonight — live-connect, detach-clean, stop-wire-restart — ended the same
        // way: silent false or an abort inside engine calls, on the very thread that owns
        // the ear's tap, with the tap world half-alive around it. Meanwhile AVAudioPlayer
        // decoded the SAME WAV and PLAYED it on every corpse of this process, at native
        // rate now that the WAV's own header carries the sample rate. So the proven path
        // speaks first; the echo-cancelled node graph is an upgrade we only promote to
        // when it is healthy, from a background queue, never again from main.
        if true {                                        // named block: Swift binds bare `}{` as glue
            let path = "/tmp/.orbit_speak_\(getpid()).wav"
            do { try d.write(to: URL(fileURLWithPath: path)) }
            catch { log("afplay WAV write failed: \(error.localizedDescription)") }
            if FileManager.default.fileExists(atPath: path) {
                let pr = Process()
                pr.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
                pr.arguments = [path]
                bblock.lock(); let gen = uttGen; bblock.unlock()
                pr.terminationHandler = { [weak self] p2 in
                    try? FileManager.default.removeItem(atPath: path)
                    log("afplay mouth exited status=\(p2.terminationStatus)")
                    if p2.terminationStatus == 0 { self?.nodeDone(gen) }   // on-time exit IS completion
                }
                do {
                    try pr.run()
                    setState { afProc = pr; outPcm = pcm; outRate = Double(rate); outT0 = CACurrentMediaTime() }
                    canc.pushRef(pcm, fromRate: Double(rate), at: CACurrentMediaTime() + 0.05)  // echo ref: its OWN samples
                    outFlip(true, "provider")
                    firstAudio("provider")
                    log("provider playback via afplay mouth: dur=\(String(format: "%.1f", Double(pcm.count) / Double(rate)))s @\(Int(rate))Hz")
                    return true
                } catch { log("afplay spawn failed: \(error.localizedDescription)") }
            }
        }
        if pcm.count > 0, let buf = AVAudioPCMBuffer(pcmFormat: nodeFormat(Double(rate)), frameCapacity: AVAudioFrameCount(pcm.count)) {
            buf.frameLength = AVAudioFrameCount(pcm.count)
            if let ch = buf.floatChannelData {
                let scale: Float = 1.0 / 32768.0
                for i in 0..<pcm.count { let v = Float(pcm[i]) * scale; ch[0][i] = v; ch[1][i] = v }
            }
            let wantAF = nodeFormat(Double(rate))
            // WIRE BEFORE DRIVE: attach + connect happen while the engine is stopped —
            // starting FIRST is what crashed every spoken answer (player play() on a node
            // connected after the graph froze). Start only AFTER the player is connected.
            var reArmEar = false
            if !nodeAttached {
                // ⟦THE ACTUAL LAW, LEARNED THE EXPENSIVE WAY⟧ (three 'fixes' died in the
                // SAME exception tonight): the safe moment to change an AVAudioEngine node
                // graph is when the engine is STOPPED. attach-vs-running games (live
                // connect, detach-clean) all left the node disconnected-in-fact, and
                // play() threw 'player started when in a disconnected state' every time.
                // So: STOP the engine, wire the node while nothing renders, RESTART the
                // engine — always, never short-circuited — and re-arm the ear's tap on the
                // same honest path. Slower by milliseconds, silent by zero.
                if engine.isRunning { engine.stop(); reArmEar = micOn }
                engine.detach(playerNode)
                engine.attach(playerNode)
                engine.connect(playerNode, to: engine.mainMixerNode, format: wantAF)
                nodeAttached = true; nodeRate = Double(rate)
                log("playback graph rewired while stopped")
            }
            else if nodeRate != Double(rate) {
                playerNode.stop(); engine.detach(playerNode); engine.attach(playerNode)
                engine.connect(playerNode, to: engine.mainMixerNode, format: wantAF); nodeRate = Double(rate)
                log("playback node reformat via detach: \(Int(nodeRate))Hz stereo")
            }
            if !engine.isRunning {
                engine.prepare()
                do { try engine.start() } catch { log("playback engine start failed: \(error.localizedDescription) — legacy player, echo NOT cancelled") }
                if !engine.isRunning { log("engine refused to start (isRunning=false after start attempt) — falling to legacy DAC path") }
                if reArmEar && engine.isRunning {
                    bblock.lock(); micOn = false; bblock.unlock(); armMic()
                    log("rewire restarted the engine and re-armed the ear")
                }
            }
            if engine.isRunning {
                bblock.lock(); let gen = uttGen; bblock.unlock()
                playerNode.stop()
                // ⟦THE WALL-CLOCK TRUTH⟧ (2026-10-30): the engine renders — the ear's tap
                // proves it every second — but playerNode's completion callback NEVER FIRES
                // on this aggregate: tts done stayed silent, the mouth stayed 'speaking',
                // the speaker lamp burned forever, and every next sentence queued behind a
                // ghost. So we stop trusting the callback and trust the CLOCK: the buffer's
                // duration is known, play() just started; the watchdog declares the sentence
                // DONE when the clock says it is. Callback still wins if it ever shows up.
                playerNode.scheduleBuffer(buf, at: nil, options: []) { [weak self] in self?.nodeDone(gen) }
                playerNode.play()
                setState { nodeEnds = CACurrentMediaTime() + Double(pcm.count) / Double(rate) + 0.35 }
                canc.pushRef(pcm, fromRate: Double(rate), at: CACurrentMediaTime() + 0.015)  // echo ref: its OWN samples
                setState { player = playerNode; outPcm = pcm; outRate = Double(rate); outT0 = CACurrentMediaTime() }
                outFlip(true, "provider")
                firstAudio("provider")
                log("provider playback via engine node: dur=\(String(format: "%.1f", Double(pcm.count) / Double(rate)))s wf=\(pcm.count)@\((Int(rate)))Hz echo=\(canc.active ? "nlms" : "idle")")
                return true
            }
        }
        // legacy path (engine unavailable) — audible but echo uncancelled, said out loud above
        // ⟦THE MOUTH SHALL NOT BE AVSPEECH WHEN WAV EXISTS⟧ (2026-10-30, 00:30): the
        // engine-node graph needs the input-side tap world alive to render; a daemon whose
        // engine refuses to start used to fall to AVSpeech — a second voice, a second set
        // of failure modes, and a silent speaker that still glowed. AVAudioPlayer needs
        // NONE of it: HAL writes, no graph, no tap — it played at chipmunk speed while the
        // engine was comatose. So when the engine is down, the WAV itself is the mouth.
        let p: AVAudioPlayer
        do { p = try AVAudioPlayer(data: d) } catch { log("provider audio decode failed: \(error.localizedDescription)"); return false }
        p.delegate = self
        guard p.prepareToPlay(), p.play() else { log("provider playback start failed"); return false }
        setState { legacy = p; outPcm = pcm; outRate = Double(rate); outT0 = CACurrentMediaTime() }
        outFlip(true, "provider")
        firstAudio("provider")
        log("provider playback started (legacy): dur=\(String(format: "%.1f", p.duration))s wf=\(pcm.count)@\((Int(rate)))Hz")
        return true
    }
    func ackTTS() {
        // Final ack for a completed streamed turn. The 202 headers went out at
        // beginTTS with no Content-Length → body is "read until close": write the
        // ack JSON, then close. The client's response-promise resolves here = end-of-turn.
        bblock.lock()
        guard !ttsAcked, ttsEOF, let conn = ttsConn else { bblock.unlock(); return }
        // Card B hardening: provider synth is async — between dequeue and playAudio both
        // mouths are silent with an empty queue while audio is IN FLIGHT. The turn state
        // (idle) is the only sound "nothing pending" signal; a lost delegate is recovered
        // by the pump (flips stuck-speaking → idle → speakNext → drain → this fires).
        guard queued.isEmpty, ttsState == "idle", synthInFlight == 0, !speech.isSpeaking, !playerNode.isPlaying, !(legacy?.isPlaying ?? false) else { bblock.unlock(); return }
        ttsAcked = true; ttsConn = nil; ttsEOF = false; streamOpen = false
        let n = spoken; let md = lastMode
        let tN = turnN; let tBase = turnSpokenBase; let tStart = turnStart; let tMode = turnMode
        turnStart = 0
        bblock.unlock()
        outFlip(false, "")   // card C: belt-and-braces — EVERY close path (pump belt, stale
                             // EOF, delegate drain) ends with the mouth closed, before the ack.
                             // Edge-triggered: harmless if speakNext already flipped.
        // "mode" = provenance for the plugin's switch predicate (card B): provider
        // audio actually played, or LEVEL-2 AVSpeech. Never treat avspeech as configured.
        send(conn, "{\"accepted\":true,\"spoken\":\(n),\"done\":true,\"mode\":\(jsonStr(md))}")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { conn.cancel() }
        // card C: close the turn's timing telemetry (phase=end on b-timing)
        if tStart > 0 {
            bblock.lock(); let fl = firstLatencyMs; bblock.unlock()
            timing("end", tN, ["\"total_ms\":\(Int((CACurrentMediaTime() - tStart) * 1000))",
                               "\"sentences\":\(n - tBase)", "\"mode\":\(jsonStr(tMode.isEmpty ? md : tMode))",
                               "\"first_audio_ms\":\(Int(fl))"])
        }
    }
    func barge() {
        bblock.lock(); queued.removeAll(); ttsState = "idle"; uttGen += 1
        let p = player; let lg = legacy; outPcm = []; outT0 = 0; bblock.unlock()
        speech.stopSpeaking(at: .immediate)
        playerNode.stop(); p?.stop(); lg?.stop()
        unduckOrResume()  // barged mid-turn: the podcast we paused deserves its voice back
        outFlip(false, "")   // card C: the mouth went silent mid-turn
        log("barge-in — mouth cleared")
    }

    func oneShot(_ conn: NWConnection, _ req: String) {
        applyProviderHeaders(req)   // card B: one-shot path carries the same provider contract
        var text = ""
        if let sep = req.range(of: "\r\n\r\n") {
            let body = String(req[sep.upperBound...])
            if let j = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
               let t = j["text"] as? String {
                if j["barge"] as? Bool == true { barge() }
                text = t
            } else { text = body }
        }
        httpResp(conn, "202 Accepted", "application/json", "{\"queued\":true}")
        log("oneShot: \"\(String(text.prefix(40)))\" base=\(pBase.isEmpty ? "UNSET" : "set") model=\(pModel.isEmpty ? "unset" : pModel)")
        enqueue(text)
    }
    func mode(_ conn: NWConnection, _ req: String) {
        var stt: Bool? = nil
        if let sep = req.range(of: "\r\n\r\n"),
           let j = try? JSONSerialization.jsonObject(with: Data(req[sep.upperBound...].utf8)) as? [String: Any] {
            stt = j["stt"] as? Bool
            if let dd = j["dump"] as? String { setState { dumpDir = dd }; log("provider dump → \(dd.isEmpty ? "off" : dd)") }   // card B evidence hook
        }
        if let s = stt {
            engineMuted = !s
            if s { armMic(); setState { sttState = "live" } }
            else { disarmMic(); setState { sttState = "muted" } }
        }
        httpResp(conn, "200 OK", "application/json", statusJSON())
    }
    func inject(_ conn: NWConnection, _ req: String) {
        // test hook: {"seg":n,"wav":"b64"} straight into the engine pipe, bypass mic
        guard let sep = req.range(of: "\r\n\r\n") else { httpResp(conn, "400 Bad Request", "text/plain", "bad"); return }
        let head = String(req[..<sep.lowerBound])
        var body = Data(req[sep.upperBound...].utf8)
        var want = 0
        var chunked = false
        for ln in head.components(separatedBy: "\n") {   // CRLF-safe: split("\n") won't match \r\n grapheme clusters
            let l = ln.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if l.hasPrefix("content-length:") { want = Int(l.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0 }
            if l.hasPrefix("transfer-encoding:") && l.contains("chunked") { chunked = true }
        }
        log("inject: want=\(want) have=\(body.count) chunked=\(chunked)")
        if chunked {
            // agentic stream: chunk-framed; decode until terminator, then feed
            let dec = ChunkDecoder()
            var acc = dec.feed(body)
            func pullC() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, err in
                    if let dd = data { acc.append(dec.feed(dd)) }
                    if dec.isDone || isComplete || err != nil {
                        httpResp(conn, "202 Accepted", "application/json", "{\"injected\":true}")
                        Self.feedInject(acc)
                        return
                    }
                    pullC()
                }
            }
            if dec.isDone {
                httpResp(conn, "202 Accepted", "application/json", "{\"injected\":true}")
                Self.feedInject(acc)
            } else { pullC() }
            return
        }
        if want > body.count {
            collect(conn, need: want, into: &body) { payload in
                httpResp(conn, "202 Accepted", "application/json", "{\"injected\":true}")
                Self.feedInject(payload)
            }
        } else {
            httpResp(conn, "202 Accepted", "application/json", "{\"injected\":true}")
            Self.feedInject(body)
        }
    }
    // ---- /ctl command surface (control-plane v1) ----
    // Same verbs and state paths as the legacy /b/mode, /b/inject, /b/tts/speak
    // handlers above, driven from one JSON dispatch instead of raw HTTP bodies.
    // Legacy endpoints stay untouched (thin-alias transition window).
    func ctlMode(_ args: [String: Any]) -> (Bool, String) {          // == POST /b/mode
        if let dd = args["dump"] as? String { setState { dumpDir = dd }; log("provider dump → \(dd.isEmpty ? "off" : dd)") }
        if let s = args["stt"] as? Bool {
            engineMuted = !s
            if s { armMic(); setState { sttState = "live" } }
            else { disarmMic(); setState { sttState = "muted" } }
        }
        return (true, statusJSON())
    }
    func ctlMicMute(_ args: [String: Any]) -> (Bool, String) {       // mic-mute == /b/mode {"stt":!mute}
        let mute = (args["mute"] as? Bool) ?? ((args["on"] as? Bool).map { !$0 }) ?? true
        engineMuted = mute
        if mute { disarmMic(); setState { sttState = "muted" } } else { armMic(); setState { sttState = "live" } }
        return (true, statusJSON())
    }
    func ctlInject(_ args: [String: Any]) -> (Bool, String) {        // == POST /b/inject
        guard let d = try? JSONSerialization.data(withJSONObject: args) else { return (true, "{\"injected\":false}") }
        Self.feedInject(d)   // validates {seg,wav}, logs on bad payload — same contract as /b/inject
        return (true, "{\"injected\":true}")
    }
    func ctlSpeak(_ args: [String: Any]) -> (Bool, String) {         // == POST /b/tts/speak
        guard let t = args["text"] as? String, !t.isEmpty else { return (false, "bad-args") }
        if args["barge"] as? Bool == true { barge() }
        enqueue(t)
        return (true, "{\"queued\":true}")
    }
    func collect(_ conn: NWConnection, need: Int, into acc: inout Data, done: @escaping (Data) -> Void) {
        // need = TOTAL Content-Length bytes; accumulate until complete (single reader on conn)
        var work = acc
        func pull() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, complete, err in
                if let dd = d { work.append(dd) }
                if work.count >= need || complete || err != nil { done(work); return }
                pull()
            }
        }
        pull()
    }
    static func feedInject(_ body: Data) {
        log("inject: feed \(body.count) bytes")
        guard let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let seg = j["seg"] as? Int, let b64 = j["wav"] as? String,
              let raw = Data(base64Encoded: b64) else { log("inject: bad payload"); return }
        let (pcm, rate) = pcm16(fromWAV: raw)
        guard !pcm.isEmpty else { log("inject: no PCM"); return }
        var wav = Data(wavHeaderStatic(Int32(pcm.count * 2), Int32(rate)))
        pcm.withUnsafeBytes { wav.append(contentsOf: $0) }
        if ProcessInfo.processInfo.environment["ORBIT_DEBUG_DUMP"] != nil { try? wav.write(to: URL(fileURLWithPath: "/tmp/orbit-inject-\(seg).wav")) }
        let line = "{\"seg\":\(seg),\"wav\":\"\(wav.base64EncodedString())\"}\n"
        ChannelB.shared.bblock.lock(); let h = ChannelB.shared.dIn; ChannelB.shared.bblock.unlock()
        guard let h = h else { log("inject: engine pipe closed"); return }
        DispatchQueue.global(qos: .userInitiated).async { h.write(Data(line.utf8)) }
    }
    static func pcm16(fromWAV raw: Data) -> ([Int16], Int) {
        // scan chunks for 'data' + 'fmt ' — no fixed-offset assumption
        guard raw.count > 12, String(data: raw[0..<4], encoding: .ascii) == "RIFF" else { return ([], 16000) }
        var i = 12; var rate = 16000; var dataOff = -1; var dataLen = 0
        while i + 8 <= raw.count {
            let id = String(data: raw[i..<i+4], encoding: .ascii) ?? ""
            var sz = 0
            (raw as NSData).getBytes(&sz, range: NSRange(location: i + 4, length: 4))
            if id == "fmt " { (raw as NSData).getBytes(&rate, range: NSRange(location: i + 12, length: 4)) }
            if id == "data" { dataOff = i + 8; dataLen = min(sz, raw.count - i - 8); break }
            if sz <= 0 { break }
            i += 8 + sz + (sz & 1)
        }
        guard dataOff >= 0, dataLen > 1 else { return ([], rate) }
        var out = [Int16](repeating: 0, count: dataLen / 2)
        (raw as NSData).getBytes(&out, range: NSRange(location: dataOff, length: out.count * 2))
        return (out, rate)
    }

    // ---- SSE publish ----
    func publish(_ event: String, _ data: String) {
        let msg = "id: \(nextId())\nevent: \(event)\ndata: \(data)\n\n"
        bblock.lock(); let conns = sseConns; bblock.unlock()
        var alive: [NWConnection] = []
        for c in conns where c.state == .ready { send(c, msg); alive.append(c) }
        bblock.lock(); sseConns = alive; bblock.unlock()
    }
    func nextId() -> Int { bblock.lock(); defer { bblock.unlock() }; evtId += 1; return evtId }
    func getEngineName() -> String { bblock.lock(); defer { bblock.unlock() }; return engineName }

    // ---- pump (0.2s from sidecar main timer) ----
    func pump() {
        pumpTick += 1
        // flush_ms timeout-flush (§5.1): an unpunctuated clause still starts speaking
        bblock.lock()
        let hasPending = !pending.isEmpty
        let idle = CACurrentMediaTime() - lastByte > flushMs
        let isOpen = streamOpen
        bblock.unlock()
        if hasPending && idle {
            if isOpen {
                // cut at last word boundary if we have one, else whole
                bblock.lock()
                let cs = Array(pending)
                var cut = cs.count
                for i in stride(from: cs.count - 1, through: 0, by: -1) where cs[i] == " " { cut = i + 1; break }
                if cut < 4 { cut = cs.count }
                let sent = String(cs[0..<cut]); pending.removeFirst(cut)
                bblock.unlock()
                enqueue(sent)
            } else {
                flushPending(true)
            }
        }
        // heartbeat @2s + queue drain watchdog
        if pumpTick % 10 == 0 {
            publish("b-status", statusJSON())
            bblock.lock(); let talking = speech.isSpeaking || playerNode.isPlaying || (legacy?.isPlaying ?? false) || (afProc?.isRunning ?? false); let q = queued.isEmpty; let st = ttsState; let eof = ttsEOF; let open = streamOpen; let stale = CACurrentMediaTime() - lastByte > 30; let pastDeadline = CACurrentMediaTime() > uttDeadline; let inflight = synthInFlight; bblock.unlock()
            if !talking && q && st != "idle" && inflight == 0 { bblock.lock(); ttsState = "idle"; bblock.unlock(); unduckOrResume(); if eof { ackTTS() } }
            // ⟦THE LAMP SHALL NOT OUTLIVE ITS MOUTH⟧ (2026-10-31, 01:15, Bob: "the speaker
            // lamp is stuck lit"): a fallback was SCHEDULED, the audio world died before it
            // spoke — isSpeaking false, node silent, legacy nil — and every idle rule was
            // held hostage by a non-empty queue. A 'speaking' lamp with no mouth moving
            // anywhere, past its generous deadline, with no synth in flight, is a LIE:
            // extinguish it, drain to the next sentence, and say so out loud.
            if !talking && st == "speaking" && pastDeadline && inflight == 0 {
                log("speaking lamp orphaned — no mouth moved; extinguished, queue drains")
                speech.stopSpeaking(at: .immediate); playerNode.stop()
                bblock.lock(); ttsState = "idle"; uttDeadline = 0; nodeEnds = 0; bblock.unlock()
                unduckOrResume(); outFlip(false, "")
                DispatchQueue.main.async { self.speakNext() }
            }
            // NOT talking, queue non-empty, state stuck "speaking" (missed delegate): speakNext's
            // own guard would re-deny — flip the state FIRST, then advance. This was the wedge.
            // Card B: synthInFlight > 0 means a provider sentence was DEQUEUED and is being
            // cooked right now — both mouths silent, queue empty, NOT a wedge. Flipping here
            // raced the alive-check in speakNext's bg block and killed the audio (T1e postmortem).
            if !talking && !q && inflight == 0 { bblock.lock(); ttsState = "idle"; bblock.unlock(); speakNext() }
            // ⟦GRAPH FROZEN AT START⟧ (three crashes 2026-10-3x: 'player started when in a
            // disconnected state'): once the engine has run, the node graph is frozen —
            // an engine STOP (config-change ear release, disarm-while-idle) invalidates our
            // 'attached' claim. Track aliveness; a stopped engine means re-attach next play.
            if nodeAttached && !engine.isRunning { nodeAttached = false }
            // ⟦CLOCK-COMPLETION⟧: node utterance past its known duration = done, callback
            // or not — ttsState flips, queue drains, the lamp goes DARK. (The callback path
            // still fires nodeDone when CoreAudio feels like it; the clock never sulks.)
            if nodeEnds > 0 && playerNode.isPlaying && CACurrentMediaTime() > nodeEnds {
                log("node utterance complete by wall clock")
                playerNode.stop()
                nodeEnds = 0
                let doneGen = uttGen
                nodeDone(doneGen)
            }
            // stuck synthesizer/player: deadline expired → force-stop BOTH mouths
            if talking && uttDeadline > 0 && pastDeadline { log("tts stuck past deadline — force-stop"); speech.stopSpeaking(at: .immediate); playerNode.stop(); player?.stop(); legacy?.stop(); let ghost = afProc; setState { afProc = nil; player = nil; legacy = nil; nodeEnds = 0 }; ghost?.terminate(); outFlip(false, "") }
            // dead client: stream flagged open, no bytes 30s → treat as EOF, don't strand the turn
            if open && !eof && stale { bblock.lock(); streamOpen = false; ttsEOF = true; if let tail = String(data: ttsBuf, encoding: .utf8) { pending += tail }; ttsBuf = Data(); let rest = pending; pending = ""; bblock.unlock(); if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { enqueue(rest) } else { ackTTS() } }
        }
        // provider playback completed but the AVAudioPlayer delegate never fired (it is
        // run-loop-affine and flaky off-main): poll it to death — currentTime at EOF
        // means the sentence is over; advance the queue exactly like didFinishPlaying.
        bblock.lock(); let pd = legacy; bblock.unlock()   // the NODE's completion handler is run-loop-proof; only LEGACY needs polling to death
        if let p = pd, !p.isPlaying, p.currentTime >= max(0.5, p.duration - 0.5) {
            log("tts done (provider, polled legacy)")
            setState { if legacy === p { legacy = nil } }
            speakNext()
        }
    }

    // ---- state helpers ----
    func setState(_ f: () -> Void) { bblock.lock(); f(); bblock.unlock() }
    func statusJSON() -> String {
        bblock.lock(); defer { bblock.unlock() }
        // SIDECAR_VERSION/ SIDECAR_BUILD are stamped at compile by build.sh (version.swift
        // generated from the VERSION file; build = git describe, else bYYYYMMDD.HHMM).
        // The plugin (card E) reads `version` for sidecar-installed detection -> tooltip "(vX)".
        return "{\"version\":\"\(SIDECAR_VERSION)\",\"build\":\"\(SIDECAR_BUILD)\",\"stt\":{\"state\":\"\(sttState)\",\"engine\":\"\(engineName)\",\"segs\":\(segsDone)},"
             + "\"tts\":{\"state\":\"\(ttsState)\",\"queued\":\(queued.count),\"spoken\":\(spoken),\"mode\":\(jsonStr(lastMode)),"
             + "\"provider\":{\"configured\":\(!pBase.isEmpty && !pModel.isEmpty),\"base\":\(jsonStr(pBase)),\"model\":\(jsonStr(pModel)),\"voice\":\(jsonStr(voiceOverride)),\"errs\":\(providerErrs)}},"
             + "\"boot\":\(ChannelB.bootMark),\"mic\":\"\(micOn ? "armed" : "muted")\",\"echoCancel\":\"\(canc.active ? "nlms-live" : "idle")\"}"
    }

    // ---- card C: return-channel frame ticker (b-in / b-out @20Hz + b-timing) ----
    // Waveform encoding: 64 signed-peak bins, 128-centered bytes, base64 — the exact
    // layout the plugin's analyser getByteTimeDomainData produces, so card F can
    // decode → drop straight into audioBus.{in,out}.buf and reuse the viz path.
    func startFrames() {
        let q = DispatchQueue(label: "orbit.b.frames", qos: .utility)
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 0.5, repeating: 0.05)
        t.setEventHandler { [weak self] in self?.frames() }
        t.resume()
        frameTimer = t
    }
    func frames() {
        // b-in: mic level + scrolling ~100ms waveform — armed mic only (muted = no events;
        // b-status mic:"muted" is the plugin's gate).
        bblock.lock(); let mic = micOn; let rate = micRate; bblock.unlock()
        if mic {
            inLock.lock(); let ring = inRing; let lvl = inRmsSm; inLock.unlock()
            let win = min(ring.count, Int(rate * 0.096))
            let (wf, _) = Self.waveframe(ring, ring.count - win, ring.count)
            publish("b-in", "{\"ts\":\(Self.nowMs()),\"level\":\(String(format: "%.4f", lvl)),\"waveform\":\"\(wf)\"}")
        }
        // b-out: envelope of the LEVEL-1 provider PCM riding the playhead. Between
        // sentences (queue advancing) isPlaying is false → frames pause, flip stays true.
        bblock.lock(); let p = player; let pcm = outPcm; let orate = outRate; let t0 = outT0; bblock.unlock()
        guard let pl = p, pl.isPlaying, !pcm.isEmpty, orate > 0 else { return }
        let pos = min(Double(pcm.count), max(0.0, CACurrentMediaTime() - t0) * orate)   // node has no currentTime — outT0 IS the playhead
        let win = min(Int(pos), Int(orate * 0.096))
        let (wf, rms) = Self.waveframe(pcm, Int(pos) - win, Int(pos))
        publish("b-out", "{\"ts\":\(Self.nowMs()),\"speaking\":true,\"mode\":\"provider\",\"level\":\(String(format: "%.4f", rms)),\"pos_ms\":\(Int(pos / orate * 1000)),\"waveform\":\"\(wf)\"}")
    }
    // signed-peak decimation into wfBins, 128-centered (getByteTimeDomainData layout) + rms
    static func waveframe(_ s: [Int16], _ from0: Int, _ to0: Int) -> (String, Double) {
        let a = max(0, min(s.count, from0)), b = max(a, min(s.count, to0))
        guard b > a else { return (flatWf, 0) }
        var bytes = [UInt8](repeating: 128, count: wfBins)
        var sumsq = 0.0
        for i in 0..<wfBins {
            var i0 = a + (b - a) * i / wfBins
            let i1 = a + (b - a) * (i + 1) / wfBins
            var peak = 0
            while i0 < i1 {
                let v = Int(s[i0])
                sumsq += Double(v) * Double(v)
                if abs(v) > abs(peak) { peak = v }
                i0 += 1
            }
            bytes[i] = UInt8(max(0, min(255, 128 + peak / 256)))
        }
        return (Data(bytes).base64EncodedString(), (sumsq / Double(b - a)).squareRoot() / 32768.0)
    }
    static let flatWf = Data([UInt8](repeating: 128, count: wfBins)).base64EncodedString()
    // speaking flips (agent.speaking atom) — edge-triggered, no spam
    func outFlip(_ on: Bool, _ mode: String) {
        bblock.lock()
        if outSpeaking == on { bblock.unlock(); log("cardC flip suppressed (already \(on))"); return }
        outSpeaking = on
        if !on { outPcm = [] }
        bblock.unlock()
        log("cardC flip → \(on) mode=\(mode)")
        publish("b-out", "{\"ts\":\(Self.nowMs()),\"speaking\":\(on ? "true" : "false"),\"mode\":\(jsonStr(mode)),\"level\":0,\"waveform\":\"\"}")
    }
    func firstAudio(_ mode: String) {
        bblock.lock()
        guard turnStart > 0, !firstAudioDone else { bblock.unlock(); return }
        firstAudioDone = true; turnMode = mode
        firstLatencyMs = (CACurrentMediaTime() - turnStart) * 1000
        let tN = turnN; let sm = lastSynthMs; let lat = firstLatencyMs
        bblock.unlock()
        timing("first_audio", tN, ["\"mode\":\(jsonStr(mode))", "\"latency_ms\":\(Int(lat))", "\"synth_ms\":\(Int(mode == "provider" ? sm : 0))"])
    }
    func timing(_ phase: String, _ turn: Int, _ extra: [String]) {
        publish("b-timing", "{\"turn\":\(turn),\"phase\":\"\(phase)\",\"ts\":\(Self.nowMs())" + (extra.isEmpty ? "" : "," + extra.joined(separator: ",")) + "}")
    }
    static func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    // ---- AVSpeechSynthesizerDelegate ----
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { log("tts done: \(utterance.speechString.prefix(40))"); speakNext() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) { log("tts cancel: \(utterance.speechString.prefix(40))"); speakNext() }

    // ---- AVAudioPlayerDelegate (LEVEL-1 provider playback) ----
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {   // LEGACY path only
        log("tts done (provider, legacy\(flag ? "" : ", playback error"))")
        setState { if self.legacy === player { self.legacy = nil } }
        speakNext()
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        log("provider playback decode error — advancing queue")
        setState { if self.legacy === player { self.legacy = nil } }
        speakNext()
    }
}

// HTTP/1.1 chunked-transfer decoder — agentic LLM streams arrive chunked
// (no Content-Length); state machine survives arbitrary byte splits.
final class ChunkDecoder {
    private enum St { case size, body, crlf, done }
    private var st: St = .size
    private var buf = Data()
    private var remaining = 0
    func feed(_ d: Data) -> Data {
        var out = Data()
        buf.append(d)
        while true {
            switch st {
            case .size:
                guard let cr = buf.firstIndex(of: 0x0D), buf.index(after: cr) < buf.count, buf[buf.index(after: cr)] == 0x0A else { return out }
                let line = String(data: buf[..<cr], encoding: .ascii) ?? ""
                buf.removeSubrange(buf.startIndex...buf.index(after: cr))
                guard let size = Int(line.split(separator: ";").first.map(String.init) ?? "", radix: 16) else { st = .done; return out }
                if size == 0 { st = .done; return out }
                remaining = size; st = .body
            case .body:
                let take = min(remaining, buf.count)
                out.append(buf[buf.startIndex..<buf.startIndex+take])
                buf.removeSubrange(buf.startIndex..<buf.startIndex+take)
                remaining -= take
                if remaining == 0 { st = .crlf } else { return out }
            case .crlf:
                if buf.count >= 2 { buf.removeSubrange(buf.startIndex..<buf.startIndex+2); st = .size } else { return out }
            case .done:
                return out
            }
        }
    }
    var isDone: Bool { st == .done }
}

func wavHeaderStatic(_ dataLen: Int32, _ rate: Int32) -> [UInt8] {
    func u32(_ v: Int32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)] }
    func u16(_ v: Int16) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }
    var h: [UInt8] = []
    h += Array("RIFF".utf8); h += u32(36 + dataLen); h += Array("WAVE".utf8)
    h += Array("fmt ".utf8); h += u32(16); h += u16(1); h += u16(1)
    h += u32(rate); h += u32(rate * 2); h += u16(2); h += u16(16)
    h += Array("data".utf8); h += u32(dataLen)
    return h
}

func jsonStr(_ s: String) -> String {
    guard let d = try? JSONSerialization.data(withJSONObject: [s]), let str = String(data: d, encoding: .utf8) else { return "\"\"" }
    return String(str.dropFirst().dropLast())
}
