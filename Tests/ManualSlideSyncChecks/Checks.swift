import Foundation

/// Integration checks compile the actual AppModel with a controllable slide
/// transport. No microphone, live presentation, vault, or user preferences.
@main
struct ManualSlideSyncChecks {
    static let first = "Amber lanterns illuminate winding pathways beyond quiet gardens"
    static let second = "Harbor workers carefully unload wooden crates before sunrise"
    static let third = "Distant mountain travelers share warm meals beside campfires"
    static let script = "\(first)\n\n[[next-slide]]\n\n\(second)\n\n[[next-slide]]\n\n\(third)"
    @MainActor static var checks = 0

    @MainActor
    static func main() async throws {
        try await forwardSelection()
        try await backwardSelectionRearmsCues()
        try await failedSelection()
        try await canceledSelection()
        try await legacySeeking()
        try await offsetsAndBounds()
        try await queuedSpeechStartCannotRaceSelection()
        try await disconnectedStartRequiresExplicitNotesOnly()
        try await pairingRearmsPreviewedCues()
        try await pairingAfterNotesOnlyStartsAtCurrentPosition()
        try await rewindCannotSilentlyDropSlides()
        try await connectionLossCannotSilentlyDropSlides()
        try await browserPairingPausesReadingWithoutLosingCandidate()
        try await browserPairingRejectsActiveSlideCommands()
        try await zeroCueDeckReadiness()
        try await slideButtonsMoveOnlyDeck()
        try await slideButtonGuards()
        try await slideButtonsPreserveReadingAndCues()
        try await slideButtonFailureAndCancellation()
        try await slideButtonCancelsQueuedSpeechStart()
        try await matchNotesUsesFreshSlide()
        try await matchNotesGuardsAndOffsets()
        try await matchNotesPreservesReadingAndRearmsCues()
        try await matchNotesFailureAndCancellation()
        print("Manual slide sync: \(checks) checks passed")
    }

    @MainActor
    static func fixture(connected: Bool = true) -> AppModel {
        let storage = MemoryDefaults(suiteName: "LocalPromptManualSyncChecks-\(UUID().uuidString)")!
        storage.values = ["draftScript": script, "draftTitle": "Synthetic slide sync"]
        let model = AppModel(defaults: storage)
        model.presentation.isConnected = connected
        return model
    }

    @MainActor
    static func expect(_ condition: @autoclosure () -> Bool, _ label: String) throws {
        guard condition() else { throw Failure(description: label) }
        checks += 1
    }

    @MainActor
    static func until(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw Failure(description: "Timed out waiting for model event")
    }

    @MainActor
    static func forwardSelection() async throws {
        let model = fixture()
        try expect(model.wordCount == 24 && model.document.slideCues.count == 2, "Synthetic three-section fixture")
        model.seek(20)
        try expect(model.slideBusy && model.position == 0, "Click reserves sync before async dispatch")
        model.seek(10)
        try await until { model.presentation.hasPendingGoTo }
        try expect(model.presentation.goToRequests == [3], "Forward click selects destination directly and busy click is ignored")
        try expect(model.position == 0 && !model.running, "Notes stay put until browser acknowledgement")
        try expect(model.presentation.advanceCalls == 0, "Click sends no next-slide commands")
        model.presentation.finishGoTo()
        try await until { !model.slideBusy }
        try expect(model.position == 20 && model.presentation.currentSlidePosition == 3, "Confirmed selection moves notes and slide together")
        try expect(!model.running && model.speech.startCalls == 0, "Paused selection stays paused")
        model.toggle()
        try await until { model.running }
        model.speech.transcript = model.words[20..<24].map(\.text).joined(separator: " ")
        try await until { !model.slideBusy }
        try expect(model.position == 24 && model.presentation.advanceCalls == 0, "Skipped earlier cues do not replay after forward selection")
        model.stop()
    }

    @MainActor
    static func backwardSelectionRearmsCues() async throws {
        let model = fixture()
        model.toggle()
        try await until { model.running }
        model.speech.transcript = "\(first) \(second)"
        try await until { !model.slideBusy && model.presentation.advanceCalls == 2 }
        try expect(model.position == 16 && model.presentation.currentSlidePosition == 3, "Natural reading advances both crossed cues")
        model.seek(2)
        try await until { model.presentation.hasPendingGoTo }
        try expect(!model.running && model.position == 16, "Running backward click pauses before moving notes")
        try expect(model.presentation.goToRequests == [1], "Backward click selects earlier slide directly")
        model.presentation.finishGoTo()
        try await until { !model.slideBusy && model.running }
        try expect(model.position == 2 && model.speech.startCalls == 2, "Successful selection resumes previous voice session with new transcript")
        model.speech.transcript = model.words[2..<8].map(\.text).joined(separator: " ")
        try await until { !model.slideBusy && model.presentation.advanceCalls == 3 }
        try expect(model.position == 8 && model.presentation.currentSlidePosition == 2, "Rereading after backward selection rearms future cue")
        model.stop()
    }

    @MainActor
    static func failedSelection() async throws {
        let model = fixture()
        model.toggle()
        try await until { model.running }
        model.speech.transcript = "Amber lanterns illuminate"
        try expect(model.position == 3, "Reading establishes position before failed selection")
        model.seek(10)
        try await until { model.presentation.hasPendingGoTo }
        model.presentation.finishGoTo(success: false)
        try await until { !model.slideBusy }
        try expect(model.position == 3, "Failed selection keeps original notes position")
        try expect(!model.running && model.speech.startCalls == 1, "Failed selection never resumes reading")
        try expect(!model.presentation.isConnected && model.slideError != nil, "Failure disconnects with visible error")
        try expect(model.presentation.goToRequests == [2] && model.presentation.advanceCalls == 0, "Failed selection is not retried")
    }

    @MainActor
    static func canceledSelection() async throws {
        let model = fixture()
        model.seek(10)
        try await until { model.presentation.hasPendingGoTo }
        model.rewind()
        try expect(model.position == 0 && !model.presentation.isConnected && !model.slideBusy, "Rewind cancels pending selection and disconnects")
        model.presentation.finishGoTo()
        for _ in 0..<10 { await Task.yield() }
        try expect(model.position == 0 && !model.running && !model.slideBusy, "Late acknowledgement cannot move rewound notes or resume")
        try expect(!model.presentation.isConnected, "Late acknowledgement cannot restore connection")
    }

    @MainActor
    static func legacySeeking() async throws {
        let unpaired = fixture(connected: false)
        unpaired.mode = .timed
        unpaired.startWithoutSlides()
        unpaired.seek(10)
        try expect(unpaired.position == 10 && unpaired.running, "Unpaired timed seek retains reading behavior")
        try expect(unpaired.presentation.goToRequests.isEmpty && unpaired.presentation.advanceCalls == 0, "Unpaired seek sends no presentation command")
        unpaired.seek(999)
        try expect(unpaired.position == 24 && !unpaired.running, "Seek to end clamps and stays paused")
        unpaired.seek(-10)
        try expect(unpaired.position == 0, "Negative seek clamps to beginning")

        let powerpoint = fixture()
        powerpoint.presentation.target = .powerpoint
        powerpoint.seek(10)
        try expect(powerpoint.position == 10 && !powerpoint.slideBusy, "PowerPoint keeps immediate legacy seek")
        try expect(powerpoint.presentation.goToRequests.isEmpty, "PowerPoint seek does not invoke unsupported slide selection")

        let busy = fixture()
        busy.presentation.isBusy = true
        busy.seek(10)
        try expect(busy.position == 0 && busy.presentation.goToRequests.isEmpty, "Transport busy blocks click")
        busy.presentation.isBusy = false
        busy.speech.isPreparing = true
        busy.seek(10)
        try expect(busy.position == 0 && busy.presentation.goToRequests.isEmpty, "Speech preparation blocks click")
    }

    @MainActor
    static func offsetsAndBounds() async throws {
        let offset = fixture()
        offset.scriptStartingSlide = 3
        offset.seek(10)
        try await until { offset.presentation.hasPendingGoTo }
        try expect(offset.presentation.goToRequests == [4], "Starting slide offset maps middle section")
        offset.presentation.finishGoTo()
        try await until { !offset.slideBusy }
        offset.seek(999)
        try await until { offset.presentation.hasPendingGoTo }
        try expect(offset.presentation.goToRequests == [4, 5], "End click uses final readable section with offset")
        offset.presentation.finishGoTo()
        try await until { !offset.slideBusy }
        try expect(offset.position == 24 && !offset.running, "Confirmed end click stays paused")

        for start in [0, 7] {
            let invalid = fixture()
            invalid.scriptStartingSlide = start
            invalid.seek(0)
            try expect(invalid.position == 0 && invalid.slideError != nil && invalid.presentation.goToRequests.isEmpty, "Invalid starting offset \(start) never dispatches")
        }
        let beyond = fixture()
        beyond.scriptStartingSlide = 5
        beyond.seek(20)
        try expect(beyond.position == 0 && beyond.slideError != nil && beyond.presentation.goToRequests.isEmpty, "Section beyond deck leaves notes unchanged")
        let unknown = fixture()
        unknown.presentation.totalSlides = nil
        unknown.seek(10)
        try expect(unknown.slideError != nil && unknown.presentation.goToRequests.isEmpty, "Unknown deck size prevents selection")
        let empty = fixture(connected: false)
        empty.script = ""
        empty.presentation.isConnected = true
        empty.seek(0)
        try expect(empty.position == 0 && empty.slideError != nil && empty.presentation.goToRequests.isEmpty, "Empty script does not dispatch invalid slide")
    }

    @MainActor
    static func queuedSpeechStartCannotRaceSelection() async throws {
        let model = fixture()
        model.toggle()
        model.seek(10)
        try await until { model.presentation.hasPendingGoTo }
        try expect(!model.running && model.speech.startCalls == 0, "Queued speech start cannot run during slide selection")
        model.presentation.finishGoTo()
        try await until { !model.slideBusy }
        try expect(model.position == 10 && !model.running, "Selection does not resume a session that never started")
    }

    @MainActor
    static func disconnectedStartRequiresExplicitNotesOnly() async throws {
        let model = fixture(connected: false)
        try expect(model.canReadWithoutSlides && !model.readsWithoutSlides, "Unpaired cue script offers explicit notes-only reading")
        model.toggle()
        for _ in 0..<10 { await Task.yield() }
        try expect(!model.running && model.speech.startCalls == 0 && model.slideError != nil, "Voice start blocks disconnected slide cues before opening microphone")
        model.mode = .timed
        model.toggle()
        try expect(!model.running, "Timed start also blocks disconnected slide cues")
        model.mode = .voice
        model.startWithoutSlides()
        try await until { model.running }
        try expect(model.readsWithoutSlides && model.slideError == nil, "Explicit notes-only start clears warning and starts reading")
        model.speech.transcript = "\(first) \(second)"
        try expect(model.position == 16 && model.presentation.advanceCalls == 0, "Notes-only reading moves text without slide commands")
        try expect(!model.canReadWithoutSlides, "Notes-only action cannot restart active reading")
        model.stop()
        model.toggle()
        try await until { model.running }
        try expect(model.readsWithoutSlides && model.speech.startCalls == 2, "Pause and resume preserve explicit notes-only intent")
        model.stop()
        model.script = "Plain standalone notes without any slide commands"
        try expect(!model.readsWithoutSlides && !model.canReadWithoutSlides, "Changing script resets notes-only intent")
        model.toggle()
        try await until { model.running }
        try expect(model.slideError == nil, "Zero-cue scripts still start without pairing")
        model.stop()

        let busy = fixture(connected: false)
        busy.presentation.isBusy = true
        busy.startWithoutSlides()
        try expect(!busy.readsWithoutSlides && busy.speech.startCalls == 0, "Busy transport prevents notes-only bypass")
        busy.presentation.isBusy = false
        busy.speech.isPreparing = true
        busy.startWithoutSlides()
        try expect(!busy.readsWithoutSlides, "Speech preparation prevents notes-only bypass")
        let connected = fixture()
        connected.startWithoutSlides()
        try expect(!connected.readsWithoutSlides && connected.speech.startCalls == 0, "Paired reading cannot opt out through disconnected action")
    }

    @MainActor
    static func pairingRearmsPreviewedCues() async throws {
        let model = fixture(connected: false)
        model.seek(20)
        model.seek(0)
        model.connectSlides()
        try await until { !model.slideBusy }
        model.toggle()
        try await until { model.running }
        model.speech.transcript = "\(first) \(second)"
        try await until { !model.slideBusy && model.presentation.advanceCalls == 2 }
        try expect(model.position == 16 && model.presentation.currentSlidePosition == 3, "Pairing rearms cues skipped during unpaired preview")
        model.stop()

        let rehearsal = fixture(connected: false)
        rehearsal.startWithoutSlides()
        try await until { rehearsal.running }
        rehearsal.speech.transcript = "\(first) \(second)"
        rehearsal.stop()
        rehearsal.seek(0)
        rehearsal.connectSlides()
        try await until { !rehearsal.slideBusy }
        try expect(!rehearsal.readsWithoutSlides, "Successful pairing clears notes-only intent")
        rehearsal.toggle()
        try await until { rehearsal.running }
        rehearsal.speech.transcript = "\(first) \(second)"
        try await until { !rehearsal.slideBusy && rehearsal.presentation.advanceCalls == 2 }
        try expect(rehearsal.position == 16, "Pairing after notes-only rehearsal preserves future cues for rereading")
        rehearsal.stop()
    }

    @MainActor
    static func pairingAfterNotesOnlyStartsAtCurrentPosition() async throws {
        let model = fixture(connected: false)
        model.startWithoutSlides()
        try await until { model.running }
        model.speech.transcript = first
        model.stop()
        model.presentation.currentSlidePosition = 2
        model.connectSlides()
        try await until { !model.slideBusy }
        try expect(model.presentation.advanceCalls == 0 && model.position == 8, "Pairing after notes-only reading does not replay crossed cue")
        model.toggle()
        try await until { model.running }
        model.speech.transcript = second
        try await until { !model.slideBusy && model.presentation.advanceCalls == 1 }
        try expect(model.position == 16 && model.presentation.currentSlidePosition == 3, "Only subsequent cue fires after pairing at current position")
        model.stop()
    }

    @MainActor
    static func rewindCannotSilentlyDropSlides() async throws {
        let model = fixture()
        model.rewind()
        model.slideError = nil
        model.toggle()
        for _ in 0..<10 { await Task.yield() }
        try expect(!model.running && model.speech.startCalls == 0 && model.slideError != nil, "Start after disconnected rewind blocks even if earlier warning was dismissed")
        model.startWithoutSlides()
        try await until { model.running }
        try expect(model.readsWithoutSlides && !model.presentation.isConnected, "User can explicitly continue notes-only after rewind")
        model.stop()
    }

    @MainActor
    static func connectionLossCannotSilentlyDropSlides() async throws {
        let lost = fixture()
        lost.toggle()
        try await until { lost.running }
        lost.presentation.isConnected = false
        lost.speech.transcript = first
        try expect(!lost.running && lost.slideError != nil && lost.presentation.advanceCalls == 0, "Silent connection loss pauses at next voice update before issuing any cue")
        lost.toggle()
        for _ in 0..<10 { await Task.yield() }
        try expect(!lost.running && lost.speech.startCalls == 1, "Unexpected disconnect cannot silently restart reading")
        lost.startWithoutSlides()
        try await until { lost.running }
        lost.speech.transcript = second
        try expect(lost.running && lost.position == 16 && lost.presentation.advanceCalls == 0, "Explicit notes-only recovery permits reading after connection loss")
        lost.stop()

        let manual = fixture()
        manual.toggle()
        try await until { manual.running }
        manual.disconnectSlides()
        try expect(!manual.running && !manual.presentation.isConnected, "Manual disconnect pauses active reading")
        try expect(manual.canReadWithoutSlides && !manual.readsWithoutSlides, "Manual disconnect still requires explicit notes-only intent")
        manual.presentation.isConnected = true
        manual.speech.isPreparing = true
        manual.disconnectSlides()
        try expect(!manual.speech.isPreparing && !manual.presentation.isConnected, "Manual disconnect cancels microphone preparation")
    }

    @MainActor
    static func browserPairingPausesReadingWithoutLosingCandidate() async throws {
        for mode in [AppModel.Mode.voice, .timed] {
            let model = fixture(connected: false)
            model.mode = mode
            model.seek(3)
            model.startWithoutSlides()
            try await until { model.running }
            let starts = model.speech.startCalls
            let disconnects = model.presentation.disconnectCalls
            let rejection = model.presentation.browser.onPairingRequested?()
            try expect(rejection == nil && !model.running && model.slideBusy, "Browser connect pauses \(mode.rawValue) and reserves pairing immediately")
            try expect(model.position == 3 && model.presentation.disconnectCalls == disconnects, "Browser connect preserves \(mode.rawValue) position and newly received candidate")
            try await until { !model.slideBusy }
            try expect(model.presentation.isConnected && model.presentation.connectCalls == 1, "Browser connect completes one fresh status handshake for \(mode.rawValue)")
            try expect(!model.running && model.speech.startCalls == starts && !model.readsWithoutSlides, "Pairing \(mode.rawValue) stays paused and clears notes-only intent")
            try expect(model.presentation.advanceCalls == 0 && model.presentation.goToRequests.isEmpty, "Pairing \(mode.rawValue) never moves deck")
            try expect(model.slideConnectionMessage != nil && model.slideError == nil, "Successful \(mode.rawValue) pairing exposes resume instruction")
            model.toggle()
            try await until { model.running }
            try expect(model.slideConnectionMessage == nil, "Starting \(mode.rawValue) clears pairing instruction")
            model.stop()
        }

        let preparing = fixture(connected: false)
        preparing.seek(3)
        preparing.speech.isPreparing = true
        let preparationReply = preparing.presentation.browser.onPairingRequested?()
        try expect(preparationReply == nil && !preparing.speech.isPreparing && preparing.position == 3, "Browser pairing cancels microphone preparation and preserves notes")
        try await until { !preparing.slideBusy }
        try expect(preparing.presentation.isConnected && preparing.presentation.disconnectCalls == 0 && !preparing.running, "Preparation cancellation retains candidate and leaves successful pairing paused")

        let queued = fixture(connected: false)
        queued.seek(3)
        queued.startWithoutSlides()
        let queuedReply = queued.presentation.browser.onPairingRequested?()
        try expect(queuedReply == nil, "Browser pairing accepts a queued microphone start")
        try await until { !queued.slideBusy }
        for _ in 0..<10 { await Task.yield() }
        try expect(queued.speech.startCalls == 0 && !queued.running && queued.position == 3, "Queued microphone task cannot resume after pairing")
        try expect(queued.presentation.disconnectCalls == 0 && queued.presentation.connectCalls == 1, "Canceling queued speech leaves candidate intact")

        let failed = fixture(connected: false)
        failed.startWithoutSlides()
        try await until { failed.running }
        failed.presentation.connectSucceeds = false
        try expect(failed.presentation.browser.onPairingRequested?() == nil, "Reading pause permits a pairing attempt even if handshake later fails")
        try await until { !failed.slideBusy }
        try expect(!failed.running && !failed.presentation.isConnected && failed.slideConnectionMessage == nil && failed.slideError != nil, "Failed pairing stays paused with error instead of success instruction")
    }

    @MainActor
    static func browserPairingRejectsActiveSlideCommands() async throws {
        let model = fixture()
        model.seek(10)
        try await until { model.presentation.hasPendingGoTo }
        let disconnects = model.presentation.disconnectCalls
        let rejection = model.presentation.browser.onPairingRequested?()
        try expect(rejection != nil && model.presentation.connectCalls == 0, "Browser pairing rejects a slide selection already in flight")
        try expect(model.presentation.hasPendingGoTo && model.presentation.disconnectCalls == disconnects, "Rejected pairing does not cancel active selection or disconnect candidate")
        try expect(model.presentation.goToRequests == [2] && model.presentation.advanceCalls == 0, "Rejected pairing dispatches no extra slide commands")
        model.presentation.finishGoTo()
        try await until { !model.slideBusy }
        try expect(model.position == 10, "Original selection completes after pairing rejection")

        let powerpoint = fixture(connected: false)
        powerpoint.presentation.target = .powerpoint
        powerpoint.startWithoutSlides()
        try await until { powerpoint.running }
        try expect(powerpoint.presentation.browser.onPairingRequested?() != nil && powerpoint.running, "Wrong target still rejects browser pairing without stopping selected mode")
        try expect(powerpoint.presentation.connectCalls == 0 && powerpoint.presentation.disconnectCalls == 0, "Wrong target rejection sends no connection or slide command")
        powerpoint.stop()
    }

    @MainActor
    static func zeroCueDeckReadiness() async throws {
        let model = fixture(connected: false)
        model.script = "\(first) \(second) \(third)"
        model.presentation.totalSlides = 114
        model.connectSlides()
        try await until { !model.slideBusy }
        try expect(model.presentation.isConnected && model.needsSlideCues, "Multi-slide deck pairing remains connected but detects missing note cues")
        try expect(!model.running && model.slideConnectionMessage == nil && model.slideError != nil, "Zero-cue pairing shows warning instead of ready-to-read success")
        let warning = model.slideError
        model.slideError = nil
        model.seek(10)
        try expect(model.position == 0 && model.presentation.goToRequests.isEmpty && model.slideError == warning, "Clicking zero-cue multi-slide notes cannot falsely map every word to slide one")
        model.slideError = nil
        model.toggle()
        for _ in 0..<10 { await Task.yield() }
        try expect(!model.running && model.speech.startCalls == 0 && model.slideError == warning, "Voice start cannot bypass missing cues after dismissing warning")
        model.mode = .timed
        model.toggle()
        try expect(!model.running, "Timed start also blocks paired multi-slide deck without cues")
        model.mode = .voice
        let disconnects = model.presentation.disconnectCalls
        model.disconnectAndReadNotes()
        try await until { model.running }
        try expect(!model.presentation.isConnected && !model.needsSlideCues && model.presentation.disconnectCalls == disconnects + 1, "Explicit notes-only recovery disconnects deck once and starts reading")
        try expect(model.slideError == nil && model.presentation.advanceCalls == 0 && model.presentation.goToRequests.isEmpty, "Explicit notes-only recovery clears warning without moving slides")
        model.stop()

        for total: Int? in [1, nil] {
            let allowed = fixture(connected: false)
            allowed.script = first
            allowed.presentation.totalSlides = total
            allowed.connectSlides()
            try await until { !allowed.slideBusy }
            try expect(!allowed.needsSlideCues && allowed.slideError == nil && allowed.slideConnectionMessage != nil, "Single or unknown-size deck preserves existing pairing behavior")
            allowed.toggle()
            try await until { allowed.running }
            try expect(allowed.presentation.isConnected, "Single or unknown-size deck still permits zero-cue reading")
            allowed.stop()
            if total == 1 {
                allowed.seek(3)
                try await until { allowed.presentation.hasPendingGoTo }
                try expect(allowed.presentation.goToRequests == [1], "Single-slide zero-cue seeking still maps to its only slide")
                allowed.presentation.finishGoTo()
                try await until { !allowed.slideBusy }
                try expect(allowed.position == 3, "Confirmed single-slide zero-cue seek still moves notes")
            }
        }

        let standalone = fixture(connected: false)
        standalone.script = first
        standalone.toggle()
        try await until { standalone.running }
        try expect(!standalone.needsSlideCues && standalone.slideError == nil, "Unpaired zero-cue notes remain normal standalone reading")
        standalone.stop()

        let busy = fixture(connected: false)
        busy.script = first
        busy.presentation.isConnected = true
        busy.presentation.isBusy = true
        let beforeBusyDisconnects = busy.presentation.disconnectCalls
        busy.disconnectAndReadNotes()
        try expect(!busy.running && busy.presentation.isConnected && busy.presentation.disconnectCalls == beforeBusyDisconnects, "Busy transport prevents disconnect-and-read action")
        busy.presentation.isBusy = false
        busy.speech.isPreparing = true
        busy.disconnectAndReadNotes()
        try expect(busy.presentation.isConnected && busy.presentation.disconnectCalls == beforeBusyDisconnects, "Microphone preparation prevents disconnect-and-read action")
        busy.speech.isPreparing = false
        busy.presentation.totalSlides = 1
        busy.disconnectAndReadNotes()
        try expect(!busy.running && busy.presentation.isConnected, "Disconnect-and-read action only applies to missing-cue multi-slide decks")
    }

    @MainActor
    static func slideButtonsMoveOnlyDeck() async throws {
        let model = fixture(connected: false)
        model.seek(3)
        model.presentation.isConnected = true
        try expect(model.canMoveSlide(by: 1) && !model.canMoveSlide(by: -1), "Opening slide enables Next but disables Previous")
        model.moveSlide(by: 1)
        try expect(model.slideBusy && model.position == 3 && !model.running, "Next reserves slide command without moving paused notes")
        model.moveSlide(by: 1)
        model.moveSlide(by: -1)
        try await until { model.presentation.hasPendingGoTo }
        try expect(model.presentation.goToRequests == [2] && !model.canMoveSlide(by: 1), "Repeated slide taps cannot race pending command")
        model.presentation.finishGoTo()
        try await until { !model.slideBusy }
        try expect(model.presentation.currentSlidePosition == 2 && model.position == 3, "Confirmed Next changes slide only")
        try expect(!model.running && model.speech.startCalls == 0, "Paused Next stays paused")
        model.moveSlide(by: -1)
        try await until { model.presentation.hasPendingGoTo }
        try expect(model.presentation.goToRequests == [2, 1], "Previous targets exact adjacent slide")
        model.presentation.finishGoTo()
        try await until { !model.slideBusy }
        try expect(model.presentation.currentSlidePosition == 1 && model.position == 3 && !model.running, "Confirmed Previous preserves paused notes")
        try expect(model.presentation.advanceCalls == 0, "Slide buttons never replay cue advances")
    }

    @MainActor
    static func slideButtonGuards() async throws {
        let model = fixture()
        for offset in [-2, 0, 2, Int.min, Int.max] {
            try expect(!model.canMoveSlide(by: offset), "Only adjacent slide offsets are accepted: \(offset)")
            model.moveSlide(by: offset)
        }
        model.moveSlide(by: -1)
        model.presentation.currentSlidePosition = 6
        try expect(model.canMoveSlide(by: -1) && !model.canMoveSlide(by: 1), "Final slide enables Previous and disables Next")
        model.moveSlide(by: 1)
        model.presentation.currentSlidePosition = 3
        model.presentation.isConnected = false
        try expect(!model.canMoveSlide(by: 1) && !model.canMoveSlide(by: -1), "Disconnected deck disables both directions")
        model.moveSlide(by: 1)
        model.presentation.isConnected = true
        model.presentation.target = .powerpoint
        try expect(!model.canMoveSlide(by: 1), "Unsupported presentation adapter cannot use direct slide buttons")
        model.moveSlide(by: 1)
        model.presentation.target = .brave
        model.presentation.isBusy = true
        try expect(!model.canMoveSlide(by: 1), "Busy transport disables slide buttons")
        model.moveSlide(by: 1)
        model.presentation.isBusy = false
        model.speech.isPreparing = true
        try expect(!model.canMoveSlide(by: 1), "Microphone preparation disables slide buttons")
        model.moveSlide(by: 1)
        model.speech.isPreparing = false
        for current: Int? in [nil, 0, -1, 7, Int.max] {
            model.presentation.currentSlidePosition = current
            try expect(!model.canMoveSlide(by: 1) && !model.canMoveSlide(by: -1), "Unknown or invalid slide position cannot dispatch: \(String(describing: current))")
            model.moveSlide(by: 1)
        }
        model.presentation.currentSlidePosition = 1
        for total: Int? in [nil, 0, -1] {
            model.presentation.totalSlides = total
            try expect(!model.canMoveSlide(by: 1), "Unknown or invalid deck size disables slide buttons")
            model.moveSlide(by: 1)
        }
        for _ in 0..<10 { await Task.yield() }
        try expect(model.presentation.goToRequests.isEmpty && !model.slideBusy && model.position == 0, "Rejected slide taps send no commands or move notes")

        let noCues = fixture(connected: false)
        noCues.script = first
        noCues.presentation.isConnected = true
        try expect(noCues.needsSlideCues && noCues.canMoveSlide(by: 1), "Manual slide buttons remain usable without a cue map")
        noCues.moveSlide(by: 1)
        try await until { noCues.presentation.hasPendingGoTo }
        noCues.presentation.finishGoTo()
        try await until { !noCues.slideBusy }
        try expect(noCues.position == 0 && noCues.presentation.currentSlidePosition == 2 && !noCues.running, "Zero-cue manual slide move preserves notes and paused state")
    }

    @MainActor
    static func slideButtonsPreserveReadingAndCues() async throws {
        for mode in [AppModel.Mode.voice, .timed] {
            let model = fixture(connected: false)
            model.seek(3)
            model.presentation.isConnected = true
            model.mode = mode
            model.toggle()
            try await until { model.running }
            model.moveSlide(by: 1)
            try await until { model.presentation.hasPendingGoTo }
            try expect(!model.running && model.position == 3, "Slide button pauses \(mode.rawValue) until acknowledgement")
            model.presentation.finishGoTo()
            try await until { !model.slideBusy && model.running }
            try expect(model.position == 3 && model.presentation.currentSlidePosition == 2, "Successful slide button resumes \(mode.rawValue) at same word")
            model.stop()
        }

        let cues = fixture()
        cues.toggle()
        try await until { cues.running }
        cues.speech.transcript = "\(first) Harbor workers carefully"
        try await until { !cues.slideBusy && cues.presentation.advanceCalls == 1 }
        try expect(cues.position == 11 && cues.presentation.currentSlidePosition == 2, "Reading consumes first cue before manual slide correction")
        cues.moveSlide(by: -1)
        try await until { cues.presentation.hasPendingGoTo }
        cues.presentation.finishGoTo()
        try await until { !cues.slideBusy && cues.running }
        cues.speech.transcript = "unload wooden crates before sunrise"
        try await until { !cues.slideBusy && cues.presentation.advanceCalls == 2 }
        try expect(cues.position == 16 && cues.presentation.currentSlidePosition == 2, "Next unread cue still fires once after manual Previous")
        cues.speech.transcript = "unload wooden crates before sunrise Distant mountain travelers"
        try expect(cues.position == 19 && cues.presentation.advanceCalls == 2, "Manual slide correction neither replays consumed cues nor duplicates next cue")
        cues.stop()
    }

    @MainActor
    static func slideButtonFailureAndCancellation() async throws {
        let failed = fixture(connected: false)
        failed.seek(3)
        failed.presentation.isConnected = true
        failed.toggle()
        try await until { failed.running }
        failed.moveSlide(by: 1)
        try await until { failed.presentation.hasPendingGoTo }
        failed.presentation.finishGoTo(success: false)
        try await until { !failed.slideBusy }
        try expect(failed.position == 3 && !failed.running && failed.speech.startCalls == 1, "Failed slide button keeps original notes and reading paused")
        try expect(!failed.presentation.isConnected && failed.slideError != nil, "Failed slide button disconnects with visible error")
        try expect(failed.presentation.goToRequests == [2] && failed.presentation.advanceCalls == 0, "Failed slide button never retries")

        let canceled = fixture(connected: false)
        canceled.seek(3)
        canceled.presentation.isConnected = true
        canceled.mode = .timed
        canceled.toggle()
        canceled.moveSlide(by: 1)
        try await until { canceled.presentation.hasPendingGoTo }
        canceled.disconnectSlides()
        canceled.presentation.finishGoTo()
        for _ in 0..<10 { await Task.yield() }
        try expect(canceled.position == 3 && !canceled.running && !canceled.slideBusy, "Late slide acknowledgement cannot resume canceled reading or move notes")
        try expect(!canceled.presentation.isConnected && canceled.presentation.goToRequests == [2], "Late slide acknowledgement cannot restore connection or retry")
    }

    @MainActor
    static func slideButtonCancelsQueuedSpeechStart() async throws {
        let model = fixture()
        model.toggle()
        model.moveSlide(by: 1)
        try await until { model.presentation.hasPendingGoTo }
        try expect(model.speech.startCalls == 0 && !model.running, "Queued microphone start cannot race direct slide command")
        model.presentation.finishGoTo()
        try await until { !model.slideBusy }
        try expect(model.position == 0 && !model.running && model.speech.startCalls == 0, "Slide button does not resume reading that had not started")
    }

    @MainActor
    static func matchNotesUsesFreshSlide() async throws {
        let model = fixture(connected: false)
        model.seek(3)
        model.presentation.isConnected = true
        model.presentation.currentSlidePosition = 3
        try expect(model.canMatchNotesToSlide, "Connected notes can follow the current slide")
        model.matchNotesToSlide()
        try expect(model.slideBusy && model.position == 3 && !model.canMatchNotesToSlide, "Match notes reserves status refresh before moving text")
        model.matchNotesToSlide()
        model.seek(20)
        try await until { model.presentation.hasPendingRefresh }
        try expect(model.presentation.refreshCalls == 1 && model.position == 3, "Repeated Match notes and text clicks cannot race pending status")
        try expect(model.presentation.goToRequests.isEmpty && model.presentation.advanceCalls == 0, "Match notes asks for status without commanding deck movement")
        model.presentation.finishRefresh(at: 2)
        try await until { !model.slideBusy }
        try expect(model.position == 8 && model.presentation.currentSlidePosition == 2, "Fresh slide two overrides stale cached slide three and finds its first word")
        try expect(!model.running && model.speech.startCalls == 0 && model.presentation.isConnected, "Paused Match notes keeps reading paused and deck connected")
        model.matchNotesToSlide()
        try await until { model.presentation.hasPendingRefresh }
        model.presentation.finishRefresh(at: 3)
        try await until { !model.slideBusy }
        try expect(model.position == 16 && model.presentation.goToRequests.isEmpty && model.presentation.advanceCalls == 0, "Fresh slide three moves only notes to its opening words")
    }

    @MainActor
    static func matchNotesGuardsAndOffsets() async throws {
        let guarded = fixture(connected: false)
        try expect(!guarded.canMatchNotesToSlide, "Disconnected notes cannot match a slide")
        guarded.matchNotesToSlide()
        guarded.presentation.isConnected = true
        guarded.presentation.target = .powerpoint
        try expect(!guarded.canMatchNotesToSlide, "Unsupported presentation adapter disables Match notes")
        guarded.matchNotesToSlide()
        guarded.presentation.target = .brave
        guarded.presentation.isBusy = true
        try expect(!guarded.canMatchNotesToSlide, "Busy presentation transport disables Match notes")
        guarded.matchNotesToSlide()
        guarded.presentation.isBusy = false
        guarded.speech.isPreparing = true
        try expect(!guarded.canMatchNotesToSlide, "Preparing microphone disables Match notes")
        guarded.matchNotesToSlide()
        guarded.speech.isPreparing = false
        guarded.script = ""
        guarded.presentation.isConnected = true
        try expect(!guarded.canMatchNotesToSlide, "Empty notes cannot match a slide")
        guarded.matchNotesToSlide()
        guarded.script = first
        guarded.presentation.isConnected = true
        try expect(guarded.needsSlideCues && !guarded.canMatchNotesToSlide, "Multi-slide deck without cues cannot pretend to locate matching notes")
        guarded.matchNotesToSlide()
        for _ in 0..<10 { await Task.yield() }
        try expect(guarded.presentation.refreshCalls == 0 && guarded.presentation.goToRequests.isEmpty && !guarded.slideBusy, "Guarded Match notes actions issue no transport request")

        let offset = fixture()
        offset.scriptStartingSlide = 3
        offset.matchNotesToSlide()
        try await until { offset.presentation.hasPendingRefresh }
        offset.presentation.finishRefresh(at: 4)
        try await until { !offset.slideBusy }
        try expect(offset.position == 8, "Match notes respects the script starting-slide offset")
        offset.matchNotesToSlide()
        try await until { offset.presentation.hasPendingRefresh }
        offset.presentation.finishRefresh(at: 2)
        try await until { !offset.slideBusy }
        try expect(offset.position == 8 && offset.slideError != nil && offset.presentation.isConnected, "Slide before script range preserves notes and reports missing mapping")
        offset.presentation.totalSlides = nil
        offset.matchNotesToSlide()
        try await until { offset.presentation.hasPendingRefresh }
        offset.presentation.finishRefresh(at: 4)
        try await until { !offset.slideBusy }
        try expect(offset.position == 8 && offset.slideError != nil && !offset.running, "Unknown deck size cannot produce a notes destination")
    }

    @MainActor
    static func matchNotesPreservesReadingAndRearmsCues() async throws {
        for mode in [AppModel.Mode.voice, .timed] {
            let model = fixture(connected: false)
            model.seek(3)
            model.presentation.isConnected = true
            model.mode = mode
            model.toggle()
            try await until { model.running }
            try expect(model.canMatchNotesToSlide, "Match notes remains available during \(mode.rawValue)")
            model.matchNotesToSlide()
            try await until { model.presentation.hasPendingRefresh }
            try expect(!model.running && model.position == 3, "Match notes pauses \(mode.rawValue) until current slide is confirmed")
            model.presentation.finishRefresh(at: 2)
            try await until { !model.slideBusy && model.running }
            try expect(model.position == 8 && model.presentation.advanceCalls == 0 && model.presentation.goToRequests.isEmpty, "Match notes resumes \(mode.rawValue) at confirmed section without moving slides")
            model.stop()
        }

        let backward = fixture()
        backward.toggle()
        try await until { backward.running }
        backward.speech.transcript = "\(first) \(second)"
        try await until { !backward.slideBusy && backward.presentation.advanceCalls == 2 }
        backward.matchNotesToSlide()
        try await until { backward.presentation.hasPendingRefresh }
        backward.presentation.finishRefresh(at: 1)
        try await until { !backward.slideBusy && backward.running }
        try expect(backward.position == 0 && backward.presentation.advanceCalls == 2, "Backward notes match resets to section beginning without replaying slide commands")
        backward.speech.transcript = first
        try await until { !backward.slideBusy && backward.presentation.advanceCalls == 3 }
        try expect(backward.position == 8 && backward.presentation.currentSlidePosition == 2, "Rereading after backward notes match rearms its next cue exactly once")
        backward.stop()

        let forward = fixture()
        forward.matchNotesToSlide()
        try await until { forward.presentation.hasPendingRefresh }
        forward.presentation.finishRefresh(at: 3)
        try await until { !forward.slideBusy }
        forward.toggle()
        try await until { forward.running }
        forward.speech.transcript = third
        try expect(forward.position == 24 && forward.presentation.advanceCalls == 0, "Forward notes match consumes earlier boundaries so reading does not replay skipped slides")
        forward.stop()

        let queued = fixture()
        queued.toggle()
        queued.matchNotesToSlide()
        try await until { queued.presentation.hasPendingRefresh }
        try expect(queued.speech.startCalls == 0 && !queued.running, "Match notes cancels a queued microphone start before status refresh")
        queued.presentation.finishRefresh(at: 2)
        try await until { !queued.slideBusy }
        try expect(queued.position == 8 && !queued.running && queued.speech.startCalls == 0, "Queued reading that had not started stays paused after Match notes")
    }

    @MainActor
    static func matchNotesFailureAndCancellation() async throws {
        let failed = fixture(connected: false)
        failed.seek(3)
        failed.presentation.isConnected = true
        failed.toggle()
        try await until { failed.running }
        failed.matchNotesToSlide()
        try await until { failed.presentation.hasPendingRefresh }
        failed.presentation.finishRefresh(at: 2, success: false)
        try await until { !failed.slideBusy }
        try expect(failed.position == 3 && !failed.running && failed.speech.startCalls == 1, "Failed status leaves original notes and pauses reading")
        try expect(!failed.presentation.isConnected && failed.slideError != nil, "Failed Match notes disconnects and exposes error")
        try expect(failed.presentation.refreshCalls == 1 && failed.presentation.goToRequests.isEmpty && failed.presentation.advanceCalls == 0, "Failed Match notes is never retried or converted into deck navigation")

        let missing = fixture(connected: false)
        missing.seek(3)
        missing.presentation.isConnected = true
        missing.mode = .timed
        missing.toggle()
        missing.matchNotesToSlide()
        try await until { missing.presentation.hasPendingRefresh }
        missing.presentation.finishRefresh(at: 6)
        try await until { !missing.slideBusy }
        try expect(missing.position == 3 && !missing.running && missing.slideError != nil, "Slide without a note section leaves notes untouched and reading paused")
        try expect(missing.presentation.isConnected && missing.presentation.currentSlidePosition == 6, "Missing note section retains the verified current slide connection")

        let canceled = fixture(connected: false)
        canceled.seek(3)
        canceled.presentation.isConnected = true
        canceled.mode = .timed
        canceled.toggle()
        canceled.matchNotesToSlide()
        try await until { canceled.presentation.hasPendingRefresh }
        canceled.disconnectSlides()
        canceled.presentation.finishRefresh(at: 2)
        for _ in 0..<10 { await Task.yield() }
        try expect(canceled.position == 3 && !canceled.running && !canceled.slideBusy, "Late canceled status cannot move notes or resume reading")
        try expect(!canceled.presentation.isConnected && canceled.presentation.refreshCalls == 1, "Late status cannot reconnect or retry Match notes")
    }

    struct Failure: Error, CustomStringConvertible { let description: String }
}
