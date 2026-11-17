import Foundation

/// A user-named folder of Markdown notes. Libraries are stored only in this
/// Mac's preferences; each keeps its own folder bookmark and filename filter.
public struct NoteLibrary: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var symbol: String

    public init(id: String = UUID().uuidString, name: String, symbol: String = NoteLibrary.symbols[0]) {
        self.id = id
        self.name = name
        self.symbol = symbol
    }

    /// The name shown in buttons and menus, never blank.
    public var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled library" : trimmed
    }

    public var bookmarkKey: String {
        // The first release stored sermon folders under this key; keep it.
        id == "sermons" ? "sermonFolderBookmark" : "\(id)FolderBookmark"
    }

    public var filenameFilterKey: String { "\(id)FilenameFilter" }

    public static let maximumCount = 12

    /// SF Symbols offered in the library editor.
    public static let symbols = [
        "books.vertical", "book", "text.book.closed", "person.2", "person.3",
        "doc.text", "mic", "music.note", "graduationcap", "star", "heart", "folder"
    ]

    /// The four libraries LocalPrompt shipped with before they became editable.
    public static let legacy = [
        NoteLibrary(id: "sermons", name: "Sermons", symbol: "books.vertical"),
        NoteLibrary(id: "bibleStudies", name: "Bible Studies", symbol: "book"),
        NoteLibrary(id: "mensMeetings", name: "Men’s Meetings", symbol: "person.2"),
        NoteLibrary(id: "introductionToBible", name: "Introduction to the Bible", symbol: "text.book.closed")
    ]

    /// A fresh install starts with one library the user can rename.
    public static func starter() -> [NoteLibrary] { [NoteLibrary(name: "Scripts")] }

    public static let storageKey = "noteLibraries"

    /// Saved libraries; otherwise the legacy four when an older version left
    /// folders or filters behind; otherwise the starter library.
    public static func load(from defaults: UserDefaults) -> [NoteLibrary] {
        if let data = defaults.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([NoteLibrary].self, from: data) {
            return Array(saved.prefix(maximumCount))
        }
        let hasLegacySettings = legacy.contains {
            defaults.object(forKey: $0.bookmarkKey) != nil || defaults.object(forKey: $0.filenameFilterKey) != nil
        }
        return hasLegacySettings ? legacy : starter()
    }

    public static func save(_ libraries: [NoteLibrary], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(Array(libraries.prefix(maximumCount))) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Forget a removed library's folder and filter. Notes on disk are untouched.
    public static func forget(_ library: NoteLibrary, in defaults: UserDefaults) {
        defaults.removeObject(forKey: library.bookmarkKey)
        defaults.removeObject(forKey: library.filenameFilterKey)
    }

    public static func matchesFilename(_ entry: SermonLibraryEntry, filter: String) -> Bool {
        let text = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || entry.fileURL.deletingPathExtension().lastPathComponent
            .range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
