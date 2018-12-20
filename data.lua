local util = require('util')

local item = {
  type = "item-with-entity-data",
  name = "logistic-cargo-wagon",
  icon = "__logistic-cargo-wagon__/graphics/icons/logistic-cargo-wagon.png",
  icon_size = 32,
  flags = {"goes-to-quickbar"},
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
      {"science-pack-1", 1},
      {"science-pack-2", 1},
      {"science-pack-3", 1},
      {"production-science-pack", 1},
      {"high-tech-science-pack", 1}
    },
    time = 30
  },
  order = "c-k-d-z"
}

local wagon = util.table.deepcopy(data.raw["cargo-wagon"]["cargo-wagon"])
wagon.name = "logistic-cargo-wagon"
wagon.color = {r = 0.47, g = 0.16, b = 0.58, a = 0.9}
wagon.icon = "__logistic-cargo-wagon__/graphics/icons/logistic-cargo-wagon.png"
wagon.minable.result = "logistic-cargo-wagon"

local player = util.table.deepcopy(data.raw["player"]["player"])
player.name = "logistic-cargo-wagon-proxy-player"
player.collision_mask = {"ghost-layer"}

data:extend({ item, recipe, technology, wagon, player })
