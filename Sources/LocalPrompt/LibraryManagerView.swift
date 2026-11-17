import SwiftUI
import PromptCore

/// Add, rename, reorder and remove note libraries. Changes apply on Done.
struct LibraryManagerView: View {
    @ObservedObject var model: AppModel
    @State private var drafts: [NoteLibrary] = []
    @State private var loaded = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Libraries").font(.title2.weight(.semibold))
            Text("Each library is a folder of Markdown notes, such as a folder in your Obsidian vault. Removing a library forgets its folder; your notes stay unchanged.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach($drafts) { $library in
                    HStack(spacing: 10) {
                        Picker("Icon", selection: $library.symbol) {
                            ForEach(NoteLibrary.symbols, id: \.self) { symbol in
                                Label(symbol, systemImage: symbol).labelStyle(.iconOnly).tag(symbol)
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).frame(width: 58)
                        .accessibilityLabel("Icon for \(library.title)")
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("Library name", text: $library.name)
                                .textFieldStyle(.roundedBorder)
                            Text(model.folderName(forLibrary: library.id).map { "Folder: \($0)" } ?? "No folder chosen yet")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button(role: .destructive) { drafts.removeAll { $0.id == library.id } } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(library.title)")
                        .accessibilityLabel("Remove \(library.title)")
                    }
                    .padding(.vertical, 4)
                }
                .onMove { drafts.move(fromOffsets: $0, toOffset: $1) }
            }
            .overlay {
                if drafts.isEmpty {
                    Text("No libraries. Add one to browse a folder of notes.")
                        .foregroundStyle(.secondary).allowsHitTesting(false)
                }
            }
            HStack {
                Button {
                    drafts.append(NoteLibrary(name: "New library"))
                } label: { Label("Add library", systemImage: "plus") }
                    .disabled(drafts.count >= NoteLibrary.maximumCount)
                Text("Drag to reorder · up to \(NoteLibrary.maximumCount)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Done") {
                    model.updateLibraries(drafts)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560, height: 480)
        .onAppear {
            guard !loaded else { return }
            drafts = model.libraries
            loaded = true
        }
    }
}
