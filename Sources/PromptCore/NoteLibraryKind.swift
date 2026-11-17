import Foundation

/// Separate local libraries share the same read-only Markdown picker.
public enum NoteLibraryKind: String, CaseIterable, Identifiable, Sendable {
    case sermons, bibleStudies, mensMeetings, introductionToBible

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sermons: return "Sermons"
        case .bibleStudies: return "Bible Studies"
        case .mensMeetings: return "Men’s Meetings"
        case .introductionToBible: return "Introduction to the Bible"
        }
    }

    public var singularTitle: String {
        switch self {
        case .sermons: return "Sermon"
        case .bibleStudies: return "Bible study"
        case .mensMeetings: return "Topic"
        case .introductionToBible: return "Lesson"
        }
    }

    public var pluralNoun: String {
        switch self {
        case .sermons: return "sermons"
        case .bibleStudies: return "Bible studies"
        case .mensMeetings: return "meeting topics"
        case .introductionToBible: return "Introduction to the Bible lessons"
        }
    }

    public var symbol: String {
        switch self {
        case .sermons: return "books.vertical"
        case .bibleStudies: return "book"
        case .mensMeetings: return "person.2"
        case .introductionToBible: return "text.book.closed"
        }
    }

    public var searchPrompt: String { "Search \(pluralNoun) or folders" }

    public var bookmarkKey: String {
        // Keep the original key so existing sermon folders survive the update.
        self == .sermons ? "sermonFolderBookmark" : "\(rawValue)FolderBookmark"
    }

    public var filenameFilterKey: String { "\(rawValue)FilenameFilter" }

    public static func matchesFilename(_ entry: SermonLibraryEntry, filter: String) -> Bool {
        let text = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || entry.fileURL.deletingPathExtension().lastPathComponent
            .range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
