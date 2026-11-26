import SwiftUI

struct ManageShortcutsView: View {
    private let settings = AppSettings.shared

    @State private var suggestions: [TerminalShortcut]?
    @State private var editing: TerminalShortcut?
    @State private var suggestionFailure: String?

    var body: some View {
        let commands = Set(settings.shortcuts.map(\.command))
        let visibleSuggestions = (suggestions ?? []).filter { !commands.contains($0.command) }
        List {
            if !settings.shortcuts.isEmpty {
                Section("Shortcuts") {
                    ForEach(settings.shortcuts) { shortcut in
                        row(shortcut)
                    }
                    .onDelete { settings.shortcuts.remove(atOffsets: $0) }
                }
            }
            if !visibleSuggestions.isEmpty {
                Section("Suggested") {
                    ForEach(visibleSuggestions) { shortcut in
                        row(shortcut)
                    }
                }
            }
        }
        .overlay {
            if suggestions != nil, settings.shortcuts.isEmpty, visibleSuggestions.isEmpty {
                ContentUnavailableView("No Shortcuts", systemImage: "terminal")
            }
        }
        .navigationTitle("Shortcuts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = TerminalShortcut()
                } label: {
                    Label("New Shortcut", systemImage: "plus")
                }
            }
        }
        .sheet(item: $editing) { shortcut in
            NavigationStack {
                ShortcutEditorView(
                    shortcut: shortcut,
                    isNew: !settings.shortcuts.contains { $0.id == shortcut.id }
                ) { saved in
                    if let index = settings.shortcuts.firstIndex(where: { $0.id == saved.id }) {
                        settings.shortcuts[index] = saved
                    } else {
                        settings.shortcuts.append(saved)
                    }
                }
            }
        }
        .alert("Couldn’t Load Suggestions", isPresented: Binding {
            suggestionFailure != nil
        } set: { presented in
            if !presented {
                suggestionFailure = nil
            }
        }, presenting: suggestionFailure) { _ in
        } message: { failure in
            Text(failure)
        }
        .task {
            do {
                suggestions = try await TerminalShortcut.suggestions()
            } catch {
                suggestionFailure = error.localizedDescription
            }
        }
    }

    private func row(_ shortcut: TerminalShortcut) -> some View {
        let directory = shortcut.directory.trimmingCharacters(in: .whitespaces)
        let command = shortcut.command
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "; ")
        return Button {
            editing = shortcut
        } label: {
            HStack(spacing: 12) {
                Image(systemName: shortcut.symbolName)
                    .font(.body)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: shortcut.name)
                        .foregroundStyle(.primary)
                    if !directory.isEmpty || !command.isEmpty {
                        HStack(spacing: 6) {
                            if !directory.isEmpty {
                                codeChip(directory)
                            }
                            if !directory.isEmpty, !command.isEmpty {
                                Text(verbatim: "·")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            if !command.isEmpty {
                                codeChip(command)
                            }
                        }
                    }
                }
            }
        }
        .tint(.primary)
    }

    private func codeChip(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.footnote.monospaced())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct ShortcutEditorView: View {
    @State var shortcut: TerminalShortcut
    let isNew: Bool
    let onSave: (TerminalShortcut) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Name") {
                TextField("Name", text: $shortcut.name)
            }
            Section("Icon") {
                NavigationLink {
                    SymbolPickerView(selection: $shortcut.symbolName)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: shortcut.symbolName)
                            .frame(width: 28)
                        Text(verbatim: shortcut.symbolName)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("Directory") {
                TextField("Directory", text: $shortcut.directory, prompt: Text(verbatim: "~"))
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("Command") {
                TextEditor(text: $shortcut.command)
                    .font(.body.monospaced())
                    .frame(minHeight: 120)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        .navigationTitle(isNew ? "New Shortcut" : "Edit Shortcut")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? "Add" : "Save") {
                    onSave(shortcut)
                    dismiss()
                }
                .disabled(shortcut.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
