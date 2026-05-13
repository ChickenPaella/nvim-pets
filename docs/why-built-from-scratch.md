# Why we built this from scratch instead of using an existing library

> Audience: teammates asking "isn't there already a vscode-pets equivalent
> for nvim?"

## One-line conclusion

**The best-known option, `pets.nvim`, does not work in our environment
(WezTerm + tmux).** Its rendering backend (`hologram.nvim`) is effectively
unmaintained and does not keep up with the graphics-protocol changes in
tmux/WezTerm. Our nvim setup already ships `image.nvim` (for Markdown
image previews, etc.), so layering a thin pet on top of it adds no new
dependency and is easier to maintain.

---

## Survey of existing libraries

### 1. `giusgad/pets.nvim` — the most well-known option

- Features: pick between several species (dogs, cats, …), multi-pet,
  commands like `:PetsNew` / `:PetsKillAll`.
- Rendering: 100% delegated to **`giusgad/hologram.nvim`** (a fork of
  `edluffy/hologram.nvim`).
- Tested in our environment:
  - WezTerm + tmux: instead of a dog sprite, we get a **broken cluster of
    pixels** (looks like fragments of RGBA data — a small lightning shape).
    No animation.
  - WezTerm standalone (outside tmux): same symptom.
- In other words, **we couldn't even produce a working local demo.**

### 2. `edluffy/hologram.nvim` (the backend)

- Implements the Kitty Graphics Protocol directly in Lua.
- Last active development was years ago. README explicitly labels it
  **"experimental"**.
- Known limits:
  - No tmux passthrough wrapping (`\ePtmux;...\e\\`) — tmux swallows the
    graphics escape sequences.
  - Chunked transmission / image-ID collision handling is minimal.
  - Doesn't keep up with WezTerm's evolving Kitty-protocol implementation.
- pets.nvim's broken rendering is a direct consequence of these limits.

### 3. `3rd/image.nvim` — the backend we use

- Supports Kitty / Sixel / Ueberzug backends.
- Handles tmux passthrough **automatically** (`tmux_show_only_in_active_window`
  and friends).
- Actively used ecosystem: Markdown / Neorg image previews, LaTeX preview, …
- **Already part of our internal nvim config** (LazyVim-based).
- That said, interactive sprite animation isn't image.nvim's concern —
  we still need a thin layer on top of it.

---

## Decision matrix

| Criterion | Adopt pets.nvim | Build nvim-pets in-house |
|---|---|---|
| Works under WezTerm + tmux | ❌ broken (verified) | ✅ works |
| Extra dependencies | hologram.nvim, nui.nvim | image.nvim (already have it) |
| Upstream maintenance | low (hologram effectively dead) | we own it |
| Debug path when things break | upstream PR or fork | edit directly |
| Code size | external, several thousand lines | ~300 lines of our own |
| Internal-environment standardization | external compatibility risk | managed alongside dotfiles |
| Internal automation (save → happy, …) | needs a separate wrapper | already on the roadmap (v1.2) |

## What did building it ourselves cost?

- Modules used: `lua/pets/renderer.lua` (~250 lines) + `lua/pets/pet.lua`
  (~80 lines).
- Sprites: extracted from vscode-pets with ImageMagick (MIT-licensed,
  documented in `LICENSES.md`).
- Milestones:
  - v0 — static sprite + toggle
  - v1.0 — per-frame idle animation (no flicker)
  - v1.1 — state machine (idle/walk/lie) + L/R sprite flip + edge bouncing
  - v1.1.5 — bounded wander box, runtime size/position commands, image-
    object caching
- Key technical issues, and how we resolved them:
  - **Frame-transition flicker** → preload every image object + use
    render-then-clear ordering
  - **Memory / protocol leak** → reuse image objects keyed by `(path, x)`
    (without this we directly hit a bug where WezTerm froze in an infinite
    loop)
  - **Ghost frame on tmux window switch** → documented as a known limit
    with a workaround (`:Pets` twice)

## Recommendation

- **Internal recommendation**: use nvim-pets. No new dependency
  (image.nvim is already installed).
- **If quoting vscode-pets externally**, flag that the closest nvim-side
  library doesn't currently work in our standard environment.
- **Re-evaluate later** if pets.nvim / hologram.nvim resume maintenance.
  Our code is small (~330 lines) so migration cost would be small too.

---

## Appendix A — Test environment

- macOS (Darwin 25.4.0)
- WezTerm (Kitty Graphics Protocol support)
- tmux (`allow-passthrough on`, `focus-events on`)
- Neovim 0.11.6 (LazyVim-based)
- Date tested: 2026-05-06

## Appendix B — Reproducing the pets.nvim demo

```lua
-- ~/.config/nvim/lua/plugins/pets-nvim-demo/config.lua (temporary)
return {
  {
    "giusgad/pets.nvim",
    dependencies = {
      "MunifTanjim/nui.nvim",
      "giusgad/hologram.nvim",
    },
    cmd = { "PetsNew", "PetsList", "PetsKillAll" },
    config = function() require("pets").setup({}) end,
  },
}
```

Run `:PetsNew dog` → broken pixel cluster. Run `:PetsKillAll` and remove
the demo directory.
