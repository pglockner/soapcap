# Structured style: check the model's note JSON against the transcript it
# was given (--rawfile transcript FILE, unnumbered; --arg format
# soap|dap|birp, to name sections the way that format does). Outputs a list of
# review messages for the clinician -- empty when nothing needs a look.
# Only mechanically checkable things: cited lines exist, an observation's
# speaker matches the speaker on the line it cites, quoted text really is
# in the transcript, no section copies transcript lines word for word, and
# a disclosed risk came with a safety plan.
include "common";

. as $note
| ($transcript | rtrimstr("\n") | split("\n")) as $lines
| ($lines | length) as $n
| ($transcript | norm) as $all
# Each transcript line's words (speaker label dropped), for lines long
# enough that finding one verbatim in the note can't be a coincidence.
| [ $lines | to_entries[]
    | {line: (.key + 1), words: (.value | sub("^[^:]*:\\s*"; "") | norm)}
    | select((.words | split(" ") | length) >= 8) ] as $long
# Where each field ends up in this format's note, for the messages.
| { subjective: ({soap: "Subjective", dap: "Data", birp: "Behavior"}[$format] // "Subjective"),
    objective:  ({soap: "Objective",  dap: "Data", birp: "Behavior"}[$format] // "Objective"),
    interventions: (if $format == "birp" then "Intervention" else "Plan" end) } as $sec
| def line_ok($l): ($l | type) == "number" and $l >= 1 and $l <= $n;
  def excerpt($l): $lines[$l - 1] | if length > 90 then .[:87] + "..." else . end;
  def unverified($text; $where):
    $text | quotes[] | select((norm) as $q | $all | contains($q) | not)
    | "\($where): quoted text isn't in the transcript: \"\(.)\"";
  def reprinted($text; $where):
    ($text | norm) as $t
    | [$long[] | select(.words as $w | $t | contains($w)) | .line]
    | select(length > 0)
    | "\($where) copies the transcript word for word (line\(if length > 1 then "s" else "" end) "
      + (map(tostring) | oxford) + ") instead of summarizing it";
  [
    ( if ($note.risk.status // "") == "disclosed"
           and ([($note.safety_plan // {})[]?[]?] | length) == 0
      then "A safety risk came up, but no safety plan was recorded -- add it if one was discussed"
      else empty end ),
    ( ($note.objective_observations // [])[] as $o
      | if (line_ok($o.line) | not) then "\($sec.objective) cites line \($o.line), which doesn't exist"
        elif ($lines[$o.line - 1] | startswith(($o.speaker // "") + ":") | not)
          then "\($sec.objective) attributes a reaction to the \($o.speaker), but line \($o.line) is: \(excerpt($o.line))"
        else empty end ),
    ( ($note.interventions_used // [])[]
      | select(line_ok(.line) | not) | "\($sec.interventions) cites line \(.line), which doesn't exist" ),
    ( ($note.plan_items // [])[]
      | select(line_ok(.line) | not) | "Plan cites line \(.line), which doesn't exist" ),
    reprinted($note.subjective // ""; $sec.subjective),
    reprinted([($note.objective_observations // [])[] | .text] | join(" "); $sec.objective),
    reprinted($note.assessment // ""; "Assessment"),
    reprinted($note.response // ""; "Response"),
    unverified($note.subjective // ""; $sec.subjective),
    ( ($note.objective_observations // [])[] | unverified(.text; $sec.objective) ),
    unverified($note.assessment // ""; "Assessment"),
    unverified($note.response // ""; "Response"),
    unverified($note.risk.summary // ""; "Risk"),
    ( ($note.interventions_used // [])[] | unverified(.action; $sec.interventions) ),
    ( ($note.plan_items // [])[] | unverified(.action; "Plan") )
  ]
