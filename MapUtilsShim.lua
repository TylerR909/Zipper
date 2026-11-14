local _, ns = ...

-- MapUtils paints its stitched world as a child of the canvas, above the
-- canvas textures. The path and pins have to sit above that art. Placement
-- stays in canvas space; only the frame level changes. Zoom still comes from
-- the canvas Child scale (MapUtils SmoothZoom sets that too, including when
-- it preserves zoom into a city map).
local shim = {}

function shim:Active()
	-- MapUtils keeps its name on the addon table, not as a global.
	if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("MapUtils") then
		return true
	end
	if IsAddOnLoaded and IsAddOnLoaded("MapUtils") then
		return true
	end
	return _G.MapUtils ~= nil
end

function shim:OverlayLevel(canvas)
	-- ns.Map.base already clears MapExplorationPin. MapUtils SyncBlizzardArt can
	-- still raise MinimapLayer / city.terrain to pin + 4 after it hides those
	-- pins, and stitched One Map art sits around canvas + 5..10. Keep a canvas
	-- + 25 floor and stay above city detail (pin + 5). MapUtils POI pins sit
	-- higher still.
	local level = ns.Map.base.OverlayLevel(self, canvas)
	local floor = (canvas:GetFrameLevel() or 1) + 25
	if floor > level then
		level = floor
	end
	if WorldMapFrame and WorldMapFrame.EnumeratePinsByTemplate then
		for pin in WorldMapFrame:EnumeratePinsByTemplate("MapExplorationPinTemplate") do
			local pinLevel = pin:GetFrameLevel()
			if pinLevel and pinLevel + 5 > level then
				level = pinLevel + 5
			end
		end
	end
	return level
end

setmetatable(shim, { __index = ns.Map.base })
ns.Map:Add(shim)
