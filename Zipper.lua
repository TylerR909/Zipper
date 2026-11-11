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
		return
	end
	if msg == "config" or msg == "options" or msg == "settings" then
		ns.Config:Toggle()
		return
	end
	-- Temporary, so the level-up line can be checked without waiting for a ding.
	if msg == "ding" then
		local levels = ns.DB.record and ns.DB.record.levels
		local row = type(levels) == "table" and levels[#levels] or nil
		local text = type(row) == "table" and ns.DB:LevelRecapText(row.lv, row.t) or nil
		ns:Print(text or L["No level-up to recap yet."])
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
