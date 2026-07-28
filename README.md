# nvim-pets

Pixel-art pets living inside your Neovim editor — vscode-pets equivalent.

One (or a small flock) of animated pixel-art pets live in your editor.
They wander across the whole buffer — walking, idling, lying down to rest
— while carefully stepping only on empty cells, never on your code. They
react to what you do: a pet walks over to watch the line you're editing,
pauses to look at you when you save, frets when LSP errors appear and
cheers when they're gone, fetches a ball you throw, drifts to sleep when
you go idle, and keeps a persistent happiness you can feed. Species, sprite
size, flock size and wander area are configurable at setup and at runtime
via `:Pets*` commands.

> Why build this when `pets.nvim` exists? See
> [docs/why-built-from-scratch.md](docs/why-built-from-scratch.md).

## Requirements

> **Read this first.** The pet is a real image drawn through the Kitty
> Graphics Protocol, so it only renders where three things line up: a
> supported OS, a supported terminal, and ImageMagick. If any one is
> missing, `:Pets` runs without error but **nothing appears**.

**All of these are required at runtime:**

- **Neovim >= 0.10**
- **OS: macOS or Linux.** Windows (native) is **not supported** — see below.
- **A Kitty Graphics Protocol terminal** — Kitty, WezTerm, or Ghostty
  (see the table below).
- **ImageMagick.** `image.nvim` uses it to decode and render every sprite, so
  it is needed **at runtime, not just for regenerating sprites**. On macOS:
  `brew install imagemagick`. image.nvim also needs its image processor set up:
  either `processor = "magick_cli"` (uses the ImageMagick CLI you just
  installed — simplest) or the default `magick` luarock. Verify the whole chain
  with `:checkhealth image`.
- **[image.nvim](https://github.com/3rd/image.nvim)** — loaded automatically
  as a dependency, but it has its own system requirements (the ImageMagick
  bullet above).

### OS / platform support

| Platform | Status |
|---|---|
| macOS | ✅ supported |
| Linux | ✅ supported |
| Windows (native) | ❌ not supported — `image.nvim` + ImageMagick don't run natively, and Kitty/Ghostty have no Windows build |
| Windows (WSL2) | ⚠️ may work with WezTerm + ImageMagick inside WSL, but **untested** — don't rely on it for a live demo |

### Terminal compatibility

| Terminal | macOS | Linux | Windows | Notes |
|---|---|---|---|---|
| Kitty | ✅ | ✅ | — | no Windows build |
| WezTerm | ✅ | ✅ | ⚠️ | Windows build exists, but the ImageMagick/OS limits above still apply |
| Ghostty | ✅ | ✅ | — | no Windows build |
| iTerm2 | ❌ | — | — | no Kitty Graphics support (uses its own image protocol) |
| Apple Terminal | ❌ | — | — | no graphics protocol |
| Alacritty | ❌ | ❌ | ❌ | no graphics protocol |
| VS Code integrated terminal | ❌ | ❌ | ❌ | no graphics protocol |

If your `TERM_PROGRAM` isn't on the known-good list the plugin prints a
one-shot warning on first `:Pets` and continues anyway, so a new terminal
that supports the protocol works without a code change. **A warning (or a
silent no-show) almost always means the terminal or ImageMagick is the
problem — run `:checkhealth image`.**

If you run nvim inside tmux, also enable in your `tmux.conf`:

```tmux
set -g allow-passthrough on
set -g focus-events on
```

## Install (lazy.nvim)

The spec below auto-detects a local checkout: if `~/nvim-pets` exists it
loads from there (live local development); otherwise lazy.nvim clones the
public GitHub repo. The same config therefore works on a dev machine and on
a fresh machine (a teammate's laptop, a demo box) with no edits.

```lua
{
  -- lazy.nvim clones this on machines without a local checkout.
  "ChickenPaella/nvim-pets",
  -- On a dev machine, point `dir` at your checkout instead, e.g.:
  --   dir = vim.fn.expand("~/nvim-pets"),
  dependencies = { "3rd/image.nvim" },
  keys = { { "<leader>pp", "<cmd>Pets<cr>", desc = "Pets: toggle" } },
  config = function()
    require("pets").setup({
      -- All optional; values shown are the defaults.
      pet    = "fox",          -- "fox" | "panda" | "dog" | "turtle"
      count  = 1,              -- how many pets roam at once (1-6)
      settle_ms = 1200,        -- freeze the pets after this idle time (0 = never)
      width  = 11,             -- sprite width in cells (overrides species default)
      height = 5,              -- sprite height in cells (overrides species default)
      fps    = 8,
      area = {
        corner = "br",         -- "br" | "bl" | "tr" | "tl"
        cols   = 0,            -- 0 = auto: cover most of the editor width
        rows   = 0,            -- 0 = auto: cover most of the editor height
      },
    })
  end,
}
```

## Usage

| Command | What it does |
|---|---|
| `:Pets` (or `<leader>pp`) | toggle the pet on/off |
| `:PetsHelp` | show a floating cheat sheet of all commands |
| `:PetsResize <w> <h>` | resize sprite (cells); auto-grows the box if needed |
| `:PetsArea <cols> <rows>` | resize the wander box (cells) |
| `:PetsMove <corner>` | move box to corner (`br` / `bl` / `tr` / `tl`) |
| `:PetsType <name>` | switch species (`fox` / `panda` / `dog` / `turtle`) |
| `:PetsCount <n>` | set how many pets roam at once (1–6) |
| `:PetsState` | print current pet / action / direction / position / size / area |
| `:PetsThrow` (or `<leader>pb`) | throw a ball to the cursor; the pet fetches it |
| `:PetsFeed` (or `<leader>pf`) | feed the pet — raises its happiness |
| `:PetsStatus` | show the pet's happiness (0–100) and mood |
| `:PetsPomodoro [min]` | start a focus session (default 25 min); the pet celebrates when it ends |
| `:PetsPeek` / `:PetsWiggle` / `:PetsSwipe` / `:PetsObject` / `:PetsFollow` / `:PetsSleep` / `:PetsWake` | manually trigger lifestyle events (debug) |

Any `:Pets*` config command applied while the pet is visible briefly hides
and re-shows it with the new settings.

## Wandering across the editor

The pet roams a wander box that covers most of the editor by default
(`area.cols = 0`, `area.rows = 0`). It walks in any of 8 directions —
up, down, diagonals included — and refuses to step on any cell that
currently contains visible text, signs, line numbers, or sidebar
content. The grid of "blocked" cells is recomputed (debounced ~150ms)
on `TextChanged`, `WinScrolled`, `WinResized`, and a few other events
so the pet's view stays up to date as you edit.

If you'd rather keep the pet in a small corner, set `area.cols` and
`area.rows` to specific values and the `area.corner` to your preferred
anchor.

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
- **Cursor follow** — every ~35 seconds (±15s jitter), *if you've edited in
  the last ~20 seconds*, the pet walks over to a free cell next to the
  cursor and watches it for ~2.6 seconds before drifting back to wandering.
  Only fires while you're actively editing, so the pet looks attentive
  rather than constantly crowding the cursor. Reuses the walk → peek
  sprites; on arrival it faces toward the cursor.
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

Manual debug triggers: `:PetsPeek`, `:PetsWiggle`, `:PetsSwipe`, `:PetsObject`, `:PetsFollow`, `:PetsSleep`, `:PetsWake`.

## Reactions, care & companionship (v1.5)

The pet now reacts to what's happening and keeps a little persistent state:

- **Speech bubbles** — a small rounded bubble pops above the pet for
  reactions: `zzz` on sleep, an occasional `saved!` on `:w`, `!?` when LSP
  errors first appear and `yay!` when the last one clears, hearts on feed,
  a sigh when it's bored.
- **LSP reactions** — on `DiagnosticChanged` the pet does a brief in-place
  fluster the moment errors appear and a happy swipe when they're all gone.
  It never leaves its spot (the old run-to-the-error behavior was too
  disruptive).
- **Ball throw** — `:PetsThrow` (`<leader>pb`) drops a ball at the cursor and
  the pet runs to fetch it. The automatic ~3-minute ball spawn still happens
  on its own too.
- **Happiness (tamagotchi-lite)** — the pet has a happiness value (0–100)
  that slowly decays in real time and rises when you feed it (`:PetsFeed`),
  play fetch, or let it watch you work. It's saved to
  `stdpath("data")/nvim-pets-mood.json` so the pet remembers across
  sessions. `:PetsStatus` reports it; a sad pet sighs more.
- **Pomodoro companion** — `:PetsPomodoro [minutes]` starts a focus session;
  the pet announces it, sits with you, and celebrates with a swipe + bubble
  when the timer rings.
- **Day / night** — at night (22:00–06:00) the pet nods off to sleep sooner,
  and it yawns (`~`) now and then while idle.

## A whole flock (v1.6)

Set `count` (1–6) and that many pets roam the editor at once, each an
independent wanderer with the species' size, pace and personality:

```lua
require("pets").setup({ pet = "fox", count = 3 })
```

or at runtime with `:PetsCount 3`. The "lead" pet is the one that reacts to
saves, the cursor, the ball and LSP changes; the rest keep it company. When
two pets drift within a few cells of each other they turn and glance — a
little flock that notices itself. The whole flock naps and wakes together.

## Staying out of your way

The pet is built to be ambient, not a distraction:

- **Pets settle when you settle** — after ~1.2s with no cursor movement,
  typing or scrolling, the pets freeze completely (no motion, no redraws)
  and spring back to life the instant you do anything. Every Kitty redraw
  briefly nudges the terminal cursor, so holding still while you read a
  screenful of code is what actually stops the cursor from flickering. Tune
  it with `settle_ms` (0 disables — pets always animate).
- **Calm cursor** — even while active, a pet is only redrawn when it
  actually moves or its frame changes; a resting pet breathes about once a
  second rather than every frame.
- **Never covers your cursor while typing** — if a pet would be drawn over
  the insertion point in insert mode, that frame is skipped, so it never
  hides what you're writing.
- **Avoids your code** — pets only put their feet on empty cells, never on
  text, signs, numbers or sidebar content.
- **One bounded image per frame per pet** — sprite placements are reused and
  repositioned rather than re-transmitted per cell, so a long session
  doesn't pile up Kitty images.
- **Timers only run while visible** — toggling the pet off (or losing focus)
  stops all background work.

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
- [x] v1.4.2 (Phase 1): wander across the whole editor — 8-direction motion + buffer-aware avoidance so the pet never walks on top of code or sidebar contents
- [x] v1.4.3 (Phase 2): pet reacts to where the cursor is — walks over to the active edit and watches (cursor follow)
- [x] v1.5: speech bubbles, LSP reactions, ball-throw command, happiness/feeding (persisted), pomodoro companion, day/night behavior
- [x] v1.6: multiple pets on screen at once — per-instance pet state, a configurable flock (`count`), and pets that glance at each other
- [x] v1.6.1: non-intrusive polish — pets never draw over the cursor while you're typing
- [ ] v1.4.4: more objects (food bowl, box) and species-specific interaction sprites
- [ ] v1.4: environment objects (food bowl, ball, box) for richer pet interaction

## License

MIT — see [LICENSE](LICENSE).

Sprite asset credits: see [LICENSES.md](LICENSES.md).
