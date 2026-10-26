import AppKit
import Combine
import PromptCore
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    static let sample = """
    Welcome. Take a breath, settle in, and speak at your own pace.

    This is LocalPrompt. The words move with your voice, so you can focus on what you want to say.

    Pause whenever you need. Your place will wait for you. If you step away from the script, return to the next sentence when you are ready.

    A good message is more than words on a screen. It is a connection between people. Look up, slow down, and give each idea room to breathe.

    You can click any word to start from there. Adjust the text size, turn on the mirror for teleprompter glass, or fill your screen.

    Now replace this practice script with your own. Your voice, your words, your pace.
    """

    enum Mode: String, CaseIterable { case voice = "Voice follow", timed = "Steady pace" }
    let speech = SpeechController()
    let presentation = SlidePresentationController()
    @Published private(set) var document: MarkdownDocument
    @Published var script: String {
        didSet {
            guard script != oldValue else { return }
            stop()
            presentation.disconnect()
            slideCueInsertionRange = nil
            document = MarkdownDocument(source: script)
            tracker = ScriptTracker(script: document.trackingText)
            slideCues = SlideCueTracker(cues: document.slideCues)
            position = 0
            elapsed = 0
            wordFraction = 0
            matchConfidence = 0
            UserDefaults.standard.set(script, forKey: "draftScript")
        }
    }
    @Published var title: String {
        didSet { UserDefaults.standard.set(title, forKey: "draftTitle") }
    }
    @Published var position = 0
    @Published var mode: Mode = .voice { didSet { stop() } }
    @Published var timedRunning = false
    @Published var wordsPerMinute = 120.0
    @Published var elapsed = 0.0
    @Published var matchConfidence = 0.0
    @Published var documentError: String?
    @Published var slideError: String?
    @Published private(set) var slideBusy = false
    private var tracker: ScriptTracker
    private var slideCues: SlideCueTracker
    private var pendingSlideAdvances = 0
    private var slideTask: Task<Void, Never>?
    private var slideGeneration = UUID()
    private var slideCueInsertionRange: NSRange?
    private let readingActivity = ReadingActivity()
    private var subscriptions = Set<AnyCancellable>()
    private var lastTick = Date()
    private var wordFraction = 0.0

    init() {
        let draft = UserDefaults.standard.string(forKey: "draftScript") ?? Self.sample
        let rendered = MarkdownDocument(source: draft)
        script = draft
        document = rendered
        title = UserDefaults.standard.string(forKey: "draftTitle") ?? "Practice script"
        tracker = ScriptTracker(script: rendered.trackingText)
        slideCues = SlideCueTracker(cues: rendered.slideCues)
        speech.$transcript.sink { [weak self] text in
            guard let self, !text.isEmpty else { return }
            let update = self.tracker.update(transcript: text)
            self.position = update.position
            self.matchConfidence = update.confidence
            if self.running { self.processSlideCues() }
        }.store(in: &subscriptions)
        presentation.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        presentation.$errorMessage.sink { [weak self] error in
            guard let self, let error else { return }
            if self.running { self.stop() }
            self.slideError = error
        }.store(in: &subscriptions)
        speech.$errorMessage.sink { [weak self] error in
            guard error != nil else { return }
            self?.cancelSlideAdvances()
        }.store(in: &subscriptions)
        // Use the published values: @Published sends before its stored value changes.
        // Silence and ad-libs still count as reading; model preparation does not.
        speech.$isRunning.combineLatest($timedRunning)
            .map { $0 || $1 }
            .removeDuplicates()
            .sink { [weak self] active in self?.readingActivity.setActive(active) }
            .store(in: &subscriptions)
        // AppDelegate also terminates after the last window closes. Fullscreen,
        // hiding, and minimizing do not end a reading session.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.stop() }
            .store(in: &subscriptions)
    }

    var words: [ScriptWord] { tracker.words }
    var wordCount: Int { words.count }
    var progress: Double { wordCount > 0 ? Double(position) / Double(wordCount) : 0 }
    var running: Bool { speech.isRunning || timedRunning }
    var timeLabel: String {
        let seconds = Int(elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func toggle() {
        if running || speech.isPreparing { stop(); return }
        guard !slideBusy, !presentation.isBusy else { return }
        guard wordCount > 0 else { return }
        if position >= wordCount {
            let slidesWereConnected = presentation.isConnected
            rewind()
            if slidesWereConnected { return }
        }
        lastTick = Date()
        if mode == .voice {
            tracker.resetTranscript()
            Task { await speech.start() }
        } else { timedRunning = true }
    }

    func stop() {
        cancelSlideAdvances()
        timedRunning = false
        speech.stop()
    }

    func seek(_ index: Int) {
        let resume = running
        stop()
        tracker.seek(to: max(0, min(index, wordCount)))
        position = tracker.position
        slideCues.seek(to: position)
        matchConfidence = 0
        wordFraction = 0
        if resume && position < wordCount { toggle() }
    }

    func rewind() {
        let slidesWereConnected = presentation.isConnected
        stop()
        presentation.disconnect()
        tracker.seek(to: 0)
        slideCues.rewind()
        position = 0
        elapsed = 0
        wordFraction = 0
        matchConfidence = 0
        if slidesWereConnected {
            slideError = "Notes rewound. Return your slideshow to the matching starting slide, then reconnect slide control."
        }
    }

    func tick() {
        let now = Date()
        let delta = min(now.timeIntervalSince(lastTick), 0.5)
        lastTick = now
        guard running else { return }
        elapsed += delta
        if timedRunning {
            wordFraction += delta * wordsPerMinute / 60
            if wordFraction >= 1 {
                let step = Int(wordFraction)
                wordFraction -= Double(step)
                tracker.seek(to: min(position + step, wordCount))
                position = tracker.position
                processSlideCues()
            }
        }
        if position >= wordCount {
            // A cue after the closing words must finish even after speech stops.
            timedRunning = false
            speech.stop()
        }
    }

    func connectSlides() {
        guard !running, !speech.isPreparing, !slideBusy, !presentation.isBusy else { return }
        cancelSlideAdvances()
        slideError = nil
        slideBusy = true
        let generation = slideGeneration
        slideTask = Task { [weak self] in
            guard let self else { return }
            await self.presentation.connect()
            guard self.slideGeneration == generation else { return }
            self.slideCues.seek(to: self.position)
            self.slideError = self.presentation.errorMessage
            self.slideBusy = false
            self.slideTask = nil
        }
    }

    func disconnectSlides() {
        cancelSlideAdvances()
        presentation.disconnect()
        slideError = nil
    }

    func testNextSlide() {
        guard !running, !speech.isPreparing, !slideBusy, !presentation.isBusy, presentation.isConnected else { return }
        slideError = nil
        enqueueSlideAdvances(1)
    }

    func captureSlideCueInsertionPoint() {
        slideCueInsertionRange = nil
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
           editor.isEditable, !editor.isFieldEditor, editor.string == script {
            slideCueInsertionRange = editor.selectedRange()
        }
    }

    func insertSlideCue() {
        guard !running, !speech.isPreparing else { return }
        let marker = "\n\n[[next-slide]]\n\n"
        if let range = slideCueInsertionRange,
           range.location != NSNotFound, NSMaxRange(range) <= script.utf16.count {
            script = (script as NSString).replacingCharacters(in: range, with: marker)
        } else {
            script += marker
        }
    }

    private func processSlideCues() {
        let crossed = slideCues.advance(to: position)
        guard presentation.isConnected, !crossed.isEmpty else { return }
        enqueueSlideAdvances(crossed.count)
    }

    private func enqueueSlideAdvances(_ count: Int) {
        pendingSlideAdvances += count
        guard slideTask == nil else { return }
        let generation = slideGeneration
        slideBusy = true
        slideTask = Task { [weak self] in
            guard let self else { return }
            while self.slideGeneration == generation, !Task.isCancelled,
                  self.pendingSlideAdvances > 0, self.presentation.isConnected {
                self.pendingSlideAdvances -= 1
                do {
                    try await self.presentation.advance()
                } catch {
                    guard self.slideGeneration == generation else { return }
                    self.stop()
                    self.presentation.disconnect()
                    self.slideError = "Reading paused: \(error.localizedDescription)"
                    return
                }
            }
            guard self.slideGeneration == generation else { return }
            self.pendingSlideAdvances = 0
            self.slideBusy = false
            self.slideTask = nil
        }
    }

    private func cancelSlideAdvances() {
        if slideTask != nil, pendingSlideAdvances > 0 || presentation.isBusy {
            presentation.disconnect()
            slideError = "Slide control canceled. Check the slideshow position and reconnect before using more cues."
        }
        slideGeneration = UUID()
        pendingSlideAdvances = 0
        slideTask?.cancel()
        slideTask = nil
        slideBusy = false
    }

    func openScript() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .utf8PlainText, .rtf, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text: String
            if url.pathExtension.lowercased() == "rtf" {
                text = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
            } else { text = try String(contentsOf: url, encoding: .utf8) }
            script = text
            title = url.deletingPathExtension().lastPathComponent
        } catch { documentError = "Could not open script: \(error.localizedDescription)" }
    }

    func exportScript() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = title + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try script.write(to: url, atomically: true, encoding: .utf8) }
        catch { documentError = "Could not save script: \(error.localizedDescription)" }
    }
}
