-- main.lua
-- Crafter plugin: a workbench-on-redstone block modelled on the vanilla
-- Crafter (合成器), built on top of Cuberite's native dropper block entity.

local Config = nil  -- cIniFile

-- ---------------------------------------------------------------------------
-- Startup
-- ---------------------------------------------------------------------------

function Initialize(Plugin)
	Plugin:SetName("Crafter")
	Plugin:SetVersion(1)

	-- Read plugin configuration
	-- NOTE: GetValueSetB is broken in this build (returns false for "true"), so
	-- booleans are parsed manually from GetValue.
	Config = cIniFile()
	Config:ReadFile(Plugin:GetLocalFolder() .. "/settings.ini")
	local function CfgBool(a_Value)
		local S = tostring(a_Value):lower()
		return (S == "1") or (S == "true") or (S == "yes")
	end
	CrafterCore.Cfg.CraftDelayTicks = Config:GetValueSetI("Crafter", "CraftDelayTicks", 4)
	CrafterCore.Cfg.EnableSounds    = CfgBool(Config:GetValue("Crafter", "EnableSounds", "true"))
	CrafterCore.Cfg.EnableParticles = CfgBool(Config:GetValue("Crafter", "EnableParticles", "true"))
	CrafterCore.Cfg.Debug           = CfgBool(Config:GetValue("Crafter", "Debug", "false"))
	CrafterCore.Cfg.LockWatchdogTicks = Config:GetValueSetI("Crafter", "LockWatchdogTicks", 5)

	-- Locate the server files (crafting.txt / items.ini) and register paths
	local Folder = Plugin:GetLocalFolder()
	local Sep = cFile:GetPathSeparator()
	local CandidateRoots = {
		Folder .. "/../..",
	}
	if cPluginManager.GetPluginsPath then
		local PPath = cPluginManager.GetPluginsPath(cPluginManager)
		if PPath then
			CandidateRoots[#CandidateRoots + 1] = PPath:match("^(.*)" .. Sep .. "[^" .. Sep .. "]+$") or PPath
		end
	end
	local ServerRoot = Folder
	for _, Root in ipairs(CandidateRoots) do
		if cFile:IsFile(Root .. Sep .. "crafting.txt") then
			ServerRoot = Root
			break
		end
	end

	CrafterCore.RecipesPath = ServerRoot .. Sep .. "crafting.txt"
	CrafterCore.ItemsPath   = ServerRoot .. Sep .. "items.ini"
	CrafterCore.SavePath    = Folder .. Sep .. "crafters.dat"

	-- Load the recipe database (all vanilla recipes, parsed in pure Lua)
	local DB, Skipped = CrafterRecipes.LoadDatabase(CrafterCore.RecipesPath, CrafterCore.ItemsPath)
	if not DB then
		LOG("[Crafter] ERROR: cannot load recipe files at " .. CrafterCore.RecipesPath)
		return false
	end
	CrafterCore.Cfg.Recipes = DB.recipes
	-- Inject the crafter's own recipe (iron + workbench + redstone + dropper) so a
	-- crafter block can craft another crafter.  Not present in the 1.12 crafting.txt.
	DB.recipes[#DB.recipes + 1] = CrafterRecipes.MakeCrafterRecipe()
	CrafterCore.RecipesNameMap = DB.itemNames
	local AliasCount = 0
	for _ in pairs(DB.itemNames) do AliasCount = AliasCount + 1 end
	LOG("[Crafter] Loaded " .. #DB.recipes .. " crafting recipes (" .. (Skipped or 0)
		.. " skipped, +1 injected crafter), " .. AliasCount .. " item aliases")

	CrafterCore.ReloadRecipes = function()
		local NewDB, NewSkipped = CrafterRecipes.LoadDatabase(CrafterCore.RecipesPath, CrafterCore.ItemsPath)
		if NewDB then
			CrafterCore.Cfg.Recipes = NewDB.recipes
			CrafterCore.RecipesNameMap = NewDB.itemNames
			LOG("[Crafter] reloaded " .. #NewDB.recipes .. " recipes (" .. (NewSkipped or 0) .. " skipped)")
		else
			LOG("[Crafter] reload failed")
		end
	end

	-- Restore the crafter registry
	CrafterCore.Load()
	CrafterCore.ResolveAllEntries()

	-- Hooks
	cPluginManager.AddHook(cPluginManager.HOOK_DROPSPENSE,           CrafterOnDropSpense)
	-- (no HOOK_PLAYER_USING_BLOCK: the native dropper window is used as the GUI)
	cPluginManager.AddHook(cPluginManager.HOOK_PLAYER_PLACING_BLOCK, CrafterOnPlayerPlacingBlock)
	cPluginManager.AddHook(cPluginManager.HOOK_PLAYER_PLACED_BLOCK,  CrafterOnPlayerPlacedBlock)
	cPluginManager.AddHook(cPluginManager.HOOK_PLAYER_BROKEN_BLOCK,  CrafterOnPlayerBrokenBlock)
	cPluginManager.AddHook(cPluginManager.HOOK_BLOCK_TO_PICKUPS,     CrafterOnBlockToPickups)
	cPluginManager.AddHook(cPluginManager.HOOK_HOPPER_PUSHING_ITEM,  CrafterOnHopperPushingItem)
	cPluginManager.AddHook(cPluginManager.HOOK_CRAFTING_NO_RECIPE,   CrafterOnCraftingNoRecipe)
	-- GUI slot-lock watchdog: rejects player insertions into disabled slots
	-- (the native dropper window has no per-slot lock and no click hook, so the
	-- lock is enforced by reverting insertions after the fact). Driven from
	-- HOOK_WORLD_TICK (world thread context, never blocks) rather than the
	-- server-level HOOK_TICK, which can deadlock with per-world hooks.
	if (CrafterCore.Cfg.LockWatchdogTicks or 0) > 0 then
		cPluginManager.AddHook(cPluginManager.HOOK_WORLD_TICK, CrafterOnWorldTick)
	end

	-- Player command: /crafter [name]  ->  give the crafter item
	--                 /crafter <subcommand> ...  ->  management (needs crafter.admin)
	-- The command is bound to the base crafter.get permission; the management
	-- subcommands additionally require crafter.admin, checked at runtime so both
	-- groups share one binding.
	cPluginManager.BindCommand("/crafter", "crafter.get", HandleCrafterCommand,
		" ~ 获取合成器；管理员可用子命令管理（place/set/toggle/pulse/craft/info/list/del）")

	-- Console commands (management & automated testing)
	cPluginManager.BindConsoleCommand("crafter", HandleCrafterConsole,
		" ~ place/set/setall/toggle/pulse/craft/info/list/del/save/reloaddb")

	LOG("[Crafter] Initialised (version " .. Plugin:GetVersion() .. ")")
	return true
end

-- After a restart, entries loaded from disk lack world/x/y/z; resolve them
-- from the registry key (world:x:y:z).
function CrafterCore.ResolveAllEntries()
	for Key, Entry in pairs(CrafterCore.Crafters) do
		local WorldName, X, Y, Z = Key:match("^(.-):(%d+):(%d+):(%d+)$")
		if WorldName then
			local World = cRoot:Get():GetWorld(WorldName)
			if World then
				Entry.world = World
				Entry.x = tonumber(X)
				Entry.y = tonumber(Y)
				Entry.z = tonumber(Z)
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

-- A dropper redstone pulse -> simulate the crafter's rising edge.
function CrafterOnDropSpense(World, DropSpenser, SlotNum)
	if CrafterCore.Cfg.Debug then
		local okW, W = pcall(function() return DropSpenser:GetWorld() end)
		local okN, N = pcall(function() return (okW and W and W:GetName()) or "nil" end)
		local K = CrafterCore.KeyFromEntity(DropSpenser)
		local InReg = K ~= nil and CrafterCore.Crafters[K] ~= nil
		LOG("[Crafter] DS-hook key=" .. tostring(K) .. " in-registry=" .. tostring(InReg)
			.. " GetWorld=" .. tostring(okW) .. ":" .. tostring(W) .. " name=" .. tostring(okN) .. ":" .. tostring(N))
	end
	if not CrafterCore.IsCrafterEntity(DropSpenser) then return false end
	CrafterCore.OnRedstonePulse(DropSpenser)
	return true
end

-- NOTE: no custom GUI window. The crafter uses the native dropper window
-- (a 3x3 grid) so inventory stays synchronised and native window-click handling
-- cannot crash the server (this build's cLuaWindow drag/paint path is broken).
-- Disabled slots are enforced in the plugin logic (crafting + hopper rules) and
-- toggled with the `crafter toggle` console command.

-- Remember which dropper placement is a crafter (marked item)
function CrafterOnPlayerPlacingBlock(Player, BlockX, BlockY, BlockZ, BlockType, BlockMeta)
	if BlockType ~= E_BLOCK_DROPPER then return false end
	local Item = Player:GetEquippedItem()
	if CrafterCore.IsCrafterItem(Item) then
		CrafterCore.PendingPlacement = {
			world = Player:GetWorld():GetName(),
			x = BlockX, y = BlockY, z = BlockZ,
			name = Item.m_CustomName or CrafterCore.CRAFTER_ITEM_NAME,
		}
		CrafterCore.DebugLog("crafter item being placed at " .. BlockX .. "," .. BlockY .. "," .. BlockZ)
	end
	return false
end

function CrafterOnPlayerPlacedBlock(Player, BlockX, BlockY, BlockZ, BlockType, BlockMeta)
	local Pending = CrafterCore.PendingPlacement
	CrafterCore.PendingPlacement = nil
	if not Pending then return false end
	if BlockType ~= E_BLOCK_DROPPER then return false end
	local W = Player:GetWorld()
	if W:GetName() ~= Pending.world then return false end
	if not ((Pending.x == BlockX) and (Pending.y == BlockY) and (Pending.z == BlockZ)) then return false end
	W:DoWithDropperAt(BlockX, BlockY, BlockZ, function(BE)
		CrafterCore.Register(BE, Pending.name or CrafterCore.CRAFTER_ITEM_NAME)
		return false
	end)
	return false
end

-- Breaking a crafter drops the crafter item + its grid contents
function CrafterOnBlockToPickups(World, Digger, BlockX, BlockY, BlockZ, BlockType, BlockMeta, Pickups)
	if BlockType ~= E_BLOCK_DROPPER then return false end
	local Key = CrafterCore.MakeKey(World:GetName(), BlockX, BlockY, BlockZ)
	local Entry = CrafterCore.Crafters[Key]
	if not Entry then return false end
	-- We must NOT clear the pickups list: the native dropper already drained
	-- its grid into Pickups before this hook (and cleared the entity), so keep
	-- those and just swap the plain dropper item for the crafter item. If the
	-- grid is somehow still populated (creative dig, other builds), add it too.
	local Found = 0
	World:DoWithDropperAt(BlockX, BlockY, BlockZ, function(BE)
		local G = BE:GetContents()
		if G then
			for i = 0, 8 do
				local It = G:GetSlot(i)
				if It and not It:IsEmpty() then
					Found = Found + 1
					Pickups:Add(It)
				end
			end
		end
		return false
	end)
	local Replaced = false
	for i = 0, Pickups:Size() - 1 do
		local It = Pickups:Get(i)
		if It and (not It:IsEmpty()) and (It.m_ItemType == CrafterCore.CRAFTER_ITEM_ID) then
			Pickups:Set(i, CrafterCore.MakeCrafterItem(Entry.name))
			Replaced = true
			break
		end
	end
	if not Replaced then
		Pickups:Add(CrafterCore.MakeCrafterItem(Entry.name))
	end
	CrafterCore.DebugLog("block-to-pickups: gridFound=" .. Found .. " pickups=" .. Pickups:Size())
	return true
end

function CrafterOnPlayerBrokenBlock(Player, BlockX, BlockY, BlockZ, BlockFace, BlockType, BlockMeta)
	if BlockType ~= E_BLOCK_DROPPER then return false end
	local W = Player:GetWorld()
	local Key = CrafterCore.MakeKey(W:GetName(), BlockX, BlockY, BlockZ)
	if CrafterCore.Crafters[Key] then
		CrafterCore.UnregisterAt(Key)
	end
	return false
end

-- Crafter-specific hopper insertion rules
function CrafterOnHopperPushingItem(World, Hopper, SrcSlot, DstBlockEntity, DstSlot)
	return CrafterCore.OnHopperPushingItem(World, Hopper, SrcSlot, DstBlockEntity, DstSlot)
end

-- Throttled scan for the GUI slot-lock watchdog. Runs from HOOK_WORLD_TICK
-- (called per world every tick, in the world tick thread so block-entity work
-- never blocks). This build passes no useful counter, so we count calls
-- ourselves; LockWatchdogTicks callbacks (default 5) elapse between scans.
-- Scans are restricted to the ticking world. Returns false to let other
-- plugins see the tick too.
local CrafterTickCount = 0
function CrafterOnWorldTick(World)
	CrafterTickCount = CrafterTickCount + 1
	if (CrafterTickCount % CrafterCore.Cfg.LockWatchdogTicks) ~= 0 then return false end
	CrafterCore.LockWatchdog(World)
	return false
end

-- Provide the crafter's own crafting recipe in a crafting table:
--   3x3 vanilla pattern:  铁锭 铁锭 铁锭 / 铁锭 工作台 铁锭 / 红石 投掷器 红石
--   (265=iron ingot, 58=workbench, 331=redstone, 158=dropper)
local CRAFTER_PATTERN = {
	{ 265, 265, 265 },
	{ 265,  58, 265 },
	{ 331, 158, 331 },
}

function CrafterOnCraftingNoRecipe(Player, Grid, Recipe)
	local W, H = Grid:GetWidth(), Grid:GetHeight()
	if W < 3 or H < 3 then return false end
	for Y = 0, 2 do
		for X = 0, 2 do
			local Expect = CRAFTER_PATTERN[Y + 1][X + 1]
			local It = Grid:GetItem(X, Y)
			if Expect == 0 then
				if It and It.m_ItemType ~= -1 then return false end
			else
				if not It then return false end
				if It.m_ItemType ~= Expect then return false end
			end
		end
	end
	-- Register the ingredients on the Recipe object.  A plugin recipe that only
	-- sets the result yields the result but Cuberite never consumes the grid
	-- (ConsumeIngredients works from the recipe's ingredient list).
	for Y = 0, 2 do
		for X = 0, 2 do
			local Expect = CRAFTER_PATTERN[Y + 1][X + 1]
			if Expect ~= 0 then
				Recipe:SetIngredient(X, Y, Expect, 1, 0)
			end
		end
	end
	Recipe:SetResult(CrafterCore.MakeCrafterItem())
	return true
end

-- ---------------------------------------------------------------------------
-- Player command
-- ---------------------------------------------------------------------------

-- Management subcommands that require the crafter.admin permission.
-- Any other first argument is treated as a custom crafter-item name.
local CRAFTER_ADMIN_SUBCOMMANDS = {
	help = true, place = true, give = true, set = true, setall = true,
	toggle = true, pulse = true, craft = true, info = true, list = true,
	del = true, save = true, reloaddb = true,
}

function HandleCrafterCommand(Split, Player)
	local Sub = Split[2] and Split[2]:lower() or ""
	-- Player-facing slot locking: /crafter lock|unlock <slot> [x y z].
	-- Without coordinates the crafter the player is standing next to is used,
	-- so locking needs only the crafter.lock permission (no admin rights).
	if (Sub == "lock") or (Sub == "unlock") then
		if not Player:HasPermission("crafter.lock") then
			Player:SendMessageFailure("你没有权限使用 /crafter " .. Sub
				.. "（需要权限 crafter.lock）")
			return true
		end
		return HandleCrafterLock(Split, Player, Sub == "lock")
	end
	if CRAFTER_ADMIN_SUBCOMMANDS[Sub] then
		if not Player:HasPermission("crafter.admin") then
			Player:SendMessageFailure("你没有权限使用 /crafter " .. Sub
				.. "（需要权限 crafter.admin）")
			return true
		end
		return HandleCrafterConsole(Split, Player)
	end
	local Name = Split[2] and table.concat(Split, " ", 2) or CrafterCore.CRAFTER_ITEM_NAME
	local Item = CrafterCore.MakeCrafterItem(Name)
	if Item:IsEmpty() then
		Player:SendMessageFailure("无法制作合成器（内部错误）")
		return true
	end
	local Added = Player:GetInventory():AddItem(Item)
	if Added > 0 then
		local Display = Name
		if Name ~= CrafterCore.CRAFTER_ITEM_NAME then
			Display = "“" .. Name .. "”"
		end
		Player:SendMessageSuccess("已获得合成器" .. Display .. "，右键放置即可使用")
	else
		Player:SendMessageFailure("背包已满，无法获得合成器")
	end
	return true
end

-- /crafter lock|unlock <slot 0-8> [x y z]: toggles the disabled (locked) state
-- of a grid slot on a crafter. The target is the crafter the player is standing
-- next to (nearest within 8 blocks), or the coordinates passed explicitly.
function HandleCrafterLock(Split, Player, WantLocked)
	local Slot = tonumber(Split[3])
	if not Slot then
		Player:SendMessageFailure("用法: /crafter " .. (WantLocked and "lock" or "unlock")
			.. " <槽位0-8> [x y z]")
		return true
	end
	if (Slot < 0) or (Slot > 8) or (Slot ~= math.floor(Slot)) then
		Player:SendMessageFailure("槽位必须是 0-8 的整数")
		return true
	end
	local X, Y, Z = nil, nil, nil
	if Split[4] then
		X, Y, Z = tonumber(Split[4]), tonumber(Split[5]), tonumber(Split[6])
		if not (X and Y and Z) then
			Player:SendMessageFailure("坐标参数不完整（x y z）")
			return true
		end
	end
	local Entry, Key = CrafterCore.FindCrafterNear(Player, X, Y, Z)
	if not Entry then
		Player:SendMessageFailure("附近没有合成器：请站到合成器旁边，或指定坐标 x y z")
		return true
	end
	local NowLocked = Entry.disabled[Slot] ~= nil
	if WantLocked ~= NowLocked then
		CrafterCore.ToggleDisabled(Entry, Slot)
	end
	if WantLocked then
		Player:SendMessageSuccess("已锁定槽位 " .. Slot .. "（" .. Key .. "）")
	else
		Player:SendMessageSuccess("已解锁槽位 " .. Slot .. "（" .. Key .. "）")
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Shutdown
-- ---------------------------------------------------------------------------

function OnDisable()
	CrafterCore.Save()
	LOG("[Crafter] Saved registry and shut down")
end
