import AppKit
import Carbon.HIToolbox

/// ⌃⌥C anywhere: open the Convert wheel for the files selected in Finder.
/// A Carbon hot key needs no permission; asking Finder for its selection
/// needs Automation permission once ("Cutie wants to control Finder").
final class FinderHotKey {
    static let display = "⌃⌥C"
    var onPress: () -> Void = {}

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static weak var current: FinderHotKey?

    func register() {
        guard hotKey == nil else { return }
        Self.current = self
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { FinderHotKey.current?.onPress() } }
            return noErr
        }, 1, &type, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x4355_5449), id: 1) // "CUTI"
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    /// The POSIX paths of Finder's selection (the frontmost Finder window or the Desktop).
    static func finderSelection() async throws -> [URL] {
        let script = """
        tell application "Finder" to set theSelection to selection as alias list
        set output to ""
        repeat with theItem in theSelection
            set output to output & POSIX path of theItem & linefeed
        end repeat
        return output
        """
        do {
            let text = try await Shell.run(Shell.osascript, ["-e", script])
            return text.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
        } catch let failure as Shell.Failure where failure.output.contains("-1743") {
            throw CutieError("Cutie isn't allowed to ask Finder. Turn it on in System Settings ▸ Privacy & Security ▸ Automation.")
        }
    }
}
