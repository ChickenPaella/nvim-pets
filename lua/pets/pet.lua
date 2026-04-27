-- Pure data/logic module: holds pet state and decides transitions.
-- No nvim API or image.nvim calls here so it stays easy to reason about.

local M = {}

-- Tick rate constants (in master ticks @ 8fps = 125ms each)
local DECISION_PERIOD = 24 -- ~3 seconds
local WALK_PERIOD = 2      -- ~250ms per cell while walking

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
}

local function pick(probs)
  local r = math.random()
  local cum = 0
  for next_action, p in pairs(probs) do
    cum = cum + p
    if r < cum then return next_action end
  end
  -- floating-point fallback: return last key
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
end

function M.action() return state.action end
function M.dir() return state.dir end
function M.col() return state.col end
function M.row() return state.row end

function M.current_set()
  return state.action .. (state.dir == "left" and "_l" or "_r")
end

local function decide()
  local probs = TRANSITIONS[state.action]
  if not probs then return end
  local next_action = pick(probs)
  if next_action == "walk" and state.action ~= "walk" then
    -- When starting to walk, randomize direction
    state.dir = (math.random() < 0.5) and "left" or "right"
  elseif (next_action == "idle" or next_action == "lie") and math.random() < 0.3 then
    -- Occasional idle/lie direction flip so the pet doesn't always face the
    -- same way while resting.
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

function M.tick(bounds)
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
