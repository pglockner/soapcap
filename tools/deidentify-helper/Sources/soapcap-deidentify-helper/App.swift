import Foundation
import OpenMedKit

// soapcap-deidentify-helper — reads a transcript body (labels already
// stripped by the caller) on stdin, runs it through OpenMedKit's on-device
// Privacy Filter model plus two regex rules (month names, 7+-digit numbers),
// and writes the same text back with detected PII
// spans replaced by consistent, category-numbered bracket tokens
// ([FIRST_NAME_1], [PHONE_1], ...). A one-line human-readable summary
// goes to stderr. See the repo README for the full stdin/stdout/exit-code
// contract this implements.

let privacyFilterRepoID = "OpenMed/OpenMed-PII-ClinicalE5-Small-33M-v1-mlx"

func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func writeStdout(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
}

// extractPII's single-chunk path does not always fully dedupe overlapping
// detections (confirmed empirically: "Camila" (51-57) and a nested partial
// match "ila" (54-57) both came back tagged first_name for the same real
// span). Two overlapping replacements corrupt the output text, so this is
// a hard prerequisite for redact() below, not an optimization -- greedy
// interval scheduling sorted by (start asc, length desc, confidence desc)
// so the first-accepted candidate at each position is the best one, and
// anything overlapping an already-accepted span is dropped rather than
// risking corruption.
func removeOverlaps(_ entities: [EntityPrediction]) -> [EntityPrediction] {
    let sorted = entities.sorted { a, b in
        if a.start != b.start { return a.start < b.start }
        let aLen = a.end - a.start, bLen = b.end - b.start
        if aLen != bLen { return aLen > bLen }
        return a.confidence > b.confidence
    }
    var result: [EntityPrediction] = []
    for entity in sorted {
        if let last = result.last, entity.start < last.end {
            continue
        }
        result.append(entity)
    }
    return result
}

// Two deterministic rules layered on top of the model, for categories the
// model was confirmed to miss or partially redact on the sample-transcript
// corpus (see README "Rule-based detections"). Case-sensitive on purpose:
// lowercase "may"/"march" are ordinary words; a capitalized sentence-initial
// "May" is the one known false positive. The long-number rule counts digits
// (7+) rather than matching a phone layout because speech-to-text groups
// digits inconsistently ("123-456789" for a spoken SSN); exactly 7 or 10
// digits is labeled PHONE, anything else ID_NUM.
let monthRule = try! NSRegularExpression(
    pattern: #"\b(?:January|February|March|April|May|June|July|August|September|October|November|December)(?:\s+\d{1,2}(?:st|nd|rd|th)?)?\b"#
)
let longNumberRule = try! NSRegularExpression(
    pattern: #"(?<![\w-])(?=(?:-?\d){7})\d+(?:-\d+)*(?![\w-])"#
)

// EntityPrediction offsets are Unicode scalar offsets, not UTF-16 or
// Character offsets -- transcripts contain em-dashes, so the conversion
// matters.
func ruleEntities(in text: String) -> [EntityPrediction] {
    let whole = NSRange(text.startIndex..., in: text)
    let scalars = text.unicodeScalars
    func entity(_ label: String, _ match: NSTextCheckingResult) -> EntityPrediction? {
        guard let range = Range(match.range, in: text) else { return nil }
        return EntityPrediction(
            label: label, text: String(text[range]), confidence: 1.0,
            start: scalars.distance(from: scalars.startIndex, to: range.lowerBound),
            end: scalars.distance(from: scalars.startIndex, to: range.upperBound)
        )
    }
    let months = monthRule.matches(in: text, range: whole).compactMap { entity("date", $0) }
    let numbers = longNumberRule.matches(in: text, range: whole).compactMap { match -> EntityPrediction? in
        guard let range = Range(match.range, in: text) else { return nil }
        let digits = text[range].filter(\.isNumber).count
        return entity(digits == 7 || digits == 10 ? "phone" : "id_num", match)
    }
    return months + numbers
}

// Builds the redacted text and its one-line summary. Public logic lives
// here (not in main.swift's top level) so it stays testable in isolation
// if this ever grows real unit tests.
func redact(text: String, rawEntities: [EntityPrediction]) -> (redacted: String, summary: String) {
    // Snap to grapheme-cluster boundaries first (matches OpenMedKit's own
    // internal practice in DeidentificationResult) so a span never splits
    // a combining-character sequence in half, then drop overlaps.
    let snapped = rawEntities.compactMap { $0.snappedToGraphemeBoundaries(in: text) }
    let entities = removeOverlaps(snapped)
    guard !entities.isEmpty else {
        return (text, "no entities detected")
    }

    // Assign a token per unique (canonical label, exact matched text) pair,
    // numbered by first appearance -- two different people never collide,
    // repeated mentions of the same person always match.
    var tokenForKey: [String: String] = [:]
    var countForLabel: [String: Int] = [:]
    var labelOrder: [String] = []
    var spanCountForLabel: [String: Int] = [:]

    for entity in entities.sorted(by: { $0.start < $1.start }) {
        let label = Policy.canonicalLabel(for: entity.label)
        let key = "\(label)\u{0}\(entity.text)"
        if tokenForKey[key] == nil {
            let n = (countForLabel[label] ?? 0) + 1
            countForLabel[label] = n
            tokenForKey[key] = "[\(label)_\(n)]"
        }
        spanCountForLabel[label, default: 0] += 1
        if !labelOrder.contains(label) {
            labelOrder.append(label)
        }
    }

    // Substitute in descending-start order so earlier offsets stay valid
    // as replacement length differs from the original span -- the same
    // pattern OpenMedKit's own internal deidentifiedText() uses.
    var redacted = text
    for entity in entities.sorted(by: { $0.start > $1.start }) {
        guard let range = entity.range(in: redacted) else { continue }
        let label = Policy.canonicalLabel(for: entity.label)
        guard let token = tokenForKey["\(label)\u{0}\(entity.text)"] else { continue }
        redacted.replaceSubrange(range, with: token)
    }

    let summary =
        "redacted \(entities.count) span(s): "
        + labelOrder.map { "\($0) x\(spanCountForLabel[$0] ?? 0)" }.joined(separator: ", ")
    return (redacted, summary)
}

@main
struct SoapcapDeidentifyHelper {
    static func main() async {
        if CommandLine.arguments.dropFirst().contains("--version") {
            print("soapcap-deidentify-helper 0.2.0 (OpenMedKit Privacy Filter + month/long-number rules)")
            exit(0)
        }

        let inputData = FileHandle.standardInput.readDataToEndOfFile()
        guard let text = String(data: inputData, encoding: .utf8) else {
            writeStderr("could not decode stdin as UTF-8")
            exit(1)
        }

        do {
            let modelDirectory = try await OpenMedModelStore.downloadMLXModel(
                repoID: privacyFilterRepoID
            )
            let openmed = try OpenMed(backend: .mlx(modelDirectoryURL: modelDirectory))
            // Run detection under two different chunk-window layouts and
            // merge the results, rather than trusting a single layout.
            // Confirmed empirically that tuning the window is a lateral
            // tradeoff, not a strict improvement: the default (256/32)
            // missed a clearly-formatted phone number that a wider,
            // more-overlapping window (480/128 -- the model's real
            // 512-token ceiling, minus headroom for special tokens) did
            // catch -- but that same wider window then MISSED a different
            // phone number in a different transcript that the default had
            // caught. Different window layouts put different content at
            // different distances from a chunk boundary, so neither
            // layout is strictly better; running both and merging (via
            // removeOverlaps, which already prefers the longer/higher-
            // confidence span on any conflict) covers both cases at once,
            // for roughly 2x inference time on an already-fast model.
            let defaultPass = try openmed.extractPIIChunked(
                text, confidenceThreshold: 0.5,
                chunkTokenLimit: 256, tokenOverlap: 32
            )
            let widePass = try openmed.extractPIIChunked(
                text, confidenceThreshold: 0.5,
                chunkTokenLimit: 480, tokenOverlap: 128
            )

            // Rule matches merge through the same removeOverlaps() as the
            // model's spans. A full "555-0233" rule span starts earlier and is
            // longer than a partial model span like "-0233", so it wins --
            // which also closes the partial-boundary leak (README).
            let (redactedText, summary) = redact(
                text: text, rawEntities: defaultPass + widePass + ruleEntities(in: text)
            )
            writeStdout(redactedText)
            writeStderr(summary)
            exit(0)
        } catch let error as OpenMedModelStoreError {
            writeStderr("model weights unavailable: \(error.localizedDescription)")
            exit(2)
        } catch {
            writeStderr("de-identify failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
