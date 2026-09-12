# shellcheck shell=bash
# soapcap — turn yap JSON into a readable, speaker-attributed transcript.
#
# Reads a yap JSON document on stdin, writes plain text on stdout:
#
#   Therapist: How was the week?
#   Client: Rough. I barely slept.
#
# `listen-and-dictate` tags every segment with a `speaker`, but that label is
# which AUDIO SOURCE picked it up (mic vs. system), not a voiceprint. Apple's
# Speech framework has no public on-device speaker-diarization API, and
# without headphones there's a real, one-directional leak: whatever plays
# through your speakers (the other party) is acoustically audible in the
# room, so your microphone hears it too and yap dutifully transcribes it a
# second time under the mic label. The reverse doesn't happen — your own
# voice never loops back into system audio.
#
# The dedupe pass removes that leak: any mic-side segment whose wording is
# largely contained in a system-side segment nearby in time is dropped as
# an echo, not real mic-side speech. Bias is toward NOT dropping when
# unsure — a missed echo is a harmless duplicate line; a wrongly dropped
# real segment is lost content — so the thresholds below are conservative.
#
# Verified against a real captured conversation (yap 1.2.1, macOS 26): the
# two channels segment near-identically when the "leak" is a clean copy
# rather than a muffled one, chopping each long utterance into one long
# chunk plus a short 1-3 word trailing fragment ("...session?", "you up.").
# Containment (does the SHORTER segment's wording fully appear in the
# longer one?) catches those trailing fragments; plain word-overlap
# (Jaccard) does not, because it penalizes the length mismatch between a
# 2-word fragment and the 8-word utterance it trails. Containment alone is
# too permissive at 1 word, though (any single common word — "yeah", "so",
# "right" — trivially "contains" 1/1) so minwords stays as the floor.

: "${SOAPCAP_DEDUPE_WINDOW:=3.5}"     # how far apart (s) two segments can start/end and still be "the same moment"
: "${SOAPCAP_DEDUPE_THRESHOLD:=0.7}"  # word-containment ratio (0-1) required to call it an echo
: "${SOAPCAP_DEDUPE_MINWORDS:=2}"     # segments shorter than this are never auto-dropped

# sc_render_transcript <mic_label> <system_label> [dedupe: 1|0]
#   mic_label / system_label: empty for single-track input (e.g. `transcribe`)
#     — dedupe is a no-op in that case since there is nothing to compare against.
sc_render_transcript() {
  local mic="${1:-}" sys="${2:-}" dedupe="${3:-1}"
  local dedupe_json="true"
  [ "$dedupe" = "1" ] || dedupe_json="false"

  jq -r \
    --arg mic "$mic" \
    --arg sys "$sys" \
    --argjson dedupe "$dedupe_json" \
    --argjson window "$SOAPCAP_DEDUPE_WINDOW" \
    --argjson thresh "$SOAPCAP_DEDUPE_THRESHOLD" \
    --argjson minwords "$SOAPCAP_DEDUPE_MINWORDS" \
    '
    def words:
      ascii_downcase
      | gsub("[^a-z0-9]"; " ")
      | splits(" +")
      | select(length > 0);

    def wordset: [words] | unique;

    # Fraction of $a'"'"'s words that also appear in $b, normalized by the
    # SHORTER of the two word counts — so a short fragment fully contained
    # in a longer segment scores 1.0 regardless of how much longer $b is.
    def containment($a; $b):
      ($a | length) as $la | ($b | length) as $lb
      | (if $la < $lb then $la else $lb end) as $m
      | if $m == 0 then 0
        else ($a | map(select(. as $x | $b | index($x) != null)) | length) / $m
        end;

    [ .segments[]
      | { speaker: (.speaker // "Speaker"),
          start:   (.start // 0),
          end:     (.end   // (.start // 0)),
          id:      (.id    // 0),
          text:    (.text  // "" | gsub("^\\s+|\\s+$"; "")) }
      | select(.text != "")
      | . + { ws: (.text | wordset) } ]
    | sort_by(.start, .id) as $all
    | ($all | map(select(.speaker == $sys))) as $sys_segs
    | ( if ($dedupe and $mic != "" and $sys != "" and $mic != $sys and ($sys_segs | length) > 0) then
          $all | map(
            . as $m
            | if ($m.speaker == $mic)
                 and ($m.ws | length) >= $minwords
                 and any($sys_segs[];
                       ($m.start - $window) <= .end
                       and .start <= ($m.end + $window)
                       and (containment($m.ws; .ws) >= $thresh))
              then $m + { echo: true }
              else $m
              end)
        else $all
        end )
    | map(select(.echo | not))
    | reduce .[] as $s ([];
        if (length > 0 and .[-1].speaker == $s.speaker)
        then .[:-1] + [ .[-1] + { text: (.[-1].text + " " + $s.text) } ]
        else . + [ { speaker: $s.speaker, text: $s.text } ]
        end)
    | .[] | "\(.speaker): \(.text)"
    '
}

# sc_merge_runs FILE...
#
# Concatenates multiple yap JSON documents (one per pause/resume leg — see
# sc_capture_session) into one {"segments": [...]} document on stdout, in
# order, each run's timestamps shifted to continue where the previous run's
# last segment left off. The shift only needs to preserve ORDERING across
# runs — sc_render_transcript discards all timing info once it has sorted
# by it — so it doesn't attempt to reflect how long a pause actually lasted;
# it just guarantees run 2's segments all sort after run 1's.
sc_merge_runs() {
  jq -s '
    reduce .[] as $doc
      ( {segments: [], off: 0};
        . as $acc
        | ($doc.segments // []) as $segs
        | ( $segs
            | map(. + { start: ((.start // 0) + $acc.off),
                        end:   ((.end // .start // 0) + $acc.off) })
          ) as $shifted
        | ( $segs | map(.end // .start // 0) ) as $ends
        | ( if ($ends | length) > 0 then ($ends | max) else 0 end ) as $rundur
        | { segments: ($acc.segments + $shifted), off: ($acc.off + $rundur + 0.001) }
      )
    | { segments: .segments }
  ' "$@"
}
