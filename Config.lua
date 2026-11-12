local _, ns = ...
local L = ns.L

ns.Config = {}

-- Minutes of trail shown on the map while glancing. 0 is the whole history.
ns.Config.GLANCE_STOPS = { 5, 10, 15, 20, 30, 45, 60, 0 }

local TRACK_DEFAULTS = {
	path = true,
	kills = true,
	questAccept = true,
	questTurnin = true,
	death = true,
	summon = true,
	hearth = true,
	portal = true,
	trainer = true,
	flight = true,
	mount = true,
	afk = true,
	idle = true,
	rest = true,
	fishing = true,
	instance = true,
	zone = true,
	party = true,
}

local KIND_KEY = {
	[ns.Kind.KILL] = "kills",
	[ns.Kind.QUEST_ACCEPT] = "questAccept",
	[ns.Kind.QUEST_TURNIN] = "questTurnin",
	[ns.Kind.DEATH] = "death",
	[ns.Kind.SUMMON] = "summon",
	[ns.Kind.HEARTH] = "hearth",
	[ns.Kind.PORTAL] = "portal",
	[ns.Kind.TRAINER] = "trainer",
	[ns.Kind.CAMP] = "rest",
	[ns.Kind.SLEEP] = "rest",
	[ns.Kind.FISH] = "fishing",
	[ns.Kind.FLIGHT_START] = "flight",
	[ns.Kind.FLIGHT_END] = "flight",
	[ns.Kind.MOUNT] = "mount",
	[ns.Kind.DISMOUNT] = "mount",
	[ns.Kind.AFK_START] = "afk",
	[ns.Kind.AFK_END] = "afk",
	[ns.Kind.IDLE] = "idle",
	[ns.Kind.INSTANCE_ENTER] = "instance",
	[ns.Kind.INSTANCE_LEAVE] = "instance",
	[ns.Kind.BOSS] = "instance",
	[ns.Kind.ZONE] = "zone",
	[ns.Kind.GROUP] = "party",
}

local TRACKS = {
	{ key = "kills", label = "Kills" },
	{ key = "questAccept", label = "Quest pickups" },
	{ key = "questTurnin", label = "Quest turn-ins" },
	{ key = "death", label = "Deaths" },
	{ key = "summon", label = "Summons" },
	{ key = "hearth", label = "Hearths" },
	{ key = "portal", label = "Teleports and portals" },
	{ key = "trainer", label = "Trainers" },
	{ key = "flight", label = "Flights" },
	{ key = "mount", label = "Mount and dismount" },
	{ key = "afk", label = "AFK" },
	{ key = "idle", label = "Idle" },
	{ key = "rest", label = "Camps and sleeping bags" },
	{ key = "fishing", label = "Fishing" },
	{ key = "instance", label = "Dungeons and raids" },
	{ key = "party", label = "Party members" },
	{ key = "zone", label = "Zone changes" },
}

function ns.Config:ClampMinutes(value)
	value = math.floor((tonumber(value) or 60) + 0.5)
	if value < 30 then
		value = 30
	elseif value > 180 then
		value = 180
	end
	local steps = math.floor((value + 7.5) / 15)
	value = steps * 15
	if value < 30 then
		value = 30
	elseif value > 180 then
		value = 180
	end
	return value
end

function ns.Config:IntervalLabel(minutes)
	minutes = self:ClampMinutes(minutes)
	if minutes == 60 then
		return L["1 hour"]
	end
	if minutes % 60 == 0 then
		return string.format(L["%d hours"], minutes / 60)
	end
	if minutes > 60 then
		return string.format(L["%d hr %d min"], math.floor(minutes / 60), minutes % 60)
	end
	return string.format(L["%d min"], minutes)
end

function ns.Config:ReminderText()
	local minutes = self:Get().remindMinutes
	local span
	if minutes == 60 then
		span = L["an hour"]
	elseif minutes % 60 == 0 then
		span = string.format(L["%d hours"], minutes / 60)
	else
		span = string.format(L["%d minutes"], minutes)
	end
	return string.format(L["Zipper has accumulated %s of data which can be lost. Suggest `/reload` to save it forever."], span)
end

function ns.Config:Get()
	ZipperDB = ZipperDB or {}
	local cfg = ZipperDB.config
	if type(cfg) ~= "table" then
		cfg = {}
		ZipperDB.config = cfg
	end
	if cfg.remind == nil then
		cfg.remind = true
	end
	cfg.remindMinutes = self:ClampMinutes(cfg.remindMinutes or 60)
	if cfg.showMarkers == nil then
		cfg.showMarkers = true
	end
	if cfg.ghostRed == nil then
		cfg.ghostRed = false
	end
	if cfg.skipQuiet == nil then
		cfg.skipQuiet = true
	end
	if cfg.glanceTrail == nil then
		cfg.glanceTrail = 30
	end
	if type(cfg.track) ~= "table" then
		cfg.track = {}
	end
	for key, value in pairs(TRACK_DEFAULTS) do
		if cfg.track[key] == nil then
			cfg.track[key] = value
		end
	end
	return cfg
end

function ns.Config:Enabled(key)
	local track = self:Get().track
	if track[key] == nil then
		return true
	end
	return track[key] and true or false
end

function ns.Config:WantsKind(kind)
	local key = KIND_KEY[kind]
	if not key then
		return true
	end
	return self:Enabled(key)
end

function ns.Config:ShowMarkers()
	return self:Get().showMarkers and true or false
end

function ns.Config:GlanceTrail()
	local minutes = self:Get().glanceTrail
	if minutes == nil then
		return 30
	end
	return minutes
end

function ns.Config:GlanceIndex(minutes)
	local stops = self.GLANCE_STOPS
	for i = 1, #stops do
		if stops[i] == minutes then
			return i
		end
	end
	return 5
end

function ns.Config:GlanceLabel(minutes)
	if not minutes or minutes <= 0 then
		return L["Full"]
	end
	return string.format(L["%d min"], minutes)
end

function ns.Config:SetGlanceTrail(minutes)
	self:Get().glanceTrail = minutes or 0
	if self.glanceText then
		self.glanceText:SetText(self:GlanceLabel(minutes))
	end
	local replay = ns.Replay
	if replay and replay.route and not (replay.UsingReplayTrail and replay:UsingReplayTrail()) then
		replay:Redraw()
	end
end

function ns.Config:ApplyReminder()
	if self.ticker then
		self.ticker:Cancel()
		self.ticker = nil
	end
	if not self.reminderArmed then
		return
	end
	local cfg = self:Get()
	if not cfg.remind then
		return
	end
	self.ticker = C_Timer.NewTicker(cfg.remindMinutes * 60, function()
		ns:Print(ns.Config:ReminderText())
	end)
end

function ns.Config:StartReminder()
	self.reminderArmed = true
	self:ApplyReminder()
end

function ns.Config:SetRemind(on)
	self:Get().remind = on and true or false
	self:ApplyReminder()
	self:RefreshSlider()
end

function ns.Config:SetMinutes(minutes)
	local cfg = self:Get()
	minutes = self:ClampMinutes(minutes)
	if cfg.remindMinutes == minutes then
		return
	end
	cfg.remindMinutes = minutes
	if cfg.remind then
		self:ApplyReminder()
	end
end

function ns.Config:SetTrack(key, on)
	local cfg = self:Get()
	if cfg.track[key] == nil and key ~= "path" then
		return
	end
	cfg.track[key] = on and true or false
	if key == "party" and ns.Social and ns.Social.active then
		if cfg.track.party then
			ns.Social:Schedule()
		else
			ns.Social:Disable()
		end
	end
end

function ns.Config:GhostRed()
	return self:Get().ghostRed and true or false
end

function ns.Config:SkipQuiet()
	return self:Get().skipQuiet and true or false
end

function ns.Config:SetSkipQuiet(on)
	self:Get().skipQuiet = on and true or false
end

function ns.Config:SetGhostRed(on)
	self:Get().ghostRed = on and true or false
	if ns.Replay and ns.Replay.route then
		ns.Replay:Redraw()
	end
end

function ns.Config:SetShowMarkers(on)
	self:Get().showMarkers = on and true or false
	if ns.Replay and ns.Replay.Redraw then
		ns.Replay:Redraw()
	end
end

function ns.Config:RefreshSlider()
	local slider = self.slider
	local valueText = self.sliderText
	if not slider then
		return
	end
	local cfg = self:Get()
	self.lock = true
	slider:SetValue(cfg.remindMinutes)
	self.lock = false
	if valueText then
		valueText:SetText(self:IntervalLabel(cfg.remindMinutes))
	end
	if cfg.remind then
		slider:Enable()
		if valueText then
			valueText:SetTextColor(1, 0.82, 0)
		end
	else
		slider:Disable()
		if valueText then
			valueText:SetTextColor(0.5, 0.5, 0.5)
		end
	end
end

local function CheckText(box)
	if box.Text then
		return box.Text
	end
	local name = box:GetName()
	if name then
		return _G[name .. "Text"]
	end
end

local PAGES = {
	{ key = "general", label = L["General"] },
	{ key = "road", label = L["The road"] },
	{ key = "moments", label = L["Moments"] },
	{ key = "saved", label = L["Saved data"] },
}

local ROAD = {
	{ key = "path", label = L["Movement"] },
	{ key = "mount", label = L["Mount and dismount"] },
	{ key = "flight", label = L["Flights"] },
	{ key = "zone", label = L["Zone changes"] },
	{ key = "afk", label = L["AFK"] },
	{ key = "idle", label = L["Idle"] },
	{ key = "rest", label = L["Camps and sleeping bags"] },
	{ key = "fishing", label = L["Fishing"] },
}

local MOMENTS = {
	{ key = "kills", label = L["Kills"] },
	{ key = "questAccept", label = L["Quest pickups"] },
	{ key = "questTurnin", label = L["Quest turn-ins"] },
	{ key = "death", label = L["Deaths"] },
	{ key = "hearth", label = L["Hearths"] },
	{ key = "summon", label = L["Summons"] },
	{ key = "portal", label = L["Teleports and portals"] },
	{ key = "trainer", label = L["Trainers"] },
	{ key = "instance", label = L["Dungeons and raids"] },
	{ key = "party", label = L["Party members"] },
}

local function AddCheck(parent, name, label)
	local box = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
	local text = CheckText(box)
	if text then
		text:SetText(label)
	end
	return box
end

local function HideSliderLabels(slider)
	for _, key in ipairs({ "Low", "High", "Text" }) do
		local label = slider[key] or _G[slider:GetName() .. key]
		if label then
			label:Hide()
		end
	end
end

local function PageFrame(parent)
	local page = CreateFrame("Frame", nil, parent)
	page:SetAllPoints()
	page:Hide()
	return page
end

local function PageNote(parent, text)
	local note = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	note:SetPoint("TOPLEFT", 16, -16)
	note:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
	note:SetJustifyH("LEFT")
	note:SetText(text)
	return note
end

function ns.Config:ShowPage(key)
	self.page = key
	if self.pages then
		for name, page in pairs(self.pages) do
			page:SetShown(name == key)
		end
	end
	if self.navButtons then
		for i = 1, #self.navButtons do
			local button = self.navButtons[i]
			local selected = button.pageKey == key
			button.bar:SetShown(selected)
			if selected then
				button.label:SetTextColor(1, 1, 1)
			else
				button.label:SetTextColor(1, 0.82, 0)
			end
		end
	end
	if self.purgeList and key ~= "saved" then
		self.purgeList:Hide()
	end
end

function ns.Config:CreateFrame()
	if self.frame then
		return
	end
	-- Same registration Forever Quest Tint uses. The name is what the AddOns list shows.
	local canvas = CreateFrame("Frame")
	canvas.name = "Zipper"

	local nav = CreateFrame("Frame", nil, canvas, "BackdropTemplate")
	nav:SetPoint("TOPLEFT", 8, -8)
	nav:SetPoint("BOTTOMLEFT", 8, 8)
	nav:SetWidth(168)
	nav:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	nav:SetBackdropColor(0, 0, 0, 0.35)
	nav:SetBackdropBorderColor(0.25, 0.25, 0.25, 0.9)

	local body = CreateFrame("Frame", nil, canvas, "BackdropTemplate")
	body:SetPoint("TOPLEFT", nav, "TOPRIGHT", 8, 0)
	body:SetPoint("BOTTOMRIGHT", -8, 8)
	body:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	body:SetBackdropColor(0, 0, 0, 0.2)
	body:SetBackdropBorderColor(0.25, 0.25, 0.25, 0.9)

	local pages = {}
	local navButtons = {}
	for i = 1, #PAGES do
		local entry = PAGES[i]
		local button = CreateFrame("Button", nil, nav)
		button:SetHeight(26)
		button:SetPoint("TOPLEFT", 6, -8 - ((i - 1) * 26))
		button:SetPoint("RIGHT", nav, "RIGHT", -6, 0)
		button.pageKey = entry.key
		button.bar = button:CreateTexture(nil, "BACKGROUND")
		button.bar:SetAllPoints()
		button.bar:SetColorTexture(0.18, 0.40, 0.72, 0.9)
		button.bar:Hide()
		button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		button.label:SetPoint("LEFT", 10, 0)
		button.label:SetText(entry.label)
		button:SetScript("OnClick", function(self)
			ns.Config:ShowPage(self.pageKey)
		end)
		navButtons[i] = button
		pages[entry.key] = PageFrame(body)
	end

	local general = pages.general
	local remind = AddCheck(general, "ZipperConfigRemind", L["Remind me to /reload"])
	remind:SetPoint("TOPLEFT", 12, -16)
	remind:SetScript("OnClick", function(self)
		ns.Config:SetRemind(self:GetChecked())
	end)

	local remindLabel = general:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	remindLabel:SetPoint("TOPLEFT", 20, -52)
	remindLabel:SetText(L["How often"])

	local slider = CreateFrame("Slider", "ZipperConfigRemindSlider", general, "UISliderTemplate")
	slider:SetPoint("TOPLEFT", 28, -76)
	slider:SetSize(220, 16)
	slider:SetMinMaxValues(30, 180)
	slider:SetValueStep(15)
	slider:SetObeyStepOnDrag(true)
	HideSliderLabels(slider)
	slider:SetScript("OnValueChanged", function(_, value)
		if ns.Config.lock then
			return
		end
		local minutes = ns.Config:ClampMinutes(value)
		ns.Config:SetMinutes(minutes)
		if ns.Config.sliderText then
			ns.Config.sliderText:SetText(ns.Config:IntervalLabel(minutes))
		end
	end)

	local valueText = general:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	valueText:SetPoint("LEFT", slider, "RIGHT", 16, 0)
	valueText:SetText(L["1 hour"])

	local glanceLabel = general:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	glanceLabel:SetPoint("TOPLEFT", 16, -112)
	glanceLabel:SetText(L["Trail on the map"])

	local glanceText = general:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	glanceText:SetPoint("LEFT", glanceLabel, "RIGHT", 10, 0)
	glanceText:SetText(ns.Config:GlanceLabel(ns.Config:GlanceTrail()))

	local glance = CreateFrame("Slider", "ZipperConfigGlanceSlider", general, "UISliderTemplate")
	glance:SetPoint("TOPLEFT", 28, -140)
	glance:SetSize(220, 16)
	glance:SetMinMaxValues(1, #ns.Config.GLANCE_STOPS)
	glance:SetValueStep(1)
	glance:SetObeyStepOnDrag(true)
	HideSliderLabels(glance)
	glance:SetScript("OnValueChanged", function(slider, value)
		if ns.Config.lock then
			return
		end
		local index = math.floor(value + 0.5)
		if index < 1 then
			index = 1
		elseif index > #ns.Config.GLANCE_STOPS then
			index = #ns.Config.GLANCE_STOPS
		end
		if math.abs(slider:GetValue() - index) > 0.01 then
			ns.Config.lock = true
			slider:SetValue(index)
			ns.Config.lock = false
		end
		ns.Config:SetGlanceTrail(ns.Config.GLANCE_STOPS[index])
	end)

	local glanceHint = general:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	glanceHint:SetPoint("TOPLEFT", 28, -162)
	glanceHint:SetPoint("RIGHT", general, "RIGHT", -16, 0)
	glanceHint:SetJustifyH("LEFT")
	glanceHint:SetText(L["Solid back to this point, then a short fade. The replay panel has its own slider."])

	local markers = AddCheck(general, "ZipperConfigMarkers", L["Show event markers on the map"])
	markers:SetPoint("TOPLEFT", 12, -196)
	markers:SetScript("OnClick", function(self)
		ns.Config:SetShowMarkers(self:GetChecked())
	end)

	local ghostRed = AddCheck(general, "ZipperConfigGhostRed", L["Red ghost trail"])
	ghostRed:SetPoint("TOPLEFT", 12, -228)
	ghostRed:SetScript("OnClick", function(self)
		ns.Config:SetGhostRed(self:GetChecked())
	end)

	local boxes = { remind = remind, showMarkers = markers, ghostRed = ghostRed }
	local roadNote = PageNote(pages.road, L["Unchecking a type stops new records of it. Saved history stays."])
	for i = 1, #ROAD do
		local entry = ROAD[i]
		local box = AddCheck(pages.road, "ZipperConfig" .. entry.key, entry.label)
		box:SetPoint("TOPLEFT", 12, -36 - ((i - 1) * 28))
		box.trackKey = entry.key
		box:SetScript("OnClick", function(self)
			ns.Config:SetTrack(self.trackKey, self:GetChecked())
		end)
		boxes[entry.key] = box
	end
	roadNote:SetShown(true)

	PageNote(pages.moments, L["Unchecking a type stops new records of it. Saved history stays."])
	for i = 1, #MOMENTS do
		local entry = MOMENTS[i]
		local column = (i - 1) % 2
		local row = math.floor((i - 1) / 2)
		local box = AddCheck(pages.moments, "ZipperConfig" .. entry.key, entry.label)
		box:SetPoint("TOPLEFT", 12 + (column * 230), -36 - (row * 28))
		box.trackKey = entry.key
		box:SetScript("OnClick", function(self)
			ns.Config:SetTrack(self.trackKey, self:GetChecked())
		end)
		boxes[entry.key] = box
	end

	local sizeText = pages.saved:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	sizeText:SetPoint("TOPLEFT", 16, -20)
	sizeText:SetPoint("RIGHT", pages.saved, "RIGHT", -16, 0)
	sizeText:SetJustifyH("LEFT")
	sizeText:SetJustifyV("TOP")
	sizeText:SetText(L["Saved journeys"])

	local purgeDrop = CreateFrame("Button", "ZipperConfigCharDrop", pages.saved, "UIPanelButtonTemplate")
	purgeDrop:SetSize(280, 22)
	purgeDrop:SetPoint("TOPLEFT", sizeText, "BOTTOMLEFT", 0, -16)
	purgeDrop:SetText(L["Saved characters"])
	purgeDrop:SetScript("OnClick", function()
		ns.Config:TogglePurgeList()
	end)

	local purgeList = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
	purgeList:SetPoint("TOPLEFT", purgeDrop, "BOTTOMLEFT", 0, -2)
	purgeList:SetWidth(280)
	purgeList:SetFrameStrata("FULLSCREEN_DIALOG")
	purgeList:SetFrameLevel(20)
	purgeList:Hide()
	purgeList:EnableMouse(true)
	purgeList:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	purgeList:SetBackdropColor(0.08, 0.07, 0.06, 0.98)
	purgeList:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)

	local purge = CreateFrame("Button", "ZipperConfigPurge", pages.saved, "UIPanelButtonTemplate")
	purge:SetSize(80, 22)
	purge:SetPoint("LEFT", purgeDrop, "RIGHT", 8, 0)
	purge:SetText(L["Delete"])
	purge:SetScript("OnClick", function()
		ns.Config:ConfirmPurge()
	end)

	local quiet = AddCheck(pages.saved, "ZipperConfigSkipQuiet", L["Skip quiet stops"])
	quiet:SetPoint("TOPLEFT", purgeDrop, "BOTTOMLEFT", -4, -16)
	quiet:SetScript("OnClick", function(self)
		ns.Config:SetSkipQuiet(self:GetChecked())
	end)

	local quietNote = pages.saved:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	quietNote:SetPoint("TOPLEFT", quiet, "BOTTOMLEFT", 28, 2)
	quietNote:SetPoint("RIGHT", pages.saved, "RIGHT", -16, 0)
	quietNote:SetJustifyH("LEFT")
	quietNote:SetText(L["The next login drops a stop where you never turned in a quest, fought, died, or walked 250 yards from where you arrived. Checking mail or the auction house does not keep it."])

	local dropQuiet = CreateFrame("Button", "ZipperConfigDropQuiet", pages.saved, "UIPanelButtonTemplate")
	dropQuiet:SetSize(160, 22)
	dropQuiet:SetPoint("TOPLEFT", quietNote, "BOTTOMLEFT", -28, -12)
	dropQuiet:SetText(L["Drop quiet stops"])
	dropQuiet:SetScript("OnClick", function()
		local count = ns.DB:DropQuietSessions()
		if count == 1 then
			ns:Print(L["Dropped 1 quiet stop."])
		elseif count > 1 then
			ns:Print(string.format(L["Dropped %d quiet stops."], count))
		else
			ns:Print(L["No quiet stops to drop."])
		end
		if ns.OnDataChanged then
			ns.OnDataChanged()
		end
		ns.Config:RefreshSize()
	end)

	self.pages = pages
	self.navButtons = navButtons
	self:ShowPage("general")

	canvas:SetScript("OnShow", function()
		ns.Config:ShowPage(ns.Config.page or "general")
		ns.Config:Refresh()
	end)
	canvas:SetScript("OnHide", function()
		if ns.Config.purgeList then
			ns.Config.purgeList:Hide()
		end
	end)

	local category
	if Settings and Settings.RegisterCanvasLayoutCategory then
		category = Settings.RegisterCanvasLayoutCategory(canvas, canvas.name)
		Settings.RegisterAddOnCategory(category)
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(canvas)
	end

	self.frame = canvas
	self.category = category
	self.slider = slider
	self.sliderText = valueText
	self.glanceSlider = glance
	self.glanceText = glanceText
	self.sizeText = sizeText
	self.purgeDrop = purgeDrop
	self.purgeList = purgeList
	self.purgeRows = {}
	self.purgeButton = purge
	self.boxes = boxes
	boxes.skipQuiet = quiet
end

function ns.Config:Refresh()
	if not self.boxes then
		return
	end
	local cfg = self:Get()
	self.boxes.remind:SetChecked(cfg.remind)
	self.boxes.path:SetChecked(self:Enabled("path"))
	self.boxes.showMarkers:SetChecked(self:ShowMarkers())
	if self.boxes.ghostRed then
		self.boxes.ghostRed:SetChecked(self:GhostRed())
	end
	if self.boxes.skipQuiet then
		self.boxes.skipQuiet:SetChecked(self:SkipQuiet())
	end
	for i = 1, #TRACKS do
		local key = TRACKS[i].key
		self.boxes[key]:SetChecked(self:Enabled(key))
	end
	self:RefreshSlider()
	if self.glanceSlider then
		self.lock = true
		self.glanceSlider:SetValue(self:GlanceIndex(cfg.glanceTrail))
		self.lock = false
		if self.glanceText then
			self.glanceText:SetText(self:GlanceLabel(cfg.glanceTrail))
		end
	end
	self:RefreshSize()
end

local function FormatBytes(bytes)
	if type(bytes) ~= "number" then
		return "—"
	end
	if bytes < 0 then
		bytes = 0
	end
	if bytes < 1024 then
		return string.format("%d B", math.floor(bytes + 0.5))
	end
	if bytes < (1024 * 1024) then
		return string.format("%.1f KB", bytes / 1024)
	end
	return string.format("%.2f MB", bytes / (1024 * 1024))
end

function ns.Config:GrowthText()
	local perHour, span = ns.DB:SizeGrowth()
	if not perHour or perHour < 1 or (span or 0) < 300 then
		return ""
	end
	return string.format(L["About %s per hour."], FormatBytes(perHour))
end

function ns.Config:PaintSize()
	if not self.sizeText then
		return
	end
	local text = string.format(L["Saved journeys  %s"], FormatBytes(self.accountBytes))
	local rate = self:GrowthText()
	if rate ~= "" then
		text = text .. "\n" .. rate
	end
	self.sizeText:SetText(text)
	self:RefreshPurgeList()
end

-- Settings is one of the two places that measure saved data. The other is the quiet poll.
function ns.Config:RefreshSize()
	if not self.sizeText or not ns.DB or not ns.DB.EstimateCharacter then
		return
	end
	self.characterBytes = ns.DB:EstimateCharacter()
	self.accountBytes = ns.DB:EstimateAll()
	self:PaintSize()
end

-- The other measurement. No chat output. A gap longer than 20 minutes starts the watch over.
function ns.Config:SampleSize()
	if not ns.DB or not ns.DB.char then
		return
	end
	local bytes = ns.DB:EstimateCharacter()
	if type(bytes) ~= "number" then
		return
	end
	ns.DB:RememberSize(bytes, ns.DB:Now())
	if self.sizeText and self.frame and self.frame:IsShown() then
		self.characterBytes = bytes
		self:PaintSize()
	end
end

function ns.Config:StartSizePoll()
	if self.sizePoll then
		return
	end
	self:SampleSize()
	self.sizePoll = C_Timer.NewTicker(5 * 60, function()
		ns.Config:SampleSize()
	end)
end

local function PurgePhrase(text)
	text = tostring(text or ""):match("^%s*(.-)%s*$") or ""
	return text == "gone forever"
end

local function DialogEditBox(dialog)
	if dialog.GetEditBox then
		return dialog:GetEditBox()
	end
	return dialog.editBox
end

local function DialogAccept(dialog)
	if dialog.GetButton1 then
		return dialog:GetButton1()
	end
	return dialog.button1
end

function ns.Config:PurgeLabel(row)
	if not row then
		return L["Saved characters"]
	end
	return string.format("%s   %s", row.label, FormatBytes(row.bytes))
end

function ns.Config:RefreshPurgeList()
	if not self.purgeDrop or not ns.DB or not ns.DB.CharacterList then
		return
	end
	local list = ns.DB:CharacterList()
	local selected
	for i = 1, #list do
		if list[i].key == self.purgeKey then
			selected = list[i]
			break
		end
	end
	if not selected then
		selected = list[1]
		self.purgeKey = selected and selected.key or nil
	end
	self.purgeDrop:SetText(self:PurgeLabel(selected))
	if self.purgeButton then
		if selected then
			self.purgeButton:Enable()
		else
			self.purgeButton:Disable()
		end
	end
	local menu = self.purgeList
	if not menu then
		return
	end
	self.purgeRows = self.purgeRows or {}
	for i = 1, #list do
		local row = self.purgeRows[i]
		if not row then
			row = CreateFrame("Button", nil, menu)
			row:SetHeight(20)
			row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.label:SetPoint("LEFT", 8, 0)
			row.label:SetPoint("RIGHT", -6, 0)
			row.label:SetJustifyH("LEFT")
			row:SetScript("OnClick", function(button)
				ns.Config.purgeKey = button.charKey
				if ns.Config.purgeList then
					ns.Config.purgeList:Hide()
				end
				ns.Config:RefreshPurgeList()
			end)
			self.purgeRows[i] = row
		end
		row.charKey = list[i].key
		row.label:SetText(self:PurgeLabel(list[i]))
		if list[i].key == self.purgeKey then
			row.label:SetTextColor(1, 0.82, 0)
		else
			row.label:SetTextColor(1, 1, 1)
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", menu, "TOPLEFT", 0, -((i - 1) * 20))
		row:SetPoint("RIGHT", menu, "RIGHT", 0, 0)
		row:Show()
	end
	for i = #list + 1, #self.purgeRows do
		self.purgeRows[i]:Hide()
	end
	menu:SetHeight(math.max(22, #list * 20 + 4))
end

function ns.Config:TogglePurgeList()
	local menu = self.purgeList
	if not menu then
		return
	end
	if menu:IsShown() then
		menu:Hide()
		return
	end
	self:RefreshPurgeList()
	menu:Show()
end

function ns.Config:ConfirmPurge()
	if not StaticPopupDialogs or not StaticPopup_Show then
		return
	end
	local key = self.purgeKey
	local journey = key and ZipperDB and ZipperDB.journeys and ZipperDB.journeys[key]
	if type(journey) ~= "table" then
		return
	end
	local label = ns.DB:JourneyLabel(journey)
	if not StaticPopupDialogs.ZIPPER_PURGE then
		StaticPopupDialogs.ZIPPER_PURGE = {
			text = L["Delete %s?\n\nType gone forever to confirm."],
			button1 = L["Delete"],
			button2 = L["Cancel"],
			hasEditBox = true,
			maxLetters = 32,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,
			OnShow = function(dialog)
				local box = DialogEditBox(dialog)
				if box then
					box:SetText("")
					box:SetFocus()
				end
				local accept = DialogAccept(dialog)
				if accept then
					accept:Disable()
				end
			end,
			EditBoxOnTextChanged = function(editBox)
				local dialog = editBox:GetParent()
				local accept = DialogAccept(dialog)
				if accept then
					if PurgePhrase(editBox:GetText()) then
						accept:Enable()
					else
						accept:Disable()
					end
				end
			end,
			OnAccept = function(dialog, data)
				local box = DialogEditBox(dialog)
				if not box or not PurgePhrase(box:GetText()) then
					return
				end
				local which = data or ns.Config.purgeKey
				local gone = which and ZipperDB and ZipperDB.journeys and ZipperDB.journeys[which]
				local name = ns.DB:JourneyLabel(gone)
				if ns.DB:Purge(which) then
					ns.Config.purgeKey = nil
					ns.Config:RefreshSize()
					ns:Print(string.format(L["%s is gone."], name))
				end
			end,
		}
	end
	StaticPopup_Show("ZIPPER_PURGE", label, nil, key)
end

function ns.Config:Toggle()
	self:CreateFrame()
	if Settings and Settings.OpenToCategory and self.category then
		Settings.OpenToCategory(self.category:GetID())
	elseif InterfaceOptionsFrame_OpenToCategory then
		InterfaceOptionsFrame_OpenToCategory(self.frame)
		InterfaceOptionsFrame_OpenToCategory(self.frame)
	end
end

ns.Config:CreateFrame()
