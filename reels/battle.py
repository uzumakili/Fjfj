"""模式 1：無意義大逃殺。一堆球在圈圈裡互撞，撞輸扣血，剩最後一顆獲勝。"""
import math
import random

from PIL import ImageDraw

from . import core
from .core import W, FPS

CX, CY, R0 = W / 2, 940, 460
SUB = 2


class Ball:
    def __init__(self, i, name, color, r, hp):
        self.i, self.name, self.color, self.r = i, name, color, r
        self.hp = self.max_hp = hp
        self.x = self.y = self.vx = self.vy = 0.0
        self.inv = 0.0  # 無敵到這個時間點


class Sim:
    def __init__(self, names, seed, hp):
        self.rng = rng = random.Random(seed)
        n = len(names)
        r = int(max(44, min(92, 0.56 * R0 / math.sqrt(n))))
        cols = core.palette(n, rng)
        self.balls = []
        order = list(range(n))
        rng.shuffle(order)
        for k, i in enumerate(order):
            b = Ball(i, names[i], cols[i], r, hp)
            a = math.tau * k / n
            ring = R0 * (0.62 if n > 1 else 0)
            b.x, b.y = CX + math.cos(a) * ring, CY + math.sin(a) * ring
            d = rng.uniform(0, math.tau)
            b.vx, b.vy = math.cos(d), math.sin(d)
            self.balls.append(b)
        self.t = 0.0
        self.R = R0
        self.r = r
        self.events = []

    def speed(self):
        return 470 * (1 + 0.013 * self.t)

    def step(self, dt):
        self.events = []
        for _ in range(SUB):
            self._sub(dt / SUB)

    def _sub(self, dt):
        self.t += dt
        # 場地會隨時間、也隨剩下的球數縮小，免得最後兩顆球一直撞不到
        alive = len(self.balls)
        want = min(R0, self.r * (1.7 * math.sqrt(alive) + 0.75))
        if self.t > 8:
            want = min(want, R0 - (self.t - 8) * 9)
        want = max(self.r * 2.7, want)
        self.R = max(want, self.R - 60 * dt)
        sp = self.speed()
        bs = self.balls
        for b in bs:
            m = math.hypot(b.vx, b.vy) or 1.0
            b.vx, b.vy = b.vx / m * sp, b.vy / m * sp
            b.x += b.vx * dt
            b.y += b.vy * dt
            dx, dy = b.x - CX, b.y - CY
            d = math.hypot(dx, dy)
            lim = self.R - b.r
            if d > lim and d > 0:
                nx, ny = dx / d, dy / d
                b.x, b.y = CX + nx * lim, CY + ny * lim
                vn = b.vx * nx + b.vy * ny
                if vn > 0:
                    b.vx -= 2 * vn * nx
                    b.vy -= 2 * vn * ny
                    # 加一點亂數，避免球卡在固定軌道繞圈
                    a = self.rng.uniform(-0.25, 0.25)
                    c, s = math.cos(a), math.sin(a)
                    b.vx, b.vy = b.vx * c - b.vy * s, b.vx * s + b.vy * c
                    self.events.append(("wall", b))
        dead = []
        for i in range(len(bs)):
            a = bs[i]
            for j in range(i + 1, len(bs)):
                b = bs[j]
                dx, dy = b.x - a.x, b.y - a.y
                d = math.hypot(dx, dy)
                if d >= a.r + b.r or d == 0:
                    continue
                nx, ny = dx / d, dy / d
                ov = (a.r + b.r - d) / 2
                a.x -= nx * ov
                a.y -= ny * ov
                b.x += nx * ov
                b.y += ny * ov
                rel = (b.vx - a.vx) * nx + (b.vy - a.vy) * ny
                if rel < 0:
                    a.vx += rel * nx
                    a.vy += rel * ny
                    b.vx -= rel * nx
                    b.vy -= rel * ny
                if self.t < a.inv or self.t < b.inv or a.hp <= 0 or b.hp <= 0:
                    continue
                win, lose = (a, b) if self.rng.random() < 0.5 else (b, a)
                lose.hp -= 1
                lose.inv = self.t + 0.55
                if lose.hp <= 0:
                    dead.append(lose)
                    self.events.append(("kill", win, lose))
                else:
                    self.events.append(("hit", win, lose))
        if dead:
            self.balls = [b for b in bs if b.hp > 0]


def _tune_hp(names, seed, target=26.0):
    """先不畫圖偷跑幾次，挑一個讓影片長度最接近 target 秒的血量。"""
    best, best_err = 3, 1e9
    for hp in (1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 18):
        s = Sim(names, seed, hp)
        while len(s.balls) > 1 and s.t < 60:
            s.step(1 / FPS)
        if abs(s.t - target) < best_err:
            best, best_err = hp, abs(s.t - target)
    return best


def make(out, title, names, seed, cta="Comment your pick"):
    hp = _tune_hp(names, seed)
    sim = Sim(names, seed, hp)
    fx_rng = random.Random(seed + 1)
    bg = core.background()
    audio = core.Audio()
    video = core.Video(out)
    parts = core.Particles()
    feed = []
    shake = 0.0
    winner = None
    end_t = None
    dt = 1 / FPS
    tsize = core.fit(title, W - 100, 88)

    while True:
        t = video.t
        sim.step(dt)
        for ev in sim.events:
            if ev[0] == "wall":
                audio.add(t, "tick", core.note(ev[1].i % 10, 523), 0.12, min_gap=0.03)
            elif ev[0] == "hit":
                audio.add(t, "pluck", core.note(ev[2].i % 10 + 2), 0.45)
                parts.burst(ev[2].x, ev[2].y, ev[2].color, n=8, speed=300, size=6,
                            life=0.4, rng=fx_rng)
            elif ev[0] == "kill":
                audio.add(t, "pop", 520, 0.8)
                audio.add(t, "boom", 0, 0.5)
                parts.burst(ev[2].x, ev[2].y, ev[2].color, n=46, rng=fx_rng)
                feed.append((t, ev[1], ev[2]))
                shake = 0.3
        if winner is None and len(sim.balls) == 1:
            winner = sim.balls[0]
            end_t = t + 2.8
            audio.fanfare(t + 0.1)
        if winner is not None:
            parts.confetti(fx_rng, 5)
        parts.step(dt)
        shake = max(0.0, shake - dt)
        ox = fx_rng.uniform(-1, 1) * shake * 45
        oy = fx_rng.uniform(-1, 1) * shake * 45

        img = bg.copy()
        core.aa_circle(img, CX + ox, CY + oy, sim.R, fill=(14, 13, 30))
        core.aa_circle(img, CX + ox, CY + oy, sim.R + 9, outline=(255, 255, 255),
                       width=9)
        d = ImageDraw.Draw(img)
        for b in sim.balls:
            spr = core.ball_sprite(b.r, b.color, b.name, b.hp, b.max_hp)
            core.paste_sprite(img, spr, b.x + ox, b.y + oy)
            if sim.t < b.inv and int(sim.t * 20) % 2 == 0:
                d.ellipse([b.x + ox - b.r, b.y + oy - b.r, b.x + ox + b.r,
                           b.y + oy + b.r], outline=(255, 255, 255), width=6)
        parts.draw(d, ox, oy)

        core.draw_text(d, (W / 2, 275), title, tsize, stroke=6)
        core.draw_text(d, (W / 2, 380), f"{len(sim.balls)} left", 52,
                       fill=(255, 220, 90))
        y = 1452
        for ft, a, b in feed[-2:]:
            age = t - ft
            k = max(0.35, 1 - age / 6)
            s = f"{a.name} eliminated {b.name}"
            core.draw_text(d, (W / 2, y), s, core.fit(s, W - 120, 46),
                           fill=core.shade((255, 255, 255), k), stroke=3)
            y += 56
        if winner is None:
            core.draw_text(d, (W / 2, 1562), cta, 50, fill=(140, 230, 255))
        else:
            core.banner(img, 1500, [("WINNER", 54, (255, 220, 90)),
                                    (winner.name, 130, winner.color)])
        video.write(img)
        if end_t is not None and t >= end_t:
            break
        if t > 75:
            break
    return video.close(audio)
