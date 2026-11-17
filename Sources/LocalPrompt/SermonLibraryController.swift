import AppKit
import Combine
import PromptCore

/// The selected folder is stored only in this Mac's preferences.
@MainActor
final class SermonLibraryController: ObservableObject {
    @Published private(set) var info: NoteLibrary
    @Published private(set) var folderURL: URL?
    @Published private var allEntries: [SermonLibraryEntry] = []
    @Published var filenameFilter: String {
        didSet { defaults.set(filenameFilter, forKey: info.filenameFilterKey) }
    }
    var entries: [SermonLibraryEntry] {
        allEntries.filter { NoteLibrary.matchesFilename($0, filter: filenameFilter) }
    }
    var totalEntryCount: Int { allEntries.count }
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private let defaults: UserDefaults
    private var bookmarkKey: String { info.bookmarkKey }

    init(library: NoteLibrary, defaults: UserDefaults = .standard) {
        info = library
        self.defaults = defaults
        filenameFilter = defaults.string(forKey: library.filenameFilterKey) ?? ""
        do { folderURL = try resolveFolder() }
        catch { errorMessage = "Choose the folder for \(library.title) again: \(error.localizedDescription)" }
    }

    /// Picks up a rename or new symbol. The id, folder and filter stay.
    func update(_ library: NoteLibrary) {
        guard library.id == info.id, library != info else { return }
        info = library
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the folder for \(info.title)"
        panel.message = "LocalPrompt reads Markdown notes here, including subfolders. Your notes stay unchanged."
        panel.prompt = "Use folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try FolderBookmark.make(url)
            defaults.set(bookmark, forKey: bookmarkKey)
            folderURL = url
            allEntries = []
            refresh()
        } catch { errorMessage = "Could not remember folder: \(error.localizedDescription)" }
    }

    func refresh() {
        refreshTask?.cancel()
        generation = UUID()
        let request = generation
        errorMessage = nil
        do { folderURL = try resolveFolder() }
        catch {
            allEntries = []
            isRefreshing = false
            errorMessage = "Choose the folder for \(info.title) again: \(error.localizedDescription)"
            return
        }
        guard let folderURL else { allEntries = []; isRefreshing = false; return }
        isRefreshing = true
        refreshTask = Task { [weak self] in
            do {
                let entries = try await Task.detached(priority: .userInitiated) {
                    let access = folderURL.startAccessingSecurityScopedResource()
                    defer { if access { folderURL.stopAccessingSecurityScopedResource() } }
                    return try SermonLibraryIndex.scan(folderURL: folderURL)
                }.value
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.allEntries = entries
                self.isRefreshing = false
            } catch {
                guard let self, !Task.isCancelled, self.generation == request else { return }
                self.allEntries = []
                self.isRefreshing = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func resolveFolder() throws -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        let url = try FolderBookmark.resolve(data, stale: &stale)
        if stale { defaults.set(try FolderBookmark.make(url), forKey: bookmarkKey) }
        return url
    }
}

/// Bookmarks keep the source local and allow manual refresh after relaunch.
struct LinkedSermon: Codable {
    let fileBookmark: Data
    let folderBookmark: Data
    let name: String

    init(fileURL: URL, folderURL: URL) throws {
        fileBookmark = try FolderBookmark.make(fileURL)
        folderBookmark = try FolderBookmark.make(folderURL)
        name = fileURL.deletingPathExtension().lastPathComponent
    }

    func resolve() throws -> (file: URL, folder: URL) {
        var stale = false
        let folder = try FolderBookmark.resolve(folderBookmark, stale: &stale)
        let file = try FolderBookmark.resolve(fileBookmark, stale: &stale)
        return (file, folder)
    }
}

/// Security-scoped bookmarks let a sandboxed build reopen a folder after
/// relaunch. Bookmarks saved by earlier, unsandboxed builds still resolve.
enum FolderBookmark {
    static func make(_ url: URL) throws -> Data {
        if let scoped = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
            return scoped
        }
        return try url.bookmarkData(options: .minimalBookmark)
    }

    static func resolve(_ data: Data, stale: inout Bool) throws -> URL {
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                               relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        return try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
