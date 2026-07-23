local M = {}

local bot = require("bot")
local doUntil = require("doUntil")

local robot = require("robot")

function M.swingDown(tool)
    if tool == "cell" then
        if not bot.inventory[0] or bot.inventory[0].name ~= "IC2:itemCellEmpty" then
            robot.select(
                doUntil(function()
                    return bot.checkItem({name = "IC2:itemCellEmpty", damage = 0}, 1)
                end, "缺少空单元")
            )
            bot.equip()
        end
        if not robot.useDown() then
            error("使用空单元拆除基石失败")
        end
        bot.inventory[0] = nil
    elseif tool == "bucket" then
        if not bot.inventory[0] or bot.inventory[0].name ~= "minecraft:bucket" then
            robot.select(
                doUntil(function()
                    return bot.checkItem({name = "minecraft:bucket"}, 1)
                end, "缺少桶")
            )
            bot.equip()
        end
        if not robot.useDown() then
            error("使用桶拆除基石失败")
        end
        bot.inventory[0] = nil
    elseif tool == nil then
        if not bot.inventory[0] or bot.inventory[0].name ~= "gregtech:gt.Tool_Vajra" then
            robot.select(
                doUntil(function()
                    return bot.checkItem({name = "gregtech:gt.Tool_Vajra"}, 1)
                end, "缺少金刚杵")
            )
            bot.equip()
        end
        if not (bot.inventory[0].enchantments and bot.inventory[0].enchantments[1] and bot.inventory[0].enchantments[1].name == "enchantment.untouching") then
            robot.useUp(nil, true)
            bot.inventory[0].enchantments = {{name = "enchantment.untouching", level = 1, label = "精准采集"}}
        end
        local _1, _2 = robot.swingDown()
        if _1 and _2 == "block" then
            os.sleep(0.01)
        end
    else
        error("错误的调用tools.swingDown()")
    end
end

function M.placeDown(item)
    if not item or not item.name then
        error("错误的调用tools.placeDown()")
    end
    if item.tool then
        if item.tool == "cell" then
            robot.select(
                doUntil(function()
                    return bot.checkItem({name = item.name, damage = item.damage}, 1)
                end, "缺少"..(item.label or item.name))
            )
            bot.down()
            local suc = robot.detect()
            if suc then
                for i = 1,3 do
                    bot.turnLeft()
                    suc = robot.detect()
                    if not suc then
                        break
                    end
                end
            end
            if suc then
                error("放置"..(item.label or item.name or "").."失败")
            end
            bot.forward()
            bot.turnRight()
            bot.turnRight()
            if not robot.placeDown() then--是的，IC2单元的放置逻辑就是这么神秘
                error("放置"..(item.label or item.name).."失败")
            end
            bot.up()
            bot.forward()
            bot.inventory[0] = nil
        elseif item.tool == "bucket" then
            robot.select(
                doUntil(function()
                    return bot.checkItem({name = item.name, damage = item.damage}, 1)
                end, "缺少"..(item.label or item.name))
            )
            bot.equip()
            if not robot.useDown() then
                error("放置"..(item.label or item.name).."失败")
            end
            bot.inventory[0] = {name = "minecraft:bucket"}
        else
            error("错误的调用tools.placeDown()")
        end
    else
        robot.select(
            doUntil(function()
                return bot.checkItem({name = item.name, damage = item.damage}, 1)
            end, "缺少"..(item.label or item.name))
        )
        if not robot.placeDown() then
            error("放置"..(item.label or item.name).."失败")
        end
    end
end

return M