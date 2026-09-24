# soapcap-deidentify-helper

The Swift half of `soapcap deidentify` — see the main [README](../../README.md#de-identify)
for what it does and how to use it from soapcap itself. This file is just
the build command and the stdin/stdout contract the bash layer
(`sc_deidentify_transcript` in `lib/commands.sh`) depends on.

## Requirements

Confirmed on two separate machines, not assumed — **plain Xcode Command
Line Tools alone is not enough.** `install.sh` checks all of these before
offering to build, and points here (rather than trying to fix them
itself) if any are missing:

| Requirement | Manual install | Effort |
|---|---|---|
| macOS 26+, Apple Silicon | Same as the rest of soapcap — nothing extra | — |
| **Full Xcode.app** (not just Command Line Tools) | App Store (free), or a signed-in download from developer.apple.com | Large — ~4GB installed (this machine; varies by Xcode version), needs an Apple ID signed in to the App Store, can take a while on a slow connection |
| Xcode set as the active developer directory | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` | One command, only needed if a CLT-only install was active before |
| Xcode's license accepted | Open Xcode.app once (GUI) — it prompts for the license on first launch. It also offers to install additional components/simulators; decline, they're not needed for this build. | One-time GUI step, a couple minutes. `sudo xcodebuild -license accept` works too if you'd rather not open the GUI. |
| Metal Toolchain component | `xcodebuild -downloadComponent MetalToolchain` (requires the two rows above first — this command itself refuses to run under a CLT-only selection) | One command, ~840MB one-time download |
| `git` | Comes bundled with Xcode automatically | None, once Xcode is installed |
| Network access to `github.com` | — | Needed once, to fetch OpenMedKit and its dependencies via Swift Package Manager during the build |
| Network access to `huggingface.co` | — | Needed once, to download the Privacy Filter model's weights on first real `soapcap deidentify` run (~129MB) |
| Disk space | — | ~1.1GB for Swift package checkouts + build products, on top of Xcode itself and the model weights above |

Once everything above is in place:

```sh
swift build -c release
```

The binary lands at `.build/release/soapcap-deidentify-helper`, which is
exactly where `SOAPCAP_DEIDENTIFY_BIN` (in `lib/common.sh`) expects it.

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
- **Exit codes**: `0` success; `2` model weights unavailable (no network
  on a true first run); `1` any other failure. Nothing should be trusted
  on stdout unless the exit code is `0`.
- **`--version`**: prints a version string and exits 0 without touching
  stdin, the model, or the network.

## Detection runs twice and merges

`extractPIIChunked` runs under two different chunk-window layouts
(256/32 tokens, then 480/128 — the latter near the model's real
512-token hard limit, see `App.swift`'s `max_position_embeddings` note)
and the results are merged through `removeOverlaps()`. This exists
because retuning the window is a lateral tradeoff, not a strict
improvement: a wider window fixed one missed phone number in testing but
broke a different one that the default window had caught. Running both
and merging covers both, for roughly 2x inference time (still under a
second for a typical transcript on this model's size). Full story in
`DEV_NOTES.local.md` if you're touching this again.

## Rule-based detections

Two regex rules run alongside the model, and their matches merge through
the same `removeOverlaps()` as the model's spans:

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

## Known limitation, found during testing

The model (OpenMed's ~33M-param Privacy Filter, via MLX) does not
reliably catch every instance of every category, even after the
two-pass merge above — this isn't a bug in the code here, it's the
actual model's real-world recall. Confirmed directly against this
project's sample-transcript corpus (`~/.config/soapcap/sample-transcripts/`):

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
