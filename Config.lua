local _, ns = ...

ns.Config = {}

local TRACK_DEFAULTS = {
	path = true,
	kills = true,
	questAccept = true,
	questTurnin = true,
	death = true,
	summon = true,
	hearth = true,
	flight = true,
	mount = true,
	afk = true,
	instance = true,
	zone = true,
}

local KIND_KEY = {
	[ns.Kind.KILL] = "kills",
	[ns.Kind.QUEST_ACCEPT] = "questAccept",
	[ns.Kind.QUEST_TURNIN] = "questTurnin",
	[ns.Kind.DEATH] = "death",
	[ns.Kind.SUMMON] = "summon",
	[ns.Kind.HEARTH] = "hearth",
	[ns.Kind.FLIGHT_START] = "flight",
	[ns.Kind.FLIGHT_END] = "flight",
	[ns.Kind.MOUNT] = "mount",
	[ns.Kind.DISMOUNT] = "mount",
	[ns.Kind.AFK_START] = "afk",
	[ns.Kind.AFK_END] = "afk",
	[ns.Kind.INSTANCE_ENTER] = "instance",
	[ns.Kind.INSTANCE_LEAVE] = "instance",
	[ns.Kind.ZONE] = "zone",
}

local TRACKS = {
	{ key = "kills", label = "Kills" },
	{ key = "questAccept", label = "Quest pickups" },
	{ key = "questTurnin", label = "Quest turn-ins" },
	{ key = "death", label = "Deaths" },
	{ key = "summon", label = "Summons" },
	{ key = "hearth", label = "Hearths" },
	{ key = "flight", label = "Flights" },
	{ key = "mount", label = "Mount and dismount" },
	{ key = "afk", label = "AFK" },
	{ key = "instance", label = "Dungeons and raids" },
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
		return "1 hour"
	end
	if minutes % 60 == 0 then
		return (minutes / 60) .. " hours"
	end
	if minutes > 60 then
		return string.format("%d hr %d min", math.floor(minutes / 60), minutes % 60)
	end
	return minutes .. " min"
end

function ns.Config:ReminderText()
	local minutes = self:Get().remindMinutes
	local span
	if minutes == 60 then
		span = "an hour"
	elseif minutes % 60 == 0 then
		span = (minutes / 60) .. " hours"
	else
		span = minutes .. " minutes"
	end
	return string.format("Zipper has accumulated %s of data which can be lost. Suggest `/reload` to save it forever.", span)
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

local function AddCheck(parent, name, label, x, y)
	local box = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
	box:SetPoint("TOPLEFT", x, y)
	local text = CheckText(box)
	if text then
		text:SetText(label)
	end
	return box
end

function ns.Config:CreateFrame()
	if self.frame then
		return
	end
	-- Same registration Forever Quest Tint uses. The name is what the AddOns list shows.
	local canvas = CreateFrame("Frame")
	canvas.name = "Zipper"
	local scroll = CreateFrame("ScrollFrame", nil, canvas, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 0, -4)
	scroll:SetPoint("BOTTOMRIGHT", -28, 4)
	local panel = CreateFrame("Frame", nil, scroll)
	panel:SetSize(640, 640)
	scroll:SetScrollChild(panel)

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Zipper")

	local sub = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
	sub:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
	sub:SetJustifyH("LEFT")
	sub:SetText("Records this character's journey and replays it on the world map.")

	local remind = AddCheck(panel, "ZipperConfigRemind", "Remind me to /reload", 12, -72)
	remind:SetScript("OnClick", function(self)
		ns.Config:SetRemind(self:GetChecked())
	end)

	local slider = CreateFrame("Slider", "ZipperConfigRemindSlider", panel, "UISliderTemplate")
	slider:SetPoint("TOPLEFT", 28, -112)
	slider:SetSize(220, 16)
	slider:SetMinMaxValues(30, 180)
	slider:SetValueStep(15)
	slider:SetObeyStepOnDrag(true)
	local lowLabel = slider.Low or _G[slider:GetName() .. "Low"]
	local highLabel = slider.High or _G[slider:GetName() .. "High"]
	local titleLabel = slider.Text or _G[slider:GetName() .. "Text"]
	if lowLabel then
		lowLabel:Hide()
	end
	if highLabel then
		highLabel:Hide()
	end
	if titleLabel then
		titleLabel:Hide()
	end
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

	local valueText = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	valueText:SetPoint("LEFT", slider, "RIGHT", 16, 0)
	valueText:SetText("1 hour")

	local record = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	record:SetPoint("TOPLEFT", 16, -156)
	record:SetText("Record")

	local path = AddCheck(panel, "ZipperConfigPath", "Movement", 12, -180)
	path:SetScript("OnClick", function(self)
		ns.Config:SetTrack("path", self:GetChecked())
	end)

	local boxes = { remind = remind, path = path }
	for i = 1, #TRACKS do
		local entry = TRACKS[i]
		local box = AddCheck(panel, "ZipperConfig" .. entry.key, entry.label, 12, -180 - (i * 28))
		box.trackKey = entry.key
		box:SetScript("OnClick", function(self)
			ns.Config:SetTrack(self.trackKey, self:GetChecked())
		end)
		boxes[entry.key] = box
	end

	local markerY = -180 - ((#TRACKS + 1) * 28)
	local markers = AddCheck(panel, "ZipperConfigMarkers", "Show event markers on the map", 12, markerY)
	markers:SetScript("OnClick", function(self)
		ns.Config:SetShowMarkers(self:GetChecked())
	end)
	boxes.showMarkers = markers

	local note = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	note:SetPoint("TOPLEFT", markers, "BOTTOMLEFT", 4, -8)
	note:SetWidth(420)
	note:SetJustifyH("LEFT")
	note:SetText("Unchecking a type stops new records of it. Saved history stays.")

	canvas:SetScript("OnShow", function()
		ns.Config:Refresh()
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
	self.boxes = boxes
end

function ns.Config:Refresh()
	if not self.boxes then
		return
	end
	local cfg = self:Get()
	self.boxes.remind:SetChecked(cfg.remind)
	self.boxes.path:SetChecked(self:Enabled("path"))
	self.boxes.showMarkers:SetChecked(self:ShowMarkers())
	for i = 1, #TRACKS do
		local key = TRACKS[i].key
		self.boxes[key]:SetChecked(self:Enabled(key))
	end
	self:RefreshSlider()
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
