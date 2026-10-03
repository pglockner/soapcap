# shellcheck shell=bash
# The Bonsai note backend (`--model bonsai`): Bonsai 2 27B, served by a
# llama-server soapcap starts for a note and stops afterwards. One of the two
# backends behind sc_model_* (lib/generate.sh), which calls the
# sc_bonsai_{label,check,start,request,stop} functions here.

sc_bonsai_label() { printf 'Bonsai\n'; }

# sc_bonsai_installed — true when both halves of the Bonsai setup exist.
sc_bonsai_installed() {
  [ -x "$SOAPCAP_BONSAI_SERVER" ] && [ -f "$SOAPCAP_BONSAI_GGUF" ]
}

# sc_bonsai_running — true while the server sc_bonsai_start launched is up.
sc_bonsai_running() {
  [ -n "${SC_BONSAI_PID:-}" ] && kill -0 "$SC_BONSAI_PID" 2>/dev/null
}

# sc_bonsai_check [MODEL HOST] — silent when Bonsai is ready to start;
# otherwise says what to fix and fails.
sc_bonsai_check() {
  if ! sc_bonsai_installed; then
    sc_err "Bonsai isn't set up — expected llama-server at $SOAPCAP_BONSAI_SERVER"
    sc_err "  and the model at $SOAPCAP_BONSAI_GGUF. Set it up with: $SC_ROOT/tools/bonsai/install.sh"
    return 1
  fi
  # Anything already answering here would silently draft the note with
  # whatever model it serves.
  if curl -s --max-time 2 "http://127.0.0.1:$SOAPCAP_BONSAI_PORT/health" >/dev/null 2>&1; then
    sc_err "something is already listening on port $SOAPCAP_BONSAI_PORT — stop it, or set"
    sc_err "  SOAPCAP_BONSAI_PORT to a free port in ~/.config/soapcap/config.sh"
    return 1
  fi
}

# sc_bonsai_start MODEL HOST CTX — launches llama-server with the Bonsai GGUF
# on 127.0.0.1:$SOAPCAP_BONSAI_PORT, with a context of CTX tokens (at least
# 8192), and waits until it has loaded. A server still running from an
# earlier draft is reused when its context is big enough. Sets
# SC_BONSAI_PID; sc_bonsai_stop undoes it. Server flags match the ones
# soapcap's prompts were tested with.
sc_bonsai_start() {
  local ctx="$3" url="http://127.0.0.1:$SOAPCAP_BONSAI_PORT"
  [ "$ctx" -ge 8192 ] || ctx=8192
  if sc_bonsai_running && [ "${SC_BONSAI_CTX:-0}" -ge "$ctx" ]; then
    return 0
  fi
  sc_bonsai_stop
  sc_bonsai_check || return 1

  sc_tmpfile SC_BONSAI_LOG || return 1
  "$SOAPCAP_BONSAI_SERVER" -m "$SOAPCAP_BONSAI_GGUF" --host 127.0.0.1 --port "$SOAPCAP_BONSAI_PORT" \
    -ngl 99 -c "$ctx" --parallel 1 --cache-type-k q8_0 --cache-type-v q8_0 \
    >"$SC_BONSAI_LOG" 2>&1 &
  SC_BONSAI_PID=$!
  SC_BONSAI_CTX=$ctx

  sc_info "Loading Bonsai (a note takes a few minutes)…"
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

# sc_bonsai_request MODEL HOST PROMPT TITLE CAP [SCHEMA] — sets SC_RAW_NOTE
# and SC_RAW_DONE (the finish_reason). Sends one chat request to the
# already-running server; CAP is the output cap in tokens. With SCHEMA (a
# JSON schema) the reply is JSON matching it, under the structured style's
# sampling settings; without, prose under the narrative ones -- in both
# cases the settings soapcap's prompts were tested with. Thinking is always
# off: with it on, a note takes many minutes longer and the prompts were
# tested without it.
sc_bonsai_request() {
  SC_RAW_NOTE=""; SC_RAW_DONE=""
  local prompt="$3" title="$4" cap="$5" schema="${6:-}" payload resp_file rc response
  # The prompt holds the transcript: it reaches jq on stdin, not as an
  # argument, where any local process could read it with `ps`.
  payload=$(printf '%s' "$prompt" | jq -Rs --argjson cap "$cap" --argjson schema "${schema:-null}" '
      {messages: [{role: "user", content: .}], stream: false,
       chat_template_kwargs: {enable_thinking: false},
       top_p: 0.8, top_k: 20, max_tokens: $cap}
      + if $schema then {temperature: 0.3,
                         response_format: {type: "json_schema", json_schema: {schema: $schema}}}
        else {temperature: 0.7} end')
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
  # shellcheck disable=SC2034  # read by sc_generate_note (lib/note.sh)
  SC_RAW_DONE=$(printf '%s' "$response" | jq -r '.choices[0].finish_reason // empty')
  [ -n "$SC_RAW_NOTE" ] || { sc_err "Bonsai returned no content"; return 1; }
}

# sc_bonsai_stop — stops the llama-server sc_bonsai_start launched, if any,
# and waits for it so its memory is actually released before we go on. Safe
# to call repeatedly.
sc_bonsai_stop() {
  if [ -n "${SC_BONSAI_PID:-}" ]; then
    kill "$SC_BONSAI_PID" 2>/dev/null
    # llama-server finishes an in-flight request before honouring SIGTERM
    # (~30s observed mid-note); give it 3s, then force it.
    local i=0
    while [ "$i" -lt 30 ] && kill -0 "$SC_BONSAI_PID" 2>/dev/null; do
      sleep 0.1; i=$((i + 1))
    done
    kill -KILL "$SC_BONSAI_PID" 2>/dev/null
    wait "$SC_BONSAI_PID" 2>/dev/null
  fi
  SC_BONSAI_PID=""
  if [ -n "${SC_BONSAI_LOG:-}" ]; then
    rm -f "$SC_BONSAI_LOG"
  fi
  SC_BONSAI_LOG=""
}
