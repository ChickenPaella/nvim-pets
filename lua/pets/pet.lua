-- Pure data/logic module: holds pet state and decides transitions.
-- No nvim API or image.nvim calls here so it stays easy to reason about.
--
-- Coordinates (col, row) are absolute screen cells. The renderer is
-- responsible for placing the float window so that those coordinates
-- map to the pet's on-screen position.

local M = {}

-- Tick rate constants (master timer fires at 8fps = 125ms per tick).
local DECISION_PERIOD = 24 -- ~3 seconds between wander decisions
local WALK_PERIOD = 2      -- 1 cell per ~250ms while walking
local RUN_PERIOD = 1       -- 1 cell per ~125ms while running
local BARK_TICKS = 12      -- ~1.5s of barking on arrival
local BARK_FLIP = 2        -- direction flip every 2 ticks (~4Hz wiggle)

local TRANSITIONS = {
  idle = { idle = 0.60, walk = 0.35, lie = 0.05 },
  walk = { walk = 0.75, idle = 0.20, lie = 0.05 },
  lie  = { lie = 0.70, idle = 0.30 },
}

local state = {
  action = "idle",       -- idle/walk/lie/running/barking/returning
  dir = "right",         -- left/right
  col = 0,               -- absolute screen column
  row = 0,               -- absolute screen row
  decision_throttle = 0,
  walk_throttle = 0,
  run_throttle = 0,
  bark_remaining = 0,
  bark_flip_throttle = 0,
  target_row = 0,        -- destination while running
  target_col = 0,
  home_row = 0,          -- where to return after barking
  home_col = 0,
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
  state.home_col = start_col
  state.home_row = start_row
  state.decision_throttle = 0
  state.walk_throttle = 0
  state.run_throttle = 0
  state.bark_remaining = 0
  state.bark_flip_throttle = 0
end

function M.action() return state.action end
function M.dir()    return state.dir    end
function M.col()    return state.col    end
function M.row()    return state.row    end

function M.is_busy()
  return state.action == "running"
      or state.action == "barking"
      or state.action == "returning"
end

function M.current_set()
  -- running/returning use the walk sprite; barking reuses idle frames and
  -- the wiggle (rapid dir flips) carries the visual signal of barking.
  local action = state.action
  if action == "running" or action == "returning" then
    action = "walk"
  elseif action == "barking" then
    action = "idle"
  end
  return action .. (state.dir == "left" and "_l" or "_r")
end

-- External entry: kick off a run-to-target reaction.
-- (target_row, target_col) are absolute screen cells. The pet remembers
-- its current position as "home" so it can return after barking.
function M.start_run_to(target_row, target_col)
  if M.is_busy() then return end
  state.home_row = state.row
  state.home_col = state.col
  state.target_row = target_row
  state.target_col = target_col
  state.action = "running"
  state.dir = (target_col < state.col) and "left" or "right"
  state.run_throttle = 0
end

local function step_toward(target_r, target_c)
  local dr = (state.row < target_r) and 1 or (state.row > target_r) and -1 or 0
  local dc = (state.col < target_c) and 1 or (state.col > target_c) and -1 or 0
  state.row = state.row + dr
  state.col = state.col + dc
  if dc < 0 then state.dir = "left"
  elseif dc > 0 then state.dir = "right" end
  return state.row == target_r and state.col == target_c
end

local function tick_running()
  state.run_throttle = state.run_throttle + 1
  if state.run_throttle < RUN_PERIOD then return end
  state.run_throttle = 0
  if step_toward(state.target_row, state.target_col) then
    state.action = "barking"
    state.bark_remaining = BARK_TICKS
    state.bark_flip_throttle = 0
  end
end

local function tick_barking()
  state.bark_remaining = state.bark_remaining - 1
  state.bark_flip_throttle = state.bark_flip_throttle + 1
  if state.bark_flip_throttle >= BARK_FLIP then
    state.bark_flip_throttle = 0
    flip_dir()
  end
  if state.bark_remaining <= 0 then
    state.action = "returning"
    state.dir = (state.home_col < state.col) and "left" or "right"
    state.run_throttle = 0
  end
end

local function tick_returning()
  state.run_throttle = state.run_throttle + 1
  if state.run_throttle < RUN_PERIOD then return end
  state.run_throttle = 0
  if step_toward(state.home_row, state.home_col) then
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

function M.tick(bounds)
  if state.action == "running"  then return tick_running()  end
  if state.action == "barking"  then return tick_barking()  end
  if state.action == "returning" then return tick_returning() end

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
