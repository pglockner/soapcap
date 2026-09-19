#!/usr/bin/env bash
# Fixture tests for soapcap: pure text-transformation logic (dedupe, run
# merging, note safety nets, de-identify plumbing), then flow tests
# (test/flow.sh) that run the real bin/soapcap against fake yap and curl
# (test/stubs/). Not covered: real audio, macOS permissions, the Ollama models
# themselves, doctor, and the window app.
#
# Run with: test/run.sh
# Exits non-zero if anything fails, so it's usable from CI.
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
# shellcheck source=lib/transcript.sh
. "$here/lib/transcript.sh"
# shellcheck source=lib/commands.sh
. "$here/lib/commands.sh"

pass=0
fail=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n' "$desc"
    printf '  expected: %q\n' "$expected"
    printf '  actual:   %q\n' "$actual"
  fi
}

# --- sc_render_transcript: dedupe --------------------------------------

# Real echo: mic (Therapist) hears the tail end of what system audio
# (Client) just said, close in time -- the classic no-headphones leak.
result=$(jq -n '{segments: [
  {speaker:"Client", start:0,   end:2, id:1, text:"How was your week going overall"},
  {speaker:"Therapist", start:2.5, end:3, id:2, text:"going overall"}
]}' | sc_render_transcript Therapist Client 1)
assert_eq "dedupe: drops a mic-side echo of a system-side utterance" \
  "Client: How was your week going overall" "$result"

# Overlapping in time but genuinely different content -- not an echo.
result=$(jq -n '{segments: [
  {speaker:"Client", start:0, end:2, id:1, text:"How was your week"},
  {speaker:"Therapist", start:1, end:2, id:2, text:"I have been stressed"}
]}' | sc_render_transcript Therapist Client 1)
assert_eq "dedupe: keeps overlapping-time but different-content segments" \
  "Client: How was your week
Therapist: I have been stressed" "$result"

# Same wording, but far outside the dedupe window -- coincidence, not an echo.
result=$(jq -n '{segments: [
  {speaker:"Client", start:0,  end:2,  id:1, text:"going overall"},
  {speaker:"Therapist", start:60, end:61, id:2, text:"going overall"}
]}' | sc_render_transcript Therapist Client 1)
assert_eq "dedupe: keeps same-content segments far apart in time" \
  "Client: going overall
Therapist: going overall" "$result"

# Short backchannel below minwords -- never auto-dropped even if it matches.
result=$(jq -n '{segments: [
  {speaker:"Client", start:0,   end:1, id:1, text:"Okay"},
  {speaker:"Therapist", start:0.5, end:1, id:2, text:"Okay"}
]}' | sc_render_transcript Therapist Client 1)
assert_eq "dedupe: never drops a short backchannel below minwords" \
  "Client: Okay
Therapist: Okay" "$result"

# --no-dedupe reproduces the raw, undeduplicated output.
result=$(jq -n '{segments: [
  {speaker:"Client", start:0,   end:2, id:1, text:"How was your week going overall"},
  {speaker:"Therapist", start:2.5, end:3, id:2, text:"going overall"}
]}' | sc_render_transcript Therapist Client 0)
assert_eq "dedupe: --no-dedupe keeps everything" \
  "Client: How was your week going overall
Therapist: going overall" "$result"

# Consecutive same-speaker segments merge into one line.
result=$(jq -n '{segments: [
  {speaker:"Client", start:0, end:1, id:1, text:"First part."},
  {speaker:"Client", start:1, end:2, id:2, text:"Second part."}
]}' | sc_render_transcript "" "" 0)
assert_eq "render: merges consecutive same-speaker segments" \
  "Client: First part. Second part." "$result"

# --- sc_merge_runs: pause/resume ordering -------------------------------

run1=$(mktemp) run2=$(mktemp)
printf '{"segments":[{"speaker":"Client","start":0,"end":1,"id":1,"text":"First run."}]}' > "$run1"
printf '{"segments":[{"speaker":"Client","start":0,"end":1,"id":1,"text":"Second run."}]}' > "$run2"
result=$(sc_merge_runs "$run1" "$run2" | sc_render_transcript "" "" 0)
assert_eq "merge_runs: second run's segments sort after the first run's" \
  "Client: First run. Second run." "$result"
rm -f "$run1" "$run2"

# An empty leg (paused almost immediately) merges cleanly with no error.
run1=$(mktemp) run2=$(mktemp)
printf '{"segments":[]}' > "$run1"
printf '{"segments":[{"speaker":"Client","start":0,"end":1,"id":1,"text":"Only real content."}]}' > "$run2"
result=$(sc_merge_runs "$run1" "$run2" | sc_render_transcript "" "" 0)
assert_eq "merge_runs: tolerates an empty leg" \
  "Client: Only real content." "$result"
rm -f "$run1" "$run2"

# --- sc_generate_note safety nets ---------------------------------------

result=$(printf 'SUBJECTIVE:\nSome content.\n\nTRANSCRIPT:\nClient: this should never appear\n' | sc_strip_transcript_echo)
assert_eq "strip_transcript_echo: truncates at a re-echoed TRANSCRIPT: marker" \
  "SUBJECTIVE:
Some content." "$result"

result=$(printf 'SUBJECTIVE:\nNormal note, no echo.\n' | sc_strip_transcript_echo)
assert_eq "strip_transcript_echo: leaves a normal note untouched" \
  "SUBJECTIVE:
Normal note, no echo." "$result"

result=$(printf 'The client appeared to be tearing up during the session. No observable presentation details available from a text-only transcript.\n' | sc_strip_contaminated_fallback)
assert_eq "strip_contaminated_fallback: strips the fallback when appended to a real observation" \
  "The client appeared to be tearing up during the session." "$result"

result=$(printf 'No observable presentation details available from a text-only transcript.\n' | sc_strip_contaminated_fallback)
assert_eq "strip_contaminated_fallback: leaves the fallback alone on its own" \
  "No observable presentation details available from a text-only transcript." "$result"

result=$(printf 'PLAN:\nContinue weekly sessions.\n\nNote: this appears to be a test recording, not a real session.\n' | sc_strip_trailing_disclaimer)
assert_eq "strip_trailing_disclaimer: strips a trailing disclaimer-style paragraph" \
  "PLAN:
Continue weekly sessions." "$result"

result=$(printf 'PLAN:\nContinue weekly sessions.\n\nHomework: practice the breathing exercise daily.\n' | sc_strip_trailing_disclaimer)
assert_eq "strip_trailing_disclaimer: leaves a legitimate second Plan paragraph untouched" \
  "PLAN:
Continue weekly sessions.

Homework: practice the breathing exercise daily." "$result"

# --- sc_deidentify_transcript --------------------------------------------
#
# These test the bash plumbing around tools/deidentify-helper (label
# strip/reattach, exit-code handling, fail-closed behavior) using stub
# scripts standing in for the real Swift binary -- the same technique
# used to stub sc_capture_session elsewhere. OpenMedKit's actual
# detection accuracy (does it correctly tag a name/phone/address in real
# English dialogue) is NOT something this harness can or should test --
# see ~/.config/soapcap/sample-transcripts/ for that manual acceptance
# pass, run by hand against the documented PII inventory per file.

SOAPCAP_DEIDENTIFY_BIN="/nonexistent/soapcap-deidentify-helper"
sc_deidentify_transcript "Therapist: Hi Sarah, how are you"
rc=$?
assert_eq "deidentify: missing helper fails closed (no transcript set)" "" "$SC_DEIDENTIFY_TRANSCRIPT"
assert_eq "deidentify: missing helper returns non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

stub=$(mktemp)
printf '#!/usr/bin/env bash\necho "boom" >&2\nexit 1\n' > "$stub"; chmod +x "$stub"
SOAPCAP_DEIDENTIFY_BIN="$stub"
sc_deidentify_transcript "Therapist: Hi Sarah, how are you"
rc=$?
assert_eq "deidentify: helper crash fails closed (no transcript set)" "" "$SC_DEIDENTIFY_TRANSCRIPT"
assert_eq "deidentify: helper crash returns non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
rm -f "$stub"

stub=$(mktemp)
printf '#!/usr/bin/env bash\necho "model weights unavailable" >&2\nexit 2\n' > "$stub"; chmod +x "$stub"
SOAPCAP_DEIDENTIFY_BIN="$stub"
sc_deidentify_transcript "Therapist: Hi Sarah, how are you"
rc=$?
assert_eq "deidentify: helper exit-2 (no weights) fails closed" "" "$SC_DEIDENTIFY_TRANSCRIPT"
assert_eq "deidentify: helper exit-2 returns non-zero" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"
rm -f "$stub"

stub=$(mktemp)
printf '#!/usr/bin/env bash\ncat\necho "no entities detected" >&2\n' > "$stub"; chmod +x "$stub"
SOAPCAP_DEIDENTIFY_BIN="$stub"
sc_deidentify_transcript "Therapist: How was your week"
assert_eq "deidentify: zero detections leaves transcript unchanged" \
  "Therapist: How was your week" "$SC_DEIDENTIFY_TRANSCRIPT"
assert_eq "deidentify: zero detections' summary relayed" \
  "no entities detected" "$SC_DEIDENTIFY_SUMMARY"
rm -f "$stub"

# A stub that just uppercases its input: if the speaker label ever leaked
# through to the helper, it would come back uppercased too -- this
# specifically catches that failure mode, not just "does re-zipping work."
stub=$(mktemp)
printf '#!/usr/bin/env bash\ntr "[:lower:]" "[:upper:]"\necho "redacted 0 span(s)" >&2\n' > "$stub"; chmod +x "$stub"
SOAPCAP_DEIDENTIFY_BIN="$stub"
sc_deidentify_transcript "Sarah: hi there, with Camila.
Client: second line here."
assert_eq "deidentify: speaker label never sent to the helper, multi-line reassembly correct" \
  "Sarah: HI THERE, WITH CAMILA.
Client: SECOND LINE HERE." "$SC_DEIDENTIFY_TRANSCRIPT"
rm -f "$stub"

# shellcheck source=test/flow.sh
. "$here/test/flow.sh"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
