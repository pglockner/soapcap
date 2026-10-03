# shellcheck shell=bash
# soapcap session — the guided capture-to-note flow.

# `session` asks up to four yes/no questions, and config.sh can answer any of
# them ahead of time so the question is skipped (yes or no; anything else,
# or leaving it out, asks):
#   SOAPCAP_SESSION_DEIDENTIFY        de-identify the transcript and the note
#   SOAPCAP_SESSION_SAVE_TRANSCRIPT   save the de-identified transcript
#   SOAPCAP_SESSION_SHOW_TRANSCRIPT   print the transcript
#   SOAPCAP_SESSION_NOTE              draft a note (in SOAPCAP_FORMAT)

# sc_session_ask NAME PROMPT DEFAULT [NOTTY] — answers one of those
# questions: from SOAPCAP_SESSION_<NAME> if config.sh set it, else by asking
# PROMPT with DEFAULT (yes|no) as the bare-Enter answer, else -- nobody to
# ask, stdin isn't a terminal -- NOTTY (default: DEFAULT). Returns 0 for yes.
sc_session_ask() {
  local var="SOAPCAP_SESSION_$1" prompt="$2" default="$3" notty="${4:-$3}"
  case "${!var:-}" in
    yes) return 0 ;;
    no)  return 1 ;;
  esac
  if [ ! -t 0 ]; then
    [ "$notty" = yes ]
  elif [ "$default" = yes ]; then
    sc_confirm "$prompt"
  else
    # "no" comes first, so bare Enter never means yes.
    [ "$(sc_choose "$prompt" no yes)" = yes ]
  fi
}

# sc_save_transcript TEXT [LABEL] — saves a transcript under SOAPCAP_SAVE_DIR
# as <date>-<time>.<LABEL>.transcript (a name `note`'s file picker finds;
# LABEL defaults to "deid", for a de-identified one), readable by this user
# only, never overwriting an existing file. Prints the path.
sc_save_transcript() {
  local dir="$SOAPCAP_SAVE_DIR" base path n=1
  base="$(date +%Y-%m-%d-%H%M).${2:-deid}"
  mkdir -p "$dir" && chmod 700 "$dir" 2>/dev/null
  path="$dir/$base.transcript"
  while [ -e "$path" ]; do n=$((n + 1)); path="$dir/$base-$n.transcript"; done
  ( umask 077; printf '%s\n' "$1" > "$path" ) || { sc_err "couldn't write $path"; return 1; }
  printf '%s\n' "$path"
}

# sc_offer_save_transcript TRANSCRIPT DEIDENTIFIED — session's offer when the
# SOAP note came out with no Subjective, so the transcript can be looked at
# afterwards. Default no. Sets SC_OFFER_SAVED to the saved path. A transcript
# that wasn't de-identified is de-identified first when the helper is built,
# if she agrees; otherwise it is saved as is, and the message says so.
sc_offer_save_transcript() {
  SC_OFFER_SAVED=""
  local text="$1" deid="$2" label=deid path
  sc_info ""
  sc_info "This note has no Subjective section, which usually means something went wrong."
  [ "$(sc_choose "Save the transcript to $SOAPCAP_SAVE_DIR so it can be looked at?" no yes)" = yes ] || return 0
  if [ "$deid" -ne 1 ]; then
    if [ -x "$SOAPCAP_DEIDENTIFY_BIN" ] && sc_confirm "De-identify it first?" \
         && sc_deidentify_transcript "$text"; then
      text="$SC_DEIDENTIFY_TRANSCRIPT"; sc_info "transcript: $SC_DEIDENTIFY_SUMMARY"
    else
      label=original
    fi
  fi
  path=$(sc_save_transcript "$text" "$label") || return 0
  SC_OFFER_SAVED="$path"
  if [ "$label" = original ]; then
    sc_info "saved: $path — this is the ORIGINAL transcript and holds client details; handle it as you would a session record, and delete it when done"
  else
    sc_info "saved: $path — best-effort de-identification; review it before sharing, and delete it when done"
  fi
  command -v open >/dev/null 2>&1 && open -R "$path" 2>/dev/null
  sc_info "(shown in Finder: the soapcap folder in your home folder)"
}

# sc_session_title — the heading `session` opens with: an ASCII-art title on
# its full-screen display when the terminal is wide enough, a plain line
# otherwise (piped, scripted, or a narrow window).
sc_session_title() {
  if [ "${SC_ALT_SCREEN:-0}" = "1" ] && [ "$(tput cols 2>/dev/null || echo 0)" -ge 50 ]; then
    cat >&2 <<'TITLE'
  _______________  ______   ____ _____  ______
 /  ___/  _ \__  \ \____ \_/ ___\\__  \ \____ \
 \___ (  <_> ) __ \|  |_> >  \___ / __ \|  |_> >
/____  >____(____  /   __/ \___  >____  /   __/
     \/          \/|__|        \/     \/|__|

TITLE
    sc_info "guided capture"
  else
    sc_info "soapcap session — guided capture"
  fi
}

# sc_session_preflight MODEL HOST — checked before the recording starts, not
# after an hour-long session: can MODEL draft a note? Says nothing when it
# can. When it can't, says what to fix and asks whether to record anyway (the
# transcript is still captured, and the note can be retried afterwards);
# fails only on a "no".
sc_session_preflight() {
  sc_model_check "$1" "$2" && return 0
  sc_info "Recording still works; a note can be drafted once that's fixed."
  [ -t 0 ] || return 0
  sc_confirm "Start recording anyway?"
}

# sc_session_format FORMAT NO_NOTE DEIDENTIFIED — prints the format to draft
# a note in, or nothing for no note. --format (FORMAT) or --no-note decide
# it outright, then SOAPCAP_SESSION_NOTE; otherwise one question asks both
# whether and which, with the configured format first so that bare Enter
# drafts it. Without a terminal to ask on, there is no note.
sc_session_format() {
  local format="$1" no_note="$2" deid="$3" f opts header="Draft a note?" choice
  [ "$no_note" -eq 1 ] && return 0
  [ -n "$format" ] && { printf '%s\n' "$format"; return 0; }
  case "${SOAPCAP_SESSION_NOTE:-}" in
    yes) printf '%s\n' "$SOAPCAP_FORMAT"; return 0 ;;
    no)  return 0 ;;
  esac
  [ -t 0 ] || return 0
  opts=("$SOAPCAP_FORMAT")
  for f in soap dap birp; do
    [ "$f" = "$SOAPCAP_FORMAT" ] || opts+=("$f")
  done
  [ "$deid" -eq 1 ] && header="Draft a de-identified note?"
  sc_info ""
  choice=$(sc_choose "$header" "${opts[@]}" no)
  [ "$choice" = no ] || printf '%s\n' "$choice"
}

# sc_session_draft FORMAT MODEL HOST STYLE TRANSCRIPT DEIDENTIFIED MINUTES CLIPBOARD
#
# Drafts the note and asks what to do with it, until that is settled. A
# draft can be copied to the clipboard, drafted again (LLM output is
# stochastic -- a weak draft is often just an unlucky roll), drafted with
# another installed model, or discarded; a draft that failed can be retried,
# tried with another model, or given up on with the transcript copied
# instead, so a session is never lost to a model that wasn't running.
# Without a terminal the first draft is kept as it comes. Sets SC_NOTE (the
# note, empty for none), SC_SESSION_COPIED ("note", "transcript" or empty)
# and SC_SESSION_REVIEW_COPY (a transcript saved for troubleshooting).
sc_session_draft() {
  SC_SESSION_COPIED=""; SC_SESSION_REVIEW_COPY=""
  local format="$1" model="$2" host="$3" style="$4" transcript="$5" deid="$6" minutes="$7" clipboard="$8"
  local choice header offered_save="" m switch others options
  # Kept loaded between drafts, so "regenerate" doesn't wait for the model
  # to load again; stopped once the draft is settled.
  # shellcheck disable=SC2034  # read by sc_generate_note (lib/note.sh)
  [ -t 0 ] && SC_KEEP_MODEL=1

  while :; do
    sc_info ""
    if sc_generate_note "$format" "$model" "$host" "$transcript" "$style"; then
      if [ "$deid" -eq 1 ]; then
        if sc_deidentify_transcript "$SC_NOTE" note; then
          SC_NOTE="$SC_DEIDENTIFY_TRANSCRIPT"
          sc_info "note: $SC_DEIDENTIFY_SUMMARY"
        else
          sc_err "note de-identify failed — showing the note as drafted instead (see above)"
        fi
      fi
      # Added after de-identification, so the redaction pass never sees
      # it; SC_NOTE is drafted afresh on regenerate, so it never stacks.
      SC_NOTE=$(sc_with_session_line "$minutes" "$SC_NOTE")
      sc_info ""
      sc_info "----- $format note -----"
      sc_show "$SC_NOTE"
      sc_info "-------------------------"
      [ -n "$SC_REVIEW" ] && sc_info "$SC_REVIEW"
      if [ ! -t 0 ]; then
        [ "$clipboard" -eq 1 ] && sc_to_clipboard "$SC_NOTE" 2>/dev/null && SC_SESSION_COPIED=note
        break
      fi
      if [ "$format" = soap ] && [ -z "$offered_save" ] \
           && printf '%s\n' "$SC_NOTE" | sc_subjective_missing; then
        offered_save=1
        sc_offer_save_transcript "$transcript" "$deid"
        SC_SESSION_REVIEW_COPY="$SC_OFFER_SAVED"
      fi
      header="This draft:"
      options=("copy to clipboard" regenerate)
    else
      SC_NOTE=""
      sc_err "note generation failed — the transcript is still here, nothing lost"
      [ -t 0 ] || break
      header="No note was drafted:"
      options=(retry)
    fi

    # Every other model that's ready to use: one is offered by name, more
    # than one as a "switch model" that then asks which.
    others=()
    while IFS= read -r m; do
      [ -n "$m" ] && [ "$m" != "$model" ] && others+=("$m")
    done <<MODELS
$(sc_installed_models "$host" "$model")
MODELS
    switch=""
    if [ "${#others[@]}" -eq 1 ]; then switch="try ${others[0]}"
    elif [ "${#others[@]}" -gt 1 ]; then switch="switch model"; fi
    [ -n "$switch" ] && options+=("$switch")
    if [ -n "$SC_NOTE" ]; then options+=(discard); else options+=("copy transcript" quit); fi

    choice=$(sc_choose "$header" "${options[@]}")
    case "$choice" in
      "copy to clipboard")
        if sc_to_clipboard "$SC_NOTE" 2>/dev/null; then SC_SESSION_COPIED=note
        else sc_err "couldn't copy the note — pbcopy isn't available"; fi
        break ;;
      "copy transcript")
        if sc_to_clipboard "$transcript" 2>/dev/null; then SC_SESSION_COPIED=transcript
        else sc_err "couldn't copy the transcript — pbcopy isn't available"; fi
        break ;;
      discard|quit) SC_NOTE=""; break ;;
      regenerate|retry) : ;;
      *)
        # Free the old model's memory before the new one loads.
        sc_model_stop
        if [ "${#others[@]}" -eq 1 ]; then model="${others[0]}"
        else model=$(sc_choose "Model for the note?" "${others[@]}"); fi ;;
    esac
  done
  sc_model_stop
}

# ---------------------------------------------------------------------------
# soapcap session [--format soap|dap|birp] [--model NAME] [--no-note]
#                 [--style narrative|structured|combined]
#                 [--clipboard] [--mic-label ...] [--system-label ...]
#                 [--locale ...] [--no-dedupe]
#
# Guided flow meant for the double-clickable launcher (soapcap.command) and
# for anyone who'd rather answer a couple of prompts than remember
# `live | note`: capture live, then ask about de-identifying, showing the
# transcript, and drafting a note (sc_session_ask, sc_session_format,
# sc_session_draft). --format implies "yes, draft one" for
# non-interactive/scripted use; --no-note skips asking. Prompts are skipped
# (falling back to plain `live` behavior) when stdin isn't a real terminal,
# since there'd be nothing to read an answer from.
sc_cmd_session() {
  local mic="$SOAPCAP_MIC_LABEL" sys="$SOAPCAP_SYSTEM_LABEL" locale="$SOAPCAP_LOCALE"
  local dedupe=1 format="" model="$SOAPCAP_MODEL" host="$SOAPCAP_OLLAMA_HOST"
  local style="$SOAPCAP_STYLE" no_note=0 clipboard=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --mic-label)    mic="${2:?}"; shift 2 ;;
      --system-label) sys="${2:?}"; shift 2 ;;
      --locale)       locale="${2:?}"; shift 2 ;;
      --no-dedupe)    dedupe=0; shift ;;
      --format)       format="${2:?}"; shift 2 ;;
      --style)        style="${2:?}"; shift 2 ;;
      --model)        model="${2:?}"; shift 2 ;;
      --host)         host="${2:?}"; shift 2 ;;
      --no-note)      no_note=1; shift ;;
      --clipboard)    clipboard=1; shift ;;
      -h|--help)      sc_usage; return 0 ;;
      *) sc_die "session: unknown option: $1" ;;
    esac
  done
  # Everything a note needs is checked before capture starts, not after an
  # hour-long session: the style, the format, and (below) the model.
  # Might this run draft a note? Yes unless told otherwise, or there is
  # nobody to ask and nothing said to draft one.
  local may_note=1
  if [ "$no_note" -eq 1 ] || [ "${SOAPCAP_SESSION_NOTE:-}" = no ]; then
    may_note=0
  elif [ -z "$format" ] && [ "${SOAPCAP_SESSION_NOTE:-}" != yes ] && [ ! -t 0 ]; then
    may_note=0
  fi
  sc_need yap; sc_need jq
  if [ "$may_note" -eq 1 ]; then
    sc_need curl
    sc_check_style "$style" || exit 1
    sc_check_format "${format:-$SOAPCAP_FORMAT}" || exit 1
  fi
  # sc_generate_note looks for the client's lines by this label.
  SOAPCAP_SYSTEM_LABEL="$sys"

  # Everything from here on can include PHI (transcript, drafted note) --
  # draw it to the terminal's alternate screen buffer so none of it lands
  # in normal scrollback or a terminal app's session-restore snapshot. See
  # Retention in the README and sc_alt_screen_start's comment.
  sc_alt_screen_start
  # Finished drafting passes leave their time/tokens/memory line on screen.
  # shellcheck disable=SC2034  # read by sc_spin_post (lib/generate.sh)
  SC_KEEP_PASS_STATS=1

  sc_session_title
  sc_capture_tips
  if [ "$may_note" -eq 1 ]; then
    sc_session_preflight "$model" "$host" || exit 1
  fi

  sc_capture_checked "$mic" "$sys" "$locale"

  local transcript
  transcript=$(printf '%s' "$SC_JSON" | sc_render_transcript "$mic" "$sys" "$dedupe") \
    || sc_die "failed to render transcript from yap JSON"

  local line_count minutes
  line_count=$(printf '%s\n' "$transcript" | wc -l | tr -d ' ')
  # Whole minutes spent recording, rounded down so it never overstates
  # the session; paused time isn't counted.
  minutes=$(( ${SC_SESSION_SECONDS:-0} / 60 ))

  sc_info ""
  sc_info "Transcript: $line_count line(s), recorded $(( ${SC_SESSION_SECONDS:-0} / 60 )):$(printf '%02d' $(( ${SC_SESSION_SECONDS:-0} % 60 ))) — the note will say \"$(sc_session_line "$minutes")\"."
  # Said here, before any question: a transcript missing one side of the
  # call changes whether a note is worth drafting at all.
  sc_warn_one_sided_capture "$SC_JSON" "$mic" "$sys"

  # One all-or-nothing question, asked once and only when the helper is
  # built. It comes before "Show the transcript?" so that what's printed
  # to the screen is already the redacted text. Yes redacts the transcript
  # here (everything downstream -- display, drafting, clipboard -- then
  # uses the redacted version) and the drafted note again before it's shown.
  local deidentify=0 saved=""
  if [ -x "$SOAPCAP_DEIDENTIFY_BIN" ] \
       && sc_session_ask DEIDENTIFY "De-identify the transcript now, and the note once it's drafted?" yes no; then
    if sc_deidentify_transcript "$transcript"; then
      deidentify=1
      transcript="$SC_DEIDENTIFY_TRANSCRIPT"
      sc_info "transcript: $SC_DEIDENTIFY_SUMMARY"
      # Only ever offered for a transcript that really was redacted, and
      # never yes by default: bare Enter must not write PHI to disk.
      if sc_session_ask SAVE_TRANSCRIPT "Save the de-identified transcript to $SOAPCAP_SAVE_DIR?" no; then
        saved=$(sc_save_transcript "$transcript") \
          && sc_info "saved: $saved — best-effort de-identification; review it before sharing, and delete it when done"
      fi
    else
      sc_err "transcript de-identify failed — continuing with the original transcript (see above)"
    fi
  fi

  if sc_session_ask SHOW_TRANSCRIPT "Show the transcript?" yes; then
    sc_info ""
    sc_info "----- transcript -----"
    sc_show "$transcript"
    sc_info "-----------------------"
  fi

  SC_NOTE=""; SC_SESSION_COPIED=""; SC_SESSION_REVIEW_COPY=""
  format=$(sc_session_format "$format" "$no_note" "$deidentify")
  if [ -n "$format" ]; then
    sc_session_draft "$format" "$model" "$host" "$style" "$transcript" "$deidentify" "$minutes" "$clipboard"
  elif [ "$clipboard" -eq 1 ]; then
    sc_to_clipboard "$transcript" 2>/dev/null && SC_SESSION_COPIED=transcript
  fi

  # Last thing on screen, so it's easy to see: the on-screen copy has no
  # scrollback, so a long note loses its top when selected by hand.
  case "$SC_SESSION_COPIED" in
    note)       sc_info ""; sc_info "Copied — Cmd-V to paste it into your preferred editor." ;;
    transcript) sc_info ""; sc_info "Transcript copied — Cmd-V to paste it into your preferred editor." ;;
  esac
  sc_info ""
  local disk="Nothing was written to disk"
  if [ -n "$saved" ]; then
    disk="The de-identified transcript is saved at $saved; nothing else was written to disk"
  elif [ -n "$SC_SESSION_REVIEW_COPY" ]; then
    disk="The transcript is saved at $SC_SESSION_REVIEW_COPY; nothing else was written to disk"
  fi
  if [ "${SC_ALT_SCREEN:-0}" = "1" ]; then
    sc_info "$disk, and this screen won't appear in your terminal's scrollback."
  else
    sc_info "$disk unless you redirected it yourself."
  fi
}
