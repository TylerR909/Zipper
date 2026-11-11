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
	-- Stitched art uses FRAME_LEVEL_OFFSET 5 on the canvas child, with zone,
	-- city, and terrain a few levels above that. SyncBlizzardArt can raise
	-- MinimapLayer above MapExplorationPin (pin stack starts near 2000), then
	-- city.terrain and underground city detail a few levels above that. When
	-- city detail takes over it hides those pins but leaves the raised art in
	-- place, so a fixed +25 and a shown-only pin check both fall short. Match
	-- MapUtils: read exploration pin levels whether shown or not, and stay
	-- above city detail (pin + 4). MapUtils POI pins sit higher still.
	local level = (canvas:GetFrameLevel() or 1) + 25
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
