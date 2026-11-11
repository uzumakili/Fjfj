# Chaos Arena（Roblox 遊戲）

回合制的生存派對遊戲。玩家被傳送到一塊 10×10 的浮空平台上，每回合連續遇到 3 種隨機災難，
撐到最後的人獲勝，拿金幣到大廳買東西。一個人也能玩。遊戲內文字是英文。

## 五種災難

| 名稱 | 內容 |
|---|---|
| Falling Tiles | 地板變紅後一塊一塊掉下去 |
| Meteor Shower | 隕石砸在紅圈上，把人炸飛，有時連地板一起砸掉 |
| The Sweeper | 旋轉的橫桿要跳過去，越轉越快，還會突然反轉 |
| Rising Lava | 地板變成金字塔，岩漿上升，只有最頂端安全 |
| Boulders | 巨石沿著紅色警示道滾過來 |

其他內容：大廳有玻璃牆可以看別人比賽、排行榜（Wins / Coins）、
商店（Speed Boost 150 金幣、Rainbow Trail 100 金幣）、自動存檔。

## 怎麼開啟

1. 安裝 [Roblox Studio](https://create.roblox.com/) 並登入。
2. 用 Roblox Studio 開啟這個資料夾裡的 `ChaosArena.rbxlx`。
3. 按上方的 **Play**（或 F5）試玩。地圖是腳本在遊戲開始時自動蓋出來的，所以編輯畫面是空的，這是正常的。

### 如果 `ChaosArena.rbxlx` 打不開

改用手動貼上，一樣可以玩：

1. 在 Roblox Studio 新增一個 **Baseplate** 專案。
2. 在右邊 Explorer 的 **ServerScriptService** 按 `+` 新增 **Script**，把 `src/Main.server.lua` 的內容整個貼進去。
3. 展開 **StarterPlayer**，在 **StarterPlayerScripts** 按 `+` 新增 **LocalScript**，把 `src/Hud.client.lua` 的內容整個貼進去。
4. 按 **Play**。

## 發佈到 Roblox

1. Studio 左上 **File → Publish to Roblox**，填名稱後發佈。
2. 要讓金幣和勝場存檔生效：**File → Game Settings → Security**，打開 **Enable Studio Access to API Services**。
3. 到 [Creator Hub](https://create.roblox.com/dashboard/creations) 把遊戲設成 **Public**，別人才進得來。

## 想調整

數值都在 `src/Main.server.lua` 最上面的 settings 區塊，例如平台大小 `GRID`、
每回合幾種災難 `EVENTS_PER_ROUND`、金幣獎勵與商店價格。
改完執行 `python build.py` 重新產生 `ChaosArena.rbxlx`（或直接在 Studio 裡改腳本）。
