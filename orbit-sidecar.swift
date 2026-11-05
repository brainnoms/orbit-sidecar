// orbit-sidecar — PRODUCTION. Faithful to proven orbit-tap-v9 tap core.
// Nightcrawler (M1 Max). ZERO content disk writes (the §5 duck-lease JSON is
// control state, atomically written, never user content). Per-app system-audio
// tap -> rolling peak/rms in RAM -> SSE loopback :8107 to the sealed renderer.
// Enumeration driven by RAW ps (catches duplicate Aperitif instances —
// the Twitch root cause). Re-scans every 4s so sources appear/vanish live.
// Real duck via output VolumeScalar (proven settable). Icons cold-channel.
import AVFoundation
import CoreAudio
import Foundation
import Network
import AppKit
import CryptoKit

func log(_ s: String) { FileHandle.standardError.write("[sidecar] \(s)\n".data(using: .utf8)!); fflush(stderr) }
let hw = AudioObjectID(kAudioObjectSystemObject)

// ---- output device UID ---------------------------------------------------
var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: AudioObjectPropertyElement(0))
var sz = UInt32(0); AudioObjectGetPropertyDataSize(hw, &addr, 0, nil, &sz)
let n0 = Int(sz) / MemoryLayout<AudioObjectID>.size
var objs = [AudioObjectID](repeating: 0, count: max(n0, 1)); var ioSz = sz
objs.withUnsafeMutableBytes { _ = AudioObjectGetPropertyData(hw, &addr, 0, nil, &ioSz, $0.baseAddress!) }
var aDev = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: AudioObjectPropertyElement(0))
var outDev = AudioObjectID(0); var dsz = UInt32(4); AudioObjectGetPropertyData(hw, &aDev, 0, nil, &dsz, &outDev)
var aUID = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: AudioObjectPropertyElement(0))
var uref: Unmanaged<CFString>?; var usz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size); AudioObjectGetPropertyData(outDev, &aUID, 0, nil, &usz, &uref)
var outputUID = (uref?.takeRetainedValue() as String?) ?? ""   // var: rebuilt on default-output change (self-health)
// Thread-safety law (bite 2026-10-26): outputUID is written from rebuildQ and read
// by concurrent tap workers; a torn Swift String write POISONS the value for the
// whole process — every later aggregate creation fails until reboot of the binary.
// All access goes through uidLock. Never read the var directly.
let uidLock = NSLock()
func getOutputUID() -> String { uidLock.lock(); defer { uidLock.unlock() }; return outputUID }
func setOutputUID(_ s: String) { uidLock.lock(); outputUID = s; uidLock.unlock() }

// ---- per-source state (reference type; ioProc mutates via device dict) --
final class Src {
    let label: String; let obj: AudioObjectID; let pid: pid_t
    let tap: AudioObjectID; let agg: AudioDeviceID; let ioID: AudioDeviceIOProcID
    var peak: Double = 0, sumsq: Double = 0, frames: Double = 0
    var lastSeen: CFTimeInterval = 0
    var lastLoud: CFTimeInterval = 0
    lazy var name: String = { NSRunningApplication(processIdentifier: pid)?.localizedName ?? label }()
    lazy var icon: String = {                       // computed ONCE, off hot path
        guard let app = NSRunningApplication(processIdentifier: pid), let img = app.icon else { return "" }
        var r = NSRect(x: 0, y: 0, width: 64, height: 64)
        guard let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return "" }
        guard let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }()
    init(_ label: String, _ obj: AudioObjectID, _ pid: pid_t, _ tap: AudioObjectID, _ agg: AudioDeviceID, _ ioID: AudioDeviceIOProcID) {
        self.label = label; self.obj = obj; self.pid = pid; self.tap = tap; self.agg = agg; self.ioID = ioID
    }
}
let lock = NSLock()
var byAgg: [AudioDeviceID: Src] = [:]     // ioProc: inID -> src
var byObj: [AudioObjectID: Src] = [:]     // registry: obj -> src
let SR = 48000.0
var lastRender: CFTimeInterval = 0        // ioProc render stamp (lock-owned); 0 = nothing rendered yet

// ---- CONTROL PLANE v1 shared state -----------------------------------------
// Contract: ~/.hermes/vaults/Hermes-Plans/orbit-control-plane-v1.md. A client is
// "proto" ONLY if it connects /stream with proto=1; proto-less clients see today's
// behavior byte-for-byte (no hello, no elected, no new events). All cp state is
// cpLock-owned. Declared EARLY: async tap workers call cpBroadcast as soon as
// they spawn, before later top-level init has run (Swift top-level vars init in
// source order — a late declaration here would be a boot-time race/crash).
let EPOCH = Int(Date().timeIntervalSince1970)     // sidecar boot epoch (unix seconds)
final class HelloRec { var conn: NWConnection?; var version = ""; var lastHello = Date.distantPast; var epoch: Double = 0 }
let cpLock = NSLock()
var roster: [String: HelloRec] = [:]              // bootId -> presence (cpLock)
var mainBoot: String? = nil                       // current elected main (cpLock)
var protoConns: [NWConnection] = []               // every live proto SSE conn (cpLock)
// ⟦EPOCH-TRUTH⟧ One visualizer is the truth: the boot claiming the highest module-load
// epoch (ms). epoch==0 means legacy client. Once an epoch>0 claim exists, superseded
// boots AND bootless legacy streams get 410 Gone — a FATAL EventSource error, so the
// BROWSER itself tears down zombie sockets instead of squatting the 6-per-host pool.
// This is the server enforcing "one main" instead of praying every realm GC's itself.
func curClaim() -> (String?, Double) {
    cpLock.lock(); defer { cpLock.unlock() }
    var cb: String? = nil; var ce: Double = 0
    for (b, r) in roster where r.epoch > ce { ce = r.epoch; cb = b }
    return (cb, ce)
}
func goneResp(_ c: NWConnection) { httpResp(c, "410 Gone", "application/json", "{\"ok\":false,\"err\":\"replaced\"}") }
// Every stream conn that carries a visualizer identity, so the 5s sweep can RETROACTIVELY
// cancel already-attached zombies the moment a newer epoch claims the plane (410 alone only
// guards the door; it cannot reach connections that came in before the claim).
let streamRegLock = NSLock()
var streamReg: [(c: NWConnection, boot: String, epoch: Double, role: String)] = []
func streamEnforce() {
    let (cb, ce) = curClaim()
    guard ce > 0 else { return }
    streamRegLock.lock()
    let doomed = streamReg.filter { $0.role != "doctor" && ($0.boot.isEmpty || ($0.epoch <= ce && $0.boot != cb)) }
    streamReg.removeAll { e in doomed.contains { $0.c === e.c } }
    streamRegLock.unlock()
    for d in doomed { d.c.cancel(); log("epoch-purge boot=\(d.boot.isEmpty ? "legacy" : d.boot)") }
}
func cpSend(_ c: NWConnection, _ event: String, _ data: String) { send(c, "event: \(event)\ndata: \(data)\n\n") }
func cpBroadcast(_ event: String, _ data: String) {
    let msg = "event: \(event)\ndata: \(data)\n\n"
    cpLock.lock(); let cs = protoConns; cpLock.unlock()
    var alive: [NWConnection] = []
    for c in cs where c.state == .ready { send(c, msg); alive.append(c) }
    cpLock.lock(); protoConns = alive; cpLock.unlock()
}
func sourcesArr() -> String {                     // the JSON array behind GET /sources
    lock.lock(); let srcs = Array(byObj.values); lock.unlock()
    let arr = srcs.map { "{\"obj\":\($0.obj),\"pid\":\($0.pid),\"name\":\"\($0.name.replacingOccurrences(of: "\"", with: ""))\",\"icon\":\"\($0.icon)\"}" }
    return "[" + arr.joined(separator: ",") + "]"
}

// ---- ps enumeration (verbatim v9) -----------------------------------------
func runPS() -> [(pid_t, String)] {
    let p = Process(); p.launchPath = "/bin/ps"; p.arguments = ["-axo", "pid=,comm="]
    let pipe = Pipe(); p.standardOutput = pipe; try? p.run()
    let d = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    var out: [(pid_t, String)] = []
    for line in String(data: d, encoding: .utf8)?.split(separator: "\n") ?? [] {
        let t = line.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { continue }
        let parts = t.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, let pid = pid_t(parts[0]) else { continue }
        out.append((pid, String(parts[1])))
    }
    return out
}
let allow = ["Aperitif", "Google Chrome", "app_mode", "Twitch", "Music", "Discord", "Steam", "Spotify", "Safari", "Firefox", "VLC", "QuickTime", "iTunes"]

// ---- CLAIM (card G, blueprint §4): transparent desktop-audio usurpation ------
// A PROCESS TAP is a non-destructive claim: it captures the tapped process's rendered
// output — the Hermes desktop's own audio included — WITHOUT swapping the system default
// device, so card D's duck volume plane stays on the real output device. The desktop
// audio loop runs on, unaware; the sidecar simply hears everything it says.
// POST /command {"cmd":"claim"}   → add "Hermes" to the tap set
// POST /command {"cmd":"release"} → drop it; the 4s rescan retires the taps
// GET  /claim → {"claimed":bool,"taps":["Hermes Helper (Renderer):pid", ...]}
// Boot default is OFF: the plugin owns the policy (blueprint §4 — "their toggles
// remain the policy"), claiming when the sidecar is present and releasing on its way out.
// Claims LEASE: a claim lives 30s and is refreshed by the claimer's GET /claim probe
// (~every 4s); a crashed claimer's lease expires and the taps retire on the next scan.
let claimLock = NSLock()
var claimExpiry: [String: Date] = [:]
func pruneClaims() {
    claimLock.lock(); claimExpiry = claimExpiry.filter { $0.value > Date() }; claimLock.unlock()
}
func claimActive(_ comm: String) -> Bool {
    claimLock.lock(); defer { claimLock.unlock() }
    let now = Date()
    return claimExpiry.contains { $0.value > now && comm.contains($0.key) }
}
func claimState() -> Bool { pruneClaims(); claimLock.lock(); defer { claimLock.unlock() }; return !claimExpiry.isEmpty }

func aliveObjects() -> Set<AudioObjectID> {
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: AudioObjectPropertyElement(0))
    var s = UInt32(0); AudioObjectGetPropertyDataSize(hw, &a, 0, nil, &s)
    let nn = Int(s) / MemoryLayout<AudioObjectID>.size
    var arr = [AudioObjectID](repeating: 0, count: max(nn, 1)); var isz = s
    arr.withUnsafeMutableBytes { _ = AudioObjectGetPropertyData(hw, &a, 0, nil, &isz, $0.baseAddress!) }
    return Set(nn > 0 ? Array(arr.prefix(nn)) : [])
}
func enumerateTargets() -> [(label: String, obj: AudioObjectID, pid: pid_t)] {
    let alive = aliveObjects(); var seen = Set<AudioObjectID>(); var targets: [(String, AudioObjectID, pid_t)] = []
    for (pid, comm) in runPS() {
        let last = comm.split(separator: "/").last.map(String.init) ?? comm
        guard allow.contains(where: { comm.contains($0) }) || claimActive(comm) else { continue }
        var a2 = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: AudioObjectPropertyElement(0))
        var p = UInt32(pid); var obj = AudioObjectID(0); var osz = UInt32(4)
        guard AudioObjectGetPropertyData(hw, &a2, 4, &p, &osz, &obj) == noErr, obj != 0, alive.contains(obj), !seen.contains(obj) else { continue }
        seen.insert(obj)
        let label = (last.contains("Aperitif")) ? "Aperitif:\(pid)" : "\(last):\(pid)"
        targets.append((label, obj, pid))
    }
    // ⟦THE MIC SHALL NOT HEAR THE SPEAKER⟧ self-tap: our OWN output — provider node AND
    // AVSpeech fallback — is output. No other process tap can see it and we refuse to
    // pretend our own voice doesn't echo. If CoreAudio refuses a self-tap, honest miss.
    do {
        var a3 = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal, mElement: AudioObjectPropertyElement(0))
        var p = UInt32(getpid()); var obj = AudioObjectID(0); var osz = UInt32(4)
        if AudioObjectGetPropertyData(hw, &a3, 4, &p, &osz, &obj) == noErr, obj != 0, !seen.contains(obj) {
            targets.append(("orbit-sidecar(self)", obj, getpid()))
        } else { log("self-tap: no process object for our pid — own voice uncancellable by tap (provider ref still covers speech)") }
    }
    return targets
}

// ---- tap + aggregate (verbatim v9) ---------------------------------------
func makeTap(_ obj: AudioObjectID) -> (tap: AudioObjectID, agg: AudioDeviceID)? {
    let uid = getOutputUID()   // snapshot once: dict must not straddle a rebuild
    let uuid = UUID(); let desc = CATapDescription(stereoMixdownOfProcesses: [obj]); desc.uuid = uuid; desc.muteBehavior = CATapMuteBehavior.unmuted
    var tapID = AudioObjectID(0); guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { return nil }
    let comp: [String: Any] = [
        kAudioAggregateDeviceNameKey: "Orbit \(uuid.uuidString.prefix(4))",
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceMainSubDeviceKey: uid,
        kAudioAggregateDeviceIsPrivateKey: true,
        kAudioAggregateDeviceIsStackedKey: false,
        kAudioAggregateDeviceTapAutoStartKey: true,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
        kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: uuid.uuidString]],
    ]
    var agg = AudioDeviceID(0); guard AudioHardwareCreateAggregateDevice(comp as CFDictionary, &agg) == noErr else { AudioHardwareDestroyProcessTap(tapID); return nil }
    return (tap: tapID, agg: agg)
}

// ---- realtime ioProc: device->src lookup, accumulate, stamp lastSeen ----
// THE CANCELLER (see echo-cancel.swift): one global, both planes feed it
let canc = EchoCanceller()

func machSec(_ host: UInt64) -> Double { var ti = mach_timebase_info(); if mach_timebase_info(&ti) != 0 || ti.denom == 0 { return CACurrentMediaTime() }; return Double(host) * Double(ti.numer) / Double(ti.denom) / 1e9 }

let ioProc: @convention(c) (AudioObjectID, UnsafePointer<AudioTimeStamp>, UnsafePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>, UnsafeMutablePointer<AudioBufferList>, UnsafePointer<AudioTimeStamp>, UnsafeMutableRawPointer?) -> OSStatus =
{ inID, inStamp, inData, _, _, _, _ in
    let abl = inData.pointee; guard abl.mNumberBuffers > 0 else { return noErr }
    lock.lock(); defer { lock.unlock() }
    guard let src = byAgg[inID] else { return noErr }
    src.lastSeen = CACurrentMediaTime()
    lastRender = src.lastSeen   // stall watchdog: last time CoreAudio actually rendered to us
    for i in 0..<Int(abl.mNumberBuffers) {
        let buf = withUnsafePointer(to: abl.mBuffers) { $0.advanced(by: i).pointee }
        let nb = Int(buf.mDataByteSize); guard let base = buf.mData, nb >= 4 else { continue }
        let cnt = nb / 4; src.frames += Double(cnt) / Double(max(1, Int(buf.mNumberChannels)))
        let ch_ch = max(1, Int(buf.mNumberChannels)); let chans0 = buf.mData
        let ch = chans0
        base.withMemoryRebound(to: Float32.self, capacity: cnt) { ch in
            for j in 0..<cnt { let v = Double(ch[j]); let a = abs(v); if a > src.peak { src.peak = a }; src.sumsq += v * v }
            // ⟦THE MIC SHALL NOT HEAR THE SPEAKER⟧ hand the canceller this render of the whole output
            let frames = cnt / max(1, ch_ch)
            if frames > 0 { let hs = machSec(inStamp.pointee.mHostTime); canc.pushMix(ch, frames, ch_ch, at: hs) }
        }
    }
    if src.peak > 0.02 { src.lastLoud = CACurrentMediaTime() }
    return noErr
}

// ---- scan: add new sources, retire dead ones ---------------------------
// coreaudiod-hardened (2026-10-21): every blocking CoreAudio call (CreateIOProcID/
// Start/Stop/Destroy) can block FOREVER in mach_msg when coreaudiod wedges — sampled
// live, three PIDs, identical stack. So tap lifecycle runs on worker threads; the
// main thread never touches the audio server synchronously. A sick CoreAudio can now
// only delay channel-A frames, never take down the HTTP plane (:PORT), channel B,
// or boot itself.
var pendingObjs = Set<AudioObjectID>()
func tapObj(_ label: String, _ obj: AudioObjectID, _ pid: pid_t) {
    lock.lock(); if pendingObjs.contains(obj) { lock.unlock(); return }; pendingObjs.insert(obj); lock.unlock()
    DispatchQueue.global(qos: .userInitiated).async {
        defer { lock.lock(); pendingObjs.remove(obj); lock.unlock() }
        guard let made = makeTap(obj) else { if label.contains("self") { log("self-tap REFUSED by CoreAudio — own output uncancellable by tap; provider/AVSpeech refs must carry it") }; return }
        var ioID: AudioDeviceIOProcID?
        if AudioDeviceCreateIOProcID(made.agg, ioProc, nil, &ioID) != noErr || ioID == nil {
            AudioHardwareDestroyAggregateDevice(made.agg); AudioHardwareDestroyProcessTap(made.tap); return
        }
        AudioDeviceStart(made.agg, ioID!)
        let s = Src(label, obj, pid, made.tap, made.agg, ioID!)
        lock.lock(); byAgg[made.agg] = s; byObj[obj] = s; lock.unlock()
        log("tap+\(label) obj=\(obj) agg=\(made.agg)")
        cpBroadcast("sources", sourcesArr())   // control plane: tap set changed
    }
}
func retire(_ s: Src) {
    DispatchQueue.global(qos: .userInitiated).async {
        AudioDeviceStop(s.agg, s.ioID); AudioDeviceDestroyIOProcID(s.agg, s.ioID)
        AudioHardwareDestroyAggregateDevice(s.agg); AudioHardwareDestroyProcessTap(s.tap)
        lock.lock(); byAgg.removeValue(forKey: s.agg); byObj.removeValue(forKey: s.obj); lock.unlock()
        log("tap-\(s.label)")
        cpBroadcast("sources", sourcesArr())   // control plane: tap set changed
    }
}
// ⟦NO-ZOMBIES⟧ exit teardown. kickstart/watchdog SIGTERM used to kill us HOLDING
// live private aggregates + process taps; coreaudiod keeps them as runtime garbage.
// Caught live 2026-10-26: fresh coreaudiod (relaunched 15:44) re-rotted to zero-taps
// by evening across ~6 deploys — each one leaked its whole tap set. Dispose every
// tracked tap before exiting. If the daemon is wedged these calls block in mach_msg
// and launchd escalates to SIGKILL anyway — no worse than today; on a healthy daemon
// the leak ends here.
func disposeAllTaps() {
    lock.lock(); let all = Array(byAgg.values); lock.unlock()
    for s in all {
        AudioDeviceStop(s.agg, s.ioID); AudioDeviceDestroyIOProcID(s.agg, s.ioID)
        AudioHardwareDestroyAggregateDevice(s.agg); AudioHardwareDestroyProcessTap(s.tap)
    }
}
signal(SIGTERM) { _ in disposeAllTaps(); _exit(0) }
signal(SIGINT)  { _ in disposeAllTaps(); _exit(0) }
func scan() {
    pruneClaims()   // expired leases drop out; enumerateTargets then retires their taps
    let targets = enumerateTargets()
    let wantObjs = Set(targets.map { $0.obj })
    lock.lock(); let have = Set(byObj.keys); let snapshot = byObj; lock.unlock()
    for t in targets where !have.contains(t.obj) { tapObj(t.label, t.obj, t.pid) }
    for (obj, s) in snapshot where !wantObjs.contains(obj) { retire(s) }
}
for t in enumerateTargets() { tapObj(t.label, t.obj, t.pid) }

// ⟦THE BRIDGE⟧ the browser ear cannot cancel what it cannot reference. Pump the
// canceller's timeline (whole-output mixdown + the agent's own bytes, int16 @16k)
// as base64 chunks every 20ms over the cp plane. Absolute sample index + lead
// let the plugin schedule ahead of the echo; its NLMS eats the latency. The
// stream STOPS when the reference goes silent — no audio, no traffic.
var refSentTo = 0
let refTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
refTimer.schedule(deadline: .now() + 0.2, repeating: 0.02)
refTimer.setEventHandler {
    let t = CACurrentMediaTime()
    guard canc.clockStart > 0 else { return }
    guard canc.active else {
        refSentTo = Int((t - canc.clockStart) * 16000) + 16000   // silence: cursor rides the clock
        return
    }
    let head = Int((t - canc.clockStart) * 16000) + 3200         // 200ms lead: latch before the echo lands
    let from = max(refSentTo, head - 8000)
    let n = min(320, head - from)
    if n >= 64 {
        let smp = canc.slice(from, n)
        var d = Data(capacity: smp.count * 2)
        for v in smp { let u = UInt16(bitPattern: v); d.append(UInt8(u & 0xff)); d.append(UInt8(u >> 8)) }
        refSentTo = from + n
        cpBroadcast("ecref", "{\"i\":\(from),\"n\":\(n),\"b\":\"\(d.base64EncodedString())\"}")
    }
}
refTimer.resume()
log("initial tap spawns=\(enumerateTargets().count)")

// ---- duck: disk-backed LEASE (blueprint §5) --------------------------------
// OLD BUG (reproduced live 2026-10-23): baseline came from the volatile cachedVol
// (start −1, refreshed only when NOT ducked) and unduck's restore raced an
// overlapping duck()'s capture on a CONCURRENT queue — barge-in mid-speech
// captured the floor 0.12 itself as the "baseline" → master pinned at 12.
// THE LEASE: every duck verb runs SERIALIZED on duckQ (channel-B calls duck()
// from the main runloop — duckQ keeps CoreAudio off main, same coreaudiod
// hardening as before). duck() reads the LIVE scalars synchronously per-channel,
// atomically persists {device→channel→level} snapshot THEN a heartbeat lease
// (no lease ⇒ nothing was pinned), and only then floors. unduck() restores from
// the snapshot and clears the lease. Boot recovery: fresh heartbeat + live owner
// ⇒ another instance is ducked (hands off); owner dead + snapshot ≤60s ⇒ restore;
// stale snapshot ⇒ untrusted, lease left untouched, floor un-pinned only.
// ⟦VOICE OWNS THE MIX LAW (Bob, 2026-10-30)⟧ the agent voice plays through the SAME master
// the duck floors — a master pin drops music AND voice by the same amount, so the duck is
// worthless AND every utterance is born at 12%. Three honest modes now: NOTHING PLAYING → no
// duck at all (voice owns a full master — "lock the front door" is no longer a whisper);
// Music/Spotify → APP-level duck (independent volume channel, master never moves); any other
// source → master duck, floor raised to where the floored voice stays intelligible.
let DUCK_FLOOR: Float32 = 0.30              // master-mode duck level == the pin signature
let DUCK_FLOOR_EPS: Float32 = 0.005
let DUCK_UNPIN_TO: Float32 = 0.5            // ONLY for stale-lease floor recovery
let DUCK_APP_VOL: Int = 15                  // app-mode duck target (Music/Spotify own their volume)
let DUCK_SNAP_MAX_AGE: TimeInterval = 60    // snapshot trusted for restore within this
let DUCK_LEASE_LIVE: TimeInterval = 5       // heartbeat younger than this ⇒ owner alive
let DUCK_DIR  = NSString(string: "~/.hermes/jarvis/orbit-duck").expandingTildeInPath
let DUCK_SNAP = DUCK_DIR + "/snapshot.json"
let DUCK_LEASE = DUCK_DIR + "/lease.json"
let duckQ = DispatchQueue(label: "orbit.duck")
var ducked = false                          // duckQ-owned; main reads display-only
var duckStarted: TimeInterval = 0
var cachedVol: Float32 = -1                 // DISPLAY ONLY (/volume + SSE) — never a baseline
func curVol() -> Float32 { cachedVol }
func volAddr(_ el: Int) -> AudioObjectPropertyAddress { AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeOutput, mElement: AudioObjectPropertyElement(el)) }
func readVol(_ dev: AudioObjectID, _ el: Int) -> Float32 { var a = volAddr(el); var v: Float32 = -1; var s = UInt32(4); return AudioObjectGetPropertyData(dev, &a, 0, nil, &s, &v) == noErr ? v : -1 }
@discardableResult func writeVol(_ dev: AudioObjectID, _ el: Int, _ v: Float32) -> Bool { var a = volAddr(el); var set = DarwinBoolean(false); guard AudioObjectIsPropertySettable(dev, &a, &set) == noErr, set.boolValue else { return false }; var nv = v; return AudioObjectSetPropertyData(dev, &a, 0, nil, 4, &nv) == noErr }
func deviceByUID(_ uid: String) -> AudioObjectID {   // snapshot's device may not be today's default
    guard !uid.isEmpty else { return outDev }
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: AudioObjectPropertyElement(0))
    var cf = uid as CFString; var dev = AudioObjectID(0); var sz = UInt32(4)
    if AudioObjectGetPropertyData(hw, &a, UInt32(MemoryLayout<CFString>.size), &cf, &sz, &dev) == noErr, dev != 0 { return dev }
    return outDev
}
func writeJSONAtomic(_ path: String, _ s: String) {  // temp+rename: no torn state on disk
    try? FileManager.default.createDirectory(atPath: DUCK_DIR, withIntermediateDirectories: true)
    if let d = s.data(using: .utf8) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
}
func readJSON(_ path: String) -> [String: Any]? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}
func restoreFromSnapshot(_ snap: [String: Any]) {
    let dev = deviceByUID((snap["device"] as? String) ?? "")
    guard let ch = snap["channels"] as? [String: Any] else { return }
    for (k, v) in ch {
        guard let el = Int(k), let lv = (v as? NSNumber)?.floatValue, lv >= 0 else { continue }
        // ⟦A CRUSHED SNAPSHOT IS NOT A MEMORY⟧ (2026-10-31, 01:05): master was found at
        // 0.0317 — AT OUR OWN FLOOR — and "restored" there sentence after sentence all
        // night: every crash that died mid-duck let the heir snapshot a ducked world, and
        // the faithful restore sealed the ratchet. A snapshot at/below floor level proves
        // nothing about the room the user lived in — restore the FLOOR, never the corpse.
        let fixed = lv < DUCK_FLOOR ? DUCK_FLOOR : lv
        if fixed != lv { log("restore: snapshot \(String(format: "%.3f", lv)) is a crushed ghost — clamped to floor \(String(format: "%.3f", DUCK_FLOOR))") }
        writeVol(dev, el, fixed)
    }
}
func clearDuckState() { try? FileManager.default.removeItem(atPath: DUCK_LEASE); try? FileManager.default.removeItem(atPath: DUCK_SNAP) }
func mediaPlayingNow() -> (Bool, String) {   // 2s-fresh MediaRemote cache — right tool for duck policy
    guard let d = try? JSONSerialization.jsonObject(with: Data(npCache.utf8)) as? [String: Any] else { return (false, "") }
    return (((d["state"] as? String) ?? "") == "playing", npAppNow())
}
func appVolume(_ app: String, set: Bool, to: Int = -1) -> Int {  // the INDEPENDENT channel duck always needed
    let verb = app == "Spotify"
        ? (set ? "set player volume to \(to)" : "get player volume")
        : (set ? "set sound volume to \(to)" : "get sound volume")
    guard let out = runOA("tell application \"\(app)\" to \(verb)", 0.8) else { return -1 }
    if set { return 0 }
    return Int((Double(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1).rounded())
}
func duck() {
    duckQ.async {
        if ducked { return }                 // overlapping speech: FIRST snapshot stands
        let (playing, app) = mediaPlayingNow()
        if !playing { log("duck: nothing playing — voice owns the full master (no lease)"); return }
        let cur = (app == "Music" || app == "Spotify") ? appVolume(app, set: false) : -1
        if cur >= 0 {
            ducked = true
            duckStarted = Date().timeIntervalSince1970
            writeJSONAtomic(DUCK_SNAP, "{\"mode\":\"app\",\"app\":\"\(app)\",\"vol\":\(cur),\"taken_at\":\(duckStarted)}")
            writeJSONAtomic(DUCK_LEASE, "{\"pid\":\(getpid()),\"started_at\":\(duckStarted),\"heartbeat\":\(duckStarted)}")
            appVolume(app, set: true, to: DUCK_APP_VOL)
            log("duck: \(app) app-volume \(cur)→\(DUCK_APP_VOL) — master untouched, voice rides full level")
            return
        }
        ducked = true
        duckStarted = Date().timeIntervalSince1970
        var els: [(Int, Float32)] = []; var chs: [String] = []
        for el in [0, 1, 2] { let v = readVol(outDev, el); if v >= 0 { els.append((el, v)); chs.append("\"\(el)\":\(v)") } }  // LIVE scalars, synchronous, per-channel — never cachedVol
        writeJSONAtomic(DUCK_SNAP, "{\"device\":\"\(getOutputUID())\",\"taken_at\":\(duckStarted),\"channels\":{\(chs.joined(separator: ","))}}")
        writeJSONAtomic(DUCK_LEASE, "{\"pid\":\(getpid()),\"started_at\":\(duckStarted),\"heartbeat\":\(duckStarted)}")
        for (el, v) in els where v > DUCK_FLOOR + DUCK_FLOOR_EPS { writeVol(outDev, el, DUCK_FLOOR) }  // never RAISE a quieter master
        cachedVol = DUCK_FLOOR
        log("duck: master snapshot{\(chs.joined(separator: ","))} floor→\(DUCK_FLOOR) lease@pid\(getpid())")
    }
}
func unduck() {
    duckQ.async {
        guard ducked else { return }
        ducked = false
        if let snap = readJSON(DUCK_SNAP) {
            if (snap["mode"] as? String) == "app", let app = snap["app"] as? String,
               let vol = (snap["vol"] as? NSNumber)?.doubleValue {
                appVolume(app, set: true, to: Int(vol.rounded()))
                log("unduck: \(app) app-volume restored to \(Int(vol)) — master never moved")
            } else { restoreFromSnapshot(snap); log("unduck: master restored from snapshot") }
        }
        clearDuckState()
        cachedVol = max(0, readVol(outDev, 0))
    }
}
func recoverDuckLease() {                    // runs FIRST on duckQ at boot — before any server/duck verb
    guard FileManager.default.fileExists(atPath: DUCK_LEASE) else { return }
    let lease = readJSON(DUCK_LEASE)
    let now = Date().timeIntervalSince1970
    let pid = (lease?["pid"] as? NSNumber)?.int32Value ?? -1
    let hb = (lease?["heartbeat"] as? NSNumber)?.doubleValue ?? 0
    if pid > 0, kill(pid, 0) == 0, hb > 0, now - hb < DUCK_LEASE_LIVE { log("duck-recovery: live lease owned by pid \(pid) — hands off"); return }
    if let snap = readJSON(DUCK_SNAP), let taken = (snap["taken_at"] as? NSNumber)?.doubleValue, now - taken <= DUCK_SNAP_MAX_AGE {
        if (snap["mode"] as? String) == "app", let app = snap["app"] as? String,
           let vol = (snap["vol"] as? NSNumber)?.doubleValue {
            let back = appVolume(app, set: true, to: Int(vol.rounded()))
            clearDuckState()
            log("duck-recovery: app duck died mid-speech — \(app) \(back == 0 ? "restored to \(Int(vol))" : "not running, cleared")")
            return
        }
        restoreFromSnapshot(snap); clearDuckState()
        log("duck-recovery: prior instance died mid-duck — restored from fresh snapshot (age \(Int(now - taken))s)")
    } else {
        var unpinned = false
        for el in [0, 1, 2] { let v = readVol(outDev, el); if v >= 0, v <= DUCK_FLOOR + DUCK_FLOOR_EPS { if writeVol(outDev, el, DUCK_UNPIN_TO) { unpinned = true } } }
        log("duck-recovery: stale lease — \(unpinned ? "output was floor-pinned, unpinned to \(DUCK_UNPIN_TO) (snapshot NOT trusted, lease left untouched)" : "output not at floor")")
    }
}
duckQ.async { recoverDuckLease() }
every(1.0) { duckQ.async { let v = readVol(outDev, 0); if v >= 0 { cachedVol = v }; if ducked { writeJSONAtomic(DUCK_LEASE, "{\"pid\":\(getpid()),\"started_at\":\(duckStarted),\"heartbeat\":\(Date().timeIntervalSince1970)}") } } }

// ---- HTTP / SSE on :8107 -----------------------------------------------
// ORBIT_PORT overrides (test instances); production stays 8107. Channel B (:8107/b/*)
// lives in channel-b.swift — additive transport decision, see CHANNEL-B.md.
let PORT = NWEndpoint.Port(rawValue: UInt16(ProcessInfo.processInfo.environment["ORBIT_PORT"] ?? "8107") ?? 8107)!
var sseConns: [NWConnection] = []
let sseLock = NSLock()
func send(_ c: NWConnection, _ s: String) { c.send(content: s.data(using: .utf8), completion: .contentProcessed { _ in }) }
func httpResp(_ c: NWConnection, _ status: String, _ ctype: String, _ body: String) {
    let r = "HTTP/1.1 \(status)\r\nContent-Type: \(ctype)\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: *\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
    c.send(content: r.data(using: .utf8), completion: .contentProcessed { _ in c.cancel() })
}
func frameJSON(reset: Bool) -> String {
    lock.lock(); let srcs = Array(byObj.values); lock.unlock()
    var arr: [String] = []
    let now = CACurrentMediaTime()
    for s in srcs {
        let rms = s.frames > 0 ? sqrt(s.sumsq / max(1, s.frames)) : 0
        let active = (now - s.lastSeen) < 0.4 && s.peak > 0.005
        arr.append(String(format: "{\"obj\":%u,\"name\":\"%@\",\"peak\":%.4f,\"rms\":%.4f,\"act\":%@}", s.obj, s.label.replacingOccurrences(of: "\"", with: ""), s.peak, rms, active ? "1" : "0"))
        if reset { s.peak = 0; s.sumsq = 0; s.frames = 0 }
    }
    let t = Int(now * 1000)
    return "{\"t\":\(t),\"ducked\":\(ducked),\"s\":[" + arr.joined(separator: ",") + "]}"
}
// ---- NOW PLAYING: spawn the trusted /usr/bin/osascript, never in-process
// AppleEvents. A freshly-built binary's NSAppleScript gets silently TCC-denied
// for Automation>Music (background procs get no prompt); osascript spawned from
// this Aqua session is ALREADY granted -- proven returning "the cure / Olivia
// Rodrigo / ..." instantly. Runs on a BACKGROUND queue with a per-call timeout
// so a wedged Music can never stall the main-loop SSE/icon timers. Poll @2s.
let npLock = NSLock()
var npCache = "{\"app\":\"\",\"track\":\"\",\"artist\":\"\",\"album\":\"\",\"state\":\"\",\"pos\":0}"
let ART_PATH = NSString(string: "~/.hermes/profiles/donna/cache/scratch/orbit_art.img").expandingTildeInPath
let artLock = NSLock()
var artBytes: Data = Data()
var artKey: String = ""
var artType: String = "image/png"
var artHash: String = ""
var artPrevHash: String = ""
var artSettle: CFTimeInterval = 0
var npLastKey: String = ""
var itunesNext: CFTimeInterval = 0   // catalog-art lookup cooldown (Spotify & co.)
func runOA(_ src: String, _ timeout: Double) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", src]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    var res: String? = nil
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        let d = out.fileHandleForReading.readDataToEndOfFile()
        res = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        sem.signal()
    }
    do { try p.run() } catch { return nil }
    if sem.wait(timeout: .now() + timeout) == .timedOut { p.interrupt(); p.terminate(); return nil }
    // ⟦HONEST-VERBS⟧ a failed osascript exits non-zero with EMPTY stdout, which
    // used to return "" (non-nil) and made every Apple Events fallback report
    // success on failure. Exit status now decides: error ⇒ nil ⇒ {ok:false}.
    // waitUntilExit is MANDATORY before reading terminationStatus — Foundation
    // throws NSException on a live process (this exact line crash-looped the
    // daemon once; the stdout-EOF read means exit is imminent, so it's fast).
    p.waitUntilExit()
    return p.terminationStatus == 0 ? res : nil
}
func npJSON(_ app: String, _ st: String, _ rec: String, pos: Double = 0, dur: Double = 0) -> String {
    let f = rec.components(separatedBy: "\n")
    let trk = f.count > 0 ? f[0] : ""
    let key = trk.isEmpty ? "" : (app + "|" + trk)
    artLock.lock(); let ver = (artKey == key && !artBytes.isEmpty) ? artHash : ""; artLock.unlock()
    let d: [String: Any] = ["app": app, "state": st,
        "track": trk, "artist": f.count > 1 ? f[1] : "",
        "album": f.count > 2 ? f[2] : "", "pos": pos, "dur": dur, "art": key, "artv": ver]
    guard let j = try? JSONSerialization.data(withJSONObject: d), let s = String(data: j, encoding: .utf8) else {
        return "{\"app\":\"\",\"track\":\"\",\"artist\":\"\",\"album\":\"\",\"state\":\"\",\"pos\":0}"
    }
    return s
}
func httpRespBin(_ c: NWConnection, _ status: String, _ ctype: String, _ body: Data) {
    let r = "HTTP/1.1 \(status)\r\nContent-Type: \(ctype)\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: no-cache\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    c.send(content: Data(r.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
}
func dumpArtBytes(_ app: String) -> (Data, String)? {
    let script = "tell application \"\(app)\"\nif (count of artwork of current track) is 0 then return \"none\"\nset d to data of artwork 1 of current track\nend tell\nset f to POSIX file \"\(ART_PATH)\"\nset rn to open for access f with write permission\nset eof rn to 0\nwrite d to rn starting at 0\nclose access rn\nreturn \"ok\""
    guard (runOA(script, 2.5) ?? "") == "ok", let data = FileManager.default.contents(atPath: ART_PATH), data.count > 100 else { return nil }
    let h = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    return (data, h)
}
// Apple's PUBLIC catalog art, no credentials. For apps whose AppleScript has no
// `artwork` (Spotify returns `missing value`): search itunes by artist+track, take
// the top song hit, upgrade its 100x100 to 600x600, download + sha256. Runs on the
// bg poll queue; semaphores so it never blocks a runloop. Exact-match -> no lag.
func itunesArt(artist: String, track: String) -> (Data, String)? {
    let term = (artist + " " + track).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !term.isEmpty else { return nil }
    guard let enc = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let url = URL(string: "https://itunes.apple.com/search?term=\(enc)&entity=song&limit=1") else { return nil }
    let cfg = URLSessionConfiguration.ephemeral
    cfg.timeoutIntervalForRequest = 4
    var data: Data?; var code = 0; var e1: Error?
    let s1 = DispatchSemaphore(value: 0)
    URLSession(configuration: cfg).dataTask(with: url) { d, r, er in data = d; code = (r as? HTTPURLResponse)?.statusCode ?? 0; e1 = er; s1.signal() }.resume()
    if s1.wait(timeout: .now() + 4.5) == .timedOut { return nil }
    guard e1 == nil, code == 200, let d = data,
          let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
          let results = obj["results"] as? [[String: Any]],
          let first = results.first,
          let u100 = first["artworkUrl100"] as? String else { return nil }
    guard let artURL = URL(string: u100.replacingOccurrences(of: "100x100bb", with: "600x600bb")) else { return nil }
    var img: Data?; var e2: Error?
    let s2 = DispatchSemaphore(value: 0)
    URLSession(configuration: cfg).dataTask(with: artURL) { d2, _, er in img = d2; e2 = er; s2.signal() }.resume()
    if s2.wait(timeout: .now() + 4.5) == .timedOut { return nil }
    guard e2 == nil, let bytes = img, bytes.count > 1000 else { return nil }
    let h = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    return (bytes, h)
}
// Whichever scriptable app is measurably LOUD right now. A silent (paused-but-
// reported) Music must never shadow an audible Spotify.
func activeMediaApp() -> String? {
    let now = CACurrentMediaTime()
    lock.lock(); let srcs = Array(byObj.values); lock.unlock()
    var best: (String, CFTimeInterval)? = nil
    for s in srcs {
        let base = s.label.components(separatedBy: ":").first ?? s.label
        guard base == "Music" || base == "Spotify" else { continue }
        if now - s.lastLoud < 2.0 && (best == nil || s.lastLoud > best!.1) { best = (base, s.lastLoud) }
    }
    return best?.0
}
// ---- NOW PLAYING PROVIDER SEAM (cross-OS) --------------------------------
// The visualizer consumes ONE normalized now-playing record (title/artist/
// album/state/app + artwork). HOW it is sourced is OS-specific; the JSON
// contract to the plugin (app, state, track, artist, album, pos, dur, art,
// artv) is NOT. On macOS the bus is primary, Apple Events is the fallback.
//
// PORT CONTRACT — to port the sidecar, reimplement the providers below for the
// target OS and keep returning the same NowPlaying + the same /nowplaying JSON:
//   macOS   : MediaRemote "Now Playing" bus (providerMediaRemote via platform
//             /usr/bin/perl + our vendored libOrbitNP.dylib) + Apple Events fallback.
//   Linux   : MPRIS over D-Bus. Enumerate org.mpris.MediaPlayer2.* names; read
//             .Metadata (xesam:title/artist/album, mpris:artUrl), .PlaybackStatus
//             ("Playing"/"Paused"), .Position (µs). Pick the active/Playing one.
//   Windows : SMTC — Windows.Media.Control.GlobalSystemMediaTransportControls-
//             SessionManager.GetCurrentSessionAsync() -> MusicPanelProperties
//             (Song/Artist/Album), TimelineProperties (Position/Duration), and
//             Thumbnail stream -> bytes for artwork.
// (The per-app audio LEVEL tap is the other OS-specific subsystem: macOS
//  CoreAudio process tap -> Linux PipeWire per-sink-input monitor / PulseAudio
//  monitor-of-monitor -> Windows WASAPI per-session. Same SSE :8107 contract.)
struct NowPlaying { var app = ""; var state = ""; var track = ""; var artist = ""; var album = ""; var pos = 0.0; var dur = 0.0; var art: Data?; var artMime = "image/jpeg" }
var guiConnTouched = false   // set once a WindowServer (GUI) connection is forced for the bus read

func appNameForPID(_ pid: Int) -> String {
    if pid > 0, let a = NSRunningApplication(processIdentifier: pid_t(pid))?.localizedName, !a.isEmpty { return a }
    return ""
}
// macOS primary: read the OS Now Playing bus (any app; artwork; streamed OR
// offline). Returns nil when nothing is playing or the bus is unreachable.
//
// READER MECHANISM — mirrors nowplaying-cli's PROVEN path, not a direct call:
// we exec /usr/bin/perl (an Apple PLATFORM binary) with a 14-line DynaLoader
// helper that loads OUR vendored libOrbitNP.dylib and calls adapter_get_env,
// which prints the normalized bus dict as JSON. WHY not call internal_get
// directly (the compiled-in adapter)? On this OS the Now Playing daemon only
// answers platform-binary requesters: every in-process read by our own
// (ad-hoc/Developer-ID) binary returns EMPTY — proven headless AND inside a
// GUI session, including nowplaying-cli's OWN in-process fallback with its
// helper disabled. /usr/bin/perl is the requesting process, so it answers.
// (internal_get stays linked for the /mrprobe diagnostic only.)
func resolveHelperPaths() -> (pl: String, dylib: String)? {
    let fm = FileManager.default
    let argv0 = CommandLine.arguments.first ?? fm.currentDirectoryPath
    let exeDir = (argv0 as NSString).deletingLastPathComponent
    var bases = [exeDir]
    let parent = (exeDir as NSString).deletingLastPathComponent
    if parent != exeDir { bases.append(parent) }
    let layouts: [(String, String)] = [
        ("mediaremote-mini.pl", "libOrbitNP.dylib"),
        ("scripts/mediaremote-mini.pl", "libOrbitNP.dylib"),
        ("share/nowplaying-cli/scripts/mediaremote-mini.pl", "lib/nowplaying-cli/libOrbitNP.dylib"),
    ]
    for b in bases {
        for (pl, dy) in layouts {
            let p = (b as NSString).appendingPathComponent(pl)
            let dd = (b as NSString).appendingPathComponent(dy)
            if fm.isReadableFile(atPath: p), fm.isReadableFile(atPath: dd) { return (p, dd) }
        }
    }
    return nil
}

// Runs the platform-perl reader once and returns the normalized bus dict, or
// nil on any failure (missing artifacts, non-zero exit, no meaningful field).
// NOTE: adapter_get_env prints ~200KB (artwork base64). stdout MUST be drained
// CONCURRENTLY with the child running — reading only after exit deadlocks once
// the 64KB pipe buffer fills (perl blocks on write, never exits). A 5s watchdog
// kills a wedged reader so it can never hang the 2s poll loop.
// ⟦MR-STALE / ART-STARVE⟧ poll-thread state (single serial poller — no lock needed).
var mrLastPos: Double = -1
var mrFrozen = 0
var artStarveKey = ""
var artStarveAt: CFTimeInterval = 0
func readNowPlayingViaPerl() -> [String: Any]? {
    guard let paths = resolveHelperPaths() else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    p.arguments = [paths.pl, paths.dylib, "adapter_get_env"]
    let outPipe = Pipe(); p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    var data = Data()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { data = outPipe.fileHandleForReading.readDataToEndOfFile(); drained.signal() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
    p.waitUntilExit(); drained.wait()
    guard p.terminationStatus == 0, !data.isEmpty,
          let obj = try? JSONSerialization.jsonObject(with: data),
          let d = obj as? [String: Any] else { return nil }
    for k in ["title", "artist", "album", "bundleIdentifier"] {
        if let v = d[k] as? String, !v.isEmpty { return d }
    }
    return nil
}

// Diagnostic mirror of the reader, exposing resolved paths, exit code, stdout
// length, parsed title, and perl stderr — to pin daemon-side read failures.
func npDiag() -> [String: Any] {
    guard let paths = resolveHelperPaths() else {
        return ["paths": "UNRESOLVED", "exe0": CommandLine.arguments.first ?? "",
                "cwd": FileManager.default.currentDirectoryPath]
    }
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    p.arguments = [paths.pl, paths.dylib, "adapter_get_env"]
    let o = Pipe(); let e = Pipe(); p.standardOutput = o; p.standardError = e
    do { try p.run() } catch { return ["pl": paths.pl, "dylib": paths.dylib, "runErr": "\(error)"] }
    var outD = Data(); var errS = ""
    let d1 = DispatchSemaphore(value: 0); let d2 = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { outD = o.fileHandleForReading.readDataToEndOfFile(); d1.signal() }
    DispatchQueue.global().async { errS = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""; d2.signal() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
    p.waitUntilExit(); d1.wait(); d2.wait()
    var title = ""
    if let obj = try? JSONSerialization.jsonObject(with: outD), let d = obj as? [String: Any] { title = (d["title"] as? String) ?? "" }
    return ["pl": paths.pl, "dylib": paths.dylib, "rc": Int(p.terminationStatus),
            "outLen": outD.count, "title": title, "err": errS]
}

func providerMediaRemote() -> NowPlaying? {
    guard let raw = readNowPlayingViaPerl() else { clearClass(); return nil }
    let d = raw as NSDictionary
    func s(_ k: String) -> String { (d.object(forKey: k as NSString) as? String) ?? "" }
    func n(_ k: String) -> Double { (d.object(forKey: k as NSString) as? NSNumber)?.doubleValue ?? 0 }
    // Stash classification inputs for the duck/pause resolver — read at the duck
    // trigger, never spawning perl on the hot path. Done BEFORE the title guard so
    // a paused / title-less session still refreshes the cache (playing=false).
    let ciBundle = s("bundleIdentifier")
    let ciPlaying = (d.object(forKey: "playing" as NSString) as? NSNumber)?.boolValue ?? false
    let ciItem = s("contentItemIdentifier")
    classLock.lock(); classCache = ClassInfo(bundleId: ciBundle, playing: ciPlaying, contentItem: ciItem, ts: Date()); classLock.unlock()
    let title = s("title"); if title.isEmpty { return nil }
    var np = NowPlaying()
    np.track = title
    np.artist = s("artist")
    np.album = s("album")
    np.state = ((d.object(forKey: "playing" as NSString) as? NSNumber)?.boolValue ?? false) ? "playing" : "paused"
    np.app = appNameForPID(Int(n("processIdentifier")))
    np.pos = n("elapsedTime"); np.dur = n("duration")
    // Artwork arrives BASE64-encoded STRING via the JSON helper (in-process
    // internal_get gave raw Data); decode before the >100B sanity gate.
    if let b64 = d.object(forKey: "artworkData" as NSString) as? String,
       let ad = Data(base64Encoded: b64), ad.count > 100 {
        np.art = ad; let m = s("artworkMimeType"); if !m.isEmpty { np.artMime = m }
    }
    return np
}
// Commit a bus record to the shared artwork pipeline and emit the plugin JSON.
// The bus is NOT reliably atomic: at a track change the record can carry the
// new text while `artworkData` still holds the PREVIOUS track's bytes (caught
// in the wild 2026-10-26: card showed the old cover under the new headline).
// So the bus path obeys the same settle law as the Apple Events path: never
// commit the previous cover under a new key — hold while the hash equals the
// last track's art until the bytes differ or a 3s grace expires (same-album
// case), during which the key has no artv and the panel shows a neutral tile.
func npBusJSON(_ np: NowPlaying) -> String {
    let key = np.app + "|" + np.track
    if let ad = np.art {
        let h = SHA256.hash(data: ad).map { String(format: "%02x", $0) }.joined()
        let now = CACurrentMediaTime()
        if key != npLastKey { npLastKey = key; artSettle = now + 3.0 }
        artLock.lock()
        if artKey != key || artHash != h {
            if artKey != key && h == artPrevHash && now < artSettle {
                // settle pending: bytes still match the previous track's art —
                // leave the old art under the old key; this key stays art-less.
            } else {
                artBytes = ad; artType = np.artMime; artKey = key; artHash = h; artPrevHash = h
            }
        }
        artLock.unlock()
    }
    artLock.lock(); let ver = (artKey == key && !artBytes.isEmpty) ? artHash : ""; artLock.unlock()
    let obj: [String: Any] = ["app": np.app, "state": np.state, "track": np.track, "artist": np.artist, "album": np.album, "pos": np.pos, "dur": np.dur, "art": key, "artv": ver]
    guard let j = try? JSONSerialization.data(withJSONObject: obj), let str = String(data: j, encoding: .utf8) else { return "" }
    return str
}
func readNowPlaying() -> String {
    // Provider chain (see seam above): OS Now Playing bus first; Apple Events
    // Music/Spotify below is the legacy fallback for anything that skips the bus.
    // ⟦MR-STALE / ART-STARVE⟧ The bus is fast but its cache is a liar: caught in the
    // wild 2026-10-26, MediaRemote froze at pos 3.4 for 3+ minutes while Music sat at
    // 327, and its artworkData served covers three tracks old — updating only on track
    // CHANGE, dying in between. Trusting it unconditionally starved the healthy Apple
    // Events fallback (fresh position, real artwork, catalog resolve). So: a playing
    // source whose position never advances is stale, and a key whose art never commits
    // for 8s has been served lies — both drop to the fallback instead of poisoning the
    // panel. Correct state live; never pin the UI to one unreliable witness.
    if let np = providerMediaRemote() {
        if np.state == "playing" {
            if np.pos > 0 && np.pos == mrLastPos { mrFrozen += 1 } else { mrFrozen = 0 }
            mrLastPos = np.pos
        } else { mrFrozen = 0; mrLastPos = -1 }
        if mrFrozen < 4 {
            let s = npBusJSON(np)
            if !s.isEmpty {
                if !s.contains("\"artv\":\"\"") { artStarveKey = ""; return s }
                let k = np.app + "|" + np.track
                if k != artStarveKey { artStarveKey = k; artStarveAt = CACurrentMediaTime() }
                if CACurrentMediaTime() - artStarveAt < 8 { return s }
                log("ART-STARVE \(k) 8s no art — falling back to Apple Events")
            }
        } else if mrFrozen == 4 {
            log("MR-STALE pos frozen at \(np.pos) — falling back to Apple Events")
        }
    }
    let empty = "{\"app\":\"\",\"track\":\"\",\"artist\":\"\",\"album\":\"\",\"state\":\"\",\"pos\":0}"
    // Follow the SPEAKER, not a fixed order. The loud app wins; silent-but-
    // reported apps are fallback only.
    var order: [String] = []
    if let l = activeMediaApp() { order.append(l) }
    for k in ["Music", "Spotify"] where !order.contains(k) { order.append(k) }
    for app in order {
        guard (runOA("tell application \"System Events\" to return (name of processes) contains \"\(app)\"", 0.8) ?? "") == "true" else { continue }
        let st = runOA("tell application \"\(app)\" to return \"\" & (player state)", 0.8) ?? ""
        guard st == "playing" || st == "paused" else { continue }
        guard let rec = runOA("tell application \"\(app)\" to return (name of current track) & linefeed & (artist of current track) & linefeed & (album of current track) & linefeed & ((duration of current track) as string)", 0.8) else { continue }
        // Artwork settle: Apple Music's `artwork` property LAGS `current track`.
        // Never commit the previous cover under the new key. Re-grab each poll
        // until the bytes actually differ from the last track's art; only after a
        // 3s grace accept an unchanged image (legit same-album), so the panel
        // shows a neutral tile rather than the WRONG album.
        let key = app + "|" + (rec.components(separatedBy: "\n").first ?? "")
        let now = CACurrentMediaTime()
        if key != npLastKey { npLastKey = key; artSettle = now + 3.0 }
        artLock.lock(); let cur = artKey; artLock.unlock()
        if cur != key, let (data, h) = dumpArtBytes(app) {
            if h != artPrevHash || now > artSettle {
                let type = (data.count > 8 && data[0] == 0x89 && data[1] == 0x50) ? "image/png" : "image/jpeg"
                artLock.lock(); artBytes = data; artType = type; artKey = key; artPrevHash = h; artHash = h; artLock.unlock()
            }
        }
        // No AppleScript art (Spotify & co. expose none) -> resolve from Apple's
        // public catalog by artist+track. Exact-match, no property lag, zero creds.
        // Music keeps its native artwork path untouched. Cooldown so an unmatched
        // lookup can't hammer iTunes every poll.
        artLock.lock(); let stillMissing = artKey != key; artLock.unlock()
        if app != "Music" && stillMissing && now >= itunesNext {
            itunesNext = now + 8.0
            let rp = rec.components(separatedBy: "\n")
            let t0 = rp.first ?? ""
            let a0 = rp.count > 1 ? rp[1] : ""
            if let (data, h) = itunesArt(artist: a0, track: t0) {
                let type = (data.count > 8 && data[0] == 0x89 && data[1] == 0x50) ? "image/png" : "image/jpeg"
                artLock.lock(); artBytes = data; artType = type; artKey = key; artPrevHash = h; artHash = h; artLock.unlock()
                log("catalog art ok \(app): \(t0)")
            }
        }
        // ⟦MR-STALE⟧ fallback carries position too — the bar and the position-advance
        // clock need it; one extra 0.8s query is nothing on this (cold) path.
        let fpos = Double(runOA("tell application \"\(app)\" to return (player position as string)", 0.8) ?? "") ?? 0
        // duration arrived as line 4 of rec — Music reports seconds, Spotify ms.
        let rd = rec.components(separatedBy: "\n")
        var fdur = Double(rd.count > 3 ? rd[3] : "") ?? 0
        if app == "Spotify" { fdur /= 1000.0 }
        return npJSON(app, st, rec, pos: fpos, dur: fdur)
    }
    return empty
}
// ---- spoken-vs-music duck/pause (Slice A) -----------------------------------
// Duck (volume floor) suits MUSIC; SPOKEN content (podcasts, audiobooks) should be
// PAUSED on interruption and resumed after. Trigger = POST /command (orbit speech — POST /command"
// start/end). Strategy: ALWAYS duck instantly (covers the ~1s MediaRemote pause
// latency AND apps that ignore the pause command — unduck restores it), and ADDITION-
// ally pause spoken content. On release: unduck + SAFE-RESUME, guarded by a fresh bus
// read (same bundle, same contentItemIdentifier, still paused) so we never resume
// something the user already resumed or advanced past.
let CMD_PLAY = 0, CMD_PAUSE = 1, CMD_TOGGLE = 2   // MediaRemote MRCommand values

struct ClassInfo { var bundleId = ""; var playing = false; var contentItem = ""; var ts = Date.distantPast }
let classLock = NSLock(); var classCache = ClassInfo()
func clearClass() { classLock.lock(); classCache = ClassInfo(); classLock.unlock() }

struct PauseState { var ours = false; var bundleId = ""; var contentItem = ""; var ts = Date.distantPast }
let pauseLock = NSLock(); var pauseState = PauseState()

// Substring hints on the (lowercased) bundle identifier — robust without pinning
// exact reverse-DNS ids; an app that matches neither falls to "unknown" → duck
// (wrongly-pausing is worse than wrongly-ducking). Mixed apps (YouTube) are left
// "unknown" here on purpose — audio-content detection (Slice C) owns those.
let SPOKEN_HINTS = ["podcast", "prismbooks", "audible", "audiobook", "overcast", "libby", "hoopla", "pocketcasts"]
let MUSIC_HINTS  = ["com.apple.music", "spotify", "tidal", "deezer", "amazon.music", "soundcloud"]
func contentType(bundleId: String?) -> String {   // "spoken" | "music" | "unknown"
    guard let b = bundleId?.lowercased(), !b.isEmpty else { return "unknown" }
    if SPOKEN_HINTS.contains(where: { b.contains($0) }) { return "spoken" }
    if MUSIC_HINTS.contains(where: { b.contains($0) }) { return "music" }
    return "unknown"
}

// Post a MediaRemote command to the current now-playing app via the SAME proven
// platform-perl path the reader uses; command code via the dylib's env option.
// Returns true only if perl exits 0 and the dylib prints "true" (framework accept).
func sendMediaCommand(_ code: Int) -> Bool {
    guard let paths = resolveHelperPaths() else { return false }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
    p.arguments = [paths.pl, paths.dylib, "adapter_send_command"]
    var env = ProcessInfo.processInfo.environment
    env["MEDIAREMOTEADAPTER_OPTION_command"] = "\(code)"
    p.environment = env
    let outPipe = Pipe(); p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { log("sendMediaCommand run failed: \(error)"); return false }
    var data = Data()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { data = outPipe.fileHandleForReading.readDataToEndOfFile(); drained.signal() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if p.isRunning { p.terminate() } }
    p.waitUntilExit(); drained.wait()
    let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return p.terminationStatus == 0 && out == "true"
}

// Speech START: instant duck for everyone; spoken + actively playing → also pause.
func duckOrPause() {
    classLock.lock(); let c = classCache; classLock.unlock()
    duck()
    if contentType(bundleId: c.bundleId) == "spoken" && c.playing {
        pauseLock.lock(); pauseState = PauseState(ours: true, bundleId: c.bundleId, contentItem: c.contentItem, ts: Date()); pauseLock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = sendMediaCommand(CMD_PAUSE)
            log("pause spoken(\(c.bundleId)) ok=\(ok)")
            if !ok { pauseLock.lock(); pauseState.ours = false; pauseLock.unlock() }  // duck already covers silence; don't try to resume
        }
    }
}

// Speech END: always restore volume; then resume ONLY if we paused it and it is
// still the same paused item (fresh read — the 2s cache could be stale).
func unduckOrResume() {
    unduck()
    pauseLock.lock(); let ps = pauseState; pauseState = PauseState(); pauseLock.unlock()
    guard ps.ours else { return }
    DispatchQueue.global(qos: .userInitiated).async {
        guard let f = readNowPlayingViaPerl() else { return }
        let playingNow = ((f["playing"] as? NSNumber)?.boolValue) ?? false
        let bundle = (f["bundleIdentifier"] as? String) ?? ""
        let item = (f["contentItemIdentifier"] as? String) ?? ""
        let sameBundle = bundle == ps.bundleId
        // If either side has no contentItemIdentifier we can't disprove a match →
        // rely on bundle + paused-state (still strictly guarded against the item
        // advancing to a DIFFERENT id, the real podcast auto-advance hazard).
        let sameItem = item.isEmpty || ps.contentItem.isEmpty || item == ps.contentItem
        if !playingNow && sameBundle && sameItem {
            let ok = sendMediaCommand(CMD_PLAY); log("resume spoken(\(bundle)) ok=\(ok)")
        } else {
            log("resume skipped: playing=\(playingNow) sameBundle=\(sameBundle) sameItem=\(sameItem)")
        }
    }
}

// ---- CONTROL PLANE v1 (election, snapshot handshake, push) -----------------
// Shared state + cpSend/cpBroadcast/sourcesArr live UP TOP (early-declared —
// async tap workers reach them before later top-level init). Events flow on the
// SAME SSE conn as levels (channel-A style: no id lines — A frames never had them).
// main = boot id that POSTed /hello MOST RECENTLY and has a live proto SSE conn.
// Called on every /hello, every proto attach, and the prune timer. On change the
// new main gets {you:true}, the demoted one {you:false} (if still connected).
func cpElection() {
    cpLock.lock()
    var best: (String, Date)? = nil
    for (b, r) in roster where r.conn?.state == .ready && r.lastHello != Date.distantPast {
        if best == nil || r.lastHello > best!.1 { best = (b, r.lastHello) }
    }
    let newMain = best?.0; let oldMain = mainBoot
    let changed = newMain != oldMain; mainBoot = newMain
    let nc = newMain.flatMap { roster[$0]?.conn }; let oc = oldMain.flatMap { roster[$0]?.conn }
    cpLock.unlock()
    guard changed else { return }
    log("cp-election main=\(newMain ?? "none") (was \(oldMain ?? "none"))")
    if let c = nc, c.state == .ready, let m = newMain { cpSend(c, "elected", "{\"you\":true,\"main\":\"\(m)\"}") }
    if let c = oc, c.state == .ready { cpSend(c, "elected", "{\"you\":false,\"main\":\"\(newMain ?? "")\"}") }
}
// A proto SSE conn attached: register (boot may arrive later via POST /hello),
// run election, then answer the full-state snapshot IMMEDIATELY (reconnect==resync).
func cpAttach(_ conn: NWConnection, _ boot: String?, _ epoch: Double = 0, _ role: String = "") {
    // ⟦EPOCH-TRUTH⟧ enforce BEFORE any headers: replaced boots are 410'd, fatally.
    let (cb, ce) = curClaim()
    if ce > 0 && role != "doctor" {
        if let b = boot, !b.isEmpty { if epoch <= ce && b != cb { goneResp(conn); return } }
        else { goneResp(conn); return }
    }
    cpLock.lock(); protoConns.append(conn)
    if let b = boot, !b.isEmpty { let r = roster[b] ?? HelloRec(); r.conn = conn; if epoch > 0 { r.epoch = max(r.epoch, epoch) }; roster[b] = r }
    cpLock.unlock()
    streamRegLock.lock(); streamReg.append((conn, boot ?? "", epoch, role)); streamRegLock.unlock()
    streamEnforce()
    cpElection()
    cpLock.lock(); let you = boot.map { !$0.isEmpty && mainBoot == $0 } ?? false; cpLock.unlock()
    npLock.lock(); let np = npCache; npLock.unlock()
    // ⟦STATE-TRUTH⟧ hello is the COMPLETE resync snapshot: control state (mic/stt/tts)
    // rides discovery itself — a restarted sidecar or reloaded renderer learns the
    // truth at hello time, not up to 8s later via /b/status polling. Never let the UI
    // paint defaults over real state.
    cpSend(conn, "hello", "{\"epoch\":\(EPOCH),\"proto\":1,\"version\":\"\(SIDECAR_VERSION)\",\"elected\":\(you),\"state\":\(ChannelB.shared.statusJSON()),\"sources\":\(sourcesArr()),\"nowplaying\":\(np)}")
}
// Roster pruning: hello older than 30s with NO live conn is dropped; a dead conn
// drops to nil so the same boot can re-attach. Then re-elect (standby takes over).
func cpPrune() {
    cpLock.lock()
    let now = Date()
    for (b, r) in roster where r.conn?.state != .ready {
        r.conn = nil
        if now.timeIntervalSince(r.lastHello) > 30 { roster.removeValue(forKey: b); log("cp-prune \(b)") }
    }
    protoConns = protoConns.filter { $0.state == .ready }
    cpLock.unlock()
    streamRegLock.lock(); streamReg = streamReg.filter { $0.c.state == .ready }; streamRegLock.unlock()
    streamEnforce()
    cpElection()
}
// ---- /ctl command channel: one versioned door for all verbs -----------------
// Unknown cmd => {ok:false,err:"unknown-cmd"} at HTTP 200 (never a silent 404).
// Legacy endpoints stay untouched; these dispatch to the SAME handler logic.
func ctlDispatch(_ cmd: String, _ args: [String: Any]) -> (Bool, String) {   // (ok, resultJSON | err)
    switch cmd {
    case "mode":       return ChannelB.shared.ctlMode(args)        // same verbs as POST /b/mode
    case "inject":     return ChannelB.shared.ctlInject(args)      // same as POST /b/inject
    case "tts-speak":  return ChannelB.shared.ctlSpeak(args)       // same as POST /b/tts/speak
    case "mic-mute":   return ChannelB.shared.ctlMicMute(args)     // == /b/mode {"stt":!mute}
    case "media":      return ctlMedia(args["action"] as? String ?? "", args)   // ⟦TRANSPORT⟧ player control: bus first, Apple Events fallback
    case "duck":       let on = (args["on"] as? Bool) ?? true      // == POST /command duck|unduck
                        if on { duckOrPause() } else { unduckOrResume() }
                        return (true, "{\"ducked\":\(ducked)}")
    case "speaker-mute": return (true, "{\"noop\":true}")          // NO speaker-mute verb exists yet — noop, do NOT invent audio behavior
    case "stage":      // ⟦DIRECTOR REMOTE⟧ silent stage directives to the plugin:
                        // attention | flyin | rest — the stage moves, the room stays quiet.
                        let what = (args["what"] as? String ?? "attention")
                        cpBroadcast("direct", "{\"what\":\"\(what)\"}")
                        return (true, "{\"broadcast\":\"direct\",\"what\":\"\(what)\"}")
    default:           return (false, "unknown-cmd")
    }
}

// ⟦TRANSPORT⟧ /ctl media — write path mirrors the read path's two-witness doctrine:
// MediaRemote bus command first (works for ANY Now Playing app), Apple Events per-app
// fallback when the bus refuses or the verb only exists in the app's dictionary
// (shuffle/repeat/seek/volume are not bus verbs). Unsupported combos answer false
// with a reason — the card dims those buttons; we never ship one that lies.
func npAppNow() -> String {
    npLock.lock(); let j = npCache; npLock.unlock()
    guard let r = j.range(of: "\"app\":\"") else { return "" }
    let s = j[r.upperBound...]; guard let e = s.firstIndex(of: "\"") else { return "" }
    return String(s[..<e])
}
func ctlMedia(_ action: String, _ args: [String: Any]) -> (Bool, String) {
    let app = npAppNow()
    let oa: (String) -> String? = { runOA("tell application \"\(app)\" to \($0)", 0.8) }
    func transport(_ code: Int, _ verb: String) -> (Bool, String) {
        if sendMediaCommand(code) { return (true, "{\"via\":\"bus\"}") }
        if (app == "Music" || app == "Spotify"), oa(verb) != nil { return (true, "{\"via\":\"applescript\"}") }
        return (false, "no-transport")
    }
    switch action {
    case "toggle": return transport(2, "playpause")
    case "play":   return transport(0, "play")
    case "pause":  return transport(1, "pause")
    case "next":   return transport(4, "next track")
    case "prev":   return transport(3, "previous track")
    case "shuffle":
        let on = (args["on"] as? Bool) ?? true
        if app == "Music"   { return oa("set shuffle enabled to \(on)") != nil ? (true, "{\"via\":\"applescript\"}") : (false, "shuffle-failed") }
        if app == "Spotify" { return oa("set shuffling to \(on)")        != nil ? (true, "{\"via\":\"applescript\"}") : (false, "shuffle-failed") }
        return (false, "shuffle-unsupported")
    case "repeat":
        let m = args["mode"] as? String ?? "off"
        if app == "Music" {
            let v = m == "one" ? "one" : m == "all" ? "all" : "off"
            return oa("set song repeat to \(v)") != nil ? (true, "{\"via\":\"applescript\"}") : (false, "repeat-failed")
        }
        if app == "Spotify" {
            let v = m == "one" ? "one" : m == "all" ? "all" : "none"
            return oa("set repeating to \(v)") != nil ? (true, "{\"via\":\"applescript\"}") : (false, "repeat-failed")
        }
        return (false, "repeat-unsupported")
    case "seek-rel":
        // Block-form AppleScript: oa() is one-line `tell … to <stmt>` and a
        // multi-statement script CANNOT ride it — the trailing lines fall out of
        // the tell block, error, and (pre-HONEST-VERBS) silently "succeeded".
        let secs = (args["secs"] as? NSNumber)?.doubleValue ?? 0
        if app == "Music" {
            let ok = runOA("tell application \"Music\"\nset p to (player position) + \(secs)\nif p < 0 then set p to 0\ntry\nif p > (duration of current track) then set p to (duration of current track)\nend try\nset player position to p\nend tell", 1.5) != nil
            return ok ? (true, "{\"via\":\"applescript\"}") : (false, "seek-failed")
        }
        if app == "Spotify" {
            let ok = runOA("tell application \"Spotify\"\nset p to (track position) + \(Int(secs * 1000))\nif p < 0 then set p to 0\ntry\nif p > (duration of current track) then set p to (duration of current track)\nend try\nset track position to p\nend tell", 1.5) != nil
            return ok ? (true, "{\"via\":\"applescript\"}") : (false, "seek-failed")
        }
        return (false, "seek-unsupported")   // bus seek needs an options dict — adapter speaks bare codes
    case "seek-abs":
        let pos = (args["pos"] as? NSNumber)?.doubleValue ?? 0
        if app == "Music"   { return runOA("tell application \"Music\" to set player position to \(max(0, pos))", 1.5) != nil ? (true, "{\"via\":\"applescript\"}") : (false, "seek-failed") }
        if app == "Spotify" { return runOA("tell application \"Spotify\" to set track position to \(max(0, Int(pos * 1000)))", 1.5) != nil ? (true, "{\"via\":\"applescript\"}") : (false, "seek-failed") }
        return (false, "seek-unsupported")
    case "set-volume":
        let vol = max(0.0, min(1.0, (args["vol"] as? NSNumber)?.doubleValue ?? -1))
        if vol < 0 { return (false, "vol-required") }
        let pct = Int((vol * 100).rounded())
        if app == "Music"   { return oa("set sound volume to \(pct)") != nil ? (true, "{\"vol\":\(pct)}") : (false, "volume-failed") }
        if app == "Spotify" { return oa("set player volume to \(pct)") != nil ? (true, "{\"vol\":\(pct)}") : (false, "volume-failed") }
        return (false, "volume-unsupported")
    default: return (false, "unknown-action")
    }
}


// ---- SELF-HEALTH (blueprint §5) ----------------------------------------------
// Default-output-device listener + IOProc stall watchdog, both feeding ONE
// rebuild path built from the SAME tap lifecycle as startup. The rebuild runs on
// its own serial queue: a wedged coreaudiod can stall rebuilds only, never the
// HTTP plane / channel B / main runloop (same hardening doctrine as tapObj).
let rebuildQ = DispatchQueue(label: "orbit.rebuild")
var rebuildWork: DispatchWorkItem?      // rebuildQ-owned only
func rebuildTaps(_ reason: String) {    // CALL ONLY ON rebuildQ
    var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: AudioObjectPropertyElement(0))
    var d = AudioObjectID(0); var s = UInt32(4)
    let got = (AudioObjectGetPropertyData(hw, &a, 0, nil, &s, &d) == noErr) && d != 0
    if reason == "device-change", got, d == outDev { return }   // no-op churn (e.g. listener fired by our own aggregate)
    log("REBUILD reason=\(reason)")
    if got {                            // re-resolve the output plane BEFORE re-tapping
        outDev = d
        var au = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: AudioObjectPropertyElement(0))
        var ur: Unmanaged<CFString>?; var us = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        AudioObjectGetPropertyData(d, &au, 0, nil, &us, &ur)
        setOutputUID((ur?.takeRetainedValue() as String?) ?? "")
    }
    lock.lock(); let all = Array(byObj.values); lock.unlock()
    for t in all {                      // synchronous teardown on rebuildQ (blocking CoreAudio stays off main)
        AudioDeviceStop(t.agg, t.ioID); AudioDeviceDestroyIOProcID(t.agg, t.ioID)
        AudioHardwareDestroyAggregateDevice(t.agg); AudioHardwareDestroyProcessTap(t.tap)
        lock.lock(); byAgg.removeValue(forKey: t.agg); byObj.removeValue(forKey: t.obj); lock.unlock()
    }
    lastRender = 0
    scan()                              // same spawn path as startup (tap+/tap- broadcast sources)
}
var cpDevAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: AudioObjectPropertyElement(0))
AudioObjectAddPropertyListenerBlock(hw, &cpDevAddr, rebuildQ) { _, _ in
    rebuildQ.async {                    // 1s debounce: DAC flap / aggregate churn fires bursts
        rebuildWork?.cancel()
        let w = DispatchWorkItem { rebuildTaps("device-change") }
        rebuildWork = w
        rebuildQ.asyncAfter(deadline: .now() + 1, execute: w)
    }
}

let server = try! NWListener(using: .tcp, on: PORT)
func handle(_ conn: NWConnection, _ req: String) {
    let first = req.split(separator: "\r\n").first.map(String.init) ?? ""
    let parts = first.split(separator: " ")
    guard parts.count >= 2 else { httpResp(conn, "400 Bad Request", "text/plain", "bad"); return }
    let method = String(parts[0]); let path = String(parts[1])
    // Channel B (:8107/b/*) — STT-out SSE + TTS-in streamed. Additive; channel A untouched.
    if path.hasPrefix("/b/") { if ChannelB.shared.handle(conn, method, path, req) { return } }
    if method == "OPTIONS" {
        conn.send(content: "HTTP/1.1 204 No Response\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET,POST,OPTIONS\r\nAccess-Control-Allow-Headers: *\r\n\r\n".data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() }); return
    }
    if path == "/stream" || path.hasPrefix("/stream?") {
        send(conn, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nAccess-Control-Allow-Origin: *\r\nConnection: keep-alive\r\n\r\n")
        sseLock.lock(); sseConns.append(conn); sseLock.unlock()
        if path.hasPrefix("/stream?") {          // control plane: proto=1 opts in; proto-less query params change NOTHING
            let q = String(path.dropFirst("/stream?".count))
            func qp(_ k: String) -> String? {
                for kv in q.split(separator: "&") {
                    let p = kv.split(separator: "=", maxSplits: 1)
                    if p.count == 2, String(p[0]) == k { return String(p[1]).removingPercentEncoding ?? String(p[1]) }
                }
                return nil
            }
            if qp("proto") == "1" { cpAttach(conn, qp("boot"), Double(qp("epoch") ?? "") ?? 0, qp("role") ?? "") }
        }
        return
    }
    if path == "/sources" { httpResp(conn, "200 OK", "application/json", "{\"sources\":" + sourcesArr() + "}"); return }
    if path == "/sky" { httpResp(conn, "200 OK", "application/json", skySnapshot()); return } // Sky P3: derived-facts record snapshot (t_c79ef288)
    if path == "/volume" { httpResp(conn, "200 OK", "application/json", "{\"vol\":\(curVol()),\"ducked\":\(ducked)}"); return }
    if path == "/npdbg" {
        let d = npDiag(); let body = (try? JSONSerialization.data(withJSONObject: d)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        httpResp(conn, "200 OK", "application/json", body); return
    }
    if path == "/claim" {
        // A GET from the claimer doubles as its lease refresh (~4s probe cadence).
        claimLock.lock(); for k in claimExpiry.keys where claimExpiry[k]! > Date() { claimExpiry[k] = Date().addingTimeInterval(30) }; claimLock.unlock()
        let on = claimState()
        lock.lock(); let labels = byObj.values.map { $0.label }.sorted(); lock.unlock()
        let taps = labels.map { "\"\($0)\"" }.joined(separator: ",")
        httpResp(conn, "200 OK", "application/json", "{\"claimed\":\(on),\"taps\":[\(taps)]}"); return
    }
    if method == "POST" && path == "/command" {
        if req.contains("release") { claimLock.lock(); claimExpiry.removeAll(); claimLock.unlock(); scan()
            httpResp(conn, "200 OK", "application/json", "{\"ok\":true,\"claimed\":false}"); return }
        if req.contains("claim") { claimLock.lock(); claimExpiry["Hermes"] = Date().addingTimeInterval(30); claimLock.unlock(); scan()
            httpResp(conn, "200 OK", "application/json", "{\"ok\":true,\"claimed\":true}"); return }
        if req.contains("unduck") { unduckOrResume() } else if req.contains("duck") { duckOrPause() }
        httpResp(conn, "200 OK", "application/json", "{\"ok\":true,\"ducked\":\(ducked)}"); return
    }
    if method == "POST" && path == "/hello" {
        // Control-plane presence + heartbeat: {"boot":"<id>","version":"..."}.
        // Re-POST refreshes lastSeen (heartbeat). main==true iff this boot is the
        // current elected main (most recent hello WITH a live proto SSE conn).
        guard let sep = req.range(of: "\r\n\r\n"),
              let j = (try? JSONSerialization.jsonObject(with: Data(req[sep.upperBound...].utf8))) as? [String: Any],
              let boot = j["boot"] as? String, !boot.isEmpty else {
            httpResp(conn, "400 Bad Request", "application/json", "{\"ok\":false,\"err\":\"bad-hello\"}"); return
        }
        cpLock.lock(); let r = roster[boot] ?? HelloRec(); r.lastHello = Date()
        if let v = j["version"] as? String { r.version = v }
        // ⟦EPOCH-TRUTH⟧ claim/refresh with module-load epoch; a heartbeat from a boot that
        // can no longer be main is answered {replaced:true} so new-code clients retire and
        // stop re-arming. Legacy (epoch==0) boots never steal from an epoch>0 claim.
        if let e = (j["epoch"] as? Double) ?? (j["epoch"] as? Int).map(Double.init) { r.epoch = max(r.epoch, e) }
        roster[boot] = r
        var cb: String? = nil; var ce: Double = 0
        for (b2, rr) in roster where rr.epoch > ce { ce = rr.epoch; cb = b2 }
        let replacedHere = ce > 0 && r.epoch < ce && cb != boot
        cpLock.unlock()
        cpElection()
        cpLock.lock(); let isMain = mainBoot == boot; cpLock.unlock()
        httpResp(conn, "200 OK", "application/json", replacedHere ? "{\"ok\":false,\"replaced\":true,\"main\":\"\(cb ?? "")\"}" : "{\"ok\":true,\"main\":\(isMain),\"epoch\":\(EPOCH)}")
        return
    }
    if method == "POST" && path == "/ctl" {
        // One versioned command door: {seq,cmd,args} -> {seq,ok,result|err} (HTTP 200 always).
        var seq = 0; var cmd = ""; var args: [String: Any] = [:]
        if let sep = req.range(of: "\r\n\r\n"), let j = (try? JSONSerialization.jsonObject(with: Data(req[sep.upperBound...].utf8))) as? [String: Any] {
            seq = (j["seq"] as? NSNumber)?.intValue ?? 0
            cmd = (j["cmd"] as? String) ?? ""
            args = (j["args"] as? [String: Any]) ?? [:]
        }
        let r = ctlDispatch(cmd, args)
        if r.0 { httpResp(conn, "200 OK", "application/json", "{\"seq\":\(seq),\"ok\":true,\"result\":\(r.1)}") }
        else { httpResp(conn, "200 OK", "application/json", "{\"seq\":\(seq),\"ok\":false,\"err\":\"\(r.1)\"}") }
        return
    }
    if path == "/mrprobe" {
        // Diagnostic: what the in-session Now Playing bus read returns.
        var out: [String: Any] = ["ok": false, "gui": guiConnTouched]
        if let raw = internal_get(false) {
            let d = raw as NSDictionary
            out = ["ok": true, "keys": d.allKeys.compactMap { $0 as? String }.sorted(),
                "title": (d.object(forKey: "title" as NSString) as? String) ?? "",
                "artist": (d.object(forKey: "artist" as NSString) as? String) ?? "",
                "album": (d.object(forKey: "album" as NSString) as? String) ?? "",
                "playing": (d.object(forKey: "playing" as NSString) as? NSNumber)?.boolValue ?? false,
                "pid": (d.object(forKey: "processIdentifier" as NSString) as? NSNumber)?.intValue ?? 0,
                "appName": appNameForPID((d.object(forKey: "processIdentifier" as NSString) as? NSNumber)?.intValue ?? 0),
                "artBytes": ((d.object(forKey: "artworkData" as NSString) as? Data)?.count) ?? 0]
        }
        // Safe in-context oracles (read status only inside terminationHandler).
        // np_test has the MediaRemote adapter COMPILED IN (no dylib/env deps) —
        // the unconfounded probe. nowplaying-cli is the dylib-based comparison.
        func oracle(_ exe: String, _ args: [String]) -> [String: Any] {
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            let o = Pipe(); p.standardOutput = o; p.standardError = o
            let sem = DispatchSemaphore(value: 0); var txt = ""; var code = -99
            p.terminationHandler = { task in
                txt = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                code = Int(task.terminationStatus); sem.signal()
            }
            do { try p.run() } catch { return ["err": "\(error)"] }
            if sem.wait(timeout: .now() + 5) == .timedOut { if p.isRunning { p.terminate() }; return ["rc": "timeout", "out": txt] }
            return ["rc": code, "out": txt.trimmingCharacters(in: .whitespacesAndNewlines)]
        }
        out["npTest"] = oracle("/Users/minowicz/.hermes/profiles/donna/cache/scratch/mr-test/np_test", [])
        out["npc"] = oracle("/opt/homebrew/bin/nowplaying-cli", ["get"])
        let body = (try? JSONSerialization.data(withJSONObject: out)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        httpResp(conn, "200 OK", "application/json", body); return
    }
    if path == "/nowplaying" { npLock.lock(); let b = npCache; npLock.unlock(); httpResp(conn, "200 OK", "application/json", b); return }
    // ⟦TRANSPORT⟧ APP volume read for the card's speaker icon (the old /volume above
    // is duck-state — different animal, do not merge). Only Music/Spotify expose app
    // volume. 404 = "this source has no app volume" — the card hides the knob.
    if path == "/appvolume" {
        let app = npAppNow()
        let pair: (String, Double)? = app == "Music" ? ("get sound volume", 100) : app == "Spotify" ? ("get player volume", 100) : nil
        guard let (verb, div) = pair else { httpResp(conn, "404 Not Found", "application/json", "{\"err\":\"no-app-volume\"}"); return }
        if let r = runOA("tell application \"\(app)\" to " + verb, 0.8), let v = Double(r.trimmingCharacters(in: .whitespacesAndNewlines)) {
            httpResp(conn, "200 OK", "application/json", "{\"vol\":\(v / div),\"app\":\"\(app)\"}")
        } else { httpResp(conn, "502 Bad Gateway", "application/json", "{\"err\":\"query-failed\"}") }
        return
    }
    // ⟦HONEST-VERBS⟧ shuffle/repeat READ-BACK. The bus never reports these, so
    // until now the card guessed (optimistic memory). Music answers both;
    // Spotify answers both but has no repeat-ONE (bool → off|all, "one" never
    // claimed). 404 = app doesn't expose state ⇒ card stays optimistic.
    if path == "/playerstate" {
        let app = npAppNow()
        func yn(_ s: String?) -> String { (s?.trimmingCharacters(in: .whitespacesAndNewlines) == "true") ? "true" : "false" }
        if app == "Music" {
            let sh = runOA("tell application \"Music\" to get shuffle enabled", 0.8)
            let rp = runOA("tell application \"Music\" to get song repeat", 0.8) ?? "off"
            let rep = ["one": "one", "all": "all"].mapValues { $0 }[rp.trimmingCharacters(in: .whitespacesAndNewlines)] ?? "off"
            httpResp(conn, "200 OK", "application/json", "{\"app\":\"Music\",\"shuffle\":\(yn(sh)),\"repeat\":\"\(rep)\"}")
            return
        }
        if app == "Spotify" {
            let sh = runOA("tell application \"Spotify\" to get shuffling", 0.8)
            let rp = runOA("tell application \"Spotify\" to get repeating", 0.8)
            httpResp(conn, "200 OK", "application/json", "{\"app\":\"Spotify\",\"shuffle\":\(yn(sh)),\"repeat\":\"\(yn(rp) == "true" ? "all" : "off")\"}")
            return
        }
        httpResp(conn, "404 Not Found", "application/json", "{\"err\":\"no-playerstate\"}")
        return
    }
    if path.hasPrefix("/artwork") {
        var k = ""
        if let r = path.range(of: "k=") {
            var s = String(path[r.upperBound...]); if let amp = s.firstIndex(of: "&") { s = String(s[..<amp]) }
            k = s.removingPercentEncoding ?? s
        }
        artLock.lock(); let b = artBytes; let t = artType; let ck = artKey; artLock.unlock()
        if b.isEmpty || (!k.isEmpty && k != ck) { httpRespBin(conn, "404 Not Found", "text/plain", Data()); return }
        httpRespBin(conn, "200 OK", t, b); return
    }
    httpResp(conn, "404 Not Found", "text/plain", "orbit")
}
server.newConnectionHandler = { conn in
    conn.start(queue: .global(qos: .userInteractive))
    conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
        if let d = data, let s = String(data: d, encoding: .utf8) { handle(conn, s) }
    }
}
var booted = false   // one-shot: announce sidecar-boot once the plane is up
server.stateUpdateHandler = { st in
    if case .ready = st {
        log("listening :\(PORT)")
        if !booted { booted = true; DispatchQueue.global().asyncAfter(deadline: .now() + 1) { cpBroadcast("sidecar-boot", "{\"epoch\":\(EPOCH),\"proto\":1}") } }
    } else { log("state \(st)") }
}
server.start(queue: .global(qos: .userInteractive))
DispatchQueue.global(qos: .userInitiated).async { ChannelB.shared.start() }   // channel B: engines (daemon/mic/TTS) come up off the main thread — AVAudioEngine init must never gate the HTTP plane

// ---- central pumps ----------------------------------------------------
func every(_ t: TimeInterval, _ body: @escaping () -> Void) {
    let timer = Timer(timeInterval: t, repeats: true) { _ in body() }
    RunLoop.main.add(timer, forMode: .common)
}
// SSE @ ~20Hz (snapshot+reset => fresh per-window peak/rms)
every(0.05) {
    let frame = frameJSON(reset: true)
    sseLock.lock(); let conns = sseConns; sseConns = []; sseLock.unlock()
    var alive: [NWConnection] = []
    for c in conns { if c.state == .ready { send(c, "event: levels\ndata: " + frame + "\n\n"); alive.append(c) } }
    sseLock.lock(); sseConns = alive; sseLock.unlock()
}
// human reporter @0.5s for our eyes
every(0.5) { print(frameJSON(reset: true)) }
// rescan every 4s — sources appear/vanish live
every(4.0) { scan() }
// channel B pump @0.2s — flush_ms timeouts, heartbeat, queue drain
every(0.2) { ChannelB.shared.pump() }
// now-playing poll @1s on main (NSAppleScript must run on the main thread)
// control plane: publish `nowplaying` ONLY when the cache content actually changed.
DispatchQueue.global(qos: .utility).async {
    while true { let j = readNowPlaying(); npLock.lock(); let chg = (j != npCache); npCache = j; npLock.unlock(); if chg { cpBroadcast("nowplaying", j) }; Thread.sleep(forTimeInterval: 2.0) }
}
// control plane: roster pruning + election sweep @5s (main drop => standby takes
// over within one sweep; hello >30s with no live conn is dropped).
every(5.0) { cpPrune() }
// self-health: stall watchdog @5s — taps claim live but CoreAudio has not rendered
// to us for >15s => rebuild in place. Conservative: only fires once we HAVE
// rendered at least one frame since boot/rebuild (a quiet machine must not storm).
// Second rule (bite 2026-10-26): the OTHER wedge is never rendered AT ALL — the
// initial grab failed (poisoned device UID / coreaudiod busy mid handoff). Zero
// sources + live targets 20s after boot => full rebuild, at most once a minute.
let bootTime = CACurrentMediaTime()
var noTapsRebuildAt: CFTimeInterval = 0
every(5.0) {
    lock.lock(); let active = !byObj.isEmpty; let lr = lastRender; lock.unlock()
    if active, lr > 0, CACurrentMediaTime() - lr > 15 { log("stall: no render for >15s"); rebuildQ.async { rebuildTaps("stall") } }
    if !active, CACurrentMediaTime() - bootTime > 20, CACurrentMediaTime() - noTapsRebuildAt > 60, !enumerateTargets().isEmpty {
        noTapsRebuildAt = CACurrentMediaTime()
        log("self-heal: zero taps 20s after boot — rebuilding"); rebuildQ.async { rebuildTaps("no-taps") }
    }
}

// ---- GUI / WindowServer connection (required for the Now Playing bus) ----
// MediaRemote answers ONLY for processes attached to the Aqua session's
// WindowServer; a bare launchd daemon is not, so the bus reads empty even in
// the gui domain. Creating NSApplication on the MAIN thread and adopting the
// .accessory policy registers this as a background GUI agent — a real
// WindowServer connection with NO Dock icon — which is what unlocks the bus.
// (NSApplication is main-thread-only; touching it off-thread throws.)
NSApplication.shared.setActivationPolicy(.accessory)
guiConnTouched = true

RunLoop.main.run()
