# SOAP Objective: the therapist's fixed mental-status frame, filled in from
# the Objective pass's JSON (prompts/objective.md). Input: that JSON, null
# when the pass failed, or {"no_client": true} when the transcript had no
# client lines to assess. --rawfile note FILE: the narrative note, whose
# own risk language is a second check before "No SI/HI reported." is
# written -- one missed disclosure in one pass must not be enough to print
# it. Output: the Objective section's body.
include "common";

def slot: if (. // "") | blank then "[not assessed]"
          else sub("^\\s+"; "") | sub("[\\s.;,]+$"; "") end;
def cap: (.[:1] | ascii_upcase) + .[1:];
# Mid-sentence slots start lowercase ("Affect constricted"), unless the
# word is an acronym.
def low: if test("^[A-Z][a-z]") then (.[:1] | ascii_downcase) + .[1:] else . end;

# Risk language the narrative note uses, minus plain denials ("denied
# suicidal ideation", "no indication of self-harm or suicidal ideation"),
# which are what "No SI/HI reported" means anyway. The gap between the
# denial and the risk term can't cross "but"/"however"/..., so "denied a
# plan but reported passive suicidal ideation" still counts as risk.
def mentions_risk:
  "(suicid[a-z]*|homicid[a-z]*|selfharm|self harm)( ideation| thoughts| behaviou?rs?)?" as $term
  | "(?:(?!\\b(but|though|although|however|yet|except)\\b)[a-z ]){0,40}?" as $gap
  | norm
  | gsub("\\b(denied|denies|denying|no|not|without)\\b" + $gap + $term
         + "(( or| and| nor)" + $gap + $term + ")*"; "")
  | test(risk_pattern);

# A disclosure is named by kind only, from a fixed list: a small model's
# own one-line summary called an active plan with means "passive, no
# plan or intent" in testing. The details are in Assessment and Plan.
def si_hi($ms):
  if $ms == null then "[SI/HI status not assessed; confirm before signing.]"
  elif ($ms.risk.status // "") == "disclosed" then
    ({"SI": "SI", "HI": "HI", "SI and HI": "SI and HI", "self-harm": "Self-harm"}[$ms.risk_kind // ""]
       // "Safety risk") + " reported; see Assessment and Plan."
  elif ($note | mentions_risk) then
    "[The note mentions a safety concern; confirm SI/HI status before signing.]"
  else "No SI/HI reported." end;

. as $x
| if ($x | type) == "object" and $x.no_client == true then
    "On time via video. [No client speech was captured; complete the Objective manually.] " + si_hi(null)
  elif $x == null or ($x.mental_status | type) != "object" then
    "On time via video. [Objective could not be drafted; complete manually.] " + si_hi(null)
  else
    $x.mental_status as $m
    | "On time via video. \($m.engagement | slot | cap). "
      + "Affect \($m.affect | slot | low); mood \($m.mood | slot | low). "
      + "Speech \($m.speech | slot | low). "
      + "Thought process \($m.thought_process | slot | low). "
      + "Insight \($m.insight | slot | low); judgment \($m.judgment | slot | low). "
      + "\($m.psychomotor | slot | cap). "
      + si_hi($x)
  end
