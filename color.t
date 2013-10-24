local Vec = terralib.require("linalg").Vec
local m = terralib.require("mem")
local templatize = terralib.require("templatize")
local inheritance = terralib.require("inheritance")

local Color = templatize(function(real, dim)
	
	local VecT = Vec(real, dim)

	local struct ColorT {}
	inheritance.staticExtend(VecT, ColorT)

	ColorT.methods.alpha = macro(function(self)
		local lastindex = dim-1
		return `[self].entries[lastindex]
	end)

end)

return Color