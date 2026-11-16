import Foundation
import UIKit
import Observation
import PierCore

/// The pod as the screens see it: its spec, saved between launches, and what
/// the runner says about it.
@MainActor @Observable
final class PodModel {
    var spec: PodSpec {
        didSet { save() }
    }
    private(set) var snapshot = PodSnapshot()
    var lastError: String?
    /// Bumps a few times a second while the pod runs, so logs refresh.
    private(set) var tick = 0

    let runner: PodRunner
    private var ticker: Task<Void, Never>?

    static let dataDirectory = URL.applicationSupportDirectory.appendingPathComponent("Pier")
    private static let specURL = dataDirectory.appendingPathComponent("pod.json")

    init() {
        let kernel = Bundle.main.url(forResource: "vmlinux", withExtension: nil)!
        try? FileManager.default.createDirectory(at: Self.dataDirectory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: Self.specURL),
            let saved = try? JSONDecoder().decode(PodSpec.self, from: data)
        {
            spec = saved
        } else {
            spec = PodSpec(services: [Templates.all[0].service])
        }
        var model: PodModel?
        runner = try! PodRunner(root: Self.dataDirectory, kernel: kernel) { snap in
            Task { @MainActor in model?.snapshot = snap }
        }
        model = self
        if Checks.has("--demo-pod") {
            spec = Templates.demoPod
        }
        AppLog.write("pier: \(spec.services.count) services in the pod")
    }

    /// Set by the `--autostart` launch argument: start once JIT is on.
    var autostartPending = Checks.has("--autostart")
    private var launchSettled = false

    /// What every window does as JIT settles: turn it on by itself once at
    /// launch, and start the pod if the launch asked for it. Any window may
    /// be the first iPadOS shows, so each calls this.
    func jitChanged(_ jit: JITSession) {
        if !launchSettled, jit.state != .checking {
            launchSettled = true
            if !jit.isOn, jit.state == .off(.noDebugger) {
                Task { await jit.turnOn(.builtInStikJIT, interactive: false) }
            }
        }
        if jit.isOn, autostartPending, !isActive {
            autostartPending = false
            start(jit: jit)
        }
        if snapshot.pod == .running, Checks.has("--close-windows") {
            Task {
                try? await Task.sleep(for: .seconds(5))
                AppLog.write("pier: closing every window, pod \(snapshot.pod.label)")
                for session in UIApplication.shared.openSessions {
                    UIApplication.shared.requestSceneSessionDestruction(session, options: nil)
                }
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(spec) {
            try? data.write(to: Self.specURL, options: .atomic)
        }
    }

    var isActive: Bool { snapshot.pod.isActive }

    func state(of service: ServiceSpec) -> ServiceState {
        snapshot.services[service.name] ?? .stopped
    }

    func start(jit: JITSession) {
        Task { await run(jit: jit) }
    }

    private func run(jit: JITSession) async {
        lastError = nil
        let backend: PierBackend
        if let r = jit.region, let exec = r.executable, let write = r.writable {
            backend = .jit(executable: exec, writable: write, size: r.size)
        } else {
            backend = .jit(nil)
        }
        let spec = self.spec
        KeepAlive.shared.terminalOpened()
        startTicker()
        do {
            try await runner.start(spec, backend: backend)
            reconnectTerminals()
            for port in spec.services.flatMap(\.ports) {
                AppLog.write("pier: port \(port.container) at \(addresses(for: port).joined(separator: ", "))")
            }
        } catch is CancellationError {
            AppLog.write("pier: start stopped")
            KeepAlive.shared.terminalClosed()
            stopTicker()
        } catch {
            lastError = String(describing: error)
            AppLog.write("pier: start failed: \(error)")
            KeepAlive.shared.terminalClosed()
            stopTicker()
        }
    }

    /// Changes the services; a running pod restarts with them, since crate
    /// cannot add disks to a running machine.
    func change(jit: JITSession, _ body: (inout [ServiceSpec]) -> Void) {
        let before = Set(spec.services.map(\.name))
        body(&spec.services)
        // A removed service takes its disk with it, as `docker rm` does; its
        // image stays, so adding it again starts clean and fast.
        let removed = before.subtracting(spec.services.map(\.name))
        guard isActive else {
            Task { for name in removed { try? await runner.reset(service: name) } }
            return
        }
        Task {
            await runner.stop()
            for name in removed {
                try? await runner.reset(service: name)
                for t in terminals where t.service == name { closeTerminal(t) }
            }
            KeepAlive.shared.terminalClosed()
            if !spec.services.isEmpty {
                await run(jit: jit)
            } else {
                stopTicker()
            }
        }
    }

    /// Terminal tabs, in the order they were opened, and the one each
    /// service shows.
    var terminals: [TermTab] = []
    var selectedTerminal: [String: UUID] = [:]


    /// A new shell in `service`, among the tabs of `deck` (by default the
    /// service's own: its page and full screen).
    func openTerminal(in service: ServiceSpec, deck: String? = nil) {
        let deck = deck ?? service.name
        let n = terminals.filter { $0.service == service.name }.count + 1
        let tab = TermTab(service: service.name, deck: deck, number: n, pod: self)
        terminals.append(tab)
        selectedTerminal[deck] = tab.id
    }

    func closeTerminal(_ tab: TermTab) {
        tab.close()
        terminals.removeAll { $0.id == tab.id }
        if selectedTerminal[tab.deck] == tab.id {
            selectedTerminal[tab.deck] = terminals.last { $0.deck == tab.deck }?.id
        }
    }

    /// Closes every shell of a window's tabs (the window went away).
    func closeDeck(_ deck: String) {
        for t in terminals where t.deck == deck { closeTerminal(t) }
        selectedTerminal[deck] = nil
    }

    /// After the pod comes back, tabs whose shells ended with it start again.
    private func reconnectTerminals() {
        for t in terminals where t.ended != nil && spec.services.contains(where: { $0.name == t.service }) {
            t.restart()
        }
    }

    /// The service whose Log tab should come forward (set when Pier runs
    /// something in it whose output matters).
    var logRequest: String?

    /// Runs a command in a service; it and its output go to the service's log.
    func run(_ command: String, in service: ServiceSpec) async {
        let log = runner.log(for: service.name)
        log.note("$ \(command)")
        let out = await exec(command, in: service)
        log.note(out.hasSuffix("\n") ? String(out.dropLast()) : out)
    }

    func stop() {
        Task {
            await runner.stop()
            KeepAlive.shared.terminalClosed()
            stopTicker()
        }
    }

    func reset(_ service: ServiceSpec) {
        Task {
            do { try await runner.reset(service: service.name) } catch { lastError = String(describing: error) }
        }
    }

    func exec(_ command: String, in service: ServiceSpec) async -> String {
        do {
            let (code, out) = try await runner.exec(["/bin/sh", "-c", command], in: service.name)
            return out + (code == 0 ? "" : "\n[exit \(code)]")
        } catch {
            return "error: \(error)"
        }
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                tick &+= 1
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
        tick &+= 1
    }

    /// TCP ports each running service listens on, read from /proc/net/tcp
    /// inside it (each service may have a network of its own).
    func listeningPorts() async -> [String: [UInt16]]? {
        let running = spec.services.filter { state(of: $0) == .running }
        guard !running.isEmpty else { return nil }
        var out: [String: [UInt16]] = [:]
        for svc in running {
            guard let (_, text) = try? await runner.exec(["/bin/sh", "-c", "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null"], in: svc.name) else { continue }
            var ports = Set<UInt16>()
            for line in text.split(separator: "\n") {
                let f = line.split(separator: " ", omittingEmptySubsequences: true)
                guard f.count > 3, f[3] == "0A", let colon = f[1].lastIndex(of: ":") else { continue }
                if let p = UInt16(f[1][f[1].index(after: colon)...], radix: 16) { ports.insert(p) }
            }
            out[svc.name] = ports.sorted()
        }
        return out
    }

    /// Remembered with the pod, so starting it leaves the service as it was.
    private func setStoppedByUser(_ name: String, _ on: Bool) {
        guard let i = spec.services.firstIndex(where: { $0.name == name }) else { return }
        spec.services[i].stoppedByUser = on ? true : nil
    }

    /// One service at a time; the rest of the pod keeps running.
    func stopService(_ service: ServiceSpec) {
        setStoppedByUser(service.name, true)
        Task {
            do { try await runner.stopService(service.name) } catch { lastError = String(describing: error) }
        }
    }

    func startService(_ service: ServiceSpec) {
        setStoppedByUser(service.name, false)
        let spec = self.spec
        let service = spec.services.first(where: { $0.name == service.name }) ?? service
        Task {
            do {
                try await runner.restartService(service, in: spec)
                for t in terminals where t.service == service.name && t.ended != nil { t.restart() }
            } catch { lastError = String(describing: error) }
        }
    }

    /// The service whose editor or delete question is open (set from its menu).
    var editRequest: String?
    var deleteRequest: String?

    /// Services SSH is being installed in right now.
    var installingSSH: Set<String> = []

    /// Installs OpenSSH in a running service, then restarts the pod so its
    /// port is forwarded; the output goes to the service's console.
    func installSSH(_ service: ServiceSpec, jit: JITSession) {
        guard !installingSSH.contains(service.name) else { return }
        installingSSH.insert(service.name)
        logRequest = service.name
        let log = runner.log(for: service.name)
        Task {
            let inside = Set((await listeningPorts() ?? [:]).values.joined())
            let port = spec.freeSSHPort(avoiding: inside)
            log.note("installing OpenSSH and tmux, SSH on port \(port); this can take a few minutes...")
            do {
                let text = try await runner.installSSH(in: service.name, port: port)
                log.note(String(text.suffix(6000)))
                log.note("SSH is on port \(port): root / pier. Restarting the pod to forward the port...")
                change(jit: jit) { services in
                    if let i = services.firstIndex(where: { $0.name == service.name }) { services[i].sshPort = port }
                }
            } catch {
                log.note("installing SSH failed: \(error)")
            }
            installingSSH.remove(service.name)
        }
    }

    /// Installs tmux in a running service; the output goes to its log.
    func installTmux(_ service: ServiceSpec) {
        guard !installingSSH.contains(service.name) else { return }
        installingSSH.insert(service.name)
        logRequest = service.name
        let log = runner.log(for: service.name)
        Task {
            log.note("installing tmux...")
            do {
                log.note(String(try await runner.installTmux(in: service.name).suffix(6000)))
                log.note("tmux is installed")
            } catch {
                log.note("installing tmux failed: \(error)")
            }
            installingSSH.remove(service.name)
        }
    }

    /// `ssh root@... -p ...` for a service with Pier's sshd.
    func sshCommand(for service: ServiceSpec) -> String? {
        guard let p = service.sshPort else { return nil }
        let host = spec.reachableFromNetwork ? (NetworkAddresses.current().first ?? "127.0.0.1") : "127.0.0.1"
        return "ssh root@\(host) -p \(p)"
    }

    /// Where a forwarded port answers: on this iPad, and from the network
    /// when the pod is reachable from it.
    func addresses(for port: PortMapping) -> [String] {
        var out = ["127.0.0.1:\(port.host)"]
        if spec.reachableFromNetwork {
            for ip in NetworkAddresses.current() {
                out.append("\(ip):\(port.host)")
            }
        }
        return out
    }
}


/// This device's IPv4 addresses on its network interfaces (Wi-Fi, VPNs).
enum NetworkAddresses {
    static func current() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("utun") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254.") && !result.contains(ip) {
                    result.append(ip)
                }
            }
        }
        return result
    }
}
