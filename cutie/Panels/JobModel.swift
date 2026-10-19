import Foundation
import Observation

/// One running or finished job, shown as a pill where it was dropped.
@Observable
final class JobModel: Identifiable {
    enum State: Equatable {
        case running(Double?)
        case done(JobOutcome)
        case failed(String)
    }

    let id = UUID()
    let title: String
    let symbol: String
    var state: State = .running(nil)
    var hovering = false

    init(title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var files: [URL] {
        if case .done(let outcome) = state { outcome.files } else { [] }
    }

    var isFinished: Bool {
        if case .running = state { false } else { true }
    }
}
