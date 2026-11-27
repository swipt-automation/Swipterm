import CoreText
import Foundation
import Observation

@Observable
final class ImportedFontStore {
    private(set) var fonts: [ImportedFont] = []

    private let directory = URL.applicationSupportDirectory.appending(path: "Fonts", directoryHint: .isDirectory)
    private var bootstrapTask: Task<Void, Never>?
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func bootstrap() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }
        let directory = directory
        let task = Task<Void, Never> {
            fonts = await Task.detached {
                try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                for url in Self.contents(of: directory) {
                    _ = CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                }
                return Self.scan(in: directory)
            }.value
        }
        bootstrapTask = task
        await task.value
    }

    func importFile(from sourceURL: URL) async throws {
        try await update { directory in
            let data = try sourceURL.withSecurityScopedAccess {
                try Data(contentsOf: sourceURL)
            }
            let destination = Self.uniqueDestination(in: directory, basedOn: sourceURL)
            try data.write(to: destination, options: .atomic)
            var error: Unmanaged<CFError>?
            guard CTFontManagerRegisterFontsForURL(destination as CFURL, .process, &error) else {
                try? FileManager.default.removeItem(at: destination)
                if let error {
                    throw error.takeRetainedValue() as Error
                }
                throw CocoaError(.fileReadCorruptFile)
            }
            return Self.scan(in: directory)
        }
    }

    func delete(_ font: ImportedFont) async throws {
        try await update { directory in
            _ = CTFontManagerUnregisterFontsForURL(font.fileURL as CFURL, .process, nil)
            try FileManager.default.removeItem(at: font.fileURL)
            return Self.scan(in: directory)
        }
        if settings.fontFamily == font.familyName {
            settings.fontFamily = ""
        }
    }

    private func update(_ operation: @escaping @Sendable (URL) throws -> [ImportedFont]) async throws {
        let directory = directory
        fonts = try await Task.detached { try operation(directory) }.value
    }

    private nonisolated static func contents(of directory: URL) -> [URL] {
        try! FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { ["ttf", "otf", "ttc", "otc"].contains($0.pathExtension.lowercased()) }
    }

    private nonisolated static func scan(in directory: URL) -> [ImportedFont] {
        contents(of: directory)
            .compactMap { url -> ImportedFont? in
                guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
                      let descriptor = descriptors.first,
                      let familyName = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
                else { return nil }
                return ImportedFont(fileURL: url, familyName: familyName)
            }
            .sorted { $0.familyName.localizedCaseInsensitiveCompare($1.familyName) == .orderedAscending }
    }

    private nonisolated static func uniqueDestination(in directory: URL, basedOn sourceURL: URL) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension
        var candidate = directory.appending(path: sourceURL.lastPathComponent)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
            let name = pathExtension.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(pathExtension)"
            candidate = directory.appending(path: name)
            counter += 1
        }
        return candidate
    }
}

nonisolated struct ImportedFont: Identifiable, Hashable, Sendable {
    var id: URL {
        fileURL
    }

    let fileURL: URL
    let familyName: String
}
