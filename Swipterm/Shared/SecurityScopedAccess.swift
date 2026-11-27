import Foundation

nonisolated extension URL {
    func withSecurityScopedAccess<Result>(_ body: () throws -> Result) rethrows -> Result {
        let isAccessing = startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                stopAccessingSecurityScopedResource()
            }
        }
        return try body()
    }
}
