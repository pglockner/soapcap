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
there or miss detail that is.

`note` sizes Ollama's context window (`num_ctx`) to the transcript's length,
so long sessions aren't silently truncated.

**Models:**

| Model | Size | Notes |
|---|---|---|
| `llama3.1:8b` | ~5GB | Best balance of reliability and speed. **Default.** Doesn't invent observations, but can under-read a client's own present-moment reaction ("I'm getting choked up") as just a general feeling rather than something that happened in the room. |
| `llama3.2:3b` | ~2GB | Fastest and lightest, but prone to inventing plausible-sounding clinical detail that isn't in the transcript. Only worth it under real memory pressure. |
| `qwen2.5:14b` | ~9GB | Most reliable at catching real Objective-section detail, including a client's own in-the-moment reactions. ~2.5x the generation time and more RAM headroom; occasionally adds a little unstated color rather than bare extraction. |
| `qwen3:30b` | ~19GB (32GB+ systems) | **Untested.** Mixture-of-experts (3B active params), so faster than its size suggests. |
| `gemma3:27b` | ~17GB (32GB+ systems) | **Untested.** Dense 27B; different failure modes than the Qwen models, worth comparing. |

The authoritative list is [`sc_model_catalog`](lib/commands.sh).

**`soapcap model`** shows this table live (with which models are actually
pulled) and, interactively, lets you pick one — pulling it via `ollama pull`
if needed, with an extra confirmation for anything untested — and saves
the pick as the new default for `session`/`note` (`--model` still overrides
per-run). `session` uses whatever is configured and doesn't ask.

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

Unlike the rest of soapcap, building this helper needs `git` (bundled with
Xcode) and network access to GitHub, to fetch OpenMedKit; the first real
run also fetches model weights from Hugging Face.

**This is a best-effort pass, not a certified de-identification.** It
redacts what OpenMedKit's model tags, plus two narrow pattern rules (month
names and numbers of seven or more digits; see
[the helper's README](tools/deidentify-helper/README.md#rule-based-detections)),
and nothing more — a missed mention
stays in the output verbatim, and the output is still confidential
clinical material. Read it before sending it anywhere. See
[Legal](#legal--read-before-first-use).

Other flags: `--out FILE`, `--clipboard`.

### Guided session

```sh
soapcap session
```

`session` captures live, then walks through the rest with prompts. It runs
on the terminal's alternate screen buffer (see [Retention](#retention)), so
it looks like a full-screen app and clears when you press Enter at the end.

1. **De-identify?** Only asked if the [de-identify](#de-identify) helper is
   built. One yes/no: yes redacts the transcript (the redacted text is what
   is displayed, drafted from, and copied), and redacts the drafted note
   again before it's shown.
2. **Show the transcript?**
3. **Draft a note from this?** (worded "Draft a de-identified note…" if you
   said yes to step 1), then **Format?** (soap, dap, birp).
4. **This draft: keep / regenerate / discard.** `regenerate` drafts again
   with the same model and transcript; `discard` ends with no note. `keep`
   copies the note to the clipboard.

Enter takes the default at every prompt; without
[gum](#nicer-prompts-and-file-picking), a bare first letter works too (`r`
for regenerate, `b` for birp). `--format`, `--no-note`, and `--model` skip
the matching prompt; `--clipboard` forces the copy on non-interactive runs.
Every `live`/`note` flag still applies. The model is whatever
[`soapcap model`](#draft-a-note) configured. This is what double-clicking
`soapcap.command` runs — see [Clickable shortcut](#clickable-shortcut).

**Multiple clients in one session (couples, families):** redaction replaces
each name with a numbered token, and the drafting model tends to write "the
client" or "the couple" rather than track who is who, so the note may lose
who said or did what. Decline de-identification if that attribution matters.

### Window app (experimental)

```sh
SOAPCAP_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" tools/session-app/build.sh
open tools/session-app/build/Soapcap.app
```

A SwiftUI window with the same flow as `session` (record, optional
de-identify, draft, keep-and-copy) and scrollable, selectable transcript and
note text. Because it isn't a terminal program, nothing it shows can land in
terminal scrollback. It needs full Xcode and a code-signing identity so macOS
keeps its Microphone and Screen Recording grants across rebuilds; see
[tools/session-app/README.md](tools/session-app/README.md). Pause and resume
are supported.

### Pause/resume

Press **p** (or space) while recording; **p** again to resume. Pausing stops
`yap`, so nothing is captured while paused; a fresh capture starts on
resume. Multiple cycles are stitched into one transcript, in order.

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
dropped as an echo. It errs toward keeping lines: a missed echo is a
duplicate, a wrongly dropped segment is lost. Tunable via env or
`~/.config/soapcap/config.sh`:

```sh
SOAPCAP_DEDUPE_WINDOW=3.5      # seconds of timing slack
SOAPCAP_DEDUPE_THRESHOLD=0.7   # word-containment ratio (0–1) to call it an echo
SOAPCAP_DEDUPE_MINWORDS=2      # segments shorter than this are never dropped
```

`--no-dedupe` shows the raw output. Expect an occasional one-word duplicate,
since segments under `SOAPCAP_DEDUPE_MINWORDS` are never dropped.
Headphones (even one earbud) remain the more reliable fix.

### Real diarization

Voice-based diarization (e.g. [FluidAudio](https://github.com/FluidInference/FluidAudio),
on-device) isn't wired in: it needs recorded audio, which the `live` path
never produces (see [Retention](#retention)).

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
  `session` is the exception: it draws to the terminal's **alternate screen
  buffer** (as `vim`/`less` do), which stays out of scrollback and out of
  the window-restore snapshots some terminal apps write to disk. The
  screen clears when `session` ends.
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
- [x] Interactive model selection/download (`soapcap model`)
- [x] `soapcap deidentify` — best-effort local PII redaction before any hand-off
- [ ] `--backend cloud` — POST the de-identified transcript to a
      BAA-covered SOAP API
- [ ] `soapcap record` — the one path that *must* keep audio briefly, for
      Upheal (audio-only intake); capture to a temp `.m4a`, upload, delete
- [x] Experimental native window front end for `session` (`tools/session-app`)

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
