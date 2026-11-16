import Foundation
import Testing

@testable import PierCore

@Suite("Spec")
struct SpecTests {
    @Test(arguments: [
        ("nginx", "docker.io/library/nginx:latest"),
        ("nginx:alpine", "docker.io/library/nginx:alpine"),
        ("louislam/uptime-kuma:2", "docker.io/louislam/uptime-kuma:2"),
        ("ghcr.io/apple/vminit:0.54.0", "ghcr.io/apple/vminit:0.54.0"),
        ("localhost:5000/app", "localhost:5000/app:latest"),
        ("alpine@sha256:abc", "docker.io/library/alpine@sha256:abc"),
    ])
    func normalizedImage(_ input: String, _ expected: String) {
        #expect(ServiceSpec.normalizedImage(input) == expected)
    }

    @Test(arguments: [("8080:80", PortMapping(host: 8080, container: 80)), ("22", PortMapping(host: 22, container: 22))])
    func portMapping(_ text: String, _ expected: PortMapping) {
        #expect(PortMapping(text) == expected)
    }

    @Test(arguments: ["", "a:b", "1:2:3", "70000"])
    func badPortMapping(_ text: String) {
        #expect(PortMapping(text) == nil)
    }

    @Test func validateCatchesClashesAndMissingDependencies() {
        var spec = PodSpec(services: [ServiceSpec(name: "a", image: "x", ports: [PortMapping(host: 80, container: 80)]),
                                      ServiceSpec(name: "b", image: "x", ports: [PortMapping(host: 80, container: 8080)])])
        #expect(throws: PierError.self) { try spec.validate() }
        spec.services[1].ports = []
        spec.services[1].dependsOn = [Dependency(service: "zzz")]
        #expect(throws: PierError.self) { try spec.validate() }
        spec.services[1].dependsOn = [Dependency(service: "a")]
        #expect(throws: Never.self) { try spec.validate() }
    }

    @Test func oldSpecsStillDecode() throws {
        let json = #"{"services":[{"name":"db","image":"postgres","command":[],"environment":[],"ports":[],"memoryMiB":512,"mountsWork":true}],"cpus":4,"memoryMiB":3072,"reachableFromNetwork":false,"workVolumeGiB":16}"#
        let spec = try JSONDecoder().decode(PodSpec.self, from: Data(json.utf8))
        #expect(spec.services[0].volumes == nil)
        #expect(spec.usesSeparateNetworks)
    }
}

@Suite("Log buffer")
struct LogBufferTests {
    @Test func linesSplitAndLimit() {
        let log = LogBuffer(limit: 3)
        log.append(Data("one\ntw".utf8))
        log.append(Data("o\nthree\nfour\n".utf8))
        #expect(log.text == "two\nthree\nfour")
    }

    @Test func longOutputWithoutNewlineBecomesALine() {
        let log = LogBuffer()
        log.append(Data(repeating: UInt8(ascii: "x"), count: 20_000))
        #expect(log.text.count == 20_000 && !log.text.contains("\n"))
    }
}
