import Foundation

/// File metadata only. Indexing a folder does not load any note text.
public struct SermonLibraryEntry: Identifiable, Equatable, Sendable {
    public var id: String { relativePath }
    public let title: String
    public let relativePath: String
    public let fileURL: URL
    public let modifiedDate: Date

    public init(title: String, relativePath: String, fileURL: URL, modifiedDate: Date) {
        self.title = title
        self.relativePath = relativePath
        self.fileURL = fileURL
        self.modifiedDate = modifiedDate
    }
}

public enum SermonLibraryError: Error, LocalizedError, Equatable {
    case folderUnavailable
    case scanFailed
    case outsideFolder
    case unsupportedFile
    case symbolicLink
    case fileUnavailable
    case fileTooLarge
    case invalidUTF8

    public var errorDescription: String? {
        switch self {
        case .folderUnavailable: return "The note folder is unavailable. Choose its current location."
        case .scanFailed: return "Could not read the note folder completely. Check its permissions and refresh."
        case .outsideFolder: return "This note is outside the selected folder. Choose the folder again."
        case .unsupportedFile: return "Choose a Markdown file inside the note folder. Hidden files and app packages are excluded."
        case .symbolicLink: return "Symbolic links are excluded. Choose the original note folder or file."
        case .fileUnavailable: return "This note is unavailable. It may have moved or been deleted. Refresh the list."
        case .fileTooLarge: return "This note is larger than the 5 MB import limit."
        case .invalidUTF8: return "This note is not valid UTF-8 text. Save it as UTF-8 Markdown and try again."
        }
    }
}

/// A read-only index of the explicitly chosen folder. No vault settings,
/// Markdown contents, or paths are written by this type.
public enum SermonLibraryIndex {
    public static let maximumFileSize = 5 * 1024 * 1024

    public static func scan(folderURL: URL) throws -> [SermonLibraryEntry] {
        let root = try validatedFolder(folderURL)
        let files = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                                        .isHiddenKey, .isPackageKey, .contentModificationDateKey]
        var failed = false
        guard let enumerator = files.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                               errorHandler: { _, _ in failed = true; return false }) else {
            throw SermonLibraryError.scanFailed
        }
        var entries: [SermonLibraryEntry] = []
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            let values: URLResourceValues
            do { values = try fileURL.resourceValues(forKeys: keys) }
            catch { throw SermonLibraryError.scanFailed }
            if values.isSymbolicLink == true || values.isHidden == true || values.isPackage == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isDirectory != true, values.isRegularFile == true,
                  fileURL.pathExtension.lowercased() == "md" else { continue }
            // Revalidate path components so replacing a directory with a link
            // during an enumeration cannot add a note from another folder.
            let safeURL = try validatedFile(fileURL, folderURL: root)
            let relative = safeURL.pathComponents.dropFirst(root.pathComponents.count).joined(separator: "/")
            entries.append(SermonLibraryEntry(title: safeURL.deletingPathExtension().lastPathComponent,
                                              relativePath: relative, fileURL: safeURL,
                                              modifiedDate: values.contentModificationDate ?? .distantPast))
        }
        guard !failed else { throw SermonLibraryError.scanFailed }
        return entries.sorted {
            if $0.modifiedDate != $1.modifiedDate { return $0.modifiedDate > $1.modifiedDate }
            let comparison = $0.title.compare($1.title, options: [.numeric, .caseInsensitive],
                                               locale: Locale(identifier: "en_US_POSIX"))
            if comparison != .orderedSame { return comparison == .orderedAscending }
            return $0.relativePath < $1.relativePath
        }
    }

    public static func read(_ entry: SermonLibraryEntry, folderURL: URL) throws -> String {
        try read(fileURL: entry.fileURL, folderURL: folderURL)
    }

    /// Bounds actual bytes read, including when a file grows after its size was
    /// checked. A failed read returns no text for the caller to install as a draft.
    public static func read(fileURL: URL, folderURL: URL) throws -> String {
        let safeURL = try validatedFile(fileURL, folderURL: folderURL)
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: safeURL.path) }
        catch { throw SermonLibraryError.fileUnavailable }
        if let size = attributes[.size] as? NSNumber, size.uint64Value > UInt64(maximumFileSize) {
            throw SermonLibraryError.fileTooLarge
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: safeURL) }
        catch { throw SermonLibraryError.fileUnavailable }
        defer { try? handle.close() }
        var data = Data()
        do {
            while data.count <= maximumFileSize {
                try Task.checkCancellation()
                let amount = min(65_536, maximumFileSize + 1 - data.count)
                guard let next = try handle.read(upToCount: amount), !next.isEmpty else { break }
                data.append(next)
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw SermonLibraryError.fileUnavailable }
        guard data.count <= maximumFileSize else { throw SermonLibraryError.fileTooLarge }
        // Also reject a path that moved outside the folder while it was read.
        _ = try validatedFile(fileURL, folderURL: folderURL)
        guard let text = String(data: data, encoding: .utf8) else { throw SermonLibraryError.invalidUTF8 }
        return text
    }

    private static func validatedFolder(_ folderURL: URL) throws -> URL {
        guard folderURL.isFileURL else { throw SermonLibraryError.folderUnavailable }
        let requested = folderURL.standardizedFileURL
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: requested.path) }
        catch { throw SermonLibraryError.folderUnavailable }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink { throw SermonLibraryError.symbolicLink }
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              FileManager.default.isReadableFile(atPath: requested.path) else { throw SermonLibraryError.folderUnavailable }
        let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
        if (try? resolved.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
            throw SermonLibraryError.folderUnavailable
        }
        return resolved
    }

    private static func validatedFile(_ fileURL: URL, folderURL: URL) throws -> URL {
        let root = try validatedFolder(folderURL)
        guard fileURL.isFileURL else { throw SermonLibraryError.outsideFolder }
        let requested = fileURL.standardizedFileURL
        let selected = folderURL.standardizedFileURL
        let relative: ArraySlice<String>
        if isDescendant(requested, of: selected) {
            relative = requested.pathComponents.dropFirst(selected.pathComponents.count)
        } else if isDescendant(requested, of: root) {
            relative = requested.pathComponents.dropFirst(root.pathComponents.count)
        } else { throw SermonLibraryError.outsideFolder }
        guard requested.pathExtension.lowercased() == "md", !relative.isEmpty,
              !relative.contains(where: { $0.hasPrefix(".") }) else { throw SermonLibraryError.unsupportedFile }
        var cursor = root
        for (index, component) in relative.enumerated() {
            cursor.appendPathComponent(component)
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: cursor.path) }
            catch { throw SermonLibraryError.fileUnavailable }
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink { throw SermonLibraryError.symbolicLink }
            let last = index == relative.count - 1
            guard type == (last ? .typeRegular : .typeDirectory) else { throw SermonLibraryError.unsupportedFile }
            let values: URLResourceValues
            do { values = try cursor.resourceValues(forKeys: [.isHiddenKey, .isPackageKey]) }
            catch { throw SermonLibraryError.fileUnavailable }
            guard values.isHidden != true, values.isPackage != true else { throw SermonLibraryError.unsupportedFile }
        }
        guard isDescendant(cursor.resolvingSymlinksInPath().standardizedFileURL, of: root) else {
            throw SermonLibraryError.outsideFolder
        }
        return cursor
    }

    private static func isDescendant(_ fileURL: URL, of folderURL: URL) -> Bool {
        let file = fileURL.pathComponents
        let folder = folderURL.pathComponents
        return file.count > folder.count && file.starts(with: folder)
    }
}
