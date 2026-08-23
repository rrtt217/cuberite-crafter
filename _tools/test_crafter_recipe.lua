
dofile("/home/david/Cuberite/Plugins/Crafter/crafter_recipes.lua")
local CR = CrafterRecipes
local itemContent = io.open("/home/david/Cuberite/items.ini","rb"):read("*a")
local craftContent = io.open("/home/david/Cuberite/crafting.txt","rb"):read("*a")
local ItemNames = CR.LoadItemNames(itemContent)
local Recipes = CR.ParseContent(craftContent, ItemNames)
-- inject the crafter recipe exactly like main.lua does
Recipes[#Recipes + 1] = CR.MakeCrafterRecipe()
print("total recipes after injection:", #Recipes)

local function gridFromRows(rows)
  local G = {}
  for y, row in ipairs(rows) do
    for x, t in ipairs(row) do
      if t then G[(x-1) + (y-1)*3] = { type = t, damage = 0, count = 1 } end
    end
  end
  return G
end

-- correct crafter pattern
local G1 = gridFromRows({
  {265,265,265},
  {265, 58,265},
  {331,158,331},
})
local F = CR.FindRecipe(Recipes, G1)
print("crafter-in-crafter match:", F and (F.name .. " / result=" .. F.result.type .. "x" .. F.result.count .. " isCrafter=" .. tostring(F.isCrafterRecipe)) or "NIL")

-- wrong arrangements must NOT match the crafter recipe
local G2 = gridFromRows({  -- iron block pattern instead
  {265,265,265},{265,265,265},{265,265,265},
})
local F2 = CR.FindRecipe(Recipes, G2)
print("iron-block grid ->", F2 and (F2.name .. ":" .. F2.result.type .. "x" .. F2.result.count) or "NIL", "(expected iron block 266x1, NOT crafter)")

local G3 = gridFromRows({  -- missing the workbench -> no match at all
  {265,265,265},{265,nil,265},{331,158,331},
})
local F3 = CR.FindRecipe(Recipes, G3)
print("broken pattern ->", F3 and (F3.name .. ":" .. F3.result.type) or "NIL", "(expected NIL)")
