-- Pure data/logic module: holds pet state and decides transitions.
-- No nvim API or image.nvim calls here so it stays easy to reason about.

local M = {}

-- Tick rate constants (master timer fires at 8fps = 125ms per tick).
local DECISION_PERIOD = 24       -- ~3s between wander decisions
local WIGGLE_FLIP_PERIOD = 2     -- dir flip every 250ms during wiggle

-- Cells per master tick = 1 / walk_period. Renderer overrides this per
-- species (turtle is much slower than fox, etc.).
local walk_period = 2

-- Default wander transition table; rows must each sum to 1.0. Renderer
-- can override per species via set_transitions() to flavor each pet's
-- personality (more or less lazy, more or less restless).
local TRANSITIONS = {
  idle = { idle = 0.60, walk = 0.35, lie = 0.05 },
  walk = { walk = 0.75, idle = 0.20, lie = 0.05 },
  lie  = { lie = 0.70, idle = 0.30 },
}

local state = {
  action = "idle", -- idle / walk / lie / peek / wiggle / swipe / sleep / approaching / interacting
  dir = "right",
  col = 0,
  row = 0,
  dx = 0,                  -- last walk delta (col), drives momentum
  dy = 0,                  -- last walk delta (row)
  decision_throttle = 0,
  walk_throttle = 0,
  transient_remaining = 0, -- countdown for peek/wiggle/swipe/interacting
  wiggle_flip_throttle = 0,
  target_col = 0,          -- destination while approaching
  target_row = 0,
  interact_ticks = 0,      -- how long to interact once we arrive
  approach_stuck_ticks = 0,
}

local function pick(probs)
  local r = math.random()
  local cum = 0
  for next_action, p in pairs(probs) do
    cum = cum + p
    if r < cum then return next_action end
  end
  for k, _ in pairs(probs) do return k end
end

local function flip_dir()
  state.dir = (state.dir == "left") and "right" or "left"
end

function M.init(start_col, start_row)
  math.randomseed(os.time())
  state.action = "idle"
  state.dir = "right"
  state.col = start_col
  state.row = start_row
  state.dx = 0
  state.dy = 0
  state.decision_throttle = 0
  state.walk_throttle = 0
  state.transient_remaining = 0
  state.wiggle_flip_throttle = 0
  state.approach_stuck_ticks = 0
end

function M.action() return state.action end
function M.dir()    return state.dir    end
function M.col()    return state.col    end
function M.row()    return state.row    end

-- Renderer calls this on show() / species switch so each pet can carry
-- its own pace (turtle slower than fox, etc.).
function M.set_walk_period(n)
  if type(n) == "number" and n >= 1 then
    walk_period = math.floor(n)
  end
end

-- Renderer injects a species-specific wander transition table here.
function M.set_transitions(t)
  if type(t) == "table" then
    TRANSITIONS = t
  end
end

function M.is_sleeping() return state.action == "sleep" end
function M.is_busy()
  return state.action == "peek"
      or state.action == "wiggle"
      or state.action == "swipe"
      or state.action == "sleep"
      or state.action == "approaching"
      or state.action == "interacting"
end
function M.is_object_busy()
  return state.action == "approaching" or state.action == "interacting"
end

function M.current_set()
  -- peek/wiggle reuse idle frames; sleep reuses lie; approaching reuses
  -- walk; interacting reuses swipe. Animation slot is decided here so
  -- the renderer doesn't need to know the lifecycle states.
  local action = state.action
  if action == "peek" or action == "wiggle" then
    action = "idle"
  elseif action == "sleep" then
    action = "lie"
  elseif action == "approaching" then
    action = "walk"
  elseif action == "interacting" then
    action = "swipe"
  end
  return action .. (state.dir == "left" and "_l" or "_r")
end

-- External entries: the events module triggers these.

-- Brief pause facing a chosen direction. Used for save reactions etc.
function M.peek(dir, ticks)
  if M.is_busy() then return end
  state.action = "peek"
  if dir == "left" or dir == "right" then state.dir = dir end
  state.transient_remaining = ticks or 8
end

-- Short head-shake (rapid left/right flips). Used for random micro-events.
function M.wiggle(ticks)
  if M.is_busy() then return end
  state.action = "wiggle"
  state.transient_remaining = ticks or 12
  state.wiggle_flip_throttle = 0
end

-- Species signature animation — plays the swipe sprite once. Caller picks
-- ticks long enough for at least one sprite cycle.
function M.swipe(ticks)
  if M.is_busy() then return end
  state.action = "swipe"
  state.transient_remaining = ticks or 12
end

-- Walk toward (target_col, target_row), then auto-transition into
-- interacting for interact_ticks before returning to idle. target_row
-- defaults to the pet's current row (horizontal-only approach).
function M.approach_to(target_col, interact_ticks, target_row)
  if M.is_busy() then return false end
  state.action = "approaching"
  state.target_col = target_col
  state.target_row = target_row or state.row
  state.interact_ticks = interact_ticks or 24
  state.dir = (target_col < state.col) and "left" or "right"
  state.walk_throttle = 0
  state.approach_stuck_ticks = 0
  return true
end

-- Long-form lying down. Stays until wake() is called.
function M.sleep()
  if M.is_busy() then return end
  state.action = "sleep"
end

function M.wake()
  if state.action == "sleep" then
    state.action = "idle"
    state.decision_throttle = 0
    state.walk_throttle = 0
  end
end

local function decide()
  local probs = TRANSITIONS[state.action]
  if not probs then return end
  local next_action = pick(probs)
  if next_action == "walk" and state.action ~= "walk" then
    state.dx = (math.random() < 0.5) and -1 or 1
    state.dy = math.random(-1, 1)
    state.dir = (state.dx == -1) and "left" or "right"
  elseif (next_action == "idle" or next_action == "lie") and math.random() < 0.3 then
    flip_dir()
  end
  state.action = next_action
end

-- Returns true if (col, row) is inside bounds and not blocked.
local function cell_ok(bounds, col, row)
  if col < bounds.col_min or col > bounds.col_max then return false end
  if row < bounds.row_min or row > bounds.row_max then return false end
  if bounds.is_blocked and bounds.is_blocked(col, row) then return false end
  return true
end

-- One step of free-roam wandering. The pet has momentum: with 70%
-- probability it keeps going in its current heading if that cell is
-- available, otherwise it picks a random valid neighbour. dx/dy each
-- live in {-1, 0, 1}; (0, 0) is excluded so the pet always moves when
-- it has a free neighbour.
local function step_8way(bounds)
  local cur_dx = state.dx
  local cur_dy = state.dy
  if cur_dx == 0 and cur_dy == 0 then
    cur_dx = (state.dir == "left") and -1 or 1
  end

  if cell_ok(bounds, state.col + cur_dx, state.row + cur_dy)
      and math.random() < 0.7 then
    state.col = state.col + cur_dx
    state.row = state.row + cur_dy
    if cur_dx ~= 0 then state.dir = (cur_dx == -1) and "left" or "right" end
    return
  end

  local candidates = {}
  for dx = -1, 1 do
    for dy = -1, 1 do
      if not (dx == 0 and dy == 0)
          and cell_ok(bounds, state.col + dx, state.row + dy) then
        candidates[#candidates + 1] = { dx, dy }
      end
    end
  end
  if #candidates == 0 then return end

  local pick = candidates[math.random(#candidates)]
  state.dx = pick[1]
  state.dy = pick[2]
  state.col = state.col + state.dx
  state.row = state.row + state.dy
  if state.dx ~= 0 then state.dir = (state.dx == -1) and "left" or "right" end
end

-- Greedy step toward (target_col, target_row). Tries diagonal first,
-- then axis-aligned fallbacks so the pet can shimmy around an obstacle.
-- Returns true if the target was reached, false otherwise. Sets a stuck
-- counter when no progress was possible so the caller can bail out.
local function step_toward_target(bounds)
  if state.col == state.target_col and state.row == state.target_row then
    return true
  end

  local dx = 0
  if state.col < state.target_col then dx = 1
  elseif state.col > state.target_col then dx = -1 end
  local dy = 0
  if state.row < state.target_row then dy = 1
  elseif state.row > state.target_row then dy = -1 end

  local function try_step(ddx, ddy)
    if ddx == 0 and ddy == 0 then return false end
    if not cell_ok(bounds, state.col + ddx, state.row + ddy) then return false end
    state.col = state.col + ddx
    state.row = state.row + ddy
    if ddx ~= 0 then state.dir = (ddx == -1) and "left" or "right" end
    state.approach_stuck_ticks = 0
    return true
  end

  if try_step(dx, dy) then return false end
  if try_step(dx, 0)  then return false end
  if try_step(0, dy)  then return false end

  state.approach_stuck_ticks = state.approach_stuck_ticks + 1
  return false
end

local function tick_transient()
  state.transient_remaining = state.transient_remaining - 1
  if state.action == "wiggle" then
    state.wiggle_flip_throttle = state.wiggle_flip_throttle + 1
    if state.wiggle_flip_throttle >= WIGGLE_FLIP_PERIOD then
      state.wiggle_flip_throttle = 0
      flip_dir()
    end
  end
  if state.transient_remaining <= 0 then
    state.action = "idle"
    state.decision_throttle = 0
    state.walk_throttle = 0
  end
end

-- Approaching keeps trying to reach (target_col, target_row). If the
-- path is blocked for a stretch of ticks we give up and return to idle
-- so an unreachable object doesn't strand the pet forever.
local APPROACH_STUCK_LIMIT = 16  -- ticks of no-progress before bailing

local function tick_approaching(bounds)
  state.walk_throttle = state.walk_throttle + 1
  if state.walk_throttle < walk_period then return end
  state.walk_throttle = 0

  if state.approach_stuck_ticks >= APPROACH_STUCK_LIMIT then
    state.action = "idle"
    state.approach_stuck_ticks = 0
    return
  end

  if step_toward_target(bounds) then
    state.action = "interacting"
    state.transient_remaining = state.interact_ticks
    state.approach_stuck_ticks = 0
  end
end

function M.tick(bounds)
  if state.action == "approaching" then return tick_approaching(bounds) end
  if state.action == "peek"
      or state.action == "wiggle"
      or state.action == "swipe"
      or state.action == "interacting" then
    return tick_transient()
  end
  if state.action == "sleep" then
    return -- frozen until wake()
  end

  state.decision_throttle = state.decision_throttle + 1
  if state.decision_throttle >= DECISION_PERIOD then
    state.decision_throttle = 0
    decide()
  end

  if state.action == "walk" then
    state.walk_throttle = state.walk_throttle + 1
    if state.walk_throttle >= walk_period then
      state.walk_throttle = 0
      step_8way(bounds)
    end
  end
end

return M
