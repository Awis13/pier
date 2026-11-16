import PierCore
import SwiftUI
import UniformTypeIdentifiers

/// Where a Compose file comes from: a folder or a file in Files, or text.
enum ComposeSource: Identifiable {
    case picked(URL)
    case pasted

    var id: String {
        switch self {
        case .picked(let u): u.absoluteString
        case .pasted: "pasted"
        }
    }
}

/// Reads a Compose file and shows what it becomes before anything changes.
struct ComposeImportView: View {
    @Environment(PodModel.self) private var pod
    @Environment(JITSession.self) private var jit
    @Environment(\.dismiss) private var dismiss
    let source: ComposeSource
    var onImported: (String?) -> Void

    @State private var text = ""
    @State private var project: ComposeProject?
    @State private var error: String?
    enum Mode { case add, update, replaceAll }
    @State private var mode = Mode.add
    @State private var scoped: URL?

    var body: some View {
        NavigationStack {
            Form {
                if case .pasted = source {
                    Section {
                        TextEditor(text: $text)
                            .font(.callout.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(minHeight: 180)
                        Button("Read") { read(text: text, directory: nil) }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: {
                        Text("compose.yaml")
                    } footer: {
                        Text("Files next to a Compose file (bind mounts, env_file, .env) come along only when you open its folder.")
                    }
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }
                if let project {
                    Section {
                        LabeledContent("Project", value: project.name)
                        Picker("Services in the pod", selection: $mode) {
                            Text("Add").tag(Mode.add)
                            Text("Update").tag(Mode.update)
                            Text("Replace All").tag(Mode.replaceAll)
                        }
                        .pickerStyle(.segmented)
                        if let clash {
                            Text(clash).font(.caption).foregroundStyle(.orange)
                        }
                    } footer: {
                        switch mode {
                        case .add: Text("These join the services already in the pod.")
                        case .update: Text("Services with these names are replaced (their disks stay); the others are added. The rest of the pod is left alone.")
                        case .replaceAll: Text("The pod's services become these. Services that go take their disks along; images stay.")
                        }
                    }
                    Section("Services, in start order") {
                        ForEach(project.services) { s in
                            ServiceSummary(service: s)
                        }
                    }
                    if !project.warnings.isEmpty {
                        Section("Left out or changed") {
                            ForEach(project.warnings, id: \.self) { w in
                                Label(w, systemImage: "exclamationmark.triangle").font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !project.copies.isEmpty {
                        Section {
                            ForEach(project.copies, id: \.to) { c in
                                Text(c.to.replacingOccurrences(of: "projects/\(project.name)/", with: "./"))
                                    .font(.callout.monospaced())
                            }
                        } header: {
                            Text("Files brought along")
                        } footer: {
                            Text("Pier keeps a copy and puts it in /work/.pier/projects/\(project.name) each time the pod starts. Import again after changing them.")
                        }
                    }
                }
            }
            .navigationTitle("Docker Compose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") { importProject() }
                        .disabled(project == nil || project!.services.isEmpty || clash != nil)
                }
            }
            .onAppear(perform: load)
            .onDisappear { scoped?.stopAccessingSecurityScopedResource(); scoped = nil }
        }
    }

    /// Names already taken when adding.
    private var clash: String? {
        guard let project, mode == .add else { return nil }
        let taken = Set(pod.spec.services.map(\.name))
        let both = project.services.map(\.name).filter(taken.contains)
        return both.isEmpty ? nil : "Already in the pod: \(both.joined(separator: ", ")). Update replaces them."
    }

    private func load() {
        guard case .picked(let url) = source else { return }
        if url.startAccessingSecurityScopedResource() { scoped = url }
        switch ComposeLoader.load(url) {
        case .success(let p):
            project = p
            error = nil
            let taken = Set(pod.spec.services.map(\.name))
            if p.services.contains(where: { taken.contains($0.name) }) { mode = .update }
        case .failure(let e): error = e.description
        }
    }

    private func read(text: String, directory: URL?, name: String? = nil) {
        do {
            var p = try ComposeProject.parse(text, directory: directory, projectName: nil)
            if directory == nil, case .picked = source {
                p.warnings.insert("Opened as a file: open its folder to bring .env, env_file and bind-mounted files along", at: 0)
            }
            if p.name == "compose", let name { p.name = name }
            project = p
            error = nil
        } catch {
            project = nil
            self.error = String(describing: error)
        }
    }

    private func importProject() {
        guard let project else { return }
        do {
            try pod.runner.keepFiles(of: project)
        } catch {
            self.error = "Could not copy the project's files: \(error.localizedDescription)"
            return
        }
        let services = project.services
        let mode = self.mode
        pod.change(jit: jit) { list in
            switch mode {
            case .add: list += services
            case .replaceAll: list = services
            case .update:
                for s in services {
                    if let i = list.firstIndex(where: { $0.name == s.name }) { list[i] = s } else { list.append(s) }
                }
            }
        }
        if !pod.isActive && jit.isOn { pod.start(jit: jit) }
        onImported(services.first?.name)
        dismiss()
    }
}

/// One service of a Compose project in a line or three.
private struct ServiceSummary: View {
    let service: ServiceSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(service.name).font(.body.monospaced().bold())
                Spacer()
                Text(service.image).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            let details = lines
            if !details.isEmpty {
                Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var lines: [String] {
        var out: [String] = []
        if !service.ports.isEmpty { out.append("ports " + service.ports.map(\.description).joined(separator: ", ")) }
        if let v = service.volumes, !v.isEmpty { out.append("\(v.count) volume\(v.count == 1 ? "" : "s")") }
        if let d = service.dependsOn, !d.isEmpty {
            out.append("after " + d.map { $0.condition == .healthy ? "\($0.service) is healthy" : $0.service }.joined(separator: ", "))
        }
        if service.healthcheck != nil { out.append("healthcheck") }
        if let r = service.restart, r != .no { out.append("restart \(r.rawValue)") }
        if !service.environment.isEmpty { out.append("\(service.environment.count) env") }
        return out
    }
}

/// Reads a Compose project from a folder (with its files) or a single file.
/// The URL must be readable (security scope already taken).
enum ComposeLoader {
    static func load(_ url: URL) -> Result<ComposeProject, PierError> {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let file: URL
        let directory: URL?
        if isDir.boolValue {
            guard let f = ComposeProject.file(in: url) else {
                return .failure(PierError("No compose.yaml or docker-compose.yml in \(url.lastPathComponent)."))
            }
            file = f
            directory = url
        } else {
            file = url
            // Its folder, when Pier may read it (always for its own files).
            let parent = url.deletingLastPathComponent()
            directory = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) != nil ? parent : nil
        }
        do {
            let text = try String(contentsOf: file, encoding: .utf8)
            var p = try ComposeProject.parse(text, directory: directory)
            if p.needsFolder {
                p.warnings.insert("Opened without its folder: open the folder to bring .env, env_file and bind-mounted files along", at: 0)
            }
            if p.name == "compose" {
                let n = (directory ?? file.deletingLastPathComponent()).lastPathComponent
                let clean = ComposeProject.cleanName(n)
                if !clean.isEmpty { p.name = clean }
            }
            return .success(p)
        } catch let e as PierError {
            return .failure(e)
        } catch {
            return .failure(PierError("Could not read \(file.lastPathComponent): \(error.localizedDescription)"))
        }
    }

    /// Whether a dropped file is a Dockerfile rather than a Compose file.
    static func isDockerfile(_ url: URL) -> Bool {
        let n = url.lastPathComponent.lowercased()
        return n == "dockerfile" || n.hasPrefix("dockerfile.") || n.hasSuffix(".dockerfile") || n == "containerfile"
    }
}

/// The overlay while something is dragged over Pier.
struct ComposeDropOverlay: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [14, 10], dashPhase: phase))
                .foregroundStyle(.tint)
                .padding(24)
            VStack(spacing: 14) {
                Image(systemName: "square.stack.3d.down.right.fill")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.tint)
                    .symbolEffect(.bounce, options: .repeating.speed(0.6))
                Text("Drop to Run").font(.largeTitle.bold())
                Text("A compose.yaml, or the folder it is in with its files")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { phase = -24 }
        }
        .transition(.opacity.combined(with: .scale(scale: 1.03)))
        .allowsHitTesting(false)
    }
}

/// A short note at the top after a drop.
struct DropToast: View {
    let text: String
    let ok: Bool

    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.callout.weight(.semibold))
            .foregroundStyle(ok ? Color.green : Color.orange)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 12, y: 4)
            .padding(.top, 12)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
