import Foundation
@main struct EngineIntegration {
    @MainActor static func main() async throws {
        let engine = Engine()
        defer { engine.stop() }
        let a = SIPAccount(username: "alice", domain: "127.0.0.1", transport: "UDP", register: false)
        let b = SIPAccount(username: "bob", domain: "127.0.0.1", transport: "UDP", register: false)
        try await engine.start(accounts: [a, b])
        let info = try await engine.command("reginfo")
        precondition(info.contains(a.aor) && info.contains(b.aor), "Both accounts must be loaded")
        _ = try await engine.command("uafind", b.aor)
        _ = try await engine.command("uaaddheader", "X-Test=hello%20world 0")
        _ = try await engine.command("uarmheader", "X-Test 0")
        print("PASS: bundled engine launch, two accounts, command responses and custom headers")
    }
}
