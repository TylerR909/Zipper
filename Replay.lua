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
-- Same-spot casts collapse; the tip also hides fish pips under the playhead.
local FISH_DEDUP_YARDS = 10
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
local MEDIA_CIRCLE = "Interface\\AddOns\\Zipper\\Media\\Circle"
local MEDIA_RING = "Interface\\AddOns\\Zipper\\Media\\Ring"
-- Elite portrait chrome is gold; keep the kill fill red and ring the pip.
local ELITE_BORDER_R, ELITE_BORDER_G, ELITE_BORDER_B = 1.00, 0.82, 0.20
local MAP_TYPE_ZONE = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3

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
		local track = ns.DB:LoadedTrack(session)
		local n, first, last
		if track then
			n = #(track.t or {})
			if n > 0 then
				first = session.s + track.t[1]
				last = session.s + track.t[n]
			end
		else
			n = ns.DB:TrackCounts(session)
			if n > 0 then
				first = session.s
				last = session.seen or session.s
			end
		end
		points = points + n
		if first then
			if not t0 or first < t0 then
				t0 = first
			end
			if not t1 or last > t1 then
				t1 = last
			end
		end
	end
	-- Open recording: keep t1 at Now so idle time after the last GPS sample
	-- (AFK at the inn) stays inside the scrubber and playhead window.
	local current = ns.DB.session
	if current then
		for s = 1, #sessions do
			if sessions[s] == current then
				local stop = ns.DB:SessionStop(current)
				if stop and (not t1 or stop > t1) then
					t1 = stop
				end
				if not t0 and type(current.s) == "number" then
					t0 = current.s
				end
				break
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
	if not view or not mapID or mapID <= 0 then
		return nil
	end
	if mapID == view then
		return x, y
	end
	if self.rectCacheView ~= view then
		self.rectCacheView = view
		self.rectCache = {}
	end
	local rect = self.rectCache[mapID]
	if rect == nil then
		local minX, maxX, minY, maxY = C_Map.GetMapRectOnMap(mapID, view)
		if minX and maxX and minY and maxY and maxX > minX and maxY > minY then
			rect = { minX, maxX - minX, minY, maxY - minY }
		else
			rect = false
		end
		self.rectCache[mapID] = rect
	end
	if not rect then
		return nil
	end
	local px = rect[1] + (x * rect[2])
	local py = rect[3] + (y * rect[4])
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

function ns.Replay:AcquireLine(layer)
	layer = layer or self:PathLayer()
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
	local n = #track.t
	local eventCount = track.ek and #track.ek or 0
	if not self.inferredModes then
		self.inferredModes = setmetatable({}, { __mode = "k" })
	end
	local cached = self.inferredModes[track]
	if cached and cached.n == n and cached.ev == eventCount then
		return cached.modes
	end
	local modes = {}
	local taxi, mounted = false, false
	local eventIndex = 1
	for i = 1, n do
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
	self.inferredModes[track] = { n = n, ev = eventCount, modes = modes }
	return modes
end

function ns.Replay:PlaceLine(line, x1, y1, x2, y2, mode, speed, trailAlpha, width, height, scale)
	local parent = line:GetParent()
	width = width or (parent and parent:GetWidth())
	height = height or (parent and parent:GetHeight())
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
	if not scale then
		local canvas = self:Canvas()
		scale = (canvas and canvas:GetScale()) or 1
	end
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
		marker.border = marker:CreateTexture(nil, "ARTWORK")
		marker.border:SetAllPoints()
		marker.border:SetTexture(MEDIA_RING)
		marker.border:Hide()
		marker.texture = marker:CreateTexture(nil, "OVERLAY")
		marker.texture:SetAllPoints()
		marker.texture:SetTexture(MEDIA_CIRCLE)
		marker.pipSize = PIP
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
			elseif pin.kind == Kind.PORTAL or pin.kind == Kind.TRAINER or pin.kind == Kind.SUMMON or pin.kind == Kind.CAMP or pin.kind == Kind.SLEEP or pin.kind == Kind.FISH then
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
		self.markers[i].pipSize = nil
	end
end

-- Circle for dense marks; Ring for rarer milestones. Sizes stay small so kills
-- and quest clusters do not blot out the route.
function ns.Replay:PaintMarker(marker, kind, extra)
	local spec = ns.EventSpec and ns.EventSpec[kind]
	local pip = spec and spec.pip
	local texture = (pip and pip.shape == "ring") and MEDIA_RING or MEDIA_CIRCLE
	local size = (pip and pip.size) or PIP
	local color = (pip and pip.color) or (spec and spec.color) or ns.KindColor[kind]
	local r, g, b = 1, 0.82, 0.28
	if color then
		r, g, b = color[1], color[2], color[3]
	end
	local elite = false
	if kind == Kind.KILL then
		local _
		_, elite = ns.DB:ReadKill(extra)
		size = elite and ELITE_PIP or KILL_PIP
	end
	marker.texture:SetTexture(texture)
	marker.texture:SetTexCoord(0, 1, 0, 1)
	marker.texture:SetVertexColor(r, g, b, 1)
	if marker.border then
		if elite then
			-- Gold ring under the red fill; inset the fill so chrome peeks out.
			marker.border:SetTexture(MEDIA_RING)
			marker.border:SetVertexColor(ELITE_BORDER_R, ELITE_BORDER_G, ELITE_BORDER_B, 1)
			marker.border:SetAllPoints()
			marker.texture:ClearAllPoints()
			marker.texture:SetPoint("TOPLEFT", 2, -2)
			marker.texture:SetPoint("BOTTOMRIGHT", -2, 2)
			marker.border:Show()
		else
			marker.border:Hide()
			marker.texture:ClearAllPoints()
			marker.texture:SetAllPoints()
		end
	end
	marker.pipSize = size
	marker.milestone = (pip and pip.milestone) and true or false
	return size
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

-- Death and an accepted summon cut the trail so replay never draws a line
-- across the jump. Hearth keeps the cast→arrival connector (same look as a
-- same-zone teleport hop). Mage Teleport: still breaks; Portal: / ritual stay put.
function ns.Replay:BreaksPath(kind, extra)
	if kind == Kind.DEATH then
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

function ns.Replay:CollectPath(sessions, minDist, oldest, newest, breakTimes, instanceSpans, cap)
	if oldest == nil and newest == nil then
		oldest, newest = self:TrailSpan()
	end
	breakTimes = breakTimes or self:BreakTimes(sessions)
	local breakIndex = 1
	instanceSpans = instanceSpans or self:InstanceSpans(sessions)
	local buf = self.pathBuf
	if not buf then
		buf = { xs = {}, ys = {}, brk = {}, modes = {}, speeds = {}, times = {}, maps = {} }
		self.pathBuf = buf
	end
	local xs, ys, brk, modes, speeds, times, maps = buf.xs, buf.ys, buf.brk, buf.modes, buf.speeds, buf.times, buf.maps
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
							if cap and n > cap then
								return xs, ys, brk, modes, speeds, times, maps, n
							end
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

-- New or scrubbed-to-start selections preview the whole route until Play.
function ns.Replay:PreviewFullRoute()
	if self.playing or not self:UsingReplayTrail() then
		return false
	end
	if not self.t0 or not self.t1 or not self.playhead then
		return false
	end
	return self.playhead <= self.t0 + 0.05
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
	if self:PreviewFullRoute() then
		return nil
	end
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
	if self:PreviewFullRoute() then
		return self.t1
	end
	if self:UsingReplayTrail() and self.playhead then
		return self.playhead
	end
	return self.t1 or (ns.DB and ns.DB:Now()) or 0
end

-- Oldest sample that still belongs on the trail, and the "now" the solid part ends at.
-- Full history has no oldest bound. The fade tail sits just past the solid window.
-- Replay trail length is played time, so a logout gap does not eat the window.
function ns.Replay:TrailSpan()
	local nowT = self:TrailNow()
	if self.t1 and nowT > self.t1 then
		nowT = self.t1
	end
	local window = self:TrailWindow()
	local oldest
	if window then
		local fade = math.min(45, math.max(10, window * 0.12))
		if self:UsingReplayTrail() then
			local nowPlayed = self:PlayedAt(nowT)
			local want = nowPlayed - window - fade
			if want <= 0 then
				oldest = self.t0
			else
				oldest = self:TimeAtPlayed(want)
			end
		else
			oldest = nowT - window - fade
		end
	end
	if self.t0 and (not oldest or oldest < self.t0) then
		oldest = self.t0
	end
	return oldest, nowT
end

function ns.Replay:FadeContext()
	local nowT = self:TrailNow()
	local window = self:TrailWindow()
	local ctx = self.fadeCtx
	if not ctx then
		ctx = {}
		self.fadeCtx = ctx
	end
	ctx.nowT = nowT
	ctx.window = window
	if window then
		ctx.fade = math.min(45, math.max(10, window * 0.12))
		local usingReplay = self:UsingReplayTrail() and true or false
		ctx.usingReplay = usingReplay
		if usingReplay then
			local pieces = self:PlayPieces()
			ctx.pieces = pieces
			ctx.nowPlayed = self:PlayedAt(nowT, pieces)
		else
			ctx.pieces = nil
			ctx.nowPlayed = nil
		end
	else
		ctx.fade = nil
		ctx.usingReplay = false
		ctx.pieces = nil
		ctx.nowPlayed = nil
	end
	return ctx
end

function ns.Replay:SegmentFade(older, ctx)
	local nowT = ctx and ctx.nowT or self:TrailNow()
	-- A ding mark can land a tick past the playhead float; keep it if it is the tip.
	if not older or older > nowT + 1.5 then
		return 0
	end
	local window = ctx and ctx.window
	if not ctx then
		window = self:TrailWindow()
	end
	if not window then
		return 1
	end
	local age
	local usingReplay = ctx and ctx.usingReplay or (not ctx and self:UsingReplayTrail())
	if usingReplay then
		local pieces = ctx and ctx.pieces or self:PlayPieces()
		local nowPlayed = (ctx and ctx.nowPlayed) or self:PlayedAt(nowT, pieces)
		local olderPlayed = self:PlayedAt(older < nowT and older or nowT, pieces)
		age = nowPlayed - olderPlayed
		if age < 0 then
			age = 0
		end
	else
		age = nowT - older
	end
	if age <= window then
		return 1
	end
	local fade = (ctx and ctx.fade) or math.min(45, math.max(10, window * 0.12))
	if age >= window + fade then
		return 0
	end
	return 1 - ((age - window) / fade)
end

function ns.Replay:RefreshTrailFade()
	local ctx = self:FadeContext()
	local count = self.segmentCount or 0
	for i = 1, count do
		local seg = self.segments[i]
		local line = seg and seg.line
		if line then
			local fade = self:SegmentFade(seg.t1, ctx)
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
		local fade = self:SegmentFade(marker.when, ctx)
		if fade < 0.03 then
			marker:Hide()
		else
			marker:SetAlpha(fade)
			marker:Show()
		end
	end
end

function ns.Replay:DrawPath(sessions)
	local oldest, newest = self:TrailSpan()
	local breakTimes = self:BreakTimes(sessions)
	local instanceSpans = self:InstanceSpans(sessions)
	local minDist = 0.0015
	local xs, ys, brk, modes, speeds, times, maps, n
	for attempt = 1, 5 do
		xs, ys, brk, modes, speeds, times, maps, n = self:CollectPath(
			sessions, minDist, oldest, newest, breakTimes, instanceSpans, attempt < 5 and LINE_CAP or nil
		)
		if n <= LINE_CAP then
			break
		end
		minDist = minDist * 2
	end
	self.lineUsed = 0
	self.segmentCount = 0
	self.hoverGen = (self.hoverGen or 0) + 1
	local canvas = self:Canvas()
	local layer = canvas and canvas:GetWidth() > 0 and self:PathLayer() or nil
	if not layer then
		self:HideSpareLines()
		return
	end
	local width, height = layer:GetWidth(), layer:GetHeight()
	local scale = (canvas and canvas:GetScale()) or 1
	local ctx = self:FadeContext()
	self.segments = self.segments or {}
	for i = 2, n do
		if not brk[i] then
			local line = self:AcquireLine(layer)
			if line then
				local fade = self:SegmentFade(times[i - 1], ctx)
				local placed = self:PlaceLine(line, xs[i - 1], ys[i - 1], xs[i], ys[i], modes[i], speeds[i], fade, width, height, scale)
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

-- Camp/sleep starts that never stayed still (old Well-Rested spam) stay off the map.
function ns.Replay:RestStartWorthDrawing(track, index, sessionStart)
	local kind = track.ek[index]
	if kind ~= Kind.CAMP and kind ~= Kind.SLEEP then
		return true
	end
	if track.ea[index] == 1 then
		return false
	end
	local startAt = sessionStart + (track.et[index] or 0)
	for j = index + 1, #track.ek do
		if track.ek[j] == kind then
			local extra = track.ea[j]
			local at = sessionStart + (track.et[j] or 0)
			if extra == 1 then
				return (at - startAt) >= REST_STAT_MIN
			end
			if not extra or extra == 0 then
				return false
			end
		end
	end
	local stop = self.t1 or (ns.DB and ns.DB:Now()) or startAt
	return (stop - startAt) >= REST_STAT_MIN
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
	local mapHost = ns.Map:Use()
	local baseLevel = mapHost:OverlayLevel(canvas)
	local oldest, newest = self:TrailSpan()
	local ctx = self:FadeContext()
	local fishCluster = {}
	local tipFishing = self:PlayheadStance() == "fish"
	local tipMap, tipX, tipY = self:PlayheadPlace()
	local function draw(wantKill, cap)
		local shown = 0
		for s = #sessions, 1, -1 do
			if shown >= cap then
				break
			end
			local session = sessions[s]
			local sessStart = session.s or 0
			local sessStop = ns.DB:SessionStop(session) or sessStart
			if (not oldest or sessStop >= oldest - 2) and (not newest or sessStart <= newest + 2) then
				local track = ns.DB:Track(session)
				for i = #track.ek, 1, -1 do
					if shown >= cap then
						break
					end
					local kind = track.ek[i]
					local isKill = kind == Kind.KILL
					if isKill == wantKill then
						local spec = ns.EventSpec and ns.EventSpec[kind]
						local when = sessStart + (track.et[i] or 0)
						local spanEnd = spec and spec.shape == "span" and track.ea[i] == 1
						local outside = self.mode == "level" and self.t0
							and (when < self.t0 - 1.5 or when > ((self.t1 or when) + 1.5))
						if spec and spec.pip and not spanEnd and not outside then
							local fade = self:SegmentFade(when, ctx)
							if fade > 0 then
								local shortRest = (kind == Kind.CAMP or kind == Kind.SLEEP)
									and not self:RestStartWorthDrawing(track, i, sessStart)
								if not shortRest then
									local mapID = track.em[i]
									local nx = track.ex[i] / ns.COORD_SCALE
									local ny = track.ey[i] / ns.COORD_SCALE
									local skipFish = false
									if kind == Kind.FISH then
										-- Tip already shows fishing; skip the pip underfoot.
										if tipFishing and tipMap and mapID == tipMap
											and tipX and tipY
											and self:YardsApart(mapID, nx, ny, tipX, tipY) <= FISH_DEDUP_YARDS then
											skipFish = true
										elseif self:FishNearCluster(fishCluster, mapID, nx, ny) then
											skipFish = true
										else
											fishCluster[#fishCluster + 1] = { mapID = mapID, x = nx, y = ny }
										end
									end
									if not skipFish then
										local px, py = self:Project(mapID, nx, ny)
										if px then
											shown = shown + 1
											local marker = self:AcquireMarker()
											local size = self:PaintMarker(marker, kind, track.ea[i])
											marker:SetAlpha(fade)
											mapHost:FitPin(marker, size)
											marker.kind = kind
											marker.extra = track.ea[i]
											marker.mapID = mapID
											marker.when = when
											marker.session = session
											mapHost:Place(marker, px, py)
											-- Level/death/boss sit above the class tip (+15) so the
											-- finishing ding ring is not covered at the playhead.
											local bump = 5
											if marker.milestone then
												bump = 18
											elseif isKill then
												bump = 3
											end
											marker:SetFrameLevel(baseLevel + bump)
											marker:Show()
										end
									end
								end
							end
						end
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

-- "fish" replaces the class tip entirely; "parked" is the idle/AFK ring.
function ns.Replay:PlayheadStance()
	local sessions = self.sessions
	local when = self.playhead
	if not sessions or not when then
		return "move"
	end
	local active = {}
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
			local spec = ns.EventSpec and ns.EventSpec[kind]
			if spec then
				if spec.shape == "span" and spec.playhead then
					if not extra or extra == 0 then
						active[kind] = true
						if spec.blocksAFK then
							active[Kind.AFK_START] = false
						end
					elseif extra == 1 then
						active[kind] = false
					end
				elseif spec.shape == "pair" and spec.playhead then
					active[kind] = true
				elseif spec.shape == "pairEnd" and spec.pairStart then
					active[spec.pairStart] = false
				end
			end
		end
	end
	local busy, parked = false, false
	for kind, on in pairs(active) do
		if on then
			local stance = ns.EventSpec[kind] and ns.EventSpec[kind].playhead
			if stance == "fish" then
				return "fish"
			elseif stance == "busy" then
				busy = true
			elseif stance == "parked" then
				parked = true
			end
		end
	end
	if busy then
		return "move"
	end
	if parked then
		return "parked"
	end
	local s1, i1, s2, i2 = Locate(sessions, when)
	if not s1 then
		return "move"
	end
	local map1, x1, y1, t1 = self:SampleXY(sessions[s1], i1)
	local map2, x2, y2, t2 = self:SampleXY(sessions[s2], i2)
	if i1 == i2 and i1 > 1 then
		map1, x1, y1, t1 = self:SampleXY(sessions[s1], i1 - 1)
		map2, x2, y2, t2 = self:SampleXY(sessions[s2], i2)
	end
	if map1 ~= map2 then
		return "move"
	end
	local dx, dy = (x2 or x1) - x1, (y2 or y1) - y1
	if (dx * dx) + (dy * dy) > (PARK_DIST * PARK_DIST) then
		return "move"
	end
	if (when - t1) >= PARK_SECONDS then
		return "parked"
	end
	return "move"
end

function ns.Replay:PlayheadParked()
	return self:PlayheadStance() == "parked"
end

function ns.Replay:YardsApart(mapID, x1, y1, x2, y2)
	local size = self:MapYards(mapID)
	if not size then
		local dx, dy = x1 - x2, y1 - y2
		return math.sqrt(dx * dx + dy * dy) * 1000
	end
	local dx = (x1 - x2) * size[1]
	local dy = (y1 - y2) * size[2]
	return math.sqrt(dx * dx + dy * dy)
end

function ns.Replay:FishNearCluster(cluster, mapID, x, y)
	if not mapID or not x or not y then
		return false
	end
	for i = 1, #cluster do
		local spot = cluster[i]
		if spot.mapID == mapID and self:YardsApart(mapID, x, y, spot.x, spot.y) <= FISH_DEDUP_YARDS then
			return true
		end
	end
	return false
end

function ns.Replay:StyleDot(mode)
	local dot = self.dot
	if not dot then
		return
	end
	-- ClassColor keys off the viewed journey. Switching characters keeps mode
	-- "move", so also refresh when the view's class color changes.
	local viewKey = ns.DB.viewKey or ns.DB.playerKey
	local r, g, b
	if mode == "fish" then
		local color = ns.KindColor[Kind.FISH]
		r, g, b = color[1], color[2], color[3]
	else
		r, g, b = self:ClassColor()
	end
	if dot.mode == mode and dot.colorView == viewKey and dot.colorR == r and dot.colorG == g and dot.colorB == b then
		return
	end
	dot.mode = mode
	dot.colorView = viewKey
	dot.colorR, dot.colorG, dot.colorB = r, g, b
	if mode == "fish" then
		dot.texture:SetTexture(MEDIA_CIRCLE)
	elseif mode == "parked" then
		dot.texture:SetTexture(MEDIA_RING)
	else
		dot.texture:SetTexture(MEDIA_CIRCLE)
	end
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
	local mode = self:PlayheadStance()
	self:StyleDot(mode)
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
	local startI = FirstIndexAtOrAfter(track.t, sessionStart, fromT)
	for i = startI, #track.t do
		local at = sessionStart + (track.t[i] or 0)
		if at > toT then
			break
		end
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
	return toT - fromT
end

function ns.Replay:CollectStats(sessions)
	local recorded, afk, idle = 0, 0, 0
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
		local endT = ns.DB:SessionStop(session) or session.s
		if self.mode == "level" and self.t1 and self.t1 < endT then
			endT = self.t1
		end
		local clip = self.mode == "level" and self.levelLo and self.t0 and self.t1
		if not clip then
			local fullEnd = ns.DB:SessionStop(session) or session.s
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
		local afkStart, idleStart, instStart, instType, campStart, sleepStart
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
			elseif kind == Kind.IDLE and (not extra or extra == 0) then
				idleStart = t
			elseif kind == Kind.IDLE and extra == 1 and idleStart then
				if t > idleStart then
					idle = idle + (t - idleStart)
				end
				idleStart = nil
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
		if idleStart and endT > idleStart then
			idle = idle + (endT - idleStart)
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
		{ L["Idle"], FormatClock(idle) },
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
		{ L["Teleports"], Comma(portals) },
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
	self.placeNames = self.placeNames or {}
	local cached = self.placeNames[mapID]
	if cached ~= nil then
		return cached or nil
	end
	local info = C_Map.GetMapInfo(mapID)
	if info and type(info.name) == "string" and not (issecretvalue and issecretvalue(info.name)) and info.name ~= "" then
		self.placeNames[mapID] = info.name
		return info.name
	end
	self.placeNames[mapID] = false
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
		GameTooltip:SetText(self:SpellTitle(pin.extra) or L["Teleport"], color[1], color[2], color[3])
	elseif pin.kind == Kind.CAMP then
		GameTooltip:SetText(L["Campfire"], color[1], color[2], color[3])
	elseif pin.kind == Kind.SLEEP then
		GameTooltip:SetText(L["Sleeping bag"], color[1], color[2], color[3])
	elseif pin.kind == Kind.FISH then
		GameTooltip:SetText(L["Fishing"], color[1], color[2], color[3])
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
	GameTooltip:SetText(L["Joined Party"], 0.45, 0.75, 1)
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
	if not journey or type(journey.with) ~= "table" or not journey.with[guid] then
		return
	end
	local person = ns.DB:CompanyByGuid(journey, guid)
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
	local gapsByLevel = ns.DB:LevelGaps(ns.DB.char)
	local covered = {}
	for i = 1, #order do
		local group = order[i]
		local top = group.lvTo or group.lv
		local missingFrac = 0
		local gaps = nil
		for lv = group.lv, top do
			covered[lv] = true
			local entry = gapsByLevel[lv]
			if entry and entry.missing > 0 then
				missingFrac = missingFrac + entry.missing
				gaps = gaps or {}
				if entry.whole then
					gaps[#gaps + 1] = { lv = lv, from = 0, to = 1, whole = true }
				else
					for r = 1, #entry.ranges do
						local range = entry.ranges[r]
						gaps[#gaps + 1] = { lv = lv, from = range.from, to = range.to, whole = false }
					end
				end
			end
		end
		if missingFrac > 0 and gaps then
			group.missingFrac = missingFrac
			group.gaps = gaps
		end
	end
	local skipped = {}
	for lv, entry in pairs(gapsByLevel) do
		if entry.whole and not covered[lv] then
			skipped[#skipped + 1] = lv
		end
	end
	if #skipped > 0 then
		table.sort(skipped)
		local runStart, runEnd, runT0, runT1
		local function flushMissing()
			if not runStart then
				return
			end
			order[#order + 1] = {
				lv = runStart,
				lvTo = runEnd ~= runStart and runEnd or nil,
				seconds = 0,
				open = false,
				missing = true,
				missingFrac = runEnd - runStart + 1,
				t0 = runT0 or 0,
				last = runT1 or runT0 or 0,
			}
			runStart, runEnd, runT0, runT1 = nil, nil, nil, nil
		end
		for i = 1, #skipped do
			local lv = skipped[i]
			local entry = gapsByLevel[lv]
			if runStart and lv == runEnd + 1 and entry.t0 == runT0 and entry.t1 == runT1 then
				runEnd = lv
			else
				flushMissing()
				runStart = lv
				runEnd = lv
				runT0 = entry.t0
				runT1 = entry.t1
			end
		end
		flushMissing()
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

local function MissingPct(frac)
	if not frac or frac <= 0 then
		return 0
	end
	local pct = math.floor(frac * 100 + 0.5)
	if pct < 1 then
		pct = 1
	elseif pct > 100 then
		pct = 100
	end
	return pct
end

function ns.Replay:LevelMissingSummary(lo, hi)
	if not lo then
		return false, nil
	end
	hi = hi or lo
	local groups = self:LevelGroups()
	local hasMissing = false
	local singlePct = nil
	for i = 1, #groups do
		local group = groups[i]
		local top = group.lvTo or group.lv
		if top >= lo and group.lv <= hi and (group.missing or (group.missingFrac and group.missingFrac > 0)) then
			hasMissing = true
			if lo == hi and group.lv == lo and top == hi and not group.missing then
				singlePct = MissingPct(group.missingFrac)
			end
		end
	end
	return hasMissing, singlePct
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
		if not group.missing and top >= lo and group.lv <= hi then
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
			if group.missing then
				rows[#rows + 1] = { self:LevelName(group), L["Missing"], r = 0.90, g = 0.56, b = 0.28 }
			elseif group.missingFrac and group.missingFrac > 0 then
				local clock = FormatClock(group.seconds or 0)
				local value
				if group.lvTo and group.lvTo ~= group.lv then
					value = string.format(L["%s (missing data)"], clock)
				else
					value = string.format(L["%s (~%d%% missing)"], clock, MissingPct(group.missingFrac))
				end
				rows[#rows + 1] = { self:LevelName(group), value }
			else
				rows[#rows + 1] = { self:LevelName(group), FormatClock(group.seconds or 0) }
			end
		end
	end
	if #rows == 1 then
		return {}
	end
	return rows
end

function ns.Replay:StatsKey(sessions)
	local parts = { tostring(#sessions) }
	local current = ns.DB.session
	local hasLive = false
	for i = 1, #sessions do
		local session = sessions[i]
		local pts, evs = ns.DB:TrackCounts(session)
		local seen = session.seen or 0
		if session == current then
			hasLive = true
			seen = math.floor(seen / 10)
		end
		parts[#parts + 1] = string.format(
			"%s.%s.%s.%s.%s.%s.%s.%s",
			session.id or i,
			seen,
			session.kills or 0,
			session.quests or 0,
			session.el or 0,
			session.ex or 0,
			pts,
			evs
		)
	end
	local t1Key = self.t1 or ""
	if hasLive and type(self.t1) == "number" then
		t1Key = math.floor(self.t1 / 10)
	end
	parts[#parts + 1] = string.format(
		"%s.%s.%s.%s.%s",
		self.mode or "",
		self.levelLo or "",
		self.levelHi or "",
		self.t0 or "",
		t1Key
	)
	local with = ns.DB.char and ns.DB.char.with
	local spans = 0
	if type(with) == "table" then
		for _, list in pairs(with) do
			if type(list) == "table" then
				spans = spans + #list
			end
		end
	end
	parts[#parts + 1] = "c" .. spans
	return table.concat(parts, ":")
end

function ns.Replay:ChapterKey(sessions)
	local parts = { tostring(#sessions) }
	for i = 1, #sessions do
		local session = sessions[i]
		local pts, evs = ns.DB:TrackCounts(session)
		parts[#parts + 1] = string.format("%s.%s.%s", session.id or i, pts, evs)
	end
	parts[#parts + 1] = string.format("%s.%s.%s.%s", self.mode or "", self.levelLo or "", self.levelHi or "", self.t0 or "")
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
			row:SetHeight(18)
			row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.label:SetPoint("LEFT", 8, 0)
			row.label:SetJustifyH("LEFT")
			row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.value:SetPoint("RIGHT", -8, 0)
			row.value:SetJustifyH("RIGHT")
			row.label:SetPoint("RIGHT", row.value, "LEFT", -10, 0)
			self.statRows[i] = row
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((i - 1) * 18))
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
	content:SetHeight(math.max(18, #rows * 18))
end

function ns.Replay:UpdateRecap(sessions)
	if self.pane == "charts" and ns.Viz and ns.Viz.Refresh then
		ns.Viz:Refresh(sessions)
		return
	end
	self:RefreshStats(sessions)
end

function ns.Replay:SetPane(pane)
	self:SetExpanded(pane == "charts")
end

function ns.Replay:ClearBlocked()
	self.blockedKey = nil
	if self.blockedText then
		self.blockedText:Hide()
	end
	if self.blockedLink then
		self.blockedLink:Hide()
	end
	if self.scroll then
		self.scroll:Show()
	end
end

function ns.Replay:ShowBlocked(key, label, pending)
	self.blockedKey = key
	self.blockedLabel = label
	self.blockedPending = pending
	self.playing = false
	self.sessions = {}
	self.t0, self.t1, self.playhead = nil, nil, nil
	if self.playButton then
		self.playButton:SetText(L["Play"])
	end
	if self.ClearOverlay then
		self:ClearOverlay()
	end
	self:RefreshCharacters()
	if self.scroll then
		self.scroll:Hide()
	end
	if self.blockedText then
		if pending == "purgePrivate" then
			self.blockedText:SetText(string.format(
				L["%s's Non-Global journey is marked for delete. Log in as them once to finish wiping it, or open Saved data."],
				label
			))
		elseif pending == "toGlobal" then
			self.blockedText:SetText(string.format(
				L["%s's journey is not on this character yet. Log in as them once to finish moving it to Global, or open Saved data to change your mind."],
				label
			))
		else
			self.blockedText:SetText(string.format(
				L["%s's data is Non-Global; can't access it from this character. Globalize their data in Saved data to view."],
				label
			))
		end
		self.blockedText:Show()
	end
	if self.blockedLink then
		self.blockedLink:Show()
	end
	if self.scopeText then
		self.scopeText:SetText(self:ScopeCaption())
	end
end

function ns.Replay:RefreshCharacters()
	if not self.charButton then
		return
	end
	local text
	if self.blockedKey and self.blockedLabel then
		text = self.blockedLabel
	elseif ns.DB.char then
		text = ns.DB:JourneyLabel(ns.DB.char)
	else
		text = L["Character"]
	end
	self.charButton:OverrideText(text)
end

function ns.Replay:ScopeCaption()
	if self.blockedKey and self.blockedLabel then
		if self.blockedPending == "toGlobal" then
			return string.format(L["%s is waiting on a login before their journey is Global here."], self.blockedLabel)
		end
		return string.format(L["%s's journey is Non-Global on this character."], self.blockedLabel)
	end
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
		local base
		if self.levelHi and self.levelHi ~= self.levelLo then
			if self:LevelIsOpen(self.levelLo, self.levelHi) then
				base = string.format(L["Levels %d–%d, so far."], self.levelLo, self.levelHi)
			else
				base = string.format(L["Levels %d–%d."], self.levelLo, self.levelHi)
			end
		elseif self:LevelIsOpen(self.levelLo) then
			base = string.format(L["Level %d, so far."], self.levelLo)
		else
			base = string.format(L["Level %d."], self.levelLo)
		end
		local hasMissing, singlePct = self:LevelMissingSummary(self.levelLo, self.levelHi)
		if hasMissing then
			if singlePct then
				return string.format(L["%s Missing ~%d%% of XP data."], base, singlePct)
			end
			return string.format(L["%s Some data is missing."], base)
		end
		return base
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
		elapsed = (ns.DB:SessionStop(session) or session.s) - session.s
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
	local sessions = self.sessions or {}
	local count = #sessions
	local first = sessions[1]
	local last = sessions[count]
	local now = ns.DB:Now()
	if self.playPieces
		and self.playPiecesChar == ns.DB.char
		and self.playPiecesMode == self.mode
		and self.playPiecesLo == self.levelLo
		and self.playPiecesHi == self.levelHi
		and self.playPiecesT0 == self.t0
		and self.playPiecesT1 == self.t1
		and self.playPiecesCount == count
		and self.playPiecesFirst == first
		and self.playPiecesLast == last
		and self.playPiecesNow == now then
		return self.playPieces
	end
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
		for i = 1, count do
			local session = sessions[i]
			if type(session) == "table" and type(session.s) == "number" then
				local stop = ns.DB:SessionStop(session) or session.s
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
	self.playPieces = pieces
	self.playPiecesChar = ns.DB.char
	self.playPiecesMode = self.mode
	self.playPiecesLo = self.levelLo
	self.playPiecesHi = self.levelHi
	self.playPiecesT0 = self.t0
	self.playPiecesT1 = self.t1
	self.playPiecesCount = count
	self.playPiecesFirst = first
	self.playPiecesLast = last
	self.playPiecesNow = now
	return pieces
end

function ns.Replay:PlayedAt(when, pieces)
	pieces = pieces or self:PlayPieces()
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

function ns.Replay:TimelineMissingText()
	if self.mode ~= "level" or not self.levelLo then
		return nil
	end
	local lo = self.levelLo
	local hi = self.levelHi or lo
	local gapsByLevel = ns.DB:LevelGaps(ns.DB.char)
	local affected = {}
	for lv = lo, hi do
		local entry = gapsByLevel[lv]
		if entry and entry.missing > 0 then
			affected[#affected + 1] = { lv = lv, entry = entry }
		end
	end
	if #affected == 0 then
		return nil
	end
	if #affected == 1 then
		local item = affected[1]
		if item.entry.whole then
			return string.format(L["Missing Level %d"], item.lv)
		end
		return string.format(L["Missing ~%d%% of Level %d"], MissingPct(item.entry.missing), item.lv)
	end
	return L["Missing data"]
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
		if self.timeMissing then
			self.timeMissing:Hide()
		end
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
	if self.timeMissing then
		local note = self:TimelineMissingText()
		if note then
			self.timeMissing:SetText(note)
			self.timeMissing:Show()
		else
			self.timeMissing:Hide()
		end
	end
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
		if zone and zone ~= "" and zone ~= L["Zone"] then
			return string.format(L["Hearthed - %s"], zone)
		end
		return L["Hearthed"]
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
		local endT = ns.DB:SessionStop(session) or session.s
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
				if mapID and mapID > 0 then
					for v = 1, #visits do
						local visit = visits[v]
						if t >= visit.first - 30 and t <= visit.last + 30 and mapID == visit.map then
							visit.work = true
						end
					end
					if open and t >= open.first - 30 and t <= open.last + 30 and mapID == open.map then
						open.work = true
					end
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
	-- Session and level windows always open on a chapter. A zone visit that
	-- began before the level (or session) is clipped away above, so ding-in-place
	-- would otherwise wait until the next zone change for the first marker.
	if self.t0 then
		local map = ns.DB:MapAt(ns.DB.char, self.t0)
		local first = merged[1]
		local needsStart = not first or first.t > self.t0 + 1
		if needsStart and first and first.kind ~= "instance" and (first.t - self.t0) <= CHAPTER_MERGE then
			first.t = self.t0
			if (not first.map or first.map == 0) and map then
				first.map = map
			end
			first.name = self:ChapterName(first.kind, first.map, first)
		elseif needsStart then
			local start = { t = self.t0, map = map, kind = "zone" }
			start.name = self:ChapterName("zone", map, start)
			table.insert(merged, 1, start)
		end
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
	pip = CreateFrame("Button", nil, self.chrome or self.frame)
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

function ns.Replay:AcquireGapPip(index)
	self.gapPips = self.gapPips or {}
	local pip = self.gapPips[index]
	if pip then
		return pip
	end
	pip = CreateFrame("Button", nil, self.chrome or self.frame)
	pip:SetSize(12, 16)
	pip.mark = pip:CreateTexture(nil, "OVERLAY")
	pip.mark:SetTexture("Interface\\Buttons\\WHITE8X8")
	pip.mark:SetSize(4, 14)
	pip.mark:SetPoint("BOTTOM", 0, 0)
	pip.mark:SetVertexColor(0.96, 0.48, 0.16, 1)
	pip:SetScript("OnClick", function(self)
		ns.Replay:SeekToTime(self.when)
	end)
	pip:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(L["Missing data"], 0.96, 0.58, 0.24)
		local items = self.gapItems or {}
		for i = 1, #items do
			local item = items[i]
			if item.whole then
				GameTooltip:AddLine(string.format(L["Level %d: no data"], item.lv), 0.90, 0.88, 0.82)
			else
				local fromPct = math.floor((item.from or 0) * 100 + 0.5)
				local toPct = math.floor((item.to or 0) * 100 + 0.5)
				GameTooltip:AddLine(string.format(L["Level %d: %d%% to %d%% XP"], item.lv, fromPct, toPct), 0.90, 0.88, 0.82)
			end
		end
		if self.gapT0 and self.gapT1 then
			GameTooltip:AddLine(string.format("%s – %s", date("%b %d, %H:%M", self.gapT0), date("%b %d, %H:%M", self.gapT1)), 0.72, 0.70, 0.65)
		elseif self.when then
			GameTooltip:AddLine(date("%b %d, %H:%M", self.when), 0.72, 0.70, 0.65)
		end
		GameTooltip:AddLine(L["Data between sessions was not saved."], 0.65, 0.63, 0.58, true)
		GameTooltip:Show()
	end)
	pip:SetScript("OnLeave", function(self)
		if GameTooltip:IsOwned(self) then
			GameTooltip:Hide()
		end
	end)
	self.gapPips[index] = pip
	return pip
end

function ns.Replay:TimelineGaps()
	if not self.t0 or not self.t1 or self.t1 <= self.t0 then
		return {}
	end
	local gapsByLevel = ns.DB:LevelGaps(ns.DB.char)
	local bySeam, seams = {}, {}
	local function addRange(lv, range, whole)
		local gt0 = range.t0
		local gt1 = range.t1
		local when
		if gt1 and gt1 >= self.t0 - 1 and gt1 <= self.t1 + 1 then
			when = gt1
		elseif gt0 and gt0 >= self.t0 - 1 and gt0 <= self.t1 + 1 then
			when = gt0
		else
			return
		end
		if when < self.t0 then
			when = self.t0
		elseif when > self.t1 then
			when = self.t1
		end
		local key = string.format("%s:%s", tostring(gt0 or 0), tostring(gt1 or 0))
		local seam = bySeam[key]
		if not seam then
			seam = { when = when, t0 = gt0, t1 = gt1, items = {} }
			bySeam[key] = seam
			seams[#seams + 1] = seam
		end
		seam.items[#seam.items + 1] = { lv = lv, from = range.from, to = range.to, whole = whole and true or false }
	end
	if self.mode == "level" and self.levelLo then
		local lo = self.levelLo
		local hi = self.levelHi or lo
		for lv = lo, hi do
			local entry = gapsByLevel[lv]
			if entry and entry.missing > 0 then
				if entry.whole then
					addRange(lv, { from = 0, to = 1, t0 = entry.t0, t1 = entry.t1 }, true)
				else
					for i = 1, #(entry.ranges or {}) do
						addRange(lv, entry.ranges[i], false)
					end
				end
			end
		end
	elseif #(self.sessions or {}) >= 2 then
		local levels = {}
		for lv in pairs(gapsByLevel) do
			levels[#levels + 1] = lv
		end
		table.sort(levels)
		for i = 1, #levels do
			local lv = levels[i]
			local entry = gapsByLevel[lv]
			if entry and entry.missing > 0 then
				local list = entry.whole and { { from = 0, to = 1, t0 = entry.t0, t1 = entry.t1 } } or (entry.ranges or {})
				for r = 1, #list do
					local range = list[r]
					if range.t0 and range.t1 and range.t0 >= self.t0 - 1 and range.t1 <= self.t1 + 1 then
						addRange(lv, range, entry.whole)
					end
				end
			end
		end
	end
	table.sort(seams, function(a, b)
		return a.when < b.when
	end)
	return seams
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
			pip:SetParent(self.chrome or self.frame)
			pip:SetFrameLevel(level)
			pip:ClearAllPoints()
			-- Sit in the lane under the chapter strip, a few px above the track.
			pip:SetPoint("BOTTOM", scrub, "TOPLEFT", fraction * width, 4)
			pip:Show()
			shown = i
		end
	end
	if self.pips then
		for i = shown + 1, #self.pips do
			self.pips[i]:Hide()
		end
	end
	local gapShown = 0
	if width > 20 and total > 0 then
		local seams = self:TimelineGaps()
		local gapLevel = (scrub:GetFrameLevel() or 1) + 7
		for i = 1, #seams do
			local seam = seams[i]
			local elapsed = self:PlayedAt(seam.when)
			local fraction = elapsed / total
			if fraction < 0 then
				fraction = 0
			elseif fraction > 1 then
				fraction = 1
			end
			local pip = self:AcquireGapPip(i)
			pip.when = seam.when
			pip.gapT0 = seam.t0
			pip.gapT1 = seam.t1
			pip.gapItems = seam.items
			pip:SetParent(self.chrome or self.frame)
			pip:SetFrameLevel(gapLevel)
			pip:ClearAllPoints()
			pip:SetPoint("BOTTOM", scrub, "TOPLEFT", fraction * width, 3)
			pip:Show()
			gapShown = i
		end
	end
	if self.gapPips then
		for i = gapShown + 1, #self.gapPips do
			self.gapPips[i]:Hide()
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
	local key = self:ChapterKey(sessions)
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

-- Jump-to-start / jump-to-end. Pauses like scrub and time-jump so a seek to t0
-- restores PreviewFullRoute and mid-route seeks keep the playhead-clipped trail.
-- Chapter prev/next keep playing via SeekToTime alone.
function ns.Replay:SeekToEdge(toEnd)
	if not self.t0 or not self.t1 or self.t1 <= self.t0 then
		return
	end
	self.playing = false
	if self.playButton then
		self.playButton:SetText(L["Play"])
	end
	self.chapterPrevSeekAt = nil
	self:SeekFraction(toEnd and 1 or 0, true)
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
	local gap = self:PieceGapSkipTo(self.playhead)
	if gap and gap > self.playhead then
		self.playhead = gap
	end
	local indoors = self:InstanceSkipTo(self.playhead)
	if indoors and indoors > self.playhead then
		self.playhead = indoors
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
		local stopAt = ns.DB:SessionStop(session) or session.s
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

-- Playhead advances in wall time; the scrubber clock only counts PlayPieces.
-- Jump logout gaps (and level-span gaps) so multi-session Select all does not
-- freeze the numerator while playing stays true through an overnight break.
function ns.Replay:PieceGapSkipTo(at)
	if not at or not self.t1 then
		return nil
	end
	local pieces = self:PlayPieces()
	if #pieces == 0 then
		return nil
	end
	local nextStart
	for i = 1, #pieces do
		local piece = pieces[i]
		if at >= piece.t0 and at <= piece.t1 then
			return nil
		end
		if piece.t0 > at and (not nextStart or piece.t0 < nextStart) then
			nextStart = piece.t0
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
	if self.blockedKey then
		return
	end
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
	local hoverGen = self.hoverGen or 0
	if rawX == self.hoverX and rawY == self.hoverY and hoverGen == self.lastHoverGen then
		return
	end
	self.hoverX, self.hoverY, self.lastHoverGen = rawX, rawY, hoverGen
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
	local mapName = best.map and self:PlaceName(best.map)
	if mapName then
		GameTooltip:AddLine(mapName, 1, 1, 1)
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
	self.hoverGen = (self.hoverGen or 0) + 1
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

-- Login/hearth often logs 1–2 samples on the continent before the zone map.
-- Do not yank the open map up to Continent/World for those blips.
function ns.Replay:MapTooWide(mapID)
	if not mapID or not C_Map or not C_Map.GetMapInfo then
		return false
	end
	local info = C_Map.GetMapInfo(mapID)
	local mapType = info and info.mapType
	return type(mapType) == "number" and mapType < MAP_TYPE_ZONE
end

function ns.Replay:NearbyZoneMap(when, window)
	local sessions = self.sessions
	if not sessions or not when then
		return nil
	end
	window = window or 20
	local best, bestDist
	for s = 1, #sessions do
		local session = sessions[s]
		local track = ns.DB:Track(session)
		for i = 1, #(track.t or {}) do
			local mapID = track.m[i]
			if mapID and not self:MapTooWide(mapID) then
				local at = session.s + (track.t[i] or 0)
				local dist = math.abs(at - when)
				if dist <= window and (not bestDist or dist < bestDist) then
					best, bestDist = mapID, dist
				end
			end
		end
	end
	return best
end

-- Route map opens and switches through C_Map.OpenWorldMap so Blizzard's
-- WORLD_MAP_OPEN handler runs untainted. Calling ToggleWorldMap or
-- WorldMapFrame:SetMapID directly from addon code taints WorldMapFrame.mapID
-- and its quest pin pool, which later blocks SetPassThroughButtons in combat.
function ns.Replay:OpenWorldMap(mapID)
	if InCombatLockdown and InCombatLockdown() then
		return false
	end
	if C_Map and C_Map.OpenWorldMap then
		C_Map.OpenWorldMap(mapID)
		return true
	end
	return false
end

-- Move the open world map to the playhead map. Never opens the map.
function ns.Replay:SnapMapToPlayhead()
	if self.settingMap then
		return
	end
	if InCombatLockdown and InCombatLockdown() then
		return
	end
	local mapID = self:PlayheadPlace()
	local map = self:EnsureMap()
	if not mapID or not map or not map:IsShown() or not map.GetMapID then
		return
	end
	if self:MapTooWide(mapID) then
		local zone = self:NearbyZoneMap(self.playhead, 30)
		if zone then
			mapID = zone
		else
			return
		end
	end
	if map:GetMapID() == mapID then
		return
	end
	self.settingMap = true
	if not self:OpenWorldMap(mapID) and map.SetMapID then
		map:SetMapID(mapID)
	end
	self.settingMap = false
end

function ns.Replay:FollowPlayhead()
	if not self.playing then
		return
	end
	self:SnapMapToPlayhead()
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
	if self.blockedKey then
		if self.RefreshCharacters then
			self:RefreshCharacters()
		end
		return
	end
	local mapShown = WorldMapFrame and WorldMapFrame:IsShown()
	local panelShown = self.frame and self.frame:IsShown()
	if not mapShown and not panelShown then
		self.dirty = true
		return
	end
	if not self.route then
		self.dirty = true
		return
	end
	if panelShown and self.mode ~= "current" and self.mode ~= "all" and self.mode ~= "span" then
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
	self.armedDelete = nil
	self:ClearBlocked()
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
	-- Only while the replay panel is open: jump an already-shown map to the
	-- scrubber. SetMode also runs from map OnShow via UseCurrentTrailOutsidePanel
	-- when the panel is closed; snapping there stole the normal zone open.
	if self.frame and self.frame:IsShown() then
		self:SnapMapToPlayhead()
	end
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
			if not group.missing then
				local top = group.lvTo or group.lv
				if not lo or group.lv < lo then
					lo = group.lv
				end
				if not hi or top > hi then
					hi = top
				end
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

function ns.Replay:ShowLevelGapTooltip(row)
	local group = row and row.levelGroup
	if not group or not (group.missing or (group.missingFrac and group.missingFrac > 0)) or not GameTooltip then
		return
	end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	if group.missing then
		GameTooltip:SetText(string.format(L["%s — Missing level"], self:LevelName(group)), 0.95, 0.62, 0.28)
		if group.lvTo and group.lvTo ~= group.lv then
			GameTooltip:AddLine(L["No data recorded for these levels."], 0.90, 0.88, 0.82, true)
		else
			GameTooltip:AddLine(L["No data recorded for this level."], 0.90, 0.88, 0.82, true)
		end
	else
		GameTooltip:SetText(string.format(L["%s — Missing data"], self:LevelName(group)), 0.95, 0.62, 0.28)
		local gaps = group.gaps or {}
		local multiLevel = group.lvTo and group.lvTo ~= group.lv
		if not multiLevel then
			local pct = MissingPct(group.missingFrac)
			if #gaps == 1 then
				local fromPct = math.floor(gaps[1].from * 100 + 0.5)
				local toPct = math.floor(gaps[1].to * 100 + 0.5)
				GameTooltip:AddLine(string.format(L["Missing ~%d%% of this level (%d%% to %d%% XP)."], pct, fromPct, toPct), 0.90, 0.88, 0.82, true)
			else
				GameTooltip:AddLine(string.format(L["Missing ~%d%% of this level:"], pct), 0.90, 0.88, 0.82, true)
				for i = 1, #gaps do
					local fromPct = math.floor(gaps[i].from * 100 + 0.5)
					local toPct = math.floor(gaps[i].to * 100 + 0.5)
					GameTooltip:AddLine("  " .. string.format(L["%d%% to %d%% XP"], fromPct, toPct), 0.85, 0.82, 0.76)
				end
			end
		else
			for i = 1, #gaps do
				local gap = gaps[i]
				if gap.whole then
					GameTooltip:AddLine(string.format(L["Level %d: no data"], gap.lv), 0.90, 0.88, 0.82)
				else
					local fromPct = math.floor(gap.from * 100 + 0.5)
					local toPct = math.floor(gap.to * 100 + 0.5)
					GameTooltip:AddLine(string.format(L["Level %d: %d%% to %d%% XP"], gap.lv, fromPct, toPct), 0.90, 0.88, 0.82)
				end
			end
		end
	end
	GameTooltip:AddLine(L["Data between sessions was not saved."], 0.65, 0.63, 0.58, true)
	GameTooltip:Show()
end

function ns.Replay:RefreshLevelList()
	local content = self.listContent
	local journey = ns.DB.char
	local sessions = journey and journey.sessions or {}
	local levels = journey and journey.levels or {}
	local last = sessions[#sessions]
	local bucket = 0
	if last and last == ns.DB.session then
		bucket = math.floor(ns.DB:Now() / 5)
	end
	local listKey = string.format(
		"%s:%d:%d:%s:%s:%s:%d:%s",
		tostring(ns.DB.viewKey or ""),
		#sessions,
		#levels,
		tostring(self.levelLo or ""),
		tostring(self.levelHi or ""),
		tostring(self.blockedKey or ""),
		bucket,
		tostring(last and last.el or "")
	)
	if listKey == self.levelListKey then
		return
	end
	self.levelListKey = listKey
	local groups = self:LevelGroups()
	for i = 1, #groups do
		local group = groups[i]
		local row = self.rows[i]
		if not row then
			row = CreateFrame("Button", nil, content)
			row:SetHeight(24)
			row.bar = row:CreateTexture(nil, "BACKGROUND")
			row.bar:SetAllPoints()
			row.bar:SetColorTexture(0.85, 0.68, 0.28, 0.16)
			row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.label:SetJustifyH("LEFT")
			row.label:SetJustifyV("MIDDLE")
			row.badge = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.badge:SetJustifyH("RIGHT")
			row.badge:SetJustifyV("MIDDLE")
			row.badge:SetPoint("RIGHT", -8, 0)
			row.badge:Hide()
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
			row:SetScript("OnEnter", function(button)
				ns.Replay:ShowLevelGapTooltip(button)
			end)
			row:SetScript("OnLeave", function(button)
				if GameTooltip and GameTooltip:IsOwned(button) then
					GameTooltip:Hide()
				end
			end)
			self.rows[i] = row
		elseif not row.badge then
			row.badge = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.badge:SetJustifyH("RIGHT")
			row.badge:SetJustifyV("MIDDLE")
			row.badge:SetPoint("RIGHT", -8, 0)
			row.badge:Hide()
			row:SetScript("OnEnter", function(button)
				ns.Replay:ShowLevelGapTooltip(button)
			end)
			row:SetScript("OnLeave", function(button)
				if GameTooltip and GameTooltip:IsOwned(button) then
					GameTooltip:Hide()
				end
			end)
		end
		row:SetHeight(24)
		row.sessionIndex = nil
		row.sessionRef = nil
		if row.delBtn then
			row.delBtn:Hide()
		end
		if row.confirmBtn then
			row.confirmBtn:Hide()
		end
		if row.cancelBtn then
			row.cancelBtn:Hide()
		end
		row.levelGroup = group
		local selected = false
		if group.missing then
			row.level = nil
			row.levelTop = nil
		else
			row.level = group.lv
			row.levelTop = group.lvTo or group.lv
			selected = self.levelLo and row.levelTop >= self.levelLo and row.level <= (self.levelHi or self.levelLo)
		end
		local badgeText = nil
		if group.missing then
			badgeText = L["Missing"]
		elseif group.missingFrac and group.missingFrac > 0 then
			if group.lvTo and group.lvTo ~= group.lv then
				badgeText = L["Missing data"]
			else
				badgeText = string.format(L["~%d%% missing"], MissingPct(group.missingFrac))
			end
		end
		-- One line. A long route clips at the row edge instead of wrapping
		-- a leftover word back under the level number.
		row.label:ClearAllPoints()
		row.label:SetPoint("LEFT", 10, 0)
		if badgeText then
			row.badge:SetText(badgeText)
			row.badge:SetTextColor(0.92, 0.58, 0.28)
			row.badge:Show()
			row.label:SetPoint("RIGHT", row.badge, "LEFT", -6, 0)
		else
			row.badge:Hide()
			row.label:SetPoint("RIGHT", -8, 0)
		end
		row.label:SetJustifyH("LEFT")
		row.label:SetJustifyV("MIDDLE")
		row.label:SetWordWrap(false)
		if group.missing then
			row.label:SetText(self:LevelName(group))
			row.label:SetTextColor(0.75, 0.52, 0.30)
		else
			row.label:SetText(self:LevelRowLabel(group))
			if selected then
				row.label:SetTextColor(1, 0.86, 0.45)
			else
				row.label:SetTextColor(0.82, 0.80, 0.74)
			end
		end
		row.bar:SetShown(selected)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((i - 1) * 24))
		row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
		row:Show()
	end
	for i = #groups + 1, #self.rows do
		self.rows[i]:Hide()
	end
	self:RefreshCharacters()
	content:SetHeight(math.max(24, #groups * 24))
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

local function EnsureSessionRowActions(row)
	if row.delBtn then
		return
	end
	local del = CreateFrame("Button", nil, row)
	del:SetSize(18, 18)
	del:SetPoint("RIGHT", -4, 0)
	del.icon = del:CreateTexture(nil, "ARTWORK")
	del.icon:SetSize(12, 12)
	del.icon:SetPoint("CENTER")
	del.icon:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
	del.icon:SetVertexColor(0.62, 0.60, 0.56, 0.78)
	del:SetScript("OnEnter", function(self)
		self.icon:SetVertexColor(1.0, 0.36, 0.32, 1.0)
		if GameTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(L["Delete this session"])
			GameTooltip:Show()
		end
	end)
	del:SetScript("OnLeave", function(self)
		self.icon:SetVertexColor(0.62, 0.60, 0.56, 0.78)
		if GameTooltip and GameTooltip:IsOwned(self) then
			GameTooltip:Hide()
		end
	end)
	del:SetScript("OnClick", function(self)
		local parent = self:GetParent()
		if parent and parent.sessionRef then
			ns.Replay:RequestDeleteSession(parent.sessionRef)
		end
	end)
	del:Hide()

	local cancel = CreateFrame("Button", nil, row)
	cancel:SetSize(18, 18)
	cancel:SetPoint("RIGHT", -4, 0)
	cancel.icon = cancel:CreateTexture(nil, "ARTWORK")
	cancel.icon:SetSize(12, 12)
	cancel.icon:SetPoint("CENTER")
	cancel.icon:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
	cancel.icon:SetVertexColor(0.82, 0.80, 0.74, 0.95)
	cancel:SetScript("OnEnter", function(self)
		self.icon:SetVertexColor(1.0, 1.0, 1.0, 1.0)
		if GameTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(L["Cancel"])
			GameTooltip:Show()
		end
	end)
	cancel:SetScript("OnLeave", function(self)
		self.icon:SetVertexColor(0.82, 0.80, 0.74, 0.95)
		if GameTooltip and GameTooltip:IsOwned(self) then
			GameTooltip:Hide()
		end
	end)
	cancel:SetScript("OnClick", function()
		ns.Replay.armedDelete = nil
		ns.Replay:RefreshList()
	end)
	cancel:Hide()

	local confirm = CreateFrame("Button", nil, row)
	confirm:SetSize(18, 18)
	confirm:SetPoint("RIGHT", cancel, "LEFT", -2, 0)
	confirm.icon = confirm:CreateTexture(nil, "ARTWORK")
	confirm.icon:SetSize(14, 14)
	confirm.icon:SetPoint("CENTER")
	confirm.icon:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
	confirm.icon:SetVertexColor(0.45, 0.95, 0.45, 0.95)
	confirm:SetScript("OnEnter", function(self)
		self.icon:SetVertexColor(0.65, 1.0, 0.65, 1.0)
		if GameTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(L["Confirm delete"])
			GameTooltip:Show()
		end
	end)
	confirm:SetScript("OnLeave", function(self)
		self.icon:SetVertexColor(0.45, 0.95, 0.45, 0.95)
		if GameTooltip and GameTooltip:IsOwned(self) then
			GameTooltip:Hide()
		end
	end)
	confirm:SetScript("OnClick", function(self)
		local parent = self:GetParent()
		local session = parent and parent.sessionRef
		ns.Replay.armedDelete = nil
		if session then
			ns.Replay:DeleteSessionNow(ns.DB.char, session)
		end
	end)
	confirm:Hide()

	row.delBtn = del
	row.cancelBtn = cancel
	row.confirmBtn = confirm
end

function ns.Replay:RequestDeleteSession(session)
	if not session or session == ns.DB:Current() then
		return
	end
	local journey = ns.DB.char
	if type(journey) ~= "table" then
		return
	end
	local gained = ns.DB:LevelsGained(session)
	local leveled = type(session.lv) == "number" and type(session.el) == "number" and session.el > session.lv
	if gained > 0 or leveled then
		self.armedDelete = nil
		self:RefreshList()
		if StaticPopupDialogs and StaticPopup_Show then
			if not StaticPopupDialogs.ZIPPER_DELETE_XP_SESSION then
				StaticPopupDialogs.ZIPPER_DELETE_XP_SESSION = {
					text = "%s",
					button1 = L["Delete"],
					button2 = L["Cancel"],
					timeout = 0,
					whileDead = true,
					hideOnEscape = true,
					preferredIndex = 3,
					OnAccept = function(_, data)
						if type(data) == "table" and data.journey and data.session then
							ns.Replay:DeleteSessionNow(data.journey, data.session)
						end
					end,
				}
			end
			local when = date("%m/%d %H:%M", session.s)
			local dur = FormatClock((ns.DB:SessionStop(session) or session.s) - session.s)
			local msg = string.format(
				L["Delete session from %s (%s)?\n\nThis session gained +%.2f levels of XP and cannot be recovered."],
				when, dur, gained or 0
			)
			StaticPopup_Show("ZIPPER_DELETE_XP_SESSION", msg, nil, {
				journey = journey,
				session = session,
			})
			return
		end
	end
	self.armedDelete = session
	self:RefreshList()
end

function ns.Replay:CaptureSelectionRefs()
	local sessions = ns.DB:Sessions()
	local span = {}
	if self.mode == "span" and self.sessionLo and self.sessionHi then
		for i = self.sessionLo, self.sessionHi do
			if sessions[i] then
				span[sessions[i]] = true
			end
		end
	end
	return {
		journey = ns.DB.char,
		mode = self.mode,
		oldIndex = self.index,
		idxSession = self.index and sessions[self.index] or nil,
		span = span,
	}
end

function ns.Replay:RestoreSelectionAfterDelete(snap)
	self.armedDelete = nil
	self.statsKey = nil
	self.chapterKey = nil
	if snap and snap.journey and snap.journey ~= ns.DB.char then
		return
	end
	local sessions = ns.DB:Sessions()
	local count = #sessions
	local function findSession(target)
		if not target then
			return nil
		end
		for i = 1, count do
			if sessions[i] == target then
				return i
			end
		end
		return nil
	end
	if count == 0 then
		self.mode = "all"
		self.index = nil
		self.sessionLo = nil
		self.sessionHi = nil
	elseif self.mode == "one" then
		local found = findSession(snap and snap.idxSession)
		if found then
			self.index = found
		else
			local fallback = (snap and snap.oldIndex) or self.index or count
			if fallback > count then
				fallback = count
			elseif fallback < 1 then
				fallback = 1
			end
			self.index = fallback
		end
		if sessions[self.index] == ns.DB:Current() then
			self.mode = "current"
			self.index = nil
		end
	elseif self.mode == "span" then
		local lo, hi
		local kept = snap and snap.span
		if kept then
			for i = 1, count do
				if kept[sessions[i]] then
					if not lo then
						lo = i
					end
					hi = i
				end
			end
		end
		if not lo then
			self.mode = "all"
			self.index = nil
			self.sessionLo = nil
			self.sessionHi = nil
		elseif lo == hi then
			self.sessionLo = lo
			self.sessionHi = lo
			if sessions[lo] == ns.DB:Current() then
				self.mode = "current"
				self.index = nil
			else
				self.mode = "one"
				self.index = lo
			end
		else
			self.index = lo
			self.sessionLo = lo
			self.sessionHi = hi
		end
	end
	if self.frame and self.frame:IsShown() then
		self:ReloadView()
		self:SyncSessionAnchor()
		self:RefreshList()
		self:UpdateReadout()
		self:Redraw()
	else
		self.dirty = true
	end
end

function ns.Replay:DeleteSessionNow(journey, session)
	if type(journey) ~= "table" or not session or session == ns.DB:Current() then
		return
	end
	local when = date("%m/%d %H:%M", session.s)
	local snap = self:CaptureSelectionRefs()
	local removed = ns.DB:DeleteSession(journey, session)
	if not removed then
		return
	end
	if journey == ns.DB.char then
		self:RestoreSelectionAfterDelete(snap)
	else
		self.armedDelete = nil
	end
	if ns.Config then
		ns.Config:RefreshSize()
		ns.Config:RefreshIsolationList()
		ns.Config:RefreshPurgeList()
	end
	ns:Print(string.format(L["Deleted session from %s."], when))
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
	self.levelListKey = nil
	local sessions = ns.DB:Sessions()
	if self.armedDelete then
		local found = false
		for i = 1, #sessions do
			if sessions[i] == self.armedDelete then
				found = true
				break
			end
		end
		if not found then
			self.armedDelete = nil
		end
	end
	self:RefreshCharacters()
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
			row:SetHeight(24)
			row.bar = row:CreateTexture(nil, "BACKGROUND")
			row.bar:SetAllPoints()
			row.bar:SetColorTexture(0.85, 0.68, 0.28, 0.16)
			row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			row.label:SetPoint("LEFT", 10, 0)
			row.label:SetPoint("RIGHT", -8, 0)
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
		EnsureSessionRowActions(row)
		row:SetHeight(24)
		if row.badge then
			row.badge:Hide()
		end
		row.levelGroup = nil
		row.sessionIndex = index
		row.sessionRef = session
		row.level = nil
		local isCurrent = session == ns.DB:Current()
		local armed = not isCurrent and self.armedDelete == session
		row.delBtn:SetShown(not isCurrent and not armed)
		row.confirmBtn:SetShown(armed)
		row.cancelBtn:SetShown(armed)
		row.label:ClearAllPoints()
		row.label:SetPoint("LEFT", 10, 0)
		if armed then
			row.label:SetPoint("RIGHT", -46, 0)
		elseif not isCurrent then
			row.label:SetPoint("RIGHT", -24, 0)
		else
			row.label:SetPoint("RIGHT", -8, 0)
		end
		row.label:SetJustifyH("LEFT")
		row.label:SetJustifyV("MIDDLE")
		row.label:SetWordWrap(false)
		row.label:SetIndentedWordWrap(false)
		local duration = (ns.DB:SessionStop(session) or session.s) - session.s
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
			selected = isCurrent
		end
		local gained = ns.DB:LevelsGained(session)
		local when = isCurrent and L["Current"] or date("%m/%d %H:%M", session.s)
		row.label:SetText(string.format(L["%s    %s    +%.2f lv    %d kills"], when, FormatClock(duration), gained, session.kills or 0))
		row.bar:SetShown(selected)
		if selected then
			row.label:SetTextColor(1, 0.86, 0.45)
		else
			row.label:SetTextColor(0.82, 0.80, 0.74)
		end
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -((i - 1) * 24))
		row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
		row:Show()
	end
	for i = #sessions + 1, #self.rows do
		self.rows[i]:Hide()
	end
	content:SetHeight(math.max(24, #sessions * 24))
end

function ns.Replay:TogglePlay()
	if not self.t0 or not self.t1 then
		return
	end
	if self.playing then
		self.playing = false
		self.playButton:SetText(L["Play"])
		-- Scrubber still at the start: restore the full-route preview.
		if self:PreviewFullRoute() and self.route then
			self.trailDirty = false
			self.lastTrailRedraw = GetTime()
			self:Redraw()
		end
		return
	end
	if self.playhead >= self.t1 - 0.05 then
		self.playhead = self.t0
	end
	self.playing = true
	self.route = true
	self.playButton:SetText(L["Pause"])
	local map = self:EnsureMap()
	if map and not map:IsShown() then
		if not self:OpenWorldMap() and not (InCombatLockdown and InCombatLockdown()) and ToggleWorldMap then
			ToggleWorldMap()
		end
	end
	-- Drop the full-route preview and start drawing only up to the playhead.
	self.trailDirty = false
	self.lastTrailRedraw = GetTime()
	self:Redraw()
end

-- Hover delay for speed tips. Forever has no built-in tooltip hover delay.
local SPEED_TIP_DELAY = 0.5

local function FormatSpeedWall(seconds)
	seconds = math.floor((seconds or 0) + 0.5)
	if seconds < 60 then
		return string.format(L["%d sec"], seconds)
	end
	local totalMins = math.floor(seconds / 60)
	local hours = math.floor(totalMins / 60)
	local mins = totalMins % 60
	if hours <= 0 then
		return string.format(L["%d min"], totalMins)
	end
	if mins == 0 then
		if hours == 1 then
			return L["1 hr"]
		end
		return string.format(L["%d hr"], hours)
	end
	return string.format(L["%d hr %d min"], hours, mins)
end

function ns.Replay:CancelSpeedTooltip(button)
	if not button then
		return
	end
	if button.speedTip then
		button.speedTip:Cancel()
		button.speedTip = nil
	end
	if GameTooltip:IsOwned(button) then
		GameTooltip:Hide()
	end
end

function ns.Replay:ShowSpeedTooltip(button)
	local rate = button and button.speed
	if not rate or rate <= 0 then
		return
	end
	GameTooltip:SetOwner(button, "ANCHOR_TOP")
	GameTooltip:SetText(rate .. "x", 1, 0.86, 0.45)
	GameTooltip:AddLine(string.format(L["1 hr = %s"], FormatSpeedWall(3600 / rate)), 1, 1, 1)
	GameTooltip:Show()
end

function ns.Replay:ScheduleSpeedTooltip(button)
	self:CancelSpeedTooltip(button)
	if not button then
		return
	end
	if not C_Timer or not C_Timer.NewTimer then
		self:ShowSpeedTooltip(button)
		return
	end
	button.speedTip = C_Timer.NewTimer(SPEED_TIP_DELAY, function()
		button.speedTip = nil
		if button:IsMouseOver() then
			ns.Replay:ShowSpeedTooltip(button)
		end
	end)
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

-- Grow t1 with the open recording so play does not stop at the last GPS sample
-- while you stand still after a hearth.
function ns.Replay:ExtendLiveT1()
	if not self.sessions then
		return
	end
	if self.mode == "level" and self.levelLo then
		local _, levelStop = ns.DB:LevelBounds(ns.DB.char, self.levelLo, self.levelHi)
		if levelStop and (not self.t1 or levelStop > self.t1) then
			self.t1 = levelStop
		end
		return
	end
	local _, t1 = Bounds(self.sessions)
	if t1 and (not self.t1 or t1 > self.t1) then
		self.t1 = t1
	end
end

function ns.Replay:OnUpdate(_, elapsed)
	if GetTime() - (self.readoutAt or 0) >= 0.5 then
		self.readoutAt = GetTime()
		self:ExtendLiveT1()
		self:UpdateRecap()
		self:RefreshList()
		self:UpdateReadout()
	end
	if self.dirty and (GetTime() - (self.lastRedraw or 0)) >= 0.5 then
		self:ReloadView()
		self:Redraw()
	end
	if self.playing and self.t0 then
		self:ExtendLiveT1()
		self.playhead = self.playhead + (elapsed * self.speed)
		local gap = self:PieceGapSkipTo(self.playhead)
		if gap and gap > self.playhead then
			self.playhead = gap
		end
		local indoors = self:InstanceSkipTo(self.playhead)
		if indoors and indoors > self.playhead then
			self.playhead = indoors
		end
		local reachedEnd = false
		if self.t1 and self.playhead >= self.t1 then
			self.playhead = self.t1
			self.playing = false
			self.playButton:SetText(L["Play"])
			reachedEnd = true
		end
		self:FollowPlayhead()
		self:UpdateDot()
		self:UpdateReadout()
		self.trailDirty = true
		-- Land the final frame (level-up ring, tip segment) without waiting on the throttle.
		if reachedEnd and self.route then
			self.trailDirty = false
			self.lastTrailRedraw = GetTime()
			self:Redraw()
		end
	end
	-- Keep the drawn tip near the playhead. A multi-second lag (and the old
	-- 0.05s floor at high speed) made kill/quest pins pop in behind the head.
	local trailWait = 0.25 / math.max(self.speed or 1, 1)
	if trailWait > 0.05 then
		trailWait = 0.05
	elseif trailWait < 0.03 then
		trailWait = 0.03
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
		ns.Replay:HideMapLegend()
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
			local marker = self.markers[i]
			host:FitPin(marker, marker.pipSize or PIP)
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
	ZipperDB = ZipperDB or {}
	-- The wide chart window is a temporary opening of the tall panel. Persist
	-- the tall rect so a reload comes back to playback, not a stretched replay.
	if self.expanded and self.collapsedWindow then
		local saved = self.collapsedWindow
		ZipperDB.window = {
			point = saved.point,
			x = saved.x,
			y = saved.y,
			w = saved.w,
			h = saved.h,
		}
		return
	end
	local point, _, _, x, y = frame:GetPoint(1)
	ZipperDB.window = {
		point = point,
		x = x,
		y = y,
		w = frame:GetWidth(),
		h = frame:GetHeight(),
	}
end

-- The open list keeps the tall panel's width up to this. Wider than the
-- session text is empty space beside the chart.
local CHART_COLUMN_MAX = 320

function ns.Replay:ApplyResizeBounds()
	local frame = self.frame
	if not frame then
		return
	end
	local minW, maxW = 348, 460
	if self.expanded then
		local col = self.columnW or 348
		minW = col + 440
		maxW = col + 900
		if maxW < minW then
			maxW = minW
		end
	end
	if frame.SetResizeBounds then
		frame:SetResizeBounds(minW, 520, maxW, 800)
	elseif frame.SetMinResize then
		frame:SetMinResize(minW, 520)
		frame:SetMaxResize(maxW, 800)
	end
end

function ns.Replay:MoveForWidth(width, height)
	local frame = self.frame
	local left = frame:GetLeft()
	local top = frame:GetTop()
	if not left or not top then
		frame:SetSize(width, height)
		return
	end
	local screenW = UIParent and UIParent:GetWidth() or 0
	local screenH = UIParent and UIParent:GetHeight() or 0
	local margin = 12
	if screenW > 0 and left + width > screenW - margin then
		left = screenW - margin - width
	end
	if left < margin then
		left = margin
	end
	if screenH > 0 and top > screenH - margin then
		top = screenH - margin
	end
	if top - height < margin then
		top = height + margin
	end
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
	frame:SetSize(width, height)
end

function ns.Replay:SetExpanded(open)
	open = open and true or false
	if open == (self.expanded and true or false) then
		return
	end
	local frame = self.frame
	if not frame then
		self.expanded = open
		self.pane = open and "charts" or "replay"
		return
	end
	if open then
		local point, _, _, x, y = frame:GetPoint(1)
		self.collapsedWindow = {
			point = point,
			x = x,
			y = y,
			w = frame:GetWidth(),
			h = frame:GetHeight(),
		}
		local col = frame:GetWidth() or 348
		if col < 348 then
			col = 348
		elseif col > 460 then
			col = 460
		end
		if col > CHART_COLUMN_MAX then
			col = CHART_COLUMN_MAX
		end
		self.columnW = col
		self.expanded = true
		self.pane = "charts"
		self.playing = false
		if self.playButton then
			self.playButton:SetText(L["Play"])
		end
		self:ApplyResizeBounds()
		self:ShowChrome(false)
		local height = frame:GetHeight()
		if not height or height < 520 then
			height = 520
		end
		self:MoveForWidth(col + 620, height)
	else
		local saved = self.collapsedWindow
		self.expanded = false
		self.pane = "replay"
		if saved and saved.point then
			frame:ClearAllPoints()
			frame:SetPoint(saved.point, UIParent, saved.point, saved.x or 0, saved.y or 0)
			frame:SetSize(saved.w or self.columnW or 348, saved.h or 736)
		else
			frame:SetWidth(self.columnW or 348)
		end
		self:ApplyResizeBounds()
		self:ShowChrome(true)
	end
	self:UpdateRecap(self.sessions)
end

function ns.Replay:PlaceChartsButton()
	local button = self.chartsButton
	local frame = self.frame
	if not button or not frame then
		return
	end
	button:ClearAllPoints()
	button:SetSize(72, 24)
	button:SetText(L["Charts"])
	button:SetFrameLevel(frame:GetFrameLevel() + 18)
	if self.optionsButton then
		button:SetPoint("RIGHT", self.optionsButton, "LEFT", -4, 0)
	end
	local font = button:GetFontString()
	if font then
		if self.expanded then
			font:SetTextColor(1, 0.86, 0.45)
		else
			font:SetTextColor(0.93, 0.90, 0.78)
		end
	end
	button:Show()
end

function ns.Replay:PlaceCollapseButton(column)
	local button = self.collapseButton
	local frame = self.frame
	if not button or not frame then
		return
	end
	if not self.expanded then
		button:Hide()
		return
	end
	button:ClearAllPoints()
	button:SetFrameLevel(frame:GetFrameLevel() + 18)
	button:SetSize(22, 64)
	button:SetText("<")
	local height = frame:GetHeight() or 700
	button:SetPoint("LEFT", frame, "TOPLEFT", (column or self.columnW or CHART_COLUMN_MAX) - 11, -math.floor(height / 2))
	button:Show()
end

function ns.Replay:AnchorSelector(column, expanded, listH, width)
	local frame = self.frame
	if not frame then
		return
	end
	if not expanded then
		if self.header then
			self.header:ClearAllPoints()
			self.header:SetPoint("TOPLEFT", 2, -2)
			self.header:SetPoint("TOPRIGHT", -2, -2)
			self.header:SetHeight(56)
		end
		if self.titleText then
			self.titleText:ClearAllPoints()
			self.titleText:SetPoint("TOPLEFT", 18, -10)
			self.titleText:SetPoint("RIGHT", frame, "RIGHT", -196, 0)
		end
		if self.charButton then
			self.charButton:ClearAllPoints()
			self.charButton:SetPoint("TOPLEFT", 16, -32)
			self.charButton:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
			self.charButton:SetHeight(22)
		end
		if self.closeButton then
			self.closeButton:ClearAllPoints()
			self.closeButton:SetPoint("TOPRIGHT", -2, -2)
		end
		if self.selectAllButton then
			self.selectAllButton:ClearAllPoints()
			self.selectAllButton:SetPoint("TOPRIGHT", -16, -68)
		end
		if self.scopeText then
			self.scopeText:ClearAllPoints()
			self.scopeText:SetPoint("TOPLEFT", 18, -100)
			self.scopeText:SetPoint("RIGHT", frame, "RIGHT", -18, 0)
		end
		if self.listInset then
			self.listInset:ClearAllPoints()
			self.listInset:SetPoint("TOPLEFT", 16, -132)
			self.listInset:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
		end
		return
	end
	-- Same vertical anchors as the tall panel. Shift only the right edge back
	-- by however much wider the chart pane made the window.
	local extra = (width or frame:GetWidth() or column) - column
	if extra < 0 then
		extra = 0
	end
	if self.header then
		self.header:ClearAllPoints()
		self.header:SetPoint("TOPLEFT", 2, -2)
		self.header:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(extra + 2), -2)
		self.header:SetHeight(56)
	end
	if self.titleText then
		self.titleText:ClearAllPoints()
		self.titleText:SetPoint("TOPLEFT", 18, -10)
		self.titleText:SetPoint("RIGHT", frame, "RIGHT", -(extra + 196), 0)
	end
	if self.charButton then
		self.charButton:ClearAllPoints()
		self.charButton:SetPoint("TOPLEFT", 16, -32)
		self.charButton:SetPoint("RIGHT", frame, "RIGHT", -(extra + 16), 0)
		self.charButton:SetHeight(22)
	end
	if self.closeButton then
		self.closeButton:ClearAllPoints()
		self.closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(extra + 2), -2)
	end
	if self.selectAllButton then
		self.selectAllButton:ClearAllPoints()
		self.selectAllButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(extra + 16), -68)
	end
	if self.scopeText then
		self.scopeText:ClearAllPoints()
		self.scopeText:SetPoint("TOPLEFT", 18, -100)
		self.scopeText:SetPoint("RIGHT", frame, "RIGHT", -(extra + 18), 0)
	end
	if self.listInset then
		self.listInset:ClearAllPoints()
		self.listInset:SetPoint("TOPLEFT", 16, -132)
		self.listInset:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", column - 16, -(132 + (listH or 64)))
	end
end

-- Playback widgets live on self.chrome. Hiding that frame hides the chapter
-- ticks too, including ones LayoutPips shows again after a selection change.
-- Their anchors stay on the panel. A hidden parent does not draw or click.
function ns.Replay:OwnChrome()
	local chrome = self.chrome
	if not chrome then
		return
	end
	local owned = {
		self.chapterStrip,
		self.scrub,
		self.timeText,
		self.timeMissing,
		self.playButton,
		self.trailLabel,
		self.trailValue,
		self.trailSlider,
		self.statInset,
	}
	if self.jumpButtons then
		for i = 1, #self.jumpButtons do
			owned[#owned + 1] = self.jumpButtons[i]
		end
	end
	if self.speedButtons then
		for i = 1, #self.speedButtons do
			owned[#owned + 1] = self.speedButtons[i]
		end
	end
	if self.pips then
		for i = 1, #self.pips do
			owned[#owned + 1] = self.pips[i]
		end
	end
	if self.gapPips then
		for i = 1, #self.gapPips do
			owned[#owned + 1] = self.gapPips[i]
		end
	end
	for i = 1, #owned do
		local widget = owned[i]
		if widget and widget.SetParent and widget:GetParent() ~= chrome then
			widget:SetParent(chrome)
		end
	end
end

function ns.Replay:ShowChrome(show)
	local chrome = self.chrome
	if not chrome then
		return
	end
	if show then
		chrome:Show()
	else
		chrome:Hide()
	end
end

function ns.Replay:Layout(width, height)
	local inset = self.listInset
	if not inset or not width or not height or width < 1 or height < 1 then
		return
	end
	local listTop = 132
	local gap = 14
	-- Chapter strip is 40px; scrub sits far enough below that 12px chapter
	-- pips have a clear lane between the strip bottom and the track.
	local charts = self.expanded and ns.Viz and ns.Viz.pane
	local controls = charts and 0 or 220
	local after = charts and 0 or 16
	local bottom = 14
	local side = 16
	local column = width
	if charts then
		column = self.columnW or CHART_COLUMN_MAX
		if column > CHART_COLUMN_MAX then
			column = CHART_COLUMN_MAX
		elseif column < 280 then
			column = 280
		end
	end
	local leftover = height - (listTop + gap + controls + after + bottom)
	local listH
	if charts then
		listH = height - listTop - bottom
	else
		listH = math.floor(leftover * 0.42)
	end
	if listH < 64 then
		listH = 64
	end
	-- Charts use the whole column under the header. The old floor was for a
	-- drawing tucked under a short list, and it would chop this list back.
	if not charts then
		if leftover - listH < 48 then
			listH = leftover - 48
		end
		if listH < 48 then
			listH = 48
		end
	end
	local frame = self.frame
	self:AnchorSelector(column, charts and true or false, listH, width)
	if not charts then
		inset:SetHeight(listH)
	end
	local y = -(listTop + listH + gap)
	local body = y
	local contentWidth = column - 66
	if contentWidth < 200 then
		contentWidth = 200
	end
	if self.listContent then
		self.listContent:SetWidth(contentWidth)
	end
	if self.statContent then
		self.statContent:SetWidth(contentWidth)
	end
	if charts then
		self:ShowChrome(false)
		self:PlaceChartsButton()
		self:PlaceCollapseButton(column)
		ns.Viz:PlaceBox(column + 8, 12, side, bottom)
		return
	end
	if ns.Viz and ns.Viz.HidePane then
		ns.Viz:HidePane()
	end
	self:PlaceChartsButton()
	self:PlaceCollapseButton(column)
	self:ShowChrome(true)
	if self.chapterStrip then
		self.chapterStrip:ClearAllPoints()
		self.chapterStrip:SetPoint("TOPLEFT", side, body + 2)
		self.chapterStrip:SetPoint("TOPRIGHT", -side, body + 2)
		self.chapterStrip:SetHeight(40)
	end
	if self.chapterStart then
		self.chapterStart:ClearAllPoints()
		self.chapterStart:SetPoint("LEFT", self.chapterStrip, "LEFT", 4, 0)
	end
	self.chapterPrev:ClearAllPoints()
	if self.chapterStart then
		self.chapterPrev:SetPoint("LEFT", self.chapterStart, "RIGHT", 2, 0)
	else
		self.chapterPrev:SetPoint("TOPLEFT", side, body)
	end
	if self.chapterEnd then
		self.chapterEnd:ClearAllPoints()
		self.chapterEnd:SetPoint("RIGHT", self.chapterStrip, "RIGHT", -4, 0)
	end
	self.chapterNext:ClearAllPoints()
	if self.chapterEnd then
		self.chapterNext:SetPoint("RIGHT", self.chapterEnd, "LEFT", -2, 0)
	else
		self.chapterNext:SetPoint("TOPRIGHT", -side, body)
	end
	self.scrub:ClearAllPoints()
	self.scrub:SetPoint("TOPLEFT", side + 2, body - 68)
	self.scrub:SetPoint("RIGHT", frame, "RIGHT", -(side + 2), 0)
	self.timeText:ClearAllPoints()
	self.timeText:SetPoint("TOPLEFT", side + 2, body - 92)
	self.timeText:SetPoint("RIGHT", frame, "RIGHT", -(side + 2), 0)
	if self.timeMissing then
		self.timeMissing:ClearAllPoints()
		self.timeMissing:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(side + 2), body - 92)
	end
	local jumpWidth, jumpGap = 72, 8
	for i = 1, #self.jumpButtons do
		self.jumpButtons[i]:ClearAllPoints()
		self.jumpButtons[i]:SetPoint("TOPLEFT", side + ((i - 1) * (jumpWidth + jumpGap)), body - 116)
	end
	self.playButton:ClearAllPoints()
	self.playButton:SetPoint("TOPLEFT", side, body - 146)
	local speedWidth, speedGap = 46, 6
	for i = 1, #self.speedButtons do
		self.speedButtons[i]:ClearAllPoints()
		self.speedButtons[i]:SetPoint("TOPLEFT", side + 64 + ((i - 1) * (speedWidth + speedGap)), body - 146)
	end
	self.trailLabel:ClearAllPoints()
	self.trailLabel:SetPoint("TOPLEFT", side + 2, body - 178)
	self.trailValue:ClearAllPoints()
	self.trailValue:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -(side + 2), body - 178)
	self.trailSlider:ClearAllPoints()
	self.trailSlider:SetPoint("TOPLEFT", side + 2, body - 198)
	self.trailSlider:SetPoint("RIGHT", frame, "RIGHT", -(side + 2), 0)
	self.statInset:ClearAllPoints()
	self.statInset:SetPoint("TOPLEFT", side, body - controls - after)
	self.statInset:SetPoint("BOTTOMRIGHT", -side, bottom)
	self:LayoutPips()
end

function ns.Replay:CreateFrame()
	if self.frame then
		return
	end
	local frame = CreateFrame("Frame", "ZipperReplayFrame", UIParent, "BackdropTemplate")
	frame:Hide()
	frame:SetSize(348, 736)
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:SetResizable(true)
	if frame.SetResizeBounds then
		frame:SetResizeBounds(348, 520, 460, 800)
	else
		frame:SetMinResize(348, 520)
		frame:SetMaxResize(460, 800)
	end
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 2,
		-- Match edgeSize so the fill meets the border with no seam.
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	frame:SetBackdropColor(0.06, 0.06, 0.07, 0.98)
	frame:SetBackdropBorderColor(0.78, 0.62, 0.28, 1)
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		ns.Replay:SaveWindow()
		if ns.Viz and ns.Viz.PlaceTabs then
			ns.Viz:PlaceTabs()
		end
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
		ns.Replay.armedDelete = nil
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
		button:SetSize(width, 24)
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
	header:SetColorTexture(0.12, 0.10, 0.08, 1)
	header:SetPoint("TOPLEFT", 2, -2)
	header:SetPoint("TOPRIGHT", -2, -2)
	header:SetHeight(56)

	local headerSheen = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
	headerSheen:SetColorTexture(1, 0.86, 0.45, 0.07)
	headerSheen:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0)
	headerSheen:SetPoint("TOPRIGHT", header, "TOPRIGHT", 0, 0)
	headerSheen:SetHeight(18)

	local rule = frame:CreateTexture(nil, "BORDER")
	rule:SetColorTexture(0.85, 0.68, 0.28, 0.95)
	rule:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
	rule:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
	rule:SetHeight(2)

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 18, -10)
	title:SetPoint("RIGHT", frame, "RIGHT", -110, 0)
	title:SetJustifyH("LEFT")
	title:SetWordWrap(false)
	title:SetTextColor(1, 0.86, 0.45)
	title:SetText(L["Zipper"])

	local charButton = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
	charButton:SetPoint("TOPLEFT", 16, -32)
	charButton:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	charButton:SetHeight(22)
	charButton:OverrideText(L["Character"])
	charButton:SetupMenu(function(_, rootDescription)
		local list = ns.DB:CharacterList()
		for i = 1, #list do
			local info = list[i]
			local mark = info.current and "  · recording" or ""
			if not info.accessible then
				mark = mark .. "  · locked"
			end
			local text = string.format("%s  (%d)%s", info.label, info.sessions, mark)
			rootDescription:CreateRadio(text, function()
				if ns.Replay.blockedKey then
					return info.key == ns.Replay.blockedKey
				end
				return info.key == ns.DB.viewKey
			end, function()
				if not info.accessible then
					ns.Replay:ShowBlocked(info.key, info.label, info.pending)
					return
				end
				ns.Replay:ClearBlocked()
				ns.Replay:RememberPlayhead()
				ns.DB:SetView(info.key)
				if ns.Viz then
					ns.Viz.selectedChars = nil
				end
				if info.key == ns.DB.playerKey then
					ns.Replay:SetMode("current", nil, true)
				else
					ns.Replay:SetMode("all", nil, true)
				end
			end)
		end
	end)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -2, -2)

	local grip = CreateFrame("Button", nil, frame)
	grip:SetSize(16, 16)
	grip:SetFrameLevel(frame:GetFrameLevel() + 20)
	grip:SetPoint("BOTTOMRIGHT", -4, 4)
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
	options:SetPoint("RIGHT", close, "LEFT", 2, 0)
	options:SetScript("OnClick", function()
		ns.Config:Toggle()
	end)

	local chartsButton = MakeButton(frame, L["Charts"], 72)
	chartsButton:SetPoint("RIGHT", options, "LEFT", -4, 0)
	chartsButton:SetFrameLevel(frame:GetFrameLevel() + 18)
	chartsButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	local chartsFont = chartsButton:GetFontString()
	if chartsFont then
		chartsFont:SetWordWrap(false)
		chartsFont:SetTextColor(0.93, 0.90, 0.78)
	end
	chartsButton:SetScript("OnClick", function()
		ns.Replay:SetExpanded(not ns.Replay.expanded)
	end)
	chartsButton:SetScript("OnEnter", function(self)
		local font = self:GetFontString()
		if font then
			font:SetTextColor(1, 0.9, 0.6)
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if ns.Replay.expanded then
			GameTooltip:SetText(L["Back to playback."])
		else
			GameTooltip:SetText(L["Open charts for this selection."])
		end
		GameTooltip:Show()
	end)
	chartsButton:SetScript("OnLeave", function(self)
		local font = self:GetFontString()
		if font then
			if ns.Replay.expanded then
				font:SetTextColor(1, 0.86, 0.45)
			else
				font:SetTextColor(0.93, 0.90, 0.78)
			end
		end
		if GameTooltip:IsOwned(self) then
			GameTooltip:Hide()
		end
	end)

	local collapseButton = MakeButton(frame, "<", 22)
	collapseButton:SetFrameLevel(frame:GetFrameLevel() + 18)
	collapseButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	collapseButton:Hide()
	local collapseFont = collapseButton:GetFontString()
	if collapseFont then
		collapseFont:SetWordWrap(false)
		collapseFont:SetTextColor(0.93, 0.90, 0.78)
	end
	collapseButton:SetScript("OnClick", function()
		ns.Replay:SetExpanded(false)
	end)
	collapseButton:SetScript("OnEnter", function(self)
		local font = self:GetFontString()
		if font then
			font:SetTextColor(1, 0.9, 0.6)
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(L["Back to playback."])
		GameTooltip:Show()
	end)
	collapseButton:SetScript("OnLeave", function(self)
		local font = self:GetFontString()
		if font then
			font:SetTextColor(0.93, 0.90, 0.78)
		end
		if GameTooltip:IsOwned(self) then
			GameTooltip:Hide()
		end
	end)

	local sessionButton = MakeButton(frame, L["Sessions"], 96)
	sessionButton:SetPoint("TOPLEFT", 16, -68)
	sessionButton:SetScript("OnClick", function()
		ns.Replay:ShowSessions()
	end)

	local levelsButton = MakeButton(frame, L["Levels"], 88)
	levelsButton:SetPoint("LEFT", sessionButton, "RIGHT", 8, 0)
	levelsButton:SetScript("OnClick", function()
		ns.Replay:RememberPlayhead()
		ns.Replay.levelLo = nil
		ns.Replay.levelHi = nil
		ns.Replay:SetMode("level", nil, true)
	end)

	local selectAll = MakeButton(frame, L["All"], 48)
	selectAll:SetPoint("TOPRIGHT", -16, -68)
	selectAll:SetScript("OnClick", function()
		ns.Replay:SelectAll()
	end)

	local scope = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	scope:SetPoint("TOPLEFT", 18, -100)
	scope:SetPoint("RIGHT", frame, "RIGHT", -18, 0)
	scope:SetJustifyH("LEFT")
	scope:SetWordWrap(true)
	scope:SetText(L["The recording in progress."])

	local inset = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	inset:SetPoint("TOPLEFT", 16, -132)
	inset:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	inset:SetHeight(168)
	inset:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	inset:SetBackdropColor(0, 0, 0, 0.35)
	inset:SetBackdropBorderColor(0.35, 0.30, 0.16, 0.85)

	local scroll = CreateFrame("ScrollFrame", nil, inset, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 8, -6)
	scroll:SetPoint("BOTTOMRIGHT", -26, 6)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(260, 24)
	scroll:SetScrollChild(content)

	local blockedText = inset:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	blockedText:SetPoint("TOPLEFT", 14, -16)
	blockedText:SetPoint("RIGHT", inset, "RIGHT", -14, 0)
	blockedText:SetJustifyH("LEFT")
	blockedText:SetJustifyV("TOP")
	blockedText:SetWordWrap(true)
	blockedText:SetTextColor(0.93, 0.82, 0.55)
	blockedText:Hide()

	local blockedLink = CreateFrame("Button", nil, inset)
	blockedLink:SetPoint("TOPLEFT", blockedText, "BOTTOMLEFT", 0, -10)
	blockedLink:SetSize(160, 18)
	blockedLink.label = blockedLink:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	blockedLink.label:SetAllPoints()
	blockedLink.label:SetJustifyH("LEFT")
	blockedLink.label:SetTextColor(0.35, 0.75, 1)
	blockedLink.label:SetText(L["Open Saved data"])
	blockedLink:SetFontString(blockedLink.label)
	blockedLink:SetScript("OnClick", function()
		if ns.Config and ns.Config.OpenSaved then
			ns.Config:OpenSaved()
		elseif ns.Config then
			ns.Config:Toggle()
		end
	end)
	blockedLink:SetScript("OnEnter", function(self)
		self.label:SetTextColor(0.55, 0.88, 1)
	end)
	blockedLink:SetScript("OnLeave", function(self)
		self.label:SetTextColor(0.35, 0.75, 1)
	end)
	blockedLink:Hide()

	local play = MakeButton(frame, L["Play"], 56)
	play:SetPoint("TOPLEFT", 16, -418)
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
	local speedWidth, speedGap = 46, 6
	for i = 1, #SPEEDS do
		local rate = SPEEDS[i]
		local speed = MakeButton(frame, rate .. "x", speedWidth)
		speed.speed = rate
		speed:SetPoint("TOPLEFT", 80 + ((i - 1) * (speedWidth + speedGap)), -418)
		speed:SetScript("OnClick", function(button)
			ns.Replay:CancelSpeedTooltip(button)
			ns.Replay:SetSpeed(button.speed)
		end)
		speed:SetScript("OnEnter", function(self)
			local font = self:GetFontString()
			if font then
				font:SetTextColor(1, 0.9, 0.6)
			end
			ns.Replay:ScheduleSpeedTooltip(self)
		end)
		speed:SetScript("OnLeave", function(self)
			ns.Replay:CancelSpeedTooltip(self)
			ns.Replay:StyleSpeedButtons()
		end)
		speedButtons[i] = speed
	end

	local trailLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	trailLabel:SetPoint("TOPLEFT", 18, -450)
	trailLabel:SetText(L["Trail"])
	trailLabel:SetTextColor(0.85, 0.82, 0.70)

	local trailValue = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	trailValue:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, -450)
	trailValue:SetTextColor(1, 0.86, 0.45)
	trailValue:SetText(L["Full"])

	local trail = CreateFrame("Slider", "ZipperReplayTrail", frame, "UISliderTemplate")
	trail:SetPoint("TOPLEFT", 18, -470)
	trail:SetPoint("RIGHT", frame, "RIGHT", -18, 0)
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
	local jumpWidth, jumpGap = 72, 8
	for i = 1, 4 do
		local jump = MakeButton(frame, "+0", jumpWidth)
		jump:SetPoint("TOPLEFT", 16 + ((i - 1) * (jumpWidth + jumpGap)), -388)
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

	-- Typographic arrows sit on the gold strip with no extra button chrome.
	local function MakeNavGlyph(parent, glyph, width)
		local button = CreateFrame("Button", nil, parent)
		button:SetSize(width or 40, 40)
		button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		local label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		label:SetPoint("CENTER", 0, 1)
		local face, _, flags = label:GetFont()
		if face then
			label:SetFont(face, 28, flags)
		end
		label:SetText(glyph)
		label:SetTextColor(0.93, 0.90, 0.78)
		button:SetFontString(label)
		button:SetScript("OnEnter", function(self)
			local font = self:GetFontString()
			if font then
				font:SetTextColor(1, 0.9, 0.6)
			end
			if self.navTip then
				GameTooltip:SetOwner(self, "ANCHOR_TOP")
				GameTooltip:SetText(self.navTip)
				GameTooltip:Show()
			end
		end)
		button:SetScript("OnLeave", function(self)
			local font = self:GetFontString()
			if font then
				font:SetTextColor(0.93, 0.90, 0.78)
			end
			if GameTooltip:IsOwned(self) then
				GameTooltip:Hide()
			end
		end)
		return button
	end

	local chapterStrip = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	chapterStrip:SetPoint("TOPLEFT", 16, -296)
	chapterStrip:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
	chapterStrip:SetHeight(40)
	chapterStrip:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	chapterStrip:SetBackdropColor(0.04, 0.03, 0.02, 0.85)
	chapterStrip:SetBackdropBorderColor(0.62, 0.50, 0.22, 0.9)

	local chapterStart = MakeNavGlyph(chapterStrip, "«", 40)
	chapterStart:SetPoint("LEFT", 4, 0)
	chapterStart.navTip = L["Jump to start"]
	chapterStart:SetScript("OnClick", function()
		ns.Replay:SeekToEdge(false)
	end)

	local chapterPrev = MakeNavGlyph(chapterStrip, "‹", 40)
	chapterPrev:SetPoint("LEFT", chapterStart, "RIGHT", 2, 0)
	chapterPrev.navTip = L["Previous chapter"]
	chapterPrev:SetScript("OnClick", function()
		ns.Replay:SkipChapter(-1)
	end)

	local chapterEnd = MakeNavGlyph(chapterStrip, "»", 40)
	chapterEnd:SetPoint("RIGHT", -4, 0)
	chapterEnd.navTip = L["Jump to end"]
	chapterEnd:SetScript("OnClick", function()
		ns.Replay:SeekToEdge(true)
	end)

	local chapterNext = MakeNavGlyph(chapterStrip, "›", 40)
	chapterNext:SetPoint("RIGHT", chapterEnd, "LEFT", -2, 0)
	chapterNext.navTip = L["Next chapter"]
	chapterNext:SetScript("OnClick", function()
		ns.Replay:SkipChapter(1)
	end)

	local chapterText = chapterStrip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	chapterText:SetPoint("LEFT", chapterPrev, "RIGHT", 8, 0)
	chapterText:SetPoint("RIGHT", chapterNext, "LEFT", -8, 0)
	chapterText:SetJustifyH("CENTER")
	chapterText:SetWordWrap(false)
	chapterText:SetTextColor(0.93, 0.90, 0.78)
	chapterText:SetText(L["No chapters yet"])

	local scrub = CreateFrame("Slider", "ZipperReplayScrub", frame, "UISliderTemplate")
	scrub:SetPoint("TOPLEFT", 18, -366)
	scrub:SetPoint("RIGHT", frame, "RIGHT", -18, 0)
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
	timeText:SetPoint("TOPLEFT", 18, -368)
	timeText:SetPoint("RIGHT", frame, "RIGHT", -18, 0)
	timeText:SetJustifyH("LEFT")
	timeText:SetTextColor(0.85, 0.82, 0.70)

	local timeMissing = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	timeMissing:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, -368)
	timeMissing:SetJustifyH("RIGHT")
	timeMissing:SetWordWrap(false)
	timeMissing:SetTextColor(0.92, 0.58, 0.28)
	timeMissing:Hide()

	local statInset = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	statInset:SetPoint("TOPLEFT", 16, -500)
	statInset:SetPoint("BOTTOMRIGHT", -16, 14)
	statInset:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	statInset:SetBackdropColor(0, 0, 0, 0.35)
	statInset:SetBackdropBorderColor(0.35, 0.30, 0.16, 0.85)

	local statScroll = CreateFrame("ScrollFrame", "ZipperReplayStats", statInset, "UIPanelScrollFrameTemplate")
	statScroll:SetPoint("TOPLEFT", 8, -6)
	statScroll:SetPoint("BOTTOMRIGHT", -26, 6)
	local statContent = CreateFrame("Frame", nil, statScroll)
	statContent:SetSize(260, 18)
	statScroll:SetScrollChild(statContent)

	self.listInset = inset
	self.frame = frame
	self.header = header
	self.scopeText = scope
	self.titleText = title
	self.closeButton = close
	self.optionsButton = options
	self.chartsButton = chartsButton
	self.collapseButton = collapseButton
	self.charButton = charButton
	self.blockedText = blockedText
	self.blockedLink = blockedLink
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
	self.chapterStrip = chapterStrip
	self.chapterStart = chapterStart
	self.chapterPrev = chapterPrev
	self.chapterNext = chapterNext
	self.chapterEnd = chapterEnd
	self.chapterText = chapterText
	self.timeText = timeText
	self.timeMissing = timeMissing
	self.trailLabel = trailLabel
	self.trailValue = trailValue
	self.trailSlider = trail
	self.statInset = statInset
	self.statScroll = statScroll
	self.statContent = statContent
	self.statRows = {}
	-- Under the list. Chart mode hides this whole frame, so a chapter tick
	-- cannot be shown back onto the chart by a later layout pass.
	local chrome = CreateFrame("Frame", nil, frame)
	chrome:SetAllPoints(frame)
	chrome:EnableMouse(false)
	chrome:SetFrameLevel(frame:GetFrameLevel() + 1)
	self.chrome = chrome
	self:OwnChrome()
	-- The route can already have drawn into these pools. Replacing the tables
	-- leaves the old textures on the map, stuck to the first view.
	self:EnsurePools()

	if ns.Viz and ns.Viz.Attach then
		ns.Viz:Attach(self)
	end

	local window = ZipperDB and ZipperDB.window
	frame:ClearAllPoints()
	if window and window.point then
		frame:SetPoint(window.point, UIParent, window.point, window.x or 0, window.y or 0)
	else
		frame:SetPoint("RIGHT", UIParent, "RIGHT", -40, 40)
	end
	local width = window and tonumber(window.w) or 348
	local height = window and tonumber(window.h) or 736
	if not width or width < 348 then
		width = 348
	elseif width > 460 then
		width = 460
	end
	if not height or height < 520 then
		height = 520
	elseif height > 800 then
		height = 800
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
	dot.mode = "move"
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
	self:HookMap()
	if map and not map:IsShown() then
		if not self:OpenWorldMap() and not (InCombatLockdown and InCombatLockdown()) and ToggleWorldMap then
			ToggleWorldMap()
		end
	end
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

local function LegendSwatchColor(entry)
	if entry.r then
		return entry.r, entry.g, entry.b
	end
	local color = ns.KindColor[entry.kind]
	if color then
		return color[1], color[2], color[3]
	end
	return 1, 0.82, 0.28
end

function ns.Replay:LegendEntries()
	local entries = {}
	local list = ns.LegendSpecs or {}
	for i = 1, #list do
		local spec = list[i]
		local pip = spec.pip
		local legend = pip and pip.legend
		if pip and legend then
			local color = pip.color or spec.color or { 1, 0.82, 0.28 }
			local texture = pip.shape == "ring" and MEDIA_RING or MEDIA_CIRCLE
			entries[#entries + 1] = {
				label = legend.label or spec.name,
				texture = texture,
				r = color[1],
				g = color[2],
				b = color[3],
				size = legend.size or 9,
			}
			if spec.kind == Kind.KILL then
				entries[#entries + 1] = {
					label = L["Elite kill"],
					texture = MEDIA_CIRCLE,
					r = color[1],
					g = color[2],
					b = color[3],
					size = 11,
					elite = true,
				}
			end
		end
	end
	return entries
end

function ns.Replay:HideMapLegend()
	self.legendWanted = false
	if self.mapLegend then
		self.mapLegend:Hide()
	end
end

function ns.Replay:HideMapLegendSoon()
	self.legendWanted = false
	C_Timer.After(0.12, function()
		if self.legendWanted then
			return
		end
		local legend = self.mapLegend
		local button = self.mapButton
		if legend and legend:IsMouseOver() then
			return
		end
		if button and button:IsMouseOver() then
			return
		end
		self:HideMapLegend()
	end)
end

function ns.Replay:EnsureMapLegend()
	if self.mapLegend then
		return self.mapLegend
	end
	local frame = CreateFrame("Frame", "ZipperMapLegend", UIParent, "BackdropTemplate")
	frame:SetFrameStrata("TOOLTIP")
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	frame:SetBackdropColor(0.05, 0.05, 0.06, 0.94)
	frame:SetBackdropBorderColor(0.62, 0.50, 0.22, 0.9)
	frame:Hide()

	local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText(L["Zipper"])
	title:SetTextColor(1, 0.82, 0)

	local entries = self:LegendEntries()
	local rows = {}
	local y = -32
	local contentWidth = 196
	for i = 1, #entries do
		local entry = entries[i]
		local row = CreateFrame("Frame", nil, frame)
		row:SetSize(contentWidth, 18)
		row:SetPoint("TOPLEFT", 12, y)
		local size = entry.size or 8
		local swatchHost = CreateFrame("Frame", nil, row)
		swatchHost:SetSize(size, size)
		swatchHost:SetPoint("LEFT", 0, 0)
		local r, g, b = LegendSwatchColor(entry)
		if entry.elite then
			local border = swatchHost:CreateTexture(nil, "ARTWORK")
			border:SetAllPoints()
			border:SetTexture(MEDIA_RING)
			border:SetVertexColor(ELITE_BORDER_R, ELITE_BORDER_G, ELITE_BORDER_B, 1)
			local fill = swatchHost:CreateTexture(nil, "OVERLAY")
			fill:SetPoint("TOPLEFT", 2, -2)
			fill:SetPoint("BOTTOMRIGHT", -2, 2)
			fill:SetTexture(entry.texture or MEDIA_CIRCLE)
			fill:SetVertexColor(r, g, b, 1)
		else
			local swatch = swatchHost:CreateTexture(nil, "ARTWORK")
			swatch:SetAllPoints()
			swatch:SetTexture(entry.texture or MEDIA_CIRCLE)
			swatch:SetVertexColor(r, g, b, 1)
		end
		local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		label:SetPoint("LEFT", swatchHost, "RIGHT", 10, 0)
		label:SetPoint("RIGHT", row, "RIGHT", 0, 0)
		label:SetJustifyH("LEFT")
		label:SetText(entry.label)
		rows[i] = row
		y = y - 18
	end

	y = y - 8
	local rule = frame:CreateTexture(nil, "ARTWORK")
	rule:SetColorTexture(0.62, 0.50, 0.22, 0.55)
	rule:SetHeight(1)
	rule:SetPoint("TOPLEFT", 12, y)
	rule:SetPoint("TOPRIGHT", -12, y)

	y = y - 10
	local hints = {
		L["Left click: show or hide the route."],
		L["Right click: open the replay and show the route."],
		L["Shift+right click: open settings."],
	}
	for i = 1, #hints do
		local hint = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		hint:SetPoint("TOPLEFT", 12, y)
		hint:SetWidth(contentWidth)
		hint:SetJustifyH("LEFT")
		hint:SetJustifyV("TOP")
		hint:SetWordWrap(true)
		hint:SetNonSpaceWrap(true)
		hint:SetText(hints[i])
		hint:SetTextColor(0.85, 0.85, 0.85)
		local height = hint:GetStringHeight() or 12
		if height < 12 then
			height = 12
		end
		hint:SetHeight(height)
		y = y - (height + 6)
	end

	frame:SetSize(contentWidth + 24, -y + 12)
	frame:SetScript("OnEnter", function()
		ns.Replay.legendWanted = true
	end)
	frame:SetScript("OnLeave", function()
		ns.Replay:HideMapLegendSoon()
	end)
	self.mapLegend = frame
	self.mapLegendRows = rows
	return frame
end

function ns.Replay:ShowMapLegend(anchor)
	local frame = self:EnsureMapLegend()
	self.legendWanted = true
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 4)
	frame:SetFrameStrata("TOOLTIP")
	frame:Show()
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
		ns.Replay:HideMapLegend()
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
		ns.Replay:ShowMapLegend(self)
	end)
	button:SetScript("OnLeave", function()
		ns.Replay:HideMapLegendSoon()
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
	-- Zipper embeds Krowi_WorldMapButtons-1.4. That library owns the corner
	-- column (shared with RareScanner/Questie when present). Anchoring under
	-- "whoever is lowest" fights OneForAll, because both keep moving under
	-- each other until the anchors form a circle.
	local lib = LibStub("Krowi_WorldMapButtons-1.4")
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
		local buttons = { self.sessionButton, self.selectAllButton, self.playButton, self.optionsButton, self.chartsButton }
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
		-- Chapter nav glyphs are bare text on the strip; skip Button paint so
		-- Ellesmere does not wrap them in extra chrome.
		buttons[#buttons + 1] = self.levelsButton
		for i = 1, #buttons do
			local button = buttons[i]
			if button then
				paint(skin.Button, button)
				paint(skin.WhiteButtonLabel, button)
			end
		end
		if self.charButton then
			paint(skin.Dropdown, self.charButton)
		end
		if ns.Viz and ns.Viz.charDropdown then
			paint(skin.Dropdown, ns.Viz.charDropdown)
		end
		if self.chapterStrip then
			paint(skin.Inset, self.chapterStrip)
		end
		if self.chapterText then
			paint(skin.Font, self.chapterText)
		end
		for _, nav in ipairs({ self.chapterStart, self.chapterPrev, self.chapterNext, self.chapterEnd }) do
			if nav then
				paint(skin.WhiteButtonLabel, nav)
				local font = nav:GetFontString()
				if font then
					font:SetTextColor(0.93, 0.90, 0.78)
				end
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
		if self.timeMissing then
			paint(skin.Font, self.timeMissing)
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
	if ns.Viz and ns.Viz.StyleTabs then
		ns.Viz:StyleTabs()
	end
	self:OwnChrome()
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
