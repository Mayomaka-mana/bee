-- genetics.lua v3 — 纯逻辑ALU（基因解析/压缩/比对/评分）
-- OpenComputers Lua 5.3 / RAM 2048KB
-- 冻结协议：无状态、零分配运行时、静态双缓冲

-- ==============================
-- 零、错误码（整数）
-- ==============================
local ERR_OK            = 0
local ERR_INVALID_INPUT = 1
local ERR_BUFFER_FULL   = 2
local ERR_PARSE_FAIL    = 3
local ERR_PACK_FAIL     = 4
local ERR_COMPARE_FAIL  = 5

-- ==============================
-- 一、静态双缓冲（仅加载期分配一次）
-- ==============================
local BUF1 = {}
local BUF2 = {}
local BUFFER = {BUF1, BUF2}
local _i = 1
while _i <= 13 do
    BUF1[_i] = 0
    BUF2[_i] = 0
    _i = _i + 1
end
local CURRENT_BUF = 1  -- 1 或 2，下一 parse 使用的索引

-- ==============================
-- 二、位压缩布局常量
-- ==============================
-- Fields 1-12: 各 4 bits (0-15)          →  bits 0-47
-- Flags 1-6:  各 1 bit  (显隐性标记)     →  bits 48-53
-- Valid:      1 bit                     →  bit 54
-- 总 55 bits, 安全容纳于 Lua 5.3 64-bit signed integer

local FIELD_BITS   = 4
local FIELD_COUNT  = 12
local FLAG_COUNT   = 6
local FLAG_OFFSET  = FIELD_COUNT * FIELD_BITS  -- 48
local VALID_BIT    = FLAG_OFFSET + FLAG_COUNT  -- 54

-- 计算字段在压缩整数中的位偏移
local function _field_shift(idx)
    return (idx - 1) * FIELD_BITS
end

-- ==============================
-- 二-B、评估权重表常量（仅加载期分配一次）
-- ==============================
local W_PROD = {0, 0, 1, 1, 3, 3, 2, 2, 1, 1, 1, 1, 0}
local W_ASST = {0, 0, 3, 1, 1, 1, 3, 3, 1, 1, 1, 1, 0}

-- ==============================
-- 三、基因解析
-- ==============================

function genetics_parse_gene(raw_data)
    -- raw_data: 包含1-12基因字段整数值的外部 table
    -- 直接覆盖 BUFFER[CURRENT_BUF]，不创建新 table
    -- 返回: success, error_code, buffer_index

    if type(raw_data) ~= "table" then
        return false, ERR_INVALID_INPUT, 0
    end

    local buf = BUFFER[CURRENT_BUF]
    local valid_count = 0
    local idx = 1
    while idx <= 12 do
        local val = tonumber(raw_data[idx]) or 0
        val = math.floor(val)
        if val < 0 then val = 0 end
        if val > 15 then val = 15 end
        buf[idx] = val
        if val ~= 0 then valid_count = valid_count + 1 end
        idx = idx + 1
    end
    buf[13] = 0  -- 重置压缩值

    if valid_count == 0 then
        return false, ERR_PARSE_FAIL, 0
    end

    local ret_idx = CURRENT_BUF
    -- 切换 buffer 供下次 parse
    if CURRENT_BUF == 1 then CURRENT_BUF = 2 else CURRENT_BUF = 1 end
    return true, ERR_OK, ret_idx
end

-- ==============================
-- 四、基因压缩
-- ==============================

function genetics_pack_gene(buffer_index)
    -- 将 BUFFER[buffer_index] 的 12 字段压缩为 64-bit 整数
    -- 返回: success, packed_integer

    if buffer_index ~= 1 and buffer_index ~= 2 then
        return false, 0
    end

    local buf = BUFFER[buffer_index]
    local packed = 0

    -- 打包 12 个字段 (每个 4 bits)
    local idx = 1
    while idx <= 12 do
        local val = buf[idx] & 0xF
        packed = packed | (val << _field_shift(idx))
        idx = idx + 1
    end

    -- 打包 6 个 boolean 标记（显隐性状态）
    -- flag[i]: 字段 i 和字段 i+6 的配对显隐性关系
    -- 若两者任一非零且值不同 → 标记为杂合（flag=1）
    local fi = 1
    while fi <= 6 do
        local a = buf[fi] & 0xF
        local b = buf[fi + 6] & 0xF
        if (a ~= 0 or b ~= 0) and a ~= b then
            packed = packed | (1 << (FLAG_OFFSET + fi - 1))
        end
        fi = fi + 1
    end

    -- Valid sentinel
    packed = packed | (1 << VALID_BIT)

    buf[13] = packed
    return true, packed
end

-- ==============================
-- 五、基因比对
-- ==============================

function genetics_compare(candidate_buf_idx, target_buf_idx, mode)
    -- 比对候选基因与目标基因
    -- mode: 0=Species Priority, 1=Trait Priority
    -- 返回: success, species_score, trait_score

    if candidate_buf_idx ~= 1 and candidate_buf_idx ~= 2 then
        return false, 0, 0
    end
    if target_buf_idx ~= 1 and target_buf_idx ~= 2 then
        return false, 0, 0
    end
    mode = math.floor(tonumber(mode) or 0)
    if mode ~= 0 and mode ~= 1 then mode = 0 end

    local cb = BUFFER[candidate_buf_idx]
    local tb = BUFFER[target_buf_idx]

    local species_score = 0
    local trait_score   = 0

    -- Species 字段: 1-2 (主品种 + 副品种)
    local i = 1
    while i <= 2 do
        if cb[i] == tb[i] then
            species_score = species_score + 8
        elseif cb[i] ~= 0 and tb[i] ~= 0 and cb[i] == tb[3 - i] then
            -- 交叉匹配 (主=副): 部分得分
            species_score = species_score + 3
        end
        i = i + 1
    end

    -- Trait 字段: 3-12
    local j = 3
    while j <= 12 do
        if cb[j] == tb[j] then
            -- 完全匹配
            if mode == 0 then
                trait_score = trait_score + 1
            else
                trait_score = trait_score + 3
            end
        elseif cb[j] ~= 0 and tb[j] ~= 0 then
            -- 非零但不完全相同：部分匹配
            local diff = cb[j] - tb[j]
            if diff < 0 then diff = -diff end
            if diff <= 2 then
                if mode == 0 then
                    trait_score = trait_score + 1
                else
                    trait_score = trait_score + 1
                end
            end
        end
        j = j + 1
    end

    return true, species_score, trait_score
end

-- ==============================
-- 六、基因评估
-- ==============================

function genetics_evaluate(buffer_index, target_type)
    -- 评估单个 buffer 的基因质量
    -- target_type: 0=Production, 1=Assistant
    -- 返回: success, species_score, trait_score

    if buffer_index ~= 1 and buffer_index ~= 2 then
        return false, 0, 0
    end
    target_type = math.floor(tonumber(target_type) or 0)
    if target_type ~= 0 and target_type ~= 1 then target_type = 0 end

    local buf = BUFFER[buffer_index]
    local species_score = 0
    local trait_score   = 0

    -- Species 字段完整性 (1-2)
    local i = 1
    while i <= 2 do
        if buf[i] ~= 0 then
            species_score = species_score + 4
        end
        i = i + 1
    end

    -- Trait 字段权重评估 (3-12)
    -- Production (0): speed(5), fertility(6) 高权重
    -- Assistant (1): lifespan(3), tolerance(7,8) 高权重
    local field_weights
    if target_type == 0 then
        field_weights = W_PROD
    else
        field_weights = W_ASST
    end

    local j = 3
    while j <= 12 do
        if buf[j] ~= 0 then
            trait_score = trait_score + field_weights[j]
        end
        j = j + 1
    end

    -- 布尔基因标记检查 (来自压缩值 flags)
    local packed = buf[13]
    if packed == 0 then
        -- 未压缩，不做 flag 检查
    else
        -- 检查显隐性标记：杂合标记越多表示基因不纯
        local fk = 1
        while fk <= 6 do
            if (packed >> (FLAG_OFFSET + fk - 1)) & 1 == 1 then
                -- 有杂合标记：略微扣减 trait_score
                trait_score = trait_score - 1
                if trait_score < 0 then trait_score = 0 end
            end
            fk = fk + 1
        end
    end

    return true, species_score, trait_score
end

-- ==============================
-- 七、模块导出
-- ==============================
-- 说明：BUFFER table 仅在 require 时分配一次（模块加载期），
-- 所有函数运行时零 table 分配。

local MODULE = {
    parse_gene  = genetics_parse_gene,
    pack_gene   = genetics_pack_gene,
    compare     = genetics_compare,
    evaluate    = genetics_evaluate,

    BUFFER      = BUFFER,

    ERR_OK            = ERR_OK,
    ERR_INVALID_INPUT = ERR_INVALID_INPUT,
    ERR_BUFFER_FULL   = ERR_BUFFER_FULL,
    ERR_PARSE_FAIL    = ERR_PARSE_FAIL,
    ERR_PACK_FAIL     = ERR_PACK_FAIL,
    ERR_COMPARE_FAIL  = ERR_COMPARE_FAIL,
}

return MODULE
