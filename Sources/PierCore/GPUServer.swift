// The iPad's GPU for software in the containers: ggml's RPC server on
// Metal, inside the app. A container's ggml (Ollama, llama.cpp) reaches it
// through the RPC backend Pier puts there (`GPUShim`), at 10.0.2.2:50052,
// the VM's way to the app. Pier keeps no models and runs nothing else here.

import Foundation
import Synchronization
import ggml

public enum GPUServer {
    public static let port = 50052
    /// Where containers find it: the VM's user-mode network sends 10.0.2.2
    /// to the app's own loopback.
    public static let endpoint = "10.0.2.2:\(port)"

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
    /// What containers may hold on the GPU: on an iPad, the memory the VM and
    /// iPadOS leave (the GPU shares it), so a model too big for it is split
    /// with the CPU instead of getting the app ended; on a Mac, no limit.
    public static func budget(vmMiB: UInt64) -> Int {
        if let mib = ProcessInfo.processInfo.environment["PIER_GPU_BUDGET_MIB"].flatMap(Int.init) { return mib << 20 }
        #if os(iOS)
        let reserve: UInt64 = 3 << 30          // iPadOS, the app, crate's JIT code
        let total = ProcessInfo.processInfo.physicalMemory
        let used = vmMiB << 20 + reserve
        return total > used + (512 << 20) ? Int(total - used) : 512 << 20
        #else
        return 0
        #endif
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
