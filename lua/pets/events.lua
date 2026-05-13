-- Lifestyle events that make the pet feel alive without leaving its
-- wander box: react to the user saving a file, drift to sleep when the
-- user goes idle for a long time, surface a small random "wiggle"
-- every few minutes, and auto-hide when nvim loses focus so a stale
-- Kitty placement doesn't pile up while the terminal redraws (tmux
-- pane moves, app switches).

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
local ACTIVITY_THROTTLE_S = 1       -- record_activity at most once per second
local FOCUS_RESHOW_DELAY_MS = 150   -- defer auto-show after FocusGained

local last_activity_at = os.time()
local last_recorded_at = 0
local was_visible_before_blur = false

local idle_timer = nil
local wiggle_timer = nil
local focus_reshow_timer = nil

local function peek_dir()
  local c = renderer.corner and renderer.corner() or "br"
  if c == "br" or c == "tr" then return "left" end
  return "right"
end

local function mark_active()
  local now = os.time()
  last_recorded_at = now
  last_activity_at = now
end

-- Throttled: record_activity is wired to high-frequency autocmds
-- (TextChanged, CursorMoved, ...). Coalescing to once per second keeps the
-- main loop quiet during heavy editing.
local function record_activity()
  if os.time() - last_recorded_at < ACTIVITY_THROTTLE_S then return end
  mark_active()
  if pet.is_sleeping() then
    pet.wake()
  end
end

local function on_save()
  if not renderer.is_visible() then return end
  mark_active()
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
  stop_timer(focus_reshow_timer)
  idle_timer = nil
  wiggle_timer = nil
  focus_reshow_timer = nil
end

-- On focus loss (tmux pane move, app switch, etc.) we tear the float
-- down completely so image.nvim's Kitty placement doesn't accumulate
-- stale state during terminal redraws — that's what was producing the
-- "ghost copy + freeze" symptom. We remember whether the pet was on
-- and bring it back automatically when focus returns.
local function on_focus_lost()
  if not renderer.is_visible() then
    was_visible_before_blur = false
    return
  end
  was_visible_before_blur = true
  pcall(renderer.hide)
end

local function on_focus_gained()
  if not was_visible_before_blur then return end
  was_visible_before_blur = false
  stop_timer(focus_reshow_timer)
  focus_reshow_timer = vim.uv.new_timer()
  focus_reshow_timer:start(FOCUS_RESHOW_DELAY_MS, 0, vim.schedule_wrap(function()
    pcall(renderer.show)
  end))
end

function M.setup()
  last_activity_at = os.time()
  last_recorded_at = last_activity_at

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

  vim.api.nvim_create_autocmd("FocusLost", {
    group = group,
    callback = function() pcall(on_focus_lost) end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function() pcall(on_focus_gained) end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = stop_all_timers,
  })

  start_idle_timer()
  schedule_next_wiggle()
end

-- Test/debug entry points used by :Pets* commands.
function M.trigger_peek()   pet.peek(peek_dir(), PEEK_TICKS) end
function M.trigger_wiggle() pet.wiggle(WIGGLE_TICKS) end
function M.trigger_sleep()  pet.sleep() end
function M.trigger_wake()   pet.wake() end

return M
