--!native
--!optimize 2
--!strict

--[[
	MIT License

	Copyright (c) 2026 VeDevelopment

	Permission is hereby granted, free of charge, to any person obtaining a copy
	of this software and associated documentation files (the "Software"), to deal
	in the Software without restriction, including without limitation the rights
	to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
	copies of the Software, and to permit persons to whom the Software is
	furnished to do so, subject to the following conditions:

	The above copyright notice and this permission notice shall be included in all
	copies or substantial portions of the Software.

	THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
	IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
	FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
	AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
	LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
	OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
	SOFTWARE.
]]

-- ─── Fluix ────────────────────────────────────────────────────────────────────
--[[
    Adaptive, demand-smoothed generic object pool.
    Per-instance design — multiple pools can coexist with independent tuning.
]]

local Identity = "Fluix"

-- ─── Services ────────────────────────────────────────────────────────────────

local RunService = game:GetService("RunService")

-- ─── Module References ───────────────────────────────────────────────────────

local Signal = require(script.VeSignal)

-- ─── Types ───────────────────────────────────────────────────────────────────

export type PoolerConfig<T> = {
	Factory              : () -> T,
	Reset                : (obj: T) -> (),
	MinSize              : number?,
	MaxSize              : number?,
	Alpha                : number?,
	Headroom             : number?,
	SampleWindow         : number?,
	PrewarmBatchSize     : number?,
	ShrinkGraceSeconds   : number?,
	IdleDisconnectWindows: number?,
	HotPoolSize          : number?,
	TTL                  : number?,
	MissRateThreshold    : number?,
	OnOverflow           : ((obj: T) -> ())?,
	BorrowPeers          : { Pooler<any> }?,
}

export type PoolerStats = {
	HotSize         : number,
	PoolSize        : number,
	TargetSize      : number,
	DemandEMA       : number,
	MissCount       : number,
	MissesThisWindow: number,
	LiveCount       : number,
	IsActive        : boolean,
}

--[[
    PoolerSignals<T>

    All five signals are typed with UDTF-derived Fire/Wait signatures so callers
    get full argument inference without casting. OnAcquire/OnRelease/OnMiss each
    pass the pooled object; OnGrow/OnShrink pass numeric pool-size deltas.
]]
export type PoolerSignals<T> = {
	OnAcquire: Signal.Signal<(obj: T) -> ()>,
	OnRelease: Signal.Signal<(obj: T) -> ()>,
	OnMiss   : Signal.Signal<(obj: T) -> ()>,
	OnGrow   : Signal.Signal<(added: number, total: number) -> ()>,
	OnShrink : Signal.Signal<(removed: number, total: number) -> ()>,
}

--[[
    Pooler<T>

    Unified type that covers both the public API surface and all private fields.
    Private fields use the underscore convention; Luau does not enforce access
    modifiers, so the distinction is purely by naming discipline.

    Internal methods (_BorrowObject, _PushToPool, _HeartbeatTick,
    _EnsureConnected) are included here so that every method body receives a
    fully typed self without any unsafe casts inside the implementation.
]]
export type Pooler<T> = {
	-- ── Private State ─────────────────────────────────────────────────────────
	_Factory                 : () -> T,
	_Reset                   : (obj: T) -> (),
	_OnOverflow              : ((obj: T) -> ())?,
	_MIN_POOL_SIZE           : number,
	_MAX_POOL_SIZE           : number,
	_EMA_ALPHA               : number,
	_HEADROOM                : number,
	_SAMPLE_WINDOW           : number,
	_PREWARM_BATCH_SIZE      : number,
	_SHRINK_GRACE_SECONDS    : number,
	_IDLE_DISCONNECT_WINDOWS : number,
	_HOT_MAX                 : number,
	_HotPool                 : { T },
	_HotSize                 : number,
	_Pool                    : { T },
	_PoolSize                : number,
	_TTL                     : number?,
	_NextTTLScan             : number,
	_MissRateThreshold       : number?,
	-- Peers are Pooler<any> because each peer can carry a different object type;
	-- the caller is responsible for type compatibility at the borrowing boundary.
	_BorrowPeers             : { Pooler<any> },
	_DemandEMA               : number,
	_WindowAcquisitions      : number,
	_WindowStart             : number,
	_TargetSize              : number,
	_LastDemandSatisfiedTime : number,
	_IdleWindowCount         : number,
	_HeartbeatConnection     : RBXScriptConnection?,
	_Destroyed               : boolean,
	_Paused                  : boolean,
	_MissCount               : number,
	_MissesThisWindow        : number,
	-- Keyed by the object reference; value is the acquisition timestamp.
	-- Using [any] avoids a T-as-key constraint, which is unsound for primitive T.
	_Live                    : { [any]: number },
	_LiveCount               : number,
	-- ── Public State ──────────────────────────────────────────────────────────
	Signals                  : PoolerSignals<T>,
	-- ── Internal Methods ──────────────────────────────────────────────────────
	_BorrowObject   : (self: Pooler<T>) -> T?,
	_PushToPool     : (self: Pooler<T>, obj: T) -> (),
	_HeartbeatTick  : (self: Pooler<T>) -> (),
	_EnsureConnected: (self: Pooler<T>) -> (),
	-- ── Public Methods ────────────────────────────────────────────────────────
	Seed             : (self: Pooler<T>, ExpectedDemand: number) -> (),
	Acquire          : (self: Pooler<T>, Apply: ((obj: T) -> ())?) -> T,
	Release          : (self: Pooler<T>, obj: T) -> (),
	ReleaseAll       : (self: Pooler<T>) -> (),
	Destroy          : (self: Pooler<T>) -> (),
	GetStats         : (self: Pooler<T>) -> PoolerStats,
	RegisterPeer     : (self: Pooler<T>, peer: Pooler<any>) -> (),
	UnregisterPeer   : (self: Pooler<T>, peer: Pooler<any>) -> (),
	Pause            : (self: Pooler<T>) -> (),
	Resume           : (self: Pooler<T>) -> (),
	Drain            : (self: Pooler<T>) -> (),
	Prewarm          : (self: Pooler<T>, n: number) -> (),
	Resize           : (self: Pooler<T>, newMin: number, newMax: number) -> (),
	IsOwned          : (self: Pooler<T>, obj: T) -> boolean,
	GetLiveCount     : (self: Pooler<T>) -> number,
	GetPoolSize      : (self: Pooler<T>) -> number,
	GetHotSize       : (self: Pooler<T>) -> number,
	GetTotalAvailable: (self: Pooler<T>) -> number,
	GetDemandEMA     : (self: Pooler<T>) -> number,
	GetTargetSize    : (self: Pooler<T>) -> number,
	GetMissCount     : (self: Pooler<T>) -> number,
	IsActive         : (self: Pooler<T>) -> boolean,
	IsDestroyed      : (self: Pooler<T>) -> boolean,
}

-- ─── Class Table ─────────────────────────────────────────────────────────────
-- Untyped locally; Pooler<T> is enforced at the constructor boundary and
-- on every method via explicit self annotation (dot syntax).

local FluixClass = {}
FluixClass.__index = FluixClass

-- ─── Constructor ─────────────────────────────────────────────────────────────

--[=[
    FluixClass.new

    Creates a new, independent object pool. All tuning, signal, ownership, and
    tier state is isolated per instance — no shared globals.

    Parameters:
        config: PoolerConfig<T>

    Returns:
        Pooler<T>
]=]
function FluixClass.new<T>(config: PoolerConfig<T>): Pooler<T>
	assert(type(config.Factory) == "function", Identity .. ": config.Factory is required")
	assert(type(config.Reset)   == "function", Identity .. ": config.Reset is required")

	-- Cast the empty table to Pooler<T> up front so every field assignment
	-- below is checked against the declared type without per-field casts.
	local self = setmetatable({} :: Pooler<T>, FluixClass :: any)

	-- ── Lifecycle Callbacks ───────────────────────────────────────────────────
	self._Factory    = config.Factory
	self._Reset      = config.Reset
	self._OnOverflow = config.OnOverflow

	-- ── Tuning Constants ──────────────────────────────────────────────────────
	self._MIN_POOL_SIZE           = config.MinSize               or 8
	self._MAX_POOL_SIZE           = config.MaxSize               or 256
	self._EMA_ALPHA               = config.Alpha                 or 0.3
	self._HEADROOM                = config.Headroom              or 2.0
	self._SAMPLE_WINDOW           = config.SampleWindow          or 0.5
	self._PREWARM_BATCH_SIZE      = config.PrewarmBatchSize      or 16
	self._SHRINK_GRACE_SECONDS    = config.ShrinkGraceSeconds    or 3.0
	self._IDLE_DISCONNECT_WINDOWS = config.IdleDisconnectWindows or 6

	-- ── Priority Tiers ────────────────────────────────────────────────────────
	self._HOT_MAX = config.HotPoolSize or 0
	self._HotPool = {} :: { T }
	self._HotSize = 0

	-- ── Cold Pool (main) ──────────────────────────────────────────────────────
	self._Pool     = {} :: { T }
	self._PoolSize = 0

	-- ── Per-Object TTL ────────────────────────────────────────────────────────
	-- TTL scan runs at most once per SampleWindow to avoid per-frame O(n) cost.
	self._TTL         = config.TTL
	self._NextTTLScan = os.clock() + (config.TTL or math.huge)

	-- ── Miss Rate Warning ─────────────────────────────────────────────────────
	self._MissRateThreshold = config.MissRateThreshold

	-- ── Cross-Pool Borrowing ──────────────────────────────────────────────────
	self._BorrowPeers = config.BorrowPeers or {} :: { Pooler<any> }

	-- ── Demand Tracking ───────────────────────────────────────────────────────
	self._DemandEMA               = 0.0
	self._WindowAcquisitions      = 0
	self._WindowStart             = os.clock()
	self._TargetSize              = self._MIN_POOL_SIZE
	self._LastDemandSatisfiedTime = os.clock()
	self._IdleWindowCount         = 0

	-- ── Heartbeat Lifecycle ───────────────────────────────────────────────────
	self._HeartbeatConnection = nil :: RBXScriptConnection?
	self._Destroyed           = false
	self._Paused              = false

	-- ── Telemetry ─────────────────────────────────────────────────────────────
	self._MissCount        = 0
	self._MissesThisWindow = 0

	-- ── Tagged Ownership ──────────────────────────────────────────────────────
	self._Live      = {} :: { [any]: number }
	self._LiveCount = 0

	-- ── Signals ───────────────────────────────────────────────────────────────
	-- Explicit Signal<Signature> casts propagate the UDTF-derived Fire/Wait
	-- types to every caller — no need for (obj: any) workarounds at call sites.
	self.Signals = {
		OnAcquire = Signal.new() :: Signal.Signal<(obj: T) -> ()>,
		OnRelease = Signal.new() :: Signal.Signal<(obj: T) -> ()>,
		OnMiss    = Signal.new() :: Signal.Signal<(obj: T) -> ()>,
		OnGrow    = Signal.new() :: Signal.Signal<(added: number, total: number) -> ()>,
		OnShrink  = Signal.new() :: Signal.Signal<(removed: number, total: number) -> ()>,
	}

	return self
end

-- ─── Internal Helpers ────────────────────────────────────────────────────────

--[[
    _BorrowObject

    Pops one object from this pool's cold pool without updating demand tracking,
    ownership, or firing any signals. Used exclusively by cross-pool borrowing.
    Returns nil if the cold pool is empty.
]]
function FluixClass._BorrowObject<T>(self: Pooler<T>): T?
	if self._PoolSize > 0 then
		local obj                  = self._Pool[self._PoolSize]
		self._Pool[self._PoolSize] = nil
		self._PoolSize            -= 1
		return obj
	end
	return nil
end

--[[
    _PushToPool

    Shared insertion path: hot → cold → OnOverflow.
    Used by both Release and TTL reclaim to avoid duplicated routing logic.
]]
function FluixClass._PushToPool(self, obj)
	if self._HOT_MAX > 0 and self._HotSize < self._HOT_MAX then
		self._HotSize += 1
		self._HotPool[self._HotSize] = obj
	elseif self._PoolSize < self._MAX_POOL_SIZE then
		self._Reset(obj)
		self._PoolSize += 1
		self._Pool[self._PoolSize] = obj
	elseif self._OnOverflow then
		self._Reset(obj)
		self._OnOverflow(obj)
	end
end

-- ─── Heartbeat Tick ──────────────────────────────────────────────────────────

function FluixClass._HeartbeatTick<T>(self: Pooler<T>)
	local Now = os.clock()

	-- ── Window Boundary ───────────────────────────────────────────────────────

	if (Now - self._WindowStart) >= self._SAMPLE_WINDOW then

		-- ── Idle Disconnect ───────────────────────────────────────────────────
		-- Only auto-disconnect on idle if not explicitly paused; Pause() manages
		-- its own disconnect path and should not be interfered with here.

		if self._WindowAcquisitions == 0 then
			self._IdleWindowCount += 1
			if self._IdleWindowCount >= self._IDLE_DISCONNECT_WINDOWS then
				if self._HeartbeatConnection then
					self._HeartbeatConnection:Disconnect()
					self._HeartbeatConnection = nil
				end
				self._WindowStart     = os.clock()
				self._IdleWindowCount = 0
				return
			end
		else
			self._IdleWindowCount = 0
		end

		-- ── Miss Rate Warning ─────────────────────────────────────────────────

		if self._MissRateThreshold and self._WindowAcquisitions > 0 then
			local Rate = self._MissesThisWindow / self._WindowAcquisitions
			if Rate > self._MissRateThreshold then
				warn(string.format(
					"%s: miss rate %.0f%% exceeds threshold %.0f%%"
						.. " — pool may be undersized (EMA=%.1f, Target=%d, Live=%d)",
					Identity,
					Rate * 100,
					self._MissRateThreshold * 100,
					self._DemandEMA,
					self._TargetSize,
					self._LiveCount
					))
			end
		end

		-- ── EMA + Target ──────────────────────────────────────────────────────

		self._DemandEMA = self._EMA_ALPHA * self._WindowAcquisitions
			+ (1 - self._EMA_ALPHA) * self._DemandEMA

		self._TargetSize = math.clamp(
			math.ceil(self._DemandEMA * self._HEADROOM),
			self._MIN_POOL_SIZE,
			self._MAX_POOL_SIZE
		)

		self._WindowAcquisitions = 0
		self._MissesThisWindow   = 0
		self._WindowStart        = Now
	end

	-- ── TTL Scan ──────────────────────────────────────────────────────────────
	-- Throttled to once per SampleWindow — avoids O(LiveCount) every frame.

	if self._TTL and Now >= self._NextTTLScan then
		self._NextTTLScan = Now + self._SAMPLE_WINDOW
		for obj, AcquireTime in pairs(self._Live) do
			if (Now - AcquireTime) > (self._TTL :: number) then
				self._Live[obj]  = nil
				self._LiveCount -= 1
				self:_PushToPool(obj :: T)
			end
		end
	end

	-- ── Pre-Warming ───────────────────────────────────────────────────────────

	-- Hot pool: fill to capacity first
	if self._HOT_MAX > 0 and self._HotSize < self._HOT_MAX then
		local Deficit = self._HOT_MAX - self._HotSize
		local Batch   = math.min(math.ceil(Deficit / 2), self._PREWARM_BATCH_SIZE)
		for _ = 1, Batch do
			self._HotSize             += 1
			self._HotPool[self._HotSize] = self._Factory()
		end
		self.Signals.OnGrow:Fire(Batch, self._HotSize + self._PoolSize)
	end

	-- Cold pool: fill toward TargetSize
	local Total = self._HotSize + self._PoolSize
	if Total < self._TargetSize then
		local Deficit = self._TargetSize - Total
		local Batch   = math.min(math.ceil(Deficit / 2), self._PREWARM_BATCH_SIZE)
		local Added   = 0
		for _ = 1, Batch do
			if self._PoolSize >= self._MAX_POOL_SIZE then break end
			self._PoolSize            += 1
			self._Pool[self._PoolSize] = self._Factory()
			Added                     += 1
		end
		if Added > 0 then
			self.Signals.OnGrow:Fire(Added, self._HotSize + self._PoolSize)
		end
	end

	-- ── Demand-Satisfied Timestamp ────────────────────────────────────────────

	if (self._HotSize + self._PoolSize) >= self._TargetSize then
		self._LastDemandSatisfiedTime = Now
	end

	-- ── Gradual Shrink (cold pool only) ──────────────────────────────────────

	local IsExcess       = self._PoolSize > self._TargetSize
	local IsGraceExpired = (Now - self._LastDemandSatisfiedTime) > self._SHRINK_GRACE_SECONDS
	local IsAboveFloor   = self._PoolSize > self._MIN_POOL_SIZE

	if IsExcess and IsGraceExpired and IsAboveFloor then
		self._Pool[self._PoolSize] = nil :: any
		self._PoolSize            -= 1
		self.Signals.OnShrink:Fire(1, self._HotSize + self._PoolSize)
	end
end

function FluixClass._EnsureConnected<T>(self: Pooler<T>)
	-- Respect an explicit Pause() — do not reconnect while paused.
	if self._Paused then return end
	if self._HeartbeatConnection then return end
	self._IdleWindowCount = 0
	self._WindowStart     = os.clock()
	self._HeartbeatConnection = RunService.Heartbeat:Connect(function()
		self:_HeartbeatTick()
	end)
end

-- ─── Public API ──────────────────────────────────────────────────────────────

--[=[
    Seed

    Pre-loads the EMA with a known expected demand and fills hot and cold pools
    synchronously. Call during initialisation when the expected acquisition rate
    is known ahead of time.

    Parameters:
        ExpectedDemand: number
            Expected acquisitions per SampleWindow (0.5 s by default).
]=]
function FluixClass.Seed<T>(self: Pooler<T>, ExpectedDemand: number)
	assert(not self._Destroyed, Identity .. ": cannot call Seed on a destroyed pool")
	ExpectedDemand   = math.max(ExpectedDemand, 0)
	self._DemandEMA  = ExpectedDemand
	self._TargetSize = math.clamp(
		math.ceil(self._DemandEMA * self._HEADROOM),
		self._MIN_POOL_SIZE,
		self._MAX_POOL_SIZE
	)

	-- Fill hot pool first
	if self._HOT_MAX > 0 then
		for _ = 1, (self._HOT_MAX - self._HotSize) do
			self._HotSize             += 1
			self._HotPool[self._HotSize] = self._Factory()
		end
	end

	-- Fill cold pool to target
	local Deficit = self._TargetSize - (self._HotSize + self._PoolSize)
	for _ = 1, Deficit do
		if self._PoolSize >= self._MAX_POOL_SIZE then break end
		self._PoolSize            += 1
		self._Pool[self._PoolSize] = self._Factory()
	end

	self:_EnsureConnected()
end

--[=[
    Acquire

    Pops an object using tier priority:
        1. Hot sub-pool  (fastest, always pre-warmed)
        2. Cold pool
        3. BorrowPeers cold pools (in registration order)
        4. Factory fallback — increments miss counters, fires OnMiss

    Apply (optional) is called with the object before it is tagged or returned,
    making it a convenient place to stamp initial state. OnAcquire fires after Apply.

    Parameters:
        Apply: ((obj: T) -> ())?

    Returns:
        T — ready for use.
]=]
function FluixClass.Acquire<T>(self: Pooler<T>, Apply: ((obj: T) -> ())?): T
	assert(not self._Destroyed, Identity .. ": cannot Acquire from a destroyed pool")
	self:_EnsureConnected()
	self._WindowAcquisitions += 1

	local obj: T

	-- Tier 1: hot pool
	if self._HotSize > 0 then
		obj                          = self._HotPool[self._HotSize]
		self._HotPool[self._HotSize] = nil :: any
		self._HotSize               -= 1

		-- Tier 2: cold pool
	elseif self._PoolSize > 0 then
		obj                        = self._Pool[self._PoolSize]
		self._Pool[self._PoolSize] = nil :: any
		self._PoolSize            -= 1

	else
		-- Tier 3: borrow from peers (cold pools only)
		local Borrowed = false
		for _, Peer in ipairs(self._BorrowPeers) do
			local Candidate = Peer:_BorrowObject()
			if Candidate ~= nil then
				-- The caller chose compatible peer types; cast is intentional.
				obj      = Candidate :: T
				Borrowed = true
				break
			end
		end

		-- Tier 4: factory fallback (miss)
		if not Borrowed then
			obj                     = self._Factory()
			self._MissCount        += 1
			self._MissesThisWindow += 1
			self.Signals.OnMiss:Fire(obj)
		end
	end

	if Apply then Apply(obj) end

	-- Tag ownership with acquisition timestamp
	self._Live[obj]  = os.clock()
	self._LiveCount += 1

	self.Signals.OnAcquire:Fire(obj)
	return obj
end

--[=[
    Release

    Returns a used object to the pool. Guards against double-release and foreign
    objects. Fires OnRelease, calls Reset, then pushes hot → cold → OnOverflow.

    The object must not be accessed after this call.

    Parameters:
        obj: T
]=]
function FluixClass.Release<T>(self: Pooler<T>, obj: T)
	assert(not self._Destroyed, Identity .. ": cannot Release to a destroyed pool")

	-- Double-release / foreign object guard
	if not self._Live[obj] then
		warn(Identity .. ": Release called on an unowned object — ignoring (double-release or wrong pool)")
		return
	end

	self._Live[obj] = nil
	self._LiveCount -= 1
	self.Signals.OnRelease:Fire(obj)
	self:_PushToPool(obj)
end

--[=[
    ReleaseAll

    Force-returns every currently live object to the pool. Useful for wave
    clears, round resets, or any bulk teardown. Snapshots the live set before
    iterating so Release mutations during iteration are safe.
]=]
function FluixClass.ReleaseAll<T>(self: Pooler<T>)
	assert(not self._Destroyed, Identity .. ": cannot ReleaseAll on a destroyed pool")

	local Snapshot: { T } = {}
	for obj in pairs(self._Live) do
		Snapshot[#Snapshot + 1] = obj :: T
	end
	for _, obj in ipairs(Snapshot) do
		self:Release(obj)
	end
end

--[=[
    Destroy

    Tears down the pool: disconnects Heartbeat, destroys all signals, clears
    both pools and the live set, and marks the instance as destroyed. Any
    subsequent public API call will error.

    Note: Reset is NOT called on pooled objects. If pooled objects hold external
    resources, iterate and clean them before calling Destroy, or use a custom
    Reset that handles full teardown.
]=]
function FluixClass.Destroy<T>(self: Pooler<T>)
	if self._Destroyed then return end
	self._Destroyed = true

	if self._HeartbeatConnection then
		self._HeartbeatConnection:Disconnect()
		self._HeartbeatConnection = nil
	end

	-- Remove this pool from any peers' borrow lists to prevent dangling refs.
	-- Peers that registered us as a peer will silently skip us on their next
	-- Acquire since _BorrowObject returns nil on an empty-but-alive pool, but
	-- cleaning up explicitly is the right thing to do.
	for _, Peer in ipairs(self._BorrowPeers) do
		Peer:UnregisterPeer(self :: Pooler<any>)
	end

	self.Signals.OnAcquire:Destroy()
	self.Signals.OnRelease:Destroy()
	self.Signals.OnMiss:Destroy()
	self.Signals.OnGrow:Destroy()
	self.Signals.OnShrink:Destroy()

	for i = 1, self._HotSize  do self._HotPool[i] = nil :: any end
	for i = 1, self._PoolSize do self._Pool[i]    = nil :: any end

	self._HotSize  = 0
	self._PoolSize = 0
	self._Live      = {}
	self._LiveCount = 0

	self._DemandEMA               = 0.0
	self._WindowAcquisitions      = 0
	self._WindowStart             = os.clock()
	self._TargetSize              = self._MIN_POOL_SIZE
	self._LastDemandSatisfiedTime = os.clock()
	self._IdleWindowCount         = 0
	self._MissCount               = 0
	self._MissesThisWindow        = 0
end

--[=[
    GetStats

    Returns a snapshot of this pool's state as a new table. Intended for
    debugging, logging, and tooling — not for hot-path use since it allocates.
    For per-frame inspection, prefer the individual zero-allocation getters.

    Fields:
        HotSize           — objects in the hot sub-pool
        PoolSize          — objects in the cold pool
        TargetSize        — EMA-derived cold pre-warm target
        DemandEMA         — smoothed acquisitions-per-window
        MissCount         — lifetime total pool misses
        MissesThisWindow  — misses since last window reset
        LiveCount         — objects currently out in the wild
        IsActive          — true if Heartbeat connection is live
]=]
function FluixClass.GetStats<T>(self: Pooler<T>): PoolerStats
	return {
		HotSize          = self._HotSize,
		PoolSize         = self._PoolSize,
		TargetSize       = self._TargetSize,
		DemandEMA        = self._DemandEMA,
		MissCount        = self._MissCount,
		MissesThisWindow = self._MissesThisWindow,
		LiveCount        = self._LiveCount,
		IsActive         = self._HeartbeatConnection ~= nil,
	}
end

-- ─── Peer Management ─────────────────────────────────────────────────────────

--[=[
    RegisterPeer

    Dynamically adds a sibling pool to the borrow list. On a miss, Fluix will
    attempt to borrow from this peer's cold pool before falling back to Factory.

    Guards against duplicate registration. The relationship is one-directional —
    call RegisterPeer on both pools for mutual borrowing.

    Parameters:
        peer: Pooler<any>   — must produce objects compatible with this pool's Reset
]=]
function FluixClass.RegisterPeer<T>(self: Pooler<T>, peer: Pooler<any>)
	assert(not self._Destroyed,    Identity .. ": cannot RegisterPeer on a destroyed pool")
	assert(peer ~= (self :: any), Identity .. ": a pool cannot be its own peer")

	-- Guard against duplicates — borrowing the same peer twice per miss is wasteful
	for _, existing in ipairs(self._BorrowPeers) do
		if existing == peer then
			warn(Identity .. ": peer already registered — ignoring")
			return
		end
	end

	table.insert(self._BorrowPeers, peer)
end

--[=[
    UnregisterPeer

    Removes a previously registered peer from the borrow list. Should be called
    before a peer pool is destroyed to prevent dangling references.

    Parameters:
        peer: Pooler<any>
]=]
function FluixClass.UnregisterPeer<T>(self: Pooler<T>, peer: Pooler<any>)
	assert(not self._Destroyed, Identity .. ": cannot UnregisterPeer on a destroyed pool")

	for i, existing in ipairs(self._BorrowPeers) do
		if existing == peer then
			-- Swap-remove: O(1), order among peers doesn't matter
			local Last = #self._BorrowPeers
			self._BorrowPeers[i]    = self._BorrowPeers[Last]
			self._BorrowPeers[Last] = nil :: any
			return
		end
	end

	warn(Identity .. ": UnregisterPeer called with a peer that was not registered — ignoring")
end

-- ─── Lifecycle Control ───────────────────────────────────────────────────────

--[=[
    Pause

    Immediately disconnects the Heartbeat connection without destroying any pool
    state. Pre-warmed objects remain in both tiers; the EMA and live ownership
    table are untouched. Subsequent Acquire calls will still work — Pause only
    suppresses background pre-warming, shrinking, and TTL scans.

    Useful during loading screens, cutscenes, or any period where you know no
    acquisitions will occur and you want zero per-frame overhead.

    Call Resume() to reconnect.
]=]
function FluixClass.Pause<T>(self: Pooler<T>)
	assert(not self._Destroyed, Identity .. ": cannot Pause a destroyed pool")
	self._Paused = true
	if self._HeartbeatConnection then
		self._HeartbeatConnection:Disconnect()
		self._HeartbeatConnection = nil
	end
end

--[=[
    Resume

    Reconnects the Heartbeat after a Pause(). Safe to call if the pool is
    already active — it is a no-op in that case.
]=]
function FluixClass.Resume<T>(self: Pooler<T>)
	assert(not self._Destroyed, Identity .. ": cannot Resume a destroyed pool")
	self._Paused = false
	self:_EnsureConnected()
end

--[=[
    Drain

    Evicts every object from both the hot and cold pools, routing each one
    through OnOverflow (if set) or silently discarding it. Does NOT touch live
    objects or reset the EMA — demand tracking continues uninterrupted.

    Use this under memory pressure when you want to release pooled objects back
    to the GC. Call Seed() or let the EMA-driven pre-warm refill the pool when
    memory pressure eases.
]=]
function FluixClass.Drain<T>(self: Pooler<T>)
	assert(not self._Destroyed, Identity .. ": cannot Drain a destroyed pool")

	-- Drain hot pool
	for i = self._HotSize, 1, -1 do
		local obj        = self._HotPool[i]
		self._HotPool[i] = nil :: any
		if self._OnOverflow then
			self._OnOverflow(obj)
		end
	end
	self._HotSize = 0

	-- Drain cold pool
	for i = self._PoolSize, 1, -1 do
		local obj      = self._Pool[i]
		self._Pool[i]  = nil :: any
		if self._OnOverflow then
			self._OnOverflow(obj)
		end
	end
	self._PoolSize = 0
end

--[=[
    Prewarm

    Synchronously allocates exactly N objects and pushes them into the pool
    without touching the EMA or TargetSize. Useful when you need a specific
    number of objects ready right now for a predictable burst — e.g. spawning
    20 enemies simultaneously — without corrupting the EMA's historical picture
    of steady-state demand.

    Distinct from Seed(), which both sets the EMA and fills to an EMA-derived
    target. Use Prewarm when you know the size you need but not the demand rate.

    Parameters:
        n: number   — number of objects to allocate and pool
]=]
function FluixClass.Prewarm<T>(self: Pooler<T>, n: number)
	assert(not self._Destroyed, Identity .. ": cannot Prewarm a destroyed pool")
	n = math.max(math.floor(n), 0)

	for _ = 1, n do
		-- Respect MaxSize ceiling — silently stop if we'd exceed it
		if (self._HotSize + self._PoolSize) >= self._MAX_POOL_SIZE then break end
		self:_PushToPool(self._Factory())
	end

	self:_EnsureConnected()
end

--[=[
    Resize

    Updates the MinSize and MaxSize bounds live, then immediately clamps
    TargetSize into the new range. The Heartbeat tick will handle the actual
    fill or gradual eviction on subsequent frames — no synchronous allocation
    or eviction happens here.

    Parameters:
        newMin: number   — new MinSize floor  (must be >= 0)
        newMax: number   — new MaxSize ceiling (must be >= newMin)
]=]
function FluixClass.Resize<T>(self: Pooler<T>, newMin: number, newMax: number)
	assert(not self._Destroyed, Identity .. ": cannot Resize a destroyed pool")
	assert(newMin >= 0,        Identity .. ": newMin must be >= 0")
	assert(newMax >= newMin,   Identity .. ": newMax must be >= newMin")

	self._MIN_POOL_SIZE = math.floor(newMin)
	self._MAX_POOL_SIZE = math.floor(newMax)

	-- Clamp the current target into the new bounds immediately so the
	-- Heartbeat tick begins converging toward the correct size next frame.
	self._TargetSize = math.clamp(self._TargetSize, self._MIN_POOL_SIZE, self._MAX_POOL_SIZE)

	self:_EnsureConnected()
end

-- ─── Ownership Query ─────────────────────────────────────────────────────────

--[=[
    IsOwned

    Returns true if the given object is currently live in this pool — i.e. it
    has been acquired and not yet released. Useful as a debug assertion to verify
    an object belongs to this pool before releasing it.

    Parameters:
        obj: T

    Returns:
        boolean
]=]
function FluixClass.IsOwned<T>(self: Pooler<T>, obj: T): boolean
	return self._Live[obj] ~= nil
end

-- ─── Zero-Allocation Getters ─────────────────────────────────────────────────
-- These read directly from instance state with no table allocation, making
-- them safe to call every frame inside hot code paths like firing loops or
-- frame-by-frame monitors. Prefer these over GetStats() at runtime.

--[=[
    GetLiveCount — objects currently acquired and not yet released.
]=]
function FluixClass.GetLiveCount<T>(self: Pooler<T>): number
	return self._LiveCount
end

--[=[
    GetPoolSize — objects sitting idle in the cold pool right now.
]=]
function FluixClass.GetPoolSize<T>(self: Pooler<T>): number
	return self._PoolSize
end

--[=[
    GetHotSize — objects sitting idle in the hot sub-pool right now.
]=]
function FluixClass.GetHotSize<T>(self: Pooler<T>): number
	return self._HotSize
end

--[=[
    GetTotalAvailable — hot + cold combined; the number of objects that can be
    acquired right now without a miss or a Factory call.
]=]
function FluixClass.GetTotalAvailable<T>(self: Pooler<T>): number
	return self._HotSize + self._PoolSize
end

--[=[
    GetDemandEMA — current smoothed acquisitions-per-window estimate.
]=]
function FluixClass.GetDemandEMA<T>(self: Pooler<T>): number
	return self._DemandEMA
end

--[=[
    GetTargetSize — the EMA-derived size the cold pool is currently pre-warming
    toward. Equal to clamp(ceil(DemandEMA * Headroom), MinSize, MaxSize).
]=]
function FluixClass.GetTargetSize<T>(self: Pooler<T>): number
	return self._TargetSize
end

--[=[
    GetMissCount — lifetime total number of times Acquire fell through to Factory.
]=]
function FluixClass.GetMissCount<T>(self: Pooler<T>): number
	return self._MissCount
end

--[=[
    IsActive — true if the Heartbeat connection is currently live. False if the
    pool is idle-dormant or has been explicitly Paused().
]=]
function FluixClass.IsActive<T>(self: Pooler<T>): boolean
	return self._HeartbeatConnection ~= nil
end

--[=[
    IsDestroyed — true if Destroy() has been called. All public methods other
    than IsDestroyed() itself will error on a destroyed pool.
]=]
function FluixClass.IsDestroyed<T>(self: Pooler<T>): boolean
	return self._Destroyed
end

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze({
	new = FluixClass.new,
})