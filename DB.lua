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

function ns.DB:Init()
	ZipperCharDB = ZipperCharDB or {}
	local db = ZipperCharDB
	if db.version ~= 2 or type(db.tracks) ~= "table" then
		self:Migrate(db)
	end
	db.version = 2
	if type(db.sessions) ~= "table" then
		db.sessions = {}
	end
	if type(db.tracks) ~= "table" then
		db.tracks = {}
	end
	if type(db.nextId) ~= "number" then
		db.nextId = #db.sessions + 1
	end
	self.char = db
	self.session = nil
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
	if not session or not self.char then
		return EmptyTrack()
	end
	local track = self.char.tracks[session.id]
	if not track then
		track = EmptyTrack()
		self.char.tracks[session.id] = track
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
	if self.session and not forceNew then
		self.session.seen = now
		self:NoteProgress()
		return self.session, true
	end

	local sessions = self.char.sessions
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

	local id = self.char.nextId or 1
	self.char.nextId = id + 1
	local session = {
		id = id,
		s = now,
		seen = now,
		kills = 0,
		quests = 0,
	}
	sessions[#sessions + 1] = session
	self.char.tracks[id] = EmptyTrack()
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

function ns.DB:EstimateCharacter()
	local db = ZipperCharDB
	if type(db) ~= "table" then
		return 0
	end
	local log = db.sizeLog
	db.sizeLog = nil
	local ok, bytes = pcall(self.EstimateBytes, self, db)
	db.sizeLog = log
	if not ok or type(bytes) ~= "number" then
		return nil
	end
	return bytes
end

function ns.DB:RememberSize(bytes, now)
	if type(bytes) ~= "number" or type(now) ~= "number" or not self.char then
		return
	end
	local log = self.char.sizeLog
	if type(log) ~= "table" then
		log = {}
		self.char.sizeLog = log
	end
	local last = log[#log]
	if type(last) == "table" and type(last[1]) == "number" and (now - last[1]) > (20 * 60) then
		log = {}
		self.char.sizeLog = log
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
		self.char.sizeLog = log
	end
	while #log > 300 do
		table.remove(log, 1)
	end
end

function ns.DB:SizeGrowth()
	local log = self.char and self.char.sizeLog
	if type(log) ~= "table" or #log < 2 then
		return nil
	end
	local first, last = log[1], log[#log]
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

function ns.DB:Purge()
	local fresh = {
		version = 2,
		sessions = {},
		tracks = {},
		nextId = 1,
	}
	ZipperCharDB = fresh
	self.char = fresh
	self.session = nil
	self:Open(self:Now(), true)
	if ns.Replay then
		ns.Replay.playing = false
		ns.Replay.statsKey = nil
		if ns.Replay.playButton then
			ns.Replay.playButton:SetText("Play")
		end
	end
	if ns.OnDataChanged then
		ns.OnDataChanged()
	end
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
