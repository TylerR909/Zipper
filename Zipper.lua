local ADDON_NAME, ns = ...

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
		-- Before PLAYER_ENTERING_WORLD. That event can arrive already in combat,
		-- and RegisterEvent is protected then.
		ns.GPS:EnsureEvents()
	elseif event == "PLAYER_ENTERING_WORLD" and not ns.started then
		-- Once per UI load. Zoning also fires this event; the open session stays open.
		-- A reload within a few minutes of the last logout stamp continues that session.
		ns.started = true
		local _, continued = ns.DB:Open(ns.DB:Now(), false)
		ns.GPS:Start(continued)
		ns:Print("recording. /zipper opens the map replay.")
		ns.Config:StartReminder()
	elseif event == "PLAYER_LOGOUT" then
		ns.GPS:Stop()
	end
end)

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
		ns:Print("/zipper — open the replay")
		ns:Print("/zipper config — reminder and what gets recorded")
		ns:Print("/zipper status — sessions and the current recap")
		return
	end
	if msg == "config" or msg == "options" or msg == "settings" then
		ns.Config:Toggle()
		return
	end
	if msg == "status" then
		local sessions, points, events = ns.DB:Stats()
		ns:Print(string.format("%d sessions, %d points, %d events.", sessions, points, events))
		local current = ns.DB:Current()
		if current then
			ns:Print(ns.DB:RecapText({ current }))
		end
		return
	end
	ns:Print("unknown command. Try /zipper help")
end
