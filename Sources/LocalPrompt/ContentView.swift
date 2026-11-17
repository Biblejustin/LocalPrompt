import SwiftUI
import Combine
import PromptCore

private let canvas = Color(red: 0.055, green: 0.072, blue: 0.09)
private let panel = Color(red: 0.085, green: 0.105, blue: 0.125)
private let mint = Color(red: 0.42, green: 0.9, blue: 0.7)

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var speech: SpeechController
    @AppStorage("fontSize") private var fontSize = 40.0
    @AppStorage("textMargin") private var margin = 65.0
    @AppStorage("mirrorText") private var mirrored = false
    @State private var showEditor = true
    @State private var showSlideSettings = false
    @StateObject private var windowState = PrompterWindowState()
    private var readingInset: Double { windowState.isFullScreen ? 0 : PrompterTextView.readingLineInset }
    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            if !windowState.isFullScreen {
                header
                Divider().opacity(0.35)
            }
            HStack(spacing: 0) {
                if showEditor && !windowState.isFullScreen {
                    sidebar.frame(width: 300)
                    Divider().opacity(0.35)
                }
                stage
            }
            if windowState.isFullScreen { fullscreenTransport }
            else { transport }
        }
        .background(canvas)
        .background(PrompterWindowReader(state: windowState).frame(width: 0, height: 0))
        .ignoresSafeArea(.container, edges: windowState.isFullScreen ? .all : [])
        .tint(mint)
        .onReceive(timer) { _ in model.tick() }
        .onExitCommand(perform: windowState.isFullScreen ? { windowState.exitFullScreen() } : nil)
        .sheet(item: $model.selectedLibrary) { library in
            SermonLibraryView(model: model, library: model.library(for: library))
        }
        .sheet(isPresented: $model.showsLibraryManager) {
            LibraryManagerView(model: model)
        }
        .alert("Script", isPresented: Binding(get: { model.documentError != nil && model.selectedLibrary == nil }, set: { if !$0 { model.documentError = nil } })) {
            Button("OK") { model.documentError = nil }
        } message: { Text(model.documentError ?? "") }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            headerRow(showSpeechBadge: true)
            headerRow(showSpeechBadge: false)
            headerRow(showSpeechBadge: false, compactLibraries: true)
        }
        .buttonStyle(.borderless)
        .padding(.leading, 85).padding(.trailing, 24).frame(height: 72)
    }

    private func headerRow(showSpeechBadge: Bool, compactLibraries: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path").font(.system(size: 25, weight: .semibold)).foregroundStyle(mint)
            VStack(alignment: .leading, spacing: 2) {
                Text("LocalPrompt").font(.system(size: 19, weight: .semibold))
                Text("YOUR WORDS. YOUR PACE.").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.4).foregroundStyle(.secondary)
            }.fixedSize()
            Spacer(minLength: 8)
            if showSpeechBadge {
                Label("ON-DEVICE SPEECH", systemImage: "lock.shield")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(mint).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(mint.opacity(0.08), in: Capsule())
                    .fixedSize()
            }
            libraryButtons(compact: compactLibraries)
            Button {
                if !showSlideSettings { model.captureSlideCueInsertionPoint() }
                showSlideSettings.toggle()
            } label: {
                Label("Slide cues", systemImage: "rectangle.on.rectangle")
                    .font(.system(size: 11)).fixedSize()
            }.help("Connect Google Slides in Brave or PowerPoint and set up slide cues")
                .popover(isPresented: $showSlideSettings) { slideSettings }
            Button { withAnimation(.easeInOut(duration: 0.2)) { showEditor.toggle() } } label: {
                Image(systemName: "sidebar.left")
            }.help("Show or hide script editor")
            Button { windowState.toggleFullScreen() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }.help("Full screen · ⌃⌘F. Esc exits; ⌘Return starts or pauses.")
        }
    }

    /// Up to four libraries get their own header button; more share a menu.
    @ViewBuilder private func libraryButtons(compact: Bool) -> some View {
        if model.libraries.isEmpty {
            Button { model.editLibraries() } label: {
                Label("Add library", systemImage: "plus.rectangle.on.folder").font(.system(size: 11)).fixedSize()
            }.help("Add a folder of Markdown notes")
        } else if model.libraries.count <= 4 {
            ForEach(model.libraries) { library in
                Button { model.selectedLibrary = library } label: {
                    if compact {
                        Image(systemName: library.symbol).font(.system(size: 13))
                            .frame(width: 24, height: 24)
                    } else {
                        Label(library.title, systemImage: library.symbol).font(.system(size: 11)).fixedSize()
                    }
                }.accessibilityLabel(library.title)
                    .help("\(library.title): browse notes in this library. Right-click to edit libraries.")
                    .disabled(!model.canReplaceScript)
                    .contextMenu { Button("Edit Libraries…") { model.editLibraries() } }
            }
        } else {
            Menu {
                ForEach(model.libraries) { library in
                    Button { model.selectedLibrary = library } label: { Label(library.title, systemImage: library.symbol) }
                }
                Divider()
                Button("Edit Libraries…") { model.editLibraries() }
            } label: {
                Label("Libraries", systemImage: "books.vertical").font(.system(size: 11))
            }.fixedSize()
                .help("Browse notes in one of your libraries")
                .disabled(!model.canReplaceScript)
        }
    }

    private var slideSettings: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            Text("SLIDE CUES").font(.system(size: 11, weight: .semibold, design: .monospaced))
            googleLinkButton
            Picker("Presentation", selection: Binding(
                get: { model.presentation.target },
                set: { model.presentation.target = $0 }
            )) {
                ForEach(SlidePresentationController.Target.allCases) { target in
                    Text(target.rawValue).tag(target)
                }
            }.disabled(model.running || speech.isPreparing || model.slideBusy || model.presentation.isBusy)
            Text("Place this marker on its own line after a slide’s notes. Finishing those words advances the connected slideshow.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("[[next-slide]]").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Spacer()
                Button("Insert cue", action: model.insertSlideCue)
                    .disabled(model.running || speech.isPreparing)
                    .help("Insert at the script cursor, or append when the editor is not focused")
            }
            Text("\(model.document.slideCues.count) cue\(model.document.slideCues.count == 1 ? "" : "s") in this script")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text(model.presentation.status).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let message = model.slideConnectionMessage {
                Text(message).font(.callout).foregroundStyle(mint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.needsSlideCues {
                Text("These notes have no slide cues. Open the teleprompter copy prepared for this deck.")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Disconnect and read notes", action: model.disconnectAndReadNotes)
                    .disabled(!model.canReplaceScript)
            }
            if model.canReadWithoutSlides {
                Button("Read without slides", action: model.startWithoutSlides)
                Text("Notes only. Slide cues stay off until you connect a deck.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if model.presentation.isConnected {
                    Button("Disconnect", action: model.disconnectSlides)
                    Button("Test next slide", action: model.testNextSlide)
                        .disabled(model.running || speech.isPreparing || model.slideBusy || model.presentation.isBusy)
                } else if model.presentation.target == .powerpoint {
                    Button(model.presentation.connectLabel, action: model.connectSlides)
                        .disabled(model.running || speech.isPreparing || model.slideBusy || model.presentation.isBusy)
                }
                if model.slideBusy { ProgressView().controlSize(.small) }
            }
            if model.presentation.target == .brave {
                Stepper("Notes start on slide \(model.scriptStartingSlide)", value: $model.scriptStartingSlide, in: 1...10_000)
                    .disabled(!model.canReplaceScript)
                Text("Click a word to move both notes and deck to that section. Each [[next-slide]] begins the next slide’s notes. For a partial script, set its starting slide above.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !model.presentation.isConnected {
                    Text("Open your deck in Brave → LocalPrompt Slides → Connect this deck. Pairing happens automatically here; reading stays paused.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                Button("Prepare Brave extension", action: model.presentation.prepareBrave)
                    .disabled(model.running || speech.isPreparing || model.presentation.isConnected || model.slideBusy || model.presentation.isBusy)
                Text(model.presentation.setupMessage ?? "First time only: prepare the Brave extension, then load its folder at brave://extensions. After an update, prepare again and reload the extension there.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Use Sidecar as an extended display. Move LocalPrompt to the iPad and leave the slideshow on your Mac or projector. Cues do not switch focus.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Start one PowerPoint slideshow on this Mac, then connect. macOS will ask for Automation access.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Testing moves a real slide. After moving slides manually, align slides and notes, then reconnect. In Brave, select the slideshow again with the extension.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Pause cancels queued changes. In Brave, clicking notes or moving ten words syncs the slide; jumping back rearms later cues. PowerPoint seeks move notes only. Rewind disconnects; return your deck to its starting slide, then reconnect.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
          }.padding(20)
        }.frame(width: 420, height: 580)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                label("SCRIPT SOURCE")
                Spacer()
                Text("SAVED LOCALLY").font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
            }
            TextField("Script title", text: $model.title)
                .font(.system(size: 18, weight: .semibold)).textFieldStyle(.plain)
            HStack {
                Button(action: model.openScript) { Label("Open", systemImage: "folder") }.disabled(!model.canReplaceScript)
                Button(action: model.exportScript) { Label("Export", systemImage: "square.and.arrow.up") }
                Spacer()
                Text("\(model.wordCount) words").font(.caption).foregroundStyle(.secondary)
            }.controlSize(.small)
            HStack {
                googleLinkButton
                Spacer()
            }.controlSize(.small)
            if let source = model.linkedSermon {
                HStack {
                    Label("Obsidian copy", systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(action: model.reloadSermon) { Label("Reload", systemImage: "arrow.clockwise") }
                        .disabled(!model.canReplaceScript)
                        .help("Reload \(source.name) from Obsidian. Current copy becomes the previous draft.")
                }.controlSize(.small)
            }
            TextEditor(text: $model.script)
                .font(.system(size: 13)).lineSpacing(5)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.06)))
                .accessibilityLabel("Script editor")
                .frame(minHeight: 150)
            Text(model.linkedSermon == nil
                 ? "Paste or open TXT, Markdown, or RTF. Markdown renders in the prompter. Edits save automatically."
                 : "Edits save in LocalPrompt only. Reload reads the latest Obsidian note. File → Restore Previous Draft undoes a load or reload.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider().opacity(0.4)
            label("READING ROOM")
            sliderRow("Text size", value: $fontSize, range: 24...72, suffix: "pt")
            sliderRow("Side margin", value: $margin, range: 36...160, suffix: "px")
            Toggle(isOn: $mirrored) { Label("Mirror for glass", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                .font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "hand.point.up.left").foregroundStyle(mint)
                Text("Click any word in the prompter to pick up from there.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 11)).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(22).background(panel)
    }

    @ViewBuilder
    private var googleLinkButton: some View {
        Group {
            if model.googleNoteLinks.count > 1 {
                Menu {
                    ForEach(Array(model.googleNoteLinks.enumerated()), id: \.element.id) { index, link in
                        Button("\(index + 1). \(link.title)") { model.openGoogleLink(link) }
                            .help(link.url.absoluteString)
                    }
                } label: { Label("Open in browser", systemImage: "arrow.up.right.square") }
            } else {
                Button {
                    if let link = model.googleNoteLinks.first { model.openGoogleLink(link) }
                } label: { Label("Open in browser", systemImage: "arrow.up.right.square") }
            }
        }
        .disabled(model.googleNoteLinks.isEmpty || model.openingGoogleLink)
        .help(model.googleNoteLinks.isEmpty
              ? "No Google Slides, Sheets, Docs, or Drive link found in this note"
              : "Open the linked Google file in Brave, or your default browser if Brave is not installed")
    }

    private var stage: some View {
        VStack(spacing: 0) {
            if !windowState.isFullScreen {
            HStack {
                HStack(spacing: 7) {
                    Circle().fill(model.running ? mint : .gray).frame(width: 6, height: 6)
                    Text(model.position >= model.wordCount && model.wordCount > 0 ? "COMPLETE" : model.running ? "\(model.mode == .voice ? "LISTENING" : "READING")" : "READY WHEN YOU ARE")
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).tracking(1)
                }.foregroundStyle(.secondary)
                Spacer()
                Text(model.title).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.horizontal, 30).padding(.top, 10).padding(.bottom, 8)
            }

            GeometryReader { _ in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(mint.opacity(0.045))
                        .frame(height: fontSize * 1.6)
                        .padding(.horizontal, 18)
                        .offset(y: max(0, readingInset - 2))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(mint.opacity(0.85))
                        .offset(x: 24, y: readingInset + fontSize * 0.45)
                    if model.wordCount == 0 {
                        VStack(spacing: 10) {
                            Image(systemName: "text.alignleft").font(.largeTitle).foregroundStyle(mint)
                            Text("Your next story starts here.").font(.title2)
                            Text("Paste a script in the editor to begin.").foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        PrompterTextView(document: model.document, words: model.words, position: model.position, fontSize: fontSize, margin: margin, onSeek: model.seek, readingTopInset: readingInset)
                            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                    }
                }.clipped()
            }

            if !windowState.isFullScreen {
            HStack(spacing: 12) {
                Text("\(min(model.position, model.wordCount)) / \(model.wordCount)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                ProgressView(value: model.progress).tint(mint).scaleEffect(y: 0.65)
                Text("\(Int(model.progress * 100))%").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                if showsSlideStatus { slideStatus }
            }.padding(.horizontal, 30).padding(.bottom, 16).padding(.top, 12)
            }
        }
    }

    private var transport: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            transportNotices
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Mode", selection: $model.mode) {
                        ForEach(AppModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 235)
                    if model.mode == .voice {
                        HStack(spacing: 7) {
                            Image(systemName: "mic.fill").foregroundStyle(mint)
                            Text(speech.status).lineLimit(2)
                        }.font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 270, alignment: .leading)
                    } else {
                        HStack {
                            Slider(value: $model.wordsPerMinute, in: 40...240, step: 5).frame(width: 150)
                            Text("\(Int(model.wordsPerMinute)) wpm").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
                Button(action: model.rewind) { Image(systemName: "backward.end.fill") }.accessibilityLabel("Rewind").help("Rewind · ⇧⌘R")
                Button { model.seek(model.position - 10) } label: { Image(systemName: "gobackward.10") }.accessibilityLabel("Back 10 words").help("Back 10 words · ⌘↑")
                readingButton
                Button { model.seek(model.position + 10) } label: { Image(systemName: "goforward.10") }.accessibilityLabel("Forward 10 words").help("Forward 10 words · ⌘↓")
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 7) {
                    Text(model.timeLabel).font(.system(size: 22, weight: .light, design: .monospaced))
                    microphoneMeter
                }.frame(width: 90)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 26).padding(.vertical, 19)
        }.background(panel)
    }

    /// Reserve space below the script so controls never cover readable words.
    private var fullscreenTransport: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            transportNotices
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    fullscreenSlideControls
                    fullscreenSlideNavigation
                    Spacer(minLength: 12)
                    fullscreenPlayback
                    Spacer(minLength: 12)
                    fullscreenMatchButtons
                    fullscreenTime
                    exitFullscreenButton
                }
                // Sidecar can offer a narrow viewport. Keep touch targets intact.
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        fullscreenSlideControls
                        Spacer(minLength: 8)
                        fullscreenMatchButtons
                        fullscreenTime
                        exitFullscreenButton
                    }
                    HStack(spacing: 12) {
                        fullscreenSlideNavigation
                        Spacer(minLength: 8)
                        fullscreenPlayback
                    }
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .background(panel)
        .popover(isPresented: $showSlideSettings, arrowEdge: .bottom) { slideSettings }
    }

    private var fullscreenSlideControls: some View {
        Button {
            if !showSlideSettings { model.captureSlideCueInsertionPoint() }
            showSlideSettings.toggle()
        } label: {
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 3) {
                    if showsSlideStatus { slideStatus }
                    else { Label("Slide cues", systemImage: "rectangle.on.rectangle") }
                    Text(speech.isPreparing ? "Preparing microphone…" : model.running ? (model.mode == .voice ? "Listening" : "Steady pace") : "Paused")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up").font(.system(size: 9, weight: .semibold))
            }.fixedSize().frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Slide controls: \(showsSlideStatus ? slideStatusText : "Slide cues")")
        .help("Slide connection and setup")
    }

    private var fullscreenPlayback: some View {
        HStack(spacing: 8) {
            Button { model.seek(model.position - 10) } label: {
                Image(systemName: "gobackward.10").frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Back 10 words").help("Back 10 words · ⌘↑")
                .disabled(model.slideBusy || model.presentation.isBusy || speech.isPreparing)
            readingButton
            Button { model.seek(model.position + 10) } label: {
                Image(systemName: "goforward.10").frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Forward 10 words").help("Forward 10 words · ⌘↓")
                .disabled(model.slideBusy || model.presentation.isBusy || speech.isPreparing)
        }.fixedSize()
    }

    private var fullscreenSlideNavigation: some View {
        HStack(spacing: 8) {
            Button { model.moveSlide(by: -1) } label: {
                Label("Previous slide", systemImage: "chevron.left")
                    .frame(minHeight: 44).padding(.horizontal, 8).contentShape(Rectangle())
            }
            .accessibilityLabel("Previous slide")
            .help("Previous slide in Brave; keep your place in the notes")
            .disabled(!model.canMoveSlide(by: -1))
            Button { model.moveSlide(by: 1) } label: {
                HStack(spacing: 5) {
                    Text("Next slide")
                    Image(systemName: "chevron.right")
                }.frame(minHeight: 44).padding(.horizontal, 8).contentShape(Rectangle())
            }
            .accessibilityLabel("Next slide")
            .help("Next slide in Brave; keep your place in the notes")
            .disabled(!model.canMoveSlide(by: 1))
        }.font(.system(size: 12, weight: .medium)).fixedSize()
    }

    @ViewBuilder
    private var fullscreenMatchButtons: some View {
        if model.presentation.supportsManualSync && model.presentation.isConnected && !model.document.slideCues.isEmpty {
            HStack(spacing: 12) {
                Button { model.seek(model.position) } label: {
                    Label("Match slide", systemImage: "arrow.triangle.2.circlepath")
                        .fixedSize().frame(minHeight: 44).contentShape(Rectangle())
                }.accessibilityLabel("Match slide to notes")
                    .help("Move the connected deck to the slide for your current notes")
                    .disabled(!model.canReplaceScript)
                Button(action: model.matchNotesToSlide) {
                    Label("Match notes", systemImage: "text.alignleft")
                        .fixedSize().frame(minHeight: 44).contentShape(Rectangle())
                }.accessibilityLabel("Match notes to slide")
                    .help("Move the teleprompter to the beginning of the notes for the current slide")
                    .disabled(!model.canMatchNotesToSlide)
            }.font(.system(size: 12, weight: .medium))
        }
    }

    private var fullscreenTime: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(model.timeLabel).font(.system(size: 16, weight: .light, design: .monospaced))
            microphoneMeter
        }.frame(width: 70)
    }

    private var exitFullscreenButton: some View {
        Button(action: windowState.exitFullScreen) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }.accessibilityLabel("Exit full screen").help("Exit full screen · Esc")
    }

    private var readingButton: some View {
        Button(action: model.toggle) {
            HStack(spacing: 8) {
                if speech.isPreparing { ProgressView().controlSize(.small) }
                else { Image(systemName: model.running ? "pause.fill" : "play.fill") }
                Text(speech.isPreparing ? "Cancel" : model.running ? "Pause" : "Start reading")
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(canvas).frame(width: 140, height: 44)
            .background(mint, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
            .disabled(model.wordCount == 0 || (!model.running && (model.slideBusy || model.presentation.isBusy)))
            .help("Start / pause · ⌘Return")
    }

    private var microphoneMeter: some View {
        HStack(spacing: 2) {
            ForEach(0..<18) { index in
                Capsule().fill(speech.isRunning && speech.level > Double(index) / 18 ? mint : .white.opacity(0.1)).frame(width: 2, height: 7)
            }
        }.accessibilityLabel("Microphone level")
            .accessibilityValue("\(Int(speech.level * 100)) percent")
    }

    @ViewBuilder
    private var transportNotices: some View {
        if let message = model.slideConnectionMessage {
            HStack {
                Image(systemName: "checkmark.circle")
                Text(message)
                Spacer()
                if !windowState.isFullScreen && model.presentation.supportsManualSync && model.presentation.isConnected && !model.document.slideCues.isEmpty {
                    Button("Match slide to notes") { model.seek(model.position) }
                        .disabled(!model.canReplaceScript)
                }
            }.font(.system(size: 12)).foregroundStyle(mint)
                .padding(12).background(mint.opacity(0.07))
        }
        if let error = speech.errorMessage {
            HStack {
                Image(systemName: "exclamationmark.circle")
                Text(error).textSelection(.enabled)
                Spacer()
                Button("Dismiss") { speech.errorMessage = nil }
            }.font(.system(size: 12)).foregroundStyle(.orange)
                .padding(12).background(.orange.opacity(0.07))
        }
        if let error = model.slideError {
            HStack {
                Image(systemName: "exclamationmark.circle")
                Text(error).textSelection(.enabled)
                Spacer()
                if model.canReadWithoutSlides {
                    Button("Read without slides", action: model.startWithoutSlides)
                }
                if model.needsSlideCues {
                    Button("Disconnect and read notes", action: model.disconnectAndReadNotes)
                        .disabled(!model.canReplaceScript)
                }
                Button("Dismiss") { model.slideError = nil }
            }.font(.system(size: 12)).foregroundStyle(.orange)
                .padding(12).background(.orange.opacity(0.07))
        }
    }

    private var showsSlideStatus: Bool {
        !model.document.slideCues.isEmpty || model.presentation.isConnected
    }

    private var slideStatus: some View {
        Label(slideStatusText, systemImage: model.presentation.isConnected ? "rectangle.on.rectangle" : "exclamationmark.circle")
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(slidesReady ? mint : .orange)
            .fixedSize()
            .accessibilityLabel(slideStatusText)
    }

    private var slidesReady: Bool {
        model.presentation.isConnected && !model.document.slideCues.isEmpty
    }

    private var slideStatusText: String {
        if model.readsWithoutSlides { return "Slides off · notes only" }
        if model.slideBusy || model.presentation.isBusy { return "Slides · checking…" }
        if !model.presentation.isConnected { return "Slides not connected" }
        if model.document.slideCues.isEmpty { return "No slide cues in notes" }
        if model.slideConnectionMessage != nil { return "Slides connected · reading paused" }
        if let slide = model.presentation.currentSlidePosition, let total = model.presentation.totalSlides {
            return "Slide \(slide) / \(total)"
        }
        return "Slides connected"
    }

    private func label(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.5).foregroundStyle(.secondary)
    }

    private func sliderRow(_ name: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(name)
                Spacer()
                Text("\(Int(value.wrappedValue)) \(suffix)").foregroundStyle(.secondary).monospacedDigit()
            }.font(.system(size: 11))
            Slider(value: value, in: range, step: 1).controlSize(.small)
        }
    }
}
