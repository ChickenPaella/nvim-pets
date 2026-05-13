local M = {}

local pet = require("pets.pet")

local state = {
  win = nil,
  buf = nil,
  cur_img = nil,
  timer = nil,
  frame_idx = 1,
  frames = {},
  image_cache = {}, -- cache[path .. "@" .. x] = image object, keeps us from
                    -- leaking a fresh image.nvim object every tick.
}

local config = {
  pet = "fox",
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

-- Per-species defaults. Sprite sheets have different native aspect ratios,
-- so each species needs its own cell size to avoid bad stretching when
-- rendered on a fixed cell grid. walk_period = master ticks per cell of
-- walking motion (lower = faster); the default tick rate is 8fps, so a
-- walk_period of 2 means 4 cells/sec.
local SPECIES = {
  fox    = { width = 11, height = 5, walk_period = 2 }, -- 92x75 ≈ 1.23:1
  panda  = { width = 10, height = 5, walk_period = 2 }, -- 96x96 = 1.00:1
  dog    = { width = 12, height = 5, walk_period = 2 }, -- 174x115 ≈ 1.51:1 (akita)
  turtle = { width = 11, height = 5, walk_period = 6 }, -- 115x90 ≈ 1.28:1 (green) — slow on purpose
}

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
  local pet_name = opts.pet or "fox"
  local sd = SPECIES[pet_name] or SPECIES.fox
  config.pet = pet_name
  config.sprite_root = opts.sprite_root or (plugin_root() .. "/sprites/" .. pet_name)
  config.width  = opts.width  or sd.width
  config.height = opts.height or sd.height
  config.walk_period = opts.walk_period or sd.walk_period
  if opts.fps    then config.fps    = opts.fps    end
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

-- Pet movement is bounded by the wander box (window-relative coords).
local function compute_bounds()
  return { col_min = 0, col_max = config.area.cols - config.width }
end

local function compute_window_pos()
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
  local row, col = compute_window_pos()
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

  -- Transparent background so only the pet sprite is visible — the wander
  -- box's empty cells let the editor underneath show through.
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

local function get_or_create_image(image_mod, path, x)
  local key = path .. "@" .. x
  local img = state.image_cache[key]
  if not img then
    img = image_mod.from_file(path, {
      id = "nvim-pets-" .. key,
      window = state.win,
      buffer = state.buf,
      x = x,
      y = 0,
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
  local new_pet = get_or_create_image(image_mod, set_frames[next_idx], pet.col())

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

  local start_col = math.max(0, math.floor((config.area.cols - config.width) / 2))
  pet.init(start_col, 0)
  pet.set_walk_period(config.walk_period or 2)
  state.frame_idx = 1

  local initial_set = pet.current_set()
  local initial_frames = state.frames[initial_set]
  if initial_frames and initial_frames[1] then
    local img = get_or_create_image(image, initial_frames[1], pet.col())
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
function M.corner()        return config.area.corner end

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

function M.set_pet(name)
  local sd = SPECIES[name]
  if not sd then
    vim.notify("nvim-pets: unknown species '" .. tostring(name) .. "' (have: fox, panda, dog, turtle)", vim.log.levels.WARN)
    return
  end
  config.pet = name
  config.sprite_root = plugin_root() .. "/sprites/" .. name
  config.width  = sd.width
  config.height = sd.height
  config.walk_period = sd.walk_period
  -- Ensure the wander box still contains the new sprite.
  if config.area.cols < config.width  then config.area.cols = config.width  end
  if config.area.rows < config.height then config.area.rows = config.height end
  apply_config()
end

function M.species() return config.pet end

function M.debug_state()
  return string.format(
    "pet=%s action=%s dir=%s pos=(%d,%d) size=%dx%d area=%s(%dx%d)",
    config.pet, pet.action(), pet.dir(), pet.row(), pet.col(),
    config.width, config.height,
    config.area.corner, config.area.cols, config.area.rows
  )
end

return M
