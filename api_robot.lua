-- api_robot.lua v3 — 无状态物理抽象层
-- OpenComputers Lua 5.3 / RAM 2048KB
-- 冻结协议：不保存业务状态，不创建 table，全部整数返回

-- ==============================
-- 零、组件句柄缓存（模块加载期分配）
-- ==============================
local component = require("component")
local computer  = require("computer")
local robot     = require("robot")

local inv_ctrl   = component.inventory_controller
local upgrade_me = component.upgrade_me
local database_c = component.database
local beekeeper  = component.beekeeper

-- ==============================
-- 一、错误码（冻结）
-- ==============================
local ERR_OK                = 0
local ERR_LOW_ENERGY        = 1
local ERR_ME_OFFLINE        = 2
local ERR_INV_FULL          = 3
local ERR_OBSTRUCTED        = 4
local ERR_APIARY_INVALID    = 5
local ERR_TIMEOUT           = 6
local ERR_COMPONENT_MISSING = 7
local ERR_ACTION_BLOCK      = 8
local ERR_UNKNOWN           = 9

-- ==============================
-- 二、Action Guard 位定义（冻结）
-- ==============================
local MOVING           = 0
local ACCESSING_ME     = 1
local ACCESSING_APIARY = 2
local CALIBRATING      = 3

-- ==============================
-- 三、状态（唯一允许的整数变量）
-- ==============================
local pos_x   = 0
local pos_y   = 0
local pos_z   = 0
local pos_dir = 0   -- 0=N 1=E 2=S 3=W
local action_flags = 0

-- ==============================
-- 四、ME Database NBT 模板（冻结协议）
-- ==============================
local NBT_TEMPLATE_DRONE    = '{name:"Forestry:beeDroneGE",tag:{Species:"%s"}}'
local NBT_TEMPLATE_PRINCESS = '{name:"Forestry:beePrincessGE",tag:{Species:"%s"}}'

-- ==============================
-- 五、内部辅助
-- ==============================

-- 能量检查
local function _energy_ok()
    local ok, val = pcall(function() return computer.energy() end)
    if not ok then return false end
    return val >= 50
end

-- 尝试获取某个 Action 锁
local function _try_lock(bit)
    if (action_flags & (1 << bit)) ~= 0 then
        return false
    end
    action_flags = action_flags | (1 << bit)
    return true
end

-- 释放某个 Action 锁
local function _release_lock(bit)
    action_flags = action_flags & ~(1 << bit)
end

-- 面向目标方向（纯位运算），返回 err_code
local function _face(target_dir)
    local diff = (target_dir - pos_dir) & 3
    if diff == 0 then
        return ERR_OK
    elseif diff == 1 then
        local ok = pcall(function() robot.turnRight() end)
        if not ok then return ERR_UNKNOWN end
        pos_dir = (pos_dir + 1) & 3
        return ERR_OK
    elseif diff == 3 then
        local ok = pcall(function() robot.turnLeft() end)
        if not ok then return ERR_UNKNOWN end
        pos_dir = (pos_dir - 1) & 3
        return ERR_OK
    else -- diff == 2
        local ok1 = pcall(function() robot.turnRight() end)
        if not ok1 then return ERR_UNKNOWN end
        pos_dir = (pos_dir + 1) & 3
        local ok2 = pcall(function() robot.turnRight() end)
        if not ok2 then return ERR_UNKNOWN end
        pos_dir = (pos_dir + 1) & 3
        return ERR_OK
    end
end

-- 向当前朝向移动一步，返回 err_code
local function _step_forward()
    local ok, result = pcall(function() return robot.forward() end)
    if not ok then return ERR_UNKNOWN end
    if not result then return ERR_OBSTRUCTED end
    if pos_dir == 0 then
        pos_z = pos_z - 1
    elseif pos_dir == 1 then
        pos_x = pos_x + 1
    elseif pos_dir == 2 then
        pos_z = pos_z + 1
    else -- pos_dir == 3
        pos_x = pos_x - 1
    end
    return ERR_OK
end

-- 向指定水平方向移动一步，返回 err_code
local function _move_step_h(dir)
    local ec = _face(dir)
    if ec ~= ERR_OK then return ec end
    if not _energy_ok() then return ERR_LOW_ENERGY end
    return _step_forward()
end

-- 竖直移动一步，返回 err_code
local function _move_step_v(dy)
    if not _energy_ok() then return ERR_LOW_ENERGY end
    local ok, result
    if dy > 0 then
        ok, result = pcall(function() return robot.up() end)
    else
        ok, result = pcall(function() return robot.down() end)
    end
    if not ok then return ERR_UNKNOWN end
    if not result then return ERR_OBSTRUCTED end
    pos_y = pos_y + dy
    return ERR_OK
end

-- 底层的移动到绝对坐标
local function _move_to_abs(tx, ty, tz)
    if not _try_lock(MOVING) then
        return false, ERR_ACTION_BLOCK, 0
    end

    local ec

    -- 竖直轴
    while pos_y ~= ty do
        local dy = (ty > pos_y) and 1 or -1
        ec = _move_step_v(dy)
        if ec ~= ERR_OK then
            _release_lock(MOVING)
            return false, ec, 0
        end
    end

    -- X 轴
    while pos_x ~= tx do
        local dir
        if tx > pos_x then dir = 1 else dir = 3 end
        ec = _move_step_h(dir)
        if ec ~= ERR_OK then
            _release_lock(MOVING)
            return false, ec, 0
        end
    end

    -- Z 轴
    while pos_z ~= tz do
        local dir
        if tz > pos_z then dir = 2 else dir = 0 end
        ec = _move_step_h(dir)
        if ec ~= ERR_OK then
            _release_lock(MOVING)
            return false, ec, 0
        end
    end

    os.sleep(0.05)
    _release_lock(MOVING)
    return true, ERR_OK, 0
end

-- ==============================
-- 六、Public API
-- ==============================

-- Movement

function api_robot_move_to(tx, ty, tz)
    tx = math.floor(tonumber(tx) or pos_x)
    ty = math.floor(tonumber(ty) or pos_y)
    tz = math.floor(tonumber(tz) or pos_z)
    return _move_to_abs(tx, ty, tz)
end

function api_robot_move(dx, dy, dz)
    dx = math.floor(tonumber(dx) or 0)
    dy = math.floor(tonumber(dy) or 0)
    dz = math.floor(tonumber(dz) or 0)
    return _move_to_abs(pos_x + dx, pos_y + dy, pos_z + dz)
end

function api_robot_get_position()
    return pos_x, pos_y, pos_z, pos_dir
end

-- ME Network

function api_robot_sync_database(db_slot, species_name, target_type)
    if not _try_lock(ACCESSING_ME) then
        return false, ERR_ACTION_BLOCK, 0
    end

    if not upgrade_me then
        _release_lock(ACCESSING_ME)
        return false, ERR_COMPONENT_MISSING, 0
    end
    local ok_linked = pcall(function() return upgrade_me.isLinked() end)
    if not ok_linked then
        _release_lock(ACCESSING_ME)
        return false, ERR_ME_OFFLINE, 0
    end

    local template
    if target_type == 0 then
        template = string.format(NBT_TEMPLATE_PRINCESS, species_name)
    else
        template = string.format(NBT_TEMPLATE_DRONE, species_name)
    end

    local ok = pcall(function()
        robot.select(db_slot)
        -- TODO: replace with actual database component call if API differs
        if database_c and database_c.setSearchString then
            database_c.setSearchString(template)
        end
        upgrade_me.requestItems(template, 1)
    end)
    os.sleep(0.05)
    _release_lock(ACCESSING_ME)
    if not ok then
        return false, ERR_UNKNOWN, 0
    end
    return true, ERR_OK, 0
end

function api_robot_fetch_by_db(db_slot, amount, target_slot)
    amount = math.floor(tonumber(amount) or 1)
    if amount < 1 then amount = 1 end
    target_slot = math.floor(tonumber(target_slot) or 1)

    if not _try_lock(ACCESSING_ME) then
        return false, ERR_ACTION_BLOCK, 0
    end

    if not upgrade_me then
        _release_lock(ACCESSING_ME)
        return false, ERR_COMPONENT_MISSING, 0
    end

    local ok = pcall(function()
        robot.select(db_slot)
        -- TODO: replace with actual ME requestItems call if API differs
        upgrade_me.requestItems(nil, amount, target_slot)
    end)
    os.sleep(0.05)
    _release_lock(ACCESSING_ME)
    if not ok then
        return false, ERR_UNKNOWN, 0
    end
    return true, ERR_OK, 0
end

function api_robot_push_all_to_me()
    if not _try_lock(ACCESSING_ME) then
        return false, ERR_ACTION_BLOCK, 0
    end

    if not upgrade_me then
        _release_lock(ACCESSING_ME)
        return false, ERR_COMPONENT_MISSING, 0
    end
    local ok_linked = pcall(function() return upgrade_me.isLinked() end)
    if not ok_linked then
        _release_lock(ACCESSING_ME)
        return false, ERR_ME_OFFLINE, 0
    end

    local inv_size = 32
    local ok_sz, sz = pcall(function() return robot.inventorySize() end)
    if ok_sz then inv_size = sz end

    local any_full = false
    for slot = 1, inv_size do
        local ok_sel = pcall(function() robot.select(slot) end)
        if ok_sel then
            local has_item = false
            pcall(function()
                local s = inv_ctrl.getStackInInternalSlot(slot)
                if s then has_item = true end
            end)
            if has_item then
                local ok_send = pcall(function() upgrade_me.sendItems() end)
                if not ok_send then
                    any_full = true
                end
            end
        end
    end
    os.sleep(0.05)
    _release_lock(ACCESSING_ME)
    if any_full then
        return false, ERR_INV_FULL, 0
    end
    return true, ERR_OK, 0
end

-- Inventory

function api_robot_get_empty_slot()
    local inv_size = 32
    local ok_sz, sz = pcall(function() return robot.inventorySize() end)
    if ok_sz then inv_size = sz end

    for slot = 1, inv_size do
        local empty = true
        pcall(function()
            local s = inv_ctrl.getStackInInternalSlot(slot)
            if s then empty = false end
        end)
        if empty then
            return true, ERR_OK, slot
        end
    end
    return false, ERR_INV_FULL, 0
end

function api_robot_clear_inventory()
    local inv_size = 32
    local ok_sz, sz = pcall(function() return robot.inventorySize() end)
    if ok_sz then inv_size = sz end

    for slot = 1, inv_size do
        local has_item = false
        pcall(function()
            local s = inv_ctrl.getStackInInternalSlot(slot)
            if s then has_item = true end
        end)
        if has_item then
            pcall(function() robot.select(slot) end)
            local ok_push = pcall(function() upgrade_me.sendItems() end)
            if not ok_push then
                pcall(function() robot.drop(0) end)
            end
        end
    end
    return true, ERR_OK, 0
end

-- Apiary

function api_robot_insert_parents(api_idx, p_slot, d_slot)
    if not _try_lock(ACCESSING_APIARY) then
        return false, ERR_ACTION_BLOCK, 0
    end

    api_idx = math.floor(tonumber(api_idx) or 0)
    p_slot  = math.floor(tonumber(p_slot)  or 1)
    d_slot  = math.floor(tonumber(d_slot)  or 2)

    local ok

    ok = pcall(function()
        robot.select(p_slot)
        robot.use(api_idx)
    end)
    if not ok then
        _release_lock(ACCESSING_APIARY)
        return false, ERR_APIARY_INVALID, 0
    end

    ok = pcall(function()
        robot.select(d_slot)
        robot.use(api_idx)
    end)
    if not ok then
        _release_lock(ACCESSING_APIARY)
        return false, ERR_APIARY_INVALID, 0
    end

    os.sleep(0.05)
    _release_lock(ACCESSING_APIARY)
    return true, ERR_OK, 0
end

function api_robot_check_birth(api_idx)
    api_idx = math.floor(tonumber(api_idx) or 0)

    if not _try_lock(ACCESSING_APIARY) then
        return false, ERR_ACTION_BLOCK, 0
    end

    local has_offspring = 0
    local ok = pcall(function()
        -- TODO: replace with actual beekeeper component call to check queen/death status
        if beekeeper and beekeeper.analyze then
            local info = beekeeper.analyze(api_idx)
            if info and info.offspring then
                has_offspring = 1
                return
            end
        end
        -- fallback: try extracting and see if anything comes out
        local suc = pcall(function() robot.use(api_idx) end)
        if suc then has_offspring = 1 end
    end)
    os.sleep(0.05)
    _release_lock(ACCESSING_APIARY)

    if not ok then
        return true, ERR_OK, 0
    end
    return true, ERR_OK, has_offspring
end

function api_robot_extract_offspring(api_idx, out_buffer_array)
    api_idx = math.floor(tonumber(api_idx) or 0)

    if not _try_lock(ACCESSING_APIARY) then
        return false, ERR_ACTION_BLOCK, 0
    end

    local count = 0
    local buf_idx = 1
    local ok = pcall(function()
        -- TODO: replace with actual beekeeper component call
        robot.use(api_idx)
        os.sleep(0.1)
        -- 吸收掉落物，写入外部 buffer
        local tries = 1
        while tries <= 10 do
            local got = false
            pcall(function()
                local stack = robot.suck(api_idx)
                if stack then
                    got = true
                    count = count + 1
                    -- 写入外部传入的 buffer（不创建新 table）
                    if out_buffer_array then
                        out_buffer_array[buf_idx] = stack
                        buf_idx = buf_idx + 1
                    end
                end
            end)
            if not got then break end
            tries = tries + 1
        end
    end)
    os.sleep(0.05)
    _release_lock(ACCESSING_APIARY)

    if not ok then
        return false, ERR_UNKNOWN, 0
    end
    return true, ERR_OK, count
end

-- Recovery

function api_robot_hard_stop()
    action_flags = 0
    pcall(function() robot.swing(0) end)
    return true, ERR_OK, 0
end

function api_robot_calibrate_home()
    if not _try_lock(CALIBRATING) then
        return false, ERR_ACTION_BLOCK, 0
    end

    pos_x   = 0
    pos_y   = 0
    pos_z   = 0
    pos_dir = 0

    local ok, name = pcall(function() return inv_ctrl.getInventoryName(0) end)
    if not ok then
        _release_lock(CALIBRATING)
        return false, ERR_COMPONENT_MISSING, 0
    end
    if name ~= "tile.oc.charger" then
        _release_lock(CALIBRATING)
        return false, ERR_UNKNOWN, 0
    end

    os.sleep(0.05)
    _release_lock(CALIBRATING)
    return true, ERR_OK, 0
end

function api_robot_reset_action()
    action_flags = 0
    return true, ERR_OK, 0
end

-- ==============================
-- 七、模块导出
-- ==============================
-- 说明：模块级 table 仅在 require 时分配一次（非主运行路径），
-- 调用方通过 local api_robot = require("api_robot") 获取函数引用。

local MODULE = {
    move_to           = api_robot_move_to,
    move              = api_robot_move,
    get_position      = api_robot_get_position,
    sync_database     = api_robot_sync_database,
    fetch_by_db       = api_robot_fetch_by_db,
    push_all_to_me    = api_robot_push_all_to_me,
    get_empty_slot    = api_robot_get_empty_slot,
    clear_inventory   = api_robot_clear_inventory,
    insert_parents    = api_robot_insert_parents,
    check_birth       = api_robot_check_birth,
    extract_offspring = api_robot_extract_offspring,
    hard_stop         = api_robot_hard_stop,
    calibrate_home    = api_robot_calibrate_home,
    reset_action      = api_robot_reset_action,

    ERR_OK                = ERR_OK,
    ERR_LOW_ENERGY        = ERR_LOW_ENERGY,
    ERR_ME_OFFLINE        = ERR_ME_OFFLINE,
    ERR_INV_FULL          = ERR_INV_FULL,
    ERR_OBSTRUCTED        = ERR_OBSTRUCTED,
    ERR_APIARY_INVALID    = ERR_APIARY_INVALID,
    ERR_TIMEOUT           = ERR_TIMEOUT,
    ERR_COMPONENT_MISSING = ERR_COMPONENT_MISSING,
    ERR_ACTION_BLOCK      = ERR_ACTION_BLOCK,
    ERR_UNKNOWN           = ERR_UNKNOWN,
}

return MODULE
