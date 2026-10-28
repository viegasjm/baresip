import Foundation
import Network
import Darwin

@MainActor final class Engine {
    private let loopbackOnly: Bool
    private let passwordOverrides: [UUID: String]
    init(loopbackOnly: Bool = false, passwordOverrides: [UUID: String] = [:]) {
        self.loopbackOnly = loopbackOnly
        self.passwordOverrides = passwordOverrides
    }
    var onEvent: (([String: Any]) -> Void)?
    var onOutput: ((String) -> Void)?
    private var outputLines = EngineOutputLines()
    var onExit: ((String) -> Void)?
    private var process: Process?
    private var connection: NWConnection?
    private var parser = Netstrings()
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    private var runtime: URL?
    private var running = false
    private var generation = UUID()
    var ready = false
    private var output: Pipe?
    private var connecting: CheckedContinuation<Void, Error>?

    func start(accounts: [SIPAccount], monoDeviceAudio: Bool = true, audioRouting: AudioRouting = AudioRouting(), registeringAccounts: Set<UUID>? = nil) async throws {
        try audioRouting.validate()
        stop()
        generation = UUID()
        let fm = FileManager.default
        guard let resources = Bundle.main.resourceURL else { throw AppError.message("App resources are unavailable.") }
        let executable = resources.appendingPathComponent("Engine/baresip")
        guard fm.isExecutableFile(atPath: executable.path) else { throw AppError.message("The Baresip engine is missing. Build the app with macos/scripts/build.sh.") }
        let folder = fm.temporaryDirectory.appendingPathComponent("BaresipMac-\(UUID().uuidString)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        runtime = folder
        let accountText = try accounts.map { try $0.configuration(startRegistration: false) }.joined(separator: "\n") + "\n"
        let port = try Self.freePort()
        let config = """
        \(loopbackOnly ? "net_interface 127.0.0.1" : "")
        sip_listen 0.0.0.0:0
        sip_transports udp,tcp,tls
        sip_verify_server yes
        sip_cafile \(resources.appendingPathComponent("Engine/ca-certificates.crt").path)
        audio_player coreaudio,\(audioRouting.outputUID)
        audio_source coreaudio,\(audioRouting.inputUID)
        audio_alert coreaudio,\(audioRouting.outputUID)
        audio_path \(resources.appendingPathComponent("Engine/sounds").path)
        ausrc_channels \(monoDeviceAudio ? 1 : 0)
        auplay_channels \(monoDeviceAudio ? 1 : 0)
        audio_level no
        call_max_calls 8
        call_hold_other_calls yes
        call_local_timeout 120
        module g711
        module g722
        module opus
        module coreaudio
        module aufile
        module auconv
        module auresamp
        module stun
        module turn
        module ice
        module srtp
        module uuid
        module menu
        module ctrl_tcp
        module_app account
        account_password_prompt no
        ctrl_tcp_trace yes
        ctrl_tcp_listen 127.0.0.1:\(port)
        """
        try writePrivate(accountText, to: folder.appendingPathComponent("accounts"))
        try writePrivate(config, to: folder.appendingPathComponent("config"))
        let child = Process(), pipe = Pipe()
        child.executableURL = executable
        child.arguments = ["-f", folder.path]
        child.standardOutput = pipe
        child.standardError = pipe
        child.standardInput = FileHandle.nullDevice
        outputLines = EngineOutputLines()
        let outputGeneration = generation
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in
                guard let self, self.generation == outputGeneration else { return }
                for line in self.outputLines.feed(data) { self.onOutput?(line) }
            }
        }
        output = pipe
        let currentGeneration = generation
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self, self.generation == currentGeneration, self.running else { return }
                self.stop()
                self.onExit?("The SIP engine stopped (status \(child.terminationStatus)). Reconnect to restart it.")
            }
        }
        process = child
        do { try child.run(); running = true } catch { stop(); throw error }
        for _ in 0..<30 {
            guard child.isRunning else { stop(); throw AppError.message("The SIP engine could not start.") }
            do {
                try await connect(port: port)
                _ = try await command("about")
                break
            } catch {
                connection?.cancel()
                connection = nil
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        guard connection != nil else {
            stop(); throw AppError.message("Could not connect to the SIP engine.")
        }
        do {
            // Fail startup clearly if the account module stopped partway through.
            for account in accounts {
                do { _ = try await command("uafind", account.aor) }
                catch { throw AppError.message("The SIP engine did not load \(account.displayName) (\(account.aor)). Check the Engine log. \(error.localizedDescription)") }
            }
            for account in accounts where registeringAccounts == nil || registeringAccounts!.contains(account.id) {
                let id = account.id
                let password: String
                if let supplied = passwordOverrides[id] { password = supplied }
                else { password = try await Task.detached { try Passwords.load(id) }.value }
                _ = try await command("uafind", account.aor)
                _ = try await command("uapassword", "\(try Passwords.commandValue(password)) 0")
                if account.register { _ = try await command("uareg", "300 0") }
            }
            ready = true
            // Account settings are loaded; passwords were supplied only through the control channel.
            try? fm.removeItem(at: folder.appendingPathComponent("accounts"))
            return
        } catch {
            stop(); throw error
        }
    }
    func register(_ account: SIPAccount, enabled: Bool) async throws {
        if enabled {
            let password: String
            if let supplied = passwordOverrides[account.id] { password = supplied }
            else { password = try await Task.detached { try Passwords.load(account.id) }.value }
            _ = try await command("uafind", account.aor)
            _ = try await command("uapassword", "\(try Passwords.commandValue(password)) 0")
        } else { _ = try await command("uafind", account.aor) }
        _ = try await command("uareg", enabled && account.register ? "300 0" : "0 0")
    }
    private func writePrivate(_ text: String, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else { throw AppError.message("Could not write the private SIP configuration.") }
    }
    private func connect(port: UInt16) async throws {
        parser = Netstrings()
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection = conn
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connecting = continuation
            conn.stateUpdateHandler = { [weak self, weak conn] state in
                Task { @MainActor in
                    guard let self, let conn, conn === self.connection, let waiting = self.connecting else { return }
                    switch state {
                    case .ready:
                        self.connecting = nil; waiting.resume()
                    case .failed(let error), .waiting(let error):
                        self.connecting = nil; waiting.resume(throwing: error)
                    case .cancelled:
                        self.connecting = nil; waiting.resume(throwing: AppError.message("Connection cancelled."))
                    default: break
                    }
                }
            }
            conn.start(queue: .main)
            Task { [weak self, weak conn] in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, let conn, conn === self.connection, let waiting = self.connecting else { return }
                self.connecting = nil
                waiting.resume(throwing: AppError.message("Local connection timed out."))
            }
        }
        receive(conn)
    }
    private func receive(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak conn] data, _, complete, error in
            Task { @MainActor in
                guard let self, let conn, conn === self.connection else { return }
                do {
                    if let data {
                        for object in try self.parser.feed(data) {
                            if let token = object["token"] as? String, let continuation = self.pending.removeValue(forKey: token) {
                                if object["ok"] as? Bool == true { continuation.resume(returning: object["data"] as? String ?? "") }
                                else { continuation.resume(throwing: AppError.message(object["data"] as? String ?? "The SIP command failed.")) }
                            } else if object["event"] as? Bool == true { self.onEvent?(object) }
                        }
                    }
                    if complete || error != nil {
                        let wasReady = self.ready
                        self.stop()
                        if wasReady { self.onExit?("Connection to the SIP engine was lost. Reconnect to continue.") }
                    } else { self.receive(conn) }
                } catch {
                    self.stop(); self.onExit?(error.localizedDescription)
                }
            }
        }
    }
    func command(_ name: String, _ params: String = "") async throws -> String {
        guard let conn = connection else { throw AppError.message("Connect the SIP engine first.") }
        guard name.utf8.count + params.utf8.count < 1000 else { throw AppError.message("This SIP command exceeds the engine's size limit.") }
        let token = UUID().uuidString
        let packet = try Netstrings.encode(["command": name, "params": params, "token": token])
        return try await withCheckedThrowingContinuation { continuation in
            pending[token] = continuation
            conn.send(content: packet, completion: .contentProcessed { [weak self] error in
                if let error { Task { @MainActor in self?.pending.removeValue(forKey: token)?.resume(throwing: error) } }
            })
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.pending.removeValue(forKey: token)?.resume(throwing: AppError.message("The SIP engine did not respond in time."))
            }
        }
    }
    func stop() {
        running = false; ready = false
        generation = UUID()
        connecting?.resume(throwing: AppError.message("Connection cancelled.")); connecting = nil
        connection?.cancel(); connection = nil
        for continuation in pending.values { continuation.resume(throwing: AppError.message("The SIP engine disconnected.")) }
        pending.removeAll()
        if let process, process.isRunning { process.terminate() }
        process = nil
        output?.fileHandleForReading.readabilityHandler = nil; output = nil
        if let runtime { try? FileManager.default.removeItem(at: runtime) }
        runtime = nil
    }
    private static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AppError.message("Could not create a local control socket.") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw AppError.message("Could not bind a local control socket.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let status = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard status == 0 else { throw AppError.message("Could not select a local control port.") }
        return UInt16(bigEndian: address.sin_port)
    }
}
