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

	return SampledFunctionBaseT

end)


--  Save/load to/from images, parameterized by:
--    A function specifying how to interpolate onto/from image grid.
--    What to do with extra color channels (dimension matching)
-- TODO: Make sampledFns be able to compute bounds on their sampling patterns,
--    so that we don't have to restrict to functions defined on the unit square.
SampledFunctionBase.loadFromImage = templatize(function(interpFn, dimMatchFn)
	
	-- TODO: Default interpFn, dimMatchFn
	
	return macro(function(sampledFn, image)
		
		-- Types
		local FnType = sampledFn:gettype()
		local ImType = image:gettype()
		local FnRealType = FnType.__templateParams[1]
		local FnSpaceDim = FnType.__templateParams[2]
		local FnColorDim = FnType.__templateParams[3]
		assert(FnSpaceDim == 2)		-- This must be a 2D function

		-- Main
		return quote
			for i=0,sampledFn.samplingPattern.size do
				var samplePoint = sampledFn.samplingPattern:get(i)
				-- TODO: normalize samplePoint against fn minx and maxs
				sampledFn.samples:set(i, dimMatchFn(interpFn(image, samplePoint)))
			end
		end
	end)

end)
SampledFunctionBase.saveToImage = templatize(function(interpFn, dimMatchFn)

	-- TODO: Default interpFn, dimMatchFn
	
	return macro(function(sampledFn, image)
		
		-- Types
		local FnType = sampledFn:gettype()
		local ImType = image:gettype()
		local FnRealType = FnType.__templateParams[1]
		local FnSpaceDim = FnType.__templateParams[2]
		local FnColorDim = FnType.__templateParams[3]
		assert(FnSpaceDim == 2)		-- This must be a 2D function
		local DiscreteVec = Vec(uint, 2)

		-- Main
		return quote
			-- TODO: Construct grid out of fn mins and maxs
			var grid = [patterns.RegularGridPattern(FnRealType, 2)].stackAlloc(
				DiscreteVec.stackAlloc(image:width(), image:height()))
			for i=0,grid:storedPattern.size do
				var samplePoint = grd:storedPattern:get(i)
				var vec = dimMatchFn(interpFn(sampledFn, samplePoint))
				-- TODO: Write vec components to pixel (need to match samplePoint with image i,j ...)
			end
			m.destruct(grid)
		end
	end)

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



