import Containerization
import ContainerizationEXT4
import ContainerizationExtras
import ContainerizationOCI
import CryptoKit
import Foundation
import Logging
import Synchronization
import SystemPackage

/// Where a service is.
public enum ServiceState: Sendable, Equatable {
    case stopped
    case preparing(String)
    case starting
    case running
    case exited(Int32)
    case failed(String)

    public var label: String {
        switch self {
        case .stopped: "Stopped"
        case .preparing(let what): what
        case .starting: "Starting"
        case .running: "Running"
        case .exited(let code): "Exited (\(code))"
        case .failed(let why): "Failed: \(why)"
        }
    }

    public var isActive: Bool {
        switch self {
        case .preparing, .starting, .running: true
        default: false
        }
    }
}

public enum PodState: Sendable, Equatable {
    case stopped
    case preparing(String)
    case booting
    case running
    case stopping
    case failed(String)

    public var label: String {
        switch self {
        case .stopped: "Stopped"
        case .preparing(let what): what
        case .booting: "Booting"
        case .running: "Running"
        case .stopping: "Stopping"
        case .failed(let why): "Failed: \(why)"
        }
    }

    public var isActive: Bool {
        switch self {
        case .preparing, .booting, .running, .stopping: true
        default: false
        }
    }
}

public struct PodSnapshot: Sendable, Equatable {
    public var pod: PodState = .stopped
    public var services: [String: ServiceState] = [:]
    /// When the virtual machine came up, for "booted in".
    public var bootSeconds: Double?
    /// Containers agents started through the Agent API: name, then the
    /// service that asked and when it goes.
    public var spawned: [String: SpawnInfo] = [:]

    public init() {}
}

/// A container an agent started.
public struct SpawnInfo: Sendable, Equatable {
    public var owner: String
    public var image: String
    public var expires: Date?

    init?(_ s: ServiceSpec) {
        guard let owner = s.spawnedBy else { return nil }
        self.owner = owner
        image = s.image
        expires = s.expires
    }
}

/// The pod's services changed from inside: an agent started a container
/// or one was removed. The app keeps its saved spec in step.
public enum ServiceEvent: Sendable {
    case added(ServiceSpec)
    case removed(String)
}

/// How the pod's virtual machine runs its CPUs.
public enum PierBackend: Sendable {
    /// The Hypervisor framework when the process may use it, otherwise crate's translator.
    case auto
    /// crate's translator, in executable memory the app prepared (iOS).
    case jit(CrateJITRegion?)
}

extension PierBackend {
    /// The translator in a region the app prepared (see crate.h).
    public static func jit(executable: UnsafeMutableRawPointer, writable: UnsafeMutableRawPointer, size: Int) -> PierBackend {
        .jit(CrateJITRegion(executable: executable, writable: writable, size: size))
    }
}

/// Runs a ``PodSpec``: one crate virtual machine with every service in it.
public actor PodRunner {
    public nonisolated let root: URL
    private let kernel: URL
    private let initImage: String
    private let logger: Logger
    let store: ImageStore
    var imageStore: ImageStore { store }

    var pod: LinuxPod?
    /// Services on networks of their own, by name: their init's PID in the VM.
    private var pids: [String: Int32] = [:]
    /// The spec of the running pod, for restart policies.
    var currentSpec: PodSpec?
    /// Services added to the running pod (each in a disk slot); they go
    /// back into one when started again.
    var hotAdded: Set<String> = []
    /// Each service's place on the bridge (its address is .10 plus it),
    /// kept while the pod runs: one removed leaves a gap, not a shift.
    var netIndex: [String: Int] = [:]
    /// The next place on the bridge: only ever goes up while the pod runs,
    /// so an address is never given to a second service.
    var nextNetIndex = 0
    /// Names being added (pulled, unpacked) and not in the spec yet.
    var reservedNames: Set<String> = []
    /// The Agent API: tokens (to their service), what agents started and
    /// when each goes, and the listener on the VM's vsock.
    var agentTokens: [String: String] = [:]
    var spawnTimers: [String: Task<Void, Never>] = [:]
    var agentListener: VsockListener?
    /// The pod's hosts file and network kind, for services added later.
    private var bootHosts: Hosts?
    private var restarts: [String: Int] = [:]
    /// A boot is under way (the VM may not exist yet).
    private var booting = false
    /// Stop was asked for during a boot: it ends at its next step.
    private var cancelBoot = false
    /// Counts boots, so work scheduled for one pod run leaves the next alone.
    private var generation = 0
    /// Policy restarts waiting out their back-off.
    private var restartTasks: [String: Task<Void, Never>] = [:]
    /// Services being stopped on purpose: their exit is no crash.
    private var stopping: Set<String> = []
    private var watchers: [Task<Void, Never>] = []
    private nonisolated let logs = Mutex<[String: LogBuffer]>([:])
    private nonisolated let snapshotState = Mutex(PodSnapshot())
    private nonisolated let onChange: @Sendable (PodSnapshot) -> Void
    nonisolated let onServices: @Sendable (ServiceEvent) -> Void

    /// The pod's own log: preparing, booting, the guest's console.
    public nonisolated let podLog = LogBuffer(limit: 4000)
    /// Carries the guest's console into `podLog`; kept for the runner's life.
    private nonisolated let console: ConsolePipe

    public static let defaultInitImage = "ghcr.io/apple/containerization/vminit:0.54.0"
    static let podID = "pier"
    static let workVolume = "work"
    /// A service's root filesystem: room for big images and what they keep
    /// (models, packages); sparse, so the iPad gives only what is written.
    static let rootfsGiB: UInt64 = 32
    static let journal = EXT4.JournalConfig(defaultMode: .ordered)
    static let arm64 = ContainerizationOCI.Platform(arch: "arm64", os: "linux", variant: nil)

    public init(
        root: URL,
        kernel: URL,
        initImage: String = PodRunner.defaultInitImage,
        logger: Logger = Logger(label: "pier"),
        onChange: @escaping @Sendable (PodSnapshot) -> Void = { _ in },
        onServices: @escaping @Sendable (ServiceEvent) -> Void = { _ in }
    ) throws {
        self.onServices = onServices
        self.root = root
        self.kernel = kernel
        self.initImage = initImage
        self.logger = logger
        self.onChange = onChange
        self.console = ConsolePipe(podLog)
        // A closed socket or pipe is an error to handle, not a reason to die.
        signal(SIGPIPE, SIG_IGN)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.store = try ImageStore(path: root.appendingPathComponent("images"))
    }

    public nonisolated var snapshot: PodSnapshot { snapshotState.withLock { $0 } }

    public nonisolated func log(for service: String) -> LogBuffer {
        logs.withLock { all in
            if let l = all[service] { return l }
            let l = LogBuffer()
            all[service] = l
            return l
        }
    }

    nonisolated func update(_ body: (inout PodSnapshot) -> Void) {
        let s = snapshotState.withLock { s in
            body(&s)
            return s
        }
        onChange(s)
    }

    private nonisolated func setPod(_ state: PodState) {
        update { $0.pod = state }
        podLog.note("pod: \(state.label)")
    }

    nonisolated func setService(_ name: String, _ state: ServiceState) {
        update { $0.services[name] = state }
    }

    // MARK: - Files

    private var initfsPath: URL { root.appendingPathComponent("initfs.ext4") }
    private var workPath: URL { root.appendingPathComponent("work.ext4") }

    func serviceDir(_ name: String) -> URL {
        root.appendingPathComponent("services").appendingPathComponent(name)
    }

    /// The guest agent's root filesystem: Apple's vminit image, with Pier's
    /// own vmexec over it when the package carries one (it puts containers
    /// in network namespaces of their own, which Apple's leaves out).
    private func initfs() async throws -> Containerization.Mount {
        let path = initfsPath
        // Empty until a build of Pier's vmexec is put there.
        let overlay = Bundle.module.url(forResource: "vmexec-overlay", withExtension: "tar.gz")
            .flatMap { ((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 0 ? $0 : nil }
        let stampURL = root.appendingPathComponent("initfs.stamp")
        var stamp = initImage
        if let overlay, let digest = Self.sha256(of: overlay) {
            stamp += " overlay \(digest)"
        }
        let current = try? String(contentsOf: stampURL, encoding: .utf8)
        if FileManager.default.fileExists(atPath: path.path), current == stamp {
            return .block(format: "ext4", source: path.path, destination: "/", options: ["ro"])
        }
        try? FileManager.default.removeItem(at: path)
        setPod(.preparing("Fetching the guest agent"))
        podLog.note("pod: pulling the guest agent \(initImage)")
        if (try? await store.get(reference: initImage, pull: false)) == nil {
            let meter = Meter(label: "downloaded", unit: .bytes) { [weak self] line in
                self?.podLog.note("agent: \(line)")
                self?.setPod(.preparing("Agent: \(line)"))
            }
            _ = try await store.pull(reference: initImage, platform: Self.arm64, progress: meter.handler)
        }
        podLog.note("pod: writing the guest agent's filesystem")
        if let overlay {
            let base = try await store.get(reference: initImage)
            let manifest = try await base.manifest(for: Self.arm64)
            let fs = try EXT4.Formatter(FilePath(path.path), minDiskSize: 512.mib())
            for layer in manifest.layers {
                let content = try await base.getContent(digest: layer.digest)
                try await fs.unpack(source: content.path, compression: .gzip)
            }
            try await fs.unpack(source: overlay, compression: .gzip)
            try fs.close()
            podLog.note("pod: guest agent with Pier's vmexec (network namespaces)")
        } else {
            _ = try await store.getInitImage(reference: initImage).initBlock(at: path, for: .linuxArm)
        }
        try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
        return .block(format: "ext4", source: path.path, destination: "/", options: ["ro"])
    }

    private func workVolume(sizeGiB: UInt64) throws -> URL {
        let path = workPath
        if !FileManager.default.fileExists(atPath: path.path) {
            podLog.note("creating the shared /work volume (\(sizeGiB) GiB, sparse)")
            let fs = try EXT4.Formatter(FilePath(path.path), minDiskSize: sizeGiB.gib(), journal: Self.journal)
            try fs.close()
        }
        return path
    }

    /// Says something about a service in its own log and in the pod's.
    nonisolated func say(_ service: String, _ text: String) {
        log(for: service).note(text)
        podLog.note("\(service): \(text)")
    }

    /// The service's root filesystem: unpacked from its image once, kept
    /// between runs, made again when the image changes.
    private func rootfs(for service: ServiceSpec) async throws -> (Containerization.Mount, ImageConfig?) {
        let dir = serviceDir(service.name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("rootfs.ext4")
        let stamp = dir.appendingPathComponent("image")
        let reference = ServiceSpec.normalizedImage(service.image)
        let name = service.name

        setService(name, .preparing("Pulling"))
        let image: Containerization.Image
        if let local = try? await store.get(reference: reference, pull: false) {
            say(name, "image \(reference) is here already (\(local.digest.prefix(19)))")
            image = local
        } else {
            say(name, "pulling \(reference) for linux/arm64")
            let meter = Meter(label: "downloaded", unit: .bytes) { [weak self] line in
                self?.say(name, line)
                self?.setService(name, .preparing(line))
            }
            let started = ContinuousClock.now
            image = try await store.pull(reference: reference, platform: Self.arm64, progress: meter.handler)
            say(name, "pulled \(reference) in \(Meter.seconds(ContinuousClock.now - started)): \(meter.summary)")
            say(name, "digest \(image.digest)")
        }
        let digest = image.digest
        let config = try await image.config(for: Self.arm64).config
        if let c = config {
            let cmd = ((c.entrypoint ?? []) + (c.cmd ?? [])).joined(separator: " ")
            if !cmd.isEmpty { say(name, "image command: \(cmd)") }
            if let wd = c.workingDir, !wd.isEmpty { say(name, "working directory: \(wd)") }
        }

        let previous = try? String(contentsOf: stamp, encoding: .utf8)
        if previous != digest || !FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.removeItem(at: path)
            setService(name, .preparing("Unpacking"))
            let manifest = try await image.manifest(for: Self.arm64)
            say(name, "unpacking \(manifest.layers.count) layers into an ext4 root filesystem (\(Self.rootfsGiB) GB, sparse)")
            let meter = Meter(label: "unpacked", unit: .bytes) { [weak self] line in
                self?.say(name, line)
                self?.setService(name, .preparing(line))
            }
            let started = ContinuousClock.now
            // Journalled (ordered, as Linux mounts ext4 by default): a pod that
            // stops without unmounting, when iOS ends Pier say, keeps a
            // consistent filesystem instead of blocks given to two files.
            let unpacker = EXT4Unpacker(capacityInBytes: Self.rootfsGiB.gib(), journal: Self.journal)
            _ = try await unpacker.unpack(image, for: Self.arm64, at: path, progress: meter.handler)
            try digest.write(to: stamp, atomically: true, encoding: .utf8)
            say(name, "unpacked in \(Meter.seconds(ContinuousClock.now - started)): \(meter.summary)")
        } else {
            say(name, "root filesystem is ready from an earlier run")
        }
        return (.block(format: "ext4", source: path.path, destination: "/", options: []), config)
    }

    /// Throws the service's root filesystem away, so the next start unpacks
    /// its image again.
    public func reset(service name: String) throws {
        guard pod == nil else { throw PierError("stop the pod first") }
        try? FileManager.default.removeItem(at: serviceDir(name))
        log(for: name).clear()
        setService(name, .stopped)
    }

    // MARK: - Running

    public var isRunning: Bool { pod != nil }

    var currentPod: LinuxPod? { pod }

    public func start(_ spec: PodSpec, backend: PierBackend) async throws {
        guard pod == nil, !booting else { throw PierError("the pod is already running") }
        booting = true
        cancelBoot = false
        generation += 1
        defer { booting = false }
        do {
            try spec.validate()
            guard !spec.services.isEmpty else { throw PierError("add a service first") }
            currentSpec = spec
            restarts = [:]
            try await boot(spec, backend: backend)
        } catch {
            let cancelled = cancelBoot
            if let pod {
                try? await pod.stop()
                self.pod = nil
            }
            pids = [:]
            watchers.forEach { $0.cancel() }
            watchers.removeAll()
            if cancelled {
                update { s in for k in s.services.keys where s.services[k]?.isActive == true { s.services[k] = .stopped } }
                setPod(.stopped)
                throw CancellationError()
            }
            setPod(.failed(String(describing: error)))
            for s in spec.services where snapshot.services[s.name]?.isActive == true {
                setService(s.name, .failed("the pod did not start"))
            }
            throw error
        }
    }

    /// Ends a boot that was asked to stop.
    private func checkCancelled() throws {
        if cancelBoot { throw CancellationError() }
    }

    private func boot(_ spec: PodSpec, backend: PierBackend) async throws {
        update { $0.bootSeconds = nil }
        pids = [:]
        setPod(.preparing("Preparing"))
        podLog.note("pod: \(spec.services.count) services, \(spec.cpus) CPUs, \(spec.memoryMiB) MB, /work \(spec.workVolumeGiB) GB")
        let initfs = try await initfs()
        let work = try workVolume(sizeGiB: spec.workVolumeGiB)

        var prepared: [(ServiceSpec, Containerization.Mount, ImageConfig?)] = []
        for service in spec.services {
            setPod(.preparing("Preparing \(service.name)"))
            try checkCancelled()
            let (rootfs, config) = try await rootfs(for: service)
            // A full disk fails the whole VM as it boots: that service waits.
            if let space = Self.ext4Space(of: URL(fileURLWithPath: rootfs.source)), space.free < 64 << 20 {
                let why = "its disk is full (\(space.total >> 30) GB): Reset Disk in its menu makes it again from the image"
                setService(service.name, .failed(why))
                say(service.name, "not started: \(why)")
                continue
            }
            prepared.append((service, rootfs, config))
            setService(service.name, .starting)
        }

        let bind = spec.reachableFromNetwork ? "" : "127.0.0.1"
        let separate = spec.usesSeparateNetworks
        let network = PodNetwork(services: spec.services)
        netIndex = spec.services.enumerated().reduce(into: [:]) { $0[$1.element.name] = $1.offset }
        nextNetIndex = spec.services.count
        update { s in
            s.spawned = spec.services.reduce(into: [:]) { d, svc in d[svc.name] = SpawnInfo(svc) }
        }
        // With networks of their own, the VM takes each port at the same
        // number and the helper sends it on to its service.
        let forwards = spec.services.flatMap { s in
            (s.ports + (s.sshPort.map { [PortMapping(host: $0, container: $0)] } ?? [])).map {
                CratePortForward(hostAddress: bind, hostPort: $0.host, guestPort: separate ? $0.host : $0.container)
            }
        }
        var helperRootfs: Containerization.Mount?
        if separate {
            setPod(.preparing("Preparing the network"))
            helperRootfs = try await rootfs(for: ServiceSpec(name: PodNetwork.helper, image: PodNetwork.helperImage)).0
            update { $0.services[PodNetwork.helper] = nil }
        }
        var kernelCmdline = Kernel.CommandLine(debug: false, panic: 0)
        kernelCmdline.kernelArgs.append("quiet")
        let cpuBackend: CrateVirtualMachineInstance.CPUBackend
        let region: CrateJITRegion?
        switch backend {
        case .auto:
            cpuBackend = .auto
            region = nil
        case .jit(let r):
            cpuBackend = .jit
            region = r
        }
        let vmm = CrateVirtualMachineManager(
            kernel: Kernel(path: kernel, platform: .linuxArm, commandline: kernelCmdline),
            initialFilesystem: initfs,
            backend: cpuBackend,
            jitRegion: region,
            portForwards: forwards,
            diskSlots: spec.slots,
            logger: logger
        )

        let hosts: Hosts
        if separate {
            hosts = Hosts(entries: [Hosts.Entry(ipAddress: "127.0.0.1", hostnames: ["localhost"])]
                + spec.services.map { Hosts.Entry(ipAddress: network.addresses[$0.name]!, hostnames: [$0.name] + ($0.aliases ?? [])) })
        } else {
            hosts = Hosts(entries: [
                Hosts.Entry(ipAddress: "127.0.0.1", hostnames: ["localhost"] + spec.services.flatMap { [$0.name] + ($0.aliases ?? []) })
            ])
        }
        let interface = try CrateNetwork.interface()
        let consoleHandle = console.handle
        let pod = try LinuxPod(
            Self.podID,
            vmm: vmm,
            vm: VMResources(cpus: spec.cpus, memoryInBytes: spec.memoryMiB.mib()),
            logger: logger
        ) { config in
            config.interfaces = [interface]
            config.dns = DNS(nameservers: [CrateNetwork.nameserver])
            config.hosts = hosts
            config.hostname = Self.podID
            config.bootLog = .fileHandle(consoleHandle)
            config.volumes = [
                LinuxPod.PodVolume(
                    name: Self.workVolume,
                    source: .diskImage(path: work),
                    format: "ext4"
                )
            ]
        }

        if let helperRootfs {
            let out = podLog
            try await pod.addContainer(PodNetwork.helper, rootfs: helperRootfs) { c in
                c.process.arguments = PodNetwork.helperCommand
                c.process.capabilities = .allCapabilities
                c.process.stdout = out
                c.process.stderr = out
                c.network = .shared
                c.hostPID = true
                c.maskedPaths = []
                c.readonlyPaths = []
                c.memoryInBytes = 128.mib()
                c.dns = DNS(nameservers: [CrateNetwork.nameserver])
            }
        }
        for (service, rootfs, imageConfig) in prepared {
            let out = log(for: service.name)
            let cpus = spec.cpus
            try await pod.addContainer(service.name, rootfs: rootfs) { c in
                Self.configure(&c, service, imageConfig, out: out, cpus: cpus, hosts: hosts, separate: separate)
            }
        }

        self.pod = pod
        bootHosts = hosts
        hotAdded = []
        let engine: String
        switch backend {
        case .auto: engine = "Hypervisor.framework when allowed, otherwise crate's JIT"
        case .jit(let r): engine = r == nil ? "crate's JIT" : "crate's JIT, \((r!.size) >> 20) MB for code"
        }
        podLog.note("booting the virtual machine: \(spec.cpus) CPUs, \(spec.memoryMiB) MB, \(engine)")
        for f in forwards {
            podLog.note("port \(f.hostAddress?.isEmpty == false ? f.hostAddress! : "0.0.0.0"):\(f.hostPort) -> \(f.guestPort)")
        }
        try checkCancelled()
        setPod(.booting)
        let started = ContinuousClock.now
        try await pod.create()
        let booted = (ContinuousClock.now - started)
        update { $0.bootSeconds = Double(booted.components.seconds) + Double(booted.components.attoseconds) / 1e18 }
        podLog.note("virtual machine up in \(booted)")
        try await prepareVolumes(spec, in: pod)
        if spec.services.contains(where: { $0.gpu == true }) { await startGPU(in: pod) }

        if separate {
            try await pod.startContainer(PodNetwork.helper)
            podLog.note("network: waiting for the helper's tools")
            let (ready, readyOut) = try await exec(["/bin/sh", "-c", PodNetwork.waitReady], in: PodNetwork.helper)
            guard ready == 0 else { throw PierError("the network helper has no tools:\n\(readyOut.suffix(800))") }
            let (code, out) = try await exec(["/bin/sh", "-c", PodNetwork.bridge], in: PodNetwork.helper)
            podLog.note("network: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            guard code == 0 else { throw PierError("could not set up the network:\n\(out.suffix(800))") }
            await startAgentAPI(in: pod)
        }
        for (index, (service, _, _)) in prepared.enumerated() {
            try checkCancelled()
            if service.stoppedByUser == true {
                setService(service.name, .stopped)
                say(service.name, "left stopped, as it was stopped by hand")
                continue
            }
            do {
                if let reason = await waitForDependencies(of: service, in: spec) {
                    setService(service.name, .failed(reason))
                    say(service.name, "not started: \(reason)")
                    continue
                }
                say(service.name, "starting")
                try await pod.startContainer(service.name)
                try await settle(service, index: index, address: separate ? network.addresses[service.name] : nil, in: pod)
            } catch {
                setService(service.name, .failed(String(describing: error)))
                log(for: service.name).note("failed to start: \(error)")
            }
        }
        try checkCancelled()
        setPod(.running)
    }

    /// A started service: watched, given its network and ports (with
    /// networks of their own), then its startup steps.
    private func settle(_ service: ServiceSpec, index: Int, address: String?, in pod: LinuxPod) async throws {
        // Watched from the start, so a process that ends at once shows its exit.
        watch(service.name, in: pod)
        if let address {
            guard let pid = await pod.containerPID(service.name) else { throw PierError("no PID for \(service.name)") }
            pids[service.name] = pid
            let (code, out) = try await exec(["/bin/sh", "-c", PodNetwork.wire(pid: pid, index: index, address: address)], in: PodNetwork.helper)
            guard code == 0 else {
                try? await Task.sleep(for: .milliseconds(300))
                if case .exited = snapshot.services[service.name] { return }
                throw PierError("could not give \(service.name) its network:\n\(out.suffix(600))")
            }
            say(service.name, "network: \(address) on br0")
            for p in service.ports + (service.sshPort.map { [PortMapping(host: $0, container: $0)] } ?? []) {
                let (c2, o2) = try await exec(["/bin/sh", "-c", PodNetwork.forward(port: p.host, to: address, target: p.container)], in: PodNetwork.helper)
                if c2 != 0 { say(service.name, "port \(p.host): \(o2)") }
            }
        }
        if case .exited = snapshot.services[service.name] { return }
        say(service.name, "running")
        setService(service.name, .running)
        await useHTTPSRepositories(in: service.name)
        await applyScanning(service)
        await runStartup(service)
        await installAgentAccess(service)
        if let port = service.sshPort {
            let result = try? await exec(["/bin/sh", "-c", Self.startSSH(port)], in: service.name)
            if let (code, _) = result, code == 0 {
                say(service.name, "sshd on port \(port) (root / pier)")
            } else {
                say(service.name, "sshd did not start: \(result?.1 ?? "")")
            }
        }
    }

    /// How a service's container is set up, at boot or added later.
    private static func configure(
        _ c: inout LinuxPod.ContainerConfiguration, _ service: ServiceSpec, _ imageConfig: ImageConfig?,
        out: LogBuffer, cpus: Int, hosts: Hosts, separate: Bool
    ) {
        if let imageConfig {
            c.process = LinuxProcessConfiguration(from: imageConfig)
        }
        if !service.command.isEmpty {
            c.process.arguments = service.command
        } else if service.entrypoint != nil || service.args != nil {
            // Compose: a new entrypoint drops the image's command.
            let entry = service.entrypoint ?? imageConfig?.entrypoint ?? []
            let args = service.args ?? (service.entrypoint == nil ? imageConfig?.cmd ?? [] : [])
            c.process.arguments = entry + args
        }
        if let wd = service.workingDir { c.process.workingDirectory = wd }
        if let u = service.user { c.process.user = ContainerizationOCI.User(username: u) }
        if service.privileged == true { c.process.capabilities = .allCapabilities }
        for v in service.volumes ?? [] {
            c.mounts.append(.sharedMount(name: Self.workVolume, destination: v.target, options: v.readOnly ? ["ro"] : [], subpath: v.source))
        }
        c.process.environmentVariables.append(contentsOf: service.environment)
        c.process.stdout = out
        c.process.stderr = out
        c.cpus = cpus
        c.memoryInBytes = service.memoryMiB.mib()
        c.hostname = service.name
        c.hosts = hosts
        if separate { c.network = .isolated }
        c.dns = DNS(nameservers: [CrateNetwork.nameserver])
        if service.mountsWork {
            c.mounts.append(.sharedMount(name: Self.workVolume, destination: "/work"))
        }
        if service.gpu == true {
            c.mounts.append(.sharedMount(name: Self.workVolume, destination: GPUShim.directory, options: ["ro"], subpath: GPUShim.volumePath))
            c.process.environmentVariables.append(contentsOf: [
                "GGML_BACKEND_PATH=\(GPUShim.directory)/libggml-rpc.so",
                "PIER_GPU=\(GPUServer.endpoint)",
            ])
        }
    }

    /// Adds a service to the running pod without restarting it: its rootfs
    /// goes into one of the VM's free disk slots. It gets the next address;
    /// its ports reach the other services, not the iPad, until the pod
    /// starts again (the VM's port forwards are set when it boots).
    public func addService(_ service: ServiceSpec) async throws {
        guard let pod, let spec = currentSpec, snapshot.pod == .running else {
            throw PierError("the pod is not running")
        }
        let name = service.name
        guard !spec.services.contains(where: { $0.name == name }), !reservedNames.contains(name) else {
            throw PierError("\(name) is already in the pod")
        }
        // Held until the service is in the spec, so a second request for the
        // same name fails at once instead of unpacking into the same disk.
        reservedNames.insert(name)
        defer { reservedNames.remove(name) }
        let run = generation
        setService(name, .starting)
        say(name, "adding to the running pod")
        let (rootfs, imageConfig) = try await rootfs(for: service)
        // The pod may have stopped or changed while the image came.
        guard generation == run, self.pod === pod, var running = currentSpec else {
            throw PierError("the pod stopped while \(name) was being prepared")
        }
        running.services.append(service)
        currentSpec = running
        hotAdded.insert(name)
        let index = nextNetIndex
        nextNetIndex += 1
        netIndex[name] = index
        do {
            try await attach(service, rootfs, imageConfig, index: index, in: pod, spec: running)
        } catch {
            setService(name, .failed(String(describing: error)))
            say(name, "failed to start: \(error)")
            throw error
        }
        // The others learn its name.
        if running.usesSeparateNetworks {
            let line = ([PodNetwork.address(index), name] + (service.aliases ?? [])).joined(separator: " ")
            for other in currentSpec?.services ?? [] where other.name != name && snapshot.services[other.name] == .running {
                _ = try? await exec(["/bin/sh", "-c", "echo '\(line)' >> /etc/hosts"], in: other.name)
            }
        }
    }

    /// Puts an added service's container into the pod and starts it.
    private func attach(
        _ service: ServiceSpec, _ rootfs: Containerization.Mount, _ imageConfig: ImageConfig?,
        index: Int, in pod: LinuxPod, spec: PodSpec
    ) async throws {
        let out = log(for: service.name)
        let separate = spec.usesSeparateNetworks
        let address = PodNetwork.address(index)
        var hosts = bootHosts ?? Hosts(entries: [])
        if separate {
            hosts.entries.append(Hosts.Entry(ipAddress: address, hostnames: [service.name] + (service.aliases ?? [])))
        }
        if service.gpu == true { await startGPU(in: pod) }
        let cpus = spec.cpus
        let finalHosts = hosts
        try await pod.addContainer(service.name, rootfs: rootfs) { c in
            Self.configure(&c, service, imageConfig, out: out, cpus: cpus, hosts: finalHosts, separate: separate)
        }
        say(service.name, "starting")
        try await pod.startContainer(service.name)
        try await settle(service, index: index, address: separate ? address : nil, in: pod)
    }

    /// Takes a service out of the running pod: stopped (it stays when that
    /// fails), its container forgotten, its name gone from the others'
    /// hosts files. One added while the pod ran frees its disk slot; one
    /// the pod booted with keeps its disk attached until the pod restarts.
    /// `deleteDisk` drops its root filesystem too.
    public func removeService(_ name: String, deleteDisk: Bool) async throws {
        guard let pod else { throw PierError("the pod is not running") }
        guard name != PodNetwork.helper else { throw PierError("the network helper stays") }
        spawnTimers[name]?.cancel()
        spawnTimers[name] = nil
        if let state = snapshot.services[name], state != .stopped {
            try await stopService(name)
        }
        try await pod.removeContainer(name)
        hotAdded.remove(name)
        netIndex[name] = nil
        if var running = currentSpec {
            running.services.removeAll { $0.name == name }
            currentSpec = running
        }
        agentTokens = agentTokens.filter { $0.value != name }
        let drop = "awk -v n='\(name)' '{for(i=2;i<=NF;i++) if($i==n) next} 1' /etc/hosts > /tmp/.pier-hosts && cat /tmp/.pier-hosts > /etc/hosts; rm -f /tmp/.pier-hosts"
        for other in currentSpec?.services ?? [] where snapshot.services[other.name] == .running {
            _ = try? await exec(["/bin/sh", "-c", drop], in: other.name)
        }
        if deleteDisk { try? FileManager.default.removeItem(at: serviceDir(name)) }
        update {
            $0.services[name] = nil
            $0.spawned[name] = nil
        }
        say(name, "removed from the pod")
        onServices(.removed(name))
    }

    private func watch(_ name: String, in pod: LinuxPod) {
        watchers.append(
            Task { [weak self] in
                do {
                    let status = try await pod.waitContainer(name)
                    await self?.exited(name, code: status.exitCode)
                } catch {
                    await self?.exited(name, code: -1)
                }
            })
    }

    private func exited(_ name: String, code: Int32) {
        guard pod != nil, snapshot.services[name] != .stopped, !stopping.contains(name), snapshot.pod != .stopping else { return }
        setService(name, .exited(code))
        say(name, "exited with \(code)")
        guard let spec = currentSpec, snapshot.pod == .running,
              let service = spec.services.first(where: { $0.name == name }) else { return }
        let again: Bool
        switch service.restart ?? .no {
        case .no: again = false
        case .always, .unlessStopped: again = true
        case .onFailure: again = code != 0
        }
        guard again else { return }
        let count = (restarts[name] ?? 0) + 1
        restarts[name] = count
        // Docker's back-off: 0.1 s doubling, at most a minute.
        let delay = min(0.1 * pow(2, Double(min(count, 10))), 60)
        say(name, "restarting (\(service.restart!.rawValue)) in \(String(format: "%.1f", delay)) s")
        let run = generation
        restartTasks[name]?.cancel()
        restartTasks[name] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.policyRestart(service, in: spec, run: run)
        }
    }

    private func policyRestart(_ service: ServiceSpec, in spec: PodSpec, run: Int) async {
        restartTasks[service.name] = nil
        guard run == generation, pod != nil, snapshot.pod == .running,
              case .exited = snapshot.services[service.name] else { return }
        try? await restartService(service, in: spec)
    }

    /// Waits as Compose does before starting a service: for services it
    /// depends on to pass their healthcheck or to finish.
    /// Nil when the service may start; otherwise why it may not.
    private func waitForDependencies(of service: ServiceSpec, in spec: PodSpec) async -> String? {
        for dep in service.dependsOn ?? [] {
            guard let other = spec.services.first(where: { $0.name == dep.service }) else { continue }
            switch dep.condition {
            case .started:
                continue
            case .healthy:
                guard let hc = other.healthcheck else { continue }
                say(service.name, "waiting for \(other.name) to be healthy")
                setService(service.name, .preparing("Waiting for \(other.name)"))
                if await waitHealthy(other.name, hc) {
                    say(service.name, "\(other.name) is healthy")
                } else {
                    say(service.name, "\(other.name) is not healthy, starting anyway")
                }
            case .completed:
                say(service.name, "waiting for \(other.name) to finish")
                setService(service.name, .preparing("Waiting for \(other.name)"))
                let deadline = ContinuousClock.now + .seconds(600)
                while ContinuousClock.now < deadline, !cancelBoot {
                    if case .exited(let code) = snapshot.services[other.name] {
                        say(service.name, "\(other.name) finished with \(code)")
                        if code != 0 { return "\(other.name) exited with \(code)" }
                        break
                    }
                    if case .failed = snapshot.services[other.name] { break }
                    if snapshot.services[other.name] == .stopped { break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
        if (service.dependsOn ?? []).contains(where: { $0.condition != .started }) {
            setService(service.name, .starting)
        }
        return nil
    }

    /// Runs a healthcheck until it passes or runs out of tries.
    private func waitHealthy(_ name: String, _ hc: Healthcheck) async -> Bool {
        let start = ContinuousClock.now
        var failures = 0
        // Check often at first; Docker waits a whole interval, which only slows a pod down.
        let pause = min(max(hc.intervalSeconds, 0.5), 2)
        let limit = hc.startPeriodSeconds + max(hc.intervalSeconds, 1) * Double(max(hc.retries, 1)) + 60
        while ContinuousClock.now - start < .seconds(limit) {
            if case .running = snapshot.services[name] {
                if cancelBoot { return false }
                if let (code, _) = await exec(hc.arguments, in: name, timeout: max(hc.timeoutSeconds, 1)), code == 0 { return true }
                if ContinuousClock.now - start > .seconds(hc.startPeriodSeconds) { failures += 1 }
            } else if case .exited = snapshot.services[name] {
                return false
            } else if snapshot.services[name] == .stopped {
                return false
            } else if case .failed = snapshot.services[name] {
                return false
            }
            if failures > max(hc.retries, 1) * Int(max(hc.intervalSeconds / pause, 1)) { return false }
            try? await Task.sleep(for: .seconds(pause))
        }
        return false
    }

    /// A file's SHA-256, read in pieces.
    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs a command but gives up after `timeout` seconds (the command may
    /// go on in the VM); nil when it timed out or could not run.
    func exec(_ arguments: [String], in service: String, timeout: Double) async -> (Int32, String)? {
        await withTaskGroup(of: (Int32, String)?.self) { group in
            group.addTask { try? await self.exec(arguments, in: service) }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Directories and files the services bind from /work, made before they start.
    private func prepareVolumes(_ spec: PodSpec, in pod: LinuxPod) async throws {
        var dirs: [String] = []
        var files: [(path: String, data: Data, mode: UInt32)] = []
        let fm = FileManager.default
        for service in spec.services {
            for v in service.volumes ?? [] {
                guard let kept = v.files else {
                    if !dirs.contains(v.source) { dirs.append(v.source) }
                    continue
                }
                let local = root.appendingPathComponent(kept)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: local.path, isDirectory: &isDir) else {
                    dirs.append(v.source)
                    continue
                }
                if !isDir.boolValue {
                    if !files.contains(where: { $0.path == v.source }), let data = fm.contents(atPath: local.path) {
                        files.append((v.source, data, Self.mode(of: local)))
                    }
                    continue
                }
                dirs.append(v.source)
                let items = fm.enumerator(at: local, includingPropertiesForKeys: [.isDirectoryKey])
                while let u = items?.nextObject() as? URL {
                    let rel = String(u.standardizedFileURL.path.dropFirst(local.standardizedFileURL.path.count + 1))
                    let dest = v.source + "/" + rel
                    if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        dirs.append(dest)
                    } else if !files.contains(where: { $0.path == dest }), let data = fm.contents(atPath: u.path) {
                        files.append((dest, data, Self.mode(of: u)))
                    }
                }
            }
        }
        guard !dirs.isEmpty || !files.isEmpty else { return }
        let bytes = files.reduce(0) { $0 + $1.data.count }
        podLog.note("volumes: \(dirs.count) directories, \(files.count) files (\(bytes >> 10) KB) in /work")
        try await pod.prepareVolume(Self.workVolume, directories: dirs, files: files)
    }

    private static func mode(of url: URL) -> UInt32 {
        let p = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
        return p & 0o777
    }

    /// Keeps a copy of the files a Compose project binds, so they are there
    /// each time the pod starts (the originals may be out of reach later).
    public nonisolated func keepFiles(of project: ComposeProject) throws {
        let fm = FileManager.default
        // Folders before what is inside them; what a copied folder holds is there already.
        var done: [String] = []
        for c in project.copies.sorted(by: { $0.to.count < $1.to.count }) {
            if done.contains(where: { c.to.hasPrefix($0 + "/") }) { continue }
            done.append(c.to)
            let dest = root.appendingPathComponent(c.to)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.copyItem(at: c.from, to: dest)
        }
    }

    public func stop() async {
        if booting {
            // The boot stops itself at its next step and cleans up.
            cancelBoot = true
            setPod(.stopping)
            while booting { try? await Task.sleep(for: .milliseconds(100)) }
            return
        }
        guard let pod else { return }
        setPod(.stopping)
        stopAgentAPI()
        restartTasks.values.forEach { $0.cancel() }
        restartTasks.removeAll()
        // Everything written reaches the disks before the machine goes.
        for name in snapshot.services.keys where snapshot.services[name] == .running {
            _ = try? await exec(["/bin/sync"], in: name)
        }
        for name in snapshot.services.keys {
            try? await pod.stopContainer(name)
        }
        do {
            try await pod.stop()
        } catch {
            podLog.note("stopping: \(error)")
        }
        self.pod = nil
        pids = [:]
        watchers.forEach { $0.cancel() }
        watchers.removeAll()
        update { s in
            for k in s.services.keys {
                if case .failed = s.services[k] { continue }
                s.services[k] = .stopped
            }
        }
        setPod(.stopped)
    }

    /// An `nmap` in /usr/local/bin for services with `honestScanning`. The
    /// VM reaches the network through slirp, which answers a TCP ACK to any
    /// address itself, so nmap's default host discovery calls every address
    /// up; unless probes are given, the wrapper uses ICMP echo and SYN, which
    /// get through honestly. Port scans need nothing.
    static let nmapWrapper = """
        #!/bin/sh
        # pier-nmap-wrapper: added by Pier (service option "Honest network scans").
        # The pod reaches the network through NAT, which answers a TCP ACK to any
        # address itself, so nmap's default host discovery would call every address
        # up. Unless discovery probes are given (-P...), use ICMP echo and SYN to
        # common ports, which get through honestly. OS detection (-O) sees the NAT.
        for a in "$@"; do
            case "$a" in -P*) exec /usr/bin/nmap "$@" ;; esac
        done
        [ -x /usr/bin/nmap ] || { echo "nmap is not installed (apt install nmap, apk add nmap, ...)" >&2; exit 127; }
        exec /usr/bin/nmap -PE -PS21,22,23,25,53,80,110,139,443,445,3389,5900,8000,8080,8443 "$@"
        """

    /// The service's startup commands, each in the background, their output
    /// in /var/log/pier-startup.log inside it and in its log here.
    func runStartup(_ service: ServiceSpec) async {
        let lines = (service.startup ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { return }
        for line in lines {
            say(service.name, "on start: \(line)")
            let quoted = "'" + line.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let script = "mkdir -p /var/log; echo \"== $(date '+%F %T') \(line.replacingOccurrences(of: "\"", with: "'"))\" >> /var/log/pier-startup.log; nohup sh -c \(quoted) >> /var/log/pier-startup.log 2>&1 < /dev/null & echo started"
            let result = try? await exec(["/bin/sh", "-c", script], in: service.name)
            if result?.0 != 0 { say(service.name, "on start failed: \(result?.1 ?? "")") }
        }
    }

    /// Puts the nmap wrapper in place, or takes Pier's away, as the option says.
    func applyScanning(_ service: ServiceSpec) async {
        let w = "/usr/local/bin/nmap"
        let script: String
        if service.honestScanning == true {
            script = "mkdir -p /usr/local/bin && cat > \(w) <<'PIER_EOF'\n\(Self.nmapWrapper)\nPIER_EOF\nchmod 755 \(w)"
        } else {
            script = "grep -q pier-nmap-wrapper \(w) 2>/dev/null && rm -f \(w); true"
        }
        _ = try? await exec(["/bin/sh", "-c", script], in: service.name)
    }

    /// Package repositories over HTTPS, with a CA bundle the image may lack.
    /// Plain HTTP does not always get through (a 5G modem answers it with
    /// its own pages), and apt, zypper and others default to it.
    func useHTTPSRepositories(in service: String) async {
        guard let url = Bundle.module.url(forResource: "cacert", withExtension: "pem"),
            let pem = try? String(contentsOf: url, encoding: .utf8)
        else { return }
        let sh = { (script: String) async -> (Int32, String)? in try? await self.exec(["/bin/sh", "-c", script], in: service) }
        guard let (has, _) = await sh("[ -d /etc/apt ] || [ -d /etc/zypp ]"), has == 0 else { return }
        _ = await sh("mkdir -p /etc/ssl/certs && : > /etc/ssl/certs/pier-ca.pem")
        // One exec per piece: the kernel takes at most 128 KiB in one argument.
        var rest = Substring(pem.replacingOccurrences(of: "'", with: ""))
        while !rest.isEmpty {
            let chunk = rest.prefix(60_000)
            rest = rest.dropFirst(chunk.count)
            _ = await sh("printf '%s' '\(chunk)' >> /etc/ssl/certs/pier-ca.pem")
        }
        let configure = """
            if [ -d /etc/apt ]; then
              for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
                [ -f "$f" ] && sed -i 's|http://|https://|g' "$f"
              done
              echo 'Acquire::https::CaInfo "/etc/ssl/certs/pier-ca.pem";' > /etc/apt/apt.conf.d/99pier-https
              [ -f /etc/ssl/certs/ca-certificates.crt ] || cp /etc/ssl/certs/pier-ca.pem /etc/ssl/certs/ca-certificates.crt
            fi
            if [ -d /etc/zypp ]; then
              for f in /etc/zypp/repos.d/*.repo; do [ -f "$f" ] && sed -i 's|http://|https://|g' "$f"; done
              [ -f /etc/ssl/ca-bundle.pem ] || cp /etc/ssl/certs/pier-ca.pem /etc/ssl/ca-bundle.pem
            fi
            echo ok
            """
        if let (code, _) = await sh(configure), code == 0 {
            say(service, "package repositories switched to https")
        }
    }

    /// Installs OpenSSH in a running service with whichever package manager
    /// its image has, sets root's password to `pier` and starts sshd on
    /// `port`. Returns the installer's output; throws if it failed.
    public func installSSH(in service: String, port: UInt16) async throws -> String {
        let script = Self.installSSH(port) + "\n" + Self.startSSH(port)
        say(service, "installing SSH on port \(port)")
        let (code, out) = try await exec(["/bin/sh", "-c", script], in: service)
        guard code == 0 else {
            say(service, "installing SSH failed (exit \(code))")
            throw PierError("installing SSH failed (exit \(code)):\n\(out.suffix(2000))")
        }
        say(service, "SSH installed, sshd on port \(port) (root / pier)")
        return out
    }

    static func installSSH(_ port: UInt16) -> String {
        [
            "set -e",
            "if [ -x /usr/sbin/sshd ] && command -v tmux >/dev/null 2>&1; then echo 'OpenSSH and tmux are installed already'",
            "elif command -v apk >/dev/null 2>&1; then apk add --no-cache openssh tmux",
            "elif command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends openssh-server tmux",
            "elif command -v dnf >/dev/null 2>&1; then dnf install -y openssh-server tmux",
            "elif command -v yum >/dev/null 2>&1; then yum install -y openssh-server tmux",
            "elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm openssh tmux",
            "elif command -v zypper >/dev/null 2>&1; then zypper -n install openssh tmux",
            "else echo 'no package manager found (apk, apt-get, dnf, yum, pacman, zypper)'; exit 1",
            "fi",
            "ssh-keygen -A",
            "mkdir -p /run/sshd /var/run/sshd /var/empty",
            "printf '%s\\n' 'Port \(port)' 'PermitRootLogin yes' 'PasswordAuthentication yes' 'KbdInteractiveAuthentication no' 'UsePAM no' 'PrintMotd no' 'Subsystem sftp internal-sftp' 'PidFile /run/sshd-pier.pid' > /etc/ssh/sshd_config_pier",
            "echo 'root:pier' | chpasswd",
        ].joined(separator: "\n")
    }

    /// Installs tmux in a running service with its image's package manager.
    public func installTmux(in service: String) async throws -> String {
        let script = [
            "set -e",
            "if command -v tmux >/dev/null 2>&1; then echo 'tmux is installed already'",
            "elif command -v apk >/dev/null 2>&1; then apk add --no-cache tmux",
            "elif command -v apt-get >/dev/null 2>&1; then export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y --no-install-recommends tmux",
            "elif command -v dnf >/dev/null 2>&1; then dnf install -y tmux",
            "elif command -v yum >/dev/null 2>&1; then yum install -y tmux",
            "elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm tmux",
            "elif command -v zypper >/dev/null 2>&1; then zypper -n install tmux",
            "else echo 'no package manager found'; exit 1",
            "fi",
            "tmux -V",
        ].joined(separator: "\n")
        say(service, "installing tmux")
        let (code, out) = try await exec(["/bin/sh", "-c", script], in: service)
        guard code == 0 else { throw PierError("installing tmux failed (exit \(code)):\n\(out.suffix(2000))") }
        say(service, "tmux installed")
        return out
    }

    static func startSSH(_ port: UInt16) -> String {
        // The pid file may be left from an earlier run of the pod, whose
        // process is gone: stopping it must not fail the start.
        "if [ -f /run/sshd-pier.pid ]; then kill $(cat /run/sshd-pier.pid) 2>/dev/null || true; rm -f /run/sshd-pier.pid; fi; sed -i 's/^Port .*/Port \(port)/' /etc/ssh/sshd_config_pier 2>/dev/null || true; mkdir -p /run/sshd; /usr/sbin/sshd -f /etc/ssh/sshd_config_pier && echo sshd listening on \(port)"
    }

    /// Stops one service; the others keep running.
    public func stopService(_ name: String) async throws {
        guard let pod else { throw PierError("the pod is not running") }
        restartTasks[name]?.cancel()
        restartTasks[name] = nil
        stopping.insert(name)
        defer { stopping.remove(name) }
        _ = try? await exec(["/bin/sync"], in: name)
        say(name, "stopping")
        try await pod.stopContainer(name)
        pids[name] = nil
        setService(name, .stopped)
        say(name, "stopped")
    }

    /// Starts one stopped service again in the running pod. Its address and
    /// network stay those of the pod as it booted, whatever the list's order
    /// is now.
    public func startService(_ service: ServiceSpec, in spec: PodSpec) async throws {
        guard let pod else { throw PierError("the pod is not running") }
        restartTasks[service.name]?.cancel()
        restartTasks[service.name] = nil
        let booted = currentSpec ?? spec
        guard let place = booted.services.firstIndex(where: { $0.name == service.name }),
              let index = netIndex[service.name] else {
            throw PierError("\(service.name) was added after the pod started: start the pod again")
        }
        var updated = booted
        updated.services[place] = service
        currentSpec = updated
        setService(service.name, .starting)
        say(service.name, "starting again")
        if hotAdded.contains(service.name) {
            // Its disk went back when it stopped: it is added again.
            if snapshot.services[service.name] == .running { throw PierError("\(service.name) is running") }
            do {
                try await pod.removeContainer(service.name)
                let (rootfs, imageConfig) = try await rootfs(for: service)
                try await attach(service, rootfs, imageConfig, index: index, in: pod, spec: updated)
            } catch {
                setService(service.name, .failed(String(describing: error)))
                say(service.name, "failed to start: \(error)")
                throw error
            }
            return
        }
        do {
            try await pod.recreateContainer(service.name)
            try await pod.startContainer(service.name)
            watch(service.name, in: pod)
            if booted.usesSeparateNetworks {
                let address = PodNetwork.address(index)
                guard let pid = await pod.containerPID(service.name) else { throw PierError("no PID for \(service.name)") }
                pids[service.name] = pid
                let (code, out) = try await exec(["/bin/sh", "-c", PodNetwork.wire(pid: pid, index: index, address: address)], in: PodNetwork.helper)
                if code != 0 {
                    try? await Task.sleep(for: .milliseconds(300))
                    if case .exited = snapshot.services[service.name] { return }
                    throw PierError("could not give \(service.name) its network:\n\(out.suffix(600))")
                }
            }
        } catch {
            setService(service.name, .failed(String(describing: error)))
            say(service.name, "failed to start: \(error)")
            throw error
        }
        if case .exited = snapshot.services[service.name] { return }
        say(service.name, "running")
        setService(service.name, .running)
        await useHTTPSRepositories(in: service.name)
        await applyScanning(service)
        await runStartup(service)
        await installAgentAccess(updated.services[place])
        if let port = service.sshPort {
            _ = try? await exec(["/bin/sh", "-c", Self.startSSH(port)], in: service.name)
        }
    }

    public func restartService(_ service: ServiceSpec, in spec: PodSpec) async throws {
        if snapshot.services[service.name] != .stopped {
            // Running, or exited by itself (still "started" to the pod).
            try? await stopService(service.name)
        }
        try await startService(service, in: spec)
    }

    /// Runs a command in a running service and returns what it printed.
    /// Where a command for a service runs, and as what. The agent's exec
    /// joins every namespace of a container but its network, so in a pod of
    /// separate networks it runs through the helper, entering all of the
    /// container's namespaces with nsenter.
    func route(_ arguments: [String], in service: String) -> (container: String, arguments: [String]) {
        guard service != PodNetwork.helper, let pid = pids[service] else { return (service, arguments) }
        return (PodNetwork.helper, PodNetwork.enter(pid: pid, arguments))
    }

    public func exec(_ arguments: [String], in service: String) async throws -> (Int32, String) {
        let (code, data) = try await execData(arguments, in: service, limit: 10_000)
        return (code, data)
    }

    /// Runs a command and keeps its output whole up to `bytes` (stdout only),
    /// for output that is data rather than lines to read.
    func execBytes(_ arguments: [String], in service: String, bytes: Int, timeout: Double) async -> (Int32, Data)? {
        await withTaskGroup(of: (Int32, Data)?.self) { group in
            group.addTask {
                guard let pod = await self.pod else { return nil }
                let sink = ByteSink(limit: bytes)
                let (target, args) = await self.route(arguments, in: service)
                guard let process = try? await pod.execInContainer(target, processID: "exec-\(UUID().uuidString.prefix(8))", configuration: { c in
                    c.arguments = args
                    c.stdout = sink
                }) else { return nil }
                guard (try? await process.start()) != nil, let status = try? await process.wait() else { return nil }
                try? await process.delete()
                return (status.exitCode, sink.data)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private func execData(_ arguments: [String], in service: String, limit: Int) async throws -> (Int32, String) {
        guard let pod else { throw PierError("the pod is not running") }
        let out = LogBuffer(limit: limit)
        let (target, args) = route(arguments, in: service)
        let process = try await pod.execInContainer(target, processID: "exec-\(UUID().uuidString.prefix(8))") { c in
            c.arguments = args
            c.stdout = out
            c.stderr = out
        }
        try await process.start()
        let status = try await process.wait()
        try? await process.delete()
        return (status.exitCode, out.text)
    }
}

/// A pipe whose reading end feeds a ``LogBuffer``: the guest's console.
final class ConsolePipe: @unchecked Sendable {
    let pipe = Pipe()
    var handle: FileHandle { pipe.fileHandleForWriting }

    init(_ log: LogBuffer) {
        pipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
            } else {
                log.append(data)
            }
        }
    }
}

/// Turns a stream of progress events into a line now and then, Docker-style:
/// "downloaded 12.4 / 54.0 MB (2/5 layers), 6.1 MB/s".
final class Meter: Sendable {
    enum Unit { case bytes }
    private struct State {
        var size: Int64 = 0
        var totalSize: Int64 = 0
        var items = 0
        var totalItems = 0
        var lastLine = ContinuousClock.now - .seconds(10)
        var lastSize: Int64 = 0
        let started = ContinuousClock.now
    }
    private let state = Mutex(State())
    private let label: String
    private let emit: @Sendable (String) -> Void

    init(label: String, unit: Unit, emit: @escaping @Sendable (String) -> Void) {
        self.label = label
        self.emit = emit
    }

    var handler: ProgressHandler {
        { [self] events in self.take(events) }
    }

    private func take(_ events: [ProgressEvent]) {
        let line: String? = state.withLock { s in
            for e in events {
                switch e {
                case .addSize(let n): s.size += n
                case .addTotalSize(let n): s.totalSize += n
                case .addItems(let n): s.items += n
                case .addTotalItems(let n): s.totalItems += n
                }
            }
            let now = ContinuousClock.now
            let done = s.totalSize > 0 && s.size >= s.totalSize
            guard now - s.lastLine >= .seconds(1) || done else { return nil }
            let elapsed = Double((now - s.lastLine).components.attoseconds) / 1e18 + Double((now - s.lastLine).components.seconds)
            let rate = elapsed > 0 && elapsed < 5 ? Double(s.size - s.lastSize) / elapsed : 0
            s.lastLine = now
            s.lastSize = s.size
            return Self.describe(label, s.size, s.totalSize, s.items, s.totalItems, rate)
        }
        if let line { emit(line) }
    }

    var summary: String {
        state.withLock { s in
            let secs = Double((ContinuousClock.now - s.started).components.seconds)
            let rate = secs > 0 ? " (\(Self.mb(Int64(Double(s.size) / secs)))/s)" : ""
            return "\(Self.mb(s.size))\(s.totalItems > 0 ? ", \(s.totalItems) items" : "")\(rate)"
        }
    }

    static func describe(_ label: String, _ size: Int64, _ total: Int64, _ items: Int, _ totalItems: Int, _ rate: Double) -> String {
        var t = "\(label) \(mb(size))"
        if total > 0 {
            t += " / \(mb(total)) (\(Int(Double(size) * 100 / Double(total)))%)"
        }
        if totalItems > 0 { t += ", \(items)/\(totalItems)" }
        if rate > 0 { t += ", \(mb(Int64(rate)))/s" }
        return t
    }

    static func mb(_ bytes: Int64) -> String {
        String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    static func seconds(_ d: Duration) -> String {
        String(format: "%.1f s", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
    }
}

/// Collects a command's output as bytes, up to a limit.
final class ByteSink: Writer, Sendable {
    private let buffer = Mutex(Data())
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    var data: Data { buffer.withLock { $0 } }

    func write(_ data: Data) throws {
        buffer.withLock { b in
            guard b.count < limit else { return }
            b.append(data.prefix(limit - b.count))
        }
    }

    func close() throws {}
}

extension PodRunner {
    /// The GPU server, and its backend in /work for containers to mount:
    /// at boot, or when a service with GPU on joins the running pod.
    func startGPU(in pod: LinuxPod) async {
        if let shim = GPUShim.data {
            do {
                try await pod.prepareVolume(Self.workVolume, directories: [GPUShim.volumePath],
                                            files: [(GPUShim.volumePath + "/libggml-rpc.so", shim, 0o755)])
            } catch {
                podLog.note("GPU: could not put its backend in /work: \(error)")
            }
        }
        let log = podLog
        let budget = GPUServer.budget(vmMiB: currentSpec?.memoryMiB ?? 0)
        GPUServer.start(cache: root.appendingPathComponent("gpu-cache"), budget: budget) { log.note($0) }
    }
}

/// Pier's RPC backend for ggml in the containers (gpu/pier-gpu.cpp, built
/// against the ggml of the Ollama release it serves).
enum GPUShim {
    static let directory = "/usr/local/lib/pier"
    static let volumePath = ".pier/gpu"
    static let data: Data? = Bundle.module.url(forResource: "libggml-rpc", withExtension: "so").flatMap { try? Data(contentsOf: $0) }
}

extension PodRunner {
    /// Free and total bytes of an ext4 image, from its superblock (as the
    /// guest last left it).
    static func ext4Space(of url: URL) -> (free: UInt64, total: UInt64)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: 1024)) != nil, let sb = try? h.read(upToCount: 1024), sb.count == 1024 else { return nil }
        func u32(_ o: Int) -> UInt64 { UInt64(sb[o]) | UInt64(sb[o + 1]) << 8 | UInt64(sb[o + 2]) << 16 | UInt64(sb[o + 3]) << 24 }
        guard sb[0x38] == 0x53, sb[0x39] == 0xEF else { return nil }      // the ext4 magic
        let blockSize = UInt64(1024) << u32(0x18)
        let total = (u32(0x04) | u32(0x150) << 32) * blockSize
        let free = (u32(0x0C) | u32(0x158) << 32) * blockSize
        return (free, total)
    }
}
