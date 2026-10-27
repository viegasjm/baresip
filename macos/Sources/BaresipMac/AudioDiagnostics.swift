import Foundation
import CoreAudio
import AVFoundation

enum AudioDiagnostics {
    static func snapshot() -> String {
        let permission: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permission = "Allowed"
        case .denied: permission = "Denied"
        case .restricted: permission = "Restricted"
        case .notDetermined: permission = "Not requested yet"
        @unknown default: permission = "Unknown"
        }
        return "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nMicrophone permission: \(permission)\n" + device(kAudioHardwarePropertyDefaultInputDevice, label: "Input", input: true) + "\n" + device(kAudioHardwarePropertyDefaultOutputDevice, label: "Output", input: false)
    }
    private static func device(_ selector: AudioObjectPropertySelector, label: String, input: Bool) -> String {
        var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0), size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id)
        guard status == noErr, id != 0 else { return "\(label): unavailable (OSStatus \(status))" }
        property.mSelector = kAudioObjectPropertyName
        var nameReference: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let nameStatus = AudioObjectGetPropertyData(id, &property, 0, nil, &size, &nameReference)
        let name = nameStatus == noErr ? (nameReference?.takeRetainedValue() as String? ?? "Unknown") : "Unknown"
        property.mSelector = kAudioDevicePropertyNominalSampleRate
        var sampleRate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        let rateStatus = AudioObjectGetPropertyData(id, &property, 0, nil, &size, &sampleRate)
        property.mSelector = kAudioDevicePropertyStreamConfiguration
        property.mScope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
        var bytes: UInt32 = 0
        var channels: UInt32 = 0
        if AudioObjectGetPropertyDataSize(id, &property, 0, nil, &bytes) == noErr, bytes >= MemoryLayout<AudioBufferList>.size {
            let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { storage.deallocate() }
            if AudioObjectGetPropertyData(id, &property, 0, nil, &bytes, storage) == noErr {
                let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
                channels = buffers.reduce(0) { $0 + $1.mNumberChannels }
            }
        }
        return "\(label): \(name) · device \(id) · \(channels) channels · \(rateStatus == noErr ? String(format: "%.0f", sampleRate) : "unknown") Hz"
    }
}
