import PierCore
import SwiftUI

/// A window with one service's terminals, as in full screen.
struct TerminalWindow: View {
    @Environment(PodModel.self) private var pod
    @Environment(\.dismissWindow) private var dismissWindow
    let serviceName: String?

    var body: some View {
        Group {
            if let name = serviceName, let service = pod.spec.services.first(where: { $0.name == name }) {
                FullScreenTerminal(pod: pod, service: service) { dismissWindow() }
                    .ignoresSafeArea()
                    .navigationTitle(name)
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
        CommandGroup(after: .newItem) {
            Button("New Terminal Window") {
                if let selected { openWindow(id: "terminal", value: selected) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(selected == nil)
        }
    }
}
