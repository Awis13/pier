import PierCore
import SwiftUI

/// What Pier keeps on the iPad: images, disks, and a way to clear them.
struct StorageView: View {
    @Environment(PodModel.self) private var pod
    @Environment(\.dismiss) private var dismiss
    @State private var images: [StoredImage] = []
    @State private var disks: [StoredDisk] = []
    @State private var loading = true
    @State private var message: String?
    @State private var confirmWork: StoredDisk?
    @State private var busy = false

    private var total: UInt64 { images.reduce(0) { $0 + $1.bytes } + disks.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Total", value: Self.size(total))
                    Button {
                        Task { await removeUnused() }
                    } label: {
                        Label("Remove Unused", systemImage: "trash")
                    }
                    .disabled(busy)
                } footer: {
                    Text(message ?? "Removes images no service uses, disks of services that are gone, and layers nothing needs.")
                }
                Section("Images") {
                    if images.isEmpty && !loading { Text("No images.").foregroundStyle(.secondary) }
                    ForEach(images) { image in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(image.reference).font(.callout.monospaced()).lineLimit(2)
                                Text(image.usedBy.isEmpty ? "not used" : "used by " + image.usedBy.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(image.usedBy.isEmpty ? .orange : .secondary)
                            }
                            Spacer()
                            Text(Self.size(image.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Button(role: .destructive) { Task { await delete(image) } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).disabled(busy)
                        }
                        .swipeActions { Button("Delete", role: .destructive) { Task { await delete(image) } } }
                    }
                }
                Section {
                    ForEach(disks) { disk in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(disk.name).font(.callout.monospaced())
                                Text(caption(disk)).font(.caption).foregroundStyle(disk.inUse ? .secondary : Color.orange)
                            }
                            Spacer()
                            Text(Self.size(disk.bytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            if disk.kind != .agent {
                                Button(role: .destructive) { ask(disk) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).disabled(busy)
                            }
                        }
                    }
                } header: {
                    Text("Disks")
                } footer: {
                    Text("A service's disk holds what was installed in it; removing it starts the service fresh from its image. Disks of a running pod can be removed once it stops.")
                }
            }
            .overlay { if loading { ProgressView() } }
            .navigationTitle("Storage")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .secondaryAction) {
                    Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .confirmationDialog("Remove /work?", isPresented: Binding(get: { confirmWork != nil }, set: { if !$0 { confirmWork = nil } }), titleVisibility: .visible) {
                Button("Remove /work and Everything in It", role: .destructive) {
                    if let d = confirmWork { Task { await delete(d) } }
                }
            } message: {
                Text("Every file the services keep in /work goes. This cannot be undone.")
            }
            .task { await reload() }
        }
    }

    private func caption(_ d: StoredDisk) -> String {
        switch d.kind {
        case .work: "shared by the services"
        case .agent: "the guest agent's filesystem; made again when needed"
        case .service: d.inUse ? "root filesystem" : "service is gone"
        }
    }

    private func ask(_ d: StoredDisk) {
        if d.kind == .work { confirmWork = d } else { Task { await delete(d) } }
    }

    private func reload() async {
        loading = true
        images = await pod.runner.images(for: pod.spec)
        disks = pod.runner.disks(for: pod.spec)
        loading = false
    }

    private func delete(_ image: StoredImage) async {
        busy = true
        do {
            let freed = try await pod.runner.deleteImage(image.reference)
            message = "Removed \(image.reference), freed \(Self.size(max(freed, image.bytes)))."
        } catch {
            message = String(describing: error)
        }
        busy = false
        await reload()
    }

    private func delete(_ disk: StoredDisk) async {
        busy = true
        do {
            try await pod.runner.deleteDisk(disk)
            message = "Removed \(disk.name), freed \(Self.size(disk.bytes))."
        } catch {
            message = String(describing: error)
        }
        busy = false
        await reload()
    }

    private func removeUnused() async {
        busy = true
        let freed = await pod.runner.removeUnused(for: pod.spec)
        message = "Freed \(Self.size(freed))."
        busy = false
        await reload()
    }

    static func size(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }
}
