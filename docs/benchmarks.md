---
sidebar_position: 3
---

# Benchmarks

All figures measured on a Roblox server with `--!native` and `--!optimize 2` enabled.
**60 sample frames, 20 warmup frames.**

> Throughput = acquire+release pairs per second.
> Round-trip latency = wall-clock µs per acquire→release cycle.
> Heartbeat overhead is approximate — treat as a relative signal.

---

## Summary

| Profile | Peak ops/s | RT µs | Miss% |
|---------|-----------|-------|-------|
| Hot(16) + cold | **2,485,800** | **0.40** | 0.0% |
| Cold-pool only | 2,268,603 | 0.44 | 0.0% |
| Cross-pool borrow | 1,927,674 | — | 0.0% |
| Miss-only (factory) | 707,214 | 1.41 | 100.0% |

---

## Profile 1 — Cold-pool only (`HotPoolSize = 0`)

| Seed | Ops | ops/s | RT µs | Miss% |
|------|-----|-------|-------|-------|
| 0 | ×100 | 2,061,856 | 0.48 | 0.0% |
| 0 | ×1,000 | 1,317,870 | 0.76 | 0.0% |
| 0 | ×5,000 | **2,268,603** | **0.44** | 0.0% |
| 0 | ×20,000 | 2,248,353 | 0.44 | 0.0% |
| 8 | ×100 | 2,000,000 | 0.50 | 0.0% |
| 8 | ×1,000 | 2,099,958 | 0.48 | 0.0% |
| 8 | ×5,000 | 2,135,383 | 0.47 | 0.0% |
| 8 | ×20,000 | 2,191,132 | 0.46 | 0.0% |
| 32 | ×1,000 | 2,148,689 | 0.47 | 0.0% |
| 128 | ×1,000 | 2,136,752 | 0.47 | 0.0% |
| 512 | ×1,000 | 2,095,997 | 0.48 | 0.0% |

---

## Profile 2 — Hot + cold tier (`HotPoolSize = 16`)

| Seed | Ops | ops/s | RT µs | Miss% |
|------|-----|-------|-------|-------|
| 0 | ×100 | 2,237,136 | 0.45 | 0.0% |
| 0 | ×1,000 | 2,335,357 | 0.43 | 0.0% |
| 0 | ×5,000 | 2,448,580 | 0.41 | 0.0% |
| 0 | ×20,000 | **2,485,800** | **0.40** | 0.0% |
| 32 | ×1,000 | 2,336,995 | 0.43 | 0.0% |
| 128 | ×1,000 | 1,767,097 | 0.57 | 0.0% |
| 512 | ×5,000 | 2,275,727 | 0.44 | 0.0% |

Hot+cold consistently outperforms cold-only by **~10%** at high operation counts due to better cache locality on the hot sub-pool stack pop.

---

## Profile 3 — Miss-only (factory fallback, pool always empty)

| Ops | ops/s | RT µs | Miss% |
|-----|-------|-------|-------|
| ×100 | 707,214 | 1.41 | 100.0% |
| ×1,000 | 641,478 | 1.56 | 100.0% |
| ×5,000 | 679,468 | 1.47 | 100.0% |
| ×20,000 | 682,200 | 1.47 | 100.0% |

Factory fallback costs **~3× more** than a pool hit (~1.47 µs vs ~0.44 µs). Pre-warm with `Seed` or tune `MinSize` and `Headroom` to eliminate misses on hot paths.

---

## Profile 4 — `ReleaseAll` bulk cost

| Objects | Total ms | µs / obj |
|---------|---------|---------|
| ×100 | 0.041 ms | 0.41 |
| ×1,000 | 0.372 ms | 0.37 |
| ×5,000 | 1.944 ms | 0.39 |
| ×20,000 | 9.844 ms | 0.49 |

Per-object cost is flat (~0.37–0.49 µs/obj) and scales linearly. Safe for wave clears up to a few thousand objects per call.

---

## Profile 5 — Cross-pool borrowing (primary empty, donor seeded)

| Ops | ops/s | Factory misses |
|-----|-------|---------------|
| ×100 | 1,661,130 | 0 |
| ×1,000 | 1,730,703 | 0 |
| ×5,000 | 1,927,674 | 0 |
| ×20,000 | 1,844,933 | 0 |

Borrowing from a peer avoids all factory calls and sustains **~1.8M ops/s** — roughly 80% of direct cold-pool throughput, with zero allocations.

---

## Profile 6 — Heartbeat background overhead

```
Heartbeat overhead: < 0.001 ms  (within noise floor)
```

The adaptive sizing, EMA demand tracking, and TTL scan running in the background introduce no measurable per-frame cost under normal pool sizes.
