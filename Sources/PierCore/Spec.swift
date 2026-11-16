import Foundation

/// A port on the iPad (or Mac) forwarded to a port of the pod.
public struct PortMapping: Codable, Hashable, Sendable {
    public var host: UInt16
    public var container: UInt16

    public init(host: UInt16, container: UInt16) {
        self.host = host
        self.container = container
    }

    /// "8080:80", or "80" for the same port on both sides.
    public init?(_ text: String) {
        let parts = text.split(separator: ":").map { UInt16($0.trimmingCharacters(in: .whitespaces)) }
        switch parts.count {
        case 1:
            guard let p = parts[0] else { return nil }
            self.init(host: p, container: p)
        case 2:
            guard let h = parts[0], let c = parts[1] else { return nil }
            self.init(host: h, container: c)
        default:
            return nil
        }
    }

    public var description: String { "\(host):\(container)" }
}

/// One container of the pod: an OCI image and how to run it.
public struct ServiceSpec: Codable, Hashable, Sendable, Identifiable {
    /// Also the container's ID and its host name inside the pod.
    public var name: String
    /// An image reference, e.g. `docker.io/library/postgres:17-alpine`.
    public var image: String
    /// Replaces the image's entrypoint and command when not empty.
    public var command: [String]
    /// `KEY=value`, added to the image's environment.
    public var environment: [String]
    public var ports: [PortMapping]
    /// Memory the container may use, in MiB.
    public var memoryMiB: UInt64
    /// Whether the shared work volume is mounted at /work.
    public var mountsWork: Bool
    /// Where Pier's own sshd in this service listens, inside the pod and on
    /// the iPad alike, once SSH was installed (user root, password pier).
    public var sshPort: UInt16?

    // From Docker Compose; unset for services made in Pier.

    /// Replaces the image's entrypoint (and drops its command), as Compose's
    /// `entrypoint`.
    public var entrypoint: [String]?
    /// Replaces the image's command but keeps its entrypoint, as Compose's
    /// `command`.
    public var args: [String]?
    public var workingDir: String?
    /// `name`, `uid` or `uid:gid`.
    public var user: String?
    /// Every capability, as Compose's `privileged`.
    public var privileged: Bool?
    /// Parts of /work bound into the service.
    public var volumes: [VolumeMount]?
    public var restart: RestartPolicy?
    public var dependsOn: [Dependency]?
    public var healthcheck: Healthcheck?
    /// More host names for the service inside the pod.
    public var aliases: [String]?
    /// Stopped by hand: the pod starts without it until it is started again.
    public var stoppedByUser: Bool?
    /// nmap's host discovery uses probes that get through the VM's NAT
    /// honestly (see `PodRunner.nmapWrapper`).
    public var honestScanning: Bool?
    /// Shell commands run in the background each time the service starts:
    /// daemons a container has no init to start (sshd, tailscaled, ...).
    public var startup: [String]?

    public var id: String { name }

    public init(
        name: String,
        image: String,
        command: [String] = [],
        environment: [String] = [],
        ports: [PortMapping] = [],
        memoryMiB: UInt64 = 512,
        mountsWork: Bool = true
    ) {
        self.name = name
        self.image = image
        self.command = command
        self.environment = environment
        self.ports = ports
        self.memoryMiB = memoryMiB
        self.mountsWork = mountsWork
    }

    /// The image as Docker reads it: a registry (docker.io unless one is
    /// named), `library/` for official images, and `:latest` without a tag.
    public static func normalizedImage(_ text: String) -> String {
        var ref = text.trimmingCharacters(in: .whitespaces)
        var parts = ref.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let first = parts.first ?? ""
        let hasRegistry = parts.count > 1 && (first.contains(".") || first.contains(":") || first == "localhost")
        if !hasRegistry {
            if parts.count == 1 { parts.insert("library", at: 0) }
            parts.insert("docker.io", at: 0)
        }
        ref = parts.joined(separator: "/")
        let last = parts.last ?? ""
        if !last.contains(":") && !last.contains("@") {
            ref += ":latest"
        }
        return ref
    }

    /// Container IDs and host names: lowercase letters, digits and dashes.
    public static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 63
            && name.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
            && name.first != "-"
    }
}

/// A directory or file of the shared /work volume bound into a service.
public struct VolumeMount: Codable, Hashable, Sendable {
    /// Path within /work, e.g. `.pier/volumes/app-db` or
    /// `.pier/projects/app/nginx.conf`.
    public var source: String
    /// Where the service sees it.
    public var target: String
    public var readOnly: Bool
    /// Files Pier keeps for it (under its data directory, `projects/...`),
    /// written into /work each time the pod starts; nil for a volume that
    /// only keeps what the service writes.
    public var files: String?

    public init(source: String, target: String, readOnly: Bool = false, files: String? = nil) {
        self.source = source
        self.target = target
        self.readOnly = readOnly
        self.files = files
    }
}

public enum RestartPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    case no, always, onFailure = "on-failure", unlessStopped = "unless-stopped"
}

public struct Dependency: Codable, Hashable, Sendable {
    public enum Condition: String, Codable, Hashable, Sendable {
        case started = "service_started"
        case healthy = "service_healthy"
        case completed = "service_completed_successfully"
    }
    public var service: String
    public var condition: Condition

    public init(service: String, condition: Condition = .started) {
        self.service = service
        self.condition = condition
    }
}

public struct Healthcheck: Codable, Hashable, Sendable {
    /// Run as is (Compose's `CMD`), or by `/bin/sh -c` when `shell`.
    public var test: [String]
    public var shell: Bool
    public var intervalSeconds: Double
    public var timeoutSeconds: Double
    public var retries: Int
    public var startPeriodSeconds: Double

    public init(test: [String], shell: Bool, intervalSeconds: Double = 30, timeoutSeconds: Double = 30, retries: Int = 3, startPeriodSeconds: Double = 0) {
        self.test = test
        self.shell = shell
        self.intervalSeconds = intervalSeconds
        self.timeoutSeconds = timeoutSeconds
        self.retries = retries
        self.startPeriodSeconds = startPeriodSeconds
    }

    public var arguments: [String] { shell ? ["/bin/sh", "-c", test.joined(separator: " ")] : test }
}

/// Everything the pod runs: one virtual machine, its services side by side on
/// one network, and a volume they share.
public struct PodSpec: Codable, Hashable, Sendable {
    public var services: [ServiceSpec]
    public var cpus: Int
    /// The virtual machine's memory, in MiB.
    public var memoryMiB: UInt64
    /// Forwarded ports listen on every interface, not only on 127.0.0.1.
    public var reachableFromNetwork: Bool
    /// Size of the shared volume mounted at /work, in GiB (sparse).
    public var workVolumeGiB: UInt64
    /// Each service on a network of its own with an address, as Docker
    /// does; off, they all share the VM's. Unset means on.
    public var separateNetworks: Bool?
    public var usesSeparateNetworks: Bool { separateNetworks ?? true }

    public init(
        services: [ServiceSpec] = [],
        cpus: Int = 4,
        memoryMiB: UInt64 = 3072,
        reachableFromNetwork: Bool = false,
        workVolumeGiB: UInt64 = 16
    ) {
        self.services = services
        self.cpus = cpus
        self.memoryMiB = memoryMiB
        self.reachableFromNetwork = reachableFromNetwork
        self.workVolumeGiB = workVolumeGiB
    }

    /// Every host port the pod forwards.
    public var hostPorts: Set<UInt16> {
        Set(services.flatMap { s in s.ports.map(\.host) + (s.sshPort.map { [$0] } ?? []) })
    }

    /// The first free port from 2222 up, for a new sshd.
    public func freeSSHPort(avoiding inside: Set<UInt16> = []) -> UInt16 {
        let used = hostPorts.union(services.flatMap { $0.ports.map(\.container) }).union(inside)
        var p: UInt16 = 2222
        while used.contains(p) { p += 1 }
        return p
    }

    public func validate() throws {
        var names = Set<String>()
        var hostPorts = Set<UInt16>()
        for s in services {
            guard ServiceSpec.isValidName(s.name) else {
                throw PierError("\"\(s.name)\" is not a valid name: use lowercase letters, digits and dashes")
            }
            guard names.insert(s.name).inserted else {
                throw PierError("two services are called \(s.name)")
            }
            for d in s.dependsOn ?? [] where !services.contains(where: { $0.name == d.service }) {
                throw PierError("\(s.name) depends on \(d.service), which is not in the pod")
            }
            for p in s.ports + (s.sshPort.map { [PortMapping(host: $0, container: $0)] } ?? []) {
                guard hostPorts.insert(p.host).inserted else {
                    throw PierError("host port \(p.host) is forwarded twice")
                }
            }
        }
    }
}

public struct PierError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}
