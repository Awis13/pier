import SwiftTerm
import UIKit

/// SwiftTerm's view, with Pier's Command shortcuts kept for Pier. A program
/// that asks for the kitty keyboard protocol (btop does) gets every press,
/// Command ones too, and UIKit then never matches the key commands of the
/// controllers around the terminal; so a press that one of them lists runs
/// that command here, before the terminal sees it.
final class PierTerminalView: TerminalView {
    private static let mask: UIKeyModifierFlags = [.command, .shift, .alternate, .control]

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            if let key = press.key, key.modifierFlags.contains(.command), run(key) { continue }
            rest.insert(press)
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    /// Finds the shortcut in the responder chain above the view and sends it.
    private func run(_ key: UIKey) -> Bool {
        let flags = key.modifierFlags.intersection(Self.mask)
        let input = key.charactersIgnoringModifiers.lowercased()
        var r = next
        while let responder = r {
            for c in responder.keyCommands ?? [] {
                guard let action = c.action, c.modifierFlags.intersection(Self.mask) == flags,
                      c.input?.lowercased() == input else { continue }
                return UIApplication.shared.sendAction(action, to: responder, from: c, for: nil)
            }
            r = responder.next
        }
        return false
    }
}
