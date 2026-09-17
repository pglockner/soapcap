# shellcheck shell=bash
# soapcap — shared helpers, config loading, cleanup. Sourced by bin/soapcap.

# ---- defaults (override via env or ~/.config/soapcap/config.sh) --------------
SOAPCAP_MIC_LABEL="${SOAPCAP_MIC_LABEL:-Therapist}"
SOAPCAP_SYSTEM_LABEL="${SOAPCAP_SYSTEM_LABEL:-Client}"
SOAPCAP_LOCALE="${SOAPCAP_LOCALE:-}"

# `note` (local SOAP/DAP/BIRP generation via Ollama). llama3.1:8b, not the
# smaller/faster llama3.2:3b, is the default — see README "note" section:
# 3b reliably either fabricates clinical Objective-section content or
# (with a prompt strong enough to stop that) swings the other way and
# under-reports real observations; 8b got both right in testing. Needs
# ~5GB free memory beyond whatever else is running — see README "Your
# machine". Fall back to llama3.2:3b with `--model` if that's tight, but
# expect to proofread the Objective section more carefully.
SOAPCAP_MODEL="${SOAPCAP_MODEL:-llama3.1:8b}"
SOAPCAP_FORMAT="${SOAPCAP_FORMAT:-soap}"
SOAPCAP_OLLAMA_HOST="${SOAPCAP_OLLAMA_HOST:-http://localhost:11434}"

# `deidentify` (local PII redaction via tools/deidentify-helper, built
# opt-in by install.sh — see README "De-identify"). SC_ROOT is set by
# bin/soapcap before this file is sourced, but test/run.sh sources this
# file directly without ever setting SC_ROOT — the inner ${SC_ROOT:-}
# guard is required, not decorative: without it this line hard-fails
# under test/run.sh's `set -u` the instant this file is sourced. No
# separate on/off toggle exists — the binary's absence is the toggle;
# sc_deidentify_transcript fails closed with an actionable message when
# it's missing.
SOAPCAP_DEIDENTIFY_BIN="${SOAPCAP_DEIDENTIFY_BIN:-${SC_ROOT:-}/tools/deidentify-helper/.build/release/soapcap-deidentify-helper}"

_sc_cfg="${SOAPCAP_CONFIG:-$HOME/.config/soapcap/config.sh}"
# shellcheck source=/dev/null
[ -f "$_sc_cfg" ] && . "$_sc_cfg"

# ---- logging (everything human-facing goes to stderr; stdout is data) -------
sc_err()  { printf 'soapcap: %s\n' "$*" >&2; }
sc_info() { printf '%s\n' "$*" >&2; }
sc_die()  { sc_err "$*"; exit 1; }

# ---- cleanup ---------------------------------------------------------------
# SC_WORKDIR holds a per-run mktemp dir that only ever contains a FIFO and
# yap's stderr. Removed on every exit path.
sc_cleanup() {
  if [ -n "${SC_WORKDIR:-}" ] && [ -d "${SC_WORKDIR:-}" ]; then
    rm -rf "$SC_WORKDIR"
  fi
  SC_WORKDIR=""
}

sc_need() {
  command -v "$1" >/dev/null 2>&1 || sc_die "required tool not found on PATH: $1"
}

# sc_to_clipboard TEXT — best-effort copy to the macOS clipboard via pbcopy.
# Note this is another place PHI can linger: most clipboard managers keep
# history. See README "Retention".
sc_to_clipboard() {
  if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$1" | pbcopy
    sc_info "(copied to clipboard)"
  else
    sc_info "(pbcopy not found — could not copy to clipboard)"
  fi
}

# ---- optional prompt/picker helpers (gum, fzf) ------------------------------
# Both are entirely optional. Every function here degrades to a plain
# `read`-based prompt (or a clear error) when the tool isn't installed —
# soapcap never requires either. Callers are expected to already know
# stdin is a real terminal (guard with `[ -t 0 ]`) before calling these.
#
# SOAPCAP_NO_GUM=1 forces the plain-prompt path in both functions below
# even when gum is present -- install.sh sets this for its one call into
# `soapcap model` (which would otherwise use gum, freshly installed by an
# earlier install.sh prompt, for that single interaction) so the whole
# installer stays plain-text throughout rather than switching styles
# partway through.

# sc_confirm PROMPT — asks a yes/no question, defaulting to yes on bare
# Enter either way. Returns 0 for yes, 1 for no.
sc_confirm() {
  local prompt="$1"
  if [ -z "${SOAPCAP_NO_GUM:-}" ] && command -v gum >/dev/null 2>&1; then
    gum confirm "$prompt"
    return $?
  fi
  printf '%s [Y/n] ' "$prompt" >&2
  local ans=""
  read -r ans || true
  case "$ans" in
    n|N|no|No) return 1 ;;
    *)         return 0 ;;
  esac
}

# sc_choose HEADER OPTION... — prints the chosen option to stdout. The
# plain-prompt fallback defaults to the first option on bare Enter, and
# also accepts a bare first letter (e.g. "k" for "keep") when that letter
# is unambiguous among the options given -- shown bracketed in the prompt
# ("[k]eep") only when it actually is unambiguous, so the hint is never
# misleading.
sc_choose() {
  local header="$1"; shift
  if [ -z "${SOAPCAP_NO_GUM:-}" ] && command -v gum >/dev/null 2>&1; then
    gum choose --header "$header" "$@"
    return
  fi
  local opt lc seen=" " unique=1
  for opt in "$@"; do
    lc=$(printf '%s' "${opt:0:1}" | tr '[:upper:]' '[:lower:]')
    case "$seen" in *" $lc "*) unique=0 ;; esac
    seen="$seen$lc "
  done
  local disp
  if [ "$unique" -eq 1 ]; then
    disp=""
    for opt in "$@"; do
      disp="${disp:+$disp/}[${opt:0:1}]${opt:1}"
    done
  else
    disp=$(IFS=/; echo "$*")
  fi
  printf '%s %s (default: %s) ' "$header" "$disp" "$1" >&2
  local ans=""
  read -r ans || true
  [ -z "$ans" ] && { printf '%s\n' "$1"; return; }
  for opt in "$@"; do
    [ "$ans" = "$opt" ] && { printf '%s\n' "$opt"; return; }
  done
  if [ "$unique" -eq 1 ] && [ "${#ans}" -eq 1 ]; then
    lc=$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')
    for opt in "$@"; do
      [ "$(printf '%s' "${opt:0:1}" | tr '[:upper:]' '[:lower:]')" = "$lc" ] && { printf '%s\n' "$opt"; return; }
    done
  fi
  printf '%s\n' "$1"
}

# sc_pick_transcript_file — browses SOAPCAP_TRANSCRIPT_DIR (default $HOME)
# for *.transcript(.txt) files via fzf and prints the chosen path to
# stdout. Only useful, and only invoked, when `note` is run with no FILE
# and nothing piped in. Fails (return 1) if fzf isn't installed — the
# caller reports that as a normal "pass a file or pipe one in" error, not
# a soapcap bug.
sc_pick_transcript_file() {
  command -v fzf >/dev/null 2>&1 || return 1
  local root="${SOAPCAP_TRANSCRIPT_DIR:-$HOME}"
  find "$root" -type d -name '.*' -prune -o \
       -type f \( -name '*.transcript' -o -name '*.transcript.txt' \) -print \
    2>/dev/null \
    | fzf --prompt="transcript> " --header="Pick a transcript for soapcap note" \
          --height=40% --reverse
}

sc_usage() {
  cat >&2 <<'EOF'
soapcap — on-device capture + transcription of a telehealth session, with
          local SOAP/DAP/BIRP note drafting via Ollama

USAGE
  soapcap doctor                  Check OS/hardware, tools, and permissions
  soapcap live [opts]             Capture a live session -> transcript
  soapcap transcribe FILE [opts]  Transcribe an existing recording -> transcript
  soapcap note [FILE] [opts]      Transcript (FILE or stdin) -> SOAP/DAP/BIRP note
                                  via a local Ollama model
  soapcap deidentify [FILE] [opts]   Transcript (FILE or stdin) -> best-effort
                                  local PII redaction (needs tools/deidentify-helper)
  soapcap model [--host URL]      Show/pick the model session & note default
                                  to, pulling it via Ollama if needed
  soapcap session [opts]          Guided: capture, then ask about a note and
                                  the clipboard — what soapcap.command runs
  soapcap version | help

WHILE RECORDING (live / session, when run from a real terminal)
  q, x, Ctrl-C          Stop for good
  p, space              Pause — nothing is captured until you resume (p again)

OPTIONS (live / transcribe / session)
  --out FILE            Write the transcript to FILE (default: stdout only)
  --keep-json FILE      Also write the raw yap JSON (segments + timings)
  --mic-label NAME      Label for your side of the call   (default: Therapist)
  --system-label NAME   Label for the other side          (default: Client)
  --locale CODE         Force a locale, e.g. en-US
  --no-dedupe           Keep mic/system audio bleed instead of dropping it
                        — see README "Without headphones"
  --clipboard           Also copy the result to the clipboard (pbcopy)

OPTIONS (note / session)
  --out FILE            Write the note to FILE (default: stdout only)
  --model NAME          Ollama model tag       (default: llama3.1:8b)
  --format soap|dap|birp Note format           (default: soap)
  --host URL            Ollama server URL      (default: http://localhost:11434)

OPTIONS (session only)
  --no-note              Skip drafting a note; just capture and print

OPTIONS (deidentify)
  --out FILE            Write the de-identified transcript to FILE (default: stdout)
  --clipboard            Also copy the result to the clipboard (pbcopy)

EXAMPLES
  soapcap session                                    # double-click via soapcap.command
  soapcap live | soapcap note
  soapcap live | soapcap deidentify | soapcap note
  soapcap transcribe call.m4a | soapcap note --format dap --out note.md

RETENTION
  By default nothing touches disk: the transcript (and note) print once to
  stdout and no working file survives the run. --out / --keep-json opt in to
  files, and --clipboard to the clipboard — all of which then hold PHI and
  are your responsibility to clear.
EOF
}
