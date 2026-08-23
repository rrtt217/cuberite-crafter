
dofile("/home/david/Cuberite/Plugins/Crafter/crafter_recipes.lua")
local CR = CrafterRecipes
local itemContent = io.open("/home/david/Cuberite/items.ini","rb"):read("*a")
local craftContent = io.open("/home/david/Cuberite/crafting.txt","rb"):read("*a")
local ItemNames = CR.LoadItemNames(itemContent)
local Recipes, Skipped = CR.ParseContent(craftContent, ItemNames)

local function BuildGrid(R)
  local Grid, Used = {}, {}
  -- 1) fixed slots first
  for _, Ing in ipairs(R.ingredients) do
    for _, Slot in ipairs(Ing.slots) do
      if Slot.x and Slot.y then
        local Cell = Slot.x + Slot.y * 3
        if Cell < 0 or Cell > 8 then return nil end
        local it = Grid[Cell]
        if not it then
          Grid[Cell] = { type = Ing.item.type, damage = (Ing.item.anyDamage and 1 or Ing.item.damage), count = 1 }
          Used[Cell] = true
        else
          it.count = (it.count or 1) + 1
        end
      end
    end
  end
  -- 2) star slots: place into first free cell (respecting row/col constraints)
  local Assigned = {}
  local function FirstFree(RowIdx, ColIdx)
    for C = 0, 8 do
      local Cx, Cy = C % 3, math.floor(C / 3)
      if not Used[C] then
        if (RowIdx == nil or Cy == RowIdx) and (ColIdx == nil or Cx == ColIdx) then
          Used[C] = true
          return C
        end
      end
    end
    return nil
  end
  local ok = true
  for _, Ing in ipairs(R.ingredients) do
    for _, Slot in ipairs(Ing.slots) do
      if not (Slot.x and Slot.y) then
        local RowIdx = Slot.y and (Slot.y) or nil
        local ColIdx = Slot.x and (Slot.x) or nil
        local Cell = FirstFree(RowIdx, ColIdx)
        if not Cell then ok = false break end
        if Grid[Cell] and Grid[Cell].type ~= Ing.item.type then ok = false break end
        if Grid[Cell] then
          Grid[Cell].count = (Grid[Cell].count or 1) + (Ing.slots and 1) or 1
        else
          Grid[Cell] = { type = Ing.item.type, damage = (Ing.item.anyDamage and 1 or Ing.item.damage), count = 1 }
        end
      end
    end
    if not ok then break end
  end
  return Grid
end

local mismatch, notfound = {}, {}
local same = 0
local couldNotBuild = 0
for i, R in ipairs(Recipes) do
  local Grid = BuildGrid(R)
  if not Grid then couldNotBuild = couldNotBuild + 1 else
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
print("=== REAL ROUND-TRIP (star-aware) ===")
print("exact-same:", same, " notfound:", #notfound, " mismatch:", #mismatch, " couldNotBuild:", couldNotBuild)
for _, i in ipairs(notfound) do
  local R = Recipes[i]
  print("  NOTFOUND #" .. i .. " [" .. tostring(R.name or "?") .. "] result=" .. R.result.type .. "^" .. R.result.damage .. "x" .. R.result.count .. " w=" .. R.width .. " h=" .. R.height)
end
local shown = 0
for _, M in ipairs(mismatch) do
  if shown < 30 then
    local iGot = -1
    for j, F in ipairs(Recipes) do if F == M.got then iGot = j break end end
    print("  MISMATCH #" .. M.idx .. " [" .. tostring(M.want.name or "?") .. "] want=" .. M.want.result.type .. "^" .. M.want.result.damage .. "x" .. M.want.result.count
      .. "  got=#" .. iGot .. " [" .. tostring(M.got.name or "?") .. "] " .. M.got.result.type .. "^" .. M.got.result.damage .. "x" .. M.got.result.count)
    shown = shown + 1
  end
end
if #mismatch > shown then print("  ... and", #mismatch - shown, "more") end
