import SwiftUI
import UniformTypeIdentifiers

struct EditGhosttyConfigView: View {
    private let scheme: ThemePickerView.Scheme
    private let configuration: ReferenceWritableKeyPath<AppSettings, String>
    private let settings: AppSettings

    @State private var content: String
    @State private var showFileImporter = false
    @State private var importError: String?

    init(scheme: ThemePickerView.Scheme, settings: AppSettings) {
        self.scheme = scheme
        self.settings = settings
        configuration = scheme == .dark ? \.darkConfig : \.lightConfig
        _content = State(initialValue: settings[keyPath: configuration])
    }

    var body: some View {
        TextEditor(text: $content)
            .font(.system(.caption2, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .task(id: content) {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                settings[keyPath: configuration] = content
            }
            .navigationTitle(scheme == .dark ? "Dark Custom Configuration" : "Light Custom Configuration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Menu {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import from File", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Label("More", systemImage: "line.3.horizontal.circle")
                }
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
                do {
                    let url = try result.get()
                    let data = try url.withSecurityScopedAccess {
                        try Data(contentsOf: url)
                    }
                    guard let text = String(data: data, encoding: .utf8) else {
                        throw CocoaError(.fileReadInapplicableStringEncoding)
                    }
                    content = text
                } catch {
                    importError = error.localizedDescription
                }
            }
            .alert("Couldn’t Import Configuration", isPresented: Binding {
                importError != nil
            } set: { _ in
                importError = nil
            }, presenting: importError) { _ in
            } message: { importError in
                Text(importError)
            }
            .onDisappear {
                settings[keyPath: configuration] = content
            }
    }
}
