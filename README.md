# nvim-pets

Pixel-art pets living inside your Neovim editor — vscode-pets equivalent.

v1.2: an animated pet wanders inside a wander box anchored to a screen
corner — idles, walks back and forth (bouncing off the box edges), and
occasionally lies down to rest. When the LSP / linter / formatter emits a
new warning or error, the pet teleports to that line and barks an alert
(`!`) before returning to its corner. Sprite size, box size, and corner
are configurable both at setup and at runtime via `:Pets*` commands.

> Why build this when `pets.nvim` exists? See
> [docs/why-built-from-scratch.md](docs/why-built-from-scratch.md).

## Requirements

- Neovim >= 0.10
- A terminal that supports the Kitty Graphics Protocol (Kitty, Ghostty, or recent WezTerm)
- ImageMagick (`brew install imagemagick` on macOS)
- [image.nvim](https://github.com/3rd/image.nvim) (loaded automatically as a dependency)

If you run nvim inside tmux, also enable in your `tmux.conf`:

```tmux
set -g allow-passthrough on
set -g focus-events on
```

## Install (lazy.nvim, local development)

```lua
{
  dir = "~/projects/nvim-pets",
  dependencies = { "3rd/image.nvim" },
  keys = { { "<leader>pp", "<cmd>Pets<cr>", desc = "Pets: toggle" } },
  config = function()
    require("pets").setup({
      -- All optional; values shown are the defaults.
      width  = 11,             -- sprite width in cells
      height = 5,              -- sprite height in cells
      fps    = 8,
      area = {
        corner = "br",         -- "br" | "bl" | "tr" | "tl"
        cols   = 35,           -- wander box width in cells
        rows   = 5,            -- wander box height in cells
      },
    })
  end,
}
```

## Usage

| Command | What it does |
|---|---|
| `:Pets` (or `<leader>pp`) | toggle the pet on/off |
| `:PetsResize <w> <h>` | resize sprite (cells); auto-grows the box if needed |
| `:PetsArea <cols> <rows>` | resize the wander box (cells) |
| `:PetsMove <corner>` | move box to corner (`br` / `bl` / `tr` / `tl`) |
| `:PetsAlert` | manually trigger an alert at the current buffer's most severe diagnostic (debug) |
| `:PetsState` | print current action / direction / position / size / area |

## Diagnostic reactions (v1.2)

When the pet is visible, it listens to `DiagnosticChanged`. On a *new* warning
or error in any visible buffer, the pet teleports to the line, plays an alert
(`!` overlay) for ~2 seconds, then returns to its wander box.

- Uses `vim.diagnostic` — coverage matches whatever you already have wired up
  (LSP servers, none-ls, ruff, eslint, etc.). The plugin doesn't analyze code itself.
- Filters: `severity >= WARN`. HINT / INFO are ignored to keep noise low.
- Same diagnostic signature only triggers once. New warnings on the same line
  re-trigger only after a 3-second debounce.
- The pet is placed two cells past end-of-line so it never covers code. If the
  line is too long, it falls back to one row below the diagnostic.

Any `:Pets*` config command applied while the pet is visible briefly hides
and re-shows it with the new settings.

## Known limitations

- **tmux window switching may leave a "ghost" frame** at the pet's last
  position. This is a tmux + Kitty Graphics Protocol limitation (tmux doesn't
  virtualize the graphics layer). Workaround: run `:Pets` twice (off → on) to
  clear the cache and redraw cleanly.

## Roadmap

- [x] v0: static sprite in a float window (toggle)
- [x] v1.0: frame-by-frame idle animation
- [x] v1.1: wandering — state machine (idle ↔ walk ↔ lie), sprite flipping, edge bouncing
- [x] v1.1.5: bounded wander box, runtime size/area/corner commands, image-cache fix
- [x] v1.2: diagnostic reactions — teleport + alert overlay on new LSP/linter warnings
- [ ] v1.3: multi-species (cat/dog/snake) — sprite extraction, runtime species switch
- [ ] v1.4: free movement across the whole screen with code-aware avoidance

## License

MIT — see [LICENSE](LICENSE).

Sprite asset credits: see [LICENSES.md](LICENSES.md).
