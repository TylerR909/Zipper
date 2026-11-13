local ADDON_NAME, ns = ...
local L = ns.L

Zipper = ns

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:RegisterEvent("PLAYER_LOGOUT")
boot:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
		ZipperDB = ZipperDB or {}
		ns.DB:Init()
		ns.Replay:Init()
	elseif event == "PLAYER_ENTERING_WORLD" and not ns.started then
		-- Once per UI load. Zoning also fires this event; the open session stays open.
		-- A reload within a few minutes of the last logout stamp continues that session.
		ns.started = true
		ns.DB:BindPlayer()
		local migrated = ns.DB.pendingNotice
		ns.DB.pendingNotice = nil
		if migrated == "toPrivate" then
			ns:Print(string.format(L["Moved %s to a Non-Global save."], ns.DB:JourneyLabel(ns.DB.record)))
		elseif migrated == "toGlobal" then
			ns:Print(string.format(L["Moved %s back to the Global save."], ns.DB:JourneyLabel(ns.DB.record)))
		elseif migrated == "purgePrivate" then
			ns:Print(string.format(L["Finished deleting %s's Non-Global journey."], ns.DB:JourneyLabel(ns.DB.record)))
		end
		if ns.Config:SkipQuiet() and ns.DB:DropQuietTail() > 0 then
			ns:Print(L["Skipped a quiet stop from the last login."])
		end
		local _, continued = ns.DB:Open(ns.DB:Now(), false)
		ns.GPS:Start(continued)
		ns.Social:Start()
		ns:Print(L["recording. /zipper opens the map replay."])
		ns.Config:StartReminder()
		ns.Config:StartSizePoll()
	elseif event == "PLAYER_LOGOUT" then
		ns.Social:Stop()
		ns.GPS:Stop()
		ns.DB:Flush()
	end
end)

-- Do not RegisterEvent from inside the ADDON_LOADED handler. This client
-- treats that as a forbidden action and the call throws. Register at file load.
ns.GPS:EnsureEvents()
ns.Social:EnsureEvents()

function ns:Print(...)
	print("|cff33ddffZipper|r:", ...)
end

SLASH_ZIPPER1 = "/zipper"
SLASH_ZIPPER2 = "/zip"
SlashCmdList.ZIPPER = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if msg == "" then
		ns.Replay:Toggle()
		return
	end
	if msg == "help" then
		ns:Print(L["/zipper — open the map, the route, and the replay"])
		ns:Print(L["/zipper config — reminder and what gets recorded"])
		ns:Print(L["/zipper status — sessions and the current recap"])
		ns:Print(L["/zipper ding — the level you just finished, or /zipper ding 28"])
		return
	end
	if msg == "config" or msg == "options" or msg == "settings" then
		ns.Config:Toggle()
		return
	end
	if msg == "ding" or msg:match("^ding%s") then
		local rest = msg:match("^ding%s*(.-)%s*$") or ""
		local level
		if rest ~= "" then
			if not rest:match("^%d+$") then
				ns:Print(L["Use /zip ding or /zip ding 28."])
				return
			end
			level = tonumber(rest)
		end
		local playerLevel = UnitLevel and UnitLevel("player")
		if type(playerLevel) ~= "number" or (issecretvalue and issecretvalue(playerLevel)) or playerLevel < 1 then
			playerLevel = nil
		end
		local maxLevel = GetMaxPlayerLevel and GetMaxPlayerLevel()
		if type(maxLevel) ~= "number" or (issecretvalue and issecretvalue(maxLevel)) or maxLevel < 1 then
			maxLevel = nil
		end
		ns:Print(ns.DB:DingCommand(level, playerLevel, maxLevel))
		return
	end
	if msg == "status" then
		local sessions, points, events = ns.DB:Stats()
		ns:Print(string.format(L["%d sessions, %d points, %d events."], sessions, points, events))
		local current = ns.DB:Current()
		if current then
			ns:Print(ns.DB:RecapText({ current }))
		end
		return
	end
	ns:Print(L["unknown command. Try /zipper help"])
end
