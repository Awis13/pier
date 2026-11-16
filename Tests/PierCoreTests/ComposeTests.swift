import Foundation
import Testing

@testable import PierCore

/// Parses a Compose file given as text, without a folder.
private func parse(_ yaml: String) throws -> ComposeProject {
    try ComposeProject.parse(yaml, directory: nil, projectName: "t")
}

private func service(_ p: ComposeProject, _ name: String) throws -> ServiceSpec {
    try #require(p.services.first { $0.name == name })
}

/// A throwaway project folder with the given files.
private func folder(_ files: [String: String]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("compose-\(UUID().uuidString)")
    for (path, text) in files {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    return dir
}

@Suite("Compose: ports")
struct PortTests {
    @Test(arguments: [
        ("\"8080:80\"", [PortMapping(host: 8080, container: 80)]),
        ("\"80\"", [PortMapping(host: 80, container: 80)]),
        ("\"127.0.0.1:5432:5432\"", [PortMapping(host: 5432, container: 5432)]),
        ("\"8080:80/tcp\"", [PortMapping(host: 8080, container: 80)]),
        ("\"[::1]:9000:90\"", [PortMapping(host: 9000, container: 90)]),
        ("\"9090-9091:8080-8081\"", [PortMapping(host: 9090, container: 8080), PortMapping(host: 9091, container: 8081)]),
        ("3000", [PortMapping(host: 3000, container: 3000)]),
        ("{target: 80, published: \"8081\"}", [PortMapping(host: 8081, container: 80)]),
    ])
    func forms(_ item: String, _ expected: [PortMapping]) throws {
        let p = try parse("services:\n  s:\n    image: nginx\n    ports:\n      - \(item)\n")
        #expect(try service(p, "s").ports == expected)
    }

    @Test func udpIsLeftOutWithAWarning() throws {
        let p = try parse("services:\n  s:\n    image: x\n    ports: [\"53:53/udp\"]\n")
        #expect(try service(p, "s").ports.isEmpty)
        #expect(p.warnings.contains { $0.contains("udp") })
    }
}

@Suite("Compose: variables")
struct VariableTests {
    @Test func dotEnvDefaultsAndEscapes() throws {
        let dir = try folder([
            "compose.yaml": """
            services:
              s:
                image: "nginx:${TAG:-alpine}"
                environment:
                  A: ${SET}
                  B: ${UNSET:-fallback}
                  C: ${SET:+yes}
                  D: $$NOT_A_VAR
                  E: $SET-suffix
                  F: ${EMPTY-kept}
                  G: ${EMPTY:-replaced}
            """,
            ".env": "SET=hello\nEMPTY=\n# comment\nQUOTED=\"with spaces\"\n",
        ])
        let p = try ComposeProject.parse(String(contentsOf: dir.appendingPathComponent("compose.yaml"), encoding: .utf8), directory: dir)
        let s = try service(p, "s")
        #expect(s.image == "nginx:alpine")
        #expect(s.environment == ["A=hello", "B=fallback", "C=yes", "D=$NOT_A_VAR", "E=hello-suffix", "F=", "G=replaced"])
        #expect(p.warnings.isEmpty)
        #expect(!p.needsFolder)
    }

    @Test func unsetVariablesAreNamedAndNeedTheFolder() throws {
        let p = try parse("services:\n  s:\n    image: x\n    environment:\n      P: ${SECRET}\n")
        #expect(p.warnings.contains { $0.contains("${SECRET} is not set") })
        #expect(p.needsFolder)
    }

    @Test func envListWithoutValueTakesDotEnv() throws {
        let dir = try folder([".env": "TOKEN=abc\n"])
        let p = try ComposeProject.parse("services:\n  s:\n    image: x\n    environment: [TOKEN, MISSING, X=1]\n", directory: dir)
        #expect(try service(p, "s").environment == ["TOKEN=abc", "X=1"])
    }

    @Test func envFileComesFirstEnvironmentWins() throws {
        let dir = try folder(["app.env": "A=from-file\nB=file\n"])
        let p = try ComposeProject.parse("services:\n  s:\n    image: x\n    env_file: app.env\n    environment:\n      B: inline\n", directory: dir)
        #expect(try service(p, "s").environment == ["A=from-file", "B=inline"])
    }
}

@Suite("Compose: commands")
struct CommandTests {
    @Test(arguments: [
        ("echo hi", ["echo", "hi"]),
        ("sh -c 'a && b'", ["sh", "-c", "a && b"]),
        ("printf \"%s x\" \"two words\"", ["printf", "%s x", "two words"]),
        ("a\\ b c", ["a b", "c"]),
        ("[\"x\", \"y z\"]", ["x", "y z"]),
        ("''", [""]),
    ])
    func command(_ yaml: String, _ expected: [String]) throws {
        let quoted = yaml.hasPrefix("[") ? yaml : "'" + yaml.replacingOccurrences(of: "'", with: "''") + "'"
        let p = try parse("services:\n  s:\n    image: x\n    command: \(quoted)\n")
        #expect(try service(p, "s").args == expected)
    }

    @Test func entrypointDropsImageCommand() throws {
        let p = try parse("services:\n  s:\n    image: x\n    entrypoint: [/bin/sh, -c]\n    command: echo hi\n")
        let s = try service(p, "s")
        #expect(s.entrypoint == ["/bin/sh", "-c"])
        #expect(s.args == ["echo", "hi"])
    }
}

@Suite("Compose: services")
struct ServiceTests {
    @Test func namesAreCleanedAndClashesGetASuffix() throws {
        let p = try parse("services:\n  Web_App:\n    image: x\n  web-app:\n    image: x\n")
        #expect(Set(p.services.map(\.name)) == ["web-app", "web-app-2"])
        #expect(try service(p, "web-app-2").aliases?.contains("Web_App") == true)
    }

    @Test func profilesAndBuildOnlyAreLeftOut() throws {
        let p = try parse("services:\n  a:\n    image: x\n  b:\n    image: x\n    profiles: [debug]\n  c:\n    build: .\n")
        #expect(p.services.map(\.name) == ["a"])
        #expect(p.warnings.count == 2)
    }

    @Test func dependenciesOrderTheStart() throws {
        let p = try parse("""
        services:
          web:
            image: x
            depends_on: [api]
          api:
            image: x
            depends_on:
              db: {condition: service_healthy}
          db:
            image: x
            healthcheck:
              test: ["CMD-SHELL", "pg_isready"]
              interval: 1m30s
              timeout: 500ms
              retries: 5
              start_period: 10s
        """)
        #expect(p.services.map(\.name) == ["db", "api", "web"])
        #expect(try service(p, "api").dependsOn == [Dependency(service: "db", condition: .healthy)])
        let hc = try #require(try service(p, "db").healthcheck)
        #expect(hc.arguments == ["/bin/sh", "-c", "pg_isready"])
        #expect(hc.intervalSeconds == 90)
        #expect(hc.timeoutSeconds == 0.5)
        #expect(hc.retries == 5)
        #expect(hc.startPeriodSeconds == 10)
    }

    @Test func dependencyCycleKeepsEveryService() throws {
        let p = try parse("services:\n  a:\n    image: x\n    depends_on: [b]\n  b:\n    image: x\n    depends_on: [a]\n")
        #expect(Set(p.services.map(\.name)) == ["a", "b"])
    }

    @Test func anchorsAndMergeKeys() throws {
        let p = try parse("""
        x-base: &base
          restart: always
          environment: {A: "1"}
        services:
          s:
            <<: *base
            image: x
            environment: {B: "2"}
        """)
        let s = try service(p, "s")
        #expect(s.restart == .always)
        #expect(s.environment == ["B=2"])
    }

    @Test(arguments: [("512m", UInt64(512)), ("1g", 1024), ("1.5G", 1536), ("268435456", 256), ("64k", 64)])
    func memory(_ text: String, _ mib: UInt64) throws {
        let p = try parse("services:\n  s:\n    image: x\n    mem_limit: \"\(text)\"\n")
        #expect(try service(p, "s").memoryMiB == mib)
    }

    @Test func restartPoliciesAndUser() throws {
        let p = try parse("services:\n  s:\n    image: x\n    restart: \"on-failure:3\"\n    user: \"1000:1000\"\n    working_dir: /app\n    privileged: true\n")
        let s = try service(p, "s")
        #expect(s.restart == .onFailure)
        #expect(s.user == "1000:1000")
        #expect(s.workingDir == "/app")
        #expect(s.privileged == true)
    }
}

@Suite("Compose: volumes")
struct VolumeTests {
    @Test func namedAndBoundVolumes() throws {
        let dir = try folder(["conf/nginx.conf": "x", "compose.yaml": ""])
        let p = try ComposeProject.parse("""
        services:
          s:
            image: x
            volumes:
              - data:/var/lib/data
              - ./conf/nginx.conf:/etc/nginx.conf:ro
              - ./missing:/m
              - .:/src
              - /var/run/docker.sock:/var/run/docker.sock
              - /anonymous
        """, directory: dir, projectName: "demo")
        let v = try #require(try service(p, "s").volumes)
        #expect(v.map(\.source) == [".pier/volumes/demo-data", ".pier/projects/demo/conf/nginx.conf", ".pier/projects/demo/missing", ".pier/projects/demo"])
        #expect(v[1].readOnly && v[1].files == "projects/demo/conf/nginx.conf")
        #expect(v[2].files == nil)
        #expect(Set(p.copies.map(\.to)) == ["projects/demo/conf/nginx.conf", "projects/demo"])
        #expect(p.warnings.contains { $0.contains("docker.sock") })
    }

    @Test func pathsOutsideTheProjectAreRefused() throws {
        let dir = try folder(["compose.yaml": ""])
        let p = try ComposeProject.parse("services:\n  s:\n    image: x\n    volumes: [\"../secret:/s\"]\n", directory: dir)
        #expect(try service(p, "s").volumes == nil)
        #expect(p.warnings.contains { $0.contains("outside the project") })
    }

    @Test func bindsWithoutAFolderNeedIt() throws {
        let p = try parse("services:\n  s:\n    image: x\n    volumes: [\"./a:/a\"]\n")
        #expect(p.needsFolder)
    }
}

@Suite("Compose: errors")
struct ErrorTests {
    @Test(arguments: ["", "- a list", "services: {}", "name: x"])
    func notACompose(_ yaml: String) {
        #expect(throws: (any Error).self) { try parse(yaml) }
    }
}
