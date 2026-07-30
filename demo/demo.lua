-- nvim-pets · Demo Day
--
--   BEAT 1   <leader>pp                    ペットが出る。文字の間だけ歩く
--   BEAT 2   x  →  u                       エラー「!?」 / 直すと「yay!」
--   BEAT 3   :PetsCount 4  →  <leader>pb   全員でボールを追う
--   BEAT 4   <leader>pf  →  :PetsStatus    幸福度は閉じても残る

local M = {}

-- 端末の文字マスは横1に対して縦2なので、N×M マスで描くと画面では N:2M の比率になります
local CELL_ASPECT = 2

local defaults = { species = "fox", count = 1, fps = 6 }

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- スプライト全体（7x3 = 21マス）が空いているかを見る。足元の1マスだけ見ていた頃は体が乗っていた
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

-- ▼ BEAT 2 ─ カーソルはこの行の最後の ")" の上にあります。 x で消して u で戻す
local ready = clamp(M.setup({ count = 3 }), 1, 6)

return M, ready
