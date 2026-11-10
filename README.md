# 白痴短影音產生器

一行指令產生一支可以直接上傳 IG Reels / YouTube Shorts / TikTok 的直式影片
（1080×1920、60fps、有音效）。畫面全部由程式即時算出來，每次結果都不一樣。

## 五種影片

| 指令 | 內容 |
|---|---|
| `battle` | 無意義大逃殺：一堆球在圈圈裡互撞扣血，剩最後一顆獲勝 |
| `race` | 彈珠賽跑：球穿過釘子、斜坡、旋轉桿，先到終點的贏 |
| `versus` | 荒謬對決：1000 隻雞 vs 1 隻大象，小點點打架 |
| `grow` | 越來越失控：球每彈一次就變大，直到塞滿 |
| `multiply` | 越來越失控：每撞一次牆就多一顆球，直到 2000 顆 |

## 安裝（只要做一次）

1. 安裝 [Python](https://www.python.org/downloads/) 3.9 以上（Windows 安裝時請勾選 “Add Python to PATH”）。
2. 在這個資料夾開啟終端機，執行：

```
pip install -r requirements.txt
```

## 使用

```
python make.py battle                      # 隨機主題的大逃殺
python make.py battle --theme 珍奶配料      # 指定主題
python make.py race --theme 星座
python make.py versus --theme 雞大象
python make.py grow
python make.py multiply
python make.py random -n 5                 # 隨機做 5 支
python make.py list                        # 列出所有內建主題
```

影片會出現在 `output/` 資料夾。一支大約要算 1–2 分鐘。

### 自己出題

```
python make.py battle --items 珍珠,椰果,布丁,仙草 --noun 配料
python make.py race --items 小明,小華,小美 --title 誰先下課
python make.py versus --a 雞:隻:1000 --b 大象:隻:1
```

也可以直接編輯 `themes.json` 新增主題，之後用 `--theme 名稱` 叫出來。

### 其他選項

- `--seed 數字`：同一個數字會產生一模一樣的影片；不指定就是隨機。
- `--title 文字`：自訂影片上方的標題。
- `--out 資料夾`：改輸出位置。

## 常見問題

- **中文字變成方塊**：把環境變數 `REELS_FONT` 設成任一個中文字型檔（.ttf / .ttc）的路徑。
- **找不到 ffmpeg**：重新執行 `pip install -r requirements.txt`。
