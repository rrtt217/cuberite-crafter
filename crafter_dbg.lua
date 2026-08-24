-- crafter_dbg.lua
-- Management & diagnostic interface for the Crafter plugin.
-- Usable both from the server console and, with the "crafter.admin"
-- permission, in-game through /crafter <subcommand>.
-- Subcommands:
--   place    <x> <y> <z> [name]                         place + register a crafter
--   give     <player> [name]                            give the crafter item to a player
--   set      <x> <y> <z> <slot 0-8> <itemid> [count] [damage]   set one grid slot (0 = clear)
--   setall   <x> <y> <z> <itemid> [count] [damage]      fill all 9 slots
--   toggle   <x> <y> <z> <slot>                         toggle a slot's disabled state
--   pulse    <x> <y> <z>                                simulate a redstone rising edge
--   craft    <x> <y> <z>                                run the craft cycle immediately
--   info     <x> <y> <z>
--   list
--   del      <x> <y> <z>                                unregister a crafter
--   save / reloaddb

-- Sends a message to the invoking player (if any) and always to the console log.
local function Tell(Player, Msg, Kind)
	if Player then
		if Kind == "success" then
			Player:SendMessageSuccess(Msg)
		elseif Kind == "failure" then
			Player:SendMessageFailure(Msg)
		else
			Player:SendMessageInfo(Msg)
		end
	end
	LOG(Msg)
end

local function ShowUsage(Player)
	local Lines = {
		"Crafter commands (values in parentheses are optional):",
		"  /crafter [name]                                  - obtain a crafter item",
		"  /crafter place <x> <y> <z> [name]                - place + register a crafter",
		"  /crafter give <player> [name]                    - give the crafter item to a player",
		"  /crafter set <x> <y> <z> <slot> <item> [count] [damage] - set a grid slot (item 0 = clear)",
		"  /crafter setall <x> <y> <z> <item> [count] [damage]    - fill all 9 slots",
		"  /crafter toggle <x> <y> <z> <slot>               - toggle a slot disabled state",
		"  /crafter pulse <x> <y> <z>                       - simulate a redstone pulse",
		"  /crafter craft <x> <y> <z>                       - run the craft cycle right away",
		"  /crafter info <x> <y> <z> / list / del <x> <y> <z> / save / reloaddb",
		"Coordinates default to the caller's world (console: default world).",
		"Management subcommands require the crafter.admin permission.",
	}
	for _, L in ipairs(Lines) do Tell(Player, L, "info") end
end

-- Resolves a world: the calling player's world when run in-game, otherwise the
-- server's default world.  (Console commands historically targeted the default
-- world.)
local function FindWorld(Player)
	if Player then
		local W = Player:GetWorld()
		if W then return W end
	end
	return cRoot:Get():GetDefaultWorld()
end

local function ItemSpec(ItemTok, CountTok, DamageTok)
	local Id = tonumber(ItemTok)
	local Count = tonumber(CountTok) or 1
	local Damage = tonumber(DamageTok) or 0
	if not Id then return nil end
	return { type = Id, count = Count, damage = Damage }
end

function HandleCrafterConsole(Split, Player)
	local Cmd = Split[2] and Split[2]:lower() or ""
	if Cmd == "" or Cmd == "help" then
		ShowUsage(Player)
		return true
	end

	if Cmd == "save" then
		CrafterCore.Save()
		Tell(Player, "Crafter registry saved.", "success")
		return true
	end

	if Cmd == "reloaddb" then
		if CrafterCore.ReloadRecipes then
			CrafterCore.ReloadRecipes()
			Tell(Player, "Crafter recipe database reloaded.", "success")
		else
			Tell(Player, "Crafter recipe reload is not available.", "failure")
		end
		return true
	end

	if Cmd == "list" then
		local N = 0
		local Lines = {}
		for Key, E in pairs(CrafterCore.Crafters) do
			N = N + 1
			local Dis = {}
			for S in pairs(E.disabled) do Dis[#Dis + 1] = S end
			table.sort(Dis)
			Lines[#Lines + 1] = Key .. "  name=" .. tostring(E.name) .. "  disabled={" .. table.concat(Dis, ",") .. "}"
		end
		Lines[#Lines + 1] = "Crafter total: " .. N
		for _, L in ipairs(Lines) do Tell(Player, L, "info") end
		return true
	end

	if Cmd == "give" then
		-- Give the crafter item to a named player (real-client placement testing)
		local PlayerName = Split[3]
		if not PlayerName then
			Tell(Player, "Usage: crafter give <playername> [custom name]", "info")
			return true
		end
		local Found = cRoot:Get():FindAndDoWithPlayer(PlayerName, function(Pl)
			local Name = Split[4] or CrafterCore.CRAFTER_ITEM_NAME
			local Item = CrafterCore.MakeCrafterItem(Name)
			local Added = Pl:GetInventory():AddItem(Item)
			Tell(Player, "gave crafter item to " .. Pl:GetName() .. " (added=" .. Added .. ")", "success")
		end)
		if not Found then
			Tell(Player, "no such player: " .. PlayerName, "failure")
		end
		return true
	end

	if Cmd == "place" then
		local X, Y, Z = tonumber(Split[3]), tonumber(Split[4]), tonumber(Split[5])
		if not (X and Y and Z) then
			Tell(Player, "Usage: crafter place <x> <y> <z> [name]", "info")
			return true
		end
		local World = FindWorld(Player)
		local Placed = false
		World:SetBlock(X, Y, Z, CrafterCore.E_BLOCK_DROPPER, 2)  -- facing north by default
		World:DoWithDropperAt(X, Y, Z, function(BE)
			CrafterCore.Register(BE, Split[6] or CrafterCore.CRAFTER_ITEM_NAME)
			Placed = true
			return false
		end)
		Tell(Player,
			Placed and ("Crafter placed at " .. X .. "," .. Y .. "," .. Z)
				or "Failed to place crafter",
			Placed and "success" or "failure")
		return true
	end

	if Cmd == "set" or Cmd == "setall" then
		local X, Y, Z = tonumber(Split[3]), tonumber(Split[4]), tonumber(Split[5])
		if not (X and Y and Z) then
			Tell(Player, "Usage: crafter " .. Cmd .. " <x> <y> <z> <slot|-> <item> [count] [damage]", "info")
			return true
		end
		local World = FindWorld(Player)
		local SlotTok = Split[6]
		local Spec = ItemSpec(Split[7], Split[8], Split[9])
		World:DoWithDropperAt(X, Y, Z, function(BE)
			local G = BE:GetContents()
			if Cmd == "setall" then
				for i = 0, 8 do
					if Spec and Spec.type ~= 0 then
						G:SetSlot(i, cItem(Spec.type, Spec.count, Spec.damage))
					else
						G:SetSlot(i, cItem())
					end
				end
			else
				local Slot = tonumber(SlotTok)
				if Slot and Slot >= 0 and Slot <= 8 then
					if Spec and Spec.type ~= 0 then
						G:SetSlot(Slot, cItem(Spec.type, Spec.count, Spec.damage))
					else
						G:SetSlot(Slot, cItem())
					end
				end
			end
			-- Re-baseline disabled slots so the GUI lock accepts the admin's write
			local ListKey = CrafterCore.MakeKey(World:GetName(), X, Y, Z)
			local ListEntry = CrafterCore.Crafters[ListKey]
			if ListEntry then CrafterCore.SnapshotLocked(ListEntry, BE) end
			return false
		end)
		Tell(Player, "crafter grid updated at " .. X .. "," .. Y .. "," .. Z, "success")
		return true
	end

	if Cmd == "toggle" then
		local X, Y, Z = tonumber(Split[3]), tonumber(Split[4]), tonumber(Split[5])
		local Slot = tonumber(Split[6])
		local World = FindWorld(Player)
		local Key = CrafterCore.MakeKey(World:GetName(), X, Y, Z)
		local Entry = CrafterCore.Crafters[Key]
		if Entry and Slot then
			local NowDisabled = CrafterCore.ToggleDisabled(Entry, Slot)
			Tell(Player, "slot " .. Slot .. " now " .. (NowDisabled and "disabled" or "enabled"), "info")
		else
			Tell(Player, "no crafter at those coords", "failure")
		end
		return true
	end

	if Cmd == "pulse" or Cmd == "craft" then
		local X, Y, Z = tonumber(Split[3]), tonumber(Split[4]), tonumber(Split[5])
		local World = FindWorld(Player)
		World:DoWithDropperAt(X, Y, Z, function(BE)
			if Cmd == "pulse" then
				CrafterCore.OnRedstonePulse(BE)
			else
				local Key = CrafterCore.MakeKey(World:GetName(), X, Y, Z)
				local Entry = CrafterCore.Crafters[Key]
				if Entry then CrafterCore.DoCraft(Entry) end
			end
			return false
		end)
		Tell(Player, Cmd .. " issued at " .. X .. "," .. Y .. "," .. Z, "info")
		return true
	end

	if Cmd == "info" then
		local X, Y, Z = tonumber(Split[3]), tonumber(Split[4]), tonumber(Split[5])
		local World = FindWorld(Player)
		local Key = CrafterCore.MakeKey(World:GetName(), X, Y, Z)
		local Entry = CrafterCore.Crafters[Key]
		if not Entry then
			Tell(Player, "no crafter registered at " .. Key, "failure")
			return true
		end
		local Valid, BT, BMeta = World:GetBlockTypeMeta(X, Y, Z)
		if not Valid then BT, BMeta = World:GetBlock(X, Y, Z), World:GetBlockMeta(X, Y, Z) end
		Tell(Player, "crafter at " .. Key .. "  block=" .. tostring(BT)
			.. " meta=" .. tostring(BMeta) .. " name=" .. tostring(Entry.name), "info")
		local Dis = {}
		for S in pairs(Entry.disabled) do Dis[#Dis + 1] = S end
		table.sort(Dis)
		Tell(Player, "  disabled slots: {" .. table.concat(Dis, ",") .. "}", "info")
		Tell(Player, "  pendingCraft=" .. tostring(Entry.pendingCraft), "info")
		World:DoWithDropperAt(X, Y, Z, function(BE)
			local G = BE:GetContents()
			for i = 0, 8 do
				local It = G:GetSlot(i)
				if It and not It:IsEmpty() then
					local Desc = "  slot " .. i .. ": item " .. It.m_ItemType
						.. " x" .. It.m_ItemCount .. " dmg " .. (It.m_ItemDamage or 0)
					Tell(Player, Desc, "info")
				end
			end
			return false
		end)
		return true
	end

	if Cmd == "del" then
		local X, Y, Z = tonumber(Split[3]), tonumber(Split[4]), tonumber(Split[5])
		local World = FindWorld(Player)
		local Key = CrafterCore.MakeKey(World:GetName(), X, Y, Z)
		CrafterCore.UnregisterAt(Key)
		Tell(Player, "crafter unregistered at " .. Key, "success")
		return true
	end

	ShowUsage(Player)
	return true
end
