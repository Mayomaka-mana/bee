-- health.lua — Watchdog 被动传感器
-- OpenComputers Lua 5.3 / RAM 2048KB
-- 冻结协议：只读环境、零分配主路径、整数状态

-- ==============================
-- 零、错误码 & 系统状态码（整数）
-- ==============================
local ERR_OK        = 0
local ERR_API_FAIL  = 1

local SYS_OK       = 0
local SYS_RECHARGE = 1
local SYS_HALT     = 2

-- ==============================
-- 一、依赖 & 函数引用缓存（加载期）
-- ==============================
local computer = require("computer")

-- 模块级函数引用 — 消除 tick() 路径闭包分配
local _freeMemory_ref = computer.freeMemory
local _energy_ref     = computer.energy
local _maxEnergy_ref  = computer.maxEnergy
local _collectgarbage = collectgarbage

-- ==============================
-- 二、阈值常量（整数，单位 KB）
-- ==============================
local MEM_THRESHOLD_GC_STEP = 1024
local MEM_THRESHOLD_GC_FULL = 512

-- ==============================
-- 三、唯一定义的整数状态变量
-- ==============================
local low_energy_count = 0
local sys_status       = SYS_OK

-- ==============================
-- 四、内部 pcall 包裹的传感器读取
--    （使用函数引用，零闭包分配）
-- ==============================
local function _read_free_memory_kb()
    local ok, val = pcall(_freeMemory_ref)
    if not ok then return -1 end
    local kb = val // 1024
    if kb < 0 then kb = 0 end
    return kb
end

local function _read_energy()
    local ok_e, energy = pcall(_energy_ref)
    local ok_m, max_e  = pcall(_maxEnergy_ref)
    if not ok_e or not ok_m or not max_e or max_e <= 0 then
        return -1, -1
    end
    return energy, max_e
end

-- GC 包装函数（供 pcall 引用，零闭包）
local function _gc_full()
    _collectgarbage()
end

local function _gc_step()
    _collectgarbage("step")
end

-- ==============================
-- 五、能量百分比安全计算
--     避免 energy * 100 整数溢出
-- ==============================
local function _energy_pct(energy, max_e)
    if max_e <= 0 then return 0 end
    if max_e > 100 then
        -- energy // (max_e // 100)  ≈  energy * 100 / max_e
        return energy // (max_e // 100)
    else
        -- max_e 小，energy * 100 在安全范围内
        return (energy * 100) // max_e
    end
end

-- ==============================
-- 六、Public API
-- ==============================

function health_init()
    low_energy_count = 0
    sys_status       = SYS_OK
    return true, ERR_OK
end

function health_tick()
    -- 1. 内存 GC Guard
    local free_kb = _read_free_memory_kb()
    if free_kb < 0 then
        sys_status = SYS_HALT
        return sys_status
    end

    if free_kb < MEM_THRESHOLD_GC_FULL then
        pcall(_gc_full)
        os.sleep(1)
        -- 重新评估
        free_kb = _read_free_memory_kb()
        if free_kb < 0 then
            sys_status = SYS_HALT
            return sys_status
        end
    elseif free_kb < MEM_THRESHOLD_GC_STEP then
        pcall(_gc_step)
    end

    -- 2. 能源防抖检测
    local energy, max_e = _read_energy()
    if energy < 0 then
        sys_status = SYS_HALT
        return sys_status
    end

    -- 安全整数百分比计算（无溢出）
    local pct = _energy_pct(energy, max_e)

    if pct < 10 then
        low_energy_count = low_energy_count + 1
        if low_energy_count >= 3 then
            sys_status = SYS_RECHARGE
            return sys_status
        end
    else
        low_energy_count = 0
    end

    sys_status = SYS_OK
    return sys_status
end

function health_get_status()
    return sys_status
end

function health_reset()
    low_energy_count = 0
    sys_status       = SYS_OK
    return true, ERR_OK
end

-- ==============================
-- 七、模块导出
-- ==============================
local MODULE = {
    init       = health_init,
    tick       = health_tick,
    get_status = health_get_status,
    reset      = health_reset,

    SYS_OK       = SYS_OK,
    SYS_RECHARGE = SYS_RECHARGE,
    SYS_HALT     = SYS_HALT,

    ERR_OK       = ERR_OK,
    ERR_API_FAIL = ERR_API_FAIL,
}

return MODULE
