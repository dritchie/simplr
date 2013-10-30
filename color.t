local Vec = terralib.require("linalg").Vec
local templatize = terralib.require("templatize")

-- Alias for Vec
local Color = templatize(function(real, dim)
	return Vec(real, dim)
end)

return Color