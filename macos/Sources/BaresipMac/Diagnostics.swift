import Foundation

struct DebugEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let category: String
    let summary: String
    let detail: String
    let callID: String?
}
struct CallDebug: Identifiable {
    let id: String
    var account = ""
    var peer = ""
    var state = ""
    var firstInvite = ""
    var failure = ""
    var codec = ""
    let started = Date()
}
struct DebugJournal {
    private(set) var entries: [DebugEntry] = []
    private(set) var calls: [CallDebug] = []
    static func redact(_ text: String) -> String {
        var safe = text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        safe = safe.replacingOccurrences(of: "(?im)^(Authorization|Proxy-Authorization|WWW-Authenticate|Proxy-Authenticate):[^\\r\\n]*(?:\\r?\\n[ \\t]+[^\\r\\n]*)*", with: "$1: [redacted]", options: .regularExpression)
        safe = safe.replacingOccurrences(of: "(?im)^(a=(?:ice-pwd|crypto|key-mgmt):)[^\\r\\n]*", with: "$1[redacted]", options: .regularExpression)
        safe = safe.replacingOccurrences(of: "(?i)(auth_pass|password)[ \\t]*=[^;\\r\\n]*", with: "$1=[redacted]", options: .regularExpression)
        if safe.range(of: "(?i)uapassword", options: .regularExpression) != nil { return "Credential control message [redacted]" }
        return safe
    }
    static func header(_ name: String, in message: String) -> String? {
        let headerBlock = message.components(separatedBy: "\r\n\r\n")[0].components(separatedBy: "\n\n")[0]
        for line in headerBlock.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == name.lowercased() {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
    static func deviceExplanation(_ reason: String) -> String? {
        guard reason.contains("[19]") else { return nil }
        return "The local audio device could not open or start. Check microphone permission and the Mac's selected microphone/speaker. The Engine log shows the AudioQueue operation and OSStatus when available."
    }
    mutating func add(category: String, summary: String, detail: String, callID: String? = nil) {
        entries.append(DebugEntry(category: category, summary: Self.redact(summary), detail: Self.redact(String(detail.prefix(65536))), callID: callID))
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
    }
    private mutating func ensureCall(_ id: String) -> Int {
        if let index = calls.firstIndex(where: { $0.id == id }) { return index }
        calls.append(CallDebug(id: id))
        if calls.count > 50 { calls.removeFirst() }
        return calls.count - 1
    }
    mutating func packet(_ event: [String: Any]) {
        guard let raw = event["message"] as? String else { return }
        let message = Self.redact(String(raw.prefix(65536)))
        let firstLine = message.components(separatedBy: .newlines).first ?? "SIP message"
        let id = Self.header("Call-ID", in: message) ?? Self.header("i", in: message)
        let direction = event["direction"] as? String ?? ""
        let transport = event["transport"] as? String ?? ""
        let source = event["source"] as? String ?? ""
        let destination = event["destination"] as? String ?? ""
        add(category: "SIP", summary: "\(direction.uppercased()) · \(transport) · \(firstLine)", detail: "\(source) → \(destination)\n\n\(message)", callID: id)
        if firstLine.hasPrefix("INVITE "), let id {
            let index = ensureCall(id)
            if calls[index].firstInvite.isEmpty { calls[index].firstInvite = message }
        }
    }
    mutating func event(_ event: [String: Any]) {
        let type = event["type"] as? String ?? "Event"
        let id = event["id"] as? String
        let param = event["param"] as? String ?? ""
        let detail = event.keys.sorted().filter { $0 != "event" }.map { "\($0): \(event[$0]!)" }.joined(separator: "\n")
        add(category: "Events", summary: type + (param.isEmpty ? "" : " · \(param)"), detail: detail, callID: id)
        guard let id, type.hasPrefix("CALL_") || type.contains("TRANSFER") else { return }
        let index = ensureCall(id)
        calls[index].account = event["accountaor"] as? String ?? calls[index].account
        calls[index].peer = event["peeruri"] as? String ?? calls[index].peer
        calls[index].state = type
        if type == "CALL_CLOSED" {
            calls[index].failure = param
            if let explanation = Self.deviceExplanation(param) {
                add(category: "Engine", summary: "Local audio device error [19]", detail: explanation, callID: id)
            }
        }
    }
    func export(callID: String? = nil) -> String {
        var text = "Baresip Mac diagnostics\nExported: \(Date().ISO8601Format())\nAuthentication headers hidden. Addresses and custom headers remain visible.\n\n"
        for call in calls where callID == nil || call.id == callID {
            text += "CALL-ID: \(call.id)\nAccount: \(call.account)\nPeer: \(call.peer)\nState: \(call.state)\nEnd reason: \(call.failure)\nFIRST INVITE:\n\(call.firstInvite)\n\n"
        }
        for entry in entries where callID == nil || entry.callID == callID || entry.category == "Engine" || entry.category == "Snapshot" {
            text += "[\(entry.timestamp.ISO8601Format())] \(entry.category) · \(entry.summary)\nCall-ID: \(entry.callID ?? "—")\n\(entry.detail)\n\n"
        }
        return Self.redact(text)
    }
}
struct EngineOutputLines {
    private var buffer = Data()
    mutating func feed(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let end = buffer.firstIndex(of: 10) {
            lines.append(DebugJournal.redact(String(decoding: buffer.prefix(end), as: UTF8.self)))
            buffer.removeSubrange(...end)
            buffer = Data(buffer)
        }
        if buffer.count > 65536 { lines.append("Engine output line exceeded 64 KB and was dropped."); buffer.removeAll() }
        return lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
