
dofile("/home/david/Cuberite/Plugins/Crafter/crafter_recipes.lua")
local CR = CrafterRecipes
local itemContent = io.open("/home/david/Cuberite/items.ini","rb"):read("*a")
local craftContent = io.open("/home/david/Cuberite/crafting.txt","rb"):read("*a")
local ItemNames = CR.LoadItemNames(itemContent)
local Recipes, Skipped = CR.ParseContent(craftContent, ItemNames)

local R = Recipes[1]
print("recipe[1]:")
print("  name=", R.name)
print("  result=", R.result.type, "^", R.result.damage, "x", R.result.count)
for i, Ing in ipairs(R.ingredients) do
  print("  ing", i, "type=", Ing.item.type, "dmg=", Ing.item.damage, "anyDamage=", tostring(Ing.item.anyDamage))
  for _, S in ipairs(Ing.slots) do print("     slot x=", tostring(S.x), "y=", tostring(S.y)) end
end
print("  w=", R.width, "h=", R.height)

-- manual grid + match attempt
local Grid = { [0] = { type = 5, damage = 4, count = 1 } }
local F, B = CR.FindRecipe(Recipes, Grid)
print("FindRecipe on grid{0:{5,4,1}} =", F and (tostring(F.name) .. " result=" .. F.result.type .. "^" .. F.result.damage .. "x" .. F.result.count) or "NIL")

-- also print the source line
for Line in craftContent:gmatch("[^\r\n]+") do
  if Line:find("acacia_planks", 1, true) then print("SRC:", Line) end
end
-- items.ini entries of interest
for _, k in ipairs({"acacialog","acaciaplanks","oaklog","planks","coal_block","ironblock"}) do
  local e = ItemNames[k]
  print("item", k, "=", e and (e.id .. ":" .. e.damage) or "MISSING")
end
