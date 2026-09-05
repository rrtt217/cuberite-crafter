# Research: disabling slots in the Crafter GUI

> **Question**: how can the Crafter's disabled slots be enforced inside the
> GUI (the native dropper 3x3 window), like the vanilla 1.21 Crafter's
> locked slots?

## TL;DR

- Cuberite exposes **no hook for window slot clicks** and **no per-slot lock
  API** in this build, so a plugin cannot veto a click directly and cannot
  render the grey "locked" overlay a vanilla client shows.
- What *is* possible (verified live): the native window is a **live view over
  the block entity's `cItemGrid`** - server-side `SetSlot` calls propagate to
  every open GUI instantly. The plugin exploits this with a **watchdog** that
  periodically scans disabled slots and *reverts insertions* a few ticks
  after they happen. Normal feed paths never place items into a locked slot:
  hoppers skip it and a crafter receiver (another crafter in front) inserts
  crafted output into the next available slot, failing the craft when no slot
  remains. The watchdog only covers the last un-interceptable path (a real
  player click) and **carries those items over to the next free slot** of the
  same crafter; only when no slot is left at all is it popped out of the front
  face. The result behaves like a vanilla locked slot for filling, while
  players can still remove items.

## Why there is no click interception

### Verified empirically

Probe hooks were registered for every interaction path and a real client
(MCC bot) drove the GUI:

| Event | Hooks that fired | Verdict |
|---|---|---|
| Right-click the block to open the GUI | `HOOK_PLAYER_USING_BLOCK`, `HOOK_PLAYER_USED_BLOCK`, `HOOK_PLAYER_OPENING_WINDOW` | interruptible at open time |
| Click a slot (pick up / place / shift-click / drag) | **none** | window clicks never reach Lua |
| Cursor drag with items | **none** | processed in C++ only |

Window slot clicks (`Click Window` packets) are consumed by Cuberite's C++
`cWindow` layer; no `HOOK_*` fires (there is no window-click hook among the
71 hooks this build exposes). `HOOK_PLAYER_LEFT_CLICK`/`RIGHT_CLICK` only
fire for *block-interaction* packets, not window clicks.

### API surface

The `cWindow` class exposes exactly 11 methods to Lua (`GetSlot`,
`SetSlot`, `SetProperty`, ...) - there is **no blocked/locked-slot flag** and
no way to tell the client to grey out a slot. A grey overlay is a pure client
render feature of vanilla 1.21 and cannot be produced by a 1.12-era server.

## The mechanism that works: revert-on-insert watchdog

### Key fact (verified)

The dropper's native window is bound to the block entity's `cItemGrid` as a
live view. Setting a slot server-side (`grid:SetSlot(...)`) updates every
open window immediately - no reopening, no refresh needed. So a plugin can
reverse an unwanted GUI change visibly.

### Algorithm

1. Every locked (disabled) slot has an **expected baseline** stored in
   `Entry.locked[slot]`. An explicit sentinel `LOCK_EMPTY` marks slots that
   must stay empty (a bare `nil` cannot represent "empty" - it looks like
   "never observed" and would let each scan re-accept an insertion).
2. A throttled `HOOK_WORLD_TICK` handler (default every 5 ticks ~ 0.25 s,
   `LockWatchdogTicks`) reads each disabled slot and compares it with the
   baseline. It deliberately runs from the **world tick** hook (world tick
   thread context, guaranteed not to block) rather than the server-level
   `HOOK_TICK`, which can deadlock with per-world hooks; scans are restricted
   to the ticking world:
   - **empty baseline, now filled** - revert (clear the slot), then carry the
     whole stack over to the next available (non-disabled) slot of the same
     crafter; only when the crafter has no slot at all is it popped out of
     the front (the GUI workaround - the click itself cannot be blocked);
   - **same item, count grew** - revert to the baseline count, carry the
     surplus over to the next available slot (same pop-out fallback);
   - **removal / emptied** - allowed (vanilla semantics: locked slots reject
     filling but players may take items out); baseline updated;
   - **swapped for a different item** - accepted and re-baselined (dupe-safe;
     a hard revert would re-create items the player is now holding);
   - **first observation of a slot** - accepted as the baseline (grace for
     restarts and admin `crafter set` writes, which also re-baseline
     explicitly via `SnapshotLocked`).
3. Because the open window mirrors the grid, the carry-over is visible to
   the player right away: the inserted item appears to slide out of the
   locked slot into the next free slot of the crafter.

### Why this design is dupe-safe

The watchdog only ever *removes items that are currently in the slot* and,
guided by `CrafterCore.InsertIntoReceiver`, re-places them according to
the crafter's fill rules (or pops them out only when the crafter is full) - it
never re-creates items that were taken out. The one inherently ambiguous
operation (a player swapping the contents) is deliberately accepted rather
than risking a duplicate.

## What is still not achievable (and why)

- **Grey "locked" overlay**: not expressible by a 1.12-protocol server; the
  concept does not exist in the window protocol.
- **Zero-flicker lock**: the rejected item is visible in the grid for up to
  ~0.25-0.5 s until the next scan reverts it. Lowering `LockWatchdogTicks`
  tightens this at the cost of more scans.
- **Origin-accurate returns**: the plugin cannot know *who* clicked or cancel
  the placement after the fact - the best it can do is carry the items over
  to the next free slot of the same crafter, popping them to the crafter's
  front only when the crafter is completely full.

## How players lock slots

Vanilla locks slots from inside the GUI (1.21 lock button). That is not
possible here — there is no window-click hook to catch "the player clicked the
lock button / a slot". Instead players use the in-game command, which is just
as practical:

1. Stand next to the crafter you want to configure (or look at your coordinates).
2. Run `/crafter lock 2` (permission `crafter.lock`, granted to all players)
   to lock slot 2, or `/crafter unlock 2` to release it.
3. The plugin resolves the **nearest registered crafter within 8 blocks** and
   toggles the slot; the optional `[x y z]` arguments target a specific block.

Locked slots then behave as described above: hoppers skip them, the recipe
matcher ignores them, and anything that lands in a locked slot through an
un-interceptable path is carried over to the next free slot (or, when the
crafter is full, popped out of the front as the last-resort workaround).

## Cost & tuning

Scan cost is proportional to the number of crafters that have locked slots
(9 `GetSlot` calls each). The scan is skipped entirely for crafters without
disabled slots. Tune with:

```ini
[Crafter]
LockWatchdogTicks=5   ; world-tick callbacks between scans; 0 disables the lock
```

## Verification matrix (real client)

| Action | Result |
|---|---|
| Cobblestone lands in a locked *empty* slot (un-interceptable path) | slot cleared; cobble x64 carried over to the next free slot; GUI resyncs immediately |
| Stone added onto a locked slot holding stone x3 | surplus x61 carried over to the next free slot; slot back to x3 |
| Anything lands in a locked slot while the crafter is *completely full* | popped out of the front (GUI workaround; impossible to cancel the click) |
| Take stone out of a locked slot | allowed; no restore, no duplicate |
| Craft a recipe next to locked slots | unaffected; locked slots untouched; no false rejects |
| Admin `crafter set` on a locked slot | accepted; baseline re-synced (no false revert) |
