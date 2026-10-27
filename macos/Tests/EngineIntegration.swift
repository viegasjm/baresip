import Foundation
@main struct EngineIntegration {
    @MainActor static func main() async {
        do { try await verify() }
        catch { print("FAIL: \(error.localizedDescription)"); exit(EXIT_FAILURE) }
    }
    @MainActor static func idle(_ store: Store) async throws {
        for _ in 0..<1000 {
            if !store.busy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AppError.message("App operation did not finish")
    }
    @MainActor static func verify() async throws {
        let audio = AudioDiagnostics.snapshot()
        precondition(audio.contains("Microphone permission:") && audio.contains("Input:") && audio.contains("Output:"))
        let catalog = AudioDiagnostics.catalog()
        if catalog.inputs.isEmpty {
            do { try AudioRouting().validateForCall(in: catalog); preconditionFailure("Missing microphone must be rejected") }
            catch { precondition(error.localizedDescription.contains("microphone")) }
        }
        print("Audio inventory: \(catalog.inputs.count) inputs, \(catalog.outputs.count) outputs")
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
        print("PASS: bundled engine launch, two accounts, command responses, custom headers and macOS audio diagnostics")
        engine.stop()
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("missing-microphone-\(UUID().uuidString)/accounts.json")
        let store = Store(storageURL: storage, audioCatalog: { AudioDeviceCatalog() })
        store.accounts = [a]; store.selectedAccount = a.id
        store.inputDeviceUID = "default"; store.outputDeviceUID = "default"
        store.destination = "sip:unused@127.0.0.1:9"
        store.connect()
        try await idle(store)
        precondition(store.connected && store.error == nil, store.error ?? "Store did not connect")
        for _ in 0..<3 {
            store.error = nil
            store.dial()
            try await idle(store)
            precondition(store.error?.contains("No microphone") == true)
            precondition(store.connected && store.calls.isEmpty && !store.busy)
        }
        precondition(!store.diagnostics.entries.contains { $0.summary.contains("CALL_OUTGOING") })
        store.error = nil
        store.captureSnapshot()
        try await idle(store)
        precondition(store.diagnostics.entries.contains { $0.summary == "reginfo" && $0.detail.contains(a.aor) })
        store.disconnect()
        store.connect()
        try await idle(store)
        precondition(store.connected && store.error == nil)
        store.disconnect()
        print("PASS: app call controls reject missing microphone repeatedly, preserve engine/account connection, release busy state, capture diagnostics and reconnect without crashing")
    }
}
