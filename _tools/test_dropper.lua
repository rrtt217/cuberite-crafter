
dofile("/home/david/Cuberite/Plugins/Crafter/crafter_recipes.lua")
local CR = CrafterRecipes
local itemContent = io.open("/home/david/Cuberite/items.ini","rb"):read("*a")
local craftContent = io.open("/home/david/Cuberite/crafting.txt","rb"):read("*a")
local ItemNames = CR.LoadItemNames(itemContent)
local Recipes = CR.ParseContent(craftContent, ItemNames)
print("dropper source line:")
for Line in craftContent:gmatch("[^\r\n]+") do
  if Line:find("^dropper:", 1) or Line:find(": Dropper") then print(" ", Line) end
end
-- correct dropper grid: cobble ring (without center 4 and 2:3=7), redstone at 7
local Grid = {}
for _, c in ipairs({0,1,2,3,5,6,8}) do Grid[c] = { type=4, damage=0, count=1 } end
Grid[7] = { type=331, damage=0, count=1 }
local F = CR.FindRecipe(Recipes, Grid)
print("dropper (redstone 2:3) ->", F and (F.result.type .. "^" .. F.result.damage .. "x" .. F.result.count) or "NIL")
if F then
  local src = {}
  for _, Ing in ipairs(F.ingredients) do
    local s = {}
    for _, Slot in ipairs(Ing.slots) do if Slot.x and Slot.y then s[#s+1] = (Slot.x+1) .. ":" .. (Slot.y+1) end end
    src[#src+1] = Ing.item.type .. "@[" .. table.concat(s, ",") .. "]"
  end
  print("  matched ingredients:", table.concat(src, " | "))
end
