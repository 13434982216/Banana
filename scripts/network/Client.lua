-- 香蕉收集屋 - 客户端
-- 只负责 UI 与输入；市场和仓库的数据全部来自服务端快照，自己不做任何权威计算。
-- 弹幕式交互（点击 +1、积满掉落）保留在本地，但掉落结果由服务端裁定。

local UI = require("urhox-libs/UI")
local Widget = require("urhox-libs/UI/Core/Widget")
local Shared = require("network.Shared")
local PlayerSessions = require("urhox-libs.Network.PlayerSessions")

local Client = {}

local serverConnection_ = nil
local myUserId_ = ""

-- 连接可能晚于脚本加载建立（后台匹配），所以按需取
local function GetConnection()
    if not serverConnection_ then
        serverConnection_ = network:GetServerConnection()
    end
    return serverConnection_
end

-- 玩法数值都在 Shared 里（服务端权威），客户端只保留窗口标题
local CONFIG = {
    title = "香蕉收集屋",
}

-- 深蓝市场风格：深海军蓝底 + 卡片渐变图区 + 金色价格
local THEME = {
    bg = { 8, 16, 32, 255 },
    surface = { 12, 24, 46, 255 },
    surfaceAlt = { 16, 32, 58, 255 },
    card = { 14, 28, 52, 255 },
    cardImageFrom = { 42, 78, 128, 255 },
    cardImageTo = { 10, 22, 44, 255 },
    nav = { 10, 20, 40, 255 },
    text = { 236, 242, 250, 255 },
    textSecondary = { 168, 184, 206, 255 },
    textMuted = { 122, 140, 164, 255 },
    gold = { 242, 196, 64, 255 },
    goldSoft = { 255, 214, 96, 255 },
    ink = { 12, 20, 36, 255 },
    accent = { 88, 196, 246, 255 },
    border = { 32, 54, 86, 255 },
    chartLine = { 242, 196, 64, 255 },
    chartFill = { 242, 196, 64, 42 },
    danger = { 232, 93, 91, 255 },
}

---@class PriceSample
---@field timestamp integer
---@field value number

---@class MarketListing
---@field name string
---@field rarity string
---@field rarityName string
---@field sellerName string
---@field wants integer
---@field stock integer
---@field basePrice number      -- 初始价
---@field highestBid number     -- 当前最高价：只在玩家出价时变化
---@field buyoutPrice number    -- 秒杀价
---@field highestBidder string|nil
---@field sold boolean
---@field priceHistory PriceSample[]

local RARITIES = Shared.RARITIES

---@class GameState
---@field points number
---@field totalClicks number
---@field totalPoints number
---@field totalDrops number
---@field nickname string
---@field avatar string
---@field profileReady boolean
---@field balance number
---@field debt number
---@field assets number
---@field maxLoan number
---@field interestRate number
---@field serviceFeeRate number
---@field leaderboard table[]
---@field inventory table[]
---@field marketListings MarketListing[]
---@field selectedTab string
---@field selectedListing MarketListing|nil
local state = {
    -- 积分是服务端账本的镜像，本地只在点击时做乐观 +1
    points = 0,
    totalClicks = 0,
    totalPoints = 0,
    totalDrops = 0,
    nickname = "",
    avatar = "",
    profileReady = false,
    balance = 0,
    debt = 0,
    assets = 0,
    maxLoan = 0,
    interestRate = 0,
    serviceFeeRate = 0,
    leaderboard = {},
    inventory = {},
    marketListings = {},
    selectedTab = "home",
    selectedListing = nil,
}

---@class UIRefs
---@field trendPlot any
---@field trendChart any
---@field trendYAxis any
---@field trendXAxis any
---@field trendHint any
---@field detailPrice any
---@field detailBidder any
---@field detailBidButton any
---@field detailBuyoutButton any
---@field detailView any
---@field marketView any
---@field marketContent any
---@field inventoryCountLabel any
---@field setupView any
---@field setupNicknameField any
---@field setupErrorLabel any
---@field setupAvatarButtons table<string, any>
---@field detailSellerAvatar any
---@field profileAvatar any
---@field profileName any
---@field profileStats any
---@field leaderboardView any
---@field leaderboardList any
---@field myAssetsValue any
---@field myBalanceValue any
---@field myDebtValue any
---@field navLeaderboard any
---@field myAvatarBig any
---@field myNameBig any
local refs = {}

-- 前向声明：仓库里点商品打开上架弹窗（具体实现在市场逻辑之后）
---@type fun(banana: table)|nil
local OpenListItemDialog = nil

-- 前向声明：余额/净资产显示在排行榜页，RefreshAll 要能刷到它
---@type fun()
local RefreshLeaderboard

-- ============================================================================
-- 动态商品图（Mythic 神话香蕉的眼睛会动）
-- 卡片重建时登记图片面板，由 UpdateAnimatedImages 逐帧换图
-- ============================================================================

---@class AnimatedImageEntry
---@field panel any
---@field rarity table
---@field group string 归属视图，只清理自己那一组

---@type AnimatedImageEntry[]
local animatedImages_ = {}

-- 按视图分组清理：RefreshAll 会连着刷新仓库和市场，
-- 若不分组建模，后刷新的那个会把先登记的清空。
---@param group string
local function ClearAnimatedImages(group)
    local kept = {}
    for _, entry in ipairs(animatedImages_) do
        if entry.group ~= group then
            kept[#kept + 1] = entry
        end
    end
    animatedImages_ = kept
end

---@param panel any
---@param rarity table
---@param group string
local function RegisterAnimatedImage(panel, rarity, group)
    if not panel or not Shared.IsAnimatedRarity(rarity) then
        return
    end
    -- 面板可能被重复登记（重建时换新面板），去重
    for _, entry in ipairs(animatedImages_) do
        if entry.panel == panel then
            entry.rarity = rarity
            entry.group = group
            return
        end
    end
    animatedImages_[#animatedImages_ + 1] = { panel = panel, rarity = rarity, group = group }
end

-- 金额一律精确显示（带千分位，不做 K/M 缩写）
local FormatMoney = Shared.FormatMoney
-- 输入框里的金额不能带千分位，否则 tonumber 解析不了
local FormatAmountInput = Shared.FormatAmountInput
local ParseAmount = Shared.ParseAmount

local GetRarity = Shared.GetRarity
local RoundPrice = Shared.RoundPrice

local function UpdateLabel(label, text)
    if label then
        label:SetText(text)
    end
end

local function GetListingImage(listing)
    return GetRarity(listing.rarity).image
end

-- 市场卡片的图片面板：登记后由动画循环逐帧刷新
---@param listing table
---@return any
local function listingImagePanel(listing)
    local panel = UI.Panel {
        width = "94%",
        height = "100%",
        backgroundImage = GetListingImage(listing),
        backgroundFit = "contain",
    }
    RegisterAnimatedImage(panel, GetRarity(listing.rarity), "market")
    return panel
end

local function UpdateProgress()
    -- 首页大数字是当前进度，掉落后归零，不是累计总分
    local current = math.tointeger(state.points) or 0
    UpdateLabel(refs.totalPointsLabel, string.format("%d/%d", current, Shared.DROP_COST))
end

-- 点击上报：积分账本在服务端，本地先乐观 +1 保证手感，
-- 下一秒服务端推来的权威值会把偏差抹平
local function SendClick()
    if PlayerSessions.Client.IsWaiting() or not state.profileReady then
        return
    end
    local connection = GetConnection()
    if not connection then
        return
    end
    local variantMap = VariantMap()
    variantMap["Clicks"] = Variant(1)
    connection:SendRemoteEvent(Shared.EVENTS.CLICK_REQUEST, true, variantMap)

    state.points = state.points + 1
    state.totalPoints = state.totalPoints + 1
    state.totalClicks = state.totalClicks + 1
    -- 乐观预演：点满就归零，服务端权威值随后覆盖
    if state.points >= Shared.DROP_COST then
        state.points = state.points - Shared.DROP_COST
    end
    UpdateProgress()
end

---@param text string
local function ShowFloatingText(text)
    UpdateLabel(refs.gainLabel, text)
    if refs.gainLabel then
        refs.gainLabel:SetStyle({ opacity = 1, translateY = 0 })
        refs.gainLabel:Animate({
            keyframes = {
                [0] = { opacity = 1, translateY = 0 },
                [1] = { opacity = 0, translateY = -24 },
            },
            duration = 0.65,
            easing = "easeOutCubic",
        })
    end
end

local function ShowGain(amount, source)
    ShowFloatingText("+" .. tostring(amount))
end

-- ============================================================================
-- 音效
-- ============================================================================

---@type Sound|nil
local dropSound_ = nil
---@type SoundSource|nil
local dropSource_ = nil

-- 品质越高音调越高，听起来更"稀有"
local DROP_PITCH = {
    normal = 0.95,
    common = 1.0,
    uncommon = 1.05,
    rare = 1.1,
    epic = 1.16,
    ultra_rare = 1.22,
    legendary = 1.3,
}

---@param scene Scene
local function InitAudio(scene)
    dropSound_ = cache:GetResource("Sound", "audio/sfx/drop.mp3")
    if not dropSound_ then
        print("[Banana] 掉落音效加载失败")
        return
    end
    local node = scene:CreateChild("AudioNode")
    local source = node:CreateComponent("SoundSource")
    if source then
        source:SetSoundType("Effect")
        dropSource_ = source
        print("[Banana] 音效就绪: 掉落音效")
    end
end

---@param rarityKey string
local function PlayDropSound(rarityKey)
    if not dropSource_ or not dropSound_ then
        return
    end
    -- Play 的 frequency 是绝对 Hz，必须乘素材采样率，不能直接传倍率
    local pitch = DROP_PITCH[rarityKey] or 1.0
    dropSource_:Play(dropSound_, dropSound_:GetFrequency() * pitch, 0.8)
end

-- ============================================================================
-- 掉落弹窗（带队列：一次掉多个就一个个弹，不会叠在一起）
-- ============================================================================

---@type string[]
local dropQueue_ = {}
---@type any
local dropModal_ = nil
---@type any
local dropImage_ = nil
---@type any
local dropName_ = nil
---@type any
local dropValue_ = nil
---@type table|nil
local dropCurrentRarity_ = nil

local ShowNextDrop

local function CreateDropModal()
    dropImage_ = UI.Panel {
        width = 116,
        height = 116,
        backgroundGradient = {
            type = "radial",
            from = THEME.cardImageFrom,
            to = THEME.cardImageTo,
        },
        backgroundImage = RARITIES[1].image,
        backgroundFit = "contain",
        borderWidth = 2,
        borderColor = THEME.border,
        borderRadius = 0,
    }
    dropName_ = UI.Label { text = "", width = "100%", fontSize = 18, fontWeight = "bold", fontColor = THEME.text, textAlign = "center" }
    dropValue_ = UI.Label { text = "", width = "100%", fontSize = 13, fontColor = THEME.gold, textAlign = "center" }

    dropModal_ = UI.Modal {
        title = "获得香蕉",
        size = "sm",
        onClose = function(self)
            -- 不销毁，后面还要复用；队里还有就接着弹
            ShowNextDrop()
        end,
    }
    dropModal_:AddContent(UI.Panel {
        width = "100%",
        flexDirection = "column",
        alignItems = "center",
        gap = 12,
        children = {
            dropImage_,
            dropName_,
            dropValue_,
            UI.Button {
                text = "收下",
                width = "100%",
                height = 46,
                fontSize = 15,
                backgroundColor = THEME.gold,
                textColor = THEME.ink,
                borderRadius = 0,
                onClick = function()
                    if dropModal_ then
                        dropModal_:Close()
                    end
                end,
            },
        },
    })
end

ShowNextDrop = function()
    if not dropModal_ then
        return
    end
    if dropModal_:IsOpen() then
        return
    end
    local rarityKey = table.remove(dropQueue_, 1)
    if not rarityKey then
        return
    end
    local rarity = GetRarity(rarityKey)
    dropCurrentRarity_ = rarity
    dropImage_:SetStyle({ backgroundImage = Shared.GetRarityImage(rarity, 1), borderColor = rarity.color })
    dropName_:SetStyle({ fontColor = rarity.color })
    dropName_:SetText(rarity.name)
    dropValue_:SetText("参考价 ¥" .. FormatMoney(rarity.price))
    PlayDropSound(rarityKey)
    dropModal_:Open()
end

---@param rarityKey string
local function EnqueueDrop(rarityKey)
    dropQueue_[#dropQueue_ + 1] = rarityKey
    ShowNextDrop()
end

local function RefreshInventory()
    -- 卡片马上要重建，旧的图片面板作废
    ClearAnimatedImages("inventory")
    if not refs.inventoryGrid then
        return
    end
    refs.inventoryGrid:ClearChildren()

    if #state.inventory == 0 then
        refs.inventoryGrid:AddChild(UI.Panel {
            width = "100%",
            padding = 24,
            alignItems = "center",
            children = {
                UI.Label { text = "还没有香蕉", fontSize = 18, fontColor = THEME.textSecondary },
                UI.Label { text = "点满 60 次即可获得香蕉", fontSize = 13, fontColor = THEME.textMuted, marginTop = 8, textAlign = "center" },
            },
        })
        UpdateLabel(refs.inventoryCountLabel, "0 根")
        return
    end

    local inventoryRows = UI.Panel {
        width = "100%",
        flexDirection = "column",
        gap = 12,
        paddingBottom = 8,
    }
    refs.inventoryGrid:AddChild(inventoryRows)

    for displayIndex = 1, #state.inventory do
        local banana = state.inventory[#state.inventory - displayIndex + 1]
        local rarity = GetRarity(banana.rarity)
        local row = math.floor((displayIndex - 1) / 2) + 1
        local rowPanel = inventoryRows:GetChildAt(row)
        if not rowPanel then
            rowPanel = UI.Panel {
                width = "100%",
                flexDirection = "row",
                gap = 12,
                flexShrink = 1,
            }
            inventoryRows:AddChild(rowPanel)
        end
        local item = UI.Panel {
            flex = 1,
            minWidth = 0,
            height = 178,
            backgroundColor = THEME.card,
            borderRadius = 0,
            borderWidth = 1,
            borderColor = rarity.color,
            overflow = "hidden",
            onClick = function()
                if OpenListItemDialog then
                    OpenListItemDialog(banana)
                end
            end,
        }
        -- 顶部大图区：整卡宽 + 竖向渐变底
        local itemImage = UI.Panel {
            width = "94%",
            height = "100%",
            backgroundImage = Shared.GetRarityImage(rarity, 1),
            backgroundFit = "contain",
            borderRadius = 0,
        }
        RegisterAnimatedImage(itemImage, rarity, "inventory")
        item:AddChild(UI.Panel {
            width = "100%",
            height = 108,
            justifyContent = "center",
            alignItems = "center",
            backgroundGradient = {
                type = "linear",
                direction = "to-bottom",
                from = THEME.cardImageFrom,
                to = THEME.cardImageTo,
            },
            children = { itemImage },
        })
        -- 信息区：商品名 + 价格，左对齐
        item:AddChild(UI.Panel {
            width = "100%",
            flexGrow = 1,
            flexDirection = "column",
            justifyContent = "center",
            gap = 3,
            paddingHorizontal = 10,
            paddingVertical = 6,
            children = {
                UI.Label {
                    text = rarity.name,
                    width = "100%",
                    fontSize = 11,
                    fontWeight = "bold",
                    fontColor = rarity.color,
                    textAlign = "left",
                },
                UI.Label {
                    text = "¥" .. FormatMoney(rarity.price),
                    width = "100%",
                    fontSize = 14,
                    fontWeight = "bold",
                    fontColor = THEME.gold,
                    textAlign = "left",
                },
            },
        })
        rowPanel:AddChild(item)
    end
    if #state.inventory % 2 == 1 then
        local lastRow = inventoryRows:GetChildAt(math.floor((#state.inventory - 1) / 2) + 1)
        if lastRow then
            lastRow:AddChild(UI.Panel { flex = 1, minWidth = 0 })
        end
    end
    UpdateLabel(refs.inventoryCountLabel, tostring(#state.inventory) .. " 根")
end

-- 库存页顶部的个人资料条
local function RefreshProfileStrip()
    if refs.profileAvatar then
        refs.profileAvatar:SetStyle({ backgroundImage = Shared.GetAvatarImage(state.avatar) })
    end
    if refs.profileName then
        refs.profileName:SetText(state.profileReady and state.nickname or "未设置昵称")
    end
    if refs.profileStats then
        refs.profileStats:SetText(string.format("余额 ¥%s · 库存 %d 件 · 净资产 ¥%s",
            FormatMoney(state.balance), #state.inventory, FormatMoney(state.assets)))
    end
end

local TREND_WINDOW = 24 * 3600          -- 曲线窗口：近 24 小时
local TREND_SAMPLE_STEP = 30 * 60       -- 采样粒度：每 30 分钟一个点
local TREND_FINE_WINDOW = 3600          -- 最近 1 小时保留原始采样精度
local TREND_HISTORY_SECONDS = TREND_WINDOW + TREND_FINE_WINDOW

---@class TrendPoint
---@field timestamp integer
---@field value number

local function FormatClock(timestamp)
    return tostring(os.date("%H:%M:%S", timestamp))
end

local function FormatHourMinute(timestamp)
    return tostring(os.date("%H:%M", timestamp))
end

---@param timestamp integer
---@return string
local function FormatObtainedAt(timestamp)
    return tostring(os.date("%m-%d %H:%M", timestamp))
end

local function NowTimestamp()
    return math.tointeger(os.time()) or 0
end

---@param value number
---@return number
local function RoundPrice(value)
    if value >= 100 then
        return math.floor(value + 0.5)
    end
    return math.floor(value * 100 + 0.5) / 100
end

---@param history PriceSample[]
---@param timestamp integer
---@param fallback number
---@return number
local function PriceAtOrBefore(history, timestamp, fallback)
    local value = fallback
    for _, sample in ipairs(history) do
        if sample.timestamp <= timestamp then
            value = sample.value
        else
            break
        end
    end
    return value
end

---@param listing MarketListing|nil
local function GetTrendData(listing)
    local now = NowTimestamp()
    local currentPrice = listing and listing.highestBid or 1
    local history = listing and listing.priceHistory or {}
    local alignedNow = math.tointeger(math.floor(now / TREND_SAMPLE_STEP) * TREND_SAMPLE_STEP) or now
    local windowStart = alignedNow - TREND_WINDOW

    -- 每个采样区间取「最后一笔报价」，即该时刻的市场最高价
    ---@type table<number, number>
    local bucketLast = {}
    for _, sample in ipairs(history) do
        if sample.timestamp >= windowStart and sample.timestamp <= now then
            local bucket = math.tointeger(math.floor(sample.timestamp / TREND_SAMPLE_STEP) * TREND_SAMPLE_STEP) or sample.timestamp
            bucketLast[bucket] = sample.value
        end
    end

    local carry = PriceAtOrBefore(history, windowStart, currentPrice)
    local points = {}
    for timestamp = windowStart, alignedNow, TREND_SAMPLE_STEP do
        local last = bucketLast[timestamp]
        if last then
            carry = last
        end
        points[#points + 1] = { timestamp = timestamp, value = carry }
    end
    if #points == 0 or points[#points].timestamp < now then
        points[#points + 1] = { timestamp = now, value = currentPrice }
    else
        points[#points].value = currentPrice
    end

    local xLabels = {}
    local axisSpan = math.max(1, now - windowStart)
    for step = 0, 4 do
        xLabels[step + 1] = FormatHourMinute(windowStart + math.floor(axisSpan * step / 4))
    end

    return {
        title = "近24小时最高价",
        axisStart = windowStart,
        axisEnd = now,
        points = points,
        xLabels = xLabels,
    }
end

local function BuildAxisLabels(minValue, maxValue, count)
    local labels = {}
    for row = 0, count - 1 do
        local ratio = 1 - row / (count - 1)
        labels[row + 1] = string.format("¥%.1f", minValue + (maxValue - minValue) * ratio)
    end
    return labels
end

---@param alpha number|nil
local function DrawDashedLine(nvg, x1, y1, x2, y2, alpha)
    local dashLength = 6
    local gapLength = 5
    local colorAlpha = alpha or 180
    local dx = x2 - x1
    local dy = y2 - y1
    local length = math.max(1, math.sqrt(dx * dx + dy * dy))
    local nx = dx / length
    local ny = dy / length
    local cursor = 0
    while cursor < length do
        local nextCursor = math.min(cursor + dashLength, length)
        nvgBeginPath(nvg)
        nvgMoveTo(nvg, x1 + nx * cursor, y1 + ny * cursor)
        nvgLineTo(nvg, x1 + nx * nextCursor, y1 + ny * nextCursor)
        nvgStrokeColor(nvg, nvgRGBA(THEME.gold[1], THEME.gold[2], THEME.gold[3], colorAlpha))
        nvgStrokeWidth(nvg, 1)
        nvgStroke(nvg)
        cursor = nextCursor + gapLength
    end
end

local function DrawSelectionOverlay(nvg, l, selectedPoint, selectedValue, timeText)
    if not selectedPoint then
        return
    end

    DrawDashedLine(nvg, selectedPoint.x, l.y, selectedPoint.x, l.y + l.h)
    DrawDashedLine(nvg, l.x, selectedPoint.y, l.x + l.w, selectedPoint.y)

    nvgFontFace(nvg, "sans")
    nvgFontSize(nvg, 10)
    nvgTextAlign(nvg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgBeginPath(nvg)
    nvgRect(nvg, l.x + 2, selectedPoint.y - 9, 48, 18)
    nvgFillColor(nvg, nvgRGBA(THEME.gold[1], THEME.gold[2], THEME.gold[3], 235))
    nvgFill(nvg)
    nvgFillColor(nvg, nvgRGBA(THEME.ink[1], THEME.ink[2], THEME.ink[3], 255))
    nvgText(nvg, l.x + 6, selectedPoint.y, string.format("¥%.1f", selectedValue), nil)

    nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgBeginPath(nvg)
    nvgRect(nvg, selectedPoint.x - 40, l.y + l.h - 20, 80, 18)
    nvgFillColor(nvg, nvgRGBA(THEME.gold[1], THEME.gold[2], THEME.gold[3], 235))
    nvgFill(nvg)
    nvgFillColor(nvg, nvgRGBA(THEME.ink[1], THEME.ink[2], THEME.ink[3], 255))
    nvgText(nvg, selectedPoint.x, l.y + l.h - 11, timeText, nil)

    nvgBeginPath(nvg)
    nvgCircle(nvg, selectedPoint.x, selectedPoint.y, 5)
    nvgFillColor(nvg, nvgRGBA(255, 255, 255, 255))
    nvgFill(nvg)
    nvgBeginPath(nvg)
    nvgCircle(nvg, selectedPoint.x, selectedPoint.y, 2)
    nvgFillColor(nvg, nvgRGBA(THEME.gold[1], THEME.gold[2], THEME.gold[3], 255))
    nvgFill(nvg)
end

---@class TrendChart : Widget
---@field points_ TrendPoint[]
---@field xLabels_ string[]
---@field lineColor_ number[]
---@field fillColor_ number[]
---@field axisStart_ integer
---@field axisEnd_ integer
---@field selectedIndex_ integer|nil
---@field pressing_ boolean
local TrendChart = UI.Widget:Extend("TrendChart")

function TrendChart:Init(props)
    props = props or {}
    props.backgroundColor = false
    props.pointerEvents = "auto"
    Widget.Init(self, props)
    self.points_ = props.points or {}
    self.xLabels_ = props.xLabels or {}
    self.lineColor_ = props.lineColor or THEME.chartLine
    self.fillColor_ = props.fillColor or THEME.chartFill
    self.axisStart_ = props.axisStart or 0
    self.axisEnd_ = props.axisEnd or 1
    self.selectedIndex_ = nil
    self.pressing_ = false
end

---@param points TrendPoint[]
---@param xLabels string[]
function TrendChart:SetData(points, axisStart, axisEnd, xLabels)
    self.points_ = points or {}
    self.axisStart_ = axisStart or self.axisStart_
    self.axisEnd_ = axisEnd or self.axisEnd_
    self.xLabels_ = xLabels or self.xLabels_
    if self.selectedIndex_ and self.selectedIndex_ > #self.points_ then
        self.selectedIndex_ = nil
    end
end

function TrendChart:GetChartMetrics()
    local l = self:GetAbsoluteLayout()
    local paddingLeft = 4
    local paddingRight = 8
    local paddingTop = 8
    local paddingBottom = 8
    return {
        x = l.x,
        y = l.y,
        w = l.w,
        h = l.h,
        left = l.x + paddingLeft,
        top = l.y + paddingTop,
        width = math.max(1, l.w - paddingLeft - paddingRight),
        height = math.max(1, l.h - paddingTop - paddingBottom),
        paddingLeft = paddingLeft,
        paddingRight = paddingRight,
        paddingTop = paddingTop,
        paddingBottom = paddingBottom,
    }
end

function TrendChart:ValueToY(value, metrics, minValue, valueRange)
    return metrics.top + (1 - (value - minValue) / valueRange) * metrics.height
end

function TrendChart:PointX(index, metrics)
    local axisSpan = math.max(1, self.axisEnd_ - self.axisStart_)
    return metrics.left + ((self.points_[index].timestamp - self.axisStart_) / axisSpan) * metrics.width
end

function TrendChart:IndexAtLocalX(localX)
    local metrics = self:GetChartMetrics()
    local axisSpan = math.max(1, self.axisEnd_ - self.axisStart_)
    local ratio = math.max(0, math.min(1, (localX - metrics.paddingLeft) / metrics.width))
    local timestamp = self.axisStart_ + ratio * axisSpan
    local nearest = 1
    local nearestDelta = math.huge
    for index, point in ipairs(self.points_) do
        local delta = math.abs(point.timestamp - timestamp)
        if delta < nearestDelta then
            nearest = index
            nearestDelta = delta
        end
    end
    return nearest
end

function TrendChart:OnPointerDown(event)
    if not event or not event:IsPrimaryAction() or #self.points_ < 1 then
        return
    end
    self.pressing_ = true
    self.selectedIndex_ = self:IndexAtLocalX(event.x)
    event:PreventDefault()
end

function TrendChart:OnPointerMove(event)
    if not event or not self.pressing_ or #self.points_ < 1 then
        return
    end
    self.selectedIndex_ = self:IndexAtLocalX(event.x)
end

function TrendChart:OnPointerUp(event)
    if event and self.pressing_ and #self.points_ >= 1 then
        self.selectedIndex_ = self:IndexAtLocalX(event.x)
    end
    self.pressing_ = false
end

function TrendChart:OnPointerCancel()
    self.pressing_ = false
end

---@param event GestureEvent
---@return boolean
function TrendChart:OnPanStart(event)
    self.pressing_ = true
    if #self.points_ >= 1 then
        self.selectedIndex_ = self:IndexAtLocalX(event.x)
    end
    return true
end

---@param event GestureEvent
function TrendChart:OnPanMove(event)
    if not self.pressing_ or #self.points_ < 1 then
        return
    end
    self.selectedIndex_ = self:IndexAtLocalX(event.x)
end

---@param event GestureEvent
function TrendChart:OnPanEnd(event)
    if self.pressing_ and #self.points_ >= 1 then
        self.selectedIndex_ = self:IndexAtLocalX(event.x)
    end
    self.pressing_ = false
end

function TrendChart:Render(nvg)
    local metrics = self:GetChartMetrics()
    local points = self.points_
    if #points < 1 or metrics.w <= 0 or metrics.h <= 0 then
        return
    end

    local minValue = math.huge
    local maxValue = -math.huge
    for _, point in ipairs(points) do
        minValue = math.min(minValue, point.value)
        maxValue = math.max(maxValue, point.value)
    end
    if maxValue - minValue < 0.01 then
        local pad = math.max(0.5, minValue * 0.002)
        minValue = minValue - pad
        maxValue = maxValue + pad
    end
    local valueRange = math.max(0.01, maxValue - minValue)

    nvgSave(nvg)
    nvgIntersectScissor(nvg, metrics.x, metrics.y, metrics.w, metrics.h)

    local drawPoints = {}
    for index, point in ipairs(points) do
        drawPoints[index] = {
            x = self:PointX(index, metrics),
            y = self:ValueToY(point.value, metrics, minValue, valueRange),
        }
    end

    if #drawPoints >= 2 then
        nvgBeginPath(nvg)
        nvgMoveTo(nvg, drawPoints[1].x, drawPoints[1].y)
        for index = 2, #drawPoints do
            nvgLineTo(nvg, drawPoints[index].x, drawPoints[index].y)
        end
        nvgLineTo(nvg, drawPoints[#drawPoints].x, metrics.y + metrics.h)
        nvgLineTo(nvg, drawPoints[1].x, metrics.y + metrics.h)
        nvgClosePath(nvg)
        nvgFillColor(nvg, nvgRGBA(self.fillColor_[1], self.fillColor_[2], self.fillColor_[3], self.fillColor_[4] or 50))
        nvgFill(nvg)

        nvgBeginPath(nvg)
        nvgMoveTo(nvg, drawPoints[1].x, drawPoints[1].y)
        for index = 2, #drawPoints do
            nvgLineTo(nvg, drawPoints[index].x, drawPoints[index].y)
        end
        nvgStrokeColor(nvg, nvgRGBA(self.lineColor_[1], self.lineColor_[2], self.lineColor_[3], self.lineColor_[4] or 255))
        nvgStrokeWidth(nvg, 2.0)
        nvgLineJoin(nvg, NVG_ROUND)
        nvgStroke(nvg)

        -- 采样点标记：点太密时按间隔抽稀，保证看得清
        local markerStep = math.max(1, math.tointeger(math.floor(#drawPoints / 12)) or 1)
        for index = 1, #drawPoints, markerStep do
            nvgBeginPath(nvg)
            nvgCircle(nvg, drawPoints[index].x, drawPoints[index].y, 2)
            nvgFillColor(nvg, nvgRGBA(255, 255, 255, 220))
            nvgFill(nvg)
        end
    end

    local lastPoint = drawPoints[#drawPoints]
    local lastValue = points[#points].value

    -- 当前价参考线：让人一眼定位「现在」这条价格在哪
    DrawDashedLine(nvg, metrics.left, lastPoint.y, metrics.left + metrics.width, lastPoint.y, 90)

    nvgBeginPath(nvg)
    nvgCircle(nvg, lastPoint.x, lastPoint.y, 5)
    nvgFillColor(nvg, nvgRGBA(255, 255, 255, 255))
    nvgFill(nvg)
    nvgBeginPath(nvg)
    nvgCircle(nvg, lastPoint.x, lastPoint.y, 3)
    nvgFillColor(nvg, nvgRGBA(self.lineColor_[1], self.lineColor_[2], self.lineColor_[3], 255))
    nvgFill(nvg)

    -- 当前时刻的价格标签，贴在右端（最新时间点）
    local tagText = "¥" .. FormatMoney(lastValue)
    local tagWidth = math.max(44, #tagText * 6 + 12)
    local tagHeight = 16
    local tagX = metrics.left + metrics.width - tagWidth - 8
    local tagY = math.max(metrics.top, math.min(metrics.top + metrics.height - tagHeight, lastPoint.y - tagHeight / 2))
    nvgBeginPath(nvg)
    nvgRect(nvg, tagX, tagY, tagWidth, tagHeight)
    nvgFillColor(nvg, nvgRGBA(THEME.gold[1], THEME.gold[2], THEME.gold[3], 235))
    nvgFill(nvg)
    nvgFontFace(nvg, "sans")
    nvgFontSize(nvg, 10)
    nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(nvg, nvgRGBA(THEME.ink[1], THEME.ink[2], THEME.ink[3], 255))
    nvgText(nvg, tagX + tagWidth / 2, tagY + tagHeight / 2, tagText, nil)

    if self.selectedIndex_ then
        local selected = points[self.selectedIndex_]
        if selected then
            local selectedPoint = {
                x = self:PointX(self.selectedIndex_, metrics),
                y = self:ValueToY(selected.value, metrics, minValue, valueRange),
            }
            DrawSelectionOverlay(nvg, metrics, selectedPoint, selected.value, FormatClock(selected.timestamp))
        end
    end
    nvgRestore(nvg)
end

local function RefreshTrendXAxis(labels)
    if not refs.trendXAxis then
        return
    end
    refs.trendXAxis:ClearChildren()
    for index, label in ipairs(labels) do
        refs.trendXAxis:AddChild(UI.Label {
            text = label,
            flex = 1,
            fontSize = 9,
            fontColor = THEME.textMuted,
            textAlign = index == 1 and "left" or (index == #labels and "right" or "center"),
        })
    end
end

local function RefreshTrendYAxis(minValue, maxValue)
    if not refs.trendYAxis then
        return
    end
    refs.trendYAxis:ClearChildren()
    local yLabels = BuildAxisLabels(minValue, maxValue, 7)
    for _, label in ipairs(yLabels) do
        refs.trendYAxis:AddChild(UI.Label {
            text = label,
            width = "100%",
            height = 14,
            fontSize = 9,
            fontColor = THEME.textMuted,
            textAlign = "right",
        })
    end
end

local function GetTrendValueRange(trendData)
    local minValue = math.huge
    local maxValue = -math.huge
    for _, point in ipairs(trendData.points) do
        minValue = math.min(minValue, point.value)
        maxValue = math.max(maxValue, point.value)
    end
    if minValue == math.huge then
        return 0, 1
    end
    if maxValue <= minValue then
        local pad = math.max(0.5, minValue * 0.002)
        return minValue - pad, maxValue + pad
    end
    return minValue, maxValue
end

---@param reuse boolean|nil
local function RefreshTrendChart(reuse)
    if not refs.trendPlot then
        return
    end

    local trendData = GetTrendData(state.selectedListing)
    local minValue, maxValue = GetTrendValueRange(trendData)

    if reuse == true and refs.trendChart then
        refs.trendChart:SetData(trendData.points, trendData.axisStart, trendData.axisEnd, trendData.xLabels)
        RefreshTrendYAxis(minValue, maxValue)
        RefreshTrendXAxis(trendData.xLabels)
        return
    end

    refs.trendPlot:ClearChildren()

    local grid = UI.Panel {
        position = "absolute",
        left = 48,
        right = 8,
        top = 0,
        height = 224,
        backgroundColor = { 10, 22, 42, 255 },
        borderRadius = 0,
        overflow = "hidden",
    }
    for row = 0, 4 do
        grid:AddChild(UI.Panel {
            position = "absolute",
            left = 0,
            top = 10 + row * 47,
            width = "100%",
            height = 1,
            backgroundColor = { 32, 54, 86, 160 },
        })
    end
    for column = 0, 5 do
        grid:AddChild(UI.Panel {
            position = "absolute",
            left = (column * 20) .. "%",
            top = 0,
            width = 1,
            height = "100%",
            backgroundColor = { 32, 54, 86, 90 },
        })
    end

    refs.trendChart = TrendChart {
        id = "trendChart",
        position = "absolute",
        left = 0,
        top = 0,
        width = "100%",
        height = 224,
        points = trendData.points,
        xLabels = trendData.xLabels,
        axisStart = trendData.axisStart,
        axisEnd = trendData.axisEnd,
        lineColor = THEME.chartLine,
        fillColor = THEME.chartFill,
    }
    grid:AddChild(refs.trendChart)
    refs.trendPlot:AddChild(grid)

    refs.trendYAxis = UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        width = 46,
        height = 224,
        justifyContent = "space-between",
        paddingVertical = 2,
        pointerEvents = "none",
    }
    RefreshTrendYAxis(minValue, maxValue)
    refs.trendPlot:AddChild(refs.trendYAxis)

    refs.trendXAxis = UI.Panel {
        position = "absolute",
        left = 48,
        right = 8,
        top = 224,
        height = 24,
        flexDirection = "row",
        justifyContent = "space-between",
        paddingTop = 7,
        pointerEvents = "none",
    }
    RefreshTrendXAxis(trendData.xLabels)
    refs.trendPlot:AddChild(refs.trendXAxis)

    if refs.trendHint then
        refs.trendHint:SetText("近 24 小时 · 出价即记录一个价格点")
    end
    print(string.format("[Market] 趋势图刷新: %s, 采样点=%d, 当前最高价=¥%.2f", trendData.title, #trendData.points, state.selectedListing and state.selectedListing.highestBid or 0))
end

local function CreateTrendChart()
    local chart = UI.Panel {
        width = "100%",
        height = 348,
        marginTop = 12,
        padding = 12,
        backgroundColor = THEME.card,
        borderWidth = 1,
        borderColor = THEME.border,
        borderRadius = 0,
        overflow = "hidden",
    }

    local chartHeader = UI.Panel {
        width = "100%",
        height = 38,
        flexDirection = "row",
        alignItems = "center",
        justifyContent = "space-between",
        marginBottom = 8,
    }
    chartHeader:AddChild(UI.Label { text = "价格走势", fontSize = 18, fontColor = THEME.text })
    chartHeader:AddChild(UI.Label { text = "按市场最高价", fontSize = 11, fontColor = THEME.textMuted })
    chart:AddChild(chartHeader)

    refs.trendPlot = UI.Panel {
        width = "100%",
        flexGrow = 1,
        flexShrink = 1,
    }
    chart:AddChild(refs.trendPlot)
    refs.trendHint = UI.Label {
        text = "近 24 小时 · 出价即记录一个价格点",
        width = "100%",
        height = 16,
        fontSize = 10,
        fontColor = THEME.textMuted,
        textAlign = "center",
        marginTop = 2,
    }
    chart:AddChild(refs.trendHint)
    RefreshTrendChart()
    return chart
end

local function SetDetailProductImage(listing)
    if not refs.detailProductImage then
        return
    end
    refs.detailProductImage:SetStyle({ backgroundImage = Shared.GetRarityImage(GetRarity(listing.rarity), 1) })
end

---@param listing MarketListing
local function RefreshDetailActions(listing)
    if refs.detailPrice then
        refs.detailPrice:SetText("¥" .. FormatMoney(listing.highestBid))
    end
    if refs.detailBidder then
        if listing.sold then
            refs.detailBidder:SetText("已成交 · 秒杀价 ¥" .. FormatMoney(listing.buyoutPrice))
        elseif listing.highestBidder then
            refs.detailBidder:SetText("最高出价人: " .. listing.highestBidder)
        else
            refs.detailBidder:SetText("暂无出价 · 秒杀价 ¥" .. FormatMoney(listing.buyoutPrice))
        end
    end
    local reachedBuyout = listing.highestBid >= listing.buyoutPrice
    if refs.detailBidButton then
        refs.detailBidButton:SetDisabled(listing.sold or reachedBuyout)
    end
    if refs.detailBuyoutButton then
        refs.detailBuyoutButton:SetDisabled(listing.sold)
        refs.detailBuyoutButton:SetText(listing.sold and "已成交" or ("秒杀 ¥" .. FormatMoney(listing.buyoutPrice)))
    end
end

local function ShowListingDetail(listing)
    state.selectedListing = listing
    if refs.marketView then refs.marketView:SetVisible(false) end
    if refs.detailView then refs.detailView:SetVisible(true) end
    SetDetailProductImage(listing)
    local currentRarity = GetRarity(listing.rarity)
    if refs.detailRarity then
        refs.detailRarity:SetStyle({ fontColor = currentRarity.color })
        refs.detailRarity:SetText(listing.rarityName)
    end
    if refs.detailTopTitle then refs.detailTopTitle:SetText("商品详情") end
    if refs.detailTitle then refs.detailTitle:SetText(listing.name or ("香蕉 · " .. listing.sellerName)) end
    if refs.detailRarity then refs.detailRarity:SetText(listing.rarityName) end
    if refs.detailDemand then refs.detailDemand:SetText("在售: " .. tostring(listing.stock or listing.wants)) end
    if refs.detailSellerName then refs.detailSellerName:SetText(listing.sellerName) end
    if refs.detailSellerAvatar then
        refs.detailSellerAvatar:SetStyle({ backgroundImage = Shared.GetAvatarImage(listing.sellerAvatar or "") })
    end
    RefreshDetailActions(listing)
    RefreshTrendChart()
    print("[Market] 打开商品详情: " .. listing.sellerName)
end

local function CloseListingDetail()
    state.selectedListing = nil
    refs.trendChart = nil
    if refs.detailView then refs.detailView:SetVisible(false) end
    if refs.marketView then refs.marketView:SetVisible(true) end
end

local function RefreshMarket()
    ClearAnimatedImages("market")
    if not refs.marketContent then
        return
    end
    refs.marketContent:ClearChildren()

    local marketGrid = UI.SimpleGrid {
        width = "100%",
        columns = 2,
        gap = 12,
        paddingBottom = 8,
    }
    refs.marketContent:AddChild(marketGrid)

    if #state.marketListings == 0 then
        refs.marketContent:AddChild(UI.Panel {
            width = "100%",
            padding = 24,
            alignItems = "center",
            children = {
                UI.Label { text = "市场暂无在售商品", fontSize = 16, fontColor = THEME.textSecondary },
                UI.Label { text = "到库存里点商品即可上架", fontSize = 12, fontColor = THEME.textMuted, marginTop = 8, textAlign = "center" },
            },
        })
    end

    for _, listing in ipairs(state.marketListings) do
        local rarity = GetRarity(listing.rarity)
        local card = UI.Panel {
            width = "100%",
            height = 284,
            backgroundColor = THEME.card,
            borderRadius = 0,
            overflow = "hidden",
            onClick = function()
                ShowListingDetail(listing)
            end,
        }
        -- 顶部大图区：整卡宽 + 竖向渐变底
        card:AddChild(UI.Panel {
            width = "100%",
            height = 180,
            justifyContent = "center",
            alignItems = "center",
            backgroundGradient = {
                type = "linear",
                direction = "to-bottom",
                from = THEME.cardImageFrom,
                to = THEME.cardImageTo,
            },
            children = {
                listingImagePanel(listing),
            },
        })
        local info = UI.Panel {
            width = "100%",
            height = 104,
            position = "relative",
            paddingHorizontal = 14,
            paddingTop = 10,
            paddingBottom = 12,
            backgroundColor = THEME.card,
        }
        info:AddChild(UI.Label {
            text = listing.name or rarity.name,
            width = "100%",
            height = 22,
            fontSize = 16,
            fontWeight = "bold",
            fontColor = THEME.text,
            textAlign = "left",
        })
        local priceBlock = UI.Panel {
            position = "absolute",
            left = 14,
            bottom = 12,
            flexDirection = "row",
            alignItems = "flex-end",
            gap = 2,
        }
        priceBlock:AddChild(UI.Label { text = "¥", fontSize = 13, fontColor = THEME.gold, marginBottom = 1 })
        local priceLabel = UI.Label {
            text = listing.sold and "已成交" or FormatMoney(listing.highestBid),
            fontSize = 22,
            fontWeight = "bold",
            fontColor = listing.sold and THEME.textMuted or THEME.gold,
        }
        priceBlock:AddChild(priceLabel)
        info:AddChild(priceBlock)
        info:AddChild(UI.Label {
            text = listing.sold and "已成交" or ("秒杀 ¥" .. FormatMoney(listing.buyoutPrice)),
            position = "absolute",
            right = 14,
            bottom = 14,
            fontSize = 12,
            fontColor = listing.sold and THEME.textMuted or THEME.textSecondary,
            textAlign = "right",
        })
        card:AddChild(info)
        marketGrid:AddChild(card)
    end
end

---@param banana table
---@param price number
---@param buyoutPrice number
local function ListInventoryItem(banana, price, buyoutPrice)
    -- 上架由服务端执行：校验、从仓库扣除、写入市场都在那边完成
    local connection = GetConnection()
    if not connection then
        return
    end
    local variantMap = VariantMap()
    variantMap["ItemId"] = Variant(banana.id)
    variantMap["Price"] = Variant(price)
    variantMap["Buyout"] = Variant(buyoutPrice)
    connection:SendRemoteEvent(Shared.EVENTS.LIST_REQUEST, true, variantMap)
    print(string.format("[Market] 请求上架 #%d 起始价¥%s 秒杀价¥%s",
        banana.id, FormatMoney(price), FormatMoney(buyoutPrice)))
end

---@param banana table
---@param banana table
local function SellToSystem(banana)
    -- 一口价卖给官方：服务端扣商品 + 余额入账
    local connection = GetConnection()
    if not connection then
        return
    end
    local variantMap = VariantMap()
    variantMap["ItemId"] = Variant(banana.id)
    connection:SendRemoteEvent(Shared.EVENTS.SELL_REQUEST, true, variantMap)
    print(string.format("[Market] 请求卖给官方 #%d", banana.id))
end

---@param banana table
OpenListItemDialog = function(banana)
    local rarity = GetRarity(banana.rarity)
    local canList = Shared.CanListItem(banana.rarity)
    ---@type any
    local modal = nil
    local errorLabel = UI.Label { text = "", width = "100%", fontSize = 11, fontColor = THEME.danger }
    local priceField = UI.TextField { width = "100%", height = 40, fontSize = 14, placeholder = "起始价" }
    local buyoutField = UI.TextField { width = "100%", height = 40, fontSize = 14, placeholder = "秒杀价" }
    priceField:SetValue(FormatAmountInput(rarity.price))
    buyoutField:SetValue(FormatAmountInput(RoundPrice(rarity.price * 1.25)))

    local function Confirm()
        local price = ParseAmount(priceField:GetValue())
        local buyout = ParseAmount(buyoutField:GetValue())
        if not price or price <= 0 then
            errorLabel:SetText("请输入有效的起始价")
            return
        end
        if not buyout or buyout <= price then
            errorLabel:SetText("秒杀价需要高于起始价")
            return
        end
        ListInventoryItem(banana, RoundPrice(price), RoundPrice(buyout))
        if modal then
            modal:Close()
        end
    end

    -- 商品信息卡片，两种流程共用
    local itemCard = UI.Panel {
        width = "100%",
        flexDirection = "row",
        alignItems = "center",
        gap = 12,
        padding = 10,
        backgroundColor = THEME.card,
        borderWidth = 1,
        borderColor = rarity.color,
        borderRadius = 0,
        overflow = "hidden",
        children = {
            UI.Panel {
                width = 64,
                height = 64,
                backgroundGradient = {
                    type = "radial",
                    from = THEME.cardImageFrom,
                    to = THEME.cardImageTo,
                },
                backgroundImage = rarity.image,
                backgroundFit = "contain",
                borderRadius = 0,
            },
            UI.Panel {
                flexGrow = 1,
                flexShrink = 1,
                flexDirection = "column",
                gap = 3,
                children = {
                    UI.Label { text = rarity.name, width = "100%", fontSize = 16, fontWeight = "bold", fontColor = rarity.color },
                    UI.Label { text = "默认价 ¥" .. FormatMoney(rarity.price), width = "100%", fontSize = 12, fontColor = THEME.gold },
                    UI.Label { text = "获得于 " .. FormatObtainedAt(banana.obtainedAt), width = "100%", fontSize = 10, fontColor = THEME.textMuted },
                },
            },
            UI.Label { text = "#" .. tostring(banana.id), fontSize = 11, fontColor = THEME.textMuted },
        },
    }

    ---@type any
    local body = nil
    ---@type table
    local footerChildren = nil

    if canList then
        body = UI.Panel {
            width = "100%",
            flexDirection = "column",
            gap = 8,
            children = {
                itemCard,
                UI.Label { text = "起始价", width = "100%", fontSize = 12, fontColor = THEME.textMuted, marginTop = 4 },
                priceField,
                UI.Label { text = "秒杀价", width = "100%", fontSize = 12, fontColor = THEME.textMuted },
                buyoutField,
                errorLabel,
            },
        }
        footerChildren = {
            UI.Button {
                text = "取消",
                width = 88,
                height = 40,
                fontSize = 14,
                backgroundColor = THEME.surfaceAlt,
                textColor = THEME.text,
                borderRadius = 0,
                onClick = function()
                    if modal then
                        modal:Close()
                    end
                end,
            },
            UI.Button {
                text = "上架",
                width = 88,
                height = 40,
                fontSize = 14,
                backgroundColor = THEME.gold,
                textColor = THEME.ink,
                borderRadius = 0,
                onClick = Confirm,
            },
        }
    else
        local sellPrice = Shared.SystemBuyPrice(banana.rarity)
        body = UI.Panel {
            width = "100%",
            flexDirection = "column",
            gap = 10,
            children = {
                itemCard,
                UI.Label {
                    text = "普通香蕉不支持挂单，可直接卖给官方回收",
                    width = "100%",
                    fontSize = 12,
                    fontColor = THEME.textMuted,
                    marginTop = 4,
                },
                UI.Label {
                    text = "回收价 ¥" .. FormatMoney(sellPrice),
                    width = "100%",
                    fontSize = 20,
                    fontWeight = "bold",
                    fontColor = THEME.gold,
                    textAlign = "center",
                },
                errorLabel,
            },
        }
        footerChildren = {
            UI.Button {
                text = "取消",
                width = 88,
                height = 40,
                fontSize = 14,
                backgroundColor = THEME.surfaceAlt,
                textColor = THEME.text,
                borderRadius = 0,
                onClick = function()
                    if modal then
                        modal:Close()
                    end
                end,
            },
            UI.Button {
                text = "卖给官方",
                width = 100,
                height = 40,
                fontSize = 14,
                backgroundColor = THEME.gold,
                textColor = THEME.ink,
                borderRadius = 0,
                onClick = function()
                    SellToSystem(banana)
                    if modal then
                        modal:Close()
                    end
                end,
            },
        }
    end

    modal = UI.Modal {
        title = canList and "上架商品" or "处理商品",
        size = "md",
        onClose = function(self)
            self:Destroy()
        end,
    }
    modal:AddContent(body)
    modal:SetFooter(UI.Panel {
        width = "100%",
        flexDirection = "row",
        justifyContent = "flex-end",
        gap = 8,
        children = footerChildren,
    })
    modal:Open()
end


---@param listing MarketListing
---@param amount number
local function PlaceBid(listing, amount)
    local connection = GetConnection()
    if not connection then
        return
    end
    local variantMap = VariantMap()
    variantMap["ListingId"] = Variant(listing.id)
    variantMap["Amount"] = Variant(amount)
    connection:SendRemoteEvent(Shared.EVENTS.BID_REQUEST, true, variantMap)
    print(string.format("[Market] 请求出价 挂单#%d ¥%s", listing.id, FormatMoney(amount)))
end

---@param listing MarketListing
local function BuyoutListing(listing)
    local connection = GetConnection()
    if not connection then
        return
    end
    local variantMap = VariantMap()
    variantMap["ListingId"] = Variant(listing.id)
    connection:SendRemoteEvent(Shared.EVENTS.BUYOUT_REQUEST, true, variantMap)
    print(string.format("[Market] 请求秒杀 挂单#%d ¥%s", listing.id, FormatMoney(listing.buyoutPrice)))
end

---@param listing MarketListing
local function OpenBidDialog(listing)
    local current = listing.highestBid
    local ceiling = listing.buyoutPrice
    ---@type any
    local modal = nil
    local options = UI.Panel { width = "100%", flexDirection = "column", gap = 8 }
    for _, rate in ipairs({ 0.02, 0.05, 0.10 }) do
        local amount = RoundPrice(math.min(current * (1 + rate), ceiling))
        if amount > current then
            options:AddChild(UI.Button {
                text = string.format("加价 %d%%   ¥%s", math.floor(rate * 100 + 0.5), FormatMoney(amount)),
                width = "100%",
                height = 44,
                fontSize = 14,
                backgroundColor = THEME.surfaceAlt,
                textColor = THEME.text,
                borderRadius = 0,
                onClick = function()
                    PlaceBid(listing, amount)
                    if modal then
                        modal:Close()
                    end
                end,
            })
        end
    end
    modal = UI.Modal {
        title = "出价",
        size = "sm",
        onClose = function(self)
            self:Destroy()
        end,
    }
    modal:AddContent(UI.Panel {
        width = "100%",
        flexDirection = "column",
        gap = 10,
        children = {
            UI.Label { text = "当前最高价 ¥" .. FormatMoney(current), fontSize = 14, fontColor = THEME.text },
            UI.Label { text = "秒杀价 ¥" .. FormatMoney(ceiling), fontSize = 13, fontColor = THEME.gold },
            UI.Label { text = "出价后立即成为最高价，无人秒杀则价格随之上涨", fontSize = 11, fontColor = THEME.textMuted },
            options,
        },
    })
    modal:Open()
end

local function CreateDetailView()
    refs.detailView = UI.Panel {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        flexShrink = 1,
        visible = false,
        paddingTop = 14,
        overflow = "hidden",
    }

    local detailTop = UI.Panel { width = "100%", flexDirection = "row", alignItems = "center", gap = 10, marginBottom = 12 }
    detailTop:AddChild(UI.Button {
        text = "返回",
        width = 58,
        height = 38,
        fontSize = 12,
        padding = 0,
        backgroundColor = THEME.surfaceAlt,
        textColor = THEME.text,
        borderRadius = 0,
        onClick = CloseListingDetail,
    })
    refs.detailTopTitle = UI.Label { text = "商品详情", flexGrow = 1, fontSize = 20, fontColor = THEME.text }
    detailTop:AddChild(refs.detailTopTitle)
    refs.detailView:AddChild(detailTop)
    local detailInfo = UI.Panel {
        width = "100%",
        height = 250,
        padding = 14,
        backgroundColor = THEME.card,
        borderWidth = 1,
        borderColor = THEME.border,
        borderRadius = 0,
        overflow = "hidden",
    }
    detailInfo:AddChild(UI.Label { text = "BANANA MARKET", fontSize = 12, fontColor = THEME.textMuted, marginBottom = 8 })
    local infoRow = UI.Panel { width = "100%", flexDirection = "row", gap = 14, alignItems = "center" }
    refs.detailProductImage = UI.Panel {
        width = 138,
        height = 112,
        backgroundGradient = {
            type = "radial",
            from = THEME.cardImageFrom,
            to = THEME.cardImageTo,
        },
        backgroundImage = "image/banana_normal_20260904085931.png",
        backgroundFit = "contain",
        borderRadius = 0,
    }
    infoRow:AddChild(refs.detailProductImage)
    local detailMeta = UI.Panel { flexGrow = 1, flexShrink = 1, gap = 6 }
    refs.detailTitle = UI.Label { text = "香蕉商品", fontSize = 20, fontColor = THEME.text }
    refs.detailRarity = UI.Label { text = "品质", fontSize = 14, fontColor = THEME.textSecondary }
    refs.detailPrice = UI.Label { text = "¥0", fontSize = 26, fontWeight = "bold", fontColor = THEME.gold }
    refs.detailDemand = UI.Label { text = "在售: 0", fontSize = 13, fontColor = THEME.textSecondary }
    refs.detailBidder = UI.Label { text = "暂无出价", fontSize = 12, fontColor = THEME.textMuted }
    detailMeta:AddChild(refs.detailTitle)
    detailMeta:AddChild(refs.detailRarity)
    detailMeta:AddChild(refs.detailPrice)
    detailMeta:AddChild(refs.detailDemand)
    detailMeta:AddChild(refs.detailBidder)
    infoRow:AddChild(detailMeta)
    detailInfo:AddChild(infoRow)
    refs.detailView:AddChild(detailInfo)

    local sellerRow = UI.Panel { width = "100%", height = 74, flexDirection = "row", alignItems = "center", gap = 10, paddingVertical = 10 }
    refs.detailSellerAvatar = UI.Panel {
        width = 44,
        height = 44,
        backgroundColor = THEME.surfaceAlt,
        backgroundImage = Shared.GetAvatarImage(state.avatar),
        backgroundFit = "cover",
        borderRadius = 22,
        overflow = "hidden",
    }
    sellerRow:AddChild(refs.detailSellerAvatar)
    refs.detailSellerName = UI.Label { text = "卖家", fontSize = 15, fontColor = THEME.text }
    sellerRow:AddChild(refs.detailSellerName)
    sellerRow:AddChild(UI.Label { text = "在线卖家", fontSize = 12, fontColor = THEME.textMuted, marginLeft = "auto" })
    refs.detailView:AddChild(sellerRow)

    refs.detailView:AddChild(CreateTrendChart())
    local actionRow = UI.Panel { width = "100%", flexDirection = "row", gap = 10, marginTop = 10 }
    refs.detailBidButton = UI.Button {
        text = "出价",
        flex = 1,
        height = 48,
        fontSize = 16,
        backgroundColor = THEME.surfaceAlt,
        textColor = THEME.text,
        borderRadius = 0,
        onClick = function()
            if state.selectedListing then
                OpenBidDialog(state.selectedListing)
            end
        end,
    }
    refs.detailBuyoutButton = UI.Button {
        text = "秒杀",
        flex = 1,
        height = 48,
        fontSize = 16,
        backgroundColor = THEME.gold,
        textColor = THEME.ink,
        borderRadius = 0,
        onClick = function()
            if state.selectedListing then
                BuyoutListing(state.selectedListing)
            end
        end,
    }
    actionRow:AddChild(refs.detailBidButton)
    actionRow:AddChild(refs.detailBuyoutButton)
    refs.detailView:AddChild(actionRow)
    return refs.detailView
end

local function RefreshAll()
    UpdateProgress()
    RefreshInventory()
    RefreshMarket()
    -- 余额/负债/净资产都在排行榜页，这里不刷就会一直是旧值
    RefreshLeaderboard()
end

local function UpdateNavStyle()
    local buttons = {
        { btn = refs.navHome, tab = "home" },
        { btn = refs.navInventory, tab = "inventory" },
        { btn = refs.navMarket, tab = "market" },
        { btn = refs.navLeaderboard, tab = "leaderboard" },
    }
    for _, item in ipairs(buttons) do
        if item.btn then
            local active = state.selectedTab == item.tab
            item.btn:SetStyle({
                backgroundColor = active and THEME.gold or THEME.surfaceAlt,
                textColor = active and THEME.ink or THEME.text,
                borderRadius = 0,
            })
        end
    end
end

local function SwitchTab(tab)
    state.selectedTab = tab
    state.selectedListing = nil
    refs.trendChart = nil
    if refs.homeView then refs.homeView:SetVisible(tab == "home") end
    if refs.inventoryView then refs.inventoryView:SetVisible(tab == "inventory") end
    if refs.marketView then refs.marketView:SetVisible(tab == "market") end
    if refs.leaderboardView then refs.leaderboardView:SetVisible(tab == "leaderboard") end
    if refs.detailView then refs.detailView:SetVisible(false) end

    if refs.statsBar then
        refs.statsBar:SetVisible(tab == "home")
    end
    UpdateNavStyle()
    UpdateLabel(refs.totalPointsLabel, "")
    UpdateProgress()
    print("[Navigation] 切换页面: " .. tab)
end

local function CreateStatsBar()
    local stats = UI.Panel {
        width = "100%",
        minHeight = 64,
        alignItems = "center",
        marginTop = 18,
        backgroundColor = false,
    }
    refs.statsBar = stats
    refs.totalPointsLabel = UI.Label { text = "", fontSize = 56, fontColor = THEME.text, fontWeight = "bold", textAlign = "center" }
    stats:AddChild(refs.totalPointsLabel)
    stats:SetVisible(state.selectedTab == "home")
    return stats
end

local function CreateHomeView()
    refs.homeView = UI.Panel {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        flexShrink = 1,
        alignItems = "center",
        paddingTop = 34,
    }

    local bananaImage = nil
    local bananaStage = UI.Panel {
        width = "100%",
        maxWidth = 410,
        aspectRatio = 1,
        position = "relative",
        alignItems = "center",
        justifyContent = "center",
        backgroundColor = false,
        onClick = function()
            SendClick()
            ShowGain(1, "手动")
            bananaImage:SetStyle({ scale = 0.94 })
            bananaImage:Animate({
                keyframes = {
                    [0] = { scale = 0.94 },
                    [1] = { scale = 1.0 },
                },
                duration = 0.12,
                easing = "easeOutCubic",
            })
            print("[Banana] 玩家点击 +1")
        end,
    }
    bananaImage = UI.Panel {
        width = "72%",
        maxWidth = 280,
        maxHeight = 280,
        aspectRatio = 1,
        backgroundGradient = {
            type = "radial",
            from = THEME.cardImageFrom,
            to = { 8, 16, 32, 0 },
        },
        backgroundImage = RARITIES[1].image,
        backgroundFit = "contain",
    }
    bananaStage:AddChild(bananaImage)

    refs.gainLabel = UI.Label {
        text = "",
        position = "absolute",
        top = "8%",
        left = 0,
        width = "100%",
        textAlign = "center",
        fontSize = 42,
        fontWeight = "bold",
        fontColor = THEME.gold,
        opacity = 0,
        pointerEvents = "none",
        zIndex = 2,
    }
    bananaStage:AddChild(refs.gainLabel)
    refs.homeView:AddChild(bananaStage)
    return refs.homeView
end

local function CreateInventoryView()
    refs.inventoryView = UI.Panel {
        width = "100%",
        flexBasis = 0,
        flexGrow = 1,
        flexShrink = 1,
        visible = false,
        paddingTop = 14,
    }
    refs.profileAvatar = UI.Panel {
        width = 48,
        height = 48,
        borderRadius = 24,
        overflow = "hidden",
        backgroundColor = THEME.surfaceAlt,
        backgroundImage = Shared.GetAvatarImage(state.avatar),
        backgroundFit = "cover",
    }
    refs.profileName = UI.Label { text = "未设置昵称", fontSize = 16, fontWeight = "bold", fontColor = THEME.text }
    refs.profileStats = UI.Label { text = "", fontSize = 11, fontColor = THEME.textMuted }

    refs.inventoryView:AddChild(UI.Panel {
        width = "100%",
        flexDirection = "row",
        alignItems = "center",
        gap = 12,
        paddingVertical = 10,
        children = {
            refs.profileAvatar,
            UI.Panel {
                flexGrow = 1,
                flexShrink = 1,
                flexDirection = "column",
                gap = 2,
                children = {
                    refs.profileName,
                    refs.profileStats,
                },
            },
        },
    })
    refs.inventoryGrid = UI.ScrollView {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        flexShrink = 1,
        scrollY = true,
        showScrollbar = false,
    }
    refs.inventoryView:AddChild(refs.inventoryGrid)
    return refs.inventoryView
end

local function CreateMarketView()
    refs.marketView = UI.Panel {
        width = "100%",
        flexBasis = 0,
        flexGrow = 1,
        flexShrink = 1,
        visible = false,
        paddingTop = 14,
    }

    local marketHeader = UI.Panel {
        width = "100%",
        flexDirection = "row",
        alignItems = "center",
        gap = 12,
        marginBottom = 8,
    }
    marketHeader:AddChild(UI.Label { text = "市场", fontSize = 22, fontColor = THEME.text, fontWeight = "bold" })
    marketHeader:AddChild(UI.Panel { width = 1, height = 16, backgroundColor = THEME.border, marginHorizontal = 2 })
    marketHeader:AddChild(UI.Label { text = "手续费 2%", fontSize = 13, fontColor = THEME.gold })
    refs.marketView:AddChild(marketHeader)

    refs.marketContent = UI.ScrollView {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        flexShrink = 1,
        scrollY = true,
        showScrollbar = false,
    }
    refs.marketView:AddChild(refs.marketContent)
    return refs.marketView
end

-- ============================================================================
-- 排行榜 + 银行
-- ============================================================================

---@param mode string "loan" 借款 / "repay" 还款
local function OpenBankDialog(mode)
    local isLoan = mode == "loan"
    local pending = 0    -- 0 表示还在第一步选金额
    ---@type any
    local modal = nil
    local errorLabel = UI.Label { text = "", width = "100%", fontSize = 12, fontColor = THEME.danger, textAlign = "center" }
    local body = UI.Panel { width = "100%", flexDirection = "column", gap = 10 }

    -- 与服务端一致的截断规则，保证确认页显示的就是实际会发生的结果
    ---@param raw number
    ---@return number
    local function ClampAmount(raw)
        local amount = raw
        if isLoan then
            local room = Shared.ECONOMY.MAX_LOAN - state.debt
            if amount > room then
                amount = room
            end
        else
            if amount > state.debt then
                amount = state.debt
            end
            if amount > state.balance then
                amount = state.balance
            end
        end
        if amount < 0 then
            amount = 0
        end
        return RoundPrice(amount)
    end

    ---@param amount number
    local function Send(amount)
        local connection = GetConnection()
        if not connection then
            errorLabel:SetText("还没连上服务器")
            return
        end
        local variantMap = VariantMap()
        variantMap["Amount"] = Variant(amount)
        connection:SendRemoteEvent(
            isLoan and Shared.EVENTS.LOAN_REQUEST or Shared.EVENTS.REPAY_REQUEST, true, variantMap)
        print(string.format("[Bank] 确认%s ¥%s", isLoan and "借款" or "还款", FormatMoney(amount)))
        if modal then
            modal:Close()
        end
    end

    local function Refresh()
        body:ClearChildren()

        -- 第一步：选金额
        if pending <= 0 then
            local room = Shared.ECONOMY.MAX_LOAN - state.debt
            body:AddChild(UI.Label {
                text = string.format("余额 ¥%s · 负债 ¥%s",
                    FormatMoney(state.balance), FormatMoney(state.debt)),
                width = "100%",
                fontSize = 13,
                fontColor = THEME.text,
            })
            body:AddChild(UI.Label {
                text = isLoan
                    and string.format("还可借 ¥%s · 每 %d 秒按 %.0f%% 计息",
                        FormatMoney(room), math.floor(Shared.ECONOMY.INTEREST_INTERVAL),
                        Shared.ECONOMY.INTEREST_RATE * 100)
                    or "还款不超过余额，最多还清全部负债",
                width = "100%",
                fontSize = 11,
                fontColor = THEME.textMuted,
            })

            local quick = UI.Panel { width = "100%", flexDirection = "row", gap = 8 }
            ---@type number[]
            local amounts = { 500, 1000, 0 }
            if isLoan then
                amounts = { 500, 1000, 2000 }
            end
            for _, amount in ipairs(amounts) do
                local isAll = amount == 0
                quick:AddChild(UI.Button {
                    text = isAll and "全部还清" or ("¥" .. FormatMoney(amount)),
                    flex = 1,
                    height = 42,
                    fontSize = 13,
                    backgroundColor = THEME.surfaceAlt,
                    textColor = THEME.text,
                    borderRadius = 0,
                    onClick = function()
                        ---@type number
                        local rawAmount = amount
                        if isAll then
                            rawAmount = state.debt
                        end
                        local clamped = ClampAmount(rawAmount)
                        if clamped <= 0 then
                            errorLabel:SetText(isLoan and "没有可借额度了" or "没有可还的负债")
                            return
                        end
                        pending = clamped
                        errorLabel:SetText("")
                        Refresh()
                    end,
                })
            end
            body:AddChild(quick)
            body:AddChild(errorLabel)
            return
        end

        -- 第二步：确认，并预告借贷之后的余额与负债
        local afterBalance = isLoan and (state.balance + pending) or (state.balance - pending)
        local afterDebt = isLoan and (state.debt + pending) or (state.debt - pending)
        body:AddChild(UI.Label {
            text = string.format("确认%s ¥%s？", isLoan and "借款" or "还款", FormatMoney(pending)),
            width = "100%",
            fontSize = 16,
            fontWeight = "bold",
            fontColor = THEME.text,
            textAlign = "center",
        })
        body:AddChild(UI.Label {
            text = string.format("余额 ¥%s → ¥%s", FormatMoney(state.balance), FormatMoney(afterBalance)),
            width = "100%",
            fontSize = 13,
            fontColor = THEME.textSecondary,
            textAlign = "center",
        })
        body:AddChild(UI.Label {
            text = string.format("负债 ¥%s → ¥%s", FormatMoney(state.debt), FormatMoney(afterDebt)),
            width = "100%",
            fontSize = 13,
            fontColor = THEME.textSecondary,
            textAlign = "center",
        })
        if isLoan then
            body:AddChild(UI.Label {
                text = string.format("未还清前每 %d 秒计息 %.0f%%",
                    math.floor(Shared.ECONOMY.INTEREST_INTERVAL), Shared.ECONOMY.INTEREST_RATE * 100),
                width = "100%",
                fontSize = 11,
                fontColor = THEME.textMuted,
                textAlign = "center",
            })
        end
        body:AddChild(errorLabel)

        local actions = UI.Panel { width = "100%", flexDirection = "row", gap = 10, marginTop = 4 }
        actions:AddChild(UI.Button {
            text = "返回",
            flex = 1,
            height = 44,
            fontSize = 14,
            backgroundColor = THEME.surfaceAlt,
            textColor = THEME.text,
            borderRadius = 0,
            onClick = function()
                pending = 0
                errorLabel:SetText("")
                Refresh()
            end,
        })
        actions:AddChild(UI.Button {
            text = isLoan and "确认借款" or "确认还款",
            flex = 1,
            height = 44,
            fontSize = 14,
            backgroundColor = THEME.gold,
            textColor = THEME.ink,
            borderRadius = 0,
            onClick = function()
                Send(pending)
            end,
        })
        body:AddChild(actions)
    end

    modal = UI.Modal {
        title = isLoan and "向银行借款" or "还款",
        size = "sm",
        onClose = function(self)
            self:Destroy()
        end,
    }
    modal:AddContent(body)
    Refresh()
    modal:Open()
end

-- 我的资产卡 + 榜单
-- ============================================================================
-- 查看其他玩家的仓库
-- ============================================================================

---@param userId string
local function RequestPlayerInventory(userId)
    local connection = GetConnection()
    if not connection then
        return
    end
    local variantMap = VariantMap()
    variantMap["UserId"] = Variant(tostring(userId))
    connection:SendRemoteEvent(Shared.EVENTS.INVENTORY_REQUEST, true, variantMap)
end

---@param data table
local function ShowPlayerInventory(data)
    ---@type any
    local modal = nil
    ---@type any[]
    local children = {
        UI.Panel {
            width = "100%",
            flexDirection = "row",
            alignItems = "center",
            gap = 12,
            padding = 10,
            backgroundColor = THEME.card,
            borderWidth = 1,
            borderColor = THEME.border,
            borderRadius = 0,
            overflow = "hidden",
            children = {
                UI.Panel {
                    width = 52,
                    height = 52,
                    borderRadius = 26,
                    overflow = "hidden",
                    backgroundColor = THEME.surfaceAlt,
                    backgroundImage = Shared.GetAvatarImage(tostring(data.avatar or "")),
                    backgroundFit = "cover",
                },
                UI.Panel {
                    flexGrow = 1,
                    flexShrink = 1,
                    flexDirection = "column",
                    gap = 3,
                    children = {
                        UI.Label { text = tostring(data.nickname or "玩家"), width = "100%", fontSize = 16, fontWeight = "bold", fontColor = THEME.text },
                        UI.Label { text = "净资产 ¥" .. FormatMoney(tonumber(data.assets) or 0), width = "100%", fontSize = 12, fontColor = THEME.gold },
                        UI.Label { text = "共 " .. tostring(data.total or 0) .. " 件藏品", width = "100%", fontSize = 11, fontColor = THEME.textMuted },
                    },
                },
            },
        },
    }

    if data.ok and type(data.items) == "table" and #data.items > 0 then
        local grid = UI.SimpleGrid { width = "100%", columns = 4, gap = 8 }
        for _, item in ipairs(data.items) do
            local rarity = GetRarity(tostring(item.key))
            grid:AddChild(UI.Panel {
                flexDirection = "column",
                alignItems = "center",
                gap = 2,
                padding = 4,
                backgroundColor = THEME.card,
                borderWidth = 1,
                borderColor = rarity.color,
                borderRadius = 0,
                overflow = "hidden",
                children = {
                    UI.Panel {
                        width = "100%",
                        aspectRatio = 1,
                        backgroundGradient = {
                            type = "radial",
                            from = THEME.cardImageFrom,
                            to = THEME.cardImageTo,
                        },
                        backgroundImage = Shared.GetRarityImage(rarity, 1),
                        backgroundFit = "contain",
                        borderRadius = 0,
                    },
                    UI.Label { text = rarity.name, width = "100%", fontSize = 8, fontColor = rarity.color, textAlign = "center" },
                    UI.Label { text = "×" .. tostring(item.count), width = "100%", fontSize = 12, fontWeight = "bold", fontColor = THEME.gold, textAlign = "center" },
                },
            })
        end
        children[#children + 1] = grid
    else
        children[#children + 1] = UI.Label {
            text = data.ok and "仓库是空的" or "该玩家已离开，暂时看不到仓库",
            width = "100%",
            fontSize = 13,
            fontColor = THEME.textMuted,
            textAlign = "center",
            marginTop = 12,
        }
    end

    modal = UI.Modal {
        title = "玩家仓库",
        size = "md",
        onClose = function(self)
            self:Destroy()
        end,
    }
    modal:AddContent(UI.Panel { width = "100%", flexDirection = "column", gap = 10, children = children })
    modal:SetFooter(UI.Panel {
        width = "100%",
        flexDirection = "row",
        justifyContent = "flex-end",
        children = {
            UI.Button {
                text = "关闭",
                width = 88,
                height = 40,
                fontSize = 14,
                backgroundColor = THEME.surfaceAlt,
                textColor = THEME.text,
                borderRadius = 0,
                onClick = function()
                    if modal then
                        modal:Close()
                    end
                end,
            },
        },
    })
    modal:Open()
end

---@param eventType string
---@param eventData VariantMap
function HandlePlayerInventory(eventType, eventData)
    local payload = eventData[Shared.PAYLOAD_FIELD]
    if not payload then
        return
    end
    local data = cjson.decode(payload:GetString())
    if type(data) ~= "table" then
        return
    end
    ShowPlayerInventory(data)
    print(string.format("[Social] 查看玩家 %s 的仓库，共 %s 件",
        tostring(data.nickname), tostring(data.total)))
end

RefreshLeaderboard = function()
    if refs.myAssetsValue then
        refs.myAssetsValue:SetText("¥" .. FormatMoney(state.assets))
    end
    if refs.myBalanceValue then
        refs.myBalanceValue:SetText("余额 ¥" .. FormatMoney(state.balance))
    end
    if refs.myDebtValue then
        refs.myDebtValue:SetText("负债 ¥" .. FormatMoney(state.debt))
    end
    if refs.myAvatarBig then
        refs.myAvatarBig:SetStyle({ backgroundImage = Shared.GetAvatarImage(state.avatar) })
    end
    if refs.myNameBig then
        refs.myNameBig:SetText(state.profileReady and state.nickname or "未设置昵称")
    end
    if not refs.leaderboardList then
        return
    end

    refs.leaderboardList:ClearChildren()
    local rows = UI.Panel { width = "100%", flexDirection = "column", gap = 8, paddingBottom = 8 }
    refs.leaderboardList:AddChild(rows)
    for index, row in ipairs(state.leaderboard) do
        local isMe = tostring(row.userId) == myUserId_
        local online = row.online ~= false
        local displayName = isMe and (state.nickname ~= "" and state.nickname or "你") or tostring(row.nickname)
        if not online then
            displayName = displayName .. " · 离线"
        end
        rows:AddChild(UI.Panel {
            width = "100%",
            height = 56,
            flexDirection = "row",
            alignItems = "center",
            gap = 10,
            paddingHorizontal = 10,
            backgroundColor = isMe and THEME.surfaceAlt or THEME.card,
            borderWidth = 1,
            borderColor = isMe and THEME.gold or THEME.border,
            borderRadius = 0,
            overflow = "hidden",
            onClick = function()
                RequestPlayerInventory(row.userId)
            end,
            children = {
                UI.Label {
                    text = tostring(index),
                    width = 26,
                    fontSize = 15,
                    fontWeight = "bold",
                    fontColor = (index <= 3) and THEME.gold or THEME.textMuted,
                    textAlign = "center",
                },
                UI.Panel {
                    width = 36,
                    height = 36,
                    borderRadius = 18,
                    overflow = "hidden",
                    backgroundColor = THEME.surfaceAlt,
                    backgroundImage = Shared.GetAvatarImage(row.avatar or ""),
                    backgroundFit = "cover",
                },
                UI.Label {
                    text = displayName,
                    flexGrow = 1,
                    flexShrink = 1,
                    fontSize = 14,
                    fontColor = online and THEME.text or THEME.textMuted,
                },
                UI.Label {
                    text = "¥" .. FormatMoney(row.assets),
                    fontSize = 15,
                    fontWeight = "bold",
                    fontColor = THEME.gold,
                },
            },
        })
    end
end

local function CreateLeaderboardView()
    refs.leaderboardView = UI.Panel {
        width = "100%",
        flexBasis = 0,
        flexGrow = 1,
        flexShrink = 1,
        visible = false,
        paddingTop = 14,
    }
    refs.leaderboardView:AddChild(UI.Label {
        text = "排行榜",
        width = "100%",
        fontSize = 22,
        fontColor = THEME.text,
        fontWeight = "bold",
        marginBottom = 10,
    })

    refs.myAvatarBig = UI.Panel {
        width = 56,
        height = 56,
        borderRadius = 28,
        overflow = "hidden",
        backgroundColor = THEME.surfaceAlt,
        backgroundImage = Shared.GetAvatarImage(state.avatar),
        backgroundFit = "cover",
    }
    refs.myNameBig = UI.Label { text = "未设置昵称", width = "100%", fontSize = 16, fontWeight = "bold", fontColor = THEME.text }
    refs.myBalanceValue = UI.Label { text = "余额 ¥0", width = "100%", fontSize = 12, fontColor = THEME.textSecondary }
    refs.myDebtValue = UI.Label { text = "负债 ¥0", width = "100%", fontSize = 12, fontColor = THEME.textMuted }
    refs.myAssetsValue = UI.Label { text = "¥0", fontSize = 24, fontWeight = "bold", fontColor = THEME.gold }

    refs.leaderboardView:AddChild(UI.Panel {
        width = "100%",
        padding = 14,
        gap = 12,
        marginBottom = 12,
        backgroundColor = THEME.card,
        borderWidth = 1,
        borderColor = THEME.border,
        borderRadius = 0,
        overflow = "hidden",
        children = {
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                alignItems = "center",
                gap = 12,
                children = {
                    refs.myAvatarBig,
                    UI.Panel {
                        flexGrow = 1,
                        flexShrink = 1,
                        flexDirection = "column",
                        gap = 2,
                        children = { refs.myNameBig, refs.myBalanceValue, refs.myDebtValue },
                    },
                    UI.Panel {
                        flexDirection = "column",
                        alignItems = "flex-end",
                        gap = 2,
                        children = {
                            UI.Label { text = "净资产", fontSize = 11, fontColor = THEME.textMuted },
                            refs.myAssetsValue,
                        },
                    },
                },
            },
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                gap = 10,
                children = {
                    UI.Button {
                        text = "借款",
                        flex = 1,
                        height = 42,
                        fontSize = 14,
                        backgroundColor = THEME.surfaceAlt,
                        textColor = THEME.text,
                        borderRadius = 0,
                        onClick = function()
                            OpenBankDialog("loan")
                        end,
                    },
                    UI.Button {
                        text = "还款",
                        flex = 1,
                        height = 42,
                        fontSize = 14,
                        backgroundColor = THEME.gold,
                        textColor = THEME.ink,
                        borderRadius = 0,
                        onClick = function()
                            OpenBankDialog("repay")
                        end,
                    },
                },
            },
        },
    })

    refs.leaderboardList = UI.ScrollView {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        flexShrink = 1,
        scrollY = true,
        showScrollbar = false,
    }
    refs.leaderboardView:AddChild(refs.leaderboardList)
    return refs.leaderboardView
end

local function CreateBottomNav()
    local nav = UI.Panel {
        width = "100%",
        flexDirection = "row",
        gap = 12,
        paddingHorizontal = 18,
        paddingVertical = 12,
        marginTop = 8,
        backgroundColor = THEME.nav,
        borderRadius = 0,
        borderWidth = 1,
        borderColor = THEME.border,
        boxShadow = { { x = 0, y = 8, blur = 20, color = { 0, 0, 0, 90 } } },
    }
    refs.navHome = UI.Button { text = "香蕉", flexGrow = 1, flexShrink = 1, height = 48, backgroundColor = THEME.gold, textColor = THEME.ink, borderRadius = 0, onClick = function() SwitchTab("home") end }
    refs.navInventory = UI.Button { text = "库存", flexGrow = 1, flexShrink = 1, height = 48, backgroundColor = THEME.surfaceAlt, textColor = THEME.text, borderRadius = 0, onClick = function() SwitchTab("inventory") end }
    refs.navMarket = UI.Button { text = "市场", flexGrow = 1, flexShrink = 1, height = 48, backgroundColor = THEME.surfaceAlt, textColor = THEME.text, borderRadius = 0, onClick = function() SwitchTab("market") end }
    refs.navLeaderboard = UI.Button { text = "排行", flexGrow = 1, flexShrink = 1, height = 48, backgroundColor = THEME.surfaceAlt, textColor = THEME.text, borderRadius = 0, onClick = function() SwitchTab("leaderboard") end }
    nav:AddChild(refs.navHome)
    nav:AddChild(refs.navInventory)
    nav:AddChild(refs.navMarket)
    nav:AddChild(refs.navLeaderboard)
    return nav
end

-- ============================================================================
-- 新用户：设置昵称 + 头像
-- ============================================================================

local function CreateProfileSetup()
    local selectedAvatar = Shared.AVATARS[1].key
    local avatarButtons = {}

    local function RefreshSelection()
        for key, button in pairs(avatarButtons) do
            local active = key == selectedAvatar
            button:SetStyle({
                borderWidth = 3,
                borderColor = active and THEME.gold or THEME.border,
                backgroundColor = active and THEME.surfaceAlt or THEME.card,
            })
        end
    end

    local avatarGrid = UI.Panel {
        width = "100%",
        flexDirection = "row",
        flexWrap = "wrap",
        gap = 12,
        justifyContent = "center",
    }
    for _, avatar in ipairs(Shared.AVATARS) do
        local button = UI.Panel {
            width = 62,
            height = 62,
            borderRadius = 31,
            overflow = "hidden",
            borderWidth = 3,
            borderColor = THEME.border,
            backgroundImage = avatar.image,
            backgroundFit = "cover",
            onClick = function()
                selectedAvatar = avatar.key
                RefreshSelection()
            end,
        }
        avatarButtons[avatar.key] = button
        avatarGrid:AddChild(button)
    end

    local nicknameField = UI.TextField {
        width = "100%",
        height = 44,
        fontSize = 15,
        maxLength = Shared.MAX_NICKNAME_LEN,
        placeholder = "给自己起个昵称",
    }
    local errorLabel = UI.Label { text = "", width = "100%", fontSize = 12, fontColor = THEME.danger, textAlign = "center" }

    local function Confirm()
        local name = nicknameField:GetValue() or ""
        if #name < 1 then
            errorLabel:SetText("请先填写昵称")
            return
        end
        local connection = GetConnection()
        if not connection then
            errorLabel:SetText("还没连上服务器")
            return
        end
        local variantMap = VariantMap()
        variantMap["Nickname"] = Variant(name)
        variantMap["Avatar"] = Variant(selectedAvatar)
        connection:SendRemoteEvent(Shared.EVENTS.SET_PROFILE, true, variantMap)
        errorLabel:SetText("")
        print("[Profile] 提交资料: " .. name .. " / " .. selectedAvatar)
    end

    local view = UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        width = "100%",
        height = "100%",
        zIndex = 100,
        visible = false,
        justifyContent = "center",
        alignItems = "center",
        paddingHorizontal = 24,
        backgroundColor = THEME.bg,
        children = {
            UI.Panel {
                width = "100%",
                padding = 20,
                gap = 14,
                backgroundColor = THEME.card,
                borderWidth = 1,
                borderColor = THEME.border,
                borderRadius = 0,
                children = {
                    UI.Label { text = "选个形象开始交易", width = "100%", fontSize = 20, fontWeight = "bold", fontColor = THEME.text, textAlign = "center" },
                    UI.Label { text = "昵称和头像会显示在你的挂单上", width = "100%", fontSize = 12, fontColor = THEME.textMuted, textAlign = "center" },
                    avatarGrid,
                    nicknameField,
                    errorLabel,
                    UI.Button {
                        text = "开始交易",
                        width = "100%",
                        height = 48,
                        fontSize = 16,
                        backgroundColor = THEME.gold,
                        textColor = THEME.ink,
                        borderRadius = 0,
                        onClick = Confirm,
                    },
                },
            },
        },
    }
    RefreshSelection()

    refs.setupView = view
    refs.setupNicknameField = nicknameField
    refs.setupErrorLabel = errorLabel
    refs.setupAvatarButtons = avatarButtons
    return view
end

local function CreateUI()
    UI.Init({
        theme = "default-dark",
        scale = UI.Scale.DEFAULT,
    })

    -- 市场与仓库内容全部来自服务端快照，这里不预置任何商品
    state.marketListings = {}

    local content = UI.Panel {
        width = "100%",
        height = "100%",
        flexDirection = "column",
        flexShrink = 1,
        paddingHorizontal = 20,
        paddingVertical = 16,
        gap = 8,
        backgroundColor = THEME.bg,
        children = {
            CreateStatsBar(),
            CreateHomeView(),
            CreateInventoryView(),
            CreateMarketView(),
            CreateLeaderboardView(),
            CreateDetailView(),
            CreateBottomNav(),
        },
    }

    local root = UI.Panel {
        width = "100%",
        height = "100%",
        backgroundColor = THEME.bg,
        children = {
            UI.SafeAreaView {
                width = "100%",
                height = "100%",
                edges = { "top", "bottom" },
                pointerEvents = "box-none",
                children = { content, CreateProfileSetup() },
            },
        },
    }
    UI.SetRoot(root)
    RefreshAll()
    SwitchTab("market")
    print("[Banana] UI 初始化完成，竖屏 Yoga UI 原型启动")
end

-- ============================================================================
-- 服务端快照 -> 本地显示
-- ============================================================================

---@param jsonStr string
local function ApplyPayload(jsonStr)
    local ok, data = pcall(cjson.decode, jsonStr)
    if not ok or type(data) ~= "table" then
        print("[Client] 市场快照解析失败")
        return
    end
    myUserId_ = tostring(data.userId or "")

    -- 自己的资料与积分（都由服务端权威下发）
    state.profileReady = data.profileReady == true
    state.nickname = tostring(data.nickname or "")
    state.avatar = tostring(data.avatar or "")
    state.points = data.points or 0
    state.totalPoints = data.totalPoints or 0
    state.totalClicks = data.totalClicks or 0
    state.totalDrops = data.totalDrops or 0
    state.balance = data.balance or 0
    state.debt = data.debt or 0
    state.assets = data.assets or 0
    state.leaderboard = data.leaderboard or {}
    UpdateProgress()
    RefreshProfileStrip()
    RefreshLeaderboard()
    if refs.setupView then
        refs.setupView:SetVisible(not state.profileReady)
    end

    -- 自己的仓库
    local inventory = {}
    for _, item in ipairs(data.inventory or {}) do
        inventory[#inventory + 1] = {
            id = item.id,
            rarity = item.rarity,
            obtainedAt = item.obtainedAt,
        }
    end
    state.inventory = inventory

    -- 市场挂单
    local listings = {}
    for _, item in ipairs(data.listings or {}) do
        local rarity = GetRarity(item.rarity)
        local history = {}
        for _, sample in ipairs(item.history or {}) do
            history[#history + 1] = { timestamp = sample.t, value = sample.v }
        end
        local bidder = tostring(item.bidder or "")
        local sellerId = tostring(item.sellerId or "")
        local sellerAvatar = tostring(item.sellerAvatar or "")
        listings[#listings + 1] = {
            id = item.id,
            name = rarity.name,
            rarity = item.rarity,
            rarityName = rarity.name,
            sellerName = (sellerId == myUserId_) and "你" or tostring(item.sellerName or "玩家"),
            sellerAvatar = (sellerAvatar ~= "") and sellerAvatar or ((sellerId == myUserId_) and state.avatar or ""),
            wants = 1,
            stock = 1,
            basePrice = (history[1] and history[1].value) or item.price,
            highestBid = item.price,
            buyoutPrice = item.buyout,
            highestBidder = (bidder ~= "") and ((bidder == myUserId_) and "你" or "其他玩家") or nil,
            sold = false,
            priceHistory = history,
        }
    end
    state.marketListings = listings

    RefreshInventory()
    RefreshMarket()

    -- 详情页开着就同步过去；挂单已被买走就退回市场
    if state.selectedListing then
        local current = nil
        for _, listing in ipairs(state.marketListings) do
            if listing.id == state.selectedListing.id then
                current = listing
                break
            end
        end
        if current then
            state.selectedListing = current
            RefreshDetailActions(current)
            RefreshTrendChart(true)
        else
            CloseListingDetail()
        end
    end
end

---@param eventType string
---@param eventData VariantMap
function HandleMarketUpdate(eventType, eventData)
    local payload = eventData[Shared.PAYLOAD_FIELD]
    if payload then
        ApplyPayload(payload:GetString())
    end
end

---@param eventType string
---@param eventData VariantMap
function HandleDropResult(eventType, eventData)
    local rarityKey = eventData["Rarity"]:GetString()
    local rarity = GetRarity(rarityKey)
    EnqueueDrop(rarityKey)
    print("[Banana] 掉落: " .. rarity.name)
end

-- ============================================================================
-- 动画循环：逐帧换图（Mythic 神话香蕉的眼睛）
-- ============================================================================

local ANIM_FRAME_INTERVAL = 0.35
local animFrame_ = 1
local animAccumulator_ = 0

---@param eventType string
---@param eventData UpdateEventData
function HandleClientUpdate(eventType, eventData)
    if #animatedImages_ == 0 then
        return
    end
    local timeStep = eventData:GetFloat("TimeStep")
    animAccumulator_ = animAccumulator_ + timeStep
    if animAccumulator_ < ANIM_FRAME_INTERVAL then
        return
    end
    animAccumulator_ = animAccumulator_ - ANIM_FRAME_INTERVAL
    animFrame_ = animFrame_ + 1

    for _, entry in ipairs(animatedImages_) do
        entry.panel:SetStyle({ backgroundImage = Shared.GetRarityImage(entry.rarity, animFrame_) })
    end

    -- 掉落弹窗（面板常驻，按当前弹出的品质取图）
    if dropImage_ and dropCurrentRarity_ and dropModal_ and dropModal_:IsOpen() then
        dropImage_:SetStyle({ backgroundImage = Shared.GetRarityImage(dropCurrentRarity_, animFrame_) })
    end

    -- 详情页同理，跟着当前选中的挂单走
    local listing = state.selectedListing
    if refs.detailProductImage and listing then
        local rarity = GetRarity(listing.rarity)
        if Shared.IsAnimatedRarity(rarity) then
            refs.detailProductImage:SetStyle({ backgroundImage = Shared.GetRarityImage(rarity, animFrame_) })
        end
    end
end

function Client.Start()
    graphics.windowTitle = CONFIG.title
    graphics:SetOrientations("Portrait")

    -- 客户端必须有自己的 Scene 并交给 helper 关联到服务器连接，
    -- 否则服务端发来的 LoadScene 无处安放
    local scene = Scene()
    scene:CreateComponent("Octree", LOCAL)
    InitAudio(scene)

    math.randomseed(os.time())
    CreateUI()
    CreateDropModal()

    Shared.RegisterClientEvents()
    SubscribeToEvent(Shared.EVENTS.PLAYER_INVENTORY, "HandlePlayerInventory")
    SubscribeToEvent("Update", "HandleClientUpdate")
    SubscribeToEvent(Shared.EVENTS.MARKET_UPDATE, "HandleMarketUpdate")
    SubscribeToEvent(Shared.EVENTS.DROP_RESULT, "HandleDropResult")
    SubscribeToEvent(Shared.EVENTS.POINT_UPDATE, "HandlePointUpdate")

    PlayerSessions.Client.Setup({
        scene = scene,

        onRestoreBegin = function()
            print("[Client] 正在恢复对局……")
        end,

        -- 服务端判定「首次进入」：快照里已经包含该账户默认的 3 个商品
        onFreshStart = function(data)
            local payload = data[Shared.PAYLOAD_FIELD]
            if payload then
                ApplyPayload(payload:GetString())
            end
            print("[Client] 已进入市场，我是 " .. PlayerSessions.Client.GetUserId())
        end,

        -- 服务端判定「重连恢复」：仓库与挂单原样回来
        onApplySnapshot = function(data)
            local payload = data[Shared.PAYLOAD_FIELD]
            if payload then
                ApplyPayload(payload:GetString())
            end
            print("[Client] 已恢复市场状态，我是 " .. PlayerSessions.Client.GetUserId())
        end,

        onRestoreTimeout = function(elapsed)
            print(string.format("[Client] 等待服务端快照超时（%.0f 秒）", elapsed))
        end,
    })

    serverConnection_ = network:GetServerConnection()
    print("[Banana] 客户端启动：每秒自动 +1，点击香蕉手动 +1，60 次掉落")
end

function Client.Stop()
    PlayerSessions.Client.Shutdown()
    UI.Shutdown()
end

-- 积分由服务端每秒推一次权威值
---@param eventType string
---@param eventData VariantMap
function HandlePointUpdate(eventType, eventData)
    state.points = eventData["Points"]:GetInt()
    state.totalPoints = eventData["TotalPoints"]:GetInt()
    state.totalClicks = eventData["TotalClicks"]:GetInt()
    state.totalDrops = eventData["TotalDrops"]:GetInt()
    UpdateProgress()
end

return Client

