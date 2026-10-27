import Foundation
import AVFoundation
@main struct EngineIntegration {
    @MainActor static func main() async {
        do { try await verify() }
        catch { print("FAIL: \(error.localizedDescription)"); exit(EXIT_FAILURE) }
    }
    static func require(_ condition: Bool, _ message: String = "App integration assertion failed") throws {
        guard condition else { throw AppError.message(message) }
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
        try require(audio.contains("Microphone permission:") && audio.contains("Input:") && audio.contains("Output:"))
        let catalog = AudioDiagnostics.catalog()
        print("Audio inventory: \(catalog.inputs.count) inputs, \(catalog.outputs.count) outputs")
        let engine = Engine()
        defer { engine.stop() }
        let a = SIPAccount(username: "alice", domain: "127.0.0.1", transport: "UDP", register: false)
        let b = SIPAccount(username: "bob", domain: "127.0.0.1", transport: "UDP", register: false)
        try await engine.start(accounts: [a, b])
        let info = try await engine.command("reginfo")
        try require(info.contains(a.aor) && info.contains(b.aor), "Both accounts must be loaded")
        _ = try await engine.command("uafind", b.aor)
        _ = try await engine.command("uaaddheader", "X-Test=hello%20world 0")
        _ = try await engine.command("uarmheader", "X-Test 0")
        print("PASS: bundled engine launch, two accounts, command responses, custom headers and macOS audio diagnostics")
        engine.stop()
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("missing-microphone-\(UUID().uuidString)/accounts.json")
        guard let port = ProcessInfo.processInfo.environment["BARESIP_TEST_SIP_PORT"], let output = catalog.outputs.first else {
            throw AppError.message("Local SIP fixture and speaker are required for the app media test")
        }
        let noMic = AudioDeviceCatalog(devices: [output], defaultOutputUID: output.uid)
        let store = Store(storageURL: storage, engine: Engine(loopbackOnly: true), audioCatalog: { noMic })
        defer {
            if store.error != nil || !store.calls.isEmpty {
                print("App state: \(store.status), error: \(store.error ?? "none"), calls: \(store.calls)")
                print(store.diagnostics.export())
            }
            store.disconnect(); store.removeTemporaryAudio()
        }
        let local = SIPAccount(username: "no-mic", domain: "127.0.0.1:\(port)", transport: "UDP", register: false, codecs: [Codec(name: "PCMA/8000/1")])
        store.accounts = [local]; store.selectedAccount = local.id
        store.inputDeviceUID = "default"; store.outputDeviceUID = output.uid
        store.destination = "sip:local-peer@127.0.0.1:\(port)"
        store.connect()
        try await idle(store)
        try require(store.connected && store.error == nil, store.error ?? "Store did not connect")
        for attempt in 0..<3 {
            store.error = nil
            store.dial()
            try await idle(store)
            try await waitFor("listen-only call established") { store.call?.connected == true }
            try require(store.error == nil && store.connected && !store.busy, store.error ?? "Call failed")
            try require(store.call?.audioInput.contains("Listen only") == true)
            if attempt == 0 {
                let source = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-input-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: source) }
                try makeFile(source)
                store.importAudioFile(source, callID: store.call!.id)
                try await idle(store)
                if let error = store.error { throw AppError.message("File preparation: \(error)") }
                try await waitFor("file finished") { store.call?.audioInput == "Audio file finished" }
                try require(store.call?.connected == true && store.connected)
                store.stopSendingAudio()
                try await idle(store)
                try require(store.error == nil, store.error ?? "Listen-only transition failed")
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            store.control("hangup")
            try await idle(store)
            try await waitFor("call closed") { store.calls.isEmpty }
            store.inputMode = .automatic
        }
        store.captureSnapshot()
        try await idle(store)
        try require(store.diagnostics.entries.contains { $0.summary == "reginfo" && $0.detail.contains(local.aor) })
        store.disconnect()
        store.connect()
        try await idle(store)
        try require(store.connected && store.error == nil)
        store.disconnect()
        print("PASS: app places three listen-only calls without a microphone, converts and sends a file during a call, survives EOF, stops sending, retains diagnostics and reconnects")
    }
    @MainActor static func waitFor(_ label: String, _ check: () -> Bool) async throws {
        for _ in 0..<800 {
            if check() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AppError.message("App media state timed out: \(label)")
    }
    static func makeFile(_ url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22050)!
        buffer.frameLength = 22050
        for i in 0..<22050 { buffer.int16ChannelData![0][i] = i % 100 < 50 ? 512 : -512 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: buffer)
    }
}
