# shellcheck shell=bash
# The install level: which of soapcap's setup changes install.sh has carried
# out on this Mac. A change that needs install.sh to run again (a new default
# model, a moved folder, a renamed setting) bumps SC_INSTALL_LEVEL and says
# why in SC_INSTALL_WHY. install.sh records the level when it finishes;
# until then soapcap offers to run it (sc_install_offer), and update.command
# runs it after a pull. The level checks need nothing else from lib/, so
# install.sh and update.command source this file on its own;
# sc_install_offer runs inside soapcap.

SC_INSTALL_LEVEL=1
SC_INSTALL_WHY="Gemma 4 E4B replaces the retired llama3.1:8b as the default note model"

# The record: machine state rather than a config.sh setting, since it says
# what is set up on this Mac.
sc_install_level_file() { printf '%s' "$HOME/.local/share/soapcap/install-level"; }

# sc_install_current — true once install.sh has finished at this level (or a
# later one).
sc_install_current() {
  local have
  have=$(cat "$(sc_install_level_file)" 2>/dev/null)
  case "$have" in ''|*[!0-9]*) have=0 ;; esac
  [ "$have" -ge "$SC_INSTALL_LEVEL" ]
}

# sc_install_record — called by install.sh when it finishes, whatever was
# answered along the way.
sc_install_record() {
  mkdir -p "$(dirname "$(sc_install_level_file)")"
  printf '%s\n' "$SC_INSTALL_LEVEL" > "$(sc_install_level_file)"
}

# sc_install_offer SOAPCAP_ARGS... — before a command runs: while install.sh
# hasn't finished at this level, offers to run it (from a terminal) or says
# it's needed (without one), then lets the command go on either way. After
# a yes, soapcap starts over with the same arguments, so the config and
# model paths install.sh just changed are read afresh; SC_INSTALL_OFFERED
# keeps that second start (or one after an install.sh that didn't finish)
# from asking again. Going on without install.sh keeps notes drafting where
# llama3.1:8b still can (sc_retired_fallback), for this run only: nothing
# is saved until install.sh runs.
sc_install_offer() {
  sc_install_current && return 0
  if [ -z "${SC_INSTALL_OFFERED:-}" ] && [ -t 0 ]; then
    sc_info "This soapcap update needs install.sh to finish: $SC_INSTALL_WHY."
    if sc_confirm "Run $SC_ROOT/install.sh now?"; then
      # stdout too goes to the terminal, never down a pipe soapcap writes to.
      "$SC_ROOT/install.sh" >&2 \
        || sc_err "install.sh didn't finish — going on without it; re-run it any time: $SC_ROOT/install.sh"
      SC_INSTALL_OFFERED=1 exec "$SC_ROOT/bin/soapcap" "$@"
    fi
    sc_info "Going on without it; soapcap will ask again next time."
  elif [ -z "${SC_INSTALL_OFFERED:-}" ]; then
    sc_info "soapcap: this update needs $SC_ROOT/install.sh ($SC_INSTALL_WHY) — run it from a terminal."
  fi
  if [ "$SOAPCAP_MODEL" = gemma4-e4b ] && ! sc_engine_installed gemma4-e4b && sc_retired_fallback; then
    SOAPCAP_MODEL="$SC_RETIRED_MODEL"
    sc_info "Until then, notes use llama3.1:8b, the old default."
  fi
  # Said just now; the note's own retired-model warning would repeat it.
  # shellcheck disable=SC2034  # read by sc_retired_notice (lib/model.sh)
  SC_RETIRED_WARNED=1
}
