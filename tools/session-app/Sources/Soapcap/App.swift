import SwiftUI

@main
struct SoapcapApp: App {
    @StateObject private var model = SessionModel()

    var body: some Scene {
        WindowGroup("soapcap session") {
            ContentView().environmentObject(model)
                .frame(minWidth: 560, minHeight: 420)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var m: SessionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch m.phase {
            case .idle: idle
            case .recording: recording
            case .working(let msg): ProgressView(msg).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .transcript: transcript
            case .note: note
            case .error(let msg): error(msg)
            }
        }
        .padding(16)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ready to record").font(.title2.bold())
            Text("Use headphones, and turn on Do Not Disturb.").foregroundStyle(.secondary)
            if m.canDeidentify {
                Toggle("De-identify the transcript, and the note once it's drafted", isOn: $m.deidentify)
            }
            HStack {
                Button("Start recording") { m.start() }.keyboardShortcut(.defaultAction)
                Button("Check permissions") { m.diagnose() }
            }
            Spacer()
        }
    }

    private var recording: some View {
        VStack(spacing: 16) {
            Spacer()
            HStack { Circle().fill(.red).frame(width: 12, height: 12)
                Text(String(format: "recording  %02d:%02d", m.elapsed / 60, m.elapsed % 60))
                    .font(.system(.title2, design: .monospaced)) }
            Button("Stop") { m.stop() }.disabled(!m.canStop).keyboardShortcut(.defaultAction)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    private func scrollText(_ s: String) -> some View {
        ScrollView { Text(s).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Transcript").font(.headline)
            scrollText(m.transcript)
            if !m.notice.isEmpty { Text(m.notice).font(.caption).foregroundStyle(.orange) }
            HStack {
                Picker("Format", selection: $m.format) {
                    ForEach(SessionModel.formats, id: \.self) { Text($0) }
                }.pickerStyle(.segmented).frame(width: 220)
                Button("Draft note") { m.draft() }.keyboardShortcut(.defaultAction)
                Spacer()
                Button("New session") { m.newSession() }
            }
        }
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(m.format.uppercased()) note").font(.headline)
            scrollText(m.note)
            if !m.notice.isEmpty { Text(m.notice).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button(m.copied ? "Copied" : "Keep (copy)") { m.keep() }.keyboardShortcut(.defaultAction)
                Button("Regenerate") { m.draft() }
                Spacer()
                Button("Discard") { m.newSession() }
            }
        }
    }

    private func error(_ msg: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView { Text(msg).font(.system(.body, design: .monospaced)).foregroundStyle(.orange)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            HStack {
                Button("Back") { m.newSession() }
                Button("Check permissions") { m.diagnose() }
            }
        }
    }
}
