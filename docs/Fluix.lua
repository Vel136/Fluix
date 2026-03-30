-- MIT License
--
-- Copyright (c) 2026 VeDevelopment

--[=[
	@class Fluix

	Adaptive, demand-smoothed object pooling for Roblox.

	@external Signal https://vel136.github.io/VeSignal/

	Fluix is a per-instance generic object pool. It tracks acquisition demand
	with an exponential moving average, pre-warms and gradually shrinks the pool
	to match real usage, and exposes hot/cold priority tiers, cross-pool
	borrowing, per-object TTL, and lifecycle signals — all with zero allocations
	on the acquire/release hot path.

	**Adaptive Sizing.** The Heartbeat pre-warms the cold pool toward
	`EMA × Headroom` and gradually shrinks it after `ShrinkGraceSeconds` of
	sustained surplus. The pool never falls below `MinSize` or rises above
	`MaxSize`.

	**Priority Tiers.** When `HotPoolSize > 0`, a hot sub-pool is maintained.
	Acquire drains hot first, then cold. Release refills hot first, then cold.

	**Cross-Pool Borrowing.** On a factory miss, Fluix iterates `BorrowPeers`
	before allocating. The borrowed object is tracked as live in the borrowing
	pool and released normally.

	**Per-Object TTL.** Acquired objects are stamped with a timestamp. The
	Heartbeat force-reclaims any object held longer than `TTL` seconds.

	```lua
	local Fluix = require(ReplicatedStorage.Fluix)

	local BulletPool = Fluix.new({
	    Factory     = function() return Bullet.new() end,
	    Reset       = function(b) b:Reset() end,
	    MinSize     = 32,
	    HotPoolSize = 8,
	    TTL         = 10,
	})

	BulletPool:Seed(20)

	local bullet = BulletPool:Acquire(function(b)
	    b.Position = spawnPos
	    b.Velocity = direction * speed
	end)

	BulletPool:Release(bullet)
	```
]=]
local Fluix = {}

-- ─── Constructor ──────────────────────────────────────────────────────────────

--[=[
	@function new
	@within Fluix

	Creates a new, independent adaptive object pool.

	`Factory` and `Reset` are required. All other config fields are optional
	and fall back to sensible defaults.

	```lua
	local Pool = Fluix.new({
	    Factory  = function() return Part.new() end,
	    Reset    = function(p) p.Parent = nil end,
	    MinSize  = 16,
	    Headroom = 3.0,
	})
	```

	@param config PoolerConfig -- Pool configuration table.
	@return Pooler -- A new pool instance.
]=]
function Fluix.new(config) end

-- ─── Signals ──────────────────────────────────────────────────────────────────

--[=[
	@prop Signals PoolerSignals
	@within Fluix

	Lifecycle signals for this pool. All five are [Signal] connections.

	| Signal | Parameters | Fires when |
	|--------|-----------|------------|
	| `OnAcquire` | `obj: T` | Object left the pool |
	| `OnRelease` | `obj: T` | Object returned to the pool |
	| `OnMiss` | `obj: T` | Factory was called (pool was empty) |
	| `OnGrow` | `added: number, total: number` | Pool expanded |
	| `OnShrink` | `removed: number, total: number` | Pool contracted |

	```lua
	Pool.Signals.OnMiss:Connect(function(obj)
	    warn("Pool miss — consider raising MinSize or Headroom")
	end)

	Pool.Signals.OnGrow:Connect(function(added, total)
	    print("Pool grew by", added, "— total:", total)
	end)
	```
]=]
Fluix.Signals = nil

-- ─── Acquire & Release ────────────────────────────────────────────────────────

--[=[
	@method Seed
	@within Fluix

	Pre-allocates `n` objects into the pool. Drains the hot sub-pool first,
	then fills cold up to `MaxSize`. Safe to call before gameplay starts.

	```lua
	Pool:Seed(32)  -- warm up 32 objects before the round begins
	```

	@param n number -- Number of objects to pre-allocate.
]=]
function Fluix:Seed(n) end

--[=[
	@method Acquire
	@within Fluix

	Acquires an object from the pool. Drains the hot sub-pool first, then cold.
	On a miss, Fluix tries `BorrowPeers` in order before calling `Factory`.

	An optional `Apply` function is called on the object before it is returned,
	allowing inline initialisation without a separate step.

	```lua
	-- Without inline init
	local bullet = Pool:Acquire()
	bullet.Position = spawnPos

	-- With inline init (preferred on hot paths)
	local bullet = Pool:Acquire(function(b)
	    b.Position = spawnPos
	    b.Velocity = direction * speed
	end)
	```

	@param Apply ((obj: T) -> ())? -- Optional initialiser called before returning.
	@return T -- The acquired object.
]=]
function Fluix:Acquire(Apply) end

--[=[
	@method Release
	@within Fluix

	Returns an object to the pool. `Reset` is called on the object. If the pool
	is full, `OnOverflow` is called instead (or the object is dropped if
	`OnOverflow` is not set).

	Double-release is detected and a warning is emitted.

	```lua
	Pool:Release(bullet)
	```

	@param obj T -- The object to return.
]=]
function Fluix:Release(obj) end

--[=[
	@method ReleaseAll
	@within Fluix

	Force-returns every currently live object at once. `Reset` is called on
	each object. Useful for wave clears or round resets.

	```lua
	Pool:ReleaseAll()
	```
]=]
function Fluix:ReleaseAll() end

-- ─── Peers ────────────────────────────────────────────────────────────────────

--[=[
	@method RegisterPeer
	@within Fluix

	Adds a sibling pool to the borrow list. On a factory miss, Fluix will
	attempt to pop an object from each registered peer's cold pool in order.

	```lua
	BulletPool:RegisterPeer(FragPool)
	FragPool:RegisterPeer(BulletPool)
	```

	@param peer Pooler -- The sibling pool to register.
]=]
function Fluix:RegisterPeer(peer) end

--[=[
	@method UnregisterPeer
	@within Fluix

	Removes a sibling pool from the borrow list.

	```lua
	BulletPool:UnregisterPeer(FragPool)
	```

	@param peer Pooler -- The sibling pool to remove.
]=]
function Fluix:UnregisterPeer(peer) end

-- ─── Lifecycle ────────────────────────────────────────────────────────────────

--[=[
	@method Pause
	@within Fluix

	Disconnects the Heartbeat without clearing any pool state. Pre-warming,
	adaptive sizing, and TTL checks stop until `Resume` is called. Useful during
	cutscenes or loading screens.

	```lua
	Pool:Pause()
	```
]=]
function Fluix:Pause() end

--[=[
	@method Resume
	@within Fluix

	Reconnects the Heartbeat. Safe to call if already active.

	```lua
	Pool:Resume()
	```
]=]
function Fluix:Resume() end

--[=[
	@method Drain
	@within Fluix

	Evicts all pooled objects from the hot and cold tiers, calling `OnOverflow`
	(or discarding) each one. Does not touch live objects or reset the EMA.
	The pool continues to function after draining.

	```lua
	Pool:Drain()  -- free memory during a loading screen
	```
]=]
function Fluix:Drain() end

--[=[
	@method Prewarm
	@within Fluix

	Immediately allocates `n` objects into the cold pool, bypassing the
	Heartbeat batch limit. Use this for one-shot forced pre-warming.

	```lua
	Pool:Prewarm(16)
	```

	@param n number -- Number of objects to allocate immediately.
]=]
function Fluix:Prewarm(n) end

--[=[
	@method Resize
	@within Fluix

	Updates the `MinSize` and `MaxSize` limits at runtime. Takes effect on the
	next Heartbeat tick.

	```lua
	Pool:Resize(64, 512)
	```

	@param newMin number -- New cold-pool floor.
	@param newMax number -- New cold-pool ceiling.
]=]
function Fluix:Resize(newMin, newMax) end

--[=[
	@method Destroy
	@within Fluix

	Destroys the pool entirely. Disconnects the Heartbeat, clears all state,
	and marks the pool as destroyed. Calling any method after `Destroy` is a
	no-op or will error.

	```lua
	Pool:Destroy()
	```
]=]
function Fluix:Destroy() end

-- ─── Inspection ───────────────────────────────────────────────────────────────

--[=[
	@method GetStats
	@within Fluix

	Returns a snapshot table of all pool metrics. Useful for dashboards and
	debugging.

	```lua
	local stats = Pool:GetStats()
	print(stats.LiveCount, stats.HotSize, stats.PoolSize, stats.MissCount)
	```

	@return PoolerStats -- Snapshot of current pool metrics.
]=]
function Fluix:GetStats() end

--[=[
	@method GetLiveCount
	@within Fluix

	Returns the number of objects currently out of the pool (acquired but not
	yet released). Zero-allocation.

	@return number
]=]
function Fluix:GetLiveCount() end

--[=[
	@method GetPoolSize
	@within Fluix

	Returns the number of objects currently in the cold pool. Zero-allocation.

	@return number
]=]
function Fluix:GetPoolSize() end

--[=[
	@method GetHotSize
	@within Fluix

	Returns the number of objects currently in the hot sub-pool. Zero-allocation.

	@return number
]=]
function Fluix:GetHotSize() end

--[=[
	@method GetTotalAvailable
	@within Fluix

	Returns the total number of objects that can be acquired right now
	(hot + cold). Zero-allocation.

	```lua
	if Pool:GetTotalAvailable() < 4 then
	    warn("Pool running low")
	end
	```

	@return number
]=]
function Fluix:GetTotalAvailable() end

--[=[
	@method GetDemandEMA
	@within Fluix

	Returns the smoothed acquisitions-per-window value tracked by the EMA.
	Zero-allocation.

	@return number
]=]
function Fluix:GetDemandEMA() end

--[=[
	@method GetTargetSize
	@within Fluix

	Returns the current EMA-derived pre-warm target for the cold pool.
	Zero-allocation.

	@return number
]=]
function Fluix:GetTargetSize() end

--[=[
	@method GetMissCount
	@within Fluix

	Returns the total number of factory misses since the pool was created.
	Zero-allocation.

	@return number
]=]
function Fluix:GetMissCount() end

--[=[
	@method IsOwned
	@within Fluix

	Returns `true` if `obj` is currently live in this pool (acquired but not
	yet released).

	@param obj T -- The object to check.
	@return boolean
]=]
function Fluix:IsOwned(obj) end

--[=[
	@method IsActive
	@within Fluix

	Returns `true` if the Heartbeat connection is currently live.

	@return boolean
]=]
function Fluix:IsActive() end

--[=[
	@method IsDestroyed
	@within Fluix

	Returns `true` if `Destroy` has been called on this pool.

	@return boolean
]=]
function Fluix:IsDestroyed() end

return Fluix
