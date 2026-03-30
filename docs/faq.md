---
sidebar_position: 4
---

# FAQ

Answers to the questions that come up most often.

---

## General

**What is Fluix?**

Fluix is a per-instance generic object pool for Roblox Luau. It tracks acquisition demand with an exponential moving average and automatically pre-warms and shrinks the pool to match real usage. It supports hot/cold priority tiers, cross-pool borrowing, per-object TTL, and lifecycle signals.

---

**Is Fluix free?**

Yes. Fluix is released under the MIT License.

---

**Does Fluix allocate on the hot path?**

No. `Acquire` and `Release` are zero-allocation when the pool is not empty or full. Allocations only occur in the Heartbeat pre-warm tick or on a factory miss.

---

**Can I use Fluix on the server and the client?**

Yes. Fluix uses `RunService.Heartbeat` for its internal tick, which fires on both server and client. Require it wherever you need a pool.

---

## Configuration

**What should I set `MinSize` to?**

Set it to the minimum number of objects you expect to be in use simultaneously at any point in time. A value that is too low means the pool will miss frequently on burst demand; too high wastes memory.

---

**What does `Headroom` do?**

`Headroom` scales the EMA demand estimate to give the pool a buffer above observed demand. `Headroom = 2.0` means the pool targets twice the smoothed acquisition rate. Increase it if you see frequent misses; decrease it to reduce idle memory.

---

**When should I enable `HotPoolSize`?**

When you have a high-frequency acquire/release pattern (e.g. bullet fire at 60Hz) and want to guarantee the fastest possible pop for the first `HotPoolSize` objects. Hot objects are O(1) stack pops; cold objects are O(1) array pops. The difference is cache locality, not algorithmic complexity.

---

**What does `Alpha` control?**

`Alpha` is the smoothing coefficient for the EMA demand tracker. A higher value (closer to 1) makes the EMA react faster to spikes; a lower value (closer to 0) makes it smoother and more stable. Default is `0.3`.

---

## Acquire & Release

**What happens if I call `Acquire` on an empty pool?**

Fluix tries `BorrowPeers` in order. If no peer has a spare object, it calls `Factory` directly (a miss). The miss is counted and `Signals.OnMiss` fires.

---

**What happens if I call `Release` on a full pool?**

If `OnOverflow` is set, it is called with the object. Otherwise the object is dropped (not returned to the pool and not destroyed — the caller is responsible if it needs cleanup).

---

**Is double-release safe?**

Double-release is detected and a warning is emitted. The object is not returned to the pool a second time.

---

**What does `ReleaseAll` do?**

It force-returns every currently live object by calling `Reset` on each and returning it to the pool (or calling `OnOverflow` if the pool is full). Useful for wave clears or round resets.

---

## TTL

**How does TTL work?**

Each acquired object is stamped with an acquisition timestamp. On every Heartbeat tick, Fluix scans live objects and force-reclaims any that have been held longer than `TTL` seconds. `Reset` is called and the object is returned to the pool (or `OnOverflow` if full).

---

**Does TTL affect performance?**

The TTL scan runs in the Heartbeat, not on the acquire/release hot path. Cost scales with `GetLiveCount()`. For typical pool sizes it is negligible.

---

## Peers

**What is cross-pool borrowing?**

When the pool misses (cold and hot pools are both empty), Fluix iterates `BorrowPeers` and tries to pop from each peer's cold pool. The first successful borrow is `Reset` and returned as the acquired object. The object is tracked as live in the borrowing pool.

---

**Do I need mutual borrowing?**

Not necessarily. One-directional borrowing (A borrows from B but not vice versa) is valid. Use mutual registration (`A:RegisterPeer(B)` and `B:RegisterPeer(A)`) when both pools serve similar object types and you want each to act as a fallback for the other.

---

## Lifecycle

**What is the difference between `Drain` and `Destroy`?**

`Drain` evicts all pooled objects (cold and hot) by calling `OnOverflow` or discarding them. Live objects are unaffected. The pool continues to function — new objects can be acquired and the Heartbeat keeps running.

`Destroy` tears down the pool entirely, disconnects the Heartbeat, clears all state, and makes the pool unusable.

---

**What does `Pause` do?**

It disconnects the Heartbeat without clearing any pool state. Pre-warming, adaptive sizing, and TTL checks stop until `Resume` is called. Useful during cutscenes or loading screens where you don't want background ticks.
