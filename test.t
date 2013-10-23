local m = terralib.require("mem")
local linalg = terralib.require("linalg")
local Vec3d = linalg.Vec(double, 3)

local terra test()
	var v = Vec3d.stackAlloc(1.0, 2.0, 3.0)
	var d = v:dot(v)
	m.destruct(v)
	return d
end

print(test())



-- local templatize = terralib.require("templatize")
-- local m = terralib.require("mem")
-- local Vector = terralib.require("vector")

-- local Shape = templatize(function(id)
-- 	local struct ShapeT {}
-- 	terra ShapeT:getID() return id end
-- 	m.addConstructors(ShapeT)
-- 	return ShapeT
-- end)

-- local struct Renderer {}
-- local shapeTypeID = 0
-- Renderer.shapeVectorFieldName = templatize(function(ShapeType)
-- 	local name = string.format("shapes%d", shapeTypeID)
-- 	shapeTypeID = shapeTypeID + 1
-- 	return name
-- end)
-- Renderer.shapeVectorFieldNames = {}

-- function Renderer.addShape(ShapeType)
-- 	local name = Renderer.shapeVectorFieldName(ShapeType)
-- 	if not Renderer.shapeVectorFieldNames[name] then
-- 		Renderer.entries:insert({field = name, type = Vector(ShapeType)})
-- 	end
-- 	return macro(function(renderer, shape)
-- 		return `renderer.[name]:push(shape)
-- 	end)
-- end

-- m.addConstructors(Renderer)

-- -------------

-- local S1 = Shape(1)
-- local S2 = Shape(2)

-- terra test()
-- 	var renderer = Renderer.stackAlloc()
-- 	var s1 = S1.stackAlloc()
-- 	var s2 = S2.stackAlloc()
-- 	[Renderer.addShape(S1)](renderer, s1)
-- 	[Renderer.addShape(S2)](renderer, s2)
-- 	m.destruct(s1)
-- 	m.destruct(s2)
-- end

-- test()