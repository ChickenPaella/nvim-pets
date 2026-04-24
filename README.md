# nvim-pets

Pixel-art pets living inside your Neovim editor — vscode-pets equivalent.

v0 MVP: displays a single static sprite in a floating window, toggled via `:Pets`.

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
- [ ] v1: frame-by-frame animation
- [ ] v1: state machine (idle / walk / sit / react)
- [ ] v1: autocmd-driven reactions (BufWritePost → happy, DiagnosticChanged → sad)
- [ ] v2: multiple pet species + skins
- [ ] v2: configurable position and size via `setup({...})`

## License

MIT — see [LICENSE](LICENSE).

Sprite asset credits: see [LICENSES.md](LICENSES.md).
