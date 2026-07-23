local M = {}

function M.getTemperatureLevel(temperature, biomeTypes)
    if type(temperature) ~= "number" then
        error("温度必须为数字")
    end
    for _, biomeType in ipairs(biomeTypes or {}) do
        if biomeType == "nether" then
            return 3 --地狱
        end
    end
    if temperature <= 0 then
        return -2 --严寒
    elseif temperature < 0.35 then
        return -1 --寒冷
    elseif temperature < 0.85 then
        return 0 --一般
    elseif temperature <= 1 then
        return 1 --温暖
    else
        return 2 --炙热
    end
end

function M.getHumidityLevel(rainfall)
    if type(rainfall) ~= "number" then
        error("降雨量必须为数字")
    end
    if rainfall <= 0.2 then
        return -1 --干旱
    elseif rainfall <= 0.8 then
        return 0 --一般
    else
        return 1 --潮湿
    end
end

function M.getTemperatureRange(temperatureGene, toleranceGene)
    if type(temperatureGene) ~= "number" or type(toleranceGene) ~= "string" then
        return nil
    end
    local tolerance = toleranceGene == "NONE" and 0 or tonumber(toleranceGene:match("_(%d+)$"))
    if tolerance == nil then
        return nil
    end
    local temperatureUpperLimit, temperatureLowerLimit = temperatureGene, temperatureGene
    if toleranceGene:sub(1,3) == "BOT" or toleranceGene:sub(1,3) == "UP_" then
        temperatureUpperLimit = temperatureUpperLimit + tolerance
    end
    if toleranceGene:sub(1,3) == "BOT" or toleranceGene:sub(1,3) == "DOW" then
        temperatureLowerLimit = temperatureLowerLimit - tolerance
    end
    return math.max(temperatureLowerLimit, -2), math.min(temperatureUpperLimit, 3)
end

function M.getHumidityRange(humidityGene, toleranceGene)
    if type(humidityGene) ~= "number" or type(toleranceGene) ~= "string" then
        return nil
    end
    local tolerance = toleranceGene == "NONE" and 0 or tonumber(toleranceGene:match("_(%d+)$"))
    if tolerance == nil then
        return nil
    end
    local humidityUpperLimit, humidityLowerLimit = humidityGene, humidityGene
    if toleranceGene:sub(1,3) == "BOT" or toleranceGene:sub(1,3) == "UP_" then
        humidityUpperLimit = humidityUpperLimit + tolerance
    end
    if toleranceGene:sub(1,3) == "BOT" or toleranceGene:sub(1,3) == "DOW" then
        humidityLowerLimit = humidityLowerLimit - tolerance
    end
    return math.max(humidityLowerLimit, -1), math.min(humidityUpperLimit, 1)
end



return M