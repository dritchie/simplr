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


return
{
	ImplicitShape = ImplicitShape
}

