local m = terralib.require("mem")
local util = terralib.require("util")
local Vector = terralib.require("vector")
local Vec = terralib.require("linalg").Vec
local Color = terralib.require("color")
local templatize = terralib.require("templatize")
local inheritance = terralib.require("inheritance")
local patterns = terralib.require("samplePatterns")
local options = terralib.require("sampledFnOptions")


local SampledFunction = templatize(function(SpaceVec, ColorVec, clampFn, accumFn)

	assert(SpaceVec.__generatorTemplate == Vec)
	assert(ColorVec.__generatorTemplate == Color)

	accumFn = accumFn or options.AccumFns.Replace()
	clampFn = clampFn or options.ClampFns.None()
	
	local colorReal = ColorVec.RealType
	local SamplingPattern = Vector(SpaceVec)

	local struct SampledFunctionT
	{
		samplingPattern: &SamplingPattern,
		ownsSamplingPattern: bool,
		samples: Vector(ColorVec)
	}
	SampledFunctionT.SpaceVec = SpaceVec
	SampledFunctionT.ColorVec = ColorVec
	SampledFunctionT.SamplingPattern = SamplingPattern

	terra SampledFunctionT:__construct()
		self.samplingPattern = nil
		self.ownsSamplingPattern = false
		m.init(self.samples)
	end

	terra SampledFunctionT:__copy(other: &SampledFunctionT)
		self.samples = m.copy(other.samples)
	end

	terra SampledFunctionT:__destruct()
		self:clear()
		m.destruct(self.samples)
	end

	terra SampledFunctionT:clear()
		if self.ownsSamplingPattern then
			m.delete(self.samplingPattern)
		end
		self.samplingPattern = nil
		self.samples:clear()
	end

	terra SampledFunctionT:spatialBounds()
		var mins = SpaceVec.stackAlloc([math.huge])
		var maxs =SpaceVec.stackAlloc([-math.huge])
		for i=0,self.samplingPattern.size do
			var samplePoint = self.samplingPattern:get(i)
			mins:minInPlace(samplePoint)
			maxs:maxInPlace(samplePoint)
		end
		return mins,maxs
	end

	terra SampledFunctionT:setSamplingPattern(pattern: &SamplingPattern)
		if self.ownsSamplingPattern then m.delete(self.samplingPattern) end
		self.samplingPattern = pattern
		self.ownsSamplingPattern = false
		self.samples:resize(pattern.size)
	end

	terra SampledFunctionT:ownSamplingPattern(pattern: &SamplingPattern)
		if self.ownsSamplingPattern then m.delete(self.samplingPattern) end
		self.samplingPattern = m.new(SamplingPattern)
		self.samplingPattern:__copy(pattern)
		self.ownsSamplingPattern = true
		self.samples:resize(pattern.size)
	end

	terra SampledFunctionT:accumulateSample(index: uint, color: ColorVec, alpha: colorReal) : {}
		var currColor = self.samples:get(index)
		self.samples:set(index, clampFn(accumFn(currColor, color, alpha)))
	end

	terra SampledFunctionT:accumulateSample(index: uint, color: ColorVec) : {}
		self:accumulateSample(index, color, 1.0)
	end

	if SpaceVec.Dimension == 2 then
		--  Save/load to/from images, parameterized by:
		--    A function specifying how to interpolate onto/from image grid.
		--    What to do with extra color channels (dimension matching)
		SampledFunctionT.loadFromImage = templatize(function(ImageType, interpFn, dimMatchFn)
			
			-- Default interpFn, dimMatchFn
			interpFn = interpFn or options.ImageInterpFns.NearestNeighbor()
			dimMatchFn = dimMatchFn or options.DimensionMatchFns.RepeatLast()
			
			return terra(sampledFn: &SampledFunctionT, image: &ImageType, mins: SpaceVec, maxs: SpaceVec) : {}
				var range = maxs - mins
				for i=0,sampledFn.samplingPattern.size do
					var samplePoint = sampledFn.samplingPattern:get(i)
					-- Normalize samplePoint before passing to image
					samplePoint = (samplePoint - mins) / range
					var sourceColor = interpFn(image, samplePoint)
					var targetColor = sampledFn.samples:getPointer(i)
					dimMatchFn(sourceColor, targetColor)
				end
			end
		end)
		SampledFunctionT.saveToImage = templatize(function(ImageType, interpFn, dimMatchFn)

			-- Default interpFn, dimMatchFn
			interpFn = interpFn or options.SampleInterpFns.NearestNeighbor()
			dimMatchFn = dimMatchFn or options.DimensionMatchFns.RepeatLast()

			local ImColorVec = ImageType.ColorVec

			-- Special case the nearest-neighbor interpolation scheme, since it's much more efficient
			--    to just iterate over samples in this case, instead of over pixel grid locations.
			if interpFn == options.SampleInterpFns.NearestNeighbor() then
				return terra(sampledFn: &SampledFunctionT, image: &ImageType, mins: SpaceVec, maxs: SpaceVec) : {}
					var range = maxs - mins
					var w = image:width()
					var h = image:height()
					for i=0,sampledFn.samples.size do
						var samplePoint = sampledFn.samplingPattern:get(i)
						var sourceColor = sampledFn.samples:get(i)
						var targetColor = ImColorVec.stackAlloc()
						dimMatchFn(sourceColor, &targetColor)
						var oldSamplePoint = samplePoint
						samplePoint = (samplePoint - mins) / range
						var icoord = [uint](samplePoint.entries[0] * w)
						var jcoord = [uint](samplePoint.entries[1] * h)
						image:setPixelColor(icoord, jcoord, targetColor)
					end
				end
			else
				local DiscreteVec = Vec(uint, 2)
				return terra(sampledFn: &SampledFunctionT, image: &ImageType, mins: SpaceVec, maxs: SpaceVec) : {}
					var range = maxs - mins
					var w = image:width()
					var h = image:height()
					var grid = [patterns.RegularGridPattern(real, 2)].stackAlloc(
						mins, maxs, DiscreteVec.stackAlloc(w, h))
					for i=0,grid.storedPattern.size do
						var samplePoint = grd.storedPattern:get(i)
						var sourceColor = interpFn(sampledFn, samplePoint)
						var targetColor = ImColorVec.stackAlloc()
						dimMatchFn(sourceColor, &targetColor)
						-- Match samplePoint to image i, j, write to image
						samplePoint = (samplePoint - mins) / range
						var icoord = [uint](samplePoint.entries[0] * w)
						var jcoord = [uint](samplePoint.entries[1] * h)
						image:setPixelColor(icoord, jcoord, targetColor)
					end
					m.destruct(grid)
				end
			end
		end)
	end

	-- Process samples in lock-step with samples from an identical sampling
	--    pattern (but possibly of a different type)
	SampledFunctionT.lockstep = templatize(
	function(SampledFunctionT2, processingFn)
		assert(SampledFunctionT.SpaceVec.Dimension == SampledFunctionT2.SpaceVec.Dimension)
		return macro(function(self, fn2)
			assert(self:gettype() == &SampledFunctionT)
			assert(fn2:gettype() == &SampledFunctionT2)
			return quote
				if self.samplingPattern ~= fn2.samplingPattern then
					util.fatalError("Attempt to compare two sample sets drawn from different sampling patterns.\n")			
				end
				for i=0,self.samplingPattern.size do
					var s1 = self.samplingPattern:getPointer(i)
					var s2 = fn2.samplingPattern:getPointer(i)
					[processingFn(s1, s2)]
				end
			end
		end)
	end)

	m.addConstructors(SampledFunctionT)
	return SampledFunctionT

end)


return SampledFunction



