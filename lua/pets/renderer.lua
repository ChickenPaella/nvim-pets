local M = {}

local state = {
  win = nil,
  buf = nil,
  img = nil,
}

local config = {
  sprite = nil,
  width = 22,
  height = 9,
}

-- Resolve the plugin root from this file's path:
--   <root>/lua/pets/renderer.lua  -> <root>
local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h:h:h")
end

function M.setup(opts)
  config.sprite = opts.sprite or (plugin_root() .. "/sprites/fox.png")
  if opts.width then config.width = opts.width end
  if opts.height then config.height = opts.height end
end

local function create_float_win()
  local width = config.width
  local height = config.height
  -- Bottom-right corner, leaving a 2-cell margin from the edge
  local row = vim.o.lines - height - 3
  local col = vim.o.columns - width - 2

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    focusable = false,
    zindex = 50,
  })

  -- Blend the float background into the editor background so only the sprite shows
  vim.wo[win].winhighlight = "Normal:Normal,NormalFloat:Normal"

  return win, buf
end

function M.show()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return
  end

  local ok_image, image = pcall(require, "image")
  if not ok_image then
    vim.notify("nvim-pets: image.nvim is not available", vim.log.levels.ERROR)
    return
  end

  if vim.fn.filereadable(config.sprite) == 0 then
    vim.notify("nvim-pets: sprite not found: " .. config.sprite, vim.log.levels.ERROR)
    return
  end

  state.win, state.buf = create_float_win()

  state.img = image.from_file(config.sprite, {
    window = state.win,
    buffer = state.buf,
    x = 0,
    y = 0,
    width = config.width,
    height = config.height,
  })
  state.img:render()
end

function M.hide()
  if state.img then
    pcall(function() state.img:clear() end)
    state.img = nil
  end
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
end

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.hide()
  else
    M.show()
  end
end

return M
