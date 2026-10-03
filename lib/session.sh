# shellcheck shell=bash
# soapcap session — the guided capture-to-note flow.

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

# sc_subjective_missing — reads a note on stdin; succeeds when it has no
# SUBJECTIVE section, or one that is empty or just "Not addressed in this
# session" (a small model sometimes writes that despite client speech).
sc_subjective_missing() {
  awk '
    function hdr(name) { return $0 ~ ("^[#* \t]*" name "[* \t]*:") }
    hdr("SUBJECTIVE") { found = 1; insec = 1; sub(/^[^:]*:/, ""); body = body $0; next }
    insec && (hdr("OBJECTIVE") || hdr("ASSESSMENT") || hdr("PLAN")) { insec = 0 }
    insec { body = body $0 }
    END {
      gsub(/[ \t*.]/, "", body)
      exit !(!found || body == "" || tolower(body) == "notaddressedinthissession")
    }
  '
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

# ---------------------------------------------------------------------------
# soapcap session [--format soap|dap|birp] [--model NAME] [--no-note]
#                 [--style narrative|structured|combined]
#                 [--clipboard] [--mic-label ...] [--system-label ...]
#                 [--locale ...] [--no-dedupe]
#
# Guided flow meant for the double-clickable launcher (soapcap.command) and
# for anyone who'd rather answer two prompts than remember `live | note`:
# capture live, print the transcript, then ask whether to draft a note and
# whether to copy the result to the clipboard. --format implies "yes, draft
# one" for non-interactive/scripted use; --no-note skips asking. Prompts are
# skipped (falling back to plain `live` behavior) when stdin isn't a real
# terminal, since there'd be nothing to read an answer from.
sc_cmd_session() {
  local mic="$SOAPCAP_MIC_LABEL" sys="$SOAPCAP_SYSTEM_LABEL" locale="$SOAPCAP_LOCALE"
  local dedupe=1 format="" model="$SOAPCAP_MODEL" host="$SOAPCAP_OLLAMA_HOST"
  local style="$SOAPCAP_STYLE" no_note=0 clipboard=0 model_given=0 note_copied=0 offered_save="" saved_for_review=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --mic-label)    mic="${2:?}"; shift 2 ;;
      --system-label) sys="${2:?}"; shift 2 ;;
      --locale)       locale="${2:?}"; shift 2 ;;
      --no-dedupe)    dedupe=0; shift ;;
      --format)       format="${2:?}"; shift 2 ;;
      --style)        style="${2:?}"; shift 2 ;;
      --model)        model="${2:?}"; model_given=1; shift 2 ;;
      --host)         host="${2:?}"; shift 2 ;;
      --no-note)      no_note=1; shift ;;
      --clipboard)    clipboard=1; shift ;;
      -h|--help)      sc_usage; return 0 ;;
      *) sc_die "session: unknown option: $1" ;;
    esac
  done
  # Checked before capture starts, not after an hour-long session.
  sc_check_style "$style" || exit 1
  # sc_generate_note looks for the client's lines by this label.
  SOAPCAP_SYSTEM_LABEL="$sys"

  sc_need yap; sc_need jq

  # Everything from here on can include PHI (transcript, drafted note) --
  # draw it to the terminal's alternate screen buffer so none of it lands
  # in normal scrollback or a terminal app's session-restore snapshot. See
  # Retention in the README and sc_alt_screen_start's comment.
  sc_alt_screen_start
  # Finished drafting passes leave their time/tokens/memory line on screen.
  # shellcheck disable=SC2034  # read by sc_spin_post (lib/generate.sh)
  SC_KEEP_PASS_STATS=1

  sc_info "soapcap session — guided capture"
  sc_info "  • Use headphones so your mic does not pick up the other party."
  sc_info "  • Turn on Do Not Disturb; system audio capture records the whole mix."
  if [ -t 0 ]; then
    sc_info "  • q or Ctrl-C to stop, p to pause (nothing is captured while paused)."
  else
    sc_info "  • Press Ctrl-C when the session ends."
  fi
  sc_info ""

  if ! sc_capture_session "$mic" "$sys" "$locale"; then
    sc_die "no audio captured. Run 'soapcap doctor' to check permissions."
  fi
  if ! printf '%s' "$SC_JSON" | jq -e '(.segments | length) > 0' >/dev/null 2>&1; then
    sc_die "capture produced no speech segments. Check mic/output routing and permissions."
  fi

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

  # One all-or-nothing question, asked once and only when the helper is
  # built. It comes before "Show the transcript?" so that what's printed
  # to the screen is already the redacted text. Yes redacts the transcript
  # here (everything downstream -- display, drafting, clipboard -- then
  # uses the redacted version) and the drafted note again before it's shown.
  local deidentify=0 saved=""
  if [ -t 0 ] && [ -x "$SOAPCAP_DEIDENTIFY_BIN" ]; then
    sc_confirm "De-identify the transcript now, and the note once it's drafted?" && deidentify=1
  fi
  if [ "$deidentify" -eq 1 ]; then
    if sc_deidentify_transcript "$transcript"; then
      transcript="$SC_DEIDENTIFY_TRANSCRIPT"
      sc_info "transcript: $SC_DEIDENTIFY_SUMMARY"
      # Only ever offered for a transcript that really was redacted, and
      # "no" comes first so bare Enter never writes PHI to disk.
      if [ "$(sc_choose "Save the de-identified transcript to $SOAPCAP_SAVE_DIR?" no yes)" = yes ]; then
        saved=$(sc_save_transcript "$transcript") \
          && sc_info "saved: $saved — best-effort de-identification; review it before sharing, and delete it when done"
      fi
    else
      sc_err "transcript de-identify failed — continuing with the original transcript (see above)"
    fi
  fi

  local show_transcript=1
  [ -t 0 ] && { sc_confirm "Show the transcript?" || show_transcript=0; }
  if [ "$show_transcript" -eq 1 ]; then
    sc_info ""
    sc_info "----- transcript -----"
    sc_show "$transcript"
    sc_info "-----------------------"
  fi

  sc_warn_one_sided_capture "$SC_JSON" "$mic" "$sys"

  local want_note=0
  if [ "$no_note" -eq 1 ]; then
    want_note=0
  elif [ -n "$format" ]; then
    want_note=1
  elif [ -t 0 ]; then
    sc_info ""
    if [ "$deidentify" -eq 1 ]; then
      sc_confirm "Draft a de-identified note from this?" && want_note=1
    else
      sc_confirm "Draft a note from this?" && want_note=1
    fi
  fi

  if [ "$want_note" -eq 1 ] && [ -z "$format" ]; then
    if [ -t 0 ]; then
      format=$(sc_choose "Format?" soap dap birp)
    else
      format="$SOAPCAP_FORMAT"
    fi
  fi

  if [ "$want_note" -eq 1 ]; then
    sc_need curl
    # Which model drafts the note: asked only on a real terminal, when
    # --model didn't already say, and when there's an actual choice. The
    # pick applies to this session only; 'soapcap model' sets the default.
    if [ -t 0 ] && [ "$model_given" -eq 0 ]; then
      local installed=() m
      while IFS= read -r m; do installed+=("$m"); done <<MODELS
$(sc_installed_models "$host" "$model")
MODELS
      if [ "${#installed[@]}" -gt 1 ]; then
        sc_info ""
        model=$(sc_choose "Model for the note?" "${installed[@]}")
      fi
    fi
    local keep_note=0 note_choice
    while [ "$keep_note" -eq 0 ]; do
      sc_info ""
      if sc_generate_note "$format" "$model" "$host" "$transcript" "$style"; then
        if [ "$deidentify" -eq 1 ]; then
          if sc_deidentify_transcript "$SC_NOTE"; then
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
        if [ -t 0 ] && [ "$format" = soap ] && [ -z "$offered_save" ] \
             && printf '%s\n' "$SC_NOTE" | sc_subjective_missing; then
          offered_save=1
          sc_offer_save_transcript "$transcript" "$deidentify"
          [ -n "$SC_OFFER_SAVED" ] && saved_for_review="$SC_OFFER_SAVED"
        fi
        if [ -t 0 ]; then
          # LLM output is stochastic -- a weak draft is often just an
          # unlucky roll, so offer another attempt with the same
          # model/transcript rather than settling for it or re-running the
          # whole command by hand. A plain yes/no doesn't work here: "no"
          # would have to mean both "discard this" AND "try again," with
          # no way to just give up and end the session with no note at
          # all. Three explicit choices instead, "keep" first so bare
          # Enter does the safe thing.
          note_choice=$(sc_choose "This draft:" keep regenerate discard)
          case "$note_choice" in
            keep) keep_note=1 ;;
            discard) SC_NOTE=""; break ;;
            *) : ;; # regenerate -- loop again
          esac
        else
          keep_note=1
        fi
      else
        sc_err "note generation failed — the transcript above is still yours, nothing lost"
        break
      fi
    done
    # "keep" is itself the user's answer to "do you want this" -- a
    # separate clipboard confirm right after was redundant in practice
    # (confirmed by hands-on testing), so keeping now copies directly.
    if [ "$keep_note" -eq 1 ] && [ -n "$SC_NOTE" ] && { [ "$clipboard" -eq 1 ] || [ -t 0 ]; }; then
      sc_to_clipboard "$SC_NOTE" && note_copied=1
    fi
  elif [ "$clipboard" -eq 1 ]; then
    sc_to_clipboard "$transcript"
  fi

  # Last thing on screen, so it's easy to see: the on-screen copy has no
  # scrollback, so a long note loses its top when selected by hand.
  if [ "$note_copied" -eq 1 ]; then
    sc_info ""
    sc_info "Note copied to clipboard — Cmd-V to paste it into your preferred editor."
  fi
  sc_info ""
  if [ -n "$saved" ]; then
    sc_info "The de-identified transcript is saved at $saved; nothing else was written to disk."
  elif [ -n "$saved_for_review" ]; then
    sc_info "The transcript is saved at $saved_for_review; nothing else was written to disk."
  else
    sc_info "Nothing here was written to disk unless you redirected it yourself."
  fi
  if [ "${SC_ALT_SCREEN:-0}" = "1" ]; then
    sc_info "This screen won't appear in your terminal's scrollback."
  fi
}
