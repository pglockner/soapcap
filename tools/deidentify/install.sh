#!/usr/bin/env bash
# Sets up soapcap's optional local de-identification (`soapcap deidentify`):
# a private Python environment with OpenMed's on-device PII model. Needs no
# Python or Xcode on the Mac beforehand: uv (installed via Homebrew if
# missing) downloads its own Python. Safe to re-run; skips whatever is
# already done. Installs into SOAPCAP_DEIDENTIFY_DIR
# (default ~/.local/share/soapcap/deidentify); delete that folder to remove it.
set -eu

PYTHON_VERSION="3.12"
WEIGHTS_SHA256="87fff672bfae2ee052b0c046b5cbe1bc14792b93eaeca2b2526ac6dd2926cdc9"

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dir="${SOAPCAP_DEIDENTIFY_DIR:-$HOME/.local/share/soapcap/deidentify}"
venv="$dir/venv"
launcher="$dir/soapcap-deidentify-helper"

die() { echo "de-identify setup: $*" >&2; exit 1; }

[ "$(uname -m)" = arm64 ] || die "needs an Apple silicon Mac"
if ! command -v uv >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || die "needs uv — install Homebrew (https://brew.sh), then: brew install uv"
  echo "==> Installing uv via Homebrew"
  brew install uv
fi

mkdir -p "$dir"

# --- 1. Python and the pinned packages --------------------------------------
if [ ! -x "$venv/bin/python" ]; then
  echo "==> Creating a private Python $PYTHON_VERSION environment"
  uv venv --quiet --python "$PYTHON_VERSION" "$venv" || die "couldn't create the Python environment"
fi
echo "==> Installing packages (~600MB the first time; log: $dir/install.log)"
if ! uv pip sync --quiet --python "$venv/bin/python" --require-hashes \
       "$here/requirements.txt" >"$dir/install.log" 2>&1; then
  tail -n 20 "$dir/install.log" >&2
  die "package install failed — full log: $dir/install.log"
fi

# --- 2. the launcher soapcap runs --------------------------------------------
cat > "$launcher" <<LAUNCHER
#!/bin/sh
exec "$venv/bin/python" "$here/deidentify.py" "\$@"
LAUNCHER
chmod +x "$launcher"

# --- 3. the model (~130MB; the only step that uses the network at run time) --
echo "==> Downloading the PII model (~130MB, one time; no transcript data involved)"
"$launcher" --fetch 2>"$dir/fetch.log" || { cat "$dir/fetch.log" >&2; die "model download failed — re-run to retry"; }
weights=$(find "$dir/models" -name weights.safetensors | head -n 1)
[ -n "$weights" ] || die "the model's weights weren't downloaded"
if [ "$(shasum -a 256 "$weights" | cut -d' ' -f1)" != "$WEIGHTS_SHA256" ]; then
  die "downloaded weights don't match the tested model's checksum — the upstream file may have changed"
fi

# --- 4. check it works, offline -----------------------------------------------
out=$(printf 'My name is Jordan Fitzgerald.' | "$launcher" 2>/dev/null) || die "the helper doesn't run — see $dir/install.log"
case "$out" in
  *Jordan*|*Fitzgerald*) die "the helper ran but didn't redact a test name" ;;
esac

cat <<DONE

De-identification is ready.
  soapcap deidentify FILE     # redact a transcript
  soapcap session             # now offers to de-identify
DONE
if [ "$dir" != "$HOME/.local/share/soapcap/deidentify" ]; then
  echo "  (installed to a custom location — keep SOAPCAP_DEIDENTIFY_DIR=\"$dir\" in ~/.config/soapcap/config.sh)"
fi
