# T2 · SSE subscriber-gate — measured receipts (card t_28b3403e, 2026-11-06)

Change: the `/stream` meter pump was `every(0.05)` — 20 RunLoop wakes/s with
zero listeners. Now roster-gated on its own serial queue: first `/stream`
connection promotes to a 13 Hz meter cadence (12–15 Hz band); an empty roster
for 3 s demotes to a 1 Hz idle heartbeat. JSON is not even built while idle.
Promotion is instant (the `/stream` handler hops `ssePromote()` onto the pump
queue); the watchdog's own curl probe IS a subscriber, so "no frames → kick"
stays safe by construction. Demotion self-reports "hot N ticks at X Hz" on
stderr — the pump carries its own proof.

## Wake measurement (no sudo on this host: `proc_pid_rusage` V2
`pkg_idle_wkups + interrupted_wkups` via `probe_wake.py` — rootless, same-user)

Idle A/B/A/B, 45–60 s alternating windows, OLD (20 Hz-everywhere) vs NEW
(subscriber-gated), scratch instances :8199 / :8198, no subscribers:

| # | OLD wakes/s | NEW wakes/s |
|---|-------------|-------------|
| 1 | 20.2 (60 s) | 17.1 (60 s) |
| 2 | 19.9         | 16.5 |
| 3 | 21.0         | 16.3 |

**OLD 20.4 ±0.6 vs NEW 16.6 ±0.4 — idle wake reduction ≈ −19%.**

Floor caveat, honestly: both processes carry a ~16/s `pkg_idle_wkups` floor
that is NOT our timers (WindowServer/mach heartbeats — both are NSApplication
accessory processes for the Now-Playing bus), and the counter only tallies
wakeups that catch the package asleep, so it UNDERSTATES the timer delta. The
counter resolves the idle case (−4/s, consistent across three windows, ±3%);
it cannot resolve 13 vs 20 Hz in the hot case — the pump self-reports that:
demotion logs `hot N ticks at X Hz over Ys` on stderr.

## Wire-cadence caveat (pre-existing, NOT caused by this change)

`t2_cadence.py` timestamps frame boundaries: PROD (old binary, hot) delivers
8.6 Hz median-gap 170 ms; scratch OLD (20 Hz pump, main RunLoop) 8.9 Hz. The
main-loop timer was never a metronome: np/scan work ate ticks (the gate also
moves the pump to its own serial queue, `orbit.sse.pump`).

**The ~13 Hz external pacemaker** (discovered with the pump's tick
self-report): scheduling 26 Hz still measured 12.9 Hz; 13 Hz measures 10.1–
10.3 Hz hot in test. The meter's tick ceiling is the tap-render cadence —
CoreAudio's process-tap callbacks hold the source lock in ~77 ms buffer
arrivals, and `frameJSON` queues behind them. That is WHY the band is 12–15
Hz: the tap's own resolution. 10.1 Hz delivered on a 13 Hz schedule, with
wake bookkeeping clean; the render-loop card owns any deeper surgery.

Rejected mitigations (measured, not guessed): `.latencyCritical` activity
while hot (kept — harmless, guards against App-Nap throttling) and queue QoS
utility→userInitiated (no delta at 10.3 vs 10.3).

## T0 lineage note

T0 (t_f467f292) is still blocked on the Chairman's enable-click; its planned
numbers are the plugin/renderer side. The sidecar-process baselines above were
captured directly (old binary, scratch ports) so T2's proof is self-contained
and re-measurable with the committed probes.
