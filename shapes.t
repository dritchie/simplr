local templatize = terralib.require("templatize")
local m = terralib.require("mem")
local Vec = terralib.require("linalg").Vec
local inheritance = terralib.require("inheritance")


local ImplicitShape = templatize(function(real, spaceDim, surfeDim)

	local SpaceVec = Vec(real, spaceDim)
	local SurfVec = Vec(real, surfDim)

	local struct ImplicitShapeT {}

	terra ImplicitShapeT:__destruct() end
	inheritance.virtual(ImplicitShapeT, "__destruct")

	inheritance.purevirtual(ImplicitShapeT, "isovalue", {SpaceVec}->{real})
	inheritance.purevirtual(ImplicitShapeT, "isovalueAndSurfaceCoord", {SpaceVec}->{real, SurfVec})

	return ImplicitShapeT

end)

local ColoredImplicitShape = templatize(function(real, spaceDim, surfDim, colorDim)

	local SpaceVec = Vec(real, spaceDim)
	local SurfVec = Vec(real, surfDim)
	local ColorVec = Vec(real, colorDim)
	local ImplicitShapeT = ImplicitShape(real, spaceDim, surfDim)

	local struct ColoredImplicitShapeT
	{
		baseShape: &ImplicitShapeT
	}

	terra ColoredImplicitShapeT:__construct(baseShape: &ImplicitShapeT)
		self.baseShape = baseShape
	end

	terra ColoredImplicitShapeT:__destruct() end
	inheritance.virtual(ColoredImplicitShapeT, "__destruct")

	inheritance.purevirtual(ColoredImplicitShapeT, "isovalueAndColor", {SpaceVec}->{real, ColorVec})

	m.addConstructors(ColoredImplicitShapeT)
	return ColoredImplicitShapeT

end)

local ConstantColorImplicitShape = templatize(function(real, spaceDim, surfDim, colorDim)

	local SpaceVec = Vec(real, spaceDim)
	local SurfVec = Vec(real, surfDim)
	local ColorVec = Vec(real, colorDim)
	local ImplicitShapeT = ImplicitShape(real, spaceDim, surfDim)
	local ColoredImplicitShapeT = ShadedImplicitShape(real, spaceDim, surfDim, colorDim)

	local struct ConstantColorImplicitShapeT
	{
		color: ColorVec
	}
	inheritance.dynamicExtend(ColoredImplicitShapeT, ConstantColorImplicitShapeT)

	-- Assumes ownership of 'color'
	terra ConstantColorImplicitShapeT:__construct(baseShape: &ImplicitShapeT, color: ColorVec)
		ColoredImplicitShapeT.__construct(self, baseShape)
		self.color = color
	end

	terra ConstantColorImplicitShapeT:__destruct()
		m.destruct(self.color)
	end
	inheritance.virtual(ConstantColorImplicitShapeT, "__destruct")

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
	ColoredImplicitShape = ColoredImplicitShape,
	ConstantColorImplicitShape = ConstantColorImplicitShape
}