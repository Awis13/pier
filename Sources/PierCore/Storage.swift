import Containerization
import ContainerizationOCI
import Foundation

/// An image in the store: what it takes and who runs it.
public struct StoredImage: Sendable, Identifiable, Hashable {
    public let reference: String
    public let digest: String
    /// The compressed size of its arm64 layers, as pulled.
    public let bytes: UInt64
    public let usedBy: [String]
    public var id: String { reference }
}

/// A disk Pier keeps: a service's root filesystem, /work or the agent's.
public struct StoredDisk: Sendable, Identifiable, Hashable {
    public enum Kind: Sendable, Hashable { case service, work, agent }
    public let name: String
    public let kind: Kind
    public let path: URL
    /// What it takes on the iPad (they are sparse).
    public let bytes: UInt64
    /// A service of the spec has it.
    public let inUse: Bool
    public var id: String { path.path }
}

extension PodRunner {
    private static func allocated(_ url: URL) -> UInt64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isDirectoryKey]
        guard let v = try? url.resourceValues(forKeys: keys) else { return 0 }
        if v.isDirectory == true {
            let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys))) ?? []
            return items.reduce(0) { $0 + allocated($1) }
        }
        return UInt64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
    }

    public func images(for spec: PodSpec) async -> [StoredImage] {
        let images = (try? await imageStore.list()) ?? []
        var out: [StoredImage] = []
        for image in images {
            var bytes: UInt64 = 0
            if let m = try? await image.manifest(for: Self.arm64) {
                bytes = m.layers.reduce(UInt64(0)) { $0 + UInt64(max($1.size, 0)) }
            }
            let users = spec.services.filter { ServiceSpec.normalizedImage($0.image) == image.reference }.map(\.name)
            out.append(StoredImage(reference: image.reference, digest: image.digest, bytes: bytes, usedBy: users))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    public nonisolated func disks(for spec: PodSpec) -> [StoredDisk] {
        var out: [StoredDisk] = []
        let services = root.appendingPathComponent("services")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: services.path)) ?? []
        for name in names.sorted() {
            let dir = services.appendingPathComponent(name)
            let used = spec.services.contains { $0.name == name } || (name == PodNetwork.helper && spec.usesSeparateNetworks)
            out.append(StoredDisk(name: name, kind: .service, path: dir, bytes: Self.allocated(dir), inUse: used))
        }
        let work = root.appendingPathComponent("work.ext4")
        if FileManager.default.fileExists(atPath: work.path) {
            out.append(StoredDisk(name: "/work", kind: .work, path: work, bytes: Self.allocated(work), inUse: true))
        }
        let initfs = root.appendingPathComponent("initfs.ext4")
        if FileManager.default.fileExists(atPath: initfs.path) {
            out.append(StoredDisk(name: "guest agent", kind: .agent, path: initfs, bytes: Self.allocated(initfs), inUse: true))
        }
        return out
    }

    /// Removes an image and the layers no other image needs.
    public func deleteImage(_ reference: String) async throws -> UInt64 {
        try await imageStore.delete(reference: reference, performCleanup: false)
        return (try? await imageStore.cleanUpOrphanedBlobs().freed) ?? 0
    }

    /// Removes a disk. A running pod keeps the disks it has in use.
    public func deleteDisk(_ disk: StoredDisk) throws {
        if isRunning && disk.inUse {
            throw PierError("stop the pod first: \(disk.name) is in use")
        }
        try FileManager.default.removeItem(at: disk.path)
        if disk.kind == .service {
            log(for: disk.name).clear()
        }
    }

    /// Images no service uses, disks of services that are gone, and layers
    /// nothing needs. Returns the bytes freed.
    public func removeUnused(for spec: PodSpec) async -> UInt64 {
        var freed: UInt64 = 0
        for image in await images(for: spec) where image.usedBy.isEmpty {
            if image.reference == ServiceSpec.normalizedImage(PodNetwork.helperImage) && spec.usesSeparateNetworks { continue }
            if image.reference == Self.defaultInitImage { continue }
            freed += image.bytes
            try? await imageStore.delete(reference: image.reference, performCleanup: false)
        }
        for disk in disks(for: spec) where !disk.inUse {
            freed += disk.bytes
            try? FileManager.default.removeItem(at: disk.path)
        }
        freed += (try? await imageStore.cleanUpOrphanedBlobs().freed) ?? 0
        return freed
    }
}
