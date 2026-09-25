# Sample transcripts

Eight **entirely fictional** therapy-session transcripts, written to exercise
soapcap's note prompts (`prompts/*.md`) and its de-identification pass
(`soapcap deidentify`). No real client, clinician, or session is behind any
of them.

Identifying details are deliberately realistic in *shape* but fictional by
construction:

- Phone numbers use `555-0100`–`555-0199`, the range reserved for fiction.
- Email addresses use the reserved `.example` domain (`fakemail.example`).
- Street addresses name no city; people, practices, employers, and insurers
  are invented.

Keep to those conventions when adding a transcript, so the corpus stays
safe to publish.

```sh
soapcap note samples/transcripts/03-selfreport-diagnosis-9min.transcript
soapcap note --format dap samples/transcripts/04-risk-disclosure-17min.transcript
soapcap deidentify samples/transcripts/06-comprehensive-long-session-22min.transcript
```

Each file uses the same `Therapist:` / `Client:` speaker labels that
`soapcap live` produces.

## At a glance

| File | Words | Main thing it tests |
|---|---:|---|
| `01-brief-checkin-1min` | 84 | Almost nothing to document: no padding, no commentary |
| `02-explicit-observation-4min` | 389 | Therapist-narrated observation → Objective |
| `03-selfreport-diagnosis-9min` | 943 | Client-narrated reaction; name without pronoun; stated diagnosis |
| `04-risk-disclosure-17min` | 1,875 | Suicidal ideation must surface; no in-session reaction |
| `05-referral-multi-intervention-20min` | 2,185 | Many interventions → prose, not a list |
| `06-comprehensive-long-session-22min` | 2,424 | Everything at once, plus a dense identifier block |
| `07-couples-single-audio-source-9min` | 1,025 | Two clients on one speaker label |
| `08-full-session-60min` | 5,787 | Full-length session: context size, many threads |

**Baseline set.** Prompt changes have been checked against 03, 04, 07, and
08: three runs each, per model, at temperature 0.7 and again at 0.3.
Between them they cover both Objective cases, the pronoun trap, a risk
disclosure, mis-attributed speakers, and a long context.

## Why each transcript is useful

### 01 — brief check-in (1 min)

A client with one minute before a meeting says sleep is going fine and
confirms next week's time.

- **Prompt tuning:** almost every section has nothing to say. Tests
  "Not addressed in this session" instead of padding, the Objective fallback
  sentence (there is no in-the-moment reaction), and the rule against
  commenting on the transcript itself ("this appears to be a very short
  session…"), which smaller models are prone to.
- **De-identification:** a single first name (Jordan) and a weekday. A
  minimal case for checking nothing *else* gets redacted.

### 02 — explicit observation (4 min)

Work stress and short sleep; a circle-of-control exercise.

- **Prompt tuning:** the easy Objective case. The therapist says outright,
  "I notice you're tearing up right now," so a correct note has real
  Objective content. Good for checking that a model doesn't *also* append
  the "no observable presentation details" fallback sentence.
- **De-identification:** an employer (Lindqvist & Cole) and a birthday
  ("March 14th"), a date of birth in all but name.

### 03 — self-report with an existing diagnosis (9 min)

Recurring chest tightness, a physician's confirmation of generalized
anxiety, a new breathing technique, a sleep routine, a referral held in
reserve.

- **Prompt tuning:**
  - *Objective, in the client's own words:* "Sorry, give me a second — I'm
    getting a little choked up." The deciding question is *when*, not *who*,
    so this belongs in Objective, and it tests that a model doesn't escalate
    "choked up" into "tearful" (llama3.1:8b did so in DAP notes in testing).
  - *Pronouns:* the client is only ever called Marcus. No one uses a pronoun
    for him, so a correct note uses they/them; a name alone never licenses
    one. Meanwhile Dr. Alvarez *is* "she" in the transcript — a control that
    should keep its pronoun.
  - *Diagnosis rule:* generalized anxiety disorder is explicitly discussed,
    so naming it is allowed; nothing beyond it is.
  - *Detail accuracy:* Tuesday vs. Friday, the landlord's email as the
    trigger, "thirty-five this June", a check-in in two weeks. Easy for a
    model to blur.
- **De-identification:** client and two clinician names, a phone number,
  an age, and a month.

### 04 — risk disclosure (17 min)

Job loss, a breakup, and a move; passive suicidal ideation with no plan
or history; a safety plan, a 988 reminder, a psychiatric referral, and
behavioral activation.

- **Prompt tuning:**
  - *Risk must surface* in Assessment and Plan (or the DAP/BIRP equivalents),
    however the model summarizes the rest.
  - *Objective, case B:* the client never narrates an in-the-moment reaction,
    so a correct note reports none (in SOAP, exactly the fallback sentence).
    Models have invented one here ("tearing up during the session") — a
    useful catch.
  - *Pronouns:* client Elena has no stated pronoun; Daniel ("he"), her sister
    Camila ("she"), and even the cat ("her") do.
- **De-identification:** a street address split across a sentence ("on
  Birchwood Lane — the one at 1420, apartment 3B"), a hyphenated surname
  (Dr. Okonkwo-Reyes, which the model has labeled inconsistently), third-party
  names, and `988` — a crisis line, not an identifier, and a check that the
  long-number rule leaves short numbers alone. "White-knuckling" has
  produced a harmless false positive.

### 05 — referral with multiple interventions (20 min)

Workload stress and stress eating: two thought records, a role-played
boundary script, a values exercise, a nutritionist referral, and a sleep
boundary.

- **Prompt tuning:** the list trap. With this many distinct interventions,
  models fall back to numbered lists or bolded sub-labels in Plan; the prose
  rule exists because of transcripts like this. Also a case-B Objective, and
  a partner (Alex) whose gender is never stated.
- **De-identification:** employer (Meridian Logistics), a clinician and her
  office phone, the partner's name, and times of day.

### 06 — comprehensive long session (22 min)

Grief on a parent's death anniversary, a guilt reframe, a grounding
exercise, an unsent-letter assignment, a medication update, and a planned
behavioral experiment for a family wedding.

- **Prompt tuning:**
  - *Objective from several sources at once:* a therapist observation ("I
    notice you're tearing up"), the client's own "I'm getting a little choked
    up again", and a racing heart during the session.
  - *Diagnosis and medication* are both explicitly discussed (major depressive
    disorder, recurrent; sertraline 100 mg), so they may be named.
  - *No risk content:* nothing to surface, so a correct note doesn't invent
    one.
- **De-identification:** the densest identifier block in the corpus, all in
  one administrative exchange: phone, an email containing a surname
  fragment (`rkowalski88@…`), an address with a spelled-out unit ("unit
  four"), an insurer, a named work account and an employer mentioned via
  HR, plus family and clinician names. Also "the number ending in 0199", a bare four-digit reference
  that the rules deliberately don't cover (see
  `tools/deidentify-helper/README.md`).

### 07 — couples session, single audio source (9 min)

Two partners on one call; a missed school pickup; the speaker-listener
technique; a shared calendar; an anniversary trip.

- **Prompt tuning:**
  - *Mis-attributed speakers:* both partners are labeled `Client:` because
    they share one microphone, the way `soapcap` would capture them. A good
    note tells Priya and Mike apart from context, as the prompt asks.
  - *Pronouns established:* here the transcript *does* use "her" and "he" for
    the two clients — the control case for the pronoun rule.
  - Client-narrated Objective ("I'm getting a little choked up").
- **De-identification:** both partners' names, **two children's names** (Emma
  and Noah), and a month-only date ("in August"), which the model never
  tagged without the month-name rule.

### 08 — full session (60 min)

A long, realistic session: a high-stakes work migration, caregiving for a
parent with Parkinson's, a relationship under strain, low mood tied to a
diagnosis anniversary, grounding, two thought records, a role-played
boundary conversation, medication, a support-group referral, and admin.

- **Prompt tuning:**
  - *Length:* the longest file, for checking that the context window is sized
    to the transcript (an undersized one silently drops the rules, which come
    first) and that later threads aren't lost.
  - *Objective, several ways:* "give me a second", "I notice you're tearing
    up", and "my chest feels a little tight".
  - *Risk screened, negative:* the therapist asks about self-harm and the
    client clearly denies it, which should be recorded without implying
    risk.
  - *Pronouns mixed:* client Theo has none stated; Sam, the dad, Naomi, and
    Dr. Whitcombe all do.
  - *A speaker-label trap:* in the role-play, a `Therapist:` line speaks as
    Naomi ("Theo, I really need you to take Tuesday again").
- **De-identification:** phone, an email containing a birth year
  (`theo.b1985@…`), a street address, an employer, an insurer, several
  third-party and clinician names, and an emergency-contact change — plus
  another "ending in" four-digit reference.
