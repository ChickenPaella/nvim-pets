-- nvim-pets · Demo Day
--
--   BEAT 1   <leader>pp                     pet appears, walks between text
--   BEAT 2   x  ->  u                       error "!?"  /  fixed "yay!"
--   BEAT 3   :PetsCount 4  ->  <leader>pb   the whole flock chases the ball
--   BEAT 4   <leader>pf  ->  :PetsStatus    happiness survives a restart
--
-- The ragged right margin below is deliberate: it is what makes the pet
-- visibly thread between the text instead of walking over open space.

local M = {}

-- A terminal cell is twice as tall as it is wide, so an N x M block of cells
-- renders the image at N : 2M. The fox is 92x75, which lands on 7 x 3 cells.
local CELL_ASPECT = 2

local defaults = { species = "fox", count = 1, fps = 6 }

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- The whole 7x3 = 21 cell footprint has to be clear. Checking only the cell
-- under its feet is what used to let the pet's body sit on top of code.
local function footprint_is_clear(grid, col, row, w, h)
  for r = row, row + h - 1 do
    for c = col, col + w - 1 do
      if grid[r] and grid[r][c] then return false end
    end
  end
  return true
end

function M.setup(opts)
  opts = opts or {}
  return clamp(opts.count or defaults.count, 1, 6), CELL_ASPECT, footprint_is_clear
end

-- BEAT 2 -- the cursor is already on the last ")" of the line below.
local ready = clamp(M.setup({ count = 3 }), 1, 6)

return M, ready
