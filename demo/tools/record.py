#!/usr/bin/env python3
"""Record the demo by driving the real nvim in a pty and saving every byte it
writes, with timestamps. Markers note where each beat starts so the render
step can cut the stream into one clip per beat.

The pty is given pixel dimensions as well as rows/cols, because image.nvim
derives its cell size from ws_xpixel/ws_ypixel and scales the sprites to
match. Leave them zero and the sprites come out tiny.
"""
import fcntl
import json
import os
import pty
import select
import signal
import struct
import termios
import time

NVIM = "/opt/homebrew/bin/nvim"
DEMO = os.path.expanduser("~/projects/nvim-pets/demo/demo.lua")
OUT = os.path.dirname(os.path.abspath(__file__))

COLS, ROWS = 96, 30
CELL_W, CELL_H = 16, 32          # what we want image.nvim to think a cell is

frames = []      # (t, bytes)
marks = []       # (t, label)
t0 = None
fd = None


def drain(seconds):
    end = time.time() + seconds
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.02)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            frames.append((time.time() - t0, chunk))


def send(keys, wait):
    os.write(fd, keys.encode())
    drain(wait)


def mark(label):
    marks.append((time.time() - t0, label))
    print(f"  {time.time()-t0:6.1f}s  {label}", flush=True)


pid, fd = pty.fork()
if pid == 0:
    env = dict(os.environ)
    env.update({
        "TERM": "xterm-kitty",
        "TERM_PROGRAM": "WezTerm",
        "COLORTERM": "truecolor",
    })
    env.pop("TMUX", None)
    os.execvpe(NVIM, [NVIM, "--cmd", "set noswapfile", "--cmd", "set laststatus=0",
                      "-c", "silent! lua require('gitsigns').toggle_current_line_blame(false)",
                      f"+call cursor(42,49)", DEMO], env)

fcntl.ioctl(fd, termios.TIOCSWINSZ,
            struct.pack("HHHH", ROWS, COLS, COLS * CELL_W, ROWS * CELL_H))
t0 = time.time()

print("recording...", flush=True)
drain(7.0)                       # lazy.nvim + lua_ls workspace load

mark("start")
send(":Pets\r", 0.4)
mark("beat1")                    # pet appears and roams the ragged margin
send("", 2.6)
send("gg", 1.0)
send("}", 1.0)
send("}", 1.0)
send("G", 1.6)

# The strongest proof that it stays off the code: type a long line right
# where it is standing and watch it step aside. The pet spawns bottom-right,
# so appending a wide line at the end of the buffer lands under it.
mark("beat1b")
# Append wide lines at the end of the buffer, on screen, right where the pet
# likes to sit. Done with :call append rather than typing them, because
# 'textwidth' rewraps a long typed line and leaves the buffer in a state that
# is awkward to undo cleanly.
send("G", 0.8)
send(":call append(line('$'), [repeat('-',88), repeat('-',88), repeat('-',88)])\r", 0.6)
send("G", 3.2)                   # the pet is covered, and steps aside
send(":45,$d\r", 1.0)            # remove exactly the three lines we added
send("G", 1.0)

send(":call cursor(42,49)\r", 0.8)
mark("beat2")
send("x", 3.2)                   # syntax error → wiggle + 「!?」
send("u", 3.2)                   # fixed → swipe + 「yay!」
send("", 0.8)

mark("beat3")
send(":PetsCount 4\r", 1.6)
send(":PetsThrow\r", 5.5)        # the whole flock runs for the ball

mark("beat4")
send(":PetsFeed\r", 1.8)
send(":PetsStatus\r", 3.0)

mark("end")

# image.nvim writes each scaled sprite to a temp file and hands the terminal
# the *path*; nvim deletes that directory on exit. Copy them out while the
# session is still alive, otherwise the render step has nothing to paste.
import base64
import re
import shutil
cache = os.path.join(OUT, "sprites")
os.makedirs(cache, exist_ok=True)
stream_so_far = b"".join(b for _, b in frames)
copied = 0
for seq in re.findall(rb"\x1b_G(.*?)\x1b\\", stream_so_far, re.S):
    head, _, payload = seq.partition(b";")
    kv = dict(p.split("=", 1) for p in head.decode().split(",") if "=" in p)
    if kv.get("a") == "t" and kv.get("t") == "f" and payload:
        try:
            src = base64.b64decode(payload + b"==").decode()
        except Exception:
            continue
        dst = os.path.join(cache, os.path.basename(src))
        if os.path.exists(src) and not os.path.exists(dst):
            shutil.copy2(src, dst)
            copied += 1
print(f"스프라이트 {copied}개 복사 → {cache}")

send(":qa!\r", 0.8)
try:
    os.kill(pid, signal.SIGKILL)
except ProcessLookupError:
    pass
os.waitpid(pid, 0)
os.close(fd)

total = sum(len(b) for _, b in frames)
path = os.path.join(OUT, "cast.jsonl")
with open(path, "w") as f:
    f.write(json.dumps({
        "cols": COLS, "rows": ROWS,
        "cell_w": CELL_W, "cell_h": CELL_H,
        "marks": marks,
    }) + "\n")
    for t, b in frames:
        f.write(json.dumps([t, b.decode("latin-1")]) + "\n")

print(f"\n{len(frames)} chunks / {total:,} bytes → {path}")
print(f"길이 {frames[-1][0]:.1f}초 / Kitty 패킷 "
      f"{b''.join(b for _, b in frames).count(bytes.fromhex('1b5f47'))}개")
