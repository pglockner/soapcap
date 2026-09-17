# soapcap

Capture a **speaker-attributed transcript of a telehealth session** on a Mac
using only Apple's on-device speech recognition — no cloud, no Whisper
download, no virtual audio devices, and by default **nothing written to
disk**.

`soapcap note` then drafts a SOAP/DAP/BIRP note from that transcript with a
**local Ollama model** — nothing leaves the machine. A cloud path
(SoapNoteAI/Upheal) isn't built yet; see [Roadmap](#roadmap).

---

## How it works

```
Zoom / Meet / Teams / Doxy.me                   your microphone
        (system audio)                                 │
              │                                        │
              └──────────►  yap listen-and-dictate  ◄──┘
                           (Apple SpeechAnalyzer,
                            fully on-device)
                                    │  JSON, via a $TMPDIR file
                                    │  deleted on every exit path
                                    ▼
                           soapcap render
                                    │
                                    ▼
                    Therapist: ...          ← stdout (default)
                    Client: ...             ← or --out FILE
                                    │
                                    ▼  soapcap note
                              Ollama (local)
                                    │
                                    ▼
                    SUBJECTIVE: ...         ← stdout (default)
                    OBJECTIVE: ...          ← or --out FILE
```

`soapcap` never talks to Zoom or any meeting API — it captures **system
audio** (whatever your Mac is playing) plus your **microphone**, so it works
with any conferencing tool.

---

## Requirements

- **macOS 26 (Tahoe) or newer, Apple silicon.** Non-negotiable — `yap`
  hard-fails on anything older or on Intel.
- [Homebrew](https://brew.sh)
- **Headphones recommended, not required.** See
  [Without headphones](#without-headphones).
- **For `note`**: [Ollama](https://ollama.com) and ~5GB free memory beyond
  whatever else is running (default model `llama3.1:8b`). Optional — capture
  and transcription work without it.
- **Optional polish**, both auto-detected, neither required: **gum** (nicer
  `session` prompts) and **fzf** (browse for a transcript file in `note`).
  See [Nicer prompts and file picking](#nicer-prompts-and-file-picking).

---

## Install

```sh
git clone https://github.com/pglockner/soapcap.git
cd soapcap
./install.sh          # brew install yap jq (force-linked — macOS 26 ships
                       # its own /usr/bin/jq, which can otherwise shadow
                       # Homebrew's), symlink onto PATH, run doctor,
                       # offer a Desktop shortcut + gum + fzf, offer to
                       # install Ollama and pull llama3.1:8b
```

No git installed? Click **Code → Download ZIP** on the
[GitHub page](https://github.com/pglockner/soapcap), unzip it, then `cd`
into the extracted folder and run `./install.sh` the same way — nothing in
soapcap depends on `.git` being present.

Or by hand:

```sh
brew install yap jq
ln -s "$PWD/bin/soapcap" "$(brew --prefix)/bin/soapcap"   # optional PATH link
```

Grant permissions **to the terminal app you run `soapcap` from** (Terminal,
iTerm, etc.), then fully quit and reopen it:

1. **System Settings → Privacy & Security → Microphone** → enable your terminal
2. **System Settings → Privacy & Security → Screen Recording** → enable your
   terminal (system-audio capture rides on this permission)

Then verify:

```sh
soapcap doctor
```

Expected tail (numbers are this machine's — `doctor` reads yours live via
`sysctl`/`df` and sizes its model advice accordingly; non-Apple-silicon fails
outright):

```
  ok    macOS 26.x
  ok    Apple M5, 16GB unified memory, 10 cores
        16GB: llama3.1:8b (default) works, but close memory-heavy apps
        (browsers, other local models) first. Comfortable otherwise:
        soapcap note --model llama3.2:3b
  ok    yap 1.2.1 (/opt/homebrew/bin/yap)
  ok    jq 1.8.2 (/opt/homebrew/bin/jq)
  ok    yap ran and returned valid JSON — permissions look granted

  ok    ollama running, llama3.1:8b pulled — 'note' is ready
  ok    gum present — 'session' prompts use it for arrow-key choose/confirm
  ok    fzf present — 'note' with no FILE can browse for one

Ready.
```

`ollama`/`gum`/`fzf` lines are informational — `live`/`transcribe` work
without any of them. `install.sh` offers to set up `note` (Ollama +
`llama3.1:8b`) already; by hand:

```sh
brew install ollama
brew services start ollama       # keeps it running across reboots
ollama pull llama3.1:8b          # ~5GB, one time
```

Change the model `session`/`note` default any time with `soapcap model` —
see [Draft a note](#draft-a-note).

Optional config: `cp config.example.sh ~/.config/soapcap/config.sh` and edit
(speaker labels, locale, note model/format, dedupe tuning).

---

## Usage

### Live session

```sh
soapcap live
```

1. Start your session in Zoom/Meet/Teams/etc.
2. Turn on **Do Not Disturb** — a stray notification sound lands in the
   transcript otherwise.
3. Run `soapcap live`. A one-line timer shows it's recording.
4. **q, x, or Ctrl-C** stop for good; **p or space** pauses — see
   [Pause/resume](#pauseresume). No keyboard available (backgrounded or
   scripted)? `kill -TERM` stops it the same way Ctrl-C would, no pause.

`yap` finalizes and the transcript prints to stdout:

```
Therapist: How have things been since we last met?
Client: Honestly pretty rough. I haven't been sleeping.
Therapist: Tell me about the sleep.
...
```

Write it to a file instead (this file contains PHI — you own its deletion):

```sh
soapcap live --out ~/sessions/2026-09-10.transcript
```

Other flags: `--mic-label`, `--system-label`, `--locale`, `--keep-json FILE`
(also save the raw `yap` JSON with timestamps), `--clipboard`.

### Existing recording

```sh
soapcap transcribe recording.m4a
soapcap transcribe recording.m4a --out out.transcript
```

For a file you already have (e.g. a QuickTime capture headed to Upheal, or a
test clip). No speaker separation — single audio track, every line is
`Speaker:`.

### Draft a note

```sh
soapcap live | soapcap note                       # pipe straight through
soapcap note ~/sessions/2026-09-10.transcript      # or from a saved file
soapcap note --format dap --out ~/notes/draft.md   # DAP instead of SOAP
```

Sends the transcript to a **local** Ollama model (default `llama3.1:8b`).
The prompt (`prompts/*.md` — read or edit it directly) requires: use only
what's in the transcript, never assign an undiscussed diagnosis, always
surface anything suggesting risk (self-harm, harm to others, abuse, crisis),
and write "Not addressed in this session" rather than pad a section out.
Formats: `soap` (default), `dap`, `birp`.

**Read every note before it goes near a chart.** It's still an LLM. Mistakes
concentrate in the Objective section, the one part that requires telling an
actual in-the-room observation apart from a client's own description of how
they've been feeling — a smaller model can either invent detail that isn't
there or miss detail that is. As a backstop, `sc_generate_note` also strips
an occasional unprompted "Note: ..." aside some models append despite being
told not to. Both are help, not a guarantee.

`note` sizes Ollama's context window (`num_ctx`) to the actual prompt length
instead of trusting Ollama's small default — a long transcript that
exceeded the default silently produced malformed notes (invented section
headers, repeated paragraphs, PII echoed verbatim) with no error at all.

**Models:**

| Model | Size | Notes |
|---|---|---|
| `llama3.1:8b` | ~5GB | Best balance of reliability and speed. **Default.** Doesn't invent observations, but can under-read a client's own present-moment reaction ("I'm getting choked up") as just a general feeling rather than something that happened in the room. |
| `llama3.2:3b` | ~2GB | Fastest and lightest, but prone to inventing plausible-sounding clinical detail that isn't in the transcript. Only worth it under real memory pressure. |
| `qwen2.5:14b` | ~9GB | Most reliable at catching real Objective-section detail, including a client's own in-the-moment reactions. ~2.5x the generation time and more RAM headroom; occasionally adds a little unstated color rather than bare extraction. |
| `qwen3:30b` | ~19GB (32GB+ systems) | **Untested.** Mixture-of-experts (3B active params), so faster than its size suggests. |
| `gemma3:27b` | ~17GB (32GB+ systems) | **Untested.** Dense 27B; different failure modes than the Qwen models, worth comparing. |

`qwen3:30b`/`gemma3:27b` are untested here by necessity — this project's
development machine only has 16GB. See [`sc_model_catalog`](lib/commands.sh)
for the authoritative, current list (this table mirrors it).

**`soapcap model`** shows this table live (with which models are actually
pulled) and, interactively, lets you pick one — pulling it via `ollama pull`
if needed, with an extra confirmation for anything untested — and saves
the pick as the new default for `session`/`note` (`--model` still overrides
per-run). `session` itself no longer asks; it just uses whatever's
configured.

Other flags: `--host URL`, `--clipboard`.

### De-identify

```sh
soapcap live | soapcap deidentify | soapcap note
soapcap deidentify ~/sessions/2026-09-10.transcript --out ~/sessions/2026-09-10.deid.transcript
```

Runs a transcript through a small **on-device** PII detection model
([OpenMedKit](https://github.com/maziyarpanahi/openmed)'s Privacy Filter,
via Apple's MLX runtime — Apple Silicon only, same as the rest of
soapcap) and replaces detected names, phone numbers, emails, addresses,
and similar identifiers with consistent bracketed placeholders
(`[FIRST_NAME_1]`, `[PHONE_1]`, …) — the same person or detail gets the
same placeholder everywhere it's tagged, so a note drafted from the
result still reads coherently. Speaker labels (`Therapist:`/`Client:`)
are never touched, even if a label happens to be someone's real name.

Needs the `tools/deidentify-helper` Swift binary — `install.sh` checks
the requirements and offers to build it if they're met (full Xcode, not
just Command Line Tools — see
[tools/deidentify-helper/README.md](tools/deidentify-helper/README.md#requirements)
for the complete list and how much effort each one is), or build it by
hand:

```sh
cd tools/deidentify-helper && swift build -c release
```

First real run also downloads the Privacy Filter model's weights
(one-time, no transcript data involved).

**This one feature does need git and network access to GitHub**, unlike
the rest of soapcap — building it resolves a Swift package dependency
([OpenMedKit](https://github.com/maziyarpanahi/openmed)) via `git clone`
under the hood. Nothing else in soapcap needs git (see [Install](#install)
— the ZIP-download path works fine for everything else); git comes
bundled with the full Xcode install this feature already needs, so it
isn't a separate install — just worth knowing this specific feature
reaches out to GitHub (and, on first real use, Hugging Face for the
model weights) during setup.

**This is a best-effort pass, not a certified de-identification.** It
redacts what OpenMedKit's model tags and nothing more — a missed mention
stays in the output verbatim, and the output is still confidential
clinical material. Read it before sending it anywhere. See
[Legal](#legal--read-before-first-use).

Other flags: `--out FILE`, `--clipboard`.

### Guided session

```sh
soapcap session
```

The scriptable path above assumes you remember the pipe syntax. `session`
instead captures live, reports the transcript's line count and asks **"Show
the transcript?"**, then asks **"Draft a note from this?"**, **"Format?"**,
and after drafting, **"This draft: keep / regenerate / discard"** — LLM
output is stochastic, so a weak draft is often just an unlucky roll.
`regenerate` drafts again with the same model and transcript, looping for
as many attempts as you want; `discard` ends the session with no note at
all rather than forcing another attempt. Once you `keep` one, it asks
**"Copy the note to the clipboard?"**. Enter takes the sensible default
every time (yes, yes, soap, keep, yes); without [gum](#nicer-prompts-and-file-picking),
every prompt also takes a bare first letter when it's unambiguous (`r` for
regenerate, `b` for birp). `--format`, `--no-note`, `--clipboard`, `--model`
skip the corresponding prompt for scripted use; every `live`/`note` flag
still applies. `session` always uses the model configured via
[`soapcap model`](#draft-a-note) (or `--model`) — it doesn't ask. This is
exactly what double-clicking `soapcap.command` runs — see
[Clickable shortcut](#clickable-shortcut).

### Pause/resume

Press **p** (or space) while recording; **p** again to resume. This is a
real pause, not cosmetic — it stops `yap` the same clean way Ctrl-C does,
so nothing is captured while paused, then starts a fresh capture on
resume. Multiple pause/resume cycles are stitched into one transcript
afterward, in order.

Keypresses need a real terminal (`soapcap.command` and a normal interactive
run both qualify). Backgrounded/piped invocations fall back to signal-only
control — Ctrl-C / `kill -TERM` to stop, no pause.

### Nicer prompts and file picking

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

---

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

This stays a plain tracked shell script rather than a compiled `.app` on
purpose — a `.app` would need Xcode/Automator and a committed binary,
rebuilt after every change; the symlinked script always runs current code.

**Icon**: `install.sh` gives the Desktop shortcut a custom icon
(`assets/soapcap.icns`) via [fileicon](https://github.com/mklement0/fileicon)
if it's installed, or offers to install it — purely cosmetic, skip it and
the shortcut just shows the generic script icon. By hand:

```sh
brew install fileicon
fileicon set ~/Desktop/soapcap.command /path/to/soapcap/assets/soapcap.icns
```

**Updating**: `update.command` is a second double-clickable shortcut that
runs `git pull` in the repo — handy for sharing soapcap with someone
non-technical (a collaborator giving feedback, say) who just needs to grab
the latest changes without touching the terminal directly. `install.sh`
only adds this one to the Desktop when the install is an actual git clone
— a ZIP download has no `.git` to pull from, and the script says so
plainly rather than erroring if run anyway. By hand:

```sh
ln -sf /path/to/soapcap/update.command ~/Desktop/update.command
fileicon set ~/Desktop/update.command /path/to/soapcap/assets/soapcap-update.icns
```

**Want a real keyboard shortcut?** Not shipped (a `.shortcut` file is a
binary asset with the same staleness problem), but easy by hand: in
Shortcuts.app, add a "Run Shell Script" action running
`/path/to/soapcap/bin/soapcap session`, then assign it a shortcut from the
saved shortcut's own settings.

---

## Without headphones

`yap`'s speaker labels are **which audio source** picked up the words, not a
voiceprint — Apple's Speech framework has no public on-device
speaker-diarization API. Without headphones there's a real but
**one-directional** leak: whatever plays through your speakers is
acoustically audible in the room, so your mic hears it too and transcribes
it a second time under your label. It doesn't happen in reverse — your
voice never loops back into system audio.

`soapcap live` runs a **dedupe pass** by default: a mic-side segment whose
wording is largely *contained in* a system-side segment nearby in time is
dropped as an echo. Deliberately conservative — a missed echo is a harmless
duplicate line, a wrongly dropped real segment is data loss. Tunable via env
/ `~/.config/soapcap/config.sh`:

```sh
SOAPCAP_DEDUPE_WINDOW=3.5      # seconds of timing slack
SOAPCAP_DEDUPE_THRESHOLD=0.7   # word-containment ratio (0–1) to call it an echo
SOAPCAP_DEDUPE_MINWORDS=2      # segments shorter than this are never dropped
```

`--no-dedupe` shows the raw, undeduplicated output. `SOAPCAP_DEDUPE_MINWORDS`
deliberately lets a single leftover word through unfiltered rather than risk
dropping a real short line — expect the occasional one-word duplicate as a
result.

Headphones remain the more reliable fix regardless — a single earbud is
enough, and you're not straining to hear the session through a laptop
speaker either.

### Real diarization (FluidAudio)

Actual voice-based diarization exists on-device via
[FluidAudio](https://github.com/FluidInference/FluidAudio) (Swift/CoreML,
Neural Engine, no cloud call) but isn't wired in — it diarizes **recorded
audio**, which `yap` never produces on the `live` path (a real change to
[Retention](#retention)), needs a Swift build and Hugging Face model
download, and would mean a custom capture helper instead of gluing existing
CLIs. Worth it if the dedupe pass proves insufficient in practice; not
attempted.

---

## Retention

- **No audio file is ever created on the `live` path** — `yap
  listen-and-dictate` transcribes in real time and never records audio.
  Nothing to clean up, by construction.
- **With no flags, nothing survives the run.** `yap` writes its growing
  JSON to a single file in a `chmod 700` `$TMPDIR` directory (holding only
  that and `yap`'s stderr); every exit path — normal stop, `kill`, a crash —
  `rm -rf`s it.
- `--out` / `--keep-json` are explicit opt-ins. Those files hold PHI and are
  **your responsibility to delete** — `rm` on an APFS SSD doesn't overwrite
  data, so there's no "secure erase" claim here; not writing the file, or
  keeping it on an encrypted volume, is the safe path.
- Your **terminal scrollback** holds whatever printed to stdout. Clear it
  (`Cmd-K`) after copying a transcript or note if you didn't use `--out`.
- **`soapcap note` stays local** — the transcript goes to Ollama over
  `localhost` only. The note is PHI exactly like the transcript: stdout by
  default, disk only with `--out`.
- **`--clipboard` is another opt-in and another place PHI can linger** —
  most clipboard managers keep history independent of `soapcap`. Fine for a
  quick paste into an EHR; don't treat it as more private than a file.

---

## Legal — read before first use

- **This is a personal project, not a clinical product.** It has not been
  reviewed by a clinician, security auditor, or compliance professional, and
  carries no certification of any kind. Using it with real client sessions is
  entirely your own decision and responsibility — read the rest of this
  section, [Retention](#retention), and [Known limitations](#known-limitations)
  before you do.
- **Recording a therapy session requires the client's informed consent.**
  Many US states are all-party-consent jurisdictions.
- Sending anything to a **third-party service** (SoapNoteAI, Upheal, an
  API) means a signed **Business Associate Agreement** with that vendor.
  The local-model path avoids this; a future cloud path would not.
- **De-identification (`soapcap deidentify`) is a best-effort local pass,
  not a certified de-identification.** It is not HIPAA Safe Harbor
  de-identification and has not gone through Expert Determination — it's
  an on-device PII-tagging model that catches what it catches. Its output
  remains confidential clinical material, not something cleared for a
  hand-off a real BAA would otherwise require, and should always be
  reviewed before being sent anywhere.
- Not affiliated with Zoom, Apple, SoapNoteAI, Upheal, or any EHR. No
  warranty. See `LICENSE`.

---

## Roadmap

- [x] On-device capture + speaker-attributed transcript (`live`, `transcribe`)
- [x] `soapcap note` — local SOAP/DAP/BIRP generation via Ollama
- [x] `soapcap session` + `soapcap.command` — guided flow, clickable launcher
- [x] `doctor` checks chip/memory/disk and sizes model advice to them
- [x] Single-key stop (q/x) and real pause/resume (p) while recording
- [x] Optional gum/fzf: nicer `session` prompts, `note` file picker
- [x] Interactive model selection/download — `soapcap model` shows the
      catalog as a table, offers to `ollama pull` a pick that isn't local
      yet, and saves it as the new `session`/`note` default
- [x] `soapcap deidentify` — best-effort local PII redaction before any hand-off
- [ ] `--backend cloud` — POST the de-identified transcript to a
      BAA-covered SOAP API
- [ ] `soapcap record` — the one path that *must* keep audio briefly, for
      Upheal (audio-only intake); capture to a temp `.m4a`, upload, delete

---

## Known limitations

### FaceTime: no system audio, at all

`soapcap` captures system audio through ScreenCaptureKit, which composites
audio **per capturable application**. FaceTime's remote-party audio is
rendered by `avconferenced`, a windowless background daemon invisible to
that model — it never reaches any capture built on ScreenCaptureKit, and
**no permission fixes this**.

Not a `soapcap`/`yap`-specific bug: [BlackHole](https://github.com/ExistentialAudio/BlackHole),
[OBS Studio](https://github.com/obsproject/obs-studio), and
[BackgroundMusic](https://github.com/kyleneideck/BackgroundMusic) — three
unrelated capture mechanisms — all have open issues describing the same
FaceTime-only silence.

Your own mic still works (a direct hardware tap, unaffected) — `live` shows
`Therapist:` lines and nothing else. Got audio from neither side? That's a
different, ordinary permission problem — run `doctor`.

**Not affected**: Zoom, Meet, Teams, Doxy.me, any ordinary windowed app.

No known workaround exists for FaceTime's system audio — three unrelated
tools already failed to find one. Playing the call through speakers (not
headphones) lets your mic pick up both sides acoustically, but with no
system-audio channel to diarize against, it collapses to one
undifferentiated `Therapist:` stream, unlabeled by speaker. Use
Zoom/Meet/Teams/Doxy.me instead when a clean speaker-attributed transcript
matters.

---

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Double-clicking `soapcap.command` says it can't be opened | Gatekeeper, first run only — see [Clickable shortcut](#clickable-shortcut) for the Open Anyway steps. |
| `doctor` WARN: no usable output | Grant **both** Microphone and Screen Recording to your terminal, then fully restart it. |
| `live` prints a "captured your side but nothing from the other party" note | Expected on FaceTime — see [Known limitations](#facetime-no-system-audio-at-all). Not FaceTime? Check the other party's output device / volume. |
| Occasional short duplicate line (often one word) | Expected — see [Without headphones](#without-headphones). Lower `SOAPCAP_DEDUPE_MINWORDS` to `1` to also catch these, at the cost of risking a real one-word utterance. |
| Longer duplicate lines still appear twice | Lower `SOAPCAP_DEDUPE_THRESHOLD` (e.g. `0.55`) or widen `SOAPCAP_DEDUPE_WINDOW`, or use headphones. |
| A real Therapist line seems to have been dropped | Raise `SOAPCAP_DEDUPE_THRESHOLD` (e.g. `0.85`) or compare against `--no-dedupe`. |
| Notification dings / music in transcript | Enable Do Not Disturb; close other audio apps. |
| `yap: command not found` | `brew install yap` (needs macOS 26+). |
| Wrong language | `soapcap live --locale en-US` or set `SOAPCAP_LOCALE`. |
| `note`: "can't reach Ollama" | `brew services start ollama` (or `ollama serve`), then re-run. |
| `note`: "model is not pulled" | `ollama pull llama3.1:8b` (or whatever `--model` you passed). |
| `note` is slow / machine feels sluggish | Close other apps, or use a smaller model (`--model llama3.2:3b`) — see [Requirements](#requirements) and [Draft a note](#draft-a-note). |
| `note` with no FILE just sits there | No terminal / no fzf, so there's nothing to read or browse. Pass a file, pipe one in, or `brew install fzf`. |
| Want Ollama to stop running | `ollama stop <model>` unloads just that model from memory (Ollama reloads it next time it's needed). To stop Ollama itself: `brew services stop ollama` if you started it that way, otherwise quit/kill the `ollama serve` process. |
