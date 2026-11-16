import PierCore
import SwiftTerm
import SwiftUI
import UIKit

/// Something Cmd-P can go to: a shell already open, or a new one.
struct SwitchEntry: Identifiable, Hashable {
    enum Kind: Hashable {
        case tab(UUID)
        case newShell
    }
    let kind: Kind
    let service: String
    let title: String
    let place: String     // where it is: the service's page, or a window
    let current: Bool

    var id: String {
        switch kind {
        case .tab(let id): id.uuidString
        case .newShell: "new/\(service)"
        }
    }
    var haystack: String { "\(service) \(title) \(place)".lowercased() }
}

/// Which window shows a deck of tabs (terminal windows register theirs), so
/// Cmd-P can bring it forward.
@MainActor
final class TerminalWindows {
    static let shared = TerminalWindows()
    var sessionByDeck: [String: String] = [:]
}

/// Asks the terminal on screen for a deck to show a tab (and the pane in it).
extension Notification.Name {
    static let pierShowTab = Notification.Name("pier.showTab")
    /// Cmd-P from a terminal (it takes the keys before the menu bar does);
    /// the object is the deck it shows.
    static let pierQuickSwitch = Notification.Name("pier.quickSwitch")
}

@MainActor
@Observable
final class SwitcherModel {
    let pod: PodModel
    let currentTab: UUID?
    var query = "" { didSet { if query != oldValue { selection = rows.first?.id } } }
    var selection: String?

    init(pod: PodModel, currentTab: UUID?) {
        self.pod = pod
        self.currentTab = currentTab
        selection = rows.first { !$0.current }?.id ?? rows.first?.id
    }

    var entries: [SwitchEntry] {
        var out: [SwitchEntry] = []
        var windowNumbers: [String: Int] = [:]
        for t in pod.terminals where t.paneOf == nil {
            let place: String
            if t.deck == t.service {
                place = "page"
            } else {
                if windowNumbers[t.deck] == nil { windowNumbers[t.deck] = windowNumbers.count + 1 }
                place = "window \(windowNumbers[t.deck]!)"
            }
            out.append(SwitchEntry(kind: .tab(t.id), service: t.service, title: t.title, place: place, current: t.id == currentTab))
        }
        for s in pod.spec.services where pod.state(of: s) == .running {
            out.append(SwitchEntry(kind: .newShell, service: s.name, title: "New shell", place: "new window", current: false))
        }
        return out
    }

    /// Entries matching every word of the query, a word matching when its
    /// letters come in that order.
    var rows: [SwitchEntry] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return entries }
        return entries.filter { e in words.allSatisfy { Self.subsequence($0, of: e.haystack) } }
    }

    var selected: SwitchEntry? { rows.first { $0.id == selection } }

    func move(_ d: Int) {
        let rs = rows
        guard !rs.isEmpty else { return }
        let i = rs.firstIndex { $0.id == selection } ?? 0
        selection = rs[(i + d + rs.count) % rs.count].id
    }

    /// The last lines a tab shows, for the preview.
    func screen(of entry: SwitchEntry) -> String {
        guard case .tab(let id) = entry.kind, let t = pod.terminals.first(where: { $0.id == id }) else { return "" }
        let term = t.view.getTerminal()
        var lines: [String] = []
        for r in 0..<term.rows {
            lines.append(term.getLine(row: r)?.translateToString(trimRight: true) ?? "")
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.suffix(40).joined(separator: "\n")
    }

    private static func subsequence(_ needle: Substring, of hay: String) -> Bool {
        var it = hay.makeIterator()
        return needle.allSatisfy { c in
            while let h = it.next() { if h == c { return true } }
            return false
        }
    }
}

/// Goes where a switch entry points.
@MainActor
enum Switch {
    static func go(to entry: SwitchEntry, pod: PodModel, openWindow: OpenWindowAction) {
        switch entry.kind {
        case .newShell:
            openWindow(id: "terminal", value: TerminalTarget(service: entry.service))
        case .tab(let id):
            guard let t = pod.terminals.first(where: { $0.id == id }) else { return }
            pod.selectedTerminal[t.deck] = t.id
            if t.deck == t.service {
                // A tab of the service's page: the main window, that service.
                pod.showRequest = t.service
                MainWindow.shared.bringForward()
            } else if let session = TerminalWindows.shared.sessionByDeck[t.deck],
                      let s = UIApplication.shared.openSessions.first(where: { $0.persistentIdentifier == session }) {
                UIApplication.shared.requestSceneSessionActivation(s, userActivity: nil, options: nil, errorHandler: nil)
            }
            NotificationCenter.default.post(name: .pierShowTab, object: t.id)
        }
    }
}

/// Cmd-P: every shell of every service, found by the letters typed, with
/// what each shows; Return goes there.
struct SwitcherView: View {
    @State var model: SwitcherModel
    let pick: (SwitchEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to a service or shell", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .onSubmit { choose(model.selected) }
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(14)
            Divider()
            HStack(spacing: 0) {
                List(model.rows, selection: $model.selection) { e in
                    row(e).tag(e.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { choose(e) }
                }
                .listStyle(.plain)
                .frame(minWidth: 260, maxWidth: 360)
                Divider()
                preview
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear { focused = true }
    }

    private func row(_ e: SwitchEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: e.kind == .newShell ? "plus.rectangle" : "terminal")
                .foregroundStyle(e.kind == .newShell ? Color.accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.kind == .newShell ? "New shell in \(e.service)" : e.title)
                    .font(.body.monospaced()).lineLimit(1)
                Text(e.current ? "\(e.place) · here" : e.place).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var preview: some View {
        if let e = model.selected, e.kind != .newShell {
            ScrollView {
                Text(model.screen(of: e))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .defaultScrollAnchor(.bottom)
            .background(Color.black.opacity(0.25))
        } else {
            ContentUnavailableView(model.selected.map { "New Shell in \($0.service)" } ?? "Nothing Found",
                                   systemImage: "terminal",
                                   description: Text(model.selected == nil ? "" : "Opens in a window of its own."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func choose(_ e: SwitchEntry?) {
        guard let e else { return }
        dismiss()
        pick(e)
    }
}
