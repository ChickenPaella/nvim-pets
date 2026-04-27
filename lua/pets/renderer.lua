local M = {}

local pet = require("pets.pet")

local state = {
  win = nil,
  buf = nil,
  cur_img = nil,    -- the image currently rendered on screen
  timer = nil,
  frame_idx = 1,
  frames = {},      -- frames[set_name] = { path1, path2, ... }
}

local config = {
  sprite_root = nil,
  sets = { "idle_l", "idle_r", "walk_l", "walk_r", "lie_l", "lie_r" },
  fps = 8,
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
  config.sprite_root = opts.sprite_root or (plugin_root() .. "/sprites/fox")
  if opts.fps then config.fps = opts.fps end
  if opts.width then config.width = opts.width end
  if opts.height then config.height = opts.height end
end

local function discover_frames()
  state.frames = {}
  for _, set_name in ipairs(config.sets) do
    local list = vim.fn.glob(config.sprite_root .. "/" .. set_name .. "/*.png", false, true)
    table.sort(list)
    state.frames[set_name] = list
  end
end

local function compute_bounds()
  return { col_min = 0, col_max = vim.o.columns - config.width }
end

-- A single fixed wide float window covers the bottom of the editor; the pet
-- "wanders" by re-rendering its image at varying x offsets within this window
-- (no nvim_win_set_config calls during movement, so no terminal redraw flicker).
local function create_float_win()
  local row = vim.o.lines - config.height - 3
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = vim.o.columns,
    height = config.height,
    row = row,
    col = 0,
    style = "minimal",
    focusable = false,
    zindex = 50,
  })

  -- Blend the float background into the editor background so only the sprite shows
  vim.wo[win].winhighlight = "Normal:Normal,NormalFloat:Normal"

  return win, buf
end

local function stop_timer()
  if state.timer then
    pcall(function() state.timer:stop() end)
    pcall(function() state.timer:close() end)
    state.timer = nil
  end
end

local function clear_current()
  if state.cur_img then
    pcall(function() state.cur_img:clear() end)
    state.cur_img = nil
  end
end

local function master_tick(image_mod)
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    M.hide()
    return
  end

  pet.tick(compute_bounds())

  local cur_set = pet.current_set()
  local set_frames = state.frames[cur_set]
  if not set_frames or #set_frames == 0 then return end

  local next_idx = (state.frame_idx % #set_frames) + 1

  -- Build the new image at the pet's current x within the fixed wide window,
  -- then render-then-clear so no gap appears between consecutive frames.
  local new_img = image_mod.from_file(set_frames[next_idx], {
    window = state.win,
    buffer = state.buf,
    x = pet.col(),
    y = 0,
    width = config.width,
    height = config.height,
  })

  pcall(function() new_img:render() end)
  clear_current()
  state.cur_img = new_img
  state.frame_idx = next_idx
end

local function start_timer(image_mod)
  stop_timer()
  state.timer = vim.uv.new_timer()
  local interval = math.floor(1000 / config.fps)
  state.timer:start(interval, interval, vim.schedule_wrap(function()
    master_tick(image_mod)
  end))
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

  if vim.fn.isdirectory(config.sprite_root) == 0 then
    vim.notify("nvim-pets: sprite root not found: " .. config.sprite_root, vim.log.levels.ERROR)
    return
  end

  discover_frames()
  if not state.frames["idle_l"] or #state.frames["idle_l"] == 0 then
    vim.notify("nvim-pets: no frames found in " .. config.sprite_root, vim.log.levels.ERROR)
    return
  end

  state.win, state.buf = create_float_win()

  -- Start position: right side of the screen.
  local start_col = vim.o.columns - config.width - 2
  pet.init(start_col, 0)
  state.frame_idx = 1

  -- Initial render so the pet is visible before the first timer tick.
  local initial_set = pet.current_set()
  local initial_frames = state.frames[initial_set]
  if initial_frames and initial_frames[1] then
    local img = image.from_file(initial_frames[1], {
      window = state.win,
      buffer = state.buf,
      x = pet.col(),
      y = 0,
      width = config.width,
      height = config.height,
    })
    pcall(function() img:render() end)
    state.cur_img = img
  end

  start_timer(image)
end

function M.hide()
  stop_timer()
  clear_current()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
  state.frame_idx = 1
end

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.hide()
  else
    M.show()
  end
end

-- Expose pet state for the optional :PetsState debug command.
function M.debug_state()
  return string.format(
    "action=%s dir=%s pos=(%d,%d)",
    pet.action(), pet.dir(), pet.row(), pet.col()
  )
end

return M
