import SwiftUI
import AppKit

/// UI-only fixture: no engine resources, real credentials or user account storage.
@MainActor final class LayoutPreviewDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
}
@main struct LayoutPreview: App {
    @NSApplicationDelegateAdaptor(LayoutPreviewDelegate.self) var delegate
    @StateObject private var store = Self.makeStore()
    @MainActor private static func makeStore() -> Store {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent("BaresipLayout-\(UUID().uuidString)/accounts.json")
        let devices = AudioDiagnostics.catalog()
        let outputsOnly = AudioDeviceCatalog(devices: devices.outputs.map {
            AudioDeviceInfo(uid: $0.uid, name: $0.name, inputChannels: 0, outputChannels: $0.outputChannels, sampleRate: $0.sampleRate)
        }, defaultOutputUID: devices.defaultOutputUID)
        let store = Store(storageURL: storage, engine: Engine(loopbackOnly: true), audioCatalog: { outputsOnly })
        let work = SIPAccount(label: "Work", username: "alex", domain: "sip.example.test")
        let personal = SIPAccount(label: "Personal", username: "alex-home", domain: "voice.example.test")
        store.accounts = [work, personal]; store.selectedAccount = work.id
        store.connected = true; store.activeAccounts = [work.id]
        store.registrations[work.aor] = "Registered"; store.inputMode = .listen
        return store
    }
    private func scenario(_ state: String) {
        guard let account = store.accounts.first else { return }
        store.calls = []; store.selectedCall = nil; store.registrations[account.aor] = "Registered"
        store.registrationErrors = [:]
        if state == "failed" {
            store.registrations[account.aor] = "Registration failed"
            store.registrationErrors[account.aor] = "403 Forbidden · sample registration failure"
        } else if state != "idle" {
            var call = SIPCall(id: "preview-leg", account: account.aor, peer: "sip:1002@example.test", state: state == "incoming" ? "Incoming" : "Connected", incoming: state == "incoming", sipCallID: "preview-call-id")
            call.audioInput = CallAudioInput.listen.title
            store.calls = [call]; store.selectedCall = call.id
        }
    }
    var body: some Scene {
        WindowGroup("Baresip layout preview") {
            MainView().environmentObject(store).modifier(WorkspaceTheme())
                .frame(minWidth: 900, minHeight: 640)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Menu("Preview state") {
                            Button("Idle") { scenario("idle") }
                            Button("Active call") { scenario("active") }
                            Button("Incoming call") { scenario("incoming") }
                            Button("Registration failed") { scenario("failed") }
                        }
                    }
                }
        }.defaultSize(width: (Bundle.main.object(forInfoDictionaryKey: "PreviewWidth") as? NSNumber)?.doubleValue ?? 1100, height: (Bundle.main.object(forInfoDictionaryKey: "PreviewHeight") as? NSNumber)?.doubleValue ?? 780)
    }
}
