--[[
    DZChatCommands - Chat bridge for Dynamic Evolution Z debug commands
    Hooks ISChat to intercept /dz <subcommand> [args] and routes them
    through the existing DynamicZ.Debug* client API.
]]

if isServer() then return end

local ISChat = ISChat
local MOD_TAG = "[DZ]"

-- Fake message display (same pattern as VoteAdmin)
local function showMessage(message, color)
    if type(color) ~= "string" then
        color = "<RGB:255,200,50>"
    end

    message = color .. " " .. message

    local msg = {
        getText = function(_) return message end,
        getTextWithPrefix = function(_) return message end,
        isServerAlert = function(_) return false end,
        isShowAuthor = function(_) return false end,
        getAuthor = function(_) return "" end,
        setShouldAttractZombies = function(_) return false end,
        setOverHeadSpeech = function(_) return false end,
    }

    if not ISChat.instance then return end
    if not ISChat.instance.chatText then return end
    ISChat.addLineInChat(msg, 0)
end

local function showError(message)
    showMessage(MOD_TAG .. " " .. message, "<RGB:255,80,80>")
end

local function showInfo(message)
    showMessage(MOD_TAG .. " " .. message, "<RGB:200,200,200>")
end

-- Check if DynamicZ client API is available
local function hasDZ()
    return DynamicZ ~= nil and DynamicZ.DebugCommand ~= nil
end

-- Command handlers
local commands = {}

commands.help = function(args)
    showMessage(MOD_TAG .. " Commands:")
    showInfo("  /dz status              - Show world evolution status")
    showInfo("  /dz debug <on|off>      - Toggle debug mode (admin)")
    showInfo("  /dz inspect             - Inspect nearest zombie")
    showInfo("  /dz untrack             - Stop tracking zombie")
    showInfo("  /dz setevo <0.0-1.0>    - Set world evolution")
    showInfo("  /dz addkills <n>        - Add kills to global counter")
    showInfo("  /dz setstage <0-4>      - Set nearest zombie stage")
    showInfo("  /dz makeleader [type]   - Make nearest zombie a leader")
    showInfo("  /dz forcepulse          - Force all leaders to pulse")
    showInfo("  /dz reset               - Reset all DZ state")
    showInfo("  /dz forcesave           - Force save to backup file")
    showInfo("  /dz diag                - Show server diagnostics")
    showInfo("  /dz pressure            - Show activity pressure map")
    showInfo("  Leader types: HIVE, HUNTER, FRENZY, SHADOW, SPLIT")
end

commands.status = function(args)
    DynamicZ.DebugStatus()
end

commands.debug = function(args)
    local mode = args[1] or "toggle"
    DynamicZ.DebugSetMode(mode)
end

commands.inspect = function(args)
    DynamicZ.DebugInspect()
end

commands.untrack = function(args)
    DynamicZ.DebugUntrack()
end

commands.setevo = function(args)
    local value = tonumber(args[1])
    if value == nil then
        showError("Usage: /dz setevo <0.0-1.0 or 0-100>")
        return
    end
    DynamicZ.DebugSetEvo(value)
end

commands.addkills = function(args)
    local amount = tonumber(args[1])
    if amount == nil then
        showError("Usage: /dz addkills <amount>")
        return
    end
    DynamicZ.DebugAddKills(amount)
end

commands.setstage = function(args)
    local stage = tonumber(args[1])
    if stage == nil then
        showError("Usage: /dz setstage <0-4>")
        return
    end
    DynamicZ.DebugSetStage(stage)
end

commands.makeleader = function(args)
    local leaderType = args[1] or nil
    DynamicZ.DebugMakeLeader(leaderType)
end

commands.forcepulse = function(args)
    DynamicZ.DebugForcePulse()
end

commands.reset = function(args)
    DynamicZ.DebugReset()
end

commands.forcesave = function(args)
    showInfo("Sending force save request to server...")
    if sendClientCommand then
        sendClientCommand("DZChatCmds", "ForceSave", {})
    else
        showError("sendClientCommand not available.")
    end
end

commands.save = commands.forcesave

commands.diag = function(args)
    showInfo("Requesting server diagnostics...")
    if sendClientCommand then
        sendClientCommand("DZChatCmds", "Diagnostics", {})
    else
        showError("sendClientCommand not available.")
    end
end

commands.pressure = function(args)
    showInfo("Requesting pressure map from server...")
    if sendClientCommand then
        sendClientCommand("DZChatCmds", "Pressure", {})
    else
        showError("sendClientCommand not available.")
    end
end

-- Listen for DynamicZ server responses and show them in chat
local NET_MODULE = "DynamicZ"
local NET_INFO = "DebugInfo"
local NET_STATE = "DebugState"

-- Track last-seen values to suppress duplicate messages
local lastDebugEnabled = nil
local lastInfoMessage = nil
local lastInfoMs = 0
local INFO_DEDUP_WINDOW_MS = 60000 -- suppress identical DebugInfo for 60s

local function onServerCommand(module, command, args)
    if module ~= NET_MODULE then return end
    if not args then return end

    if command == NET_INFO and args.message then
        -- Deduplicate: only show if message changed or 60s elapsed
        local nowMs = getTimestampMs and getTimestampMs() or 0
        if args.message ~= lastInfoMessage or (nowMs - lastInfoMs) >= INFO_DEDUP_WINDOW_MS then
            showInfo(args.message)
            lastInfoMessage = args.message
            lastInfoMs = nowMs
        end
    end

    if command == NET_STATE then
        -- Only show debug mode message when it actually changes
        if args.debugEnabled ~= nil then
            local enabled = args.debugEnabled == true
            if lastDebugEnabled == nil or enabled ~= lastDebugEnabled then
                local label = enabled and "ENABLED" or "DISABLED"
                showInfo("Debug mode: " .. label)
                lastDebugEnabled = enabled
            end
        end
    end
end

if Events and Events.OnServerCommand and Events.OnServerCommand.Add then
    Events.OnServerCommand.Add(onServerCommand)
end

-- Hook ISChat command entry
local original_onCommandEntered = ISChat["onCommandEntered"]

ISChat["onCommandEntered"] = function(self)
    local commandText = ISChat.instance.textEntry:getText()

    if commandText and commandText ~= "" then
        local words = {}
        for word in commandText:gmatch("%S+") do
            words[#words + 1] = word
        end

        if #words >= 1 then
            local firstWord = string.lower(words[1])

            if firstWord == "/dz" then
                if not hasDZ() then
                    showError("Dynamic Evolution Z is not loaded.")
                    ISChat.instance.textEntry:setText("")
                    return
                end

                local subCommand = words[2] and string.lower(words[2]) or "help"
                local args = {}
                for i = 3, #words do
                    args[#args + 1] = words[i]
                end

                local handler = commands[subCommand]
                if handler then
                    handler(args)
                else
                    showError("Unknown subcommand: " .. subCommand)
                    showInfo("Type /dz help for available commands.")
                end

                ISChat.instance.textEntry:setText("")
                return
            end
        end
    end

    original_onCommandEntered(self)
end

print("[DZChatCommands] Chat hook installed - type /dz help in chat")
