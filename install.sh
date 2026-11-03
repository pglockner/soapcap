#!/usr/bin/env bash
# soapcap installer — dependencies, PATH symlink, permission check.
set -eu

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

case "${1:-}" in
  -h|--help)
    cat <<'EOF'
Usage: ./install.sh

Installs yap and jq via Homebrew, puts soapcap on your PATH, runs
`soapcap doctor`, then offers each optional piece in turn (Desktop
shortcut, gum, fzf, the note models Gemma 4 E4B and Bonsai, the de-identify
helper). Replaces the retired llama3.1:8b, if it finds it. Safe to re-run.
EOF
    exit 0 ;;
  "") ;;
  *) echo "install.sh takes no arguments (try --help)" >&2; exit 2 ;;
esac

maj=$(sw_vers -productVersion 2>/dev/null | cut -d. -f1)
if [ "${maj:-0}" -lt 26 ] 2>/dev/null; then
  echo "soapcap needs macOS 26 (Tahoe) or newer — found $(sw_vers -productVersion)." >&2
  exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew not found. Install it from https://brew.sh first." >&2
  exit 1
fi

echo "==> Installing yap and jq via Homebrew"
brew install yap jq

prefix=$(brew --prefix)

# `brew install` doesn't always symlink into $prefix/bin — notably when a
# same-named binary already exists there from somewhere else (macOS 26
# itself now ships a /usr/bin/jq). Force it so soapcap actually gets the
# Homebrew-managed one instead of silently falling back to PATH order.
for formula in yap jq; do
  if [ ! -e "$prefix/bin/$formula" ]; then
    echo "==> $formula wasn't linked by Homebrew — linking it"
    brew link --overwrite "$formula"
  fi
done

link="$prefix/bin/soapcap"
if [ -e "$link" ] && [ ! -L "$link" ]; then
  echo "==> $link exists and is not a symlink — skipping PATH link"
else
  echo "==> Linking $link -> $here/bin/soapcap"
  ln -sf "$here/bin/soapcap" "$link"
fi

# --- note models: settings and folder moves ----------------------------------
# Before doctor, so it reports the models where they now are.
cfg="${SOAPCAP_CONFIG:-$HOME/.config/soapcap/config.sh}"
# shellcheck source=lib/model.sh
. "$here/lib/model.sh"   # sc_save_model_config, sc_retired_pulled, sc_retired_fallback
# shellcheck source=lib/install_level.sh
. "$here/lib/install_level.sh"   # sc_install_record

# Settings renamed when Bonsai's llama-server became the engine for every
# tested model; commented-out examples are renamed too.
if [ -f "$cfg" ] && grep -Eq 'SOAPCAP_BONSAI_(DIR|SERVER|PORT)=' "$cfg"; then
  body=$(sed -E 's/SOAPCAP_BONSAI_DIR=/SOAPCAP_ENGINE_DIR=/; s/SOAPCAP_BONSAI_SERVER=/SOAPCAP_LLAMA_SERVER=/; s/SOAPCAP_BONSAI_PORT=/SOAPCAP_ENGINE_PORT=/' "$cfg")
  printf '%s\n' "$body" > "$cfg"   # in place, so a symlinked config.sh stays one
  echo "==> Renamed SOAPCAP_BONSAI_DIR/_SERVER/_PORT in $cfg to"
  echo "    SOAPCAP_ENGINE_DIR, SOAPCAP_LLAMA_SERVER and SOAPCAP_ENGINE_PORT"
fi

# model_ready MODEL — whether soapcap itself would find MODEL set up, with
# config.sh applied (lib/engine.sh). Both read soapcap's settings in a
# subshell, so none of them leak into this script.
model_ready() {
  # shellcheck source=/dev/null
  ( set +eu; SC_ROOT="$here"; . "$here/lib/common.sh"; . "$here/lib/engine.sh"; sc_engine_installed "$1" )
}
# The engine folder soapcap will look in, config.sh's if it sets one, so the
# models installer puts everything there.
# shellcheck source=/dev/null
engine_dir=$( set +eu; . "$here/lib/common.sh"; printf '%s' "$SOAPCAP_ENGINE_DIR" )
# setup_models MODEL... — tools/models/install.sh into that folder. Its "use
# it / make it the default" hints are left out: this script says what's next.
setup_models() {
  SOAPCAP_ENGINE_DIR="$engine_dir" SOAPCAP_MODELS_NO_HINTS=1 "$here/tools/models/install.sh" "$@" \
    || echo "==> Model setup didn't finish — re-run any time: tools/models/install.sh $*"
}
# engine_built — whether tools/models/install.sh would skip building
# llama-server, so a question can leave its few minutes out.
engine_built() { [ -x "$engine_dir/llama.cpp/build/bin/llama-server" ]; }

# A Bonsai setup from before the engine had its own folder: carried over
# without asking, since it was asked for once already. Its download moves;
# the engine is rebuilt.
old_bonsai="$HOME/.local/share/soapcap/bonsai"
if [ -f "$old_bonsai/Ternary-Bonsai-2-27B-PTQ1_0.gguf" ] && [ "$old_bonsai" != "$engine_dir" ]; then
  echo
  echo "==> Moving Bonsai to soapcap's engine folder (rebuilds llama-server, a few minutes)"
  setup_models bonsai
fi

echo
echo "==> Running: soapcap doctor"
echo "    (grant Microphone AND Screen Recording to your terminal in"
echo "     System Settings > Privacy & Security if the probe warns)"
echo
"$here/bin/soapcap" doctor || true

mkdir -p "$HOME/.config/soapcap"

if [ -t 0 ] && [ -d "$HOME/Desktop" ]; then
  echo
  printf "Add a double-clickable shortcut to your Desktop? [Y/n] "
  ans=""
  read -r ans || true
  case "$ans" in
    n|N|no|No) : ;;
    *)
      ln -sf "$here/soapcap.command" "$HOME/Desktop/soapcap.command"
      echo "==> ~/Desktop/soapcap.command -> $here/soapcap.command"
      echo "    First double-click will be blocked by Gatekeeper — see"
      echo "    README 'Clickable shortcut' for the Open Anyway steps."

      if command -v fileicon >/dev/null 2>&1; then
        fileicon set "$HOME/Desktop/soapcap.command" "$here/assets/soapcap.icns" >/dev/null 2>&1 || true
      elif [ -t 0 ]; then
        printf "Give the shortcut a custom icon (installs fileicon via Homebrew)? [Y/n] "
        ans=""
        read -r ans || true
        case "$ans" in
          n|N|no|No) : ;;
          *)
            brew install fileicon
            fileicon set "$HOME/Desktop/soapcap.command" "$here/assets/soapcap.icns" || true
            ;;
        esac
      fi

      # An update shortcut only makes sense for a git clone -- a
      # ZIP-downloaded copy has no .git to pull from, and offering a
      # button that would just error out isn't useful for someone
      # non-technical relying on this shortcut (e.g. a collaborator
      # giving feedback).
      if [ -d "$here/.git" ]; then
        ln -sf "$here/update.command" "$HOME/Desktop/update.command"
        echo "==> ~/Desktop/update.command -> $here/update.command"
        echo "    Double-click it any time to pull the latest soapcap changes."
        if command -v fileicon >/dev/null 2>&1; then
          fileicon set "$HOME/Desktop/update.command" "$here/assets/soapcap-update.icns" >/dev/null 2>&1 || true
        fi
      fi
      ;;
  esac
fi

if [ -t 0 ] && ! command -v gum >/dev/null 2>&1; then
  echo
  printf "Install gum for nicer 'session' prompts (arrow-key choose/confirm instead of plain [Y/n])? [Y/n] "
  ans=""
  read -r ans || true
  case "$ans" in
    n|N|no|No) : ;;
    *) brew install gum ;;
  esac
fi

if [ -t 0 ] && ! command -v fzf >/dev/null 2>&1; then
  echo
  printf "Install fzf so 'note' can browse for a transcript file instead of needing one piped in? [Y/n] "
  ans=""
  read -r ans || true
  case "$ans" in
    n|N|no|No) : ;;
    *) brew install fzf ;;
  esac
fi

# --- note models: what's set up ----------------------------------------------
gemma_ready=0; model_ready gemma4-e4b && gemma_ready=1
bonsai_ready=0; model_ready bonsai && bonsai_ready=1
cfg_model=$(sed -n 's/^SOAPCAP_MODEL="\(.*\)"$/\1/p' "$cfg" 2>/dev/null | tail -n 1)

# --- the retired llama3.1:8b: replace it with Gemma 4 E4B --------------------
# remove_retired — `ollama rm llama3.1:8b`, starting Ollama for it if it
# isn't running, then checks that the model really is gone.
remove_retired() {
  local served=""
  if ! command -v ollama >/dev/null 2>&1; then
    echo "==> llama3.1:8b is still in Ollama's folder, but the ollama command isn't on PATH"
    echo "    to remove it. Reinstall Ollama (brew install ollama), then: ollama rm llama3.1:8b"
    return 0
  fi
  if ! ollama list >/dev/null 2>&1; then
    ollama serve >/dev/null 2>&1 &
    served=$!
    local i=0
    while [ "$i" -lt 30 ] && ! ollama list >/dev/null 2>&1; do sleep 0.5; i=$((i + 1)); done
  fi
  echo "==> Removing llama3.1:8b"
  ollama rm llama3.1:8b || true
  if sc_retired_pulled || ollama list 2>/dev/null | awk 'NR > 1 { print $1 }' | grep -qx 'llama3.1:8b'; then
    echo "==> llama3.1:8b is still there — remove it by hand: ollama rm llama3.1:8b"
  else
    echo "==> llama3.1:8b is gone (~5GB freed)"
    if [ -z "$(ollama list 2>/dev/null | awk 'NR > 1')" ]; then
      echo "    Nothing else is in Ollama, and soapcap no longer needs it. To remove it too:"
      echo "      brew services stop ollama; brew uninstall ollama"
    fi
  fi
  if [ -n "$served" ]; then
    kill "$served" 2>/dev/null || true
    wait "$served" 2>/dev/null || true
  fi
}

# The replacement is offered whenever llama3.1:8b is the default or still
# pulled. Gemma is set up first, and llama3.1:8b removed only once it is, so
# notes keep working if the download fails. Someone whose default is
# another model (Bonsai) is only offered the removal.
kept_retired=0
llama_in_use=0; [ "$cfg_model" = "$SC_RETIRED_MODEL" ] && llama_in_use=1
llama_pulled=0; sc_retired_pulled && llama_pulled=1
if [ "$llama_in_use" -eq 1 ] || [ "$llama_pulled" -eq 1 ]; then
  need_gemma=0
  case "$cfg_model" in "$SC_RETIRED_MODEL"|""|gemma4-e4b) [ "$gemma_ready" -eq 0 ] && need_gemma=1 ;; esac
  echo
  echo "!! llama3.1:8b is retired. soapcap's notes are now tested with Gemma 4 E4B,"
  echo "!! which replaces it as the default. Replacing it is strongly recommended."
  if [ "$need_gemma" -eq 1 ]; then
    build_note=", plus a few minutes to build its engine"
    engine_built && build_note=""
    question="Replace llama3.1:8b with Gemma 4 E4B now (a ~5GB download$build_note; then llama3.1:8b is removed)?"
  elif [ "$llama_in_use" -eq 1 ]; then
    question="Switch your default to Gemma 4 E4B (already set up) and remove llama3.1:8b?"
  else
    question="Remove llama3.1:8b (~5GB) now?"
  fi
  ans=""
  if [ -t 0 ]; then
    printf '%s [Y/n] ' "$question"
    read -r ans || true
  else
    ans=n
  fi
  case "$ans" in
    n|N|no|No)
      kept_retired=1
      echo "==> llama3.1:8b kept for now. Re-run ./install.sh from a terminal any time to replace it." ;;
    *)
      if [ "$need_gemma" -eq 1 ]; then
        setup_models gemma4-e4b
        model_ready gemma4-e4b && gemma_ready=1
      fi
      if [ "$need_gemma" -eq 1 ] && [ "$gemma_ready" -eq 0 ]; then
        kept_retired=1
        echo "==> llama3.1:8b left in place so notes keep working; re-run ./install.sh to try again."
      else
        if [ "$llama_in_use" -eq 1 ]; then
          sc_save_model_config gemma4-e4b
          cfg_model=gemma4-e4b
          echo "==> Default note model set to gemma4-e4b"
        fi
        [ "$llama_pulled" -eq 1 ] && remove_retired
      fi ;;
  esac
fi

# --- one question, offering only what isn't set up yet -------------------------
# Re-running install.sh must never push a download someone has declined, so
# an already-installed model is never offered again, and once any model is
# set up (or llama3.1:8b was just kept) the default answer is to add nothing.
mem_gb=$(( $(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))
offer_bonsai=1
[ "$mem_gb" -lt 16 ] && offer_bonsai=0
choices=()
[ "$gemma_ready" -eq 0 ] && choices+=("gemma4-e4b")
[ "$bonsai_ready" -eq 0 ] && [ "$offer_bonsai" -eq 1 ] && choices+=("bonsai")
[ "${#choices[@]}" -eq 2 ] && choices+=("both")

if [ -t 0 ] && [ "${#choices[@]}" -gt 0 ]; then
  default_choice="${choices[0]}"
  [ "$gemma_ready" -eq 1 ] || [ "$bonsai_ready" -eq 1 ] || [ "$kept_retired" -eq 1 ] && default_choice="skip"
  choices+=("skip")

  echo
  echo "Local note drafting — which model(s)?"
  [ "$gemma_ready" -eq 1 ] && echo "  (gemma4-e4b is already set up)"
  [ "$bonsai_ready" -eq 1 ] && echo "  (bonsai is already set up)"
  i=1
  for c in "${choices[@]}"; do
    case "$c" in
      gemma4-e4b) desc="the default: fast, under two minutes a note — ~5GB" ;;
      bonsai)     desc="slower (a few minutes a note) but more careful — ~6GB" ;;
      both)       desc="both of the above (~11GB)" ;;
      skip)       desc="nothing now — capture and transcription work without a model" ;;
    esac
    printf '  %d) %-12s %s\n' "$i" "$c" "$desc"
    i=$((i + 1))
  done
  engine_built || echo "  (the first model also builds PrismML's llama.cpp fork, a few minutes)"
  printf "Choose [default: %s] " "$default_choice"
  ans=""
  read -r ans || true
  pick="$default_choice"
  if [ -n "$ans" ]; then
    pick=""
    i=1
    for c in "${choices[@]}"; do
      [ "$ans" = "$i" ] || [ "$ans" = "$c" ] && pick="$c"
      i=$((i + 1))
    done
    [ -n "$pick" ] || { echo "==> Not a choice — skipping note models for now"; pick="skip"; }
  fi
  case "$pick" in
    gemma4-e4b) setup_models gemma4-e4b ;;
    bonsai)     setup_models bonsai ;;
    both)       setup_models gemma4-e4b bonsai ;;
  esac
  model_ready gemma4-e4b && gemma_ready=1
  model_ready bonsai && bonsai_ready=1
fi

# Point the default at an installed model when the current one isn't.
current="${cfg_model:-gemma4-e4b}"
new_default=""
if [ "$current" = gemma4-e4b ] && [ "$gemma_ready" -eq 0 ] && [ "$bonsai_ready" -eq 1 ]; then
  new_default="bonsai"
elif [ "$current" = bonsai ] && [ "$bonsai_ready" -eq 0 ] && [ "$gemma_ready" -eq 1 ]; then
  new_default="gemma4-e4b"
fi
if [ -n "$new_default" ]; then
  sc_save_model_config "$new_default"
  echo "==> Default note model set to $new_default (the one that's installed)"
fi
# llama3.1:8b kept and Gemma not set up: before this update llama3.1:8b was
# the default with no setting, so say so in config.sh, or notes would now
# try the missing Gemma.
if [ "$kept_retired" -eq 1 ] && [ "$gemma_ready" -eq 0 ] && sc_retired_fallback; then
  sc_save_model_config "$SC_RETIRED_MODEL"
  echo "==> Default note model kept at llama3.1:8b (saved in config.sh) so notes keep working"
fi

deidentify_ready=0
deidentify_dir="${SOAPCAP_DEIDENTIFY_DIR:-$HOME/.local/share/soapcap/deidentify}"
if [ -x "$deidentify_dir/soapcap-deidentify-helper" ]; then
  deidentify_ready=1
elif [ -t 0 ]; then
  echo
  printf "Set up local de-identification (soapcap deidentify — on-device PII redaction; ~700MB, a few minutes)? [Y/n] "
  ans=""
  read -r ans || true
  case "$ans" in
    n|N|no|No) : ;;
    *)
      if "$here/tools/deidentify/install.sh"; then
        deidentify_ready=1
      else
        echo "==> De-identification setup failed. Re-run it any time: tools/deidentify/install.sh"
      fi
      ;;
  esac
fi

next_msg="
Next:
  soapcap session                                     # guided: capture, then ask about a note"
if [ "$gemma_ready" -eq 1 ] || [ "$bonsai_ready" -eq 1 ]; then
  next_msg="$next_msg
  soapcap model                                       # pick the note model (gemma4-e4b or bonsai)"
fi
if [ "$deidentify_ready" -eq 1 ]; then
  next_msg="$next_msg
  soapcap deidentify FILE                             # best-effort local PII redaction"
fi
next_msg="$next_msg
  cp config.example.sh ~/.config/soapcap/config.sh    # optional config"

# Optional extras: only the ones not set up yet.
extras=""
[ "$gemma_ready" -ne 1 ] && extras="$extras
  tools/models/install.sh gemma4-e4b   Gemma 4 E4B, the default note model (~5GB)"
[ "$bonsai_ready" -ne 1 ] && [ "$offer_bonsai" -eq 1 ] && extras="$extras
  tools/models/install.sh bonsai       Bonsai note model (slower, more careful; ~6GB)"
[ "$deidentify_ready" -ne 1 ] && extras="$extras
  tools/deidentify/install.sh          local PII redaction (~700MB)"
if [ -n "$extras" ]; then
  next_msg="$next_msg

Optional extras, not set up yet (re-run ./install.sh to be offered them, or run):$extras"
fi
sc_install_record   # whatever was answered: soapcap stops offering install.sh
printf '%s\n' "$next_msg"
