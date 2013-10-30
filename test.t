local m = terralib.require("mem")

local linalg = terralib.require("linalg")
local Vec = linalg.Vec
local Vec3d = linalg.Vec(double, 3)
local Vec2d = linalg.Vec(double, 2)
local Vec2u = linalg.Vec(uint, 2)
local Vec3f = linalg.Vec(float, 3)

local Color = terralib.require("color")
local Color1d = Color(double, 1)
local Color3d = Color(double, 3)

local im = terralib.require("image")
local RGBImage = im.Image(uint8, 3)

local patterns = terralib.require("samplePatterns")
local ImgGridPattern = patterns.RegularGridSamplingPattern(Vec2d)

local shapes = terralib.require("shapes")
local Shape2d1d = shapes.ImplicitShape(Vec2d, Color1d)
local Circle2d1d = shapes.SphereImplicitShape(Vec2d, Color1d)
local Capsule2d1d = shapes.CapsuleImplicitShape(Vec2d, Color1d)
local ConstColorShape2d1d = shapes.ConstantColorImplicitShape(Vec2d, Color1d)

local SfnOpts = terralib.require("sampledFnOptions")
local SampledFunction = terralib.require("sampledFunction")
-- local SampledFunction2d1d = SampledFunction(Vec2d, Color1d)
local SampledFunction2d1d = SampledFunction(Vec2d, Color1d, SfnOpts.ClampFns.SoftMin(10, 1.0), SfnOpts.AccumFns.Over())
local SampledImg = SampledFunction(Vec2d, Color3d)

local ImplicitSampler = terralib.require("samplers").ImplicitSampler
local ImplicitSampler2d1d = ImplicitSampler(SampledFunction2d1d, Shape2d1d)

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
	var sampler = ImplicitSampler2d1d.stackAlloc(&sfn)

	var circle = Circle2d1d.stackAlloc(Vec2d.stackAlloc(0.4, 0.5), 0.1)
	var coloredCircle = ConstColorShape2d1d.heapAlloc(&circle, Color1d.stackAlloc(1.0))
	var circle2 = Circle2d1d.stackAlloc(Vec2d.stackAlloc(0.6, 0.5), 0.1)
	var coloredCircle2 = ConstColorShape2d1d.heapAlloc(&circle2, Color1d.stackAlloc(1.0))
	var circle3 = Circle2d1d.stackAlloc(Vec2d.stackAlloc(0.5, 0.7), 0.1)
	var coloredCircle3 = ConstColorShape2d1d.heapAlloc(&circle3, Color1d.stackAlloc(1.0))
	-- var capsule = Capsule2d1d.stackAlloc(Vec2d.stackAlloc(0.5, 0.2), Vec2d.stackAlloc(0.5, 0.8), 0.05)
	-- var coloredCapsule = ConstColorShape2d1d.heapAlloc(&capsule, Color1d.stackAlloc(1.0))
	-- sampler:addShape(coloredCapsule)
	sampler:addShape(coloredCircle)
	sampler:addShape(coloredCircle2)
	sampler:addShape(coloredCircle3)

	sampler:sampleSmooth(gridPattern:getSamplePattern(), 0.01)
	-- sampler:sampleSharp(gridPattern:getSamplePattern())

	var image = RGBImage.stackAlloc(500, 500)
	[SampledFunction2d1d.saveToImage(RGBImage)](&sfn, &image, zeros, ones)
	image:save(im.Format.PNG, "shape.png")
	m.destruct(image)
	m.destruct(sampler)
	m.destruct(sfn)
	m.destruct(gridPattern)
end
-- ImplicitSampler2d1d.methods.sampleSharp:printpretty()
-- ImplicitSampler2d1d.methods.sampleSmooth:printpretty()
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
-- 	var v2 = Vec3f(v)
-- 	m.destruct(v)
-- 	return d
-- end
-- print(testVec())



