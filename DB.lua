local _, ns = ...

ns.DB = {}

local function EmptyTrack()
	return {
		t = {},
		m = {},
		x = {},
		y = {},
		et = {},
		ek = {},
		em = {},
		ex = {},
		ey = {},
		ea = {},
		mode = {},
		spd = {},
	}
end

local function EnsureTrack(track)
	track.t = track.t or {}
	track.m = track.m or {}
	track.x = track.x or {}
	track.y = track.y or {}
	track.et = track.et or {}
	track.ek = track.ek or {}
	track.em = track.em or {}
	track.ex = track.ex or {}
	track.ey = track.ey or {}
	track.ea = track.ea or {}
	track.mode = track.mode or {}
	track.spd = track.spd or {}
	return track
end

local function Usable(session)
	return type(session) == "table" and type(session.id) == "number" and type(session.s) == "number"
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

local function StripKills(track)
	local et, ek, em, ex, ey, ea = {}, {}, {}, {}, {}, {}
	local kept = 0
	local kills = 0
	for i = 1, #track.ek do
		if track.ek[i] == ns.Kind.KILL then
			kills = kills + 1
		else
			kept = kept + 1
			et[kept] = track.et[i]
			ek[kept] = track.ek[i]
			em[kept] = track.em[i]
			ex[kept] = track.ex[i]
			ey[kept] = track.ey[i]
			ea[kept] = track.ea[i]
		end
	end
	track.et, track.ek, track.em = et, ek, em
	track.ex, track.ey, track.ea = ex, ey, ea
	return kills
end

local function CountQuests(track)
	local quests = 0
	for i = 1, #track.ek do
		if track.ek[i] == ns.Kind.QUEST_TURNIN then
			quests = quests + 1
		end
	end
	return quests
end

function ns.DB:Migrate(db)
	local old = db.sessions
	local sessions, tracks = {}, {}
	local nextId = 1
	if type(old) == "table" then
		for i = 1, #old do
			local item = old[i]
			if type(item) == "table" and type(item.s) == "number" then
				local id = nextId
				nextId = nextId + 1
				local track = EmptyTrack()
				if type(item.t) == "table" then
					track.t = item.t
					track.m = item.m or {}
					track.x = item.x or {}
					track.y = item.y or {}
					track.et = item.et or {}
					track.ek = item.ek or {}
					track.em = item.em or {}
					track.ex = item.ex or {}
					track.ey = item.ey or {}
					track.ea = item.ea or {}
				end
				EnsureTrack(track)
				local kills = StripKills(track)
				local function num(value)
					if type(value) == "number" then
						return value
					end
					return nil
				end
				sessions[#sessions + 1] = {
					id = id,
					s = item.s,
					seen = item.seen or item.s,
					kills = item.kills or kills,
					quests = item.quests or CountQuests(track),
					lv = num(item.lv),
					xp = num(item.xp),
					xm = num(item.xm),
					el = num(item.el),
					ex = num(item.ex),
					em = num(item.em),
				}
				tracks[id] = track
			end
		end
	end
	db.sessions = sessions
	db.tracks = tracks
	db.nextId = nextId
	db.version = 2
end

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function PushVar(buf, n)
	n = math.floor(n or 0)
	if n < 0 then
		n = 0
	end
	repeat
		local byte = n % 128
		n = math.floor(n / 128)
		if n > 0 then
			byte = byte + 128
		end
		buf[#buf + 1] = byte
	until n == 0
end

local function ReadVar(bytes, index)
	local value, shift = 0, 0
	while index <= #bytes do
		local byte = bytes:byte(index)
		index = index + 1
		value = value + (byte % 128) * (2 ^ shift)
		if byte < 128 then
			return value, index
		end
		shift = shift + 7
		if shift > 28 then
			break
		end
	end
	return value, index
end

local function Zig(n)
	n = math.floor(n or 0)
	if n >= 0 then
		return n * 2
	end
	return (-n * 2) - 1
end

local function Unzig(n)
	if n % 2 == 0 then
		return n / 2
	end
	return -((n + 1) / 2)
end

local function Encode64(raw)
	local out = {}
	local length = #raw
	local i = 1
	while i <= length do
		local a = raw:byte(i) or 0
		local b = raw:byte(i + 1) or 0
		local c = raw:byte(i + 2) or 0
		local chunk = a * 65536 + b * 256 + c
		out[#out + 1] = B64:sub(math.floor(chunk / 262144) % 64 + 1, math.floor(chunk / 262144) % 64 + 1)
		out[#out + 1] = B64:sub(math.floor(chunk / 4096) % 64 + 1, math.floor(chunk / 4096) % 64 + 1)
		if i + 1 <= length then
			out[#out + 1] = B64:sub(math.floor(chunk / 64) % 64 + 1, math.floor(chunk / 64) % 64 + 1)
		else
			out[#out + 1] = "="
		end
		if i + 2 <= length then
			out[#out + 1] = B64:sub(chunk % 64 + 1, chunk % 64 + 1)
		else
			out[#out + 1] = "="
		end
		i = i + 3
	end
	return table.concat(out)
end

local function Decode64(text)
	local map = {}
	for i = 1, #B64 do
		map[B64:sub(i, i)] = i - 1
	end
	local out = {}
	text = (text or ""):gsub("%s", "")
	local i = 1
	while i <= #text do
		local a = map[text:sub(i, i)] or 0
		local b = map[text:sub(i + 1, i + 1)] or 0
		local c = text:sub(i + 2, i + 2)
		local d = text:sub(i + 3, i + 3)
		local cc = c == "=" and 0 or (map[c] or 0)
		local dd = d == "=" and 0 or (map[d] or 0)
		local chunk = a * 262144 + b * 4096 + cc * 64 + dd
		out[#out + 1] = string.char(math.floor(chunk / 65536) % 256)
		if c ~= "=" then
			out[#out + 1] = string.char(math.floor(chunk / 256) % 256)
		end
		if d ~= "=" then
			out[#out + 1] = string.char(chunk % 256)
		end
		i = i + 4
	end
	return table.concat(out)
end

local function PackRuns(buf, values, count, nilCode)
	local index = 1
	while index <= count do
		local value = values[index]
		if value == nil then
			value = nilCode
		end
		local nextIndex = index + 1
		while nextIndex <= count do
			local other = values[nextIndex]
			if other == nil then
				other = nilCode
			end
			if other ~= value then
				break
			end
			nextIndex = nextIndex + 1
		end
		PushVar(buf, nextIndex - index)
		PushVar(buf, value)
		index = nextIndex
	end
	PushVar(buf, 0)
end

local function UnpackRuns(bytes, index, count, nilCode)
	local values = {}
	local filled = 0
	local ended = false
	while filled < count do
		local run, value
		run, index = ReadVar(bytes, index)
		if not run or run <= 0 then
			ended = true
			break
		end
		value, index = ReadVar(bytes, index)
		if value == nilCode then
			value = nil
		end
		for _ = 1, run do
			filled = filled + 1
			if filled <= count then
				values[filled] = value
			end
		end
	end
	if not ended then
		local _
		_, index = ReadVar(bytes, index)
	end
	return values, index
end

function ns.DB:PackTrack(track)
	track = EnsureTrack(track or EmptyTrack())
	local count = #track.t
	local events = #track.ek
	local buf = { string.byte("Z"), string.byte("3") }
	PushVar(buf, count)
	PushVar(buf, events)
	local previous = 0
	for i = 1, count do
		local value = track.t[i] or 0
		PushVar(buf, math.max(0, value - previous))
		previous = value
	end
	previous = 0
	for i = 1, count do
		local value = track.m[i] or 0
		PushVar(buf, Zig(value - previous))
		previous = value
	end
	previous = 0
	for i = 1, count do
		local value = track.x[i] or 0
		PushVar(buf, Zig(value - previous))
		previous = value
	end
	previous = 0
	for i = 1, count do
		local value = track.y[i] or 0
		PushVar(buf, Zig(value - previous))
		previous = value
	end
	PackRuns(buf, track.mode, count, 255)
	PackRuns(buf, track.spd, count, 0)
	previous = 0
	for i = 1, events do
		local value = track.et[i] or 0
		PushVar(buf, math.max(0, value - previous))
		previous = value
		PushVar(buf, track.ek[i] or 0)
		PushVar(buf, Zig(track.em[i] or 0))
		PushVar(buf, Zig(track.ex[i] or 0))
		PushVar(buf, Zig(track.ey[i] or 0))
		PushVar(buf, Zig(track.ea[i] or 0))
	end
	local raw = {}
	for i = 1, #buf do
		raw[i] = string.char(buf[i])
	end
	return "Z3:" .. Encode64(table.concat(raw))
end

function ns.DB:UnpackTrack(packed)
	if type(packed) ~= "string" or packed:sub(1, 3) ~= "Z3:" then
		return EnsureTrack(type(packed) == "table" and packed or EmptyTrack())
	end
	local bytes = Decode64(packed:sub(4))
	if bytes:byte(1) ~= string.byte("Z") or bytes:byte(2) ~= string.byte("3") then
		return EmptyTrack()
	end
	local index = 3
	local count, events
	count, index = ReadVar(bytes, index)
	events, index = ReadVar(bytes, index)
	local track = EmptyTrack()
	local previous = 0
	for i = 1, count do
		local delta
		delta, index = ReadVar(bytes, index)
		previous = previous + delta
		track.t[i] = previous
	end
	previous = 0
	for i = 1, count do
		local delta
		delta, index = ReadVar(bytes, index)
		previous = previous + Unzig(delta)
		track.m[i] = previous
	end
	previous = 0
	for i = 1, count do
		local delta
		delta, index = ReadVar(bytes, index)
		previous = previous + Unzig(delta)
		track.x[i] = previous
	end
	previous = 0
	for i = 1, count do
		local delta
		delta, index = ReadVar(bytes, index)
		previous = previous + Unzig(delta)
		track.y[i] = previous
	end
	track.mode, index = UnpackRuns(bytes, index, count, 255)
	track.spd, index = UnpackRuns(bytes, index, count, 0)
	previous = 0
	for i = 1, events do
		local delta, kind, mapID, x, y, extra
		delta, index = ReadVar(bytes, index)
		previous = previous + delta
		track.et[i] = previous
		kind, index = ReadVar(bytes, index)
		track.ek[i] = kind
		mapID, index = ReadVar(bytes, index)
		track.em[i] = Unzig(mapID)
		x, index = ReadVar(bytes, index)
		track.ex[i] = Unzig(x)
		y, index = ReadVar(bytes, index)
		track.ey[i] = Unzig(y)
		extra, index = ReadVar(bytes, index)
		track.ea[i] = Unzig(extra)
	end
	return track
end

function ns.DB:NewJourney(name, realm)
	return {
		name = name or "Character",
		realm = realm or "",
		version = 3,
		nextId = 1,
		sessions = {},
		tracks = {},
	}
end

function ns.DB:JourneyLabel(journey)
	if type(journey) ~= "table" then
		return "Character"
	end
	if journey.realm and journey.realm ~= "" then
		return (journey.name or "Character") .. "-" .. journey.realm
	end
	return journey.name or "Character"
end

function ns.DB:EnsureStore()
	ZipperDB = ZipperDB or {}
	if type(ZipperDB.journeys) ~= "table" then
		ZipperDB.journeys = {}
	end
end

function ns.DB:CopyLegacy(source, journey)
	if type(source) ~= "table" then
		return false
	end
	if source.version ~= 2 or type(source.tracks) ~= "table" then
		self:Migrate(source)
	end
	if type(source.sessions) ~= "table" or #source.sessions == 0 then
		return false
	end
	journey.sessions = {}
	journey.tracks = {}
	journey.nextId = source.nextId or (#source.sessions + 1)
	for i = 1, #source.sessions do
		local session = source.sessions[i]
		if Usable(session) then
			local copy = {}
			for key, value in pairs(session) do
				if type(value) ~= "table" then
					copy[key] = value
				end
			end
			journey.sessions[#journey.sessions + 1] = copy
			local track = source.tracks[session.id]
			if type(track) == "table" then
				local copied = EmptyTrack()
				for _, field in ipairs({ "t", "m", "x", "y", "et", "ek", "em", "ex", "ey", "ea", "mode", "spd" }) do
					local list = track[field]
					if type(list) == "table" then
						for n = 1, #list do
							copied[field][n] = list[n]
						end
					end
				end
				journey.tracks[session.id] = copied
			end
		end
	end
	if type(source.sizeLog) == "table" then
		journey.sizeLog = source.sizeLog
	end
	return #journey.sessions > 0
end

function ns.DB:BindPlayer()
	self:EnsureStore()
	local guid = UnitGUID and UnitGUID("player") or nil
	if type(guid) ~= "string" or guid == "" then
		return false
	end
	local name = UnitName and UnitName("player") or nil
	if type(name) ~= "string" or name == "" then
		name = "Character"
	end
	local realm = GetRealmName and GetRealmName() or ""
	if type(realm) ~= "string" then
		realm = ""
	end
	local journey = ZipperDB.journeys[guid]
	if type(journey) ~= "table" then
		journey = self:NewJourney(name, realm)
		ZipperDB.journeys[guid] = journey
	end
	journey.name = name
	journey.realm = realm
	if type(journey.sessions) ~= "table" then
		journey.sessions = {}
	end
	if type(journey.tracks) ~= "table" then
		journey.tracks = {}
	end
	if type(journey.nextId) ~= "number" then
		journey.nextId = #journey.sessions + 1
	end
	if #journey.sessions == 0 and type(ZipperCharDB) == "table" and not ZipperCharDB.imported then
		self:CopyLegacy(ZipperCharDB, journey)
	end
	self.playerKey = guid
	self.record = journey
	if not self.viewKey or not ZipperDB.journeys[self.viewKey] then
		self.viewKey = guid
		self.char = journey
	end
	return true
end

function ns.DB:SetView(key)
	self:EnsureStore()
	local journey = ZipperDB.journeys[key]
	if type(journey) ~= "table" then
		return false
	end
	self.viewKey = key
	self.char = journey
	return true
end

function ns.DB:CharacterList()
	self:EnsureStore()
	local list = {}
	for key, journey in pairs(ZipperDB.journeys) do
		if type(journey) == "table" then
			list[#list + 1] = {
				key = key,
				label = self:JourneyLabel(journey),
				sessions = type(journey.sessions) == "table" and #journey.sessions or 0,
				bytes = self:JourneyBytes(journey),
				current = key == self.playerKey,
			}
		end
	end
	table.sort(list, function(a, b)
		if a.current ~= b.current then
			return a.current
		end
		return a.label < b.label
	end)
	return list
end

function ns.DB:Init()
	self:EnsureStore()
	self.session = nil
end

function ns.DB:HostFor(session)
	local function owns(journey)
		if type(journey) ~= "table" or type(journey.sessions) ~= "table" or not session then
			return false
		end
		for i = 1, #journey.sessions do
			if journey.sessions[i] == session then
				return true
			end
		end
		return false
	end
	if owns(self.record) then
		return self.record
	end
	if owns(self.char) then
		return self.char
	end
	return self.record or self.char
end

function ns.DB:Flush()
	self:EnsureStore()
	for _, journey in pairs(ZipperDB.journeys) do
		if type(journey) == "table" and type(journey.tracks) == "table" then
			for id, track in pairs(journey.tracks) do
				if type(track) == "table" then
					journey.tracks[id] = self:PackTrack(track)
				end
			end
			journey.bytes = self:MeasureJourney(journey)
		end
	end
end

function ns.DB:Now()
	return GetServerTime()
end

function ns.DB:PackCoord(value)
	local n = math.floor((value * ns.COORD_SCALE) + 0.5)
	if n < 0 then
		return 0
	end
	if n > ns.COORD_SCALE then
		return ns.COORD_SCALE
	end
	return n
end

function ns.DB:Current()
	return self.session
end

function ns.DB:Sessions()
	return self.char and self.char.sessions or {}
end

function ns.DB:Track(session)
	local host = self:HostFor(session)
	if not session or not host then
		return EmptyTrack()
	end
	if type(host.tracks) ~= "table" then
		host.tracks = {}
	end
	local track = host.tracks[session.id]
	if type(track) == "string" then
		track = self:UnpackTrack(track)
		host.tracks[session.id] = track
	elseif type(track) ~= "table" then
		track = EmptyTrack()
		host.tracks[session.id] = track
	end
	return EnsureTrack(track)
end

function ns.DB:NoteProgress()
	local session = self.session
	if not session then
		return
	end
	local level = UnitLevel("player")
	local xp = UnitXP("player")
	local maxXP = UnitXPMax("player")
	if type(level) ~= "number" or level <= 0 then
		return
	end
	if type(xp) ~= "number" then
		xp = 0
	end
	if type(maxXP) ~= "number" then
		maxXP = 0
	end
	if session.lv == nil then
		session.lv = level
		session.xp = xp
		session.xm = maxXP
	end
	session.el = level
	session.ex = xp
	session.em = maxXP
end

function ns.DB:LevelsGained(session)
	if type(session) ~= "table" or type(session.lv) ~= "number" or type(session.el) ~= "number" then
		return 0
	end
	local startFrac = 0
	if type(session.xm) == "number" and session.xm > 0 then
		startFrac = (session.xp or 0) / session.xm
	end
	local endFrac = 0
	if type(session.em) == "number" and session.em > 0 then
		endFrac = (session.ex or 0) / session.em
	end
	local gained = (session.el - session.lv) + (endFrac - startFrac)
	if gained < 0 then
		return 0
	end
	return gained
end

function ns.DB:RecapNumbers(sessions)
	local kills, quests, levels = 0, 0, 0
	for i = 1, #sessions do
		local session = sessions[i]
		kills = kills + (session.kills or 0)
		quests = quests + (session.quests or 0)
		levels = levels + self:LevelsGained(session)
	end
	return kills, quests, levels
end

function ns.DB:RecapText(sessions)
	local kills, quests, levels = self:RecapNumbers(sessions or {})
	local enemy = (kills == 1) and "enemy" or "enemies"
	local quest = (quests == 1) and "quest" or "quests"
	local levelText
	if math.abs(levels - 1) < 0.005 then
		levelText = "1 level"
	else
		levelText = string.format("%.2f levels", levels)
	end
	return string.format("You killed %s %s, finished %s %s, and gained %s.", Comma(kills), enemy, Comma(quests), quest, levelText)
end

function ns.DB:Open(now, forceNew)
	if not self.record then
		self:BindPlayer()
	end
	local host = self.record
	if not host then
		return nil, false
	end
	if self.session and not forceNew then
		self.session.seen = now
		self:NoteProgress()
		return self.session, true
	end

	local sessions = host.sessions
	local last = sessions[#sessions]
	if not forceNew and Usable(last) and type(last.seen) == "number" then
		local gap = now - last.seen
		if gap >= 0 and gap <= ns.CONTINUE_SECONDS then
			self.session = last
			self:Track(last)
			last.seen = now
			self:NoteProgress()
			return last, true
		end
	end

	local id = host.nextId or 1
	host.nextId = id + 1
	local session = {
		id = id,
		s = now,
		seen = now,
		kills = 0,
		quests = 0,
	}
	sessions[#sessions + 1] = session
	host.tracks[id] = EmptyTrack()
	self.session = session
	self:NoteProgress()
	return session, false
end

function ns.DB:Touch(now)
	if self.session then
		self.session.seen = now
	end
end

function ns.DB:AddKill()
	if not ns.Config:WantsKind(ns.Kind.KILL) then
		return
	end
	local session = self.session
	if not session then
		return
	end
	session.kills = (session.kills or 0) + 1
	session.seen = self:Now()
end

function ns.DB:AddSample(mapID, x, y, now, mode, speed)
	if not ns.Config:Enabled("path") then
		return false
	end
	local session = self.session
	if not session then
		return false
	end
	local track = self:Track(session)
	if #track.t >= ns.SAMPLE_CAP then
		self:Open(now, true)
		session = self.session
		track = self:Track(session)
	end

	local px = self:PackCoord(x)
	local py = self:PackCoord(y)
	local n = #track.t
	if n > 0 and track.m[n] == mapID and track.x[n] == px and track.y[n] == py then
		session.seen = now
		return false
	end

	local offset = now - session.s
	if offset < 0 then
		offset = 0
	end
	n = n + 1
	track.t[n] = math.floor(offset)
	track.m[n] = mapID
	track.x[n] = px
	track.y[n] = py
	track.mode[n] = mode or ns.Travel.FOOT
	track.spd[n] = speed or 100
	session.seen = now
	return true
end

function ns.DB:AddEvent(kind, mapID, x, y, now, extra)
	if not ns.Config:WantsKind(kind) then
		return false
	end
	local session = self.session
	if not session then
		return false
	end
	if kind == ns.Kind.KILL then
		self:AddKill()
		return true
	end
	if kind == ns.Kind.QUEST_TURNIN then
		session.quests = (session.quests or 0) + 1
	end
	local track = self:Track(session)
	local offset = now - session.s
	if offset < 0 then
		offset = 0
	end
	local n = #track.ek + 1
	track.et[n] = math.floor(offset)
	track.ek[n] = kind
	track.em[n] = mapID
	track.ex[n] = self:PackCoord(x)
	track.ey[n] = self:PackCoord(y)
	track.ea[n] = extra or 0
	session.seen = now
	return true
end

function ns.DB:Stats()
	local sessions = self:Sessions()
	local points, events = 0, 0
	for i = 1, #sessions do
		local track = self:Track(sessions[i])
		points = points + #track.t
		events = events + #track.ek
	end
	return #sessions, points, events
end

local function QuoteJSON(text)
	text = tostring(text)
	text = text:gsub("[%z\1-\31\\\"]", function(char)
		if char == "\\" then
			return "\\\\"
		elseif char == "\"" then
			return "\\\""
		elseif char == "\n" then
			return "\\n"
		elseif char == "\r" then
			return "\\r"
		elseif char == "\t" then
			return "\\t"
		end
		return string.format("\\u%04x", string.byte(char))
	end)
	return "\"" .. text .. "\""
end

local function AppendJSON(out, value, seen)
	local kind = type(value)
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			out[#out + 1] = "null"
		elseif value % 1 == 0 and value > -1e15 and value < 1e15 then
			out[#out + 1] = string.format("%d", value)
		else
			out[#out + 1] = string.format("%.6g", value)
		end
	elseif kind == "string" then
		out[#out + 1] = QuoteJSON(value)
	elseif kind == "boolean" then
		out[#out + 1] = value and "true" or "false"
	elseif kind ~= "table" then
		out[#out + 1] = "null"
	elseif seen[value] then
		out[#out + 1] = "null"
	else
		seen[value] = true
		local count = #value
		local items = 0
		local array = true
		for key in pairs(value) do
			items = items + 1
			if type(key) ~= "number" or key < 1 or key > count or key ~= math.floor(key) then
				array = false
			end
		end
		if array and (items == count or items == 0) then
			out[#out + 1] = "["
			for i = 1, count do
				if i > 1 then
					out[#out + 1] = ","
				end
				AppendJSON(out, value[i], seen)
			end
			out[#out + 1] = "]"
		else
			out[#out + 1] = "{"
			local first = true
			for key, item in pairs(value) do
				if type(key) == "string" or type(key) == "number" then
					if not first then
						out[#out + 1] = ","
					end
					first = false
					out[#out + 1] = QuoteJSON(tostring(key))
					out[#out + 1] = ":"
					AppendJSON(out, item, seen)
				end
			end
			out[#out + 1] = "}"
		end
		seen[value] = nil
	end
end

-- Compact byte count. CBOR when the client has it, otherwise compact JSON.
-- This is a lower bound. WoW writes the real saved file as formatted Lua.
function ns.DB:EstimateBytes(value)
	if value == nil then
		return 0
	end
	local util = C_EncodingUtil
	if util and util.SerializeCBOR then
		local ok, encoded = pcall(util.SerializeCBOR, value)
		if ok and type(encoded) == "string" then
			return #encoded
		end
	end
	if util and util.SerializeJSON then
		local ok, encoded = pcall(util.SerializeJSON, value)
		if ok and type(encoded) == "string" then
			return #encoded
		end
	end
	local out = {}
	AppendJSON(out, value, {})
	return #table.concat(out)
end

function ns.DB:MeasureJourney(journey)
	if type(journey) ~= "table" or type(journey.tracks) ~= "table" then
		return 0
	end
	local bytes = #(journey.sessions or {}) * 48
	for _, track in pairs(journey.tracks) do
		if type(track) == "string" then
			bytes = bytes + #track
		elseif type(track) == "table" then
			local ok, packed = pcall(self.PackTrack, self, track)
			if ok and type(packed) == "string" then
				bytes = bytes + #packed
			end
		end
	end
	return bytes
end

function ns.DB:JourneyBytes(journey)
	if type(journey) ~= "table" then
		return 0
	end
	local loaded = false
	if type(journey.tracks) == "table" then
		for _, track in pairs(journey.tracks) do
			if type(track) == "table" then
				loaded = true
				break
			end
		end
	end
	if loaded or type(journey.bytes) ~= "number" then
		local bytes = self:MeasureJourney(journey)
		journey.bytes = bytes
		return bytes
	end
	return journey.bytes
end

function ns.DB:EstimateCharacter()
	if not self.record then
		self:BindPlayer()
	end
	if not self.record then
		return 0
	end
	local bytes = self:JourneyBytes(self.record)
	return bytes
end

function ns.DB:EstimateAll()
	self:EnsureStore()
	local total = 0
	for _, journey in pairs(ZipperDB.journeys) do
		total = total + self:JourneyBytes(journey)
	end
	return total
end

function ns.DB:RememberSize(bytes, now)
	local host = self.record or self.char
	if type(bytes) ~= "number" or type(now) ~= "number" or not host then
		return
	end
	local log = host.sizeLog
	if type(log) ~= "table" then
		log = {}
		host.sizeLog = log
	end
	local last = log[#log]
	if type(last) == "table" and type(last[1]) == "number" and (now - last[1]) > (20 * 60) then
		log = {}
		host.sizeLog = log
		last = nil
	end
	if type(last) == "table" and last[1] == now and last[2] == bytes then
		return
	end
	log[#log + 1] = { now, math.floor(bytes) }
	local cutoff = now - (24 * 3600)
	local drop = 0
	for i = 1, #log do
		local sample = log[i]
		if type(sample) == "table" and type(sample[1]) == "number" and sample[1] < cutoff then
			drop = i
		else
			break
		end
	end
	if drop > 0 then
		local kept = {}
		for i = drop + 1, #log do
			kept[#kept + 1] = log[i]
		end
		log = kept
		host.sizeLog = log
	end
	while #log > 300 do
		table.remove(log, 1)
	end
end

function ns.DB:SizeGrowth()
	local host = self.record or self.char
	local log = host and host.sizeLog
	if type(log) ~= "table" or #log < 2 then
		return nil
	end
	-- A switch to packed storage drops the number once. Rate starts after that drop.
	local start = 1
	for i = 2, #log do
		local prev = log[i - 1]
		local sample = log[i]
		local before = type(prev) == "table" and prev[2] or 0
		local after = type(sample) == "table" and sample[2] or 0
		if before > 0 and after < before * 0.85 then
			start = i
		end
	end
	local first, last = log[start], log[#log]
	if type(first) ~= "table" or type(last) ~= "table" then
		return nil
	end
	if type(first[1]) ~= "number" or type(last[1]) ~= "number" then
		return nil
	end
	local span = last[1] - first[1]
	if span < 300 then
		return nil
	end
	local delta = (last[2] or 0) - (first[2] or 0)
	return (delta / span) * 3600, span, delta
end

function ns.DB:Purge(key)
	self:EnsureStore()
	key = key or self.playerKey
	if not key or type(ZipperDB.journeys[key]) ~= "table" then
		return false
	end
	local removingCurrent = key == self.playerKey
	if removingCurrent then
		local name, realm = "Character", ""
		if self.record then
			name = self.record.name or name
			realm = self.record.realm or realm
		end
		local fresh = self:NewJourney(name, realm)
		ZipperDB.journeys[key] = fresh
		self.record = fresh
		self.session = nil
		if self.viewKey == key then
			self.char = fresh
		end
		self:Open(self:Now(), true)
	else
		ZipperDB.journeys[key] = nil
		if self.viewKey == key then
			self.viewKey = self.playerKey
			self.char = self.record
		end
	end
	if ns.Replay then
		ns.Replay.playing = removingCurrent and false or ns.Replay.playing
		ns.Replay.statsKey = nil
		ns.Replay.chapterKey = nil
		if removingCurrent and ns.Replay.playButton then
			ns.Replay.playButton:SetText("Play")
		end
		if ns.Replay.RefreshCharacters then
			ns.Replay:RefreshCharacters()
		end
		if ns.Replay.frame and ns.Replay.frame:IsShown() and ns.Replay.SetMode then
			ns.Replay:SetMode(removingCurrent and "current" or "all")
		end
	end
	if ns.OnDataChanged then
		ns.OnDataChanged()
	end
	return true
end

function ns.DB:SelectSessions(mode, index)
	local sessions = self:Sessions()
	if mode == "all" then
		return sessions
	end
	if mode == "one" and sessions[index] then
		return { sessions[index] }, index
	end
	if self.session then
		for i = 1, #sessions do
			if sessions[i] == self.session then
				return { self.session }, i
			end
		end
	end
	local last = sessions[#sessions]
	if last then
		return { last }, #sessions
	end
	return {}, nil
end
