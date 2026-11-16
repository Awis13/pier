// Ports published while the pod runs. The VM's own forwards are set when it
// boots, so a service added later (or a port added later) is published by the
// app instead: it listens on the iPad's port, and for each connection dials
// the VM's vsock, where the network helper sends it on to the service.

import Foundation
import Synchronization
import Containerization

/// Joins two connected sockets, both ways, on threads of their own; closes
/// both when either side ends.
enum Relay {
    static func join(_ a: Int32, _ b: Int32) {
        let open = Mutex(2)
        func pump(_ from: Int32, _ to: Int32) {
            let t = Thread {
                var buffer = [UInt8](repeating: 0, count: 1 << 18)
                while true {
                    let n = read(from, &buffer, buffer.count)
                    if n <= 0 { break }
                    var sent = 0
                    while sent < n {
                        let w = buffer.withUnsafeBytes { write(to, $0.baseAddress! + sent, n - sent) }
                        if w <= 0 { break }
                        sent += w
                    }
                    if sent < n { break }
                }
                shutdown(to, SHUT_WR)
                shutdown(from, SHUT_RD)
                if open.withLock({ $0 -= 1; return $0 == 0 }) {
                    close(a)
                    close(b)
                }
            }
            t.stackSize = 1 << 20
            t.start()
        }
        pump(a, b)
        pump(b, a)
    }
}

/// A port the app listens on for a service.
final class LivePort: @unchecked Sendable {
    let service: String
    let mapping: PortMapping
    let fd: Int32

    init(service: String, mapping: PortMapping, fd: Int32) {
        self.service = service
        self.mapping = mapping
        self.fd = fd
    }

    /// The vsock port the helper listens on for it.
    var vsockPort: UInt32 { 0x10000 + UInt32(mapping.host) }

    func close() {
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }
}

extension PodRunner {
    /// The host ports the VM forwards since it booted, by service.
    func recordBootPorts(_ spec: PodSpec) {
        bootPorts = spec.services.reduce(into: [:]) { d, s in d[s.name] = Set(s.ports.map(\.host)) }
    }

    /// Makes `service`'s ports reach the iPad without restarting the pod.
    /// False if that needs a restart: a port the VM forwards since it booted
    /// was taken away or changed, or the pod's services share one network.
    public func setPorts(_ service: ServiceSpec) async -> Bool {
        guard let spec = currentSpec, spec.usesSeparateNetworks, snapshot.pod == .running,
              let i = spec.services.firstIndex(where: { $0.name == service.name }) else { return false }
        let boot = bootPorts[service.name] ?? []
        let old = spec.services[i].ports.filter { boot.contains($0.host) }
        guard old.allSatisfy({ service.ports.contains($0) }) else { return false }
        var running = spec
        running.services[i].ports = service.ports
        currentSpec = running
        for (host, live) in livePorts where live.service == service.name && !service.ports.contains(live.mapping) {
            await unpublish(host)
        }
        guard snapshot.services[service.name] == .running else { return true }
        for m in service.ports where !boot.contains(m.host) && livePorts[m.host] == nil {
            await publish(m, of: service.name)
        }
        return true
    }

    /// Publishes the ports of a service that joined the running pod.
    func publishPorts(of service: ServiceSpec) async {
        for m in service.ports where livePorts[m.host] == nil {
            await publish(m, of: service.name)
        }
    }

    func publish(_ m: PortMapping, of name: String) async {
        guard let pod, let index = netIndex[name] else { return }
        if let owner = currentSpec?.services.first(where: { $0.name != name && $0.ports.contains { $0.host == m.host } }) {
            say(name, "port \(m.host) is \(owner.name)'s; not published")
            return
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(m.host.bigEndian)
        addr.sin_addr.s_addr = currentSpec?.reachableFromNetwork == true ? INADDR_ANY : inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard bound, listen(fd, 64) == 0 else {
            say(name, "port \(m.host) is in use on the iPad; not published")
            close(fd)
            return
        }
        let live = LivePort(service: name, mapping: m, fd: fd)
        let relay = "nohup socat VSOCK-LISTEN:\(live.vsockPort),reuseaddr,fork TCP:\(PodNetwork.address(index)):\(m.container) >/tmp/port-\(m.host).log 2>&1 < /dev/null & echo started"
        guard let (code, out) = try? await exec(["/bin/sh", "-c", relay], in: PodNetwork.helper), code == 0 else {
            say(name, "port \(m.host) not published: the network helper did not take it")
            live.close()
            return
        }
        _ = out
        livePorts[m.host] = live
        let vport = live.vsockPort
        let thread = Thread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break
                }
                var one: Int32 = 1
                setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                Task.detached {
                    do {
                        let handle = try await pod.withVirtualMachineInstance { try await $0.dial(vport) }
                        let guest = dup(handle.fileDescriptor)
                        try? handle.close()
                        guard guest >= 0 else { close(client); return }
                        Relay.join(client, guest)
                    } catch {
                        close(client)
                    }
                }
            }
        }
        thread.name = "pier.port.\(m.host)"
        thread.start()
        say(name, "port \(m.host) → \(m.container) published")
    }

    func unpublish(_ host: UInt16) async {
        guard let live = livePorts.removeValue(forKey: host) else { return }
        live.close()
        _ = try? await exec(["/bin/sh", "-c", "pkill -f '[V]SOCK-LISTEN:\(live.vsockPort),' ; true"], in: PodNetwork.helper)
    }

    func unpublishAll(of name: String) async {
        for (host, live) in livePorts where live.service == name { await unpublish(host) }
    }

    func closeLivePorts() {
        livePorts.values.forEach { $0.close() }
        livePorts = [:]
    }
}
