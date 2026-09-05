-- crafter_core.lua
-- Core mechanics of the Crafter plugin.
--
-- A Crafter is physically a dropper block entity (E_BLOCK_DROPPER) marked in a
-- plugin-side registry. The dropper prototype provides, for free:
--   * redstone activation (HOOK_DROPSPENSE fires on a power-up of the block),
--   * orientation (meta 0-5, native placement is player-facing),
--   * a persisted 3x3 cItemGrid (slots 0-8) that hoppers can reach,
--   * native player-driven item transport when no plugin GUI is open.
-- The plugin then layers the crafter behaviour on top:
--   * protected-block markers + persistence of disabled slots / custom names,
--   * the native dropper window as the GUI (3x3 grid, no custom window),
--   * redstone rising-edge -> delayed craft -> eject (into container or world),
--   * crafter-specific hopper insertion rules (disabled slots + fill order),
--   * GUI slot lock: insertions into disabled slots are reverted by a watchdog
--     (no window-click hook exists, so a click cannot be blocked; normal feed
--     paths never place items into locked slots - they carry over instead).

CrafterCore = {}

-- ---------------------------------------------------------------------------
-- Constants
-- ---------------------------------------------------------------------------

-- The Lua global E_BLOCK_DROPPER (158 in this build; items.ini "dropper=158")
CrafterCore.E_BLOCK_DROPPER = E_BLOCK_DROPPER
CrafterCore.CRAFTER_ITEM_ID = 158      -- items.ini: "dropper=158"
CrafterCore.CRAFTER_ITEM_NAME = "合成器"
CrafterCore.CRAFTER_ITEM_LORE = "Crafter:auto"

-- Configuration, filled by main.lua from settings.ini
CrafterCore.Cfg = {
	CraftDelayTicks = 4,           -- 红石刻*2 = 4 game ticks, per the wiki
	EnableSounds = true,
	EnableParticles = true,
	Debug = false,
	LockWatchdogTicks = 5,         -- GUI lock scan interval (0 = disabled)
	Recipes = nil,                 -- recipe database (list) from crafter_recipes
}

-- Registry: key -> { world, x, y, z, disabled = {[slot]=true}, name, window, viewers = {[name]=true} }
CrafterCore.Crafters = {}

-- Persistence file (set by main.lua)
CrafterCore.SavePath = nil

-- Pending block-placement marker (HOOK_PLAYER_PLACING_BLOCK -> HOOK_PLAYER_PLACED_BLOCK)
CrafterCore.PendingPlacement = nil

function CrafterCore.DebugLog(...)
	if CrafterCore.Cfg.Debug then
		-- LOG() in this build only prints its first argument; join all parts.
		local Parts = {}
		for i = 1, select("#", ...) do Parts[i] = tostring(select(i, ...)) end
		LOG(table.concat(Parts, " "))
	end
end

-- ---------------------------------------------------------------------------
-- Registry helpers
-- ---------------------------------------------------------------------------

function CrafterCore.MakeKey(WorldName, X, Y, Z)
	return tostring(WorldName) .. ":" .. tostring(X) .. ":" .. tostring(Y) .. ":" .. tostring(Z)
end

function CrafterCore.KeyFromEntity(BE)
	local W = BE:GetWorld()
	if not W then return nil end
	return CrafterCore.MakeKey(W:GetName(), BE:GetPosX(), BE:GetPosY(), BE:GetPosZ())
end

function CrafterCore.IsCrafterEntity(BE)
	if not BE then return false end
	local Key = CrafterCore.KeyFromEntity(BE)
	return (Key ~= nil) and (CrafterCore.Crafters[Key] ~= nil)
end

function CrafterCore.Register(BE, a_Name)
	local Key = CrafterCore.KeyFromEntity(BE)
	if not Key then return false end
	if CrafterCore.Crafters[Key] then
		if a_Name then
			CrafterCore.Crafters[Key].name = a_Name
			CrafterCore.Save()
		end
		return false
	end
	local W = BE:GetWorld()
	CrafterCore.Crafters[Key] = {
		world = W,
		x = BE:GetPosX(),
		y = BE:GetPosY(),
		z = BE:GetPosZ(),
		disabled = {},
		locked = {},               -- baseline contents of disabled slots (GUI lock)
		name = a_Name or CrafterCore.CRAFTER_ITEM_NAME,
		window = nil,
		viewers = {},
	}
	CrafterCore.DebugLog("registered crafter at " .. Key)
	CrafterCore.Save()
	return true
end

function CrafterCore.Unregister(BE)
	if not BE then return end
	local Key = CrafterCore.KeyFromEntity(BE)
	if not Key then return end
	CrafterCore.UnregisterAt(Key)
end

-- Removes a crafter entry by registry key (works also after the block was
-- already removed from the world).
function CrafterCore.UnregisterAt(Key)
	local Entry = CrafterCore.Crafters[Key]
	if not Entry then return end
	CrafterCore.Crafters[Key] = nil
	CrafterCore.DebugLog("unregistered crafter at " .. Key)
	CrafterCore.Save()
end

-- Fills in the world/coords of an Entry created from disk (or lazily at any
-- future point), using the live block entity.
function CrafterCore.EnsureResolved(BE)
	if not BE then return nil end
	local Key = CrafterCore.KeyFromEntity(BE)
	local Entry = Key and CrafterCore.Crafters[Key]
	if not Entry then return nil end
	if not Entry.world then
		local W = BE:GetWorld()
		if W then
			Entry.world = W
			Entry.x = BE:GetPosX()
			Entry.y = BE:GetPosY()
			Entry.z = BE:GetPosZ()
		end
	end
	return Entry
end

-- ---------------------------------------------------------------------------
-- Crafter item
-- ---------------------------------------------------------------------------

function CrafterCore.MakeCrafterItem(a_Name)
	-- cItem(type,count,damage, enchantments, customName) in this build: there is no
	-- lore constructor arg, and a nil 4th arg fails; set the fields afterwards.
	local It = cItem(CrafterCore.CRAFTER_ITEM_ID, 1, 0)
	It.m_CustomName = a_Name or CrafterCore.CRAFTER_ITEM_NAME
	It.m_Lore = CrafterCore.CRAFTER_ITEM_LORE
	return It
end

function CrafterCore.IsCrafterItem(Item)
	if not Item then return false end
	if Item:IsEmpty() then return false end
	if Item.m_ItemType ~= CrafterCore.CRAFTER_ITEM_ID then return false end
	if Item.m_CustomName == CrafterCore.CRAFTER_ITEM_NAME then return true end
	return ((Item.m_Lore or ""):find("^Crafter:", 1) ~= nil)
end

-- ---------------------------------------------------------------------------
-- Grid bridging (plain tables <-> dropper cItemGrid)
-- ---------------------------------------------------------------------------

function CrafterCore.ReadGrid(BE)
	local Grid = {}
	local C = BE:GetContents()
	if not C then return Grid end
	for i = 0, 8 do
		local It = C:GetSlot(i)
		if It and not It:IsEmpty() then
			Grid[i] = {
				type = It.m_ItemType,
				damage = It.m_ItemDamage or 0,
				count = It.m_ItemCount,
			}
		end
	end
	return Grid
end

function CrafterCore.WriteGrid(BE, Grid)
	local C = BE:GetContents()
	if not C then return end
	for i = 0, 8 do
		local P = Grid[i]
		if P then
			C:SetSlot(i, cItem(P.type, P.count, P.damage or 0))
		else
			C:SetSlot(i, cItem())
		end
	end
end

-- ---------------------------------------------------------------------------
-- Redstone-driven crafting
-- ---------------------------------------------------------------------------

-- Called on every HOOK_DROPSPENSE for one of our crafters.  Because Cuberite's
-- dropper only dropspenses on a power-up transition, each call is treated as a
-- rising edge.  A second pulse while a craft is already scheduled is ignored
-- (pendingCraft), mirroring the "one craft per pulse" vanilla behaviour.
function CrafterCore.OnRedstonePulse(BE)
	local Entry = CrafterCore.EnsureResolved(BE)
	if not Entry then return end
	local Key = CrafterCore.KeyFromEntity(BE)
	if Entry.pendingCraft then
		CrafterCore.DebugLog("ignoring pulse at " .. Key .. " (craft pending)")
		return
	end
	Entry.pendingCraft = true
	local Delay = CrafterCore.Cfg.CraftDelayTicks
	CrafterCore.DebugLog("pulse at " .. Key .. ", craft in " .. Delay .. " ticks")
	BE:GetWorld():ScheduleTask(Delay, function()
		CrafterCore.DoCraft(Entry)
	end)
end

function CrafterCore.DoCraft(Entry)
	local Key = CrafterCore.MakeKey(Entry.world:GetName(), Entry.x, Entry.y, Entry.z)
	Entry.pendingCraft = false
	local W = Entry.world
	if not CrafterCore.Crafters[Key] then return end
	W:DoWithDropperAt(Entry.x, Entry.y, Entry.z, function(BE)
		local Recipes = CrafterCore.Cfg.Recipes
		if not Recipes then return false end
		local Grid = CrafterCore.ReadGrid(BE)
		-- Disabled slots do not participate in crafting (vanilla crafter): feed the
		-- matcher a copy with disabled slots hidden, but consume/write back against
		-- the full physical grid so disabled-slot items are preserved.
		local MatchGrid = {}
		local Disabled = Entry.disabled or {}
		for i = 0, 8 do
			if not Disabled[i] then
				MatchGrid[i] = Grid[i]
			end
		end
		local R, Binding = CrafterRecipes.FindRecipe(Recipes, MatchGrid)
		if not R then
			CrafterCore.DebugLog("craft failed at " .. Key .. " (no recipe)")
			CrafterCore.PlaySound(W, Entry.x, Entry.y, Entry.z, "block.dispenser.fail", 1.0)
			return false
		end
		-- Output: into the container in front if it accepts, else as pickups.
		-- The crafter's own recipe must eject the marked crafter item (name + lore)
		-- so that placing the result registers a new crafter.
		local OutItem
		if R.isCrafterRecipe then
			OutItem = CrafterCore.MakeCrafterItem()
		else
			OutItem = cItem(R.result.type, R.result.count, R.result.damage)
		end
		-- A crafter receiver with no available (non-locked) slot must FAIL the
		-- craft BEFORE the ingredients are consumed: nothing pops out, nothing is
		-- lost - the recipe simply does not run (vanilla "no output space").
		if not CrafterCore.CanPlaceFront(W, BE, OutItem) then
			CrafterCore.DebugLog("craft failed at " .. Key .. " (no output space in front)")
			CrafterCore.PlaySound(W, Entry.x, Entry.y, Entry.z, "block.dispenser.fail", 1.0)
			return false
		end
		-- Consume ingredients and write the remainder back into the grid.
		CrafterRecipes.ConsumeGrid(Grid, Binding)
		CrafterCore.WriteGrid(BE, Grid)
		CrafterCore.DebugLog("crafted " .. R.result.type .. "^" .. R.result.damage .. " x" .. R.result.count .. " at " .. Key)
		CrafterCore.Eject(W, BE, OutItem)
		CrafterCore.PlaySound(W, Entry.x, Entry.y, Entry.z, "block.dispenser.dispense", 1.7)
		if CrafterCore.Cfg.EnableParticles then
			CrafterCore.Smoke(W, Entry.x, Entry.y, Entry.z)
		end
		return false
	end)
end

-- Determines the coords in front of the dropper from its block meta.
function CrafterCore.GetFrontCoords(BE)
	local X, Y, Z = BE:GetPosX(), BE:GetPosY(), BE:GetPosZ()
	-- Use the vector overload (3-arg GetBlockMeta is deprecated & spammy here).
	-- Mask off any extra meta bits (this build sets bit 0x8 while a crafter is
	-- powered, which would otherwise shift the "front" direction).
	local Meta = BE:GetWorld():GetBlockMeta(Vector3i(X, Y, Z)) % 8
	if Meta == 0 then return X, Y - 1, Z end
	if Meta == 1 then return X, Y + 1, Z end
	if Meta == 2 then return X, Y, Z - 1 end
	if Meta == 3 then return X, Y, Z + 1 end
	if Meta == 4 then return X - 1, Y, Z end
	return X + 1, Y, Z
end

-- Inserts aItem (a single stack) into a crafter's grid following the crafter
-- fill rules: first empty non-disabled slot (left-to-right, top-to-bottom),
-- else the non-disabled slot holding the smallest same-type stack, else the
-- crafter is treated as full. Returns the number of items NOT placed (0 = the
-- whole stack was placed). Never ejects anything.
function CrafterCore.InsertIntoReceiver(Entry, Grid, Item)
	local Type = Item.m_ItemType
	local Damage = Item.m_ItemDamage or 0
	local Left = Item.m_ItemCount
	while Left > 0 do
		local Slot = CrafterCore.FindInsertTarget(Entry, Grid, Item)
		if not Slot then return Left end
		local Dst = Grid:GetSlot(Slot)
		if Dst:IsEmpty() then
			local Max = cItem(Type, 1, Damage):GetMaxStackSize()
			local Put = math.min(Left, Max)
			Grid:SetSlot(Slot, cItem(Type, Put, Damage))
			Left = Left - Put
		else
			local Free = Dst:GetMaxStackSize() - Dst.m_ItemCount
			if Free <= 0 then return Left end
			local Put = math.min(Left, Free)
			Grid:SetSlot(Slot, cItem(Type, Dst.m_ItemCount + Put, Damage))
			Left = Left - Put
		end
	end
	return Left
end

-- True when the block in front of BE can accept the WHOLE aItem without
-- ejecting it: a crafter receiver must have enough total capacity across its
-- non-disabled slots (empty slots = a full max-stack each; same-type stacks =
-- their remaining room; locked slots count nothing). Any other block (plain
-- container or air) always accepts, since the dropper prototype ejects into
-- it / as pickups. Capacity-based, so a partial merge slot is counted exactly.
function CrafterCore.CanPlaceFront(W, BE, Item)
	local FX, FY, FZ = CrafterCore.GetFrontCoords(BE)
	local Type = Item.m_ItemType
	local Damage = Item.m_ItemDamage or 0
	local Need = Item.m_ItemCount
	local HitCrafter = false
	local Capacity = 0
	W:DoWithBlockEntityAt(FX, FY, FZ, function(Dst)
		if Dst then
			local Entry = CrafterCore.EnsureResolved(Dst)
			if Entry then
				HitCrafter = true
				local G = Dst:GetContents()
				if G then
					for i = 0, 8 do
						if not Entry.disabled[i] then
							local It = G:GetSlot(i)
							if It:IsEmpty() then
								Capacity = Capacity + cItem(Type, 1, Damage):GetMaxStackSize()
							elseif (It.m_ItemType == Type) and ((It.m_ItemDamage or 0) == Damage) then
								Capacity = Capacity + (It:GetMaxStackSize() - It.m_ItemCount)
							end
						end
					end
				end
			end
		end
		return false
	end)
	-- A non-crafter front (plain container / air) always accepts: the eject
	-- path handles it (dropper-like AddItems / pickups).
	if not HitCrafter then return true end
	return (Capacity >= Need)
end

-- Ejects an item out of the front of the crafter: into a container in front
-- if one accepts it, otherwise as an item pickup. A crafter receiver is fed
-- with the crafter fill rules (locked slots skipped, item carries over to the
-- next available slot) and leftovers are returned WITHOUT being ejected.
-- With a_ForceEject leftover items are always dropped as pickups at the front
-- (used only by the GUI-lock watchdog's pop-out workaround).
function CrafterCore.Eject(W, BE, Item, a_ForceEject)
	local FX, FY, FZ = CrafterCore.GetFrontCoords(BE)
	local Items = cItems()
	Items:Add(Item)
	local ReceiverLeft = nil
	-- Deposit into a crafter receiver (if the front block is one of ours).
	W:DoWithBlockEntityAt(FX, FY, FZ, function(Dst)
		if Dst then
			local Entry = CrafterCore.EnsureResolved(Dst)
			if Entry then
				local G = Dst:GetContents()
				if G then
					ReceiverLeft = CrafterCore.InsertIntoReceiver(Entry, G, Item)
				else
					ReceiverLeft = Item.m_ItemCount
				end
				if (ReceiverLeft > 0) and a_ForceEject then
					-- Workaround path: a full crafter receiver in front must not
					-- swallow the items - drop the remainder as pickups.
					local Drop = cItems()
					Drop:Add(cItem(Item.m_ItemType, ReceiverLeft, Item.m_ItemDamage or 0))
					W:SpawnItemPickups(Drop, FX, FY, FZ, 0.6)
					ReceiverLeft = 0
				end
				return false
			end
			-- Non-crafter container: AddItems() mutates Items in place to hold the
			-- leftovers and returns the number of items added, so the container
			-- check must look for a grid method via pcall (some block-entity Lua
			-- bindings in this build lack GetContents on the shared base class).
			local ok, G = pcall(function() return Dst:GetContents() end)
			if ok and G then
				pcall(function() G:AddItems(Items, true) end)
			end
		end
		return false
	end)
	if ReceiverLeft ~= nil then
		local Taken = Item.m_ItemCount - ReceiverLeft
		CrafterCore.DebugLog("receiver at " .. FX .. "," .. FY .. "," .. FZ
			.. " took x" .. Taken .. " of item " .. Item.m_ItemType
			.. ", leftover x" .. ReceiverLeft)
		return ReceiverLeft
	end
	-- Fallback for containers whose generic block-entity binding lacks
	-- GetContents in this build (chests fetch fine from some contexts but not
	-- from the plugin env): try the chest-specific accessor too.
	if Items:Size() > 0 then
		W:DoWithChestAt(FX, FY, FZ, function(Chest)
			if Chest and Chest.GetContents then
				local ok, G = pcall(function() return Chest:GetContents() end)
				if ok and G then
					pcall(function() G:AddItems(Items, true) end)
				end
			end
			return false
		end)
	end
	if Items:Size() > 0 then
		W:SpawnItemPickups(Items, FX, FY, FZ, 0.6)
		CrafterCore.DebugLog("ejected " .. Items:Size() .. " pickup stack(s) at " .. FX .. "," .. FY .. "," .. FZ)
	end
end

function CrafterCore.PlaySound(W, X, Y, Z, SoundName, Pitch)
	if CrafterCore.Cfg.EnableSounds then
		W:BroadcastSoundEffect(SoundName, X, Y, Z, 0.7, Pitch)
	end
end

function CrafterCore.Smoke(W, X, Y, Z)
	W:BroadcastParticleEffect("smoke", Vector3f(X, Y, Z), Vector3f(0, 0, 0), 0, 20)
end

-- ---------------------------------------------------------------------------
-- Hopper insertion rules (vanilla crafter)
--   1) first empty non-disabled slot, left-to-right top-to-bottom
--   2) else the non-disabled slot with the smallest stack of the same item
--   3) else the crafter is "full" and accepts nothing
-- ---------------------------------------------------------------------------

function CrafterCore.FindInsertTarget(Entry, CrafterGrid, SrcItem)
	-- Pass 1: first empty, non-disabled slot
	for i = 0, 8 do
		if not Entry.disabled[i] then
			if CrafterGrid:GetSlot(i):IsEmpty() then return i end
		end
	end
	-- Pass 2: smallest existing stack of the same item
	local Best, BestCount = nil, math.huge
	for i = 0, 8 do
		if not Entry.disabled[i] then
			local It = CrafterGrid:GetSlot(i)
			if not It:IsEmpty() then
				if It.m_ItemType == SrcItem.m_ItemType then
					if (It.m_ItemDamage or 0) == (SrcItem.m_ItemDamage or 0) then
						if It.m_ItemCount < BestCount then
							Best, BestCount = i, It.m_ItemCount
						end
					end
				end
			end
		end
	end
	if Best then
		local It = CrafterGrid:GetSlot(Best)
		if It.m_ItemCount < It:GetMaxStackSize() then return Best end
	end
	return nil
end

-- Hopper interop: driven by HOOK_HOPPER_PUSHING_ITEM using the build's native
-- cHopperEntity::MoveItemsToSlot semantics:
--   * the hook's DstSlot is the destination cell the hopper intends to fill,
--   * returning TRUE vetoes that move and the native tries the next source
--     slot for the same destination (documented in the C++ source),
--   * returning FALSE lets the native move exactly ONE item (CopyOne) and
--     decrement the source slot by one - no loss, one item per 8-tick cycle,
--   * the native already fills the first empty destination cell in order
--     (left-to-right, top-to-bottom) and tops up a taken matching cell when
--     no empty cell succeeds (the merge rule).
-- So our handler ONLY vetoes pushes into DISABLED slots; everything else is
-- handed back to the native, which satisfies the fill-order / merge / reject
-- rules on its own.
function CrafterCore.OnHopperPushingItem(World, Hopper, SrcSlot, DstBlockEntity, DstSlot)
	if not CrafterCore.IsCrafterEntity(DstBlockEntity) then return false end
	local Entry = CrafterCore.EnsureResolved(DstBlockEntity)
	if not Entry then return false end
	-- Veto pushes into disabled slots: the native then tries the next slot.
	if Entry.disabled and Entry.disabled[DstSlot] then
		CrafterCore.DebugLog("hopper vetoed push into disabled slot " .. DstSlot
			.. " at " .. CrafterCore.KeyFromEntity(DstBlockEntity))
		return true
	end
	-- No empty non-disabled slot: the native would top up the FIRST taken slot
	-- in order, but the spec wants the SMALLEST same-type stack. Veto every
	-- top-up target except the smallest matching stack so the native walks its
	-- destination loop onto it. When an empty slot exists, the native's
	-- first-empty fill already matches the spec and nothing overrides it.
	for i = 0, 8 do
		if not Entry.disabled[i] then
			if DstBlockEntity:GetContents():GetSlot(i):IsEmpty() then return false end
		end
	end
	local HG = Hopper:GetContents()
	local SrcItem = HG and HG:GetSlot(SrcSlot)
	if not SrcItem or SrcItem:IsEmpty() then return false end
	local SrcType = SrcItem.m_ItemType
	local SrcDamage = SrcItem.m_ItemDamage or 0
	local Grid = DstBlockEntity:GetContents()
	local Best, BestCount = DstSlot, math.huge
	for i = 0, 8 do
		if not Entry.disabled[i] then
			local It = Grid:GetSlot(i)
			if not It:IsEmpty() and (It.m_ItemType == SrcType) and ((It.m_ItemDamage or 0) == SrcDamage) then
				if It.m_ItemCount < BestCount then Best, BestCount = i, It.m_ItemCount end
			end
		end
	end
	if DstSlot ~= Best then
		CrafterCore.DebugLog("hopper vetoed top-up of slot " .. DstSlot
			.. " (smallest is " .. Best .. " x" .. BestCount .. ")")
		return true
	end
	return false
end

function CrafterCore.ToggleDisabled(Entry, Slot)
	if Entry.disabled[Slot] then
		Entry.disabled[Slot] = nil
		if Entry.locked then Entry.locked[Slot] = nil end
	else
		Entry.disabled[Slot] = true
	end
	CrafterCore.Save()
	return Entry.disabled[Slot] ~= nil
end

-- ---------------------------------------------------------------------------
-- GUI slot lock ("locked slot" baked into the native dropper window)
-- ---------------------------------------------------------------------------
--
-- There is NO Lua hook for window slot clicks in this build (verified: a real
-- client click fires no plugin hook), so a plugin cannot veto a click directly.
-- Normal feed paths (hopper, craft output into a crafter receiver) already
-- route around locked slots: items carry over to the next available slot and,
-- when no slot exists, the feed simply fails - nothing pops out. The watchdog
-- below only exists for the remaining un-interceptable path (player GUI) and
-- reverts *insertions* into disabled slots a short while after they happen:
--   * the items are carried over to the next available slot of the same
--     crafter (like a hopper feed), or if the crafter has no slot left at all
--     they are popped out of the front face (the GUI workaround - the click
--     itself cannot be blocked);
--   * players may still remove items from a locked slot,
--   * the open GUI resyncs automatically because the native window is a live
--     view over the block entity's cItemGrid (server-side SetSlot propagates).

-- Sentinel marking "locked slot is (and must stay) empty". An explicit marker
-- is needed because an empty baseline stored as nil is indistinguishable from
-- "never observed yet", which would let each scan re-accept an insertion.
CrafterCore.LOCK_EMPTY = {}

-- Records the current grid contents of every disabled slot into Entry.locked
-- (the expected state). Call after any authoritative server-side write to the
-- grid (e.g. the `crafter set` console/in-game command).
function CrafterCore.SnapshotLocked(Entry, BE)
	local G = BE:GetContents()
	if not G then return end
	Entry.locked = Entry.locked or {}
	for Slot in pairs(Entry.disabled or {}) do
		local It = G:GetSlot(Slot)
		if It and not It:IsEmpty() then
			Entry.locked[Slot] = {
				type = It.m_ItemType,
				damage = It.m_ItemDamage or 0,
				count = It.m_ItemCount,
			}
		else
			Entry.locked[Slot] = CrafterCore.LOCK_EMPTY
		end
	end
end

-- Checks one crafter's disabled slots for unauthorized insertions and reverts
-- them. The very first observation of a slot is always accepted as the new
-- baseline (so console `set` / restarts never trigger a false revert).
function CrafterCore.LockCheckEntry(Entry)
	local W = Entry.world
	if not W then return end
	W:DoWithDropperAt(Entry.x, Entry.y, Entry.z, function(BE)
		local G = BE:GetContents()
		if not G then return false end
		Entry.locked = Entry.locked or {}
		for Slot in pairs(Entry.disabled or {}) do
			local It = G:GetSlot(Slot)
			local Cur = nil
			if It and not It:IsEmpty() then
				Cur = { type = It.m_ItemType, damage = It.m_ItemDamage or 0, count = It.m_ItemCount }
			end
			local Snap = Entry.locked[Slot]
			local Reject = nil   -- items to eject (amount already reflected in Cur)
			if Snap == nil then
				-- never observed yet: accept the current state as baseline
				Entry.locked[Slot] = Cur or CrafterCore.LOCK_EMPTY
			elseif Snap == CrafterCore.LOCK_EMPTY then
				if Cur ~= nil then
					-- insertion into an empty locked slot: reject the whole stack
					G:SetSlot(Slot, cItem())
					Reject = Cur
				end
				-- else still empty: nothing to do (baseline stays LOCK_EMPTY)
			elseif Cur == nil then
				-- player emptied the slot: allowed (vanilla semantics)
				Entry.locked[Slot] = CrafterCore.LOCK_EMPTY
			elseif (Cur.type ~= Snap.type) or (Cur.damage ~= Snap.damage) then
				-- swapped for a different item: accept and re-baseline
				Entry.locked[Slot] = Cur
			elseif Cur.count > Snap.count then
				-- same item was added by a player: reject the surplus
				G:SetSlot(Slot, cItem(Snap.type, Snap.count, Snap.damage))
				local Left = { type = Snap.type, damage = Snap.damage, count = Cur.count - Snap.count }
				Reject = Left
			else
				-- same item, equal or fewer: allowed (removal)
				Entry.locked[Slot] = Cur
			end
			if Reject then
				-- The item had to leave the locked slot. First carry it over to the
				-- next available (non-locked) slot of this same crafter, exactly
				-- like a hopper feed would. Only when the crafter genuinely has no
				-- slot left is it popped out of the front (the GUI workaround).
				local Key = CrafterCore.MakeKey(W:GetName(), Entry.x, Entry.y, Entry.z)
				local Left = CrafterCore.InsertIntoReceiver(Entry, G, cItem(Reject.type, Reject.count, Reject.damage))
				if Left <= 0 then
					CrafterCore.DebugLog("GUI lock: carried x" .. Reject.count .. " of item "
						.. Reject.type .. " to next slot (locked slot " .. Slot .. " at " .. Key .. ")")
				else
					CrafterCore.Eject(W, BE, cItem(Reject.type, Left, Reject.damage), true)
					CrafterCore.DebugLog("GUI lock: rejected x" .. Left .. " of item "
						.. Reject.type .. " (no slot left, locked slot " .. Slot .. " at " .. Key .. ")")
				end
			end
		end
		return false
	end)
end

-- Scans every registered crafter that has disabled slots. Called by the
-- throttled HOOK_WORLD_TICK handler in main.lua for the ticking world
-- (World == nil scans everything, kept for callers that don't know the world).
function CrafterCore.LockWatchdog(World)
	for _, Entry in pairs(CrafterCore.Crafters) do
		if Entry.disabled and next(Entry.disabled) then
			if (World == nil) or (Entry.world == World) then
				CrafterCore.LockCheckEntry(Entry)
			end
		end
	end
end

-- Resolves the crafter a player wants to act on: explicit coordinates, or the
-- nearest registered crafter in the player's world within 8 blocks. Used by the
-- player-facing /crafter lock|unlock commands so no coordinates or admin rights
-- are required to lock a slot on the crafter you are standing next to.
function CrafterCore.FindCrafterNear(Player, X, Y, Z)
	local PWorld = Player:GetWorld()
	if X and Y and Z then
		local Key = CrafterCore.MakeKey(PWorld:GetName(), X, Y, Z)
		return CrafterCore.Crafters[Key], Key
	end
	local PX, PY, PZ = Player:GetPosX(), Player:GetPosY(), Player:GetPosZ()
	local Best, BestKey, BestD = nil, nil, 64  -- 8 blocks squared
	for Key, E in pairs(CrafterCore.Crafters) do
		if (E.world == PWorld) and E.x and E.y and E.z then
			local DX, DY, DZ = E.x - PX, E.y - PY, E.z - PZ
			local D = DX * DX + DY * DY + DZ * DZ
			if D <= BestD then
				Best, BestKey, BestD = E, Key, D
			end
		end
	end
	return Best, BestKey
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

function CrafterCore.Save()
	if not CrafterCore.SavePath then return end
	local Lines = {}
	for Key, E in pairs(CrafterCore.Crafters) do
		local Dis = {}
		for S in pairs(E.disabled) do Dis[#Dis + 1] = S end
		table.sort(Dis)
		Lines[#Lines + 1] =
			string.format("%q|%s|%q", Key, table.concat(Dis, ","), E.name or CrafterCore.CRAFTER_ITEM_NAME)
	end
	local Content = table.concat(Lines, "\n")
	if #Lines > 0 then Content = Content .. "\n" end
	local F = io.open(CrafterCore.SavePath, "wb")
	if not F then return end
	F:write(Content)
	F:close()
end

function CrafterCore.Load()
	CrafterCore.Crafters = {}
	if not CrafterCore.SavePath then return end
	local Content = cFile:ReadWholeFile(CrafterCore.SavePath)
	if Content == nil or Content == "" then return end
	local function Undquotify(S)
		if not S then return nil end
		if loadstring then
			return loadstring("return " .. S)()
		end
		return load("return " .. S)()
	end
	for Line in Content:gmatch("[^\n]+") do
		local KeyRaw, DisRaw, NameRaw = Line:match("^(.+)%|([^|]*)%|(.*)$")
		if KeyRaw then
			local Key = Undquotify(KeyRaw)
			local Name = Undquotify(NameRaw)
			local Entry = {
				disabled = {},
				locked = {},       -- filled lazily by the GUI-lock watchdog
				name = Name or CrafterCore.CRAFTER_ITEM_NAME,
				window = nil,
				viewers = {},
				ready = false,
			}
			if DisRaw ~= "" then
				for S in DisRaw:gmatch("%d+") do
					Entry.disabled[tonumber(S)] = true
				end
			end
			CrafterCore.Crafters[Key] = Entry
		end
	end
	CrafterCore.DebugLog("loaded " .. CrafterCore.Count() .. " crafter(s) from disk")
end

function CrafterCore.Count()
	local N = 0
	for _ in pairs(CrafterCore.Crafters) do N = N + 1 end
	return N
end

-- After loading from disk the Entry lacks world/x/y/z (restored lazily once
-- the dropper block entity is seen again).  Resolve them from the key.
function CrafterCore.ResolveEntry(Key, World, X, Y, Z)
	local Entry = CrafterCore.Crafters[Key]
	if not Entry then return end
	Entry.world = World
	Entry.x = X
	Entry.y = Y
	Entry.z = Z
end