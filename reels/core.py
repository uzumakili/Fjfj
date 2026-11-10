"""共用工具：畫面、字型、音效合成、影片輸出。"""
import colorsys
import math
import os
import random
import shutil
import subprocess
import wave
from functools import lru_cache

import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H, FPS = 1080, 1920, 60
SR = 44100

# IG / Shorts 的介面會蓋住上下兩塊，重要內容放在這個範圍內
SAFE_TOP, SAFE_BOTTOM = 230, 1580

FONT_CANDIDATES = [
    # Windows
    "C:/Windows/Fonts/msjhbd.ttc",
    "C:/Windows/Fonts/msjh.ttc",
    "C:/Windows/Fonts/mingliu.ttc",
    # macOS
    "/System/Library/Fonts/PingFang.ttc",
    "/System/Library/Fonts/STHeiti Medium.ttc",
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
    "/Library/Fonts/Arial Unicode.ttf",
    # Linux
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
]


@lru_cache(maxsize=1)
def font_path():
    env = os.environ.get("REELS_FONT")
    if env:
        if os.path.exists(env):
            return env
        raise SystemExit(f"REELS_FONT 指定的字型不存在：{env}")
    for p in FONT_CANDIDATES:
        if os.path.exists(p):
            return p
    raise SystemExit(
        "找不到中文字型。請把環境變數 REELS_FONT 設成一個 .ttf/.ttc 字型檔的路徑。"
    )


@lru_cache(maxsize=512)
def font(size):
    return ImageFont.truetype(font_path(), int(size))


def text_w(s, size):
    return font(size).getlength(s)


def fit(s, max_w, size, min_size=18):
    """回傳能讓文字塞進 max_w 的最大字級（不超過 size）。"""
    size = int(size)
    while size > min_size and text_w(s, size) > max_w:
        size -= 2
    return size


def draw_text(d, xy, s, size, fill=(255, 255, 255), anchor="mm", stroke=4,
              stroke_fill=(0, 0, 0)):
    d.text(xy, s, font=font(size), fill=fill, anchor=anchor,
           stroke_width=stroke, stroke_fill=stroke_fill)


def hsv(h, s=0.75, v=1.0):
    r, g, b = colorsys.hsv_to_rgb(h % 1.0, s, v)
    return (int(r * 255), int(g * 255), int(b * 255))


def shade(c, k):
    return tuple(max(0, min(255, int(x * k))) for x in c)


def mix(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def palette(n, rng):
    off = rng.random()
    return [hsv(off + i / n, 0.72, 1.0) for i in range(n)]


def background(top=(26, 22, 52), bottom=(7, 7, 16)):
    t = np.linspace(0, 1, H, dtype=np.float32)[:, None, None]
    a = np.array(top, dtype=np.float32)[None, None, :]
    b = np.array(bottom, dtype=np.float32)[None, None, :]
    col = a + (b - a) * t
    arr = np.broadcast_to(col, (H, W, 3)).astype(np.uint8)
    return Image.fromarray(arr, "RGB")


def aa_circle(img, cx, cy, r, fill=None, outline=None, width=0, ss=2):
    """在 img 上畫一個邊緣平滑的圓（PIL 內建的圓有鋸齒）。"""
    if r <= 0:
        return
    pad = width + 2
    size = int(2 * (r + pad)) + 2
    x0 = int(round(cx - size / 2))
    y0 = int(round(cy - size / 2))
    lx, ly = (cx - x0) * ss, (cy - y0) * ss
    box = [lx - r * ss, ly - r * ss, lx + r * ss, ly + r * ss]
    if fill is not None:
        m = Image.new("L", (size * ss, size * ss), 0)
        ImageDraw.Draw(m).ellipse(box, fill=255)
        img.paste(fill, (x0, y0), m.reduce(ss))
    if outline is not None and width > 0:
        m = Image.new("L", (size * ss, size * ss), 0)
        ImageDraw.Draw(m).ellipse(box, outline=255, width=int(width * ss))
        img.paste(outline, (x0, y0), m.reduce(ss))


@lru_cache(maxsize=4096)
def ball_sprite(r, color, label="", pips=-1, max_pips=0):
    """預先畫好的球（含文字與血量點），回傳 RGBA 圖。"""
    ss = 3
    size = (2 * r + 6) * ss
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    c = size / 2
    R = r * ss
    d.ellipse([c - R, c - R, c + R, c + R], fill=shade(color, 0.55) + (255,))
    R2 = R - max(3, r // 9) * ss
    d.ellipse([c - R2, c - R2, c + R2, c + R2], fill=color + (255,))
    # 高光
    hl = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    hr = R2 * 0.55
    hx, hy = c - R2 * 0.32, c - R2 * 0.36
    ImageDraw.Draw(hl).ellipse([hx - hr, hy - hr * 0.8, hx + hr, hy + hr * 0.8],
                               fill=(255, 255, 255, 46))
    im = Image.alpha_composite(im, hl)
    d = ImageDraw.Draw(im)
    if label:
        show_pips = max_pips > 0
        fs = fit(label, 1.55 * R2, R2 * 0.8, min_size=10)
        ty = c - (R2 * 0.14 if show_pips else 0)
        d.text((c, ty), label, font=font(fs), fill=(255, 255, 255), anchor="mm",
               stroke_width=max(2, fs // 9), stroke_fill=(0, 0, 0))
        if show_pips:
            py = c + R2 * 0.5
            if max_pips <= 6:
                pr = R2 * 0.085
                gap = pr * 2.7
                x = c - gap * (max_pips - 1) / 2
                for i in range(max_pips):
                    col = (255, 255, 255, 255) if i < pips else (0, 0, 0, 90)
                    d.ellipse([x - pr, py - pr, x + pr, py + pr], fill=col)
                    x += gap
            else:
                d.text((c, py), str(pips), font=font(R2 * 0.36),
                       fill=(255, 255, 255), anchor="mm",
                       stroke_width=2 * ss, stroke_fill=(0, 0, 0))
    return im.resize((size // ss, size // ss), Image.LANCZOS)


def paste_sprite(img, sprite, cx, cy):
    img.paste(sprite, (int(round(cx - sprite.width / 2)),
                       int(round(cy - sprite.height / 2))), sprite)


def banner(img, cy, lines):
    """半透明黑底橫幅。lines: [(文字, 字級, 顏色), ...]"""
    lines = [(s, fit(s, W - 120, size), col) for s, size, col in lines]
    h = int(sum(size * 1.4 for _, size, _ in lines) + 70)
    y0 = int(cy - h / 2)
    img.paste((0, 0, 0), (0, y0), Image.new("L", (W, h), 185))
    d = ImageDraw.Draw(img)
    d.rectangle([0, y0, W, y0 + 5], fill=(255, 255, 255))
    d.rectangle([0, y0 + h - 5, W, y0 + h], fill=(255, 255, 255))
    y = y0 + 35
    for s, size, col in lines:
        y += size * 0.7
        draw_text(d, (W / 2, y), s, size, fill=col, stroke=max(3, size // 14))
        y += size * 0.7


class Particles:
    def __init__(self, limit=600):
        self.p = []
        self.limit = limit

    def burst(self, x, y, color, n=24, speed=520, size=9, life=0.8, rng=random):
        for _ in range(n):
            if len(self.p) >= self.limit:
                return
            a = rng.uniform(0, math.tau)
            v = speed * rng.uniform(0.25, 1.0)
            self.p.append([x, y, math.cos(a) * v, math.sin(a) * v,
                           life * rng.uniform(0.6, 1.0), life, color,
                           size * rng.uniform(0.6, 1.2)])

    def confetti(self, rng, n=6):
        for _ in range(n):
            if len(self.p) >= self.limit:
                return
            self.p.append([rng.uniform(0, W), -20, rng.uniform(-80, 80),
                           rng.uniform(300, 700), 3.0, 3.0,
                           hsv(rng.random(), 0.8, 1.0), rng.uniform(8, 16)])

    def step(self, dt, gravity=700):
        for q in self.p:
            q[3] += gravity * dt
            q[0] += q[2] * dt
            q[1] += q[3] * dt
            q[4] -= dt
        self.p = [q for q in self.p if q[4] > 0]

    def draw(self, d, ox=0, oy=0):
        for x, y, _, _, life, life0, col, size in self.p:
            s = size * min(1.0, life / life0 * 1.6)
            x += ox
            y += oy
            d.ellipse([x - s, y - s, x + s, y + s], fill=col)


# ---------------------------------------------------------------- 音效

PENTA = [0, 2, 4, 7, 9]


def note(i, base=261.63):
    """五聲音階第 i 個音，怎麼亂按都不會難聽。"""
    return base * 2 ** ((PENTA[i % 5] + 12 * (i // 5)) / 12)


@lru_cache(maxsize=512)
def _synth(kind, freq):
    if kind == "pluck":
        t = np.arange(int(SR * 0.4)) / SR
        s = np.sin(math.tau * freq * t) * np.exp(-t * 11)
        s += 0.35 * np.sin(math.tau * 2 * freq * t) * np.exp(-t * 17)
    elif kind == "tick":
        t = np.arange(int(SR * 0.07)) / SR
        s = np.sin(math.tau * freq * t) * np.exp(-t * 55)
    elif kind == "pop":
        t = np.arange(int(SR * 0.22)) / SR
        f = freq * (1 - 0.7 * t / t[-1])
        s = np.sin(math.tau * np.cumsum(f) / SR) * np.exp(-t * 16)
        noise = np.random.default_rng(1).uniform(-1, 1, len(t))
        s += 0.35 * noise * np.exp(-t * 45)
    elif kind == "boom":
        t = np.arange(int(SR * 0.7)) / SR
        f = 130 * np.exp(-t * 4) + 38
        s = 1.4 * np.sin(math.tau * np.cumsum(f) / SR) * np.exp(-t * 5)
        noise = np.random.default_rng(2).uniform(-1, 1, len(t))
        s += 0.5 * noise * np.exp(-t * 22)
    else:
        raise ValueError(kind)
    fade = min(len(s), int(SR * 0.002))
    s[:fade] *= np.linspace(0, 1, fade)
    return s.astype(np.float32)


class Audio:
    def __init__(self):
        self.events = []
        self._last = {}

    def add(self, t, kind="pluck", freq=440.0, vol=0.5, min_gap=0.0, key=None):
        """min_gap：同一個 key 的聲音至少間隔幾秒，避免同時幾百個聲音糊成一片。"""
        if min_gap > 0:
            k = key or kind
            if t - self._last.get(k, -9) < min_gap:
                return
            self._last[k] = t
        self.events.append((t, kind, round(float(freq), 1), vol))

    def fanfare(self, t):
        for i, n in enumerate([5, 7, 9, 10, 12]):
            self.add(t + i * 0.11, "pluck", note(n), 0.6)

    def write(self, duration, path):
        buf = np.zeros(int((duration + 0.5) * SR), dtype=np.float32)
        for t, kind, freq, vol in self.events:
            i = int(t * SR)
            if i >= len(buf):
                continue
            s = _synth(kind, freq)
            n = min(len(s), len(buf) - i)
            buf[i:i + n] += s[:n] * vol
        buf = np.tanh(buf * 0.9)
        pcm = (buf[:int(duration * SR)] * 32000).astype(np.int16)
        with wave.open(path, "wb") as f:
            f.setnchannels(1)
            f.setsampwidth(2)
            f.setframerate(SR)
            f.writeframes(pcm.tobytes())


# ---------------------------------------------------------------- 影片

@lru_cache(maxsize=1)
def ffmpeg_exe():
    exe = shutil.which("ffmpeg")
    if exe:
        return exe
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        raise SystemExit("找不到 ffmpeg。請執行：pip install imageio-ffmpeg")


class Video:
    def __init__(self, out_path):
        os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
        self.out = out_path
        self.tmp_video = out_path + ".video.mp4"
        self.tmp_audio = out_path + ".audio.wav"
        self.proc = subprocess.Popen(
            [ffmpeg_exe(), "-y", "-loglevel", "error",
             "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}",
             "-r", str(FPS), "-i", "-",
             "-c:v", "libx264", "-preset", "veryfast", "-crf", "19",
             "-pix_fmt", "yuv420p", self.tmp_video],
            stdin=subprocess.PIPE)
        self.frames = 0

    @property
    def t(self):
        return self.frames / FPS

    def write(self, img):
        self.proc.stdin.write(img.tobytes())
        self.frames += 1
        if self.frames % (FPS * 5) == 0:
            print(f"  已算好 {self.frames // FPS} 秒…", flush=True)

    def close(self, audio):
        self.proc.stdin.close()
        if self.proc.wait() != 0:
            raise SystemExit("ffmpeg 輸出影片失敗")
        audio.write(self.t, self.tmp_audio)
        r = subprocess.run(
            [ffmpeg_exe(), "-y", "-loglevel", "error",
             "-i", self.tmp_video, "-i", self.tmp_audio,
             "-c:v", "copy", "-c:a", "aac", "-b:a", "160k",
             "-movflags", "+faststart", "-shortest", self.out])
        os.remove(self.tmp_video)
        os.remove(self.tmp_audio)
        if r.returncode != 0:
            raise SystemExit("ffmpeg 合成聲音失敗")
        print(f"完成：{self.out}（{self.t:.1f} 秒）")
        return self.out
