-- crafter_recipes.lua
-- Pure-Lua recipe database for the Crafter plugin.
--
-- It parses Cuberite's server-side crafting recipe file (crafting.txt) and the
-- item alias file (items.ini), then matches a 3x3 crafter grid against the
-- recipes. It deliberately has NO dependency on the Cuberite runtime API so it
-- can be unit-tested standalone with plain `lua` / `luajit`.
--
-- Recipe / item format (matching Cuberite's own docs in crafting.txt):
--   <Line>       = [<name>:] <Result> = <Ingredient> | <Ingredient> | ...
--   <Ingredient> = <ItemId>[, <X>:<Y>|*|X:*|*:Y ...]
--   <ItemId>     = <ItemName>[^<Damage>]   (damage -1 == "any damage")
--   <Result>     = <ItemName>[^<Damage>][, <Count>]
--
-- Plain-item representation used throughout: { type = <int>, damage = <int>,
-- count = <int> }. A crafter grid is an array of exactly 9 such tables
-- (row-major, index 0 = top-left); nil / empty table means an empty slot.

CrafterRecipes = {}

------------------------------------------------------------------------------
-- File reading (injectable, so the module stays standalone-testable)
------------------------------------------------------------------------------

local FileReader = io and io.open or nil

function CrafterRecipes.SetFileReader(a_Fn)
	FileReader = a_Fn
end

local function ReadFile(a_Path)
	if FileReader then
		local F = FileReader(a_Path, "rb")
		if not F then return nil end
		local Content = F:read("*a")
		F:close()
		return Content
	end
	-- Fallback: cFile (Cuberite runtime)
	if cFile and cFile.ReadWholeFile then
		local C = cFile.ReadWholeFile(cFile, a_Path)
		if C == "" then return nil end  -- cFile returns "" on failure
		return C
	end
	return nil
end

------------------------------------------------------------------------------
-- items.ini parsing
------------------------------------------------------------------------------

local function Trim(a_S)
	return (a_S:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Returns a map: lowercased item name -> { id = number, damage = number }.
-- First occurrence wins for duplicates (mirrors Cuberite closely enough), with
-- one caveat: some names are first defined as *block* ids that can never be
-- placed in a crafting grid (e.g. items.ini has both "redstonedust=55" [wire
-- block] and "redstonedust=331" [dust item]). crafting.txt uses those names as
-- ITEMS, so the known block-id shadowings are corrected afterwards (1.12 ids).
local ALIAS_CORRECTIONS = {
	["redstonedust"]  = { id = 331, damage = 0 },
	["cake"]          = { id = 354, damage = 0 },
	["skeletonhead"]  = { id = 397, damage = 0 },
	["creeperhead"]   = { id = 397, damage = 4 },
	["creaperhead"]   = { id = 397, damage = 4 }, -- legacy spelling
	["zombiehead"]    = { id = 397, damage = 2 },
	["witherhead"]    = { id = 397, damage = 1 },
	["playerhead"]    = { id = 397, damage = 3 },
	["stevehead"]     = { id = 397, damage = 3 },
}

function CrafterRecipes.LoadItemNames(a_Content)
	local Res = {}
	for Line in a_Content:gmatch("[^\r\n]+") do
		local L = Trim(Line)
		if (L ~= "") and (L:sub(1, 1) ~= "#") and L:find("=", 1, true) then
			local K, V = L:match("^([^=]+)=(.*)$")
			K = Trim(K):lower()
			V = Trim(V)
			local Id, Dmg = V:match("^(%d+):(%d+)$")
			if Id then
				if not Res[K] then
					Res[K] = { id = tonumber(Id), damage = tonumber(Dmg) }
				end
			else
				local Id2 = tonumber(V)
				if Id2 and not Res[K] then
					Res[K] = { id = Id2, damage = 0 }
				end
			end
		end
	end
	for K, V in pairs(ALIAS_CORRECTIONS) do
		Res[K] = V
	end
	return Res
end

------------------------------------------------------------------------------
-- crafting.txt parsing
------------------------------------------------------------------------------

-- Resolves an item alias with normalisation: tries the exact (lowercased)
-- name first, then the name with all whitespace removed.  The latter handles
-- item names written with spaces in crafting.txt (e.g. "Cooked Rabbit" ->
-- items.ini key "cookedrabbit").
local function ResolveAlias(a_Name, a_ItemNames)
	local Low = a_Name:lower()
	local E = a_ItemNames[Low]
	if E then return E end
	local Stripped = (a_Name:gsub("%s", "")):lower()
	if Stripped ~= Low then
		return a_ItemNames[Stripped]
	end
	return nil
end

-- Parses an item token ("OakLog" or "Wool^3" or "Planks^-1" or "Dye ^-1" or
-- "Cooked Rabbit") into a requirement table: { type, damage, anyDamage }.
-- crafting.txt allows optional whitespace, including around the "^" damage
-- marker and inside item names.
local function ParseItemRequirement(a_Token, a_ItemNames)
	local Token = Trim(a_Token)
	if Token == "" then return nil end
	-- Form: <Name> [^ <Damage>]  -- whitespace around / inside Name is allowed.
	local Name, Dmg = Token:match("^(.+)%s*%^%s*([%-]?%d+)$")
	if Name then
		Name = Trim(Name)
		if (Name ~= "") and Name:match("^[%a%d_ ]+$") then
			local Entry = ResolveAlias(Name, a_ItemNames)
			if Entry then
				return {
					type = Entry.id,
					damage = tonumber(Dmg),
					anyDamage = (tonumber(Dmg) == -1),
				}
			end
		end
		return nil
	end
	if Token:match("^[%a%d_ ]+$") then
		local Entry = ResolveAlias(Token, a_ItemNames)
		if Entry then
			return { type = Entry.id, damage = Entry.damage, anyDamage = false }
		end
	end
	return nil
end

-- Parses a slot token: "X:Y", "X:*", "*:Y" or "*".  Returns {x=, y=} where a
-- nil component stands for "any".
local function ParseSlotToken(a_Token)
	local T = Trim(a_Token)
	if T == "*" then
		return { x = nil, y = nil }
	end
	local X, Y = T:match("^(%d+):(%d+)$")
	if X then
		return { x = tonumber(X), y = tonumber(Y) }
	end
	local Y2 = T:match("^%*:(%d+)$")
	if Y2 then
		return { x = nil, y = tonumber(Y2) }
	end
	local X2 = T:match("^(%d+):%*$")
	if X2 then
		return { x = tonumber(X2), y = nil }
	end
	return nil
end

-- Parses one recipe line (without the trailing '#comment').  Returns a recipe
-- table or nil when the line doesn't parse.  Unresolvable item names cause the
-- recipe to be dropped (the loader counts these).
local function ParseRecipeLine(a_Line, a_ItemNames)
	local EqPos = a_Line:find("=", 1, true)
	if not EqPos then return nil end
	local ResultSide = Trim(a_Line:sub(1, EqPos - 1))
	local IngSide = a_Line:sub(EqPos + 1)

	-- Optional recipe-name prefix "name: " before the result item.
	local Name, Rs = nil, ResultSide
	local ColonPos = ResultSide:find(":", 1, true)
	if ColonPos then
		local After = Trim(ResultSide:sub(ColonPos + 1))
		if After:match("^[%a%d_]") then
			Name = Trim(ResultSide:sub(1, ColonPos - 1))
			Rs = After
		end
	end

	-- Result: ItemName[^Damage][, Count]
	local ItemTok, CountTok = Rs:match("^([^,]+),%s*(%d+)$")
	if not ItemTok then
		ItemTok = Rs:match("^([^,]+)$")
		if ItemTok then ItemTok = Trim(ItemTok) end
	end
	if not ItemTok then return nil end
	local ResultReq = ParseItemRequirement(ItemTok, a_ItemNames)
	if not ResultReq then return nil end
	local Result = {
		type = ResultReq.type,
		damage = ResultReq.damage,
		count = tonumber(CountTok) or 1,
	}

	-- Ingredients
	local Ingredients = {}
	for Part in IngSide:gmatch("[^|]+") do
		local P = Trim(Part)
		if P ~= "" then
			local First, Rest = P:match("^([^,]+),(.*)$")
			if First then
				local Item = ParseItemRequirement(Trim(First), a_ItemNames)
				if Item then
					local Slots = {}
					if Rest then
						for SC in (Trim(Rest)):gmatch("[^,]+") do
							local Slot = ParseSlotToken(SC)
							if Slot then Slots[#Slots + 1] = Slot end
						end
					end
					if #Slots > 0 then
						Ingredients[#Ingredients + 1] = { item = Item, slots = Slots }
					end
				end
			end
		end
	end
	if #Ingredients == 0 then return nil end

	-- Compute the pattern bounding box over fixed slots (needed for the
	-- offset search).  A recipe without any fixed slot is treated as 1x1.
	local MinX, MaxX, MinY, MaxY = 3, 1, 3, 1
	for _, Ing in ipairs(Ingredients) do
		for _, Slot in ipairs(Ing.slots) do
			if Slot.x and Slot.y then
				if Slot.x < MinX then MinX = Slot.x end
				if Slot.x > MaxX then MaxX = Slot.x end
				if Slot.y < MinY then MinY = Slot.y end
				if Slot.y > MaxY then MaxY = Slot.y end
			end
		end
	end
	local W, H
	if MaxX < MinX then
		W, H = 1, 1
	else
		W, H = MaxX - MinX + 1, MaxY - MinY + 1
	end

	-- Normalize all slot coords to be relative to the pattern's bounding box,
	-- so that the offset search can shift the whole pattern within the 3x3.
	for _, Ing in ipairs(Ingredients) do
		for _, Slot in ipairs(Ing.slots) do
			if Slot.x and Slot.y then
				Slot.x = Slot.x - MinX
				Slot.y = Slot.y - MinY
			elseif Slot.x then
				Slot.x = Slot.x - MinX
			elseif Slot.y then
				Slot.y = Slot.y - MinY
			end
		end
	end

	return {
		name = Name,
		result = Result,
		ingredients = Ingredients,
		width = W,
		height = H,
	}
end

-- Parses the whole crafting.txt content.  Returns the recipe list.
-- Recipes with unresolvable items are skipped; the count is reported via the
-- second return value for diagnostics.
function CrafterRecipes.ParseContent(a_Content, a_ItemNames)
	local Recipes = {}
	local Skipped = 0
	for Line in a_Content:gmatch("[^\r\n]+") do
		local L = Trim(Line)
		if (L ~= "") and (L:sub(1, 1) ~= "#") then
			local NoComment = Trim(L:gsub("#.*$", ""))
			if NoComment ~= "" then
				local R = ParseRecipeLine(NoComment, a_ItemNames)
				if R then
					Recipes[#Recipes + 1] = R
				else
					Skipped = Skipped + 1
				end
			end
		end
	end
	return Recipes, Skipped
end

------------------------------------------------------------------------------
-- Matching
------------------------------------------------------------------------------

local function CellMatches(a_Item, a_Req)
	if not a_Item then return false end
	if (a_Item.count or 0) <= 0 then return false end
	if a_Item.type ~= a_Req.type then return false end
	if not a_Req.anyDamage and (a_Item.damage or 0) ~= a_Req.damage then
		return false
	end
	return true
end

-- Tries to match one recipe against the 3x3 a_Grid at pattern offset (ox, oy).
-- Returns the binding (per ingredient: list of { cell, amount }) or nil.
local function MatchAtOffset(a_Recipe, a_Grid, a_Ox, a_Oy)
	local Used = {}
	local Binding = {}

	-- Phase 1: fixed slots (deterministic).
	for I, Ing in ipairs(a_Recipe.ingredients) do
		local PerIng = {}
		local CellAmt = {}
		local Valid = true
		for _, Slot in ipairs(Ing.slots) do
			if Slot.x and Slot.y then
				local Cell = (Slot.x + a_Ox) + (Slot.y + a_Oy) * 3
				if (Cell < 0) or (Cell > 8) then
					Valid = false
					break
				end
				CellAmt[Cell] = (CellAmt[Cell] or 0) + 1
			end
		end
		if not Valid then return nil end
		for Cell, Amt in pairs(CellAmt) do
			if Used[Cell] then return nil end
			if not CellMatches(a_Grid[Cell], Ing.item) then return nil end
			if a_Grid[Cell].count < Amt then return nil end
			Used[Cell] = true
			PerIng[#PerIng + 1] = { cell = Cell, amount = Amt }
		end
		Binding[I] = PerIng
	end

	-- Phase 2: star slots (backtracking).
	local StarJobs = {}
	for I, Ing in ipairs(a_Recipe.ingredients) do
		for _, Slot in ipairs(Ing.slots) do
			if not (Slot.x and Slot.y) then
				StarJobs[#StarJobs + 1] = {
					ingIdx = I,
					slot = Slot,
					item = Ing.item,
				}
			end
		end
	end

	local DfsOk = false
	local function Dfs(a_JobIdx)
		if a_JobIdx > #StarJobs then
			DfsOk = true
			return true
		end
		local Job = StarJobs[a_JobIdx]
		local Row = Job.slot.y and (Job.slot.y + a_Oy) or nil
		local Col = Job.slot.x and (Job.slot.x + a_Ox) or nil
		for C = 0, 8 do
			local Cx, Cy = C % 3, math.floor(C / 3)
			if ((Row == nil) or (Cy == Row)) and ((Col == nil) or (Cx == Col)) then
				if (not Used[C]) and CellMatches(a_Grid[C], Job.item) then
					Used[C] = true
					local PB = Binding[Job.ingIdx]
					PB[#PB + 1] = { cell = C, amount = 1 }
					if Dfs(a_JobIdx + 1) then return true end
					PB[#PB] = nil
					Used[C] = nil
				end
			end
		end
		return false
	end

	if (Dfs(1) == false) or (not DfsOk) then return nil end

	-- Phase 3: no extra items outside the consumed cells.
	for C = 0, 8 do
		if not Used[C] then
			if a_Grid[C] and ((a_Grid[C].count or 0) > 0) then return nil end
		end
	end

	return Binding
end

-- Finds the first recipe that matches the 3x3 a_Grid.
-- Returns the recipe and its binding, or nil.
function CrafterRecipes.FindRecipe(a_Recipes, a_Grid)
	for _, R in ipairs(a_Recipes) do
		local MaxOx = 3 - R.width
		local MaxOy = 3 - R.height
		for Oy = 0, MaxOy do
			for Ox = 0, MaxOx do
				local Binding = MatchAtOffset(R, a_Grid, Ox, Oy)
				if Binding then return R, Binding end
			end
		end
	end
	return nil
end

-- Consumes the items described by a binding from the grid (mutates it).
-- The grid item tables are the very same tables the caller supplied.
function CrafterRecipes.ConsumeGrid(a_Grid, a_Binding)
	for _, PerIng in ipairs(a_Binding) do
		for _, CI in ipairs(PerIng) do
			local It = a_Grid[CI.cell]
			if It then
				It.count = It.count - CI.amount
				if It.count <= 0 then a_Grid[CI.cell] = nil end
			end
		end
	end
end

------------------------------------------------------------------------------
-- The crafter's own recipe (vanilla 1.21 3x3 pattern), so a crafter can craft
-- another crafter.  crafting.txt has no such recipe (Crafter is a 1.21 item),
-- so the plugin injects it into the loaded database.  Cells are already 0-based
-- grid indices (the pattern spans the full 3x3, no bounding-box normalisation).
--   iron        iron        iron
--   iron        workbench   iron
--   redstone    dropper     redstone
function CrafterRecipes.MakeCrafterRecipe(a_ResultType, a_ResultDamage)
	return {
		name = "crafter",
		isCrafterRecipe = true,
		result = {
			type = a_ResultType or 158,
			damage = a_ResultDamage or 0,
			count = 1,
		},
		ingredients = {
			{ item = { type = 265, damage = 0, anyDamage = false }, slots = { {x=0,y=0},{x=1,y=0},{x=2,y=0} } },
			{ item = { type = 265, damage = 0, anyDamage = false }, slots = { {x=0,y=1},{x=2,y=1} } },
			{ item = { type = 58,  damage = 0, anyDamage = false }, slots = { {x=1,y=1} } },
			{ item = { type = 331, damage = 0, anyDamage = false }, slots = { {x=0,y=2},{x=2,y=2} } },
			{ item = { type = 158, damage = 0, anyDamage = false }, slots = { {x=1,y=2} } },
		},
		width = 3,
		height = 3,
	}
end

-- Convenience: load both files and return a ready-to-use recipe database.
------------------------------------------------------------------------------

function CrafterRecipes.LoadDatabase(a_CraftingPath, a_ItemsPath, a_FileReader)
	if a_FileReader then
		CrafterRecipes.SetFileReader(a_FileReader)
	end
	local ItemContent = ReadFile(a_ItemsPath)
	local CraftContent = ReadFile(a_CraftingPath)
	if not ItemContent or not CraftContent then
		return nil, "cannot read recipe files"
	end
	local ItemNames = CrafterRecipes.LoadItemNames(ItemContent)
	local Recipes, Skipped = CrafterRecipes.ParseContent(CraftContent, ItemNames)
	return {
		recipes = Recipes,
		itemNames = ItemNames,
		skipped = Skipped,
	}, Skipped
end
