local M = {}

local pet = require("pets.pet")

local state = {
  win = nil,
  buf = nil,
  cur_img = nil,
  cur_exclaim = nil,
  timer = nil,
  frame_idx = 1,
  frames = {},
  image_cache = {},   -- cache[key] = image object (key = path .. "@" .. x .. "," .. y)
  in_alert_window = false, -- true while the float is positioned at an alert location
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

-- Wander mode bounds: pet coords are window-relative inside the wander box.
local function compute_bounds()
  return {
    col_min = 0,
    col_max = config.area.cols - config.width,
    row_min = 0,
    row_max = config.area.rows - config.height,
  }
end

-- Anchor the wander box at one of the four screen corners.
local function compute_corner_pos()
  local cols = config.area.cols
  local rows = config.area.rows
  local right = vim.o.columns - cols - 2
  local left  = 2
  local bot   = vim.o.lines - rows - 3
  local top   = 1

  local c = config.area.corner
  if c == "bl" then return bot, left  end
  if c == "tr" then return top, right end
  if c == "tl" then return top, left  end
  return bot, right
end

local function create_float_win()
  local row, col = compute_corner_pos()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = config.area.cols,
    height = config.area.rows,
    row = row,
    col = col,
    style = "minimal",
    focusable = false,
    zindex = 50,
  })

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
  state.cur_img = nil
  state.cur_exclaim = nil
end

-- Move/resize the float to a small alert area at (abs_row, abs_col).
-- Pet coordinates are reset to in-window offsets that leave room above
-- for the exclaim overlay. After the alert ends the window is restored
-- to the wander-box corner via restore_wander_window().
local function enter_alert_window(abs_row, abs_col, dir)
  local sw = config.width
  local sh = config.height
  local exh = config.exclaim_height
  local win_w = sw + 2
  local win_h = sh + exh + 1

  local win_row = math.max(0, abs_row - exh)
  local win_col = math.max(0, abs_col)
  if win_col + win_w > vim.o.columns then
    win_col = math.max(0, vim.o.columns - win_w - 1)
  end
  if win_row + win_h > vim.o.lines - 1 then
    win_row = math.max(0, vim.o.lines - win_h - 1)
  end

  -- Drop image cache before moving — entries cached at wander-box-relative
  -- coords aren't meaningful after the window jumps to a new screen position.
  clear_image_cache()

  vim.api.nvim_win_set_config(state.win, {
    relative = "editor",
    row = win_row,
    col = win_col,
    width = win_w,
    height = win_h,
  })
  state.in_alert_window = true

  pet.enter_alert(exh, 1, dir)
end

local function restore_wander_window()
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end
  state.in_alert_window = false
  local row, col = compute_corner_pos()
  -- Cache is invalid for the new window position; clear before moving.
  clear_image_cache()
  vim.api.nvim_win_set_config(state.win, {
    relative = "editor",
    row = row,
    col = col,
    width = config.area.cols,
    height = config.area.rows,
  })
end

local function master_tick(image_mod)
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    M.hide()
    return
  end

  local was_alert = pet.is_alert()
  pet.tick(compute_bounds())
  local is_alert_now = pet.is_alert()

  -- alert just ended → snap window back to wander box
  if was_alert and not is_alert_now and state.in_alert_window then
    restore_wander_window()
  end

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
  state.in_alert_window = false

  -- Pet starts at the middle of the wander box (window-relative).
  local start_col = math.max(0, math.floor((config.area.cols - config.width) / 2))
  pet.init(start_col, 0)
  state.frame_idx = 1

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
  state.in_alert_window = false
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

-- Entry point used by reactions.lua. (abs_row, abs_col) are screen cells.
function M.alert_at(abs_row, abs_col, dir)
  if not M.is_visible() then return end
  -- Refuse to overlap an in-flight alert; reactions.lua already debounces
  -- but a manual :PetsAlert during alert would otherwise stack.
  if pet.is_alert() then return end
  enter_alert_window(abs_row, abs_col, dir)
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
    "action=%s dir=%s pos=(%d,%d) size=%dx%d area=%s(%dx%d) alert_win=%s",
    pet.action(), pet.dir(), pet.row(), pet.col(),
    config.width, config.height,
    config.area.corner, config.area.cols, config.area.rows,
    tostring(state.in_alert_window)
  )
end

return M
