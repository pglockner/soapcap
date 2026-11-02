#!/usr/bin/env bash
# Sets up soapcap's tested note models (`soapcap note --model NAME`): builds
# llama-server from PrismML's llama.cpp fork — the runtime soapcap's prompts
# were tested on, and the only one that loads Bonsai's PTQ1_0 weights — then
# downloads each named model, checked against a pinned checksum. Safe to
# re-run; skips whatever is already done. Installs into SOAPCAP_ENGINE_DIR
# (default ~/.local/share/soapcap/engine).
#
#   tools/models/install.sh gemma4-e4b          the default model
#   tools/models/install.sh bonsai              the slower, more careful one
#   tools/models/install.sh gemma4-e4b bonsai   both
set -eu

FORK_URL="https://github.com/PrismML-Eng/llama.cpp.git"
FORK_COMMIT="9a9394a895b96003ca842a6041cb28ac49a108f7"

# pin MODEL — sets LABEL, GGUF_NAME, GGUF_URL, GGUF_SHA256 and GGUF_BYTES for
# MODEL (the files soapcap was tested with), or fails for any other name.
# The file names match lib/common.sh's SOAPCAP_*_GGUF defaults.
pin() {
  case "$1" in
    gemma4-e4b)
      LABEL="Gemma 4 E4B"
      GGUF_NAME="gemma-4-E4B-it-Q4_K_M.gguf"
      GGUF_URL="https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/bfc15c382204943c3a8fff0c750b94ae2364d7a3/$GGUF_NAME"
      GGUF_SHA256="85a896a047553e842f25297ee5b031d64ff30147d9c4af17b1e4b394cd1fab87"
      GGUF_BYTES=4977171584 ;;
    bonsai)
      LABEL="Bonsai 2 27B"
      GGUF_NAME="Ternary-Bonsai-2-27B-PTQ1_0.gguf"
      GGUF_URL="https://huggingface.co/prism-ml/Ternary-Bonsai-2-27B-gguf/resolve/65f27a86966957c534ea6ad12149286e01ca7cc0/$GGUF_NAME"
      GGUF_SHA256="53107f530aa52eb00912263ab1ee29bd199261c87cd7b4ad4ca1318c1fe33ee3"
      GGUF_BYTES=5946648928 ;;
    *) return 1 ;;
  esac
}

die() { echo "models setup: $*" >&2; exit 1; }

case "${1:-}" in
  ""|-h|--help)
    sed -n '2,11s/^# \{0,1\}//p' "$0"
    [ -n "${1:-}" ] && exit 0
    exit 2 ;;
esac
for model in "$@"; do
  pin "$model" || die "unknown model '$model' — use gemma4-e4b or bonsai"
done

dir="${SOAPCAP_ENGINE_DIR:-$HOME/.local/share/soapcap/engine}"
src="$dir/llama.cpp"
server="$src/build/bin/llama-server"

[ "$(uname -m)" = arm64 ] || die "needs an Apple silicon Mac"
mem_gb=$(( $(/usr/sbin/sysctl -n hw.memsize) / 1073741824 ))
case " $* " in
  *" bonsai "*)
    if [ "$mem_gb" -lt 16 ]; then
      echo "Warning: this Mac has ${mem_gb}GB of memory. Bonsai was tested on 16GB and" >&2
      echo "uses most of that while drafting; with less it may swap heavily or fail to load." >&2
    fi ;;
esac

xcrun --find clang >/dev/null 2>&1 || die "needs Apple's command line tools — run: xcode-select --install"
command -v git >/dev/null 2>&1 || die "needs git — run: xcode-select --install"
if ! command -v cmake >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || die "needs cmake — install Homebrew (https://brew.sh), then: brew install cmake"
  echo "==> Installing cmake via Homebrew"
  brew install cmake
fi

mkdir -p "$dir"

# --- 0. a Bonsai setup from before the engine had its own folder ------------
# Its model file moves here rather than downloading again. The rest of that
# folder is the old llama-server build, which can't move (it finds its
# libraries by their old path) and is rebuilt here below, so the folder is
# deleted -- but only once no model file is left in it. If both folders
# have one, the old folder is left for the user to delete.
old="$HOME/.local/share/soapcap/bonsai"
if [ -d "$old" ] && [ "$old" != "$dir" ]; then
  pin bonsai
  if [ -f "$old/$GGUF_NAME" ] && [ ! -f "$dir/$GGUF_NAME" ]; then
    echo "==> Moving Bonsai's model from $old to $dir"
    mv "$old/$GGUF_NAME" "$dir/$GGUF_NAME"
  fi
  if [ -f "$old/$GGUF_NAME" ]; then
    echo "==> $old still holds a copy of Bonsai's model; $dir has one too."
    echo "    Once Bonsai works from the new folder, delete the old one: rm -rf \"$old\""
  else
    rm -rf "$old"
  fi
fi

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

# --- 2. the models ----------------------------------------------------------
sha_ok() { [ "$(shasum -a 256 "$1" | cut -d' ' -f1)" = "$GGUF_SHA256" ]; }

for model in "$@"; do
  pin "$model"
  gguf="$dir/$GGUF_NAME"
  if [ -f "$gguf" ] && echo "==> Checking the existing $LABEL file" && sha_ok "$gguf"; then
    :
  else
    [ -f "$gguf" ] && mv "$gguf" "$gguf.bad"
    # A finished .part (interrupted before the rename) would make a resumed
    # curl fail on every re-run, so only resume one that's still short.
    if [ "$(stat -f %z "$gguf.part" 2>/dev/null || echo 0)" != "$GGUF_BYTES" ]; then
      echo "==> Downloading $LABEL (~$(( (GGUF_BYTES + 500000000) / 1000000000 ))GB, resumable if interrupted)"
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
  echo
  echo "$LABEL is ready."
  printf '  %-34s # use it for one note\n' "soapcap note --model $model FILE"
  printf '  %-34s # or make it the default\n' "soapcap model"
done
if [ "$dir" != "$HOME/.local/share/soapcap/engine" ]; then
  echo "  (installed to a custom location — keep SOAPCAP_ENGINE_DIR=\"$dir\" in ~/.config/soapcap/config.sh)"
fi
