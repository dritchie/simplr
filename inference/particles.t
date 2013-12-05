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

local C = terralib.includec("stdio.h")

--------------------------------

local lerp = macro(function(lo, hi, t)
	return `(1.0-t)*lo + t*hi
end)


local ParticlesRetType = templatize(function(real)
	local Vec2 = Vec(real, 2)
	local Color3 = Color(real, 3)
	local struct LineSeg { start: Vec2, stop: Vec2, color: Color3 }
	local struct ParticlesRetTypeT { segs: Vector(LineSeg), smoothParam: real }
	ParticlesRetTypeT.LineSeg = LineSeg
	terra ParticlesRetTypeT:__construct() m.init(self.segs) end
	terra ParticlesRetTypeT:__construct(segs: Vector(LineSeg), s: real)
		self.segs = segs; self.smoothParam = s
	end
	terra ParticlesRetTypeT:__copy(other: &ParticlesRetTypeT)
		self.segs = m.copy(other.segs)
		self.smoothParam = other.smoothParam
	end
	terra ParticlesRetTypeT:__destruct()
		m.destruct(self.segs)
	end
	m.addConstructors(ParticlesRetTypeT)
	return ParticlesRetTypeT
end)

local function particlesModule(inferenceTime, doSmoothing)
	return function()
		local doSmooth = doSmoothing
		if doSmooth == nil then doSmooth = (real == ad.num) end
		local Vec2 = Vec(real, 2)
		local Color3 = Color(real, 3)
		local SampledFunctionType = SampledFunction(Vec2d, Color3, SfnOpts.ClampFns.None(), SfnOpts.AccumFns.Over())
		local ShapeType = shapes.ImplicitShape(Vec2, Color3)
		local Capsule = shapes.CapsuleImplicitShape(Vec2, Color3)
		local ColoredShape = shapes.ConstantColorImplicitShape(Vec2, Color3)
		local Sampler = ImplicitSampler(SampledFunctionType, ShapeType)

		local RetType = ParticlesRetType(real)
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
		local nbetaClamped = macro(function(a, b)
			return quote
				var x = beta(a, b, {structural=false})
				-- Have to clamp, because HMC may take us out of the support range.
				x = ad.math.fmax(ad.math.fmin(x, 1.0), 0.0)
			in
				x
			end
		end)
		-- More intuitive
		local nbetaMSClamped = macro(function(m, s)
			return quote
				var b = s
				var a = m*b/(1.0-m)
				var x = nbetaClamped(a, b)
			in
				x
			end
		end)

		local terra rotate(dir: Vec2, angle: real)
			var x = dir(0)
			var y = dir(1)
			var cosang = ad.math.cos(angle)
			var sinang = ad.math.sin(angle)
			return Vec2.stackAlloc(x*cosang - y*sinang, y*cosang + x*sinang)
		end

		-- Constants
		local stepSize = 0.25
		local stepSizeSq = stepSize*stepSize
		local totalTime = 100
		local numSteps = totalTime / stepSize
		local lineWidth = 0.005

		-- Priors
		local numSpawnPointsConcentration = 20
		local spawnPointPosMean = 0.5
		local spawnPointPosSD = 0.25
		local dominantVelMagMean = 0.01
		local dominantVelMagShape = `5.0
		local numParticlesConcentration = 4
		local velDirSD = math.pi/6.0
		local velMagShape = `5.0
		local colorPerturbTightness = `4.0
		local numAttractorsConcentration = 10
		local attractorPosMean = 0.5
		local attractorPosSD = 0.25
		local attractorMagMean = `0.0
		local attractorMagSD = 0.002

		local struct Particle
		{
			pos: Vec2,
			vel: Vec2,
			accel: Vec2,
			color: Color3
		}
		terra Particle:__construct(pos: Vec2, vel: Vec2, color: Color3)
			self.pos = pos
			self.vel = vel
			self.accel = Vec2.stackAlloc(0.0, 0.0)
			self.color = color
		end
		m.addConstructors(Particle)

		local struct Attractor
		{
			pos: Vec2,
			mag: real
		}

		-- The 'prior' part of the program which recursively generates a bunch of line
		--    segments to be rendered.
		local particles = pfn(terra()
			var segs = [Vector(LineSeg)].stackAlloc()
			var particles = [Vector(Particle)].stackAlloc()
			var attractors = [Vector(Attractor)].stackAlloc()

			-- Spawn particles
			-- var numSpawnPoints = poisson(numSpawnPointsConcentration)
			var numSpawnPoints = 1
			for i=0,numSpawnPoints do
				var pos = Vec2.stackAlloc(ngaussian(spawnPointPosMean, spawnPointPosSD), ngaussian(spawnPointPosMean, spawnPointPosSD))
				var domDir = nuniformClamped(0.0, [2*math.pi])
				var domMag = ngammaMS(dominantVelMagMean, dominantVelMagShape)	-- This is an immensely sensitive variable...
				-- var domMag = dominantVelMagMean
				var domColor = Color3.stackAlloc(nuniformClamped(0.0, 1.0), nuniformClamped(0.0, 1.0), nuniformClamped(0.0, 1.0))

				var vel = rotate(Vec2.stackAlloc(1.0, 0.0), domDir) * domMag
				particles:push(Particle.stackAlloc(pos, vel, domColor))

				-- var numParticles = 1
				-- -- var numParticles = poisson(numParticlesConcentration)
				-- for p=0,numParticles do
				-- 	var velDir = rotate(Vec2.stackAlloc(1.0, 0.0), ngaussian(domDir, velDirSD))
				-- 	var vel = ngammaMS(domMag, velMagShape) * velDir
				-- 	var color = Color3.stackAlloc(nbetaMSClamped(domColor(0), colorPerturbTightness),
				-- 								  nbetaMSClamped(domColor(1), colorPerturbTightness),
				-- 								  nbetaMSClamped(domColor(2), colorPerturbTightness))
				-- 	particles:push(Particle.stackAlloc(pos, vel, color))
				-- end
			end

			-- Spawn attractors
			var numAttractors = poisson(numAttractorsConcentration)
			-- var numAttractors = 1
			for i=0,numAttractors do
				var pos = Vec2.stackAlloc(ngaussian(attractorPosMean, attractorPosSD), ngaussian(attractorPosMean, attractorPosSD))
				var mag = ngaussian(attractorMagMean, attractorMagSD)
				attractors:push(Attractor{pos, mag})
			end

			-- Simulate, recording streamlines as we go
			for t=0,numSteps do
				for i=0,particles.size do
					var p = particles:getPointer(i)
					var newAccel = Vec2.stackAlloc(0.0, 0.0)
					for j=0,attractors.size do
						var apos = attractors(j).pos
						var amag = attractors(j).mag
						var diffVec = apos - p.pos
						var diffVecNorm = diffVec:norm()
						diffVec = diffVec / diffVecNorm
						newAccel = newAccel + (amag * diffVec)
					end
					var oldPos = p.pos
					-- Leapfrog integration
					p.pos = p.pos + stepSize*p.vel + 0.5*p.accel*stepSizeSq
					p.vel = p.vel + 0.5*(p.accel + newAccel)*stepSize
					p.accel = newAccel
					-- Record streamline segment
					segs:push(LineSeg{oldPos, p.pos, p.color})
				end
			end

			m.destruct(particles)
			m.destruct(attractors)

			var smoothingAmount = 0.00002
			-- var smoothingAmount = 0.0005
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
					var capsule = Capsule.heapAlloc(seg.start, seg.stop, lineWidth)
					var coloredCapsule = ColoredShape.heapAlloc(capsule, seg.color)
					sampler:addShape(coloredCapsule)
				end
				[util.optionally(smooth, function() return quote
					sampler:sampleSmooth(pattern, retval.smoothParam)
				end end)]
				[util.optionally(not smooth, function() return quote
					sampler:sampleSharp(pattern)
				end end)]
			end
		end
		local renderSmooth = genRenderFn(true)
		local renderSharp = genRenderFn(false)

		-- Module exports
		return
		{
			prior = particles,
			doDepthBiasedSelection = true,
			sampleSmooth = renderSmooth,
			sampleSharp = renderSharp,
			sample = (doSmooth and renderSmooth or renderSharp),
			SampledFunctionType = SampledFunctionType,
			SamplerType = Sampler
		}
	end
end


return particlesModule



