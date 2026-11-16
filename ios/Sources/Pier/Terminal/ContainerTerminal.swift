import Combine
import GameController
import PierCore
import SwiftTerm
import SwiftUI
import UIKit

/// One terminal tab: a shell in a service, and the screen that shows it. The
/// screen lives as long as the tab, so switching tabs or services keeps it.
@MainActor
final class TermTab: NSObject, Identifiable, ObservableObject, TerminalViewDelegate {
    let id = UUID()
    let service: String
    let view: TerminalView
    @Published var title: String
    @Published private(set) var ended: Int32?
    /// Full screen has the view: the service page leaves it alone.
    var borrowed = false
    private var session: ShellSession?
    private var connecting = false
    private var pending: [Data] = []
    private weak var pod: PodModel?

    init(service: String, number: Int, pod: PodModel) {
        self.service = service
        self.title = number == 1 ? service : "\(service) \(number)"
        self.pod = pod
        self.view = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        super.init()
        view.terminalDelegate = self
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
        view.feed(byteArray: bytes[...])
        if Self.contains(Self.eraseScrollback, in: bytes) {
            // SwiftTerm drops the history but leaves the view
            // scrolled where it was, past the lines that are left: blank.
            // Setting the history size again re-pins the scroll view.
            view.changeScrollback(Self.scrollback)
        }
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
        let d = Data(data)
        if let session { session.send(d) } else { pending.append(d) }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        guard let session else { return }
        Task { await session.resize(cols: newCols, rows: newRows) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
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
            v.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 4),
            v.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -4),
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
        ]
    }

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
        let tabs = pod.terminals.filter { $0.service == service.name }
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
final class FullScreenTerminalController: UIViewController {
    private let pod: PodModel
    private let service: ServiceSpec
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

    init(pod: PodModel, service: ServiceSpec, onClose: @escaping () -> Void) {
        self.pod = pod
        self.service = service
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var tabs: [TermTab] { pod.terminals.filter { $0.service == service.name } }

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
            screen.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 4),
            screen.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -4),
        ])
        bottomToKeyboard?.isActive = true

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            tabBar.heightAnchor.constraint(equalToConstant: 32),
            tabBar.leadingAnchor.constraint(equalTo: side.leadingAnchor, constant: 6),
            tabBar.trailingAnchor.constraint(equalTo: side.trailingAnchor, constant: -6),
            screen.topAnchor.constraint(greaterThanOrEqualTo: tabBar.bottomAnchor, constant: 2),
        ])
        tabBar.onSelect = { [weak self] i in
            guard let self, i < self.tabs.count else { return }
            self.show(self.tabs[i])
        }
        tabBar.onNew = { [weak self] in
            guard let self else { return }
            self.pod.openTerminal(in: self.service)
            if let t = self.tabs.last { self.show(t) }
        }
        tabBar.onClose = { [weak self] w in
            guard let self, w.index < self.tabs.count else { return }
            let t = self.tabs[w.index]
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
        let start = tabs.first { $0.id == pod.selectedTerminal[service.name] } ?? tabs.first
        if let start { show(start) }
        applyAppearance()
    }

    /// Puts a session's terminal on screen and marks its tab.
    private func show(_ t: TermTab) {
        shown?.view.removeFromSuperview()
        shown?.borrowed = false
        shown = t
        t.borrowed = true
        pod.selectedTerminal[service.name] = t.id
        let v = t.view
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        screen.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: screen.topAnchor),
            v.bottomAnchor.constraint(equalTo: screen.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: screen.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: screen.trailingAnchor),
        ])
        if v.gestureRecognizers?.contains(where: { $0.name == "pier-fullscreen" }) != true {
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
            pinch.name = "pier-fullscreen"
            v.addGestureRecognizer(pinch)
            let down = UISwipeGestureRecognizer(target: self, action: #selector(leave))
            down.name = "pier-fullscreen"
            down.direction = .down
            down.numberOfTouchesRequired = 2
            v.addGestureRecognizer(down)
        }
        setUpKeyBar(from: v)
        TermTab.style(v)
        t.connect()
        refreshTabs()
        if view.window != nil { v.becomeFirstResponder() }
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
        if let v = shown?.view { TermTab.style(v) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        shown?.view.becomeFirstResponder()
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
            UIKeyCommand(title: "Close Full Screen", action: #selector(leave), input: "w", modifierFlags: .command),
            UIKeyCommand(title: "New Tab", action: #selector(newTab), input: "t", modifierFlags: .command),
            UIKeyCommand(title: "Next Tab", action: #selector(nextTab), input: "]", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Previous Tab", action: #selector(previousTab), input: "[", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Bigger Text", action: #selector(bigger), input: "+", modifierFlags: .command),
            UIKeyCommand(title: "Bigger Text", action: #selector(bigger), input: "=", modifierFlags: .command),
            UIKeyCommand(title: "Smaller Text", action: #selector(smaller), input: "-", modifierFlags: .command),
            UIKeyCommand(title: "Actual Size", action: #selector(resetSize), input: "0", modifierFlags: .command),
        ]
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
    let onClose: () -> Void

    func makeUIViewController(context: Context) -> FullScreenTerminalController {
        FullScreenTerminalController(pod: pod, service: service, onClose: onClose)
    }

    func updateUIViewController(_ c: FullScreenTerminalController, context: Context) {}
}
