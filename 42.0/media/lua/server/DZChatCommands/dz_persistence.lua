--[[
    DZChatCommands - Server-side persistence fix for Dynamic Evolution Z

    Problems fixed:
    1. ModData.getOrCreate("DynamicZ_Global") returns empty table on dedicated
       server restart, losing all saved state.
    2. RecalculateWorldEvolution is never called on startup, so world age
       is not reflected until the first zombie dies or midnight passes.
    3. The DZ mod calls gameTime:getWorldAgeDays() but that method is on
       IsoWorld, not GameTime. So DZ always computes days=0.
       We use getWorldAgeHours()/24 or getWorldAgeDaysSinceBegin() instead.
    4. Events.OnGameStart.Add may not fire on dedicated servers (DZ uses
       addEvent which may work differently). We use EveryOneMinute fallback.
    5. DZ registers AdvanceLeaderTick on "EveryOneSecond" which does not exist
       in PZ. pulseId stays 0, leader system is dead. Fixed via OnTick.
    6. DZ registers RecalculateWorldEvolution on "OnMidnight" which does not
       exist in PZ. World evolution never recalculates during play. Fixed via
       EveryDays (fires at in-game day rollover).
    7. DZ calls getNumActiveZombies() which does not exist in Build 42.
       Auto-seeding never triggers, max leaders capped at 1. Fixed via
       polyfill using getCell():getZombieList():size().
    8. DZ's search-after-target-loss uses setLastHeardSound which is dead
       code in PZ B42 (field written but never read by any game logic).
       Evolved zombies should search the player's last known position
       after losing sight, but the call has zero behavioral effect. Fixed
       by wrapping ApplyStageEvolutionBuffs with pathToLocationF (A*-capable
       pathfinding via PathFindBehavior2/PolygonalMap2). Enhanced with
       player ID tracking: stores the targeted player's onlineID/username
       while the zombie has a target, then looks them up via
       getPlayerByOnlineID (O(1) HashMap, LuaManager.java:3488) after
       target loss to path toward the player's CURRENT position instead
       of a stale last-known location. Re-paths every 3 seconds for the
       duration of DZ's search window (computeSearchWindowHours, based on
       stage and persistence buff). Falls back to static last-known
       position if the player disconnected or died. Tracking is strictly
       time-limited (never infinite). Also compensates for the
       inaccessible zombie.memory field: setTarget won't stick because
       timeSinceSeenFlesh can't be reset from Lua (it's a field, not a
       method), so repeated pathToLocation tracking is the best
       equivalent to extended memory.
    9. DZ's applyStage4Sense calls dead setLastHeardSound when a stage 4+
       zombie senses a nearby player (without direct line of sight). The
       zombie should investigate toward the sensed player but never moves.
       Fixed by extending the ApplyStageEvolutionBuffs wrapper to also
       replicate findNearestPlayer and call pathToLocationF to the detected
       player's current position.
   10. DZ's TryAmbientWander calls dead setLastHeardSound to make idle
       zombies wander toward computed target positions (influenced by nearby
       player presence and reactive kill signals). The zombie never moves.
       Fixed by wrapping TryAmbientWander to read the stored target coords
       from modData and call pathToLocationF after the original succeeds.
   11. DZ's leader system (ApplyLeaderInfluence) calls dead setLastHeardSound
       to direct followers toward the leader's target, leader's position,
       or migration waypoints. Followers never actually move toward these
       coordinates. Fixed by wrapping ApplyLeaderInfluence to iterate
       influenced followers and call pathToLocationF with the appropriate
       coordinates per leader type (HUNTER/FRENZY/SHADOW/HIVE: leader's
       target or leader position; SPLIT: 3-way flanking offset computed
       from follower position hash, replicating DZ's local computeSplitPoint;
       migrating: blended migration target).
   12. DZ's getWorldAgeDaysSafe() (local in DZ_GlobalState.lua) has a fallback
       path that uses getWorldAgeHours()/24 without adding the timeSinceApo
       sandbox offset. The primary path (getWorldAgeDaysSinceBegin) includes
       it, but if that pcall ever fails, the fallback silently drops the
       offset. Since getWorldAgeDaysSafe is local, it can't be patched.
       Fixed by replacing the entire DynamicZ.RecalculateWorldEvolution
       function with one that uses the companion mod's corrected
       getWorldAgeDays() (which always includes timeSinceApo).
   13. DZ's AdvanceLeaderTick uses Config.LeaderPulseInterval with a
       hardcoded fallback of 180. Since LeaderPulseInterval is not in
       DZ's default sandbox config, the fallback always applies: pulses
       fire every 180 ticks = 180 seconds = 3 minutes. Leaders only act
       (TryLeaderPulse) when a pulse fires, making the leader system
       extremely sluggish. Fixed by replacing AdvanceLeaderTick with a
       version using fallback=3 (pulse every 3 seconds).
   15. DZ registers DebugTrackTick on "EveryOneSecond" (DZ_Debug.lua:1501)
       which does not exist in PZ. The server-side zombie tracking feature
       (admin inspect/track with diff-snapshots and auto-updates) never ticks.
       Fixed by calling DynamicZ.DebugTrackTick() from the OnTick handler
       alongside AdvanceLeaderTick. DebugTrackTick has its own internal
       time-based throttle (getNowHours vs nextTickHour using
       Config.DebugTrackIntervalSeconds, default 2s), so calling it every
       ~1 second from OnTick is appropriate — it will self-throttle.
   14. DZ's local getZombieDebugId (DZ_Leader.lua:43) checks
       DynamicZ.GetZombieDebugId first, then falls back to position
       "P:x:y:z". By default GetZombieDebugId is nil, so all debug
       logging uses ambiguous position strings. Fixed by setting
       GetZombieDebugId to try getOnlineID ("O<id>"), then getID
       ("R<id>" — IsoMovingObject's monotonic counter), then position.
       This also improves getZombieRuntimeId's fallback chain (line 188
       calls getZombieDebugId as its last resort).
   16. DZ's SyncVanillaKillCounter uses a single global vanillaKillBaseline
       that resets on server restart (set to 0 at OnGameStart when no players
       are connected yet). On dedicated server, EveryOneSecond is dead so the
       sync never runs again — totalKills only grows from OnZombieDead events
       and resets to 0 on every restart (ModData persistence bug). Fixed by
       replacing SyncVanillaKillCounter with a vanilla-truth sync: tracks
       each player's getZombieKills() (persisted to file for offline players),
       sets totalKills = max(totalKills, sum of all player kills). The vanilla
       counter is PZ's own persistent source of truth — survives restarts
       without any backup needed.

    Unfixable from companion mod (require upstream changes):
    - zombie:getMemory()/setMemory() don't exist. memory is a public int
      field but PZ's Kahlua bridge only exposes methods, not fields.
      The memory buff itself is dead, but fix #8 provides a behavioral
      workaround (active search instead of passive forget-time extension).
    - getZombieRuntimeId() uses getObjectID() which doesn't exist on
      IsoZombie. Local function, can't override. However, it tries
      getOnlineID() first (works in MP), so this is NOT broken on
      dedicated servers. Fix 14 improves the final fallback (position ->
      getID-based) since getZombieRuntimeId calls getZombieDebugId at
      line 188 as its last resort.

    Solution:
    - Wraps DynamicZ.SaveGlobalState to also write a backup file via
      getFileWriter (independent of ModData).
    - After DZ initializes, restores from backup + computes correct
      worldEvolution using the actual world age.
    - Polyfills missing global functions (getNumActiveZombies).
    - Wraps ApplyStageEvolutionBuffs (fixes 8, 9), TryAmbientWander (fix 10),
      and ApplyLeaderInfluence (fix 11) to replace dead setLastHeardSound
      calls with pathToLocationF.
    - Replaces SyncVanillaKillCounter with vanilla-truth sync (fix 16):
      uses each player's getZombieKills() as persistent source of truth.
    - Provides "ForceSave" and "Diagnostics" network commands.
]]

local BACKUP_FILE = "DZChatCommands_GlobalState.ini"
local PLAYER_KILLS_FILE = "DZChatCommands_PlayerKills.ini"
local NET_MODULE = "DZChatCmds"
local LOG_TAG = "[DZChatCommands]"

local fixupComplete = false

-- Per-player last-known kills: keyed by username, value = getZombieKills().
-- Updated every sync for connected players, persisted to file for offline
-- players. totalKills = max(totalKills, sum of all entries). The vanilla
-- kill counter is the source of truth — it persists across restarts in PZ's
-- own save data, so we never lose kill history.
local playerKills = {}

-- Polyfill: getNumActiveZombies() does not exist in Build 42.
-- DZ_Leader.lua calls it for auto-seeding and max leader calculation.
-- Without it, getNumActiveZombiesSafe() returns 0, auto-seeding never
-- triggers, and max leaders is capped at 1.
-- Uses getCell():getZombieList():size() — the same pattern DZ itself uses
-- in recountLoadedLeaders() and TryAutoSeedLeaders.
if not getNumActiveZombies then
    function getNumActiveZombies()
        local cell = getCell and getCell()
        if not cell then return 0 end
        local ok, zombieList = pcall(function() return cell:getZombieList() end)
        if not ok or not zombieList then return 0 end
        local ok2, size = pcall(function() return zombieList:size() end)
        if not ok2 then return 0 end
        return size
    end
end

local function toNumber(value, fallback)
    local n = tonumber(value)
    return n ~= nil and n or fallback
end

-- Iterate all active players. Matches DZ's forEachActivePlayer pattern:
-- tries getOnlinePlayers() first, falls back to getNumActivePlayers() +
-- getSpecificPlayer(i) for singleplayer where getOnlinePlayers() returns
-- an empty list.
local function forEachActivePlayer(callback)
    if not callback then return end

    if getOnlinePlayers then
        local players = getOnlinePlayers()
        if players and players.size and players.get and players:size() > 0 then
            for i = 0, players:size() - 1 do
                local player = players:get(i)
                if player then
                    callback(player)
                end
            end
            return
        end
    end

    -- Singleplayer fallback: getOnlinePlayers() returns empty list
    if not getNumActivePlayers or not getSpecificPlayer then return end
    local count = math.max(0, math.floor(toNumber(getNumActivePlayers(), 0)))
    for i = 0, count - 1 do
        local player = getSpecificPlayer(i)
        if player then
            callback(player)
        end
    end
end

-- Deduplicating logger: suppresses identical messages within a 60s window.
-- Changed or new messages print immediately. Same message re-prints after 60s.
local _logLastMessage = nil
local _logLastMs = 0
local _LOG_DEDUP_MS = 60000

local function logInfo(message)
    local msg = tostring(message)
    local nowMs = getTimestampMs and getTimestampMs() or 0
    if msg == _logLastMessage and (nowMs - _logLastMs) < _LOG_DEDUP_MS then
        return
    end
    _logLastMessage = msg
    _logLastMs = nowMs
    print(LOG_TAG .. " " .. msg)
end

local function clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

-- Submit an A* path request to make a zombie navigate to a location.
-- Uses PathFindBehavior2.pathToLocationF which bypasses CanUsePathfindState
-- Look up the last targeted player by stored onlineID or username.
-- Uses getPlayerByOnlineID (O(1) HashMap, LuaManager.java:3488) first,
-- falls back to username scan via getOnlinePlayers if player reconnected
-- with a new onlineID. Returns the IsoPlayer or nil.
local function lookupLastTargetPlayer(dz)
    if not dz then return nil end

    -- Fast path: O(1) lookup by onlineID (works in MP)
    local onlineID = dz._lastTargetOnlineID
    if onlineID and getPlayerByOnlineID then
        local ok, player = pcall(getPlayerByOnlineID, onlineID)
        if ok and player then
            -- Verify player is alive
            local alive = true
            if player.isDead then
                local okD, dead = pcall(function() return player:isDead() end)
                if okD and dead then alive = false end
            end
            if alive then return player end
        end
    end

    -- Fallback: username scan (handles reconnect with new onlineID)
    local username = dz._lastTargetUsername
    if username and getOnlinePlayers then
        local ok, players = pcall(getOnlinePlayers)
        if ok and players and players.size then
            for i = 0, players:size() - 1 do
                local p = players:get(i)
                if p and p.username == username then
                    local alive = true
                    if p.isDead then
                        local okD, dead = pcall(function() return p:isDead() end)
                        if okD and dead then alive = false end
                    end
                    if alive then
                        -- Update cached onlineID for faster future lookups
                        if p.getOnlineID then
                            local okID, id = pcall(function() return p:getOnlineID() end)
                            if okID then dz._lastTargetOnlineID = id end
                        end
                        return p
                    end
                end
            end
        end
    end

    return nil
end

-- Submit an A* pathfinding request via PathFindBehavior2.pathToLocationF
-- (works on dedicated server). Sets animation variables to trigger movement.
-- Returns true on success, false on error.
local function pathToLocation(zombie, x, y, z)
    local ok = pcall(function()
        local pathBehavior = zombie:getPathFindBehavior2()
        if pathBehavior and pathBehavior.pathToLocationF then
            pathBehavior:pathToLocationF(x, y, z)
            zombie:setVariable("bPathfind", true)
            zombie:setVariable("bMoving", false)
        end
    end)
    return ok
end

-- Find the nearest alive player within maxDistanceSq of a zombie.
-- Replicates DZ_Evolution.lua's local findNearestPlayer function.
-- Uses getOnlinePlayers() with Z-level check (±1 floor).
-- Returns (player, distSq) or (nil, nil).
local function findNearestPlayerInRadius(zombie, maxDistanceSq)
    if not zombie or not zombie.getX then return nil, nil end

    local zx = toNumber(zombie:getX(), 0)
    local zy = toNumber(zombie:getY(), 0)
    local zz = math.floor(toNumber(zombie:getZ(), 0))
    local bestPlayer = nil
    local bestDistSq = nil

    if getOnlinePlayers then
        local players = getOnlinePlayers()
        if players and players.size and players.get then
            for i = 0, players:size() - 1 do
                local player = players:get(i)
                if player and (not player.isDead or not player:isDead()) then
                    local pz = math.floor(toNumber(player:getZ(), 0))
                    if math.abs(pz - zz) <= 1 then
                        local px = toNumber(player:getX(), 0)
                        local py = toNumber(player:getY(), 0)
                        local dx = zx - px
                        local dy = zy - py
                        local distSq = (dx * dx) + (dy * dy)
                        if distSq <= maxDistanceSq and (bestDistSq == nil or distSq < bestDistSq) then
                            bestPlayer = player
                            bestDistSq = distSq
                        end
                    end
                end
            end
        end
    elseif getNumActivePlayers and getSpecificPlayer then
        local count = math.max(0, math.floor(toNumber(getNumActivePlayers(), 0)))
        for i = 0, count - 1 do
            local player = getSpecificPlayer(i)
            if player and (not player.isDead or not player:isDead()) then
                local pz = math.floor(toNumber(player:getZ(), 0))
                if math.abs(pz - zz) <= 1 then
                    local px = toNumber(player:getX(), 0)
                    local py = toNumber(player:getY(), 0)
                    local dx = zx - px
                    local dy = zy - py
                    local distSq = (dx * dx) + (dy * dy)
                    if distSq <= maxDistanceSq and (bestDistSq == nil or distSq < bestDistSq) then
                        bestPlayer = player
                        bestDistSq = distSq
                    end
                end
            end
        end
    end

    return bestPlayer, bestDistSq
end

-- Get world age in hours for search window calculation.
-- Replicates DZ_Evolution.lua's local getNowHours() function.
local function getNowHours()
    if not getGameTime then return 0 end
    local gameTime = getGameTime()
    if not gameTime or not gameTime.getWorldAgeHours then return 0 end
    return toNumber(gameTime:getWorldAgeHours(), 0)
end

-- Compute DZ's search window duration (in hours) for a given evolution stage.
-- Replicates getStageBuffValues (local in DZ_Evolution.lua) for the search
-- and persistence buff components, then applies DZ's search window formula
-- from applyPersistenceAndSearch: baseSearchSeconds * (1 + search + persistence*0.5).
local function computeSearchWindowHours(stage)
    local Config = DynamicZ_Config or {}
    local step = clamp(toNumber(Config.StageBuffStep, 0.05), 0.0, 0.20)
    local cap = clamp(toNumber(Config.StageBuffCap, 0.20), 0.0, 0.30)

    local persistence = 0.0
    local search = 0.0
    if stage >= 1 then persistence = persistence + step; search = search + step end
    if stage >= 4 then persistence = persistence + step end
    persistence = clamp(persistence, 0.0, cap)
    search = clamp(search, 0.0, cap)

    local baseSearchSeconds = math.max(4.0, toNumber(Config.StageSearchBaseSeconds, 12.0))
    local searchSeconds = baseSearchSeconds * (1.0 + search + (persistence * 0.5))
    return searchSeconds / 3600.0
end

-- Get world age in days from game time.
-- CRITICAL: gameTime:getWorldAgeDays() is on IsoWorld, NOT GameTime.
-- DZ_GlobalState.lua has this bug (line 80) — RecalculateWorldEvolution always
-- gets days=0 because gameTime.getWorldAgeDays is nil.
-- We use getWorldAgeHours()/24 which IS proven from vanilla PZ Lua
-- (ISPlowAction, forageSystem, ISWeatherChannel, Vehicles, etc.).
-- The timeSinceApo offset uses the exact vanilla pattern from ISWeatherChannel.lua:
--   getGameTime():getWorldAgeHours() / 24 + (getSandboxOptions():getTimeSinceApo() - 1) * 30
local function getWorldAgeDays()
    if getGameTime then
        local gameTime = getGameTime()
        if gameTime then
            -- Primary: getWorldAgeHours / 24 (proven in vanilla PZ Lua)
            if gameTime.getWorldAgeHours then
                local hours = toNumber(gameTime:getWorldAgeHours(), 0)
                local days = hours / 24.0
                -- Add timeSinceApo offset (vanilla pattern from ISWeatherChannel.lua)
                if getSandboxOptions then
                    local opts = getSandboxOptions()
                    if opts and opts.getTimeSinceApo then
                        days = days + (toNumber(opts:getTimeSinceApo(), 1) - 1) * 30
                    end
                end
                return days
            end
            -- Fallback: getNightsSurvived (also proven in vanilla ISWeatherChannel.lua)
            if gameTime.getNightsSurvived then
                return toNumber(gameTime:getNightsSurvived(), 0)
            end
        end
    end
    -- Last resort: IsoWorld has getWorldAgeDays (not GameTime)
    if getWorld then
        local world = getWorld()
        if world and world.getWorldAgeDays then
            return toNumber(world:getWorldAgeDays(), 0)
        end
    end
    logInfo("getWorldAgeDays: no method available to determine world age")
    return 0
end

-- Compute worldEvolution directly using DZ's formula.
-- This is needed because:
-- 1. RecalculateWorldEvolution may return early (evo disabled)
-- 2. RecalculateWorldEvolution uses the broken getWorldAgeDays on GameTime
--    and always gets days=0. We use the correct method.
local function computeWorldEvolution(totalKills)
    local Config = DynamicZ_Config or {}
    local timeFactor = toNumber(Config.TimeFactor, 0.005)
    local killFactor = toNumber(Config.KillFactor, 0.0005)
    local maxEvo = toNumber(Config.MaxWorldEvolution, 1.0)
    local days = getWorldAgeDays()
    local kills = toNumber(totalKills, 0)

    local evo = (days * timeFactor) + (kills * killFactor)
    evo = clamp(evo, 0.0, maxEvo)

    logInfo(string.format(
        "computeWorldEvolution: days=%.1f * timeFactor=%.4f + kills=%d * killFactor=%.5f = %.4f (max=%.1f)",
        days, timeFactor, kills, killFactor, evo, maxEvo))

    return evo
end

-- File-based backup write
local function writeBackup()
    local g = DynamicZ and DynamicZ.Global
    if not g then
        logInfo("WARN writeBackup: DynamicZ.Global is nil, cannot write.")
        return false
    end

    local ok, writer = pcall(getFileWriter, BACKUP_FILE, true, false)
    if not ok or not writer then
        logInfo("WARN writeBackup: getFileWriter failed: " .. tostring(writer))
        return false
    end

    local kills = math.floor(toNumber(g.totalKills, 0))
    local evo = toNumber(g.worldEvolution, 0.0)
    local leaders = math.floor(toNumber(g.activeLeaders, 0))
    local pressure = toNumber(g.activityPressure, 0.0)

    writer:write("totalKills=" .. tostring(kills) .. "\n")
    writer:write("worldEvolution=" .. tostring(evo) .. "\n")
    writer:write("activeLeaders=" .. tostring(leaders) .. "\n")
    writer:write("activityPressure=" .. tostring(pressure) .. "\n")
    writer:close()

    logInfo(string.format("Backup written: kills=%d evo=%.4f leaders=%d pressure=%.4f",
        kills, evo, leaders, pressure))
    return true
end

-- File-based backup read
local function readBackup()
    local ok, reader = pcall(getFileReader, BACKUP_FILE, false)
    if not ok or not reader then return nil end

    local data = {}
    local line = reader:readLine()
    while line ~= nil do
        local key, value = line:match("^(%w+)=(.+)$")
        if key and value then
            data[key] = tonumber(value)
        end
        line = reader:readLine()
    end
    reader:close()

    logInfo(string.format("Backup read: kills=%s evo=%s",
        tostring(data.totalKills), tostring(data.worldEvolution)))
    return data
end

-- Write per-player last-known kills to file.
-- Format: one line per player "username=kills"
local function writePlayerKills()
    local ok, writer = pcall(getFileWriter, PLAYER_KILLS_FILE, true, false)
    if not ok or not writer then return false end

    for username, kills in pairs(playerKills) do
        writer:write(tostring(username) .. "=" .. tostring(math.floor(kills)) .. "\n")
    end
    writer:close()
    return true
end

-- Read per-player last-known kills from file.
-- Returns table keyed by username -> kill count.
local function readPlayerKills()
    local ok, reader = pcall(getFileReader, PLAYER_KILLS_FILE, false)
    if not ok or not reader then return {} end

    local data = {}
    local line = reader:readLine()
    while line ~= nil do
        local key, value = line:match("^(.+)=(%d+)$")
        if key and value then
            data[key] = tonumber(value) or 0
        end
        line = reader:readLine()
    end
    reader:close()
    return data
end

-- Vanilla kill sync. Replaces DZ's broken SyncVanillaKillCounter.
--
-- Uses each player's getZombieKills() as the source of truth. The vanilla
-- counter persists in PZ's own save data and never loses kills, unlike
-- DZ's ModData-based totalKills which resets on dedicated server restart.
--
-- Tracks last-known kills per player (persisted to file for offline players).
-- On each sync: update connected players, sum all entries (online + offline),
-- set totalKills = max(totalKills, sum). OnZombieDead can push totalKills
-- higher (non-player kills like fire/vehicles), which is preserved by the
-- max() — vanilla kills are a floor, not a ceiling.
local function syncVanillaKills()
    if not DynamicZ or not DynamicZ.Global then return end

    local changed = false

    forEachActivePlayer(function(player)
        if not player.getZombieKills or not player.getUsername then return end
        local username = tostring(player:getUsername())
        local currentKills = math.max(0, math.floor(toNumber(player:getZombieKills(), 0)))

        local prev = playerKills[username]
        if prev == nil or currentKills > math.floor(prev) then
            playerKills[username] = currentKills
            changed = true
        end
    end)

    if changed then
        writePlayerKills()
    end

    -- Sum all known player kills (online + offline from file)
    local vanillaSum = 0
    for _, kills in pairs(playerKills) do
        vanillaSum = vanillaSum + math.floor(kills)
    end

    -- totalKills = max(current, vanilla sum). OnZombieDead may have pushed
    -- totalKills above the vanilla sum (non-player kills), so never decrease.
    local currentTotal = math.floor(toNumber(DynamicZ.Global.totalKills, 0))
    if vanillaSum > currentTotal then
        DynamicZ.Global.totalKills = vanillaSum
        logInfo(string.format("Kill sync: totalKills %d -> %d (vanilla sum)", currentTotal, vanillaSum))
        if DynamicZ.RecalculateWorldEvolution then
            DynamicZ.RecalculateWorldEvolution()
        elseif DynamicZ.SaveGlobalState then
            DynamicZ.SaveGlobalState()
        end
    end

    -- Reset killAddsFromEvents so DZ's own bookkeeping stays clean
    if DynamicZ.Runtime then
        DynamicZ.Runtime.killAddsFromEvents = 0
    end
end

-- Wrap DynamicZ.SaveGlobalState to also write backup file
local function installSaveHook()
    if not DynamicZ or not DynamicZ.SaveGlobalState then
        logInfo("WARN installSaveHook: DynamicZ.SaveGlobalState not available.")
        return false
    end
    if DynamicZ._DZChatCmds_SaveHooked then
        logInfo("SaveGlobalState hook already installed.")
        return true
    end

    local original = DynamicZ.SaveGlobalState
    DynamicZ.SaveGlobalState = function()
        original()
        writeBackup()
        -- Also persist pressure data so it survives graceful shutdown.
        -- Guard with isInstalled() to avoid overwriting a valid pressure file
        -- with empty data if the pressure system failed to install.
        if DZChatCommands_Pressure and DZChatCommands_Pressure.isInstalled
                and DZChatCommands_Pressure.isInstalled()
                and DZChatCommands_Pressure.writePressureFile then
            DZChatCommands_Pressure.writePressureFile()
        end
    end
    DynamicZ._DZChatCmds_SaveHooked = true
    logInfo("SaveGlobalState hook installed.")
    return true
end

-- Install pathfinding fix for search (fix 8) and stage 4 sense (fix 9).
--
-- Fix 8: DZ_Evolution.lua's applyPersistenceAndSearch calls setLastHeardSound
-- to make evolved zombies search the player's last known position after losing
-- sight. setLastHeardSound is dead code in PZ B42 (field written but never
-- read). This fix detects the target-loss condition and calls pathToLocationF
-- instead, actually causing the zombie to navigate to the last known position.
--
-- Fix 9: DZ_Evolution.lua's applyStage4Sense calls setLastHeardSound when a
-- stage 4+ zombie senses a nearby player (no line of sight required). The
-- zombie should investigate but never moves. CRITICAL: applyStage4Sense does
-- NOT store the sensed player's coordinates in modData (only calls dead
-- setLastHeardSound), so we must replicate findNearestPlayer to get the
-- player's position ourselves. Sense detection runs before the search fix
-- because current player position is a better signal than old last-known
-- position.
--
-- Both fixes wrap DynamicZ.ApplyStageEvolutionBuffs. On dedicated server,
-- PathFindBehavior2.pathToLocationF bypasses CanUsePathfindState (line 6950:
-- return !GameServer.server) and submits A* requests directly to PolygonalMap2.
local function installSearchFix()
    if not DynamicZ or not DynamicZ.ApplyStageEvolutionBuffs then
        logInfo("WARN installSearchFix: DynamicZ.ApplyStageEvolutionBuffs not available.")
        return false
    end
    if DynamicZ._DZChatCmds_SearchFixed then
        logInfo("Search fix already installed.")
        return true
    end

    local origApplyBuffs = DynamicZ.ApplyStageEvolutionBuffs

    DynamicZ.ApplyStageEvolutionBuffs = function(zombie, dz, targetPlayer)
        -- Let DZ do its processing first (memory, persistence, search, sense, etc.)
        origApplyBuffs(zombie, dz, targetPlayer)

        -- Post-processing: replace dead setLastHeardSound calls with pathToLocationF
        if not zombie or not dz then return end

        local stage = math.floor(toNumber(dz.evoStage, 0))
        if stage <= 0 then return end

        -- Resolve target (same logic as DZ's ApplyStageEvolutionBuffs)
        targetPlayer = targetPlayer
            or (DynamicZ.GetTargetPlayer and DynamicZ.GetTargetPlayer(zombie))

        if targetPlayer then
            -- Has target — store player ID for post-loss tracking, clear flags
            if targetPlayer.getOnlineID then
                local okID, id = pcall(function() return targetPlayer:getOnlineID() end)
                if okID then dz._lastTargetOnlineID = id end
            end
            if targetPlayer.username then
                dz._lastTargetUsername = targetPlayer.username
            end
            dz._searchPathSent = nil
            dz._sensePathHour = nil
            dz._trackPathHour = nil
            return
        end

        local nowH = getNowHours()

        -- Fix 9: Stage 4 sense — replaces dead setLastHeardSound in applyStage4Sense.
        -- applyStage4Sense runs for stage 4+ zombies with no current target.
        -- It finds nearest player within Stage4SenseRadius and calls dead
        -- setLastHeardSound. It does NOT store coordinates in modData, so we
        -- must replicate findNearestPlayer ourselves.
        -- Runs BEFORE search because it detects CURRENT player position (better
        -- than old last-known position from applyPersistenceAndSearch).
        if stage >= 4 then
            local sensePathHour = toNumber(dz._sensePathHour, 0)
            local senseCooldown = 3.0 / 3600.0  -- 3 seconds in hours
            if (nowH - sensePathHour) >= senseCooldown then
                local Config = DynamicZ_Config or {}
                local senseRadius = math.max(8.0, toNumber(Config.Stage4SenseRadius, 16.0))
                local nearestPlayer = findNearestPlayerInRadius(zombie, senseRadius * senseRadius)
                if nearestPlayer then
                    local px = math.floor(toNumber(nearestPlayer:getX(), 0))
                    local py = math.floor(toNumber(nearestPlayer:getY(), 0))
                    local pz = math.floor(toNumber(nearestPlayer:getZ(), 0))
                    if pathToLocation(zombie, px, py, pz) then
                        dz._sensePathHour = nowH
                        logInfo(string.format(
                            "Sense fix: zombie %d (stage %d) pathing toward sensed player (%.0f, %.0f, %.0f)",
                            zombie:getID(), stage, px, py, pz))
                    end
                    return  -- Sense found a player — skip search fallback
                end
            end
        end

        -- Fix 8: Repeating search after target loss — replaces dead
        -- setLastHeardSound in applyPersistenceAndSearch. Instead of one-shot
        -- path to a static position, repeatedly paths toward the player's
        -- CURRENT position (looked up by stored onlineID/username) every 3
        -- seconds for the duration of DZ's search window. Falls back to last
        -- known static position if the player disconnected or died.
        -- Tracking is STRICTLY TIME-LIMITED by computeSearchWindowHours(stage).

        -- Need last known position (set by DZ's applyPersistenceAndSearch)
        local lastX = toNumber(dz.lastTargetX, nil)
        local lastY = toNumber(dz.lastTargetY, nil)
        local lastZ = toNumber(dz.lastTargetZ, nil)
        if not lastX or not lastY or not lastZ then return end

        -- Check search window (replicate DZ's time check)
        local lastSeen = toNumber(dz.lastTargetSeenHours, -1)
        if lastSeen < 0 then return end

        local windowH = computeSearchWindowHours(stage)
        if (nowH - lastSeen) > windowH then
            -- Window expired: clear tracking state, revert to vanilla
            dz._trackPathHour = nil
            dz._searchPathSent = nil
            return
        end

        -- Guard: skip if zombie is part of a leader migration
        if dz.isMigrating == true then return end

        -- Guard: skip if zombie is under active leader influence.
        -- Mirrors TryAmbientWander's "SUPPRESSED_LEADER" check
        -- (DZ_Leader.lua lines 1128-1133). When the leader system is
        -- driving this follower, fix 11 handles pathing — running both
        -- would cause path stuttering (pathToLocationF overwrites goal
        -- and resets startedMoving on every call). DZ's author built
        -- this exclusion for wander but missed it for search (masked by
        -- dead setLastHeardSound having no observable conflict).
        local influenceUntil = toNumber(dz.leaderInfluenceUntil, 0)
        if dz.leaderInfluence == true and influenceUntil > nowH then return end

        -- Cooldown: don't re-path more often than every 3 seconds
        local trackCooldown = 3.0 / 3600.0  -- 3 seconds in hours
        local lastTrack = toNumber(dz._trackPathHour, 0)
        if (nowH - lastTrack) < trackCooldown then return end

        -- Try to look up the player's CURRENT position via stored ID
        local trackedPlayer = lookupLastTargetPlayer(dz)

        local pathX, pathY, pathZ
        if trackedPlayer then
            -- Player is still online and alive: path to CURRENT position
            pathX = math.floor(toNumber(trackedPlayer:getX(), 0))
            pathY = math.floor(toNumber(trackedPlayer:getY(), 0))
            pathZ = math.floor(toNumber(trackedPlayer:getZ(), 0))
        else
            -- Player disconnected or died: fall back to last known position
            pathX = lastX
            pathY = lastY
            pathZ = lastZ
        end

        if pathToLocation(zombie, pathX, pathY, pathZ) then
            dz._trackPathHour = nowH
            dz._searchPathSent = true
        end
    end

    DynamicZ._DZChatCmds_SearchFixed = true
    logInfo("Search fix installed: ApplyStageEvolutionBuffs wrapped (fixes 8+9).")
    return true
end

-- Install pathfinding fix for ambient wandering (fix 10).
--
-- DZ_Leader.lua's TryAmbientWander computes a target position for idle zombies
-- (influenced by nearby player presence, reactive kill signals, world evolution)
-- and calls dead setLastHeardSound. The zombie never actually moves toward the
-- target. After the dead setLastHeardSound call, DZ stores the target coords in
-- dz.ambientLastTargetX/Y/Z — we read these and call pathToLocationF.
--
-- TryAmbientWander is global on the DynamicZ table, so we can wrap it.
-- It already has extensive throttling (ambientNextEvalHour every ~2.5-4s,
-- ambientNextWanderHour every ~2-6min) and chance-based filtering, so our
-- pathToLocationF call only fires when DZ actually decided to move the zombie.
local function installWanderFix()
    if not DynamicZ or not DynamicZ.TryAmbientWander then
        logInfo("WARN installWanderFix: DynamicZ.TryAmbientWander not available.")
        return false
    end
    if DynamicZ._DZChatCmds_WanderFixed then
        logInfo("Wander fix already installed.")
        return true
    end

    local origTryAmbientWander = DynamicZ.TryAmbientWander

    DynamicZ.TryAmbientWander = function(zombie, dz)
        local result = origTryAmbientWander(zombie, dz)

        -- Only act when wander succeeded (returned true = DZ chose to move this zombie)
        if result ~= true then return result end
        if not zombie then return result end

        -- Resolve dz table (original may have created it via EnsureZombieData)
        dz = dz or (zombie.getModData and zombie:getModData() and zombie:getModData().DZ)
        if not dz then return result end

        -- Read wander target coords stored by original after setLastHeardSound
        local targetX = toNumber(dz.ambientLastTargetX, nil)
        local targetY = toNumber(dz.ambientLastTargetY, nil)
        local targetZ = toNumber(dz.ambientLastTargetZ, nil)
        if not targetX or not targetY then return result end
        if not targetZ then targetZ = 0 end

        if pathToLocation(zombie, targetX, targetY, targetZ) then
            logInfo(string.format(
                "Wander fix: zombie %d pathing to wander target (%.0f, %.0f, %.0f) mode=%s",
                zombie:getID(), targetX, targetY, targetZ,
                tostring(dz.ambientMode or "?")))
        end

        return result
    end

    DynamicZ._DZChatCmds_WanderFixed = true
    logInfo("Wander fix installed: TryAmbientWander wrapped with pathToLocationF.")
    return true
end

-- Install pathfinding fix for leader influence (fix 11).
--
-- DZ_Leader.lua's ApplyLeaderInfluence iterates followers within LeaderRadius
-- and calls applyFollowerBoost (local), which calls dead setLastHeardSound to
-- direct followers toward the leader's target, leader's own position, or
-- migration waypoints. It also calls applyMigrationDirective (local) which
-- uses dead setLastHeardSound for migrating zombies (blended or raw target).
-- None of these movement commands have any effect.
--
-- This fix wraps ApplyLeaderInfluence. After the original runs (which sets
-- follower modData: leaderInfluence, leaderAuraType, leaderInfluenceUntil,
-- migrationTargetX/Y/Z, etc.), we:
-- 1. Fix the leader's own migration path (if migrating)
-- 2. Iterate zombies in radius (replicating DZ's local forEachZombieInRadius
--    using cell:getGridSquare grid traversal) and call pathToLocationF on each
--    influenced follower with the appropriate coordinates:
--    - HUNTER/SHADOW/HIVE: leader's target position
--    - FRENZY: leader's target position, or leader's own position as fallback
--    - SPLIT: 3-way flanking offset from follower position hash, replicating
--      DZ's local computeSplitPoint logic (bucket = abs((fx + fy*3) % 3),
--      offset by Config.LeaderSplitFlankDistance in 3 directions)
--    - Migrating followers: blended migration target (replicating DZ's blend
--      formula from applyMigrationDirective)
-- Replicate DZ's getLeaderMigrationSettings (DZ_Leader.lua:1438).
-- Used by installLeaderFix for pressure-initiated migrations.
-- All referenced functions (GetMigrationSandboxSettings, IsMigrationEnabled)
-- are exposed on the DynamicZ table.
local function getLeaderMigrationSettings(dz)
    local Config = DynamicZ_Config or {}

    local sandbox
    if DynamicZ.GetMigrationSandboxSettings then
        sandbox = DynamicZ.GetMigrationSandboxSettings()
    else
        sandbox = {
            enabled = DynamicZ.IsMigrationEnabled and DynamicZ.IsMigrationEnabled() or false,
            radius = 2, percentage = 30, killThreshold = 5,
            killWindowHours = 24, cooldownHours = 12, durationHours = 8, intensity = 2,
        }
    end

    local intensity = math.floor(clamp(toNumber(sandbox.intensity, 2), 1, 3))
    local profile
    if intensity <= 1 then
        profile = { checkIntervalMult = 1.25, percentageMult = 0.85, minScoreBias = 1.0, cooldownMult = 1.15 }
    elseif intensity >= 3 then
        profile = { checkIntervalMult = 0.75, percentageMult = 1.15, minScoreBias = -1.0, cooldownMult = 0.85 }
    else
        profile = { checkIntervalMult = 1.0, percentageMult = 1.0, minScoreBias = 0.0, cooldownMult = 1.0 }
    end

    local leaderStage = math.max(0, math.floor(toNumber(dz and dz.leaderStage, 0)))
    local basePercentage = clamp(toNumber(sandbox.percentage, 30), 10, 40)
    local stagePercentBonus = clamp(toNumber(Config.MigrationLeaderStagePercentBonus, 5), 0, 10)

    local baseCooldown = clamp(toNumber(sandbox.cooldownHours, 12), 6, 24)
    local cooldownReduction = clamp(toNumber(Config.MigrationLeaderStageCooldownReductionHours, 0.5), 0, 1)

    return {
        enabled = sandbox.enabled == true,
        percentage = clamp((basePercentage + (leaderStage * stagePercentBonus)) * profile.percentageMult, 10, 40),
        cooldownHours = math.max(toNumber(Config.MigrationMinCooldownHours, 4.0),
            (baseCooldown - (leaderStage * cooldownReduction)) * profile.cooldownMult),
        durationHours = clamp(toNumber(sandbox.durationHours, 8), 4, 12),
        checkIntervalHours = math.max(0.5, toNumber(Config.MigrationCheckIntervalHours, 6.0) * profile.checkIntervalMult),
        minimumScore = toNumber(Config.MigrationMinimumScore, 3.0) + profile.minScoreBias,
        minWorldEvolution = clamp(toNumber(Config.MigrationMinWorldEvolution, 0.35), 0.0, 1.0),
        minFollowers = math.max(1, math.floor(toNumber(Config.MigrationMinFollowers, 6))),
    }
end

local function installLeaderFix()
    if not DynamicZ or not DynamicZ.ApplyLeaderInfluence then
        logInfo("WARN installLeaderFix: DynamicZ.ApplyLeaderInfluence not available.")
        return false
    end
    if DynamicZ._DZChatCmds_LeaderFixed then
        logInfo("Leader fix already installed.")
        return true
    end

    local origApplyLeaderInfluence = DynamicZ.ApplyLeaderInfluence

    DynamicZ.ApplyLeaderInfluence = function(leader, dz, pulseIdOverride)
        -- Let DZ do its processing first
        origApplyLeaderInfluence(leader, dz, pulseIdOverride)

        if not leader or not dz or dz.isLeader ~= true then return end

        local Config = DynamicZ_Config or {}
        local nowH = getNowHours()
        local Pressure = DZChatCommands_Pressure

        -- Resolve leader's target
        local leaderTarget = nil
        if leader.getTarget then
            local ok, val = pcall(function() return leader:getTarget() end)
            if ok then leaderTarget = val end
        end

        -- Leader positions
        local leaderX = toNumber(leader:getX(), nil)
        local leaderY = toNumber(leader:getY(), nil)
        local leaderZ = math.floor(toNumber(leader:getZ(), 0))

        -- Leader's target position
        local targetX, targetY, targetZ
        if leaderTarget then
            targetX = toNumber(leaderTarget:getX(), nil)
            targetY = toNumber(leaderTarget:getY(), nil)
            targetZ = math.floor(toNumber(leaderTarget:getZ(), 0))
        end

        -- Fix leader's own migration path.
        -- applyMigrationDirective is called via tryUpdateLeaderMigration inside
        -- the original. It sets dz.migrationLastDirectiveHour when it fires.
        -- We check if the directive just fired (within ~1 second of now) to
        -- sync with the original's throttle interval.
        if dz.isMigrating == true then
            local lastDirH = toNumber(dz.migrationLastDirectiveHour, -1)
            if lastDirH >= 0 and math.abs(nowH - lastDirH) < (1.0 / 3600.0) then
                local mtx = toNumber(dz.migrationTargetX, nil)
                local mty = toNumber(dz.migrationTargetY, nil)
                local mtz = math.floor(toNumber(dz.migrationTargetZ, leaderZ))
                if mtx and mty then
                    -- Pressure Case A: redirect to higher-pressure chunk if available
                    if Pressure and Pressure.isInstalled and Pressure.isInstalled()
                       and Pressure.findBestPressureTarget and Pressure.getMigrationScoreAtPos then
                        local curScore = Pressure.getMigrationScoreAtPos(mtx, mty)
                        local better = Pressure.findBestPressureTarget(leader, curScore)
                        if better then
                            mtx = better.x
                            mty = better.y
                            mtz = better.z
                            dz.migrationTargetX = mtx
                            dz.migrationTargetY = mty
                            dz.migrationTargetZ = mtz
                            dz.migrationTargetChunkKey = better.key
                        end
                    end

                    -- Replicate blend logic from applyMigrationDirective
                    local blendW = clamp(toNumber(Config.MigrationDirectionBlendWeight, 0.40), 0.0, 1.0)
                    local pathX, pathY = mtx, mty
                    if blendW > 0 then
                        local vx, vy = leaderX, leaderY
                        if leaderTarget and targetX and targetY then
                            vx, vy = targetX, targetY
                        end
                        if vx and vy then
                            pathX = vx + ((mtx - vx) * blendW)
                            pathY = vy + ((mty - vy) * blendW)
                        end
                    end
                    pathToLocation(leader, pathX, pathY, mtz)
                end
            end

        end

        -- Pressure Case B setup: if DZ did not start a migration, check whether
        -- a pressure-driven migration should be initiated. Follower collection is
        -- piggybacked onto the follower-path traversal below (single grid walk).
        local pressureFollowers, pTarget, pSettings
        if dz.isMigrating ~= true
           and Pressure and Pressure.isInstalled and Pressure.isInstalled()
           and Pressure.findBestPressureTarget then
            local settings = getLeaderMigrationSettings(dz)
            if settings.enabled == true then
                local worldEvo = toNumber(DynamicZ.Global and DynamicZ.Global.worldEvolution, 0.0)
                if worldEvo >= settings.minWorldEvolution
                   and math.max(0, math.floor(toNumber(dz.leaderStage, 0))) >= 1
                   and math.max(0, math.floor(toNumber(dz.lastFollowerCount, 0))) >= settings.minFollowers
                   and toNumber(dz.migrationCooldownUntil, 0.0) <= nowH then
                    local nextCheck = toNumber(dz._pressureMigCheckHour, 0.0)
                    if nextCheck <= nowH then
                        dz._pressureMigCheckHour = nowH + settings.checkIntervalHours
                        local pt = Pressure.findBestPressureTarget(leader, settings.minimumScore)
                        if pt then
                            pTarget = pt
                            pSettings = settings
                            pressureFollowers = {}
                        end
                    end
                end
            end
        end

        -- Fix follower paths: iterate zombies in radius and path influenced ones.
        -- Replicates DZ's local forEachZombieInRadius grid traversal.
        local radius = math.floor(toNumber(Config.LeaderRadius, 12))
        if not leaderX or not leaderY then return end

        local cell = getCell and getCell()
        if not cell then return end

        local cx = math.floor(leaderX)
        local cy = math.floor(leaderY)
        local radiusSq = radius * radius

        for gx = cx - radius, cx + radius do
            for gy = cy - radius, cy + radius do
                local dx = gx - cx
                local dy = gy - cy
                if (dx * dx + dy * dy) <= radiusSq then
                    local ok, sq = pcall(function() return cell:getGridSquare(gx, gy, leaderZ) end)
                    if ok and sq then
                        local ok2, movObjs = pcall(function() return sq:getMovingObjects() end)
                        if ok2 and movObjs then
                            for i = 0, movObjs:size() - 1 do
                                local obj = movObjs:get(i)
                                if obj and obj ~= leader and instanceof and instanceof(obj, "IsoZombie") then
                                    -- Piggyback: collect non-leader zombies for pressure migration (Case B)
                                    if pressureFollowers then
                                        if not DynamicZ.CanProcessZombie or DynamicZ.CanProcessZombie(obj) then
                                            local pDZ = DynamicZ.EnsureZombieData and DynamicZ.EnsureZombieData(obj)
                                            if pDZ and pDZ.isLeader ~= true then
                                                local fdx = toNumber(obj:getX(), 0) - cx
                                                local fdy = toNumber(obj:getY(), 0) - cy
                                                pressureFollowers[#pressureFollowers + 1] = { zombie = obj, dz = pDZ, distSq = fdx*fdx + fdy*fdy }
                                            end
                                        end
                                    end

                                    local fMD = obj.getModData and obj:getModData()
                                    local fDZ = fMD and fMD.DZ
                                    if fDZ and fDZ.leaderInfluence == true
                                       and toNumber(fDZ.leaderInfluenceUntil, 0) > nowH then
                                        local px, py, pz

                                        if fDZ.isMigrating == true then
                                            -- Migrating follower: path to migration target
                                            -- Replicate blend from applyMigrationDirective
                                            px = toNumber(fDZ.migrationTargetX, nil)
                                            py = toNumber(fDZ.migrationTargetY, nil)
                                            pz = math.floor(toNumber(fDZ.migrationTargetZ, leaderZ))
                                            if px and py then
                                                local bw = clamp(toNumber(Config.MigrationDirectionBlendWeight, 0.40), 0.0, 1.0)
                                                if bw > 0 then
                                                    local vx = toNumber(obj:getX(), nil)
                                                    local vy = toNumber(obj:getY(), nil)
                                                    if obj.getTarget then
                                                        local ok3, ct = pcall(function() return obj:getTarget() end)
                                                        if ok3 and ct then
                                                            vx = toNumber(ct:getX(), vx)
                                                            vy = toNumber(ct:getY(), vy)
                                                        end
                                                    end
                                                    if vx and vy then
                                                        px = vx + ((px - vx) * bw)
                                                        py = vy + ((py - vy) * bw)
                                                    end
                                                end
                                            end
                                        else
                                            -- Non-migrating follower: coords by leader type
                                            local fType = tostring(fDZ.leaderAuraType or "HIVE")
                                            if fType == "SPLIT" and targetX and targetY then
                                                -- Replicate DZ's local computeSplitPoint:
                                                -- 3-way flanking based on follower position hash.
                                                -- bucket = abs((fx + fy*3) % 3)
                                                -- 0: flank right, 1: flank diag back-left, 2: flank backward
                                                local dist = toNumber(Config.LeaderSplitFlankDistance, 5.0)
                                                local fx = math.floor(toNumber(obj:getX(), 0))
                                                local fy = math.floor(toNumber(obj:getY(), 0))
                                                local bucket = math.abs((fx + (fy * 3)) % 3)
                                                if bucket == 0 then
                                                    px, py, pz = targetX + dist, targetY, targetZ
                                                elseif bucket == 1 then
                                                    px, py, pz = targetX - dist, targetY + dist, targetZ
                                                else
                                                    px, py, pz = targetX, targetY - dist, targetZ
                                                end
                                            elseif fType == "FRENZY" or fType == "SHADOW" then
                                                -- FRENZY/SHADOW fall back to leader pos if no target
                                                px = targetX or leaderX
                                                py = targetY or leaderY
                                                pz = targetZ or leaderZ
                                            else
                                                -- HUNTER, HIVE: leader's target position only
                                                if targetX and targetY then
                                                    px, py, pz = targetX, targetY, targetZ
                                                end
                                            end
                                        end

                                        if px and py then
                                            pathToLocation(obj, px, py, pz or leaderZ)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Pressure Case B: assign migration ModData if enough followers collected
        if pressureFollowers and pTarget and pSettings
           and #pressureFollowers >= pSettings.minFollowers then
            table.sort(pressureFollowers, function(a, b) return toNumber(a.distSq, 0) > toNumber(b.distSq, 0) end)
            local migrateCount = math.max(1, math.floor(#pressureFollowers * (pSettings.percentage / 100.0)))
            migrateCount = math.min(migrateCount, #pressureFollowers)
            local leaderId = DynamicZ.GetZombieDebugId and tostring(DynamicZ.GetZombieDebugId(leader)) or "unknown"
            local migEndTime = nowH + pSettings.durationHours

            dz.isMigrating = true
            dz.migrationRole = "leader"
            dz.migrationLeaderId = leaderId
            dz.migrationTargetX = pTarget.x
            dz.migrationTargetY = pTarget.y
            dz.migrationTargetZ = pTarget.z
            dz.migrationTargetChunkKey = pTarget.key
            dz.migrationEndTime = migEndTime
            dz.migrationStartFollowers = #pressureFollowers
            dz.migrationAssignedCount = migrateCount
            dz.migrationStartHour = nowH
            dz.migrationLastFollowerCount = #pressureFollowers
            dz.migrationLastDirectiveHour = nil

            for mi = 1, migrateCount do
                local sel = pressureFollowers[mi]
                if sel and sel.dz then
                    sel.dz.isMigrating = true
                    sel.dz.migrationRole = "follower"
                    sel.dz.migrationLeaderId = leaderId
                    sel.dz.migrationTargetX = pTarget.x
                    sel.dz.migrationTargetY = pTarget.y
                    sel.dz.migrationTargetZ = pTarget.z
                    sel.dz.migrationTargetChunkKey = pTarget.key
                    sel.dz.migrationEndTime = migEndTime
                    sel.dz.migrationLastDirectiveHour = nil
                end
            end

            logInfo(string.format(
                "Pressure migration started: target=%s score=%.2f pressure=%.3f followers=%d/%d",
                tostring(pTarget.key), toNumber(pTarget.score, 0),
                toNumber(pTarget.pressure, 0), migrateCount, #pressureFollowers))
        end
    end

    DynamicZ._DZChatCmds_LeaderFixed = true
    logInfo("Leader fix installed: ApplyLeaderInfluence wrapped with pathToLocationF for followers.")
    return true
end

-- Replace DynamicZ.RecalculateWorldEvolution with a version that uses
-- our corrected getWorldAgeDays() (includes timeSinceApo offset).
-- DZ's original uses the local getWorldAgeDaysSafe() whose fallback path
-- (getWorldAgeHours()/24) misses the timeSinceApo sandbox offset.
-- Since getWorldAgeDaysSafe is local, we can't patch it directly.
-- Instead we replace the entire RecalculateWorldEvolution function.
-- This also means every zombie kill (DZ_Core.lua:255) now uses the
-- correct world age instead of potentially falling back to the wrong one.
local function installRecalcFix()
    if not DynamicZ or not DynamicZ.RecalculateWorldEvolution then
        logInfo("WARN installRecalcFix: DynamicZ.RecalculateWorldEvolution not available.")
        return false
    end
    if DynamicZ._DZChatCmds_RecalcFixed then
        logInfo("RecalculateWorldEvolution fix already installed.")
        return true
    end

    DynamicZ.RecalculateWorldEvolution = function()
        if DynamicZ.IsEvolutionEnabled and not DynamicZ.IsEvolutionEnabled() then
            return
        end

        local Config = DynamicZ_Config or {}
        local days = getWorldAgeDays()
        local timeFactor = toNumber(Config.TimeFactor, 0.005)
        local killFactor = toNumber(Config.KillFactor, 0.0005)
        local maxWorldEvolution = toNumber(Config.MaxWorldEvolution, 1.0)
        local totalKills = toNumber(DynamicZ.Global.totalKills, 0)

        local evolution = (days * timeFactor) + (totalKills * killFactor)
        DynamicZ.Global.worldEvolution = clamp(evolution, 0.0, maxWorldEvolution)

        DynamicZ.SaveGlobalState()
    end

    DynamicZ._DZChatCmds_RecalcFixed = true
    logInfo("RecalculateWorldEvolution fix installed: uses corrected getWorldAgeDays with timeSinceApo.")
    return true
end

-- Replace DynamicZ.AdvanceLeaderTick with a version that uses a fallback
-- pulse interval of 3 instead of 180 (fix 13).
--
-- DZ_Leader.lua's AdvanceLeaderTick increments updateTick each call and
-- fires a leader pulse when (updateTick % interval == 0). The interval
-- comes from Config.LeaderPulseInterval with a hardcoded fallback of 180.
-- Since LeaderPulseInterval is not in DZ's default sandbox config, the
-- fallback always applies: a pulse fires every 180 ticks. Our companion
-- mod calls AdvanceLeaderTick once per real second (OnTick at 10 FPS,
-- ticks%10==0), so 180 ticks = 180 seconds = 3 minutes between pulses.
-- Leaders only act (TryLeaderPulse) when a pulse fires, making the
-- leader system extremely sluggish.
-- With fallback=3, pulses fire every 3 seconds, making leaders responsive.
local function installTickFix()
    if not DynamicZ then
        logInfo("WARN installTickFix: DynamicZ table not available.")
        return false
    end
    if DynamicZ._DZChatCmds_TickFixed then
        logInfo("AdvanceLeaderTick fix already installed.")
        return true
    end

    DynamicZ.AdvanceLeaderTick = function()
        local runtime = DynamicZ.Runtime
        runtime.updateTick = toNumber(runtime.updateTick, 0) + 1

        local interval = toNumber((DynamicZ_Config or {}).LeaderPulseInterval, 3)
        if interval < 1 then
            interval = 1
        end

        if runtime.updateTick % interval == 0 then
            runtime.pulseId = toNumber(runtime.pulseId, 0) + 1
        end
    end

    DynamicZ._DZChatCmds_TickFixed = true
    logInfo("AdvanceLeaderTick fix installed: fallback pulse interval 180 -> 3.")
    return true
end

-- Set DynamicZ.GetZombieDebugId to a function that returns a stable
-- identifier for debug logging (fix 14).
--
-- DZ_Leader.lua's local getZombieDebugId checks DynamicZ.GetZombieDebugId
-- first (line 44), then falls back to a position-based string "P:x:y:z".
-- By default GetZombieDebugId is nil, so every zombie is identified by
-- position, which is ambiguous when multiple zombies share a tile.
--
-- This fix provides a proper implementation:
-- 1. getOnlineID() — multiplayer network ID (works in MP, returns "O<id>")
-- 2. getID() — IsoMovingObject.id monotonic counter (works in SP,
--    returns "R<id>" for "Runtime")
-- 3. Position fallback "P:x:y:z" as last resort
--
-- Note: getZombieRuntimeId (local in DZ_Leader.lua, line 159) also tries
-- getOnlineID then getObjectID (which does NOT exist on IsoZombie) then
-- falls back to getZombieDebugId. By providing GetZombieDebugId with
-- getID(), we give getZombieRuntimeId a valid fallback instead of position.
local function installDebugIdFix()
    if not DynamicZ then
        logInfo("WARN installDebugIdFix: DynamicZ table not available.")
        return false
    end
    if DynamicZ._DZChatCmds_DebugIdFixed then
        logInfo("GetZombieDebugId fix already installed.")
        return true
    end

    DynamicZ.GetZombieDebugId = function(zombie)
        if not zombie then
            return "unknown"
        end

        -- Try getOnlineID first (multiplayer network ID)
        if zombie.getOnlineID then
            local ok, value = pcall(function() return zombie:getOnlineID() end)
            if ok then
                local n = tonumber(value)
                if n ~= nil and n >= 0 then
                    return "O" .. tostring(math.floor(n))
                end
            end
        end

        -- Try getID (IsoMovingObject.id — monotonic counter, works in SP+MP)
        if zombie.getID then
            local ok, value = pcall(function() return zombie:getID() end)
            if ok then
                local n = tonumber(value)
                if n ~= nil and n >= 0 then
                    return "R" .. tostring(math.floor(n))
                end
            end
        end

        -- Position fallback
        local x = zombie.getX and math.floor(tonumber(zombie:getX()) or 0) or 0
        local y = zombie.getY and math.floor(tonumber(zombie:getY()) or 0) or 0
        local z = zombie.getZ and math.floor(tonumber(zombie:getZ()) or 0) or 0
        return string.format("P:%d:%d:%d", x, y, z)
    end

    DynamicZ._DZChatCmds_DebugIdFixed = true
    logInfo("GetZombieDebugId fix installed: uses getOnlineID -> getID -> position fallback.")
    return true
end

-- Core fixup: restore from backup if ModData was empty,
-- then compute correct worldEvolution using actual world age.
local function onGameStartFixup()
    logInfo("onGameStartFixup: starting...")

    if not DynamicZ then
        logInfo("WARN: DynamicZ table not available at fixup time.")
        return false
    end
    if not DynamicZ.Global then
        logInfo("WARN: DynamicZ.Global not available at fixup time.")
        return false
    end

    local g = DynamicZ.Global
    local loadedKills = math.floor(toNumber(g.totalKills, 0))
    local loadedEvo = toNumber(g.worldEvolution, 0.0)

    logInfo(string.format("Post-load state: totalKills=%d worldEvolution=%.4f",
        loadedKills, loadedEvo))

    -- Log sandbox evolution setting
    local evoEnabled = "unknown"
    if DynamicZ.IsEvolutionEnabled then
        evoEnabled = tostring(DynamicZ.IsEvolutionEnabled())
    else
        evoEnabled = "function not found"
    end
    logInfo("IsEvolutionEnabled = " .. evoEnabled)

    -- Log world age (using our corrected method)
    local days = getWorldAgeDays()
    logInfo(string.format("World age (corrected): %.1f days", days))

    -- Sync totalKills from vanilla kill counters (the source of truth).
    -- This handles both fresh starts and restarts where ModData was lost.
    syncVanillaKills()
    logInfo(string.format("After vanilla sync: totalKills=%d", math.floor(toNumber(g.totalKills, 0))))

    -- DZ's RecalculateWorldEvolution has a bug: it calls
    -- gameTime:getWorldAgeDays() which doesn't exist on GameTime
    -- (it's on IsoWorld). So it always computes days=0.
    -- We ALWAYS compute worldEvolution ourselves using the correct method.
    local computedEvo = computeWorldEvolution(g.totalKills)
    if computedEvo > loadedEvo then
        g.worldEvolution = computedEvo
        logInfo(string.format("Set worldEvolution=%.4f (was %.4f)", computedEvo, loadedEvo))
    else
        logInfo(string.format("Keeping worldEvolution=%.4f (computed=%.4f)",
            loadedEvo, computedEvo))
    end

    -- Save: write to both ModData and our backup file.
    -- Call SaveGlobalState if available (syncs ModData + transmit).
    if DynamicZ.SaveGlobalState then
        logInfo("Calling SaveGlobalState...")
        DynamicZ.SaveGlobalState()
    end
    -- Always write backup directly too (SaveGlobalState hook may not be installed yet)
    if not DynamicZ._DZChatCmds_SaveHooked then
        logInfo("Hook not installed, writing backup directly...")
        writeBackup()
    end

    logInfo(string.format(
        "Post-fixup state: totalKills=%d worldEvolution=%.4f",
        math.floor(toNumber(g.totalKills, 0)),
        toNumber(g.worldEvolution, 0.0)
    ))
    logInfo("onGameStartFixup: complete.")
    return true
end

-- Override DZ's broken SyncVanillaKillCounter with our vanilla-truth version.
-- DZ's original uses a single global baseline that resets on restart
-- (vanillaKillBaseline=0 when no players at OnGameStart) and inflates
-- totalKills when players reconnect. Our version uses each player's
-- getZombieKills() as the persistent source of truth.
local function installKillSyncFix()
    if not DynamicZ then return false end

    -- Load last-known kills from previous session (includes offline players)
    local saved = readPlayerKills()
    local count = 0
    for username, kills in pairs(saved) do
        playerKills[username] = kills
        count = count + 1
    end
    if count > 0 then
        logInfo(string.format("Loaded %d player kill records from file.", count))
    end

    DynamicZ.SyncVanillaKillCounter = syncVanillaKills
    DynamicZ._DZChatCmds_KillSyncFixed = true
    logInfo("SyncVanillaKillCounter replaced with vanilla-truth version.")
    return true
end

-- Enable debug UI for admin players without requiring the sandbox debug setting.
-- Sets DynamicZ.DebugEnabled = true on the server, which:
-- 1. Makes IsDebugEnabled() return true (DZ_Debug.lua:88)
-- 2. Unblocks canUseDebug() for admin players (admin check still enforced
--    by hasDebugPrivileges inside canUseDebug, line 170)
-- 3. Enables DebugTrackTick and DebugHeartbeat server-side
-- 4. Server's buildStatePayload sends debugEnabled=true to clients (line 197),
--    which makes client's isClientDebugEnabled() return true (line 60-61),
--    enabling HUD overlay, inspect window, and context menu for admin players
--    (canUseDebugUI still requires admin check for MP clients, line 117-118)
local function installAdminDebugAccess()
    if not DynamicZ then
        logInfo("WARN installAdminDebugAccess: DynamicZ table not available.")
        return false
    end
    if DynamicZ.DebugEnabled == true then
        logInfo("Debug already enabled.")
        return true
    end

    DynamicZ.DebugEnabled = true
    logInfo("Debug UI enabled for admin players (sandbox setting bypassed).")
    return true
end

-- Install all behavior fixes (search, sense, wander, leader, recalc, tick, debugId, killSync).
-- Called from multiple init paths (OnGameStart, EveryOneMinute, ensureFixup).
local function installAllFixes()
    installSaveHook()
    installKillSyncFix()
    installSearchFix()
    installWanderFix()
    installLeaderFix()
    installRecalcFix()
    installTickFix()
    installDebugIdFix()
    installAdminDebugAccess()
    -- Activity pressure system: installs evo + seed hooks. Migration is handled by installLeaderFix above.
    if DZChatCommands_Pressure and DZChatCommands_Pressure.install then
        DZChatCommands_Pressure.install()
    end
end

-- Lazy-init: run fixup on first client command if events never fired
local function ensureFixup()
    if fixupComplete then return end
    if not DynamicZ or not DynamicZ.Global then return end
    logInfo("Lazy-init: running fixup from first client command.")
    installAllFixes()
    syncVanillaKills()
    if onGameStartFixup() then
        fixupComplete = true
    end
end

-- Network command handler for ForceSave and Diagnostics from chat bridge
local function onClientCommand(module, command, player, args)
    if module ~= NET_MODULE then return end
    ensureFixup()

    if command == "ForceSave" then
        logInfo("ForceSave command received.")

        if not player then
            logInfo("WARN ForceSave: player is nil.")
            return
        end

        -- Log player info
        local playerName = "unknown"
        if player.getUsername then
            playerName = tostring(player:getUsername())
        end
        local accessLevel = "unknown"
        if player.getAccessLevel then
            accessLevel = tostring(player:getAccessLevel() or "")
        end
        logInfo(string.format("ForceSave from player=%s accessLevel=[%s]",
            playerName, accessLevel))

        -- Check admin - accept admin, moderator, overseer, gm
        local isAdmin = false
        if player.getAccessLevel then
            local access = string.lower(tostring(player:getAccessLevel() or ""))
            isAdmin = (access == "admin") or (access == "moderator")
                   or (access == "overseer") or (access == "gm")
        end

        if not isAdmin then
            logInfo("ForceSave denied: insufficient access (accessLevel=[" .. accessLevel .. "])")
            if sendServerCommand then
                pcall(function()
                    sendServerCommand(player, "DynamicZ", "DebugInfo",
                        { message = "ForceSave denied: access level [" .. accessLevel .. "] is not admin." })
                end)
            end
            return
        end

        logInfo("ForceSave: admin check passed, saving...")

        -- Call SaveGlobalState if available (syncs ModData)
        if DynamicZ and DynamicZ.SaveGlobalState then
            DynamicZ.SaveGlobalState()
            logInfo("ForceSave: SaveGlobalState called.")
        end

        -- ALWAYS write backup directly — don't depend on hook being installed
        local wrote = writeBackup()
        if not wrote then
            logInfo("ForceSave: writeBackup returned false.")
        end

        -- Also persist pressure data
        if DZChatCommands_Pressure and DZChatCommands_Pressure.writePressureFile then
            DZChatCommands_Pressure.writePressureFile()
        end

        -- Send confirmation back
        if sendServerCommand then
            local g = DynamicZ and DynamicZ.Global or {}
            local message = string.format(
                "Force-saved: totalKills=%d worldEvolution=%.4f backup=%s",
                math.floor(toNumber(g.totalKills, 0)),
                toNumber(g.worldEvolution, 0.0),
                tostring(wrote)
            )
            logInfo("ForceSave response: " .. message)
            pcall(function()
                sendServerCommand(player, "DynamicZ", "DebugInfo", { message = message })
            end)
        else
            logInfo("WARN ForceSave: sendServerCommand not available.")
        end

    elseif command == "Pressure" then
        logInfo("Pressure command received.")
        if not player then return end
        local isAdmin = false
        if player.getAccessLevel then
            local access = string.lower(tostring(player:getAccessLevel() or ""))
            isAdmin = (access == "admin") or (access == "moderator")
                   or (access == "overseer") or (access == "gm")
        end
        if not isAdmin then
            if sendServerCommand then
                pcall(function()
                    sendServerCommand(player, "DynamicZ", "DebugInfo",
                        { message = "Pressure denied: insufficient access." })
                end)
            end
            return
        end
        if DZChatCommands_Pressure and DZChatCommands_Pressure.handleCommand then
            DZChatCommands_Pressure.handleCommand(player)
        else
            if sendServerCommand then
                pcall(function()
                    sendServerCommand(player, "DynamicZ", "DebugInfo",
                        { message = "Pressure system not loaded." })
                end)
            end
        end

    elseif command == "Diagnostics" then
        logInfo("Diagnostics command received.")
        if not player then return end

        local lines = {}
        lines[#lines + 1] = "=== DZChatCommands Server Diagnostics ==="
        lines[#lines + 1] = string.format("fixupComplete: %s", tostring(fixupComplete))
        lines[#lines + 1] = string.format("SaveHooked: %s",
            tostring(DynamicZ and DynamicZ._DZChatCmds_SaveHooked or false))
        lines[#lines + 1] = string.format("SearchFixed: %s",
            tostring(DynamicZ and DynamicZ._DZChatCmds_SearchFixed or false))
        lines[#lines + 1] = string.format("WanderFixed: %s",
            tostring(DynamicZ and DynamicZ._DZChatCmds_WanderFixed or false))
        lines[#lines + 1] = string.format("LeaderFixed: %s",
            tostring(DynamicZ and DynamicZ._DZChatCmds_LeaderFixed or false))
        lines[#lines + 1] = string.format("RecalcFixed: %s",
            tostring(DynamicZ and DynamicZ._DZChatCmds_RecalcFixed or false))
        lines[#lines + 1] = string.format("TickFixed: %s",
            tostring(DynamicZ and DynamicZ._DZChatCmds_TickFixed or false))
        lines[#lines + 1] = string.format("DebugIdFixed: %s",
            tostring(DynamicZ and DynamicZ._DZChatCmds_DebugIdFixed or false))
        lines[#lines + 1] = string.format("KillSyncFixed: %s",
            tostring(DynamicZ and DynamicZ._DZChatCmds_KillSyncFixed or false))
        lines[#lines + 1] = string.format("DynamicZ loaded: %s",
            tostring(DynamicZ ~= nil))
        lines[#lines + 1] = string.format("Global available: %s",
            tostring(DynamicZ and DynamicZ.Global ~= nil))

        if DynamicZ and DynamicZ.Global then
            local g = DynamicZ.Global
            lines[#lines + 1] = string.format("totalKills: %d",
                math.floor(toNumber(g.totalKills, 0)))
            lines[#lines + 1] = string.format("worldEvolution: %.4f",
                toNumber(g.worldEvolution, 0.0))
            lines[#lines + 1] = string.format("activeLeaders: %d",
                math.floor(toNumber(g.activeLeaders, 0)))
        end

        local evoEnabled = "unknown"
        if DynamicZ and DynamicZ.IsEvolutionEnabled then
            evoEnabled = tostring(DynamicZ.IsEvolutionEnabled())
        end
        lines[#lines + 1] = "IsEvolutionEnabled: " .. evoEnabled

        local days = getWorldAgeDays()
        lines[#lines + 1] = string.format("World age (corrected): %.1f days", days)

        -- Also log which method we used
        local method = "none"
        if getGameTime then
            local gt = getGameTime()
            if gt then
                if gt.getWorldAgeDaysSinceBegin then
                    method = "getWorldAgeDaysSinceBegin"
                elseif gt.getWorldAgeHours then
                    method = "getWorldAgeHours/24"
                elseif gt.getNightsSurvived then
                    method = "getNightsSurvived"
                end
            end
        end
        if method == "none" and getWorld then
            local w = getWorld()
            if w and w.getWorldAgeDays then
                method = "getWorld():getWorldAgeDays"
            end
        end
        lines[#lines + 1] = "World age method: " .. method

        local computedEvo = computeWorldEvolution(
            DynamicZ and DynamicZ.Global and DynamicZ.Global.totalKills or 0)
        lines[#lines + 1] = string.format("Computed evo (formula): %.4f", computedEvo)

        -- Check backup file
        local backup = readBackup()
        if backup then
            lines[#lines + 1] = string.format("Backup file: kills=%d evo=%.4f",
                toNumber(backup.totalKills, 0), toNumber(backup.worldEvolution, 0))
        else
            lines[#lines + 1] = "Backup file: not found"
        end

        -- Activity pressure
        if DZChatCommands_Pressure and DZChatCommands_Pressure.isInstalled and DZChatCommands_Pressure.isInstalled() then
            lines[#lines + 1] = string.format("Pressure: max=%.3f avg=%.3f chunks=%d",
                DZChatCommands_Pressure.getMaxPressure(),
                DZChatCommands_Pressure.getAveragePressure(),
                DZChatCommands_Pressure.getPressuredChunkCount())
        else
            lines[#lines + 1] = "Pressure: not installed"
        end

        -- Per-player kill tracking
        local playerCount = 0
        local vanillaSum = 0
        for _, kills in pairs(playerKills) do
            playerCount = playerCount + 1
            vanillaSum = vanillaSum + math.floor(kills)
        end
        lines[#lines + 1] = string.format("Player kills tracked: %d players, vanilla sum=%d", playerCount, vanillaSum)
        for username, kills in pairs(playerKills) do
            lines[#lines + 1] = string.format("  %s: kills=%d", username, math.floor(kills))
        end

        -- Player access level
        local accessLevel = "unknown"
        if player.getAccessLevel then
            accessLevel = tostring(player:getAccessLevel() or "")
        end
        lines[#lines + 1] = "Your access level: [" .. accessLevel .. "]"

        if sendServerCommand then
            for _, line in ipairs(lines) do
                pcall(function()
                    sendServerCommand(player, "DynamicZ", "DebugInfo", { message = line })
                end)
            end
        end
    end
end

-- Register events
local function registerEvent(eventName, handler)
    if not Events then
        logInfo("WARN registerEvent: Events table not available for " .. eventName)
        return false
    end
    local eventObj = Events[eventName]
    if eventObj and eventObj.Add then
        eventObj.Add(handler)
        logInfo("Registered event: " .. eventName)
        return true
    else
        logInfo("WARN registerEvent: Event " .. eventName .. " not found or no Add method.")
        return false
    end
end

if not DynamicZ_ChatCmds_ServerLoaded then
    -- Primary: try OnGameStart (fires after world load)
    registerEvent("OnGameStart", function()
        logInfo("OnGameStart event fired.")
        installAllFixes()
        if onGameStartFixup() then
            fixupComplete = true
        end
    end)

    -- Fallback: EveryOneMinute checks if fixup was missed + slow-cadence periodic tasks.
    registerEvent("EveryOneMinute", function()
        if not DynamicZ or not DynamicZ.Global then return end

        if not fixupComplete then
            if DynamicZ.Global.totalKills == nil then return end
            logInfo("EveryOneMinute fallback: OnGameStart may not have fired, running fixup now.")
            installAllFixes()
            syncVanillaKills()
            if onGameStartFixup() then
                fixupComplete = true
            end
            return
        end

        -- Per-player kill sync: catches kills the event path may have missed
        -- (e.g., vehicle kills). Once per minute is sufficient.
        syncVanillaKills()
        if DynamicZ.TryAutoSeedLeaders then
            DynamicZ.TryAutoSeedLeaders()
        end
        if DynamicZ.RecountActiveLeaders then
            DynamicZ.RecountActiveLeaders(false)
        end
        -- Activity pressure tick: accumulate/decay per-chunk pressure
        if DZChatCommands_Pressure and DZChatCommands_Pressure.tick then
            DZChatCommands_Pressure.tick()
        end
    end)

    -- OnTick: substitute for DZ's broken EveryOneSecond registration.
    -- DZ registers AdvanceLeaderTick on the non-existent "EveryOneSecond" event,
    -- so pulseId stays 0 forever and TryLeaderPulse always early-returns.
    -- OnTick fires every frame with a monotonic tick counter as argument.
    -- Dedicated server runs at 10 FPS (GameServer.java:816 sets lockFps=10),
    -- so ticks % 10 == 0 fires AdvanceLeaderTick once per real second.
    registerEvent("OnTick", function(ticks)
        if not fixupComplete then return end
        if not DynamicZ or not DynamicZ.AdvanceLeaderTick then return end
        if ticks % 10 ~= 0 then return end

        DynamicZ.AdvanceLeaderTick()

        -- Fix 15: DebugTrackTick registered on non-existent "EveryOneSecond"
        -- (DZ_Debug.lua:1501). Admin zombie tracking never ticks without this.
        -- DebugTrackTick self-throttles via getNowHours/nextTickHour internally.
        if DynamicZ.DebugTrackTick then
            DynamicZ.DebugTrackTick()
        end
    end)

    -- EveryDays: substitute for DZ's broken OnMidnight registration.
    -- DZ registers RecalculateWorldEvolution on "OnMidnight" which does not
    -- exist in PZ. EveryDays fires at in-game day rollover (GameTime.java:671
    -- triggers when getTimeOfDay() >= 24.0). RecalculateWorldEvolution is cheap
    -- arithmetic but calls ModData.transmit(), so once per day is appropriate.
    -- We also recompute using our corrected world age formula, since DZ's own
    -- RecalculateWorldEvolution uses the broken getWorldAgeDays on GameTime.
    registerEvent("EveryDays", function()
        if not fixupComplete then return end
        if not DynamicZ or not DynamicZ.Global then return end

        local g = DynamicZ.Global
        local computedEvo = computeWorldEvolution(g.totalKills)
        local currentEvo = toNumber(g.worldEvolution, 0.0)
        if computedEvo > currentEvo then
            g.worldEvolution = computedEvo
            logInfo(string.format("EveryDays: worldEvolution %.4f -> %.4f", currentEvo, computedEvo))
        end
        if DynamicZ.SaveGlobalState then
            DynamicZ.SaveGlobalState()
        end
    end)

    registerEvent("OnClientCommand", onClientCommand)
    DynamicZ_ChatCmds_ServerLoaded = true
    logInfo("Server persistence module loaded.")
end
