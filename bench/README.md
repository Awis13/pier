# Benchmarks

The same Debian container on any backend, so the cost of crate's JIT shows
against Hypervisor.framework on a Mac:

```sh
pierctl -k ios/Resources/vmlinux --root ~/pier-bench --backend auto --exec 'bench:bash /bench/bench.sh' bench
pierctl -k ios/Resources/vmlinux --root ~/pier-bench --backend jit  --exec 'bench:bash /bench/bench.sh' bench
```

`bench.sh REGEX` runs only the tests whose names match. `CRATE_JIT_STATS=1`
prints crate's counters when the VM stops.

On an M-series Mac (16.11.2026), JIT against Hypervisor.framework:

| Test | JIT slower by |
|---|---|
| Python loops and calls | 4.7–4.9× |
| Node (JIT, `--jitless`, calls) | 3–7× |
| gcc, fork+exec | ~4.5× |
| 7-Zip, sysbench cpu | ~1.75× |
| sha256, memory latency | ~1× |

Most of the cost is the software TLB check every guest load and store takes
(about five host instructions and a load); jump-cache lookups for indirect
branches are about a tenth of the time.
