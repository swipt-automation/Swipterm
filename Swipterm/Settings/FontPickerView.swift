import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FontPickerView: View {
    @Binding private var selection: String
    private let families: [String]

    @EnvironmentObject private var fontStore: ImportedFontStore
    @State private var searchText = ""
    @State private var showFileImporter = false
    @State private var errorMessage: String?
    @State private var editMode: EditMode = .inactive
    @Environment(\.dismiss) private var dismiss

    init(selection: Binding<String>) {
        _selection = selection
        families = UIFont.familyNames
            .filter { family in
                UIFont.fontNames(forFamilyName: family).contains { name in
                    UIFont(name: name, size: 12)?.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) == true
                }
            }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                Section {
                    familyRow(name: "", label: String(localized: "Follow Theme"))
                }
                if !fontStore.fonts.isEmpty {
                    Section("Imported") {
                        ForEach(fontStore.fonts) { font in
                            familyRow(name: font.familyName, label: font.familyName)
                        }
                        .onDelete { offsets in
                            let targets = offsets.map { fontStore.fonts[$0] }
                            Task { await deleteImported(targets) }
                        }
                    }
                }
                ForEach(groupedKeys, id: \.self) { letter in
                    Section(letter) {
                        ForEach(grouped[letter]!, id: \.self) { family in
                            familyRow(name: family, label: family)
                        }
                    }
                }
            } else {
                Section("Fonts") {
                    ForEach(filteredFamilies, id: \.self) { family in
                        familyRow(name: family, label: family)
                    }
                }
            }
        }
        .searchable(text: $searchText)
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import from File", systemImage: "doc.badge.plus")
                    }
                    if !fontStore.fonts.isEmpty {
                        Button {
                            withAnimation {
                                editMode = editMode.isEditing ? .inactive : .active
                            }
                        } label: {
                            Label(editMode.isEditing ? "Done" : "Manage Imported Fonts", systemImage: "slider.horizontal.3")
                        }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("Couldn’t Update Fonts", isPresented: Binding {
            errorMessage != nil
        } set: { _ in
            errorMessage = nil
        }, presenting: errorMessage) { _ in
        } message: { errorMessage in
            Text(errorMessage)
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.font], allowsMultipleSelection: true) { result in
            Task {
                do {
                    for url in try result.get() {
                        try await fontStore.importFile(from: url)
                    }
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func familyRow(name: String, label: String) -> some View {
        Button {
            selection = name
            dismiss()
        } label: {
            HStack {
                Text(label)
                    .font(name.isEmpty ? .body : .custom(name, size: 17))
                    .foregroundStyle(.primary)
                Spacer()
                if selection == name {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var filteredFamilies: [String] {
        var seen = Set<String>()
        return (fontStore.fonts.map(\.familyName) + families)
            .filter { seen.insert($0).inserted && $0.localizedCaseInsensitiveContains(searchText) }
    }

    private var grouped: [String: [String]] {
        let imported = Set(fontStore.fonts.map(\.familyName))
        return Dictionary(grouping: families.filter { !imported.contains($0) }) { family in
            let first = family.prefix(1).uppercased()
            return first.first!.isLetter ? first : "#"
        }
    }

    private var groupedKeys: [String] {
        grouped.keys.sorted()
    }

    private func deleteImported(_ targets: [ImportedFont]) async {
        for font in targets {
            do {
                try await fontStore.delete(font)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        if fontStore.fonts.isEmpty, editMode.isEditing {
            withAnimation { editMode = .inactive }
        }
    }
}
