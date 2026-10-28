import SwiftUI
import UniformTypeIdentifiers

struct DebugTextFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
struct DebugView: View {
    @EnvironmentObject var store: Store
    @State private var callID = ""
    @State private var category = "All"
    @State private var registrationOnly = false
    @State private var selectedEntry: UUID?
    @State private var detailMode = "Message"
    @State private var exporting = false
    private var focusedCall: CallDebug? {
        callID.isEmpty ? store.diagnostics.calls.last : store.diagnostics.calls.first { $0.id == callID }
    }
    private var entries: [DebugEntry] {
        (registrationOnly ? store.diagnostics.registrationEntries(account: store.account?.aor) : store.diagnostics.entries).reversed().filter {
            (category == "All" || $0.category == category) &&
            (registrationOnly || callID.isEmpty || $0.callID == callID || $0.category == "Engine" || $0.category == "Snapshot")
        }
    }
    private var focusedEntry: DebugEntry? { entries.first { $0.id == selectedEntry } ?? entries.first }
    private var detailText: String {
        if registrationOnly {
            guard let entry = focusedEntry else { return "No REGISTER captured for this account. Enable Capture, then use Connect or Retry beside the account." }
            return "\(entry.timestamp.ISO8601Format())\n\(entry.summary)\nCall-ID: \(entry.callID ?? "—")\n\n\(entry.detail)"
        }
        if detailMode == "First INVITE" { return focusedCall?.firstInvite.isEmpty == false ? focusedCall!.firstInvite : "No INVITE captured yet. Enable capture before making or receiving a call." }
        guard let entry = focusedEntry else { return "Connect an account or reproduce the call issue to capture diagnostics." }
        return "\(entry.timestamp.ISO8601Format())\n\(entry.summary)\nCall-ID: \(entry.callID ?? "—")\n\n\(entry.detail)"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Debug").font(.largeTitle.weight(.semibold))
                    Text("SIP signaling, call history, and local audio diagnostics.").foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Capture", isOn: $store.captureDiagnostics).toggleStyle(.switch).fixedSize()
                Button("Snapshot") { store.captureSnapshot() }.disabled(store.busy).help("Capture engine version, loaded accounts, registration status, calls, and local audio diagnostics in Debug.")
                Button { exporting = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                Button("Clear") { store.diagnostics = DebugJournal(); selectedEntry = nil; callID = "" }
            }
            HStack {
                Picker("Call", selection: $callID) {
                    Text("All signaling").tag("")
                    ForEach(store.diagnostics.calls.reversed()) { call in Text("\(call.peer.isEmpty ? "Call" : call.peer) · \(call.id)").tag(call.id) }
                }.frame(maxWidth: 500).disabled(registrationOnly)
                Spacer()
                Toggle("Mono device audio", isOn: $store.monoDeviceAudio).help("Use one microphone/speaker channel independently of the negotiated codec. Applies on the next connection.").disabled(store.busy || !store.calls.isEmpty)
            }
            Toggle("REGISTER · selected account", isOn: $registrationOnly).toggleStyle(.checkbox)
            if registrationOnly, let account = store.account {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(account.displayName) · \(store.connection(for: account).title)").font(.headline)
                    if let reason = store.registrationErrors[account.aor] { Text(reason).foregroundStyle(.orange).textSelection(.enabled) }
                    Text("Use Connect or Retry beside the account to capture a new attempt. A 401 challenge is normal when followed by an authenticated REGISTER and 200 OK.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !registrationOnly, let call = focusedCall {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("SIP Call-ID").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(call.id).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            Button("Copy ID") { copy(call.id) }
                        }
                        if !call.account.isEmpty { Text("Account: \(call.account)").font(.caption).textSelection(.enabled) }
                        if !call.peer.isEmpty { Text("Peer: \(call.peer)").font(.caption).textSelection(.enabled) }
                        if !call.failure.isEmpty {
                            Text("Ended: \(call.failure)").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                            if let explanation = DebugJournal.deviceExplanation(call.failure) { Text(explanation).font(.caption).foregroundStyle(.secondary) }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
            }
            HStack {
                Picker("Show", selection: $category) {
                    ForEach(["All", "SIP", "Engine", "Events", "Snapshot"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 420)
                Spacer()
                Text("\(entries.count) entries · latest 500 retained").font(.caption).foregroundStyle(.secondary)
            }
            HSplitView {
                List(selection: $selectedEntry) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(entry.category).font(.caption.weight(.semibold)).foregroundStyle(entry.category == "SIP" ? Color.teal : .secondary)
                                Spacer()
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(entry.summary).font(.caption.monospaced()).lineLimit(3)
                        }.padding(.vertical, 4).tag(entry.id)
                    }
                }.frame(minWidth: 240, idealWidth: 300, maxWidth: 380)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("Detail", selection: $detailMode) { Text("Message").tag("Message"); Text("First INVITE").tag("First INVITE") }.pickerStyle(.segmented).frame(maxWidth: 240).disabled(registrationOnly)
                        Spacer()
                        Button("Copy") { copy(detailText) }
                    }
                    ScrollView([.horizontal, .vertical]) {
                        Text(detailText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(12).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }.padding(.leading, 12).frame(minWidth: 350)
            }.frame(minHeight: 240, maxHeight: .infinity)
            Text("Authentication headers are hidden. Addresses and custom headers remain visible. Capture stays in memory until export or quit. Mono device audio applies after reconnecting.").font(.caption).foregroundStyle(.secondary)
        }.padding(24)
        .fileExporter(isPresented: $exporting, document: DebugTextFile(text: store.diagnostics.export(callID: callID.isEmpty ? nil : callID, registrationAccount: registrationOnly ? store.account?.aor : nil)), contentType: .plainText, defaultFilename: "Baresip-Diagnostics-\(Date().formatted(.iso8601.year().month().day()))") { result in
            if case .failure(let error) = result { store.error = error.localizedDescription }
        }
    }
    private func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(DebugJournal.redact(text), forType: .string) }
}
