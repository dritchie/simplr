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

--------------------------------

local lerp = macro(function(lo, hi, t)
	return `(1.0-t)*lo + t*hi
end)


local GrammarRetType = templatize(function(real)
	local Vec2 = Vec(real, 2)
	local struct LineSeg { start: Vec2, stop: Vec2 }
	local struct GrammarRetTypeT { segs: Vector(LineSeg), smoothParam: double }
	GrammarRetTypeT.LineSeg = LineSeg
	terra GrammarRetTypeT:__construct() m.init(self.segs) end
	terra GrammarRetTypeT:__construct(segs: Vector(LineSeg), s: double)
		self.segs = segs; self.smoothParam = s
	end
	terra GrammarRetTypeT:__copy(other: &GrammarRetTypeT)
		self.segs = m.copy(other.segs)
		self.smoothParam = other.smoothParam
	end
	terra GrammarRetTypeT:__destruct()
		m.destruct(self.segs)
	end
	m.addConstructors(GrammarRetTypeT)
	return GrammarRetTypeT
end)

local function grammarModule(inferenceTime, doSmoothing)
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

		local RetType = GrammarRetType(real)
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

		-- A bunch of constants. Perhaps factor these out?
		local lengthAlpha = `10.0
		local lengthBeta = `0.01
		local anglePriorMean = `0.0
		local anglePriorSD = math.pi/6.0
		local lineThickness = 0.007
		local maxBranches = 2
		local branchProb = 0.35

		-- The 'prior' part of the program which recursively generates a bunch of line
		--    segments to be rendered.
		local grammarRec = pfn()
		local function genBranches(currPoint, currDir, segs)
			local branches = {}
			for i=1,maxBranches do
				table.insert(branches, quote
					if flip(branchProb) then
						var len = ngamma(lengthAlpha, lengthBeta)
						var dir = rotate([currDir], ngaussian(anglePriorMean, anglePriorSD))
						var newPoint = [currPoint] + len*dir
						segs:push(LineSeg{[currPoint], newPoint})
						grammarRec(newPoint, dir, segs)
					end
				end)
			end
			return branches
		end
		grammarRec:define(terra(currPoint: Vec2, currDir: Vec2, segs: &Vector(LineSeg)) : {}
			[genBranches(currPoint, currDir, segs)]
		end)
		local grammar = pfn(terra()
			var segs = [Vector(LineSeg)].stackAlloc()
			var rootPoint = Vec2.stackAlloc(0.458, 0.068)
			var rootDir = Vec2.stackAlloc(0.0, 1.0)
			-- Just so we're guaranteed to have at least one continuous nonstructural
			var ang = ngaussian(anglePriorMean, anglePriorSD)
			rootDir = rotate(rootDir, ang)

			grammarRec(rootPoint, rootDir, &segs)

			-- var smoothingAmount = lerp(0.01, 0.0005, inferenceTime)
			var smoothingAmount = 0.0005 
			return RetType.stackAlloc(segs, smoothingAmount)
		end)

		-- Rendering
		local function genRenderFn(smooth)
			return terra(retval: &RetType, sampler: &Sampler, pattern: &Vector(Vec2d))
				sampler:clear()
				for i=0,retval.segs.size do
					var seg = retval.segs:getPointer(i)
					var capsule = Capsule.heapAlloc(seg.start, seg.stop, lineThickness)
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
			prior = grammar,
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
	codeModule = grammarModule,
	doDepthBiasedSelection = true
}



