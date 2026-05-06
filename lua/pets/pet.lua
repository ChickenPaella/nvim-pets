-- Pure data/logic module: holds pet state and decides transitions.
-- No nvim API or image.nvim calls here so it stays easy to reason about.

local M = {}

-- Tick rate constants (in master ticks @ 8fps = 125ms each)
local DECISION_PERIOD = 24 -- ~3 seconds
local WALK_PERIOD = 2      -- ~250ms per cell while walking
local ALERT_TICKS = 16     -- ~2 seconds for an alert reaction

-- Transition probability tables; rows must each sum to 1.0.
local TRANSITIONS = {
  idle = { idle = 0.60, walk = 0.35, lie = 0.05 },
  walk = { walk = 0.75, idle = 0.20, lie = 0.05 },
  lie  = { lie = 0.70, idle = 0.30 }, -- lie -> walk feels jarring; require idle first
}

local state = {
  action = "idle",
  dir = "right",
  col = 0,
  row = 0,
  decision_throttle = 0,
  walk_throttle = 0,
  alert_remaining = 0,
  -- Saved state to restore after alert completes.
  pre_alert = nil, -- { action, dir, col, row }
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
  state.pre_alert = nil
end

function M.action() return state.action end
function M.dir() return state.dir end
function M.col() return state.col end
function M.row() return state.row end
function M.is_alert() return state.action == "alert" end

function M.current_set()
  -- Alert reuses idle frames; the visual difference is the exclaim overlay
  -- rendered alongside, plus the absolute screen position.
  local action = (state.action == "alert") and "idle" or state.action
  return action .. (state.dir == "left" and "_l" or "_r")
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

-- Enter alert mode: teleport to (row, col), pause wandering for ALERT_TICKS,
-- then auto-restore to whatever we were doing before.
-- target_dir is optional — if given, the pet faces that way during alert.
function M.enter_alert(target_row, target_col, target_dir)
  state.pre_alert = {
    action = state.action,
    dir = state.dir,
    col = state.col,
    row = state.row,
  }
  state.action = "alert"
  state.row = target_row
  state.col = target_col
  if target_dir == "left" or target_dir == "right" then
    state.dir = target_dir
  end
  state.alert_remaining = ALERT_TICKS
  state.decision_throttle = 0
  state.walk_throttle = 0
end

local function exit_alert()
  if not state.pre_alert then
    state.action = "idle"
    return
  end
  state.action = state.pre_alert.action
  state.dir = state.pre_alert.dir
  state.col = state.pre_alert.col
  state.row = state.pre_alert.row
  state.pre_alert = nil
  state.alert_remaining = 0
  -- Reset throttles so we don't immediately re-decide right after returning.
  state.decision_throttle = 0
  state.walk_throttle = 0
  -- If pre-alert action wasn't a known wander state, fall back to idle.
  if not TRANSITIONS[state.action] then state.action = "idle" end
end

function M.tick(bounds)
  if state.action == "alert" then
    state.alert_remaining = state.alert_remaining - 1
    if state.alert_remaining <= 0 then
      exit_alert()
    end
    return
  end

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
