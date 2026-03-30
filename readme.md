# Fluix

Adaptive, demand-smoothed object pooling for Roblox.

**[Documentation](https://vel136.github.io/Fluix/)** · **[Creator Store](https://create.roblox.com/store/asset/84852268228213/Fluix)**

**Version:** V1.0.0

Fluix is a per-instance generic object pool for Roblox Luau. It tracks acquisition demand with an exponential moving average, pre-warms and gradually shrinks the pool to match real usage, and exposes hot/cold priority tiers, cross-pool borrowing, per-object TTL, and lifecycle signals — all with zero allocations on the acquire/release hot path.

---

## Install

Get Fluix from the **[Roblox Creator Store](https://create.roblox.com/store/asset/84852268228213/Fluix)**, drop the module into `ReplicatedStorage`, and require it:

```lua
local Fluix = require(ReplicatedStorage.Fluix)
```

No external dependencies. One require.

---

## Quick Start

```lua
local Fluix = require(ReplicatedStorage.Fluix)

local BulletPool = Fluix.new({
    Factory = function() return Bullet.new() end,
    Reset   = function(b) b:Reset() end,
    MinSize = 32,
})

-- Pre-allocate 20 objects before gameplay starts
BulletPool:Seed(20)

-- Acquire with an optional inline initialiser
local bullet = BulletPool:Acquire(function(b)
    b.Position = spawnPos
    b.Velocity = direction * speed
end)

-- Return when done
BulletPool:Release(bullet)
```

---

## Configuration

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `Factory` | `() -> T` | **required** | Allocates a fresh object |
| `Reset` | `(T) -> ()` | **required** | Clears an object before re-pooling |
| `MinSize` | `number` | `8` | Floor the cold pool never shrinks below |
| `MaxSize` | `number` | `256` | Hard cold-pool ceiling |
| `Alpha` | `number` | `0.3` | EMA smoothing coefficient (0–1) |
| `Headroom` | `number` | `2.0` | Pool target multiplier over smoothed demand |
| `SampleWindow` | `number` | `0.5` | Demand measurement interval in seconds |
| `PrewarmBatchSize` | `number` | `16` | Max allocations per Heartbeat tick |
| `ShrinkGraceSeconds` | `number` | `3.0` | Surplus duration before eviction begins |
| `IdleDisconnectWindows` | `number` | `6` | Consecutive idle windows before dormancy |
| `HotPoolSize` | `number` | `0` | Dedicated hot sub-pool capacity (0 = off) |
| `TTL` | `number` | `nil` | Max seconds an object may be live (nil = off) |
| `MissRateThreshold` | `number` | `nil` | Miss rate 0–1 that triggers a warn() (nil = off) |
| `OnOverflow` | `(T) -> ()` | `nil` | Called when the pool is full on Release |
| `BorrowPeers` | `{ Pooler }` | `{}` | Sibling pools to borrow from on a miss |

---

## Signals

Each pool instance exposes a `Signals` table of [VeSignal](https://vel136.github.io/VeSignal/) connections:

| Signal | Fires with | Description |
|--------|-----------|-------------|
| `OnAcquire` | `obj: T` | Object left the pool |
| `OnRelease` | `obj: T` | Object returned to the pool |
| `OnMiss` | `obj: T` | Factory fallback used (pool was empty) |
| `OnGrow` | `added, total` | Pool expanded |
| `OnShrink` | `removed, total` | Pool contracted |

```lua
BulletPool.Signals.OnMiss:Connect(function(obj)
    warn("Pool miss — consider raising MinSize or Headroom")
end)
```

---

## API

**Lifecycle**

| Method | Description |
|--------|-------------|
| `Fluix.new(config)` | Create a new pool |
| `pool:Seed(n)` | Pre-allocate `n` objects |
| `pool:Acquire(initFn?)` | Get an object, with optional inline init |
| `pool:Release(obj)` | Return an object |
| `pool:ReleaseAll()` | Force-return every live object |
| `pool:Pause()` | Disconnect Heartbeat without destroying state |
| `pool:Resume()` | Reconnect Heartbeat |
| `pool:Drain()` | Evict all pooled objects (does not touch live) |
| `pool:Destroy()` | Destroy the pool |

**Peers**

| Method | Description |
|--------|-------------|
| `pool:RegisterPeer(other)` | Add a sibling pool to borrow from |
| `pool:UnregisterPeer(other)` | Remove a sibling pool |

**Inspection (zero-allocation)**

| Method | Description |
|--------|-------------|
| `pool:GetLiveCount()` | Objects currently out |
| `pool:GetPoolSize()` | Objects in the cold pool |
| `pool:GetHotSize()` | Objects in the hot sub-pool |
| `pool:GetTotalAvailable()` | Hot + cold (acquirable right now) |
| `pool:GetDemandEMA()` | Smoothed acquisitions-per-window |
| `pool:GetTargetSize()` | EMA-derived pre-warm target |
| `pool:GetMissCount()` | Lifetime total pool misses |
| `pool:IsActive()` | `true` if Heartbeat is live |
| `pool:IsDestroyed()` | `true` if `Destroy()` has been called |
| `pool:IsOwned(obj)` | `true` if `obj` is currently live in this pool |
| `pool:GetStats()` | Table of all stats |

---

## Benchmarks

Measured on Roblox server, 60 sample frames, 20 warmup frames. Throughput = acquire+release pairs per second. Round-trip latency = µs per acquire→release cycle.

| Profile | Peak ops/s | RT µs | Miss% |
|---------|-----------|-------|-------|
| Hot(16) + cold | **2,485,800** | **0.40** | 0.0% |
| Cold-pool only | 2,268,603 | 0.44 | 0.0% |
| Cross-pool borrow | 1,927,674 | — | 0.0% |
| Miss-only (factory) | 707,214 | 1.41 | 100.0% |

**ReleaseAll** per-object cost: ~0.37–0.49 µs/obj across ×100 to ×20,000 objects.

**Heartbeat overhead**: < 0.001 ms (within noise floor).

---

## License

MIT — Copyright © 2026 VeDevelopment
