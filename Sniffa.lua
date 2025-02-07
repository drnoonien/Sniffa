local addonName, ns = ...

-- =======================================================================================

local function VDTLog(payload, label)
	if (VDT) then
		VDT:Add(payload, label)
	end
end

local function PruneHistoryByDate(targetDate)
	if not targetDate:match("^%d%d%d%d%-%d%d%-%d%d$") then
		print(addonName, "Error: date must be in yyyy-mm-dd format")
		return
	end

	for key in pairs(SniffaDB.history) do
		local entryDate = key:match("^(%d%d%d%d%-%d%d%-%d%d)")
		if entryDate == targetDate then
			SniffaDB.history[key] = nil
		end
	end

	print(addonName, "Pruned entries for date:", targetDate)
end

local function PruneHistory(n)
	-- Create a sorted list of keys (timestamps)
	local keys = {}
	for key in pairs(SniffaDB.history) do
		table.insert(keys, key)
	end

	-- Sort keys in ascending order (oldest first)
	table.sort(keys, function(a, b) return a < b end)

	-- Prune the oldest n entries
	for i = 1, n do
		local oldestKey = keys[i]
		if oldestKey then
			SniffaDB.history[oldestKey] = nil
		end
	end
end

local function SortTableByKeysDescending(inputTable)
	local sorted = {}

	-- First get all keys
	local keys = {}
	for key in pairs(inputTable) do
		table.insert(keys, key)
	end

	-- Sort keys descending
	table.sort(keys, function(a, b) return a > b end)

	-- Create new array with key-value pairs
	for i, key in ipairs(keys) do
		table.insert(sorted, {
			key = key,
			value = inputTable[key]
		})
	end

	return sorted
end


local function ColorString(text, color)
	local colorCodes = {
		red = "|cFFFF3333",
		yellow = "|cFFFFFF00",
		green = "|cFF00FF00",
		blue = "|cFF87CEEB",
		default = "|cFFFFFFFF" -- Default to white
	}

	local colorCode = colorCodes[color] or colorCodes.default
	return colorCode .. text .. "|r"
end

local function GetCurrentFormattedDateTime()
	return date("%Y-%m-%d %H:%M:%S")
end

local function setRelativeColumnWidths(container, left, right, leftWidth)
	left:SetWidth(container.frame:GetWidth() * leftWidth)
	right:SetWidth(container.frame:GetWidth() * (1 - leftWidth))
end

local GUI = nil

local function ShowGUI()
	if (GUI) then
		GUI:Show()
		return
	end

	local AceGUI = LibStub("AceGUI-3.0")

	local guiState = {
		selectedPull = nil
	}

	local window = AceGUI:Create("Frame")
	GUI = window

	window:SetTitle("Sniffa")
	window:SetWidth(600)
	window:SetHeight(500)
	window:EnableResize(false)
	window:SetLayout("Fill")
	window:SetStatusText("v1.0.0")

	_G["SniffaGlobalWindowHandle"] = window.frame
	table.insert(UISpecialFrames, "SniffaGlobalWindowHandle")

	window:SetCallback("OnClose", function(widget)
		AceGUI:Release(widget)
		GUI = nil
	end)

	---

	local container = AceGUI:Create("SimpleGroup")
	container:SetFullWidth(true)
	container:SetFullHeight(true)
	container:SetLayout("Flow")
	window:AddChild(container)

	---

	local historySorted = SortTableByKeysDescending(SniffaDB.history)

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

	---@param value EncounterData
	local function loadDetails(frame, value)
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

		for _, entry in ipairs(value.deathData) do
			local label = AceGUI:Create("Label")
			label:SetFullWidth(true)
			local text = ColorString(string.format("%s - [ Death: %s ]", entry.time, entry.player), "blue")

			if (entry.player == UnitName("player")) then
				text = "|A:characterupdate_arrow-bullet-point:12:12:0:-1.5|a " .. text
			end

			label:SetText(text)
			label:SetFontObject(GameFontNormal)

			label:SetUserData("sortTime", entry.time)

			label:SetImage(133730)
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
				text = "|A:characterupdate_arrow-bullet-point:12:12:0:-1.5|a " .. text
			end

			if (not v.hit) then
				text = ColorString(text, "red")
			elseif (v.drift > 5) then
				text = ColorString(text, "yellow")
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

		table.sort(labels, function(a, b)
			return a:GetUserData("sortTime") < b:GetUserData("sortTime")
		end)

		for _, label in ipairs(labels) do
			frame:AddChild(label)
		end
	end

	for index, entry in ipairs(historySorted) do
		---@class EncounterData
		local entryValue = entry.value

		local label = AceGUI:Create("InteractiveLabel")
		label:SetText(entry.key)
		label:SetFontObject(GameFontNormal)
		label:SetCallback("OnClick", function()
			if (guiState.selectedPullLabel) then
				guiState.selectedPullLabel:SetColor(1, 1, 1)
			end
			label:SetColor(0, 1, 0)
			guiState.selectedPullLabel = label
			loadDetails(innerRight, entryValue)
		end)

		if (index == 1) then
			label:SetColor(0, 1, 0)
			guiState.selectedPullLabel = label
			loadDetails(innerRight, entryValue)
		end

		innerLeft:AddChild(label)
	end

	setRelativeColumnWidths(container, left, right, 0.3)

	container:AddChild(left)
	container:AddChild(right)
end

-- =======================================================================================

local function trim(s)
	return s:match("^%s*(.-)%s*$")
end

local function customSplit(input, delimiter)
	local result = {}

	if (input == "") then
		return result
	end

	for match in (input .. delimiter):gmatch("(.-)" .. delimiter) do
		table.insert(result, trim(match))
	end

	return result
end

local function formatTimestamp(seconds)
	local minutes = math.floor(seconds / 60)
	local secs = math.floor(seconds % 60)
	local millis = math.floor((seconds - math.floor(seconds)) * 1000)
	return string.format("%02d:%02d.%03d", minutes, secs, millis)
end

local function expandEventName(shortEvent)
	local events = {
		["SCC"] = "SPELL_CAST_SUCCESS",
		["SCS"] = "SPELL_CAST_START",
		["SAA"] = "SPELL_AURA_APPLIED",
		["SAR"] = "SPELL_AURA_REMOVED"
	}

	return events[shortEvent]
end

--[[
	Note programs sometimes use the wrong spell-id in their generated
	note, this function re-maps known spells to the spell that will
	actually be used in-game for tracking
]]
local function mapIncorrectPlayerSpellsInNote(spell)
	-- map<note-id, cast-id>
	local map = {
		[370984] = 370960, -- Emerald Communion (in note: 370984)
		[367226] = 367230, -- Spiritbloom (in note: 367226)
		[355936] = 382614, -- Dream Breath (in note: 355936)
		[304971] = 375576, -- Divine Toll (in note: 304971)
		[77764] = 106898, -- Stampeding Roar (in note: 77764)
		[315443] = 383269 -- Abom limb (in note: 315443)
	}

	if (map[spell]) then
		return map[spell]
	end

	return spell
end

---@type { player: string, time: number }[]
local DEATH_EVENTS = {}

---@type table<string, number[]>
local PLAYER_EVENTS = {}

---@type table<string, number[]>
local ENEMY_EVENTS = {}

---@class OffsetData
---@field event string
---@field spell number
---@field count number
---
---@class NoteEntry
---@field player string
---@field spell number
---@field time number
---@field offset? OffsetData
---
---@type NoteEntry[]
local NOTE_DATA = {}

local ENCOUNTER_PLAYERS = {}

local NOTE_METADATA = {
	players = {},
	spells = {}
}

-- Run on ENCOUNTER_START
local function ParseNote()
	local note = _G.VMRT.Note.Text1
	local collect = false

	local limitToBlock = (
		note:match("sniffstart") and
		note:match("sniffend")
	)

	for line in note:gmatch("[^\r\n]+") do
		if (line:find("sniffstart")) then
			collect = true
		elseif (line:find("sniffend")) then
			collect = false
		elseif (collect or not limitToBlock) then
			if (not line:find("{spell:%d+") and not line:find("{time:")) then
				-- skip
			else
				local minute, sec, options = line:match("{time:(%d+)[:%.]?(%d*),?([^{}]*)}")

				-- This whitespace around the dash is critical to
				-- parse Viserio exports correctly, if there multiple
				-- enemy spells on the same timestamp, it will concat
				-- all of them using a dash, but the dash will lack a
				-- trailing space, so for example
				--
				--[[
					{time:1:32,SAR:450980:1}4:29{spell:438801}Call of the Swarm -{spell:441782}Strands of Reality - Player {spell:315443}
				]]
				--
				-- We can infer that it's not the player delimiter
				-- since the dash is instantly followed by "{spell..".
				-- This is all super flakey and will obviously break
				-- the second the export format changes.
				local assignemntsPart = string.match(line, ".*%s%-%s(.*)")
				local parts = customSplit(assignemntsPart, "  ")

				for _, part in pairs(parts) do
					-- Cleans up "player1 @player2" assignments
					part = part:gsub("@%S+", "")
					local playerName = customSplit(part, " ")[1]
					local spell = part:match("{spell:(%d+)}")

					local RECORD_ENTRY = (IsInGroup() and ENCOUNTER_PLAYERS[playerName]) or not IsInGroup()

					if (RECORD_ENTRY) then
						-- There might be other noise in the note
						if (spell) then
							local playerSpell = mapIncorrectPlayerSpellsInNote(tonumber(spell))

							NOTE_METADATA.players[playerName] = true
							NOTE_METADATA.spells[playerSpell] = true

							local playerEntry = {
								player = playerName,
								spell = playerSpell,
								time = (minute * 60) + sec
							}

							if (options ~= "") then
								local event, offsetSpell, count = options:match("(%a+):(%d+):(%d+)")

								NOTE_METADATA.spells[tonumber(offsetSpell)] = true

								playerEntry.offset = {
									event = expandEventName(event),
									spell = tonumber(offsetSpell),
									count = tonumber(count)
								}
							end

							tinsert(NOTE_DATA, playerEntry)
						end
					end
				end
			end
		end
	end
end

local EventFrame = CreateFrame("Frame")
EventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
EventFrame:RegisterEvent("ENCOUNTER_START")
EventFrame:RegisterEvent("ENCOUNTER_END")
EventFrame:RegisterEvent("ADDON_LOADED")

EventFrame:SetScript("OnEvent", function(self, event, ...)
	self[event](self, event, ...)
end)

local CAPTURE_EVENTS = false
local START_DATETIME = nil
local START_TIME = -1
local END_TIME = -1

---@class ResultRow
---@field hit boolean
---@field player string
---@field spell number
---@field time string
---@field drift? number

local function GenerateEncounterResult()
	---@type ResultRow[]
	local result = {}

	for _, assignment in ipairs(NOTE_DATA) do
		-- Wrapper function to emulate "continue" functionality via
		-- return
		local function continueWrapper()
			local startTime = START_TIME
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

				if (not ENEMY_EVENTS[enemyKey]) then
					return
				end

				local enemyEventTime = ENEMY_EVENTS[enemyKey][assignment.offset.count]

				if (not enemyEventTime) then
					return
				end

				-- Shift up the start-time to when the tracked event happened
				startTime = enemyEventTime
				-- Assignment times are relative to the offset, need
				-- to add elapsed duration for an absolute value
				assignmentTime = assignmentTime + (enemyEventTime - START_TIME)
			end

			local duration = END_TIME - startTime

			local THRESHOLD_WINDOW = 10

			if (assignment.time > (duration + THRESHOLD_WINDOW)) then
				return
			end

			---@type ResultRow
			local resultRow = {
				hit = false,
				player = assignment.player,
				spell = assignment.spell,
				time = formatTimestamp(assignmentTime)
			}

			local casts = PLAYER_EVENTS[assignment.player .. ":" .. assignment.spell] or {}

			for _, absoluteCastTime in ipairs(casts) do
				local relativeCastTime = absoluteCastTime - startTime

				if (math.abs(assignment.time - relativeCastTime) <= THRESHOLD_WINDOW) then
					resultRow.hit = true
					resultRow.time = formatTimestamp(absoluteCastTime - START_TIME)
					resultRow.drift = relativeCastTime - assignment.time
				end
			end

			tinsert(result, resultRow)
		end

		continueWrapper()
	end

	return result
end

function EventFrame:ADDON_LOADED(_, addon)
	if (addon ~= addonName) then
		return
	end

	self:UnregisterEvent("ADDON_LOADED")

	---@class EncounterMeta
	---@field encounterID number
	---@field encounterName string
	---@field difficultyID number
	---@field groupSize number
	---@field success boolean
	---@field duration number

	---@class EncounterData
	---@field meta EncounterMeta
	---@field data ResultRow[]
	---@field deathData { player: string, time: string }[]

	---@class SniffaOptions
	---@field autoShowAfterEncounter string

	---@class SniffaDBType
	---@field history table<string, EncounterData>
	---@field options SniffaOptions

	---@type SniffaDBType
	SniffaDB = SniffaDB or { history = {} }

	if not SniffaDB.options then
		SniffaDB.options = {
			autoShowAfterEncounter = "if_my_missed_assignments",
		}
	end

	local options = {
		name = "Sniffa",
		type = "group",
		args = {

			clearAllData = {
				type = "execute",
				name = "Clear all data",
				order = 1,
				func = function()
					SniffaDB.history = {}
					print(addonName, "Removed all stored data!")
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

		}
	}

	LibStub("AceConfig-3.0"):RegisterOptionsTable(addonName, options)
	ns.optionsFrame = LibStub("AceConfigDialog-3.0"):AddToBlizOptions(addonName, "Sniffa")
end

function EventFrame:ENCOUNTER_START(event, ...)
	local enabledEncounters = {
		[2902] = "Ulgrax",
		[2917] = "Horror",
		[2898] = "Sikran",
		[2918] = "Rasha",
		[2919] = "Brood",
		[2920] = "Princess",
		[2921] = "Silken",
		[2922] = "Ansu",
	}

	local encounterID, encounterName, difficultyID, groupSize = ...

	if (not enabledEncounters[encounterID]) then
		return
	end

	for i = 1, GetNumGroupMembers() do
		local name, _, _, _, _, _, _, _, _, _, _ = GetRaidRosterInfo(i)
		if name then
			-- Remove realm name if present
			local realmLessName = name:match("^[^-]+")
			ENCOUNTER_PLAYERS[realmLessName] = true
		end
	end

	PLAYER_EVENTS = {}
	DEATH_EVENTS = {}
	ENEMY_EVENTS = {}
	NOTE_DATA = {}
	NOTE_METADATA = {}

	ParseNote()

	if (#NOTE_DATA <= 0) then
		return
	end

	START_TIME = GetTime()
	START_DATETIME = GetCurrentFormattedDateTime()
	CAPTURE_EVENTS = true
end

function EventFrame:ENCOUNTER_END(_, ...)
	if (not CAPTURE_EVENTS) then
		return
	end

	local encounterID, encounterName, difficultyID, groupSize, success = ...

	CAPTURE_EVENTS = false
	END_TIME = GetTime()

	local duration = END_TIME - START_TIME

	if (duration < 5) then
		print(addonName, "Error: fight too short, not saving the entry:", duration)
		return
	end

	local result = GenerateEncounterResult()

	VDTLog({ START_TIME, END_TIME }, "start-end")
	VDTLog({ PLAYER_EVENTS }, "player-events")
	VDTLog({ ENEMY_EVENTS }, "enemy-events")
	VDTLog({ NOTE_METADATA }, "note-meta")
	VDTLog({ NOTE_DATA }, "note-data")
	VDTLog({ DEATH_EVENTS }, "death-events")
	VDTLog({ result }, "compare-result")

	local deathData = {}

	for _, value in ipairs(DEATH_EVENTS) do
		tinsert(deathData, {
			player = value.player,
			time = formatTimestamp(value.time - START_TIME)
		})
	end

	SniffaDB.history[START_DATETIME] = {
		meta = {
			encounterID = encounterID,
			encounterName = encounterName,
			difficultyID = difficultyID,
			groupSize = groupSize,
			success = success,
			duration = END_TIME - START_TIME
		},
		data = result,
		deathData = deathData
	}

	VDTLog({ SniffaDB }, "SniffaDB")

	if (SniffaDB.options.autoShowAfterEncounter == "always") then
		ShowGUI()
		return
	end

	if (SniffaDB.options.autoShowAfterEncounter == "if_any_missed_assignments") then
		for _, k in pairs(result) do
			if (not k.hit) then
				ShowGUI()
				return
			end
		end
	end

	if (SniffaDB.options.autoShowAfterEncounter == "if_my_missed_assignments") then
		for _, k in pairs(result) do
			if (k.player == UnitName("player") and not k.hit) then
				ShowGUI()
				return
			end
		end
	end
end

function EventFrame:COMBAT_LOG_EVENT_UNFILTERED()
	if (not CAPTURE_EVENTS) then
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

	-- Trim off any server name
	if (not hostileSourceUnit and sourceName) then
		sourceName = sourceName:match("^[^-]+")
	end
	if (not hostileDestUnit and destName) then
		destName = destName:match("^[^-]+")
	end

	-- Stop tracking deaths after 7 deaths, pull is _likely_ over
	local keepTrackingDeaths = #DEATH_EVENTS < 7

	if (not hostileSourceUnit and subEvent == "UNIT_DIED" and keepTrackingDeaths) then
		if (ENCOUNTER_PLAYERS[destName]) then
			tinsert(DEATH_EVENTS, {
				player = destName,
				time = GetTime()
			})
		end

		return
	end

	if (subEvent ~= "SPELL_CAST_START" and
			subEvent ~= "SPELL_CAST_SUCCESS" and
			subEvent ~= "SPELL_AURA_APPLIED" and
			subEvent ~= "SPELL_AURA_REMOVED") then
		return
	end

	local spell = eventArgs[12]

	-- Spirit of Redemption
	if (not hostileSourceUnit and subEvent == "SPELL_AURA_APPLIED" and spell == 27827 and keepTrackingDeaths) then
		if (ENCOUNTER_PLAYERS[sourceName]) then
			tinsert(DEATH_EVENTS, {
				player = sourceName,
				time = GetTime()
			})
		end

		return
	end

	if (not NOTE_METADATA.spells[spell]) then
		return
	end

	if (hostileSourceUnit) then
		-- TODO: This can be further filtered down once the note is
		-- parsed and we know which spell IDs to capture

		local key = subEvent .. ":" .. spell

		if (ENEMY_EVENTS[key]) then
			tinsert(ENEMY_EVENTS[key], GetTime())
		else
			ENEMY_EVENTS[key] = { GetTime() }
		end
	else
		if (subEvent ~= "SPELL_CAST_SUCCESS") then
			return
		end

		if (not NOTE_METADATA.players[sourceName]) then
			return
		end

		local key = sourceName .. ":" .. spell

		if (PLAYER_EVENTS[key]) then
			tinsert(PLAYER_EVENTS[key], GetTime())
		else
			PLAYER_EVENTS[key] = { GetTime() }
		end
	end
end

SLASH_SNIFFA1 = "/sniff"
SLASH_SNIFFA2 = "/sniffa"
SlashCmdList.SNIFFA = function(msg, editBox)
	local args = customSplit(msg, " ")

	if (#args <= 0) then
		ShowGUI()
	end

	if (args[1] == "help") then
		print(addonName, "Available commands:")
		print("/sniff - Opens the Sniffa GUI.")
		print("/sniff help - Displays this help information.")
		print("/sniff config - Opens config.")
		print("/sniff prune <number> - Prunes the oldest <number> of entries from the history.")
		print("/sniff prune-date <yyyy-mm-dd> - Prunes entries from the history for the specified date.")
		print("/sniff note (debug only) - Parses the current note and logs the data to ViragDevTool")
	end

	if (args[1] == "note") then
		NOTE_DATA = {}
		NOTE_METADATA = {}

		ParseNote()
		VDTLog({ NOTE_DATA }, "note-data")
		VDTLog({ NOTE_METADATA }, "note-metadata")

		print(addonName, "Dumped note to VDT")
	end

	if (args[1] == "config") then
		Settings.OpenToCategory(ns.optionsFrame.name)
	end

	if (args[1] == "prune") then
		if (not args[2]) then
			print(addonName, "Error: need to pass a number to prune")
			return
		end

		PruneHistory(args[2])
		print(addonName, string.format("Pruned %s entries", args[2]))
	end

	if (args[1] == "prune-date") then
		if (not args[2]) then
			print(addonName, "Error: need to pass a date in yyyy-mm-dd format to prune-date")
			return
		end

		PruneHistoryByDate(args[2])
	end
end
