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
        print("PASS: 6 protocol, credential and connection-state tests")
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
