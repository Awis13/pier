import Foundation
import Yams

/// A Docker Compose file read into Pier's services.
///
/// Supported: image, command, entrypoint, environment, env_file, ports,
/// expose (nothing to do: every port is reachable inside the pod), volumes
/// (named ones and files or directories next to the Compose file, both kept
/// in /work), depends_on with conditions, healthcheck, restart, working_dir,
/// user, privileged, hostname, container_name and network aliases (extra
/// names), mem_limit and deploy memory limits, profiles (left out, as
/// Compose does by default), `${VAR}` from `.env`, YAML anchors and `<<`.
/// Everything else is named in `warnings`.
public struct ComposeProject: Sendable {
    public var name: String
    public var services: [ServiceSpec]
    public var warnings: [String]
    /// Files and directories next to the Compose file that services bind:
    /// their place on this device, and where Pier keeps a copy (relative to
    /// its data directory).
    public var copies: [(from: URL, to: String)]
    /// Read without its folder, yet it binds files, reads env files or uses
    /// variables nobody set: it would not run as written.
    public var needsFolder = false

    public static let fileNames = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"]

    /// Reads a Compose file. `directory` is where it lives, for `.env`,
    /// `env_file` and bind mounts; without one those are reported.
    public static func parse(_ text: String, directory: URL?, projectName: String? = nil) throws -> ComposeProject {
        guard let root = try Yams.load(yaml: text) as? [String: Any] else {
            throw PierError("this is not a Compose file: no mapping at the top")
        }
        var reader = Reader(directory: directory)
        reader.variables = reader.loadDotEnv()
        let doc = reader.resolveMerges(root) as? [String: Any] ?? root
        let project = ServiceName.clean(projectName ?? (doc["name"] as? String) ?? directory?.lastPathComponent ?? "compose")
        reader.project = project.isEmpty ? "compose" : project

        guard let services = doc["services"] as? [String: Any], !services.isEmpty else {
            throw PierError("the Compose file has no services")
        }
        for key in doc.keys.sorted() where !["services", "volumes", "networks", "name", "version"].contains(key) && !key.hasPrefix("x-") {
            reader.warn("\(key): not supported, left out")
        }
        if let networks = doc["networks"] as? [String: Any], !networks.isEmpty {
            reader.warn("networks: all services share one network in Pier, each with its own address")
        }

        // Names first: services refer to each other by them.
        var names: [String: String] = [:]
        var taken: Set<String> = []
        // Keys already in Pier's form keep their name; the rest give way.
        let keys = services.keys.sorted()
        for key in keys.filter({ ServiceName.clean($0) == $0 }) + keys.filter({ ServiceName.clean($0) != $0 }) {
            let base = ServiceName.clean(key)
            var name = base
            var n = 2
            while taken.contains(name) {
                name = "\(base)-\(n)"
                n += 1
            }
            if name != base { reader.warn("\(key): \(base) is taken by another service, called \(name)") }
            taken.insert(name)
            names[key] = name
        }

        var out: [ServiceSpec] = []
        for key in services.keys.sorted() {
            guard let raw = services[key] as? [String: Any] else {
                reader.warn("\(key): not a mapping, left out")
                continue
            }
            let svc = reader.interpolate(raw) as? [String: Any] ?? raw
            if let profiles = svc["profiles"] as? [Any], !profiles.isEmpty {
                reader.warn("\(key): has profiles, left out as Compose does without --profile")
                continue
            }
            if let s = try reader.service(key, svc, name: names[key]!, names: names) {
                out.append(s)
            }
        }
        out = reader.ordered(out)
        reader.unset = reader.missing.set
        for v in reader.unset.sorted() {
            reader.warn("${\(v)} is not set\(directory == nil ? " (it may be in .env next to the file)" : ""); empty is used")
        }
        var result = ComposeProject(name: reader.project, services: out, warnings: reader.warnings, copies: reader.copies)
        result.needsFolder = directory == nil && (reader.wantedFiles || !reader.unset.isEmpty)
        return result
    }

    /// A name as Pier allows it: lowercase letters, digits and dashes.
    public static func cleanName(_ s: String) -> String { ServiceName.clean(s) }

    /// Finds the Compose file in a directory.
    public static func file(in directory: URL) -> URL? {
        for n in fileNames {
            let u = directory.appendingPathComponent(n)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }
}

enum ServiceName {
    /// Pier's names: lowercase letters, digits and dashes.
    static func clean(_ s: String) -> String {
        var out = ""
        for c in s.lowercased() {
            if c.isASCII && (c.isLetter || c.isNumber) { out.append(c) } else if !out.hasSuffix("-") { out.append("-") }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(63))
    }
}

private struct Reader {
    let directory: URL?
    var project = "compose"
    var variables: [String: String] = [:]
    var warnings: [String] = []
    var copies: [(from: URL, to: String)] = []
    /// Variables used without a value or a default.
    var unset: Set<String> = []
    /// It binds files or reads env files next to it.
    var wantedFiles = false

    init(directory: URL?) { self.directory = directory }

    mutating func warn(_ s: String) { warnings.append(s) }

    // MARK: Variables

    func loadDotEnv() -> [String: String] {
        guard let directory else { return [:] }
        return (try? Self.envFile(directory.appendingPathComponent(".env"))) ?? [:]
    }

    static func envFile(_ url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") { continue }
            if l.hasPrefix("export ") { l = String(l.dropFirst(7)) }
            guard let eq = l.firstIndex(of: "=") else { continue }
            let k = l[..<eq].trimmingCharacters(in: .whitespaces)
            var v = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, f == "\"" || f == "'", v.last == f {
                v = String(v.dropFirst().dropLast())
            } else if let hash = v.range(of: " #") {
                v = v[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            out[k] = v
        }
        return out
    }

    final class Names: @unchecked Sendable { var set: Set<String> = [] }
    let missing = Names()

    /// `${VAR}`, `${VAR:-default}`, `${VAR-default}`, `${VAR:?err}`, `$VAR`, `$$`.
    func substitute(_ s: String) -> String {
        guard s.contains("$") else { return s }
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "$" else { out.append(c); i = s.index(after: i); continue }
            let n = s.index(after: i)
            guard n < s.endIndex else { out.append("$"); break }
            if s[n] == "$" { out.append("$"); i = s.index(after: n); continue }
            if s[n] == "{", let close = s[n...].firstIndex(of: "}") {
                let body = String(s[s.index(after: n)..<close])
                out += expand(body)
                i = s.index(after: close)
                continue
            }
            var j = n
            while j < s.endIndex, s[j].isLetter || s[j].isNumber || s[j] == "_" { j = s.index(after: j) }
            if j == n { out.append("$"); i = n; continue }
            let name = String(s[n..<j])
            if variables[name] == nil { missing.set.insert(name) }
            out += variables[name] ?? ""
            i = j
        }
        return out
    }

    private func expand(_ body: String) -> String {
        for op in [":-", "-", ":?", "?", ":+", "+"] {
            if let r = body.range(of: op) {
                let name = String(body[..<r.lowerBound])
                guard name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
                let arg = substitute(String(body[r.upperBound...]))
                let v = variables[name]
                switch op {
                case ":-": return (v?.isEmpty ?? true) ? arg : v!
                case "-": return v ?? arg
                case ":+": return (v?.isEmpty ?? true) ? "" : arg
                case "+": return v == nil ? "" : arg
                default:
                    if v == nil { missing.set.insert(name) }
                    return v ?? ""
                }
            }
        }
        if variables[body] == nil { missing.set.insert(body) }
        return variables[body] ?? ""
    }

    func interpolate(_ v: Any) -> Any {
        switch v {
        case let s as String: return substitute(s)
        case let a as [Any]: return a.map(interpolate)
        case let d as [String: Any]: return d.mapValues(interpolate)
        default: return v
        }
    }

    /// YAML merge keys (`<<: *defaults`), which the loader leaves as keys.
    func resolveMerges(_ v: Any) -> Any {
        switch v {
        case let a as [Any]: return a.map(resolveMerges)
        case var d as [String: Any]:
            if let merge = d.removeValue(forKey: "<<") {
                let bases = (merge as? [Any]) ?? [merge]
                for base in bases.reversed() {
                    if let b = resolveMerges(base) as? [String: Any] {
                        for (k, val) in b where d[k] == nil { d[k] = val }
                    }
                }
            }
            return d.mapValues(resolveMerges)
        default: return v
        }
    }

    // MARK: Values

    static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let i as Int: return String(i)
        case let d as Double: return d == d.rounded() ? String(Int(d)) : String(d)
        case let b as Bool: return b ? "true" : "false"
        default: return nil
        }
    }

    /// A command as Compose reads it: a list as is, a string split like a shell.
    static func command(_ v: Any?) -> [String]? {
        if let a = v as? [Any] { return a.compactMap { string($0) } }
        if let s = v as? String { return shellSplit(s) }
        return nil
    }

    static func shellSplit(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var has = false
        var quote: Character?
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if let q = quote {
                if c == q { quote = nil }
                else if c == "\\" && q == "\"", s.index(after: i) < s.endIndex { i = s.index(after: i); cur.append(s[i]) }
                else { cur.append(c) }
            } else if c == "'" || c == "\"" { quote = c; has = true }
            else if c == "\\", s.index(after: i) < s.endIndex { i = s.index(after: i); cur.append(s[i]); has = true }
            else if c.isWhitespace { if has || !cur.isEmpty { out.append(cur); cur = ""; has = false } }
            else { cur.append(c) }
            i = s.index(after: i)
        }
        if has || !cur.isEmpty { out.append(cur) }
        return out
    }

    /// "30s", "1m30s", "500ms", "2h" in seconds.
    static func duration(_ v: Any?) -> Double? {
        if let n = v as? Int { return Double(n) }
        guard let s = string(v) else { return nil }
        var total = 0.0
        var num = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c.isNumber || c == "." { num.append(c); i = s.index(after: i); continue }
            var unit = String(c)
            let n = s.index(after: i)
            if c == "m", n < s.endIndex, s[n] == "s" { unit = "ms"; i = n }
            else if c == "u" || c == "µ", n < s.endIndex, s[n] == "s" { unit = "us"; i = n }
            let x = Double(num) ?? 0
            switch unit {
            case "h": total += x * 3600
            case "m": total += x * 60
            case "s": total += x
            case "ms": total += x / 1000
            case "us": total += x / 1_000_000
            default: break
            }
            num = ""
            i = s.index(after: i)
        }
        if !num.isEmpty { total += Double(num) ?? 0 }
        return total
    }

    /// "512m", "1g", "1G", "268435456" in MiB.
    static func mebibytes(_ v: Any?) -> UInt64? {
        if let n = v as? Int { return UInt64(max(n, 0)) >> 20 }
        guard var s = string(v)?.lowercased().trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasSuffix("b") { s.removeLast() }
        let mult: Double
        switch s.last {
        case "k": mult = 1.0 / 1024; s.removeLast()
        case "m": mult = 1; s.removeLast()
        case "g": mult = 1024; s.removeLast()
        case "t": mult = 1024 * 1024; s.removeLast()
        default: mult = 1.0 / 1_048_576
        }
        guard let x = Double(s) else { return nil }
        return UInt64((x * mult).rounded(.up))
    }

    // MARK: Services

    mutating func service(_ key: String, _ s: [String: Any], name: String, names: [String: String]) throws -> ServiceSpec? {
        guard !name.isEmpty else { warn("\(key): no usable name, left out"); return nil }
        if name != key { warn("\(key): called \(name) in Pier; \(key) still resolves") }
        guard let image = Self.string(s["image"]), !image.isEmpty else {
            if s["build"] != nil {
                warn("\(key): build: is not supported yet (needs an image), left out")
            } else {
                warn("\(key): no image, left out")
            }
            return nil
        }
        if s["build"] != nil { warn("\(key): build: ignored, the image \(image) is used") }

        var spec = ServiceSpec(name: name, image: image, memoryMiB: 1024)
        var aliases: [String] = []
        if name != key { aliases.append(key) }

        let known: Set<String> = [
            "image", "build", "command", "entrypoint", "environment", "env_file", "ports", "expose", "volumes",
            "depends_on", "healthcheck", "restart", "working_dir", "user", "privileged", "hostname", "container_name",
            "networks", "mem_limit", "deploy", "profiles", "labels", "stdin_open", "tty", "init", "stop_signal",
            "stop_grace_period", "logging", "platform", "pull_policy", "cap_add", "domainname",
        ]
        for k in s.keys.sorted() where !known.contains(k) && !k.hasPrefix("x-") {
            warn("\(key): \(k) is not supported, ignored")
        }

        if let e = Self.command(s["entrypoint"]) { spec.entrypoint = e }
        if let c = Self.command(s["command"]) { spec.args = c }
        if let wd = Self.string(s["working_dir"]), !wd.isEmpty { spec.workingDir = wd }
        if let u = Self.string(s["user"]), !u.isEmpty { spec.user = u }
        if (s["privileged"] as? Bool) == true { spec.privileged = true }
        if let caps = s["cap_add"] as? [Any], caps.compactMap({ Self.string($0)?.uppercased() }).contains(where: { $0 == "ALL" || $0 == "SYS_ADMIN" || $0 == "NET_ADMIN" }) {
            spec.privileged = true
            warn("\(key): cap_add gives it every capability in Pier")
        }
        if let p = Self.string(s["platform"]), !p.contains("arm64") && !p.contains("aarch64") {
            warn("\(key): platform \(p) ignored, Pier runs linux/arm64")
        }
        for k in ["hostname", "container_name"] {
            if let h = Self.string(s[k]) {
                let c = ServiceName.clean(h)
                if !c.isEmpty && c != name { aliases.append(h) }
            }
        }
        if let nets = s["networks"] as? [String: Any] {
            for case let n as [String: Any] in nets.values {
                for case let a as String in (n["aliases"] as? [Any]) ?? [] { aliases.append(a) }
            }
        }
        let allNames = Array(Set(aliases)).sorted()
        if !allNames.isEmpty { spec.aliases = allNames }

        // Environment: env_file first, environment over it.
        var env: [(String, String?)] = []
        for f in envFiles(s["env_file"]) {
            guard let directory else { wantedFiles = true; warn("\(key): env_file \(f.path) needs the Compose file's folder"); continue }
            let url = Self.resolve(f.path, in: directory)
            do {
                let vars = try Self.envFile(url)
                for k in vars.keys.sorted() { env.append((k, substitute(vars[k]!))) }
            } catch {
                if f.required { warn("\(key): env_file \(f.path) could not be read") }
            }
        }
        if let d = s["environment"] as? [String: Any] {
            for k in d.keys.sorted() { env.append((k, d[k].flatMap { Self.string($0) })) }
        } else if let a = s["environment"] as? [Any] {
            for case let item as String in a {
                if let eq = item.firstIndex(of: "=") {
                    env.append((String(item[..<eq]), String(item[item.index(after: eq)...])))
                } else {
                    env.append((item, nil))
                }
            }
        }
        var seen: [String: String] = [:]
        var order: [String] = []
        for (k, v) in env {
            let value = v ?? variables[k]
            guard let value else { continue }
            if seen[k] == nil { order.append(k) }
            seen[k] = value
        }
        spec.environment = order.map { "\($0)=\(seen[$0]!)" }

        spec.ports = ports(key, s["ports"])

        if let m = Self.mebibytes(s["mem_limit"]) { spec.memoryMiB = max(m, 64) }
        if let deploy = s["deploy"] as? [String: Any] {
            if let r = deploy["resources"] as? [String: Any], let l = r["limits"] as? [String: Any], let m = Self.mebibytes(l["memory"]) {
                spec.memoryMiB = max(m, 64)
            }
            if let n = deploy["replicas"] as? Int, n != 1 { warn("\(key): replicas \(n) ignored, one runs") }
        }

        if let r = Self.string(s["restart"]) {
            let base = r.split(separator: ":").first.map(String.init) ?? r
            if let p = RestartPolicy(rawValue: base) { spec.restart = p } else { warn("\(key): restart \(r) not understood") }
        }

        // depends_on: a list, or a mapping with conditions.
        var deps: [Dependency] = []
        if let a = s["depends_on"] as? [Any] {
            for case let d as String in a { if let n = names[d] { deps.append(Dependency(service: n)) } else { warn("\(key): depends on \(d), which is not here") } }
        } else if let m = s["depends_on"] as? [String: Any] {
            for d in m.keys.sorted() {
                guard let n = names[d] else { warn("\(key): depends on \(d), which is not here"); continue }
                let cond = ((m[d] as? [String: Any])?["condition"] as? String).flatMap(Dependency.Condition.init(rawValue:)) ?? .started
                deps.append(Dependency(service: n, condition: cond))
            }
        }
        if !deps.isEmpty { spec.dependsOn = deps }

        if let h = s["healthcheck"] as? [String: Any], (h["disable"] as? Bool) != true {
            var test: [String] = []
            var shell = true
            if let a = h["test"] as? [Any] {
                let parts = a.compactMap { Self.string($0) }
                switch parts.first {
                case "NONE": test = []
                case "CMD": test = Array(parts.dropFirst()); shell = false
                case "CMD-SHELL": test = [parts.dropFirst().joined(separator: " ")]
                default: test = parts; shell = false
                }
            } else if let t = h["test"] as? String {
                test = [t]
            }
            if !test.isEmpty {
                spec.healthcheck = Healthcheck(
                    test: test, shell: shell,
                    intervalSeconds: Self.duration(h["interval"]) ?? 30,
                    timeoutSeconds: Self.duration(h["timeout"]) ?? 30,
                    retries: (h["retries"] as? Int) ?? 3,
                    startPeriodSeconds: Self.duration(h["start_period"]) ?? 0)
            }
        }

        let vols = volumes(key, s["volumes"])
        if !vols.isEmpty { spec.volumes = vols }
        return spec
    }

    private func envFiles(_ v: Any?) -> [(path: String, required: Bool)] {
        if let s = v as? String { return [(s, true)] }
        guard let a = v as? [Any] else { return [] }
        return a.compactMap { item in
            if let s = item as? String { return (s, true) }
            if let d = item as? [String: Any], let p = d["path"] as? String { return (p, (d["required"] as? Bool) ?? true) }
            return nil
        }
    }

    mutating func ports(_ key: String, _ v: Any?) -> [PortMapping] {
        guard let list = v as? [Any] else { return [] }
        var out: [PortMapping] = []
        for item in list {
            var host: String?
            var target: String
            var proto = "tcp"
            if let d = item as? [String: Any] {
                guard let t = Self.string(d["target"]) else { continue }
                target = t
                host = Self.string(d["published"])
                proto = Self.string(d["protocol"]) ?? "tcp"
            } else if let s = Self.string(item) {
                var text = s
                if let slash = text.lastIndex(of: "/") {
                    proto = String(text[text.index(after: slash)...])
                    text = String(text[..<slash])
                }
                // [ip:]host:container, the IP possibly in brackets.
                var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                if text.hasPrefix("[") , let close = text.firstIndex(of: "]") {
                    let rest = text[text.index(after: close)...].dropFirst()
                    parts = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                } else if parts.count == 3 {
                    parts.removeFirst()
                }
                target = parts.last ?? ""
                if parts.count == 2, !parts[0].isEmpty { host = parts[0] }
            } else {
                continue
            }
            guard proto == "tcp" else { warn("\(key): port \(target)/\(proto) left out, Pier forwards TCP"); continue }
            let targets = Self.range(target)
            let hosts = host.map(Self.range) ?? targets
            guard !targets.isEmpty else { warn("\(key): port \(target) not understood"); continue }
            if hosts.count == targets.count {
                for (h, t) in zip(hosts, targets) { out.append(PortMapping(host: h, container: t)) }
            } else if let h = hosts.first {
                out.append(PortMapping(host: h, container: targets[0]))
            }
        }
        return out
    }

    static func range(_ s: String) -> [UInt16] {
        let p = s.split(separator: "-").map { UInt16($0.trimmingCharacters(in: .whitespaces)) }
        if p.count == 1, let a = p[0] { return [a] }
        if p.count == 2, let a = p[0], let b = p[1], a <= b, b - a < 1000 { return Array(a...b) }
        return []
    }

    mutating func volumes(_ key: String, _ v: Any?) -> [VolumeMount] {
        guard let list = v as? [Any] else { return [] }
        var out: [VolumeMount] = []
        for item in list {
            var source = ""
            var target = ""
            var readOnly = false
            var type = ""
            if let d = item as? [String: Any] {
                type = Self.string(d["type"]) ?? ""
                source = Self.string(d["source"]) ?? ""
                target = Self.string(d["target"]) ?? ""
                readOnly = (d["read_only"] as? Bool) ?? false
            } else if let s = item as? String {
                let parts = s.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
                if parts.count == 1 { target = parts[0] } else { source = parts[0]; target = parts[1] }
                if parts.count > 2 { readOnly = parts[2].split(separator: ",").contains("ro") }
            }
            guard !target.isEmpty else { continue }
            if type == "tmpfs" { warn("\(key): tmpfs \(target) is a plain directory in Pier"); continue }
            if source.isEmpty {
                // Anonymous: kept with the service, like the rest of its files.
                continue
            }
            let isPath = source.hasPrefix(".") || source.hasPrefix("/") || source.hasPrefix("~") || type == "bind"
            if !isPath {
                let vol = ServiceName.clean(source)
                out.append(VolumeMount(source: ".pier/volumes/\(project)-\(vol)", target: target, readOnly: readOnly))
                continue
            }
            guard let directory, !source.hasPrefix("/"), !source.hasPrefix("~") else {
                if source.hasPrefix("/var/run/docker.sock") || source.hasPrefix("/run/docker.sock") {
                    warn("\(key): \(source) left out, there is no Docker daemon")
                } else if directory == nil {
                    wantedFiles = true
                    warn("\(key): \(source) left out: open the Compose file's folder to bring files along")
                } else {
                    warn("\(key): \(source) is outside the project, a fresh directory in /work is used")
                    out.append(VolumeMount(source: ".pier/volumes/\(project)-\(ServiceName.clean(source))", target: target, readOnly: readOnly))
                }
                continue
            }
            let url = Self.resolve(source, in: directory)
            let rel = Self.relative(url, to: directory.standardizedFileURL)
            guard let rel else {
                warn("\(key): \(source) is outside the project folder, left out")
                continue
            }
            let inWork = rel == "." ? ".pier/projects/\(project)" : ".pier/projects/\(project)/\(rel)"
            if FileManager.default.fileExists(atPath: url.path) {
                let kept = rel == "." ? "projects/\(project)" : "projects/\(project)/\(rel)"
                if !copies.contains(where: { $0.to == kept }) { copies.append((url, kept)) }
                out.append(VolumeMount(source: inWork, target: target, readOnly: readOnly, files: kept))
            } else {
                // Docker makes a missing bind source a directory.
                out.append(VolumeMount(source: inWork, target: target, readOnly: readOnly))
            }
        }
        return out
    }

    /// A path of the Compose file, relative to its folder (whether or not the
    /// folder's URL ends in a slash).
    static func resolve(_ path: String, in dir: URL) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL
            : dir.appendingPathComponent(path).standardizedFileURL
    }

    static func relative(_ url: URL, to dir: URL) -> String? {
        let base = dir.path.hasSuffix("/") ? dir.path : dir.path + "/"
        if url.path == dir.path { return "." }
        guard url.path.hasPrefix(base) else { return nil }
        return String(url.path.dropFirst(base.count))
    }

    /// Services after those they depend on (a cycle keeps the file's order).
    func ordered(_ services: [ServiceSpec]) -> [ServiceSpec] {
        var done: [String] = []
        var visiting: Set<String> = []
        let byName = Dictionary(uniqueKeysWithValues: services.map { ($0.name, $0) })
        func visit(_ n: String) {
            if done.contains(n) || visiting.contains(n) { return }
            visiting.insert(n)
            for d in byName[n]?.dependsOn ?? [] { visit(d.service) }
            visiting.remove(n)
            done.append(n)
        }
        for s in services { visit(s.name) }
        return done.compactMap { byName[$0] }
    }
}
