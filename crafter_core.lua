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
--   * a workbench-style GUI with a read-only result slot,
--   * redstone rising-edge -> delayed craft -> eject (into container or world),
--   * crafter-specific hopper insertion rules (disabled slots + fill order).

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
		-- Consume ingredients and write the remainder back into the grid.
		CrafterRecipes.ConsumeGrid(Grid, Binding)
		CrafterCore.WriteGrid(BE, Grid)
		CrafterCore.DebugLog("crafted " .. R.result.type .. "^" .. R.result.damage .. " x" .. R.result.count .. " at " .. Key)
		-- Output: into the container in front if it accepts, else as pickups.
		-- The crafter's own recipe must eject the marked crafter item (name + lore)
		-- so that placing the result registers a new crafter.
		local OutItem
		if R.isCrafterRecipe then
			OutItem = CrafterCore.MakeCrafterItem()
		else
			OutItem = cItem(R.result.type, R.result.count, R.result.damage)
		end
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

-- Ejects an item out of the front of the crafter: into a container in front
-- if one accepts it (like the dropper), otherwise as an item pickup.
function CrafterCore.Eject(W, BE, Item)
	local FX, FY, FZ = CrafterCore.GetFrontCoords(BE)
	local Items = cItems()
	Items:Add(Item)
	-- Deposit into the container in front (if any). AddItems() mutates Items in
	-- place to hold the leftovers and returns the number of items added, so the
	-- container check must look for a grid method via pcall (some block-entity
	-- Lua bindings in this build lack GetContents on the shared base class).
	W:DoWithBlockEntityAt(FX, FY, FZ, function(Dst)
		if Dst then
			local ok, G = pcall(function() return Dst:GetContents() end)
			if ok and G then
				pcall(function() G:AddItems(Items, true) end)
			end
		end
		return false
	end)
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

function CrafterCore.OnHopperPushingItem(World, Hopper, SrcSlot, DstBlockEntity, DstSlot)
	if not CrafterCore.IsCrafterEntity(DstBlockEntity) then return false end
	local Entry = CrafterCore.EnsureResolved(DstBlockEntity)
	local HopperGrid = Hopper:GetContents()
	local SrcItem = HopperGrid and HopperGrid:GetSlot(SrcSlot)
	if not SrcItem or SrcItem:IsEmpty() then return true end
	-- Cache the item type eagerly: this build returns -1 for the *first* field
	-- access on a hopper-sourced cItem, then the real value on later accesses
	-- (a binding quirk that used to surface in debug logs).
	local SrcType = SrcItem.m_ItemType

	local CrafterGrid = DstBlockEntity:GetContents()
	local Target = CrafterCore.FindInsertTarget(Entry, CrafterGrid, SrcItem)
	if not Target then
		-- No legal slot: treat the crafter as full, veto the native push.
		return true
	end

	local MaxStack = SrcItem:GetMaxStackSize()
	local DstItem = CrafterGrid:GetSlot(Target)
	local MoveCount
	if DstItem:IsEmpty() then
		MoveCount = math.min(SrcItem.m_ItemCount, MaxStack)
	else
		MoveCount = math.min(SrcItem.m_ItemCount, math.max(0, MaxStack - DstItem.m_ItemCount))
	end
	if MoveCount <= 0 then return true end

	if DstItem:IsEmpty() then
		CrafterGrid:SetSlot(Target, cItem(SrcType, MoveCount, SrcItem.m_ItemDamage or 0))
	else
		DstItem.m_ItemCount = DstItem.m_ItemCount + MoveCount
		CrafterGrid:SetSlot(Target, DstItem)
	end

	if SrcItem.m_ItemCount <= MoveCount then
		HopperGrid:SetSlot(SrcSlot, cItem())
	else
		SrcItem.m_ItemCount = SrcItem.m_ItemCount - MoveCount
		HopperGrid:SetSlot(SrcSlot, SrcItem)
	end

	CrafterCore.DebugLog("hopper pushed x" .. MoveCount .. " of item " .. SrcType .. " into slot " .. Target)
	return true
end

-- ---------------------------------------------------------------------------
-- Disabled slots
-- ---------------------------------------------------------------------------

function CrafterCore.ToggleDisabled(Entry, Slot)
	if Entry.disabled[Slot] then
		Entry.disabled[Slot] = nil
	else
		Entry.disabled[Slot] = true
	end
	CrafterCore.Save()
	return Entry.disabled[Slot] ~= nil
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
