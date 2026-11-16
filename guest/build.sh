#!/bin/sh
# Builds what Pier puts inside the VM, in a Linux container (Docker, or
# Apple's `container` with CONTAINER_CLI=container):
#
#   agent   Sources/PierCore/Resources/vmexec-overlay.tar.gz
#           vminitd and vmexec from the containerization fork, statically
#           linked (Swift static Linux SDK); laid over Apple's vminit image.
#   kernel  ios/Resources/vmlinux
#           Linux 6.12 with Kata's arm64 config plus Landlock (guest/kernel.config).
#
#     guest/build.sh [agent|kernel|all]     (default: all)
#
# The containerization fork is expected next to this repo (../containerization).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
src=${CONTAINERIZATION:-$here/../containerization}
cli=${CONTAINER_CLI:-docker}
what=${1:-all}
swift_image=swift:6.3
sdk_url=https://download.swift.org/swift-6.3.3-release/static-sdk/swift-6.3.3-RELEASE/swift-6.3.3-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz
sdk_sum=87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b
kernel_version=6.12.28
out=$here/guest/out
mkdir -p "$out"

agent() {
    [ -d "$src/vminitd" ] || { echo "no containerization fork at $src"; exit 1; }
    echo "building vminitd and vmexec (static, arm64)..."
    $cli run --rm --platform linux/arm64 \
        -v "$src:/src:ro" -v "$out:/out" -v pier-swift-cache:/cache \
        "$swift_image" bash -euc "
            export HOME=/cache
            swift sdk list | grep -q static-linux || swift sdk install '$sdk_url' --checksum $sdk_sum
            rm -rf /build && mkdir /build && cp -R /src /build/containerization
            rm -rf /build/containerization/Frameworks /build/containerization/.build
            cd /build/containerization/vminitd
            for p in vminitd vmexec; do
                swift build -c release --swift-sdk aarch64-swift-linux-musl --product \$p -Xlinker -s --scratch-path /cache/vminitd-build
            done
            mkdir -p /tmp/ov/sbin
            cp /cache/vminitd-build/aarch64-swift-linux-musl/release/vminitd /cache/vminitd-build/aarch64-swift-linux-musl/release/vmexec /tmp/ov/sbin/
            tar -C /tmp/ov -czf /out/vmexec-overlay.tar.gz ./sbin
        "
    cp "$out/vmexec-overlay.tar.gz" "$here/Sources/PierCore/Resources/vmexec-overlay.tar.gz"
    echo "agent: Sources/PierCore/Resources/vmexec-overlay.tar.gz"
}

kernel() {
    echo "building Linux $kernel_version with Landlock (arm64)..."
    $cli run --rm --platform linux/arm64 \
        -v "$here/guest:/guest:ro" -v "$out:/out" -v pier-kernel-cache:/cache \
        -v "$here/Sources/PierCore/Resources/cacert.pem:/ca.pem:ro" \
        ubuntu:24.04 bash -euc "
            export DEBIAN_FRONTEND=noninteractive
            # Over HTTPS: plain HTTP is intercepted on some networks.
            sed -i 's|http://|https://|g' /etc/apt/sources.list.d/*.sources
            apt='apt-get -qq -o Acquire::https::CaInfo=/ca.pem'
            \$apt update && \$apt install -y build-essential bc flex bison libelf-dev libssl-dev xz-utils cpio curl ca-certificates >/dev/null
            cd /cache
            [ -f linux-$kernel_version.tar.xz ] || curl -fsSLO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$kernel_version.tar.xz
            rm -rf linux-$kernel_version && tar xJf linux-$kernel_version.tar.xz && cd linux-$kernel_version
            cp /guest/kernel.config .config && make olddefconfig >/dev/null
            grep -q '^CONFIG_SECURITY_LANDLOCK=y' .config
            make -j\$(nproc) Image >/dev/null
            cp arch/arm64/boot/Image /out/vmlinux
        "
    cp "$out/vmlinux" "$here/ios/Resources/vmlinux"
    echo "kernel: ios/Resources/vmlinux"
}

case $what in
agent) agent ;;
kernel) kernel ;;
all) agent; kernel ;;
*) echo "usage: guest/build.sh [agent|kernel|all]"; exit 2 ;;
esac
