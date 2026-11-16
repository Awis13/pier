import Containerization
import ContainerizationOS
import Foundation
import Synchronization

/// An interactive shell in a service: a process with a terminal (a PTY in the
/// guest), its input and output carried over vsock by the guest agent. No SSH
/// server is involved.
public final class ShellSession: Sendable {
    public let service: String
    private let process: LinuxProcess
    private let input: InputStream
    private let done = Mutex<Bool>(false)

    init(service: String, process: LinuxProcess, input: InputStream) {
        self.service = service
        self.process = process
        self.input = input
    }

    /// Bytes typed by the user.
    public func send(_ data: Data) {
        input.send(data)
    }

    public func resize(cols: Int, rows: Int) async {
        guard cols > 0, rows > 0 else { return }
        try? await process.resize(to: .init(width: UInt16(min(cols, 1000)), height: UInt16(min(rows, 1000))))
    }

    /// Waits for the shell to exit; returns its code.
    public func wait() async -> Int32 {
        let status = try? await process.wait()
        finish()
        return status?.exitCode ?? -1
    }

    /// Ends the shell (SIGHUP, as closing a terminal does).
    public func close() async {
        try? await process.kill(.hup)
        finish()
    }

    private func finish() {
        let first = done.withLock { d -> Bool in
            defer { d = true }
            return !d
        }
        guard first else { return }
        input.finish()
        Task { try? await process.delete() }
    }

    /// The process's stdin: what `send` hands it.
    final class InputStream: ReaderStream, Sendable {
        private let pair = AsyncStream<Data>.makeStream()

        func stream() -> AsyncStream<Data> { pair.stream }
        func send(_ data: Data) { pair.continuation.yield(data) }
        func finish() { pair.continuation.finish() }
    }

    /// The process's stdout, to a callback.
    final class Output: Writer, Sendable {
        let handler: @Sendable (Data) -> Void
        init(_ handler: @escaping @Sendable (Data) -> Void) { self.handler = handler }
        func write(_ data: Data) throws { handler(data) }
        func close() throws {}
    }
}

extension PodRunner {
    /// The login shell of the service: bash if the image has it, else sh.
    static let shellCommand = [
        "/bin/sh", "-c",
        "if command -v bash >/dev/null 2>&1; then exec bash -l; elif command -v ash >/dev/null 2>&1; then exec ash -l; else exec sh -l; fi",
    ]

    /// Opens a shell with a terminal in a running service. `output` gets
    /// everything the terminal prints, on the agent's threads.
    public func openShell(
        in service: String,
        cols: Int,
        rows: Int,
        command: [String]? = nil,
        output: @escaping @Sendable (Data) -> Void
    ) async throws -> ShellSession {
        guard let pod = currentPod else { throw PierError("the pod is not running") }
        let input = ShellSession.InputStream()
        let out = ShellSession.Output(output)
        let (target, args) = route(command ?? Self.shellCommand, in: service)
        let process = try await pod.execInContainer(target, processID: "tty-\(UUID().uuidString.prefix(8))") { c in
            c.arguments = args
            c.terminal = true
            c.stdin = input
            c.stdout = out
            c.environmentVariables.removeAll { $0.hasPrefix("TERM=") }
            c.environmentVariables.append("TERM=xterm-256color")
            c.environmentVariables.append("COLORTERM=truecolor")
            // apt asks nothing and takes the defaults, as in Docker images.
            if !c.environmentVariables.contains(where: { $0.hasPrefix("DEBIAN_FRONTEND=") }) {
                c.environmentVariables.append("DEBIAN_FRONTEND=noninteractive")
            }
            if c.workingDirectory.isEmpty { c.workingDirectory = "/" }
        }
        try await process.start()
        let session = ShellSession(service: service, process: process, input: input)
        await session.resize(cols: cols, rows: rows)
        return session
    }
}
