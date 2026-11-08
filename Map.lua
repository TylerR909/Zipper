local _, ns = ...

-- The map the replay draws on. A shim can replace the default when another
-- addon owns the world map. Replay asks ns.Map and does not name those addons.
ns.Map = { shims = {} }

function ns.Map:Add(shim)
	self.shims[#self.shims + 1] = shim
end

function ns.Map:Use()
	for i = #self.shims, 1, -1 do
		local shim = self.shims[i]
		if shim.Active and shim:Active() then
			return shim
		end
	end
	return self.base
end

local base = {}

function base:Active()
	return true
end

function base:Canvas()
	if not WorldMapFrame then
		return nil
	end
	if WorldMapFrame.GetCanvas then
		return WorldMapFrame:GetCanvas()
	end
	if WorldMapFrame.ScrollContainer then
		return WorldMapFrame.ScrollContainer.Child
	end
end

function base:OverlayLevel(canvas)
	return (canvas:GetFrameLevel() or 1) + 5
end

function base:Zoom()
	local canvas = self:Canvas()
	local zoom = canvas and canvas:GetScale() or 1
	if not zoom or zoom < 0.05 then
		zoom = 0.05
	end
	return zoom
end

-- Fixed screen size. SetScale would also scale the anchor and slide the pin
-- toward the top-left as the map zooms in.
function base:FitPin(pin, pixels)
	pin:SetScale(1)
	local zoom = self:Zoom()
	pin:SetSize(pixels / zoom, pixels / zoom)
end

function base:Place(pin, nx, ny)
	local canvas = self:Canvas()
	if not canvas then
		return
	end
	if pin:GetParent() ~= canvas then
		pin:SetParent(canvas)
	end
	local width, height = canvas:GetWidth(), canvas:GetHeight()
	pin:ClearAllPoints()
	pin:SetPoint("CENTER", canvas, "TOPLEFT", nx * width, -ny * height)
end

ns.Map.base = base
