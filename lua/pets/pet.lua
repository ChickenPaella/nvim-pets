-- Pure data/logic module: holds pet state and decides transitions.
-- No nvim API or image.nvim calls here so it stays easy to reason about.

local M = {}

-- Tick rate constants (master timer fires at 8fps = 125ms per tick).
local DECISION_PERIOD = 24  -- ~3s between wander decisions
local WALK_PERIOD = 2       -- 1 cell per ~250ms while walking
local ALERT_TICKS = 24      -- ~3s of alerted behavior on a new diagnostic
local ALERT_FLIP_PERIOD = 4 -- direction reversal every ~500ms while alerted

-- Transition probability tables; rows must each sum to 1.0.
local TRANSITIONS = {
  idle = { idle = 0.60, walk = 0.35, lie = 0.05 },
  walk = { walk = 0.75, idle = 0.20, lie = 0.05 },
  lie  = { lie = 0.70, idle = 0.30 },
}

local state = {
  action = "idle",  -- idle / walk / lie / alerted
  dir = "right",
  col = 0,
  row = 0,
  decision_throttle = 0,
  walk_throttle = 0,
  alert_remaining = 0,
  alert_flip_throttle = 0,
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
  state.decision_throttle = 0
  state.walk_throttle = 0
  state.alert_remaining = 0
  state.alert_flip_throttle = 0
end

function M.action() return state.action end
function M.dir()    return state.dir    end
function M.col()    return state.col    end
function M.row()    return state.row    end

function M.is_alerted() return state.action == "alerted" end

function M.current_set()
  -- "alerted" reuses the walk frames; the rapid dir-flip + per-tick movement
  -- is what makes it visually distinct from a normal walk.
  local action = (state.action == "alerted") and "walk" or state.action
  return action .. (state.dir == "left" and "_l" or "_r")
end

function M.start_alert()
  if state.action == "alerted" then return end
  state.action = "alerted"
  state.alert_remaining = ALERT_TICKS
  state.alert_flip_throttle = 0
end

local function decide()
  local probs = TRANSITIONS[state.action]
  if not probs then return end
  local next_action = pick(probs)
  if next_action == "walk" and state.action ~= "walk" then
    state.dir = (math.random() < 0.5) and "left" or "right"
  elseif (next_action == "idle" or next_action == "lie") and math.random() < 0.3 then
    flip_dir()
  end
  state.action = next_action
end

local function try_move(bounds)
  local dx = (state.dir == "left") and -1 or 1
  local new_col = state.col + dx
  if new_col < bounds.col_min then
    state.dir = "right"
    new_col = state.col + 1
  elseif new_col > bounds.col_max then
    state.dir = "left"
    new_col = state.col - 1
  end
  state.col = new_col
end

local function tick_alerted(bounds)
  state.alert_remaining = state.alert_remaining - 1

  state.alert_flip_throttle = state.alert_flip_throttle + 1
  if state.alert_flip_throttle >= ALERT_FLIP_PERIOD then
    state.alert_flip_throttle = 0
    flip_dir()
  end

  -- Move every tick (twice as fast as a normal walk) so the pet looks
  -- visibly agitated in the corner of your eye without leaving the box.
  try_move(bounds)

  if state.alert_remaining <= 0 then
    state.action = "idle"
    state.decision_throttle = 0
    state.walk_throttle = 0
  end
end

function M.tick(bounds)
  if state.action == "alerted" then return tick_alerted(bounds) end

  state.decision_throttle = state.decision_throttle + 1
  if state.decision_throttle >= DECISION_PERIOD then
    state.decision_throttle = 0
    decide()
  end

  if state.action == "walk" then
    state.walk_throttle = state.walk_throttle + 1
    if state.walk_throttle >= WALK_PERIOD then
      state.walk_throttle = 0
      try_move(bounds)
    end
  end
end

return M
