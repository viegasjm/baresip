import SwiftUI
import AVFoundation

@MainActor final class Store: ObservableObject {
    @Published var accounts: [SIPAccount] = []
    @Published var selectedAccount: UUID?
    @Published var calls: [SIPCall] = []
    @Published var selectedCall: String?
    @Published var registrations: [String: String] = [:]
    @Published var destination = ""
    @Published var callHeaders: [SIPHeader] = []
    @Published var connected = false
    @Published var busy = false
    @Published var status = "Ready to connect"
    @Published var error: String?
    @Published var activity: [String] = []
    @Published var transferTarget = ""
    @Published var attendedTransfer = false
    private let engine = Engine()
    private var appliedHeaders: [String: Set<String>] = [:]
    private var transferOriginal: String?
    private var transferConsult: String?
    private var transferExisting: Set<String> = []
    private var registrationTask: Task<Void, Never>?
    private var storage: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BaresipMac/accounts.json")
    }
    var account: SIPAccount? { accounts.first { $0.id == selectedAccount } }
    var call: SIPCall? { calls.first { $0.id == selectedCall } }
    init() {
        do {
            if FileManager.default.fileExists(atPath: storage.path) { accounts = try JSONDecoder().decode([SIPAccount].self, from: Data(contentsOf: storage)) }
        } catch { self.error = "Could not load saved accounts: \(error.localizedDescription)" }
        selectedAccount = accounts.first?.id
        engine.onEvent = { [weak self] in self?.event($0) }
        engine.onExit = { [weak self] message in
            self?.connected = false; self?.calls = []; self?.attendedTransfer = false
            self?.status = "Disconnected"; self?.error = message
        }
    }
    func note(_ text: String) {
        let time = Date().formatted(date: .omitted, time: .shortened)
        activity.insert("\(time)  \(text)", at: 0)
        activity = Array(activity.prefix(100))
    }
    func run(_ operation: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await operation() } catch { self.error = error.localizedDescription }
        }
    }
    func connect() {
        guard calls.isEmpty, !accounts.isEmpty else { return }
        run {
            self.connected = false; self.status = "Connecting…"; self.registrations = [:]
            do {
                try await self.engine.start(accounts: self.accounts)
                self.appliedHeaders = [:]; self.connected = true; self.status = "Connected"
                self.note("SIP engine connected")
                await self.refreshRegistrations()
                self.registrationTask?.cancel()
                self.registrationTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        guard !Task.isCancelled else { return }
                        await self?.refreshRegistrations()
                    }
                }
            } catch { self.status = "Disconnected"; throw error }
        }
    }
    func disconnect() {
        registrationTask?.cancel(); registrationTask = nil
        engine.stop(); connected = false; calls = []; attendedTransfer = false
        registrations = [:]; status = "Disconnected"
    }
    func save(_ account: SIPAccount, password: String) throws {
        guard calls.isEmpty else { throw AppError.message("Finish your calls before changing accounts.") }
        _ = try account.configuration(password: password)
        guard !accounts.contains(where: { $0.id != account.id && $0.aor == account.aor }) else {
            throw AppError.message("This SIP address is already configured.")
        }
        try Passwords.save(password, for: account.id)
        var updated = accounts
        if let index = updated.firstIndex(where: { $0.id == account.id }) { updated[index] = account }
        else { updated.append(account) }
        try persist(updated)
        accounts = updated; selectedAccount = account.id
        if connected { disconnect(); connect() }
    }
    func delete(_ account: SIPAccount) {
        guard calls.isEmpty else { return }
        do {
            let updated = accounts.filter { $0.id != account.id }
            try persist(updated)
            Passwords.delete(account.id)
            accounts = updated; selectedAccount = accounts.first?.id
            if connected { disconnect(); if !accounts.isEmpty { connect() } }
        } catch { self.error = error.localizedDescription }
    }
    private func persist(_ accounts: [SIPAccount]) throws {
        try FileManager.default.createDirectory(at: storage.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(accounts).write(to: storage, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storage.path)
    }
    private func microphone() async throws {
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard allowed else { throw AppError.message("Allow Baresip Mac to use your microphone in System Settings → Privacy & Security → Microphone.") }
    }
    static func dialURI(_ input: String, account: SIPAccount) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !value.contains("\0"), !value.contains("\""), !value.contains("<"), !value.contains(">") else {
            throw AppError.message("Enter a phone number, extension, or SIP address without spaces.")
        }
        if value.hasPrefix("sip:") || value.hasPrefix("sips:") { return value }
        return "sip:" + value + (value.contains("@") ? "" : "@\(account.domain)")
    }
    func dial() {
        guard let account, connected else { return }
        run {
            let uri = try Self.dialURI(self.destination, account: account)
            for header in account.headers + self.callHeaders { try header.validate() }
            try await self.microphone()
            _ = try await self.engine.command("uafind", account.aor)
            // uafind raises this account to index zero in Baresip's UA list.
            let headers = account.headers + self.callHeaders
            let names = Set(headers.map(\.name))
            for name in self.appliedHeaders[account.aor, default: []].union(names) {
                _ = try await self.engine.command("uarmheader", "\(name) 0")
            }
            self.appliedHeaders[account.aor] = names
            for header in headers { _ = try await self.engine.command("uaaddheader", "\(header.commandPair) 0") }
            _ = try await self.engine.command("dial", uri)
            self.note("Calling \(uri) using \(account.displayName)")
        }
    }
    func control(_ command: String, params: String = "", onSuccess: (() -> Void)? = nil) {
        guard let call, connected else { return }
        run {
            if command == "accept" { try await self.microphone() }
            _ = try await self.engine.command("uafind", call.account)
            if call.state != "Incoming" { _ = try await self.engine.command("callfind", call.id) }
            _ = try await self.engine.command(command, command == "accept" || command == "hangup" ? call.id : params)
            if command == "mute", let index = self.calls.firstIndex(where: { $0.id == call.id }) { self.calls[index].muted.toggle() }
            self.note("\(command.capitalized) requested")
            onSuccess?()
        }
    }
    func transfer(attended: Bool) {
        guard let call, let account = accounts.first(where: { $0.aor == call.account }) else { return }
        do {
            let uri = try Self.dialURI(transferTarget, account: account)
            if !attended { control("transfer", params: uri); return }
            run {
                _ = try await self.engine.command("uafind", call.account)
                _ = try await self.engine.command("callfind", call.id)
                let existing = Set(self.calls.map(\.id))
                _ = try await self.engine.command("atransferstart", uri)
                self.transferOriginal = call.id
                self.transferExisting = existing
                self.transferConsult = self.calls.first { !existing.contains($0.id) && $0.account == call.account }?.id
                self.attendedTransfer = true
            }
        } catch { self.error = error.localizedDescription }
    }
    func finishTransfer(abort: Bool) {
        run {
            if !abort {
                guard let consult = self.calls.first(where: { $0.id == self.transferConsult }), consult.connected else {
                    throw AppError.message("Wait for the consultation call to connect before completing the transfer.")
                }
                _ = try await self.engine.command("uafind", consult.account)
                _ = try await self.engine.command("callfind", consult.id)
            }
            _ = try await self.engine.command(abort ? "atransferabort" : "atransferexec")
            self.attendedTransfer = false
            self.transferOriginal = nil; self.transferConsult = nil
        }
    }
    private func refreshRegistrations() async {
        guard connected else { return }
        guard let text = try? await engine.command("reginfo") else { return }
        let clean = text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
        for account in accounts {
            if !account.register { registrations[account.aor] = "Direct calls"; continue }
            guard let line = clean.components(separatedBy: .newlines).first(where: { $0.contains(account.aor) }) else { continue }
            if line.contains("OK") { registrations[account.aor] = "Registered" }
            else if line.contains("zzz") { registrations[account.aor] = "Registering…" }
            else { registrations[account.aor] = "Registration failed" }
        }
    }
    private func event(_ object: [String: Any]) {
        let type = object["type"] as? String ?? ""
        let aor = object["accountaor"] as? String ?? ""
        if type == "REGISTER_OK" { registrations[aor] = "Registered"; note("Account registered: \(aor)"); return }
        if type == "REGISTER_FAIL" { registrations[aor] = "Registration failed"; note("Registration failed: \(aor)"); return }
        guard let id = object["id"] as? String else { return }
        if type == "CALL_CLOSED" {
            calls.removeAll { $0.id == id }
            if selectedCall == id { selectedCall = calls.first?.id }
            if calls.isEmpty { attendedTransfer = false }
            if id == transferConsult || id == transferOriginal {
                attendedTransfer = false; transferOriginal = nil; transferConsult = nil
            }
            note("Call ended: \(object["param"] as? String ?? "")")
            return
        }
        let states = ["CALL_INCOMING": "Incoming", "CALL_OUTGOING": "Calling", "CALL_RINGING": "Ringing", "CALL_PROGRESS": "Connecting", "CALL_ANSWERED": "Connected", "CALL_ESTABLISHED": "Connected"]
        if let state = states[type] {
            if attendedTransfer, transferConsult == nil, !transferExisting.contains(id),
               object["direction"] as? String == "outgoing" { transferConsult = id }
            if let index = calls.firstIndex(where: { $0.id == id }) {
                if state == "Connected", calls[index].state != "Connected" { calls[index].started = Date() }
                calls[index].state = state
            }
            else {
                calls.append(SIPCall(id: id, account: aor, peer: object["peeruri"] as? String ?? "Unknown caller", state: state, incoming: object["direction"] as? String == "incoming"))
                selectedCall = id
            }
            if type == "CALL_INCOMING" { NSApp.requestUserAttention(.criticalRequest) }
        }
        if let index = calls.firstIndex(where: { $0.id == id }) {
            if type == "CALL_HOLD" { calls[index].held = true }
            if type == "CALL_RESUME" { calls[index].held = false }
        }
        if type == "TRANSFER_FAILED" { error = "Call transfer failed: \(object["param"] as? String ?? "Unknown reason")"; attendedTransfer = false }
    }
}
