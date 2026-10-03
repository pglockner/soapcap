# Changelog

## 0.9 (2026-10-03)

- Moved the experimental window app out of this repository; it is now the seed of a separate Swift rewrite, which is in development.
- Shortened the README and moved detail into `docs/` (notes, setup, capture).
- Stated what `session` offers to save: de-identified transcripts only, except the troubleshooting save when a SOAP draft has no Subjective.
- Moved the cloud hand-off roadmap item to the de-identify helper's README and dropped the audio-recording item.
- Split `lib/commands.sh` into one file per command, with no behavior change.

## 0.8 (2026-09-28 – 2026-10-01)

- Changed the note format to a therapist's SOAP layout, with a mental-status Objective section, a session line, and saved transcripts.
- Added a choice of note model in session, and a model command that lists pulled models.
- Added a drafting status with a live token count, swap, and persistent lines in session.
- Added a clipboard hint in session, an offer to save the transcript when Subjective is missing, and a warning for over-long transcripts.
- Changed the note and transcript to wrap to the terminal's width on screen only.

## 0.7 (2026-09-25 – 2026-09-26)

- Added a style setting to the note feature, with the options narrative, structured and combined.
- Fixed the Bonsai health check so it no longer relies on `jq -e` with possibly empty input.

## 0.6 (2026-09-24)

- Added Bonsai as a second tested note model and trimmed the model picker to two options.
- Added a fictional sample-transcript corpus with a guide to each transcript.
- Changed the transcript ignore rule so that only samples/transcripts is exempted from *.transcript, which tracks the sample transcripts.

## 0.5 (2026-09-21 – 2026-09-23)

- Changed the soap.md prompt: it now states a positive default for unestablished pronouns, treats the Objective fallback rule as an explicit decision gate, no longer quotes the Objective rule's example phrases, and requires continuous prose with no lists in every section.
- Ported the four soap.md prompt fixes to dap.md and birp.md.
- Added month-name and long-number regex rules to deidentify-helper.
- Updated the soapcap-update.icns icon, added an app SwiftUI preview, and ignored Xcode workspace state.

## 0.4 (2026-09-18)

- Added an XCTest target for the session logic in session-app.

## 0.3 (2026-09-16 – 2026-09-18)

- Added an experimental native window front end (tools/session-app), including pause and resume.
- Changed session to use an alternate-screen display and to auto-copy on keep.
- Changed session to show a single de-identify prompt up front.
- Fixed the unreliable Metal Toolchain check, replacing the interactive Metal Toolchain fix with a requirements check.
- Fixed an inconsistency in install.sh's gum handling.

## 0.2 (2026-09-16)

- Added `soapcap deidentify`, a local pass that de-identifies PII.

## 0.1 (2026-09-12 – 2026-09-15)

- Added soapcap, an on-device telehealth transcription tool that generates SOAP, DAP and BIRP notes locally
- Fixed Ollama's context window to be sized to the prompt, which prevents malformed notes
- Fixed the spacebar never actually pausing recording
- Added an interactive model chooser to the session, then moved model choice out of the session into a `soapcap model` command
- Added the option to regenerate, keep or discard a weak note draft in a session
