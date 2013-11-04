-- Include Quicksand
terralib.require("prob")


local m = terralib.require("mem")
local templatize = terralib.require("templatize")
local ad = terralib.require("ad")

local Vector = terralib.require("vector")

local linalg = terralib.require("linalg")
local Vec = linalg.Vec
local Vec2d = linalg.Vec(double, 2)
local Vec2u = linalg.Vec(uint, 2)

local Color = terralib.require("color")
local Color1d = Color(double, 1)

local im = terralib.require("image")
local RGBImage = im.Image(uint8, 3)

local patterns = terralib.require("samplePatterns")
local ImgGridPattern = patterns.RegularGridSamplingPattern(Vec2d)

local shapes = terralib.require("shapes")
local Shape2d1d = shapes.ImplicitShape(Vec2d, Color1d)
local Capsule2d1d = shapes.CapsuleImplicitShape(Vec2d, Color1d)
local ConstColorShape2d1d = shapes.ConstantColorImplicitShape(Vec2d, Color1d)

local SfnOpts = terralib.require("sampledFnOptions")
local SampledFunction = terralib.require("sampledFunction")
local SampledFunction2d1d = SampledFunction(Vec2d, Color1d)
-- local SampledFunction2d1d = SampledFunction(Vec2d, Color1d, SfnOpts.ClampFns.SoftMin(10, 1.0), SfnOpts.AccumFns.Over())

local ImplicitSampler = terralib.require("samplers").ImplicitSampler
local ImplicitSampler2d1d = ImplicitSampler(SampledFunction2d1d, Shape2d1d)

local C = terralib.includecstring [[
#include <stdio.h>
]]

--------------


-- Calculate mean squared error between two sample sets
local mse = templatize(function(SampledFunctionT1, SampledFunctionT2)
	local function makeProcessFn(accum)
		return function(color1, color2)
			return quote [accum] = [accum] + [color1]:distSq(@[color2]) end
		end 
	end
	return terra(fn1: &SampledFunctionT1, fn2: &SampledFunctionT2)
		var accum = 0.0
		[SampledFunctionT1.lockstep(SampledFunctionT2, makeProcessFn(accum))](fn1, fn2)
		return accum / fn1.samples.size
	end
end)

-- Load up the target image. This only needs to be done once, since
--    the type of this object is not dependent upon the 'real' type
local target = m.gc(terralib.new(SampledFunction2d1d))
local targetFilename = "squiggle_200.png"
local imgWidth = global(int)
local imgHeight = global(int)
local grid = global(ImgGridPattern)
local terra loadTarget()
	target:__construct()
	var image = RGBImage.stackAlloc(im.Format.PNG, targetFilename)
	imgWidth = image:width()
	imgHeight = image:height()
	grid = ImgGridPattern.stackAlloc(
		Vec2d.stackAlloc(0.0),
		Vec2d.stackAlloc(1.0),
		Vec2u.stackAlloc(imgWidth, imgHeight))
	target:setSamplingPattern(grid:getSamplePattern())
	[SampledFunction2d1d.loadFromImage(RGBImage)](&target, &image,
		Vec2d.stackAlloc(0.0), Vec2d.stackAlloc(1.0))
	m.destruct(image)
end
loadTarget()

-- The probabilistic program we do inference over
local function program()

	-- Shorthand for common non-structural ERPs
	local ngaussian = macro(function(mean, sd)
		return `gaussian([mean], [sd], {structural=false})
	end)
	local ngamma = macro(function(alpha, beta)
		return `gamma([alpha], [beta], {structural=false})
	end)

	local terra rotate(dir: Vec2d, angle: double)
		var x = dir.entries[0]
		var y = dir.entries[1]
		var cosang = ad.math.cos(angle)
		var sinang = ad.math.sin(angle)
		return Vec2d.stackAlloc(x*cosang - y*sinang, y*cosang + x*sinang)
	end

	-- A bunch of constants. Perhaps factor these out?
	local numSegs = 20
	local startPosPriorMean = 0.5
	local startPosPriorSD = 0.2
	local startDirPriorMean = 0.0
	local startDirPriorSD = math.pi/3.0
	local lengthPriorAlpha = 0.5
	local lengthPriorBeta = 0.5
	local anglePriorMean = 0.0
	local anglePriorSD = 0.1

	-- The 'prior' part of the program which generates the polyine to be rendered.
	local polyline = pfn(terra()
		var points = [Vector(Vec2d)].stackAlloc(numSegs, Vec2d.stackAlloc(0.0))
		points:getPointer(0).entries[0] = ngaussian(startPosPriorMean, startPosPriorSD)
		points:getPointer(0).entries[1] = ngaussian(startPosPriorMean, startPosPriorSD)
		var dir = rotate(Vec2d.stackAlloc(1.0, 0.0), ngaussian(startDirPriorMean, startDirPriorSD))
		var len = 0.0
		for i=1,numSegs do
			len = ngamma(lengthPriorAlpha, lengthPriorBeta)
			dir = rotate(dir, ngaussian(anglePriorMean, anglePriorSD))
			points:set(i, points:get(i-1) + (len*dir))
		end
		return points
	end)

	-- The sample set and sampler are 'global' to the inference chain since it
	--    is wasteful to reconstruct these every iteration.
	-- Technically, there will end up being one set of globals for each 
	--    specialization of the program.
	local samples = m.gc(terralib.new(SampledFunction2d1d))
	local sampler = m.gc(terralib.new(ImplicitSampler2d1d))
	local terra initSamplerGlobals()
		samples = SampledFunction2d1d.stackAlloc()
		sampler = ImplicitSampler2d1d.stackAlloc(&samples)

	end
	initSamplerGlobals()

	-- Likelihood subroutine (renders polyline)
	local lineThickness = 0.02
	local constColor = m.gc(terralib.new(Color1d))
	constColor:__construct(1.0)
	local terra renderSegments(points: &Vector(Vec2d))
		sampler:clear()
		for i=0,points.size-1 do
			var capsule = Capsule2d1d.heapAlloc(points:get(i), points:get(i+1), lineThickness)
			var coloredCapsule = ConstColorShape2d1d.heapAlloc(capsule, constColor)
			sampler:addShape(coloredCapsule)
		end
		var spattern = grid:getSamplePattern()
		sampler:sampleSharp(spattern)
	end

	-- Overall likelihood function, which computes MSE between rendered polyline
	--   and target image.
	local terra renderAndMatchFactor(points: &Vector(Vec2d))
		renderSegments(points)
		return [mse(SampledFunction2d1d, SampledFunction2d1d)](&samples, &target)
	end

	-- The top-level computation that inference runs on.
	return terra()
		var points = polyline()
		factor(renderAndMatchFactor(&points))
		return points
	end
end


-- Do inference!
local kernel = RandomWalk()
local numsamps = 1000
local function doInference()
	local terra fn()
		return [mcmc(program, kernel, {numsamps=numsamps, verbose=true})]
	end
	return m.gc(fn())
end
doInference()




