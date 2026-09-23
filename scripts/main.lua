--[[
香蕉收集屋 - 入口

这是真正的联网游戏：服务端持有市场挂单和每个账户的仓库，客户端只负责显示与输入。

    scripts/main.lua            入口，按运行模式分流
    scripts/network/Shared.lua  两端共用：稀有度、事件名、价格工具
    scripts/network/Server.lua  权威逻辑：市场 + 每账户仓库
    scripts/network/Client.lua  UI 与输入，数据来自服务端快照

玩家身份用认证后的 user_id，所以换个客户端连上来看到的是同一个市场，
同一个账号重连回来仓库里的东西也还在。
]]

local Module = nil

function Start()
    if IsServerMode() then
        print("[Banana] SERVER mode")
        Module = require("network.Server")
    elseif IsNetworkMode() then
        print("[Banana] CLIENT mode")
        Module = require("network.Client")
    else
        print("[Banana] 需要联网模式运行（服务端 + 客户端）")
        return
    end

    Module.Start()
end

function Stop()
    if Module and Module.Stop then
        Module.Stop()
    end
end
