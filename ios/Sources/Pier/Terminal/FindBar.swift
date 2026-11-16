import SwiftTerm
import UIKit
import UserNotifications

/// Cmd-F: finds text in a terminal's screen and scrollback. Return goes to
/// the match above (the newest output is at the bottom), Shift-Return and
/// Cmd-G to the one below; Escape closes and gives the keys back.
@MainActor
final class FindBar: UIView, UITextFieldDelegate {
    weak var terminal: TerminalView?
    private let field = UITextField()
    private let count = UILabel()
    private let caseButton = UIButton(type: .system)
    private var caseSensitive = false { didSet { caseButton.isSelected = caseSensitive; search(fresh: true) } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 10
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 8

        field.placeholder = "Find"
        field.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.returnKeyType = .search
        field.clearButtonMode = .whileEditing
        field.delegate = self
        field.addTarget(self, action: #selector(changed), for: .editingChanged)

        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.textColor = .secondaryLabel
        count.setContentHuggingPriority(.required, for: .horizontal)

        caseButton.setTitle("Aa", for: .normal)
        caseButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        caseButton.changesSelectionAsPrimaryAction = false
        caseButton.addAction(UIAction { [weak self] _ in self?.caseSensitive.toggle() }, for: .primaryActionTriggered)
        caseButton.accessibilityLabel = "Match Case"

        func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
            let b = UIButton(type: .system)
            b.setImage(UIImage(systemName: symbol), for: .normal)
            b.accessibilityLabel = label
            b.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
            return b
        }
        let stack = UIStackView(arrangedSubviews: [
            UIImageView(image: UIImage(systemName: "magnifyingglass")),
            field, count, caseButton,
            button("chevron.up", "Previous Match") { [weak self] in self?.step(up: true) },
            button("chevron.down", "Next Match") { [weak self] in self?.step(up: false) },
            button("xmark", "Close") { [weak self] in self?.close() },
        ])
        stack.arrangedSubviews.first?.tintColor = .secondaryLabel
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the bar over `host`, for `terminal`, with the selection (if any)
    /// as what to find.
    func open(in host: UIView, for terminal: TerminalView) {
        self.terminal = terminal
        if superview !== host {
            removeFromSuperview()
            translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(self)
            NSLayoutConstraint.activate([
                topAnchor.constraint(equalTo: host.safeAreaLayoutGuide.topAnchor, constant: 8),
                trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
                widthAnchor.constraint(lessThanOrEqualTo: host.widthAnchor, constant: -32),
            ])
        }
        if let picked = terminal.getSelection(), !picked.isEmpty, !picked.contains("\n") {
            field.text = picked
        }
        isHidden = false
        host.bringSubviewToFront(self)
        field.becomeFirstResponder()
        field.selectAll(nil)
        search(fresh: true)
    }

    var isOpen: Bool { superview != nil && !isHidden }

    func close() {
        terminal?.clearSearch()
        isHidden = true
        field.resignFirstResponder()
        terminal?.becomeFirstResponder()
    }

    /// Cmd-G and Cmd-Shift-G, also while the terminal has the keys.
    func step(up: Bool) {
        guard let t = terminal, let text = field.text, !text.isEmpty else { return }
        if up { t.findPrevious(text, options: options) } else { t.findNext(text, options: options) }
        showCount()
    }

    private var options: SearchOptions { SearchOptions(caseSensitive: caseSensitive) }

    @objc private func changed() { search(fresh: true) }

    /// From the bottom up: the newest match first.
    private func search(fresh: Bool) {
        guard let t = terminal else { return }
        t.clearSearch()
        guard let text = field.text, !text.isEmpty else { count.text = ""; return }
        t.findPrevious(text, options: options)
        showCount()
    }

    private func showCount() {
        guard let t = terminal, let text = field.text, !text.isEmpty else { count.text = ""; return }
        let (i, total) = t.searchMatchSummary(text, options: options)
        count.text = total == 0 ? "none" : "\(i)/\(total)"
        count.textColor = total == 0 ? .systemRed : .secondaryLabel
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        step(up: true)
        return false
    }

    override var keyCommands: [UIKeyCommand]? {
        let esc = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(escape))
        esc.wantsPriorityOverSystemBehavior = true
        return [
            esc,
            UIKeyCommand(input: "\r", modifierFlags: .shift, action: #selector(down)),
            UIKeyCommand(title: "Find Next", action: #selector(down), input: "g", modifierFlags: .command),
            UIKeyCommand(title: "Find Previous", action: #selector(up), input: "g", modifierFlags: [.command, .shift]),
        ]
    }

    @objc private func escape() { close() }
    @objc private func down() { step(up: false) }
    @objc private func up() { step(up: true) }
}

/// Says when a command that ran a while ends where it isn't watched: in the
/// background, in another window, or in a tab not on screen.
@MainActor
final class CommandNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CommandNotifier()
    /// Shorter commands end too soon to have been waited for.
    static let after: TimeInterval = 10
    private var asked = false

    func install() { UNUserNotificationCenter.current().delegate = self }

    func ended(_ b: CommandBlock, tab: UUID, service: String, view: TerminalView) {
        guard let s = b.started, let e = b.ended, e.timeIntervalSince(s) >= Self.after else { return }
        let watched = UIApplication.shared.applicationState == .active
            && view.window?.windowScene?.activationState == .foregroundActive
            && view.window?.isKeyWindow == true
        guard !watched else { return }
        let center = UNUserNotificationCenter.current()
        let post = {
            let c = UNMutableNotificationContent()
            let ok = b.exit == 0
            c.title = ok ? "✓ \(b.command)" : "✗ \(b.command)"
            c.body = "\(service) · \(Self.duration(e.timeIntervalSince(s)))" + (ok ? "" : " · exit \(b.exit.map(String.init) ?? "?")")
            c.sound = .default
            c.threadIdentifier = service
            c.userInfo = ["tab": tab.uuidString]
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
        if asked { post(); return }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.asked = true
                if granted { post() }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// A tap shows that tab.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let s = response.notification.request.content.userInfo["tab"] as? String, let id = UUID(uuidString: s) else { return }
        await MainActor.run { NotificationCenter.default.post(name: .pierOpenTab, object: id) }
    }

    private static func duration(_ d: TimeInterval) -> String {
        if d < 60 { return String(format: "%.0fs", d) }
        let m = Int(d) / 60, sec = Int(d) % 60
        return m < 60 ? "\(m)m \(sec)s" : "\(m / 60)h \(m % 60)m"
    }
}

extension Notification.Name {
    /// A notification for a tab was tapped: go to it.
    static let pierOpenTab = Notification.Name("pier.openTab")
}
