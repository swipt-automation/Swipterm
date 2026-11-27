import Foundation
import GRDB
import os

final class PreferenceStore {
    private nonisolated struct Item: Codable, FetchableRecord, PersistableRecord {
        static let databaseTableName = "preferences"

        var name: String
        var data: Data
    }

    private let database: DatabaseQueue

    init(database: DatabaseQueue) {
        self.database = database
    }

    func value<T: Decodable>(_ type: T.Type, for name: String) -> T? {
        guard let item = try! database.read({ try Item.fetchOne($0, key: name) }) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: item.data)
        } catch {
            AppDatabase.logger.error("remove unreadable preference \(name, privacy: .public): \(error, privacy: .public)")
            remove(name)
            return nil
        }
    }

    func set(_ value: some Encodable, for name: String) {
        let data = try! JSONEncoder().encode(value)
        try! database.write { try Item(name: name, data: data).save($0) }
    }

    func remove(_ name: String) {
        _ = try! database.write { try Item.deleteOne($0, key: name) }
    }
}
