# shellcheck shell=bash
# shellcheck disable=SC2154  # $here comes from test/run.sh
# Flow tests: run the real bin/soapcap end to end against fake `yap` and
# `curl` (test/stubs/), so capture, stop-signal handling, note generation and
# `session` are exercised without audio hardware or Ollama. Sourced by
# test/run.sh, which provides $here, assert_eq and the pass/fail counters.
#
# Each run is hermetic: `env -i`, a throwaway HOME (no developer config), a
# throwaway TMPDIR, and a PATH holding only the stubs, jq, and /usr/bin:/bin
# (so real yap, ollama and gum are never reached).

FLOW_DIR=$(mktemp -d)
FLOW_BIN="$FLOW_DIR/bin"
mkdir -p "$FLOW_BIN" "$FLOW_DIR/home" "$FLOW_DIR/tmp"
cp "$here/test/stubs/yap" "$here/test/stubs/curl" "$here/test/stubs/llama-server" "$FLOW_BIN/"
ln -s "$(command -v jq)" "$FLOW_BIN/jq"
: > "$FLOW_DIR/bonsai.gguf"
BONSAI_ENV=(SOAPCAP_BONSAI_SERVER="$FLOW_BIN/llama-server" SOAPCAP_BONSAI_GGUF="$FLOW_DIR/bonsai.gguf")

assert_contains() {
  local desc="$1" haystack="$2" needle="$3" r=no
  case "$haystack" in *"$needle"*) r=yes ;; esac
  assert_eq "$desc" yes "$r"
}

assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3" r=yes
  case "$haystack" in *"$needle"*) r=no ;; esac
  assert_eq "$desc" yes "$r"
}

# flow_run SIGNAL [VAR=VALUE ...] -- soapcap ARGS...
# SIGNAL "none" waits for soapcap to finish on its own. Otherwise, once the
# stub yap (or, with FLOW_READY=llama, the stub llama-server) is running,
# SIGNAL goes to the soapcap script's own pid only -- the way the window
# app stops it. Sets FLOW_OUT, FLOW_ERR, FLOW_RC; stdin comes from
# $FLOW_STDIN (default /dev/null).
flow_run() {
  local sig="$1"; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  : > "$FLOW_DIR/yap.log"; : > "$FLOW_DIR/curl.log"; : > "$FLOW_DIR/llama.log"; : > "$FLOW_DIR/curl.args"
  rm -f "$FLOW_DIR/payload.json" "$FLOW_DIR/out" "$FLOW_DIR/err"

  # A job started with & from a non-interactive shell begins with SIGINT
  # ignored (so it couldn't trap it); a terminal's Ctrl-C isn't. perl resets
  # SIGINT to its default and then exec()s soapcap, same pid throughout.
  # shellcheck disable=SC2016  # $SIG is a perl variable, not a shell one
  env -i PATH="$FLOW_BIN:/usr/bin:/bin" HOME="$FLOW_DIR/home" TMPDIR="$FLOW_DIR/tmp" \
    STUB_YAP_LOG="$FLOW_DIR/yap.log" STUB_CURL_LOG="$FLOW_DIR/curl.log" \
    STUB_CURL_PAYLOAD="$FLOW_DIR/payload.json" STUB_LLAMA_LOG="$FLOW_DIR/llama.log" \
    STUB_CURL_ARGS="$FLOW_DIR/curl.args" \
    ${envs[@]+"${envs[@]}"} \
    /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' "$here/bin/soapcap" "$@" \
    <"${FLOW_STDIN:-/dev/null}" >"$FLOW_DIR/out" 2>"$FLOW_DIR/err" &
  local pid=$!
  ( sleep 20; kill -KILL "$pid" 2>/dev/null ) &
  local watchdog=$!

  if [ "$sig" != none ]; then
    local i=0 ready="$FLOW_DIR/yap.log"
    [ "${FLOW_READY:-}" = llama ] && ready="$FLOW_DIR/llama.log"
    while [ "$i" -lt 50 ] && ! grep -q '^started' "$ready"; do
      sleep 0.1; i=$((i + 1))
    done
    sleep 0.3   # let soapcap install its signal trap / reach the request
    kill "-$sig" "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null; FLOW_RC=$?
  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  pkill -f "$FLOW_BIN/yap" 2>/dev/null   # reap a stub left behind by a killed run
  sleep 0.2   # let a signalled stub llama-server log that it stopped
  FLOW_LLAMA_LEFT=$(pgrep -f "$FLOW_BIN/llama-server" | wc -l | tr -d ' ')
  pkill -f "$FLOW_BIN/llama-server" 2>/dev/null
  FLOW_OUT=$(cat "$FLOW_DIR/out"); FLOW_ERR=$(cat "$FLOW_DIR/err")
}

expected_transcript="Therapist: How have you been sleeping
Client: Not great this week"

# --- live: stop signals --------------------------------------------------

flow_run TERM -- live
assert_eq "live: SIGTERM to the script alone yields the transcript" \
  "$expected_transcript" "$FLOW_OUT"
assert_eq "live: SIGTERM exit status is 0" "0" "$FLOW_RC"
assert_contains "live: SIGTERM is relayed to yap as SIGINT" "$(cat "$FLOW_DIR/yap.log")" "signal INT"
assert_not_contains "live: yap never receives SIGTERM directly" "$(cat "$FLOW_DIR/yap.log")" "signal TERM"
assert_eq "live: nothing left in TMPDIR after a run" "0" \
  "$(find "$FLOW_DIR/tmp" -mindepth 1 | wc -l | tr -d ' ')"

flow_run INT -- live
assert_eq "live: SIGINT to the script yields the transcript" \
  "$expected_transcript" "$FLOW_OUT"

# --- live: options and failures ------------------------------------------

flow_run TERM -- live --mic-label Doc --system-label Patient
assert_eq "live: custom speaker labels reach yap and the transcript" \
  "Doc: How have you been sleeping
Patient: Not great this week" "$FLOW_OUT"
assert_contains "live: labels are passed to yap as flags" \
  "$(cat "$FLOW_DIR/yap.log")" "--mic-label Doc --system-label Patient"

flow_run none STUB_YAP_MODE=permission -- live
assert_eq "live: a permission failure exits non-zero" "1" "$FLOW_RC"
assert_contains "live: yap's own error text is shown" "$FLOW_ERR" "yap: Error: Screen Recording permission"
assert_contains "live: says no audio was captured" "$FLOW_ERR" "no audio captured"
assert_eq "live: nothing on stdout when capture fails" "" "$FLOW_OUT"
assert_eq "live: nothing left in TMPDIR after a failed run" "0" \
  "$(find "$FLOW_DIR/tmp" -mindepth 1 | wc -l | tr -d ' ')"

flow_run TERM STUB_YAP_MODE=empty -- live
assert_contains "live: a session with no speech says so" "$FLOW_ERR" "no speech segments"

flow_run TERM STUB_YAP_MODE=nodata -- live
assert_contains "live: yap producing nothing is reported" "$FLOW_ERR" "no audio captured"

# --- note ----------------------------------------------------------------

FLOW_STDIN="$FLOW_DIR/transcript.txt"
printf 'Therapist: hi\nClient: hello\n' > "$FLOW_STDIN"

flow_run none -- note
assert_contains "note: prints the drafted note" "$FLOW_OUT" "SUBJECTIVE:"
assert_contains "note: prints the note body" "$FLOW_OUT" "Stub note"
assert_eq "note: exits 0" "0" "$FLOW_RC"
assert_eq "note: requests the default model" "llama3.1:8b" "$(jq -r .model "$FLOW_DIR/payload.json")"
assert_eq "note: asks for a non-streaming response" "false" "$(jq -r .stream "$FLOW_DIR/payload.json")"
assert_eq "note: sends the transcript after the prompt" "yes" \
  "$(jq -r '.prompt | contains("TRANSCRIPT:\nTherapist: hi\nClient: hello")' "$FLOW_DIR/payload.json" | sed 's/true/yes/; s/false/no/')"
assert_eq "note: starts with the SOAP prompt" "$(head -1 "$here/prompts/soap.md")" \
  "$(jq -r '.prompt | split("\n")[0]' "$FLOW_DIR/payload.json")"
assert_eq "note: sizes num_ctx to at least 4096" "yes" \
  "$([ "$(jq -r .options.num_ctx "$FLOW_DIR/payload.json")" -ge 4096 ] && echo yes || echo no)"

flow_run none -- note --format dap
assert_eq "note --format dap: uses the DAP prompt" "$(head -1 "$here/prompts/dap.md")" \
  "$(jq -r '.prompt | split("\n")[0]' "$FLOW_DIR/payload.json")"

flow_run none -- note --model other:1b
assert_contains "note: an unpulled model is reported" "$FLOW_ERR" "is not pulled"
assert_contains "note: an unpulled model's error says how to pull it" "$FLOW_ERR" "ollama pull other:1b"

flow_run none STUB_OLLAMA_MODEL=other:1b -- note --model other:1b
assert_contains "note: an untested model gets a warning" "$FLOW_ERR" "hasn't been tested"
assert_eq "note: an untested model still drafts" "0" "$FLOW_RC"

flow_run none -- note
assert_not_contains "note: the default model gets no untested warning" "$FLOW_ERR" "hasn't been tested"

# --- note --model bonsai -------------------------------------------------

flow_run none "${BONSAI_ENV[@]}" STUB_OLLAMA_MODE=down -- note --model bonsai
assert_contains "bonsai: prints the drafted note" "$FLOW_OUT" "Bonsai stub note"
assert_eq "bonsai: exits 0 even with Ollama down" "0" "$FLOW_RC"
assert_not_contains "bonsai: never asks Ollama for models" "$(cat "$FLOW_DIR/curl.log")" "/api/tags"
assert_not_contains "bonsai: no untested warning" "$FLOW_ERR" "hasn't been tested"
assert_contains "bonsai: server binds to localhost only" "$(cat "$FLOW_DIR/llama.log")" "--host 127.0.0.1"
assert_contains "bonsai: server loads the configured model" "$(cat "$FLOW_DIR/llama.log")" "-m $FLOW_DIR/bonsai.gguf"
assert_eq "bonsai: server is stopped after the note" "stopped" "$(tail -n 1 "$FLOW_DIR/llama.log")"
assert_eq "bonsai: no server left running" "0" "$FLOW_LLAMA_LEFT"
assert_eq "bonsai: thinking is turned off" "false" \
  "$(jq -r .chat_template_kwargs.enable_thinking "$FLOW_DIR/payload.json")"
assert_eq "bonsai: tested sampling settings" "0.7 0.8 20 2000" \
  "$(jq -r '"\(.temperature) \(.top_p) \(.top_k) \(.max_tokens)"' "$FLOW_DIR/payload.json")"
assert_eq "bonsai: sends the SOAP prompt and transcript as one user message" "yes" \
  "$(jq -r '.messages | length == 1 and .[0].role == "user" and (.[0].content | contains("TRANSCRIPT:\nTherapist: hi"))' "$FLOW_DIR/payload.json" | sed 's/true/yes/; s/false/no/')"

flow_run none SOAPCAP_BONSAI_SERVER=/nonexistent/llama-server -- note --model bonsai
assert_eq "bonsai: not set up exits non-zero" "1" "$FLOW_RC"
assert_contains "bonsai: not set up points to the installer" "$FLOW_ERR" "tools/bonsai/install.sh"

flow_run none "${BONSAI_ENV[@]}" STUB_LLAMA_BUSY=1 -- note --model bonsai
assert_contains "bonsai: a busy port is refused" "$FLOW_ERR" "already listening on port"
assert_eq "bonsai: a busy port never starts a server" "" "$(cat "$FLOW_DIR/llama.log")"

flow_run none "${BONSAI_ENV[@]}" STUB_LLAMA_MODE=crash -- note --model bonsai
assert_contains "bonsai: a failed load is reported" "$FLOW_ERR" "exited while loading"
assert_contains "bonsai: a failed load shows the server's own error" "$FLOW_ERR" "error loading model"

flow_run none "${BONSAI_ENV[@]}" STUB_BONSAI_REPLY=error -- note --model bonsai
assert_contains "bonsai: a server error message is surfaced" "$FLOW_ERR" "Bonsai error: boom"
assert_eq "bonsai: server stopped after an error" "0" "$FLOW_LLAMA_LEFT"

flow_run none "${BONSAI_ENV[@]}" STUB_BONSAI_REPLY=length -- note --model bonsai
assert_contains "bonsai: a truncated note is flagged" "$FLOW_ERR" "output limit"

t0=$SECONDS
FLOW_READY=llama flow_run TERM "${BONSAI_ENV[@]}" STUB_BONSAI_REPLY=hang -- note --model bonsai
assert_eq "bonsai: SIGTERM mid-note is acted on at once, not after the request" "yes" \
  "$([ $((SECONDS - t0)) -lt 5 ] && echo yes || echo no)"
assert_eq "bonsai: SIGTERM mid-note stops the server" "stopped" "$(tail -n 1 "$FLOW_DIR/llama.log")"
assert_eq "bonsai: SIGTERM mid-note leaves no server running" "0" "$FLOW_LLAMA_LEFT"
assert_eq "bonsai: SIGTERM mid-note leaves no temp files" "0" \
  "$(find "$FLOW_DIR/tmp" -mindepth 1 | wc -l | tr -d ' ')"

flow_run none -- note
assert_eq "note: the transcript never appears in curl's arguments" "no" \
  "$(grep -q 'TRANSCRIPT' "$FLOW_DIR/curl.args" && echo yes || echo no)"
assert_eq "note: nothing left in TMPDIR after a run" "0" \
  "$(find "$FLOW_DIR/tmp" -mindepth 1 | wc -l | tr -d ' ')"

flow_run none STUB_OLLAMA_MODE=down -- note
assert_contains "note: Ollama being down is reported" "$FLOW_ERR" "can't reach Ollama"
assert_eq "note: a down Ollama exits non-zero" "1" "$FLOW_RC"

flow_run none STUB_OLLAMA_MODE=error -- note
assert_contains "note: an Ollama error message is surfaced" "$FLOW_ERR" "Ollama error: boom"

flow_run none STUB_OLLAMA_MODE=empty -- note
assert_contains "note: an empty response is reported" "$FLOW_ERR" "no content"

: > "$FLOW_STDIN"
flow_run none -- note
assert_contains "note: an empty transcript is rejected" "$FLOW_ERR" "empty transcript"
FLOW_STDIN=""

# --- session (non-interactive) ------------------------------------------

flow_run TERM -- session --format soap
assert_contains "session: prints the transcript" "$FLOW_OUT" "Client: Not great this week"
assert_contains "session: prints the drafted note" "$FLOW_OUT" "Stub note"
assert_eq "session: exits 0" "0" "$FLOW_RC"
assert_not_contains "session: no alternate-screen codes when output isn't a terminal" \
  "$FLOW_OUT$FLOW_ERR" "$(printf '\033[?1049h')"

flow_run none STUB_YAP_MODE=permission -- session --no-note
assert_eq "session: a capture failure exits non-zero" "1" "$FLOW_RC"
assert_contains "session: a capture failure says so" "$FLOW_ERR" "no audio captured"

# --- misc ----------------------------------------------------------------

flow_run none -- version
assert_eq "version: prints 'soapcap X.Y.Z'" "yes" \
  "$(printf '%s' "$FLOW_OUT" | grep -Eq '^soapcap [0-9]+\.[0-9]+\.[0-9]+$' && echo yes || echo no)"

flow_run none -- bogus
assert_eq "unknown command exits 2" "2" "$FLOW_RC"

rm -rf "$FLOW_DIR"
