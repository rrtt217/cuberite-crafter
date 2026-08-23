
dofile("/home/david/Cuberite/Plugins/Crafter/crafter_recipes.lua")
local CR = CrafterRecipes
local itemContent = io.open("/home/david/Cuberite/items.ini", "rb"):read("*a")
local craftContent = io.open("/home/david/Cuberite/crafting.txt", "rb"):read("*a")
local ItemNames = CR.LoadItemNames(itemContent)
local Recipes, Skipped = CR.ParseContent(craftContent, ItemNames)

-- part 2: round-trip exact-match
local mismatch, notfound = {}, {}
local same = 0
for i, R in ipairs(Recipes) do
  local Grid = {}
  local ok = true
  for _, Ing in ipairs(R.ingredients) do
    for _, Slot in ipairs(Ing.slots) do
      if Slot.x and Slot.y then
        local Cell = Slot.x + Slot.y * 3
        if Cell < 0 or Cell > 8 then ok = false break end
        local it = Grid[Cell]
        if not it then
          it = { type = Ing.item.type, damage = (Ing.item.anyDamage and 1 or Ing.item.damage), count = 1 }
          Grid[Cell] = it
        else
          it.count = (it.count or 1) + 1
        end
      end
    end
    if not ok then break end
  end
  if ok then
    local F = CR.FindRecipe(Recipes, Grid)
    if not F then
      notfound[#notfound+1] = i
    elseif F ~= R then
      mismatch[#mismatch+1] = { idx = i, got = F, want = R }
    else
      same = same + 1
    end
  end
end
print("=== ROUND-TRIP ===")
print("exact-same:", same, "notfound:", #notfound, "mismatch:", #mismatch)
for _, i in ipairs(notfound) do
  local R = Recipes[i]
  print("  NOTFOUND #" .. i .. " [" .. tostring(R.name or "?") .. "] result=" .. R.result.type .. "^" .. R.result.damage .. "x" .. R.result.count .. " w=" .. R.width .. " h=" .. R.height)
end
local shown = 0
for _, M in ipairs(mismatch) do
  if shown < 25 then
    local R = Recipes[M.idx]
    local iGot = -1
    for j, F in ipairs(Recipes) do if F == M.got then iGot = j break end end
    print("  MISMATCH #" .. M.idx .. " [" .. tostring(R.name or "?") .. "] want=" .. R.result.type .. "^" .. R.result.damage .. "x" .. R.result.count
      .. " got=#" .. iGot .. " [" .. tostring(M.got.name or "?") .. "] " .. M.got.result.type .. "^" .. M.got.result.damage .. "x" .. M.got.result.count)
    shown = shown + 1
  end
end
if #mismatch > shown then print("  ... and", #mismatch - shown, "more mismatches") end
