local Vector = terralib.require("vector")
local Vec = terralib.require("linalg").Vec
local templatize = terralib.require("templatize")
local shapeColor = terralib.require("shapeColor")


-- Need: SampledFunctionBase, then SampledFunction subclass which is parameterized
--    by accumFn, clampFn
-- Can think of these as a different interface to providing the same information as
--    OpenGL's glBlendFunc and glBlendEquation
-- Default provided clampFns: none, min, softmin
-- Default provided accumFns: replace, over
--    (over treats the last output dimension as alpha?)

-- Blurring will use the alpha channel (last output dimension), so we'll have to
--    make sure we always use RGBA color, even when A is constant in the input...

-- TODO: Save/load to/from images (need a FreeImage wrapper), parameterized by
--    function specifying how to interpolate onto/from image grid.
-- Default provided functions: nearest neighbor, bilinear.
-- When loading/saving, specify what to write into 'extra' outDims (e.g. loading an
--    RGB image into an RGBA (4-dimensional) structure).

local SampledFunction = templatize(function(real, inDim, outDim)
	
	local InVec = Vec(real, inDim)
	local OutVec = Vec(real, outDim)
	local SamplingPattern = Vector(InVec)
	local Samples = Vector(OutVec)

	local struct SampledFunctionT = 
	{
		samplingPattern: &SamplingPattern,
		samples: Samples
	}

	terra SampledFunctionT:__construct()
		self.samplingPattern = nil
		m.init(self.samples)
	end

	terra SampledFunctionT:__copy(other: &SampledFunctionT)
		self.samples = m.copy(other.samples)
	end

	terra SampledFunctionT:__destruct()
		m.destruct(self.samples)
	end

	terra SampledFunctionT:clear()
		self.samplingPattern = nil
		self.samples:clear()
	end

	terra SampledFunctionT:setSamplingPattern(pattern: &SamplingPattern)
		self.samplingPattern = pattern
		self.samples:resize(pattern.size)
	end

	terra SampledFunctionT:setSample(which: uint, value: OutVec)
		self.samples:set(which, value)
	end

	m.addConstructors(SampledFunctionT)
	return SampledFunctionT

end)


local ImplicitSampler = templatize(function(real, spaceDim, colorDim)

	local Shape = shapeColor.ColoredImplicitShape(real, spaceDim, colorDim)
	local SpaceVec = Vec(real, spaceDim)
	local ColorVec = Vec(real, colorDim)
	local SamplingPattern = Vector(SpaceVec)
	local Samples = Vector(ColorVec)

	local struct ImplicitSamplerT
	{
		shapes: Vector(&Shape),
		sampledFn: SampledFunction(real, spaceDim, colorDim)
	}

	terra ImplicitSamplerT:__construct()
		m.init(self.shapes)
		m.init(self.sampledFn)
	end

	terra ImplicitSamplerT:__destruct()
		m.destruct(self.shapes)
		m.destruct(self.sampledFn)
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
				self.sampledFn:setSample(sampi, color)
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
	SampledFunction = SampledFunction,
	ImplicitSampler = ImplicitSampler
}



