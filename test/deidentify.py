"""Tests for tools/deidentify/deidentify.py's text logic: the regex rules,
chunking, overlap removal and token substitution. The model itself isn't
loaded. Run by test/run.sh when python3 is available."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools", "deidentify"))
import deidentify as d  # noqa: E402

upper = str.upper


def spans(text, *pairs):
    return [(text.index(t), text.index(t) + len(t), label, 0.9) for t, label in pairs]


class Rules(unittest.TestCase):
    def labels(self, text):
        return [(text[a:b], label) for a, b, label, _ in d.rule_spans(text)]

    def test_month_with_day(self):
        self.assertEqual(self.labels("born March 14th, I may go"), [("March 14th", "date")])

    def test_long_numbers(self):
        self.assertEqual(self.labels("call 555-0199 or 988"), [("555-0199", "phone")])
        self.assertEqual(self.labels("id 123-456789"), [("123-456789", "id_num")])


class Chunks(unittest.TestCase):
    def test_short_text_is_one_chunk(self):
        self.assertEqual(d.chunks([(0, 2), (3, 5)], 256, 32), [(0, None)])

    def test_windows_overlap_and_cover_the_end(self):
        offsets = [(i, i + 1) for i in range(10)]
        self.assertEqual(d.chunks(offsets, 4, 1), [(0, 4), (3, 7), (6, 10)])


class Redact(unittest.TestCase):
    def test_same_text_same_token(self):
        text = "Ana met Ben. Ana left."
        s = [(0, 3, "first_name", 0.9), (8, 11, "first_name", 0.9), (13, 16, "first_name", 0.9)]
        out, summary = d.redact(text, s, upper)
        self.assertEqual(out, "[FIRST_NAME_1] met [FIRST_NAME_2]. [FIRST_NAME_1] left.")
        self.assertEqual(summary, "redacted 3 span(s): FIRST_NAME x3")

    def test_nested_span_is_dropped(self):
        text = "my sister Camila has"
        s = spans(text, ("Camila", "first_name")) + [(13, 16, "first_name", 0.99)]
        self.assertEqual(d.redact(text, s, upper)[0], "my sister [FIRST_NAME_1] has")

    def test_longer_span_wins_at_the_same_start(self):
        text = "call 555-0233 now"
        s = [(5, 13, "phone", 1.0), (5, 8, "phone", 0.6)]
        self.assertEqual(d.redact(text, s, upper)[0], "call [PHONE_1] now")

    def test_nothing_found(self):
        self.assertEqual(d.redact("hello", [], upper), ("hello", "no entities detected"))

    def test_line_count_is_kept(self):
        text = "Ana\nsaid\nhi"
        self.assertEqual(d.redact(text, [(0, 3, "first_name", 0.9)], upper)[0].count("\n"), 2)


class RepeatNames(unittest.TestCase):
    def test_missed_repeat_is_caught_as_a_whole_word(self):
        text = "Sam called. The Sam dinner, not the Samuel one."
        found = d.repeat_names(text, [(0, 3, "FIRST_NAME", 0.9)], upper)
        self.assertEqual(sorted((a, b) for a, b, _, _ in found), [(0, 3), (16, 19)])

    def test_other_labels_are_not_repeated(self):
        text = "at noon, around noon"
        self.assertEqual(d.repeat_names(text, [(3, 7, "TIME", 0.9)], upper), [])


if __name__ == "__main__":
    unittest.main(verbosity=0)
