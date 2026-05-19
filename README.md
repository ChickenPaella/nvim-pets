# nvim-pets

Pixel-art pets living inside your Neovim editor — vscode-pets equivalent.

v1.2: an animated pet wanders inside a wander box anchored to a screen
corner — idles, walks back and forth (bouncing off the box edges), and
occasionally lies down to rest. The pet also reacts to your work
without ever leaving its corner: it pauses to look at you when you
save, drifts off to sleep after long inactivity, and surfaces a small
random wiggle every few minutes. Sprite size, box size, and corner are
configurable both at setup and at runtime via `:Pets*` commands.

> Why build this when `pets.nvim` exists? See
> [docs/why-built-from-scratch.md](docs/why-built-from-scratch.md).

## Requirements

- Neovim >= 0.10
- A terminal that supports the Kitty Graphics Protocol (see compatibility below)
- ImageMagick (`brew install imagemagick` on macOS) — only required if you
  regenerate sprites; not needed at runtime
- [image.nvim](https://github.com/3rd/image.nvim) (loaded automatically as a dependency)

### Terminal compatibility

| Terminal | Status |
|---|---|
| Kitty | ✅ supported |
| WezTerm | ✅ supported |
| Ghostty | ✅ supported |
| iTerm2 | ❌ no Kitty Graphics support |
| Apple Terminal | ❌ no graphics protocol |
| Alacritty | ❌ no graphics protocol |
| VS Code integrated terminal | ❌ no graphics protocol |

If your `TERM_PROGRAM` isn't on the known-good list the plugin will print
a one-shot warning on first `:Pets` and continue anyway, so a new terminal
that supports the protocol will work without a code change.

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
      pet    = "fox",          -- "fox" | "panda" | "dog" | "turtle"
      width  = 11,             -- sprite width in cells (overrides species default)
      height = 5,              -- sprite height in cells (overrides species default)
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
| `:PetsType <name>` | switch species (`fox` / `panda` / `dog` / `turtle`) |
| `:PetsState` | print current pet / action / direction / position / size / area |
| `:PetsPeek` / `:PetsWiggle` / `:PetsSwipe` / `:PetsObject` / `:PetsSleep` / `:PetsWake` | manually trigger lifestyle events (debug) |

Any `:Pets*` config command applied while the pet is visible briefly hides
and re-shows it with the new settings.

## Species personality

Each species has its own wander transition probabilities so the way it
spends time differs:

- **fox** — restless: highest `walk` probability, shortest `lie` runs
- **dog** — balanced: walks and idles a lot, occasionally lies down
- **panda** — mellow: lies down often even from `idle`, walks less
- **turtle** — sleepy: spends most of its time lying down, walks slowly

Combined with the per-species sprite and the periodic swipe animation,
the four pets read as visibly distinct over a session.

## Lifestyle events (v1.2)

The pet stays in its corner but reacts to your editing rhythm:

- **Peek on save** — `BufWritePost` fires the pet into a brief `peek` state:
  it pauses for ~1 second and faces toward the screen center (away from
  the corner) so it looks like it's looking at you.
- **Sleep on long idle** — after ~10 minutes with no cursor movement / text
  change / save, the pet curls up into a `lie` pose and stays there.
  Any user activity wakes it back to idle automatically.
- **Random wiggle** — every ~5 minutes (±2 min jitter), if the pet isn't
  busy, it does a short head-shake (~1.5s of rapid left/right flips).
  Background sign of life.
- **Species swipe** — every ~4 minutes (±90s jitter), the pet plays its
  species-specific swipe animation (fox paw, panda hands-up, dog paw,
  turtle reach). This is what makes each species feel different beyond
  just the sprite.
- **Environment objects** — every ~3 minutes (±60s jitter), a ball appears
  somewhere in the wander box. The pet walks over to it (using the walk
  sprite), plays the species swipe animation for ~3 seconds, then the
  ball disappears and normal wandering resumes. Only one object is active
  at a time, and the timer is skipped while the pet is busy or asleep.
- **Focus loss** — `FocusLost` (e.g. tmux pane move, app switch) tears
  the float down completely; `FocusGained` brings it back after a short
  defer. This is more aggressive than image.nvim's
  `editor_only_render_when_focused` because it also drops the cached
  Kitty placements, which prevents stale-image build-up that can freeze
  WezTerm + tmux on long sessions.

All of this reuses the existing idle / lie sprites — no new assets.

Manual debug triggers: `:PetsPeek`, `:PetsWiggle`, `:PetsSleep`, `:PetsWake`.

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
- [x] v1.2: lifestyle events — save peek, idle sleep, random wiggle
- [x] v1.3.1: multi-species — `panda` added alongside `fox`, runtime switch via `:PetsType`
- [x] v1.3.2: `dog` (akita shiba) and `turtle` (green) added
- [x] v1.3.3: per-species personality — distinct wander probabilities + a periodic swipe signature animation
- [x] v1.4.1: environment objects — ball spawns, pet approaches, plays swipe, ball despawns
- [ ] v1.4.2: more objects (food bowl, box) and species-specific interaction sprites
- [ ] v1.4: environment objects (food bowl, ball, box) for richer pet interaction

## License

MIT — see [LICENSE](LICENSE).

Sprite asset credits: see [LICENSES.md](LICENSES.md).
