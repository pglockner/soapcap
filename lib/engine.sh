# shellcheck shell=bash
# The engine note backend: the models soapcap runs on its own llama-server
# (PrismML's llama.cpp fork, built by tools/models/install.sh), started for a
# note and stopped afterwards. One of the two backends behind sc_model_*
# (lib/generate.sh), which calls the
# sc_engine_{label,check,start,request,stop,resumes_opening} functions here.

# sc_engine_model MODEL — prints "LABEL|GGUF|FLAGS" for each model the engine
# runs: its name on screen, its weights, and the server flags it needs beyond
# the ones every model gets. Fails for any other name. Adding a model means
# one line here, its pin in tools/models/install.sh, and its catalog line
# (sc_model_catalog).
#
# Gemma's attention looks back over a sliding window, so the server can
# return to the end of a shared opening only from a checkpoint; without one
# taken at every request, the Objective pass reads the transcript again.
sc_engine_model() {
  case "$1" in
    gemma4-e4b) printf '%s|%s|%s\n' "Gemma 4 E4B" "$SOAPCAP_GEMMA_GGUF" "--checkpoint-min-step 0" ;;
    bonsai)     printf '%s|%s|%s\n' "Bonsai" "$SOAPCAP_BONSAI_GGUF" "" ;;
    *) return 1 ;;
  esac
}

sc_engine_label() { sc_engine_model "$1" | cut -d'|' -f1; }

sc_engine_gguf() { sc_engine_model "$1" | cut -d'|' -f2; }

# sc_engine_resumes_opening — yes, for both models: each keeps its place
# only near the end of a prompt (a hybrid model, a sliding window), so a
# transcript in the middle of one is read again by the next request.
# Measured with Bonsai on the 60-minute sample: a SOAP note's Objective pass
# took 194 s re-reading the transcript and 48 s resuming after it.
sc_engine_resumes_opening() { return 0; }

# sc_engine_installed MODEL — true when the server and MODEL's weights exist.
sc_engine_installed() {
  local gguf
  gguf=$(sc_engine_gguf "$1") || return 1
  [ -x "$SOAPCAP_LLAMA_SERVER" ] && [ -f "$gguf" ]
}

# sc_engine_running — true while the server sc_engine_start launched is up.
sc_engine_running() {
  [ -n "${SC_ENGINE_PID:-}" ] && kill -0 "$SC_ENGINE_PID" 2>/dev/null
}

# sc_engine_check MODEL [HOST] — silent when MODEL is ready to start;
# otherwise says what to fix and fails.
sc_engine_check() {
  local label
  label=$(sc_engine_label "$1")
  if ! sc_engine_installed "$1"; then
    sc_err "$label isn't set up — expected llama-server at $SOAPCAP_LLAMA_SERVER"
    sc_err "  and the model at $(sc_engine_gguf "$1"). Set it up with: $SC_ROOT/tools/models/install.sh $1"
    return 1
  fi
  # Anything already answering here would silently draft the note with
  # whatever model it serves.
  if curl -s --max-time 2 "http://127.0.0.1:$SOAPCAP_ENGINE_PORT/health" >/dev/null 2>&1; then
    sc_err "something is already listening on port $SOAPCAP_ENGINE_PORT — stop it, or set"
    sc_err "  SOAPCAP_ENGINE_PORT to a free port in ~/.config/soapcap/config.sh"
    return 1
  fi
}

# sc_engine_start MODEL HOST CTX — launches llama-server with MODEL's weights
# on 127.0.0.1:$SOAPCAP_ENGINE_PORT, with a context of CTX tokens (at least
# 8192), and waits until it has loaded. A server still running MODEL from an
# earlier draft is reused when its context is big enough. Sets
# SC_ENGINE_PID; sc_engine_stop undoes it. Server flags match the ones
# soapcap's prompts were tested with.
sc_engine_start() {
  local model="$1" ctx="$3" url="http://127.0.0.1:$SOAPCAP_ENGINE_PORT" label gguf flags
  [ "$ctx" -ge 8192 ] || ctx=8192
  if sc_engine_running && [ "${SC_ENGINE_MODEL:-}" = "$model" ] && [ "${SC_ENGINE_CTX:-0}" -ge "$ctx" ]; then
    return 0
  fi
  sc_engine_stop
  sc_engine_check "$model" || return 1
  IFS='|' read -r label gguf flags <<<"$(sc_engine_model "$model")"

  sc_tmpfile SC_ENGINE_LOG || return 1
  # shellcheck disable=SC2086  # $flags is a list of flags
  "$SOAPCAP_LLAMA_SERVER" -m "$gguf" --host 127.0.0.1 --port "$SOAPCAP_ENGINE_PORT" \
    -ngl 99 -c "$ctx" --parallel 1 --cache-type-k q8_0 --cache-type-v q8_0 $flags \
    >"$SC_ENGINE_LOG" 2>&1 &
  SC_ENGINE_PID=$!
  SC_ENGINE_CTX=$ctx
  SC_ENGINE_MODEL=$model

  sc_info "Loading ${label}…"
  local i=0
  while [ "$i" -lt 180 ]; do
    if ! kill -0 "$SC_ENGINE_PID" 2>/dev/null; then
      sc_err "llama-server exited while loading $label — last lines of its log:"
      tail -n 5 "$SC_ENGINE_LOG" >&2
      sc_engine_stop
      return 1
    fi
    # Not `jq -e`: jq 1.6 exits 0 on empty input, i.e. when nothing answers.
    if [ "$(curl -s --max-time 2 "$url/health" 2>/dev/null | jq -r '.status // empty' 2>/dev/null)" = ok ]; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  sc_err "$label didn't finish loading within 180s"
  sc_engine_stop
  return 1
}

# sc_engine_request MODEL HOST PROMPT TITLE CAP [SCHEMA] — sets SC_RAW_NOTE
# and SC_RAW_DONE (the finish_reason). Sends one chat request to the
# already-running server; CAP is the output cap in tokens. With SCHEMA (a
# JSON schema) the reply is JSON matching it, under the structured style's
# sampling settings; without, prose under the narrative ones -- in both
# cases the settings soapcap's prompts were tested with. Thinking is always
# off: with it on, a note takes many minutes longer and the prompts were
# tested without it.
sc_engine_request() {
  SC_RAW_NOTE=""; SC_RAW_DONE=""
  local prompt="$3" title="$4" cap="$5" schema="${6:-}" payload resp_file rc response label
  label=$(sc_engine_label "$1")
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
  sc_spin_post "$title" "http://127.0.0.1:$SOAPCAP_ENGINE_PORT/v1/chat/completions" \
    "$payload" "$resp_file" 900
  rc=$?
  response=$(cat "$resp_file"); rm -f "$resp_file"

  if [ "$rc" -ne 0 ] || [ -z "$response" ]; then
    sc_err "request to $label failed"; return 1
  fi
  if printf '%s' "$response" | jq -e '.error' >/dev/null 2>&1; then
    sc_err "$label error: $(printf '%s' "$response" | jq -r '.error.message // .error')"
    return 1
  fi
  SC_RAW_NOTE=$(printf '%s' "$response" | jq -r '.choices[0].message.content // empty')
  # shellcheck disable=SC2034  # read by sc_generate_note (lib/note.sh)
  SC_RAW_DONE=$(printf '%s' "$response" | jq -r '.choices[0].finish_reason // empty')
  [ -n "$SC_RAW_NOTE" ] || { sc_err "$label returned no content"; return 1; }
}

# sc_engine_stop — stops the llama-server sc_engine_start launched, if any,
# and waits for it so its memory is actually released before we go on. Safe
# to call repeatedly.
sc_engine_stop() {
  if [ -n "${SC_ENGINE_PID:-}" ]; then
    kill "$SC_ENGINE_PID" 2>/dev/null
    # llama-server finishes an in-flight request before honouring SIGTERM
    # (~30s observed mid-note); give it 3s, then force it.
    local i=0
    while [ "$i" -lt 30 ] && kill -0 "$SC_ENGINE_PID" 2>/dev/null; do
      sleep 0.1; i=$((i + 1))
    done
    kill -KILL "$SC_ENGINE_PID" 2>/dev/null
    wait "$SC_ENGINE_PID" 2>/dev/null
  fi
  SC_ENGINE_PID=""; SC_ENGINE_MODEL=""
  if [ -n "${SC_ENGINE_LOG:-}" ]; then
    rm -f "$SC_ENGINE_LOG"
  fi
  SC_ENGINE_LOG=""
}
