-- Tracks which screen cells currently contain visible content (text,
-- signs, numbers, sidebar entries) so the pet can avoid stepping on
-- them.
--
-- Sidebars (nvim-tree, etc.) aren't special-cased: their lines are text
-- like any other, so they end up in the blocked grid naturally. Floating
-- windows (cmp menus, our own pet float) are skipped — we don't want
-- transient overlays to permanently corral the pet.
--
-- The grid is recomputed on demand by events.lua whenever the screen
-- content changes, debounced so a burst of TextChanged events doesn't
-- thrash the loop.

local M = {}

-- blocked_rows[screen_row] = { {start_col, end_col_exclusive}, ... }
-- Per-row sorted by start_col so a linear scan is fast in practice
-- (a row rarely has more than 1–2 ranges).
local blocked_rows = {}
local dirty = true

local function add_range(row, start_col, end_col)
  if end_col <= start_col then return end
  local list = blocked_rows[row]
  if not list then
    blocked_rows[row] = { { start_col, end_col } }
    return
  end
  list[#list + 1] = { start_col, end_col }
end

function M.mark_dirty() dirty = true end

function M.refresh()
  blocked_rows = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local wcfg = vim.api.nvim_win_get_config(win)
    -- relative == "" identifies a regular split. Floating windows
    -- (our pet float, completion popups, etc.) report relative ~= "".
    if wcfg.relative == "" then
      local pos = vim.api.nvim_win_get_position(win)
      local screen_row_top = pos[1]
      local screen_col_left = pos[2]
      local winwidth = vim.api.nvim_win_get_width(win)

      local info_list = vim.fn.getwininfo(win)
      local info = info_list and info_list[1] or nil
      if info then
        local textoff = info.textoff or 0   -- number/sign/fold columns
        local topline = info.topline or 1
        local botline = info.botline or 1
        local buf = info.bufnr
        local total = vim.api.nvim_buf_line_count(buf)
        local last = math.min(botline, total)

        for lnum = topline, last do
          local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
          local line_w = vim.fn.strdisplaywidth(line)
          local content_w = math.min(textoff + line_w, winwidth)
          if content_w > 0 then
            local screen_row = screen_row_top + (lnum - topline)
            add_range(screen_row, screen_col_left, screen_col_left + content_w)
          end
        end
      end
    end
  end
  dirty = false
end

-- Lazy: a rebuild only happens on the first query after mark_dirty().
-- Pet ticks query at most 8/sec, so even heavy typing pays only one
-- refresh per pet tick — no extra timers, no autocmd-rate churn.
function M.is_blocked(row, col)
  if dirty then M.refresh() end
  local ranges = blocked_rows[row]
  if not ranges then return false end
  for _, r in ipairs(ranges) do
    if col >= r[1] and col < r[2] then return true end
  end
  return false
end

-- Drop the cached grid (used on hide / VimLeavePre to free memory).
function M.clear()
  blocked_rows = {}
  dirty = true
end

return M
