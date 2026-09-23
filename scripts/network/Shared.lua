--[[
Shared - 客户端与服务端共用的定义

只放两边都要用的东西：稀有度配置、网络事件名、价格工具。
不依赖引擎状态，可以在任何一端 require。
]]

local Shared = {}

-- ============================================================================
-- 网络事件
-- ============================================================================

Shared.EVENTS = {
    -- 客户端 → 服务器（请求）
    CLICK_REQUEST = "ClickRequest",     -- 点一下香蕉
    SET_PROFILE = "SetProfile",         -- 新用户设置昵称 + 头像
    LIST_REQUEST = "ListRequest",       -- 上架：把仓库里的某个商品挂到市场
    SELL_REQUEST = "SellRequest",       -- 卖给官方：普通香蕉一口价回收
    BID_REQUEST = "BidRequest",         -- 出价
    BUYOUT_REQUEST = "BuyoutRequest",   -- 秒杀
    INVENTORY_REQUEST = "InventoryRequest", -- 查看指定玩家的仓库
    LOAN_REQUEST = "LoanRequest",       -- 向银行借款
    REPAY_REQUEST = "RepayRequest",     -- 还款

    -- 服务器 → 客户端
    MARKET_UPDATE = "MarketUpdate",     -- 市场 + 自己仓库 + 自己资料的快照（JSON）
    DROP_RESULT = "DropResult",         -- 掉落结果，只发给当事人
    POINT_UPDATE = "PointUpdate",       -- 自己的积分数值（轻量，每秒一次）
    PLAYER_INVENTORY = "PlayerInventory", -- 某玩家仓库快照（只回给请求者）
}

-- 服务器需要接收的事件
Shared.SERVER_EVENTS = {
    Shared.EVENTS.CLICK_REQUEST,
    Shared.EVENTS.SET_PROFILE,
    Shared.EVENTS.LIST_REQUEST,
    Shared.EVENTS.SELL_REQUEST,
    Shared.EVENTS.BID_REQUEST,
    Shared.EVENTS.BUYOUT_REQUEST,
    Shared.EVENTS.INVENTORY_REQUEST,
    Shared.EVENTS.LOAN_REQUEST,
    Shared.EVENTS.REPAY_REQUEST,
}

-- 客户端需要接收的事件
Shared.CLIENT_EVENTS = {
    Shared.EVENTS.MARKET_UPDATE,
    Shared.EVENTS.DROP_RESULT,
    Shared.EVENTS.POINT_UPDATE,
    Shared.EVENTS.PLAYER_INVENTORY,
}

-- 快照 JSON 放在这个字段里传输
Shared.PAYLOAD_FIELD = "Payload"

-- ============================================================================
-- 商品品质
-- ============================================================================

Shared.RARITIES = {
    { key = "normal", name = "Normal 普通", probability = 70.0, color = { 181, 181, 181, 255 }, price = 0.01, image = "image/banana_normal_20260922031810.png" },
    { key = "common", name = "Common 优良", probability = 25.0, color = { 162, 255, 148, 255 }, price = 0.02, image = "image/banana_common_20260922031813.png" },
    { key = "uncommon", name = "Uncommon 罕见", probability = 4.89, color = { 114, 242, 245, 255 }, price = 0.05, image = "image/banana_uncommon_20260922031807.png" },
    { key = "rare", name = "Rare 稀有", probability = 0.1, color = { 115, 160, 255, 255 }, price = 0.1, image = "image/banana_rare_20260922031814.png" },
    { key = "epic", name = "Epic 史诗", probability = 0.01, color = { 239, 121, 255, 255 }, price = 0.2, image = "image/banana_epic_20260922031809.png" },
    { key = "ultra_rare", name = "Ultra Rare 超稀有", probability = 0.00025, color = { 255, 255, 255, 255 }, price = 0.4, image = "image/banana_ultra_rare_20260922031804.png" },
    { key = "legendary", name = "Legendary 传说", probability = 9.999999999999999e-06, color = { 255, 237, 0, 255 }, price = 0.7, image = "image/banana_legendary_20260922031808.png" },
    { key = "mythic", name = "Mythic 神话", probability = 1e-06, color = { 255, 92, 92, 255 }, price = 0.99, image = "image/banana_mythic_f1.png", frames = { "image/banana_mythic_f1.png", "image/banana_mythic_f2.png", "image/banana_mythic_f3.png", "image/banana_mythic_f4.png", "image/banana_mythic_f5.png", "image/banana_mythic_f6.png", "image/banana_mythic_f7.png", "image/banana_mythic_f8.png" } },
    { key = "bananamobile", name = "Bananamobile", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_bananamobile.png" },
    { key = "minotaurmana", name = "Minotaurmana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_minotaurmana.png" },
    { key = "papercutnana", name = "Papercutnana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_papercutnana.png" },
    { key = "cripplenana", name = "Cripplenana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_cripplenana.png" },
    { key = "zombienana", name = "Zombienana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_zombienana.png" },
    { key = "dreambanana", name = "Dream Banana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_dreambanana.png" },
    { key = "sharknana", name = "Sharknana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_sharknana.png" },
    { key = "fortunecookienana", name = "Fortunecookienana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_fortunecookienana.png" },
    { key = "fencenana", name = "Fencenana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_fencenana.png" },
    { key = "perseverancenana", name = "Perseverancenana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_perseverancenana.png" },
    { key = "bonsainana", name = "Bonsainana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_bonsainana.png" },
    { key = "farmernana", name = "Farmernana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_farmernana.png" },
    { key = "primordialnana", name = "Primordialnana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_primordialnana.png" },
    { key = "poststampnana", name = "Poststampnana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_poststampnana.png" },
    { key = "swissnana", name = "Swissnana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_swissnana.png" },
    { key = "pharaonana", name = "Pharaonana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_pharaonana.png" },
    { key = "alienana", name = "Alienana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_alienana.png" },
    { key = "starryornamentnana", name = "Starryornamentnana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_starryornamentnana.png" },
    { key = "claynana", name = "Claynana", probability = 2.0, color = { 181, 181, 181, 255 }, price = 0.02, image = "image/banana_claynana.png" },
    { key = "ihopeitsabikenana", name = "Ihopeitsabikenana", probability = 1.0, color = { 162, 255, 148, 255 }, price = 0.04, image = "image/banana_ihopeitsabikenana.png" },
    { key = "paintsetnana", name = "Paintsetnana", probability = 1.0, color = { 162, 255, 148, 255 }, price = 0.06, image = "image/banana_paintsetnana.png" },
    { key = "slalomnana", name = "Slalomnana", probability = 1.0, color = { 114, 242, 245, 255 }, price = 0.12, image = "image/banana_slalomnana.png" },
    { key = "nutcracknana", name = "Nutcracknana", probability = 1.0, color = { 114, 242, 245, 255 }, price = 0.18, image = "image/banana_nutcracknana.png" },
    { key = "reindeernana", name = "Reindeernana", probability = 0.2, color = { 115, 160, 255, 255 }, price = 0.45, image = "image/banana_reindeernana.png" },
    { key = "christmasbalnana", name = "Christmasbalnana", probability = 0.2, color = { 239, 121, 255, 255 }, price = 0.6, image = "image/banana_christmasbalnana.png" },
    { key = "sleighnana", name = "Sleighnana", probability = 0.2, color = { 239, 121, 255, 255 }, price = 0.8, image = "image/banana_sleighnana.png" },
    { key = "mlgbanana", name = "MLGBanana", probability = 0.2, color = { 239, 121, 255, 255 }, price = 0.95, image = "image/banana_mlgbanana.png" },
}

-- 新账户默认获得的商品（按品质 key）
Shared.STARTER_ITEMS = { "normal", "normal", "uncommon" }

-- 玩法数值
Shared.DROP_COST = 60               -- 点满多少次掉一个香蕉
Shared.AUTO_POINT_INTERVAL = 1.0    -- 服务端每秒自动加多少点
Shared.MAX_CLICK_PER_REPORT = 30    -- 单次上报的点击数上限（防刷）
Shared.MAX_NICKNAME_LEN = 12

-- 经济
Shared.ECONOMY = {
    START_BALANCE = 10,             -- 新账户初始余额（按商品几分~几毛的新价体系定）
    MAX_LOAN = 50,                  -- 同时可欠的最大负债
    SERVICE_FEE_RATE = 0.02,        -- 成交手续费（从卖家所得里扣）
    INTEREST_RATE = 0.01,           -- 每个计息周期对未还负债计息
    INTEREST_INTERVAL = 10,         -- 计息周期（秒）
}

-- 可选头像：抽象物种
Shared.AVATARS = {
    { key = "blob", image = "image/avatar_blob_20260921161942.png" },
    { key = "frog", image = "image/avatar_frog_20260921161939.png" },
    { key = "banana", image = "image/avatar_banana_20260921161942.png" },
    { key = "eye", image = "image/avatar_eye_20260921161942.png" },
    { key = "cat", image = "image/avatar_cat_20260921161941.png" },
    { key = "alien", image = "image/avatar_alien_20260921161938.png" },
    { key = "spiral", image = "image/avatar_spiral_20260921161938.png" },
    { key = "cube", image = "image/avatar_cube_20260921161949.png" },
}

---@param key string
---@return boolean
function Shared.IsValidAvatar(key)
    for _, avatar in ipairs(Shared.AVATARS) do
        if avatar.key == key then
            return true
        end
    end
    return false
end

---@param key string
---@return string
function Shared.GetAvatarImage(key)
    for _, avatar in ipairs(Shared.AVATARS) do
        if avatar.key == key then
            return avatar.image
        end
    end
    return Shared.AVATARS[1].image
end

---@param key string
---@return table
function Shared.GetRarity(key)
    for _, rarity in ipairs(Shared.RARITIES) do
        if rarity.key == key then
            return rarity
        end
    end
    return Shared.RARITIES[1]
end

---@return table
function Shared.RollRarity()
    local total = 0
    for _, rarity in ipairs(Shared.RARITIES) do
        total = total + rarity.probability
    end
    local roll = math.random() * total
    local cursor = 0
    for _, rarity in ipairs(Shared.RARITIES) do
        cursor = cursor + rarity.probability
        if roll <= cursor then
            return rarity
        end
    end
    return Shared.RARITIES[1]
end

---@param rarity table
---@param frameIndex integer
---@return string 商品图路径；有 frames 的品质按帧取图（眼睛会动）
function Shared.GetRarityImage(rarity, frameIndex)
    local frames = rarity.frames
    if frames and #frames > 0 then
        local index = ((frameIndex - 1) % #frames) + 1
        return frames[index]
    end
    return rarity.image
end

---@param rarity table
---@return boolean 这个品质的图是否需要逐帧刷新
function Shared.IsAnimatedRarity(rarity)
    return rarity.frames ~= nil and #rarity.frames > 1
end

---@param rarityKey string
---@return boolean
function Shared.IsValidRarity(rarityKey)
    for _, rarity in ipairs(Shared.RARITIES) do
        if rarity.key == rarityKey then
            return true
        end
    end
    return false
end

-- 开发调试：名单里的账号连接时会把缺的品质各补一个（已有的不重复发）。
-- ⚠️ 上线前清空这个表。
Shared.DEV_GRANT_USER_IDS = {
    1052919190,
}

-- serverCloud 存储配置
Shared.CLOUD = {
    SAVE = "banana_save",               -- 玩家存档：余额/负债/仓库/资料
    MARKET = "banana_market",           -- 全局市场挂单
    ASSETS = "banana_assets",           -- 排行榜排序用的净资产（必须是整数）
    MARKET_OWNER = 1,                   -- 存放全局市场数据的保留账号 id
    AUTOSAVE_INTERVAL = 15,             -- 存档回写间隔（秒）

    -- 市场数据结构版本。改价格体系、挂单字段这类会让旧数据失效的改动时 +1，
    -- 服务器下次启动会丢弃旧挂单（只执行一次，版本号写在云端）。
    MARKET_VERSION = 2,
    MARKET_VERSION_KEY = "banana_market_version",
}

-- 普通香蕉不能挂单，只能一口价卖给官方
Shared.SYSTEM_BUY_RARITY = "normal"

---@param rarityKey string
---@return boolean 是否允许挂到市场
function Shared.CanListItem(rarityKey)
    return rarityKey ~= Shared.SYSTEM_BUY_RARITY
end

---@param rarityKey string
---@return number 官方回收价
function Shared.SystemBuyPrice(rarityKey)
    return Shared.GetRarity(rarityKey).price
end

---@param value number
---@return string 精确金额，带千分位：1,002 / 50,000 / 1,234.567K
--- 百万以上改用 K（避免一长串数字），但依然不四舍五入：
--- 除以 1000 对整数金额最多产生 3 位小数，可以完整表示。
function Shared.FormatMoney(value)
    local negative = value < 0
    local amount = math.abs(value)
    local scaled = amount
    local suffix = ""
    if amount >= 1000000 then
        scaled = amount / 1000
        suffix = "K"
    end
    local whole = math.floor(scaled)
    local frac = math.floor((scaled - whole) * 1000 + 0.5)
    if frac >= 1000 then
        whole = whole + 1
        frac = 0
    end
    local grouped = string.gsub(string.reverse(tostring(whole)), "(%d%d%d)", "%1,")
    local text = string.reverse(grouped)
    if string.sub(text, 1, 1) == "," then
        text = string.sub(text, 2)
    end
    if frac > 0 then
        local fracText = string.format("%03d", frac)
        fracText = string.gsub(fracText, "0+$", "")
        text = text .. "." .. fracText
    end
    if negative then
        text = "-" .. text
    end
    return text .. suffix
end

---@param value number
---@return string 输入框里显示的金额：纯数字，不带千分位
--- 输入框是要被 tonumber 解析的，加了逗号会解析失败（"5,000" -> nil）
function Shared.FormatAmountInput(value)
    if math.abs(value - math.floor(value + 0.5)) < 0.005 then
        return tostring(math.floor(value + 0.5))
    end
    return string.format("%.2f", value)
end

---@param text string|nil
---@return number|nil 解析用户输入的金额，容忍千分位和空格
function Shared.ParseAmount(text)
    local cleaned = string.gsub(text or "", "[^%d%.%-]", "")
    if cleaned == "" or cleaned == "-" or cleaned == "." then
        return nil
    end
    return tonumber(cleaned)
end

---@param value number
---@return number
function Shared.RoundPrice(value)
    if value >= 100 then
        return math.floor(value + 0.5)
    end
    return math.floor(value * 100 + 0.5) / 100
end

---@param value number
---@return string
function Shared.FormatPrice(value)
    if value >= 1000000 then
        return string.format("%.2fM", value / 1000000)
    end
    if value >= 1000 then
        return string.format("%.1fK", value / 1000)
    end
    if math.abs(value - math.floor(value + 0.5)) < 0.05 then
        return tostring(math.floor(value + 0.5))
    end
    return string.format("%.1f", value)
end

-- ============================================================================
-- 事件注册（接收方必须注册，否则事件会被静默丢弃）
-- ============================================================================

-- 注册函数（双方都需要注册所有事件）
function Shared.RegisterServerEvents()
    for _, eventName in ipairs(Shared.SERVER_EVENTS) do
        network:RegisterRemoteEvent(eventName)
    end
    for _, eventName in ipairs(Shared.CLIENT_EVENTS) do
        network:RegisterRemoteEvent(eventName)
    end
end

function Shared.RegisterClientEvents()
    for _, eventName in ipairs(Shared.SERVER_EVENTS) do
        network:RegisterRemoteEvent(eventName)
    end
    for _, eventName in ipairs(Shared.CLIENT_EVENTS) do
        network:RegisterRemoteEvent(eventName)
    end
end

return Shared
