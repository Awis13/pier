#!/usr/bin/env python3
# Gives ggml's RPC server a memory budget (ggml_backend_rpc_set_memory_budget):
# it reports at most that much to clients and refuses allocations past it, so
# a client such as Ollama puts on the GPU only what the iPad can hold next to
# the VM. Applied to ggml/src/ggml-rpc/ggml-rpc.cpp by gpu/build-ggml.sh.
import sys

path = sys.argv[1]
s = open(path).read()
if "pier_budget" in s:
    sys.exit(0)

def rep(a, b):
    global s
    assert s.count(a) == 1, a[:60]
    s = s.replace(a, b)

rep('#include "ggml-rpc.h"\n', '''#include "ggml-rpc.h"
#include <atomic>

// What clients may allocate on this server's devices, in bytes (0: no limit),
// and what they hold now.
static std::atomic<size_t> pier_budget{0};
static std::atomic<size_t> pier_used{0};

extern "C" GGML_BACKEND_API void ggml_backend_rpc_set_memory_budget(size_t bytes) {
    pier_budget = bytes;
}
''')
rep('''    ggml_backend_buffer_t buffer = ggml_backend_buft_alloc_buffer(buft, request.size);
    response.remote_ptr = 0;''', '''    size_t budget = pier_budget.load();
    ggml_backend_buffer_t buffer = nullptr;
    if (budget == 0 || pier_used.load() + request.size <= budget) {
        buffer = ggml_backend_buft_alloc_buffer(buft, request.size);
    }
    if (buffer != nullptr) {
        pier_used += buffer->size;
    }
    response.remote_ptr = 0;''')
rep('''    ggml_backend_buffer_free(buffer);
    buffers.erase(buffer);
    return true;''', '''    pier_used -= buffer->size;
    ggml_backend_buffer_free(buffer);
    buffers.erase(buffer);
    return true;''')
rep('''    for (auto buffer : buffers) {
        ggml_backend_buffer_free(buffer);
    }''', '''    for (auto buffer : buffers) {
        pier_used -= buffer->size;
        ggml_backend_buffer_free(buffer);
    }''')
rep('''    ggml_backend_dev_memory(dev, &free, &total);
    response.free_mem = free;
    response.total_mem = total;''', '''    ggml_backend_dev_memory(dev, &free, &total);
    size_t budget = pier_budget.load(), used = pier_used.load();
    if (budget > 0) {
        total = std::min(total, budget);
        free = std::min(free, budget > used ? budget - used : 0);
    }
    response.free_mem = free;
    response.total_mem = total;''')
open(path, "w").write(s)
