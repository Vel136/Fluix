---
sidebar_position: 1
---

# Getting Started

Fluix is a single-module adaptive object pool. Install it, configure a Factory and Reset, and start pooling.

---

## Installation

Get Fluix from the Roblox Creator Store:

**[Get Fluix on Creator Store](https://create.roblox.com/store/asset/84852268228213/Fluix)**

Drop the module into `ReplicatedStorage` and require it:

```lua
local Fluix = require(ReplicatedStorage.Fluix)
```

No dependencies. No setup. One require.

---

## Your First Pool

```lua
local Fluix = require(ReplicatedStorage.Fluix)

local BulletPool = Fluix.new({
    Factory = function() return Bullet.new() end,
    Reset   = function(b) b:Reset() end,
    MinSize = 32,
})

-- Pre-allocate before gameplay starts
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

## Signals

Every pool exposes lifecycle signals via [VeSignal](https://vel136.github.io/VeSignal/):

```lua
BulletPool.Signals.OnMiss:Connect(function(obj)
    warn("Pool miss — consider raising MinSize or Headroom")
end)

BulletPool.Signals.OnAcquire:Connect(function(obj)
    -- obj just left the pool
end)
```

---

## Hot/Cold Tiers

Set `HotPoolSize` to maintain a small sub-pool of immediately-ready objects. Acquire drains hot first, then cold. Release refills hot first.

```lua
local Pool = Fluix.new({
    Factory     = function() return Part.new() end,
    Reset       = function(p) p.Parent = nil end,
    MinSize     = 64,
    HotPoolSize = 8,   -- keep 8 objects always warm
})
```

---

## Cross-Pool Borrowing

On a factory miss, Fluix checks peer pools before allocating:

```lua
local BulletPool = Fluix.new({ Factory = ..., Reset = ... })
local FragPool   = Fluix.new({ Factory = ..., Reset = ... })

-- Mutual borrowing
BulletPool:RegisterPeer(FragPool)
FragPool:RegisterPeer(BulletPool)
```

---

## Lifecycle Control

```lua
pool:Pause()   -- disconnect Heartbeat during a cutscene
pool:Resume()  -- reconnect when gameplay resumes
pool:Drain()   -- evict all pooled objects under memory pressure
pool:Destroy() -- destroy the pool entirely
```

---

## Quick Reference

| I want to… | Method |
|------------|--------|
| Create a pool | [`Fluix.new`](../api/Fluix#new) |
| Pre-warm objects | [`pool:Seed`](../api/Fluix#Seed) |
| Get an object | [`pool:Acquire`](../api/Fluix#Acquire) |
| Return an object | [`pool:Release`](../api/Fluix#Release) |
| Return all live objects | [`pool:ReleaseAll`](../api/Fluix#ReleaseAll) |
| Check available count | [`pool:GetTotalAvailable`](../api/Fluix#GetTotalAvailable) |
| See all stats | [`pool:GetStats`](../api/Fluix#GetStats) |
| See practical examples | [Use Cases](./guides/use-cases) |
