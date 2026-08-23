
dofile("/home/david/Cuberite/Plugins/Crafter/crafter_recipes.lua")
local CR = CrafterRecipes
local craftContent = io.open("/home/david/Cuberite/crafting.txt","rb"):read("*a")
local itemContent = io.open("/home/david/Cuberite/items.ini","rb"):read("*a")
local ItemNames = CR.LoadItemNames(itemContent)
local Recipes = CR.ParseContent(craftContent, ItemNames)

-- print source lines containing firework / rocket
local lines = {}
for Line in craftContent:gmatch("[^\r\n]+") do
  if Line:lower():find("firework") or Line:lower():find("rocket") then
    lines[#lines+1] = Line
  end
end
print("--- crafting.txt firework lines:", #lines)
for i, L in ipairs(lines) do print(i, L) end

-- print the 11 mismatched recipes' parsed form (#737,744,745,749,751..757) and their opponents (730-733,750)
local function dump(no)
  local R = Recipes[no]
  if not R then print("#"..no.." nil"); return end
  print("#"..no.." ["..tostring(R.name).."] result="..R.result.type.."^"..R.result.damage.."x"..R.result.count)
  for i, Ing in ipairs(R.ingredients) do
    local slotsP = {}
    for _, S in ipairs(Ing.slots) do slotsP[#slotsP+1] = tostring(S.x)..":"..tostring(S.y) end
    print("   ing type="..Ing.item.type.." dmg="..Ing.item.damage.." any="..tostring(Ing.item.anyDamage).." slots=["..table.concat(slotsP,",").."]")
  end
end
print("=== recipes 730-757 ===")
for n=730,757 do dump(n) end
