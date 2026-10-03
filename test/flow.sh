# shellcheck shell=bash
# shellcheck disable=SC2154  # $here comes from test/run.sh
# Flow tests: run the real bin/soapcap end to end against fake `yap`, `curl`
# and `pbcopy` (test/stubs/), so capture, stop-signal handling, note
# generation and `session` are exercised without audio hardware or Ollama --
# off a terminal (flow_run) and on one (flow_tty). Sourced by
# test/run.sh, which provides $here, the assert_* helpers and the pass/fail
# counters.
#
# Each run is hermetic: `env -i`, a throwaway HOME (no developer config), a
# throwaway TMPDIR, and a PATH holding only the stubs, jq, and /usr/bin:/bin
# (so real yap, ollama and gum are never reached).

FLOW_DIR=$(mktemp -d)
FLOW_BIN="$FLOW_DIR/bin"
mkdir -p "$FLOW_BIN" "$FLOW_DIR/home" "$FLOW_DIR/tmp"
cp "$here/test/stubs/yap" "$here/test/stubs/curl" "$here/test/stubs/llama-server" "$here/test/stubs/pbcopy" "$FLOW_BIN/"
ln -s "$(command -v jq)" "$FLOW_BIN/jq"
: > "$FLOW_DIR/bonsai.gguf"
BONSAI_ENV=(SOAPCAP_BONSAI_SERVER="$FLOW_BIN/llama-server" SOAPCAP_BONSAI_GGUF="$FLOW_DIR/bonsai.gguf")

# flow_run SIGNAL [VAR=VALUE ...] -- soapcap ARGS...
# SIGNAL "none" waits for soapcap to finish on its own. Otherwise, once the
# stub yap (or, with FLOW_READY=llama, the stub llama-server) is running,
# SIGNAL goes to the soapcap script's own pid only -- the way the window
# app stops it. Sets FLOW_OUT, FLOW_ERR, FLOW_RC; stdin comes from
# $FLOW_STDIN (default /dev/null).
# The environment every run gets: the stubs' log files and nothing of the
# developer's own.
FLOW_ENV=(PATH="$FLOW_BIN:/usr/bin:/bin" HOME="$FLOW_DIR/home" TMPDIR="$FLOW_DIR/tmp"
  STUB_YAP_LOG="$FLOW_DIR/yap.log" STUB_CURL_LOG="$FLOW_DIR/curl.log"
  STUB_CURL_PAYLOAD="$FLOW_DIR/payload.json" STUB_LLAMA_LOG="$FLOW_DIR/llama.log"
  STUB_CURL_ARGS="$FLOW_DIR/curl.args" STUB_CURL_PAYLOG="$FLOW_DIR/payloads.jsonl"
  STUB_STRUCT_COUNT="$FLOW_DIR/struct.count" STUB_CLIPBOARD="$FLOW_DIR/clipboard")

flow_reset() {
  : > "$FLOW_DIR/yap.log"; : > "$FLOW_DIR/curl.log"; : > "$FLOW_DIR/llama.log"; : > "$FLOW_DIR/curl.args"
  : > "$FLOW_DIR/payloads.jsonl"
  rm -f "$FLOW_DIR/payload.json" "$FLOW_DIR/first.json" "$FLOW_DIR/out" "$FLOW_DIR/err" \
    "$FLOW_DIR/struct.count" "$FLOW_DIR/clipboard"
}

# Reaps what a run left behind and reads its logs.
flow_finish() {
  pkill -f "$FLOW_BIN/yap" 2>/dev/null   # reap a stub left behind by a killed run
  sleep 0.2   # let a signalled stub llama-server log that it stopped
  FLOW_LLAMA_LEFT=$(pgrep -f "$FLOW_BIN/llama-server" | wc -l | tr -d ' ')
  pkill -f "$FLOW_BIN/llama-server" 2>/dev/null
  # The first request (payload.json holds only the last one): the note
  # itself, ahead of SOAP's Objective pass.
  head -n 1 "$FLOW_DIR/payloads.jsonl" > "$FLOW_DIR/first.json"
}

flow_run() {
  local sig="$1"; shift
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  flow_reset

  # A job started with & from a non-interactive shell begins with SIGINT
  # ignored (so it couldn't trap it); a terminal's Ctrl-C isn't. perl resets
  # SIGINT to its default and then exec()s soapcap, same pid throughout.
  # shellcheck disable=SC2016  # $SIG is a perl variable, not a shell one
  env -i "${FLOW_ENV[@]}" \
    ${envs[@]+"${envs[@]}"} \
    /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' "$here/bin/soapcap" "$@" \
    <"${FLOW_STDIN:-/dev/null}" >"$FLOW_DIR/out" 2>"$FLOW_DIR/err" &
  local pid=$!
  # (Detached from stdout: the sleep outlives the watchdog, and would hold a
  # pipe the suite's output goes down open until it ends.)
  ( sleep 20; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
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
  flow_finish
  FLOW_OUT=$(cat "$FLOW_DIR/out"); FLOW_ERR=$(cat "$FLOW_DIR/err")
}

# flow_tty [VAR=VALUE ...] -- soapcap ARGS... <<STEPS
# The same, on a pseudo-terminal (script(1)), so the paths that need a real
# terminal run: keypresses while recording, the pause, and session's prompts.
# STEPS, one per line, are "TEXT<tab>KEYS": once TEXT appears in what soapcap
# has printed since the last step, KEYS are typed (printf %b escapes: \n is
# Enter, \003 Ctrl-C). A step whose TEXT never appears is recorded in
# FLOW_STUCK and ends the run. FLOW_ROWS sets the terminal's height (default
# 60, tall enough that nothing is paged). Sets FLOW_OUT (everything the
# terminal showed, stdout and stderr together) and FLOW_RC; FLOW_ERR is
# empty.
flow_tty() {
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  flow_reset
  FLOW_STUCK=""; FLOW_ERR=""

  # soapcap's exit status goes to a file: util-linux's script reports 130
  # for any run it relayed a Ctrl-C to, whatever the command returned. The
  # wrapper has its own (empty) SIGINT handler so that Ctrl-C doesn't end it.
  rm -f "$FLOW_DIR/tty.rc"
  {
    echo '#!/usr/bin/env bash'
    echo 'trap : INT'
    echo "stty rows ${FLOW_ROWS:-60} cols 100"
    printf 'env -i TERM=xterm'
    printf ' %q' "${FLOW_ENV[@]}" ${envs[@]+"${envs[@]}"} "$here/bin/soapcap" "$@"
    echo
    printf 'echo $? > %q\n' "$FLOW_DIR/tty.rc"
  } > "$FLOW_DIR/tty.sh"
  chmod +x "$FLOW_DIR/tty.sh"
  : > "$FLOW_DIR/keys"

  # BSD script takes the command as arguments, util-linux's as -c STRING.
  # perl resets SIGINT as in flow_run, so a typed Ctrl-C reaches soapcap.
  # Keys reach script down a pipe from `tail -f` on a plain file: macOS's
  # script refuses a FIFO as its stdin.
  local cmd=(script -q /dev/null "$FLOW_DIR/tty.sh")
  if script --version 2>&1 | grep -q util-linux; then
    cmd=(script -qec "$FLOW_DIR/tty.sh" /dev/null)
  fi
  # shellcheck disable=SC2016  # $SIG is a perl variable, not a shell one
  tail -f "$FLOW_DIR/keys" 2>/dev/null \
    | /usr/bin/perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' "${cmd[@]}" >"$FLOW_DIR/out" 2>&1 &
  local pid=$!
  ( sleep 30; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  local watchdog=$!

  local text keys seen=0 i
  while IFS=$'\t' read -r text keys; do
    i=0
    until tail -c "+$((seen + 1))" "$FLOW_DIR/out" | LC_ALL=C grep -qF -- "$text"; do
      i=$((i + 1))
      if [ "$i" -gt 100 ] || ! kill -0 "$pid" 2>/dev/null; then
        FLOW_STUCK="$text"; break 2
      fi
      sleep 0.1
    done
    seen=$(wc -c < "$FLOW_DIR/out" | tr -d ' ')
    printf '%b' "$keys" >> "$FLOW_DIR/keys"
  done
  [ -n "$FLOW_STUCK" ] && kill -KILL "$pid" 2>/dev/null
  # `wait` would wait for the whole pipeline, and tail never ends by itself:
  # once script has gone, one more byte makes tail write to a closed pipe.
  while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  echo >> "$FLOW_DIR/keys"
  wait "$pid" 2>/dev/null
  FLOW_RC=$(cat "$FLOW_DIR/tty.rc" 2>/dev/null || echo killed)
  kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null
  flow_finish
  FLOW_OUT=$(LC_ALL=C tr -d '\r' < "$FLOW_DIR/out")
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

yesno() { sed 's/true/yes/; s/false/no/'; }
nreq() { grep -c "$1" "$FLOW_DIR/curl.log" | tr -d ' '; }   # requests to URL pattern

FLOW_STDIN="$FLOW_DIR/transcript.txt"
printf 'Therapist: hi\nClient: hello\n' > "$FLOW_STDIN"

flow_run none -- note
assert_contains "note: prints the drafted note" "$FLOW_OUT" "SUBJECTIVE:"
assert_contains "note: prints the note body" "$FLOW_OUT" "Stub note"
assert_eq "note: exits 0" "0" "$FLOW_RC"
assert_eq "note: requests the default model" "llama3.1:8b" "$(jq -r .model "$FLOW_DIR/first.json")"
assert_eq "note: asks for a streamed response (live token count)" "true" "$(jq -r .stream "$FLOW_DIR/first.json")"
assert_eq "note: sends the transcript after the prompt" "yes" \
  "$(jq -r '.prompt | contains("TRANSCRIPT:\nTherapist: hi\nClient: hello")' "$FLOW_DIR/first.json" | sed 's/true/yes/; s/false/no/')"
assert_eq "note: starts with the SOAP prompt" "$(head -1 "$here/prompts/soap.md")" \
  "$(jq -r '.prompt | split("\n")[0]' "$FLOW_DIR/first.json")"
assert_eq "note: sizes num_ctx to at least 4096" "yes" \
  "$([ "$(jq -r .options.num_ctx "$FLOW_DIR/first.json")" -ge 4096 ] && echo yes || echo no)"

assert_eq "note: unloads the Ollama model once the note is done" "unload llama3.1:8b" \
  "$(tail -n 1 "$FLOW_DIR/curl.log")"
assert_eq "note: ...only once, after both passes" "1" "$(grep -c '^unload' "$FLOW_DIR/curl.log" | tr -d ' ')"

flow_run none -- note --format dap
assert_eq "note --format dap: uses the DAP prompt" "$(head -1 "$here/prompts/dap.md")" \
  "$(jq -r '.prompt | split("\n")[0]' "$FLOW_DIR/payload.json")"
assert_eq "note --format dap: no Objective pass" "1" "$(wc -l < "$FLOW_DIR/payloads.jsonl" | tr -d ' ')"
assert_not_contains "note --format dap: no mental-status frame" "$FLOW_OUT" "On time via video"

# --- note: SOAP's Objective pass -----------------------------------------

objective="OBJECTIVE:
On time via video. Stub engaged. Affect stub affect; mood stub mood. Speech stub speech. Thought process stub thought. Insight stub insight; judgment stub judgment. Stub psychomotor."

flow_run none -- note
assert_eq "objective: SOAP is two requests, the note first" "no yes" \
  "$(jq -r 'has("format")' "$FLOW_DIR/payloads.jsonl" | yesno | tr '\n' ' ' | sed 's/ $//')"
assert_eq "objective: the second request asks for the mental-status fields" "mental_status risk risk_kind" \
  "$(jq -r '.format.required | join(" ")' "$FLOW_DIR/payload.json")"
assert_eq "objective: its prompt is the Objective prompt" "$(head -1 "$here/prompts/objective.md")" \
  "$(jq -r '.prompt | split("\n")[0]' "$FLOW_DIR/payload.json")"
assert_eq "objective: its prompt carries the transcript" "yes" \
  "$(jq -r '.prompt | contains("TRANSCRIPT:\nTherapist: hi\nClient: hello")' "$FLOW_DIR/payload.json" | yesno)"
assert_contains "objective: the frame is filled in from the pass" "$FLOW_OUT" "$objective No SI/HI reported.

ASSESSMENT:"
assert_not_contains "objective: the narrative's own Objective is replaced" "$FLOW_OUT" "No observable presentation"
assert_eq "objective: no session line without --duration" "SUBJECTIVE:" "$(printf '%s\n' "$FLOW_OUT" | head -n 1)"

flow_run none STUB_OBJ_RISK=disclosed -- note
assert_contains "objective: a disclosed risk replaces the SI/HI line" "$FLOW_OUT" "$objective HI reported; see Assessment and Plan."
assert_not_contains "objective: ...and \"No SI/HI reported\" never appears" "$FLOW_OUT" "No SI/HI reported"

flow_run none STUB_OBJ_RISK=screened_negative -- note
assert_contains "objective: a negative screen reads \"No SI/HI reported\"" "$FLOW_OUT" "No SI/HI reported."

flow_run none STUB_OBJ_MODE=invalid -- note
assert_eq "objective: a failed pass still delivers the note" "0" "$FLOW_RC"
assert_contains "objective: ...says the Objective needs completing" "$FLOW_OUT" "[Objective could not be drafted; complete manually.]"
assert_not_contains "objective: ...and never claims no SI/HI" "$FLOW_OUT" "No SI/HI reported"
assert_contains "objective: ...and warns on stderr" "$FLOW_ERR" "the Objective pass failed"

printf 'Therapist: just me talking\n' > "$FLOW_DIR/mic-only.txt"
FLOW_STDIN="$FLOW_DIR/mic-only.txt" flow_run none -- note
assert_eq "objective: no client lines, no Objective pass" "1" "$(nreq /api/generate)"
assert_contains "objective: ...Objective is left to the clinician" "$FLOW_OUT" \
  "[No client speech was captured; complete the Objective manually.]"
assert_not_contains "objective: ...with no SI/HI claim" "$FLOW_OUT" "No SI/HI reported"
assert_contains "objective: ...and says why" "$FLOW_ERR" "no Client lines in the transcript"

flow_run none -- note --duration 63
assert_eq "duration: --duration puts the session line first" "63 minutes, telehealth" \
  "$(printf '%s\n' "$FLOW_OUT" | head -n 1)"
assert_eq "duration: then a blank line, then the note" "
SUBJECTIVE:" "$(printf '%s\n' "$FLOW_OUT" | sed -n '2,3p')"

flow_run none SOAPCAP_SESSION_TYPE="in person" -- note --duration 1
assert_eq "duration: one minute, and the session type is configurable" "1 minute, in person" \
  "$(printf '%s\n' "$FLOW_OUT" | head -n 1)"

flow_run none -- note --duration 1h
assert_eq "duration: anything but whole minutes is refused" "1" "$FLOW_RC"
assert_eq "duration: ...before any request" "" "$(cat "$FLOW_DIR/curl.log")"

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
  "$(jq -r .chat_template_kwargs.enable_thinking "$FLOW_DIR/first.json")"
assert_eq "bonsai: tested sampling settings" "0.7 0.8 20 2000" \
  "$(jq -r '"\(.temperature) \(.top_p) \(.top_k) \(.max_tokens)"' "$FLOW_DIR/first.json")"
assert_eq "bonsai: sends the SOAP prompt and transcript as one user message" "yes" \
  "$(jq -r '.messages | length == 1 and .[0].role == "user" and (.[0].content | contains("TRANSCRIPT:\nTherapist: hi"))' "$FLOW_DIR/first.json" | sed 's/true/yes/; s/false/no/')"
assert_eq "bonsai: one server start for the note and its Objective" "1" \
  "$(grep -c '^started' "$FLOW_DIR/llama.log" | tr -d ' ')"
assert_contains "bonsai: the Objective pass is filled in" "$FLOW_OUT" "On time via video. Stub engaged."

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
assert_eq "note: a failed draft still unloads the model" "unload llama3.1:8b" "$(tail -n 1 "$FLOW_DIR/curl.log")"

flow_run none STUB_OLLAMA_MODE=empty -- note
assert_contains "note: an empty response is reported" "$FLOW_ERR" "no content"

# --- note --style --------------------------------------------------------

soap_fields="subjective assessment risk safety_plan interventions_used plan_items"

flow_run none -- note
assert_eq "style: the narrative request carries no schema" "no" \
  "$(jq -r 'has("format") or has("response_format")' "$FLOW_DIR/first.json" | yesno)"
assert_eq "style: narrative SOAP is the note plus its Objective" "2" "$(nreq /api/generate)"

flow_run none -- note --format birp
assert_eq "style: narrative BIRP is a single request" "1" "$(nreq /api/generate)"

flow_run none -- note --style bogus
assert_eq "style: an unknown style exits non-zero" "1" "$FLOW_RC"
assert_contains "style: an unknown style is named" "$FLOW_ERR" "unknown style 'bogus'"
assert_eq "style: an unknown style sends no request" "" "$(cat "$FLOW_DIR/curl.log")"

flow_run none SOAPCAP_STYLE=bogus -- note
assert_eq "style: an unknown SOAPCAP_STYLE exits non-zero" "1" "$FLOW_RC"

flow_run none -- note --style structured
assert_eq "structured: exits 0" "0" "$FLOW_RC"
assert_contains "structured: Subjective comes from the JSON" "$FLOW_OUT" "SUBJECTIVE:
Stub structured subjective."
assert_contains "structured: SOAP's Objective comes from its own pass" "$FLOW_OUT" "OBJECTIVE:
On time via video. Stub engaged."
assert_contains "structured: risk is added to Assessment" "$FLOW_OUT" \
  "Stub structured assessment. Stub risk summary."
assert_contains "structured: interventions open Plan" "$FLOW_OUT" \
  "PLAN:
In session, the therapist reviewed a stub exercise."
assert_contains "structured: the safety plan is composed into Plan" "$FLOW_OUT" \
  "The safety plan identified warning signs: a stub sign; and emergency steps: calling 988."
assert_contains "structured: next steps are composed into Plan" "$FLOW_OUT" \
  "The client agreed to do a stub task."
assert_not_contains "structured: no JSON reaches the note" "$FLOW_OUT" "{"
assert_contains "structured: the review goes to stderr" "$FLOW_ERR" "review: nothing flagged"
assert_not_contains "structured: the review stays out of the note" "$FLOW_OUT" "nothing flagged"
assert_eq "structured: sends Ollama a schema" "object" "$(jq -r .format.type "$FLOW_DIR/first.json")"
assert_eq "structured: the SOAP schema's fields, in note order" "$soap_fields" \
  "$(jq -r '.format.required | join(" ")' "$FLOW_DIR/first.json")"
assert_eq "structured: tested sampling, and an output cap" "0.3 0.8 20 3000" \
  "$(jq -r '.options | "\(.temperature) \(.top_p) \(.top_k) \(.num_predict)"' "$FLOW_DIR/first.json")"
assert_eq "structured: the context fits the prompt plus the output cap" "yes" \
  "$(jq -r '.options.num_ctx - .options.num_predict >= (.prompt | split(" ") | length)' "$FLOW_DIR/first.json" | yesno)"
assert_eq "structured: the transcript goes with numbered lines" "yes" \
  "$(jq -r '.prompt | contains("TRANSCRIPT:\n1 | Therapist: hi\n2 | Client: hello")' "$FLOW_DIR/first.json" | yesno)"
assert_eq "structured: the prompt names the format" "yes" \
  "$(jq -r '.prompt | split("\n")[0] | endswith("drafting a clinical SOAP")' "$FLOW_DIR/first.json" | yesno)"

flow_run none -- note --style structured --format dap
assert_contains "structured dap: Data holds reported content and observations" "$FLOW_OUT" \
  "DATA:
Stub structured subjective. Stub observation."
assert_eq "structured dap: the prompt names the format" "yes" \
  "$(jq -r '.prompt | split("\n")[0] | endswith("drafting a clinical DAP")' "$FLOW_DIR/payload.json" | yesno)"

flow_run none -- note --style structured --format birp
assert_contains "structured birp: interventions get their own section" "$FLOW_OUT" \
  "INTERVENTION:
In session, the therapist reviewed a stub exercise."
assert_contains "structured birp: risk is added to Response" "$FLOW_OUT" \
  "RESPONSE:
Stub structured response. Stub risk summary."
assert_eq "structured birp: the BIRP schema's fields, in note order" \
  "subjective objective_observations interventions_used response risk safety_plan plan_items" \
  "$(jq -r '.format.required | join(" ")' "$FLOW_DIR/payload.json")"

flow_run none STUB_STRUCT_MODE=invalid_once -- note --style structured --format dap
assert_eq "structured: one malformed response is retried" "0" "$FLOW_RC"
assert_contains "structured: the retry is announced" "$FLOW_ERR" "retrying once"
assert_eq "structured: the retry is a second request" "2" "$(nreq /api/generate)"

flow_run none STUB_STRUCT_MODE=invalid -- note --style structured
assert_eq "structured: two malformed responses fail" "1" "$FLOW_RC"
assert_contains "structured: says why it failed" "$FLOW_ERR" "incomplete twice"
assert_eq "structured: never more than two attempts" "2" "$(nreq /api/generate)"

flow_run none STUB_STRUCT_MODE=length -- note --style structured
assert_eq "structured: a response cut off at the cap is not accepted" "1" "$FLOW_RC"

flow_run none "${BONSAI_ENV[@]}" STUB_OLLAMA_MODE=down -- note --model bonsai --style structured
assert_eq "structured bonsai: exits 0" "0" "$FLOW_RC"
assert_contains "structured bonsai: renders the note" "$FLOW_OUT" "Stub structured subjective."
assert_eq "structured bonsai: sends a JSON schema" "json_schema" \
  "$(jq -r .response_format.type "$FLOW_DIR/payload.json")"
assert_eq "structured bonsai: tested sampling, and an output cap" "0.3 0.8 20 3000" \
  "$(jq -r '"\(.temperature) \(.top_p) \(.top_k) \(.max_tokens)"' "$FLOW_DIR/first.json")"
assert_eq "structured bonsai: the Objective pass has a smaller cap" "600" \
  "$(jq -r .max_tokens "$FLOW_DIR/payload.json")"
assert_eq "structured bonsai: the Objective fields are length-capped" "100" \
  "$(jq -r .response_format.json_schema.schema.properties.mental_status.properties.affect.maxLength "$FLOW_DIR/payload.json")"
assert_eq "structured bonsai: thinking is turned off" "false" \
  "$(jq -r .chat_template_kwargs.enable_thinking "$FLOW_DIR/first.json")"
assert_eq "structured bonsai: server is stopped after the note" "stopped" "$(tail -n 1 "$FLOW_DIR/llama.log")"
assert_eq "structured bonsai: no server left running" "0" "$FLOW_LLAMA_LEFT"

flow_run none -- note --style combined
assert_eq "combined: exits 0" "0" "$FLOW_RC"
assert_contains "combined: prints the narrative note" "$FLOW_OUT" "Stub note"
assert_not_contains "combined: the structured draft isn't the note" "$FLOW_OUT" "Stub structured"
assert_eq "combined: three requests for SOAP" "3" "$(wc -l < "$FLOW_DIR/payloads.jsonl" | tr -d ' ')"
assert_eq "combined: the narrative note, the check, then the Objective" "no yes yes" \
  "$(jq -r 'has("format")' "$FLOW_DIR/payloads.jsonl" | yesno | tr '\n' ' ' | sed 's/ $//')"
assert_eq "combined: the check is the full structured pass" "$soap_fields" \
  "$(sed -n 2p "$FLOW_DIR/payloads.jsonl" | jq -r '.format.required | join(" ")')"
assert_contains "combined: shows a review" "$FLOW_ERR" "review before submitting"
assert_contains "combined: flags undocumented risk" "$FLOW_ERR" \
  "A safety risk came up in the session, but the note doesn't mention it"
assert_contains "combined: lists next steps with their lines" "$FLOW_ERR" "line 2: do a stub task"
assert_not_contains "combined: the review stays out of the note" "$FLOW_OUT" "review before submitting"

flow_run none -- note --style combined --out "$FLOW_DIR/note.out"
assert_not_contains "combined: the review stays out of --out" "$(cat "$FLOW_DIR/note.out")" "review before submitting"
rm -f "$FLOW_DIR/note.out"

flow_run none STUB_STRUCT_MODE=invalid -- note --style combined
assert_eq "combined: a failed review pass still delivers the note" "0" "$FLOW_RC"
assert_contains "combined: ...with the note intact" "$FLOW_OUT" "Stub note"
assert_contains "combined: ...and says it wasn't checked" "$FLOW_ERR" "review pass failed"

flow_run none "${BONSAI_ENV[@]}" STUB_OLLAMA_MODE=down -- note --model bonsai --style combined
assert_eq "combined bonsai: exits 0" "0" "$FLOW_RC"
assert_contains "combined bonsai: prints the narrative note" "$FLOW_OUT" "Bonsai stub note"
assert_eq "combined bonsai: one server start for both passes" "1" "$(grep -c '^started' "$FLOW_DIR/llama.log" | tr -d ' ')"
assert_eq "combined bonsai: three requests to it" "3" "$(nreq /v1/chat/completions)"
assert_eq "combined bonsai: the narrative pass keeps its tested settings" "0.7 2000 false" \
  "$(head -1 "$FLOW_DIR/payloads.jsonl" | jq -r '"\(.temperature) \(.max_tokens) \(has("response_format"))"')"
assert_eq "combined bonsai: server is stopped after both passes" "stopped" "$(tail -n 1 "$FLOW_DIR/llama.log")"
assert_eq "combined bonsai: no server left running" "0" "$FLOW_LLAMA_LEFT"

flow_run none -- session --style bogus --format soap
assert_eq "session: an unknown style exits non-zero" "1" "$FLOW_RC"
assert_eq "session: an unknown style is caught before capture starts" "" "$(cat "$FLOW_DIR/yap.log")"

: > "$FLOW_STDIN"
flow_run none -- note
assert_contains "note: an empty transcript is rejected" "$FLOW_ERR" "empty transcript"
FLOW_STDIN=""

# --- session (non-interactive) ------------------------------------------

flow_run TERM -- session --format soap
assert_contains "session: prints the transcript" "$FLOW_OUT" "Client: Not great this week"
assert_contains "session: prints the drafted note" "$FLOW_OUT" "Stub note"
assert_contains "session: the note opens with recording time and session type" "$FLOW_OUT" "under 1 minute, telehealth

SUBJECTIVE:"
assert_eq "session: exits 0" "0" "$FLOW_RC"
assert_not_contains "session: no alternate-screen codes when output isn't a terminal" \
  "$FLOW_OUT$FLOW_ERR" "$(printf '\033[?1049h')"

flow_run none STUB_YAP_MODE=permission -- session --no-note
assert_eq "session: a capture failure exits non-zero" "1" "$FLOW_RC"
assert_contains "session: a capture failure says so" "$FLOW_ERR" "no audio captured"

# --- transcribe, deidentify (end to end) ----------------------------------

: > "$FLOW_DIR/call.m4a"
flow_run none -- transcribe "$FLOW_DIR/call.m4a" --locale en-GB
assert_eq "transcribe: prints the recording's transcript" "Speaker: A recorded line" "$FLOW_OUT"
assert_contains "transcribe: the file and locale reach yap" "$(cat "$FLOW_DIR/yap.log")" \
  "transcribe $FLOW_DIR/call.m4a --json --locale en-GB"

# Stand-ins for the de-identify helper: one upper-cases what it is given (so
# anything it was sent is recognizable), one fails.
printf '#!/usr/bin/env bash\ntr "[:lower:]" "[:upper:]"\necho "redacted 2 span(s)" >&2\n' > "$FLOW_BIN/deid-ok"
printf '#!/usr/bin/env bash\ncat\necho "boom" >&2\nexit 1\n' > "$FLOW_BIN/deid-fail"
chmod +x "$FLOW_BIN/deid-ok" "$FLOW_BIN/deid-fail"
FLOW_STDIN="$FLOW_DIR/transcript.txt"
printf 'Therapist: hi\nClient: hello\n' > "$FLOW_STDIN"

flow_run none SOAPCAP_DEIDENTIFY_BIN="$FLOW_BIN/deid-ok" -- deidentify
assert_eq "deidentify: redacts what was said, never the speaker labels" "Therapist: HI
Client: HELLO" "$FLOW_OUT"
flow_run none SOAPCAP_DEIDENTIFY_BIN="$FLOW_BIN/deid-fail" -- deidentify
assert_eq "deidentify: a failed helper exits non-zero" "1" "$FLOW_RC"
assert_eq "deidentify: ...and prints nothing, not even what the helper wrote" "" "$FLOW_OUT"

# --- one context size per note, an output cap, the host check -------------

awk 'BEGIN { for (i = 0; i < 150; i++) print "Client: one two three four five six seven eight nine ten eleven twelve" }' > "$FLOW_DIR/long.txt"
FLOW_STDIN="$FLOW_DIR/long.txt" flow_run none -- note --style combined
assert_eq "context: all three passes of a note ask for the same num_ctx (no reload between them)" "1" \
  "$(jq -r '.options.num_ctx' "$FLOW_DIR/payloads.jsonl" | sort -u | wc -l | tr -d ' ')"
assert_eq "context: ...big enough for the largest pass and its output cap" "yes" \
  "$(jq -s -r '[.[] | (.prompt | split(" ") | length) + .options.num_predict <= .options.num_ctx] | all' "$FLOW_DIR/payloads.jsonl" | yesno)"
assert_eq "note: the narrative pass has an output cap" "2000" "$(jq -r '.options.num_predict' "$FLOW_DIR/first.json")"

flow_run none -- note --host http://10.0.0.5:11434
assert_contains "host: a host that isn't this Mac gets a warning" "$FLOW_ERR" "http://10.0.0.5:11434 is not this Mac"
assert_eq "host: ...once, not once per pass" "1" "$(printf '%s\n' "$FLOW_ERR" | grep -c 'is not this Mac')"
flow_run none -- note --host http://127.0.0.1:11434
assert_not_contains "host: a loopback host gets none" "$FLOW_ERR" "is not this Mac"

# --- config ---------------------------------------------------------------

printf 'SOAPCAP_FORMAT=""\nSOAPCAP_MODEL=""\n' > "$FLOW_DIR/blank.sh"
flow_run none SOAPCAP_CONFIG="$FLOW_DIR/blank.sh" -- note
assert_eq "config: a blank entry means the default (SOAP, llama3.1:8b)" "$(head -1 "$here/prompts/soap.md") llama3.1:8b" \
  "$(jq -r '(.prompt | split("\n")[0]) + " " + .model' "$FLOW_DIR/first.json")"

SOAPCAP_CONFIG="$FLOW_DIR/model.sh"
sc_save_model_config bonsai
assert_eq "model config: created when there is no config yet" 'SOAPCAP_MODEL="bonsai"' "$(cat "$SOAPCAP_CONFIG")"
printf '# mine\nSOAPCAP_MODEL="old"\nSOAPCAP_LOCALE="en-US"\n' > "$SOAPCAP_CONFIG"
sc_save_model_config llama3.1:8b
assert_eq "model config: an existing entry is replaced where it stands" '# mine
SOAPCAP_MODEL="llama3.1:8b"
SOAPCAP_LOCALE="en-US"' "$(cat "$SOAPCAP_CONFIG")"
unset SOAPCAP_CONFIG

# --- session: settled before the recording starts -------------------------

FLOW_STDIN=""

flow_run none -- session --format bogus
assert_contains "session: an unknown format is named" "$FLOW_ERR" "unknown format 'bogus'"
assert_eq "session: ...before capture starts" "" "$(cat "$FLOW_DIR/yap.log")"

flow_run TERM STUB_OLLAMA_MODE=down -- session --format soap
assert_contains "session: a model that can't draft is reported before recording" \
  "$(printf '%s\n' "$FLOW_ERR" | sed '/recording\|Transcript:/q')" "can't reach Ollama"
assert_contains "session: ...and the recording still happens" "$FLOW_OUT" "Client: Not great this week"

flow_run TERM SOAPCAP_DEIDENTIFY_BIN="$FLOW_BIN/deid-ok" SOAPCAP_SESSION_DEIDENTIFY=yes -- session --format soap
assert_contains "session: config can answer the de-identify question (transcript redacted)" "$FLOW_OUT" "Client: NOT GREAT THIS WEEK"
assert_contains "session: ...and the note is redacted too" "$FLOW_OUT" "STUB NOTE"
assert_eq "session: ...but nothing is saved without a yes" "0" \
  "$(find "$FLOW_DIR/home" -name '*.transcript' | wc -l | tr -d ' ')"

# --- on a terminal: keypresses, pause, session's prompts ------------------
# (flow_tty: the paths that only run when stdin is a real terminal.)

tab=$'\t'
both_legs="Therapist: How have you been sleeping
Client: Not great this week
Therapist: How have you been sleeping
Client: Not great this week"

flow_tty -- live <<STEPS
recording${tab}p
paused${tab}p
recording${tab}q
STEPS
assert_eq "tty: every step's prompt appeared" "" "$FLOW_STUCK"
assert_contains "pause: both legs are in the transcript, in order" "$FLOW_OUT" "$both_legs"

flow_tty -- live <<STEPS
recording${tab}p
paused${tab}\003
STEPS
assert_contains "pause: Ctrl-C while paused stops, and still delivers the transcript" "$FLOW_OUT" "$expected_transcript"
assert_eq "pause: ...exiting 0" "0" "$FLOW_RC"
assert_eq "pause: ...with nothing left in TMPDIR" "0" \
  "$(find "$FLOW_DIR/tmp" -mindepth 1 | wc -l | tr -d ' ')"

# Enter at every prompt: show the transcript, draft in the configured
# format, copy the draft.
flow_tty SOAPCAP_FORMAT=dap -- session <<STEPS
recording${tab}q
Show the transcript?${tab}\n
Draft a note?${tab}\n
This draft:${tab}\n
Press Enter${tab}\n
STEPS
assert_eq "session: every prompt appeared, in order" "" "$FLOW_STUCK"
assert_eq "session: Enter drafts in the configured format, not always SOAP" "$(head -1 "$here/prompts/dap.md")" \
  "$(jq -r '.prompt | split("\n")[0]' "$FLOW_DIR/first.json")"
assert_contains "session: Enter at the draft copies the note to the clipboard" "$(cat "$FLOW_DIR/clipboard")" "under 1 minute, telehealth

SUBJECTIVE:
Stub note"
assert_contains "session: says it was copied, once, with the paste hint" "$FLOW_OUT" "Copied — Cmd-V to paste"
assert_not_contains "session: ...not twice" "$FLOW_OUT" "(copied to clipboard)"
assert_not_contains "session: no model question up front" "$FLOW_OUT" "Model for the note?"

flow_tty "${BONSAI_ENV[@]}" -- session <<STEPS
recording${tab}q
Show the transcript?${tab}n\n
Draft a note?${tab}b\n
This draft:${tab}r\n
This draft:${tab}t\n
This draft:${tab}c\n
Press Enter${tab}\n
STEPS
assert_eq "session: regenerate, then another model: every prompt appeared" "" "$FLOW_STUCK"
assert_not_contains "session: a declined transcript isn't shown" "$FLOW_OUT" "----- transcript -----"
assert_eq "session: regenerate drafts again with the model still loaded (unloaded only after draft 2)" "2" \
  "$(awk '/api\/generate/ { drafts++ } /^unload/ { print drafts; exit }' "$FLOW_DIR/curl.log")"
assert_contains "session: the other installed model is offered by name" "$FLOW_OUT" "[t]ry bonsai"
assert_eq "session: switching unloads the first model before the second drafts" "unload llama3.1:8b" \
  "$(grep -B1 -m1 '/health' "$FLOW_DIR/curl.log" | head -n 1)"
assert_contains "session: the kept draft is the second model's" "$(cat "$FLOW_DIR/clipboard")" "Bonsai stub note"
assert_eq "session: ...whose server is stopped at the end" "stopped 0" "$(tail -n 1 "$FLOW_DIR/llama.log") $FLOW_LLAMA_LEFT"

flow_tty STUB_OLLAMA_MODE=error -- session <<STEPS
recording${tab}q
Show the transcript?${tab}n\n
Draft a note?${tab}\n
No note was drafted:${tab}c\n
Press Enter${tab}\n
STEPS
assert_eq "session: a failed draft offers a way out" "" "$FLOW_STUCK"
assert_eq "session: ...copying the transcript, so the session isn't lost" "$expected_transcript" "$(cat "$FLOW_DIR/clipboard")"

flow_tty STUB_OLLAMA_MODE=down -- session <<STEPS
Start recording anyway?${tab}n\n
Press Enter${tab}\n
STEPS
assert_contains "session: a model that can't draft is flagged before recording" "$FLOW_OUT" "can't reach Ollama"
assert_eq "session: ...and declining never starts the recording" "" "$(cat "$FLOW_DIR/yap.log")"

if command -v less >/dev/null 2>&1; then
  FLOW_ROWS=12 flow_tty -- session --format soap <<STEPS
recording${tab}q
Show the transcript?${tab}n\n
q to continue${tab}q
This draft:${tab}d\n
Press Enter${tab}\n
STEPS
  assert_eq "session: a note taller than the window is paged, not scrolled away" "" "$FLOW_STUCK"
  assert_eq "session: ...on the same full screen (it is left once, at the end)" "1" \
    "$(printf '%s' "$FLOW_OUT" | grep -o "$(printf '\033')\[?1049l" | wc -l | tr -d ' ')"
  assert_eq "session: discard copies nothing" "no" "$([ -e "$FLOW_DIR/clipboard" ] && echo yes || echo no)"
else
  echo "skip session: paging (less isn't installed)"
fi

# --- misc ----------------------------------------------------------------

flow_run none -- version
assert_eq "version: prints 'soapcap X.Y.Z'" "yes" \
  "$(printf '%s' "$FLOW_OUT" | grep -Eq '^soapcap [0-9]+\.[0-9]+\.[0-9]+$' && echo yes || echo no)"

flow_run none -- bogus
assert_eq "unknown command exits 2" "2" "$FLOW_RC"

rm -rf "$FLOW_DIR"
