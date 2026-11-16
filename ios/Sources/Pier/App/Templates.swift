import PierCore

/// Ready-made services for the Add sheet, in groups.
struct Template: Identifiable {
    let title: String
    let summary: String
    let service: ServiceSpec
    var id: String { title }
}

struct TemplateGroup: Identifiable {
    let title: String
    let symbol: String
    let templates: [Template]
    var id: String { title }
}

enum Templates {
    /// A service that runs a command, or waits in /work for commands.
    private static func idle(_ name: String, _ image: String, mem: UInt64 = 512, ports: [PortMapping] = []) -> ServiceSpec {
        ServiceSpec(name: name, image: image, command: ["/bin/sh", "-c", "cd /work 2>/dev/null; exec sleep infinity"],
                    ports: ports, memoryMiB: mem)
    }

    private static func port(_ host: UInt16, _ container: UInt16? = nil) -> PortMapping {
        PortMapping(host: host, container: container ?? host)
    }

    static let groups: [TemplateGroup] = [
        TemplateGroup(title: "Databases", symbol: "cylinder.split.1x2", templates: [
            Template(title: "PostgreSQL 17", summary: "user postgres, password pier",
                     service: ServiceSpec(name: "db", image: "docker.io/library/postgres:17-alpine",
                                          environment: ["POSTGRES_PASSWORD=pier"], ports: [port(5432)], memoryMiB: 512, mountsWork: false)),
            Template(title: "MySQL 8.4", summary: "root password pier, database app",
                     service: ServiceSpec(name: "mysql", image: "docker.io/library/mysql:8.4",
                                          environment: ["MYSQL_ROOT_PASSWORD=pier", "MYSQL_DATABASE=app"], ports: [port(3306)], memoryMiB: 1024, mountsWork: false)),
            Template(title: "MariaDB 11", summary: "root password pier, database app",
                     service: ServiceSpec(name: "mariadb", image: "docker.io/library/mariadb:11",
                                          environment: ["MARIADB_ROOT_PASSWORD=pier", "MARIADB_DATABASE=app"], ports: [port(3307, 3306)], memoryMiB: 768, mountsWork: false)),
            Template(title: "Redis 7", summary: "in-memory key-value store",
                     service: ServiceSpec(name: "redis", image: "docker.io/library/redis:7-alpine", ports: [port(6379)], memoryMiB: 256, mountsWork: false)),
            Template(title: "Valkey 8", summary: "the open Redis fork",
                     service: ServiceSpec(name: "valkey", image: "docker.io/valkey/valkey:8-alpine", ports: [port(6380, 6379)], memoryMiB: 256, mountsWork: false)),
            Template(title: "MongoDB 8", summary: "user root, password pier",
                     service: ServiceSpec(name: "mongo", image: "docker.io/library/mongo:8",
                                          environment: ["MONGO_INITDB_ROOT_USERNAME=root", "MONGO_INITDB_ROOT_PASSWORD=pier"], ports: [port(27017)], memoryMiB: 1024, mountsWork: false)),
            Template(title: "ClickHouse", summary: "column store; HTTP 8123, native 9000",
                     service: ServiceSpec(name: "clickhouse", image: "docker.io/clickhouse/clickhouse-server:latest",
                                          environment: ["CLICKHOUSE_PASSWORD=pier"], ports: [port(8123), port(9000)], memoryMiB: 1536, mountsWork: false)),
            Template(title: "Qdrant", summary: "vector database; REST 6333",
                     service: ServiceSpec(name: "qdrant", image: "docker.io/qdrant/qdrant:latest", ports: [port(6333), port(6334)], memoryMiB: 512, mountsWork: false)),
            Template(title: "Memcached", summary: "memory cache on 11211",
                     service: ServiceSpec(name: "memcached", image: "docker.io/library/memcached:alpine", ports: [port(11211)], memoryMiB: 128, mountsWork: false)),
            Template(title: "Adminer", summary: "database admin in the browser, port 8081",
                     service: ServiceSpec(name: "adminer", image: "docker.io/library/adminer:latest", ports: [port(8081, 8080)], memoryMiB: 128, mountsWork: false)),
        ]),
        TemplateGroup(title: "Web Servers and Proxies", symbol: "globe", templates: [
            Template(title: "nginx", summary: "serves /work/site on 8080",
                     service: ServiceSpec(name: "web", image: "docker.io/library/nginx:alpine",
                                          command: ["/bin/sh", "-c", "mkdir -p /work/site && rm -rf /usr/share/nginx/html && ln -s /work/site /usr/share/nginx/html && exec nginx -g 'daemon off;'"],
                                          ports: [port(8080, 80)], memoryMiB: 256)),
            Template(title: "Caddy", summary: "serves /work/site on 8082, automatic config",
                     service: ServiceSpec(name: "caddy", image: "docker.io/library/caddy:alpine",
                                          command: ["/bin/sh", "-c", "mkdir -p /work/site && exec caddy file-server --root /work/site --listen :80"],
                                          ports: [port(8082, 80)], memoryMiB: 128)),
            Template(title: "Apache httpd", summary: "classic web server on 8083",
                     service: ServiceSpec(name: "httpd", image: "docker.io/library/httpd:alpine", ports: [port(8083, 80)], memoryMiB: 256, mountsWork: false)),
            Template(title: "Traefik", summary: "reverse proxy, dashboard on 8090",
                     service: ServiceSpec(name: "traefik", image: "docker.io/library/traefik:v3",
                                          command: ["traefik", "--api.insecure=true", "--entrypoints.web.address=:80"],
                                          ports: [port(8084, 80), port(8090, 8080)], memoryMiB: 256, mountsWork: false)),
            Template(title: "HAProxy", summary: "load balancer (bring a config in /work)",
                     service: ServiceSpec(name: "haproxy", image: "docker.io/library/haproxy:alpine", memoryMiB: 128)),
        ]),
        TemplateGroup(title: "Languages and Runtimes", symbol: "chevron.left.forwardslash.chevron.right", templates: [
            Template(title: "Node.js 22", summary: "waits in /work; port 3000", service: idle("node", "docker.io/library/node:22-alpine", mem: 1024, ports: [port(3000)])),
            Template(title: "Bun", summary: "fast JavaScript runtime; port 3001", service: idle("bun", "docker.io/oven/bun:alpine", mem: 768, ports: [port(3001, 3000)])),
            Template(title: "Deno", summary: "secure JavaScript and TypeScript; port 8001", service: idle("deno", "docker.io/denoland/deno:alpine", mem: 768, ports: [port(8001, 8000)])),
            Template(title: "Python 3.13", summary: "waits in /work; port 8000", service: idle("python", "docker.io/library/python:3.13-alpine", mem: 768, ports: [port(8000)])),
            Template(title: "Go 1.24", summary: "waits in /work; port 8085", service: idle("go", "docker.io/library/golang:1.24-alpine", mem: 1024, ports: [port(8085, 8080)])),
            Template(title: "Rust", summary: "cargo and rustc; waits in /work", service: idle("rust", "docker.io/library/rust:alpine", mem: 1536)),
            Template(title: "Ruby 3.3", summary: "waits in /work; port 3002", service: idle("ruby", "docker.io/library/ruby:3.3-alpine", mem: 768, ports: [port(3002, 3000)])),
            Template(title: "PHP 8.3", summary: "php -S on 8086 from /work",
                     service: ServiceSpec(name: "php", image: "docker.io/library/php:8.3-cli-alpine",
                                          command: ["/bin/sh", "-c", "mkdir -p /work/site && exec php -S 0.0.0.0:8000 -t /work/site"],
                                          ports: [port(8086, 8000)], memoryMiB: 256)),
            Template(title: "Java 21", summary: "Eclipse Temurin JDK; waits in /work", service: idle("java", "docker.io/library/eclipse-temurin:21-jdk", mem: 1536)),
            Template(title: ".NET 8", summary: "SDK; waits in /work", service: idle("dotnet", "mcr.microsoft.com/dotnet/sdk:8.0", mem: 1536)),
            Template(title: "Elixir", summary: "waits in /work", service: idle("elixir", "docker.io/library/elixir:alpine", mem: 768)),
            Template(title: "Swift 6", summary: "waits in /work", service: idle("swift", "docker.io/library/swift:6.3", mem: 2048)),
        ]),
        TemplateGroup(title: "Linux Systems", symbol: "terminal", templates: [
            Template(title: "Alpine", summary: "small and quick", service: idle("alpine", "docker.io/library/alpine:3.20", mem: 256)),
            Template(title: "Debian 13", summary: "trixie", service: idle("debian", "docker.io/library/debian:trixie", mem: 512)),
            Template(title: "Ubuntu 24.04", summary: "noble", service: idle("ubuntu", "docker.io/library/ubuntu:24.04", mem: 512)),
            Template(title: "Fedora", summary: "latest Fedora", service: idle("fedora", "docker.io/library/fedora:latest", mem: 512)),
            Template(title: "Rocky Linux 9", summary: "RHEL-compatible", service: idle("rocky", "docker.io/library/rockylinux:9", mem: 512)),
            Template(title: "openSUSE Tumbleweed", summary: "rolling release", service: idle("opensuse", "docker.io/opensuse/tumbleweed:latest", mem: 512)),
            Template(title: "Kali Linux", summary: "rolling; security tools with apt", service: idle("kali", "docker.io/kalilinux/kali-rolling:latest", mem: 1024)),
            Template(title: "Arch Linux ARM", summary: "community arm64 build",
                     service: ServiceSpec(name: "arch", image: "docker.io/menci/archlinuxarm:latest",
                                          command: ["/bin/sh", "-c", "grep -q '^DisableSandbox' /etc/pacman.conf || sed -i '/^\\[options\\]/a DisableSandbox' /etc/pacman.conf; cd /work 2>/dev/null; exec sleep infinity"],
                                          memoryMiB: 512)),
            Template(title: "BusyBox", summary: "the bare minimum", service: idle("busybox", "docker.io/library/busybox:latest", mem: 64)),
        ]),
        TemplateGroup(title: "Developer Tools", symbol: "hammer", templates: [
            Template(title: "SSH server", summary: "port 2222, user pier, password pier",
                     service: ServiceSpec(name: "ssh", image: "lscr.io/linuxserver/openssh-server:latest",
                                          environment: ["PUID=0", "PGID=0", "USER_NAME=pier", "USER_PASSWORD=pier", "PASSWORD_ACCESS=true", "SUDO_ACCESS=true"],
                                          ports: [port(2222)], memoryMiB: 256)),
            Template(title: "VS Code in the browser", summary: "code-server on 8443, password pier, folder /work",
                     service: ServiceSpec(name: "code", image: "docker.io/codercom/code-server:latest",
                                          command: ["code-server", "--bind-addr", "0.0.0.0:8080", "/work"], environment: ["PASSWORD=pier"],
                                          ports: [port(8443, 8080)], memoryMiB: 1024)),
            Template(title: "Jupyter", summary: "notebooks on 8888, token pier",
                     service: ServiceSpec(name: "jupyter", image: "quay.io/jupyter/base-notebook:latest",
                                          command: ["start-notebook.py", "--IdentityProvider.token=pier", "--ServerApp.root_dir=/work"],
                                          ports: [port(8888)], memoryMiB: 1024)),
            Template(title: "Gitea", summary: "Git hosting; web 3003, SSH 2223",
                     service: ServiceSpec(name: "gitea", image: "docker.io/gitea/gitea:latest", ports: [port(3003, 3000), port(2223, 22)], memoryMiB: 512, mountsWork: false)),
            Template(title: "MinIO", summary: "S3 storage; API 9010, console 9011, minio / pierpier",
                     service: ServiceSpec(name: "minio", image: "docker.io/minio/minio:latest",
                                          command: ["minio", "server", "/data", "--console-address", ":9001"],
                                          environment: ["MINIO_ROOT_USER=minio", "MINIO_ROOT_PASSWORD=pierpier"],
                                          ports: [port(9010, 9000), port(9011, 9001)], memoryMiB: 512, mountsWork: false)),
            Template(title: "Mailpit", summary: "catches mail: SMTP 1025, web 8025",
                     service: ServiceSpec(name: "mailpit", image: "docker.io/axllent/mailpit:latest", ports: [port(1025), port(8025)], memoryMiB: 128, mountsWork: false)),
            Template(title: "RabbitMQ", summary: "AMQP 5672, management 15672 (guest / guest)",
                     service: ServiceSpec(name: "rabbitmq", image: "docker.io/library/rabbitmq:management-alpine", ports: [port(5672), port(15672)], memoryMiB: 768, mountsWork: false)),
            Template(title: "NATS", summary: "messaging on 4222",
                     service: ServiceSpec(name: "nats", image: "docker.io/library/nats:alpine", ports: [port(4222), port(8222)], memoryMiB: 128, mountsWork: false)),
            Template(title: "n8n", summary: "workflow automation on 5678",
                     service: ServiceSpec(name: "n8n", image: "docker.io/n8nio/n8n:latest", ports: [port(5678)], memoryMiB: 1024, mountsWork: false)),
            Template(title: "Uptime Kuma", summary: "uptime monitor on 3004",
                     service: ServiceSpec(name: "uptime", image: "docker.io/louislam/uptime-kuma:2", ports: [port(3004, 3001)], memoryMiB: 512, mountsWork: false)),
        ]),
    ]

    static var all: [Template] { groups.flatMap(\.templates) }

    static func named(_ title: String) -> Template? { all.first { $0.title == title } }

    /// What `--demo-pod` runs: a database, a web server and a shell sharing /work.
    static var demoPod: PodSpec {
        var shell = named("Alpine")!.service
        shell.name = "shell"
        shell.command = ["/bin/sh", "-c", "mkdir -p /work/site && echo '<h1>Hello from Pier on iPad</h1>' > /work/site/index.html && exec sleep infinity"]
        return PodSpec(
            services: [named("PostgreSQL 17")!.service, named("nginx")!.service, shell],
            cpus: 4,
            memoryMiB: 2048,
            reachableFromNetwork: true,
            workVolumeGiB: 8
        )
    }
}
