local M = {}

local pet = require("pets.pet")
local blocked = require("pets.blocked")

local state = {
  win = nil,
  buf = nil,
  cur_img = nil,
  timer = nil,
  frame_idx = 1,
  frames = {},
  image_cache = {}, -- cache[path .. "@" .. x] = image object, keeps us from
                    -- leaking a fresh image.nvim object every tick.
  object = nil,     -- { type, x, y, width, height, sprite_path, image } | nil
  float_row = nil,  -- screen row of the float window's top-left, set on show()
  float_col = nil,
  float_cols = nil, -- effective width  (cell count) of the float
  float_rows = nil, -- effective height
}

local config = {
  pet = "fox",
  sprite_root = nil,
  sets = { "idle_l", "idle_r", "walk_l", "walk_r", "lie_l", "lie_r", "swipe_l", "swipe_r" },
  fps = 8,
  width = 11,
  height = 5,
  area = {
    corner = "br",
    cols = 0,  -- 0 = auto: cover most of the editor (vim.o.columns - 4)
    rows = 0,  -- 0 = auto: cover most of the editor (vim.o.lines - 4)
  },
}

local CORNERS = { br = true, bl = true, tr = true, tl = true }

-- Environment objects the pet can interact with. Each entry says where
-- the object's sprite lives (relative to the plugin root) and how many
-- cells it occupies. y_from_bottom = how far above the wander box floor
-- the object sits (1 = sitting on the floor row).
local OBJECTS = {
  ball = {
    sprite = "objects/ball.png",
    width = 2, height = 1, y_from_bottom = 1,
  },
}

-- Margins between the wander box and the editor's edges. The bottom margin
-- is larger because the statusline and cmdline occupy the lowest rows.
local PAD_LEFT, PAD_RIGHT = 2, 2
local PAD_TOP,  PAD_BOTTOM = 1, 3

-- find_main_window picks the largest regular split (with current as a
-- tiebreaker) so the pet float lands on the main editing area without
-- ever covering a sidebar like nvim-tree. Floating windows themselves
-- are ignored.
local function find_main_window()
  local current = vim.api.nvim_get_current_win()
  local best, best_score = nil, -1
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local wcfg = vim.api.nvim_win_get_config(win)
    if wcfg.relative == "" then
      local w = vim.api.nvim_win_get_width(win)
      local h = vim.api.nvim_win_get_height(win)
      local score = w * h + ((win == current) and 1 or 0)
      if score > best_score then best, best_score = win, score end
    end
  end
  return best
end

-- Decide where the pet's float should live. Auto mode (area.cols/rows
-- left at 0) drops it onto the main code window. Explicit cols/rows
-- keeps the legacy corner-anchored small-box behavior for users who
-- want the pet tucked away.
local function compute_float_geometry()
  local cols, rows = config.area.cols, config.area.rows

  if cols > 0 and rows > 0 then
    local right_x = math.max(0, vim.o.columns - cols - PAD_RIGHT)
    local left_x  = PAD_LEFT
    local bot_y   = math.max(0, vim.o.lines - rows - PAD_BOTTOM)
    local top_y   = PAD_TOP
    local c = config.area.corner
    local r, x = bot_y, right_x
    if c == "bl" then r, x = bot_y, left_x
    elseif c == "tr" then r, x = top_y, right_x
    elseif c == "tl" then r, x = top_y, left_x
    end
    return r, x, cols, rows
  end

  local target = find_main_window()
  if target then
    local pos = vim.api.nvim_win_get_position(target)
    return pos[1], pos[2],
           vim.api.nvim_win_get_width(target),
           vim.api.nvim_win_get_height(target)
  end

  return PAD_TOP, PAD_LEFT,
         math.max(20, vim.o.columns - PAD_LEFT - PAD_RIGHT),
         math.max(8,  vim.o.lines   - PAD_TOP  - PAD_BOTTOM)
end

local function effective_cols() return state.float_cols or 0 end
local function effective_rows() return state.float_rows or 0 end

-- Per-species defaults. Each entry holds:
--   width / height — cell size, picked to match the sprite's native
--     aspect ratio so the image isn't squashed or stretched.
--   walk_period — master ticks between cell-by-cell moves while walking
--     (lower = faster). The default tick rate is 8fps.
--   transitions — wander state machine probability table; each row sums
--     to 1.0. Tuned to give each species a personality (fox is restless,
--     turtle is sleepy, panda is mellow, dog is balanced).
local SPECIES = {
  fox = {
    width = 11, height = 5, walk_period = 2, -- 92x75 ≈ 1.23:1
    transitions = {
      idle = { idle = 0.50, walk = 0.45, lie = 0.05 },
      walk = { walk = 0.75, idle = 0.20, lie = 0.05 },
      lie  = { lie = 0.60, idle = 0.40 },
    },
  },
  panda = {
    width = 10, height = 5, walk_period = 2, -- 96x96 = 1.00:1
    transitions = {
      idle = { idle = 0.55, walk = 0.25, lie = 0.20 },
      walk = { walk = 0.70, idle = 0.25, lie = 0.05 },
      lie  = { lie = 0.75, idle = 0.25 },
    },
  },
  dog = {
    width = 12, height = 5, walk_period = 2, -- 174x115 ≈ 1.51:1 (akita)
    transitions = {
      idle = { idle = 0.55, walk = 0.40, lie = 0.05 },
      walk = { walk = 0.75, idle = 0.20, lie = 0.05 },
      lie  = { lie = 0.65, idle = 0.35 },
    },
  },
  turtle = {
    width = 11, height = 5, walk_period = 6, -- 115x90 ≈ 1.28:1 (green)
    transitions = {
      idle = { idle = 0.55, walk = 0.15, lie = 0.30 },
      walk = { walk = 0.60, idle = 0.30, lie = 0.10 },
      lie  = { lie = 0.80, idle = 0.20 },
    },
  },
}

local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h:h:h")
end

local terminal_warned = false

-- One-shot warning when nvim is running in a terminal that almost
-- certainly can't render Kitty Graphics. We don't refuse to start —
-- new terminals can be missing from our list — but we want the team
-- member to know why nothing's showing up.
local function maybe_warn_about_terminal()
  if terminal_warned then return end
  terminal_warned = true

  if vim.env.KITTY_WINDOW_ID then return end
  local prog = vim.env.TERM_PROGRAM
  if prog == "WezTerm" or prog == "ghostty" then return end
  -- Inside tmux the parent terminal info is hidden; trust the user.
  if vim.env.TMUX then return end

  vim.notify(
    "nvim-pets: TERM_PROGRAM='" .. (prog or "<unset>") ..
    "' isn't on the known-good list (Kitty, WezTerm, Ghostty). " ..
    "Pet sprites may not render. Run :checkhealth image to verify.",
    vim.log.levels.WARN
  )
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
  config.transitions = sd.transitions
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

-- Bounds describe the pet's allowed (col, row) range inside the float
-- window, plus an is_blocked callback that maps pet coords to screen
-- coords and queries the blocked grid. The pet uses its bottom-center
-- cell as the "feet" anchor — that's the natural ground-contact point.
local function compute_bounds()
  local float_row = state.float_row or 0
  local float_col = state.float_col or 0
  local foot_dx = math.floor(config.width / 2)
  local foot_dy = config.height - 1
  return {
    col_min = 0,
    col_max = math.max(0, effective_cols() - config.width),
    row_min = 0,
    row_max = math.max(0, effective_rows() - config.height),
    is_blocked = function(col, row)
      return blocked.is_blocked(float_row + row + foot_dy, float_col + col + foot_dx)
    end,
  }
end

local function create_float_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = state.float_cols,
    height = state.float_rows,
    row = state.float_row,
    col = state.float_col,
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

local function render_object(image_mod)
  local obj = state.object
  if not obj then return end
  if not obj.image then
    obj.image = image_mod.from_file(obj.sprite_path, {
      id = "nvim-pets-object-" .. obj.type,
      window = state.win,
      buffer = state.buf,
      x = obj.x,
      y = obj.y,
      width = obj.width,
      height = obj.height,
    })
  end
  pcall(function() obj.image:render() end)
end

local function clear_object_image()
  if state.object and state.object.image then
    pcall(function() state.object.image:clear() end)
    state.object.image = nil
  end
end

local function master_tick(image_mod)
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    M.hide()
    return
  end

  pet.tick(compute_bounds())

  -- Render the object first so the pet (placed below) ends up on top in
  -- z-order when they share a column.
  render_object(image_mod)

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

  maybe_warn_about_terminal()

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

  -- Compute the float geometry once per show so the rest of the code
  -- (bounds, start position, object placement) reads from a consistent
  -- snapshot. Re-toggling :Pets re-detects the main window.
  state.float_row, state.float_col, state.float_cols, state.float_rows = compute_float_geometry()

  state.win, state.buf = create_float_win()

  -- Initial blocked map before the first move so the pet doesn't
  -- briefly stand on text. Bottom-right of the float is the safest
  -- default — sits just above the window's statusline area, usually
  -- clear of code.
  blocked.refresh()

  local start_col = math.max(0, state.float_cols - config.width - 2)
  local start_row = math.max(0, state.float_rows - config.height - 1)
  pet.init(start_col, start_row)
  pet.set_walk_period(config.walk_period or 2)
  if config.transitions then pet.set_transitions(config.transitions) end
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
  clear_object_image()
  clear_image_cache()
  state.object = nil
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
  state.frame_idx = 1
  state.float_row, state.float_col = nil, nil
  state.float_cols, state.float_rows = nil, nil
  blocked.clear()
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
  -- Only clamp if the user explicitly set a small wander box; cols/rows = 0
  -- means auto (full editor) and is always large enough.
  if config.area.cols > 0 and config.area.cols < config.width  then config.area.cols = config.width  end
  if config.area.rows > 0 and config.area.rows < config.height then config.area.rows = config.height end
  apply_config()
end

function M.set_area(cols, rows)
  if cols and cols >= 0 then
    config.area.cols = (cols > 0) and math.max(cols, config.width) or 0
  end
  if rows and rows >= 0 then
    config.area.rows = (rows > 0) and math.max(rows, config.height) or 0
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

function M.species_list()
  local names = {}
  for name in pairs(SPECIES) do names[#names + 1] = name end
  table.sort(names)
  return names
end

function M.has_object()
  return state.object ~= nil
end

-- Pick a random x for an object inside the wander box, biased to be at
-- least `min_distance` cells away from the pet so the pet has to walk to
-- get there. Falls back to any valid x if no spot satisfies the distance.
function M.random_object_x(min_distance)
  local def = OBJECTS.ball
  local max_x = math.max(0, effective_cols() - def.width)
  min_distance = min_distance or 0
  for _ = 1, 5 do
    local x = math.random(0, max_x)
    if math.abs(x - pet.col()) >= min_distance then return x end
  end
  return math.random(0, max_x)
end

-- Returns the pet row the caller should approach to (so a horizontal
-- walk reaches the object), or nil if the spawn was rejected.
function M.spawn_object(type, x)
  if state.object then return nil end
  local def = OBJECTS[type]
  if not def then return nil end
  -- The object sits at the bottom of the wander box, so the pet's
  -- bottom row aligns with the object's row when approaching.
  local target_row = math.max(0, effective_rows() - config.height)
  local foot_row = math.max(0, effective_rows() - def.y_from_bottom - def.height + 1)
  state.object = {
    type = type,
    x = x,
    y = foot_row,
    width = def.width,
    height = def.height,
    sprite_path = plugin_root() .. "/sprites/" .. def.sprite,
    image = nil,
  }
  return target_row
end

function M.despawn_object()
  clear_object_image()
  state.object = nil
end

function M.set_pet(name)
  local sd = SPECIES[name]
  if not sd then
    vim.notify(
      "nvim-pets: unknown species '" .. tostring(name)
        .. "' (have: " .. table.concat(M.species_list(), ", ") .. ")",
      vim.log.levels.WARN
    )
    return
  end
  config.pet = name
  config.sprite_root = plugin_root() .. "/sprites/" .. name
  config.width  = sd.width
  config.height = sd.height
  config.walk_period = sd.walk_period
  config.transitions = sd.transitions
  -- Ensure an explicitly-sized wander box still contains the new sprite.
  if config.area.cols > 0 and config.area.cols < config.width  then config.area.cols = config.width  end
  if config.area.rows > 0 and config.area.rows < config.height then config.area.rows = config.height end
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
