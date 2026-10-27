import Foundation

func XCTAssertTrue(_ value: Bool) { precondition(value) }
func XCTAssertFalse(_ value: Bool) { precondition(!value) }
func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) { precondition(lhs == rhs, "Values differ: \(lhs), \(rhs)") }
func XCTAssertThrowsError<T>(_ value: @autoclosure () throws -> T) {
    do { _ = try value() } catch { return }
    preconditionFailure("Expected an error")
}
@main struct ProtocolTests {
    static func main() throws {
        let suite = ProtocolTests()
        try suite.testFragmentedAndConcatenatedNetstrings()
        suite.testRejectsInvalidFramingAndOversizedMessages()
        try suite.testHeadersCannotInjectAdditionalSIPMessages()
        try suite.testCodecOrderAndPasswordIsolation()
        suite.testConnectionStatusReflectsSelectedAccount()
        suite.testAccountCannotInjectConfiguration()
        suite.testFirstInviteAndAuthenticationRedaction()
        suite.testDebugHistoryAndRetention()
        suite.testFragmentedEngineOutput()
        try suite.testAudioDeviceRouting()
        print("PASS: 10 protocol, credential, connection-state, debug and device-routing tests")
    }
    func testAudioDeviceRouting() throws {
        let micA = AudioDeviceInfo(uid: "mic-a", name: "Headset", inputChannels: 1, outputChannels: 0, sampleRate: 48000)
        let micB = AudioDeviceInfo(uid: "mic-b", name: "Headset", inputChannels: 2, outputChannels: 0, sampleRate: 48000)
        let speaker = AudioDeviceInfo(uid: "speaker", name: "Speakers", inputChannels: 0, outputChannels: 2, sampleRate: 48000)
        let catalog = AudioDeviceCatalog(devices: [micA, micB, speaker], defaultInputUID: "mic-a", defaultOutputUID: "speaker")
        XCTAssertEqual(catalog.resolve("default", input: true)?.uid, "mic-a")
        XCTAssertEqual(catalog.resolve("mic-b", input: true)?.uid, "mic-b")
        try AudioRouting(inputUID: "mic-b", outputUID: "speaker").validateForCall(in: catalog)
        let unplugged = AudioDeviceCatalog(devices: [micA, speaker], defaultInputUID: "mic-a", defaultOutputUID: "speaker")
        XCTAssertThrowsError(try AudioRouting(inputUID: "mic-b", outputUID: "speaker").validateForCall(in: unplugged))
        XCTAssertThrowsError(try AudioRouting(inputUID: "speaker", outputUID: "speaker").validateForCall(in: catalog))
        XCTAssertThrowsError(try AudioRouting().validateForCall(in: AudioDeviceCatalog(devices: [speaker], defaultOutputUID: "speaker")))
        XCTAssertThrowsError(try AudioRouting(inputUID: "device\nmodule injected").validate())
        XCTAssertThrowsError(try AudioRouting(inputUID: String(repeating: "a", count: 128)).validate())
    }
    func testFirstInviteAndAuthenticationRedaction() {
        var journal = DebugJournal()
        let first = "INVITE sip:bob@example.com SIP/2.0\r\nCall-ID: test-call\r\nX-Trace: retained\r\nAuthorization: Digest secret-value\r\n folded-secret\r\nContent-Length: 0\r\n\r\n"
        journal.packet(["message": first, "direction": "sent", "transport": "TLS", "source": "127.0.0.1:1", "destination": "127.0.0.1:2"])
        journal.packet(["message": first.replacingOccurrences(of: "X-Trace: retained", with: "X-Trace: second"), "direction": "sent"])
        XCTAssertEqual(journal.calls.count, 1)
        XCTAssertTrue(journal.calls[0].firstInvite.contains("X-Trace: retained"))
        let export = journal.export()
        XCTAssertFalse(export.contains("secret-value"))
        XCTAssertFalse(export.contains("folded-secret"))
        XCTAssertTrue(export.contains("Authorization: [redacted]"))
        XCTAssertTrue(export.contains("TLS"))
        let sdp = DebugJournal.redact("a=ice-pwd:private-ice\r\na=crypto:1 AES_CM_128_HMAC_SHA1_80 inline:private-key")
        XCTAssertFalse(sdp.contains("private-ice"))
        XCTAssertFalse(sdp.contains("private-key"))
        XCTAssertEqual(DebugJournal.header("Call-ID", in: first), "test-call")
        XCTAssertTrue(DebugJournal.redact("Proxy-Authorization: private\r\nWWW-Authenticate: nonce=private").contains("[redacted]"))
        XCTAssertFalse(DebugJournal.redact("uapassword value=secret 0").contains("value=secret"))
    }
    func testDebugHistoryAndRetention() {
        var journal = DebugJournal()
        journal.event(["type": "CALL_OUTGOING", "id": "ended-call", "peeruri": "sip:bob@example.com"])
        journal.event(["type": "CALL_CLOSED", "id": "ended-call", "param": "Operation not supported by device [19]"])
        XCTAssertEqual(journal.calls[0].failure, "Operation not supported by device [19]")
        XCTAssertTrue(journal.export(callID: "ended-call").contains("local audio device"))
        XCTAssertTrue(DebugJournal.deviceExplanation("Device error [19]") != nil)
        XCTAssertTrue(DebugJournal.deviceExplanation("486 Busy Here") == nil)
        for index in 0..<600 { journal.add(category: "Engine", summary: "line \(index)", detail: "diagnostic") }
        XCTAssertEqual(journal.entries.count, 500)
        XCTAssertTrue(journal.calls.contains { $0.id == "ended-call" })
    }
    func testFragmentedEngineOutput() {
        var output = EngineOutputLines()
        let line = Data("coreaudio: café\nAuthorization: secret\n".utf8)
        let split = line.firstIndex(of: 0xC3)! + 1
        XCTAssertTrue(output.feed(line.prefix(split)).isEmpty)
        let lines = output.feed(line.dropFirst(split))
        XCTAssertEqual(lines[0], "coreaudio: café")
        XCTAssertEqual(lines[1], "Authorization: [redacted]")
        XCTAssertEqual(output.feed(Data(repeating: 65, count: 70000)).count, 1)
    }
    func testFragmentedAndConcatenatedNetstrings() throws {
        let first = try Netstrings.encode(["command": "dial", "params": "sip:joão@example.com"])
        let second = try Netstrings.encode(["command": "hold"])
        var parser = Netstrings()
        XCTAssertTrue(try parser.feed(first.prefix(5)).isEmpty)
        let objects = try parser.feed(first.dropFirst(5) + second)
        XCTAssertEqual(objects.count, 2)
        XCTAssertEqual(objects[0]["params"] as? String, "sip:joão@example.com")
        XCTAssertEqual(objects[1]["command"] as? String, "hold")
        XCTAssertTrue(parser.buffer.isEmpty)
    }
    func testRejectsInvalidFramingAndOversizedMessages() {
        for packet in ["2:{};", "9999999:", "x:{} ,", "1:1,"] {
            var parser = Netstrings()
            XCTAssertThrowsError(try parser.feed(Data(packet.utf8)))
        }
    }
    func testHeadersCannotInjectAdditionalSIPMessages() throws {
        var header = SIPHeader(name: "X-Trace", value: "one\r\nVia: injected")
        XCTAssertThrowsError(try header.validate())
        header.value = "a value with spaces & punctuation=✓"
        try header.validate()
        XCTAssertFalse(header.commandPair.contains(" "))
        XCTAssertTrue(header.commandPair.contains("%20"))
        header.name = "Bad:Name"
        XCTAssertThrowsError(try header.validate())
    }
    func testCodecOrderAndPasswordIsolation() throws {
        var account = SIPAccount(username: "alice", domain: "example.com")
        account.codecs = [Codec(name: "PCMA/8000/1"), Codec(name: "opus/48000/2"), Codec(name: "PCMU/8000/1", enabled: false)]
        let line = try account.configuration(startRegistration: false)
        XCTAssertFalse(line.contains("auth_pass"))
        XCTAssertTrue(line.contains("regint=0"))
        let password = "pass;word with spaces\"\\%&=+"
        let encoded = try Passwords.commandValue(password)
        XCTAssertEqual(String(encoded.dropFirst(6)).removingPercentEncoding, password)
        XCTAssertFalse(encoded.contains(" "))
        XCTAssertEqual(try Passwords.commandValue(""), "value=")
        XCTAssertTrue(line.contains("audio_codecs=PCMA/8000/1,opus/48000/2"))
        XCTAssertFalse(line.contains("PCMU"))
        account.codecs = account.codecs.map { Codec(name: $0.name, enabled: false) }
        XCTAssertThrowsError(try account.configuration())
    }
    func testConnectionStatusReflectsSelectedAccount() {
        let account = SIPAccount(username: "alice", domain: "example.com")
        let failed = AccountConnection(engineConnected: true, starting: false, account: account, registration: "Registration failed")
        XCTAssertEqual(failed.title, "Registration failed")
        XCTAssertFalse(failed.canDial)
        let registered = AccountConnection(engineConnected: true, starting: false, account: account, registration: "Registered")
        XCTAssertEqual(registered.title, "Registered")
        XCTAssertTrue(registered.canDial)
        XCTAssertFalse(AccountConnection(engineConnected: true, starting: false, account: account, registration: nil).canDial)
        XCTAssertFalse(AccountConnection(engineConnected: false, starting: false, account: account, registration: "Registered").canDial)
        var direct = account
        direct.register = false
        XCTAssertTrue(AccountConnection(engineConnected: true, starting: false, account: direct, registration: nil).canDial)
    }
    func testAccountCannotInjectConfiguration() {
        var account = SIPAccount(username: "alice", domain: "example.com\nmodule evil")
        XCTAssertThrowsError(try account.configuration())
        account.domain = "example.com"
        XCTAssertThrowsError(try Passwords.commandValue(String(repeating: " ", count: 400)))
    }
}
