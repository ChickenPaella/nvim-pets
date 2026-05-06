-- Listens to nvim diagnostics and nudges the pet into "alerted" mode
-- (visible agitation in its wander box) whenever a *new* warning or
-- error appears.
--
-- Source-of-truth for what counts as a "code smell" is delegated to the
-- LSP / linter / formatter the user already has — this module just reacts
-- to whatever they emit.

local M = {}

local renderer = require("pets.renderer")

local seen = {}                  -- { [signature] = true }
local last_reaction_at = 0       -- vim.uv.hrtime() ns
local DEBOUNCE_NS = 3 * 1000000000

local function signature(d)
  return string.format("%d|%d|%d|%d|%s",
    d.bufnr or 0, d.lnum or 0, d.col or 0, d.severity or 0, d.source or "")
end

function M.on_diagnostic_changed(args)
  if not renderer.is_visible() then return end

  local now = vim.uv.hrtime()
  if now - last_reaction_at < DEBOUNCE_NS then return end

  local diags = vim.diagnostic.get(args.buf, {
    severity = { min = vim.diagnostic.severity.WARN },
  })
  if not diags or #diags == 0 then return end

  local has_new = false
  for _, d in ipairs(diags) do
    local s = signature(d)
    if not seen[s] then
      seen[s] = true
      has_new = true
    end
  end
  if not has_new then return end

  renderer.alert_at(0, 0)
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

-- Manual trigger for :PetsAlert. Bypasses signature-dedup so you can re-
-- trigger the agitation animation on the same diagnostic for testing.
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
  renderer.alert_at(0, 0)
  last_reaction_at = vim.uv.hrtime()
end

return M
