/// What ash does with the command it generates. The interpreted command and its
/// explanation are always displayed; the action decides what happens beyond that.
enum Action: String, Codable, CaseIterable {
    case run      // display, then execute
    case confirm  // display, ask y/n, then execute if confirmed
    case copy     // display, then copy to clipboard (no execute)
    case print    // display only

    /// Parse a user-facing value, accepting friendly aliases.
    static func parse(_ s: String) -> Action? {
        switch s.lowercased() {
        case "run", "execute", "exec", "r": return .run
        case "confirm", "ask", "i": return .confirm
        case "copy", "print-and-copy", "pc", "c": return .copy
        case "print", "show", "p": return .print
        default: return nil
        }
    }

    var label: String { rawValue }
}
