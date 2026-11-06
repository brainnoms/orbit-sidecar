#!/usr/bin/env python3
# Precise SSE cadence: timestamps of complete `event: levels` boundaries over a window
import subprocess, sys, time
port = sys.argv[1]; secs = float(sys.argv[2]) if len(sys.argv) > 2 else 12
p = subprocess.Popen(["curl", "-sN", "--max-time", str(int(secs)), f"localhost:{port}/stream"],
                     stdout=subprocess.PIPE)
buf = b""; marks = []
t_open = time.time()
while True:
    chunk = p.stdout.read(1)
    if not chunk: break
    buf += chunk
    if buf.endswith(b"\n\n"):
        if b"event: levels" in buf: marks.append(time.time())
        buf = b""
marks = [m for m in marks if m - t_open < secs - 0.2]  # drop boundary partials
span = (marks[-1] - marks[0]) if len(marks) > 1 else 0
hz = (len(marks) - 1) / span if span > 0 else 0
gaps = [round(b - a, 3) for a, b in zip(marks, marks[1:])]
gaps_sorted = sorted(gaps)
med = gaps_sorted[len(gaps)//2] if gaps else 0
print(f":{port} n={len(marks)} over {secs}s -> {hz:.1f} Hz median-gap={med*1000:.0f}ms "
      f"p10={gaps_sorted[max(0,len(gaps)//10)]*1000:.0f}ms p90={gaps_sorted[-max(1,len(gaps)//10)]*1000:.0f}ms")
