#!/usr/bin/env python3
"""Assemble the recorded stream into one looping GIF per demo beat.

One clip per beat rather than a single long video: a loop lets the presenter
talk over it for as long as they need, and four small files drop into slides
far more easily than one big one.
"""
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render import Renderer, load_cast   # noqa: E402

SP = os.path.dirname(os.path.abspath(__file__))
OUTDIR = os.path.join(SP, "clips")
FPS = 10
WIDTH = 1152          # downscaled from the native 1536 so the GIFs stay small

CLIPS = [
    ("01-avoids-code", 7.6, 21.6,
     "펫이 코드를 피해 걷고, 서 있는 자리에 코드가 오면 비킨다"),
    ("02-reacts",      22.2, 29.0, "에러가 나면 당황하고, 고치면 기뻐한다"),
    ("03-flock-ball",  29.5, 36.2, "공을 던지면 전원이 달려온다"),
    ("04-happiness",   36.5, 41.0, "행복도는 에디터를 닫아도 남는다"),
]


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    meta, chunks = load_cast()
    r = Renderer(meta, policy="lastwins")
    native_w = r.cols * r.cw
    scale = WIDTH / native_w
    print(f"native {native_w}x{r.rows*r.ch} → GIF {WIDTH}x{int(r.rows*r.ch*scale)} @ {FPS}fps\n")

    # Frame times we need, tagged with which clip they belong to.
    wanted = []
    for name, a, b, _ in CLIPS:
        t = a
        while t <= b:
            wanted.append((round(t, 3), name))
            t += 1.0 / FPS
    wanted.sort()

    grabbed = {name: [] for name, *_ in CLIPS}
    wi = 0
    pending = b""
    for t, chunk in chunks:
        data = pending + chunk
        pending = b""
        r.now = t
        while data:
            i = data.find(b"\x1b_G")
            if i < 0:
                if data.endswith(b"\x1b") or data.endswith(b"\x1b_"):
                    r.feed_text(data[:-2]); pending = data[-2:]
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

        while wi < len(wanted) and t >= wanted[wi][0]:
            ts, name = wanted[wi]
            r.now = ts
            img, n = r.frame()
            img = img.resize((WIDTH, int(img.height * scale)), Image.LANCZOS)
            grabbed[name].append(img)
            wi += 1

    total = 0
    for name, a, b, caption in CLIPS:
        fr = grabbed[name]
        if not fr:
            print(f"  {name}: 프레임 없음")
            continue
        # One shared adaptive palette across the clip keeps the file small and
        # avoids colours shifting between frames.
        pal = fr[0].quantize(colors=128, method=Image.MEDIANCUT)
        pframes = [f.quantize(colors=128, palette=pal, dither=Image.NONE) for f in fr]

        # Collapse runs of identical frames ourselves and carry their time
        # forward. Pillow's own optimizer drops the duplicates but keeps a
        # single flat duration, which made a mostly-static clip play back
        # three times too fast.
        step = int(1000 / FPS)
        uniq = []
        for f in pframes:
            if uniq and f.tobytes() == uniq[-1][0].tobytes():
                uniq[-1][1] += step
            else:
                uniq.append([f, step])
        imgs = [u[0] for u in uniq]
        durs = [u[1] for u in uniq]

        path = os.path.join(OUTDIR, name + ".gif")
        imgs[0].save(path, save_all=True, append_images=imgs[1:],
                     duration=durs, loop=0, optimize=False, disposal=1)
        kb = os.path.getsize(path) / 1024
        total += kb
        print(f"  {name+'.gif':<22} {len(imgs):>3}/{len(fr):<3} 프레임  "
              f"{sum(durs)/1000:>4.1f}초  {kb:>7.0f} KB   {caption}")
    print(f"\n합계 {total/1024:.1f} MB → {OUTDIR}")


if __name__ == "__main__":
    main()
