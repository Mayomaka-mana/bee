-- main.lua — 生命周期守护入口
-- OpenComputers Lua 5.3 / RAM 2048KB
-- 冻结协议：模块加载、顶层异常隔离、主循环调度、安全停机

-- ==============================
-- 零、系统常量
-- ==============================
local HALT_SLEEP     = 5000
local RECHARGE_SLEEP = 2000
local OK_SLEEP_MIN   = 50
local SYS_OK         = 0
local SYS_RECHARGE   = 1
local SYS_HALT       = 2

-- ==============================
-- 一、模块注册表（加载期 require，有序）
-- ==============================
local _mod_storage  = nil
local _mod_genetics = nil
local _mod_health   = nil
local _mod_api_robot = nil
local _mod_core     = nil

-- ==============================
-- 一-B、零闭包辅助函数（加载期定义）
-- ==============================
local function _sleeper(ms)
    os.sleep(ms)
end

-- ==============================
-- 二、BOOT 加载（严格顺序：无依赖先加载）
-- ==============================
local function _boot_load()
    _mod_storage  = require("storage")
    _mod_genetics = require("genetics")
    _mod_health   = require("health")
    _mod_api_robot = require("api_robot")
    _mod_core     = require("core_task")
end

-- ==============================
-- 三、BOOT 初始化（顺序执行）
-- ==============================
local function _boot_init()
    local ok, ec = _mod_storage.init()
    if not ok then return false, ec end
    ok, ec = _mod_health.init()
    if not ok then return false, ec end
    ok, ec = _mod_core.init()
    if not ok then return false, ec end
    return true, 0
end

-- ==============================
-- 四、主循环（零 table 分配、零闭包分配）
-- ==============================
local function _main_loop()
    local sys_code = 0
    local sleep_ms = OK_SLEEP_MIN
    local sleep_sec = 0.0

    while true do
        -- 1. health tick
        local ok, status = pcall(_mod_health.tick)
        if not ok then
            sys_code = SYS_HALT
        else
            sys_code = math.floor(tonumber(status) or SYS_HALT)
        end
        if sys_code < 0 or sys_code > 2 then
            sys_code = SYS_HALT
        end

        -- 2. 路由：HALT / RECHARGE / OK
        if sys_code == SYS_HALT then
            sleep_ms = HALT_SLEEP
        elseif sys_code == SYS_RECHARGE then
            sleep_ms = RECHARGE_SLEEP
        else
            -- SYS_OK: 执行 core_task.tick
            local ok_tick, ms = pcall(_mod_core.tick)
            if not ok_tick then
                sys_code = SYS_HALT
                sleep_ms = HALT_SLEEP
            else
                sleep_ms = math.floor(tonumber(ms) or OK_SLEEP_MIN)
                if sleep_ms < OK_SLEEP_MIN then sleep_ms = OK_SLEEP_MIN end
            end
        end

        -- 3. sleep（零闭包：使用预定义 _sleeper 引用）
        sleep_sec = sleep_ms / 1000
        pcall(_sleeper, sleep_sec)
    end
end

-- ==============================
-- 五、入口（xpcall 顶层保护）
-- ==============================
local function _entry()
    local ok, err = pcall(_boot_load)
    if not ok then return false, "BOOT_LOAD: " .. tostring(err) end

    ok, err = pcall(_boot_init)
    if not ok then return false, "BOOT_INIT: " .. tostring(err) end

    pcall(_main_loop)
    return true, "HALTED"
end

local success, reason = xpcall(_entry, function(crash_err)
    pcall(function()
        if _mod_storage and _mod_storage.save_if_dirty then
            _mod_storage.save_if_dirty()
        end
    end)
    return "CRASH: " .. tostring(crash_err)
end)

if not success then
    pcall(_sleeper, 5)
    pcall(function() computer.shutdown() end)
end