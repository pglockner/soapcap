# Combined style: cross-check a NARRATIVE note against a structured
# extraction of the same transcript. Input: the extraction JSON.
#   --rawfile note FILE  --rawfile transcript FILE  --arg format soap|dap|birp
# Output: {flags: [message...], steps: [{line, action}...]}.
# Flags are the checks that can be made reliably against prose: quotes
# that aren't in the transcript, SOAP's Objective saying "none" when the
# transcript has in-the-moment reactions (or the reverse), and risk or a
# safety screen that came up but isn't in the note. Next steps are listed
# as a checklist, not judged: word-overlap matching was tried and was wrong
# more often than right (it can't tell a rewording from an omission).
include "common";

def note_section($name):
  (capture("(?s)(^|\\n)" + $name + ":\\s*(?<body>.*?)(\\n[A-Z]+:|$)").body // "") | sub("\\s+$"; "");

. as $x
| ($transcript | norm) as $all
| ($note | norm) as $n
| ($x.objective_observations // []) as $obs
| {
    flags: [
      ( $note | quotes[] | select((norm) as $q | $all | contains($q) | not)
        | "Quoted text isn't in the transcript: \"\(.)\"" ),
      ( select($format == "soap") | ($note | note_section("OBJECTIVE")) as $o
        | if ($o == fallback) and ($obs | length) > 0
            then "Objective says there were no observable reactions, but the transcript has "
                 + ([$obs[] | "one at line \(.line) (\(.speaker))"] | oxford)
          elif ($o != fallback) and ($o | blank | not) and ($obs | length) == 0
            then "Objective describes reactions, but none were found in the transcript -- check it's not general, reported content"
          else empty end ),
      ( if ($x.risk.status // "") == "disclosed"
             and ($n | test("suicid|self harm|selfharm|harm (themself|themselves|himself|herself)|better off|safety plan|988|crisis") | not)
          then "A safety risk came up in the session, but the note doesn't mention it"
        elif ($x.risk.status // "") == "screened_negative"
             and ($n | test("(denied|denies|no) [a-z ]{0,40}(suicid|self harm|selfharm|harm|safety|risk|unsafe)|no (current )?risk") | not)
          then "Safety was asked about and denied, but the note doesn't record that screen"
        else empty end )
    ],
    steps: [ ($x.plan_items // [])[] | {line, action: (.action | phrase)}
             | select(.action | blank | not) ]
  }
