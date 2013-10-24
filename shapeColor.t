local m = terralib.require("mem")
local templatize = terralib.require("templatize")
local inheritance = terralib.require("inheritance")
local Vec = terralib.require("linalg").Vec
local Color = terralib.require("color")
local shapes = terralib.require("shapes")
local ImplicitShape = shapes.ImplicitShape


local ColoredImplicitShapeBase = templatize(function(real, spaceDim, colorDim)

	local SpaceVec = Vec(real, spaceDim)
	local ColorVec = Color(real, colorDim)

	local struct ColoredImplicitShapeBaseT {}

	terra ColoredImplicitShapeBaseT:__destruct() end
	inheritance.virtual(ColoredImplicitShapeBaseT, "__destruct")

	inheritance.purevirtual(ColoredImplicitShapeBaseT, "isovalueAndColor", {SpaceVec}->{real, ColorVec})

	return ColoredImplicitShapeBaseT

end)


local ColoredImplicitShape = templatize(function(real, spaceDim, surfDim, colorDim)

	local SpaceVec = Vec(real, spaceDim)
	local SurfVec = Vec(real, surfDim)
	local ColorVec = Color(real, colorDim)
	local ImplicitShapeT = ImplicitShape(real, spaceDim, surfDim)
	local ColoredImplicitShapeBaseT = ColoredImplicitShapeBase(real, spaceDim, colorDim)

	local struct ColoredImplicitShapeT
	{
		baseShape: &ImplicitShapeT
	}
	inheritance.dynamicExtend(ColoredImplicitShapeBaseT, ColoredImplicitShapeT)

	terra ColoredImplicitShapeT:__construct(baseShape: &ImplicitShapeT)
		self.baseShape = baseShape
	end

	m.addConstructors(ColoredImplicitShapeT)
	return ColoredImplicitShapeT

end)

local ConstantColorImplicitShape = templatize(function(real, spaceDim, surfDim, colorDim)

	local SpaceVec = Vec(real, spaceDim)
	local SurfVec = Vec(real, surfDim)
	local ColorVec = Color(real, colorDim)
	local ImplicitShapeT = ImplicitShape(real, spaceDim, surfDim)
	local ColoredImplicitShapeT = ColoredImplicitShape(real, spaceDim, surfDim, colorDim)

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
	ColoredImplicitShape = ColoredImplicitShapeBase,
	ConstantColorImplicitShape = ConstantColorImplicitShape
}