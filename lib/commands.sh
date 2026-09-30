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

  case "$SOAPCAP_STYLE" in
    narrative) sc_info "  ok    note style: narrative (the default)" ;;
    structured|combined)
      sc_info "  ok    note style: $SOAPCAP_STYLE (experimental — see README \"Note style\")" ;;
    *) sc_info "  WARN  SOAPCAP_STYLE='$SOAPCAP_STYLE' isn't a style — use narrative, structured, or combined" ;;
  esac

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

# sc_mem_pct — prints memory in use as a whole percentage of RAM, the same
# measure Activity Monitor's memory pressure uses (kern.memorystatus_level
# is the percentage free), plus swap in use -- so it passes 100 once the
# Mac is swapping to make room. Empty if it can't be read.
sc_mem_pct() {
  local free total swap
  free=$(sysctl -n kern.memorystatus_level 2>/dev/null) || return 0
  total=$(sysctl -n hw.memsize 2>/dev/null) || return 0
  # "total = 2048.00M  used = 551.25M ..." -> used, in MB
  swap=$(sysctl -n vm.swapusage 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "used") { sub(/M$/, "", $(i+2)); print int($(i+2)); exit }}')
  [ -n "$free" ] && [ -n "$total" ] || return 0
  echo $(( 100 - free + ${swap:-0} * 1048576 * 100 / total ))
}

# sc_status_line TITLE SECONDS SPINNER — prints one redraw of the drafting
# status line to stderr: spinner, title, elapsed time, and memory in use,
# green below 75%, yellow to 90%, red above.
sc_status_line() {
  local mem color="" reset=$'\033[0m'
  mem=$(sc_mem_pct)
  if [ -n "$mem" ]; then
    if [ "$mem" -ge 90 ]; then color=$'\033[31m'
    elif [ "$mem" -ge 75 ]; then color=$'\033[33m'
    else color=$'\033[32m'; fi
    mem="   ${color}memory ${mem}%${reset}"
  fi
  printf '\r\033[K%s %s  %d:%02d%s' "$3" "$1" $(($2 / 60)) $(($2 % 60)) "$mem" >&2
}

# sc_spin_post TITLE URL PAYLOAD OUTFILE MAX_SECONDS — POSTs PAYLOAD as JSON
# to URL, response body to OUTFILE. Returns curl's own exit status. On a
# terminal it shows a status line, redrawn every second, with elapsed time
# and memory in use (a large model can push a 16GB Mac into swap);
# otherwise, e.g. under the window app, just the title. PAYLOAD holds the
# transcript, so it goes to curl from a private temp file rather than as
# an argument, where any local process could read it with `ps`.
sc_spin_post() {
  local title="$1" url="$2" payload="$3" out="$4" max="$5" body rc
  sc_tmpfile body || return 1
  printf '%s' "$payload" > "$body"
  [ -t 2 ] || sc_info "$title"
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
  if [ -t 2 ]; then
    # An array, not a string sliced per character: slicing counts bytes
    # outside a UTF-8 locale and would split these.
    local t0=$SECONDS i=0 frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    while kill -0 "$cpid" 2>/dev/null; do
      sc_status_line "$title" $((SECONDS - t0)) "${frames[$((i % 10))]}"
      i=$((i + 1))
      # `wait` on a background sleep, not a foreground one, so a signal is
      # still acted on at once.
      sleep 1 & wait $! 2>/dev/null
    done
    printf '\r\033[K' >&2
  fi
  wait "$cpid"
  rc=$?
  trap - INT TERM
  rm -f "$body"
  return "$rc"
}

# sc_ollama_generate MODEL HOST PROMPT TITLE [HEADROOM] [EXTRA] — sets
# SC_RAW_NOTE and SC_RAW_DONE (Ollama's done_reason). Talks to Ollama's
# HTTP API directly rather than shelling out to `ollama run`: the CLI
# renders a spinner/progress UI even when its stdout isn't a terminal,
# which corrupts captured output. EXTRA is a JSON object deep-merged into
# the request (the structured style's schema and sampling settings);
# without it the request is exactly what the narrative style always sent.
sc_ollama_generate() {
  SC_RAW_NOTE=""; SC_RAW_DONE=""
  local model="$1" host="$2" prompt="$3" title="$4" headroom="${5:-1024}" extra="${6:-}"

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
  ctx=$(sc_estimate_ctx "$prompt" "$headroom" 4096)
  payload=$(jq -n --arg model "$model" --arg prompt "$prompt" --argjson num_ctx "$ctx" \
    '{model: $model, prompt: $prompt, stream: false, options: {num_ctx: $num_ctx}}')
  if [ -n "$extra" ]; then
    payload=$(printf '%s' "$payload" | jq --argjson x "$extra" '. * $x')
  fi

  sc_tmpfile resp_file || return 1
  sc_spin_post "$title" "$host/api/generate" "$payload" "$resp_file" 300
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
  SC_RAW_DONE=$(printf '%s' "$response" | jq -r '.done_reason // empty')
  [ -n "$SC_RAW_NOTE" ] || { sc_err "Ollama returned no content"; return 1; }
}

# sc_model_stop MODEL HOST — frees the model's memory once a note is done:
# stops Bonsai's server, or asks Ollama to unload the model now rather than
# keep it loaded for its default five minutes. Best effort -- a failed
# unload only means Ollama drops it later on its own.
sc_model_stop() {
  if [ "$1" = bonsai ]; then
    sc_bonsai_stop
  else
    curl -s --max-time 5 -X POST "$2/api/generate" -H 'Content-Type: application/json' \
      -d "$(jq -nc --arg m "$1" '{model: $m, keep_alive: 0}')" >/dev/null 2>&1
  fi
  return 0
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
    # Not `jq -e`: jq 1.6 exits 0 on empty input, i.e. when nothing answers.
    if [ "$(curl -s --max-time 2 "$url/health" 2>/dev/null | jq -r '.status // empty' 2>/dev/null)" = ok ]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  sc_err "Bonsai didn't finish loading within 180s"
  sc_bonsai_stop
  return 1
}

# sc_bonsai_request PROMPT TITLE SETTINGS — sets SC_RAW_NOTE and SC_RAW_DONE
# (the finish_reason). Sends one chat request to the already-running server
# (sc_bonsai_start); SETTINGS is a JSON object of sampling/output settings
# merged into it. Thinking is always off: with it on, a note takes many
# minutes longer and the prompts were tested without it.
sc_bonsai_request() {
  SC_RAW_NOTE=""; SC_RAW_DONE=""
  local prompt="$1" title="$2" settings="$3" payload resp_file rc response
  payload=$(jq -n --arg p "$prompt" --argjson s "$settings" '{
    messages: [{role: "user", content: $p}], stream: false,
    chat_template_kwargs: {enable_thinking: false}
  } + $s')
  sc_tmpfile resp_file || return 1
  sc_spin_post "$title" "http://127.0.0.1:$SOAPCAP_BONSAI_PORT/v1/chat/completions" \
    "$payload" "$resp_file" 900
  rc=$?
  response=$(cat "$resp_file"); rm -f "$resp_file"

  if [ "$rc" -ne 0 ] || [ -z "$response" ]; then
    sc_err "request to Bonsai failed"; return 1
  fi
  if printf '%s' "$response" | jq -e '.error' >/dev/null 2>&1; then
    sc_err "Bonsai error: $(printf '%s' "$response" | jq -r '.error.message // .error')"
    return 1
  fi
  SC_RAW_NOTE=$(printf '%s' "$response" | jq -r '.choices[0].message.content // empty')
  SC_RAW_DONE=$(printf '%s' "$response" | jq -r '.choices[0].finish_reason // empty')
  [ -n "$SC_RAW_NOTE" ] || { sc_err "Bonsai returned no content"; return 1; }
}

# The narrative style's Bonsai settings -- the ones soapcap's prompts were
# tested with. 2048 of context headroom covers the 2000-token output cap.
SC_BONSAI_NARRATIVE='{"temperature": 0.7, "top_p": 0.8, "top_k": 20, "max_tokens": 2000}'

# sc_bonsai_narrative PROMPT FORMAT — drafts a narrative note on the
# already-running server; sets SC_RAW_NOTE.
sc_bonsai_narrative() {
  sc_bonsai_request "$1" "Drafting a $2 note with Bonsai (this takes a few minutes)…" \
    "$SC_BONSAI_NARRATIVE" || return 1
  if [ "$SC_RAW_DONE" = length ]; then
    sc_err "warning: Bonsai hit its output limit — the end of the note may be cut off"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Note styles (SOAPCAP_STYLE / --style):
#   narrative   the model writes the note as prose (prompts/<format>.md)
#   structured  the model returns JSON matching a schema; code checks it
#               against the transcript and writes the note
#               (prompts/structured/, lib/structured/)
#   combined    a narrative note, plus a structured pass used only to
#               review it -- roughly twice the drafting time

# sc_check_style STYLE — returns 1, with an error, unless STYLE is valid.
sc_check_style() {
  case "$1" in
    narrative|structured|combined) return 0 ;;
    *) sc_err "unknown style '$1' — use narrative, structured, or combined"; return 1 ;;
  esac
}

# sc_structured_fields FORMAT — the schema fields for FORMAT, in the order
# the model writes them (which is also note order).
sc_structured_fields() {
  case "$1" in
    # SOAP's Objective comes from its own pass (the "objective" fields),
    # not from observations -- see sc_objective_prompt.
    soap)      echo "subjective assessment risk safety_plan interventions_used plan_items" ;;
    dap)       echo "subjective objective_observations assessment risk safety_plan interventions_used plan_items" ;;
    objective) echo "mental_status risk risk_kind" ;;
    birp)     echo "subjective objective_observations interventions_used response risk safety_plan plan_items" ;;
    *) return 1 ;;
  esac
}

# sc_structured_prompt FORMAT TRANSCRIPT — prints the structured prompt: the
# shared content rules, the field guide for FORMAT's fields, and the
# transcript with numbered lines (the model cites them; validation checks
# them against this same transcript).
sc_structured_prompt() {
  local format="$1" transcript="$2" dir="$SC_ROOT/prompts/structured" f
  local upper; upper=$(printf '%s' "$format" | tr '[:lower:]' '[:upper:]')
  sed "1s/clinical SOAP\$/clinical $upper/" "$dir/rules.md"
  echo
  for f in _intro $(sc_structured_fields "$format") _phrases _closing; do
    awk -v s="$f" '/^## /{p=($2 == s); next} p' "$dir/fields.md"
  done
  printf '\nTRANSCRIPT:\n'
  printf '%s\n' "$transcript" | awk '{printf "%d | %s\n", NR, $0}'
}

# sc_objective_prompt TRANSCRIPT — prints the SOAP Objective pass's prompt.
# Its own prompt rather than the shared rules: those forbid judging affect,
# mood or speech from a transcript, which is exactly what this pass does,
# for the therapist's mental-status Objective.
sc_objective_prompt() {
  cat "$SC_ROOT/prompts/objective.md"
  printf '\nTRANSCRIPT:\n%s\n' "$1"
}

# sc_render_objective JSON NOTE — prints the SOAP Objective body: the fixed
# frame from lib/structured/objective.jq, filled in from the Objective
# pass's JSON ("null" if that pass failed). NOTE is the rest of the note,
# checked for risk language before "No SI/HI reported." goes in.
sc_render_objective() {
  local nfile out
  sc_tmpfile nfile || return 1
  printf '%s\n' "$2" > "$nfile"
  out=$(printf '%s' "$1" | jq -r -L "$SC_ROOT/lib/structured" --rawfile note "$nfile" \
    -f "$SC_ROOT/lib/structured/objective.jq")
  rm -f "$nfile"
  [ -n "$out" ] && printf '%s\n' "$out"
}

# sc_splice_objective BODY — reads a SOAP note on stdin and prints it with
# its OBJECTIVE section's body replaced by BODY. Copes with what a model
# may have done to that section: extra header markup ("**OBJECTIVE:**"),
# text on the header line, a second OBJECTIVE, or none at all (inserted
# before ASSESSMENT, else PLAN, else at the end).
sc_splice_objective() {
  awk -v body="$1" '
    function hdr(name) { return $0 ~ ("^[#* \t]*" name "[* \t]*:") }
    function put() { if (!done) { print "OBJECTIVE:"; print body; print ""; done = 1 } }
    hdr("OBJECTIVE") { skip = 1; put(); next }
    hdr("SUBJECTIVE") || hdr("ASSESSMENT") || hdr("PLAN") {
      if (skip) skip = 0
      if (!hdr("SUBJECTIVE")) put()
    }
    !skip { print }
    END { if (!done) { print ""; print "OBJECTIVE:"; print body } }
  '
}

# sc_add_objective JSON — replaces SC_NOTE's Objective with the one
# rendered from the Objective pass's JSON.
sc_add_objective() {
  local body
  body=$(sc_render_objective "$1" "$SC_NOTE") && [ -n "$body" ] || {
    sc_err "couldn't compose the Objective"; return 1; }
  SC_NOTE=$(printf '%s\n' "$SC_NOTE" | sc_splice_objective "$body")
}

# sc_default_plan — safety net: the SOAP prompt says Plan always states
# the plan of care, but a model can still fall back on the other sections'
# "Not addressed in this session" (seen with llama3.1:8b) or leave Plan
# empty. Reads a note on stdin; either case becomes the plan-of-care
# sentence. Plan is the last section, so its body runs to the end.
sc_default_plan() {
  awk '
    { lines[NR] = $0 }
    /^[#* \t]*PLAN[* \t]*:/ { p = NR }
    END {
      body = ""
      for (i = p + 1; p && i <= NR; i++) body = body lines[i]
      gsub(/[ \t*.]/, "", body)
      empty = p && (body == "" || tolower(body) == "notaddressedinthissession")
      for (i = 1; i <= (empty ? p : NR); i++) print lines[i]
      if (empty) print "The current plan of care will continue."
    }
  '
}

# sc_structured_schema FORMAT — prints the JSON schema for FORMAT.
sc_structured_schema() {
  local fields
  fields=$(sc_structured_fields "$1" | jq -Rc 'split(" ")')
  jq -c --argjson fields "$fields" \
    '. as $all | {type: "object",
       properties: (reduce $fields[] as $f ({}; .[$f] = $all[$f])),
       required: $fields}' "$SC_ROOT/prompts/structured/schema.json"
}

# sc_structured_request MODEL HOST FORMAT PROMPT TITLE [CAP] — sets
# SC_STRUCT_JSON. CAP is the output cap in tokens (default 3000).
# Bonsai's server must already be running. The schema is enforced by the
# server, but a response can still be cut off (output cap) or come back
# malformed, so one invalid response is retried once before giving up. The
# output cap matters: without one, a model can loop inside the JSON until
# the request times out.
sc_structured_request() {
  SC_STRUCT_JSON=""
  local model="$1" host="$2" format="$3" prompt="$4" title="$5" cap="${6:-3000}" schema attempt
  schema=$(sc_structured_schema "$format") || { sc_err "no structured schema for '$format'"; return 1; }
  for attempt in 1 2; do
    if [ "$model" = bonsai ]; then
      sc_bonsai_request "$prompt" "$title" "$(jq -nc --argjson s "$schema" --argjson cap "$cap" '{
        temperature: 0.3, top_p: 0.8, top_k: 20, max_tokens: $cap,
        response_format: {type: "json_schema", json_schema: {schema: $s}}}')" || return 1
    else
      sc_ollama_generate "$model" "$host" "$prompt" "$title" 3072 "$(jq -nc --argjson s "$schema" --argjson cap "$cap" '{
        format: $s, options: {temperature: 0.3, top_p: 0.8, top_k: 20, num_predict: $cap}}')" || return 1
    fi
    if [ "$SC_RAW_DONE" = stop ] && printf '%s' "$SC_RAW_NOTE" \
         | jq -e --argjson s "$schema" '. as $o | type == "object" and ($s.required | all(. as $k | $o | has($k)))' >/dev/null 2>&1; then
      SC_STRUCT_JSON="$SC_RAW_NOTE"
      return 0
    fi
    [ "$attempt" = 1 ] && sc_info "The structured draft came back incomplete — retrying once…"
  done
  sc_err "the structured draft came back incomplete twice (cut off or malformed)"
  return 1
}

# sc_review_block TITLE LINES — frames review lines for display on stderr.
sc_review_block() {
  printf '%s\n' "----- $1 -----" "$2" "-----------------------------"
}

# sc_generate_note <format> <model> <host> <transcript> [style]
#
# Drafts a note from a transcript with a local model: `bonsai` via
# llama-server, anything else via Ollama. On success sets SC_NOTE (the note)
# and SC_REVIEW (review text for the clinician, possibly empty -- shown on
# stderr, never part of the note) and returns 0; on failure prints an
# actionable error via sc_err and returns 1 — it does NOT exit, so a caller
# holding an already-captured transcript (sc_cmd_session) can report the
# failure without losing it. sc_cmd_note, which has nothing else at stake,
# turns that failure straight into sc_die.
sc_generate_note() {
  SC_NOTE=""; SC_REVIEW=""
  local format="$1" model="$2" host="$3" transcript="$4" style="${5:-narrative}"
  sc_check_style "$style" || return 1

  local prompt_file="$SC_ROOT/prompts/$format.md"
  if [ ! -f "$prompt_file" ]; then
    sc_err "unknown format '$format' (no $prompt_file)"; return 1
  fi

  if ! sc_model_catalog | cut -d'|' -f1 | grep -qx "$model"; then
    sc_info "note: $model hasn't been tested with soapcap's prompts — proofread it with extra care."
  fi

  local full_prompt="" sprompt="" rc=0 note
  if [ "$style" != structured ]; then
    full_prompt="$(cat "$prompt_file")

TRANSCRIPT:
$transcript"
  fi
  if [ "$style" != narrative ]; then
    sprompt=$(sc_structured_prompt "$format" "$transcript")
  fi

  # SOAP's Objective always comes from a pass of its own (see
  # sc_objective_prompt), whatever the style.
  # With no client speech at all (the other side of the call wasn't
  # captured), there's nobody to assess: the model would rate the
  # therapist instead. Skip the pass and leave Objective to the clinician.
  local oprompt="" ojson="null" sjson=""
  if [ "$format" = soap ]; then
    if printf '%s\n' "$transcript" | awk -v l="$SOAPCAP_SYSTEM_LABEL: " 'index($0, l) == 1 { f = 1 } END { exit !f }'; then
      oprompt=$(sc_objective_prompt "$transcript")
    else
      ojson='{"no_client": true}'
      sc_info "note: no $SOAPCAP_SYSTEM_LABEL lines in the transcript — the Objective is left for you to complete."
    fi
  fi

  # Bonsai: one server start for every pass, sized for the largest request.
  # 2048 of headroom covers the narrative output cap, 3072 the structured one.
  local who="$model" slow=""
  if [ "$model" = bonsai ]; then
    who="Bonsai"; slow=" (this takes a few minutes)"
    local c ctx=0
    if [ -n "$full_prompt" ]; then c=$(sc_estimate_ctx "$full_prompt" 2048 8192); [ "$c" -gt "$ctx" ] && ctx=$c; fi
    if [ -n "$sprompt" ]; then c=$(sc_estimate_ctx "$sprompt" 3072 8192); [ "$c" -gt "$ctx" ] && ctx=$c; fi
    if [ -n "$oprompt" ]; then c=$(sc_estimate_ctx "$oprompt" 3072 8192); [ "$c" -gt "$ctx" ] && ctx=$c; fi
    sc_bonsai_start "$ctx" || return 1
  fi

  if [ -n "$full_prompt" ]; then
    if [ "$model" = bonsai ]; then
      sc_bonsai_narrative "$full_prompt" "$format"
    else
      sc_ollama_generate "$model" "$host" "$full_prompt" "Drafting a $format note with ${model}…"
    fi || { sc_model_stop "$model" "$host"; return 1; }
    note="$SC_RAW_NOTE"
  fi
  if [ -n "$sprompt" ]; then
    if [ "$style" = structured ]; then
      sc_structured_request "$model" "$host" "$format" "$sprompt" \
        "Drafting a structured $format note with ${who}${slow}…" || { sc_model_stop "$model" "$host"; return 1; }
    else
      sc_structured_request "$model" "$host" "$format" "$sprompt" \
        "Checking the note against the transcript with ${who}…"
      rc=$?
    fi
    sjson="$SC_STRUCT_JSON"
  fi
  if [ -n "$oprompt" ]; then
    # A failed Objective pass never costs the rest of the note: the
    # Objective then says plainly that it needs completing by hand.
    # A few short phrases: a low output cap stops a field that runs on
    # (seen once with Bonsai) from costing minutes before it's retried.
    if sc_structured_request "$model" "$host" objective "$oprompt" "Drafting the Objective with ${who}…" 600; then
      ojson="$SC_STRUCT_JSON"
    else
      sc_err "warning: the Objective pass failed — complete the Objective by hand"
    fi
  fi
  sc_model_stop "$model" "$host"
  SC_RAW_NOTE="$note"; SC_STRUCT_JSON="$sjson"

  local tfile nfile lines
  if [ "$style" = structured ]; then
    SC_NOTE=$(printf '%s' "$SC_STRUCT_JSON" | jq -r -L "$SC_ROOT/lib/structured" \
      --arg format "$format" -f "$SC_ROOT/lib/structured/render.jq") || return 1
    [ "$format" = soap ] && { sc_add_objective "$ojson" || return 1; }
    sc_tmpfile tfile || return 1
    printf '%s\n' "$transcript" > "$tfile"
    lines=$(printf '%s' "$SC_STRUCT_JSON" | jq -r -L "$SC_ROOT/lib/structured" \
      --rawfile transcript "$tfile" --arg format "$format" -f "$SC_ROOT/lib/structured/validate.jq" \
      | jq -r '.[] | "  • " + .')
    rm -f "$tfile"
    if [ -n "$lines" ]; then SC_REVIEW=$(sc_review_block "review before submitting" "$lines")
    else SC_REVIEW="review: nothing flagged"; fi
    [ -n "$SC_NOTE" ]
    return
  fi

  # Three safety nets against known model misbehavior in prose — see each
  # function's own comment for the specific failure it guards against.
  note="$SC_RAW_NOTE"
  note=$(printf '%s\n' "$note" | sc_strip_transcript_echo)
  note=$(printf '%s\n' "$note" | sc_strip_contaminated_fallback)
  SC_NOTE=$(printf '%s\n' "$note" | sc_strip_trailing_disclaimer)
  [ -n "$SC_NOTE" ] || return 1
  if [ "$format" = soap ]; then
    sc_add_objective "$ojson" || return 1
    SC_NOTE=$(printf '%s\n' "$SC_NOTE" | sc_default_plan)
  fi

  if [ "$style" = combined ]; then
    if [ "$rc" -ne 0 ]; then
      # The review pass is a check, not the note: never lose the note over it.
      SC_REVIEW="warning: the review pass failed, so this note hasn't been checked against the transcript"
      return 0
    fi
    sc_tmpfile tfile || return 0
    sc_tmpfile nfile || return 0
    printf '%s\n' "$transcript" > "$tfile"
    printf '%s\n' "$SC_NOTE" > "$nfile"
    lines=$(printf '%s' "$SC_STRUCT_JSON" | jq -r -L "$SC_ROOT/lib/structured" \
      --rawfile transcript "$tfile" --rawfile note "$nfile" --arg format "$format" \
      -f "$SC_ROOT/lib/structured/review.jq" | jq -r '
        (.flags[] | "  • " + .),
        (if (.steps | length) > 0 then
           "  Next steps mentioned in the session — confirm each is in the note:",
           (.steps[] | "    line \(.line): \(.action)")
         else empty end)')
    rm -f "$tfile" "$nfile"
    if [ -n "$lines" ]; then SC_REVIEW=$(sc_review_block "review before submitting" "$lines")
    else SC_REVIEW="review: nothing flagged"; fi
  fi
  return 0
}

# sc_session_line MINUTES — prints the note's first line, e.g.
# "63 minutes, telehealth".
sc_session_line() {
  case "$1" in
    0) printf 'under 1 minute, %s\n' "$SOAPCAP_SESSION_TYPE" ;;
    1) printf '1 minute, %s\n' "$SOAPCAP_SESSION_TYPE" ;;
    *) printf '%s minutes, %s\n' "$1" "$SOAPCAP_SESSION_TYPE" ;;
  esac
}

# sc_with_session_line MINUTES NOTE — prints NOTE under its session line,
# or unchanged when MINUTES is empty (a transcript of unknown length).
sc_with_session_line() {
  if [ -n "$1" ]; then printf '%s\n\n%s\n' "$(sc_session_line "$1")" "$2"
  else printf '%s\n' "$2"; fi
}

# ---------------------------------------------------------------------------
# soapcap note [FILE] [--model NAME] [--format soap|dap|birp]
#              [--style narrative|structured|combined] [--host URL]
#              [--duration MINUTES] [--out FILE] [--clipboard]
#
# Reads a transcript (FILE, or stdin so it composes with `live`/`transcribe`)
# and drafts a note via sc_generate_note(). Any review text goes to stderr,
# never into the note, --out, or the clipboard. --duration puts the
# session line ("50 minutes, telehealth") above the note; a transcript file
# doesn't record how long the session was.
sc_cmd_note() {
  local file="" out="" model="$SOAPCAP_MODEL" format="$SOAPCAP_FORMAT" host="$SOAPCAP_OLLAMA_HOST"
  local style="$SOAPCAP_STYLE" clipboard=0 duration=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out)       out="${2:?--out needs a path}"; shift 2 ;;
      --model)     model="${2:?}"; shift 2 ;;
      --format)    format="${2:?}"; shift 2 ;;
      --style)     style="${2:?}"; shift 2 ;;
      --host)      host="${2:?}"; shift 2 ;;
      --duration)  duration="${2:?--duration needs a number of minutes}"; shift 2 ;;
      --clipboard) clipboard=1; shift ;;
      -h|--help)   sc_usage; return 0 ;;
      -*) sc_die "note: unknown option: $1" ;;
      *)  file="$1"; shift ;;
    esac
  done

  sc_check_style "$style" || exit 1
  case "$duration" in
    ''|*[!0-9]*) [ -z "$duration" ] || sc_die "note: --duration takes whole minutes, e.g. --duration 53" ;;
  esac
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

  sc_generate_note "$format" "$model" "$host" "$transcript" "$style" || sc_die "note generation failed"
  local note
  note=$(sc_with_session_line "$duration" "$SC_NOTE")

  if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$note" > "$out"
    sc_info "note written to: $out  (contains PHI — delete when done)"
  else
    sc_show "$note"
  fi
  [ -n "$SC_REVIEW" ] && sc_info "$SC_REVIEW"
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

# sc_save_transcript TEXT — saves a de-identified transcript under
# SOAPCAP_SAVE_DIR as <date>-<time>.deid.transcript (a name `note`'s file
# picker finds), readable by this user only, never overwriting an existing
# file. Prints the path.
sc_save_transcript() {
  local dir="$SOAPCAP_SAVE_DIR" base path n=1
  base="$(date +%Y-%m-%d-%H%M).deid"
  mkdir -p "$dir" && chmod 700 "$dir" 2>/dev/null
  path="$dir/$base.transcript"
  while [ -e "$path" ]; do n=$((n + 1)); path="$dir/$base-$n.transcript"; done
  ( umask 077; printf '%s\n' "$1" > "$path" ) || { sc_err "couldn't write $path"; return 1; }
  printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# soapcap session [--format soap|dap|birp] [--model NAME] [--no-note]
#                 [--style narrative|structured|combined]
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
  local style="$SOAPCAP_STYLE" no_note=0 clipboard=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --mic-label)    mic="${2:?}"; shift 2 ;;
      --system-label) sys="${2:?}"; shift 2 ;;
      --locale)       locale="${2:?}"; shift 2 ;;
      --no-dedupe)    dedupe=0; shift ;;
      --format)       format="${2:?}"; shift 2 ;;
      --style)        style="${2:?}"; shift 2 ;;
      --model)        model="${2:?}"; shift 2 ;;
      --host)         host="${2:?}"; shift 2 ;;
      --no-note)      no_note=1; shift ;;
      --clipboard)    clipboard=1; shift ;;
      -h|--help)      sc_usage; return 0 ;;
      *) sc_die "session: unknown option: $1" ;;
    esac
  done
  # Checked before capture starts, not after an hour-long session.
  sc_check_style "$style" || exit 1
  # sc_generate_note looks for the client's lines by this label.
  SOAPCAP_SYSTEM_LABEL="$sys"

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

  local line_count minutes
  line_count=$(printf '%s\n' "$transcript" | wc -l | tr -d ' ')
  # Whole minutes spent recording, rounded down so it never overstates
  # the session; paused time isn't counted.
  minutes=$(( ${SC_SESSION_SECONDS:-0} / 60 ))

  sc_info ""
  sc_info "Transcript: $line_count line(s), recorded $(( ${SC_SESSION_SECONDS:-0} / 60 )):$(printf '%02d' $(( ${SC_SESSION_SECONDS:-0} % 60 ))) — the note will say \"$(sc_session_line "$minutes")\"."

  # One all-or-nothing question, asked once and only when the helper is
  # built. It comes before "Show the transcript?" so that what's printed
  # to the screen is already the redacted text. Yes redacts the transcript
  # here (everything downstream -- display, drafting, clipboard -- then
  # uses the redacted version) and the drafted note again before it's shown.
  local deidentify=0 saved=""
  if [ -t 0 ] && [ -x "$SOAPCAP_DEIDENTIFY_BIN" ]; then
    sc_confirm "De-identify the transcript now, and the note once it's drafted?" && deidentify=1
  fi
  if [ "$deidentify" -eq 1 ]; then
    if sc_deidentify_transcript "$transcript"; then
      transcript="$SC_DEIDENTIFY_TRANSCRIPT"
      sc_info "transcript: $SC_DEIDENTIFY_SUMMARY"
      # Only ever offered for a transcript that really was redacted, and
      # "no" comes first so bare Enter never writes PHI to disk.
      if [ "$(sc_choose "Save the de-identified transcript to $SOAPCAP_SAVE_DIR?" no yes)" = yes ]; then
        saved=$(sc_save_transcript "$transcript") \
          && sc_info "saved: $saved — best-effort de-identification; review it before sharing, and delete it when done"
      fi
    else
      sc_err "transcript de-identify failed — continuing with the original transcript (see above)"
    fi
  fi

  local show_transcript=1
  [ -t 0 ] && { sc_confirm "Show the transcript?" || show_transcript=0; }
  if [ "$show_transcript" -eq 1 ]; then
    sc_info ""
    sc_info "----- transcript -----"
    sc_show "$transcript"
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
      if sc_generate_note "$format" "$model" "$host" "$transcript" "$style"; then
        if [ "$deidentify" -eq 1 ]; then
          if sc_deidentify_transcript "$SC_NOTE"; then
            SC_NOTE="$SC_DEIDENTIFY_TRANSCRIPT"
            sc_info "note: $SC_DEIDENTIFY_SUMMARY"
          else
            sc_err "note de-identify failed — showing the note as drafted instead (see above)"
          fi
        fi
        # Added after de-identification, so the redaction pass never sees
        # it; SC_NOTE is drafted afresh on regenerate, so it never stacks.
        SC_NOTE=$(sc_with_session_line "$minutes" "$SC_NOTE")
        sc_info ""
        sc_info "----- $format note -----"
        sc_show "$SC_NOTE"
        sc_info "-------------------------"
        [ -n "$SC_REVIEW" ] && sc_info "$SC_REVIEW"
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
  if [ -n "$saved" ]; then
    sc_info "The de-identified transcript is saved at $saved; nothing else was written to disk."
  else
    sc_info "Nothing here was written to disk unless you redirected it yourself."
  fi
  if [ "${SC_ALT_SCREEN:-0}" = "1" ]; then
    sc_info "This screen won't appear in your terminal's scrollback."
  fi
}
