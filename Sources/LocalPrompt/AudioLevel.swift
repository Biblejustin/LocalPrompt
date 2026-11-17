import AVFoundation
import Foundation

/// Metering only; the recognizer receives the original converted buffer.
enum AudioLevel {
    static func meterValue(in buffer: AVAudioPCMBuffer) -> Double {
        min(1, normalizedRMS(in: buffer) * 6)
    }

    /// RMS across every channel, normalized to full-scale PCM amplitude.
    static func normalizedRMS(in buffer: AVAudioPCMBuffer) -> Double {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return 0 }
        let stride = Int(buffer.stride)

        if let samples = buffer.floatChannelData {
            return rms(samples, frames: frames, channels: channels, stride: stride) { Double($0) }
        }
        if let samples = buffer.int16ChannelData {
            // SpeechAnalyzer commonly selects Int16, even for a Float32 mic.
            return rms(samples, frames: frames, channels: channels, stride: stride) { Double($0) / 32_768 }
        }
        if let samples = buffer.int32ChannelData {
            return rms(samples, frames: frames, channels: channels, stride: stride) { Double($0) / 2_147_483_648 }
        }
        return 0
    }

    private static func rms<Sample>(
        _ samples: UnsafePointer<UnsafeMutablePointer<Sample>>,
        frames: Int, channels: Int, stride: Int, normalize: (Sample) -> Double
    ) -> Double {
        var squareSum = 0.0
        for channel in 0..<channels {
            for frame in 0..<frames {
                let sample = normalize(samples[channel][frame * stride])
                if sample.isFinite { squareSum += sample * sample }
            }
        }
        return sqrt(squareSum / Double(frames * channels))
    }
}
