--[[
    DZChatCommands - Server-side persistence & pathfinding fixes for Dynamic Evolution Z

    Active fixes (9 remaining after DZ update — fixes 2,3,5,6,7,12,13,14,15 now fixed upstream):

    1. ModData persistence loss on restart: ModData.getOrCreate returns empty
       table on dedicated server restart, losing all saved state. Fixed by
       wrapping SaveGlobalState to write a file-based backup, and restoring
       from it during fixup.
    4. OnGameStart may not fire on dedicated servers: DZ uses addEvent which
       may not fire reliably. Fixed via EveryOneMinute fallback that runs
       fixup if OnGameStart was missed.
    8. Dead setLastHeardSound in search-after-target-loss: DZ's
       applyPersistenceAndSearch calls setLastHeardSound which is dead code
       in PZ B42 (field written but never read). Evolved zombies should search
       the player's last known position after losing sight, but the call has
       zero effect. Fixed by wrapping ApplyStageEvolutionBuffs with
       pathToLocationF (A* pathfinding via PathFindBehavior2/PolygonalMap2).
       Enhanced with player ID tracking for re-pathing to CURRENT position.
    9. Dead setLastHeardSound in stage 4 sense: applyStage4Sense calls dead
       setLastHeardSound when a stage 4+ zombie senses a nearby player. Fixed
       by extending the ApplyStageEvolutionBuffs wrapper to replicate
       findNearestPlayer and call pathToLocationF to the sensed player.
   10. Dead setLastHeardSound in ambient wander: TryAmbientWander calls dead
       setLastHeardSound for idle zombie movement. Fixed by wrapping
       TryAmbientWander to read target coords from modData and call
       pathToLocationF after the original succeeds.
   11. Dead setLastHeardSound in leader follower direction: ApplyLeaderInfluence
       calls dead setLastHeardSound to direct followers. Fixed by wrapping it
       to iterate influenced followers and call pathToLocationF per leader type
       (HUNTER/FRENZY/SHADOW/HIVE/SPLIT/migrating).
   16. SyncVanillaKillCounter offline player loss: DZ's sync only sums online
       players — offline player kills vanish from the sum. Fixed by tracking
       per-player getZombieKills() persisted to file, with totalKills =
       max(totalKills, sum of all known player kills).
   17. Dead setLastHeardSound in cohesion drift: TryCohesionDrift computes a
       centroid of nearby peers and calls dead setLastHeardSound to bias the
       zombie toward the group center. Fixed by wrapping TryCohesionDrift to
       re-derive the centroid via grid traversal and call pathToLocationF.
   18. Dead setLastHeardSound in thump-release re-issue:
       reissueDirectiveAfterThumpRelease calls dead setLastHeardSound for
       both migration followers (line 543) and ambient wander (line 557)
       after clearing a stale thump target. Fixed by wrapping
       TryReleaseStaleThumpTarget to read stored coords and pathToLocationF.

    Additionally enables debug UI for admin players (bypasses sandbox setting).

    Unfixable from companion mod (require upstream changes):
    - zombie:getMemory()/setMemory() don't exist (Kahlua exposes methods only).
    - getZombieRuntimeId() uses non-existent getObjectID(), but getOnlineID()
      works first in MP so this is not broken on dedicated servers.

    Solution:
    - Wraps SaveGlobalState to write file-based backup (fix 1).
    - Uses EveryOneMinute fallback for init (fix 4).
    - Wraps ApplyStageEvolutionBuffs (fixes 8, 9), TryAmbientWander (fix 10),
      ApplyLeaderInfluence (fix 11), TryCohesionDrift (fix 17), and
      TryReleaseStaleThumpTarget (fix 18) to replace dead setLastHeardSound
      calls with pathToLocationF.
    - Replaces SyncVanillaKillCounter with per-player vanilla-truth sync (fix 16).
    - Provides "ForceSave" and "Diagnostics" network commands.

    NOTE: Pressure system removed — DZ now has native DZ_Pressure.lua that is
    fully integrated into DZ_Evolution and DZ_Leader. Running both would cause
    double pressure accumulation and double evolution/migration influence.
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

local function isDebugEnabled()
    if SandboxVars and SandboxVars.DynamicZ then
        return SandboxVars.DynamicZ.EnableDebugMode == true
    end
    return false
end

local function logInfo(message)
    if not isDebugEnabled() then return end
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
    end

    DynamicZ._DZChatCmds_LeaderFixed = true
    logInfo("Leader fix installed: ApplyLeaderInfluence wrapped with pathToLocationF for followers.")
    return true
end




-- Install pathfinding fix for cohesion drift (fix 17).
--
-- DZ_Leader.lua's TryCohesionDrift computes a centroid of nearby eligible
-- peers (reservoir-sampled), applies a strength multiplier, and calls dead
-- setLastHeardSound to bias the zombie toward the group center. The drift
-- target is ephemeral (local variables, never stored in modData), so we
-- can't read it post-call like the wander fix does.
--
-- Strategy: snapshot dz.cohesionLastDriftHour before the original. If it
-- changed (drift occurred), re-derive the approximate centroid using our
-- own grid traversal and path there. The result may differ slightly from
-- DZ's reservoir-sampled subset, but the directional intent is equivalent.
local function installCohesionDriftFix()
    if not DynamicZ or not DynamicZ.TryCohesionDrift then
        logInfo("WARN installCohesionDriftFix: DynamicZ.TryCohesionDrift not available.")
        return false
    end
    if DynamicZ._DZChatCmds_CohesionDriftFixed then
        logInfo("Cohesion drift fix already installed.")
        return true
    end

    local origTryCohesionDrift = DynamicZ.TryCohesionDrift

    DynamicZ.TryCohesionDrift = function(zombie, dz)
        -- Resolve dz before call so we can snapshot
        dz = dz or (zombie and zombie.getModData and zombie:getModData() and zombie:getModData().DZ)
        local prevDriftHour = dz and toNumber(dz.cohesionLastDriftHour, nil)

        local result = origTryCohesionDrift(zombie, dz)

        -- Only act if DZ actually decided to drift (cohesionLastDriftHour updated)
        if result ~= true then return result end
        if not zombie or not dz then return result end

        local newDriftHour = toNumber(dz.cohesionLastDriftHour, nil)
        if not newDriftHour or newDriftHour == prevDriftHour then return result end

        -- Re-derive approximate centroid from nearby zombies on the same floor.
        -- DZ uses reservoir sampling from peers with isEligibleCohesionPeer;
        -- we use a simpler full-average of nearby zombies that are under leader
        -- influence or migrating (the two conditions DZ requires for drift eligibility).
        local zx = toNumber(zombie:getX(), nil)
        local zy = toNumber(zombie:getY(), nil)
        local zz = math.floor(toNumber(zombie:getZ(), 0))
        if not zx or not zy then return result end

        local Config = DynamicZ_Config or {}
        local radius = math.max(2, math.floor(toNumber(Config.CohesionDriftNeighborRadius, 6)))

        local cell = getCell and getCell()
        if not cell then return result end

        local cx = math.floor(zx)
        local cy = math.floor(zy)
        local radiusSq = radius * radius
        local sumX, sumY, count = 0, 0, 0

        for gx = cx - radius, cx + radius do
            for gy = cy - radius, cy + radius do
                local dx = gx - cx
                local dy = gy - cy
                if (dx * dx + dy * dy) <= radiusSq then
                    local ok, sq = pcall(function() return cell:getGridSquare(gx, gy, zz) end)
                    if ok and sq then
                        local ok2, movObjs = pcall(function() return sq:getMovingObjects() end)
                        if ok2 and movObjs then
                            for i = 0, movObjs:size() - 1 do
                                local obj = movObjs:get(i)
                                if obj and obj ~= zombie and instanceof and instanceof(obj, "IsoZombie") then
                                    local fMD = obj.getModData and obj:getModData()
                                    local fDZ = fMD and fMD.DZ
                                    if fDZ then
                                        local nowH = getNowHours()
                                        local eligible = fDZ.isMigrating == true
                                            or (fDZ.leaderInfluence == true
                                                and toNumber(fDZ.leaderInfluenceUntil, 0) > nowH)
                                        if eligible then
                                            sumX = sumX + toNumber(obj:getX(), zx)
                                            sumY = sumY + toNumber(obj:getY(), zy)
                                            count = count + 1
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        if count < 2 then return result end

        local centerX = sumX / count
        local centerY = sumY / count
        local ddx = centerX - zx
        local ddy = centerY - zy
        local distance = math.sqrt((ddx * ddx) + (ddy * ddy))
        if distance <= 0.5 then return result end

        local strength = clamp(toNumber(Config.CohesionDriftStrength, 0.45), 0.10, 1.0)
        local driftX = zx + (ddx * strength)
        local driftY = zy + (ddy * strength)

        if pathToLocation(zombie, driftX, driftY, zz) then
            logInfo(string.format(
                "Cohesion drift fix: zombie %d pathing toward group center (%.0f, %.0f) peers=%d",
                zombie:getID(), driftX, driftY, count))
        end

        return result
    end

    DynamicZ._DZChatCmds_CohesionDriftFixed = true
    logInfo("Cohesion drift fix installed: TryCohesionDrift wrapped with pathToLocationF.")
    return true
end

-- Install pathfinding fix for thump-release re-issue (fix 18).
--
-- DZ_Leader.lua's TryReleaseStaleThumpTarget detects zombies that have been
-- thumping a barricade too long with no player nearby, clears their thump
-- target, then calls the local reissueDirectiveAfterThumpRelease to redirect
-- them. That function uses dead setLastHeardSound for both migration followers
-- (line 543) and ambient wander re-issue (line 557). The migration leader
-- branch (line 541) correctly uses tryPathToLocation, but non-leaders get
-- no actual movement.
--
-- The coords ARE stored in dz moddata: migrationTargetX/Y/Z for migrating
-- zombies, ambientLastTargetX/Y/Z for wandering zombies. We wrap
-- TryReleaseStaleThumpTarget and if it returns true, read the appropriate
-- coords and call pathToLocationF.
local function installThumpReleaseFix()
    if not DynamicZ or not DynamicZ.TryReleaseStaleThumpTarget then
        logInfo("WARN installThumpReleaseFix: DynamicZ.TryReleaseStaleThumpTarget not available.")
        return false
    end
    if DynamicZ._DZChatCmds_ThumpReleaseFixed then
        logInfo("Thump release fix already installed.")
        return true
    end

    local origTryReleaseStaleThumpTarget = DynamicZ.TryReleaseStaleThumpTarget

    DynamicZ.TryReleaseStaleThumpTarget = function(zombie, dz)
        local result = origTryReleaseStaleThumpTarget(zombie, dz)

        -- Only act when release actually happened
        if result ~= true then return result end
        if not zombie then return result end

        dz = dz or (zombie.getModData and zombie:getModData() and zombie:getModData().DZ)
        if not dz then return result end

        local targetX, targetY, targetZ

        if dz.isMigrating == true then
            -- Migration case: leader already got pathToLocation from DZ (line 541).
            -- Non-leader followers only got dead setLastHeardSound (line 543).
            if dz.migrationRole ~= "leader" then
                targetX = toNumber(dz.migrationTargetX, nil)
                targetY = toNumber(dz.migrationTargetY, nil)
                targetZ = math.floor(toNumber(dz.migrationTargetZ,
                    zombie.getZ and toNumber(zombie:getZ(), 0) or 0))
            end
        else
            -- Ambient wander re-issue: dead setLastHeardSound at line 557.
            targetX = toNumber(dz.ambientLastTargetX, nil)
            targetY = toNumber(dz.ambientLastTargetY, nil)
            targetZ = math.floor(toNumber(dz.ambientLastTargetZ,
                zombie.getZ and toNumber(zombie:getZ(), 0) or 0))
        end

        if targetX and targetY then
            if pathToLocation(zombie, targetX, targetY, targetZ or 0) then
                logInfo(string.format(
                    "Thump release fix: zombie %d pathing to (%.0f, %.0f, %.0f) mode=%s",
                    zombie:getID(), targetX, targetY, targetZ or 0,
                    tostring(dz.ambientMode or dz.migrationRole or "?")))
            end
        end

        return result
    end

    DynamicZ._DZChatCmds_ThumpReleaseFixed = true
    logInfo("Thump release fix installed: TryReleaseStaleThumpTarget wrapped with pathToLocationF.")
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

    -- Sync totalKills from vanilla kill counters (the source of truth).
    -- This handles both fresh starts and restarts where ModData was lost.
    syncVanillaKills()
    logInfo(string.format("After vanilla sync: totalKills=%d", math.floor(toNumber(g.totalKills, 0))))

    -- Recalculate worldEvolution using DZ's own (now-correct) formula.
    -- DZ update fixed getWorldAgeDaysSafe to use getWorldAgeDaysSinceBegin.
    if DynamicZ.RecalculateWorldEvolution then
        DynamicZ.RecalculateWorldEvolution()
        logInfo(string.format("After recalc: worldEvolution=%.4f", toNumber(g.worldEvolution, 0.0)))
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

-- Install all behavior fixes.
-- Called from multiple init paths (OnGameStart, EveryOneMinute, ensureFixup).
-- NOTE: Fixes 2,3,5,6,7,12,13,14,15 removed — now fixed natively in DZ update.
-- Remaining active fixes: 1 (backup), 4 (OnGameStart fallback), 8-9 (search/sense),
-- 10 (wander), 11 (leader follower), 16 (kill sync), 17 (cohesion drift),
-- 18 (thump release), admin debug access.
local function installAllFixes()
    installSaveHook()
    installKillSyncFix()
    installSearchFix()
    installWanderFix()
    installLeaderFix()
    installCohesionDriftFix()
    installThumpReleaseFix()
    installAdminDebugAccess()
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
        lines[#lines + 1] = string.format("KillSyncFixed: %s",
            tostring(DynamicZ and DynamicZ._DZChatCmds_KillSyncFixed or false))
        lines[#lines + 1] = string.format("CohesionDriftFixed: %s",
            tostring(DynamicZ and DynamicZ._DZChatCmds_CohesionDriftFixed or false))
        lines[#lines + 1] = string.format("ThumpReleaseFixed: %s",
            tostring(DynamicZ and DynamicZ._DZChatCmds_ThumpReleaseFixed or false))
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

        -- Check backup file
        local backup = readBackup()
        if backup then
            lines[#lines + 1] = string.format("Backup file: kills=%d evo=%.4f",
                toNumber(backup.totalKills, 0), toNumber(backup.worldEvolution, 0))
        else
            lines[#lines + 1] = "Backup file: not found"
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

    -- Fallback: EveryOneMinute checks if fixup was missed (fix 4).
    -- DZ's EveryOneMinute now handles SyncVanillaKillCounter (our override),
    -- TryAutoSeedLeaders, RecountActiveLeaders, and TickPressureSystem natively.
    -- We only need the init fallback here.
    registerEvent("EveryOneMinute", function()
        if fixupComplete then return end
        if not DynamicZ or not DynamicZ.Global then return end
        if DynamicZ.Global.totalKills == nil then return end
        logInfo("EveryOneMinute fallback: OnGameStart may not have fired, running fixup now.")
        installAllFixes()
        syncVanillaKills()
        if onGameStartFixup() then
            fixupComplete = true
        end
    end)

    -- NOTE: OnTick and EveryDays handlers removed — DZ update handles these natively.
    -- DZ_Core.lua now simulates EveryOneSecond via OnTick (calling AdvanceLeaderTick
    -- + DebugTrackTick), and EveryDays calls OnMidnight → RecalculateWorldEvolution.
    -- Our SaveGlobalState hook ensures backups are written when DZ saves.

    registerEvent("OnClientCommand", onClientCommand)
    DynamicZ_ChatCmds_ServerLoaded = true
    logInfo("Server persistence module loaded.")
end
