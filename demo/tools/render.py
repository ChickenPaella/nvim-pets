#!/usr/bin/env python3
"""Turn the recorded pty stream into frames.

The text comes from replaying the stream through a VT emulator; the sprites
come from the Kitty graphics packets the stream carries (each one names a PNG
on disk, copied out at record time). Drawing order reproduces z=-1: cell
backgrounds, then sprites, then glyphs — so text always wins over a sprite,
which is exactly what the terminal does.
"""
import argparse
import base64
import json
import os
import re
import sys

import pyte
from PIL import Image, ImageDraw, ImageFont

SP = os.path.dirname(os.path.abspath(__file__))
FONT_PATH = os.path.expanduser("~/Library/Fonts/JetBrainsMonoNerdFont-Regular.ttf")
FONT_BOLD = os.path.expanduser("~/Library/Fonts/JetBrainsMonoNerdFont-Bold.ttf")

# gruvbox-ish fallbacks, used only where the stream says "default"
DEF_BG = (0x28, 0x28, 0x28)
DEF_FG = (0xEB, 0xDB, 0xB2)

NAMED = {
    "black": (0x28, 0x28, 0x28), "red": (0xCC, 0x24, 0x1D),
    "green": (0x98, 0x97, 0x1A), "brown": (0xD7, 0x99, 0x21),
    "blue": (0x45, 0x85, 0x88), "magenta": (0xB1, 0x62, 0x86),
    "cyan": (0x68, 0x9D, 0x6A), "white": (0xA8, 0x99, 0x84),
    "brightblack": (0x92, 0x83, 0x74), "brightred": (0xFB, 0x49, 0x34),
    "brightgreen": (0xB8, 0xBB, 0x26), "brightbrown": (0xFA, 0xBD, 0x2F),
    "brightblue": (0x83, 0xA5, 0x98), "brightmagenta": (0xD3, 0x86, 0x9B),
    "brightcyan": (0x8E, 0xC0, 0x7C), "brightwhite": (0xEB, 0xDB, 0xB2),
}


def rgb(c, fallback):
    if c is None or c == "default":
        return fallback
    if isinstance(c, str) and len(c) == 6:
        try:
            return (int(c[0:2], 16), int(c[2:4], 16), int(c[4:6], 16))
        except ValueError:
            pass
    return NAMED.get(c, fallback)


def load_cast():
    lines = open(os.path.join(SP, "cast.jsonl")).read().split("\n")
    meta = json.loads(lines[0])
    chunks = []
    for line in lines[1:]:
        if line.strip():
            t, s = json.loads(line)
            chunks.append((t, s.encode("latin-1")))
    return meta, chunks


class Renderer:
    def __init__(self, meta, policy, scale=1):
        self.cols, self.rows = meta["cols"], meta["rows"]
        self.cw, self.ch = meta["cell_w"], meta["cell_h"]
        self.policy = policy
        self.scale = scale
        self.screen = pyte.Screen(self.cols, self.rows)
        self.vt = pyte.ByteStream(self.screen)
        self.images = {}       # kitty image id -> png path
        # image.nvim retires the previous frame by deleting the image right
        # after placing the new one, so honouring `a=d` literally leaves the
        # screen empty. Instead track one *slot* per sprite on screen and
        # match each new placement to the nearest slot of the same size —
        # pets move at most one cell per tick, so proximity identifies them.
        # A slot that stops being refreshed for TTL seconds is gone.
        self.slots = []        # {sid, row, col, w, h, path, t}
        self.next_sid = 0
        self.claimed = set()   # slot ids already assigned in the current tick
        self.last_place_t = -1e9
        self.now = 0.0
        self.sprite_cache = {}
        size = self._fit_font()
        self.font = ImageFont.truetype(FONT_PATH, size)
        self.bold = ImageFont.truetype(FONT_BOLD, size)
        # baseline offset so glyphs sit nicely in the cell
        asc, desc = self.font.getmetrics()
        self.baseline = max(0, (self.ch - (asc + desc)) // 2)

    def _fit_font(self):
        best, bestd = 10, 1e9
        for s in range(8, 40):
            f = ImageFont.truetype(FONT_PATH, s)
            d = abs(f.getlength("M") - self.cw)
            if d < bestd:
                best, bestd = s, d
        return best

    # ── stream handling ─────────────────────────────────────────────────
    def feed_text(self, data):
        if data:
            self.vt.feed(data)

    TTL = 2.0        # a resting pet re-renders about once a second
    BATCH_GAP = 0.10 # placements closer than this belong to the same tick

    def handle_apc(self, body):
        head, _, payload = body.partition(b";")
        kv = dict(p.split("=", 1) for p in head.decode("ascii", "replace").split(",")
                  if "=" in p)
        a = kv.get("a")
        iid = kv.get("i")
        if a == "t" and kv.get("t") == "f" and payload:
            try:
                path = base64.b64decode(payload + b"==").decode()
            except Exception:
                return
            self.images[iid] = os.path.join(SP, "sprites", os.path.basename(path))
        elif a == "p":
            row, col = self.screen.cursor.y, self.screen.cursor.x
            w = int(kv.get("w", 0) or 0)
            h = int(kv.get("h", 0) or 0)
            path = self.images.get(iid)
            if not path:
                return
            # All views are drawn inside one master tick, so placements that
            # arrive together belong to *different* sprites, and placements in
            # a later tick are the same sprites having moved. Assign each
            # placement to the nearest slot not already claimed this tick —
            # distance is only a tie-breaker, not a gate, because a boxed-in
            # pet relocates across the screen in a single step. Gating on
            # distance left the old position on screen as a ghost, sitting on
            # the very code the pet had just stepped off.
            if self.now - self.last_place_t > self.BATCH_GAP:
                self.claimed = set()
            self.last_place_t = self.now

            best, bestd = None, 10 ** 9
            for sl in self.slots:
                if sl["w"] != w or sl["h"] != h or sl["sid"] in self.claimed:
                    continue
                d = max(abs(sl["row"] - row), abs(sl["col"] - col))
                if d < bestd:
                    best, bestd = sl, d
            if best is not None:
                best.update(row=row, col=col, path=path, t=self.now)
                self.claimed.add(best["sid"])
            else:
                self.slots.append(dict(sid=self.next_sid, row=row, col=col,
                                       w=w, h=h, path=path, t=self.now))
                self.claimed.add(self.next_sid)
                self.next_sid += 1
        elif a == "d":
            # Only a wholesale "delete everything" is meaningful to us; that
            # is what :Pets / :PetsCount send when they tear the float down.
            if kv.get("d", "a") in ("a", "A"):
                self.slots.clear()
                self.claimed.clear()
        # else: transmit acks, queries, animation frames we don't need

    def live(self, keep=None):
        alive = [s for s in self.slots if self.now - s["t"] <= self.TTL]
        self.slots = alive
        return alive

    # ── drawing ────────────────────────────────────────────────────────
    def sprite(self, path):
        if path not in self.sprite_cache:
            try:
                self.sprite_cache[path] = Image.open(path).convert("RGBA")
            except Exception:
                self.sprite_cache[path] = None
        return self.sprite_cache[path]

    def frame(self, keep=1):
        W, H = self.cols * self.cw, self.rows * self.ch
        img = Image.new("RGB", (W, H), DEF_BG)
        d = ImageDraw.Draw(img)
        buf = self.screen.buffer

        # 1. cell backgrounds
        for y in range(self.rows):
            row = buf[y]
            for x in range(self.cols):
                c = row[x]
                fgc, bgc = c.fg, c.bg
                if c.reverse:
                    fgc, bgc = bgc, fgc
                bg = rgb(bgc, None)
                if bg is not None and bg != DEF_BG:
                    d.rectangle([x * self.cw, y * self.ch,
                                 (x + 1) * self.cw - 1, (y + 1) * self.ch - 1], fill=bg)

        # 2. sprites (z = -1, so under the glyphs)
        n = 0
        for sl in self.live():
            row, col, w, h = sl["row"], sl["col"], sl["w"], sl["h"]
            sp = self.sprite(sl["path"])
            if sp is None:
                continue
            if w and h and sp.size != (w, h):
                sp = sp.resize((w, h), Image.LANCZOS)
            img.paste(sp, (col * self.cw, row * self.ch), sp)
            n += 1

        # 3. glyphs
        for y in range(self.rows):
            row = buf[y]
            for x in range(self.cols):
                c = row[x]
                if not c.data or c.data == " ":
                    continue
                fgc, bgc = c.fg, c.bg
                if c.reverse:
                    fgc, bgc = bgc, fgc
                d.text((x * self.cw, y * self.ch + self.baseline), c.data,
                       font=(self.bold if c.bold else self.font),
                       fill=rgb(fgc, DEF_FG))

        if self.scale != 1:
            img = img.resize((W * self.scale, H * self.scale), Image.LANCZOS)
        return img, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--policy", default="lastwins", choices=["strict", "lastwins"])
    ap.add_argument("--at", type=float, action="append", default=None,
                    help="dump a single frame at this timestamp (repeatable)")
    ap.add_argument("--keep", type=int, default=1)
    ap.add_argument("--out", default="probe")
    args = ap.parse_args()

    meta, chunks = load_cast()
    print("marks:", [(round(t, 1), n) for t, n in meta["marks"]])
    r = Renderer(meta, args.policy)
    print(f"grid {r.cols}x{r.rows} cell {r.cw}x{r.ch} font {r.font.size}px "
          f"advance {r.font.getlength('M'):.1f}px")

    targets = sorted(args.at or [12.0])
    ti = 0
    pending = b""
    for t, chunk in chunks:
        data = pending + chunk
        pending = b""
        r.now = t
        while data:
            i = data.find(b"\x1b_G")
            if i < 0:
                if data.endswith(b"\x1b") or data.endswith(b"\x1b_"):
                    keep_tail = 2
                    r.feed_text(data[:-keep_tail]); pending = data[-keep_tail:]
                else:
                    r.feed_text(data)
                break
            j = data.find(b"\x1b\\", i)
            if j < 0:
                r.feed_text(data[:i]); pending = data[i:]
                break
            r.feed_text(data[:i])
            r.handle_apc(data[i + 3:j])
            data = data[j + 2:]

        while ti < len(targets) and t >= targets[ti]:
            r.now = t
            img, n = r.frame()
            path = os.path.join(SP, f"{args.out}-{targets[ti]:g}s.png")
            img.save(path)
            print(f"  t={targets[ti]:>5.1f}s  sprites={n}  → {path}")
            ti += 1
    while ti < len(targets):
        img, n = r.frame()
        path = os.path.join(SP, f"{args.out}-{targets[ti]:g}s.png")
        img.save(path)
        print(f"  t={targets[ti]:>5.1f}s (end)  sprites={n}  → {path}")
        ti += 1


if __name__ == "__main__":
    main()
