import GhosttyTheme
import SwiftUI

struct ThemePickerView: View {
    enum Scheme {
        case light
        case dark
    }

    private let scheme: Scheme
    @Binding private var selection: String
    private let themes: [GhosttyThemeDefinition]

    @State private var searchText = ""
    @Environment(\.dismiss) private var dismiss

    init(scheme: Scheme, selection: Binding<String>) {
        self.scheme = scheme
        _selection = selection
        themes = GhosttyThemeCatalog.allThemes
            .filter { $0.isDark == (scheme == .dark) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if searchText.isEmpty {
                ForEach(groupedKeys, id: \.self) { letter in
                    Section(letter) {
                        ForEach(grouped[letter]!) { theme in
                            themeRow(theme)
                        }
                    }
                }
            } else {
                Section("Themes") {
                    ForEach(themes.filter { $0.name.localizedCaseInsensitiveContains(searchText) }) { theme in
                        themeRow(theme)
                    }
                }
            }
        }
        .searchable(text: $searchText)
        .navigationTitle(scheme == .dark ? "Dark Theme" : "Light Theme")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func themeRow(_ theme: GhosttyThemeDefinition) -> some View {
        Button {
            selection = theme.name
            dismiss()
        } label: {
            HStack {
                Text(theme.name)
                    .foregroundStyle(.primary)
                Spacer()
                if selection == theme.name {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var grouped: [String: [GhosttyThemeDefinition]] {
        Dictionary(grouping: themes) { theme in
            let first = theme.name.prefix(1).uppercased()
            return first.first!.isLetter ? first : "#"
        }
    }

    private var groupedKeys: [String] {
        grouped.keys.sorted()
    }
}
