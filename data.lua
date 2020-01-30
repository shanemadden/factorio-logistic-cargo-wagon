local util = require('util')

local item = {
  type = "item-with-entity-data",
  name = "logistic-cargo-wagon",
  icon = "__logistic-cargo-wagon__/graphics/icons/logistic-cargo-wagon.png",
  icon_size = 32,
  flags = {},
  subgroup = "transport",
  order = "a[train-system]-gz[logistic-cargo-wagon]",
  place_result = "logistic-cargo-wagon",
  stack_size = 5,
}

local recipe = {
  type = "recipe",
  name = "logistic-cargo-wagon",
  enabled = false,
  ingredients = {
    {"cargo-wagon", 1},
    {"logistic-chest-requester", 1},
    {"logistic-chest-active-provider", 1},
  },
  result = "logistic-cargo-wagon"
}

local technology = {
  type = "technology",
  name = "logistic-cargo-wagon",
  icon_size = 128,
  icon = "__base__/graphics/technology/railway.png",
  effects = {
    {
      type = "unlock-recipe",
      recipe = "logistic-cargo-wagon"
    }
  },
  prerequisites = { "character-logistic-slots-2", "character-logistic-trash-slots-2", "logistic-system", "automated-rail-transportation" },
  unit = {
    count = 500,
    ingredients =
    {
      {"automation-science-pack", 1},
      {"logistic-science-pack", 1},
      {"chemical-science-pack", 1},
      {"production-science-pack", 1},
      {"utility-science-pack", 1}
    },
    time = 30
  },
  order = "c-k-d-z"
}

local wagon = util.table.deepcopy(data.raw["cargo-wagon"]["cargo-wagon"])
wagon.name = "logistic-cargo-wagon"
wagon.color = {r = 0.47, g = 0.16, b = 0.58, a = 0.9}
wagon.icon = "__logistic-cargo-wagon__/graphics/icons/logistic-cargo-wagon.png"
wagon.icon_size = 32
wagon.minable.result = "logistic-cargo-wagon"

local character = util.table.deepcopy(data.raw["character"]["character"])
character.name = "logistic-cargo-wagon-proxy-player"
character.collision_mask = {"ghost-layer"}

if mods.robotworld then
  technology.unit = {
    count = 100,
    ingredients =
    {
      {"automation-science-pack", 1},
      {"logistic-science-pack", 1},
    },
    time = 30
  }
  if data.raw.technology["early-character-logistic-slots"] and data.raw.technology["early-character-logistic-trash-slots"] then
    -- robot world's early tech is active, use those as our prereqs
    technology.prerequisites = { "railway", "early-character-logistic-slots", "early-character-logistic-trash-slots" }
  else
    technology.prerequisites = { "railway", "character-logistic-slots-1", "character-logistic-trash-slots-1" }
  end
end
data:extend({ item, recipe, wagon, character, technology })