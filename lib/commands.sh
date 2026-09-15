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
    sc_info "        ${mem_gb}GB: comfortable for 'note' (default llama3.1:8b) alongside other apps"
    sc_info "        (or the stronger, slower qwen2.5:14b — see config.example.sh)"
  elif [ "$mem_gb" -ge 16 ] 2>/dev/null; then
    sc_info "        ${mem_gb}GB: llama3.1:8b (default) works, but close memory-heavy apps"
    sc_info "        (browsers, other local models) first. Comfortable otherwise:"
    sc_info "        soapcap note --model llama3.2:3b"
  elif [ "$mem_gb" -gt 0 ] 2>/dev/null; then
    sc_info "        ${mem_gb}GB: tight for local note drafting. Close other apps and try:"
    sc_info "        soapcap note --model llama3.2:3b"
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
  if command -v ollama >/dev/null 2>&1; then
    local tags
    if tags=$(curl -s --max-time 3 "$SOAPCAP_OLLAMA_HOST/api/tags" 2>/dev/null) && [ -n "$tags" ]; then
      if printf '%s' "$tags" | jq -e --arg m "$SOAPCAP_MODEL" \
           '[.models[]?.name] | any(. == $m or startswith($m + ":"))' >/dev/null 2>&1; then
        sc_info "  ok    ollama running, $SOAPCAP_MODEL pulled — 'note' is ready"
      else
        sc_info "  WARN  ollama running, but $SOAPCAP_MODEL is not pulled"
        sc_info "        run: ollama pull $SOAPCAP_MODEL"
      fi
    else
      sc_info "  WARN  ollama installed but not running — needed for 'note'"
      sc_info "        run: brew services start ollama   (or: ollama serve)"
    fi
  else
    sc_info "  --    ollama not installed — only needed for 'note' (local SOAP generation)"
    sc_info "        install with: brew install ollama"
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

  sc_info ""
  if [ "$fail" -eq 0 ]; then
    sc_info "Ready."
  else
    sc_info "One or more checks failed — see above."
  fi
  return "$fail"
}

# ---------------------------------------------------------------------------
# sc_model_catalog — one "tag|size|note" line per candidate model, for
# `soapcap model`. llama3.2:3b, llama3.1:8b, and qwen2.5:14b reflect actual
# testing (see README "Draft a note"). The rest postdate that testing and
# are worth trying, but a leading marker in `note` says exactly how much to
# trust them: "[not recommended]" means tested and found worse than an
# existing option; "[untested]" means never run against soapcap's prompts
# at all (sc_cmd_model gates pulling one behind an extra confirmation,
# since that marker specifically means "Objective-section accuracy is
# unverified," not just "not downloaded yet").
sc_model_catalog() {
  cat <<'EOF'
llama3.2:3b|~2GB|Fastest & lightest; prone to inventing plausible clinical detail. Only worth it under real memory pressure.
llama3.1:8b|~5GB|Best balance of reliability and speed. (default)
qwen2.5:14b|~9GB|Most reliable at catching real Objective-section detail. ~2.5x slower, wants more RAM headroom.
qwen3:30b|~19GB (32GB+)|[untested] Mixture-of-experts (3B active params) — faster than its size suggests.
gemma3:27b|~17GB (32GB+)|[untested] Dense 27B. Different failure modes than the Qwen models, worth comparing.
EOF
}

# sc_model_table HOST — prints sc_model_catalog as an aligned, wrapped
# table (~86 columns) with a live PULLED column, one line at a time to
# stdout for the caller to route through sc_info.
sc_model_table() {
  local host="$1" tag size note status
  local pulled
  pulled=$(curl -s --max-time 3 "$host/api/tags" 2>/dev/null | jq -r '.models[]?.name // empty' 2>/dev/null)
  {
    while IFS='|' read -r tag size note; do
      [ -z "$tag" ] && continue
      status="not pulled"
      printf '%s\n' "$pulled" | grep -qx "$tag" && status="pulled"
      printf '%s\t%s\t%s\t%s\n' "$tag" "$size" "$status" "$note"
    done <<CATALOG
$(sc_model_catalog)
CATALOG
  } | awk -F'\t' -v tagw=13 -v sizew=15 -v statw=11 -v notew=44 '
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
# Shows the model catalog as a table (with live pulled/not-pulled status)
# and, with a real terminal, offers to pick one, pulling it via `ollama
# pull` if needed and saving the pick as the new default for session/note
# (still overridable per-run with --model). Read-only when not
# interactive: just prints the table and the current default.
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
  sc_info ""
  while IFS= read -r line; do sc_info "$line"; done <<TABLE
$(sc_model_table "$host")
TABLE
  sc_info ""

  [ -t 0 ] || return 0

  # $SOAPCAP_MODEL always leads the choices (and is the bare-Enter
  # default), so hitting Enter here never silently changes anything.
  # It's llama3.1:8b on first-time setup (config.sh's absence just leaves
  # common.sh's own compiled-in default in place) and whatever was last
  # saved on every run after that.
  local tag tags=("$SOAPCAP_MODEL")
  while IFS='|' read -r tag _ _; do
    [ -z "$tag" ] || [ "$tag" = "$SOAPCAP_MODEL" ] && continue
    tags+=("$tag")
  done <<CATALOG
$(sc_model_catalog)
CATALOG

  local chosen
  chosen=$(sc_choose "Pick a model:" "${tags[@]}")

  local pulled
  pulled=$(curl -s --max-time 3 "$host/api/tags" 2>/dev/null | jq -r '.models[]?.name // empty' 2>/dev/null)
  if ! printf '%s\n' "$pulled" | grep -qx "$chosen"; then
    local note
    note=$(sc_model_catalog | awk -F'|' -v t="$chosen" '$1 == t { print $3 }')
    case "$note" in
      '[untested]'*)
        sc_info "$chosen hasn't been run against soapcap's prompts — Objective-section"
        sc_info "accuracy in particular is unverified (see README \"Draft a note\")."
        sc_confirm "Pull $chosen anyway?" || { sc_info "Not pulled — default unchanged ($SOAPCAP_MODEL)."; return 1; }
        ;;
      *)
        sc_confirm "$chosen isn't pulled yet — pull it now?" || { sc_info "Not pulled — default unchanged ($SOAPCAP_MODEL)."; return 1; }
        ;;
    esac
    if ! command -v ollama >/dev/null 2>&1; then
      sc_err "ollama CLI not found on PATH — install with: brew install ollama"
      return 1
    fi
    ollama pull "$chosen" || { sc_err "pull failed — default unchanged ($SOAPCAP_MODEL)"; return 1; }
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

# sc_generate_note <format> <model> <host> <transcript>
#
# Asks a local Ollama model to draft a note from a transcript. Talks to
# Ollama's HTTP API directly rather than shelling out to `ollama run` — the
# CLI renders a spinner/progress UI even when its own stdout isn't a real
# terminal, which corrupts captured output; the API returns one clean JSON
# response. The curl call itself runs under `gum spin` when available, safe
# from that same corruption because the response goes straight to a temp
# file (-o), never through gum's own stdout. On success sets SC_NOTE and
# returns 0; on failure prints an actionable error via sc_err and returns
# 1 — it does NOT exit, so a caller
# holding an already-captured transcript (sc_cmd_session) can report the
# failure without losing it. sc_cmd_note, which has nothing else at stake,
# turns that failure straight into sc_die.
sc_generate_note() {
  SC_NOTE=""
  local format="$1" model="$2" host="$3" transcript="$4"

  local prompt_file="$SC_ROOT/prompts/$format.md"
  if [ ! -f "$prompt_file" ]; then
    sc_err "unknown format '$format' (no $prompt_file)"; return 1
  fi

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

  local system_prompt full_prompt payload response note
  system_prompt=$(cat "$prompt_file")
  full_prompt="$system_prompt

TRANSCRIPT:
$transcript"

  # Ollama's context window defaults to a small value (historically 2048)
  # unless a request explicitly asks for more. A long transcript's prompt
  # can silently exceed that with no error -- the model just loses part of
  # the prompt (often the rules, which come first) and produces malformed,
  # repetitive output with invented section headers. Size num_ctx to the
  # actual prompt instead of trusting the default: ~1.5 tokens/word as a
  # safety margin over English's real ~0.75 words/token, plus headroom for
  # the response, floored at 4096 and capped at 32768.
  local word_count est_tokens ctx
  word_count=$(printf '%s' "$full_prompt" | wc -w | tr -d ' ')
  est_tokens=$(( word_count * 3 / 2 + 1024 ))
  ctx=4096
  [ "$est_tokens" -gt "$ctx" ] && ctx=$est_tokens
  [ "$ctx" -gt 32768 ] && ctx=32768
  ctx=$(( ( (ctx + 1023) / 1024 ) * 1024 ))

  payload=$(jq -n --arg model "$model" --arg prompt "$full_prompt" --argjson num_ctx "$ctx" \
    '{model: $model, prompt: $prompt, stream: false, options: {num_ctx: $num_ctx}}')

  local title="Drafting a $format note with ${model}…"
  local resp_file rc
  resp_file=$(mktemp) || { sc_err "could not create a temp file"; return 1; }
  if command -v gum >/dev/null 2>&1; then
    gum spin --title "$title" -- \
      curl -s --max-time 300 -X POST "$host/api/generate" \
        -H 'Content-Type: application/json' -d "$payload" -o "$resp_file"
    rc=$?
  else
    sc_info "$title"
    curl -s --max-time 300 -X POST "$host/api/generate" \
      -H 'Content-Type: application/json' -d "$payload" -o "$resp_file"
    rc=$?
  fi
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
  note=$(printf '%s' "$response" | jq -r '.response // empty')
  if [ -z "$note" ]; then
    sc_err "Ollama returned no content"; return 1
  fi

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
    sc_confirm "Draft a note from this?" && want_note=1
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
    if [ "$keep_note" -eq 1 ] && [ -n "$SC_NOTE" ]; then
      if [ "$clipboard" -eq 1 ]; then
        sc_to_clipboard "$SC_NOTE"
      elif [ -t 0 ]; then
        sc_confirm "Copy the note to the clipboard?" && sc_to_clipboard "$SC_NOTE"
      fi
    fi
  elif [ "$clipboard" -eq 1 ]; then
    sc_to_clipboard "$transcript"
  fi

  sc_info ""
  sc_info "Nothing here was written to disk unless you redirected it yourself."
}
