local _, ns = ...

-- MapUtils paints its stitched world as a child of the canvas, above the
-- canvas textures. The path and pins have to sit above that art. Placement
-- stays in canvas space; only the frame level changes.
local shim = {}

function shim:Active()
	-- MapUtils keeps its name on the addon table, not as a global. The stitched
	-- map is a child of the canvas at about frame level +10. The path has to
	-- be higher than that or it only shows through transparent edges.
	if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("MapUtils") then
		return true
	end
	if IsAddOnLoaded and IsAddOnLoaded("MapUtils") then
		return true
	end
	return _G.MapUtils ~= nil
end

function shim:OverlayLevel(canvas)
	return (canvas:GetFrameLevel() or 1) + 25
end

setmetatable(shim, { __index = ns.Map.base })
ns.Map:Add(shim)
