-- 香蕉收集屋：点击、自动累积、品质掉落与交易市场原型
-- 竖屏手游版本，UI 使用 Yoga UI。

local UI = require("urhox-libs/UI")
local Widget = require("urhox-libs/UI/Core/Widget")

local CONFIG = {
    title = "香蕉收集屋",
    dropCost = 300,
    autoGainInterval = 1.0,
    serviceFeeRate = 0.02,
}

local RARITIES = {
    { key = "normal", name = "Normal 普通", probability = 70.0, color = { 181, 181, 181, 255 }, price = 1, image = "image/banana_normal_20260904085931.png" },
    { key = "common", name = "Common 优良", probability = 25.0, color = { 162, 255, 148, 255 }, price = 5, image = "image/banana_common_20260904085932.png" },
    { key = "uncommon", name = "Uncommon 罕见", probability = 4.89, color = { 114, 242, 245, 255 }, price = 25, image = "image/banana_uncommon_20260904085934.png" },
    { key = "rare", name = "Rare 稀有", probability = 0.1, color = { 115, 160, 255, 255 }, price = 100, image = "image/banana_rare_20260904085933.png" },
    { key = "epic", name = "Epic 史诗", probability = 0.01, color = { 239, 121, 255, 255 }, price = 500, image = "image/banana_epic_20260904085935.png" },
    { key = "ultra_rare", name = "Ultra Rare 超稀有", probability = 1 / 400000 * 100, color = { 255, 255, 255, 255 }, price = 5000, image = "image/banana_ultra_rare_20260904085936.png" },
    { key = "legendary", name = "Legendary 传说", probability = 1 / 10000000 * 100, color = { 255, 237, 0, 255 }, price = 50000, image = "image/banana_legendary_20260904085937.png" },
}

local state = {
    points = 0,
    totalClicks = 0,
    totalPoints = 0,
    totalDrops = 0,
    elapsed = 0,
    secondAccumulator = 0,
    inventory = {},
    nextBananaId = 1,
    marketListings = {},
    selectedTab = "home",
    selectedListing = nil,
    trendPeriod = "minute",
    trendScrollOffset = 0,
    trendStickToLatest = true,
}

local refs = {}

local function FormatNumber(value)
    if value >= 1000000 then
        return string.format("%.2fM", value / 1000000)
    end
    if value >= 1000 then
        return string.format("%.1fK", value / 1000)
    end
    return tostring(math.floor(value))
end

local function FormatTime(seconds)
    local wholeSeconds = math.max(0, math.floor(seconds))
    local minutes = math.floor(wholeSeconds / 60)
    local remainSeconds = wholeSeconds % 60
    return string.format("%02d:%02d", minutes, remainSeconds)
end

local function GetRarity(key)
    for _, rarity in ipairs(RARITIES) do
        if rarity.key == key then
            return rarity
        end
    end
    return RARITIES[1]
end

local function RollRarity()
    local totalProbability = 0
    for _, rarity in ipairs(RARITIES) do
        totalProbability = totalProbability + rarity.probability
    end

    local roll = math.random() * totalProbability
    local cursor = 0
    for _, rarity in ipairs(RARITIES) do
        cursor = cursor + rarity.probability
        if roll <= cursor then
            return rarity
        end
    end
    return RARITIES[1]
end

local function AddBanana(rarity)
    local banana = {
        id = state.nextBananaId,
        rarity = rarity.key,
        obtainedAt = os.time(),
        listed = false,
    }
    state.nextBananaId = state.nextBananaId + 1
    table.insert(state.inventory, banana)
    state.totalDrops = state.totalDrops + 1
    print(string.format("[Banana] 掉落 #%d: %s, 默认价 ¥%d", banana.id, rarity.name, rarity.price))
    return banana
end

local function UpdateLabel(label, text)
    if label then
        label:SetText(text)
    end
end

local function GetListingImage(listing)
    return GetRarity(listing.rarity).image
end

local function UpdateProgress()
    UpdateLabel(refs.totalPointsLabel, FormatNumber(state.totalPoints))
end

local function ShowGain(amount, source)
    UpdateLabel(refs.gainLabel, "+" .. tostring(amount))
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

local function RefreshInventory()
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
                UI.Label { text = "还没有香蕉", fontSize = 18, fontColor = { 210, 190, 160, 255 } },
                UI.Label { text = "积满 300 点即可获得香蕉", fontSize = 13, fontColor = { 150, 145, 160, 255 }, marginTop = 8, textAlign = "center" },
            },
        })
        UpdateLabel(refs.inventoryCountLabel, "0 根")
        return
    end

    for index = #state.inventory, 1, -1 do
        local banana = state.inventory[index]
        local rarity = GetRarity(banana.rarity)
        local row = math.floor((index - 1) / 2) + 1
        local rowPanel = refs.inventoryGrid:GetChildAt(row)
        if not rowPanel then
            rowPanel = UI.Panel {
                width = "100%",
                flexDirection = "row",
                gap = 12,
                flexShrink = 1,
            }
            refs.inventoryGrid:AddChild(rowPanel)
        end
        local item = UI.Panel {
            flex = 1,
            minHeight = 154,
            alignItems = "center",
            justifyContent = "center",
            gap = 5,
            padding = 8,
            backgroundColor = { 255, 255, 255, 255 },
            borderRadius = 14,
            borderWidth = 1,
            borderColor = rarity.color,
        }
        item:AddChild(UI.Panel {
            width = "78%",
            maxWidth = 88,
            aspectRatio = 1,
            backgroundImage = rarity.image,
            backgroundFit = "contain",
        })
        item:AddChild(UI.Label { text = rarity.name, width = "100%", fontSize = 10, fontColor = rarity.color, textAlign = "center" })
        item:AddChild(UI.Label { text = "¥" .. FormatNumber(rarity.price), width = "100%", fontSize = 11, fontColor = { 65, 60, 65, 255 }, textAlign = "center" })
        rowPanel:AddChild(item)
    end
    UpdateLabel(refs.inventoryCountLabel, tostring(#state.inventory) .. " 根")
end

local TREND_DAY_COUNT = 90
local TREND_CANDLE_SLOT = 22
local TREND_MINUTE_STEP = 5
local TREND_LONG_PRESS_MS = 280
local TREND_PAN_THRESHOLD = 8

local function GetTimeMs()
    if time and time.GetElapsedTime then
        return time:GetElapsedTime() * 1000
    end
    return os.clock() * 1000
end

---@class TrendPoint
---@field timestamp integer
---@field value number

---@class TrendCandle
---@field open number
---@field close number
---@field high number
---@field low number

local function FormatMonthDay(timestamp)
    return tostring(os.date("%m-%d", timestamp))
end

local function FormatClock(timestamp)
    return tostring(os.date("%H:%M:%S", timestamp))
end

local function DayStart(timestamp)
    local formatted = tostring(os.date("%Y-%m-%d", timestamp))
    local year = math.tointeger(string.sub(formatted, 1, 4)) or 2026
    local month = math.tointeger(string.sub(formatted, 6, 7)) or 1
    local day = math.tointeger(string.sub(formatted, 9, 10)) or 1
    return os.time({ year = year, month = month, day = day, hour = 0, min = 0, sec = 0 })
end

---@param basePrice number
---@param count integer
---@param seed integer
---@param startValue number|nil
---@return number[]
local function BuildPriceSeries(basePrice, count, seed, startValue)
    local values = {}
    local value = startValue or (basePrice * 0.86)
    for index = 1, count do
        local wave = math.sin((index + seed) * 0.085) * 0.006
        local drift = (basePrice - value) * 0.018
        value = math.max(basePrice * 0.72, math.min(basePrice * 1.18, value * (1 + wave + drift)))
        values[index] = value
    end
    return values
end

local function GetTrendData(period, basePrice)
    local now = os.time()
    if period == "minute" then
        local dayStart = DayStart(now)
        local elapsedMinutes = math.tointeger(math.max(1, (math.tointeger(math.floor((now - dayStart) / 60)) or 0) + 1)) or 1
        local sampleCount = math.tointeger(math.max(2, math.floor((elapsedMinutes - 1) / TREND_MINUTE_STEP) + 1)) or 2
        local values = BuildPriceSeries(basePrice, sampleCount, 11, basePrice * 0.96)
        local points = {}
        for index, value in ipairs(values) do
            points[index] = {
                timestamp = dayStart + (index - 1) * TREND_MINUTE_STEP * 60,
                value = value,
            }
        end
        return {
            title = "分时走势",
            mode = "line",
            axisStart = dayStart,
            axisEnd = dayStart + 24 * 3600,
            points = points,
            xLabels = { "00:00", "04:00", "08:00", "12:00", "16:00", "20:00", "24:00" },
        }
    end

    local todayStart = DayStart(now)
    local values = BuildPriceSeries(basePrice, TREND_DAY_COUNT, 29, basePrice * 0.55)
    local points = {}
    for index, value in ipairs(values) do
        local timestamp = todayStart - (TREND_DAY_COUNT - index) * 86400 -- 从今天往前铺满全部交易日
        points[index] = {
            timestamp = timestamp,
            value = value,
        }
    end
    return {
        title = "日K走势",
        mode = "candles",
        axisStart = points[1].timestamp,
        axisEnd = points[#points].timestamp,
        points = points,
        xLabels = {},
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

local function DrawDashedLine(nvg, x1, y1, x2, y2)
    local dashLength = 6
    local gapLength = 5
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
        nvgStrokeColor(nvg, nvgRGBA(126, 88, 230, 180))
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
    nvgRoundedRect(nvg, l.x + 2, selectedPoint.y - 9, 48, 18, 3)
    nvgFillColor(nvg, nvgRGBA(126, 88, 230, 235))
    nvgFill(nvg)
    nvgFillColor(nvg, nvgRGBA(255, 255, 255, 255))
    nvgText(nvg, l.x + 6, selectedPoint.y, string.format("¥%.1f", selectedValue), nil)

    nvgTextAlign(nvg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgBeginPath(nvg)
    nvgRoundedRect(nvg, selectedPoint.x - 40, l.y + l.h - 20, 80, 18, 3)
    nvgFillColor(nvg, nvgRGBA(126, 88, 230, 235))
    nvgFill(nvg)
    nvgFillColor(nvg, nvgRGBA(255, 255, 255, 255))
    nvgText(nvg, selectedPoint.x, l.y + l.h - 11, timeText, nil)

    nvgBeginPath(nvg)
    nvgCircle(nvg, selectedPoint.x, selectedPoint.y, 5)
    nvgFillColor(nvg, nvgRGBA(255, 255, 255, 255))
    nvgFill(nvg)
    nvgBeginPath(nvg)
    nvgCircle(nvg, selectedPoint.x, selectedPoint.y, 2)
    nvgFillColor(nvg, nvgRGBA(126, 88, 230, 255))
    nvgFill(nvg)
end

---@class TrendChart : Widget
---@field points_ TrendPoint[]
---@field candles_ TrendCandle[]
---@field xLabels_ string[]
---@field lineColor_ number[]
---@field fillColor_ number[]
---@field chartMode_ string
---@field axisStart_ integer
---@field axisEnd_ integer
---@field slotWidth_ number
---@field scrollOffset_ number
---@field onScrollChange_ fun(offset: number, stickToLatest: boolean)|nil
---@field selectedIndex_ integer|nil
---@field pressing_ boolean
---@field panning_ boolean
---@field crosshair_ boolean
---@field pressStartX_ number
---@field pressStartTime_ number
---@field pressOffset_ number
---@field stickToLatest_ boolean
local TrendChart = UI.Widget:Extend("TrendChart")

function TrendChart:Init(props)
    props = props or {}
    props.backgroundColor = false
    props.pointerEvents = "auto"
    Widget.Init(self, props)
    self.points_ = props.points or {}
    self.candles_ = props.candles or {}
    self.xLabels_ = props.xLabels or {}
    self.lineColor_ = props.lineColor or { 126, 88, 230, 255 }
    self.fillColor_ = props.fillColor or { 126, 88, 230, 50 }
    self.chartMode_ = props.chartMode or "line"
    self.axisStart_ = props.axisStart or 0
    self.axisEnd_ = props.axisEnd or 1
    self.slotWidth_ = props.slotWidth or TREND_CANDLE_SLOT
    self.scrollOffset_ = props.scrollOffset or 0
    self.onScrollChange_ = props.onScrollChange
    self.selectedIndex_ = nil
    self.pressing_ = false
    self.panning_ = false
    self.crosshair_ = false
    self.pressStartX_ = 0
    self.pressStartTime_ = 0
    self.pressOffset_ = 0
    self.stickToLatest_ = props.stickToLatest == true
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

function TrendChart:GetContentWidth()
    if self.chartMode_ ~= "candles" then
        return self:GetChartMetrics().width
    end
    return #self.points_ * self.slotWidth_
end

function TrendChart:GetLatestOffset()
    return self:GetContentWidth() - self:GetChartMetrics().width
end

function TrendChart:ClampScroll(offset)
    local latest = self:GetLatestOffset()
    local minOffset = math.min(0, latest)
    local maxOffset = math.max(0, latest)
    return math.max(minOffset, math.min(maxOffset, offset))
end

function TrendChart:SyncScrollToLayout()
    if self.chartMode_ ~= "candles" then
        self.scrollOffset_ = 0
        return
    end
    if self.stickToLatest_ then
        self.scrollOffset_ = self:GetLatestOffset()
    else
        self.scrollOffset_ = self:ClampScroll(self.scrollOffset_)
    end
end

function TrendChart:SetScrollOffset(offset, fromUser)
    self.scrollOffset_ = self:ClampScroll(offset)
    if fromUser then
        self.stickToLatest_ = math.abs(self.scrollOffset_ - self:GetLatestOffset()) <= 0.5
    end
    if self.onScrollChange_ then
        self.onScrollChange_(self.scrollOffset_, self.stickToLatest_)
    end
end

function TrendChart:ValueToY(value, metrics, minValue, valueRange)
    return metrics.top + (1 - (value - minValue) / valueRange) * metrics.height
end

function TrendChart:GetVisibleRange(minValue, maxValue)
    if self.chartMode_ ~= "candles" then
        return minValue, maxValue
    end
    self:SyncScrollToLayout()
    local metrics = self:GetChartMetrics()
    local firstIndex = math.tointeger(math.max(1, math.floor(self.scrollOffset_ / self.slotWidth_) + 1)) or 1
    local lastIndex = math.tointeger(math.min(#self.points_, math.ceil((self.scrollOffset_ + metrics.width) / self.slotWidth_))) or #self.points_
    local visibleMin = math.huge
    local visibleMax = -math.huge
    for index = firstIndex, lastIndex do
        local candle = self.candles_[index]
        if candle then
            visibleMin = math.min(visibleMin, candle.low)
            visibleMax = math.max(visibleMax, candle.high)
        else
            visibleMin = math.min(visibleMin, self.points_[index].value)
            visibleMax = math.max(visibleMax, self.points_[index].value)
        end
    end
    if visibleMin == math.huge then
        return minValue, maxValue
    end
    return visibleMin, visibleMax
end

function TrendChart:PointX(index, metrics)
    if self.chartMode_ == "candles" then
        return metrics.left + (index - 0.5) * self.slotWidth_ - self.scrollOffset_
    end
    local axisSpan = math.max(1, self.axisEnd_ - self.axisStart_)
    return metrics.left + ((self.points_[index].timestamp - self.axisStart_) / axisSpan) * metrics.width
end

function TrendChart:IndexAtLocalX(localX)
    local metrics = self:GetChartMetrics()
    if self.chartMode_ == "candles" then
        local contentX = localX - metrics.paddingLeft + self.scrollOffset_
        local rawIndex = math.floor(contentX / self.slotWidth_) + 1
        return math.max(1, math.min(#self.points_, math.tointeger(rawIndex) or 1))
    end
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

function TrendChart:UpdateSelectionFromEvent(event)
    if not event or #self.points_ < 1 then
        return
    end
    self.selectedIndex_ = self:IndexAtLocalX(event.x)
end

function TrendChart:OnPointerDown(event)
    if not event or not event:IsPrimaryAction() then
        return
    end
    self:SyncScrollToLayout()
    self.pressing_ = true
    self.panning_ = false
    self.crosshair_ = false
    self.pressStartX_ = event.x
    self.pressStartTime_ = GetTimeMs()
    self.pressOffset_ = self.scrollOffset_
    event:PreventDefault()
end

function TrendChart:OnPointerMove(event)
    if not event or not self.pressing_ then
        return
    end
    local dx = event.x - self.pressStartX_
    if self.chartMode_ == "candles" and not self.crosshair_ and math.abs(dx) >= TREND_PAN_THRESHOLD then
        self.panning_ = true
    end
    if self.panning_ then
        self:SetScrollOffset(self.pressOffset_ - dx, true)
        return
    end
    if self.crosshair_ or (GetTimeMs() - self.pressStartTime_ >= TREND_LONG_PRESS_MS) then
        self.crosshair_ = true
        self:UpdateSelectionFromEvent(event)
    end
end

function TrendChart:OnPointerUp(event)
    if event and self.pressing_ and not self.panning_ then
        if self.crosshair_ or (GetTimeMs() - self.pressStartTime_ >= TREND_LONG_PRESS_MS) then
            self:UpdateSelectionFromEvent(event)
        elseif self.chartMode_ ~= "candles" then
            self:UpdateSelectionFromEvent(event)
        end
    end
    self.pressing_ = false
    self.panning_ = false
end

function TrendChart:OnPointerCancel()
    self.pressing_ = false
    self.panning_ = false
    self.crosshair_ = false
end

---@param event GestureEvent
---@return boolean
function TrendChart:OnPanStart(event)
    self:SyncScrollToLayout()
    self.pressing_ = true
    self.panning_ = false
    self.crosshair_ = false
    self.pressStartX_ = event.x
    self.pressStartTime_ = GetTimeMs()
    self.pressOffset_ = self.scrollOffset_
    return true
end

---@param event GestureEvent
function TrendChart:OnPanMove(event)
    if not self.pressing_ then
        return
    end
    local dx = event.x - self.pressStartX_
    if self.chartMode_ == "candles" and not self.crosshair_ and math.abs(dx) >= TREND_PAN_THRESHOLD then
        self.panning_ = true
    end
    if self.panning_ then
        self:SetScrollOffset(self.pressOffset_ - dx, true)
        return
    end
    if self.crosshair_ or (GetTimeMs() - self.pressStartTime_ >= TREND_LONG_PRESS_MS) then
        self.crosshair_ = true
        self.selectedIndex_ = self:IndexAtLocalX(event.x)
    end
end

---@param event GestureEvent
function TrendChart:OnPanEnd(event)
    if self.pressing_ and not self.panning_ then
        if self.crosshair_ or (GetTimeMs() - self.pressStartTime_ >= TREND_LONG_PRESS_MS) then
            self.selectedIndex_ = self:IndexAtLocalX(event.x)
        elseif self.chartMode_ ~= "candles" then
            self.selectedIndex_ = self:IndexAtLocalX(event.x)
        end
    end
    self.pressing_ = false
    self.panning_ = false
end

local function BuildCandles(points)
    local candles = {}
    for index, point in ipairs(points) do
        local previous = points[math.max(1, index - 1)].value
        local closeValue = point.value
        local openValue = index == 1 and closeValue * 0.96 or previous
        local highValue = math.max(openValue, closeValue) * (1.008 + (index % 3) * 0.002)
        local lowValue = math.min(openValue, closeValue) * (0.992 - (index % 2) * 0.0015)
        candles[index] = { open = openValue, close = closeValue, high = highValue, low = lowValue }
    end
    return candles
end

function TrendChart:Render(nvg)
    local metrics = self:GetChartMetrics()
    local points = self.points_
    if #points < 1 or metrics.w <= 0 or metrics.h <= 0 then
        return
    end
    self:SyncScrollToLayout()

    local minValue = math.huge
    local maxValue = -math.huge
    for _, point in ipairs(points) do
        minValue = math.min(minValue, point.value)
        maxValue = math.max(maxValue, point.value)
    end
    minValue, maxValue = self:GetVisibleRange(minValue, maxValue)
    local valueRange = math.max(0.01, maxValue - minValue)

    nvgSave(nvg)
    nvgIntersectScissor(nvg, metrics.x, metrics.y, metrics.w, metrics.h)

    if self.chartMode_ == "candles" then
        local candleWidth = math.max(4, self.slotWidth_ * 0.62)
        for index, candle in ipairs(self.candles_) do
            local x = self:PointX(index, metrics)
            if x >= metrics.left - self.slotWidth_ and x <= metrics.left + metrics.width + self.slotWidth_ then
                local highY = self:ValueToY(candle.high, metrics, minValue, valueRange)
                local lowY = self:ValueToY(candle.low, metrics, minValue, valueRange)
                local openY = self:ValueToY(candle.open, metrics, minValue, valueRange)
                local closeY = self:ValueToY(candle.close, metrics, minValue, valueRange)
                local rising = candle.close >= candle.open
                local color = rising and { 35, 178, 118, 255 } or { 226, 91, 105, 255 }
                nvgBeginPath(nvg)
                nvgMoveTo(nvg, x, highY)
                nvgLineTo(nvg, x, lowY)
                nvgStrokeColor(nvg, nvgRGBA(color[1], color[2], color[3], 255))
                nvgStrokeWidth(nvg, 1.5)
                nvgStroke(nvg)
                local bodyTop = math.min(openY, closeY)
                local bodyHeight = math.max(2, math.abs(closeY - openY))
                nvgBeginPath(nvg)
                nvgRect(nvg, x - candleWidth / 2, bodyTop, candleWidth, bodyHeight)
                nvgFillColor(nvg, nvgRGBA(color[1], color[2], color[3], 255))
                nvgFill(nvg)
            end
        end
    else
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
            nvgStrokeWidth(nvg, 2.2)
            nvgLineJoin(nvg, NVG_ROUND)
            nvgStroke(nvg)
        end

        local lastPoint = drawPoints[#drawPoints]
        nvgBeginPath(nvg)
        nvgCircle(nvg, lastPoint.x, lastPoint.y, 5)
        nvgFillColor(nvg, nvgRGBA(255, 255, 255, 255))
        nvgFill(nvg)
        nvgBeginPath(nvg)
        nvgCircle(nvg, lastPoint.x, lastPoint.y, 3)
        nvgFillColor(nvg, nvgRGBA(self.lineColor_[1], self.lineColor_[2], self.lineColor_[3], 255))
        nvgFill(nvg)
    end

    if self.selectedIndex_ then
        local selected = points[self.selectedIndex_]
        local selectedPoint = {
            x = self:PointX(self.selectedIndex_, metrics),
            y = self:ValueToY(selected.value, metrics, minValue, valueRange),
        }
        local timeText = self.chartMode_ == "candles" and FormatMonthDay(selected.timestamp) or FormatClock(selected.timestamp)
        DrawSelectionOverlay(nvg, metrics, selectedPoint, selected.value, timeText)
    end
    nvgRestore(nvg)
end

local function GetVisibleXLabels(trendData, scrollOffset, viewportWidth)
    if trendData.mode ~= "candles" then
        return trendData.xLabels
    end
    local contentWidth = #trendData.points * TREND_CANDLE_SLOT
    local latest = contentWidth - viewportWidth
    local aligned = math.max(math.min(scrollOffset, math.max(0, latest)), math.min(0, latest))
    local firstIndex = math.tointeger(math.max(1, math.floor(aligned / TREND_CANDLE_SLOT) + 1)) or 1
    local lastIndex = math.tointeger(math.min(#trendData.points, math.ceil((aligned + viewportWidth) / TREND_CANDLE_SLOT))) or #trendData.points
    if lastIndex < firstIndex then
        firstIndex = math.max(1, #trendData.points - 4)
        lastIndex = #trendData.points
    end
    local labels = {}
    local span = math.max(1, lastIndex - firstIndex)
    for step = 0, 4 do
        local index = firstIndex + (math.tointeger(math.floor(span * step / 4)) or 0)
        labels[step + 1] = FormatMonthDay(trendData.points[index].timestamp)
    end
    return labels
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
            fontColor = { 145, 145, 145, 255 },
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
            fontColor = { 145, 145, 145, 255 },
            textAlign = "right",
        })
    end
end

local function RefreshTrendChart()
    if not refs.trendPlot then
        return
    end

    refs.trendPlot:ClearChildren()
    local basePrice = state.selectedListing and state.selectedListing.highestBid or 8
    local trendData = GetTrendData(state.trendPeriod, basePrice)
    local minValue = math.huge
    local maxValue = -math.huge
    for _, point in ipairs(trendData.points) do
        minValue = math.min(minValue, point.value)
        maxValue = math.max(maxValue, point.value)
    end

    local isDay = state.trendPeriod == "day"
    if not isDay then
        state.trendScrollOffset = 0
        state.trendStickToLatest = true
    else
        if state.trendStickToLatest then
            state.trendScrollOffset = math.max(0, #trendData.points * TREND_CANDLE_SLOT)
        end
        local visibleCount = math.max(1, math.tointeger(math.floor(280 / TREND_CANDLE_SLOT)) or 1)
        local startIndex = math.max(1, #trendData.points - visibleCount + 1)
        minValue = math.huge
        maxValue = -math.huge
        for index = startIndex, #trendData.points do
            minValue = math.min(minValue, trendData.points[index].value)
            maxValue = math.max(maxValue, trendData.points[index].value)
        end
    end

    local grid = UI.Panel {
        width = "100%",
        height = 224,
        marginLeft = 48,
        marginRight = 8,
        position = "relative",
        backgroundColor = { 252, 252, 252, 255 },
        borderRadius = 6,
        overflow = "hidden",
    }
    for row = 0, 4 do
        grid:AddChild(UI.Panel {
            position = "absolute",
            left = 0,
            top = 10 + row * 47,
            width = "100%",
            height = 1,
            backgroundColor = { 232, 232, 232, 255 },
        })
    end
    for column = 0, 5 do
        grid:AddChild(UI.Panel {
            position = "absolute",
            left = (column * 20) .. "%",
            top = 0,
            width = 1,
            height = "100%",
            backgroundColor = { 238, 238, 238, 180 },
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
        candles = BuildCandles(trendData.points),
        xLabels = trendData.xLabels,
        chartMode = isDay and "candles" or "line",
        axisStart = trendData.axisStart,
        axisEnd = trendData.axisEnd,
        slotWidth = TREND_CANDLE_SLOT,
        scrollOffset = isDay and state.trendScrollOffset or 0,
        stickToLatest = isDay and state.trendStickToLatest,
        onScrollChange = function(offset, stickToLatest)
            state.trendScrollOffset = offset
            state.trendStickToLatest = stickToLatest
            if refs.trendChart then
                local metrics = refs.trendChart:GetChartMetrics()
                RefreshTrendXAxis(GetVisibleXLabels(trendData, offset, metrics.width))
                local visMin, visMax = refs.trendChart:GetVisibleRange(minValue, maxValue)
                RefreshTrendYAxis(visMin, visMax)
            end
        end,
        lineColor = { 126, 88, 230, 255 },
        fillColor = { 126, 88, 230, 48 },
    }
    grid:AddChild(refs.trendChart)
    refs.trendPlot:AddChild(grid)

    refs.trendYAxis = UI.Panel {
        position = "absolute",
        left = 0,
        top = 0,
        width = 46,
        height = 224,
        justifyContent = "spaceBetween",
        paddingVertical = 2,
        pointerEvents = "none",
    }
    RefreshTrendYAxis(minValue, maxValue)
    refs.trendPlot:AddChild(refs.trendYAxis)

    refs.trendXAxis = UI.Panel {
        width = "100%",
        height = 24,
        marginLeft = 48,
        marginRight = 8,
        flexDirection = "row",
        justifyContent = "spaceBetween",
        paddingTop = 7,
        pointerEvents = "none",
    }
    local xLabels = isDay and GetVisibleXLabels(trendData, state.trendScrollOffset, 280) or trendData.xLabels
    RefreshTrendXAxis(xLabels)
    refs.trendPlot:AddChild(refs.trendXAxis)
    if refs.trendHint then
        refs.trendHint:SetText(isDay and "左右滑动查看全部日期 · 长按显示十字线" or "当天 00:00-24:00 · 曲线画到当前时刻")
    end

    if refs.minuteTrendButton then
        refs.minuteTrendButton:SetStyle({
            backgroundColor = state.trendPeriod == "minute" and { 126, 88, 230, 255 } or { 245, 245, 245, 255 },
            textColor = state.trendPeriod == "minute" and { 255, 255, 255, 255 } or { 100, 100, 100, 255 },
        })
    end
    if refs.dayTrendButton then
        refs.dayTrendButton:SetStyle({
            backgroundColor = state.trendPeriod == "day" and { 126, 88, 230, 255 } or { 245, 245, 245, 255 },
            textColor = state.trendPeriod == "day" and { 255, 255, 255, 255 } or { 100, 100, 100, 255 },
        })
    end
    print(string.format("[Market] 趋势图刷新: %s, 点数=%d, 起点=%s", trendData.title, #trendData.points, FormatMonthDay(trendData.points[1].timestamp)))
end

local function SetTrendPeriod(period)
    state.trendPeriod = period
    state.trendScrollOffset = 0
    state.trendStickToLatest = true
    print("[Market] 趋势图切换: " .. (period == "minute" and "分K" or "日K"))
    RefreshTrendChart()
end

local function CreateTrendChart()
    local chart = UI.Panel {
        width = "100%",
        height = 348,
        marginTop = 12,
        padding = 12,
        backgroundColor = { 255, 255, 255, 255 },
        borderWidth = 1,
        borderColor = { 232, 232, 232, 255 },
        overflow = "hidden",
    }

    local chartHeader = UI.Panel {
        width = "100%",
        height = 38,
        flexDirection = "row",
        alignItems = "center",
        justifyContent = "spaceBetween",
        marginBottom = 8,
    }
    chartHeader:AddChild(UI.Label { text = "价格走势", fontSize = 18, fontColor = { 35, 35, 35, 255 } })
    local periodSwitch = UI.Panel { flexDirection = "row", gap = 6, height = 30 }
    refs.minuteTrendButton = UI.Button {
        text = "分K",
        width = 52,
        height = 30,
        padding = 0,
        fontSize = 11,
        backgroundColor = { 224, 166, 30, 255 },
        textColor = { 255, 255, 255, 255 },
        onClick = function() SetTrendPeriod("minute") end,
    }
    refs.dayTrendButton = UI.Button {
        text = "日K",
        width = 52,
        height = 30,
        padding = 0,
        fontSize = 11,
        backgroundColor = { 245, 245, 245, 255 },
        textColor = { 100, 100, 100, 255 },
        onClick = function() SetTrendPeriod("day") end,
    }
    periodSwitch:AddChild(refs.minuteTrendButton)
    periodSwitch:AddChild(refs.dayTrendButton)
    chartHeader:AddChild(periodSwitch)
    chart:AddChild(chartHeader)

    refs.trendPlot = UI.Panel {
        width = "100%",
        flexGrow = 1,
        flexShrink = 1,
    }
    chart:AddChild(refs.trendPlot)
    refs.trendHint = UI.Label {
        text = "日K 左右滑动查看全部日期 · 长按显示十字线",
        width = "100%",
        height = 16,
        fontSize = 10,
        fontColor = { 160, 160, 160, 255 },
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
    refs.detailProductImage:SetStyle({ backgroundImage = GetListingImage(listing) })
end

local function ShowListingDetail(listing)
    state.selectedListing = listing
    state.trendStickToLatest = true
    if refs.marketView then refs.marketView:SetVisible(false) end
    if refs.detailView then refs.detailView:SetVisible(true) end
    SetDetailProductImage(listing)
    local currentRarity = GetRarity(listing.rarity)
    if refs.detailRarity then
        refs.detailRarity:SetStyle({ fontColor = currentRarity.color })
        refs.detailRarity:SetText(listing.rarityName)
    end
    if refs.detailTopTitle then refs.detailTopTitle:SetText("商品详情") end
    if refs.detailTitle then refs.detailTitle:SetText("香蕉 · " .. listing.sellerName) end
    if refs.detailRarity then refs.detailRarity:SetText(listing.rarityName) end
    if refs.detailPrice then refs.detailPrice:SetText("¥" .. FormatNumber(listing.highestBid)) end
    if refs.detailDemand then refs.detailDemand:SetText(tostring(listing.wants) .. " 人出价") end
    if refs.detailSellerName then refs.detailSellerName:SetText(listing.sellerName) end
    RefreshTrendChart()
    print("[Market] 打开商品详情: " .. listing.sellerName)
end

local function CloseListingDetail()
    if refs.detailView then refs.detailView:SetVisible(false) end
    if refs.marketView then refs.marketView:SetVisible(true) end
end

local function RefreshMarket()
    if not refs.marketContent then
        return
    end
    refs.marketContent:ClearChildren()

    local marketGrid = UI.Panel {
        width = "100%",
        flexDirection = "column",
        gap = 14,
        overflow = "hidden",
    }
    refs.marketContent:AddChild(marketGrid)

    for index, listing in ipairs(state.marketListings) do
        local rarity = GetRarity(listing.rarity)
        local row = math.floor((index - 1) / 2) + 1
        local rowPanel = marketGrid:GetChildAt(row)
        if not rowPanel then
            rowPanel = UI.Panel {
                width = "100%",
                flexDirection = "row",
                gap = 12,
                flexShrink = 1,
            }
            marketGrid:AddChild(rowPanel)
        end
        local card = UI.Panel {
            flex = 1,
            flexShrink = 1,
            minWidth = 0,
            height = 270,
            gap = 3,
            backgroundColor = { 255, 255, 255, 255 },
        }
        card:AddChild(UI.Panel {
            width = "100%",
            height = 142,
            backgroundColor = { 224, 224, 224, 255 },
            backgroundImage = GetListingImage(listing),
            backgroundFit = "contain",
        })
        card:AddChild(UI.Label { text = rarity.name, width = "100%", height = 24, fontSize = 11, fontColor = { 45, 45, 45, 255 }, textAlign = "left", paddingHorizontal = 4 })
        card:AddChild(UI.Label { text = "香蕉 · 个人挂单", width = "100%", height = 22, fontSize = 11, fontColor = { 30, 30, 30, 255 }, textAlign = "left", paddingHorizontal = 4 })
        local marketPriceRow = UI.Panel { width = "100%", height = 46, flexDirection = "row", justifyContent = "spaceBetween", alignItems = "center", paddingHorizontal = 8 }
        local priceBlock = UI.Panel { flexGrow = 1, flexShrink = 1, gap = 1 }
        priceBlock:AddChild(UI.Label { text = "最高出价", fontSize = 9, fontColor = { 145, 145, 145, 255 } })
        priceBlock:AddChild(UI.Label { text = "¥" .. FormatNumber(listing.highestBid), fontSize = 15, fontColor = { 194, 145, 8, 255 } })
        marketPriceRow:AddChild(priceBlock)
        local bidCountBlock = UI.Panel { width = 72, alignItems = "flex-end", gap = 1 }
        bidCountBlock:AddChild(UI.Label { text = "出价人数", fontSize = 9, fontColor = { 145, 145, 145, 255 }, textAlign = "right" })
        bidCountBlock:AddChild(UI.Label { text = tostring(listing.wants) .. " 人", fontSize = 11, fontWeight = "bold", fontColor = { 75, 75, 75, 255 }, textAlign = "right" })
        marketPriceRow:AddChild(bidCountBlock)
        card:AddChild(marketPriceRow)
        card:AddChild(UI.Button {
            text = "查看",
            variant = "secondary",
            width = "92%",
            height = 30,
            fontSize = 10,
            marginHorizontal = 4,
            onClick = function()
                ShowListingDetail(listing)
            end,
        })
        rowPanel:AddChild(card)
    end

    UpdateLabel(refs.marketStatusLabel, "市场")
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
    detailTop:AddChild(UI.Button { text = "返回", variant = "secondary", width = 58, height = 38, fontSize = 12, padding = 0, onClick = CloseListingDetail })
    refs.detailTopTitle = UI.Label { text = "商品详情", flexGrow = 1, fontSize = 20, fontColor = { 35, 35, 35, 255 } }
    detailTop:AddChild(refs.detailTopTitle)
    refs.detailView:AddChild(detailTop)
    local detailInfo = UI.Panel {
        width = "100%",
        height = 250,
        padding = 14,
        backgroundColor = { 255, 255, 255, 255 },
        borderWidth = 1,
        borderColor = { 225, 225, 225, 255 },
    }
    detailInfo:AddChild(UI.Label { text = "BANANA MARKET", fontSize = 12, fontColor = { 130, 130, 130, 255 }, marginBottom = 8 })
    local infoRow = UI.Panel { width = "100%", flexDirection = "row", gap = 14, alignItems = "center" }
    refs.detailProductImage = UI.Panel {
        width = 138,
        height = 112,
        backgroundColor = { 224, 224, 224, 255 },
        backgroundImage = "image/banana_normal_20260904085931.png",
        backgroundFit = "contain",
    }
    infoRow:AddChild(refs.detailProductImage)
    local detailMeta = UI.Panel { flexGrow = 1, flexShrink = 1, gap = 6 }
    refs.detailTitle = UI.Label { text = "香蕉商品", fontSize = 20, fontColor = { 35, 35, 35, 255 } }
    refs.detailRarity = UI.Label { text = "品质", fontSize = 14, fontColor = { 75, 75, 75, 255 } }
    refs.detailPrice = UI.Label { text = "¥0", fontSize = 26, fontWeight = "bold", fontColor = { 194, 145, 8, 255 } }
    refs.detailDemand = UI.Label { text = "0 人想要", fontSize = 13, fontColor = { 120, 120, 120, 255 } }
    detailMeta:AddChild(refs.detailTitle)
    detailMeta:AddChild(refs.detailRarity)
    detailMeta:AddChild(refs.detailPrice)
    detailMeta:AddChild(refs.detailDemand)
    infoRow:AddChild(detailMeta)
    detailInfo:AddChild(infoRow)
    refs.detailView:AddChild(detailInfo)

    local sellerRow = UI.Panel { width = "100%", height = 74, flexDirection = "row", alignItems = "center", gap = 10, paddingVertical = 10 }
    local sellerAvatar = UI.Panel {
        width = 44,
        height = 44,
        backgroundColor = { 25, 25, 25, 255 },
        backgroundImage = "image/edited_seller_avatar_yellow_20260905023748.png",
        backgroundFit = "contain",
    }
    sellerRow:AddChild(sellerAvatar)
    refs.detailSellerName = UI.Label { text = "卖家", fontSize = 15, fontColor = { 45, 45, 45, 255 } }
    sellerRow:AddChild(refs.detailSellerName)
    sellerRow:AddChild(UI.Label { text = "在线卖家", fontSize = 12, fontColor = { 130, 130, 130, 255 }, marginLeft = "auto" })
    refs.detailView:AddChild(sellerRow)

    refs.detailView:AddChild(CreateTrendChart())
    refs.detailView:AddChild(UI.Button { text = "立即求购", width = "100%", height = 48, marginTop = 10, variant = "primary", onClick = function() print("[Market] 提交求购") end })
    return refs.detailView
end

local function RefreshAll()
    UpdateProgress()
    RefreshInventory()
    RefreshMarket()
end

local function AddPoint(amount, source)
    state.points = state.points + amount
    state.totalPoints = state.totalPoints + amount
    state.totalClicks = state.totalClicks + (source == "手动" and amount or 0)
    ShowGain(amount, source)

    while state.points >= CONFIG.dropCost do
        state.points = state.points - CONFIG.dropCost
        local rarity = RollRarity()
        AddBanana(rarity)
        RefreshInventory()
    end
    UpdateProgress()
end

local function SwitchTab(tab)
    state.selectedTab = tab
    if refs.homeView then refs.homeView:SetVisible(tab == "home") end
    if refs.inventoryView then refs.inventoryView:SetVisible(tab == "inventory") end
    if refs.marketView then refs.marketView:SetVisible(tab == "market") end
    if refs.detailView then refs.detailView:SetVisible(false) end

    if refs.statsBar then
        refs.statsBar:SetVisible(tab == "home")
    end
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
        backgroundColor = { 248, 248, 246, 255 },
    }
    refs.statsBar = stats
    refs.totalPointsLabel = UI.Label { text = "", fontSize = 56, fontColor = { 12, 12, 12, 255 }, fontWeight = "bold", textAlign = "center" }
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
            AddPoint(1, "手动")
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
        fontColor = { 238, 176, 0, 255 },
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
    local inventoryHeader = UI.Panel { width = "100%", height = 0, overflow = "hidden" }
    refs.inventoryView:AddChild(inventoryHeader)
    refs.inventoryGrid = UI.Panel {
        width = "100%",
        flex = 1,
        flexShrink = 1,
        flexDirection = "column",
        gap = 12,
        overflow = "hidden",
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
    marketHeader:AddChild(UI.Label { text = "市场", fontSize = 20, fontColor = { 35, 35, 35, 255 } })
    marketHeader:AddChild(UI.Label { text = "|", fontSize = 16, fontColor = { 180, 180, 180, 255 } })
    marketHeader:AddChild(UI.Label { text = "手续费 2%", fontSize = 12, fontColor = { 150, 120, 40, 255 } })
    refs.marketView:AddChild(marketHeader)

    refs.marketStatusLabel = UI.Label { text = "", fontSize = 12, fontColor = { 120, 120, 120, 255 }, marginBottom = 8 }
    refs.marketView:AddChild(refs.marketStatusLabel)

    refs.marketContent = UI.Panel {
        width = "100%",
        flexGrow = 1,
        flexBasis = 0,
        flexShrink = 1,
        overflow = "hidden",
    }
    refs.marketView:AddChild(refs.marketContent)
    return refs.marketView
end

local function CreateBottomNav()
    local nav = UI.Panel {
        width = "100%",
        flexDirection = "row",
        gap = 12,
        paddingHorizontal = 18,
        paddingVertical = 12,
        marginTop = 8,
        backgroundColor = { 255, 255, 255, 255 },
        borderRadius = 28,
        borderWidth = 1,
        borderColor = { 232, 232, 232, 255 },
        boxShadow = { { x = 0, y = 8, blur = 20, color = { 0, 0, 0, 24 } } },
    }
    nav:AddChild(UI.Button { text = "●  香蕉", variant = "secondary", flexGrow = 1, flexShrink = 1, height = 48, backgroundColor = { 255, 255, 255, 255 }, textColor = { 18, 18, 18, 255 }, onClick = function() SwitchTab("home") end })
    nav:AddChild(UI.Button { text = "库存", variant = "secondary", flexGrow = 1, flexShrink = 1, height = 48, backgroundColor = { 255, 255, 255, 255 }, textColor = { 18, 18, 18, 255 }, onClick = function() SwitchTab("inventory") end })
    nav:AddChild(UI.Button { text = "市场", variant = "secondary", flexGrow = 1, flexShrink = 1, height = 48, backgroundColor = { 255, 255, 255, 255 }, textColor = { 18, 18, 18, 255 }, onClick = function() SwitchTab("market") end })
    return nav
end

local function CreateUI()
    UI.Init({
        theme = "default-dark",
        scale = UI.Scale.DEFAULT,
    })

    state.marketListings = {
        { rarity = "common", rarityName = "优良 · Common", sellerName = "黄香蕉商店", wants = 18, highestBid = 8, remaining = 2640 },
        { rarity = "uncommon", rarityName = "罕见 · Uncommon", sellerName = "香蕉研究所", wants = 6, highestBid = 42, remaining = 1870 },
        { rarity = "rare", rarityName = "稀有 · Rare", sellerName = "金色果园", wants = 2, highestBid = 160, remaining = 3210 },
        { rarity = "epic", rarityName = "史诗 · Epic", sellerName = "传说收藏家", wants = 1, highestBid = 720, remaining = 3480 },
    }

    local content = UI.Panel {
        width = "100%",
        height = "100%",
        flexDirection = "column",
        flexShrink = 1,
        paddingHorizontal = 20,
        paddingVertical = 16,
        gap = 8,
        backgroundColor = { 248, 248, 246, 255 },
        children = {
            CreateStatsBar(),
            CreateHomeView(),
            CreateInventoryView(),
            CreateMarketView(),
            CreateDetailView(),
            CreateBottomNav(),
        },
    }

    local root = UI.Panel {
        width = "100%",
        height = "100%",
        backgroundColor = { 248, 248, 246, 255 },
        children = {
            UI.SafeAreaView {
                width = "100%",
                height = "100%",
                edges = { "top", "bottom" },
                pointerEvents = "box-none",
                children = { content },
            },
        },
    }
    UI.SetRoot(root)
    RefreshAll()
    print("[Banana] UI 初始化完成，竖屏 Yoga UI 原型启动")
end

function Start()
    graphics.windowTitle = CONFIG.title
    graphics:SetOrientations("Portrait")
    print("[Banana] 请求默认竖屏方向")
    math.randomseed(os.time())
    CreateUI()
    SubscribeToEvent("Update", "HandleUpdate")
    print("[Banana] 游戏启动：每秒自动 +1，点击香蕉手动 +1，300 点掉落")
end

function Stop()
    UI.Shutdown()
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local timeStep = eventData["TimeStep"]:GetFloat()
    state.elapsed = state.elapsed + timeStep
    state.secondAccumulator = state.secondAccumulator + timeStep

    while state.secondAccumulator >= CONFIG.autoGainInterval do
        state.secondAccumulator = state.secondAccumulator - CONFIG.autoGainInterval
        AddPoint(1, "自动")
    end

    for _, listing in ipairs(state.marketListings) do
        listing.remaining = math.max(0, listing.remaining - timeStep)
    end
end
