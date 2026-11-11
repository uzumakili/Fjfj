# Lumen Garden（Roblox 遊戲）

在漂浮島上培育發光花朵的養成遊戲。每朵花的外型由基因決定，要靠雜交配出新品種、
完成訂單、填滿圖鑑。可以一個人玩，進度會存檔，離線時花會繼續長。遊戲內文字是英文。

## 玩法

1. 畫面下方是種子，點一顆選起來，走到空的土堆按 **E** 種下。
2. 花開了再按 **E** 收成，得到花瓣（貨幣）和種子。
3. **旁邊有別的花開著時，收成拿到的是兩朵花的雜交種子**；旁邊沒有花就是自交。
4. 上方的訂單要求特定的花（例如「發光的藍色星形花，7 片花瓣以上」），種出來後在花旁按 **F** 交付，獎勵很高，訂單會越來越難。
5. 花瓣可以買升級：更多土堆、長得更快、突變率更高、種子袋更大、基因透鏡。

## 深度在哪裡

- **顏色要自己配**：商店只賣紅、黃、藍三種野生種子。綠、青、紫要把兩種顏色種在隔壁雜交出來。
- **隱性基因**：發光（Glowing）、重瓣（Double）、巨大（Giant）都是隱性，兩個基因都帶才會表現。
  看起來普通的花可能是帶因者，自交或和另一個帶因者雜交才會出現。
- **花形**：圓瓣、橢圓、星形，星形要兩個尖瓣基因。
- **基因透鏡**：買了以後種子會顯示隱藏基因（例如 `Glow Gg`），可以有計畫地配種。
- **圖鑑**：6 種顏色 × 3 種花形 × 發光 × 重瓣 × 巨大，共 144 個品種，每發現一種有獎勵。

## 怎麼開啟

1. 安裝 [Roblox Studio](https://create.roblox.com/) 並登入。
2. 用 Roblox Studio 開啟 `LumenGarden.rbxlx`。
3. 按上方的 **Play**。島嶼和介面是遊戲開始時由腳本建立的，所以編輯畫面是空的。

如果檔案打不開：新增一個 Baseplate 專案，在 **ServerScriptService** 新增 **Script** 貼上
`src/Garden.server.lua`，在 **StarterPlayer → StarterPlayerScripts** 新增 **LocalScript** 貼上
`src/Garden.client.lua`，再按 Play。

## 發佈

1. **File → Publish to Roblox**。
2. 要讓存檔生效：**File → Game Settings → Security**，打開 **Enable Studio Access to API Services**。
3. 在 [Creator Hub](https://create.roblox.com/dashboard/creations) 把遊戲設成 Public。

每個伺服器最多 12 座花園，建議把遊戲的 **Max Players** 設成 12 以下。

## 想調整

數值在 `src/Garden.server.lua` 最上面的 settings 區塊（起始花瓣、土堆數、價格等），
介面顏色在 `src/Garden.client.lua` 的 theme 區塊。改完執行 `python build.py` 重新產生檔案。
