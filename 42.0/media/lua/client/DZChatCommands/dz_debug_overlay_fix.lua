--[[
    DZChatCommands - Debug overlay fix for Dynamic Evolution Z

    DZ_DebugClient.lua registers updateNearestZombieCache on the
    "EveryOneSecond" event, but that event does NOT exist in PZ's
    LuaEventManager (only EveryOneMinute and EveryTenMinutes exist).
    The registration silently fails, so the debug overlay's nearest-
    zombie readout never updates.

    This fix re-registers the same function on the OnTick event,
    throttled to once per ~1000 ms using getTimestampMs() (verified
    global: LuaManager.java line 7709, wraps System.currentTimeMillis).

    API verification (all from LuaManager.GlobalObject, decompiled source):
      getTimestampMs()              -> line 7709, returns System.currentTimeMillis()
      getPerformance()              -> line 3503, returns PerformanceSettings.instance
      getPerformance():getFramerate() -> PerformanceSettings.java line 50, delegates to getLockFPS()
      getAverageFPS()               -> line 9780, returns GameWindow.averageFPS (capped)
      OnTick event                  -> LuaEventManager.java line 590, fires from IngameState.onTick()
                                       with numberTicks as argument
]]

if isServer and isServer() then return end

-- Wait for DynamicZ to be loaded (this mod loads after DZ via mod list order)
if not DynamicZ or not DynamicZ.DebugClient then
    return
end

-- Guard against double-loading
if DynamicZ._debugOverlayFixLoaded then
    return
end
DynamicZ._debugOverlayFixLoaded = true

local ClientState = DynamicZ.DebugClient
local INTERVAL_MS = 1000
local lastUpdateMs = 0

-- Reference the original function that DZ defines but never successfully hooks
-- We call it directly since it reads from DynamicZ.DebugClient state
local function tickUpdateNearestZombieCache()
    local nowMs = getTimestampMs()
    if (nowMs - lastUpdateMs) < INTERVAL_MS then
        return
    end
    lastUpdateMs = nowMs

    -- Guard: DZ may not have finished loading its functions yet
    if not DynamicZ or not DynamicZ.DebugClient then
        return
    end

    -- Reproduce the exact logic from DZ_DebugClient.lua lines 704-729
    -- We cannot call the local function directly (it's local to that file),
    -- so we inline the equivalent logic using the same DynamicZ APIs.

    -- Check canShowOverlay equivalent
    if DynamicZ_Config and DynamicZ_Config.DebugOverlay == false then
        ClientState.targetStage = nil
        ClientState.targetDistance = nil
        return
    end

    -- Check debug enabled
    local debugEnabled = false
    if DynamicZ.DebugEnabled ~= nil then
        debugEnabled = DynamicZ.DebugEnabled == true
    elseif DynamicZ.IsSandboxDebugEnabled and DynamicZ.IsSandboxDebugEnabled() then
        debugEnabled = true
    elseif SandboxVars and SandboxVars.DynamicZ and SandboxVars.DynamicZ.EnableDebugMode == true then
        debugEnabled = true
    elseif DynamicZ_Config and DynamicZ_Config.DebugMode == true then
        debugEnabled = true
    end

    if not debugEnabled then
        ClientState.targetStage = nil
        ClientState.targetDistance = nil
        return
    end

    -- Check player exists and is admin (for MP)
    local player = getPlayer and getPlayer() or nil
    if not player then
        ClientState.targetStage = nil
        ClientState.targetDistance = nil
        return
    end

    if isClient and isClient() then
        local isAdmin = false
        if player.isAdmin and player:isAdmin() then
            isAdmin = true
        elseif player.getAccessLevel then
            local access = string.lower(tostring(player:getAccessLevel() or ""))
            isAdmin = (access == "admin")
        end
        if not isAdmin then
            ClientState.targetStage = nil
            ClientState.targetDistance = nil
            return
        end
    end

    -- getNearestZombieStageInfo equivalent
    local cell = getCell and getCell() or nil
    if not cell or not instanceof then
        ClientState.targetStage = nil
        ClientState.targetDistance = nil
        return
    end

    local px = math.floor(tonumber(player:getX()) or 0)
    local py = math.floor(tonumber(player:getY()) or 0)
    local pz = math.floor(tonumber(player:getZ()) or 0)

    local radius = 20
    if DynamicZ_Config and DynamicZ_Config.DebugNearestZombieRadius then
        radius = tonumber(DynamicZ_Config.DebugNearestZombieRadius) or 20
    end
    radius = math.max(1, math.floor(radius))
    local radiusSq = radius * radius

    local bestStage = nil
    local bestDistSq = nil

    for x = px - radius, px + radius do
        for y = py - radius, py + radius do
            local dx = x - px
            local dy = y - py
            if (dx * dx + dy * dy) <= radiusSq then
                local square = cell:getGridSquare(x, y, pz)
                if square then
                    local objects = square:getMovingObjects()
                    if objects then
                        for i = 0, objects:size() - 1 do
                            local obj = objects:get(i)
                            if obj and instanceof(obj, "IsoZombie") then
                                local distX = (tonumber(obj:getX()) or 0) - px
                                local distY = (tonumber(obj:getY()) or 0) - py
                                local distSq = (distX * distX) + (distY * distY)
                                if bestDistSq == nil or distSq < bestDistSq then
                                    local md = obj:getModData()
                                    local dz = md and md.DZ or nil
                                    local stage = dz and tonumber(dz.evoStage) or nil
                                    if stage ~= nil then
                                        bestDistSq = distSq
                                        bestStage = stage
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    ClientState.targetStage = bestStage
    ClientState.targetDistance = bestDistSq and math.sqrt(bestDistSq) or nil

    -- Merge local state if no server state yet
    if not ClientState.hasServerState then
        local snapshot = {
            worldEvolution = 0.0,
            totalKills = 0,
            activeLeaders = 0,
            maxLeaders = 1,
        }

        local persisted = nil
        if ModData and ModData.getOrCreate then
            local ok, state = pcall(function()
                return ModData.getOrCreate("DynamicZ_Global")
            end)
            if ok and state then
                persisted = state
            end
        end

        if persisted then
            snapshot.worldEvolution = tonumber(persisted.worldEvolution) or 0.0
            snapshot.totalKills = math.floor(tonumber(persisted.totalKills) or 0)
            snapshot.activeLeaders = math.floor(tonumber(persisted.activeLeaders) or 0)
        elseif DynamicZ.Global then
            snapshot.worldEvolution = tonumber(DynamicZ.Global.worldEvolution) or 0.0
            snapshot.totalKills = math.floor(tonumber(DynamicZ.Global.totalKills) or 0)
            snapshot.activeLeaders = math.floor(tonumber(DynamicZ.Global.activeLeaders) or 0)
        end

        if DynamicZ.GetMaxLeaders then
            snapshot.maxLeaders = math.floor(tonumber(DynamicZ.GetMaxLeaders()) or 1)
        end

        -- Merge: keep existing state keys, overlay snapshot defaults
        local merged = snapshot
        if ClientState.state then
            for key, value in pairs(ClientState.state) do
                merged[key] = value
            end
        end
        ClientState.state = merged
    end

    -- Periodic status refresh (same logic as DZ: every ~3 game-seconds)
    local nowHours = 0
    if getGameTime then
        local gameTime = getGameTime()
        if gameTime and gameTime.getWorldAgeHours then
            nowHours = tonumber(gameTime:getWorldAgeHours()) or 0
        end
    end

    local refreshIntervalHours = 3.0 / 3600.0
    local nextRefresh = tonumber(ClientState.nextStatusRefreshHour) or 0
    if nowHours >= nextRefresh then
        -- Request updated state from server
        if sendClientCommand then
            sendClientCommand("DynamicZ", "Debug", { action = "status" })
        elseif DynamicZ.ExecuteDebugAction then
            DynamicZ.ExecuteDebugAction(player, "status", {})
        end
        ClientState.nextStatusRefreshHour = nowHours + refreshIntervalHours
    end
end

-- Register on OnTick (verified: LuaEventManager.java line 590)
if Events and Events.OnTick and Events.OnTick.Add then
    Events.OnTick.Add(tickUpdateNearestZombieCache)
    print("[DZChatCommands] Debug overlay fix: registered updateNearestZombieCache on OnTick (throttled to ~1s via getTimestampMs)")
end
