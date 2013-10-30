local Vec = terralib.require("linalg").Vec
local templatize = terralib.require("templatize")

-- Alias for Vec
local Color = templatize(function(real, dim)
	return Vec(real, dim)
end)

-- We also provide a macro for getting alpha (the last dimension of the Vec)
Color.alpha = macro(function(vec)
	local lastIndex = vec:gettype().Dimension - 1
	return `vec.entries[lastIndex]
end)

return Color