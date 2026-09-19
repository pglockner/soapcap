import AppKit
import SwiftUI

@MainActor
final class SessionModel: ObservableObject {
    enum Phase: Equatable {
        case idle, recording, paused, working(String), transcript, note, error(String)
    }
    private enum StopReason { case pause, finish }

    static let formats = ["soap", "dap", "birp"]

    @Published var phase: Phase = .idle
    @Published var deidentify = true
    @Published var format = "soap"
    @Published var transcript = ""
    @Published var note = ""
    @Published var notice = ""
    @Published var elapsed = 0      // seconds recorded, across all legs
    @Published var legElapsed = 0   // seconds in the current leg
    @Published var copied = false

    let canDeidentify = Runner.deidentifyAvailable
    private var live: Runner.Live?
    private var legStart = Date()
    private var priorElapsed = 0
    private var pieces: [String] = []
    private var lastErr = ""
    private var stopReason: StopReason?
    private var timer: Timer?
    /// Bumped by newSession() so a leg that finishes afterwards is ignored.
    private var generation = 0

    /// yap needs about 3s to start; stopping or pausing earlier loses the
    /// leg (soapcap doctor's own probe runs for 3s too).
    var canStop: Bool { legElapsed >= 3 }

    func start() {
        pieces = []; priorElapsed = 0; lastErr = ""; notice = ""; copied = false
        beginLeg()
    }

    /// Each pause ends the current `soapcap live` and each resume starts a
    /// new one, so nothing is captured while paused. Legs are joined at the end.
    private func beginLeg() {
        let leg: Runner.Live
        do { leg = try Runner.Live() } catch {
            phase = .error("could not start soapcap: \(error)"); return
        }
        live = leg
        stopReason = nil
        legStart = Date(); legElapsed = 0; elapsed = priorElapsed
        phase = .recording
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.legElapsed = Int(Date().timeIntervalSince(self.legStart))
                self.elapsed = self.priorElapsed + self.legElapsed
            }
        }
        let gen = generation
        Task { let r = await leg.finish(); await self.legFinished(r, generation: gen) }
    }

    func pause() { requestStop(.pause) }

    func resume() { if phase == .paused { beginLeg() } }

    func stop() {
        if phase == .paused { Task { await finalize() } } else { requestStop(.finish) }
    }

    private func requestStop(_ reason: StopReason) {
        guard phase == .recording, canStop else { return }
        stopReason = reason
        live?.stop()
        phase = .working(reason == .pause ? "Pausing…" : "Finishing transcription…")
    }

    private func legFinished(_ r: (transcript: String, err: String, status: Int32), generation gen: Int) async {
        guard gen == generation else { return }
        timer?.invalidate(); timer = nil
        live = nil
        priorElapsed = elapsed
        if !r.transcript.isEmpty { pieces.append(r.transcript) }
        if !r.err.isEmpty { lastErr = r.err }
        if notice.isEmpty { notice = Self.cleanNotice(r.err) }
        if stopReason == .pause { phase = .paused } else { await finalize() }
    }

    private func finalize() async {
        guard !pieces.isEmpty else {
            phase = .error("No transcript captured.\n\n\(lastErr)"); return
        }
        transcript = Self.joinPieces(pieces)
        if deidentify && canDeidentify {
            phase = .working("De-identifying the transcript…")
            let d = await Runner.pipe(["deidentify"], input: transcript)
            if d.status == 0 {
                transcript = d.out.trimmingCharacters(in: .newlines)
                notice = "transcript: \(d.err)"
            } else {
                notice = "transcript de-identify failed; continuing with the original"
            }
        }
        phase = .transcript
    }

    func draft() {
        Task {
            phase = .working("Drafting a \(format) note…")
            let n = await Runner.pipe(["note", "--format", format], input: transcript)
            guard n.status == 0, !n.out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                phase = .error("Note drafting failed.\n\n\(n.err)"); return
            }
            note = n.out.trimmingCharacters(in: .newlines)
            notice = ""
            if deidentify && canDeidentify {
                let d = await Runner.pipe(["deidentify"], input: note)
                if d.status == 0 {
                    note = d.out.trimmingCharacters(in: .newlines); notice = "note: \(d.err)"
                } else {
                    notice = "note de-identify failed; showing as drafted"
                }
            }
            copied = false
            phase = .note
        }
    }

    func keep() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(note, forType: .string)
        // Convention (nspasteboard.org) asking clipboard managers not to record this.
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        copied = true
    }

    /// Runs `soapcap doctor` as a child of this app, so its capture probe
    /// reports what macOS lets *this app* do, not what the terminal can.
    func diagnose() {
        Task {
            phase = .working("Running soapcap doctor (a few seconds)…")
            let d = await Runner.pipe(["doctor"], input: "")
            let text = (d.out + "\n" + d.err).trimmingCharacters(in: .whitespacesAndNewlines)
            phase = .error(text.isEmpty ? "soapcap doctor printed nothing (exit \(d.status))" : text)
        }
    }

    func newSession() {
        generation += 1
        stopReason = .finish
        live?.stop()
        timer?.invalidate(); timer = nil
        pieces = []; transcript = ""; note = ""; notice = ""; copied = false; phase = .idle
    }

    static func cleanNotice(_ stderr: String) -> String {
        stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("soapcap live") && !$0.hasPrefix("•") }
            .prefix(1).joined(separator: "\n")
    }

    /// Joins the legs' transcripts, merging a speaker's last line of one leg
    /// with their first line of the next so a pause doesn't split a turn.
    static func joinPieces(_ pieces: [String]) -> String {
        var lines: [String] = []
        for piece in pieces {
            for line in piece.split(separator: "\n").map(String.init) {
                if let last = lines.last, let a = label(last), let b = label(line), a == b {
                    lines[lines.count - 1] = last + " " + String(line.dropFirst(b.count + 2))
                } else {
                    lines.append(line)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func label(_ line: String) -> String? {
        line.range(of: ": ").map { String(line[..<$0.lowerBound]) }
    }
}
