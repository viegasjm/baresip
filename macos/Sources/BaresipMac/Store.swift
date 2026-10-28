import SwiftUI
import AVFoundation

@MainActor final class Store: ObservableObject {
    @Published var diagnostics = DebugJournal()
    @Published var captureDiagnostics = true
    @Published var monoDeviceAudio = UserDefaults.standard.object(forKey: "monoDeviceAudio") as? Bool ?? true {
        didSet { UserDefaults.standard.set(monoDeviceAudio, forKey: "monoDeviceAudio") }
    }
    @Published var inputMode = CallInputMode.automatic
    @Published var audioFile: PreparedAudioFile?
    private var preparedAudioFiles: [PreparedAudioFile] = []
    private var nextCallInput = ""
    @Published var audioDevices = AudioDeviceCatalog()
    @Published var inputDeviceUID = UserDefaults.standard.string(forKey: "inputDeviceUID") ?? "default"
    @Published var outputDeviceUID = UserDefaults.standard.string(forKey: "outputDeviceUID") ?? "default"
    var audioRouting: AudioRouting { AudioRouting(inputUID: inputDeviceUID, outputUID: outputDeviceUID) }
    @Published var accounts: [SIPAccount] = []
    @Published var selectedAccount: UUID?
    @Published var calls: [SIPCall] = []
    @Published var selectedCall: String?
    @Published var registrations: [String: String] = [:]
    @Published var registrationErrors: [String: String] = [:]
    @Published var destination = ""
    @Published var callHeaders: [SIPHeader] = []
    @Published var activeAccounts: Set<UUID> = []
    @Published var connected = false
    @Published var busy = false
    @Published var status = "Ready to connect"
    @Published var error: String?
    @Published var activity: [String] = []
    @Published var transferTarget = ""
    @Published var attendedTransfer = false
    private let engine: Engine
    private var appliedHeaders: [String: Set<String>] = [:]
    private var transferOriginal: String?
    private var transferConsult: String?
    private var transferExisting: Set<String> = []
    private var registrationTask: Task<Void, Never>?
    private let storageOverride: URL?
    private let audioCatalog: () -> AudioDeviceCatalog
    private var storage: URL {
        if let storageOverride { return storageOverride }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BaresipMac/accounts.json")
    }
    var account: SIPAccount? { accounts.first { $0.id == selectedAccount } }
    func connection(for account: SIPAccount?) -> AccountConnection {
        AccountConnection(engineConnected: connected && account.map { activeAccounts.contains($0.id) } == true, starting: status == "Connecting…" && account.map { activeAccounts.contains($0.id) } == true, account: account, registration: account.flatMap { registrations[$0.aor] })
    }
    var accountConnection: AccountConnection { connection(for: account) }
    var call: SIPCall? { calls.first { $0.id == selectedCall } }
    init(storageURL: URL? = nil, engine testEngine: Engine? = nil, audioCatalog: @escaping () -> AudioDeviceCatalog = AudioDiagnostics.catalog) {
        self.engine = testEngine ?? Engine()
        self.storageOverride = storageURL
        self.audioCatalog = audioCatalog
        audioDevices = audioCatalog()
        do {
            if FileManager.default.fileExists(atPath: storage.path) { accounts = try JSONDecoder().decode([SIPAccount].self, from: Data(contentsOf: storage)) }
        } catch { self.error = "Could not load saved accounts: \(error.localizedDescription)" }
        selectedAccount = accounts.first?.id
        engine.onOutput = { [weak self] line in
            guard let self, self.captureDiagnostics else { return }
            self.diagnostics.add(category: "Engine", summary: line, detail: line)
        }
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
    func connect(account target: SIPAccount? = nil) {
        guard calls.isEmpty, !accounts.isEmpty else { return }
        run {
            self.activeAccounts = Set(target.map { [$0.id] } ?? self.accounts.map(\.id))
            self.connected = false; self.status = "Connecting…"; self.registrations = [:]; self.registrationErrors = [:]
            do {
                try await self.engine.start(accounts: self.accounts, monoDeviceAudio: self.monoDeviceAudio, audioRouting: self.audioRouting, registeringAccounts: self.activeAccounts)
                self.appliedHeaders = [:]; self.connected = true; self.status = "SIP engine ready"
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
    func registrationAction(_ account: SIPAccount, disconnect: Bool = false) {
        guard connected else { connect(account: account); return }
        guard !calls.contains(where: { $0.account == account.aor }) || !disconnect else { return }
        run {
            if disconnect { self.activeAccounts.remove(account.id) }
            else {
                self.activeAccounts.insert(account.id)
                self.registrations[account.aor] = "Registering…"
                self.registrationErrors[account.aor] = nil
            }
            do {
                try await self.engine.register(account, enabled: !disconnect)
                if disconnect { self.registrations[account.aor] = "Offline" }
                self.note("\(disconnect ? "Disconnected" : "Registration requested"): \(account.displayName)")
            } catch {
                self.registrations[account.aor] = "Registration failed"
                self.registrationErrors[account.aor] = error.localizedDescription
                throw error
            }
        }
    }
    func sendDTMF(_ digit: String) {
        guard let call, call.connected, !call.held,
              digit.count == 1, "0123456789*#".contains(digit) else { return }
        control("sndcode", params: digit)
    }
    func disconnect() {
        registrationTask?.cancel(); registrationTask = nil
        engine.stop(); connected = false; calls = []; attendedTransfer = false
        activeAccounts = []; registrations = [:]; registrationErrors = [:]; status = "Disconnected"
    }
    func save(_ account: SIPAccount, password: String) throws {
        guard calls.isEmpty else { throw AppError.message("Finish your calls before changing accounts.") }
        guard !busy else { throw AppError.message("Wait for the current action to finish before saving.") }
        try account.validate()
        _ = try Passwords.commandValue(password)
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
    func refreshAudioDevices() { audioDevices = audioCatalog() }
    func audioDeviceChanged() {
        guard calls.isEmpty, !busy else { return }
        UserDefaults.standard.set(inputDeviceUID, forKey: "inputDeviceUID")
        UserDefaults.standard.set(outputDeviceUID, forKey: "outputDeviceUID")
        if connected { connect() }
    }
    private func prepareCallInput(mode override: CallInputMode? = nil) async throws -> CallAudioInput {
        let requestedMode = override ?? inputMode
        refreshAudioDevices()
        let hasMicrophone = audioDevices.resolve(inputDeviceUID, input: true) != nil
        var allowed = false
        if requestedMode == .automatic && hasMicrophone {
            allowed = await AVCaptureDevice.requestAccess(for: .audio)
        }
        let input = try audioRouting.callInput(mode: requestedMode, file: audioFile?.url, in: audioDevices, microphoneAllowed: allowed)
        if input == .listen && requestedMode == .automatic {
            note(hasMicrophone ? "Microphone access unavailable; continuing in listen-only mode" : "No microphone available; continuing in listen-only mode")
        }
        return input
    }
    func importAudioFile(_ url: URL, callID: String? = nil) {
        run {
            let prepared = try await Task.detached { try AudioFileInput.prepare(url) }.value
            self.preparedAudioFiles.append(prepared)
            self.audioFile = prepared
            self.inputMode = .file
            self.note("Audio file ready: \(prepared.name)")
            if let callID {
                guard let call = self.calls.first(where: { $0.id == callID }), call.connected, !call.held else {
                    throw AppError.message("The selected call is no longer available for playback. The file is ready for your next call.")
                }
                _ = try await self.engine.command("callfind", call.id)
                _ = try await self.engine.command("callsource", "aufile,\(prepared.url.path)")
                if let index = self.calls.firstIndex(where: { $0.id == call.id }) { self.calls[index].audioInput = "Playing \(prepared.name)" }
                self.note("Playing \(prepared.name) into call · Call-ID: \(call.sipID)")
            }
        }
    }
    func stopSendingAudio() {
        let id = call?.id
        control("callsource", params: "none") { [weak self] in
            guard let self, let id, let index = self.calls.firstIndex(where: { $0.id == id }) else { return }
            self.calls[index].audioInput = CallAudioInput.listen.title
        }
    }
    func clearAudioFile() {
        guard calls.isEmpty, !busy else { return }
        removeTemporaryAudio(); audioFile = nil; inputMode = .automatic
    }
    func removeTemporaryAudio() { preparedAudioFiles.forEach { $0.remove() }; preparedAudioFiles.removeAll() }
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
        guard accountConnection.canDial else {
            error = "This account is not registered. Edit its connection settings or retry registration before calling."
            return
        }
        run {
            let uri = try Self.dialURI(self.destination, account: account)
            for header in account.headers + self.callHeaders { try header.validate() }
            let input = try await self.prepareCallInput()
            _ = try await self.engine.command("uafind", account.aor)
            // uafind raises this account to index zero in Baresip's UA list.
            let headers = account.headers + self.callHeaders
            let names = Set(headers.map(\.name))
            for name in self.appliedHeaders[account.aor, default: []].union(names) {
                _ = try await self.engine.command("uarmheader", "\(name) 0")
            }
            self.appliedHeaders[account.aor] = names
            for header in headers { _ = try await self.engine.command("uaaddheader", "\(header.commandPair) 0") }
            if let source = input.source { _ = try await self.engine.command("ausrcdefault", source) }
            self.nextCallInput = input == .listen ? input.title : (self.inputMode == .file ? "Playing \(self.audioFile?.name ?? "audio file")" : input.title)
            _ = try await self.engine.command("dialdir", "\(uri) audio=\(input.direction) video=inactive")
            self.note("Calling \(uri) using \(account.displayName)")
        }
    }
    func control(_ command: String, params: String = "", onSuccess: (() -> Void)? = nil) {
        guard let call, connected else { return }
        run {
            let input = command == "accept" ? try await self.prepareCallInput(mode: call.localPeerID == nil ? nil : .listen) : nil
            _ = try await self.engine.command("uafind", call.account)
            if call.state != "Incoming" { _ = try await self.engine.command("callfind", call.id) }
            if let input {
                if let peer = call.localPeerID { _ = try await self.engine.command("callpair", "\(call.id) \(peer)") }
                _ = try await self.engine.command("callfind", call.id)
                if let source = input.source { _ = try await self.engine.command("callsource", source) }
                _ = try await self.engine.command("acceptdir", "audio=\(input.direction) video=inactive callid=\(call.id)")
                if let index = self.calls.firstIndex(where: { $0.id == call.id }) { self.calls[index].audioInput = input.title }
            } else {
                _ = try await self.engine.command(command, ["hangup", "hold", "resume"].contains(command) ? call.id : params)
            }
            if ["hold", "resume"].contains(command), let index = self.calls.firstIndex(where: { $0.id == call.id }) {
                self.calls[index].held = command == "hold"
            }
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
        for account in accounts where activeAccounts.contains(account.id) {
            if !account.register { registrations[account.aor] = "Direct calls"; continue }
            guard let line = clean.components(separatedBy: .newlines).first(where: { $0.contains(account.aor) }) else { continue }
            if line.contains("OK") { registrations[account.aor] = "Registered"; registrationErrors[account.aor] = nil }
            else if line.contains("zzz") { registrations[account.aor] = "Registering…" }
            else { registrations[account.aor] = "Registration failed" }
        }
    }
    func captureSnapshot() {
        run {
            self.diagnostics.add(category: "Snapshot", summary: "macOS audio devices and permissions", detail: AudioDiagnostics.snapshot() + "\nSelected input UID: \(self.inputDeviceUID)\nSelected output UID: \(self.outputDeviceUID)\nNext connection mono device audio: \(self.monoDeviceAudio)")
            guard self.connected else { return }
            for command in ["about", "reginfo", "callstat"] {
                do {
                    let result = try await self.engine.command(command)
                    self.diagnostics.add(category: "Snapshot", summary: command, detail: result)
                } catch {
                    self.diagnostics.add(category: "Snapshot", summary: command, detail: error.localizedDescription)
                }
            }
            if let call = self.call {
                _ = try await self.engine.command("uafind", call.account)
                _ = try await self.engine.command("callfind", call.id)
                let audio = try await self.engine.command("audio_debug")
                self.diagnostics.add(category: "Snapshot", summary: "Negotiated audio and RTP", detail: audio, callID: call.sipID)
            }
        }
    }
    private func event(_ object: [String: Any]) {
        if object["type"] as? String == "SIP_TRACE" {
            if captureDiagnostics { diagnostics.packet(object) }
            return
        }
        if captureDiagnostics { diagnostics.event(object) }
        let type = object["type"] as? String ?? ""
        let aor = object["accountaor"] as? String ?? ""
        if type.hasPrefix("REGISTER_"), !accounts.contains(where: { $0.aor == aor && activeAccounts.contains($0.id) }) { return }
        if type == "REGISTER_OK" { registrations[aor] = "Registered"; registrationErrors[aor] = nil; note("Account registered: \(aor)"); return }
        if type == "REGISTER_FAIL" {
            registrations[aor] = "Registration failed"
            let reason = object["param"] as? String ?? "The SIP server did not accept this registration."
            registrationErrors[aor] = reason
            note("Registration failed: \(aor) — \(reason)")
            return
        }
        guard let rawID = object["id"] as? String, let id = SIPCall.controlID(object) else { return }
        if type == "END_OF_FILE" {
            if let index = calls.firstIndex(where: { $0.id == id }) { calls[index].audioInput = "Audio file finished" }
            note("Audio file finished; call remains connected · Call-ID: \(rawID)")
            return
        }
        if type == "CALL_CLOSED" {
            calls.removeAll { $0.id == id }
            if selectedCall == id { selectedCall = calls.first?.id }
            if calls.isEmpty { attendedTransfer = false }
            if id == transferConsult || id == transferOriginal {
                attendedTransfer = false; transferOriginal = nil; transferConsult = nil
            }
            let reason = object["param"] as? String ?? ""
            note("Call ended: \(reason) · Call-ID: \(rawID)")
            if DebugJournal.deviceExplanation(reason) != nil {
                refreshAudioDevices()
                error = "Call audio could not start. Check your microphone and speaker in the Audio tab, then try again. Your SIP accounts remain connected. Details are available in Debug."
                note("Local audio device error. Open the Debug tab for microphone/speaker details.")
            }
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
                calls.append(SIPCall(id: id, account: aor, peer: object["peeruri"] as? String ?? "Unknown caller", state: state, incoming: object["direction"] as? String == "incoming", sipCallID: rawID))
                if type != "CALL_INCOMING", let index = calls.firstIndex(where: { $0.id == id }) { calls[index].audioInput = nextCallInput }
                selectedCall = id
            }
            let numbers = accounts.first { $0.aor == aor }?.assignedNumbers ?? []
            if type == "CALL_INCOMING", let incoming = calls.first(where: { $0.id == id }), let partner = incoming.localPartner(in: calls, phoneNumbers: numbers) {
                if let index = calls.firstIndex(where: { $0.id == id }) { calls[index].localPeerID = partner.id }
                if let index = calls.firstIndex(where: { $0.id == partner.id }) { calls[index].localPeerID = id }
            }
            if type == "CALL_INCOMING" { NSApp?.requestUserAttention(.criticalRequest) }
        }
        if let index = calls.firstIndex(where: { $0.id == id }) {
            calls[index].updateHoldState(object)
            if let peer = object["local_peer_leg"] as? String, !peer.isEmpty { calls[index].localPeerID = peer }
        }
        if type == "TRANSFER_FAILED" { error = "Call transfer failed: \(object["param"] as? String ?? "Unknown reason")"; attendedTransfer = false }
    }
}
