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


--------------------------------

local lerp = macro(function(lo, hi, t)
	return `(1.0-t)*lo + t*hi
end)


local PolylinesRetType = templatize(function(real)
	local Vec2 = Vec(real, 2)
	local struct PolylinesRetTypeT { points: Vector(Vec2), smoothParam: double }
	terra PolylinesRetTypeT:__construct() m.init(self.points) end
	terra PolylinesRetTypeT:__construct(p: Vector(Vec2), s: double)
		self.points = p; self.smoothParam = s
	end
	terra PolylinesRetTypeT:__copy(other: &PolylinesRetTypeT)
		self.points = m.copy(other.points)
		self.smoothParam = other.smoothParam
	end
	terra PolylinesRetTypeT:__destruct()
		m.destruct(self.points)
	end
	m.addConstructors(PolylinesRetTypeT)
	return PolylinesRetTypeT
end)

local function polylineModule(inferenceTime, doSmoothing)
	return function()
		local doSmooth = doSmoothing
		if doSmooth == nil then doSmooth = (real == ad.num) end
		local Vec2 = Vec(real, 2)
		local Color1 = Color(real, 1)
		local SampledFunctionType = SampledFunction(Vec2d, Color1, SfnOpts.ClampFns.None(), SfnOpts.AccumFns.Over())
		local ShapeType = shapes.ImplicitShape(Vec2, Color1)
		local Capsule = shapes.CapsuleImplicitShape(Vec2, Color1)
		local ColoredShape = shapes.ConstantColorImplicitShape(Vec2, Color1)
		local Sampler = ImplicitSampler(SampledFunctionType, ShapeType)

		local RetType = PolylinesRetType(real)

		-- Shorthand for common non-structural ERPs
		local ngaussian = macro(function(mean, sd)
			return `gaussian([mean], [sd], {structural=false})
		end)
		local nuniformWithFalloff = macro(function(lo, hi)
			return `uniformWithFalloff([lo], [hi], {structural=false})
		end)
		local ngamma = macro(function(a, b)
			return `gamma([a], [b], {structural=false})
		end)

		local terra rotate(dir: Vec2, angle: real)
			var x = dir(0)
			var y = dir(1)
			var cosang = ad.math.cos(angle)
			var sinang = ad.math.sin(angle)
			return Vec2.stackAlloc(x*cosang - y*sinang, y*cosang + x*sinang)
		end

		-- A bunch of constants. Perhaps factor these out?
		-- local numSegs = `40
		local numSegs = `20
		local startPosMin = `0.0
		local startPosMax = `1.0
		local startDirMin = `0.0
		local startDirMax = `2.0*[math.pi]
		-- local lengthMin = `0.01
		-- local lengthMax = `0.1
		local lengthAlpha = `10.0
		local lengthBeta = `0.01
		local anglePriorMean = `0.0
		local anglePriorSD = `[math.pi]/6.0
		local lineThickness = `0.01

		-- The 'prior' part of the program which generates the polyine to be rendered.
		local polyline = pfn(terra()
			var points = [Vector(Vec2)].stackAlloc(numSegs, Vec2.stackAlloc(0.0))
			points:getPointer(0)(0) = nuniformWithFalloff(startPosMin, startPosMax)
			points:getPointer(0)(1) = nuniformWithFalloff(startPosMin, startPosMax)
			-- points:getPointer(0)(0) = 0.258
			-- points:getPointer(0)(1) = 0.219
			var dir = rotate(Vec2.stackAlloc(1.0, 0.0), nuniformWithFalloff(startDirMin, startDirMax))
			var len : real = 0.0
			for i=1,numSegs do
				-- len = nuniformWithFalloff(lengthMin, lengthMax)
				len = ngamma(lengthAlpha, lengthBeta)
				dir = rotate(dir, ngaussian(anglePriorMean, anglePriorSD))
				points:set(i, points:get(i-1) + (len*dir))
			end
			var smoothingAmount = lerp(0.01, 0.0005, inferenceTime)
			return RetType.stackAlloc(points, smoothingAmount)
		end)

		-- Rendering polyline (used by likelihood module)
		local function genRenderFn(smooth)
			return terra(retval: &RetType, sampler: &Sampler, pattern: &Vector(Vec2d))
				sampler:clear()
				for i=0,retval.points.size-1 do
					var capsule = Capsule.heapAlloc(retval.points:get(i), retval.points:get(i+1), lineThickness)
					var coloredCapsule = ColoredShape.heapAlloc(capsule, Color1.stackAlloc(1.0))
					sampler:addShape(coloredCapsule)
				end
				[(not smooth) and (`sampler:sampleSharp(pattern)) or (`sampler:sampleSmooth(pattern, retval.smoothParam))]
			end
		end
		local renderSmooth = genRenderFn(true)
		local renderSharp = genRenderFn(false)

		-- Module exports
		return
		{
			prior = polyline,
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
	codeModule = polylineModule
}



