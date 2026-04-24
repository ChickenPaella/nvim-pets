local M = {}

function M.setup(opts)
  local renderer = require("pets.renderer")
  renderer.setup(opts or {})

  vim.api.nvim_create_user_command("Pets", function()
    renderer.toggle()
  end, { desc = "nvim-pets: toggle pet display" })
end

return M
