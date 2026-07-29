local M = {}

local pet = require("pets.pet")
local blocked = require("pets.blocked")
local bubble = require("pets.bubble")

local state = {
  win = nil,
  buf = nil,
  timer = nil,
  frames = {},
  -- One render view per pet on screen:
  --   { pet = <pet instance>, cache = { [path] = image }, cur_img, frame_idx }
  -- The image cache is keyed by path only (not path+x+y) and repositioned
  -- each tick via img:render({ x, y }), so it stays bounded by the frame
  -- count even when the pet roams the whole editor — otherwise every
  -- visited cell leaked a Kitty placement until the terminal froze on long
  -- sessions. Each view also gets its own image ids (prefixed by index) so
  -- two pets never share a placement.
  views = {},
  object = nil,     -- { type, x, y, width, height, sprite_path, image } | nil
  last_motion = 0,  -- uv.now() of the last cursor/scroll/edit; drives settle
  float_row = nil,  -- screen row of the float window's top-left, set on show()
  float_col = nil,
  float_cols = nil, -- effective width  (cell count) of the float
  float_rows = nil, -- effective height
  paused = false,   -- true while nvim is unfocused (see M.pause / M.resume)
  image_mod = nil,  -- the image.nvim module, kept so resume() can restart
}

local config = {
  pet = "fox",
  sprite_root = nil,
  sets = { "idle_l", "idle_r", "walk_l", "walk_r", "lie_l", "lie_r", "swipe_l", "swipe_r" },
  -- 6fps instead of 8 — fewer Kitty Graphics commands per second, which
  -- noticeably reduces the text-cursor blink some terminals exhibit
  -- when the float overlaps the cursor's cell. Animation still feels
  -- alive at this rate.
  fps = 6,
  width = 11,
  height = 5,
  count = 1,   -- number of pets roaming at once (1 = classic single pet)
  -- The pets go still (stop moving *and* stop being redrawn) after this many
  -- ms with no cursor movement / typing / scrolling, and spring back to life
  -- the moment you do anything. Since every redraw briefly nudges the
  -- terminal cursor, freezing while you read is what actually stops the
  -- cursor flicker. 0 disables it (pets always animate).
  settle_ms = 1200,
  area = {
    corner = "br",
    cols = 0,  -- 0 = auto: cover most of the editor (vim.o.columns - 4)
    rows = 0,  -- 0 = auto: cover most of the editor (vim.o.lines - 4)
  },
}

local CORNERS = { br = true, bl = true, tr = true, tl = true }
local MAX_PETS = 6  -- keep the Kitty placement count (and the surprise) sane
local FLOCK_NOTICE_DIST = 3  -- cells within which two pets glance at each other
-- Master ticks between sprite-frame flips while a pet is standing still.
-- At 6fps that's ~1 breath/sec — slow enough that a resting pet barely
-- redraws, which keeps the terminal cursor from flickering.
local ANIM_PERIOD = 6

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

-- find_main_window picks the largest regular split holding a real file
-- buffer (buftype = ""), with the current window as a tiebreaker. This
-- intentionally excludes terminals, quickfix lists, help, nvim-tree
-- and similar non-code panels, so the pet always lands on the code
-- area regardless of how the layout is split.
local function find_main_window()
  local current = vim.api.nvim_get_current_win()
  local best, best_score = nil, -1
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local wcfg = vim.api.nvim_win_get_config(win)
    if wcfg.relative == "" then
      local buf = vim.api.nvim_win_get_buf(win)
      local btype = vim.api.nvim_get_option_value("buftype", { buf = buf })
      if btype == "" then
        local w = vim.api.nvim_win_get_width(win)
        local h = vim.api.nvim_win_get_height(win)
        local score = w * h + ((win == current) and 1 or 0)
        if score > best_score then best, best_score = win, score end
      end
    end
  end
  if best then return best end

  -- Fallback: no file buffer (e.g., the user is on a Dashboard / empty
  -- session). Use the largest non-floating window anyway so we have
  -- something to attach to.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local wcfg = vim.api.nvim_win_get_config(win)
    if wcfg.relative == "" then
      local w = vim.api.nvim_win_get_width(win)
      local h = vim.api.nvim_win_get_height(win)
      local score = w * h
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
--   width / height — cell size, deliberately small so the pet feels
--     like an icon rather than a chunky pixel-art block. Picked to
--     roughly match each sprite's native aspect (terminal cells are
--     ~1:2 W:H, so N cols × M rows renders the image at N : 2M).
--   walk_period — master ticks between cell-by-cell moves while
--     walking (lower = faster).
--   transitions — wander state machine probability table; each row
--     sums to 1.0. Tuned toward "walk often" so the pet is visibly
--     lively by default while still showing per-species personality
--     (fox restless, turtle sleepy, panda mellow, dog balanced).
local SPECIES = {
  fox = {
    width = 7, height = 3, walk_period = 1, -- 92x75 ≈ 1.23:1
    transitions = {
      idle = { idle = 0.30, walk = 0.65, lie = 0.05 },
      walk = { walk = 0.90, idle = 0.08, lie = 0.02 },
      lie  = { lie = 0.50, idle = 0.50 },
    },
  },
  panda = {
    width = 6, height = 3, walk_period = 2, -- 96x96 = 1.00:1
    transitions = {
      idle = { idle = 0.40, walk = 0.50, lie = 0.10 },
      walk = { walk = 0.85, idle = 0.12, lie = 0.03 },
      lie  = { lie = 0.65, idle = 0.35 },
    },
  },
  dog = {
    width = 9, height = 3, walk_period = 1, -- 174x115 ≈ 1.51:1 (akita)
    transitions = {
      idle = { idle = 0.35, walk = 0.60, lie = 0.05 },
      walk = { walk = 0.88, idle = 0.10, lie = 0.02 },
      lie  = { lie = 0.55, idle = 0.45 },
    },
  },
  turtle = {
    width = 7, height = 3, walk_period = 4, -- 115x90 ≈ 1.28:1 (green)
    transitions = {
      idle = { idle = 0.50, walk = 0.30, lie = 0.20 },
      walk = { walk = 0.80, idle = 0.18, lie = 0.02 },
      lie  = { lie = 0.70, idle = 0.30 },
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
  if opts.count  then config.count  = math.max(1, math.min(MAX_PETS, math.floor(opts.count))) end
  if opts.settle_ms ~= nil then config.settle_ms = math.max(0, opts.settle_ms) end
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
-- coords and queries the blocked grid.
--
-- The sprite is config.width × config.height cells, so the whole footprint
-- has to be clear. Anchoring on a single bottom-center "feet" cell was the
-- reason the pet still covered code: one empty cell at its feet was enough
-- for the remaining ~20 cells of its body to sit on top of a line.
local function footprint_blocked(col, row)
  return blocked.rect_blocked(
    (state.float_row or 0) + row,
    (state.float_col or 0) + col,
    config.width, config.height
  )
end

local function compute_bounds()
  return {
    col_min = 0,
    col_max = math.max(0, effective_cols() - config.width),
    row_min = 0,
    row_max = math.max(0, effective_rows() - config.height),
    is_blocked = footprint_blocked,
  }
end

local function overlaps_taken(taken, col, row)
  for _, t in ipairs(taken) do
    if col < t[1] + config.width and col + config.width > t[1]
        and row < t[2] + config.height and row + config.height > t[2] then
      return true
    end
  end
  return false
end

-- Free sprite-sized spot nearest to (pref_col, pref_row), searched outward
-- row by row and then column by column. Used to place pets on show(): the
-- old code dropped them at a fixed bottom-right offset, which lands on top
-- of code whenever the file happens to fill that corner. `taken` collects
-- the rects already handed out so a flock doesn't spawn stacked. Returns nil
-- when the screen has no room at all.
local function find_free_spot(pref_col, pref_row, taken)
  local col_max = math.max(0, effective_cols() - config.width)
  local row_max = math.max(0, effective_rows() - config.height)
  pref_col = math.max(0, math.min(pref_col, col_max))
  pref_row = math.max(0, math.min(pref_row, row_max))

  for dr = 0, row_max do
    for _, row in ipairs({ pref_row - dr, pref_row + dr }) do
      if row >= 0 and row <= row_max then
        for dc = 0, col_max do
          for _, col in ipairs({ pref_col + dc, pref_col - dc }) do
            if col >= 0 and col <= col_max
                and not overlaps_taken(taken, col, row)
                and not footprint_blocked(col, row) then
              return col, row
            end
          end
        end
      end
    end
  end
  return nil
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
  -- Speech bubbles reuse a normal (opaque) highlight so their text stays
  -- readable over code. Linked to Normal so it follows the colorscheme.
  vim.api.nvim_set_hl(0, "NvimPetsBubble", { link = "Normal", default = true })
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

-- One cached image.nvim object per (view, sprite frame). Position is
-- applied at render time (img:render({ x, y })), so a frame visited at many
-- cells still costs a single object/placement per pet.
local function get_image(view, idx, image_mod, path)
  local img = view.cache[path]
  if not img then
    img = image_mod.from_file(path, {
      id = "nvim-pets-v" .. idx .. "-" .. path,
      window = state.win,
      buffer = state.buf,
      x = 0,
      y = 0,
      width = config.width,
      height = config.height,
    })
    view.cache[path] = img
  end
  return img
end

local function clear_view_images(view)
  if view.cur_img then
    pcall(function() view.cur_img:clear() end)
    view.cur_img = nil
  end
  for _, img in pairs(view.cache) do
    pcall(function() img:clear() end)
  end
  view.cache = {}
end

local function clear_all_views()
  for _, view in ipairs(state.views) do
    clear_view_images(view)
  end
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

-- Cursor screen cell (0-based) when we should keep pets off it, else nil.
-- While you're typing (insert mode) a sprite drawn over the insertion point
-- makes some terminals fight the cursor and blink, and it hides what you're
-- writing — so a pet overlapping the cursor is skipped for that frame. In
-- normal mode the pet may pass freely.
local function cursor_avoid_cell()
  if vim.fn.mode():sub(1, 1) ~= "i" then return nil end
  return vim.fn.screenrow() - 1, vim.fn.screencol() - 1
end

local function overlaps_cursor(view, cur_r, cur_c)
  if not cur_r then return false end
  local top = state.float_row + view.pet:row()
  local left = state.float_col + view.pet:col()
  return cur_r >= top and cur_r < top + config.height
     and cur_c >= left and cur_c < left + config.width
end

-- Pets glance at a near neighbour when idle (the flock "notices" itself).
local function flock_glance()
  local n = #state.views
  if n < 2 then return end
  for i = 1, n do
    for j = i + 1, n do
      local a, b = state.views[i].pet, state.views[j].pet
      if math.abs(a:col() - b:col()) <= FLOCK_NOTICE_DIST
         and math.abs(a:row() - b:row()) <= FLOCK_NOTICE_DIST then
        a:look_at(b:col())
        b:look_at(a:col())
      end
    end
  end
end

local function render_view(view, idx, image_mod, cur_r, cur_c)
  local set_frames = state.frames[view.pet:current_set()]
  if not set_frames or #set_frames == 0 then return end

  -- Keep the pet off the insertion point: hide this frame if it would cover
  -- the cursor while typing.
  if overlaps_cursor(view, cur_r, cur_c) then
    if view.cur_img then
      pcall(function() view.cur_img:clear() end)
      view.cur_img = nil
    end
    view.last_path, view.last_x, view.last_y = nil, nil, nil
    return
  end

  local x, y = view.pet:col(), view.pet:row()
  local moved = (x ~= view.last_x or y ~= view.last_y)

  -- Frame timing: while moving, advance one frame per step so the legs stay
  -- in sync with the motion; while standing still, breathe slowly on the
  -- animation clock. Decoupling this from the master tick is what keeps a
  -- resting pet from re-drawing 6×/sec.
  if moved then
    view.frame_idx = (view.frame_idx % #set_frames) + 1
    view.anim_throttle = 0
  else
    view.anim_throttle = (view.anim_throttle or 0) + 1
    if view.anim_throttle >= ANIM_PERIOD then
      view.anim_throttle = 0
      view.frame_idx = (view.frame_idx % #set_frames) + 1
    end
  end

  local path = set_frames[view.frame_idx]
  -- Nothing changed since the last draw → don't touch the terminal at all.
  -- Every Kitty placement nudges the real cursor (move → draw → restore),
  -- and doing that many times a second is what makes the cursor flicker, so
  -- skipping no-op redraws is the core of keeping the cursor calm.
  if path == view.last_path and not moved then return end

  local img = get_image(view, idx, image_mod, path)
  pcall(function() img:render({ x = x, y = y }) end)
  if view.cur_img and view.cur_img ~= img then
    pcall(function() view.cur_img:clear() end)
  end
  view.cur_img = img
  view.last_path, view.last_x, view.last_y = path, x, y
end

-- True while *any* pet is still walking to or playing with the object. The
-- lead pet used to be the only one asked, so with a flock the ball vanished
-- the moment the lead was done even though the others were mid-run.
local function any_object_busy()
  for _, view in ipairs(state.views) do
    if view.pet:is_object_busy() then return true end
  end
  return false
end

local now_ms = (vim.uv or vim.loop).now

-- Called (cheaply) on every cursor move / scroll / edit so the pets know
-- you're active. See config.settle_ms.
function M.poke()
  state.last_motion = now_ms()
end

local function master_tick(image_mod)
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    M.hide()
    return
  end

  -- Settle: once you've stopped moving for a moment, freeze the pets
  -- entirely — no logic ticks, no redraws — so the terminal cursor is left
  -- completely alone while you read. Any activity calls M.poke() and they
  -- resume next tick. A pet in the middle of playing with a ball keeps going
  -- so the interaction doesn't stall half-way.
  if config.settle_ms > 0
      and (now_ms() - state.last_motion) > config.settle_ms
      and not (state.object and any_object_busy()) then
    return
  end

  local bounds = compute_bounds()
  local lead_sleeping = pet.is_sleeping()

  for i, view in ipairs(state.views) do
    -- The lead pet (view 1) is the events-driven singleton and is ticked by
    -- pet.tick; the rest are autonomous wanderers. Extras mirror the lead's
    -- sleep state so the whole flock naps and wakes together.
    if i == 1 then
      pet.tick(bounds)
    else
      if lead_sleeping and not view.pet:is_sleeping() then view.pet:sleep()
      elseif not lead_sleeping and view.pet:is_sleeping() then view.pet:wake() end
      view.pet:tick(bounds)
    end
  end

  flock_glance()

  -- Despawn an object once every pet is finished with it. Folded into the
  -- master tick so there's no separate polling timer and no visible lag.
  if state.object and not any_object_busy() then
    clear_object_image()
    state.object = nil
  end

  -- Render the object first so pets (re-rendered below) sit on top in
  -- z-order when they share a column.
  render_object(image_mod)

  local cur_r, cur_c = cursor_avoid_cell()
  for i, view in ipairs(state.views) do
    render_view(view, i, image_mod, cur_r, cur_c)
  end
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

  -- Initial blocked map before the first placement so the pets don't
  -- briefly stand on text. The bottom-right of the float is only the
  -- *preferred* spawn; find_free_spot moves it if code is already there.
  blocked.refresh()

  local taken = {}
  local pref_col = math.max(0, state.float_cols - config.width - 2)
  local pref_row = math.max(0, state.float_rows - config.height - 1)
  local start_col, start_row = find_free_spot(pref_col, pref_row, taken)
  if not start_col then start_col, start_row = pref_col, pref_row end
  taken[#taken + 1] = { start_col, start_row }

  -- View 1 is the events-driven lead pet (the pet.lua singleton); any extras
  -- are independent instances that share the species' size/pace/personality.
  -- They start spread out across the floor so they don't all stack up.
  pet.init(start_col, start_row)
  pet.set_walk_period(config.walk_period or 2)
  if config.transitions then pet.set_transitions(config.transitions) end

  state.views = { { pet = pet.singleton(), cache = {}, cur_img = nil, frame_idx = 1 } }
  local span = math.max(1, state.float_cols - config.width)
  for i = 2, config.count do
    local pc = math.floor(span * (i - 1) / config.count)
    local sc, sr = find_free_spot(pc, start_row, taken)
    if not sc then sc, sr = pc, start_row end
    taken[#taken + 1] = { sc, sr }
    local inst = pet.new(sc, sr)
    inst:set_walk_period(config.walk_period or 2)
    if config.transitions then inst:set_transitions(config.transitions) end
    state.views[i] = { pet = inst, cache = {}, cur_img = nil, frame_idx = 1 }
  end

  for i, view in ipairs(state.views) do
    local frames = state.frames[view.pet:current_set()]
    if frames and frames[1] then
      local x, y = view.pet:col(), view.pet:row()
      local img = get_image(view, i, image, frames[1])
      pcall(function() img:render({ x = x, y = y }) end)
      view.cur_img = img
      view.last_path, view.last_x, view.last_y = frames[1], x, y
    end
  end

  state.image_mod = image
  state.paused = false
  state.last_motion = now_ms()  -- animate for a beat, then settle if idle
  start_timer(image)

  -- Let the lifestyle-event timers (events.lua) run only while the pet is
  -- actually on screen.
  vim.api.nvim_exec_autocmds("User", { pattern = "PetsShown", modeline = false })
end

-- Pop a small speech bubble just above the pet (sleep "zzz", save
-- reactions, LSP "!?", feeding hearts, ...). No-op when the pet isn't on
-- screen so callers don't have to guard.
function M.say(text, duration_ms)
  if not (state.float_row and state.float_col) then return end
  local pet_top_row = state.float_row + pet.row()
  local pet_left_col = state.float_col + pet.col()
  -- Sit the bubble above the pet; its border occupies one extra row, so go
  -- up a few rows. Fall back below the pet if there's no room above.
  local row = pet_top_row - 3
  if row < 0 then row = pet_top_row + config.height end
  bubble.show(text, row, pet_left_col, duration_ms)
end

-- Stop animating but leave everything on screen and in place. Used when nvim
-- loses focus (app switch, tmux window/session switch): we don't want to keep
-- issuing Kitty placements at a terminal that isn't showing us, but tearing
-- the float down instead — which is what this replaced — made the pets vanish
-- whenever you looked at another window and respawned them in the starting
-- corner when you came back.
function M.pause()
  if state.paused then return end
  state.paused = true
  stop_timer()
end

function M.resume()
  if not state.paused then return end
  state.paused = false
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end

  -- The terminal may have dropped our placements while we were away (tmux
  -- clears images for inactive windows), so force a full redraw rather than
  -- letting render_view skip it as an unchanged no-op.
  for _, view in ipairs(state.views) do
    view.last_path, view.last_x, view.last_y = nil, nil, nil
  end
  state.last_motion = now_ms()
  if state.image_mod then start_timer(state.image_mod) end
end

function M.is_paused() return state.paused == true end

function M.hide()
  stop_timer()
  state.paused = false
  bubble.hide()
  clear_all_views()
  clear_object_image()
  state.views = {}
  state.object = nil
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
  state.float_row, state.float_col = nil, nil
  state.float_cols, state.float_rows = nil, nil
  blocked.clear()

  vim.api.nvim_exec_autocmds("User", { pattern = "PetsHidden", modeline = false })
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

-- Direction the pet should face to "look at" the user: toward the cursor's
-- screen column relative to the pet's center. Replaces the old corner-based
-- guess, which was meaningless once the pet roams the whole editor. Falls
-- back to the corner heuristic when the pet isn't placed yet.
function M.peek_dir_toward_cursor()
  if not (state.float_col and pet.col) then
    return (config.area.corner == "br" or config.area.corner == "tr") and "left" or "right"
  end
  local pet_center = state.float_col + pet.col() + math.floor(config.width / 2)
  local cursor_col = vim.fn.screencol()
  return (cursor_col < pet_center) and "left" or "right"
end

-- Find a spot next to the cursor where the pet can stand and watch the
-- edit. Searches outward in rings from the cursor for a free feet-cell
-- (unblocked + inside the float bounds) and returns the corresponding pet
-- (col, row) plus the facing toward the cursor. Returns nil when the
-- cursor's neighbourhood is fully blocked or off the float.
-- Reaches further than it used to: the pet now needs a whole sprite-sized
-- clear rectangle rather than one free cell, and next to the line you're
-- editing that's usually a few cells further out.
local WATCH_SEARCH_RADIUS = 14
function M.cursor_watch_target()
  if not (state.float_row and state.float_col) then return nil end
  local foot_dx = math.floor(config.width / 2)
  local foot_dy = config.height - 1
  local cur_r = vim.fn.screenrow() - 1   -- 0-based screen row of the cursor
  local cur_c = vim.fn.screencol() - 1   -- 0-based screen col of the cursor
  local col_max = math.max(0, (state.float_cols or 0) - config.width)
  local row_max = math.max(0, (state.float_rows or 0) - config.height)

  for radius = 1, WATCH_SEARCH_RADIUS do
    -- Prefer cells on the cursor's own row (beside the edit), then rings.
    local offsets = {
      { 0,  radius }, { 0, -radius },
      { radius, 0 }, { -radius, 0 },
      { radius, radius }, { radius, -radius },
      { -radius, radius }, { -radius, -radius },
    }
    for _, off in ipairs(offsets) do
      local fr = cur_r + off[1]   -- candidate feet screen row
      local fc = cur_c + off[2]   -- candidate feet screen col
      local col = fc - state.float_col - foot_dx
      local row = fr - state.float_row - foot_dy
      if col >= 0 and col <= col_max and row >= 0 and row <= row_max
          and not footprint_blocked(col, row) then
        local face = (cur_c > fc) and "right" or "left"
        return col, row, face
      end
    end
  end
  return nil
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

-- Set how many pets roam at once (clamped to [1, MAX_PETS]); re-shows so
-- the new flock is built immediately.
function M.set_count(n)
  n = tonumber(n)
  if not n then
    vim.notify("nvim-pets: count must be a number", vim.log.levels.WARN)
    return
  end
  config.count = math.max(1, math.min(MAX_PETS, math.floor(n)))
  apply_config()
end

function M.count() return config.count end

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

-- Object x (in float columns) directly under the cursor, clamped so the
-- whole sprite stays inside the wander box. Used by the ball-throw command
-- so the ball lands where you're looking. Falls back to a random x when the
-- float position isn't known yet.
function M.cursor_object_x()
  local def = OBJECTS.ball
  local max_x = math.max(0, effective_cols() - def.width)
  if not state.float_col then return math.random(0, max_x) end
  local x = (vim.fn.screencol() - 1) - state.float_col
  return math.max(0, math.min(x, max_x))
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

-- Send the whole flock after the object, not just the events-driven lead pet.
-- Each extra pet aims a sprite-width to the side of the ball, alternating
-- left and right, so they converge on it instead of stacking on one cell.
-- Returns true when at least one pet was free to start running.
function M.approach_object_all(x, target_row, ticks)
  local col_max = math.max(0, effective_cols() - config.width)
  local started = false
  for i, view in ipairs(state.views) do
    local slot = math.floor(i / 2)
    local side = (i % 2 == 0) and 1 or -1
    local target = x + side * slot * (config.width + 1)
    target = math.max(0, math.min(target, col_max))
    if view.pet:approach_to(target, ticks, target_row) then started = true end
  end
  return started
end

-- True while any pet is still busy with the current object.
function M.any_object_busy() return any_object_busy() end

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
    "pet=%s count=%d action=%s dir=%s pos=(%d,%d) size=%dx%d area=%s(%dx%d)",
    config.pet, config.count, pet.action(), pet.dir(), pet.row(), pet.col(),
    config.width, config.height,
    config.area.corner, config.area.cols, config.area.rows
  )
end

return M
