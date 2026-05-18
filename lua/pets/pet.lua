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
  decision_throttle = 0,
  walk_throttle = 0,
  transient_remaining = 0, -- countdown for peek/wiggle/swipe/interacting
  wiggle_flip_throttle = 0,
  target_col = 0,          -- destination while approaching
  interact_ticks = 0,      -- how long to interact once we arrive
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

-- Walk toward target_col, then auto-transition into interacting for
-- interact_ticks before returning to idle. Caller (events.lua) uses this
-- when an environment object spawns and the pet should engage with it.
function M.approach_to(target_col, interact_ticks)
  if M.is_busy() then return false end
  state.action = "approaching"
  state.target_col = target_col
  state.interact_ticks = interact_ticks or 24
  state.dir = (target_col < state.col) and "left" or "right"
  state.walk_throttle = 0
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

local function tick_approaching()
  state.walk_throttle = state.walk_throttle + 1
  if state.walk_throttle < walk_period then return end
  state.walk_throttle = 0

  if state.col == state.target_col then
    -- Arrived: switch to interacting using the same transient countdown
    -- machinery as swipe / wiggle.
    state.action = "interacting"
    state.transient_remaining = state.interact_ticks
    return
  end

  local dx = (state.col < state.target_col) and 1 or -1
  state.col = state.col + dx
  state.dir = (dx == -1) and "left" or "right"
end

function M.tick(bounds)
  if state.action == "approaching" then return tick_approaching() end
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
      try_move(bounds)
    end
  end
end

return M
