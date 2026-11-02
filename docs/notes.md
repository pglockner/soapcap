# Notes in detail

What `soapcap note` produces and how to tune it. The short version is in the
main [README](../README.md#draft-a-note).

## SOAP house format

SOAP notes follow a fixed house format:

- **Objective** is a brief mental-status summary, drafted by a **second
  model pass** of its own ([`prompts/objective.md`](../prompts/objective.md)).
  The model supplies one short clinical phrase for each of engagement,
  affect, mood, speech, thought process, insight, judgment and psychomotor.
  soapcap puts them in a fixed frame:

  > On time via video. Engaged and collaborative. Affect congruent; mood
  > mildly stressed. Speech clear and articulate. Thought process linear.
  > Insight improving; judgment intact. No psychomotor abnormalities. No
  > SI/HI reported.

  These phrases are the model's judgment from a text transcript, not
  something it observed, so check each one against what you saw. "On
  time via video." is fixed text; edit it when that isn't true. The last
  sentence depends on what the session showed:
  - **"No SI/HI reported."** appears only when the Objective pass found no
    disclosure *and* the rest of the note has no risk language (a plain
    denial like "denied suicidal ideation" doesn't count as risk language).
  - **A disclosure** replaces it with a fixed line naming only the kind:
    "SI reported; see Assessment and Plan." (or HI, SI and HI,
    self-harm). Check plan, intent and means in Assessment and Plan.
  - **Risk language in the note that the Objective pass missed** gives a
    bracketed "[… confirm SI/HI status before signing.]" instead.
  - **If the Objective pass fails**, the rest of the note is kept, and
    Objective says in brackets that it needs completing by hand.
  - **If the transcript has no client lines at all** (the other side of
    the call wasn't captured), there's no Objective pass. Objective says
    in brackets to complete it by hand, rather than rating the therapist.
- **Plan** always states the plan of care. It covers what the session
  set up (interventions, homework, referrals, follow-up) and then closes
  with "The current plan of care will continue." when the session didn't
  change the plan of care. The models don't always get that distinction
  right, so check that closing line when a session did change the plan.
- **Session line.** With `--duration MINUTES`, the note starts with a line
  like `63 minutes, telehealth`. `session` adds it automatically from
  recording time: whole minutes, rounded down, with paused time left out.
  Set `SOAPCAP_SESSION_TYPE` in config to change "telehealth". A
  transcript file doesn't record how long the session ran, so `note FILE`
  leaves the line out unless you pass `--duration`.

The second pass makes a SOAP note take roughly twice as long as a DAP or
BIRP note.

## While it drafts

`note` sizes the model's context window to the transcript's length, so
long sessions aren't silently truncated. Every pass of a note uses the same
size (a model is loaded again whenever the size changes), and every pass
has an output cap, so a model that starts repeating itself is cut off
rather than left running until the request times out — soapcap says so
when a note hit the cap.

While it drafts, a status line shows elapsed time, a live count of the
tokens the model has generated (with a tokens-per-second rate), and memory
in use, turning yellow at 75% and red at 90%. The memory number counts swap
too, so it passes 100% once the Mac is swapping to make room, which slows
drafting a lot; from 90% the line also shows swap in use. Closing other
apps is the fix. In `session`, each finished pass keeps its line, ending
`-- done!`, so you can see what the note cost; `note` clears it. The model
is unloaded as soon as the note is done; `session` keeps it loaded until
you've settled on a draft, so that regenerating doesn't wait for it to load
again. Models are asked not to "think" (`enable_thinking: false`, or
Ollama's `think: false`): reasoning made notes worse or much slower in
testing.

## Models

The two soapcap's prompts are tested with, both run on soapcap's own
engine:

| Model | Size | Notes |
|---|---|---|
| `gemma4-e4b` | ~5GB | **Default.** Gemma 4 E4B Instruct, in unsloth's 4-bit conversion. Fast: under two minutes for a long session, and needs the least memory (~6.5GB). Now and then gives a client whose pronoun was never stated one from their name; proofread pronouns, or de-identify the transcript first, which removes the cue. |
| `bonsai` | ~6GB (16GB+ Mac) | Bonsai 2 27B, a ternary-weight model from PrismML. Slower (4–8 minutes a SOAP note), and it uses most of a 16GB Mac's memory while it runs. More accurate, and keeps pronouns neutral. Still proofread it. |

**`soapcap model`** shows both with their live status, plus any other
model you've already pulled into Ollama (marked untested), and lets you pick
one as the default for `session`/`note` (setting it up first if needed).
`--model` still overrides it per run. The authoritative list is
[`sc_model_catalog`](../lib/model.sh).

### Setting up the models

Both run on `llama-server` from
[PrismML's llama.cpp fork](https://github.com/PrismML-Eng/llama.cpp), at
the commit soapcap was tested with: the only runtime that loads Bonsai's
weights, and the one Gemma's notes were tested on. `install.sh` offers
them, or run it any time:

```sh
tools/models/install.sh gemma4-e4b   # builds the fork's llama-server the
                                     # first time (pinned, ~2 min), downloads
                                     # the model (~5GB, checksum-verified)
                                     # into ~/.local/share/soapcap/engine
tools/models/install.sh bonsai       # ~6GB more, same server
soapcap note --model bonsai transcript.txt
```

soapcap starts the server on `127.0.0.1` only when drafting a note and
stops it straight after, so its memory is free the rest of the time. Its
location and port are configurable — see `config.example.sh`. Gemma's
server takes a checkpoint at every request (`--checkpoint-min-step 0`):
its attention looks back over a sliding window, so without one the
Objective pass would read the whole transcript again.

### The retired llama3.1:8b

`llama3.1:8b`, via Ollama, was the default until Gemma 4 E4B replaced it.
While it's still your default, or still pulled while Gemma isn't set up,
`note`, `session`, `soapcap model` and `doctor` warn about it. Re-running
`install.sh` replaces it: it sets up Gemma 4 E4B, switches a
`SOAPCAP_MODEL="llama3.1:8b"` in `config.sh` to it, then runs
`ollama rm llama3.1:8b` (starting Ollama for it if needed) and checks that
it's gone. llama3.1:8b is only removed once Gemma is set up, so notes keep
working if the download fails. Until then, `--model llama3.1:8b` still
drafts, as an untested model. By hand:

```sh
tools/models/install.sh gemma4-e4b
soapcap model                 # pick gemma4-e4b
ollama rm llama3.1:8b         # frees ~5GB
brew uninstall ollama         # optional, if nothing else uses it
```

### Other models

Any Ollama model works too, but outside the two above soapcap flags it as
untested each time, and its notes need closer proofreading. Pull it, then
name it:

```sh
ollama pull qwen2.5:14b
soapcap note --model qwen2.5:14b transcript.txt
```

To make it stick, set `SOAPCAP_MODEL="qwen2.5:14b"` in
`~/.config/soapcap/config.sh`. `qwen2.5:14b` (~9GB) is a reasonable middle
ground, but in SOAP notes it often assigns pronouns from names and adds
detail the transcript doesn't support.

## Note style

`--style`, or `SOAPCAP_STYLE` in config. `structured` and `combined` are
experimental.

| Style | What happens | Trade-off |
|---|---|---|
| `narrative` | **Default.** The model writes the note as prose from `prompts/<format>.md`. | Fullest Subjective and the most natural wording. Format rules depend on the model following the prompt. |
| `structured` | The model fills in a fixed set of fields — each Objective observation (DAP/BIRP) and next step cites the transcript line it comes from — and soapcap checks them and writes the note itself. SOAP's Objective still comes from its own pass. | Headers, the Objective rule and "Not addressed" are guaranteed by code rather than the model. Plan lists every commitment, and a disclosed risk's safety plan (warning signs, coping strategies, supports, emergency steps) in full. Cited lines, who-said-what, and quotes are checked against the transcript. But Subjective comes out briefer than narrative's, and Plan reads as composed sentences rather than free prose. |
| `combined` | A narrative note, plus a structured pass used only to check it. | The narrative note, unchanged, plus a review: quotes that aren't in the transcript, a safety risk or safety screen the note doesn't mention, and a checklist of the next steps mentioned in the session. **One more model pass** than narrative, so SOAP takes three. |

Reviews print to the terminal only (stderr) — never into the note, `--out`,
or the clipboard.

The next-steps checklist lists every next step the check found, with its
transcript line. It doesn't say which ones the note is missing; check
those yourself.

Structured style's rules, field guide and schema are in
[`prompts/structured/`](../prompts/structured/); its checks and rendering are
in [`lib/structured/`](../lib/structured/).
