import SwiftUI

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
