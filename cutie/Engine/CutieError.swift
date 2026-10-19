import Foundation

/// A friendly error for things the user can fix or should know about.
nonisolated struct CutieError: LocalizedError, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
