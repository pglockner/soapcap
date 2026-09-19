import AppKit
import SwiftUI

@MainActor
final class SessionModel: ObservableObject {
    enum Phase: Equatable {
        case idle, recording, working(String), transcript, note, error(String)
    }

    static let formats = ["soap", "dap", "birp"]

    @Published var phase: Phase = .idle
    @Published var deidentify = true
    @Published var format = "soap"
    @Published var transcript = ""
    @Published var note = ""
    @Published var notice = ""
    @Published var elapsed = 0
    @Published var copied = false

    let canDeidentify = Runner.deidentifyAvailable
    private var live: Runner.Live?
    private var started = Date()
    private var timer: Timer?

    /// yap needs about 3s to start; stopping earlier loses the recording
    /// (soapcap doctor's own probe runs for 3s too).
    var canStop: Bool { elapsed >= 3 }

    func start() {
        do { live = try Runner.Live() } catch {
            phase = .error("could not start soapcap: \(error)"); return
        }
        started = Date(); elapsed = 0; phase = .recording; notice = ""; copied = false
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Int(Date().timeIntervalSince(self.started))
            }
        }
        Task { await finishRecording() }
    }

    func stop() {
        guard canStop else { return }
        live?.stop()
        phase = .working("Finishing transcription…")
    }

    private func finishRecording() async {
        guard let live else { return }
        let r = await live.finish()
        timer?.invalidate(); timer = nil
        self.live = nil
        guard !r.transcript.isEmpty else {
            phase = .error("No transcript captured.\n\n\(r.err)"); return
        }
        transcript = r.transcript
        notice = Self.cleanNotice(r.err)
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
        live?.stop()
        transcript = ""; note = ""; notice = ""; copied = false; phase = .idle
    }

    static func cleanNotice(_ stderr: String) -> String {
        stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("soapcap live") && !$0.hasPrefix("•") }
            .prefix(1).joined(separator: "\n")
    }
}
