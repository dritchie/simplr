local templatize = terralib.require("templatize")
local m = terralib.require("mem")
local Vec = terralib.require("linalg").Vec
local inheritance = terralib.require("inheritance")


local ImplicitShape = templatize(function(real, spaceDim, surfeDim)

	local SpaceVec = Vec(real, spaceDim)
	local SurfVec = Vec(real, surfDim)

	local struct ImplicitShapeT {}

	inheritance.purevirtual(ImplicitShapeT, "isovalue", {SpaceVec}->{real})
	inheritance.purevirtual(ImplicitShapeT, "isovalueAndSurfaceCoord", {SpaceVec}->{real, SurfVec})

	return ImplicitShapeT

end)

local ShadedImplicitShape = templatize(function(real, spaceDim, surfDim, colorDim)

	local SpaceVec = Vec(real, spaceDim)
	local SurfVec = Vec(real, surfDim)
	local ColorVec = Vec(real, colorDim)
	local ImplicitShapeT = ImplicitShape(real, spaceDim, surfDim)

	local struct ShadedImplicitShapeT
	{
		baseShape: &ImplicitShapeT
	}

	terra ShadedImplicitShapeT:__construct(baseShape: &ImplicitShapeT)
		self.baseShape = baseShape
	end

	inheritance.purevirtual(ShadedImplicitShapeT, "isovalueAndColor", {SpaceVec}->{real, ColorVec})

	m.addConstructors(ShadedImplicitShapeT)
	return ShadedImplicitShapeT

end)

local ConstantColorImplicitShape = templatize(function(real, spaceDim, surfDim, colorDim)

	local SpaceVec = Vec(real, spaceDim)
	local SurfVec = Vec(real, surfDim)
	local ColorVec = Vec(real, colorDim)
	local ImplicitShapeT = ImplicitShape(real, spaceDim, surfDim)
	local ShadedImplicitShapeT = ShadedImplicitShape(real, spaceDim, surfDim, colorDim)

	local struct ConstantColorImplicitShapeT
	{
		color: ColorVec
	}
	inheritance.dynamicExtend(ShadedImplicitShapeT, ConstantColorImplicitShapeT)

	-- Assumes ownership of 'color'
	terra ConstantColorImplicitShapeT:__construct(baseShape: &ImplicitShapeT, color: ColorVec)
		ShadedImplicitShapeT.__construct(self, baseShape)
		self.color = color
	end

	terra ConstantColorImplicitShapeT:__destruct()
		m.destruct(self.color)
	end

	terra ConstantColorImplicitShapeT:isovalueAndColor(point: SpaceVec)
		return self.color
	end
	inheritance.virtual(ConstantColorImplicitShapeT, "isovalueAndColor")

	m.addConstructors(ConstantColorImplicitShapeT)
	return ConstantColorImplicitShapeT

end)


return
{
	ImplicitShape = ImplicitShape,
	ShadedImplicitShape = ShadedImplicitShape,
	ConstantColorImplicitShape = ConstantColorImplicitShape
}