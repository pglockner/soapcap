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
shortcut, gum, fzf, note drafting via Ollama + llama3.1:8b, the Bonsai
note model, the de-identify helper). Safe to re-run.
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

# --- note models: one question, offering only what isn't set up yet --------
# Re-running install.sh must never push a download someone has declined, so
# an already-installed model is never offered again, and once any model is
# set up the default answer is to add nothing.
bonsai_dir="${SOAPCAP_BONSAI_DIR:-$HOME/.local/share/soapcap/bonsai}"
ollama_ready=0
[ -f "${OLLAMA_MODELS:-$HOME/.ollama/models}/manifests/registry.ollama.ai/library/llama3.1/8b" ] && ollama_ready=1
bonsai_ready=0
[ -x "$bonsai_dir/llama.cpp/build/bin/llama-server" ] \
  && [ -f "$bonsai_dir/Ternary-Bonsai-2-27B-PTQ1_0.gguf" ] && bonsai_ready=1
mem_gb=$(( $(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 ))

setup_llama() {
  command -v ollama >/dev/null 2>&1 || brew install ollama
  brew services start ollama >/dev/null 2>&1 || true
  echo "==> Pulling llama3.1:8b (~5GB)"
  if ollama pull llama3.1:8b; then
    ollama_ready=1
  else
    echo "==> llama3.1:8b pull failed — retry any time: ollama pull llama3.1:8b"
  fi
}
setup_bonsai() {
  if "$here/tools/bonsai/install.sh"; then
    bonsai_ready=1
  else
    echo "==> Bonsai setup didn't finish — re-run any time: tools/bonsai/install.sh"
  fi
}

offer_bonsai=1
[ "$mem_gb" -lt 16 ] && offer_bonsai=0
choices=()
[ "$ollama_ready" -eq 0 ] && choices+=("llama3.1:8b")
[ "$bonsai_ready" -eq 0 ] && [ "$offer_bonsai" -eq 1 ] && choices+=("bonsai")
[ "${#choices[@]}" -eq 2 ] && choices+=("both")

if [ -t 0 ] && [ "${#choices[@]}" -gt 0 ]; then
  default_choice="${choices[0]}"
  [ "$ollama_ready" -eq 1 ] || [ "$bonsai_ready" -eq 1 ] && default_choice="skip"
  choices+=("skip")

  echo
  echo "Local note drafting — which model(s)?"
  [ "$ollama_ready" -eq 1 ] && echo "  (llama3.1:8b is already set up)"
  [ "$bonsai_ready" -eq 1 ] && echo "  (bonsai is already set up)"
  i=1
  for c in "${choices[@]}"; do
    case "$c" in
      llama3.1:8b) desc="fast, usually under a minute a note — installs Ollama, ~5GB" ;;
      bonsai)      desc="slower (a few minutes) but more careful — builds PrismML's llama.cpp fork, ~6GB" ;;
      both)        desc="both of the above (~11GB)" ;;
      skip)        desc="nothing now — capture and transcription work without a model" ;;
    esac
    printf '  %d) %-12s %s\n' "$i" "$c" "$desc"
    i=$((i + 1))
  done
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
    llama3.1:8b) setup_llama ;;
    bonsai)      setup_bonsai ;;
    both)        setup_llama; setup_bonsai ;;
  esac
fi

# Point the default at an installed model when the current one isn't.
cfg="${SOAPCAP_CONFIG:-$HOME/.config/soapcap/config.sh}"
current=$(sed -n 's/^SOAPCAP_MODEL="\(.*\)"$/\1/p' "$cfg" 2>/dev/null | tail -n 1)
current="${current:-llama3.1:8b}"
new_default=""
if [ "$current" = "llama3.1:8b" ] && [ "$ollama_ready" -eq 0 ] && [ "$bonsai_ready" -eq 1 ]; then
  new_default="bonsai"
elif [ "$current" = "bonsai" ] && [ "$bonsai_ready" -eq 0 ] && [ "$ollama_ready" -eq 1 ]; then
  new_default="llama3.1:8b"
fi
if [ -n "$new_default" ]; then
  if grep -q '^SOAPCAP_MODEL=' "$cfg" 2>/dev/null; then
    sed -i '' "s|^SOAPCAP_MODEL=.*|SOAPCAP_MODEL=\"$new_default\"|" "$cfg"
  else
    printf 'SOAPCAP_MODEL="%s"\n' "$new_default" >> "$cfg"
  fi
  echo "==> Default note model set to $new_default (the one that's installed)"
fi

deidentify_ready=0
if [ -t 0 ] && [ ! -x "$here/tools/deidentify-helper/.build/release/soapcap-deidentify-helper" ]; then
  # Confirmed on two separate machines: plain Xcode Command Line Tools is
  # NOT enough here (mlx-swift's Metal shaders need the Metal Toolchain
  # component, and xcodebuild -downloadComponent itself refuses to run
  # under a CLT-only selection -- "requires Xcode"). Rather than trying
  # to fix any of this interactively (a full Xcode install is a multi-GB,
  # App-Store-gated thing install.sh has no business attempting), just
  # check and point to the real requirements table.
  deidentify_missing=""
  command -v swift >/dev/null 2>&1 || deidentify_missing="${deidentify_missing}swift "
  case "$(xcode-select -p 2>/dev/null)" in
    *CommandLineTools|"") deidentify_missing="${deidentify_missing}full-Xcode " ;;
  esac
  # `xcrun --find metal` only locates a binary -- on a CLT-only-turned-full-Xcode
  # machine it can find a stub that itself refuses to run until the Metal
  # Toolchain component is actually downloaded. Invoke it for real instead.
  xcrun metal --version >/dev/null 2>&1 || deidentify_missing="${deidentify_missing}Metal-Toolchain "

  if [ -n "$deidentify_missing" ]; then
    echo
    echo "==> Skipping the local de-identification helper (soapcap deidentify) —"
    echo "    missing: $deidentify_missing"
    echo "    See tools/deidentify-helper/README.md \"Requirements\" for what each"
    echo "    one needs and how much effort it is (full Xcode, not just Command"
    echo "    Line Tools, is the big one). Re-run install.sh once they're in"
    echo "    place, or build by hand later: cd tools/deidentify-helper && swift build -c release"
  else
    echo
    printf "Build the local de-identification helper (soapcap deidentify — Swift + OpenMedKit, on-device PII redaction)? [Y/n] "
    ans=""
    read -r ans || true
    case "$ans" in
      n|N|no|No) : ;;
      *)
        echo "==> Building tools/deidentify-helper (swift build -c release)…"
        if (cd "$here/tools/deidentify-helper" && swift build -c release); then
          deidentify_ready=1
          echo "==> Built. Warming up (downloads the privacy-filter model's weights once, no transcript data involved)…"
          "$here/tools/deidentify-helper/.build/release/soapcap-deidentify-helper" <<<"warm up" >/dev/null 2>&1 || true
        else
          echo "==> Build failed. If the error mentions a license, run: sudo xcodebuild -license accept"
          echo "    Otherwise see tools/deidentify-helper/README.md \"Requirements\", then re-run"
          echo "    install.sh, or build by hand: cd tools/deidentify-helper && swift build -c release"
        fi
        ;;
    esac
  fi
fi

next_msg="
Next:
  soapcap session                                     # guided: capture, then ask about a note"
if [ "$ollama_ready" -eq 1 ] || [ "$bonsai_ready" -eq 1 ]; then
  next_msg="$next_msg
  soapcap model                                       # pick the note model (llama3.1:8b or bonsai)"
fi
if [ "$deidentify_ready" -eq 1 ]; then
  next_msg="$next_msg
  soapcap deidentify FILE                             # best-effort local PII redaction"
fi
next_msg="$next_msg
  cp config.example.sh ~/.config/soapcap/config.sh    # optional config"
if [ "$ollama_ready" -ne 1 ] && [ "$bonsai_ready" -ne 1 ]; then
  next_msg="$next_msg

To draft notes locally later, re-run ./install.sh and pick a model, or:
  brew install ollama && brew services start ollama && ollama pull llama3.1:8b
  tools/bonsai/install.sh       # the slower, more careful alternative"
fi
if [ "$deidentify_ready" -ne 1 ]; then
  next_msg="$next_msg

To build the (optional) local de-identification helper later:
  cd tools/deidentify-helper && swift build -c release"
fi
next_msg="$next_msg

Optional extras (each README lists requirements and steps):
  tools/bonsai/install.sh    Bonsai note model (slower, more careful; ~6GB)
  tools/deidentify-helper/   local PII redaction (needs full Xcode)
  tools/session-app/         experimental window app (needs Xcode + a signing identity)"
printf '%s\n' "$next_msg"
