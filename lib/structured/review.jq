# Combined style: cross-check a NARRATIVE note against a structured
# extraction of the same transcript. Input: the extraction JSON.
#   --rawfile note FILE  --rawfile transcript FILE  --arg format soap|dap|birp
# Output: {flags: [message...], steps: [{line, action}...]}.
# Flags are the checks that can be made reliably against prose: quotes
# that aren't in the transcript, and risk or a safety screen that came up
# but isn't in the note. (SOAP's Objective is written by code from its own
# pass -- lib/structured/objective.jq -- so there's nothing to check there.)
# Next steps are listed as a checklist, not judged: word-overlap matching
# was tried and was wrong more often than right (it can't tell a rewording
# from an omission).
include "common";

. as $x
| ($transcript | norm) as $all
| ($note | norm) as $n
| {
    flags: [
      ( $note | quotes[] | select((norm) as $q | $all | contains($q) | not)
        | "Quoted text isn't in the transcript: \"\(.)\"" ),
      ( if ($x.risk.status // "") == "disclosed"
             and ($n | test(risk_pattern) | not)
          then "A safety risk came up in the session, but the note doesn't mention it"
        elif ($x.risk.status // "") == "screened_negative"
             and ($n | test("(denied|denies|no) [a-z ]{0,40}(suicid|self harm|selfharm|harm|safety|risk|unsafe)|no (current )?risk") | not)
          then "Safety was asked about and denied, but the note doesn't record that screen"
        else empty end )
    ],
    steps: [ ($x.plan_items // [])[] | {line, action: (.action | phrase)}
             | select(.action | blank | not) ]
  }
