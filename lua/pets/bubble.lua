-- Tiny transient speech bubble shown next to the pet. A small bordered
-- float that auto-closes after a timeout. Used for "zzz" on sleep, save
-- reactions, LSP reactions, feeding hearts, etc. Only one bubble exists at
-- a time — a new one replaces the old so reactions never stack up.

local M = {}

local state = { win = nil, buf = nil, timer = nil }

local function close()
  if state.timer then
    pcall(function() state.timer:stop() end)
    pcall(function() state.timer:close() end)
    state.timer = nil
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win, state.buf = nil, nil
end

M.hide = close

-- Show `text` with its top-left near screen cell (row, col). The border
-- adds a row/column of its own, so callers position relative to the pet
-- and let the bubble sit slightly above it.
function M.show(text, row, col, duration_ms)
  close()
  if type(text) ~= "string" or text == "" then return end
  text = " " .. text .. " "

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })
  vim.bo[buf].bufhidden = "wipe"

  local width = vim.fn.strdisplaywidth(text)
  local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
    relative = "editor",
    width = width,
    height = 1,
    row = math.max(0, row),
    col = math.max(0, col),
    style = "minimal",
    focusable = false,
    zindex = 60,           -- above the pet float (zindex 50)
    border = "rounded",
    noautocmd = true,
  })
  if not ok then
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    return
  end

  vim.wo[win].winhighlight = "NormalFloat:NvimPetsBubble,FloatBorder:NvimPetsBubble"
  state.win, state.buf = win, buf

  state.timer = vim.uv.new_timer()
  state.timer:start(duration_ms or 2000, 0, vim.schedule_wrap(close))
end

return M
