# shellcheck shell=bash
# soapcap note — note styles, the SOAP Objective pass, and drafting.

# Note styles (SOAPCAP_STYLE / --style):
#   narrative   the model writes the note as prose (prompts/<format>.md)
#   structured  the model returns JSON matching a schema; code checks it
#               against the transcript and writes the note
#               (prompts/structured/, lib/structured/)
#   combined    a narrative note, plus a structured pass used only to
#               review it -- roughly twice the drafting time

# sc_check_style STYLE — returns 1, with an error, unless STYLE is valid.
sc_check_style() {
  case "$1" in
    narrative|structured|combined) return 0 ;;
    *) sc_err "unknown style '$1' — use narrative, structured, or combined"; return 1 ;;
  esac
}

# sc_structured_fields FORMAT — the schema fields for FORMAT, in the order
# the model writes them (which is also note order).
sc_structured_fields() {
  case "$1" in
    # SOAP's Objective comes from its own pass (the "objective" fields),
    # not from observations -- see sc_objective_prompt.
    soap)      echo "subjective assessment risk safety_plan interventions_used plan_items" ;;
    dap)       echo "subjective objective_observations assessment risk safety_plan interventions_used plan_items" ;;
    objective) echo "mental_status risk risk_kind" ;;
    birp)     echo "subjective objective_observations interventions_used response risk safety_plan plan_items" ;;
    *) return 1 ;;
  esac
}

# sc_structured_prompt FORMAT TRANSCRIPT — prints the structured prompt: the
# shared content rules, the field guide for FORMAT's fields, and the
# transcript with numbered lines (the model cites them; validation checks
# them against this same transcript).
sc_structured_prompt() {
  local format="$1" transcript="$2" dir="$SC_ROOT/prompts/structured" f
  local upper; upper=$(printf '%s' "$format" | tr '[:lower:]' '[:upper:]')
  sed "1s/clinical SOAP\$/clinical $upper/" "$dir/rules.md"
  echo
  for f in _intro $(sc_structured_fields "$format") _phrases _closing; do
    awk -v s="$f" '/^## /{p=($2 == s); next} p' "$dir/fields.md"
  done
  printf '\nTRANSCRIPT:\n'
  printf '%s\n' "$transcript" | awk '{printf "%d | %s\n", NR, $0}'
}

# sc_objective_prompt TRANSCRIPT — prints the SOAP Objective pass's prompt.
# Its own prompt rather than the shared rules: those forbid judging affect,
# mood or speech from a transcript, which is exactly what this pass does,
# for the therapist's mental-status Objective.
sc_objective_prompt() {
  cat "$SC_ROOT/prompts/objective.md"
  printf '\nTRANSCRIPT:\n%s\n' "$1"
}

# sc_render_objective JSON NOTE — prints the SOAP Objective body: the fixed
# frame from lib/structured/objective.jq, filled in from the Objective
# pass's JSON ("null" if that pass failed). NOTE is the rest of the note,
# checked for risk language before "No SI/HI reported." goes in.
sc_render_objective() {
  local nfile out
  sc_tmpfile nfile || return 1
  printf '%s\n' "$2" > "$nfile"
  out=$(printf '%s' "$1" | jq -r -L "$SC_ROOT/lib/structured" --rawfile note "$nfile" \
    -f "$SC_ROOT/lib/structured/objective.jq")
  rm -f "$nfile"
  [ -n "$out" ] && printf '%s\n' "$out"
}

# sc_splice_objective BODY — reads a SOAP note on stdin and prints it with
# its OBJECTIVE section's body replaced by BODY. Copes with what a model
# may have done to that section: extra header markup ("**OBJECTIVE:**"),
# text on the header line, a second OBJECTIVE, or none at all (inserted
# before ASSESSMENT, else PLAN, else at the end).
sc_splice_objective() {
  awk -v body="$1" '
    function hdr(name) { return $0 ~ ("^[#* \t]*" name "[* \t]*:") }
    function put() { if (!done) { print "OBJECTIVE:"; print body; print ""; done = 1 } }
    hdr("OBJECTIVE") { skip = 1; put(); next }
    hdr("SUBJECTIVE") || hdr("ASSESSMENT") || hdr("PLAN") {
      if (skip) skip = 0
      if (!hdr("SUBJECTIVE")) put()
    }
    !skip { print }
    END { if (!done) { print ""; print "OBJECTIVE:"; print body } }
  '
}

# sc_add_objective JSON — replaces SC_NOTE's Objective with the one
# rendered from the Objective pass's JSON.
sc_add_objective() {
  local body
  if ! body=$(sc_render_objective "$1" "$SC_NOTE") || [ -z "$body" ]; then
    sc_err "couldn't compose the Objective"; return 1
  fi
  SC_NOTE=$(printf '%s\n' "$SC_NOTE" | sc_splice_objective "$body")
}

# sc_default_plan — safety net: the SOAP prompt says Plan always states
# the plan of care, but a model can still fall back on the other sections'
# "Not addressed in this session" (seen with llama3.1:8b) or leave Plan
# empty. Reads a note on stdin; either case becomes the plan-of-care
# sentence. Plan is the last section, so its body runs to the end.
sc_default_plan() {
  awk '
    { lines[NR] = $0 }
    /^[#* \t]*PLAN[* \t]*:/ { p = NR }
    END {
      body = ""
      for (i = p + 1; p && i <= NR; i++) body = body lines[i]
      gsub(/[ \t*.]/, "", body)
      empty = p && (body == "" || tolower(body) == "notaddressedinthissession")
      for (i = 1; i <= (empty ? p : NR); i++) print lines[i]
      if (empty) print "The current plan of care will continue."
    }
  '
}

# sc_structured_schema FORMAT — prints the JSON schema for FORMAT.
sc_structured_schema() {
  local fields
  fields=$(sc_structured_fields "$1" | jq -Rc 'split(" ")')
  jq -c --argjson fields "$fields" \
    '. as $all | {type: "object",
       properties: (reduce $fields[] as $f ({}; .[$f] = $all[$f])),
       required: $fields}' "$SC_ROOT/prompts/structured/schema.json"
}

# sc_structured_request MODEL HOST FORMAT PROMPT TITLE [CAP] — sets
# SC_STRUCT_JSON. CAP is the output cap in tokens (default 3000).
# Bonsai's server must already be running. The schema is enforced by the
# server, but a response can still be cut off (output cap) or come back
# malformed, so one invalid response is retried once before giving up. The
# output cap matters: without one, a model can loop inside the JSON until
# the request times out.
sc_structured_request() {
  SC_STRUCT_JSON=""
  local model="$1" host="$2" format="$3" prompt="$4" title="$5" cap="${6:-3000}" schema attempt
  schema=$(sc_structured_schema "$format") || { sc_err "no structured schema for '$format'"; return 1; }
  for attempt in 1 2; do
    if [ "$model" = bonsai ]; then
      sc_bonsai_request "$prompt" "$title" "$(jq -nc --argjson s "$schema" --argjson cap "$cap" '{
        temperature: 0.3, top_p: 0.8, top_k: 20, max_tokens: $cap,
        response_format: {type: "json_schema", json_schema: {schema: $s}}}')" || return 1
    else
      sc_ollama_generate "$model" "$host" "$prompt" "$title" 3072 "$(jq -nc --argjson s "$schema" --argjson cap "$cap" '{
        format: $s, options: {temperature: 0.3, top_p: 0.8, top_k: 20, num_predict: $cap}}')" || return 1
    fi
    # shellcheck disable=SC2153  # set by sc_ollama_generate (lib/generate.sh)
    if [ "$SC_RAW_DONE" = stop ] && printf '%s' "$SC_RAW_NOTE" \
         | jq -e --argjson s "$schema" '. as $o | type == "object" and ($s.required | all(. as $k | $o | has($k)))' >/dev/null 2>&1; then
      SC_STRUCT_JSON="$SC_RAW_NOTE"
      return 0
    fi
    [ "$attempt" = 1 ] && sc_info "The structured draft came back incomplete — retrying once…"
  done
  sc_err "the structured draft came back incomplete twice (cut off or malformed)"
  return 1
}

# sc_review_block TITLE LINES — frames review lines for display on stderr.
sc_review_block() {
  printf '%s\n' "----- $1 -----" "$2" "-----------------------------"
}

# sc_generate_note <format> <model> <host> <transcript> [style]
#
# Drafts a note from a transcript with a local model: `bonsai` via
# llama-server, anything else via Ollama. On success sets SC_NOTE (the note)
# and SC_REVIEW (review text for the clinician, possibly empty -- shown on
# stderr, never part of the note) and returns 0; on failure prints an
# actionable error via sc_err and returns 1 — it does NOT exit, so a caller
# holding an already-captured transcript (sc_cmd_session) can report the
# failure without losing it. sc_cmd_note, which has nothing else at stake,
# turns that failure straight into sc_die.
sc_generate_note() {
  SC_NOTE=""; SC_REVIEW=""
  local format="$1" model="$2" host="$3" transcript="$4" style="${5:-narrative}"
  sc_check_style "$style" || return 1

  local prompt_file="$SC_ROOT/prompts/$format.md"
  if [ ! -f "$prompt_file" ]; then
    sc_err "unknown format '$format' (no $prompt_file)"; return 1
  fi

  if ! sc_model_catalog | cut -d'|' -f1 | grep -qx "$model"; then
    sc_info "note: $model hasn't been tested with soapcap's prompts — proofread it with extra care."
  fi

  local full_prompt="" sprompt="" rc=0 note=""
  if [ "$style" != structured ]; then
    full_prompt="$(cat "$prompt_file")

TRANSCRIPT:
$transcript"
  fi
  if [ "$style" != narrative ]; then
    sprompt=$(sc_structured_prompt "$format" "$transcript")
  fi

  # Past the context cap a model silently loses part of its input, and what
  # it writes then can look fine while missing whole sections.
  if { [ -n "$full_prompt" ] && sc_ctx_exceeds_cap "$full_prompt" 2048; } \
     || { [ -n "$sprompt" ] && sc_ctx_exceeds_cap "$sprompt" 3072; }; then
    sc_info "warning: this transcript is very long — it may be more than $model can take in at once, so sections of the note (Subjective especially) may be missing or wrong. Check the note against the transcript."
  fi

  # SOAP's Objective always comes from a pass of its own (see
  # sc_objective_prompt), whatever the style.
  # With no client speech at all (the other side of the call wasn't
  # captured), there's nobody to assess: the model would rate the
  # therapist instead. Skip the pass and leave Objective to the clinician.
  local oprompt="" ojson="null" sjson=""
  if [ "$format" = soap ]; then
    if printf '%s\n' "$transcript" | awk -v l="$SOAPCAP_SYSTEM_LABEL: " 'index($0, l) == 1 { f = 1 } END { exit !f }'; then
      oprompt=$(sc_objective_prompt "$transcript")
    else
      ojson='{"no_client": true}'
      sc_info "note: no $SOAPCAP_SYSTEM_LABEL lines in the transcript — the Objective is left for you to complete."
    fi
  fi

  # Bonsai: one server start for every pass, sized for the largest request.
  # 2048 of headroom covers the narrative output cap, 3072 the structured one.
  local who="$model" slow=""
  if [ "$model" = bonsai ]; then
    who="Bonsai"; slow=" (this takes a few minutes)"
    local c ctx=0
    if [ -n "$full_prompt" ]; then c=$(sc_estimate_ctx "$full_prompt" 2048 8192); [ "$c" -gt "$ctx" ] && ctx=$c; fi
    if [ -n "$sprompt" ]; then c=$(sc_estimate_ctx "$sprompt" 3072 8192); [ "$c" -gt "$ctx" ] && ctx=$c; fi
    if [ -n "$oprompt" ]; then c=$(sc_estimate_ctx "$oprompt" 3072 8192); [ "$c" -gt "$ctx" ] && ctx=$c; fi
    sc_bonsai_start "$ctx" || return 1
  fi

  if [ -n "$full_prompt" ]; then
    if [ "$model" = bonsai ]; then
      sc_bonsai_narrative "$full_prompt" "$format"
    else
      sc_ollama_generate "$model" "$host" "$full_prompt" "Drafting a $format note with ${model}…"
    fi || { sc_model_stop "$model" "$host"; return 1; }
    note="$SC_RAW_NOTE"
  fi
  if [ -n "$sprompt" ]; then
    if [ "$style" = structured ]; then
      sc_structured_request "$model" "$host" "$format" "$sprompt" \
        "Drafting a structured $format note with ${who}${slow}…" || { sc_model_stop "$model" "$host"; return 1; }
    else
      sc_structured_request "$model" "$host" "$format" "$sprompt" \
        "Checking the note against the transcript with ${who}…"
      rc=$?
    fi
    sjson="$SC_STRUCT_JSON"
  fi
  if [ -n "$oprompt" ]; then
    # A failed Objective pass never costs the rest of the note: the
    # Objective then says plainly that it needs completing by hand.
    # A few short phrases: a low output cap stops a field that runs on
    # (seen once with Bonsai) from costing minutes before it's retried.
    if sc_structured_request "$model" "$host" objective "$oprompt" "Drafting the Objective with ${who}…" 600; then
      ojson="$SC_STRUCT_JSON"
    else
      sc_err "warning: the Objective pass failed — complete the Objective by hand"
    fi
  fi
  sc_model_stop "$model" "$host"
  SC_RAW_NOTE="$note"; SC_STRUCT_JSON="$sjson"

  local tfile nfile lines
  if [ "$style" = structured ]; then
    SC_NOTE=$(printf '%s' "$SC_STRUCT_JSON" | jq -r -L "$SC_ROOT/lib/structured" \
      --arg format "$format" -f "$SC_ROOT/lib/structured/render.jq") || return 1
    [ "$format" = soap ] && { sc_add_objective "$ojson" || return 1; }
    sc_tmpfile tfile || return 1
    printf '%s\n' "$transcript" > "$tfile"
    lines=$(printf '%s' "$SC_STRUCT_JSON" | jq -r -L "$SC_ROOT/lib/structured" \
      --rawfile transcript "$tfile" --arg format "$format" -f "$SC_ROOT/lib/structured/validate.jq" \
      | jq -r '.[] | "  • " + .')
    rm -f "$tfile"
    if [ -n "$lines" ]; then SC_REVIEW=$(sc_review_block "review before submitting" "$lines")
    else SC_REVIEW="review: nothing flagged"; fi
    [ -n "$SC_NOTE" ]
    return
  fi

  # Three safety nets against known model misbehavior in prose — see each
  # function's own comment for the specific failure it guards against.
  note="$SC_RAW_NOTE"
  note=$(printf '%s\n' "$note" | sc_strip_transcript_echo)
  note=$(printf '%s\n' "$note" | sc_strip_contaminated_fallback)
  SC_NOTE=$(printf '%s\n' "$note" | sc_strip_trailing_disclaimer)
  [ -n "$SC_NOTE" ] || return 1
  if [ "$format" = soap ]; then
    sc_add_objective "$ojson" || return 1
    SC_NOTE=$(printf '%s\n' "$SC_NOTE" | sc_default_plan)
  fi

  if [ "$style" = combined ]; then
    if [ "$rc" -ne 0 ]; then
      # The review pass is a check, not the note: never lose the note over it.
      SC_REVIEW="warning: the review pass failed, so this note hasn't been checked against the transcript"
      return 0
    fi
    sc_tmpfile tfile || return 0
    sc_tmpfile nfile || return 0
    printf '%s\n' "$transcript" > "$tfile"
    printf '%s\n' "$SC_NOTE" > "$nfile"
    lines=$(printf '%s' "$SC_STRUCT_JSON" | jq -r -L "$SC_ROOT/lib/structured" \
      --rawfile transcript "$tfile" --rawfile note "$nfile" --arg format "$format" \
      -f "$SC_ROOT/lib/structured/review.jq" | jq -r '
        (.flags[] | "  • " + .),
        (if (.steps | length) > 0 then
           "  Next steps mentioned in the session — confirm each is in the note:",
           (.steps[] | "    line \(.line): \(.action)")
         else empty end)')
    rm -f "$tfile" "$nfile"
    if [ -n "$lines" ]; then SC_REVIEW=$(sc_review_block "review before submitting" "$lines")
    else SC_REVIEW="review: nothing flagged"; fi
  fi
  return 0
}

# sc_session_line MINUTES — prints the note's first line, e.g.
# "63 minutes, telehealth".
sc_session_line() {
  case "$1" in
    0) printf 'under 1 minute, %s\n' "$SOAPCAP_SESSION_TYPE" ;;
    1) printf '1 minute, %s\n' "$SOAPCAP_SESSION_TYPE" ;;
    *) printf '%s minutes, %s\n' "$1" "$SOAPCAP_SESSION_TYPE" ;;
  esac
}

# sc_with_session_line MINUTES NOTE — prints NOTE under its session line,
# or unchanged when MINUTES is empty (a transcript of unknown length).
sc_with_session_line() {
  if [ -n "$1" ]; then printf '%s\n\n%s\n' "$(sc_session_line "$1")" "$2"
  else printf '%s\n' "$2"; fi
}

# ---------------------------------------------------------------------------
# soapcap note [FILE] [--model NAME] [--format soap|dap|birp]
#              [--style narrative|structured|combined] [--host URL]
#              [--duration MINUTES] [--out FILE] [--clipboard]
#
# Reads a transcript (FILE, or stdin so it composes with `live`/`transcribe`)
# and drafts a note via sc_generate_note(). Any review text goes to stderr,
# never into the note, --out, or the clipboard. --duration puts the
# session line ("50 minutes, telehealth") above the note; a transcript file
# doesn't record how long the session was.
sc_cmd_note() {
  local file="" out="" model="$SOAPCAP_MODEL" format="$SOAPCAP_FORMAT" host="$SOAPCAP_OLLAMA_HOST"
  local style="$SOAPCAP_STYLE" clipboard=0 duration=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --out)       out="${2:?--out needs a path}"; shift 2 ;;
      --model)     model="${2:?}"; shift 2 ;;
      --format)    format="${2:?}"; shift 2 ;;
      --style)     style="${2:?}"; shift 2 ;;
      --host)      host="${2:?}"; shift 2 ;;
      --duration)  duration="${2:?--duration needs a number of minutes}"; shift 2 ;;
      --clipboard) clipboard=1; shift ;;
      -h|--help)   sc_usage; return 0 ;;
      -*) sc_die "note: unknown option: $1" ;;
      *)  file="$1"; shift ;;
    esac
  done

  sc_check_style "$style" || exit 1
  case "$duration" in
    ''|*[!0-9]*) [ -z "$duration" ] || sc_die "note: --duration takes whole minutes, e.g. --duration 53" ;;
  esac
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

  sc_generate_note "$format" "$model" "$host" "$transcript" "$style" || sc_die "note generation failed"
  local note
  note=$(sc_with_session_line "$duration" "$SC_NOTE")

  if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$note" > "$out"
    sc_info "note written to: $out  (contains PHI — delete when done)"
  else
    sc_show "$note"
  fi
  [ -n "$SC_REVIEW" ] && sc_info "$SC_REVIEW"
  [ "$clipboard" -eq 1 ] && sc_to_clipboard "$note"
  return 0
}
