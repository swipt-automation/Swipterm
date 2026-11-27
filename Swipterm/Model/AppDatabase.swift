import Foundation
import GRDB
import os

enum AppDatabase {
    nonisolated static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "storage")

    private static let url = URL.applicationSupportDirectory.appending(path: "Swipterm.sqlite")

    static func open() -> DatabaseQueue {
        do {
            do {
                return try load()
            } catch let error as DatabaseError where error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB {
                logger.error("reset \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                try remove()
                return try load()
            }
        } catch {
            fatalError("cannot open \(url.lastPathComponent): \(error)")
        }
    }

    private static func load() throws -> DatabaseQueue {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try DatabaseQueue(path: url.path)
        try migrator.migrate(database)
        return database
    }

    private static func remove() throws {
        for path in [url.path, url.path + "-journal", url.path + "-wal", url.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.removeItem(atPath: path)
        }
    }

    private static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.eraseDatabaseOnSchemaChange = true
        migrator.registerMigration("0.1.0", migrate: createTables)
        return migrator
    }()

    private nonisolated static func createTables(_ db: Database) throws {
        try db.create(table: "preferences") { t in
            t.primaryKey("name", .text)
            t.column("data", .blob).notNull()
        }
    }
}
