local Vector = terralib.require("vector")
local Vec = terralib.require("linalg").Vec
local Color = terralib.require("color")
local templatize = terralib.require("templatize")
local inheritance = terralib.require("inheritance")
local ad = terralib.require("ad")
local patterns = terralib.require("samplePatterns")


-- Functions that specify how to quantize/convert color channels
--    from one datatype to another.
local ChannelFns = 
{
	None = function()
		return macro(function(src, dst)
			local DstTyp = dst:gettype()
			return `[DstTyp](src)
		end)
	end,
	Quantize = function()
		return macro(function(src, dst)
			local SrcTyp = src:gettype()
			local DstTyp = dst:gettype()
			if SrcTyp:isintegral() and DstTyp:isfloat() then
				local intmax = 2 ^ (terralib.sizeof(SrcTyp)*8)
				return `src / [DstTyp](intmax)
			else if SrcTyp:isfloat() and DstTyp:isintegral() then
				local intmax = 2 ^ (terralib.sizeof(DstTyp)*8)
				return `[DstTyp](src * intmax)
			else
				return `[DstTyp](src)
			end
		end)
	end
}


-- Functions that specify how to deal with 'extra' color channels when
--    writing to/loading from images.
local function makeDimMatchFn(extraCompFn)
	return function(channelFn)
		channelFn = channelFn or ChannelFns.Quantize()
		return macro(function(src, dst)
			local SrcTyp = src:gettype()
			local DstTyp = dst:gettype()
			local SrcDim = SrcTyp.__templateParams[2]
			local DstDim = DstTyp.__templateParams[2]
			local MinDim = math.min(SrcDim, DstDim)
			local t = {}
			for i=1,MinDim do table.insert(t, quote `dst.entries[[i-1]] = channelFn(src.entries[[i-1]]) end)
			for i=MinDim+1,DstDim do table.insert(t, quote `dst.entries[[i-1]] = channelFn([extraCompFn(src, SrcDim, DstDim, i)]) end)
		end)
	end
end
local DimensionMatchFns =
{
	makeNew = makeDimMatchFn,
	Zeros = makeDimMatchFn(function(src, srcDim, dstDim, currIndex)
		return 0.0
	end),
	ZerosWithFullAlpha = makeDimMatchFn(function(src, srcDim, dstDim, currIndex)
		if currIndex == dstDim then return 1.0 else return 0.0 end
	end),
	RepeatLast = makeDimMatchFn(function(src, srcDim, dstDim, currIndex)
		return `src[[srcDim-1]]
	end),
	RepeatLastWithFullAlpha = makeDimMatchFn(function(src, srcDim, dstDim, currIndex)
		if currIndex == dstDim then return 1.0 else return `src[[srcDim-1]] end
	end)
}

-- Functions that specify how to interpolate color from an image
local ImageInterpFns = 
{
	NearestNeighbor = function()
		return macro(function(image, samplePoint)
			return quote
				var i = [uint](samplePoint.entries[0] * image:width())
				var j = [uint](samplePoint.entries[1] * image:height())
				var color = image:getPixelColor(i, j)
			in
				color
			end
		end)
	end
}

-- Functions that specify how to interpolate color from a SampledFn
local SampleInterpFns = 
{
	NearestNeighbor = function()
		-- This is really just a flag indicating that we should do nearest neighbor,
		--    intead of general interpolation
		return "NearestNeighbor"
		-- This is what the structure of a general interpolation function should look like:
		--    return macro(function(sampledFn, samplePoint)
		-- 	     --
		--    end)
	end
}


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
			
			-- Default interpFn, dimMatchFn
			interpFn = interpFn or ImageInterpFns.NearestNeighbor()
			dimMatchFn = dimMatchFn or DimensionMatchFns.RepeatLastWithFullAlpha()
			
			local terra fn(sampledFn: &SampledFunctionBaseT, image: &ImageType, mins: SpaceVec, maxs: SpaceVec) : {}
				var range = maxs - mins
				for i=0,sampledFn.samplingPattern.size do
					var samplePoint = sampledFn.samplingPattern:get(i)
					-- Normalize samplePoint before passing to image
					samplePoint = (samplePoint-mins) / range
					var sourceColor = interpFn(image, samplePoint)
					var targetColor = sampledFn.samples:get(i)
					dimMatchFn(sourceColor, targetColor)
				end
			end
			local terra fn(sampledFn: &SampledFunctionBaseT, image: &ImageType) : {}
				var mins, maxs = sampledFn:spatialBounds()
				return fn(sampledFn, image, mins, maxs)
			end)
			return fn

		end)
		SampledFunctionBaseT.saveToImage = templatize(function(ImageType, interpFn, dimMatchFn)

			-- Default interpFn, dimMatchFn
			interpFn = interpFn or SampleInterpFns.NearestNeighbor()
			dimMatchFn = dimMatchFn or DimensionMatchFns.RepeatLastWithFullAlpha()

			local ImColorVec = ImageType.ColorVec

			-- Special case the nearest-neighbor interpolation scheme, since it's much more efficient
			--    to just iterate over samples in this case, instead of over pixel grid locations.
			if interpFn == SampleInterpFns.NearestNeighbor() then
				local terra fn(sampledFn: &SampledFunctionBaseT, image: &ImageType, mins: SpaceVec, maxs: SpaceVec) : {}
					var range = maxs - mins
					var w = image:width()
					var h = image:height()
					for i=0,sampledFn.samples.size do
						var samplePoint = sampledFn.samplingPattern:get(i)
						var sourceColor = sampledFn.samples:get(i)
						var targetColor = ImColorVec.stackAlloc()
						dimMatchFn(sourceColor, targetColor)
						samplePoint = (samplePoint - mins) / range
						var icoord = [uint](samplePoint.entries[0] * w)
						var jcoord = [uint](samplePoint.entries[1] * h)
						image:setPixelColor(icoord, jcoord, targetColor)
					end
				end
				local terra fn(sampledFn: &SampledFunctionBaseT, image: &ImageType) : {}
					var mins, maxs = sampledFn:spatialBounds()
					return fn(sampledFn, image, mins, maxs)
				end
				return fn
			else
				local DiscreteVec = Vec(uint, 2)
				local terra fn(sampledFn: &SampledFunctionBaseT, image: &ImageType, mins: SpaceVec, maxs: SpaceVec) : {}
					var range = maxs - mins
					var w = image:width()
					var h = image:height()
					var grid = [patterns.RegularGridPattern(real, 2)].stackAlloc(
						mins, maxs, DiscreteVec.stackAlloc(w, h))
					for i=0,grid:storedPattern.size do
						var samplePoint = grd:storedPattern:get(i)
						var sourceColor = interpFn(sampledFn, samplePoint)
						var targetColor = ImColorVec.stackAlloc()
						dimMatchFn(sourceColor, targetColor)
						-- Match samplePoint to image i, j, write to image
						samplePoint = (samplePoint - mins) / range
						var icoord = [uint](samplePoint.entries[0] * w)
						var jcoord = [uint](samplePoint.entries[1] * h)
						image:setPixelColor(icoord, jcoord, targetColor)
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
	end

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



