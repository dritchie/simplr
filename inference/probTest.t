-- Include Quicksand
terralib.require("prob")

local m = terralib.require("mem")
local util = terralib.require("util")

local Vec = terralib.require("linalg").Vec
local Vec2d = Vec(double, 2)
local Vec2u = Vec(uint, 2)

local Color = terralib.require("color")
local Color1d = Color(double, 1)

local im = terralib.require("image")
local RGBImage = im.Image(uint8, 3)

local patterns = terralib.require("samplePatterns")
local ImgGridPattern = patterns.RegularGridSamplingPattern(Vec2d)

local SampledFunction = terralib.require("sampledFunction")
local SampledFunction2d1d = SampledFunction(Vec2d, Color1d)

local circlesModule = terralib.require("circles")
local polylineModule = terralib.require("polyline")
local grammarModule = terralib.require("grammar")
local vinesModule = terralib.require("vines")
local veinsModule = terralib.require("veins")
local particlesModule = terralib.require("particles")
local colorDotModule = terralib.require("colorDot")
local stainedGlassModule = terralib.require("stainedGlass")

local loadTargetImage = terralib.require("targetImageLikelihood").loadTargetImage
local mseLikelihoodModule = terralib.require("targetImageLikelihood").mseLikelihoodModule

local C = terralib.includecstring [[
#include <stdio.h>
#include <string.h>
]]

--------------


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

local function doForwardSample(program, numsamps)
	local terra fn()
		return [forwardSample(program, numsamps)]
	end
	return m.gc(fn())
end


-- Render a video of the sequence of accepted states
local function renderVideo(pmodule, targetData, valueSeq, directory, name, doSmooth)
	io.write("Rendering video...")
	io.flush()
	local moviefilename = string.format("%s/%s.mp4", directory, name)
	local framebasename = string.format("%s/%s", directory, name) .. "_%06d.png"
	local framewildcard = string.format("%s/%s", directory, name) .. "_*.png"
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
				[doSmooth and 
					(`M.sampleSmooth(&val.value, &sampler, grid:getSamplePattern()))
				or
					(`M.sampleSharp(&val.value, &sampler, grid:getSamplePattern()))
				]
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
	util.wait(string.format("ffmpeg -threads 0 -y -r 30 -i %s -c:v libx264 -r 30 -pix_fmt yuv420p %s 2>&1",
		framebasename, moviefilename))
	util.wait(string.format("rm -f %s", framewildcard))
	print("done.")
end


------------------

local numsamps = 2000
local doGlobalAnnealing = false
local initialGlobalTemp = 10
local doLocalErrorTempering = false
local hmcUsePrimalLP = true
local alwaysDoSmoothing = false
local outputSmoothRender = false
local constraintStrength = 2000
local expandFactor = 1

local doHMC = true

-- local priorModule = stainedGlassModule
-- local targetImgName = "targets/tiger_250.png"
-- local priorModule = colorDotModule
-- local targetImgName = "targets/red_250.png"
-- local priorModule = particlesModule
-- local targetImgName = "targets/red_250.png"
-- local priorModule = veinsModule
-- local targetImgName = "targets/bird_250.png"
-- local priorModule = vinesModule
-- local targetImgName = "targets/knot_250.png"
local priorModule = grammarModule
local targetImgName = "targets/helix_250.png"
-- local priorModule = polylineModule
-- local targetImgName = "targets/squiggle_200.png"
-- local priorModule = circlesModule
-- local targetImgName = "targets/symbol_200.png"

local HMCParams = {usePrimalLP=hmcUsePrimalLP, pmrAlpha=0.0}
local LARJParams = {intervals=0}
LARJParams.doDepthBiasedSelection = priorModule.doDepthBiasedSelection
LARJParams.jumpFreq = priorModule.jumpFreq or 0.0

local kernel = nil
if doHMC then
	kernel = LARJ(HMC(HMCParams))(LARJParams)
else
	kernel = LARJ(RandomWalk({structs=false}))(LARJParams)
end

-------------------

local inferenceTime = global(double)
local zeroTargetLLSum = global(double)

local function genAnnealingCode(trace, infTime)
	local init = 1.0 / initialGlobalTemp
	return quote [trace].temperature = 1.0/(init + inferenceTime) end
end
local function genLocalErrorTemperingCode(trace, prevInfTime, currInfTime)
	return quote
		var oldLLPart = [prevInfTime]*zeroTargetLLSum
		var newLLPart = [currInfTime]*zeroTargetLLSum
		[trace].logprob = [trace].logprob - oldLLPart + newLLPart
	end
end
local scheduleFunction = macro(function(iter, currTrace)
	return quote
		var oldInfTime = inferenceTime
		inferenceTime = [double](iter) / numsamps
		[util.optionally(doGlobalAnnealing, genAnnealingCode, currTrace, inferenceTime)]
		[util.optionally(doLocalErrorTempering, genLocalErrorTemperingCode, currTrace, oldInfTime, inferenceTime)]
	end
end)

-- We should always use the smooth renderer if requested, or if we're doing HMC
--   where logprobs come from the AD trace (if we don't do this, then jumps will not work well)
local alwaysSmooth = nil
alwaysSmooth = alwaysDoSmoothing or (doHMC and not hmcUsePrimalLP)
local pmodule = priorModule.codeModule(inferenceTime, alwaysSmooth)

constraintStrength = expandFactor*expandFactor*constraintStrength
local targetData = loadTargetImage(pmodule().SampledFunctionType, targetImgName, expandFactor)
local lmodule = mseLikelihoodModule(pmodule, targetData, constraintStrength,
	inferenceTime, zeroTargetLLSum, doLocalErrorTempering)
local program = bayesProgram(pmodule, lmodule)

local kernel = Schedule(kernel, scheduleFunction)

local values = doMCMC(program, kernel, numsamps)
-- local values = doForwardSample(program, numsamps)

local basename = arg[1] or "movie"
renderVideo(pmodule, targetData, values, "renders", basename, outputSmoothRender)

