# shellcheck shell=bash
# soapcap deidentify — local PII redaction via the de-identify helper.

# sc_deidentify_transcript TRANSCRIPT
#
# Runs TRANSCRIPT through the de-identify helper (tools/deidentify: OpenMed's
# on-device PII model) and replaces detected PII with consistent,
# category-numbered bracket tokens ([FIRST_NAME_1], [PHONE_1], ...) --
# the helper does the actual detection and substitution; this function
# only strips/reattaches speaker labels around it. Deliberately does NOT
# follow this file's other text-transform helpers' "always succeeds, pure
# awk" shape: failing closed is the entire point here. A missing/crashed
# helper must produce NO output, not a pass-through of unredacted PHI --
# a silent no-op would be a worse failure than an error. On success sets
# SC_DEIDENTIFY_TRANSCRIPT and SC_DEIDENTIFY_SUMMARY (a one-line count,
# e.g. "redacted 4 span(s): FIRST_NAME x3, PHONE x1", straight from the
# helper's own stderr) and returns 0. On failure both are cleared, an
# actionable message goes to sc_err, and it returns 1 without exiting --
# same contract as sc_generate_note.
sc_deidentify_transcript() {
  SC_DEIDENTIFY_TRANSCRIPT=""
  SC_DEIDENTIFY_SUMMARY=""
  local transcript="$1" bin="$SOAPCAP_DEIDENTIFY_BIN"

  if [ ! -x "$bin" ]; then
    sc_err "de-identify helper not found or not executable: $bin"
    sc_err "set it up with: ${SC_ROOT:-.}/tools/deidentify/install.sh"
    return 1
  fi

  # Split into (label, body) at the FIRST ": " per line -- the label is
  # NEVER sent to the helper and NEVER substituted, even if a configured
  # label happens to be a real name. A line with no colon is label=""
  # body=<whole line>, still processed. Labels held in a parallel array,
  # bodies concatenated with \n into $body_blob (order preserved).
  local -a labels=()
  local body_blob="" line label body first=1
  while IFS= read -r line; do
    case "$line" in
      *': '*) label="${line%%: *}"; body="${line#*: }" ;;
      *)      label="";             body="$line" ;;
    esac
    labels+=("$label")
    if [ "$first" -eq 1 ]; then body_blob="$body"; first=0
    else body_blob="$body_blob"$'\n'"$body"; fi
  done <<TRANSCRIPT
$transcript
TRANSCRIPT

  local errfile; errfile=$(mktemp) || { sc_err "could not create a temp file"; return 1; }
  local redacted_body rc
  redacted_body=$(printf '%s' "$body_blob" | "$bin" 2>"$errfile")
  rc=$?
  local helper_stderr; helper_stderr=$(cat "$errfile"); rm -f "$errfile"

  if [ "$rc" -eq 2 ]; then
    sc_err "de-identify model weights unavailable: $helper_stderr"
    sc_err "re-run ${SC_ROOT:-.}/tools/deidentify/install.sh to download them"
    return 1
  elif [ "$rc" -ne 0 ]; then
    sc_err "de-identify helper failed: $helper_stderr"
    return 1
  fi
  SC_DEIDENTIFY_SUMMARY="$helper_stderr"

  # Re-zip: redacted_body has exactly as many lines as $labels has
  # entries (the helper never changes line count), so pair them back up
  # in order.
  local i=0 out="" redacted_line
  while IFS= read -r redacted_line; do
    label="${labels[$i]}"
    if [ -n "$label" ]; then redacted_line="$label: $redacted_line"; fi
    if [ "$i" -eq 0 ]; then out="$redacted_line"
    else out="$out"$'\n'"$redacted_line"; fi
    i=$((i + 1))
  done <<REDACTED
$redacted_body
REDACTED

  SC_DEIDENTIFY_TRANSCRIPT="$out"
  return 0
}

# soapcap deidentify [FILE] [--out FILE] [--clipboard]
#
# Reads a transcript (FILE, or stdin so it composes with `live`/`note`,
# e.g. `soapcap live | soapcap deidentify | soapcap note`) and runs it
# through sc_deidentify_transcript(). Mirrors sc_cmd_note's FILE/stdin/
# --out/picker conventions, minus --model/--format/--host -- there's one
# fixed detection model, no catalog to choose from.
sc_cmd_deidentify() {
  local file="" out="" clipboard=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --out)       out="${2:?--out needs a path}"; shift 2 ;;
      --clipboard) clipboard=1; shift ;;
      -h|--help)   sc_usage; return 0 ;;
      -*) sc_die "deidentify: unknown option: $1" ;;
      *)  file="$1"; shift ;;
    esac
  done

  local transcript
  if [ -n "$file" ]; then
    [ -f "$file" ] || sc_die "no such file: $file"
    transcript=$(cat "$file")
  elif [ -t 0 ]; then
    file=$(sc_pick_transcript_file) \
      || sc_die "deidentify: no FILE given and nothing piped in. Pass a file, pipe a transcript in, or install fzf to browse for one (brew install fzf)."
    [ -n "$file" ] || sc_die "deidentify: no file selected"
    [ -f "$file" ] || sc_die "no such file: $file"
    transcript=$(cat "$file")
  else
    transcript=$(cat)
  fi
  [ -n "$transcript" ] || sc_die "deidentify: empty transcript (pass a file, or pipe one in via stdin)"

  # No pipefail is set (bin/soapcap: set -u only), but none is needed:
  # sc_die below exits before anything reaches this command's stdout, so
  # a downstream `| soapcap note` sees zero bytes and hits its own
  # existing "empty transcript" guard rather than a partial/bad note.
  sc_deidentify_transcript "$transcript" \
    || sc_die "de-identification failed — see above. Nothing was printed, to avoid passing unredacted PHI downstream."
  local redacted="$SC_DEIDENTIFY_TRANSCRIPT"
  sc_info "$SC_DEIDENTIFY_SUMMARY"

  if [ -n "$out" ]; then
    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$redacted" > "$out"
    sc_info "de-identified transcript written to: $out — best-effort only, review before treating as safe to share (see README \"De-identify\")"
  else
    printf '%s\n' "$redacted"
  fi
  [ "$clipboard" -eq 1 ] && sc_to_clipboard "$redacted"
  return 0
}
