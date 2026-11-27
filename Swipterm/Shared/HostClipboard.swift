import Foundation
import SwiptermKit
import UIKit
import UniformTypeIdentifiers

final nonisolated class HostClipboard: LinuxClipboard, @unchecked Sendable {
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

    init() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            UIPasteboard.changedNotification,
            UIPasteboard.removedNotification,
            UIApplication.willEnterForegroundNotification,
            UIApplication.didBecomeActiveNotification,
        ]
        for name in names {
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

    func detach(from runtime: LinuxRuntime) {
        lock.withLock {
            if self.runtime === runtime {
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

    func writePlainTextFromDevice(_ text: String) {
        write([LinuxClipboardItem(mime: "text/plain;charset=utf-8", data: Data(text.utf8))])
        let target = lock.withLock { runtime }
        try? target?.setClipboardOffers(Self.plainTextMIMEs)
    }

    static func offeredMIMETypes(from pasteboard: UIPasteboard) -> [String] {
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
            box.result = data.map(Result.success) ?? .failure(error ?? CocoaError(.fileReadUnknown))
            semaphore.signal()
        }
        semaphore.wait()
        return try box.result!.get()
    }
}

final nonisolated class HostPasteStaging: @unchecked Sendable {
    static let guestDirectory = "/run/host/paste"
    static var hostDirectory: URL {
        FileManager.default.temporaryDirectory.appending(path: "SwiptermPaste", directoryHint: .isDirectory)
    }

    private static let staleFileAge: TimeInterval = 24 * 60 * 60
    private static let linuxNativeImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "svg",
    ]

    enum Source: @unchecked Sendable {
        case file(URL)
        case provider(NSItemProvider, UTType)

        init?(provider: NSItemProvider) {
            guard let type = HostPasteStaging.stageableType(of: provider) else { return nil }
            self = .provider(provider, type)
        }
    }

    private let lock = NSLock()
    private weak var runtime: LinuxRuntime?
    private var usesVirtioFS = true
    private var reservedNames: Set<String> = []

    func attach(to runtime: LinuxRuntime, usesVirtioFS: Bool) {
        lock.withLock {
            self.runtime = runtime
            self.usesVirtioFS = usesVirtioFS
        }
    }

    func detach(from runtime: LinuxRuntime) {
        lock.withLock {
            if self.runtime === runtime {
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

    static func hasPasteboardContent() -> Bool {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasStrings || pasteboard.hasURLs || pasteboard.hasImages {
            return true
        }
        if pasteboard.contains(pasteboardTypes: [UTType.fileURL.identifier]) {
            return true
        }
        return stageableType(among: pasteboard.types.compactMap(UTType.init)) != nil
    }

    static func stageableType(of provider: NSItemProvider) -> UTType? {
        provider.registeredContentTypesForOpenInPlace.first ?? stageableType(among: provider.registeredContentTypes)
    }

    private static func stageableType(among types: [UTType]) -> UTType? {
        if types.contains(where: { $0.conforms(to: .text) }) {
            return nil
        }
        if let image = types.first(where: { $0.conforms(to: .image) }) {
            return image
        }
        return types.first { $0.conforms(to: .data) && !$0.conforms(to: .url) }
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
    func stage(_ sources: [Source], progress: Progress, completion: @escaping @MainActor (Result<String?, any Error>) -> Void) {
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

            var stagedPaths: [String] {
                lock.withLock {
                    values.compactMap { try? $0.get() }
                }
            }
        }
        progress.totalUnitCount = Int64(sources.count)
        let ordered = OrderedPaths(count: sources.count)
        let group = DispatchGroup()
        for (index, source) in sources.enumerated() {
            group.enter()
            let itemProgress = Progress(totalUnitCount: 100, parent: progress, pendingUnitCount: 1)
            switch source {
            case let .file(url):
                DispatchQueue.global(qos: .userInitiated).async { [self] in
                    defer { group.leave() }
                    let copyProgress = Progress(totalUnitCount: 0, parent: itemProgress, pendingUnitCount: 100)
                    ordered.set(Result {
                        try url.withSecurityScopedAccess {
                            try stageSingleSourceFile(at: url, suggestedName: url.lastPathComponent, type: nil, progress: copyProgress)
                        }
                    }, at: index)
                }
            case let .provider(provider, type):
                let suggestedName = provider.suggestedName
                let loadProgress = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [self] url, error in
                    defer { group.leave() }
                    let copyProgress = Progress(totalUnitCount: 0, parent: itemProgress, pendingUnitCount: 10)
                    ordered.set(Result {
                        guard let url else {
                            throw error ?? CocoaError(.fileReadUnknown)
                        }
                        return try stageSingleSourceFile(at: url, suggestedName: suggestedName, type: type, progress: copyProgress)
                    }, at: index)
                }
                itemProgress.addChild(loadProgress, withPendingUnitCount: 90)
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) { @Sendable [self] in
            if progress.isCancelled {
                Self.removeStagedFiles(ordered.stagedPaths)
                DispatchQueue.main.async { completion(.failure(CocoaError(.userCancelled))) }
                return
            }
            do {
                try publishAndComplete(ordered.compacted(), completion: completion)
            } catch {
                Self.removeStagedFiles(ordered.stagedPaths)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private static func removeStagedFiles(_ guestPaths: [String]) {
        let hostDir = hostDirectory
        for guestPath in guestPaths {
            try? FileManager.default.removeItem(at: hostDir.appending(path: (guestPath as NSString).lastPathComponent))
        }
    }

    private func stageSingleSourceFile(at sourceURL: URL, suggestedName: String?, type: UTType?, progress: Progress) throws -> String? {
        let resourceValues = try sourceURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if resourceValues.isDirectory! {
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
        progress.totalUnitCount = Int64(resourceValues.fileSize!)
        if isImage, !Self.linuxNativeImageExtensions.contains(lowerExt) {
            guard let image = try UIImage(data: Data(contentsOf: sourceURL)) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: sourceURL])
            }
            let png = Self.normalizedPNGData(for: image)
            return try storeFile(name: baseName, extension: "png") { destination in
                try png.write(to: destination, options: .atomic)
                progress.completedUnitCount = progress.totalUnitCount
            }
        }
        return try storeFile(name: baseName, extension: rawExtension) { destination in
            try Self.copyFile(from: sourceURL, to: destination, progress: progress)
        }
    }

    private static func copyFile(from source: URL, to destination: URL, progress: Progress) throws {
        if progress.isCancelled {
            throw CocoaError(.userCancelled)
        }
        if clonefile(source.path(percentEncoded: false), destination.path(percentEncoded: false), 0) == 0 {
            progress.completedUnitCount = progress.totalUnitCount
            return
        }
        let input = try FileHandle(forReadingFrom: source)
        FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            if progress.isCancelled {
                try? output.close()
                try? input.close()
                try FileManager.default.removeItem(at: destination)
                throw CocoaError(.userCancelled)
            }
            try output.write(contentsOf: chunk)
            progress.completedUnitCount += Int64(chunk.count)
        }
        try output.close()
        try input.close()
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
