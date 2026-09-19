import XCTest
@testable import Soapcap

/// A stand-in for the `soapcap` CLI, selected with SOAPCAP_BIN. STUB_MODE:
/// normal (default), relay (models yap under a script that relays SIGINT),
/// empty (a capture that fails), bob (live prints a name to redact).
/// STUB_DIR holds a per-leg counter so successive `live` runs differ.
private let stubScript = #"""
#!/usr/bin/env bash
mode="${STUB_MODE:-normal}"
case "$1" in
  live)
    echo "soapcap live — banner" >&2
    echo "  • one" >&2
    echo "NOTE: one-sided" >&2
    if [ "$mode" = relay ]; then
      perl -e '$|=1; $SIG{INT}=sub{print "INT\n"; exit 0}; $SIG{TERM}=sub{print "TERM\n"; exit 143}; select(undef,undef,undef,0.05) while 1' &
      p=$!
      trap 'kill -INT $p 2>/dev/null' TERM
      while kill -0 $p 2>/dev/null; do wait $p 2>/dev/null; done
      exit 0
    fi
    n=$(cat "$STUB_DIR/count" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$STUB_DIR/count"
    case "$mode" in
      empty) trap 'echo "soapcap: no audio captured." >&2; exit 1' TERM ;;
      bob)   trap 'echo "Therapist: hi Bob"; exit 0' TERM ;;
      *)     if [ "$n" = 1 ]; then trap 'echo "Therapist: hello"; exit 0' TERM
             else trap 'printf "Therapist: again\nClient: fine\n"; exit 0' TERM; fi ;;
    esac
    while :; do sleep 0.05; done ;;
  deidentify)
    sed 's/Bob/[FIRST_NAME_1]/g'
    echo "redacted 1 span(s): FIRST_NAME x1" >&2 ;;
  note)
    cat > /dev/null
    printf 'SUBJECTIVE:\nformat %s\nNote about Bob\n' "$3" ;;
  doctor)
    echo "ok    all good" ;;
esac
"""#

@MainActor
final class SessionModelTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("soapcap-app-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stub = dir.appendingPathComponent("soapcap")
        try stubScript.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        setenv("SOAPCAP_BIN", stub.path, 1)
        setenv("SOAPCAP_DEIDENTIFY_BIN", stub.path, 1) // any executable: enables the toggle
        setenv("STUB_DIR", dir.path, 1)
        setenv("STUB_MODE", "normal", 1)
    }

    override func tearDown() async throws {
        for k in ["SOAPCAP_BIN", "SOAPCAP_DEIDENTIFY_BIN", "STUB_DIR", "STUB_MODE"] { unsetenv(k) }
        try? FileManager.default.removeItem(at: dir)
    }

    /// Polls (suspending, so the main run loop and timers keep running).
    private func waitFor(_ what: String, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line,
                         _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)", file: file, line: line); return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: pure logic

    func testJoinPiecesMergesASpeakersTurnAcrossAPause() {
        XCTAssertEqual(
            SessionModel.joinPieces(["Therapist: hello\nClient: hi\nTherapist: so", "Therapist: how are you\nClient: fine"]),
            "Therapist: hello\nClient: hi\nTherapist: so how are you\nClient: fine")
    }

    func testJoinPiecesKeepsDifferentSpeakersSeparate() {
        XCTAssertEqual(SessionModel.joinPieces(["Therapist: a", "Client: b"]), "Therapist: a\nClient: b")
    }

    func testJoinPiecesSinglePieceIsUnchanged() {
        XCTAssertEqual(SessionModel.joinPieces(["Therapist: only"]), "Therapist: only")
        XCTAssertEqual(SessionModel.joinPieces([]), "")
    }

    func testLabelSplitsAtTheFirstColonSpace() {
        XCTAssertEqual(SessionModel.label("Therapist: note: this"), "Therapist")
        XCTAssertNil(SessionModel.label("no label here"))
    }

    func testCleanNoticeDropsTheBannerAndKeepsTheFirstWarning() {
        let stderr = "soapcap live — on-device capture\n  • Use headphones\n\nNOTE: captured your side\nmore detail"
        XCTAssertEqual(SessionModel.cleanNotice(stderr), "NOTE: captured your side")
    }

    // MARK: Runner

    func testDeidentifyAvailabilityFollowsTheHelperBinary() {
        XCTAssertTrue(Runner.deidentifyAvailable)
        setenv("SOAPCAP_DEIDENTIFY_BIN", dir.appendingPathComponent("missing").path, 1)
        XCTAssertFalse(Runner.deidentifyAvailable)
    }

    func testPipeRunsTheCLIWithInputOnStdin() async {
        let r = await Runner.pipe(["deidentify"], input: "hi Bob")
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.out.trimmingCharacters(in: .newlines), "hi [FIRST_NAME_1]")
        XCTAssertTrue(r.err.hasPrefix("redacted 1"))
    }

    /// The bug that lost recordings: stopping must signal only the script,
    /// which relays SIGINT. If yap also got SIGTERM directly it would print TERM.
    func testStopSignalsOnlyTheScriptSoTheChildGetsSIGINT() async throws {
        setenv("STUB_MODE", "relay", 1)
        let live = try Runner.Live()
        try await Task.sleep(nanoseconds: 700_000_000) // let the script install its trap
        live.stop()
        let r = await live.finish()
        XCTAssertEqual(r.transcript, "INT")
        XCTAssertEqual(r.status, 0)
    }

    // MARK: session flow (each leg needs 3s before it can be stopped)

    func testStopIsIgnoredDuringTheFirstThreeSeconds() async {
        let m = SessionModel()
        m.start()
        m.stop()
        m.pause()
        XCTAssertEqual(m.phase, .recording)
        m.newSession()
        XCTAssertEqual(m.phase, .idle)
    }

    func testPauseResumeStopJoinsTheLegs() async {
        let m = SessionModel()
        m.deidentify = false
        m.start()
        await waitFor("first leg to be stoppable") { m.canStop }
        m.pause()
        await waitFor("paused") { m.phase == .paused }
        m.resume()
        await waitFor("second leg to be stoppable") { m.phase == .recording && m.canStop }
        m.stop()
        await waitFor("transcript") { m.phase == .transcript }
        XCTAssertEqual(m.transcript, "Therapist: hello again\nClient: fine")
        XCTAssertEqual(m.notice, "NOTE: one-sided")
        XCTAssertGreaterThanOrEqual(m.elapsed, 6)
    }

    func testStoppingWhilePausedFinishesWithoutAnotherLeg() async {
        let m = SessionModel()
        m.deidentify = false
        m.start()
        await waitFor("stoppable") { m.canStop }
        m.pause()
        await waitFor("paused") { m.phase == .paused }
        m.stop()
        await waitFor("transcript") { m.phase == .transcript }
        XCTAssertEqual(m.transcript, "Therapist: hello")
    }

    func testDeidentifyRunsOnTheTranscriptAndThenTheNote() async {
        setenv("STUB_MODE", "bob", 1)
        let m = SessionModel()
        m.deidentify = true
        m.start()
        await waitFor("stoppable") { m.canStop }
        m.stop()
        await waitFor("transcript") { m.phase == .transcript }
        XCTAssertEqual(m.transcript, "Therapist: hi [FIRST_NAME_1]")
        XCTAssertTrue(m.notice.hasPrefix("transcript: "))

        m.format = "dap"
        m.draft()
        await waitFor("note") { m.phase == .note }
        XCTAssertEqual(m.note, "SUBJECTIVE:\nformat dap\nNote about [FIRST_NAME_1]")
        XCTAssertTrue(m.notice.hasPrefix("note: "))
    }

    func testWithoutDeidentifyNothingIsRedacted() async {
        setenv("STUB_MODE", "bob", 1)
        let m = SessionModel()
        m.deidentify = false
        m.start()
        await waitFor("stoppable") { m.canStop }
        m.stop()
        await waitFor("transcript") { m.phase == .transcript }
        XCTAssertEqual(m.transcript, "Therapist: hi Bob")
    }

    func testAFailedCaptureShowsTheErrorAndTheCLIsMessage() async {
        setenv("STUB_MODE", "empty", 1)
        let m = SessionModel()
        m.start()
        await waitFor("stoppable") { m.canStop }
        m.stop()
        await waitFor("error screen") { if case .error = m.phase { return true } else { return false } }
        guard case .error(let msg) = m.phase else { return }
        XCTAssertTrue(msg.contains("No transcript captured"))
        XCTAssertTrue(msg.contains("no audio captured"))
    }

    func testNewSessionDuringARecordingIgnoresTheLateResult() async {
        let m = SessionModel()
        m.start()
        await waitFor("stoppable") { m.canStop }
        m.newSession()
        try? await Task.sleep(nanoseconds: 1_000_000_000) // the old leg finishes in the background
        XCTAssertEqual(m.phase, .idle)
        XCTAssertEqual(m.transcript, "")
    }
}
