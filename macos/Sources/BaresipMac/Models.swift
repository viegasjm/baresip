import Foundation
import Security

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
    var transport = "TLS"
    var register = true
    var codecs = Codec.defaults
    var headers: [SIPHeader] = []
    var aor: String { "sip:\(username)@\(domain)" }
    var displayName: String { label.isEmpty ? username : label }
    func validate() throws {
        let forbidden = CharacterSet(charactersIn: "\"<>;\r\n\t \\")
        for value in [username, domain, authUser, proxy] {
            guard value.rangeOfCharacter(from: forbidden) == nil else { throw AppError.message("Account fields cannot contain spaces, quotes, brackets, backslashes, or semicolons.") }
        }
        guard !username.isEmpty, !domain.isEmpty, !domain.contains("@"), !username.contains("@") else { throw AppError.message("Enter a username and SIP domain separately.") }
        guard ["UDP", "TCP", "TLS"].contains(transport) else { throw AppError.message("Choose a supported SIP transport.") }
        guard codecs.contains(where: \.enabled) else { throw AppError.message("Enable at least one audio codec.") }
        for header in headers { try header.validate() }
    }
    func configuration(startRegistration: Bool = true) throws -> String {
        try validate()
        var line = "<\(aor);transport=\(transport.lowercased())>;regint=\(register && startRegistration ? 300 : 0);audio_codecs=\(codecs.filter(\.enabled).map(\.name).joined(separator: ","))"
        if !authUser.isEmpty { line += ";auth_user=\(authUser)" }
        if !proxy.isEmpty { line += ";outbound=\"sip:\(proxy);transport=\(transport.lowercased())\"" }
        return line
    }
}
struct SIPCall: Identifiable, Equatable {
    var id: String
    var account: String
    var peer: String
    var state: String
    var incoming: Bool
    var held = false
    var muted = false
    var started = Date()
    var connected: Bool { state == "Connected" }
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
    static let service = "com.viegasjm.baresip-mac"
    static func load(_ id: UUID) throws -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data else {
            throw AppError.message("Could not read this account's password from Keychain (\(status)). Allow access or enter the password again.")
        }
        return String(decoding: data, as: UTF8.self)
    }
    static func commandValue(_ password: String) throws -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = password.addingPercentEncoding(withAllowedCharacters: safe) ?? ""
        guard encoded.utf8.count < 900 else { throw AppError.message("The encoded password exceeds the engine command size limit.") }
        return "value=" + encoded
    }
    static func save(_ password: String, for id: UUID) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
        let update = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = q
            insert[kSecValueData as String] = Data(password.utf8)
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw AppError.message("Could not save the password in Keychain (\(added)).") }
        } else if status != errSecSuccess { throw AppError.message("Could not update Keychain (\(status)).") }
    }
    static func delete(_ id: UUID) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString] as CFDictionary)
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
