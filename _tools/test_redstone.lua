
dofile("/home/david/Cuberite/Plugins/Crafter/crafter_recipes.lua")
local CR = CrafterRecipes
local itemContent = io.open("/home/david/Cuberite/items.ini","rb"):read("*a")
local craftContent = io.open("/home/david/Cuberite/crafting.txt","rb"):read("*a")
local ItemNames = CR.LoadItemNames(itemContent)
local Recipes = CR.ParseContent(craftContent, ItemNames)
print("redstonedust alias ->", ItemNames["redstonedust"].id .. ":" .. ItemNames["redstonedust"].damage, "(expected 331:0)")
print("cake alias ->", ItemNames["cake"].id, "(expected 354)")
print("skeletonhead alias ->", ItemNames["skeletonhead"].id .. ":" .. ItemNames["skeletonhead"].damage, "(expected 397:0)")

local function findByName(name)
  for i, R in ipairs(Recipes) do if R.name == name then return i, R end end
  return nil
end
local function check(name, cells, expectedResult, label)
  local Grid = {}
  for cell, it in pairs(cells) do Grid[cell] = it end
  local F = CR.FindRecipe(Recipes, Grid)
  local got = F and (F.result.type .. "^" .. F.result.damage .. "x" .. F.result.count) or "NIL"
  print(label, "->", got, (got == expectedResult) and "OK" or ("  EXPECTED " .. expectedResult))
end

-- redstone torch: redstone(331) above stick(280) at top of 3x3
check("rtorch", { [0] = {type=331, damage=0, count=1}, [3] = {type=280, damage=0, count=1} }, "76^0x1", "redstone torch (redstone top)")
-- same but shifted to middle column
check("rtorch2", { [1] = {type=331, damage=0, count=1}, [4] = {type=280, damage=0, count=1} }, "76^0x1", "redstone torch (middle col)")
-- redstone block: 3x3 dust
local rsb = {}
for c = 0, 8 do rsb[c] = { type=331, damage=0, count=1 } end
check("rsblock", rsb, "152^0x1", "redstone block (9x dust)")
-- redstone dust from block: 1 block anywhere
check("rsfromblock", { [4] = { type=152, damage=0, count=1 } }, "331^0x9", "redstone dust from block")
-- dropper: cobble ring + redstone + empty center
check("dropper", {
  [0]={type=4,damage=0,count=1},[1]={type=4,damage=0,count=1},[2]={type=4,damage=0,count=1},
  [3]={type=4,damage=0,count=1},[5]={type=4,damage=0,count=1},
  [6]={type=4,damage=0,count=1},[7]={type=4,damage=0,count=1},[8]={type=4,damage=0,count=1},
  [4]={type=331,damage=0,count=1},
}, "158^0x1", "dropper recipe")
-- repeater: stone row + redstone torch corners + redstone dust center-top
check("repeater", {
  [1]={type=331,damage=0,count=1},           -- 2:1 redstone dust
  [0]={type=76,damage=0,count=1},[2]={type=76,damage=0,count=1}, -- torches 1:1 3:1
  [3]={type=1,damage=0,count=1},[4]={type=1,damage=0,count=1},[5]={type=1,damage=0,count=1}, -- stone row
}, "356^0x1", "repeater recipe")
-- cake: milk bucket x3 + sugar + egg + wheat x3
check("cake", {
  [0]={type=335,damage=0,count=1},[1]={type=335,damage=0,count=1},[2]={type=335,damage=0,count=1},
  [3]={type=353,damage=0,count=1},[5]={type=353,damage=0,count=1},
  [4]={type=344,damage=0,count=1},
  [6]={type=296,damage=0,count=1},[7]={type=296,damage=0,count=1},[8]={type=296,damage=0,count=1},
}, "354^0x1", "cake")
