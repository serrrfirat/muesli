import AVFoundation
import Foundation

/// Capture and imported files are normalized by Hush's chunker to bounded mono PCM16 WAV.
/// Local Muesli models receive 16 kHz floats without writing decrypted audio to disk.
enum HushLocalAudio {
    static func samples(from chunk: AudioChunk) throws -> [Float] {
        try samples(wav: chunk.data)
    }

    static func samples(wav: Data) throws -> [Float] {
        try wav.withUnsafeBytes { bytes in
            guard bytes.count >= 44 else { throw AppError("Invalid captured PCM audio") }
            func word(_ offset: Int) -> UInt16 {
                UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
            }
            func integer(_ offset: Int) -> UInt32 {
                UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            }
            let rate = integer(24)
            let payload = Int(integer(40))
            guard integer(0) == 0x46464952, integer(8) == 0x45564157,
                  integer(12) == 0x20746D66, integer(16) == 16,
                  word(20) == 1, word(22) == 1, word(32) == 2, word(34) == 16,
                  integer(36) == 0x61746164, payload == bytes.count - 44, payload > 0,
                  payload.isMultiple(of: 2), (8_000...192_000).contains(rate) else {
                throw AppError("Local transcription requires captured mono PCM16 audio")
            }
            let count = payload / 2
            func sample(_ index: Int) -> Float {
                Float(Int16(bitPattern: word(44 + index * 2))) / 32768
            }
            if rate == 16_000 {
                return Array(unsafeUninitializedCapacity: count) { buffer, initialized in
                    for index in 0..<count { buffer[index] = sample(index) }
                    initialized = count
                }
            }
            guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(rate), channels: 1, interleaved: false),
                  let destinationFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                    sampleRate: 16_000, channels: 1, interleaved: false),
                  let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(count)),
                  let channel = input.floatChannelData?[0],
                  let converter = AVAudioConverter(from: sourceFormat, to: destinationFormat) else {
                throw AppError("Could not prepare local transcription audio")
            }
            input.frameLength = AVAudioFrameCount(count)
            for index in 0..<count { channel[index] = sample(index) }
            let capacity = AVAudioFrameCount(ceil(Double(count) * 16_000 / Double(rate))) + 64
            guard let output = AVAudioPCMBuffer(pcmFormat: destinationFormat, frameCapacity: capacity) else {
                throw AppError("Could not allocate local transcription audio")
            }
            var supplied = false
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, state in
                guard !supplied else { state.pointee = .endOfStream; return nil }
                supplied = true
                state.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            guard status != .error, output.frameLength > 0, let samples = output.floatChannelData?[0] else {
                throw AppError("Could not resample local transcription audio")
            }
            return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        }
    }
}
