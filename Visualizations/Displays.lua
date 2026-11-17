local _, ns = ...
local L = ns.L

-- Display types. A chart module picks one by name. The model is a plain table
-- from that module's Build. Shapes:
--   pie      { slices = { label, value, r, g, b }, foot }
--   meters   { rows = slices, percent }
-- Pie and meters read slices, or rows when slices is absent. A chart can list
-- both and keep one Build.
--   columns  { rows = { label, kills, turnins, r, g, b }, footer }
--   groups   same rows as columns. Kill bars and turn-in bars use separate scales.
--   stacks   { rows, parts = { key, text, r, g, b }, footer, clock }
--   share    parts, when the model has them. Otherwise grouped and solo.
--            clock formats stacks and that share as hours.
--   pyramid  { rows = { label, grouped, solo }, footer }
--   zones    { zones, footer }
-- ns.Viz:SetDisplay(chartId, displayId) swaps the drawing when the chart lists
-- that display. The window shows the list when it has more than one name.

local KILL_R, KILL_G, KILL_B = 1.00, 0.25, 0.20
local TURNIN_R, TURNIN_G, TURNIN_B = 0.24, 0.70, 0.44
local GROUP_R, GROUP_G, GROUP_B = 0.35, 0.62, 0.95
local SOLO_R, SOLO_G, SOLO_B = 0.78, 0.76, 0.70
local ZONE_R, ZONE_G, ZONE_B = 0.93, 0.78, 0.35

local function ShownSlices(slices)
	local shown = {}
	local total = 0
	for i = 1, #slices do
		local value = slices[i].value or 0
		if value > 0 then
			shown[#shown + 1] = slices[i]
			total = total + value
		end
	end
	return shown, total
end

local function DrawLegend(viz, shown, total, rowY)
	for i = 1, #shown do
		local slice = shown[i]
		local swatch = viz:Bar()
		swatch:SetPoint("TOPLEFT", 0, -rowY)
		swatch:SetSize(10, 10)
		swatch:SetVertexColor(slice.r, slice.g, slice.b, 1)
		local name = viz:Font()
		name:SetPoint("TOPLEFT", 16, -(rowY - 2))
		name:SetWidth(math.floor(viz:Width() * 0.42))
		name:SetTextColor(0.78, 0.76, 0.70)
		name:SetText(slice.label)
		local value = viz:Font()
		value:SetPoint("TOPRIGHT", 0, -(rowY - 2))
		value:SetWidth(math.floor(viz:Width() * 0.5))
		value:SetJustifyH("RIGHT")
		value:SetTextColor(0.93, 0.90, 0.78)
		local pct = math.floor((slice.value / total) * 100 + 0.5)
		value:SetText(string.format("%s   %d%%", ns.Viz:Clock(slice.value), pct))
		rowY = rowY + 18
	end
	return rowY
end

local function DrawFoot(viz, text, rowY)
	if text and text ~= "" then
		local note = viz:Font()
		note:SetPoint("TOPLEFT", 0, -(rowY + 6))
		note:SetPoint("RIGHT", viz.content, "RIGHT", 0, 0)
		note:SetWordWrap(true)
		note:SetTextColor(0.62, 0.60, 0.54)
		note:SetText(text)
		local width = viz:Width()
		local lines = 2
		if width > 40 then
			lines = math.ceil(#text / math.floor(width / 6))
		end
		if lines < 1 then
			lines = 1
		elseif lines > 4 then
			lines = 4
		end
		rowY = rowY + 6 + (lines * 14)
	end
	viz:ContentHeight(rowY + 4)
end

-- Filled wedges are spokes from the center. CreateLine does not fill, and a
-- line inside the scroll child does not draw. A cooldown wedge in that same
-- child also draws nothing. A pixel plug over the middle cuts the tips off.
local function DrawPie(viz, slices, foot)
	local shown, total = ShownSlices(slices)
	if total <= 0 then
		viz:Empty()
		return
	end
	local width = viz:Width()
	local radius = 58
	if width < (radius * 2) + 8 then
		radius = math.floor((width - 8) / 2)
	end
	if radius < 32 then
		radius = 32
	end
	local cx = width / 2
	local cy = 8 + radius
	local steps = 96
	local used = 0
	local angle = -math.pi / 2
	for i = 1, #shown do
		local count
		if i == #shown then
			count = steps - used
		else
			count = math.floor((shown[i].value / total) * steps + 0.5)
			if count < 1 then
				count = 1
			end
			local reserve = #shown - i
			if used + count > steps - reserve then
				count = steps - used - reserve
			end
			if count < 1 then
				count = 0
			end
		end
		if count > 0 then
			local sweep = (count / steps) * (math.pi * 2)
			local step = sweep / count
			for n = 0, count - 1 do
				local mid = angle - ((n + 0.5) * step)
				local thick = (radius * step) + 2
				if thick < 2 then
					thick = 2
				end
				-- Width is the radius. Rotation 0 is horizontal, and a positive
				-- angle turns counter-clockwise. One pixel past the middle
				-- closes the hole where spokes meet.
				local spoke = viz:Bar()
				spoke:SetSize(radius + 2, thick)
				local ox = math.cos(mid) * (radius / 2)
				local oy = math.sin(mid) * (radius / 2)
				spoke:SetPoint("CENTER", viz.content, "TOPLEFT", cx + ox, -(cy + oy))
				spoke:SetRotation(-mid)
				spoke:SetVertexColor(shown[i].r, shown[i].g, shown[i].b, 1)
			end
			angle = angle - sweep
			used = used + count
		end
	end
	DrawFoot(viz, foot, DrawLegend(viz, shown, total, cy + radius + 12))
end

local function DrawMeters(viz, rows, withPercent)
	local shown = {}
	local maxValue = 0
	local total = 0
	for i = 1, #rows do
		local value = rows[i].value or 0
		if value > 0 then
			shown[#shown + 1] = rows[i]
			total = total + value
			if value > maxValue then
				maxValue = value
			end
		end
	end
	if maxValue <= 0 then
		viz:Empty()
		return
	end
	local width = viz:Width()
	local labelW = 96
	local valueW = withPercent and 108 or 64
	local barMax = width - labelW - valueW - 8
	if barMax < 16 then
		barMax = 16
	end
	local y = 4
	for i = 1, #shown do
		local row = shown[i]
		local name = viz:Font()
		name:SetPoint("TOPLEFT", 0, -y)
		name:SetWidth(labelW)
		name:SetTextColor(row.r, row.g, row.b)
		name:SetText(row.label)
		local bar = viz:Bar()
		local w = math.max(2, math.floor((row.value / maxValue) * barMax + 0.5))
		bar:SetPoint("TOPLEFT", labelW, -(y + 2))
		bar:SetSize(w, 10)
		bar:SetVertexColor(row.r, row.g, row.b, 1)
		local value = viz:Font()
		value:SetPoint("TOPRIGHT", 0, -y)
		value:SetWidth(valueW)
		value:SetJustifyH("RIGHT")
		value:SetTextColor(0.93, 0.90, 0.78)
		if withPercent and total > 0 then
			local pct = math.floor((row.value / total) * 100 + 0.5)
			value:SetText(string.format("%s   %d%%", ns.Viz:Clock(row.value), pct))
		else
			value:SetText(ns.Viz:Clock(row.value))
		end
		y = y + 18
	end
	viz:ContentHeight(y + 4)
end

-- Two counted columns. The bar is the count against the next power of ten,
-- so a selection of 100 and a selection of 700 do not both fill the column.
local function Axis(maxValue)
	local axis = 1
	while axis < maxValue and axis < 1000000 do
		axis = axis * 10
	end
	return axis
end

local function DrawColumns(viz, rows, footer)
	if #rows == 0 then
		viz:Empty()
		return
	end
	local maxA, maxB = 0, 0
	for i = 1, #rows do
		local kills = rows[i].kills or 0
		local turnins = rows[i].turnins or 0
		if kills > maxA then
			maxA = kills
		end
		if turnins > maxB then
			maxB = turnins
		end
	end
	maxA = Axis(maxA)
	maxB = Axis(maxB)
	local width = viz:Width()
	local nameW = 108
	if width < 240 then
		nameW = 72
	end
	local gap = 8
	local col = math.floor((width - nameW - gap) / 2)
	if col < 52 then
		col = 52
	end
	local numW = 36
	local barMax = col - numW - 6
	if barMax < 4 then
		barMax = 4
	end
	local rightA = nameW + col
	local rightB = nameW + col + gap + col
	local y = 2
	local function head(text, right, r, g, b)
		local font = viz:Font()
		font:SetPoint("TOPRIGHT", viz.content, "TOPLEFT", right, -y)
		font:SetWidth(col)
		font:SetJustifyH("RIGHT")
		font:SetTextColor(r, g, b)
		font:SetText(text)
	end
	head(L["Kills"], rightA, KILL_R, KILL_G, KILL_B)
	head(L["Turn-ins"], rightB, TURNIN_R, TURNIN_G, TURNIN_B)
	y = y + 16
	local function cell(value, maxValue, right, r, g, b)
		if value > 0 and maxValue > 0 then
			local bar = viz:Bar()
			local w = math.floor((value / maxValue) * barMax + 0.5)
			if w < 2 then
				w = 2
			end
			bar:SetPoint("TOPRIGHT", viz.content, "TOPLEFT", right - numW - 4, -(y + 3))
			bar:SetSize(w, 8)
			bar:SetVertexColor(r, g, b, 1)
		end
		local num = viz:Font()
		num:SetPoint("TOPRIGHT", viz.content, "TOPLEFT", right, -y)
		num:SetWidth(numW)
		num:SetJustifyH("RIGHT")
		if value > 0 then
			num:SetTextColor(0.93, 0.90, 0.78)
		else
			num:SetTextColor(0.45, 0.43, 0.38)
		end
		num:SetText(ns.Viz:Comma(value))
	end
	for i = 1, #rows do
		local row = rows[i]
		local name = viz:Font()
		name:SetPoint("TOPLEFT", 0, -y)
		name:SetWidth(nameW - 4)
		name:SetTextColor(row.r, row.g, row.b)
		name:SetText(row.label)
		cell(row.kills or 0, maxA, rightA, KILL_R, KILL_G, KILL_B)
		cell(row.turnins or 0, maxB, rightB, TURNIN_R, TURNIN_G, TURNIN_B)
		y = y + 18
	end
	DrawFoot(viz, footer, y)
end

-- Grouped horizontal bars. Kills and turn-ins each have their own axis, so
-- a small turn-in count can still draw a long bar when the turn-in axis is low.
local function DrawGroups(viz, rows, footer)
	if #rows == 0 then
		viz:Empty()
		return
	end
	local maxKills, maxTurnins = 0, 0
	for i = 1, #rows do
		local kills = rows[i].kills or 0
		local turnins = rows[i].turnins or 0
		if kills > maxKills then
			maxKills = kills
		end
		if turnins > maxTurnins then
			maxTurnins = turnins
		end
	end
	local killAxis = Axis(maxKills)
	local turnAxis = Axis(maxTurnins)
	local width = viz:Width()
	local nameW = 108
	local numW = 44
	local gap = 6
	local barMax = width - nameW - numW - gap
	if barMax < 24 then
		barMax = 24
	end
	local y = 2
	local killsLeg = viz:Font()
	killsLeg:SetPoint("TOPLEFT", 0, -y)
	killsLeg:SetWidth(72)
	killsLeg:SetTextColor(KILL_R, KILL_G, KILL_B)
	killsLeg:SetText(L["Kills"])
	local turnLeg = viz:Font()
	turnLeg:SetPoint("TOPLEFT", 80, -y)
	turnLeg:SetWidth(96)
	turnLeg:SetTextColor(TURNIN_R, TURNIN_G, TURNIN_B)
	turnLeg:SetText(L["Turn-ins"])
	y = y + 16
	local function line(value, axis, r, g, b, lineY)
		local num = viz:Font()
		num:SetPoint("TOPRIGHT", viz.content, "TOPLEFT", nameW + barMax + gap + numW, -lineY)
		num:SetWidth(numW)
		num:SetJustifyH("RIGHT")
		if value > 0 then
			num:SetTextColor(0.93, 0.90, 0.78)
			if axis > 0 then
				local bar = viz:Bar()
				local w = math.floor((value / axis) * barMax + 0.5)
				if w < 2 then
					w = 2
				end
				bar:SetPoint("TOPLEFT", nameW, -(lineY + 3))
				bar:SetSize(w, 8)
				bar:SetVertexColor(r, g, b, 1)
			end
		else
			num:SetTextColor(0.45, 0.43, 0.38)
		end
		num:SetText(ns.Viz:Comma(value))
	end
	for i = 1, #rows do
		local row = rows[i]
		local name = viz:Font()
		name:SetPoint("TOPLEFT", 0, -y)
		name:SetWidth(nameW - 4)
		if row.r ~= nil and row.g ~= nil and row.b ~= nil then
			name:SetTextColor(row.r, row.g, row.b)
		else
			name:SetTextColor(0.93, 0.90, 0.78)
		end
		name:SetText(row.label)
		line(row.kills or 0, killAxis, KILL_R, KILL_G, KILL_B, y)
		line(row.turnins or 0, turnAxis, TURNIN_R, TURNIN_G, TURNIN_B, y + 14)
		y = y + 32
	end
	DrawFoot(viz, footer, y)
end

-- One horizontal bar per row. Segments share a count, so they share one axis.
-- Absolute: the longest row fills the track. Share: every row fills the track,
-- and the split is that row alone. clock formats the numbers as hours.
local function DrawStacks(viz, rows, parts, footer, share, clock)
	if #rows == 0 or #parts == 0 then
		viz:Empty()
		return
	end
	local nParts = #parts
	local function amount(value)
		if clock then
			return ns.Viz:Clock(value)
		end
		return ns.Viz:Comma(value)
	end
	local function columnWidth(part)
		local text = L[part.text] or ""
		local header = (#text * 6) + 10
		local floorW = clock and 58 or 48
		if header < floorW then
			header = floorW
		end
		if header > 96 then
			header = 96
		end
		return header
	end
	local widths = {}
	local usedW = 0
	for p = 1, nParts do
		widths[p] = columnWidth(parts[p])
		usedW = usedW + widths[p]
	end
	local maxTotal = 0
	for i = 1, #rows do
		local total = 0
		for p = 1, nParts do
			total = total + (rows[i][parts[p].key] or 0)
		end
		rows[i].stackTotal = total
		if total > maxTotal then
			maxTotal = total
		end
	end
	local axis = maxTotal
	if axis < 1 then
		axis = 1
	end
	local width = viz:Width()
	local nameW = 52
	local gap = 6
	local totalW = clock and 64 or 44
	local columns = width - nameW - usedW - gap
	-- A column per part clips the clocks once several places have time.
	-- One total stays, and the part names move onto a legend.
	local legend = columns < 24
	local barMax = columns
	if legend then
		barMax = width - nameW - totalW - gap
		if barMax < 24 then
			barMax = 24
		end
	end
	local y = 2
	local right0 = nameW + barMax + gap
	local rightEdge = {}
	if legend then
		local x = 0
		for p = 1, nParts do
			local part = parts[p]
			local text = L[part.text]
			local w = (#text * 6) + 16
			if x > 0 and x + w > width then
				y = y + 14
				x = 0
			end
			local swatch = viz:Bar()
			swatch:SetPoint("TOPLEFT", x, -(y + 2))
			swatch:SetSize(8, 8)
			swatch:SetVertexColor(part.r, part.g, part.b, 1)
			local font = viz:Font()
			font:SetPoint("TOPLEFT", x + 10, -y)
			font:SetWidth(w - 10)
			font:SetTextColor(part.r, part.g, part.b)
			font:SetText(text)
			x = x + w
		end
		y = y + 16
	else
		local running = 0
		for p = 1, nParts do
			running = running + widths[p]
			rightEdge[p] = right0 + running
			local part = parts[p]
			local font = viz:Font()
			font:SetPoint("TOPRIGHT", viz.content, "TOPLEFT", rightEdge[p], -y)
			font:SetWidth(widths[p])
			font:SetJustifyH("RIGHT")
			font:SetTextColor(part.r, part.g, part.b)
			font:SetText(L[part.text])
		end
		y = y + 16
	end
	for i = 1, #rows do
		local row = rows[i]
		local name = viz:Font()
		name:SetPoint("TOPLEFT", 0, -y)
		name:SetWidth(nameW - 4)
		name:SetTextColor(0.78, 0.76, 0.70)
		name:SetText(row.label)
		local total = row.stackTotal or 0
		if total > 0 and (share or axis > 0) then
			local full = barMax
			if not share then
				full = math.floor((total / axis) * barMax + 0.5)
				if full < 2 then
					full = 2
				end
			end
			local used = 0
			local lastPart = 0
			for p = 1, nParts do
				if (row[parts[p].key] or 0) > 0 then
					lastPart = p
				end
			end
			for p = 1, nParts do
				local value = row[parts[p].key] or 0
				if value > 0 and used < full then
					local w
					if p == lastPart then
						w = full - used
					else
						w = math.floor((value / total) * full + 0.5)
						if w < 1 then
							w = 1
						end
						if used + w > full then
							w = full - used
						end
					end
					if w > 0 then
						local bar = viz:Bar()
						bar:SetPoint("TOPLEFT", nameW + used, -(y + 3))
						bar:SetSize(w, 8)
						bar:SetVertexColor(parts[p].r, parts[p].g, parts[p].b, 1)
						used = used + w
					end
				end
			end
		end
		if legend then
			local num = viz:Font()
			num:SetPoint("TOPRIGHT", viz.content, "TOPLEFT", right0 + totalW, -y)
			num:SetWidth(totalW)
			num:SetJustifyH("RIGHT")
			if total > 0 then
				num:SetTextColor(0.93, 0.90, 0.78)
			else
				num:SetTextColor(0.45, 0.43, 0.38)
			end
			num:SetText(amount(total))
		else
			for p = 1, nParts do
				local value = row[parts[p].key] or 0
				local num = viz:Font()
				num:SetPoint("TOPRIGHT", viz.content, "TOPLEFT", rightEdge[p], -y)
				num:SetWidth(widths[p])
				num:SetJustifyH("RIGHT")
				if value > 0 then
					num:SetTextColor(0.93, 0.90, 0.78)
				else
					num:SetTextColor(0.45, 0.43, 0.38)
				end
				num:SetText(amount(value))
			end
		end
		y = y + 18
	end
	DrawFoot(viz, footer, y)
end

-- Time is the bar. Kills and turn-ins stay numbers, because they are not hours.
local function DrawZones(viz, zones, footer)
	local shown = {}
	local maxSeconds = 0
	for i = 1, #(zones or {}) do
		local row = zones[i]
		local seconds = row.seconds or 0
		local kills = row.kills or 0
		local turnins = row.turnins or 0
		if seconds >= 60 or kills > 0 or turnins > 0 then
			shown[#shown + 1] = row
			if seconds > maxSeconds then
				maxSeconds = seconds
			end
		end
	end
	if #shown == 0 then
		viz:Empty()
		return
	end
	local width = viz:Width()
	local nameW = 120
	local clockW = 48
	local killW = 36
	local turnW = 72
	local gap = 6
	local barMax = width - nameW - clockW - killW - turnW - gap
	if barMax < 16 then
		nameW = 88
		barMax = width - nameW - clockW - killW - turnW - gap
	end
	if barMax < 12 then
		barMax = 12
	end
	local y = 2
	local clockRight = nameW + barMax + gap + clockW
	local killsRight = clockRight + killW
	local turnRight = killsRight + turnW
	local function head(text, right, width, r, g, b)
		local font = viz:Font()
		font:SetPoint("TOPRIGHT", viz.content, "TOPLEFT", right, -y)
		font:SetWidth(width)
		font:SetJustifyH("RIGHT")
		font:SetTextColor(r, g, b)
		font:SetText(text)
	end
	head(L["Time"], clockRight, clockW, ZONE_R, ZONE_G, ZONE_B)
	head(L["Kills"], killsRight, killW, KILL_R, KILL_G, KILL_B)
	head(L["Turn-ins"], turnRight, turnW, TURNIN_R, TURNIN_G, TURNIN_B)
	y = y + 16
	for i = 1, #shown do
		local row = shown[i]
		local seconds = row.seconds or 0
		local kills = row.kills or 0
		local turnins = row.turnins or 0
		local name = viz:Font()
		name:SetPoint("TOPLEFT", 0, -y)
		name:SetWidth(nameW - 4)
		name:SetTextColor(0.93, 0.90, 0.78)
		local label = ns.Replay:PlaceName(row.map)
		name:SetText(label or L["Unknown zone"])
		if seconds > 0 and maxSeconds > 0 then
			local bar = viz:Bar()
			local w = math.floor((seconds / maxSeconds) * barMax + 0.5)
			if w < 2 then
				w = 2
			end
			bar:SetPoint("TOPLEFT", nameW, -(y + 3))
			bar:SetSize(w, 8)
			bar:SetVertexColor(ZONE_R, ZONE_G, ZONE_B, 1)
		end
		local clock = viz:Font()
		clock:SetPoint("TOPRIGHT", viz.content, "TOPLEFT", clockRight, -y)
		clock:SetWidth(clockW)
		clock:SetJustifyH("RIGHT")
		if seconds > 0 then
			clock:SetTextColor(0.93, 0.90, 0.78)
		else
			clock:SetTextColor(0.45, 0.43, 0.38)
		end
		clock:SetText(ns.Viz:Clock(seconds))
		local function count(value, right, width)
			local num = viz:Font()
			num:SetPoint("TOPRIGHT", viz.content, "TOPLEFT", right, -y)
			num:SetWidth(width)
			num:SetJustifyH("RIGHT")
			if value > 0 then
				num:SetTextColor(0.93, 0.90, 0.78)
			else
				num:SetTextColor(0.45, 0.43, 0.38)
			end
			num:SetText(ns.Viz:Comma(value))
		end
		count(kills, killsRight, killW)
		count(turnins, turnRight, turnW)
		y = y + 18
	end
	DrawFoot(viz, footer, y)
end

-- Population pyramid: solo left, grouped right, one shared axis.
local function DrawPyramid(viz, rows, footer)
	if #rows == 0 then
		viz:Empty()
		return
	end
	local maxValue = 0
	for i = 1, #rows do
		local solo = rows[i].solo or 0
		local grouped = rows[i].grouped or 0
		if solo > maxValue then
			maxValue = solo
		end
		if grouped > maxValue then
			maxValue = grouped
		end
	end
	local axis = Axis(maxValue)
	local width = viz:Width()
	-- The center column is the level text. A fixed width leaves a hole around it.
	local probe = viz:Font()
	local labelW = 0
	for i = 1, #rows do
		probe:SetText(rows[i].label or "")
		local w = math.ceil(probe:GetStringWidth() or 0)
		if w > labelW then
			labelW = w
		end
	end
	probe:Hide()
	if labelW < 24 then
		labelW = 24
	end
	labelW = labelW + 2
	local numW = 40
	local gap = 2
	local wingMax = math.floor((width - labelW - (2 * numW) - (2 * gap)) / 2)
	if wingMax < 8 then
		wingMax = 8
	end
	local labelLeft = numW + wingMax + gap
	local rightBarLeft = labelLeft + labelW + gap
	local rightNumLeft = rightBarLeft + wingMax + gap
	local y = 2
	local soloLeg = viz:Font()
	soloLeg:SetPoint("TOPLEFT", 0, -y)
	soloLeg:SetWidth(math.floor(width / 2) - 4)
	soloLeg:SetJustifyH("LEFT")
	soloLeg:SetTextColor(SOLO_R, SOLO_G, SOLO_B)
	soloLeg:SetText(L["Solo"])
	local groupLeg = viz:Font()
	groupLeg:SetPoint("TOPRIGHT", 0, -y)
	groupLeg:SetWidth(math.floor(width / 2) - 4)
	groupLeg:SetJustifyH("RIGHT")
	groupLeg:SetTextColor(GROUP_R, GROUP_G, GROUP_B)
	groupLeg:SetText(L["Grouped"])
	y = y + 16
	for i = 1, #rows do
		local row = rows[i]
		local solo = row.solo or 0
		local grouped = row.grouped or 0
		local name = viz:Font()
		name:SetPoint("TOPLEFT", labelLeft, -y)
		name:SetWidth(labelW)
		name:SetJustifyH("CENTER")
		name:SetTextColor(0.93, 0.90, 0.78)
		name:SetText(row.label)
		if solo > 0 and axis > 0 then
			local w = math.floor((solo / axis) * wingMax + 0.5)
			if w < 2 then
				w = 2
			end
			local bar = viz:Bar()
			bar:SetPoint("TOPRIGHT", viz.content, "TOPLEFT", labelLeft - gap, -(y + 3))
			bar:SetSize(w, 8)
			bar:SetVertexColor(SOLO_R, SOLO_G, SOLO_B, 1)
		end
		local soloNum = viz:Font()
		soloNum:SetPoint("TOPLEFT", 0, -y)
		soloNum:SetWidth(numW)
		soloNum:SetJustifyH("RIGHT")
		if solo > 0 then
			soloNum:SetTextColor(0.93, 0.90, 0.78)
		else
			soloNum:SetTextColor(0.45, 0.43, 0.38)
		end
		soloNum:SetText(ns.Viz:Comma(solo))
		if grouped > 0 and axis > 0 then
			local w = math.floor((grouped / axis) * wingMax + 0.5)
			if w < 2 then
				w = 2
			end
			local bar = viz:Bar()
			bar:SetPoint("TOPLEFT", rightBarLeft, -(y + 3))
			bar:SetSize(w, 8)
			bar:SetVertexColor(GROUP_R, GROUP_G, GROUP_B, 1)
		end
		local groupNum = viz:Font()
		groupNum:SetPoint("TOPLEFT", rightNumLeft, -y)
		groupNum:SetWidth(numW)
		groupNum:SetJustifyH("LEFT")
		if grouped > 0 then
			groupNum:SetTextColor(0.93, 0.90, 0.78)
		else
			groupNum:SetTextColor(0.45, 0.43, 0.38)
		end
		groupNum:SetText(ns.Viz:Comma(grouped))
		y = y + 18
	end
	DrawFoot(viz, footer, y)
end

-- 100% stacked bar: each row fills the bar; split is that row's grouped then solo.
local function DrawShare(viz, rows, footer)
	if #rows == 0 then
		viz:Empty()
		return
	end
	local width = viz:Width()
	local nameW = 52
	local numW = 64
	local gap = 6
	local barMax = width - nameW - (2 * numW) - gap
	if barMax < 24 then
		barMax = 24
	end
	local y = 2
	local right0 = nameW + barMax + gap
	local groupLeg = viz:Font()
	groupLeg:SetPoint("TOPRIGHT", viz.content, "TOPLEFT", right0 + numW, -y)
	groupLeg:SetWidth(numW)
	groupLeg:SetJustifyH("RIGHT")
	groupLeg:SetTextColor(GROUP_R, GROUP_G, GROUP_B)
	groupLeg:SetText(L["Grouped"])
	local soloLeg = viz:Font()
	soloLeg:SetPoint("TOPRIGHT", viz.content, "TOPLEFT", right0 + (2 * numW), -y)
	soloLeg:SetWidth(numW)
	soloLeg:SetJustifyH("RIGHT")
	soloLeg:SetTextColor(SOLO_R, SOLO_G, SOLO_B)
	soloLeg:SetText(L["Solo"])
	y = y + 16
	for i = 1, #rows do
		local row = rows[i]
		local grouped = row.grouped or 0
		local solo = row.solo or 0
		local total = grouped + solo
		local name = viz:Font()
		name:SetPoint("TOPLEFT", 0, -y)
		name:SetWidth(nameW - 4)
		name:SetTextColor(0.78, 0.76, 0.70)
		name:SetText(row.label)
		if total > 0 then
			local gW = math.floor((grouped / total) * barMax + 0.5)
			if grouped > 0 and solo > 0 then
				if gW < 1 then
					gW = 1
				end
				if gW > barMax - 1 then
					gW = barMax - 1
				end
			elseif grouped > 0 then
				gW = barMax
			else
				gW = 0
			end
			local sW = barMax - gW
			if grouped > 0 and gW > 0 then
				local bar = viz:Bar()
				bar:SetPoint("TOPLEFT", nameW, -(y + 3))
				bar:SetSize(gW, 8)
				bar:SetVertexColor(GROUP_R, GROUP_G, GROUP_B, 1)
			end
			if solo > 0 and sW > 0 then
				local bar = viz:Bar()
				bar:SetPoint("TOPLEFT", nameW + gW, -(y + 3))
				bar:SetSize(sW, 8)
				bar:SetVertexColor(SOLO_R, SOLO_G, SOLO_B, 1)
			end
		end
		local groupNum = viz:Font()
		groupNum:SetPoint("TOPRIGHT", viz.content, "TOPLEFT", right0 + numW, -y)
		groupNum:SetWidth(numW)
		groupNum:SetJustifyH("RIGHT")
		if grouped > 0 then
			groupNum:SetTextColor(0.93, 0.90, 0.78)
		else
			groupNum:SetTextColor(0.45, 0.43, 0.38)
		end
		groupNum:SetText(ns.Viz:Comma(grouped))
		local soloNum = viz:Font()
		soloNum:SetPoint("TOPRIGHT", viz.content, "TOPLEFT", right0 + (2 * numW), -y)
		soloNum:SetWidth(numW)
		soloNum:SetJustifyH("RIGHT")
		if solo > 0 then
			soloNum:SetTextColor(0.93, 0.90, 0.78)
		else
			soloNum:SetTextColor(0.45, 0.43, 0.38)
		end
		soloNum:SetText(ns.Viz:Comma(solo))
		y = y + 18
	end
	DrawFoot(viz, footer, y)
end

local function modelRows(model)
	if type(model) ~= "table" then
		return {}, nil
	end
	return model.rows or {}, model.footer
end

-- One list of { label, value, r, g, b }. Pie stores it as slices. Meters
-- stores it as rows. Either drawer can draw either chart.
local function SliceList(model)
	if type(model) ~= "table" then
		return {}
	end
	if type(model.slices) == "table" then
		return model.slices
	end
	return model.rows or {}
end

ns.Viz:RegisterDisplay("pie", {
	label = L["Pie"],
	Draw = function(viz, model)
		model = model or {}
		DrawPie(viz, SliceList(model), model.foot)
	end,
})

ns.Viz:RegisterDisplay("meters", {
	label = L["Bars"],
	Draw = function(viz, model)
		model = model or {}
		DrawMeters(viz, SliceList(model), model.percent and true or false)
	end,
})

ns.Viz:RegisterDisplay("columns", {
	label = L["Columns"],
	Draw = function(viz, model)
		local rows, foot = modelRows(model)
		DrawColumns(viz, rows, foot)
	end,
})

ns.Viz:RegisterDisplay("groups", {
	label = L["Grouped bars"],
	Draw = function(viz, model)
		local rows, foot = modelRows(model)
		DrawGroups(viz, rows, foot)
	end,
})

ns.Viz:RegisterDisplay("stacks", {
	label = L["Stacked bars"],
	Draw = function(viz, model)
		model = model or {}
		DrawStacks(viz, model.rows or {}, model.parts or {}, model.footer, false, model.clock and true or false)
	end,
})

ns.Viz:RegisterDisplay("share", {
	label = L["Share"],
	Draw = function(viz, model)
		model = model or {}
		local parts = model.parts
		if type(parts) == "table" and #parts > 0 then
			DrawStacks(viz, model.rows or {}, parts, model.footer, true, model.clock and true or false)
		else
			local rows, foot = modelRows(model)
			DrawShare(viz, rows, foot)
		end
	end,
})

ns.Viz:RegisterDisplay("pyramid", {
	label = L["Pyramid"],
	Draw = function(viz, model)
		local rows, foot = modelRows(model)
		DrawPyramid(viz, rows, foot)
	end,
})

ns.Viz:RegisterDisplay("zones", {
	label = L["Zones"],
	Draw = function(viz, model)
		model = model or {}
		DrawZones(viz, model.zones, model.footer)
	end,
})
