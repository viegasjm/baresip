import SwiftUI
import UniformTypeIdentifiers

struct AudioSettingsView: View {
    @EnvironmentObject var store: Store
    @State private var showFilePicker = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Audio devices").font(.largeTitle.weight(.semibold))
                        Text("Choose the microphone and speaker for your calls.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { store.refreshAudioDevices() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Send audio from", selection: $store.inputMode) {
                            ForEach(CallInputMode.allCases) { mode in Text(mode.title).tag(mode) }
                        }.disabled(store.busy || !store.calls.isEmpty)
                        Text("Without a microphone or microphone permission, automatic mode still connects the call so you can listen.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(store.audioFile?.name ?? "No audio file selected").lineLimit(1)
                            Spacer()
                            Button("Choose audio file…") { showFilePicker = true }.disabled(store.busy || !store.calls.isEmpty)
                            if store.audioFile != nil { Button("Clear") { store.clearAudioFile() }.disabled(store.busy || !store.calls.isEmpty) }
                        }
                        Text("WAV, MP3, M4A and other formats macOS can decode, up to 10 minutes. Files are converted locally and kept for this app session. Choose a file here to send it when the call connects, or use Play audio file during a call.").font(.caption).foregroundStyle(.secondary)
                    }.padding(16)
                } label: { Label("Call input", systemImage: "waveform") }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("Microphone", selection: $store.inputDeviceUID) {
                            Text("System default — \(store.audioDevices.resolve("default", input: true)?.name ?? "No microphone")").tag("default")
                            ForEach(store.audioDevices.inputs) { device in Text(deviceLabel(device)).tag(device.uid) }
                            if store.inputDeviceUID != "default", !store.audioDevices.inputs.contains(where: { $0.uid == store.inputDeviceUID }) {
                                Text("Previously selected microphone is unavailable").tag(store.inputDeviceUID)
                            }
                        }.disabled(store.busy || !store.calls.isEmpty)
                        if let device = store.audioDevices.resolve(store.inputDeviceUID, input: true) {
                            deviceDetails(device, channels: device.inputChannels)
                        } else {
                            Label(store.audioDevices.inputs.isEmpty ? "No microphone detected. Calls will use listen-only mode unless you choose an audio file." : "Choose an available microphone.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                } label: { Label("Input", systemImage: "mic") }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("Speaker", selection: $store.outputDeviceUID) {
                            Text("System default — \(store.audioDevices.resolve("default", input: false)?.name ?? "No speaker")").tag("default")
                            ForEach(store.audioDevices.outputs) { device in Text(deviceLabel(device)).tag(device.uid) }
                            if store.outputDeviceUID != "default", !store.audioDevices.outputs.contains(where: { $0.uid == store.outputDeviceUID }) {
                                Text("Previously selected speaker is unavailable").tag(store.outputDeviceUID)
                            }
                        }.disabled(store.busy || !store.calls.isEmpty)
                        if let device = store.audioDevices.resolve(store.outputDeviceUID, input: false) {
                            deviceDetails(device, channels: device.outputChannels)
                        } else { Label("Choose an available speaker.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                } label: { Label("Output", systemImage: "speaker.wave.2") }
                HStack {
                    Toggle("Keypad sounds", isOn: $store.keypadSounds).toggleStyle(.checkbox)
                    Spacer()
                    Button("Test keypad sound") { store.playKeypadSound() }.disabled(!store.keypadSounds)
                }
                Text("Hear a short tone through the selected speaker when sending a digit. Turning this off keeps sending digits to the call.").font(.caption).foregroundStyle(.secondary)
                if let issue = store.keypadSoundIssue { Text(issue).font(.caption).foregroundStyle(.orange) }
                Toggle("Use mono device audio", isOn: $store.monoDeviceAudio).disabled(store.busy || !store.calls.isEmpty)
                Text("Device choices are saved on this Mac. Changing a device reconnects idle accounts. Finish active calls before changing devices. Mono mode applies after reconnecting.").font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url): store.importAudioFile(url)
            case .failure(let error): store.error = error.localizedDescription
            }
        }
        .onAppear { store.refreshAudioDevices() }
        .onChange(of: store.inputDeviceUID) { _, _ in store.audioDeviceChanged() }
        .onChange(of: store.outputDeviceUID) { _, _ in store.audioDeviceChanged() }
    }
    private func deviceLabel(_ device: AudioDeviceInfo) -> String {
        store.audioDevices.devices.filter { $0.name == device.name }.count > 1 ? "\(device.name) — \(device.uid)" : device.name
    }
    private func deviceDetails(_ device: AudioDeviceInfo, channels: UInt32) -> some View {
        Text("\(channels) channel\(channels == 1 ? "" : "s") · \(Int(device.sampleRate)) Hz").font(.caption).foregroundStyle(.secondary)
    }
}
