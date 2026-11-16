#!/bin/sh
# Builds Sources/PierCore/Resources/libggml-rpc.so: ggml's RPC backend for
# Linux arm64, pointed at Pier's GPU server (pier-gpu.cpp) and named so ggml
# describes it as an Apple GPU. It is built in the Ollama image it serves, so
# it matches that image's libggml-base and glibc.
#
#     gpu/build-shim.sh [OLLAMA_VERSION] [LLAMA_CPP_TAG]   # default 0.40.16 b12177
# Needs docker (or CONTAINER_CLI=container).
set -eu
ollama=${1:-0.40.16}
tag=${2:-b12177}
here=$(cd "$(dirname "$0")/.." && pwd)
cli=${CONTAINER_CLI:-docker}
$cli run --rm --platform linux/arm64 -v "$here/gpu:/gpu" -e TAG="$tag" --entrypoint /bin/sh "ollama/ollama:$ollama" -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq g++ git ca-certificates >/dev/null
git clone -q --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp /src
cd /src/ggml/src/ggml-rpc
sed "s|std::string dev_desc = std::string(endpoint);|std::string dev_desc = std::string(\"Apple GPU (Metal, via Pier) \") + endpoint;|" ggml-rpc.cpp > /tmp/ggml-rpc.cpp
grep -q "via Pier" /tmp/ggml-rpc.cpp
g++ -shared -fPIC -O2 -std=c++17 -DGGML_BACKEND_SHARED -DGGML_BACKEND_BUILD -I../../include -I.. -I. \
    /tmp/ggml-rpc.cpp log.cpp transport.cpp /gpu/pier-gpu.cpp \
    -L/usr/lib/ollama -l:libggml-base.so.0 -Wl,-rpath,/usr/lib/ollama -Wl,--no-undefined -o /gpu/libggml-rpc.so
'
mv "$here/gpu/libggml-rpc.so" "$here/Sources/PierCore/Resources/libggml-rpc.so"
echo "$here/Sources/PierCore/Resources/libggml-rpc.so"
