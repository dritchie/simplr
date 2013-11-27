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


-- Probabilistic code for multiply-recursive structures.

local lerp = macro(function(lo, hi, t)
	return `(1.0-t)*lo + t*hi
end)


local VinesRetType = templatize(function(real)
	local Vec2 = Vec(real, 2)
	local struct LineSeg { start: Vec2, stop: Vec2, width: double }
	local struct VinesRetTypeT { segs: Vector(LineSeg), smoothParam: double }
	VinesRetTypeT.LineSeg = LineSeg
	terra VinesRetTypeT:__construct() m.init(self.segs) end
	terra VinesRetTypeT:__construct(segs: Vector(LineSeg), s: double)
		self.segs = segs; self.smoothParam = s
	end
	terra VinesRetTypeT:__copy(other: &VinesRetTypeT)
		self.segs = m.copy(other.segs)
		self.smoothParam = other.smoothParam
	end
	terra VinesRetTypeT:__destruct()
		m.destruct(self.segs)
	end
	m.addConstructors(VinesRetTypeT)
	return VinesRetTypeT
end)

local function vinesModule(inferenceTime, doSmoothing)
	return function()
		if doSmoothing == nil then doSmoothing = (real == ad.num) end
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

		local RetType = VinesRetType(real)
		local LineSeg = RetType.LineSeg

		-- Shorthand for common non-structural ERPs
		local ngaussian = macro(function(mean, sd)
			return `gaussian([mean], [sd], {structural=false})
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

		-- Constants
		local maxBranches = 4
		local branchProb = 0.1
		local numStepsLambda = 6
		local lengthAlpha = `10.0
		local lengthBeta = 0.0025
		local angleMean = `0.0
		local angleSD = math.pi/6.0
		local widthAlpha = `20.0
		local widthBeta = 0.0003
		local depthWidthScale = `0.25
		local branchSpawnAlpha = `1.0
		local branchSpawnBeta = 0.1

		-- The 'prior' part of the program which recursively generates a bunch of line
		--    segments to be rendered.
		local vinesRec = pfn()
		local function genBranches(depth, lengths, dirs, allSegs)
			local branches = {}
			for i=1,maxBranches do
				table.insert(branches, quote
					var numSegs = lengths.size
					var segStartIndex = allSegs.size - numSegs
					var totalLength = lengths(0)
					for i=1,numSegs do totalLength = totalLength + lengths(i) end
					if flip(branchProb) then
						-- Decide at which point along the parent vine this child
						--    should spawn
						var startT = 1.0 - ngamma(branchSpawnAlpha, branchSpawnBeta)
						startT = ad.math.fmax(startT, 0.0)  -- Extremely unlikely, but best to be safe
						var lengthAccum = lengths(0)
						var whichSeg = 0U
						while lengthAccum/totalLength <= startT do
							whichSeg = whichSeg + 1
							lengthAccum = lengthAccum + lengths(whichSeg)
						end
						var l = lengths(whichSeg)
						var t = (totalLength*startT - (lengthAccum - l))/l
						var seg = allSegs(segStartIndex+whichSeg)
						var startPoint = lerp(seg.start, seg.stop, t)
						var startDir = dirs(whichSeg)
						vinesRec(depth+1, startPoint, startDir, allSegs)
					end
				end)
			end
			return branches
		end
		vinesRec:define(terra(depth: uint, currPoint: Vec2, currDir: Vec2, segs: &Vector(LineSeg)) : {}
			-- First, generate the vine itself
			var lineWidth = ngamma(widthAlpha, widthBeta) / (depthWidthScale*depth)
			var numSteps = poisson(numStepsLambda) + 1 -- so we never get 0
			var lengths = [Vector(double)].stackAlloc(numSteps, 0.0)
			var dirs = [Vector(Vec2)].stackAlloc(numSteps, Vec2.stackAlloc())
			for i=0,numSteps do
				var len = ngamma(lengthAlpha, lengthBeta)
				var dir = rotate(currDir, ngaussian(angleMean, angleSD))
				var newPoint = currPoint + len*dir
				segs:push(LineSeg{currPoint, newPoint, lineWidth})
				currPoint = newPoint
				lengths(i) = len
				dirs(i) = dir
			end
			-- Then, (potentially) generate recursive branches
			[genBranches(depth, lengths, dirs, segs)]
			-- Clean up
			m.destruct(lengths)
			m.destruct(dirs)
		end)
		local vines = pfn(terra()
			var segs = [Vector(LineSeg)].stackAlloc()
			var rootPoint = Vec2.stackAlloc(0.5, 0.18)
			var rootDir = Vec2.stackAlloc(0.0, 1.0)
			-- Just so we're guaranteed to have at least one continuous nonstructural
			var ang = ngaussian(angleMean, angleSD)
			rootDir = rotate(rootDir, ang)

			vinesRec(1, rootPoint, rootDir, &segs)

			var smoothingAmount : double
			[(not doSmoothing) and quote end or
			quote
				-- smoothingAmount = 0.0005
				smoothingAmount = lerp(0.01, 0.0005, inferenceTime)
			end]
			return RetType.stackAlloc(segs, smoothingAmount)
		end)

		-- Rendering
		local terra renderSegments(retval: &RetType, sampler: &Sampler, pattern: &Vector(Vec2d))
			sampler:clear()
			for i=0,retval.segs.size do
				var seg = retval.segs:getPointer(i)
				var capsule = Capsule.heapAlloc(seg.start, seg.stop, seg.width)
				var coloredCapsule = ColoredShape.heapAlloc(capsule, Color1.stackAlloc(1.0))
				sampler:addShape(coloredCapsule)
			end
			[(not doSmoothing) and (`sampler:sampleSharp(pattern)) or (`sampler:sampleSmooth(pattern, retval.smoothParam))]
		end

		-- Module exports
		return
		{
			prior = vines,
			doDepthBiasedSelection = true,
			sample = renderSegments,
			SampledFunctionType = SampledFunctionType,
			SamplerType = Sampler
		}
	end
end


return vinesModule



