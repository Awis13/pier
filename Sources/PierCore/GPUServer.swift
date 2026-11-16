// The iPad's GPU for software in the containers: ggml's RPC server on
// Metal, inside the app. A container's ggml (Ollama, llama.cpp) reaches it
// through the RPC backend Pier puts there (`GPUShim`), at 10.0.2.2:50052,
// the VM's way to the app. Pier keeps no models and runs nothing else here.

import Foundation
import Synchronization
import ggml

public enum GPUServer {
    public static let port = 50052
    /// Where containers find it: the VM's vsock, to the app (the backend in
    /// the container connects with AF_VSOCK, past the VM's network); the app
    /// passes each connection to the server on its loopback.
    public static let endpoint = "vsock:\(port)"

    /// Joins a vsock connection from a container to the server, both ways,
    /// on threads of their own; closes both when either side ends.
    static func bridge(_ vsock: Int32) {
        let tcp = socket(AF_INET, SOCK_STREAM, 0)
        guard tcp >= 0 else { close(vsock); return }
        var one: Int32 = 1
        setsockopt(tcp, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(tcp, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
        guard connected else { close(tcp); close(vsock); return }
        Relay.join(vsock, tcp)
    }

    private static let started = Mutex(false)

    /// The GPU's name and memory, as the server offers it.
    public static func device() -> (name: String, totalMiB: Int)? {
        guard let dev = metal() else { return nil }
        var free = 0, total = 0
        ggml_backend_dev_memory(dev, &free, &total)
        return (String(cString: ggml_backend_dev_description(dev)), total >> 20)
    }

    private static func metal() -> ggml_backend_dev_t? {
        for i in 0..<ggml_backend_dev_count() {
            if let d = ggml_backend_dev_get(i), ggml_backend_dev_type(d) == GGML_BACKEND_DEVICE_TYPE_GPU { return d }
        }
        return nil
    }

    /// Starts the server once, on a thread of its own (it never returns).
    /// `cache` keeps tensors a client sent before, so a model loads faster
    /// the next time.
    /// What containers may hold on the GPU: no limit, unless
    /// PIER_GPU_BUDGET_MIB sets one. A model too big for the iPad may get
    /// Pier ended by iPadOS; that is the user's call.
    public static func budget(vmMiB: UInt64) -> Int {
        ProcessInfo.processInfo.environment["PIER_GPU_BUDGET_MIB"].flatMap(Int.init).map { $0 << 20 } ?? 0
    }

    @discardableResult
    public static func start(cache: URL, budget: Int, log: @escaping @Sendable (String) -> Void) -> Bool {
        ggml_backend_rpc_set_memory_budget(budget)
        let first = started.withLock { s in
            defer { s = true }
            return !s
        }
        guard first else { return true }
        guard let dev = metal() else {
            log("GPU: no Metal device")
            return false
        }
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let name = String(cString: ggml_backend_dev_description(dev))
        let devPtr = UnsafeMutablePointer<ggml_backend_dev_t?>.allocate(capacity: 1)
        devPtr.initialize(to: dev)
        let cachePath = strdup(cache.path)
        let thread = Thread {
            ggml_backend_rpc_start_server("127.0.0.1:\(port)", cachePath, 2, 1, devPtr)
            log("GPU: the server stopped")
        }
        thread.name = "pier.gpu"
        thread.stackSize = 8 << 20
        thread.start()
        log("GPU: \(name) for containers at \(endpoint)" + (budget > 0 ? ", up to \(budget >> 20) MB" : ""))
        return true
    }
}
