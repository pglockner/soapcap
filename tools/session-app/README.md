# Soapcap.app (experimental)

A SwiftUI window front end for the `soapcap session` flow. It reimplements
nothing: it runs `soapcap live`, `soapcap deidentify`, and `soapcap note` as
child processes over pipes.
Because it isn't a terminal program, nothing it shows can end up in terminal
scrollback or a terminal's window-restore snapshot. Data stays in memory; the
note is copied to the clipboard marked as concealed so clipboard managers that
honor that convention skip it.

## Requirements

| Requirement | Notes |
|---|---|
| Full Xcode (not just Command Line Tools) | Same as `../deidentify-helper` |
| soapcap itself | The app runs `<repo>/bin/soapcap` |
| De-identify helper (optional) | The de-identify toggle only appears if it's built |

## Build and run

```sh
tools/session-app/build.sh && open tools/session-app/build/Soapcap.app
```

`build.sh` signs ad hoc. To keep macOS privacy grants across rebuilds, set
`SOAPCAP_SIGN_IDENTITY` to a stable local code-signing identity.

## Signing

`build.sh` signs ad hoc unless `SOAPCAP_SIGN_IDENTITY` names a code-signing
identity, e.g. an Apple Development certificate (Xcode creates one for a
free Apple ID). Use one: with an ad-hoc signature, macOS treats each rebuild
as a different app and drops its Microphone and Screen Recording grants. To
reset a stuck grant: `tccutil reset ScreenCapture local.soapcap.session` and
`tccutil reset Microphone local.soapcap.session`.

```sh
SOAPCAP_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" tools/session-app/build.sh
```

Grant Microphone and Screen Recording to "Soapcap" the first time (quit and
reopen the app after granting). The **Check permissions** button runs
`soapcap doctor` as the app, so it reports what macOS lets the app do.

## Tests

```sh
cd tools/session-app && swift test
```

15 XCTest cases (about 25 seconds) cover the session logic against a stub
`soapcap`: pause/resume joining, de-identify order, failure screens, the
3-second stop guard, and the stop-signal regression (signalling only the
script, so `yap` gets SIGINT and not SIGTERM). Microphone/Screen Recording
permissions, signing, and the window itself are not covered; they need a
person.

## Limitations

- Pause ends the current `soapcap live` and Resume starts a new one, so each
  leg needs about 3 seconds to start before it can be paused or stopped.
