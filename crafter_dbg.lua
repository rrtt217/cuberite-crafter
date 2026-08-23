-- crafter_dbg.lua
-- Console-command management & diagnostic interface for the Crafter plugin.
-- These commands make the plugin fully testable without a GUI client:
--   crafter place  <x> <y> <z> [name]
--   crafter set    <x> <y> <z> <slot 0-8> <itemid> [count] [damage]   (itemid 0 = clear)
--   crafter setall <x> <y> <z> <itemid> [count] [damage]              (all 9 slots)
--   crafter toggle <x> <y> <z> <slot>
--   crafter pulse  <x> <y> <z>            (simulate a redstone rising edge)
--   crafter craft  <x> <y> <z>            (execute the craft cycle immediately)
--   crafter info   <x> <y> <z>
--   crafter list
--   crafter del    <x> <y> <z>
--   crafter save / reloaddb / test

local function ShowUsage()
	LOG("Crafter console commands:")
	LOG("  crafter place <x> <y> <z> [name]                 - place + register a crafter")
	LOG("  crafter give <player> [name]                        - give the crafter item to a player")
	LOG("  crafter set <x> <y> <z> <slot> <item> [count] [damage] - set grid slot (item 0 = clear)")
	LOG("  crafter setall <x> <y> <z> <item> [count] [damage]      - fill all 9 slots")
	LOG("  crafter toggle <x> <y> <z> <slot>            - toggle a slot disabled state")
	LOG("  crafter pulse <x> <y> <z>                    - simulate a redstone pulse")
	LOG("  crafter craft <x> <y> <z>                    - run the craft cycle right away")
	LOG("  crafter info <x> <y> <z> / list / del <x> <y> <z> / save / reloaddb")
end

-- Parses "<world>:<x>:<y>:<z>" or expects world as separate arg; the key format
-- helper used here expects numeric x/y/z.
local function FindWorld(WorldName)
	local World = cRoot:Get():GetWorld(WorldName)
	if not World then
		World = cRoot:Get():GetDefaultWorld()
	end
	return World
end

local function ItemSpec(ItemTok, CountTok, DamageTok)
	local Id = tonumber(ItemTok)
	local Count = tonumber(CountTok) or 1
	local Damage = tonumber(DamageTok) or 0
	if not Id then return nil end
	return { type = Id, count = Count, damage = Damage }
end

function HandleCrafterConsole(Split)
	local Cmd = Split[2] and Split[2]:lower() or ""
	if Cmd == "" or Cmd == "help" then
		ShowUsage()
		return true
	end

	if Cmd == "save" then
		CrafterCore.Save()
		LOG("Crafter registry saved.")
		return true
	end

	if Cmd == "reloaddb" then
		if CrafterCore.ReloadRecipes then
			CrafterCore.ReloadRecipes()
		end
		return true
	end

	if Cmd == "list" then
		local N = 0
		for Key, E in pairs(CrafterCore.Crafters) do
			N = N + 1
			local Dis = {}
			for S in pairs(E.disabled) do Dis[#Dis + 1] = S end
			table.sort(Dis)
			LOG(Key .. "  name=" .. tostring(E.name) .. "  disabled={" .. table.concat(Dis, ",") .. "}")
		end
		LOG("Crafter total: " .. N)
		return true
	end

	if Cmd == "give" then
		-- Give the crafter item to a named player (real-client placement testing)
		local PlayerName = Split[3]
		if not PlayerName then
			LOG("Usage: crafter give <playername> [custom name]")
			return true
		end
		local Found = cRoot:Get():FindAndDoWithPlayer(PlayerName, function(Player)
			local Name = Split[4] or CrafterCore.CRAFTER_ITEM_NAME
			local Item = CrafterCore.MakeCrafterItem(Name)
			local Added = Player:GetInventory():AddItem(Item)
			LOG("gave crafter item to " .. Player:GetName() .. " (added=" .. Added .. ")")
		end)
		if not Found then
			LOG("no such player: " .. PlayerName)
		end
		return true
	end

	if Cmd == "place" then
		local X, Y, Z = tonumber(Split[3]), tonumber(Split[4]), tonumber(Split[5])
		if not (X and Y and Z) then
			LOG("Usage: crafter place <x> <y> <z> [name]")
			return true
		end
		local World = FindWorld("")
		local Placed = false
		World:SetBlock(X, Y, Z, CrafterCore.E_BLOCK_DROPPER, 2)  -- facing north by default
		World:DoWithDropperAt(X, Y, Z, function(BE)
			CrafterCore.Register(BE, Split[6] or CrafterCore.CRAFTER_ITEM_NAME)
			Placed = true
			return false
		end)
		LOG(Placed and ("Crafter placed at " .. X .. "," .. Y .. "," .. Z)
			or "Failed to place crafter")
		return true
	end

	if Cmd == "set" or Cmd == "setall" then
		local X, Y, Z = tonumber(Split[3]), tonumber(Split[4]), tonumber(Split[5])
		if not (X and Y and Z) then
			LOG("Usage: crafter " .. Cmd .. " <x> <y> <z> <slot|-> <item> [count] [damage]")
			return true
		end
		local World = FindWorld()
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
			return false
		end)
		LOG("crafter grid updated at " .. X .. "," .. Y .. "," .. Z)
		return true
	end

	if Cmd == "toggle" then
		local X, Y, Z = tonumber(Split[3]), tonumber(Split[4]), tonumber(Split[5])
		local Slot = tonumber(Split[6])
		local World = FindWorld()
		local Key = CrafterCore.MakeKey(World:GetName(), X, Y, Z)
		local Entry = CrafterCore.Crafters[Key]
		if Entry and Slot then
			local NowDisabled = CrafterCore.ToggleDisabled(Entry, Slot)
			LOG("slot " .. Slot .. " now " .. (NowDisabled and "disabled" or "enabled"))
		else
			LOG("no crafter at those coords")
		end
		return true
	end

	if Cmd == "pulse" or Cmd == "craft" then
		local X, Y, Z = tonumber(Split[3]), tonumber(Split[4]), tonumber(Split[5])
		local World = FindWorld()
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
		LOG(Cmd .. " issued at " .. X .. "," .. Y .. "," .. Z)
		return true
	end

	if Cmd == "info" then
		local X, Y, Z = tonumber(Split[3]), tonumber(Split[4]), tonumber(Split[5])
		local World = FindWorld()
		local Key = CrafterCore.MakeKey(World:GetName(), X, Y, Z)
		local Entry = CrafterCore.Crafters[Key]
		if not Entry then
			LOG("no crafter registered at " .. Key)
			return true
		end
		local Valid, BT, BMeta = World:GetBlockTypeMeta(X, Y, Z)
		if not Valid then BT, BMeta = World:GetBlock(X, Y, Z), World:GetBlockMeta(X, Y, Z) end
		LOG("crafter at " .. Key .. "  block=" .. tostring(BT)
			.. " meta=" .. tostring(BMeta) .. " name=" .. tostring(Entry.name))
		local Dis = {}
		for S in pairs(Entry.disabled) do Dis[#Dis + 1] = S end
		table.sort(Dis)
		LOG("  disabled slots: {" .. table.concat(Dis, ",") .. "}")
		LOG("  pendingCraft=" .. tostring(Entry.pendingCraft))
		World:DoWithDropperAt(X, Y, Z, function(BE)
			local G = BE:GetContents()
			for i = 0, 8 do
				local It = G:GetSlot(i)
				if It and not It:IsEmpty() then
					LOG("  slot " .. i .. ": item " .. It.m_ItemType .. " x" .. It.m_ItemCount .. " dmg " .. (It.m_ItemDamage or 0))
				end
			end
			return false
		end)
		return true
	end

	if Cmd == "del" then
		local X, Y, Z = tonumber(Split[3]), tonumber(Split[4]), tonumber(Split[5])
		local World = FindWorld()
		local Key = CrafterCore.MakeKey(World:GetName(), X, Y, Z)
		CrafterCore.UnregisterAt(Key)
		LOG("crafter unregistered at " .. Key)
		return true
	end

	ShowUsage()
	return true
end
