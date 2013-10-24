local Vector = terralib.require("vector")
local Vec = terralib.require("linalg").Vec
local Color = terralib.require("color")
local templatize = terralib.require("templatize")
local shapeColor = terralib.require("shapeColor")
local inheritance = terralib.require("inheritance")
local ad = terralib.require("ad")

-- Blurring will use the alpha channel (last output dimension), so we'll have to
--    make sure we always use RGBA color, even when A is constant in the input...

local SampledFunctionBase = templatize(function(real, spaceDim, colorDim)
	
	local SpaceVec = Vec(real, spaceDim)
	local ColorVec = Color(real, colorDim)
	local SamplingPattern = Vector(SpaceVec)
	local Samples = Vector(ColorVec)

	local struct SampledFunctionBaseT = 
	{
		samplingPattern: &SamplingPattern,
		samples: Samples
	}

	terra SampledFunctionBaseT:__construct()
		self.samplingPattern = nil
		m.init(self.samples)
	end

	terra SampledFunctionBaseT:__copy(other: &SampledFunctionBaseT)
		self.samples = m.copy(other.samples)
	end

	terra SampledFunctionBaseT:__destruct()
		m.destruct(self.samples)
	end
	inheritance.virtual(SampledFunctionBaseT, "__destruct")

	terra SampledFunctionBaseT:clear()
		self.samplingPattern = nil
		self.samples:clear()
	end

	terra SampledFunctionBaseT:setSamplingPattern(pattern: &SamplingPattern)
		self.samplingPattern = pattern
		self.samples:resize(pattern.size)
	end

	inheritance.purevirtual(SampledFunctionBaseT, "accumulateSample", {uint, ColorVec}->{})

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

	accumFn = accumFn or AccumFns.Replace
	clampFn = clampFn or ClampFns.None

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


local ImplicitSampler = templatize(function(real, spaceDim, colorDim)

	local Shape = shapeColor.ColoredImplicitShape(real, spaceDim, colorDim)
	local SpaceVec = Vec(real, spaceDim)
	local ColorVec = Color(real, colorDim)
	local SamplingPattern = Vector(SpaceVec)
	local Samples = Vector(ColorVec)
	local SampledFunctionT = SampledFunctionBase(real, spaceDim, colorDim)

	local struct ImplicitSamplerT
	{
		shapes: Vector(&Shape),
		sampledFn: &SampledFunctionT
	}

	-- Assumes ownership of sampledFn
	terra ImplicitSamplerT:__construct(sampledFn: &SampledFunctionT)
		m.init(self.shapes)
		self.sampledFn = sampledFn
	end

	terra ImplicitSamplerT:__destruct()
		m.destruct(self.shapes)
		m.delete(self.sampledFn)
	end

	-- Assumes ownership of shape
	terra ImplicitSamplerT:addShape(shape: &Shape)
		self.shapes:push(shape)
	end

	terra ImplicitSamplerT:sample(pattern: &SamplingPattern)
		self.sampledFn:setSamplingPattern(pattern)
		-- TODO: More efficient than O(#samples*#shapes)
		for sampi=0,pattern.size do
			var samplePoint = pattern:get(sampi)
			for shapei=0,self.shapes.size do
				-- TODO: blur would happen here
				var isovalue, color = self.shapes:get(shapei):isovalueAndColor(samplePoint)
				self.sampledFn:accumulateSample(sampi, color)
			end
		end
	end

	terra ImplicitSamplerT:clearSamples()
		self.sampledFn:clear()
	end

	terra ImplicitSamplerT:clearShapes()
		for i=0,self.shapes.size do
			m.delete(self.shapes:get(i))
		end
		self.shapes:clear()
	end

	m.addConstructors(ImplicitSamplerT)
	return ImplicitSamplerT

end)


return 
{
	AccumFns = AccumFns,
	ClampFns = ClampFns,
	SampledFunction = SampledFunction,
	ImplicitSampler = ImplicitSampler
}



