import AppKit
import Observation
import SwiftUI

/// Float: a little shelf that holds files above every window until you drag
/// them somewhere. Drop more files on it to add them.
@Observable
final class FloatModel {
    var files: [URL]
    init(files: [URL]) { self.files = files }
}
