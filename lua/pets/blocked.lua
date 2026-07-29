-- Tracks which screen cells currently contain visible content (text,
-- signs, numbers, fold columns, virtual text, sidebar entries) so the pet
-- can avoid stepping on them.
--
-- Sidebars (nvim-tree, etc.) aren't special-cased: their lines are text
-- like any other, so they end up in the blocked grid naturally. Floating
-- windows (cmp menus, our own pet float) are skipped — we don't want
-- transient overlays to permanently corral the pet.
--
-- Screen rows are advanced by each line's real display height rather than
-- assuming (lnum - topline): closed folds, wrapped lines and virt_lines all
-- break the one-buffer-line-per-screen-row assumption, and getting that
-- mapping wrong shifts the whole grid so the pet walks over code it
-- believes is empty.
--
-- The grid is recomputed on demand by events.lua whenever the screen
-- content changes, debounced so a burst of TextChanged events doesn't
-- thrash the loop.

local M = {}

-- blocked_rows[screen_row] = { {start_col, end_col_exclusive}, ... }
-- A row rarely holds more than 1–2 ranges, so a linear scan is fast in
-- practice.
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

-- Extra display columns contributed by virtual text — diagnostics at the
-- end of a line, inlay hints, and anything else an extmark draws. They
-- occupy real cells, so leaving them out let the pet park on top of an
-- error message. Collected in one extmark query for the whole visible
-- range instead of one query per line.
--
-- virt_lines aren't measured here: they add screen rows rather than
-- columns, and screenpos() already accounts for the rows they push down.
local function virt_widths(buf, top_lnum, bot_lnum)
  local widths = {}
  local ok, marks = pcall(
    vim.api.nvim_buf_get_extmarks, buf, -1,
    { top_lnum - 1, 0 }, { bot_lnum - 1, -1 },
    { details = true }
  )
  if not ok then return widths end
  for _, mark in ipairs(marks) do
    local lnum = mark[2] + 1
    local details = mark[4]
    local chunks = details and details.virt_text
    if chunks then
      local w = 0
      for _, chunk in ipairs(chunks) do
        w = w + vim.fn.strdisplaywidth(chunk[1] or "")
      end
      widths[lnum] = (widths[lnum] or 0) + w
    end
  end
  return widths
end

-- Buffer lines that open a closed fold, mapped to the fold's last line. A
-- closed fold renders as a single full-width 'foldtext' line, so it blocks
-- differently from the lines it hides.
local function closed_folds(win, topline, botline)
  local folds = {}
  vim.api.nvim_win_call(win, function()
    local lnum = topline
    while lnum <= botline do
      local fold_end = vim.fn.foldclosedend(lnum)
      if fold_end ~= -1 then
        folds[lnum] = fold_end
        lnum = fold_end + 1
      else
        lnum = lnum + 1
      end
    end
  end)
  return folds
end

-- Screen rows a single buffer line occupies, wrap- and virt_lines-aware.
-- nvim_win_text_height is the authority here; screenpos() would also work
-- but returns 0 without an attached UI, which would silently empty the whole
-- grid and let the pet walk over everything.
local has_text_height = type(vim.api.nvim_win_text_height) == "function"

local function line_height(win, lnum)
  if not has_text_height then return 1 end
  local ok, h = pcall(vim.api.nvim_win_text_height, win,
    { start_row = lnum - 1, end_row = lnum - 1 })
  if ok and h and h.all and h.all > 0 then return h.all end
  return 1
end

local function mark_window(win)
  local info = (vim.fn.getwininfo(win) or {})[1]
  if not info then return end

  local buf = info.bufnr
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end

  local textoff = info.textoff or 0        -- number/sign/fold columns
  local win_left = (info.wincol or 1) - 1  -- 0-based screen col
  local win_width = info.width or 0
  local win_height = info.height or 0
  local text_width = math.max(1, win_width - textoff)
  local wrap = vim.wo[win].wrap
  local total = vim.api.nvim_buf_line_count(buf)
  local topline = math.max(1, info.topline or 1)
  local botline = math.min(info.botline or topline, total)
  if botline < topline or win_width <= 0 then return end

  local virt = virt_widths(buf, topline, botline)
  local folds = closed_folds(win, topline, botline)

  -- Screen row where this window's text starts; a 'winbar' takes the first
  -- row of the window when present.
  local screen_row = (info.winrow or 1) - 1 + (info.winbar or 0)
  local last_row = screen_row + win_height - 1

  local lnum = topline
  while lnum <= botline and screen_row <= last_row do
    if folds[lnum] then
      -- A closed fold renders as one full-width 'foldtext' line.
      add_range(screen_row, win_left, win_left + win_width)
      screen_row = screen_row + 1
      lnum = folds[lnum] + 1
    else
      local line = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
      local line_w = vim.fn.strdisplaywidth(line) + (virt[lnum] or 0)

      if wrap and line_w > text_width then
        -- Every screen row of a wrapped line but the last is full text
        -- width; continuation rows start after the number/sign columns.
        local segs = math.ceil(line_w / text_width)
        for k = 0, segs - 1 do
          local row = screen_row + k
          if row > last_row then break end
          local seg = (k == segs - 1)
            and (line_w - (segs - 1) * text_width)
            or text_width
          local left = win_left + ((k == 0) and 0 or textoff)
          add_range(row, left, win_left + textoff + math.min(seg, text_width))
        end
      else
        add_range(screen_row, win_left,
                  win_left + math.min(textoff + line_w, win_width))
      end

      screen_row = screen_row + line_height(win, lnum)
      lnum = lnum + 1
    end
  end
end

function M.refresh()
  blocked_rows = {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local wcfg = vim.api.nvim_win_get_config(win)
    -- relative == "" identifies a regular split. Floating windows (our pet
    -- float, completion popups, etc.) report relative ~= "".
    if wcfg.relative == "" then
      pcall(mark_window, win)
    end
  end
  dirty = false
end

-- Lazy: a rebuild only happens on the first query after mark_dirty().
-- Pet ticks query a handful of times per frame at most, so even heavy
-- typing pays only one refresh per pet tick — no extra timers, no
-- autocmd-rate churn.
function M.is_blocked(row, col)
  if dirty then M.refresh() end
  local ranges = blocked_rows[row]
  if not ranges then return false end
  for _, r in ipairs(ranges) do
    if col >= r[1] and col < r[2] then return true end
  end
  return false
end

-- True when any cell of the width × height rectangle anchored at
-- (row, col) holds content. The pet is an image several cells wide and
-- tall, so testing a single "feet" cell let its whole body sit on top of
-- code — only the full sprite footprint says whether a spot is really free.
function M.rect_blocked(row, col, width, height)
  if dirty then M.refresh() end
  local right = col + width      -- exclusive
  for r = row, row + height - 1 do
    local ranges = blocked_rows[r]
    if ranges then
      for _, rg in ipairs(ranges) do
        if col < rg[2] and right > rg[1] then return true end
      end
    end
  end
  return false
end

-- Drop the cached grid (used on hide / VimLeavePre to free memory).
function M.clear()
  blocked_rows = {}
  dirty = true
end

return M
