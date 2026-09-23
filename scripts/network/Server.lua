--[[
Server - 权威服务端

市场挂单和每个账户的仓库都只存在于这里，客户端只是显示 + 发请求。

玩家身份用认证后的 user_id（PlayerSessions 负责与会话绑定），
所以同一个账号重连回来，仓库里的东西还在。

客户端能发来的只有 4 种请求（掉落 / 上架 / 出价 / 秒杀），
所有数值校验都在服务端做，客户端改不了结果。
]]

local Shared = require("network.Shared")
local PlayerSessions = require("urhox-libs.Network.PlayerSessions")

local Server = {}

local scene_ = nil

-- 全局市场挂单
---@type table[]
local listings_ = {}
local nextListingId_ = 1

-- 自动加点的计时累加器（服务端权威）
local autoPointAccumulator_ = 0
-- 贷款计息的计时累加器
local interestAccumulator_ = 0
local autosaveAccumulator_ = 0
local marketDirty_ = false

-- 前向声明：读档是异步的，读完要重新广播快照；实现在下方
---@type fun()
local BroadcastMarket
---@type fun(entry: PlayerSessionEntry): boolean
local TryDrop

---@class PlayerState
---@field inventory table[]
---@field nextItemId integer
---@field nickname string
---@field avatar string
---@field profileReady boolean
---@field points number
---@field totalPoints number
---@field totalClicks number
---@field totalDrops number
---@field balance number
---@field debt number

local TREND_HISTORY_SECONDS = 25 * 3600

local function NowTimestamp()
    return math.tointeger(os.time()) or 0
end

-- ============================================================================
-- 工具
-- ============================================================================

---@param history table[]
---@param timestamp integer
---@param value number
local function RecordPriceSample(history, timestamp, value)
    local last = history[#history]
    if last and last.t == timestamp then
        last.v = value
        return
    end
    history[#history + 1] = { t = timestamp, v = value }
    local cutoff = timestamp - TREND_HISTORY_SECONDS
    local dropCount = 0
    for index = 1, #history do
        if history[index].t >= cutoff then
            break
        end
        dropCount = dropCount + 1
    end
    if dropCount > 0 then
        local trimmed = {}
        for index = dropCount + 1, #history do
            trimmed[#trimmed + 1] = history[index]
        end
        for index = 1, #trimmed do
            history[index] = trimmed[index]
        end
        for index = #trimmed + 1, #history do
            history[index] = nil
        end
    end
end

---@param listingId integer
---@return table|nil
local function FindListing(listingId)
    for _, listing in ipairs(listings_) do
        if listing.id == listingId then
            return listing
        end
    end
    return nil
end

---@param userId integer
---@param itemId integer
---@return table|nil, integer|nil
local function TakeFromInventory(userId, itemId)
    local entry = PlayerSessions.Server.Get(userId)
    if not entry or not entry.state then
        return nil, nil
    end
    local inventory = entry.state.inventory
    for index, item in ipairs(inventory) do
        if item.id == itemId then
            table.remove(inventory, index)
            return item, index
        end
    end
    return nil, nil
end

---@param userId integer
---@param itemId integer
---@return table|nil 找到时返回仓库里的商品（不移除）
local function FindInventoryItem(userId, itemId)
    local entry = PlayerSessions.Server.Get(userId)
    if not entry or not entry.state then
        return nil
    end
    for _, item in ipairs(entry.state.inventory) do
        if item.id == itemId then
            return item
        end
    end
    return nil
end

---@param userId integer
---@param rarityKey string
---@return table
local function GrantItem(userId, rarityKey)
    local entry = PlayerSessions.Server.Get(userId)
    local state = entry.state
    local item = {
        id = state.nextItemId,
        rarity = rarityKey,
        obtainedAt = NowTimestamp(),
    }
    state.nextItemId = state.nextItemId + 1
    state.inventory[#state.inventory + 1] = item
    return item
end

-- 商品估值：按品质的参考价
---@param rarityKey string
---@return number
local function ItemValue(rarityKey)
    return Shared.GetRarity(rarityKey).price
end

-- 净资产 = 余额 - 负债 + 仓库商品估值 + 自己挂单的当前价
---@param entry PlayerSessionEntry
---@return number
local function PlayerAssets(entry)
    local state = entry.state
    local total = state.balance - state.debt
    for _, item in ipairs(state.inventory) do
        total = total + ItemValue(item.rarity)
    end
    local sellerId = tostring(entry.userId)
    for _, listing in ipairs(listings_) do
        if listing.sellerId == sellerId then
            total = total + listing.price
        end
    end
    return total
end

---@param entry PlayerSessionEntry
---@return string
local function DisplayName(entry)
    if entry.state.nickname ~= "" then
        return entry.state.nickname
    end
    return "玩家" .. tostring(entry.userId)
end

-- ============================================================================
-- 云端存档（serverCloud）
--
-- 内存里的状态是权威的，云端只负责持久化：
--   玩家存档 → 存在各自 uid 下，服务器重启后能读回来
--   市场挂单 → 存在保留账号 MARKET_OWNER 下，是全局唯一的一份
-- 没有 serverCloud 时（比如本地跑）全部降级为纯内存，不影响玩法。
-- ============================================================================

---@return boolean 当前环境是否支持云存储
local function CloudReady()
    -- luacheck: ignore
    return serverCloud ~= nil
end

---@param state PlayerState
---@return table
local function BuildSaveBlob(state)
    local inventory = {}
    for _, item in ipairs(state.inventory) do
        inventory[#inventory + 1] = {
            id = item.id,
            rarity = item.rarity,
            obtainedAt = item.obtainedAt,
        }
    end
    return {
        version = 1,
        nickname = state.nickname,
        avatar = state.avatar,
        profileReady = state.profileReady,
        balance = state.balance,
        debt = state.debt,
        points = state.points,
        totalPoints = state.totalPoints,
        totalClicks = state.totalClicks,
        totalDrops = state.totalDrops,
        nextItemId = state.nextItemId,
        inventory = inventory,
    }
end

-- 云端数据属于外部输入，逐字段校验后再写进内存状态
---@param state PlayerState
---@param blob table
local function ApplySaveBlob(state, blob)
    state.nickname = tostring(blob.nickname or "")
    state.avatar = tostring(blob.avatar or "")
    state.profileReady = blob.profileReady == true
    state.balance = tonumber(blob.balance) or Shared.ECONOMY.START_BALANCE
    state.debt = tonumber(blob.debt) or 0
    state.points = tonumber(blob.points) or 0
    state.totalPoints = tonumber(blob.totalPoints) or 0
    state.totalClicks = tonumber(blob.totalClicks) or 0
    state.totalDrops = tonumber(blob.totalDrops) or 0
    state.nextItemId = math.tointeger(blob.nextItemId) or 1

    state.inventory = {}
    if type(blob.inventory) == "table" then
        local maxId = 0
        for _, raw in ipairs(blob.inventory) do
            local id = math.tointeger(raw.id)
            local rarity = tostring(raw.rarity or "")
            if id and Shared.IsValidRarity(rarity) then
                state.inventory[#state.inventory + 1] = {
                    id = id,
                    rarity = rarity,
                    obtainedAt = math.tointeger(raw.obtainedAt) or NowTimestamp(),
                }
                maxId = math.max(maxId, id)
            end
        end
        -- 防止存档里的 nextItemId 落后导致 id 撞车
        state.nextItemId = math.max(state.nextItemId, maxId + 1)
    end
end

---@param userId integer
local function SavePlayer(userId)
    if not CloudReady() then
        return
    end
    local entry = PlayerSessions.Server.Get(userId)
    if not entry or not entry.state then
        return
    end
    serverCloud:BatchSet(userId)
        :Set(Shared.CLOUD.SAVE, BuildSaveBlob(entry.state))
        :SetInt(Shared.CLOUD.ASSETS, math.floor(PlayerAssets(entry) + 0.5))
        :Save("玩家存档", {
            error = function(code, reason)
                print(string.format("[Server] 存档失败 %s: %s %s",
                    tostring(userId), tostring(code), tostring(reason)))
            end,
        })
end

-- 开发发放：把仓库里没有的品质各补一个。按品质去重，所以重复连接是幂等的。
---@param entry PlayerSessionEntry
local function ApplyDevGrant(entry)
    local userId = entry.userId
    local listed = false
    for _, id in ipairs(Shared.DEV_GRANT_USER_IDS) do
        local numeric = math.tointeger(id)
        if numeric == userId then
            listed = true
            break
        end
    end
    if not listed then
        return
    end

    ---@type table<string, boolean>
    local owned = {}
    for _, item in ipairs(entry.state.inventory) do
        owned[item.rarity] = true
    end

    local granted = 0
    for _, rarity in ipairs(Shared.RARITIES) do
        if not owned[rarity.key] then
            GrantItem(userId, rarity.key)
            granted = granted + 1
        end
    end
    if granted > 0 then
        print(string.format("[Server] 开发发放：玩家 %s 补齐 %d 种品质，仓库现有 %d 件",
            tostring(userId), granted, #entry.state.inventory))
        SavePlayer(userId)
        BroadcastMarket()
    end
end

---@param userId integer
local function LoadPlayer(userId)
    if not CloudReady() then
        return
    end
    local entry = PlayerSessions.Server.Get(userId)
    if not entry or not entry.state then
        return
    end
    serverCloud:Get(userId, Shared.CLOUD.SAVE, {
        ok = function(scores, iscores)
            local blob = scores and scores[Shared.CLOUD.SAVE]
            if type(blob) == "table" then
                ApplySaveBlob(entry.state, blob)
                -- 旧存档可能积了超过 60 的点数（当时阈值是 300），读档后立刻结算
                if TryDrop(entry) then
                    print(string.format("[Server] 玩家 %s 读档后结算超额进度，剩余 %d 点",
                        tostring(userId), math.tointeger(entry.state.points) or 0))
                end
                print(string.format("[Server] 玩家 %s 读档成功：余额 ¥%s，仓库 %d 件，进度 %d/%d",
                    tostring(userId), Shared.FormatMoney(entry.state.balance),
                    #entry.state.inventory,
                    math.tointeger(entry.state.points) or 0, Shared.DROP_COST))
            else
                print(string.format("[Server] 玩家 %s 无存档，使用初始数据", tostring(userId)))
            end
            -- 无论读没读到都回写一次：新账号把初始状态落盘
            SavePlayer(userId)
            -- 开发发放放在读档之后，否则会被存档覆盖掉
            ApplyDevGrant(entry)
            BroadcastMarket()
        end,
        error = function(code, reason)
            print(string.format("[Server] 读档失败 %s: %s %s",
                tostring(userId), tostring(code), tostring(reason)))
        end,
    })
end

local function SaveMarket()
    if not CloudReady() then
        return
    end
    serverCloud:Set(Shared.CLOUD.MARKET_OWNER, Shared.CLOUD.MARKET, { listings = listings_ }, {
        error = function(code, reason)
            print(string.format("[Server] 市场存档失败: %s %s", tostring(code), tostring(reason)))
        end,
    })
end

local function LoadMarket()
    if not CloudReady() then
        print("[Server] 无 serverCloud，市场仅存内存")
        return
    end

    -- 先查数据结构版本：版本落后说明是旧体系留下的挂单，整批丢弃。
    -- 版本号存在云端，所以只会在版本提升后的第一次启动执行一次。
    serverCloud:BatchGet(Shared.CLOUD.MARKET_OWNER)
        :Key(Shared.CLOUD.MARKET_VERSION_KEY)
        :Key(Shared.CLOUD.MARKET)
        :Fetch({
            ok = function(scores, iscores)
                local store = scores or {}
                local storedVersion = tonumber(store[Shared.CLOUD.MARKET_VERSION_KEY]) or 0

                if storedVersion < Shared.CLOUD.MARKET_VERSION then
                    local blob = store[Shared.CLOUD.MARKET]
                    local oldCount = 0
                    if type(blob) == "table" and type(blob.listings) == "table" then
                        oldCount = #blob.listings
                    end
                    print(string.format("[Server] 市场数据版本 %d -> %d，清空旧挂单 %d 条",
                        storedVersion, Shared.CLOUD.MARKET_VERSION, oldCount))
                    listings_ = {}
                    nextListingId_ = 1
                    SaveMarket()
                    serverCloud:Set(Shared.CLOUD.MARKET_OWNER, Shared.CLOUD.MARKET_VERSION_KEY,
                        Shared.CLOUD.MARKET_VERSION, {
                            error = function(code, reason)
                                print(string.format("[Server] 市场版本号写入失败: %s %s",
                                    tostring(code), tostring(reason)))
                            end,
                        })
                    BroadcastMarket()
                    return
                end

                local blob = store[Shared.CLOUD.MARKET]
                if type(blob) ~= "table" or type(blob.listings) ~= "table" then
                    print("[Server] 云端无市场数据，从空市场开始")
                    return
                end
                local restored = {}
                local maxId = 0
                for _, raw in ipairs(blob.listings) do
                    local id = math.tointeger(raw.id)
                    local rarity = tostring(raw.rarity or "")
                    local price = tonumber(raw.price)
                    local buyout = tonumber(raw.buyout)
                    if id and price and buyout and Shared.IsValidRarity(rarity) then
                        restored[#restored + 1] = {
                            id = id,
                            rarity = rarity,
                            sellerId = tostring(raw.sellerId or ""),
                            sellerUserId = math.tointeger(raw.sellerUserId) or 0,
                            sellerName = tostring(raw.sellerName or "玩家"),
                            sellerAvatar = tostring(raw.sellerAvatar or ""),
                            price = price,
                            buyout = buyout,
                            bidder = raw.bidder,
                            history = type(raw.history) == "table" and raw.history or {},
                        }
                        maxId = math.max(maxId, id)
                    end
                end
                listings_ = restored
                nextListingId_ = maxId + 1
                print(string.format("[Server] 从云端载入 %d 条挂单（数据版本 %d）",
                    #listings_, storedVersion))
                BroadcastMarket()
            end,
            error = function(code, reason)
                print(string.format("[Server] 市场读档失败: %s %s", tostring(code), tostring(reason)))
            end,
        })
end

-- 全服排行榜：包含离线玩家（他们的状态还在宽限期里）
-- 长期账本：每个出现过的用户都留一条记录，离开后依然留在排行榜上。
-- 只靠 PlayerSessions 的表是不够的——宽限期一过玩家状态就被销毁，
-- 人也就从榜单上消失了。
---@class LeaderboardRecord
---@field userId string
---@field nickname string
---@field avatar string
---@field assets number
---@field online boolean

---@type table<string, LeaderboardRecord>
local records_ = {}

---@return table[]
local function BuildLeaderboard()
    -- 先把当前在册玩家（含宽限期内掉线的）的记录刷新一遍
    local seen = {}
    PlayerSessions.Server.ForEach(function(entry)
        if entry.state then
            local id = tostring(entry.userId)
            seen[id] = true
            local record = records_[id]
            if not record then
                record = { userId = id, nickname = "", avatar = "", assets = 0, online = true }
                records_[id] = record
            end
            record.nickname = DisplayName(entry)
            record.avatar = entry.state.avatar
            record.assets = Shared.RoundPrice(PlayerAssets(entry))
            record.online = true
        end
    end)

    -- 本轮没出现的标记为离线，但记录保留
    ---@type table[]
    local rows = {}
    for id, record in pairs(records_) do
        if not seen[id] then
            record.online = false
        end
        rows[#rows + 1] = {
            userId = record.userId,
            nickname = record.nickname ~= "" and record.nickname or ("玩家" .. record.userId),
            avatar = record.avatar,
            assets = record.assets,
            online = record.online,
        }
    end
    table.sort(rows, function(a, b)
        if a.assets == b.assets then
            return a.userId < b.userId
        end
        return a.assets > b.assets
    end)
    return rows
end

---@param userId integer
---@return string
local function BuildPayload(userId)
    local entry = PlayerSessions.Server.Get(userId)
    local state = entry and entry.state or nil

    local inventory = {}
    if state then
        for _, item in ipairs(state.inventory) do
            inventory[#inventory + 1] = {
                id = item.id,
                rarity = item.rarity,
                obtainedAt = item.obtainedAt,
            }
        end
    end

    local listings = {}
    for _, listing in ipairs(listings_) do
        local history = {}
        for _, sample in ipairs(listing.history) do
            history[#history + 1] = { t = sample.t, v = sample.v }
        end
        listings[#listings + 1] = {
            id = listing.id,
            rarity = listing.rarity,
            sellerId = listing.sellerId,
            sellerName = listing.sellerName,
            sellerAvatar = listing.sellerAvatar,
            price = listing.price,
            buyout = listing.buyout,
            bidder = listing.bidder or "",
            history = history,
        }
    end

    return cjson.encode({
        userId = tostring(userId),
        profileReady = state and state.profileReady or false,
        nickname = state and state.nickname or "",
        avatar = state and state.avatar or "",
        points = state and state.points or 0,
        totalPoints = state and state.totalPoints or 0,
        totalClicks = state and state.totalClicks or 0,
        totalDrops = state and state.totalDrops or 0,
        balance = state and state.balance or 0,
        debt = state and state.debt or 0,
        assets = entry and Shared.RoundPrice(PlayerAssets(entry)) or 0,
        leaderboard = BuildLeaderboard(),
        inventory = inventory,
        listings = listings,
    })
end

---@param entry PlayerSessionEntry
---@return VariantMap
local function BuildPointMap(entry)
    local variantMap = VariantMap()
    variantMap["Points"] = Variant(entry.state.points)
    variantMap["TotalPoints"] = Variant(entry.state.totalPoints)
    variantMap["TotalClicks"] = Variant(entry.state.totalClicks)
    variantMap["TotalDrops"] = Variant(entry.state.totalDrops)
    return variantMap
end

-- 积满点数就掉一个香蕉。返回是否发生了掉落（掉落会改变仓库，需要重推市场快照）
---@param entry PlayerSessionEntry
---@return boolean
TryDrop = function(entry)
    local state = entry.state
    local dropped = false
    while state.points >= Shared.DROP_COST do
        state.points = state.points - Shared.DROP_COST
        state.totalDrops = state.totalDrops + 1
        local rarity = Shared.RollRarity()
        local item = GrantItem(entry.userId, rarity.key)
        dropped = true
        print(string.format("[Server] 玩家 %s 掉落 #%d: %s",
            tostring(entry.userId), item.id, rarity.name))

        if entry.connection then
            local result = VariantMap()
            result["Rarity"] = Variant(rarity.key)
            result["ItemId"] = Variant(item.id)
            entry.connection:SendRemoteEvent(Shared.EVENTS.DROP_RESULT, true, result)
        end
    end
    return dropped
end

-- 把市场 + 该玩家自己仓库的全量状态推给所有在线玩家
BroadcastMarket = function()
    -- 每次广播都意味着市场状态刚刚变过，顺带标记待回写
    marketDirty_ = true
    PlayerSessions.Server.ForEachOnline(function(entry, connection)
        local variantMap = VariantMap()
        variantMap[Shared.PAYLOAD_FIELD] = Variant(BuildPayload(entry.userId))
        connection:SendRemoteEvent(Shared.EVENTS.MARKET_UPDATE, true, variantMap)
    end)
end

-- ============================================================================
-- 请求处理
--
-- ⚠️ 这些处理函数必须是**全局函数**：SubscribeToEvent 按函数名在全局表里查找，
--    写成 local function 不会报错，只会在引擎日志里留下
--    "Could not find Lua function"，然后事件被静默丢弃。
-- ============================================================================

---@param eventType string
---@param eventData VariantMap
function HandleClickRequest(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local entry = PlayerSessions.Server.FromConnection(connection)
    if not entry then
        return
    end

    local clicks = eventData["Clicks"]:GetInt()
    if clicks < 1 then
        return
    end
    -- 单次上报封顶，避免客户端一次性声明几千点
    if clicks > Shared.MAX_CLICK_PER_REPORT then
        clicks = Shared.MAX_CLICK_PER_REPORT
    end

    entry.state.points = entry.state.points + clicks
    entry.state.totalPoints = entry.state.totalPoints + clicks
    entry.state.totalClicks = entry.state.totalClicks + clicks

    local dropped = TryDrop(entry)
    connection:SendRemoteEvent(Shared.EVENTS.POINT_UPDATE, true, BuildPointMap(entry))
    if dropped then
        BroadcastMarket()
    end
end

---@param eventType string
---@param eventData VariantMap
function HandleSetProfile(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local entry = PlayerSessions.Server.FromConnection(connection)
    if not entry then
        return
    end

    local nickname = eventData["Nickname"]:GetString()
    local avatar = eventData["Avatar"]:GetString()

    if #nickname < 1 or #nickname > Shared.MAX_NICKNAME_LEN then
        print(string.format("[Server] 玩家 %s 昵称不合法（长度 %d）", tostring(entry.userId), #nickname))
        return
    end
    if not Shared.IsValidAvatar(avatar) then
        print(string.format("[Server] 玩家 %s 头像不合法：%s", tostring(entry.userId), tostring(avatar)))
        return
    end

    entry.state.nickname = nickname
    entry.state.avatar = avatar
    entry.state.profileReady = true
    print(string.format("[Server] 玩家 %s 设置资料：%s / %s", tostring(entry.userId), nickname, avatar))

    -- 资料会出现在挂单的卖家信息里，所以要让所有人更新
    BroadcastMarket()
end

---@param eventType string
---@param eventData VariantMap
function HandleListRequest(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local entry = PlayerSessions.Server.FromConnection(connection)
    if not entry then
        return
    end
    local userId = entry.userId

    local itemId = eventData["ItemId"]:GetInt()
    local price = Shared.RoundPrice(eventData["Price"]:GetFloat())
    local buyout = Shared.RoundPrice(eventData["Buyout"]:GetFloat())

    if price <= 0 or buyout <= price then
        print(string.format("[Server] 玩家 %s 上架失败：价格不合法 (%.2f / %.2f)", userId, price, buyout))
        return
    end

    local item = FindInventoryItem(userId, itemId)
    if not item then
        print(string.format("[Server] 玩家 %s 上架失败：仓库里没有商品 #%d", userId, itemId))
        return
    end
    if not Shared.CanListItem(item.rarity) then
        print(string.format("[Server] 玩家 %s 上架失败：%s 不能挂单，只能卖给官方",
            userId, Shared.GetRarity(item.rarity).name))
        return
    end
    TakeFromInventory(userId, itemId)

    local rarity = Shared.GetRarity(item.rarity)
    local now = NowTimestamp()
    local nickname = entry.state.nickname
    if not nickname or nickname == "" then
        nickname = "玩家" .. tostring(userId)
    end
    listings_[#listings_ + 1] = {
        id = nextListingId_,
        rarity = item.rarity,
        sellerId = tostring(userId),
        sellerUserId = userId,
        sellerName = nickname,
        sellerAvatar = entry.state.avatar,
        price = price,
        buyout = buyout,
        bidder = nil,
        history = { { t = now, v = price } },
    }
    nextListingId_ = nextListingId_ + 1
    print(string.format("[Server] 玩家 %s 上架 %s 起始价¥%s 秒杀价¥%s",
        userId, rarity.name, Shared.FormatMoney(price), Shared.FormatMoney(buyout)))

    BroadcastMarket()
end

---@param eventType string
---@param eventData VariantMap
function HandleSellRequest(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local entry = PlayerSessions.Server.FromConnection(connection)
    if not entry then
        return
    end
    local userId = entry.userId

    local itemId = eventData["ItemId"]:GetInt()
    local item = FindInventoryItem(userId, itemId)
    if not item then
        print(string.format("[Server] 玩家 %s 卖给官方失败：仓库里没有商品 #%d", userId, itemId))
        return
    end
    if Shared.CanListItem(item.rarity) then
        print(string.format("[Server] 玩家 %s 卖给官方被拒：%s 应当走市场挂单",
            userId, Shared.GetRarity(item.rarity).name))
        return
    end

    local gain = Shared.SystemBuyPrice(item.rarity)
    TakeFromInventory(userId, itemId)
    entry.state.balance = entry.state.balance + gain
    print(string.format("[Server] 玩家 %s 卖给官方 %s，入账 ¥%s，余额 ¥%s",
        userId, Shared.GetRarity(item.rarity).name, Shared.FormatMoney(gain),
        Shared.FormatMoney(entry.state.balance)))

    BroadcastMarket()
end

---@param eventType string
---@param eventData VariantMap
function HandleBidRequest(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local entry = PlayerSessions.Server.FromConnection(connection)
    if not entry then
        return
    end
    local userId = entry.userId

    local listing = FindListing(eventData["ListingId"]:GetInt())
    if not listing then
        return
    end
    local amount = Shared.RoundPrice(eventData["Amount"]:GetFloat())
    if amount <= listing.price or amount > listing.buyout then
        print(string.format("[Server] 玩家 %s 出价 %.2f 被拒（当前 %.2f，秒杀价 %.2f）",
            userId, amount, listing.price, listing.buyout))
        return
    end

    listing.price = amount
    listing.bidder = tostring(userId)
    RecordPriceSample(listing.history, NowTimestamp(), amount)
    print(string.format("[Server] 玩家 %s 出价成功：挂单 #%d -> ¥%s",
        userId, listing.id, Shared.FormatMoney(amount)))

    BroadcastMarket()
end

---@param eventType string
---@param eventData VariantMap
function HandleBuyoutRequest(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local entry = PlayerSessions.Server.FromConnection(connection)
    if not entry then
        return
    end
    local userId = entry.userId

    local listingId = eventData["ListingId"]:GetInt()
    local listing = FindListing(listingId)
    if not listing then
        return
    end

    if entry.state.balance < listing.buyout then
        print(string.format("[Server] 玩家 %s 余额不足：¥%.2f < ¥%.2f",
            tostring(userId), entry.state.balance, listing.buyout))
        return
    end

    -- 付款：买家出全款，卖家到手扣掉手续费
    entry.state.balance = Shared.RoundPrice(entry.state.balance - listing.buyout)
    local sellerEntry = PlayerSessions.Server.Get(listing.sellerUserId)
    if sellerEntry and sellerEntry.state then
        local income = Shared.RoundPrice(listing.buyout * (1 - Shared.ECONOMY.SERVICE_FEE_RATE))
        sellerEntry.state.balance = Shared.RoundPrice(sellerEntry.state.balance + income)
        print(string.format("[Server] 卖家 %s 到账 ¥%s（扣手续费后）",
            tostring(listing.sellerUserId), Shared.FormatMoney(income)))
    end

    -- 买下的商品进买家仓库，挂单从市场移除
    local item = GrantItem(userId, listing.rarity)
    for index, other in ipairs(listings_) do
        if other.id == listingId then
            table.remove(listings_, index)
            break
        end
    end
    print(string.format("[Server] 玩家 %s 秒杀成交：挂单 #%d ¥%s，商品 #%d 已入库",
        userId, listingId, Shared.FormatMoney(listing.buyout), item.id))

    BroadcastMarket()
end

-- ============================================================================
-- 银行贷款
-- ============================================================================

---@param eventType string
---@param eventData VariantMap
function HandleInventoryRequest(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local entry = PlayerSessions.Server.FromConnection(connection)
    if not entry then
        return
    end

    local targetId = math.tointeger(tonumber(eventData["UserId"]:GetString() or "")) or 0
    local target = PlayerSessions.Server.Get(targetId)

    local payload = {
        ok = false,
        nickname = "",
        avatar = "",
        assets = 0,
        total = 0,
        items = {},
    }
    if target and target.state then
        local nickname = target.state.nickname
        if not nickname or nickname == "" then
            nickname = "玩家" .. tostring(targetId)
        end
        -- 按香蕉种类聚合：几百件藏品也只会发回几十条，包不会撑大
        local counts = {}
        for _, item in ipairs(target.state.inventory) do
            counts[item.rarity] = (counts[item.rarity] or 0) + 1
        end
        local items = {}
        for _, rarity in ipairs(Shared.RARITIES) do
            local count = counts[rarity.key]
            if count then
                items[#items + 1] = { key = rarity.key, count = count }
            end
        end
        payload.ok = true
        payload.nickname = nickname
        payload.avatar = target.state.avatar or ""
        payload.assets = Shared.RoundPrice(PlayerAssets(target))
        payload.total = #target.state.inventory
        payload.items = items
    end

    local variantMap = VariantMap()
    variantMap[Shared.PAYLOAD_FIELD] = Variant(cjson.encode(payload))
    connection:SendRemoteEvent(Shared.EVENTS.PLAYER_INVENTORY, true, variantMap)
    print(string.format("[Server] 玩家 %s 查看 %s 的仓库：%s", entry.userId, targetId,
        payload.ok and (tostring(payload.total) .. " 件") or "对方已离开"))
end

---@param eventType string
---@param eventData VariantMap
function HandleLoanRequest(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local entry = PlayerSessions.Server.FromConnection(connection)
    if not entry then
        return
    end

    local amount = Shared.RoundPrice(eventData["Amount"]:GetFloat())
    if amount <= 0 then
        return
    end

    -- 超出剩余额度就按额度截断
    local room = Shared.ECONOMY.MAX_LOAN - entry.state.debt
    if amount > room then
        amount = Shared.RoundPrice(room)
    end
    if amount <= 0 then
        print(string.format("[Server] 玩家 %s 借款被拒：已达上限 ¥%s",
            tostring(entry.userId), Shared.FormatMoney(Shared.ECONOMY.MAX_LOAN)))
        return
    end

    entry.state.balance = Shared.RoundPrice(entry.state.balance + amount)
    entry.state.debt = Shared.RoundPrice(entry.state.debt + amount)
    print(string.format("[Server] 玩家 %s 借款 ¥%s，当前负债 ¥%s",
        tostring(entry.userId), Shared.FormatMoney(amount), Shared.FormatMoney(entry.state.debt)))

    BroadcastMarket()
end

---@param eventType string
---@param eventData VariantMap
function HandleRepayRequest(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    local entry = PlayerSessions.Server.FromConnection(connection)
    if not entry then
        return
    end

    local amount = Shared.RoundPrice(eventData["Amount"]:GetFloat())
    if amount <= 0 then
        return
    end
    -- 最多还到负债为零，且不能超过手上的余额
    if amount > entry.state.debt then
        amount = entry.state.debt
    end
    if amount > entry.state.balance then
        amount = entry.state.balance
    end
    if amount <= 0 then
        print(string.format("[Server] 玩家 %s 还款被拒：余额或负债不足", tostring(entry.userId)))
        return
    end

    entry.state.balance = Shared.RoundPrice(entry.state.balance - amount)
    entry.state.debt = Shared.RoundPrice(entry.state.debt - amount)
    print(string.format("[Server] 玩家 %s 还款 ¥%s，剩余负债 ¥%s",
        tostring(entry.userId), Shared.FormatMoney(amount), Shared.FormatMoney(entry.state.debt)))

    BroadcastMarket()
end

-- 计息：对未还负债按周期复利
local function ApplyInterest()
    local charged = false
    PlayerSessions.Server.ForEach(function(entry)
        if entry.state and entry.state.debt > 0 then
            entry.state.debt = Shared.RoundPrice(entry.state.debt * (1 + Shared.ECONOMY.INTEREST_RATE))
            charged = true
        end
    end)
    return charged
end

-- ============================================================================
-- 生命周期
-- ============================================================================

function Server.Start()
    scene_ = Scene()
    scene_:CreateComponent("Octree", LOCAL)

    math.randomseed(NowTimestamp())

    PlayerSessions.Server.Setup({
        scene = scene_,

        -- 首次进入：建业务状态，并按默认配置发 3 个商品。
        -- 昵称/头像是空的，客户端会先弹设置界面。
        onCreatePlayer = function(userId, connection)
            print(string.format("[Server] 玩家 %s 首次加入", tostring(userId)))
            ---@type PlayerState
            local state = {
                inventory = {},
                nextItemId = 1,
                nickname = "",
                avatar = "",
                profileReady = false,
                points = 0,
                totalPoints = 0,
                totalClicks = 0,
                totalDrops = 0,
                balance = Shared.ECONOMY.START_BALANCE,
                debt = 0,
            }
            for _, rarityKey in ipairs(Shared.STARTER_ITEMS) do
                local item = {
                    id = state.nextItemId,
                    rarity = rarityKey,
                    obtainedAt = NowTimestamp(),
                }
                state.nextItemId = state.nextItemId + 1
                state.inventory[#state.inventory + 1] = item
            end
            return state
        end,

        -- 首次激活与重连恢复共用：把市场 + 自己仓库的全量快照发下去
        onBuildSnapshot = function(entry, isRestore, snapshot)
            snapshot[Shared.PAYLOAD_FIELD] = Variant(BuildPayload(entry.userId))
        end,

        onDisconnected = function(entry, timeout)
            print(string.format("[Server] 玩家 %s 掉线，宽限 %.0f 秒（仓库已暂存）",
                tostring(entry.userId), timeout))
        end,

        onDisposePlayer = function(entry, reason)
            print(string.format("[Server] 玩家 %s 离开：%s", tostring(entry.userId), reason))
        end,

        onActivated = function(entry, isRestore)
            print(string.format("[Server] 玩家 %s 已激活（%s），在线 %d",
                tostring(entry.userId), isRestore and "恢复" or "首次",
                PlayerSessions.Server.CountOnline()))
            -- 只在首次激活时读档。
            -- 重连恢复（isRestore）时内存里的状态才是最新的——玩家在掉线期间
            -- 依然在线过、卖过东西，用云端旧存档覆盖会把这段进度抹掉。
            if not isRestore then
                LoadPlayer(entry.userId)
            end
        end,
    })

    Shared.RegisterServerEvents()

    -- 先把上次的市场挂单读回来，避免重启后市场清空
    LoadMarket()

    SubscribeToEvent(Shared.EVENTS.CLICK_REQUEST, "HandleClickRequest")
    SubscribeToEvent(Shared.EVENTS.SET_PROFILE, "HandleSetProfile")
    SubscribeToEvent(Shared.EVENTS.LIST_REQUEST, "HandleListRequest")
    SubscribeToEvent(Shared.EVENTS.SELL_REQUEST, "HandleSellRequest")
    SubscribeToEvent(Shared.EVENTS.BID_REQUEST, "HandleBidRequest")
    SubscribeToEvent(Shared.EVENTS.BUYOUT_REQUEST, "HandleBuyoutRequest")
    SubscribeToEvent(Shared.EVENTS.INVENTORY_REQUEST, "HandleInventoryRequest")
    SubscribeToEvent(Shared.EVENTS.LOAN_REQUEST, "HandleLoanRequest")
    SubscribeToEvent(Shared.EVENTS.REPAY_REQUEST, "HandleRepayRequest")
    SubscribeToEvent("Update", "HandleServerUpdate")

    ---@diagnostic disable-next-line: undefined-global
    print(string.format("[Server] 市场服务已启动，最大玩家 %d", SERVER_MAX_PLAYERS))
end

-- 服务端计时：每个在线玩家按固定间隔自动加点数，积满就掉落。
-- 积分的账本完全在服务端，客户端报的点击数也要经过这里。
---@param eventType string
---@param eventData UpdateEventData
function HandleServerUpdate(eventType, eventData)
    local timeStep = eventData:GetFloat("TimeStep")

    -- 定期回写云端存档（放在最前面，避免被下面的提前 return 跳过）
    autosaveAccumulator_ = autosaveAccumulator_ + timeStep
    if autosaveAccumulator_ >= Shared.CLOUD.AUTOSAVE_INTERVAL then
        autosaveAccumulator_ = autosaveAccumulator_ - Shared.CLOUD.AUTOSAVE_INTERVAL
        -- 在线玩家的状态随时在变，直接全量回写。
        -- 上限 20 人 × 每 15 秒一次 ≈ 80 次/分钟，远低于云端 300 次/分钟的限制；
        -- 如果以后把 max_players 调到 100 以上，这里要改成只写脏数据。
        local saved = 0
        PlayerSessions.Server.ForEachOnline(function(entry, connection)
            SavePlayer(entry.userId)
            saved = saved + 1
        end)
        if marketDirty_ then
            marketDirty_ = false
            SaveMarket()
        end
        if saved > 0 then
            print(string.format("[Server] 自动存档：%d 名在线玩家", saved))
        end
    end

    -- 贷款计息（独立于加点计时）
    interestAccumulator_ = interestAccumulator_ + timeStep
    if interestAccumulator_ >= Shared.ECONOMY.INTEREST_INTERVAL then
        interestAccumulator_ = interestAccumulator_ - Shared.ECONOMY.INTEREST_INTERVAL
        if ApplyInterest() then
            BroadcastMarket()
        end
    end

    autoPointAccumulator_ = autoPointAccumulator_ + timeStep
    if autoPointAccumulator_ < Shared.AUTO_POINT_INTERVAL then
        return
    end
    local ticks = math.floor(autoPointAccumulator_ / Shared.AUTO_POINT_INTERVAL)
    autoPointAccumulator_ = autoPointAccumulator_ - ticks * Shared.AUTO_POINT_INTERVAL
    if ticks < 1 then
        return
    end

    local dropped = false
    PlayerSessions.Server.ForEachOnline(function(entry, connection)
        entry.state.points = entry.state.points + ticks
        entry.state.totalPoints = entry.state.totalPoints + ticks
        if TryDrop(entry) then
            dropped = true
        end
        connection:SendRemoteEvent(Shared.EVENTS.POINT_UPDATE, true, BuildPointMap(entry))
    end)

    if dropped then
        BroadcastMarket()
    end
end

function Server.Stop()
    PlayerSessions.Server.Shutdown()
end

return Server
