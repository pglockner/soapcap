#!/usr/bin/env bash
# Drafts a note from each sample transcript (samples/transcripts/) with a
# real model and checks the note's shape: every section header present, and
# no section empty or "Not addressed in this session" when the transcript
# plainly covers it. A regression check for prompt and model changes -- the
# one thing test/run.sh's stand-ins can't cover. Slow (a model pass or two
# per transcript) and not run by CI.
#
#   test/samples.sh                          every sample, default model, SOAP
#   test/samples.sh --model bonsai 03 08     just samples 03 and 08
#   test/samples.sh --runs 5 08              five drafts of sample 08
#   test/samples.sh --keep DIR               also save each note under DIR
#
# Any other option (--format, --style, --host) is passed to `soapcap note`.
# Exits non-zero if any draft fails a check.
set -u

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SC_ROOT="$here"
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
# shellcheck source=lib/commands.sh
. "$here/lib/commands.sh"

runs=1 keep="" format=soap opts=() picks=()
while [ $# -gt 0 ]; do
  case "$1" in
    --runs)   runs="${2:?--runs needs a number}"; shift 2 ;;
    --keep)   keep="${2:?--keep needs a folder}"; shift 2 ;;
    --format) format="${2:?}"; opts+=("$1" "$2"); shift 2 ;;
    --*)      opts+=("$1" "${2:?}"); shift 2 ;;
    *)        picks+=("$1"); shift ;;
  esac
done
case "$format" in
  soap) headers="SUBJECTIVE OBJECTIVE ASSESSMENT PLAN" ;;
  dap)  headers="DATA ASSESSMENT PLAN" ;;
  birp) headers="BEHAVIOR INTERVENTION RESPONSE PLAN" ;;
  *) echo "samples.sh: unknown format '$format'" >&2; exit 2 ;;
esac
[ -z "$keep" ] || mkdir -p "$keep"

# check_note HEADERS — reads a note on stdin; prints what is wrong with it,
# nothing if it's sound. Sample 01 is a one-minute check-in with next to no
# content, so an empty section there isn't a fault (see its README entry).
check_note() {
  awk -v want="$1" -v lenient="$2" "$SC_NOTE_AWK"'
    BEGIN { n = split(want, names, " ") }
    { for (i = 1; i <= n; i++) if (hdr(names[i])) { cur = names[i]; seen[cur] = 1; sub(/^[^:]*:/, "") } }
    cur != "" { body[cur] = body[cur] $0 }
    END {
      for (i = 1; i <= n; i++) {
        if (!seen[names[i]]) print "no " names[i] " section"
        else if (!lenient && hollow(body[names[i]])) print names[i] " is empty or \"Not addressed\""
      }
    }'
}

bad=0 total=0
for f in "$here"/samples/transcripts/*.transcript; do
  name=$(basename "$f" .transcript)
  if [ "${#picks[@]}" -gt 0 ]; then
    case " ${picks[*]} " in *" ${name%%-*} "*) ;; *) continue ;; esac
  fi
  lenient=""
  [ "${name%%-*}" = 01 ] && lenient=1
  i=1
  while [ "$i" -le "$runs" ]; do
    total=$((total + 1))
    t0=$SECONDS
    if note=$("$here/bin/soapcap" note "$f" ${opts[@]+"${opts[@]}"} 2>/dev/null); then
      faults=$(printf '%s\n' "$note" | check_note "$headers" "$lenient")
    else
      note=""; faults="soapcap note failed"
    fi
    [ -z "$keep" ] || printf '%s\n' "$note" > "$keep/$name.$i.txt"
    if [ -z "$faults" ]; then
      printf 'ok    %-44s run %d  %3ds\n' "$name" "$i" $((SECONDS - t0))
    else
      bad=$((bad + 1))
      printf 'FAIL  %-44s run %d  %3ds  %s\n' "$name" "$i" $((SECONDS - t0)) "$(printf '%s' "$faults" | paste -sd ';' -)"
    fi
    i=$((i + 1))
  done
done

echo
echo "$((total - bad)) of $total drafts sound"
[ "$bad" -eq 0 ]
