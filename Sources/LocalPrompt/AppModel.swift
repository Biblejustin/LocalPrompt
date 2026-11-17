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
    @Published private(set) var libraries: [NoteLibrary] = []
    @Published var selectedLibrary: NoteLibrary?
    @Published var showsLibraryManager = false
    private var libraryControllers: [String: SermonLibraryController] = [:]
    @Published private(set) var linkedSermon: LinkedSermon?
    @Published private var previousDraft: SavedDraft?
    @Published private(set) var document: MarkdownDocument
    @Published private(set) var googleNoteLinks: [GoogleNoteLink]
    @Published private(set) var openingGoogleLink = false
    @Published var script: String {
        didSet {
            guard script != oldValue else { return }
            rebuildScript()
            defaults.set(script, forKey: "draftScript")
        }
    }
    @Published var title: String {
        didSet { defaults.set(title, forKey: "draftTitle") }
    }
    @Published var position = 0
    @Published var scriptStartingSlide = 1
    @Published var mode: Mode = .voice { didSet { stop() } }
    @Published var timedRunning = false
    @Published var wordsPerMinute = 120.0
    @Published var elapsed = 0.0
    @Published var matchConfidence = 0.0
    @Published var documentError: String?
    @Published var slideError: String?
    @Published private(set) var slideConnectionMessage: String?
    @Published private(set) var slideBusy = false
    @Published private(set) var readsWithoutSlides = false
    private let defaults: UserDefaults
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        libraries = NoteLibrary.load(from: defaults)
        let draft = defaults.string(forKey: "draftScript") ?? Self.sample
        let source = defaults.data(forKey: "linkedSermon").flatMap { try? JSONDecoder().decode(LinkedSermon.self, from: $0) }
        linkedSermon = source
        previousDraft = defaults.data(forKey: "previousScriptDraft").flatMap { try? JSONDecoder().decode(SavedDraft.self, from: $0) }
        let rendered = MarkdownDocument(source: draft, obsidian: source != nil)
        script = draft
        document = rendered
        googleNoteLinks = GoogleNoteLink.links(in: draft)
        title = defaults.string(forKey: "draftTitle") ?? "Practice script"
        tracker = ScriptTracker(script: rendered.trackingText)
        slideCues = SlideCueTracker(cues: rendered.slideCues)
        SlideDiagnostics.shared.record(.appOpened, position: 0, cueCount: rendered.slideCues.count)
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
            self.slideConnectionMessage = nil
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
            .sink { [weak self] active in
                guard let self else { return }
                self.readingActivity.setActive(active)
                if active {
                    SlideDiagnostics.shared.record(.readingStarted, position: self.position, cueCount: self.document.slideCues.count)
                }
            }
            .store(in: &subscriptions)
        // AppDelegate also terminates after the last window closes. Fullscreen,
        // hiding, and minimizing do not end a reading session.
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.stop()
                self?.presentation.browser.stopListening()
                SlideDiagnostics.shared.flush()
            }
            .store(in: &subscriptions)
        // The extension's explicit tab selection is the pairing action. Reuse
        // the same guarded status handshake and cue alignment as manual setup.
        presentation.browser.onPairingRequested = { [weak self] in
            guard let self else { return "Open LocalPrompt before connecting slides." }
            guard self.presentation.target == .brave else {
                return "Choose Google Slides in Brave in LocalPrompt before connecting."
            }
            guard self.slideTask == nil, self.pendingSlideAdvances == 0,
                  !self.slideBusy, !self.presentation.isBusy else {
                return "Wait for the current slide command to finish, then connect from Brave."
            }
            // An explicit browser connection pauses reading, including a queued
            // microphone start. The guard above ensures stop cannot disconnect
            // the newly received candidate by canceling a live slide command.
            self.stop()
            self.connectSlides()
            return nil
        }
        do { try presentation.browser.startListening() }
        catch { slideError = error.localizedDescription }
    }

    var words: [ScriptWord] { tracker.words }
    var wordCount: Int { words.count }
    var progress: Double { wordCount > 0 ? Double(position) / Double(wordCount) : 0 }
    var running: Bool { speech.isRunning || timedRunning }
    var canReplaceScript: Bool { !running && !speech.isPreparing && !slideBusy && !presentation.isBusy }
    var canReadWithoutSlides: Bool {
        !document.slideCues.isEmpty && !presentation.isConnected && canReplaceScript
    }
    var needsSlideCues: Bool {
        presentation.isConnected && document.slideCues.isEmpty && (presentation.totalSlides ?? 0) > 1
    }
    private var missingSlideCuesMessage: String {
        "This deck has multiple slides, but these notes have no slide cues. Open the teleprompter copy, or choose Disconnect and read notes."
    }
    var hasPreviousDraft: Bool { previousDraft != nil }
    var timeLabel: String {
        let seconds = Int(elapsed)
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func toggle() {
        if running || speech.isPreparing { stop(); return }
        guard !slideBusy, !presentation.isBusy else { return }
        guard wordCount > 0 else { return }
        guard !needsSlideCues else {
            SlideDiagnostics.shared.record(.startBlocked, position: position, cueCount: 0)
            slideConnectionMessage = nil
            slideError = missingSlideCuesMessage
            return
        }
        if position >= wordCount {
            let slidesWereConnected = presentation.isConnected
            rewind()
            if slidesWereConnected { return }
        }
        guard document.slideCues.isEmpty || presentation.isConnected || readsWithoutSlides else {
            SlideDiagnostics.shared.record(.startBlocked, position: position, cueCount: document.slideCues.count)
            slideError = "This script has slide cues, but no slideshow is connected. Connect your slideshow, or choose Read without slides."
            return
        }
        slideConnectionMessage = nil
        lastTick = Date()
        if mode == .voice {
            tracker.resetTranscript()
            let generation = slideGeneration
            Task { [weak self] in
                guard let self, self.slideGeneration == generation,
                      !self.slideBusy, !self.presentation.isBusy else { return }
                await self.speech.start()
            }
        } else { timedRunning = true }
    }

    /// An explicit notes-only session remains intentional until the user pairs
    /// slides or changes scripts. Disconnected cues are never queued for replay.
    func startWithoutSlides() {
        guard canReadWithoutSlides else { return }
        readsWithoutSlides = true
        SlideDiagnostics.shared.record(.notesOnly, position: position, cueCount: document.slideCues.count)
        slideError = nil
        toggle()
    }

    func disconnectAndReadNotes() {
        guard needsSlideCues, canReplaceScript else { return }
        disconnectSlides()
        toggle()
    }

    func stop() {
        cancelSlideAdvances()
        timedRunning = false
        speech.stop()
    }

    func seek(_ index: Int) {
        // A second click must not race a command already sent to the deck.
        guard !slideBusy, !presentation.isBusy, !speech.isPreparing else { return }
        slideConnectionMessage = nil
        let resume = running
        let destination = max(0, min(index, wordCount))
        stop()
        guard !needsSlideCues else {
            slideError = missingSlideCuesMessage
            return
        }
        guard presentation.isConnected, presentation.supportsManualSync else {
            applySeek(to: destination, rearmCues: false)
            if resume && position < wordCount { toggle() }
            return
        }
        guard let total = presentation.totalSlides,
              let targetSlide = SlidePositionMap.slide(
                forWordAt: min(destination, wordCount - 1), wordCount: wordCount,
                cues: document.slideCues, startingSlide: scriptStartingSlide, totalSlides: total
              ) else {
            slideError = "This note section falls outside the connected deck. Check Notes start on slide and the script’s slide cues."
            return
        }
        slideError = nil
        slideBusy = true
        let generation = slideGeneration
        slideTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.presentation.goToSlide(targetSlide)
                guard self.slideGeneration == generation, !Task.isCancelled else { return }
                // A confirmed backward jump starts a new pass from that section.
                // Future cues must fire again when those words are reread.
                self.applySeek(to: destination, rearmCues: true)
                self.slideBusy = false
                self.slideTask = nil
                if resume && self.position < self.wordCount { self.toggle() }
            } catch {
                guard self.slideGeneration == generation else { return }
                self.presentation.disconnect()
                self.slideError = "Reading paused: \(error.localizedDescription)"
                self.slideBusy = false
                self.slideTask = nil
            }
        }
    }

    private func applySeek(to index: Int, rearmCues: Bool) {
        tracker.seek(to: index)
        position = tracker.position
        if rearmCues { slideCues = SlideCueTracker(cues: document.slideCues, position: position) }
        else { slideCues.seek(to: position) }
        matchConfidence = 0
        wordFraction = 0
    }

    func rewind() {
        slideConnectionMessage = nil
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
        slideConnectionMessage = nil
        slideError = nil
        slideBusy = true
        let generation = slideGeneration
        slideTask = Task { [weak self] in
            guard let self else { return }
            await self.presentation.connect()
            guard self.slideGeneration == generation else { return }
            if self.presentation.isConnected {
                // Pairing starts a fresh pass at the current notes. Browsing or
                // rehearsing while unpaired must not disable later slide cues.
                self.slideCues = SlideCueTracker(cues: self.document.slideCues, position: self.position)
                self.readsWithoutSlides = false
                self.slideConnectionMessage = self.needsSlideCues ? nil : "Slides connected. Check the matching slide, then press Start reading."
            }
            self.slideError = self.needsSlideCues ? self.missingSlideCuesMessage : self.presentation.errorMessage
            self.slideBusy = false
            self.slideTask = nil
        }
    }

    func disconnectSlides() {
        if running || speech.isPreparing { stop() }
        else { cancelSlideAdvances() }
        presentation.disconnect()
        slideConnectionMessage = nil
        slideError = nil
    }

    func testNextSlide() {
        guard !running, !speech.isPreparing, !slideBusy, !presentation.isBusy, presentation.isConnected else { return }
        slideError = nil
        enqueueSlideAdvances(1)
    }

    func canMoveSlide(by offset: Int) -> Bool {
        manualSlideDestination(by: offset) != nil
    }

    var canMatchNotesToSlide: Bool {
        presentation.supportsManualSync && presentation.isConnected && wordCount > 0 &&
        !needsSlideCues && !slideBusy && !presentation.isBusy && !speech.isPreparing
    }

    /// Read the actual slide before moving notes; never move the deck to a
    /// cached position when the user asks to follow the slides instead.
    func matchNotesToSlide() {
        guard canMatchNotesToSlide else { return }
        let resume = running
        stop()
        slideConnectionMessage = nil
        slideError = nil
        slideBusy = true
        let generation = slideGeneration
        slideTask = Task { [weak self] in
            guard let self else { return }
            do {
                let current = try await self.presentation.refreshPosition()
                guard self.slideGeneration == generation, !Task.isCancelled else { return }
                guard let total = self.presentation.totalSlides,
                      let destination = SlidePositionMap.firstWord(
                        forSlide: current, wordCount: self.wordCount,
                        cues: self.document.slideCues, startingSlide: self.scriptStartingSlide,
                        totalSlides: total
                      ) else {
                    self.slideError = "Slide \(current) has no matching notes. Check Notes start on slide and the script’s slide cues."
                    self.slideBusy = false
                    self.slideTask = nil
                    return
                }
                self.applySeek(to: destination, rearmCues: true)
                self.slideBusy = false
                self.slideTask = nil
                if resume { self.toggle() }
            } catch {
                guard self.slideGeneration == generation else { return }
                self.presentation.disconnect()
                self.slideError = "Reading paused: \(error.localizedDescription)"
                self.slideBusy = false
                self.slideTask = nil
            }
        }
    }

    private func manualSlideDestination(by offset: Int) -> Int? {
        guard offset == -1 || offset == 1,
              presentation.supportsManualSync, presentation.isConnected,
              !slideBusy, !presentation.isBusy, !speech.isPreparing,
              let current = presentation.currentSlidePosition,
              let total = presentation.totalSlides,
              current >= 1, current <= total else { return nil }
        guard offset < 0 ? current > 1 : current < total else { return nil }
        return current + offset
    }

    /// A manual slide correction leaves notes and consumed cues in place.
    /// Pause recognition until the deck confirms so automatic cues cannot race it.
    func moveSlide(by offset: Int) {
        guard let destination = manualSlideDestination(by: offset) else { return }
        let resume = running
        stop()
        slideConnectionMessage = nil
        slideError = nil
        slideBusy = true
        let generation = slideGeneration
        slideTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.presentation.goToSlide(destination)
                guard self.slideGeneration == generation, !Task.isCancelled else { return }
                self.slideBusy = false
                self.slideTask = nil
                if resume && self.position < self.wordCount { self.toggle() }
            } catch {
                guard self.slideGeneration == generation else { return }
                self.presentation.disconnect()
                self.slideError = "Reading paused: \(error.localizedDescription)"
                self.slideBusy = false
                self.slideTask = nil
            }
        }
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
        guard presentation.isConnected else {
            if !readsWithoutSlides && !document.slideCues.isEmpty {
                stop()
                slideError = "Slide connection was lost. Reading paused. Reconnect your slideshow, or choose Read without slides."
            }
            return
        }
        let crossed = slideCues.advance(to: position)
        guard !crossed.isEmpty else { return }
        SlideDiagnostics.shared.record(.cueCrossed, position: position, cueCount: crossed.count)
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
        guard canReplaceScript else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .utf8PlainText, .rtf, UTType(filenameExtension: "md") ?? .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text: String
            if url.pathExtension.lowercased() == "rtf" {
                text = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
            } else { text = try String(contentsOf: url, encoding: .utf8) }
            try replaceDraft(text: text, title: url.deletingPathExtension().lastPathComponent, source: nil)
        } catch { documentError = "Could not open script: \(error.localizedDescription)" }
    }

    func openGoogleLink(_ link: GoogleNoteLink) {
        guard !openingGoogleLink, googleNoteLinks.contains(link) else { return }
        let workspace = NSWorkspace.shared
        guard let browser = workspace.urlForApplication(withBundleIdentifier: "com.brave.Browser") else {
            if !workspace.open(link.url) { documentError = "Could not open the Google file in your browser." }
            return
        }
        openingGoogleLink = true
        workspace.open([link.url], withApplicationAt: browser, configuration: .init()) { [weak self] _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.openingGoogleLink = false
                if let error { self.documentError = "Could not open the Google file: \(error.localizedDescription)" }
            }
        }
    }

    func library(for info: NoteLibrary) -> SermonLibraryController {
        if let existing = libraryControllers[info.id] { return existing }
        let controller = SermonLibraryController(library: info, defaults: defaults)
        libraryControllers[info.id] = controller
        return controller
    }

    /// The folder a saved library points at, without creating one for a draft.
    func folderName(forLibrary id: String) -> String? {
        guard let info = libraries.first(where: { $0.id == id }) else { return nil }
        return library(for: info).folderURL?.lastPathComponent
    }

    /// Closes any open library picker before showing the editor.
    func editLibraries() {
        guard selectedLibrary != nil else { showsLibraryManager = true; return }
        selectedLibrary = nil
        DispatchQueue.main.async { [weak self] in self?.showsLibraryManager = true }
    }

    /// Saves the edited list. Removed libraries forget their folder and filter;
    /// the notes themselves are never touched.
    func updateLibraries(_ edited: [NoteLibrary]) {
        let kept = Array(edited.prefix(NoteLibrary.maximumCount))
        for removed in libraries where !kept.contains(where: { $0.id == removed.id }) {
            NoteLibrary.forget(removed, in: defaults)
            libraryControllers[removed.id] = nil
            if selectedLibrary?.id == removed.id { selectedLibrary = nil }
        }
        libraries = kept
        NoteLibrary.save(kept, to: defaults)
        for info in kept { libraryControllers[info.id]?.update(info) }
    }

    func openNote(_ entry: SermonLibraryEntry, from library: SermonLibraryController) -> Bool {
        guard canReplaceScript, let folder = library.folderURL else { return false }
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        do {
            let text = try SermonLibraryIndex.read(entry, folderURL: folder)
            let source = try LinkedSermon(fileURL: entry.fileURL, folderURL: folder)
            try replaceDraft(text: text, title: entry.title, source: source)
            return true
        } catch { documentError = "Could not open note: \(error.localizedDescription)"; return false }
    }

    func reloadSermon() {
        guard canReplaceScript, let linkedSermon else { return }
        do {
            let urls = try linkedSermon.resolve()
            let access = urls.folder.startAccessingSecurityScopedResource()
            defer { if access { urls.folder.stopAccessingSecurityScopedResource() } }
            let text = try SermonLibraryIndex.read(fileURL: urls.file, folderURL: urls.folder)
            // A refresh with no source changes should not reset a reading pass.
            guard text != script else { return }
            let source = try LinkedSermon(fileURL: urls.file, folderURL: urls.folder)
            try replaceDraft(text: text, title: source.name, source: source)
        } catch { documentError = "Could not reload note. Current draft kept. \(error.localizedDescription)" }
    }

    func restorePreviousDraft() {
        guard canReplaceScript, let previousDraft else { return }
        do { try replaceDraft(text: previousDraft.script, title: previousDraft.title, source: previousDraft.source) }
        catch { documentError = "Could not restore draft: \(error.localizedDescription)" }
    }

    private struct SavedDraft: Codable {
        let script: String
        let title: String
        let source: LinkedSermon?
    }

    private func replaceDraft(text: String, title: String, source: LinkedSermon?) throws {
        let previous = SavedDraft(script: script, title: self.title, source: linkedSermon)
        // Encode everything before replacing a draft. Import failures leave it intact.
        let previousData = try JSONEncoder().encode(previous)
        let sourceData = try source.map { try JSONEncoder().encode($0) }
        previousDraft = previous
        defaults.set(previousData, forKey: "previousScriptDraft")
        linkedSermon = source
        defaults.set(sourceData, forKey: "linkedSermon")
        let unchanged = script == text
        script = text
        if unchanged { rebuildScript() }
        self.title = title
        documentError = nil
    }

    private func rebuildScript() {
        stop()
        presentation.disconnect()
        slideConnectionMessage = nil
        slideCueInsertionRange = nil
        document = MarkdownDocument(source: script, obsidian: linkedSermon != nil)
        googleNoteLinks = GoogleNoteLink.links(in: script)
        tracker = ScriptTracker(script: document.trackingText)
        slideCues = SlideCueTracker(cues: document.slideCues)
        readsWithoutSlides = false
        scriptStartingSlide = 1
        position = 0
        elapsed = 0
        wordFraction = 0
        matchConfidence = 0
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
