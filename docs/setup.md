# Setup in detail

Manual install steps and the optional extras. The short version is in the
main [README](../README.md#install).

## Installing by hand

```sh
brew install yap jq
ln -s "$PWD/bin/soapcap" "$(brew --prefix)/bin/soapcap"   # optional PATH link
```

## What `doctor` reports

`soapcap doctor`'s expected tail (numbers are this machine's — `doctor` reads yours live via
`sysctl`/`df` and sizes its model advice accordingly; non-Apple-silicon fails
outright):

```
  ok    macOS 26.x
  ok    Apple M5, 16GB unified memory, 10 cores
        16GB: llama3.1:8b (default) works; close memory-heavy apps
        (browsers, other local models) first. bonsai fits too, but uses
        most of this memory while it drafts
  ok    yap 1.2.1 (/opt/homebrew/bin/yap)
  ok    jq 1.8.2 (/opt/homebrew/bin/jq)
  ok    yap ran and returned valid JSON — permissions look granted

  ok    ollama running, llama3.1:8b pulled — 'note' is ready
  ok    Bonsai set up — 'note --model bonsai' is ready
  ok    gum present — 'session' prompts use it for arrow-key choose/confirm
  ok    fzf present — 'note' with no FILE can browse for one

Ready.
```

`ollama`/Bonsai/`gum`/`fzf` lines are informational — `live`/`transcribe` work
without any of them. `install.sh` offers to set up `note` (Ollama +
`llama3.1:8b`) already; by hand:

```sh
brew install ollama
brew services start ollama       # keeps it running across reboots
ollama pull llama3.1:8b          # ~5GB, one time
```

## Nicer prompts and file picking

Two independent, fully optional integrations — `doctor` reports whether
each is present, and nothing breaks without them:

- **[gum](https://github.com/charmbracelet/gum)** replaces `session`'s
  plain `[Y/n]` prompts with a styled confirm and an arrow-key choose menu.
  `install.sh` offers to install it. Without it, `session` falls back to
  the plain prompts exactly as before.
- **[fzf](https://junegunn.github.io/fzf/)** lets `soapcap note` (run with
  no `FILE` and nothing piped in) browse for a transcript interactively
  instead of hanging on stdin waiting for typed input. Searches
  `SOAPCAP_TRANSCRIPT_DIR` (default `$HOME`) for `*.transcript` files.
  Without it, `note` in that situation just tells you to pass a file or
  pipe one in.

Neither changes scripted use (`live | note`, `--format`/`--clipboard`, an
explicit `FILE` argument) at all — both only ever replace a prompt that
would otherwise be plain text or would otherwise block.


## Clickable shortcut

`soapcap.command` at the repo root is a double-clickable entry point —
Finder opens `.command` files in Terminal.app automatically and runs
`soapcap session` there. `install.sh` offers to symlink it onto your
Desktop; by hand:

```sh
ln -sf /path/to/soapcap/soapcap.command ~/Desktop/soapcap.command
```

**First double-click**: not usually needed after a plain `git clone` on the
same Mac, but a copy that crossed machines some other way — the ZIP
download, AirDrop, a USB drive — carries Gatekeeper's quarantine flag.
Current macOS won't offer a direct "Open" button for an unsigned script;
double-click (or right-click → Open) once to trigger the block, then go to
**System Settings → Privacy & Security**, scroll to the Security section,
and click **Open Anyway** next to the `soapcap.command` notice (confirm
with your password/Touch ID, then **Open** once more in the follow-up
dialog). After that it opens normally, no repeat needed.

**Icon**: `install.sh` gives the Desktop shortcut a custom icon
(`assets/soapcap.icns`) via [fileicon](https://github.com/mklement0/fileicon),
offering to install it if missing. Cosmetic only. By hand:

```sh
brew install fileicon
fileicon set ~/Desktop/soapcap.command /path/to/soapcap/assets/soapcap.icns
```

**Updating**: `update.command` is a second double-clickable shortcut that
runs `git pull` in the repo. `install.sh` only adds it for a git clone (a
ZIP download has no `.git` to pull from). By hand:

```sh
ln -sf /path/to/soapcap/update.command ~/Desktop/update.command
fileicon set ~/Desktop/update.command /path/to/soapcap/assets/soapcap-update.icns
```

**Keyboard shortcut:** in Shortcuts.app, add a "Run Shell Script" action
running `/path/to/soapcap/bin/soapcap session`, then assign it a shortcut
in that shortcut's settings.
