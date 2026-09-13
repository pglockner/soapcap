# shellcheck shell=bash
# soapcap — live capture wrapper around `yap listen-and-dictate`.
#
# yap streams JSON as it transcribes and, on SIGINT, finalizes that JSON into
# a valid document before exiting (verified on yap 1.2.1 / macOS 26). We feed
# its stdout through a FIFO so the transcript lives only in the pipe buffer
# and a shell variable — never on disk.

# sc_capture <mic_label> <system_label> <locale> <max_seconds>
#   max_seconds > 0  -> auto-stop after N seconds (used by `doctor`'s probe;
#                       no keypress handling, no pause)
#   max_seconds == 0 -> run until stopped. If stdin is a real terminal:
#                       q/x or Ctrl-C stops for good, p/space pauses (sets
#                       SC_CAPTURE_ACTION=paused for the caller to act on).
#                       Otherwise (piped/scripted/backgrounded): the older
#                       signal-only behavior, no keypress reading at all.
# On success sets SC_JSON to yap's JSON document and returns 0.
sc_capture() {
  SC_JSON=""
  SC_CAPTURE_ACTION="stopped"
  local mic="$1" sys="$2" locale="${3:-}" maxs="${4:-0}"

  local wd
  wd=$(mktemp -d "${TMPDIR:-/tmp}/soapcap.XXXXXX") || return 1
  chmod 700 "$wd" 2>/dev/null
  SC_WORKDIR="$wd"
  local jf="$wd/segments.json" ef="$wd/yap.err"

  local yargs
  yargs=( listen-and-dictate --json --mic-label "$mic" --system-label "$sys" )
  [ -n "$locale" ] && yargs=( "${yargs[@]}" --locale "$locale" )

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
    # Interactive: poll for a keypress once a second. This tick doubles as
    # the recording timer, and — because bash's `read` (like `wait`) is
    # interruptible by a trapped signal — Ctrl-C still reacts immediately
    # rather than waiting out the poll interval (verified).
    trap 'kill -INT "$ypid" 2>/dev/null' INT TERM
    local s=0 key
    while kill -0 "$ypid" 2>/dev/null; do
      printf '\r  ●  recording  %02d:%02d   (q to stop, p to pause, Ctrl-C also stops)  ' \
        $((s / 60)) $((s % 60)) >&2
      key=""
      IFS= read -r -s -n 1 -t 1 key
      case "$key" in
        q|Q|x|X) kill -INT "$ypid" 2>/dev/null ;;
        p|P|' ')  kill -INT "$ypid" 2>/dev/null; SC_CAPTURE_ACTION="paused" ;;
      esac
      s=$((s + 1))
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

  [ -s "$ef" ] && sed 's/^/  yap: /' "$ef" >&2
  [ -s "$jf" ] && SC_JSON=$(cat "$jf")

  rm -rf "$wd"
  SC_WORKDIR=""

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
# never on offer there anyway).
sc_capture_session() {
  SC_JSON=""
  local mic="$1" sys="$2" locale="${3:-}"

  if [ ! -t 0 ]; then
    sc_capture "$mic" "$sys" "$locale" 0
    return
  fi

  local wd
  wd=$(mktemp -d "${TMPDIR:-/tmp}/soapcap-session.XXXXXX") || return 1
  chmod 700 "$wd" 2>/dev/null
  SC_WORKDIR="$wd"

  local runfiles=() n=0 keep_going=1
  while [ "$keep_going" -eq 1 ]; do
    n=$((n + 1))
    # A run producing nothing is only fatal the first time (real capture
    # failure); after a pause it just means an empty leg — the merge
    # below tolerates an empty run's worth of segments.
    if ! sc_capture "$mic" "$sys" "$locale" 0 && [ "$n" -eq 1 ]; then
      rm -rf "$wd"; SC_WORKDIR=""
      return 1
    fi
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
      sc_info "  ⏸  paused — nothing is being captured. p to resume, q to stop for good."
      local key resumed=0
      while [ "$resumed" -eq 0 ]; do
        key=""
        IFS= read -r -s -n 1 key || key="q"
        case "$key" in
          p|P|' ') resumed=1 ;;
          q|Q|x|X) resumed=1; keep_going=0 ;;
        esac
      done
      [ "$keep_going" -eq 1 ] && sc_info "  ▶  resuming…"
    else
      keep_going=0
    fi
  done

  SC_JSON=$(sc_merge_runs "${runfiles[@]}")
  rm -rf "$wd"
  # Read by sc_cleanup's EXIT trap in common.sh, not visible to shellcheck
  # across files.
  # shellcheck disable=SC2034
  SC_WORKDIR=""
  [ -n "$SC_JSON" ]
}
