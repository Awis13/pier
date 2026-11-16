#!/bin/bash
# Pier CPU benchmarks: each line is "name seconds" (lower is better), then
# 7-Zip and sysbench scores. Installs what it needs on first run.
set -u
if ! command -v python3 >/dev/null || ! command -v node >/dev/null || ! command -v 7z >/dev/null || ! command -v sysbench >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null && apt-get install -y -qq python3 nodejs 7zip sysbench gcc >/dev/null 2>&1
fi
only=${1:-}
t() {
    local name=$1; shift
    [ -n "$only" ] && [[ ! "$name" =~ $only ]] && return
    local s=$(date +%s.%N)
    "$@" >/dev/null 2>&1
    local e=$(date +%s.%N)
    printf '%-14s %8.3f\n' "$name" "$(echo "$e - $s" | bc 2>/dev/null || awk "BEGIN{print $e-$s}")"
}
cat > /tmp/memlat.c <<'C'
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
int main(void){ size_t n=(128u<<20)/sizeof(size_t); size_t *a=malloc(n*sizeof(size_t));
 for(size_t i=0;i<n;i++) a[i]=i; srand(1);
 for(size_t i=n-1;i>0;i--){ size_t j=((size_t)rand()<<16^rand())%(i+1); size_t t=a[i];a[i]=a[j];a[j]=t; }
 size_t p=0; for(long i=0;i<20000000;i++) p=a[p]; printf("%zu\n",p); return 0; }
C
gcc -O2 -o /tmp/memlat /tmp/memlat.c 2>/dev/null
t py_loop     python3 -c 's=0
for i in range(10_000_000): s+=i'
t py_calls    python3 -c 'f=lambda n: n if n<2 else f(n-1)+f(n-2)
f(30)'
t py_dict     python3 -c 'd={}
for i in range(2_000_000): d[str(i)]=i
sum(d[str(i)] for i in range(2_000_000))'
t node_loop   node -e 'let s=0; for (let i=0;i<1e8;i++) s+=i'
t node_calls  node -e 'const f=n=>n<2?n:f(n-1)+f(n-2); f(35)'
t node_jitless node --jitless -e 'let s=0; for (let i=0;i<1e7;i++) s+=i'
t node_start  node -e '0'
t gzip        sh -c 'head -c 64M /dev/urandom > /tmp/r && gzip -1 -c /tmp/r'
t sha256      sh -c 'head -c 512M /dev/zero | sha256sum'
t memlat      /tmp/memlat
t gcc_build   gcc -O2 -o /tmp/m2 /tmp/memlat.c
t forkexec    sh -c 'for i in $(seq 500); do /bin/true; done'
if [ -z "$only" ]; then
    echo "7z_1t_mips     $(7z b -md22 -mmt1 2>/dev/null | awk '/^Tot:/{print $NF}')"
    echo "7z_4t_mips     $(7z b -md22 -mmt4 2>/dev/null | awk '/^Tot:/{print $NF}')"
    echo "sysbench_1t    $(sysbench cpu --cpu-max-prime=20000 --threads=1 --time=5 run 2>/dev/null | awk '/events per second/{print $NF}')"
fi
