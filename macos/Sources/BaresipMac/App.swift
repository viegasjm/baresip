import SwiftUI
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: Store?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { store?.disconnect() }
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
            MainView().environmentObject(store)
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
    @EnvironmentObject var store: Store
    @State private var editing: SIPAccount?
    @State private var showEditor = false
    @State private var showHeaders = false
    @State private var showActivity = false
    @State private var deleting = false
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack {
                    Label("ACCOUNTS", systemImage: "person.crop.circle.badge.checkmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { editing = nil; showEditor = true } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("Add SIP account").disabled(!store.calls.isEmpty || store.busy)
                }.padding(16)
                List(selection: $store.selectedAccount) {
                    ForEach(store.accounts) { account in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(account.displayName).font(.headline)
                            Text(account.aor.replacingOccurrences(of: "sip:", with: "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            HStack(spacing: 5) {
                                Circle().fill(registrationColor(account)).frame(width: 6, height: 6)
                                Text(store.registrations[account.aor] ?? "Offline").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 7).tag(account.id)
                    }
                }.listStyle(.sidebar)
                if !store.calls.isEmpty {
                    Divider()
                    Text("ACTIVE CALLS").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                    List(selection: $store.selectedCall) {
                        ForEach(store.calls) { call in
                            VStack(alignment: .leading, spacing: 4) {
                                Label(call.peer.replacingOccurrences(of: "sip:", with: ""), systemImage: call.incoming ? "phone.arrow.down.left" : "phone.arrow.up.right").lineLimit(1)
                                Text(call.held ? "On hold" : call.state).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 5).tag(call.id)
                        }
                    }.listStyle(.sidebar).frame(maxHeight: 240)
                }
                Divider()
                HStack {
                    Image(systemName: "waveform.circle.fill").font(.title2).foregroundStyle(.teal)
                    VStack(alignment: .leading) { Text("Baresip Mac").font(.headline); Text("Powered by Baresip 4.12").font(.caption2).foregroundStyle(.secondary) }
                    Spacer()
                }.padding(16)
            }.navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
        } detail: {
            ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.account?.displayName ?? "Your SIP workspace").font(.largeTitle.weight(.semibold))
                        Text(store.account?.aor ?? "Connect your accounts and take control of your calls.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Circle().fill(store.connected ? .green : .secondary).frame(width: 7, height: 7)
                    Text(store.status).font(.callout).foregroundStyle(.secondary)
                    Button(store.connected ? "Disconnect" : "Connect") {
                        if store.connected { store.disconnect() } else { store.connect() }
                    }.disabled(store.accounts.isEmpty || store.busy || !store.calls.isEmpty)
                }
                if store.accounts.isEmpty {
                    Spacer()
                    ContentUnavailableView {
                        Label("A phone that works your way", systemImage: "phone.connection.fill")
                    } description: {
                        Text("Add a SIP account to get started. Manage multiple providers, choose your codecs, and send custom headers.")
                    } actions: {
                        Button("Add SIP account") { editing = nil; showEditor = true }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    Spacer()
                } else {
                    if let call = store.call { callCard(call) }
                    GroupBox {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                TextField("Phone number, extension, or sip:user@domain", text: $store.destination)
                                    .textFieldStyle(.roundedBorder).font(.title3).onSubmit { store.dial() }
                                Button { store.dial() } label: { Label("Call", systemImage: "phone.fill").frame(width: 74) }
                                    .buttonStyle(.borderedProminent).tint(.teal).controlSize(.large)
                                    .disabled(!store.connected || store.busy || store.destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
                                Button("Edit account") { editing = account; showEditor = true }.disabled(!store.calls.isEmpty || store.busy)
                                Button(role: .destructive) { deleting = true } label: { Image(systemName: "trash") }.disabled(!store.calls.isEmpty || store.busy).help("Delete account")
                            }.padding(12)
                        } label: { Label("Account settings", systemImage: "slider.horizontal.3") }
                    }
                    Spacer(minLength: 0)
                    DisclosureGroup("Activity", isExpanded: $showActivity) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 7) {
                                if store.activity.isEmpty { Text("Call and registration activity will appear here.").foregroundStyle(.secondary) }
                                ForEach(Array(store.activity.enumerated()), id: \.offset) { _, item in Text(item).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            }.padding(.top, 8)
                        }.frame(height: 100)
                    }.foregroundStyle(.secondary)
                }
            }.padding(28).frame(maxWidth: .infinity, minHeight: 620, alignment: .top).background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .tint(.teal)
        .sheet(isPresented: $showEditor) { AccountEditor(account: editing ?? SIPAccount()).environmentObject(store) }
        .alert("Unable to complete action", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .confirmationDialog("Delete this SIP account?", isPresented: $deleting) {
            Button("Delete account", role: .destructive) { if let account = store.account { store.delete(account) } }
        }
    }
    private func registrationColor(_ account: SIPAccount) -> Color {
        switch store.registrations[account.aor] { case "Registered", "Direct calls": return .green; case "Registration failed": return .red; case "Registering…": return .orange; default: return .gray }
    }
    private func callCard(_ call: SIPCall) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(systemName: call.held ? "pause.circle.fill" : "phone.circle.fill").font(.system(size: 42)).foregroundStyle(.teal)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(call.peer.replacingOccurrences(of: "sip:", with: "")).font(.title2.weight(.medium)).textSelection(.enabled)
                        Text("\(call.held ? "On hold" : call.state) · \(call.account.replacingOccurrences(of: "sip:", with: ""))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if call.connected { Text(call.started, style: .timer).font(.title3.monospacedDigit()) }
                }
                HStack(spacing: 12) {
                    if call.state == "Incoming" {
                        Button { store.control("accept") } label: { Label("Answer", systemImage: "phone.fill") }.tint(.green).buttonStyle(.borderedProminent)
                    }
                    if call.connected {
                        Button { store.control(call.held ? "resume" : "hold") } label: { Label(call.held ? "Resume" : "Hold", systemImage: call.held ? "play.fill" : "pause.fill") }
                        Button { store.control("mute", params: call.muted ? "off" : "on") } label: { Label(call.muted ? "Unmute" : "Mute", systemImage: call.muted ? "mic.slash.fill" : "mic.fill") }
                    }
                    Spacer()
                    Button { store.control("hangup") } label: { Label(call.state == "Incoming" ? "Decline" : "End call", systemImage: "phone.down.fill") }.buttonStyle(.borderedProminent).tint(.red)
                }.disabled(store.busy)
                if call.connected {
                    Divider()
                    if store.attendedTransfer {
                        HStack {
                            Text("Consult with the recipient, then complete the transfer.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel transfer") { store.finishTransfer(abort: true) }
                            Button("Complete transfer") { store.finishTransfer(abort: false) }.buttonStyle(.borderedProminent)
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
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State var account: SIPAccount
    @State private var password = ""
    @State private var validationError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "person.crop.circle.badge.plus").font(.title).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 3) { Text("SIP account").font(.title2.weight(.semibold)); Text("Your provider, your preferences.").foregroundStyle(.secondary) }
            }
            TabView {
                Form {
                    TextField("Account name", text: $account.label)
                    TextField("Username", text: $account.username)
                    TextField("Domain / host:port", text: $account.domain)
                    SecureField("Password", text: $password)
                    TextField("Authentication username (optional)", text: $account.authUser)
                    TextField("Outbound proxy host:port (optional)", text: $account.proxy)
                    Picker("Transport", selection: $account.transport) { Text("TLS").tag("TLS"); Text("TCP").tag("TCP"); Text("UDP").tag("UDP") }
                    Toggle("Register with the SIP server", isOn: $account.register)
                    Text("Passwords are stored in macOS Keychain. Turn registration off for direct SIP calls.").font(.caption).foregroundStyle(.secondary)
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
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save account") {
                    do { try store.save(account, password: password); dismiss() } catch { validationError = error.localizedDescription }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 640, height: 560).tint(.teal)
        .onAppear { password = Passwords.read(account.id) }
        .alert("Check account settings", isPresented: Binding(get: { validationError != nil }, set: { if !$0 { validationError = nil } })) { Button("OK") { validationError = nil } } message: { Text(validationError ?? "") }
    }
}
