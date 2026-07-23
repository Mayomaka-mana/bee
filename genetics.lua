-- genetics.lua v4 — 纯逻辑ALU（基因解析/压缩/比对/评分 + NBT解码）
-- OpenComputers Lua 5.3 / RAM 2048KB
-- 冻结协议：无状态、零分配运行时、静态双缓冲

-- ==============================
-- 零、NBT 解码依赖（加载期 require）
-- ==============================
local zzlib = require("lib.zzlib")
local nbt   = require("lib.nbt")

-- ==============================
-- 一、错误码（整数）
-- ==============================
local ERR_OK            = 0
local ERR_INVALID_INPUT = 1
local ERR_BUFFER_FULL   = 2
local ERR_PARSE_FAIL    = 3
local ERR_DECODE_FAIL   = 4
local ERR_PACK_FAIL     = 5
local ERR_COMPARE_FAIL  = 6
local ERR_NOT_A_BEE     = 7
local ERR_NBT_FORMAT    = 8

-- ==============================
-- 二、基因等级映射表（字符串 → 整数）
-- ==============================
-- 寿命
local LIFESPAN_MAP = {
    ["forestry.lifespanShortest"]=1, ["forestry.lifespanShorter"]=2,
    ["forestry.lifespanShort"]=3, ["forestry.lifespanShortened"]=4,
    ["forestry.lifespanNormal"]=5, ["forestry.lifespanElongated"]=6,
    ["forestry.lifespanLong"]=7, ["forestry.lifespanLonger"]=8,
    ["forestry.lifespanLongest"]=9, ["gregtech.lifeEon"]=10
}
-- 工作速度
local SPEED_MAP = {
    ["forestry.speedSlowest"]=1, ["forestry.speedSlower"]=2,
    ["forestry.speedSlow"]=3, ["forestry.speedNormal"]=4,
    ["forestry.speedFast"]=5, ["forestry.speedFaster"]=6,
    ["forestry.speedFastest"]=7, ["magicbees.speedBlinding"]=8
}
-- 授粉速度
local FLOWERING_MAP = {
    ["forestry.floweringSlowest"]=1, ["forestry.floweringSlower"]=2,
    ["forestry.floweringSlow"]=3, ["forestry.floweringNormal"]=4,
    ["forestry.floweringFast"]=5, ["forestry.floweringFaster"]=6,
    ["forestry.floweringFastest"]=7, ["forestry.floweringMaximum"]=8
}
-- 生育能力
local FERTILITY_MAP = {
    ["forestry.fertilityLow"]=1, ["forestry.fertilityNormal"]=2,
    ["forestry.fertilityHigh"]=3, ["forestry.fertilityMaximum"]=4
}
-- 活动范围
local TERRITORY_MAP = {
    ["forestry.territoryAverage"]=1, ["forestry.territoryLarge"]=2,
    ["forestry.territoryLarger"]=3, ["forestry.territoryLargest"]=4
}
-- 温度
local TEMPERATURE_MAP = {
    ["Icy"]=1, ["Cold"]=2, ["Normal"]=3,
    ["Warm"]=4, ["Hot"]=5, ["Hellish"]=6
}
-- 湿度
local HUMIDITY_MAP = {
    ["Arid"]=1, ["Normal"]=2, ["Damp"]=3
}
-- 适应性
local TOLERANCE_MAP = {
    ["forestry.toleranceUp1"]=1, ["forestry.toleranceUp2"]=2,
    ["forestry.toleranceUp3"]=3, ["forestry.toleranceUp4"]=4,
    ["forestry.toleranceUp5"]=5, ["forestry.toleranceNone"]=6,
    ["forestry.toleranceDown1"]=7, ["forestry.toleranceDown2"]=8,
    ["forestry.toleranceDown3"]=9, ["forestry.toleranceDown"]=10,
    ["forestry.toleranceDown5"]=11, ["forestry.toleranceBoth1"]=12,
    ["forestry.toleranceBoth2"]=13, ["forestry.toleranceBoth3"]=14,
    ["forestry.toleranceBoth4"]=15, ["forestry.toleranceBoth5"]=16
}

-- ==============================
-- 三、静态双缓冲（仅加载期分配一次）
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
-- 四、位压缩布局常量
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
-- 五、评估权重表常量（仅加载期分配一次）
-- ==============================
local W_PROD = {0, 0, 1, 1, 3, 3, 2, 2, 1, 1, 1, 1, 0}
local W_ASST = {0, 0, 3, 1, 1, 1, 3, 3, 1, 1, 1, 1, 0}

-- ==============================
-- 六、NBT 解码内部函数
-- ==============================

-- zlib解压 + NBT解码原始 tag
local function _decode_nbt_tag(tag_string)
    local ok, result = pcall(zzlib.gunzip, tag_string)
    if not ok then return nil end
    ok, result = pcall(nbt.decode, result)
    if not ok then return nil end
    -- nbt.decode 返回 (success, result, position)
    -- 实际返回格式取决于lib/nbt.lua的实现，尝试提取value
    if type(result) == "table" and result.value then
        return result.value
    end
    return result
end

-- 从NBT tag中解析染色体数据，返回 { [slot] = {uid0, uid1}, ... }
local function _parse_chromosomes(tag)
    if not tag or not tag.Genome then
        return nil
    end
    local chroms = nil
    if type(tag.Genome) == "table" and tag.Genome.Chromosomes then
        chroms = tag.Genome.Chromosomes
    elseif type(tag.Genome) == "table" and tag.Genome.value and tag.Genome.value.Chromosomes then
        chroms = tag.Genome.value.Chromosomes
    else
        return nil
    end

    if type(chroms) == "table" and chroms.value then
        chroms = chroms.value
    end
    if type(chroms) ~= "table" then
        return nil
    end

    local genes = {}
    for _, t in pairs(chroms) do
        if type(t) == "table" then
            local c = t.value or t
            if c.Slot then
                local slot = (type(c.Slot) == "table" and c.Slot.value) or c.Slot
                local uid0 = (type(c.UID0) == "table" and c.UID0.value) or c.UID0
                local uid1 = (type(c.UID1) == "table" and c.UID1.value) or c.UID1
                slot = tonumber(slot) or slot
                genes[slot] = {uid0, uid1}
            else
                -- 没有Slot → 始祖种标记，直接返回 uid0/uid1
                local uid0 = (type(c.UID0) == "table" and c.UID0.value) or c.UID0
                local uid1 = (type(c.UID1) == "table" and c.UID1.value) or c.UID1
                return {["_species"] = {uid0, uid1}}
            end
        end
    end
    return genes
end

-- 从物品stack解析基因 → 内部 buffer
-- 字段映射（染色体slot -> buffer index）:
--   slot 0: species   → buf[1], buf[7]  (active/inactive)
--   slot 1: speed     → buf[2], buf[8]
--   slot 2: lifespan  → buf[3], buf[9]
--   slot 3: fertility → buf[4], buf[10]
--   slot 4: tempToler → buf[5], buf[11]
--   slot 5: nocturnal → buf[6], buf[12]

local function _analyze_stack_intobuffer(stack, buf)
    -- stack 来自 inventory_controller.getStackInInternalSlot
    if not stack or not stack.tag then
        return false, ERR_NBT_FORMAT
    end

    local item_name = stack.name or ""
    if item_name ~= "Forestry:beePrincessGE" and item_name ~= "Forestry:beeDroneGE" then
        return false, ERR_NOT_A_BEE
    end

    local tag = _decode_nbt_tag(stack.tag)
    if not tag then
        return false, ERR_DECODE_FAIL
    end

    local genes = _parse_chromosomes(tag)
    if not genes then
        return false, ERR_PARSE_FAIL
    end

    -- 如果是始祖种(没有Slot)，特殊处理
    if genes._species then
        -- 只有品种信息，其他字段填0
        buf[1] = 1  -- species_active 占位
        buf[7] = 1  -- species_inactive 占位
        local _j = 2
        while _j <= 6 do
            buf[_j] = 0
            buf[_j + 6] = 0
            _j = _j + 1
        end
        buf[13] = 0
        return true, ERR_OK
    end

    -- species (slot 0) — 这里只保留占位值
    buf[1] = 1
    buf[7] = 1

    -- speed (slot 1)
    local speed_g = genes[1] or {"forestry.speedNormal", "forestry.speedNormal"}
    buf[2] = SPEED_MAP[speed_g[1]] or 4
    buf[8] = SPEED_MAP[speed_g[2]] or 4

    -- lifespan (slot 2)
    local life_g = genes[2] or {"forestry.lifespanNormal", "forestry.lifespanNormal"}
    buf[3] = LIFESPAN_MAP[life_g[1]] or 5
    buf[9] = LIFESPAN_MAP[life_g[2]] or 5

    -- fertility (slot 3)
    local fert_g = genes[3] or {"forestry.fertilityNormal", "forestry.fertilityNormal"}
    buf[4] = FERTILITY_MAP[fert_g[1]] or 2
    buf[10] = FERTILITY_MAP[fert_g[2]] or 2

    -- temperatureTolerance (slot 4)
    local ttol_g = genes[4] or {"forestry.toleranceNone", "forestry.toleranceNone"}
    buf[5] = TOLERANCE_MAP[ttol_g[1]] or 6
    buf[11] = TOLERANCE_MAP[ttol_g[2]] or 6

    -- nocturnal/boolean (slot 5)
    local noc_g = genes[5] or {"forestry.boolFalse", "forestry.boolFalse"}
    buf[6] = (noc_g[1] == "forestry.boolTrue") and 1 or 0
    buf[12] = (noc_g[2] == "forestry.boolTrue") and 1 or 0

    buf[13] = 0  -- packed到时会重新计算

    return true, ERR_OK
end

-- ==============================
-- 七、Public API
-- ==============================

-- 从物品原始数据解析基因 → 内部buffer
function genetics_analyze_stack(stack)
    if type(stack) ~= "table" then
        return false, ERR_INVALID_INPUT, 0
    end

    local buf = BUFFER[CURRENT_BUF]
    -- 清空buffer
    local ci = 1
    while ci <= 13 do
        buf[ci] = 0
        ci = ci + 1
    end

    local ok, ec = _analyze_stack_intobuffer(stack, buf)
    if not ok then
        return false, ec, 0
    end

    local ret_idx = CURRENT_BUF
    -- 切换buffer
    if CURRENT_BUF == 1 then CURRENT_BUF = 2 else CURRENT_BUF = 1 end
    return true, ERR_OK, ret_idx
end

-- 基因解析（兼容旧接口：从已解析数据表读取）
function genetics_parse_gene(raw_data)
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
    buf[13] = 0
    if valid_count == 0 then
        return false, ERR_PARSE_FAIL, 0
    end
    local ret_idx = CURRENT_BUF
    -- 切换 buffer 供下次 parse
    if CURRENT_BUF == 1 then CURRENT_BUF = 2 else CURRENT_BUF = 1 end
    return true, ERR_OK, ret_idx
end

-- 基因压缩
function genetics_pack_gene(buffer_index)
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

-- 基因比对
function genetics_compare(candidate_buf_idx, target_buf_idx, mode)
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
            species_score = species_score + 3
        end
        i = i + 1
    end
    -- Trait 字段: 3-12
    local j = 3
    while j <= 12 do
        if cb[j] == tb[j] then
            if mode == 0 then
                trait_score = trait_score + 1
            else
                trait_score = trait_score + 3
            end
        elseif cb[j] ~= 0 and tb[j] ~= 0 then
            local diff = cb[j] - tb[j]
            if diff < 0 then diff = -diff end
            if diff <= 2 then
                trait_score = trait_score + 1
            end
        end
        j = j + 1
    end
    return true, species_score, trait_score
end

-- 基因评估
function genetics_evaluate(buffer_index, target_type)
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
    if packed ~= 0 then
        local fk = 1
        while fk <= 6 do
            if (packed >> (FLAG_OFFSET + fk - 1)) & 1 == 1 then
                trait_score = trait_score - 1
                if trait_score < 0 then trait_score = 0 end
            end
            fk = fk + 1
        end
    end

    return true, species_score, trait_score
end

-- ==============================
-- 八、模块导出
-- ==============================
local MODULE = {
    -- 新接口：从物品直接解析
    analyze_stack = genetics_analyze_stack,
    -- 旧接口兼容
    parse_gene    = genetics_parse_gene,
    pack_gene     = genetics_pack_gene,
    compare       = genetics_compare,
    evaluate      = genetics_evaluate,

    BUFFER        = BUFFER,

    ERR_OK            = ERR_OK,
    ERR_INVALID_INPUT = ERR_INVALID_INPUT,
    ERR_BUFFER_FULL   = ERR_BUFFER_FULL,
    ERR_PARSE_FAIL    = ERR_PARSE_FAIL,
    ERR_DECODE_FAIL   = ERR_DECODE_FAIL,
    ERR_PACK_FAIL     = ERR_PACK_FAIL,
    ERR_COMPARE_FAIL  = ERR_COMPARE_FAIL,
    ERR_NOT_A_BEE     = ERR_NOT_A_BEE,
    ERR_NBT_FORMAT    = ERR_NBT_FORMAT,
}

return MODULE
