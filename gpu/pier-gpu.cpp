// Pier's GPU for ggml in a container: the RPC backend, already pointed at
// the iPad's GPU in the Pier app. Loaded by ggml (and so Ollama, llama.cpp)
// as libggml-rpc.so from its backend directory.
#include <cstdlib>
#include "ggml-rpc.h"
#include "ggml-backend-impl.h"

extern "C" {
GGML_BACKEND_API ggml_backend_reg_t ggml_backend_init(void) {
    const char * endpoint = std::getenv("PIER_GPU");
    if (!endpoint || !*endpoint) endpoint = "172.20.0.1:50052";
    return ggml_backend_rpc_add_server(endpoint);
}
GGML_BACKEND_API int ggml_backend_score(void) { return 1; }
}
