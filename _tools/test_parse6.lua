
dofile("/home/david/Cuberite/Plugins/Crafter/crafter_recipes.lua")
local CR = CrafterRecipes
local itemContent = io.open("/home/david/Cuberite/items.ini","rb"):read("*a")
local craftContent = io.open("/home/david/Cuberite/crafting.txt","rb"):read("*a")
local ItemNames = CR.LoadItemNames(itemContent)
print("fireworkstar entry:", ItemNames["fireworkstar"] and (ItemNames["fireworkstar"].id .. ":" .. ItemNames["fireworkstar"].damage) or "MISSING")
print("paper entry:", ItemNames["paper"] and (ItemNames["paper"].id .. ":" .. ItemNames["paper"].damage) or "MISSING")

-- what does the actual crafting.txt line 4 look like exactly (bytes)?
local n = 0
for Line in craftContent:gmatch("([^\r\n]+)") do
  n = n + 1
  if n >= 4 and n <= 4 then
    print("LINE4 bytes:", Line:byte(1, #Line))
  end
  if n >= 4 and n <= 30 then
    -- find firework star lines
  end
end
-- parse line 4 manually via internal pieces: reproduce parser on the first firework line
local Recipes = CR.ParseContent(craftContent, ItemNames)
-- find recipe with result 401 (firework star) ingredient fireworkstar+paper+gunpowder
for i, R in ipairs(Recipes) do
  if R.result.type == 401 then
    local ings = {}
    for _, Ing in ipairs(R.ingredients) do ings[#ings+1] = Ing.item.type .. "^" .. Ing.item.damage end
    print("R401 #" .. i .. " [" .. tostring(R.name or "?") .. "] too=" .. table.concat(ings, ", ") .. " ingCount=" .. #R.ingredients)
    if i > 740 then break end
  end
end
