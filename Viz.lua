local _, ns = ...
local L = ns.L

-- Charts read one summary of the current replay selection.
-- Summarize walks those sessions once and keeps the numbers. A chart file
-- turns that table into a model. A display draws the model. Switching charts
-- or display types does not walk the tracks again.
-- The replay window grows to the right for charts. A list of chart names sits
-- on the left of that new area, and the drawing fills the rest.
--
-- Visualizations/index.xml loads the displays, then one file per chart.
-- A chart registers the question and the display that answers it:
--   ns.Viz:Register {
--     id, label, title, note,
--     display = "groups",
--     displays = { "groups", "columns" },
--     Build = function(summary) return model end,
--   }
-- ns.Viz:SetDisplay(id, displayId) swaps the drawing when displays lists it.
-- A chart that lists more than one shows those names under the note.
-- A new number belongs in Summarize. The chart file only reads the summary.

local WORLD = 0
local TRAVEL_GAP = 20
local charts = {}
local displays = {}

ns.Viz = {
	chartId = "where",
}


function ns.Viz:Clock(seconds)
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

function ns.Viz:Comma(value)
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

local function SortDings(list)
	table.sort(list, function(a, b)
		if a.t == b.t then
			return a.lv < b.lv
		end
		return a.t < b.t
	end)
	return list
end

local function Dings(journey)
	local list = {}
	local rows = journey and journey.levels
	if type(rows) ~= "table" then
		return list
	end
	for i = 1, #rows do
		local row = rows[i]
		if type(row) == "table" and type(row.lv) == "number" and type(row.t) == "number" then
			list[#list + 1] = row
		end
	end
	return SortDings(list)
end

-- Level-up rows are the usual source. A LEVEL event covers a journey whose
-- ding list was missing, without a second chart pass.
local function LevelMarks(sessions, dings)
	local seen = {}
	for i = 1, #dings do
		seen[dings[i].t .. ":" .. dings[i].lv] = true
	end
	local Kind = ns.Kind
	for s = 1, #sessions do
		local session = sessions[s]
		local track = ns.DB:Track(session)
		for i = 1, #(track.ek or {}) do
			if track.ek[i] == Kind.LEVEL then
				local level = track.ea and track.ea[i]
				local when = session.s + (track.et[i] or 0)
				if type(level) == "number" and level > 0 then
					local key = when .. ":" .. level
					if not seen[key] then
						seen[key] = true
						dings[#dings + 1] = { t = when, lv = level }
					end
				end
			end
		end
	end
	return SortDings(dings)
end

local function InstanceType(extra)
	local kind = ns.DB:ReadInstance(extra)
	if type(kind) ~= "number" or kind < ns.Instance.PARTY or kind > ns.Instance.OTHER then
		return ns.Instance.OTHER
	end
	return kind
end

local function Overlap(startT, endT, clip0, clip1)
	if not startT or not endT or endT <= startT then
		return nil
	end
	local a, b = startT, endT
	if clip0 and a < clip0 then
		a = clip0
	end
	if clip1 and b > clip1 then
		b = clip1
	end
	if b <= a then
		return nil
	end
	return a, b
end

-- An open company span runs to the live clock, or to the last session on a
-- finished journey. The same end the party report uses.
local function CompanyEnd(journey)
	if journey == ns.DB.record and ns.DB.session then
		return ns.DB:Now()
	end
	local list = journey and journey.sessions
	local last = type(list) == "table" and list[#list] or nil
	return (last and (last.seen or last.s)) or 0
end

-- One merged span list, so a kill does not walk every companion.
local function GroupSpans(journey)
	local raw = {}
	local with = journey and journey.with
	local liveEnd = CompanyEnd(journey)
	if type(with) == "table" then
		for _, spans in pairs(with) do
			if type(spans) == "table" then
				for i = 1, #spans, 2 do
					local startAt = spans[i]
					local stopAt = spans[i + 1]
					if type(stopAt) ~= "number" then
						stopAt = liveEnd
					end
					if type(startAt) == "number" and stopAt >= startAt then
						raw[#raw + 1] = { startAt, stopAt }
					end
				end
			end
		end
	end
	table.sort(raw, function(a, b)
		return a[1] < b[1]
	end)
	local merged = {}
	for i = 1, #raw do
		local startAt, stopAt = raw[i][1], raw[i][2]
		local last = merged[#merged]
		if last and startAt <= last[2] then
			if stopAt > last[2] then
				last[2] = stopAt
			end
		else
			merged[#merged + 1] = { startAt, stopAt }
		end
	end
	return merged
end

local function GroupedAt(spans, when)
	local lo, hi = 1, #spans
	while lo <= hi do
		local mid = math.floor((lo + hi) / 2)
		local startAt, stopAt = spans[mid][1], spans[mid][2]
		if when < startAt then
			hi = mid - 1
		elseif when > stopAt then
			lo = mid + 1
		else
			return true
		end
	end
	return false
end

local function EmptyLevel(level)
	return {
		lv = level,
		kills = 0,
		turnins = 0,
		deaths = 0,
		solo = 0,
		grouped = 0,
		normal = 0,
		elite = 0,
		rare = 0,
	}
end

function ns.Viz:RegisterDisplay(id, display)
	if type(id) ~= "string" or type(display) ~= "table" or type(display.Draw) ~= "function" then
		return
	end
	display.id = id
	displays[id] = display
end

function ns.Viz:Display(id)
	return displays[id]
end

function ns.Viz:Register(chart)
	if type(chart) ~= "table" or type(chart.id) ~= "string" or type(chart.Build) ~= "function" then
		return
	end
	if type(chart.display) ~= "string" then
		return
	end
	charts[#charts + 1] = chart
	if self.sideTabs then
		self:BuildTabs()
	end
end

function ns.Viz:Find(id)
	for i = 1, #charts do
		if charts[i].id == id then
			return charts[i]
		end
	end
end

-- The chart lists the display names its model can feed. An unlisted name
-- stays on the current drawing.
function ns.Viz:SetDisplay(id, displayId)
	local chart = self:Find(id)
	if not chart or type(displayId) ~= "string" or not displays[displayId] then
		return false
	end
	local allowed = chart.displays
	if type(allowed) ~= "table" then
		return false
	end
	local found = false
	for i = 1, #allowed do
		if allowed[i] == displayId then
			found = true
			break
		end
	end
	if not found then
		return false
	end
	chart.display = displayId
	if self.chartId == id and self.pane and self.pane:IsShown() then
		self:Draw()
	end
	return true
end

function ns.Viz:Chart()
	local chart = self:Find(self.chartId)
	if chart then
		return chart
	end
	return charts[1]
end

function ns.Viz:LevelRows(summary, keys)
	local levels = summary and summary.levels or {}
	local rows = {}
	for i = 1, #levels do
		local row = levels[i]
		local out = { label = string.format(L["Lv %d"], row.lv) }
		for k = 1, #keys do
			local key = keys[k]
			out[key] = row[key] or 0
		end
		rows[#rows + 1] = out
	end
	return rows
end

function ns.Viz:Summarize(replay, sessions)
	sessions = sessions or {}
	local Kind = ns.Kind
	local Travel = ns.Travel
	local where = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0, [6] = 0 }
	local travel = { foot = 0, mount = 0, flight = 0, ghost = 0 }
	local pauses = { idle = 0, afk = 0, camp = 0, sleep = 0, fish = 0, eat = 0 }
	local kills = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0, [6] = 0 }
	local turnins = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0, [6] = 0 }
	local idleAt = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0, [6] = 0 }
	local buckets = {}
	local whereByLevel = {}
	local recorded = 0
	local unplacedKills = 0
	local counts = { kills = 0, turnins = 0, accepts = 0, deaths = 0 }
	local levelClip = replay.mode == "level" and replay.levelLo and replay.t0 and replay.t1
	local dings = LevelMarks(sessions, Dings(ns.DB.char))
	local groupSpans = GroupSpans(ns.DB.char)
	local zones = {}
	local minLv, maxLv
	local piece
	local dingI = 1
	local dingLevel

	local function zoneRow(mapID)
		mapID = tonumber(mapID)
		if not mapID or mapID <= 0 then
			return nil
		end
		local row = piece.zones[mapID]
		if not row then
			row = { map = mapID, seconds = 0, kills = 0, turnins = 0 }
			piece.zones[mapID] = row
		end
		return row
	end

	local function bump(level, field)
		if type(level) ~= "number" or level <= 0 or level > 200 then
			return
		end
		local row = piece.buckets[level]
		if not row then
			row = EmptyLevel(level)
			piece.buckets[level] = row
		end
		row[field] = row[field] + 1
	end

	-- First ding strictly after t. Dings are sorted.
	local function firstDingPast(t)
		local lo, hi = 1, #dings + 1
		while lo < hi do
			local mid = math.floor((lo + hi) / 2)
			if dings[mid].t > t then
				hi = mid
			else
				lo = mid + 1
			end
		end
		return lo
	end

	local function levelFrom(when, fallback)
		local idx = firstDingPast(when + 1) - 1
		local level = idx >= 1 and dings[idx].lv or nil
		if not level and type(fallback) == "number" and fallback > 0 then
			level = fallback
		end
		return level
	end

	-- Event times only move forward, so the index walks the ding list once.
	local function levelAtForward(when, fallback)
		while dingI <= #dings and dings[dingI].t <= when + 1 do
			dingLevel = dings[dingI].lv
			dingI = dingI + 1
		end
		local level = dingLevel
		if not level and type(fallback) == "number" and fallback > 0 then
			level = fallback
		end
		return level
	end

	local function whereBucket(level)
		if type(level) ~= "number" or level <= 0 or level > 200 then
			return nil
		end
		local row = piece.whereByLevel[level]
		if not row then
			row = {
				lv = level,
				span = 0,
				where = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0, [6] = 0 },
				idleAt = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0, [6] = 0 },
				idle = 0,
			}
			piece.whereByLevel[level] = row
		end
		return row
	end

	-- Split [a, b) on each ding inside it. fn(level, seconds).
	local function eachLevel(a, b, fallback, fn)
		if not a or not b or b <= a then
			return
		end
		local cuts = { a }
		local i = firstDingPast(a)
		while i <= #dings do
			local t = dings[i].t
			if t >= b then
				break
			end
			cuts[#cuts + 1] = t
			i = i + 1
		end
		cuts[#cuts + 1] = b
		for i = 1, #cuts - 1 do
			local level = levelFrom(cuts[i], fallback)
			local seconds = cuts[i + 1] - cuts[i]
			if level and seconds > 0 then
				fn(level, seconds)
			end
		end
	end

	local function blankCounts()
		return { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0, [6] = 0 }
	end

	local function newPiece()
		return {
			where = blankCounts(),
			travel = { foot = 0, mount = 0, flight = 0, ghost = 0 },
			pauses = { idle = 0, afk = 0, camp = 0, sleep = 0, fish = 0, eat = 0 },
			kills = blankCounts(),
			turnins = blankCounts(),
			idleAt = blankCounts(),
			buckets = {},
			whereByLevel = {},
			zones = {},
			recorded = 0,
			unplacedKills = 0,
			counts = { kills = 0, turnins = 0, accepts = 0, deaths = 0 },
		}
	end

	local function addNums(into, src)
		for key, value in pairs(src) do
			into[key] = (into[key] or 0) + value
		end
	end

	local function noteLevel(level)
		if type(level) ~= "number" then
			return
		end
		if not minLv or level < minLv then
			minLv = level
		end
		if not maxLv or level > maxLv then
			maxLv = level
		end
	end

	local function mergePiece(src)
		addNums(where, src.where)
		addNums(travel, src.travel)
		addNums(pauses, src.pauses)
		addNums(kills, src.kills)
		addNums(turnins, src.turnins)
		addNums(idleAt, src.idleAt)
		addNums(counts, src.counts)
		recorded = recorded + (src.recorded or 0)
		unplacedKills = unplacedKills + (src.unplacedKills or 0)
		for level, row in pairs(src.buckets) do
			noteLevel(level)
			local into = buckets[level]
			if not into then
				into = EmptyLevel(level)
				buckets[level] = into
			end
			into.kills = into.kills + row.kills
			into.turnins = into.turnins + row.turnins
			into.deaths = into.deaths + row.deaths
			into.solo = into.solo + row.solo
			into.grouped = into.grouped + row.grouped
			into.normal = into.normal + row.normal
			into.elite = into.elite + row.elite
			into.rare = into.rare + row.rare
		end
		for level, row in pairs(src.whereByLevel) do
			noteLevel(level)
			local into = whereByLevel[level]
			if not into then
				into = {
					lv = level,
					span = 0,
					where = blankCounts(),
					idleAt = blankCounts(),
					idle = 0,
				}
				whereByLevel[level] = into
			end
			into.span = into.span + row.span
			addNums(into.where, row.where)
			addNums(into.idleAt, row.idleAt)
		end
		for _, row in pairs(src.zones) do
			local into = zones[row.map]
			if not into then
				into = { map = row.map, seconds = 0, kills = 0, turnins = 0 }
				zones[row.map] = into
			end
			into.seconds = into.seconds + row.seconds
			into.kills = into.kills + row.kills
			into.turnins = into.turnins + row.turnins
		end
	end

	-- A level selection is the spans of those levels, not one box around all of
	-- them. A second session of the same level must not keep the first session
	-- running into the next level.
	local levelSpans = levelClip and ns.DB:LevelSpans(ns.DB.char) or nil

	local function clipsFor(session)
		local stop = ns.DB:SessionStop(session) or session.s
		if not levelClip then
			if stop > session.s then
				return { { session.s, stop } }
			end
			return {}
		end
		local lo = replay.levelLo
		local hi = replay.levelHi or lo
		local list = {}
		for i = 1, #levelSpans do
			local span = levelSpans[i]
			local top = span.lvTo or span.lv
			if top >= lo and span.lv <= hi then
				local spanStop = ns.DB:SpanStop(span, ns.DB.char)
				local a, b = Overlap(session.s, stop, span.t0, spanStop)
				if a then
					list[#list + 1] = { a, b }
				end
			end
		end
		table.sort(list, function(p, q)
			return p[1] < q[1]
		end)
		local merged = {}
		for i = 1, #list do
			local last = merged[#merged]
			if last and list[i][1] <= last[2] then
				if list[i][2] > last[2] then
					last[2] = list[i][2]
				end
			else
				merged[#merged + 1] = { list[i][1], list[i][2] }
			end
		end
		return merged
	end

	-- Stored company endpoints only. An open span's end is the live clock, and
	-- putting that in the key would throw away every cached session once a second.
	local function groupFingerprint()
		local with = ns.DB.char and ns.DB.char.with
		if type(with) ~= "table" then
			return "-"
		end
		local parts = {}
		for name, spans in pairs(with) do
			if type(spans) == "table" then
				local bits = { tostring(name), tostring(#spans) }
				for i = 1, #spans do
					bits[#bits + 1] = tostring(spans[i])
				end
				parts[#parts + 1] = table.concat(bits, ".")
			end
		end
		table.sort(parts)
		return table.concat(parts, "|")
	end

	local fingerprint = groupFingerprint()

	local function pieceKey(session, index, clips)
		local track = ns.DB:Track(session)
		local bits = {
			tostring(session.id or index),
			tostring(session.seen or 0),
			tostring(#track.t),
			tostring(#(track.ek or {})),
		}
		for i = 1, #clips do
			bits[#bits + 1] = tostring(clips[i][1]) .. "-" .. tostring(clips[i][2])
		end
		bits[#bits + 1] = fingerprint
		return table.concat(bits, "|")
	end

	local function absorb(session, clips)
		piece = newPiece()
		local where = piece.where
		local travel = piece.travel
		local pauses = piece.pauses
		local kills = piece.kills
		local turnins = piece.turnins
		local idleAt = piece.idleAt
		local counts = piece.counts
		local killEvents = 0
		local stop = ns.DB:SessionStop(session) or session.s
		for c = 1, #clips do
			local clip0, clip1 = clips[c][1], clips[c][2]
			if clip1 > clip0 then
				piece.recorded = piece.recorded + (clip1 - clip0)
				eachLevel(clip0, clip1, session.lv, function(level, seconds)
					local row = whereBucket(level)
					if row then
						row.span = row.span + seconds
					end
				end)
				local track = ns.DB:Track(session)
				local modes = track.mode
				if not modes or #modes < #track.t then
					modes = replay:InferModes(track)
				end
				for i = 1, #track.t do
					local sampleT = session.s + (track.t[i] or 0)
					if sampleT >= clip0 and sampleT <= clip1 and i > 1 then
						local mapID = track.m[i]
						if mapID and mapID == track.m[i - 1] then
							local dt = (track.t[i] or 0) - (track.t[i - 1] or 0)
							if dt > 0 and dt <= TRAVEL_GAP then
								local mode = modes[i] or Travel.FOOT
								if mode == Travel.FLIGHT then
									travel.flight = travel.flight + dt
								elseif mode == Travel.MOUNT then
									travel.mount = travel.mount + dt
								elseif mode == Travel.GHOST then
									travel.ghost = travel.ghost + dt
								else
									travel.foot = travel.foot + dt
								end
							end
						end
					end
				end
				-- Idle does not add a sample, so the gap stays on the map you were
				-- in. The travel chart drops those gaps. This one keeps them.
				local function addZoneSeconds(mapID, startT, endT)
					local row = zoneRow(mapID)
					if not row then
						return
					end
					local a, spanEnd = Overlap(startT, endT, clip0, clip1)
					if not a then
						return
					end
					row.seconds = row.seconds + (spanEnd - a)
				end
				local sampleCount = #track.t
				if sampleCount > 0 then
					local firstAt = session.s + (track.t[1] or 0)
					addZoneSeconds(track.m[1], session.s, firstAt)
					for i = 2, sampleCount do
						local prevAt = session.s + (track.t[i - 1] or 0)
						local thisAt = session.s + (track.t[i] or 0)
						addZoneSeconds(track.m[i - 1], prevAt, thisAt)
					end
					local lastAt = session.s + (track.t[sampleCount] or 0)
					addZoneSeconds(track.m[sampleCount], lastAt, stop)
				end
				local sampleAt = 1
				local function mapAt(when)
					local count = #track.t
					if count == 0 then
						return nil
					end
					while sampleAt < count do
						local nextAt = session.s + (track.t[sampleAt + 1] or 0)
						if nextAt > when then
							break
						end
						sampleAt = sampleAt + 1
					end
					return track.m[sampleAt]
				end
				local afkStart, idleStart, idlePlace, campStart, sleepStart, fishStart, eatStart
				local instStart, instType
				local function addPause(field, startT, endT, still)
					local a, b = Overlap(startT, endT, clip0, clip1)
					if not a then
						return
					end
					local seconds = b - a
					if still then
						seconds = replay:RestStillSeconds(track, modes, session.s, a, b)
					end
					if seconds > 0 then
						pauses[field] = pauses[field] + seconds
					end
				end
				local function placeNow()
					return instType or WORLD
				end
				local function addIdle(startT, endT, place)
					local a, b = Overlap(startT, endT, clip0, clip1)
					if not a then
						return
					end
					local seconds = b - a
					if seconds <= 0 then
						return
					end
					pauses.idle = pauses.idle + seconds
					place = place or WORLD
					idleAt[place] = (idleAt[place] or 0) + seconds
					eachLevel(a, b, session.lv, function(level, slice)
						local row = whereBucket(level)
						if row then
							row.idleAt[place] = (row.idleAt[place] or 0) + slice
						end
					end)
				end
				-- Idle can cross a door. Close the span on the place it started in.
				local function splitIdle(when)
					if not idleStart or when <= idleStart then
						return
					end
					addIdle(idleStart, when, idlePlace)
					idleStart = when
				end
				dingI = 1
				dingLevel = nil
				for i = 1, #(track.ek or {}) do
					local kind = track.ek[i]
					local when = session.s + (track.et[i] or 0)
					local extra = track.ea and track.ea[i]
					local inside = when >= clip0 and when <= clip1
					if kind == Kind.INSTANCE_ENTER then
						splitIdle(when)
						instStart = when
						instType = InstanceType(extra)
						idlePlace = placeNow()
					elseif kind == Kind.INSTANCE_LEAVE and instStart and instType then
						splitIdle(when)
						local a, b = Overlap(instStart, when, clip0, clip1)
						if a then
							where[instType] = where[instType] + (b - a)
							eachLevel(a, b, session.lv, function(level, seconds)
								local row = whereBucket(level)
								if row then
									row.where[instType] = row.where[instType] + seconds
								end
							end)
						end
						instStart, instType = nil, nil
						idlePlace = placeNow()
					elseif kind == Kind.AFK_START then
						afkStart = when
					elseif kind == Kind.AFK_END and afkStart then
						addPause("afk", afkStart, when, false)
						afkStart = nil
					elseif kind == Kind.IDLE and (not extra or extra == 0) then
						idleStart = when
						idlePlace = placeNow()
					elseif kind == Kind.IDLE and extra == 1 and idleStart then
						addIdle(idleStart, when, idlePlace)
						idleStart, idlePlace = nil, nil
					elseif kind == Kind.CAMP and (not extra or extra == 0) then
						campStart = when
					elseif kind == Kind.CAMP and extra == 1 and campStart then
						addPause("camp", campStart, when, true)
						campStart = nil
					elseif kind == Kind.SLEEP and (not extra or extra == 0) then
						sleepStart = when
					elseif kind == Kind.SLEEP and extra == 1 and sleepStart then
						addPause("sleep", sleepStart, when, true)
						sleepStart = nil
					elseif kind == Kind.FISH and (not extra or extra == 0) then
						fishStart = when
					elseif kind == Kind.FISH and extra == 1 and fishStart then
						addPause("fish", fishStart, when, false)
						fishStart = nil
					elseif kind == Kind.EAT and (not extra or extra == 0) then
						eatStart = when
					elseif kind == Kind.EAT and extra == 1 and eatStart then
						addPause("eat", eatStart, when, false)
						eatStart = nil
					elseif inside and kind == Kind.KILL then
						killEvents = killEvents + 1
						local place = instType or WORLD
						kills[place] = kills[place] + 1
						counts.kills = counts.kills + 1
						local level = levelAtForward(when, session.lv)
						bump(level, "kills")
						local _, elite, rare = ns.DB:ReadKill(extra)
						if elite then
							bump(level, "elite")
						elseif rare then
							bump(level, "rare")
						else
							bump(level, "normal")
						end
						if GroupedAt(groupSpans, when) then
							bump(level, "grouped")
						else
							bump(level, "solo")
						end
						local mapID = track.em and track.em[i]
						if not mapID or mapID <= 0 then
							mapID = mapAt(when)
						end
						local zone = zoneRow(mapID)
						if zone then
							zone.kills = zone.kills + 1
						end
					elseif inside and kind == Kind.QUEST_TURNIN then
						local place = instType or WORLD
						turnins[place] = turnins[place] + 1
						counts.turnins = counts.turnins + 1
						bump(levelAtForward(when, session.lv), "turnins")
						local mapID = track.em and track.em[i]
						if not mapID or mapID <= 0 then
							mapID = mapAt(when)
						end
						local zone = zoneRow(mapID)
						if zone then
							zone.turnins = zone.turnins + 1
						end
					elseif inside and kind == Kind.QUEST_ACCEPT then
						counts.accepts = counts.accepts + 1
					elseif inside and kind == Kind.DEATH then
						counts.deaths = counts.deaths + 1
						bump(levelAtForward(when, session.lv), "deaths")
					end
				end
				if afkStart then
					addPause("afk", afkStart, stop, false)
				end
				if idleStart then
					addIdle(idleStart, stop, idlePlace)
				end
				if campStart then
					addPause("camp", campStart, stop, true)
				end
				if sleepStart then
					addPause("sleep", sleepStart, stop, true)
				end
				if fishStart then
					addPause("fish", fishStart, stop, false)
				end
				if eatStart then
					addPause("eat", eatStart, stop, false)
				end
				if instStart and instType then
					local a, b = Overlap(instStart, stop, clip0, clip1)
					if a then
						where[instType] = where[instType] + (b - a)
						eachLevel(a, b, session.lv, function(level, seconds)
							local row = whereBucket(level)
							if row then
								row.where[instType] = row.where[instType] + seconds
							end
						end)
					end
				end
			end
		end
		if not levelClip then
			local missing = (session.kills or 0) - killEvents
			if missing > 0 then
				piece.unplacedKills = missing
				counts.kills = counts.kills + missing
			end
		end
		return piece
	end

	self.pieces = self.pieces or {}
	local gen = (self.pieceGen or 0) + 1
	self.pieceGen = gen
	for s = 1, #sessions do
		local session = sessions[s]
		local clips = clipsFor(session)
		if #clips > 0 then
			local key = pieceKey(session, s, clips)
			local entry = self.pieces[key]
			local built
			if entry then
				entry.gen = gen
				built = entry.piece
			else
				built = absorb(session, clips)
				self.pieces[key] = { piece = built, gen = gen }
			end
			mergePiece(built)
		end
	end
	for key, entry in pairs(self.pieces) do
		if entry.gen ~= gen then
			self.pieces[key] = nil
		end
	end
	local inside = 0
	for key = ns.Instance.PARTY, ns.Instance.OTHER do
		inside = inside + (where[key] or 0)
	end
	local world = recorded - inside
	if world < 0 then
		world = 0
	end
	where[WORLD] = world
	local idleShown = 0
	local function takeIdle(key)
		local cut = idleAt[key] or 0
		local have = where[key] or 0
		if cut > have then
			cut = have
		end
		if cut > 0 then
			where[key] = have - cut
			idleShown = idleShown + cut
		end
	end
	takeIdle(WORLD)
	for key = ns.Instance.PARTY, ns.Instance.OTHER do
		takeIdle(key)
	end
	for _, row in pairs(whereByLevel) do
		local inside = 0
		for key = ns.Instance.PARTY, ns.Instance.OTHER do
			inside = inside + (row.where[key] or 0)
		end
		local world = row.span - inside
		if world < 0 then
			world = 0
		end
		row.where[WORLD] = world
		local shown = 0
		local function take(key)
			local cut = row.idleAt[key] or 0
			local have = row.where[key] or 0
			if cut > have then
				cut = have
			end
			if cut > 0 then
				row.where[key] = have - cut
				shown = shown + cut
			end
		end
		take(WORLD)
		for key = ns.Instance.PARTY, ns.Instance.OTHER do
			take(key)
		end
		row.idle = shown
	end
	local function withWhere(row)
		local src = whereByLevel[row.lv]
		if src then
			row.where = src.where
			row.idle = src.idle or 0
		else
			row.where = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 0, [5] = 0, [6] = 0 }
			row.idle = 0
		end
		return row
	end
	local levels = {}
	if minLv and maxLv and (maxLv - minLv) <= 100 then
		for level = minLv, maxLv do
			levels[#levels + 1] = withWhere(buckets[level] or EmptyLevel(level))
		end
	elseif minLv then
		local seen = {}
		for level, row in pairs(buckets) do
			seen[level] = row
		end
		for level in pairs(whereByLevel) do
			if not seen[level] then
				seen[level] = EmptyLevel(level)
			end
		end
		for _, row in pairs(seen) do
			levels[#levels + 1] = withWhere(row)
		end
		table.sort(levels, function(a, b)
			return a.lv < b.lv
		end)
	end
	local zoneList = {}
	for _, row in pairs(zones) do
		zoneList[#zoneList + 1] = row
	end
	table.sort(zoneList, function(a, b)
		if a.seconds ~= b.seconds then
			return a.seconds > b.seconds
		end
		if a.kills ~= b.kills then
			return a.kills > b.kills
		end
		return a.map < b.map
	end)
	return {
		where = where,
		travel = travel,
		pauses = pauses,
		kills = kills,
		turnins = turnins,
		levels = levels,
		zones = zoneList,
		unplacedKills = unplacedKills,
		recorded = recorded,
		idle = idleShown,
		counts = counts,
	}
end

function ns.Viz:DrawToken()
	local chart = self:Chart()
	local width = 0
	if self.scroll then
		width = math.floor((self.scroll:GetWidth() or 0) + 0.5)
	end
	return (self.chartId or "") .. ":" .. (chart and chart.display or "") .. ":" .. tostring(width)
end

function ns.Viz:Refresh(sessions)
	if not self.pane or ns.Replay.pane ~= "charts" then
		return
	end
	sessions = sessions or ns.Replay.sessions or {}
	local key = ns.Replay:StatsKey(sessions)
	local token = self:DrawToken()
	if key == self.summaryKey and self.summary and token == self.drawKey then
		return
	end
	if key ~= self.summaryKey or not self.summary then
		self.summary = self:Summarize(ns.Replay, sessions)
		self.summaryKey = key
	end
	self:Draw()
end

local function PaintToggle(button, active)
	if not button or not button.SetBackdropBorderColor then
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
	if active then
		button:SetBackdropBorderColor(0.85, 0.68, 0.28, 1)
		button:SetBackdropColor(0.20, 0.16, 0.08, 1)
	else
		button:SetBackdropBorderColor(0.38, 0.32, 0.16, 0.9)
		button:SetBackdropColor(0.12, 0.11, 0.10, 1)
	end
end

function ns.Viz:StyleTabs()
	local tabs = self.sideTabs
	if not tabs then
		return
	end
	for i = 1, #tabs do
		local tab = tabs[i]
		PaintToggle(tab, tab.tabId == self.chartId)
	end
end

function ns.Viz:PlaceTabs()
	local menu = self.menu
	local tabs = self.sideTabs
	if not menu or not tabs then
		return
	end
	local width = menu:GetWidth() or 0
	if width < 40 then
		width = 152
	end
	local y = 0
	for i = 1, #tabs do
		local tab = tabs[i]
		if tab:IsShown() then
			tab:ClearAllPoints()
			tab:SetPoint("TOPLEFT", menu, "TOPLEFT", 0, y)
			tab:SetSize(width, 26)
			y = y - 30
		end
	end
	self:StyleTabs()
end

function ns.Viz:Select(id)
	self.chartId = id
	if not ns.Replay.expanded then
		ns.Replay:SetExpanded(true)
	elseif self.pane and self.pane:IsShown() then
		self:Draw()
	end
	self:StyleTabs()
end

function ns.Viz:HidePane()
	if self.pane then
		self.pane:Hide()
	end
end

function ns.Viz:LayoutBody()
	local pane = self.pane
	local menu = self.menu
	local host = self.chartHost
	if not pane or not menu or not host then
		return
	end
	menu:ClearAllPoints()
	menu:SetPoint("TOPLEFT", 8, -8)
	menu:SetPoint("BOTTOMLEFT", 8, 8)
	menu:SetWidth(168)
	host:ClearAllPoints()
	host:SetPoint("TOPLEFT", menu, "TOPRIGHT", 8, 0)
	host:SetPoint("BOTTOMRIGHT", -6, 8)
	if self.menuRule then
		self.menuRule:ClearAllPoints()
		self.menuRule:SetPoint("TOPLEFT", menu, "TOPRIGHT", 4, 0)
		self.menuRule:SetPoint("BOTTOMLEFT", menu, "BOTTOMRIGHT", 4, 0)
		self.menuRule:SetWidth(1)
		self.menuRule:Show()
	end
	self:PlaceTabs()
end

function ns.Viz:PlaceBox(left, top, right, bottom)
	if not self.pane then
		return
	end
	self.pane:ClearAllPoints()
	self.pane:SetPoint("TOPLEFT", left, -top)
	self.pane:SetPoint("BOTTOMRIGHT", -right, bottom)
	self.pane:Show()
	self:LayoutBody()
	if self.summary then
		self:Draw()
	end
end

function ns.Viz:Begin()
	self.barN = 0
	self.fontN = 0
	for i = 1, #(self.bars or {}) do
		self.bars[i]:Hide()
	end
	for i = 1, #(self.fonts or {}) do
		self.fonts[i]:Hide()
	end
end

function ns.Viz:Bar()
	self.bars = self.bars or {}
	local bar = self.bars[(self.barN or 0) + 1]
	if not bar then
		bar = self.content:CreateTexture(nil, "ARTWORK")
		bar:SetTexture("Interface\\Buttons\\WHITE8X8")
		self.bars[#self.bars + 1] = bar
	end
	self.barN = (self.barN or 0) + 1
	bar:ClearAllPoints()
	-- The pie rotates its spokes. The next chart reuses this texture, and a
	-- leftover angle turns a row bar on its side and lets it paint over the note.
	bar:SetRotation(0)
	bar:Show()
	return bar
end

function ns.Viz:Font()
	self.fonts = self.fonts or {}
	local font = self.fonts[(self.fontN or 0) + 1]
	if not font then
		font = self.content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		self.fonts[#self.fonts + 1] = font
	end
	self.fontN = (self.fontN or 0) + 1
	font:ClearAllPoints()
	font:SetJustifyH("LEFT")
	font:SetJustifyV("TOP")
	font:SetWordWrap(false)
	font:SetTextColor(0.93, 0.90, 0.78)
	local width = self:Width()
	if width < 40 then
		width = 400
	end
	font:SetWidth(width)
	font:Show()
	return font
end

function ns.Viz:ContentHeight(height)
	if not height or height < 1 then
		height = 1
	end
	local width = self.scroll and self.scroll:GetWidth() or 0
	if width > 40 then
		self.content:SetWidth(width)
	end
	self.content:SetHeight(height)
end

function ns.Viz:Empty(text)
	local font = self:Font()
	font:SetPoint("TOPLEFT", 0, -4)
	font:SetPoint("RIGHT", self.content, "RIGHT", 0, 0)
	font:SetWordWrap(true)
	font:SetJustifyH("LEFT")
	font:SetTextColor(0.62, 0.60, 0.54)
	font:SetText(text or L["Nothing in this selection yet."])
	self:ContentHeight(36)
end

function ns.Viz:Width()
	local width = self.content:GetWidth() or 0
	if width < 40 and self.scroll then
		width = self.scroll:GetWidth() or 0
	end
	if width > 40 then
		self.content:SetWidth(width)
	end
	return width
end

function ns.Viz:Draw()
	if not self.content or not self.pane or not self.pane:IsShown() then
		return
	end
	local chart = self:Chart()
	if not chart then
		return
	end
	if self:Width() < 40 then
		return
	end
	self.drawKey = self:DrawToken()
	self.title:SetText(chart.title)
	self.note:SetText(chart.note or "")
	self:PlaceDisplays(chart)
	self:Begin()
	if not self.summary then
		self:Empty()
		return
	end
	local model = chart.Build(self.summary)
	if type(model) ~= "table" then
		self:Empty()
		self:StyleTabs()
		return
	end
	if model.empty then
		if type(model.empty) == "string" then
			self:Empty(model.empty)
		else
			self:Empty()
		end
		self:StyleTabs()
		return
	end
	local display = displays[chart.display]
	if not display then
		self:Empty()
		self:StyleTabs()
		return
	end
	display.Draw(self, model)
	self:StyleTabs()
end

local function MakeToggle(parent, text, width)
	local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
	button:SetSize(width, 22)
	button:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	local label = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("LEFT", 8, 0)
	label:SetPoint("RIGHT", -6, 0)
	label:SetJustifyH("LEFT")
	label:SetWordWrap(false)
	label:SetText(text)
	button:SetFontString(label)
	return button
end

local function PlaceScroll(viz, top)
	viz.scroll:ClearAllPoints()
	viz.scroll:SetPoint("TOPLEFT", 8, -top)
	viz.scroll:SetPoint("BOTTOMRIGHT", -26, 6)
end

function ns.Viz:PlaceDisplays(chart)
	self.displayButtons = self.displayButtons or {}
	local allowed = chart and chart.displays
	local count = 0
	if type(allowed) == "table" then
		count = #allowed
	end
	if count < 2 or not self.chartHost or not self.scroll then
		for i = 1, #self.displayButtons do
			self.displayButtons[i]:Hide()
		end
		if self.scroll then
			PlaceScroll(self, 62)
		end
		return
	end
	local x = 10
	for i = 1, count do
		local id = allowed[i]
		local display = displays[id]
		local button = self.displayButtons[i]
		if not button then
			button = MakeToggle(self.chartHost, "", 44)
			button:SetFrameLevel(self.chartHost:GetFrameLevel() + 4)
			button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			button:SetScript("OnClick", function(self)
				ns.Viz:SetDisplay(ns.Viz.chartId, self.displayId)
			end)
			local font = button:GetFontString()
			if font then
				font:SetJustifyH("CENTER")
			end
			self.displayButtons[i] = button
		end
		local text = id
		if display and display.label then
			text = display.label
		end
		button.displayId = id
		button:SetText(text)
		local width = (#text * 6) + 18
		if width < 44 then
			width = 44
		end
		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", self.chartHost, "TOPLEFT", x, -60)
		button:SetSize(width, 22)
		PaintToggle(button, chart.display == id)
		button:Show()
		x = x + width + 6
	end
	for i = count + 1, #self.displayButtons do
		self.displayButtons[i]:Hide()
	end
	PlaceScroll(self, 88)
end

local function MakeTab(parent, text, id, tipTitle, tipBody)
	local button = MakeToggle(parent, text, 152)
	button.tabId = id
	button.tipTitle = tipTitle
	button.tipBody = tipBody
	button:SetFrameLevel(parent:GetFrameLevel() + 16)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:SetScript("OnClick", function(self)
		ns.Viz:Select(self.tabId)
	end)
	button:SetScript("OnEnter", function(self)
		if not GameTooltip then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(self.tipTitle or "", 1, 0.86, 0.45)
		if self.tipBody and self.tipBody ~= "" then
			GameTooltip:AddLine(self.tipBody, 0.78, 0.76, 0.70, true)
		end
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function(self)
		if GameTooltip and GameTooltip:IsOwned(self) then
			GameTooltip:Hide()
		end
	end)
	return button
end

function ns.Viz:BuildTabs()
	local frame = ns.Replay.frame
	if not frame then
		return
	end
	local parent = self.menu or ns.Replay.frame
	if not parent then
		return
	end
	self.sideTabs = self.sideTabs or {}
	local specs = {}
	for i = 1, #charts do
		local chart = charts[i]
		specs[#specs + 1] = {
			id = chart.id,
			label = chart.label,
			title = chart.title,
			body = chart.note,
		}
	end
	for i = 1, #specs do
		local spec = specs[i]
		local tab = self.sideTabs[i]
		if not tab then
			tab = MakeTab(parent, spec.title, spec.id, spec.title, spec.body)
			self.sideTabs[i] = tab
		end
		tab.tabId = spec.id
		tab.tipTitle = spec.title
		tab.tipBody = spec.body
		tab:SetText(spec.title)
		tab:Show()
	end
	for i = #specs + 1, #self.sideTabs do
		self.sideTabs[i]:Hide()
	end
	self:PlaceTabs()
end

function ns.Viz:Attach(replay)
	if self.pane or not replay.frame then
		return
	end
	local frame = replay.frame
	local pane = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	-- Above the playback layer, under the resize grip and the Charts handle.
	pane:SetFrameLevel(frame:GetFrameLevel() + 12)
	pane:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	pane:SetBackdropColor(0, 0, 0, 0.35)
	pane:SetBackdropBorderColor(0.35, 0.30, 0.16, 0.85)
	pane:Hide()

	local menu = CreateFrame("Frame", nil, pane)
	menu:SetWidth(168)
	local rule = pane:CreateTexture(nil, "BORDER")
	rule:SetColorTexture(0.85, 0.68, 0.28, 0.75)
	rule:Hide()
	local host = CreateFrame("Frame", nil, pane)

	local title = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	title:SetPoint("TOPLEFT", 10, -8)
	title:SetPoint("RIGHT", host, "RIGHT", -10, 0)
	title:SetJustifyH("LEFT")
	title:SetWordWrap(false)
	title:SetTextColor(1, 0.86, 0.45)

	local note = host:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	note:SetPoint("TOPLEFT", 10, -26)
	note:SetPoint("RIGHT", host, "RIGHT", -10, 0)
	note:SetHeight(32)
	note:SetJustifyH("LEFT")
	note:SetJustifyV("TOP")
	note:SetWordWrap(true)
	note:SetTextColor(0.62, 0.60, 0.54)

	local scroll = CreateFrame("ScrollFrame", "ZipperVizScroll", host, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 8, -62)
	scroll:SetPoint("BOTTOMRIGHT", -26, 6)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(240, 40)
	scroll:SetScrollChild(content)

	self.pane = pane
	self.menu = menu
	self.menuRule = rule
	self.chartHost = host
	self.title = title
	self.note = note
	self.scroll = scroll
	self.content = content
	pane:SetScript("OnSizeChanged", function()
		ns.Viz:LayoutBody()
		if ns.Replay.expanded and ns.Viz.pane and ns.Viz.pane:IsShown() then
			ns.Viz:Draw()
		end
	end)
	self:BuildTabs()
end

