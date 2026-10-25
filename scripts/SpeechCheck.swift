import Foundation
import Speech

/// Compile with SpeechController.swift. Requires a synthetic audio fixture;
/// never requests microphone access or records audio.
@main
struct SpeechCheck {
    @MainActor
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            print("Usage: speech-check /path/to/voice-check.aiff")
            exit(2)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let expected = "Welcome. Take a breath, settle in, and speak at your own pace. This is LocalPrompt. The words move with your voice, so you can focus on what you want to say."
        let controller = SpeechController()
        do {
            guard SpeechTranscriber.isAvailable else { throw CheckError.failed("Local model unavailable") }
            let installed = await SpeechTranscriber.installedLocales
            guard installed.contains(where: { $0.language.languageCode?.identifier == "en" }) else {
                throw CheckError.failed("Install English speech assets before this check; test does not download models.")
            }

            for iteration in 1...2 {
                let start = Date()
                let transcript = try await controller.transcribeFile(url)
                let errorRate = wordErrorRate(expected: expected, actual: transcript)
                print("Session \(iteration): \(String(format: "%.2f", Date().timeIntervalSince(start)))s; word error rate \(Int(errorRate * 100))%")
                print(transcript)
                guard errorRate <= 0.25 else { throw CheckError.failed("Transcript differs substantially from fixture") }
                guard !controller.isRunning, !controller.isPreparing, controller.errorMessage == nil else {
                    throw CheckError.failed("Session did not clean up")
                }
            }

            do {
                _ = try await controller.transcribeFile(url.deletingLastPathComponent().appendingPathComponent("missing-speech-check-file.aiff"))
                throw CheckError.failed("Missing file unexpectedly succeeded")
            } catch let error as CheckError {
                throw error
            } catch {
                guard !controller.isRunning, !controller.isPreparing, controller.errorMessage != nil else {
                    throw CheckError.failed("Failure did not clean up")
                }
                print("Missing-file failure: cleaned up")
            }

            let recovered = try await controller.transcribeFile(url)
            guard wordErrorRate(expected: expected, actual: recovered) <= 0.25,
                  !controller.isRunning, !controller.isPreparing,
                  controller.errorMessage == nil else {
                throw CheckError.failed("Recovery session failed")
            }
            controller.stop()
            controller.stop()
            print("Recovery + repeated stop: passed")
            print("PASS: real local speech model; 3 file sessions; failure recovery; no microphone access")
        } catch {
            controller.stop()
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "local prompt", with: "localprompt")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func wordErrorRate(expected: String, actual: String) -> Double {
        let reference = words(expected)
        let recognized = words(actual)
        var row = Array(0...recognized.count)
        for (index, word) in reference.enumerated() {
            var next = [index + 1] + Array(repeating: 0, count: recognized.count)
            for (column, other) in recognized.enumerated() {
                next[column + 1] = min(row[column + 1] + 1, next[column] + 1,
                                       row[column] + (word == other ? 0 : 1))
            }
            row = next
        }
        return Double(row.last ?? 0) / Double(max(1, reference.count))
    }

    private enum CheckError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }
}
