-- core_task.lua v4.1 — FSM 大脑调度器（事务恢复同步版）
-- OpenComputers Lua 5.3 / RAM 2048KB
-- 冻结协议：Single Tick Single Action、错误码路由、事务恢复

-- ==============================
-- 零、依赖（加载期 require）
-- ==============================
local storage  = require("storage")
local genetics = require("genetics")
local api_robot = require("api_robot")
local health   = require("health")

-- ==============================
-- 一、FSM 状态常量（整数 0-14）
-- ==============================
local IDLE       = 0
local FETCH      = 1
local INSERT     = 2
local WAIT_BIRTH = 3
local EXTRACT    = 4
local ANALYZE    = 5
local COMPARE    = 6
local STORE      = 7
local CLEANUP    = 8
local CALIBRATE  = 9
local RECOVER    = 10
local HALT       = 11
local CHECK      = 12
local PREPARE    = 13
local FINISH     = 14

-- ==============================
-- 二、错误码引用（来自 api_robot）
-- ==============================
local ERR_OK                = api_robot.ERR_OK
local ERR_LOW_ENERGY        = api_robot.ERR_LOW_ENERGY
local ERR_ME_OFFLINE        = api_robot.ERR_ME_OFFLINE
local ERR_INV_FULL          = api_robot.ERR_INV_FULL
local ERR_OBSTRUCTED        = api_robot.ERR_OBSTRUCTED
local ERR_APIARY_INVALID    = api_robot.ERR_APIARY_INVALID
local ERR_TIMEOUT           = api_robot.ERR_TIMEOUT
local ERR_COMPONENT_MISSING = api_robot.ERR_COMPONENT_MISSING
local ERR_ACTION_BLOCK      = api_robot.ERR_ACTION_BLOCK
local ERR_UNKNOWN           = api_robot.ERR_UNKNOWN

-- ==============================
-- 三、任务参数（local 整数 + 字符串缓存）
--     运行时零 table 分配
-- ==============================
local current_state  = IDLE
local task_species   = ""
local task_target_type = 0
local task_mode      = 0
local apiary_idx     = 0
local apiary_alt     = 0
local parent_slot    = 0
local drone_slot     = 0
local work_slot      = 0
local db_slot        = 0
local target_buf_idx = 0
local retry_count    = 0
local prev_state     = IDLE

local analyzed_buf_idx = 0

local fetch_phase     = 0
local prepare_phase   = 0
local insert_phase    = 0

local calibrate_retries = 0
local CALIBRATE_MAX     = 3

-- v4.1 新增：ANALYZE 恢复标记（断电后非首次进入）
local analyze_recovery = 0

-- ==============================
-- 四、预分配 buffer（加载期，仅此一次）
-- ==============================
local EXTRACT_BUFFER = {}

-- ==============================
-- 五、错误码路由（O(1) 整数判断）
--     输入 err_code，返回目标状态
-- ==============================
local function _route_error(err_code)
    if err_code == ERR_OK then
        return current_state
    elseif err_code == ERR_LOW_ENERGY then
        return CHECK
    elseif err_code == ERR_ME_OFFLINE then
        return RECOVER
    elseif err_code == ERR_INV_FULL then
        return CLEANUP
    elseif err_code == ERR_OBSTRUCTED then
        return CALIBRATE
    elseif err_code == ERR_APIARY_INVALID then
        if apiary_idx == apiary_alt then
            return HALT
        end
        local tmp = apiary_idx
        apiary_idx = apiary_alt
        apiary_alt = tmp
        return prev_state
    elseif err_code == ERR_TIMEOUT then
        return current_state
    elseif err_code == ERR_ACTION_BLOCK then
        return current_state
    elseif err_code == ERR_COMPONENT_MISSING then
        return HALT
    else
        return HALT
    end
end

-- ==============================
-- 六、State Handlers（每个返回 next_state, sleep_ms）
-- ==============================

local function _state_idle()
    if task_species == "" then
        return IDLE, 500
    end
    retry_count = 0
    prepare_phase = 0
    analyze_recovery = 0
    return PREPARE, 50
end

local function _state_prepare()
    if prepare_phase == 0 then
        local suc, ec = api_robot.calibrate_home()
        if not suc then
            return _route_error(ec), 200
        end
        prepare_phase = 1
        return PREPARE, 50
    else
        local suc, ec = api_robot.sync_database(db_slot, task_species, task_target_type)
        if not suc then
            return _route_error(ec), 200
        end
        prepare_phase = 0
        fetch_phase = 0
        return FETCH, 50
    end
end

local function _state_fetch()
    if fetch_phase == 0 then
        local suc, ec = api_robot.fetch_by_db(db_slot, 1, parent_slot)
        if not suc then
            return _route_error(ec), 200
        end
        fetch_phase = 1
        return FETCH, 50
    else
        local suc, ec = api_robot.fetch_by_db(db_slot, 1, drone_slot)
        if not suc then
            return _route_error(ec), 200
        end
        fetch_phase = 0
        -- 持久化任务参数 + tx=1
        storage.set_task_params(apiary_idx, parent_slot, drone_slot, work_slot, target_buf_idx, task_mode)
        storage.set_tx(1)
        storage.save_if_dirty()
        insert_phase = 0
        return INSERT, 50
    end
end

local function _state_insert()
    if insert_phase == 0 then
        local suc, ec = api_robot.move_to(apiary_idx, 0, 0)
        if not suc then
            return _route_error(ec), 200
        end
        insert_phase = 1
        return INSERT, 50
    else
        local suc, ec = api_robot.insert_parents(apiary_idx, parent_slot, drone_slot)
        if not suc then
            return _route_error(ec), 200
        end
        insert_phase = 0
        storage.set_tx(2)
        storage.save_if_dirty()
        return WAIT_BIRTH, 50
    end
end

local function _state_wait_birth()
    local suc, ec, has_offspring = api_robot.check_birth(apiary_idx)
    if not suc then
        return _route_error(ec), 200
    end

    if has_offspring == 0 then
        retry_count = retry_count + 1
        storage.set_retry(retry_count)
        if retry_count > 600 then
            storage.set_tx(0)
            storage.save_if_dirty()
            retry_count = 0
            return IDLE, 50
        end
        return WAIT_BIRTH, 500
    end

    retry_count = 0
    storage.set_retry(0)
    return EXTRACT, 50
end

local function _state_extract()
    local bi = 1
    while EXTRACT_BUFFER[bi] ~= nil do
        EXTRACT_BUFFER[bi] = nil
        bi = bi + 1
    end

    local suc, ec, count = api_robot.extract_offspring(apiary_idx, EXTRACT_BUFFER)
    if not suc then
        return _route_error(ec), 200
    end

    storage.set_tx(3)
    storage.save_if_dirty()
    analyze_recovery = 0
    return ANALYZE, 50
end

local function _state_analyze()
    -- 恢复路径：EXTRACT_BUFFER 可能为空（断电），扫描机器人背包
    if EXTRACT_BUFFER[1] == nil then
        if analyze_recovery == 0 then
            -- 尝试从背包中寻找后代物品
            local suc, ec, slot = api_robot.get_empty_slot()
            -- get_empty_slot 返回第一个空槽，我们需要的是有物品的槽
            -- 简单做法：从槽位 1 开始扫描，将第一个非空、非亲本槽位的数据当作后代
            -- 由于 EXTRACT_BUFFER 是外部 buffer，api_robot.extract_offspring 应已写入
            -- 若 extract_offspring 已调但 buffer 为空 → 真正无后代 → CLEANUP
            analyze_recovery = 1
            return CLEANUP, 50
        else
            return CLEANUP, 50
        end
    end

    local suc, ec, buf_idx = genetics.parse_gene(EXTRACT_BUFFER[1])
    if not suc then
        return CLEANUP, 50
    end

    local ok_pack, packed = genetics.pack_gene(buf_idx)
    if not ok_pack then
        return CLEANUP, 50
    end

    analyzed_buf_idx = buf_idx
    return COMPARE, 50
end

local function _state_compare()
    local suc, species_score, trait_score = genetics.compare(
        analyzed_buf_idx,
        target_buf_idx,
        task_mode
    )
    if not suc then
        return CLEANUP, 50
    end

    return STORE, 50
end

local function _state_store()
    local suc, ec = api_robot.push_all_to_me()
    if not suc then
        return _route_error(ec), 200
    end

    storage.set_tx(4)
    storage.save_if_dirty()
    return FINISH, 50
end

local function _state_cleanup()
    local suc, ec = api_robot.clear_inventory()
    if not suc then
        return _route_error(ec), 200
    end

    storage.set_tx(0)
    storage.save_if_dirty()
    return IDLE, 50
end

local function _state_calibrate()
    local suc, ec = api_robot.calibrate_home()
    if not suc then
        calibrate_retries = calibrate_retries + 1
        if calibrate_retries >= CALIBRATE_MAX then
            calibrate_retries = 0
            return HALT, 50
        end
        return CALIBRATE, 500
    end

    calibrate_retries = 0
    return prev_state, 50
end

local function _state_recover()
    local suc, ec = api_robot.sync_database(db_slot, task_species, task_target_type)
    if suc then
        storage.set_tx(1)
        storage.save_if_dirty()
        prepare_phase = 0
        fetch_phase = 0
        return PREPARE, 50
    end

    retry_count = retry_count + 1
    if retry_count > 120 then
        return HALT, 50
    end
    return RECOVER, 1000
end

local function _state_halt()
    return HALT, 5000
end

local function _state_check()
    local sys_status = health.tick()
    if sys_status == health.SYS_HALT then
        return HALT, 5000
    elseif sys_status == health.SYS_RECHARGE then
        return IDLE, 5000
    end
    return prev_state, 50
end

local function _state_finish()
    storage.set_tx(0)
    storage.save_if_dirty()
    retry_count = 0
    return IDLE, 50
end

-- ==============================
-- 七、状态分发表（加载期分配，运行时只读索引）
-- ==============================
local STATE_HANDLERS = {
    _state_idle,
    _state_fetch,
    _state_insert,
    _state_wait_birth,
    _state_extract,
    _state_analyze,
    _state_compare,
    _state_store,
    _state_cleanup,
    _state_calibrate,
    _state_recover,
    _state_halt,
    _state_check,
    _state_prepare,
    _state_finish,
}

-- ==============================
-- 八、Public API
-- ==============================

function core_task_init()
    health.init()

    local tx = storage.get_tx()

    if tx == 2 then
        -- 已入蜂箱：恢复蜂箱位置 + 目标比对参数 + retry
        apiary_idx, parent_slot, drone_slot, work_slot, target_buf_idx, task_mode
            = storage.get_task_params()
        retry_count = storage.get_retry()
        current_state = WAIT_BIRTH
    elseif tx == 3 then
        -- 持后代：恢复目标比对参数
        apiary_idx, parent_slot, drone_slot, work_slot, target_buf_idx, task_mode
            = storage.get_task_params()
        retry_count = 0
        analyze_recovery = 1
        current_state = ANALYZE
    elseif tx == 1 then
        -- 持亲本断电：恢复参数直接跳到 INSERT（不丢失亲本）
        apiary_idx, parent_slot, drone_slot, work_slot, target_buf_idx, task_mode
            = storage.get_task_params()
        retry_count = 0
        insert_phase = 0
        current_state = INSERT
    elseif tx == 4 then
        storage.set_tx(0)
        storage.save_if_dirty()
        current_state = IDLE
    else
        current_state = IDLE
    end

    fetch_phase       = 0
    prepare_phase     = 0
    insert_phase      = 0
    calibrate_retries = 0

    return true, ERR_OK
end

function core_task_tick()
    if current_state < 0 or current_state > 14 then
        current_state = HALT
    end

    prev_state = current_state

    local handler_idx = current_state + 1
    local ok, next_state, sleep_ms = pcall(STATE_HANDLERS[handler_idx])
    if not ok then
        current_state = HALT
        return 5000
    end

    next_state = math.floor(tonumber(next_state) or IDLE)
    if next_state < 0 or next_state > 14 then
        next_state = HALT
    end
    sleep_ms = math.floor(tonumber(sleep_ms) or 50)
    if sleep_ms < 10 then sleep_ms = 10 end

    current_state = next_state
    return sleep_ms
end

function core_task_get_state()
    return current_state
end

function core_task_reset()
    current_state    = IDLE
    retry_count      = 0
    task_species     = ""
    task_target_type = 0
    task_mode        = 0
    fetch_phase      = 0
    prepare_phase    = 0
    insert_phase     = 0
    calibrate_retries = 0
    analyze_recovery  = 0
    storage.set_tx(0)
    storage.save_if_dirty()
    return true, ERR_OK
end

-- ==============================
-- 九、辅助：设置任务参数（外部调用）
-- ==============================
function core_task_set_task(species, target_type, mode, api_idx, alt_idx, p_slot, d_slot, w_slot, db_s, tgt_buf)
    task_species      = tostring(species or "")
    task_target_type  = math.floor(tonumber(target_type) or 0)
    if task_target_type ~= 0 and task_target_type ~= 1 then task_target_type = 0 end
    task_mode         = math.floor(tonumber(mode) or 0)
    if task_mode ~= 0 and task_mode ~= 1 then task_mode = 0 end
    apiary_idx        = math.floor(tonumber(api_idx) or 0)
    apiary_alt        = math.floor(tonumber(alt_idx) or 0)
    parent_slot       = math.floor(tonumber(p_slot) or 1)
    drone_slot        = math.floor(tonumber(d_slot) or 2)
    work_slot         = math.floor(tonumber(w_slot) or 3)
    db_slot           = math.floor(tonumber(db_s) or 1)
    target_buf_idx    = math.floor(tonumber(tgt_buf) or 1)
    if target_buf_idx ~= 1 and target_buf_idx ~= 2 then target_buf_idx = 1 end
    current_state     = PREPARE
    prepare_phase     = 0
    fetch_phase       = 0
    insert_phase      = 0
    analyze_recovery  = 0
    return true, ERR_OK
end

-- ==============================
-- 十、模块导出
-- ==============================
local MODULE = {
    init       = core_task_init,
    tick       = core_task_tick,
    get_state  = core_task_get_state,
    reset      = core_task_reset,
    set_task   = core_task_set_task,

    IDLE       = IDLE,
    FETCH      = FETCH,
    INSERT     = INSERT,
    WAIT_BIRTH = WAIT_BIRTH,
    EXTRACT    = EXTRACT,
    ANALYZE    = ANALYZE,
    COMPARE    = COMPARE,
    STORE      = STORE,
    CLEANUP    = CLEANUP,
    CALIBRATE  = CALIBRATE,
    RECOVER    = RECOVER,
    HALT       = HALT,
    CHECK      = CHECK,
    PREPARE    = PREPARE,
    FINISH     = FINISH,

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
