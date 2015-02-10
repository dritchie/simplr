-- Include Quicksand
require("prob")

local m = require("mem")
local templatize = require("templatize")
local ad = require("ad")

local Vector = require("vector")

local Vec = require("linalg").Vec
local Vec2d = Vec(double, 2)
local Color = require("color")

local SfnOpts = require("sampledFnOptions")
local SampledFunction = require("sampledFunction")

local shapes = require("shapes")

local ImplicitSampler = require("samplers").ImplicitSampler

-------------------------------------------

local function colorDotModule(inferenceTime, doSmoothing)
	return function()
		local doSmooth = doSmoothing
		if doSmooth == nil then doSmooth = (real == ad.num) end
		local Vec2 = Vec(real, 2)
		local Color3 = Color(real, 3)
		local SampledFunctionType = SampledFunction(Vec2d, Color3, SfnOpts.ClampFns.None(), SfnOpts.AccumFns.Over())
		local ShapeType = shapes.ImplicitShape(Vec2, Color3)
		local CircleShape = shapes.SphereImplicitShape(Vec2, Color3)
		local ColoredShape = shapes.ConstantColorImplicitShape(Vec2, Color3)
		local Sampler = ImplicitSampler(SampledFunctionType, ShapeType)

		-- Shorthand for common non-structural ERPs
		local nuniformClamped = macro(function(lo, hi)
			return quote
				var x = uniform(lo, hi, {structural=false})
				-- Have to clamp, because HMC may take us out of the support range.
				x = ad.math.fmax(ad.math.fmin(x, hi), lo)
			in
				x
			end
		end)

		-- Constants
		local center = 0.5
		local radius = 0.2

		local colorDot = pfn(terra()
			return Color3.stackAlloc(nuniformClamped(0.0, 1.0), nuniformClamped(0.0, 1.0), nuniformClamped(0.0, 1.0))
		end)

		local terra render(retval: &Color3, sampler: &Sampler, pattern: &Vector(Vec2d))
			sampler:clear()
			var cShape = CircleShape.heapAlloc(Vec2.stackAlloc(center), radius)
			var coloredShape = ColoredShape.heapAlloc(cShape, @retval)
			sampler:addShape(coloredShape)
			sampler:sampleSharp(pattern)
		end

		return
		{
			prior = colorDot, 
			sampleSmooth = render,
			sampleSharp = render,
			sample = render,
			SampledFunctionType = SampledFunctionType,
			SamplerType = Sampler
		}
	end
end


return
{
	codeModule = colorDotModule
}


