import Foundation

/// Drives the soapcap CLI as child processes. Nothing here touches disk.
enum Runner {
    /// SOAPCAP_BIN overrides; otherwise <repo>/bin/soapcap, found relative to
    /// the bundle at <repo>/tools/session-app/build/Soapcap.app.
    static var bin: URL {
        if let p = ProcessInfo.processInfo.environment["SOAPCAP_BIN"] { return URL(fileURLWithPath: p) }
        var u = Bundle.main.bundleURL
        for _ in 0..<4 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("bin/soapcap")
    }

    static var deidentifyAvailable: Bool {
        let env = ProcessInfo.processInfo.environment
        let path = env["SOAPCAP_DEIDENTIFY_BIN"]
            ?? bin.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("tools/deidentify-helper/.build/release/soapcap-deidentify-helper").path
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// GUI apps get a minimal PATH; soapcap needs Homebrew's yap, jq, ollama, etc.
    static func makeProcess(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        p.environment = env
        return p
    }

    private static func drain(_ p: Process, out: Pipe, err: Pipe) -> (String, String) {
        var o = Data(), e = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { o = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { e = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        p.waitUntilExit()
        g.wait()
        return (String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }

    /// Runs `soapcap <args>` with `input` on stdin.
    static func pipe(_ args: [String], input: String) async -> (out: String, err: String, status: Int32) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = makeProcess(args)
                let i = Pipe(), o = Pipe(), e = Pipe()
                p.standardInput = i; p.standardOutput = o; p.standardError = e
                do { try p.run() } catch {
                    cont.resume(returning: ("", "could not run \(bin.path): \(error)", 127)); return
                }
                i.fileHandleForWriting.write(Data(input.utf8))
                try? i.fileHandleForWriting.close()
                let (out, err) = drain(p, out: o, err: e)
                cont.resume(returning: (out, err.trimmingCharacters(in: .whitespacesAndNewlines), p.terminationStatus))
            }
        }
    }

    /// A running `soapcap live`. With stdin not a tty it uses its signal-only
    /// stop path: SIGTERM ends capture cleanly and prints the transcript.
    final class Live {
        let process: Process
        private let out = Pipe(), err = Pipe()

        init() throws {
            process = Runner.makeProcess(["live"])
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = out
            process.standardError = err
            try process.run()
        }

        /// Signals only the script's own pid. Process.terminate() also reaches
        /// the child yap (same process group), which then dies on SIGTERM
        /// without writing its output; the script must relay SIGINT instead.
        func stop() { if process.isRunning { kill(process.processIdentifier, SIGTERM) } }

        func finish() async -> (transcript: String, err: String, status: Int32) {
            await withCheckedContinuation { cont in
                DispatchQueue.global().async {
                    let (o, e) = Runner.drain(self.process, out: self.out, err: self.err)
                    cont.resume(returning: (o.trimmingCharacters(in: .newlines),
                                            e.trimmingCharacters(in: .whitespacesAndNewlines),
                                            self.process.terminationStatus))
                }
            }
        }
    }
}
