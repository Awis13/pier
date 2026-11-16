import Combine
import GameController
import PierCore
import SwiftTerm
import SwiftUI
import UIKit

/// One terminal tab: a shell in a service, and the screen that shows it. The
/// screen lives as long as the tab, so switching tabs or services keeps it.
@MainActor
final class TermTab: NSObject, Identifiable, ObservableObject, TerminalViewDelegate, UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    let id = UUID()
    let service: String
    /// The set of tabs it belongs to: the service's name for its page and
    /// full screen, or that plus a window's ID for a window of its own.
    let deck: String
    /// A pane split off a tab (its ID): shown beside that tab's terminal,
    /// not as a tab of its own.
    var paneOf: UUID?
    let view: TerminalView
    @Published var title: String
    @Published private(set) var ended: Int32?
    /// Full screen has the view: the service page leaves it alone.
    var borrowed = false
    private var session: ShellSession?
    private var connecting = false
    private var pending: [Data] = []
    private weak var pod: PodModel?
    /// The history's suggestion at the prompt, and the commands that ran.
    private(set) var suggester: Suggester!
    /// Each command and its output, drawn as a block.
    private(set) var blocks: CommandBlocks!
    private var splitter = MarkSplitter()
    private var editMenu: UIEditMenuInteraction?
    private var menuPoint = CGPoint.zero
    private var dragStart: Position?

    init(service: String, deck: String, number: Int, pod: PodModel) {
        self.service = service
        self.deck = deck
        self.title = number == 1 ? service : "\(service) \(number)"
        self.pod = pod
        self.view = PierTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        view.terminalDelegate = self
        suggester = Suggester(view: view, service: service)
        blocks = CommandBlocks(view: view)
        // A mouse: right click for the menu, drag to select (fingers still
        // scroll, and select with a long press, as before).
        let menu = UIEditMenuInteraction(delegate: self)
        view.addInteraction(menu)
        editMenu = menu
        let pointer = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let right = UITapGestureRecognizer(target: self, action: #selector(rightClick(_:)))
        right.buttonMaskRequired = .secondary
        right.allowedTouchTypes = pointer
        view.addGestureRecognizer(right)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(pointerDrag(_:)))
        drag.allowedTouchTypes = pointer
        drag.delegate = self
        view.addGestureRecognizer(drag)
        view.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        suggester.onTap = { [weak self] in
            if let rest = self?.suggester.accept() { self?.sendText(rest) }
        }
        view.changeScrollback(Self.scrollback)
        Self.style(view)
    }

    static func style(_ v: TerminalView) {
        let a = Appearance.shared
        a.theme(named: nil).apply(to: v)
        v.font = a.font()
        v.getTerminal().setCursorStyle(a.cursor.style(blink: a.cursorBlink))
        v.optionAsMetaKey = a.optionAsMeta
    }

    /// Opens the shell, sized to the view.
    func connect() {
        guard session == nil, !connecting, ended == nil, let pod else { return }
        connecting = true
        let t = view.getTerminal()
        let cols = max(t.cols, 20), rows = max(t.rows, 5)
        let service = self.service
        Task {
            do {
                let s = try await pod.runner.openShell(in: service, cols: cols, rows: rows) { [weak self] data in
                    DispatchQueue.main.async { self?.show(data) }
                }
                self.session = s
                self.connecting = false
                // The view may have been laid out while the shell opened:
                // the shell gets the size it has now.
                let t = self.view.getTerminal()
                await s.resize(cols: t.cols, rows: t.rows)
                for d in pending { s.send(d) }
                pending.removeAll()
                let code = await s.wait()
                self.session = nil
                self.ended = code
                self.show(Data("\r\n\u{1b}[2m[shell exited with \(code)]\u{1b}[0m\r\n".utf8))
            } catch {
                self.connecting = false
                self.ended = -1
                self.show(Data("\u{1b}[31mcould not open a shell in \(service): \(error)\u{1b}[0m\r\n".utf8))
            }
        }
    }

    /// Starts a new shell in a tab whose shell has ended.
    func restart() {
        ended = nil
        connect()
    }

    func close() {
        let s = session
        session = nil
        Task { await s?.close() }
    }

    private func show(_ data: Data) {
        let bytes = [UInt8](data)
        // Fed piece by piece, stopping at each shell mark, so every mark is
        // read with the screen as it left it.
        for (piece, mark) in splitter.split(bytes) {
            view.feed(byteArray: piece)
            if let mark {
                let command = suggester.mark(mark)
                blocks.mark(mark, command: command)
            }
        }
        if Self.contains(Self.eraseScrollback, in: bytes) {
            // SwiftTerm drops the history but leaves the view
            // scrolled where it was, past the lines that are left: blank.
            // Setting the history size again re-pins the scroll view.
            view.changeScrollback(Self.scrollback)
            blocks.clear()
        }
        suggester.refresh()
        blocks.redraw()
    }

    static let scrollback = 10_000
    private static let eraseScrollback = Array("\u{1b}[3J".utf8)

    private static func contains(_ needle: [UInt8], in hay: [UInt8]) -> Bool {
        guard hay.count >= needle.count else { return false }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<i + needle.count]) == needle {
            return true
        }
        return false
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Right arrow with a suggestion showing types the suggestion.
        let bytes = Array(data)
        if bytes == [0x1b, 0x5b, 0x43] || bytes == [0x1b, 0x4f, 0x43], let rest = suggester.accept() {
            sendText(rest)
            return
        }
        suggester.keySent()
        let d = Data(data)
        if let session { session.send(d) } else { pending.append(d) }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        DispatchQueue.main.async { [weak self] in self?.blocks.redraw() }
        guard let session else { return }
        Task { await session.resize(cols: newCols, rows: newRows) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // OSC 7: file://host/path
        suggester.directory = directory.flatMap { URL(string: $0)?.path } ?? directory
    }

    // MARK: Mouse

    private var cell: CGSize {
        let t = view.getTerminal()
        let size = view.getOptimalFrameSize()
        return CGSize(width: size.width / CGFloat(max(t.cols, 1)), height: size.height / CGFloat(max(t.rows, 1)))
    }

    /// A point of the view (content coordinates) as a buffer position.
    private func position(_ p: CGPoint) -> Position {
        let t = view.getTerminal(), c = cell
        let col = min(max(Int(p.x / max(c.width, 1)), 0), max(t.cols - 1, 0))
        let row = max(Int(p.y / max(c.height, 1)), 0)
        return Position(col: col, row: row)
    }

    @objc private func rightClick(_ g: UITapGestureRecognizer) {
        menuPoint = g.location(in: view)
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: menuPoint))
    }

    /// Drag with the mouse: select from where it went down to where it is.
    @objc private func pointerDrag(_ g: UIPanGestureRecognizer) {
        let here = position(g.location(in: view))
        switch g.state {
        case .began:
            dragStart = here
            view.selection.setSelection(start: here, end: here)
        case .changed:
            guard let start = dragStart else { return }
            let forward = (here.row, here.col) >= (start.row, start.col)
            let end = Position(col: min(here.col + (forward ? 1 : 0), view.getTerminal().cols), row: here.row)
            view.selection.setSelection(start: forward ? start : end, end: forward ? end : start)
        default:
            dragStart = nil
        }
        view.setNeedsDisplay()
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // A program that takes the mouse (vim, htop, tmux) gets it.
        view.getTerminal().mouseMode == .off
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var items: [UIMenuElement] = []
        if view.selection.active {
            items.append(UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                guard let self else { return }
                UIPasteboard.general.string = self.view.selection.getSelectedText()
            })
        }
        if let b = blocks.block(atBufferRow: position(menuPoint).row) {
            let command = b.command
            var block: [UIMenuElement] = [
                UIAction(title: "Copy Block", image: UIImage(systemName: "rectangle.on.rectangle")) { [weak self] _ in
                    UIPasteboard.general.string = self?.blocks.text(of: b)
                },
                UIAction(title: "Copy Output", image: UIImage(systemName: "text.alignleft")) { [weak self] _ in
                    UIPasteboard.general.string = self?.blocks.output(of: b)
                },
            ]
            if !command.isEmpty {
                block.insert(UIAction(title: "Copy Command", image: UIImage(systemName: "terminal")) { _ in
                    UIPasteboard.general.string = command
                }, at: 1)
                block.append(UIAction(title: "Run Again", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    self?.sendText(command + "\n")
                })
            }
            items.append(UIMenu(title: command.isEmpty ? "" : String(command.prefix(50)), options: .displayInline, children: block))
        }
        var edit: [UIMenuElement] = []
        if UIPasteboard.general.hasStrings {
            edit.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.view.paste(nil)
            })
        }
        edit.append(UIAction(title: "Select All", image: UIImage(systemName: "selection.pin.in.out")) { [weak self] _ in
            self?.view.selectAll(nil)
        })
        items.append(UIMenu(options: .displayInline, children: edit))
        return UIMenu(children: items)
    }

    /// Text typed into the shell as if from the keyboard.
    func sendText(_ text: String) {
        let d = Data(text.utf8)
        if let session { session.send(d) } else { pending.append(d) }
    }
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { UIApplication.shared.open(url) }
    }
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {
        if let text = String(data: content, encoding: .utf8) { UIPasteboard.general.string = text }
    }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Shows one tab's terminal with a key bar above the keyboard, pinch
/// and ⌘+ ⌘− ⌘0 for the size.
final class TerminalHostController: UIViewController {
    var termTab: TermTab? { didSet { if oldValue !== termTab { attach() } } }
    private var keyBar: UIView?
    private var bottomToKeyboard: NSLayoutConstraint?
    private var bottomToKeyBar: NSLayoutConstraint?
    private var softKeyboardUp = false
    private var pinchBase: Double = 0
    private var looks: AnyCancellable?
    private let holder = UIView()

    override func viewDidLoad() {
        super.viewDidLoad()
        holder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(holder)
        bottomToKeyboard = holder.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            holder.topAnchor.constraint(equalTo: view.topAnchor),
            holder.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            holder.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        bottomToKeyboard?.isActive = true
        for name in [UIResponder.keyboardWillShowNotification, UIResponder.keyboardWillHideNotification,
                     UIResponder.keyboardWillChangeFrameNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: name, object: nil)
        }
        for name in [NSNotification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateKeyBar), name: name, object: nil)
        }
        looks = Appearance.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async {
                guard let v = self?.termTab?.view else { return }
                TermTab.style(v)
                self?.view.backgroundColor = v.nativeBackgroundColor
            }
        }
        attach()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        termTab?.view.becomeFirstResponder()
    }

    /// Takes the terminal back after full screen borrowed it.
    func reattachIfMoved() {
        guard isViewLoaded, let t = termTab, !t.borrowed, t.view.superview !== holder else { return }
        attach()
    }

    private func attach() {
        guard isViewLoaded, let tab = termTab, !tab.borrowed else { return }
        holder.subviews.forEach { $0.removeFromSuperview() }
        let v = tab.view
        v.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: holder.topAnchor),
            v.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 10),
            v.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -10),
        ])
        if v.gestureRecognizers?.contains(where: { $0 is UIPinchGestureRecognizer }) != true {
            v.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        }
        view.backgroundColor = v.nativeBackgroundColor
        setUpKeyBar(from: v)
        view.layoutIfNeeded()
        tab.connect()
        if view.window != nil { v.becomeFirstResponder() }
    }

    /// SwiftTerm's key bar (Esc, Ctrl, Tab, arrows), above the keyboard and
    /// clear of the window's corners, shown only with the on-screen keyboard.
    private func setUpKeyBar(from v: TerminalView) {
        keyBar?.removeFromSuperview()
        keyBar = nil
        bottomToKeyBar = nil
        guard let bar = v.inputAccessoryView else { return updateKeyBar() }
        v.inputAccessoryView = nil
        keyBar = bar
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.layer.cornerRadius = 12
        bar.clipsToBounds = true
        view.addSubview(bar)
        bottomToKeyBar = holder.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -4)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -6),
            bar.heightAnchor.constraint(equalToConstant: 44),
        ])
        updateKeyBar()
    }

    @objc private func keyboardChanged(_ n: Notification) {
        var up = false
        if n.name != UIResponder.keyboardWillHideNotification,
           let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
           let screen = view.window?.screen {
            let onScreen = end.intersection(screen.bounds)
            up = !onScreen.isNull && onScreen.height > 120
        }
        guard up != softKeyboardUp else { return }
        softKeyboardUp = up
        updateKeyBar()
    }

    @objc private func updateKeyBar() {
        let show = GCKeyboard.coalesced == nil && keyBar != nil && softKeyboardUp
        keyBar?.isHidden = !show
        bottomToKeyBar?.isActive = false
        bottomToKeyboard?.isActive = false
        (show ? bottomToKeyBar : bottomToKeyboard)?.isActive = true
        view.setNeedsLayout()
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        let a = Appearance.shared
        switch g.state {
        case .began: pinchBase = a.fontSize
        case .changed:
            let size = min(max((pinchBase * Double(g.scale)).rounded(), 8), 36)
            if size != a.fontSize { a.fontSize = size }
        default: break
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Bigger Text", action: #selector(bigger), input: "+", modifierFlags: .command),
            UIKeyCommand(title: "Bigger Text", action: #selector(bigger), input: "=", modifierFlags: .command),
            UIKeyCommand(title: "Smaller Text", action: #selector(smaller), input: "-", modifierFlags: .command),
            UIKeyCommand(title: "Actual Size", action: #selector(resetSize), input: "0", modifierFlags: .command),
            UIKeyCommand(title: "Command History", action: #selector(showHistory), input: "r", modifierFlags: .command),
            UIKeyCommand(title: "Quick Switch", action: #selector(quickSwitch), input: "p", modifierFlags: .command),
            UIKeyCommand(title: "Previous Command", action: #selector(previousBlock), input: UIKeyCommand.inputUpArrow, modifierFlags: .command),
            UIKeyCommand(title: "Next Command", action: #selector(nextBlock), input: UIKeyCommand.inputDownArrow, modifierFlags: .command),
        ]
    }

    @objc private func showHistory() { presentHistory(for: termTab) }
    @objc private func quickSwitch() { NotificationCenter.default.post(name: .pierQuickSwitch, object: termTab?.deck) }
    @objc private func previousBlock() { termTab?.blocks.jump(up: true) }
    @objc private func nextBlock() { termTab?.blocks.jump(up: false) }
    @objc private func bigger() { Appearance.shared.fontSize = min(Appearance.shared.fontSize + 1, 36) }
    @objc private func smaller() { Appearance.shared.fontSize = max(Appearance.shared.fontSize - 1, 8) }
    @objc private func resetSize() { Appearance.shared.fontSize = 14 }
}

struct TerminalHost: UIViewControllerRepresentable {
    let tab: TermTab

    func makeUIViewController(context: Context) -> TerminalHostController {
        let c = TerminalHostController()
        c.termTab = tab
        return c
    }

    func updateUIViewController(_ c: TerminalHostController, context: Context) {
        c.termTab = tab
        c.reattachIfMoved()
    }
}

/// A service's terminal tabs: a strip of tabs over the selected one.
struct ServiceTerminals: View {
    @Environment(PodModel.self) private var pod
    let service: ServiceSpec
    let running: Bool

    var body: some View {
        let tabs = pod.terminals.filter { $0.deck == service.name && $0.paneOf == nil }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tabs) { t in
                            TabChip(tab: t, selected: pod.selectedTerminal[service.name] == t.id) {
                                pod.selectedTerminal[service.name] = t.id
                            } close: {
                                pod.closeTerminal(t)
                            }
                        }
                    }
                }
                Button { pod.openTerminal(in: service) } label: { Image(systemName: "plus") }
                    .disabled(!running)
                    .keyboardShortcut("t", modifiers: .command)
                    .help("New terminal in \(service.name)")
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            if let id = pod.selectedTerminal[service.name], let tab = tabs.first(where: { $0.id == id }) {
                TerminalHost(tab: tab)
                    .id(tab.id)
            } else {
                ContentUnavailableView {
                    Label("No Terminal", systemImage: "terminal")
                } description: {
                    Text(running ? "Open a shell in \(service.name) with +." : "Start the pod to open a shell.")
                } actions: {
                    if running {
                        Button("Open Terminal") { pod.openTerminal(in: service) }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .background(Color(platform: PlatformColor(hex: Appearance.shared.theme(named: nil).bg)), in: .rect(cornerRadius: 10))
        .onAppear {
            if running, tabs.isEmpty { pod.openTerminal(in: service) }
        }
    }
}

private struct TabChip: View {
    @ObservedObject var tab: TermTab
    let selected: Bool
    let select: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: tab.ended == nil ? "terminal" : "terminal.fill").font(.caption)
            Text(tab.title).font(.caption.monospaced()).lineLimit(1)
            if tab.ended != nil { Text("ended").font(.caption2).foregroundStyle(.secondary) }
            Button(action: close) { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(selected ? AnyShapeStyle(.tint.opacity(0.35)) : AnyShapeStyle(.quaternary), in: .capsule)
        .contentShape(.capsule)
        .onTapGesture(perform: select)
        .contextMenu {
            if tab.ended != nil { Button("Start Again") { tab.restart() } }
            Button("Close", role: .destructive, action: close)
        }
    }
}

/// Open Full Screen: the service's shells, laid out as a terminal app lays out its
/// terminal (TerminalController.viewDidLoad and setUpTabBar): the theme's
/// background, a tab strip of sessions on top (select, + for a new
/// one, x to close, long press to rename), the text 4 pt off the sides, the
/// key bar over the keyboard. Cmd+W or a two-finger swipe down leaves.
extension UIViewController {
    /// Cmd-R: the command history; the one picked is typed (not run) into `tab`.
    func presentHistory(for tab: TermTab?) {
        guard let tab else { return }
        let search = HistorySearchView(service: tab.service) { [weak tab] command in
            tab?.sendText(command)
        }
        present(UIHostingController(rootView: search), animated: true)
    }
}

final class FullScreenTerminalController: UIViewController, UIGestureRecognizerDelegate {
    private let pod: PodModel
    private let service: ServiceSpec
    private let deck: String
    private let onClose: () -> Void
    private let screen = UIView()
    private let tabBar = TabBar()
    private var shown: TermTab?
    private var keyBar: UIView?
    private var bottomToKeyboard: NSLayoutConstraint?
    private var bottomToKeyBar: NSLayoutConstraint?
    private var softKeyboardUp = false
    private var pinchBase: Double = 0
    private var looks: AnyCancellable?
    private var showObserver: NSObjectProtocol?

    init(pod: PodModel, service: ServiceSpec, deck: String, onClose: @escaping () -> Void) {
        self.pod = pod
        self.service = service
        self.deck = deck
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var tabs: [TermTab] { pod.terminals.filter { $0.deck == deck && $0.paneOf == nil } }

    /// How a tab is split: a terminal, or terminals side by side or stacked.
    indirect enum Pane {
        case leaf(TermTab)
        case split(NSLayoutConstraint.Axis, [Pane])

        var leaves: [TermTab] {
            switch self {
            case .leaf(let t): [t]
            case .split(_, let ps): ps.flatMap(\.leaves)
            }
        }

        /// `new` next to `at`, along `axis`.
        func inserting(_ new: TermTab, after at: TermTab, axis: NSLayoutConstraint.Axis) -> Pane {
            switch self {
            case .leaf(let t):
                return t === at ? .split(axis, [.leaf(t), .leaf(new)]) : self
            case .split(let a, let ps):
                if a == axis, let i = ps.firstIndex(where: { if case .leaf(let t) = $0 { t === at } else { false } }) {
                    var out = ps
                    out.insert(.leaf(new), at: i + 1)
                    return .split(a, out)
                }
                return .split(a, ps.map { $0.inserting(new, after: at, axis: axis) })
            }
        }

        /// Without `gone`; a split left with one pane becomes that pane.
        func removing(_ gone: TermTab) -> Pane? {
            switch self {
            case .leaf(let t): return t === gone ? nil : self
            case .split(let a, let ps):
                let rest = ps.compactMap { $0.removing(gone) }
                if rest.isEmpty { return nil }
                return rest.count == 1 ? rest[0] : .split(a, rest)
            }
        }
    }

    /// Each tab's panes, by the tab's ID; a tab without an entry is one pane.
    private var layouts: [UUID: Pane] = [:]
    /// The pane that gets the keys.
    private var focused: TermTab?

    private func layout(of t: TermTab) -> Pane { layouts[t.id] ?? .leaf(t) }

    override func viewDidLoad() {
        super.viewDidLoad()
        screen.clipsToBounds = true
        screen.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(screen)
        let top: UILayoutGuide
        let side: UILayoutGuide
        if #available(iOS 26, *) {
            top = view.layoutGuide(for: .safeArea(cornerAdaptation: .vertical))
            side = view.layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
        } else {
            top = view.safeAreaLayoutGuide
            side = view.safeAreaLayoutGuide
        }
        let pullUp = screen.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        pullUp.priority = .defaultLow
        bottomToKeyboard = screen.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            screen.topAnchor.constraint(greaterThanOrEqualTo: top.topAnchor),
            pullUp,
            screen.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            screen.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])
        bottomToKeyboard?.isActive = true

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            tabBar.heightAnchor.constraint(equalToConstant: 32),
            tabBar.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 6),
            tabBar.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -6),
            screen.topAnchor.constraint(greaterThanOrEqualTo: tabBar.bottomAnchor, constant: 10),
        ])
        tabBar.onSelect = { [weak self] i in
            guard let self, i < self.tabs.count else { return }
            self.show(self.tabs[i])
        }
        tabBar.onNew = { [weak self] in
            guard let self else { return }
            self.pod.openTerminal(in: self.service, deck: self.deck)
            if let t = self.tabs.last { self.show(t) }
        }
        tabBar.onClose = { [weak self] w in
            guard let self, w.index < self.tabs.count else { return }
            let t = self.tabs[w.index]
            for pane in self.layout(of: t).leaves where pane !== t { self.pod.closeTerminal(pane) }
            self.layouts[t.id] = nil
            if t === self.shown { self.shown = nil }
            self.pod.closeTerminal(t)
            if let next = self.tabs.last { self.show(next) } else { self.leave() }
        }
        tabBar.onRename = { [weak self] w in self?.rename(w.index) }

        for name in [UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillHideNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: name, object: nil)
        }
        for name in [NSNotification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            NotificationCenter.default.addObserver(self, selector: #selector(updateKeyBar), name: name, object: nil)
        }
        looks = Appearance.shared.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.applyAppearance() }
        }
        let start = tabs.first { $0.id == pod.selectedTerminal[deck] } ?? tabs.first
        if let start { show(start) }
        showObserver = NotificationCenter.default.addObserver(forName: .pierShowTab, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, let id = n.object as? UUID,
                      let t = self.pod.terminals.first(where: { $0.id == id }), t.deck == self.deck else { return }
                self.show(t)
            }
        }
        applyAppearance()
    }

    /// Puts a tab on screen, every pane of it, and marks the tab.
    private func show(_ t: TermTab) {
        for old in shown.map({ layout(of: $0).leaves }) ?? [] {
            old.view.removeFromSuperview()
            old.borrowed = false
        }
        screen.subviews.forEach { $0.removeFromSuperview() }
        shown = t
        pod.selectedTerminal[deck] = t.id
        let pane = layout(of: t)
        let leaves = pane.leaves
        if focused == nil || !leaves.contains(where: { $0 === focused }) { focused = leaves.first }
        let root = build(pane)
        root.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: screen.topAnchor),
            root.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
        ])
        for leaf in leaves {
            leaf.borrowed = true
            TermTab.style(leaf.view)
            leaf.connect()
        }
        if let f = focused { setUpKeyBar(from: f.view) }
        markFocus()
        refreshTabs()
        if view.window != nil { focused?.view.becomeFirstResponder() }
    }

    /// The views of a layout: stacks of terminals, a hairline between them.
    private func build(_ pane: Pane) -> UIView {
        switch pane {
        case .leaf(let t):
            let v = t.view
            v.removeFromSuperview()
            v.translatesAutoresizingMaskIntoConstraints = false
            v.inputAccessoryView = v === focused?.view ? v.inputAccessoryView : nil
            if v.gestureRecognizers?.contains(where: { $0.name == "pier-fullscreen" }) != true {
                let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
                pinch.name = "pier-fullscreen"
                v.addGestureRecognizer(pinch)
                let down = UISwipeGestureRecognizer(target: self, action: #selector(leave))
                down.name = "pier-fullscreen"
                down.direction = .down
                down.numberOfTouchesRequired = 2
                v.addGestureRecognizer(down)
                let tap = UITapGestureRecognizer(target: self, action: #selector(tappedPane(_:)))
                tap.name = "pier-fullscreen"
                tap.cancelsTouchesInView = false
                tap.delegate = self
                v.addGestureRecognizer(tap)
            }
            return v
        case .split(let axis, let ps):
            let stack = UIStackView(arrangedSubviews: ps.map(build))
            stack.axis = axis
            stack.distribution = .fillEqually
            stack.spacing = 1
            stack.backgroundColor = UIColor.separator
            return stack
        }
    }

    /// A thin outline on the pane with the keys, when there is more than one.
    private func markFocus() {
        guard let t = shown else { return }
        let leaves = layout(of: t).leaves
        for leaf in leaves {
            let on = leaves.count > 1 && leaf === focused
            leaf.view.layer.borderWidth = on ? 1 : 0
            leaf.view.layer.borderColor = view.tintColor.withAlphaComponent(0.6).cgColor
        }
    }

    private func focus(_ t: TermTab) {
        guard t !== focused else { return }
        focused?.view.inputAccessoryView = nil
        focused = t
        setUpKeyBar(from: t.view)
        markFocus()
        t.view.becomeFirstResponder()
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func tappedPane(_ g: UITapGestureRecognizer) {
        guard let v = g.view, let t = shown.map({ layout(of: $0).leaves })?.first(where: { $0.view === v }) else { return }
        focus(t)
    }

    /// A new shell beside the focused pane.
    private func split(_ axis: NSLayoutConstraint.Axis) {
        guard let t = shown, let at = focused else { return }
        let new = pod.openTerminal(in: service, deck: deck)
        new.paneOf = t.id
        pod.selectedTerminal[deck] = t.id
        layouts[t.id] = layout(of: t).inserting(new, after: at, axis: axis)
        focused = new
        show(t)
    }

    /// Closes the focused pane; with one pane, what Cmd-W always did.
    @objc private func closePane() {
        guard let t = shown, let f = focused, layout(of: t).leaves.count > 1 else { return leave() }
        let rest = layout(of: t).removing(f)
        let leaves = rest?.leaves ?? []
        if f === t, let heir = leaves.first {
            // The tab's own terminal goes: another pane takes its place in the strip.
            heir.paneOf = nil
            for other in leaves where other !== heir { other.paneOf = heir.id }
            layouts[t.id] = nil
            layouts[heir.id] = rest.flatMap { leaves.count > 1 ? $0 : nil }
            pod.closeTerminal(f)
            focused = heir
            show(heir)
        } else {
            layouts[t.id] = rest.flatMap { leaves.count > 1 ? $0 : nil }
            pod.closeTerminal(f)
            focused = leaves.first
            show(t)
        }
    }

    @objc private func showHistory() { presentHistory(for: focused ?? shown) }
    @objc private func quickSwitch() { NotificationCenter.default.post(name: .pierQuickSwitch, object: deck) }
    @objc private func previousBlock() { (focused ?? shown)?.blocks.jump(up: true) }
    @objc private func nextBlock() { (focused ?? shown)?.blocks.jump(up: false) }
    @objc private func splitRight() { split(.horizontal) }
    @objc private func splitDown() { split(.vertical) }
    @objc private func nextPane() { stepPane(1) }
    @objc private func previousPane() { stepPane(-1) }
    private func stepPane(_ d: Int) {
        guard let t = shown else { return }
        let ls = layout(of: t).leaves
        guard ls.count > 1, let i = ls.firstIndex(where: { $0 === focused }) else { return }
        focus(ls[(i + d + ls.count) % ls.count])
    }

    @objc private func selectTab(_ c: UIKeyCommand) {
        guard let n = c.input.flatMap(Int.init), n >= 1, n <= tabs.count else { return }
        show(tabs[n - 1])
    }

    private func refreshTabs() {
        let ws = tabs.enumerated().map { i, t in
            TmuxWindow(index: i, name: t.title, active: t === shown, bell: false, activity: 0,
                       panes: 1, command: "", sync: false, width: 0, height: 0)
        }
        tabBar.update(ws, force: true)
    }

    private func rename(_ index: Int) {
        guard index < tabs.count else { return }
        let t = tabs[index]
        let alert = UIAlertController(title: "Rename Tab", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.text = t.title }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            if let name = alert?.textFields?.first?.text, !name.isEmpty { t.title = name }
            self?.refreshTabs()
        })
        present(alert, animated: true)
    }

    private func applyAppearance() {
        let theme = Appearance.shared.theme(named: nil)
        view.backgroundColor = PlatformColor(hex: theme.bg)
        tabBar.setForeground(PlatformColor(hex: theme.fg))
        overrideUserInterfaceStyle = theme.isDark ? .dark : .light
        for leaf in shown.map({ layout(of: $0).leaves }) ?? [] { TermTab.style(leaf.view) }
        markFocus()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        (focused ?? shown)?.view.becomeFirstResponder()
        // --suggest-test: runs a command, then types its start (checking without a keyboard).
        if Checks.arguments.contains("--suggest-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                (self?.focused ?? self?.shown)?.sendText("echo SH=$0 B=$BASH_VERSION Z=$ZSH_VERSION\necho pier-history-check\nls /nonexistent\nsleep 1.3; echo slow done\n")
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    (self?.focused ?? self?.shown)?.sendText("echo pier-h")
                }
            }
        }
        // --split: right, then down (checking without a keyboard).
        if Checks.has("--split") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.splitRight()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self?.splitDown() }
            }
        }
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    private func setUpKeyBar(from v: TerminalView) {
        if let bar = v.inputAccessoryView {
            v.inputAccessoryView = nil
            keyBar?.removeFromSuperview()
            keyBar = bar
        }
        guard let bar = keyBar else { return updateKeyBar() }
        guard bar.superview !== view else { return updateKeyBar() }
        bar.removeFromSuperview()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.layer.cornerRadius = 12
        bar.clipsToBounds = true
        view.addSubview(bar)
        bottomToKeyBar = screen.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -4)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -6),
            bar.heightAnchor.constraint(equalToConstant: 44),
        ])
        updateKeyBar()
    }

    @objc private func keyboardChanged(_ n: Notification) {
        var up = false
        if n.name != UIResponder.keyboardWillHideNotification,
           let end = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
           let s = view.window?.screen {
            let onScreen = end.intersection(s.bounds)
            up = !onScreen.isNull && onScreen.height > 120
        }
        guard up != softKeyboardUp else { return }
        softKeyboardUp = up
        updateKeyBar()
    }

    @objc private func updateKeyBar() {
        let show = GCKeyboard.coalesced == nil && keyBar != nil && softKeyboardUp
        keyBar?.isHidden = !show
        bottomToKeyBar?.isActive = false
        bottomToKeyboard?.isActive = false
        (show ? bottomToKeyBar : bottomToKeyboard)?.isActive = true
        view.setNeedsLayout()
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        let a = Appearance.shared
        switch g.state {
        case .began: pinchBase = a.fontSize
        case .changed:
            let size = min(max((pinchBase * Double(g.scale)).rounded(), 8), 36)
            if size != a.fontSize { a.fontSize = size }
        default: break
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Close Pane", action: #selector(closePane), input: "w", modifierFlags: .command),
            UIKeyCommand(title: "Split Right", action: #selector(splitRight), input: "d", modifierFlags: .command),
            UIKeyCommand(title: "Split Down", action: #selector(splitDown), input: "d", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Next Pane", action: #selector(nextPane), input: "]", modifierFlags: .command),
            UIKeyCommand(title: "Previous Pane", action: #selector(previousPane), input: "[", modifierFlags: .command),
            UIKeyCommand(title: "New Tab", action: #selector(newTab), input: "t", modifierFlags: .command),
            UIKeyCommand(title: "Next Tab", action: #selector(nextTab), input: "]", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Previous Tab", action: #selector(previousTab), input: "[", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Bigger Text", action: #selector(bigger), input: "+", modifierFlags: .command),
            UIKeyCommand(title: "Bigger Text", action: #selector(bigger), input: "=", modifierFlags: .command),
            UIKeyCommand(title: "Smaller Text", action: #selector(smaller), input: "-", modifierFlags: .command),
            UIKeyCommand(title: "Actual Size", action: #selector(resetSize), input: "0", modifierFlags: .command),
            UIKeyCommand(title: "Command History", action: #selector(showHistory), input: "r", modifierFlags: .command),
            UIKeyCommand(title: "Quick Switch", action: #selector(quickSwitch), input: "p", modifierFlags: .command),
            UIKeyCommand(title: "Previous Command", action: #selector(previousBlock), input: UIKeyCommand.inputUpArrow, modifierFlags: .command),
            UIKeyCommand(title: "Next Command", action: #selector(nextBlock), input: UIKeyCommand.inputDownArrow, modifierFlags: .command),
        ] + (1...9).map {
            UIKeyCommand(title: "Tab \($0)", action: #selector(selectTab(_:)), input: String($0), modifierFlags: .command)
        }
    }

    @objc private func newTab() { tabBar.onNew?() }
    @objc private func nextTab() { step(1) }
    @objc private func previousTab() { step(-1) }
    private func step(_ d: Int) {
        let ts = tabs
        guard let cur = ts.firstIndex(where: { $0 === shown }), !ts.isEmpty else { return }
        show(ts[(cur + d + ts.count) % ts.count])
    }

    @objc private func leave() {
        shown?.view.removeFromSuperview()
        shown?.borrowed = false
        onClose()
    }
    @objc private func bigger() { Appearance.shared.fontSize = min(Appearance.shared.fontSize + 1, 36) }
    @objc private func smaller() { Appearance.shared.fontSize = max(Appearance.shared.fontSize - 1, 8) }
    @objc private func resetSize() { Appearance.shared.fontSize = 14 }
}

struct FullScreenTerminal: UIViewControllerRepresentable {
    let pod: PodModel
    let service: ServiceSpec
    /// Whose tabs: the service's own unless a window has its own.
    var deck: String? = nil
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> FullScreenTerminalController {
        FullScreenTerminalController(pod: pod, service: service, deck: deck ?? service.name, onClose: onClose)
    }

    func updateUIViewController(_ c: FullScreenTerminalController, context: Context) {}
}
