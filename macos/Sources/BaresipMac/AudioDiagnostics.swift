import Foundation
import CoreAudio
import AVFoundation

struct AudioDeviceInfo: Identifiable, Equatable {
    var id: String { uid }
    let uid: String
    let name: String
    let inputChannels: UInt32
    let outputChannels: UInt32
    let sampleRate: Float64
}
struct AudioDeviceCatalog {
    var devices: [AudioDeviceInfo] = []
    var defaultInputUID: String?
    var defaultOutputUID: String?
    var inputs: [AudioDeviceInfo] { devices.filter { $0.inputChannels > 0 } }
    var outputs: [AudioDeviceInfo] { devices.filter { $0.outputChannels > 0 } }
    func resolve(_ uid: String, input: Bool) -> AudioDeviceInfo? {
        let target = uid == "default" ? (input ? defaultInputUID : defaultOutputUID) : uid
        return (input ? inputs : outputs).first { $0.uid == target }
    }
}
struct AudioRouting: Equatable {
    var inputUID = "default"
    var outputUID = "default"
    func validate() throws {
        for uid in [inputUID, outputUID] {
            guard !uid.isEmpty, uid.utf8.count < 128, uid.rangeOfCharacter(from: CharacterSet(charactersIn: ",\r\n\0")) == nil else { throw AppError.message("The audio device identifier cannot be used in this configuration.") }
        }
    }
    func validateForCall(in catalog: AudioDeviceCatalog) throws {
        try validate()
        guard catalog.resolve(inputUID, input: true) != nil else {
            throw AppError.message(inputUID == "default" ? "No microphone is available. Connect a USB/Bluetooth microphone or headset, then choose it in the Audio tab." : "The selected microphone is unavailable. Choose an available input in the Audio tab.")
        }
        guard catalog.resolve(outputUID, input: false) != nil else {
            throw AppError.message("The selected speaker is unavailable. Choose an available output in the Audio tab.")
        }
    }
}
enum AudioDiagnostics {
    static func catalog() -> AudioDeviceCatalog {
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &bytes) == noErr, bytes > 0 else { return AudioDeviceCatalog() }
        var ids = [AudioDeviceID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &bytes, $0.baseAddress!) }
        guard status == noErr else { return AudioDeviceCatalog() }
        let devices = ids.compactMap { id -> AudioDeviceInfo? in
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) else { return nil }
            var rate = Float64(0), size = UInt32(MemoryLayout<Float64>.size)
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
            return AudioDeviceInfo(uid: uid, name: stringProperty(id, kAudioObjectPropertyName) ?? "Audio device", inputChannels: channels(id, input: true), outputChannels: channels(id, input: false), sampleRate: rate)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return AudioDeviceCatalog(devices: devices, defaultInputUID: defaultUID(kAudioHardwarePropertyDefaultInputDevice), defaultOutputUID: defaultUID(kAudioHardwarePropertyDefaultOutputDevice))
    }
    static func snapshot() -> String {
        let permission: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = "Allowed"
        case .denied: permission = "Denied"
        case .restricted: permission = "Restricted"
        case .notDetermined: permission = "Not requested yet"
        @unknown default: permission = "Unknown"
        }
        let devices = catalog()
        var result = "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nMicrophone permission: \(permission)\n"
        result += "Input: \(devices.resolve("default", input: true)?.name ?? "No default microphone")\nOutput: \(devices.resolve("default", input: false)?.name ?? "No default speaker")\nAvailable devices:\n"
        for device in devices.devices {
            result += "\(device.name) · UID \(device.uid) · input \(device.inputChannels) ch · output \(device.outputChannels) ch · \(Int(device.sampleRate)) Hz\n"
        }
        return result
    }
    private static func defaultUID(_ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return stringProperty(id, kAudioDevicePropertyDeviceUID)
    }
    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var reference: Unmanaged<CFString>?, size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &reference) == noErr else { return nil }
        return reference?.takeRetainedValue() as String?
    }
    private static func channels(_ id: AudioDeviceID, input: Bool) -> UInt32 {
        var property = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &property, 0, nil, &bytes) == noErr, bytes >= MemoryLayout<AudioBufferList>.size else { return 0 }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &bytes, storage) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + $1.mNumberChannels }
    }
}
