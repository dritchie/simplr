local m = terralib.require("mem")
local linalg = terralib.require("linalg")
local Vec3d = linalg.Vec(double, 3)
local im = terralib.require("image")

local RGBImage = im.Image(uint8, 3)

local terra test()
	var flowerPic = RGBImage.stackAlloc(im.Format.JPEG, "flowers.jpg")
	m.destruct(flowerPic)
end
test()

-- local terra test()
-- 	var v = Vec3d.stackAlloc(1.0, 2.0, 3.0)
-- 	var d = v:dot(v)
-- 	m.destruct(v)
-- 	return d
-- end

-- print(test())