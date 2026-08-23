
dofile("/home/david/Cuberite/Plugins/Crafter/crafter_recipes.lua")
local CR = CrafterRecipes
local itemContent = io.open("/home/david/Cuberite/items.ini","rb"):read("*a")
local craftContent = io.open("/home/david/Cuberite/crafting.txt","rb"):read("*a")
local ItemNames = CR.LoadItemNames(itemContent)
local Recipes, Skipped = CR.ParseContent(craftContent, ItemNames)

-- walk source lines in order, counting expected ingredient tokens (fragments separated by "|")
-- vs parsed ingredient count; report lines where parsed < expected-tokens.
local idx = 0
local dropped = 0
local examples = {}
for Line in craftContent:gmatch("[^\r\n]+") do
  local L = (Line:gsub("^%s+",""):gsub("%s+$",""))
  if L ~= "" and L:sub(1,1) ~= "#" then
    local NoComment = (L:gsub("#.*$","")):gsub("^%s+",""):gsub("%s+$","")
    if NoComment ~= "" then
      local EqPos = NoComment:find("=", 1, true)
      local IngSide = NoComment:sub(EqPos + 1)
      local expected = 0
      for Part in IngSide:gmatch("[^|]+") do
        local P = (Part:gsub("^%s+",""):gsub("%s+$",""))
        if P ~= "" then expected = expected + 1 end
      end
      idx = idx + 1
      local R = Recipes[idx]
      if R then
        local got = #R.ingredients
        if got < expected then
          dropped = dropped + 1
          if #examples < 40 then
            examples[#examples+1] = { idx = idx, line = NoComment, exp = expected, got = got }
          end
        end
      end
    end
  end
end
print("=== recipes with dropped ingredient tokens:", dropped, " (of", #Recipes, ") ===")
for _, E in ipairs(examples) do
  print("#" .. E.idx .. " exp=" .. E.exp .. " got=" .. E.got .. "  << " .. E.line)
end
