--[[
    DZChatCommands - Debug overlay fix for Dynamic Evolution Z

    Fixes three issues that prevent the debug HUD overlay from appearing
    on dedicated servers:

    1. DZ_DebugClient.lua registers updateNearestZombieCache on the
       "EveryOneSecond" event, but that event does NOT exist in PZ's
       LuaEventManager (only EveryOneMinute and EveryTenMinutes exist).
       The registration silently fails, so the overlay's nearest-zombie
       readout never updates. Fix: re-register on OnTick, throttled to
       ~1000 ms via getTimestampMs().

    2. DZ_Config.lua sets DebugOverlay = false by default (line 148).
       canShowOverlay() (DZ_DebugClient.lua:125) checks this BEFORE the
       debug-enabled check, so the overlay never draws even after the
       server enables debug mode. Fix: set DebugOverlay = true when the
       player is admin (the admin + debugEnabled checks in canUseDebugUI
       are sufficient gatekeeping).

    3. DZ_DebugClient.lua's onGameStart (line 894) checks
       isClientDebugEnabled() which returns false on join because the
       server hasn't sent state yet. It bails without requesting initial
       status, creating a chicken-and-egg: client never asks server,
       server only sends on EveryOneMinute heartbeat. Fix: on first tick
       when player is admin, send a status request to bootstrap the flow.

    API verification (all from LuaManager.GlobalObject, decompiled source):
      getTimestampMs()              -> line 7709, returns System.currentTimeMillis()
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
local initialStatusSent = false

local function isPlayerAdmin(player)
    if not player then return false end
    if player.isAdmin and player:isAdmin() then return true end
    if player.getAccessLevel then
        local access = string.lower(tostring(player:getAccessLevel() or ""))
        return access == "admin"
    end
    return false
end

-- Fix 2: Override DebugOverlay config so canShowOverlay() / drawOverlay() are
-- not blocked. The admin + debugEnabled checks in canUseDebugUI() are sufficient.
-- We set this unconditionally; canShowOverlay still requires debug enabled + admin.
if DynamicZ_Config then
    DynamicZ_Config.DebugOverlay = true
    print("[DZChatCommands] Debug overlay fix: set DynamicZ_Config.DebugOverlay = true")
end

local function tickUpdateNearestZombieCache()
    local nowMs = getTimestampMs()
    if (nowMs - lastUpdateMs) < INTERVAL_MS then
        return
    end
    lastUpdateMs = nowMs

    if not DynamicZ or not DynamicZ.DebugClient then
        return
    end

    -- Check debug enabled (same cascade as DZ_DebugClient.lua isClientDebugEnabled)
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

    -- Check player exists and is admin (for MP)
    local player = getPlayer and getPlayer() or nil
    if not player then
        ClientState.targetStage = nil
        ClientState.targetDistance = nil
        return
    end

    local playerIsAdmin = true
    if isClient and isClient() then
        playerIsAdmin = isPlayerAdmin(player)
        if not playerIsAdmin then
            ClientState.targetStage = nil
            ClientState.targetDistance = nil
            return
        end
    end

    -- Fix 3: On first tick when player is admin, request status from server
    -- to bootstrap the debug state flow. DZ's onGameStart bails because
    -- isClientDebugEnabled() is false before the server sends state.
    if not initialStatusSent and playerIsAdmin then
        initialStatusSent = true
        if sendClientCommand then
            sendClientCommand("DynamicZ", "Debug", { action = "status" })
            print("[DZChatCommands] Debug overlay fix: sent initial status request to server")
        end
    end

    if not debugEnabled then
        ClientState.targetStage = nil
        ClientState.targetDistance = nil
        return
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
