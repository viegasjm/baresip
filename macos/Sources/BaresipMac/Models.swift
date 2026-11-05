import Foundation

struct SIPHeader: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "X-Customer-ID"
    var value = ""
    func validate() throws {
        guard name.range(of: "^[A-Za-z0-9!#$%&'*+.^_`|~-]+$", options: .regularExpression) != nil,
              !value.contains(where: { $0.isNewline || $0 == "\0" }), !value.isEmpty else {
            throw AppError.message("Enter a valid header name and a nonempty value without line breaks.")
        }
        guard value.utf8.count < 700 else { throw AppError.message("Header values must be shorter than 700 bytes.") }
    }
    var commandPair: String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return name + "=" + (value.addingPercentEncoding(withAllowedCharacters: safe) ?? "")
    }
}
struct Codec: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var enabled = true
    static let defaults = [Codec(name: "opus/48000/2"), Codec(name: "G722/16000/1"), Codec(name: "PCMA/8000/1"), Codec(name: "PCMU/8000/1")]
}
struct SIPAccount: Codable, Identifiable, Equatable {
    var id = UUID()
    var label = ""
    var username = ""
    var domain = ""
    var authUser = ""
    var proxy = ""
    var phoneNumbers: String?
    var transport = "TLS"
    var register = true
    var codecs = Codec.defaults
    var headers: [SIPHeader] = []
    var aor: String { "sip:\(username)@\(domain)" }
    var displayName: String { label.isEmpty ? username : label }
    var assignedNumbers: [String] { phoneNumbers?.split { $0 == "," || $0.isWhitespace }.map(String.init) ?? [] }
    func validate() throws {
        let forbidden = CharacterSet(charactersIn: "\"<>;\r\n\t \\")
        for value in [username, domain, authUser, proxy] {
            guard value.rangeOfCharacter(from: forbidden) == nil else { throw AppError.message("Account fields cannot contain spaces, quotes, brackets, backslashes, or semicolons.") }
        }
        guard !username.isEmpty, !domain.isEmpty, !domain.contains("@"), !username.contains("@") else { throw AppError.message("Enter a username and SIP domain separately.") }
        guard ["UDP", "TCP", "TLS"].contains(transport) else { throw AppError.message("Choose a supported SIP transport.") }
        guard codecs.contains(where: \.enabled) else { throw AppError.message("Enable at least one audio codec.") }
        for number in assignedNumbers {
            guard number.range(of: "^\\+[1-9][0-9]{6,14}$", options: .regularExpression) != nil else { throw AppError.message("Enter assigned numbers in full international format, such as +12025550123.") }
        }
        for header in headers { try header.validate() }
    }
    func configuration(startRegistration: Bool = true) throws -> String {
        try validate()
        var line = "<\(aor);transport=\(transport.lowercased())>;regint=\(register && startRegistration ? 300 : 0);natpinhole=yes;dtmfmode=auto;audio_codecs=\(codecs.filter(\.enabled).map(\.name).joined(separator: ","))"
        if !authUser.isEmpty { line += ";auth_user=\(authUser)" }
        if !proxy.isEmpty { line += ";outbound=\"sip:\(proxy);transport=\(transport.lowercased())\"" }
        if !assignedNumbers.isEmpty { line += ";inbound_numbers=\(assignedNumbers.joined(separator: ","))" }
        return line
    }
}
struct SIPCall: Identifiable, Equatable {
    var id: String
    var account: String
    var peer: String
    var state: String
    var incoming: Bool
    var sipCallID = ""
    var localPeerID: String?
    var sipID: String { sipCallID.isEmpty ? id : sipCallID }
    static func controlID(_ event: [String: Any]) -> String? { event["leg_id"] as? String ?? event["id"] as? String }
    static func uriIdentity(_ value: String) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "sips:", with: "").replacingOccurrences(of: "sip:", with: "")
        let address = clean.components(separatedBy: ";")[0].components(separatedBy: "?")[0]
        guard let at = address.lastIndex(of: "@") else { return address }
        return String(address[...at]) + address[address.index(after: at)...].lowercased()
    }
    func localPartner(in calls: [SIPCall], phoneNumbers: [String] = []) -> SIPCall? {
        guard incoming else { return nil }
        let candidates = calls.filter { !$0.incoming && $0.account != account && $0.localPeerID == nil }
        let exact = candidates.filter { $0.sipID == sipID }
        if exact.count == 1 { return exact[0] }
        let targeted = candidates.filter {
            let target = Self.uriIdentity($0.peer)
            let number = target.components(separatedBy: "@")[0]
            return (target == Self.uriIdentity(account) || phoneNumbers.contains(number)) && Date().timeIntervalSince($0.started) < 30
        }
        return targeted.count == 1 ? targeted[0] : nil
    }
    var held = false
    var remoteHeld = false
    var audioInput = ""
    var muted = false
    var started = Date()
    var connected: Bool { state == "Connected" }
    var statusTitle: String { held ? "On hold" : (remoteHeld ? "Held by remote party" : state) }
    mutating func updateHoldState(_ event: [String: Any]) {
        if let local = event["local_hold"] as? Bool { held = local }
        if event["type"] as? String == "CALL_HOLD" { remoteHeld = true }
        if event["type"] as? String == "CALL_RESUME" { remoteHeld = false }
    }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct Netstrings {
    private(set) var buffer = Data()
    static func encode(_ object: [String: String]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return Data("\(json.count):".utf8) + json + Data(",".utf8)
    }
    mutating func feed(_ data: Data) throws -> [[String: Any]] {
        buffer.append(data)
        var result: [[String: Any]] = []
        while let colon = buffer.firstIndex(of: 58) {
            guard colon < 10, let length = Int(String(decoding: buffer.prefix(colon), as: UTF8.self)), length >= 0, length <= 1_048_576 else { throw AppError.message("Invalid engine response length.") }
            let start = colon + 1, end = start + length
            guard buffer.count > end else { break }
            guard buffer[end] == 44 else { throw AppError.message("Invalid engine response framing.") }
            guard let object = try JSONSerialization.jsonObject(with: buffer.subdata(in: start..<end)) as? [String: Any] else { throw AppError.message("Invalid engine response.") }
            result.append(object)
            buffer.removeSubrange(0...end)
            buffer = Data(buffer)
        }
        if buffer.count > 1_048_600 { throw AppError.message("Engine response is too large.") }
        return result
    }
}
enum Passwords {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BaresipMac/credentials", isDirectory: true)
    }
    static func load(_ id: UUID, directory override: URL? = nil) throws -> String {
        let file = (override ?? directory).appendingPathComponent(id.uuidString)
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return String(decoding: try Data(contentsOf: file), as: UTF8.self)
    }
    static func commandValue(_ password: String) throws -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = password.addingPercentEncoding(withAllowedCharacters: safe) ?? ""
        guard encoded.utf8.count < 900 else { throw AppError.message("The encoded password exceeds the engine command size limit.") }
        return "value=" + encoded
    }
    static func save(_ password: String, for id: UUID, directory override: URL? = nil) throws {
        let folder = override ?? directory
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        let file = folder.appendingPathComponent(id.uuidString)
        try Data(password.utf8).write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func delete(_ id: UUID, directory override: URL? = nil) {
        try? FileManager.default.removeItem(at: (override ?? directory).appendingPathComponent(id.uuidString))
    }
}

struct AccountEditorRequest: Identifiable {
    let id = UUID()
    let account: SIPAccount
}
struct AccountConnection {
    enum Phase { case offline, starting, registering, registered, failed, direct }
    let phase: Phase
    init(engineConnected: Bool, starting: Bool, account: SIPAccount?, registration: String?) {
        if starting { phase = .starting }
        else if !engineConnected || account == nil { phase = .offline }
        else if account?.register == false { phase = .direct }
        else if registration == "Registered" { phase = .registered }
        else if registration == "Registration failed" { phase = .failed }
        else { phase = .registering }
    }
    var title: String {
        switch phase {
        case .offline: return "Offline"
        case .starting: return "Connecting…"
        case .registering: return "Registering…"
        case .registered: return "Registered"
        case .failed: return "Registration failed"
        case .direct: return "Direct calls ready"
        }
    }
    var canDial: Bool { phase == .registered || phase == .direct }
}
