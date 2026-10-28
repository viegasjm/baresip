import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: Store?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { store?.disconnect(); store?.removeTemporaryAudio() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
@main struct BaresipMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var store = Store()
    var body: some Scene {
        WindowGroup("Baresip Mac") {
            MainView().environmentObject(store).modifier(WorkspaceTheme())
                .onAppear { delegate.store = store }
                .frame(minWidth: 980, minHeight: 680)
        }
        .defaultSize(width: 1100, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Link("Baresip source & license", destination: URL(string: "https://github.com/viegasjm/baresip")!)
            }
        }
    }
}
struct MainView: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    private var palette: ThemePalette { theme.palette(for: scheme) }
    @EnvironmentObject var store: Store
    @State private var editor: AccountEditorRequest?
    @State private var showHeaders = false
    @State private var showActivity = false
    @State private var deleting = false
    @State private var showAudioFilePicker = false
    @State private var audioFileCallID: String?
    @State private var workspaceTab = "calls"
    @State private var showKeypad = false
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Label("ACCOUNTS", systemImage: "person.crop.circle.badge.checkmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { editor = AccountEditorRequest(account: SIPAccount()) } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("Add SIP account").disabled(!store.calls.isEmpty || store.busy)
                }.padding(16)
                List(selection: $store.selectedAccount) {
                    ForEach(store.accounts) { account in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(account.displayName).font(.headline)
                            Text(account.aor.replacingOccurrences(of: "sip:", with: "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            HStack(spacing: 5) {
                                Circle().fill(registrationColor(account)).frame(width: 6, height: 6)
                                Text(store.connection(for: account).title).font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Button(store.connection(for: account).canDial ? "Disconnect" : (store.connection(for: account).phase == .failed ? "Retry" : "Connect")) {
                                    store.registrationAction(account, disconnect: store.connection(for: account).canDial)
                                }.buttonStyle(.borderless).font(.caption)
                                    .disabled(store.busy || store.calls.contains { $0.account == account.aor })
                                    .accessibilityLabel("\(store.connection(for: account).canDial ? "Disconnect" : "Connect or register") \(account.displayName)")
                            }
                        }.padding(.vertical, 7).tag(account.id)
                        .listRowBackground(store.selectedAccount == account.id ? palette.selection : Color.clear)
                        .contextMenu { Button("Edit account") { editor = AccountEditorRequest(account: account) } }
                        .onTapGesture(count: 2) { store.selectedAccount = account.id; editor = AccountEditorRequest(account: account) }
                    }
                }.listStyle(.sidebar).scrollContentBackground(.hidden)
                if !store.calls.isEmpty {
                    Divider()
                    Text("ACTIVE CALLS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    List(selection: $store.selectedCall) {
                        ForEach(store.calls) { call in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(call.peer.replacingOccurrences(of: "sip:", with: ""), systemImage: call.incoming ? "phone.arrow.down.left" : "phone.arrow.up.right").lineLimit(1)
                                Text("\(call.statusTitle) · \(store.accounts.first { $0.aor == call.account }?.displayName ?? call.account)").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5).tag(call.id)
                        }
                    }.listStyle(.sidebar).scrollContentBackground(.hidden).frame(maxHeight: 240)
                }
                Divider()
                HStack {
                    Image(systemName: "waveform.circle.fill").font(.title2).foregroundStyle(palette.accent)
                    VStack(alignment: .leading) { Text("Baresip Mac").font(.headline); Text("Powered by Baresip 4.12").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                }.padding(16)
            }.background(palette.sidebar).navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
        } detail: {
            TabView(selection: $workspaceTab) {
            ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.account?.displayName ?? "Your SIP workspace").font(.largeTitle.weight(.semibold))
                        Text(store.account?.aor ?? "Connect your accounts and take control of your calls.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(connectionColor(store.accountConnection)).frame(width: 7, height: 7)
                    Text(store.accountConnection.title).font(.callout).foregroundStyle(store.accountConnection.phase == .failed ? Color.red : Color.secondary)

                }
                if store.accounts.isEmpty {
                    Spacer()
                    ContentUnavailableView {
                        Label("A phone that works your way", systemImage: "phone.connection.fill")
                    } description: {
                        Text("Add a SIP account to get started. Manage multiple providers, choose your codecs, and send custom headers.")
                    } actions: {
                        Button("Add SIP account") { editor = AccountEditorRequest(account: SIPAccount()) }.buttonStyle(.borderedProminent).tint(palette.button).foregroundStyle(palette.buttonText).controlSize(.large)
                    }
                    Spacer()
                } else {
                    if store.accountConnection.phase == .failed, let account = store.account {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                Label("This account is not registered", systemImage: "exclamationmark.triangle.fill").font(.headline).foregroundStyle(.red)
                                Text(store.registrationErrors[account.aor] ?? "Check the username, password, domain, and transport, then retry registration.").textSelection(.enabled)
                                HStack {
                                    Button("Edit account") { editor = AccountEditorRequest(account: account) }.buttonStyle(.borderedProminent).tint(palette.button).foregroundStyle(palette.buttonText)
                                    Button("Retry registration") { store.registrationAction(account) }.disabled(store.busy)
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                        }
                    }
                    if let call = store.call { callCard(call) }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                TextField("Phone number, extension, or sip:user@domain", text: $store.destination)
                                    .textFieldStyle(.roundedBorder).font(.title3).onSubmit { store.dial() }
                                Button { store.dial() } label: { Label("Call", systemImage: "phone.fill").foregroundStyle(palette.buttonText).frame(width: 74) }
                                    .buttonStyle(.borderedProminent).tint(palette.button).controlSize(.large)
                                    .disabled(!store.accountConnection.canDial || store.busy || store.destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            HStack {
                                Label("Outgoing via \(store.account?.displayName ?? "selected account")", systemImage: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button { showHeaders.toggle() } label: { Label("Call headers\(store.callHeaders.isEmpty ? "" : " (\(store.callHeaders.count))")", systemImage: "text.alignleft") }.buttonStyle(.borderless)
                            }
                            if showHeaders {
                                Divider()
                                Text("Added to the next outgoing call, alongside the account's default headers. These stay here until you remove them.").font(.caption).foregroundStyle(.secondary)
                                HeadersEditor(headers: $store.callHeaders)
                            }
                        }.padding(12)
                    } label: { Label("Make a call", systemImage: "phone.arrow.up.right") }
                    if let account = store.account {
                        GroupBox {
                            HStack(alignment: .top, spacing: 25) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("CODEC PRIORITY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                    Text(account.codecs.filter(\.enabled).enumerated().map { "\($0.offset + 1). \($0.element.name.components(separatedBy: "/")[0])" }.joined(separator: "   →   ")).font(.callout.monospaced())
                                    Text("\(account.transport) transport · \(account.headers.count) default SIP headers").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Edit account") { editor = AccountEditorRequest(account: account) }
                                Button(role: .destructive) { deleting = true } label: { Image(systemName: "trash") }.disabled(!store.calls.isEmpty || store.busy).help("Delete account")
                            }.padding(12)
                        } label: { Label("Account settings", systemImage: "slider.horizontal.3") }
                    }
                    Spacer(minLength: 0)
                    HStack { Spacer(); Button("Open Debug") { workspaceTab = "debug" }.buttonStyle(.borderless) }
                    DisclosureGroup("Activity", isExpanded: $showActivity) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 7) {
                                if store.activity.isEmpty { Text("Call and registration activity will appear here.").foregroundStyle(.secondary) }
                                ForEach(Array(store.activity.enumerated()), id: \.offset) { _, item in Text(item).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            }.padding(.top, 8)
                        }.frame(height: 100)
                    }.foregroundStyle(.secondary)
                }
            }.padding(28).frame(maxWidth: .infinity, minHeight: 620, alignment: .top).background(palette.canvas)
            }.tabItem { Label("Calls", systemImage: "phone") }.tag("calls")
            AudioSettingsView().tabItem { Label("Audio", systemImage: "speaker.wave.2") }.tag("audio")
            AppearanceSettingsView().tabItem { Label("Appearance", systemImage: "paintpalette") }.tag("appearance")
            DebugView().tabItem { Label("Debug", systemImage: "ant") }.tag("debug")
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
        .alert("Unable to complete action", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .confirmationDialog("Delete this SIP account?", isPresented: $deleting) {
            Button("Delete account", role: .destructive) { if let account = store.account { store.delete(account) } }
        }
    }
    private func registrationColor(_ account: SIPAccount) -> Color { connectionColor(store.connection(for: account)) }
    private func connectionColor(_ connection: AccountConnection) -> Color {
        switch connection.phase {
        case .registered, .direct: return .green
        case .failed: return .red
        case .starting, .registering: return .orange
        case .offline: return .gray
        }
    }
    private func callCard(_ call: SIPCall) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: call.held ? "pause.circle.fill" : "phone.circle.fill").font(.system(size: 42)).foregroundStyle(palette.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(call.peer.replacingOccurrences(of: "sip:", with: "")).font(.title2.weight(.medium)).textSelection(.enabled)
                        Text("\(call.statusTitle) · \(call.account.replacingOccurrences(of: "sip:", with: ""))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if call.connected { Text(call.started, style: .timer).font(.title3.monospacedDigit()) }
                }
                HStack(spacing: 12) {
                    if call.state == "Incoming" {
                        Button { store.control("accept") } label: { Label("Answer", systemImage: "phone.fill") }.tint(.green).buttonStyle(.borderedProminent)
                    }
                    if call.connected {
                        Button { showKeypad.toggle() } label: { Label("Keypad", systemImage: "circle.grid.3x3.fill") }
                        Button { store.control(call.held ? "resume" : "hold") } label: { Label(call.held ? "Resume" : "Hold", systemImage: call.held ? "play.fill" : "pause.fill") }
                        Button { store.control("mute", params: call.muted ? "off" : "on") } label: { Label(call.muted ? "Unmute" : "Mute", systemImage: call.muted ? "mic.slash.fill" : "mic.fill") }
                    }
                    Spacer()
                    Button { store.control("hangup") } label: { Label(call.state == "Incoming" ? "Decline" : "End call", systemImage: "phone.down.fill") }.buttonStyle(.borderedProminent).tint(.red)
                }.disabled(store.busy)
                if call.connected {
                    if showKeypad {
                        VStack(spacing: 8) {
                            HStack {
                                Text("Send DTMF to this call").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Toggle("Keypad sounds", isOn: $store.keypadSounds).toggleStyle(.checkbox).font(.caption)
                            }
                            if let issue = store.keypadSoundIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                            ForEach(["123", "456", "789", "*0#"], id: \.self) { row in
                                HStack(spacing: 10) {
                                    ForEach(Array(row).map(String.init), id: \.self) { digit in
                                        Button { store.sendDTMF(digit) } label: { Text(digit).font(.title2.monospacedDigit()).frame(width: 54, height: 30) }
                                            .accessibilityLabel("Send DTMF \(digit)")
                                    }
                                }
                            }
                        }.frame(maxWidth: .infinity).disabled(store.busy || call.held)
                    }
                    HStack {
                        Label(call.audioInput.isEmpty ? "Call audio" : call.audioInput, systemImage: "waveform").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Play audio file…") { audioFileCallID = call.id; showAudioFilePicker = true }
                        Button("Listen only") { store.stopSendingAudio() }
                    }.disabled(store.busy || call.held)
                    Divider()
                    if store.attendedTransfer {
                        HStack {
                            Text("Consult with the recipient, then complete the transfer.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel transfer") { store.finishTransfer(abort: true) }
                            Button("Complete transfer") { store.finishTransfer(abort: false) }.buttonStyle(.borderedProminent).tint(palette.button).foregroundStyle(palette.buttonText)
                        }.disabled(store.busy)
                    } else {
                        HStack {
                            TextField("Transfer to extension or SIP address", text: $store.transferTarget).textFieldStyle(.roundedBorder)
                            Button("Blind transfer") { store.transfer(attended: false) }.disabled(store.transferTarget.isEmpty)
                            Button("Consult first") { store.transfer(attended: true) }.disabled(store.transferTarget.isEmpty)
                        }.disabled(store.busy)
                    }
                }
            }.padding(14)
        } label: { Text("Current call") }
    }
}

struct HeadersEditor: View {
    @Binding var headers: [SIPHeader]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach($headers) { $header in
                HStack {
                    TextField("Header name", text: $header.name).frame(width: 180)
                    TextField("Value", text: $header.value)
                    Button { headers.removeAll { $0.id == header.id } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove header")
                }.textFieldStyle(.roundedBorder)
            }
            Button { headers.append(SIPHeader()) } label: { Label("Add header", systemImage: "plus") }.buttonStyle(.borderless)
        }
    }
}
struct AccountEditor: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    private var palette: ThemePalette { theme.palette(for: scheme) }
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var account: SIPAccount
    @State private var password = ""
    @State private var validationError: String?
    @State private var passwordLoading = true
    @State private var passwordReadFailed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "person.crop.circle.badge.plus").font(.title).foregroundStyle(palette.accent)
                VStack(alignment: .leading, spacing: 3) { Text(store.accounts.contains(where: { $0.id == account.id }) ? "Edit account" : "Add SIP account").font(.title2.weight(.semibold)); Text("Your provider, your preferences.").foregroundStyle(.secondary) }
            }
            TabView {
                Form {
                    TextField("Account name", text: $account.label)
                    TextField("Username", text: $account.username)
                    TextField("Domain / host:port", text: $account.domain)
                    SecureField("Password", text: $password).disabled(passwordLoading)
                    TextField("Authentication username (optional)", text: $account.authUser)
                    TextField("Outbound proxy host:port (optional)", text: $account.proxy)
                    TextField("Assigned numbers (optional, separated by commas)", text: Binding(get: { account.phoneNumbers ?? "" }, set: { account.phoneNumbers = $0 }))
                    Text("Enter full numbers such as +12025550123 to recognize calls between your accounts.").font(.caption).foregroundStyle(.secondary)
                    Picker("Transport", selection: $account.transport) { Text("TLS").tag("TLS"); Text("TCP").tag("TCP"); Text("UDP").tag("UDP") }
                    Toggle("Register with the SIP server", isOn: $account.register)
                    Text("Passwords are saved locally, readable only by your macOS user, without Keychain encryption or prompts. Turn registration off for direct SIP calls.").font(.caption).foregroundStyle(.secondary)
                }.formStyle(.grouped).tabItem { Label("Connection", systemImage: "network") }
                VStack(alignment: .leading, spacing: 16) {
                    Text("Codecs are offered in this order. Enable the codecs you need and use the arrows to change their priority.").font(.callout).foregroundStyle(.secondary)
                    ForEach(Array(account.codecs.enumerated()), id: \.element.id) { index, codec in
                        HStack {
                            Text("\(index + 1)").foregroundStyle(.secondary).frame(width: 20)
                            Toggle(codec.name, isOn: $account.codecs[index].enabled).toggleStyle(.checkbox)
                            Spacer()
                            Button { account.codecs.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Higher priority")
                            Button { account.codecs.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }.disabled(index == account.codecs.count - 1).help("Lower priority")
                        }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text("The remote server also participates in codec negotiation.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(20).tabItem { Label("Codecs", systemImage: "waveform") }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Default headers added to outgoing INVITEs from this account. You can also add headers in the call panel.").foregroundStyle(.secondary)
                        HeadersEditor(headers: $account.headers)
                    }.padding(20)
                }.tabItem { Label("SIP headers", systemImage: "text.alignleft") }
            }
            if passwordLoading { ProgressView("Loading saved password…").controlSize(.small) }
            if !store.calls.isEmpty { Text("Finish your calls before saving changes.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save account") {
                    do { try store.save(account, password: password); dismiss() } catch { validationError = error.localizedDescription }
                }.buttonStyle(.borderedProminent).tint(palette.button).foregroundStyle(palette.buttonText).keyboardShortcut(.defaultAction)
                .disabled(passwordLoading || store.busy || !store.calls.isEmpty || (passwordReadFailed && password.isEmpty))
            }
        }.padding(24).frame(width: 640, height: 560).tint(palette.accent)
        .task {
            let id = account.id
            do { password = try await Task.detached { try Passwords.load(id) }.value }
            catch { passwordReadFailed = true; validationError = error.localizedDescription }
            passwordLoading = false
        }
        .alert("Check account settings", isPresented: Binding(get: { validationError != nil }, set: { if !$0 { validationError = nil } })) { Button("OK") { validationError = nil } } message: { Text(validationError ?? "") }
    }
}
