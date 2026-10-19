import AppKit

nonisolated enum SaveLocation: String, CaseIterable, Sendable {
    case nextToOriginal, downloads

    var name: String {
        switch self {
        case .nextToOriginal: "Next to the original"
        case .downloads: "In Downloads"
        }
    }
}
