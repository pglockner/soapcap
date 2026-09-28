# Shared helpers for the structured note style (render.jq, validate.jq,
# review.jq). Loaded with: jq -L "$SC_ROOT/lib/structured" 'include "common"; ...'

def blank: (gsub("\\s"; "") == "");

# Lowercase, straighten curly quotes, drop punctuation, collapse space --
# so a quote can be matched against the transcript regardless of how the
# model typed its apostrophes or dashes.
def norm:
  ascii_downcase
  | gsub("[‘’]"; "'") | gsub("[“”]"; "\"")
  | gsub("[^a-z0-9 \n]"; "") | gsub("\\s+"; " ")
  | ltrimstr(" ") | rtrimstr(" ");

# Quoted spans of 4+ characters. Every span is extracted first and only
# then length-filtered: filtering inside the regex would let a skipped
# short quote ("yes") pair the wrong quote marks and swallow the text
# between two real quotes as one bogus span.
def quotes: [scan("[\"“]([^\"“”]*)[\"”]") | .[0] | select(length >= 4)];

# Words in a note that suggest a safety risk was documented. Matched
# against norm'd text, so "self-harm" arrives as "selfharm".
def risk_pattern: "suicid|homicid|self harm|selfharm|harm (themself|themselves|himself|herself|others|someone)|better off|safety plan|988|crisis";

def fallback: "No observable presentation details available from a text-only transcript.";

# Tidy a model phrase so it fits mid-sentence: trim, drop trailing
# punctuation, a leading "to ", and a leading "commit to"/"agree to" that
# would double up with the sentence's own verb. Case is left alone --
# forcing lowercase mangled proper nouns ("camila (sister)").
def phrase:
  sub("^\\s+"; "") | sub("[\\s.;,]+$"; "") | sub("^[Tt]o\\s+"; "")
  | sub("^([Cc]ommit(ted)?|[Aa]gree(d)?)\\s+to\\s+"; "");

def oxford:
  if length == 0 then "" elif length == 1 then .[0]
  elif length == 2 then "\(.[0]) and \(.[1])"
  else (.[:-1] | join(", ")) + ", and " + .[-1] end;

def chunks($n): [range(0; length; $n) as $i | .[$i:$i+$n]];

def section($s): if ($s | blank) then "Not addressed in this session" else $s end;
