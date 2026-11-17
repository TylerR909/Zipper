local _, ns = ...
local L = ns.L

local WORLD = 0

-- Places.lua reads this. It has to load after this file.
ns.Viz.WhereOrder = {
	{ key = WORLD, text = "Open world", r = 0.93, g = 0.78, b = 0.35 },
	{ key = ns.Instance.PARTY, text = "Dungeons", r = 1.00, g = 0.40, b = 0.70 },
	{ key = ns.Instance.RAID, text = "Raids", r = 0.72, g = 0.36, b = 0.55 },
	{ key = ns.Instance.PVP, text = "Battlegrounds", r = 0.45, g = 0.75, b = 1.00 },
	{ key = ns.Instance.ARENA, text = "Arenas", r = 0.75, g = 0.40, b = 1.00 },
	{ key = ns.Instance.SCENARIO, text = "Scenarios", r = 0.20, g = 0.90, b = 0.90 },
	{ key = ns.Instance.OTHER, text = "Other instances", r = 0.62, g = 0.62, b = 0.68 },
}

local function slices(order, bag)
	local list = {}
	for i = 1, #order do
		local row = order[i]
		list[#list + 1] = {
			label = L[row.text],
			value = bag[row.key] or 0,
			r = row.r,
			g = row.g,
			b = row.b,
		}
	end
	return list
end

local function foot(list)
	local total = 0
	local missing = {}
	for i = 1, #list do
		local value = list[i].value or 0
		total = total + value
		if value <= 0 then
			missing[#missing + 1] = list[i].label
		end
	end
	local clock = ns.Viz:Clock(total)
	if #missing == 0 then
		return string.format(L["%s total."], clock)
	end
	local listText
	if #missing == 1 then
		listText = missing[1]
	else
		local head = missing[1]
		for i = 2, #missing - 1 do
			head = head .. ", " .. missing[i]
		end
		listText = string.format(L["%s, or %s"], head, missing[#missing])
	end
	return string.format(L["%s total. No time in %s."], clock, listText)
end

local IDLE_PART = { key = "idle", text = "Idle", r = 0.62, g = 0.62, b = 0.68 }

-- One row per level. Parts are the places that actually have time, then idle.
-- The same rows feed stacked bars (absolute) and share (each level fills the bar).
local function levelModel(summary)
	local levels = summary.levels or {}
	local order = ns.Viz.WhereOrder or {}
	local totals = {}
	local idleTotal = 0
	for i = 1, #levels do
		local bag = levels[i].where or {}
		for p = 1, #order do
			local key = order[p].key
			totals[key] = (totals[key] or 0) + (bag[key] or 0)
		end
		idleTotal = idleTotal + (levels[i].idle or 0)
	end
	local parts = {}
	for p = 1, #order do
		local row = order[p]
		if (totals[row.key] or 0) > 0 then
			parts[#parts + 1] = {
				key = row.key,
				text = row.text,
				r = row.r,
				g = row.g,
				b = row.b,
			}
		end
	end
	if idleTotal > 0 then
		parts[#parts + 1] = IDLE_PART
	end
	local rows = {}
	for i = 1, #levels do
		local src = levels[i]
		local bag = src.where or {}
		local out = { label = string.format(L["Lv %d"], src.lv) }
		for p = 1, #parts do
			local key = parts[p].key
			if key == "idle" then
				out.idle = src.idle or 0
			else
				out[key] = bag[key] or 0
			end
		end
		rows[#rows + 1] = out
	end
	return rows, parts
end

ns.Viz:Register({
	id = "where",
	label = L["Where"],
	title = L["Where time went"],
	note = "",
	display = "pie",
	displays = { "pie", "stacks", "share" },
	Build = function(summary)
		local list = slices(ns.Viz.WhereOrder, summary.where or {})
		local idle = summary.idle or 0
		if idle > 0 then
			list[#list + 1] = {
				label = L["Idle"],
				value = idle,
				r = IDLE_PART.r,
				g = IDLE_PART.g,
				b = IDLE_PART.b,
			}
		end
		local rows, parts = levelModel(summary)
		return {
			slices = list,
			foot = foot(list),
			rows = rows,
			parts = parts,
			clock = true,
		}
	end,
})
