-- Unit tests for crafter_recipes.lua (runs standalone under luajit/lua)
local CR = dofile("crafter_recipes.lua")

local Passed, Failed = 0, 0
local function Check(a_Cond, a_Label)
	if a_Cond then Passed = Passed + 1
	else Failed = Failed + 1; print("FAIL: " .. a_Label) end
end

local DB, Skipped = CR.LoadDatabase("/home/david/Cuberite/crafting.txt", "/home/david/Cuberite/items.ini")
Check(DB ~= nil, "database loads")
Check(DB ~= nil and #DB.recipes > 700, "recipe count > 700, got " .. tostring(DB and #DB.recipes))
print("parsed recipes:", DB and #DB.recipes, "skipped:", Skipped)
local IM = DB.itemNames

local Grid = {}
local function ClearGrid() for i = 0, 8 do Grid[i] = nil end end
local function N(t, c) return { type = t, damage = 0, count = c or 1 } end
local function ND(t, d, c) return { type = t, damage = d, count = c or 1 } end
local function Id(n) local e = IM[n:lower()]; return e and e.id or -1 end

local STICK, PLANK, COAL, CHEST, WB, TORCH, CAKE, BUCKET, MILK, SUGAR, EGG, WHEAT, IRON, OAK_LOG =
	Id("stick"), Id("planks"), Id("coal"), Id("chest"), Id("workbench"), Id("torch"),
	Id("cake"), Id("bucket"), Id("milkbucket"), Id("sugar"), Id("egg"), Id("wheat"),
	Id("iron_ingot"), Id("oaklog")

-- 1. sticks (shifted, any-damage planks)
do ClearGrid()
	Grid[0] = ND(PLANK, 4); Grid[3] = ND(PLANK, 4)
	local r, b = CR.FindRecipe(DB.recipes, Grid)
	Check(r ~= nil and r.result.type == STICK and r.result.count == 4, "sticks (damage-agnostic) result")
	if r then
		CR.ConsumeGrid(Grid, b)
		Check(Grid[0] == nil and Grid[3] == nil, "sticks consumed")
	end
end

-- 2. torch
do ClearGrid()
	Grid[4] = N(COAL); Grid[7] = N(STICK)
	local r, b = CR.FindRecipe(DB.recipes, Grid)
	Check(r ~= nil and r.result.type == TORCH and r.result.count == 4, "torch recipe")
	if r then CR.ConsumeGrid(Grid, b); Check(Grid[4] == nil and Grid[7] == nil, "torch consumed") end
end

-- 3. crafting table shifted to bottom-right
do ClearGrid()
	Grid[4] = N(PLANK); Grid[5] = N(PLANK); Grid[7] = N(PLANK); Grid[8] = N(PLANK)
	local r = CR.FindRecipe(DB.recipes, Grid)
	Check(r ~= nil and r.result.type == WB, "crafting table found at offset")
end

-- 4. chest (full 3x3 ring)
do ClearGrid()
	Grid[0]=N(PLANK);Grid[1]=N(PLANK);Grid[2]=N(PLANK)
	Grid[3]=N(PLANK);Grid[5]=N(PLANK)
	Grid[6]=N(PLANK);Grid[7]=N(PLANK);Grid[8]=N(PLANK)
	local r = CR.FindRecipe(DB.recipes, Grid)
	Check(r ~= nil and r.result.type == CHEST, "chest recipe found")
end

-- 5. cake: recipe found; over-supplied cells keep their remainder.
do ClearGrid()
	Grid[0]=N(MILK, 2);Grid[1]=N(MILK);Grid[2]=N(MILK)
	Grid[3]=N(SUGAR);Grid[4]=N(EGG);Grid[5]=N(SUGAR)
	Grid[6]=N(WHEAT);Grid[7]=N(WHEAT);Grid[8]=N(WHEAT)
	local r, b = CR.FindRecipe(DB.recipes, Grid)
	Check(r ~= nil and r.result.type == CAKE, "cake recipe found")
	if r then
		CR.ConsumeGrid(Grid, b)
		Check(Grid[0] ~= nil and Grid[0].type == MILK and Grid[0].count == 1, "over-supplied milk cell keeps remainder")
		Check(Grid[1] == nil and Grid[2] == nil, "single milk buckets consumed")
		Check(Grid[4] == nil and Grid[3] == nil and Grid[5] == nil and Grid[6] == nil and Grid[7] == nil and Grid[8] == nil, "other cake ingredients consumed")
	end
end

-- 6. painting: stick ring + any-wool centre (damage 14 = red wool)
do ClearGrid()
	Grid[0]=N(STICK);Grid[1]=N(STICK);Grid[2]=N(STICK)
	Grid[3]=N(STICK);Grid[4]=ND(Id("wool"), 14);Grid[5]=N(STICK)
	Grid[6]=N(STICK);Grid[7]=N(STICK);Grid[8]=N(STICK)
	local r = CR.FindRecipe(DB.recipes, Grid)
	Check(r ~= nil and r.result.type == Id("painting"), "painting (any-wool damage)")
end

-- 7. writable book: book + feather + inksac, all stars
do ClearGrid()
	Grid[0]=N(Id("book")); Grid[8]=N(Id("feather")); Grid[2]=ND(Id("inksac"), 0)
	local r = CR.FindRecipe(DB.recipes, Grid)
	Check(r ~= nil and r.result.type == Id("bookandquill"), "writable book (multi-star)")
end

-- 8. book: 3 papers + leather, all stars (same-type stars)
do ClearGrid()
	Grid[1]=N(Id("paper")); Grid[4]=N(Id("paper")); Grid[7]=N(Id("paper")); Grid[8]=N(Id("leather"))
	local r = CR.FindRecipe(DB.recipes, Grid)
	Check(r ~= nil and r.result.type == Id("book"), "book (3 same-type stars + leather)")
end

-- 9. gray dye: black(0) + white(15) stars -> gray(8) x2
do ClearGrid()
	Grid[2]=ND(Id("blackdye"), 0); Grid[7]=ND(Id("whitedye"), 15)
	local r = CR.FindRecipe(DB.recipes, Grid)
	Check(r ~= nil and r.result.type == Id("graydye") and r.result.count == 2 and r.result.damage == 8, "gray dye (two different stars)")
end

-- 10. junk / extra-item rejections
do ClearGrid()
	Grid[0]=N(PLANK); Grid[4]=N(Id("cobblestone"))
	Check(CR.FindRecipe(DB.recipes, Grid) == nil, "junk pattern -> no recipe")
	ClearGrid()
	Grid[0]=N(PLANK); Grid[3]=N(PLANK); Grid[8]=N(Id("cobblestone"))
	Check(CR.FindRecipe(DB.recipes, Grid) == nil, "extra item outside pattern -> no recipe")
end

-- 11. star single item: 1 log anywhere -> 4 planks
do ClearGrid()
	Grid[8] = N(OAK_LOG)
	local r = CR.FindRecipe(DB.recipes, Grid)
	Check(r ~= nil and r.result.type == 5 and r.result.count == 4, "oak log -> 4 planks (star)")
end

-- 12. result damage (acacia log dmg0 -> acacia planks dmg4)
do ClearGrid()
	Grid[4] = N(Id("acacialog"))
	local r = CR.FindRecipe(DB.recipes, Grid)
	Check(r ~= nil and r.result.type == 5 and r.result.damage == 4, "acacia log -> acacia planks damage 4")
end

-- 13. multi-consumption from one slot (synthesized)
do
	local Synth = {
		{ name = "test_multi", result = { type = 999, damage = 0, count = 1 }, width = 1, height = 1,
		  ingredients = { { item = { type = IRON, damage = 0, anyDamage = false }, slots = { { x = 0, y = 0 }, { x = 0, y = 0 } } } } }
	}
	ClearGrid()
	Grid[4] = N(IRON, 2)
	local r, b = CR.FindRecipe(Synth, Grid)
	Check(r ~= nil, "multi-consume same slot matches with count >= 2")
	if r then CR.ConsumeGrid(Grid, b); Check(Grid[4] == nil, "multi-consume empties cell") end
	ClearGrid()
	Grid[4] = N(IRON, 1)
	Check(CR.FindRecipe(Synth, Grid) == nil, "multi-consume fails when count insufficient")
end

-- 14. whole-database sanity
do
	local bad = 0
	for _, R in ipairs(DB.recipes) do
		if type(R.result.type) ~= "number" or (R.result.count or 0) <= 0 then bad = bad + 1 end
	end
	Check(bad == 0, "no malformed recipes")
end

-- 15. every recipe's canonical pattern is matchable (stars placed at spare cells)
do
	local unfound = 0
	local unmatched = {}
	for _, R in ipairs(DB.recipes) do
		ClearGrid()
		local usedCells = {}
		local ok = true
		-- reserve cells for fixed slots first, then give each star slot a free cell
		local starCount = 0
		for _, Ing in ipairs(R.ingredients) do
			for _, Slot in ipairs(Ing.slots) do
				if Slot.x and Slot.y then
					local Cell = Slot.x + Slot.y * 3
					if Cell < 0 or Cell > 8 then ok = false break end
					usedCells[Cell] = true
				else
					starCount = starCount + 1
				end
			end
		end
		if ok then
			local starIdx = 0
			for _, Ing in ipairs(R.ingredients) do
				for _, Slot in ipairs(Ing.slots) do
					if Slot.x and Slot.y then
						local Cell = Slot.x + Slot.y * 3
						if Grid[Cell] then
							Grid[Cell] = { type = Grid[Cell].type, damage = Grid[Cell].damage, count = Grid[Cell].count + 1 }
						else
							Grid[Cell] = { type = Ing.item.type, damage = (Ing.item.anyDamage and 0 or Ing.item.damage), count = 1 }
						end
					else
						starIdx = starIdx + 1
						for C = 0, 8 do
							if not usedCells[C] then
								usedCells[C] = true
								Grid[C] = { type = Ing.item.type, damage = (Ing.item.anyDamage and 0 or Ing.item.damage), count = 1 }
								break
							end
						end
					end
				end
			end
			local r = CR.FindRecipe(DB.recipes, Grid)
			if not r then
				unfound = unfound + 1
				if #unmatched < 25 then unmatched[#unmatched + 1] = R.name or ("#" .. tostring(R.result.type)) end
			end
		end
	end
	Check(unfound == 0, "every recipe canonical pattern matchable (unfound=" .. unfound .. ")")
	if #unmatched > 0 then print("  unmatched:", table.concat(unmatched, ", ")) end
end

print(("=== PASSED %d, FAILED %d ==="):format(Passed, Failed))
os.exit(Failed == 0 and 0 or 1)
