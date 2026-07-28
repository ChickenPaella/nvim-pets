# Requirements & troubleshooting

nvim-pets draws a **real image** through the Kitty Graphics Protocol, so the
pet only renders where three things line up. If any one is missing, `:Pets`
runs without an error but **nothing appears** (it fails silently).

## The three requirements

| Requirement | What you need |
|---|---|
| **OS** | macOS or Linux (Windows native is not supported) |
| **Terminal** | Kitty, WezTerm, or Ghostty |
| **Image processing** | ImageMagick (`brew install imagemagick`) |

One-liner: **macOS/Linux + a Kitty-protocol terminal (Kitty/WezTerm/Ghostty) + ImageMagick — that's the only combination that works.**

## Details

### 1. OS
- ✅ **macOS, Linux** — supported.
- ❌ **Windows (native)** — not supported: image.nvim and ImageMagick don't run
  natively, and Kitty/Ghostty have no Windows build.
- ⚠️ **Windows WSL2** — might work with WezTerm + ImageMagick inside WSL, but
  **untested**. Don't rely on it for a live demo.

### 2. Terminal (must speak the Kitty Graphics Protocol)
- ✅ Kitty, WezTerm, Ghostty
- ❌ iTerm2 — only supports its own inline-image protocol, not Kitty's
- ❌ Apple Terminal, Alacritty, VS Code integrated terminal — no graphics protocol

> **Why only the Kitty protocol?** Overlapping the pet on top of your code
> without covering it (z-index), and moving the sprite by repositioning an
> image *id* rather than re-transmitting it every frame, are only possible
> with the Kitty protocol. On older protocols each frame is re-sent, which
> flickers and piles up images until the terminal freezes. So this constraint
> is the precondition for a pet that *doesn't get in your way*.

### 3. ImageMagick
- image.nvim uses it **at runtime** to decode and render every sprite (it is
  **not** only for regenerating sprites — without it, nothing shows).
- macOS: `brew install imagemagick`.
- This project's recommended image.nvim config uses `processor = "magick_cli"`,
  so only the ImageMagick CLI is needed (no luarocks setup). The image.nvim
  default `magick_rock` processor instead needs the `magick` luarock.
- Verify the whole chain with `:checkhealth image`.

### 4. If you use tmux
Add to your `tmux.conf`:
```tmux
set -g allow-passthrough on
set -g focus-events on
```

## Nothing shows up — self-diagnosis order
1. `:checkhealth image` — check image.nvim / ImageMagick.
2. Confirm the terminal is Kitty / WezTerm / Ghostty (`echo $TERM_PROGRAM`).
3. Inside tmux? Confirm the passthrough settings above.
4. `:Pets` twice (off → on) — clears a tmux ghost frame.
