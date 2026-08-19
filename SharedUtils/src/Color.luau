local Color = {}

function Color.darken(color: Color3, opacity: number): Color3
	local r = math.round(color.R * (1 - opacity) * 255)
	local g = math.round(color.G * (1 - opacity) * 255)
	local b = math.round(color.B * (1 - opacity) * 255)

	return Color3.fromRGB(r, g, b)
end

function Color.lighten(color: Color3, opacity: number): Color3
	local r = math.round((color.R + (1 - color.R) * opacity) * 255)
	local g = math.round((color.G + (1 - color.G) * opacity) * 255)
	local b = math.round((color.B + (1 - color.B) * opacity) * 255)

	return Color3.fromRGB(r, g, b)
end

return Color
