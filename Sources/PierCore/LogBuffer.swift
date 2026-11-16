import Containerization
import Foundation
import Synchronization

/// A container's output: the last lines kept in memory, for the log view.
public final class LogBuffer: Writer, Sendable {
    private struct State {
        var lines: [String] = []
        var partial = Data()
        var version = 0
    }

    private let state = Mutex(State())
    private let limit: Int

    public init(limit: Int = 2000) {
        self.limit = limit
    }

    public func write(_ data: Data) throws {
        append(data)
    }

    public func close() throws {}

    public func append(_ data: Data) {
        state.withLock { s in
            s.partial.append(data)
            while let nl = s.partial.firstIndex(of: 0x0A) {
                let line = s.partial[s.partial.startIndex..<nl]
                s.lines.append(String(decoding: line, as: UTF8.self))
                s.partial.removeSubrange(s.partial.startIndex...nl)
            }
            // Output without newlines (progress bars, binary) still makes lines.
            if s.partial.count > 16 << 10 {
                s.lines.append(String(decoding: s.partial, as: UTF8.self))
                s.partial.removeAll()
            }
            if s.lines.count > limit {
                s.lines.removeFirst(s.lines.count - limit)
            }
            s.version += 1
        }
    }

    public func note(_ text: String) {
        append(Data((text + "\n").utf8))
    }

    /// Bumps on every write, so a view can tell it has something new.
    public var version: Int { state.withLock { $0.version } }

    public var text: String {
        state.withLock { s in
            var all = s.lines.joined(separator: "\n")
            if !s.partial.isEmpty {
                all += "\n" + String(decoding: s.partial, as: UTF8.self)
            }
            return all
        }
    }

    public func clear() {
        state.withLock { $0 = State(version: $0.version + 1) }
    }
}
