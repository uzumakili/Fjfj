"""模式 2：彈珠賽跑。一堆球從上面掉下來，穿過各種障礙，先到終點的贏。"""
import math
import random

from PIL import Image, ImageDraw

from . import core
from .core import W, H, FPS

WL, WR = 50, 1030          # 左右牆
SEC_H = 800                # 每段關卡的高度
START_Y = 1000             # 第一段關卡從這裡開始
BALL_Y0 = 620              # 球的起跑位置
N_MAX = 18                 # 關卡最多幾段
BR = 32                    # 球半徑
SUB = 4
G = 1500
BAR_T = 9                  # 橫桿半粗細
KINDS = ["pegs", "zigzag", "bumpers", "spinners", "funnel"]


class Course:
    def __init__(self, rng, n):
        self.kinds = []
        self.pegs = [[] for _ in range(n)]      # (x, y, r, 是否彈力球)
        self.segs = [[] for _ in range(n)]      # (x1, y1, x2, y2)
        self.spins = [[] for _ in range(n)]     # (cx, cy, 半長, 角速度, 初始角)
        prev = None
        for i in range(n):
            kind = "pegs" if i == 0 else rng.choice([k for k in KINDS if k != prev])
            prev = kind
            self.kinds.append(kind)
            getattr(self, "_" + kind)(i, START_Y + i * SEC_H, rng)

    def _pegs(self, i, y, rng):
        step = (WR - WL) / 8
        for row in range(6):
            yy = y + 80 + row * 120
            if row % 2 == 0:
                xs = [WL + step * k for k in range(1, 8)]
            else:
                xs = [WL + step * (k + 0.5) for k in range(1, 7)]
            for x in xs:
                self.pegs[i].append((x, yy, 13, False))

    def _zigzag(self, i, y, rng):
        left = rng.random() < 0.5
        span = (WR - WL) * 0.66
        for k in range(3):
            yy = y + 60 + k * 250
            if left:
                self.segs[i].append((WL, yy, WL + span, yy + 190))
            else:
                self.segs[i].append((WR, yy, WR - span, yy + 190))
            left = not left

    def _bumpers(self, i, y, rng):
        for row, xs in enumerate([(300, 780), (540,), (300, 780)]):
            for x in xs:
                self.pegs[i].append((x, y + 150 + row * 240, 55, True))

    def _spinners(self, i, y, rng):
        s = rng.choice([-1, 1])
        for cx, cy, sg in [(300, y + 230, s), (780, y + 230, -s), (540, y + 560, s)]:
            self.spins[i].append((cx, cy, 150, sg * rng.uniform(2.2, 3.2),
                                  rng.uniform(0, math.pi)))

    def _funnel(self, i, y, rng):
        self.segs[i].append((WL, y + 120, 405, y + 380))
        self.segs[i].append((WR, y + 120, 675, y + 380))
        self.pegs[i].append((540, y + 580, 34, True))
        self.pegs[i].append((290, y + 640, 13, False))
        self.pegs[i].append((790, y + 640, 13, False))

    def image(self, i):
        """把第 i 段的固定障礙畫成一張圖（先畫兩倍大再縮小，邊緣才平滑）。"""
        ss = 2
        y0 = START_Y + i * SEC_H
        im = Image.new("RGBA", (W * ss, SEC_H * ss), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        for x1, y1, x2, y2 in self.segs[i]:
            a, b = (x1 * ss, (y1 - y0) * ss), (x2 * ss, (y2 - y0) * ss)
            d.line([a, b], fill=(235, 235, 255, 255), width=BAR_T * 2 * ss)
            for px, py in (a, b):
                r = BAR_T * ss
                d.ellipse([px - r, py - r, px + r, py + r], fill=(235, 235, 255, 255))
        for x, y, r, bouncy in self.pegs[i]:
            col = (255, 90, 140, 255) if bouncy else (235, 235, 255, 255)
            cx, cy, rr = x * ss, (y - y0) * ss, r * ss
            d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=col)
            if bouncy:
                r2 = rr * 0.6
                d.ellipse([cx - r2, cy - r2, cx + r2, cy + r2],
                          fill=(255, 170, 200, 255))
        return im.reduce(ss)


class Ball:
    def __init__(self, i, name, color):
        self.i, self.name, self.color = i, name, color
        self.x = self.y = self.vx = self.vy = 0.0
        self.rank = None
        self.chk_t, self.chk_x, self.chk_y = 0.0, 0.0, 0.0


class Sim:
    def __init__(self, names, seed, n_sections, finish_y=None):
        self.rng = rng = random.Random(seed)
        self.course = Course(rng, N_MAX)  # 固定段數，亂數順序才會每次一致
        self.n_sections = n_sections
        self.finish_y = finish_y
        self.floor_y = (finish_y + 560) if finish_y else None
        cols = core.palette(len(names), rng)
        self.balls = []
        slots = [(c, r) for r in range(4) for c in range(6)]
        rng.shuffle(slots)
        for i, name in enumerate(names):
            b = Ball(i, name, cols[i])
            c, r = slots[i % len(slots)]
            b.x = WL + 120 + c * 148 + rng.uniform(-20, 20)
            b.y = BALL_Y0 + r * 90 + rng.uniform(-10, 10)
            b.vx = rng.uniform(-60, 60)
            b.chk_x, b.chk_y = b.x, b.y
            self.balls.append(b)
        self.t = 0.0
        self.finished = []
        self.events = []

    def leader(self):
        return max(self.balls, key=lambda b: b.y)

    def order(self):
        rest = sorted((b for b in self.balls if b.rank is None), key=lambda b: -b.y)
        return self.finished + rest

    def step(self, dt):
        self.events = []
        for _ in range(SUB):
            self._sub(dt / SUB)

    def _hit(self, b, px, py, pr, rest, ovx=0.0, ovy=0.0, bouncy=False):
        dx, dy = b.x - px, b.y - py
        d2 = dx * dx + dy * dy
        rr = BR + pr
        if d2 >= rr * rr or d2 == 0:
            return
        d = math.sqrt(d2)
        nx, ny = dx / d, dy / d
        b.x, b.y = px + nx * rr, py + ny * rr
        vn = (b.vx - ovx) * nx + (b.vy - ovy) * ny
        if vn < 0:
            out = -vn * rest
            if bouncy:
                out = max(out, 620)
            b.vx += (out - vn) * nx
            b.vy += (out - vn) * ny
            b.vx += self.rng.uniform(-12, 12)
            if -vn > 160:
                self.events.append(("bump" if bouncy else "hit", b, -vn))

    def _sub(self, dt):
        self.t += dt
        c = self.course
        damp = 1 - 0.25 * dt
        for b in self.balls:
            b.vy += G * dt
            b.vx *= damp
            b.vy *= damp
            sp = math.hypot(b.vx, b.vy)
            if sp > 1500:
                b.vx, b.vy = b.vx / sp * 1500, b.vy / sp * 1500
            b.x += b.vx * dt
            b.y += b.vy * dt
            if b.x < WL + BR:
                b.x = WL + BR
                b.vx = abs(b.vx) * 0.5
            elif b.x > WR - BR:
                b.x = WR - BR
                b.vx = -abs(b.vx) * 0.5
            if self.floor_y and b.y > self.floor_y - BR:
                b.y = self.floor_y - BR
                b.vy = -abs(b.vy) * 0.3
                b.vx *= 0.98
            s = int((b.y - START_Y) // SEC_H)
            if 0 <= s < self.n_sections and not (self.finish_y and b.y > self.finish_y):
                for x, y, r, bouncy in c.pegs[s]:
                    self._hit(b, x, y, r, 0.55, bouncy=bouncy)
                for x1, y1, x2, y2 in c.segs[s]:
                    ex, ey = x2 - x1, y2 - y1
                    u = ((b.x - x1) * ex + (b.y - y1) * ey) / (ex * ex + ey * ey)
                    u = max(0.0, min(1.0, u))
                    self._hit(b, x1 + ex * u, y1 + ey * u, BAR_T, 0.35)
                for cx, cy, hl, om, ph in c.spins[s]:
                    a = ph + om * self.t
                    ex, ey = math.cos(a) * hl, math.sin(a) * hl
                    u = ((b.x - cx) * ex + (b.y - cy) * ey) / (hl * hl)
                    u = max(-1.0, min(1.0, u))
                    px, py = cx + ex * u, cy + ey * u
                    self._hit(b, px, py, BAR_T, 0.5, -om * (py - cy), om * (px - cx))
            if b.rank is None:
                if self.finish_y and b.y > self.finish_y:
                    b.rank = len(self.finished) + 1
                    self.finished.append(b)
                    self.events.append(("finish", b, 0))
                elif self.t - b.chk_t > 1.5:
                    # 卡住超過 1.5 秒就踢它一腳
                    if math.hypot(b.x - b.chk_x, b.y - b.chk_y) < 25:
                        b.vx = self.rng.choice([-1, 1]) * 420
                        b.vy = -520
                    b.chk_t, b.chk_x, b.chk_y = self.t, b.x, b.y
        bs = self.balls
        for i in range(len(bs)):
            a = bs[i]
            for j in range(i + 1, len(bs)):
                b = bs[j]
                dx, dy = b.x - a.x, b.y - a.y
                if abs(dy) >= 2 * BR or abs(dx) >= 2 * BR:
                    continue
                d = math.hypot(dx, dy)
                if d >= 2 * BR or d == 0:
                    continue
                nx, ny = dx / d, dy / d
                ov = (2 * BR - d) / 2
                a.x -= nx * ov
                a.y -= ny * ov
                b.x += nx * ov
                b.y += ny * ov
                rel = (b.vx - a.vx) * nx + (b.vy - a.vy) * ny
                if rel < 0:
                    k = rel * 0.8
                    a.vx += k * nx
                    a.vy += k * ny
                    b.vx -= k * nx
                    b.vy -= k * ny


def _plan(names, seed, target=25.0, n_max=N_MAX):
    """先不畫圖偷跑一次，看領先的球 target 秒時跑到第幾段，終點就設在那段的結尾。"""
    s = Sim(names, seed, n_max)
    while s.t < target:
        s.step(1 / FPS)
    sec = int((s.leader().y - START_Y) // SEC_H)
    sec = max(2, min(n_max - 1, sec))
    return sec + 1


def make(out, title, names, seed, cta="留言你押誰"):
    n = _plan(names, seed)
    finish_y = START_Y + n * SEC_H
    sim = Sim(names, seed, n, finish_y)
    rng = random.Random(seed + 1)
    bg = core.background()
    audio = core.Audio()
    video = core.Video(out)
    parts = core.Particles()
    sec_img = {}
    cam = 0.0
    cam_max = finish_y - H * 0.42
    end_t = None
    win_t = None
    dt = 1 / FPS
    tsize = core.fit(title, W - 100, 84)

    while True:
        t = video.t
        sim.step(dt)
        for kind, b, v in sim.events:
            if kind == "hit":
                audio.add(t, "tick", core.note(b.i % 10, 392), min(0.3, v / 3000),
                          min_gap=0.03)
            elif kind == "bump":
                audio.add(t, "pop", 500 + b.i * 25, 0.4, min_gap=0.04)
            elif kind == "finish":
                parts.burst(b.x, b.y, b.color, n=30, rng=rng)
                if b.rank == 1:
                    win_t = t
                    audio.fanfare(t)
                else:
                    audio.add(t, "pluck", core.note(8 - min(b.rank, 6)), 0.5)
        if win_t is not None and end_t is None:
            if len(sim.finished) >= min(3, len(sim.balls)) or t - win_t > 4:
                end_t = t + 2.8
        if win_t is not None:
            parts.confetti(rng, 4)
        parts.step(dt)

        lead = sim.leader()
        target = min(cam_max, lead.y - H * 0.52)
        cam += (max(0.0, target) - cam) * 0.09

        img = bg.copy()
        d = ImageDraw.Draw(img)
        d.rectangle([0, 0, WL, H], fill=(60, 56, 96))
        d.rectangle([WR, 0, W, H], fill=(60, 56, 96))
        # 終點線
        fy = finish_y - cam
        if fy < H + 40:
            sq = 35
            for row in range(2):
                for k in range(int((WR - WL) / sq)):
                    col = (255, 255, 255) if (k + row) % 2 == 0 else (20, 20, 20)
                    d.rectangle([WL + k * sq, fy + row * sq, WL + (k + 1) * sq,
                                 fy + (row + 1) * sq], fill=col)
            d.rectangle([WL, sim.floor_y - cam, WR, sim.floor_y - cam + 14],
                        fill=(235, 235, 255))
        s0 = int((cam - START_Y) // SEC_H)
        for s in (s0, s0 + 1, s0 + 2, s0 + 3):
            if not 0 <= s < n:
                continue
            if s not in sec_img:
                sec_img[s] = sim.course.image(s)
            for old in [k for k in sec_img if k < s0 - 1]:
                del sec_img[old]
            sy = START_Y + s * SEC_H - cam
            if sy < H and sy + SEC_H > 0:
                img.paste(sec_img[s], (0, int(round(sy))), sec_img[s])
            for cx, cy, hl, om, ph in sim.course.spins[s]:
                a = ph + om * sim.t
                ex, ey = math.cos(a) * hl, math.sin(a) * hl
                p1, p2 = (cx - ex, cy - ey - cam), (cx + ex, cy + ey - cam)
                d.line([p1, p2], fill=(120, 255, 190), width=BAR_T * 2)
                for px, py in (p1, p2, (cx, cy - cam)):
                    r = BAR_T + (3 if (px, py) == (cx, cy - cam) else 0)
                    d.ellipse([px - r, py - r, px + r, py + r], fill=(120, 255, 190))
        for b in sim.balls:
            y = b.y - cam
            if -80 < y < H + 80:
                core.paste_sprite(img, core.ball_sprite(BR, b.color), b.x, y)
        for b in sim.balls:
            y = b.y - cam
            if -80 < y < H + 80:
                core.draw_text(d, (b.x, y - BR - 20), b.name, 30, fill=b.color,
                               stroke=3)
        parts.draw(d, 0, -cam)

        # 上方標題與即時名次
        img.paste((0, 0, 0), (0, 0), Image.new("L", (W, 520), 225))
        d = ImageDraw.Draw(img)
        core.draw_text(d, (W / 2, 275), title, tsize, stroke=6)
        order = sim.order()
        x = 90
        for k, b in enumerate(order[:3]):
            s = f"{k + 1}. {b.name}"
            fs = 46
            core.draw_text(d, (x, 385 + k * 56), s, fs, fill=b.color, anchor="lm",
                           stroke=3)
        prog = min(1.0, max(0.0, (lead.y - BALL_Y0) / (finish_y - BALL_Y0)))
        d.rectangle([620, 372, 990, 396], fill=(40, 40, 60))
        d.rectangle([620, 372, 620 + 370 * prog, 396], fill=(255, 220, 90))
        core.draw_text(d, (805, 440), f"進度 {int(prog * 100)}%", 40, stroke=3)
        if end_t is None:
            core.draw_text(d, (W / 2, 1548), cta, 50, fill=(140, 230, 255))
        else:
            top = sim.finished
            lines = [("冠軍", 54, (255, 220, 90)), (top[0].name, 130, top[0].color)]
            if len(top) > 1:
                rest = "　".join(f"{k + 2}. {b.name}" for k, b in enumerate(top[1:3]))
                lines.append((rest, 50, (255, 255, 255)))
            core.banner(img, 820, lines)
        video.write(img)
        if end_t is not None and t >= end_t:
            break
        if t > 90:
            break
    return video.close(audio)
