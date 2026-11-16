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
    /// The service's shell: bash if the image has it, else ash or sh. bash
    /// starts with hooks that mark its prompts and commands (OSC 133), as
    /// Ghostty and Warp do, with nothing installed in the container: a rc
    /// file in a fresh temporary directory reads the login files, adds the
    /// hooks and removes the directory. The marks let the terminal tell what
    /// is typed at the prompt (suggestions from history) and what ran.
    static let shellCommand = ["/bin/sh", "-c", shellLoader]

    static let bashHooks = #"""
        _pier_ran= _pier_armed=
        _pier_precmd() {
          local s=$?
          if [[ -n $_pier_ran ]]; then printf '\e]133;D;%s\a' $s; else printf '\e]133;D\a'; fi
          _pier_ran=
          printf '\e]7;file://%s%s\a' "$HOSTNAME" "$PWD"
          [[ $PS1 == *'133;B'* ]] || PS1='\[\e]133;A\a\]'"$PS1"'\[\e]133;B\a\]'
        }
        _pier_arm() { _pier_armed=1; }
        _pier_command() { _pier_ran=1; printf '\e]133;C\a'; }
        _pier_preexec() {
          [[ -n $_pier_armed && -z $COMP_LINE ]] || return 0
          _pier_armed=
          # An empty line runs PROMPT_COMMAND straight away: no command of the user's.
          [[ $BASH_COMMAND == _pier_precmd* ]] && return 0
          _pier_command
        }
        # A DEBUG trap already set keeps running after ours.
        _pier_trap_body() { eval "set -- $(trap -p DEBUG)"; _pier_debug=${3-}; }
        if [[ -n ${bash_preexec_imported:-}${__bp_imported:-} ]]; then
          precmd_functions=(_pier_precmd "${precmd_functions[@]}")
          preexec_functions+=(_pier_command)
        else
          _pier_debug=
          _pier_trap_body
          if [[ -n $_pier_debug ]]; then
            trap '_pier_preexec; eval "$_pier_debug"' DEBUG
          else
            trap '_pier_preexec' DEBUG
          fi
          if [[ $(declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a"* ]]; then
            PROMPT_COMMAND=(_pier_precmd "${PROMPT_COMMAND[@]}" _pier_arm)
          else
            PROMPT_COMMAND="_pier_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND};_pier_arm"
          fi
        fi
        """#

    static let shellLoader = """
        if command -v bash >/dev/null 2>&1; then
          d=$(mktemp -d 2>/dev/null) || exec bash -l
          cat >"$d/rc" <<'PIER_EOF'
        [ -f /etc/profile ] && . /etc/profile
        for f in ~/.bash_profile ~/.bash_login ~/.profile; do [ -f "$f" ] && { . "$f"; break; }; done
        \(bashHooks)
        command rm -rf -- "$PIER_TMP"; unset PIER_TMP
        PIER_EOF
          PIER_TMP=$d exec bash --rcfile "$d/rc" -i
        elif command -v ash >/dev/null 2>&1; then exec ash -l
        else exec sh -l
        fi
        """

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
