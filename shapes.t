local templatize = terralib.require("templatize")
local m = terralib.require("mem")
local Vec = terralib.require("linalg").Vec
local Color = terralib.require("color")
local inheritance = terralib.require("inheritance")


-- TODO: If virtual function calls are too slow, we can handle the Shape hierarchy through
--    code parameterization (e.g. ConstantColorShape(BaseShapeType))
-- To support this, samplers will need to store each type of shape it is ever passed in a 
--    separate list (use-driven type generation). Sampling iterates over each list in sequence. 
-- This will be faster, but we will lose the ability to specify the exact order in which
--    shapes are rendered (i.e. they will be rendered in batches according to their types.)


local ImplicitShape = templatize(function(real, spaceDim, colorDim)

	local SpaceVec = Vec(real, spaceDim)
	local ColorVec = Color(real, colorDim)

	local struct ImplicitShapeT {}

	terra ImplicitShapeT:__destruct() end
	inheritance.virtual(ImplicitShapeT, "__destruct")

	inheritance.purevirtual(ImplicitShapeT, "isovalue", {&SpaceVec}->{real})
	inheritance.purevirtual(ImplicitShapeT, "isovalueAndColor", {&SpaceVec}->{real, ColorVec})

	return ImplicitShapeT

end)

local ConstantColorImplicitShape = templatize(function(real, spaceDim, colorDim)

	local SpaceVec = Vec(real, spaceDim)
	local ColorVec = Color(real, colorDim)
	local ImplicitShapeT = ImplicitShape(real, spaceDim, colorDim)

	local struct ConstantColorImplicitShapeT
	{
		innerShape: &ImplicitShapeT,
		color: ColorVec
	}
	inheritance.dynamicExtend(ImplicitShapeT, ConstantColorImplicitShapeT)

	terra ConstantColorImplicitShapeT:__construct(shape: &ImplicitShapeT, color: &ColorVec)
		self.innerShape = innerShape
		self.color = @color
	end

	terra ConstantColorImplicitShapeT:isovalue(point: &SpaceVec)
		return innerShape:isovalue(point)
	end
	inheritance.virtual(ConstantColorImplicitShapeT, "isovalue")

	terra ConstantColorImplicitShapeT:isovalueAndColor(point: &SpaceVec)
		return innerShape:isovalue(point), self.color
	end
	inheritance.virtual(ConstantColorImplicitShapeT, "isovalue")

	m.addConstructors(ConstantColorImplicitShapeT)
	return ConstantColorImplicitShapeT

end)


-- TODO: For these concrete shapes, is it faster to use the generalized implicit formula
--    or to tranform into a canonical one? Currently using generalized.

local SphereImplicitShape = templatize(function(real, spaceDim, colorDim)

	local SpaceVec = Vec(real, spaceDim)
	local ImplicitShapeT = ImplicitShape(real, spaceDim, colorDim)

	local struct SphereImplicitShapeT
	{
		center: SpaceVec,
		rSq: real
	}
	inheritance.dynamicExtend(ImplicitShapeT, SphereImplicitShapeT)

	terra SphereImplicitShapeT:__construct(center: &SpaceVec, r: real)
		self.center = @center
		self.rSq = r*r
	end

	terra SphereImplicitShapeT:isovalue(point: &SpaceVec)
		return point:distSq(self.center) - self.rSq
	end
	inheritance.virtual(SphereImplicitShapeT, "isovalue")

	return SphereImplicitShapeT

end)

-- Cylinder with hemispherical caps at either end (much easier to implement/efficient to
--    evaluate than a true cylinder).
local CapsuleImplicitShape = templatize(function(real, spaceDim, colorDim)
	
	local SpaceVec = Vec(real, spaceDim)
	local ImplicitShapeT = ImplicitShape(real, spaceDim, colorDim)

	local struct CapsuleImplicitShapeT
	{
		bot: SpaceVec,
		top: SpaceVec,
		rSq: real
	}
	inheritance.dynamicExtend(ImplicitShapeT, CapsuleImplicitShapeT)

	-- NOTE: Assumption is that bot ~= top (we do not do a check for the degeneracy in the
	--    isovalue function to save time)
	terra CapsuleImplicitShapeT:__construct(bot: &SpaceVec, top: &SpaceVec, r: real)
		self.bot = @bot
		self.top = @top
		self.rSq = r*r
	end

	terra CapsuleImplicitShapeT:isovalue(point: &SpaceVec)
		var t = (@point - self.bot):(self.top - self.bot)
		-- Beyond the ends of the cylinder; treat as semispherical caps
		if t < 0.0 then return point:distSq(bot) - self.rSq end
		if t > 1.0 then return point:distSq(top) - self.rSq end
		-- Inside the bounds of the cylinder; treat as shaft
		var proj = a + t*(b-a)
		return point:distSq(proj) - self.rSq
	end
	inheritance.virtual(CapsuleImplicitShapeT, "isovalue")

	return CapsuleImplicitShapeT

end)



return
{
	ImplicitShape = ImplicitShape,
	ConstantColorImplicitShape = ConstantColorImplicitShape,
	SphereImplicitShape = SphereImplicitShape,
	CapsuleImplicitShape = CapsuleImplicitShape
}




