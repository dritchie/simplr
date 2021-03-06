local m = require("mem")
local templatize = require("templatize")


local BBox = templatize(function(VecT)

	local real = VecT.RealType

	local struct BBoxT { mins: VecT, maxs: VecT }

	terra BBoxT:__construct(mins: VecT, maxs: VecT) : {}
		self.mins = m.copy(mins)
		self.maxs = m.copy(maxs)
	end

	terra BBoxT:__construct() : {}
		self:__construct(VecT.stackAlloc([math.huge]), VecT.stackAlloc([-math.huge]))
	end

	terra BBoxT:expand(point: &VecT)
		self.mins:minInPlace(@point)
		self.maxs:maxInPlace(@point)
	end

	terra BBoxT:expand(other: &BBoxT)
		self.mins:minInPlace(other.mins)
		self.maxs:maxInPlace(other.maxs)
	end

	terra BBoxT:expand(amount: real)
		[VecT.foreach(`self.mins, function(x) return quote [x] = [x] - amount end end)]
		[VecT.foreach(`self.maxs, function(x) return quote [x] = [x] + amount end end)]
	end

	terra BBoxT:contains(point: &VecT)
		return @point > self.mins and @point < self.maxs
	end

	m.addConstructors(BBoxT)
	return BBoxT

end)


return BBox
