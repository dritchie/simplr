local m = terralib.require("mem")
local linalg = terralib.require("linalg")
local Vec = linalg.Vec
local Vec3d = linalg.Vec(double, 3)
local Vec2d = linalg.Vec(double, 2)
local im = terralib.require("image")
local RGBImage = im.Image(uint8, 3)
local SampledFunction = terralib.require("sampledFunction")
local SampledImg = SampledFunction(double, 2, 3)
local patterns = terralib.require("samplePatterns")
local ImgGridPattern = patterns.RegularGridSamplingPattern(double, 2)

local terra testImageLoadAndSave()
	var flowerPic = RGBImage.stackAlloc(im.Format.JPEG, "flowers.jpg")
	var zeros = Vec2d.stackAlloc(0.0)
	var ones = Vec2d.stackAlloc(1.0)
	var gridPattern = ImgGridPattern.stackAlloc(zeros, ones,
		[Vec(uint, 2)].stackAlloc(flowerPic:width(), flowerPic:height()))
	var sfn = SampledImg.stackAlloc()
	sfn:setSamplingPattern(gridPattern:getSamplePattern())
	[SampledImg.loadFromImage(RGBImage)](&sfn, &flowerPic, zeros, ones)
	var outputPic = RGBImage.stackAlloc(flowerPic:width(), flowerPic:height())
	[SampledImg.saveToImage(RGBImage)](&sfn, &outputPic, zeros, ones)
	outputPic:save(im.Format.JPEG, "output.jpg")
	m.destruct(gridPattern)
	m.destruct(sfn)
	m.destruct(flowerPic)
	m.destruct(outputPic)
end
testImageLoadAndSave()

-- local terra testImage()
-- 	var flowerPic = RGBImage.stackAlloc(im.Format.JPEG, "flowers.jpg")
-- 	m.destruct(flowerPic)
-- end
-- testImage()

-- local terra testVec()
-- 	var v = Vec3d.stackAlloc(1.0, 2.0, 3.0)
-- 	var d = v:dot(v)
-- 	m.destruct(v)
-- 	return d
-- end
-- print(testVec())