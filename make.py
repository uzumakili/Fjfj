"""短影音產生器。用法見 README.md，或執行 python make.py -h"""
import argparse
import json
import os
import random
import sys

from reels import battle, grow, race, versus

HERE = os.path.dirname(os.path.abspath(__file__))
MODES = ["battle", "race", "versus", "grow", "multiply"]
MAX_ITEMS = 12


def load_themes():
    with open(os.path.join(HERE, "themes.json"), encoding="utf-8") as f:
        return json.load(f)


def parse_side(s):
    """'雞:隻:1000' 或 '雞:1000'"""
    p = s.split(":")
    if len(p) == 2:
        return [p[0], "個", int(p[1])]
    if len(p) == 3:
        return [p[0], p[1], int(p[2])]
    raise SystemExit(f"格式錯誤：{s}（要像 雞:隻:1000）")


def pick_list(args, themes, rng):
    """回傳 (主題名, 名詞, 項目清單)"""
    if args.items:
        items = [x.strip() for x in args.items.replace("，", ",").split(",") if x.strip()]
        if len(items) < 2:
            raise SystemExit("--items 至少要兩個，用逗號分開")
        return "自訂", args.noun or "", items[:MAX_ITEMS]
    name = args.theme or rng.choice(sorted(themes["lists"]))
    if name not in themes["lists"]:
        raise SystemExit(f"沒有「{name}」這個主題。可用：{'、'.join(themes['lists'])}")
    th = themes["lists"][name]
    items = list(th["items"])
    if len(items) > MAX_ITEMS:
        items = rng.sample(items, MAX_ITEMS)
    return name, th["noun"], items


def run(mode, args, themes):
    seed = args.seed if args.seed is not None else random.randrange(1, 100000)
    rng = random.Random(seed)
    out_dir = args.out

    def path(tag):
        return os.path.join(out_dir, f"{mode}_{tag}_{seed}.mp4")

    print(f"[{mode}] seed={seed}")
    if mode == "battle":
        name, noun, items = pick_list(args, themes, rng)
        title = args.title or f"誰是最強{noun}？"
        return battle.make(path(name), title, items, seed)
    if mode == "race":
        name, noun, items = pick_list(args, themes, rng)
        title = args.title or f"{noun}彈珠賽跑"
        return race.make(path(name), title, items, seed)
    if mode == "versus":
        if args.a and args.b:
            a, b, name = parse_side(args.a), parse_side(args.b), "自訂"
        else:
            name = args.theme or rng.choice(sorted(themes["versus"]))
            if name not in themes["versus"]:
                raise SystemExit(
                    f"沒有「{name}」這個對決。可用：{'、'.join(themes['versus'])}")
            a, b = themes["versus"][name]["a"], themes["versus"][name]["b"]
        if not (1 <= a[2] <= 1500 and 1 <= b[2] <= 1500):
            raise SystemExit("每一邊的數量要在 1 到 1500 之間")
        return versus.make(path(name), a, b, seed)
    if mode == "grow":
        return grow.make_grow(path("變大"), seed, args.title or "球每彈一次就變大")
    if mode == "multiply":
        return grow.make_multiply(path("變多"), seed,
                                  args.title or "每撞一次牆就多一顆球")
    raise SystemExit(f"未知模式：{mode}")


def main():
    ap = argparse.ArgumentParser(description="白痴短影音產生器")
    ap.add_argument("mode", choices=MODES + ["random", "list"],
                    help="battle 大逃殺 / race 彈珠賽跑 / versus 對決 / grow 變大 / "
                         "multiply 變多 / random 隨機 / list 列出主題")
    ap.add_argument("--theme", help="主題名稱（見 list）")
    ap.add_argument("--items", help="自訂項目，用逗號分開，例如 珍珠,椰果,布丁")
    ap.add_argument("--noun", help="自訂項目的總稱，例如 珍奶配料")
    ap.add_argument("--title", help="自訂影片標題")
    ap.add_argument("--a", help="對決 A 方，例如 雞:隻:1000")
    ap.add_argument("--b", help="對決 B 方，例如 大象:隻:1")
    ap.add_argument("--seed", type=int, help="亂數種子；同一個種子會產生一模一樣的影片")
    ap.add_argument("-n", type=int, default=1, help="一次產生幾支")
    ap.add_argument("--out", default=os.path.join(HERE, "output"), help="輸出資料夾")
    args = ap.parse_args()

    themes = load_themes()
    if args.mode == "list":
        print("清單主題（battle / race 用）：")
        for k, v in themes["lists"].items():
            print(f"  {k}：{'、'.join(v['items'])}")
        print("對決主題（versus 用）：")
        for k, v in themes["versus"].items():
            a, b = v["a"], v["b"]
            print(f"  {k}：{a[2]}{a[1]}{a[0]} vs {b[2]}{b[1]}{b[0]}")
        return
    if args.n > 1 and args.seed is not None:
        raise SystemExit("-n 大於 1 時不要指定 --seed，不然每支都一樣")
    for _ in range(args.n):
        mode = random.choice(MODES) if args.mode == "random" else args.mode
        run(mode, args, themes)


if __name__ == "__main__":
    sys.exit(main())
