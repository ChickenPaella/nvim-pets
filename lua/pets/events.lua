-- Lifestyle events that make the pet feel alive without leaving its
-- wander box: react to the user saving a file, drift to sleep when the
-- user goes idle for a long time, and surface a small random "wiggle"
-- every few minutes.
--
-- Nothing here generates new sprites — every behavior reuses the
-- existing idle / lie / walk frames and gets its character from
-- direction locking, dir-flip rhythm, or frozen state.

local M = {}

local pet = require("pets.pet")
local renderer = require("pets.renderer")

-- Tunables — kept here rather than in setup() so they're easy to find.
local PEEK_TICKS = 8                -- ~1s pause after :w
local WIGGLE_TICKS = 12             -- ~1.5s head-shake
local IDLE_THRESHOLD_S = 10 * 60    -- 10 minutes → drift to sleep
local IDLE_CHECK_INTERVAL_MS = 30 * 1000
local WIGGLE_BASE_S = 5 * 60        -- average gap between random wiggles
local WIGGLE_JITTER_S = 2 * 60      -- ± jitter so timing isn't predictable

local last_activity_at = os.time()
local idle_timer = nil
local wiggle_timer = nil

-- Pet faces away from the corner, so it appears to look at the user.
local function peek_dir()
  local c = renderer.corner and renderer.corner() or "br"
  if c == "br" or c == "tr" then return "left" end
  return "right"
end

local function record_activity()
  last_activity_at = os.time()
  if pet.is_sleeping() then
    pet.wake()
  end
end

local function on_save()
  if not renderer.is_visible() then return end
  record_activity()
  pet.peek(peek_dir(), PEEK_TICKS)
end

local function on_idle_check()
  if not renderer.is_visible() then return end
  if pet.is_sleeping() then return end
  if pet.is_busy() then return end
  if os.time() - last_activity_at >= IDLE_THRESHOLD_S then
    pet.sleep()
  end
end

local function stop_timer(t)
  if t then
    pcall(function() t:stop() end)
    pcall(function() t:close() end)
  end
end

local function schedule_next_wiggle()
  stop_timer(wiggle_timer)
  local jitter = math.random(-WIGGLE_JITTER_S, WIGGLE_JITTER_S)
  local delay_ms = math.max(60 * 1000, (WIGGLE_BASE_S + jitter) * 1000)
  wiggle_timer = vim.uv.new_timer()
  wiggle_timer:start(delay_ms, 0, vim.schedule_wrap(function()
    if renderer.is_visible() and not pet.is_sleeping() and not pet.is_busy() then
      pet.wiggle(WIGGLE_TICKS)
    end
    schedule_next_wiggle()
  end))
end

local function start_idle_timer()
  stop_timer(idle_timer)
  idle_timer = vim.uv.new_timer()
  idle_timer:start(
    IDLE_CHECK_INTERVAL_MS,
    IDLE_CHECK_INTERVAL_MS,
    vim.schedule_wrap(on_idle_check)
  )
end

local function stop_all_timers()
  stop_timer(idle_timer)
  stop_timer(wiggle_timer)
  idle_timer = nil
  wiggle_timer = nil
end

function M.setup()
  last_activity_at = os.time()

  local group = vim.api.nvim_create_augroup("nvim-pets-events", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function() pcall(on_save) end,
  })

  vim.api.nvim_create_autocmd({
    "CursorMoved", "CursorMovedI", "InsertEnter", "InsertLeave",
    "TextChanged", "TextChangedI",
  }, {
    group = group,
    callback = record_activity,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = stop_all_timers,
  })

  start_idle_timer()
  schedule_next_wiggle()
end

-- Test/debug entry points used by :Pets* commands.
function M.trigger_peek() pet.peek(peek_dir(), PEEK_TICKS) end
function M.trigger_wiggle() pet.wiggle(WIGGLE_TICKS) end
function M.trigger_sleep() pet.sleep() end
function M.trigger_wake() pet.wake() end

return M
