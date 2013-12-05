-- Include Quicksand
terralib.require("prob")

local m = terralib.require("mem")
local templatize = terralib.require("templatize")
local ad = terralib.require("ad")

local Vector = terralib.require("vector")

local Vec = terralib.require("linalg").Vec
local Vec2d = Vec(double, 2)
local Color = terralib.require("color")

local SfnOpts = terralib.require("sampledFnOptions")
local SampledFunction = terralib.require("sampledFunction")

local shapes = terralib.require("shapes")

local ImplicitSampler = terralib.require("samplers").ImplicitSampler

-------------------------------------------

local function colorDotModule(inferenceTime, doSmoothing)
	return function()
		local doSmooth = doSmoothing
		if doSmooth == nil then doSmooth = (real == ad.num) end
		local Vec2 = Vec(real, 2)
		local Color3 = Color(real, 3)
		local SampledFunctionType = SampledFunction(Vec2d, Color3, SfnOpts.ClampFns.Min(1.0), SfnOpts.AccumFns.Over())
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


return colorDotModule

