local m = terralib.require("mem")
local linalg = terralib.require("linalg")
local Vec = linalg.Vec
local Vec3d = linalg.Vec(double, 3)
local Vec2d = linalg.Vec(double, 2)
local Vec2u = linalg.Vec(uint, 2)
local Color = terralib.require("color")
local Color1d = Color(double, 1)
local im = terralib.require("image")
local RGBImage = im.Image(uint8, 3)
local RGBAImage = im.Image(uint8, 4)
local SampledFunction = terralib.require("sampledFunction")
local SampledFunction2d1d = SampledFunction(double, 2, 1)
local SampledImg = SampledFunction(double, 2, 3)
local patterns = terralib.require("samplePatterns")
local ImgGridPattern = patterns.RegularGridSamplingPattern(double, 2)
local ImplicitSampler = terralib.require("samplers").ImplicitSampler
local ImplicitSampler2d1d = ImplicitSampler(double, 2, 1)
local shapes = terralib.require("shapes")
local Circle2d1d = shapes.SphereImplicitShape(double, 2, 1)
local Capsule2d1d = shapes.CapsuleImplicitShape(double, 2, 1)
local ConstColorShape2d1d = shapes.ConstantColorImplicitShape(double, 2, 1)

local C = terralib.includecstring [[
#include <stdio.h>
]]

local terra testSampler()
	var zeros = Vec2d.stackAlloc(0.0)
	var ones = Vec2d.stackAlloc(1.0)
	var gridPattern = ImgGridPattern.stackAlloc(
		zeros,
		ones,
		Vec2u.stackAlloc(500, 500))
	var sfn = SampledFunction2d1d.stackAlloc()
	-- var circle = Circle2d1d.stackAlloc(Vec2d.stackAlloc(0.5, 0.5), 0.25)
	-- var colorWrapper = ConstColorShape2d1d.heapAlloc(&circle, Color1d.stackAlloc(1.0))
	var capsule = Capsule2d1d.stackAlloc(Vec2d.stackAlloc(0.5, 0.2), Vec2d.stackAlloc(0.5, 0.8), 0.05)
	var colorWrapper = ConstColorShape2d1d.heapAlloc(&capsule, Color1d.stackAlloc(1.0))
	var sampler = ImplicitSampler2d1d.stackAlloc(&sfn)
	sampler:addShape(colorWrapper)
	sampler:sample(gridPattern:getSamplePattern())
	var image = RGBAImage.stackAlloc(500, 500)
	[SampledFunction2d1d.saveToImage(RGBAImage)](&sfn, &image, zeros, ones)
	image:save(im.Format.PNG, "shape.png")
	m.destruct(image)
	m.destruct(sampler)
	m.destruct(sfn)
	m.destruct(gridPattern)
end
testSampler()

-- local terra testImageLoadAndSave()
-- 	var flowerPic = RGBImage.stackAlloc(im.Format.JPEG, "flowers.jpg")
-- 	var zeros = Vec2d.stackAlloc(0.0)
-- 	var ones = Vec2d.stackAlloc(1.0)
-- 	var gridPattern = ImgGridPattern.stackAlloc(zeros, ones,
-- 		Vec2u.stackAlloc(flowerPic:width(), flowerPic:height()))
-- 	var sfn = SampledImg.stackAlloc()
-- 	sfn:setSamplingPattern(gridPattern:getSamplePattern())
-- 	[SampledImg.loadFromImage(RGBImage)](&sfn, &flowerPic, zeros, ones)
-- 	var outputPic = RGBImage.stackAlloc(flowerPic:width(), flowerPic:height())
-- 	[SampledImg.saveToImage(RGBImage)](&sfn, &outputPic, zeros, ones)
-- 	outputPic:save(im.Format.JPEG, "output.jpg")
-- 	m.destruct(gridPattern)
-- 	m.destruct(sfn)
-- 	m.destruct(flowerPic)
-- 	m.destruct(outputPic)
-- end
-- testImageLoadAndSave()

-- local terra testPNG()
-- 	var blankImg = RGBImage.stackAlloc(500, 500)
-- 	blankImg:save(im.Format.PNG, "blank.png")
-- end
-- testPNG()

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