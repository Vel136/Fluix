---
sidebar_position: 1
---

# Use Cases

Practical patterns for the most common Fluix use-cases.

---

## Bullet / Projectile Pool

The most common pool pattern. Acquire on fire, release on impact or expiry.

```lua
local Fluix = require(ReplicatedStorage.Fluix)

local BulletPool = Fluix.new({
    Factory     = function() return Bullet.new() end,
    Reset       = function(b) b:Reset() end,
    MinSize     = 64,
    HotPoolSize = 8,    -- keep 8 bullets instantly ready
    TTL         = 10,   -- force-reclaim bullets stuck longer than 10s
    OnOverflow  = function(b) b:Destroy() end,
})

BulletPool:Seed(32)

local function onFire(origin, direction, speed)
    local bullet = BulletPool:Acquire(function(b)
        b.Position = origin
        b.Velocity = direction * speed
        b:Enable()
    end)
    return bullet
end

local function onImpact(bullet)
    BulletPool:Release(bullet)
end
```

---

## Wave / Round Reset

Use `ReleaseAll` to force-return every live object at the end of a wave without tracking individual references.

```lua
local EnemyPool = Fluix.new({
    Factory = function() return Enemy.new() end,
    Reset   = function(e) e:Reset() end,
    MinSize = 32,
})

local function onWaveEnd()
    EnemyPool:ReleaseAll()  -- all live enemies returned instantly
end
```

---

## Shared Effect Pool with Cross-Pool Borrowing

Two similar effect types share a fallback pool. On a miss in `ExplosionPool`, Fluix tries `SmokePool` before calling Factory.

```lua
local ExplosionPool = Fluix.new({
    Factory  = function() return ExplosionEffect.new() end,
    Reset    = function(e) e:Hide() end,
    MinSize  = 16,
})

local SmokePool = Fluix.new({
    Factory  = function() return SmokeEffect.new() end,
    Reset    = function(s) s:Hide() end,
    MinSize  = 16,
})

-- Mutual borrowing — each pool falls back to the other on miss
ExplosionPool:RegisterPeer(SmokePool)
SmokePool:RegisterPeer(ExplosionPool)
```

---

## Cutscene / Loading Pause

Suppress Heartbeat ticks during a cutscene to avoid unnecessary pre-warm work.

```lua
local function onCutsceneStart()
    BulletPool:Pause()
    EnemyPool:Pause()
end

local function onCutsceneEnd()
    BulletPool:Resume()
    EnemyPool:Resume()
end
```

---

## Memory Pressure Drain

Evict all pooled objects without destroying the pool, freeing memory during a loading screen while keeping the pool alive for the next session.

```lua
local function onLoadingScreenOpen()
    BulletPool:Drain()   -- evicts cold + hot; live objects unaffected
end
```

---

## Miss Monitoring

Wire up `OnMiss` to measure pool health and tune `MinSize` or `Headroom` in development.

```lua
BulletPool.Signals.OnMiss:Connect(function(obj)
    warn(string.format(
        "[BulletPool] Miss #%d — consider raising MinSize or Headroom",
        BulletPool:GetMissCount()
    ))
end)
```

---

## Zero-Allocation Hot-Path Inspection

Check pool state without allocating on the acquire/release path.

```lua
game:GetService("RunService").Heartbeat:Connect(function()
    if BulletPool:GetTotalAvailable() < 4 then
        -- Pool running low — log or pre-warm externally
    end
end)
```

---

## Stat Snapshot

`GetStats()` returns a snapshot table useful for debugging dashboards or logging.

```lua
local stats = BulletPool:GetStats()
print(stats.LiveCount, stats.HotSize, stats.ColdSize, stats.MissCount)
```
