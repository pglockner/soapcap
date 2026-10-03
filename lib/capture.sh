# shellcheck shell=bash
# soapcap — live capture wrapper around `yap listen-and-dictate`.
#
# yap streams JSON as it transcribes and, on SIGINT, finalizes that JSON into
# a valid document before exiting (verified on yap 1.2.1 / macOS 26). Its
# output goes to a file in a private temp directory (sc_tmpdir), read into a
# shell variable once yap exits and removed on every exit path.

# sc_capture <mic_label> <system_label> <locale> <max_seconds> [already]
#   max_seconds > 0  -> auto-stop after N seconds (used by `doctor`'s probe;
#                       no keypress handling, no pause)
#   max_seconds == 0 -> run until stopped. If stdin is a real terminal:
#                       q/x or Ctrl-C stops for good, p/space pauses (sets
#                       SC_CAPTURE_ACTION=paused for the caller to act on).
#                       Otherwise (piped/scripted/backgrounded): the older
#                       signal-only behavior, no keypress reading at all.
#   already          -> seconds recorded before this leg (after a pause), so
#                       the on-screen timer carries on rather than restarting
# On success sets SC_JSON to yap's JSON document and returns 0. Either way
# sets SC_CAPTURE_SECONDS to how long yap was recording.
sc_capture() {
  SC_JSON=""
  SC_CAPTURE_ACTION="stopped"
  SC_CAPTURE_SECONDS=0
  local mic="$1" sys="$2" locale="${3:-}" maxs="${4:-0}" already="${5:-0}"

  local wd
  sc_tmpdir wd || return 1
  local jf="$wd/segments.json" ef="$wd/yap.err"

  local yargs
  yargs=( listen-and-dictate --json --mic-label "$mic" --system-label "$sys" )
  [ -n "$locale" ] && yargs=( "${yargs[@]}" --locale "$locale" )

  local t0=$SECONDS
  yap "${yargs[@]}" >"$jf" 2>"$ef" &
  local ypid=$!

  if [ "${maxs:-0}" -gt 0 ] 2>/dev/null; then
    # Fixed-duration probe (doctor). No keypresses, no display.
    ( sleep "$maxs"; kill -INT "$ypid" 2>/dev/null ) &
    local wpid=$!
    trap 'kill -INT "$ypid" 2>/dev/null' INT TERM
    while kill -0 "$ypid" 2>/dev/null; do
      wait "$ypid" 2>/dev/null
    done
    trap - INT TERM
    kill -TERM "$wpid" 2>/dev/null
    wait "$wpid" 2>/dev/null

  elif [ -t 0 ]; then
    # Interactive: poll for a keypress once a second, redrawing the
    # recording timer each time round. Because bash's `read` (like `wait`)
    # is interruptible by a trapped signal, Ctrl-C still reacts immediately
    # rather than waiting out the poll interval (verified). The timer reads
    # the clock rather than counting polls: a stray keypress ends a poll
    # early.
    trap 'kill -INT "$ypid" 2>/dev/null' INT TERM
    local s key
    while kill -0 "$ypid" 2>/dev/null; do
      s=$((already + SECONDS - t0))
      printf '\r  ●  recording  %02d:%02d   (q to stop, p to pause, Ctrl-C also stops)  ' \
        $((s / 60)) $((s % 60)) >&2
      key=""
      IFS= read -r -s -n 1 -t 1 key
      case "$key" in
        q|Q|x|X) kill -INT "$ypid" 2>/dev/null ;;
        p|P|' ')  kill -INT "$ypid" 2>/dev/null; SC_CAPTURE_ACTION="paused" ;;
      esac
    done
    trap - INT TERM
    printf '\r%*s\r' 72 '' >&2

  else
    # Non-interactive (piped/backgrounded/scripted): no stdin to read
    # keypresses from, so just wait for a stop signal — same as before
    # keypress support existed.
    trap 'kill -INT "$ypid" 2>/dev/null' INT TERM
    while kill -0 "$ypid" 2>/dev/null; do
      wait "$ypid" 2>/dev/null
    done
    trap - INT TERM
  fi

  wait "$ypid" 2>/dev/null
  SC_CAPTURE_SECONDS=$((SECONDS - t0))

  [ -s "$ef" ] && sed 's/^/  yap: /' "$ef" >&2
  [ -s "$jf" ] && SC_JSON=$(cat "$jf")

  rm -rf "$wd"

  [ -n "$SC_JSON" ]
}

# sc_capture_session <mic_label> <system_label> <locale>
#
# Wraps sc_capture with pause/resume: each pause ends the current `yap` run
# cleanly (a real gap — nothing is captured while paused, see README
# "Pause/resume") and resume starts a fresh one. All runs are merged into a
# single SC_JSON before returning, so callers see exactly what they did
# before this existed. Falls back to a single plain sc_capture call when
# stdin isn't a terminal (nothing to read a keypress from, and pausing was
# never on offer there anyway). Sets SC_SESSION_SECONDS to the time spent
# recording, summed across legs -- time spent paused doesn't count.
sc_capture_session() {
  SC_JSON=""
  SC_SESSION_SECONDS=0
  local mic="$1" sys="$2" locale="${3:-}"

  if [ ! -t 0 ]; then
    sc_capture "$mic" "$sys" "$locale" 0
    local rc=$?
    SC_SESSION_SECONDS=$SC_CAPTURE_SECONDS
    return "$rc"
  fi

  local wd
  sc_tmpdir wd || return 1

  local runfiles=() n=0 keep_going=1
  while [ "$keep_going" -eq 1 ]; do
    n=$((n + 1))
    # A run producing nothing is only fatal the first time (real capture
    # failure); after a pause it just means an empty leg — the merge
    # below tolerates an empty run's worth of segments.
    if ! sc_capture "$mic" "$sys" "$locale" 0 "$SC_SESSION_SECONDS" && [ "$n" -eq 1 ]; then
      rm -rf "$wd"
      return 1
    fi
    SC_SESSION_SECONDS=$((SC_SESSION_SECONDS + SC_CAPTURE_SECONDS))
    # An empty leg (e.g. paused almost immediately) isn't valid JSON on its
    # own; give sc_merge_runs a well-formed empty document instead.
    if [ -n "$SC_JSON" ]; then
      printf '%s' "$SC_JSON" > "$wd/run$n.json"
    else
      printf '{"segments":[]}' > "$wd/run$n.json"
    fi
    runfiles+=( "$wd/run$n.json" )

    if [ "$SC_CAPTURE_ACTION" = "paused" ]; then
      sc_info ""
      sc_info "$(printf '  ⏸  paused at %02d:%02d — nothing is being captured. p to resume, q to stop for good.' \
        $((SC_SESSION_SECONDS / 60)) $((SC_SESSION_SECONDS % 60)))"
      # Ctrl-C (or a kill) while paused means "stop for good", as it does
      # while recording -- not "throw the session away". The read polls
      # once a second because bash 3.2 (macOS's) doesn't let a trapped
      # signal interrupt a `read` that has no timeout.
      local key resumed=0 stop=0
      trap 'stop=1' INT TERM
      while [ "$resumed" -eq 0 ]; do
        key=""
        IFS= read -r -s -n 1 -t 1 key
        [ "$stop" -eq 1 ] && key="q"
        case "$key" in
          p|P|' ') resumed=1 ;;
          q|Q|x|X) resumed=1; keep_going=0 ;;
        esac
      done
      trap - INT TERM
      [ "$keep_going" -eq 1 ] && sc_info "  ▶  resuming…"
    else
      keep_going=0
    fi
  done

  SC_JSON=$(sc_merge_runs "${runfiles[@]}")
  rm -rf "$wd"
  [ -n "$SC_JSON" ]
}
