-- Lifestyle events that make the pet feel alive without leaving its
-- wander box: react to the user saving a file, drift to sleep when the
-- user goes idle for a long time, surface a small random "wiggle"
-- every few minutes, and auto-hide when nvim loses focus so a stale
-- Kitty placement doesn't pile up while the terminal redraws (tmux
-- pane moves, app switches).

local M = {}

local pet = require("pets.pet")
local renderer = require("pets.renderer")
local blocked = require("pets.blocked")
local mood = require("pets.mood")

-- Tunables — kept here rather than in setup() so they're easy to find.
local PEEK_TICKS = 8                -- ~1s pause after :w
local WIGGLE_TICKS = 12             -- ~1.5s head-shake
local SWIPE_TICKS = 12              -- ~1.5s species-signature animation
local IDLE_THRESHOLD_S = 10 * 60    -- 10 minutes → drift to sleep
local IDLE_THRESHOLD_NIGHT_S = 4 * 60 -- at night the pet nods off sooner
local IDLE_CHECK_INTERVAL_MS = 30 * 1000
local WIGGLE_BASE_S = 5 * 60        -- average gap between random wiggles
local WIGGLE_JITTER_S = 2 * 60      -- ± jitter so timing isn't predictable
local SWIPE_BASE_S = 90             -- average gap between species swipes (~1.5 min)
local SWIPE_JITTER_S = 30           -- ± jitter
local OBJECT_SPAWN_BASE_S = 3 * 60  -- average gap between environment-object spawns
local OBJECT_SPAWN_JITTER_S = 60
local OBJECT_INTERACT_TICKS = 24    -- ~3s of interaction once the pet arrives
local OBJECT_MIN_DISTANCE = 6       -- spawn at least N cells from the pet so it walks
local POMODORO_DEFAULT_MIN = 25     -- default focus session length
local MOOD_GAIN_PLAY = 8            -- happiness from a ball play session
local MOOD_GAIN_WATCH = 3           -- happiness from watching you work
local MOOD_GAIN_FEED = 25           -- happiness from a feed
local MOOD_GAIN_POMODORO = 10       -- happiness from finishing a focus session
local FOLLOW_BASE_S = 35            -- average gap between cursor-follow visits
local FOLLOW_JITTER_S = 15          -- ± jitter
local FOLLOW_RECENT_ACTIVITY_S = 20 -- only follow if the user edited within this window
local WATCH_TICKS = 16              -- ~2.6s of watching the cursor once arrived
local ACTIVITY_THROTTLE_S = 1       -- record_activity at most once per second
local FOCUS_RESHOW_DELAY_MS = 150   -- defer auto-show after FocusGained

local last_activity_at = os.time()
local last_recorded_at = 0
local was_visible_before_blur = false

local idle_timer = nil
local wiggle_timer = nil
local swipe_timer = nil
local object_timer = nil
local follow_timer = nil
local pomodoro_timer = nil
local focus_reshow_timer = nil

local prev_error_count = 0          -- for diagnostic-change reactions

local function is_night()
  local h = tonumber(os.date("%H"))
  return h ~= nil and (h >= 22 or h < 6)
end

local function peek_dir()
  if renderer.peek_dir_toward_cursor then
    return renderer.peek_dir_toward_cursor()
  end
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
  -- Unthrottled: wake the pets from "settled" the instant you do anything so
  -- resuming feels immediate. This is just a timestamp write, so it's cheap
  -- even on every cursor move.
  renderer.poke()
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
  -- Only chirp sometimes so it's a treat, not noise on every :w.
  if math.random() < 0.35 then renderer.say("saved!") end
end

local function on_idle_check()
  if not renderer.is_visible() then return end
  if pet.is_sleeping() then return end
  if pet.is_busy() then return end
  local threshold = is_night() and IDLE_THRESHOLD_NIGHT_S or IDLE_THRESHOLD_S
  if os.time() - last_activity_at >= threshold then
    pet.sleep()
    renderer.say("zzz", 3000)
  end
end

-- React to LSP error count changes: a small in-place fluster the moment
-- errors first appear, a happy swipe when the last one is cleared. This is
-- the gentle, never-leaves-its-spot version of diagnostic reactions (the
-- old run-to-the-error behavior was too disruptive and got reverted).
local function on_diagnostics()
  if not renderer.is_visible() then return end
  local errors = #vim.diagnostic.get(nil, { severity = vim.diagnostic.severity.ERROR })
  if not pet.is_busy() and not pet.is_sleeping() then
    if errors > 0 and prev_error_count == 0 then
      pet.wiggle(WIGGLE_TICKS)
      renderer.say("!?")
    elseif errors == 0 and prev_error_count > 0 then
      pet.swipe(SWIPE_TICKS)
      renderer.say("yay!")
    end
  end
  prev_error_count = errors
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
      -- A bored/sad pet sighs; a content one occasionally yawns.
      if mood.happiness() < 25 then
        renderer.say("...")
      elseif math.random() < 0.3 then
        renderer.say("~")
      end
    end
    schedule_next_wiggle()
  end))
end

local function schedule_next_swipe()
  stop_timer(swipe_timer)
  local jitter = math.random(-SWIPE_JITTER_S, SWIPE_JITTER_S)
  local delay_ms = math.max(60 * 1000, (SWIPE_BASE_S + jitter) * 1000)
  swipe_timer = vim.uv.new_timer()
  swipe_timer:start(delay_ms, 0, vim.schedule_wrap(function()
    if renderer.is_visible() and not pet.is_sleeping() and not pet.is_busy() then
      pet.swipe(SWIPE_TICKS)
    end
    schedule_next_swipe()
  end))
end

local function try_spawn_object()
  if not renderer.is_visible() then return end
  if renderer.has_object() then return end
  if pet.is_sleeping() or pet.is_busy() then return end
  local x = renderer.random_object_x(OBJECT_MIN_DISTANCE)
  local target_row = renderer.spawn_object("ball", x)
  if target_row then
    pet.approach_to(x, OBJECT_INTERACT_TICKS, target_row)
    mood.add(MOOD_GAIN_PLAY)
  end
end

-- Throw a ball to the cell under the cursor; the pet runs to fetch it.
-- Wired to a command/keymap so it's an intentional, on-demand interaction.
local function throw_ball()
  if not renderer.is_visible() then return end
  if renderer.has_object() then return end
  if pet.is_sleeping() or pet.is_busy() then return end
  local x = renderer.cursor_object_x()
  local target_row = renderer.spawn_object("ball", x)
  if target_row then
    pet.approach_to(x, OBJECT_INTERACT_TICKS, target_row)
    mood.add(MOOD_GAIN_PLAY)
  end
end

local function schedule_next_object()
  stop_timer(object_timer)
  local jitter = math.random(-OBJECT_SPAWN_JITTER_S, OBJECT_SPAWN_JITTER_S)
  local delay_ms = math.max(60 * 1000, (OBJECT_SPAWN_BASE_S + jitter) * 1000)
  object_timer = vim.uv.new_timer()
  object_timer:start(delay_ms, 0, vim.schedule_wrap(function()
    try_spawn_object()
    schedule_next_object()
  end))
end

-- Walk over to the cursor and watch it for a moment. Only fires while the
-- user is actively editing (recent activity) so the pet looks attentive
-- rather than randomly drifting onto the cursor when you're away.
local function try_follow_cursor()
  if not renderer.is_visible() then return end
  if pet.is_sleeping() or pet.is_busy() then return end
  if renderer.has_object() then return end
  if os.time() - last_activity_at > FOLLOW_RECENT_ACTIVITY_S then return end
  local col, row, face = renderer.cursor_watch_target()
  if not col then return end
  if pet.approach_to(col, WATCH_TICKS, row, "watch", face) then
    mood.add(MOOD_GAIN_WATCH)
  end
end

local function schedule_next_follow()
  stop_timer(follow_timer)
  local jitter = math.random(-FOLLOW_JITTER_S, FOLLOW_JITTER_S)
  local delay_ms = math.max(15 * 1000, (FOLLOW_BASE_S + jitter) * 1000)
  follow_timer = vim.uv.new_timer()
  follow_timer:start(delay_ms, 0, vim.schedule_wrap(function()
    try_follow_cursor()
    schedule_next_follow()
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

-- The lifestyle timers only do anything while the pet is visible, so we
-- start them on PetsShown and stop them on PetsHidden rather than letting
-- them poll forever in the background (object watcher used to wake every
-- 500ms even with the pet hidden).
local function start_lifestyle_timers()
  start_idle_timer()
  schedule_next_wiggle()
  schedule_next_swipe()
  schedule_next_object()
  schedule_next_follow()
end

local function stop_lifestyle_timers()
  stop_timer(idle_timer)
  stop_timer(wiggle_timer)
  stop_timer(swipe_timer)
  stop_timer(object_timer)
  stop_timer(follow_timer)
  idle_timer = nil
  wiggle_timer = nil
  swipe_timer = nil
  object_timer = nil
  follow_timer = nil
end

local function stop_all_timers()
  stop_lifestyle_timers()
  stop_timer(focus_reshow_timer)
  stop_timer(pomodoro_timer)
  focus_reshow_timer = nil
  pomodoro_timer = nil
end

-- Pomodoro companion: the pet keeps you company for a focus session and
-- celebrates when the timer rings. Independent of the wander timers so it
-- survives the pet being toggled off mid-session.
local function start_pomodoro(minutes)
  minutes = minutes or POMODORO_DEFAULT_MIN
  stop_timer(pomodoro_timer)
  renderer.say("focus " .. minutes .. "m!", 2500)
  pomodoro_timer = vim.uv.new_timer()
  pomodoro_timer:start(minutes * 60 * 1000, 0, vim.schedule_wrap(function()
    if renderer.is_visible() and not pet.is_busy() and not pet.is_sleeping() then
      pet.swipe(SWIPE_TICKS)
    end
    renderer.say("done! tea?", 3500)
    mood.add(MOOD_GAIN_POMODORO)
    stop_timer(pomodoro_timer)
    pomodoro_timer = nil
  end))
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
  mood.load()

  local group = vim.api.nvim_create_augroup("nvim-pets-events", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function() pcall(on_save) end,
  })

  vim.api.nvim_create_autocmd({
    "CursorMoved", "CursorMovedI", "InsertEnter", "InsertLeave",
    "TextChanged", "TextChangedI", "WinScrolled",
  }, {
    group = group,
    callback = record_activity,
  })

  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    callback = function() pcall(on_diagnostics) end,
  })

  vim.api.nvim_create_autocmd("FocusLost", {
    group = group,
    callback = function() pcall(on_focus_lost) end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function() pcall(on_focus_gained) end,
  })

  -- Mark the blocked grid as stale whenever visible content might have
  -- changed. blocked.is_blocked rebuilds lazily on the next pet query,
  -- so we don't pay a refresh per keystroke and there's no debounce
  -- timer churning in the background.
  vim.api.nvim_create_autocmd({
    "TextChanged", "TextChangedI",
    "WinScrolled", "WinResized", "VimResized",
    "BufWinEnter", "TabEnter",
  }, {
    group = group,
    callback = function() blocked.mark_dirty() end,
  })

  -- The renderer fires these when the pet is shown / hidden (including the
  -- hide+show that FocusLost/FocusGained and the :Pets* config commands do),
  -- so the lifestyle timers run exactly when the pet is on screen.
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "PetsShown",
    callback = start_lifestyle_timers,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "PetsHidden",
    callback = stop_lifestyle_timers,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      stop_all_timers()
      mood.save()
    end,
  })

  -- If the pet is already visible when setup runs (e.g. config reload),
  -- start the timers immediately; otherwise PetsShown will.
  if renderer.is_visible() then
    start_lifestyle_timers()
  end
end

-- Test/debug entry points used by :Pets* commands.
function M.trigger_peek()   pet.peek(peek_dir(), PEEK_TICKS) end
function M.trigger_wiggle() pet.wiggle(WIGGLE_TICKS) end
function M.trigger_swipe()  pet.swipe(SWIPE_TICKS) end
function M.trigger_object() try_spawn_object() end
-- Debug: follow the cursor now, bypassing the recent-activity gate.
function M.trigger_follow()
  mark_active()
  try_follow_cursor()
end
function M.trigger_sleep()  pet.sleep() end
function M.trigger_wake()   pet.wake() end

-- Throw a ball to the cursor (intentional play).
function M.throw() throw_ball() end

-- Feed the pet: a happiness boost and a heart.
function M.feed()
  mood.add(MOOD_GAIN_FEED)
  if renderer.is_visible() then
    if not pet.is_busy() then pet.peek(peek_dir(), PEEK_TICKS) end
    renderer.say("yum <3")
  end
end

-- Report happiness as a notification (and a bubble when on screen).
function M.status()
  local h = mood.happiness()
  vim.notify(
    string.format("nvim-pets: %s — happiness %d/100 (%s)",
      renderer.species and renderer.species() or "pet", h, mood.label()),
    vim.log.levels.INFO
  )
  if renderer.is_visible() then renderer.say(mood.label()) end
end

-- Start a focus session; minutes optional (defaults to 25).
function M.pomodoro(minutes) start_pomodoro(minutes) end

return M
