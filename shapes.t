local templatize = terralib.require("templatize")
local m = terralib.require("mem")
local util = terralib.require("util")
local Vec = terralib.require("linalg").Vec
local Color = terralib.require("color")
local inheritance = terralib.require("inheritance")
local BBox = terralib.require("bbox")
local ad = terralib.require("ad")


-- TODO: If virtual function calls are too slow, we can handle the Shape hierarchy through
--    code parameterization (e.g. ConstantColorShape(BaseShapeType))
-- To support this, samplers will need to store each type of shape it is ever passed in a 
--    separate list (use-driven type generation). Sampling iterates over each list in sequence. 
-- This will be faster, but we will lose the ability to specify the exact order in which
--    shapes are rendered (i.e. they will be rendered in batches according to their types.)


local ImplicitShape = templatize(function(SpaceVec, ColorVec)

	assert(SpaceVec.__generatorTemplate == Vec)
	assert(ColorVec.__generatorTemplate == Color)

	local real = SpaceVec.RealType
	local BBoxT = BBox(Vec(double, SpaceVec.Dimension))

	local struct ImplicitShapeT {}
	ImplicitShapeT.SpaceVec = SpaceVec
	ImplicitShapeT.ColorVec = ColorVec

	terra ImplicitShapeT:__destruct() : {} end
	inheritance.virtual(ImplicitShapeT, "__destruct")

	inheritance.purevirtual(ImplicitShapeT, "minIsovalue", {}->{real})
	inheritance.purevirtual(ImplicitShapeT, "isovalue", {SpaceVec}->{real})
	inheritance.purevirtual(ImplicitShapeT, "isovalueAndColor", {SpaceVec}->{real, ColorVec})
	inheritance.purevirtual(ImplicitShapeT, "bounds", {}->{BBoxT})

	return ImplicitShapeT

end)

local ConstantColorImplicitShape = templatize(function(SpaceVec, ColorVec)

	local real = SpaceVec.RealType
	local BBoxT = BBox(Vec(double, SpaceVec.Dimension))
	local ImplicitShapeT = ImplicitShape(SpaceVec, ColorVec)

	local struct ConstantColorImplicitShapeT
	{
		innerShape: &ImplicitShapeT,
		color: ColorVec
	}
	inheritance.dynamicExtend(ImplicitShapeT, ConstantColorImplicitShapeT)

	-- Takes ownserhip of 'shape'
	terra ConstantColorImplicitShapeT:__construct(shape: &ImplicitShapeT, color: ColorVec)
		self.innerShape = shape
		self.color = color
	end

	terra ConstantColorImplicitShapeT:__destruct() : {}
		m.delete(self.innerShape)
	end
	inheritance.virtual(ConstantColorImplicitShapeT, "__destruct")

	terra ConstantColorImplicitShapeT:minIsovalue() : real
		return self.innerShape:minIsovalue()
	end
	inheritance.virtual(ConstantColorImplicitShapeT, "minIsovalue")

	terra ConstantColorImplicitShapeT:isovalue(point: SpaceVec) : real
		return self.innerShape:isovalue(point)
	end
	inheritance.virtual(ConstantColorImplicitShapeT, "isovalue")

	terra ConstantColorImplicitShapeT:isovalueAndColor(point: SpaceVec) : {real, ColorVec}
		return self.innerShape:isovalue(point), self.color
	end
	inheritance.virtual(ConstantColorImplicitShapeT, "isovalueAndColor")

	terra ConstantColorImplicitShapeT:bounds() : BBoxT
		return self.innerShape:bounds()
	end
	inheritance.virtual(ConstantColorImplicitShapeT, "bounds")

	m.addConstructors(ConstantColorImplicitShapeT)
	return ConstantColorImplicitShapeT

end)


-- TODO: For these concrete shapes, is it faster to use the generalized implicit formula
--    or to tranform into a canonical one? Currently using generalized.

local sphereBBox = templatize(function(VecT)
	local real = VecT.RealType
	local function genExpands(center, rad, bbox, tmp)
		local stmts = {}
		for i=0,VecT.Dimension-1 do
			table.insert(stmts, quote
				[tmp] = [center].entries[ [i] ]
				[center].entries[ [i] ]  = [tmp] + rad
				[bbox]:expand(&[center])
				[center].entries[ [i] ]  = [tmp] - rad
				[bbox]:expand(&[center])
				[center].entries[ [i] ] = [tmp]
			end)
		end
		return stmts
	end
	return terra(center: VecT, rad: real)
		var bbox = [BBox(VecT)].stackAlloc()
		var tmp : real
		[genExpands(center, rad, bbox, tmp)]
		return bbox
	end
end)

local SphereImplicitShape = templatize(function(SpaceVec, ColorVec)

	local real = SpaceVec.RealType
	local BVec = Vec(double, SpaceVec.Dimension)
	local BBoxT = BBox(BVec)
	local ImplicitShapeT = ImplicitShape(SpaceVec, ColorVec)

	local struct SphereImplicitShapeT
	{
		center: SpaceVec,
		r: real,
		rSq: real
	}
	inheritance.dynamicExtend(ImplicitShapeT, SphereImplicitShapeT)

	terra SphereImplicitShapeT:__construct(center: SpaceVec, r: real)
		self.center = center
		self.r = r
		self.rSq = r*r
	end

	-- AD primitive for sphere isosurface function
	local val = ad.val
	local accumadj = ad.def.accumadj
	local isoval = Vec.makeADPrimitive(
		{Vec(double, SpaceVec.Dimension), Vec(double, SpaceVec.Dimension), double},
		macro(function(point, center, rSq)
			return `point:distSq(center) - rSq
		end),
		macro(function(v, point, center, rSq)
			local VecT = center:gettype()
			return quote
				accumadj(v, rSq, -1.0)
				[VecT.foreachPair(point, center, function(p, c)
					return quote
						accumadj(v, p, 2*(val(p) - val(c)))
						accumadj(v, c, 2*(val(c) - val(p)))
					end
				end)]
			end
		end))

	terra SphereImplicitShapeT:isovalue(point: SpaceVec) : real
		-- return point:distSq(self.center) - self.rSq
		return isoval(point, self.center, self.rSq)
	end
	inheritance.virtual(SphereImplicitShapeT, "isovalue")

	terra SphereImplicitShapeT:minIsovalue() : real
		return -self.rSq
	end
	inheritance.virtual(SphereImplicitShapeT, "minIsovalue")

	terra SphereImplicitShapeT:bounds() : BBoxT
		return [sphereBBox(BVec)](ad.val(self.center), ad.val(self.r))
	end
	inheritance.virtual(SphereImplicitShapeT, "bounds")

	m.addConstructors(SphereImplicitShapeT)
	return SphereImplicitShapeT

end)

-- Cylinder with hemispherical caps at either end (much easier to implement/efficient to
--    evaluate than a true cylinder).
local CapsuleImplicitShape = templatize(function(SpaceVec, ColorVec)

	local real = SpaceVec.RealType
	local BVec = Vec(double, SpaceVec.Dimension)
	local BBoxT = BBox(BVec)
	local ImplicitShapeT = ImplicitShape(SpaceVec, ColorVec)

	local struct CapsuleImplicitShapeT
	{
		bot: SpaceVec,
		top: SpaceVec,
		r: real,
		rSq: real,
		topMinusBot: SpaceVec,
		sqLen: real
	}
	inheritance.dynamicExtend(ImplicitShapeT, CapsuleImplicitShapeT)

	-- NOTE: Assumption is that bot ~= top (we do not do a check for the degeneracy in the
	--    isovalue function to save time)
	terra CapsuleImplicitShapeT:__construct(bot: SpaceVec, top: SpaceVec, r: real)
		self.bot = bot
		self.top = top
		self.r = r
		self.rSq = r*r
		self.topMinusBot = top - bot
		self.sqLen = self.topMinusBot:normSq()
	end

	-- AD primitive for capsule isosurface function
	local val = ad.val
	local accumadj = ad.def.accumadj
	local VecT = Vec(double, SpaceVec.Dimension)
	local isoval = Vec.makeADPrimitive(
		{VecT, VecT, VecT, double, double},
		macro(function(point, bot, top, rSq, sqLen)
			return quote
				var topMinusBot = top - bot
				var t = (point - bot):dot(topMinusBot) / sqLen
				-- Beyond the ends of the cylinder; treat as semispherical caps
				if t < 0.0 then return point:distSq(bot) - rSq end
				if t > 1.0 then return point:distSq(top) - rSq end
				-- Inside the bounds of the cylinder; treat as shaft
				var proj = bot + t*topMinusBot
				var result = point:distSq(proj) - rSq
			in
				result
			end
		end),
		macro(function(v, point, bot, top, rSq, sqLen)
			local VecT = bot:gettype()
			return quote
				accumadj(v, rSq, -1.0)
				var valbot = val(bot)
				var topMinusBot = val(top) - valbot
				var pointMinusBot = val(point) - valbot
				var t = pointMinusBot:dot(topMinusBot) / val(sqLen)
				if t < 0.0 then
					[VecT.foreachPair(point, bot, function(p, b)
						return quote
							accumadj(v, p, 2*(val(p) - val(b)))
							accumadj(v, b, 2*(val(b) - val(p)))
						end
					end)]
				elseif t > 1.0 then
					[VecT.foreachPair(point, top, function(p, t)
						return quote
							accumadj(v, p, 2*(val(p) - val(t)))
							accumadj(v, t, 2*(val(t) - val(p)))
						end
					end)]
				else
					-- From Wolfram Alpha...fingers crossed...
					var tmbnormsq = topMinusBot:normSq()
					var lsq = val(sqLen)
					accumadj(v, sqLen, -2*pointMinusBot:normSq()*tmbnormsq*(tmbnormsq - lsq) / (lsq*lsq*lsq))
					[VecT.foreachTuple(function(p, b, t)
						return quote
							var bmp = val(b) - val(p)
							var bmt = val(b) - val(t)
							var bmtSq = bmt*bmt
							accumadj(v, p, -2*bmp*(bmtSq-lsq)*(bmtSq-lsq) / (lsq*lsq))
							accumadj(v, b, 2*bmp*(bmtSq-lsq)*(bmt*(3*val(b) - 2*val(p) - val(t)) - lsq) / (lsq*lsq))
							accumadj(v, t, -4*bmp*bmp*bmt*(bmtSq-lsq) / (lsq*lsq))
						end
					end, point, bot, top)]
				end
			end
		end))

	terra CapsuleImplicitShapeT:isovalue(point: SpaceVec) : real
		var t = (point - self.bot):dot(self.topMinusBot) / self.sqLen
		-- Beyond the ends of the cylinder; treat as semispherical caps
		if t < 0.0 then return point:distSq(self.bot) - self.rSq end
		if t > 1.0 then return point:distSq(self.top) - self.rSq end
		-- Inside the bounds of the cylinder; treat as shaft
		var proj = self.bot + t*self.topMinusBot
		return point:distSq(proj) - self.rSq
		
		-- return isoval(point, self.bot, self.top, self.rSq, self.sqLen)
	end
	inheritance.virtual(CapsuleImplicitShapeT, "isovalue")

	terra CapsuleImplicitShapeT:minIsovalue() : real
		return -self.rSq
	end
	inheritance.virtual(CapsuleImplicitShapeT, "minIsovalue")

	terra CapsuleImplicitShapeT:bounds() : BBoxT
		var bbox1 = [sphereBBox(BVec)](ad.val(self.bot), ad.val(self.r))
		var bbox2 = [sphereBBox(BVec)](ad.val(self.top), ad.val(self.r))
		bbox1:expand(&bbox2)
		return bbox1
	end
	inheritance.virtual(CapsuleImplicitShapeT, "bounds")

	m.addConstructors(CapsuleImplicitShapeT)
	return CapsuleImplicitShapeT

end)



return
{
	ImplicitShape = ImplicitShape,
	ConstantColorImplicitShape = ConstantColorImplicitShape,
	SphereImplicitShape = SphereImplicitShape,
	CapsuleImplicitShape = CapsuleImplicitShape
}




