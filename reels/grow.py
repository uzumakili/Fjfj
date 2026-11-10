"""模式 6：越來越失控。
grow     ：一顆球每彈一次就變大，直到塞滿整個圈。
multiply ：每撞一次牆就多一顆球，直到滿出來。
"""
import math
import random

import numpy as np
from PIL import ImageDraw

from . import core
from .core import W, FPS

CX, CY, R = W / 2, 940, 450
SUB = 8


# ------------------------------------------------------------ 變大

class GrowSim:
    def __init__(self, seed, growth):
        rng = random.Random(seed)
        self.growth = growth
        self.r = 22.0
        self.x, self.y = CX + rng.uniform(-150, 150), CY - 150
        a = rng.uniform(-0.9, 0.9)
        self.vx, self.vy = math.sin(a) * 500, -math.cos(a) * 300
        self.g = 1700
        self.vmin = 950.0
        self.t = 0.0
        self.bounces = 0
        self.done = False
        self.hits = 0  # 這一格發生幾次彈跳

    def step(self, dt):
        self.hits = 0
        if self.done:
            return
        h = dt / SUB
        for _ in range(SUB):
            self.t += h
            self.vy += self.g * h
            self.x += self.vx * h
            self.y += self.vy * h
            dx, dy = self.x - CX, self.y - CY
            d = math.hypot(dx, dy)
            lim = R - self.r
            if d >= lim and d > 0:
                nx, ny = dx / d, dy / d
                vn = self.vx * nx + self.vy * ny
                if vn > 0:
                    self.vx -= 2 * vn * nx
                    self.vy -= 2 * vn * ny
                    sp = math.hypot(self.vx, self.vy)
                    tgt = max(self.vmin, sp) * 1.006
                    self.vx, self.vy = self.vx / sp * tgt, self.vy / sp * tgt
                    self.vmin *= 1.006
                    self.bounces += 1
                    self.hits += 1
                    self.r = self.r * self.growth + 1.2
                if self.r >= R - 1:
                    self.r = R
                    self.x, self.y = CX, CY
                    self.done = True
                    return
                lim = R - self.r
                self.x, self.y = CX + nx * lim, CY + ny * lim


def _tune_growth(seed, target=22.0):
    """試一排成長率，挑塞滿時間最接近 target 秒的那個。"""
    best, best_err = 1.03, 1e9
    for i in range(40):
        gr = 1.004 + i * 0.003
        s = GrowSim(seed, gr)
        while not s.done and s.t < 60:
            s.step(1 / FPS)
        if abs(s.t - target) < best_err:
            best, best_err = gr, abs(s.t - target)
    return best


def make_grow(out, seed, title="The ball grows every bounce"):
    sim = GrowSim(seed, _tune_growth(seed))
    rng = random.Random(seed + 1)
    hue0 = rng.random()
    bg = core.background()
    audio = core.Audio()
    video = core.Video(out)
    parts = core.Particles()
    trail = []
    flash = 0.0
    end_t = None
    dt = 1 / FPS
    tsize = core.fit(title, W - 100, 88)

    while True:
        t = video.t
        was_done = sim.done
        sim.step(dt)
        color = core.hsv(hue0 + sim.bounces * 0.037, 0.75, 1.0)
        if sim.hits:
            n = sim.bounces
            audio.add(t, "pluck", core.note(n % 15, 196), 0.5, min_gap=0.045)
            flash = 1.0
            if sim.r < R * 0.8:
                parts.burst(sim.x, sim.y, color, n=6, speed=350, size=6, life=0.4,
                            rng=rng)
        if sim.done and not was_done:
            end_t = t + 2.6
            audio.add(t, "boom", 0, 0.9)
            audio.fanfare(t + 0.25)
            flash = 2.5
        if sim.done:
            parts.confetti(rng, 5)
        parts.step(dt)
        flash = max(0.0, flash - dt * 5)
        trail.append((sim.x, sim.y, sim.r, color))
        trail = trail[-10:]

        img = bg.copy()
        core.aa_circle(img, CX, CY, R, fill=(14, 13, 30))
        ring = core.mix((255, 255, 255), color, min(1.0, flash))
        core.aa_circle(img, CX, CY, R + 10, outline=ring, width=10)
        d = ImageDraw.Draw(img)
        if not sim.done:
            for k, (x, y, r, c) in enumerate(trail[:-1]):
                f = (k + 1) / len(trail) * 0.35
                cc = core.mix((14, 13, 30), c, f)
                d.ellipse([x - r, y - r, x + r, y + r], fill=cc)
        core.aa_circle(img, sim.x, sim.y, sim.r, fill=core.shade(color, 0.55))
        core.aa_circle(img, sim.x, sim.y, sim.r - max(3, sim.r * 0.07), fill=color)
        d = ImageDraw.Draw(img)
        parts.draw(d)
        core.draw_text(d, (W / 2, 275), title, tsize, stroke=6)
        core.draw_text(d, (W / 2, 380), f"Bounces: {sim.bounces}", 56,
                       fill=(255, 220, 90))
        if sim.done:
            core.banner(img, CY, [("FULL!", 120, (255, 255, 255)),
                                  (f"{sim.bounces} bounces total", 60, (255, 220, 90))])
        else:
            core.draw_text(d, (W / 2, 1520), "Guess how many bounces to fill it", 50,
                           fill=(140, 230, 255))
        video.write(img)
        if end_t is not None and t >= end_t:
            break
        if t > 80:
            break
    return video.close(audio)


# ------------------------------------------------------------ 變多

class MultiSim:
    def __init__(self, seed, cap, g):
        self.rng = np.random.default_rng(seed)
        self.cap = cap
        self.g = g
        self.r = 13.0
        self.pos = np.array([[CX, CY - 200.0]])
        self.vel = np.array([[260.0, 0.0]])
        self.hue = np.array([self.rng.random()])
        self.t = 0.0
        self.spawned = 0

    @property
    def n(self):
        return len(self.pos)

    def step(self, dt):
        self.spawned = 0
        for _ in range(2):
            h = dt / 2
            self.t += h
            self.vel[:, 1] += self.g * h
            self.pos += self.vel * h
            dv = self.pos - (CX, CY)
            d = np.hypot(dv[:, 0], dv[:, 1])
            lim = R - self.r
            n = dv / np.maximum(d, 1e-6)[:, None]
            vn = (self.vel * n).sum(1)
            hit = (d > lim) & (vn > 0)
            if not hit.any():
                continue
            self.vel[hit] -= 2 * vn[hit, None] * n[hit]
            self.pos[hit] = (CX, CY) + n[hit] * lim
            k = int(min(hit.sum(), self.cap - self.n))
            if k <= 0:
                continue
            src = np.flatnonzero(hit)[:k]
            ang = self.rng.uniform(0, math.tau, k)
            spd = np.hypot(self.vel[src, 0], self.vel[src, 1])
            nv = np.stack([np.cos(ang), np.sin(ang)], 1) * spd[:, None]
            self.pos = np.concatenate([self.pos, self.pos[src] - n[src] * 4])
            self.vel = np.concatenate([self.vel, nv])
            self.hue = np.concatenate([self.hue, self.hue[src] + 0.045])
            self.spawned += k


def _tune_g(seed, cap, target=20.0):
    """試一排重力，挑滿出來的時間最接近 target 秒的那個。"""
    best, best_err = 600.0, 1e9
    for i in range(24):
        g = 40.0 * 1.22 ** i
        s = MultiSim(seed, cap, g)
        while s.n < cap and s.t < 60:
            s.step(1 / FPS)
        if abs(s.t - target) < best_err:
            best, best_err = g, abs(s.t - target)
    return best


def make_multiply(out, seed, title="+1 ball every wall hit", cap=2000):
    sim = MultiSim(seed, cap, _tune_g(seed, cap))
    rng = random.Random(seed + 1)
    bg = core.background()
    audio = core.Audio()
    video = core.Video(out)
    parts = core.Particles()
    end_t = None
    dt = 1 / FPS
    tsize = core.fit(title, W - 100, 84)
    arena = bg.copy()
    core.aa_circle(arena, CX, CY, R, fill=(14, 13, 30))
    core.aa_circle(arena, CX, CY, R + 10, outline=(255, 255, 255), width=10)

    while True:
        t = video.t
        if end_t is None:
            sim.step(dt)
            if sim.spawned:
                i = int(math.log2(sim.n) * 2.2)
                audio.add(t, "pluck", core.note(i, 196), 0.4, min_gap=0.04)
            if sim.n >= cap:
                end_t = t + 2.6
                audio.add(t, "boom", 0, 0.9)
                audio.fanfare(t + 0.25)
        else:
            parts.confetti(rng, 5)
        parts.step(dt)

        img = arena.copy()
        d = ImageDraw.Draw(img)
        r = sim.r
        if sim.n <= 40:
            for (x, y), hue in zip(sim.pos, sim.hue):
                core.aa_circle(img, x, y, r, fill=core.hsv(hue, 0.75, 1.0))
            d = ImageDraw.Draw(img)
        else:
            for (x, y), hue in zip(sim.pos.tolist(), sim.hue.tolist()):
                d.ellipse([x - r, y - r, x + r, y + r], fill=core.hsv(hue, 0.75, 1.0),
                          outline=(0, 0, 0))
        parts.draw(d)
        core.draw_text(d, (W / 2, 275), title, tsize, stroke=6)
        core.draw_text(d, (W / 2, 380), f"{sim.n} balls", 60, fill=(255, 220, 90))
        if end_t is not None:
            core.banner(img, CY, [("FULL!", 130, (255, 255, 255)),
                                  (f"{sim.n} balls total", 60, (255, 220, 90))])
        else:
            core.draw_text(d, (W / 2, 1520), "How long can you watch?", 50,
                           fill=(140, 230, 255))
        video.write(img)
        if end_t is not None and t >= end_t:
            break
        if t > 80:
            break
    return video.close(audio)
