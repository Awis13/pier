// Pier's GPU for ggml in a container: ggml's RPC backend, pointed at the
// iPad's GPU that the Pier app serves. ggml (and so Ollama and llama.cpp)
// loads it through GGML_BACKEND_PATH. When the GPU cannot be reached, it
// declines, and ggml carries on with the CPU.
#include <arpa/inet.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <string>
#include <sys/socket.h>
#include <unistd.h>
#include <linux/vm_sockets.h>
#include "ggml-rpc.h"
#include "ggml-backend-impl.h"

// Whether something answers at host:port (or vsock:port, the VM's host)
// within two seconds.
static bool reachable(const std::string & endpoint) {
    size_t colon = endpoint.rfind(':');
    if (colon == std::string::npos) return false;
    std::string host = endpoint.substr(0, colon), port = endpoint.substr(colon + 1);
    if (host == "vsock") {
        int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
        if (fd < 0) return false;
        sockaddr_vm vm{};
        vm.svm_family = AF_VSOCK;
        vm.svm_cid = VMADDR_CID_HOST;
        vm.svm_port = (unsigned) std::atoi(port.c_str());
        timeval tv{2, 0};
        setsockopt(fd, AF_VSOCK, SO_VM_SOCKETS_CONNECT_TIMEOUT, &tv, sizeof(tv));
        bool ok = connect(fd, (sockaddr *) &vm, sizeof(vm)) == 0;
        close(fd);
        return ok;
    }
    addrinfo hints{}, * res = nullptr;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host.c_str(), port.c_str(), &hints, &res) != 0 || !res) return false;
    int fd = socket(res->ai_family, SOCK_STREAM, 0);
    bool ok = false;
    if (fd >= 0) {
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        if (connect(fd, res->ai_addr, res->ai_addrlen) == 0) {
            ok = true;
        } else {
            pollfd p{fd, POLLOUT, 0};
            int err = 0;
            socklen_t len = sizeof(err);
            ok = poll(&p, 1, 2000) == 1 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0;
        }
        close(fd);
    }
    freeaddrinfo(res);
    return ok;
}

extern "C" {
GGML_BACKEND_API ggml_backend_reg_t ggml_backend_init(void) {
    const char * env = std::getenv("PIER_GPU");
    std::string endpoint = env && *env ? env : "vsock:50052";
    if (!reachable(endpoint)) {
        std::fprintf(stderr, "pier: the iPad's GPU does not answer at %s (is GPU on for this service in Pier?); using the CPU\n", endpoint.c_str());
        return nullptr;
    }
    return ggml_backend_rpc_add_server(endpoint.c_str());
}
GGML_BACKEND_API int ggml_backend_score(void) { return 1; }
}
