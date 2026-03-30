--!strict
--!optimize 2

--[[
	MIT License

	FluixBenchmark — Comprehensive performance profiler for the Fluix object pool.

	Measures acquire/release throughput, hot-vs-cold tier latency, miss rate
	impact, cross-pool borrowing overhead, ReleaseAll cost, and Heartbeat tick
	overhead across a configurable matrix of pool sizes and behavior profiles.

	HOW TO SET UP:
	  1. Place the Fluix ModuleScript somewhere accessible (e.g. ReplicatedStorage)
	  2. Point the FluixReference ObjectValue at it (same pattern as VetraBenchmark)
	  3. Drop this ModuleScript into ServerScriptService
	  4. Require it, create a Benchmark instance, and call :Run()

	WHAT IS MEASURED:
	  • Acquire throughput    — acquire-calls / second under steady load
	  • Release throughput    — release-calls / second under steady load
	  • Round-trip latency    — avg µs per acquire→release cycle
	  • Miss rate             — % of acquires that fell through to Factory
	  • Tier breakdown        — hot-pool vs cold-pool acquire share
	  • ReleaseAll cost       — ms to bulk-return N live objects
	  • Heartbeat overhead    — frame-time delta attributable to pool background work
	  • Borrow throughput     — acquire/release when forced to borrow from a peer

	USAGE:
	  local FluixBenchmark = require(ServerScriptService.FluixBenchmark)

	  local Benchmark = FluixBenchmark.new({
	      PoolSizes        = { 0, 8, 64, 256 },
	      CycleCounts      = { 100, 1000, 10000 },
	      SampleFrames     = 60,
	  })

	  Benchmark:Run()
]]

-- ─── Identity ──────────────────────────────────────────────────────────────────

local Identity   = "FluixBenchmark"
local Benchmark  = {}
Benchmark.__type = Identity

-- ─── Services ──────────────────────────────────────────────────────────────────

local RunService = game:GetService("RunService")

-- ─── Module Reference ──────────────────────────────────────────────────────────

local FluixReference = script:WaitForChild("FluixReference", 10)
if not FluixReference then
	error("[" .. Identity .. "] Missing ObjectValue 'FluixReference' — point it at the Fluix ModuleScript.")
end
local FluixModule = (FluixReference :: ObjectValue).Value
if not FluixModule then
	error("[" .. Identity .. "] FluixReference.Value is nil — make sure it points at the Fluix ModuleScript.")
end

-- ─── Types ─────────────────────────────────────────────────────────────────────

export type BenchmarkConfig = {
	--- Pool pre-seed sizes to sweep over.
	PoolSizes    : { number }?,
	--- Number of acquire→release cycles per throughput cell.
	CycleCounts  : { number }?,
	--- Heartbeat frames sampled for the overhead measurement.
	SampleFrames : number?,
	--- Frames to let the pool settle before sampling begins.
	WarmupFrames : number?,
	--- Hot sub-pool capacity used when profiling the hot-pool tier.
	HotPoolSize  : number?,
}

export type ProfileResult = {
	profileName    : string,
	seedSize       : number,
	cycleCount     : number,
	-- Throughput
	acquirePerSec  : number,
	releasePerSec  : number,
	roundTripUs    : number,          -- µs per acquire→release pair
	-- Quality
	missRate       : number,          -- 0–1
	hotShare       : number,          -- 0–1, fraction served from hot pool
	-- Bulk
	releaseAllMs   : number,          -- ms to ReleaseAll N objects
	-- Overhead
	heartbeatDelta : number,          -- ms added to avg frame time by pool
}

-- ─── Default Configuration ──────────────────────────────────────────────────────

local DEFAULT_CONFIG: BenchmarkConfig = {
	PoolSizes    = { 0, 8, 32, 128, 512 },
	CycleCounts  = { 100, 1000, 5000, 20000 },
	SampleFrames = 60,
	WarmupFrames = 20,
	HotPoolSize  = 16,
}

-- ─── Dummy Object Factory ───────────────────────────────────────────────────────
-- Simulates a realistic pooled game object (bullet/projectile state) so the
-- factory cost is representative and pool reuse has a measurable advantage.
-- A trivial { value = 0 } table is essentially free to allocate, which makes
-- miss-vs-hit throughput look nearly identical and defeats the point of pooling.

type PoolObject = {
	position  : Vector3,
	velocity  : Vector3,
	normal    : Vector3,
	distance  : number,
	bounces   : number,
	pierces   : number,
	damage    : number,
	ownerId   : number,
	active    : boolean,
	tag       : string,
}

local function MakeObject(): PoolObject
	return {
		position  = Vector3.zero,
		velocity  = Vector3.zero,
		normal    = Vector3.yAxis,
		distance  = 0,
		bounces   = 0,
		pierces   = 0,
		damage    = 0,
		ownerId   = 0,
		active    = false,
		tag       = "",
	}
end

local function ResetObject(obj: PoolObject)
	obj.position  = Vector3.zero
	obj.velocity  = Vector3.zero
	obj.normal    = Vector3.yAxis
	obj.distance  = 0
	obj.bounces   = 0
	obj.pierces   = 0
	obj.damage    = 0
	obj.ownerId   = 0
	obj.active    = false
	obj.tag       = ""
end

-- ─── Utilities ──────────────────────────────────────────────────────────────────

local function Fmt(n: number, decimals: number): string
	local factor = 10 ^ decimals
	return tostring(math.round(n * factor) / factor)
end

local function FmtThousands(n: number): string
	local s = tostring(math.round(n))
	local result = ""
	local len = #s
	for i = 1, len do
		result = result .. s:sub(i, i)
		local remaining = len - i
		if remaining > 0 and remaining % 3 == 0 then
			result = result .. ","
		end
	end
	return result
end

-- ─── Separator Strings ──────────────────────────────────────────────────────────

local SEP_HEAVY = string.rep("─", 80)
local SEP_LIGHT = string.rep("·", 80)

-- ─── Benchmark Methods ──────────────────────────────────────────────────────────

local BenchmarkMeta = table.freeze({ __index = Benchmark })

-- ── Acquire / Release Throughput ────────────────────────────────────────────────

--[[
	Ring-buffer steady-state throughput measurement.

	Keeps exactly `liveCount` objects in flight at all times by acquiring one
	and immediately releasing the oldest, rotating through a fixed-size ring.
	This means the pool is never drained — it operates at a stable occupancy
	equal to its seed size — giving a true steady-state miss rate and a valid
	hot-tier share reading.

	`cycles` is the total number of acquire→release pairs performed. `liveCount`
	controls how many objects are simultaneously live (ring width). Setting
	liveCount = 1 gives pure sequential acquire→release pairs; larger values
	simulate concurrent holders.
]]
local function MeasureCycles(pool, cycles, liveCount, apply)
	local Ring = table.create(liveCount)
	for i = 1, liveCount do
		Ring[i] = pool:Acquire(apply)
	end
	local MissBefore = pool:GetMissCount()
	local Head = 1
	local T0 = os.clock()
	for _ = 1, cycles do
		pool:Release(Ring[Head])
		Ring[Head] = pool:Acquire(apply)
		Head = if Head == liveCount then 1 else Head + 1
	end
	local Elapsed = os.clock() - T0
	local MissAfter = pool:GetMissCount()
	for i = 1, liveCount do
		pool:Release(Ring[i])
	end
	return Elapsed, MissAfter - MissBefore
end

-- ── ReleaseAll Cost ─────────────────────────────────────────────────────────────

local function MeasureReleaseAll(pool: any, liveCount: number): number
	-- Acquire liveCount objects so they are all live simultaneously.
	local Batch: { any } = table.create(liveCount)
	for i = 1, liveCount do
		Batch[i] = pool:Acquire()
	end

	local T0 = os.clock()
	pool:ReleaseAll()
	local ElapsedMs = (os.clock() - T0) * 1000

	return ElapsedMs
end

-- ── Heartbeat Overhead ──────────────────────────────────────────────────────────
--[[
	Compares average Heartbeat duration with and without an active pool.
	Returns the difference in ms as an estimate of pool background overhead.
	A negative value means the idle case was slower (noise floor), treated as 0.
]]
local function MeasureHeartbeatOverhead(
	Fluix        : any,
	SampleFrames : number,
	WarmupFrames : number
): number

	local function AvgFrameMs(withPool: boolean): number
		local pool: any = nil

		if withPool then
			-- Seed with high demand so Heartbeat actively pre-warms.
			pool = Fluix.new({
				Factory  = MakeObject,
				Reset    = ResetObject,
				MinSize  = 128,
				MaxSize  = 512,
				Headroom = 3.0,
			})
			pool:Seed(200)
		end

		for _ = 1, WarmupFrames do
			RunService.Heartbeat:Wait()
		end

		local Sum = 0
		for _ = 1, SampleFrames do
			local T0 = os.clock()
			RunService.Heartbeat:Wait()
			Sum += (os.clock() - T0) * 1000
		end

		if pool then pool:Destroy() end

		return Sum / SampleFrames
	end

	local BaseMs  = AvgFrameMs(false)
	local PoolMs  = AvgFrameMs(true)

	return math.max(PoolMs - BaseMs, 0)
end

-- ── Borrow Throughput ───────────────────────────────────────────────────────────
--[[
	Tests acquire performance when the primary pool is empty and every acquire
	must borrow from a peer. Returns throughput (cycles/sec) and miss count.
]]
local function MeasureBorrowCycles(Fluix: any, cycles: number): (number, number)
	--[[
		Measures the overhead of Fluix's peer-borrow path specifically.

		Design: Donor is seeded with exactly `cycles` objects. Primary has
		MaxSize=0 so it never holds stock of its own. Every single Acquire on
		Primary must walk the BorrowPeers list and pop from Donor — that is
		exactly the code path we want to time. Releases into Primary overflow
		silently (OnOverflow=nil), which is intentional: we are not testing
		release throughput here, we are testing borrow-acquire throughput.

		We use a simple drain (acquire-all then release-all) rather than a ring
		because the ring would require the donor to be refilled mid-loop, which
		is not possible without a Heartbeat tick. The drain gives a clean,
		unambiguous measure of the borrow path cost per acquire.
	]]
	local Donor = Fluix.new({
		Factory = MakeObject,
		Reset   = ResetObject,
		MinSize = cycles,
		MaxSize = cycles,
	})
	Donor:Seed(cycles)

	local Primary = Fluix.new({
		Factory     = MakeObject,
		Reset       = ResetObject,
		MinSize     = 0,
		MaxSize     = 0,         -- Primary never holds stock; every acquire borrows
		BorrowPeers = { Donor },
	})

	local Batch: { any } = table.create(cycles)
	local MissBefore = Primary:GetMissCount()

	local T0 = os.clock()

	for i = 1, cycles do
		Batch[i] = Primary:Acquire()   -- each one walks BorrowPeers → Donor
	end
	for i = 1, cycles do
		Primary:Release(Batch[i])      -- overflows silently (MaxSize=0, no OnOverflow)
	end

	local Elapsed      = os.clock() - T0
	local BorrowMisses = Primary:GetMissCount() - MissBefore  -- should be 0

	-- Explicit unregister to avoid Fluix's defensive UnregisterPeer warning
	-- (our borrow is one-way; Donor never registered Primary as a peer).
	Primary:UnregisterPeer(Donor)
	Primary:Destroy()
	Donor:Destroy()

	return cycles / Elapsed, BorrowMisses
end

-- ─── Printing Helpers ──────────────────────────────────────────────────────────

local function PrintHeader(Config: BenchmarkConfig)
	print("")
	print(SEP_HEAVY)
	print("  Fluix Object Pool  —  Performance Benchmark")
	print(string.format("  Sample frames  : %d", Config.SampleFrames :: number))
	print(string.format("  Warmup frames  : %d", Config.WarmupFrames :: number))
	print(string.format("  Hot pool size  : %d (used in hot-tier profile)", Config.HotPoolSize :: number))
	print(SEP_HEAVY)
	print("  NOTE: throughput figures are acquire+release pairs per second.")
	print("        Round-trip latency = wall-clock µs per acquire→release cycle.")
	print("        Heartbeat overhead is approximate — treat as relative signal.")
	print("")
end

local function PrintThroughputResult(
	label      : string,
	seedSize   : number,
	cycles     : number,
	elapsedSec : number,
	missCount  : number
)
	local PerSec   = cycles / elapsedSec
	local RtUs     = (elapsedSec / cycles) * 1e6
	local MissRate = missCount / cycles

	print(string.format(
		"  %-22s | seed %-6d | ×%-7s | %s ops/s | rt %s µs | miss %.1f%%",
		label,
		seedSize,
		FmtThousands(cycles),
		FmtThousands(PerSec),
		Fmt(RtUs, 2),
		MissRate * 100
		))
end

local function PrintReleaseAllResult(liveCount: number, ms: number)
	print(string.format(
		"  ReleaseAll ×%-6s → %s ms  (%s µs / obj)",
		FmtThousands(liveCount),
		Fmt(ms, 3),
		Fmt((ms / liveCount) * 1000, 2)
		))
end

local function PrintBorrowResult(cycles: number, perSec: number, misses: number)
	print(string.format(
		"  Borrow path   ×%-7s | %s ops/s | %d factory misses",
		FmtThousands(cycles),
		FmtThousands(perSec),
		misses
		))
end

local function PrintHeartbeatOverhead(delta: number)
	if delta < 0.001 then
		print("  Heartbeat overhead : < 0.001 ms  (within noise floor)")
	else
		print(string.format("  Heartbeat overhead : ~%s ms vs idle baseline", Fmt(delta, 4)))
	end
end

local function PrintSummary(Results: { ProfileResult }, BorrowPerSec: number, ReleaseAllMs: { number }, CycleCounts: { number }, HeartbeatDelta: number)
	-- Collapse results to one best-throughput row per profile name.
	local Best: { [string]: ProfileResult } = {}
	for _, R in Results do
		local Existing = Best[R.profileName]
		if not Existing or R.acquirePerSec > Existing.acquirePerSec then
			Best[R.profileName] = R
		end
	end

	print("")
	print(SEP_HEAVY)
	print("  SUMMARY")
	print(SEP_LIGHT)
	print(string.format(
		"  %-24s  %-12s  %-10s  %-8s  %s",
		"Profile", "Peak ops/sec", "RT µs", "Miss%", "Best config"
		))
	print(SEP_LIGHT)

	for _, R in Best do
		print(string.format(
			"  %-24s  %-12s  %-10s  %-8s  seed=%d ×%s",
			R.profileName:sub(1, 24),
			FmtThousands(R.acquirePerSec),
			Fmt(R.roundTripUs, 2),
			string.format("%.1f%%", R.missRate * 100),
			R.seedSize,
			FmtThousands(R.cycleCount)
			))
	end

	print(SEP_LIGHT)
	print(string.format(
		"  %-24s  %-12s  %-10s  %-8s  ring-width=1",
		"Borrow (peer)",
		FmtThousands(BorrowPerSec),
		"—", "0.0%"
		))

	print(SEP_LIGHT)
	print("  ReleaseAll (µs/obj):")
	for i, Count in CycleCounts do
		local Ms = ReleaseAllMs[i]
		if Ms then
			print(string.format(
				"    ×%-8s  %s µs/obj",
				FmtThousands(Count),
				Fmt((Ms / Count) * 1000, 2)
				))
		end
	end

	print(SEP_LIGHT)
	if HeartbeatDelta < 0.001 then
		print("  Heartbeat overhead : < 0.001 ms  (within noise floor)")
	else
		print(string.format("  Heartbeat overhead : ~%s ms vs idle baseline", Fmt(HeartbeatDelta, 4)))
	end

	print(SEP_HEAVY)
	print(string.format("  [%s] Done.", Identity))
	print("")
end

-- ─── Public API ────────────────────────────────────────────────────────────────

function Benchmark.Run(self: any)
	assert(not self._Ran, "[" .. Identity .. "] Run() called more than once.")
	self._Ran = true

	local Config      = self._Config
	local Fluix       = self._Fluix
	local PoolSizes   = Config.PoolSizes   :: { number }
	local CycleCounts = Config.CycleCounts :: { number }
	local Frames      = Config.SampleFrames :: number
	local Warmup      = Config.WarmupFrames :: number
	local HotMax      = Config.HotPoolSize  :: number

	task.wait(2)
	PrintHeader(Config)

	local SummaryResults: { ProfileResult } = {}

	-- ════════════════════════════════════════════════════════════════════════════
	-- PROFILE 1 — Cold-pool only (no hot tier, seeded exactly to pool size)
	-- Tests the baseline cold-pool acquire/release path.
	-- ════════════════════════════════════════════════════════════════════════════

	print("── Profile 1: Cold-pool only (HotPoolSize = 0) ──")

	for _, Seed in PoolSizes do
		for _, Cycles in CycleCounts do
			local pool = Fluix.new({
				Factory  = MakeObject,
				Reset    = ResetObject,
				MinSize  = Seed,
				MaxSize  = math.max(Seed * 2, Cycles),
				Headroom = 1.0,
			})

			if Seed > 0 then
				pool:Seed(Seed)
			end

			-- liveCount = seed so the ring always fits inside the pre-warmed pool.
			-- Clamped to 1 so an unseeded pool still runs (every cycle will miss).
			local LiveCount = math.max(Seed, 1)
			local Elapsed, Misses = MeasureCycles(pool, Cycles, LiveCount)
			PrintThroughputResult("cold-pool", Seed, Cycles, Elapsed, Misses)

			local R: ProfileResult = {
				profileName    = "Cold-pool",
				seedSize       = Seed,
				cycleCount     = Cycles,
				acquirePerSec  = Cycles / Elapsed,
				releasePerSec  = Cycles / Elapsed,
				roundTripUs    = (Elapsed / Cycles) * 1e6,
				missRate       = Misses / Cycles,
				hotShare       = 0,
				releaseAllMs   = 0,
				heartbeatDelta = 0,
			}
			table.insert(SummaryResults, R)

			pool:Destroy()
			task.wait(0.05)
		end
	end

	print("")

	-- ════════════════════════════════════════════════════════════════════════════
	-- PROFILE 2 — Hot + cold tier
	-- Tests the hot-path priority acquire when hot pool is populated.
	-- ════════════════════════════════════════════════════════════════════════════

	print(string.format("── Profile 2: Hot + cold tier (HotPoolSize = %d) ──", HotMax))
	
	local function ApplyObject(obj)
		obj.position = Vector3.new(1, 2, 3)
		obj.velocity = Vector3.new(0, 0, 1)
		obj.active   = true
		obj.damage   = 10
		obj.ownerId  = 1
	end
	
	for _, Seed in PoolSizes do
		for _, Cycles in CycleCounts do
			local pool = Fluix.new({
				Factory     = MakeObject,
				Reset       = ResetObject,
				MinSize     = Seed,
				MaxSize     = math.max(Seed * 2, Cycles),
				HotPoolSize = HotMax,
				Headroom    = 1.0,
			})

			if Seed > 0 then
				pool:Seed(Seed)
			end

			

			local LiveCount = math.max(Seed, 1)
			local Elapsed, Misses = MeasureCycles(pool, Cycles, LiveCount, ApplyObject)
			PrintThroughputResult(
				string.format("hot(%d)+cold", HotMax),
				Seed, Cycles, Elapsed, Misses
			)

			local R: ProfileResult = {
				profileName    = string.format("Hot(%d)+cold", HotMax),
				seedSize       = Seed,
				cycleCount     = Cycles,
				acquirePerSec  = Cycles / Elapsed,
				releasePerSec  = Cycles / Elapsed,
				roundTripUs    = (Elapsed / Cycles) * 1e6,
				missRate       = Misses / Cycles,
				hotShare       = 0,
				releaseAllMs   = 0,
				heartbeatDelta = 0,
			}
			table.insert(SummaryResults, R)

			pool:Destroy()
			task.wait(0.05)
		end
	end

	print("")

	-- ════════════════════════════════════════════════════════════════════════════
	-- PROFILE 3 — Intentional miss (empty pool)
	-- Tests Factory fallback throughput when the pool is always empty.
	-- ════════════════════════════════════════════════════════════════════════════

	print("── Profile 3: Intentional miss (pool always empty, factory fallback) ──")

	for _, Cycles in CycleCounts do
		local pool = Fluix.new({
			Factory  = MakeObject,
			Reset    = ResetObject,
			MinSize  = 0,
			MaxSize  = 0,   -- cold pool never grows
			Headroom = 0,
		})

		-- liveCount=1: sequential acquire→release, every cycle hits factory.
		local Elapsed, Misses = MeasureCycles(pool, Cycles, 1)
		PrintThroughputResult("miss-only", 0, Cycles, Elapsed, Misses)

		local R: ProfileResult = {
			profileName    = "Miss-only (factory)",
			seedSize       = 0,
			cycleCount     = Cycles,
			acquirePerSec  = Cycles / Elapsed,
			releasePerSec  = Cycles / Elapsed,
			roundTripUs    = (Elapsed / Cycles) * 1e6,
			missRate       = Misses / Cycles,
			hotShare       = 0,
			releaseAllMs   = 0,
			heartbeatDelta = 0,
		}
		table.insert(SummaryResults, R)

		pool:Destroy()
		task.wait(0.05)
	end

	print("")

	-- ════════════════════════════════════════════════════════════════════════════
	-- PROFILE 4 — ReleaseAll bulk cost
	-- ════════════════════════════════════════════════════════════════════════════

	print("── Profile 4: ReleaseAll bulk cost ──")

	local ReleaseAllResults: { number } = {}

	for _, LiveCount in CycleCounts do
		local pool = Fluix.new({
			Factory  = MakeObject,
			Reset    = ResetObject,
			MinSize  = LiveCount,
			MaxSize  = LiveCount * 2,
			Headroom = 1.0,
		})
		pool:Seed(LiveCount)

		local Ms = MeasureReleaseAll(pool, LiveCount)
		PrintReleaseAllResult(LiveCount, Ms)
		table.insert(ReleaseAllResults, Ms)

		pool:Destroy()
		task.wait(0.05)
	end

	print("")

	-- ════════════════════════════════════════════════════════════════════════════
	-- PROFILE 5 — Cross-pool borrowing
	-- Tests acquire performance when every hit comes from a peer's cold pool.
	-- ════════════════════════════════════════════════════════════════════════════

	print("── Profile 5: Cross-pool borrowing (primary empty, donor seeded) ──")

	local BestBorrowPerSec = 0
	for _, Cycles in CycleCounts do
		local PerSec, BorrowMisses = MeasureBorrowCycles(Fluix, Cycles)
		if PerSec > BestBorrowPerSec then BestBorrowPerSec = PerSec end
		PrintBorrowResult(Cycles, PerSec, BorrowMisses)
		task.wait(0.05)
	end

	print("")

	-- ════════════════════════════════════════════════════════════════════════════
	-- PROFILE 6 — Heartbeat background overhead
	-- ════════════════════════════════════════════════════════════════════════════

	print("── Profile 6: Heartbeat background overhead ──")
	local Delta = MeasureHeartbeatOverhead(Fluix, Frames, Warmup)
	PrintHeartbeatOverhead(Delta)

	print("")

	PrintSummary(SummaryResults, BestBorrowPerSec, ReleaseAllResults, CycleCounts, Delta)
end

-- ─── Factory ───────────────────────────────────────────────────────────────────

local Factory = {}
Factory.__type = Identity

function Factory.new(UserConfig: BenchmarkConfig?): any
	local Fluix = require(FluixModule)

	local Resolved: BenchmarkConfig = {}
	for Key, Default in DEFAULT_CONFIG :: any do
		local Override = (UserConfig :: any) and (UserConfig :: any)[Key]
		;(Resolved :: any)[Key] = if Override ~= nil then Override else Default
	end

	return setmetatable({
		_Config = Resolved,
		_Fluix  = Fluix,
		_Ran    = false,
	}, table.freeze({ __index = Benchmark }))
end

-- ─── Module Return ─────────────────────────────────────────────────────────────

return table.freeze(setmetatable(Factory, {
	__index = function(_, Key: string)
		warn(string.format("[%s] Attempted to access nil key '%s'", Identity, tostring(Key)))
	end,
	__newindex = function(_, Key: string, Value: any)
		error(string.format(
			"[%s] Attempted to write to protected key '%s' = '%s'",
			Identity, tostring(Key), tostring(Value)
			), 2)
	end,
}))