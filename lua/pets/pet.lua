-- Pure data/logic module: holds pet state and decides transitions.
-- No nvim API or image.nvim calls here so it stays easy to reason about.
--
-- Two ways to use it:
--   * the module-level singleton API (M.tick, M.peek, M.col, ...) — this is
--     the "lead" pet the events module drives, and keeps the original API so
--     events.lua never had to change;
--   * M.new() — an independent pet instance with the same methods, used by
--     the renderer to put a whole flock of pets on screen at once.
-- All behavior lives in shared local functions that take an explicit state
-- table, so the singleton and every instance run identical logic.

local M = {}

-- Tick rate constants. The master timer runs at config.fps (default 6fps
-- ≈ 166ms per tick), so the periods below are in ticks, not milliseconds.
local DECISION_PERIOD = 24       -- ~4s between wander decisions (at 6fps)
local WIGGLE_FLIP_PERIOD = 2     -- dir flip ~every 330ms during wiggle
local APPROACH_STUCK_LIMIT = 16  -- ticks of no-progress before bailing
local RELOCATE_TRIES = 40        -- random probes for open space when boxed in
local RELOCATE_COOLDOWN = 30     -- ticks before retrying after a failed sweep

-- Default wander transition table; rows must each sum to 1.0. The renderer
-- overrides this per species via set_transitions() to flavor each pet's
-- personality (more or less lazy, more or less restless).
local DEFAULT_TRANSITIONS = {
  idle = { idle = 0.60, walk = 0.35, lie = 0.05 },
  walk = { walk = 0.75, idle = 0.20, lie = 0.05 },
  lie  = { lie = 0.70, idle = 0.30 },
}

local function new_state(start_col, start_row)
  return {
    action = "idle", -- idle/walk/lie/peek/wiggle/swipe/sleep/approaching/interacting
    dir = "right",
    col = start_col or 0,
    row = start_row or 0,
    dx = 0,                  -- last walk delta (col), drives momentum
    dy = 0,                  -- last walk delta (row)
    decision_throttle = 0,
    walk_throttle = 0,
    transient_remaining = 0, -- countdown for peek/wiggle/swipe/interacting
    wiggle_flip_throttle = 0,
    target_col = 0,          -- destination while approaching
    target_row = 0,
    interact_ticks = 0,      -- how long to interact once we arrive
    arrive_action = "interact", -- "interact" (swipe) | "watch" (peek at cursor)
    arrive_face = nil,       -- forced facing on arrival (watch faces the cursor)
    approach_stuck_ticks = 0,
    relocate_cooldown = 0,   -- ticks to wait before re-attempting a relocate
    walk_period = 2,         -- master ticks per cell move (per species)
    transitions = DEFAULT_TRANSITIONS,
  }
end

local function pick(probs)
  local r = math.random()
  local cum = 0
  for next_action, p in pairs(probs) do
    cum = cum + p
    if r < cum then return next_action end
  end
  for k, _ in pairs(probs) do return k end
end

local function flip_dir(s)
  s.dir = (s.dir == "left") and "right" or "left"
end

-- Returns true if (col, row) is inside bounds and not blocked.
local function cell_ok(bounds, col, row)
  if col < bounds.col_min or col > bounds.col_max then return false end
  if row < bounds.row_min or row > bounds.row_max then return false end
  if bounds.is_blocked and bounds.is_blocked(col, row) then return false end
  return true
end

-- Boxed-in recovery. In a densely-filled buffer almost every cell holds
-- text, so the pet can walk into a pocket where all 8 neighbours are
-- blocked and then just stand there — the "roam the whole editor" promise
-- quietly stops working. When that happens we relocate the pet to a free
-- spot so it always has somewhere to go (the area right of line ends, blank
-- lines, and below the last line are reliably open).
local function place_at(s, col, row)
  if col ~= s.col then s.dir = (col < s.col) and "left" or "right" end
  s.col, s.row = col, row
  s.dx, s.dy = 0, 0
end

local function relocate_to_free(s, bounds)
  for _ = 1, RELOCATE_TRIES do
    local c = math.random(bounds.col_min, bounds.col_max)
    local r = math.random(bounds.row_min, bounds.row_max)
    if cell_ok(bounds, c, r) then
      place_at(s, c, r)
      return true
    end
  end

  -- Random probing gets unreliable now that a spot has to fit the pet's
  -- whole sprite rather than a single cell, so fall back to a deterministic
  -- sweep from the bottom-right — past the end of each line and below the
  -- last line is where a code buffer actually has room.
  for r = bounds.row_max, bounds.row_min, -1 do
    for c = bounds.col_max, bounds.col_min, -1 do
      if cell_ok(bounds, c, r) then
        place_at(s, c, r)
        return true
      end
    end
  end
  return false
end

-- One step of free-roam wandering. The pet has momentum: with 70%
-- probability it keeps going in its current heading if that cell is
-- available, otherwise it picks a random valid neighbour. dx/dy each live
-- in {-1, 0, 1}; (0, 0) is excluded so the pet always moves when it has a
-- free neighbour.
local function step_8way(s, bounds)
  local cur_dx = s.dx
  local cur_dy = s.dy
  if cur_dx == 0 and cur_dy == 0 then
    cur_dx = (s.dir == "left") and -1 or 1
  end

  if cell_ok(bounds, s.col + cur_dx, s.row + cur_dy)
      and math.random() < 0.7 then
    s.col = s.col + cur_dx
    s.row = s.row + cur_dy
    if cur_dx ~= 0 then s.dir = (cur_dx == -1) and "left" or "right" end
    return
  end

  local candidates = {}
  for dx = -1, 1 do
    for dy = -1, 1 do
      if not (dx == 0 and dy == 0)
          and cell_ok(bounds, s.col + dx, s.row + dy) then
        candidates[#candidates + 1] = { dx, dy }
      end
    end
  end
  if #candidates == 0 then
    -- Boxed in by text on every side: scurry to open space instead of
    -- freezing in place. When even the sweep finds nothing (a screen with no
    -- sprite-sized gap left at all) back off for a while — retrying the full
    -- sweep on every tick would burn CPU for no gain.
    if s.relocate_cooldown > 0 then
      s.relocate_cooldown = s.relocate_cooldown - 1
      return
    end
    if not relocate_to_free(s, bounds) then
      s.relocate_cooldown = RELOCATE_COOLDOWN
    end
    return
  end

  local choice = candidates[math.random(#candidates)]
  s.dx = choice[1]
  s.dy = choice[2]
  s.col = s.col + s.dx
  s.row = s.row + s.dy
  if s.dx ~= 0 then s.dir = (s.dx == -1) and "left" or "right" end
end

-- Greedy step toward (target_col, target_row). Tries diagonal first, then
-- axis-aligned fallbacks so the pet can shimmy around an obstacle. Returns
-- true if the target was reached. Sets a stuck counter when no progress was
-- possible so the caller can bail out.
local function step_toward_target(s, bounds)
  if s.col == s.target_col and s.row == s.target_row then
    return true
  end

  local dx = 0
  if s.col < s.target_col then dx = 1
  elseif s.col > s.target_col then dx = -1 end
  local dy = 0
  if s.row < s.target_row then dy = 1
  elseif s.row > s.target_row then dy = -1 end

  local function try_step(ddx, ddy)
    if ddx == 0 and ddy == 0 then return false end
    if not cell_ok(bounds, s.col + ddx, s.row + ddy) then return false end
    s.col = s.col + ddx
    s.row = s.row + ddy
    if ddx ~= 0 then s.dir = (ddx == -1) and "left" or "right" end
    s.approach_stuck_ticks = 0
    return true
  end

  if try_step(dx, dy) then return false end
  if try_step(dx, 0)  then return false end
  if try_step(0, dy)  then return false end

  s.approach_stuck_ticks = s.approach_stuck_ticks + 1
  return false
end

local function decide(s)
  local probs = s.transitions[s.action]
  if not probs then return end
  local next_action = pick(probs)
  if next_action == "walk" and s.action ~= "walk" then
    s.dx = (math.random() < 0.5) and -1 or 1
    s.dy = math.random(-1, 1)
    s.dir = (s.dx == -1) and "left" or "right"
  elseif (next_action == "idle" or next_action == "lie") and math.random() < 0.3 then
    flip_dir(s)
  end
  s.action = next_action
end

local function tick_transient(s)
  s.transient_remaining = s.transient_remaining - 1
  if s.action == "wiggle" then
    s.wiggle_flip_throttle = s.wiggle_flip_throttle + 1
    if s.wiggle_flip_throttle >= WIGGLE_FLIP_PERIOD then
      s.wiggle_flip_throttle = 0
      flip_dir(s)
    end
  end
  if s.transient_remaining <= 0 then
    s.action = "idle"
    s.decision_throttle = 0
    s.walk_throttle = 0
  end
end

-- Approaching keeps trying to reach (target_col, target_row). If the path
-- is blocked for a stretch of ticks we give up and return to idle so an
-- unreachable object doesn't strand the pet forever.
local function tick_approaching(s, bounds)
  s.walk_throttle = s.walk_throttle + 1
  if s.walk_throttle < s.walk_period then return end
  s.walk_throttle = 0

  if s.approach_stuck_ticks >= APPROACH_STUCK_LIMIT then
    s.action = "idle"
    s.approach_stuck_ticks = 0
    return
  end

  if step_toward_target(s, bounds) then
    if s.arrive_face then s.dir = s.arrive_face end
    s.action = (s.arrive_action == "watch") and "peek" or "interacting"
    s.transient_remaining = s.interact_ticks
    s.approach_stuck_ticks = 0
  end
end

-- Text can appear *under* a pet that is standing still — you type a long
-- line right where it happens to be resting — and nothing in the wander
-- logic would notice, because the footprint is only ever checked when the
-- pet tries to move. It would sit on top of your code until it next decided
-- to walk, which breaks the one thing this plugin promises.
--
-- So: the moment a pet's own footprint stops being clear, move it. A single
-- step is enough when a line merely grew; when the whole neighbourhood
-- filled up, step_8way finds no candidate and relocates instead. Pets in
-- the middle of walking to or playing with an object are left alone — they
-- have a destination, and get re-checked when they're done.
local function tick_displaced(s, bounds)
  if not (bounds.is_blocked and bounds.is_blocked(s.col, s.row)) then
    return false
  end
  if s.action == "approaching" or s.action == "interacting" then return false end
  if s.action == "sleep" then s.action = "idle" end
  step_8way(s, bounds)
  return true
end

local function do_tick(s, bounds)
  if tick_displaced(s, bounds) then return end
  if s.action == "approaching" then return tick_approaching(s, bounds) end
  if s.action == "peek"
      or s.action == "wiggle"
      or s.action == "swipe"
      or s.action == "interacting" then
    return tick_transient(s)
  end
  if s.action == "sleep" then
    return -- frozen until wake()
  end

  s.decision_throttle = s.decision_throttle + 1
  if s.decision_throttle >= DECISION_PERIOD then
    s.decision_throttle = 0
    decide(s)
  end

  if s.action == "walk" then
    s.walk_throttle = s.walk_throttle + 1
    if s.walk_throttle >= s.walk_period then
      s.walk_throttle = 0
      step_8way(s, bounds)
    end
  end
end

local function is_busy(s)
  return s.action == "peek"
      or s.action == "wiggle"
      or s.action == "swipe"
      or s.action == "sleep"
      or s.action == "approaching"
      or s.action == "interacting"
end

local function current_set(s)
  -- peek/wiggle reuse idle frames; sleep reuses lie; approaching reuses
  -- walk; interacting reuses swipe. Animation slot is decided here so the
  -- renderer doesn't need to know the lifecycle states.
  local action = s.action
  if action == "peek" or action == "wiggle" then
    action = "idle"
  elseif action == "sleep" then
    action = "lie"
  elseif action == "approaching" then
    action = "walk"
  elseif action == "interacting" then
    action = "swipe"
  end
  return action .. (s.dir == "left" and "_l" or "_r")
end

-- ── Instance methods ────────────────────────────────────────────────────

local Pet = {}
Pet.__index = Pet

function Pet:tick(bounds) do_tick(self.s, bounds) end

function Pet:action() return self.s.action end
function Pet:dir()    return self.s.dir    end
function Pet:col()    return self.s.col    end
function Pet:row()    return self.s.row    end

function Pet:set_walk_period(n)
  if type(n) == "number" and n >= 1 then self.s.walk_period = math.floor(n) end
end

function Pet:set_transitions(t)
  if type(t) == "table" then self.s.transitions = t end
end

function Pet:is_sleeping() return self.s.action == "sleep" end
function Pet:is_busy()     return is_busy(self.s) end
function Pet:is_object_busy()
  return self.s.action == "approaching" or self.s.action == "interacting"
end
function Pet:current_set() return current_set(self.s) end

-- Brief pause facing a chosen direction. Used for save reactions etc.
function Pet:peek(dir, ticks)
  if is_busy(self.s) then return end
  self.s.action = "peek"
  if dir == "left" or dir == "right" then self.s.dir = dir end
  self.s.transient_remaining = ticks or 8
end

-- Short head-shake (rapid left/right flips). Used for random micro-events.
function Pet:wiggle(ticks)
  if is_busy(self.s) then return end
  self.s.action = "wiggle"
  self.s.transient_remaining = ticks or 12
  self.s.wiggle_flip_throttle = 0
end

-- Species signature animation — plays the swipe sprite once.
function Pet:swipe(ticks)
  if is_busy(self.s) then return end
  self.s.action = "swipe"
  self.s.transient_remaining = ticks or 12
end

-- Walk toward (target_col, target_row), then auto-transition into an
-- arrival action for arrive_ticks before returning to idle:
--   "interact" (default) → plays the swipe sprite (object play)
--   "watch"              → holds a peek/idle pose, used to look at the cursor
-- arrive_face, when given, overrides the facing on arrival so a watching
-- pet faces the cursor rather than its last walking direction.
function Pet:approach_to(target_col, arrive_ticks, target_row, arrive_action, arrive_face)
  if is_busy(self.s) then return false end
  local s = self.s
  s.action = "approaching"
  s.target_col = target_col
  s.target_row = target_row or s.row
  s.interact_ticks = arrive_ticks or 24
  s.arrive_action = arrive_action or "interact"
  s.arrive_face = (arrive_face == "left" or arrive_face == "right") and arrive_face or nil
  s.dir = (target_col < s.col) and "left" or "right"
  s.walk_throttle = 0
  s.approach_stuck_ticks = 0
  return true
end

-- Long-form lying down. Stays until wake() is called.
function Pet:sleep()
  if is_busy(self.s) then return end
  self.s.action = "sleep"
end

function Pet:wake()
  if self.s.action == "sleep" then
    self.s.action = "idle"
    self.s.decision_throttle = 0
    self.s.walk_throttle = 0
  end
end

-- Glance toward a column if idle, without disturbing any other state. Used
-- for the "two pets notice each other" touch when a flock clusters.
function Pet:look_at(col)
  if self.s.action == "idle" and col ~= self.s.col then
    self.s.dir = (col < self.s.col) and "left" or "right"
  end
end

-- Reset to a fresh wandering state at (start_col, start_row), keeping the
-- per-instance walk_period / transitions.
function Pet:reset(start_col, start_row)
  local wp, tr = self.s.walk_period, self.s.transitions
  self.s = new_state(start_col, start_row)
  self.s.walk_period = wp
  self.s.transitions = tr
end

function M.new(start_col, start_row)
  return setmetatable({ s = new_state(start_col, start_row) }, Pet)
end

-- ── Singleton (the lead pet the events module drives) ───────────────────

local singleton = M.new(0, 0)

function M.init(start_col, start_row)
  -- hrtime() (nanoseconds) instead of os.time() (whole seconds) so rapid
  -- toggles don't reseed to the same value and replay identical wandering.
  math.randomseed((vim.uv or vim.loop).hrtime() % 2147483647)
  singleton:reset(start_col, start_row)
end

function M.singleton() return singleton end

M.tick              = function(b) return singleton:tick(b) end
M.action            = function() return singleton:action() end
M.dir               = function() return singleton:dir() end
M.col               = function() return singleton:col() end
M.row               = function() return singleton:row() end
M.set_walk_period   = function(n) return singleton:set_walk_period(n) end
M.set_transitions   = function(t) return singleton:set_transitions(t) end
M.is_sleeping       = function() return singleton:is_sleeping() end
M.is_busy           = function() return singleton:is_busy() end
M.is_object_busy    = function() return singleton:is_object_busy() end
M.current_set       = function() return singleton:current_set() end
M.peek              = function(dir, ticks) return singleton:peek(dir, ticks) end
M.wiggle            = function(ticks) return singleton:wiggle(ticks) end
M.swipe             = function(ticks) return singleton:swipe(ticks) end
M.approach_to       = function(...) return singleton:approach_to(...) end
M.sleep             = function() return singleton:sleep() end
M.wake              = function() return singleton:wake() end

return M
