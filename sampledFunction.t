local Vector = terralib.require("vector")
local Vec = terralib.require("linalg").Vec
local Color = terralib.require("color")
local templatize = terralib.require("templatize")
local inheritance = terralib.require("inheritance")
local ad = terralib.require("ad")
local patterns = terralib.require("samplePatterns")


local SampledFunctionBase
SampledFunctionBase = templatize(function(real, spaceDim, colorDim)
	
	local SpaceVec = Vec(real, spaceDim)
	local ColorVec = Color(real, colorDim)
	local SamplingPattern = Vector(SpaceVec)
	local Samples = Vector(ColorVec)

	local struct SampledFunctionBaseT = 
	{
		samplingPattern: &SamplingPattern,
		ownsSamplingPattern: bool,
		samples: Samples
	}

	terra SampledFunctionBaseT:__construct()
		self.samplingPattern = nil
		self.ownsSamplingPattern = false
		m.init(self.samples)
	end

	terra SampledFunctionBaseT:__copy(other: &SampledFunctionBaseT)
		self.samples = m.copy(other.samples)
	end

	terra SampledFunctionBaseT:__destruct()
		self:clear()
		m.destruct(self.samples)
	end
	inheritance.virtual(SampledFunctionBaseT, "__destruct")

	terra SampledFunctionBaseT:clear()
		if self.ownsSamplingPattern then m.delete(self.samplingPattern) end
		self.samplingPattern = nil
		self.samples:clear()
	end

	terra SampledFunctionBaseT:spatialBounds()
		var mins = SpaceVec.stackAlloc([math.huge])
		var maxs =SpaceVec.stackAlloc([-math.huge])
		for i=0,self.samplingPattern.size do
			var samplePoint = self.samplingPattern:get(i)
			mins:minInPlace(samplePoint)
			maxs:maxInPlace(samplePoint)
		end
		return mins,maxs
	end

	terra SampledFunctionBaseT:setSamplingPattern(pattern: &SamplingPattern)
		if self.ownSamplingPattern then m.delete(self.samplingPattern) end
		self.samplingPattern = pattern
		self.ownsSamplingPattern = false
		self.samples:resize(pattern.size)
	end

	terra SampledFunctionBaseT:ownSamplingPattern(pattern: &SamplingPattern)
		if self.ownSamplingPattern then m.delete(self.samplingPattern) end
		self.samplingPattern = m.new(SamplingPattern)
		self.samplingPattern:__copy(pattern)
		self.ownsSamplingPattern = true
		self.samples:resize(pattern.size)
	end

	inheritance.purevirtual(SampledFunctionBaseT, "accumulateSample", {uint, ColorVec}->{})

	if spaceDim == 2 then
		--  Save/load to/from images, parameterized by:
		--    A function specifying how to interpolate onto/from image grid.
		--    What to do with extra color channels (dimension matching)
		SampledFunctionBaseT.loadFromImage = templatize(function(ImageType, interpFn, dimMatchFn)
			
			-- TODO: Default interpFn, dimMatchFn
			
			local terra fn(sampledFn: &SampledFunctionBaseT, image: &ImageType, mins: SpaceVec, maxs: SpaceVec) : {}
				var range = maxs - mins
				for i=0,sampledFn.samplingPattern.size do
					var samplePoint = sampledFn.samplingPattern:get(i)
					-- Normalize samplePoint before passing to image
					samplePoint = (samplePoint-mins) / range
					sampledFn.samples:set(i, dimMatchFn(interpFn(image, samplePoint)))
				end
			end
			local terra fn(sampledFn: &SampledFunctionBaseT, image: &ImageType) : {}
				var mins, maxs = sampledFn:spatialBounds()
				return fn(sampledFn, image, mins, maxs)
			end)
			return fn

		end)
		SampledFunctionBaseT.saveToImage = templatize(function(ImageType, interpFn, dimMatchFn)

			-- TODO: Default interpFn, dimMatchFn

			-- Code gen helper
			local function arrayElems(ptr, num)
				local t = {}
				for i=1,num do
					local iminus1 = i-1
					table.insert(t, `ptr[iminus1])
				end
				return t
			end

			local DiscreteVec = Vec(uint, 2)
			
			local terra fn(sampledFn: &SampledFunctionBaseT, image: &ImageType, mins: SpaceVec, maxs: SpaceVec) : {}
				var range = maxs - mins
				var w = image:width()
				var h = image:height()
				var grid = [patterns.RegularGridPattern(real, 2)].stackAlloc(
					mins, maxs, DiscreteVec.stackAlloc(w, h))
				for i=0,grid:storedPattern.size do
					var samplePoint = grd:storedPattern:get(i)
					var color = dimMatchFn(interpFn(sampledFn, samplePoint))
					-- Match samplePoint to image i, j, write to image
					samplePoint = (samplePoint - mins) / range
					var icoord = [uint](samplePoint.entries[0] * w)
					var jcoord = [uint](samplePoint.entries[1] * h)
					var p = image:pixel(icoord, jcoord)
					[arrayElems(p)] = [ColorVec.entries(color)]
				end
				m.destruct(grid)
			end
			local terra fn(sampledFn: &SampledFunctionBaseT, image: &ImageType) : {}
				var mins, maxs = sampledFn:spatialBounds()
				return fn(sampledFn, image, mins, maxs)
			end
			return fn

		end
	end)

	return SampledFunctionBaseT

end)


-- Some default color accumlation / clamping functions
-- Can think of these as a different interface to providing the same information as
--    OpenGL's glBlendFunc and glBlendEquation
local AccumFns = 
{
	Replace = function()
		return macro(function(currColor, newColor) return newColor end)
	end,
	Over = function()
		return macro(function(currColor, newColor)
			return `newColor:alpha()*newColor + (1.0 - newColor:alpha())*currColor
		end)
	end
}
local ClampFns = 
{
	None = function() return macro(function(color) return color end) end,
	Min = function(maxval)
		if maxval == nil then maxval = 1.0 end
		return macro(function(color)
			local VecT = color:gettype()
			return [VecT.map(color, function(ce) return `ad.math.fmin(ce, maxval) end)]
		end)
	end,
	SoftMin = function(power, maxval)
		if maxval == nil then maxval = 1.0 end
		return macro(function(color)
			local VecT = color:gettype()
			return [VecT.map(color, function(ce)
				-- TODO: More efficient softmin implementation.
				return `ad.math.pow(ad.math.pow(ce, -power) + ad.math.pow(maxval, -power), 1.0/-alpha)
			end)]
		end)
	end
}


local SampledFunction = templatize(function(real, spaceDim, colorDim, accumFn, clampFn)

	accumFn = accumFn or AccumFns.Replace()
	clampFn = clampFn or ClampFns.None()

	local ColorVec = Color(real, colorDim)
	local SampledFunctionBaseT = SampledFunctionBase(real, spaceDim, colorDim)

	local struct SampledFunctionT {}
	inheritance.dynamicExtend(SampledFunctionBaseT, SampledFunctionT)

	terra SampledFunctionT:accumulateSample(index: uint, color: ColorVec)
		var currColor = self.samples:get(index)
		self.samples:set(index, clampFn(accumFn(currColor, color)))
	end
	inheritance.virtual(SampledFunctionT, "accumulateSample")

	m.addConstructors(SampledFunctionT)
	return SampledFunctionT

end)


return 
{
	AccumFns = AccumFns,
	ClampFns = ClampFns,
	SampledFunctionBase = SampledFunctionBase,
	SampledFunction = SampledFunction
}



