"""soapcap's de-identify helper.

Reads a transcript body (speaker labels already stripped by the caller) on
stdin, runs it through OpenMed's on-device PII model plus two regex rules
(month names, 7+-digit numbers), and writes the same text back with detected
spans replaced by consistent, category-numbered tokens ([FIRST_NAME_1],
[PHONE_1], ...). A one-line summary goes to stderr. README.md has the full
stdin/stdout/exit-code contract.

Never touches the network: the model is downloaded by install.sh, and this
runs with the Hugging Face hub offline. `--fetch` (used by install.sh) is the
one exception.
"""

import os
import re
import sys

VERSION = "soapcap-deidentify-helper 0.3.0 (OpenMed PII model via MLX + month/long-number rules)"
MODEL = "OpenMed/OpenMed-PII-ClinicalE5-Small-33M-v1-mlx"
TOKENIZER = "OpenMed/OpenMed-PII-ClinicalE5-Small-33M-v1"
CONFIDENCE = 0.5
# Detection runs under two chunk-window layouts (token limit, overlap) and
# the results are merged. Neither is strictly better: each catches a phone
# number the other misses, because they put different text near a chunk
# boundary. 480 leaves headroom under the model's 512-token ceiling.
WINDOWS = ((256, 32), (480, 128))

# Case-sensitive on purpose: lowercase "may"/"march" are ordinary words; a
# capitalized sentence-initial "May" is the one known false positive.
MONTH_RULE = re.compile(
    r"\b(?:January|February|March|April|May|June|July|August|September|October"
    r"|November|December)(?:\s+\d{1,2}(?:st|nd|rd|th)?)?\b"
)
# Counts digits (7+) rather than matching a phone layout, because
# speech-to-text groups digits inconsistently ("123-456789" for a spoken SSN).
LONG_NUMBER_RULE = re.compile(r"(?<![\w-])(?=(?:-?\d){7})\d+(?:-\d+)*(?![\w-])")


def rule_spans(text):
    """(start, end, label, confidence) for the two regex rules."""
    spans = [(m.start(), m.end(), "date", 1.0) for m in MONTH_RULE.finditer(text)]
    for m in LONG_NUMBER_RULE.finditer(text):
        digits = sum(c.isdigit() for c in m.group())
        spans.append((m.start(), m.end(), "phone" if digits in (7, 10) else "id_num", 1.0))
    return spans


def chunks(offsets, limit, overlap):
    """Character ranges covering the text in windows of LIMIT tokens."""
    offsets = [(a, b) for a, b in offsets if a < b]
    if len(offsets) <= limit:
        return [(0, None)]
    out, start = [], 0
    while start < len(offsets):
        end = min(start + limit, len(offsets))
        out.append((offsets[start][0], offsets[end - 1][1]))
        if end == len(offsets):
            break
        start = max(start + 1, end - overlap)
    return out


def repeat_names(text, spans, canonical):
    """A name the model tagged once is redacted everywhere it appears as a
    whole word. The model misses an occasional repeat ("the Sam dinner"),
    and one missed mention undoes the rest."""
    names = {text[a:b] for a, b, label, _ in spans if canonical(label) in ("FIRST_NAME", "LAST_NAME")}
    found = {text[a:b]: label for a, b, label, _ in spans if text[a:b] in names}
    out = []
    for name, label in found.items():
        for m in re.finditer(rf"(?<!\w){re.escape(name)}(?!\w)", text):
            out.append((m.start(), m.end(), label, 1.0))
    return out


def remove_overlaps(spans):
    """Two overlapping replacements would corrupt the text, so keep the
    earliest span at each position, preferring longer then more confident,
    and drop anything that overlaps one already kept."""
    kept = []
    for span in sorted(spans, key=lambda s: (s[0], -(s[1] - s[0]), -s[3])):
        if kept and span[0] < kept[-1][1]:
            continue
        kept.append(span)
    return kept


def redact(text, spans, canonical):
    """Returns (redacted text, summary line)."""
    spans = remove_overlaps(spans)
    if not spans:
        return text, "no entities detected"
    # One token per (label, exact text), numbered by first appearance: two
    # different people never collide, repeats of one person always match.
    tokens, per_label, counts = {}, {}, {}
    for start, end, label, _ in spans:
        label = canonical(label)
        key = (label, text[start:end])
        if key not in tokens:
            per_label[label] = per_label.get(label, 0) + 1
            tokens[key] = f"[{label}_{per_label[label]}]"
        counts[label] = counts.get(label, 0) + 1
    out, pos = [], 0
    for start, end, label, _ in spans:
        out += [text[pos:start], tokens[(canonical(label), text[start:end])]]
        pos = end
    out.append(text[pos:])
    summary = f"redacted {len(spans)} span(s): " + ", ".join(f"{k} x{v}" for k, v in counts.items())
    return "".join(out), summary


def model_spans(text):
    from openmed import extract_pii
    from openmed.core.config import OpenMedConfig
    from tokenizers import Tokenizer

    config = OpenMedConfig(cache_dir=os.path.join(os.environ["HF_HOME"], "openmed"))
    tokenizer = Tokenizer.from_pretrained(TOKENIZER)
    tokenizer.no_truncation()  # its config truncates at 512; we chunk instead
    offsets = tokenizer.encode(text, add_special_tokens=False).offsets
    spans = []
    for limit, overlap in WINDOWS:
        for start, end in chunks(offsets, limit, overlap):
            result = extract_pii(text[start:end], model_name=MODEL,
                                 confidence_threshold=CONFIDENCE, config=config)
            spans += [(start + e.start, start + e.end, e.label, e.confidence) for e in result.entities]
    # A one-character span is a stray token ("haven't" -> "haven'[NAME]"),
    # never a whole identifier.
    return [s for s in spans if s[1] - s[0] > 1]


def main():
    if "--version" in sys.argv[1:]:
        print(VERSION)
        return 0
    # Model files live beside the venv, so removing the install directory
    # removes everything.
    os.environ.setdefault("HF_HOME", os.path.join(os.path.dirname(sys.prefix), "models"))
    fetch = "--fetch" in sys.argv[1:]
    if not fetch:
        os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    os.environ.setdefault("TRANSFORMERS_VERBOSITY", "error")
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

    try:
        text = "warm up" if fetch else sys.stdin.buffer.read().decode("utf-8")
    except UnicodeDecodeError:
        print("could not decode stdin as UTF-8", file=sys.stderr)
        return 1

    # The libraries print notices of their own; stderr is one line by contract.
    real_stderr = os.dup(2)
    devnull = os.open(os.devnull, os.O_WRONLY)
    os.dup2(devnull, 2)
    try:
        from openmed.core.labels import normalize_label
        spans = model_spans(text) + rule_spans(text) if text.strip() else []
        spans += repeat_names(text, spans, normalize_label)
        redacted, summary = redact(text, spans, normalize_label)
        status = 0
    except Exception as error:  # noqa: BLE001 - any failure maps to an exit code
        offline = "offline" in str(error).lower() or type(error).__name__ in (
            "LocalEntryNotFoundError", "OfflineModeIsEnabled")
        redacted = ""
        summary = (f"model weights unavailable: {error}" if offline
                   else f"de-identify failed: {type(error).__name__}: {error}")
        status = 2 if offline else 1
    finally:
        os.dup2(real_stderr, 2)
    summary = summary.splitlines()[0] if summary else "de-identify failed"
    if status == 0 and not fetch:
        sys.stdout.write(redacted)
    print(summary, file=sys.stderr)
    return status


if __name__ == "__main__":
    sys.exit(main())
