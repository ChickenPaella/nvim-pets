-- Pure data/logic module: holds pet state and decides transitions.
-- No nvim API or image.nvim calls here so it stays easy to reason about.

local M = {}

-- Tick rate constants (master timer fires at 8fps = 125ms per tick).
local DECISION_PERIOD = 24       -- ~3s between wander decisions
local WALK_PERIOD = 2            -- 1 cell per ~250ms while walking
local WIGGLE_FLIP_PERIOD = 2     -- dir flip every 250ms during wiggle

-- Transition probability tables; rows must each sum to 1.0.
local TRANSITIONS = {
  idle = { idle = 0.60, walk = 0.35, lie = 0.05 },
  walk = { walk = 0.75, idle = 0.20, lie = 0.05 },
  lie  = { lie = 0.70, idle = 0.30 },
}

local state = {
  action = "idle", -- idle / walk / lie / peek / wiggle / sleep
  dir = "right",
  col = 0,
  row = 0,
  decision_throttle = 0,
  walk_throttle = 0,
  transient_remaining = 0, -- countdown for peek/wiggle; sleep has no timer
  wiggle_flip_throttle = 0,
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
  state.transient_remaining = 0
  state.wiggle_flip_throttle = 0
end

function M.action() return state.action end
function M.dir()    return state.dir    end
function M.col()    return state.col    end
function M.row()    return state.row    end

function M.is_sleeping() return state.action == "sleep" end
function M.is_busy()
  return state.action == "peek"
      or state.action == "wiggle"
      or state.action == "sleep"
end

function M.current_set()
  -- peek/wiggle reuse the idle frames; sleep reuses lie.
  -- Visual difference comes from dir locking (peek), rapid dir flips
  -- (wiggle), and frozen state (sleep).
  local action = state.action
  if action == "peek" or action == "wiggle" then
    action = "idle"
  elseif action == "sleep" then
    action = "lie"
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

function M.tick(bounds)
  if state.action == "peek" or state.action == "wiggle" then
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
    if state.walk_throttle >= WALK_PERIOD then
      state.walk_throttle = 0
      try_move(bounds)
    end
  end
end

return M
