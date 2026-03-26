--[[
    DZChatCommands - Server-side pathfinding fixes for Dynamic Evolution Z

    Active fixes (1 essential fix + idle repath + admin debug access):

   11. Dead setLastHeardSound in leader follower direction: ApplyLeaderInfluence's
       applyFollowerBoost (DZ_Leader:4998-5107) still uses trySetLastHeardSound
       for ALL 5 leader types (HUNTER/FRENZY/SHADOW/HIVE/SPLIT) with zero
       tryPathToLocation calls. ESSENTIAL — this fix is the sole source of
       working follower movement. Fixed by wrapping ApplyLeaderInfluence to
       iterate influenced followers and call pathToLocationF per leader type.
       New STALKER/HOWLER types are safe — ApplyLeaderInfluence returns early
       for them (DZ_Leader:5130-5140) and they don't set leaderInfluence on
       followers (handled by dedicated runStalkerLeader/runHowlerLeader with
       native tryPathToLocation).

    Idle follower re-path: OnZombieUpdate detects when influenced followers
    complete their A* path (go idle between 3s pulses) and immediately re-paths
    toward zombie:getTarget() — the player's CURRENT position. Reduces worst-case
    idle time from 3000ms to ~300ms, eliminating visible stop-wait-repath stutter.
    Works independently of DZ's CoreBatchProcessingEnabled — PZ engine fires
    OnZombieUpdate per-frame regardless of DZ's batch processing config.

    Additionally enables debug UI for admin players via DebugEnabledOverride
    (survives DZ_Core init reset regardless of mod load order).

    Removed fixes (now handled natively by DZ):
    - Fix 1 (ModData backup): DZ handles its own file-based backup/restore.
    - Fix 4 (OnGameStart fallback): DZ's ensureStartupStateAvailable handles it.
    - Fix 8 (search after target loss): DZ uses tryPathToLocation natively.
    - Fix 9 (stage 4 sense): DZ uses tryPathToLocation natively.
    - Fix 10 (ambient wander): DZ uses tryAmbientPathWithFallback natively
      (tryPathToLocation + tryPathToLocationFDirect). Works on auth client.
    - Fix 16 (kill sync): DZ tracks per-player kills natively.
    - Fix 17 (cohesion drift): DZ uses tryPathToLocation natively with
      CohesionDriftPathingEnabled + budget system (DZ_Leader:3614-3628).
    - Fix 18 (thump release): DZ uses tryPathToLocation natively in
      reissueDirectiveAfterThumpRelease for all cases (DZ_Leader:2413-2509).
    - Fixes 2,3,5,6,7,12,13,14,15: fixed upstream in earlier DZ updates.

    Unfixable from companion mod (require upstream changes):
    - zombie:getMemory()/setMemory() don't exist (Kahlua exposes methods only).
    - getZombieRuntimeId() uses non-existent getObjectID(), but getOnlineID()
      works first in MP so this is not broken on dedicated servers.

    Solution:
    - Wraps ApplyLeaderInfluence (fix 11) to replace dead setLastHeardSound
      calls in applyFollowerBoost with pathToLocationF.
    - Provides "ForceSave" and "Diagnostics" network commands.

    NOTE: Pressure system removed -- DZ now has native DZ_Pressure.lua that is
    fully integrated into DZ_Evolution and DZ_Leader. Running both would cause
    double pressure accumulation and double evolution/migration influence.
]]

local NET_MODULE = "DZChatCmds"
local LOG_TAG = "[DZChatCommands]"

local fixupComplete = false


local function toNumber(value, fallback)
    local n = tonumber(value)
    return n ~= nil and n or fallback
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

-- Submit an A* pathfinding request via PathFindBehavior2.pathToLocationF
-- (works on dedicated server). Sets animation variables to trigger movement.
--
-- Stutter prevention for walking zombies (path2 exists):
-- pathToLocationF is always called (updates A* target via setData), but
-- bPathfind/bMoving are skipped. The zombie is already in PathFindState;
-- setData resets progress to notrunning, and pfb2.update() resubmits A*
-- next frame. During the 1-3 frame gap, updateWhileRunningPathfind()
-- keeps the zombie moving toward the last waypoint (pathNextX/Y).
-- No state re-entry, no idle animation.
--
-- Critically, this means the zombie's A* destination always stays ahead
-- of it (updated every 3s pulse). It never "completes" its path while
-- following a moving target, so it never exits PathFindState to idle.
-- Identical-tile targets are already filtered by needsNewPath upstream.
--
-- For idle zombies (no path2): pathToLocationF + animation vars to enter
-- PathFindState.
-- Returns true on success, false on error.
local function pathToLocation(zombie, x, y, z)
    local ok = pcall(function()
        local pathBehavior = zombie:getPathFindBehavior2()
        if pathBehavior and pathBehavior.pathToLocationF then
            pathBehavior:pathToLocationF(x, y, z)
            -- Only set animation vars when zombie is idle (path2 nil).
            -- If already in PathFindState (path2 exists), pathToLocationF
            -- updated the target; pfb2.update() handles the rest.
            if zombie:getPath2() == nil then
                zombie:setVariable("bPathfind", true)
                zombie:setVariable("bMoving", false)
            end
        end
    end)
    return ok
end

-- Get world age in hours for search window calculation.
-- Replicates DZ_Evolution.lua's local getNowHours() function.
local function getNowHours()
    if not getGameTime then return 0 end
    local gameTime = getGameTime()
    if not gameTime or not gameTime.getWorldAgeHours then return 0 end
    return toNumber(gameTime:getWorldAgeHours(), 0)
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
-- New STALKER/HOWLER leader types are handled safely: ApplyLeaderInfluence
-- returns early at DZ_Leader:5130-5140 for these types (delegating to
-- dedicated runStalkerLeader/runHowlerLeader functions). Neither sets
-- leaderInfluence=true on followers via applyFollowerBoost, so our grid
-- traversal finds no influenced followers and takes no action.
--
-- This fix wraps ApplyLeaderInfluence. Before calling the original, we detect
-- FRENZY/SPLIT leaders and save nearby zombie path2 references. DZ's
-- applyFollowerBoost calls tryResetPath (DZ_Leader:5059,5093) which sets
-- path2=nil, destroying the current A* path. Our pathToLocationF is async —
-- the replacement path arrives 1-N ticks later. Without the save/restore, the
-- zombie stops dead in the gap. By restoring path2 after the original returns,
-- the zombie keeps walking its old path until A* delivers the new one.
--
-- After the original runs (which sets follower modData: leaderInfluence,
-- leaderAuraType, leaderInfluenceUntil, migrationTargetX/Y/Z, etc.), we:
-- 1. Restore path2 for FRENZY/SPLIT followers (smooth transition)
-- 2. Fix the leader's own migration path (if migrating)
-- 3. Iterate zombies in radius (replicating DZ's local forEachZombieInRadius
--    using cell:getGridSquare grid traversal) and call pathToLocationF on each
--    influenced follower with the appropriate coordinates:
--    - HUNTER/SHADOW/HIVE: leader's target position
--    - FRENZY: leader's target position, or leader's own position as fallback
--    - SPLIT: 3-way flanking offset from follower position hash, replicating
--      DZ's local computeSplitPoint logic (bucket = abs((fx + fy*3) % 3),
--      offset by Config.LeaderSplitFlankDistance in 3 directions)
--    - Migrating followers: blended migration target (replicating DZ's blend
--      formula from applyMigrationDirective)
-- 4. Deduplication: floor-based tile comparison via fDZ._cmdLastPathX/Y/Z
--    skips redundant pathToLocationF when the computed target tile is unchanged.
--    Effective for stationary followers and non-migrating with stable targets.
--    Migration followers see limited benefit (blend shifts with follower position).
-- 5. Multi-leader dedup: when overlapping leaders both iterate the same follower,
--    only the closest leader's path wins (per-pulse {zombieId→distSq} tracking,
--    mirroring DZ's canLeaderClaimFollowerForPulse distance arbitration).

-- Check if target tile changed from last pathed tile. Returns true if path needed.
-- Updates cache when target changed (pathToLocation always issues pathToLocationF
-- when this returns true, so cache stays in sync).
local function needsNewPath(fDZ, px, py, pz)
    local tileX = math.floor(px)
    local tileY = math.floor(py)
    local tileZ = pz  -- already integer from math.floor upstream
    if fDZ._cmdLastPathX == tileX
       and fDZ._cmdLastPathY == tileY
       and fDZ._cmdLastPathZ == tileZ then
        return false
    end
    fDZ._cmdLastPathX = tileX
    fDZ._cmdLastPathY = tileY
    fDZ._cmdLastPathZ = tileZ
    return true
end

-- Save path2 references for zombies near a leader. FRENZY (DZ_Leader:5059) and
-- SPLIT (DZ_Leader:5093) call tryResetPath which sets path2=nil, destroying the
-- zombie's current A* path. The zombie stops dead until our async pathToLocationF
-- result arrives. By saving and restoring path2, the zombie keeps walking its old
-- path until A* delivers the new one (smooth transition, no stutter).
-- Returns a table {zombie=path} or nil.
local function saveNearbyPaths(leader, leaderX, leaderY, leaderZ, radius)
    local cell = getCell and getCell()
    if not cell then return nil end

    local saved = {}
    local cx = math.floor(leaderX)
    local cy = math.floor(leaderY)
    local rSq = radius * radius
    local count = 0

    for gx = cx - radius, cx + radius do
        for gy = cy - radius, cy + radius do
            local ddx = gx - cx
            local ddy = gy - cy
            if (ddx * ddx + ddy * ddy) <= rSq then
                local ok, sq = pcall(function() return cell:getGridSquare(gx, gy, leaderZ) end)
                if ok and sq then
                    local ok2, movObjs = pcall(function() return sq:getMovingObjects() end)
                    if ok2 and movObjs then
                        for i = 0, movObjs:size() - 1 do
                            local obj = movObjs:get(i)
                            if obj and obj ~= leader and instanceof and instanceof(obj, "IsoZombie") then
                                local ok3, path = pcall(function() return obj:getPath2() end)
                                if ok3 and path ~= nil then
                                    saved[obj] = path
                                    count = count + 1
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return count > 0 and saved or nil
end

-- Restore path2 for zombies where DZ's tryResetPath cleared it.
local function restoreClearedPaths(savedPaths)
    if not savedPaths then return end
    for zombie, path in pairs(savedPaths) do
        local ok, cur = pcall(function() return zombie:getPath2() end)
        if ok and cur == nil then
            pcall(function() zombie:setPath2(path) end)
        end
    end
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

    -- Multi-leader dedup: when two leaders have overlapping radii, DZ's
    -- canLeaderClaimFollowerForPulse (DZ_Leader:2778) gives the follower to the
    -- closest leader. But our wrapper iterates ALL influenced followers in radius
    -- regardless of who claimed them. Without this tracking, a farther leader
    -- could override the closer leader's path → twitching between targets.
    -- Track {zombieId = distSq} per pulse so only the closest leader's path wins.
    local lastPathedPulseId = -1
    local pathedThisPulse = {}

    DynamicZ.ApplyLeaderInfluence = function(leader, dz, pulseIdOverride)
        if not leader or not dz or dz.isLeader ~= true then
            origApplyLeaderInfluence(leader, dz, pulseIdOverride)
            return
        end

        local Config = DynamicZ_Config or {}

        -- Reset per-pulse tracking when a new pulse starts
        local currentPulseId = math.floor(toNumber(
            pulseIdOverride,
            toNumber(DynamicZ.Runtime and DynamicZ.Runtime.pulseId, 0)
        ))
        if currentPulseId ~= lastPathedPulseId then
            lastPathedPulseId = currentPulseId
            pathedThisPulse = {}
        end

        -- Leader positions (needed for path save AND follower traversal)
        local leaderX = toNumber(leader:getX(), nil)
        local leaderY = toNumber(leader:getY(), nil)
        local leaderZ = math.floor(toNumber(leader:getZ(), 0))

        -- FRENZY (DZ_Leader:5059) and SPLIT (DZ_Leader:5093) call tryResetPath
        -- on each follower, setting path2=nil. This destroys the zombie's current
        -- A* path. Our pathToLocationF is async — the new path arrives 1-N ticks
        -- later. Without intervention, the zombie stops dead in the gap.
        -- Fix: save path2 before DZ runs, restore after. The zombie keeps walking
        -- its old path until A* delivers the new one (smooth transition).
        local savedPaths = nil
        if leaderX and leaderY then
            local leaderType = nil
            if DynamicZ.AssignLeaderType then
                leaderType = DynamicZ.AssignLeaderType(leader, dz, nil)
                if DynamicZ.NormalizeLeaderType then
                    leaderType = DynamicZ.NormalizeLeaderType(leaderType) or leaderType
                end
            end
            if leaderType == "FRENZY" or leaderType == "SPLIT" then
                local radius = math.floor(toNumber(Config.LeaderRadius, 16))
                savedPaths = saveNearbyPaths(leader, leaderX, leaderY, leaderZ, radius)
            end
        end

        -- Let DZ do its processing (sets modData, timers, targets; may tryResetPath)
        origApplyLeaderInfluence(leader, dz, pulseIdOverride)

        -- Restore paths cleared by tryResetPath (FRENZY/SPLIT only)
        restoreClearedPaths(savedPaths)

        local nowH = getNowHours()

        -- Resolve leader's target
        local leaderTarget = nil
        if leader.getTarget then
            local ok, val = pcall(function() return leader:getTarget() end)
            if ok then leaderTarget = val end
        end

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
        local radius = math.floor(toNumber(Config.LeaderRadius, 16))
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
                                        -- Multi-leader dedup: skip if a closer leader
                                        -- already pathed this zombie this pulse.
                                        -- Mirrors DZ's canLeaderClaimFollowerForPulse
                                        -- distance arbitration (DZ_Leader:2778-2803).
                                        local objId = obj:getID()
                                        local fx = toNumber(obj:getX(), 0)
                                        local fy = toNumber(obj:getY(), 0)
                                        local fdx = fx - leaderX
                                        local fdy = fy - leaderY
                                        local ourDistSq = fdx * fdx + fdy * fdy
                                        local prevDistSq = pathedThisPulse[objId]
                                        if prevDistSq and prevDistSq < ourDistSq then
                                            -- Closer leader already handled this follower
                                        else
                                        pathedThisPulse[objId] = ourDistSq
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
                                            local finalZ = pz or leaderZ
                                            if needsNewPath(fDZ, px, py, finalZ) then
                                                pathToLocation(obj, px, py, finalZ)
                                            end
                                        end
                                        end -- multi-leader dedup else
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

-- One-time migration: merge companion mod's per-player kill data into DZ's native file.
-- DZ's writeTrackedPlayerKills is local, so we write DZ's file directly using same format.
local function migrateKillData()
    local companionFile = "DZChatCommands_PlayerKills.ini"
    local reader = getFileReader(companionFile, true)
    if not reader then return end  -- no companion file, nothing to migrate

    local companionKills = {}
    local line = reader:readLine()
    while line do
        local user, kills = string.match(line, "^(.-)=(%d+)$")
        if user and kills then companionKills[user] = tonumber(kills) end
        line = reader:readLine()
    end
    reader:close()

    local runtime = DynamicZ.Runtime
    if not runtime then return end
    local dzKills = runtime.playerKills
    if not dzKills then
        dzKills = {}
        runtime.playerKills = dzKills
    end

    local merged = false
    for user, kills in pairs(companionKills) do
        local existing = tonumber(dzKills[user]) or 0
        if kills > existing then
            dzKills[user] = kills
            merged = true
        end
    end

    if merged then
        -- Write DZ's file directly (same format as DZ_Core:397-408)
        local writer = getFileWriter("DynamicZ_PlayerKills.ini", true, false)
        if writer then
            for user, kills in pairs(dzKills) do
                writer:writeLine(tostring(user) .. "=" .. tostring(math.floor(kills)))
            end
            writer:close()
        end
        -- Trigger DZ sync to update totalKills from the merged table
        if DynamicZ.SyncVanillaKillCounter then
            DynamicZ.SyncVanillaKillCounter()
        end
        logInfo("Migrated kill data from companion to DZ native file.")
    end
end

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

    -- One-time kill data migration from companion's file to DZ's native file
    migrateKillData()

    -- Recalculate worldEvolution using DZ's own formula
    if DynamicZ.RecalculateWorldEvolution then
        DynamicZ.RecalculateWorldEvolution()
        logInfo(string.format("After recalc: worldEvolution=%.4f",
            toNumber(DynamicZ.Global.worldEvolution, 0.0)))
    end

    -- Save via DZ's native SaveGlobalState (includes backup)
    if DynamicZ.SaveGlobalState then
        DynamicZ.SaveGlobalState()
    end

    logInfo("onGameStartFixup: complete.")
    return true
end

-- Enable debug UI for admin players without requiring the sandbox debug setting.
-- Sets DynamicZ.DebugEnabledOverride = true, which is checked first by
-- DZ_Debug.lua's IsDebugEnabled() (line 83-85, priority 1). This survives
-- DZ_Core's init reset of DebugEnabled regardless of mod load order.
-- Effect: canUseDebug() returns true for admin players, DebugTrackTick and
-- DebugHeartbeat run server-side, buildStatePayload sends debugEnabled=true
-- to clients enabling HUD overlay/inspect/context menu for admin players.
local function installAdminDebugAccess()
    if not DynamicZ then
        logInfo("WARN installAdminDebugAccess: DynamicZ table not available.")
        return false
    end
    -- DZ_Debug.lua IsDebugEnabled() priority: DebugEnabledOverride > DebugEnabled > sandbox.
    -- DZ_Core.lua resets both to nil/false during init (line 478-479). Using the override
    -- ensures our setting survives regardless of load order, since IsDebugEnabled checks
    -- it first and it's not touched after DZ's one-time init.
    if DynamicZ.DebugEnabledOverride == true then
        return true
    end

    DynamicZ.DebugEnabledOverride = true
    logInfo("Debug UI enabled for admin players (DebugEnabledOverride set).")
    return true
end

-- Idle follower re-path via OnZombieUpdate.
--
-- Problem: the 3-second leader pulse paths followers to the player's position at
-- pulse time. If the player is moving, the zombie arrives at the stale position
-- in 1-2s, completes PathFindState, goes idle, and waits up to 3s for the next
-- pulse. Visible as stop-wait-repath stuttering at 5-7 tile distance.
--
-- Fix: OnZombieUpdate fires per-frame per-zombie on the auth-owning client (where
-- DZ and this mod run). We throttle to ~300ms per zombie. When an influenced
-- follower has no active path (completed its A* path and exited PathFindState),
-- we immediately re-path toward zombie:getTarget() — the player they're chasing.
-- This gives us the player's CURRENT position (not 3s stale), and the zombie
-- resumes moving within 1-3 frames instead of waiting for the next pulse.
--
-- Works independently of DZ's CoreBatchProcessingEnabled (default: true). DZ's
-- batch processing replaces DZ's own OnZombieUpdate handler, but PZ engine fires
-- the OnZombieUpdate event per-frame per-zombie regardless. Our handler is
-- registered independently and fires on every zombie update on the auth client.
--
-- Only acts on zombies that fix 11 has previously pathed (_cmdLastPathX exists).
-- Worst-case idle time drops from 3000ms to ~300ms.
local IDLE_CHECK_INTERVAL_MS = 300

local function onZombieUpdateIdleRepath(zombie)
    if not zombie then return end

    -- Fast bail: only act on zombies our fix 11 has pathed
    local ok0, md = pcall(function() return zombie:getModData() end)
    if not ok0 or not md then return end
    local fDZ = md.DZ
    if not fDZ then return end

    -- Only influenced followers that we've previously pathed
    if fDZ.leaderInfluence ~= true then return end
    if not fDZ._cmdLastPathX then return end

    -- Throttle: don't check every frame
    local nowMs = getTimestampMs and getTimestampMs() or 0
    local lastCheck = toNumber(fDZ._cmdIdleCheckMs, 0)
    if (nowMs - lastCheck) < IDLE_CHECK_INTERVAL_MS then return end
    fDZ._cmdIdleCheckMs = nowMs

    -- Check if zombie completed its path (went idle)
    local ok1, path = pcall(function() return zombie:getPath2() end)
    if not ok1 or path ~= nil then return end  -- still has active path, good

    -- Still influenced? (check expiry)
    local nowH = getNowHours()
    if toNumber(fDZ.leaderInfluenceUntil, 0) <= nowH then return end

    -- Find fresh target: zombie's current attack target (the player it can see)
    local targetX, targetY, targetZ
    if zombie.getTarget then
        local ok2, tgt = pcall(function() return zombie:getTarget() end)
        if ok2 and tgt then
            targetX = toNumber(tgt:getX(), nil)
            targetY = toNumber(tgt:getY(), nil)
            targetZ = math.floor(toNumber(tgt:getZ(), 0))
        end
    end

    -- Fallback for migrating followers: use stored migration target
    if not targetX or not targetY then
        if fDZ.isMigrating == true then
            targetX = toNumber(fDZ.migrationTargetX, nil)
            targetY = toNumber(fDZ.migrationTargetY, nil)
            targetZ = math.floor(toNumber(fDZ.migrationTargetZ, 0))
        end
    end

    if not targetX or not targetY then return end

    -- Check distance: don't re-path if zombie is already very close to target
    -- (within 2 tiles). The zombie arrived, it's just standing near the player.
    local zx = toNumber(zombie:getX(), nil)
    local zy = toNumber(zombie:getY(), nil)
    if zx and zy then
        local ddx = targetX - zx
        local ddy = targetY - zy
        if (ddx * ddx + ddy * ddy) < 4 then return end  -- within 2 tiles
    end

    -- Clear needsNewPath cache so the next 3s pulse isn't deduped against
    -- this emergency re-path (the pulse target may differ from ours)
    fDZ._cmdLastPathX = nil
    fDZ._cmdLastPathY = nil
    fDZ._cmdLastPathZ = nil

    pathToLocation(zombie, targetX, targetY, targetZ)
    logInfo(string.format("Idle repath: zombie %d re-pathed to (%.0f, %.0f)",
        zombie:getID(), targetX, targetY))
end

-- Active fix: 11 (leader follower pathing), idle follower repath, admin debug.
-- Removed: 1-10, 12-18 (all handled natively by DZ).
local function installAllFixes()
    installLeaderFix()
    installAdminDebugAccess()
end

local function ensureFixup()
    if fixupComplete then return end
    if not DynamicZ or not DynamicZ.Global then return end
    logInfo("Lazy-init: running fixup from first client command.")
    installAllFixes()
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

        -- Send confirmation back
        if sendServerCommand then
            local g = DynamicZ and DynamicZ.Global or {}
            local message = string.format(
                "Force-saved: totalKills=%d worldEvolution=%.4f",
                math.floor(toNumber(g.totalKills, 0)),
                toNumber(g.worldEvolution, 0.0)
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
        lines[#lines + 1] = string.format("LeaderFixed: %s",
            tostring(DynamicZ and DynamicZ._DZChatCmds_LeaderFixed or false))
        lines[#lines + 1] = string.format("DebugEnabledOverride: %s",
            tostring(DynamicZ and DynamicZ.DebugEnabledOverride))
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
    registerEvent("OnGameStart", function()
        logInfo("OnGameStart event fired.")
        installAllFixes()
        if onGameStartFixup() then
            fixupComplete = true
        end
    end)

    -- Fallback: install wraps if OnGameStart didn't fire.
    -- DZ's own ensureStartupStateAvailable handles startup state natively.
    registerEvent("EveryOneMinute", function()
        if fixupComplete then return end
        if not DynamicZ or not DynamicZ.Global then return end
        logInfo("EveryOneMinute fallback: installing fixes.")
        installAllFixes()
        if onGameStartFixup() then
            fixupComplete = true
        end
    end)

    registerEvent("OnClientCommand", onClientCommand)

    -- Idle follower re-path: detect path completion per-frame and re-path
    -- immediately toward the player, eliminating the 3-second pulse wait.
    -- OnZombieUpdate fires per-frame per-zombie on the auth-owning client
    -- (where DZ runs). Works independently of CoreBatchProcessingEnabled —
    -- PZ engine fires this event regardless of DZ's batch processing config.
    registerEvent("OnZombieUpdate", onZombieUpdateIdleRepath)

    DynamicZ_ChatCmds_ServerLoaded = true
    logInfo("Server persistence module loaded.")
end
