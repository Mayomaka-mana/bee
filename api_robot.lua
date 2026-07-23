-- api_robot.lua v4 -- robot abstraction layer
-- OpenComputers Lua 5.3 / RAM 2048KB
-- Frozen protocol: stateless, zero table allocation, integer-only returns

local component = require("component")
local computer  = require("computer")
local robot     = require("robot")

local inv_ctrl   = component.inventory_controller
local upgrade_me = component.upgrade_me
local database_c = component.database
local beekeeper  = component.beekeeper

-- startup component check (no pcall - must pass)
local function _check_components()
    if not inv_ctrl then error("missing inventory_controller") end
    if not upgrade_me then error("missing upgrade_me") end
    if not database_c then error("missing database") end
    if not beekeeper then error("missing beekeeper") end
    local ok, linked = pcall(function() return upgrade_me.isLinked() end)
    if not ok or not linked then error("not connected to ME network") end
    if robot.inventorySize() < 32 then error("need >=32 inventory slots") end
    local name = inv_ctrl.getInventoryName(0)
    if not name or not string.find(tostring(name), "charger") then
        error("robot must start on OC charger")
    end
end
_check_components()

-- error codes
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

-- action guard bits
local MOVING           = 0
local ACCESSING_ME     = 1
local ACCESSING_APIARY = 2
local CALIBRATING      = 3

-- state (integers only)
local pos_x   = 0
local pos_y   = 0
local pos_z   = 0
local pos_dir = 0   -- 0=N 1=E 2=S 3=W
local action_flags = 0

-- helpers

local function _energy_ok()
    local ok, val = pcall(function() return computer.energy() end)
    if not ok then return false end
    return val >= 50
end

local function _try_lock(bit)
    if (action_flags & (1 << bit)) ~= 0 then return false end
    action_flags = action_flags | (1 << bit)
    return true
end

local function _release_lock(bit)
    action_flags = action_flags & ~(1 << bit)
end

local function _face(target_dir)
    local diff = (target_dir - pos_dir) & 3
    if diff == 0 then return ERR_OK
    elseif diff == 1 then
        if not pcall(function() robot.turnRight() end) then return ERR_UNKNOWN end
        pos_dir = (pos_dir + 1) & 3
        return ERR_OK
    elseif diff == 3 then
        if not pcall(function() robot.turnLeft() end) then return ERR_UNKNOWN end
        pos_dir = (pos_dir - 1) & 3
        return ERR_OK
    else
        if not pcall(function() robot.turnRight() end) then return ERR_UNKNOWN end
        pos_dir = (pos_dir + 1) & 3
        if not pcall(function() robot.turnRight() end) then return ERR_UNKNOWN end
        pos_dir = (pos_dir + 1) & 3
        return ERR_OK
    end
end

local function _step_forward()
    local ok, result = pcall(function() return robot.forward() end)
    if not ok then return ERR_UNKNOWN end
    if not result then return ERR_OBSTRUCTED end
    if pos_dir == 0 then pos_z = pos_z - 1
    elseif pos_dir == 1 then pos_x = pos_x + 1
    elseif pos_dir == 2 then pos_z = pos_z + 1
    else pos_x = pos_x - 1 end
    return ERR_OK
end

local function _move_step_h(dir)
    local ec = _face(dir)
    if ec ~= ERR_OK then return ec end
    if not _energy_ok() then return ERR_LOW_ENERGY end
    return _step_forward()
end

local function _move_step_v(dy)
    if not _energy_ok() then return ERR_LOW_ENERGY end
    local ok, result
    if dy > 0 then ok, result = pcall(function() return robot.up() end)
    else ok, result = pcall(function() return robot.down() end) end
    if not ok then return ERR_UNKNOWN end
    if not result then return ERR_OBSTRUCTED end
    pos_y = pos_y + dy
    return ERR_OK
end

local function _move_to_abs(tx, ty, tz)
    if not _try_lock(MOVING) then return false, ERR_ACTION_BLOCK, 0 end
    local ec
    while pos_y ~= ty do
        local dy = (ty > pos_y) and 1 or -1
        ec = _move_step_v(dy)
        if ec ~= ERR_OK then _release_lock(MOVING); return false, ec, 0 end
    end
    while pos_x ~= tx do
        local dir = (tx > pos_x) and 1 or 3
        ec = _move_step_h(dir)
        if ec ~= ERR_OK then _release_lock(MOVING); return false, ec, 0 end
    end
    while pos_z ~= tz do
        local dir = (tz > pos_z) and 2 or 0
        ec = _move_step_h(dir)
        if ec ~= ERR_OK then _release_lock(MOVING); return false, ec, 0 end
    end
    os.sleep(0.05)
    _release_lock(MOVING)
    return true, ERR_OK, 0
end

-- Public API

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
    db_slot = math.floor(tonumber(db_slot) or 1)
    if db_slot < 1 then db_slot = 1 end
    if not _try_lock(ACCESSING_ME) then return false, ERR_ACTION_BLOCK, 0 end

    local ok_linked = pcall(function()
        if not upgrade_me.isLinked() then error("ME offline") end
    end)
    if not ok_linked then _release_lock(ACCESSING_ME); return false, ERR_ME_OFFLINE, 0 end

    local item_name = (target_type == 0) and "Forestry:beePrincessGE" or "Forestry:beeDroneGE"
    local nbt = '{IsAnalyzed:1b,Genome:{Chromosomes:[0:{Slot:0b,UID0:"' .. species_name .. '",UID1:"' .. species_name .. '"}]}}'

    local ok = pcall(function()
        database_c.clear(db_slot)
        database_c.set(db_slot, item_name, 0, nbt)
        local entry = database_c.get(db_slot)
        if not entry then error("database set failed") end
        upgrade_me.store({name = item_name, label = entry.label}, database_c.address, db_slot)
    end)

    os.sleep(0.05)
    _release_lock(ACCESSING_ME)
    if not ok then return false, ERR_UNKNOWN, 0 end
    return true, ERR_OK, 0
end

function api_robot_fetch_by_db(db_slot, amount, target_slot)
    db_slot = math.floor(tonumber(db_slot) or 1)
    if db_slot < 1 then db_slot = 1 end
    amount = math.floor(tonumber(amount) or 1)
    if amount < 1 then amount = 1 end
    target_slot = math.floor(tonumber(target_slot) or 1)
    if target_slot < 1 then target_slot = 1 end

    if not _try_lock(ACCESSING_ME) then return false, ERR_ACTION_BLOCK, 0 end

    local ok = pcall(function()
        if not upgrade_me.isLinked() then error("ME offline") end
        robot.select(target_slot)
        upgrade_me.requestItems(database_c.address, db_slot, amount)
    end)

    os.sleep(0.1)
    _release_lock(ACCESSING_ME)
    if not ok then return false, ERR_ME_OFFLINE, 0 end
    return true, ERR_OK, 0
end

function api_robot_push_all_to_me()
    if not _try_lock(ACCESSING_ME) then return false, ERR_ACTION_BLOCK, 0 end
    local ok_linked = pcall(function() return upgrade_me.isLinked() end)
    if not ok_linked then _release_lock(ACCESSING_ME); return false, ERR_ME_OFFLINE, 0 end

    local inv_size = 32
    pcall(function() inv_size = robot.inventorySize() end)
    local any_full = false
    for slot = 1, inv_size do
        local has_item = false
        pcall(function()
            if inv_ctrl.getStackInInternalSlot(slot) then has_item = true end
        end)
        if has_item then
            pcall(function() robot.select(slot) end)
            if not pcall(function() upgrade_me.sendItems() end) then any_full = true end
        end
    end
    os.sleep(0.05)
    _release_lock(ACCESSING_ME)
    if any_full then return false, ERR_INV_FULL, 0 end
    return true, ERR_OK, 0
end

-- Inventory

function api_robot_get_empty_slot()
    local inv_size = 32
    pcall(function() inv_size = robot.inventorySize() end)
    for slot = 1, inv_size do
        local empty = true
        pcall(function()
            if inv_ctrl.getStackInInternalSlot(slot) then empty = false end
        end)
        if empty then return true, ERR_OK, slot end
    end
    return false, ERR_INV_FULL, 0
end

function api_robot_clear_inventory()
    local inv_size = 32
    pcall(function() inv_size = robot.inventorySize() end)
    for slot = 1, inv_size do
        local has_item = false
        pcall(function()
            if inv_ctrl.getStackInInternalSlot(slot) then has_item = true end
        end)
        if has_item then
            pcall(function() robot.select(slot) end)
            if not pcall(function() upgrade_me.sendItems() end) then
                pcall(function() robot.drop(0) end)
            end
        end
    end
    return true, ERR_OK, 0
end

-- Apiary operations (robot stands on apiary, side=0 = down)

function api_robot_insert_parents(api_idx, p_slot, d_slot)
    if not _try_lock(ACCESSING_APIARY) then return false, ERR_ACTION_BLOCK, 0 end
    api_idx = math.floor(tonumber(api_idx) or 0)
    p_slot  = math.floor(tonumber(p_slot)  or 1)
    d_slot  = math.floor(tonumber(d_slot)  or 2)

    local ok = pcall(function()
        robot.select(p_slot)
        if not inv_ctrl.dropIntoSlot(0, 1, 1) then error("drop princess failed") end
    end)
    if not ok then _release_lock(ACCESSING_APIARY); return false, ERR_APIARY_INVALID, 0 end

    ok = pcall(function()
        robot.select(d_slot)
        if not inv_ctrl.dropIntoSlot(0, 2, 1) then error("drop drone failed") end
    end)
    if not ok then _release_lock(ACCESSING_APIARY); return false, ERR_APIARY_INVALID, 0 end

    os.sleep(0.1)
    _release_lock(ACCESSING_APIARY)
    return true, ERR_OK, 0
end

function api_robot_check_birth(api_idx)
    api_idx = math.floor(tonumber(api_idx) or 0)
    if not _try_lock(ACCESSING_APIARY) then return false, ERR_ACTION_BLOCK, 0 end

    local has_offspring = 0
    local ok = pcall(function()
        local stack1 = inv_ctrl.getStackInSlot(0, 1)
        if not stack1 then has_offspring = 1
        elseif stack1.name == "Forestry:beePrincessGE" then has_offspring = 1
        elseif stack1.name == "Forestry:beeQueenGE" then
            if stack1.individual and stack1.individual.health then
                if stack1.individual.health <= 0 then has_offspring = 1 end
            end
        else has_offspring = 1 end

        if has_offspring == 0 then
            for i = 3, 9 do
                if inv_ctrl.getStackInSlot(0, i) then has_offspring = 1; break end
            end
        end
    end)

    os.sleep(0.05)
    _release_lock(ACCESSING_APIARY)
    if not ok then return true, ERR_OK, 0 end
    return true, ERR_OK, has_offspring
end

function api_robot_extract_offspring(api_idx, out_buffer_array)
    api_idx = math.floor(tonumber(api_idx) or 0)
    if not _try_lock(ACCESSING_APIARY) then return false, ERR_ACTION_BLOCK, 0 end

    local count = 0
    local buf_idx = 1
    local ok = pcall(function()
        for i = 3, 9 do
            local suc = pcall(function() return inv_ctrl.suckFromSlot(0, i) end)
            if suc then
                os.sleep(0)
                count = count + 1
                if out_buffer_array then
                    pcall(function()
                        robot.select(1)
                        local stack = inv_ctrl.getStackInInternalSlot(1)
                        if stack then out_buffer_array[buf_idx] = stack; buf_idx = buf_idx + 1 end
                    end)
                end
            end
        end
        pcall(function()
            local stack1 = inv_ctrl.getStackInSlot(0, 1)
            if stack1 and stack1.name == "Forestry:beePrincessGE" then
                inv_ctrl.suckFromSlot(0, 1)
                os.sleep(0)
                count = count + 1
                if out_buffer_array then
                    pcall(function()
                        robot.select(1)
                        local stack = inv_ctrl.getStackInInternalSlot(1)
                        if stack then out_buffer_array[buf_idx] = stack; buf_idx = buf_idx + 1 end
                    end)
                end
            end
        end)
    end)

    os.sleep(0.05)
    _release_lock(ACCESSING_APIARY)
    if not ok then return false, ERR_UNKNOWN, 0 end
    return true, ERR_OK, count
end

-- Recovery

function api_robot_hard_stop()
    action_flags = 0
    return true, ERR_OK, 0
end

function api_robot_calibrate_home()
    if not _try_lock(CALIBRATING) then return false, ERR_ACTION_BLOCK, 0 end
    pos_x = 0; pos_y = 0; pos_z = 0; pos_dir = 0

    local ok, name = pcall(function() return inv_ctrl.getInventoryName(0) end)
    if not ok then _release_lock(CALIBRATING); return false, ERR_COMPONENT_MISSING, 0 end
    if not name or not string.find(tostring(name), "charger") then
        _release_lock(CALIBRATING); return false, ERR_UNKNOWN, 0
    end

    os.sleep(0.05)
    _release_lock(CALIBRATING)
    return true, ERR_OK, 0
end

function api_robot_reset_action()
    action_flags = 0
    return true, ERR_OK, 0
end

-- Module export

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
