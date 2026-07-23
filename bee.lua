local component = require("component")
--local serialization = require("serialization")

local strategy, mutations, device

local function initialize()
    if not component.inventory_controller then
        error("缺少物品栏交互升级")
    elseif not component.robot then
        error("此程序需要在机器人上运行")
    elseif component.robot.inventorySize() < 32 then
        error("需要2个物品栏升级")
    elseif not component.crafting then
        error("缺少合成升级")
    elseif not component.beekeeper then
        error("缺少养蜂员升级")
    elseif not component.database then
        error("缺少数据库升级")
    elseif not component.upgrade_me then
        error("缺少ME升级")
    elseif not component.upgrade_me.isLinked() then
        error("未连接到ME网络")
    elseif component.inventory_controller.getInventoryName(0) ~= "tile.oc.charger" then
        error("机器人初始位置应位于OC充电器上方")
    end
    print("蜂箱交互兼容层 v3")
    local controller = component.inventory_controller
    local dropSupported = type(controller.dropIntoSlot) == "function"
    local suckSupported = type(controller.suckFromSlot) == "function"
    local address = type(controller.address) == "string" and controller.address or "unknown"
    print("物品栏交互升级: address=" .. address .. ", dropIntoSlot=" .. tostring(dropSupported) .. ", suckFromSlot=" .. tostring(suckSupported))
    if type(component.methods) == "function" and address ~= "unknown" then
        local methodsSuccess, methods = pcall(component.methods, address)
        if methodsSuccess and type(methods) == "table" then
            local methodNames = {}
            for name, available in pairs(methods) do
                if available then
                    table.insert(methodNames, tostring(name))
                end
            end
            table.sort(methodNames)
            print("物品栏交互升级API: " .. table.concat(methodNames, ","))
        end
    end
    print("加载中...")
    mutations = require("mutations")
    device = require("device")
    strategy = require("strategy")
end

local function main()
    print("请输入需要培育的蜜蜂:")
    local species = io.read()
    if mutations[species] then
        strategy.task(species)
    else
        error("未发现突变路径")
    end
end

local suc, err = pcall(initialize)
if suc then
    suc, err = pcall(main)
    if not suc then
        print("发生错误: " .. err)
        device.destruct()
    end
else
    print("发生错误: " .. err)
end
