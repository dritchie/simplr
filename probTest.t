-- Include Quicksand
terralib.require("prob")
local rand = terralib.require("prob.random")

local m = terralib.require("mem")
local util = terralib.require("util")
local templatize = terralib.require("templatize")
local ad = terralib.require("ad")

local Vector = terralib.require("vector")

local linalg = terralib.require("linalg")
local Vec = linalg.Vec
local Vec2d = linalg.Vec(double, 2)
local Vec2u = linalg.Vec(uint, 2)

local BBox = terralib.require("bbox")

local Color = terralib.require("color")
local Color1d = Color(double, 1)

local im = terralib.require("image")
local RGBImage = im.Image(uint8, 3)

local patterns = terralib.require("samplePatterns")
local ImgGridPattern = patterns.RegularGridSamplingPattern(Vec2d)

local shapes = terralib.require("shapes")
local Shape2d1d = shapes.ImplicitShape(Vec2d, Color1d)
local Capsule2d1d = shapes.CapsuleImplicitShape(Vec2d, Color1d)
local Circle2d1d = shapes.SphereImplicitShape(Vec2d, Color1d)
local ConstColorShape2d1d = shapes.ConstantColorImplicitShape(Vec2d, Color1d)

local SfnOpts = terralib.require("sampledFnOptions")
local SampledFunction = terralib.require("sampledFunction")
local SampledFunction2d1d = SampledFunction(Vec2d, Color1d)
-- local SampledFunction2d1d = SampledFunction(Vec2d, Color1d, SfnOpts.ClampFns.SoftMin(10, 1.0), SfnOpts.AccumFns.Over())

local ImplicitSampler = terralib.require("samplers").ImplicitSampler
local ImplicitSampler2d1d = ImplicitSampler(SampledFunction2d1d, Shape2d1d)

local C = terralib.includecstring [[
#include <stdio.h>
#include <string.h>
]]

--------------

local lerp = macro(function(lo, hi, t)
	return `(1.0-t)*lo + t*hi
end)


-- Load up the target image. This only needs to be done once, since
--    the type of this object is not dependent upon the 'real' type
-- 'expandFactor' says how much we want to expand the sample grid around the image sample
--    locations. e.g. a value of 3 will place the actual image at the center of a 3x3 grid of 
--    sample locations, with the outer 8 blocks having zero values at every sample point.
local function loadTargetImage(SampledFunctionType, filename, expandFactor)
	expandFactor = expandFactor or 1
	local target = m.gc(terralib.new(SampledFunctionType))
	local terra loadTarget(targetFilename: rawstring)
		target:__construct()
		var image = RGBImage.stackAlloc(im.Format.PNG, targetFilename)
		var imgWidth = image:width()
		var imgHeight = image:height()
		-- For now (for simplicity) we just handle square images
		if imgWidth ~= imgHeight then util.fatalError("Target image width ~= height\n") end
		var expandWidth = imgWidth * expandFactor
		var exandHeight = imgHeight * expandFactor
		var mincoord = 0.5 - expandFactor*0.5
		var maxcoord = 0.5 + expandFactor*0.5
		var grid = ImgGridPattern.stackAlloc(
			Vec2d.stackAlloc(mincoord),
			Vec2d.stackAlloc(maxcoord),
			Vec2u.stackAlloc(expandWidth, exandHeight))
		target:ownSamplingPattern(grid:getSamplePattern())
		[SampledFunctionType.loadFromImage(RGBImage)](&target, &image,
			Vec2d.stackAlloc(0.0), Vec2d.stackAlloc(1.0))
		m.destruct(grid)
		m.destruct(image)
		return imgWidth, imgHeight
	end
	local width, height = loadTarget(filename)
	return {target = target, width = width, height = height}
end


-- Calculate squared error between two sample sets
local sqErr = macro(function(srcPointer, tgtPointer)
	local SampledFunctionT1 = srcPointer:gettype().type
	local SampledFunctionT2 = tgtPointer:gettype().type
	assert(SampledFunctionT1.__generatorTemplate == SampledFunction)
	assert(SampledFunctionT2.__generatorTemplate == SampledFunction)
	local accumType = SampledFunctionT1.ColorVec.RealType
	local function makeProcessFn(accum)
		return macro(function(color1, color2)
			return quote [accum] = [accum] + [color1]:distSq(@[color2]) end
		end) 
	end
	return quote
		var accum : accumType = 0.0
		[SampledFunctionT1.lockstep(SampledFunctionT2, makeProcessFn(accum))](srcPointer, tgtPointer)
	in
		accum
	end
end)

-- Calculate mean squared error between two sample sets
local mse = macro(function(srcPointer, tgtPointer)
	local SampledFunctionT1 = srcPointer:gettype().type
	local SampledFunctionT2 = tgtPointer:gettype().type
	assert(SampledFunctionT1.__generatorTemplate == SampledFunction)
	assert(SampledFunctionT2.__generatorTemplate == SampledFunction)
	local accumType = SampledFunctionT1.ColorVec.RealType
	local function makeProcessFn(accum)
		return macro(function(color1, color2)
			return quote [accum] = [accum] + [color1]:distSq(@[color2]) end
		end) 
	end
	return quote
		var accum : accumType = 0.0
		[SampledFunctionT1.lockstep(SampledFunctionT2, makeProcessFn(accum))](srcPointer, tgtPointer)
		var result = accum / srcPointer.samples.size
	in
		result
	end
end)


-- Likelihood module for calculating MSE with respect to a sampled target function
local function sampledErrorLikelihoodModule(priorModuleWithSampling, targetData, strength)
	local target = targetData.target
	return function()
		local P = priorModuleWithSampling()
		local ReturnType = P.prior:gettype().returns[1]
		local SamplerType = P.sample:gettype().parameters[2].type
		local SampledFunctionType = SamplerType.SampledFunctionType
		local SamplingPatternType = P.sample:gettype().parameters[3].type

		-- The sample set and sampler are 'global' to the inference chain since it
		--    is wasteful to reconstruct these every iteration.
		-- Technically, there will end up being one set of globals for each 
		--    specialization of the program.
		local samples = m.gc(terralib.new(SampledFunctionType))
		local sampler = m.gc(terralib.new(SamplerType))
		local terra initSamplerGlobals()
			samples = SampledFunctionType.stackAlloc()
			sampler = SamplerType.stackAlloc(&samples)

		end
		initSamplerGlobals()

		local terra likelihood(value: &ReturnType)
			P.sample(value, &sampler, target.samplingPattern)
			-- var err = sqErr(&samples, &target)
			var err = mse(&samples, &target)
			var l = -strength*err
			return l
		end

		return 
		{
			likelihood = likelihood,
			targetData = targetData
		}
	end
end


-- Make a bayesian inference program
local function bayesProgram(priorModule, likelihoodModule)
	return function()
		local prior = priorModule().prior
		local likelihood = likelihoodModule().likelihood
		return terra()
			var structure = prior()
			factor(likelihood(&structure))
			return structure
		end
	end
end

-- Do inference
local function doMCMC(program, kernel, numsamps, verbose)
	if verbose == nil then verbose = true end
	local terra fn()
		return [mcmc(program, kernel, {numsamps=numsamps, verbose=verbose})]
	end
	return m.gc(fn())
end


-- Render a video of the sequence of accepted states
local function renderVideo(pmodule, targetData, valueSeq, directory, name)
	io.write("Rendering video...")
	io.flush()
	local moviefilename = string.format("%s/%s.mp4", directory, name)
	local framebasename = directory .. "/movieframe_%06d.png"
	local framewildcard = directory .. "/movieframe_*.png"
	local M = pmodule()
	local SampledFunctionType = M.SampledFunctionType
	local SamplerType = M.SamplerType
	local width = targetData.width
	local height = targetData.height
	-- We render every frame of a 1000 frame sequence. We want to linearly adjust downward
	--    for longer sequences
	-- 1000/1 = numValues/x
	local numValues = valueSeq.size
	local frameSkip = math.ceil(numValues / 1000.0)
	local function renderFrames(valueSeq, basename)
		return quote
			var samples = SampledFunctionType.stackAlloc()
			var grid = ImgGridPattern.stackAlloc(
				Vec2d.stackAlloc(0.0),
				Vec2d.stackAlloc(1.0),
				Vec2u.stackAlloc(width, height))
			var sampler = SamplerType.stackAlloc(&samples)
			var framename : int8[1024]
			var image = RGBImage.stackAlloc(width, height)
			var zeros = Vec2d.stackAlloc(0.0)
			var ones = Vec2d.stackAlloc(1.0)
			var incr = [int]([frameSkip])
			var framenumber = 0
			for i=0,[valueSeq].size,incr do
				var val = [valueSeq]:getPointer(i)
				M.sample(&val.value, &sampler, grid:getSamplePattern())
				[SampledFunctionType.saveToImage(RGBImage)](&samples, &image, zeros, ones)
				C.sprintf(framename, [basename], framenumber)
				framenumber = framenumber + 1
				image:save(im.Format.PNG, framename)
			end
			m.destruct(image)
			m.destruct(grid)
			m.destruct(sampler)
			m.destruct(samples)
		end
	end
	local terra doRenderFrames() : {} [renderFrames(valueSeq, framebasename)] end
	doRenderFrames()
	util.wait(string.format("ffmpeg -y -r 30 -i %s -c:v libx264 -r 30 -pix_fmt yuv420p %s 2>&1",
		framebasename, moviefilename))
	util.wait(string.format("rm -f %s", framewildcard))
	print("done.")
end

---------------------


-- Probabilistic code for random polylines.

local PolyinesRetType = templatize(function(real)
	local Vec2 = Vec(real, 2)
	local struct PolyinesRetTypeT { points: Vector(Vec2), smoothParam: real }
	terra PolyinesRetTypeT:__construct() m.init(self.points) end
	terra PolyinesRetTypeT:__construct(p: Vector(Vec2), s: real)
		self.points = p; self.smoothParam = s
	end
	terra PolyinesRetTypeT:__copy(other: &PolyinesRetTypeT)
		self.points = m.copy(other.points)
		self.smoothParam = other.smoothParam
	end
	terra PolyinesRetTypeT:__destruct()
		m.destruct(self.points)
	end
	m.addConstructors(PolyinesRetTypeT)
	return PolyinesRetTypeT
end)

local function polylineModule(doSmoothing, inferenceTime)
	return function()
		local Vec2 = Vec(real, 2)
		local Color1 = Color(real, 1)
		local SampledFunctionType = nil
		if doSmoothing then
			SampledFunctionType = SampledFunction(Vec2d, Color1, SfnOpts.ClampFns.Min(1.0), SfnOpts.AccumFns.Over())
		else
			SampledFunctionType = SampledFunction(Vec2d, Color1)
		end
		local ShapeType = shapes.ImplicitShape(Vec2, Color1)
		local Capsule = shapes.CapsuleImplicitShape(Vec2, Color1)
		local ColoredShape = shapes.ConstantColorImplicitShape(Vec2, Color1)
		local Sampler = ImplicitSampler(SampledFunctionType, ShapeType)

		local RetType = PolyinesRetType(real)

		-- Shorthand for common non-structural ERPs
		local ngaussian = macro(function(mean, sd)
			return `gaussian([mean], [sd], {structural=false})
		end)
		local nuniformWithFalloff = macro(function(lo, hi)
			return `uniformWithFalloff([lo], [hi], {structural=false})
		end)

		local terra rotate(dir: Vec2, angle: real)
			var x = dir(0)
			var y = dir(1)
			var cosang = ad.math.cos(angle)
			var sinang = ad.math.sin(angle)
			return Vec2.stackAlloc(x*cosang - y*sinang, y*cosang + x*sinang)
		end

		-- A bunch of constants. Perhaps factor these out?
		local numSegs = 40
		local startPosMin = 0.0
		local startPosMax = 1.0
		local startDirMin = 0.0
		local startDirMax = 2.0*math.pi
		local lengthMin = 0.01
		local lengthMax = 0.1
		local anglePriorMean = 0.0
		local anglePriorSD = math.pi/6.0
		local lineThickness = 0.01
		local centerPenaltyStrength = 0.4

		-- The 'prior' part of the program which generates the polyine to be rendered.
		local polyline = pfn(terra()
			var points = [Vector(Vec2)].stackAlloc(numSegs, Vec2.stackAlloc(0.0))
			points:getPointer(0)(0) = nuniformWithFalloff(startPosMin, startPosMax)
			points:getPointer(0)(1) = nuniformWithFalloff(startPosMin, startPosMax)
			var dir = rotate(Vec2.stackAlloc(1.0, 0.0), nuniformWithFalloff(startDirMin, startDirMax))
			var len : real = 0.0
			for i=1,numSegs do
				len = nuniformWithFalloff(lengthMin, lengthMax)
				dir = rotate(dir, ngaussian(anglePriorMean, anglePriorSD))
				points:set(i, points:get(i-1) + (len*dir))
				-- factor([rand.gaussian_logprob(real)](points(i)(0), 0.5, centerPenaltyStrength))
				-- factor([rand.gaussian_logprob(real)](points(i)(1), 0.5, centerPenaltyStrength))
			end
			var smoothingAmount : real
			[(not doSmoothing) and quote end or
			quote
				-- smoothingAmount = 0.001
				smoothingAmount = lerp(0.01, 0.001, inferenceTime)
			end]
			return RetType.stackAlloc(points, smoothingAmount)
		end)
		-- local polyline = pfn(terra()
		-- 	var points = [Vector(Vec2)].stackAlloc(numSegs, Vec2.stackAlloc(0.0))
		-- 	for i=1,numSegs do
		-- 		points:getPointer(i)(0) = nuniformWithFalloff(startPosMin, startPosMax)
		-- 		points:getPointer(i)(1) = nuniformWithFalloff(startPosMin, startPosMax)
		-- 	end
		-- 	var smoothingAmount : real
		-- 	[(not doSmoothing) and quote end or
		-- 	quote
		-- 		-- smoothingAmount = 0.001
		-- 		smoothingAmount = lerp(0.01, 0.001, inferenceTime)
		-- 	end]
		-- 	return RetType.stackAlloc(points, smoothingAmount)
		-- end)

		-- Rendering polyline (used by likelihood module)
		local terra renderSegments(retval: &RetType, sampler: &Sampler, pattern: &Vector(Vec2d))
			sampler:clear()
			for i=0,retval.points.size-1 do
				var capsule = Capsule.heapAlloc(retval.points:get(i), retval.points:get(i+1), lineThickness)
				var coloredCapsule = ColoredShape.heapAlloc(capsule, Color1.stackAlloc(1.0))
				sampler:addShape(coloredCapsule)
			end
			[(not doSmoothing) and (`sampler:sampleSharp(pattern)) or (`sampler:sampleSmooth(pattern, retval.smoothParam))]
		end

		-- Module exports
		return
		{
			prior = polyline,
			sample = renderSegments,
			SampledFunctionType = SampledFunctionType,
			SamplerType = Sampler
		}
	end
end




-- Probabilistic code for rendering with random circles

local Circle = templatize(function(real)
	local Vec2 = Vec(real, 2)
	local struct CircleT { center: Vec2, radius: real }
	return CircleT
end)

-- Super annoying, but if I want to be able to render things exactly as they looked during inference,
--    I need to package up the smoothing param in the return value of the computation.
local CirclesRetType = templatize(function(real)
	local struct CircleRetTypeT { circles: Vector(Circle(real)), smoothParam: real }
	terra CircleRetTypeT:__construct() m.init(self.circles) end
	terra CircleRetTypeT:__construct(c: Vector(Circle(real)), s: real)
		self.circles = c; self.smoothParam = s
	end
	terra CircleRetTypeT:__copy(other: &CircleRetTypeT)
		self.circles = m.copy(other.circles)
		self.smoothParam = other.smoothParam
	end
	terra CircleRetTypeT:__destruct()
		m.destruct(self.circles)
	end
	m.addConstructors(CircleRetTypeT)
	return CircleRetTypeT
end)

local function circlesModule(doSmoothing, inferenceTime)
	return function()
		local Vec2 = Vec(real, 2)
		local Color1 = Color(real, 1)
		local CircleT = Circle(real)
		local SampledFunctionType = nil
		if doSmoothing then
			SampledFunctionType = SampledFunction(Vec2d, Color1, SfnOpts.ClampFns.Min(1.0), SfnOpts.AccumFns.Over())
		else
			SampledFunctionType = SampledFunction(Vec2d, Color1)
		end
		local ShapeType = shapes.ImplicitShape(Vec2, Color1)
		local CircleShape = shapes.SphereImplicitShape(Vec2, Color1)
		local ColoredShape = shapes.ConstantColorImplicitShape(Vec2, Color1)
		local Sampler = ImplicitSampler(SampledFunctionType, ShapeType)

		local RetType = CirclesRetType(real)

		-- Shorthand for common non-structural ERPs
		local nuniformWithFalloff = macro(function(lo, hi)
			return `uniformWithFalloff([lo], [hi], {structural=false})
		end)
		local ngamma = macro(function(a, b)
			return `gamma([a], [b], {structural=false})
		end)

		-- Constants
		local numCircles = 40
		local posMin = 0.0
		local posMax = 1.0
		local radMin = 0.025
		local radMax = 0.1
		local smoothAlpha = 10.0
		local smoothBeta = 10.0

		local circles = pfn(terra()
			var circs = [Vector(CircleT)].stackAlloc(numCircles, CircleT { Vec2.stackAlloc(0.0), 1.0 } )
			for i=0,numCircles do
				circs:getPointer(i).center(0) = nuniformWithFalloff(posMin, posMax)
				circs:getPointer(i).center(1) = nuniformWithFalloff(posMin, posMax)
				circs:getPointer(i).radius = nuniformWithFalloff(radMin, radMax)
			end
			var smoothingAmount : real
			[(not doSmoothing) and quote end or
			quote
				-- smoothingAmount = 0.005
				smoothingAmount = lerp(0.01, 0.001, inferenceTime)
				-- smoothingAmount = 1.0 / ngamma(smoothAlpha, smoothBeta)
			end]
			return RetType.stackAlloc(circs, smoothingAmount)
		end)

		local terra renderCircles(retval: &RetType, sampler: &Sampler, pattern: &Vector(Vec2d))
			sampler:clear()
			for i=0,retval.circles.size do
				var c = retval.circles:getPointer(i)
				var cShape = CircleShape.heapAlloc(c.center, c.radius)
				var coloredShape = ColoredShape.heapAlloc(cShape, Color1.stackAlloc(1.0))
				sampler:addShape(coloredShape)
			end
			[(not doSmoothing) and (`sampler:sampleSharp(pattern)) or (`sampler:sampleSmooth(pattern, retval.smoothParam))]
		end

		return
		{
			prior = circles, 
			sample = renderCircles,
			SampledFunctionType = SampledFunctionType,
			SamplerType = Sampler
		}
	end
end


------------------

local numsamps = 1000

local doAnnealing = false

local inferenceTime = global(double)
local scheduleFunction = macro(function(iter, currTrace)
	local setTime = (quote inferenceTime = [double](iter) / numsamps end)
	if doAnnealing then
		return quote
			[setTime]
			currTrace.temperature = 1.0/(0.0001 + inferenceTime)
		end
	else return setTime end
end)

-- local pmodule = polylineModule(false, inferenceTime)
-- local targetImgName = "squiggle_200.png"
local pmodule = circlesModule(true, inferenceTime)
local targetImgName = "symbol_200.png"

local constraintStrength = 2000
local expandFactor = 1
constraintStrength = expandFactor*expandFactor*constraintStrength
local targetData = loadTargetImage(SampledFunction2d1d, targetImgName, expandFactor)
local lmodule = sampledErrorLikelihoodModule(pmodule, targetData, constraintStrength)
local program = bayesProgram(pmodule, lmodule)

-- local kernel = RandomWalk()
-- local kernel = ADRandomWalk()
local kernel = HMC()

local kernel = Schedule(kernel, scheduleFunction)
local values = doMCMC(program, kernel, numsamps)
renderVideo(pmodule, targetData, values, "renders", "movie")






