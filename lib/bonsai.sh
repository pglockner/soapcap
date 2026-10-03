# shellcheck shell=bash
# The Bonsai note model, served by a llama-server soapcap starts per note.

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
