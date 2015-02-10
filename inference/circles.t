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

local lerp = macro(function(lo, hi, t)
	return `(1.0-t)*lo + t*hi
end)


local Circle = templatize(function(real)
	local Vec2 = Vec(real, 2)
	local struct CircleT { center: Vec2, radius: real }
	return CircleT
end)

-- Super annoying, but if I want to be able to render things exactly as they looked during inference,
--    I need to package up the smoothing param in the return value of the computation.
local CirclesRetType = templatize(function(real)
	local struct CircleRetTypeT { circles: Vector(Circle(real)), smoothParam: double }
	terra CircleRetTypeT:__construct() m.init(self.circles) end
	terra CircleRetTypeT:__construct(c: Vector(Circle(real)), s: double)
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

local function circlesModule(inferenceTime, doSmoothing)
	return function()
		local doSmooth = doSmoothing
		if doSmooth == nil then doSmooth = (real == ad.num) end
		local Vec2 = Vec(real, 2)
		local Color1 = Color(real, 1)
		local CircleT = Circle(real)
		local SampledFunctionType = SampledFunction(Vec2d, Color1, SfnOpts.ClampFns.None(), SfnOpts.AccumFns.Over())
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
		local numCircles = `40
		local posMin = `0.0
		local posMax = `1.0
		local radMin = `0.025
		local radMax = `0.1

		local circles = pfn(terra()
			var circs = [Vector(CircleT)].stackAlloc(numCircles, CircleT { Vec2.stackAlloc(0.0), 1.0 } )
			for i=0,numCircles do
				circs:getPointer(i).center(0) = nuniformWithFalloff(posMin, posMax)
				circs:getPointer(i).center(1) = nuniformWithFalloff(posMin, posMax)
				circs:getPointer(i).radius = nuniformWithFalloff(radMin, radMax)
			end
			var smoothingAmount = lerp(0.01, 0.001, inferenceTime)
			return RetType.stackAlloc(circs, smoothingAmount)
		end)

		local function genRenderFn(smooth)
			return terra(retval: &RetType, sampler: &Sampler, pattern: &Vector(Vec2d))
				sampler:clear()
				for i=0,retval.circles.size do
					var c = retval.circles:getPointer(i)
					var cShape = CircleShape.heapAlloc(c.center, c.radius)
					var coloredShape = ColoredShape.heapAlloc(cShape, Color1.stackAlloc(1.0))
					sampler:addShape(coloredShape)
				end
				[(not smooth) and (`sampler:sampleSharp(pattern)) or (`sampler:sampleSmooth(pattern, retval.smoothParam))]
			end
		end
		local renderSmooth = genRenderFn(true)
		local renderSharp = genRenderFn(false)

		return
		{
			prior = circles, 
			sampleSmooth = renderSmooth,
			sampleSharp = renderSharp,
			sample = (doSmooth and renderSmooth or renderSharp),
			SampledFunctionType = SampledFunctionType,
			SamplerType = Sampler
		}
	end
end


return
{
	codeModule = circlesModule
}


