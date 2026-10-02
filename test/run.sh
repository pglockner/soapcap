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
    # The last flow run's stderr, when there was one: usually the reason.
    [ -n "${FLOW_ERR:-}" ] && printf '  stderr:   %s\n' "$(printf '%s' "$FLOW_ERR" | head -5)"
  fi
}

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

# --- structured style: rendering (lib/structured/render.jq) -------------

sjq() { jq -r -L "$here/lib/structured" "$@"; }
render() { sjq --arg format "$1" -f "$here/lib/structured/render.jq"; }

empty_note='{"subjective": "", "objective_observations": [], "assessment": "", "response": "",
  "risk": {"status": "not_addressed", "summary": ""},
  "safety_plan": {"warning_signs": [], "coping_strategies": [], "supports": [], "emergency_steps": []},
  "interventions_used": [], "plan_items": []}'

assert_eq "render soap: an empty note still has exactly the four headers, filled in" \
  "SUBJECTIVE:
Not addressed in this session

OBJECTIVE:
No observable presentation details available from a text-only transcript.

ASSESSMENT:
Not addressed in this session

PLAN:
The current plan of care will continue." "$(printf '%s' "$empty_note" | render soap)"

assert_eq "render dap: no observations -> the fallback sentence closes Data" \
  "DATA:
Reported. No observable presentation details available from a text-only transcript." \
  "$(printf '%s' "$empty_note" | jq '.subjective = "Reported."' | render dap | head -2)"

assert_eq "render birp: the four BIRP headers, in order" "BEHAVIOR: INTERVENTION: RESPONSE: PLAN:" \
  "$(printf '%s' "$empty_note" | render birp | grep -E '^[A-Z]+:$' | tr '\n' ' ' | sed 's/ $//')"

assert_eq "render: risk not addressed adds nothing to Assessment" "Impression." \
  "$(printf '%s' "$empty_note" | jq '.assessment = "Impression." | .risk.summary = "should not show"' \
     | render soap | sed -n '/^ASSESSMENT:/{n;p;}')"

assert_eq "render: next steps grouped three to a sentence, then the therapist's and shared ones" \
  "The client agreed to a1, a2, and a3. The client also planned to a4. The therapist will t1. The client and therapist agreed to b1." \
  "$(printf '%s' "$empty_note" | jq '.plan_items = [
      {line:1,actor:"client",action:"a1"},{line:1,actor:"client",action:"a2"},{line:1,actor:"client",action:"a3"},
      {line:1,actor:"client",action:"a4"},{line:1,actor:"therapist",action:"t1"},{line:1,actor:"both",action:"b1"}]' \
     | render soap | sed -n '/^PLAN:/{n;p;}')"

assert_eq "render: interventions go four to a sentence" \
  "In session, the therapist did i1, did i2, did i3, and did i4. The therapist also did i5." \
  "$(printf '%s' "$empty_note" | jq '.interventions_used = [range(1;6) | {line:1, action:"did i\(.)"}]' \
     | render soap | sed -n '/^PLAN:/{n;p;}')"

assert_eq "render: tidies phrases (\"commit to\", leading \"to\", trailing period), keeps proper nouns" \
  "The client agreed to paint on Saturday, call Camila, and walk daily." \
  "$(printf '%s' "$empty_note" | jq '.plan_items = [
      {line:1,actor:"client",action:"Commit to paint on Saturday."},
      {line:1,actor:"client",action:"to call Camila"},{line:1,actor:"client",action:"walk daily;"}]' \
     | render soap | sed -n '/^PLAN:/{n;p;}')"

assert_eq "render: the safety plan lists only the parts that were filled in" \
  "The safety plan identified warning signs: skipping meals; and supports: the client's sister (Camila)." \
  "$(printf '%s' "$empty_note" | jq '.safety_plan.warning_signs = ["skipping meals"] | .safety_plan.supports = ["the client'"'"'s sister (Camila)"]' \
     | render soap | sed -n '/^PLAN:/{n;p;}')"

# --- SOAP Objective (lib/structured/objective.jq, sc_splice_objective) ---

SC_ROOT="$here"
ms='{"mental_status": {"engagement": "engaged and collaborative", "affect": "congruent",
  "mood": "mildly stressed.", "speech": "clear", "thought_process": "linear",
  "insight": "improving", "judgment": "intact", "psychomotor": "no psychomotor abnormalities"},
  "risk": {"status": "not_addressed", "summary": ""}}'
frame="On time via video. Engaged and collaborative. Affect congruent; mood mildly stressed. Speech clear. Thought process linear. Insight improving; judgment intact. No psychomotor abnormalities."

assert_eq "objective: fills the fixed frame, trimming trailing periods" \
  "$frame No SI/HI reported." "$(sc_render_objective "$ms" "PLAN: Continue.")"
assert_eq "objective: a disclosure is named by kind, in fixed words" "$frame SI reported; see Assessment and Plan." \
  "$(sc_render_objective "$(jq '.risk = {status: "disclosed", summary: "Passive, no plan"} | .risk_kind = "SI"' <<<"$ms")" "x")"
assert_eq "objective: ...HI too" "$frame SI and HI reported; see Assessment and Plan." \
  "$(sc_render_objective "$(jq '.risk.status = "disclosed" | .risk_kind = "SI and HI"' <<<"$ms")" "x")"
assert_eq "objective: disclosed with no usable kind still says so" "$frame Safety risk reported; see Assessment and Plan." \
  "$(sc_render_objective "$(jq '.risk.status = "disclosed" | .risk_kind = "none"' <<<"$ms")" "x")"
assert_contains "objective: risk in the note, missed by the pass, blocks \"No SI/HI reported\"" \
  "$(sc_render_objective "$ms" "The client said everyone would be better off without them.")" \
  "[The note mentions a safety concern; confirm SI/HI status before signing.]"
assert_contains "objective: ...self-harm too" \
  "$(sc_render_objective "$ms" "Reported urges to self-harm.")" "confirm SI/HI status"
assert_eq "objective: a plain denial in the note is still \"No SI/HI reported\"" "$frame No SI/HI reported." \
  "$(sc_render_objective "$ms" "The client denied suicidal ideation.")"
assert_eq "objective: a denial covering two terms is still a denial" "$frame No SI/HI reported." \
  "$(sc_render_objective "$ms" "There is no indication of self-harm or suicidal ideation.")"
assert_contains "objective: a denial followed by a disclosure isn't a denial" \
  "$(sc_render_objective "$ms" "The client denied a plan but reported passive suicidal ideation.")" \
  "confirm SI/HI status"
assert_eq "objective: a failed pass is marked, with no SI/HI claim" \
  "On time via video. [Objective could not be drafted; complete manually.] [SI/HI status not assessed; confirm before signing.]" \
  "$(sc_render_objective null "x")"
assert_eq "objective: no client speech leaves it to the clinician, with no SI/HI claim" \
  "On time via video. [No client speech was captured; complete the Objective manually.] [SI/HI status not assessed; confirm before signing.]" \
  "$(sc_render_objective '{"no_client": true}' "x")"
assert_contains "objective: a blank field shows, rather than vanishing" \
  "$(sc_render_objective "$(jq '.mental_status.affect = ""' <<<"$ms")" "x")" "Affect [not assessed]; mood"

spliced="SUBJECTIVE:
S.

OBJECTIVE:
BODY

ASSESSMENT:
A.

PLAN:
P."
assert_eq "splice: replaces the Objective's body" "$spliced" \
  "$(printf 'SUBJECTIVE:\nS.\n\nOBJECTIVE:\nold\nlines\n\nASSESSMENT:\nA.\n\nPLAN:\nP.\n' | sc_splice_objective BODY)"
assert_eq "splice: handles header markup, text on the header line, and a second Objective" "$spliced" \
  "$(printf 'SUBJECTIVE:\nS.\n\n**OBJECTIVE:** old\n\nASSESSMENT:\nA.\n\nOBJECTIVE:\nagain\n\nPLAN:\nP.\n' | sc_splice_objective BODY)"
assert_eq "splice: inserts a missing Objective before Assessment" "$spliced" \
  "$(printf 'SUBJECTIVE:\nS.\n\nASSESSMENT:\nA.\n\nPLAN:\nP.\n' | sc_splice_objective BODY)"

assert_eq "default plan: \"Not addressed\" in Plan becomes the plan-of-care sentence" \
  "A:
x

PLAN:
The current plan of care will continue." \
  "$(printf 'A:\nx\n\nPLAN:\nNot addressed in this session.\n' | sc_default_plan)"
assert_eq "default plan: so does an empty Plan" "PLAN:
The current plan of care will continue." "$(printf 'PLAN:\n\n' | sc_default_plan)"
assert_eq "default plan: a real Plan is left alone" "PLAN:
Weekly sessions. Not addressed in this session." \
  "$(printf 'PLAN:\nWeekly sessions. Not addressed in this session.\n' | sc_default_plan)"
assert_eq "default plan: \"Not addressed\" elsewhere is left alone" "ASSESSMENT:
Not addressed in this session.

PLAN:
Continue." "$(printf 'ASSESSMENT:\nNot addressed in this session.\n\nPLAN:\nContinue.\n' | sc_default_plan)"

# --- sc_ctx_exceeds_cap -------------------------------------------------

short=$(awk 'BEGIN{for(i=0;i<9000;i++)printf "w "}')
long=$(awk 'BEGIN{for(i=0;i<22000;i++)printf "w "}')
assert_eq "ctx cap: a 9000-word prompt fits" fits "$(sc_ctx_exceeds_cap "$short" 1024 && echo over || echo fits)"
assert_eq "ctx cap: a 22000-word prompt does not" over "$(sc_ctx_exceeds_cap "$long" 1024 && echo over || echo fits)"

# --- sc_subjective_missing ----------------------------------------------

miss() { printf '%b' "$1" | sc_subjective_missing && echo missing || echo present; }
assert_eq "subjective: real content is present" present \
  "$(miss '63 minutes, telehealth\n\nSUBJECTIVE:\nFelt anxious.\n\nOBJECTIVE:\nx\n')"
assert_eq "subjective: \"Not addressed\" is missing" missing \
  "$(miss 'SUBJECTIVE:\nNot addressed in this session\n\nOBJECTIVE:\nx\n')"
assert_eq "subjective: empty is missing" missing "$(miss 'SUBJECTIVE:\n\nOBJECTIVE:\nx\n')"
assert_eq "subjective: no header is missing" missing "$(miss 'and confused.\n\nOBJECTIVE:\nx\n')"
assert_eq "subjective: bold header with text on the line is present" present \
  "$(miss '**SUBJECTIVE:** Felt anxious.\n\nOBJECTIVE:\nx\n')"

# --- sc_show: word-wrap for the terminal only ---------------------------

# script(1) gives sc_show a real terminal 30 columns wide -- with a stale
# COLUMNS=80 in the environment, which must not win; script prefixes its
# output with ^D and two backspaces, and ends lines in \r\n.
# shellcheck disable=SC1112  # the curly quotes are the point of the test
para='The client reported a difficult week — “I’m exhausted,” they said — with work and caregiving demands.'
# shellcheck disable=SC2016  # $1/$2 belong to the inner bash
# BSD script takes the command as arguments, util-linux's as -c STRING
# (run by sh, so the text goes in through the environment, not quoting).
if script --version 2>&1 | grep -q util-linux; then
  shown=$(COLUMNS=80 SC_T_HERE="$here" SC_T_PARA="$para" script -qec \
    "bash -c 'stty cols 30; . \"\$SC_T_HERE/lib/common.sh\"; sc_show \"\$SC_T_PARA\"'" /dev/null </dev/null \
    | LC_ALL=C sed -e 's/\r$//' | sed '/^$/d')
else
  # shellcheck disable=SC2016  # $1/$2 belong to the inner bash
  shown=$(COLUMNS=80 script -q /dev/null bash -c 'stty cols 30; . "$1/lib/common.sh"; sc_show "$2"' _ "$here" "$para" </dev/null \
    | LC_ALL=C sed -e $'s/^\\^D\b\b//' -e 's/\r$//' | sed '/^$/d')
fi
widest=0
while IFS= read -r l; do
  n=$(LC_ALL=en_US.UTF-8 bash -c 'printf %s "${#1}"' _ "$l")
  [ "$n" -gt "$widest" ] && widest=$n
done <<<"$shown"
assert_eq "sc_show: on a terminal, it wraps (more than one line)" "yes" \
  "$([ "$(printf '%s\n' "$shown" | wc -l | tr -d ' ')" -gt 1 ] && echo yes || echo no)"
assert_eq "sc_show: ...every line fits the terminal's width" "yes" "$([ "$widest" -le 30 ] && echo yes || echo no)"
assert_eq "sc_show: ...wrapping at spaces, never inside a word" "$para" \
  "$(printf '%s\n' "$shown" | sed 's/ $//' | paste -sd ' ' -)"
assert_eq "sc_show: not a terminal, printed unchanged" "$para" "$(sc_show "$para" | cat)"

# --- session line and saved transcripts ----------------------------------

assert_eq "session line: minutes and session type" "63 minutes, telehealth" "$(sc_session_line 63)"
assert_eq "session line: one minute is singular" "1 minute, telehealth" "$(sc_session_line 1)"
assert_eq "session line: under a minute doesn't read as zero" "under 1 minute, telehealth" "$(sc_session_line 0)"
assert_eq "session line: left off when the length is unknown" "NOTE" "$(sc_with_session_line "" NOTE)"

SOAPCAP_SAVE_DIR=$(mktemp -d)/saved
p1=$(sc_save_transcript "Client: [FIRST_NAME_1] said hi")
p2=$(sc_save_transcript "second")
assert_eq "save: writes the transcript" "Client: [FIRST_NAME_1] said hi" "$(cat "$p1")"
assert_eq "save: readable by this user only" "600" "$(stat -c %a "$p1" 2>/dev/null || stat -f %Lp "$p1")"
assert_eq "save: a second save the same minute gets its own file" "second" "$(cat "$p2")"
assert_contains "save: named so note's file picker finds it" "$p1" ".deid.transcript"
rm -rf "$(dirname "$SOAPCAP_SAVE_DIR")"
assert_eq "save: bare Enter at the save prompt means no" "no" \
  "$(printf '\n' | SOAPCAP_NO_GUM=1 sc_choose "Save?" no yes 2>/dev/null)"

# --- structured style: validation (lib/structured/validate.jq) ----------

vtranscript=$(mktemp)
printf "Therapist: I notice you are tearing up.\nClient: Yeah, it's a lot.\nClient: Just laying there for hours and not really eating much at all.\n" > "$vtranscript"
validate() { sjq --rawfile transcript "$vtranscript" --arg format "${1:-soap}" -f "$here/lib/structured/validate.jq" | jq -r '.[]'; }

assert_eq "validate: a clean note flags nothing" "" "$(printf '%s' "$empty_note" | validate)"

assert_contains "validate: flags an observation attributed to the wrong speaker" \
  "$(printf '%s' "$empty_note" | jq '.objective_observations = [{line:1,speaker:"Client",text:"Tearing up."}]' | validate)" \
  "attributes a reaction to the Client, but line 1 is: Therapist: I notice"

assert_contains "validate: flags a cited line that doesn't exist" \
  "$(printf '%s' "$empty_note" | jq '.plan_items = [{line:9,actor:"client",action:"x"}]' | validate)" \
  "cites line 9, which doesn't exist"

assert_contains "validate: flags a quote that isn't in the transcript" \
  "$(printf '%s' "$empty_note" | jq '.subjective = "They said \"I am getting choked up\"."' | validate)" \
  "isn't in the transcript: \"I am getting choked up\""

assert_eq "validate: a real quote passes, curly apostrophes and all" "" \
  "$(printf '%s' "$empty_note" | jq '.subjective = "They said \u201cYeah, it\u2019s a lot\u201d."' | validate)"

assert_contains "validate: flags an observation that copies a transcript line" \
  "$(printf '%s' "$empty_note" | jq '.objective_observations = [{line:3,speaker:"Client",text:"Just laying there for hours and not really eating much at all."}]' | validate)" \
  "Objective copies the transcript word for word (line 3)"

assert_contains "validate: names the section a copy lands in, per format (BIRP: Behavior)" \
  "$(printf '%s' "$empty_note" | jq '.objective_observations = [{line:3,speaker:"Client",text:"Just laying there for hours and not really eating much at all."}]' | validate birp)" \
  "Behavior copies the transcript word for word (line 3)"

assert_eq "validate: a short phrase shared with the transcript isn't a copy" "" \
  "$(printf '%s' "$empty_note" | jq '.subjective = "The client said it was a lot."' | validate)"

assert_contains "validate: flags a disclosed risk with no safety plan" \
  "$(printf '%s' "$empty_note" | jq '.risk = {status:"disclosed", summary:"Passive SI."}' | validate)" \
  "no safety plan was recorded"
rm -f "$vtranscript"

# --- structured style: drift guard ---------------------------------------
# prompts/structured/rules.md is a fourth copy of the content rules. Every
# rule bullet that's word-for-word identical across soap/dap/birp.md must
# appear word-for-word in it too, so a fix to one isn't silently missed in
# the other -- except the one rule the structured renderer implements in
# code instead ("Not addressed in this session").

drift_check() {  # RULES_FILE -> first line of each shared bullet missing from it
  jq -rn --rawfile s "$here/prompts/soap.md" --rawfile d "$here/prompts/dap.md" \
    --rawfile b "$here/prompts/birp.md" --rawfile r "$1" '
  # One entry per rule bullet: a "- " line plus its indented continuations.
  def bullets: split("\n") | reduce .[] as $l ({out: [], cur: null};
      if ($l | startswith("- ")) then (if .cur then .out += [.cur] else . end) | .cur = $l
      elif ($l | startswith("  ")) and .cur then .cur += "\n" + $l
      else (if .cur then .out += [.cur] else . end) | .cur = null end)
    | if .cur then .out + [.cur] else .out end;
  ($d | bullets) as $D | ($b | bullets) as $B | ($r | bullets) as $R
  | $s | bullets[] | . as $x
  | select(startswith("- If any other section has no relevant content") | not)
  | select(($D | any(.[]; . == $x)) and ($B | any(.[]; . == $x)) and ($R | any(.[]; . == $x) | not))
  | split("\n")[0]'
}
assert_eq "drift guard: rules shared by all three prompts are also in the structured rules" "" \
  "$(drift_check "$here/prompts/structured/rules.md")"
mutated=$(mktemp)
sed 's/Do not assign or imply a diagnosis/Do not assign a diagnosis/' "$here/prompts/structured/rules.md" > "$mutated"
assert_eq "drift guard: catches a shared rule edited in only one place" \
  "- Do not assign or imply a diagnosis unless one was explicitly discussed" "$(drift_check "$mutated")"
rm -f "$mutated"

# shellcheck source=test/flow.sh
. "$here/test/flow.sh"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
