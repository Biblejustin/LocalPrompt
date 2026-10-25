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
    @Published private(set) var document: MarkdownDocument
    @Published var script: String {
        didSet {
            guard script != oldValue else { return }
            stop()
            document = MarkdownDocument(source: script)
            tracker = ScriptTracker(script: document.trackingText)
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
    private var tracker: ScriptTracker
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
        speech.$transcript.sink { [weak self] text in
            guard let self, !text.isEmpty else { return }
            let update = self.tracker.update(transcript: text)
            self.position = update.position
            self.matchConfidence = update.confidence
        }.store(in: &subscriptions)
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
        guard wordCount > 0 else { return }
        if position >= wordCount { rewind() }
        lastTick = Date()
        if mode == .voice {
            tracker.resetTranscript()
            Task { await speech.start() }
        } else { timedRunning = true }
    }

    func stop() {
        timedRunning = false
        speech.stop()
    }

    func seek(_ index: Int) {
        let resume = running
        stop()
        tracker.seek(to: max(0, min(index, wordCount)))
        position = tracker.position
        matchConfidence = 0
        wordFraction = 0
        if resume && position < wordCount { toggle() }
    }

    func rewind() {
        stop()
        tracker.seek(to: 0)
        position = 0
        elapsed = 0
        wordFraction = 0
        matchConfidence = 0
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
            }
        }
        if position >= wordCount { stop() }
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
