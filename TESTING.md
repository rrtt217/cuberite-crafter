# Testing the Crafter plugin

This document collects every automated and manual test used to validate the
Crafter plugin, plus the tooling needed to reproduce them. The plugin itself, its
commands and its configuration are documented in the [README](README.md).

## 1. Automated unit tests

The recipe parser/matcher is pure Lua and runs standalone, without a server.
All scripts `dofile` `crafter_recipes.lua`, so run them **from the plugin folder**
and with the server's `crafting.txt`/`items.ini` available (`/path/to/Cuberite`):

```sh
cd Plugins/Crafter
lua _tools/test_recipes.lua            # main suite
lua _tools/test_crafter_recipe.lua     # injected crafter-crafts-crafter recipe
lua _tools/test_dropper.lua            # dropper/ingredient matching
lua _tools/test_redstone.lua           # redstone / redstone-torch recipes
# parser + alias audits (each targets one parser regression):
for f in _tools/test_parse*.lua; do lua "$f"; done
```

The scripts embed absolute paths to the server files in a few places
(`/home/david/Cuberite/...`); adjust them to your checkout if you moved things.

| Script | Verifies |
|---|---|
| `test_recipes.lua` | All 789 vanilla recipes self-match exactly (round-trip); every parsed recipe can be found again by the matcher. **789/789 passed.** |
| `test_crafter_recipe.lua` | The injected crafter recipe (iron + workbench + redstone + dropper) is parsed and matches its 3x3 pattern. |
| `test_dropper.lua` | Dropper-relevant recipes (incl. the crafter's) resolve against `items.ini` aliases. |
| `test_redstone.lua` | `redstonedust` aliases (block 55 vs. item 331) and the redstone torch recipes match — regression test for item-id shadowing by block ids. |
| `test_parse.lua` … `test_parse8.lua` | Step-by-step audits of the parser: multi-word names (`Cooked Rabbit`), `^`-damage syntax with surrounding spaces (`Dye ^-1`), alias corrections (cake, skulls/heads), duplicate-key handling, and empty/edge-case lines. |

### Static checks

```sh
# repo lint (site-wide .luacheckrc knows all Cuberite globals):
luacheck Plugins/Crafter/
# API surface check (unknown classes/methods/hook constants):
#  -> the preset's cuberite_check tool, plugin = Crafter
```

## 2. Manual end-to-end tests (real client / MCC bot)

The environment for these tests: a running Cuberite server, the plugin loaded
(`reload` in the console restarts it), and a **real client** — the MCC bot is
used here to place blocks, flick levers, open windows and observe pickups.

> **Important**: `cWorld:SetBlock`-created droppers **do** fire redstone in this
> build (live-probed: adjacent redstone block and direct `Activate()` both made a
> `SetBlock` dropper dispense, `HOOK_DROPSPENSE` fired). The two real pitfalls are
> different: (1) `SetBlock` in an **unloaded chunk is silently a no-op**, and
> (2) `FastSetBlock` creates **no block entity** — the block renders as a dropper
> but is truly inert (no window, no redstone, no hopper). The craft tests below
> still use a **player-placed** crafter, because they exercise the placement
> hooks (PLACING/PLACED), item consumption and real-client behaviour.

### 2.1 Setup

1. Give yourself a crafter item: `/crafter` (or `crafter give <player>` from the
   console).
2. Place it on the ground. The plugin logs `registered crafter at world:x:y:z`
   (Debug=true in `settings.ini` shows these logs).
3. Open it (right-click) to fill the 3x3 grid, or use the management commands:

```
# in-game (needs crafter.admin) or in the console:
crafter set    120 80 0 0 50 4     # slot 0: 4x torch (id 50)
crafter setall 120 80 0 50 8      # all slots: 8x torch
crafter info   120 80 0           # inspect block + grid
crafter list                      # every registered crafter
```

### 2.2 Test matrix

| # | Scenario | Procedure | Expected result |
|---|---|---|---|
| 1 | **Real-client placement registers the crafter** | Place the crafter item with a client | Log `registered crafter at …`; `crafter list` shows it |
| 2 | **Redstone rising edge crafts** | Put 4x torch in the grid, flick a lever (or run `crafter pulse`) | 4 game ticks later the torch is consumed and 4x torch pickups spawn in front; `crafter info` shows the slot emptied |
| 3 | **Disabled slot blocks crafting** | `crafter toggle` the slot holding coal; try to craft a recipe using coal | Craft fails (fail sound), the coal stays in the slot; toggling back allows the craft again |
| 4 | **Hopper fill order** | Hopper above feeding coal (and a mixed set: coal + iron) | Coal arrives **one item at a time** (count grows by 1 per 8-tick cycle, never a whole stack); first empty non-disabled slot is filled left-to-right/top-to-bottom; disabled slots are skipped; with no empty slots the *smallest* same-type stack is topped up; a full crafter rejects the item (it stays in the hopper) |
| 5 | **Output into container** | Place a chest in front of the dropper's face; craft | Result is deposited into the chest, not spawned as pickups |
| 6 | **Breaking drops item + contents** | Mine a placed crafter | Pickups contain the crafter item plus all non-empty grid items; `crafter list` no longer shows it |
| 7 | **Persistence** | `crafter toggle`, then reload the plugin / restart the server | Disabled slots and custom names restored from `crafters.dat`; grid persists with the world |
| 8 | **Debounce** | Two pulses while a craft is pending | Only one craft runs |
| 9 | **Crafting-table recipe** | 3x3: iron ring + workbench + redstone + dropper in a crafting table | Result: crafter item; after taking it the grid is fully consumed |
| 10 | **Crafter crafts crafter** | Put the same 3x3 pattern inside a crafter's grid, pulse it | A new crafter item (with name/lore marker) is ejected; placing it registers a new crafter |
| 11 | **Permission gating** | As a normal player run `/crafter info …`; as an op run it | Normal player is refused (`crafter.admin` required); op sees the details |
| 12 | **GUI slot lock** | Lock a slot (as a normal player: `/crafter lock <slot>` standing next to the crafter, or as admin via `crafter toggle`), have an item land in that locked slot via a path we cannot intercept, and watch the watchdog (then try to *take* an item out) | The item is **carried over to the next available slot** of the same crafter within ~0.25 s (watchdog log `GUI lock: carried …`); only when the crafter has no slot left at all is it popped out of the front as the workaround (log `GUI lock: rejected … (no slot left, …)`); removal is allowed and not reverted |
| 13 | **Crafter receiver feed-in** | Crafter A directly faces Crafter B. Lock slot 0 of B, leave B's other slots empty, craft something in A | Output lands in B's **slot 1** (first non-locked empty slot); nothing lands in the locked slot 0 and nothing is ejected (`receiver at … took x…`) |
| 14 | **Crafter receiver full → craft fails** | Crafter A faces Crafter B; B's slot 0 locked and B's remaining slots filled with non-mergeable items; craft in A | The craft **fails** (`craft failed … (no output space in front)`), A's ingredients are **not consumed** and nothing is ejected/dropped |
| 15 | **Crafter receiver merge** | As in the feed-in case but B's slot 1 holds 1× of the output item type (rest full with other items); craft | The output **merges into B's slot 1** (smallest same-type stack) instead of failing or ejecting |
| 16 | **Player-facing lock/unlock** | As a **Default-rank** player stand next to a crafter and run `/crafter lock 2`, `/crafter unlock 2`; also try `/crafter info …` | Lock/unlock succeeds without coordinates (`已锁定槽位 2（world:…）`), shows up in `crafter list` (`disabled={…}`); the admin-only `info` subcommand is refused with a `crafter.admin` message |

### 2.3 Redstone wiring notes

- A lever is the simplest rising edge: flip it on, craft fires; flipping it off
  and on again fires another craft.
- A redstone torch, button or block next to the crafter works the same way.
- The `crafter pulse <x> <y> <z>` command simulates the rising edge directly and
  is useful when no redstone is wired up.

### 2.4 GUI slot lock notes

- Locked slots are enforced by a **revert-on-insert watchdog** (there is no
  window-click hook in this build). Normal feed paths never place items into
  a locked slot: hoppers skip it, and a crafter receiver (another crafter in
  front) inserts crafted output into the next available slot, failing the
  craft when no slot remains. Only un-interceptable insertions (a real
  player click) are reverted after `LockWatchdogTicks` (default 5) — the
  item is carried over to the next free slot of the same crafter, or (only if
  the crafter is completely full) popped out of the front; the open GUI
  resyncs automatically.
- The watchdog runs from **`HOOK_WORLD_TICK`** (world tick thread context), not
  the server-level `HOOK_TICK` which can deadlock with per-world hooks; scans are
  restricted to the ticking world.
- `crafter set`/`setall` on a locked slot is treated as authoritative and
  re-baselines the lock, so automation may still write whatever it needs.
- Full mechanism, limits and API research: [docs/gui-slot-locking.md](docs/gui-slot-locking.md).

## 3. Known quirks relevant to testing

- **`SetBlock` crafters are fully redstone-capable** (corrected 2026-08 live
  probe): `crafter place` (`cWorld:SetBlock` + meta) creates the block entity
  synchronously and redstone triggers it. What makes a crafter inert: using
  `FastSetBlock` (no block entity) or placing into an unloaded chunk (silent
  no-op — check `GetBlockTypeMeta` returns `valid` right after). Placement hooks
  (PLACING/PLACED) do not fire for `SetBlock`, which is why `crafter place`
  registers via `DoWithDropperAt`. Verify client-facing workflows (GUI, item
  consumption, sounds) with a player-placed crafter.
- **`GetValueSetB` bug**: boolean settings are parsed from `GetValue` manually;
  if a checkbox-like tool writes `true` it still works after `reload`.
- **Debug output**: with `Debug=true`, every hook/craft decision is logged with a
  `[Crafter]` prefix — turn it off for production.

## 4. Regression log

Significant bugs found during development and their regression tests:

- **Workbench recipe did not consume ingredients** — `Recipe:SetIngredient` was
  missing; now every non-empty pattern cell is registered so Cuberite consumes
  the grid. Covered by E2E test #9.
- **Item-id shadowing in `items.ini`** — block ids shadowed item ids (`redstonedust`
  = 55 vs 331, `cake`, skull subtypes). Fixed with an explicit alias-correction
  table; covered by `test_redstone.lua` + `test_parse*.lua`.
- **Admin commands not usable in-game** — management subcommands were console-only,
  and `/crafter` treated every argument as an item name. Now `/crafter <sub>`
  dispatches to the shared handler behind the `crafter.admin` permission.
  Covered by E2E test #11.
- **"SetBlock droppers never fire redstone" (disproved 2026-08)** — a systematic
  live probe (MCPServer `execute_lua` + MCC bot keeping chunks loaded) showed
  `SetBlock` droppers dispense on redstone and `Activate()`, with a synchronous
  3x3 block entity. The earlier observation was caused by one of the real traps:
  `FastSetBlock` (creates no block entity) or an unloaded-chunk placement
  (silent no-op). Full placement-vs-player comparison data and the yaw/displacement
  meta mapping (from build commit ffa3279d `Mixins.h`) are in the session research
  notes; facing table: meta 0=down 1=up 2=N 3=S 4=W 5=E, same as vanilla.
- **Disabled slots were not enforced in the GUI** — window clicks are not
  interceptable in this build (no hook fires), so locked slots could be filled by
  hand. Added a revert-on-insert watchdog with an explicit `LOCK_EMPTY` baseline
  sentinel. Covered by E2E test #12; mechanism in
  [docs/gui-slot-locking.md](docs/gui-slot-locking.md).
- **Breaking a crafter dropped double contents** — the native break also drained
  the grid into the pickups list, and the handler re-added the same stacks. The
  handler now detects whether the grid is still populated and, if so, rebuilds the
  drop list deterministically (clear + one pass + crafter item), warming the
  -1/0 field quirk before reading. Covered by E2E test #6.
- **Hopper transfers were a whole stack at once (and hook-based transfers
  duplicated in this build)** — `HOOK_HOPPER_PUSHING_ITEM` returning true makes
  Cuberite re-invoke the hook for other slots (documented) and even false
  mis-handlers duplicated, so the handler only *vetoes* the native's chosen
  destination slot when it is disabled, or (with no empty slot) when it is not the
  smallest same-type stack; everything else is left to the native path (exactly
  one item per 8-tick cycle). Covered by E2E test #4.
- **Locked slots used to eject fed-in items (now: carry over / fail)** — the
  old feed paths deposited into the first empty slot regardless of lock state
  (via `AddItems`), so a crafter receiver with a locked slot 0 would fill it and
  the watchdog then *ejected* the item. Now a crafter receiver (including
  craft output into another crafter) inserts strictly per the crafter fill rules:
  locked slots are skipped, the item carries over to the next available slot
  (or merges into the smallest same-type stack), and with no slot at all the
  craft **fails before consuming** — nothing ever pops out on a normal feed.
  Only a real window click (un-interceptable) is reverted by the watchdog, which
  also carries the items over, popping them out only when the crafter is full.
  Covered by E2E tests #13-15.