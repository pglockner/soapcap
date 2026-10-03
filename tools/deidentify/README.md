# soapcap de-identify helper

The half of `soapcap deidentify` that finds and replaces identifiers — see
the main [README](../../README.md#de-identify) for what it does and how to
use it from soapcap. It is a short Python program (`deidentify.py`) running
[OpenMed](https://github.com/maziyarpanahi/openmed)'s on-device PII model
through Apple's MLX runtime, plus a few deterministic rules.

## Install

```sh
tools/deidentify/install.sh
```

The main `install.sh` offers this too. It needs an Apple silicon Mac and
Homebrew, and nothing else: no Python, no Xcode.

| Step | What it does | Size |
|---|---|---|
| uv | Installs [uv](https://docs.astral.sh/uv/) with Homebrew if it's missing. uv downloads its own Python 3.12, so the Mac's Python (or lack of one) doesn't matter. | ~40MB |
| Packages | Creates a private environment and installs the exact package versions in `requirements.txt`, each checked against its recorded hash. | ~440MB |
| Model | Downloads the model's weights from Hugging Face and checks them against a recorded checksum. | ~130MB |
| Check | Redacts a test sentence with the network switched off. | — |

Everything lands in `~/.local/share/soapcap/deidentify`
(`SOAPCAP_DEIDENTIFY_DIR`); delete that folder to remove it. Re-running the
script is safe and repairs a partial install. Moving the soapcap folder
afterwards means re-running it, because the launcher it writes points at
`deidentify.py` here.

**No network at run time.** The install is the only step that downloads
anything. `deidentify.py` runs with the Hugging Face hub switched off, so a
transcript is never in a process that can reach the network for model files.

To change a package version, edit `requirements.in` and regenerate the lock:

```sh
uv pip compile --generate-hashes --python-version 3.12 requirements.in -o requirements.txt
```

## Contract

- **stdin**: UTF-8 text — a transcript's body only, no speaker labels
  (the caller strips those first and re-attaches them after).
- **stdout on exit 0**: the same text with detected PII spans (model and
  [rules](#rule-based-detections)) replaced by
  consistent bracketed tokens (`[FIRST_NAME_1]`, `[PHONE_1]`, …) — the
  same value always gets the same token, different values never collide.
  Line count is unchanged from the input.
- **stderr on exit 0**: exactly one line — either
  `redacted N span(s): LABEL x count, ...` or `no entities detected`.
- **Exit codes**: `0` success; `2` model weights unavailable (the
  install didn't finish); `1` any other failure. Nothing should be trusted
  on stdout unless the exit code is `0`.
- **`--version`**: prints a version string and exits 0 without touching
  stdin, the model, or the network.

## Detection runs twice and merges

The text is cut into overlapping windows of tokens and the model runs on
each. That happens under two window layouts (256 tokens with 32 of overlap,
then 480 with 128, the latter just under the model's 512-token limit) and
the results are merged through `remove_overlaps()`. Retuning the window is a
lateral tradeoff, not a strict improvement: a wider window fixed one missed
phone number in testing but broke a different one that the narrower window
had caught. Running both and merging covers both. A 60-minute transcript
still takes about 3 seconds.

## Rule-based detections

Two regex rules run alongside the model, and their matches merge through
the same `remove_overlaps()` as the model's spans:

| Rule | Pattern | Label |
|---|---|---|
| Month names, with optional day | `\b(?:January\|…\|December)(?:\s+\d{1,2}(?:st\|nd\|rd\|th)?)?\b` (case-sensitive) | `DATE` |
| 7+ digits, optionally hyphen-grouped | `(?<![\w-])(?=(?:-?\d){7})\d+(?:-\d+)*(?![\w-])` | `PHONE` if exactly 7 or 10 digits, else `ID_NUM` |

Why these two and not more:

- **Months** cover the model's one confirmed category-level miss (see
  below). Matching is case-sensitive, so lowercase "may" and "march" are
  never touched. A capitalized, sentence-initial "May I…" *is*
  redacted, a known false positive in the safe direction.
- **Long numbers** count digits instead of matching a phone layout,
  because speech-to-text groups digits inconsistently. In a test of
  spoken numbers transcribed by `yap`, phone numbers came out
  `555-0199` / `415-555-0148` (parentheses dropped), and a spoken SSN
  came out `123-456789`. A number of seven or more digits in a
  therapy transcript is almost always an identifier. Dollar amounts are
  safe, because the transcriber inserts commas (`$1,500,000`), which break
  the match. This rule also closes the partial-boundary leak described
  below for hyphenated numbers: the full `555-0199` rule span starts
  earlier and is longer than a partial model span such as `-0199`, so it
  wins the overlap merge.

Known gaps these rules deliberately don't cover:

- A bare four-digit reference ("the number ending in 0199"). A rule
  covering it would have to redact every four-digit number, which is
  too broad.
- A long number read as separate digits, which the transcriber may
  write as `1, 2, 3, 4, 5, 6,789`.
- Numbers separated by spaces or dots. None appeared in the
  transcription test.

On the sample-transcript corpus, adding the rules took must-redact
identifiers from 36/40 to 38/40 fully removed, with no new false
positives. The two remaining misses are the "ending in" references above.

That was measured with the earlier Swift helper. This one was compared with
it on all eight sample transcripts: it removes everything the Swift helper
removed, plus an employer and an insurer the Swift helper left in. Both
leave the two "ending in" references and one insurer's name in the
60-minute sample. It also tags more durations ("ten minutes", "forty
minutes") as `TIME` than the Swift helper did, which is over-redaction, not
a leak, but it does cost a note some detail.

Two more rules clean up the model's own output:

- **A name tagged once is redacted everywhere.** Any text the model tags as
  a first or last name is then replaced wherever it appears as a whole word.
  The model misses an occasional repeat (it caught nine of ten "Sam"s in the
  60-minute sample and left "the Sam dinner"), and one missed mention undoes
  the rest. A name that is also an ordinary word ("Will", "Hope") gets
  over-redacted, in the safe direction.
- **One-character spans are dropped.** The model sometimes tags a stray
  token, which turned "haven't" into "haven'[FIRST_NAME_4]".

## Known limitation, found during testing

The model (OpenMed's ~33M-param Privacy Filter, via MLX) does not
reliably catch every instance of every category, even after the
two-pass merge above — this isn't a bug in the code here, it's the
actual model's real-world recall. Confirmed directly against this
project's sample-transcript corpus ([`samples/transcripts/`](../../samples/transcripts/)):

- A month-only date mention ("your anniversary is coming up in August")
  was never tagged at all, in either occurrence, under any window
  configuration or confidence threshold tested — a genuine miss, not a
  chunking artifact. The month rule under
  [Rule-based detections](#rule-based-detections) now covers it.
- A hyphenated surname ("Okonkwo-Reyes") got labeled inconsistently
  across two separate mentions in the same transcript — `USERNAME` once,
  `LAST_NAME` once. Both instances still got redacted; this is a
  category-labeling wrinkle, not a leak.
- One idiom ("white-knuckling") had "white" flagged and redacted — a
  benign false positive (safe-direction over-redaction, not a miss).
- **Span boundaries can differ across machines for the same input.**
  Confirmed by running the full 7-file corpus on two different Apple
  Silicon Macs (same code, same model weights): 6 of 7 files were
  byte-for-byte identical, but one phone number (`555-0199`) got a
  partial redaction on one machine — `555[PHONE_1]` instead of
  `[PHONE_1]` — because the detected span started 3 characters later
  than it did on the other machine. Same input, same weights, different
  hardware, different exact boundary. This means a clean run on one Mac
  doesn't guarantee a clean run on another; there's no known way to
  detect this class of partial leak from the summary line alone (it
  still reports `PHONE x1` either way) — only a byte-level diff of the
  actual output caught it here. For numbers of 7+ digits, the
  long-number rule now covers this (see
  [Rule-based detections](#rule-based-detections)). It is still possible
  for any other category.

This is exactly why `soapcap deidentify` is documented as best-effort,
not certified — see the main README's Legal section.

The design deliberately prefers a real NER model over hand-rolled regex,
because regex is weak on the *harder* category (names), and mixing the
two approaches has real tradeoffs: regex false positives, a doubled
maintenance surface, and two different failure models to reason about.
The two rules above were added as a considered exception, limited to
formats regex handles well (month names, long digit runs), each tied to
a measured model miss. Keep further regex to that standard, not quiet
patches.

## Roadmap

Hand-offs to services outside the Mac follow one rule, which is why this
lives here: **only de-identified output is written to disk or
sent anywhere.** soapcap itself follows it already. `session` offers to save
a transcript only after redaction succeeds, with one exception for
troubleshooting: when a SOAP draft comes out with no Subjective section, it
offers to save the transcript, de-identified if this helper is set up and
you accept, so the cause can be found.

- [ ] `--backend cloud` — POST the de-identified transcript to a
      BAA-covered SOAP API. Refuses a transcript that hasn't been through
      this helper.
