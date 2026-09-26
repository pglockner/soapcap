## _intro
Output: the transcript below has numbered lines. Respond with a JSON
object whose fields are, in order:
## subjective
- subjective: prose, in full sentences — client-reported symptoms,
  concerns, and experiences since the last session. Empty string if the
  transcript contains none.
## objective_observations
- objective_observations: one entry per narrated in-the-moment reaction
  as defined above, each with the number of the line where it occurs,
  the speaker label on that line, and one sentence describing it in your
  own words. An empty list if the transcript contains none — never write
  a placeholder or "no observations" sentence; that is handled for you.
## assessment
- assessment: prose — clinical impression and progress toward treatment
  goals. Do not describe safety or risk here; that goes in risk, which
  is added to this section for you.
## response
- response: prose — how the client responded to the interventions used
  this session. Do not describe safety or risk here; that goes in risk,
  which is added to this section for you.
## risk
- risk: status is "disclosed" if anything suggesting risk to safety
  appears, "screened_negative" if safety was asked about and the client
  denied any risk, "not_addressed" otherwise; summary is one or two
  sentences documenting it (empty string when not_addressed).
## safety_plan
- safety_plan: if a safety plan was made or reviewed in this session,
  its contents, each entry a short noun phrase: warning_signs (signs the
  client identified that things are getting worse), coping_strategies
  (things the client can do on their own), supports (people the client
  can reach out to — crisis lines and emergency services belong in
  emergency_steps, not here), emergency_steps (what the client will do
  if they are in immediate danger). Include every item the transcript
  names and nothing it doesn't. All four lists empty if no safety plan
  was discussed. These are composed into the note for you.
## interventions_used
- interventions_used: one entry per technique or exercise the therapist
  actually carried out with the client during this session itself. Leave
  out anything that was only suggested, recommended, or assigned for
  later — that belongs in plan_items, and nothing should appear in both.
  action is a short past-tense verb phrase with no subject — the words
  that would complete "In session, the therapist …" — describing what
  was done the way the transcript describes it; never relabel it with a
  clinical term the transcript doesn't use. These are composed into a
  sentence for you. Include the number of the line where it takes place.
## plan_items
- plan_items: one entry per distinct homework or next step, follow-up,
  referral, or contact/administrative change. actor is who will do it:
  client, therapist, or both. action is a short verb phrase in base form,
  with no subject and no "will" — the words that would complete "agreed
  to …" — so name the action itself, never beginning with "commit to" or
  "agree to". These are composed into sentences for you. Include the
  number of the line where it is established.
## _phrases
- Every short phrase in safety_plan, interventions_used, and plan_items
  is dropped into the middle of a sentence as written, so write it the
  way it would read there — with "a", "an", or "the" where the sentence
  needs one.
## _closing
Line numbers go only in the line fields, never inside any text.
