#!/usr/bin/env bash
# Sets up soapcap's optional Bonsai note model (`soapcap note --model bonsai`):
# builds llama-server from PrismML's llama.cpp fork — the only runtime that
# can load Bonsai's PTQ1_0 weights — and downloads the model. Safe to re-run;
# skips whatever is already done. Installs into SOAPCAP_BONSAI_DIR
# (default ~/.local/share/soapcap/bonsai).
set -eu

FORK_URL="https://github.com/PrismML-Eng/llama.cpp.git"
FORK_COMMIT="9a9394a895b96003ca842a6041cb28ac49a108f7"
GGUF_NAME="Ternary-Bonsai-2-27B-PTQ1_0.gguf"
GGUF_REV="65f27a86966957c534ea6ad12149286e01ca7cc0"
GGUF_URL="https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf/resolve/$GGUF_REV/$GGUF_NAME"
GGUF_SHA256="53107f530aa52eb00912263ab1ee29bd199261c87cd7b4ad4ca1318c1fe33ee3"
GGUF_BYTES=5946648928

dir="${SOAPCAP_BONSAI_DIR:-$HOME/.local/share/soapcap/bonsai}"
src="$dir/llama.cpp"
server="$src/build/bin/llama-server"
gguf="$dir/$GGUF_NAME"

die() { echo "bonsai setup: $*" >&2; exit 1; }

[ "$(uname -m)" = arm64 ] || die "needs an Apple silicon Mac"
mem_gb=$(( $(/usr/sbin/sysctl -n hw.memsize) / 1073741824 ))
if [ "$mem_gb" -lt 16 ]; then
  echo "Warning: this Mac has ${mem_gb}GB of memory. Bonsai was tested on 16GB and" >&2
  echo "uses most of that while drafting; with less it may swap heavily or fail to load." >&2
fi

xcrun --find clang >/dev/null 2>&1 || die "needs Apple's command line tools — run: xcode-select --install"
command -v git >/dev/null 2>&1 || die "needs git — run: xcode-select --install"
if ! command -v cmake >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || die "needs cmake — install Homebrew (https://brew.sh), then: brew install cmake"
  echo "==> Installing cmake via Homebrew"
  brew install cmake
fi

mkdir -p "$dir"

# --- 1. llama-server, pinned to the fork commit soapcap was tested with -----
if [ "$(git -C "$src" rev-parse HEAD 2>/dev/null || true)" != "$FORK_COMMIT" ]; then
  if [ -e "$src" ] && [ ! -d "$src/.git" ]; then
    die "$src exists but isn't a git checkout — move it aside and re-run"
  fi
  echo "==> Fetching PrismML's llama.cpp fork (commit ${FORK_COMMIT:0:9})"
  if [ ! -d "$src/.git" ]; then
    git init -q "$src"
    git -C "$src" remote add origin "$FORK_URL"
  fi
  git -C "$src" fetch -q --depth 1 origin "$FORK_COMMIT"
  git -C "$src" checkout -q --detach FETCH_HEAD
  rm -rf "$src/build"
fi

if [ ! -x "$server" ]; then
  echo "==> Building llama-server (a few minutes; log: $dir/build.log)"
  if ! { cmake -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=Release \
           -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
         && cmake --build "$src/build" --config Release --target llama-server \
              -j "$(/usr/sbin/sysctl -n hw.ncpu)"; } >"$dir/build.log" 2>&1; then
    tail -n 20 "$dir/build.log" >&2
    die "build failed — full log: $dir/build.log"
  fi
fi
"$server" --version >/dev/null 2>&1 || die "built llama-server doesn't run — see $dir/build.log"

# --- 2. the model -----------------------------------------------------------
sha_ok() { [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$GGUF_SHA256" ]; }

if [ -f "$gguf" ] && echo "==> Checking the existing model file" && sha_ok "$gguf"; then
  :
else
  [ -f "$gguf" ] && mv "$gguf" "$gguf.bad"
  # A finished .part (interrupted before the rename) would make a resumed
  # curl fail on every re-run, so only resume one that's still short.
  if [ "$(stat -f %z "$gguf.part" 2>/dev/null || echo 0)" != "$GGUF_BYTES" ]; then
    echo "==> Downloading Bonsai 2 27B (~6GB, resumable if interrupted)"
    curl -fL --retry 3 -C - -o "$gguf.part" "$GGUF_URL" || die "download failed — re-run to resume"
  fi
  echo "==> Verifying the download"
  if ! sha_ok "$gguf.part"; then
    rm -f "$gguf.part"
    die "downloaded file doesn't match the tested model's checksum — the upstream file may have changed"
  fi
  mv "$gguf.part" "$gguf"
  rm -f "$gguf.bad"
fi

cat <<EOF

Bonsai is ready.
  soapcap note --model bonsai FILE     # use it for one note
  soapcap model                        # or make it the default
EOF
if [ "$dir" != "$HOME/.local/share/soapcap/bonsai" ]; then
  echo "  (installed to a custom location — keep SOAPCAP_BONSAI_DIR=\"$dir\" in ~/.config/soapcap/config.sh)"
fi
