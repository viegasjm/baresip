import Foundation
import AVFoundation
@main struct EngineIntegration {
    @MainActor static func main() async {
        setbuf(stdout, nil)
        do {
            if ProcessInfo.processInfo.environment["BARESIP_LIVE_SELF_CALL"] == "1" {
                let input = FileHandle.standardInput.readDataToEndOfFile()
                let credentials = try JSONDecoder().decode([LiveCredential].self, from: input)
                try require(credentials.count == 2, "Two isolated credentials are required")
                try await verifySelfCall("", live: credentials)
            }
            else if let port = ProcessInfo.processInfo.environment["BARESIP_SELF_CALL_PORT"] { try await verifySelfCall(port) }
            else { try await verify() }
        }
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
    @MainActor static func verifyRegistrationControls(port: String) async throws {
        let a = SIPAccount(username: "registration-a", domain: "127.0.0.1:\(port)", authUser: "registration-a", transport: "UDP")
        let b = SIPAccount(username: "registration-b", domain: "127.0.0.1:\(port)", authUser: "registration-b", transport: "UDP")
        let password = ProcessInfo.processInfo.environment["BARESIP_TEST_PASSWORD"]!
        let engine = Engine(loopbackOnly: true, passwordOverrides: [a.id: password, b.id: password])
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("registration-\(UUID().uuidString)/accounts.json")
        let store = Store(storageURL: storage, engine: engine)
        defer { store.disconnect() }
        store.accounts = [a, b]; store.selectedAccount = a.id
        store.registrationAction(a)
        try await idle(store)
        try await waitFor("only A registered") { store.connection(for: a).canDial }
        try require(store.connection(for: b).phase == .offline, "Connecting A must leave B offline")
        try require(store.diagnostics.registrationEntries(account: b.aor).isEmpty, "Offline account unexpectedly sent REGISTER")
        store.registrationAction(b)
        try await idle(store)
        try await waitFor("B registered independently") { store.connection(for: b).canDial }
        let aRequests = store.diagnostics.registrationEntries(account: a.aor).filter { $0.category == "SIP" && $0.summary.contains("SENT") }.count
        store.registrationAction(b, disconnect: true)
        try await idle(store)
        try require(store.connection(for: a).canDial && store.connection(for: b).phase == .offline)
        store.registrationAction(b)
        try await idle(store)
        try await waitFor("B re-registered") { store.connection(for: b).canDial }
        try require(store.diagnostics.registrationEntries(account: a.aor).filter { $0.category == "SIP" && $0.summary.contains("SENT") }.count == aRequests, "Retrying B must not restart A")
        print("PASS: both explicit-auth-user accounts loaded; independent connect, unregister and retry with digest-auth REGISTER traces")
    }
    @MainActor static func verify() async throws {
        try await verifyRegistrationControls(port: ProcessInfo.processInfo.environment["BARESIP_TEST_SIP_PORT"]!)
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
        let permissionBefore = AVCaptureDevice.authorizationStatus(for: .audio)
        let keypad = KeypadAudio()
        try keypad.play("5", outputUID: output.uid)
        try require(keypad.isPlaying && keypad.outputUID == output.uid, "Local keypad sound did not start on the selected speaker")
        try await Task.sleep(nanoseconds: 60_000_000)
        try require(keypad.playbackTime > 0.02, "Local keypad playback did not advance")
        keypad.stop()
        try require(!keypad.isPlaying && AVCaptureDevice.authorizationStatus(for: .audio) == permissionBefore)
        print("PASS: local keypad audio renders through the selected speaker without requesting a microphone")
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
            // Verify the same state that controls the Hold / Resume button.
            for _ in 0..<2 {
                store.control("hold")
                try await idle(store)
                try require(store.error == nil && store.call?.held == true, store.error ?? "Hold button did not become Resume")
                try await waitFor("hold SDP answer") {
                    store.diagnostics.entries.contains { $0.summary.contains("CALL_REMOTE_SDP") && $0.callID == store.call?.sipID && ($0.detail.contains("local_hold: true") || $0.detail.contains("local_hold: 1")) }
                }
                try await Task.sleep(nanoseconds: 150_000_000)
                store.control("resume")
                try await idle(store)
                try require(store.error == nil && store.call?.held == false, store.error ?? "Resume button did not become Hold")
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            if attempt == 0 {
                let previousKeypadSounds = store.keypadSounds
                defer { store.keypadSounds = previousKeypadSounds }
                store.keypadSounds = true
                store.outputDeviceUID = "missing-keypad-speaker"
                store.sendDTMF("1"); try await idle(store)
                try require(store.keypadSoundIssue != nil && store.error == nil, "Unavailable local speaker must not block remote DTMF")
                store.outputDeviceUID = output.uid
                store.sendDTMF("2"); try await idle(store)
                try require(store.keypadSoundIssue == nil, store.keypadSoundIssue ?? "Local keypad sound failed")
                store.keypadSounds = false
                store.sendDTMF("#"); try await idle(store)
                try require(store.call?.audioInput.contains("Listen only") == true, "Keypad feedback changed the call's audio source")
                try await waitFor("DTMF INFO captured") { store.diagnostics.entries.filter { $0.summary.contains("INFO ") }.count >= 3 }

                let source = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-input-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: source) }
                try makeFile(source, frames: 88200)
                store.importAudioFile(source, callID: store.call!.id)
                try await idle(store)
                if let error = store.error { throw AppError.message("File preparation: \(error)") }
                store.sendDTMF("5"); try await idle(store)
                try await waitFor("file finished") { store.call?.audioInput == "Audio file finished" }
                try require(store.call?.connected == true && store.connected)
                store.stopSendingAudio()
                try await idle(store)
                try require(store.error == nil, store.error ?? "Listen-only transition failed")
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if attempt == 2 {
                let firstID = store.call!.id
                store.dial()
                try await idle(store)
                try await waitFor("second call established and first auto-held") {
                    store.calls.count == 2 && store.call?.id != firstID && store.call?.connected == true && store.calls.first { $0.id == firstID }?.held == true
                }
                let secondID = store.call!.id
                store.selectedCall = firstID
                store.control("resume")
                try await idle(store)
                try await waitFor("selected call resumed and other call auto-held") {
                    store.calls.first { $0.id == firstID }?.held == false && store.calls.first { $0.id == secondID }?.held == true
                }
                store.selectedCall = secondID
                store.control("hangup")
                try await idle(store)
                try await waitFor("second call closed") { store.calls.count == 1 }
                store.selectedCall = firstID
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
        print("PASS: app places listen-only calls without a microphone, converts and sends a file during a call, survives EOF, stops sending, toggles Hold/Resume repeatedly and synchronizes auto-hold across two calls, retains diagnostics and reconnects")
    }
    @MainActor static func waitFor(_ label: String, attempts: Int = 4000, _ check: () -> Bool) async throws {
        for _ in 0..<attempts {
            if check() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AppError.message("App media state timed out: \(label)")
    }
    struct LiveCredential: Decodable { let username: String; let password: String; let domain: String; let phoneNumber: String?; let callerID: String? }
    @MainActor static func verifySelfCall(_ port: String, live: [LiveCredential]? = nil) async throws {
        let catalog = AudioDiagnostics.catalog()
        guard let output = catalog.outputs.first else { throw AppError.message("A speaker is required for the self-call audio test") }
        let noMic = AudioDeviceCatalog(devices: [output], defaultOutputUID: output.uid)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("self-call-\(UUID().uuidString)/accounts.json")
        let codecName = ProcessInfo.processInfo.environment["BARESIP_SELF_CODEC"] ?? "PCMA"
        let codec = ["PCMA": "PCMA/8000/1", "PCMU": "PCMU/8000/1", "G722": "G722/16000/1", "opus": "opus/48000/2"][codecName]!
        var alice = SIPAccount(username: live?[0].username ?? "alice", domain: live?[0].domain ?? "127.0.0.1:\(port)", transport: live == nil ? "UDP" : "TLS", codecs: [Codec(name: codec)])
        var bob = SIPAccount(username: live?[1].username ?? "bob", domain: live?[1].domain ?? "127.0.0.1:\(port)", transport: live == nil ? "UDP" : "TLS", codecs: [Codec(name: codec)])
        let localNumber = ProcessInfo.processInfo.environment["BARESIP_SELF_CALL_NUMBER"]
        bob.phoneNumbers = live?[1].phoneNumber ?? localNumber.map { "+12025550124, \($0)" }
        // Telnyx must identify A before applying B's account-only URI policy.
        // Digest authentication still follows the provider's challenge.
        if live != nil {
            alice.headers = [SIPHeader(name: "X-Telnyx-Username", value: alice.username)]
            if let callerID = live?[0].callerID { alice.headers.append(SIPHeader(name: "P-Asserted-Identity", value: "<sip:\(callerID)@\(alice.domain)>")) }
        }
        let passwords = live.map { [alice.id: $0[0].password, bob.id: $0[1].password] } ?? [:]
        let engine = Engine(loopbackOnly: live == nil, passwordOverrides: passwords)
        let store = Store(storageURL: path, engine: engine, audioCatalog: { noMic })
        defer {
            if live == nil && (store.error != nil || !store.calls.isEmpty) { print(store.diagnostics.export()) }
            if live != nil {
                print("Live final state: registrations=\(store.registrations.values.sorted()), calls=\(store.calls.map { $0.state })")
                for entry in store.diagnostics.entries where entry.category == "SIP" || entry.category == "Events" {
                    print(entry.summary)
                    if entry.category == "SIP" && entry.summary.contains("403") { print(entry.detail) }
                }
            }
            store.disconnect(); store.removeTemporaryAudio()
        }
        store.accounts = [alice, bob]; store.selectedAccount = alice.id
        store.inputDeviceUID = "default"; store.outputDeviceUID = output.uid
        store.connect(); try await idle(store)
        try await waitFor("both self-call accounts registered", attempts: live == nil ? 4000 : 18000) { store.registrations.values.filter { $0 == "Registered" }.count == 2 }
        if live != nil { print("Live: both isolated accounts registered") }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("self-call-silence-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: source) }
        try makeFile(source, silence: live == nil, frames: live == nil ? 88200 : 264600)
        let preselected = ProcessInfo.processInfo.environment["BARESIP_SELF_PRESELECT_FILE"] == "1"
        if preselected { store.importAudioFile(source); try await idle(store) }
        store.destination = live?[1].phoneNumber ?? localNumber ?? bob.aor
        if live != nil {
            for attempt in 0..<4 {
                let ended = store.diagnostics.entries.filter { $0.category == "Events" && $0.summary.hasPrefix("CALL_CLOSED") }.count
                store.selectedAccount = alice.id; store.dial(); try await idle(store)
                for _ in 0..<2000 {
                    if store.calls.count == 2 && store.calls.contains(where: { $0.incoming }) { break }
                    if store.diagnostics.entries.filter({ $0.category == "Events" && $0.summary.hasPrefix("CALL_CLOSED") }).count > ended { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                if store.calls.count == 2 { break }
                if let call = store.calls.first { store.selectedCall = call.id; store.control("hangup"); try await idle(store) }
                if attempt < 3 { print("Live: retrying number call after routing rejection"); try await Task.sleep(nanoseconds: 15_000_000_000) }
            }
        }
        else { store.dial(); try await idle(store) }
        try await waitFor("two distinct local call legs") { store.calls.count == 2 && store.calls.contains { $0.incoming && $0.state == "Incoming" } }
        let outgoing = store.calls.first { !$0.incoming }!
        let incoming = store.calls.first { $0.incoming }!
        try require(outgoing.id != incoming.id, "Call legs were merged")
        let rewritten = ProcessInfo.processInfo.environment["BARESIP_SELF_CALL_REWRITE"] == "1"
        if live == nil { try require((outgoing.sipID != incoming.sipID) == rewritten, "Proxy Call-ID behavior differs") }
        else { print("Live: distinct local legs; SIP Call-IDs \(outgoing.sipID), \(incoming.sipID)") }
        try require(incoming.localPeerID == outgoing.id && outgoing.localPeerID == incoming.id, "Local peers were not paired")
        store.selectedCall = incoming.id; store.control("accept"); try await idle(store)
        try await waitFor("both local call legs established") { store.calls.count == 2 && store.calls.allSatisfy { $0.connected } }
        try await Task.sleep(nanoseconds: 300_000_000)
        try require(store.calls.allSatisfy { !$0.held }, "Self-call legs held each other")
        try require(store.calls.first { $0.id == incoming.id }?.audioInput == CallAudioInput.listen.title, "Local receiver did not default to listen-only")
        var beforeReceived = 0
        if live != nil {
            _ = try await engine.command("uafind", bob.aor)
            _ = try await engine.command("callfind", incoming.id)
            beforeReceived = try rtpPackets(try await engine.command("audio_debug"), direction: "rx")
        }
        if !preselected { store.importAudioFile(source, callID: outgoing.id); try await idle(store) }
        if let error = store.error { throw AppError.message(error) }
        if live == nil {
            try await waitFor("file RTP received by the other local account") {
                store.diagnostics.entries.contains { $0.category == "Events" && $0.summary.contains("CALL_RTPESTAB") && $0.detail.contains(incoming.id) }
            }
        }
        try await waitFor("self-call file finished") { store.calls.first { $0.id == outgoing.id }?.audioInput == "Audio file finished" }
        if live != nil {
            try await Task.sleep(nanoseconds: 300_000_000)
            _ = try await engine.command("uafind", bob.aor)
            _ = try await engine.command("callfind", incoming.id)
            let receiverSnapshot = try await engine.command("audio_debug")
            let received = try rtpPackets(receiverSnapshot, direction: "rx")
            _ = try await engine.command("uafind", alice.aor)
            _ = try await engine.command("callfind", outgoing.id)
            let senderSnapshot = try await engine.command("audio_debug")
            let sent = try rtpPackets(senderSnapshot, direction: "tx")
            let sendErrors = try rtpValue(senderSnapshot, pattern: "RTP errors: tx=([0-9]+)", group: 1)
            print("Live file media: A attempted \(sent) RTP packets (\(sendErrors) send errors); B received \(received - beforeReceived) additional RTP packets")
            if sent <= 40 || received - beforeReceived < sent * 4 / 5 || sendErrors != 0 {
                print("A media snapshot:\n\(senderSnapshot)\nB media snapshot:\n\(receiverSnapshot)")
                for entry in store.diagnostics.entries where entry.category == "SIP" && entry.detail.contains("m=audio") {
                    print(entry.summary + "\n" + (entry.detail.components(separatedBy: "\r\n\r\n").last ?? ""))
                }
            }
            try require(sent > 40 && received - beforeReceived >= sent * 4 / 5 && sendErrors == 0, "File audio delivery or sender errors did not meet the test threshold")
        }
        try require(store.calls.count == 2 && store.calls.allSatisfy { $0.connected && !$0.held }, "File playback closed or held a leg")
        store.selectedCall = incoming.id; store.captureSnapshot(); try await idle(store)
        try require(store.diagnostics.entries.contains { $0.summary == "Negotiated audio and RTP" && $0.callID == incoming.sipID && $0.detail.contains(codecName) })
        store.selectedCall = outgoing.id; store.control("hold"); try await idle(store)
        try await Task.sleep(nanoseconds: 200_000_000)
        try require(store.calls.first { $0.id == outgoing.id }?.held == true)
        try require(store.calls.first { $0.id == incoming.id }?.held == false, "Holding one leg changed the other's local hold state")
        store.control("resume"); try await idle(store)
        try await Task.sleep(nanoseconds: 200_000_000)
        try require(store.calls.allSatisfy { !$0.held }, "Resuming one self-call leg held its peer")
        store.selectedCall = localNumber == nil ? incoming.id : outgoing.id; store.control("hangup"); try await idle(store)
        try await waitFor("both self-call legs ended normally") { store.calls.isEmpty }
        try require(store.connected && store.error == nil, store.error ?? "App disconnected")
        print("PASS: native app \(codecName) self-call; two registered accounts and distinct local legs; \(live == nil ? (rewritten ? "rewritten" : "shared") : "provider") SIP Call-ID; no mutual auto-hold; \(preselected ? "preselected" : "live") file received by second account; selected-leg hold/resume and hangup")
    }
    static func makeFile(_ url: URL, silence: Bool = false, frames: AVAudioFrameCount = 22050) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: true)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.int16ChannelData![0][i] = silence ? 0 : (i % 100 < 50 ? 512 : -512) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: buffer)
    }
    static func rtpPackets(_ snapshot: String, direction: String) throws -> Int {
        try rtpValue(snapshot, pattern: "RTP packets: tx_attempted=([0-9]+) rx=([0-9]+)", group: direction == "tx" ? 1 : 2)
    }
    static func rtpValue(_ snapshot: String, pattern: String, group: Int) throws -> Int {
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: snapshot, range: NSRange(snapshot.startIndex..., in: snapshot)),
              let range = Range(match.range(at: group), in: snapshot), let value = Int(snapshot[range]) else {
            throw AppError.message("RTP counters missing from engine snapshot")
        }
        return value
    }
}
