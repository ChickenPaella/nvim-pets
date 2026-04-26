local M = {}

local state = {
  win = nil,
  buf = nil,
  imgs = {},
  timer = nil,
  frames = {},
  frame_idx = 1,
}

local config = {
  sprite_dir = nil,
  fps = 8,
  width = 22,
  height = 9,
}

-- Resolve the plugin root from this file's path:
--   <root>/lua/pets/renderer.lua  -> <root>
local function plugin_root()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h:h:h")
end

function M.setup(opts)
  config.sprite_dir = opts.sprite_dir or (plugin_root() .. "/sprites/fox/idle")
  if opts.fps then config.fps = opts.fps end
  if opts.width then config.width = opts.width end
  if opts.height then config.height = opts.height end
end

local function discover_frames(dir)
  local list = vim.fn.glob(dir .. "/*.png", false, true)
  table.sort(list)
  return list
end

local function create_float_win()
  local width = config.width
  local height = config.height
  -- Bottom-right corner, leaving a 2-cell margin from the edge
  local row = vim.o.lines - height - 3
  local col = vim.o.columns - width - 2

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    focusable = false,
    zindex = 50,
  })

  -- Blend the float background into the editor background so only the sprite shows
  vim.wo[win].winhighlight = "Normal:Normal,NormalFloat:Normal"

  return win, buf
end

-- Pre-create one image object per frame so we can render-then-clear without
-- recreating images on each tick (this eliminates the gap that causes flicker).
local function preload_images(image_mod)
  state.imgs = {}
  for i, frame_path in ipairs(state.frames) do
    state.imgs[i] = image_mod.from_file(frame_path, {
      id = "nvim-pets-frame-" .. i,
      window = state.win,
      buffer = state.buf,
      x = 0,
      y = 0,
      width = config.width,
      height = config.height,
    })
  end
end

local function clear_all_images()
  for _, img in ipairs(state.imgs) do
    pcall(function() img:clear() end)
  end
  state.imgs = {}
end

local function stop_timer()
  if state.timer then
    pcall(function() state.timer:stop() end)
    pcall(function() state.timer:close() end)
    state.timer = nil
  end
end

local function start_timer()
  stop_timer()
  state.timer = vim.uv.new_timer()
  local interval = math.floor(1000 / config.fps)
  state.timer:start(interval, interval, vim.schedule_wrap(function()
    if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
      M.hide()
      return
    end
    if #state.imgs < 2 then return end
    local prev_idx = state.frame_idx
    local next_idx = (prev_idx % #state.imgs) + 1
    -- Render new frame BEFORE clearing the previous one to avoid an
    -- empty moment between frames.
    pcall(function() state.imgs[next_idx]:render() end)
    pcall(function() state.imgs[prev_idx]:clear() end)
    state.frame_idx = next_idx
  end))
end

function M.show()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    return
  end

  local ok_image, image = pcall(require, "image")
  if not ok_image then
    vim.notify("nvim-pets: image.nvim is not available", vim.log.levels.ERROR)
    return
  end

  if vim.fn.isdirectory(config.sprite_dir) == 0 then
    vim.notify("nvim-pets: sprite dir not found: " .. config.sprite_dir, vim.log.levels.ERROR)
    return
  end

  state.frames = discover_frames(config.sprite_dir)
  if #state.frames == 0 then
    vim.notify("nvim-pets: no frames found in " .. config.sprite_dir, vim.log.levels.ERROR)
    return
  end

  state.win, state.buf = create_float_win()
  state.frame_idx = 1

  preload_images(image)
  pcall(function() state.imgs[1]:render() end)
  start_timer()
end

function M.hide()
  stop_timer()
  clear_all_images()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  state.win = nil
  state.buf = nil
  state.frame_idx = 1
end

function M.toggle()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    M.hide()
  else
    M.show()
  end
end

return M
