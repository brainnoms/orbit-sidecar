#!/bin/bash
# Orbit sidecar watchdog. launchd KeepAlive covers EXIT; this covers
# "alive-but-tap-dead / wedged" (e.g. output-device change invalidating the
# aggregate tap, or the HTTP/SSE loop stalling). Detected via the live /stream:
#   - no HTTP / no frames at all  -> kick
#   - every frame has empty sources ("s":[]) -> taps never came up -> kick
#   - sources present (even silent, act:0)   -> healthy, do nothing
# Rate-limited so a genuinely-silent system can't trigger a kick loop.
UID_="$(id -u)"
SVC="gui/${UID_}/com.hermes.orbit-sidecar"
STAMP="${HOME}/Projects/orbit/watchdog.log"
RATE="/tmp/orbit_watchdog_lastkick"

kick() {
  local now last
  now="$(date +%s)"
  last="$(cat "$RATE" 2>/dev/null || echo 0)"
  if [ $((now - last)) -lt 30 ]; then exit 0; fi   # no thrash
  echo "$(date '+%Y-%m-%d %H:%M:%S') KICK reason=$1" >> "$STAMP"
  date +%s > "$RATE"
  launchctl kickstart -k "$SVC" 2>/dev/null || true
}

body="$(curl -s --max-time 6 http://127.0.0.1:8107/stream 2>/dev/null)"
if [ -z "$body" ]; then kick "no-stream"; exit 0; fi

frames="$(printf '%s' "$body" | grep -c '"s":')"
empties="$(printf '%s' "$body" | grep -c '"s":\[\]')"
EMPTYMARK="/tmp/orbit_watchdog_emptykicked"
if [ "${frames:-0}" -gt 0 ] && [ "$frames" -eq "$empties" ]; then
  # taps silent. the hardened sidecar self-heals (scan retries on workers) once
  # coreaudiod returns, so kick ONCE per empty-streak, not every 30s — a wedged
  # audio server survives kick storms; the kicks only churn now-playing + TTS.
  if [ ! -f "$EMPTYMARK" ]; then touch "$EMPTYMARK"; kick "tap-dead(s:[] first-strike)"; fi
  exit 0
fi
rm -f "$EMPTYMARK"   # frames flowing again -> streak reset

# rule 3: system reports audio PLAYING but no source is active -> the tap lost
# its output device (aggregate invalidated by a device switch) -> restart, which
# rebuilds the aggregate on the CURRENT default output.
# ⟦TAP-DEAF EXEMPTION (2026-10-30)⟧ the rule may only judge apps the tap can HEAR.
# Podcasts (process "Aperitif") attaches a tap but its playback never meters on it
# (peak/rms stay 0) — and untapped players are worse. "playing + all-sources-silent"
# used to KILL the sidecar mid-podcast-episode, over and over (three graceful
# SIGTERM exits witnessed). Music/Spotify meter honestly; only their silence is
# evidence of a dead aggregate. Everything else: no opinion, no kick.
np="$(curl -s --max-time 3 http://127.0.0.1:8107/nowplaying 2>/dev/null)"
npapp="$(printf '%s' "$np" | sed -n 's/.*"app":"\([^"]*\)".*/\1/p' | head -1)"
# ⟦PAUSE IS NOT DEAFNESS — AND A FROZEN CLOCK IS NOT A CONCERT⟧ (card t_ba7ca933):
# two independent lies made this rule a kick machine (4,750 lifetime kicks, ~every
# 43 s for hours — each one re-muted the ear mid-side and the wake loop died in the
# cradle):  (1) the STATE string lies — MR-STALE keeps reporting "playing" over a
# frozen position, and a paused track still owns now-playing. A paused/frozen world
# is honest silence; only POSITIONS THAT ADVANCE between two reads prove a concert.
# (2) the SILENCE test judged the LAST frame — a quiet intro or an inter-beat gap
# is rms 0 for one frame on a perfectly healthy tap. A dead aggregate is silent
# ACROSS THE WHOLE WINDOW: every source line rms 0, not just the newest.
# Both must hold, or this rule has no opinion and no kick.
npstate="$(printf '%s' "$np" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p' | head -1)"
case "$npapp" in
  Music|Spotify)
    if [ "$npstate" = playing ]; then
      sleep 2
      np2="$(curl -s --max-time 3 http://127.0.0.1:8107/nowplaying 2>/dev/null)"
      pos1="$(printf '%s' "$np"  | sed -n 's/.*"pos":\([0-9.]*\).*/\1/p' | head -1)"
      pos2="$(printf '%s' "$np2" | sed -n 's/.*"pos":\([0-9.]*\).*/\1/p' | head -1)"
      moving="$(awk -v a="${pos1:--1}" -v b="${pos2:--1}" 'BEGIN{print (b>a+0.2) ? 1 : 0}')"
      if [ "$moving" = 1 ]; then
        total="$(printf '%s' "$body" | grep -c "\"name\":\"$npapp:")"
        noisy="$(printf '%s' "$body" | grep "\"name\":\"$npapp:" | grep -vEc '"rms":(0|0\.0+)[,}]')"
        SILENTMARK="/tmp/orbit_watchdog_silentkicked"
        if [ "${total:-0}" -gt 0 ] && [ "${noisy:-0}" -gt 0 ]; then
          rm -f "$SILENTMARK"   # an audible frame in this window: tap alive, streak reset
        fi
        # ⟦A KICK THAT CURES NOTHING SHALL NOT KICK AGAIN⟧: a genuinely quiet track
        # (soft intro, meter floor) reads rms-0 across the WHOLE window forever; the
        # restart cannot cure it, only churn the ear. One kick per silence-streak,
        # exactly like the s:[] rule — the mark dies on the first audible frame.
        if [ "${total:-0}" -gt 0 ] && [ "${noisy:-0}" -eq 0 ] && [ ! -f "$SILENTMARK" ]; then
          touch "$SILENTMARK"
          kick "playing-and-fresh-but-whole-window-silent($npapp tap deaf? first-strike)"
        fi
      fi
    fi
    ;;
esac

exit 0
