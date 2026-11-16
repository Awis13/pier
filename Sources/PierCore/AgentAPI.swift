// The Agent API: an agent in a service (Claude Code, a script) works the
// pod through HTTP at 172.20.0.1:7070. The network helper carries the
// connection to the app over vsock; each service with access has a token
// at /pier/token, and its tier says what it may do.

import Containerization
import Foundation

/// What an agent in a service may do, each tier with all of the ones before.
public enum AgentTier: String, Codable, CaseIterable, Sendable, Comparable {
    case off
    /// See the services, their state, addresses and logs.
    case observe
    /// Run commands in other services; stop, start and restart them.
    case operate
    /// Start containers of its own (and remove them), within limits.
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
        case .operate: "Also runs commands in other services, stops, starts and restarts them."
        case .admin: "Also starts containers of its own, which go away after a while."
        }
    }

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// Limits on what one agent starts.
enum AgentLimits {
    static let containersPerAgent = 4
    static let memoryMiB: UInt64 = 1024
    static let defaultMemoryMiB: UInt64 = 256
    static let defaultTTLMinutes = 60
    static let maxTTLMinutes = 24 * 60
    static let execTimeout = 60.0
    static let maxExecTimeout = 600.0
    static let outputBytes = 64 * 1024
}

/// The body is JSON from one request, read and answered on one task at a time.
struct AgentRequest: @unchecked Sendable {
    var method: String
    var path: [String]
    var query: [String: String]
    var token: String?
    var body: [String: Any]
}

struct AgentResponse: @unchecked Sendable {
    var status: Int
    var json: Any

    static func ok(_ json: Any) -> Self { .init(status: 200, json: json) }
    static func error(_ status: Int, _ message: String) -> Self { .init(status: status, json: ["error": message]) }
}

// MARK: - HTTP over a vsock connection

enum AgentHTTP {
    static let port: UInt32 = 7070
    static let address = "\(PodNetwork.gateway):7070"

    /// Reads one request from `fd`, answers it and closes the connection.
    static func serve(_ fd: Int32, _ answer: @Sendable @escaping (AgentRequest) async -> AgentResponse) async {
        let request = await Task.detached { read(fd) }.value
        let response: AgentResponse
        if let request {
            response = await answer(request)
        } else {
            response = .error(400, "not an HTTP request Pier understands")
        }
        await Task.detached { write(response, to: fd); close(fd) }.value
    }

    private static func read(_ fd: Int32) -> AgentRequest? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        let crlf = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n <= 0 { return nil }
            data.append(buffer, count: n)
            headerEnd = data.range(of: crlf)
            if data.count > 64 * 1024 && headerEnd == nil { return nil }
        }
        guard let end = headerEnd, let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = min(Int(headers["content-length"] ?? "0") ?? 0, 1 << 20)
        var body = Data(data[end.upperBound...])
        while body.count < length {
            let n = Darwin.read(fd, &buffer, min(buffer.count, length - body.count))
            if n <= 0 { break }
            body.append(buffer, count: n)
        }
        let target = String(first[1])
        let parts = target.split(separator: "?", maxSplits: 1)
        let path = parts[0].split(separator: "/").map { $0.removingPercentEncoding ?? String($0) }
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                query[kv[0]] = kv.count > 1 ? kv[1] : ""
            }
        }
        var token = headers["authorization"].flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : nil }
        if token == nil { token = headers["x-pier-token"] }
        let json = (body.isEmpty ? nil : try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        return AgentRequest(method: String(first[0]).uppercased(), path: path, query: query, token: token, body: json ?? [:])
    }

    private static func write(_ r: AgentResponse, to fd: Int32) {
        let body = (try? JSONSerialization.data(withJSONObject: r.json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 409: "Conflict", 500: "Internal Server Error"][r.status] ?? "Error"
        var out = Data("HTTP/1.1 \(r.status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count + 1)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        out.append(0x0a)
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
            let relay = "killall socat 2>/dev/null; nohup socat TCP-LISTEN:\(AgentHTTP.port),bind=\(PodNetwork.gateway),reuseaddr,fork VSOCK-CONNECT:2:\(AgentHTTP.port) >/tmp/agent-api.log 2>&1 < /dev/null & echo started"
            let (code, out) = try await exec(["/bin/sh", "-c", relay], in: PodNetwork.helper)
            podLog.note(code == 0 ? "agent API on \(AgentHTTP.address)" : "agent API did not start: \(out)")
        } catch {
            podLog.note("agent API did not start: \(error)")
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
    /// loses any it had.
    func installAgentAccess(_ service: ServiceSpec) async {
        agentTokens = agentTokens.filter { $0.value != service.name }
        let tier = service.agentAccess ?? .off
        guard tier != .off, currentSpec?.usesSeparateNetworks == true else {
            _ = try? await exec(["/bin/sh", "-c", "rm -rf /pier /usr/local/bin/pier"], in: service.name)
            return
        }
        let token = Self.newToken()
        agentTokens[token] = service.name
        let docs = AgentDocs.markdown(service: service.name, tier: tier, spec: currentSpec)
        let files: [(String, String, String)] = [
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
            tier >= t ? nil : .error(403, "this needs \(t.title.lowercased()) access; \(caller) has \(tier.title.lowercased()). Ask the user to raise it in Pier (service > Agent Access).")
        }
        let p = r.path
        guard p.first == "v1" else { return .error(404, "unknown path; see /pier/AGENT.md") }
        switch (r.method, Array(p.dropFirst())) {
        case ("GET", ["me"]):
            return .ok(["service": caller, "tier": tier.rawValue, "api": AgentHTTP.address, "limits": limits(for: caller)])

        case ("GET", ["services"]):
            if let denied = need(.observe) { return denied }
            return .ok(["services": spec.services.map { describe($0) }])

        case ("GET", let rest) where rest.count == 3 && rest[0] == "services" && rest[2] == "logs":
            if let denied = need(.observe) { return denied }
            guard spec.services.contains(where: { $0.name == rest[1] }) else { return .error(404, "no service \(rest[1])") }
            let lines = min(Int(r.query["lines"] ?? "") ?? 200, 2000)
            let text = log(for: rest[1]).text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
            return .ok(["service": rest[1], "log": text])

        case ("POST", let rest) where rest.count == 3 && rest[0] == "services":
            let name = rest[1]
            guard let target = spec.services.first(where: { $0.name == name }) else { return .error(404, "no service \(name)") }
            switch rest[2] {
            case "exec":
                if let denied = need(.operate) { return denied }
                return await runCommand(r.body, in: name)
            case "start", "stop", "restart":
                if let denied = need(.operate) { return denied }
                if name == caller { return .error(409, "an agent does not \(rest[2]) its own service; ask the user") }
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
            case "remove":
                if let denied = need(.admin) { return denied }
                guard snapshot.spawned[name]?.owner == caller else {
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
            return await spawn(r.body, for: caller)

        default:
            return .error(404, "unknown \(r.method) /\(p.joined(separator: "/")); see /pier/AGENT.md")
        }
    }

    private func describe(_ s: ServiceSpec) -> [String: Any] {
        var d: [String: Any] = [
            "name": s.name,
            "image": s.image,
            "state": snapshot.services[s.name]?.label ?? "unknown",
            "ports": s.ports.map { "\($0.host):\($0.container)" },
            "agentAccess": (s.agentAccess ?? .off).rawValue,
        ]
        if let i = netIndex[s.name] { d["address"] = PodNetwork.address(i) }
        if let info = snapshot.spawned[s.name] {
            d["spawnedBy"] = info.owner
            if let e = info.expires { d["expires"] = ISO8601DateFormatter().string(from: e) }
        }
        return d
    }

    private func limits(for caller: String) -> [String: Any] {
        [
            "containers": AgentLimits.containersPerAgent,
            "running": snapshot.spawned.values.filter { $0.owner == caller }.count,
            "memoryMiB": AgentLimits.memoryMiB,
            "defaultTTLMinutes": AgentLimits.defaultTTLMinutes,
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
        let timeout = min((body["timeout"] as? Double) ?? AgentLimits.execTimeout, AgentLimits.maxExecTimeout)
        guard let (code, out) = await exec(argv, in: service, timeout: timeout) else {
            return .error(500, "no answer within \(Int(timeout)) s (the command may still run)")
        }
        let trimmed = out.utf8.count > AgentLimits.outputBytes ? String(decoding: out.utf8.suffix(AgentLimits.outputBytes), as: UTF8.self) : out
        return .ok(["service": service, "exit": Int(code), "output": trimmed])
    }

    /// A container of the caller's own: named `<caller>-<name>`, on the pod's
    /// bridge, gone when its time is up, when it is removed or when the pod
    /// stops.
    private func spawn(_ body: [String: Any], for caller: String) async -> AgentResponse {
        guard let image = body["image"] as? String, !image.isEmpty else {
            return .error(400, "send at least {\"image\": \"alpine:3.20\"}")
        }
        let mine = snapshot.spawned.values.filter { $0.owner == caller }.count
        guard mine < AgentLimits.containersPerAgent else {
            return .error(409, "\(caller) has \(mine) containers already (at most \(AgentLimits.containersPerAgent)); remove one first")
        }
        let requested = (body["name"] as? String) ?? String(image.split(separator: "/").last ?? "box").split(separator: ":").first.map(String.init) ?? "box"
        let cleaned = String(requested.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        var name = String("\(caller)-\(cleaned.isEmpty ? "box" : cleaned)".prefix(48))
        if currentSpec?.services.contains(where: { $0.name == name }) == true {
            var n = 2
            while currentSpec?.services.contains(where: { $0.name == "\(name)-\(n)" }) == true { n += 1 }
            name = "\(name)-\(n)"
        }
        let memory = min(UInt64((body["memoryMiB"] as? Int) ?? Int(AgentLimits.defaultMemoryMiB)), AgentLimits.memoryMiB)
        let ttl = min(max((body["ttlMinutes"] as? Int) ?? AgentLimits.defaultTTLMinutes, 1), AgentLimits.maxTTLMinutes)
        var command = (body["command"] as? [String]) ?? []
        if let shell = body["command"] as? String { command = ["/bin/sh", "-c", shell] }
        if command.isEmpty, body["keepAlive"] as? Bool ?? true, body["useImageCommand"] as? Bool != true {
            command = ["/bin/sh", "-c", "trap 'exit 0' TERM; while :; do sleep 3600 & wait $!; done"]
        }
        var service = ServiceSpec(
            name: name, image: image, command: command,
            environment: (body["env"] as? [String]) ?? [], memoryMiB: memory, mountsWork: false
        )
        service.aliases = body["name"] is String ? [cleaned] : nil
        let expires = Date().addingTimeInterval(Double(ttl) * 60)
        update { $0.spawned[name] = SpawnInfo(owner: caller, image: image, expires: expires) }
        do {
            try await addService(service)
        } catch {
            update { $0.spawned[name] = nil }
            if hotAdded.contains(name) { try? await removeService(name, deleteDisk: true) }
            return .error(500, "\(error)")
        }
        let spawned = name, seconds = Double(ttl) * 60
        spawnTimers[name] = Task.detached { [self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self.expire(spawned)
        }
        var reply = describe(currentSpec?.services.first { $0.name == name } ?? service)
        reply["ttlMinutes"] = ttl
        return .ok(reply)
    }

    private func expire(_ name: String) async {
        say(name, "time is up: removing the container an agent started")
        try? await removeService(name, deleteDisk: true)
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
        Only the user changes it (in Pier: the service > Agent Access).

        Other services: \(others.isEmpty ? "none" : others.joined(separator: ", ")).
        Reach them by name (`ping db`, `psql -h db`); `pier ps` shows addresses and state.

        ## The `pier` command

        ```
        pier me                          # who you are, your tier and limits
        """
        if tier >= .observe {
            md += """

            pier ps                          # every service: state, address, ports
            pier logs NAME [LINES]           # a service's output (default 200 lines)
            """
        }
        if tier >= .operate {
            md += """

            pier exec NAME COMMAND...        # run a shell command in another service
            pier stop|start|restart NAME     # not your own service
            """
        }
        if tier >= .admin {
            md += """

            pier spawn IMAGE [--name N] [--ttl MIN] [--mem MB] [-- COMMAND...]
                                             # a container of your own, named \(service)-N
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
        | `GET /v1/services` | observe | `services[]`: name, image, state, address, ports, spawnedBy, expires |
        | `GET /v1/services/NAME/logs?lines=200` | observe | `log` |
        | `POST /v1/services/NAME/exec` | operate | `{"command": "uname -a", "timeout": 60}` or `{"argv": [...]}` → `exit`, `output` (last 64 KB) |
        | `POST /v1/services/NAME/start` · `stop` · `restart` | operate | not your own service |
        | `POST /v1/spawn` | admin | `{"image": "alpine:3.20", "name": "scan", "ttlMinutes": 60, "memoryMiB": 256, "command": "sleep infinity", "env": ["K=v"]}` |
        | `POST /v1/services/NAME/remove` | admin | only containers you started |

        Errors come back as `{"error": "..."}` with 4xx or 5xx.

        """
        if tier >= .admin {
            md += """
            ## Containers of your own

            - At most \(AgentLimits.containersPerAgent) at a time, up to \(AgentLimits.memoryMiB) MB each (\(AgentLimits.defaultMemoryMiB) MB unless you ask).
            - Each goes away after its time (\(AgentLimits.defaultTTLMinutes) minutes unless you ask, at most \(AgentLimits.maxTTLMinutes / 60) hours), when you
              remove it, or when the pod stops, with its disk. Keep results in `/work` of a service that has it,
              or copy them out with `pier exec`.
            - Without a command a container just stays up, for `pier exec`; `"useImageCommand": true` runs the image's own.
            - It gets the next address on the bridge and its name in `/etc/hosts` of the running services.
              Its ports reach the other services, not the iPad, until the pod restarts.
            - The pod has a few free disk slots; when none is left, spawning fails until one is removed.
            - Clean up after yourself: `pier rm` what you no longer need.

            """
        }
        md += """
        ## Notes

        - The VM translates ARM64 code as it runs: native programs run at about half speed,
          Python and Node slower. Prefer native tools for heavy work.
        - Images must be `linux/arm64`.
        - Ask the user before anything that reaches outside the pod or changes another service's data.
        """
        return md
    }

    static func skill(tier: AgentTier) -> String {
        """
        ---
        name: pier
        description: Work with the Pier pod this container runs in — list the other services, read their logs, run commands in them, start containers of your own (by tier). Use when the task involves other containers, services, Docker-like work, or spawning a scratch container.
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

    json_str() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | awk 'BEGIN{ORS=""} NR>1{print "\\n"} {print}'; }

    req() { # METHOD PATH [BODY]
      if command -v curl >/dev/null 2>&1; then
        if [ -n "$3" ]; then curl -sS -X "$1" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data "$3" "$API$2"
        else curl -sS -X "$1" -H "Authorization: Bearer $TOKEN" "$API$2"; fi
      elif command -v wget >/dev/null 2>&1; then
        if [ "$1" = POST ]; then wget -qO- --header "Authorization: Bearer $TOKEN" --header 'Content-Type: application/json' --post-data "${3:-{\}}" "$API$2"
        else wget -qO- --header "Authorization: Bearer $TOKEN" "$API$2"; fi
      elif command -v bash >/dev/null 2>&1; then
        PIER_M="$1" PIER_P="$2" PIER_B="$3" PIER_T="$TOKEN" bash -c '
          exec 3<>/dev/tcp/172.20.0.1/7070 || exit 1
          printf "%s %s HTTP/1.1\r\nHost: pier\r\nAuthorization: Bearer %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s" \
            "$PIER_M" "$PIER_P" "$PIER_T" "${#PIER_B}" "$PIER_B" >&3
          sed "1,/^\r$/d" <&3'
      else
        echo "pier: needs curl, wget or bash" >&2; exit 1
      fi
    }

    cmd="${1:-help}"; [ $# -gt 0 ] && shift
    case "$cmd" in
      me) req GET /v1/me ;;
      ps|services) req GET /v1/services ;;
      logs) [ -n "$1" ] || { echo "pier logs NAME [LINES]" >&2; exit 2; }; req GET "/v1/services/$1/logs?lines=${2:-200}" ;;
      exec) [ $# -ge 2 ] || { echo "pier exec NAME COMMAND..." >&2; exit 2; }
            name="$1"; shift; req POST "/v1/services/$name/exec" "{\"command\":\"$(json_str "$*")\"}" ;;
      start|stop|restart) [ -n "$1" ] || { echo "pier $cmd NAME" >&2; exit 2; }; req POST "/v1/services/$1/$cmd" ;;
      spawn)
        [ -n "$1" ] || { echo "pier spawn IMAGE [--name N] [--ttl MIN] [--mem MB] [-- COMMAND...]" >&2; exit 2; }
        body="\"image\":\"$(json_str "$1")\""; shift
        while [ $# -gt 0 ]; do
          case "$1" in
            --name) body="$body,\"name\":\"$(json_str "$2")\""; shift 2 ;;
            --ttl) body="$body,\"ttlMinutes\":$2"; shift 2 ;;
            --mem) body="$body,\"memoryMiB\":$2"; shift 2 ;;
            --) shift; body="$body,\"command\":\"$(json_str "$*")\""; break ;;
            *) echo "pier spawn: unknown option $1" >&2; exit 2 ;;
          esac
        done
        req POST /v1/spawn "{$body}" ;;
      rm|remove) [ -n "$1" ] || { echo "pier rm NAME" >&2; exit 2; }; req POST "/v1/services/$1/remove" ;;
      *) sed -n '/^## The `pier` command/,/^## The HTTP API/p' /pier/AGENT.md | sed '$d' ;;
    esac
    """#
}
