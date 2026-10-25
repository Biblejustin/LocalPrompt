import AppKit
import Combine
import SwiftUI

/// Observe this view's window, including fullscreen entered with the green
/// window button, the menu, a keyboard shortcut, or restored window state.
@MainActor
final class PrompterWindowState: ObservableObject {
    @Published private(set) var isFullScreen = false
    private(set) weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []

    func attach(to window: NSWindow?) {
        guard self.window !== window else { return }
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        self.window = window
        update(from: window)
        guard let window else { return }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                Task { @MainActor in
                    guard let self, self.window === window else { return }
                    self.update(from: window)
                }
            })
        }
    }

    private func update(from window: NSWindow?) {
        isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
    }

    func toggleFullScreen() { window?.toggleFullScreen(nil) }

    func exitFullScreen() {
        guard window?.styleMask.contains(.fullScreen) == true else { return }
        window?.toggleFullScreen(nil)
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }
}

struct PrompterWindowReader: NSViewRepresentable {
    let state: PrompterWindowState

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.onWindowChange = { [weak state] window in state?.attach(to: window) }
        return view
    }

    func updateNSView(_ view: WindowReaderView, context: Context) {}

    final class WindowReaderView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Never publish SwiftUI state during its representable layout pass.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onWindowChange?(self.window)
            }
        }
    }
}
