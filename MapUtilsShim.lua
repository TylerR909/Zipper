local _, ns = ...

-- MapUtils paints its stitched world as a child of the canvas, above the
-- canvas textures. The path and pins have to sit above that art. Placement
-- stays in canvas space; only the frame level changes.
local shim = {}

function shim:Active()
	return _G.MapUtils ~= nil and WorldMapFrame ~= nil
end

function shim:OverlayLevel(canvas)
	return (canvas:GetFrameLevel() or 1) + 20
end

setmetatable(shim, { __index = ns.Map.base })
ns.Map:Add(shim)
