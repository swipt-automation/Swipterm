import Foundation
import SwiptermKit

final nonisolated class ConsoleNewlineNormalizer: @unchecked Sendable {
    private let lock = NSLock()
    private var lastByteWasCR = false

    func normalize(_ data: Data) -> Data {
        lock.withLock {
            var out = Data()
            out.reserveCapacity(data.count + 16)
            for byte in data {
                if byte == 0x0A, !lastByteWasCR {
                    out.append(0x0D)
                }
                out.append(byte)
                lastByteWasCR = (byte == 0x0D)
            }
            return out
        }
    }
}

nonisolated struct ConsoleBlankLineFilter {
    private var blankLines = Data()
    private var pending = Data()
    private var escape: Data?
    private var lineHasContent = false

    mutating func filter(_ data: Data) -> Data {
        var out = Data()
        for byte in data {
            if lineHasContent {
                out.append(byte)
                lineHasContent = byte != 0x0A
                continue
            }
            if var sequence = escape {
                sequence.append(byte)
                let isCSI = sequence.count > 1 && sequence[sequence.startIndex + 1] == UInt8(ascii: "[")
                if isCSI, sequence.count == 2 || !(0x40 ... 0x7E).contains(byte) {
                    escape = sequence
                    continue
                }
                escape = nil
                if isCSI, byte == UInt8(ascii: "m") {
                    pending.append(sequence)
                } else {
                    out.append(blankLines)
                    beginLine(with: sequence, into: &out)
                }
                continue
            }
            switch byte {
            case 0x0A:
                blankLines.append(pending)
                blankLines.append(byte)
                pending.removeAll()
            case 0x1B:
                escape = Data([byte])
            case 0x00 ... 0x20, 0x7F:
                pending.append(byte)
            default:
                beginLine(with: Data([byte]), into: &out)
            }
        }
        return out
    }

    private mutating func beginLine(with bytes: Data, into out: inout Data) {
        out.append(pending)
        out.append(bytes)
        blankLines.removeAll()
        pending.removeAll()
        lineHasContent = true
    }
}

nonisolated enum ConsoleText {
    static func plain(_ chunks: [Data]) -> String {
        var data = Data()
        for chunk in chunks {
            data.append(chunk)
        }
        var lines: [String] = []
        var line = String.UnicodeScalarView()
        var scalars = String(decoding: data, as: UTF8.self).unicodeScalars.makeIterator()
        var pending: Unicode.Scalar?
        func next() -> Unicode.Scalar? {
            if let scalar = pending {
                pending = nil
                return scalar
            }
            return scalars.next()
        }
        while let scalar = next() {
            switch scalar {
            case "\u{1B}":
                skipEscape(next: next)
            case "\n":
                lines.append(String(line))
                line.removeAll()
            case "\r":
                let following = next()
                if following != "\n" {
                    line.removeAll()
                }
                pending = following
            case "\u{8}":
                if !line.isEmpty {
                    line.removeLast()
                }
            case "\t":
                line.append(scalar)
            default:
                if scalar.value >= 0x20, scalar.value != 0x7F {
                    line.append(scalar)
                }
            }
        }
        if !line.isEmpty {
            lines.append(String(line))
        }
        return lines.joined(separator: "\n")
    }

    private static func skipEscape(next: () -> Unicode.Scalar?) {
        guard let introducer = next() else { return }
        switch introducer {
        case "[":
            while let scalar = next(), !(0x40 ... 0x7E).contains(scalar.value) {}
        case "]", "P", "_", "^":
            var previous: Unicode.Scalar?
            while let scalar = next() {
                if scalar == "\u{7}" || (previous == "\u{1B}" && scalar == "\\") {
                    break
                }
                previous = scalar
            }
        default:
            var scalar: Unicode.Scalar? = introducer
            while let current = scalar, (0x20 ... 0x2F).contains(current.value) {
                scalar = next()
            }
        }
    }
}

nonisolated enum ConsoleMeter {
    case download(DownloadMeter)
    case extraction(name: String?, fraction: Double, elapsed: Duration)

    func lines(width: Int) -> [String] {
        switch self {
        case let .download(meter):
            meter.lines(width: width)
        case let .extraction(name, fraction, elapsed):
            ConsoleLayout.progress(name: name, fields: [ConsoleFormat.clock(elapsed / .seconds(1))], fraction: fraction, width: width)
        }
    }
}

nonisolated struct DownloadMeter {
    private struct Sample {
        let time: ContinuousClock.Instant
        let bytes: Int64
    }

    private static let window = Duration.seconds(3)

    private let start: ContinuousClock.Instant
    private let name: String
    private var now: ContinuousClock.Instant
    private var bytesWritten: Int64 = 0
    private var totalBytes: Int64?
    private var samples: [Sample] = []

    init(start: ContinuousClock.Instant, name: String) {
        self.start = start
        self.name = name
        now = start
    }

    mutating func update(bytesWritten: Int64, totalBytes: Int64?) {
        now = .now
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        samples.append(Sample(time: now, bytes: bytesWritten))
        while samples.count > 2, samples[1].time.duration(to: now) >= Self.window {
            samples.removeFirst()
        }
    }

    func lines(width: Int) -> [String] {
        let elapsed = start.duration(to: now) / .seconds(1)
        let complete = totalBytes.map { bytesWritten >= $0 } ?? false
        let rate = complete ? Double(bytesWritten) / elapsed : recentRate
        var eta = "--:--"
        if complete {
            eta = ConsoleFormat.clock(elapsed)
        } else if let rate, rate > 0, let totalBytes {
            eta = ConsoleFormat.clock(Double(totalBytes - bytesWritten) / rate)
        }
        let fields = [ConsoleFormat.transfer(bytesWritten, of: totalBytes), rate.map(ConsoleFormat.rate), eta].compactMap(\.self)
        let fraction = totalBytes.map { Double(bytesWritten) / Double(max($0, 1)) }
        return ConsoleLayout.progress(name: name, fields: fields, fraction: fraction, width: width)
    }

    private var recentRate: Double? {
        let first = samples.first!, last = samples.last!
        let span = first.time.duration(to: last.time)
        guard span >= .seconds(1) else { return nil }
        return Double(last.bytes - first.bytes) / (span / .seconds(1))
    }
}

nonisolated enum ConsoleFormat {
    private static let units = ["B", "KiB", "MiB", "GiB", "TiB"]

    static func size(_ bytes: Int64) -> String {
        let (divisor, unit) = scale(Double(bytes))
        return String(format: "%.1f", Double(bytes) / divisor) + " " + unit
    }

    static func transfer(_ written: Int64, of total: Int64?) -> String {
        guard let total, written < total else { return size(written) }
        let (divisor, unit) = scale(Double(total))
        return String(format: "%.1f / %.1f", Double(written) / divisor, Double(total) / divisor) + " " + unit
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        let (divisor, unit) = scale(bytesPerSecond)
        let value = bytesPerSecond / divisor
        let format = value < 9.995 ? "%.2f" : value < 99.95 ? "%.1f" : "%.0f"
        return String(format: format, value) + " " + unit + "/s"
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds < 100 * 3600 else { return "--:--" }
        let seconds = Int(seconds)
        let (hours, minutes) = (seconds / 3600, seconds / 60 % 60)
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
        }
        return String(format: "%02d:%02d", minutes, seconds % 60)
    }

    private static func scale(_ value: Double) -> (divisor: Double, unit: String) {
        var divisor = 1.0
        var index = 0
        while index < units.count - 1, value / divisor > 2048 {
            divisor *= 1024
            index += 1
        }
        return (divisor, units[index])
    }
}

nonisolated enum ConsoleLayout {
    private static let minimumBar = 10
    private static let minimumName = 8

    static func progress(name: String?, fields: [String], fraction: Double?, width: Int) -> [String] {
        guard let fraction else {
            return Self.info(name: name, fields: fields, width: width)
        }
        let info = fields.joined(separator: " ")
        let percent = String(format: "%3d%%", Int(fraction * 100))
        let tail = info.count + 1 + 1 + percent.count
        if let name {
            let room = width - 1 - 2 - tail - minimumBar
            if room >= min(name.count, minimumName) {
                let label = String(name.prefix(room))
                let available = width - 1 - label.count - 2 - tail
                let barWidth = min(available, max(minimumBar, width * 2 / 5))
                return [" " + label + String(repeating: " ", count: 2 + available - barWidth) + info + " " + bar(fraction, width: barWidth) + " " + percent]
            }
        } else if width - 1 - tail >= minimumBar {
            let barWidth = min(width - 1 - tail, max(minimumBar, width * 2 / 5))
            return [" " + info + " " + bar(fraction, width: barWidth) + " " + percent]
        }
        return Self.info(name: name, fields: fields, width: width) + [" " + bar(fraction, width: width - 2 - percent.count) + " " + percent]
    }

    private static func info(name: String?, fields: [String], width: Int) -> [String] {
        var fields = fields
        while fields.count > 1, 1 + fields.joined(separator: " ").count > width {
            fields.removeLast()
        }
        let info = String(fields.joined(separator: " ").prefix(width - 1))
        guard let name else {
            return [" " + info]
        }
        let gap = width - 1 - name.count - info.count
        if gap >= 2 {
            return [" " + name + String(repeating: " ", count: gap) + info]
        }
        return [" " + String(name.prefix(width - 1)), " " + info]
    }

    private static func bar(_ fraction: Double, width: Int) -> String {
        let inner = width - 2
        let filled = Int(Double(inner) * fraction)
        return "[" + String(repeating: "#", count: filled) + String(repeating: "-", count: inner - filled) + "]"
    }
}

final class ConsoleBuffer {
    private struct Progress {
        var meter: ConsoleMeter
        var chunkIndex: Int?
        var lineLengths: [Int] = []
    }

    private(set) var chunks: [Data] = []
    private(set) var progressEpoch: UInt64 = 0
    private(set) var isClosed = false
    private var listeners: [UUID: (Data) -> Void] = [:]
    private var openProgress: Progress?
    private var columns: UInt16 = 40

    var text: String {
        ConsoleText.plain(chunks)
    }

    func subscribe(_ handler: @escaping (Data) -> Void) -> UUID {
        let id = UUID()
        for chunk in chunks {
            handler(chunk)
        }
        if !isClosed {
            listeners[id] = handler
        }
        return id
    }

    func unsubscribe(_ id: UUID) {
        listeners.removeValue(forKey: id)
    }

    func close() {
        isClosed = true
        listeners.removeAll()
    }

    func resize(columns: UInt16) {
        guard columns != self.columns else { return }
        self.columns = columns
        if openProgress != nil {
            renderProgress()
        }
    }

    func append(_ chunk: Data) {
        guard !isClosed else { return }
        chunks.append(chunk)
        for listener in listeners.values {
            listener(chunk)
        }
    }

    func appendStep(_ title: String) {
        endProgress()
        appendLines("\u{1B}[1m==> \(title)\u{1B}[0m\r\n")
    }

    func appendError(_ message: String) {
        endProgress()
        appendLines("\u{1B}[1;31merror:\u{1B}[0m \(message)\r\n")
    }

    func updateProgress(_ meter: ConsoleMeter, epoch: UInt64) {
        guard !isClosed, progressEpoch == epoch else { return }
        var progress = openProgress ?? Progress(meter: meter)
        progress.meter = meter
        openProgress = progress
        renderProgress()
    }

    func updateDownload(bytesWritten: Int64, totalBytes: Int64?, name: String, start: ContinuousClock.Instant, epoch: UInt64) {
        var meter = DownloadMeter(start: start, name: name)
        if case let .download(current)? = openProgress?.meter {
            meter = current
        }
        meter.update(bytesWritten: bytesWritten, totalBytes: totalBytes)
        updateProgress(.download(meter), epoch: epoch)
    }

    func endProgress() {
        progressEpoch &+= 1
        let rendered = openProgress?.chunkIndex != nil
        openProgress = nil
        if rendered {
            append(Data("\r\n".utf8))
        }
    }

    private func appendLines(_ text: String) {
        let atLineStart = chunks.last.map { $0.last == 0x0A } ?? true
        append(Data(((atLineStart ? "" : "\r\n") + text).utf8))
    }

    private func renderProgress() {
        var progress = openProgress!
        let columns = Int(columns)
        let lines = progress.meter.lines(width: max(columns - 1, 20))
        let snapshot = lines.joined(separator: "\r\n")
        let rows = progress.lineLengths.reduce(0) { $0 + max(($1 + columns - 1) / columns, 1) }
        let redraw = Data(("\r" + (rows > 1 ? "\u{1B}[\(rows - 1)A" : "") + "\u{1B}[J" + snapshot).utf8)
        if let chunkIndex = progress.chunkIndex {
            chunks[chunkIndex] = Data(snapshot.utf8)
        } else {
            progress.chunkIndex = chunks.count
            chunks.append(Data(snapshot.utf8))
        }
        progress.lineLengths = lines.map(\.count)
        openProgress = progress
        for listener in listeners.values {
            listener(redraw)
        }
    }
}
