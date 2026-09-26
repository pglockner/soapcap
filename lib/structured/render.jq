# Structured style: render the model's note JSON as the final plain-text
# note for $format (soap|dap|birp). Every format rule the narrative prompts
# ask the model to follow is guaranteed here instead -- exact headers,
# prose (no lists), the Objective fallback XOR real observations, "Not
# addressed" for empty sections, and risk stated whenever it came up --
# and Plan prose is composed from the model's short phrases.
include "common";

def observations:
  [(.objective_observations // [])[] | .text | select(blank | not)] | join(" ");
def presentation: observations as $o | if $o == "" then fallback else $o end;
def risk_text: if (.risk.status // "not_addressed") != "not_addressed" then (.risk.summary // "") else "" end;
def prose($parts): [$parts[] | select(blank | not)] | join(" ");

# Four to a sentence: a model can list every question asked as its own
# intervention (seen with BIRP), and one 20-item sentence is unreadable.
def interventions_sentence:
  ["In session, the therapist", "The therapist also", "The therapist additionally",
   "The therapist further"] as $openers
  | [(.interventions_used // [])[] | .action | select(blank | not) | phrase]
  | chunks(4) | to_entries[] | "\($openers[.key % 4]) \(.value | oxford).";

def safety_plan_sentence:
  (.safety_plan // {}) as $s
  | [ ["warning signs", "warning_signs"], ["coping strategies", "coping_strategies"],
      ["supports", "supports"], ["emergency steps", "emergency_steps"] ]
  | map(.[0] as $part | [($s[.[1]] // [])[] | select(blank | not) | phrase]
        | select(length > 0) | "\($part): \(oxford)")
  # Semicolons between the parts, since a part's own items can hold commas
  # (and parentheses, e.g. "sister (Camila)").
  | if length == 0 then empty
    elif length == 1 then "The safety plan identified \(.[0])."
    else "The safety plan identified " + (.[:-1] | join("; ")) + "; and " + .[-1] + "." end;

def plan_sentences:
  (.plan_items // []) as $items
  | ["The client agreed to", "The client also planned to",
     "Additionally, the client agreed to", "The client further agreed to"] as $openers
  | ([$items[] | select(.actor == "client") | .action | select(blank | not) | phrase]
     | chunks(3) | to_entries[] | "\($openers[.key % 4]) \(.value | oxford)."),
    ([$items[] | select(.actor == "therapist") | .action | select(blank | not) | phrase]
     | if length == 0 then empty else "The therapist will \(oxford)." end),
    ([$items[] | select(.actor == "both") | .action | select(blank | not) | phrase]
     | if length == 0 then empty else "The client and therapist agreed to \(oxford)." end);

if $format == "soap" then
  "SUBJECTIVE:\n" + section(.subjective // "")
  + "\n\nOBJECTIVE:\n" + presentation
  + "\n\nASSESSMENT:\n" + section(prose([.assessment // "", risk_text]))
  + "\n\nPLAN:\n" + section(prose([interventions_sentence, safety_plan_sentence, plan_sentences]))
elif $format == "dap" then
  "DATA:\n" + prose([.subjective // "", presentation])
  + "\n\nASSESSMENT:\n" + section(prose([.assessment // "", risk_text]))
  + "\n\nPLAN:\n" + section(prose([interventions_sentence, safety_plan_sentence, plan_sentences]))
elif $format == "birp" then
  "BEHAVIOR:\n" + prose([.subjective // "", presentation])
  + "\n\nINTERVENTION:\n" + section(prose([interventions_sentence]))
  + "\n\nRESPONSE:\n" + section(prose([.response // "", risk_text]))
  + "\n\nPLAN:\n" + section(prose([safety_plan_sentence, plan_sentences]))
else error("unknown format: \($format)") end
