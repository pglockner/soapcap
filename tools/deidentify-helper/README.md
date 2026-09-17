# soapcap-deidentify-helper

The Swift half of `soapcap deidentify` — see the main [README](../../README.md#de-identify)
for what it does and how to use it from soapcap itself. This file is just
the build command and the stdin/stdout contract the bash layer
(`sc_deidentify_transcript` in `lib/commands.sh`) depends on.

## Build

```sh
swift build -c release
```

Needs Xcode Command Line Tools (`xcode-select --install`) and, on a fresh
install, the Metal Toolchain component — confirmed missing by default on
two separate machines' first build attempt. `install.sh` checks for this
and offers to fetch it as its own step; building by hand, `swift build`
does **not** download it automatically and instead fails with:

```
error: cannot execute tool 'metal' due to missing Metal Toolchain;
use: xcodebuild -downloadComponent MetalToolchain
```

Run that exact command (one-time, ~840MB) and retry `swift build`.

The binary lands at `.build/release/soapcap-deidentify-helper`, which is
exactly where `SOAPCAP_DEIDENTIFY_BIN` (in `lib/common.sh`) expects it.

## Contract

- **stdin**: UTF-8 text — a transcript's body only, no speaker labels
  (the caller strips those first and re-attaches them after).
- **stdout on exit 0**: the same text with detected PII spans replaced by
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

## Known limitation, found during testing

The model (OpenMed's ~33M-param Privacy Filter, via MLX) does not
reliably catch every instance of every category, even after the
two-pass merge above — this isn't a bug in the code here, it's the
actual model's real-world recall. Confirmed directly against this
project's sample-transcript corpus (`~/.config/soapcap/sample-transcripts/`):

- A month-only date mention ("your anniversary is coming up in August")
  was never tagged at all, in either occurrence, under any window
  configuration or confidence threshold tested — a genuine miss, not a
  chunking artifact.
- A hyphenated surname ("Okonkwo-Reyes") got labeled inconsistently
  across two separate mentions in the same transcript — `USERNAME` once,
  `LAST_NAME` once. Both instances still got redacted; this is a
  category-labeling wrinkle, not a leak.
- One idiom ("white-knuckling") had "white" flagged and redacted — a
  benign false positive (safe-direction over-redaction, not a miss).

This is exactly why `soapcap deidentify` is documented as best-effort,
not certified — see the main README's Legal section. Don't "fix" the
date-miss above by bolting regex onto the Swift side for structured
formats without discussing it first: it was a deliberate, considered
choice earlier in this feature's design to prefer a real NER model over
hand-rolled regex specifically because regex is weak on the *harder*
category (names), and mixing the two approaches has real tradeoffs
(regex false-positives, doubled maintenance surface, two different
failure models to reason about) that deserve a real decision, not a
quiet patch.
