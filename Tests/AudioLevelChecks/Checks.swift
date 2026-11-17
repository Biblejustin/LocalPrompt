import AVFoundation
import Foundation

// Synthetic PCM buffers only. No microphone, audio engine, or preferences.
@main
struct AudioLevelChecks {
    static func main() throws {
        var checks = 0
        func expect(_ actual: Double, _ expected: Double, _ label: String) throws {
            guard actual.isFinite, abs(actual - expected) < 0.000_001 else {
                throw Failure(description: "\(label): expected \(expected), got \(actual)")
            }
            checks += 1
        }

        let silent = buffer(.pcmFormatInt16, channels: 1)
        for frame in 0..<4 { silent.int16ChannelData![0][frame] = 0 }
        try expect(AudioLevel.meterValue(in: silent), 0, "Int16 silence")
        silent.frameLength = 0
        try expect(AudioLevel.meterValue(in: silent), 0, "Empty audio")

        let quiet = buffer(.pcmFormatInt16, channels: 1)
        for (frame, sample) in [Int16(2048), -2048, 2048, -2048].enumerated() {
            quiet.int16ChannelData![0][frame] = sample
        }
        try expect(AudioLevel.normalizedRMS(in: quiet), 0.0625, "Int16 known RMS")
        try expect(AudioLevel.meterValue(in: quiet), 0.375, "Int16 visible meter")

        let fullScale = buffer(.pcmFormatInt16, channels: 1)
        for frame in 0..<4 { fullScale.int16ChannelData![0][frame] = .min }
        try expect(AudioLevel.normalizedRMS(in: fullScale), 1, "Int16 negative full scale")
        try expect(AudioLevel.meterValue(in: fullScale), 1, "Meter clamps at full scale")

        let floats = buffer(.pcmFormatFloat32, channels: 1)
        for (frame, sample) in [Float(0.1), -0.1, 0.1, -0.1].enumerated() {
            floats.floatChannelData![0][frame] = sample
        }
        try expect(AudioLevel.meterValue(in: floats), 0.6, "Float32 meter preserved")
        for frame in 0..<4 { floats.floatChannelData![0][frame] = 2 }
        try expect(AudioLevel.meterValue(in: floats), 1, "Over-range float clips meter")

        // A signal only on the second channel must remain visible. Interleaved
        // and planar versions of the same waveform must have identical RMS.
        for interleaved in [false, true] {
            let stereo = buffer(.pcmFormatInt16, channels: 2, interleaved: interleaved)
            for frame in 0..<4 {
                let signal: Int16 = frame % 2 == 0 ? 8192 : -8192
                if interleaved {
                    // Write the raw interleaved storage independently of the
                    // per-channel pointers used by the meter implementation.
                    stereo.int16ChannelData![0][frame * 2] = 0
                    stereo.int16ChannelData![0][frame * 2 + 1] = signal
                } else {
                    stereo.int16ChannelData![0][frame] = 0
                    stereo.int16ChannelData![1][frame] = signal
                }
            }
            try expect(AudioLevel.normalizedRMS(in: stereo), sqrt(0.25 * 0.25 / 2), "Int16 stereo \(interleaved)")

            let multichannel = buffer(.pcmFormatFloat32, channels: 2, interleaved: interleaved)
            for frame in 0..<4 {
                if interleaved {
                    multichannel.floatChannelData![0][frame * 2] = 0.125
                    multichannel.floatChannelData![0][frame * 2 + 1] = -0.25
                } else {
                    multichannel.floatChannelData![0][frame] = 0.125
                    multichannel.floatChannelData![1][frame] = -0.25
                }
            }
            try expect(AudioLevel.normalizedRMS(in: multichannel), sqrt((0.015625 + 0.0625) / 2), "Float32 multichannel \(interleaved)")
        }

        let integers = buffer(.pcmFormatInt32, channels: 1)
        for frame in 0..<4 { integers.int32ChannelData![0][frame] = 536_870_912 }
        try expect(AudioLevel.normalizedRMS(in: integers), 0.25, "Int32 normalization")

        print("Audio level: \(checks) checks passed")
    }

    private static func buffer(_ format: AVAudioCommonFormat, channels: AVAudioChannelCount, interleaved: Bool = false) -> AVAudioPCMBuffer {
        let pcm = AVAudioFormat(commonFormat: format, sampleRate: 16_000, channels: channels, interleaved: interleaved)!
        let result = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: 4)!
        result.frameLength = 4
        return result
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }
}
