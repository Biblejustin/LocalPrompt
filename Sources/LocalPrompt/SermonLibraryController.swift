import AppKit
import Combine
import PromptCore

/// The selected folder is stored only in this Mac's preferences.
@MainActor
final class SermonLibraryController: ObservableObject {
    let kind: NoteLibraryKind
    @Published private(set) var folderURL: URL?
    @Published private var allEntries: [SermonLibraryEntry] = []
    @Published var filenameFilter: String {
        didSet { defaults.set(filenameFilter, forKey: kind.filenameFilterKey) }
    }
    var entries: [SermonLibraryEntry] {
        allEntries.filter { NoteLibraryKind.matchesFilename($0, filter: filenameFilter) }
    }
    var totalEntryCount: Int { allEntries.count }
    @Published private(set) var isRefreshing = false
    @Published private(set) var errorMessage: String?
    private var refreshTask: Task<Void, Never>?
    private var generation = UUID()
    private let defaults: UserDefaults
    private var bookmarkKey: String { kind.bookmarkKey }

    init(kind: NoteLibraryKind = .sermons, defaults: UserDefaults = .standard) {
        self.kind = kind
        self.defaults = defaults
        filenameFilter = defaults.string(forKey: kind.filenameFilterKey) ?? ""
        do { folderURL = try resolveFolder() }
        catch { errorMessage = "Choose the folder for \(kind.pluralNoun) again: \(error.localizedDescription)" }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose your Obsidian folder for \(kind.pluralNoun)"
        panel.message = "LocalPrompt reads Markdown notes here, including subfolders. Your notes stay unchanged."
        panel.prompt = "Use folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = folderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark)
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
            errorMessage = "Choose the folder for \(kind.pluralNoun) again: \(error.localizedDescription)"
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
        let url = try URL(resolvingBookmarkData: data, options: .withoutUI, bookmarkDataIsStale: &stale)
        if stale { defaults.set(try url.bookmarkData(options: .minimalBookmark), forKey: bookmarkKey) }
        return url
    }
}

/// Bookmarks keep the source local and allow manual refresh after relaunch.
struct LinkedSermon: Codable {
    let fileBookmark: Data
    let folderBookmark: Data
    let name: String

    init(fileURL: URL, folderURL: URL) throws {
        fileBookmark = try fileURL.bookmarkData(options: .minimalBookmark)
        folderBookmark = try folderURL.bookmarkData(options: .minimalBookmark)
        name = fileURL.deletingPathExtension().lastPathComponent
    }

    func resolve() throws -> (file: URL, folder: URL) {
        var stale = false
        let folder = try URL(resolvingBookmarkData: folderBookmark, options: .withoutUI, bookmarkDataIsStale: &stale)
        let file = try URL(resolvingBookmarkData: fileBookmark, options: .withoutUI, bookmarkDataIsStale: &stale)
        return (file, folder)
    }
}
