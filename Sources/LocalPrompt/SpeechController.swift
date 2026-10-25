import AVFoundation
import Combine
import Foundation
import Speech

/// Apple's SpeechTranscriber performs recognition on this Mac. Only model setup
/// may use the network; microphone audio is neither uploaded nor saved.
@MainActor
final class SpeechController: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isPreparing = false
    @Published private(set) var status = "Voice follow ready"
    @Published private(set) var transcript = ""
    @Published private(set) var level = 0.0
    @Published var errorMessage: String?

    private let locale: Locale
    private var sessionID: UUID?
    private var setupTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var analyzer: SpeechAnalyzer?
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var pump: AudioInputPump?
    private var downloadObservation: NSKeyValueObservation?
    private var finalizedTranscript = ""

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    func start() async {
        guard !isRunning, !isPreparing else { return }
        let id = beginPreparation(status: "Preparing microphone…")
        transcript = ""
        finalizedTranscript = ""
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                await self.cleanupTask?.value
                try self.checkSession(id)
                guard await self.microphoneAllowed() else {
                    throw SpeechFailure.microphoneDenied
                }
                try self.checkSession(id)
                let transcriber = try await self.makeReadyTranscriber(id: id)
                let audioEngine = AVAudioEngine()
                let input = audioEngine.inputNode
                let naturalFormat = input.outputFormat(forBus: 0)
                guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else {
                    throw SpeechFailure.noMicrophone
                }
                guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
                    compatibleWith: [transcriber], considering: naturalFormat
                ) else { throw SpeechFailure.unsupportedAudio }
                try self.checkSession(id)

                let analyzer = SpeechAnalyzer(modules: [transcriber])
                self.analyzer = analyzer
                try await analyzer.prepareToAnalyze(in: format)
                try self.checkSession(id)
                let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
                let pump = try AudioInputPump(
                    inputFormat: naturalFormat, outputFormat: format,
                    continuation: continuation,
                    onLevel: { [weak self] value in
                        Task { @MainActor in
                            guard self?.sessionID == id else { return }
                            self?.level = value
                        }
                    },
                    onError: { [weak self] message in
                        Task { @MainActor in self?.fail(message, id: id) }
                    }
                )
                self.pump = pump
                self.engine = audioEngine
                self.consumeResults(from: transcriber, id: id)
                try await analyzer.start(inputSequence: stream)
                try self.checkSession(id)
                input.installTap(onBus: 0, bufferSize: 1024, format: naturalFormat) { [weak pump] buffer, _ in
                    pump?.append(buffer)
                }
                self.tapInstalled = true
                audioEngine.prepare()
                try audioEngine.start()
                self.isPreparing = false
                self.isRunning = true
                self.status = "Listening · on this Mac"
            } catch is CancellationError {
                if self.sessionID == id { self.stop() }
            } catch {
                self.fail(error.localizedDescription, id: id)
            }
        }
        setupTask = task
        await task.value
        if sessionID == id { setupTask = nil }
    }

    /// Downloads missing language assets without opening the microphone.
    func prepareModel() async {
        guard !isRunning, !isPreparing else { return }
        let id = beginPreparation(status: "Checking local speech model…")
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.makeReadyTranscriber(id: id)
                try self.checkSession(id)
                self.isPreparing = false
                self.status = "Local speech model ready"
            } catch is CancellationError {
                if self.sessionID == id { self.stop() }
            } catch {
                self.fail(error.localizedDescription, id: id)
            }
        }
        setupTask = task
        await task.value
        if sessionID == id { setupTask = nil }
    }

    func stop() {
        sessionID = nil
        setupTask?.cancel()
        setupTask = nil
        downloadObservation?.invalidate()
        downloadObservation = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        engine = nil
        pump?.finish()
        pump = nil
        resultsTask?.cancel()
        resultsTask = nil
        if let analyzer {
            let previousCleanup = cleanupTask
            cleanupTask = Task {
                await previousCleanup?.value
                await analyzer.cancelAndFinishNow()
            }
        }
        analyzer = nil
        isRunning = false
        isPreparing = false
        level = 0
        status = "Paused"
    }

    /// Exercises the actual local model with a supplied file, without mic access.
    func transcribeFile(_ url: URL) async throws -> String {
        guard !isRunning, !isPreparing else { throw SpeechFailure.sessionBusy }
        let id = beginPreparation(status: "Preparing local file transcription…")
        transcript = ""
        finalizedTranscript = ""
        do {
            await cleanupTask?.value
            try checkSession(id)
            let transcriber = try await makeReadyTranscriber(id: id)
            let file = try AVAudioFile(forReading: url)
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            self.analyzer = analyzer
            consumeResults(from: transcriber, id: id)
            let fileResultsTask = resultsTask
            isPreparing = false
            isRunning = true
            status = "Transcribing file · on this Mac"
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            // A stop/restart can replace the controller's task during start().
            // This invocation must await only its own result stream.
            await fileResultsTask?.value
            if let errorMessage { throw SpeechFailure.recognition(errorMessage) }
            try checkSession(id)
            let result = transcript
            stop()
            status = "Local file transcription complete"
            return result
        } catch {
            if sessionID == id { fail(error.localizedDescription, id: id) }
            throw error
        }
    }

    private func beginPreparation(status: String) -> UUID {
        let id = UUID()
        sessionID = id
        errorMessage = nil
        isPreparing = true
        self.status = status
        return id
    }

    private func checkSession(_ id: UUID) throws {
        try Task.checkCancellation()
        guard sessionID == id else { throw CancellationError() }
    }

    private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func makeReadyTranscriber(id: UUID) async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw SpeechFailure.unavailable }
        guard let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw SpeechFailure.unsupportedLanguage
        }
        try checkSession(id)
        let transcriber = SpeechTranscriber(
            locale: supportedLocale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: []
        )
        status = "Checking local speech model…"
        if let download = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try checkSession(id)
            status = "Downloading speech model from Apple…"
            downloadObservation = download.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] progress, _ in
                let percentage = Int(progress.fractionCompleted * 100)
                Task { @MainActor in
                    guard self?.sessionID == id else { return }
                    self?.status = "Downloading speech model… \(percentage)%"
                }
            }
            try await download.downloadAndInstall()
            try checkSession(id)
            downloadObservation?.invalidate()
            downloadObservation = nil
        }
        try checkSession(id)
        guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
            throw SpeechFailure.modelNotInstalled
        }
        try checkSession(id)
        return transcriber
    }

    private func consumeResults(from transcriber: SpeechTranscriber, id: UUID) {
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.sessionID == id else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.finalizedTranscript = self.join(self.finalizedTranscript, text)
                        self.transcript = self.finalizedTranscript
                    } else {
                        // Volatile results replace the current segment, never append it.
                        self.transcript = self.join(self.finalizedTranscript, text)
                    }
                }
            } catch is CancellationError {
                // User stopped, or another task already reported the session error.
            } catch {
                self?.fail(error.localizedDescription, id: id)
            }
        }
    }

    private func join(_ prefix: String, _ suffix: String) -> String {
        guard !prefix.isEmpty else { return suffix }
        guard !suffix.isEmpty else { return prefix }
        return prefix + (prefix.last?.isWhitespace == true || suffix.first?.isWhitespace == true ? "" : " ") + suffix
    }

    private func fail(_ message: String, id: UUID) {
        guard sessionID == id else { return }
        stop()
        errorMessage = message
        status = "Voice follow unavailable"
    }
}

private enum SpeechFailure: LocalizedError {
    case microphoneDenied, noMicrophone, unsupportedAudio, unavailable
    case unsupportedLanguage, modelNotInstalled, sessionBusy, recognition(String)

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Allow LocalPrompt microphone access in System Settings → Privacy & Security → Microphone."
        case .noMicrophone: return "No working microphone found. Connect or select a microphone, then try again."
        case .unsupportedAudio: return "This microphone format cannot be converted for local speech recognition."
        case .unavailable: return "Apple's local speech model is unavailable on this Mac. Voice follow requires a supported Mac running macOS 26 or later."
        case .unsupportedLanguage: return "Local speech recognition does not support this language on this Mac."
        case .modelNotInstalled: return "Speech model is not installed. Connect to the internet, prepare the model, then retry."
        case .sessionBusy: return "Stop the current voice session before transcribing a file."
        case .recognition(let message): return message
        }
    }
}

/// Owns audio buffers before leaving the real-time tap. Conversion occurs on a
/// serial queue; no UI work, disk recording, or network work occurs in the tap.
private final class AudioInputPump: @unchecked Sendable {
    private let queue = DispatchQueue(label: "LocalPrompt.audio-conversion", qos: .userInitiated)
    private let lock = NSLock()
    private var closed = false
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private let onLevel: @Sendable (Double) -> Void
    private let onError: @Sendable (String) -> Void
    private var levelCounter = 0

    init(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat,
         continuation: AsyncStream<AnalyzerInput>.Continuation,
         onLevel: @escaping @Sendable (Double) -> Void,
         onError: @escaping @Sendable (String) -> Void) throws {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SpeechFailure.unsupportedAudio
        }
        self.converter = converter
        self.format = outputFormat
        self.continuation = continuation
        self.onLevel = onLevel
        self.onError = onError
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard !isClosed, let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in source.indices {
            if let from = source[index].mData, let to = destination[index].mData {
                memcpy(to, from, Int(source[index].mDataByteSize))
            }
        }
        queue.async { [weak self] in self?.convert(copy) }
    }

    func finish() {
        lock.lock()
        closed = true
        lock.unlock()
        continuation.finish()
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    private func convert(_ buffer: AVAudioPCMBuffer) {
        guard !isClosed else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            onError(error?.localizedDescription ?? "Microphone audio conversion failed.")
            return
        }
        guard converted.frameLength > 0, !isClosed else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
        levelCounter += 1
        if levelCounter % 4 == 0, let samples = converted.floatChannelData?[0] {
            var squareSum = 0.0
            let stride = converted.format.isInterleaved ? Int(converted.format.channelCount) : 1
            for index in 0..<Int(converted.frameLength) {
                let sample = Double(samples[index * stride])
                squareSum += sample * sample
            }
            onLevel(min(1, sqrt(squareSum / Double(converted.frameLength)) * 6))
        }
    }
}
