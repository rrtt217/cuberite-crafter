
-- Comprehensive recipe-parse audit (standalone, run under luajit)
dofile("/home/david/Cuberite/Plugins/Crafter/crafter_recipes.lua")
local CR = CrafterRecipes

local itemContent = io.open("/home/david/Cuberite/items.ini", "rb"):read("*a")
local craftContent = io.open("/home/david/Cuberite/crafting.txt", "rb"):read("*a")
local ItemNames = CR.LoadItemNames(itemContent)
local Recipes, Skipped = CR.ParseContent(craftContent, ItemNames)

local function count(t) local n=0 for _ in pairs(t) do n=n+1 end return n end
print("items.ini aliases:", count(ItemNames))
print("recipes parsed:", #Recipes, " skipped:", Skipped)

-- unresolved-name check: names used in crafting.txt vs items.ini
local usedNames = {}
for Line in craftContent:gmatch("[^\r\n]+") do
  local L = (Line:gsub("^%s+", ""):gsub("%s+$", ""))
  if L ~= "" and L:sub(1,1) ~= "#" then
    local NC = L:gsub("#.*$", "")
    for Name, Dmg in NC:gmatch("([%a%d_]+%^[%-]?%d+)") do
      local base = Name:match("^([%a%d_]+)") 
      usedNames[base:lower()] = (usedNames[base:lower()] or 0) + 1
    end
    for Name in NC:gmatch("([%a%d_]+)") do
      usedNames[Name:lower()] = (usedNames[Name:lower()] or 0) + 1
    end
  end
end
print("--- names used in crafting.txt not in items.ini ---")
local miss = 0
for k in pairs(usedNames) do
  if not ItemNames[k] then
    miss = miss + 1
    if miss <= 30 then print("  MISSING:", k, "uses:", usedNames[k]) end
  end
end
print("total missing item-name tokens:", miss)

local trouble = {}
for i, R in ipairs(Recipes) do
  local problems = {}
  if not R.result or not R.result.type or R.result.type <= 0 then
    problems[#problems+1] = "result-type=" .. tostring(R.result and R.result.type)
  end
  if not R.ingredients or #R.ingredients == 0 then
    problems[#problems+1] = "no-ingredients"
  end
  for _, Ing in ipairs(R.ingredients or {}) do
    if not Ing.item or not Ing.item.type or Ing.item.type <= 0 then problems[#problems+1] = "ing-type<=0" end
    if not Ing.slots or #Ing.slots == 0 then problems[#problems+1] = "ing-no-slots" end
  end
  if #problems > 0 then
    trouble[#trouble+1] = { i = i, R = R, why = table.concat(problems, ";") }
  end
end
print("--- recipes with parse problems:", #trouble)
for _, T in ipairs(trouble) do
  print("  #", T.i, "[" .. tostring(T.R.name or "?") .. "] " .. T.why)
end
