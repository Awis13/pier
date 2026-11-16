#!/bin/sh
# Builds Frameworks/ggml.xcframework: ggml with Metal and its RPC server, for
# iOS and macOS, from the llama.cpp release whose ggml the served Ollama uses.
#
#     gpu/build-ggml.sh [LLAMA_CPP_TAG]      # default b12177 (Ollama 0.40.16)
set -eu
tag=${1:-b12177}
here=$(cd "$(dirname "$0")/.." && pwd)
work=${WORK:-$here/.build/ggml-$tag}
[ -d "$work/src/.git" ] || git clone -q --depth 1 --branch "$tag" https://github.com/ggml-org/llama.cpp "$work/src"
python3 "$here/gpu/rpc-budget.py" "$work/src/ggml/src/ggml-rpc/ggml-rpc.cpp"
common="-DBUILD_SHARED_LIBS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_RPC=ON -DGGML_RPC_RDMA=OFF
        -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_BLAS=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 -DLLAMA_CURL=OFF
        -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF"
targets="--target ggml-rpc ggml-metal ggml-cpu ggml-base ggml"
cmake -S "$work/src" -B "$work/macos" $common -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$work/macos" $targets -j 8 >/dev/null
cmake -S "$work/src" -B "$work/ios" -G Xcode $common -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO >/dev/null
cmake --build "$work/ios" --config Release $targets -- -quiet >/dev/null
mkdir -p "$work/headers"
cp "$work"/src/ggml/include/ggml.h "$work"/src/ggml/include/ggml-alloc.h "$work"/src/ggml/include/ggml-backend.h \
   "$work"/src/ggml/include/ggml-cpu.h "$work"/src/ggml/include/ggml-metal.h "$work"/src/ggml/include/ggml-rpc.h "$work/headers/"
sed -i '' 's|^GGML_BACKEND_API ggml_backend_reg_t ggml_backend_rpc_add_server(const char \* endpoint);|&\
\
// Pier: what clients may allocate on a server started in this process (0: no limit).\
GGML_BACKEND_API void ggml_backend_rpc_set_memory_budget(size_t bytes);|' "$work/headers/ggml-rpc.h"
cat > "$work/headers/module.modulemap" <<'MAP'
module ggml {
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-cpu.h"
    header "ggml-metal.h"
    header "ggml-rpc.h"
    link "c++"
    link framework "Metal"
    link framework "MetalKit"
    link framework "Foundation"
    link framework "Accelerate"
    export *
}
MAP
xcrun libtool -static -o "$work/libggml-ios.a" $(find "$work/ios" -name '*.a' -path '*Release-iphoneos*') 2>/dev/null
xcrun libtool -static -o "$work/libggml-macos.a" $(find "$work/macos" -name '*.a') 2>/dev/null
rm -rf "$here/Frameworks/ggml.xcframework"
mkdir -p "$here/Frameworks"
xcodebuild -create-xcframework -library "$work/libggml-ios.a" -headers "$work/headers" \
    -library "$work/libggml-macos.a" -headers "$work/headers" -output "$here/Frameworks/ggml.xcframework" >/dev/null
echo "$here/Frameworks/ggml.xcframework"
