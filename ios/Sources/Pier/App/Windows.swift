import PierCore
import SwiftUI

/// A window with shells of one service: tabs of its own, a new shell when
/// it opens, all of them closed when it closes, so windows never take each
/// other's sessions.
struct TerminalWindow: View {
    @Environment(PodModel.self) private var pod
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var windowID = UUID().uuidString
    let serviceName: String?

    private var deck: String { "\(serviceName ?? "")@\(windowID)" }

    var body: some View {
        Group {
            if let name = serviceName, let service = pod.spec.services.first(where: { $0.name == name }) {
                let deck = deck
                Group {
                    if pod.terminals.contains(where: { $0.deck == deck }) {
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
                .onDisappear { pod.closeDeck(deck) }
                // Shift-Command-N here: another window, a new shell in the same container.
                .focusedSceneValue(\.selectedService, name)
            } else {
                ContentUnavailableView("No Such Service", systemImage: "terminal",
                                       description: Text("Open a service's terminal window from its menu."))
            }
        }
    }
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
                if let selected { openWindow(id: "terminal", value: selected) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(selected == nil)
        }
    }
}
