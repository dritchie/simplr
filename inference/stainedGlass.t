-- Include Quicksand
terralib.require("prob")

local m = terralib.require("mem")
local templatize = terralib.require("templatize")
local ad = terralib.require("ad")
local util = terralib.require("util")
local inheritance = terralib.require("inheritance")

local Vector = terralib.require("vector")

local BBox = terralib.require("bbox")

local Vec = terralib.require("linalg").Vec
local Vec2d = Vec(double, 2)
local Color = terralib.require("color")

local SfnOpts = terralib.require("sampledFnOptions")
local SampledFunction = terralib.require("sampledFunction")

local shapes = terralib.require("shapes")

local ImplicitSampler = terralib.require("samplers").ImplicitSampler

local C = terralib.includec("stdio.h")

local CNearTree = terralib.require("CNearTree")


--------------------------------

local erph = terralib.require("prob.erph")
local random = terralib.require("prob.random")
newERP(
"uniformNoPrior",
random.uniform_sample,
erph.overloadOnParams(2, function(V, P1, P2)
	return terra(val: V, lo: P1, hi: P2)
		return V(0.0)
	end
end))


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

-- For testing with fixed point patterns
local pointLocs = global(Vector(Vec2d))
local rand = terralib.require("prob.random")
local terra initPointLocs()
	pointLocs:__construct(500, Vec2d.stackAlloc())
	for i=0,pointLocs.size do
		-- pointLocs(i)(0) = [rand.gaussian_sample(double)](0.5, 0.25)
		-- pointLocs(i)(1) = [rand.gaussian_sample(double)](0.5, 0.25)
		pointLocs(i)(0) = [rand.uniform_sample(double)](0.0, 1.0)
		pointLocs(i)(1) = [rand.uniform_sample(double)](0.0, 1.0)
	end
end
initPointLocs()

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

		local BBoxT = BBox(Vec2d)

		-- Shorthand for common non-structural ERPs
		local ngaussian = macro(function(mean, sd)
			return `gaussian([mean], [sd], {structural=false})
		end)
		local nuniformNoPrior = macro(function(lo, hi)
			return `uniformNoPrior(lo, hi, {structural=false})
		end)
		local nuniformNoPriorClamped = macro(function(lo, hi)
			return quote
				var x = nuniformNoPrior(lo, hi)
				-- Have to clamp, because HMC may take us out of the support range.
				x = ad.math.fmax(ad.math.fmin(x, hi), lo)
			in
				x
			end
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
		local numPointsConcentration = 500
		-- local numPointsConcentration = 50
		local pointPosMean = 0.5
		local pointPosSD = 0.25

		-- Constants
		local numNeighbors = 10
		-- local numNeighbors = numPointsConcentration-1

		-- The 'prior' part of the program which recursively generates a bunch of line
		--    segments to be rendered.
		local stainedGlass = pfn(terra()
			-- var numPoints = numNeighbors + poisson(numPointsConcentration)
			var numPoints = numPointsConcentration
			var points = [Vector(Point)].stackAlloc(numPoints, Point{})
			for i=0,numPoints do
				-- points(i).loc(0) = ngaussian(pointPosMean, pointPosSD)
				-- points(i).loc(1) = ngaussian(pointPosMean, pointPosSD)
				points(i).loc(0) = pointLocs(i)(0)
				points(i).loc(1) = pointLocs(i)(1)
				-- points(i).loc(0) = nuniformNoPrior(0.0, 1.0)
				-- points(i).loc(1) = nuniformNoPrior(0.0, 1.0)
				-- points(i).color(0) = nuniformClamped(0.0, 1.0)
				-- points(i).color(1) = nuniformClamped(0.0, 1.0)
				-- points(i).color(2) = nuniformClamped(0.0, 1.0)
				-- points(i).color(0) = nuniformNoPriorClamped(0.0, 1.0)
				-- points(i).color(1) = nuniformNoPriorClamped(0.0, 1.0)
				-- points(i).color(2) = nuniformNoPriorClamped(0.0, 1.0)
				points(i).color(0) = nuniformNoPrior(0.0, 1.0)
				points(i).color(1) = nuniformNoPrior(0.0, 1.0)
				points(i).color(2) = nuniformNoPrior(0.0, 1.0)
				-- points(i).color(0) = ngaussian(0.5, 0.5)
				-- points(i).color(1) = ngaussian(0.5, 0.5)
				-- points(i).color(2) = ngaussian(0.5, 0.5)

				-- C.printf("r: %.2f, g: %.2f, b: %.2f\n", ad.val(points(i).color(0)),
				-- 										ad.val(points(i).color(1)),
				-- 										ad.val(points(i).color(2)))
			end

			-- var smoothingAmount = 0.0
			-- if inferenceTime < 0.5 then
			-- 	smoothingAmount = lerp(1.0, 0.0, 2.0*inferenceTime)
			-- end
			var smoothingAmount = lerp(1.0, 0.0, inferenceTime)
			-- var smoothingAmount = lerp(1.0, 0.0, 0.99)
			-- var smoothingAmount = 0.25
			-- var smoothingAmount = 0.0
			return RetType.stackAlloc(points, smoothingAmount)
		end)

		-- Brute-force nearest-neighbor lookup
		local terra knnBruteForce(queryPoint: Vec2, points: &Vector(Point))
			if not (points.size >= numNeighbors) then
				util.fatalError("numNeighbors must be <= the number of points")
			end
			var ns = [Vector(&Point)].stackAlloc(numNeighbors, nil)
			var nds = [Vector(real)].stackAlloc(numNeighbors, [math.huge])
			for i=0,points.size do
				var p = points(i)
				var dist = queryPoint:distSq(p.loc)
				for j=0,numNeighbors do
					if ns(j) == nil then
						ns(j) = points:getPointer(i)
						nds(j) = dist
						break
					elseif nds(j) > dist then
						ns:insert(j, points:getPointer(i))
						nds:insert(j, dist)
						ns:resize(numNeighbors)
						nds:resize(numNeighbors)
						break
					end
				end
			end
			m.destruct(nds)
			return ns
		end

		-- Accelerated nearest-neighbor lookup
		-- TODO: Something funny is happening with this version. Fix it.
		local ffi = require("ffi")
		local nearTree = global(CNearTree.CNearTreeHandle)
		ffi.gc(nearTree:getpointer(), function(nt) CNearTree.CNearTreeFree(nt) end)
		local CNEARTREE_TYPE_DOUBLE = 16
		local terra initNearTree()
			CNearTree.CNearTreeCreate(&nearTree, 2, CNEARTREE_TYPE_DOUBLE)
		end
		initNearTree()
		local terra knnCNearTree(queryPoint: Vec2)
			var queryPointD  = ad.val(queryPoint)
			var queryPointRawData = [&double](queryPointD.entries)
			var radius = [math.huge] 	-- ???
			var outCoords : CNearTree.CVectorHandle
			var outPointers : CNearTree.CVectorHandle
			CNearTree.CVectorCreate(&outCoords, sizeof([&opaque]), 0)
			CNearTree.CVectorCreate(&outPointers, sizeof([&opaque]), 0)
			var retcode = CNearTree.CNearTreeFindKNearest(nearTree, numNeighbors, radius, outCoords, outPointers, queryPointRawData, 0)
			-- if retcode ~= 0 then
			-- 	util.fatalError("NearTree failed to find nearest neighbors\n")
			-- end
			-- CNearTree.CVectorFree(&outCoords)
			-- var outsize: uint64
			-- CNearTree.CVectorGetSize(outPointers, &outsize)
			-- if outsize ~= numNeighbors then
			-- 	util.fatalError("NearTree failed to find as many neighbors as requested\n")
			-- end

			var ns = [Vector(&Point)].stackAlloc(numNeighbors, nil)
			var minDist = [math.huge]
			var minIndex = -1
			for i=0,numNeighbors do
				var elem : &opaque
				CNearTree.CVectorGetElement(outPointers, &elem, i)
				var point = @[&&Point](elem)
				ns(i) = point
				var loc = ns(i).loc
				var dist = queryPoint:distSq(loc)
				if dist < minDist then
					minDist = ad.val(dist)
					minIndex = i
				end
			end
			CNearTree.CVectorFree(&outPointers)

			-- Ensure the closest one is first (other ordering doesn't really matter)
			-- TODO: Fully sort these.
			var tmp = ns(0)
			ns(0) = ns(minIndex)
			ns(minIndex) = tmp

			return ns
		end

		-- Stained glass rendering abstracted as an ImplicitShape
		local struct StainedGlassShape
		{
			points: Vector(Point),
			smoothing: real
		}
		inheritance.dynamicExtend(ShapeType, StainedGlassShape)

		terra StainedGlassShape:__construct(ps: &Vector(Point), smoothing: real)
			self.points = m.copy(@ps)
			self.smoothing = smoothing
		end


		terra StainedGlassShape:__destruct() : {}
			m.destruct(self.points)
		end
		inheritance.virtual(StainedGlassShape, "__destruct")

		terra StainedGlassShape:isovalue(point: Vec2) : real
			return 0.0
		end
		inheritance.virtual(StainedGlassShape, "isovalue")

		terra StainedGlassShape:isovalueAndColor(point: Vec2) : {real, Color3, real}

			var neighbors = knnBruteForce(point, &self.points)
			-- var neighbors = knnCNearTree(point)

			var dists = [Vector(real)].stackAlloc(neighbors.size, 0.0)
			for i=0,dists.size do
				dists(i) = point:dist(neighbors(i).loc)
			end

			-- -- Compute unnormalized weights via inverse distance
			-- var weights = [Vector(real)].stackAlloc(neighbors.size, 0.0)
			-- for i=0,weights.size do
			-- 	weights(i) = 1.0 / dists(i)
			-- end

			-- Compute unnormalized weights by lerped distance
			var weights = [Vector(real)].stackAlloc(neighbors.size, 0.0)
			var minDist = dists(0)
			var maxDist = dists(numNeighbors-1)
			for i=0,weights.size do
				weights(i) =  1.0 - ((dists(i) - minDist) / (maxDist - minDist))
			end

			var totalWeight = weights(0)
			-- Interpolate toward zero for all weights other than the largest (using smoothing param)
			for i=1,weights.size do
				weights(i) = lerp(0.0, weights(i), self.smoothing)
				totalWeight = totalWeight + weights(i)
			end
			-- Normalize, do linear comb of colors
			var color = Color3.stackAlloc(0.0, 0.0, 0.0)
			for i=0,weights.size do
				weights(i) = weights(i) / totalWeight
				color = color + (weights(i) * neighbors(i).color)
			end

			m.destruct(neighbors)
			m.destruct(dists)
			m.destruct(weights)

			return 0.0, color, 1.0
		end
		inheritance.virtual(StainedGlassShape, "isovalueAndColor")

		terra StainedGlassShape:bounds() : BBoxT
			return BBoxT.stackAlloc(Vec2d.stackAlloc(0.0), Vec2d.stackAlloc(1.0))
		end
		inheritance.virtual(StainedGlassShape, "bounds")


		m.addConstructors(StainedGlassShape)

		-- Rendering
		local function genRenderFn(smooth)
			return terra(retval: &RetType, sampler: &Sampler, pattern: &Vector(Vec2d))
				sampler:clear()

				-- Repopulate the near tree
				CNearTree.CNearTreeClear(nearTree)
				for i=0,retval.points.size do
					var p = ad.val(retval.points(i).loc)
					var pdata = [&double](p.entries)
					CNearTree.CNearTreeInsert(nearTree, pdata, retval.points:getPointer(i))
				end
				CNearTree.CNearTreeCompleteDelayedInsert(nearTree)

				var shape = [smooth and
					(`StainedGlassShape.heapAlloc(&retval.points, retval.smoothParam))
				or
					(`StainedGlassShape.heapAlloc(&retval.points, 0.0))
				]
				sampler:addShape(shape)
				sampler:sampleSharp(pattern)
			end
		end
		local renderSmooth = genRenderFn(true)
		local renderSharp = genRenderFn(false)

		-- Module exports
		return
		{
			prior = stainedGlass,
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
	codeModule = stainedGlassModule,
	-- jumpFreq = 0.25
	jumpFreq = 0.0
}



