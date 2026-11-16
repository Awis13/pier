// pierctl: runs a pod spec on the Mac, for checking PierCore without the iPad.

import ArgumentParser
import Foundation
import Logging
import PierCore

@main
struct PierCtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pierctl",
        abstract: "Run a Pier pod on this Mac"
    )

    @Option(name: .shortAndLong, help: "Kernel (arm64 Image)")
    var kernel: String

    @Option(name: .long, help: "Pier's data directory")
    var root: String

    @Option(name: .long, help: "cpu backend: auto (hvf) or jit")
    var backend: String = "auto"

    @Option(name: .long, help: "Seconds to keep the pod up; 0 waits for Ctrl-C")
    var seconds: Int = 0

    @Option(name: .long, help: "After start, run this shell command in a service (SERVICE:COMMAND)")
    var exec: [String] = []

    @Option(name: .long, help: "Install SSH in this service after start")
    var installSsh: String?

    @Option(name: .long, help: "Open a terminal shell in this service and run a check through it")
    var ttyTest: String?

    @Option(name: .long, help: "After start, restart this service alone")
    var restart: String?

    @Flag(name: .long, help: "Only read the Compose file and print the services")
    var check = false

    @Argument(help: "Pod spec (JSON), or a Compose file or its folder")
    var spec: String

    func run() async throws {
        setvbuf(stdout, nil, _IONBF, 0)
        let input = URL(fileURLWithPath: spec)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: input.path, isDirectory: &isDir)
        let spec: PodSpec
        var compose: ComposeProject?
        if isDir.boolValue || ["yml", "yaml"].contains(input.pathExtension) {
            let file = isDir.boolValue ? ComposeProject.file(in: input) : input
            guard let file else { throw PierError("no Compose file in \(input.path)") }
            let project = try ComposeProject.parse(String(contentsOf: file, encoding: .utf8), directory: file.deletingLastPathComponent())
            for w in project.warnings { print("[compose] warning: \(w)") }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            for s in project.services {
                print("[compose] \(s.name): \(String(decoding: try enc.encode(s), as: UTF8.self))")
            }
            for c in project.copies { print("[compose] keeps \(c.from.path) as \(c.to)") }
            if check { return }
            let memory = project.services.reduce(UInt64(512)) { $0 + $1.memoryMiB / 2 }
            spec = PodSpec(services: project.services, memoryMiB: min(max(memory, 2048), 6144))
            compose = project
        } else {
            spec = try JSONDecoder().decode(PodSpec.self, from: Data(contentsOf: input))
        }
        var logger = Logger(label: "pier")
        logger.logLevel = .warning
        let runner = try PodRunner(
            root: URL(fileURLWithPath: root),
            kernel: URL(fileURLWithPath: kernel),
            logger: logger,
            onChange: { s in
                let services = s.services.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.label)" }
                print("[state] pod=\(s.pod.label) \(services.joined(separator: " "))")
            }
        )
        if let compose { try runner.keepFiles(of: compose) }
        try await runner.start(spec, backend: backend == "jit" ? .jit(nil) : .auto)
        if let boot = runner.snapshot.bootSeconds {
            print("[pier] vm booted in \(String(format: "%.2f", boot)) s")
        }
        if let svc = installSsh {
            let port = spec.services.first { $0.name == svc }?.sshPort ?? spec.freeSSHPort()
            let out = try await runner.installSSH(in: svc, port: port)
            print("[ssh] \(svc) on \(port)\n\(out.suffix(600))")
        }
        if let svc = ttyTest {
            let shell = try await runner.openShell(in: svc, cols: 100, rows: 30) { data in
                FileHandle.standardOutput.write(data)
            }
            shell.send(Data("tty; stty size; echo TERM=$TERM; echo SHELL=$0\n".utf8))
            try await Task.sleep(for: .seconds(2))
            await shell.resize(cols: 132, rows: 40)
            shell.send(Data("stty size; exit 7\n".utf8))
            let code = await shell.wait()
            print("\n[tty] exit \(code)")
        }
        if let name = restart, let svc = spec.services.first(where: { $0.name == name }) {
            let t0 = ContinuousClock.now
            try await runner.restartService(svc, in: spec)
            print("[restart] \(name) in \(ContinuousClock.now - t0)")
        }
        for e in exec {
            guard let colon = e.firstIndex(of: ":") else { continue }
            let service = String(e[..<colon])
            let command = String(e[e.index(after: colon)...])
            let (code, out) = try await runner.exec(["/bin/sh", "-c", command], in: service)
            print("[exec \(service)] exit \(code)\n\(out)")
        }
        if seconds > 0 {
            try await Task.sleep(for: .seconds(seconds))
        } else {
            try await Task.sleep(for: .seconds(365 * 24 * 3600))
        }
        for s in spec.services {
            print("---- \(s.name)\n\(runner.log(for: s.name).text.suffix(1500))")
        }
        print("---- pod\n\(runner.podLog.text.split(separator: "\n").filter { !$0.contains("vminitd") }.suffix(40).joined(separator: "\n"))")
        await runner.stop()
    }
}
