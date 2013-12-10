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


local VinesRetType = templatize(function(real)
	local Vec2 = Vec(real, 2)
	local struct LineSeg { start: Vec2, stop: Vec2, width: real }
	local struct VinesRetTypeT { segs: Vector(LineSeg), smoothParam: real }
	VinesRetTypeT.LineSeg = LineSeg
	terra VinesRetTypeT:__construct() m.init(self.segs) end
	terra VinesRetTypeT:__construct(segs: Vector(LineSeg), s: real)
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
		local doSmooth = doSmoothing
		if doSmooth == nil then doSmooth = (real == ad.num) end
		local Vec2 = Vec(real, 2)
		local Color1 = Color(real, 1)
		local SampledFunctionType = SampledFunction(Vec2d, Color1, SfnOpts.ClampFns.None(), SfnOpts.AccumFns.Over())
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
		local ngammaMS = macro(function(m, s)
			return `gammaMeanShape([m], [s], {structural=false})
		end)

		local terra rotate(dir: Vec2, angle: real)
			var x = dir(0)
			var y = dir(1)
			var cosang = ad.math.cos(angle)
			var sinang = ad.math.sin(angle)
			return Vec2.stackAlloc(x*cosang - y*sinang, y*cosang + x*sinang)
		end

		-- Constants
		local maxBranches = 2
		-- local initialBranchProb = 0.45
		-- local finalBranchProb = 0.45
		local initialBranchProb = 0.25
		local finalBranchProb = 0.25
		local branchProbMult = 1.0
		-- local maxBranches = 4
		-- local initialBranchProb = 0.75
		-- local finalBranchProb = 0.0
		-- local branchProbMult = 0.7
		local numStepsLambda = 6
		local lengthShape = `10.0
		local lengthMean = 0.025
		local angleMean = `0.0
		local angleSD = math.pi/6.0
		local initialWidthShape = `100.0
		local initialWidthMean = 0.01
		local widthMultShape = `100.0
		local widthMultMean = 0.1
		local branchSpawnShape = `1.0
		local branchSpawnMean = 0.1

		-- The 'prior' part of the program which recursively generates a bunch of line
		--    segments to be rendered.
		local vinesRec = pfn()
		local function genBranches(depth, currWidth, branchProb, currPoint, currDir, allSegs)
			local stmts = {}
			for i=1,maxBranches do
				table.insert(stmts, quote
					if flip(branchProb) then
						-- First, generate the vine itself
						var lineWidth = currWidth * (1.0 - ad.math.fmin(ngammaMS(widthMultMean, widthMultShape), 1.0))
						var numSteps = poisson(numStepsLambda) + 1 -- so we never get 0
						-- var len = ngammaMS(lengthMean, lengthShape)
						for i=0,numSteps do
							var len = ngammaMS(lengthMean, lengthShape)
							currDir = rotate(currDir, ngaussian(angleMean, angleSD))
							var newPoint = currPoint + len*currDir
							allSegs:push(LineSeg{currPoint, newPoint, lineWidth})
							currPoint = newPoint
						end
						vinesRec(depth+1, lineWidth, currPoint, currDir, allSegs)
					end
				end)
			end
			return stmts
		end
		vinesRec:define(terra(depth: uint, currWidth: real, currPoint: Vec2, currDir: Vec2, segs: &Vector(LineSeg)) : {}
			var branchProb = lerp(initialBranchProb, finalBranchProb, 1.0 - ad.math.pow(branchProbMult, depth))
			[genBranches(depth, currWidth, branchProb, currPoint, currDir, segs)]
		end)
		local vines = pfn(terra()
			var segs = [Vector(LineSeg)].stackAlloc()
			var rootPoint = Vec2.stackAlloc(0.5, 0.18)
			var rootDir = Vec2.stackAlloc(0.0, 1.0)
			-- Just so we're guaranteed to have at least one continuous nonstructural
			var ang = ngaussian(angleMean, angleSD)
			rootDir = rotate(rootDir, ang)
			var initialWidth = ngammaMS(initialWidthMean, initialWidthShape)

			vinesRec(1, initialWidth, rootPoint, rootDir, &segs)

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
			prior = vines,
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
	codeModule = vinesModule,
	doDepthBiasedSelection = true
}



