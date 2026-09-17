#!/usr/bin/env bash
# soapcap installer — dependencies, PATH symlink, permission check.
set -eu

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

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

ollama_ready=0
if [ -t 0 ]; then
  echo
  printf "Set up local note drafting now (installs Ollama, downloads llama3.1:8b, ~5GB)? [Y/n] "
  ans=""
  read -r ans || true
  case "$ans" in
    n|N|no|No) : ;;
    *)
      command -v ollama >/dev/null 2>&1 || brew install ollama
      brew services start ollama >/dev/null 2>&1 || true
      echo "==> Pulling llama3.1:8b (default model, ~5GB)"
      if ollama pull llama3.1:8b; then
        ollama_ready=1
        # llama3.1:8b is the safe, already-tested default; offer to also
        # pick/pull one of the other tested models (or, with an extra
        # warning, an untested larger one for 32GB+ systems) right away.
        # SOAPCAP_NO_GUM keeps this plain-text even if gum was just
        # installed a few prompts ago -- install.sh stays plain
        # throughout rather than switching styles partway through.
        echo
        SOAPCAP_NO_GUM=1 "$here/bin/soapcap" model || true
      fi
      ;;
  esac
fi

deidentify_ready=0
if [ -t 0 ] && [ ! -x "$here/tools/deidentify-helper/.build/release/soapcap-deidentify-helper" ]; then
  echo
  printf "Build the local de-identification helper (soapcap deidentify — Swift + OpenMedKit, on-device PII redaction; needs Xcode Command Line Tools)? [Y/n] "
  ans=""
  read -r ans || true
  case "$ans" in
    n|N|no|No) : ;;
    *)
      if ! command -v swift >/dev/null 2>&1; then
        echo "==> swift not found. Install Xcode Command Line Tools first:"
        echo "        xcode-select --install"
        echo "    then re-run install.sh (or build by hand later — see README 'De-identify')."
      else
        # A fresh Xcode/CLT install doesn't always include the Metal
        # Toolchain (needed to compile mlx-swift's GPU shader code) --
        # confirmed on two separate machines, both failing on the very
        # first build attempt with the same error. Check and offer this
        # as its own opt-in step, same shape as every other optional
        # piece in this script, rather than only reacting to the failure
        # after the fact.
        if ! xcrun --find metal >/dev/null 2>&1; then
          echo
          printf "Also need the Metal Toolchain to compile this (one-time, ~840MB — Apple's own component, via xcodebuild). Download it now? [Y/n] "
          ans=""
          read -r ans || true
          case "$ans" in
            n|N|no|No)
              echo "==> Skipping — the build below will likely fail until you run:"
              echo "        xcodebuild -downloadComponent MetalToolchain"
              ;;
            *)
              echo "==> Downloading the Metal Toolchain (can take a while on a slow connection)…"
              xcodebuild -downloadComponent MetalToolchain || true
              ;;
          esac
        fi
        echo "==> Building tools/deidentify-helper (swift build -c release)…"
        if (cd "$here/tools/deidentify-helper" && swift build -c release); then
          deidentify_ready=1
          echo "==> Built. Warming up (downloads the privacy-filter model's weights once, no transcript data involved)…"
          "$here/tools/deidentify-helper/.build/release/soapcap-deidentify-helper" <<<"warm up" >/dev/null 2>&1 || true
        else
          echo "==> Build failed. If the error mentions a license, run: sudo xcodebuild -license accept"
          echo "    If it mentions the Metal Toolchain, run: xcodebuild -downloadComponent MetalToolchain"
          echo "    Otherwise ensure Xcode Command Line Tools are installed (xcode-select --install),"
          echo "    then re-run install.sh, or build by hand: cd tools/deidentify-helper && swift build -c release"
        fi
      fi
      ;;
  esac
fi

next_msg="
Next:
  soapcap session                                     # guided: capture, then ask about a note"
if [ "$ollama_ready" -eq 1 ]; then
  next_msg="$next_msg
  soapcap model                                       # pick/change the note-drafting model"
fi
if [ "$deidentify_ready" -eq 1 ]; then
  next_msg="$next_msg
  soapcap deidentify FILE                             # best-effort local PII redaction"
fi
next_msg="$next_msg
  cp config.example.sh ~/.config/soapcap/config.sh    # optional config"
if [ "$ollama_ready" -ne 1 ]; then
  next_msg="$next_msg

To draft notes locally (optional — a ~5GB one-time download):
  brew install ollama
  brew services start ollama
  ollama pull llama3.1:8b
  soapcap session               # or: soapcap live | soapcap note"
fi
if [ "$deidentify_ready" -ne 1 ]; then
  next_msg="$next_msg

To build the (optional) local de-identification helper later:
  cd tools/deidentify-helper && swift build -c release"
fi
printf '%s\n' "$next_msg"
