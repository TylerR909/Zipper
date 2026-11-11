local _, ns = ...
local L = ns.L

ns.Replay = {
	mode = "current",
	playing = false,
	speed = 30,
	speeds = { 1, 10, 30, 120, 600 },
}

-- Minutes of trail behind the playhead. 0 is the whole selected journey.
ns.Replay.TRAIL_STOPS = { 2, 3, 5, 10, 15, 20, 30, 45, 60, 0 }

local Kind = ns.Kind
local PIP = 6
local KILL_PIP = 5
local ELITE_PIP = 8
local KILL_CAP = 800
local PARK_SECONDS = 20
local PARK_DIST = 0.0035
local TRAVEL_GAP = 20
local STAY_SECONDS = 240
-- Camp/sleep stats: drop spans that moved, and brief Boosted Rest stop-loot flicker.
local REST_STILL = PARK_DIST * 2
local REST_STAT_MIN = 30
local CHAPTER_MERGE = 90
-- Previous-chapter: restart current unless near its start (timeline × speed) or
-- a Previous click just restarted it (wall clock). High speeds outrun a fixed 1s.
local CHAPTER_PREV_WALL = 1
local CHAPTER_PREV_GRACE = 0.75
local LINE_CAP = 500
local MARKER_CAP = 300
local PATH_COLOR_R, PATH_COLOR_G, PATH_COLOR_B, PATH_COLOR_A = 0.25, 0.85, 1, 0.9
local SPEEDS = ns.Replay.speeds

local function PlainNumber(value)
	return type(value) == "number" and not (issecretvalue and issecretvalue(value))
end

local function Comma(value)
	local text = tostring(math.floor(value or 0))
	while true do
		local replaced
		text, replaced = string.gsub(text, "^(-?%d+)(%d%d%d)", "%1,%2")
		if replaced == 0 then
			break
		end
	end
	return text
end

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
	return ns.Map:Use():Canvas()
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

function ns.Replay:PathLayer()
	local canvas = self:Canvas()
	if not canvas then
		return nil
	end
	local layer = self.pathLayer
	if not layer then
		layer = CreateFrame("Frame", nil, canvas)
		layer:EnableMouse(false)
		self.pathLayer = layer
	end
	if layer:GetParent() ~= canvas then
		layer:SetParent(canvas)
	end
	-- ClearAllPoints on a rect that already resolved leaves that rect up for
	-- the rest of the frame. Re-applying it for every segment made the layer
	-- jump, and every line on it with it.
	if not layer:GetPoint() then
		layer:SetAllPoints(canvas)
	end
	local level = ns.Map:Use():OverlayLevel(canvas)
	if layer:GetFrameLevel() ~= level then
		layer:SetFrameLevel(level)
	end
	layer:EnableMouse(false)
	layer:Show()
	return layer
end

function ns.Replay:EnsurePools()
	if not self.lines then
		self.lines = {}
		self.lineUsed = 0
	end
	if not self.markers then
		self.markers = {}
		self.markerUsed = 0
	end
end

function ns.Replay:AcquireLine()
	local layer = self:PathLayer()
	if not layer then
		return nil
	end
	self:EnsurePools()
	local line = self.lines[self.lineUsed + 1]
	if not line then
		-- A rotated texture keeps its old rect for one frame after SetPoint,
		-- so a reused segment flashes where it used to be and then snaps down.
		line = layer:CreateLine(nil, "OVERLAY")
		line:SetColorTexture(PATH_COLOR_R, PATH_COLOR_G, PATH_COLOR_B, PATH_COLOR_A)
		line:SetSnapToPixelGrid(false)
		line:SetTexelSnappingBias(0)
		self.lines[#self.lines + 1] = line
	end
	self.lineUsed = self.lineUsed + 1
	if line:GetParent() ~= layer then
		line:SetParent(layer)
	end
	return line
end

function ns.Replay:LineLook(mode, speed)
	local heat = ((speed or 100) - 100) / 250
	if heat < 0 then
		heat = 0
	elseif heat > 1 then
		heat = 1
	end
	local thin = 1 - (0.4 * heat)
	if mode == ns.Travel.GHOST then
		if ns.Config:GhostRed() then
			return 0.55, 0.16, 0.16, 0.9, 1
		end
		return 0.42, 0.42, 0.46, 0.85, 1
	end
	if mode == ns.Travel.FLIGHT then
		return 0.62, 0.38, 1, 0.95, 0.7
	end
	if mode == ns.Travel.MOUNT then
		return 0.95, 0.72 - (0.38 * heat), 0.22, 0.92, thin
	end
	local cr, cg, cb = self:ClassColor()
	local lift = 0.28 * heat
	return cr + ((1 - cr) * lift), cg + ((1 - cg) * lift), cb + ((1 - cb) * lift), 0.92, thin
end

function ns.Replay:InferModes(track)
	local modes = {}
	local taxi, mounted = false, false
	local eventIndex = 1
	local eventCount = track.ek and #track.ek or 0
	for i = 1, #track.t do
		local at = track.t[i]
		while eventIndex <= eventCount and (track.et[eventIndex] or 0) <= at do
			local kind = track.ek[eventIndex]
			if kind == ns.Kind.FLIGHT_START then
				taxi = true
			elseif kind == ns.Kind.FLIGHT_END then
				taxi = false
			elseif kind == ns.Kind.MOUNT then
				mounted = true
			elseif kind == ns.Kind.DISMOUNT then
				mounted = false
			end
			eventIndex = eventIndex + 1
		end
		if taxi then
			modes[i] = ns.Travel.FLIGHT
		elseif mounted then
			modes[i] = ns.Travel.MOUNT
		else
			modes[i] = ns.Travel.FOOT
		end
	end
	return modes
end

function ns.Replay:PlaceLine(line, x1, y1, x2, y2, mode, speed, trailAlpha)
	local parent = line:GetParent()
	local width = parent and parent:GetWidth()
	local height = parent and parent:GetHeight()
	if not width or width <= 0 or not height or height <= 0 then
		line:Hide()
		return false
	end
	local sx1, sy1 = x1 * width, -y1 * height
	local sx2, sy2 = x2 * width, -y2 * height
	local dx, dy = sx2 - sx1, sy2 - sy1
	local length = math.sqrt((dx * dx) + (dy * dy))
	if length < 1 then
		line:Hide()
		return false
	end
	local canvas = self:Canvas()
	local scale = (canvas and canvas:GetScale()) or 1
	if scale < 0.05 then
		scale = 0.05
	end
	local r, g, b, a, mul = self:LineLook(mode, speed)
	if trailAlpha == nil then
		trailAlpha = 1
	end
	a = (a or 0.9) * trailAlpha
	local thick = (2 * (mul or 1)) / scale
	if thick < 1 then
		thick = 1
	elseif thick > 14 then
		thick = 14
	end
	line:SetThickness(thick)
	line:SetStartPoint("TOPLEFT", parent, sx1, sy1)
	line:SetEndPoint("TOPLEFT", parent, sx2, sy2)
	line:SetColorTexture(r, g, b, a or 0.9)
	if a < 0.03 then
		line:Hide()
		return true
	end
	line:Show()
	return true
end

function ns.Replay:HideSpareLines()
	if not self.lines then
		return
	end
	for i = self.lineUsed + 1, #self.lines do
		self.lines[i]:Hide()
	end
end

function ns.Replay:AcquireMarker()
	local canvas = self:Canvas()
	if not canvas then
		return nil
	end
	self:EnsurePools()
	local marker = self.markers[self.markerUsed + 1]
	if not marker then
		marker = CreateFrame("Frame", nil, canvas)
		marker:SetSize(12, 12)
		marker.texture = marker:CreateTexture(nil, "OVERLAY")
		marker.texture:SetAllPoints()
		marker.texture:SetTexture("Interface\\BUTTONS\\WHITE8X8")
		marker:EnableMouse(true)
		marker.zipperPin = true
		marker:SetScript("OnEnter", function(pin)
			if not pin.kind then
				return
			end
			GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
			if pin.kind == Kind.KILL then
				local mobID, elite, rare = ns.DB:ReadKill(pin.extra)
				local title = L["Kill"]
				if elite and rare then
					title = L["Rare elite kill"]
				elseif elite then
					title = L["Elite kill"]
				elseif rare then
					title = L["Rare kill"]
				end
				GameTooltip:SetText(title, 1, 0.25, 0.2)
				if mobID > 0 then
					GameTooltip:AddLine(string.format(L["Mob %d"], mobID), 1, 1, 1)
				end
			elseif pin.kind == Kind.GROUP then
				ns.Replay:GroupTooltip(pin)
			elseif pin.kind == Kind.PORTAL or pin.kind == Kind.TRAINER or pin.kind == Kind.SUMMON or pin.kind == Kind.CAMP or pin.kind == Kind.SLEEP then
				ns.Replay:TravelTooltip(pin)
			else
				GameTooltip:SetText(ns.KindName[pin.kind] or L["Event"], 1, 0.9, 0.4)
			end
			if pin.kind == Kind.LEVEL and pin.extra and pin.extra > 0 then
				GameTooltip:AddLine(string.format(L["Reached level %d"], pin.extra), 1, 1, 1)
			elseif pin.extra and (pin.kind == Kind.QUEST_ACCEPT or pin.kind == Kind.QUEST_TURNIN) and pin.extra > 0 then
				local title = C_QuestLog.GetTitleForQuestID(pin.extra)
				GameTooltip:AddLine(title or string.format(L["Quest %d"], pin.extra), 1, 1, 1)
			elseif pin.kind == Kind.ZONE and pin.mapID then
				local info = C_Map.GetMapInfo(pin.mapID)
				GameTooltip:AddLine((info and info.name) or string.format(L["Map %d"], pin.mapID), 1, 1, 1)
			elseif (pin.kind == Kind.INSTANCE_ENTER or pin.kind == Kind.INSTANCE_LEAVE) and pin.extra and pin.extra > 0 then
				local instType = ns.DB:ReadInstance(pin.extra)
				GameTooltip:AddLine(ns.InstanceName[instType] or L["Instance"], 1, 1, 1)
			elseif pin.kind == Kind.BOSS then
				GameTooltip:AddLine(L["Boss"], 1, 1, 1)
			end
			if pin.kind ~= Kind.GROUP and pin.when then
				ns.Replay:AddCompanyLine(GameTooltip, ns.DB.char, pin.when)
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
	if not self.markers then
		return
	end
	for i = self.markerUsed + 1, #self.markers do
		self.markers[i]:Hide()
		self.markers[i].kind = nil
	end
end

local function FirstIndexAtOrAfter(times, origin, threshold)
	local lo, hi = 1, #times
	local found = hi + 1
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		if origin + times[mid] < threshold then
			lo = mid + 1
		else
			found = mid
			hi = mid - 1
		end
	end
	return found
end

function ns.Replay:CrossesBreak(prevT, t, times, index)
	index = index or 1
	local count = times and #times or 0
	while index <= count and times[index] < prevT do
		index = index + 1
	end
	local at = times[index]
	if at and at >= prevT and at < t then
		return true, index
	end
	return false, index
end

-- Death, hearth, an accepted summon, and a mage teleport cut the trail so
-- replay never draws a line across the jump. Portal: and ritual casts stay put.
function ns.Replay:BreaksPath(kind, extra)
	if kind == Kind.DEATH or kind == Kind.HEARTH then
		return true
	end
	if kind == Kind.SUMMON then
		return not extra or extra == 0
	end
	if kind ~= Kind.PORTAL or not extra or (issecretvalue and issecretvalue(extra)) or extra == 0 then
		return false
	end
	if not C_Spell or not C_Spell.GetSpellInfo then
		return false
	end
	local info = C_Spell.GetSpellInfo(extra)
	local name = info and info.name
	-- A secret name still has type "string", and subscripting it throws.
	if not name or (issecretvalue and issecretvalue(name)) or type(name) ~= "string" then
		return false
	end
	return string.sub(name, 1, 9) == "Teleport:"
end

function ns.Replay:BreakTimes(sessions)
	local times = {}
	for s = 1, #sessions do
		local session = sessions[s]
		local track = ns.DB:Track(session)
		for i = 1, #(track.ek or {}) do
			if self:BreaksPath(track.ek[i], track.ea and track.ea[i]) then
				times[#times + 1] = session.s + (track.et[i] or 0)
			end
		end
	end
	table.sort(times)
	return times
end

function ns.Replay:CollectPath(sessions, minDist)
	local oldest, newest = self:TrailSpan()
	local breakTimes = self:BreakTimes(sessions)
	local breakIndex = 1
	local instanceSpans = self:InstanceSpans(sessions)
	local xs, ys, brk, modes, speeds, times, maps = {}, {}, {}, {}, {}, {}, {}
	local n = 0
	local prevT
	local lastX, lastY, lastMode
	local open = false
	local minDistSq = minDist * minDist
	for s = 1, #sessions do
		local session = sessions[s]
		local track = ns.DB:Track(session)
		local count = #track.t
		if count > 0 then
			local origin = session.s
			local startT = origin + track.t[1]
			local endT = origin + track.t[count]
			if newest and startT > newest then
				break
			elseif not oldest or endT >= oldest then
				local inferred
				local i0 = 1
				if oldest and startT < oldest then
					i0 = FirstIndexAtOrAfter(track.t, origin, oldest)
				end
				for i = i0, count do
					local t = origin + track.t[i]
					if newest and t > newest then
						break
					end
					if self:InsideSkippedInstance(t, instanceSpans) then
						open = false
						prevT = t
					else
					local px, py = self:Project(track.m[i], track.x[i] / ns.COORD_SCALE, track.y[i] / ns.COORD_SCALE)
					local mode = track.mode and track.mode[i]
					if mode == nil then
						if not inferred then
							inferred = self:InferModes(track)
						end
						mode = inferred[i] or ns.Travel.FOOT
					end
					local speed = (track.spd and track.spd[i]) or 100
					local gap = prevT and (t - prevT) > ns.CONTINUE_SECONDS
					local crosses = false
					if prevT then
						crosses, breakIndex = self:CrossesBreak(prevT, t, breakTimes, breakIndex)
					end
					if not px or gap then
						open = false
					else
						local keep = not open
						if open then
							local dx, dy = px - lastX, py - lastY
							keep = (dx * dx + dy * dy) >= minDistSq or mode ~= lastMode or crosses
						end
						if keep then
							n = n + 1
							xs[n] = px
							ys[n] = py
							modes[n] = mode
							speeds[n] = speed
							times[n] = t
							maps[n] = track.m[i]
							brk[n] = (not open) or crosses
							lastX, lastY, lastMode = px, py, mode
							open = true
						end
					end
					prevT = t
					end
				end
			end
		end
	end
	if self:UsingReplayTrail() and newest then
		local mapID, x, y = self:PlayheadPlace()
		if mapID then
			local px, py = self:Project(mapID, x, y)
			if px and (n == 0 or math.abs(xs[n] - px) > 0.00001 or math.abs(ys[n] - py) > 0.00001) then
				n = n + 1
				xs[n] = px
				ys[n] = py
				modes[n] = modes[n - 1] or ns.Travel.FOOT
				speeds[n] = speeds[n - 1] or 100
				times[n] = newest
				maps[n] = mapID
				brk[n] = n == 1 or maps[n - 1] ~= mapID
			end
		end
	end
	return xs, ys, brk, modes, speeds, times, maps, n
end

function ns.Replay:UsingReplayTrail()
	return self.frame and self.frame:IsShown()
end

function ns.Replay:SnapTrail(minutes)
	minutes = tonumber(minutes) or 0
	if minutes <= 0 or minutes > 60 then
		return 0
	end
	local best, bestDist
	for i = 1, #self.TRAIL_STOPS do
		local stop = self.TRAIL_STOPS[i]
		if stop > 0 then
			local dist = math.abs(stop - minutes)
			if not bestDist or dist < bestDist or (dist == bestDist and stop > best) then
				best, bestDist = stop, dist
			end
		end
	end
	return best or 0
end

function ns.Replay:TrailIndex(minutes)
	local stops = self.TRAIL_STOPS
	for i = 1, #stops do
		if stops[i] == minutes then
			return i
		end
	end
	return #stops
end

function ns.Replay:ReplayTrailMinutes()
	if self.replayTrail == nil then
		local saved = tonumber(ZipperDB and ZipperDB.replayTrail) or 0
		local snapped = self:SnapTrail(saved)
		self.replayTrail = snapped
		if ZipperDB and ZipperDB.replayTrail ~= snapped then
			ZipperDB.replayTrail = snapped
		end
	end
	return self.replayTrail
end

function ns.Replay:TrailLabel(minutes)
	if not minutes or minutes <= 0 then
		return L["Full"]
	end
	return string.format(L["%d min"], minutes)
end

function ns.Replay:SetReplayTrail(minutes)
	minutes = self:SnapTrail(minutes)
	self.replayTrail = minutes
	self.trailShown = minutes
	ZipperDB = ZipperDB or {}
	ZipperDB.replayTrail = minutes
	if self.trailValue then
		self.trailValue:SetText(self:TrailLabel(minutes))
	end
	self.trailDirty = true
end

function ns.Replay:SyncTrailSlider()
	local slider = self.trailSlider
	if not slider then
		return
	end
	local minutes = self:ReplayTrailMinutes()
	if self.trailShown == minutes then
		return
	end
	self.trailShown = minutes
	local stops = self.TRAIL_STOPS
	self.lockTrail = true
	slider:Enable()
	slider:SetMinMaxValues(1, #stops)
	slider:SetValueStep(1)
	slider:SetValue(self:TrailIndex(minutes))
	self.lockTrail = false
	if self.trailValue then
		self.trailValue:SetText(self:TrailLabel(minutes))
	end
end

function ns.Replay:TrailWindow()
	local minutes
	if self:UsingReplayTrail() then
		minutes = self:ReplayTrailMinutes()
	else
		minutes = ns.Config:GlanceTrail()
	end
	if not minutes or minutes <= 0 then
		return nil
	end
	return minutes * 60
end

function ns.Replay:TrailNow()
	if self:UsingReplayTrail() and self.playhead then
		return self.playhead
	end
	return self.t1 or (ns.DB and ns.DB:Now()) or 0
end

-- Oldest sample that still belongs on the trail, and the "now" the solid part ends at.
-- Full history has no oldest bound. The fade tail sits just past the solid window.
function ns.Replay:TrailSpan()
	local nowT = self:TrailNow()
	if self.t1 and nowT > self.t1 then
		nowT = self.t1
	end
	local window = self:TrailWindow()
	local oldest
	if window then
		local fade = math.min(45, math.max(10, window * 0.12))
		oldest = nowT - window - fade
	end
	if self.t0 and (not oldest or oldest < self.t0) then
		oldest = self.t0
	end
	return oldest, nowT
end

function ns.Replay:SegmentFade(older)
	local nowT = self:TrailNow()
	if not older or older > nowT then
		return 0
	end
	local window = self:TrailWindow()
	if not window then
		return 1
	end
	local age = nowT - older
	if age <= window then
		return 1
	end
	local fade = math.min(45, math.max(10, window * 0.12))
	if age >= window + fade then
		return 0
	end
	return 1 - ((age - window) / fade)
end

function ns.Replay:RefreshTrailFade()
	local count = self.segmentCount or 0
	for i = 1, count do
		local seg = self.segments[i]
		local line = seg and seg.line
		if line then
			local fade = self:SegmentFade(seg.t1)
			local r, g, b, a = self:LineLook(seg.mode, seg.speed)
			a = (a or 0.9) * fade
			if not seg.placed or a < 0.03 then
				line:Hide()
			else
				line:SetColorTexture(r, g, b, a)
				line:Show()
			end
		end
	end
	for i = 1, self.markerUsed or 0 do
		local marker = self.markers[i]
		local fade = self:SegmentFade(marker.when)
		if fade < 0.03 then
			marker:Hide()
		else
			marker:SetAlpha(fade)
			marker:Show()
		end
	end
end

function ns.Replay:DrawPath(sessions)
	local minDist = 0.0015
	local xs, ys, brk, modes, speeds, times, maps, n
	for _ = 1, 5 do
		xs, ys, brk, modes, speeds, times, maps, n = self:CollectPath(sessions, minDist)
		if n <= LINE_CAP then
			break
		end
		minDist = minDist * 2
	end
	self.lineUsed = 0
	self.segmentCount = 0
	local canvas = self:Canvas()
	if not canvas or canvas:GetWidth() <= 0 or not self:PathLayer() then
		self:HideSpareLines()
		return
	end
	self.segments = self.segments or {}
	for i = 2, n do
		if not brk[i] then
			local line = self:AcquireLine()
			if line then
				local fade = self:SegmentFade(times[i - 1])
				local placed = self:PlaceLine(line, xs[i - 1], ys[i - 1], xs[i], ys[i], modes[i], speeds[i], fade)
				self.segmentCount = self.segmentCount + 1
				local seg = self.segments[self.segmentCount]
				if not seg then
					seg = {}
					self.segments[self.segmentCount] = seg
				end
				seg.line = line
				seg.placed = placed and true or false
				seg.x1, seg.y1 = xs[i - 1], ys[i - 1]
				seg.x2, seg.y2 = xs[i], ys[i]
				seg.t1, seg.t2 = times[i - 1], times[i]
				seg.map = maps[i]
				seg.mode = modes[i]
				seg.speed = speeds[i]
			end
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
	local function draw(wantKill, cap)
		local shown = 0
		for s = #sessions, 1, -1 do
			if shown >= cap then
				break
			end
			local session = sessions[s]
			local track = ns.DB:Track(session)
			for i = #track.ek, 1, -1 do
				if shown >= cap then
					break
				end
				local kind = track.ek[i]
				local isKill = kind == Kind.KILL
				local when = session.s + (track.et[i] or 0)
				local restEnd = (kind == Kind.CAMP or kind == Kind.SLEEP) and track.ea[i] == 1
				local outside = self.mode == "level" and self.t0 and (when < self.t0 or when > (self.t1 or when))
				if isKill == wantKill and kind ~= Kind.ZONE and kind ~= Kind.EAT and not restEnd and not outside and self:SegmentFade(when) > 0 then
					local px, py = self:Project(track.em[i], track.ex[i] / ns.COORD_SCALE, track.ey[i] / ns.COORD_SCALE)
					if px then
						shown = shown + 1
						local marker = self:AcquireMarker()
						local size = PIP
						if isKill then
							local _, elite = ns.DB:ReadKill(track.ea[i])
							marker.texture:SetTexture("Interface\\AddOns\\Zipper\\Media\\Circle")
							marker.texture:SetTexCoord(0, 1, 0, 1)
							marker.texture:SetVertexColor(0.86, 0.12, 0.10, 1)
							size = elite and ELITE_PIP or KILL_PIP
						elseif kind == Kind.LEVEL then
							marker.texture:SetTexture("Interface\\Buttons\\WHITE8X8")
							marker.texture:SetTexCoord(0, 1, 0, 1)
							marker.texture:SetVertexColor(1, 0.92, 0.45, 1)
							size = 7
						elseif kind == Kind.DEATH then
							marker.texture:SetTexture("Interface\\Buttons\\WHITE8X8")
							marker.texture:SetTexCoord(0, 1, 0, 1)
							marker.texture:SetVertexColor(0.72, 0.08, 0.08, 1)
							size = 8
						elseif kind == Kind.GROUP then
							local color = ns.KindColor[Kind.GROUP]
							marker.texture:SetTexture("Interface\\Buttons\\WHITE8X8")
							marker.texture:SetTexCoord(0, 1, 0, 1)
							marker.texture:SetVertexColor(color[1], color[2], color[3], 1)
							size = 7
						elseif kind == Kind.QUEST_ACCEPT then
							marker.texture:SetTexture("Interface\\Buttons\\WHITE8X8")
							marker.texture:SetTexCoord(0, 1, 0, 1)
							marker.texture:SetVertexColor(0.58, 0.44, 0.06, 1)
						elseif kind == Kind.QUEST_TURNIN then
							marker.texture:SetTexture("Interface\\Buttons\\WHITE8X8")
							marker.texture:SetTexCoord(0, 1, 0, 1)
							marker.texture:SetVertexColor(0.235, 0.702, 0.443, 1)
						elseif kind == Kind.PORTAL or kind == Kind.TRAINER or kind == Kind.CAMP or kind == Kind.SLEEP then
							local color = ns.KindColor[kind]
							marker.texture:SetTexture("Interface\\Buttons\\WHITE8X8")
							marker.texture:SetTexCoord(0, 1, 0, 1)
							marker.texture:SetVertexColor(color[1], color[2], color[3], 1)
						else
							marker.texture:SetTexture("Interface\\Buttons\\WHITE8X8")
							marker.texture:SetTexCoord(0, 1, 0, 1)
							marker.texture:SetVertexColor(1, 0.82, 0.28, 1)
						end
						marker:SetAlpha(self:SegmentFade(when))
						ns.Map:Use():FitPin(marker, size)
						marker.kind = kind
						marker.extra = track.ea[i]
						marker.mapID = track.em[i]
						marker.when = when
						marker.session = session
						ns.Map:Use():Place(marker, px, py)
						marker:SetFrameLevel(ns.Map:Use():OverlayLevel(canvas) + (isKill and 3 or 5))
						marker:Show()
					end
				end
			end
		end
	end
	draw(false, MARKER_CAP)
	draw(true, KILL_CAP)
	self:HideSpareMarkers()
end

function ns.Replay:ClassColor()
	-- The line belongs to the journey on screen. UnitClass is only the logged-in character.
	local viewKey = ns.DB.viewKey or ns.DB.playerKey
	local other = viewKey and ns.DB.playerKey and viewKey ~= ns.DB.playerKey
	local classFile
	if other then
		classFile = ns.DB:JourneyClass(ns.DB.char, viewKey)
	else
		local _, live = UnitClass("player")
		if type(live) == "string" and not (issecretvalue and issecretvalue(live)) and live ~= "" then
			classFile = live
			if ns.DB.record then
				ns.DB.record.class = live
			end
		else
			classFile = ns.DB:JourneyClass(ns.DB.record, ns.DB.playerKey)
		end
	end
	if classFile and viewKey == self.colorView and classFile == self.classFile and self.classR then
		return self.classR, self.classG, self.classB
	end
	local r, g, b
	if classFile and C_ClassColor and C_ClassColor.GetClassColor then
		local color = C_ClassColor.GetClassColor(classFile)
		if color and color.GetRGB then
			r, g, b = color:GetRGB()
		end
	end
	if (not r or (issecretvalue and issecretvalue(r))) and classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
		local color = RAID_CLASS_COLORS[classFile]
		r, g, b = color.r, color.g, color.b
	end
	if not r or (issecretvalue and issecretvalue(r)) then
		r, g, b = 0.9, 0.9, 0.9
	end
	self.colorView = viewKey
	self.classFile = classFile
	self.classR, self.classG, self.classB = r, g, b
	return r, g, b
end

function ns.Replay:PlayheadParked()
	local sessions = self.sessions
	local when = self.playhead
	if not sessions or not when then
		return false
	end
	local afk = false
	local camp, sleep, meal = false, false, false
	for s = 1, #sessions do
		local session = sessions[s]
		local track = ns.DB:Track(session)
		for i = 1, #(track.ek or {}) do
			local at = session.s + (track.et[i] or 0)
			if at > when then
				break
			end
			local kind = track.ek[i]
			local extra = track.ea[i]
			if kind == Kind.AFK_START then
				afk = true
			elseif kind == Kind.AFK_END then
				afk = false
			elseif kind == Kind.CAMP and (not extra or extra == 0) then
				afk = false
				camp = true
			elseif kind == Kind.CAMP and extra == 1 then
				camp = false
			elseif kind == Kind.SLEEP and (not extra or extra == 0) then
				afk = false
				sleep = true
			elseif kind == Kind.SLEEP and extra == 1 then
				sleep = false
			elseif kind == Kind.EAT and (not extra or extra == 0) then
				afk = false
				meal = true
			elseif kind == Kind.EAT and extra == 1 then
				meal = false
			end
		end
	end
	if camp or sleep or meal then
		return false
	end
	if afk then
		return true
	end
	local s1, i1, s2, i2 = Locate(sessions, when)
	if not s1 then
		return false
	end
	local map1, x1, y1, t1 = self:SampleXY(sessions[s1], i1)
	local map2, x2, y2, t2 = self:SampleXY(sessions[s2], i2)
	if i1 == i2 and i1 > 1 then
		map1, x1, y1, t1 = self:SampleXY(sessions[s1], i1 - 1)
		map2, x2, y2, t2 = self:SampleXY(sessions[s2], i2)
	end
	if map1 ~= map2 then
		return false
	end
	local dx, dy = (x2 or x1) - x1, (y2 or y1) - y1
	if (dx * dx) + (dy * dy) > (PARK_DIST * PARK_DIST) then
		return false
	end
	return (when - t1) >= PARK_SECONDS
end

function ns.Replay:StyleDot(parked)
	local dot = self.dot
	if not dot or dot.parked == parked then
		return
	end
	dot.parked = parked
	if parked then
		dot.texture:SetTexture("Interface\\AddOns\\Zipper\\Media\\Ring")
	else
		dot.texture:SetTexture("Interface\\AddOns\\Zipper\\Media\\Circle")
	end
	local r, g, b = self:ClassColor()
	dot.texture:SetVertexColor(r, g, b, 1)
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
	local parked = self:PlayheadParked()
	self:StyleDot(parked)
	ns.Map:Use():FitPin(self.dot, 12)
	ns.Map:Use():Place(self.dot, x, y)
	self.dot:SetFrameLevel(ns.Map:Use():OverlayLevel(canvas) + 15)
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
	-- Glancing keeps the saved replay position, but the dot belongs at the end of the live trail.
	local glance = not self:UsingReplayTrail()
	local saved
	if glance then
		saved = self.playhead
		self.playhead = self.t1
	end
	local mapID, x, y = self:PlayheadPlace()
	local px, py
	if mapID then
		px, py = self:Project(mapID, x, y)
	end
	if px then
		self:PositionDot(px, py)
	elseif self.dot then
		self.dot:Hide()
	end
	if glance then
		self.playhead = saved
	end
end

function ns.Replay:MapYards(mapID)
	if not mapID then
		return nil
	end
	self.mapYards = self.mapYards or {}
	local cached = self.mapYards[mapID]
	if cached ~= nil then
		if cached then
			return cached
		end
		return nil
	end
	local width, height
	if C_Map and C_Map.GetMapWorldSize then
		width, height = C_Map.GetMapWorldSize(mapID)
	end
	if not PlainNumber(width) or not PlainNumber(height) or width <= 0 or height <= 0 then
		self.mapYards[mapID] = false
		return nil
	end
	self.mapYards[mapID] = { width, height }
	return self.mapYards[mapID]
end

-- Camp/sleep time only when the path stayed put on foot. Old Boosted Rest marks
-- kept firing while questing and sometimes stayed open through flight.
function ns.Replay:RestStillSeconds(track, modes, sessionStart, fromT, toT)
	if not fromT or not toT or toT <= fromT then
		return 0
	end
	if (toT - fromT) < REST_STAT_MIN then
		return 0
	end
	local scale = ns.COORD_SCALE
	local travel = 0
	local lastI
	for i = 1, #track.t do
		local at = sessionStart + (track.t[i] or 0)
		if at > toT then
			break
		end
		if at >= fromT then
			local mode = modes and modes[i]
			if mode and mode ~= ns.Travel.FOOT then
				return 0
			end
			if lastI then
				if track.m[i] ~= track.m[lastI] then
					return 0
				end
				local dx = ((track.x[i] or 0) - (track.x[lastI] or 0)) / scale
				local dy = ((track.y[i] or 0) - (track.y[lastI] or 0)) / scale
				travel = travel + math.sqrt((dx * dx) + (dy * dy))
				if travel > REST_STILL then
					return 0
				end
			end
			lastI = i
		end
	end
	return toT - fromT
end

function ns.Replay:CollectStats(sessions)
	local recorded, afk = 0, 0
	local footTime, mountTime, flightTime = 0, 0, 0
	local footYards, mountYards, flightYards = 0, 0, 0
	local yardsKnown = false
	local speedTime, speedSum, maxSpeed = 0, 0, 0
	local kills, turnins, levels = 0, 0, 0
	local accepts, deaths, summons, hearths, flights, mounts, portals, trainers = 0, 0, 0, 0, 0, 0, 0, 0
	local camp, slept = 0, 0
	local zoneChanges, zoneCount, samples = 0, 0, 0
	local zones = {}
	local entered, inside = {}, {}
	for _, kind in pairs(ns.Instance) do
		entered[kind] = 0
		inside[kind] = 0
	end
	local scale = ns.COORD_SCALE
	for s = 1, #sessions do
		local session = sessions[s]
		local endT = session.seen or session.s
		if self.mode == "level" and self.t1 and self.t1 < endT then
			endT = self.t1
		end
		local clip = self.mode == "level" and self.levelLo and self.t0 and self.t1
		if not clip then
			local fullEnd = session.seen or session.s
			if fullEnd > session.s then
				recorded = recorded + (fullEnd - session.s)
			end
			kills = kills + (session.kills or 0)
			turnins = turnins + (session.quests or 0)
			levels = levels + ns.DB:LevelsGained(session)
		end
		local track = ns.DB:Track(session)
		samples = samples + #track.t
		local modes = track.mode
		if not modes or #modes < #track.t then
			modes = self:InferModes(track)
		end
		for i = 1, #track.t do
			local sampleT = session.s + (track.t[i] or 0)
			if self.mode == "level" and self.levelLo and self.t0 and (sampleT < self.t0 or sampleT > self.t1) then
				sampleT = nil
			end
			if sampleT then
			local mapID = track.m[i]
			if mapID and not zones[mapID] then
				zones[mapID] = true
				zoneCount = zoneCount + 1
			end
			local spd = track.spd and track.spd[i]
			if PlainNumber(spd) and spd > maxSpeed then
				maxSpeed = spd
			end
			if i > 1 and mapID and mapID == track.m[i - 1] then
				local dt = (track.t[i] or 0) - (track.t[i - 1] or 0)
				if dt > 0 and dt <= TRAVEL_GAP then
					local mode = modes[i] or ns.Travel.FOOT
					if mode == ns.Travel.FLIGHT then
						flightTime = flightTime + dt
					elseif mode == ns.Travel.MOUNT then
						mountTime = mountTime + dt
					else
						footTime = footTime + dt
					end
					if PlainNumber(spd) and spd > 0 then
						speedTime = speedTime + dt
						speedSum = speedSum + (spd * dt)
					end
					local size = self:MapYards(mapID)
					if size then
						local dx = ((track.x[i] or 0) - (track.x[i - 1] or 0)) / scale * size[1]
						local dy = ((track.y[i] or 0) - (track.y[i - 1] or 0)) / scale * size[2]
						local yards = math.sqrt((dx * dx) + (dy * dy))
						yardsKnown = true
						if mode == ns.Travel.FLIGHT then
							flightYards = flightYards + yards
						elseif mode == ns.Travel.MOUNT then
							mountYards = mountYards + yards
						else
							footYards = footYards + yards
						end
					end
				end
			end
			end
		end
		local afkStart, instStart, instType, campStart, sleepStart
		for i = 1, #(track.ek or {}) do
			local kind = track.ek[i]
			local t = session.s + (track.et[i] or 0)
			local extra = track.ea[i]
			if self.mode == "level" and self.levelLo and self.t0 and (t < self.t0 or t > self.t1) then
				kind = nil
			end
			if kind == Kind.KILL and self.mode == "level" and self.levelLo then
				kills = kills + 1
			elseif kind == Kind.QUEST_TURNIN and self.mode == "level" and self.levelLo then
				turnins = turnins + 1
			elseif kind == Kind.AFK_START then
				afkStart = t
			elseif kind == Kind.AFK_END and afkStart then
				if t > afkStart then
					afk = afk + (t - afkStart)
				end
				afkStart = nil
			elseif kind == Kind.CAMP and (not extra or extra == 0) then
				campStart = t
			elseif kind == Kind.CAMP and extra == 1 and campStart then
				camp = camp + self:RestStillSeconds(track, modes, session.s, campStart, t)
				campStart = nil
			elseif kind == Kind.SLEEP and (not extra or extra == 0) then
				sleepStart = t
			elseif kind == Kind.SLEEP and extra == 1 and sleepStart then
				slept = slept + self:RestStillSeconds(track, modes, session.s, sleepStart, t)
				sleepStart = nil
			elseif kind == Kind.INSTANCE_ENTER then
				instStart = t
				instType = ns.DB:ReadInstance(extra)
				if not entered[instType] then
					instType = ns.Instance.OTHER
				end
				entered[instType] = entered[instType] + 1
			elseif kind == Kind.INSTANCE_LEAVE and instStart then
				if t > instStart and inside[instType] then
					inside[instType] = inside[instType] + (t - instStart)
				end
				instStart, instType = nil, nil
			elseif kind == Kind.QUEST_ACCEPT then
				accepts = accepts + 1
			elseif kind == Kind.DEATH then
				deaths = deaths + 1
			elseif kind == Kind.SUMMON and (not extra or extra == 0) then
				summons = summons + 1
			elseif kind == Kind.PORTAL then
				portals = portals + 1
			elseif kind == Kind.TRAINER then
				trainers = trainers + 1
			elseif kind == Kind.HEARTH then
				hearths = hearths + 1
			elseif kind == Kind.FLIGHT_START then
				flights = flights + 1
			elseif kind == Kind.MOUNT then
				mounts = mounts + 1
			elseif kind == Kind.ZONE then
				zoneChanges = zoneChanges + 1
			end
		end
		if afkStart and endT > afkStart then
			afk = afk + (endT - afkStart)
		end
		if campStart and endT > campStart then
			camp = camp + self:RestStillSeconds(track, modes, session.s, campStart, endT)
		end
		if sleepStart and endT > sleepStart then
			slept = slept + self:RestStillSeconds(track, modes, session.s, sleepStart, endT)
		end
		if instStart and endT > instStart and inside[instType] then
			inside[instType] = inside[instType] + (endT - instStart)
		end
	end
	if self.mode == "level" and self.levelLo then
		recorded = self:LevelSeconds(self.levelLo, self.levelHi)
		levels = self:LevelsGainedInSelection()
	end
	local function yards(value)
		if not yardsKnown then
			return "—"
		end
		return string.format(L["%s yd"], Comma(math.floor((value or 0) + 0.5)))
	end
	local function percent(value)
		if not value or value <= 0 then
			return "—"
		end
		return math.floor(value + 0.5) .. "%"
	end
	local average = 0
	if speedTime > 0 then
		average = speedSum / speedTime
	end
	local party, raid = ns.Instance.PARTY, ns.Instance.RAID
	local pvp, arena, scenario, other = ns.Instance.PVP, ns.Instance.ARENA, ns.Instance.SCENARIO, ns.Instance.OTHER
	local rows = {
		{ header = L["Time"] },
		{ L["Recorded"], FormatClock(recorded) },
		{ L["On foot"], FormatClock(footTime) },
		{ L["Mounted"], FormatClock(mountTime) },
		{ L["Flight path"], FormatClock(flightTime) },
		{ L["AFK"], FormatClock(afk) },
		{ L["Camped"], FormatClock(camp) },
		{ L["Slept"], FormatClock(slept) },
		{ L["Dungeons"], FormatClock(inside[party]) },
		{ L["Raids"], FormatClock(inside[raid]) },
		{ L["Battlegrounds"], FormatClock(inside[pvp]) },
		{ L["Arenas"], FormatClock(inside[arena]) },
		{ L["Scenarios"], FormatClock(inside[scenario]) },
		{ L["Other instances"], FormatClock(inside[other]) },
		{ header = L["Distance"] },
		{ L["On foot"], yards(footYards) },
		{ L["Mounted"], yards(mountYards) },
		{ L["Flight path"], yards(flightYards) },
		{ L["Fastest"], percent(maxSpeed) },
		{ L["Average speed"], percent(average) },
		{ header = L["Progress"] },
		{ L["Levels"], string.format("+%.2f", levels) },
		{ L["Kills"], Comma(kills) },
		{ L["Quests picked up"], Comma(accepts) },
		{ L["Quests turned in"], Comma(turnins) },
		{ L["Deaths"], Comma(deaths) },
		{ header = L["Moments"] },
		{ L["Summons"], Comma(summons) },
		{ L["Hearths"], Comma(hearths) },
		{ L["Portals"], Comma(portals) },
		{ L["Trainers"], Comma(trainers) },
		{ L["Flights"], Comma(flights) },
		{ L["Mounts"], Comma(mounts) },
		{ L["Dungeons entered"], Comma(entered[party]) },
		{ L["Raids entered"], Comma(entered[raid]) },
		{ L["Battlegrounds entered"], Comma(entered[pvp]) },
		{ L["Arenas entered"], Comma(entered[arena]) },
		{ L["Scenarios entered"], Comma(entered[scenario]) },
		{ L["Other instances entered"], Comma(entered[other]) },
		{ L["Zone changes"], Comma(zoneChanges) },
		{ L["Zones visited"], Comma(zoneCount) },
		{ L["Path samples"], Comma(samples) },
		{ L["Sessions"], Comma(#sessions) },
	}
	local levelRows = self:LevelStatRows()
	for i = 1, #levelRows do
		rows[#rows + 1] = levelRows[i]
	end
	local companyRows = self:CompanyRows(sessions)
	for i = 1, #companyRows do
		rows[#rows + 1] = companyRows[i]
	end
	return rows
end

function ns.Replay:ClassFileColor(classFile)
	if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
		local color = RAID_CLASS_COLORS[classFile]
		if color and not (issecretvalue and issecretvalue(color.r)) then
			return color.r, color.g, color.b
		end
	end
	return 0.78, 0.76, 0.70
end

function ns.Replay:PlaceName(mapID)
	if not mapID or mapID == 0 or not C_Map or not C_Map.GetMapInfo then
		return nil
	end
	local info = C_Map.GetMapInfo(mapID)
	if info and type(info.name) == "string" and not (issecretvalue and issecretvalue(info.name)) and info.name ~= "" then
		return info.name
	end
	return nil
end

function ns.Replay:SpellTitle(spellID)
	spellID = tonumber(spellID)
	if not spellID or spellID <= 0 or not C_Spell or not C_Spell.GetSpellInfo then
		return nil
	end
	local info = C_Spell.GetSpellInfo(spellID)
	local name = info and info.name
	if not name or (issecretvalue and issecretvalue(name)) or type(name) ~= "string" or name == "" then
		return nil
	end
	return name
end

function ns.Replay:TrainerTitle(extra)
	local trainerType, profession = ns.DB:ReadTrainer(extra)
	if trainerType == 2 then
		local name = ns.ProfessionName[profession]
		if name then
			return string.format(L["%s trainer"], name)
		end
		return L["Profession trainer"]
	end
	if trainerType == 3 then
		return L["Pet trainer"]
	end
	return L["Class trainer"]
end

function ns.Replay:TravelTooltip(pin)
	local color = ns.KindColor[pin.kind] or { 1, 0.9, 0.4 }
	if pin.kind == Kind.PORTAL then
		GameTooltip:SetText(self:SpellTitle(pin.extra) or L["Portal"], color[1], color[2], color[3])
	elseif pin.kind == Kind.CAMP then
		GameTooltip:SetText(L["Campfire"], color[1], color[2], color[3])
	elseif pin.kind == Kind.SLEEP then
		GameTooltip:SetText(L["Sleeping bag"], color[1], color[2], color[3])
	elseif pin.kind == Kind.TRAINER then
		GameTooltip:SetText(self:TrainerTitle(pin.extra), color[1], color[2], color[3])
	elseif pin.extra and pin.extra > 0 then
		GameTooltip:SetText(self:SpellTitle(pin.extra) or L["Ritual of Summoning"], 0.75, 0.40, 1)
	else
		GameTooltip:SetText(L["Summon"], 0.75, 0.40, 1)
		local who = ns.DB:SummonerName(pin.session, pin.when)
		if who then
			GameTooltip:AddLine(string.format(L["Summoned by %s"], who), 1, 1, 1)
		end
	end
end

function ns.Replay:GroupTooltip(pin)
	GameTooltip:SetText(L["Joined"], 0.45, 0.75, 1)
	local people = ns.DB:JoinsAt(ns.DB.char, pin.when or 0)
	if #people == 0 then
		local count = tonumber(pin.extra) or 0
		if count > 1 then
			GameTooltip:AddLine(string.format(L["%d people"], count), 1, 1, 1)
		else
			GameTooltip:AddLine(L["Party"], 1, 1, 1)
		end
	end
	for i = 1, #people do
		local person = people[i]
		local r, g, b = self:ClassFileColor(person.classFile)
		local line = person.name
		if person.className then
			line = person.className .. "   " .. person.name
		end
		if person.first then
			if person.level and person.level > 0 then
				line = line .. string.format(L["   · first time, level %d"], person.level)
			else
				line = line .. L["   · first time"]
			end
		end
		GameTooltip:AddLine(line, r, g, b)
	end
	local where = self:PlaceName(pin.mapID)
	if where then
		GameTooltip:AddLine(where, 0.75, 0.75, 0.75)
	end
end

function ns.Replay:CompanyFacts(person)
	local parts = {}
	if person.quests > 0 then
		parts[#parts + 1] = person.quests == 1 and L["1 quest"] or string.format(L["%d quests"], person.quests)
	elseif person.accepts > 0 then
		parts[#parts + 1] = person.accepts == 1 and L["1 pickup"] or string.format(L["%d pickups"], person.accepts)
	end
	if person.elites > 0 then
		parts[#parts + 1] = person.elites == 1 and L["1 elite"] or string.format(L["%d elites"], person.elites)
	end
	if person.rares > 0 then
		parts[#parts + 1] = person.rares == 1 and L["1 rare"] or string.format(L["%d rares"], person.rares)
	end
	if person.elites == 0 and person.rares == 0 and person.kills > 0 then
		parts[#parts + 1] = person.kills == 1 and L["1 kill"] or string.format(L["%d kills"], person.kills)
	end
	if person.dungeons > 0 then
		parts[#parts + 1] = person.dungeons == 1 and L["1 dungeon"] or string.format(L["%d dungeons"], person.dungeons)
	end
	if person.raids > 0 then
		parts[#parts + 1] = person.raids == 1 and L["1 raid"] or string.format(L["%d raids"], person.raids)
	end
	if person.deaths > 0 then
		parts[#parts + 1] = person.deaths == 1 and L["1 death"] or string.format(L["%d deaths"], person.deaths)
	end
	return table.concat(parts, " · ")
end

function ns.Replay:CompanyValue(person)
	local parts = { FormatClock(person.seconds) }
	local facts = self:CompanyFacts(person)
	if facts ~= "" then
		parts[#parts + 1] = facts
	end
	if person.metByName then
		local where = self:PlaceName(person.metMap)
		if where then
			parts[#parts + 1] = string.format(L["met in %s on %s"], where, person.metByName)
		else
			parts[#parts + 1] = string.format(L["met on %s"], person.metByName)
		end
	end
	return table.concat(parts, " · ")
end

function ns.Replay:FirstMetSentence(person)
	local where = self:PlaceName(person.metMap)
	if person.metByName then
		if where then
			return string.format(L["First met in %s on %s"], where, person.metByName)
		end
		return string.format(L["First met on %s"], person.metByName)
	end
	if where and person.metLevel and person.metLevel > 0 then
		return string.format(L["First met in %s at level %d"], where, person.metLevel)
	end
	if where then
		return string.format(L["First met in %s"], where)
	end
	return nil
end

function ns.Replay:CompanyLine(journey, when)
	if not ns.Config:Enabled("party") or not journey or not when then
		return nil
	end
	local people = ns.DB:CompanyAt(journey, when)
	if #people == 0 then
		return nil
	end
	local names = {}
	local shown = math.min(3, #people)
	for i = 1, shown do
		names[#names + 1] = people[i].name
	end
	local text
	if #people > shown then
		text = string.format(L["With %s +%d"], table.concat(names, ", "), #people - shown)
	else
		text = string.format(L["With %s"], table.concat(names, ", "))
	end
	local r, g, b = 0.45, 0.75, 1
	if #people == 1 then
		r, g, b = self:ClassFileColor(people[1].classFile)
	end
	return text, r, g, b
end

function ns.Replay:AddCompanyLine(tooltip, journey, when)
	local text, r, g, b = self:CompanyLine(journey, when)
	if not text or not tooltip or (tooltip.IsForbidden and tooltip:IsForbidden()) then
		return
	end
	tooltip:AddLine(text, r, g, b)
end

function ns.Replay:UnitGuid(tooltip)
	local guid
	if TooltipUtil and TooltipUtil.GetDisplayedUnit then
		local _, _, displayed = TooltipUtil.GetDisplayedUnit(tooltip)
		if type(displayed) == "string" and not (issecretvalue and issecretvalue(displayed)) then
			guid = displayed
		end
	end
	if not guid and tooltip.GetUnit then
		local _, unit = tooltip:GetUnit()
		-- Secret strings still report type "string". Check issecretvalue before any compare.
		if type(unit) == "string" and not (issecretvalue and issecretvalue(unit)) and unit ~= "" then
			local raw = UnitGUID(unit)
			if type(raw) == "string" and not (issecretvalue and issecretvalue(raw)) then
				guid = raw
			end
		end
	end
	if not guid or (issecretvalue and issecretvalue(guid)) then
		return nil
	end
	if guid:sub(1, 7) ~= "Player-" or guid == ns.DB.playerKey then
		return nil
	end
	return guid
end

function ns.Replay:PaintUnitCompany(tooltip)
	if not ns.Config:Enabled("party") then
		return
	end
	local guid = self:UnitGuid(tooltip)
	if not guid then
		return
	end
	local journey = ns.DB.record or ns.DB.char
	local person = journey and ns.DB:CompanyByGuid(journey, guid)
	if not person then
		return
	end
	local r, g, b = self:ClassFileColor(person.classFile)
	tooltip:AddLine(" ")
	if (person.seconds or 0) >= 1 then
		tooltip:AddDoubleLine(L["Together"], FormatClock(person.seconds or 0), r, g, b, 0.93, 0.90, 0.78)
	else
		tooltip:AddLine(L["Together"], r, g, b)
	end
	local facts = self:CompanyFacts(person)
	if facts ~= "" then
		tooltip:AddLine(facts, 0.78, 0.76, 0.70)
	end
	local met = self:FirstMetSentence(person)
	if met then
		tooltip:AddLine(met, 0.75, 0.75, 0.75)
	end
	tooltip:Show()
end

function ns.Replay:EnsureUnitTip()
	if self.unitTip then
		return
	end
	local function OnUnitTooltip(tooltip)
		if ns.Replay.paintingTip or tooltip ~= GameTooltip then
			return
		end
		if tooltip.IsForbidden and tooltip:IsForbidden() then
			return
		end
		ns.Replay.paintingTip = true
		local ok, err = pcall(ns.Replay.PaintUnitCompany, ns.Replay, tooltip)
		ns.Replay.paintingTip = false
		if not ok and not ns.Replay.unitTipFailed then
			ns.Replay.unitTipFailed = true
			geterrorhandler()(err)
		end
	end
	-- Forever builds unit tooltips through TooltipDataProcessor. The script
	-- handler is only there if that API is missing.
	if TooltipDataProcessor and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
		local ok = pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Unit, OnUnitTooltip)
		if ok then
			self.unitTip = true
		end
		return
	end
	if GameTooltip and GameTooltip.HookScript then
		GameTooltip:HookScript("OnTooltipSetUnit", OnUnitTooltip)
		self.unitTip = true
	end
end

function ns.Replay:CompanyRows(sessions)
	local t0, t1
	if self.mode == "level" and self.levelLo and self.t0 and self.t1 then
		t0, t1 = self.t0, self.t1
	end
	local report = ns.DB:CompanyReport(ns.DB.char, sessions, t0, t1)
	if #report == 0 then
		return {}
	end
	local rows = { { header = L["Company"] } }
	local shown = math.min(8, #report)
	for i = 1, shown do
		local person = report[i]
		local r, g, b = self:ClassFileColor(person.classFile)
		rows[#rows + 1] = { person.name, self:CompanyValue(person), r = r, g = g, b = b }
	end
	if #report > shown then
		rows[#rows + 1] = { string.format(L["%d more"], #report - shown), "" }
	end
	return rows
end

-- One row per level. A level that crosses logins is several spans; the list adds those together.
-- Levels 1 through 6 are one row. Later levels stay separate.
local STARTER_LEVEL = 6

function ns.Replay:LevelGroups()
	local spans = ns.DB:LevelSpans(ns.DB.char)
	local groups, order = {}, {}
	for i = 1, #spans do
		local span = spans[i]
		local top = span.lvTo or span.lv
		local ranged = span.lvTo and span.lvTo ~= span.lv
		local starter = span.lv >= 1 and top <= STARTER_LEVEL
		local key = starter and "starter" or (ranged and (span.lv .. "-" .. span.lvTo) or tostring(span.lv))
		local group = groups[key]
		if not group then
			group = {
				lv = span.lv,
				lvTo = (not starter and ranged) and span.lvTo or nil,
				seconds = 0,
				open = false,
				t0 = span.t0,
				last = span.t0,
			}
			groups[key] = group
			order[#order + 1] = group
		end
		if not group.t0 or span.t0 < group.t0 then
			group.t0 = span.t0
		end
		if starter then
			local low = math.min(group.lv, span.lv)
			local high = math.max(group.lvTo or group.lv, top)
			group.lv = low
			group.lvTo = high ~= low and high or nil
		end
		local stop = ns.DB:SpanStop(span, ns.DB.char)
		local dur = (stop or span.t0) - span.t0
		if dur > 0 then
			group.seconds = group.seconds + dur
		end
		if not span.t1 then
			group.open = true
		end
		if stop and stop > group.last then
			group.last = stop
		end
	end
	local live = ns.DB.session
	local sessions = ns.DB.char and ns.DB.char.sessions
	local liveHere = false
	if live and type(sessions) == "table" then
		for i = 1, #sessions do
			if sessions[i] == live then
				liveHere = true
				break
			end
		end
	end
	if liveHere and type(live.el) == "number" then
		for i = 1, #order do
			local group = order[i]
			local top = group.lvTo or group.lv
			if live.el >= group.lv and live.el <= top then
				group.open = true
			end
		end
	end
	table.sort(order, function(a, b)
		if a.last == b.last then
			return a.lv > b.lv
		end
		return a.last > b.last
	end)
	return order
end

function ns.Replay:LevelName(group)
	if group.lvTo and group.lvTo ~= group.lv then
		if group.open then
			return string.format(L["Lv %d–%d (so far)"], group.lv, group.lvTo)
		end
		return string.format(L["Lv %d–%d"], group.lv, group.lvTo)
	end
	if group.open then
		return string.format(L["Lv %d (so far)"], group.lv)
	end
	return string.format(L["Lv %d"], group.lv)
end

function ns.Replay:LevelIsOpen(lo, hi)
	if not lo then
		return false
	end
	hi = hi or lo
	local groups = self:LevelGroups()
	for i = 1, #groups do
		local group = groups[i]
		local top = group.lvTo or group.lv
		if group.open and group.lv == lo and top == hi then
			return true
		end
	end
	return false
end

function ns.Replay:LevelSeconds(lo, hi)
	if not lo then
		return 0
	end
	hi = hi or lo
	local seconds = 0
	local groups = self:LevelGroups()
	for i = 1, #groups do
		local group = groups[i]
		local top = group.lvTo or group.lv
		if top >= lo and group.lv <= hi then
			seconds = seconds + (group.seconds or 0)
		end
	end
	return seconds
end

-- Finished levels count as 1.00 each; an open level adds its current XP fraction.
function ns.Replay:LevelsGainedInSelection()
	local lo = self.levelLo
	if not lo then
		return 0
	end
	local hi = self.levelHi or lo
	local gained = 0
	local groups = self:LevelGroups()
	local liveLevel, frac = ns.DB:OpenLevelProgress(ns.DB.char)
	for i = 1, #groups do
		local group = groups[i]
		local top = group.lvTo or group.lv
		if top >= lo and group.lv <= hi then
			local a = math.max(group.lv, lo)
			local b = math.min(top, hi)
			if a <= b then
				if group.open then
					if liveLevel and liveLevel >= a and liveLevel <= b then
						gained = gained + (liveLevel - a) + frac
					elseif liveLevel and liveLevel > b then
						gained = gained + (b - a + 1)
					end
				else
					gained = gained + (b - a + 1)
				end
			end
		end
	end
	if gained < 0 then
		return 0
	end
	return gained
end

function ns.Replay:LevelStatRows()
	local groups = self:LevelGroups()
	if #groups == 0 then
		return {}
	end
	local rows = { { header = L["Levels"] } }
	for i = 1, #groups do
		local group = groups[i]
		local top = group.lvTo or group.lv
		if not self.levelLo or (top >= self.levelLo and group.lv <= (self.levelHi or self.levelLo)) then
			rows[#rows + 1] = { self:LevelName(group), FormatClock(group.seconds or 0) }
		end
	end
	if #rows == 1 then
		return {}
	end
	return rows
end

function ns.Replay:StatsKey(sessions)
	local parts = { tostring(#sessions) }
	for i = 1, #sessions do
		local session = sessions[i]
		local track = ns.DB:Track(session)
		parts[#parts + 1] = string.format(
			"%s.%s.%s.%s.%s.%s.%s.%s",
			session.id or i,
			session.seen or 0,
			session.kills or 0,
			session.quests or 0,
			session.el or 0,
			session.ex or 0,
			#track.t,
			#(track.ek or {})
		)
	end
	parts[#parts + 1] = string.format(
		"%s.%s.%s.%s.%s",
		self.mode or "",
		self.levelLo or "",
		self.levelHi or "",
		self.t0 or "",
		self.t1 or ""
	)
	if self.mode == "level" then
		parts[#parts + 1] = "lv" .. math.floor(ns.DB:Now() / 5)
	end
	local with = ns.DB.char and ns.DB.char.with
	local spans, open = 0, 0
	if type(with) == "table" then
		for _, list in pairs(with) do
			if type(list) == "table" then
				spans = spans + #list
				if #list % 2 == 1 then
					open = open + 1
				end
			end
		end
	end
	parts[#parts + 1] = "c" .. spans
	if open > 0 then
		parts[#parts + 1] = "o" .. math.floor(ns.DB:Now() / 5)
	end
	return table.concat(parts, ":")
end

function ns.Replay:RefreshStats(sessions)
	local content = self.statContent
	if not content then
		return
	end
	sessions = sessions or self.sessions or {}
	local key = self:StatsKey(sessions)
	if key == self.statsKey then
		return
	end
	self.statsKey = key
	local width = self.statScroll and self.statScroll:GetWidth() or 0
	if width > 40 then
		content:SetWidth(width)
	end
	local rows = self:CollectStats(sessions)
	self.statRows = self.statRows or {}
	for i = 1, #rows do
		local info = rows[i]
		local row = self.statRows[i]
		if not row then
			row = CreateFrame("Frame", nil, content)
			row:SetHeight(16)
			row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.label:SetPoint("LEFT", 4, 0)
			row.label:SetJustifyH("LEFT")
			row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.value:SetPoint("RIGHT", -4, 0)
			row.value:SetJustifyH("RIGHT")
			row.label:SetPoint("RIGHT", row.value, "LEFT", -8, 0)
			self.statRows[i] = row
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((i - 1) * 16))
		row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
		if info.header then
			row.label:SetText(info.header)
			row.label:SetTextColor(1, 0.86, 0.45)
			row.value:SetText("")
		else
			row.label:SetText(info[1])
			if info.r ~= nil then
				row.label:SetTextColor(info.r, info.g, info.b)
			else
				row.label:SetTextColor(0.78, 0.76, 0.70)
			end
			row.value:SetText(info[2] or "")
			row.value:SetTextColor(0.93, 0.90, 0.78)
		end
		row:Show()
	end
	for i = #rows + 1, #self.statRows do
		self.statRows[i]:Hide()
	end
	content:SetHeight(math.max(16, #rows * 16))
end

function ns.Replay:UpdateRecap(sessions)
	self:RefreshStats(sessions)
end

function ns.Replay:ToggleCharacters()
	local picker = self.charPicker
	if not picker then
		return
	end
	if picker:IsShown() then
		picker:Hide()
		return
	end
	self:RefreshCharacters()
	picker:Show()
end

function ns.Replay:StyleCharButton()
	local button = self.charButton
	if not button or not button.arrow then
		return
	end
	local open = self.charPicker and self.charPicker:IsShown()
	if open then
		button.arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollUp-Up")
	else
		button.arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
	end
end

function ns.Replay:RefreshCharacters()
	if self.charButton and ns.DB.char then
		self.charButton:SetText(ns.DB:JourneyLabel(ns.DB.char))
	end
	local picker = self.charPicker
	if not picker then
		return
	end
	local list = ns.DB:CharacterList()
	self.charRows = self.charRows or {}
	for i = 1, #list do
		local row = self.charRows[i]
		if not row then
			row = CreateFrame("Button", nil, picker)
			row:SetHeight(20)
			row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.label:SetPoint("LEFT", 8, 0)
			row.label:SetPoint("RIGHT", -6, 0)
			row.label:SetJustifyH("LEFT")
			row:SetScript("OnClick", function(button)
				ns.Replay:RememberPlayhead()
				ns.DB:SetView(button.charKey)
				if ns.Replay.charPicker then
					ns.Replay.charPicker:Hide()
				end
				if button.charKey == ns.DB.playerKey then
					ns.Replay:SetMode("current", nil, true)
				else
					ns.Replay:SetMode("all", nil, true)
				end
			end)
			self.charRows[i] = row
		end
		row.charKey = list[i].key
		local mark = list[i].current and "  · recording" or ""
		row.label:SetText(string.format("%s  (%d)%s", list[i].label, list[i].sessions, mark))
		if list[i].key == ns.DB.viewKey then
			row.label:SetTextColor(1, 0.86, 0.45)
		else
			row.label:SetTextColor(0.9, 0.88, 0.78)
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", picker, "TOPLEFT", 0, -((i - 1) * 20))
		row:SetPoint("RIGHT", picker, "RIGHT", 0, 0)
		row:Show()
	end
	for i = #list + 1, #self.charRows do
		self.charRows[i]:Hide()
	end
	picker:SetHeight(math.max(22, #list * 20 + 4))
end

function ns.Replay:ScopeCaption()
	local who = ns.DB:JourneyLabel(ns.DB.char)
	local other = ns.DB.viewKey and ns.DB.playerKey and ns.DB.viewKey ~= ns.DB.playerKey
	local count = #ns.DB:Sessions()
	if other then
		return string.format(L["%s's saved journey. %d sessions. Recording continues on this character."], who, count)
	end
	if self.mode == "level" then
		if not self.levelLo then
			return L["Pick a level to replay it. Shift-click a second level for a range."]
		end
		if self.levelHi and self.levelHi ~= self.levelLo then
			if self:LevelIsOpen(self.levelLo, self.levelHi) then
				return string.format(L["Levels %d–%d, so far."], self.levelLo, self.levelHi)
			end
			return string.format(L["Levels %d–%d."], self.levelLo, self.levelHi)
		end
		if self:LevelIsOpen(self.levelLo) then
			return string.format(L["Level %d, so far."], self.levelLo)
		end
		return string.format(L["Level %d."], self.levelLo)
	end
	if self.mode == "all" then
		if count <= 1 then
			return L["Every session on this character, added together. There is only one so far, so this matches the recording in progress."]
		end
		return string.format(L["Every session on this character, added together. %d sessions."], count)
	end
	if self.mode == "span" then
		local lo = self.sessionLo or self.index or 1
		local hi = self.sessionHi or lo
		local picked = hi - lo + 1
		if picked < 1 then
			picked = 1
		end
		return string.format(L["%d sessions selected."], picked)
	end
	if self.mode == "one" then
		return L["Only the session you picked in the list."]
	end
	local session = ns.DB:Current()
	local elapsed = 0
	if session then
		elapsed = (session.seen or session.s) - session.s
	end
	return string.format(L["The recording in progress, including reloads a few minutes apart. %s so far."], FormatClock(elapsed))
end

local function MergePieces(pieces)
	if #pieces < 2 then
		return pieces
	end
	table.sort(pieces, function(a, b)
		return a.t0 < b.t0
	end)
	local merged = { { t0 = pieces[1].t0, t1 = pieces[1].t1 } }
	for i = 2, #pieces do
		local last = merged[#merged]
		local piece = pieces[i]
		if piece.t0 <= last.t1 + 2 then
			if piece.t1 > last.t1 then
				last.t1 = piece.t1
			end
		else
			merged[#merged + 1] = { t0 = piece.t0, t1 = piece.t1 }
		end
	end
	return merged
end

function ns.Replay:PlayPieces()
	local pieces = {}
	if self.mode == "level" and self.levelLo then
		local spans = ns.DB:LevelSpans(ns.DB.char)
		local hi = self.levelHi or self.levelLo
		for i = 1, #spans do
			local span = spans[i]
			local top = span.lvTo or span.lv
			if top >= self.levelLo and span.lv <= hi then
				local stop = ns.DB:SpanStop(span, ns.DB.char)
				if stop and stop > span.t0 then
					pieces[#pieces + 1] = { t0 = span.t0, t1 = stop }
				end
			end
		end
	else
		local sessions = self.sessions or {}
		for i = 1, #sessions do
			local session = sessions[i]
			if type(session) == "table" and type(session.s) == "number" then
				local stop = session.seen or session.s
				if session == ns.DB.session then
					stop = ns.DB:Now()
				end
				if stop > session.s then
					pieces[#pieces + 1] = { t0 = session.s, t1 = stop }
				end
			end
		end
	end
	pieces = MergePieces(pieces)
	if #pieces == 0 and self.t0 and self.t1 and self.t1 > self.t0 then
		pieces[1] = { t0 = self.t0, t1 = self.t1 }
	end
	return pieces
end

function ns.Replay:PlayedAt(when)
	local pieces = self:PlayPieces()
	local total, elapsed = 0, 0
	when = when or 0
	for i = 1, #pieces do
		local piece = pieces[i]
		local dur = piece.t1 - piece.t0
		if dur < 0 then
			dur = 0
		end
		total = total + dur
		if when >= piece.t1 then
			elapsed = elapsed + dur
		elseif when > piece.t0 then
			elapsed = elapsed + (when - piece.t0)
		end
	end
	return elapsed, total
end

function ns.Replay:TimeAtPlayed(seconds)
	local pieces = self:PlayPieces()
	if #pieces == 0 then
		return self.t0 or 0
	end
	if not seconds or seconds <= 0 then
		return pieces[1].t0
	end
	local left = seconds
	for i = 1, #pieces do
		local dur = pieces[i].t1 - pieces[i].t0
		if dur < 0 then
			dur = 0
		end
		if left <= dur or i == #pieces then
			local at = pieces[i].t0 + left
			if at > pieces[i].t1 then
				at = pieces[i].t1
			end
			return at
		end
		left = left - dur
	end
	return pieces[#pieces].t1
end

function ns.Replay:UpdateReadout()
	if not self.timeText then
		return
	end
	if self.scopeText then
		self.scopeText:SetText(self:ScopeCaption())
	end
	local sessions = self.sessions or {}
	if not self.t0 or not self.t1 then
		self.timeText:SetText(L["No path yet. Walk somewhere and Zipper will keep the points."])
		self:UpdateRecap(sessions)
		self.playButton:SetText(L["Play"])
		self:SyncTrailSlider()
		self:SyncJumps()
		self:SyncChapters()
		return
	end
	local at = self.playhead or self.t0
	local elapsed, total = self:PlayedAt(at)
	if total < 0 then
		total = 0
	end
	if elapsed < 0 then
		elapsed = 0
	elseif elapsed > total then
		elapsed = total
	end
	self.timeText:SetText(string.format("%s  /  %s", FormatClock(elapsed), FormatClock(total)))
	self:UpdateRecap(sessions)
	if not self.playing then
		self.playButton:SetText(L["Play"])
	end
	self:UpdateScrub()
	self:SyncTrailSlider()
	self:SyncJumps()
	self:SyncChapters()
end

function ns.Replay:UpdateScrub()
	local scrub = self.scrub
	if not scrub or not self.t0 or not self.t1 or self.t1 <= self.t0 then
		return
	end
	local elapsed, total = self:PlayedAt(self.playhead)
	local fraction = 0
	if total > 0 then
		fraction = elapsed / total
	end
	if fraction < 0 then
		fraction = 0
	elseif fraction > 1 then
		fraction = 1
	end
	self.lockScrub = true
	scrub:SetValue(fraction)
	self.lockScrub = false
end

function ns.Replay:JumpSteps()
	local minutes = 0
	local _, total = self:PlayedAt(self.t1 or self.playhead or 0)
	if total and total > 0 then
		minutes = total / 60
	end
	if minutes >= 360 then
		return 60, 15
	elseif minutes >= 120 then
		return 30, 10
	elseif minutes >= 30 then
		return 10, 5
	end
	return 5, 1
end

function ns.Replay:JumpLabel(minutes, negative)
	local prefix = negative and "-" or "+"
	if minutes >= 60 and minutes % 60 == 0 then
		local hours = minutes / 60
		if hours == 1 then
			return string.format(L["%s1 hr"], prefix)
		end
		return string.format(L["%s%d hr"], prefix, hours)
	end
	return string.format(L["%s%d m"], prefix, minutes)
end

function ns.Replay:SyncJumps()
	local buttons = self.jumpButtons
	if not buttons then
		return
	end
	local big, small = self:JumpSteps()
	if self.jumpBig == big and self.jumpSmall == small then
		return
	end
	self.jumpBig, self.jumpSmall = big, small
	local steps = { -big, -small, small, big }
	for i = 1, 4 do
		local minutes = steps[i]
		buttons[i]:SetText(self:JumpLabel(math.abs(minutes), minutes < 0))
		buttons[i].jumpSeconds = minutes * 60
	end
end

function ns.Replay:MapTitle(mapID)
	if not mapID or mapID == 0 then
		return L["Zone"]
	end
	if C_Map and C_Map.GetMapInfo then
		local info = C_Map.GetMapInfo(mapID)
		if info and type(info.name) == "string" and info.name ~= "" then
			return info.name
		end
	end
	return L["Zone"]
end

function ns.Replay:ChapterName(kind, mapID, chapter)
	if kind == "instance" then
		local label = ns.InstanceName[chapter and chapter.inst] or L["Dungeon"]
		if chapter and chapter.tEnd and chapter.tEnd > chapter.t then
			return label .. " · " .. FormatClock(chapter.tEnd - chapter.t)
		end
		return label
	end
	local zone = self:MapTitle(mapID)
	if kind == "hearth" then
		return string.format(L["Hearth · %s"], zone)
	elseif kind == "teleport" then
		return string.format(L["Teleport · %s"], zone)
	elseif kind == "land" then
		return string.format(L["Landed · %s"], zone)
	end
	return zone
end

-- Map of the first path sample after a teleport cast. A same-zone hop
-- lands on fromMap and returns nil so CollectChapters skips the chapter.
function ns.Replay:TeleportArrival(sessions, eventT, fromMap)
	if not eventT or not fromMap or fromMap == 0 then
		return nil
	end
	local bestMap, bestT
	for s = 1, #(sessions or {}) do
		local session = sessions[s]
		local track = ns.DB:Track(session)
		local origin = session.s
		for i = 1, #track.t do
			local t = origin + (track.t[i] or 0)
			if t > eventT + 45 then
				break
			end
			local mapID = track.m[i]
			if mapID and mapID ~= 0 and t > eventT then
				if not bestT or t < bestT then
					bestT = t
					bestMap = mapID
				end
			end
		end
	end
	if bestMap and bestMap ~= fromMap then
		return bestMap
	end
	return nil
end

function ns.Replay:InstanceSkips(inst)
	inst = ns.DB:ReadInstance(inst)
	return inst ~= ns.Instance.PVP and inst ~= ns.Instance.ARENA
end

function ns.Replay:InstanceSpans(sessions)
	local spans = {}
	local open
	for s = 1, #(sessions or {}) do
		local session = sessions[s]
		local track = ns.DB:Track(session)
		local endT = session.seen or session.s
		for i = 1, #(track.ek or {}) do
			local kind = track.ek[i]
			local t = session.s + (track.et[i] or 0)
			if kind == Kind.INSTANCE_ENTER then
				if open then
					open.tEnd = t
					spans[#spans + 1] = open
				end
				local instType = ns.DB:ReadInstance(track.ea[i])
				open = {
					t = t,
					map = track.em[i],
					inst = instType,
					skip = self:InstanceSkips(instType),
				}
			elseif kind == Kind.INSTANCE_LEAVE and open then
				open.tEnd = t
				spans[#spans + 1] = open
				open = nil
			end
		end
		if open then
			open.tEnd = endT
			spans[#spans + 1] = open
			open = nil
		end
	end
	return spans
end

function ns.Replay:InsideSkippedInstance(t, spans)
	for i = 1, #(spans or {}) do
		local span = spans[i]
		if span.skip and t > span.t and t < (span.tEnd or t) then
			return true
		end
	end
	return false
end

function ns.Replay:InstanceSkipTo(at)
	if not at or not self.sessions then
		return nil
	end
	local spans = self:InstanceSpans(self.sessions)
	for i = 1, #spans do
		local span = spans[i]
		if span.skip and at >= span.t and span.tEnd and at < span.tEnd then
			return span.tEnd
		end
	end
end

function ns.Replay:CollectChapters(sessions)
	local visits = {}
	local open
	local function closeVisit()
		if not open then
			return
		end
		visits[#visits + 1] = open
		open = nil
	end
	local workKind = {
		[Kind.QUEST_ACCEPT] = true,
		[Kind.QUEST_TURNIN] = true,
		[Kind.DEATH] = true,
		[Kind.INSTANCE_ENTER] = true,
	}
	for s = 1, #sessions do
		local session = sessions[s]
		local track = ns.DB:Track(session)
		local modes = track.mode
		if not modes or #modes < #track.t then
			modes = self:InferModes(track)
		end
		for i = 1, #track.t do
			local mapID = track.m[i]
			local mode = modes[i] or ns.Travel.FOOT
			local t = session.s + (track.t[i] or 0)
			if not mapID or mode == ns.Travel.FLIGHT then
				closeVisit()
			elseif open and open.map == mapID then
				open.last = t
			else
				closeVisit()
				open = { map = mapID, first = t, last = t, work = false }
			end
		end
		for i = 1, #(track.ek or {}) do
			if workKind[track.ek[i]] then
				local t = session.s + (track.et[i] or 0)
				local mapID = track.em[i]
				for v = 1, #visits do
					local visit = visits[v]
					if t >= visit.first - 30 and t <= visit.last + 30 and (not mapID or mapID == 0 or mapID == visit.map) then
						visit.work = true
					end
				end
				if open and t >= open.first - 30 and t <= open.last + 30 and (not mapID or mapID == 0 or mapID == open.map) then
					open.work = true
				end
			end
		end
	end
	closeVisit()

	local chapters = {}
	for i = 1, #visits do
		local visit = visits[i]
		if visit.work or (visit.last - visit.first) >= STAY_SECONDS then
			chapters[#chapters + 1] = { t = visit.first, map = visit.map, kind = "zone" }
		end
	end
	for s = 1, #sessions do
		local session = sessions[s]
		local track = ns.DB:Track(session)
		for i = 1, #(track.ek or {}) do
			local kind = track.ek[i]
			local extra = track.ea and track.ea[i]
			local eventT = session.s + (track.et[i] or 0)
			local mapID = track.em[i]
			local chapterKind
			if kind == Kind.FLIGHT_END then
				chapterKind = "land"
			elseif kind == Kind.HEARTH then
				chapterKind = "hearth"
			elseif kind == Kind.PORTAL and self:BreaksPath(kind, extra) then
				local arrival = self:TeleportArrival(sessions, eventT, mapID)
				if arrival then
					chapterKind = "teleport"
					mapID = arrival
				end
			end
			if chapterKind then
				chapters[#chapters + 1] = {
					t = eventT,
					map = mapID,
					kind = chapterKind,
				}
			end
		end
	end
	local indoors = self:InstanceSpans(sessions)
	for i = 1, #indoors do
		local span = indoors[i]
		chapters[#chapters + 1] = {
			t = span.t,
			tEnd = span.tEnd,
			map = span.map,
			kind = "instance",
			inst = span.inst,
			skip = span.skip,
		}
	end
	table.sort(chapters, function(a, b)
		if a.t == b.t then
			return a.kind < b.kind
		end
		return a.t < b.t
	end)

	local merged = {}
	for i = 1, #chapters do
		local chapter = chapters[i]
		local previous = merged[#merged]
		if previous and previous.kind ~= "instance" and chapter.kind ~= "instance" and (chapter.t - previous.t) <= CHAPTER_MERGE then
			if chapter.t < previous.t then
				previous.t = chapter.t
			end
			if chapter.kind == "hearth" or previous.kind == "hearth" then
				previous.kind = "hearth"
			elseif chapter.kind == "teleport" or previous.kind == "teleport" then
				previous.kind = "teleport"
			elseif chapter.kind == "zone" or previous.kind == "zone" then
				previous.kind = "zone"
			end
			-- Teleport chapters already carry the arrival map; keep it. Hearth
			-- still picks up arrival from a following zone stop.
			if chapter.kind == "teleport" and chapter.map and chapter.map ~= 0 then
				previous.map = chapter.map
			elseif previous.kind ~= "teleport" then
				if chapter.map and chapter.map ~= 0 and (previous.kind ~= "hearth" or not previous.map) then
					previous.map = chapter.map
				end
				if chapter.kind == "zone" and chapter.map then
					previous.map = chapter.map
				end
			end
		else
			merged[#merged + 1] = { t = chapter.t, map = chapter.map, kind = chapter.kind }
		end
	end
	for i = 1, #merged do
		local chapter = merged[i]
		chapter.name = self:ChapterName(chapter.kind, chapter.map, chapter)
	end
	if self.mode == "level" and self.t0 and self.t1 then
		local kept = {}
		for i = 1, #merged do
			local chapter = merged[i]
			if chapter.t >= self.t0 and chapter.t <= self.t1 then
				kept[#kept + 1] = chapter
			end
		end
		merged = kept
	end
	return merged
end

function ns.Replay:SeekToTime(when)
	if not self.t0 or not self.t1 or self.t1 <= self.t0 or not when then
		return
	end
	-- Chapter buttons and scrub markers jump the playhead without pausing.
	local elapsed, total = self:PlayedAt(when)
	local fraction = 0
	if total > 0 then
		fraction = elapsed / total
	end
	if fraction < 0 then
		fraction = 0
	elseif fraction > 1 then
		fraction = 1
	end
	self:SeekFraction(fraction, true)
end

function ns.Replay:SkipChapter(step)
	local chapters = self.chapters
	if not chapters or #chapters == 0 or not self.t0 then
		return
	end
	local at = self.playhead or self.t0
	local index
	local restartedCurrent = false
	if step > 0 then
		self.chapterPrevSeekAt = nil
		for i = 1, #chapters do
			if chapters[i].t > at + 1 then
				index = i
				break
			end
		end
	else
		local current
		for i = #chapters, 1, -1 do
			if chapters[i].t <= at then
				current = i
				break
			end
		end
		local now = GetTime()
		local grace = math.max(1, (self.speed or 1) * CHAPTER_PREV_GRACE)
		local recent = self.chapterPrevSeekAt and (now - self.chapterPrevSeekAt) <= CHAPTER_PREV_WALL
		local nearStart = current and (at - chapters[current].t) <= grace
		if current and (recent or nearStart) then
			if current > 1 then
				index = current - 1
			end
			self.chapterPrevSeekAt = nil
		elseif current then
			index = current
			restartedCurrent = true
		end
	end
	if index then
		self:SeekToTime(chapters[index].t)
		if restartedCurrent then
			self.chapterPrevSeekAt = GetTime()
		else
			self.chapterPrevSeekAt = nil
		end
	end
end

function ns.Replay:AcquirePip(index)
	self.pips = self.pips or {}
	local pip = self.pips[index]
	if pip then
		return pip
	end
	pip = CreateFrame("Button", nil, self.frame)
	pip:SetSize(12, 12)
	pip.mark = pip:CreateTexture(nil, "OVERLAY")
	pip.mark:SetTexture("Interface\\Buttons\\WHITE8X8")
	pip.mark:SetSize(3, 8)
	pip.mark:SetPoint("CENTER")
	pip:SetScript("OnClick", function(self)
		ns.Replay:SeekToTime(self.when)
	end)
	pip:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(self.title or L["Chapter"], 1, 0.86, 0.45)
		if self.when then
			GameTooltip:AddLine(date("%b %d, %H:%M", self.when), 1, 1, 1)
		end
		GameTooltip:Show()
	end)
	pip:SetScript("OnLeave", function(self)
		if GameTooltip:IsOwned(self) then
			GameTooltip:Hide()
		end
	end)
	self.pips[index] = pip
	return pip
end

function ns.Replay:LayoutPips()
	local scrub = self.scrub
	local chapters = self.chapters or {}
	if not scrub then
		return
	end
	local width = scrub:GetWidth() or 0
	local _, total = self:PlayedAt(self.t1 or 0)
	local shown = 0
	if width > 20 and total > 0 then
		local level = (scrub:GetFrameLevel() or 1) + 6
		for i = 1, #chapters do
			local chapter = chapters[i]
			local elapsed = self:PlayedAt(chapter.t)
			local fraction = elapsed / total
			if fraction < 0 then
				fraction = 0
			elseif fraction > 1 then
				fraction = 1
			end
			local pip = self:AcquirePip(i)
			pip.when = chapter.t
			pip.title = chapter.name
			pip:SetParent(self.frame)
			pip:SetFrameLevel(level)
			pip:ClearAllPoints()
			pip:SetPoint("BOTTOM", scrub, "TOPLEFT", fraction * width, 1)
			pip:Show()
			shown = i
		end
	end
	if self.pips then
		for i = shown + 1, #self.pips do
			self.pips[i]:Hide()
		end
	end
end

function ns.Replay:PaintChapter()
	local chapters = self.chapters or {}
	local at = self.playhead or self.t0 or 0
	local current = 0
	for i = 1, #chapters do
		if chapters[i].t <= at + 1 then
			current = i
		else
			break
		end
	end
	if self.chapterText then
		if #chapters == 0 then
			self.chapterText:SetText(L["No chapters yet"])
		else
			local shown = current > 0 and current or 1
			local prefix = current > 0 and "" or "Next  "
			self.chapterText:SetText(string.format(L["%s%d/%d  %s"], prefix, shown, #chapters, chapters[shown].name))
		end
	end
	if not self.pips then
		return
	end
	for i = 1, #chapters do
		local pip = self.pips[i]
		if pip and pip.mark and pip:IsShown() then
			if i == current then
				pip.mark:SetVertexColor(1, 0.86, 0.35, 1)
				pip.mark:SetSize(4, 10)
			else
				pip.mark:SetVertexColor(0.72, 0.58, 0.22, 0.95)
				pip.mark:SetSize(3, 8)
			end
		end
	end
end

function ns.Replay:SyncChapters()
	if not self.chapterPrev then
		return
	end
	local sessions = self.sessions or {}
	local key = self:StatsKey(sessions)
	local width = self.scrub and self.scrub:GetWidth() or 0
	if key ~= self.chapterKey then
		self.chapterKey = key
		self.chapters = self:CollectChapters(sessions)
		self.pipWidth = nil
	end
	if width ~= self.pipWidth then
		self.pipWidth = width
		self:LayoutPips()
	end
	self:PaintChapter()
end

function ns.Replay:Jump(seconds)
	if not self.t0 or not self.t1 or self.t1 <= self.t0 then
		return
	end
	self.playing = false
	if self.playButton then
		self.playButton:SetText(L["Play"])
	end
	local elapsed, total = self:PlayedAt(self.playhead or self.t0)
	local target = elapsed + seconds
	if target < 0 then
		target = 0
	elseif total and target > total then
		target = total
	end
	local fraction = 0
	if total and total > 0 then
		fraction = target / total
	end
	self:SeekFraction(fraction, true)
end

function ns.Replay:SeekFraction(fraction, immediate)
	if not self.t0 or not self.t1 then
		return
	end
	local _, total = self:PlayedAt(self.t1)
	if not total or total <= 0 then
		self.playhead = self.t0
	else
		self.playhead = self:TimeAtPlayed(total * fraction)
	end
	local indoors = self:InstanceSkipTo(self.playhead)
	if indoors and indoors > self.playhead then
		self.playhead = indoors
	end
	local gap = self:LevelGapSkipTo(self.playhead)
	if gap and gap > self.playhead then
		self.playhead = gap
	end
	self:UpdateDot()
	self:UpdateReadout()
	if immediate then
		self.trailDirty = false
		self.lastTrailRedraw = GetTime()
		if self.route then
			self:Redraw()
		end
	else
		-- The next frame rebuilds the trail from this playhead, including a skip backward.
		self.trailDirty = true
		self.lastTrailRedraw = 0
	end
end

function ns.Replay:SessionsForLevel(lo, hi)
	hi = hi or lo
	local journey = ns.DB.char
	local spans = ns.DB:LevelSpans(journey)
	local sessions = ns.DB:Sessions()
	local picked = {}
	for s = 1, #sessions do
		local session = sessions[s]
		local startAt = session.s
		local stopAt = session.seen or session.s
		if startAt and stopAt then
			for i = 1, #spans do
				local span = spans[i]
				local top = span.lvTo or span.lv
				if top >= lo and span.lv <= hi then
					local spanStop = ns.DB:SpanStop(span, journey) or span.t0
					if stopAt >= span.t0 and startAt <= spanStop then
						picked[#picked + 1] = session
						break
					end
				end
			end
		end
	end
	return picked
end

function ns.Replay:LevelGapSkipTo(at)
	if self.mode ~= "level" or not at or not self.levelLo or not self.t1 then
		return nil
	end
	local hi = self.levelHi or self.levelLo
	local spans = ns.DB:LevelSpans(ns.DB.char)
	local nextStart
	for i = 1, #spans do
		local span = spans[i]
		local top = span.lvTo or span.lv
		if top >= self.levelLo and span.lv <= hi then
			local stop = ns.DB:SpanStop(span, ns.DB.char) or span.t0
			if at >= span.t0 and at <= stop then
				return nil
			end
			if span.t0 > at and (not nextStart or span.t0 < nextStart) then
				nextStart = span.t0
			end
		end
	end
	if not nextStart or nextStart > self.t1 then
		return nil
	end
	return nextStart
end

function ns.Replay:SelectionKey()
	local view = ns.DB.viewKey or ""
	if self.mode == "level" then
		local lo = self.levelLo
		local hi = self.levelHi or lo
		if not lo then
			return view .. "|level|"
		end
		return string.format("%s|level|%d|%d", view, lo, hi)
	end
	local lo = self.sessionLo
	local hi = self.sessionHi or lo
	if self.mode == "span" and lo and hi then
		return string.format("%s|span|%d|%d", view, lo, hi)
	end
	if self.mode == "one" and self.index then
		return string.format("%s|one|%d", view, self.index)
	end
	if self.mode == "current" then
		return view .. "|current"
	end
	if self.mode == "all" then
		return view .. "|all"
	end
	return string.format("%s|%s|%s", view, tostring(self.mode), tostring(self.index or ""))
end

function ns.Replay:RememberPlayhead()
	if not self.playhead then
		return
	end
	self.playheads = self.playheads or {}
	self.playheads[self:SelectionKey()] = self.playhead
end

function ns.Replay:RestorePlayhead()
	local t0, t1 = self.t0, self.t1
	if not t0 then
		self.playhead = nil
		return
	end
	self.playheads = self.playheads or {}
	local saved = self.playheads[self:SelectionKey()]
	if not saved then
		self.playhead = t0
		return
	end
	if saved < t0 then
		self.playhead = t0
	elseif t1 and saved > t1 then
		self.playhead = t1
	else
		self.playhead = saved
	end
end

function ns.Replay:ReloadView()
	local followTail = (not self.playing) and self.playhead and self.t1 and math.abs(self.playhead - self.t1) < 1
	local sessions, index = ns.DB:SelectSessions(self.mode, self.index, self.sessionHi)
	self.sessions = sessions
	self.index = index
	local t0, t1 = Bounds(sessions)
	if self.mode == "level" and self.levelLo then
		local levelStart, levelStop = ns.DB:LevelBounds(ns.DB.char, self.levelLo, self.levelHi)
		if levelStart then
			t0, t1 = levelStart, levelStop or levelStart
			sessions = self:SessionsForLevel(self.levelLo, self.levelHi)
			self.sessions = sessions
		end
	end
	self.t0, self.t1 = t0, t1
	if not self.playhead or not t0 then
		self.playhead = t0 or t1
	elseif followTail then
		self.playhead = t1
	elseif self.playhead < t0 then
		self.playhead = t0
	elseif self.playhead > t1 then
		self.playhead = t1
	end
	self:RefreshList()
	self:UpdateReadout()
end

function ns.Replay:HidePathTip()
	local layer = self.pathLayer
	if layer and GameTooltip:IsOwned(layer) then
		GameTooltip:Hide()
	end
end

function ns.Replay:HoverPath()
	local layer = self.pathLayer
	local canvas = self:Canvas()
	local count = self.segmentCount or 0
	if not self.route or not layer or not canvas or count == 0 then
		return
	end
	local owner = GameTooltip:IsShown() and GameTooltip:GetOwner()
	if owner and owner ~= layer and not owner.zipperPin then
		return
	end
	local scale = canvas:GetEffectiveScale()
	local left, right = canvas:GetLeft(), canvas:GetRight()
	local top, bottom = canvas:GetTop(), canvas:GetBottom()
	if not scale or scale <= 0 or not left or not right or not top or not bottom then
		return
	end
	local width, height = right - left, top - bottom
	if width <= 0 or height <= 0 then
		return
	end
	local rawX, rawY = GetCursorPosition()
	local cx, cy = rawX / scale, rawY / scale
	if cx < left or cx > right or cy > top or cy < bottom then
		self:HidePathTip()
		return
	end
	local px = (cx - left) / width
	local py = (top - cy) / height
	local best, bestDist, bestAlong
	for i = 1, count do
		local seg = self.segments[i]
		if seg and seg.line and seg.line:IsShown() then
			local dx, dy = seg.x2 - seg.x1, seg.y2 - seg.y1
			local len2 = (dx * dx) + (dy * dy)
			local along = 0
			local qx, qy
			if len2 < 0.0000001 then
				qx, qy = seg.x1, seg.y1
			else
				along = ((px - seg.x1) * dx + (py - seg.y1) * dy) / len2
				if along < 0 then
					along = 0
				elseif along > 1 then
					along = 1
				end
				qx = seg.x1 + (dx * along)
				qy = seg.y1 + (dy * along)
			end
			local ax = (left + (qx * width)) * scale
			local ay = (top - (qy * height)) * scale
			local dist = math.sqrt(((rawX - ax) ^ 2) + ((rawY - ay) ^ 2))
			if not bestDist or dist < bestDist then
				best, bestDist, bestAlong = seg, dist, along
			end
		end
	end
	if not best or not best.t1 or bestDist > 12 then
		self:HidePathTip()
		return
	end
	local when = best.t1 + ((best.t2 - best.t1) * bestAlong)
	GameTooltip:SetOwner(layer, "ANCHOR_CURSOR")
	GameTooltip:ClearLines()
	GameTooltip:AddLine(date("%b %d, %H:%M", when), 1, 0.86, 0.45)
	local info = best.map and C_Map.GetMapInfo(best.map)
	if info and info.name then
		GameTooltip:AddLine(info.name, 1, 1, 1)
	end
	if best.mode == ns.Travel.GHOST then
		GameTooltip:AddLine(L["Ghost"], 0.7, 0.7, 0.74)
	elseif best.mode == ns.Travel.FLIGHT then
		GameTooltip:AddLine(L["Flight path"], 0.72, 0.55, 1)
	elseif best.mode == ns.Travel.MOUNT then
		GameTooltip:AddLine(string.format(L["Mounted, %d%% speed"], best.speed or 100), 0.95, 0.75, 0.3)
	elseif (best.speed or 100) > 105 then
		GameTooltip:AddLine(string.format(L["%d%% speed"], best.speed), 0.6, 0.85, 1)
	end
	self:AddCompanyLine(GameTooltip, ns.DB.char, when)
	GameTooltip:Show()
end

function ns.Replay:ClearOverlay()
	self.lineUsed = 0
	self.markerUsed = 0
	self.segmentCount = 0
	self:HidePathTip()
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

function ns.Replay:FollowPlayhead()
	if not self.playing or self.settingMap then
		return
	end
	local mapID = self:PlayheadPlace()
	local map = self:EnsureMap()
	if not mapID or not map or not map:IsShown() or not map.SetMapID or not map.GetMapID then
		return
	end
	if map:GetMapID() == mapID then
		return
	end
	self.settingMap = true
	if C_Map and C_Map.OpenWorldMap and not map:IsShown() then
		C_Map.OpenWorldMap(mapID)
	else
		map:SetMapID(mapID)
	end
	self.settingMap = false
end

function ns.Replay:Redraw()
	if not self.route then
		self:ClearOverlay()
		return
	end
	self:FollowPlayhead()
	local map = self:EnsureMap()
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
	if not self.route then
		self.dirty = true
		return
	end
	if self.frame and self.frame:IsShown() and self.mode ~= "current" and self.mode ~= "all" and self.mode ~= "span" then
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

function ns.Replay:SetMode(mode, index, alreadyRemembered)
	if mode == "current" and ns.DB.playerKey then
		ns.DB:SetView(ns.DB.playerKey)
	end
	if not alreadyRemembered then
		self:RememberPlayhead()
	end
	self.mode = mode
	self.index = index
	self.playing = false
	self:ReloadView()
	self:SyncSessionAnchor()
	self:RestorePlayhead()
	self:StyleModeButtons()
	self:UpdateReadout()
	self:Redraw()
end

function ns.Replay:SyncSessionAnchor()
	if self.mode == "span" then
		return
	end
	local sessions = ns.DB:Sessions()
	if self.mode == "all" then
		self.sessionLo = 1
		self.sessionHi = #sessions
		return
	end
	if self.mode == "one" and self.index then
		self.sessionLo = self.index
		self.sessionHi = self.index
		return
	end
	if self.mode == "current" then
		local current = ns.DB:Current()
		for i = 1, #sessions do
			if sessions[i] == current then
				self.sessionLo = i
				self.sessionHi = i
				return
			end
		end
	end
end

function ns.Replay:ShowSessions()
	if self.mode ~= "level" then
		self:RefreshList()
		self:StyleModeButtons()
		return
	end
	self:RememberPlayhead()
	self.levelLo = nil
	self.levelHi = nil
	local other = ns.DB.viewKey and ns.DB.playerKey and ns.DB.viewKey ~= ns.DB.playerKey
	if other then
		self:SetMode("all", nil, true)
	else
		self:SetMode("current", nil, true)
	end
end

function ns.Replay:SelectAll()
	if self.mode == "level" then
		local groups = self:LevelGroups()
		local lo, hi
		for i = 1, #groups do
			local group = groups[i]
			local top = group.lvTo or group.lv
			if not lo or group.lv < lo then
				lo = group.lv
			end
			if not hi or top > hi then
				hi = top
			end
		end
		if lo then
			self:SelectLevel(lo, hi, false)
		end
		return
	end
	self:SetMode("all")
end

function ns.Replay:SelectSession(index, extend)
	if not index then
		return
	end
	local count = #ns.DB:Sessions()
	if count < 1 then
		return
	end
	if index < 1 then
		index = 1
	elseif index > count then
		index = count
	end
	self:RememberPlayhead()
	if extend and self.sessionLo then
		if index < self.sessionLo then
			self.sessionHi = self.sessionHi or self.sessionLo
			self.sessionLo = index
		else
			self.sessionHi = index
		end
		if self.sessionHi < self.sessionLo then
			self.sessionLo, self.sessionHi = self.sessionHi, self.sessionLo
		end
	else
		self.sessionLo = index
		self.sessionHi = index
	end
	local lo = self.sessionLo
	local hi = self.sessionHi or lo
	if lo <= 1 and hi >= count then
		self:SetMode("all", nil, true)
		return
	end
	if lo == hi then
		local sessions = ns.DB:Sessions()
		if sessions[lo] == ns.DB:Current() then
			self:SetMode("current", nil, true)
			return
		end
		self:SetMode("one", lo, true)
		return
	end
	self:SetMode("span", lo, true)
end

function ns.Replay:StyleModeButtons()
	-- Left-click ShowRoute can SetMode before the replay panel exists.
	local function paint(button, active)
		if not button then
			return
		end
		local font = button:GetFontString()
		if font then
			if active then
				font:SetTextColor(1, 0.86, 0.45)
			else
				font:SetTextColor(0.78, 0.76, 0.70)
			end
		end
		if button.SetBackdropBorderColor then
			if active then
				button:SetBackdropBorderColor(0.85, 0.68, 0.28, 1)
				button:SetBackdropColor(0.20, 0.16, 0.08, 1)
			else
				button:SetBackdropBorderColor(0.38, 0.32, 0.16, 0.9)
				button:SetBackdropColor(0.12, 0.11, 0.10, 1)
			end
		end
	end
	paint(self.sessionButton, self.mode ~= "level")
	paint(self.levelsButton, self.mode == "level")
	paint(self.selectAllButton, false)
end

function ns.Replay:ShowLevel(lo, hi)
	lo = tonumber(lo)
	hi = tonumber(hi) or lo
	if not lo or lo <= 0 then
		return
	end
	if not hi or hi < lo then
		hi = lo
	end
	if ns.DB.playerKey then
		ns.DB:SetView(ns.DB.playerKey)
	end
	self:CreateFrame()
	self.playheads = self.playheads or {}
	self.playheads[string.format("%s|level|%d|%d", ns.DB.viewKey or "", lo, hi)] = nil
	self.levelLo = lo
	self.levelHi = hi
	self.playing = false
	self:SetMode("level", nil, true)
	self.playhead = self.t0
	if self.frame and not self.frame:IsShown() then
		self.frame:Show()
	end
	-- OnShow reloads the view. Park at the start again so Play is the next step.
	self.playing = false
	self.playhead = self.t0
	if self.playButton then
		self.playButton:SetText(L["Play"])
	end
	self:UpdateReadout()
	if self.scroll and self.scroll.SetVerticalScroll then
		self.scroll:SetVerticalScroll(0)
	end
	self:ShowRoute()
end

function ns.Replay:SelectLevel(lo, hi, extend)
	self:RememberPlayhead()
	if extend and self.levelLo and lo then
		hi = hi or lo
		if lo < self.levelLo then
			self.levelHi = self.levelHi or self.levelLo
			self.levelLo = lo
		else
			self.levelHi = hi
		end
		if self.levelHi < self.levelLo then
			self.levelLo, self.levelHi = self.levelHi, self.levelLo
		end
	else
		self.levelLo = lo
		self.levelHi = hi or lo
	end
	self:SetMode("level", nil, true)
end

function ns.Replay:RefreshLevelList()
	local content = self.listContent
	local groups = self:LevelGroups()
	local width = content:GetWidth()
	if width < 40 then
		width = 250
	end
	for i = 1, #groups do
		local group = groups[i]
		local row = self.rows[i]
		if not row then
			row = CreateFrame("Button", nil, content)
			row:SetHeight(22)
			row.bar = row:CreateTexture(nil, "BACKGROUND")
			row.bar:SetAllPoints()
			row.bar:SetColorTexture(0.85, 0.68, 0.28, 0.16)
			row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.label:SetPoint("LEFT", 8, 0)
			row.label:SetPoint("RIGHT", -6, 0)
			row.label:SetJustifyH("LEFT")
			row:SetScript("OnClick", function(button)
				local shift = IsShiftKeyDown and IsShiftKeyDown()
				if shift and issecretvalue and issecretvalue(shift) then
					shift = false
				end
				if button.level then
					ns.Replay:SelectLevel(button.level, button.levelTop or button.level, shift and true or false)
					return
				end
				if button.sessionIndex then
					ns.Replay:SelectSession(button.sessionIndex, shift and true or false)
				end
			end)
			self.rows[i] = row
		end
		row.sessionIndex = nil
		row.level = group.lv
		row.levelTop = group.lvTo or group.lv
		local selected = self.levelLo and row.levelTop >= self.levelLo and row.level <= (self.levelHi or self.levelLo)
		row.label:SetText(self:LevelRowLabel(group))
		row.bar:SetShown(selected)
		if selected then
			row.label:SetTextColor(1, 0.86, 0.45)
		else
			row.label:SetTextColor(0.82, 0.80, 0.74)
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((i - 1) * 22))
		row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
		row:Show()
	end
	for i = #groups + 1, #self.rows do
		self.rows[i]:Hide()
	end
	if self.charButton and ns.DB.char then
		self.charButton:SetText(ns.DB:JourneyLabel(ns.DB.char))
	end
	content:SetHeight(math.max(22, #groups * 22))
end

function ns.Replay:LevelPlace(group)
	if not group or not group.t0 then
		return nil
	end
	local journey = ns.DB.char
	local fromName = self:PlaceName(ns.DB:MapAt(journey, group.t0))
	local endAt = group.last
	if group.open then
		endAt = ns.DB:Now()
	end
	local toName = self:PlaceName(ns.DB:MapAt(journey, endAt or group.t0))
	if fromName and toName and fromName ~= toName then
		return string.format(L["%s to %s"], fromName, toName)
	end
	return fromName or toName
end

function ns.Replay:LevelRowLabel(group)
	local text = string.format("%s    %s", self:LevelName(group), FormatClock(group.seconds or 0))
	local place = self:LevelPlace(group)
	if place then
		text = text .. "    " .. place
	end
	return text
end

function ns.Replay:RefreshList()
	local content = self.listContent
	if not content then
		return
	end
	if self.mode == "level" then
		self:RefreshLevelList()
		return
	end
	local sessions = ns.DB:Sessions()
	if self.charButton and ns.DB.char then
		self.charButton:SetText(ns.DB:JourneyLabel(ns.DB.char))
	end
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
			row:SetHeight(22)
			row.bar = row:CreateTexture(nil, "BACKGROUND")
			row.bar:SetAllPoints()
			row.bar:SetColorTexture(0.85, 0.68, 0.28, 0.16)
			row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.label:SetPoint("LEFT", 8, 0)
			row.label:SetPoint("RIGHT", -6, 0)
			row.label:SetJustifyH("LEFT")
			row:SetScript("OnClick", function(button)
				local shift = IsShiftKeyDown and IsShiftKeyDown()
				if shift and issecretvalue and issecretvalue(shift) then
					shift = false
				end
				if button.level then
					ns.Replay:SelectLevel(button.level, button.levelTop or button.level, shift and true or false)
					return
				end
				if button.sessionIndex then
					ns.Replay:SelectSession(button.sessionIndex, shift and true or false)
				end
			end)
			self.rows[i] = row
		end
		row.sessionIndex = index
		row.level = nil
		local duration = (session.seen or session.s) - session.s
		local lo = self.sessionLo
		local hi = self.sessionHi or lo
		local selected = false
		if self.mode == "all" then
			selected = true
		elseif self.mode == "span" and lo and hi then
			selected = index >= lo and index <= hi
		elseif self.mode == "one" then
			selected = self.index == index
		elseif self.mode == "current" then
			selected = session == ns.DB:Current()
		end
		local gained = ns.DB:LevelsGained(session)
		row.label:SetText(string.format(L["%s    %s    +%.2f lv    %d kills"], date("%m/%d %H:%M", session.s), FormatClock(duration), gained, session.kills or 0))
		row.bar:SetShown(selected)
		if selected then
			row.label:SetTextColor(1, 0.86, 0.45)
		else
			row.label:SetTextColor(0.82, 0.80, 0.74)
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((i - 1) * 22))
		row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
		row:Show()
	end
	for i = #sessions + 1, #self.rows do
		self.rows[i]:Hide()
	end
	content:SetHeight(math.max(22, #sessions * 22))
end

function ns.Replay:TogglePlay()
	if not self.t0 or not self.t1 then
		return
	end
	if self.playing then
		self.playing = false
		self.playButton:SetText(L["Play"])
		return
	end
	if self.playhead >= self.t1 - 0.05 then
		self.playhead = self.t0
	end
	self.playing = true
	self.route = true
	self.playButton:SetText(L["Pause"])
	local map = self:EnsureMap()
	if map and not map:IsShown() and ToggleWorldMap then
		ToggleWorldMap()
	end
end

function ns.Replay:StyleSpeedButtons()
	local buttons = self.speedButtons
	if not buttons then
		return
	end
	for i = 1, #buttons do
		local button = buttons[i]
		local active = button.speed == self.speed
		local font = button:GetFontString()
		if font then
			if active then
				font:SetTextColor(1, 0.86, 0.45)
			else
				font:SetTextColor(0.78, 0.76, 0.70)
			end
		end
		if active then
			button:SetBackdropBorderColor(0.85, 0.68, 0.28, 1)
			button:SetBackdropColor(0.20, 0.16, 0.08, 1)
		else
			button:SetBackdropBorderColor(0.38, 0.32, 0.16, 0.9)
			button:SetBackdropColor(0.12, 0.11, 0.10, 1)
		end
	end
end

function ns.Replay:SetSpeed(speed)
	self.speed = speed
	self:StyleSpeedButtons()
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
	if self.playing and self.t0 then
		self.playhead = self.playhead + (elapsed * self.speed)
		local indoors = self:InstanceSkipTo(self.playhead)
		if indoors and indoors > self.playhead then
			self.playhead = indoors
		end
		local gap = self:LevelGapSkipTo(self.playhead)
		if gap and gap > self.playhead then
			self.playhead = gap
		end
		if self.playhead >= self.t1 then
			self.playhead = self.t1
			self.playing = false
			self.playButton:SetText(L["Play"])
		end
		self:FollowPlayhead()
		self:UpdateDot()
		self:UpdateReadout()
		self.trailDirty = true
	end
	-- Keep the drawn tip within about four seconds of travel. High playback speeds redraw more often.
	local trailWait = 4 / math.max(self.speed or 1, 1)
	if trailWait < 0.05 then
		trailWait = 0.05
	elseif trailWait > 0.25 then
		trailWait = 0.25
	end
	if self.trailDirty and (GetTime() - (self.lastTrailRedraw or 0)) >= trailWait then
		self.lastTrailRedraw = GetTime()
		self.trailDirty = false
		if self.route then
			self:Redraw()
		end
	elseif self.playing and (self.segmentCount or 0) > 0 then
		self:RefreshTrailFade()
	end
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
	WorldMapFrame:HookScript("OnShow", function()
		if not ns.Replay.route then
			return
		end
		if ns.Replay:UseCurrentTrailOutsidePanel() then
			return
		end
		ns.Replay:Redraw()
	end)
	WorldMapFrame:HookScript("OnHide", function()
		ns.Replay.playing = false
		if ns.Replay.playButton then
			ns.Replay.playButton:SetText(L["Play"])
		end
		ns.Replay:ClearOverlay()
	end)
	local canvas = self:Canvas()
	if canvas then
		canvas:HookScript("OnSizeChanged", function()
			ns.Replay:Redraw()
		end)
	end
	if WorldMapFrame.OnCanvasScaleChanged then
		hooksecurefunc(WorldMapFrame, "OnCanvasScaleChanged", function()
			if ns.Replay.route then
				ns.Replay:Redraw()
			else
				ns.Replay:RescalePins()
			end
		end)
	end
	local scroll = WorldMapFrame.ScrollContainer
	if scroll and not self.cursorWatch then
		self.cursorWatch = true
		scroll:HookScript("OnUpdate", function()
			if ns.Replay.route and WorldMapFrame:IsShown() then
				ns.Replay:HoverPath()
			end
		end)
	end
end

function ns.Replay:RescalePins()
	local host = ns.Map:Use()
	if self.markers then
		for i = 1, self.markerUsed or 0 do
			host:FitPin(self.markers[i], PIP)
		end
	end
	if self.dot then
		host:FitPin(self.dot, 12)
	end
end

function ns.Replay:SaveWindow()
	local frame = self.frame
	if not frame then
		return
	end
	local point, _, _, x, y = frame:GetPoint(1)
	ZipperDB = ZipperDB or {}
	ZipperDB.window = {
		point = point,
		x = x,
		y = y,
		w = frame:GetWidth(),
		h = frame:GetHeight(),
	}
end

function ns.Replay:Layout(width, height)
	local inset = self.listInset
	if not inset or not width or not height or width < 1 or height < 1 then
		return
	end
	local listTop = 118
	local gap = 12
	local controls = 186
	local after = 14
	local bottom = 12
	local leftover = height - (listTop + gap + controls + after + bottom)
	local listH = math.floor(leftover * 0.42)
	if listH < 64 then
		listH = 64
	end
	if leftover - listH < 48 then
		listH = leftover - 48
	end
	if listH < 48 then
		listH = 48
	end
	inset:SetHeight(listH)
	local y = -(listTop + listH + gap)
	local frame = self.frame
	self.chapterPrev:ClearAllPoints()
	self.chapterPrev:SetPoint("TOPLEFT", 14, y)
	self.chapterNext:ClearAllPoints()
	self.chapterNext:SetPoint("TOPRIGHT", -14, y)
	self.scrub:ClearAllPoints()
	self.scrub:SetPoint("TOPLEFT", 16, y - 44)
	self.scrub:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	self.timeText:ClearAllPoints()
	self.timeText:SetPoint("TOPLEFT", 16, y - 68)
	self.timeText:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	for i = 1, #self.jumpButtons do
		self.jumpButtons[i]:ClearAllPoints()
		self.jumpButtons[i]:SetPoint("TOPLEFT", 14 + ((i - 1) * 78), y - 90)
	end
	self.playButton:ClearAllPoints()
	self.playButton:SetPoint("TOPLEFT", 14, y - 120)
	for i = 1, #self.speedButtons do
		self.speedButtons[i]:ClearAllPoints()
		self.speedButtons[i]:SetPoint("TOPLEFT", 76 + ((i - 1) * 50), y - 120)
	end
	self.trailLabel:ClearAllPoints()
	self.trailLabel:SetPoint("TOPLEFT", 16, y - 150)
	self.trailValue:ClearAllPoints()
	self.trailValue:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, y - 150)
	self.trailSlider:ClearAllPoints()
	self.trailSlider:SetPoint("TOPLEFT", 16, y - 168)
	self.trailSlider:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	self.statInset:ClearAllPoints()
	self.statInset:SetPoint("TOPLEFT", 14, y - controls - after)
	self.statInset:SetPoint("BOTTOMRIGHT", -14, bottom)
	local contentWidth = width - 58
	if contentWidth < 200 then
		contentWidth = 200
	end
	if self.listContent then
		self.listContent:SetWidth(contentWidth)
	end
	if self.statContent then
		self.statContent:SetWidth(contentWidth)
	end
end

function ns.Replay:CreateFrame()
	if self.frame then
		return
	end
	local frame = CreateFrame("Frame", "ZipperReplayFrame", UIParent, "BackdropTemplate")
	frame:Hide()
	frame:SetSize(336, 736)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:SetResizable(true)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(336, 470, 440, 760)
	else
		frame:SetMinResize(336, 470)
		frame:SetMaxResize(440, 760)
	end
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
		insets = { left = 1, right = 1, top = 1, bottom = 1 },
	})
	frame:SetBackdropColor(0.07, 0.07, 0.08, 0.97)
	frame:SetBackdropBorderColor(0.62, 0.50, 0.22, 0.95)
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		ns.Replay:SaveWindow()
	end)
	frame:SetScript("OnSizeChanged", function(self, width, height)
		ns.Replay:Layout(width, height)
	end)
	frame:SetScript("OnShow", function()
		ns.Replay:HookMap()
		ns.Replay:EnsureDot()
		ns.Replay:ReloadView()
		ns.Replay:Redraw()
	end)
	frame:SetScript("OnHide", function()
		ns.Replay.playing = false
		if ns.Replay.playButton then
			ns.Replay.playButton:SetText(L["Play"])
		end
		-- Closing replay keeps the route on when it was on, and drops past /
		-- other-character browse so a later standalone map shows the live trail.
		ns.Replay:UseCurrentTrailOutsidePanel()
	end)
	frame:SetScript("OnUpdate", function(self, elapsed)
		ns.Replay:OnUpdate(self, elapsed)
	end)
	tinsert(UISpecialFrames, "ZipperReplayFrame")

	local function MakeButton(parent, text, width)
		local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
		button:SetSize(width, 22)
		button:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Buttons\\WHITE8X8",
			edgeSize = 1,
		})
		button:SetBackdropColor(0.12, 0.11, 0.10, 1)
		button:SetBackdropBorderColor(0.38, 0.32, 0.16, 0.9)
		local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		label:SetPoint("CENTER")
		label:SetText(text)
		button:SetFontString(label)
		button:SetScript("OnEnter", function(self)
			if self:GetFontString() then
				self:GetFontString():SetTextColor(1, 0.9, 0.6)
			end
		end)
		button:SetScript("OnLeave", function()
			ns.Replay:StyleModeButtons()
		end)
		return button
	end

	local header = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
	header:SetColorTexture(0.11, 0.10, 0.09, 1)
	header:SetPoint("TOPLEFT", 1, -1)
	header:SetPoint("TOPRIGHT", -1, -1)
	header:SetHeight(46)

	local rule = frame:CreateTexture(nil, "BORDER")
	rule:SetColorTexture(0.62, 0.50, 0.22, 0.85)
	rule:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
	rule:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
	rule:SetHeight(1)

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -8)
	title:SetText(L["Zipper"])

	local charButton = CreateFrame("Button", nil, frame, "BackdropTemplate")
	charButton:SetPoint("TOPLEFT", 12, -26)
	charButton:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
	charButton:SetHeight(20)
	charButton:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	charButton:SetBackdropColor(0.05, 0.04, 0.03, 1)
	charButton:SetBackdropBorderColor(0.85, 0.68, 0.28, 1)
	local arrow = charButton:CreateTexture(nil, "OVERLAY")
	arrow:SetSize(16, 16)
	arrow:SetPoint("RIGHT", -4, 0)
	arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
	charButton.arrow = arrow
	local charLabel = charButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	charLabel:SetPoint("LEFT", 8, 0)
	charLabel:SetPoint("RIGHT", arrow, "LEFT", -4, 0)
	charLabel:SetJustifyH("LEFT")
	charLabel:SetWordWrap(false)
	charLabel:SetText(L["Character"])
	charButton:SetFontString(charLabel)
	charButton:SetScript("OnClick", function()
		ns.Replay:ToggleCharacters()
	end)
	charButton:SetScript("OnEnter", function(self)
		self:SetBackdropBorderColor(1, 0.86, 0.45, 1)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(L["Choose a character"])
		GameTooltip:Show()
	end)
	charButton:SetScript("OnLeave", function(self)
		self:SetBackdropBorderColor(0.85, 0.68, 0.28, 1)
		if GameTooltip:IsOwned(self) then
			GameTooltip:Hide()
		end
	end)
	charButton:SetScript("OnMouseDown", function(self)
		self.arrow:SetPoint("RIGHT", -3, -1)
	end)
	charButton:SetScript("OnMouseUp", function(self)
		self.arrow:SetPoint("RIGHT", -4, 0)
	end)

	local charPicker = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	charPicker:SetPoint("TOPLEFT", charButton, "BOTTOMLEFT", 0, -2)
	charPicker:SetPoint("RIGHT", charButton, "RIGHT", 0, 0)
	charPicker:SetFrameStrata("DIALOG")
	charPicker:SetFrameLevel(400)
	charPicker:Hide()
	charPicker:EnableMouse(true)
	charPicker:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	charPicker:SetBackdropColor(0.08, 0.07, 0.06, 0.98)
	charPicker:SetBackdropBorderColor(0.62, 0.50, 0.22, 0.95)
	charPicker:SetScript("OnShow", function()
		ns.Replay:StyleCharButton()
	end)
	charPicker:SetScript("OnHide", function()
		ns.Replay:StyleCharButton()
	end)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", 2, 2)

	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetFrameLevel(frame:GetFrameLevel() + 20)
	grip:SetPoint("BOTTOMRIGHT", -2, 2)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(L["Drag to resize"])
		GameTooltip:Show()
	end)
	grip:SetScript("OnLeave", function(self)
		if GameTooltip:IsOwned(self) then
			GameTooltip:Hide()
		end
	end)
	grip:RegisterForDrag("LeftButton")
	grip:SetScript("OnDragStart", function()
		frame:StartSizing("BOTTOMRIGHT")
	end)
	grip:SetScript("OnDragStop", function()
		frame:StopMovingOrSizing()
		ns.Replay:SaveWindow()
	end)

	local options = MakeButton(frame, L["Options"], 64)
	options:SetPoint("RIGHT", close, "LEFT", 4, -2)
	options:SetScript("OnClick", function()
		ns.Config:Toggle()
	end)

	local sessionButton = MakeButton(frame, L["Sessions"], 96)
	sessionButton:SetPoint("TOPLEFT", 14, -56)
	sessionButton:SetScript("OnClick", function()
		ns.Replay:ShowSessions()
	end)

	local levelsButton = MakeButton(frame, L["Levels"], 88)
	levelsButton:SetPoint("LEFT", sessionButton, "RIGHT", 6, 0)
	levelsButton:SetScript("OnClick", function()
		ns.Replay:RememberPlayhead()
		ns.Replay.levelLo = nil
		ns.Replay.levelHi = nil
		ns.Replay:SetMode("level", nil, true)
	end)

	local selectAll = MakeButton(frame, L["Select all"], 104)
	selectAll:SetPoint("TOPRIGHT", -14, -56)
	selectAll:SetScript("OnClick", function()
		ns.Replay:SelectAll()
	end)

	local scope = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	scope:SetPoint("TOPLEFT", 16, -84)
	scope:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	scope:SetJustifyH("LEFT")
	scope:SetWordWrap(true)
	scope:SetText(L["The recording in progress."])

	local inset = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	inset:SetPoint("TOPLEFT", 14, -118)
	inset:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
	inset:SetHeight(168)
	inset:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	inset:SetBackdropColor(0, 0, 0, 0.35)
	inset:SetBackdropBorderColor(0.35, 0.30, 0.16, 0.85)

	local scroll = CreateFrame("ScrollFrame", nil, inset, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 6, -4)
	scroll:SetPoint("BOTTOMRIGHT", -24, 4)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(260, 22)
	scroll:SetScrollChild(content)

	local play = MakeButton(frame, L["Play"], 56)
	play:SetPoint("TOPLEFT", 14, -418)
	play:SetScript("OnClick", function()
		ns.Replay:TogglePlay()
	end)
	play:SetScript("OnLeave", function(self)
		local font = self:GetFontString()
		if font then
			font:SetTextColor(1, 1, 1)
		end
	end)

	local speedButtons = {}
	local speedWidth, speedGap = 46, 4
	for i = 1, #SPEEDS do
		local rate = SPEEDS[i]
		local speed = MakeButton(frame, rate .. "x", speedWidth)
		speed.speed = rate
		speed:SetPoint("TOPLEFT", 76 + ((i - 1) * (speedWidth + speedGap)), -418)
		speed:SetScript("OnClick", function(button)
			ns.Replay:SetSpeed(button.speed)
		end)
		speed:SetScript("OnLeave", function()
			ns.Replay:StyleSpeedButtons()
		end)
		speedButtons[i] = speed
	end

	local trailLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	trailLabel:SetPoint("TOPLEFT", 16, -448)
	trailLabel:SetText(L["Trail"])
	trailLabel:SetTextColor(0.85, 0.82, 0.70)

	local trailValue = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	trailValue:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -16, -448)
	trailValue:SetTextColor(1, 0.86, 0.45)
	trailValue:SetText(L["Full"])

	local trail = CreateFrame("Slider", "ZipperReplayTrail", frame, "UISliderTemplate")
	trail:SetPoint("TOPLEFT", 16, -466)
	trail:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	trail:SetHeight(16)
	trail:SetMinMaxValues(1, #ns.Replay.TRAIL_STOPS)
	trail:SetValueStep(1)
	trail:SetValue(#ns.Replay.TRAIL_STOPS)
	trail:SetObeyStepOnDrag(true)
	for _, key in ipairs({ "Low", "High", "Text" }) do
		local label = trail[key] or _G[trail:GetName() .. key]
		if label then
			label:Hide()
		end
	end
	trail:SetScript("OnValueChanged", function(slider, value)
		if ns.Replay.lockTrail then
			return
		end
		local stops = ns.Replay.TRAIL_STOPS
		local index = math.floor(value + 0.5)
		if index < 1 then
			index = 1
		elseif index > #stops then
			index = #stops
		end
		if math.abs(slider:GetValue() - index) > 0.01 then
			ns.Replay.lockTrail = true
			slider:SetValue(index)
			ns.Replay.lockTrail = false
		end
		ns.Replay:SetReplayTrail(stops[index])
	end)

	local jumpButtons = {}
	local jumpWidth, jumpGap = 72, 6
	for i = 1, 4 do
		local jump = MakeButton(frame, "+0", jumpWidth)
		jump:SetPoint("TOPLEFT", 14 + ((i - 1) * (jumpWidth + jumpGap)), -388)
		jump:SetScript("OnClick", function(button)
			ns.Replay:Jump(button.jumpSeconds or 0)
		end)
		jump:SetScript("OnLeave", function(self)
			local font = self:GetFontString()
			if font then
				font:SetTextColor(1, 1, 1)
			end
		end)
		jumpButtons[i] = jump
	end

	local chapterPrev = MakeButton(frame, "<", 36)
	chapterPrev:SetPoint("TOPLEFT", 14, -298)
	chapterPrev:SetScript("OnClick", function()
		ns.Replay:SkipChapter(-1)
	end)
	chapterPrev:SetScript("OnEnter", function(self)
		local font = self:GetFontString()
		if font then
			font:SetTextColor(1, 0.9, 0.6)
		end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(L["Previous chapter"])
		GameTooltip:Show()
	end)
	chapterPrev:SetScript("OnLeave", function(self)
		local font = self:GetFontString()
		if font then
			font:SetTextColor(1, 1, 1)
		end
		if GameTooltip:IsOwned(self) then
			GameTooltip:Hide()
		end
	end)

	local chapterNext = MakeButton(frame, ">", 36)
	chapterNext:SetPoint("TOPRIGHT", -14, -298)
	chapterNext:SetScript("OnClick", function()
		ns.Replay:SkipChapter(1)
	end)
	chapterNext:SetScript("OnEnter", function(self)
		local font = self:GetFontString()
		if font then
			font:SetTextColor(1, 0.9, 0.6)
		end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(L["Next chapter"])
		GameTooltip:Show()
	end)
	chapterNext:SetScript("OnLeave", function(self)
		local font = self:GetFontString()
		if font then
			font:SetTextColor(1, 1, 1)
		end
		if GameTooltip:IsOwned(self) then
			GameTooltip:Hide()
		end
	end)

	local chapterText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	chapterText:SetPoint("LEFT", chapterPrev, "RIGHT", 6, 0)
	chapterText:SetPoint("RIGHT", chapterNext, "LEFT", -6, 0)
	chapterText:SetJustifyH("CENTER")
	chapterText:SetWordWrap(false)
	chapterText:SetTextColor(0.93, 0.90, 0.78)
	chapterText:SetText(L["No chapters yet"])

	local scrub = CreateFrame("Slider", "ZipperReplayScrub", frame, "UISliderTemplate")
	scrub:SetPoint("TOPLEFT", 16, -342)
	scrub:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	scrub:SetHeight(16)
	scrub:SetMinMaxValues(0, 1)
	-- A nine-hour session needs a much finer step than one tenth of a percent.
	scrub:SetValueStep(0.00001)
	scrub:SetValue(1)
	scrub:SetObeyStepOnDrag(true)
	for _, key in ipairs({ "Low", "High", "Text" }) do
		local label = scrub[key] or _G[scrub:GetName() .. key]
		if label then
			label:Hide()
		end
	end
	scrub:SetScript("OnValueChanged", function(_, value)
		if ns.Replay.lockScrub then
			return
		end
		ns.Replay.playing = false
		if ns.Replay.playButton then
			ns.Replay.playButton:SetText(L["Play"])
		end
		ns.Replay:SeekFraction(value)
	end)

	local timeText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	timeText:SetPoint("TOPLEFT", 16, -366)
	timeText:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	timeText:SetJustifyH("LEFT")
	timeText:SetTextColor(0.85, 0.82, 0.70)

	local statInset = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	statInset:SetPoint("TOPLEFT", 14, -500)
	statInset:SetPoint("BOTTOMRIGHT", -14, 12)
	statInset:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	statInset:SetBackdropColor(0, 0, 0, 0.35)
	statInset:SetBackdropBorderColor(0.35, 0.30, 0.16, 0.85)

	local statScroll = CreateFrame("ScrollFrame", "ZipperReplayStats", statInset, "UIPanelScrollFrameTemplate")
	statScroll:SetPoint("TOPLEFT", 4, -4)
	statScroll:SetPoint("BOTTOMRIGHT", -22, 4)
	local statContent = CreateFrame("Frame", nil, statScroll)
	statContent:SetSize(260, 16)
	statScroll:SetScrollChild(statContent)

	self.listInset = inset
	self.frame = frame
	self.scopeText = scope
	self.titleText = title
	self.closeButton = close
	self.optionsButton = options
	self.charButton = charButton
	self.charPicker = charPicker
	self.charRows = {}
	self.sessionButton = sessionButton
	self.levelsButton = levelsButton
	self.selectAllButton = selectAll
	self.scroll = scroll
	self.listContent = content
	self.rows = {}
	self.playButton = play
	self.speedButtons = speedButtons
	self:StyleSpeedButtons()
	self.scrub = scrub
	self.jumpButtons = jumpButtons
	self.chapterPrev = chapterPrev
	self.chapterNext = chapterNext
	self.chapterText = chapterText
	self.timeText = timeText
	self.trailLabel = trailLabel
	self.trailValue = trailValue
	self.trailSlider = trail
	self.statInset = statInset
	self.statScroll = statScroll
	self.statContent = statContent
	self.statRows = {}
	-- The route can already have drawn into these pools. Replacing the tables
	-- leaves the old textures on the map, stuck to the first view.
	self:EnsurePools()

	local window = ZipperDB and ZipperDB.window
	frame:ClearAllPoints()
	if window and window.point then
		frame:SetPoint(window.point, UIParent, window.point, window.x or 0, window.y or 0)
	else
		frame:SetPoint("RIGHT", UIParent, "RIGHT", -40, 40)
	end
	local width = window and tonumber(window.w) or 336
	local height = window and tonumber(window.h) or 736
	if not width or width < 336 then
		width = 336
	elseif width > 440 then
		width = 440
	end
	if not height or height < 470 then
		height = 470
	elseif height > 760 then
		height = 760
	end
	frame:SetSize(width, height)
	self:Layout(width, height)
	self:ApplySkin()
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
	dot.texture:SetTexture("Interface\\AddOns\\Zipper\\Media\\Circle")
	local r, g, b = self:ClassColor()
	dot.texture:SetVertexColor(r, g, b, 1)
	dot.parked = false
	dot:EnableMouse(false)
	self.dot = dot
end

function ns.Replay:UseCurrentTrailOutsidePanel()
	if self.frame and self.frame:IsShown() then
		return false
	end
	self.levelLo, self.levelHi = nil, nil
	if self.route then
		self:SetMode("current", nil, true)
	else
		if ns.DB.playerKey then
			ns.DB:SetView(ns.DB.playerKey)
		end
		self.mode = "current"
		self.index = nil
		self:ClearOverlay()
	end
	return true
end

function ns.Replay:ShowRoute()
	self.route = true
	if not self.sessions then
		self:ReloadView()
	end
	local map = self:EnsureMap()
	if map and not map:IsShown() and ToggleWorldMap then
		ToggleWorldMap()
	end
	self:HookMap()
	self:EnsureDot()
	if not (self.frame and self.frame:IsShown()) then
		if self:UseCurrentTrailOutsidePanel() then
			return
		end
	end
	self:Redraw()
end

function ns.Replay:Toggle()
	self:CreateFrame()
	if self.frame:IsShown() then
		self.playing = false
		self.frame:Hide()
		return
	end
	self:ShowRoute()
	self.frame:Show()
	self:SetMode(self.mode or "current", self.index)
end

function ns.Replay:ToggleRoute()
	if self.route then
		self.route = false
		self.playing = false
		if self.playButton then
			self.playButton:SetText(L["Play"])
		end
		self:ClearOverlay()
		return
	end
	self:ShowRoute()
end

function ns.Replay:RaiseMapButton(button)
	-- Krowi parents the button to WorldMapFrame, under the scroll container that
	-- holds the map art. RareScanner's template is HIGH; a plain button is not,
	-- so the map draws over it. Keep it on the scroll container, above that art.
	local container = WorldMapFrame and WorldMapFrame.ScrollContainer
	if container and button:GetParent() ~= container then
		button:SetParent(container)
	end
	button:SetFrameStrata("HIGH")
	button:SetFrameLevel(510)
end

function ns.Replay:StyleMapButton(button)
	button:SetSize(32, 32)
	self:RaiseMapButton(button)
	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetSize(25, 25)
	background:SetPoint("TOPLEFT", 2, -4)
	button.icon = button:CreateTexture(nil, "ARTWORK")
	button.icon:SetTexture("Interface\\AddOns\\Zipper\\Media\\MapButton")
	button.icon:SetSize(18, 18)
	button.icon:SetPoint("CENTER", 0, 1)
	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetSize(54, 54)
	border:SetPoint("TOPLEFT")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
	-- This client rejects modifier click names such as Shift-RightButtonUp.
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:SetScript("OnClick", function(_, mouseButton)
		local shift = false
		if mouseButton == "RightButton" and IsShiftKeyDown then
			shift = IsShiftKeyDown()
			if issecretvalue and issecretvalue(shift) then
				shift = false
			end
		end
		if shift then
			ns.Config:Toggle()
		elseif mouseButton == "RightButton" then
			ns.Replay:Toggle()
		else
			ns.Replay:ToggleRoute()
		end
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(L["Zipper"], 1, 0.82, 0)
		GameTooltip:AddLine(L["Left click: show or hide the route."], 1, 1, 1, true)
		GameTooltip:AddLine(L["Right click: open the replay and show the route."], 1, 1, 1, true)
		GameTooltip:AddLine(L["Shift+right click: open settings."], 1, 1, 1, true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	-- Krowi calls this on every map change before it reflows the column.
	button.Refresh = function()
		ns.Replay:RaiseMapButton(button)
	end
end

function ns.Replay:CreateMapButton()
	if self.mapButton or not WorldMapFrame then
		return
	end
	-- RareScanner's corner buttons are Krowi_WorldMapButtonsN. That library owns
	-- the column. Anchoring under "whoever is lowest" fights OneForAll, because
	-- both keep moving under each other until the anchors form a circle.
	local lib = LibStub and LibStub("Krowi_WorldMapButtons-1.4", true)
	if not lib then
		return
	end
	local button = lib:Add(nil, "Button")
	self:StyleMapButton(button)
	button:Show()
	if lib.SetPoints then
		lib.SetPoints()
	end
	self.mapButton = button
end

function ns.Replay:ApplySkin()
	local skin = self.skin
	local frame = self.frame
	if not skin or not frame or self.skinApplied then
		return
	end
	local function paint(fn, ...)
		if type(fn) == "function" then
			fn(...)
		end
	end
	local ok, err = pcall(function()
		paint(skin.Shell, frame)
		if self.closeButton then
			paint(skin.CloseButton, self.closeButton)
		end
		local buttons = { self.sessionButton, self.selectAllButton, self.playButton, self.optionsButton }
		if self.speedButtons then
			for j = 1, #self.speedButtons do
				buttons[#buttons + 1] = self.speedButtons[j]
			end
		end
		if self.jumpButtons then
			for j = 1, #self.jumpButtons do
				buttons[#buttons + 1] = self.jumpButtons[j]
			end
		end
		buttons[#buttons + 1] = self.chapterPrev
		buttons[#buttons + 1] = self.chapterNext
		buttons[#buttons + 1] = self.levelsButton
		for i = 1, #buttons do
			local button = buttons[i]
			if button then
				paint(skin.Button, button)
				paint(skin.WhiteButtonLabel, button)
			end
		end
		local bars = {
			self.scroll and (self.scroll.ScrollBar or self.scroll.scrollBar),
			self.statScroll and (self.statScroll.ScrollBar or self.statScroll.scrollBar),
		}
		for i = 1, #bars do
			if bars[i] then
				paint(skin.ScrollBar, bars[i])
			end
		end
		if self.titleText then
			paint(skin.Font, self.titleText)
		end
		if self.timeText then
			paint(skin.Font, self.timeText)
		end
		if self.trailLabel then
			paint(skin.Font, self.trailLabel)
		end
		if self.trailValue then
			paint(skin.Font, self.trailValue)
		end
	end)
	self.skinApplied = true
	if not ok then
		ns:Print(string.format(L["EllesmereUI skin skipped: %s"], tostring(err)))
	end
	self:StyleSpeedButtons()
	if self.sessionButton then
		self:StyleModeButtons()
	end
end

function ns.Replay:RegisterSkin()
	if self.skinRegistered then
		return
	end
	local eui = _G.EllesmereUI
	if not eui or not eui.RegisterSkin then
		return
	end
	self.skinRegistered = true
	eui.RegisterSkin("Zipper", function(S)
		ns.Replay.skin = S
		ns.Replay:ApplySkin()
	end)
end

-- Local addon links only. The client delivers the click through SetItemRef.
if EventRegistry and EventRegistry.RegisterCallback then
	EventRegistry:RegisterCallback("SetItemRef", function(_, link, _, button)
		if button and button ~= "LeftButton" then
			return
		end
		local modified = IsModifiedClick and IsModifiedClick()
		if modified and not (issecretvalue and issecretvalue(modified)) then
			return
		end
		local lo, hi = ns.DB:LevelFromLink(link)
		if not lo then
			return
		end
		ns.Replay:ShowLevel(lo, hi)
	end, ns.Replay)
end

function ns.Replay:Init()
	ns.OnDataChanged = function()
		ns.Replay:OnDataChanged()
	end
	self:EnsureUnitTip()
	self:RegisterSkin()
	local waiter = CreateFrame("Frame")
	waiter:RegisterEvent("PLAYER_LOGIN")
	waiter:RegisterEvent("ADDON_LOADED")
	waiter:SetScript("OnEvent", function(self, event, name)
		if event == "ADDON_LOADED" and name ~= "Blizzard_WorldMap" and not WorldMapFrame then
			return
		end
		if not WorldMapFrame then
			return
		end
		self:UnregisterAllEvents()
		ns.Replay:CreateMapButton()
	end)
end

ns.Replay:EnsureUnitTip()
