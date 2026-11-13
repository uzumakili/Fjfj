#!/usr/bin/env python3
"""Draws rough pictures of what a Neon Canvas player would see, without Roblox.

The game runs in the mock engine (see run_tests.py); at chosen moments the 3D parts and the GUI
are exported and painted with Pillow. The result is NOT a Roblox screenshot: lighting, fonts and
effects are approximations. It exists to check layout, colours and composition before anyone
opens Studio.

    pip install lupa pillow
    python preview.py [output folder]
"""
import json
import math
import os
import re
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

import run_tests as rt

SS = 2  # everything is drawn at twice the size and shrunk, for smooth edges
FONT_DIR = "/usr/share/fonts/opentype/inter/"
FONTS = {
    "GothamBlack": "Inter-Black.otf",
    "GothamBold": "Inter-Bold.otf",
    "GothamMedium": "Inter-Medium.otf",
}
_font_cache = {}


def font(name, size):
    key = (name, int(size))
    if key not in _font_cache:
        path = FONT_DIR + FONTS.get(name, "Inter-Regular.otf")
        if not os.path.exists(path):
            path = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
        _font_cache[key] = ImageFont.truetype(path, max(4, int(size)))
    return _font_cache[key]


def blend(img, shape_fn, box, alpha):
    """Draws one shape with transparency. shape_fn(draw, w, h) paints white on a mask."""
    x0, y0, x1, y1 = [int(round(v)) for v in box]
    w, h = x1 - x0, y1 - y0
    if w <= 0 or h <= 0 or alpha <= 0.004:
        return None
    mask = Image.new("L", (w, h), 0)
    shape_fn(ImageDraw.Draw(mask), w, h)
    if alpha < 0.996:
        mask = mask.point(lambda v: int(v * alpha))
    return mask, (x0, y0)


def paste(img, color, masked):
    if masked:
        mask, at = masked
        img.paste(tuple(color), at, mask)


# ---------------------------------------------------------------------------------------------
# The 3D world, seen through the game's camera
# ---------------------------------------------------------------------------------------------

def draw_world(img, snap):
    W, H = img.size
    cam = snap["camera"]
    ex, ey, ez = cam[0:3]
    R = cam[3:12]
    focal = (H / 2) / math.tan(math.radians(snap["fov"]) / 2)
    squash = max(0.15, abs(R[5]))  # how much a flat circle is flattened by the viewing angle

    def project(x, y, z):
        dx, dy, dz = x - ex, y - ey, z - ez
        cx = R[0] * dx + R[3] * dy + R[6] * dz
        cy = R[1] * dx + R[4] * dy + R[7] * dz
        depth = -(R[2] * dx + R[5] * dy + R[8] * dz)
        if depth < 1:
            return None
        return W / 2 + cx / depth * focal, H / 2 - cy / depth * focal, depth

    # night sky
    top, bottom = (9, 10, 26), (20, 16, 44)
    grad = Image.new("RGB", (1, H))
    for y in range(H):
        k = y / H
        grad.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * k) for i in range(3)))
    img.paste(grad.resize((W, H)))
    glow = Image.new("RGB", (W, H), (0, 0, 0))

    def put(color, masked, neon):
        paste(img, color, masked)
        if neon and masked:
            paste(glow, color, masked)

    items = []
    for p in snap["parts"]:
        if p["n"] in ("Head", "UpperTorso", "LowerTorso", "HumanoidRootPart"):
            continue
        cf, size = p["cf"], p["sz"]
        upright = p["s"] == "Cylinder" and abs(cf[6]) > 0.9
        if upright:
            top_y = cf[1] + size[0] / 2
        elif p["s"] == "Ball":
            top_y = cf[1] + size[0] / 2
        else:
            top_y = cf[1] + size[1] / 2
        items.append((top_y, p, upright))
    items.sort(key=lambda it: it[0])

    for top_y, p, upright in items:
        cf, size = p["cf"], p["sz"]
        neon = p["m"] == "Neon"
        alpha = 1 - p["t"]
        color = p["c"] if neon else [int(c * 0.72) for c in p["c"]]
        if p["m"] == "Glass":
            alpha *= 0.6
        if upright:
            radius, height = size[1] / 2, size[0]
            at = project(cf[0], top_y, cf[2])
            if not at:
                continue
            sx, sy, depth = at
            rx = radius * focal / depth
            ry = rx * squash
            if height > 2:  # a pillar or post: draw its side too
                low = project(cf[0], top_y - height, cf[2])
                if low:
                    lx, ly, ldepth = low
                    lrx = radius * focal / ldepth
                    side = [int(c * 0.6) for c in color]
                    box = (min(sx - rx, lx - lrx), min(sy, ly) - ry, max(sx + rx, lx + lrx), max(sy, ly) + lrx * squash)
                    pts = [(sx - rx - box[0], sy - box[1]), (sx + rx - box[0], sy - box[1]),
                           (lx + lrx - box[0], ly - box[1]), (lx - lrx - box[0], ly - box[1])]
                    put(side, blend(img, lambda d, w, h: (d.polygon(pts, fill=255), d.ellipse(
                        (lx - lrx - box[0], ly - lrx * squash - box[1], lx + lrx - box[0], ly + lrx * squash - box[1]),
                        fill=255)), box, alpha), neon)
            put(color, blend(img, lambda d, w, h: d.ellipse((0, 0, w - 1, h - 1), fill=255),
                             (sx - rx, sy - ry, sx + rx, sy + ry), alpha), neon)
        elif p["s"] == "Ball":
            at = project(cf[0], cf[1], cf[2])
            if not at:
                continue
            sx, sy, depth = at
            r = size[0] / 2 * focal / depth
            if p["m"] == "ForceField":
                put(color, blend(img, lambda d, w, h: d.ellipse((2, 2, w - 3, h - 3), outline=255, width=max(2, int(3 * SS))),
                                 (sx - r, sy - r, sx + r, sy + r), 0.7), True)
            else:
                put(color, blend(img, lambda d, w, h: d.ellipse((0, 0, w - 1, h - 1), fill=255),
                                 (sx - r, sy - r, sx + r, sy + r), alpha), neon)
        else:
            # a long thin piece (a bolt, a beam, a dash streak): draw it as a thick line
            if p["s"] == "Cylinder":
                axis, length, thick = (cf[3], cf[6], cf[9]), size[0], size[1]
            else:
                axis, length, thick = (cf[5], cf[8], cf[11]), size[2], size[0]
            a = project(cf[0] - axis[0] * length / 2, cf[1] - axis[1] * length / 2, cf[2] - axis[2] * length / 2)
            b = project(cf[0] + axis[0] * length / 2, cf[1] + axis[1] * length / 2, cf[2] + axis[2] * length / 2)
            if not a or not b:
                continue
            width = max(1.5, thick * focal / ((a[2] + b[2]) / 2))
            pad = width
            box = (min(a[0], b[0]) - pad, min(a[1], b[1]) - pad, max(a[0], b[0]) + pad, max(a[1], b[1]) + pad)
            line = [(a[0] - box[0], a[1] - box[1]), (b[0] - box[0], b[1] - box[1])]

            def stroke(d, w, h, line=line, width=width):
                d.line(line, fill=255, width=int(width))
                for q in line:
                    d.ellipse((q[0] - width / 2, q[1] - width / 2, q[0] + width / 2, q[1] + width / 2), fill=255)
            put(color, blend(img, stroke, box, alpha), neon)

    # player characters: a simple token with the team outline
    for c in snap["chars"]:
        at = project(c["at"][0], c["at"][1] - 0.5, c["at"][2])
        if not at:
            continue
        sx, sy, depth = at
        r = 1.7 * focal / depth
        paste(img, (36, 38, 60), blend(img, lambda d, w, h: d.ellipse((0, 0, w - 1, h - 1), fill=255), (sx - r, sy - r, sx + r, sy + r), 1))
        paste(img, c["c"], blend(img, lambda d, w, h: d.ellipse((1, 1, w - 2, h - 2), outline=255, width=max(2, int(r * 0.3))),
                                 (sx - r, sy - r, sx + r, sy + r), 1))
        hr = r * 0.5
        paste(img, (236, 236, 246), blend(img, lambda d, w, h: d.ellipse((0, 0, w - 1, h - 1), fill=255),
                                          (sx - hr, sy - hr - r * 0.2, sx + hr, sy + hr - r * 0.2), 1))
        if c.get("field"):
            fr = r * 2.2
            paste(img, (200, 220, 255), blend(img, lambda d, w, h: d.ellipse((1, 1, w - 2, h - 2), outline=255, width=3 * SS),
                                              (sx - fr, sy - fr, sx + fr, sy + fr), 0.5))

    # bloom: neon things bleed light
    img.paste(ImageChops.add(img, glow.filter(ImageFilter.GaussianBlur(7 * SS)).point(lambda v: int(v * 0.55))))

    # name plates float above everything
    draw = ImageDraw.Draw(img)
    for plate in snap["plates"]:
        at = project(*plate["at"])
        if not at:
            continue
        sx, sy = at[0], at[1]
        top = sy - plate["h"] * SS / 2
        for item in plate["items"]:
            if "text" in item:
                if not item["text"] or item["a"] <= 0.02:
                    continue
                f = font("GothamBold", item["size"] * SS)
                h = item["h"] * SS if not item.get("full") else plate["h"] * SS
                width = draw.textlength(item["text"], font=f)
                y = top + item["y"] * SS + h / 2
                draw.text((sx - width / 2, y), item["text"], font=f, fill=tuple(item["color"]), anchor="lm",
                          stroke_width=SS, stroke_fill=(8, 8, 16))
            else:
                w, h = item["w"] * SS, item["h"] * SS
                x0, y0 = sx - w / 2, top + item["y"] * SS
                draw.rounded_rectangle((x0, y0, x0 + w, y0 + h), h / 2, fill=(14, 16, 28))
                if item["bar"] > 0.02:
                    draw.rounded_rectangle((x0, y0, x0 + w * item["bar"], y0 + h), h / 2, fill=tuple(item["color"]))


# ---------------------------------------------------------------------------------------------
# The 2D interface
# ---------------------------------------------------------------------------------------------

TAG = re.compile(r"<(/?)(font|b)([^>]*)>")


def rich_segments(text, color):
    """Splits rich text into (text, colour) runs. Only <font color> and <b> are understood."""
    out, stack, pos = [], [tuple(color)], 0
    for m in TAG.finditer(text):
        if m.start() > pos:
            out.append((text[pos:m.start()], stack[-1]))
        pos = m.end()
        if m.group(2) == "font":
            if m.group(1):
                if len(stack) > 1:
                    stack.pop()
            else:
                hexcode = re.search(r'#([0-9a-fA-F]{6})', m.group(3))
                stack.append(tuple(int(hexcode.group(1)[i:i + 2], 16) for i in (0, 2, 4)) if hexcode else stack[-1])
    if pos < len(text):
        out.append((text[pos:], stack[-1]))
    return [(t.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&"), c) for t, c in out]


def draw_text(img, node, box, scale):
    text = node.get("text") or ""
    alpha = 1 - node.get("textT", 0)
    if not text or alpha <= 0.02:
        return
    x0, y0, x1, y1 = box
    f = font(node.get("font"), node["textSize"] * scale)
    draw = ImageDraw.Draw(img)
    runs = rich_segments(text, node["textColor"]) if node.get("rich") else [(text, tuple(node["textColor"]))]
    plain = "".join(t for t, _ in runs)
    lines = [runs]
    if node.get("wrap") and draw.textlength(plain, font=f) > (x1 - x0):
        lines, current, width = [], [], 0
        for word in plain.split(" "):
            w = draw.textlength(word + " ", font=f)
            if current and width + w > (x1 - x0):
                lines.append([(" ".join(current), runs[0][1])])
                current, width = [], 0
            current.append(word)
            width += w
        if current:
            lines.append([(" ".join(current), runs[0][1])])
    line_h = node["textSize"] * scale * 1.22
    total = line_h * len(lines)
    ya = node.get("ya", "Center")
    y = y0 if ya == "Top" else (y1 - total if ya == "Bottom" else (y0 + y1 - total) / 2)
    for line in lines:
        width = sum(draw.textlength(t, font=f) for t, _ in line)
        xa = node.get("xa", "Center")
        x = x0 if xa == "Left" else (x1 - width if xa == "Right" else (x0 + x1 - width) / 2)
        for t, color in line:
            if alpha < 0.98:
                color = tuple(int(c * alpha + 20 * (1 - alpha)) for c in color)
            draw.text((x, y + line_h / 2), t, font=f, fill=color, anchor="lm")
            x += draw.textlength(t, font=f)
        y += line_h


def draw_node(img, node, parent, scale, forced=None):
    """parent = (x, y, w, h) in pixels; forced = (x, y, w, h) when a layout placed this node."""
    if node.get("visible") is False:
        return
    px, py, pw, ph = parent
    if forced:
        x, y, w, h = forced
    else:
        size, pos, anchor = node["size"], node["pos"], node["anchor"]
        w = size[0] * pw + size[1] * scale
        h = size[2] * ph + size[3] * scale
        x = px + pos[0] * pw + pos[1] * scale - anchor[0] * w
        y = py + pos[2] * ph + pos[3] * scale - anchor[1] * h
    radius, stroke, list_layout, grid_layout = 0, None, None, None
    for kid in node["kids"]:
        cls = kid["class"]
        if cls == "UICorner":
            radius = min(kid["radius"][0] * min(w, h) + kid["radius"][1] * scale, min(w, h) / 2)
        elif cls == "UIStroke":
            stroke = kid
        elif cls == "UIScale":
            scale = scale * kid["scale"]
        elif cls == "UIListLayout":
            list_layout = kid
        elif cls == "UIGridLayout":
            grid_layout = kid
    box = (x, y, x + w, y + h)
    rot = node.get("rot", 0)
    alpha = 1 - node.get("bgT", 1)
    if rot and alpha > 0.004 and w > 0 and h > 0:
        # a rotated bar: draw it on its own tile and turn it
        tile = Image.new("L", (int(w) + 2, int(h) + 2), 0)
        ImageDraw.Draw(tile).rounded_rectangle((0, 0, int(w), int(h)), radius, fill=int(255 * alpha))
        tile = tile.rotate(-rot, expand=True, resample=Image.BICUBIC)
        img.paste(tuple(node["bg"]), (int(x + w / 2 - tile.width / 2), int(y + h / 2 - tile.height / 2)), tile)
    elif alpha > 0.004:
        paste(img, node["bg"], blend(img, lambda d, ww, hh: d.rounded_rectangle((0, 0, ww - 1, hh - 1), radius, fill=255), box, alpha))
    if stroke and stroke["strokeT"] < 0.99 and w > 2 and h > 2:
        t = max(1, int(round(stroke["thickness"] * scale)))
        paste(img, stroke["color"], blend(
            img, lambda d, ww, hh: d.rounded_rectangle((0, 0, ww - 1, hh - 1), radius + t, outline=255, width=t),
            (x - t, y - t, x + w + t, y + h + t), 1 - stroke["strokeT"]))
    if "text" in node:
        draw_text(img, node, box, scale)

    kids = [k for k in node["kids"] if "size" in k]
    order = sorted(range(len(kids)), key=lambda i: (kids[i].get("z", 1), i))
    if list_layout or grid_layout:
        flow = sorted([k for k in kids if k.get("visible") is not False], key=lambda k: k.get("order", 0))
        placed = {}
        if list_layout:
            vertical = list_layout["fill"] == "Vertical"
            pad = list_layout["pad"][0] * (h if vertical else w) + list_layout["pad"][1] * scale
            sizes = [(k["size"][0] * w + k["size"][1] * scale, k["size"][2] * h + k["size"][3] * scale) for k in flow]
            total = sum(s[1] if vertical else s[0] for s in sizes) + pad * max(0, len(flow) - 1)
            cursor = 0
            if vertical and list_layout["va"] == "Center":
                cursor = (h - total) / 2
            elif vertical and list_layout["va"] == "Bottom":
                cursor = h - total
            elif not vertical and list_layout["ha"] == "Center":
                cursor = (w - total) / 2
            elif not vertical and list_layout["ha"] == "Right":
                cursor = w - total
            for k, (kw, kh) in zip(flow, sizes):
                if vertical:
                    kx = {"Left": 0, "Center": (w - kw) / 2, "Right": w - kw}[list_layout["ha"]]
                    placed[id(k)] = (x + kx, y + cursor, kw, kh)
                    cursor += kh + pad
                else:
                    ky = {"Top": 0, "Center": (h - kh) / 2, "Bottom": h - kh}[list_layout["va"]]
                    placed[id(k)] = (x + cursor, y + ky, kw, kh)
                    cursor += kw + pad
        else:
            cell, cpad = grid_layout["cell"], grid_layout["pad"]
            cw, ch = cell[0] * w + cell[1] * scale, cell[2] * h + cell[3] * scale
            gx, gy = cpad[0] * w + cpad[1] * scale, cpad[2] * h + cpad[3] * scale
            cols = max(1, int((w + gx + 0.5) // (cw + gx)))
            for i, k in enumerate(flow):
                placed[id(k)] = (x + (i % cols) * (cw + gx), y + (i // cols) * (ch + gy), cw, ch)
        for i in order:
            draw_node(img, kids[i], (x, y, w, h), scale, placed.get(id(kids[i])))
    else:
        for i in order:
            draw_node(img, kids[i], (x, y, w, h), scale)


def draw_guis(img, snap):
    W, H = img.size
    screens = [g for g in snap["guis"] if g["class"] == "ScreenGui" and g.get("enabled", True)]
    screens.sort(key=lambda g: g.get("order", 0))
    for g in screens:
        top = 0 if g.get("inset") else 36 * SS  # Roblox keeps a strip at the top for its own buttons
        scale = SS
        for kid in g["kids"]:
            if kid["class"] == "UIScale":
                scale *= kid["scale"]
        kids = [k for k in g["kids"] if "size" in k]
        for i in sorted(range(len(kids)), key=lambda i: (kids[i].get("z", 1), i)):
            draw_node(img, kids[i], (0, top, W, H - top), scale)


def render(snapshot_json, path):
    snap = json.loads(snapshot_json)
    W, H = int(snap["viewport"][0]), int(snap["viewport"][1])
    img = Image.new("RGB", (W * SS, H * SS))
    draw_world(img, snap)
    draw_guis(img, snap)
    img.resize((W, H), Image.LANCZOS).save(path)
    return path


# ---------------------------------------------------------------------------------------------
# A scripted session that stops at interesting moments
# ---------------------------------------------------------------------------------------------

def press(M, player, label):
    buttons = M.visibleButtons(player.PlayerGui)
    for i in range(1, len(buttons) + 1):
        if str(buttons[i].Text).startswith(label):
            M.click(buttons[i])
            return True
    return False


def session(schema, out, device="pc", viewport=(1280, 720), prefix="", saved=None):
    world = rt.World(schema, seed=11)
    M = world.M
    server_src = rt.read(os.path.join(rt.SRC, "NeonCanvas.server.lua"))
    client_src = rt.read(os.path.join(rt.SRC, "NeonCanvas.client.lua"))
    H = world.scenarios.session(M, server_src, client_src)
    if device == "touch":
        M.setDevice("touch")
    M.setViewport(*viewport)
    if saved:
        M.datastore.data["NeonCanvas_v1/p_1"] = world.lua.table_from(saved, recursive=True)
    H.startServer()
    H.advance(0.5)
    player, _ = H.join("You", 1, True)
    shots = []

    def shot(name):
        shots.append(render(M.snapshot(player), os.path.join(out, prefix + name + ".png")))

    H.advance(4)
    shot("01_menu_how_to_play")
    if device == "pc":
        press(M, player, "LOADOUT")
        H.advance(0.3)
        shot("02_menu_loadout")
        press(M, player, "PROFILE")
        H.advance(0.3)
        shot("03_menu_profile")
    press(M, player, "CLOSE")
    H.advance(1.5)
    shot("04_waiting_deck")
    H.walker(player)
    if device == "pc":
        H.keyboardPlayer()
    else:
        H.clicker(player, 0.4)
    H.waitFor("Countdown", 60)
    H.advance(1.6)
    shot("05_countdown")
    H.waitFor("Playing", 20)
    H.advance(12)
    shot("06_match_early")
    H.advance(45)
    shot("07_match_middle")
    H.advance(75)
    shot("08_final_rush")
    H.waitFor("Results", 60)
    H.advance(2.5)
    shot("09_results")
    errors = rt.lua_list(M.errors)
    if errors:
        print("errors during the preview session:", errors[:3])
    return shots


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(rt.HERE, "preview")
    os.makedirs(out, exist_ok=True)
    schema = rt.load_schema()
    veteran = {"lvl": 9, "xp": 120, "rating": 340, "coins": 900, "wins": 21, "matches": 40, "kos": 133, "dots": 8421,
               "primary": "bolt", "a1": "nova", "a2": "vortex", "title": "dotter", "titles": {"rookie": True, "dotter": True}}
    for path in session(schema, out, saved=veteran):
        print(path)
    for path in session(schema, out, device="touch", viewport=(844, 390), prefix="phone_"):
        print(path)


if __name__ == "__main__":
    main()
