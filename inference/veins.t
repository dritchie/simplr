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

local C = terralib.includec("stdio.h")

--------------------------------


-- Probabilistic code for multiply-recursive structures.

local lerp = macro(function(lo, hi, t)
	return `(1.0-t)*lo + t*hi
end)


local VeinsRetType = templatize(function(real)
	local Vec2 = Vec(real, 2)
	local struct LineSeg { start: Vec2, stop: Vec2, width: real }
	local struct VeinsRetTypeT { segs: Vector(LineSeg), smoothParam: real }
	VeinsRetTypeT.LineSeg = LineSeg
	terra VeinsRetTypeT:__construct() m.init(self.segs) end
	terra VeinsRetTypeT:__construct(segs: Vector(LineSeg), s: real)
		self.segs = segs; self.smoothParam = s
	end
	terra VeinsRetTypeT:__copy(other: &VeinsRetTypeT)
		self.segs = m.copy(other.segs)
		self.smoothParam = other.smoothParam
	end
	terra VeinsRetTypeT:__destruct()
		m.destruct(self.segs)
	end
	m.addConstructors(VeinsRetTypeT)
	return VeinsRetTypeT
end)

local function veinsModule(inferenceTime, doSmoothing)
	return function()
		if doSmoothing == nil then doSmoothing = (real == ad.num) end
		local Vec2 = Vec(real, 2)
		local Color1 = Color(real, 1)
		-- local SampledFunctionType = SampledFunction(Vec2d, Color1, SfnOpts.ClampFns.Min(1.0), SfnOpts.AccumFns.Over())
		local SampledFunctionType = SampledFunction(Vec2d, Color1, SfnOpts.ClampFns.None(), SfnOpts.AccumFns.Over())
		local ShapeType = shapes.ImplicitShape(Vec2, Color1)
		local Capsule = shapes.CapsuleImplicitShape(Vec2, Color1)
		local ColoredShape = shapes.ConstantColorImplicitShape(Vec2, Color1)
		local Sampler = ImplicitSampler(SampledFunctionType, ShapeType)

		local RetType = VeinsRetType(real)
		local LineSeg = RetType.LineSeg

		-- Shorthand for common non-structural ERPs
		local ngaussian = macro(function(mean, sd)
			return `gaussian([mean], [sd], {structural=false})
		end)
		local ngammaMS = macro(function(m, s)
			return `gammaMeanShape([m], [s], {structural=false})
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
		local nbeta = macro(function(a, b)
			return `beta(a, b, {structural=false})
		end)

		local terra rotate(dir: Vec2, angle: real)
			var x = dir(0)
			var y = dir(1)
			var cosang = ad.math.cos(angle)
			var sinang = ad.math.sin(angle)
			return Vec2.stackAlloc(x*cosang - y*sinang, y*cosang + x*sinang)
		end

		-- Constants
		local widthMult = 0.01
		local widthPower = 0.75
		local length = 0.05
		local numSegsMean = `40.0
		local numChildrenMeanMult = `0.2
		local segAngleMean = `0.0
		local segAngleSD = `[math.pi]/8
		local spawnAngleAlpha = 0.5	-- Arcsin distribution
		local spawnAngleBeta = 0.5	-- Arcsin distribution

		-- The 'prior' part of the program which recursively generates a bunch of line
		--    segments to be rendered.
		local veinsRec = pfn()
		veinsRec:define(terra(depth: uint, currPoint: Vec2, currDir: Vec2, segs: &Vector(LineSeg)) : {}
			-- Generate a polyline
			var lineWidth = widthMult/ad.math.pow(depth, widthPower)
			var numSegs	 = poisson(numSegsMean/depth)
			var dirs = [Vector(Vec2)].stackAlloc(numSegs, Vec2.stackAlloc())
			for i=0,numSegs do
				currDir = rotate(currDir, ngaussian(segAngleMean, segAngleSD))
				var newPoint = currPoint + length*currDir
				dirs(i) = currDir
				segs:push(LineSeg{currPoint, newPoint, lineWidth})
				currPoint = newPoint
			end
			-- Spawn some number of child polylines
			var numChildren = poisson(numChildrenMeanMult*numSegs/depth)
			var segStartIndex = segs.size - numSegs
			var L = numSegs*length
			for i=0,numChildren do
				var t = nuniformClamped(0.05, 0.95)*L
				var whichSeg = [uint](ad.val(t/length))
				var segT = t - whichSeg*length
				var lineSeg = segs:getPointer(segStartIndex + whichSeg)
				var startPoint = lerp(lineSeg.start, lineSeg.stop, segT)
				var dir = dirs(whichSeg)
				var ang = lerp([-math.pi/4], [math.pi/4], nbeta(spawnAngleAlpha, spawnAngleBeta))
				var startDir = rotate(dir, ang)
				veinsRec(depth+1, startPoint, startDir, segs)
			end
			-- Clean up
			m.destruct(dirs)
		end)
		local veins = pfn(terra()
			var segs = [Vector(LineSeg)].stackAlloc()
			var rootPoint = Vec2.stackAlloc(0.52, 0.2)
			var rootDir = Vec2.stackAlloc(0.0, 1.0)

			veinsRec(1, rootPoint, rootDir, &segs)

			var smoothingAmount = 0.0005
			-- var smoothingAmount = lerp(0.01, 0.0005, inferenceTime)
			-- var smoothingAmount = ngammaMS(0.002, 2)
			return RetType.stackAlloc(segs, smoothingAmount)
		end)

		-- Rendering
		local function genRenderFn(smooth)
			return terra(retval: &RetType, sampler: &Sampler, pattern: &Vector(Vec2d))
				sampler:clear()
				for i=0,retval.segs.size do
					var seg = retval.segs:getPointer(i)
					var capsule = Capsule.heapAlloc(seg.start, seg.stop, seg.width)
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
			prior = veins,
			doDepthBiasedSelection = true,
			sampleSmooth = renderSmooth,
			sampleSharp = renderSharp,
			sample = (doSmoothing and renderSmooth or renderSharp),
			SampledFunctionType = SampledFunctionType,
			SamplerType = Sampler
		}
	end
end


return veinsModule



