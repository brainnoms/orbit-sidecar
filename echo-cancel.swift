// ═══════════════════════════════════════════════════════════════════════════
// ⟦THE MIC SHALL NOT HEAR THE SPEAKER — PERIOD⟧ (Bob, 2026-10-30)
// Duck and pause are politeness; this is physics. The mic hears ONLY the room.
// The whole output is subtracted from the input. Every tapped process's PCM
// already flows through ioProc (the meters always had the samples and threw
// them away) → splice that mixdown into a reference timeline and cancel it
// from the mic with a normalized-LMS adaptive filter, which converges on
// whatever speaker→mic latency and EQ this machine happens to have. The
// agent's own voice rides a SECOND reference at the same clock: we hold its
// exact bytes before the DAC ever sees them, and the sidecar is not a tapped
// process, so the two timelines sum — no writer ever races another's array.
// Untapped sources have no reference: bypass, never hallucinate.
// ═══════════════════════════════════════════════════════════════════════════
import Foundation
import QuartzCore   // CACurrentMediaTime — the same mach clock as the audio timestamps

private let EC_NTAP = 1536        // 96 ms echo tail @16k (built-in ~30ms; BT lives near the edge)
private let EC_RATE = 16000.0     // reference timeline rate = the mic tap's own rate
private let EC_N = Int(EC_RATE * 4)  // 4-second rings

final class EchoCanceller {
    private var w  = [Float](repeating: 0, count: EC_NTAP)
    private var xv = [Float](repeating: 0, count: EC_NTAP)           // reference window, newest at [0]
    private var mix = [Float](repeating: 0, count: EC_N)             // writer 1: ioProc mixdown (all tapped apps)
    private var agt = [Float](repeating: 0, count: EC_N)             // writer 2: the agent's own exact PCM
    private var baseT: Double = 0                                 // wall time of ring sample 0 (shared clock)
    private var mixWrite = 0                                      // monotonic absolute sample index for mix
    private var acc = [Float](repeating: 0, count: 8); var accN = 0
    private var devStep = 3                                       // device-rate → 16k decimation (48k default)
    private let mu: Float = 0.012, leak: Float = 0.9993
    private var preE = 0.0, errE = 0.0, meas = 0
    private var lastMix = 0.0, lastAgt = 0.0                      // liveness of each reference

    var active: Bool { let t = CACurrentMediaTime(); return t - lastMix < 0.5 || t - lastAgt < 0.5 }
    func setDeviceRate(_ r: Double) {
        let s = min(8, max(1, Int((r / EC_RATE).rounded())))
        if s != devStep { devStep = s; w = [Float](repeating: 0, count: EC_NTAP) }
    }

    // ---- writer 1: every render quantum of the whole-output mixdown (ioProc) ----
    func pushMix(_ ch: UnsafePointer<Float>, _ frames: Int, _ chans: Int, at t: Double) {
        if baseT == 0 { baseT = t - Double(mixWrite) / EC_RATE }
        var i = 0
        while i < frames {
            var s = 0.0
            for c in 0..<chans { s += Double(ch[i * chans + c]) }
            acc[accN] = Float(s / Double(max(1, chans))); accN += 1
            if accN == devStep {
                accN = 0
                // place by TIME: gap → silence-fill so phase stays honest (tap churn, sleeps)
                let want = Int((t - baseT) * EC_RATE)
                if want > mixWrite {
                    var g = mixWrite
                    while g < want && g - mixWrite < EC_N { mix[g % EC_N] = 0; g += 1 }
                    mixWrite = min(want, mixWrite + EC_N)
                }
                var m = 0.0; for k in 0..<devStep { m += Double(acc[k]) }
                mix[mixWrite % EC_N] = Float(m / Double(devStep))
                mixWrite += 1
                lastMix = t
            }
            i += 1
        }
    }

    // ---- writer 2: the agent's sentence, exact bytes, anchored to play start ----
    func pushRef(_ pcm: [Int16], fromRate: Double, at t: Double) {
        let ratio = fromRate / EC_RATE
        let n = Swift.min(Int(Double(pcm.count) / ratio), EC_N)
        if baseT == 0 { baseT = t - Double(mixWrite) / EC_RATE }
        let start = Int((t - baseT) * EC_RATE)
        for i in 0..<n {
            let pos = Double(i) * ratio
            let i0 = Swift.min(pcm.count - 1, Int(pos)); let i1 = Swift.min(pcm.count - 1, i0 + 1)
            let frac = Float(pos - Double(i0))
            agt[(start + i) % EC_N] = Float(pcm[i0]) + (Float(pcm[i1]) - Float(pcm[i0])) * frac
        }
        lastAgt = t + Double(n) / EC_RATE
    }

    private func refAt(_ idx: Int) -> Float {
        let v = mix[idx % EC_N] + agt[idx % EC_N]
        return v
    }

    // ---- the mic tap: subtract everything the speaker is generating, in place ----
    func process(_ s: inout [Int16], _ n: Int, at t: Double) {
        guard n > 0, baseT != 0 else { return }
        let base = Int((t - baseT) * EC_RATE) - 2 * Int(EC_RATE / 1000)   // 2ms early; the tail eats true latency
        var norm = 0.0
        for i in 0..<n { let fi = base + i; if fi >= 0 { let v = refAt(fi); norm += Double(v) * Double(v) } }
        norm = norm / Double(max(1, n))
        let adapting = norm > 400            // real far-end energy → adapt + cancel; silence → mic untouched
        var i = 0
        while i < n {
            var j = EC_NTAP - 1
            while j > 0 { xv[j] = xv[j - 1]; j -= 1 }
            let fi = base + i
            xv[0] = fi >= 0 ? refAt(fi) : 0
            let d = Float(s[i])
            preE += Double(d) * Double(d)
            if adapting {
                var y: Float = 0
                var k = 0
                while k < EC_NTAP { if w[k] != 0 { y += w[k] * xv[k] }; k += 1 }
                var e = d - y
                errE += Double(e) * Double(e)
                meas += 1
                let step = mu * Float(Double(e) / (1e6 + norm * Double(EC_NTAP) * 0.001))
                k = 0
                while k < EC_NTAP { w[k] = leak * w[k] + step * xv[k]; k += 1 }
                if e > 32767 { e = 32767 }; if e < -32767 { e = -32767 }
                s[i] = Int16(e)
            } else {
                errE += Double(d) * Double(d)
                meas += 1
            }
            i += 1
        }
    }

    // dB of speaker output actually removed from the mic — observable or it didn't happen
    func reportAndReset() -> String {
        guard meas > 1000, preE > 1e8 else { meas = 0; preE = 0; errE = 0; return "listening" }
        let r = 10.0 * log10(max(1.0, errE) / max(1.0, preE))
        meas = 0; preE = 0; errE = 0
        return r < -1 ? String(format: "%.0f dB removed", r) : String(format: "%.0f dB (not cancelling)", r)
    }
}
