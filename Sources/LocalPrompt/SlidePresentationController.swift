import AppKit
import Combine

/// Routes cues only to the presentation service explicitly selected by the user.
@MainActor
final class SlidePresentationController: ObservableObject {
    enum Target: String, CaseIterable, Identifiable {
        case brave = "Google Slides in Brave"
        case powerpoint = "PowerPoint for Mac"
        var id: Self { self }
    }

    @Published var target: Target = .brave {
        didSet {
            guard target != oldValue else { return }
            browser.disconnect()
            powerpoint.disconnect()
            errorMessage = nil
        }
    }
    @Published private(set) var errorMessage: String?
    @Published private(set) var setupMessage: String?
    let browser = BrowserPresentationController()
    private let powerpoint = PresentationController()
    private var subscriptions = Set<AnyCancellable>()

    init() {
        browser.objectWillChange.merge(with: powerpoint.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &subscriptions)
        browser.$errorMessage.sink { [weak self] message in
            guard let self, self.target == .brave else { return }
            self.errorMessage = message
        }.store(in: &subscriptions)
        powerpoint.$errorMessage.sink { [weak self] message in
            guard let self, self.target == .powerpoint else { return }
            self.errorMessage = message
        }.store(in: &subscriptions)
    }

    var status: String { target == .brave ? browser.status : powerpoint.status }
    var isConnected: Bool { target == .brave ? browser.isConnected : powerpoint.isConnected }
    var isBusy: Bool { browser.isBusy || powerpoint.isBusy }
    var connectLabel: String { target == .brave ? "Connect Google Slides" : "Connect PowerPoint" }

    func connect() async {
        if target == .brave { await browser.connect() }
        else { await powerpoint.connect() }
    }

    func advance() async throws {
        if target == .brave { try await browser.advance() }
        else { try await powerpoint.advance() }
    }

    func disconnect() {
        browser.disconnect()
        powerpoint.disconnect()
        errorMessage = nil
    }

    func prepareBrave() {
        guard !isConnected, !isBusy else { return }
        do {
            let folder = try BraveExtensionSetup.prepare()
            try browser.startListening()
            setupMessage = "In Brave, open brave://extensions, enable Developer mode, choose Load unpacked, and select the BraveExtension folder shown in Finder. Then open your slideshow and click the LocalPrompt Slides extension → Connect this slideshow. Return here and click Connect Google Slides."
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
        } catch { errorMessage = error.localizedDescription }
    }
}

/// Installs only this app's local helper registration. Brave still requires the
/// user to load and invoke the extension; no browser profile is edited here.
private enum BraveExtensionSetup {
    static let extensionID = "ojnmagbchlkpiajkkpkchacbbmnpmlid"

    static func prepare() throws -> URL {
        let files = FileManager.default
        guard let resources = Bundle.main.resourceURL else { throw SetupError.missingBundle }
        let source = resources.appendingPathComponent("BraveExtension", isDirectory: true)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/LocalPromptSlidesHost")
        guard files.fileExists(atPath: source.appendingPathComponent("manifest.json").path),
              files.isExecutableFile(atPath: helper.path) else { throw SetupError.missingBundle }
        let support = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        let root = support.appendingPathComponent("LocalPrompt", isDirectory: true)
        try files.createDirectory(at: root, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let destination = root.appendingPathComponent("BraveExtension", isDirectory: true)
        let staging = root.appendingPathComponent("BraveExtension-\(UUID().uuidString).noindex")
        try files.copyItem(at: source, to: staging)
        if files.fileExists(atPath: destination.path) {
            // Keep the previous extension as a recoverable local backup.
            let backup = root.appendingPathComponent("BraveExtension-backup-\(UUID().uuidString).noindex")
            try files.moveItem(at: destination, to: backup)
            do { try files.moveItem(at: staging, to: destination) }
            catch { try? files.moveItem(at: backup, to: destination); throw error }
        } else { try files.moveItem(at: staging, to: destination) }
        let manifest: [String: Any] = [
            "name": "com.biblejustin.localprompt.slides",
            "description": "LocalPrompt slide cues on this Mac",
            "path": helper.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        // Brave uses Chrome's native-host lookup on current macOS releases.
        // Register its own directory too for versions that use a separate path.
        for relative in ["Google/Chrome/NativeMessagingHosts", "BraveSoftware/Brave-Browser/NativeMessagingHosts"] {
            let hosts = support.appendingPathComponent(relative, isDirectory: true)
            try files.createDirectory(at: hosts, withIntermediateDirectories: true)
            try data.write(to: hosts.appendingPathComponent("com.biblejustin.localprompt.slides.json"), options: .atomic)
        }
        return destination
    }

    private enum SetupError: LocalizedError {
        case missingBundle
        var errorDescription: String? { "The Brave extension is missing from this build. Reinstall the complete LocalPrompt app." }
    }
}
