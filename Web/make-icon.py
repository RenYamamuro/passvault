#!/usr/bin/env python3
"""アプリのアイコンを作る。

  python3 Web/make-icon.py            … 候補を Web/icon-draft/ に並べる
  python3 Web/make-icon.py wheel      … 決めた案で本番の一式を作る

作り方の決めごと:
  ・4 倍で描いて縮める。Pillow の図形描画には縁の滑らかさが無いため
  ・角は丸めない。iOS も Android も自分で型を当てるので、
    こちらで丸めると二重に切られて縁が痩せる
  ・図は中央 60% に収める。maskable では外側が切り落とされることがある
  ・32px で読めることを最優先。潰れる細部は入れない
"""

import sys
from pathlib import Path

from PIL import Image, ImageDraw

HERE = Path(__file__).parent
S = 1024          # 仕上がりの一辺
SS = 4            # 何倍で描くか
N = S * SS

# 地の色。アプリのアクセント（藍）に合わせる。
SKY = (92, 111, 232)
DEEP = (46, 61, 168)
INK = (255, 255, 255)


def tile() -> Image.Image:
    """斜めのグラデーションを敷いた正方形。"""
    small = Image.new('RGB', (64, 64))
    px = small.load()
    for y in range(64):
        for x in range(64):
            t = (x + y) / 126
            px[x, y] = tuple(round(a + (b - a) * t) for a, b in zip(SKY, DEEP))
    return small.resize((N, N), Image.BICUBIC).convert('RGBA')


def line(draw, a, b, width):
    """端を丸めた線。Pillow の line には丸い端が無いので、円を足して作る。"""
    draw.line([a, b], fill=INK, width=width)
    r = width // 2
    for (x, y) in (a, b):
        draw.ellipse([x - r, y - r, x + r, y + r], fill=INK)


def wheel(draw):
    """金庫の handle。名前（Vault）に素直で、他のパスワード管理ツールと被らない。"""
    c = N // 2
    ring_r, ring_w = int(N * 0.200), int(N * 0.054)
    draw.ellipse([c - ring_r, c - ring_r, c + ring_r, c + ring_r],
                 outline=INK, width=ring_w)
    spoke_w = int(N * 0.052)
    # 輪の少し外まで。伸ばしすぎると照準器に見える。
    reach, inner = int(N * 0.262), int(N * 0.070)
    k = 0.7071
    for dx, dy in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
        line(draw,
             (c + int(inner * k * dx), c + int(inner * k * dy)),
             (c + int(reach * k * dx), c + int(reach * k * dy)),
             spoke_w)
    hub = int(N * 0.066)
    draw.ellipse([c - hub, c - hub, c + hub, c + hub], fill=INK)


def dial(draw):
    """同じ handle だが、輻を輪の内側で止めたもの。より静かに見える。"""
    c = N // 2
    ring_r, ring_w = int(N * 0.225), int(N * 0.050)
    draw.ellipse([c - ring_r, c - ring_r, c + ring_r, c + ring_r],
                 outline=INK, width=ring_w)
    spoke_w = int(N * 0.048)
    k = 0.7071
    inner, outer = int(N * 0.068), int(N * 0.200)
    for dx, dy in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
        line(draw,
             (c + int(inner * k * dx), c + int(inner * k * dy)),
             (c + int(outer * k * dx), c + int(outer * k * dy)),
             spoke_w)
    hub = int(N * 0.064)
    draw.ellipse([c - hub, c - hub, c + hub, c + hub], fill=INK)


def shield(draw):
    """盾に鍵穴。守ることと、秘密を収めることの両方を言う。"""
    c = N // 2
    w = int(N * 0.235)
    top, waist, tip_y = int(N * 0.235), int(N * 0.545), int(N * 0.790)
    r = int(N * 0.070)
    # 肩は角丸で、裾は中央へ絞る
    draw.rounded_rectangle([c - w, top, c + w, waist], radius=r, fill=INK,
                           corners=(True, True, False, False))

    def bez(p0, p1, p2, t):
        return (round((1 - t) ** 2 * p0[0] + 2 * (1 - t) * t * p1[0] + t ** 2 * p2[0]),
                round((1 - t) ** 2 * p0[1] + 2 * (1 - t) * t * p1[1] + t ** 2 * p2[1]))

    steps = 40
    skirt = [(c - w, waist - 2), (c + w, waist - 2)]
    right, tip, left = (c + w, waist), (c, tip_y), (c - w, waist)
    for i in range(1, steps + 1):
        skirt.append(bez(right, (c + w, int(N * 0.715)), tip, i / steps))
    for i in range(1, steps + 1):
        skirt.append(bez(tip, (c - w, int(N * 0.715)), left, i / steps))
    draw.polygon(skirt, fill=INK)

    # 鍵穴は地の色で抜く。盾の重心に置く。
    hy = int(N * 0.445)
    hole_r, tail_w = int(N * 0.066), int(N * 0.040)
    draw.ellipse([c - hole_r, hy - hole_r, c + hole_r, hy + hole_r], fill=(0, 0, 0, 0))
    draw.polygon([(c - tail_w, hy), (c + tail_w, hy),
                  (c + int(tail_w * 1.45), hy + int(N * 0.105)),
                  (c - int(tail_w * 1.45), hy + int(N * 0.105))], fill=(0, 0, 0, 0))


def key(draw):
    """鍵そのもの。何のアプリかを一番まっすぐに言う。"""
    c = N // 2
    head_r, stroke = int(N * 0.140), int(N * 0.054)
    k = 0.7071
    # 対角線の中心が絵の中心に来るように置く
    span = int(N * 0.235)
    hx, hy = c - int(span * k), c - int(span * k)
    ex, ey = c + int(span * k) + int(N * 0.030), c + int(span * k) + int(N * 0.030)
    draw.ellipse([hx - head_r, hy - head_r, hx + head_r, hy + head_r],
                 outline=INK, width=stroke)
    start = (hx + int(head_r * k), hy + int(head_r * k))
    line(draw, start, (ex, ey), stroke)
    # 歯は柄の片側に、先端の手前まで
    tooth = int(N * 0.092)
    for at in (0.58, 0.80):
        px = start[0] + (ex - start[0]) * at
        py = start[1] + (ey - start[1]) * at
        line(draw, (round(px), round(py)),
             (round(px + tooth * k), round(py - tooth * k)), stroke)


DESIGNS = {'wheel': wheel, 'dial': dial, 'shield': shield, 'key': key}


def render(name: str) -> Image.Image:
    base = tile()
    glyph = Image.new('RGBA', (N, N), (0, 0, 0, 0))
    DESIGNS[name](ImageDraw.Draw(glyph))
    base.alpha_composite(glyph)
    return base.resize((S, S), Image.LANCZOS).convert('RGB')


def drafts() -> int:
    out = HERE / 'icon-draft'
    out.mkdir(exist_ok=True)
    for name in DESIGNS:
        art = render(name)
        art.save(out / f'{name}-1024.png')
        # 小さくして潰れないかを見る。ここで読めない案は落とす。
        for size in (128, 48, 32):
            art.resize((size, size), Image.LANCZOS).save(out / f'{name}-{size}.png')
        print(f'  {name}')
    print(f'候補を書きました: {out}')
    return 0


def sheet() -> int:
    """候補を並べた 1 枚。小さいサイズで潰れないかは、並べないと分からない。"""
    sizes = [256, 128, 64, 40, 32]
    pad, gap, label = 26, 20, 34
    cols = pad * 2 + sum(sizes) + gap * (len(sizes) - 1)
    rows = pad * 2 + len(DESIGNS) * (256 + label)
    canvas = Image.new('RGB', (cols, rows), (244, 244, 247))
    draw = ImageDraw.Draw(canvas)
    y = pad
    for name in DESIGNS:
        art = render(name)
        draw.text((pad, y), name, fill=(40, 40, 48))
        x, top = pad, y + label
        for size in sizes:
            canvas.paste(art.resize((size, size), Image.LANCZOS),
                         (x, top + (256 - size) // 2))
            x += size + gap
        y += 256 + label
    out = HERE / 'icon-draft' / 'compare.png'
    out.parent.mkdir(exist_ok=True)
    canvas.save(out)
    print(f'比較表: {out}')
    return 0


def final(name: str) -> int:
    if name not in DESIGNS:
        print(f'知らない案です: {name}（{" / ".join(DESIGNS)}）', file=sys.stderr)
        return 1
    art = render(name)
    master = HERE / 'icon-master.png'
    art.save(master)
    print(f'書きました: {master}（案 {name}）')
    return 0


if __name__ == '__main__':
    arg = sys.argv[1] if len(sys.argv) > 1 else None
    if arg is None:
        sys.exit(drafts())
    sys.exit(sheet() if arg == 'compare' else final(arg))
