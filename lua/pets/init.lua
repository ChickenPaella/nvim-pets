local M = {}

function M.setup(opts)
  local renderer = require("pets.renderer")
  local events = require("pets.events")
  renderer.setup(opts or {})
  events.setup()

  vim.api.nvim_create_user_command("Pets", function()
    renderer.toggle()
  end, { desc = "nvim-pets: toggle pet display" })

  vim.api.nvim_create_user_command("PetsState", function()
    vim.notify(renderer.debug_state(), vim.log.levels.INFO)
  end, { desc = "nvim-pets: print pet state" })

  vim.api.nvim_create_user_command("PetsPeek",   events.trigger_peek,   { desc = "nvim-pets: trigger a peek (debug)" })
  vim.api.nvim_create_user_command("PetsWiggle", events.trigger_wiggle, { desc = "nvim-pets: trigger a wiggle (debug)" })
  vim.api.nvim_create_user_command("PetsSleep",  events.trigger_sleep,  { desc = "nvim-pets: put the pet to sleep (debug)" })
  vim.api.nvim_create_user_command("PetsWake",   events.trigger_wake,   { desc = "nvim-pets: wake the pet up (debug)" })

  vim.api.nvim_create_user_command("PetsResize", function(args)
    local w = tonumber(args.fargs[1])
    local h = tonumber(args.fargs[2])
    renderer.set_size(w, h)
  end, {
    nargs = "+",
    desc = "nvim-pets: resize sprite (width [height])",
  })

  vim.api.nvim_create_user_command("PetsArea", function(args)
    local cols = tonumber(args.fargs[1])
    local rows = tonumber(args.fargs[2])
    renderer.set_area(cols, rows)
  end, {
    nargs = "+",
    desc = "nvim-pets: resize wander box (cols [rows])",
  })

  vim.api.nvim_create_user_command("PetsMove", function(args)
    renderer.set_corner(args.fargs[1])
  end, {
    nargs = 1,
    complete = function() return { "br", "bl", "tr", "tl" } end,
    desc = "nvim-pets: move wander box to a corner (br/bl/tr/tl)",
  })

  vim.api.nvim_create_user_command("PetsType", function(args)
    renderer.set_pet(args.fargs[1])
  end, {
    nargs = 1,
    complete = function() return { "fox", "panda", "dog", "turtle" } end,
    desc = "nvim-pets: switch pet species (fox/panda/dog/turtle)",
  })
end

return M
