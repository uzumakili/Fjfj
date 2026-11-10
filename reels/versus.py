"""模式 3：荒謬對決模擬。例如 1000 隻雞 vs 1 隻大象，用小點點打架。"""
import math
import random

import numpy as np
from PIL import ImageDraw

from . import core
from .core import W, FPS

FX0, FX1, FY0, FY1 = 60, 1020, 470, 1490
COL = [(255, 176, 46), (70, 170, 255)]


def unit_radius(count):
    return max(7.0, min(110.0, 240 / math.sqrt(count)))


class Sim:
    def __init__(self, counts, seed, k=1.0):
        rng = np.random.default_rng(seed)
        self.luck = rng.uniform(0.78, 1.3)  # 每個 seed 的勝負不一樣
        pos, rad, side, hp, dps, spd = [], [], [], [], [], []
        for s, n in enumerate(counts):
            r = unit_radius(n)
            y0, y1 = (FY0 + r, FY0 + 330) if s == 0 else (FY1 - 330, FY1 - r)
            if n <= 12:
                xs = np.linspace(FX0, FX1, n + 2)[1:-1]
                ys = np.full(n, (y0 + y1) / 2)
                p = np.stack([xs, ys], 1)
            else:
                p = np.stack([rng.uniform(FX0 + r, FX1 - r, n),
                              rng.uniform(y0, y1, n)], 1)
            pos.append(p)
            rad.append(np.full(n, r))
            side.append(np.full(n, s))
            # 讓兩邊「數量 x 血量 x 攻擊」相等，再乘上運氣
            base = 100 / math.sqrt(n)
            hp.append(np.full(n, base * (self.luck if s == 0 else 1.0)))
            dps.append(np.full(n, base * k))
            spd.append(np.full(n, 60 + 1100 / r))
        self.pos = np.concatenate(pos).astype(np.float32)
        self.rad = np.concatenate(rad).astype(np.float32)
        self.side = np.concatenate(side)
        self.hp = np.concatenate(hp).astype(np.float32)
        self.hp0 = self.hp.copy()
        self.dps = np.concatenate(dps).astype(np.float32)
        self.spd = np.concatenate(spd).astype(np.float32)
        self.tone = rng.uniform(0.75, 1.0, len(self.pos))
        self.total0 = [float(self.hp[self.side == s].sum()) for s in (0, 1)]
        self.t = 0.0
        self.first_contact = None
        self.deaths = []  # 這一格死掉的 (x, y, r, side)
        for _ in range(30):
            self._separate(self._pairs())

    def _pairs(self):
        """所有單位兩兩之間的 x 差、y 差、距離（對角線設成超大，避免自己撞自己）。"""
        x, y = self.pos[:, 0], self.pos[:, 1]
        dx = x[:, None] - x[None, :]
        dy = y[:, None] - y[None, :]
        dist = np.sqrt(dx * dx + dy * dy)
        np.fill_diagonal(dist, 1e9)
        return dx, dy, dist

    def _cache(self):
        """只跟「誰還活著」有關的矩陣，有人死掉才重算。"""
        m = self.rad ** 2
        self._rs = self.rad[:, None] + self.rad[None, :]
        self._w = m[None, :] / (m[:, None] + m[None, :])
        self._enemy = self.side[:, None] != self.side[None, :]
        self._far = np.where(self._enemy, 0, 1e9).astype(np.float32)

    def _separate(self, dd):
        dx, dy, dist = dd
        if getattr(self, "_rs", None) is None or len(self._rs) != len(self.pos):
            self._cache()
        f = self._rs - dist
        np.maximum(f, 0, out=f)
        f *= self._w
        f /= np.maximum(dist, 1e-3)
        self.pos[:, 0] += (dx * f).sum(1) * 0.5
        self.pos[:, 1] += (dy * f).sum(1) * 0.5
        self.pos[:, 0] = np.clip(self.pos[:, 0], FX0 + self.rad, FX1 - self.rad)
        self.pos[:, 1] = np.clip(self.pos[:, 1], FY0 + self.rad, FY1 - self.rad)

    def count(self, s):
        return int((self.side == s).sum())

    def hp_frac(self, s):
        return float(self.hp[self.side == s].sum()) / self.total0[s]

    def over(self):
        return self.count(0) == 0 or self.count(1) == 0

    def step(self, dt):
        self.deaths = []
        self.t += dt
        if self.over():
            return
        dx, dy, dist = self._pairs()
        if getattr(self, "_rs", None) is None or len(self._rs) != len(self.pos):
            self._cache()
        gap = dist - self._rs
        ge = gap + self._far
        j = ge.argmin(1)
        idx = np.arange(len(self.pos))
        g = ge[idx, j]
        inv = 1 / np.maximum(dist[idx, j], 1e-3)
        move = np.where(g > 1.0, np.minimum(self.spd * dt, np.maximum(g, 0)), 0)
        self.pos[:, 0] -= dx[idx, j] * inv * move
        self.pos[:, 1] -= dy[idx, j] * inv * move
        self._separate((dx, dy, dist))
        contact = ge < 4.0
        if contact.any():
            if self.first_contact is None:
                self.first_contact = self.t
            self.hp -= (contact @ self.dps) * dt
            dead = self.hp <= 0
            if dead.any():
                for i in np.flatnonzero(dead):
                    self.deaths.append((float(self.pos[i, 0]), float(self.pos[i, 1]),
                                        float(self.rad[i]), int(self.side[i])))
                keep = ~dead
                for name in ("pos", "rad", "side", "hp", "hp0", "dps", "spd", "tone"):
                    setattr(self, name, getattr(self, name)[keep])
                self._rs = None


def _tune_k(counts, seed, target=20.0):
    """先不畫圖試跑幾輪，把戰鬥長度校正到大約 target 秒。"""
    k = 0.2
    for _ in range(3):
        s = Sim(counts, seed, k)
        while not s.over() and s.t < 70:
            s.step(1 / 20)
        ta = s.first_contact or 0.0
        fight = max(0.5, s.t - ta)
        want = max(6.0, target - ta)
        if abs(fight - want) < 3:
            break
        k *= fight / want
    return k


def make(out, a, b, seed, cta="Who wins? Comment below"):
    """a、b：(單數名稱, 複數名稱, 數量)"""
    counts = (a[2], b[2])
    names = tuple(s[1] if s[2] > 1 else s[0] for s in (a, b))
    single = (a[0], b[0])
    sim = Sim(counts, seed, _tune_k(counts, seed))
    rng = random.Random(seed + 1)
    bg = core.background()
    ImageDraw.Draw(bg).rounded_rectangle([FX0 - 8, FY0 - 8, FX1 + 8, FY1 + 8], 28,
                                         fill=(14, 13, 30), outline=(255, 255, 255),
                                         width=6)
    audio = core.Audio()
    video = core.Video(out)
    parts = core.Particles(limit=500)
    title = f"{a[2]} {names[0]} vs {b[2]} {names[1]}"
    tsize = core.fit(title, W - 90, 88)
    end_t = None
    win = None
    dt = 1 / FPS

    while True:
        t = video.t
        sim.step(dt)
        for x, y, r, s in sim.deaths:
            if r >= 30:
                audio.add(t, "boom", 0, 0.9)
                parts.burst(x, y, COL[s], n=50, speed=600, rng=rng)
            else:
                audio.add(t, "tick", 700 + 500 * s + rng.uniform(-80, 80), 0.3,
                          min_gap=0.035, key=s)
                parts.burst(x, y, COL[s], n=2, speed=200, size=4, life=0.35, rng=rng)
        if end_t is None and sim.over():
            win = 0 if sim.count(0) > 0 else 1
            end_t = t + 2.8
            audio.fanfare(t + 0.15)
        if end_t is not None:
            parts.confetti(rng, 5)
        parts.step(dt)

        img = bg.copy()
        d = ImageDraw.Draw(img)
        big = []
        for i in range(len(sim.pos)):
            x, y = float(sim.pos[i, 0]), float(sim.pos[i, 1])
            r = float(sim.rad[i])
            s = int(sim.side[i])
            if r >= 30:
                big.append((i, x, y, r, s))
            else:
                d.ellipse([x - r, y - r, x + r, y + r],
                          fill=core.shade(COL[s], float(sim.tone[i])),
                          outline=(0, 0, 0))
        for i, x, y, r, s in big:
            core.paste_sprite(img, core.ball_sprite(int(r), COL[s], single[s]), x, y)
            f = max(0.0, float(sim.hp[i] / sim.hp0[i]))
            bw = r * 1.5
            d.rectangle([x - bw / 2, y - r - 22, x + bw / 2, y - r - 10],
                        fill=(0, 0, 0))
            d.rectangle([x - bw / 2 + 2, y - r - 20, x - bw / 2 + 2 + (bw - 4) * f,
                         y - r - 12], fill=(90, 230, 110))
        parts.draw(d)

        core.draw_text(d, (W / 2, 270), title, tsize, stroke=6)
        core.draw_text(d, (70, 362), f"{names[0]} {sim.count(0)}", 54, fill=COL[0],
                       anchor="lm")
        core.draw_text(d, (1010, 362), f"{sim.count(1)} {names[1]}", 54, fill=COL[1],
                       anchor="rm")
        bw = 440
        d.rectangle([70, 410, 70 + bw, 432], fill=(40, 40, 60))
        d.rectangle([1010 - bw, 410, 1010, 432], fill=(40, 40, 60))
        d.rectangle([70, 410, 70 + bw * sim.hp_frac(0), 432], fill=COL[0])
        d.rectangle([1010 - bw * sim.hp_frac(1), 410, 1010, 432], fill=COL[1])
        if win is None:
            core.draw_text(d, (W / 2, 1548), cta, 50, fill=(140, 230, 255))
        else:
            core.banner(img, 980, [
                (f"{names[win].upper()} {'WIN' if counts[win] > 1 else 'WINS'}!", 120, COL[win]),
                (f"{sim.count(win)} left", 58, (255, 255, 255))])
        video.write(img)
        if end_t is not None and t >= end_t:
            break
        if t > 90:
            break
    return video.close(audio)
