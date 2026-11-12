local ADDON_NAME, ns = ...
local L = ns.L

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

local DECODE64

local function Decode64(text)
	if not DECODE64 then
		DECODE64 = {}
		for i = 1, #B64 do
			DECODE64[B64:sub(i, i)] = i - 1
		end
	end
	local map = DECODE64
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

-- Skip `count` varints. A value ends on the first byte below 128.
local function SkipVars(bytes, index, count)
	local seen = 0
	local n = #bytes
	while seen < count and index <= n do
		local byte = bytes:byte(index)
		index = index + 1
		if not byte then
			break
		end
		if byte < 128 then
			seen = seen + 1
		end
	end
	return index
end

-- Mode and speed runs end with a 0 length. Consume that terminator too.
local function SkipRuns(bytes, index)
	while index <= #bytes do
		local run
		run, index = ReadVar(bytes, index)
		if not run or run <= 0 then
			return index
		end
		local _
		_, index = ReadVar(bytes, index)
	end
	return index
end

-- Events only. Point arrays stay packed so a scan cannot pin the journey in RAM.
local function WalkPackedEvents(packed, origin, fn)
	if type(packed) ~= "string" or packed:sub(1, 3) ~= "Z3:" then
		return false
	end
	local bytes = Decode64(packed:sub(4))
	if bytes:byte(1) ~= string.byte("Z") or bytes:byte(2) ~= string.byte("3") then
		return false
	end
	local index = 3
	local count, events
	count, index = ReadVar(bytes, index)
	events, index = ReadVar(bytes, index)
	if not count or not events or events <= 0 then
		return false
	end
	index = SkipVars(bytes, index, count)
	index = SkipVars(bytes, index, count)
	index = SkipVars(bytes, index, count)
	index = SkipVars(bytes, index, count)
	index = SkipRuns(bytes, index)
	index = SkipRuns(bytes, index)
	local previous = 0
	for _ = 1, events do
		local delta, kind, mapID, extra
		delta, index = ReadVar(bytes, index)
		previous = previous + (delta or 0)
		kind, index = ReadVar(bytes, index)
		mapID, index = ReadVar(bytes, index)
		local _
		_, index = ReadVar(bytes, index)
		_, index = ReadVar(bytes, index)
		extra, index = ReadVar(bytes, index)
		if fn(origin + previous, kind, Unzig(extra or 0), Unzig(mapID or 0)) then
			return true
		end
	end
	return false
end

local function JourneyOwns(journey, session)
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
	local _, classFile = UnitClass and UnitClass("player") or nil
	if type(classFile) == "string" and classFile ~= "" and not (issecretvalue and issecretvalue(classFile)) then
		journey.class = classFile
	end
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

function ns.DB:JourneyClass(journey, key)
	journey = journey or self.char
	if type(journey) == "table" and type(journey.class) == "string" and journey.class ~= "" then
		return journey.class
	end
	key = key or self.viewKey
	local classFile
	if type(key) == "string" and GetPlayerInfoByGUID then
		local _, file = GetPlayerInfoByGUID(key)
		if type(file) == "string" and file ~= "" and not (issecretvalue and issecretvalue(file)) then
			classFile = file
		end
	end
	if not classFile then
		local people = ZipperDB and ZipperDB.people
		local person = type(people) == "table" and type(key) == "string" and people[key] or nil
		if type(person) == "table" and type(person.c) == "string" and person.c ~= "" then
			classFile = person.c
		end
	end
	if classFile and type(journey) == "table" then
		journey.class = classFile
	end
	return classFile
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
	if JourneyOwns(self.record, session) then
		return self.record
	end
	if JourneyOwns(self.char, session) then
		return self.char
	end
	return self.record or self.char
end

-- Read events without Track(). Track() replaces a packed string with tables and
-- keeps them until logout, which is how an idle login held the whole journey.
function ns.DB:EachEvent(session, fn)
	if not Usable(session) or type(fn) ~= "function" then
		return false
	end
	local host = self:HostFor(session)
	local track = host and type(host.tracks) == "table" and host.tracks[session.id]
	if type(track) == "table" then
		local origin = session.s
		for i = 1, #(track.ek or {}) do
			if fn(origin + (track.et[i] or 0), track.ek[i], track.ea[i] or 0, track.em[i] or 0) then
				return true
			end
		end
		return false
	end
	if type(track) ~= "string" then
		return false
	end
	return WalkPackedEvents(track, session.s, fn) or false
end

function ns.DB:PointCount(session)
	if not Usable(session) then
		return 0
	end
	local host = self:HostFor(session)
	local track = host and type(host.tracks) == "table" and host.tracks[session.id]
	if type(track) == "table" then
		return #(track.t or {})
	end
	if type(track) ~= "string" or track:sub(1, 3) ~= "Z3:" then
		return 0
	end
	local bytes = Decode64(track:sub(4))
	if bytes:byte(1) ~= string.byte("Z") or bytes:byte(2) ~= string.byte("3") then
		return 0
	end
	local count = ReadVar(bytes, 3)
	return count or 0
end

function ns.DB:HistoryVisible()
	local replay = ns.Replay
	if type(replay) ~= "table" then
		return false
	end
	if replay.frame and replay.frame.IsShown and replay.frame:IsShown() then
		return true
	end
	if replay.route and WorldMapFrame and WorldMapFrame.IsShown and WorldMapFrame:IsShown() then
		return true
	end
	return false
end

-- Pack every session except the one being recorded. Call only when the map
-- and the replay panel are both closed, or the next redraw would unpack again.
function ns.DB:ReleaseHistory()
	if type(ZipperDB) ~= "table" or type(ZipperDB.journeys) ~= "table" then
		return
	end
	local live = self.session
	local liveHost = self.record
	for _, journey in pairs(ZipperDB.journeys) do
		local tracks = type(journey) == "table" and journey.tracks
		if type(tracks) == "table" then
			for id, track in pairs(tracks) do
				if type(track) == "table" and not (journey == liveHost and live and id == live.id) then
					tracks[id] = self:PackTrack(track)
				end
			end
		end
	end
end

function ns.DB:Flush()
	self:EnsureStore()
	self:PruneIdleCompany(false)
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

function ns.DB:NoteLevelUp(level, now)
	local host = self.record
	if not host or type(level) ~= "number" or level <= 0 then
		return false
	end
	now = now or self:Now()
	-- The ding is the session's latest moment. A level span ignores a ding past seen.
	if self.session and (type(self.session.seen) ~= "number" or now > self.session.seen) then
		self.session.seen = now
	end
	if type(host.levels) ~= "table" then
		host.levels = {}
	end
	local last = host.levels[#host.levels]
	if last and last.lv == level and type(last.t) == "number" and math.abs(last.t - now) < 5 then
		return false
	end
	host.levels[#host.levels + 1] = { lv = level, t = now }
	return true
end

function ns.DB:MapAt(journey, when)
	local sessions = journey and journey.sessions
	if type(sessions) ~= "table" or type(when) ~= "number" then
		return nil
	end
	local found, foundAt
	for i = 1, #sessions do
		local session = sessions[i]
		if type(session) == "table" and type(session.s) == "number" and when >= session.s - 1 then
			local stop = session.seen or session.s
			if session == self.session then
				stop = self:Now()
			end
			if when <= stop + 2 then
				local track = self:Track(session)
				for n = 1, #(track.t or {}) do
					local at = session.s + (track.t[n] or 0)
					if at <= when + 1 and (not foundAt or at >= foundAt) and track.m[n] and track.m[n] ~= 0 then
						foundAt = at
						found = track.m[n]
					end
				end
				for n = 1, #(track.et or {}) do
					local at = session.s + (track.et[n] or 0)
					if at <= when + 1 and (not foundAt or at >= foundAt) and track.em[n] and track.em[n] ~= 0 then
						foundAt = at
						found = track.em[n]
					end
				end
			end
		end
	end
	return found
end

function ns.DB:SpanStop(span, journey)
	if span.t1 then
		return span.t1
	end
	if journey == self.record then
		return self:Now()
	end
	local sessions = journey and journey.sessions
	local last = sessions and sessions[#sessions]
	return (last and (last.seen or last.s)) or span.t0
end

local function CollectDings(journey)
	local dings = {}
	if type(journey) ~= "table" or type(journey.levels) ~= "table" then
		return dings
	end
	for i = 1, #journey.levels do
		local row = journey.levels[i]
		if type(row) == "table" and type(row.lv) == "number" and type(row.t) == "number" then
			dings[#dings + 1] = row
		end
	end
	table.sort(dings, function(a, b)
		if a.t == b.t then
			return a.lv < b.lv
		end
		return a.t < b.t
	end)
	return dings
end

function ns.DB:LevelSpans(journey)
	journey = journey or self.char
	if type(journey) ~= "table" then
		return {}
	end
	local sessions = journey.sessions or {}
	local dings = CollectDings(journey)
	local spans = {}
	local function add(lv, lvTo, t0, t1, exact)
		if not lv or not t0 or t1 and t1 <= t0 then
			return
		end
		spans[#spans + 1] = { lv = lv, lvTo = lvTo, t0 = t0, t1 = t1, exact = exact and true or false }
	end
	for s = 1, #sessions do
		local session = sessions[s]
		local fromLevel = session.lv
		if type(fromLevel) == "number" then
			local segStart = session.s
			local segLevel = fromLevel
			local segTop = session.el or fromLevel
			local windowEnd = session.seen or session.s
			local inSession = {}
			for i = 1, #dings do
				local ding = dings[i]
				if ding.t >= session.s and ding.t <= windowEnd + 1 then
					inSession[#inSession + 1] = ding
				end
			end
			if #inSession == 0 then
				local open = session == self.session and segTop == fromLevel
				if segTop > fromLevel then
					add(fromLevel, segTop, segStart, windowEnd, false)
				else
					add(fromLevel, nil, segStart, open and nil or windowEnd, false)
				end
			else
				for i = 1, #inSession do
					local ding = inSession[i]
					if ding.t > segStart and segLevel then
						local jumped = ding.lv > segLevel + 1
						add(segLevel, jumped and (ding.lv - 1) or nil, segStart, ding.t, not jumped and ding.lv == segLevel + 1)
					end
					segStart = ding.t
					segLevel = ding.lv
				end
				if segLevel and windowEnd > segStart then
					local open = session == self.session and (session.el or segLevel) == segLevel
					local top = session.el
					if top and top > segLevel then
						add(segLevel, top, segStart, open and nil or windowEnd, false)
					else
						add(segLevel, nil, segStart, open and nil or windowEnd, true)
					end
				end
			end
		end
	end
	return spans
end

function ns.DB:LevelBounds(journey, lo, hi)
	if not lo then
		return nil
	end
	if not hi or hi < lo then
		hi = lo
	end
	local t0, t1
	local spans = self:LevelSpans(journey)
	for i = 1, #spans do
		local span = spans[i]
		local top = span.lvTo or span.lv
		if top >= lo and span.lv <= hi then
			local stop = self:SpanStop(span, journey)
			if not t0 or span.t0 < t0 then
				t0 = span.t0
			end
			if stop and (not t1 or stop > t1) then
				t1 = stop
			end
		end
	end
	return t0, t1
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

-- Level and XP fraction for an open (still-in-progress) level on this journey.
function ns.DB:OpenLevelProgress(journey)
	journey = journey or self.char
	local session
	if journey == self.record and self.session then
		session = self.session
	else
		local sessions = journey and journey.sessions
		session = sessions and sessions[#sessions]
	end
	if type(session) ~= "table" or type(session.el) ~= "number" then
		return nil, 0
	end
	local frac = 0
	if type(session.em) == "number" and session.em > 0 then
		frac = (session.ex or 0) / session.em
	end
	if frac < 0 then
		frac = 0
	elseif frac > 1 then
		frac = 1
	end
	return session.el, frac
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
	local enemy = (kills == 1) and L["enemy"] or L["enemies"]
	local quest = (quests == 1) and L["quest"] or L["quests"]
	local levelText
	if math.abs(levels - 1) < 0.005 then
		levelText = L["1 level"]
	else
		levelText = string.format(L["%.2f levels"], levels)
	end
	return string.format(L["You killed %s %s, finished %s %s, and gained %s."], Comma(kills), enemy, Comma(quests), quest, levelText)
end

local function PlayedWords(seconds)
	seconds = math.floor(seconds or 0)
	if seconds < 0 then
		seconds = 0
	end
	if seconds < 60 then
		return string.format(L["%d sec"], seconds)
	end
	local minutes = math.floor(seconds / 60)
	local hours = math.floor(minutes / 60)
	minutes = minutes % 60
	if hours <= 0 then
		local remain = seconds % 60
		if remain > 0 then
			return string.format(L["%d min %d sec"], minutes, remain)
		end
		return string.format(L["%d min"], minutes)
	end
	if minutes == 0 then
		if hours == 1 then
			return L["1 hour"]
		end
		return string.format(L["%d hours"], hours)
	end
	return string.format(L["%d hr %d min"], hours, minutes)
end

local function MapName(mapID)
	if not mapID or mapID == 0 or not C_Map or not C_Map.GetMapInfo then
		return nil
	end
	local info = C_Map.GetMapInfo(mapID)
	local name = info and info.name
	if type(name) ~= "string" or name == "" or (issecretvalue and issecretvalue(name)) then
		return nil
	end
	return name
end

local function FinishedBand(db, newLevel, now)
	local journey = db.record
	if type(journey) ~= "table" or type(newLevel) ~= "number" or type(now) ~= "number" then
		return nil
	end
	local dings = CollectDings(journey)
	local sessions = journey.sessions or {}
	for s = #sessions, 1, -1 do
		local session = sessions[s]
		if type(session) == "table" and type(session.s) == "number" and type(session.lv) == "number" then
			local windowEnd = session.seen or session.s
			if session == db.session and now > windowEnd then
				windowEnd = now
			end
			if now >= session.s - 1 and now <= windowEnd + 1 then
				local segLevel = session.lv
				local segStart = session.s
				for i = 1, #dings do
					local ding = dings[i]
					if ding.t >= session.s and ding.t <= windowEnd + 1 then
						if math.abs(ding.t - now) <= 1 and ding.lv == newLevel and segLevel < newLevel then
							return segLevel, newLevel - 1
						end
						if ding.t >= segStart then
							segStart = ding.t
							segLevel = ding.lv
						end
					end
				end
			end
		end
	end
	return nil
end

local function StartedOnDing(journey, span)
	local levels = journey.levels
	if type(levels) ~= "table" then
		return false
	end
	for i = 1, #levels do
		local row = levels[i]
		if type(row) == "table" and row.lv == span.lv and type(row.t) == "number" and math.abs(row.t - span.t0) <= 1 then
			return true
		end
	end
	return false
end

local function InSpan(span, when, onDing)
	if type(span.t1) ~= "number" or type(when) ~= "number" or when > span.t1 then
		return false
	end
	if onDing then
		return when > span.t0
	end
	return when >= span.t0
end

local function RecapLine(lo, hi, seconds, kills, quests, deaths, fromName, toName)
	local taken = PlayedWords(seconds)
	local ranged = hi ~= lo
	local head
	if fromName and toName and fromName ~= toName then
		if ranged then
			head = string.format(L["Levels %d–%d took %s, from %s to %s."], lo, hi, taken, fromName, toName)
		else
			head = string.format(L["Level %d took %s, from %s to %s."], lo, taken, fromName, toName)
		end
	elseif fromName or toName then
		local where = fromName or toName
		if ranged then
			head = string.format(L["Levels %d–%d took %s in %s."], lo, hi, taken, where)
		else
			head = string.format(L["Level %d took %s in %s."], lo, taken, where)
		end
	elseif ranged then
		head = string.format(L["Levels %d–%d took %s."], lo, hi, taken)
	else
		head = string.format(L["Level %d took %s."], lo, taken)
	end
	local bits = {}
	if kills > 0 and quests > 0 then
		local enemy = (kills == 1) and L["enemy"] or L["enemies"]
		local quest = (quests == 1) and L["quest"] or L["quests"]
		bits[#bits + 1] = string.format(L["You killed %s %s and finished %s %s."], Comma(kills), enemy, Comma(quests), quest)
	elseif kills > 0 then
		local enemy = (kills == 1) and L["enemy"] or L["enemies"]
		bits[#bits + 1] = string.format(L["You killed %s %s."], Comma(kills), enemy)
	elseif quests > 0 then
		local quest = (quests == 1) and L["quest"] or L["quests"]
		bits[#bits + 1] = string.format(L["You finished %s %s."], Comma(quests), quest)
	end
	if deaths == 1 then
		bits[#bits + 1] = L["You died once."]
	elseif deaths > 1 then
		bits[#bits + 1] = string.format(L["You died %d times."], deaths)
	end
	local text = head
	if #bits > 0 then
		text = text .. " " .. table.concat(bits, " ")
	end
	local link = ns.DB:LevelChatLink(lo, hi)
	if link then
		text = text .. " " .. link
	end
	return text
end

local function CountFacts(db, journey, spans)
	local kills, quests, deaths = 0, 0, 0
	local onDing = {}
	for i = 1, #spans do
		onDing[i] = StartedOnDing(journey, spans[i])
	end
	local sessions = journey.sessions or {}
	for s = 1, #sessions do
		local session = sessions[s]
		if type(session) == "table" and type(session.s) == "number" then
			local track = db:Track(session)
			for n = 1, #(track.ek or {}) do
				local kind = track.ek[n]
				local want = kind == ns.Kind.KILL or kind == ns.Kind.QUEST_TURNIN or kind == ns.Kind.DEATH
				if want then
					local when = session.s + (track.et[n] or 0)
					for i = 1, #spans do
						if InSpan(spans[i], when, onDing[i]) then
							if kind == ns.Kind.KILL then
								kills = kills + 1
							elseif kind == ns.Kind.QUEST_TURNIN then
								quests = quests + 1
							else
								deaths = deaths + 1
							end
							break
						end
					end
				end
			end
		end
	end
	return kills, quests, deaths
end

function ns.DB:LevelRecapText(newLevel, now)
	local journey = self.record
	if type(journey) ~= "table" or type(newLevel) ~= "number" then
		return nil
	end
	if type(now) ~= "number" then
		local levels = journey.levels
		if type(levels) == "table" then
			for i = #levels, 1, -1 do
				local row = levels[i]
				if type(row) == "table" and row.lv == newLevel and type(row.t) == "number" then
					now = row.t
					break
				end
			end
		end
	end
	if type(now) ~= "number" then
		return nil
	end
	local lo, hi = FinishedBand(self, newLevel, now)
	if not lo or not hi or hi < lo then
		return nil
	end
	local spans = self:LevelSpans(journey)
	local matched = {}
	local seconds = 0
	local t0, t1
	for i = 1, #spans do
		local span = spans[i]
		local top = span.lvTo or span.lv
		if span.lv == lo and top == hi and type(span.t1) == "number" then
			matched[#matched + 1] = span
			local dur = span.t1 - span.t0
			if dur > 0 then
				seconds = seconds + dur
			end
			if not t0 or span.t0 < t0 then
				t0 = span.t0
			end
			if not t1 or span.t1 > t1 then
				t1 = span.t1
			end
		end
	end
	local kills, quests, deaths = CountFacts(self, journey, matched)
	if seconds < 1 and kills == 0 and quests == 0 and deaths == 0 then
		return nil
	end
	local fromName = t0 and MapName(self:MapAt(journey, t0)) or nil
	local toName = t1 and MapName(self:MapAt(journey, t1)) or nil
	return RecapLine(lo, hi, seconds, kills, quests, deaths, fromName, toName)
end

function ns.DB:ExactLevelRecap(level)
	local journey = self.record
	if type(journey) ~= "table" or type(level) ~= "number" or level < 1 then
		return nil
	end
	local spans = self:LevelSpans(journey)
	local matched = {}
	local seconds = 0
	local t0, t1
	for i = 1, #spans do
		local span = spans[i]
		local top = span.lvTo or span.lv
		-- A jump stored as one stretch is not a recording of each level inside it.
		if span.lv == level and top == level and type(span.t1) == "number" then
			matched[#matched + 1] = span
			local dur = span.t1 - span.t0
			if dur > 0 then
				seconds = seconds + dur
			end
			if not t0 or span.t0 < t0 then
				t0 = span.t0
			end
			if not t1 or span.t1 > t1 then
				t1 = span.t1
			end
		end
	end
	local kills, quests, deaths = CountFacts(self, journey, matched)
	if seconds < 1 and kills == 0 and quests == 0 and deaths == 0 then
		return nil
	end
	local fromName = t0 and MapName(self:MapAt(journey, t0)) or nil
	local toName = t1 and MapName(self:MapAt(journey, t1)) or nil
	return RecapLine(level, level, seconds, kills, quests, deaths, fromName, toName)
end

function ns.DB:DingCommand(level, playerLevel, maxLevel)
	if level == nil then
		if type(playerLevel) ~= "number" or playerLevel < 2 then
			return L["No level-up to recap yet."]
		end
		level = playerLevel - 1
	end
	if type(level) ~= "number" or level < 1 or level ~= math.floor(level) then
		return L["Use /zip ding or /zip ding 28."]
	end
	if type(maxLevel) == "number" and maxLevel >= 1 then
		if level > maxLevel then
			return string.format(L["Level %d is past the level cap of %d."], level, maxLevel)
		end
		if level >= maxLevel then
			return string.format(L["Level %d is the level cap."], level)
		end
	end
	if type(playerLevel) == "number" then
		if playerLevel < level then
			return string.format(L["You have not reached level %d."], level)
		end
		if playerLevel < level + 1 then
			return string.format(L["You have not reached level %d."], level + 1)
		end
	end
	return self:ExactLevelRecap(level) or string.format(L["No recording for level %d."], level)
end

function ns.DB:LevelChatLink(lo, hi)
	if type(lo) ~= "number" or lo <= 0 then
		return nil
	end
	if type(hi) ~= "number" or hi < lo then
		hi = lo
	end
	local label
	if hi ~= lo then
		label = string.format(L["Replay levels %d–%d"], lo, hi)
	else
		label = string.format(L["Replay level %d"], lo)
	end
	return string.format("|cff71d5ff|Haddon:%s:level:%d:%d|h[%s]|h|r", ADDON_NAME, lo, hi, label)
end

function ns.DB:LevelFromLink(link)
	if type(link) ~= "string" or link == "" or (issecretvalue and issecretvalue(link)) then
		return nil
	end
	local body = string.match(link, "|H([^|]+)") or link
	local linkType, addon, action, lo, hi = string.match(body, "^([^:]+):([^:]+):([^:]+):(%d+):(%d+)")
	if linkType ~= "addon" or addon ~= ADDON_NAME or action ~= "level" then
		return nil
	end
	lo = tonumber(lo)
	hi = tonumber(hi)
	if not lo or not hi or lo <= 0 or hi <= 0 then
		return nil
	end
	if hi < lo then
		lo, hi = hi, lo
	end
	return lo, hi
end

local QUIET_KEEP = {
	[ns.Kind.KILL] = true,
	[ns.Kind.QUEST_ACCEPT] = true,
	[ns.Kind.QUEST_TURNIN] = true,
	[ns.Kind.DEATH] = true,
	[ns.Kind.SUMMON] = true,
	[ns.Kind.HEARTH] = true,
	[ns.Kind.FLIGHT_START] = true,
	[ns.Kind.INSTANCE_ENTER] = true,
	[ns.Kind.BOSS] = true,
	[ns.Kind.LEVEL] = true,
	[ns.Kind.PORTAL] = true,
	[ns.Kind.TRAINER] = true,
	[ns.Kind.CAMP] = true,
	[ns.Kind.SLEEP] = true,
	[ns.Kind.FISH] = true,
}

function ns.DB:SessionWorthKeeping(journey, session)
	if not Usable(session) then
		return true
	end
	if (session.kills or 0) > 0 or (session.quests or 0) > 0 then
		return true
	end
	if type(session.lv) == "number" and type(session.el) == "number" and session.el > session.lv then
		return true
	end
	if type(session.reach) == "number" and session.reach >= (ns.QUIET_YARDS or 250) then
		return true
	end
	local keep = false
	self:EachEvent(session, function(_, kind, extra)
		extra = extra or 0
		if kind == ns.Kind.CAMP or kind == ns.Kind.SLEEP or kind == ns.Kind.FISH then
			if extra ~= 1 then
				keep = true
				return true
			end
		elseif kind == ns.Kind.GROUP then
			if extra >= self.GROUP_KEPT then
				keep = true
				return true
			end
		elseif QUIET_KEEP[kind] then
			keep = true
			return true
		end
	end)
	if keep then
		return true
	end
	-- Older stops have no measured distance. Leave those alone.
	if self:PointCount(session) > 0 and type(session.reach) ~= "number" then
		return true
	end
	return false
end

function ns.DB:RemoveSession(journey, index)
	local sessions = journey and journey.sessions
	local session = sessions and sessions[index]
	if not Usable(session) or session == self.session then
		return false
	end
	table.remove(sessions, index)
	if type(journey.tracks) == "table" and session.id then
		journey.tracks[session.id] = nil
	end
	return true
end

function ns.DB:DropQuietTail()
	local journey = self.record
	local sessions = journey and journey.sessions
	if type(sessions) ~= "table" then
		return 0
	end
	local last = sessions[#sessions]
	if not Usable(last) or last == self.session then
		return 0
	end
	local seen = last.seen or last.s
	if type(seen) == "number" and (self:Now() - seen) <= ns.CONTINUE_SECONDS then
		return 0
	end
	if self:SessionWorthKeeping(journey, last) then
		return 0
	end
	if not self:RemoveSession(journey, #sessions) then
		return 0
	end
	self:PruneIdleCompany(false)
	self.companySpanKey = nil
	self.companyReportKey = nil
	return 1
end

function ns.DB:DropQuietSessions()
	self:EnsureStore()
	local journeys = ZipperDB.journeys
	if type(journeys) ~= "table" then
		return 0
	end
	local dropped = 0
	for _, journey in pairs(journeys) do
		local sessions = type(journey) == "table" and journey.sessions or nil
		if type(sessions) == "table" then
			for i = #sessions, 1, -1 do
				local session = sessions[i]
				if session ~= self.session and not self:SessionWorthKeeping(journey, session) then
					if self:RemoveSession(journey, i) then
						dropped = dropped + 1
					end
				end
			end
		end
	end
	if dropped > 0 then
		self:PruneIdleCompany(false)
		self.companySpanKey = nil
		self.companyReportKey = nil
	end
	return dropped
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

ns.DB.KILL_ELITE = 16777216
ns.DB.KILL_RARE = 33554432

function ns.DB:CreatureID(guid)
	if type(guid) ~= "string" or guid == "" then
		return 0
	end
	local unitType, _, _, _, _, id = strsplit("-", guid)
	if (unitType == "Creature" or unitType == "Vehicle") and id then
		return tonumber(id) or 0
	end
	return 0
end

function ns.DB:PackKill(mobID, elite, rare)
	mobID = tonumber(mobID) or 0
	if mobID < 0 then
		mobID = 0
	end
	if mobID >= self.KILL_ELITE then
		mobID = mobID % self.KILL_ELITE
	end
	if elite then
		mobID = mobID + self.KILL_ELITE
	end
	if rare then
		mobID = mobID + self.KILL_RARE
	end
	return mobID
end

function ns.DB:PackTrainer(trainerType, profession)
	trainerType = tonumber(trainerType) or 0
	profession = tonumber(profession) or 0
	if trainerType < 0 then
		trainerType = 0
	end
	if profession < 0 then
		profession = 0
	end
	return trainerType + profession * 16
end

function ns.DB:ReadTrainer(extra)
	extra = tonumber(extra) or 0
	if extra < 0 then
		extra = 0
	end
	return extra % 16, math.floor(extra / 16)
end

-- Instance type is 1..6. Older events stored only the type. Newer ones pack
-- GetInstanceInfo's instanceID above it so a leave/re-enter of the same run
-- can be merged when counting dungeons with the party.
ns.DB.INSTANCE_ID_MUL = 8

function ns.DB:PackInstance(instType, instanceID)
	instType = tonumber(instType) or 0
	instanceID = tonumber(instanceID) or 0
	if instType < 0 then
		instType = 0
	end
	if instanceID < 0 then
		instanceID = 0
	end
	return instType + instanceID * self.INSTANCE_ID_MUL
end

function ns.DB:ReadInstance(extra)
	extra = tonumber(extra) or 0
	if extra < 0 then
		extra = 0
	end
	return extra % self.INSTANCE_ID_MUL, math.floor(extra / self.INSTANCE_ID_MUL)
end

function ns.DB:NoteSummoner(name, now)
	local session = self.session
	if not session or type(name) ~= "string" or name == "" or type(now) ~= "number" then
		return
	end
	if issecretvalue and issecretvalue(name) then
		return
	end
	local list = session.summonBy
	if type(list) ~= "table" then
		list = {}
		session.summonBy = list
	end
	local last = list[#list]
	if type(last) == "table" and last.n == name and type(last.t) == "number" and math.abs(last.t - now) <= 2 then
		return
	end
	list[#list + 1] = { t = now, n = name }
end

function ns.DB:SummonerName(session, when)
	local list = session and session.summonBy
	if type(list) ~= "table" or type(when) ~= "number" then
		return nil
	end
	local best, bestGap
	for i = 1, #list do
		local row = list[i]
		if type(row) == "table" and type(row.t) == "number" and type(row.n) == "string" then
			local gap = when - row.t
			if gap >= 0 and gap <= 120 and (not bestGap or gap < bestGap) then
				best = row.n
				bestGap = gap
			end
		end
	end
	return best
end

function ns.DB:ReadKill(extra)
	extra = tonumber(extra) or 0
	if extra < 0 then
		extra = 0
	end
	local rare = false
	if extra >= self.KILL_RARE then
		rare = true
		extra = extra - self.KILL_RARE
	end
	local elite = false
	if extra >= self.KILL_ELITE then
		elite = true
		extra = extra - self.KILL_ELITE
	end
	return extra, elite, rare
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
	return self:AddEventOn(self.session, kind, mapID, x, y, now, extra)
end

function ns.DB:AddEventOn(session, kind, mapID, x, y, now, extra)
	if not ns.Config:WantsKind(kind) then
		return false
	end
	if not session then
		return false
	end
	if kind == ns.Kind.KILL then
		session.kills = (session.kills or 0) + 1
	elseif kind == ns.Kind.QUEST_TURNIN then
		session.quests = (session.quests or 0) + 1
	end
	local track = self:Track(session)
	local offset = math.floor(now - session.s)
	if offset < 0 then
		offset = 0
	end
	local n = #track.ek
	local insertAt = n + 1
	-- Idle start is backdated; keep et ordered so replay scans stay correct.
	if n > 0 and offset < (track.et[n] or 0) then
		insertAt = 1
		for i = n, 1, -1 do
			if (track.et[i] or 0) <= offset then
				insertAt = i + 1
				break
			end
			insertAt = i
		end
		for i = n, insertAt, -1 do
			track.et[i + 1] = track.et[i]
			track.ek[i + 1] = track.ek[i]
			track.em[i + 1] = track.em[i]
			track.ex[i + 1] = track.ex[i]
			track.ey[i + 1] = track.ey[i]
			track.ea[i + 1] = track.ea[i]
		end
	end
	track.et[insertAt] = offset
	track.ek[insertAt] = kind
	track.em[insertAt] = mapID
	track.ex[insertAt] = self:PackCoord(x)
	track.ey[insertAt] = self:PackCoord(y)
	track.ea[insertAt] = extra or 0
	session.seen = self:Now()
	if kind ~= ns.Kind.GROUP and self:CompanyQualifies(kind) then
		self:CreditCompany(now)
	end
	return true
end

function ns.DB:LastInstanceDoor()
	local host = self.record
	local sessions = host and host.sessions
	if type(sessions) ~= "table" then
		return nil
	end
	-- The first idle tick calls this. Track() would unpack every session that
	-- has no door and keep those tables until logout.
	for s = #sessions, 1, -1 do
		local session = sessions[s]
		local foundKind, foundExtra
		self:EachEvent(session, function(_, kind, extra)
			if kind == ns.Kind.INSTANCE_ENTER or kind == ns.Kind.INSTANCE_LEAVE then
				foundKind, foundExtra = kind, extra
			end
		end)
		if foundKind then
			return foundKind, foundExtra, session
		end
	end
end

function ns.DB:CloseInstance(session, extra)
	if not session then
		return false
	end
	local track = self:Track(session)
	local n = #track.t
	local mapID = n > 0 and track.m[n] or 0
	local x = n > 0 and (track.x[n] / ns.COORD_SCALE) or 0
	local y = n > 0 and (track.y[n] / ns.COORD_SCALE) or 0
	return self:AddEventOn(session, ns.Kind.INSTANCE_LEAVE, mapID, x, y, session.seen or session.s, extra or 0)
end

-- Company is a time span per person, not a pile of counters.
-- journey.with[guid] = { join, leave, join, leave, ... }. An odd length is still grouped.
-- A span is saved only after something happened inside it: a quest, a finished
-- objective, a kill, a death, or an instance. Standing in a group does not.
-- Names and the first meeting live once on ZipperDB.people, and only then.
-- people[guid].ok is the join time of the stretch that earned the record.
-- A join pip uses GROUP_KEPT on top of the headcount so a later prune can
-- tell it from a pip that was written just for being invited.

ns.DB.GROUP_KEPT = 16777216

function ns.DB:CompanyQualifies(kind)
	return kind == ns.Kind.QUEST_ACCEPT
		or kind == ns.Kind.QUEST_TURNIN
		or kind == ns.Kind.KILL
		or kind == ns.Kind.DEATH
		or kind == ns.Kind.INSTANCE_ENTER
		or kind == ns.Kind.BOSS
end

function ns.DB:TouchPerson(guid, info, now, mapID)
	self:EnsureStore()
	if type(ZipperDB.people) ~= "table" then
		ZipperDB.people = {}
	end
	local row = ZipperDB.people[guid]
	if type(row) ~= "table" then
		row = {}
		ZipperDB.people[guid] = row
	end
	info = info or {}
	if type(info.n) == "string" and info.n ~= "" then
		row.n = info.n
	end
	if type(info.c) == "string" and info.c ~= "" then
		row.c = info.c
	end
	if type(row.t) ~= "number" then
		row.t = now
		row.map = mapID or 0
		local level = tonumber(info.lv) or 0
		if level < 0 then
			level = 0
		end
		row.lv = level
		row.by = self.playerKey
		if self.record and type(self.record.name) == "string" and self.record.name ~= "" then
			row.bn = self.record.name
		end
	end
	return row
end

function ns.DB:SealStaleCompany(now)
	local journey = self.record
	local with = journey and journey.with
	if type(with) ~= "table" or type(now) ~= "number" then
		return
	end
	local current = self.session
	local sessions = journey.sessions
	for _, spans in pairs(with) do
		if type(spans) == "table" and (#spans % 2 == 1) then
			local start = spans[#spans]
			local owner
			if type(start) == "number" and type(sessions) == "table" then
				for i = 1, #sessions do
					local session = sessions[i]
					local seen = session.seen or session.s
					if type(session.s) == "number" and start >= session.s and type(seen) == "number" and start <= seen + 1 then
						owner = session
					end
				end
			end
			if owner ~= current then
				local stop = start
				if owner then
					stop = owner.seen or owner.s or start
				end
				if type(stop) ~= "number" or stop < start then
					stop = start
				end
				spans[#spans + 1] = stop
			end
		end
	end
end

function ns.DB:CloseCompany(now)
	local journey = self.record
	local with = journey and journey.with
	if type(with) ~= "table" or type(now) ~= "number" then
		return false
	end
	local changed = false
	for _, spans in pairs(with) do
		if type(spans) == "table" and (#spans % 2 == 1) then
			local start = spans[#spans]
			local stop = now
			if type(start) == "number" and stop < start then
				stop = start
			end
			spans[#spans + 1] = stop
			changed = true
		end
	end
	if changed then
		self:Touch(now)
	end
	return changed
end

-- End one person's open stretch without moving the session clock backward.
function ns.DB:CloseMember(guid, when)
	local journey = self.record
	local with = journey and journey.with
	local spans = type(with) == "table" and with[guid]
	if type(guid) ~= "string" or type(spans) ~= "table" or #spans % 2 == 0 or type(when) ~= "number" then
		return false
	end
	local startAt = spans[#spans]
	if type(startAt) == "number" and when < startAt then
		when = startAt
	end
	spans[#spans + 1] = when
	return true
end

-- Forget an open stretch that was only a party slot, never someone beside you.
function ns.DB:DropOpen(guid)
	local journey = self.record
	local with = journey and journey.with
	local spans = type(with) == "table" and with[guid]
	if type(spans) ~= "table" or #spans % 2 == 0 then
		return false
	end
	spans[#spans] = nil
	if #spans == 0 then
		with[guid] = nil
		if not next(with) then
			journey.with = nil
		end
	end
	return true
end

-- members[guid] = { n = name, c = classFile, lv = their level }.
-- Returns the guids who actually joined, and whether any span opened or closed.
-- A leave within the reload window is the same stretch, not a new join.
function ns.DB:ApplyRoster(members, now)
	local journey = self.record
	if type(journey) ~= "table" or type(now) ~= "number" or type(members) ~= "table" then
		return {}, false
	end
	local with = journey.with
	if type(with) ~= "table" then
		if not next(members) then
			return {}, false
		end
		with = {}
		journey.with = with
	end
	local joined = {}
	local changed = false
	for guid, spans in pairs(with) do
		if guid ~= self.playerKey and type(spans) == "table" and (#spans % 2 == 1) and not members[guid] then
			local start = spans[#spans]
			local stop = now
			if type(start) == "number" and stop < start then
				stop = start
			end
			spans[#spans + 1] = stop
			changed = true
		end
	end
	for guid in pairs(members) do
		if type(guid) == "string" and guid ~= self.playerKey then
			local spans = with[guid]
			if type(spans) ~= "table" then
				spans = {}
				with[guid] = spans
			end
			if #spans % 2 == 0 then
				local last = spans[#spans]
				if type(last) == "number" and now >= last and (now - last) <= ns.CONTINUE_SECONDS then
					spans[#spans] = nil
					changed = true
				else
					spans[#spans + 1] = now
					joined[#joined + 1] = guid
					changed = true
				end
			end
		end
	end
	if changed then
		self:Touch(now)
		self:PruneIdleCompany(true)
	end
	return joined, changed
end

function ns.DB:CoveringStart(spans, when, liveEnd)
	if type(spans) ~= "table" or type(when) ~= "number" then
		return nil
	end
	for i = 1, #spans, 2 do
		local startAt = spans[i]
		local stopAt = spans[i + 1]
		if type(stopAt) ~= "number" then
			stopAt = liveEnd or when
		end
		if type(startAt) == "number" and when >= startAt and when <= stopAt then
			return startAt
		end
	end
	return nil
end

function ns.DB:RangeHasWork(journey, startAt, stopAt)
	local sessions = journey and journey.sessions
	if type(sessions) ~= "table" or type(startAt) ~= "number" or type(stopAt) ~= "number" then
		return false
	end
	for i = 1, #sessions do
		local session = sessions[i]
		if type(session) == "table" and type(session.s) == "number" and session.s <= stopAt then
			local hit = false
			self:EachEvent(session, function(when, kind)
				if when >= startAt and when <= stopAt and self:CompanyQualifies(kind) then
					hit = true
					return true
				end
			end)
			if hit then
				return true
			end
		end
	end
	return false
end

function ns.DB:HasKeptMarker(journey, startAt)
	local sessions = journey and journey.sessions
	if type(sessions) ~= "table" or type(startAt) ~= "number" then
		return false
	end
	for i = 1, #sessions do
		local session = sessions[i]
		if type(session) == "table" and type(session.s) == "number" then
			local hit = false
			self:EachEvent(session, function(when, kind, extra)
				if kind == ns.Kind.GROUP and (extra or 0) >= self.GROUP_KEPT and math.abs(when - startAt) <= 2 then
					hit = true
					return true
				end
			end)
			if hit then
				return true
			end
		end
	end
	return false
end

function ns.DB:SpanWorthKeeping(journey, guid, startAt, stopAt)
	if self:RangeHasWork(journey, startAt, stopAt) or self:HasKeptMarker(journey, startAt) then
		return true
	end
	local people = ZipperDB and ZipperDB.people
	local row = type(people) == "table" and people[guid] or nil
	return type(row) == "table" and type(row.ok) == "number" and math.abs(row.ok - startAt) <= 2
end

function ns.DB:JoinPlace(guid, when)
	local recall, mapID, x, y
	if ns.Social and ns.Social.Recall then
		recall, mapID, x, y = ns.Social:Recall(guid)
	end
	if type(recall) == "table" and type(recall.t) == "number" and math.abs(recall.t - when) <= 2 and type(x) == "number" and type(y) == "number" then
		return mapID or 0, x, y
	end
	return self:SampleNear(self.record, when)
end

function ns.DB:SampleNear(journey, when)
	local sessions = journey and journey.sessions
	if type(sessions) ~= "table" or type(when) ~= "number" then
		return nil
	end
	local best, mapID, x, y
	for i = 1, #sessions do
		local session = sessions[i]
		if type(session) == "table" and type(session.s) == "number" then
			local track = self:Track(session)
			for n = 1, #track.t do
				local dist = math.abs((session.s + (track.t[n] or 0)) - when)
				if not best or dist < best then
					best = dist
					mapID = track.m[n]
					x = (track.x[n] or 0) / ns.COORD_SCALE
					y = (track.y[n] or 0) / ns.COORD_SCALE
				end
			end
		end
	end
	if best and best <= 30 and mapID and mapID ~= 0 then
		return mapID, x, y
	end
	return nil
end

function ns.DB:SessionCovering(journey, when)
	local sessions = journey and journey.sessions
	local found
	if type(sessions) == "table" and type(when) == "number" then
		for i = 1, #sessions do
			local session = sessions[i]
			if type(session) == "table" and type(session.s) == "number" and when >= session.s then
				if session == self.session or when <= (session.seen or session.s) + 2 then
					found = session
				end
			end
		end
	end
	return found or self.session
end

function ns.DB:HasJoinMarker(journey, when)
	local sessions = journey and journey.sessions
	if type(sessions) ~= "table" or type(when) ~= "number" then
		return false
	end
	for i = 1, #sessions do
		local session = sessions[i]
		if type(session) == "table" and type(session.s) == "number" then
			local hit = false
			self:EachEvent(session, function(at, kind)
				if kind == ns.Kind.GROUP and math.abs(at - when) <= 2 then
					hit = true
					return true
				end
			end)
			if hit then
				return true
			end
		end
	end
	return false
end

function ns.DB:WriteJoinMarker(when)
	local journey = self.record
	if not journey or self:HasJoinMarker(journey, when) then
		return false
	end
	local session = self:SessionCovering(journey, when)
	if not session then
		return false
	end
	local count = 0
	local mapID, x, y
	local with = journey.with
	if type(with) == "table" then
		for guid, spans in pairs(with) do
			if type(spans) == "table" then
				for i = 1, #spans, 2 do
					local startAt = spans[i]
					if type(startAt) == "number" and math.abs(startAt - when) <= 2 then
						count = count + 1
						if not mapID then
							mapID, x, y = self:JoinPlace(guid, startAt)
						end
					end
				end
			end
		end
	end
	if not mapID or type(x) ~= "number" or type(y) ~= "number" then
		mapID, x, y = 0, 0, 0
	end
	if count < 1 then
		count = 1
	end
	return self:AddEventOn(session, ns.Kind.GROUP, mapID, x, y, when, count + self.GROUP_KEPT)
end

-- The event at `when` already happened. Anyone whose span covers it has now
-- done something together, so their name is worth saving and the join pip
-- belongs at the spot they were picked up.
function ns.DB:CreditCompany(when)
	local journey = self.record
	local with = journey and journey.with
	if type(with) ~= "table" or type(when) ~= "number" then
		return false
	end
	local starts = {}
	local any = false
	for guid, spans in pairs(with) do
		local startAt = self:CoveringStart(spans, when, when)
		local apart = ns.Social and ns.Social.NearEnough and not ns.Social:NearEnough(guid)
		if startAt and not apart then
			local info, mapID = nil, nil
			if ns.Social and ns.Social.Recall then
				local recall, recalledMap = ns.Social:Recall(guid)
				info = recall
				mapID = recalledMap
			end
			if type(info) ~= "table" or type(info.t) ~= "number" or math.abs(info.t - startAt) > 2 then
				mapID = select(1, self:JoinPlace(guid, startAt))
			end
			self:TouchPerson(guid, info, startAt, mapID)
			local row = ZipperDB.people and ZipperDB.people[guid]
			if type(row) == "table" and type(row.ok) ~= "number" then
				row.ok = startAt
			end
			starts[startAt] = true
			any = true
		end
	end
	for startAt in pairs(starts) do
		self:WriteJoinMarker(startAt)
	end
	return any
end

local function MarkerNear(when, starts)
	for i = 1, #starts do
		if math.abs(starts[i] - when) <= 2 then
			return true
		end
	end
	return false
end

local function DropIdleMarkers(self, journey, starts)
	local sessions = journey.sessions
	if type(sessions) ~= "table" then
		return
	end
	for i = 1, #sessions do
		local session = sessions[i]
		if type(session) == "table" and type(session.s) == "number" and journey.tracks and journey.tracks[session.id] then
			local needsDrop = false
			self:EachEvent(session, function(when, kind)
				if kind == ns.Kind.GROUP and not MarkerNear(when, starts) then
					needsDrop = true
					return true
				end
			end)
			if not needsDrop then
				-- Packed history stays packed. Unpacking here used to keep every session.
			else
			local track = self:Track(session)
			local et, ek, em, ex, ey, ea = {}, {}, {}, {}, {}, {}
			local count = 0
			local dropped = false
			for n = 1, #(track.ek or {}) do
				local kind = track.ek[n]
				local when = session.s + (track.et[n] or 0)
				if kind == ns.Kind.GROUP and not MarkerNear(when, starts) then
					dropped = true
				else
					count = count + 1
					et[count] = track.et[n]
					ek[count] = kind
					em[count] = track.em[n]
					ex[count] = track.ex[n]
					ey[count] = track.ey[n]
					ea[count] = track.ea[n]
				end
			end
			if dropped then
				track.et, track.ek, track.em = et, ek, em
				track.ex, track.ey, track.ea = ex, ey, ea
			end
			end
		end
	end
end

-- closedOnly leaves an open stretch in memory so a later quest can still claim it.
-- A full prune runs on login and on logout, after open stretches have been closed.
function ns.DB:PruneIdleCompany(closedOnly)
	self:EnsureStore()
	local journeys = ZipperDB.journeys
	if type(journeys) ~= "table" then
		return
	end
	for _, journey in pairs(journeys) do
		local with = type(journey) == "table" and journey.with or nil
		if type(with) == "table" then
			local liveEnd = 0
			if journey == self.record and self.session then
				liveEnd = self:Now()
			else
				local sessions = journey.sessions
				local last = type(sessions) == "table" and sessions[#sessions] or nil
				liveEnd = (last and (last.seen or last.s)) or 0
			end
			local starts = {}
			for guid, spans in pairs(with) do
				if type(spans) == "table" then
					local fresh = {}
					for i = 1, #spans, 2 do
						local startAt = spans[i]
						local stopAt = spans[i + 1]
						local open = type(stopAt) ~= "number"
						local keep = false
						if type(startAt) == "number" then
							if open and closedOnly then
								keep = true
							else
								local endAt = open and liveEnd or stopAt
								keep = self:SpanWorthKeeping(journey, guid, startAt, endAt)
							end
						end
						if keep then
							fresh[#fresh + 1] = startAt
							starts[#starts + 1] = startAt
							if not open then
								fresh[#fresh + 1] = stopAt
							end
						end
					end
					if #fresh > 0 then
						with[guid] = fresh
					else
						with[guid] = nil
					end
				else
					with[guid] = nil
				end
			end
			if not next(with) then
				journey.with = nil
			end
			DropIdleMarkers(self, journey, starts)
		end
	end
	local people = ZipperDB.people
	if type(people) == "table" then
		for guid in pairs(people) do
			local used = false
			for _, journey in pairs(journeys) do
				local with = type(journey) == "table" and journey.with or nil
				if type(with) == "table" and type(with[guid]) == "table" and #with[guid] > 0 then
					used = true
					break
				end
			end
			if not used then
				people[guid] = nil
			end
		end
		if not next(people) then
			ZipperDB.people = nil
		end
	end
	if not self:HistoryVisible() then
		self:ReleaseHistory()
	end
end

function ns.DB:JoinsAt(journey, when)
	local found = {}
	local with = journey and journey.with
	local people = ZipperDB and ZipperDB.people
	if type(with) ~= "table" or type(when) ~= "number" then
		return found
	end
	for guid, spans in pairs(with) do
		if type(spans) == "table" then
			for i = 1, #spans, 2 do
				local start = spans[i]
				if type(start) == "number" and math.abs(start - when) <= 2 then
					local person = type(people) == "table" and people[guid] or nil
					local name = type(person) == "table" and person.n or nil
					local classFile = type(person) == "table" and person.c or nil
					local level = type(person) == "table" and tonumber(person.lv) or 0
					local first = type(person) == "table" and type(person.t) == "number" and math.abs(person.t - when) <= 2
					if type(name) ~= "string" or name == "" then
						name = L["Someone"]
					end
					found[#found + 1] = {
						guid = guid,
						name = name,
						classFile = type(classFile) == "string" and classFile or nil,
						className = ns.ClassLabel and ns.ClassLabel(classFile) or nil,
						first = first and true or false,
						level = level,
					}
					break
				end
			end
		end
	end
	table.sort(found, function(a, b)
		return a.name < b.name
	end)
	return found
end

local function CompanyLiveEnd(self, journey)
	if journey == self.record and self.session then
		return self:Now()
	end
	local sessions = journey and journey.sessions
	local last = sessions and sessions[#sessions]
	return (last and (last.seen or last.s)) or 0
end

local function CompanyWindow(self, journey, session, t0, t1, liveEnd)
	if type(session) ~= "table" or type(session.s) ~= "number" then
		return nil
	end
	local startAt = session.s
	local stopAt = session.seen or session.s
	if session == self.session and journey == self.record then
		stopAt = math.max(stopAt, liveEnd)
	end
	if type(t0) == "number" and t0 > startAt then
		startAt = t0
	end
	if type(t1) == "number" and t1 < stopAt then
		stopAt = t1
	end
	if stopAt < startAt then
		return nil
	end
	return startAt, stopAt
end

local function SpanCovers(spans, when, liveEnd)
	for i = 1, #spans, 2 do
		local startAt = spans[i]
		local stopAt = spans[i + 1]
		if type(stopAt) ~= "number" then
			stopAt = liveEnd
		end
		if type(startAt) == "number" and when >= startAt and when <= stopAt then
			return true
		end
	end
	return false
end

local function SpanOverlap(spans, startAt, stopAt, liveEnd)
	local total = 0
	for i = 1, #spans, 2 do
		local left = spans[i]
		local right = spans[i + 1]
		if type(right) ~= "number" then
			right = liveEnd
		end
		if type(left) == "number" then
			if left < startAt then
				left = startAt
			end
			if right > stopAt then
				right = stopAt
			end
			if right > left then
				total = total + (right - left)
			end
		end
	end
	return total
end

-- A dungeon/raid with the party counts once a boss dies inside it. Walking in
-- and out does not. Leave and re-enter of the same instanceID within this
-- window is still the same run, so a second door click does not add another.
local COMPANY_INSTANCE_REENTER = 30 * 60

local function CompanyInstanceRuns(self, sessions)
	local runs = {}
	local open
	local function flush()
		if open and type(open.bossWhen) == "number" then
			runs[#runs + 1] = {
				bossWhen = open.bossWhen,
				instType = open.instType,
			}
		end
		open = nil
	end
	for i = 1, #(sessions or {}) do
		local session = sessions[i]
		self:EachEvent(session, function(when, kind, extra, mapID)
			extra = extra or 0
			mapID = mapID or 0
			if kind == ns.Kind.INSTANCE_ENTER then
				local instType, instanceID = self:ReadInstance(extra)
				if instType == ns.Instance.PARTY or instType == ns.Instance.RAID then
					local key
					if instanceID > 0 then
						key = instType .. ":" .. instanceID
					else
						key = instType .. ":m" .. tostring(mapID or 0)
					end
					if open and open.key == key and type(open.leftAt) == "number" and (when - open.leftAt) <= COMPANY_INSTANCE_REENTER then
						open.leftAt = nil
					else
						flush()
						open = {
							key = key,
							instType = instType,
						}
					end
				else
					flush()
				end
			elseif kind == ns.Kind.INSTANCE_LEAVE then
				if open then
					open.leftAt = when
				end
			elseif kind == ns.Kind.BOSS then
				if open and not open.leftAt and not open.bossWhen then
					open.bossWhen = when
				end
			end
		end)
	end
	flush()
	return runs
end

local function JourneyKey(journey)
	if not ZipperDB or type(ZipperDB.journeys) ~= "table" then
		return nil
	end
	for key, item in pairs(ZipperDB.journeys) do
		if item == journey then
			return key
		end
	end
	return nil
end

local function KeptSpans(self, journey, guid, spans, liveEnd)
	local copy = {}
	if type(spans) ~= "table" then
		return copy
	end
	for i = 1, #spans, 2 do
		local startAt = spans[i]
		local stopAt = spans[i + 1]
		local open = type(stopAt) ~= "number"
		local endAt = open and liveEnd or stopAt
		if type(startAt) == "number" and type(endAt) == "number" and self:SpanWorthKeeping(journey, guid, startAt, endAt) then
			copy[#copy + 1] = startAt
			copy[#copy + 1] = endAt
		end
	end
	return copy
end

function ns.DB:CompanyReport(journey, sessions, t0, t1)
	local list = {}
	local with = journey and journey.with
	if type(journey) ~= "table" or type(with) ~= "table" or type(sessions) ~= "table" then
		return list
	end
	local people = ZipperDB and ZipperDB.people or {}
	local liveEnd = CompanyLiveEnd(self, journey)
	local rows = {}
	for guid, spans in pairs(with) do
		local kept = KeptSpans(self, journey, guid, spans, liveEnd)
		if type(guid) == "string" and #kept > 0 then
			spans = kept
			local person = people[guid]
			local name = type(person) == "table" and person.n or nil
			if type(name) ~= "string" or name == "" then
				name = L["Someone"]
			end
			rows[guid] = {
				guid = guid,
				name = name,
				classFile = type(person) == "table" and person.c or nil,
				seconds = 0,
				quests = 0,
				accepts = 0,
				elites = 0,
				rares = 0,
				kills = 0,
				deaths = 0,
				dungeons = 0,
				raids = 0,
				spans = spans,
				metMap = type(person) == "table" and person.map or 0,
				metBy = type(person) == "table" and person.by or nil,
				metName = type(person) == "table" and person.bn or nil,
				metLevel = type(person) == "table" and person.lv or 0,
				earned = type(person) == "table" and person.ok or nil,
			}
		end
	end
	local viewer = JourneyKey(journey)
	for i = 1, #sessions do
		local session = sessions[i]
		local startAt, stopAt = CompanyWindow(self, journey, session, t0, t1, liveEnd)
		if startAt then
			for _, row in pairs(rows) do
				row.seconds = row.seconds + SpanOverlap(row.spans, startAt, stopAt, liveEnd)
			end
			self:EachEvent(session, function(when, kind, extra)
				if when >= startAt and when <= stopAt then
					for _, row in pairs(rows) do
						if SpanCovers(row.spans, when, liveEnd) then
							if kind == ns.Kind.QUEST_TURNIN then
								row.quests = row.quests + 1
							elseif kind == ns.Kind.QUEST_ACCEPT then
								row.accepts = row.accepts + 1
							elseif kind == ns.Kind.KILL then
								row.kills = row.kills + 1
								local _, elite, rare = self:ReadKill(extra)
								if elite then
									row.elites = row.elites + 1
								elseif rare then
									row.rares = row.rares + 1
								end
							elseif kind == ns.Kind.DEATH then
								row.deaths = row.deaths + 1
							end
						end
					end
				end
			end)
		end
	end
	local runs = CompanyInstanceRuns(self, sessions)
	for r = 1, #runs do
		local run = runs[r]
		local when = run.bossWhen
		if type(t0) == "number" and when < t0 then
			when = nil
		end
		if when and type(t1) == "number" and when > t1 then
			when = nil
		end
		if when then
			for _, row in pairs(rows) do
				if SpanCovers(row.spans, when, liveEnd) then
					if run.instType == ns.Instance.PARTY then
						row.dungeons = row.dungeons + 1
					elseif run.instType == ns.Instance.RAID then
						row.raids = row.raids + 1
					end
				end
			end
		end
	end
	for _, row in pairs(rows) do
		row.spans = nil
		if row.metBy and row.metBy ~= viewer then
			local other = ZipperDB.journeys and ZipperDB.journeys[row.metBy]
			row.metByName = (type(other) == "table" and other.name) or row.metName
			if type(row.metByName) ~= "string" or row.metByName == "" then
				row.metByName = L["another character"]
			end
		end
		row.metName = nil
		local earnedHere = type(row.earned) == "number"
		if earnedHere and type(t0) == "number" and row.earned < t0 then
			earnedHere = false
		end
		if earnedHere and type(t1) == "number" and row.earned > t1 then
			earnedHere = false
		end
		row.earned = nil
		if earnedHere or row.seconds >= 1 or row.quests > 0 or row.accepts > 0 or row.kills > 0 or row.deaths > 0 or row.dungeons > 0 or row.raids > 0 then
			list[#list + 1] = row
		end
	end
	table.sort(list, function(a, b)
		if a.seconds ~= b.seconds then
			return a.seconds > b.seconds
		end
		return a.name < b.name
	end)
	return list
end

function ns.DB:CompanyCacheKey(journey)
	local with = journey and journey.with
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
	local sessions = journey and journey.sessions or {}
	local last = sessions[#sessions]
	local seen = last and (last.seen or last.s) or 0
	local kills, quests = 0, 0
	for i = 1, #sessions do
		local session = sessions[i]
		kills = kills + (session.kills or 0)
		quests = quests + (session.quests or 0)
	end
	local bucket = 0
	if open > 0 and journey == self.record then
		bucket = math.floor(self:Now() / 30)
	end
	return spans .. ":" .. #sessions .. ":" .. seen .. ":" .. kills .. ":" .. quests .. ":" .. bucket
end

function ns.DB:CompanySpanIndex(journey)
	if type(journey) ~= "table" then
		return {}
	end
	local key = self:CompanyCacheKey(journey)
	if self.companySpanJourney == journey and self.companySpanKey == key and self.companySpans then
		return self.companySpans
	end
	local with = journey.with
	local people = ZipperDB and ZipperDB.people or {}
	local liveEnd = CompanyLiveEnd(self, journey)
	local index = {}
	if type(with) == "table" then
		for guid, spans in pairs(with) do
			local kept = KeptSpans(self, journey, guid, spans, liveEnd)
			if type(guid) == "string" and #kept > 0 then
				local person = people[guid]
				local name = type(person) == "table" and person.n or nil
				if type(name) ~= "string" or name == "" then
					name = L["Someone"]
				end
				index[#index + 1] = {
					guid = guid,
					name = name,
					classFile = type(person) == "table" and person.c or nil,
					spans = kept,
					liveEnd = liveEnd,
				}
			end
		end
		table.sort(index, function(a, b)
			return a.name < b.name
		end)
	end
	self.companySpanJourney = journey
	self.companySpanKey = key
	self.companySpans = index
	return index
end

function ns.DB:CompanyAt(journey, when)
	local found = {}
	if type(when) ~= "number" then
		return found
	end
	local index = self:CompanySpanIndex(journey)
	for i = 1, #index do
		local row = index[i]
		if self:CoveringStart(row.spans, when, row.liveEnd) then
			found[#found + 1] = row
		end
	end
	return found
end

function ns.DB:CompanyByGuid(journey, guid)
	if type(journey) ~= "table" or type(guid) ~= "string" then
		return nil
	end
	local key = self:CompanyCacheKey(journey)
	if self.companyReportJourney ~= journey or self.companyReportKey ~= key or not self.companyByGuid then
		local list = self:CompanyReport(journey, journey.sessions or {})
		local byGuid = {}
		for i = 1, #list do
			local row = list[i]
			if row.guid then
				byGuid[row.guid] = row
			end
		end
		self.companyReportJourney = journey
		self.companyReportKey = key
		self.companyByGuid = byGuid
	end
	return self.companyByGuid[guid]
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

local function MeasureWith(with)
	if type(with) ~= "table" then
		return 0
	end
	local bytes = 0
	for guid, spans in pairs(with) do
		bytes = bytes + 24 + #tostring(guid)
		if type(spans) == "table" then
			bytes = bytes + (#spans * 8)
		end
	end
	return bytes
end

function ns.DB:MeasurePeople()
	local people = ZipperDB and ZipperDB.people
	if type(people) ~= "table" then
		return 0
	end
	local bytes = 0
	for guid, row in pairs(people) do
		bytes = bytes + 32 + #tostring(guid)
		if type(row) == "table" then
			if type(row.n) == "string" then
				bytes = bytes + #row.n
			end
			if type(row.bn) == "string" then
				bytes = bytes + #row.bn
			end
			if type(row.c) == "string" then
				bytes = bytes + #row.c
			end
		end
	end
	return bytes
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

-- Stand-in for a loaded track. The five-minute size poll used to PackTrack
-- every table, which encoded the whole journey into temporary strings while
-- you stood still. Packed strings still report their real length.
local function EstimateTrack(track)
	if type(track) == "string" then
		return #track
	end
	if type(track) ~= "table" then
		return 0
	end
	local points = #(track.t or {})
	local events = #(track.ek or {})
	return 24 + (points * 12) + (events * 8)
end

function ns.DB:MeasureJourney(journey)
	if type(journey) ~= "table" or type(journey.tracks) ~= "table" then
		return 0
	end
	local bytes = #(journey.sessions or {}) * 48
	bytes = bytes + MeasureWith(journey.with)
	for _, track in pairs(journey.tracks) do
		bytes = bytes + EstimateTrack(track)
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
	local total = self:MeasurePeople()
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
			ns.Replay.playButton:SetText(L["Play"])
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

function ns.DB:SelectSessions(mode, index, indexHi)
	local sessions = self:Sessions()
	if mode == "all" then
		return sessions
	end
	if mode == "span" and index then
		local hi = indexHi or index
		local lo = index
		if hi < lo then
			lo, hi = hi, lo
		end
		local picked = {}
		for i = lo, hi do
			if sessions[i] then
				picked[#picked + 1] = sessions[i]
			end
		end
		return picked, lo
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
