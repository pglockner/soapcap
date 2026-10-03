# shellcheck shell=bash
# soapcap live and soapcap transcribe — capture a transcript.

# sc_capture_tips — the reminders shown before a recording starts.
sc_capture_tips() {
  sc_info "  • Use headphones so your mic does not pick up the other party."
  sc_info "  • Turn on Do Not Disturb; system audio capture records the whole mix."
  if [ -t 0 ]; then
    sc_info "  • q or Ctrl-C to stop, p to pause (nothing is captured while paused)."
  else
    sc_info "  • Press Ctrl-C when the session ends."
  fi
  sc_info ""
}

# sc_capture_checked MIC SYS LOCALE — records until stopped (sc_capture_session)
# and leaves yap's JSON in SC_JSON; exits with an actionable message when
# nothing, or no speech, was captured.
sc_capture_checked() {
  if ! sc_capture_session "$1" "$2" "$3"; then
    sc_die "no audio captured. Run 'soapcap doctor' to check permissions."
  fi
  if ! printf '%s' "$SC_JSON" | jq -e '(.segments | length) > 0' >/dev/null 2>&1; then
    sc_die "capture produced no speech segments. Check mic/output routing and permissions."
  fi
}

sc_cmd_live() {
  local out="" keepjson="" dedupe=1 clipboard=0
  local mic="$SOAPCAP_MIC_LABEL" sys="$SOAPCAP_SYSTEM_LABEL" locale="$SOAPCAP_LOCALE"
  while [ $# -gt 0 ]; do
    case "$1" in
      --out)          out="${2:?--out needs a path}"; shift 2 ;;
      --keep-json)    keepjson="${2:?--keep-json needs a path}"; shift 2 ;;
      --mic-label)    mic="${2:?}"; shift 2 ;;
      --system-label) sys="${2:?}"; shift 2 ;;
      --locale)       locale="${2:?}"; shift 2 ;;
      --no-dedupe)    dedupe=0; shift ;;
      --clipboard)    clipboard=1; shift ;;
      -h|--help)      sc_usage; return 0 ;;
      *) sc_die "live: unknown option: $1" ;;
    esac
  done

  sc_need yap; sc_need jq

  sc_info "soapcap live — on-device capture"
  sc_capture_tips
  sc_capture_checked "$mic" "$sys" "$locale"

  if [ -n "$keepjson" ]; then
    sc_write_file "$keepjson" "$SC_JSON" || sc_die "couldn't write $keepjson"
    sc_info "raw JSON written to: $keepjson  (contains PHI)"
  fi

  local transcript
  transcript=$(printf '%s' "$SC_JSON" | sc_render_transcript "$mic" "$sys" "$dedupe") \
    || sc_die "failed to render transcript from yap JSON"

  if [ -n "$out" ]; then
    sc_write_file "$out" "$transcript" || sc_die "couldn't write $out"
    sc_info "transcript written to: $out  (contains PHI — delete when done)"
  else
    printf '%s\n' "$transcript"
  fi
  [ "$clipboard" -eq 1 ] && sc_to_clipboard "$transcript"

  sc_warn_one_sided_capture "$SC_JSON" "$mic" "$sys"

  sc_info ""
  if [ -n "$out" ]; then
    sc_info "Draft a note from this: soapcap note $out"
  else
    sc_info "Draft a note from this: soapcap live | soapcap note"
  fi
}

# One side of the call captured nothing at all is a specific, recognizable
# failure mode (FaceTime's remote audio is rendered by a windowless daemon,
# `avconferenced`, invisible to ScreenCaptureKit's per-application audio
# model — no permission fixes it) — worth naming instead of leaving someone
# to conclude soapcap is just broken. See README "Known limitations".
sc_warn_one_sided_capture() {
  local json="$1" mic="$2" sys="$3"
  local mic_n sys_n
  mic_n=$(printf '%s' "$json" | jq --arg s "$mic" '[.segments[] | select(.speaker == $s)] | length' 2>/dev/null)
  sys_n=$(printf '%s' "$json" | jq --arg s "$sys" '[.segments[] | select(.speaker == $s)] | length' 2>/dev/null)
  if [ "${mic_n:-0}" -gt 0 ] 2>/dev/null && [ "${sys_n:-0}" -eq 0 ] 2>/dev/null; then
    sc_info ""
    sc_info "NOTE: captured your side ($mic) but nothing from the other party ($sys)."
    sc_info "      If this call was on FaceTime, that's expected, not a bug: FaceTime's"
    sc_info "      remote audio is rendered by a windowless background daemon that"
    sc_info "      ScreenCaptureKit can't see, no matter what permissions are granted."
    sc_info "      Zoom/Meet/Teams/Doxy.me are unaffected. See README 'Known limitations'."
  fi
}

# ---------------------------------------------------------------------------
sc_cmd_transcribe() {
  local file="" out="" keepjson="" locale="$SOAPCAP_LOCALE"
  while [ $# -gt 0 ]; do
    case "$1" in
      --out)       out="${2:?--out needs a path}"; shift 2 ;;
      --keep-json) keepjson="${2:?--keep-json needs a path}"; shift 2 ;;
      --locale)    locale="${2:?}"; shift 2 ;;
      -h|--help)   sc_usage; return 0 ;;
      -*) sc_die "transcribe: unknown option: $1" ;;
      *)  file="$1"; shift ;;
    esac
  done
  [ -n "$file" ] || sc_die "usage: soapcap transcribe FILE [--out ...] [--keep-json ...]"
  [ -f "$file" ] || sc_die "no such file: $file"

  sc_need yap; sc_need jq

  local yargs
  yargs=( transcribe "$file" --json )
  [ -n "$locale" ] && yargs=( "${yargs[@]}" --locale "$locale" )

  local json
  json=$(yap "${yargs[@]}") || sc_die "yap transcribe failed"

  if [ -n "$keepjson" ]; then
    sc_write_file "$keepjson" "$json" || sc_die "couldn't write $keepjson"
  fi

  local transcript
  transcript=$(printf '%s' "$json" | sc_render_transcript "" "" 1) \
    || sc_die "failed to render transcript"

  if [ -n "$out" ]; then
    sc_write_file "$out" "$transcript" || sc_die "couldn't write $out"
    sc_info "transcript written to: $out"
  else
    printf '%s\n' "$transcript"
  fi
}
