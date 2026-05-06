local M = {}

function M.setup(opts)
  local renderer = require("pets.renderer")
  renderer.setup(opts or {})

  vim.api.nvim_create_user_command("Pets", function()
    renderer.toggle()
  end, { desc = "nvim-pets: toggle pet display" })

  vim.api.nvim_create_user_command("PetsState", function()
    vim.notify(renderer.debug_state(), vim.log.levels.INFO)
  end, { desc = "nvim-pets: print pet state" })

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
end

return M
