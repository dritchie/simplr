local templatize = terralib.require("templatize")
local m = terralib.require("mem")
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

	terra SphereImplicitShapeT:isovalue(point: SpaceVec) : real
		return point:distSq(self.center) - self.rSq
	end
	inheritance.virtual(SphereImplicitShapeT, "isovalue")

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

	local C = terralib.includec("stdio.h")

	terra CapsuleImplicitShapeT:isovalue(point: SpaceVec) : real
		var t = (point - self.bot):dot(self.topMinusBot) / self.sqLen
		-- Beyond the ends of the cylinder; treat as semispherical caps
		if t < 0.0 then return point:distSq(self.bot) - self.rSq end
		if t > 1.0 then return point:distSq(self.top) - self.rSq end
		-- Inside the bounds of the cylinder; treat as shaft
		var proj = self.bot + t*self.topMinusBot
		return point:distSq(proj) - self.rSq
	end
	inheritance.virtual(CapsuleImplicitShapeT, "isovalue")

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




