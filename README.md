# nvim-pets

Pixel-art pets living inside your Neovim editor — vscode-pets equivalent.

v1.0: displays an animated pet sprite (8fps idle loop) in a floating window, toggled via `:Pets`.

## Requirements

- Neovim >= 0.10
- A terminal that supports the Kitty Graphics Protocol (Kitty, Ghostty, or recent WezTerm)
- ImageMagick (`brew install imagemagick` on macOS)
- [image.nvim](https://github.com/3rd/image.nvim) (loaded automatically as a dependency)

## Install (lazy.nvim, local development)

```lua
{
  dir = "~/projects/nvim-pets",
  dependencies = { "3rd/image.nvim" },
  keys = { { "<leader>pp", "<cmd>Pets<cr>", desc = "Pets: toggle" } },
  config = function() require("pets").setup() end,
}
```

## Usage

- `:Pets` or `<leader>pp` — toggle the pet display

## Roadmap

- [x] v0: static sprite in a float window (toggle)
- [x] v1.0: frame-by-frame idle animation
- [ ] v1.1: wandering — state machine + movement (idle ↔ walk ↔ run, sprite flipping, edge handling)
- [ ] v1.2: autocmd-driven reactions (BufWritePost → happy, DiagnosticChanged → sad)
- [ ] v1.3: multi-pet selection + position/size config via `setup({...})`

## License

MIT — see [LICENSE](LICENSE).

Sprite asset credits: see [LICENSES.md](LICENSES.md).
