# Capture in detail

How speaker labels work, the echo de-duplication pass, and what can't be
captured. The short version is in the main [README](../README.md#without-headphones).

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
never produces (see [Retention](../README.md#retention)).


## FaceTime: no system audio, at all

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
