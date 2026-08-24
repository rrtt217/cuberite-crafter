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
  after they happen, ejecting the rejected items through the normal output
  path. The result behaves like a vanilla locked slot for filling, while
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
   - **empty baseline, now filled** - revert (clear the slot), eject the
     whole stack through `Eject()` (front container first, else pickups);
   - **same item, count grew** - revert to the baseline count, eject the
     surplus;
   - **removal / emptied** - allowed (vanilla semantics: locked slots reject
     filling but players may take items out); baseline updated;
   - **swapped for a different item** - accepted and re-baselined (dupe-safe;
     a hard revert would re-create items the player is now holding);
   - **first observation of a slot** - accepted as the baseline (grace for
     restarts and admin `crafter set` writes, which also re-baseline
     explicitly via `SnapshotLocked`).
3. Because the open window mirrors the grid, the revert is visible to the
   player right away: the item appears to "bounce back" out of the locked
   slot (in reality it lands in the front container / as a pickup).

### Why this design is dupe-safe

The watchdog only ever *removes items that are currently in the slot* and
ejects them through the standard output path - it never re-creates items
that were taken out. The one inherently ambiguous operation (a player
swapping the contents) is deliberately accepted rather than risking a
duplicate.

## What is still not achievable (and why)

- **Grey "locked" overlay**: not expressible by a 1.12-protocol server; the
  concept does not exist in the window protocol.
- **Zero-flicker lock**: the rejected item is visible in the grid for up to
  ~0.25-0.5 s until the next scan reverts it. Lowering `LockWatchdogTicks`
  tightens this at the cost of more scans.
- **Origin-accurate returns**: the plugin cannot know *who* clicked, so
  rejected items go to the crafter's front (container or pickups) rather
  than back to the clicker's cursor.

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
matcher ignores them, and the GUI watchdog bounces any inserted items back out.

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
| Insert cobblestone into a locked *empty* slot | rejected; slot stays empty; cobble x64 appears in the front chest; GUI resyncs immediately |
| Add stone onto a locked slot holding stone x3 | surplus x61 rejected; slot back to x3; chest receives x61 |
| Take stone out of a locked slot | allowed; no restore, no duplicate |
| Craft a recipe next to locked slots | unaffected; locked slots untouched; no false rejects |
| Admin `crafter set` on a locked slot | accepted; baseline re-synced (no false revert) |
