import PierCore
import SwiftUI
import UIKit

/// A window with shells of one service: tabs of its own, a new shell when
/// it opens, all of them closed when it closes, so windows never take each
/// other's sessions.
struct TerminalWindow: View {
    @Environment(PodModel.self) private var pod
    @Environment(JITSession.self) private var jit
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    let target: TerminalTarget?

    private var serviceName: String? { target?.service }
    private var deck: String { "\(target?.service ?? "")@\(target?.id.uuidString ?? "")" }

    var body: some View {
        Group {
            if let name = serviceName, let service = pod.spec.services.first(where: { $0.name == name }) {
                let deck = deck
                Group {
                    if pod.state(of: service) != .running && !pod.terminals.contains(where: { $0.deck == deck }) {
                        // A shell opens once the service runs.
                        ContentUnavailableView {
                            Label("\(name) Is Not Running", systemImage: "terminal")
                        } description: {
                            Text(pod.snapshot.pod == .running ? "Start \(name) from its menu." : "Start the pod, and a shell opens here.")
                        } actions: {
                            if !pod.isActive {
                                Button { pod.start(jit: jit) } label: { Label("Start Pod", systemImage: "play.fill") }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!jit.isOn)
                            }
                            JITStatus()
                        }
                    } else if pod.terminals.contains(where: { $0.deck == deck }) {
                        FullScreenTerminal(pod: pod, service: service, deck: deck) {
                            pod.closeDeck(deck)
                            dismissWindow()
                        }
                        .ignoresSafeArea()
                    } else {
                        Color.black.ignoresSafeArea()
                            .onAppear { pod.openTerminal(in: service, deck: deck) }
                    }
                }
                .navigationTitle(name)
                .onAppear {
                    pod.jitChanged(jit)
                    MainWindow.shared.open = { openWindow(id: "main") }
                    // Launched with only terminal windows restored: Pier's own comes too.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        if MainWindow.shared.sessions.isEmpty { MainWindow.shared.bringForward() }
                    }
                }
                .onChange(of: jit.state) { pod.jitChanged(jit) }
                .onChange(of: pod.snapshot.pod) { pod.jitChanged(jit) }
                // Only when the window itself goes: SwiftUI calls onDisappear
                // here when another window opens, too.
                .background(SceneEnd { pod.closeDeck(deck) })
                // Shift-Command-N here: another window, a new shell in the same container.
                .focusedSceneValue(\.selectedService, name)
            } else {
                ContentUnavailableView("No Such Service", systemImage: "terminal",
                                       description: Text("Open a service's terminal window from its menu."))
            }
        }
    }
}

/// Runs `ended` once the scene of the window it is in disconnects (the
/// window closed for good), not when the window merely loses focus.
struct SceneEnd: UIViewRepresentable {
    let ended: () -> Void

    final class Probe: UIView {
        var ended: (() -> Void)?
        private var observer: NSObjectProtocol?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard observer == nil, let scene = window?.windowScene else { return }
            observer = NotificationCenter.default.addObserver(
                forName: UIScene.didDisconnectNotification, object: scene, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.ended?() }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.isUserInteractionEnabled = false
        v.ended = ended
        return v
    }

    func updateUIView(_ v: Probe, context: Context) { v.ended = ended }
}

/// Brings the main window forward whenever Pier comes back to the screen:
/// iPadOS shows the window used last (often a terminal), and a tap on the
/// icon should show Pier itself. A closed main window opens again.
@MainActor
final class MainWindow {
    static let shared = MainWindow()
    /// Sessions of main windows now open.
    var sessions: Set<String> = []
    /// Opens a new main window (any window that can sets this).
    var open: (() -> Void)?
    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { MainWindow.shared.bringForward() } }
    }

    func bringForward() {
        if let session = UIApplication.shared.openSessions.first(where: { sessions.contains($0.persistentIdentifier) }) {
            UIApplication.shared.requestSceneSessionActivation(session, userActivity: nil, options: nil, errorHandler: nil)
        } else {
            open?()
        }
    }
}

/// Tells `MainWindow` about the window it is in: there while it is, gone
/// when its scene disconnects.
struct MainWindowMark: UIViewRepresentable {
    final class Probe: UIView {
        private var id: String?
        private var observer: NSObjectProtocol?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard id == nil, let scene = window?.windowScene else { return }
            let id = scene.session.persistentIdentifier
            self.id = id
            MainWindow.shared.sessions.insert(id)
            observer = NotificationCenter.default.addObserver(
                forName: UIScene.didDisconnectNotification, object: scene, queue: .main
            ) { _ in MainActor.assumeIsolated { _ = MainWindow.shared.sessions.remove(id) } }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: Probe, context: Context) {}
}

/// What a terminal window shows: a service, and an ID of its own. iPadOS
/// brings forward a window already showing the same value instead of
/// opening another, so every new window gets a new ID.
struct TerminalTarget: Codable, Hashable {
    var service: String
    var id = UUID()
}

/// What the selected service is, for the menu bar's commands.
struct SelectedServiceKey: FocusedValueKey {
    typealias Value = String
}

extension FocusedValues {
    var selectedService: String? {
        get { self[SelectedServiceKey.self] }
        set { self[SelectedServiceKey.self] = newValue }
    }
}

/// The menu bar: windows for services, and the terminal's own commands.
struct PierCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.selectedService) private var selected

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: .command)
            Button("New Terminal Window") {
                if let selected { openWindow(id: "terminal", value: TerminalTarget(service: selected)) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(selected == nil)
        }
    }
}
