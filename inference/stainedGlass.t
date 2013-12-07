-- Include Quicksand
terralib.require("prob")

local m = terralib.require("mem")
local templatize = terralib.require("templatize")
local ad = terralib.require("ad")
local util = terralib.require("util")

local Vector = terralib.require("vector")

local Vec = terralib.require("linalg").Vec
local Vec2d = Vec(double, 2)
local Color = terralib.require("color")

local SfnOpts = terralib.require("sampledFnOptions")
local SampledFunction = terralib.require("sampledFunction")

local shapes = terralib.require("shapes")

local ImplicitSampler = terralib.require("samplers").ImplicitSampler

--------------------------------

local lerp = macro(function(lo, hi, t)
	return `(1.0-t)*lo + t*hi
end)


local StainedGlassRetType = templatize(function(real)
	local Vec2 = Vec(real, 2)
	local Color3 = Color(real, 3)
	local struct Point { loc: Vec2, color: Color3 }
	local struct StainedGlassRetTypeT { points: Vector(Point), smoothParam: real }
	StainedGlassRetTypeT.Point = Point
	terra StainedGlassRetTypeT:__construct() m.init(self.points) end
	terra StainedGlassRetTypeT:__construct(points: Vector(Point), s: real)
		self.points = points; self.smoothParam = s
	end
	terra StainedGlassRetTypeT:__copy(other: &StainedGlassRetTypeT)
		self.points = m.copy(other.points)
		self.smoothParam = other.smoothParam
	end
	terra StainedGlassRetTypeT:__destruct()
		m.destruct(self.points)
	end
	m.addConstructors(StainedGlassRetTypeT)
	return StainedGlassRetTypeT
end)

local function stainedGlassModule(inferenceTime, doSmoothing)
	return function()
		local doSmooth = doSmoothing
		if doSmooth == nil then doSmooth = (real == ad.num) end
		local Vec2 = Vec(real, 2)
		local Color3 = Color(real, 3)
		local SampledFunctionType = SampledFunction(Vec2d, Color3, SfnOpts.ClampFns.None(), SfnOpts.AccumFns.Over())
		local ShapeType = shapes.ImplicitShape(Vec2, Color3)
		local Sampler = ImplicitSampler(SampledFunctionType, ShapeType)

		local RetType = StainedGlassRetType(real)
		local Point = RetType.Point

		-- Shorthand for common non-structural ERPs
		local ngaussian = macro(function(mean, sd)
			return `gaussian([mean], [sd], {structural=false})
		end)
		local nuniformClamped = macro(function(lo, hi)
			return quote
				var x = uniform(lo, hi, {structural=false})
				-- Have to clamp, because HMC may take us out of the support range.
				x = ad.math.fmax(ad.math.fmin(x, hi), lo)
			in
				x
			end
		end)

		-- Priors
		local numPointsConcentration = 20
		local pointPosMean = 0.5
		local pointPosSD = 0.25

		-- The 'prior' part of the program which recursively generates a bunch of line
		--    segments to be rendered.
		local stainedGlass = pfn(terra()
			var numPoints = poisson(numPointsConcentration)
			var points = [Vector(Point)].stackAlloc(numPoints, Point{})
			for i=0,numPoints do
				points(i).loc(0) = ngaussian(pointPosMean, pointPosSD)
				points(i).loc(1) = ngaussian(pointPosMean, pointPosSD)
				points(i).color(0) = nuniformClamped(0.0, 1.0)
				points(i).color(1) = nuniformClamped(0.0, 1.0)
				points(i).color(2) = nuniformClamped(0.0, 1.0)
			end

			var smoothingAmount = lerp(1.0, 0.0, inferenceTime)
			return RetType.stackAlloc(points, smoothingAmount)
		end)

		-- Rendering
		local function genRenderFn(smooth)
			return terra(retval: &RetType, sampler: &Sampler, pattern: &Vector(Vec2d))
				sampler:clear()
				-- Compute unnormalized weights via inverse distance
				-- Interpolate toward zero for all weights other than the largest (smoothing param)
				-- Normalize, do linear comb of colors
			end
		end
		local renderSmooth = genRenderFn(true)
		local renderSharp = genRenderFn(false)

		-- Module exports
		return
		{
			prior = stainedGlass,
			doDepthBiasedSelection = false,
			sampleSmooth = renderSmooth,
			sampleSharp = renderSharp,
			sample = (doSmooth and renderSmooth or renderSharp),
			SampledFunctionType = SampledFunctionType,
			SamplerType = Sampler
		}
	end
end


return stainedGlassModule



