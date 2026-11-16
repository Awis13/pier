import UIKit

/// Native tabs for the windows of a tmux session, in the strip beside the
/// window controls. Each tab shows its number and name, a dot for new output
/// in the background and an orange dot for a bell.
final class TabBar: UIView {
    var onSelect: ((Int) -> Void)?
    var onNew: (() -> Void)?
    var onRename: ((TmuxWindow) -> Void)?
    var onClose: ((TmuxWindow) -> Void)?
    var onWatch: ((TmuxWindow) -> Void)?
    var isWatched: ((TmuxWindow) -> Bool)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let plus = UIButton(type: .system)
    private(set) var windows: [TmuxWindow] = []
    private var unseen: Set<Int> = []
    private var fg = UIColor.white

    var activeWindow: TmuxWindow? { windows.first(where: \.active) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        stack.axis = .horizontal
        stack.spacing = 4
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        plus.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)), for: .normal)
        plus.accessibilityLabel = "New tab"
        plus.addAction(UIAction { [weak self] _ in self?.onNew?() }, for: .touchUpInside)
        plus.hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 8))
        plus.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            plus.widthAnchor.constraint(equalToConstant: 30),
            plus.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setForeground(_ color: UIColor) {
        fg = color
        plus.tintColor = color.withAlphaComponent(0.7)
        rebuild()
    }

    /// Shows ws. A background window whose output moved on since it was last
    /// active gets the activity dot until it is selected.
    func update(_ ws: [TmuxWindow], force: Bool = false) {
        let old = Dictionary(windows.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
        for w in ws {
            if w.active {
                unseen.remove(w.index)
            } else if let o = old[w.index], w.activity > o.activity {
                unseen.insert(w.index)
            }
        }
        unseen.formIntersection(ws.map(\.index))
        guard ws != windows || old.isEmpty || force else { return }
        windows = ws
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for w in windows {
            stack.addArrangedSubview(tab(for: w))
        }
        stack.addArrangedSubview(plus)
        if let active = windows.firstIndex(where: \.active) {
            layoutIfNeeded()
            scroll.scrollRectToVisible(stack.arrangedSubviews[active].frame.insetBy(dx: -20, dy: 0), animated: true)
        }
    }

    /// A tab: its title (tap to select, press and hold for the menu) and a
    /// close button big enough for a finger or the Pencil, on one pill.
    private func tab(for w: TmuxWindow) -> UIView {
        var cfg = UIButton.Configuration.plain()
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 2)
        let title = NSMutableAttributedString()
        if w.bell {
            title.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: UIColor.systemOrange]))
        } else if unseen.contains(w.index) {
            title.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: fg.withAlphaComponent(0.6)]))
        }
        let small = UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let font = UIFont.systemFont(ofSize: 13, weight: w.active ? .semibold : .regular)
        title.append(NSAttributedString(string: "\(w.index) ", attributes: [.font: small, .foregroundColor: fg.withAlphaComponent(0.45)]))
        title.append(NSAttributedString(string: w.name, attributes: [.font: font, .foregroundColor: fg.withAlphaComponent(w.active ? 1 : 0.7)]))
        if w.sync {
            // Typing goes to every pane: hard to miss on purpose.
            title.append(NSAttributedString(string: " ⇶ all panes", attributes: [.font: small, .foregroundColor: UIColor.systemOrange]))
        }
        if w.panes > 1 {
            title.append(NSAttributedString(string: " ⧉\(w.panes)", attributes: [.font: small, .foregroundColor: fg.withAlphaComponent(0.45)]))
        }
        cfg.attributedTitle = AttributedString(title)
        cfg.titleLineBreakMode = .byTruncatingTail
        let b = UIButton(configuration: cfg)
        b.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
        b.accessibilityLabel = "Tab \(w.index), \(w.name)"
        b.addAction(UIAction { [weak self] _ in self?.onSelect?(w.index) }, for: .touchUpInside)
        b.menu = UIMenu(children: [
            UIAction(title: "Rename…", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.onRename?(w) },
            UIAction(title: "Notify on Output", image: UIImage(systemName: "bell.badge"),
                     state: isWatched?(w) == true ? .on : .off) { [weak self] _ in self?.onWatch?(w) },
            UIAction(title: "Close Tab", image: UIImage(systemName: "xmark"), attributes: .destructive) { [weak self] _ in
                self?.onClose?(w)
            },
        ])

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)), for: .normal)
        close.tintColor = fg.withAlphaComponent(w.active ? 0.7 : 0.45)
        // The system lift: under a hovering Pencil or the pointer the button
        // rises and follows the tip, as links and buttons do across iPadOS.
        close.hoverStyle = UIHoverStyle(effect: .lift, shape: .circle)
        close.accessibilityLabel = "Close tab \(w.index)"
        close.addAction(UIAction { [weak self] _ in self?.onClose?(w) }, for: .touchUpInside)
        close.widthAnchor.constraint(equalToConstant: 28).isActive = true
        close.heightAnchor.constraint(equalToConstant: 28).isActive = true

        b.hoverStyle = UIHoverStyle(effect: .highlight, shape: .rect(cornerRadius: 8))
        let pill = UIStackView(arrangedSubviews: [b, close])
        pill.axis = .horizontal
        pill.alignment = .center
        pill.spacing = 0
        pill.layoutMargins = UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 2)
        pill.isLayoutMarginsRelativeArrangement = true
        pill.backgroundColor = w.active ? fg.withAlphaComponent(0.16) : .clear
        pill.layer.cornerRadius = 8
        return pill
    }
}

/// A yes-or-no question answered from the keyboard as well as by touch:
/// the arrows (or Tab) choose a button, which is lit, Return or Space presses
/// it, Esc cancels.
///
/// iPadOS moves its keyboard focus with the arrows and Tab before any view
/// sees the press, and here it would move focus out of the window and stick.
/// So the arrows and Tab are key commands that ask for priority over that
/// (wantsPriorityOverSystemBehavior, as Apple advises for arrow and Tab
/// commands), Return, Space and Esc are read from the presses, and nothing
/// here can take focus (plain views, not buttons). tools/check-confirm-keys.sh
/// checks it with real key presses in the simulator.
final class KeyConfirm: UIViewController, UIGestureRecognizerDelegate {
    private let titleText: String
    private let message: String
    private let confirmTitle: String
    private let onConfirm: () -> Void
    /// Runs once it is gone, whichever way: give the keys back.
    var onDismiss: (() -> Void)?
    private var choices: [UIView] = []
    private var labels: [UILabel] = []
    private var card: UIView?
    private var selected = 1 { didSet { light() } }   // the confirm button

    init(title: String, message: String, confirm: String, onConfirm: @escaping () -> Void) {
        titleText = title
        self.message = message
        confirmTitle = confirm
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        let outside = UITapGestureRecognizer(target: self, action: #selector(cancel))
        outside.allowedPressTypes = []   // taps only: Return and Esc are keys here
        outside.delegate = self
        view.addGestureRecognizer(outside)

        let card: UIVisualEffectView
        if #available(iOS 26, *) {
            card = UIVisualEffectView(effect: UIGlassEffect())
        } else {
            card = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        }
        self.card = card
        card.layer.cornerRadius = 24
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        let title = UILabel()
        title.text = titleText
        title.font = .preferredFont(forTextStyle: .headline)
        title.textAlignment = .center
        title.numberOfLines = 0
        let body = UILabel()
        body.text = message
        body.font = .preferredFont(forTextStyle: .subheadline)
        body.textColor = .secondaryLabel
        body.textAlignment = .center
        body.numberOfLines = 0

        for (i, name) in ["Cancel", confirmTitle].enumerated() {
            let choice = UIView()
            choice.tag = i
            choice.isAccessibilityElement = true
            choice.accessibilityLabel = name
            choice.accessibilityTraits = .button
            choice.layer.cornerRadius = 22
            choice.layer.cornerCurve = .continuous
            choice.hoverStyle = UIHoverStyle(effect: .highlight, shape: .capsule)
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.allowedPressTypes = []
            choice.addGestureRecognizer(tap)
            let label = UILabel()
            label.text = name
            label.font = .preferredFont(forTextStyle: .body).withWeight(.semibold)
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            choice.addSubview(label)
            NSLayoutConstraint.activate([
                choice.heightAnchor.constraint(equalToConstant: 44),
                label.centerXAnchor.constraint(equalTo: choice.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: choice.centerYAnchor),
            ])
            choices.append(choice)
            labels.append(label)
        }
        let row = UIStackView(arrangedSubviews: choices)
        row.spacing = 12
        row.distribution = .fillEqually
        let stack = UIStackView(arrangedSubviews: [title, body, row])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(20, after: body)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 320),
            stack.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -18),
            stack.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -18),
        ])
        light()
    }

    /// The chosen button is filled (red for the destructive one), the other plain grey.
    private func light() {
        for (i, choice) in choices.enumerated() {
            let on = i == selected, destructive = i == 1
            choice.backgroundColor = on ? (destructive ? .systemRed : view.tintColor) : .secondarySystemFill
            choice.accessibilityValue = on ? "selected" : nil
            labels[i].textColor = on ? .white : (destructive ? .systemRed : .label)
        }
    }

    // Keys come here, not to the terminal underneath or the system, while it is open.
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDismiss?()
        onDismiss = nil
    }

    /// A tap outside the card cancels; inside it only the buttons act.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let card else { return true }
        return !card.frame.contains(touch.location(in: view))
    }

    override var keyCommands: [UIKeyCommand]? {
        func key(_ input: String, _ flags: UIKeyModifierFlags = [], action: Selector) -> UIKeyCommand {
            let c = UIKeyCommand(input: input, modifierFlags: flags, action: action)
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
        return [
            key(UIKeyCommand.inputLeftArrow, action: #selector(chooseCancel)),
            key(UIKeyCommand.inputUpArrow, action: #selector(chooseCancel)),
            key(UIKeyCommand.inputRightArrow, action: #selector(chooseConfirm)),
            key(UIKeyCommand.inputDownArrow, action: #selector(chooseConfirm)),
            key("\t", action: #selector(toggle)),
            key("\t", .shift, action: #selector(chooseCancel)),
            key(".", .command, action: #selector(cancel)),
        ]
    }

    // Return, Space and Esc never match key commands here, so they are read
    // from the presses; every other press goes on to UIKit, which matches the
    // key commands (a pressesBegan that keeps them would stop that).
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var rest = Set<UIPress>()
        for press in presses {
            switch press.key?.keyCode {
            case .keyboardReturnOrEnter?, .keypadEnter?, .keyboardSpacebar?:
                finish(confirmed: selected == 1)
            case .keyboardEscape?:
                finish(confirmed: false)
            default:
                rest.insert(press)
            }
        }
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
    }

    @objc private func chooseCancel() { selected = 0 }
    @objc private func chooseConfirm() { selected = 1 }
    @objc private func toggle() { selected = 1 - selected }


    @objc private func cancel() { finish(confirmed: false) }
    @objc private func tapped(_ g: UITapGestureRecognizer) { finish(confirmed: g.view?.tag == 1) }

    private func finish(confirmed: Bool) {
        guard presentingViewController != nil, !isBeingDismissed else { return }
        dismiss(animated: true) { [onConfirm] in if confirmed { onConfirm() } }
    }
}

private extension UIFont {
    func withWeight(_ w: UIFont.Weight) -> UIFont {
        UIFont.systemFont(ofSize: pointSize, weight: w)
    }
}

