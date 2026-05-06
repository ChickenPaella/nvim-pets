local M = {}

local pet = require("pets.pet")

local state = {
  win = nil,
  buf = nil,
  cur_img = nil,
  timer = nil,
  frame_idx = 1,
  frames = {},
  image_cache = {},     -- cache[key] = image object
  in_run_window = false, -- true while the float follows the pet (run/bark/return)
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

-- Wander box anchored to a screen corner, returned as (row, col) of the
-- box's top-left in absolute screen cells.
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

-- Bounds for wander mode in absolute screen cells.
local function compute_bounds()
  local box_r, box_c = compute_corner_pos()
  return {
    col_min = box_c,
    col_max = box_c + config.area.cols - config.width,
    row_min = box_r,
    row_max = box_r + config.area.rows - config.height,
  }
end

-- Position/size for the small "run window" that follows the pet during
-- run/bark/return. Returns row, col, width, height plus the in-window
-- (x, y) where the pet should be drawn.
--
-- Window size matches the sprite exactly (no margin). Pet is always at
-- (0, 0) inside the window. Without margin there's no empty band of
-- float-window background to leak through onto the editor view.
local function compute_run_window(pet_row, pet_col)
  local w = config.width
  local h = config.height
  local row = pet_row
  local col = pet_col
  if row < 0 then row = 0 end
  if col < 0 then col = 0 end
  if col + w > vim.o.columns then col = math.max(0, vim.o.columns - w - 1) end
  if row + h > vim.o.lines - 1 then row = math.max(0, vim.o.lines - h - 1) end
  return row, col, w, h, 0, 0
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

  -- Transparent background so the float never paints over editor text.
  -- The pet sprite is the only visible content; everywhere the sprite
  -- isn't, the editor underneath shows through.
  vim.api.nvim_set_hl(0, "NvimPetsTransparent", { bg = "NONE" })
  vim.wo[win].winhighlight =
    "Normal:NvimPetsTransparent,NormalFloat:NvimPetsTransparent,EndOfBuffer:NvimPetsTransparent"
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

local function clear_image_cache()
  for _, img in pairs(state.image_cache) do
    pcall(function() img:clear() end)
  end
  state.image_cache = {}
  state.cur_img = nil
end

local function set_window(row, col, w, h)
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end
  vim.api.nvim_win_set_config(state.win, {
    relative = "editor",
    row = row,
    col = col,
    width = w,
    height = h,
  })
end

local function master_tick(image_mod)
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    M.hide()
    return
  end

  local was_busy = pet.is_busy()
  pet.tick(compute_bounds())
  local is_busy = pet.is_busy()

  -- Mode transitions: switch the float between wander-box and run-window
  -- modes. Cache is dropped on each switch since cached images are bound
  -- to (x, y) inside a window that just changed shape and position.
  if not was_busy and is_busy then
    clear_image_cache()
    state.in_run_window = true
    local r, c, w, h = compute_run_window(pet.row(), pet.col())
    set_window(r, c, w, h)
  elseif was_busy and not is_busy then
    clear_image_cache()
    state.in_run_window = false
    local r, c = compute_corner_pos()
    set_window(r, c, config.area.cols, config.area.rows)
  elseif is_busy then
    -- Active run/bark/return — keep the small window glued to the pet so
    -- only a sprite-sized patch of UI is ever covered.
    --
    -- image.nvim does not automatically reposition a placed image when
    -- the window's row/col changes; the Kitty placement stays at the
    -- old absolute spot until we explicitly clear it. So before the
    -- window moves, clear the current sprite, then move, then let the
    -- normal render below re-place it at the new window position.
    if state.cur_img then
      pcall(function() state.cur_img:clear() end)
      state.cur_img = nil
    end
    local r, c, w, h = compute_run_window(pet.row(), pet.col())
    set_window(r, c, w, h)
  end

  local cur_set = pet.current_set()
  local set_frames = state.frames[cur_set]
  if not set_frames or #set_frames == 0 then return end
  local next_idx = (state.frame_idx % #set_frames) + 1

  -- Pet's coordinates inside the current float window.
  local pet_x, pet_y
  if state.in_run_window then
    local _, _, _, _, ix, iy = compute_run_window(pet.row(), pet.col())
    pet_x, pet_y = ix, iy
  else
    local box_r, box_c = compute_corner_pos()
    pet_x = pet.col() - box_c
    pet_y = pet.row() - box_r
  end

  local new_pet = get_or_create_image(image_mod, set_frames[next_idx], pet_x, pet_y)
  pcall(function() new_pet:render() end)

  if state.cur_img and state.cur_img ~= new_pet then
    pcall(function() state.cur_img:clear() end)
  end
  state.cur_img = new_pet
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
  state.in_run_window = false

  -- Pet starts at the middle of the wander box (absolute coords).
  local box_r, box_c = compute_corner_pos()
  local start_col = box_c + math.floor((config.area.cols - config.width) / 2)
  local start_row = box_r
  pet.init(start_col, start_row)
  state.frame_idx = 1

  local initial_set = pet.current_set()
  local initial_frames = state.frames[initial_set]
  if initial_frames and initial_frames[1] then
    local pet_x = pet.col() - box_c
    local pet_y = pet.row() - box_r
    local img = get_or_create_image(image, initial_frames[1], pet_x, pet_y)
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
  state.in_run_window = false
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

-- Entry point used by reactions.lua. (abs_row, abs_col) are absolute
-- screen cells where the pet should run to.
function M.alert_at(abs_row, abs_col)
  if not M.is_visible() then return end
  if pet.is_busy() then return end
  pet.start_run_to(abs_row, abs_col)
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
    "action=%s dir=%s pos=(%d,%d) size=%dx%d area=%s(%dx%d) run_win=%s",
    pet.action(), pet.dir(), pet.row(), pet.col(),
    config.width, config.height,
    config.area.corner, config.area.cols, config.area.rows,
    tostring(state.in_run_window)
  )
end

return M
