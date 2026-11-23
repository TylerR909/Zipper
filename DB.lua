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
local B64_ENC = {}
local B64_DEC = {}
local BYTE_CHAR = {}
for i = 1, 64 do
	local ch = B64:sub(i, i)
	B64_ENC[i - 1] = ch
	B64_DEC[ch:byte(1)] = i - 1
end
for i = 0, 255 do
	BYTE_CHAR[i] = string.char(i)
end

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
	local len = #bytes
	while index <= len do
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

local function SkipVar(bytes, index)
	local len = #bytes
	local steps = 0
	while index <= len do
		local byte = bytes:byte(index)
		index = index + 1
		if byte < 128 then
			return index
		end
		steps = steps + 1
		if steps > 4 then
			break
		end
	end
	return index
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
	local outN = 0
	local length = #raw
	local i = 1
	while i <= length do
		local a = raw:byte(i) or 0
		local b = raw:byte(i + 1) or 0
		local c = raw:byte(i + 2) or 0
		local chunk = a * 65536 + b * 256 + c
		outN = outN + 1
		out[outN] = B64_ENC[math.floor(chunk / 262144) % 64]
		outN = outN + 1
		out[outN] = B64_ENC[math.floor(chunk / 4096) % 64]
		outN = outN + 1
		if i + 1 <= length then
			out[outN] = B64_ENC[math.floor(chunk / 64) % 64]
		else
			out[outN] = "="
		end
		outN = outN + 1
		if i + 2 <= length then
			out[outN] = B64_ENC[chunk % 64]
		else
			out[outN] = "="
		end
		i = i + 3
	end
	return table.concat(out)
end

local function Decode64(text)
	text = text or ""
	if text:find("%s") then
		text = text:gsub("%s", "")
	end
	local out = {}
	local outN = 0
	local len = #text
	local i = 1
	while i <= len do
		local b1, b2, b3, b4 = text:byte(i, i + 3)
		local a = b1 and B64_DEC[b1] or 0
		local b = b2 and B64_DEC[b2] or 0
		local cc = (b3 and b3 ~= 61) and (B64_DEC[b3] or 0) or 0
		local dd = (b4 and b4 ~= 61) and (B64_DEC[b4] or 0) or 0
		local chunk = a * 262144 + b * 4096 + cc * 64 + dd
		outN = outN + 1
		out[outN] = BYTE_CHAR[math.floor(chunk / 65536) % 256]
		if b3 and b3 ~= 61 then
			outN = outN + 1
			out[outN] = BYTE_CHAR[math.floor(chunk / 256) % 256]
		end
		if b4 and b4 ~= 61 then
			outN = outN + 1
			out[outN] = BYTE_CHAR[chunk % 256]
		end
		i = i + 4
	end
	return table.concat(out)
end

local function SkipRuns(bytes, index, count)
	local filled = 0
	local ended = false
	while filled < count do
		local run
		run, index = ReadVar(bytes, index)
		if not run or run <= 0 then
			ended = true
			break
		end
		index = SkipVar(bytes, index)
		filled = filled + run
	end
	if not ended then
		index = SkipVar(bytes, index)
	end
	return index
end

local function DecodeHeader(packed)
	if type(packed) ~= "string" or packed:sub(1, 3) ~= "Z3:" then
		return nil, nil
	end
	local bytes = Decode64(packed:sub(4, 19))
	if bytes:byte(1) ~= 90 or bytes:byte(2) ~= 51 then
		return 0, 0
	end
	local index = 3
	local count, events
	count, index = ReadVar(bytes, index)
	events, index = ReadVar(bytes, index)
	return count or 0, events or 0
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
		raw[i] = BYTE_CHAR[buf[i]]
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

-- Forever regional unique names: UnitName's second return is surname, joined with a
-- space (see Blizzard Camelot NameUtil). GetUnitName wraps that for display.
function ns.UnitDisplayName(unit)
	unit = unit or "player"
	local function usable(value)
		if type(value) ~= "string" then
			return nil
		end
		if issecretvalue and issecretvalue(value) then
			return nil
		end
		if value == "" then
			return nil
		end
		return value
	end
	if GetUnitName then
		local full = usable(GetUnitName(unit, true))
		if full then
			-- Surname uses a space; a trailing -Realm can still appear on other flavors.
			return full:match("^([^-]+)") or full
		end
	end
	local name, second
	if UnitNameUnmodified then
		name, second = UnitNameUnmodified(unit)
	elseif UnitName then
		name, second = UnitName(unit)
	end
	name = usable(name)
	second = usable(second)
	if not name then
		return nil
	end
	if second and RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() then
		return name .. " " .. second
	end
	return name
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
	local name = journey.name or "Character"
	-- Regional unique names already include the surname; skip the long realm suffix.
	if RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() then
		return name
	end
	if journey.realm and journey.realm ~= "" then
		return name .. "-" .. journey.realm
	end
	return name
end

function ns.DB:EnsureStore()
	ZipperDB = ZipperDB or {}
	if type(ZipperDB.journeys) ~= "table" then
		ZipperDB.journeys = {}
	end
end

-- A body owns sessions and tracks. A stripped roster stub must not grow empty
-- tables or BindPlayer / Open will treat it as live history.
local function HasBody(journey)
	return type(journey) == "table"
		and type(journey.sessions) == "table"
		and type(journey.tracks) == "table"
end

local function ScopeOf(journey)
	if type(journey) == "table" and journey.scope == "private" then
		return "private"
	end
	return "global"
end

local function EnsureCharDB()
	if type(ZipperCharDB) ~= "table" then
		ZipperCharDB = {}
	end
	return ZipperCharDB
end

local function ClearLegacyCharKeys(db)
	if type(db) ~= "table" then
		return
	end
	db.sessions = nil
	db.tracks = nil
	db.version = nil
	db.nextId = nil
	db.sizeLog = nil
	db.levels = nil
	db.with = nil
	db.name = nil
	db.realm = nil
	db.class = nil
	db.bytes = nil
end

local function SessionCountOf(journey)
	if type(journey) ~= "table" then
		return 0
	end
	if type(journey.sessions) == "table" then
		return #journey.sessions
	end
	if type(journey.sessionCount) == "number" then
		return journey.sessionCount
	end
	return 0
end

local function NewStub(from, scope)
	local stub = {
		name = (from and from.name) or "Character",
		realm = (from and from.realm) or "",
		scope = scope or ScopeOf(from),
		sessionCount = SessionCountOf(from),
	}
	if from and type(from.class) == "string" and from.class ~= "" then
		stub.class = from.class
	end
	if from and type(from.bytes) == "number" then
		stub.bytes = from.bytes
	end
	return stub
end

local function EnsureBodyShape(journey)
	if type(journey) ~= "table" then
		return false
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
	if type(journey.version) ~= "number" then
		journey.version = 3
	end
	return true
end

local function CharBody()
	local db = type(ZipperCharDB) == "table" and ZipperCharDB or nil
	if db and HasBody(db.journey) then
		return db.journey
	end
	return nil
end

local function SyncStubFromBody(stub, body)
	if type(stub) ~= "table" or type(body) ~= "table" then
		return
	end
	if type(body.name) == "string" then
		stub.name = body.name
	end
	if type(body.realm) == "string" then
		stub.realm = body.realm
	end
	if type(body.class) == "string" and body.class ~= "" then
		stub.class = body.class
	end
	stub.sessionCount = SessionCountOf(body)
	if type(body.bytes) == "number" then
		stub.bytes = body.bytes
	end
end

local function PeopleRefsFromWith(with)
	local refs = {}
	if type(with) ~= "table" then
		return refs
	end
	for guid, spans in pairs(with) do
		if type(spans) == "table" and #spans > 0 then
			refs[guid] = true
		end
	end
	return refs
end

local function SnapshotPeopleRefs(stub, body)
	if type(stub) ~= "table" then
		return
	end
	local refs = PeopleRefsFromWith(body and body.with)
	if next(refs) then
		stub.peopleRefs = refs
	else
		stub.peopleRefs = nil
	end
end

local function StubHadPrivateData(roster)
	if type(roster) ~= "table" then
		return false
	end
	if roster.migrating or roster.pending then
		return true
	end
	if type(roster.sessionCount) == "number" and roster.sessionCount > 0 then
		return true
	end
	if type(roster.bytes) == "number" and roster.bytes > 0 then
		return true
	end
	return false
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

function ns.DB:JourneyAccessible(key)
	self:EnsureStore()
	if type(key) ~= "string" then
		return false
	end
	local roster = ZipperDB.journeys[key]
	if type(roster) ~= "table" then
		return false
	end
	local pending = roster.pending
	if pending == "toGlobal" or pending == "purgePrivate" then
		return key == self.playerKey and CharBody() ~= nil
	end
	if HasBody(roster) then
		return true
	end
	if ScopeOf(roster) == "private" then
		return key == self.playerKey and CharBody() ~= nil
	end
	return false
end

function ns.DB:JourneyBody(key)
	if not self:JourneyAccessible(key) then
		return nil
	end
	local roster = ZipperDB.journeys[key]
	if HasBody(roster) then
		return roster
	end
	if key == self.playerKey then
		return CharBody()
	end
	return nil
end

function ns.DB:RosterBytes(entry)
	if type(entry) ~= "table" then
		return 0
	end
	if HasBody(entry) then
		return self:JourneyBytes(entry)
	end
	if type(entry.bytes) == "number" then
		return entry.bytes
	end
	return 0
end

-- Dual-write first: destination gains the body while the source still holds it.
-- The next login's RecoverMigrating strips or wipes the source once both files saved.
-- Do not deep-copy: self.session must keep pointing at the same session object.
function ns.DB:MigrateSelfToPrivate()
	self:EnsureStore()
	local guid = self.playerKey
	if type(guid) ~= "string" then
		return false
	end
	local roster = ZipperDB.journeys[guid]
	local body = self.record
	if not HasBody(body) and HasBody(roster) then
		body = roster
	end
	if not HasBody(body) then
		body = CharBody()
	end
	if not HasBody(body) then
		return false
	end
	local charDB = EnsureCharDB()
	charDB.imported = true
	ClearLegacyCharKeys(charDB)
	-- Already CharDB-only: finish the stub and clear migrating.
	if not HasBody(roster) or roster ~= body then
		if CharBody() == body or charDB.journey == body then
			local stub = (type(roster) == "table" and not HasBody(roster)) and roster or NewStub(body, "private")
			stub.scope = "private"
			stub.pending = nil
			stub.migrating = nil
			SyncStubFromBody(stub, body)
			SnapshotPeopleRefs(stub, body)
			ZipperDB.journeys[guid] = stub
			charDB.journey = body
			body.migrating = nil
			self.record = body
			if self.viewKey == guid then
				self.char = body
			end
			return true
		end
	end
	-- First step: CharDB points at the live body; account still owns that same table.
	charDB.journey = body
	body.scope = "private"
	body.pending = nil
	body.migrating = true
	if type(roster) == "table" and roster == body then
		roster.scope = "private"
		roster.pending = nil
		roster.migrating = true
	else
		ZipperDB.journeys[guid] = body
		body.scope = "private"
		body.migrating = true
	end
	self.record = body
	if self.viewKey == guid then
		self.char = body
	end
	return true
end

function ns.DB:MigrateSelfToGlobal()
	self:EnsureStore()
	local guid = self.playerKey
	if type(guid) ~= "string" then
		return false
	end
	local charDB = EnsureCharDB()
	local body = CharBody() or self.record
	local roster = ZipperDB.journeys[guid]
	if not HasBody(body) then
		if HasBody(roster) then
			roster.scope = "global"
			roster.pending = nil
			roster.migrating = nil
			self.record = roster
			if self.viewKey == guid then
				self.char = roster
			end
			return true
		end
		return false
	end
	if type(roster) == "table" and not HasBody(roster) then
		if type(roster.name) == "string" then
			body.name = roster.name
		end
		if type(roster.realm) == "string" then
			body.realm = roster.realm
		end
		if type(roster.class) == "string" and roster.class ~= "" then
			body.class = roster.class
		end
	end
	-- First step: account owns the body; CharDB still points at it until next login.
	body.scope = "global"
	body.pending = nil
	body.migrating = true
	body.sessionCount = nil
	body.peopleRefs = nil
	ZipperDB.journeys[guid] = body
	charDB.imported = true
	ClearLegacyCharKeys(charDB)
	if charDB.journey ~= body then
		charDB.journey = body
	end
	self.record = body
	if self.viewKey == guid then
		self.char = body
	end
	return true
end

function ns.DB:ApplyPendingSelf()
	local guid = self.playerKey
	local roster = guid and ZipperDB.journeys[guid] or nil
	if type(roster) ~= "table" then
		return nil
	end
	local pending = roster.pending
	if pending == "toPrivate" then
		if self:MigrateSelfToPrivate() then
			self.pendingNotice = "toPrivate"
			return "toPrivate"
		end
	elseif pending == "toGlobal" then
		if self:MigrateSelfToGlobal() then
			self.pendingNotice = "toGlobal"
			return "toGlobal"
		end
	elseif pending == "purgePrivate" then
		local charDB = EnsureCharDB()
		charDB.journey = nil
		charDB.imported = true
		ClearLegacyCharKeys(charDB)
		local name = roster.name or "Character"
		local realm = roster.realm or ""
		local fresh = self:NewJourney(name, realm)
		fresh.class = roster.class
		fresh.scope = "global"
		ZipperDB.journeys[guid] = fresh
		self.record = fresh
		if self.viewKey == guid then
			self.char = fresh
		end
		self.pendingNotice = "purgePrivate"
		return "purgePrivate"
	end
	return nil
end

function ns.DB:RecoverMigrating()
	local guid = self.playerKey
	local roster = guid and ZipperDB.journeys[guid] or nil
	if type(roster) ~= "table" or not roster.migrating then
		return false
	end
	local charDB = EnsureCharDB()
	local charBody = CharBody()
	local accountBody = HasBody(roster) and roster or nil
	-- Both files loaded a body: finish by keeping the destination and dropping the source.
	if accountBody and charBody then
		if ScopeOf(roster) == "private" or roster.pending == "toPrivate" then
			charDB.journey = charBody
			ClearLegacyCharKeys(charDB)
			local stub = NewStub(charBody, "private")
			stub.migrating = nil
			stub.pending = nil
			SyncStubFromBody(stub, charBody)
			SnapshotPeopleRefs(stub, charBody)
			ZipperDB.journeys[guid] = stub
			charBody.migrating = nil
			self.record = charBody
		else
			charDB.journey = nil
			ClearLegacyCharKeys(charDB)
			accountBody.scope = "global"
			accountBody.pending = nil
			accountBody.migrating = nil
			accountBody.peopleRefs = nil
			ZipperDB.journeys[guid] = accountBody
			self.record = accountBody
		end
		if self.viewKey == guid then
			self.char = self.record
		end
		return true
	end
	-- CharDB has the body; account is already a stub. Finish the stub and clear migrating.
	if charBody and not accountBody then
		local stub = (type(roster) == "table" and not HasBody(roster)) and roster or NewStub(charBody, "private")
		stub.scope = "private"
		stub.pending = nil
		stub.migrating = nil
		SyncStubFromBody(stub, charBody)
		SnapshotPeopleRefs(stub, charBody)
		ZipperDB.journeys[guid] = stub
		charDB.journey = charBody
		charDB.imported = true
		ClearLegacyCharKeys(charDB)
		charBody.migrating = nil
		self.record = charBody
		if self.viewKey == guid then
			self.char = charBody
		end
		return true
	end
	-- Account still has the only body. Retry dual-write toward the pending destination.
	if accountBody and not charBody then
		if roster.pending == "toPrivate" or ScopeOf(roster) == "private" then
			return self:MigrateSelfToPrivate()
		end
		roster.migrating = nil
		roster.scope = "global"
		roster.pending = nil
		self.record = accountBody
		if self.viewKey == guid then
			self.char = accountBody
		end
		return true
	end
	roster.migrating = nil
	return false
end

-- wantGlobal true = Global checkbox on. Missing scope stays Global until toggled.
function ns.DB:SetGlobal(key, wantGlobal)
	self:EnsureStore()
	if type(key) ~= "string" then
		return false
	end
	local roster = ZipperDB.journeys[key]
	if type(roster) ~= "table" then
		return false
	end
	wantGlobal = wantGlobal and true or false
	if key == self.playerKey then
		if wantGlobal then
			if roster.pending == "toPrivate" and HasBody(roster) then
				roster.scope = "global"
				roster.pending = nil
				roster.migrating = nil
				return true
			end
			return self:MigrateSelfToGlobal()
		end
		if roster.pending == "toGlobal" then
			roster.scope = "private"
			roster.pending = nil
			return true
		end
		return self:MigrateSelfToPrivate()
	end
	if wantGlobal then
		if roster.pending == "toPrivate" and HasBody(roster) then
			roster.scope = "global"
			roster.pending = nil
			return true
		end
		if ScopeOf(roster) == "global" and roster.pending == nil then
			return true
		end
		roster.scope = "global"
		roster.pending = "toGlobal"
		return true
	end
	if roster.pending == "toGlobal" then
		roster.scope = "private"
		roster.pending = nil
		return true
	end
	if ScopeOf(roster) == "private" and not HasBody(roster) and roster.pending == nil then
		return true
	end
	roster.scope = "private"
	roster.pending = "toPrivate"
	return true
end

function ns.DB:BindPlayer()
	self:EnsureStore()
	local guid = UnitGUID and UnitGUID("player") or nil
	if type(guid) ~= "string" or guid == "" then
		return false
	end
	local name = ns.UnitDisplayName("player")
	if type(name) ~= "string" or name == "" then
		name = "Character"
	end
	local realm = GetRealmName and GetRealmName() or ""
	if type(realm) ~= "string" or (issecretvalue and issecretvalue(realm)) then
		realm = ""
	end
	-- With regional unique names the realm label is a ruleset bucket, not part of the
	-- character identity shown in the replay picker.
	if RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled() then
		realm = ""
	end
	self.playerKey = guid

	local roster = ZipperDB.journeys[guid]
	if type(roster) ~= "table" then
		roster = self:NewJourney(name, realm)
		ZipperDB.journeys[guid] = roster
	end
	roster.name = name
	roster.realm = realm
	local classFile
	if UnitClass then
		local _
		_, classFile = UnitClass("player")
	end
	if type(classFile) == "string" and not (issecretvalue and issecretvalue(classFile)) and classFile ~= "" then
		roster.class = classFile
	end

	local charDB = type(ZipperCharDB) == "table" and ZipperCharDB or nil
	if charDB and HasBody(charDB.journey) then
		charDB.imported = true
		ClearLegacyCharKeys(charDB)
	elseif charDB and not charDB.imported then
		if HasBody(roster) and #roster.sessions == 0 then
			if self:CopyLegacy(charDB, roster) then
				charDB.imported = true
				ClearLegacyCharKeys(charDB)
			end
		elseif not HasBody(roster) and ScopeOf(roster) == "global" and roster.pending == nil then
			EnsureBodyShape(roster)
			if self:CopyLegacy(charDB, roster) then
				charDB.imported = true
				ClearLegacyCharKeys(charDB)
			end
		end
	end

	self:RecoverMigrating()
	self:ApplyPendingSelf()

	roster = ZipperDB.journeys[guid]
	local body
	if ScopeOf(roster) == "private" or roster.pending == "toGlobal" or roster.pending == "purgePrivate" then
		body = CharBody()
		if not body and HasBody(roster) and (roster.pending == "toPrivate" or roster.migrating) then
			body = roster
		end
	elseif HasBody(roster) then
		body = roster
	else
		body = CharBody()
	end

	self.privateLoadFailed = nil
	if not HasBody(body) then
		if ScopeOf(roster) == "private" and not HasBody(roster) then
			if StubHadPrivateData(roster) then
				-- CharDB did not load a journey that should exist. Do not mint empty.
				self.record = nil
				self.privateLoadFailed = true
				self.viewKey = guid
				self.char = nil
				return true
			end
			-- Brand-new private character with no history yet.
			body = self:NewJourney(name, realm)
			body.class = roster.class
			local db = EnsureCharDB()
			db.imported = true
			ClearLegacyCharKeys(db)
			db.journey = body
			local stub = NewStub(roster, "private")
			stub.pending = nil
			stub.migrating = nil
			ZipperDB.journeys[guid] = stub
			roster = stub
		else
			EnsureBodyShape(roster)
			body = roster
		end
	elseif body == roster then
		EnsureBodyShape(body)
	else
		EnsureBodyShape(body)
		SyncStubFromBody(roster, body)
		SnapshotPeopleRefs(roster, body)
	end

	self.record = body
	if not self.viewKey or not ZipperDB.journeys[self.viewKey] then
		self.viewKey = guid
		self.char = body
	elseif self.viewKey == guid then
		self.char = body
	elseif not self:JourneyAccessible(self.viewKey) then
		self.viewKey = guid
		self.char = body
	else
		self.char = self:JourneyBody(self.viewKey) or body
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
	if not classFile and type(key) == "string" then
		local roster = ZipperDB and ZipperDB.journeys and ZipperDB.journeys[key]
		if type(roster) == "table" and type(roster.class) == "string" and roster.class ~= "" then
			classFile = roster.class
		end
	end
	if classFile and type(journey) == "table" then
		journey.class = classFile
	end
	return classFile
end

function ns.DB:SetView(key)
	self:EnsureStore()
	if not self:JourneyAccessible(key) then
		return false
	end
	local body = self:JourneyBody(key)
	if type(body) ~= "table" then
		return false
	end
	self.viewKey = key
	self.char = body
	return true
end

function ns.DB:CharacterList()
	self:EnsureStore()
	local list = {}
	for key, roster in pairs(ZipperDB.journeys) do
		if type(roster) == "table" then
			local body = self:JourneyBody(key)
			local sessions
			local bytes
			if body then
				sessions = #body.sessions
				bytes = self:JourneyBytes(body)
				if not HasBody(roster) then
					roster.bytes = bytes
					roster.sessionCount = sessions
					SnapshotPeopleRefs(roster, body)
				end
			elseif HasBody(roster) then
				sessions = #roster.sessions
				bytes = self:JourneyBytes(roster)
			else
				sessions = SessionCountOf(roster)
				bytes = self:RosterBytes(roster)
			end
			list[#list + 1] = {
				key = key,
				label = self:JourneyLabel(roster),
				sessions = sessions,
				bytes = bytes,
				current = key == self.playerKey,
				scope = ScopeOf(roster),
				pending = roster.pending,
				accessible = body ~= nil,
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
	local journeys = ZipperDB and ZipperDB.journeys
	if type(journeys) == "table" then
		for _, journey in pairs(journeys) do
			if journey ~= self.record and journey ~= self.char and owns(journey) then
				return journey
			end
		end
	end
	return self.record or self.char
end

local function PackJourneyHost(self, journey)
	if type(journey) ~= "table" or type(journey.tracks) ~= "table" then
		return nil
	end
	for id, track in pairs(journey.tracks) do
		if type(track) == "table" then
			journey.tracks[id] = self:PackTrack(track)
		end
	end
	local bytes = self:MeasureJourney(journey)
	journey.bytes = bytes
	return bytes
end

function ns.DB:Flush()
	self:EnsureStore()
	self:PruneIdleCompany(false)
	local packed = {}
	for _, journey in pairs(ZipperDB.journeys) do
		if HasBody(journey) then
			PackJourneyHost(self, journey)
			packed[journey] = true
		end
	end
	local record = self.record
	if HasBody(record) and not packed[record] then
		local bytes = PackJourneyHost(self, record)
		local guid = self.playerKey
		local stub = guid and ZipperDB.journeys[guid] or nil
		if type(stub) == "table" and stub ~= record then
			stub.bytes = bytes
			stub.sessionCount = SessionCountOf(record)
			SyncStubFromBody(stub, record)
			SnapshotPeopleRefs(stub, record)
		end
	elseif HasBody(record) and packed[record] then
		local guid = self.playerKey
		local roster = guid and ZipperDB.journeys[guid] or nil
		if type(roster) == "table" then
			SnapshotPeopleRefs(roster, record)
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

-- End of a session's played window. The open recording uses Now so standing
-- still (no new GPS samples) still advances the replay clock and list duration.
function ns.DB:SessionStop(session)
	if not session then
		return nil
	end
	if session == self.session then
		return self:Now()
	end
	return session.seen or session.s
end

function ns.DB:Sessions()
	return self.char and self.char.sessions or {}
end

function ns.DB:Track(session, host)
	host = host or self:HostFor(session)
	if not session or not host then
		return EmptyTrack()
	end
	if type(host.tracks) ~= "table" then
		host.tracks = {}
	end
	local track = host.tracks[session.id]
	if type(track) == "string" then
		local packedBytes = #track
		track = self:UnpackTrack(track)
		host.tracks[session.id] = track
		self:RememberTrackBytes(track, packedBytes)
	elseif type(track) ~= "table" then
		track = EmptyTrack()
		host.tracks[session.id] = track
	end
	return EnsureTrack(track)
end

function ns.DB:LoadedTrack(session, host)
	host = host or self:HostFor(session)
	if not session or not host or type(host.tracks) ~= "table" then
		return nil
	end
	local track = host.tracks[session.id]
	if type(track) == "table" then
		return track
	end
	return nil
end

function ns.DB:TrackCounts(session, host)
	host = host or self:HostFor(session)
	if not session or not host or type(host.tracks) ~= "table" then
		return 0, 0
	end
	local raw = host.tracks[session.id]
	if type(raw) == "table" then
		return #(raw.t or {}), #(raw.ek or {})
	end
	if type(raw) == "string" then
		local points, events = DecodeHeader(raw)
		if points then
			return points, events
		end
	end
	return 0, 0
end

-- Walk events without unpacking a packed track into retained tables.
-- Stops early when fn returns a truthy value.
function ns.DB:EachEvent(journey, session, fn)
	if not session or type(fn) ~= "function" then
		return
	end
	local host = journey or self:HostFor(session)
	local raw = host and type(host.tracks) == "table" and host.tracks[session.id] or nil
	if type(raw) == "table" then
		local ek = raw.ek
		if type(ek) ~= "table" then
			return
		end
		local et, em, ex, ey, ea = raw.et, raw.em, raw.ex, raw.ey, raw.ea
		for i = 1, #ek do
			if fn(et and et[i] or 0, ek[i], em and em[i] or 0, ex and ex[i] or 0, ey and ey[i] or 0, ea and ea[i] or 0) then
				return
			end
		end
		return
	end
	if type(raw) ~= "string" or raw:sub(1, 3) ~= "Z3:" then
		return
	end
	local _, totalEvents = DecodeHeader(raw)
	if not totalEvents or totalEvents <= 0 then
		return
	end
	local bytes = Decode64(raw:sub(4))
	if bytes:byte(1) ~= 90 or bytes:byte(2) ~= 51 then
		return
	end
	local index = 3
	local count, events
	count, index = ReadVar(bytes, index)
	events, index = ReadVar(bytes, index)
	for _ = 1, count * 4 do
		index = SkipVar(bytes, index)
	end
	index = SkipRuns(bytes, index, count)
	index = SkipRuns(bytes, index, count)
	local previous = 0
	for _ = 1, events do
		local delta, kind, mapID, x, y, extra
		delta, index = ReadVar(bytes, index)
		previous = previous + delta
		kind, index = ReadVar(bytes, index)
		mapID, index = ReadVar(bytes, index)
		x, index = ReadVar(bytes, index)
		y, index = ReadVar(bytes, index)
		extra, index = ReadVar(bytes, index)
		if fn(previous, kind, Unzig(mapID), Unzig(x), Unzig(y), Unzig(extra)) then
			return
		end
	end
end

local function PlainNumber(value)
	if type(value) ~= "number" or (issecretvalue and issecretvalue(value)) then
		return nil
	end
	return value
end

function ns.DB:NoteProgress()
	local session = self.session
	if not session then
		return
	end
	local level = PlainNumber(UnitLevel("player"))
	local xp = PlainNumber(UnitXP("player"))
	local maxXP = PlainNumber(UnitXPMax("player"))
	if not level or level <= 0 or not xp or not maxXP then
		return
	end
	-- During logout teardown the client can return 0/0 XP and a stale level.
	-- Keep the last good sample instead of wiping the session's end bar.
	local maxLevel = GetMaxPlayerLevel and PlainNumber(GetMaxPlayerLevel())
	if maxXP <= 0 and (not maxLevel or level < maxLevel) then
		return
	end
	if type(session.lv) == "number" and level < session.lv then
		return
	end
	if type(session.el) == "number" and level < session.el then
		return
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
	if self.session then
		if type(self.session.seen) ~= "number" or now > self.session.seen then
			self.session.seen = now
		end
		if type(self.session.el) ~= "number" or level > self.session.el then
			self.session.el = level
			self.session.ex = 0
			self.session.em = 0
		end
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

local GAP_EPS = 0.01

local function ClampFrac(xp, maxXP)
	if type(maxXP) ~= "number" or maxXP <= 0 or type(xp) ~= "number" then
		return nil
	end
	local frac = xp / maxXP
	if frac < 0 then
		return 0
	end
	if frac > 1 then
		return 1
	end
	return frac
end

-- Detects XP and whole-level gaps between consecutive saved sessions (e.g. after a crash).
-- Returns a map keyed by level: { missing = frac, whole = bool, t0 = sec, t1 = sec, ranges = { { from, to } } }.
function ns.DB:LevelGaps(journey)
	journey = journey or self.char
	if type(journey) ~= "table" then
		return {}
	end
	local sessions = journey.sessions
	if type(sessions) ~= "table" or #sessions < 2 then
		return {}
	end
	local dings = CollectDings(journey)
	local function highestDingIn(session)
		if type(session.s) ~= "number" then
			return nil
		end
		local stop = (type(session.seen) == "number" and session.seen or session.s) + 1
		local top
		for i = 1, #dings do
			local ding = dings[i]
			if ding.t >= session.s and ding.t <= stop then
				if not top or ding.lv > top then
					top = ding.lv
				end
			end
		end
		return top
	end
	local byLevel = {}
	local function addGap(lv, fromFrac, toFrac, whole, t0, t1)
		local diff = toFrac - fromFrac
		if not whole and diff < GAP_EPS then
			return
		end
		local entry = byLevel[lv]
		if not entry then
			entry = {
				missing = 0,
				whole = whole and true or false,
				t0 = t0,
				t1 = t1,
				ranges = {},
			}
			byLevel[lv] = entry
		else
			if not whole then
				entry.whole = false
			end
			if t0 and (not entry.t0 or t0 < entry.t0) then
				entry.t0 = t0
			end
			if t1 and (not entry.t1 or t1 > entry.t1) then
				entry.t1 = t1
			end
		end
		entry.missing = math.min(1, entry.missing + diff)
		entry.ranges[#entry.ranges + 1] = { from = fromFrac, to = toFrac, t0 = t0, t1 = t1 }
	end

	local prev
	for i = 1, #sessions do
		local curr = sessions[i]
		if type(curr) == "table" then
			local currLv = curr.lv
			local currEl = curr.el or currLv
			if prev and type(currLv) == "number" and currLv > 0 then
				local prevLv = type(prev.lv) == "number" and prev.lv or 0
				local prevDing = highestDingIn(prev) or 0
				local explainedTo = math.max(prevLv, prevDing)
				local prevEl = type(prev.el) == "number" and prev.el or 0
				local prevFrac = ClampFrac(prev.ex, prev.em)
				local currFrac = ClampFrac(curr.xp, curr.xm)
				local prevEnd = prev.seen or prev.s
				local currStart = curr.s
				local barTrusted = prevFrac ~= nil and prevEl >= explainedTo and prevEl > 0
				if barTrusted then
					if currLv == prevEl then
						if currFrac and (currFrac - prevFrac) >= GAP_EPS then
							addGap(currLv, prevFrac, currFrac, false, prevEnd, currStart)
						end
					elseif currLv > prevEl then
						if (1 - prevFrac) >= GAP_EPS then
							addGap(prevEl, prevFrac, 1, false, prevEnd, currStart)
						end
						for skipped = prevEl + 1, currLv - 1 do
							addGap(skipped, 0, 1, true, prevEnd, currStart)
						end
						if currFrac and currFrac >= GAP_EPS then
							addGap(currLv, 0, currFrac, false, prevEnd, currStart)
						end
					end
				elseif explainedTo > 0 and currLv > explainedTo then
					for skipped = explainedTo + 1, currLv - 1 do
						addGap(skipped, 0, 1, true, prevEnd, currStart)
					end
					if currFrac and currFrac >= GAP_EPS then
						addGap(currLv, 0, currFrac, false, prevEnd, currStart)
					end
				end
			end
			if (type(currLv) == "number" and currLv > 0) or (type(currEl) == "number" and currEl > 0) then
				prev = curr
			end
		end
	end
	return byLevel
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

-- Closed spans wholly inside [lo, hi]. A jump that sticks out past hi is skipped.
function ns.DB:RangeRecapText(lo, hi)
	local journey = self.record
	if type(journey) ~= "table" or type(lo) ~= "number" or type(hi) ~= "number" then
		return nil
	end
	if lo < 1 or hi < lo then
		return nil
	end
	local spans = self:LevelSpans(journey)
	local matched = {}
	local seconds = 0
	local t0, t1
	for i = 1, #spans do
		local span = spans[i]
		local top = span.lvTo or span.lv
		if span.lv >= lo and top <= hi and type(span.t1) == "number" then
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

-- Extra chat lines after a ding. Starter band at 6; every 10 levels a decade
-- plus a total. At 10 the decade is 1–10 and is also the total, so one line.
function ns.DB:MilestoneSummaryTexts(newLevel)
	local lines = {}
	if type(newLevel) ~= "number" or newLevel < 1 or newLevel ~= math.floor(newLevel) then
		return lines
	end
	local function add(lo, hi)
		local text = self:RangeRecapText(lo, hi)
		if text then
			lines[#lines + 1] = text
		end
	end
	if newLevel == 6 then
		add(1, 6)
		return lines
	end
	if newLevel == 10 then
		add(1, 10)
		return lines
	end
	if newLevel > 10 and newLevel % 10 == 0 then
		add(newLevel - 10, newLevel - 1)
		add(1, newLevel - 1)
	end
	return lines
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

local MAP_TYPE_ZONE = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3

local function MapTooWide(mapID)
	if not mapID or not C_Map or not C_Map.GetMapInfo then
		return false
	end
	local info = C_Map.GetMapInfo(mapID)
	local mapType = info and info.mapType
	return type(mapType) == "number" and mapType < MAP_TYPE_ZONE
end

local function SafeMaxLevel()
	local maxLv = GetMaxPlayerLevel and GetMaxPlayerLevel()
	if type(maxLv) == "number" and not (issecretvalue and issecretvalue(maxLv)) and maxLv >= 1 then
		return maxLv
	end
	return 60
end

local function MergeSpansDuration(spans, t0, t1)
	if #spans == 0 or not t0 or not t1 or t1 <= t0 then
		return 0
	end
	table.sort(spans, function(a, b)
		if a[1] == b[1] then
			return a[2] < b[2]
		end
		return a[1] < b[1]
	end)
	local total = 0
	local curA, curB
	for i = 1, #spans do
		local a, b = spans[i][1], spans[i][2]
		if a < t0 then
			a = t0
		end
		if b > t1 then
			b = t1
		end
		if b > a then
			if not curA then
				curA, curB = a, b
			elseif a <= curB then
				if b > curB then
					curB = b
				end
			else
				total = total + (curB - curA)
				curA, curB = a, b
			end
		end
	end
	if curA then
		total = total + (curB - curA)
	end
	return total
end

function ns.DB:SessionBytes(journey, session)
	if not Usable(session) then
		return 0
	end
	local host = journey or self:HostFor(session)
	local raw = host and type(host.tracks) == "table" and host.tracks[session.id] or nil
	local trackBytes = 0
	if type(raw) == "string" then
		trackBytes = #raw
	elseif type(raw) == "table" then
		-- Match MeasureJourney's per-track estimate without unpacking anything new.
		local points = type(raw.t) == "table" and #raw.t or 0
		local events = type(raw.ek) == "table" and #raw.ek or 0
		trackBytes = math.floor(4 + points * 5.2 + events * 9.5 + 0.5)
	end
	return 48 + trackBytes
end

-- Inspect a session's maps and events without unpacking a Z3 track into tables.
function ns.DB:InspectSession(journey, session)
	if not Usable(session) then
		return nil
	end
	local host = journey or self:HostFor(session)
	local raw = host and type(host.tracks) == "table" and host.tracks[session.id] or nil
	local startAt = session.s
	local stopAt = self:SessionStop(session) or startAt
	local duration = stopAt - startAt
	if duration < 0 then
		duration = 0
	end
	local cityMaps = ns.CityMaps or {}
	local Kind = ns.Kind
	local samples = 0
	local events = 0
	local hasMap = false
	local allCity = true
	local hasInstance = false
	local hasBoss = false
	local hasDeath = false
	local hasQuestAccept = false
	local hasCraftOrFish = false
	local hasKeptGroup = false
	local hasKeepEvent = false
	local hasOtherKeepEvent = false
	local idleSpans = {}
	local openIdle, openAfk

	local function handleEvent(when, kind, _, _, _, extra)
		extra = extra or 0
		local spec = ns.EventSpec and ns.EventSpec[kind]
		if kind == Kind.GROUP then
			if extra >= self.GROUP_KEPT then
				hasKeptGroup = true
				hasKeepEvent = true
			end
		elseif spec and spec.keepsSession then
			if spec.shape ~= "span" or extra ~= 1 then
				hasKeepEvent = true
				if kind ~= Kind.CRAFT and kind ~= Kind.FISH then
					hasOtherKeepEvent = true
				end
			end
		end
		if kind == Kind.INSTANCE_ENTER or kind == Kind.INSTANCE_LEAVE then
			hasInstance = true
		elseif kind == Kind.BOSS then
			hasBoss = true
			hasInstance = true
		elseif kind == Kind.DEATH then
			hasDeath = true
		elseif kind == Kind.QUEST_ACCEPT then
			hasQuestAccept = true
		elseif (kind == Kind.CRAFT or kind == Kind.FISH) and extra ~= 1 then
			hasCraftOrFish = true
		elseif kind == Kind.IDLE then
			if extra == 0 then
				if not openIdle then
					openIdle = when
				end
			elseif extra == 1 then
				if openIdle then
					idleSpans[#idleSpans + 1] = { openIdle, when }
					openIdle = nil
				end
			end
		elseif kind == Kind.AFK_START then
			if not openAfk then
				openAfk = when
			end
		elseif kind == Kind.AFK_END then
			if openAfk then
				idleSpans[#idleSpans + 1] = { openAfk, when }
				openAfk = nil
			end
		end
	end

	if type(raw) == "table" then
		local m = raw.m
		samples = type(raw.t) == "table" and #raw.t or 0
		if type(m) == "table" then
			for i = 1, samples do
				local mapID = m[i]
				if type(mapID) == "number" and mapID > 0 and not MapTooWide(mapID) then
					hasMap = true
					if not cityMaps[mapID] then
						allCity = false
					end
				end
			end
		end
		local ek = raw.ek
		if type(ek) == "table" then
			events = #ek
			local et, em, ex, ey, ea = raw.et, raw.em, raw.ex, raw.ey, raw.ea
			for i = 1, events do
				handleEvent(startAt + (et and et[i] or 0), ek[i], em and em[i] or 0, ex and ex[i] or 0, ey and ey[i] or 0, ea and ea[i] or 0)
			end
		end
	elseif type(raw) == "string" and raw:sub(1, 3) == "Z3:" then
		local bytes = Decode64(raw:sub(4))
		if bytes:byte(1) == 90 and bytes:byte(2) == 51 then
			local index = 3
			samples, index = ReadVar(bytes, index)
			events, index = ReadVar(bytes, index)
			-- Skip sample timestamps (t).
			for _ = 1, samples do
				index = SkipVar(bytes, index)
			end
			-- Read sample mapIDs (m).
			local prevM = 0
			for _ = 1, samples do
				local delta
				delta, index = ReadVar(bytes, index)
				prevM = prevM + Unzig(delta)
				if prevM > 0 and not MapTooWide(prevM) then
					hasMap = true
					if not cityMaps[prevM] then
						allCity = false
					end
				end
			end
			-- Skip sample x and y.
			for _ = 1, samples * 2 do
				index = SkipVar(bytes, index)
			end
			index = SkipRuns(bytes, index, samples)
			index = SkipRuns(bytes, index, samples)
			local prevT = 0
			for _ = 1, events do
				local delta, kind, mapID, x, y, extra
				delta, index = ReadVar(bytes, index)
				prevT = prevT + delta
				kind, index = ReadVar(bytes, index)
				mapID, index = ReadVar(bytes, index)
				x, index = ReadVar(bytes, index)
				y, index = ReadVar(bytes, index)
				extra, index = ReadVar(bytes, index)
				handleEvent(startAt + prevT, kind, Unzig(mapID), Unzig(x), Unzig(y), Unzig(extra))
			end
		end
	end

	if openIdle then
		idleSpans[#idleSpans + 1] = { openIdle, stopAt }
	end
	if openAfk then
		idleSpans[#idleSpans + 1] = { openAfk, stopAt }
	end

	local idleSeconds = MergeSpansDuration(idleSpans, startAt, stopAt)
	local idleRatio = duration > 0 and (idleSeconds / duration) or 0
	local xpGained = self:LevelsGained(session)
	local leveledUp = type(session.lv) == "number" and type(session.el) == "number" and session.el > session.lv
	local kills = session.kills or 0
	local quests = session.quests or 0
	local maxLv = SafeMaxLevel()
	local preCap = type(session.lv) ~= "number" or session.lv < maxLv
	local worthKeeping = (kills > 0)
		or (quests > 0)
		or leveledUp
		or (type(session.reach) == "number" and session.reach >= (ns.QUIET_YARDS or 250))
		or hasKeepEvent
		or (type(session.reach) ~= "number" and samples > 0)

	return {
		duration = duration,
		bytes = self:SessionBytes(host, session),
		samples = samples,
		events = events,
		kills = kills,
		quests = quests,
		xpGained = xpGained,
		leveledUp = leveledUp,
		reach = session.reach,
		preCap = preCap,
		cityOnly = hasMap and allCity and not hasInstance,
		hasInstance = hasInstance,
		hasBoss = hasBoss,
		hasDeath = hasDeath,
		hasQuestAccept = hasQuestAccept,
		hasCraftOrFish = hasCraftOrFish,
		hasKeptGroup = hasKeptGroup,
		hasKeepEvent = hasKeepEvent,
		hasOtherKeepEvent = hasOtherKeepEvent,
		idleSeconds = idleSeconds,
		idleRatio = idleRatio,
		quiet = not worthKeeping,
	}
end

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
	self:EachEvent(journey, session, function(_, kind, _, _, _, extra)
		extra = extra or 0
		local spec = ns.EventSpec and ns.EventSpec[kind]
		if kind == ns.Kind.GROUP then
			if extra >= self.GROUP_KEPT then
				keep = true
				return true
			end
		elseif spec and spec.keepsSession then
			if spec.shape ~= "span" or extra ~= 1 then
				keep = true
				return true
			end
		end
	end)
	if keep then
		return true
	end
	-- Older stops have no measured distance. Leave those alone.
	if type(session.reach) ~= "number" and self:TrackCounts(session, journey) > 0 then
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
	local s0 = session.s
	local s1 = session.seen or session.s
	table.remove(sessions, index)
	if type(journey.tracks) == "table" and session.id then
		journey.tracks[session.id] = nil
	end
	if type(journey.levels) == "table" and type(s0) == "number" and type(s1) == "number" then
		for i = #journey.levels, 1, -1 do
			local row = journey.levels[i]
			if type(row) == "table" and type(row.t) == "number" and row.t >= s0 and row.t <= s1 then
				table.remove(journey.levels, i)
			end
		end
	end
	self.eventGen = (self.eventGen or 0) + 1
	return true
end

function ns.DB:FinalizeSessionRemovals(touched, closedOnly)
	self:PruneIdleCompany(closedOnly and true or false)
	self.companySpanKey = nil
	self.companyReportKey = nil
	if type(touched) ~= "table" then
		return
	end
	self:EnsureStore()
	local journeys = ZipperDB.journeys
	for journey in pairs(touched) do
		if type(journey) == "table" and HasBody(journey) then
			journey.bytes = self:MeasureJourney(journey)
			if journey == self.record and self.playerKey and type(journeys) == "table" then
				local stub = journeys[self.playerKey]
				if type(stub) == "table" and stub ~= journey then
					SyncStubFromBody(stub, journey)
					SnapshotPeopleRefs(stub, journey)
				end
			end
		end
	end
end

function ns.DB:DeleteSession(journey, session)
	if type(journey) ~= "table" or not Usable(session) or session == self.session then
		return false, 0
	end
	local sessions = journey.sessions
	if type(sessions) ~= "table" then
		return false, 0
	end
	for i = #sessions, 1, -1 do
		if sessions[i] == session then
			local bytes = self:SessionBytes(journey, session)
			if self:RemoveSession(journey, i) then
				self:FinalizeSessionRemovals({ [journey] = true }, true)
				return true, bytes
			end
			return false, 0
		end
	end
	return false, 0
end

function ns.DB:DeleteSessions(items)
	if type(items) ~= "table" or #items == 0 then
		return 0, 0
	end
	local byJourney = {}
	for i = 1, #items do
		local entry = items[i]
		local journey = entry and entry.journey
		local session = entry and entry.session
		if type(journey) == "table" and Usable(session) and session ~= self.session then
			local set = byJourney[journey]
			if not set then
				set = {}
				byJourney[journey] = set
			end
			set[session] = true
		end
	end
	local dropped = 0
	local freedBytes = 0
	local touched = {}
	for journey, set in pairs(byJourney) do
		local sessions = journey.sessions
		if type(sessions) == "table" then
			for i = #sessions, 1, -1 do
				local session = sessions[i]
				if set[session] and session ~= self.session then
					local bytes = self:SessionBytes(journey, session)
					if self:RemoveSession(journey, i) then
						dropped = dropped + 1
						freedBytes = freedBytes + bytes
						touched[journey] = true
					end
				end
			end
		end
	end
	if dropped > 0 then
		self:FinalizeSessionRemovals(touched, true)
	end
	return dropped, freedBytes
end

function ns.DB:DropQuietTail()
	self:EnsureStore()
	local journeys = ZipperDB.journeys
	local now = self:Now()
	local maxSeconds = ns.QUIET_MAX_SECONDS or 900
	local dropped = 0
	local seenJourneys = {}
	local touched = {}

	local function checkTail(journey)
		if type(journey) ~= "table" or seenJourneys[journey] then
			return
		end
		seenJourneys[journey] = true
		local sessions = journey.sessions
		if type(sessions) ~= "table" or #sessions == 0 then
			return
		end
		local last = sessions[#sessions]
		if not Usable(last) or last == self.session then
			return
		end
		local seen = last.seen or last.s
		if type(seen) == "number" and (now - seen) <= ns.CONTINUE_SECONDS then
			return
		end
		if type(seen) == "number" and (seen - last.s) > maxSeconds then
			return
		end
		if self:SessionWorthKeeping(journey, last) then
			return
		end
		if self:RemoveSession(journey, #sessions) then
			dropped = dropped + 1
			touched[journey] = true
		end
	end

	if type(journeys) == "table" then
		for _, journey in pairs(journeys) do
			if HasBody(journey) then
				checkTail(journey)
			end
		end
	end
	if HasBody(self.record) then
		checkTail(self.record)
	end
	if dropped > 0 then
		self:FinalizeSessionRemovals(touched)
	end
	return dropped
end

function ns.DB:DropQuietSessions()
	self:EnsureStore()
	local journeys = ZipperDB.journeys
	if type(journeys) ~= "table" then
		return 0
	end
	local dropped = 0
	local seen = {}
	local touched = {}
	local function sweep(journey)
		if type(journey) ~= "table" or seen[journey] then
			return
		end
		seen[journey] = true
		local sessions = journey.sessions
		if type(sessions) ~= "table" then
			return
		end
		for i = #sessions, 1, -1 do
			local session = sessions[i]
			if session ~= self.session and not self:SessionWorthKeeping(journey, session) then
				if self:RemoveSession(journey, i) then
					dropped = dropped + 1
					touched[journey] = true
				end
			end
		end
	end
	for _, journey in pairs(journeys) do
		if HasBody(journey) then
			sweep(journey)
		end
	end
	if HasBody(self.record) then
		sweep(self.record)
	end
	if dropped > 0 then
		self:FinalizeSessionRemovals(touched, true)
	end
	return dropped
end

-- Dry-run session finder for automated cleanup presets.
function ns.DB:FindCleanupSessions(opts)
	self:EnsureStore()
	opts = opts or {}
	local preset = opts.preset or "quiet"
	local scope = opts.scope or "all"
	local maxSeconds = (type(opts.maxMinutes) == "number" and opts.maxMinutes > 0) and (opts.maxMinutes * 60) or nil
	local idlePct = type(opts.idlePct) == "number" and opts.idlePct or 80
	local protectPreCap = opts.protectPreCap ~= false
	local keepCraftFish = opts.keepCraftFish ~= false

	local targets = {}
	local seen = {}
	local function addJourney(key, journey)
		if type(journey) ~= "table" or not HasBody(journey) or seen[journey] then
			return
		end
		seen[journey] = true
		targets[#targets + 1] = { key = key, journey = journey, label = self:JourneyLabel(journey) }
	end

	if scope == "current" then
		local cur = self.record or self.char
		if cur then
			addJourney(self.playerKey or self.viewKey or "", cur)
		end
	else
		local journeys = ZipperDB.journeys
		if type(journeys) == "table" then
			for key, journey in pairs(journeys) do
				if HasBody(journey) then
					addJourney(key, journey)
				end
			end
		end
	end

	local matches = {}
	for t = 1, #targets do
		local entry = targets[t]
		local journey = entry.journey
		local sessions = journey.sessions
		if type(sessions) == "table" then
			for i = 1, #sessions do
				local session = sessions[i]
				if Usable(session) and session ~= self.session then
					local info = self:InspectSession(journey, session)
					if info then
						-- Hard milestone excludes for automated cleanups.
						local blocked = info.xpGained > 0
							or info.leveledUp
							or info.kills > 0
							or info.quests > 0
							or info.hasQuestAccept
							or info.hasInstance
							or info.hasBoss
							or info.hasDeath
							or info.hasKeptGroup
						if not blocked then
							local matched = false
							local reason = nil
							if preset == "quiet" then
								if info.quiet and (not maxSeconds or info.duration <= maxSeconds) then
									matched = true
									reason = L["Quiet stop"]
								end
							elseif preset == "idle" then
								if info.duration >= 60
									and (info.idleRatio * 100) >= idlePct
									and not info.hasCraftOrFish
									and not info.hasOtherKeepEvent
									and (not maxSeconds or info.duration <= maxSeconds)
								then
									matched = true
									reason = string.format(L["%d%% idle"], math.floor(info.idleRatio * 100 + 0.5))
								end
							elseif preset == "city" then
								if info.cityOnly
									and (not protectPreCap or not info.preCap)
									and (not keepCraftFish or not info.hasCraftOrFish)
									and (not maxSeconds or info.duration <= maxSeconds)
								then
									matched = true
									reason = L["City only"]
								end
							elseif preset == "short" then
								local limit = maxSeconds or (ns.QUIET_MAX_SECONDS or 900)
								if info.duration <= limit
									and not info.hasOtherKeepEvent
									and (not protectPreCap or not info.preCap)
									and (not keepCraftFish or not info.hasCraftOrFish)
								then
									matched = true
									reason = L["Short stop"]
								end
							end
							if matched then
								matches[#matches + 1] = {
									key = entry.key,
									journey = journey,
									charLabel = entry.label,
									session = session,
									duration = info.duration,
									bytes = info.bytes,
									reason = reason,
									info = info,
								}
							end
						end
					end
				end
			end
		end
	end

	table.sort(matches, function(a, b)
		if a.session.s == b.session.s then
			return (a.charLabel or "") < (b.charLabel or "")
		end
		return a.session.s > b.session.s
	end)
	return matches
end

function ns.DB:Open(now, forceNew)
	if not self.record then
		self:BindPlayer()
	end
	local host = self.record
	if not host then
		return nil, false
	end
	if not EnsureBodyShape(host) then
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
	self.eventGen = (self.eventGen or 0) + 1
	if kind ~= ns.Kind.GROUP and self:CompanyQualifies(kind) then
		self:CreditCompany(now)
	end
	return true
end

function ns.DB:LastSessionRole(session)
	session = session or self.session
	if not session then
		return nil
	end
	local track = self:Track(session)
	local ek = track and track.ek
	local ea = track and track.ea
	if type(ek) == "table" then
		for i = #ek, 1, -1 do
			if ek[i] == ns.Kind.ROLE then
				local val = ea and ea[i]
				if type(val) == "number" and val >= 0 then
					return val
				end
			end
		end
	end
	if type(session.role) == "number" and session.role >= 0 then
		return session.role
	end
	return nil
end

function ns.DB:LastInstanceDoor()
	local host = self.record
	local sessions = host and host.sessions
	if type(sessions) ~= "table" then
		return nil
	end
	for s = #sessions, 1, -1 do
		local session = sessions[s]
		local foundKind, foundExtra
		self:EachEvent(host, session, function(_, kind, _, _, _, extra)
			if kind == ns.Kind.INSTANCE_ENTER or kind == ns.Kind.INSTANCE_LEAVE then
				foundKind = kind
				foundExtra = extra
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
	local spec = ns.EventSpec and ns.EventSpec[kind]
	return (spec and spec.qualifiesCompany) and true or false
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
	local found = false
	for i = 1, #sessions do
		local session = sessions[i]
		if type(session) == "table" and type(session.s) == "number" and session.s <= stopAt then
			local stop = (session == self.session) and self:Now() or (session.seen or session.s)
			if stop >= startAt - 2 then
				self:EachEvent(journey, session, function(offset, kind)
					local when = session.s + (offset or 0)
					if when >= startAt and when <= stopAt and self:CompanyQualifies(kind) then
						found = true
						return true
					end
				end)
				if found then
					return true
				end
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
	local found = false
	for i = 1, #sessions do
		local session = sessions[i]
		if type(session) == "table" and type(session.s) == "number" and session.s <= startAt + 2 then
			local stop = (session == self.session) and self:Now() or (session.seen or session.s)
			if stop >= startAt - 2 then
				self:EachEvent(journey, session, function(offset, kind, _, _, _, extra)
					if kind == ns.Kind.GROUP then
						local when = session.s + (offset or 0)
						if (extra or 0) >= self.GROUP_KEPT and math.abs(when - startAt) <= 2 then
							found = true
							return true
						end
					end
				end)
				if found then
					return true
				end
			end
		end
	end
	return false
end

function ns.DB:SpanWorthKeeping(journey, guid, startAt, stopAt)
	local people = ZipperDB and ZipperDB.people
	local row = type(people) == "table" and people[guid] or nil
	if type(row) == "table" and type(row.ok) == "number" and math.abs(row.ok - startAt) <= 2 then
		return true
	end
	return self:RangeHasWork(journey, startAt, stopAt) or self:HasKeptMarker(journey, startAt)
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
	local found = false
	for i = 1, #sessions do
		local session = sessions[i]
		if type(session) == "table" and type(session.s) == "number" and session.s <= when + 2 then
			local stop = (session == self.session) and self:Now() or (session.seen or session.s)
			if stop >= when - 2 then
				self:EachEvent(journey, session, function(offset, kind)
					if kind == ns.Kind.GROUP then
						local at = session.s + (offset or 0)
						if math.abs(at - when) <= 2 then
							found = true
							return true
						end
					end
				end)
				if found then
					return true
				end
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
			self:EachEvent(journey, session, function(offset, kind)
				if kind == ns.Kind.GROUP then
					local when = session.s + (offset or 0)
					if not MarkerNear(when, starts) then
						needsDrop = true
						return true
					end
				end
			end)
			if needsDrop then
				local track = self:Track(session, journey)
				local et, ek, em, ex, ey, ea = {}, {}, {}, {}, {}, {}
				local count = 0
				for n = 1, #(track.ek or {}) do
					local kind = track.ek[n]
					local when = session.s + (track.et[n] or 0)
					if kind ~= ns.Kind.GROUP or MarkerNear(when, starts) then
						count = count + 1
						et[count] = track.et[n]
						ek[count] = kind
						em[count] = track.em[n]
						ex[count] = track.ex[n]
						ey[count] = track.ey[n]
						ea[count] = track.ea[n]
					end
				end
				track.et, track.ek, track.em = et, ek, em
				track.ex, track.ey, track.ea = ex, ey, ea
				self.eventGen = (self.eventGen or 0) + 1
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
	local hosts = {}
	local function addHost(journey)
		if type(journey) == "table" and not hosts[journey] then
			hosts[journey] = true
			hosts[#hosts + 1] = journey
		end
	end
	for _, journey in pairs(journeys) do
		if HasBody(journey) then
			addHost(journey)
		end
	end
	addHost(self.record)
	for i = 1, #hosts do
		local journey = hosts[i]
		local with = journey.with
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
	-- Private bodies are not in the account map for other characters. Keep a
	-- guid set on the stub so their logout does not wipe ZipperDB.people.
	for key, roster in pairs(journeys) do
		if type(roster) == "table" and not HasBody(roster) then
			if key == self.playerKey and HasBody(self.record) then
				SnapshotPeopleRefs(roster, self.record)
			end
		elseif type(roster) == "table" and HasBody(roster) then
			SnapshotPeopleRefs(roster, roster)
		end
	end
	local people = ZipperDB.people
	if type(people) ~= "table" then
		return
	end
	for guid in pairs(people) do
		local used = false
		for i = 1, #hosts do
			local with = hosts[i].with
			if type(with) == "table" and type(with[guid]) == "table" and #with[guid] > 0 then
				used = true
				break
			end
		end
		if not used then
			for _, roster in pairs(journeys) do
				if type(roster) == "table" and type(roster.peopleRefs) == "table" and roster.peopleRefs[guid] then
					used = true
					break
				end
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

local function CompanyInstanceRuns(self, journey, sessions)
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
		self:EachEvent(journey, session, function(offset, kind, mapID, _, _, extra)
			local when = session.s + (offset or 0)
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
	if type(journey) ~= "table" then
		return nil
	end
	local db = ns.DB
	if db and journey == db.record and type(db.playerKey) == "string" then
		return db.playerKey
	end
	local charBody = CharBody()
	if charBody and journey == charBody and db and type(db.playerKey) == "string" then
		return db.playerKey
	end
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
			local activeRows = {}
			for _, row in pairs(rows) do
				local overlap = SpanOverlap(row.spans, startAt, stopAt, liveEnd)
				if overlap > 0 then
					row.seconds = row.seconds + overlap
					activeRows[#activeRows + 1] = row
				else
					local spans = row.spans
					for s = 1, #spans, 2 do
						local left = spans[s]
						local right = spans[s + 1]
						if type(right) ~= "number" then
							right = liveEnd
						end
						if type(left) == "number" and right >= startAt and left <= stopAt then
							activeRows[#activeRows + 1] = row
							break
						end
					end
				end
			end
			if #activeRows > 0 then
				self:EachEvent(journey, session, function(offset, kind, _, _, _, extra)
					local when = session.s + (offset or 0)
					if when >= startAt and when <= stopAt then
						if kind == ns.Kind.QUEST_TURNIN or kind == ns.Kind.QUEST_ACCEPT or kind == ns.Kind.KILL or kind == ns.Kind.DEATH then
							for r = 1, #activeRows do
								local row = activeRows[r]
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
					end
				end)
			end
		end
	end
	local runs = CompanyInstanceRuns(self, journey, sessions)
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
	return spans .. ":" .. #sessions .. ":" .. (self.eventGen or 0) .. ":" .. kills .. ":" .. quests .. ":" .. bucket
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

-- Chat lookup of people you have actually played with. One letter matches too
-- much of an account roster, and the list stops so a short query stays readable.
ns.DB.SEARCH_MIN = 2
ns.DB.SEARCH_LIMIT = 8

local function SearchLetters(text)
	local count, i = 0, 1
	local size = #text
	while i <= size do
		count = count + 1
		local byte = text:byte(i)
		if byte < 128 then
			i = i + 1
		elseif byte < 224 then
			i = i + 2
		elseif byte < 240 then
			i = i + 3
		else
			i = i + 4
		end
	end
	return count
end

local function SearchRank(name, query)
	local lower = name:lower()
	local at = string.find(lower, query, 1, true)
	if not at then
		return nil
	end
	local rank = 2
	if at == 1 then
		rank = 0
	else
		local prev = lower:byte(at - 1)
		-- A space or hyphen starts the next word, as in "Dracy Heartsong".
		if prev == 32 or prev == 45 then
			rank = 1
		end
	end
	return rank, at, lower
end

local function SearchSpanSeconds(spans, liveEnd)
	local seconds = 0
	if type(spans) ~= "table" then
		return 0
	end
	for i = 1, #spans, 2 do
		local startAt = spans[i]
		local stopAt = spans[i + 1]
		if type(stopAt) ~= "number" then
			stopAt = liveEnd
		end
		if type(startAt) == "number" and type(stopAt) == "number" and stopAt > startAt then
			seconds = seconds + (stopAt - startAt)
		end
	end
	return seconds
end

local function SearchHosts(self)
	local hosts = {}
	local function add(key, journey)
		if type(key) ~= "string" or type(journey) ~= "table" then
			return
		end
		local host = hosts[key]
		if not host then
			host = { key = key }
			hosts[key] = host
			hosts[#hosts + 1] = host
		end
		if HasBody(journey) then
			host.body = journey
		else
			host.stub = journey
		end
	end
	local journeys = ZipperDB and ZipperDB.journeys
	if type(journeys) == "table" then
		for key, journey in pairs(journeys) do
			add(key, journey)
		end
	end
	if type(self.playerKey) == "string" and HasBody(self.record) then
		add(self.playerKey, self.record)
	end
	return hosts
end

local function SearchCompanions(self, guid)
	local list = {}
	local hosts = SearchHosts(self)
	for i = 1, #hosts do
		local host = hosts[i]
		if host.key ~= guid then
			local body = host.body
			local seconds = 0
			local linked = false
			if body and type(body.with) == "table" then
				local spans = body.with[guid]
				if type(spans) == "table" and #spans > 0 then
					linked = true
					seconds = SearchSpanSeconds(spans, CompanyLiveEnd(self, body))
				end
			end
			if not linked then
				local refs = host.stub and host.stub.peopleRefs
				if type(refs) ~= "table" and body then
					refs = body.peopleRefs
				end
				if type(refs) == "table" and refs[guid] then
					linked = true
				end
			end
			if linked then
				local source = body or host.stub
				list[#list + 1] = {
					name = self:JourneyLabel(source),
					seconds = seconds,
				}
			end
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

local function SearchWith(list)
	if #list == 0 then
		return nil
	end
	local extra = 0
	local shown = #list
	if shown > 3 then
		extra = shown - 3
		shown = 3
	end
	local timed, quiet = {}, {}
	for i = 1, shown do
		local item = list[i]
		if item.seconds >= 1 then
			timed[#timed + 1] = string.format(L["%s with %s"], PlayedWords(item.seconds), item.name)
		else
			quiet[#quiet + 1] = item.name
		end
	end
	local parts = {}
	if #timed > 0 then
		parts[#parts + 1] = table.concat(timed, ", ")
	end
	if #quiet > 0 then
		parts[#parts + 1] = string.format(L["With %s"], table.concat(quiet, ", "))
	end
	local text = table.concat(parts, ". ")
	if extra > 0 and text ~= "" then
		text = text .. ", " .. string.format(L["and %d more"], extra)
	end
	return text
end

local function SearchMet(row)
	local metName = type(row.bn) == "string" and row.bn ~= "" and row.bn or nil
	if not metName and type(row.by) == "string" and ZipperDB and type(ZipperDB.journeys) == "table" then
		local other = ZipperDB.journeys[row.by]
		if type(other) == "table" then
			metName = ns.DB:JourneyLabel(other)
		end
	end
	local where = MapName(row.map)
	local level = tonumber(row.lv) or 0
	if metName and where then
		return string.format(L["First met in %s on %s"], where, metName)
	end
	if metName then
		return string.format(L["First met on %s"], metName)
	end
	if where and level > 0 then
		return string.format(L["First met in %s at level %d"], where, level)
	end
	if where then
		return string.format(L["First met in %s"], where)
	end
	return nil
end

function ns.DB:SearchPeople(query)
	if type(query) ~= "string" or (issecretvalue and issecretvalue(query)) then
		return "short", {}, 0
	end
	query = string.lower(query:match("^%s*(.-)%s*$") or "")
	if SearchLetters(query) < self.SEARCH_MIN then
		return "short", {}, 0
	end
	local people = ZipperDB and ZipperDB.people
	if type(people) ~= "table" then
		return "none", {}, 0
	end
	local hits = {}
	for guid, row in pairs(people) do
		local name = type(row) == "table" and row.n or nil
		if type(guid) == "string" and type(name) == "string" and name ~= "" and not (issecretvalue and issecretvalue(name)) then
			local rank, at, lower = SearchRank(name, query)
			if rank then
				hits[#hits + 1] = {
					guid = guid,
					name = name,
					row = row,
					rank = rank,
					at = at,
					lower = lower,
				}
			end
		end
	end
	table.sort(hits, function(a, b)
		if a.rank ~= b.rank then
			return a.rank < b.rank
		end
		if a.at ~= b.at then
			return a.at < b.at
		end
		if a.lower ~= b.lower then
			return a.lower < b.lower
		end
		return a.guid < b.guid
	end)
	local total = #hits
	local limit = self.SEARCH_LIMIT
	if total > limit then
		for i = total, limit + 1, -1 do
			hits[i] = nil
		end
	end
	local rows = {}
	for i = 1, #hits do
		local hit = hits[i]
		local row = hit.row
		local classFile = type(row.c) == "string" and row.c ~= "" and row.c or nil
		local className = classFile and ns.ClassLabel and ns.ClassLabel(classFile) or nil
		if type(className) ~= "string" or className == "" then
			className = nil
		end
		local detail = SearchWith(SearchCompanions(self, hit.guid)) or SearchMet(row)
		local text = hit.name
		if className then
			text = text .. ", " .. className
		end
		if detail and detail ~= "" then
			text = text .. ". " .. detail
		end
		text = text .. "."
		rows[#rows + 1] = {
			name = hit.name,
			classFile = classFile,
			text = text,
		}
	end
	if #rows == 0 then
		return "none", rows, 0
	end
	return "ok", rows, total
end

function ns.DB:Stats()
	local sessions = self:Sessions()
	local points, events = 0, 0
	for i = 1, #sessions do
		local p, e = self:TrackCounts(sessions[i], self.char)
		points = points + p
		events = events + e
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

-- Fitted to packed Z3. Used so a settings refresh can size a live track
-- without encoding it. Exact again on logout, when Flush packs first.
local POINT_BYTES = 5.802
local EVENT_BYTES = 14

function ns.DB:RememberTrackBytes(track, packedBytes)
	if type(track) ~= "table" or type(packedBytes) ~= "number" then
		return
	end
	if not self.trackBytes then
		self.trackBytes = setmetatable({}, { __mode = "k" })
	end
	self.trackBytes[track] = {
		bytes = packedBytes,
		points = #(track.t or {}),
		events = #(track.ek or {}),
	}
end

local function EstimateUnpackedTrack(track)
	local points = #(track.t or {})
	local events = #(track.ek or {})
	local remembered = ns.DB.trackBytes and ns.DB.trackBytes[track]
	local bytes
	if type(remembered) == "table" and type(remembered.bytes) == "number" then
		bytes = remembered.bytes
			+ (points - (remembered.points or 0)) * POINT_BYTES
			+ (events - (remembered.events or 0)) * EVENT_BYTES
	else
		bytes = points * POINT_BYTES + events * EVENT_BYTES
	end
	bytes = math.floor(bytes + 0.5)
	if bytes < 0 then
		bytes = 0
	end
	return bytes
end

function ns.DB:MeasureJourney(journey)
	if type(journey) ~= "table" or type(journey.tracks) ~= "table" then
		return 0
	end
	local bytes = #(journey.sessions or {}) * 48
	bytes = bytes + MeasureWith(journey.with)
	for _, track in pairs(journey.tracks) do
		if type(track) == "string" then
			bytes = bytes + #track
		elseif type(track) == "table" then
			bytes = bytes + EstimateUnpackedTrack(track)
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
	local total = self:MeasurePeople()
	local counted = {}
	for key, roster in pairs(ZipperDB.journeys) do
		if type(roster) == "table" then
			local body = self:JourneyBody(key)
			if body and not counted[body] then
				counted[body] = true
				total = total + self:JourneyBytes(body)
				if not HasBody(roster) then
					roster.bytes = body.bytes
					roster.sessionCount = SessionCountOf(body)
				end
			elseif not body then
				total = total + self:RosterBytes(roster)
			end
		end
	end
	if HasBody(self.record) and not counted[self.record] then
		total = total + self:JourneyBytes(self.record)
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
	local roster = key and ZipperDB.journeys[key] or nil
	if not key or type(roster) ~= "table" then
		return false
	end
	local removingCurrent = key == self.playerKey
	if removingCurrent then
		local name = (self.record and self.record.name) or roster.name or "Character"
		local realm = (self.record and self.record.realm) or roster.realm or ""
		local class = (self.record and self.record.class) or roster.class
		local charDB = EnsureCharDB()
		charDB.journey = nil
		charDB.imported = true
		ClearLegacyCharKeys(charDB)
		local fresh = self:NewJourney(name, realm)
		fresh.class = class
		fresh.scope = "global"
		ZipperDB.journeys[key] = fresh
		self.record = fresh
		self.session = nil
		if self.viewKey == key then
			self.char = fresh
		end
		self:Open(self:Now(), true)
	elseif HasBody(roster) then
		-- Body still in the account file (Global or pending toPrivate).
		ZipperDB.journeys[key] = nil
		if self.viewKey == key then
			self.viewKey = self.playerKey
			self.char = self.record
		end
	else
		-- Body only on that character's CharDB. Keep the stub until they log in.
		roster.scope = "private"
		roster.pending = "purgePrivate"
		roster.migrating = nil
		roster.bytes = 0
		roster.sessionCount = 0
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
