import Foundation
import AVFoundation

enum CallInputMode: String, CaseIterable, Identifiable {
    case automatic, listen, file
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Microphone when available"
        case .listen: return "Listen only"
        case .file: return "Audio file"
        }
    }
}
enum CallAudioInput: Equatable {
    case listen, microphone(String), file(URL)
    var direction: String { self == .listen ? "recvonly" : "sendrecv" }
    var source: String? {
        switch self {
        case .listen: return nil
        case .microphone(let uid): return "coreaudio,\(uid)"
        case .file(let url): return "aufile,\(url.path)"
        }
    }
    var title: String {
        switch self {
        case .listen: return "Listen only · no audio sent"
        case .microphone: return "Microphone"
        case .file: return "Audio file"
        }
    }
}

struct PreparedAudioFile {
    let url: URL
    let name: String
    func remove() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}
enum AudioFileInput {
    // A private, short path avoids the engine's 128-byte device field limit.
    static func prepare(_ source: URL) throws -> PreparedAudioFile {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let input = try AVAudioFile(forReading: source)
        let duration = Double(input.length) / input.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, duration <= 600 else {
            throw AppError.message("Choose an audio file between 0 and 10 minutes long.")
        }
        let folder = URL(fileURLWithPath: "/tmp/bm-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let target = folder.appendingPathComponent("input.wav")
        do {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true),
                  let converter = AVAudioConverter(from: input.processingFormat, to: format) else {
                throw AppError.message("This audio format cannot be converted for calls.")
            }
            guard FileManager.default.createFile(atPath: target.path, contents: wavHeader(bytes: 0), attributes: [.posixPermissions: 0o600]) else {
                throw AppError.message("Could not create the call audio file.")
            }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            try output.seekToEnd()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw AppError.message("Could not prepare audio buffers.") }
            var readError: Error?
            var framesWritten: AVAudioFramePosition = 0
            while true {
                var conversionError: NSError?
                let status = converter.convert(to: buffer, error: &conversionError) { frames, state in
                    if input.framePosition >= input.length { state.pointee = .endOfStream; return nil }
                    guard readError == nil else { state.pointee = .endOfStream; return nil }
                    guard let chunk = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: min(frames, 4096)) else {
                        readError = AppError.message("Could not prepare the audio file.")
                        state.pointee = .endOfStream; return nil
                    }
                    do { try input.read(into: chunk) }
                    catch { readError = error; state.pointee = .endOfStream; return nil }
                    state.pointee = chunk.frameLength == 0 ? .endOfStream : .haveData
                    return chunk.frameLength == 0 ? nil : chunk
                }
                if let readError { throw readError }
                if status == .error { throw conversionError ?? AppError.message("The audio file could not be converted.") }
                framesWritten += AVAudioFramePosition(buffer.frameLength)
                guard framesWritten <= 16000 * 600 else { throw AppError.message("The converted file exceeds 10 minutes.") }
                if buffer.frameLength > 0 {
                    guard let samples = buffer.int16ChannelData?[0] else { throw AppError.message("The converted audio has no samples.") }
                    try output.write(contentsOf: Data(bytes: samples, count: Int(buffer.frameLength) * 2))
                }
                if status == .endOfStream { break }
                if status == .error || (status == .inputRanDry && buffer.frameLength == 0) {
                    throw AppError.message("The audio file could not be decoded completely.")
                }
            }
            guard framesWritten > 0 else { throw AppError.message("The audio file is empty.") }
            try output.seek(toOffset: 0)
            try output.write(contentsOf: wavHeader(bytes: UInt32(framesWritten * 2)))
            try output.close()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            return PreparedAudioFile(url: target, name: source.lastPathComponent)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }
    // Libre's WAV reader expects fmt immediately after RIFF; AVAudioFile's
    // writer can insert JUNK chunks. Emit a canonical PCM header instead.
    private static func wavHeader(bytes: UInt32) -> Data {
        var result = Data("RIFF".utf8)
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { result.append(contentsOf: $0) }
        }
        number(UInt32(36) + bytes)
        result.append(Data("WAVEfmt ".utf8))
        number(UInt32(16)); number(UInt16(1)); number(UInt16(1))
        number(UInt32(16000)); number(UInt32(32000))
        number(UInt16(2)); number(UInt16(16))
        result.append(Data("data".utf8)); number(bytes)
        return result
    }

}
