--[[
    DZChatCommands - Activity Pressure System for Dynamic Evolution Z

    Adds per-chunk "pressure" that builds over time when players remain in an
    area. Pressure influences three DZ systems:

    1. Leader migration scoring: leaders prefer migrating toward high-pressure
       chunks, drawing organized hordes toward entrenched players.
    2. Evolution acceleration: zombies near high-pressure zones gain evoPoints
       faster, so the zombies that arrive get tougher quicker.
    3. Leader auto-seed rate: higher average pressure increases the desired
       leader count, so more leaders exist to respond.

    Pressure accumulates per-chunk using DZ's own chunk coordinate system
    (Config.MigrationChunkSize, default 10 tiles). Each game-minute, every
    online player's chunk (plus immediate neighbors) gains pressure. Chunks
    decay toward zero when no player is nearby. A fresh area takes ~12
    game-hours of continuous player presence to reach full pressure (1.0).

    Pressure data is persisted to file alongside the existing backup system
    and survives server restarts.

    The migration hook uses debug.getupvalue/debug.setupvalue to extract and
    replace the local evaluateMigrationTargetChunk function inside DZ's
    ApplyLeaderInfluence closure chain.
]]

-- =========================================================================
-- Config
-- =========================================================================

-- Pressure accumulation: gain per game-minute per chunk with a player present.
-- Target: 12 game-hours = 720 game-minutes to reach 1.0.
-- gain = 1.0 / 720 = ~0.00139 per minute.
local PRESSURE_GAIN_PER_MINUTE = 1.0 / 720.0

-- Decay per game-minute for chunks with NO player present.
-- Full pressure decays to 0 in ~24 game-hours without player presence.
-- decay = 1.0 / 1440 = ~0.000694 per minute.
local PRESSURE_DECAY_PER_MINUTE = 1.0 / 1440.0

-- How many chunks around each player receive pressure (Manhattan distance).
-- 1 = player's chunk + immediate 4 neighbors.
local PRESSURE_RADIUS_CHUNKS = 1

-- Pressure weight added to migration scoring formula.
-- At max pressure (1.0) this adds 10 to the chunk score (compared to
-- killWeight*recentKills + densityWeight*headroom, typically 5-15 range).
local MIGRATION_PRESSURE_WEIGHT = 10.0

-- Evolution acceleration: evoPoints bonus per OnZombieUpdate cycle at max
-- pressure. Linear scaling: bonus = pressure * EVO_PRESSURE_MULTIPLIER.
-- At 1.0 pressure a zombie gains +1 bonus point per cycle (doubling the
-- normal 1.0 rate).
local EVO_PRESSURE_MULTIPLIER = 1.0

-- Auto-seed: at max average pressure, desired leaders multiplied by this.
-- Effectively changes LeaderAutoSeedMinPercent (default 1%) up to
-- 1% * SEED_PRESSURE_MAX_MULTIPLIER of active zombies.
local SEED_PRESSURE_MAX_MULTIPLIER = 5.0

-- Extended scan radius for pressure-only migration targets (in chunks).
-- DZ's own migration radius is only 2-4 chunks (20-40 tiles). Pressure
-- should attract leaders from much further away. At max pressure the scan
-- extends to this radius; at lower pressure it linearly interpolates
-- between DZ's radius and this value.
local MIGRATION_PRESSURE_MAX_SCAN_RADIUS = 30  -- 30 chunks = 300 tiles

-- Minimum pressure to have any effect (avoids noise from briefly passing by).
local PRESSURE_MIN_THRESHOLD = 0.01

-- Purge chunks below this pressure to save memory.
local PRESSURE_PURGE_THRESHOLD = 0.001

-- Persistence
local PRESSURE_FILE = "DZChatCommands_Pressure.ini"

-- =========================================================================
-- Internal state
-- =========================================================================

-- Per-chunk pressure: keyed by "wx:wy", value = { pressure = 0..1 }
local chunkPressure = {}

-- Flag to prevent double-install
local pressureInstalled = false

-- Log tag
local LOG_TAG = "[DZChatCommands:Pressure]"

-- =========================================================================
-- Helpers (replicate DZ's chunk coord system exactly)
-- =========================================================================

local function toNumber(value, fallback)
    local n = tonumber(value)
    return n ~= nil and n or fallback
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function getChunkSize()
    local Config = DynamicZ_Config or {}
    return math.max(5, math.floor(toNumber(Config.MigrationChunkSize, 10)))
end

local function worldToChunk(value, chunkSize)
    chunkSize = math.max(1, math.floor(toNumber(chunkSize, 10)))
    value = math.floor(toNumber(value, 0))
    if value >= 0 then
        return math.floor(value / chunkSize)
    end
    return math.floor((value - (chunkSize - 1)) / chunkSize)
end

local function getChunkKey(wx, wy)
    return tostring(math.floor(toNumber(wx, 0))) .. ":" .. tostring(math.floor(toNumber(wy, 0)))
end

local function getChunkCenter(wx, wy)
    local cs = getChunkSize()
    local baseX = math.floor(toNumber(wx, 0)) * cs
    local baseY = math.floor(toNumber(wy, 0)) * cs
    local half = math.floor(cs / 2)
    return baseX + half, baseY + half
end

-- Dedup logger (same pattern as dz_persistence.lua)
local _logLast = nil
local _logLastMs = 0
local function logPressure(msg)
    local s = LOG_TAG .. " " .. tostring(msg)
    local nowMs = getTimestampMs and getTimestampMs() or 0
    if s == _logLast and (nowMs - _logLastMs) < 60000 then return end
    _logLast = s
    _logLastMs = nowMs
    print(s)
end

-- =========================================================================
-- Persistence: read/write pressure data to file
-- =========================================================================

local function writePressureFile()
    local writer = getFileWriter and getFileWriter(PRESSURE_FILE, true, false)
    if not writer then return false end
    local ok, err = pcall(function()
        for key, entry in pairs(chunkPressure) do
            if entry.pressure and entry.pressure >= PRESSURE_PURGE_THRESHOLD then
                writer:writeln(key .. "=" .. string.format("%.6f", entry.pressure))
            end
        end
    end)
    pcall(function() writer:close() end)
    return ok
end

local function readPressureFile()
    local reader = getFileReader and getFileReader(PRESSURE_FILE, false)
    if not reader then return nil end
    local data = {}
    local ok, err = pcall(function()
        local line = reader:readLine()
        while line ~= nil do
            local k, v = line:match("^(.-)=(.+)$")
            if k and v then
                local p = tonumber(v)
                if p and p >= PRESSURE_PURGE_THRESHOLD then
                    data[k] = { pressure = p }
                end
            end
            line = reader:readLine()
        end
    end)
    pcall(function() reader:close() end)
    return ok and data or nil
end

-- =========================================================================
-- Core: accumulate and decay pressure
-- =========================================================================

-- Returns set of chunk keys that have a player present (including neighbors)
local function getPlayerChunks()
    local playerChunks = {}
    local cs = getChunkSize()

    local players = getOnlinePlayers and getOnlinePlayers()
    if not players or not players.size then return playerChunks end

    for i = 0, players:size() - 1 do
        local player = players:get(i)
        if player and player.getX then
            local px = player:getX()
            local py = player:getY()
            if px and py then
                local cx = worldToChunk(px, cs)
                local cy = worldToChunk(py, cs)
                for dx = -PRESSURE_RADIUS_CHUNKS, PRESSURE_RADIUS_CHUNKS do
                    for dy = -PRESSURE_RADIUS_CHUNKS, PRESSURE_RADIUS_CHUNKS do
                        if math.abs(dx) + math.abs(dy) <= PRESSURE_RADIUS_CHUNKS then
                            local key = getChunkKey(cx + dx, cy + dy)
                            playerChunks[key] = true
                        end
                    end
                end
            end
        end
    end
    return playerChunks
end

-- Called once per game-minute. Accumulates pressure in player-occupied chunks,
-- decays all other tracked chunks, purges near-zero entries.
local function tickPressure()
    local playerChunks = getPlayerChunks()

    -- Accumulate for player-occupied chunks
    for key, _ in pairs(playerChunks) do
        local entry = chunkPressure[key]
        if not entry then
            entry = { pressure = 0 }
            chunkPressure[key] = entry
        end
        entry.pressure = clamp(entry.pressure + PRESSURE_GAIN_PER_MINUTE, 0, 1.0)
    end

    -- Decay all tracked chunks that DON'T have a player
    local toRemove = {}
    for key, entry in pairs(chunkPressure) do
        if not playerChunks[key] then
            entry.pressure = math.max(0, entry.pressure - PRESSURE_DECAY_PER_MINUTE)
            if entry.pressure < PRESSURE_PURGE_THRESHOLD then
                toRemove[#toRemove + 1] = key
            end
        end
    end
    for _, key in ipairs(toRemove) do
        chunkPressure[key] = nil
    end
end

-- =========================================================================
-- Query API
-- =========================================================================

-- Get pressure for a specific chunk (0..1)
local function getPressure(wx, wy)
    local key = getChunkKey(wx, wy)
    local entry = chunkPressure[key]
    if not entry then return 0 end
    return entry.pressure or 0
end

-- Get pressure at a world position
local function getPressureAtPos(worldX, worldY)
    local cs = getChunkSize()
    local cx = worldToChunk(worldX, cs)
    local cy = worldToChunk(worldY, cs)
    return getPressure(cx, cy)
end

-- Get average pressure across all tracked chunks (for auto-seed scaling)
local function getAveragePressure()
    local total = 0
    local count = 0
    for _, entry in pairs(chunkPressure) do
        if entry.pressure >= PRESSURE_MIN_THRESHOLD then
            total = total + entry.pressure
            count = count + 1
        end
    end
    if count == 0 then return 0 end
    return total / count
end

-- Get max pressure across all chunks
local function getMaxPressure()
    local maxP = 0
    for _, entry in pairs(chunkPressure) do
        if entry.pressure > maxP then maxP = entry.pressure end
    end
    return maxP
end

-- Get count of pressured chunks
local function getPressuredChunkCount()
    local count = 0
    for _, entry in pairs(chunkPressure) do
        if entry.pressure >= PRESSURE_MIN_THRESHOLD then
            count = count + 1
        end
    end
    return count
end

-- =========================================================================
-- Hook 1: Migration scoring — inject pressure weight
-- =========================================================================

-- Uses debug.getupvalue to extract local functions from DZ's closure chain.
--
-- IMPORTANT: By the time this installs, DynamicZ.ApplyLeaderInfluence has
-- already been replaced by the companion mod's leader fix wrapper. The chain is:
--
-- DynamicZ.ApplyLeaderInfluence  (wrapper from installLeaderFix)
--   -> upvalue: origApplyLeaderInfluence  (original DZ function)
--     -> upvalue: tryUpdateLeaderMigration  (local in DZ_Leader.lua)
--       -> upvalue: evaluateMigrationTargetChunk  (local in DZ_Leader.lua)
--
-- We must traverse TWO levels of upvalues to reach tryUpdateLeaderMigration.

local function installMigrationPressureHook()
    if not DynamicZ or not DynamicZ.ApplyLeaderInfluence then
        logPressure("WARN: ApplyLeaderInfluence not found, skipping migration hook.")
        return false
    end

    -- Step 1: The current ApplyLeaderInfluence is the companion mod's wrapper.
    -- Find the ORIGINAL DZ function stored as 'origApplyLeaderInfluence' upvalue.
    local applyFn = DynamicZ.ApplyLeaderInfluence
    local origApplyFn = nil
    for i = 1, 60 do
        local ok, name, val = pcall(debug.getupvalue, applyFn, i)
        if not ok or name == nil then break end
        if name == "origApplyLeaderInfluence" then
            origApplyFn = val
            break
        end
    end

    -- Fallback: if no wrapper exists (leader fix not installed), try direct
    if not origApplyFn then
        logPressure("No origApplyLeaderInfluence upvalue found, trying direct search.")
        origApplyFn = applyFn
    end

    -- Step 2: Find tryUpdateLeaderMigration in the ORIGINAL function's upvalues
    local tryUpdateIdx, tryUpdateFn = nil, nil
    for i = 1, 60 do
        local ok, name, val = pcall(debug.getupvalue, origApplyFn, i)
        if not ok or name == nil then break end
        if name == "tryUpdateLeaderMigration" then
            tryUpdateIdx = i
            tryUpdateFn = val
            break
        end
    end

    if not tryUpdateFn then
        logPressure("WARN: Could not find tryUpdateLeaderMigration upvalue. Migration hook skipped.")
        return false
    end

    -- Step 2: Find evaluateMigrationTargetChunk in tryUpdateLeaderMigration's upvalues
    local evalIdx, evalFn = nil, nil
    for i = 1, 60 do
        local ok, name, val = pcall(debug.getupvalue, tryUpdateFn, i)
        if not ok or name == nil then break end
        if name == "evaluateMigrationTargetChunk" then
            evalIdx = i
            evalFn = val
            break
        end
    end

    if not evalFn then
        logPressure("WARN: Could not find evaluateMigrationTargetChunk upvalue. Migration hook skipped.")
        return false
    end

    -- Step 3: Also extract helper functions we need from evalFn's closure
    -- We need: getChunkCoordsFromObject, isChunkLoaded, countActiveZombiesInChunk,
    --          getChunkRecentKills, getChunkCenter, getChunkKey, getChunkSize, toNumber, clamp
    -- But we already replicated the chunk helpers above. For the scoring, we
    -- wrap the original and add our pressure term to its result.
    --
    -- Approach: call the original evalFn, then if it returned a result, add
    -- pressure score. Also scan for higher-pressure chunks that the original
    -- may have discarded (because they had too many zombies for the density check).
    -- For simplicity and safety: wrap the original, boost its result, and also
    -- check if any high-pressure chunk nearby would make a better target.

    local function pressureAwareEvaluation(leader, settings, nowHours)
        -- Call original scoring
        local best = evalFn(leader, settings, nowHours)

        -- Add pressure bonus to the original best result
        if best and best.wx ~= nil and best.wy ~= nil then
            local p = getPressure(best.wx, best.wy)
            if p >= PRESSURE_MIN_THRESHOLD then
                best.score = best.score + (MIGRATION_PRESSURE_WEIGHT * p)
                best.pressure = p
            end
        end

        -- Also scan for high-pressure targets well beyond DZ's small migration
        -- radius (2-4 chunks / 20-40 tiles). The pressure scan uses an extended
        -- radius that scales with the max pressure found: at low pressure we
        -- stay close to DZ's radius, at full pressure we scan up to
        -- MIGRATION_PRESSURE_MAX_SCAN_RADIUS chunks (300 tiles).
        -- To keep the scan efficient at large radii, we only check chunks that
        -- actually have pressure entries (sparse iteration) instead of scanning
        -- every chunk in the radius.
        if leader and leader.getX then
            local cs = getChunkSize()
            local leaderCX = worldToChunk(leader:getX(), cs)
            local leaderCY = worldToChunk(leader:getY(), cs)
            local leaderZ = leader.getZ and math.floor(toNumber(leader:getZ(), 0)) or 0
            local dzRadius = math.max(1, math.floor(toNumber(settings.radius, 2)))
            -- Scale scan radius with max pressure: lerp from DZ's radius to max
            local maxP = getMaxPressure()
            local pressureRadius = math.floor(dzRadius + (MIGRATION_PRESSURE_MAX_SCAN_RADIUS - dzRadius) * maxP)

            for key, entry in pairs(chunkPressure) do
                if entry.pressure >= PRESSURE_MIN_THRESHOLD then
                    -- Parse chunk coords from key
                    local kx, ky = key:match("^(-?%d+):(-?%d+)$")
                    kx = tonumber(kx)
                    ky = tonumber(ky)
                    if kx and ky then
                        local dist = math.abs(kx - leaderCX) + math.abs(ky - leaderCY)
                        if dist > 0 and dist <= pressureRadius then
                            -- Score purely from pressure (ignoring density gate)
                            local p = entry.pressure
                            local pressureScore = MIGRATION_PRESSURE_WEIGHT * p
                            if pressureScore > (settings.minimumScore or 3.0) then
                                if not best or pressureScore > best.score then
                                    local tx, ty = getChunkCenter(kx, ky)
                                    best = {
                                        wx = kx, wy = ky,
                                        x = tx, y = ty, z = leaderZ,
                                        score = pressureScore,
                                        recentKills = 0,
                                        zombieCount = 0,
                                        key = key,
                                        pressure = p,
                                    }
                                end
                            end
                        end
                    end
                end
            end
        end

        return best
    end

    -- Step 4: Inject our replacement via debug.setupvalue
    local ok = pcall(debug.setupvalue, tryUpdateFn, evalIdx, pressureAwareEvaluation)
    if not ok then
        logPressure("WARN: debug.setupvalue failed for evaluateMigrationTargetChunk.")
        return false
    end

    logPressure("Migration pressure hook installed (upvalue chain: ApplyLeaderInfluence -> tryUpdateLeaderMigration -> evaluateMigrationTargetChunk).")
    return true
end

-- =========================================================================
-- Hook 2: Evolution acceleration — bonus evoPoints in pressured zones
-- =========================================================================

local function installEvoPressureHook()
    if not DynamicZ or not DynamicZ.TryAddEvolutionPoints then
        logPressure("WARN: TryAddEvolutionPoints not found, skipping evo hook.")
        return false
    end

    local originalTryAdd = DynamicZ.TryAddEvolutionPoints

    DynamicZ.TryAddEvolutionPoints = function(zombie, dz)
        -- Call original first (adds base 1.0 point per cycle)
        originalTryAdd(zombie, dz)

        -- Replicate DZ's guard conditions before adding pressure bonus.
        -- Without these, zombies in pressured chunks gain bonus evo even when
        -- wandering alone far from any player.
        if not zombie or not dz then return end
        if not zombie.getX then return end
        if DynamicZ.IsEvolutionEnabled and not DynamicZ.IsEvolutionEnabled() then return end
        if DynamicZ.CanProcessZombie and not DynamicZ.CanProcessZombie(zombie) then return end
        if DynamicZ.IsZombieInActiveChunk and not DynamicZ.IsZombieInActiveChunk(zombie) then return end
        local target = DynamicZ.GetTargetPlayer and DynamicZ.GetTargetPlayer(zombie) or nil
        if not target then return end
        -- Replicate DZ's close-distance gate (10 tiles squared = 100).
        -- Without this, zombies chasing from far away get the pressure bonus
        -- even though DZ's own TryAddEvolutionPoints would reject them.
        local dx = toNumber(zombie:getX(), 0) - toNumber(target:getX(), 0)
        local dy = toNumber(zombie:getY(), 0) - toNumber(target:getY(), 0)
        if (dx * dx + dy * dy) >= 100 then return end

        local p = getPressureAtPos(zombie:getX(), zombie:getY())
        if p < PRESSURE_MIN_THRESHOLD then return end

        local bonus = p * EVO_PRESSURE_MULTIPLIER
        if bonus <= 0 then return end

        -- Use fractional accumulator (same pattern as DZ's evoPointRemainder)
        local remainder = toNumber(dz._pressureEvoRemainder, 0)
        remainder = remainder + bonus
        local wholePoints = math.floor(remainder)
        dz._pressureEvoRemainder = remainder - wholePoints

        if wholePoints > 0 then
            dz.evoPoints = math.floor(toNumber(dz.evoPoints, 0)) + wholePoints
        end
    end

    logPressure("Evolution pressure hook installed (wraps TryAddEvolutionPoints).")
    return true
end

-- =========================================================================
-- Hook 3: Auto-seed scaling — more desired leaders under pressure
-- =========================================================================

local function installSeedPressureHook()
    if not DynamicZ or not DynamicZ.TryAutoSeedLeaders then
        logPressure("WARN: TryAutoSeedLeaders not found, skipping seed hook.")
        return false
    end
    if not DynamicZ_Config then
        logPressure("WARN: DynamicZ_Config is nil, seed pressure hook would have no effect. Skipping.")
        return false
    end

    local originalTryAutoSeed = DynamicZ.TryAutoSeedLeaders
    local Config = DynamicZ_Config

    DynamicZ.TryAutoSeedLeaders = function()
        local avgPressure = getAveragePressure()
        if avgPressure < PRESSURE_MIN_THRESHOLD then
            -- No significant pressure: run original unchanged
            return originalTryAutoSeed()
        end

        -- Temporarily inflate LeaderAutoSeedMinPercent based on average pressure.
        -- Linear interpolation: at pressure 0 -> 1x, at pressure 1 -> SEED_PRESSURE_MAX_MULTIPLIER x.
        local multiplier = 1.0 + (avgPressure * (SEED_PRESSURE_MAX_MULTIPLIER - 1.0))
        local origPercent = Config.LeaderAutoSeedMinPercent
        local basePercent = toNumber(origPercent, 0.003)
        local boosted = clamp(basePercent * multiplier, 0.0, 0.10)

        Config.LeaderAutoSeedMinPercent = boosted
        local ok, result = pcall(originalTryAutoSeed)
        -- ALWAYS restore original value, even if original threw an error
        Config.LeaderAutoSeedMinPercent = origPercent

        if not ok then
            logPressure("WARN: TryAutoSeedLeaders error: " .. tostring(result))
        end
        return result
    end

    logPressure("Auto-seed pressure hook installed (wraps TryAutoSeedLeaders).")
    return true
end

-- =========================================================================
-- Installation entry point
-- =========================================================================

local function installPressureSystem()
    if pressureInstalled then
        logPressure("Pressure system already installed.")
        return true
    end

    if not DynamicZ then
        logPressure("WARN: DynamicZ not available, cannot install pressure system.")
        return false
    end

    -- Load persisted pressure data
    local saved = readPressureFile()
    if saved then
        chunkPressure = saved
        local count = 0
        for _ in pairs(chunkPressure) do count = count + 1 end
        logPressure(string.format("Loaded %d pressured chunks from file.", count))
    end

    -- Install hooks
    local migOk = installMigrationPressureHook()
    local evoOk = installEvoPressureHook()
    local seedOk = installSeedPressureHook()

    pressureInstalled = true
    logPressure(string.format(
        "Pressure system installed: migration=%s evo=%s seed=%s",
        tostring(migOk), tostring(evoOk), tostring(seedOk)
    ))
    return true
end

-- =========================================================================
-- Tick handler: called from dz_persistence.lua's EveryOneMinute
-- =========================================================================

local _lastPersistMinute = 0
local PERSIST_INTERVAL_MINUTES = 10 -- save to file every 10 game-minutes

local function onPressureTick()
    if not pressureInstalled then return end

    tickPressure()

    -- Periodic persistence
    _lastPersistMinute = _lastPersistMinute + 1
    if _lastPersistMinute >= PERSIST_INTERVAL_MINUTES then
        writePressureFile()
        _lastPersistMinute = 0
    end

    -- Update DynamicZ.Global.activityPressure (the unused placeholder)
    if DynamicZ and DynamicZ.Global then
        DynamicZ.Global.activityPressure = getMaxPressure()
    end
end

-- =========================================================================
-- Chat command: /dz pressure — show pressure map to admin
-- =========================================================================

local function handlePressureCommand(player)
    if not player then return end

    local lines = {}
    lines[#lines + 1] = "=== Activity Pressure Map ==="

    local maxP = getMaxPressure()
    local avgP = getAveragePressure()
    local count = getPressuredChunkCount()
    lines[#lines + 1] = string.format("Tracked chunks: %d", count)
    lines[#lines + 1] = string.format("Max pressure: %.3f", maxP)
    lines[#lines + 1] = string.format("Avg pressure: %.3f", avgP)

    -- Show top 10 highest pressure chunks
    local sorted = {}
    for key, entry in pairs(chunkPressure) do
        if entry.pressure >= PRESSURE_MIN_THRESHOLD then
            sorted[#sorted + 1] = { key = key, pressure = entry.pressure }
        end
    end
    table.sort(sorted, function(a, b) return a.pressure > b.pressure end)

    local showCount = math.min(#sorted, 10)
    if showCount > 0 then
        lines[#lines + 1] = string.format("Top %d chunks:", showCount)
        for i = 1, showCount do
            local e = sorted[i]
            lines[#lines + 1] = string.format("  %s: %.3f", e.key, e.pressure)
        end
    end

    -- Pressure effects summary
    if maxP >= PRESSURE_MIN_THRESHOLD then
        local seedMult = 1.0 + (avgP * (SEED_PRESSURE_MAX_MULTIPLIER - 1.0))
        lines[#lines + 1] = string.format("Evo bonus at max: +%.1f%%", maxP * EVO_PRESSURE_MULTIPLIER * 100)
        lines[#lines + 1] = string.format("Migration weight at max: +%.1f", maxP * MIGRATION_PRESSURE_WEIGHT)
        lines[#lines + 1] = string.format("Seed multiplier (avg): %.1fx", seedMult)
    end

    lines[#lines + 1] = string.format("Spinup time: %.0f game-hours to full", 1.0 / PRESSURE_GAIN_PER_MINUTE / 60)
    lines[#lines + 1] = string.format("Decay time: %.0f game-hours to zero", 1.0 / PRESSURE_DECAY_PER_MINUTE / 60)

    -- Send to player via DebugInfo
    if sendServerCommand then
        for _, line in ipairs(lines) do
            pcall(function()
                sendServerCommand(player, "DynamicZ", "DebugInfo", { message = line })
            end)
        end
    end
end

-- =========================================================================
-- Public API (used by dz_persistence.lua)
-- =========================================================================

DZChatCommands_Pressure = {
    install = installPressureSystem,
    tick = onPressureTick,
    handleCommand = handlePressureCommand,
    getPressure = getPressure,
    getPressureAtPos = getPressureAtPos,
    getAveragePressure = getAveragePressure,
    getMaxPressure = getMaxPressure,
    getPressuredChunkCount = getPressuredChunkCount,
    writePressureFile = writePressureFile,
    isInstalled = function() return pressureInstalled end,
}

logPressure("Pressure module loaded.")
