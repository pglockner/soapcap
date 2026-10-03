# shellcheck shell=bash
# Talking to the note model: output safety nets, context sizing, the
# drafting status line, and the Ollama request.

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

# sc_ctx_exceeds_cap PROMPT HEADROOM — succeeds when PROMPT plus HEADROOM
# needs more than sc_estimate_ctx's 32768-token cap, i.e. the model would
# silently lose part of the prompt (see sc_estimate_ctx).
sc_ctx_exceeds_cap() {
  local words
  words=$(printf '%s' "$1" | wc -w | tr -d ' ')
  [ $(( words * 3 / 2 + $2 )) -gt 32768 ]
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

# sc_swap_info — prints "PERCENT GB" for swap in use (e.g. "42 2.1"), or
# nothing when there is no swap file yet. macOS grows swap on demand, so
# the percentage is of the swap file as it stands now.
sc_swap_info() {
  sysctl -n vm.swapusage 2>/dev/null | awk '
    function mb(v,  u) { u = substr(v, length(v)); sub(/[MG]$/, "", v); return u == "G" ? v * 1024 : v }
    { for (i = 1; i < NF; i++) {
        if ($i == "total") t = mb($(i+2))
        if ($i == "used")  u = mb($(i+2)) } }
    END { if (t > 0) printf "%d %.1f\n", u * 100 / t, u / 1024 }'
}

# sc_status_line TITLE SECONDS SPINNER [PROGRESS] — prints one redraw of
# the drafting status line to stderr: spinner, title, elapsed time, PROGRESS
# (e.g. a token count) if given, and memory in use, green below 75%, yellow
# to 90%, red above. From 90% it adds swap in use, which is what pushes the
# memory figure up.
sc_status_line() {
  local mem color="" reset=$'\033[0m' swap="" progress=""
  [ -n "${4:-}" ] && progress="   $4"
  mem=$(sc_mem_pct)
  if [ -n "$mem" ]; then
    if [ "$mem" -ge 90 ]; then
      color=$'\033[31m'
      local sw
      sw=$(sc_swap_info)
      [ -n "$sw" ] && swap="   ${color}swap ${sw% *}% (${sw#* }GB)${reset}"
    elif [ "$mem" -ge 75 ]; then color=$'\033[33m'
    else color=$'\033[32m'; fi
    mem="   ${color}memory ${mem}%${reset}"
  fi
  printf '\r\033[K%s %s  %d:%02d%s%s%s' "$3" "$1" $(($2 / 60)) $(($2 % 60)) "$progress" "$mem" "$swap" >&2
}

# sc_token_progress TOKENS SECONDS_SINCE_FIRST — "412 tokens, 18 tok/s".
# The rate runs from the first token, so reading a long transcript doesn't
# drag it down, and appears once there are 2+ seconds to measure.
sc_token_progress() {
  if [ "$2" -ge 2 ]; then printf '%s tokens, %s tok/s\n' "$1" $(($1 / $2))
  else printf '%s tokens\n' "$1"; fi
}

# sc_spin_post TITLE URL PAYLOAD OUTFILE MAX_SECONDS [COUNT] — POSTs PAYLOAD
# as JSON to URL, response body to OUTFILE. With COUNT set, the response is
# Ollama's streamed NDJSON (one line per generated token) and the status
# line shows a live token count and rate. Returns curl's own exit status. On a
# terminal it shows a status line, redrawn every second, with elapsed time
# and memory in use (a large model can push a 16GB Mac into swap);
# otherwise, e.g. under a GUI front end, just the title. PAYLOAD holds the
# transcript, so it goes to curl from a private temp file rather than as
# an argument, where any local process could read it with `ps`.
sc_spin_post() {
  local title="$1" url="$2" payload="$3" out="$4" max="$5" count="${6:-}" body rc
  sc_tmpfile body || return 1
  printf '%s' "$payload" > "$body"
  [ -t 2 ] || sc_info "$title"
  # Backgrounded + `wait` because bash holds a signal until a foreground
  # command finishes — minutes, here — so a SIGTERM (how a GUI front
  # end stops soapcap) would otherwise go unanswered, and a second one kills
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
    local tokens=0 t_first="" progress=""
    while kill -0 "$cpid" 2>/dev/null; do
      progress=""
      if [ -n "$count" ]; then
        tokens=$(wc -l < "$out" 2>/dev/null | tr -d ' ')
        if [ "${tokens:-0}" -gt 0 ]; then
          [ -n "$t_first" ] || t_first=$SECONDS
          progress=$(sc_token_progress "$tokens" $((SECONDS - t_first)))
        fi
      fi
      sc_status_line "$title" $((SECONDS - t0)) "${frames[$((i % 10))]}" "$progress"
      i=$((i + 1))
      # `wait` on a background sleep, not a foreground one, so a signal is
      # still acted on at once.
      sleep 1 & wait $! 2>/dev/null
    done
    wait "$cpid"
    rc=$?
    if [ "$rc" -eq 0 ] && [ -n "${SC_KEEP_PASS_STATS:-}" ]; then
      # Only `session` sets this. Keep the finished pass's line, with its final time/tokens/memory,
      # so the cost of the note stays on screen; the next pass starts on
      # a fresh line.
      progress=""
      if [ -n "$count" ]; then
        tokens=$(wc -l < "$out" 2>/dev/null | tr -d ' ')
        [ "${tokens:-0}" -gt 0 ] && progress=$(sc_token_progress "$tokens" $((SECONDS - ${t_first:-$SECONDS})))
      fi
      sc_status_line "$title" $((SECONDS - t0)) "✓" "$progress"
      printf ' -- done!\n' >&2
    else
      printf '\r\033[K' >&2
    fi
  else
    wait "$cpid"
    rc=$?
  fi
  trap - INT TERM
  rm -f "$body"
  return "$rc"
}

# sc_ollama_generate MODEL HOST PROMPT TITLE [HEADROOM] [EXTRA] — sets
# SC_RAW_NOTE and SC_RAW_DONE (Ollama's done_reason). Talks to Ollama's
# HTTP API directly rather than shelling out to `ollama run`: the CLI
# renders a spinner/progress UI even when its stdout isn't a terminal,
# which corrupts captured output. EXTRA is a JSON object deep-merged into
# the request (the structured style's schema and sampling settings). Always
# sent with think:false: reasoning made notes worse in testing.
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
    '{model: $model, prompt: $prompt, stream: true, think: false, options: {num_ctx: $num_ctx}}')
  if [ -n "$extra" ]; then
    payload=$(printf '%s' "$payload" | jq --argjson x "$extra" '. * $x')
  fi

  sc_tmpfile resp_file || return 1
  sc_spin_post "$title" "$host/api/generate" "$payload" "$resp_file" 300 count
  rc=$?
  # Streamed: one JSON object per token. Fold them back into the single
  # object a non-streamed reply would have been (text joined, the last
  # chunk's done_reason, any error).
  response=$(jq -s 'if length == 0 then empty else {
      response: (map(.response // "") | join("")),
      done_reason: (map(.done_reason // empty) | last),
      error: (map(.error // empty) | first) } end' "$resp_file" 2>/dev/null)
  rm -f "$resp_file"
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
  # shellcheck disable=SC2034  # read by sc_generate_note (lib/note.sh)
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
