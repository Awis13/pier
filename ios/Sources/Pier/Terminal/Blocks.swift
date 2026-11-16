import SwiftTerm
import UIKit

/// Splits the shell's output at its marks (OSC 133), so each mark is handled
/// with the terminal in the state the mark left it. A mark cut in two by the
/// stream waits for the rest.
struct MarkSplitter {
    private var carry: [UInt8] = []
    private static let intro = Array("\u{1b}]133;".utf8)

    /// The pieces to feed in order, each with the mark that ends it, if any
    /// (its body, such as "D;0").
    mutating func split(_ bytes: [UInt8]) -> [(ArraySlice<UInt8>, String?)] {
        let data = carry.isEmpty ? bytes : carry + bytes
        carry = []
        var out: [(ArraySlice<UInt8>, String?)] = []
        var start = 0
        var i = 0
        while let at = Self.find(Self.intro, in: data, from: i) {
            let bodyStart = at + Self.intro.count
            var end: Int?
            var j = bodyStart
            while j < data.count {
                if data[j] == 0x07 { end = j + 1; break }
                if data[j] == 0x1b, j + 1 < data.count, data[j + 1] == 0x5c { end = j + 2; break }
                if j - bodyStart > 256 { break }   // not a mark of ours
                j += 1
            }
            guard let end else {
                if j >= data.count {
                    // Cut by the stream: the rest comes with the next output.
                    out.append((data[start..<at], nil))
                    carry = Array(data[at...])
                    return out
                }
                i = bodyStart
                continue
            }
            let bodyEnd = data[end - 1] == 0x07 ? end - 1 : end - 2
            out.append((data[start..<end], String(decoding: data[bodyStart..<bodyEnd], as: UTF8.self)))
            start = end
            i = end
        }
        if start < data.count { out.append((data[start...], nil)) }
        return out
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8], from: Int) -> Int? {
        guard hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
        for i in from...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<i + needle.count]) == needle {
            return i
        }
        return nil
    }
}

/// One command and what it printed, as the shell marked them.
final class CommandBlock {
    /// Rows count from the first line the terminal ever had (buffer row
    /// plus lines trimmed off the top), so they stay put as history goes.
    var promptRow: Int
    var outputRow: Int?
    var command = ""
    var started: Date?
    var ended: Date?
    var exit: Int?
    init(promptRow: Int) { self.promptRow = promptRow }
}

/// Draws each command as a block, as Warp does: a hairline above its prompt
/// and, once it ends, a badge with how it ended, how long it took and when.
/// The terminal's right-click menu copies a block, its command or output.
@MainActor
final class CommandBlocks {
    weak var view: TerminalView?
    private(set) var blocks: [CommandBlock] = []
    private var lines: [UIView] = []
    private var badges: [UILabel] = []
    private static let keep = 1000

    init(view: TerminalView) { self.view = view }

    // MARK: Marks

    func mark(_ body: String, command: String?) {
        guard let v = view else { return }
        let t = v.getTerminal()
        guard !t.isCurrentBufferAlternate else { return }
        let fields = body.split(separator: ";", omittingEmptySubsequences: false)
        let row = absoluteCursorRow(v, t)
        switch fields.first {
        case "A":
            let promptRow = t.activeSemanticPromptOrigin.map { $0.row + t.buffer.totalLinesTrimmed } ?? row
            if let last = blocks.last, last.started == nil {
                last.promptRow = promptRow       // the prompt drawn again
            } else {
                blocks.append(CommandBlock(promptRow: promptRow))
                if blocks.count > Self.keep { blocks.removeFirst(blocks.count - Self.keep) }
            }
        case "C":
            guard let b = blocks.last, b.started == nil else { return }
            b.started = Date()
            b.command = command ?? ""
            b.outputRow = row
        case "D":
            guard let b = blocks.last, b.started != nil, b.ended == nil else { return }
            b.ended = Date()
            b.exit = fields.count > 1 ? Int(fields[1]) : nil
        default:
            break
        }
    }

    /// The scrollback was erased: no block is where it was.
    func clear() {
        blocks.removeAll()
        redraw()
    }

    // MARK: Text

    /// What a block printed: from its output's row to the next prompt.
    func output(of b: CommandBlock) -> String {
        guard let v = view, let first = b.outputRow else { return "" }
        let t = v.getTerminal()
        let next = blocks.first { $0.promptRow > b.promptRow }?.promptRow
        let last = (next ?? (absoluteCursorRow(v, t) + 1)) - 1
        guard last >= first else { return "" }
        var rows: [String] = []
        for r in first...last {
            guard let line = t.getScrollInvariantLine(row: r) else { continue }
            let text = line.translateToString(trimRight: true)
            if line.isWrapped, !rows.isEmpty { rows[rows.count - 1] += text } else { rows.append(text) }
        }
        while rows.last?.isEmpty == true { rows.removeLast() }
        return rows.joined(separator: "\n")
    }

    // MARK: Navigation

    /// Scrolls to the previous (up) or next block's prompt from what shows.
    func jump(up: Bool) {
        guard let v = view else { return }
        let t = v.getTerminal()
        let h = cellHeight(v, t)
        guard h > 0 else { return }
        let top = Int((v.contentOffset.y / h).rounded()) + t.buffer.totalLinesTrimmed
        let rows = blocks.map(\.promptRow)
        let target = up ? rows.last { $0 < top } : rows.first { $0 > top }
        if let target { v.scrollTo(row: max(0, target - t.buffer.totalLinesTrimmed)) }
    }

    // MARK: Drawing

    func redraw() {
        guard let v = view else { return }
        let t = v.getTerminal()
        let h = cellHeight(v, t)
        var used = 0, usedBadges = 0
        defer {
            for i in used..<lines.count { lines[i].isHidden = true }
            for i in usedBadges..<badges.count { badges[i].isHidden = true }
        }
        guard h > 0, !t.isCurrentBufferAlternate else { return }
        let trimmed = t.buffer.totalLinesTrimmed
        let width = v.bounds.width
        let fg = v.nativeForegroundColor
        for (i, b) in blocks.enumerated() {
            let r = b.promptRow - trimmed
            guard r >= 0, isPrompt(r, t) else { continue }
            let y = CGFloat(r) * h
            if i > 0 {
                let line = pooled(&lines, used) { UIView() }
                line.backgroundColor = fg.withAlphaComponent(0.14)
                // In the middle of the blank row the prompt leaves above it, if
                // there is one: the line keeps off the prompt's text.
                let above = r > 0 && (t.getScrollInvariantLine(row: b.promptRow - 1)?.translateToString(trimRight: true).isEmpty ?? false)
                line.frame = CGRect(x: 0, y: above ? y - h / 2 : y - 0.5, width: width, height: 0.5)
                line.isHidden = false
                v.bringSubviewToFront(line)
                used += 1
            }
            guard b.ended != nil else { continue }
            let badge = pooled(&badges, usedBadges) { Self.makeBadge() }
            style(badge, for: b, font: v.font)
            let size = badge.intrinsicContentSize
            let w = size.width + 12
            badge.frame = CGRect(x: max(0, width - w - 14), y: y + 2, width: w, height: max(h - 4, 10))
            badge.isHidden = false
            v.bringSubviewToFront(badge)
            usedBadges += 1
        }
    }

    private static func makeBadge() -> UILabel {
        let l = UILabel()
        l.textAlignment = .center
        l.layer.cornerRadius = 5
        l.clipsToBounds = true
        l.isUserInteractionEnabled = false
        return l
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// How a block ended: ✓ or ✗ with the code, how long it ran, when it ended.
    private func style(_ badge: UILabel, for b: CommandBlock, font: UIFont) {
        let ok = b.exit == 0
        let color: UIColor = b.exit == nil ? .secondaryLabel : ok ? .systemGreen : .systemRed
        var parts = [ok ? "✓" : "✗ \(b.exit.map(String.init) ?? "?")"]
        if let s = b.started, let e = b.ended { parts.append(Self.duration(e.timeIntervalSince(s))) }
        if let e = b.ended { parts.append(Self.clock.string(from: e)) }
        badge.text = parts.joined(separator: " · ")
        badge.font = UIFont.monospacedSystemFont(ofSize: max(font.pointSize - 3, 9), weight: .medium)
        badge.textColor = color
        badge.backgroundColor = color.withAlphaComponent(0.13)
    }

    /// The block whose prompt or output is on a buffer row.
    func block(atBufferRow r: Int) -> CommandBlock? {
        guard let v = view else { return nil }
        let abs = r + v.getTerminal().buffer.totalLinesTrimmed
        return blocks.last { $0.promptRow <= abs }
    }

    /// Its command and what it printed, as one text.
    func text(of b: CommandBlock) -> String {
        let out = output(of: b)
        return b.command.isEmpty ? out : "$ \(b.command)" + (out.isEmpty ? "" : "\n" + out)
    }

    private static func duration(_ d: TimeInterval) -> String {
        if d < 1 { return String(format: "%.0fms", d * 1000) }
        if d < 60 { return String(format: "%.1fs", d) }
        let m = Int(d) / 60, s = Int(d) % 60
        return m < 60 ? "\(m)m \(s)s" : "\(m / 60)h \(m % 60)m"
    }

    /// A row the shell's prompt is still on (clear may have wiped it).
    private func isPrompt(_ r: Int, _ t: Terminal) -> Bool {
        (0..<min(t.cols, 8)).contains {
            if case .prompt = t.semanticContent(at: Position(col: $0, row: r)) { true } else { false }
        }
    }

    private func cellHeight(_ v: TerminalView, _ t: Terminal) -> CGFloat {
        t.rows > 0 ? v.getOptimalFrameSize().height / CGFloat(t.rows) : 0
    }

    private func absoluteCursorRow(_ v: TerminalView, _ t: Terminal) -> Int {
        var top = t.getTopVisibleRow()
        let h = cellHeight(v, t)
        if h > 0 { top = max(top, Int((v.contentSize.height / h).rounded()) - t.rows) }
        return top + t.getCursorLocation().y + t.buffer.totalLinesTrimmed
    }

    private func pooled<V: UIView>(_ pool: inout [V], _ i: Int, make: () -> V) -> V {
        if i == pool.count {
            let v = make()
            view?.addSubview(v)
            pool.append(v)
        }
        return pool[i]
    }
}
