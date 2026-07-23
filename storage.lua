-- storage.lua v3.1 — 持久化状态中心（事务恢复增强）
-- OpenComputers Lua 5.3 / RAM 2048KB
-- 冻结协议：ACID持久化、O(1)双指针队列、Dirty机制

-- ==============================
-- 零、错误码（整数）
-- ==============================
local ERR_OK               = 0
local ERR_IO_FAIL          = 1
local ERR_SERIALIZE_FAIL   = 2
local ERR_UNSERIALIZE_FAIL = 3
local ERR_INVALID_STATE    = 4
local ERR_QUEUE_EMPTY      = 5
local ERR_QUEUE_FULL       = 6

-- ==============================
-- 一、文件路径常量
-- ==============================
local FILE_DAT = "storage.dat"
local FILE_TMP = "storage.tmp"

-- ==============================
-- 二、序列化模块（加载期 require）
-- ==============================
local serialization = require("serialization")

-- ==============================
-- 三、状态（仅加载期分配，扁平整数结构）
-- ==============================
local state = {}
state.tx           = 0
state.dirty        = 0
state.task_cursor  = 0
state.queue_head   = 1
state.queue_tail   = 1
state.queue        = {}

-- v3.1 新增：事务恢复参数字段
state.task_apiary_idx  = 0
state.task_parent_slot = 0
state.task_drone_slot  = 0
state.task_work_slot   = 0
state.task_target_buf  = 0
state.task_mode        = 0
state.task_retry       = 0
state.task_state       = 0

-- ==============================
-- 四、内部文件操作（全部 pcall 隔离）
-- ==============================

local function _file_exists(path)
    local f = io.open(path, "r")
    if f then
        pcall(function() f:close() end)
        return true
    end
    return false
end

local function _file_read_all(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local data = nil
    pcall(function()
        data = f:read("*a")
    end)
    pcall(function() f:close() end)
    return data
end

local function _file_write_all(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    local ok = true
    if not pcall(function() f:write(content) end) then ok = false end
    if not pcall(function() f:flush() end) then ok = false end
    pcall(function() f:close() end)
    return ok
end

local function _load_opt_int(loaded, key, default)
    return math.floor(tonumber(loaded[key]) or default)
end

-- ==============================
-- 五、Public API
-- ==============================

function storage_init()
    if _file_exists(FILE_TMP) then
        pcall(function() os.remove(FILE_TMP) end)
    end

    if _file_exists(FILE_DAT) then
        local raw = _file_read_all(FILE_DAT)
        if raw then
            local ok_unser, loaded = pcall(function()
                return serialization.unserialize(raw)
            end)
            if ok_unser and type(loaded) == "table" then
                state.tx           = _load_opt_int(loaded, "tx", 0)
                state.task_cursor  = _load_opt_int(loaded, "task_cursor", 0)
                state.queue_head   = _load_opt_int(loaded, "queue_head", 1)
                state.queue_tail   = _load_opt_int(loaded, "queue_tail", 1)
                state.task_apiary_idx = _load_opt_int(loaded, "task_apiary_idx", 0)
                state.task_parent_slot = _load_opt_int(loaded, "task_parent_slot", 0)
                state.task_drone_slot  = _load_opt_int(loaded, "task_drone_slot", 0)
                state.task_work_slot   = _load_opt_int(loaded, "task_work_slot", 0)
                state.task_target_buf  = _load_opt_int(loaded, "task_target_buf", 0)
                state.task_mode        = _load_opt_int(loaded, "task_mode", 0)
                state.task_retry       = _load_opt_int(loaded, "task_retry", 0)
                state.task_state       = _load_opt_int(loaded, "task_state", 0)
                if type(loaded.queue) == "table" then
                    local qi = loaded.queue_head or 1
                    local qt = loaded.queue_tail or 1
                    while qi < qt do
                        state.queue[qi] = loaded.queue[qi]
                        qi = qi + 1
                    end
                end
                state.dirty = 0
                return true, ERR_OK
            end
        end
    end

    state.tx               = 0
    state.dirty            = 0
    state.task_cursor      = 0
    state.queue_head       = 1
    state.queue_tail       = 1
    state.task_apiary_idx  = 0
    state.task_parent_slot = 0
    state.task_drone_slot  = 0
    state.task_work_slot   = 0
    state.task_target_buf  = 0
    state.task_mode        = 0
    state.task_retry       = 0
    state.task_state       = 0
    local qi = 1
    while state.queue[qi] ~= nil do
        state.queue[qi] = nil
        qi = qi + 1
    end
    return true, ERR_OK
end

function storage_get_tx()
    return state.tx
end

function storage_set_tx(value)
    value = math.floor(tonumber(value) or 0)
    if value < 0 or value > 4 then
        return false, ERR_INVALID_STATE
    end
    state.tx = value
    state.dirty = 1
    return true, ERR_OK
end

function storage_enqueue(task_id)
    task_id = math.floor(tonumber(task_id) or 0)
    if task_id <= 0 then
        return false, ERR_INVALID_STATE
    end
    state.queue[state.queue_tail] = task_id
    state.queue_tail = state.queue_tail + 1
    state.dirty = 1
    return true, ERR_OK
end

function storage_dequeue()
    if state.queue_head >= state.queue_tail then
        return false, ERR_QUEUE_EMPTY, 0
    end
    local task_id = state.queue[state.queue_head]
    state.queue[state.queue_head] = nil
    state.queue_head = state.queue_head + 1
    state.dirty = 1
    return true, ERR_OK, task_id
end

-- v3.1 新增：任务参数持久化接口

function storage_set_task_params(apiary, p_slot, d_slot, work_slot, tgt_buf, mode)
    state.task_apiary_idx  = math.floor(tonumber(apiary) or 0)
    state.task_parent_slot = math.floor(tonumber(p_slot) or 0)
    state.task_drone_slot  = math.floor(tonumber(d_slot) or 0)
    state.task_work_slot   = math.floor(tonumber(work_slot) or 0)
    state.task_target_buf  = math.floor(tonumber(tgt_buf) or 1)
    if state.task_target_buf ~= 1 and state.task_target_buf ~= 2 then state.task_target_buf = 1 end
    state.task_mode        = math.floor(tonumber(mode) or 0)
    if state.task_mode ~= 0 and state.task_mode ~= 1 then state.task_mode = 0 end
    state.dirty = 1
    return true, ERR_OK
end

function storage_get_task_params()
    return state.task_apiary_idx,
           state.task_parent_slot,
           state.task_drone_slot,
           state.task_work_slot,
           state.task_target_buf,
           state.task_mode
end

function storage_set_retry(value)
    state.task_retry = math.floor(tonumber(value) or 0)
    state.dirty = 1
    return true, ERR_OK
end

function storage_get_retry()
    return state.task_retry
end

function storage_set_task_state(value)
    value = math.floor(tonumber(value) or 0)
    if value < 0 or value > 14 then
        return false, ERR_INVALID_STATE
    end
    state.task_state = value
    state.dirty = 1
    return true, ERR_OK
end

function storage_get_task_state()
    return state.task_state
end

function storage_save()
    local snapshot = {}
    snapshot.tx           = state.tx
    snapshot.task_cursor  = state.task_cursor
    snapshot.queue_head   = state.queue_head
    snapshot.queue_tail   = state.queue_tail
    snapshot.task_apiary_idx  = state.task_apiary_idx
    snapshot.task_parent_slot = state.task_parent_slot
    snapshot.task_drone_slot  = state.task_drone_slot
    snapshot.task_work_slot   = state.task_work_slot
    snapshot.task_target_buf  = state.task_target_buf
    snapshot.task_mode        = state.task_mode
    snapshot.task_retry       = state.task_retry
    snapshot.task_state       = state.task_state
    snapshot.queue        = {}
    local qi = state.queue_head
    while qi < state.queue_tail do
        snapshot.queue[qi] = state.queue[qi]
        qi = qi + 1
    end

    local ok_ser, data = pcall(function()
        return serialization.serialize(snapshot)
    end)
    if not ok_ser or not data then
        return false, ERR_SERIALIZE_FAIL
    end

    if not _file_write_all(FILE_TMP, data) then
        return false, ERR_IO_FAIL
    end

    local ok_rename = pcall(function()
        os.rename(FILE_TMP, FILE_DAT)
    end)
    if not ok_rename then
        pcall(function() os.remove(FILE_TMP) end)
        return false, ERR_IO_FAIL
    end

    state.dirty = 0
    return true, ERR_OK
end

function storage_save_if_dirty()
    if state.dirty == 0 then
        return true, ERR_OK
    end
    return storage_save()
end

function storage_reset()
    state.tx               = 0
    state.dirty            = 0
    state.task_cursor      = 0
    state.queue_head       = 1
    state.queue_tail       = 1
    state.task_apiary_idx  = 0
    state.task_parent_slot = 0
    state.task_drone_slot  = 0
    state.task_work_slot   = 0
    state.task_target_buf  = 0
    state.task_mode        = 0
    state.task_retry       = 0
    state.task_state       = 0
    local qi = 1
    while state.queue[qi] ~= nil do
        state.queue[qi] = nil
        qi = qi + 1
    end
    return true, ERR_OK
end

-- ==============================
-- 六、模块导出
-- ==============================
local MODULE = {
    init          = storage_init,
    get_tx        = storage_get_tx,
    set_tx        = storage_set_tx,
    enqueue       = storage_enqueue,
    dequeue       = storage_dequeue,
    save          = storage_save,
    save_if_dirty = storage_save_if_dirty,
    reset         = storage_reset,

    set_task_params  = storage_set_task_params,
    get_task_params  = storage_get_task_params,
    set_retry        = storage_set_retry,
    get_retry        = storage_get_retry,
    set_task_state   = storage_set_task_state,
    get_task_state   = storage_get_task_state,

    ERR_OK               = ERR_OK,
    ERR_IO_FAIL          = ERR_IO_FAIL,
    ERR_SERIALIZE_FAIL   = ERR_SERIALIZE_FAIL,
    ERR_UNSERIALIZE_FAIL = ERR_UNSERIALIZE_FAIL,
    ERR_INVALID_STATE    = ERR_INVALID_STATE,
    ERR_QUEUE_EMPTY      = ERR_QUEUE_EMPTY,
    ERR_QUEUE_FULL       = ERR_QUEUE_FULL,
}

return MODULE
