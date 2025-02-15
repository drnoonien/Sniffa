local addonName, ns = ...

---@class OffsetData
---@field event string
---@field spell number
---@field count number

---@class NoteEntry
---@field player string
---@field spell number
---@field time number
---@field offset? OffsetData

---@class ResultRow
---@field hit boolean
---@field player string
---@field spell number
---@field time string
---@field drift? number

---@class DeathData
---@field player string
---@field time string
---@field ress? boolean

---@alias PlayerName string
---@alias SpellId number
---@alias SpellName string
---@alias Time number
---@alias EventAndSpellKey string
---@alias PlayerNameAndSpellKey string

---@class Capture
---@field captureEvents boolean
---@field playersInEncounter table<PlayerName, boolean>
---@field playerUnitIdCache table<UnitId, PlayerName>
---@field deadPlayers table<PlayerName, boolean>
---@field deathEvents DeathData[]
---@field startTime? number
---@field endTime? number
---@field startDateTime? string | osdate
---@field untrackedPlayerSpells table<SpellId, SpellName>
---@field trackedPlayerSpells table<SpellName, SpellId>
---@field playerEvents table<PlayerNameAndSpellKey, Time[]>
---@field enemyEvents table<EventAndSpellKey, Time[]>

---@class NoteMeta
---@field players table<PlayerName, boolean>
---@field spells table<SpellId, boolean>
---@field spellNames table<SpellName, SpellId>

---@class Note
---@field data NoteEntry[]
---@field meta NoteMeta

---@class ns.parser
---@field note Note
---@field capture Capture
---@field ResetState? function
---@field ParseNote? function
---@field ExpandEventName? function
---@field MapIncorrectPlayerSpellsFromNote? function
---@field ProcessEncounterResult? function

------------------------------------------------------------------------------------------

-- EasyMenu is apparently removed from the game, stole this shim from
-- the wow-dev discord.

local function EasyMenu_Initialize(frame, level, menuList)
    for index = 1, #menuList do
        local value = menuList[index]
        if (value.text) then
            value.index = index;
            UIDropDownMenu_AddButton(value, level);
        end
    end
end

local function EasyMenu(menuList, menuFrame, anchor, x, y, displayMode, autoHideDelay)
    if (displayMode == "MENU") then
        menuFrame.displayMode = displayMode;
    end
    UIDropDownMenu_Initialize(menuFrame, EasyMenu_Initialize, displayMode, nil, menuList);
    ToggleDropDownMenu(1, nil, menuFrame, anchor, x, y, menuList, nil, autoHideDelay);
end

------------------------------------------------------------------------------------------

local LDB = LibStub("LibDataBroker-1.1")
local LDBIcon = LibStub("LibDBIcon-1.0")
local AceGUI = LibStub("AceGUI-3.0")

ns.util = {}
ns.gui = {}

---@type Note
local parserNoteDefaults = {
    data = {},
    meta = {
        players = {},
        spells = {},
        spellNames = {},
    }
}
---@type Capture
local parserCaptureDefaults = {
    captureEvents = false,

    playersInEncounter = {},
    playerUnitIdCache = {},
    deadPlayers = {},
    deathEvents = {},

    startTime = nil,
    endTime = nil,
    startDateTime = nil,

    untrackedPlayerSpells = {},
    trackedPlayerSpells = {},

    playerEvents = {},
    enemyEvents = {},
}

---@type ns.parser
ns.parser = {
    note = parserNoteDefaults,
    capture = parserCaptureDefaults
}

local ENABLED_ENCOUNTERS = {
    [2086] = "Rezan",     -- Debug
    [2820] = "Gnarlroot", -- Debug

    [2902] = "Ulgrax",
    [2917] = "Horror",
    [2898] = "Sikran",
    [2918] = "Rasha",
    [2919] = "Brood",
    [2920] = "Princess",
    [2921] = "Silken",
    [2922] = "Ansu",
}

ns.EventFrame = CreateFrame("Frame")
ns.EventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
ns.EventFrame:RegisterEvent("ENCOUNTER_START")
ns.EventFrame:RegisterEvent("ENCOUNTER_END")
ns.EventFrame:RegisterEvent("ADDON_LOADED")
ns.EventFrame:RegisterEvent("UNIT_FLAGS")

ns.EventFrame:SetScript("OnEvent", function(self, event, ...)
    self[event](self, event, ...)
end)

function ns.EventFrame:ADDON_LOADED(_, addon)
    if (addon ~= addonName) then
        return
    else
        self:UnregisterEvent("ADDON_LOADED")
    end

    SniffaDB = SniffaDB or {
        history = {},
        options = {}
    }

    ns.RegisterAddonOptions()
    ns.RegisterSlashCommands()
    ns.RegisterMinimapButton()
end

function ns.EventFrame:ENCOUNTER_START(_, ...)
    local encounterID, encounterName, difficultyID, groupSize = ...

    if (not ENABLED_ENCOUNTERS[encounterID]) then
        return
    end

    ns.parser.ResetState()

    for i = 1, MAX_RAID_MEMBERS do
        local name, _, _, _, _, _, _, _, _, _, _ = GetRaidRosterInfo(i)

        if name then
            local realmLessName = ns.util.TrimRealmName(name)
            ns.parser.capture.playersInEncounter[realmLessName] = true

            -- Wiki says: Do not make any assumptions about raidid
            -- (raid1, raid2, etc) to name mappings remaining the same
            -- or not. When the raid changes, people MAY retain it or
            -- not, depending on raid size and WoW patch. Yes, this
            -- behavior has changed with patches in the past and may
            -- do it again.
            --
            -- https://warcraft.wiki.gg/wiki/API_GetRaidRosterInfo
            --
            -- We're going to assume this isn't applicable to
            -- ENCOUNTER_START since nobody should be moving around
            -- once the encounter has begun.
            ns.parser.capture.playerUnitIdCache["raid" .. i] = realmLessName
        end
    end

    ns.parser.ParseNote()

    if (#ns.parser.note.data <= 0) then
        return
    end

    ns.parser.capture.captureEvents = true
    ns.parser.capture.startTime = GetTime()
    ns.parser.capture.startDateTime = date("%Y-%m-%d %H:%M:%S")
end

function ns.EventFrame:ENCOUNTER_END(_, ...)
    if (not ns.parser.capture.captureEvents) then
        return
    end

    local encounterID, encounterName, difficultyID, groupSize, success = ...

    ns.parser.capture.captureEvents = false
    ns.parser.capture.endTime = GetTime()

    local duration = ns.parser.capture.endTime - ns.parser.capture.startTime

    if (duration < SniffaDB.options.minimumEncounterLenght) then
        ns.util.PrintInfo("Encounter too short, no data will be stored")
        return
    end

    local encounterResult = ns.parser.ProcessEncounterResult()

    local deathData = {}

    for _, value in ipairs(ns.parser.capture.deathEvents) do
        tinsert(deathData, {
            player = value.player,
            time = ns.util.FormatSecondsAsTimestamp(value.time - ns.parser.capture.startTime),
            ress = value.ress
        })
    end

    SniffaDB.history[ns.parser.capture.startDateTime] = {
        meta = {
            encounterID = encounterID,
            encounterName = encounterName,
            difficultyID = difficultyID,
            groupSize = groupSize,
            success = success,
            duration = ns.parser.capture.endTime - ns.parser.capture.startTime
        },
        data = encounterResult,
        deathData = deathData
    }

    if (SniffaDB.options.showCaptureDebug) then
        for untrackedSpellId, untrackedSpellName in pairs(ns.parser.capture.untrackedPlayerSpells) do
            local similarSpellWasCast = ns.parser.capture.trackedPlayerSpells[untrackedSpellName]
            local similarNamedSpellIsInNote = ns.parser.note.meta.spellNames[untrackedSpellName]

            if (similarNamedSpellIsInNote and not similarSpellWasCast) then
                ns.util.PrintError(
                    string.format(
                        "Captured a spell whose name but not ID matches a note assignment, contact the developer and ask them to map the spell, name: %s, cast ID: %s, note ID: %s",
                        untrackedSpellName,
                        untrackedSpellId,
                        similarNamedSpellIsInNote
                    )
                )
            end
        end
    end

    ns.util.VDTLog(ns.parser, "ENCOUNTER_END")

    ns.gui.TryShowMainGUIAfterEncounter(encounterResult)
end

function ns.EventFrame:UNIT_FLAGS(_, unitId)
    if (not ns.parser.capture.captureEvents) then
        return
    end

    local playerName = ns.parser.capture.playerUnitIdCache[unitId]

    if (not playerName or not ns.parser.capture.deadPlayers[playerName]) then
        return
    end

    if (UnitIsDeadOrGhost(unitId)) then
        return
    end

    tinsert(ns.parser.capture.deathEvents, {
        player = playerName,
        time = GetTime(),
        ress = true
    })

    ns.parser.capture.deadPlayers[playerName] = nil
end

function ns.EventFrame:COMBAT_LOG_EVENT_UNFILTERED()
    if (not ns.parser.capture.captureEvents) then
        return
    end

    local eventArgs = { CombatLogGetCurrentEventInfo() }

    local subEvent = eventArgs[2]
    local sourceName = eventArgs[5]
    local sourceUnitFlags = eventArgs[6]
    local destUnitFlags = eventArgs[10]
    local destName = eventArgs[9]

    local hostileSourceUnit = bit.band(sourceUnitFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0
    local hostileDestUnit = bit.band(destUnitFlags, COMBATLOG_OBJECT_REACTION_HOSTILE) > 0

    if (not hostileSourceUnit and sourceName) then
        sourceName = ns.util.TrimRealmName(sourceName)
    end
    if (not hostileDestUnit and destName) then
        destName = ns.util.TrimRealmName(destName)
    end

    --------------------------------------------------------------------------------------

    if (not hostileDestUnit and subEvent == "UNIT_DIED") then
        ns.util.VDTLog({ hostileDestUnit, subEvent, destName }, "UNIT_DIED")

        if (ns.parser.capture.deadPlayers[destName]
                or not ns.parser.capture.playersInEncounter[destName]
                or not ns.parser.note.meta.players[destName]) then
            return
        end

        ns.parser.capture.deadPlayers[destName] = true
        tinsert(ns.parser.capture.deathEvents, {
            player = destName,
            time = GetTime()
        })
    end

    --------------------------------------------------------------------------------------

    if (subEvent ~= "SPELL_CAST_START" and
            subEvent ~= "SPELL_CAST_SUCCESS" and
            subEvent ~= "SPELL_AURA_APPLIED" and
            subEvent ~= "SPELL_AURA_REMOVED") then
        return
    end

    local spell = eventArgs[12]

    -- Spirit of Redemption
    if (not hostileSourceUnit and subEvent == "SPELL_AURA_APPLIED" and spell == 27827) then
        if (ns.parser.capture.deadPlayers[sourceName]
                or not ns.parser.capture.playersInEncounter[sourceName]
                or not ns.parser.note.meta.players[sourceName]) then
            return
        end

        ns.parser.capture.deadPlayers[sourceName] = true
        tinsert(ns.parser.capture.deathEvents, {
            player = sourceName,
            time = GetTime()
        })
    end

    -- Record all friendly spells that weren't in the note, this is
    -- for diagnostics purposes to find unmapped spells
    if (ns.parser.note.meta.players[sourceName] and not ns.parser.note.meta.spells[spell]) then
        if (not ns.parser.capture.untrackedPlayerSpells[spell]) then
            local spellInfo = C_Spell.GetSpellInfo(spell)
            local spellName = spellInfo.name
            ns.parser.capture.untrackedPlayerSpells[spell] = spellName
        end

        return
    end

    -- Only collect spells we collected from the note, these are the
    -- only ones that will be relevant to calculating offsets later
    if (hostileSourceUnit and not ns.parser.note.meta.spells[spell]) then
        local key = subEvent .. ":" .. spell

        if (ns.parser.capture.enemyEvents[key]) then
            tinsert(ns.parser.capture.enemyEvents[key], GetTime())
        else
            ns.parser.capture.enemyEvents[key] = { GetTime() }
        end
    end

    if (not hostileSourceUnit) then
        if (subEvent ~= "SPELL_CAST_SUCCESS") then
            return
        end

        -- Player not in the note, we don't care about you
        if (not ns.parser.note.meta.players[sourceName]) then
            return
        end

        local spellInfo = C_Spell.GetSpellInfo(spell)
        ns.parser.capture.trackedPlayerSpells[spellInfo.name] = spell

        local key = sourceName .. ":" .. spell

        if (ns.parser.capture.playerEvents[key]) then
            tinsert(ns.parser.capture.playerEvents[key], GetTime())
        else
            ns.parser.capture.playerEvents[key] = { GetTime() }
        end
    end
end

function ns.RegisterSlashCommands()
    SLASH_SNIFFA1 = "/sniff"
    SLASH_SNIFFA2 = "/sniffa"

    local COMMAND_MAP = {
        ["help"] = function()
            ns.util.PrintInfo("Available commands:")
            print("/sniff - Opens the Sniffa GUI.")
            print("/sniff help - Displays this help information.")
            print("/sniff config - Opens config.")
            print("/sniff note (debug only) - Parses the current note and logs the data to ViragDevTool")
        end,
        ["config"] = function()
            Settings.OpenToCategory(ns.AceOptionsFrame.name)
        end,
        ["note"] = function()
            ns.parser.ResetState()
            ns.parser.ParseNote()

            ns.util.VDTLog({ ns.parser }, "Note dump")
        end
    }

    SlashCmdList.SNIFFA = function(msg)
        local command, value, rest = msg:match("^(%S*)%s*(%S*)%s*(.-)$")

        local maybeCommand = COMMAND_MAP[command]

        if (maybeCommand) then
            maybeCommand()
            return
        end

        ns.gui:ShowMainGUI()
    end
end

function ns.RegisterAddonOptions()
    local defaultOptions = {
        autoShowAfterEncounter = "if_my_missed_assignments",
        showCaptureDebug = false,
        minimumEncounterLenght = 7,
        enableDebugLogging = false,
    }

    for key, defaultValue in pairs(defaultOptions) do
        if (not SniffaDB.options) then
            SniffaDB.options = {}
        end

        if (SniffaDB.options[key] == nil) then
            SniffaDB.options[key] = defaultValue
        end
    end

    local options = {
        name = addonName,
        type = "group",
        args = {
            clearAllData = {
                type = "execute",
                name = "Clear all data",
                order = 1,
                func = function()
                    SniffaDB.history = {}
                    ns.util.PrintInfo("Cleared data.")
                end,
            },
            emptyRow1 = {
                width = "full",
                type = "description",
                name = " ",
                order = 2,
            },
            emptyRow2 = {
                width = "full",
                type = "description",
                name = " ",
                order = 3,
            },
            autoShowAfterEncounter = {
                width = 1.2,
                type = "select",
                name = "Automatically show after encounter",
                desc = "Decides how the UI should behave when a tracked encounter ends",
                order = 4,
                values = {
                    always = "Always",
                    if_any_missed_assignments = "If there are any missed assignments",
                    if_my_missed_assignments = "If I have missed assignments",
                    never = "Never",
                },
                set = function(_, val)
                    SniffaDB.options.autoShowAfterEncounter = val
                end,
                get = function(_)
                    return SniffaDB.options.autoShowAfterEncounter
                end,
            },
            emptyRow3 = {
                width = "full",
                type = "description",
                name = " ",
                order = 5,
            },
            showCaptureDebug = {
                type = "toggle",
                name = "Show capture mismatch info",
                desc = "Prints a warning to chat after combat if a note-id missmatch was detected",
                order = 6,
                set = function(_, val)
                    SniffaDB.options.showCaptureDebug = val
                end,
                get = function(_)
                    return SniffaDB.options.showCaptureDebug
                end
            },
            emptyRow4 = {
                width = "full",
                type = "description",
                name = " ",
                order = 7,
            },
            minimumEncounterLenght = {
                order = 8,
                type = "range",
                name = "Minimum encounter length",
                desc = "Pulls shorter than this many seconds will not be saved",
                min = 3,
                max = 120,
                step = 1,
                set = function(_, value)
                    SniffaDB.options.minimumEncounterLenght = value
                end,
                get = function(_)
                    return SniffaDB.options.minimumEncounterLenght
                end
            },
            emptyRow5 = {
                width = "full",
                type = "description",
                name = " ",
                order = 9,
            },
            hideMinimapButton = {
                type = "toggle",
                name = "Hide minimap button",
                order = 10,
                set = function(_, val)
                    SniffaLDBIconDB.hide = val
                    if (val) then
                        LDBIcon:Hide(addonName)
                    else
                        LDBIcon:Show(addonName)
                    end
                end,
                get = function(_)
                    return SniffaLDBIconDB.hide
                end
            },
            emptyRow6 = {
                width = "full",
                type = "description",
                name = " ",
                order = 11,
            },
            enableDebugLogging = {
                type = "toggle",
                name = "Enable debug logging (VDT)",
                order = 12,
                set = function(_, val)
                    SniffaDB.options.enableDebugLogging = val
                end,
                get = function(_)
                    return SniffaDB.options.enableDebugLogging
                end
            },

        }
    }

    LibStub("AceConfig-3.0"):RegisterOptionsTable(addonName, options)
    ns.AceOptionsFrame = LibStub("AceConfigDialog-3.0"):AddToBlizOptions(addonName, addonName)
end

function ns.RegisterMinimapButton()
    local dataObj = LDB:NewDataObject("Sniffa", {
        type = "launcher",
        text = addonName,
        icon = "Interface\\AddOns\\" .. addonName .. "\\Assets\\sniffa_icon.tga",
        OnClick = function(_, button)
            if button == "LeftButton" then
                ns.gui.ShowMainGUI()
            elseif button == "RightButton" then
                Settings.OpenToCategory(ns.AceOptionsFrame.name)
            end
        end,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine(addonName)
            tooltip:AddLine("Left-click to open")
            tooltip:AddLine("Right-click for options")
        end,
    })

    if not SniffaLDBIconDB then SniffaLDBIconDB = {} end
    LDBIcon:Register(addonName, dataObj, SniffaLDBIconDB)
end

function ns.util.VDTLog(payload, label)
    if (not SniffaDB.options.enableDebugLogging) then
        return
    end

    if (VDT and type(VDT) == "table") then
        VDT:Add(payload, string.format("%s — %s", addonName, label or "[Unnamed log entry]"))
    end
end

function ns.util.DeepCopy(object)
    local lookup_table = {}
    local function _copy(obj)
        if type(obj) ~= "table" then
            return obj
        elseif lookup_table[obj] then
            return lookup_table[obj]
        end

        local new_table = {}
        lookup_table[obj] = new_table

        for key, value in pairs(obj) do
            new_table[_copy(key)] = _copy(value)
        end

        return setmetatable(new_table, getmetatable(obj))
    end

    return _copy(object)
end

function ns.util.TrimRealmName(name)
    return name:match("^[^-]+")
end

function ns.util.SortTableByKeysDescending(inputTable)
    local sorted = {}

    -- First get all keys
    local keys = {}
    for key in pairs(inputTable) do
        table.insert(keys, key)
    end

    -- Sort keys descending
    table.sort(keys, function(a, b) return a > b end)

    -- Create new array with key-value pairs
    for _, key in ipairs(keys) do
        table.insert(sorted, {
            key = key,
            value = inputTable[key]
        })
    end

    return sorted
end

function ns.util.SetRelativeColumnWidths(container, left, right, leftWidth)
    left:SetWidth(container.frame:GetWidth() * leftWidth)
    right:SetWidth(container.frame:GetWidth() * (1 - leftWidth))
end

--- @param colorName "red"|"yellow"|"green"|"softgreen"|"blue"|"default"
function ns.util.SetTextColor(text, colorName)
    local colorCodes = {
        red = "|cFFFF3333",
        yellow = "|cFFFFFF00",
        green = "|cFF00FF00",
        softgreen = "|cFF49d849",
        blue = "|cFF87CEEB",
        default = "|cFFFFFFFF" -- Default to white
    }

    local colorCode = colorCodes[colorName] or colorCodes.default
    return colorCode .. text .. "|r"
end

function ns.util.PrintError(message)
    local msg = string.format(
        "%s %s — %s",
        ns.util.SetTextColor("[ERROR]", "red"),
        addonName,
        message
    )

    print(msg)
end

function ns.util.PrintWarn(message)
    local msg = string.format(
        "%s %s — %s",
        ns.util.SetTextColor("[WARN]", "yellow"),
        addonName,
        message
    )

    print(msg)
end

function ns.util.PrintInfo(message)
    local msg = string.format(
        "%s — %s",
        addonName,
        message
    )

    print(msg)
end

function ns.util.SplitDelimiter(message, delim)
    local result = {}

    if (message == "") then
        return result
    end

    for hit in (message .. delim):gmatch("(.-)" .. delim) do
        table.insert(result, hit:match("^%s*(.-)%s*$"))
    end

    return result
end

function ns.util.FormatSecondsAsTimestamp(seconds)
    local minutes = math.floor(seconds / 60)
    local secs = math.floor(seconds % 60)
    local millis = math.floor((seconds - math.floor(seconds)) * 1000)
    return string.format("%02d:%02d.%03d", minutes, secs, millis)
end

---@param result ResultRow[]
function ns.gui.TryShowMainGUIAfterEncounter(result)
    if (SniffaDB.options.autoShowAfterEncounter == "always") then
        ns.gui.ShowMainGUI()
        return
    end

    if (SniffaDB.options.autoShowAfterEncounter == "if_any_missed_assignments") then
        for _, k in pairs(result) do
            if (not k.hit) then
                ns.gui.ShowMainGUI()
                return
            end
        end
    end

    if (SniffaDB.options.autoShowAfterEncounter == "if_my_missed_assignments") then
        for _, k in pairs(result) do
            if (k.player == UnitName("player") and not k.hit) then
                ns.gui.ShowMainGUI()
                return
            end
        end
    end
end

function ns.gui.ShowMainGUI()
    if (ns.gui.MainGUI) then
        ns.gui.MainGUI:Hide()
        ns.gui.MainGUI = nil
        return
    end

    local state = {
        selectedPull = nil
    }

    local window = AceGUI:Create("Frame")
    ns.gui.MainGUI = window

    _G["SniffaAddon77GlobalWindowHandle"] = window.frame
    table.insert(UISpecialFrames, "SniffaAddon77GlobalWindowHandle")

    window:SetTitle(addonName)
    window:SetWidth(600)
    window:SetHeight(500)
    window:EnableResize(false)
    window:SetLayout("fill")

    local version = C_AddOns.GetAddOnMetadata(addonName, "Version")
    window:SetStatusText(string.format(" v%s", version))

    window:SetCallback("OnClose", function(widget)
        AceGUI:Release(widget)
        ns.gui.MainGUI = nil
    end)

    --------------------------------------------------------------------------------------

    local container = AceGUI:Create("SimpleGroup")
    container:SetFullWidth(true)
    container:SetFullHeight(true)
    container:SetLayout("Flow")
    window:AddChild(container)

    --------------------------------------------------------------------------------------

    local historySorted = ns.util.SortTableByKeysDescending(SniffaDB.history)

    local left = AceGUI:Create("InlineGroup")
    left:SetTitle(string.format("Pulls (%d)", #historySorted))
    left:SetLayout("Fill")
    left:SetFullHeight(true)

    local innerLeft = AceGUI:Create("ScrollFrame")
    left:AddChild(innerLeft)

    local right = AceGUI:Create("InlineGroup")
    right:SetTitle("Details")
    right:SetLayout("Fill")
    right:SetFullHeight(true)

    local innerRight = AceGUI:Create("ScrollFrame")
    right:AddChild(innerRight)

    --------------------------------------------------------------------------------------

    for index, entry in ipairs(historySorted) do
        ---@class EncounterData
        local entryValue = entry.value

        local label = AceGUI:Create("InteractiveLabel")
        label:SetText(entry.key)
        label:SetFontObject(GameFontNormal)
        label:SetCallback("OnClick", function(_, _, btn)
            if (state.selectedPullLabel) then
                state.selectedPullLabel:SetColor(1, 1, 1)
            end

            label:SetColor(0, 1, 0)
            state.selectedPullLabel = label

            ns.gui.SetDetails(innerRight, entryValue)

            if btn == "RightButton" then
                local menu = {
                    {
                        text = "Delete row",
                        func = function()
                            SniffaDB.history[entry.key] = nil

                            -- Sue me, I don't know how to redraw this
                            -- shit in Ace
                            ns.gui.MainGUI:Hide()
                            ns.gui.ShowMainGUI()
                        end,
                    },
                    {
                        text = "Delete all rows on this date",
                        func = function()
                            for key in pairs(SniffaDB.history) do
                                local targetDate = entry.key:match("^(%d%d%d%d%-%d%d%-%d%d)")

                                local entryDate = key:match("^(%d%d%d%d%-%d%d%-%d%d)")
                                if entryDate == targetDate then
                                    SniffaDB.history[key] = nil
                                end
                            end

                            -- Sue me, I don't know how to redraw this
                            -- shit in Ace
                            ns.gui.MainGUI:Hide()
                            ns.gui.ShowMainGUI()
                        end,
                    }
                }

                -- Show the menu at the cursor location.
                local contextMenuFrame = CreateFrame("Frame", "ContextMenuFrame", UIParent, "UIDropDownMenuTemplate")
                EasyMenu(menu, contextMenuFrame, "cursor", 0, 0, "MENU")
            end
        end)

        if (index == 1) then
            label:SetColor(0, 1, 0)
            state.selectedPullLabel = label
            ns.gui.SetDetails(innerRight, entryValue)
        end

        innerLeft:AddChild(label)
    end

    ns.util.SetRelativeColumnWidths(container, left, right, 0.3)

    container:AddChild(left)
    container:AddChild(right)
end

function ns.gui.SetDetails(frame, value)
    frame:ReleaseChildren()

    local information = AceGUI:Create("Label")
    information:SetFullWidth(true)
    information:SetText(string.format("%s", value.meta.encounterName))
    information:SetFontObject(GameFontNormal)
    frame:AddChild(information)

    local spacer = AceGUI:Create("Label")
    spacer:SetText(" ")
    spacer:SetFullWidth(true)
    frame:AddChild(spacer)

    local labels = {}

    --------------------------------------------------------------------------------------

    local playerHighlightTexture = "|A:characterupdate_arrow-bullet-point:12:12:0:-1.5|a"

    for _, entry in ipairs(value.deathData) do
        local label = AceGUI:Create("Label")
        label:SetFullWidth(true)

        local text = string.format("%s - [%s] %s", entry.time, entry.ress and "Ress" or "Death", entry.player)

        if (entry.ress) then
            text = ns.util.SetTextColor(text, "softgreen")
        else
            text = ns.util.SetTextColor(text, "blue")
        end

        if (entry.player == UnitName("player")) then
            text = playerHighlightTexture .. " " .. text
        end

        label:SetText(text)
        label:SetFontObject(GameFontNormal)

        label:SetUserData("sortTime", entry.time)

        local ressIcon  = 135955
        local skullIcon = 133730

        label:SetImage(entry.ress and ressIcon or skullIcon)
        label:SetImageSize(16, 16)

        -- Zoom the icon in a bit to hide borders
        local texture = label.image
        local zoomFactor = 0.12
        local left = zoomFactor / 2
        local right = 1 - (zoomFactor / 2)
        local top = zoomFactor / 2
        local bottom = 1 - (zoomFactor / 2)
        texture:SetTexCoord(left, right, top, bottom)

        tinsert(labels, label)
    end

    --------------------------------------------------------------------------------------

    for _, v in ipairs(value.data) do
        local label = AceGUI:Create("Label")
        label:SetFullWidth(true)

        local spellInfo = C_Spell.GetSpellInfo(v.spell)
        local spellName = spellInfo.name

        local text = ""

        if (v.hit) then
            if (v.drift > 0) then
                text = string.format("%s - %s - %s (+%.2f)", v.time, spellName, v.player, v.drift)
            else
                text = string.format("%s - %s - %s (%.2f)", v.time, spellName, v.player, v.drift)
            end
        else
            text = string.format("%s - %s - %s", v.time, spellName, v.player)
        end

        if (v.player == UnitName("player")) then
            text = playerHighlightTexture .. " " .. text
        end

        if (not v.hit) then
            text = ns.util.SetTextColor(text, "red")
        elseif (v.drift > 5) then
            text = ns.util.SetTextColor(text, "yellow")
        end

        label:SetText(text)
        label:SetFontObject(GameFontNormal)

        label:SetUserData("sortTime", v.time)

        label:SetImage(spellInfo.originalIconID)
        label:SetImageSize(16, 16)

        -- Zoom the icon in a bit to hide borders
        local texture = label.image
        local zoomFactor = 0.12
        local left = zoomFactor / 2
        local right = 1 - (zoomFactor / 2)
        local top = zoomFactor / 2
        local bottom = 1 - (zoomFactor / 2)
        texture:SetTexCoord(left, right, top, bottom)

        tinsert(labels, label)
    end

    --------------------------------------------------------------------------------------

    table.sort(labels, function(a, b)
        return a:GetUserData("sortTime") < b:GetUserData("sortTime")
    end)

    for _, label in ipairs(labels) do
        frame:AddChild(label)
    end
end

function ns.parser.ExpandEventName(eventName)
    local events = {
        ["SCC"] = "SPELL_CAST_SUCCESS",
        ["SCS"] = "SPELL_CAST_START",
        ["SAA"] = "SPELL_AURA_APPLIED",
        ["SAR"] = "SPELL_AURA_REMOVED"
    }

    return events[eventName]
end

function ns.parser.MapIncorrectPlayerSpellsFromNote(spell)
    -- map<note-id, actual-cast-id>
    local map = {
        -- Evoker
        [370984] = 370960, -- Emerald Communion
        [367226] = 367230, -- Spiritbloom
        [355936] = 382614, -- Dream Breath

        -- Paladin
        [304971] = 375576, -- Divine Toll

        -- Druid
        [77764] = 106898, -- Stampeding Roar

        -- DK
        [315443] = 383269, -- Abom. limb

        -- Hunter
        [281195] = 264735, -- SoTF
        [388035] = 272679, -- FotB
    }

    if (map[spell]) then
        return map[spell]
    end

    return spell
end

function ns.parser.ResetState()
    ns.parser.note = ns.util.DeepCopy(parserNoteDefaults)
    ns.parser.capture = ns.util.DeepCopy(parserCaptureDefaults)
end

function ns.parser.ParseNote()
    if (not _G.VMRT) then
        ns.util.PrintError("Method Raid Tools not installed and/or enabled")
        return
    end

    -- _G.VMRT.Note.SelfText if you want to include personal note
    local note = _G.VMRT.Note.Text1

    local isInsideCollectBlock = false
    local collectEverything = true

    local sniffStartKeyword = "sniffstart"
    local sniffEndKeyword = "sniffend"

    local startKeywordFound = note:match(sniffStartKeyword)
    local endKeywordFound = note:match(sniffEndKeyword)

    if (startKeywordFound and not endKeywordFound) or
        (not startKeywordFound and endKeywordFound) then
        ns.util.PrintWarn("Only found one of two required keywords, the entire note will be used")
    end

    if (startKeywordFound and endKeywordFound) then
        collectEverything = false
    end

    for line in note:gmatch("[^\r\n]+") do
        local function ContinueWrapper()
            if (line:find(sniffStartKeyword)) then
                isInsideCollectBlock = true
                return
            end

            if (line:find(sniffEndKeyword)) then
                isInsideCollectBlock = false
                return
            end

            if (not isInsideCollectBlock and not collectEverything) then
                return
            end

            -- Both of these are expected to be present for the line
            -- to be valid
            if (not line:find("{spell:") and not line:find("{time:")) then
                return
            end

            local minute, sec, options = line:match("{time:(%d+)[:%.]?(%d*),?([^{}]*)}")
            local assignemntsPart = line:match(".*%s%-%s(.*)")

            local PLAYER_DELIMITER = "  "
            local playerBlocks = ns.util.SplitDelimiter(assignemntsPart, PLAYER_DELIMITER)

            for _, block in pairs(playerBlocks) do
                -- Cleans up "player1 @player2" assignments
                block = block:gsub("@%S+", "")

                local playerPart = block:match("^(%S*)%s+")
                local spellPart = block:match("{spell:(%d+)}")
                local spell = tonumber(spellPart)

                local captureEntry = (
                    (IsInGroup() and ns.parser.capture.playersInEncounter[playerPart]) or
                    (not IsInGroup())
                )

                if (captureEntry) then
                    local playerSpell = ns.parser.MapIncorrectPlayerSpellsFromNote(spell)
                    local spellInfo = C_Spell.GetSpellInfo(playerSpell)

                    ns.parser.note.meta.players[playerPart] = true
                    ns.parser.note.meta.spells[playerSpell] = true
                    ns.parser.note.meta.spellNames[spellInfo.name] = spell

                    local playerEntry = {
                        player = playerPart,
                        spell = playerSpell,
                        time = (minute * 60) + sec
                    }

                    if (options ~= "") then
                        local event, offsetSpell, count = options:match("(%a+):(%d+):(%d+)")

                        ns.parser.note.meta.spells[offsetSpell] = true

                        playerEntry.offset = {
                            event = ns.parser.ExpandEventName(event),
                            spell = offsetSpell,
                            count = count
                        }
                    end

                    tinsert(ns.parser.note.data, playerEntry)
                end
            end
        end

        ContinueWrapper()
    end
end

function ns.parser.ProcessEncounterResult()
    ---@type ResultRow[]
    local result = {}

    for _, assignment in ipairs(ns.parser.note.data) do
        local function ContinueWrapper()
            local startTime = ns.parser.capture.startTime
            local assignmentTime = assignment.time

            --[[
				When there's an offset present, the following changes
				happen:

				- starTime should be moved up to when the offset event
				happened, this means we will treat the fight as having
				started when that event ocurred, ignoring everything
				that came before

				- assignmentTime is going to be relative to the offset
				event, meaning we need to add all the time that came
				before to get an absolute timestamp to use for reporting
			]]
            if (assignment.offset) then
                local enemyKey = assignment.offset.event .. ":" .. assignment.offset.spell

                if (not ns.parser.capture.enemyEvents[enemyKey]) then
                    return
                end

                local enemyEventTime = ns.parser.capture.enemyEvents[enemyKey][assignment.offset.count]

                if (not enemyEventTime) then
                    return
                end

                -- Shift up the start-time to when the tracked event happened
                startTime = enemyEventTime
                -- Assignment times are relative to the offset, need
                -- to add elapsed duration for an absolute value
                assignmentTime = assignmentTime + (enemyEventTime - ns.parser.capture.startTime)
            end

            local duration = ns.parser.capture.endTime - startTime
            local THRESHOLD_WINDOW = 10

            -- No point checking any assignments whose time is further
            -- up in the fight than we reached
            if (assignment.time > (duration + THRESHOLD_WINDOW)) then
                return
            end

            ---@type ResultRow
            local resultRow = {
                hit = false,
                player = assignment.player,
                spell = assignment.spell,
                time = ns.util.FormatSecondsAsTimestamp(assignmentTime)
            }

            local playerKey = assignment.player .. ":" .. assignment.spell
            local playerCasts = ns.parser.capture.playerEvents[playerKey] or {}

            for _, absoluteCastTime in ipairs(playerCasts) do
                local relativeCastTime = absoluteCastTime - startTime

                if (math.abs(assignment.time - relativeCastTime) <= THRESHOLD_WINDOW) then
                    resultRow.hit = true
                    resultRow.time = ns.util.FormatSecondsAsTimestamp(absoluteCastTime - ns.parser.capture.startTime)
                    resultRow.drift = relativeCastTime - assignment.time
                end
            end

            tinsert(result, resultRow)
        end

        ContinueWrapper()
    end

    return result
end
