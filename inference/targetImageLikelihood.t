local m = terralib.require("mem")
local util = terralib.require("util")
local ad = terralib.require("ad")

local im = terralib.require("image")
local RGBImage = im.Image(uint8, 3)

local Vec = terralib.require("linalg").Vec
local Vec2d = Vec(double, 2)
local Vec2u = Vec(uint, 2)

local patterns = terralib.require("samplePatterns")
local ImgGridPattern = patterns.RegularGridSamplingPattern(Vec2d)

------------------------

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

-- Calculate mean squared error between two sample sets
local mse = macro(function(srcPointer, tgtPointer)
	local SampledFunctionT1 = srcPointer:gettype().type
	local SampledFunctionT2 = tgtPointer:gettype().type
	local accumType = SampledFunctionT1.ColorVec.RealType
	local function makeProcessFn(accum)
		return macro(function(color1, color2)
			return quote
				var err = [color1]:distSq(@[color2])
				-- if not (@[color2] == 0.0) then 
					[accum] = [accum] + err
				-- end
			end
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


-- Calculate mean squared error between two sample sets
-- Return the resulting error in two components: the error from target pixels with value 0,
--    and the error from target pixels with value > 0.
local mseComps = macro(function(srcPointer, tgtPointer)
	local SampledFunctionT1 = srcPointer:gettype().type
	local SampledFunctionT2 = tgtPointer:gettype().type
	local accumType = SampledFunctionT1.ColorVec.RealType
	local function makeProcessFn(accumZero, accumNonZero)
		return macro(function(color1, color2)
			return quote
				var err = [color1]:distSq(@[color2])
				if @[color2] == 0.0 then
					[accumZero] = [accumZero] + err
				else
					[accumNonZero] = [accumNonZero] + err
				end
			end
		end) 
	end
	return quote
		var accumZero : accumType = 0.0
		var accumNonZero : accumType = 0.0
		[SampledFunctionT1.lockstep(SampledFunctionT2, makeProcessFn(accumZero, accumNonZero))](srcPointer, tgtPointer)
		var resultZero = accumZero / srcPointer.samples.size
		var resultNonzero = accumNonZero / srcPointer.samples.size
	in
		resultZero, resultNonzero
	end
end)


-- Likelihood module for calculating MSE with respect to a sampled target function
local function mseLikelihoodModule(priorModuleWithSampling, targetData, strength, inferenceTime, zeroTargetLLSum, doLocalErrorTempering)
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
			var zeroWeight = [double](inferenceTime)
			var l : real
			[doLocalErrorTempering and
				quote
					var zeroErr, nonZeroErr = mseComps(&samples, &target)
					var zeroLL = -strength*zeroErr
					var nonZeroLL = -strength*nonZeroErr
					zeroTargetLLSum = ad.val(zeroLL)
					l = nonZeroLL + inferenceTime*zeroLL
				end
			or
				quote
					l = -strength * mse(&samples, &target)
				end
			]
			return l
		end

		return 
		{
			likelihood = likelihood,
			targetData = targetData
		}
	end
end



return
{
	loadTargetImage = loadTargetImage,
	mseLikelihoodModule = mseLikelihoodModule
}






