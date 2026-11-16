import SwiftTerm
import SwiftUI
import UIKit

/// A command run in a service, for suggestions as you type and for Cmd-R.
struct HistoryEntry: Codable, Hashable {
    var command: String
    var service: String
    var directory: String?
    var time: Date
}

/// Every service's commands, kept on the iPad, newest last.
@MainActor
final class CommandHistory {
    static let shared = CommandHistory()
    private(set) var entries: [HistoryEntry] = []
    private let url = PodModel.dataDirectory.appendingPathComponent("history.json")
    private static let keep = 5000

    private init() {
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    /// A command that ran. One typed with a space first stays out, as shells do.
    func add(_ typed: String, service: String, directory: String?) {
        let command = typed.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty, !typed.hasPrefix(" "),
              !command.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return }
        entries.removeAll { $0.command == command && $0.service == service }
        entries.append(HistoryEntry(command: command, service: service, directory: directory, time: Date()))
        if entries.count > Self.keep { entries.removeFirst(entries.count - Self.keep) }
        let snapshot = entries, url = url
        Task.detached { try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic) }
    }

    /// The newest command that starts with what is typed: from the same
    /// service and directory first, then the service, then anywhere.
    func suggestion(for typed: String, service: String, directory: String?) -> String? {
        let candidates = entries.reversed().filter { $0.command.hasPrefix(typed) && $0.command != typed }
        return candidates.first { $0.service == service && $0.directory == directory }?.command
            ?? candidates.first { $0.service == service }?.command
            ?? candidates.first?.command
    }
}

/// Reads the shell's marks (OSC 133) around one terminal: what is typed at
/// the prompt gets the history's suggestion, drawn grey after the cursor as
/// fish does, and a command that runs goes into the history.
@MainActor
final class Suggester {
    weak var view: TerminalView?
    let service: String
    var directory: String?
    /// The suggestion's text after what is typed, while one shows.
    private(set) var remainder: String?
    var onTap: (() -> Void)?
    private var inputRow: Int?         // the buffer row typing starts on, with trimmed lines counted
    private var stale = false
    private let ghost = UILabel()

    private static let markB = Array("\u{1b}]133;B".utf8)
    private static let markC = Array("\u{1b}]133;C".utf8)

    init(view: TerminalView, service: String) {
        self.view = view
        self.service = service
        ghost.isHidden = true
        ghost.lineBreakMode = .byClipping
        ghost.isUserInteractionEnabled = true
        ghost.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        view.addSubview(ghost)
    }

    /// Before output reaches the terminal: a command starting (C) is read
    /// from the screen while it still shows what was typed.
    func before(_ bytes: [UInt8]) {
        guard let v = view, Self.contains(Self.markC, in: bytes) else { return }
        if let typed = typedText(v.getTerminal(), toCursor: false) {
            CommandHistory.shared.add(typed, service: service, directory: directory)
        }
        inputRow = nil
        hide()
    }

    /// After output reached it: a prompt ready for typing (B) is noted, and
    /// the suggestion follows what is typed now.
    func after(_ bytes: [UInt8]) {
        guard let v = view else { return }
        let t = v.getTerminal()
        if Self.contains(Self.markB, in: bytes), !t.isCurrentBufferAlternate {
            inputRow = liveTop(v, t) + t.getCursorLocation().y + t.buffer.totalLinesTrimmed
        }
        stale = false
        update()
    }

    /// A key went to the shell: what shows may no longer be at the cursor.
    func keySent() { stale = true }

    /// The suggestion to type, once: nil when none shows.
    func accept() -> String? {
        guard let rest = remainder, !stale else { return nil }
        hide()
        return rest
    }

    func hide() {
        ghost.isHidden = true
        remainder = nil
    }

    @objc private func tapped() { onTap?() }

    private func update() {
        guard let v = view else { return hide() }
        let t = v.getTerminal()
        guard !t.isCurrentBufferAlternate, inputRow != nil, t.cols > 0, t.rows > 0,
              let typed = typedText(t, toCursor: true), !typed.trimmingCharacters(in: .whitespaces).isEmpty,
              let full = CommandHistory.shared.suggestion(for: typed, service: service, directory: directory)
        else { return hide() }
        let rest = String(full.dropFirst(typed.count))
        guard !rest.isEmpty else { return hide() }
        let (cx, cy) = t.getCursorLocation()
        let size = v.getOptimalFrameSize()
        let cell = CGSize(width: size.width / CGFloat(t.cols), height: size.height / CGFloat(t.rows))
        let x = CGFloat(cx) * cell.width
        ghost.font = v.font
        ghost.textColor = v.nativeForegroundColor.withAlphaComponent(0.38)
        ghost.text = rest
        let room = max(0, CGFloat(t.cols) * cell.width - x)
        ghost.frame = CGRect(x: x, y: CGFloat(liveTop(v, t) + cy) * cell.height,
                             width: min(room, ghost.sizeThatFits(.zero).width), height: cell.height)
        ghost.isHidden = room <= 0
        v.bringSubviewToFront(ghost)
        remainder = rest
    }

    /// The typed text from where typing starts: to the cursor, or all of it.
    /// Only the cells the terminal marked as input count; anything after the
    /// cursor but blanks means an edit in the middle, which gets nothing.
    private func typedText(_ t: Terminal, toCursor: Bool) -> String? {
        guard let v = view, let abs = inputRow else { return nil }
        let start = abs - t.buffer.totalLinesTrimmed
        let (cx, cy) = t.getCursorLocation()
        let row = liveTop(v, t) + cy
        guard start >= 0, row >= start, row - start < t.rows else { return nil }
        var typed = ""
        for r in start...row {
            guard let line = t.getScrollInvariantLine(row: r + t.buffer.totalLinesTrimmed) else { return nil }
            let cols = (0..<t.cols).filter { t.semanticContent(at: Position(col: $0, row: r)) == .input }
            if r < row || !toCursor {
                for c in cols { typed += Self.cellText(line, c, t) }
                continue
            }
            for c in cols where c < cx { typed += Self.cellText(line, c, t) }
            if cols.contains(where: { $0 >= cx && Self.cellText(line, $0, t) != " " }) { return nil }
        }
        return toCursor ? typed : typed.trimmingCharacters(in: .whitespaces).isEmpty ? nil : typed.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    /// Where the live screen's first row is in the buffer (not the scrolled view's).
    private func liveTop(_ v: TerminalView, _ t: Terminal) -> Int {
        var top = t.getTopVisibleRow()
        let h = t.rows > 0 ? v.getOptimalFrameSize().height / CGFloat(t.rows) : 0
        if h > 0 { top = max(top, Int((v.contentSize.height / h).rounded()) - t.rows) }
        return top
    }

    private static func cellText(_ line: BufferLine, _ c: Int, _ t: Terminal) -> String {
        let cd = line[c]
        if cd.width == 0 { return "" }
        let ch = t.getCharacter(for: cd)
        return ch == "\u{0}" ? " " : String(ch)
    }

    private static func contains(_ needle: [UInt8], in hay: [UInt8]) -> Bool {
        guard hay.count >= needle.count else { return false }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<i + needle.count]) == needle {
            return true
        }
        return false
    }
}

/// Cmd-R: every service's commands, newest first, found by all the words typed.
struct HistorySearchView: View {
    let service: String
    let pick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [HistoryEntry] {
        let words = query.lowercased().split(separator: " ")
        var seen = Set<String>()
        return CommandHistory.shared.entries.reversed().filter { e in
            words.allSatisfy { e.command.lowercased().contains($0) } && seen.insert(e.command).inserted
        }
    }

    var body: some View {
        NavigationStack {
            List(results.prefix(300), id: \.self) { e in
                Button {
                    pick(e.command)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.command).font(.callout.monospaced()).lineLimit(2).foregroundStyle(.primary)
                        Text(e.service == service ? (e.directory ?? "") : "\(e.service)  \(e.directory ?? "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView("No Commands", systemImage: "clock.arrow.circlepath",
                                           description: Text("Commands run in Pier's shells show up here."))
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search commands")
            .navigationTitle("Command History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
