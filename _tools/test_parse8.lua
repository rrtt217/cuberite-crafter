
dofile("/home/david/Cuberite/Plugins/Crafter/crafter_recipes.lua")
local CR = CrafterRecipes
local itemContent = io.open("/home/david/Cuberite/items.ini","rb"):read("*a")
local craftContent = io.open("/home/david/Cuberite/crafting.txt","rb"):read("*a")
local ItemNames = CR.LoadItemNames(itemContent)

-- every ITEM token used as a result or an ingredient (i.e., after the '=', before ',' in each fragment)
local missing = {}
local usage = {}
local totalTokens = 0
for Line in craftContent:gmatch("[^\r\n]+") do
  local L = (Line:gsub("^%s+",""):gsub("%s+$",""))
  if L ~= "" and L:sub(1,1) ~= "#" then
    local NC = (L:gsub("#.*$","")):gsub("^%s+",""):gsub("%s+$","")
    local EqPos = NC:find("=", 1, true)
    if EqPos then
      -- result side: first token (ignore name prefix)
      local ResultSide = NC:sub(1, EqPos-1)
      local Rs = ResultSide:match("^[^:]+:%s*(.+)$") or ResultSide
      local ItemTok = Rs:match("%s*([%a%d_]+%^?[%-]?%d*)%s*[,%s]*") or Rs:match("%s*([%a%d_]+)")
      if ItemTok then
        totalTokens = totalTokens + 1
        local Req = CR.ParseItemRequirement and nil
      end
      -- use a quick local resolver via loading: simpler to just try name resolution below
    end
  end
end

-- simpler: reuse parser by scanning ingredient fragments and result tokens for names that fail
local function TryName(name)
  name = name:lower()
  return ItemNames[name] ~= nil
end
local Parsed = {}
local function RecordMissing(name, dmg)
  local key = name .. (dmg and ("^"..dmg) or "")
  if not missing[key] then missing[key] = { name = name, dmg = dmg } end
  usage[key] = (usage[key] or 0) + 1
end
for Line in craftContent:gmatch("[^\r\n]+") do
  local L = (Line:gsub("^%s+",""):gsub("%s+$",""))
  if L ~= "" and L:sub(1,1) ~= "#" then
    local NC = (L:gsub("#.*$","")):gsub("^%s+",""):gsub("%s+$","")
    -- result-token
    local EqPos = NC:find("=", 1, true)
    if EqPos then
      local ResultSide = NC:sub(1, EqPos-1)
      local Rs = ResultSide:match("^[^:]+:%s*(.+)$") or ResultSide
      for Name, Dmg in Rs:gmatch("([%a%d_]+)%^([%-]?%d+)") do
        totalTokens = totalTokens + 1
        if not TryName(Name) then RecordMissing(Name, Dmg) end
      end
      for Name in Rs:gmatch("([%a%d_]+)") do
        -- only the item token; skip if it was already counted with ^
        if not Rs:match("[%a%d_]+%^[%-]?%d+") then break end
      end
      -- fallback: match leading item name before , or count
      local Lead = Rs:match("^%s*([%a%d_]+)%s*[,%d^]") or Rs:match("^%s*([%a%d_]+)%s*$")
      if Lead then
        totalTokens = totalTokens + 1
        if not TryName(Lead) and not missing[Lead] then RecordMissing(Lead) end
      end
      -- ingredient tokens
      for Part in NC:sub(EqPos+1):gmatch("[^|]+") do
        local P = (Part:gsub("^%s+",""):gsub("%s+$",""))
        if P ~= "" then
          local Name, Dmg = P:match("^([%a%d_]+)%^([%-]?%d+)")
          local Name2 = Name or P:match("^([%a%d_]+)")
          totalTokens = totalTokens + 1
          if Name2 and not TryName(Name2) then RecordMissing(Name2, Name and Dmg or nil) end
        end
      end
    end
  end
end
print("=== unique item-name tokens used in crafting.txt that FAIL items.ini lookup ===")
for key, M in pairs(missing) do
  print("  MISSING:", M.name .. (M.dmg and ("^"..M.dmg) or ""), " uses:", usage[key])
end
print("total unique missing:", #(function() local n=0 for _ in pairs(missing) do n=n+1 end return n end)())
