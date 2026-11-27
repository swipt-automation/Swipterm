import Foundation
import SwiptermKit

nonisolated struct ClipboardDevice: LinuxCharacterDevice {
    let clipboard: HostClipboard

    func open(access: LinuxFileAccess) throws -> any LinuxCharacterDeviceFile {
        let initialData = switch access {
        case .readOnly, .readWrite:
            try clipboard.read(mime: "text/plain;charset=utf-8") ?? Data()
        case .writeOnly:
            Data()
        }
        return ClipboardDeviceFile(clipboard: clipboard, access: access, initialData: initialData)
    }
}

private final nonisolated class ClipboardDeviceFile: LinuxCharacterDeviceFile, @unchecked Sendable {
    private let clipboard: HostClipboard
    private let access: LinuxFileAccess
    private let lock = NSLock()
    private let readBuffer: Data
    private var readOffset = 0
    private var writeBuffer = Data()
    private var didWrite = false

    init(clipboard: HostClipboard, access: LinuxFileAccess, initialData: Data) {
        self.clipboard = clipboard
        self.access = access
        readBuffer = initialData
    }

    func read(maxLength: Int) throws -> Data {
        guard access != .writeOnly else {
            throw LinuxError.EBADF
        }
        return lock.withLock {
            guard readOffset < readBuffer.count, maxLength > 0 else {
                return Data()
            }
            let end = min(readOffset + maxLength, readBuffer.count)
            defer { readOffset = end }
            return readBuffer.subdata(in: readOffset ..< end)
        }
    }

    func write(_ data: Data) throws -> Int {
        guard access != .readOnly else {
            throw LinuxError.EBADF
        }
        lock.withLock {
            writeBuffer.append(data)
            didWrite = true
        }
        return data.count
    }

    func close() {
        let written: Data? = lock.withLock {
            (didWrite || access == .writeOnly) ? writeBuffer : nil
        }
        if let written {
            clipboard.writePlainTextFromDevice(String(decoding: written, as: UTF8.self))
        }
    }
}
