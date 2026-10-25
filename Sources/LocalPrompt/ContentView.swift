import SwiftUI
import Combine

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
            if !windowState.isFullScreen { transport }
        }
        .background(canvas)
        .background(PrompterWindowReader(state: windowState).frame(width: 0, height: 0))
        .ignoresSafeArea(.container, edges: windowState.isFullScreen ? .all : [])
        .tint(mint)
        .onReceive(timer) { _ in model.tick() }
        .onExitCommand(perform: windowState.isFullScreen ? { windowState.exitFullScreen() } : nil)
        .onChange(of: speech.errorMessage) { _, message in
            if message != nil { windowState.exitFullScreen() }
        }
        .alert("Script", isPresented: Binding(get: { model.documentError != nil }, set: { if !$0 { model.documentError = nil } })) {
            Button("OK") { model.documentError = nil }
        } message: { Text(model.documentError ?? "") }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path").font(.system(size: 25, weight: .semibold)).foregroundStyle(mint)
            VStack(alignment: .leading, spacing: 2) {
                Text("LocalPrompt").font(.system(size: 19, weight: .semibold))
                Text("YOUR WORDS. YOUR PACE.").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.4).foregroundStyle(.secondary)
            }
            Spacer()
            Label("ON-DEVICE SPEECH", systemImage: "lock.shield")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(mint).padding(.horizontal, 12).padding(.vertical, 7)
                .background(mint.opacity(0.08), in: Capsule())
            Button { withAnimation(.easeInOut(duration: 0.2)) { showEditor.toggle() } } label: {
                Image(systemName: "sidebar.left")
            }.help("Show or hide script editor")
            Button { windowState.toggleFullScreen() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }.help("Full screen · ⌃⌘F. Esc returns controls; ⌘Return starts or pauses.")
        }
        .buttonStyle(.borderless)
        .padding(.leading, 85).padding(.trailing, 24).frame(height: 72)
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
                Button(action: model.openScript) { Label("Open", systemImage: "folder") }
                Button(action: model.exportScript) { Label("Export", systemImage: "square.and.arrow.up") }
                Spacer()
                Text("\(model.wordCount) words").font(.caption).foregroundStyle(.secondary)
            }.controlSize(.small)
            TextEditor(text: $model.script)
                .font(.system(size: 13)).lineSpacing(5)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.06)))
                .accessibilityLabel("Script editor")
                .frame(minHeight: 150)
            Text("Paste or open TXT, Markdown, or RTF. Markdown renders in the prompter. Edits save automatically.")
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
            }.padding(.horizontal, 30).padding(.bottom, 16).padding(.top, 12)
            }
        }
    }

    private var transport: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.35)
            if let error = speech.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { speech.errorMessage = nil }
                }.font(.system(size: 12)).foregroundStyle(.orange)
                    .padding(12).background(.orange.opacity(0.07))
            }
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
                Button(action: model.toggle) {
                    HStack(spacing: 8) {
                        if speech.isPreparing { ProgressView().controlSize(.small) }
                        else { Image(systemName: model.running ? "pause.fill" : "play.fill") }
                        Text(speech.isPreparing ? "Cancel" : model.running ? "Pause" : "Start reading")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(canvas).frame(width: 140, height: 40)
                    .background(mint, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain).disabled(model.wordCount == 0).help("Start / pause · ⌘Return")
                Button { model.seek(model.position + 10) } label: { Image(systemName: "goforward.10") }.accessibilityLabel("Forward 10 words").help("Forward 10 words · ⌘↓")
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 7) {
                    Text(model.timeLabel).font(.system(size: 22, weight: .light, design: .monospaced))
                    HStack(spacing: 3) {
                        ForEach(0..<18) { index in
                            Capsule().fill(speech.isRunning && speech.level > Double(index) / 18 ? mint : .white.opacity(0.1)).frame(width: 3, height: 7)
                        }
                    }.accessibilityLabel("Microphone level")
                }.frame(width: 90)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 26).padding(.vertical, 19)
        }.background(panel)
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
