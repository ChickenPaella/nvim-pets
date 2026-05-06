-- Listens to nvim diagnostics and triggers an alert reaction on the pet
-- whenever a *new* warning/error appears in a visible buffer line.
--
-- Source-of-truth for what counts as a "code smell" is delegated to the
-- LSP / linter / formatter the user already has — this module just reacts
-- to whatever they emit. So coverage scales with how much the user has
-- wired up (none-ls, conform, eslint LSP, ruff, etc.).

local M = {}

local renderer = require("pets.renderer")

local seen = {}                  -- { [signature] = true }
local last_reaction_at = 0       -- vim.uv.hrtime() ns
local DEBOUNCE_NS = 3 * 1000000000  -- 3 seconds between reactions

local function signature(d)
  return string.format("%d|%d|%d|%d|%s",
    d.bufnr or 0, d.lnum or 0, d.col or 0, d.severity or 0, d.source or "")
end

local function pick_target(diagnostics)
  -- vim.diagnostic.severity: ERROR=1, WARN=2, INFO=3, HINT=4
  -- Lower number = higher severity. Tie-break by earliest line, then column.
  table.sort(diagnostics, function(a, b)
    if a.severity ~= b.severity then return a.severity < b.severity end
    if a.lnum ~= b.lnum then return a.lnum < b.lnum end
    return (a.col or 0) < (b.col or 0)
  end)
  return diagnostics[1]
end

local function compute_pet_position(target)
  local wins = vim.fn.win_findbuf(target.bufnr)
  if not wins or #wins == 0 then return nil end
  local winid = wins[1]

  -- screenpos returns 1-based screen coords; lnum/col are 0-based.
  local pos = vim.fn.screenpos(winid, target.lnum + 1, 1)
  if not pos or pos.row == 0 then return nil end

  local line = vim.api.nvim_buf_get_lines(target.bufnr, target.lnum, target.lnum + 1, false)[1] or ""
  local line_w = vim.fn.strdisplaywidth(line)

  local sw = renderer.sprite_width()
  local sh = renderer.sprite_height()

  -- Image (x, y) are 0-based offsets inside the full-screen float window.
  -- Place the pet two cells to the right of end-of-line, on the same row.
  local pet_col = pos.col + line_w + 1
  local pet_row = pos.row - 1

  -- Right-edge fallback: if the pet would clip the right margin, drop
  -- one row below the diagnostic and align with the line's left margin.
  if pet_col + sw > vim.o.columns then
    pet_col = math.max(0, pos.col - 1)
    pet_row = pet_row + 1
    if pet_col + sw > vim.o.columns then
      pet_col = math.max(0, vim.o.columns - sw - 1)
    end
  end

  -- Keep the pet inside the visible editor area (avoid status / cmdline).
  pet_row = math.max(0, math.min(pet_row, vim.o.lines - sh - 2))
  pet_col = math.max(0, pet_col)

  return pet_row, pet_col
end

function M.on_diagnostic_changed(args)
  if not renderer.is_visible() then return end

  local now = vim.uv.hrtime()
  if now - last_reaction_at < DEBOUNCE_NS then return end

  local diags = vim.diagnostic.get(args.buf, {
    severity = { min = vim.diagnostic.severity.WARN },
  })
  if not diags or #diags == 0 then return end

  local newdiags = {}
  for _, d in ipairs(diags) do
    local s = signature(d)
    if not seen[s] then
      seen[s] = true
      table.insert(newdiags, d)
    end
  end
  if #newdiags == 0 then return end

  local target = pick_target(newdiags)
  local row, col = compute_pet_position(target)
  if not row then return end

  renderer.alert_at(row, col, "left")
  last_reaction_at = now
end

local function clear_seen_for_buf(bufnr)
  local prefix = bufnr .. "|"
  for k, _ in pairs(seen) do
    if vim.startswith(k, prefix) then
      seen[k] = nil
    end
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("nvim-pets-reactions", { clear = true })
  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = group,
    callback = function(args)
      pcall(M.on_diagnostic_changed, args)
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(args)
      clear_seen_for_buf(args.buf)
    end,
  })
end

-- Manual trigger: react to the most severe diagnostic in the current buffer
-- regardless of "seen" state and debounce. Used by :PetsAlert.
function M.trigger_manual()
  if not renderer.is_visible() then
    vim.notify("nvim-pets: pet is hidden — run :Pets first", vim.log.levels.INFO)
    return
  end
  local diags = vim.diagnostic.get(0, {
    severity = { min = vim.diagnostic.severity.WARN },
  })
  if not diags or #diags == 0 then
    vim.notify("nvim-pets: no warning/error diagnostics in current buffer", vim.log.levels.INFO)
    return
  end
  local target = pick_target(diags)
  local row, col = compute_pet_position(target)
  if not row then
    vim.notify("nvim-pets: target diagnostic line not visible on screen", vim.log.levels.INFO)
    return
  end
  renderer.alert_at(row, col, "left")
  last_reaction_at = vim.uv.hrtime()
end

return M
