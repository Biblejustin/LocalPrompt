import Foundation

/// A Google file or folder explicitly linked in the original note. Extraction
/// is local only; it never resolves shortened links or fetches their contents.
public struct GoogleNoteLink: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case slides, sheets, docs, drive
    }

    public let url: URL
    public let kind: Kind
    public var id: String { url.absoluteString }
    public var title: String {
        switch kind {
        case .slides: "Google Slides"
        case .sheets: "Google Sheets"
        case .docs: "Google Docs"
        case .drive: "Google Drive"
        }
    }

    /// Frontmatter appears before the body, so its links naturally come first.
    /// Keep distinct views/fragments of a file, but remove repeated exact links.
    public static func links(in source: String) -> [GoogleNoteLink] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        let text = source as NSString
        var seen = Set<String>()
        return detector.matches(in: source, range: NSRange(location: 0, length: text.length)).compactMap { match in
            guard let detected = match.url,
                  var components = URLComponents(url: detected, resolvingAgainstBaseURL: false),
                  components.scheme?.lowercased() == "https",
                  components.user == nil, components.password == nil,
                  components.port == nil || components.port == 443,
                  let host = components.host?.lowercased(),
                  host == "docs.google.com" || host == "drive.google.com",
                  let kind = kind(for: components, host: host) else { return nil }
            components.scheme = "https"
            components.host = host
            // The standard HTTPS port names the same URL with or without :443.
            if components.port == 443 { components.port = nil }
            guard let url = components.url, seen.insert(url.absoluteString).inserted else { return nil }
            return GoogleNoteLink(url: url, kind: kind)
        }
    }

    private static func kind(for components: URLComponents, host: String) -> Kind? {
        // Use encoded paths so an encoded slash cannot manufacture path segments.
        let path = components.percentEncodedPath
        if host == "docs.google.com" {
            let services: [(String, Kind)] = [("presentation", .slides), ("spreadsheets", .sheets), ("document", .docs)]
            for (service, kind) in services {
                let pattern = "^/\(service)/(?:u/[0-9]+/)?d/(?:e/)?[A-Za-z0-9_-]+(?:/(?:edit|view|preview|present|pub|mobilebasic))?/?$"
                if path.range(of: pattern, options: .regularExpression) != nil { return kind }
            }
            return nil
        }
        if path.range(of: #"^/file/d/[A-Za-z0-9_-]+(?:/(?:view|preview|edit))?/?$"#, options: .regularExpression) != nil ||
            path.range(of: #"^/drive/(?:u/[0-9]+/)?folders/[A-Za-z0-9_-]+/?$"#, options: .regularExpression) != nil {
            return .drive
        }
        if path == "/open" || path == "/open/" {
            let identifiers = components.queryItems?.filter { $0.name == "id" } ?? []
            if identifiers.count == 1, let identifier = identifiers[0].value,
               identifier.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil {
                return .drive
            }
        }
        return nil
    }
}
