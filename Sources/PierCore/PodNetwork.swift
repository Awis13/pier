import Foundation

/// A network like Docker's bridge inside the pod's virtual machine: every
/// service in a network namespace of its own with an address on `br0`, the
/// helper `pier-net` (in the VM's own network and PID namespaces) wiring them
/// up, masquerading their traffic out of eth0 and sending the ports forwarded
/// from the iPad on to the service they belong to.
struct PodNetwork {
    static let helper = "pier-net"
    static let helperImage = "docker.io/library/alpine:3.20"
    static let subnet = "172.20.0"
    static let gateway = "\(subnet).1"

    /// Each service's address, in the order of the spec.
    let addresses: [String: String]

    init(services: [ServiceSpec]) {
        var a: [String: String] = [:]
        for (i, s) in services.enumerated() { a[s.name] = "\(Self.subnet).\(10 + i)" }
        addresses = a
    }

    /// The helper's command: the tools it needs, then waiting.
    static let helperCommand = [
        "/bin/sh", "-c",
        "apk add --no-cache iproute2 iptables iptables-legacy util-linux-misc >/tmp/apk.log 2>&1; touch /tmp/pier-net-ready; exec sleep infinity",
    ]

    /// iptables for the kernel's legacy tables (the VM's kernel has no nftables).
    static let iptables = "IPT=iptables; command -v iptables-legacy >/dev/null 2>&1 && IPT=iptables-legacy"

    /// Waits for the helper's tools.
    static let waitReady = "for i in $(seq 600); do [ -f /tmp/pier-net-ready ] && command -v nsenter >/dev/null && exit 0; sleep 0.5; done; cat /tmp/apk.log; exit 1"

    /// The bridge and masquerading, once per boot.
    static var bridge: String {
        """
        set -e
        \(iptables)
        ip link add br0 type bridge 2>/dev/null || true
        ip addr add \(gateway)/24 dev br0 2>/dev/null || true
        ip link set br0 up
        echo 1 > /proc/sys/net/ipv4/ip_forward
        $IPT -t nat -C POSTROUTING -s \(subnet).0/24 ! -o br0 -j MASQUERADE 2>/dev/null || $IPT -t nat -A POSTROUTING -s \(subnet).0/24 ! -o br0 -j MASQUERADE
        echo bridge br0 \(gateway)/24 up
        """
    }

    /// A veth from the bridge into the network namespace of process `pid`,
    /// as that container's eth0 at `address`.
    static func wire(pid: Int32, index: Int, address: String) -> String {
        let host = "pv\(index)", peer = "pp\(index)"
        return """
        set -e
        ip link del \(host) 2>/dev/null || true
        ip link add \(host) type veth peer name \(peer)
        ip link set \(host) master br0 up
        ip link set \(peer) netns \(pid)
        nsenter -t \(pid) -n ip link set \(peer) name eth0
        nsenter -t \(pid) -n ip addr add \(address)/24 dev eth0
        nsenter -t \(pid) -n ip link set lo up
        nsenter -t \(pid) -n ip link set eth0 up
        nsenter -t \(pid) -n ip route add default via \(gateway)
        echo eth0 \(address)
        """
    }

    /// `arguments` run inside the container whose init is `pid`: its mount,
    /// UTS, IPC, network, PID and cgroup namespaces, its root and working
    /// directory, a plain environment — and its cgroup, so the service's
    /// memory limit applies, not the helper's small one. The helper sees only
    /// its own cgroup, so the whole tree is mounted once from the VM's.
    static func enter(pid: Int32, _ arguments: [String]) -> [String] {
        let join = """
            [ -f /run/pier-cg/cgroup.procs ] || { mkdir -p /run/pier-cg && nsenter -t 1 -C mount -t cgroup2 none /run/pier-cg; } 2>/dev/null
            cg=$(nsenter -t 1 -C cat /proc/\(pid)/cgroup 2>/dev/null | sed -n 's/^0:://p')
            [ -n "$cg" ] && echo $$ > "/run/pier-cg$cg/cgroup.procs" 2>/dev/null
            exec "$@"
            """
        return ["/bin/sh", "-c", join, "pier-enter",
         "nsenter", "-t", String(pid), "-m", "-u", "-i", "-n", "-p", "-C", "-r", "-w", "--",
         "/usr/bin/env", "-i",
         "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
         "HOME=/root", "TERM=xterm-256color", "COLORTERM=truecolor", "LANG=C.UTF-8",
         // apt asks nothing and takes the defaults, as in Docker images; dpkg-reconfigure still asks.
         "DEBIAN_FRONTEND=noninteractive"] + arguments
    }

    /// Connections to `port` on the VM (forwarded there from the iPad) go
    /// on to `address:target`.
    static func forward(port: UInt16, to address: String, target: UInt16) -> String {
        """
        \(iptables)
        $IPT -t nat -A PREROUTING -i eth0 -p tcp --dport \(port) -j DNAT --to-destination \(address):\(target)
        $IPT -t nat -A OUTPUT -o lo -p tcp --dport \(port) -j DNAT --to-destination \(address):\(target) 2>/dev/null || true
        echo port \(port) to \(address):\(target)
        """
    }
}

extension PodSpec {
    /// Each service's own address when services get networks of their own;
    /// empty when they share the VM's.
    public var serviceAddresses: [String: String] {
        usesSeparateNetworks ? PodNetwork(services: services).addresses : [:]
    }
}
