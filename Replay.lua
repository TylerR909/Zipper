local _, ns = ...

ns.Replay = {
	mode = "current",
	playing = false,
	speed = 30,
	speeds = { 1, 10, 30, 120, 600 },
}

local Kind = ns.Kind
local LINE_CAP = 500
local MARKER_CAP = 300
local PATH_COLOR_R, PATH_COLOR_G, PATH_COLOR_B, PATH_COLOR_A = 0.25, 0.85, 1, 0.9
local SPEEDS = ns.Replay.speeds

local function FormatClock(seconds)
	seconds = math.floor(seconds or 0)
	if seconds < 0 then
		seconds = 0
	end
	local hours = math.floor(seconds / 3600)
	local mins = math.floor((seconds % 3600) / 60)
	local secs = seconds % 60
	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, mins, secs)
	end
	return string.format("%d:%02d", mins, secs)
end

local function Bounds(sessions)
	local t0, t1
	local points = 0
	for s = 1, #sessions do
		local session = sessions[s]
		local track = ns.DB:Track(session)
		local n = #track.t
		points = points + n
		if n > 0 then
			local first = session.s + track.t[1]
			local last = session.s + track.t[n]
			if not t0 or first < t0 then
				t0 = first
			end
			if not t1 or last > t1 then
				t1 = last
			end
		end
	end
	return t0, t1, points
end

local function Locate(sessions, epoch)
	local leftS, leftI
	for s = 1, #sessions do
		local session = sessions[s]
		local track = ns.DB:Track(session)
		local n = #track.t
		if n > 0 then
			local first = session.s + track.t[1]
			local last = session.s + track.t[n]
			if epoch <= first then
				return s, 1, s, 1
			end
			if epoch <= last then
				local lo, hi = 1, n
				while lo < hi do
					local mid = math.floor((lo + hi + 1) / 2)
					if session.s + track.t[mid] <= epoch then
						lo = mid
					else
						hi = mid - 1
					end
				end
				local nextI = math.min(lo + 1, n)
				return s, lo, s, nextI
			end
			leftS, leftI = s, n
		end
	end
	if leftS then
		return leftS, leftI, leftS, leftI
	end
	return nil
end

function ns.Replay:Canvas()
	if not WorldMapFrame then
		return nil
	end
	if WorldMapFrame.GetCanvas then
		return WorldMapFrame:GetCanvas()
	end
	if WorldMapFrame.ScrollContainer then
		return WorldMapFrame.ScrollContainer.Child
	end
end

function ns.Replay:EnsureMap()
	if WorldMapFrame then
		return WorldMapFrame
	end
	if C_AddOns and C_AddOns.LoadAddOn then
		C_AddOns.LoadAddOn("Blizzard_WorldMap")
	elseif LoadAddOn then
		LoadAddOn("Blizzard_WorldMap")
	end
	return WorldMapFrame
end

function ns.Replay:Project(mapID, x, y)
	local view = self.mapID
	if not view or not mapID then
		return nil
	end
	if mapID == view then
		return x, y
	end
	local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(mapID, view)
	if not minX or not maxX or not minY or not maxY then
		return nil
	end
	if maxX <= minX or maxY <= minY then
		return nil
	end
	local px = minX + (x * (maxX - minX))
	local py = minY + (y * (maxY - minY))
	if px < -0.02 or px > 1.02 or py < -0.02 or py > 1.02 then
		return nil
	end
	return px, py
end

function ns.Replay:AcquireLine()
	local canvas = self:Canvas()
	local line = self.lines[self.lineUsed + 1]
	if not line then
		line = canvas:CreateTexture(nil, "OVERLAY")
		line:SetTexture("Interface\\BUTTONS\\WHITE8X8")
		line:SetVertexColor(PATH_COLOR_R, PATH_COLOR_G, PATH_COLOR_B, PATH_COLOR_A)
		self.lines[#self.lines + 1] = line
	end
	self.lineUsed = self.lineUsed + 1
	if line:GetParent() ~= canvas then
		line:SetParent(canvas)
	end
	return line
end

function ns.Replay:PlaceLine(line, x1, y1, x2, y2)
	local canvas = self:Canvas()
	local width = canvas:GetWidth()
	local height = canvas:GetHeight()
	if not width or width <= 0 or not height or height <= 0 then
		line:Hide()
		return
	end
	local sx1, sy1 = x1 * width, -y1 * height
	local sx2, sy2 = x2 * width, -y2 * height
	local dx, dy = sx2 - sx1, sy2 - sy1
	local length = math.sqrt((dx * dx) + (dy * dy))
	if length < 1 then
		line:Hide()
		return
	end
	local scale = canvas:GetScale() or 1
	if scale < 0.05 then
		scale = 0.05
	end
	local thick = 2 / scale
	if thick < 1.25 then
		thick = 1.25
	elseif thick > 14 then
		thick = 14
	end
	line:ClearAllPoints()
	line:SetSize(length, thick)
	line:SetPoint("CENTER", canvas, "TOPLEFT", (sx1 + sx2) / 2, (sy1 + sy2) / 2)
	line:SetRotation(math.atan2(dy, dx))
	line:Show()
end

function ns.Replay:HideSpareLines()
	for i = self.lineUsed + 1, #self.lines do
		self.lines[i]:Hide()
	end
end

function ns.Replay:AcquireMarker()
	local canvas = self:Canvas()
	local marker = self.markers[self.markerUsed + 1]
	if not marker then
		marker = CreateFrame("Frame", nil, canvas)
		marker:SetSize(12, 12)
		marker.texture = marker:CreateTexture(nil, "OVERLAY")
		marker.texture:SetAllPoints()
		marker.texture:SetTexture("Interface\\BUTTONS\\WHITE8X8")
		marker:EnableMouse(true)
		marker:SetScript("OnEnter", function(pin)
			if not pin.kind then
				return
			end
			GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
			GameTooltip:SetText(ns.KindName[pin.kind] or "Event", 1, 0.9, 0.4)
			if pin.extra and (pin.kind == Kind.QUEST_ACCEPT or pin.kind == Kind.QUEST_TURNIN) and pin.extra > 0 then
				local title = C_QuestLog.GetTitleForQuestID(pin.extra)
				GameTooltip:AddLine(title or ("Quest " .. pin.extra), 1, 1, 1)
			elseif pin.kind == Kind.ZONE and pin.mapID then
				local info = C_Map.GetMapInfo(pin.mapID)
				GameTooltip:AddLine((info and info.name) or ("Map " .. pin.mapID), 1, 1, 1)
			elseif (pin.kind == Kind.INSTANCE_ENTER or pin.kind == Kind.INSTANCE_LEAVE) and pin.extra and pin.extra > 0 then
				GameTooltip:AddLine(ns.InstanceName[pin.extra] or "Instance", 1, 1, 1)
			end
			if pin.when then
				GameTooltip:AddLine(date("%m/%d %H:%M", pin.when), 0.7, 0.7, 0.7)
			end
			GameTooltip:Show()
		end)
		marker:SetScript("OnLeave", function(pin)
			if GameTooltip:IsOwned(pin) then
				GameTooltip:Hide()
			end
		end)
		self.markers[#self.markers + 1] = marker
	end
	self.markerUsed = self.markerUsed + 1
	if marker:GetParent() ~= canvas then
		marker:SetParent(canvas)
	end
	return marker
end

function ns.Replay:HideSpareMarkers()
	for i = self.markerUsed + 1, #self.markers do
		self.markers[i]:Hide()
		self.markers[i].kind = nil
	end
end

function ns.Replay:CollectPath(sessions, minDist)
	local xs, ys, brk = {}, {}, {}
	local n = 0
	local prevT
	local lastX, lastY
	local open = false
	local minDistSq = minDist * minDist
	for s = 1, #sessions do
		local session = sessions[s]
		local track = ns.DB:Track(session)
		for i = 1, #track.t do
			local t = session.s + track.t[i]
			local px, py = self:Project(track.m[i], track.x[i] / ns.COORD_SCALE, track.y[i] / ns.COORD_SCALE)
			local gap = prevT and (t - prevT) > ns.CONTINUE_SECONDS
			if not px or gap then
				open = false
			else
				local keep = not open
				if open then
					local dx, dy = px - lastX, py - lastY
					keep = (dx * dx + dy * dy) >= minDistSq
				end
				if keep then
					n = n + 1
					xs[n] = px
					ys[n] = py
					brk[n] = not open
					lastX, lastY = px, py
					open = true
				end
			end
			prevT = t
		end
	end
	return xs, ys, brk, n
end

function ns.Replay:DrawPath(sessions)
	local minDist = 0.0015
	local xs, ys, brk, n
	for _ = 1, 5 do
		xs, ys, brk, n = self:CollectPath(sessions, minDist)
		if n <= LINE_CAP then
			break
		end
		minDist = minDist * 2
	end
	self.lineUsed = 0
	local canvas = self:Canvas()
	if not canvas or canvas:GetWidth() <= 0 then
		self:HideSpareLines()
		return
	end
	for i = 2, n do
		if not brk[i] then
			local line = self:AcquireLine()
			self:PlaceLine(line, xs[i - 1], ys[i - 1], xs[i], ys[i])
		end
	end
	self:HideSpareLines()
end

function ns.Replay:DrawMarkers(sessions)
	self.markerUsed = 0
	if not ns.Config:ShowMarkers() then
		self:HideSpareMarkers()
		return
	end
	local canvas = self:Canvas()
	if not canvas or canvas:GetWidth() <= 0 then
		self:HideSpareMarkers()
		return
	end
	local width, height = canvas:GetWidth(), canvas:GetHeight()
	local shown = 0
	for s = #sessions, 1, -1 do
		local session = sessions[s]
		local track = ns.DB:Track(session)
		for i = #track.ek, 1, -1 do
			if shown >= MARKER_CAP then
				break
			end
			local px, py = self:Project(track.em[i], track.ex[i] / ns.COORD_SCALE, track.ey[i] / ns.COORD_SCALE)
			if px then
				shown = shown + 1
				local marker = self:AcquireMarker()
				local color = ns.KindColor[track.ek[i]] or { 1, 1, 1 }
				marker.texture:SetVertexColor(color[1], color[2], color[3], 1)
				marker.kind = track.ek[i]
				marker.extra = track.ea[i]
				marker.mapID = track.em[i]
				marker.when = session.s + track.et[i]
				marker:ClearAllPoints()
				marker:SetPoint("CENTER", canvas, "TOPLEFT", px * width, -py * height)
				marker:SetFrameLevel((canvas:GetFrameLevel() or 1) + 30)
				marker:Show()
			end
		end
	end
	self:HideSpareMarkers()
end

function ns.Replay:PositionDot(x, y)
	local canvas = self:Canvas()
	if not canvas or not self.dot then
		return
	end
	local width, height = canvas:GetWidth(), canvas:GetHeight()
	if not width or width <= 0 then
		self.dot:Hide()
		return
	end
	if self.dot:GetParent() ~= canvas then
		self.dot:SetParent(canvas)
	end
	local scale = canvas:GetScale() or 1
	if scale < 0.05 then
		scale = 0.05
	end
	local size = 10 / scale
	if size < 6 then
		size = 6
	elseif size > 28 then
		size = 28
	end
	self.dot:SetSize(size, size)
	self.dot:ClearAllPoints()
	self.dot:SetPoint("CENTER", canvas, "TOPLEFT", x * width, -y * height)
	self.dot:SetFrameLevel((canvas:GetFrameLevel() or 1) + 40)
	self.dot:Show()
end

function ns.Replay:SampleXY(session, index)
	local track = ns.DB:Track(session)
	return track.m[index], track.x[index] / ns.COORD_SCALE, track.y[index] / ns.COORD_SCALE, session.s + track.t[index]
end

function ns.Replay:PlayheadPlace()
	local sessions = self.sessions
	if not sessions or not self.playhead then
		return nil
	end
	local s1, i1, s2, i2 = Locate(sessions, self.playhead)
	if not s1 then
		return nil
	end
	local map1, x1, y1, t1 = self:SampleXY(sessions[s1], i1)
	local map2, x2, y2, t2 = self:SampleXY(sessions[s2], i2)
	local mapID, x, y = map1, x1, y1
	if map1 == map2 and t2 > t1 then
		local alpha = (self.playhead - t1) / (t2 - t1)
		if alpha < 0 then
			alpha = 0
		elseif alpha > 1 then
			alpha = 1
		end
		x = x1 + ((x2 - x1) * alpha)
		y = y1 + ((y2 - y1) * alpha)
	elseif self.playhead >= t2 then
		mapID, x, y = map2, x2, y2
	end
	return mapID, x, y
end

function ns.Replay:UpdateDot()
	local mapID, x, y = self:PlayheadPlace()
	if not mapID then
		if self.dot then
			self.dot:Hide()
		end
		return
	end
	local px, py = self:Project(mapID, x, y)
	if not px then
		if self.dot then
			self.dot:Hide()
		end
		return
	end
	self:PositionDot(px, py)
end

function ns.Replay:Summarize(sessions)
	local afk, dungeon, raid = 0, 0, 0
	local afkStart, instStart, instType
	local lastT = self.t1
	for s = 1, #sessions do
		local session = sessions[s]
		local track = ns.DB:Track(session)
		for i = 1, #track.ek do
			local kind = track.ek[i]
			local t = session.s + track.et[i]
			local extra = track.ea[i]
			if kind == Kind.AFK_START then
				afkStart = t
			elseif kind == Kind.AFK_END and afkStart then
				afk = afk + (t - afkStart)
				afkStart = nil
			elseif kind == Kind.INSTANCE_ENTER then
				instStart = t
				instType = extra
			elseif kind == Kind.INSTANCE_LEAVE and instStart then
				local span = t - instStart
				if instType == ns.Instance.RAID then
					raid = raid + span
				elseif instType == ns.Instance.PARTY then
					dungeon = dungeon + span
				end
				instStart = nil
				instType = nil
			end
		end
	end
	if afkStart and lastT and lastT > afkStart then
		afk = afk + (lastT - afkStart)
	end
	if instStart and lastT and lastT > instStart then
		local span = lastT - instStart
		if instType == ns.Instance.RAID then
			raid = raid + span
		elseif instType == ns.Instance.PARTY then
			dungeon = dungeon + span
		end
	end
	return afk, dungeon, raid
end

function ns.Replay:UpdateRecap(sessions)
	if not self.summaryText then
		return
	end
	sessions = sessions or self.sessions or {}
	local recap = ns.DB:RecapText(sessions)
	if not self.t0 or not self.t1 then
		self.summaryText:SetText(recap)
		return
	end
	local afk, dungeon, raid = self:Summarize(sessions)
	self.summaryText:SetText(string.format("%s\nAFK %s    Dungeons %s    Raids %s", recap, FormatClock(afk), FormatClock(dungeon), FormatClock(raid)))
end

function ns.Replay:UpdateReadout()
	if not self.timeText then
		return
	end
	local sessions = self.sessions or {}
	if not self.t0 or not self.t1 then
		self.timeText:SetText("No path yet. Walk somewhere and Zipper will keep the points.")
		self:UpdateRecap(sessions)
		self.playButton:SetText("Play")
		return
	end
	local at = self.playhead or self.t0
	local span = self.t1 - self.t0
	if span < 0 then
		span = 0
	end
	self.timeText:SetText(string.format("%s  /  %s    %dx", FormatClock(at - self.t0), FormatClock(span), self.speed))
	self:UpdateRecap(sessions)
	if not self.playing then
		self.playButton:SetText("Play")
	end
	self:UpdateScrub()
end

function ns.Replay:UpdateScrub()
	local scrub = self.scrub
	if not scrub or not self.t0 or not self.t1 or self.t1 <= self.t0 then
		return
	end
	local fraction = (self.playhead - self.t0) / (self.t1 - self.t0)
	if fraction < 0 then
		fraction = 0
	elseif fraction > 1 then
		fraction = 1
	end
	self.lockScrub = true
	scrub:SetValue(fraction)
	self.lockScrub = false
end

function ns.Replay:SeekFraction(fraction)
	if not self.t0 or not self.t1 then
		return
	end
	self.playhead = self.t0 + ((self.t1 - self.t0) * fraction)
	self:UpdateDot()
	self:UpdateReadout()
end

function ns.Replay:ReloadView()
	local followTail = (not self.playing) and self.playhead and self.t1 and math.abs(self.playhead - self.t1) < 1
	local sessions, index = ns.DB:SelectSessions(self.mode, self.index)
	self.sessions = sessions
	self.index = index
	local t0, t1 = Bounds(sessions)
	self.t0, self.t1 = t0, t1
	if not self.playhead or not t0 then
		self.playhead = t1 or t0
	elseif followTail or self.playhead < t0 then
		self.playhead = t1
	elseif self.playhead > t1 then
		self.playhead = t1
	end
	self:RefreshList()
	self:UpdateReadout()
end

function ns.Replay:ClearOverlay()
	self.lineUsed = 0
	self.markerUsed = 0
	if self.lines then
		self:HideSpareLines()
	end
	if self.markers then
		self:HideSpareMarkers()
	end
	if self.dot then
		self.dot:Hide()
	end
end

function ns.Replay:Redraw()
	if not self.frame or not self.frame:IsShown() then
		self:ClearOverlay()
		return
	end
	local map = self:EnsureMap()
	if self.playing and map and map:IsShown() and map.GetMapID and map.SetMapID and not self.settingMap then
		local desired = self:PlayheadPlace()
		local current = map:GetMapID()
		if desired and current and desired ~= current then
			self.settingMap = true
			map:SetMapID(desired)
			self.settingMap = false
			if map:GetMapID() ~= current then
				return
			end
		end
	end
	self.mapID = map and map.GetMapID and map:GetMapID() or nil
	local canvas = self:Canvas()
	if not map or not map:IsShown() or not canvas or canvas:GetWidth() <= 0 then
		self:ClearOverlay()
		return
	end
	local sessions = self.sessions or {}
	self:DrawPath(sessions)
	self:DrawMarkers(sessions)
	self:UpdateDot()
	self.dirty = false
	self.lastRedraw = GetTime()
end

function ns.Replay:OnDataChanged()
	if not self.frame or not self.frame:IsShown() then
		self.dirty = true
		return
	end
	if self.mode ~= "current" and self.mode ~= "all" then
		self.dirty = true
		return
	end
	if GetTime() - (self.lastRedraw or 0) < 0.5 then
		self.dirty = true
		return
	end
	self:ReloadView()
	self:Redraw()
end

function ns.Replay:SetMode(mode, index)
	self.mode = mode
	self.index = index
	self.playing = false
	self:ReloadView()
	if self.t1 then
		self.playhead = self.t1
	end
	self:StyleModeButtons()
	self:UpdateReadout()
	self:Redraw()
end

function ns.Replay:StyleModeButtons()
	local function paint(button, active)
		local font = button:GetFontString()
		if font then
			if active then
				font:SetTextColor(1, 0.9, 0.4)
			else
				font:SetTextColor(1, 1, 1)
			end
		end
	end
	paint(self.sessionButton, self.mode == "current")
	paint(self.journeyButton, self.mode == "all")
end

function ns.Replay:RefreshList()
	local content = self.listContent
	if not content then
		return
	end
	local sessions = ns.DB:Sessions()
	local width = content:GetWidth()
	if width < 40 then
		width = 250
	end
	for i = 1, #sessions do
		local index = #sessions - i + 1
		local session = sessions[index]
		local row = self.rows[i]
		if not row then
			row = CreateFrame("Button", nil, content)
			row:SetHeight(18)
			row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.label:SetAllPoints()
			row.label:SetJustifyH("LEFT")
			row:SetScript("OnClick", function(button)
				ns.Replay:SetMode("one", button.sessionIndex)
			end)
			self.rows[i] = row
		end
		row.sessionIndex = index
		local duration = (session.seen or session.s) - session.s
		local selected = (self.mode == "one" and self.index == index) or (self.mode == "current" and session == ns.DB:Current())
		local prefix = selected and "> " or "  "
		local gained = ns.DB:LevelsGained(session)
		row.label:SetText(string.format("%s%s   %s   +%.2f lv   %d kills", prefix, date("%m/%d %H:%M", session.s), FormatClock(duration), gained, session.kills or 0))
		if selected then
			row.label:SetTextColor(1, 0.9, 0.4)
		else
			row.label:SetTextColor(0.85, 0.85, 0.85)
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((i - 1) * 18))
		row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
		row:Show()
	end
	for i = #sessions + 1, #self.rows do
		self.rows[i]:Hide()
	end
	content:SetHeight(math.max(18, #sessions * 18))
end

function ns.Replay:TogglePlay()
	if not self.t0 or not self.t1 then
		return
	end
	if self.playing then
		self.playing = false
		self.playButton:SetText("Play")
		return
	end
	if self.playhead >= self.t1 - 0.05 then
		self.playhead = self.t0
	end
	self.playing = true
	self.playButton:SetText("Pause")
	local map = self:EnsureMap()
	if map and not map:IsShown() and ToggleWorldMap then
		ToggleWorldMap()
	end
end

function ns.Replay:CycleSpeed()
	local nextSpeed = SPEEDS[1]
	for i = 1, #SPEEDS do
		if SPEEDS[i] == self.speed then
			nextSpeed = SPEEDS[(i % #SPEEDS) + 1]
			break
		end
	end
	self.speed = nextSpeed
	self.speedButton:SetText(self.speed .. "x")
	self:UpdateReadout()
end

function ns.Replay:OnUpdate(_, elapsed)
	if GetTime() - (self.readoutAt or 0) >= 0.5 then
		self.readoutAt = GetTime()
		self:UpdateRecap()
		self:RefreshList()
	end
	if self.dirty and (GetTime() - (self.lastRedraw or 0)) >= 0.5 then
		self:ReloadView()
		self:Redraw()
	end
	if not self.playing or not self.t0 then
		return
	end
	self.playhead = self.playhead + (elapsed * self.speed)
	if self.playhead >= self.t1 then
		self.playhead = self.t1
		self.playing = false
		self.playButton:SetText("Play")
	end
	self:UpdateDot()
	self:UpdateReadout()
end

function ns.Replay:HookMap()
	if self.mapHooked or not WorldMapFrame then
		return
	end
	self.mapHooked = true
	if WorldMapFrame.OnMapChanged then
		hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
			ns.Replay:Redraw()
		end)
	end
	WorldMapFrame:HookScript("OnHide", function()
		ns.Replay.playing = false
		if ns.Replay.playButton then
			ns.Replay.playButton:SetText("Play")
		end
		ns.Replay:ClearOverlay()
	end)
	local canvas = self:Canvas()
	if canvas then
		canvas:HookScript("OnSizeChanged", function()
			ns.Replay:Redraw()
		end)
	end
end

function ns.Replay:CreateFrame()
	if self.frame then
		return
	end
	local frame = CreateFrame("Frame", "ZipperReplayFrame", UIParent, "BackdropTemplate")
	frame:Hide()
	frame:SetSize(300, 448)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true,
		tileSize = 32,
		edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, _, x, y = self:GetPoint(1)
		ZipperDB = ZipperDB or {}
		ZipperDB.window = { point = point, x = x, y = y }
	end)
	frame:SetScript("OnShow", function()
		ns.Replay:HookMap()
		ns.Replay:EnsureDot()
		ns.Replay:ReloadView()
		ns.Replay:Redraw()
	end)
	frame:SetScript("OnHide", function()
		ns.Replay.playing = false
		ns.Replay:ClearOverlay()
	end)
	frame:SetScript("OnUpdate", function(self, elapsed)
		ns.Replay:OnUpdate(self, elapsed)
	end)
	tinsert(UISpecialFrames, "ZipperReplayFrame")

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 18, -16)
	title:SetText("Zipper")

	local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("TOPLEFT", 18, -36)
	hint:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	hint:SetJustifyH("LEFT")
	hint:SetText("Replay draws on the world map.")

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	local options = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	options:SetSize(70, 20)
	options:SetPoint("RIGHT", close, "LEFT", 2, 0)
	options:SetText("Options")
	options:SetScript("OnClick", function()
		ns.Config:Toggle()
	end)

	local sessionButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	sessionButton:SetSize(120, 22)
	sessionButton:SetPoint("TOPLEFT", 18, -58)
	sessionButton:SetText("This session")
	sessionButton:SetScript("OnClick", function()
		ns.Replay:SetMode("current")
	end)

	local journeyButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	journeyButton:SetSize(120, 22)
	journeyButton:SetPoint("LEFT", sessionButton, "RIGHT", 8, 0)
	journeyButton:SetText("Journey")
	journeyButton:SetScript("OnClick", function()
		ns.Replay:SetMode("all")
	end)

	local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 18, -88)
	scroll:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -32, -250)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(250, 18)
	scroll:SetScrollChild(content)

	local play = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	play:SetSize(72, 22)
	play:SetPoint("TOPLEFT", 18, -262)
	play:SetText("Play")
	play:SetScript("OnClick", function()
		ns.Replay:TogglePlay()
	end)

	local speed = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	speed:SetSize(64, 22)
	speed:SetPoint("LEFT", play, "RIGHT", 8, 0)
	speed:SetText(self.speed .. "x")
	speed:SetScript("OnClick", function()
		ns.Replay:CycleSpeed()
	end)

	local scrub = CreateFrame("Slider", "ZipperReplayScrub", frame, "UISliderTemplate")
	scrub:SetPoint("TOPLEFT", 24, -300)
	scrub:SetPoint("RIGHT", frame, "RIGHT", -24, 0)
	scrub:SetHeight(16)
	scrub:SetMinMaxValues(0, 1)
	scrub:SetValueStep(0.001)
	scrub:SetValue(1)
	scrub:SetObeyStepOnDrag(true)
	scrub:SetScript("OnValueChanged", function(_, value)
		if ns.Replay.lockScrub then
			return
		end
		ns.Replay.playing = false
		if ns.Replay.playButton then
			ns.Replay.playButton:SetText("Play")
		end
		ns.Replay:SeekFraction(value)
	end)

	local timeText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	timeText:SetPoint("TOPLEFT", 18, -324)
	timeText:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	timeText:SetJustifyH("LEFT")

	local summary = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	summary:SetPoint("TOPLEFT", 18, -344)
	summary:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	summary:SetJustifyH("LEFT")
	summary:SetJustifyV("TOP")

	self.frame = frame
	self.sessionButton = sessionButton
	self.journeyButton = journeyButton
	self.listContent = content
	self.rows = {}
	self.playButton = play
	self.speedButton = speed
	self.scrub = scrub
	self.timeText = timeText
	self.summaryText = summary
	self.lines = {}
	self.markers = {}
	self.lineUsed = 0
	self.markerUsed = 0

	local window = ZipperDB and ZipperDB.window
	frame:ClearAllPoints()
	if window and window.point then
		frame:SetPoint(window.point, UIParent, window.point, window.x or 0, window.y or 0)
	else
		frame:SetPoint("RIGHT", UIParent, "RIGHT", -40, 40)
	end
end

function ns.Replay:EnsureDot()
	local canvas = self:Canvas()
	if not canvas or self.dot then
		return
	end
	local dot = CreateFrame("Frame", nil, canvas)
	dot:SetSize(12, 12)
	dot.texture = dot:CreateTexture(nil, "OVERLAY")
	dot.texture:SetAllPoints()
	dot.texture:SetTexture("Interface\\BUTTONS\\WHITE8X8")
	dot.texture:SetVertexColor(1, 0.82, 0.2, 1)
	dot:EnableMouse(false)
	self.dot = dot
end

function ns.Replay:Toggle()
	self:CreateFrame()
	if self.frame:IsShown() then
		self.playing = false
		self.frame:Hide()
		return
	end
	local map = self:EnsureMap()
	if map and not map:IsShown() and ToggleWorldMap then
		ToggleWorldMap()
	end
	self:HookMap()
	self:EnsureDot()
	self.frame:Show()
	self:SetMode(self.mode or "current", self.index)
end

function ns.Replay:Init()
	ns.OnDataChanged = function()
		ns.Replay:OnDataChanged()
	end
end
