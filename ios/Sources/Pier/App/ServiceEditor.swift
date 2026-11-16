import PierCore
import SwiftUI

/// Adds a service, from a template or by hand, or edits one.
struct ServiceEditor: View {
    let original: ServiceSpec?
    let save: (ServiceSpec) -> Void
    @Environment(PodModel.self) private var pod
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var image = ""
    @State private var command = ""
    @State private var environment = ""
    @State private var ports = ""
    @State private var memory: UInt64 = 512
    @State private var mountsWork = true
    @State private var honestScanning = false
    @State private var showingCatalog = false
    @State private var picked: String?

    var body: some View {
        NavigationStack {
            Form {
                if original == nil {
                    Section {
                        Button { showingCatalog = true } label: {
                            HStack {
                                Label(picked ?? "Choose from Catalog", systemImage: "square.grid.2x2")
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    } footer: {
                        Text("Databases, web servers, languages, Linux systems and developer tools, ready to run. Or fill in any image below.")
                    }
                }
                Section {
                    TextField("Name", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onChange(of: name) {
                            let clean = Self.cleanName(name)
                            if clean != name { name = clean }
                        }
                    TextField("Image, e.g. docker.io/library/redis:7-alpine", text: $image)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Stepper("Memory: \(memory) MB", value: $memory, in: 64...8192, step: 64)
                    Toggle("Mount the shared /work", isOn: $mountsWork)
                } header: {
                    Text("Service")
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    }
                }
                Section {
                    Toggle("Honest network scans", isOn: $honestScanning)
                } footer: {
                    Text("Network traffic leaves through the iPad's NAT, which answers some probes for any address, so nmap would find every host up. On: nmap looks for hosts with ping and TCP SYN instead, which tell the truth. Port scans work either way; nmap's OS detection can't see past the NAT.")
                }
                Section {
                    TextField("Command (empty: the image's own)", text: $command, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                } footer: {
                    Text("Run through /bin/sh -c.")
                }
                Section {
                    TextField("Ports, e.g. 8080:80 5432", text: $ports)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                } footer: {
                    Text("HOST:CONTAINER, separated by spaces. Services reach each other by name: db:5432.")
                }
                Section("Environment") {
                    TextField("KEY=value, one per line", text: $environment, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().font(.body.monospaced())
                }
            }
            .navigationTitle(original == nil ? "Add Service" : "Edit \(original!.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(original == nil ? "Add" : "Save") {
                        if let s = built { save(s); dismiss() }
                    }
                    .disabled(built == nil)
                }
            }
            .onAppear { if let original { apply(original) } }
            .sheet(isPresented: $showingCatalog) {
                CatalogView { t in
                    picked = t.title
                    apply(t.service)
                }
            }
        }
    }

    /// Lowercase letters, digits and dashes: what a container ID and host name take.
    static func cleanName(_ text: String) -> String {
        var out = ""
        for c in text.lowercased() {
            if c.isASCII && (c.isLetter || c.isNumber) {
                out.append(c)
            } else if !out.isEmpty && out.last != "-" {
                out.append("-")
            }
        }
        return String(out.prefix(63))
    }

    private func apply(_ s: ServiceSpec) {
        var n = s.name
        if original == nil {
            var i = 2
            while pod.spec.services.contains(where: { $0.name == n }) {
                n = "\(s.name)\(i)"
                i += 1
            }
        }
        name = n
        image = s.image
        if s.command.count == 3, s.command[0] == "/bin/sh", s.command[1] == "-c" {
            command = s.command[2]
        } else {
            command = s.command.joined(separator: " ")
        }
        environment = s.environment.joined(separator: "\n")
        ports = s.ports.map(\.description).joined(separator: " ")
        memory = s.memoryMiB
        mountsWork = s.mountsWork
        honestScanning = s.honestScanning ?? false
    }

    private var parsedPorts: [PortMapping]? {
        var out: [PortMapping] = []
        for part in ports.split(whereSeparator: { $0 == " " || $0 == "," }) {
            guard let p = PortMapping(String(part)) else { return nil }
            out.append(p)
        }
        return out
    }

    private var problem: String? {
        if name.isEmpty || image.isEmpty { return nil }
        if !ServiceSpec.isValidName(name) { return "Names use lowercase letters, digits and dashes." }
        if original?.name != name, pod.spec.services.contains(where: { $0.name == name }) {
            return "There is a service called \(name) already."
        }
        if parsedPorts == nil { return "Ports look like 8080:80 or 5432." }
        return nil
    }

    private var built: ServiceSpec? {
        guard !name.isEmpty, !image.isEmpty, problem == nil, let ports = parsedPorts else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        // What the form doesn't show (SSH, Compose's volumes, healthchecks and
        // the rest) stays as it was.
        var s = original ?? ServiceSpec(name: name, image: image)
        s.name = name
        s.image = image.trimmingCharacters(in: .whitespaces)
        s.command = trimmed.isEmpty ? [] : ["/bin/sh", "-c", trimmed]
        s.environment = environment.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("=") }
        s.ports = ports
        s.memoryMiB = memory
        s.mountsWork = mountsWork
        s.honestScanning = honestScanning ? true : nil
        return s
    }
}

/// Every template, in groups, searchable; a tap picks one.
struct CatalogView: View {
    let pick: (Template) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private func matches(_ t: Template) -> Bool {
        query.isEmpty || [t.title, t.summary, t.service.image].contains { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(Templates.groups) { group in
                    let shown = group.templates.filter(matches)
                    if !shown.isEmpty {
                        Section {
                            ForEach(shown) { t in
                                Button {
                                    pick(t)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(t.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                                        Text(t.summary).font(.caption).foregroundStyle(.secondary)
                                        Text(t.service.image).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        } header: {
                            Label(group.title, systemImage: group.symbol)
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search images")
            .navigationTitle("Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
