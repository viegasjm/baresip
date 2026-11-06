import SwiftUI
import UniformTypeIdentifiers

enum WorkspacePage: String, CaseIterable, Identifiable {
    case calls, debug, audio, appearance
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self { case .calls: return "phone"; case .debug: return "ant"; case .audio: return "speaker.wave.2"; case .appearance: return "paintpalette" }
    }
}

struct MainView: View {
    @EnvironmentObject var store: Store
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    private var palette: ThemePalette { theme.palette(for: scheme) }
    private var callSelection: Binding<String?> {
        Binding(get: { store.selectedCall }, set: { id in
            if let id { store.selectCall(id) }
            if id != nil { workspace = .calls }
        })
    }
    private var accountSelection: Binding<UUID?> {
        Binding(get: { store.selectedAccount }, set: { id in
            store.selectedAccount = id
            if let call = store.calls.first(where: { call in store.accounts.first { $0.id == id }?.aor == call.account }) {
                store.selectCall(call.id); workspace = .calls
            }
        })
    }
    @State private var workspace: WorkspacePage = .calls
    @State private var editor: AccountEditorRequest?
    @State private var deletingAccount: SIPAccount?
    @StateObject private var debugState = DebugWorkspaceState()
    @State private var showHeaders = false
    @State private var showActivity = false
    @State private var showDialPad = true
    @State private var showKeypad = false
    @State private var showTransfer = false
    @State private var showAdditionalCall = false
    @State private var showAudioFilePicker = false
    @State private var audioFileCallID: String?
    @FocusState private var destinationFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 250, ideal: 270, max: 330)
        } detail: {
            Group {
                switch workspace {
                case .calls: callsWorkspace
                case .debug: DebugView(state: debugState)
                case .audio: AudioSettingsView()
                case .appearance: AppearanceSettingsView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(palette.canvas)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        if let account = store.account {
                            Button { editor = AccountEditorRequest(account: account) } label: { HStack(spacing: 6) { Image(systemName: "slider.horizontal.3"); Text("Account settings") } }
                                .help("Edit \(account.displayName)").disabled(store.busy)
                        }
                    }
                }
        }
        .background(palette.canvas)
        .fileImporter(isPresented: $showAudioFilePicker, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): store.importAudioFile(url, callID: audioFileCallID)
            case .failure(let error): store.error = error.localizedDescription
            }
        }
        .sheet(item: $editor) { request in AccountEditor(account: request.account).id(request.id).environmentObject(store) }
        .sheet(isPresented: $showHeaders) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Headers for the next call").font(.title2.weight(.semibold))
                Text("Added alongside the outgoing account's default headers. These stay here until you remove them.").foregroundStyle(.secondary)
                ScrollView { HeadersEditor(headers: $store.callHeaders) }
                HStack { Spacer(); Button("Done") { showHeaders = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 560, height: 360)
        }
        .alert("Unable to complete action", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .confirmationDialog("Delete \(deletingAccount?.displayName ?? "this account")?", isPresented: Binding(get: { deletingAccount != nil }, set: { if !$0 { deletingAccount = nil } })) {
            if let account = deletingAccount { Button("Delete account", role: .destructive) { store.delete(account); deletingAccount = nil } }
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 28)).foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Baresip Mac").font(.headline)
                    Text("Softphone").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(16)
            VStack(spacing: 3) {
                ForEach(WorkspacePage.allCases) { page in
                    Button { workspace = page } label: {
                        HStack(spacing: 10) {
                            Image(systemName: page.symbol).frame(width: 18)
                            Text(page.title).font(.callout.weight(workspace == page ? .semibold : .regular))
                            Spacer()
                            if page == .calls, !store.calls.isEmpty { Text("\(store.calls.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        }.padding(.horizontal, 12).padding(.vertical, 9)
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                            .background(workspace == page ? palette.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityValue(workspace == page ? "Selected" : "Not selected")
                }
            }.padding(.horizontal, 10).padding(.bottom, 12)
            Divider()
            HStack {
                Text("ACCOUNTS").font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                Text("\(store.accounts.count)").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button { editor = AccountEditorRequest(account: SIPAccount()) } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless).help("Add SIP account").disabled(!store.calls.isEmpty || store.busy)
            }.padding(.horizontal, 16).padding(.vertical, 12)
            List(selection: accountSelection) {
                ForEach(store.accounts) { account in accountRow(account) }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            if !store.calls.isEmpty {
                Divider()
                Text("ACTIVE CALLS").font(.caption2.weight(.semibold)).tracking(0.8).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10)
                List(selection: callSelection) {
                    ForEach(store.calls) { call in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.accountName(for: call)).font(.callout.weight(.semibold)).lineLimit(1)
                            Text("\(call.incoming ? "Incoming" : "Outgoing") · \(call.statusTitle)").font(.caption2).foregroundStyle(.secondary)
                            if let related = store.relatedCall(to: call) { Label("Linked to \(store.accountName(for: related))", systemImage: "link").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                        }.padding(.vertical, 5).tag(call.id).contentShape(Rectangle())
                            .onTapGesture { store.selectCall(call.id); workspace = .calls }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden).frame(height: CGFloat(min(210, store.calls.count * 78 + 8)))
            }
            Divider()
            Button { workspace = .audio } label: {
                HStack {
                    Label("Audio setup", systemImage: "speaker.wave.2")
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption2)
                }.font(.caption).foregroundStyle(.secondary).padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.background(palette.sidebar)
    }

    private func accountRow(_ account: SIPAccount) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.displayName).font(.callout.weight(.semibold)).lineLimit(1).textSelection(.enabled)
                Spacer()
                Menu { accountActions(account) } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Actions for \(account.displayName)")
            }
            Text(account.aor.replacingOccurrences(of: "sip:", with: "")).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(account.aor).textSelection(.enabled)
            HStack(spacing: 5) {
                Circle().fill(connectionColor(store.connection(for: account))).frame(width: 6, height: 6)
                Text(store.connection(for: account).title).font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 3)
                Button(store.connection(for: account).canDial ? (account.register ? "Unregister" : "Disconnect") : (store.connection(for: account).phase == .failed ? "Retry" : "Connect")) {
                    store.registrationAction(account, disconnect: store.connection(for: account).canDial)
                }.buttonStyle(.borderless).font(.caption2)
                    .disabled(store.busy || store.calls.contains { $0.account == account.aor })
                    .help("Account registration control for \(account.displayName). End an active call using its End call button.")
                    .accessibilityLabel("\(store.connection(for: account).canDial ? (account.register ? "Unregister" : "Disconnect") : "Connect or register") \(account.displayName)")
            }
            ForEach(store.calls.filter { $0.account == account.aor }) { call in
                Label("\(call.incoming ? "Incoming" : "Outgoing") · \(call.statusTitle)", systemImage: call.incoming ? "phone.arrow.down.left" : "phone.arrow.up.right").font(.caption2).foregroundStyle(palette.accent)
            }
        }.padding(.vertical, 7).tag(account.id)
            .listRowBackground(store.selectedAccount == account.id ? palette.selection : Color.clear)
            .contextMenu { accountActions(account) }
            .onTapGesture(count: 2) { editor = AccountEditorRequest(account: account) }
    }
    @ViewBuilder private func accountActions(_ account: SIPAccount) -> some View {
        Button("Copy account name") { copyAccountText(account.displayName) }
        Button("Copy SIP address") { copyAccountText(account.aor) }
        Divider()
        Button("Edit account") { editor = AccountEditorRequest(account: account) }.disabled(store.busy)
        Button("Delete account", role: .destructive) { deletingAccount = account }.disabled(!store.calls.isEmpty || store.busy)
    }
    private func copyAccountText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var callsWorkspace: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calls").font(.largeTitle.weight(.semibold))
                    Text(store.calls.isEmpty ? "Call a number, extension, or SIP address." : "\(store.calls.count) call end\(store.calls.count == 1 ? "" : "s"). Select an account's side to control it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if store.accounts.isEmpty {
                    ContentUnavailableView {
                        Label("Add your first account", systemImage: "phone.connection.fill")
                    } description: { Text("Connect a SIP provider to start making and receiving calls.") } actions: {
                        Button("Add SIP account") { editor = AccountEditorRequest(account: SIPAccount()) }
                            .buttonStyle(.borderedProminent).tint(palette.button).foregroundStyle(palette.buttonText)
                    }.frame(minHeight: 340)
                } else {
                    if store.accountConnection.phase == .failed, let account = store.account { registrationFailure(account) }
                    if let call = store.call {
                        if store.calls.count > 1 { callOverview }
                        callCard(call)
                        DisclosureGroup("Start another call", isExpanded: $showAdditionalCall) { dialer.padding(.top, 12) }
                    } else { dialer }
                    DisclosureGroup("Recent activity", isExpanded: $showActivity) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 7) {
                                if store.activity.isEmpty { Text("Connection and call activity will appear here.").font(.caption).foregroundStyle(.secondary) }
                                ForEach(Array(store.activity.enumerated()), id: \.offset) { _, item in Text(item).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            }.padding(.top, 8)
                        }.frame(maxHeight: 120)
                    }.font(.callout).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: 720).padding(28).frame(maxWidth: .infinity, alignment: .top)
        }.background(palette.canvas)
    }

    private func registrationFailure(_ account: SIPAccount) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 5) {
                Text("Registration failed for \(account.displayName)").font(.callout.weight(.semibold))
                Text(store.registrationErrors[account.aor] ?? "Review this account's connection settings and retry.").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Retry") { store.registrationAction(account) }.disabled(store.busy)
                    Button("Inspect REGISTER") { debugState.registrationOnly = true; debugState.category = "All"; debugState.selectedEntry = nil; workspace = .debug }
                    Button("Edit account") { editor = AccountEditorRequest(account: account) }
                }.buttonStyle(.borderless).font(.caption)
            }
            Spacer(minLength: 0)
        }.padding(16).background(palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var dialer: some View {
        GroupBox {
            VStack(spacing: 18) {
                HStack {
                    Text("From").font(.caption).foregroundStyle(.secondary)
                    Picker("Outgoing account", selection: $store.selectedAccount) {
                        ForEach(store.accounts) { account in Text(account.displayName).tag(Optional(account.id)) }
                    }.labelsHidden().frame(maxWidth: 220, alignment: .leading)
                    Spacer(minLength: 12)
                    Circle().fill(connectionColor(store.accountConnection)).frame(width: 6, height: 6)
                    Text(store.accountConnection.title).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    TextField("Number or SIP address", text: $store.destination)
                        .font(.title2.monospacedDigit()).textFieldStyle(.plain).padding(12)
                        .background(palette.canvas, in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(palette.border) }
                        .focused($destinationFocused).onSubmit { store.dial() }
                    Button { store.dial() } label: { Label("Call", systemImage: "phone.fill").foregroundStyle(palette.buttonText).padding(.vertical, 7).frame(width: 74) }
                        .buttonStyle(.borderedProminent).tint(palette.button).controlSize(.large)
                        .disabled(!store.accountConnection.canDial || store.busy || store.destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if showDialPad {
                    PhoneKeypad(actionLabel: "Dial") { digit in
                        store.destination += digit
                        store.playKeypadSound(digit)
                        destinationFocused = true
                    }.padding(.vertical, 2)
                }
                HStack(spacing: 14) {
                    Button { showDialPad.toggle() } label: { Label(showDialPad ? "Hide dial pad" : "Dial pad", systemImage: "circle.grid.3x3") }
                    Button { showHeaders = true } label: { Label("Headers\(store.callHeaders.isEmpty ? "" : " (\(store.callHeaders.count))")", systemImage: "text.alignleft") }
                    Spacer()
                    Button { if !store.destination.isEmpty { store.destination.removeLast() } } label: { Image(systemName: "delete.left") }
                        .help("Delete last digit").disabled(store.destination.isEmpty)
                }.font(.caption).buttonStyle(.borderless)
                if !store.accountConnection.canDial {
                    Text("Connect this account in the sidebar before calling.").font(.caption).foregroundStyle(.secondary)
                }
                if let issue = store.keypadSoundIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
            }.padding(20)
        } label: { Label("New call", systemImage: "phone.arrow.up.right") }
        .frame(maxWidth: 520).frame(maxWidth: .infinity)
    }

    private func connectionColor(_ connection: AccountConnection) -> Color {
        switch connection.phase {
        case .registered, .direct: return .green
        case .failed: return .red
        case .starting, .registering: return .orange
        case .offline: return .gray
        }
    }

    private var callOverview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Call ends · \(store.calls.count)").font(.headline)
            ForEach(store.calls) { call in
                Button { store.selectCall(call.id) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: call.incoming ? "phone.arrow.down.left" : "phone.arrow.up.right").foregroundStyle(palette.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(store.accountName(for: call)).font(.callout.weight(.semibold))
                            Text("\(call.incoming ? "Incoming from" : "Outgoing to") \(call.peer.replacingOccurrences(of: "sip:", with: ""))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            if let related = store.relatedCall(to: call) {
                                Label("Linked to \(store.accountName(for: related))", systemImage: "link").font(.caption).foregroundStyle(palette.accent)
                            }
                        }
                        Spacer(minLength: 4)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(call.statusTitle).font(.callout.weight(.medium))
                            if store.selectedCall == call.id { Text("Controlling this side").font(.caption2).foregroundStyle(palette.accent) }
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(store.selectedCall == call.id ? palette.selection : palette.surface, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(store.accountName(for: call)), \(call.incoming ? "incoming" : "outgoing"), \(call.statusTitle)").accessibilityValue(store.selectedCall == call.id ? "Controlling this side" : "Select to control this side")
            }
        }
    }

    private func callCard(_ call: SIPCall) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 20) {
                Text("Controls for \(store.accountName(for: call))").font(.headline)
                HStack(spacing: 14) {
                    Image(systemName: call.held ? "pause.circle.fill" : "phone.circle.fill").font(.system(size: 48)).foregroundStyle(palette.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(call.peer.replacingOccurrences(of: "sip:", with: "")).font(.title2.weight(.semibold)).textSelection(.enabled)
                        Text("\(call.incoming ? "Incoming to" : "Outgoing from") \(store.accountName(for: call))").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text(call.statusTitle).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        if call.connected { Text(call.started, style: .timer).font(.title3.monospacedDigit()) }
                    }
                }
                if let related = store.relatedCall(to: call) {
                    Label("Linked call · \(store.accountName(for: related)) · \(related.statusTitle)", systemImage: "link").font(.callout).foregroundStyle(palette.accent)
                    Text("End call sends hangup from \(store.accountName(for: call)). The server normally ends the linked side too.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if call.state == "Incoming" {
                        Button { store.control("accept", callID: call.id) } label: { Label("Answer", systemImage: "phone.fill") }.tint(.green).buttonStyle(.borderedProminent)
                    }
                    if call.connected {
                        Button { store.control(call.held ? "resume" : "hold", callID: call.id) } label: { Label(call.held ? "Resume" : "Hold", systemImage: call.held ? "play.fill" : "pause.fill") }
                        Button { store.control("mute", params: call.muted ? "off" : "on", callID: call.id) } label: { Label(call.muted ? "Unmute" : "Mute", systemImage: call.muted ? "mic.slash.fill" : "mic.fill") }
                        Button { showKeypad.toggle() } label: { Label("Keypad", systemImage: "circle.grid.3x3.fill") }
                        Button { showTransfer.toggle() } label: { Label("Transfer", systemImage: "arrowshape.turn.up.right") }
                    }
                    Spacer(minLength: 0)
                    Button { store.control("hangup", callID: call.id) } label: { Label(call.state == "Incoming" ? "Decline" : "End call", systemImage: "phone.down.fill") }
                        .buttonStyle(.borderedProminent).tint(.red).help("End call on \(store.accountName(for: call))").accessibilityLabel("\(call.state == "Incoming" ? "Decline" : "End call") on \(store.accountName(for: call))")
                }.controlSize(.large).disabled(store.busy)
                if call.connected {
                    if showKeypad {
                        Divider()
                        HStack {
                            Text("Send tones to this call").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Toggle("Keypad sounds", isOn: $store.keypadSounds).toggleStyle(.checkbox).font(.caption)
                        }
                        PhoneKeypad(actionLabel: "Send DTMF") { store.sendDTMF($0, callID: call.id) }.disabled(store.busy || call.held)
                        if let issue = store.keypadSoundIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                    }
                    if showTransfer || store.attendedTransfer {
                        Divider()
                        if store.attendedTransfer {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Consult with the recipient, then complete the transfer.").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Cancel transfer") { store.finishTransfer(abort: true) }
                                    Spacer()
                                    Button("Complete transfer") { store.finishTransfer(abort: false) }.buttonStyle(.borderedProminent).tint(palette.button).foregroundStyle(palette.buttonText)
                                }
                            }.disabled(store.busy)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Transfer from \(store.accountName(for: call))").font(.callout.weight(.medium))
                                TextField("+country code and number, extension, or SIP address", text: $store.transferTarget).textFieldStyle(.roundedBorder)
                                if let account = store.accounts.first(where: { $0.aor == call.account }), let uri = try? Store.dialURI(store.transferTarget, account: account) {
                                    Text("Destination: \(uri)").font(.caption.monospaced()).textSelection(.enabled)
                                }
                                Text("For international numbers, include + and the country code. The server must allow the transfer destination.").font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    Button("Blind transfer") { store.transfer(attended: false, callID: call.id) }.disabled(store.transferTarget.isEmpty)
                                    Button("Consult first") { store.transfer(attended: true, callID: call.id) }.disabled(store.transferTarget.isEmpty)
                                }
                            }.disabled(store.busy)
                        }
                    }
                    if let failure = call.transferFailure {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Transfer failed: \(failure)").font(.callout.weight(.semibold))
                            Text(call.transferDestination ?? "").font(.caption.monospaced()).textSelection(.enabled)
                            Text(SIPCall.transferExplanation(failure)).font(.caption)
                            Button("Inspect transfer in Debug") { debugState.callID = call.sipID; debugState.registrationOnly = false; debugState.category = "SIP"; debugState.selectedEntry = nil; workspace = .debug }
                        }.foregroundStyle(.orange)
                    }
                    Divider()
                    HStack {
                        Label(call.audioInput.isEmpty ? "Call audio" : call.audioInput, systemImage: "waveform").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Menu {
                            Button("Play audio file…") { audioFileCallID = call.id; showAudioFilePicker = true }
                            Button("Listen only") { store.stopSendingAudio(callID: call.id) }
                        } label: { Label("Audio input", systemImage: "slider.horizontal.3") }.fixedSize().disabled(store.busy || call.held)
                    }
                }
            }.padding(20)
        } label: { Label(call.state == "Incoming" ? "Incoming call" : "Current call", systemImage: call.incoming ? "phone.arrow.down.left" : "phone.arrow.up.right") }
    }
}
