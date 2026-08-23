#!/bin/bash
cd /home/david/Cuberite/Plugins/Crafter || exit 1
git add -A
git commit -q -m "Fix workbench recipe: register ingredients so crafting consumes them

A plugin recipe that only sets the result yields the result item but
Cuberite's ConsumeIngredients works from the recipe's ingredient list,
so the 9 pattern cells were never depleted.  Now set all non-empty cells
via Recipe:SetIngredient(x, y, type, 1, 0) before SetResult.
" 
git push -q origin main
echo "PUSHED: $(git log --oneline -1)"
