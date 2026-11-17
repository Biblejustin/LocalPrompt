import SwiftUI
import PromptCore

struct SermonLibraryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var library: SermonLibraryController
    @State private var query = ""
    @State private var selection: String?

    private var matches: [SermonLibraryEntry] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return library.entries.filter {
            search.isEmpty || $0.title.localizedStandardContains(search) || $0.relativePath.localizedStandardContains(search)
        }
    }

    private var selectedEntry: SermonLibraryEntry? { matches.first { $0.id == selection } }
    private var hasFilenameFilter: Bool { !library.filenameFilter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var noteNoun: String {
        library.kind == .bibleStudies ? library.kind.singularTitle : library.kind.singularTitle.lowercased()
    }
    private var emptyMessage: String {
        if library.folderURL == nil { return "Choose a folder to see your \(library.kind.pluralNoun)." }
        if hasFilenameFilter && library.entries.isEmpty { return "No notes match the filename filter." }
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "No matching \(library.kind.pluralNoun)." }
        return "No Markdown notes found in this folder."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(library.kind.title, systemImage: library.kind.symbol).font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { model.selectedLibrary = nil }.keyboardShortcut(.cancelAction)
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(library.folderURL?.lastPathComponent ?? "Choose a folder for \(library.kind.pluralNoun)").font(.headline)
                    Text(library.folderURL.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "Pick a folder inside your Obsidian vault for \(library.kind.pluralNoun).")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Button(library.folderURL == nil ? "Choose folder…" : "Change folder…", action: library.chooseFolder)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Filename filter").font(.caption)
                    TextField("All Markdown files", text: $library.filenameFilter)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Filename filter")
                }
                Text("Text in filename · clear to show all notes")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField(library.kind.searchPrompt, text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search \(library.kind.pluralNoun)")
                Button(action: library.refresh) { Label("Refresh list", systemImage: "arrow.clockwise") }
                    .disabled(library.folderURL == nil || library.isRefreshing)
            }
            if let error = library.errorMessage {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
            }
            List(selection: $selection) {
                ForEach(matches) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title).font(.headline).lineLimit(2)
                        HStack {
                            Text(entry.relativePath).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(entry.modifiedDate, style: .date)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 5)
                    .tag(entry.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(entry) }
                }
            }
            .overlay {
                if library.isRefreshing { ProgressView("Reading folder…") }
                else if matches.isEmpty {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            .onChange(of: query) { _, _ in if selectedEntry == nil { selection = nil } }
            .onChange(of: library.entries) { _, _ in if selectedEntry == nil { selection = nil } }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(matches.count) of \(library.entries.count) \(library.kind.pluralNoun) · newest first").font(.caption)
                    if hasFilenameFilter {
                        Text("\(library.totalEntryCount) Markdown files in folder").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Opens a local copy. Vault notes stay unchanged.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open \(noteNoun)") { if let selectedEntry { open(selectedEntry) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedEntry == nil || !model.canReplaceScript || library.isRefreshing)
            }
        }
        .padding(22)
        .frame(width: 650, height: 540)
        .onAppear { library.refresh() }
        .alert(library.kind.title, isPresented: Binding(get: { model.documentError != nil }, set: { if !$0 { model.documentError = nil } })) {
            Button("OK") { model.documentError = nil }
        } message: { Text(model.documentError ?? "") }
    }

    private func open(_ entry: SermonLibraryEntry) {
        if model.openNote(entry, from: library) { model.selectedLibrary = nil }
    }
}
