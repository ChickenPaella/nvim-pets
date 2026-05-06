local M = {}

local pet = require("pets.pet")

local state = {
  win = nil,
  buf = nil,
  cur_img = nil,      -- the pet sprite image currently rendered
  cur_exclaim = nil,  -- the alert "!" overlay currently rendered (or nil)
  timer = nil,
  frame_idx = 1,
  frames = {},        -- frames[set_name] = { path1, path2, ... }
  image_cache = {},   -- cache[key] = image object
                      -- key = path .. "@" .. x .. "," .. y
                      -- y is part of the key now because alert mode places
                      -- the pet at varied vertical positions, not just the
                      -- wander box's fixed row.
}

local config = {
  sprite_root = nil,
  sets = { "idle_l", "idle_r", "walk_l", "walk_r", "lie_l", "lie_r" },
  fps = 8,
  width = 11,
  height = 5,
  area = {
    corner = "br",
    cols = 35,
    rows = 5,
  },
  exclaim_path = nil,
  exclaim_width = 2,
  exclaim_height = 2,
}

local CORNERS = { br = true, bl = true, tr = true, tl = true }

local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h:h:h")
end

local function normalize_corner(corner)
  if corner == "bottom-right" then return "br" end
  if corner == "bottom-left"  then return "bl" end
  if corner == "top-right"    then return "tr" end
  if corner == "top-left"     then return "tl" end
  return corner
end

function M.setup(opts)
  config.sprite_root = opts.sprite_root or (plugin_root() .. "/sprites/fox")
  config.exclaim_path = opts.exclaim_path or (plugin_root() .. "/sprites/effects/exclaim.png")
  if opts.fps    then config.fps    = opts.fps    end
  if opts.width  then config.width  = opts.width  end
  if opts.height then config.height = opts.height end
  if opts.area then
    if opts.area.corner then
      local c = normalize_corner(opts.area.corner)
      if CORNERS[c] then config.area.corner = c end
    end
    if opts.area.cols then config.area.cols = opts.area.cols end
    if opts.area.rows then config.area.rows = opts.area.rows end
  end
end

local function discover_frames()
  state.frames = {}
  for _, set_name in ipairs(config.sets) do
    local list = vim.fn.glob(config.sprite_root .. "/" .. set_name .. "/*.png", false, true)
    table.sort(list)
    state.frames[set_name] = list
  end
end

-- Wander box anchored to a screen corner, expressed as absolute coordinates
-- inside the full-screen float window.
local function compute_bounds()
  local cols = config.area.cols
  local rows = config.area.rows
  local right_x = vim.o.columns - cols - 2
  local left_x  = 2
  local bot_y   = vim.o.lines - rows - 3
  local top_y   = 1

  local box_x, box_y
  local c = config.area.corner
  if c == "bl" then
    box_x, box_y = left_x,  bot_y
  elseif c == "tr" then
    box_x, box_y = right_x, top_y
  elseif c == "tl" then
    box_x, box_y = left_x,  top_y
  else
    box_x, box_y = right_x, bot_y
  end

  return {
    col_min = box_x,
    col_max = box_x + cols - config.width,
    row_min = box_y,
    row_max = box_y + rows - config.height,
  }
end

local function create_float_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  -- Full-screen, transparent, non-interactive float. The pet's coordinates
  -- live inside this window and are interpreted as absolute screen cells.
  -- This replaces the v1.1 corner-anchored wander-box window so that alerts
  -- can teleport the pet anywhere on screen without recreating the window.
  local height = math.max(1, vim.o.lines - 2)
  local width  = math.max(1, vim.o.columns)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = 0,
    col = 0,
    style = "minimal",
    focusable = false,
    zindex = 50,
  })

  vim.wo[win].winhighlight = "Normal:Normal,NormalFloat:Normal"
  -- Without this, the full-screen float draws an opaque background and hides
  -- the editor UI underneath. winblend=100 makes the empty buffer cells fully
  -- transparent so editor text shows through; image.nvim still draws sprites
  -- on top via the Kitty Graphics Protocol (an overlay layer above cells).
  vim.wo[win].winblend = 100
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
  if state.cur_exclaim then
    pcall(function() state.cur_exclaim:clear() end)
    state.cur_exclaim = nil
  end
end

local function cache_key(path, x, y)
  return path .. "@" .. x .. "," .. y
end

local function get_or_create_image(image_mod, path, x, y)
  local key = cache_key(path, x, y)
  local img = state.image_cache[key]
  if not img then
    img = image_mod.from_file(path, {
      id = "nvim-pets-" .. key,
      window = state.win,
      buffer = state.buf,
      x = x,
      y = y,
      width = config.width,
      height = config.height,
    })
    state.image_cache[key] = img
  end
  return img
end

local function get_or_create_exclaim(image_mod, x, y)
  if not config.exclaim_path then return nil end
  if vim.fn.filereadable(config.exclaim_path) == 0 then return nil end
  local key = cache_key("exclaim", x, y)
  local img = state.image_cache[key]
  if not img then
    img = image_mod.from_file(config.exclaim_path, {
      id = "nvim-pets-" .. key,
      window = state.win,
      buffer = state.buf,
      x = x,
      y = y,
      width = config.exclaim_width,
      height = config.exclaim_height,
    })
    state.image_cache[key] = img
  end
  return img
end

local function clear_image_cache()
  for _, img in pairs(state.image_cache) do
    pcall(function() img:clear() end)
  end
  state.image_cache = {}
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
  local pet_x, pet_y = pet.col(), pet.row()

  local new_pet = get_or_create_image(image_mod, set_frames[next_idx], pet_x, pet_y)
  pcall(function() new_pet:render() end)

  local new_exclaim
  if pet.is_alert() then
    local ex_x = pet_x + math.floor(config.width / 2) - 1
    local ex_y = math.max(0, pet_y - config.exclaim_height)
    new_exclaim = get_or_create_exclaim(image_mod, ex_x, ex_y)
    if new_exclaim then
      pcall(function() new_exclaim:render() end)
    end
  end

  -- Render-then-clear: only clear once new frames are on screen, so the
  -- transition has no visible gap.
  if state.cur_img and state.cur_img ~= new_pet then
    pcall(function() state.cur_img:clear() end)
  end
  if state.cur_exclaim and state.cur_exclaim ~= new_exclaim then
    pcall(function() state.cur_exclaim:clear() end)
  end

  state.cur_img = new_pet
  state.cur_exclaim = new_exclaim
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

  -- Start position: middle of the wander box, in absolute screen coords.
  local bounds = compute_bounds()
  local start_col = math.floor((bounds.col_min + bounds.col_max) / 2)
  local start_row = bounds.row_min
  pet.init(start_col, start_row)
  state.frame_idx = 1

  -- Initial render so the pet is visible before the first timer tick.
  local initial_set = pet.current_set()
  local initial_frames = state.frames[initial_set]
  if initial_frames and initial_frames[1] then
    local img = get_or_create_image(image, initial_frames[1], pet.col(), pet.row())
    pcall(function() img:render() end)
    state.cur_img = img
  end

  start_timer(image)
end

function M.hide()
  stop_timer()
  clear_current()
  clear_image_cache()
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

function M.is_visible()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

function M.sprite_width()  return config.width  end
function M.sprite_height() return config.height end

-- External entry point used by reactions.lua to trigger an alert reaction.
-- (row, col) are absolute screen cells. Optionally face the pet a direction.
function M.alert_at(row, col, dir)
  if not M.is_visible() then return end
  pet.enter_alert(row, col, dir)
end

local function apply_config()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.hide()
    M.show()
  end
end

function M.set_size(w, h)
  if w and w > 0 then config.width  = w end
  if h and h > 0 then config.height = h end
  if config.area.cols < config.width  then config.area.cols = config.width  end
  if config.area.rows < config.height then config.area.rows = config.height end
  apply_config()
end

function M.set_area(cols, rows)
  if cols and cols > 0 then
    config.area.cols = math.max(cols, config.width)
  end
  if rows and rows > 0 then
    config.area.rows = math.max(rows, config.height)
  end
  apply_config()
end

function M.set_corner(corner)
  local c = normalize_corner(corner)
  if c and CORNERS[c] then
    config.area.corner = c
    apply_config()
  else
    vim.notify("nvim-pets: invalid corner " .. tostring(corner) .. " (use br/bl/tr/tl)", vim.log.levels.WARN)
  end
end

function M.debug_state()
  return string.format(
    "action=%s dir=%s pos=(%d,%d) size=%dx%d area=%s(%dx%d)",
    pet.action(), pet.dir(), pet.row(), pet.col(),
    config.width, config.height,
    config.area.corner, config.area.cols, config.area.rows
  )
end

return M
