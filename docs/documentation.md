---
sidebar_position: 2
sidebar_label: "Overview"
---

# Fluix

*Every object ready before demand arrives.*

Adaptive, demand-smoothed object pooling for Roblox.

Fluix is a per-instance generic object pool. It tracks acquisition demand with an exponential moving average, pre-warms and gradually shrinks the pool to match real usage, and exposes hot/cold priority tiers, cross-pool borrowing, per-object TTL, and lifecycle signals — all with zero allocations on the acquire/release hot path.

---

## One File. One Require.

Drop Fluix into `ReplicatedStorage` and require it from any script.

```lua
local Fluix = require(ReplicatedStorage.Fluix)
```

---

## Basic Pool

```lua
local BulletPool = Fluix.new({
    Factory = function() return Bullet.new() end,
    Reset   = function(b) b:Reset() end,
    MinSize = 32,
})

BulletPool:Seed(20)

local bullet = BulletPool:Acquire(function(b)
    b.Position = spawnPos
    b.Velocity = direction * speed
end)

BulletPool:Release(bullet)
```

---

## Adaptive Sizing

Fluix measures acquisitions-per-window using an exponential moving average (EMA). The Heartbeat pre-warms the cold pool toward `EMA × Headroom`, then gradually shrinks it when demand drops — after `ShrinkGraceSeconds` of sustained surplus.

```lua
local Pool = Fluix.new({
    Factory            = function() return Part.new() end,
    Reset              = function(p) p.Parent = nil end,
    MinSize            = 16,
    Headroom           = 3.0,       -- target = EMA × 3
    ShrinkGraceSeconds = 5.0,       -- wait 5s before evicting surplus
    Alpha              = 0.2,       -- slower EMA smoothing
})
```

---

## Hot/Cold Tiers

When `HotPoolSize > 0`, a dedicated sub-pool of the most-recently-used objects is maintained. Acquire drains hot first (O(1) pop), then cold. Release refills hot first.

```lua
local Pool = Fluix.new({
    Factory     = function() return ExplosionEffect.new() end,
    Reset       = function(e) e:Reset() end,
    MinSize     = 64,
    HotPoolSize = 8,
})
```

---

## Signals

Every pool exposes a `Signals` table of [VeSignal](https://vel136.github.io/VeSignal/) connections:

| Signal | Parameters | Fires when |
|--------|-----------|------------|
| `OnAcquire` | `obj: T` | Object left the pool |
| `OnRelease` | `obj: T` | Object returned to the pool |
| `OnMiss` | `obj: T` | Factory was called (pool was empty) |
| `OnGrow` | `added, total` | Pool expanded |
| `OnShrink` | `removed, total` | Pool contracted |

```lua
Pool.Signals.OnMiss:Connect(function(obj)
    warn("Pool miss — consider raising MinSize or Headroom")
end)
```

---

## Cross-Pool Borrowing

On a factory miss, Fluix checks `BorrowPeers` in order before allocating a new object. The borrowed object is tracked as live in the borrowing pool and released normally.

```lua
local BulletPool = Fluix.new({ Factory = ..., Reset = ..., BorrowPeers = { FragPool } })

-- Or register dynamically:
BulletPool:RegisterPeer(FragPool)
FragPool:RegisterPeer(BulletPool)
```

---

## Per-Object TTL

Set `TTL` to automatically reclaim objects that are held too long. Fluix's Heartbeat force-resets and returns any live object that exceeds its TTL.

```lua
local Pool = Fluix.new({
    Factory = function() return StatusEffect.new() end,
    Reset   = function(e) e:Deactivate() end,
    TTL     = 10,   -- reclaim after 10 seconds
})
```

---

## Lifecycle Control

```lua
pool:Pause()     -- disconnect Heartbeat (preserves state)
pool:Resume()    -- reconnect Heartbeat
pool:Drain()     -- evict all pooled objects; live objects unaffected
pool:ReleaseAll() -- force-return every live object at once
pool:Destroy()   -- tear down the pool entirely
```

---

## Configuration Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `Factory` | `() -> T` | **required** | Allocates a fresh object |
| `Reset` | `(T) -> ()` | **required** | Clears an object before re-pooling |
| `MinSize` | `number` | `8` | Cold pool floor |
| `MaxSize` | `number` | `256` | Hard cold-pool ceiling |
| `Alpha` | `number` | `0.3` | EMA smoothing coefficient (0–1) |
| `Headroom` | `number` | `2.0` | Target multiplier over EMA |
| `SampleWindow` | `number` | `0.5` | Demand window in seconds |
| `PrewarmBatchSize` | `number` | `16` | Max allocs per Heartbeat tick |
| `ShrinkGraceSeconds` | `number` | `3.0` | Surplus duration before eviction |
| `IdleDisconnectWindows` | `number` | `6` | Idle windows before dormancy |
| `HotPoolSize` | `number` | `0` | Hot sub-pool capacity (0 = off) |
| `TTL` | `number` | `nil` | Live object time limit in seconds |
| `MissRateThreshold` | `number` | `nil` | Miss rate warn threshold |
| `OnOverflow` | `(T) -> ()` | `nil` | Called when pool is full on Release |
| `BorrowPeers` | `{ Pooler }` | `{}` | Pools to borrow from on miss |
