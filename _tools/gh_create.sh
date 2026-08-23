#!/bin/bash
cd /home/david/Cuberite/Plugins/Crafter || exit 1
gh repo create rrtt217/cuberite-crafter --public \
  --source=. --remote=origin --push \
  --description "Cuberite plugin: a dropper-based Minecraft Crafter (合成器) - 3x3 grid, redstone auto-craft, disabled slots, hopper rules" \
  > _tools/gh_create.txt 2>&1
echo "EXIT=$?" >> _tools/gh_create.txt
cat _tools/gh_create.txt
