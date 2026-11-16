// The Agent API: an agent in a service (Claude Code, a script) works the
// pod through HTTP at 172.20.0.1:7070. The network helper carries the
// connection to the app over vsock; each service with access has a token
// at /pier/token, and its tier says what it may do.

import Containerization
import Foundation
import Synchronization

/// What an agent in a service may do, each tier with all of the ones before.
public enum AgentTier: String, Codable, CaseIterable, Sendable, Comparable {
    case off
    /// See the services, their state, addresses and logs.
    case observe
    /// Run commands in other services, copy files in and out; stop, start
    /// and restart them.
    case operate
    /// Start containers of its own and remove them.
    case admin

    public var title: String {
        switch self {
        case .off: "Off"
        case .observe: "Observe"
        case .operate: "Operate"
        case .admin: "Admin"
        }
    }

    public var summary: String {
        switch self {
        case .off: "No access to the pod."
        case .observe: "Sees the services, their state, addresses and logs."
        case .operate: "Also runs commands in other services, copies files in and out, stops, starts and restarts them."
        case .admin: "Also starts containers of its own, which stay in the pod until removed."
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// Limits on what agents start.
enum AgentLimits {
    static let containersPerAgent = 4
    static let minMemoryMiB = 32
    static let maxMemoryMiB = 1024
    static let defaultMemoryMiB = 256
    /// Asked-for lifetimes, in minutes: a week at most.
    static let maxTTLMinutes = 7 * 24 * 60
    static let execTimeout = 60.0
    static let maxExecTimeout = 600.0
    static let outputBytes = 64 * 1024
    /// Files copied in or out.
    static let fileBytes = 64 << 20
    /// Disk slots kept free for the user's own services.
    static let slotsForUser = 1
}

struct AgentRequest: Sendable {
    var method: String
    var path: [String]
    var query: [String: String]
    var token: String?
    var body: Data

    /// The body as a JSON object (empty when it is not one).
    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}

struct AgentResponse: Sendable {
    var status: Int
    var body: Data
    var contentType = "application/json"
    var headers: [String: String] = [:]

    static func ok(_ json: [String: any Sendable]) -> Self { .init(status: 200, body: encode(json)) }
    static func error(_ status: Int, _ message: String) -> Self { .init(status: status, body: encode(["error": message])) }
    static func bytes(_ data: Data, kind: String) -> Self {
        .init(status: 200, body: data, contentType: "application/octet-stream", headers: ["X-Pier-Kind": kind])
    }

    private static func encode(_ json: [String: any Sendable]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        data.append(0x0a)
        return data
    }
}

// MARK: - HTTP over a vsock connection

enum AgentHTTP {
    static let port: UInt32 = 7070
    static let address = "\(PodNetwork.gateway):\(port)"
    /// Connections served at once; more are turned away.
    static let maxConnections = 16
    private static let open = Mutex(0)
    /// Blocking reads and writes run here, off Swift's cooperative pool.
    private static let io = DispatchQueue(label: "pier.agent-api", attributes: .concurrent)

    /// Reads one request from `fd`, answers it and closes the connection.
    static func serve(_ fd: Int32, _ answer: @Sendable @escaping (AgentRequest) async -> AgentResponse) async {
        let admitted = open.withLock { n in
            guard n < maxConnections else { return false }
            n += 1
            return true
        }
        guard admitted else {
            close(fd)
            return
        }
        defer { open.withLock { $0 -= 1 } }
        // A connection that stops sending is dropped instead of holding a thread.
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let request = await onIO { read(fd) }
        let response: AgentResponse
        if let request {
            response = await answer(request)
        } else {
            response = .error(400, "not an HTTP request Pier understands")
        }
        await onIO {
            write(response, to: fd)
            close(fd)
        }
    }

    private static func onIO<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { c in io.async { c.resume(returning: work()) } }
    }

    private static func read(_ fd: Int32) -> AgentRequest? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        let crlf = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n <= 0 { return nil }
            data.append(buffer, count: n)
            headerEnd = data.range(of: crlf)
            if headerEnd == nil && data.count > 64 * 1024 { return nil }
        }
        guard let end = headerEnd, let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2, first[1].hasPrefix("/") else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let declared = Int(headers["content-length"] ?? "0") ?? 0
        guard declared >= 0, declared <= AgentLimits.fileBytes else { return nil }
        var body = Data(data[end.upperBound...])
        while body.count < declared {
            let n = Darwin.read(fd, &buffer, min(buffer.count, declared - body.count))
            if n <= 0 { return nil }
            body.append(buffer, count: n)
        }
        if body.count > declared { body = body.prefix(declared) }
        let target = first[1]
        let question = target.firstIndex(of: "?")
        let pathPart = question.map { target[..<$0] } ?? target[...]
        let queryPart = question.map { target[target.index(after: $0)...] } ?? ""
        let path = pathPart.split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        var query: [String: String] = [:]
        for pair in queryPart.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = kv.first, !key.isEmpty else { continue }
            let value = kv.count > 1 ? String(kv[1]) : ""
            query[key.removingPercentEncoding ?? String(key)] = value.removingPercentEncoding ?? value
        }
        var token = headers["authorization"].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        if token == nil { token = headers["x-pier-token"] }
        return AgentRequest(method: String(first[0]).uppercased(), path: path, query: query, token: token, body: body)
    }

    private static func write(_ r: AgentResponse, to fd: Int32) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 409: "Conflict", 413: "Payload Too Large", 500: "Internal Server Error", 504: "Gateway Timeout"][r.status] ?? "Error"
        var head = "HTTP/1.1 \(r.status) \(reason)\r\nContent-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\nConnection: close\r\n"
        for (k, v) in r.headers { head += "\(k): \(v)\r\n" }
        var out = Data((head + "\r\n").utf8)
        out.append(r.body)
        out.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}

// MARK: - The pod's side

extension PodRunner {
    /// Listens on the VM's vsock and has the network helper carry
    /// 172.20.0.1:7070 there.
    func startAgentAPI(in pod: LinuxPod) async {
        do {
            let listener = try await pod.withVirtualMachineInstance { try $0.listen(AgentHTTP.port) }
            agentListener = listener
            // The listener ends when the pod stops (stopAgentAPI), and with it this task.
            Task.detached { [self] in
                for await connection in listener {
                    let fd = dup(connection.fileDescriptor)
                    try? connection.close()
                    guard fd >= 0 else { continue }
                    Task.detached {
                        await AgentHTTP.serve(fd) { request in await self.answer(request) }
                    }
                }
            }
            let relay = "command -v socat >/dev/null || { echo no socat:; tail -3 /tmp/apk.log; exit 1; }; killall socat 2>/dev/null; nohup socat TCP-LISTEN:\(AgentHTTP.port),bind=\(PodNetwork.gateway),reuseaddr,fork VSOCK-CONNECT:2:\(AgentHTTP.port) >/tmp/agent-api.log 2>&1 < /dev/null & echo started"
            let (code, out) = try await exec(["/bin/sh", "-c", relay], in: PodNetwork.helper)
            podLog.note(code == 0 ? "agent API on \(AgentHTTP.address)" : "agent API did not start: \(out)")
        } catch {
            podLog.note("agent API did not start: \(error)")
        }
        // Containers that asked for a lifetime keep it across restarts.
        for s in currentSpec?.services ?? [] {
            if let e = s.expires { armExpiry(s.name, at: e) }
        }
    }

    /// A service's tier changed while it runs: its token and files follow.
    public func setAgentAccess(_ service: ServiceSpec) async {
        guard var spec = currentSpec, let i = spec.services.firstIndex(where: { $0.name == service.name }) else { return }
        spec.services[i].agentAccess = service.agentAccess
        currentSpec = spec
        if snapshot.services[service.name] == .running { await installAgentAccess(spec.services[i]) }
    }

    func stopAgentAPI() {
        try? agentListener?.finish()
        agentListener = nil
        agentTokens = [:]
        spawnTimers.values.forEach { $0.cancel() }
        spawnTimers = [:]
    }

    /// Gives a service with access its token, the API's description, the
    /// `pier` command and a skill for Claude Code. A service without access
    /// loses what Pier put there before (and nothing else).
    func installAgentAccess(_ service: ServiceSpec) async {
        agentTokens = agentTokens.filter { $0.value != service.name }
        let tier = service.agentAccess ?? .off
        guard tier != .off, currentSpec?.usesSeparateNetworks == true else {
            let cleanup = """
                if [ -f /pier/.pier ]; then rm -f /pier/.pier /pier/token /pier/AGENT.md; rmdir /pier 2>/dev/null; fi
                grep -q "Pier's Agent API" /usr/local/bin/pier 2>/dev/null && rm -f /usr/local/bin/pier
                grep -q 'name: pier' /root/.claude/skills/pier/SKILL.md 2>/dev/null && rm -rf /root/.claude/skills/pier
                true
                """
            _ = try? await exec(["/bin/sh", "-c", cleanup], in: service.name)
            return
        }
        let token = Self.newToken()
        agentTokens[token] = service.name
        let docs = AgentDocs.markdown(service: service.name, tier: tier, spec: currentSpec)
        let files: [(String, String, String)] = [
            ("/pier/.pier", "Written by Pier; removed when agent access is turned off.\n", "644"),
            ("/pier/token", token, "600"),
            ("/pier/AGENT.md", docs, "644"),
            ("/usr/local/bin/pier", AgentDocs.cli, "755"),
            ("/root/.claude/skills/pier/SKILL.md", AgentDocs.skill(tier: tier), "644"),
        ]
        var script = "set -e\n"
        for (path, text, mode) in files {
            let dir = (path as NSString).deletingLastPathComponent
            let b64 = Data(text.utf8).base64EncodedString()
            script += "mkdir -p '\(dir)'; echo '\(b64)' | base64 -d > '\(path)'; chmod \(mode) '\(path)'\n"
        }
        let result = try? await exec(["/bin/sh", "-c", script], in: service.name)
        if result?.0 == 0 {
            say(service.name, "agent access: \(tier.title.lowercased()) (/pier/AGENT.md, the pier command)")
        } else {
            say(service.name, "agent access could not be set up: \(result?.1 ?? "")")
        }
    }

    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Routes

    func answer(_ r: AgentRequest) async -> AgentResponse {
        guard let token = r.token, let caller = agentTokens[token] else {
            return .error(401, "no valid token: send the one in /pier/token as 'Authorization: Bearer <token>'")
        }
        guard let spec = currentSpec, let me = spec.services.first(where: { $0.name == caller }) else {
            return .error(401, "the service this token was for is gone")
        }
        let tier = me.agentAccess ?? .off
        func need(_ t: AgentTier) -> AgentResponse? {
            tier >= t ? nil : .error(403, "this needs \(t.title.lowercased()) access; \(caller) has \(tier.title.lowercased()). Ask the user to raise it in Pier (the service's settings, Agent Access).")
        }
        guard r.path.first == "v1" else { return .error(404, "unknown path; see /pier/AGENT.md") }
        let p = Array(r.path.dropFirst())
        switch (r.method, p) {
        case ("GET", ["me"]):
            return .ok(["service": caller, "tier": tier.rawValue, "api": AgentHTTP.address, "limits": limits(for: caller)])

        case ("GET", ["services"]):
            if let denied = need(.observe) { return denied }
            return .ok(["services": spec.services.map { describe($0) }])

        case ("GET", let rest) where rest.count == 2 && rest[0] == "services":
            if let denied = need(.observe) { return denied }
            guard let s = spec.services.first(where: { $0.name == rest[1] }) else { return .error(404, "no service \(rest[1])") }
            return .ok(describe(s))

        case ("GET", let rest) where rest.count == 3 && rest[0] == "services" && rest[2] == "logs":
            if let denied = need(.observe) { return denied }
            guard spec.services.contains(where: { $0.name == rest[1] }) else { return .error(404, "no service \(rest[1])") }
            let lines = min(max(Int(r.query["lines"] ?? "") ?? 200, 1), 5000)
            let text = log(for: rest[1]).text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
            return .ok(["service": rest[1], "log": text])

        case (let method, let rest) where rest.count == 3 && rest[0] == "services" && rest[2] == "files":
            if let denied = need(.operate) { return denied }
            guard let target = spec.services.first(where: { $0.name == rest[1] }) else { return .error(404, "no service \(rest[1])") }
            if let refused = refusal(touching: target, by: me) { return refused }
            guard let path = r.query["path"], path.hasPrefix("/") else { return .error(400, "give ?path=/absolute/path") }
            // `b64=1`: the bytes as base64 in JSON, for clients that handle only text.
            let b64 = r.query["b64"] != nil
            switch method {
            case "GET":
                let answer = await readFile(path, in: target.name, statOnly: r.query["stat"] != nil)
                guard b64, answer.status == 200, let kind = answer.headers["X-Pier-Kind"] else { return answer }
                return .ok(["path": path, "kind": kind, "data": answer.body.base64EncodedString()])
            case "POST", "PUT":
                var data = r.body
                if b64 {
                    guard let text = r.json["data"] as? String, let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else {
                        return .error(400, "send {\"data\": \"<base64>\"} with b64=1")
                    }
                    data = decoded
                }
                return await writeFile(data, to: path, in: target.name, extract: r.query["extract"] != nil, append: r.query["append"] != nil)
            default: return .error(404, "files take GET or POST")
            }

        case ("POST", let rest) where rest.count == 3 && rest[0] == "services":
            let name = rest[1]
            guard let target = spec.services.first(where: { $0.name == name }) else { return .error(404, "no service \(name)") }
            switch rest[2] {
            case "exec":
                if let denied = need(.operate) { return denied }
                if let refused = refusal(touching: target, by: me) { return refused }
                return await runCommand(r.json, in: name)
            case "start", "stop", "restart":
                if let denied = need(.operate) { return denied }
                if name == caller { return .error(409, "an agent does not \(rest[2]) its own service; ask the user") }
                if let refused = refusal(touching: target, by: me) { return refused }
                do {
                    switch rest[2] {
                    case "start": try await startService(target, in: spec)
                    case "stop": try await stopService(name)
                    default: try await restartService(target, in: spec)
                    }
                    return .ok(["service": name, "state": snapshot.services[name]?.label ?? "unknown"])
                } catch {
                    return .error(500, "\(error)")
                }
            case "ports":
                // Publishes ports of a container on the iPad, at once.
                if let denied = need(.admin) { return denied }
                guard target.spawnedBy == caller else {
                    return .error(403, "\(name) is not a container \(caller) started; ask the user to publish its ports in Pier")
                }
                guard let ports = Self.ports(r.json["ports"]) else {
                    return .error(400, "send {\"ports\": [\"8080:80\"]} (iPad port:container port; an empty list unpublishes)")
                }
                if let clash = spec.services.first(where: { $0.name != name && $0.ports.contains { p in ports.contains { $0.host == p.host } } }) {
                    return .error(409, "a port asked for is \(clash.name)'s")
                }
                var changed = target
                changed.ports = ports
                guard await setPorts(changed) else { return .error(409, "these ports need the pod restarted; ask the user") }
                if let now = currentSpec?.services.first(where: { $0.name == name }) { onServices(.changed(now)) }
                return .ok(describe(currentSpec?.services.first { $0.name == name } ?? changed))
            case "remove":
                if let denied = need(.admin) { return denied }
                guard target.spawnedBy == caller else {
                    return .error(403, "\(name) is not a container \(caller) started; only those can be removed")
                }
                do {
                    try await removeService(name, deleteDisk: true)
                    return .ok(["removed": name])
                } catch {
                    return .error(500, "\(error)")
                }
            default:
                return .error(404, "unknown action \(rest[2])")
            }

        case ("POST", ["spawn"]):
            if let denied = need(.admin) { return denied }
            return await spawn(r.json, for: caller)

        default:
            return .error(404, "unknown \(r.method) /\(r.path.joined(separator: "/")); see /pier/AGENT.md")
        }
    }

    /// Why `caller` may not act on `target`, if it may not: an agent's own
    /// containers are always its to use; another agent's are not, and
    /// neither is a service with more access than the caller (whose token
    /// would give that access away).
    private func refusal(touching target: ServiceSpec, by caller: ServiceSpec) -> AgentResponse? {
        if target.spawnedBy == caller.name { return nil }
        if let owner = target.spawnedBy {
            return .error(403, "\(target.name) belongs to the agent in \(owner); only it or the user may use it")
        }
        if (target.agentAccess ?? .off) > (caller.agentAccess ?? .off) {
            return .error(403, "\(target.name) has more access than \(caller.name); ask the user")
        }
        return nil
    }

    private func describe(_ s: ServiceSpec) -> [String: any Sendable] {
        var d: [String: any Sendable] = [
            "name": s.name,
            "image": s.image,
            "state": snapshot.services[s.name]?.label ?? "unknown",
            "ports": s.ports.map { "\($0.host):\($0.container)" },
            "memoryMiB": Int(s.memoryMiB),
            "agentAccess": (s.agentAccess ?? .off).rawValue,
        ]
        if let i = netIndex[s.name] { d["address"] = PodNetwork.address(i) }
        if let owner = s.spawnedBy { d["spawnedBy"] = owner }
        if let e = s.expires { d["expires"] = ISO8601DateFormatter().string(from: e) }
        return d
    }

    /// Disk slots a new container could take now, less the ones kept for
    /// the user.
    private var slotsForAgents: Int {
        (currentSpec?.slots ?? 0) - hotAdded.count - reservedNames.count - AgentLimits.slotsForUser
    }

    private func limits(for caller: String) -> [String: any Sendable] {
        [
            "containers": AgentLimits.containersPerAgent,
            "yours": (currentSpec?.services ?? []).filter { $0.spawnedBy == caller }.count,
            "freeSlots": max(slotsForAgents, 0),
            "memoryMiB": ["min": AgentLimits.minMemoryMiB, "max": AgentLimits.maxMemoryMiB, "default": AgentLimits.defaultMemoryMiB],
            "maxTTLMinutes": AgentLimits.maxTTLMinutes,
        ]
    }

    private func runCommand(_ body: [String: Any], in service: String) async -> AgentResponse {
        let argv: [String]
        if let command = body["command"] as? String, !command.isEmpty {
            argv = ["/bin/sh", "-c", command]
        } else if let a = body["argv"] as? [String], !a.isEmpty {
            argv = a
        } else {
            return .error(400, "send {\"command\": \"...\"} (run by /bin/sh) or {\"argv\": [...]}")
        }
        let asked = (body["timeout"] as? Double) ?? AgentLimits.execTimeout
        let timeout = min(max(asked, 1), AgentLimits.maxExecTimeout)
        guard let (code, out) = await exec(argv, in: service, timeout: timeout) else {
            return .error(504, "no answer within \(Int(timeout)) s (the command may still run)")
        }
        let trimmed = out.utf8.count > AgentLimits.outputBytes ? String(decoding: out.utf8.suffix(AgentLimits.outputBytes), as: UTF8.self) : out
        return .ok(["service": service, "exit": Int(code), "output": trimmed])
    }

    // MARK: Files

    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// A file as it is, or a directory as a tar archive.
    private func readFile(_ path: String, in service: String, statOnly: Bool) async -> AgentResponse {
        let q = Self.quoted(path)
        let probe = "if [ -d \(q) ]; then echo dir $(du -sk \(q) 2>/dev/null | cut -f1); elif [ -f \(q) ]; then echo file $(wc -c < \(q)); else echo none 0; fi"
        guard let (_, out) = await exec(["/bin/sh", "-c", probe], in: service, timeout: 30) else { return .error(504, "no answer") }
        let fields = out.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, fields[0] != "none" else { return .error(404, "no file or directory \(path) in \(service)") }
        let kind = String(fields[0])
        let size = (Int(fields[1]) ?? 0) * (kind == "dir" ? 1024 : 1)
        if statOnly { return .ok(["path": path, "kind": kind, "bytes": size]) }
        guard size <= AgentLimits.fileBytes else { return .error(413, "\(path) is \(size >> 20) MB; at most \(AgentLimits.fileBytes >> 20) MB at a time") }
        let send = kind == "dir" ? "tar -C \(q) -cf - . 2>/dev/null" : "cat \(q)"
        guard let (code, data) = await execBytes(["/bin/sh", "-c", send], in: service, bytes: AgentLimits.fileBytes + 1, timeout: AgentLimits.maxExecTimeout) else {
            return .error(504, "reading \(path) took too long")
        }
        guard code == 0, data.count <= AgentLimits.fileBytes else {
            return .error(500, "could not read \(path)")
        }
        return .bytes(data, kind: kind)
    }

    /// Writes the request's body to a file, or unpacks it (a tar archive)
    /// into a directory.
    private func writeFile(_ data: Data, to path: String, in service: String, extract: Bool, append: Bool = false) async -> AgentResponse {
        let q = Self.quoted(path)
        let part = Self.quoted(extract ? "/tmp/.pier-upload-\(UUID().uuidString)" : path + ".pier-part")
        let b64 = data.base64EncodedString()
        // Arguments of 96 KB (Linux takes up to 128 KB each), ten to a command.
        let chunk = 96 * 1024
        var pieces: [String] = []
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: chunk, limitedBy: b64.endIndex) ?? b64.endIndex
            pieces.append(String(b64[i..<j]))
            i = j
        }
        let dir = extract ? q : Self.quoted((path as NSString).deletingLastPathComponent)
        guard let (made, _) = await exec(["/bin/sh", "-c", "mkdir -p \(dir) && : > \(part)"], in: service, timeout: 30), made == 0 else {
            return .error(500, "could not write \(path)")
        }
        var start = 0
        while start < pieces.count {
            let batch = Array(pieces[start..<min(start + 10, pieces.count)])
            let script = "for c in \"$@\"; do printf %s \"$c\"; done | base64 -d >> \(part)"
            guard let (code, _) = await exec(["/bin/sh", "-c", script, "sh"] + batch, in: service, timeout: 120), code == 0 else {
                _ = await exec(["/bin/sh", "-c", "rm -f \(part)"], in: service, timeout: 30)
                return .error(500, "could not write \(path)")
            }
            start += 10
        }
        // Synced before answering: a copy that returned is on the disk, even if
        // Pier is ended right after.
        let finish = (extract ? "tar -C \(q) -xf \(part); rc=$?; rm -f \(part)"
            : append ? "cat \(part) >> \(q); rc=$?; rm -f \(part)" : "mv -f \(part) \(q); rc=$?") + "; sync; exit $rc"
        guard let (code, out) = await exec(["/bin/sh", "-c", finish], in: service, timeout: 120), code == 0 else {
            return .error(500, "could not finish \(path)")
        }
        _ = out
        return .ok(["service": service, "path": path, "bytes": data.count, "extracted": extract])
    }

    // MARK: Containers of an agent's own

    /// A container of the caller's own, named `<caller>-<name>`: it stays in
    /// the pod (across restarts too) until the agent or the user removes it,
    /// or until its time is up if it asked for one.
    /// "8080:80" or "8080" (the same both sides), from a JSON list.
    static func ports(_ value: Any?) -> [PortMapping]? {
        guard let list = value as? [Any] else { return nil }
        var out: [PortMapping] = []
        for item in list {
            let text = (item as? String) ?? (item as? Int).map(String.init) ?? ""
            let parts = text.split(separator: ":").map { UInt16($0) }
            guard (1...2).contains(parts.count), let host = parts[0], host > 0, let c = parts.last!, c > 0 else { return nil }
            out.append(PortMapping(host: host, container: c))
        }
        return out
    }

    private func spawn(_ body: [String: Any], for caller: String) async -> AgentResponse {
        guard let image = body["image"] as? String, !image.isEmpty else {
            return .error(400, "send at least {\"image\": \"alpine:3.20\"}")
        }
        guard currentSpec?.usesSeparateNetworks == true else { return .error(409, "the pod shares one network: no agent containers") }
        let mine = (currentSpec?.services ?? []).filter { $0.spawnedBy == caller }.count
        guard mine < AgentLimits.containersPerAgent else {
            return .error(409, "\(caller) has \(mine) containers (at most \(AgentLimits.containersPerAgent)); remove one with pier rm first")
        }
        guard slotsForAgents > 0 else {
            return .error(409, "no free disk slot for another container (one stays free for the user); remove one, or ask the user to restart the pod, which frees them")
        }
        let memory = (body["memoryMiB"] as? Int) ?? AgentLimits.defaultMemoryMiB
        guard (AgentLimits.minMemoryMiB...AgentLimits.maxMemoryMiB).contains(memory) else {
            return .error(400, "memoryMiB must be \(AgentLimits.minMemoryMiB) to \(AgentLimits.maxMemoryMiB)")
        }
        var expires: Date?
        if let ttl = body["ttlMinutes"] as? Int {
            guard (1...AgentLimits.maxTTLMinutes).contains(ttl) else {
                return .error(400, "ttlMinutes must be 1 to \(AgentLimits.maxTTLMinutes), or left out (no limit)")
            }
            expires = Date().addingTimeInterval(Double(ttl) * 60)
        }
        let requested = (body["name"] as? String) ?? String(image.split(separator: "/").last ?? "box").split(separator: ":").first.map(String.init) ?? "box"
        var cleaned = String(requested.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if cleaned.isEmpty { cleaned = "box" }
        var name = String("\(caller)-\(cleaned)".prefix(48))
        func taken(_ n: String) -> Bool { currentSpec?.services.contains { $0.name == n } == true || reservedNames.contains(n) }
        if taken(name) {
            var n = 2
            while taken("\(name)-\(n)") { n += 1 }
            name = "\(name)-\(n)"
        }
        var command = (body["command"] as? [String]) ?? []
        if let shell = body["command"] as? String { command = ["/bin/sh", "-c", shell] }
        if command.isEmpty, body["useImageCommand"] as? Bool != true {
            command = ["/bin/sh", "-c", "trap 'exit 0' TERM; while :; do sleep 3600 & wait $!; done"]
        }
        var service = ServiceSpec(
            name: name, image: image, command: command,
            environment: (body["env"] as? [String]) ?? [], memoryMiB: UInt64(memory), mountsWork: false
        )
        service.aliases = body["name"] is String && cleaned != name ? [cleaned] : nil
        service.spawnedBy = caller
        service.expires = expires
        if body["ports"] != nil {
            guard let ports = Self.ports(body["ports"]) else { return .error(400, "ports: [\"8080:80\"] (iPad port:container port)") }
            if let clash = currentSpec?.services.first(where: { $0.ports.contains { p in ports.contains { $0.host == p.host } } }) {
                return .error(409, "a port asked for is \(clash.name)'s")
            }
            service.ports = ports
        }
        do {
            try await addService(service)
        } catch {
            return .error(500, "\(error)")
        }
        update { $0.spawned[name] = SpawnInfo(service) }
        onServices(.added(service))
        if let expires { armExpiry(name, at: expires) }
        return .ok(describe(currentSpec?.services.first { $0.name == name } ?? service))
    }

    /// Removes a container whose time is up. The timer forgets itself first,
    /// so removing does not cancel the task doing it.
    func armExpiry(_ name: String, at date: Date) {
        spawnTimers[name]?.cancel()
        let delay = max(date.timeIntervalSinceNow, 1)
        spawnTimers[name] = Task.detached { [self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self.expire(name)
        }
    }

    private func expire(_ name: String) async {
        spawnTimers[name] = nil
        say(name, "its time is up: removing it")
        do {
            try await removeService(name, deleteDisk: true)
        } catch {
            say(name, "could not remove it: \(error)")
        }
    }
}

// MARK: - What the agent reads

enum AgentDocs {
    static func markdown(service: String, tier: AgentTier, spec: PodSpec?) -> String {
        let others = (spec?.services ?? []).filter { $0.name != service }.map { "`\($0.name)` (\($0.image))" }
        var md = """
        # Pier: this pod, for agents

        You run in **\(service)**, one container of a Pier pod: Linux containers on an iPad,
        each with its own address on a bridge (172.20.0.0/24), in one virtual machine.
        This file is written each time the service starts; what it says is current then.

        Your access: **\(tier.title)**. \(tier.summary)
        Only the user changes it (in Pier: the service's settings, Agent Access).

        Other services when this started: \(others.isEmpty ? "none" : others.joined(separator: ", ")).
        Reach them by name (`ping db`, `psql -h db`); `pier ps` shows what runs now, with addresses.

        ## The `pier` command

        ```
        pier me                          # who you are, your tier and limits
        """
        if tier >= .observe {
            md += """

            pier ps                          # every service: state, address, ports, memory
            pier logs NAME [LINES]           # a service's output (default 200 lines)
            """
        }
        if tier >= .operate {
            md += """

            pier exec NAME COMMAND...        # run a shell command in another service
            pier cp NAME:/path LOCAL         # copy a file or directory out
            pier cp LOCAL NAME:/path         # copy one in (a path ending in / keeps the name)
            pier stop|start|restart NAME     # not your own service
            """
        }
        if tier >= .admin {
            md += """

            pier spawn IMAGE [--name N] [--mem MB] [--ttl MIN] [--port 8080:80] [-- COMMAND...]
                                             # a container of your own, named \(service)-N
            pier publish NAME 8080:80 ...    # its ports on the iPad, at once (none: unpublish)
            pier rm NAME                     # remove one you started
            """
        }
        md += """

        ```

        ## The HTTP API

        `http://\(AgentHTTP.address)`, JSON, the token from `/pier/token` as
        `Authorization: Bearer <token>`. Everything `pier` does goes through it:

        | Request | Tier | Body / answer |
        |---|---|---|
        | `GET /v1/me` | any | `service`, `tier`, `limits` |
        | `GET /v1/services` · `GET /v1/services/NAME` | observe | name, image, state, address, ports, memoryMiB, spawnedBy, expires |
        | `GET /v1/services/NAME/logs?lines=200` | observe | `log` |
        | `POST /v1/services/NAME/exec` | operate | `{"command": "uname -a", "timeout": 60}` or `{"argv": [...]}` → `exit`, `output` (last 64 KB) |
        | `GET /v1/services/NAME/files?path=/p` | operate | the file's bytes, or a directory as tar (`X-Pier-Kind: file` or `dir`); `&stat=1` → `kind`, `bytes` |
        | `POST /v1/services/NAME/files?path=/p` | operate | the body becomes the file; `&extract=1` unpacks a tar body into directory `/p`; `&append=1` adds to the file |
        | `POST /v1/services/NAME/start` · `stop` · `restart` | operate | not your own service |
        | `POST /v1/spawn` | admin | `{"image": "alpine:3.20", "name": "scan", "memoryMiB": 256, "command": "sleep infinity", "env": ["K=v"], "ttlMinutes": 60}` (all but `image` optional) |
        | `POST /v1/services/NAME/remove` | admin | only containers you started |

        Errors come back as `{"error": "..."}` with 4xx or 5xx. Files are up to \(AgentLimits.fileBytes >> 20) MB at a time.

        ## Whose is what

        - Containers you started are yours: exec, copy, stop, remove them freely.
        - Another agent's containers are not yours to touch, and neither is a service with
          more access than you; the API refuses both.

        """
        if tier >= .admin {
            md += """
            ## Containers of your own

            - At most \(AgentLimits.containersPerAgent) at a time, \(AgentLimits.minMemoryMiB) to \(AgentLimits.maxMemoryMiB) MB each (\(AgentLimits.defaultMemoryMiB) MB unless you ask).
            - They stay in the pod, across restarts too, until you `pier rm` them or the user removes
              them. `--ttl MIN` (`ttlMinutes`) makes one go by itself, for one-off work.
            - Without a command a container just stays up, for `pier exec`; `"useImageCommand": true`
              runs the image's own command.
            - Each gets the next address on the bridge and its name in `/etc/hosts` of the running
              services. `--port 8080:80` (`"ports": ["8080:80"]`) publishes a port on the iPad at once:
              `http://localhost:8080` in its Safari, and on the network if the user allowed that;
              `pier publish NAME 8080:80` does it for one already running.
            - Disk slots for containers added while the pod runs are few, and one stays free for the
              user; `pier me` shows how many are left. A pod restart frees them.
            - Clean up after yourself: `pier rm` what you no longer need.

            """
        }
        md += """
        ## Notes

        - The VM translates ARM64 code as it runs: compiled programs run about 1.75 times slower
          than on the bare iPad, compiling and starting many processes about 4.5 times, Python
          and Node slower still. Prefer native tools for heavy work.
        - Images must be `linux/arm64`.
        - Containers started by different agents share one network for now and can reach each other.
        - Ask the user before anything that reaches outside the pod or changes another service's data.
        """
        return md
    }

    static func skill(tier: AgentTier) -> String {
        """
        ---
        name: pier
        description: Work with the Pier pod this container runs in — list the other services, read their logs, run commands in them, copy files in and out, start containers of your own (by tier). Use when the task involves other containers, services, Docker-like work, or a scratch container.
        ---

        You run in a container of a Pier pod (Linux containers on an iPad). Read `/pier/AGENT.md`
        first: it says what your access (**\(tier.title)**) allows and how to use the `pier` command
        and the HTTP API. Use `pier` rather than guessing addresses; clean up what you start.
        """
    }

    /// `pier`: the API from a shell, with curl, wget or bash alone.
    static let cli = #"""
    #!/bin/sh
    # pier: Pier's Agent API from a shell. See /pier/AGENT.md.
    API="${PIER_API:-http://172.20.0.1:7070}"
    TOKEN="$(cat /pier/token 2>/dev/null)"
    [ -n "$TOKEN" ] || { echo "pier: no token in /pier/token (is agent access on for this service?)" >&2; exit 1; }

    CR="$(printf '\r')"
    json_str() {
      printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037' \
        | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' -e "s/$CR/\\\\r/g" \
        | awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}'
    }
    urlenc() { printf '%s' "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/&/%26/g' -e 's/?/%3F/g' -e 's/#/%23/g' -e 's/+/%2B/g'; }
    have() { command -v "$1" >/dev/null 2>&1; }

    req() { # METHOD PATH [BODY]
      if have curl; then
        if [ -n "$3" ]; then curl -sS -X "$1" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$3" "$API$2"
        else curl -sS -X "$1" -H "Authorization: Bearer $TOKEN" "$API$2"; fi
      elif have wget; then
        if [ "$1" = POST ]; then wget -qO- --header "Authorization: Bearer $TOKEN" --header 'Content-Type: application/json' --post-data "${3:-{\}}" "$API$2" || echo "pier: the request failed (wget hides the reason; curl shows it)" >&2
        else wget -qO- --header "Authorization: Bearer $TOKEN" "$API$2" || echo "pier: the request failed (wget hides the reason; curl shows it)" >&2; fi
      elif have bash; then
        LC_ALL=C PIER_M="$1" PIER_P="$2" PIER_B="$3" PIER_T="$TOKEN" bash -c '
          exec 3<>/dev/tcp/172.20.0.1/7070 || exit 1
          printf "%s %s HTTP/1.1\r\nHost: pier\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s" \
            "$PIER_M" "$PIER_P" "$PIER_T" "${#PIER_B}" "$PIER_B" >&3
          sed "1,/^\r$/d" <&3'
      else
        echo "pier: needs curl, wget or bash" >&2; exit 1
      fi
    }

    fetch() { # PATH OUTFILE (binary)
      if have curl; then curl -sSf -H "Authorization: Bearer $TOKEN" -o "$2" "$API$1"
      elif have wget; then wget -q --header "Authorization: Bearer $TOKEN" -O "$2" "$API$1"
      else # bash alone: the bytes come as base64 in JSON
        out="$(req GET "$1&b64=1")" || return 1
        data="$(printf '%s' "$out" | sed -n 's/.*"data" *: *"\([^"]*\)".*/\1/p')"
        [ -n "$data" ] || { printf '%s\n' "$out" >&2; return 1; }
        printf '%s' "$data" | sed 's/\\//g' | base64 -d > "$2"
      fi
    }
    send() { # PATH INFILE (binary)
      if have curl; then curl -sSf -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/octet-stream' --data-binary "@$2" "$API$1"
      elif have wget; then wget -qO- --header "Authorization: Bearer $TOKEN" --header 'Content-Type: application/octet-stream' --post-file "$2" "$API$1"
      else # bash alone: base64 in JSON, 96 KB of it a request (the most one variable may hold), appended after the first
        more=""
        base64 < "$2" | tr -d '\n' | fold -w 98304 | while IFS= read -r chunk || [ -n "$chunk" ]; do
          req POST "$1&b64=1$more" "{\"data\":\"$chunk\"}" >/dev/null || exit 1
          more="&append=1"
        done && echo "{ \"path\" : \"sent\" }"
      fi
    }

    copy() { # SRC DST, one of them NAME:/path
      case "$1" in
        *:/*)
          name="${1%%:*}"; rpath="${1#*:}"; dst="$2"
          stat="$(req GET "/v1/services/$name/files?path=$(urlenc "$rpath")&stat=1")"
          kind="$(printf '%s' "$stat" | sed -n 's/.*"kind" *: *"\([a-z]*\)".*/\1/p')"
          [ -n "$kind" ] || { printf '%s\n' "$stat" >&2; return 1; }
          if [ "$kind" = dir ]; then
            mkdir -p "$dst" && tmp="$(mktemp)" && fetch "/v1/services/$name/files?path=$(urlenc "$rpath")" "$tmp" && tar -C "$dst" -xf "$tmp"; rc=$?; rm -f "$tmp"; return $rc
          fi
          [ -d "$dst" ] && dst="$dst/$(basename "$rpath")"
          fetch "/v1/services/$name/files?path=$(urlenc "$rpath")" "$dst" ;;
        *)
          case "$2" in *:/*) ;; *) echo "pier cp: one side must be NAME:/path" >&2; return 2 ;; esac
          name="${2%%:*}"; rpath="${2#*:}"; src="$1"
          case "$rpath" in */) rpath="$rpath$(basename "$src")" ;; esac
          if [ -d "$src" ]; then
            tmp="$(mktemp)" && tar -C "$src" -cf "$tmp" . && send "/v1/services/$name/files?path=$(urlenc "$rpath")&extract=1" "$tmp"; rc=$?; rm -f "$tmp"; return $rc
          fi
          send "/v1/services/$name/files?path=$(urlenc "$rpath")" "$src" ;;
      esac
    }

    cmd="${1:-help}"; [ $# -gt 0 ] && shift
    case "$cmd" in
      me) req GET /v1/me ;;
      ps|services) req GET /v1/services ;;
      logs) [ -n "$1" ] || { echo "pier logs NAME [LINES]" >&2; exit 2; }; req GET "/v1/services/$1/logs?lines=${2:-200}" ;;
      exec) [ $# -ge 2 ] || { echo "pier exec NAME COMMAND..." >&2; exit 2; }
            name="$1"; shift; req POST "/v1/services/$name/exec" "{\"command\":\"$(json_str "$*")\"}" ;;
      cp) [ $# -eq 2 ] || { echo "pier cp NAME:/path LOCAL  or  pier cp LOCAL NAME:/path" >&2; exit 2; }; copy "$1" "$2" ;;
      start|stop|restart) [ -n "$1" ] || { echo "pier $cmd NAME" >&2; exit 2; }; req POST "/v1/services/$1/$cmd" ;;
      spawn)
        [ -n "$1" ] || { echo "pier spawn IMAGE [--name N] [--mem MB] [--ttl MIN] [--port 8080:80] [-- COMMAND...]" >&2; exit 2; }
        body="\"image\":\"$(json_str "$1")\""; shift
        ports=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --port) ports="${ports:+$ports,}\"$2\""; shift 2; continue ;;
            --name) body="$body,\"name\":\"$(json_str "$2")\""; shift 2 ;;
            --ttl) body="$body,\"ttlMinutes\":$2"; shift 2 ;;
            --mem) body="$body,\"memoryMiB\":$2"; shift 2 ;;
            --) shift; body="$body,\"command\":\"$(json_str "$*")\""; break ;;
            *) echo "pier spawn: unknown option $1" >&2; exit 2 ;;
          esac
        done
        [ -n "$ports" ] && body="$body,\"ports\":[$ports]"
        req POST /v1/spawn "{$body}" ;;
      publish) [ -n "$1" ] || { echo "pier publish NAME [8080:80 ...]" >&2; exit 2; }
        name="$1"; shift; ports=""
        for p in "$@"; do ports="${ports:+$ports,}\"$p\""; done
        req POST "/v1/services/$name/ports" "{\"ports\":[$ports]}" ;;
      rm|remove) [ -n "$1" ] || { echo "pier rm NAME" >&2; exit 2; }; req POST "/v1/services/$1/remove" ;;
      *) sed -n '/^## The `pier` command/,/^## The HTTP API/p' /pier/AGENT.md | sed '$d' ;;
    esac
    """#
}
