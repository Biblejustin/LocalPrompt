import SwiftUI
import AppKit

@main
struct LocalPromptApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            ContentView(model: model, speech: model.speech)
                .preferredColorScheme(.dark)
                .frame(minWidth: 920, minHeight: 650)
        }
        .defaultSize(width: 1260, height: 820)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Script…", action: model.openScript).keyboardShortcut("o")
                Button("Export Script…", action: model.exportScript).keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu("Prompt") {
                Button("Toggle Full Screen") { NSApp.keyWindow?.toggleFullScreen(nil) }.keyboardShortcut("f", modifiers: [.command, .control])
                Button("Start / Pause", action: model.toggle).keyboardShortcut(.return, modifiers: .command)
                Button("Back 10 Words") { model.seek(model.position - 10) }.keyboardShortcut(.upArrow, modifiers: .command)
                Button("Forward 10 Words") { model.seek(model.position + 10) }.keyboardShortcut(.downArrow, modifiers: .command)
                Button("Rewind", action: model.rewind).keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
