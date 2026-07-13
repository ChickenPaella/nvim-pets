-- Lightweight tamagotchi layer: the pet has a happiness value (0–100) that
-- slowly decays in real time and rises when you interact with it (feed,
-- play with the ball, let it watch you work). Persisted across sessions in
-- a small JSON file so the pet "remembers" how it was left.
--
-- Kept deliberately simple: one number, time-based decay computed on read
-- rather than a background timer.

local M = {}

local PATH = vim.fn.stdpath("data") .. "/nvim-pets-mood.json"
local DECAY_PER_HOUR = 2 -- happiness lost per real hour while you're away

local state = { happiness = 80, last = os.time() }

local function clamp(v) return math.max(0, math.min(100, v)) end

-- Subtract decay for the wall-clock time elapsed since we last touched the
-- value. Called before every read/write so happiness is always current.
local function apply_decay()
  local now = os.time()
  local hours = (now - state.last) / 3600
  if hours > 0 then
    state.happiness = clamp(state.happiness - hours * DECAY_PER_HOUR)
    state.last = now
  end
end

function M.load()
  local f = io.open(PATH, "r")
  if f then
    local content = f:read("*a")
    f:close()
    local ok, data = pcall(vim.json.decode, content)
    if ok and type(data) == "table" then
      state.happiness = clamp(tonumber(data.happiness) or state.happiness)
      state.last = tonumber(data.last) or os.time()
    end
  end
  apply_decay()
end

function M.save()
  apply_decay()
  local f = io.open(PATH, "w")
  if f then
    f:write(vim.json.encode({ happiness = math.floor(state.happiness), last = state.last }))
    f:close()
  end
end

function M.add(n)
  apply_decay()
  state.happiness = clamp(state.happiness + n)
  M.save()
end

function M.happiness()
  apply_decay()
  return math.floor(state.happiness)
end

function M.label()
  local h = M.happiness()
  if h >= 80 then return "happy" end
  if h >= 50 then return "content" end
  if h >= 25 then return "bored" end
  return "sad"
end

return M
