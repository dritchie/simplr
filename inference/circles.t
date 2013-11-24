-- Include Quicksand
terralib.require("prob")

local m = terralib.require("mem")
local templatize = terralib.require("templatize")

local Vector = terralib.require("vector")

local Vec = terralib.require("linalg").Vec
local Vec2d = Vec(double, 2)
local Color = terralib.require("color")

local SfnOpts = terralib.require("sampledFnOptions")
local SampledFunction = terralib.require("sampledFunction")

local shapes = terralib.require("shapes")

local ImplicitSampler = terralib.require("samplers").ImplicitSampler

-------------------------------------------


-- Probabilistic code for rendering with random circles

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
		if doSmoothing == nil then doSmoothing = (real == ad.num) end
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

		local circles = pfn(terra()
			var circs = [Vector(CircleT)].stackAlloc(numCircles, CircleT { Vec2.stackAlloc(0.0), 1.0 } )
			for i=0,numCircles do
				circs:getPointer(i).center(0) = nuniformWithFalloff(posMin, posMax)
				circs:getPointer(i).center(1) = nuniformWithFalloff(posMin, posMax)
				circs:getPointer(i).radius = nuniformWithFalloff(radMin, radMax)
			end
			var smoothingAmount = 0.0
			[(not doSmoothing) and quote end or
			quote
				-- smoothingAmount = 0.005
				smoothingAmount = lerp(0.01, 0.001, inferenceTime)
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


return circlesModule


