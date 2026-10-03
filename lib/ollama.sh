# shellcheck shell=bash
# The Ollama note backend: every model tag except `bonsai`. One of the two
# backends behind sc_model_* (lib/generate.sh), which calls the
# sc_ollama_{label,check,start,request,stop} functions here.

# sc_ollama_models HOST — prints the tags pulled into the Ollama at HOST, one
# per line. Fails when nothing answers there.
sc_ollama_models() {
  local tags
  tags=$(curl -s --max-time 5 "$1/api/tags" 2>/dev/null) || return 1
  [ -n "$tags" ] || return 1
  printf '%s' "$tags" | jq -r '.models[]?.name // empty' 2>/dev/null
}

# sc_ollama_has MODEL — reads tags on stdin (sc_ollama_models); succeeds when
# MODEL is one of them, or names one without its size ("llama3.1").
sc_ollama_has() {
  awk -v m="$1" '$0 == m || index($0, m ":") == 1 { found = 1 } END { exit !found }'
}

# sc_warn_remote_host HOST — soapcap's promise is that a transcript never
# leaves this Mac, but --host / SOAPCAP_OLLAMA_HOST can point anywhere. Says
# so, once a run, when HOST isn't a loopback address.
sc_warn_remote_host() {
  [ -z "${SC_HOST_WARNED:-}" ] || return 0
  local h="${1#*://}"
  h="${h%%/*}"
  case "$h" in
    localhost|localhost:*|127.*|'[::1]'|'[::1]':*) return 0 ;;
  esac
  SC_HOST_WARNED=1
  sc_err "warning: $1 is not this Mac — the transcript will be sent to that machine over the network"
}

sc_ollama_label() { printf '%s\n' "$1"; }

# sc_ollama_check MODEL HOST — silent when MODEL is ready to draft with;
# otherwise says what to fix and fails.
sc_ollama_check() {
  local model="$1" host="$2" names
  sc_warn_remote_host "$host"
  if ! names=$(sc_ollama_models "$host"); then
    sc_err "can't reach Ollama at $host — start it with: brew services start ollama (or: ollama serve)"
    return 1
  fi
  if ! printf '%s\n' "$names" | sc_ollama_has "$model"; then
    sc_err "model '$model' is not pulled — run: ollama pull $model"
    return 1
  fi
}

# sc_ollama_start MODEL HOST CTX — checks MODEL is there and fixes the
# context size for every request that follows. Ollama loads a model on its
# first request, and loads it again whenever a request's num_ctx differs from
# the last one's, so each pass of a note must send the same size. Its own
# default (historically 2048) is far too small; never below 4096.
sc_ollama_start() {
  sc_ollama_check "$1" "$2" || return 1
  SC_OLLAMA_CTX=$3
  [ "$SC_OLLAMA_CTX" -ge 4096 ] || SC_OLLAMA_CTX=4096
}

# sc_ollama_request MODEL HOST PROMPT TITLE CAP [SCHEMA] — sets SC_RAW_NOTE
# and SC_RAW_DONE (Ollama's done_reason). CAP is the output cap in tokens:
# without one, a model that starts repeating itself runs until the request
# times out. With SCHEMA (a JSON schema) the reply is JSON matching it, under
# the structured style's sampling settings; without, prose under the model's
# own defaults. Talks to Ollama's HTTP API directly rather than shelling out
# to `ollama run`: the CLI renders a spinner/progress UI even when its stdout
# isn't a terminal, which corrupts captured output. Always sent with
# think:false: reasoning made notes worse in testing.
sc_ollama_request() {
  SC_RAW_NOTE=""; SC_RAW_DONE=""
  local model="$1" host="$2" prompt="$3" title="$4" cap="$5" schema="${6:-}"
  local payload resp_file rc response
  # The prompt holds the transcript: it reaches jq on stdin, not as an
  # argument, where any local process could read it with `ps`.
  payload=$(printf '%s' "$prompt" | jq -Rs --arg model "$model" \
    --argjson ctx "${SC_OLLAMA_CTX:-4096}" --argjson cap "$cap" --argjson schema "${schema:-null}" '
      {model: $model, prompt: ., stream: true, think: false,
       options: {num_ctx: $ctx, num_predict: $cap}}
      | if $schema then .format = $schema
                        | .options += {temperature: 0.3, top_p: 0.8, top_k: 20}
        else . end')

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

# sc_ollama_stop MODEL HOST — asks Ollama to unload MODEL now rather than
# keep it in memory for its default five minutes. Best effort: a failed
# unload only means Ollama drops it later on its own.
sc_ollama_stop() {
  curl -s --max-time 5 -X POST "$2/api/generate" -H 'Content-Type: application/json' \
    -d "$(jq -nc --arg m "$1" '{model: $m, keep_alive: 0}')" >/dev/null 2>&1
  return 0
}
