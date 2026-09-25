# shellcheck shell=bash
# soapcap — subcommand implementations.

# ---------------------------------------------------------------------------
sc_cmd_doctor() {
  local fail=0 v maj
  v=$(sw_vers -productVersion 2>/dev/null); maj=${v%%.*}
  if [ "${maj:-0}" -ge 26 ] 2>/dev/null; then
    sc_info "  ok    macOS $v"
  else
    sc_info "  FAIL  macOS ${v:-unknown} — yap needs macOS 26 (Tahoe) or newer"
    fail=1
  fi

  local chip mem_bytes mem_gb ncpu
  chip=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
  ncpu=$(sysctl -n hw.ncpu 2>/dev/null)
  mem_bytes=$(sysctl -n hw.memsize 2>/dev/null)
  mem_gb=$(( ${mem_bytes:-0} / 1073741824 ))
  if printf '%s' "$chip" | grep -qi apple; then
    sc_info "  ok    $chip, ${mem_gb}GB unified memory, ${ncpu:-?} cores"
  else
    sc_info "  FAIL  $chip — yap's distributed build and SpeechAnalyzer's on-device"
    sc_info "        model both target Apple silicon; an Intel Mac is not expected to work"
    fail=1
  fi
  if [ "$mem_gb" -ge 32 ] 2>/dev/null; then
    sc_info "        ${mem_gb}GB: comfortable for 'note' with either llama3.1:8b or bonsai"
  elif [ "$mem_gb" -ge 16 ] 2>/dev/null; then
    sc_info "        ${mem_gb}GB: llama3.1:8b (default) works; close memory-heavy apps"
    sc_info "        (browsers, other local models) first. bonsai fits too, but uses"
    sc_info "        most of this memory while it drafts"
  elif [ "$mem_gb" -gt 0 ] 2>/dev/null; then
    sc_info "        ${mem_gb}GB: tight for local note drafting — close other apps before"
    sc_info "        'note'; bonsai needs 16GB+"
  fi

  local disk_avail_kb disk_avail_gb
  disk_avail_kb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
  disk_avail_gb=$(( ${disk_avail_kb:-0} / 1048576 ))
  if [ "$disk_avail_gb" -lt 6 ] 2>/dev/null; then
    sc_info "  WARN  only ${disk_avail_gb}GB free on $HOME's volume — Ollama models run"
    sc_info "        several GB each (llama3.1:8b is ~5GB)"
  fi

  if command -v yap >/dev/null 2>&1; then
    local yv
    yv=$(brew list --versions yap 2>/dev/null | awk '{print $2}')
    sc_info "  ok    yap ${yv:-(installed)} ($(command -v yap))"
  else
    sc_info "  FAIL  yap not found — install with: brew install yap"
    fail=1
  fi

  if command -v jq >/dev/null 2>&1; then
    sc_info "  ok    jq $(jq --version 2>/dev/null | sed 's/^jq-//') ($(command -v jq))"
  else
    sc_info "  FAIL  jq not found — install with: brew install jq"
    fail=1
  fi

  if [ "$fail" -eq 0 ]; then
    sc_info "  ..    probing Microphone + Screen Recording permission (3s)…"
    if sc_capture "MicProbe" "SysProbe" "" 3 \
        && printf '%s' "$SC_JSON" | jq -e '.segments' >/dev/null 2>&1; then
      sc_info "  ok    yap ran and returned valid JSON — permissions look granted"
    else
      sc_info "  WARN  yap did not return usable output."
      sc_info "        Grant BOTH Microphone and Screen Recording to your terminal"
      sc_info "        app in System Settings > Privacy & Security, then re-run."
      fail=1
    fi
  fi

  sc_info ""
  # With bonsai as the default, Ollama is optional: its gaps are "--"
  # (informational), not WARN, so removing llama3.1:8b on purpose to free
  # space doesn't read as a problem.
  local omodel="$SOAPCAP_MODEL" olevel="WARN" oneed="needed for 'note'"
  if [ "$omodel" = bonsai ]; then
    omodel="llama3.1:8b"; olevel="--  "; oneed="only needed to switch back to llama3.1:8b"
  fi
  if command -v ollama >/dev/null 2>&1; then
    local tags
    if tags=$(curl -s --max-time 3 "$SOAPCAP_OLLAMA_HOST/api/tags" 2>/dev/null) && [ -n "$tags" ]; then
      if printf '%s' "$tags" | jq -e --arg m "$omodel" \
           '[.models[]?.name] | any(. == $m or startswith($m + ":"))' >/dev/null 2>&1; then
        if [ "$omodel" = "$SOAPCAP_MODEL" ]; then
          sc_info "  ok    ollama running, $omodel pulled — 'note' is ready"
        else
          sc_info "  ok    ollama running, $omodel pulled — 'note --model $omodel' is ready"
        fi
      else
        sc_info "  $olevel  ollama running, but $omodel is not pulled — $oneed"
        sc_info "        run: ollama pull $omodel"
      fi
    else
      sc_info "  $olevel  ollama installed but not running — $oneed"
      sc_info "        run: brew services start ollama   (or: ollama serve)"
    fi
  else
    sc_info "  --    ollama not installed — only needed for llama3.1:8b notes"
    sc_info "        install with: brew install ollama"
  fi

  if sc_bonsai_installed; then
    sc_info "  ok    Bonsai set up — 'note --model bonsai' is ready"
  elif [ "$SOAPCAP_MODEL" = bonsai ]; then
    sc_info "  WARN  your default model is bonsai, but Bonsai isn't set up"
    sc_info "        set up with: $SC_ROOT/tools/bonsai/install.sh"
  else
    sc_info "  --    Bonsai not set up — optional, slower but more careful note model"
    sc_info "        set up with: $SC_ROOT/tools/bonsai/install.sh"
  fi

  if command -v gum >/dev/null 2>&1; then
    sc_info "  ok    gum present — 'session' prompts use it for arrow-key choose/confirm"
  else
    sc_info "  --    gum not installed — 'session' falls back to plain [Y/n] prompts"
    sc_info "        install with: brew install gum"
  fi
  if command -v fzf >/dev/null 2>&1; then
    sc_info "  ok    fzf present — 'note' with no FILE can browse for one"
  else
    sc_info "  --    fzf not installed — 'note' with no FILE needs one piped in instead"
    sc_info "        install with: brew install fzf"
  fi
  if [ -x "$SOAPCAP_DEIDENTIFY_BIN" ] && "$SOAPCAP_DEIDENTIFY_BIN" --version >/dev/null 2>&1; then
    sc_info "  ok    de-identify helper built and runs ($SOAPCAP_DEIDENTIFY_BIN)"
  else
    sc_info "  --    de-identify helper not built — only needed for 'soapcap deidentify'"
    sc_info "        (and the optional note de-identify offer in 'soapcap session')"
    sc_info "        build with: cd tools/deidentify-helper && swift build -c release"
    sc_info "        (or re-run install.sh)"
  fi

  sc_info ""
  if [ "$fail" -eq 0 ]; then
    sc_info "Ready."
  else
    sc_info "One or more checks failed — see above."
  fi
  return "$fail"
}

# ---------------------------------------------------------------------------
# sc_model_catalog — one "tag|size|note" line per model soapcap has been
# tested with (the baselines behind README "Draft a note"). Any other
# Ollama tag still works via --model or SOAPCAP_MODEL, with a warning.
sc_model_catalog() {
  cat <<'EOF'
llama3.1:8b|~5GB|Default. Fast (usually under a minute). Often assumes a client's pronoun from their name; proofread pronouns and the Objective section.
bonsai|~6GB (16GB+ Mac)|More careful: best at pronouns and at not inventing in-session reactions. Slower (a few minutes a note). Set up with tools/bonsai/install.sh.
EOF
}

# sc_bonsai_installed — true when both halves of the Bonsai setup exist.
sc_bonsai_installed() {
  [ -x "$SOAPCAP_BONSAI_SERVER" ] && [ -f "$SOAPCAP_BONSAI_GGUF" ]
}

# sc_model_table HOST — prints sc_model_catalog as an aligned, wrapped
# table (~86 columns) with a live STATUS column, one line at a time to
# stdout for the caller to route through sc_info.
sc_model_table() {
  local host="$1" tag size note status
  local pulled
  pulled=$(curl -s --max-time 3 "$host/api/tags" 2>/dev/null | jq -r '.models[]?.name // empty' 2>/dev/null)
  {
    while IFS='|' read -r tag size note; do
      [ -z "$tag" ] && continue
      if [ "$tag" = bonsai ]; then
        status="not set up"
        sc_bonsai_installed && status="installed"
      else
        status="not pulled"
        printf '%s\n' "$pulled" | grep -qx "$tag" && status="pulled"
      fi
      printf '%s\t%s\t%s\t%s\n' "$tag" "$size" "$status" "$note"
    done <<CATALOG
$(sc_model_catalog)
CATALOG
  } | awk -F'\t' -v tagw=13 -v sizew=17 -v statw=11 -v notew=42 '
    function pad(s, w) { return sprintf("%-" w "s", s) }
    BEGIN {
      printf "%s %s %s %s\n", pad("MODEL",tagw), pad("SIZE",sizew), pad("STATUS",statw), "NOTES"
      printf "%s %s %s %s\n", pad("-----",tagw), pad("----",sizew), pad("------",statw), "-----"
    }
    {
      n = split($4, words, " ")
      line = ""; first = 1
      for (i = 1; i <= n; i++) {
        cand = (line == "") ? words[i] : line " " words[i]
        if (length(cand) > notew && line != "") {
          if (first) { printf "%s %s %s %s\n", pad($1,tagw), pad($2,sizew), pad($3,statw), line; first = 0 }
          else       { printf "%s %s %s %s\n", pad("",tagw), pad("",sizew), pad("",statw), line }
          line = words[i]
        } else line = cand
      }
      if (first) printf "%s %s %s %s\n", pad($1,tagw), pad($2,sizew), pad($3,statw), line
      else       printf "%s %s %s %s\n", pad("",tagw), pad("",sizew), pad("",statw), line
    }
  '
}

# sc_save_model_config TAG — persists TAG as SOAPCAP_MODEL in config.sh
# (creating ~/.config/soapcap/config.sh if it doesn't exist yet), so
# session/note pick it up as the new default without needing --model.
sc_save_model_config() {
  local tag="$1" cfg="${SOAPCAP_CONFIG:-$HOME/.config/soapcap/config.sh}"
  mkdir -p "$(dirname "$cfg")"
  if [ -f "$cfg" ] && grep -q '^SOAPCAP_MODEL=' "$cfg"; then
    sed -i '' "s|^SOAPCAP_MODEL=.*|SOAPCAP_MODEL=\"$tag\"|" "$cfg"
  else
    printf 'SOAPCAP_MODEL="%s"\n' "$tag" >> "$cfg"
  fi
}

# soapcap model [--host URL]
#
# Shows the tested models as a table (with live status) and, with a real
# terminal, offers to pick one — pulling an Ollama model if needed — and
# saves the pick as the new default for session/note (still overridable
# per-run with --model). Read-only when not interactive.
sc_cmd_model() {
  local host="$SOAPCAP_OLLAMA_HOST"
  while [ $# -gt 0 ]; do
    case "$1" in
      --host)    host="${2:?}"; shift 2 ;;
      -h|--help) sc_usage; return 0 ;;
      *) sc_die "model: unknown option: $1" ;;
    esac
  done

  sc_need curl; sc_need jq
  sc_info "Current default: $SOAPCAP_MODEL"
  if ! sc_model_catalog | cut -d'|' -f1 | grep -qx "$SOAPCAP_MODEL"; then
    sc_info "  (a custom model — untested with soapcap's prompts)"
  fi
  sc_info ""
  while IFS= read -r line; do sc_info "$line"; done <<TABLE
$(sc_model_table "$host")
TABLE
  sc_info ""
  sc_info "Other Ollama models work too, untested — see 'soapcap help' (OTHER MODELS)."
  sc_info ""

  [ -t 0 ] || return 0

  # $SOAPCAP_MODEL always leads the choices (and is the bare-Enter
  # default), so hitting Enter here never silently changes anything —
  # including when it's a custom model set in config.sh.
  local tag tags=("$SOAPCAP_MODEL")
  while IFS='|' read -r tag _ _; do
    [ -z "$tag" ] || [ "$tag" = "$SOAPCAP_MODEL" ] && continue
    tags+=("$tag")
  done <<CATALOG
$(sc_model_catalog)
CATALOG

  local chosen
  chosen=$(sc_choose "Pick a model:" "${tags[@]}")

  if [ "$chosen" = bonsai ]; then
    if ! sc_bonsai_installed; then
      sc_err "Bonsai isn't set up yet — run: $SC_ROOT/tools/bonsai/install.sh"
      sc_info "Default unchanged ($SOAPCAP_MODEL)."
      return 1
    fi
  else
    local pulled
    pulled=$(curl -s --max-time 3 "$host/api/tags" 2>/dev/null | jq -r '.models[]?.name // empty' 2>/dev/null)
    if ! printf '%s\n' "$pulled" | grep -qx "$chosen"; then
      sc_confirm "$chosen isn't pulled yet — pull it now?" || { sc_info "Not pulled — default unchanged ($SOAPCAP_MODEL)."; return 1; }
      if ! command -v ollama >/dev/null 2>&1; then
        sc_err "ollama CLI not found on PATH — install with: brew install ollama"
        return 1
      fi
      ollama pull "$chosen" || { sc_err "pull failed — default unchanged ($SOAPCAP_MODEL)"; return 1; }
    fi
  fi

  sc_save_model_config "$chosen"
  sc_info "Saved — session/note will use $chosen by default (override any time with --model)."
}

# ---------------------------------------------------------------------------
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
  sc_info "  • Use headphones so your mic does not pick up the other party."
  sc_info "  • Turn on Do Not Disturb; system audio capture records the whole mix."
  if [ -t 0 ]; then
    sc_info "  • q or Ctrl-C to stop, p to pause (nothing is captured while paused)."
  else
    sc_info "  • Press Ctrl-C when the session ends."
  fi
  sc_info ""

  if ! sc_capture_session "$mic" "$sys" "$locale"; then
    sc_die "no audio captured. Run 'soapcap doctor' to check permissions."
  fi
  if ! printf '%s' "$SC_JSON" | jq -e '(.segments | length) > 0' >/dev/null 2>&1; then
    sc_die "capture produced no speech segments. Check mic/output routing and permissions."
  fi

  if [ -n "$keepjson" ]; then
    mkdir -p "$(dirname "$keepjson")"
    printf '%s\n' "$SC_JSON" > "$keepjson"
    sc_info "raw JSON written to: $keepjson  (contains PHI)"
  fi

  local transcript
  transcript=$(printf '%s' "$SC_JSON" | sc_render_transcript "$mic" "$sys" "$dedupe") \
    || sc_die "failed to render transcript from yap JSON"

  if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$transcript" > "$out"
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
    mkdir -p "$(dirname "$keepjson")"
    printf '%s\n' "$json" > "$keepjson"
  fi

  local transcript
  transcript=$(printf '%s' "$json" | sc_render_transcript "" "" 1) \
    || sc_die "failed to render transcript"

  if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$transcript" > "$out"
    sc_info "transcript written to: $out"
  else
    printf '%s\n' "$transcript"
  fi
}

# sc_strip_transcript_echo — safety net: small models sometimes ignore the
# "don't repeat the transcript" instruction and echo it back after the
# note. Since the prompt always introduces it with a literal "TRANSCRIPT:"
# line, cut there if it reappears rather than duplicate PHI into the
# output. Reads note text on stdin, writes the truncated text on stdout.
sc_strip_transcript_echo() {
  awk '/^TRANSCRIPT:[[:space:]]*$/ { exit } { print }'
}

# sc_strip_contaminated_fallback — safety net: the SOAP prompt's exact
# required Objective fallback sentence ("No observable presentation
# details...") is meant to be used ALONE, only when there's nothing to
# report -- but a model sometimes appends it to the end of a line that
# already has a real observation on it, producing a self-contradicting
# sentence. Every observed instance of this puts the fallback on the same
# line as the real content (never as its own separate paragraph), so
# strip just the fallback text when a line contains it alongside
# something else, leaving the real content and the fallback's own correct
# standalone use untouched.
sc_strip_contaminated_fallback() {
  awk -v fb="No observable presentation details available from a text-only transcript." '
    {
      if ($0 != fb && index($0, fb) > 0) {
        line = substr($0, 1, index($0, fb) - 1)
        sub(/[ \t]+$/, "", line)
        print line
      } else {
        print
      }
    }
  '
}

# sc_strip_trailing_disclaimer — safety net: seen in the wild — a model
# appending a trailing aside after Plan editorializing about the
# transcript itself ("Note: this appears to be a test recording..."),
# despite the prompt explicitly forbidding closing remarks. Strips
# exactly one trailing paragraph if its first line looks like that kind
# of disclaimer. Real Plan content essentially never opens a new
# paragraph this way, so the false-positive risk is low; leaving it in
# would mean shipping commentary that doesn't belong in a clinical note.
sc_strip_trailing_disclaimer() {
  awk '
    { lines[NR] = $0 }
    END {
      n = NR
      i = n
      while (i > 0 && lines[i] == "") i--
      start = i
      while (start > 0 && lines[start] != "") start--
      first = tolower(lines[start + 1])
      is_aside = (first ~ /^(note|disclaimer|caveat|n\.b\.)[ \t]*[:,-]/) \
                 || (first ~ /^please note[ \t]*[:,-]/)
      last_line = (start > 0 && is_aside) ? start : n
      for (j = 1; j <= last_line; j++) print lines[j]
    }
  '
}

# sc_estimate_ctx PROMPT HEADROOM FLOOR — prints a context-window size for
# PROMPT. A context too small for the prompt fails silently: the model
# just loses part of it (often the rules, which come first) and produces
# malformed, repetitive output with invented section headers. ~1.5
# tokens/word is a safety margin over English's real ~0.75 words/token;
# HEADROOM covers the response. At least FLOOR, capped at 32768, rounded
# up to a multiple of 1024.
sc_estimate_ctx() {
  local words ctx
  words=$(printf '%s' "$1" | wc -w | tr -d ' ')
  ctx=$(( words * 3 / 2 + $2 ))
  [ "$ctx" -lt "$3" ] && ctx=$3
  [ "$ctx" -gt 32768 ] && ctx=32768
  printf '%s\n' $(( ( (ctx + 1023) / 1024 ) * 1024 ))
}

# sc_spin_post TITLE URL PAYLOAD OUTFILE MAX_SECONDS — POSTs PAYLOAD as JSON
# to URL, response body to OUTFILE, under `gum spin` when available.
# Returns curl's own exit status. The response goes to a file (-o), never
# through gum's stdout, so the spinner can't corrupt it. PAYLOAD holds the
# transcript, so it goes to curl from a private temp file rather than as
# an argument, where any local process could read it with `ps`.
sc_spin_post() {
  local title="$1" url="$2" payload="$3" out="$4" max="$5" body rc
  sc_tmpfile body || return 1
  printf '%s' "$payload" > "$body"
  if [ -t 2 ] && command -v gum >/dev/null 2>&1; then
    # TERM_PROGRAM=Apple_Terminal for this one call only: bubbletea (gum's
    # TUI library) probes terminal capabilities (modes 2026/2027) on every
    # non-Apple TERM_PROGRAM, and a short-lived spinner can exit before the
    # terminal's reply arrives, leaking raw "^[[?2026;2$y..." bytes onto
    # the next prompt in iTerm2/ghostty/kitty/alacritty/wezterm -- a known,
    # still-open bubbletea bug (github.com/charmbracelet/bubbletea#1590).
    # Confirmed no other output differs (byte-identical spin apart from
    # the query itself) before relying on this.
    TERM_PROGRAM=Apple_Terminal gum spin --title "$title" -- \
      curl -s --max-time "$max" -X POST "$url" \
        -H 'Content-Type: application/json' -d "@$body" -o "$out"
    rc=$?
  else
    sc_info "$title"
    # Backgrounded + `wait` because bash holds a signal until a foreground
    # command finishes — minutes, here — so a SIGTERM (how the window app
    # stops soapcap) would otherwise go unanswered, and a second one kills
    # bash without its EXIT trap, orphaning Bonsai's server.
    curl -s --max-time "$max" -X POST "$url" \
      -H 'Content-Type: application/json' -d "@$body" -o "$out" &
    local cpid=$!
    # shellcheck disable=SC2064  # expand $cpid now, on purpose
    trap "kill $cpid 2>/dev/null; exit 143" TERM
    # shellcheck disable=SC2064
    trap "kill $cpid 2>/dev/null; exit 130" INT
    wait "$cpid"
    rc=$?
    trap - INT TERM
  fi
  rm -f "$body"
  return "$rc"
}

# sc_ollama_generate MODEL HOST PROMPT FORMAT — sets SC_RAW_NOTE. Talks to
# Ollama's HTTP API directly rather than shelling out to `ollama run`: the
# CLI renders a spinner/progress UI even when its stdout isn't a terminal,
# which corrupts captured output.
sc_ollama_generate() {
  SC_RAW_NOTE=""
  local model="$1" host="$2" prompt="$3" format="$4"

  local tags
  if ! tags=$(curl -s --max-time 5 "$host/api/tags"); then
    sc_err "can't reach Ollama at $host — start it with: brew services start ollama (or: ollama serve)"
    return 1
  fi
  if ! printf '%s' "$tags" | jq -e --arg m "$model" \
        '[.models[]?.name] | any(. == $m or startswith($m + ":"))' >/dev/null 2>&1; then
    sc_err "model '$model' is not pulled — run: ollama pull $model"
    return 1
  fi

  # Ollama's own default context (historically 2048) is far too small.
  local ctx payload resp_file rc response
  ctx=$(sc_estimate_ctx "$prompt" 1024 4096)
  payload=$(jq -n --arg model "$model" --arg prompt "$prompt" --argjson num_ctx "$ctx" \
    '{model: $model, prompt: $prompt, stream: false, options: {num_ctx: $num_ctx}}')

  sc_tmpfile resp_file || return 1
  sc_spin_post "Drafting a $format note with ${model}…" "$host/api/generate" \
    "$payload" "$resp_file" 300
  rc=$?
  response=$(cat "$resp_file"); rm -f "$resp_file"
  # A mid-response --max-time timeout (curl exit 28) leaves a non-empty but
  # partial/invalid file -- check curl's own exit status, not just whether
  # anything got written, or a timeout gets misreported as "no content"
  # further down instead of the actionable message here.
  if [ "$rc" -ne 0 ] || [ -z "$response" ]; then
    sc_err "request to Ollama failed"; return 1
  fi
  if printf '%s' "$response" | jq -e '.error' >/dev/null 2>&1; then
    sc_err "Ollama error: $(printf '%s' "$response" | jq -r '.error')"
    return 1
  fi
  SC_RAW_NOTE=$(printf '%s' "$response" | jq -r '.response // empty')
  [ -n "$SC_RAW_NOTE" ] || { sc_err "Ollama returned no content"; return 1; }
}

# sc_bonsai_start CTX — launches llama-server with the Bonsai GGUF on
# 127.0.0.1:$SOAPCAP_BONSAI_PORT and waits until it has loaded. Sets
# SC_BONSAI_PID; sc_bonsai_stop (also run by the EXIT trap) undoes it.
# Server flags match the ones soapcap's prompts were tested with.
sc_bonsai_start() {
  local ctx="$1" url="http://127.0.0.1:$SOAPCAP_BONSAI_PORT"
  if [ ! -x "$SOAPCAP_BONSAI_SERVER" ] || [ ! -f "$SOAPCAP_BONSAI_GGUF" ]; then
    sc_err "Bonsai isn't set up — expected llama-server at $SOAPCAP_BONSAI_SERVER"
    sc_err "  and the model at $SOAPCAP_BONSAI_GGUF. Set it up with: $SC_ROOT/tools/bonsai/install.sh"
    return 1
  fi
  # Anything already answering here would silently draft the note with
  # whatever model it serves.
  if curl -s --max-time 2 "$url/health" >/dev/null 2>&1; then
    sc_err "something is already listening on port $SOAPCAP_BONSAI_PORT — stop it, or set"
    sc_err "  SOAPCAP_BONSAI_PORT to a free port in ~/.config/soapcap/config.sh"
    return 1
  fi

  sc_tmpfile SC_BONSAI_LOG || return 1
  "$SOAPCAP_BONSAI_SERVER" -m "$SOAPCAP_BONSAI_GGUF" --host 127.0.0.1 --port "$SOAPCAP_BONSAI_PORT" \
    -ngl 99 -c "$ctx" --parallel 1 --cache-type-k q8_0 --cache-type-v q8_0 \
    >"$SC_BONSAI_LOG" 2>&1 &
  SC_BONSAI_PID=$!

  sc_info "Loading Bonsai…"
  local i=0
  while [ "$i" -lt 180 ]; do
    if ! kill -0 "$SC_BONSAI_PID" 2>/dev/null; then
      sc_err "llama-server exited while loading Bonsai — last lines of its log:"
      tail -n 5 "$SC_BONSAI_LOG" >&2
      sc_bonsai_stop
      return 1
    fi
    if curl -s --max-time 2 "$url/health" 2>/dev/null | jq -e '.status == "ok"' >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  sc_err "Bonsai didn't finish loading within 180s"
  sc_bonsai_stop
  return 1
}

# sc_bonsai_generate PROMPT FORMAT — sets SC_RAW_NOTE. Starts the server,
# drafts one note, and stops the server straight away, so its ~6GB is free
# again before anything else (e.g. de-identify) runs. Sampling matches the
# settings soapcap's prompts were tested with.
sc_bonsai_generate() {
  SC_RAW_NOTE=""
  local prompt="$1" format="$2" ctx payload resp_file rc response
  # 2048 of headroom: the request allows up to 2000 output tokens.
  ctx=$(sc_estimate_ctx "$prompt" 2048 8192)
  sc_bonsai_start "$ctx" || return 1

  payload=$(jq -n --arg p "$prompt" '{
    messages: [{role: "user", content: $p}],
    temperature: 0.7, top_p: 0.8, top_k: 20, max_tokens: 2000, stream: false,
    chat_template_kwargs: {enable_thinking: false}
  }')
  sc_tmpfile resp_file || { sc_bonsai_stop; return 1; }
  sc_spin_post "Drafting a $format note with Bonsai (this takes a few minutes)…" \
    "http://127.0.0.1:$SOAPCAP_BONSAI_PORT/v1/chat/completions" "$payload" "$resp_file" 900
  rc=$?
  sc_bonsai_stop
  response=$(cat "$resp_file"); rm -f "$resp_file"

  if [ "$rc" -ne 0 ] || [ -z "$response" ]; then
    sc_err "request to Bonsai failed"; return 1
  fi
  if printf '%s' "$response" | jq -e '.error' >/dev/null 2>&1; then
    sc_err "Bonsai error: $(printf '%s' "$response" | jq -r '.error.message // .error')"
    return 1
  fi
  SC_RAW_NOTE=$(printf '%s' "$response" | jq -r '.choices[0].message.content // empty')
  [ -n "$SC_RAW_NOTE" ] || { sc_err "Bonsai returned no content"; return 1; }
  if [ "$(printf '%s' "$response" | jq -r '.choices[0].finish_reason // empty')" = length ]; then
    sc_err "warning: Bonsai hit its output limit — the end of the note may be cut off"
  fi
  return 0
}

# sc_generate_note <format> <model> <host> <transcript>
#
# Drafts a note from a transcript with a local model: `bonsai` via
# llama-server, anything else via Ollama. On success sets SC_NOTE and
# returns 0; on failure prints an actionable error via sc_err and returns
# 1 — it does NOT exit, so a caller holding an already-captured transcript
# (sc_cmd_session) can report the failure without losing it. sc_cmd_note,
# which has nothing else at stake, turns that failure straight into sc_die.
sc_generate_note() {
  SC_NOTE=""
  local format="$1" model="$2" host="$3" transcript="$4"

  local prompt_file="$SC_ROOT/prompts/$format.md"
  if [ ! -f "$prompt_file" ]; then
    sc_err "unknown format '$format' (no $prompt_file)"; return 1
  fi

  local full_prompt note
  full_prompt="$(cat "$prompt_file")

TRANSCRIPT:
$transcript"

  if ! sc_model_catalog | cut -d'|' -f1 | grep -qx "$model"; then
    sc_info "note: $model hasn't been tested with soapcap's prompts — proofread it with extra care."
  fi

  case "$model" in
    bonsai) sc_bonsai_generate "$full_prompt" "$format" || return 1 ;;
    *)      sc_ollama_generate "$model" "$host" "$full_prompt" "$format" || return 1 ;;
  esac
  note="$SC_RAW_NOTE"

  # Three safety nets against known model misbehavior — see each
  # function's own comment for the specific failure it guards against.
  note=$(printf '%s\n' "$note" | sc_strip_transcript_echo)
  note=$(printf '%s\n' "$note" | sc_strip_contaminated_fallback)
  SC_NOTE=$(printf '%s\n' "$note" | sc_strip_trailing_disclaimer)
  [ -n "$SC_NOTE" ]
}

# ---------------------------------------------------------------------------
# soapcap note [FILE] [--model NAME] [--format soap|dap|birp] [--host URL]
#              [--out FILE] [--clipboard]
#
# Reads a transcript (FILE, or stdin so it composes with `live`/`transcribe`)
# and drafts a note via sc_generate_note().
sc_cmd_note() {
  local file="" out="" model="$SOAPCAP_MODEL" format="$SOAPCAP_FORMAT" host="$SOAPCAP_OLLAMA_HOST"
  local clipboard=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --out)       out="${2:?--out needs a path}"; shift 2 ;;
      --model)     model="${2:?}"; shift 2 ;;
      --format)    format="${2:?}"; shift 2 ;;
      --host)      host="${2:?}"; shift 2 ;;
      --clipboard) clipboard=1; shift ;;
      -h|--help)   sc_usage; return 0 ;;
      -*) sc_die "note: unknown option: $1" ;;
      *)  file="$1"; shift ;;
    esac
  done

  sc_need curl; sc_need jq

  local transcript
  if [ -n "$file" ]; then
    [ -f "$file" ] || sc_die "no such file: $file"
    transcript=$(cat "$file")
  elif [ -t 0 ]; then
    # Nothing was piped in and no FILE was given — with a real terminal
    # sitting there, `cat` on stdin would just hang waiting for typed
    # input. Offer to browse for one instead (needs fzf); otherwise say
    # plainly what's expected rather than hang.
    file=$(sc_pick_transcript_file) \
      || sc_die "note: no FILE given and nothing piped in. Pass a file, pipe a transcript in, or install fzf to browse for one (brew install fzf)."
    [ -n "$file" ] || sc_die "note: no file selected"
    [ -f "$file" ] || sc_die "no such file: $file"
    transcript=$(cat "$file")
  else
    transcript=$(cat)
  fi
  [ -n "$transcript" ] || sc_die "note: empty transcript (pass a file, or pipe one in via stdin)"

  sc_generate_note "$format" "$model" "$host" "$transcript" || sc_die "note generation failed"
  local note="$SC_NOTE"

  if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$note" > "$out"
    sc_info "note written to: $out  (contains PHI — delete when done)"
  else
    printf '%s\n' "$note"
  fi
  [ "$clipboard" -eq 1 ] && sc_to_clipboard "$note"
  return 0
}

# ---------------------------------------------------------------------------
# sc_deidentify_transcript TRANSCRIPT
#
# Runs TRANSCRIPT through tools/deidentify-helper (OpenMedKit's on-device
# Privacy Filter model) and replaces detected PII with consistent,
# category-numbered bracket tokens ([FIRST_NAME_1], [PHONE_1], ...) --
# the helper does the actual detection and substitution; this function
# only strips/reattaches speaker labels around it. Deliberately does NOT
# follow this file's other text-transform helpers' "always succeeds, pure
# awk" shape: failing closed is the entire point here. A missing/crashed
# helper must produce NO output, not a pass-through of unredacted PHI --
# a silent no-op would be a worse failure than an error. On success sets
# SC_DEIDENTIFY_TRANSCRIPT and SC_DEIDENTIFY_SUMMARY (a one-line count,
# e.g. "redacted 4 span(s): FIRST_NAME x3, PHONE x1", straight from the
# helper's own stderr) and returns 0. On failure both are cleared, an
# actionable message goes to sc_err, and it returns 1 without exiting --
# same contract as sc_generate_note.
sc_deidentify_transcript() {
  SC_DEIDENTIFY_TRANSCRIPT=""
  SC_DEIDENTIFY_SUMMARY=""
  local transcript="$1" bin="$SOAPCAP_DEIDENTIFY_BIN"

  if [ ! -x "$bin" ]; then
    sc_err "de-identify helper not found or not executable: $bin"
    sc_err "build it with: cd \"${SC_ROOT:-.}/tools/deidentify-helper\" && swift build -c release"
    sc_err "(or re-run install.sh and accept the de-identification helper offer)"
    return 1
  fi

  # Split into (label, body) at the FIRST ": " per line -- the label is
  # NEVER sent to the helper and NEVER substituted, even if a configured
  # label happens to be a real name. A line with no colon is label=""
  # body=<whole line>, still processed. Labels held in a parallel array,
  # bodies concatenated with \n into $body_blob (order preserved).
  local -a labels=()
  local body_blob="" line label body first=1
  while IFS= read -r line; do
    case "$line" in
      *': '*) label="${line%%: *}"; body="${line#*: }" ;;
      *)      label="";             body="$line" ;;
    esac
    labels+=("$label")
    if [ "$first" -eq 1 ]; then body_blob="$body"; first=0
    else body_blob="$body_blob"$'\n'"$body"; fi
  done <<TRANSCRIPT
$transcript
TRANSCRIPT

  local errfile; errfile=$(mktemp) || { sc_err "could not create a temp file"; return 1; }
  local redacted_body rc
  redacted_body=$(printf '%s' "$body_blob" | "$bin" 2>"$errfile")
  rc=$?
  local helper_stderr; helper_stderr=$(cat "$errfile"); rm -f "$errfile"

  if [ "$rc" -eq 2 ]; then
    sc_err "de-identify model weights unavailable: $helper_stderr"
    sc_err "check your network connection and try again (one-time download)"
    return 1
  elif [ "$rc" -ne 0 ]; then
    sc_err "de-identify helper failed: $helper_stderr"
    return 1
  fi
  SC_DEIDENTIFY_SUMMARY="$helper_stderr"

  # Re-zip: redacted_body has exactly as many lines as $labels has
  # entries (the helper never changes line count), so pair them back up
  # in order.
  local i=0 out="" redacted_line
  while IFS= read -r redacted_line; do
    label="${labels[$i]}"
    if [ -n "$label" ]; then redacted_line="$label: $redacted_line"; fi
    if [ "$i" -eq 0 ]; then out="$redacted_line"
    else out="$out"$'\n'"$redacted_line"; fi
    i=$((i + 1))
  done <<REDACTED
$redacted_body
REDACTED

  SC_DEIDENTIFY_TRANSCRIPT="$out"
  return 0
}

# soapcap deidentify [FILE] [--out FILE] [--clipboard]
#
# Reads a transcript (FILE, or stdin so it composes with `live`/`note`,
# e.g. `soapcap live | soapcap deidentify | soapcap note`) and runs it
# through sc_deidentify_transcript(). Mirrors sc_cmd_note's FILE/stdin/
# --out/picker conventions, minus --model/--format/--host -- there's one
# fixed detection model, no catalog to choose from.
sc_cmd_deidentify() {
  local file="" out="" clipboard=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --out)       out="${2:?--out needs a path}"; shift 2 ;;
      --clipboard) clipboard=1; shift ;;
      -h|--help)   sc_usage; return 0 ;;
      -*) sc_die "deidentify: unknown option: $1" ;;
      *)  file="$1"; shift ;;
    esac
  done

  local transcript
  if [ -n "$file" ]; then
    [ -f "$file" ] || sc_die "no such file: $file"
    transcript=$(cat "$file")
  elif [ -t 0 ]; then
    file=$(sc_pick_transcript_file) \
      || sc_die "deidentify: no FILE given and nothing piped in. Pass a file, pipe a transcript in, or install fzf to browse for one (brew install fzf)."
    [ -n "$file" ] || sc_die "deidentify: no file selected"
    [ -f "$file" ] || sc_die "no such file: $file"
    transcript=$(cat "$file")
  else
    transcript=$(cat)
  fi
  [ -n "$transcript" ] || sc_die "deidentify: empty transcript (pass a file, or pipe one in via stdin)"

  # No pipefail is set (bin/soapcap: set -u only), but none is needed:
  # sc_die below exits before anything reaches this command's stdout, so
  # a downstream `| soapcap note` sees zero bytes and hits its own
  # existing "empty transcript" guard rather than a partial/bad note.
  sc_deidentify_transcript "$transcript" \
    || sc_die "de-identification failed — see above. Nothing was printed, to avoid passing unredacted PHI downstream."
  local redacted="$SC_DEIDENTIFY_TRANSCRIPT"
  sc_info "$SC_DEIDENTIFY_SUMMARY"

  if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$redacted" > "$out"
    sc_info "de-identified transcript written to: $out — best-effort only, review before treating as safe to share (see README \"De-identify\")"
  else
    printf '%s\n' "$redacted"
  fi
  [ "$clipboard" -eq 1 ] && sc_to_clipboard "$redacted"
  return 0
}

# ---------------------------------------------------------------------------
# soapcap session [--format soap|dap|birp] [--model NAME] [--no-note]
#                 [--clipboard] [--mic-label ...] [--system-label ...]
#                 [--locale ...] [--no-dedupe]
#
# Guided flow meant for the double-clickable launcher (soapcap.command) and
# for anyone who'd rather answer two prompts than remember `live | note`:
# capture live, print the transcript, then ask whether to draft a note and
# whether to copy the result to the clipboard. --format implies "yes, draft
# one" for non-interactive/scripted use; --no-note skips asking. Prompts are
# skipped (falling back to plain `live` behavior) when stdin isn't a real
# terminal, since there'd be nothing to read an answer from.
sc_cmd_session() {
  local mic="$SOAPCAP_MIC_LABEL" sys="$SOAPCAP_SYSTEM_LABEL" locale="$SOAPCAP_LOCALE"
  local dedupe=1 format="" model="$SOAPCAP_MODEL" host="$SOAPCAP_OLLAMA_HOST"
  local no_note=0 clipboard=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --mic-label)    mic="${2:?}"; shift 2 ;;
      --system-label) sys="${2:?}"; shift 2 ;;
      --locale)       locale="${2:?}"; shift 2 ;;
      --no-dedupe)    dedupe=0; shift ;;
      --format)       format="${2:?}"; shift 2 ;;
      --model)        model="${2:?}"; shift 2 ;;
      --host)         host="${2:?}"; shift 2 ;;
      --no-note)      no_note=1; shift ;;
      --clipboard)    clipboard=1; shift ;;
      -h|--help)      sc_usage; return 0 ;;
      *) sc_die "session: unknown option: $1" ;;
    esac
  done

  sc_need yap; sc_need jq

  # Everything from here on can include PHI (transcript, drafted note) --
  # draw it to the terminal's alternate screen buffer so none of it lands
  # in normal scrollback or a terminal app's session-restore snapshot. See
  # Retention in the README and sc_alt_screen_start's comment.
  sc_alt_screen_start

  sc_info "soapcap session — guided capture"
  sc_info "  • Use headphones so your mic does not pick up the other party."
  sc_info "  • Turn on Do Not Disturb; system audio capture records the whole mix."
  if [ -t 0 ]; then
    sc_info "  • q or Ctrl-C to stop, p to pause (nothing is captured while paused)."
  else
    sc_info "  • Press Ctrl-C when the session ends."
  fi
  sc_info ""

  if ! sc_capture_session "$mic" "$sys" "$locale"; then
    sc_die "no audio captured. Run 'soapcap doctor' to check permissions."
  fi
  if ! printf '%s' "$SC_JSON" | jq -e '(.segments | length) > 0' >/dev/null 2>&1; then
    sc_die "capture produced no speech segments. Check mic/output routing and permissions."
  fi

  local transcript
  transcript=$(printf '%s' "$SC_JSON" | sc_render_transcript "$mic" "$sys" "$dedupe") \
    || sc_die "failed to render transcript from yap JSON"

  local line_count
  line_count=$(printf '%s\n' "$transcript" | wc -l | tr -d ' ')

  sc_info ""
  sc_info "Transcript: $line_count line(s)."

  # One all-or-nothing question, asked once and only when the helper is
  # built. It comes before "Show the transcript?" so that what's printed
  # to the screen is already the redacted text. Yes redacts the transcript
  # here (everything downstream -- display, drafting, clipboard -- then
  # uses the redacted version) and the drafted note again before it's shown.
  local deidentify=0
  if [ -t 0 ] && [ -x "$SOAPCAP_DEIDENTIFY_BIN" ]; then
    sc_confirm "De-identify the transcript now, and the note once it's drafted?" && deidentify=1
  fi
  if [ "$deidentify" -eq 1 ]; then
    if sc_deidentify_transcript "$transcript"; then
      transcript="$SC_DEIDENTIFY_TRANSCRIPT"
      sc_info "transcript: $SC_DEIDENTIFY_SUMMARY"
    else
      sc_err "transcript de-identify failed — continuing with the original transcript (see above)"
    fi
  fi

  local show_transcript=1
  [ -t 0 ] && { sc_confirm "Show the transcript?" || show_transcript=0; }
  if [ "$show_transcript" -eq 1 ]; then
    sc_info ""
    sc_info "----- transcript -----"
    printf '%s\n' "$transcript"
    sc_info "-----------------------"
  fi

  sc_warn_one_sided_capture "$SC_JSON" "$mic" "$sys"

  local want_note=0
  if [ "$no_note" -eq 1 ]; then
    want_note=0
  elif [ -n "$format" ]; then
    want_note=1
  elif [ -t 0 ]; then
    sc_info ""
    if [ "$deidentify" -eq 1 ]; then
      sc_confirm "Draft a de-identified note from this?" && want_note=1
    else
      sc_confirm "Draft a note from this?" && want_note=1
    fi
  fi

  if [ "$want_note" -eq 1 ] && [ -z "$format" ]; then
    if [ -t 0 ]; then
      format=$(sc_choose "Format?" soap dap birp)
    else
      format="$SOAPCAP_FORMAT"
    fi
  fi

  if [ "$want_note" -eq 1 ]; then
    sc_need curl
    local keep_note=0 note_choice
    while [ "$keep_note" -eq 0 ]; do
      sc_info ""
      if sc_generate_note "$format" "$model" "$host" "$transcript"; then
        if [ "$deidentify" -eq 1 ]; then
          if sc_deidentify_transcript "$SC_NOTE"; then
            SC_NOTE="$SC_DEIDENTIFY_TRANSCRIPT"
            sc_info "note: $SC_DEIDENTIFY_SUMMARY"
          else
            sc_err "note de-identify failed — showing the note as drafted instead (see above)"
          fi
        fi
        sc_info ""
        sc_info "----- $format note -----"
        printf '%s\n' "$SC_NOTE"
        sc_info "-------------------------"
        if [ -t 0 ]; then
          # LLM output is stochastic -- a weak draft is often just an
          # unlucky roll, so offer another attempt with the same
          # model/transcript rather than settling for it or re-running the
          # whole command by hand. A plain yes/no doesn't work here: "no"
          # would have to mean both "discard this" AND "try again," with
          # no way to just give up and end the session with no note at
          # all. Three explicit choices instead, "keep" first so bare
          # Enter does the safe thing.
          note_choice=$(sc_choose "This draft:" keep regenerate discard)
          case "$note_choice" in
            keep) keep_note=1 ;;
            discard) SC_NOTE=""; break ;;
            *) : ;; # regenerate -- loop again
          esac
        else
          keep_note=1
        fi
      else
        sc_err "note generation failed — the transcript above is still yours, nothing lost"
        break
      fi
    done
    # "keep" is itself the user's answer to "do you want this" -- a
    # separate clipboard confirm right after was redundant in practice
    # (confirmed by hands-on testing), so keeping now copies directly.
    if [ "$keep_note" -eq 1 ] && [ -n "$SC_NOTE" ] && { [ "$clipboard" -eq 1 ] || [ -t 0 ]; }; then
      sc_to_clipboard "$SC_NOTE"
    fi
  elif [ "$clipboard" -eq 1 ]; then
    sc_to_clipboard "$transcript"
  fi

  sc_info ""
  sc_info "Nothing here was written to disk unless you redirected it yourself."
  if [ "${SC_ALT_SCREEN:-0}" = "1" ]; then
    sc_info "This screen won't appear in your terminal's scrollback."
  fi
}
