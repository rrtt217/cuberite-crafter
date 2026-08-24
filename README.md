# Crafter (合成器) — an automatic crafting block for Cuberite

A faithful re-implementation of the Minecraft **Crafter** block (1.21 style),
built on top of Cuberite's native **dropper** block entity. Place it, feed it
with a hopper, hit it with a redstone signal and it crafts the matching recipe,
ejects the result out of its front, and lets you lock slots that must not be used.

> **Why a dropper as the prototype?** The dropper provides, for free: redstone
> activation, block orientation, a persisted 3x3 grid, hopper interoperability and
> native container eject — exactly what a crafter needs.

## Features

- **3x3 crafting grid** — the dropper's native `cItemGrid`, saved with the world.
- **Native GUI** — right-click opens the dropper's own 3x3 window. No custom
  `cLuaWindow`, so inventory stays fully synchronised (this build's `cLuaWindow`
  drag/paint path crashes the server).
- **Redstone crafting** — a rising edge (lever, button, redstone block, torch)
  schedules a craft 4 game ticks later (2 redstone ticks), matches a recipe,
  consumes ingredients and ejects the result from the front.
- **Slot locking** — disabled slots are skipped by the recipe matcher and by
  hoppers (their items stay put and are never consumed).
- **Hopper rules** — hoppers fill the first *empty non-disabled* slot
  (left-to-right, top-to-bottom); if none, they merge into the smallest existing
  stack of the same item; if the crafter is full it rejects the item.
- **Output routing** — results drop into a container placed in front (chest,
  hopper, ...), otherwise they spawn as item pickups.
- **Crafter item** — obtained via `/crafter` or crafted in a crafting table
  (vanilla 3x3 recipe). Placing it registers the block; breaking it drops the
  crafter item plus all its contents.
- **Crafter crafts crafter** — the crafter's own recipe is injected into the
  plugin's recipe database, so a crafter can craft a new crafter.
- **Persistence** — disabled slots and custom names survive restarts
  (`crafters.dat`).

## Requirements

- Cuberite with the **dropper = block 158** mapping (see
  [Compatibility](#compatibility)). Built and tested against a custom
  1.12.2-protocol build; other builds need the block-ID mapping adjusted.
- A vanilla-style `crafting.txt` + `items.ini` in the server folder
  (the recipe database is parsed in pure Lua at startup).

## Installation

1. Copy the `Crafter/` folder into your server's `Plugins/` directory.
2. Restart the server (or run `reload` in the console).
3. Grant the permissions below to the groups/ranks of your choice.

## Commands & permissions

| Command | Permission | Who | Description |
|---|---|---|---|
| `/crafter [name]` | `crafter.get` | everyone | Obtain a crafter item (optional custom display name) |
| `/crafter help` | `crafter.admin` | operators/admins | Show all subcommands |
| `/crafter list` | `crafter.admin` | operators/admins | List registered crafters |
| `/crafter info <x> <y> <z>` | `crafter.admin` | operators/admins | Show block, name, disabled slots, grid contents |
| `/crafter place <x> <y> <z> [name]` | `crafter.admin` | operators/admins | Create + register a crafter at coordinates |
| `/crafter give <player> [name]` | `crafter.admin` | operators/admins | Give a crafter item to another player |
| `/crafter set` / `setall` | `crafter.admin` | operators/admins | Set one or all grid slots (`item 0` clears) |
| `/crafter toggle <x> <y> <z> <slot>` | `crafter.admin` | operators/admins | Lock/unlock a slot |
| `/crafter pulse` / `craft` | `crafter.admin` | operators/admins | Simulate a redstone rising edge / run a craft now |
| `/crafter del <x> <y> <z>` | `crafter.admin` | operators/admins | Unregister a crafter |
| `/crafter save` / `reloaddb` | `crafter.admin` | operators/admins | Save the registry / reload the recipe DB |

All management subcommands also exist as the server-console command `crafter`
(no permission needed there). See [TESTING.md](TESTING.md) for the full command
reference and worked examples.

**Permission setup:**

- `crafter.get` — lets players obtain the crafter item. Assign to your default
  group/rank (anyone you want to be able to craft crafters).
- `crafter.admin` — in-game access to every management subcommand. Assign to
  operators/admins only. (Ranks with the `*` wildcard permission get it
  automatically.)

## Configuration

`settings.ini` (in the plugin folder):

```ini
[Crafter]
CraftDelayTicks=4      ; ticks between redstone signal and craft (4 = 2 redstone ticks)
EnableSounds=true      ; dispense/fail sound effects
EnableParticles=true   ; smoke on craft
Debug=false            ; verbose server-console logging
```

## How it works

| File | Role |
|---|---|
| `main.lua` | Initialization, hook registration, `/crafter` command dispatcher |
| `crafter_core.lua` | Crafter registry, redstone→craft→eject, hopper rules, persistence, crafter item |
| `crafter_recipes.lua` | Pure-Lua `crafting.txt`/`items.ini` parser + 3x3 recipe matcher |
| `crafter_dbg.lua` | Management interface (console + in-game with `crafter.admin`) |
| `settings.ini.example` | Sample configuration |

A crafter is physically a dropper block entity registered in a plugin-side
registry. Custom names and disabled slots are tracked by the plugin and are the
only non-vanilla state. Everything else (grid, orientation, redstone, eject)
is provided by the dropper underneath.

## Compatibility

- **Block IDs**: this build maps dropper = 158, dispenser = 23 (note: upstream
  Cuberite API docs differ). The plugin only references block 158 through
  `E_BLOCK_DROPPER`.
- **No custom GUI**: `cLuaWindow` click/drag handling (`OnLeftPaintEnd`) crashes
  this server build, so the crafter reuses the dropper's native 3x3 window.
- **Redstone only fires for player-placed blocks**: droppers created via
  `SetBlock` (e.g. `crafter place`) do not fire `HOOK_DROPSPENSE` and are not
  marked for saving. Real crafters must be placed with the crafter item.
- **Binding quirks worked around**: `AddItems` returns the count added and
  mutates the passed `cItems`; powered droppers set meta bit 0x8 (masked with
  `% 8` for orientation); `GetValueSetB` mis-parses `"true"` (booleans are read
  manually); chest block-entities lack `GetContents` on some paths (a
  `DoWithChestAt` fallback is used for output).

## Testing

Unit tests live in `_tools/` and the full manual end-to-end procedure (real
client, redstone, hoppers, persistence) is documented in
**[TESTING.md](TESTING.md)**.
