-- A cheat-sheet float listing the :Pets* commands, opened with :PetsHelp.
-- Rounded-border float centered in the editor; q / Esc / <CR> close it. Only
-- one instance exists at a time — reopening replaces the old window.

local M = {}

-- { command, keymap, description } — keymap "" when the plugin ships none.
-- Keymaps shown are the ones the README documents (<leader>pp/pb/pf).
local ROWS = {
  { title = "Care · interact" },
  { ":Pets",           "<leader>pp", "toggle the pet on / off" },
  { ":PetsFeed",       "<leader>pf", "feed (happiness up)" },
  { ":PetsThrow",      "<leader>pb", "throw a ball to the cursor (fetched)" },
  { ":PetsStatus",     "",           "show happiness · mood" },
  { ":PetsPomodoro",   "",           "focus session [min] (default 25)" },
  { title = "Appearance · layout" },
  { ":PetsType",       "",           "switch species (fox/panda/dog/turtle)" },
  { ":PetsCount",      "",           "flock size (1-6)" },
  { ":PetsMove",       "",           "box corner (br/bl/tr/tl)" },
  { ":PetsResize",     "",           "sprite size (w h)" },
  { ":PetsArea",       "",           "wander box size (cols rows)" },
  { ":PetsState",      "",           "print current state" },
  { title = "Manual triggers (debug)" },
  { ":PetsPeek/Wiggle/Swipe",  "", "reaction animations" },
  { ":PetsFollow/Object",      "", "follow cursor / spawn a ball" },
  { ":PetsSleep/Wake",         "", "put to sleep / wake up" },
}

local state = { win = nil, buf = nil }

local function close()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win, state.buf = nil, nil
end

-- Lay out one row as "  :Cmd <keymap>   description" with the command column
-- padded to a shared width so the descriptions line up. Section titles are
-- returned as-is (rendered centered by the caller's width).
local function format_rows()
  -- Widest command+keymap cell decides the description column start.
  local cmd_w = 0
  for _, r in ipairs(ROWS) do
    if not r.title then
      local cell = r[2] ~= "" and (r[1] .. "  " .. r[2]) or r[1]
      cmd_w = math.max(cmd_w, vim.fn.strdisplaywidth(cell))
    end
  end

  local lines = {}
  for _, r in ipairs(ROWS) do
    if r.title then
      lines[#lines + 1] = ""
      lines[#lines + 1] = "── " .. r.title .. " ──"
    else
      local cell = r[2] ~= "" and (r[1] .. "  " .. r[2]) or r[1]
      local pad = cmd_w - vim.fn.strdisplaywidth(cell)
      lines[#lines + 1] = "  " .. cell .. string.rep(" ", pad + 3) .. r[3]
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "  q / Esc  close"
  return lines
end

function M.show()
  close()

  local lines = format_rows()
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = width + 2
  local height = #lines

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " nvim-pets ",
    title_pos = "center",
    zindex = 200,
  })
  vim.wo[win].winhighlight = "NormalFloat:NvimPetsBubble,FloatBorder:NvimPetsBubble"
  state.win, state.buf = win, buf

  for _, key in ipairs({ "q", "<Esc>", "<CR>" }) do
    vim.keymap.set("n", key, close, { buffer = buf, nowait = true, silent = true })
  end
end

return M
