import Foundation
import SwiptermKit
import UIKit
import UniformTypeIdentifiers

final nonisolated class HostClipboard: LinuxClipboard, @unchecked Sendable {
    static let shared = HostClipboard()

    private static let plainTextMIMEs = [
        "text/plain;charset=utf-8",
        "UTF8_STRING",
        "text/plain",
        "STRING",
        "TEXT",
    ]

    private let lock = NSLock()
    private weak var runtime: LinuxRuntime?
    private var lastObservedChangeCount = -1
    private var isWritingFromGuest = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIPasteboard.changedNotification,
            UIPasteboard.removedNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.didBecomeActiveNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                self.syncOffers(force: false)
            }
        }
    }

    func attach(to runtime: LinuxRuntime) {
        lock.withLock {
            self.runtime = runtime
            lastObservedChangeCount = -1
        }
        syncOffers(force: true)
    }

    func detach(from runtime: LinuxRuntime?) {
        lock.withLock {
            if self.runtime === runtime || runtime == nil {
                self.runtime = nil
            }
        }
    }

    func syncOffers(force: Bool) {
        let pasteboard = UIPasteboard.general
        let target: LinuxRuntime? = lock.withLock {
            guard !isWritingFromGuest, let runtime else { return nil }
            let changeCount = pasteboard.changeCount
            if !force, changeCount == lastObservedChangeCount {
                return nil
            }
            lastObservedChangeCount = changeCount
            return runtime
        }
        guard let target else { return }
        let mimes = Self.offeredMIMETypes(from: pasteboard)
        try? target.setClipboardOffers(mimes)
    }

    func read(mime: String) throws -> Data? {
        let pasteboard = UIPasteboard.general
        if Self.plainTextMIMEs.contains(mime) || mime.hasPrefix("text/plain") {
            if pasteboard.hasStrings, let string = pasteboard.string {
                return Data(string.utf8)
            }
            if pasteboard.hasURLs, let url = pasteboard.url {
                return Data(url.absoluteString.utf8)
            }
            if let data = try Self.loadProviderData(from: pasteboard.itemProviders, conformingTo: .plainText) {
                return data
            }
            return nil
        }

        if mime == "text/html" {
            if let data = try Self.loadProviderData(from: pasteboard.itemProviders, conformingTo: .html) {
                return data
            }
            if let raw = pasteboard.data(forPasteboardType: UTType.html.identifier) {
                return raw
            }
            if let text = pasteboard.value(forPasteboardType: UTType.html.identifier) as? String {
                return Data(text.utf8)
            }
            return nil
        }

        if mime == "image/png" {
            let providers = pasteboard.itemProviders
            if let png = try Self.loadProviderData(from: providers, exactType: .png) {
                return png
            }
            if let png = pasteboard.data(forPasteboardType: UTType.png.identifier) {
                return png
            }
            if let rawImage = try Self.loadProviderData(from: providers, conformingTo: .image),
               let image = UIImage(data: rawImage)
            {
                return HostPasteStaging.normalizedPNGData(for: image)
            }
            if let image = pasteboard.image {
                return HostPasteStaging.normalizedPNGData(for: image)
            }
            return nil
        }

        let targetType: UTType? = switch mime {
        case "image/jpeg": .jpeg
        case "image/gif": .gif
        case "image/webp": .webP
        case "image/svg+xml": .svg
        default: nil
        }
        if let targetType {
            if let data = try Self.loadProviderData(from: pasteboard.itemProviders, exactType: targetType) {
                return data
            }
            if let data = pasteboard.data(forPasteboardType: targetType.identifier) {
                return data
            }
        }
        return nil
    }

    func write(_ items: [LinuxClipboardItem]) {
        let pasteboard = UIPasteboard.general
        var representation: [String: Any] = [:]
        for item in items {
            if Self.plainTextMIMEs.contains(item.mime) || item.mime.hasPrefix("text/plain") {
                if representation[UTType.utf8PlainText.identifier] == nil {
                    representation[UTType.utf8PlainText.identifier] = String(decoding: item.data, as: UTF8.self)
                }
            } else if item.mime == "text/html" {
                representation[UTType.html.identifier] = item.data
            } else if item.mime == "image/png" {
                representation[UTType.png.identifier] = item.data
            } else if item.mime == "image/jpeg" {
                representation[UTType.jpeg.identifier] = item.data
            } else if item.mime == "image/gif" {
                representation[UTType.gif.identifier] = item.data
            } else if item.mime == "image/webp" {
                representation[UTType.webP.identifier] = item.data
            } else if item.mime == "image/svg+xml" {
                representation[UTType.svg.identifier] = item.data
            }
        }

        if representation.isEmpty, !items.isEmpty {
            return
        }
        lock.withLock {
            isWritingFromGuest = true
        }
        pasteboard.items = representation.isEmpty ? [] : [representation]
        let updatedCount = pasteboard.changeCount
        lock.withLock {
            isWritingFromGuest = false
            lastObservedChangeCount = updatedCount
        }
    }

    static func writePlainTextFromDevice(_ text: String) {
        shared.write([LinuxClipboardItem(mime: "text/plain;charset=utf-8", data: Data(text.utf8))])
        let mimes = plainTextMIMEs
        let target = shared.lock.withLock { shared.runtime }
        try? target?.setClipboardOffers(mimes)
    }

    static func offeredMIMETypes(from pasteboard: UIPasteboard = .general) -> [String] {
        let types = pasteboard.types.compactMap(UTType.init)

        var mimes: [String] = []
        let hasText = pasteboard.hasStrings
            || pasteboard.hasURLs
            || types.contains { $0.conforms(to: .text) || $0.conforms(to: .url) }
        if hasText {
            mimes.append(contentsOf: plainTextMIMEs)
        }
        if types.contains(where: { $0.conforms(to: .html) }) {
            mimes.append("text/html")
        }
        let hasImage = pasteboard.hasImages || types.contains { $0.conforms(to: .image) }
        if hasImage {
            mimes.append("image/png")
            if types.contains(where: { $0.conforms(to: .jpeg) }) {
                mimes.append("image/jpeg")
            }
            if types.contains(where: { $0.conforms(to: .gif) }) {
                mimes.append("image/gif")
            }
            if types.contains(where: { $0.conforms(to: .webP) }) {
                mimes.append("image/webp")
            }
            if types.contains(where: { $0.conforms(to: .svg) }) {
                mimes.append("image/svg+xml")
            }
        }
        return mimes
    }

    private static func loadProviderData(from providers: [NSItemProvider], exactType: UTType) throws -> Data? {
        let provider = providers.first { provider in
            provider.registeredTypeIdentifiers.contains { UTType($0) == exactType }
        }
        return try provider.map { try loadDataSynchronously(from: $0, typeIdentifier: exactType.identifier) }
    }

    private static func loadProviderData(from providers: [NSItemProvider], conformingTo target: UTType) throws -> Data? {
        for provider in providers {
            if let identifier = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: target) == true }) {
                return try loadDataSynchronously(from: provider, typeIdentifier: identifier)
            }
        }
        return nil
    }

    private static func loadDataSynchronously(from provider: NSItemProvider, typeIdentifier: String) throws -> Data {
        final class Box: @unchecked Sendable {
            var result: Result<Data, any Error>?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        _ = provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
            box.result = data.map(Result.success) ?? .failure(error!)
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }
}

final nonisolated class HostPasteStaging: @unchecked Sendable {
    static let shared = HostPasteStaging()

    static let guestDirectory = "/run/host/paste"
    static var hostDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "SwiptermPaste", directoryHint: .isDirectory)
    }

    private static let staleFileAge: TimeInterval = 24 * 60 * 60
    private static let linuxNativeImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg",
    ]

    struct ProviderItem: @unchecked Sendable {
        let provider: NSItemProvider
        let type: UTType
    }

    private let lock = NSLock()
    private weak var runtime: LinuxRuntime?
    private var usesVirtioFS = true
    private var reservedNames: Set<String> = []

    private init() {}

    func attach(to runtime: LinuxRuntime, usesVirtioFS: Bool) {
        lock.withLock {
            self.runtime = runtime
            self.usesVirtioFS = usesVirtioFS
        }
    }

    func detach(from runtime: LinuxRuntime?) {
        lock.withLock {
            if self.runtime === runtime || runtime == nil {
                self.runtime = nil
            }
        }
    }

    static func prepareHostDirectory() throws {
        let directory = hostDirectory
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let cutoff = Date().addingTimeInterval(-staleFileAge)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            if try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate! < cutoff {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    static func removeAllFiles() throws {
        do {
            try FileManager.default.removeItem(at: hostDirectory)
        } catch CocoaError.fileNoSuchFile {}
    }

    static func hasPasteboardContent(_ pasteboard: UIPasteboard = .general) -> Bool {
        if pasteboard.hasStrings || pasteboard.hasURLs || pasteboard.hasImages {
            return true
        }
        if pasteboard.contains(pasteboardTypes: [UTType.fileURL.identifier]) {
            return true
        }
        return stageableType(among: pasteboard.types) != nil
    }

    static func stageableType(among identifiers: [String]) -> UTType? {
        let types = identifiers.compactMap(UTType.init)
        if let image = types.first(where: { $0.conforms(to: .image) }) {
            return image
        }
        if types.contains(where: { $0.conforms(to: .text) }) {
            return nil
        }
        return types.first { type in
            !type.isDynamic
                && type.conforms(to: .data)
                && !type.conforms(to: .text)
                && !type.conforms(to: .url)
        }
    }

    static func plainText(string: String?, urls: [URL]) -> String? {
        let nonFileURLs = urls.filter { url in
            !url.isFileURL && (string.map { !urlSpellsString($0, url) } ?? true)
        }
        if !nonFileURLs.isEmpty {
            return nonFileURLs.map(\.absoluteString).joined(separator: " ")
        }
        guard let string, !string.isEmpty else { return nil }
        return string
    }

    static func fileURLs(in pasteboard: UIPasteboard) -> [URL] {
        var result: [URL] = []
        if pasteboard.hasURLs, let urls = pasteboard.urls {
            result.append(contentsOf: urls.filter(\.isFileURL))
        }
        if result.isEmpty, pasteboard.contains(pasteboardTypes: [UTType.fileURL.identifier]) {
            for item in pasteboard.items {
                guard let raw = item[UTType.fileURL.identifier] else { continue }
                if let url = raw as? URL, url.isFileURL {
                    result.append(url)
                } else if let data = raw as? Data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                    result.append(url)
                } else if let str = raw as? String, let url = URL(string: str), url.isFileURL {
                    result.append(url)
                }
            }
        }
        return result
    }

    static func normalizedPNGData(for image: UIImage) -> Data {
        if image.imageOrientation == .up, let data = image.pngData() {
            return data
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = false
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return rendered.pngData()!
    }

    @MainActor
    func stageFileURLs(_ urls: [URL], completion: @escaping @MainActor (Result<String?, any Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            do {
                try Self.prepareHostDirectory()
                let staged = try urls.compactMap { url -> String? in
                    let isAccessingSecurityScope = url.startAccessingSecurityScopedResource()
                    defer {
                        if isAccessingSecurityScope {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    return try stageSingleSourceFile(at: url, suggestedName: url.lastPathComponent, type: nil)
                }
                publishAndComplete(staged, completion: completion)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    @MainActor
    func stageProviders(_ items: [ProviderItem], completion: @escaping @MainActor (Result<String?, any Error>) -> Void) {
        do {
            try Self.prepareHostDirectory()
        } catch {
            completion(.failure(error))
            return
        }
        final class OrderedPaths: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [Result<String?, any Error>]
            init(count: Int) {
                values = Array(repeating: .success(nil), count: count)
            }

            func set(_ value: Result<String?, any Error>, at index: Int) {
                lock.withLock { values[index] = value }
            }

            func compacted() throws -> [String] {
                try lock.withLock { try values.compactMap { try $0.get() } }
            }
        }
        let ordered = OrderedPaths(count: items.count)
        let group = DispatchGroup()
        for (index, item) in items.enumerated() {
            group.enter()
            let suggested = item.provider.suggestedName
            let itemType = item.type
            item.provider.loadFileRepresentation(forTypeIdentifier: itemType.identifier) { [self] url, error in
                defer { group.leave() }
                ordered.set(Result {
                    guard let url else { throw error! }
                    return try stageSingleSourceFile(at: url, suggestedName: suggested, type: itemType)
                }, at: index)
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) { @Sendable [self] in
            do {
                try publishAndComplete(ordered.compacted(), completion: completion)
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func stageSingleSourceFile(at sourceURL: URL, suggestedName: String?, type: UTType?) throws -> String? {
        if try sourceURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory! {
            return nil
        }
        var resolvedType = type
        if resolvedType == nil, !sourceURL.pathExtension.isEmpty {
            resolvedType = UTType(filenameExtension: sourceURL.pathExtension)
        }
        let (baseName, rawExtension) = Self.splitFileName(suggestedName ?? sourceURL.lastPathComponent, type: resolvedType)
        let lowerExt = rawExtension.lowercased()
        let isImage = (resolvedType?.conforms(to: .image) ?? false)
            || UTType(filenameExtension: lowerExt)?.conforms(to: .image) == true
        if isImage, !Self.linuxNativeImageExtensions.contains(lowerExt) {
            guard let image = try UIImage(data: Data(contentsOf: sourceURL)) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: sourceURL])
            }
            let png = Self.normalizedPNGData(for: image)
            return try storeFile(name: baseName, extension: "png") { destination in
                try png.write(to: destination, options: .atomic)
            }
        }
        return try storeFile(name: baseName, extension: rawExtension) { destination in
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        }
    }

    private func storeFile(name: String, extension fileExtension: String, write: (URL) throws -> Void) throws -> String {
        let cleanName = name.isEmpty ? "file" : Self.shellSafeName(name)
        let suffix = fileExtension.isEmpty ? "" : "." + Self.shellSafeName(fileExtension)
        let directory = Self.hostDirectory
        let fileName: String = lock.withLock {
            let stamp = Int(Date().timeIntervalSince1970)
            var candidate = "\(cleanName)-\(stamp)\(suffix)"
            var counter = 1
            while reservedNames.contains(candidate)
                || FileManager.default.fileExists(atPath: directory.appending(path: candidate).path(percentEncoded: false))
            {
                candidate = "\(cleanName)-\(stamp)-\(counter)\(suffix)"
                counter += 1
            }
            reservedNames.insert(candidate)
            return candidate
        }
        defer {
            lock.withLock { _ = reservedNames.remove(fileName) }
        }
        let destination = directory.appending(path: fileName)
        try write(destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644, .modificationDate: Date()],
            ofItemAtPath: destination.path(percentEncoded: false)
        )
        return Self.guestDirectory + "/" + fileName
    }

    private func publishAndComplete(_ guestPaths: [String], completion: @escaping @MainActor (Result<String?, any Error>) -> Void) {
        guard !guestPaths.isEmpty else {
            DispatchQueue.main.async { completion(.success(nil)) }
            return
        }
        let (targetRuntime, virtioFS) = lock.withLock { (runtime, usesVirtioFS) }
        let joined = guestPaths.joined(separator: " ")
        if !virtioFS, let targetRuntime {
            let hostDir = Self.hostDirectory
            Task.detached(priority: .userInitiated) {
                let result: Result<String?, any Error>
                do {
                    for guestPath in guestPaths {
                        let hostFile = hostDir.appending(path: (guestPath as NSString).lastPathComponent)
                        try await targetRuntime.fileSystem.writeFile(guestPath, contents: Data(contentsOf: hostFile), permissions: 0o644)
                    }
                    result = .success(joined)
                } catch {
                    result = .failure(error)
                }
                await MainActor.run {
                    completion(result)
                }
            }
            return
        }
        DispatchQueue.main.async {
            completion(.success(joined))
        }
    }

    private static func splitFileName(_ fileName: String, type: UTType?) -> (name: String, extension: String) {
        let fileName = fileName as NSString
        let ext = fileName.pathExtension
        if ext.isEmpty {
            return (fileName as String, type?.preferredFilenameExtension ?? "")
        }
        return (fileName.deletingPathExtension, ext)
    }

    private static func shellSafeName(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" ? $0 : "_" })
    }

    private static func urlSpellsString(_ string: String, _ url: URL) -> Bool {
        let lhs = (url.absoluteString.removingPercentEncoding ?? url.absoluteString).trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = (string.removingPercentEncoding ?? string).trimmingCharacters(in: .whitespacesAndNewlines)
        return lhs == rhs
    }
}
