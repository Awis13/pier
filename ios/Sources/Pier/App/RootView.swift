import PierCore
import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @Environment(PodModel.self) private var pod
    @Environment(JITSession.self) private var jit
    @Environment(\.openWindow) private var openWindow
    @State private var selection: String?
    @State private var switching = false
    @State private var adding = false
    @State private var pickingCompose = false
    @State private var compose: ComposeSource?
    @State private var dropTargeted = false
    @State private var toast: (text: String, ok: Bool)?
    @State private var showingSettings = false
    @State private var showingPodLog = false
    @State private var showingStorage = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    PodHeader(showingLog: $showingPodLog)
                }
                Section("Network") {
                    Label("Addresses and Ports", systemImage: "network")
                        .tag("#network")
                    ForEach(["127.0.0.1"] + NetworkAddresses.current(), id: \.self) { ip in
                        CopyRow(text: ip, caption: ip == "127.0.0.1" ? "this iPad" : "network")
                    }
                }
                Section("Services") {
                    ForEach(pod.spec.services) { service in
                        ServiceRow(service: service)
                            .tag(service.name)
                            .contextMenu { ServiceMenu(service: service) }
                    }
                    .onMove { from, to in
                        pod.spec.services.move(fromOffsets: from, toOffset: to)
                    }
                }
            }
            .navigationTitle("Pier")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { adding = true } label: { Label("Add Service", systemImage: "shippingbox") }
                        Button { pickingCompose = true } label: { Label("Import Docker Compose...", systemImage: "square.stack.3d.up") }
                        Button { compose = .pasted } label: { Label("Paste Compose YAML", systemImage: "doc.on.clipboard") }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button { showingSettings = true } label: { Label("Pod Settings", systemImage: "slider.horizontal.3") }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button { showingStorage = true } label: { Label("Storage", systemImage: "internaldrive") }
                }
            }
        } detail: {
            if selection == "#network" || selection.map({ $0 == "127.0.0.1" || NetworkAddresses.current().contains($0) }) == true {
                NetworkView()
            } else if let name = selection, let service = pod.spec.services.first(where: { $0.name == name }) {
                ServiceDetail(service: service)
            } else {
                ContentUnavailableView(
                    "No Service Selected",
                    systemImage: "shippingbox",
                    description: Text("Pick a service to see its log and ports, or add one with +.")
                )
            }
        }
        .background(MainWindowMark())
        .onAppear { MainWindow.shared.open = { openWindow(id: "main") } }
        .focusedSceneValue(\.switcherShown, $switching)
        .sheet(isPresented: $switching) {
            SwitcherView(model: SwitcherModel(pod: pod, currentTab: selection.flatMap { pod.selectedTerminal[$0] })) { e in
                Switch.go(to: e, pod: pod, openWindow: openWindow)
            }
        }
        .onChange(of: pod.showRequest) {
            if let name = pod.showRequest {
                selection = name
                pod.showRequest = nil
            }
        }
        .focusedSceneValue(\.selectedService, pod.spec.services.contains(where: { $0.name == selection }) ? selection : nil)
        .sheet(isPresented: $adding) {
            ServiceEditor(original: nil) { new in
                pod.change(jit: jit) { $0.append(new) }
                selection = new.name
            }
        }
        .onDrop(of: [.folder, .yaml, .fileURL, .item], isTargeted: $dropTargeted.animation(.spring(duration: 0.3))) { providers in
            guard let provider = providers.first else { return false }
            let type = provider.registeredTypeIdentifiers.first(where: { $0 == UTType.folder.identifier })
                ?? provider.registeredTypeIdentifiers.first ?? UTType.item.identifier
            _ = provider.loadInPlaceFileRepresentation(forTypeIdentifier: type) { url, inPlace, _ in
                guard let url else { return }
                // A copy (not in place) is deleted when this returns: keep our own.
                var target = url
                if !inPlace {
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
                    let copy = dir.appendingPathComponent(url.lastPathComponent)
                    guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
                          (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
                    target = copy
                }
                Task { @MainActor in dropped(target) }
            }
            return true
        }
        .overlay { if dropTargeted { ComposeDropOverlay() } }
        .overlay(alignment: .top) {
            if let toast { DropToast(text: toast.text, ok: toast.ok) }
        }
        .fileImporter(
            isPresented: $pickingCompose,
            allowedContentTypes: [.folder, .yaml] + [UTType(filenameExtension: "yml")].compactMap { $0 }
        ) { result in
            if case .success(let url) = result { compose = .picked(url) }
        }
        .sheet(item: $compose) { source in
            ComposeImportView(source: source) { first in
                if let first { selection = first }
            }
        }
        .sheet(isPresented: Binding(get: { pod.editRequest != nil }, set: { if !$0 { pod.editRequest = nil } })) {
            if let name = pod.editRequest, let service = pod.spec.services.first(where: { $0.name == name }) {
                ServiceEditor(original: service) { updated in
                    pod.change(jit: jit) { services in
                        if let i = services.firstIndex(where: { $0.name == name }) { services[i] = updated }
                    }
                    if selection == name { selection = updated.name }
                }
            }
        }
        .confirmationDialog(
            "Delete \(pod.deleteRequest ?? "")?",
            isPresented: Binding(get: { pod.deleteRequest != nil }, set: { if !$0 { pod.deleteRequest = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete Service and Its Disk", role: .destructive) {
                if let name = pod.deleteRequest {
                    if selection == name { selection = nil }
                    pod.change(jit: jit) { $0.removeAll { $0.name == name } }
                }
                pod.deleteRequest = nil
            }
        } message: {
            Text("What was installed in it goes; its image and /work stay.")
        }
        .sheet(isPresented: $showingSettings) { PodSettings() }
        .sheet(isPresented: $showingPodLog) { PodLogView() }
        .sheet(isPresented: $showingStorage) { StorageView() }
        .onChange(of: jit.state) { pod.jitChanged(jit) }
        .onAppear {
            pod.jitChanged(jit)
            // Checking without touch: --select NAME opens a service.
            let args = Checks.arguments
            if let i = args.firstIndex(of: "--select"), i + 1 < args.count { selection = args[i + 1] }
        }
        .onChange(of: pod.snapshot.pod) {
            // --run COMMAND runs in the selected service once the pod is up.
            pod.jitChanged(jit)
            // --windows N opens N terminal windows of the first service.
            if pod.snapshot.pod == .running, let n = Checks.take("--windows").flatMap(Int.init),
               let first = pod.spec.services.first {
                Task {
                    for _ in 0..<n {
                        try? await Task.sleep(for: .seconds(2))
                        openWindow(id: "terminal", value: TerminalTarget(service: first.name))
                    }
                }
            }
            if pod.snapshot.pod == .running, let name = Checks.take("--install-ssh"),
                let service = pod.spec.services.first(where: { $0.name == name }), service.sshPort == nil
            {
                pod.installSSH(service, jit: jit)
            }
            guard pod.snapshot.pod == .running, let name = selection,
                let service = pod.spec.services.first(where: { $0.name == name }),
                let command = Checks.take("--run")
            else { return }
            Task { await pod.run(command, in: service) }
        }
        .onOpenURL { _ in jit.cameToFront() }
    }

    /// JIT goes on by itself at launch, as in crate.
    /// A Compose file or folder dropped on Pier: imported and started at
    /// once when it fits; otherwise the preview opens.
    private func dropped(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if ComposeLoader.isDockerfile(url) {
            show("Dockerfiles: building images comes next, for now drop a compose.yaml", ok: false)
            return
        }
        switch ComposeLoader.load(url) {
        case .failure(let e):
            show(e.description, ok: false)
        case .success(let project):
            let taken = Set(pod.spec.services.map(\.name))
            guard !project.services.isEmpty, !project.needsFolder, !project.services.contains(where: { taken.contains($0.name) }) else {
                compose = .picked(url)
                return
            }
            do {
                try pod.runner.keepFiles(of: project)
            } catch {
                show("Could not copy the project's files: \(error.localizedDescription)", ok: false)
                return
            }
            let services = project.services
            pod.change(jit: jit) { $0 += services }
            if !pod.isActive && jit.isOn { pod.start(jit: jit) }
            selection = services.first?.name
            let n = services.count
            show("\(project.name): \(n) service\(n == 1 ? "" : "s") added, starting", ok: true)
        }
    }

    private func show(_ text: String, ok: Bool) {
        withAnimation(.spring(duration: 0.4)) { toast = (text, ok) }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeOut(duration: 0.3)) { toast = nil }
        }
    }
}

struct PodHeader: View {
    @Environment(PodModel.self) private var pod
    @Environment(JITSession.self) private var jit
    @Binding var showingLog: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(pod.snapshot.pod.label).font(.headline).lineLimit(2)
                Spacer()
                if let boot = pod.snapshot.bootSeconds, pod.snapshot.pod == .running {
                    Text(String(format: "booted in %.1f s", boot)).font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                if pod.isActive {
                    Button(role: .destructive) { pod.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .buttonStyle(.bordered)
                        .disabled(pod.snapshot.pod == .stopping)
                } else {
                    Button { pod.start(jit: jit) } label: { Label("Start", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(!jit.isOn || pod.spec.services.isEmpty)
                }
                Button { showingLog = true } label: { Label("Log", systemImage: "text.alignleft") }
                    .buttonStyle(.bordered)
            }
            JITStatus()
            if pod.isActive {
                // iPadOS ends an app whose last window is closed; minimizing keeps it.
                Label("Closing the last window stops the pod; minimize to keep it running.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let error = pod.lastError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch pod.snapshot.pod {
        case .running: .green
        case .failed: .red
        case .stopped: .secondary
        default: .orange
        }
    }
}

struct JITStatus: View {
    @Environment(JITSession.self) private var jit

    var body: some View {
        switch jit.state {
        case .on(let mb):
            Label("JIT on, \(mb) MB for code", systemImage: "bolt.fill")
                .font(.caption).foregroundStyle(.secondary)
        case .checking:
            Label("Checking JIT", systemImage: "hourglass").font(.caption).foregroundStyle(.secondary)
        default:
            VStack(alignment: .leading, spacing: 6) {
                Label(jit.isTurningOn ? "Turning JIT on" : "JIT is off", systemImage: "bolt.slash")
                    .font(.caption.bold())
                if let problem = jit.problem {
                    Text(problem).font(.caption).foregroundStyle(.secondary)
                }
                if !jit.isTurningOn {
                    Button("Turn On JIT") {
                        Task { await jit.turnOn(.builtInStikJIT) }
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

struct ServiceRow: View {
    @Environment(PodModel.self) private var pod
    let service: ServiceSpec

    var body: some View {
        let state = pod.state(of: service)
        HStack {
            Circle().fill(color(state)).frame(width: 8, height: 8)
            VStack(alignment: .leading) {
                Text(service.name).font(.body.monospaced())
                Text(service.image).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(state.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func color(_ state: ServiceState) -> Color {
        switch state {
        case .running: .green
        case .failed: .red
        case .exited(let code): code == 0 ? .secondary : .red
        case .stopped: .secondary
        default: .orange
        }
    }
}

struct ServiceDetail: View {
    @Environment(PodModel.self) private var pod
    @Environment(JITSession.self) private var jit
    let service: ServiceSpec
    @Environment(\.openURL) private var openURL
    @State private var tab = Tab.console
    @State private var fullScreen: TermTab?

    /// The service's selected shell, alone on the whole screen.
    private func openFullScreen() {
        if pod.selectedTerminal[service.name] == nil || !pod.terminals.contains(where: { $0.deck == service.name }) {
            pod.openTerminal(in: service)
        }
        guard let id = pod.selectedTerminal[service.name] else { return }
        fullScreen = pod.terminals.first { $0.id == id }
    }

    enum Tab { case console, log }

    var body: some View {
        let state = pod.state(of: service)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.image).font(.callout.monospaced()).textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                    Text(state.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if pod.snapshot.pod == .running {
                    if state == .running {
                        Button { pod.stopService(service) } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(.bordered)
                    } else if !state.isActive {
                        Button { pod.startService(service) } label: { Label("Start", systemImage: "play.fill") }
                            .buttonStyle(.bordered)
                    }
                }
                Button { openFullScreen() } label: { Label("Open Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.borderedProminent)
                    .disabled(state != .running)
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Menu {
                    ServiceMenu(service: service)
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
            }
            if !service.ports.isEmpty {
                PortChips(service: service)
            }
            if let cmd = pod.sshCommand(for: service) {
                HStack(spacing: 6) {
                    Text(cmd + "   password pier").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                    CopyButton(text: cmd).font(.caption)
                }
            }
            Picker("View", selection: $tab) {
                Text("Terminal").tag(Tab.console)
                Text("Log").tag(Tab.log)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            switch tab {
            case .console:
                ServiceTerminals(service: service, running: state == .running)
            case .log:
                LogText(log: pod.runner.log(for: service.name), tick: pod.tick)
            }
        }
        .padding()
        .navigationTitle(service.name)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pod.logRequest, initial: true) {
            if pod.logRequest == service.name {
                tab = .log
                pod.logRequest = nil
            }
        }
        .onChange(of: pod.snapshot.pod, initial: true) {
            if pod.snapshot.pod == .running, Checks.arguments.contains("--fullscreen"), Checks.has("--fullscreen") {
                openFullScreen()
            }
        }
        .fullScreenCover(item: $fullScreen) { t in
            FullScreenTerminal(pod: pod, service: service) { fullScreen = nil }
                .ignoresSafeArea()
        }
    }
}

/// Commands in a service, one after another like a terminal, the input at
/// the bottom.

/// A log that follows its end.
struct LogText: View {
    let log: LogBuffer
    let tick: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(log.text.isEmpty ? "No output yet." : log.text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id("end")
            }
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
            .onChange(of: tick) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

struct PodLogView: View {
    @Environment(PodModel.self) private var pod
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            LogText(log: pod.runner.podLog, tick: pod.tick)
                .padding()
                .navigationTitle("Pod Log")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .secondaryAction) {
                        ShareLink(item: pod.runner.podLog.text + "\n\n" + AppLog.contents())
                    }
                }
        }
    }
}

struct PodSettings: View {
    @Environment(PodModel.self) private var pod
    @Environment(\.dismiss) private var dismiss
    @State private var keepAlive = KeepAlive.shared.enabled

    var body: some View {
        @Bindable var pod = pod
        NavigationStack {
            Form {
                Section("Virtual machine") {
                    Stepper("CPUs: \(pod.spec.cpus)", value: $pod.spec.cpus, in: 1...8)
                    Stepper("Memory: \(pod.spec.memoryMiB) MB", value: $pod.spec.memoryMiB, in: 512...10240, step: 256)
                    Stepper("Shared /work: \(pod.spec.workVolumeGiB) GB", value: $pod.spec.workVolumeGiB, in: 1...256)
                }
                .disabled(pod.isActive)
                Section {
                    Toggle("Reachable from the network", isOn: $pod.spec.reachableFromNetwork)
                        .disabled(pod.isActive)
                } footer: {
                    Text("Off: forwarded ports answer only on this iPad (127.0.0.1). On: on every network the iPad is on, Wi-Fi and VPNs included.")
                }
                Section("Terminal") {
                    NavigationLink("Terminal Appearance") { AppearanceView() }
                }
                Section {
                    Toggle("Keep running in the background", isOn: $keepAlive)
                        .onChange(of: keepAlive) { KeepAlive.shared.enabled = keepAlive }
                } footer: {
                    Text("Uses coarse location updates, only to keep iPadOS from suspending Pier while the pod runs. Location is never stored or sent.")
                }
            }
            .navigationTitle("Pod Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// A value with a copy button.
struct CopyRow: View {
    let text: String
    var caption: String? = nil
    @State private var copied = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(text).font(.body.monospaced()).textSelection(.enabled)
                if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            CopyButton(text: text)
        }
    }
}

struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy \(text)")
    }
}

/// A service's forwarded ports: where each answers, to copy or open.
struct PortChips: View {
    @Environment(PodModel.self) private var pod
    @Environment(\.openURL) private var openURL
    let service: ServiceSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(service.ports, id: \.self) { port in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text(":" + String(port.container)).font(.caption.monospaced().bold())
                        Image(systemName: "arrow.left").font(.caption2).foregroundStyle(.secondary)
                        ForEach(pod.addresses(for: port), id: \.self) { address in
                            HStack(spacing: 4) {
                                Text(address).font(.caption.monospaced()).lineLimit(1)
                                CopyButton(text: address).font(.caption)
                            }
                            .fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: .capsule)
                        }
                        if PortInfo.isWeb(port.container) {
                            Button("Open") { openURL(URL(string: "http://127.0.0.1:\(port.host)")!) }
                                .font(.caption).buttonStyle(.bordered)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            }
        }
    }
}

enum PortInfo {
    static let names: [UInt16: String] = [
        22: "SSH", 2222: "SSH", 80: "HTTP", 443: "HTTPS", 8080: "HTTP", 8000: "HTTP", 3000: "HTTP",
        5173: "Vite", 5432: "PostgreSQL", 3306: "MySQL", 6379: "Redis", 27017: "MongoDB", 9000: "HTTP",
    ]
    static func isWeb(_ p: UInt16) -> Bool { [80, 8080, 8000, 3000, 5173, 9000, 4000, 5000, 8888].contains(p) }
    static func name(_ p: UInt16) -> String { names[p] ?? "" }
}

/// The right-click / long-press menu of a service.
/// Everything that can be done to a service, in one menu: the ⋯ button on
/// its page and a long press (or right click) on it in the list.
struct ServiceMenu: View {
    @Environment(PodModel.self) private var pod
    @Environment(JITSession.self) private var jit
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow
    let service: ServiceSpec

    var body: some View {
        let state = pod.state(of: service)
        let running = state == .running
        Section {
            if running {
                Button { pod.stopService(service) } label: { Label("Stop", systemImage: "stop.fill") }
                Button { pod.startService(service) } label: { Label("Restart", systemImage: "arrow.clockwise") }
            } else {
                Button { pod.startService(service) } label: { Label("Start", systemImage: "play.fill") }
                    .disabled(pod.snapshot.pod != .running || state.isActive)
            }
        }
        Section {
            if service.sshPort == nil {
                Button { pod.installSSH(service, jit: jit) } label: { Label("Install SSH + tmux", systemImage: "key") }
                    .disabled(!running || pod.installingSSH.contains(service.name))
            }
            Button { pod.installTmux(service) } label: { Label("Install tmux", systemImage: "rectangle.split.3x1") }
                .disabled(!running || pod.installingSSH.contains(service.name))
        }
        Menu {
            if let cmd = pod.sshCommand(for: service) {
                Button { UIPasteboard.general.string = cmd } label: { Label("SSH Command", systemImage: "terminal") }
            }
            if let ip = pod.spec.serviceAddresses[service.name] {
                Button { UIPasteboard.general.string = ip } label: { Label(ip, systemImage: "network") }
            }
            ForEach(service.ports, id: \.self) { port in
                ForEach(pod.addresses(for: port), id: \.self) { address in
                    Button { UIPasteboard.general.string = address } label: { Label(address, systemImage: "link") }
                }
            }
            Button { UIPasteboard.general.string = service.image } label: { Label("Image", systemImage: "shippingbox") }
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        Section {
            Button { openWindow(id: "terminal", value: TerminalTarget(service: service.name)) } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
        }
        Section {
            Button { pod.editRequest = service.name } label: { Label("Edit...", systemImage: "pencil") }
            Button { pod.reset(service) } label: { Label("Unpack Image Again", systemImage: "arrow.counterclockwise") }
                .disabled(pod.isActive)
        }
        Section {
            Button(role: .destructive) { pod.deleteRequest = service.name } label: { Label("Delete Service...", systemImage: "trash") }
        }
    }
}

/// Every address and port of the pod on one page.
struct NetworkView: View {
    @Environment(PodModel.self) private var pod
    @Environment(\.openURL) private var openURL
    @State private var listening: [String: [UInt16]]?
    @State private var checking = false

    var body: some View {
        let forwarded = pod.spec.services.flatMap { s in s.ports.map { (s, $0) } }
        List {
            Section("This iPad") {
                ForEach(["127.0.0.1"] + NetworkAddresses.current(), id: \.self) { ip in
                    CopyRow(text: ip, caption: ip == "127.0.0.1" ? "apps on this iPad (Safari, SSH apps)" : (pod.spec.reachableFromNetwork ? "other devices reach the pod here" : "ports are not open here: turn on Reachable from the network"))
                }
            }
            Section {
                if forwarded.isEmpty {
                    Text("No ports forwarded. Add HOST:CONTAINER ports to a service.").foregroundStyle(.secondary)
                }
                ForEach(forwarded, id: \.1) { service, port in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(service.name).font(.body.monospaced().bold())
                            Text("\(PortInfo.name(port.container)) :\(String(port.container)) inside").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(width: 170, alignment: .leading)
                        Circle().fill(dot(for: port, of: service)).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(pod.addresses(for: port), id: \.self) { address in
                                HStack {
                                    Text(address).font(.callout.monospaced()).textSelection(.enabled)
                                    CopyButton(text: address)
                                    if PortInfo.isWeb(port.container) {
                                        Button { openURL(URL(string: "http://\(address)")!) } label: { Image(systemName: "safari") }
                                            .buttonStyle(.borderless)
                                    }
                                }
                            }
                        }
                        Spacer()
                    }
                }
            } header: {
                Text("Forwarded ports")
            } footer: {
                Text("Green: the service listens on it. Grey: nothing listens yet, or the service is stopped.")
            }
            Section {
                let addresses = pod.spec.serviceAddresses
                ForEach(pod.spec.services) { service in
                    let fwd = Set(service.ports.map(\.container))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Circle().fill(pod.state(of: service) == .running ? Color.green : .secondary).frame(width: 8, height: 8)
                            Text(service.name).font(.body.monospaced().bold())
                            Spacer()
                            if let ip = addresses[service.name] {
                                Text(ip).font(.callout.monospaced()).textSelection(.enabled)
                                CopyButton(text: ip)
                            }
                        }
                        if let ports = listening?[service.name] {
                            if ports.isEmpty {
                                Text("listens on nothing yet").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(ports, id: \.self) { p in
                                HStack {
                                    Text(":" + String(p)).font(.callout.monospaced())
                                    Text(PortInfo.name(p)).font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    if let ip = addresses[service.name] {
                                        Text(ip + ":" + String(p)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        CopyButton(text: "\(ip):\(p)")
                                    }
                                    Text(fwd.contains(p) ? "forwarded" : "inside only")
                                        .font(.caption).foregroundStyle(fwd.contains(p) ? .green : .secondary)
                                }
                                .padding(.leading, 16)
                            }
                        } else if pod.state(of: service) != .running {
                            Text("not running").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Services")
                    Spacer()
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(checking || pod.snapshot.pod != .running)
                }
            }
            Section("Inside the pod") {
                Text(pod.spec.usesSeparateNetworks
                     ? "Each service has an address of its own on 172.20.0.0/24, as with Docker: they reach each other by name (db:5432) or address, and two services may use the same port. The iPad is 10.0.2.2 from inside."
                     : "Services share one network: they reach each other by name, e.g. db:5432, or at 127.0.0.1. The pod is 10.0.2.15; the iPad is 10.0.2.2 from inside.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Addresses and Ports")
        .task(id: pod.snapshot.pod) { await refresh() }
    }

    private func dot(for port: PortMapping, of service: ServiceSpec) -> Color {
        guard let ports = listening?[service.name] else { return .secondary }
        return ports.contains(port.container) ? .green : .secondary
    }

    private func refresh() async {
        guard pod.snapshot.pod == .running else { listening = nil; return }
        checking = true
        listening = await pod.listeningPorts()
        checking = false
    }
}

/// Launch arguments for checking Pier without touch (`--autostart`,
/// `--demo-pod`, `--select`, `--run`, `--install-ssh`, `--windows`, `--close-windows`, `--split`, `--suggest-test`, `--switcher`). They count only when
/// the launch also sets PIER_CHECKS=1, which tapping the icon never does, and
/// each acts once per launch.
enum Checks {
    static let enabled = ProcessInfo.processInfo.environment["PIER_CHECKS"] == "1"
    static var arguments: [String] { enabled ? ProcessInfo.processInfo.arguments : [] }
    nonisolated(unsafe) private static var used: Set<String> = []

    static func has(_ flag: String) -> Bool {
        guard arguments.contains(flag), !used.contains(flag) else { return false }
        used.insert(flag)
        return true
    }

    static func take(_ flag: String) -> String? {
        let args = arguments
        guard !used.contains(flag), let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        used.insert(flag)
        return args[i + 1]
    }
}

