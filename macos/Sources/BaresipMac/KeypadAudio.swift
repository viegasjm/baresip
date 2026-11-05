import Foundation
import AVFoundation

/// Short local feedback. These samples never enter the SIP audio source.
enum KeypadTone {
    static let sampleRate = 44100
    static let duration = 0.14
    static func samples(for digit: String) throws -> [Int16] {
        let rows = ["123", "456", "789", "*0#"]
        let lows = [697.0, 770.0, 852.0, 941.0]
        let highs = [1209.0, 1336.0, 1477.0]
        guard digit.count == 1, let row = rows.firstIndex(where: { $0.contains(digit) }),
              let column = Array(rows[row]).map(String.init).firstIndex(of: digit) else {
            throw AppError.message("Choose a keypad digit from 0–9, * or #.")
        }
        let count = Int(Double(sampleRate) * duration)
        let ramp = Double(sampleRate) * 0.005
        return (0..<count).map { index in
            let t = Double(index) / Double(sampleRate)
            let envelope = min(1, Double(index) / ramp, Double(count - 1 - index) / ramp)
            let value = 0.12 * envelope * (sin(2 * .pi * lows[row] * t) + sin(2 * .pi * highs[column] * t))
            return Int16(value * Double(Int16.max))
        }
    }
    static func wave(for digit: String) throws -> Data {
        let samples = try samples(for: digit)
        var data = Data()
        func string(_ value: String) { data.append(contentsOf: value.utf8) }
        func integer<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        string("RIFF"); integer(UInt32(36 + samples.count * 2)); string("WAVEfmt ")
        integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
        integer(UInt32(sampleRate)); integer(UInt32(sampleRate * 2))
        integer(UInt16(2)); integer(UInt16(16)); string("data"); integer(UInt32(samples.count * 2))
        for sample in samples { integer(sample) }
        return data
    }
}

@MainActor final class KeypadAudio {
    private var player: AVAudioPlayer?
    private var cleanup: Task<Void, Never>?
    var playbackTime: TimeInterval { player?.currentTime ?? 0 }
    var isPlaying: Bool { player?.isPlaying == true }
    var outputUID: String? { player?.currentDevice }
    func play(_ digit: String, outputUID: String) throws {
        let data = try KeypadTone.wave(for: digit)
        stop()
        let player = try AVAudioPlayer(data: data)
        player.currentDevice = outputUID
        guard player.currentDevice == outputUID, player.prepareToPlay(), player.play() else {
            throw AppError.message("Keypad sound could not play through the selected speaker. Check the Audio tab and the Mac's output volume.")
        }
        self.player = player
        cleanup = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            self?.stop()
        }
    }
    func stop() {
        cleanup?.cancel(); cleanup = nil
        player?.stop(); player = nil
    }
}
