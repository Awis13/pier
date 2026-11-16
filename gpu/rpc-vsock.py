#!/usr/bin/env python3
# Lets ggml's RPC client reach a server on the VM's host over vsock: the
# endpoint "vsock:PORT" connects to the host (CID 2) at PORT instead of over
# TCP. Applied to ggml/src/ggml-rpc/transport.cpp by gpu/build-shim.sh.
import sys

path = sys.argv[1]
s = open(path).read()
if "AF_VSOCK" in s:
    sys.exit(0)

def rep(a, b):
    global s
    assert s.count(a) == 1, a[:60]
    s = s.replace(a, b)

rep('''socket_ptr socket_t::connect(const char * host, int port) {
''', '''socket_ptr socket_t::connect(const char * host, int port) {
#ifdef __linux__
    // Pier: the iPad's GPU is served by the app the VM runs in.
    if (strcmp(host, "vsock") == 0) {
        int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
        if (!is_valid_fd(fd)) {
            return nullptr;
        }
        struct sockaddr_vm vm;
        memset(&vm, 0, sizeof(vm));
        vm.svm_family = AF_VSOCK;
        vm.svm_cid = VMADDR_CID_HOST;
        vm.svm_port = port;
        if (::connect(fd, (struct sockaddr *)&vm, sizeof(vm)) < 0) {
            close(fd);
            return nullptr;
        }
        return socket_ptr(new socket_t(std::make_unique<impl>(fd)));
    }
#endif
''')
first_include = s.index("#include")
s = s[:first_include] + "#ifdef __linux__\n#include <sys/socket.h>\n#include <linux/vm_sockets.h>\n#endif\n" + s[first_include:]
open(path, "w").write(s)
