import AppKit
import SlidesBridgeKit
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
    var supportsManualSync: Bool { target == .brave }
    var currentSlidePosition: Int? { target == .brave ? browser.currentSlidePosition : nil }
    var totalSlides: Int? { target == .brave ? browser.totalSlides : nil }

    func connect() async {
        if target == .brave { await browser.connect() }
        else { await powerpoint.connect() }
    }

    func advance() async throws {
        if target == .brave { try await browser.advance() }
        else { try await powerpoint.advance() }
    }

    func goToSlide(_ position: Int) async throws {
        guard target == .brave else { throw ManualSyncError.unsupported }
        try await browser.goToSlide(position)
    }

    func refreshPosition() async throws -> Int {
        guard target == .brave else { throw ManualSyncError.unsupported }
        return try await browser.refreshPosition()
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
            setupMessage = "In Brave, open brave://extensions, enable Developer mode, choose Load unpacked, and select the BraveExtension folder shown in Finder. If already installed, click Reload instead. Then open your deck → LocalPrompt Slides → Connect this deck. LocalPrompt pairs automatically."
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
        } catch { errorMessage = error.localizedDescription }
    }

    private enum ManualSyncError: LocalizedError {
        case unsupported
        var errorDescription: String? { "Manual slide sync currently supports Google Slides in Brave." }
    }
}

/// Installs only this app's local helper registration. Brave still requires the
/// user to load and invoke the extension; no browser profile is edited here.
private enum BraveExtensionSetup {
    /// Native-host folders, relative to the user's real home. A sandboxed build
    /// may write only these (see AppStore/LocalPrompt.entitlements).
    static let hostFolders = [
        "Library/Application Support/Google/Chrome/NativeMessagingHosts",
        "Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts",
    ]

    static func prepare() throws -> URL {
        let files = FileManager.default
        guard let resources = Bundle.main.resourceURL else { throw SetupError.missingBundle }
        let source = resources.appendingPathComponent("BraveExtension", isDirectory: true)
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/LocalPromptSlidesHost")
        guard files.fileExists(atPath: source.appendingPathComponent("manifest.json").path),
              files.isExecutableFile(atPath: helper.path) else { throw SetupError.missingBundle }
        // Inside the sandbox this is the app's own container, which is fine
        // for the extension copy that "Load unpacked" points at.
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
            "name": SlidesBridgeIdentity.hostName,
            "description": "LocalPrompt slide cues on this Mac",
            "path": helper.path,
            "type": "stdio",
            "allowed_origins": SlidesBridgeIdentity.allowedOrigins,
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        // Brave uses Chrome's native-host lookup on current macOS releases.
        // Register its own directory too for versions that use a separate path.
        // A sandboxed build cannot create the browser's own folders, so there
        // only browsers that have run on this Mac (folder exists) are registered.
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        var registered = 0
        var lastError: Error?
        for relative in hostFolders {
            let hosts = realHome.appendingPathComponent(relative, isDirectory: true)
            if sandboxed, !files.fileExists(atPath: hosts.deletingLastPathComponent().path) { continue }
            do {
                try files.createDirectory(at: hosts, withIntermediateDirectories: !sandboxed)
            } catch CocoaError.fileWriteFileExists {
            } catch where files.fileExists(atPath: hosts.path) {
            } catch { lastError = error; continue }
            do {
                try data.write(to: hosts.appendingPathComponent("\(SlidesBridgeIdentity.hostName).json"), options: .atomic)
                registered += 1
            } catch { lastError = error }
        }
        guard registered > 0 else { throw lastError ?? SetupError.noBrowser }
        return destination
    }

    /// The user's home folder, not the sandbox container that
    /// FileManager reports inside a Mac App Store build.
    static var realHome: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private enum SetupError: LocalizedError {
        case missingBundle, noBrowser
        var errorDescription: String? {
            switch self {
            case .missingBundle: return "The Brave extension is missing from this build. Reinstall the complete LocalPrompt app."
            case .noBrowser: return "Open Brave or Chrome once on this Mac, quit it, then prepare the extension again."
            }
        }
    }
}
